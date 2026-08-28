#!/bin/sh
# tests/lib/assert.sh - minimal POSIX sh assertion helpers.
# No framework dependency (SPEC 13). Sourced by every tests/unit/*.sh file.
#
# Each test file prints a final "TESTS <pass> <fail>" line that tests/run.sh aggregates,
# and exits non-zero if any assertion failed.

S5T_PASS=0
S5T_FAIL=0
S5T_SKIP=0
S5T_NAME=${S5T_NAME:-$(basename "$0")}

t_ok() {
    S5T_PASS=$((S5T_PASS + 1))
}

t_bad() {
    S5T_FAIL=$((S5T_FAIL + 1))
    printf 'not ok - %s\n' "$1" >&2
}

# t_skip <desc> <why> : recorded and reported as a skip. Never a pass.
t_skip() {
    S5T_SKIP=$((S5T_SKIP + 1))
    printf 'skip - %s (%s)\n' "$1" "$2"
}

# assert_eq <desc> <expected> <actual>
assert_eq() {
    if [ "$2" = "$3" ]; then
        t_ok
    else
        t_bad "$1: expected [$2] got [$3]"
    fi
}

# assert_ne <desc> <unexpected> <actual>
assert_ne() {
    if [ "$2" != "$3" ]; then
        t_ok
    else
        t_bad "$1: value should not be [$2]"
    fi
}

# assert_contains <desc> <needle> <haystack>
assert_contains() {
    case "$3" in
    *"$2"*) t_ok ;;
    *) t_bad "$1: [$3] does not contain [$2]" ;;
    esac
}

# assert_not_contains <desc> <needle> <haystack>
assert_not_contains() {
    case "$3" in
    *"$2"*) t_bad "$1: [$3] must not contain [$2]" ;;
    *) t_ok ;;
    esac
}

# assert_file_exists <desc> <path>
assert_file_exists() {
    if [ -f "$2" ]; then
        t_ok
    else
        t_bad "$1: file missing: $2"
    fi
}

# assert_dir_exists <desc> <path>
assert_dir_exists() {
    if [ -d "$2" ]; then
        t_ok
    else
        t_bad "$1: directory missing: $2"
    fi
}

# assert_file_absent <desc> <path>
assert_file_absent() {
    if [ -e "$2" ] || [ -L "$2" ]; then
        t_bad "$1: path should not exist: $2"
    else
        t_ok
    fi
}

# assert_mode <desc> <expected-octal> <path>
assert_mode() {
    _am=$(t_mode_of "$3")
    if [ "$_am" = "$2" ]; then
        t_ok
    else
        t_bad "$1: expected mode $2 got $_am on $3"
    fi
}

t_mode_of() {
    # GNU and busybox stat both accept -c. There is no ls fallback: parsing
    # `ls -l` for a numeric mode is not portable, and "unknown" makes assert_mode
    # fail loudly rather than quietly comparing against a guess.
    stat -c '%a' "$1" 2>/dev/null || printf 'unknown'
}

# t_run <cmd...> : run a command, capture combined output in T_OUT and status in T_STATUS.
# Never aborts the caller, even under set -e.
t_run() {
    T_OUT=$("$@" 2>&1) && T_STATUS=0 || T_STATUS=$?
    return 0
}

# t_run_sh <shell> <script> <args...>
t_run_sh() {
    _sh=$1
    shift
    t_run "$_sh" "$@"
}

# t_mktestroot: create an isolated test root with the .s5-test-root sentinel and
# export S5_TEST_ROOT / S5_TEST_MODE. Registers cleanup on EXIT.
t_mktestroot() {
    S5_TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/s5test.XXXXXX") || {
        printf 'cannot create test root\n' >&2
        exit 1
    }
    : >"$S5_TEST_ROOT/.s5-test-root"
    S5_TEST_MODE=1
    export S5_TEST_ROOT S5_TEST_MODE
    # shellcheck disable=SC2064
    trap "t_cleanup_root" EXIT HUP INT TERM
}

t_cleanup_root() {
    if [ -n "${S5_TEST_ROOT:-}" ]; then
        case "$S5_TEST_ROOT" in
        /tmp/s5test.* | "${TMPDIR:-/tmp}"/s5test.*)
            rm -rf "$S5_TEST_ROOT"
            ;;
        *)
            printf 'refusing to remove suspicious test root: %s\n' "$S5_TEST_ROOT" >&2
            ;;
        esac
    fi
}

t_summary() {
    printf 'TESTS %d %d\n' "$S5T_PASS" "$S5T_FAIL"
    printf 'SKIPS %d\n' "$S5T_SKIP"
    if [ "$S5T_FAIL" -ne 0 ]; then
        printf '%s: %d failed\n' "$S5T_NAME" "$S5T_FAIL" >&2
        exit 1
    fi
    exit 0
}
