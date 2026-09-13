#!/usr/bin/env python3
"""Mutation tests across the release contract's checkout interface."""

import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
import release_contract as contract


FILES = ('socks5.sh', '.github/workflows/ci.yml',
         'tests/protocol/start_engine.sh', 'tests/unit/test_xray_asset.sh')


def declarations(name, text):
    if name == FILES[0]:
        pattern = (r'^[ \t]*S5_(?:XRAY_(?:VERSION|COMMIT)|ASSET_(?:NAME|SIZE|SHA256|'
                   r'BINARY_SIZE|BINARY_SHA256))=(?P<value>[A-Za-z0-9_.-]+)$')
        expected = 12
    elif name == FILES[1]:
        pattern = (r'^            (?:arch|asset|size|sha|binary_size|binary_sha|elf_arch): '
                   r'(?P<value>[A-Za-z0-9_.-]+)$')
        expected = 14
    elif name == FILES[2]:
        pattern = r'^    (?:ASSET|SIZE|SHA)=(?P<value>[A-Za-z0-9_.-]+)$'
        expected = 6
    else:
        pattern = (r'^assert_eq "(?:Xray release[^"\n]*|(?:amd64|arm64) '
                   r'(?:asset name|archive (?:size|digest)|extracted xray (?:size|digest)))"'
                   r'(?:[ \t]|\\\n)+(?P<value>[A-Za-z0-9_.-]+)')
        expected = 12
    start, end = 0, len(text)
    if name == FILES[1]:
        job = re.search(r'^  xray-assets:\n(.*?)(?=^  [a-z][a-z0-9-]*:|\Z)',
                        text, re.MULTILINE | re.DOTALL)
        if job is None:
            raise AssertionError('release asset job is missing')
        start, end = job.span(1)
    matches = list(re.compile(pattern, re.MULTILINE).finditer(text, start, end))
    if len(matches) != expected:
        raise AssertionError(f'{name}: mutation inventory {len(matches)} != {expected}')
    return matches


def main():
    source = Path(sys.argv[1]).resolve()
    shell = os.environ.get('S5_TEST_SHELL', 'sh')
    checked = 0
    with tempfile.TemporaryDirectory(prefix='s5-pin-contract-') as directory:
        root = Path(directory)
        for name in ('tests', '.github'):
            shutil.copytree(source / name, root / name)
        for name in ('socks5.sh', 'README.md', 'README.zh-CN.md', '.gitignore'):
            shutil.copy2(source / name, root / name)
        subprocess.run(['git', '-C', str(root), 'init', '-q'], check=True)
        subprocess.run(['git', '-C', str(root), 'add', '.'], check=True)
        originals = {name: (root / name).read_text() for name in FILES}

        def rejects(name, changed, label):
            nonlocal checked
            path = root / name
            path.write_text(changed)
            try:
                try:
                    contract.check(root, shell)
                except (contract.ContractError, ValueError):
                    checked += 1
                else:
                    raise AssertionError(name + ': accepted ' + label)
            finally:
                path.write_text(originals[name])

        contract.check(root, shell)
        checked += 1
        for name, text in originals.items():
            for index, match in enumerate(declarations(name, text)):
                start, end = match.span('value')
                value = match['value']
                alternatives = [('wrong', '9' * len(value)), ('empty', ''),
                                ('malformed', 'invalid-pin'), ('unrecognized', '${UNREADABLE}')]
                if re.fullmatch('[0-9a-f]{64}', value):
                    # Swap to another valid release hash rather than just a
                    # random digest; membership in a known set is insufficient.
                    other = ('4d30283ae614e3057f730f67cd088a42be6fdf91f8639d82cb69e48cde80413c'
                             if value.startswith('23cd') else
                             '23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae')
                    alternatives.append(('wrong-architecture-or-kind', other))
                for label, replacement in alternatives:
                    rejects(name, text[:start] + replacement + text[end:], f'{index} {label}')
                if name != FILES[3]:
                    rejects(name, text[:match.start()] + text[match.end():], f'{index} deleted')
                    rejects(name, text[:match.start()] + '# ' + text[match.start():],
                            f'{index} commented out')

        workflow = originals[FILES[1]]
        for literal in [
                "SC_SHA='6c881ab0698e4e6ea235245f22832860544f17ba386442fe7e9d629f8cbedf87'",
                "SC_URL='https://github.com/koalaman/shellcheck/releases/download/"
                "v0.10.0/shellcheck-v0.10.0.linux.x86_64.tar.xz'",
                '${{ matrix.sha }}', '${{ matrix.binary_sha }}']:
            if workflow.count(literal) != 1:
                raise AssertionError('workflow mutation anchor missing or duplicated')
            rejects(FILES[1], workflow.replace(literal, ''), 'missing ' + literal.split('=')[0])
            rejects(FILES[1], workflow.replace(literal, literal + 'invalid'), 'malformed tool/binding')
        mirror = 'https://github.com/91sexboy/One-click-socks5-proxy-setup/releases/download/'
        upstream = 'https://github.com/XTLS/Xray-core/releases/download/v26.3.27/'
        for name in FILES[:3]:
            text = originals[name]
            tag = 'xray-$S5_XRAY_VERSION' if name == FILES[0] else 'xray-v26.3.27/'
            url = mirror + tag
            if text.count(url) != 1:
                raise AssertionError('release URL mutation anchor missing or duplicated')
            rejects(name, text.replace(url, url.replace('xray-', 'other-')), 'wrong mirror tag')
            rejects(name, text.replace(url, url.replace('91sexboy', 'unexpected-owner')), 'wrong repository')
            rejects(name, text.replace(url, upstream), 'upstream distribution source')
            rejects(name, text.replace(url, url.replace('https:', 'http:')), 'insecure distribution source')
            rejects(name, text.replace(url, ''), 'missing URL')
            if name == FILES[0]:
                line = 'S5_XRAY_BASE=' + url
                rejects(name, text.replace(line, line + '\n' + line), 'duplicate distribution base')
                anchor = '-o "$1" "$S5_XRAY_BASE/$S5_ASSET_NAME" || {'
                if text.count(anchor) != 1:
                    raise AssertionError('installer transport mutation anchor missing')
                fallback = ('-o "$1" "$S5_XRAY_BASE/$S5_ASSET_NAME" || '
                            'curl -fsSL "' + upstream + '$S5_ASSET_NAME" || {')
                rejects(name, text.replace(anchor, fallback), 'transport failure triggers upstream fallback')
            else:
                variable = '$XRAY_ASSET' if name == FILES[1] else '$ASSET'
                anchor = '"' + url + variable + '"'
                fallback = anchor + ' || curl -fsSL "' + upstream + variable + '"'
                rejects(name, text.replace(anchor, fallback), 'additional fallback URL')

        # Test callers through the real docs/asset paths too, not just imports.
        def run_test(name, expected):
            nonlocal checked
            result = subprocess.run(['sh', str(root / 'tests/run.sh'), name],
                                    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    timeout=45, check=False)
            if result.returncode != expected or 'skipped:' in result.stdout:
                raise AssertionError(name + ': unexpected result\n' + result.stdout)
            checked += 1

        asset = root / FILES[3]
        # Unrelated fixture/comment text is not a release declaration, regardless
        # of its length, format or accidental resemblance to another pin.
        asset.write_text(originals[FILES[3]] + '\n# ' + 'a' * 63 + '\n' +
                         'S5T_UNUSED_NEGATIVE_DIGEST=' + 'b' * 64 + '\n')
        contract.check(root, shell)
        checked += 1
        run_test('test_xray_asset', 0)
        run_test('test_xray_docs', 0)
        asset.write_text(originals[FILES[3]])
        for name, text in originals.items():
            match = declarations(name, text)[0]
            start, end = match.span('value')
            (root / name).write_text(text[:start] + 'invalid-pin' + text[end:])
            try:
                run_test('test_xray_docs', 1)
            finally:
                (root / name).write_text(text)
    print(f'release contract regressions: {checked} checks passed')


if __name__ == '__main__':
    main()
