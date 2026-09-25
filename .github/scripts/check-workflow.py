#!/usr/bin/env python3
"""Validate the release workflow's parsed structure and required entrypoints."""

from pathlib import Path
import re
import sys

sys.dont_write_bytecode = True
import yaml

CHECKOUT = 'actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09'
UPLOADER = 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02'
JOBS = {'lint', 'unit', 'xray-assets', 'xray-mixed', 'xray-systemd', 'openrc-integration',
        'systemd-assertion-controls', 'openrc-assertion-controls', 'memory-report'}
IMAGES = {'alpine:3.20', 'alpine:3.24'}
MUTATIONS = {'fail', 'skip', 'unreachable', 'swallow'}
RUNNERS = {('ubuntu-24.04', 'amd64'), ('ubuntu-24.04-arm', 'arm64')}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def body(step):
    return '\n'.join(line.strip() for line in step.get('run', '').splitlines()
                     if line.strip() and not line.lstrip().startswith('#')).replace('\\\n', ' ')


def executable_lines(step):
    """Return simple executable lines; reject dead/suppressed required calls.

    Required entrypoints are intentionally standalone commands. Shell constructs
    such as echo, conditionals, &&, ||, substitutions and pipelines are not
    equivalent evidence that the command executes and propagates failure.
    """
    result = []
    for raw in step.get('run', '').splitlines():
        line = raw.strip()
        if not line or line.startswith('#') or line in ('|', '>'):
            continue
        if line.endswith('\\'):
            line = line[:-1].rstrip()
        # A quoted sh -c body is executable; inspect its physical command lines
        # while retaining the same dead/suppressed-form rejection.
        if line.startswith("sh -c '"):
            line = line[7:].strip()
        if line.endswith("'"):
            line = line[:-1].rstrip()
        result.append(line)
    return result


def line_executes(line, command):
    if line == command:
        return True
    # A required command may take a fixed environment-sourced argument. It must
    # still be the command at the start of its own line, with no control operator.
    if line.startswith(command + ' ') and not any(token in line for token in
            (' && ', ' || ', ';', '|', 'if ', 'echo ')):
        return True
    # A leading setup command in a chain is still executed and gates the required
    # command through &&; a required command on the right would be conditional.
    return line.endswith(' && ' + command) and not any(token in line[:-len(command)]
            for token in (' || ', ';', '|', 'if ', 'echo '))


def entry(job, command, step_name=None):
    matches = []
    occurrences = 0
    for step in job['steps']:
        text = body(step)
        lines = executable_lines(step)
        dangerous = any(pattern in text for pattern in (
            'echo ' + command, 'if false; then\n' + command,
            'if false; then ' + command, 'false && ' + command,
            command + ' || true'))
        count = sum(line_executes(line, command) for line in lines)
        # A multiline if false puts the command on an exact physical line, but
        # the enclosing construct still makes it dead.
        if dangerous:
            count = 0
            if command in text:
                occurrences += 1
        else:
            occurrences += count
        if count:
            matches.append(step)
    require(len(matches) == 1 and occurrences == 1,
            'expected one executable entrypoint: ' + command)
    if step_name is not None:
        require(matches[0].get('name') == step_name,
                'entrypoint is in the wrong step: ' + command)
    return matches[0]


def matrix(job, key):
    return job.get('strategy', {}).get('matrix', {}).get(key, [])


def check(workflow):
    jobs = workflow.get('jobs', {})
    require(set(jobs) == JOBS, 'the complete release job set must remain present')
    for name, job in jobs.items():
        require(type(job.get('timeout-minutes')) is int and job['timeout-minutes'] > 0,
                name + ': positive job-level timeout required')
        require('continue-on-error' not in job, name + ': job cannot be non-blocking')
        require(isinstance(job.get('steps'), list) and job['steps'], name + ': steps required')
        require(sum(step.get('uses') == CHECKOUT for step in job['steps']) == 1,
                name + ': exact pinned checkout required')
        for step in job['steps']:
            require('continue-on-error' not in step, name + ': step cannot be non-blocking')
            if 'uses' in step:
                require(step['uses'] in (CHECKOUT, UPLOADER), name + ': action pin changed')
            if 'run' in step:
                require(isinstance(step['run'], str) and body(step) not in ('', 'true', ':'),
                        name + ': executable step required')
                require(not re.search(r'\$\{\{\s*matrix\.', step['run']),
                        name + ': matrix values must enter through env')
    for name in ('xray-assets', 'memory-report'):
        pairs = [(row.get('runner'), row.get('arch')) for row in matrix(jobs[name], 'include')]
        require(len(pairs) == 2 and set(pairs) == RUNNERS, name + ': native architecture matrix changed')
        require(jobs[name]['runs-on'] == '${{ matrix.runner }}', name + ': runner binding changed')
    shells = matrix(jobs['unit'], 'shell')
    require(len(shells) == 4 and {(row.get('runner'), row.get('command')) for row in shells} ==
            {('ubuntu-24.04', shell) for shell in ('sh', 'dash', 'bash', 'busybox sh')},
            'unit: all four shell implementations required')
    require(jobs['unit']['runs-on'] == '${{ matrix.shell.runner }}', 'unit: runner binding changed')
    require(entry(jobs['unit'], 'sh tests/run.sh', 'Unit suite').get('env', {}).get('S5_TEST_SHELL') ==
            '${{ matrix.shell.command }}', 'unit: shell binding changed')
    for name in ('openrc-integration', 'openrc-assertion-controls'):
        images = matrix(jobs[name], 'image')
        require(len(images) == 2 and set(images) == IMAGES, name + ': both Alpine versions required')
        command = ('sh /src/.github/scripts/alpine-lifecycle.sh' if name == 'openrc-integration'
                   else 'python3 .github/scripts/lifecycle-assert-control.py openrc')
        step = entry(jobs[name], command)
        require(step.get('env', {}).get('ALPINE_IMAGE') == '${{ matrix.image }}' and
                '"$ALPINE_IMAGE"' in body(step), name + ': image binding changed')
        require('docker run --rm ' in body(step), name + ': native container entrypoint missing')
    for name, dependency, backend in (('systemd-assertion-controls', 'xray-systemd', 'systemd'),
                                      ('openrc-assertion-controls', 'openrc-integration', 'openrc')):
        choices = matrix(jobs[name], 'mutation')
        require(len(choices) == 4 and set(choices) == MUTATIONS, name + ': assertion controls changed')
        require(jobs[name].get('needs') in (dependency, [dependency]), name + ': healthy gate dependency changed')
        step = entry(jobs[name], 'python3 .github/scripts/lifecycle-assert-control.py ' + backend)
        require(step.get('env', {}).get('ASSERTION_MUTATION') == '${{ matrix.mutation }}' and
                '"$ASSERTION_MUTATION"' in body(step), name + ': mutation binding changed')
        if backend == 'openrc':
            require('docker run --rm --init --privileged' in body(step), 'OpenRC controls require an orphan reaper')
    for name in ('xray-mixed', 'xray-systemd', 'systemd-assertion-controls', 'memory-report'):
        entry(jobs[name], 'sudo sh .github/scripts/add-test-target-addresses.sh')
    entry(jobs['xray-systemd'], 'sh .github/scripts/systemd-lifecycle.sh')
    mixed = body(entry(jobs['xray-mixed'], 'sh tests/protocol/run_xray_mixed.sh'))
    for required in ('duplex_target.py --host 0.0.0.0 --host6 ::', 'sh tests/protocol/start_engine.sh',
                     'test -s "$root/out/ready"', 'lifecycle_write_fixtures "$root"'):
        require(required in mixed, 'mixed gate lost ' + required)
    memory = entry(jobs['memory-report'], 'sh .github/scripts/memory-report.sh')
    require(memory.get('env', {}).get('XRAY_ARCH') == '${{ matrix.arch }}', 'memory: architecture binding changed')
    entry(jobs['memory-report'], 'sudo env GITHUB_ACTIONS=true python3 .github/scripts/memory-peak-check.py --real-cgroup')
    uploads = [step for step in jobs['memory-report']['steps'] if step.get('uses') == UPLOADER]
    require(len(uploads) == 1, 'memory: exact pinned uploader required')
    require(uploads[0].get('with', {}).get('path') == 'memory-comparison-${{ matrix.arch }}.json' and
            uploads[0]['with'].get('name') == 'memory-comparison-${{ matrix.arch }}',
            'memory: only the architecture-specific comparison JSON may be uploaded')
    require(uploads[0]['with'].get('if-no-files-found') == 'error', 'memory: missing artifact must fail')
    lint = jobs['lint']
    entry(lint, 'python3 .github/scripts/check-workflow.py .github/workflows/ci.yml')
    entry(lint, 'python3 tests/lib/workflow_contract_regression.py')
    entry(lint, 'sh .github/scripts/lint-workflow-shell.sh')
    entry(lint, 'python3 tests/protocol/arity_audit.py')
    entry(lint, 'sudo apt-get update && sudo apt-get install -y python3-yaml')
    return len(jobs)


def main():
    try:
        path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path('.github/workflows/ci.yml')
        count = check(yaml.safe_load(path.read_text(encoding='utf-8')))
    except (OSError, ValueError, KeyError, TypeError, yaml.YAMLError) as error:
        print('workflow contract: ' + str(error), file=sys.stderr)
        return 1
    print('workflow contract: jobs=%d' % count)
    return 0


if __name__ == '__main__':
    sys.exit(main())
