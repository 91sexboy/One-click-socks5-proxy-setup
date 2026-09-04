#!/bin/sh
# Command-line entry behaviour of a real invocation.
#
# These run socks5.sh as a child process rather than sourcing it: how many
# times a prompt is issued, and whether dispatch happens at all, is only
# observable from outside the script.

S5T_NAME=test_xray_cli
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
ROOT=${S5_REPO_ROOT}
t_mktestroot

# cli <stdin-text> <argv...> : run socks5.sh as a child, leaving T_OUT/T_STATUS.
cli() {
    _stdin=$1
    shift
    printf '%s' "$_stdin" >"$S5_TEST_ROOT/stdin"
    # S5_TEST_SHELL may be a multi-word command such as `busybox sh`.
    # shellcheck disable=SC2086
    T_OUT=$(env S5_TEST_MODE=1 S5_TEST_ROOT="$S5_TEST_ROOT" \
        S5_ASSUME_ROOT=1 S5_SKIP_OWNERSHIP=1 \
        ${S5_TEST_SHELL:-sh} "$ROOT/socks5.sh" "$@" \
        <"$S5_TEST_ROOT/stdin" 2>&1) && T_STATUS=0 || T_STATUS=$?
    return 0
}

t_prompt_count() {
    printf '%s\n' "$1" | grep -c 'Choose language'
}

# SPEC 2: every real invocation asks for language before command dispatch --
# once, not once per dispatch layer.
cli '2
' status
assert_eq "status asks for language exactly once" 1 "$(t_prompt_count "$T_OUT")"
assert_not_contains "one answer is enough for status" 'invalid language' "$T_OUT"

cli '2
' help
assert_eq "help asks for language exactly once" 1 "$(t_prompt_count "$T_OUT")"
assert_eq "help succeeds" 0 "$T_STATUS"
assert_contains "help prints usage" 'Usage: sh socks5.sh' "$T_OUT"

# SPEC 2: invalid input is retried with a bounded count, and EOF fails.
cli 'x
2
' status
assert_eq "an invalid language answer is retried" 2 "$(t_prompt_count "$T_OUT")"
assert_contains "an invalid language answer is reported" 'invalid language' "$T_OUT"

cli 'x
x
x
x
x
' status
assert_ne "invalid answers do not loop forever" 0 "$T_STATUS"
assert_eq "language retries are bounded at three attempts" 3 "$(t_prompt_count "$T_OUT")"

cli '' status
assert_ne "EOF on the language prompt fails" 0 "$T_STATUS"
assert_eq "EOF is not retried" 1 "$(t_prompt_count "$T_OUT")"

t_summary
