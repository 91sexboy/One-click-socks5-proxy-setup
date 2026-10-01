#!/usr/bin/env python3
"""Validate the parsed structure of the CI and publish workflows.

Rules that hold for any workflow here (pinned actions, job timeouts, blocking
steps, least privilege) apply to both files; each file then has its own job set
and entrypoint contract.
"""

from pathlib import Path
import re
import sys

sys.dont_write_bytecode = True
import yaml

CHECKOUT = 'actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09'
UPLOADER = 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02'
DOWNLOADER = 'actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093'
ATTESTER = 'actions/attest-build-provenance@43d14bc2b83dec42d39ecae14e916627a18bb661'
PINNED = re.compile(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}')
PUBLISH_JOBS = {'prepare', 'assemble', 'publish'}
# Only the publishing job may write, and only what releasing and attesting need.
PUBLISH_WRITES = {'contents': 'write', 'id-token': 'write', 'attestations': 'write'}
JOBS = {'lint', 'syntax', 'unit', 'xray-assets', 'xray-mixed', 'xray-systemd', 'openrc-integration',
        'systemd-assertion-controls', 'openrc-assertion-controls', 'memory-report'}
LIFECYCLE_ROWS = {('alpine:3.20', '0', '0'), ('alpine:3.22', '1', '1'),
                  ('alpine:3.24', '0', '0')}
# The mutations prove the assertion calls, which no Alpine version changes.
CONTROL_IMAGES = {'alpine:3.24'}
MUTATIONS = {'fail', 'skip', 'unreachable', 'swallow'}
RUNNERS = {('ubuntu-24.04', 'amd64'), ('ubuntu-24.04-arm', 'arm64')}
# Packages every runner image already ships; installing them again only spends
# time. The jobs that need them confirm them with require-runner-tools.sh.
PREINSTALLED = {'python3', 'curl', 'file', 'iproute2', 'dash', 'bash'}
TOOL_JOBS = ('xray-mixed', 'xray-systemd', 'systemd-assertion-controls', 'memory-report')
SYNTAX = ('sh -n socks5.sh', 'dash -n socks5.sh', 'bash -n socks5.sh', 'busybox sh -n socks5.sh')


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


# A lone & backgrounds the command, so the step ends before it reports and its
# status is never seen. && is a control operator handled separately, and an &
# beside < or > is a redirection such as 2>&1.
BACKGROUND = re.compile(r'(?<![&<>])&(?![&>])')
# An unconditional exit or return before the required line ends the step first.
TERMINATOR = re.compile(r'(exit|return)(\s|;|$)')
OPENERS = ('if ', 'case ', 'while ', 'until ', 'for ')
CLOSERS = ('fi', 'esac', 'done')


def line_executes(line, command):
    if BACKGROUND.search(line):
        return False
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


def live_lines(lines):
    """Drop every line after an unconditional exit or return.

    Only a terminator outside any compound command is unconditional; one inside
    an if, case or loop body leaves the lines after the construct reachable.
    """
    depth = 0
    for line in lines:
        if depth == 0 and TERMINATOR.match(line):
            return
        yield line
        if line.startswith(OPENERS):
            depth += 1
        elif line in CLOSERS or line.startswith(tuple(closer + ' ' for closer in CLOSERS)):
            depth = max(depth - 1, 0)


def entry(job, command, step_name=None):
    matches = []
    occurrences = 0
    for step in job['steps']:
        text = body(step)
        lines = list(live_lines(executable_lines(step)))
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


def triggers(workflow):
    # YAML 1.1 reads a bare `on` key as the boolean true.
    return workflow.get('on', workflow.get(True))


def common(workflow, job_set, actions):
    """The rules every workflow here keeps, whatever its jobs do."""
    jobs = workflow.get('jobs', {})
    require(set(jobs) == job_set, 'the complete job set must remain present')
    require(workflow.get('permissions') == {'contents': 'read'},
            'workflow permissions must default to read-only contents')
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
                require(isinstance(step['uses'], str) and PINNED.fullmatch(step['uses']),
                        name + ': action must be pinned to a commit')
                require(step['uses'] in actions, name + ': action pin changed')
            if 'run' in step:
                require(isinstance(step['run'], str) and body(step) not in ('', 'true', ':'),
                        name + ': executable step required')
                require(not re.search(r'\$\{\{\s*matrix\.', step['run']),
                        name + ': matrix values must enter through env')
    return jobs


def check_publish(workflow):
    jobs = common(workflow, PUBLISH_JOBS, (CHECKOUT, UPLOADER, DOWNLOADER, ATTESTER))
    require(triggers(workflow) == {'workflow_dispatch': None},
            'publish: only a manual dispatch may publish')
    require(workflow.get('concurrency', {}).get('cancel-in-progress') is False,
            'publish: a running publication must never be cancelled')
    for name in ('prepare', 'assemble'):
        require('permissions' not in jobs[name], name + ': build job must stay read-only')
    for name, job in jobs.items():
        checkout = next(step for step in job['steps'] if step.get('uses') == CHECKOUT)
        require(checkout.get('with', {}).get('persist-credentials') is False,
                name + ': checkout must not persist the token')
    for command in ('sh .github/scripts/publish-release.sh claim',
                    'sh .github/scripts/publish-release.sh upload',
                    'sh .github/scripts/publish-release.sh publish'):
        entry(jobs['publish'], command)
    require(jobs['publish'].get('permissions') == PUBLISH_WRITES,
            'publish: write permissions changed')
    return len(jobs)


def check(workflow):
    jobs = common(workflow, JOBS, (CHECKOUT, UPLOADER))
    on = triggers(workflow)
    require(isinstance(on, dict) and set(on) == {'push', 'pull_request', 'workflow_dispatch'} and
            on['push'] == {'branches': ['xray-only']},
            'ci: push must cover only the primary branch, beside pull_request')
    require(workflow.get('concurrency') == {
        'group': 'ci-${{ github.ref }}',
        'cancel-in-progress': "${{ github.event_name == 'pull_request' }}"},
        'ci: superseded PR runs must be cancelled, primary-branch runs kept')
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
    lifecycle_rows = [(row.get('image'), row.get('hostile_curl'), row.get('quota_blind'))
                      for row in matrix(jobs['openrc-integration'], 'include')]
    require(len(lifecycle_rows) == len(LIFECYCLE_ROWS) and set(lifecycle_rows) == LIFECYCLE_ROWS,
            'openrc-integration: required Alpine lifecycle rows changed')
    lifecycle_step = entry(jobs['openrc-integration'],
                           'sh /src/.github/scripts/alpine-lifecycle.sh')
    require(lifecycle_step.get('env', {}).get('ALPINE_IMAGE') == '${{ matrix.image }}' and
            lifecycle_step.get('env', {}).get('ALPINE_HOSTILE_CURL') ==
            '${{ matrix.hostile_curl }}' and
            lifecycle_step.get('env', {}).get('ALPINE_QUOTA_BLIND') ==
            '${{ matrix.quota_blind }}' and '"$ALPINE_IMAGE"' in body(lifecycle_step),
            'openrc-integration: matrix bindings changed')
    # Its own message: a job-level binding the container never receives leaves the
    # hostile row running the ordinary gate, and that must not read as a binding.
    require('-e ALPINE_HOSTILE_CURL="$ALPINE_HOSTILE_CURL"' in body(lifecycle_step),
            'openrc-integration: hostile curl flag not forwarded to the container')
    require('-e ALPINE_QUOTA_BLIND="$ALPINE_QUOTA_BLIND"' in body(lifecycle_step),
            'openrc-integration: quota-blind flag not forwarded to the container')
    require('docker run --rm ' in body(lifecycle_step),
            'openrc-integration: native container entrypoint missing')
    control_images = matrix(jobs['openrc-assertion-controls'], 'image')
    require(len(control_images) == len(CONTROL_IMAGES) and set(control_images) == CONTROL_IMAGES,
            'openrc-assertion-controls: required Alpine versions changed')
    control_step = entry(jobs['openrc-assertion-controls'],
                         'python3 .github/scripts/lifecycle-assert-control.py openrc')
    require(control_step.get('env', {}).get('ALPINE_IMAGE') == '${{ matrix.image }}' and
            '"$ALPINE_IMAGE"' in body(control_step),
            'openrc-assertion-controls: image binding changed')
    require('docker run --rm ' in body(control_step),
            'openrc-assertion-controls: native container entrypoint missing')
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
    for required in ('lifecycle_start_duplex_target "$root"', 'sh tests/protocol/start_engine.sh',
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
    for name, job in jobs.items():
        for step in job['steps']:
            for packages in re.findall(r'apt-get install -y ([^\n&|;]+)', step.get('run', '')):
                again = PREINSTALLED & set(packages.split())
                require(not again, name + ': reinstalls preinstalled ' + ' '.join(sorted(again)))
    for name in TOOL_JOBS:
        entry(jobs[name], 'sh .github/scripts/require-runner-tools.sh')
    for command in SYNTAX:
        entry(jobs['syntax'], command, 'Syntax')
    require(not any(step.get('name') == 'Syntax' for step in jobs['unit']['steps']),
            'unit: syntax runs once, in its own job')
    lint = jobs['lint']
    entry(lint, 'python3 .github/scripts/check-workflow.py .github/workflows/ci.yml')
    entry(lint, 'python3 .github/scripts/check-workflow.py .github/workflows/publish-xray-raw.yml')
    entry(lint, 'python3 tests/lib/workflow_contract_regression.py')
    entry(lint, 'sh .github/scripts/lint-workflow-shell.sh')
    entry(lint, 'python3 tests/protocol/arity_audit.py')
    entry(lint, 'sudo apt-get update && sudo apt-get install -y python3-yaml')
    return len(jobs)


def main():
    try:
        path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path('.github/workflows/ci.yml')
        workflow = yaml.safe_load(path.read_text(encoding='utf-8'))
        profiles = {'xray-only-ci': check, 'publish-xray-raw': check_publish}
        require(isinstance(workflow, dict) and workflow.get('name') in profiles,
                'unknown workflow name')
        count = profiles[workflow['name']](workflow)
    except (OSError, ValueError, KeyError, TypeError, yaml.YAMLError) as error:
        print('workflow contract: ' + str(error), file=sys.stderr)
        return 1
    print('workflow contract: jobs=%d' % count)
    return 0


if __name__ == '__main__':
    sys.exit(main())
