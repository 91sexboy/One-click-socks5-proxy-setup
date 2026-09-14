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
            'control-needs': lambda jobs: jobs['systemd-assertion-controls'].pop('needs'),
            'upload-path': lambda jobs: jobs['memory-report']['steps'][-1]['with'].update({'path': '**/*'}),
            'upload-missing': lambda jobs: jobs['memory-report']['steps'][-1]['with'].update({'if-no-files-found': 'warn'}),
            'memory-env': lambda jobs: next(step for step in jobs['memory-report']['steps'] if step.get('name') == 'Measure Xray process and cgroup memory')['env'].update({'XRAY_ARCH': 'amd64'}),
            'container-env': lambda jobs: next(step for step in jobs['openrc-integration']['steps'] if 'run' in step)['env'].update({'ALPINE_IMAGE': 'alpine:3.20'}),
        }
        for label, mutate in mutations.items():
            with self.subTest(mutation=label):
                changed = copy.deepcopy(self.workflow)
                mutate(changed['jobs'])
                result = self.run_oracle(changed)
                self.assertNotEqual(result.returncode, 0, label)
                self.assertIn('workflow contract:', result.stderr)


if __name__ == '__main__':
    unittest.main()
