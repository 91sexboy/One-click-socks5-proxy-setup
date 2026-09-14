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
done

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
