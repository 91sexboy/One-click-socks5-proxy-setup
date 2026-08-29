#!/bin/sh
# tests/unit/test_interrupt.sh - B3 regression, PTY half: a real SIGINT during
# password entry must restore the terminal and leave nothing behind.
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

assert_contains "echo was disabled during password entry" \
    "terminal echo is DISABLED" "$T_OUT"
assert_contains "echo was restored after SIGINT" \
    "terminal echo is RESTORED" "$T_OUT"
assert_not_contains "no pty check failed" "not ok" "$T_OUT"

# If `stty -g` cannot capture the original state, the script must refuse before
# running `stty -echo`; otherwise a password prompt can leave the terminal in an
# un-restorable state.
t_run python3 "${S5_ROOT_TEST_ROOT:-${S5_REPO_ROOT}}/tests/pty/stty_capture.py" "$S5_TEST_ROOT" "$S5_TEST_ROOT/bin"
assert_eq "English stty-failure scenario passes" 0 "$T_STATUS"
# BF-07: the Chinese-default selection on a real pty. Blank input selects
# Chinese; the driver still verifies the same termios invariants.
t_run python3 "${S5_REPO_ROOT}/tests/pty/stty_capture.py" "$S5_TEST_ROOT" "$S5_TEST_ROOT/bin" ""
assert_eq "Chinese-default stty-failure scenario passes" 0 "$T_STATUS"
assert_eq "the stty capture failure scenario passes" 0 "$T_STATUS"
assert_contains "the capture failure keeps echo enabled" \
    "echo remains enabled" "$T_OUT"
assert_not_contains "the capture failure scenario has no failed check" \
    "not ok" "$T_OUT"

t_summary
