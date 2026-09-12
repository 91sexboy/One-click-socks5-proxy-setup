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
    _cliroot=${CLI_ROOT:-}
    if [ -z "$_cliroot" ]; then
        _cliroot=$(mktemp -d "$S5_TEST_ROOT/cli.XXXXXX") || exit 1
        : >"$_cliroot/.s5-test-root"
    fi
    # S5_OSRELEASE is passed quoted and empty when unused: socks5.sh reads it as
    # ${S5_OSRELEASE:-/etc/os-release}, so empty is the default, and an unquoted
    # VAR=VALUE word would split on the spaces in this repository's own path and
    # leave env treating a path fragment as the command to run.
    # S5_TEST_SHELL may be a multi-word command such as `busybox sh`.
    # shellcheck disable=SC2086
    T_OUT=$(env S5_TEST_MODE=1 S5_TEST_ROOT="$_cliroot" \
        S5_ASSUME_ROOT="${CLI_ASSUME_ROOT:-1}" S5_SKIP_OWNERSHIP=1 \
        S5_OSRELEASE="${CLI_OSRELEASE:-}" \
        ${S5_TEST_SHELL:-sh} "$ROOT/socks5.sh" "$@" \
        <"$S5_TEST_ROOT/stdin" 2>&1) && T_STATUS=0 || T_STATUS=$?
    return 0
}

t_prompt_count() {
    printf '%s\n' "$1" | grep -c 'Choose language'
}

# A first invocation asks once before dispatch; later invocations reuse the choice.
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

CLI_ROOT=$S5_TEST_ROOT
cli '2
' help
assert_eq "the first invocation accepts English" 0 "$T_STATUS"
cli '' help
assert_eq "a later invocation needs no language input" 0 "$T_STATUS"
assert_eq "a later invocation does not ask for language" 0 "$(t_prompt_count "$T_OUT")"
assert_contains "a later invocation retains English" 'Usage: sh socks5.sh' "$T_OUT"
cli '1
' language
assert_eq "the language command changes the saved choice" 0 "$T_STATUS"
assert_eq "changing language asks exactly once" 1 "$(t_prompt_count "$T_OUT")"
cli '' help
assert_eq "the changed language needs no further input" 0 "$T_STATUS"
assert_eq "the changed language is remembered without a prompt" 0 "$(t_prompt_count "$T_OUT")"
assert_contains "a later invocation uses the changed Chinese preference" '用法：sh socks5.sh' "$T_OUT"
cli '2
' language extra
assert_eq "extra arguments are refused by the language command" 64 "$T_STATUS"
cli '' help
assert_contains "a rejected language command leaves the saved choice intact" '用法：sh socks5.sh' "$T_OUT"
cli '' language
assert_ne "EOF cancels an explicit language change" 0 "$T_STATUS"
cli '' help
assert_contains "a cancelled language change leaves the saved choice intact" '用法：sh socks5.sh' "$T_OUT"

CLI_ASSUME_ROOT=0
cli '' help
assert_eq "unprivileged help can reuse the saved language" 0 "$T_STATUS"
assert_eq "unprivileged help does not prompt again" 0 "$(t_prompt_count "$T_OUT")"
cli '2
' language
assert_ne "an unprivileged language change cannot claim it was saved" 0 "$T_STATUS"
assert_contains "an unsaved preference is reported" 'could not save the language preference' "$T_OUT"
CLI_ASSUME_ROOT=1
cli '' help
assert_contains "an unprivileged change leaves the shared preference intact" '用法：sh socks5.sh' "$T_OUT"

# Preferences are data, never shell code; a malformed value asks again.
printf '$(touch %s)\n' "$S5_TEST_ROOT/executed" >"$CLI_ROOT/etc/xray-socks5.lang"
cli '2
' help
assert_eq "a malformed preference can be replaced by a valid choice" 0 "$T_STATUS"
assert_eq "a malformed preference prompts exactly once" 1 "$(t_prompt_count "$T_OUT")"
assert_file_absent "a preference is never executed as shell code" "$S5_TEST_ROOT/executed"
cli '' help
assert_contains "the replacement preference is remembered" 'Usage: sh socks5.sh' "$T_OUT"

# Unsafe paths are not followed or replaced, even when persistence fails.
rm "$CLI_ROOT/etc/xray-socks5.lang"
printf 'en\n' >"$S5_TEST_ROOT/foreign-language"
ln -s "$S5_TEST_ROOT/foreign-language" "$CLI_ROOT/etc/xray-socks5.lang"
cli '1
' help
assert_eq "an unsafe preference does not prevent help" 0 "$T_STATUS"
assert_contains "an unsafe preference is not silently saved" '无法保存语言设置' "$T_OUT"
assert_eq "a language symlink target is untouched" en "$(cat "$S5_TEST_ROOT/foreign-language")"
if [ -L "$CLI_ROOT/etc/xray-socks5.lang" ]; then
    t_ok
else
    t_bad "the language symlink was replaced"
fi
rm "$CLI_ROOT/etc/xray-socks5.lang"
printf 'en\n' >"$CLI_ROOT/etc/xray-socks5.lang"
chmod 0666 "$CLI_ROOT/etc/xray-socks5.lang"
cli '1
' help
assert_eq "a writable preference is not trusted" 1 "$(t_prompt_count "$T_OUT")"
assert_contains "a writable preference is not overwritten" '无法保存语言设置' "$T_OUT"
assert_eq "an unsafe preference keeps its original contents" en "$(cat "$CLI_ROOT/etc/xray-socks5.lang")"

t_summary
