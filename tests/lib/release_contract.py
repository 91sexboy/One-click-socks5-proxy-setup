#!/usr/bin/env python3
"""Check release declarations, not arbitrary hex strings in test fixtures."""

import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile

# Official v26.3.27 digest sidecars, checked against downloaded archives and
# their extracted xray members; intentionally independent of production data.
VERSION = 'v26.3.27'
COMMIT = 'd2758a023cd7f4174a5a5fa4ff66e487d4342ba0'
BASE = 'https://github.com/91sexboy/One-click-socks5-proxy-setup/releases/download/'
SOURCE_DISTRIBUTION_TAG = 'xray-v26.3.27'
DISTRIBUTION_TAG = 'xray-v26.3.27-r1'
PINS = {
    'amd64': {
        'asset': 'Xray-linux-64.zip',
        'size': '21136402',
        'sha': '23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae',
        'binary_size': '36577406',
        'binary_sha': '8255dd939c34cf966cc91517b6324dd3c8d0bcf49ffac8beca049a38c46845ed',
    },
    'arm64': {
        'asset': 'Xray-linux-arm64-v8a.zip',
        'size': '19716427',
        'sha': '4d30283ae614e3057f730f67cd088a42be6fdf91f8639d82cb69e48cde80413c',
        'binary_size': '34209918',
        'binary_sha': 'c2d20a7045250497083afea0d79db0672f6c89a25aaaf37c92de034d6b764b04',
    },
}
SC_URL = ('https://github.com/koalaman/shellcheck/releases/download/'
          'v0.10.0/shellcheck-v0.10.0.linux.x86_64.tar.xz')
SC_SHA = '6c881ab0698e4e6ea235245f22832860544f17ba386442fe7e9d629f8cbedf87'

RAW_ASSETS = {
    'amd64': ('xray-v26.3.27-linux-amd64', PINS['amd64']['binary_size'], PINS['amd64']['binary_sha']),
    'arm64': ('xray-v26.3.27-linux-arm64', PINS['arm64']['binary_size'], PINS['arm64']['binary_sha']),
}
RAW_PAYLOAD = {
    'xray-v26.3.27-linux-amd64', 'xray-v26.3.27-linux-arm64',
    'xray-v26.3.27-SHA256SUMS', 'xray-v26.3.27-PROVENANCE.json',
    'xray-v26.3.27-LICENSE.txt',
}

# Each entry is required, including positive metadata assertions in the asset
# test. Readers reject missing, duplicate and unrecognizable declarations.
FILES = ('socks5.sh', '.github/workflows/ci.yml',
         'tests/protocol/start_engine.sh', 'tests/unit/test_xray_asset.sh')

# The amd64 binary pins are mirrored outside FILES as well: both native lifecycle
# gates re-check the installed bytes from outside the installer, and the docs test
# requires that they do. Nothing derives those literals, so a bump that misses one
# leaves stale bytes that fail as a lifecycle mystery rather than a pin mismatch.
PIN_MIRRORS = ('.github/scripts/alpine-lifecycle.sh',
               '.github/scripts/systemd-lifecycle.sh',
               'tests/unit/test_xray_workflow.sh')


class ContractError(ValueError):
    pass


def require(condition, label):
    if not condition:
        raise ContractError(label)


def one(pattern, text, label):
    matches = re.findall(pattern, text, re.MULTILINE | re.DOTALL)
    require(len(matches) == 1, label + ': expected one recognizable declaration')
    return matches[0]


def assignments(text, names):
    result = {}
    for name in names:
        rhs = one(r'^\s*' + re.escape(name) + r'=([^\n]*)$', text, name)
        tokens = shlex.split(rhs, comments=True)
        require(len(tokens) == 1, name + ': expected a literal assignment')
        result[name] = tokens[0]
    return result


def release_url(text, tag, asset):
    active = '\n'.join(line for line in text.splitlines()
                       if not line.lstrip().startswith('#'))
    urls = re.findall(r'https?://[^\s"\']+', active)
    require(urls == [BASE + tag + '/' + asset],
            'Xray download URL: wrong mirror, tag or fallback')


def check_installer(root, shell):
    values = assignments((root / 'socks5.sh').read_text(),
                         ['S5_XRAY_DISTRIBUTION_TAG', 'S5_XRAY_BASE'])
    require(values == {
        'S5_XRAY_DISTRIBUTION_TAG': DISTRIBUTION_TAG,
        'S5_XRAY_BASE': BASE + '$S5_XRAY_DISTRIBUTION_TAG'},
        'installer: wrong or duplicate distribution base')
    script = r'''
. "$1/socks5.sh" || exit 1
S5_LANG=en
S5_ARCHNAME=$2
S5_ASSET_NAME= S5_ASSET_SIZE= S5_ASSET_SHA256=
s5_asset_select || exit 1
printf '%s\n' "$S5_XRAY_VERSION" "$S5_XRAY_COMMIT" "$S5_XRAY_DISTRIBUTION_TAG" "$S5_XRAY_BASE" \
    "$S5_ASSET_NAME" "$S5_ASSET_SIZE" "$S5_ASSET_SHA256"
: >"$S5_TEST_ROOT/curl.calls"
s5_curl_command() { printf '%s\n' curl-call "$@" >>"$S5_TEST_ROOT/curl.calls"; return 1; }
_fetch_status=0
s5_fetch_binary "$S5_TEST_ROOT/candidate" >/dev/null 2>&1 || _fetch_status=$?
printf 'fetch-status=%s\n' "$_fetch_status"
cat "$S5_TEST_ROOT/curl.calls"
'''
    with tempfile.TemporaryDirectory(prefix='s5-pin-selector-') as directory:
        Path(directory, '.s5-test-root').touch()
        env = dict(os.environ, S5_LIB_ONLY='1', S5_TEST_MODE='1',
                   S5_TEST_ROOT=directory, S5_ASSUME_ROOT='1', S5_SKIP_OWNERSHIP='1')
        env.pop('S5_TEST_ASSET_PATH', None)
        for arch in PINS:
            raw_name, raw_size, raw_sha = RAW_ASSETS[arch]
            result = subprocess.run(
                shlex.split(shell) + ['-c', script, 'release-contract', str(root), arch],
                env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                timeout=15, check=False)
            expected = [VERSION, COMMIT, DISTRIBUTION_TAG, BASE + DISTRIBUTION_TAG,
                        raw_name, raw_size, raw_sha]
            expected += ['fetch-status=1', 'curl-call', '-q', '-fsSL', '--proto', '=https',
                         '--proto-redir', '=https', '--max-time', '120', '--max-filesize',
                         str(int(raw_size) + 1), '-o', directory + '/candidate',
                         BASE + DISTRIBUTION_TAG + '/' + raw_name]
            require(result.returncode == 0 and result.stdout.splitlines() == expected,
                    'installer ' + arch + ': selector or download contract differs')


def check_workflow(text):
    job = one(r'^  xray-assets:\n(.*?)(?=^  [a-z][a-z0-9-]*:|\Z)',
              text, 'asset job')
    matrix = one(r'^        include:\n(.*?)(?=^    steps:)', job, 'asset matrix')
    rows = []
    for line in matrix.splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        match = re.fullmatch(r'          (- |  )([a-z_]+): ([A-Za-z0-9_.-]+)', line)
        require(match is not None, 'asset matrix: unrecognized literal row')
        prefix, key, value = match.groups()
        if prefix == '- ':
            rows.append({})
        require(rows and key not in rows[-1], 'asset matrix: duplicate or misplaced key')
        rows[-1][key] = value
    expected = []
    for arch, pins in PINS.items():
        raw_name, raw_size, raw_sha = RAW_ASSETS[arch]
        expected.append({
            'runner': 'ubuntu-24.04' if arch == 'amd64' else 'ubuntu-24.04-arm',
            'arch': arch, 'source_asset': pins['asset'], 'source_size': pins['size'],
            'source_sha': pins['sha'], 'asset': raw_name, 'size': raw_size,
            'sha': raw_sha, 'elf_arch': 'x86-64' if arch == 'amd64' else 'aarch64'})
    require(rows == expected, 'asset matrix: incomplete, duplicate or mismatched metadata')
    for name, key in [('SOURCE_ASSET', 'source_asset'), ('SOURCE_SIZE', 'source_size'),
                      ('SOURCE_SHA', 'source_sha'), ('ASSET', 'asset'), ('SIZE', 'size'),
                      ('SHA', 'sha'), ('ELF_ARCH', 'elf_arch')]:
        value = one(r'^          XRAY_' + name + r': ([^\n]+)$', job, 'XRAY_' + name)
        require(value == '${{ matrix.' + key + ' }}', 'XRAY_' + name + ': wrong matrix binding')
    active = '\n'.join(line for line in job.splitlines()
                       if not line.lstrip().startswith('#'))
    urls = re.findall(r'https?://[^\s"\']+', active)
    require(urls == [
        'https://github.com/XTLS/Xray-core/releases/download/' + VERSION + '/$XRAY_SOURCE_ASSET',
        BASE + SOURCE_DISTRIBUTION_TAG + '/$XRAY_SOURCE_ASSET',
        BASE + DISTRIBUTION_TAG + '/$XRAY_ASSET'],
        'asset workflow: wrong upstream, mirror or raw distribution URL')
    require(assignments(text, ['SC_URL', 'SC_SHA']) == {'SC_URL': SC_URL, 'SC_SHA': SC_SHA},
            'ShellCheck: URL or digest differs')


def check_launcher(text):
    block = one(r'^case "\$ARCH" in\n(.*?)^esac$', text, 'launcher architecture case')
    for arch in PINS:
        raw_name, raw_size, raw_sha = RAW_ASSETS[arch]
        body = one(r'^' + arch + r'\)\n(.*?)^    ;;$', block, 'launcher ' + arch)
        require(assignments(body, ['ASSET', 'SIZE', 'SHA']) == {
            'ASSET': raw_name, 'SIZE': raw_size, 'SHA': raw_sha},
            'launcher ' + arch + ': metadata differs')
    release_url(text, DISTRIBUTION_TAG, '$ASSET')


def check_pin_mirrors(root):
    # Both gates run on amd64 only, so that architecture's binary pins are the
    # whole mirrored set. Every 64-hex token in these files must be a current
    # release digest as well, or a bump that leaves one behind reads as correct.
    known = {pins[key] for pins in PINS.values() for key in ('sha', 'binary_sha')}
    for name in PIN_MIRRORS:
        text = (root / name).read_text(encoding='utf-8')
        for key in ('binary_size', 'binary_sha'):
            require(PINS['amd64'][key] in text,
                    name + ': amd64 ' + key + ' is missing or stale')
        for token in re.findall('[0-9a-fA-F]{64}', text):
            require(token in known, name + ': unrecognized digest ' + token)


def check_asset_expectations(text):
    expected = {
        'Xray release is stable v26.3.27': [VERSION, '$S5_XRAY_VERSION'],
        'Xray release commit is pinned': [COMMIT, '$S5_XRAY_COMMIT'],
        'raw distribution tag is revisioned': [DISTRIBUTION_TAG,
                                                '$S5_XRAY_DISTRIBUTION_TAG'],
    }
    for arch in PINS:
        name, size, sha = RAW_ASSETS[arch]
        expected[arch + ' raw asset name'] = [name, '$S5_ASSET_NAME']
        expected[arch + ' raw size'] = [size, '$S5_ASSET_SIZE']
        expected[arch + ' raw digest'] = [sha, '$S5_ASSET_SHA256']
    seen = {}
    for line in text.replace('\\\n', '').splitlines():
        if not line.startswith('assert_eq '):
            continue
        tokens = shlex.split(line, comments=True)
        if len(tokens) > 1 and tokens[1] in expected:
            require(tokens[1] not in seen, 'asset expectations: duplicate assertion')
            seen[tokens[1]] = tokens[2:]
    require(seen == expected, 'asset expectations: incomplete or mismatched metadata assertions')


def check_raw_publisher(root):
    workflow_path = root / '.github/workflows/publish-xray-raw.yml'
    script_path = root / '.github/scripts/publish-release.sh'
    preparer_path = root / '.github/scripts/prepare-xray-raw.py'
    notes_path = root / '.github/releases/xray-v26.3.27-r1.md'
    require(workflow_path.is_file() and script_path.is_file() and preparer_path.is_file() and
            notes_path.is_file(), 'raw publisher: required tracked files are missing')
    workflow = workflow_path.read_text(encoding='utf-8')
    script = script_path.read_text(encoding='utf-8')
    preparer = preparer_path.read_text(encoding='utf-8')
    notes = notes_path.read_text(encoding='utf-8')
    # The release API calls live in publish-release.sh; the workflow invokes it.
    publisher = workflow + '\n' + script
    require('workflow_dispatch:' in workflow and 'push:' not in workflow and 'pull_request:' not in workflow,
            'raw publisher: must be dispatch-only')
    require('contents: read' in workflow and 'contents: write' in workflow,
            'raw publisher: permission boundary is missing')
    require('--clobber' not in publisher and '--force' not in publisher,
            'raw publisher: replacement path is forbidden')
    require(script.count("2>/dev/null |\n        jq -r '.object.sha // empty' || true") == 1 and
            'jq -r .object.sha || true' not in publisher and
            '--jq .object.sha 2>/dev/null || true' not in publisher,
            'raw publisher: missing-tag lookup must not capture the gh error body')
    require('releases/tags/$DISTRIBUTION_TAG' not in publisher and
            script.count('gh api --paginate "repos/$GITHUB_REPOSITORY/releases?per_page=100"') == 1 and
            script.count('select(.tag_name==$tag)') == 1,
            'raw publisher: draft releases must be found through the paginated release listing')
    require(script.count("jq 'length')\" -le 1 ||") == 1 and
            'if length == 1 then .[0] else empty end' in script,
            'raw publisher: a tag claimed by more than one release must be refused')
    require(script.count('releases/$RELEASE_ID') >= 3 and
            "printf 'RELEASE_ID=%s" in workflow and
            'gh release upload' not in publisher,
            'raw publisher: every step after the claim must address the draft by id')
    require('compare/$claimed...$GITHUB_SHA' not in publisher and
            'test "$claimed" = "$GITHUB_SHA" ||' in script and
            'test "$actual" = "$GITHUB_SHA" ||' in script and
            'jq -r .target_commitish)" = "$GITHUB_SHA" ||' in script,
            'raw publisher: the tag and draft must belong to the exact dispatch commit and may not move')
    require(workflow.count('test "$GITHUB_REF" = refs/heads/xray-only') == 1 and
            script.count('test "$GITHUB_REF" = refs/heads/xray-only') == 1 and
            workflow.count('DISTRIBUTION_TAG: ' + DISTRIBUTION_TAG) == 1,
            'raw publisher: branch or tag pin differs')
    for action in ('actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09',
                   'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02',
                   'actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093',
                   'actions/attest-build-provenance@43d14bc2b83dec42d39ecae14e916627a18bb661'):
        require(action in workflow, 'raw publisher: action pin missing ' + action)
    require('https://github.com/XTLS/Xray-core/releases/download/' in preparer,
            'raw publisher: pinned upstream source missing')
    require(VERSION in preparer and COMMIT in preparer,
            'raw publisher: upstream version or commit differs')
    for arch, pins in PINS.items():
        for value in (pins['asset'], pins['size'], pins['sha'], pins['binary_size'], pins['binary_sha']):
            require(value in preparer, 'raw publisher ' + arch + ': source/raw pin missing ' + value)
        raw_name, raw_size, raw_sha = RAW_ASSETS[arch]
        require(raw_name in publisher and raw_name.replace(VERSION, '{VERSION}') in preparer,
                'raw publisher ' + arch + ': raw name differs')
        require(raw_size in preparer and raw_sha in preparer,
                'raw publisher ' + arch + ': raw identity differs')
    for name in RAW_PAYLOAD:
        require(name in script and (name.replace(VERSION, '{VERSION}') in preparer or name in notes),
                'raw publisher: payload member missing ' + name)
    for term in ('unchanged', 'not custom builds', 'SHA256SUMS', 'PROVENANCE.json', 'LICENSE.txt'):
        require(term in notes, 'raw release notes: missing ' + term)


def check(root, shell='sh'):
    root = Path(root).resolve()
    check_raw_publisher(root)
    texts = {name: (root / name).read_text(encoding='utf-8') for name in FILES}
    for pins in PINS.values():
        for key in ('sha', 'binary_sha'):
            require(re.fullmatch('[0-9a-f]{64}', pins[key]), 'oracle digest format')
        for key in ('size', 'binary_size'):
            require(re.fullmatch('[1-9][0-9]*', pins[key]), 'oracle size format')
    require(re.fullmatch('[0-9a-f]{40}', COMMIT), 'oracle revision format')
    require(re.fullmatch('[0-9a-f]{64}', SC_SHA), 'oracle ShellCheck digest format')
    check_pin_mirrors(root)
    check_installer(root, shell)
    check_workflow(texts[FILES[1]])
    check_launcher(texts[FILES[2]])
    check_asset_expectations(texts[FILES[3]])


def main():
    try:
        check(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else 'sh')
    except (ContractError, OSError, ValueError, subprocess.SubprocessError) as error:
        print('release contract: ' + str(error), file=sys.stderr)
        return 1
    print('release contract: installer, workflow, launcher, publisher, asset expectations'
          ' and mirrored pins verified')
    return 0


if __name__ == '__main__':
    sys.exit(main())
