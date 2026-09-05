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
# Set CLI_OSRELEASE to pin the detected platform for one call.
cli() {
    _stdin=$1
    shift
    printf '%s' "$_stdin" >"$S5_TEST_ROOT/stdin"
    # S5_OSRELEASE is passed quoted and empty when unused: socks5.sh reads it as
    # ${S5_OSRELEASE:-/etc/os-release}, so empty is the default, and an unquoted
    # VAR=VALUE word would split on the spaces in this repository's own path and
    # leave env treating a path fragment as the command to run.
    # S5_TEST_SHELL may be a multi-word command such as `busybox sh`.
    # shellcheck disable=SC2086
    T_OUT=$(env S5_TEST_MODE=1 S5_TEST_ROOT="$S5_TEST_ROOT" \
        S5_ASSUME_ROOT=1 S5_SKIP_OWNERSHIP=1 \
        S5_OSRELEASE="${CLI_OSRELEASE:-}" \
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

# README.md documents bare `sh socks5.sh` as the install command and s5_main maps
# '' and install to one arm, so the two must behave identically. shift is a POSIX
# special built-in: shifting past the end terminates a non-interactive shell, so
# the zero-argument form used to die before dispatch under dash while `install`
# worked. Every other case here, and every CI step, passes an explicit
# subcommand, which is why nothing caught it. The platform is pinned to a
# rejected fixture so both calls stop at the same early, deterministic point.
CLI_OSRELEASE="$ROOT/tests/fixtures/os-release/alpine-3.19"
cli '2
'
_barestatus=$T_STATUS
_bareout=$T_OUT
cli '2
' install
CLI_OSRELEASE=''
assert_eq "a bare invocation asks for language exactly once" \
    1 "$(t_prompt_count "$_bareout")"
assert_eq "a bare invocation exits like install" "$T_STATUS" "$_barestatus"
assert_eq "a bare invocation behaves like install" "$T_OUT" "$_bareout"

t_summary
