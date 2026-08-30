#!/bin/sh
# tests/unit/test_interrupt.sh - a real SIGINT during visible password input
# must leave the installation, transaction state, and mutation lock clean.
#
# Delegates to tests/pty/interrupt.py because POSIX sh cannot allocate a pty.
# Python is a TEST-only dependency; socks5.sh never uses it.

S5T_NAME=test_interrupt
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
. "${S5_REPO_ROOT}/tests/lib/stub.sh"
. "${S5_REPO_ROOT}/tests/lib/env.sh"

s5env_setup

if ! command -v python3 >/dev/null 2>&1; then
    t_skip "PTY interrupt test" "python3 is not available on this machine"
    t_summary
fi

t_run python3 "${S5_REPO_ROOT}/tests/pty/interrupt.py" "$S5_TEST_ROOT" "$S5_TEST_ROOT/bin"
assert_eq "the pty interrupt scenario passes" 0 "$T_STATUS"

# Surface the individual checks so a failure is diagnosable from the log.
printf '%s\n' "$T_OUT" | while IFS= read -r _l; do
    case "$_l" in
    'not ok'*) printf '    %s\n' "$_l" >&2 ;;
    *) ;;
    esac
done

assert_contains "echo remains enabled during password entry" \
    "terminal echo remains ENABLED while" "$T_OUT"
assert_contains "echo remains enabled after SIGINT" \
    "terminal echo remains ENABLED after" "$T_OUT"
assert_contains "SIGINT releases the mutation lock" \
    "operation lock was released" "$T_OUT"
assert_not_contains "no pty check failed" "not ok" "$T_OUT"

t_summary
