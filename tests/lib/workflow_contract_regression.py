#!/usr/bin/env python3
"""Mutation checks for the parsed workflow contract; run only in the lint job."""

import copy
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
import yaml

ROOT = Path(__file__).resolve().parents[2]

# Dropping the -e forwarding has to keep the command's physical shape: collapsed
# onto one line the entrypoint is no longer a standalone line, so the oracle
# rejects it for a missing entrypoint and never reaches the forwarding clause.
UNFORWARDED_RUN = ('docker run --rm --privileged -v "$PWD:/src" -w /src \\\n'
                   '  -e ALPINE_QUOTA_BLIND="$ALPINE_QUOTA_BLIND" "$ALPINE_IMAGE" \\\n'
                   '  sh /src/.github/scripts/alpine-lifecycle.sh\n')

UNFORWARDED_QUOTA_RUN = ('docker run --rm --privileged -v "$PWD:/src" -w /src \\\n'
                         '  -e ALPINE_HOSTILE_UNZIP="$ALPINE_HOSTILE_UNZIP" "$ALPINE_IMAGE" \\\n'
                         '  sh /src/.github/scripts/alpine-lifecycle.sh\n')


class WorkflowContractTests(unittest.TestCase):
    def setUp(self):
        self.workflow = yaml.safe_load((ROOT / '.github/workflows/ci.yml').read_text())

    def run_oracle(self, workflow):
        with tempfile.TemporaryDirectory(prefix='s5-workflow-') as directory:
            path = Path(directory) / 'ci.yml'
            path.write_text(yaml.safe_dump(workflow, sort_keys=False))
            command = [sys.executable] + ([] if __debug__ else ['-O'])
            return subprocess.run(command + [str(ROOT / '.github/scripts/check-workflow.py'), str(path)],
                                  capture_output=True, text=True, timeout=10)

    def test_equivalent_yaml_formatting_is_accepted(self):
        result = self.run_oracle(self.workflow)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_missing_or_weakened_contract_is_rejected(self):
        mutations = {
            'timeout': lambda jobs: jobs['unit'].pop('timeout-minutes'),
            'boolean-timeout': lambda jobs: jobs['unit'].update({'timeout-minutes': True}),
            'action-sha': lambda jobs: jobs['unit']['steps'][0].update({'uses': 'actions/checkout@' + '0' * 40}),
            'memory-runner': lambda jobs: jobs['memory-report']['strategy']['matrix']['include'].pop(),
            'runner-binding': lambda jobs: jobs['memory-report'].update({'runs-on': 'ubuntu-24.04'}),
            'missing-job': lambda jobs: jobs.pop('xray-systemd'),
            'job-escape': lambda jobs: jobs['unit'].update({'continue-on-error': False}),
            'step-escape': lambda jobs: jobs['unit']['steps'][-1].update({'continue-on-error': True}),
            'disabled-entrypoint': lambda jobs: jobs['unit']['steps'][-1].update({'run': 'true'}),
            'shell-binding': lambda jobs: jobs['unit']['steps'][-1]['env'].update({'S5_TEST_SHELL': 'sh'}),
            'control-mutation': lambda jobs: jobs['openrc-assertion-controls']['strategy']['matrix']['mutation'].pop(),
            'control-image': lambda jobs: jobs['openrc-assertion-controls']['strategy']['matrix']['image'].pop(),
            'lifecycle-image': lambda jobs: jobs['openrc-integration']['strategy']['matrix']['include'].pop(),
            'lifecycle-hostile-flag': lambda jobs: jobs['openrc-integration']['strategy']['matrix']['include'][1].update({'hostile_unzip': '0'}),
            'lifecycle-quota-flag': lambda jobs: jobs['openrc-integration']['strategy']['matrix']['include'][1].update({'quota_blind': '0'}),
            'control-needs': lambda jobs: jobs['systemd-assertion-controls'].pop('needs'),
            'upload-path': lambda jobs: jobs['memory-report']['steps'][-1]['with'].update({'path': '**/*'}),
            'upload-missing': lambda jobs: jobs['memory-report']['steps'][-1]['with'].update({'if-no-files-found': 'warn'}),
            'memory-env': lambda jobs: next(step for step in jobs['memory-report']['steps'] if step.get('name') == 'Measure Xray process and cgroup memory')['env'].update({'XRAY_ARCH': 'amd64'}),
            'container-env': lambda jobs: next(step for step in jobs['openrc-integration']['steps'] if 'run' in step)['env'].update({'ALPINE_IMAGE': 'alpine:3.20'}),
            'hostile-container-env': lambda jobs: next(step for step in jobs['openrc-integration']['steps'] if 'run' in step)['env'].pop('ALPINE_HOSTILE_UNZIP'),
            'quota-container-env': lambda jobs: next(step for step in jobs['openrc-integration']['steps'] if 'run' in step)['env'].pop('ALPINE_QUOTA_BLIND'),
            'hostile-container-forward': lambda jobs: next(step for step in jobs['openrc-integration']['steps'] if 'run' in step).update({'run': UNFORWARDED_RUN}),
            'quota-container-forward': lambda jobs: next(step for step in jobs['openrc-integration']['steps'] if 'run' in step).update({'run': UNFORWARDED_QUOTA_RUN}),
        }
        # A mutation rejected for an unrelated reason proves nothing about the
        # clause it targets, which is how a collapsed container command passed
        # here while never reaching the forwarding it was written to falsify.
        messages = {
            'lifecycle-hostile-flag': 'openrc-integration: required Alpine lifecycle rows changed',
            'lifecycle-quota-flag': 'openrc-integration: required Alpine lifecycle rows changed',
            'hostile-container-env': 'openrc-integration: matrix bindings changed',
            'quota-container-env': 'openrc-integration: matrix bindings changed',
            'hostile-container-forward':
                'openrc-integration: hostile unzip flag not forwarded to the container',
            'quota-container-forward':
                'openrc-integration: quota-blind flag not forwarded to the container',
        }
        for label, mutate in mutations.items():
            with self.subTest(mutation=label):
                changed = copy.deepcopy(self.workflow)
                mutate(changed['jobs'])
                result = self.run_oracle(changed)
                self.assertNotEqual(result.returncode, 0, label)
                self.assertIn('workflow contract: ' + messages.get(label, ''), result.stderr)

    def test_textual_noop_entrypoints_are_rejected(self):
        mutations = {
            'echo': 'echo sh tests/run.sh',
            'comment': '# sh tests/run.sh\ntrue',
            'unreachable': 'if false; then\n  sh tests/run.sh\nfi',
            'and-dead': 'false && sh tests/run.sh',
            'swallowed': 'sh tests/run.sh || true',
            'duplicate': 'sh tests/run.sh\nsh tests/run.sh',
            'wrong-step': 'sh tests/run.sh',
        }
        for label, replacement in mutations.items():
            with self.subTest(mutation=label):
                changed = copy.deepcopy(self.workflow)
                step = next(step for step in changed['jobs']['unit']['steps']
                            if 'sh tests/run.sh' in step.get('run', ''))
                if label == 'wrong-step':
                    syntax = next(item for item in changed['jobs']['unit']['steps']
                                  if item.get('name') == 'Syntax')
                    syntax['run'] = replacement
                    step['run'] = 'printf "unit suite displaced\n"'
                else:
                    step['run'] = replacement
                result = self.run_oracle(changed)
                self.assertNotEqual(result.returncode, 0, label)
                self.assertIn('workflow contract:', result.stderr)

    def test_unrelated_dead_branch_does_not_hide_live_entrypoint(self):
        changed = copy.deepcopy(self.workflow)
        step = next(step for step in changed['jobs']['unit']['steps']
                    if 'sh tests/run.sh' in step.get('run', ''))
        step['run'] = 'if false; then\n  echo unrelated\nfi\nsh tests/run.sh'
        result = self.run_oracle(changed)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
