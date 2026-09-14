#!/usr/bin/env python3
"""Nonprivileged tests of native-control preparation and verdicts, not native evidence."""

import base64
import contextlib
import importlib.util
import io
import itertools
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True


def run_regressions(root):
    spec = importlib.util.spec_from_file_location(
        'lifecycle_control', root / '.github/scripts/lifecycle-assert-control.py')
    control = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(control)
    if control.GATES != {'systemd': 'systemd-lifecycle.sh', 'openrc': 'alpine-lifecycle.sh'}:
        raise AssertionError('both native callers must be covered')
    if set(control.MODES) != {'healthy', 'fail', 'skip', 'unreachable', 'swallow'}:
        raise AssertionError('control mode coverage changed')
    checks = 0
    with tempfile.TemporaryDirectory(prefix='s5-control-test-') as directory:
        work = Path(directory)
        source = work / 'source'
        scripts = source / '.github/scripts'
        scripts.mkdir(parents=True)
        (source / 'tests').mkdir()
        for name in ('socks5.sh', 'README.md', 'README.zh-CN.md', '.gitignore'):
            (source / name).touch()
        for name in ('CLAUDE.md', 'CONTEXT.md', 'SPEC.md', 'todo.md'):
            (source / name).write_text('private\n')
        (source / '.claude').mkdir()
        (source / '.claude/private').touch()
        assertion = scripts / 'lifecycle-update-assert.sh'
        assertion.write_text(f"#!/bin/sh\nprintf '%s\\n' '{control.REACHED}'\n")
        fakebin = work / 'bin'
        fakebin.mkdir()
        sudo = fakebin / 'sudo'
        sudo.write_text('#!/bin/sh\nexec "$@"\n')
        sudo.chmod(0o700)
        old_path = os.environ['PATH']
        os.environ['PATH'] = str(fakebin) + os.pathsep + old_path
        try:
            for backend, filename in control.GATES.items():
                command = ('sudo ' if backend == 'systemd' else '') + 'sh .github/scripts/lifecycle-update-assert.sh'
                actual = (root / '.github/scripts' / filename).read_text().splitlines()
                if actual.count(command) != 1:
                    raise AssertionError(backend + ': real gate is not a caller')
                (scripts / filename).write_text('#!/bin/sh\nset -eu\n' + command + '\nprintf "gate-finished\\n"\n')
                for mode in control.MODES:
                    checkout = work / (backend + '-' + mode)
                    checkout.mkdir()
                    gate = control.prepare(source, checkout, backend, mode)
                    for private in ('CLAUDE.md', 'CONTEXT.md', 'SPEC.md', 'todo.md', '.claude'):
                        if (checkout / private).exists():
                            raise AssertionError('snapshot copied a private path')
                    log = work / 'gate.log'
                    status = control.run_gate(gate, checkout, log, timeout=10)
                    output = log.read_text()
                    control.verify(mode, status, output)
                    if (mode == 'fail') == ('gate-finished' in output):
                        raise AssertionError('failure was swallowed or healthy path stopped')
                    checks += 1
        finally:
            os.environ['PATH'] = old_path

        # The verifier must reject all unrelated failures, missing/repeated
        # markers and timeouts, not just accept the hand-picked positive cases.
        for mode in control.MODES:
            for status, checkpoint, reached, forced in itertools.product(
                    (0, 1, 73, 124, -15), (False, True), (False, True), (False, True)):
                expected = {
                    'healthy': (0, True, True, False),
                    'fail': (73, True, True, True),
                    'skip': (0, True, False, False),
                    'unreachable': (0, True, False, False),
                    'swallow': (0, True, True, True),
                }[mode]
                output = '\n'.join(marker for marker, present in (
                    (control.CHECKPOINT, checkpoint), (control.REACHED, reached),
                    (control.FORCED, forced)) if present)
                accepted = True
                try:
                    control.verify(mode, status, output)
                except ValueError:
                    accepted = False
                if accepted != ((status, checkpoint, reached, forced) == expected):
                    raise AssertionError('control verdict accepted the wrong evidence')
                checks += 1
            try:
                control.verify(mode, 0, (control.CHECKPOINT + '\n') * 2)
            except ValueError:
                checks += 1
            else:
                raise AssertionError('control accepted repeated checkpoints')

        credentials = work / 'credentials'
        credentials.mkdir()
        common = root / '.github/scripts/lifecycle-common.sh'
        subprocess.run(['sh', '-c', '. "$1"; lifecycle_write_fixtures "$2"',
                        'fixture', str(common), str(credentials)], check=True)
        tokens = []
        for name in ('pass', 'pass.update'):
            user, secret = (credentials / name).read_text().splitlines()
            pair = user + ':' + secret
            tokens.extend((secret, pair, base64.b64encode(pair.encode()).decode()))
        (scripts / 'lifecycle-common.sh').write_text(common.read_text())
        real_run = subprocess.run

        def safe_subprocess(arguments, **kwargs):
            if arguments[0] == 'sh' and arguments[3] == 'lifecycle-fixtures':
                return real_run(arguments, **kwargs)
            return subprocess.CompletedProcess(arguments, 0)

        for fault in ('verdict', 'timeout'):
            def failing_gate(_gate, _root, log):
                log.write_text('old diagnostic\n' * 100 + 'x' * 9000 + '\n' +
                               '\n'.join(tokens) + '\nuseful failure reason\n')
                if fault == 'timeout':
                    raise subprocess.TimeoutExpired('synthetic-gate', 1)
                return 1

            diagnostic = io.StringIO()
            with patch.dict(os.environ, {'GITHUB_ACTIONS': 'true'}), \
                    patch.object(control.subprocess, 'run', side_effect=safe_subprocess), \
                    patch.object(control, 'run_gate', side_effect=failing_gate), \
                    contextlib.redirect_stderr(diagnostic):
                try:
                    control.native_control(source, 'systemd', 'healthy')
                except (ValueError, subprocess.TimeoutExpired):
                    pass
                else:
                    raise AssertionError('a broken native control passed')
            text = diagnostic.getvalue()
            if 'useful failure reason' not in text or '<REDACTED>' not in text:
                raise AssertionError('failed control discarded its diagnostic summary')
            if any(token in text for token in tokens):
                raise AssertionError('failed control leaked a credential generation')
            if len(text.splitlines()) > 41 or len(text) > 8200:
                raise AssertionError('failed control emitted an unbounded diagnostic')
            checks += 1

        sleeper = work / 'sleeper.sh'
        sleeper.write_text('printf "%s\\n" "$$" > sleeper.pid\nexec sleep 30\n')
        try:
            control.run_gate(sleeper, work, work / 'sleep.log', timeout=1)
        except subprocess.TimeoutExpired:
            pid = int((work / 'sleeper.pid').read_text())
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                checks += 1
            else:
                raise AssertionError('timed-out child was not reaped')
        else:
            raise AssertionError('timeout did not fire')
    print(f'lifecycle control regressions: {checks} checks passed (no native lifecycle run)')


class LifecycleControlTests(unittest.TestCase):
    root = Path(__file__).resolve().parents[2]

    def test_lifecycle_control_mutations(self):
        run_regressions(self.root)


def main():
    if len(sys.argv) > 1:
        LifecycleControlTests.root = Path(sys.argv[1]).resolve()
    result = unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromTestCase(LifecycleControlTests))
    return int(not result.wasSuccessful())


if __name__ == '__main__':
    sys.exit(main())
