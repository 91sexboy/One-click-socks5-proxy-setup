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
BASE = 'https://github.com/XTLS/Xray-core/releases/download/'
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

# Each entry is required, including positive metadata assertions in the asset
# test. Readers reject missing, duplicate and unrecognizable declarations.
FILES = ('socks5.sh', '.github/workflows/ci.yml',
         'tests/protocol/start_engine.sh', 'tests/unit/test_xray_asset.sh')


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


def release_url(text, asset):
    active = '\n'.join(line for line in text.splitlines()
                       if not line.lstrip().startswith('#'))
    version = one(re.escape(BASE) + r'([^/\s"\']+)/' + re.escape(asset),
                  active, 'Xray download URL')
    require(version == VERSION, 'Xray download URL: wrong release')


def check_installer(root, shell):
    # Only the real library-mode selector executes. Every architecture starts
    # fresh and clears outputs, so a deleted assignment cannot inherit a pin.
    script = '''
. "$1/socks5.sh" || exit 1
S5_ARCHNAME=$2
S5_ASSET_NAME= S5_ASSET_SIZE= S5_ASSET_SHA256=
S5_ASSET_BINARY_SIZE= S5_ASSET_BINARY_SHA256=
s5_asset_select || exit 1
printf '%s\\n' "$S5_XRAY_VERSION" "$S5_XRAY_COMMIT" "$S5_XRAY_BASE" \\
    "$S5_ASSET_NAME" "$S5_ASSET_SIZE" "$S5_ASSET_SHA256" \\
    "$S5_ASSET_BINARY_SIZE" "$S5_ASSET_BINARY_SHA256"
'''
    with tempfile.TemporaryDirectory(prefix='s5-pin-selector-') as directory:
        Path(directory, '.s5-test-root').touch()
        env = dict(os.environ, S5_LIB_ONLY='1', S5_TEST_MODE='1',
                   S5_TEST_ROOT=directory, S5_ASSUME_ROOT='1', S5_SKIP_OWNERSHIP='1')
        for arch, pins in PINS.items():
            result = subprocess.run(
                shlex.split(shell) + ['-c', script, 'release-contract', str(root), arch],
                env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                timeout=15, check=False)
            expected = [VERSION, COMMIT, BASE + VERSION] + list(pins.values())
            require(result.returncode == 0 and result.stdout.splitlines() == expected,
                    'installer ' + arch + ': selector metadata differs')


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
    expected = [dict(pins, arch=arch,
                     runner='ubuntu-24.04' if arch == 'amd64' else 'ubuntu-24.04-arm',
                     elf_arch='x86-64' if arch == 'amd64' else 'aarch64')
                for arch, pins in PINS.items()]
    require(rows == expected, 'asset matrix: incomplete, duplicate or mismatched metadata')
    for name, key in [('ASSET', 'asset'), ('SIZE', 'size'), ('SHA', 'sha'),
                      ('BINARY_SIZE', 'binary_size'), ('BINARY_SHA', 'binary_sha'),
                      ('ELF_ARCH', 'elf_arch')]:
        value = one(r'^          XRAY_' + name + r': ([^\n]+)$', job, 'XRAY_' + name)
        require(value == '${{ matrix.' + key + ' }}', 'XRAY_' + name + ': wrong matrix binding')
    release_url(job, '$XRAY_ASSET')
    require(assignments(text, ['SC_URL', 'SC_SHA']) == {'SC_URL': SC_URL, 'SC_SHA': SC_SHA},
            'ShellCheck: URL or digest differs')


def check_launcher(text):
    block = one(r'^case "\$ARCH" in\n(.*?)^esac$', text, 'launcher architecture case')
    for arch, pins in PINS.items():
        body = one(r'^' + arch + r'\)\n(.*?)^    ;;$', block, 'launcher ' + arch)
        require(assignments(body, ['ASSET', 'SIZE', 'SHA']) == {
            'ASSET': pins['asset'], 'SIZE': pins['size'], 'SHA': pins['sha']},
            'launcher ' + arch + ': metadata differs')
    release_url(text, '$ASSET')


def check_asset_expectations(text):
    expected = {
        'Xray release is stable v26.3.27': [VERSION, '$S5_XRAY_VERSION'],
        'Xray release commit is pinned': [COMMIT, '$S5_XRAY_COMMIT'],
    }
    fields = [('asset name', 'asset', 'S5_ASSET_NAME'),
              ('archive size', 'size', 'S5_ASSET_SIZE'),
              ('archive digest', 'sha', 'S5_ASSET_SHA256'),
              ('extracted xray size', 'binary_size', 'S5_ASSET_BINARY_SIZE'),
              ('extracted xray digest', 'binary_sha', 'S5_ASSET_BINARY_SHA256')]
    for arch, pins in PINS.items():
        for label, key, variable in fields:
            expected[arch + ' ' + label] = [pins[key], '$' + variable]
    seen = {}
    for line in text.replace('\\\n', '').splitlines():
        if not line.startswith('assert_eq '):
            continue
        tokens = shlex.split(line, comments=True)
        if len(tokens) > 1 and tokens[1] in expected:
            require(tokens[1] not in seen, 'asset expectations: duplicate assertion')
            seen[tokens[1]] = tokens[2:]
    require(seen == expected, 'asset expectations: incomplete or mismatched metadata assertions')


def check(root, shell='sh'):
    root = Path(root).resolve()
    texts = {name: (root / name).read_text(encoding='utf-8') for name in FILES}
    for pins in PINS.values():
        for key in ('sha', 'binary_sha'):
            require(re.fullmatch('[0-9a-f]{64}', pins[key]), 'oracle digest format')
        for key in ('size', 'binary_size'):
            require(re.fullmatch('[1-9][0-9]*', pins[key]), 'oracle size format')
    require(re.fullmatch('[0-9a-f]{40}', COMMIT), 'oracle revision format')
    require(re.fullmatch('[0-9a-f]{64}', SC_SHA), 'oracle ShellCheck digest format')
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
    print('release contract: installer, workflow, launcher and asset expectations verified')
    return 0


if __name__ == '__main__':
    sys.exit(main())
