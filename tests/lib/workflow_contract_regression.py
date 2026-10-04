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
                         '  -e ALPINE_HOSTILE_CURL="$ALPINE_HOSTILE_CURL" "$ALPINE_IMAGE" \\\n'
                         '  sh /src/.github/scripts/alpine-lifecycle.sh\n')


BOUNDED_ENGINE_WAIT = 'lifecycle_wait_until 600 0.2 lifecycle_ready_or_exited "$root/out/ready" "$engine_pid"'


def unbound_engine_wait(jobs):
    # The same predicate in a hand loop has no attempt bound.
    step = next(step for step in jobs['xray-mixed']['steps'] if 'start_engine.sh' in step.get('run', ''))
    step['run'] = step['run'].replace(
        BOUNDED_ENGINE_WAIT,
        'while ! lifecycle_ready_or_exited "$root/out/ready" "$engine_pid"; do sleep 0.2; done')


def on(workflow):
    # YAML 1.1 loads a bare `on` key as True.
    return workflow[True]


class WorkflowContractTests(unittest.TestCase):
    def setUp(self):
        self.workflow = yaml.safe_load((ROOT / '.github/workflows/ci.yml').read_text())
        self.publish = yaml.safe_load((ROOT / '.github/workflows/publish-xray-raw.yml').read_text())

    def run_oracle(self, workflow):
        with tempfile.TemporaryDirectory(prefix='s5-workflow-') as directory:
            path = Path(directory) / 'workflow.yml'
            path.write_text(yaml.safe_dump(workflow, sort_keys=False))
            command = [sys.executable] + ([] if __debug__ else ['-O'])
            return subprocess.run(command + [str(ROOT / '.github/scripts/check-workflow.py'), str(path)],
                                  capture_output=True, text=True, timeout=10)

    def assert_rejected(self, workflow, label, message):
        result = self.run_oracle(workflow)
        self.assertNotEqual(result.returncode, 0, label)
        # The exact reason: a mutation rejected for an unrelated clause proves
        # nothing about the clause it was written to falsify.
        self.assertIn('workflow contract: ' + message + '\n', result.stderr, label)

    def test_equivalent_yaml_formatting_is_accepted(self):
        for workflow in (self.workflow, self.publish):
            result = self.run_oracle(workflow)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_ci_triggers_and_concurrency(self):
        mutations = {
            'push-every-branch': (lambda w: on(w).update({'push': {'branches': ['**']}}),
                                  'ci: push must cover only the primary branch, beside pull_request'),
            'no-pull-request': (lambda w: on(w).pop('pull_request'),
                                'ci: push must cover only the primary branch, beside pull_request'),
            'no-concurrency': (lambda w: w.pop('concurrency'),
                               'ci: superseded PR runs must be cancelled, primary-branch runs kept'),
            'cancel-primary': (lambda w: w['concurrency'].update({'cancel-in-progress': True}),
                               'ci: superseded PR runs must be cancelled, primary-branch runs kept'),
            'write-default': (lambda w: w.update({'permissions': {'contents': 'write'}}),
                              'workflow permissions must default to read-only contents'),
        }
        for label, (mutate, message) in mutations.items():
            with self.subTest(mutation=label):
                changed = copy.deepcopy(self.workflow)
                mutate(changed)
                self.assert_rejected(changed, label, message)

    def test_publish_workflow_shares_the_generic_rules(self):
        def step(workflow, job, uses):
            return next(item for item in workflow['jobs'][job]['steps']
                        if item.get('uses', '').startswith(uses))
        mutations = {
            'unpinned-action': (lambda w: step(w, 'publish', 'actions/download-artifact').update(
                {'uses': 'actions/download-artifact@v4'}), 'publish: action must be pinned to a commit'),
            'foreign-action': (lambda w: step(w, 'publish', 'actions/download-artifact').update(
                {'uses': 'someone/else@' + '1' * 40}), 'publish: action pin changed'),
            'no-timeout': (lambda w: w['jobs']['prepare'].pop('timeout-minutes'),
                           'prepare: positive job-level timeout required'),
            'job-escape': (lambda w: w['jobs']['publish'].update({'continue-on-error': True}),
                           'publish: job cannot be non-blocking'),
            'step-escape': (lambda w: w['jobs']['prepare']['steps'][-1].update({'continue-on-error': True}),
                            'prepare: step cannot be non-blocking'),
            'build-writes': (lambda w: w['jobs']['prepare'].update({'permissions': {'contents': 'write'}}),
                             'prepare: build job must stay read-only'),
            'assemble-writes': (lambda w: w['jobs']['assemble'].update({'permissions': {'contents': 'write'}}),
                                'assemble: build job must stay read-only'),
            'persisted-token': (lambda w: step(w, 'publish', 'actions/checkout').pop('with'),
                                'publish: checkout must not persist the token'),
            'dropped-publish': (lambda w: w['jobs']['publish']['steps'][-1].update(
                {'run': 'echo sh .github/scripts/publish-release.sh publish'}),
                'expected one executable entrypoint: sh .github/scripts/publish-release.sh publish'),
            'extra-write': (lambda w: w['jobs']['publish']['permissions'].update({'packages': 'write'}),
                            'publish: write permissions changed'),
            'push-trigger': (lambda w: on(w).update({'push': None}),
                             'publish: only a manual dispatch may publish'),
            'cancellable': (lambda w: w['concurrency'].update({'cancel-in-progress': True}),
                            'publish: a running publication must never be cancelled'),
            'missing-job': (lambda w: w['jobs'].pop('prepare'), 'the complete job set must remain present'),
        }
        for label, (mutate, message) in mutations.items():
            with self.subTest(mutation=label):
                changed = copy.deepcopy(self.publish)
                mutate(changed)
                self.assert_rejected(changed, label, message)

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
            'lifecycle-hostile-flag': lambda jobs: jobs['openrc-integration']['strategy']['matrix']['include'][1].update({'hostile_curl': '0'}),
            'lifecycle-quota-flag': lambda jobs: jobs['openrc-integration']['strategy']['matrix']['include'][1].update({'quota_blind': '0'}),
            'control-needs': lambda jobs: jobs['systemd-assertion-controls'].pop('needs'),
            'upload-path': lambda jobs: jobs['memory-report']['steps'][-1]['with'].update({'path': '**/*'}),
            'upload-missing': lambda jobs: jobs['memory-report']['steps'][-1]['with'].update({'if-no-files-found': 'warn'}),
            'memory-env': lambda jobs: next(step for step in jobs['memory-report']['steps'] if step.get('name') == 'Measure Xray process and cgroup memory')['env'].update({'XRAY_ARCH': 'amd64'}),
            'container-env': lambda jobs: next(step for step in jobs['openrc-integration']['steps'] if 'run' in step)['env'].update({'ALPINE_IMAGE': 'alpine:3.20'}),
            'hostile-container-env': lambda jobs: next(step for step in jobs['openrc-integration']['steps'] if 'run' in step)['env'].pop('ALPINE_HOSTILE_CURL'),
            'quota-container-env': lambda jobs: next(step for step in jobs['openrc-integration']['steps'] if 'run' in step)['env'].pop('ALPINE_QUOTA_BLIND'),
            'hostile-container-forward': lambda jobs: next(step for step in jobs['openrc-integration']['steps'] if 'run' in step).update({'run': UNFORWARDED_RUN}),
            'quota-container-forward': lambda jobs: next(step for step in jobs['openrc-integration']['steps'] if 'run' in step).update({'run': UNFORWARDED_QUOTA_RUN}),
            'unbounded-engine-wait': unbound_engine_wait,
            'reinstall': lambda jobs: jobs['xray-mixed']['steps'].insert(1, {'name': 'Install', 'run': 'sudo apt-get update && sudo apt-get install -y python3 curl'}),
            'runner-tools': lambda jobs: jobs['memory-report']['steps'].pop(1),
            'syntax-per-leg': lambda jobs: jobs['unit']['steps'].insert(1, {'name': 'Syntax', 'run': 'sh -n socks5.sh'}),
            'syntax-shell': lambda jobs: next(step for step in jobs['syntax']['steps'] if step.get('name') == 'Syntax').update({'run': 'sh -n socks5.sh\ndash -n socks5.sh\nbash -n socks5.sh'}),
        }
        # A mutation rejected for an unrelated reason proves nothing about the
        # clause it targets, which is how a collapsed container command passed
        # here while never reaching the forwarding it was written to falsify.
        messages = {
            'timeout': 'unit: positive job-level timeout required',
            'boolean-timeout': 'unit: positive job-level timeout required',
            'action-sha': 'unit: exact pinned checkout required',
            'memory-runner': 'memory-report: native architecture matrix changed',
            'runner-binding': 'memory-report: runner binding changed',
            'missing-job': 'the complete job set must remain present',
            'job-escape': 'unit: job cannot be non-blocking',
            'step-escape': 'unit: step cannot be non-blocking',
            'disabled-entrypoint': 'unit: executable step required',
            'shell-binding': 'unit: shell binding changed',
            'control-mutation': 'openrc-assertion-controls: assertion controls changed',
            'control-image': 'openrc-assertion-controls: required Alpine versions changed',
            'lifecycle-image': 'openrc-integration: required Alpine lifecycle rows changed',
            'control-needs': 'systemd-assertion-controls: healthy gate dependency changed',
            'upload-path': 'memory: only the architecture-specific comparison JSON may be uploaded',
            'upload-missing': 'memory: missing artifact must fail',
            'memory-env': 'memory: architecture binding changed',
            'container-env': 'openrc-integration: matrix bindings changed',
            'lifecycle-hostile-flag': 'openrc-integration: required Alpine lifecycle rows changed',
            'lifecycle-quota-flag': 'openrc-integration: required Alpine lifecycle rows changed',
            'hostile-container-env': 'openrc-integration: matrix bindings changed',
            'quota-container-env': 'openrc-integration: matrix bindings changed',
            'hostile-container-forward':
                'openrc-integration: hostile curl flag not forwarded to the container',
            'quota-container-forward':
                'openrc-integration: quota-blind flag not forwarded to the container',
            'unbounded-engine-wait': 'mixed gate lost ' + BOUNDED_ENGINE_WAIT,
            'reinstall': 'xray-mixed: reinstalls preinstalled curl python3',
            'runner-tools': 'expected one executable entrypoint: sh .github/scripts/require-runner-tools.sh',
            'syntax-per-leg': 'unit: syntax runs once, in its own job',
            'syntax-shell': 'expected one executable entrypoint: busybox sh -n socks5.sh',
        }
        self.assertEqual(set(messages), set(mutations))
        for label, mutate in mutations.items():
            with self.subTest(mutation=label):
                changed = copy.deepcopy(self.workflow)
                mutate(changed['jobs'])
                self.assert_rejected(changed, label, messages[label])

    def test_textual_noop_entrypoints_are_rejected(self):
        mutations = {
            'echo': 'echo sh tests/run.sh',
            'comment': '# sh tests/run.sh\ntrue',
            'unreachable': 'if false; then\n  sh tests/run.sh\nfi',
            'and-dead': 'false && sh tests/run.sh',
            'swallowed': 'sh tests/run.sh || true',
            'duplicate': 'sh tests/run.sh\nsh tests/run.sh',
            'background': 'sh tests/run.sh &',
            'background-env': 'sh tests/run.sh >log 2>&1 &',
            'exit-before': 'exit 0\nsh tests/run.sh',
            'return-before': 'return\nsh tests/run.sh',
            'wrong-step': 'sh tests/run.sh',
        }
        for label, replacement in mutations.items():
            with self.subTest(mutation=label):
                changed = copy.deepcopy(self.workflow)
                step = next(step for step in changed['jobs']['unit']['steps']
                            if 'sh tests/run.sh' in step.get('run', ''))
                if label == 'wrong-step':
                    other = next(item for item in changed['jobs']['unit']['steps']
                                 if item.get('name') == 'Install BusyBox')
                    other['run'] = replacement
                    step['run'] = 'printf "unit suite displaced\n"'
                else:
                    step['run'] = replacement
                message = {'wrong-step': 'entrypoint is in the wrong step: sh tests/run.sh',
                           'comment': 'unit: executable step required'}.get(
                               label, 'expected one executable entrypoint: sh tests/run.sh')
                self.assert_rejected(changed, label, message)

    def test_conditional_exit_does_not_hide_live_entrypoint(self):
        # Only an unconditional terminator makes the lines after it dead.
        changed = copy.deepcopy(self.workflow)
        step = next(step for step in changed['jobs']['unit']['steps']
                    if 'sh tests/run.sh' in step.get('run', ''))
        step['run'] = 'if ! command -v sh; then\n  exit 1\nfi\nsh tests/run.sh 2>&1'
        result = self.run_oracle(changed)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_unrelated_dead_branch_does_not_hide_live_entrypoint(self):
        changed = copy.deepcopy(self.workflow)
        step = next(step for step in changed['jobs']['unit']['steps']
                    if 'sh tests/run.sh' in step.get('run', ''))
        step['run'] = 'if false; then\n  echo unrelated\nfi\nsh tests/run.sh'
        result = self.run_oracle(changed)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
