#!/usr/bin/env python3
"""Run assertion reachability/error-propagation controls on disposable native CI hosts."""

import argparse
import base64
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile

CHECKPOINT = 'lifecycle-control: update checkpoint'
REACHED = 'lifecycle-update-assert: reached'
FORCED = 'lifecycle-control: injected assertion failure'
FAILURE = 73
MODES = ('healthy', 'fail', 'skip', 'unreachable', 'swallow')
GATES = {'systemd': 'systemd-lifecycle.sh', 'openrc': 'alpine-lifecycle.sh'}


def prepare(root, destination, backend, mode):
    for name in ('tests', '.github'):
        shutil.copytree(root / name, destination / name)
    for name in ('socks5.sh', 'README.md', 'README.zh-CN.md', '.gitignore'):
        shutil.copy2(root / name, destination / name)
    gate = destination / '.github/scripts' / GATES[backend]
    assertion = destination / '.github/scripts/lifecycle-update-assert.sh'
    command = ('sudo ' if backend == 'systemd' else '') + 'sh .github/scripts/lifecycle-update-assert.sh'
    lines = gate.read_text().splitlines()
    if lines.count(command) != 1:
        raise ValueError('expected exactly one post-update assertion call')
    if mode != 'healthy':
        with assertion.open('a') as handle:
            handle.write(f"\nprintf '%s\\n' '{FORCED}'\nexit {FAILURE}\n")
    replacement = command
    if mode == 'skip':
        replacement = ':'
    elif mode == 'unreachable':
        replacement = 'if false; then\n' + command + '\nfi'
    elif mode == 'swallow':
        replacement = command + ' || true'
    lines[lines.index(command)] = f"printf '%s\\n' '{CHECKPOINT}'\n" + replacement
    gate.write_text('\n'.join(lines) + '\n')
    return gate


def verify(mode, status, output):
    lines = output.splitlines()
    checkpoint = lines.count(CHECKPOINT)
    reached = lines.count(REACHED)
    forced = lines.count(FORCED)
    # Every broken-call control must still finish the rest of its native gate.
    # An unrelated early error or timeout is never evidence of detection.
    expected = {
        'healthy': (0, 1, 1, 0),
        'fail': (FAILURE, 1, 1, 1),
        'skip': (0, 1, 0, 0),
        'unreachable': (0, 1, 0, 0),
        'swallow': (0, 1, 1, 1),
    }
    if mode not in expected:
        raise ValueError('unknown control mode')
    if (status, checkpoint, reached, forced) != expected[mode]:
        raise ValueError(f'{mode}: unexpected marker/status evidence (status={status}, '
                         f'checkpoint={checkpoint}, reached={reached}, forced={forced})')


def run_gate(gate, root, log, timeout=1200):
    with log.open('wb') as output:
        process = subprocess.Popen(['sh', str(gate)], cwd=root, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            return process.wait(timeout=timeout)
        except BaseException:
            # The gate and its direct children share this owned process group;
            # native daemons are removed separately by their own cleanup paths.
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                pass
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            raise


def fixture_secrets(root, work):
    subprocess.run(['sh', '-c', '. "$1"; lifecycle_write_fixtures "$2"',
                    'lifecycle-fixtures', str(root / '.github/scripts/lifecycle-common.sh'), str(work)],
                   check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
    secrets = set()
    for name in ('pass', 'pass.update'):
        user, password = (work / name).read_text().splitlines()
        if not user or not password:
            raise ValueError('empty lifecycle credential fixture')
        pair = user + ':' + password
        secrets.update((password, pair, base64.b64encode(pair.encode()).decode()))
    return sorted(secrets, key=len, reverse=True)


def report_failure(log, secrets):
    try:
        output = log.read_text(errors='replace')
    except OSError:
        print('lifecycle-control: diagnostic log unavailable', file=sys.stderr)
        return
    for secret in secrets:
        output = output.replace(secret, '<REDACTED>')
    summary = '\n'.join(output.splitlines()[-40:])[-8000:]
    print('lifecycle-control: diagnostic summary\n' + summary, file=sys.stderr)


def native_control(root, backend, mode):
    if os.environ.get('GITHUB_ACTIONS') != 'true':
        raise ValueError('native lifecycle controls run only in disposable GitHub Actions environments')
    if backend == 'openrc' and os.geteuid() != 0:
        raise ValueError('OpenRC control requires container root')
    # Refuse to adopt an installation that predates this invocation. The
    # systemd gate already owns namespace cleanup; OpenRC cleanup stays here.
    prefix = ['sudo'] if backend == 'systemd' else []
    subprocess.run(prefix + ['sh', '-c', '''
for path in /etc/xray-socks5 /var/lib/xray-socks5 /usr/local/libexec/xray-socks5; do
    test ! -e "$path" && test ! -L "$path" || exit 1
done
'''], check=True, timeout=15)
    with tempfile.TemporaryDirectory(prefix='lifecycle-control-') as directory:
        work = Path(directory)
        checkout = work / 'repo'
        checkout.mkdir()
        gate = prepare(root, checkout, backend, mode)
        secrets = fixture_secrets(checkout, work)
        log = work / 'gate.log'
        try:
            try:
                status = run_gate(gate, checkout, log)
                output = log.read_text(errors='replace')
                verify(mode, status, output)
            except BaseException:
                report_failure(log, secrets)
                raise
        finally:
            if backend == 'openrc' and Path('/var/lib/xray-socks5/state').exists():
                # Forced failures stop after update but before the gate's uninstall.
                cleanup_log = work / 'cleanup.log'
                try:
                    with cleanup_log.open('wb') as cleanup:
                        subprocess.run(['sh', str(checkout / 'socks5.sh'), 'uninstall'],
                                       input=b'y\n', stdout=cleanup, stderr=subprocess.STDOUT,
                                       timeout=60, check=True)
                except BaseException:
                    report_failure(cleanup_log, secrets)
                    raise
        print(f'lifecycle-control: backend={backend} mode={mode} evidence=ok status={status}')


def interrupted(signum, _frame):
    raise InterruptedError(f'interrupted by signal {signum}')


def main():
    for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, interrupted)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('backend', choices=GATES)
    parser.add_argument('mode', choices=MODES)
    args = parser.parse_args()
    try:
        native_control(Path(__file__).resolve().parents[2], args.backend, args.mode)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, 'lifecycle-control: ' + str(error) + '\n')


if __name__ == '__main__':
    main()
