#!/usr/bin/env python3
"""Mutation tests across the release contract's checkout interface."""

import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
import release_contract as contract


FILES = ('socks5.sh', '.github/workflows/ci.yml',
         'tests/protocol/start_engine.sh', 'tests/unit/test_xray_asset.sh')


def declarations(name, text):
    if name == FILES[0]:
        pattern = (r'^[ \t]*S5_(?:XRAY_(?:VERSION|COMMIT|DISTRIBUTION_TAG)|'
                   r'ASSET_(?:NAME|SIZE|SHA256))=(?P<value>[A-Za-z0-9_.-]+)$')
        expected = 9
    elif name == FILES[1]:
        pattern = (r'^            (?:arch|source_asset|source_size|source_sha|asset|size|sha|elf_arch): '
                   r'(?P<value>[A-Za-z0-9_.-]+)$')
        expected = 16
    elif name == FILES[2]:
        pattern = r'^    (?:ASSET|SIZE|SHA)=(?P<value>[A-Za-z0-9_.-]+)$'
        expected = 6
    else:
        pattern = (r'^assert_eq "(?:Xray release[^"\n]*|raw distribution tag is revisioned|'
                   r'(?:amd64|arm64) raw (?:asset name|size|digest))"'
                   r'(?:[ \t]|\\\n)+(?P<value>[A-Za-z0-9_.-]+)')
        expected = 9
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


def run_regressions(source):
    shell = os.environ.get('S5_TEST_SHELL', 'sh')
    checked = 0
    with tempfile.TemporaryDirectory(prefix='s5-pin-contract-') as directory:
        root = Path(directory)
        for name in ('tests', '.github', 'docs/adr'):
            shutil.copytree(source / name, root / name)
        for name in ('socks5.sh', 'README.md', 'README.zh-CN.md', '.gitignore', 'LICENSE',
                     'THIRD_PARTY_NOTICES.md'):
            shutil.copy2(source / name, root / name)
        subprocess.run(['git', '-C', str(root), 'init', '-q'], check=True)
        subprocess.run(['git', '-C', str(root), 'add', '.'], check=True)
        originals = {name: (root / name).read_text() for name in FILES}

        def rejects(name, changed, label):
            nonlocal checked
            path = root / name
            restore = path.read_text()
            path.write_text(changed)
            try:
                try:
                    contract.check(root, shell)
                except (contract.ContractError, ValueError):
                    checked += 1
                else:
                    raise AssertionError(name + ': accepted ' + label)
            finally:
                path.write_text(restore)

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
                '${{ matrix.source_sha }}', '${{ matrix.sha }}']:
            if workflow.count(literal) != 1:
                raise AssertionError('workflow mutation anchor missing or duplicated')
            rejects(FILES[1], workflow.replace(literal, ''), 'missing ' + literal.split('=')[0])
            rejects(FILES[1], workflow.replace(literal, literal + 'invalid'), 'malformed tool/binding')
        mirror = 'https://github.com/91sexboy/One-click-socks5-proxy-setup/releases/download/'
        installer = originals[FILES[0]]
        base_line = 'S5_XRAY_BASE=' + mirror + '$S5_XRAY_DISTRIBUTION_TAG'
        if installer.count(base_line) != 1:
            raise AssertionError('installer distribution base anchor missing')
        rejects(FILES[0], installer.replace('xray-v26.3.27-r1', 'xray-v26.3.27-other', 1),
                'wrong raw distribution tag')
        rejects(FILES[0], installer.replace(base_line, base_line.replace('91sexboy', 'unexpected-owner')),
                'wrong repository')
        rejects(FILES[0], installer.replace(base_line, base_line.replace('https:', 'http:')),
                'insecure distribution source')
        rejects(FILES[0], installer.replace(base_line, base_line + '\n' + base_line),
                'duplicate distribution base')
        anchor = ('-o "$1" "$S5_XRAY_BASE/$S5_ASSET_NAME"\n'
                  '        _sfb_curl=$?')
        if installer.count(anchor) != 1:
            raise AssertionError('installer raw transport mutation anchor missing')
        fallback = ('-o "$1" "$S5_XRAY_BASE/$S5_ASSET_NAME" || '
                    's5_curl_command -fsSL "https://github.com/XTLS/Xray-core/releases/download/'
                    'v26.3.27/$S5_ASSET_NAME"\n        _sfb_curl=$?')
        rejects(FILES[0], installer.replace(anchor, fallback),
                'transport failure triggers upstream fallback')
        for name, variable in ((FILES[1], '$XRAY_ASSET'), (FILES[2], '$ASSET')):
            text = originals[name]
            raw_url = mirror + 'xray-v26.3.27-r1/' + variable
            if text.count(raw_url) != 1:
                raise AssertionError('raw release URL mutation anchor missing')
            rejects(name, text.replace(raw_url, raw_url.replace('xray-v26.3.27-r1', 'other-r1')),
                    'wrong raw mirror tag')
            rejects(name, text.replace(raw_url, raw_url.replace('91sexboy', 'unexpected-owner')),
                    'wrong raw repository')
            rejects(name, text.replace(raw_url, raw_url.replace('https:', 'http:')),
                    'insecure raw distribution source')

        digest = contract.PINS['amd64']['binary_sha']
        size = contract.PINS['amd64']['binary_size']
        unknown = 'de' * 32
        for name in contract.PIN_MIRRORS:
            text = (root / name).read_text()
            if text.count(digest) != 1 or text.count(size) != 1:
                raise AssertionError('pin mirror mutation anchor missing or duplicated')
            rejects(name, text.replace(digest, unknown), 'stale binary digest')
            rejects(name, text.replace(size, '9' * len(size)), 'stale binary size')
            rejects(name, text.replace(digest, ''), 'dropped binary digest assertion')
            rejects(name, text.replace(size, ''), 'dropped binary size assertion')
            rejects(name, text.replace(digest, contract.PINS['arm64']['binary_sha']),
                    'the binary digest of the architecture these gates never run on')
            rejects(name, text + '\n# ' + unknown + '\n', 'an unrecognized digest')
            # Another current pin is not staleness: the mirrors are required to
            # carry the amd64 binary bytes, not forbidden every other digest.
            (root / name).write_text(text + '\n# ' + contract.PINS['arm64']['sha'] + '\n')
            contract.check(root, shell)
            checked += 1
            (root / name).write_text(text)

        publisher = (root / '.github/workflows/publish-xray-raw.yml').read_text()
        preparer = (root / '.github/scripts/prepare-xray-raw.py').read_text()
        publisher_cases = [
            ('.github/workflows/publish-xray-raw.yml', publisher,
             'DISTRIBUTION_TAG: xray-v26.3.27-r1', 'DISTRIBUTION_TAG: xray-v26.3.27-other', 'wrong raw release tag'),
            ('.github/workflows/publish-xray-raw.yml', publisher,
             'test "$GITHUB_REF" = refs/heads/xray-only', 'test "$GITHUB_REF" = refs/heads/other', 'wrong dispatch branch'),
            ('.github/workflows/publish-xray-raw.yml', publisher,
             "jq -r '.object.sha // empty' || true",
             'jq -r .object.sha || true', 'missing ref becomes literal null'),
            ('.github/workflows/publish-xray-raw.yml', publisher,
             'repos/$GITHUB_REPOSITORY/releases?per_page=100',
             'repos/$GITHUB_REPOSITORY/releases/tags/$DISTRIBUTION_TAG',
             'draft looked up through published-release endpoint'),
            ('.github/workflows/publish-xray-raw.yml', publisher,
             '''test "$(printf '%s' "$matches" | jq 'length')" -le 1 || {''',
             '''test "$(printf '%s' "$matches" | jq 'length')" -ge 0 || {''',
             'duplicate release claims accepted'),
            ('.github/workflows/publish-xray-raw.yml', publisher,
             'test "$claimed" = "$GITHUB_SHA" ||', 'test "$claimed" != "$GITHUB_SHA" ||',
             'a tag claimed by another commit accepted'),
            ('.github/workflows/publish-xray-raw.yml', publisher,
             'test "$actual" = "$CLAIMED_SHA" ||', 'test "$actual" != "$CLAIMED_SHA" ||',
             'publication rides a tag that moved'),
            ('.github/workflows/publish-xray-raw.yml', publisher,
             '''test "$(printf '%s' "$release" | jq -r .target_commitish)" = "$GITHUB_SHA" || {''',
             '''test "$(printf '%s' "$release" | jq -r .target_commitish)" != "$GITHUB_SHA" || {''',
             'draft targeted at another commit accepted'),
            ('.github/workflows/publish-xray-raw.yml', publisher,
             'releases/$RELEASE_ID"', 'releases/tags/$DISTRIBUTION_TAG"',
             'draft addressed by tag instead of id'),
            ('.github/workflows/publish-xray-raw.yml', publisher,
             "gh api --method POST -H 'Content-Type: application/octet-stream'",
             'gh release upload "$DISTRIBUTION_TAG" --clobber --repo "$GITHUB_REPOSITORY"',
             'replacement upload enabled'),
            ('.github/scripts/prepare-xray-raw.py', preparer,
             'https://github.com/XTLS/Xray-core/releases/download/',
             'https://unexpected.example/releases/download/', 'wrong upstream source'),
            ('.github/scripts/prepare-xray-raw.py', preparer,
             contract.RAW_ASSETS['amd64'][0], 'xray-wrong-amd64', 'wrong amd64 raw name'),
            ('.github/scripts/prepare-xray-raw.py', preparer,
             contract.RAW_ASSETS['arm64'][2], 'f' * 64, 'wrong arm64 raw digest'),
        ]
        for name, text, old, new, label in publisher_cases:
            if text.count(old) < 1:
                raise AssertionError('publisher mutation anchor missing: ' + label)
            rejects(name, text.replace(old, new, 1), label)

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
        run_test('test_xray_readme', 0)
        asset.write_text(originals[FILES[3]])
        for name, text in originals.items():
            match = declarations(name, text)[0]
            start, end = match.span('value')
            (root / name).write_text(text[:start] + 'invalid-pin' + text[end:])
            try:
                run_test('test_xray_readme', 1)
            finally:
                (root / name).write_text(text)
    print(f'release contract regressions: {checked} checks passed')


class ReleaseContractTests(unittest.TestCase):
    source = Path(__file__).resolve().parents[2]

    def test_release_contract_mutations(self):
        run_regressions(self.source)


def main():
    if len(sys.argv) > 1:
        ReleaseContractTests.source = Path(sys.argv[1]).resolve()
    result = unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromTestCase(ReleaseContractTests))
    return int(not result.wasSuccessful())


if __name__ == '__main__':
    sys.exit(main())
