#!/bin/sh
# Protocol probes must validate complete replies, ongoing traffic and readiness.

S5T_NAME=test_xray_probe
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
ROOT=${S5_REPO_ROOT}
PYTHONDONTWRITEBYTECODE=1
export PYTHONDONTWRITEBYTECODE
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

# CI-01/03/04: these execute the real transport and launcher paths using only
# loopback sockets and temporary fixtures; no Xray download or root is needed.
t_run python3 "$ROOT/tests/protocol/probe_selftest.py" --exchange-only
assert_eq "unsolicited frames have correct content, order and ongoing progress" 0 "$T_STATUS"
assert_contains "the last progress window is exercised" 'ok - unsolicited late-stop is rejected' "$T_OUT"
t_run python3 "$ROOT/tests/protocol/concurrency_selftest.py"
assert_eq "cohorts carry overlapping traffic and the gate checks independent occupancy" 0 "$T_STATUS"
assert_contains "the 64-worker mutation fails boundedly" 'ok - max64 mutant rejects boundedly' "$T_OUT"
t_run python3 "$ROOT/tests/protocol/launcher_selftest.py" --shell "${S5_TEST_SHELL:-sh}"
assert_eq "readiness follows the listener and stale outputs cannot release clients" 0 "$T_STATUS"
assert_not_contains "readiness has no failing check" 'not ok' "$T_OUT"

# Mutation proofs are behaviour checks, not source-presence claims. Removing
# either S validation dimension, or restoring early readiness publication, must
# make the corresponding real-path selftest red.
t_run python3 - "$ROOT" "$S5_TEST_ROOT" <<'PY'
from pathlib import Path
import sys
root, scratch = map(Path, sys.argv[1:])
source = (root / "tests/protocol/xray_mixed.py").read_text()
for name, old, new in (
    ("no-payload", 'if payload != ("server-%d" % expected_seq).encode("ascii"):', 'if False:'),
    ("no-progress", 'progress_window = 2.0', 'progress_window = 60.0'),
):
    assert source.count(old) == 1
    directory = scratch / name
    directory.mkdir()
    (directory / "xray_mixed.py").write_text(source.replace(old, new))
    (directory / "probe_selftest.py").write_text((root / "tests/protocol/probe_selftest.py").read_text())
launcher = (root / "tests/protocol/start_engine.sh").read_text()
lines = launcher.splitlines(keepends=True)
publication = ''.join(line for line in lines if line.startswith(("printf '%s\\n' \"$PORT\"", 'mv -f "$OUTDIR/ready.tmp"')))
assert publication and launcher.count(publication) == 1
launcher = launcher.replace(publication, '').replace('ready=0\n', publication + 'ready=0\n')
(scratch / "early-ready.sh").write_text(launcher)
PY
assert_eq "transport and readiness mutations were constructed" 0 "$T_STATUS"
t_run python3 "$S5_TEST_ROOT/no-payload/probe_selftest.py" --exchange-only payload
assert_ne "dropping unsolicited payload validation makes the selftest red" 0 "$T_STATUS"
assert_contains "payload mutation reaches its specific regression" 'not ok - unsolicited payload is rejected' "$T_OUT"
t_run python3 "$S5_TEST_ROOT/no-progress/probe_selftest.py" --exchange-only late-stop
assert_ne "dropping ongoing progress validation makes the selftest red" 0 "$T_STATUS"
assert_contains "progress mutation reaches its final-window regression" 'not ok - unsolicited late-stop is rejected' "$T_OUT"
t_run python3 "$ROOT/tests/protocol/launcher_selftest.py" --shell "${S5_TEST_SHELL:-sh}" \
    --launcher "$S5_TEST_ROOT/early-ready.sh"
assert_ne "publishing readiness early makes the selftest red" 0 "$T_STATUS"
assert_contains "early readiness mutation reaches the delayed-listener regression" \
    'not ok - delayed listener never releases the protocol consumer early' "$T_OUT"

t_summary
