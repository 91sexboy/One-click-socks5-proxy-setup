#!/bin/sh
# The duplex target must not splice two threads' frames onto one connection.

S5T_NAME=test_xray_target
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
ROOT=${S5_REPO_ROOT}
t_mktestroot

if ! command -v python3 >/dev/null 2>&1; then
    t_skip "duplex target frame writer is serialised" "python3 is unavailable"
    t_summary
    exit 0
fi

# The protocol gate's own failure mode: the target sent each frame in two pieces
# from two threads with no lock, so the client parsed a spliced header and
# reported a wrong cid and nonce. Reproduced at 83% with the write window
# widened to 10ms, and 0% once the writes were serialised.
t_run python3 "$ROOT/tests/protocol/target_selftest.py"
assert_eq "duplex target frame writer is serialised" 0 "$T_STATUS"
assert_contains "the self-test reports no spliced frame" \
    'ok - the stream carries no spliced frame' "$T_OUT"
assert_contains "the self-test keeps every cid" \
    'ok - every frame keeps its cid' "$T_OUT"
assert_not_contains "the self-test has no failing check" 'not ok' "$T_OUT"

# A writer without the lock has to fail this test, or it proves nothing.
_ttdir=$S5_TEST_ROOT/unlocked
mkdir -p "$_ttdir"
sed 's/^        with self\._lock:$/        if True:/' \
    "$ROOT/tests/protocol/duplex_target.py" >"$_ttdir/duplex_target.py"
assert_contains "the unlocked copy dropped the lock" 'if True:' \
    "$(cat "$_ttdir/duplex_target.py")"
cp "$ROOT/tests/protocol/target_selftest.py" "$_ttdir/target_selftest.py"
t_run python3 "$_ttdir/target_selftest.py"
assert_ne "an unlocked frame writer fails the self-test" 0 "$T_STATUS"

t_summary
