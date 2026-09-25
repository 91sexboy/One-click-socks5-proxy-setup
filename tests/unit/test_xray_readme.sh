#!/bin/sh
# Public README claims, independent release pins and local ADR links.

S5T_NAME=test_xray_readme
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
ROOT=${S5_REPO_ROOT}
t_mktestroot
t_source_production ''

t_run python3 "$ROOT/tests/lib/release_contract.py" "$ROOT" "${S5_TEST_SHELL:-sh}"
assert_eq "release declarations agree with independent pins" 0 "$T_STATUS"
if [ "$T_STATUS" -ne 0 ]; then printf '%s\n' "$T_OUT" >&2; fi
assert_eq "the production card endpoint matches the independent documented endpoint" \
    https://icanhazip.com "$S5_ADDR_ENDPOINT"
_docrepo=https://github.com/91sexboy/One-click-socks5-proxy-setup
for _doc in README.md README.zh-CN.md; do
    _doctext=$(cat "$ROOT/$_doc")
    for _platform in Alpine OpenRC; do
        if grep -qi "$_platform" "$ROOT/$_doc"; then
            t_ok
        else
            t_bad "$_doc documents $_platform"
        fi
    done
    assert_contains "$_doc names the card address endpoint" icanhazip.com "$_doctext"
    assert_contains "$_doc documents the card address placeholder" SERVER_IPV4 "$_doctext"
    assert_not_contains "$_doc does not deny the routing it describes" 'metrics, routing' "$_doctext"
    assert_not_contains "$_doc does not deny the routing it describes (zh)" 'metrics、routing' "$_doctext"
    assert_not_contains "$_doc does not claim install verifies transport" \
        'bidirectional transport locally' "$_doctext"
    assert_not_contains "$_doc does not claim install verifies transport (zh)" '和持续双向传输' "$_doctext"
    assert_contains "$_doc links the CI badge to the project" \
        "[![CI — xray-only]($_docrepo/actions/workflows/ci.yml/badge.svg?branch=xray-only)]($_docrepo)" "$_doctext"
    case "$_doc" in
    README.md) _doclanguage='[简体中文](README.zh-CN.md)' ;;
    README.zh-CN.md) _doclanguage='[English](README.md)' ;;
    esac
    assert_contains "$_doc links to the other language" "$_doclanguage" "$_doctext"
    assert_contains "$_doc links to the verified local release mirror" \
        "($_docrepo/releases/tag/xray-v26.3.27)" "$_doctext"
    case "$_doc" in
    README.md)
        assert_contains "English update docs retain a verified blank port" \
            'blank port keeps the current port only after its listener is verified' "$_doctext"
        assert_contains "English update docs rotate blank credentials" \
            'Blank username and password answers generate new values' "$_doctext"
        ;;
    README.zh-CN.md)
        assert_contains "Chinese update docs retain a verified blank port" \
            '更新时端口留空，仅在确认当前监听器属于本次安装后保留原端口' "$_doctext"
        assert_contains "Chinese update docs rotate blank credentials" \
            '账户名或密码留空会生成新值' "$_doctext"
        ;;
    esac
done

t_run python3 -O - "$ROOT" <<'PY'
from pathlib import Path
import re
import sys

REPO = 'https://github.com/91sexboy/One-click-socks5-proxy-setup'
COMMIT = '9271644340d2332725d0c83e818711481486668f'
RUN = '34800667931'
ROWS = [
    ('amd64', '0', '35896', '11710464'),
    ('amd64', '1', '35912', '11972608'),
    ('amd64', '32', '36424', '13283328'),
    ('amd64', '128', '40876', '19304448'),
    ('arm64', '0', '29460', '6348800'),
    ('arm64', '1', '29520', '6348800'),
    ('arm64', '32', '30928', '8183808'),
    ('arm64', '128', '35324', '14200832'),
]
DOCS = {
    'README.md': ('Measured memory', 'Phase cgroup peak (bytes)', (
        'instantaneous RSS snapshots', 'not a 60-second load test',
        'not isolated startup RSS peaks', 'outside the Xray cgroup',
        'not a minimum-memory guarantee', '14 days',
    )),
    'README.zh-CN.md': ('内存实测', '阶段 cgroup 峰值 (bytes)', (
        '瞬时 RSS 快照', '不是持续 60 秒的负载测试',
        '不是独立启动 RSS 峰值', '位于 Xray cgroup 之外',
        '不是最低内存保证', '14 天',
    )),
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def check(texts):
    for name, (heading, peak_header, caveats) in DOCS.items():
        sections = re.findall(r'^## ' + re.escape(heading) + r'\n(.*?)(?=^## |\Z)',
                              texts[name], re.MULTILINE | re.DOTALL)
        require(len(sections) == 1, f'{name}: evidence section')
        section = sections[0]
        tables = []
        for block in re.findall(r'(?:^\|[^\n]*\n)+', section, re.MULTILINE):
            cells = [tuple(cell.strip() for cell in line.strip('|').split('|'))
                     for line in block.splitlines()]
            tables.append(cells)
        require(len(tables) == 1, f'{name}: evidence table')
        table = tables[0]
        require(len(table[0]) == 4 and table[0][2:] == ('RSS (KiB)', peak_header),
                f'{name}: evidence units')
        require(sorted(table[2:]) == sorted(ROWS), f'{name}: historical measurements')
        for path in (f'/commit/{COMMIT}', f'/actions/runs/{RUN}',
                     f'/actions/runs/{RUN}/job/103842545297',
                     f'/actions/runs/{RUN}/job/103842545245'):
            require(f']({REPO}{path})' in section, f'{name}: evidence provenance')
        for claim in ('v26.3.27', 'Ubuntu 24.04', 'memory-comparison-amd64',
                      'memory-comparison-arm64', *caveats):
            require(claim in section, f'{name}: measurement context')


texts = {name: (Path(sys.argv[1]) / name).read_text() for name in DOCS}
check(texts)
mutations = 0
for name, (heading, peak_header, caveats) in DOCS.items():
    row = '| amd64 | 0 | 35896 | 11710464 |'
    changes = [
        (f'## {heading}', f'### {heading}', 'evidence section'),
        (row + '\n', '', 'historical measurements'),
        (row, row + '\n' + row, 'historical measurements'),
        ('35896', '35897', 'historical measurements'),
        ('RSS (KiB)', 'RSS (MiB)', 'evidence units'),
        (peak_header, peak_header.replace('bytes', 'KiB'), 'evidence units'),
        (COMMIT, '0' * 40, 'evidence provenance'),
        (RUN, '34800667930', 'evidence provenance'),
        ('103842545297', '103842545296', 'evidence provenance'),
        ('103842545245', '103842545244', 'evidence provenance'),
    ] + [(claim, '', 'measurement context') for claim in caveats]
    for old, new, reason in changes:
        require(old in texts[name], f'mutation target missing: {old}')
        changed = dict(texts)
        changed[name] = texts[name].replace(old, new)
        try:
            check(changed)
        except ValueError as error:
            require(str(error) == f'{name}: {reason}', f'wrong rejection: {error}')
        else:
            raise ValueError(f'mutation accepted: {name}: {old}')
        mutations += 1
changed = {name: text.replace('35896', '35897') for name, text in texts.items()}
try:
    check(changed)
except ValueError as error:
    require(str(error) == 'README.md: historical measurements', f'wrong rejection: {error}')
else:
    raise ValueError('identical corruption in both translations was accepted')
print(f'memory evidence: two translations, eight rows, {mutations + 1} rejected mutations')
PY
assert_eq "historical memory evidence and its rejection controls agree" 0 "$T_STATUS"
if [ "$T_STATUS" -ne 0 ]; then printf '%s\n' "$T_OUT" >&2; fi

t_run python3 "$ROOT/tests/lib/doc_links.py" "$ROOT"
assert_eq "all public README and ADR local links resolve" 0 "$T_STATUS"
if [ "$T_STATUS" -ne 0 ]; then printf '%s\n' "$T_OUT" >&2; fi
mkdir -p "$S5_TEST_ROOT/docs/adr"
printf '[decision](docs/adr/0001.md)\n' >"$S5_TEST_ROOT/README.md"
printf '[English](README.md)\n' >"$S5_TEST_ROOT/README.zh-CN.md"
printf '[missing](missing.md)\n' >"$S5_TEST_ROOT/docs/adr/0001.md"
t_run python3 -O "$ROOT/tests/lib/doc_links.py" "$S5_TEST_ROOT"
assert_eq "an ADR dangling link fails even with optimized Python" 1 "$T_STATUS"
assert_contains "a dangling link identifies its source ADR" 'docs/adr/0001.md: missing local link missing.md' "$T_OUT"
printf '[README](../../README.md)\n' >"$S5_TEST_ROOT/docs/adr/0001.md"
t_run python3 -O "$ROOT/tests/lib/doc_links.py" "$S5_TEST_ROOT"
assert_eq "valid relative ADR links pass with optimized Python" 0 "$T_STATUS"
printf '[README](../../README.md#missing)\n' >"$S5_TEST_ROOT/docs/adr/0001.md"
t_run python3 -O "$ROOT/tests/lib/doc_links.py" "$S5_TEST_ROOT"
assert_eq "a missing ADR link anchor fails with optimized Python" 1 "$T_STATUS"
assert_contains "an absent anchor identifies the source ADR" 'docs/adr/0001.md: missing local anchor' "$T_OUT"
printf '\n## Missing\n' >>"$S5_TEST_ROOT/README.md"
t_run python3 -O "$ROOT/tests/lib/doc_links.py" "$S5_TEST_ROOT"
assert_eq "a resolved ADR link anchor passes with optimized Python" 0 "$T_STATUS"

t_summary
