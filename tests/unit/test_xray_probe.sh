#!/bin/sh
# The negative probes must read exactly, not keep whatever one recv returns.

S5T_NAME=test_xray_probe
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
ROOT=${S5_REPO_ROOT}
t_mktestroot

if ! command -v python3 >/dev/null 2>&1; then
    t_skip "the negative probes read exactly" "python3 is unavailable"
    t_summary
    exit 0
fi

# SPEC 6 requires exact reads on monotonic deadlines. A single recv cannot tell a
# complete reply from a fragment, so a proxy that accepted the connection read as
# one that rejected it: the reply arrived split, the first read came back short,
# and the mismatch counted as a rejection.
t_run python3 "$ROOT/tests/protocol/probe_selftest.py"
assert_eq "the negative probes read exactly" 0 "$T_STATUS"
assert_contains "a split no-auth acceptance is not mistaken for a rejection" \
    'ok - a split no-auth acceptance is not read as a rejection' "$T_OUT"
assert_contains "a split SOCKS4 grant is not mistaken for a rejection" \
    'ok - a split SOCKS4 grant is not read as a rejection' "$T_OUT"
assert_contains "a split 407 still proves the rejection" \
    'ok - a split 407 is read as a rejection' "$T_OUT"
# A probe that cannot separate its own read failure from a refusal reports a
# rejection it never observed, which is the same false pass from the other side.
assert_contains "a stalled proxy is not mistaken for a rejection" \
    'ok - a stalled SOCKS4 reply is not read as a rejection' "$T_OUT"
assert_not_contains "the self-test has no failing check" 'not ok' "$T_OUT"

# A probe that short-reads has to fail this test, or it proves nothing.
_tpdir=$S5_TEST_ROOT/shortread
mkdir -p "$_tpdir"
sed 's/^    while len(data) < size:$/    while False:/' \
    "$ROOT/tests/protocol/xray_mixed.py" >"$_tpdir/xray_mixed.py"
assert_contains "the short-reading copy dropped the exact read" 'while False:' \
    "$(cat "$_tpdir/xray_mixed.py")"
cp "$ROOT/tests/protocol/probe_selftest.py" "$_tpdir/probe_selftest.py"
t_run python3 "$_tpdir/probe_selftest.py"
assert_ne "a short-reading probe fails the self-test" 0 "$T_STATUS"

t_summary
