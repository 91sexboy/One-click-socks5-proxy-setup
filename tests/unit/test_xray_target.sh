#!/bin/sh
# The duplex target must not splice two threads' frames onto one connection, nor
# two threads' metrics writes into one report.

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
# The metrics path is the same bug: main flushed the report from its finally with
# no lock held while workers were still flushing it under one, through a temporary
# every writer named the same.
assert_contains "the self-test serialises the metrics write" \
    'ok - the second metrics write waits for the first' "$T_OUT"
assert_contains "the self-test keeps the report whole" \
    'ok - the report holds every counter' "$T_OUT"
assert_contains "the self-test keeps concurrent temporaries apart" \
    'ok - the file holds one whole text and no splice' "$T_OUT"
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

# Nor does the metrics write prove anything unless a copy without its lock fails.
# This mutation targets the 4-space `with COUNT_LOCK:` in write_metrics; the
# per-counter ones inside serve and serve_connection are indented deeper and stay.
_ttdir=$S5_TEST_ROOT/unlocked-metrics
mkdir -p "$_ttdir"
sed 's/^    with COUNT_LOCK:$/    if True:/' \
    "$ROOT/tests/protocol/duplex_target.py" >"$_ttdir/duplex_target.py"
assert_contains "the unlocked-metrics copy dropped the lock" 'if True:' \
    "$(cat "$_ttdir/duplex_target.py")"
cp "$ROOT/tests/protocol/target_selftest.py" "$_ttdir/target_selftest.py"
t_run python3 "$_ttdir/target_selftest.py"
assert_ne "an unlocked metrics write fails the self-test" 0 "$T_STATUS"
assert_contains "the unlocked metrics write lets the second writer in" \
    'not ok - the second metrics write waits for the first' "$T_OUT"

# And a copy back on one shared temporary name has to fail it too.
_ttdir=$S5_TEST_ROOT/shared-temporary
mkdir -p "$_ttdir"
sed 's/^    tmp = .*$/    tmp = path + ".tmp"/' \
    "$ROOT/tests/protocol/duplex_target.py" >"$_ttdir/duplex_target.py"
assert_contains "the shared-temporary copy names one temporary" 'tmp = path + ".tmp"' \
    "$(cat "$_ttdir/duplex_target.py")"
cp "$ROOT/tests/protocol/target_selftest.py" "$_ttdir/target_selftest.py"
t_run python3 "$_ttdir/target_selftest.py"
assert_ne "a shared temporary fails the self-test" 0 "$T_STATUS"
assert_contains "the shared temporary splices the file" \
    'not ok - the file holds one whole text and no splice' "$T_OUT"

t_summary
