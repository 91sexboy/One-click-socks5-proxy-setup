#!/bin/sh
# tests/run.sh - dependency-free POSIX sh test runner.
#
#   sh tests/run.sh                      # run every unit test with /bin/sh
#   S5_TEST_SHELL=dash sh tests/run.sh   # run them under dash
#   S5_TEST_SHELL='busybox sh' sh tests/run.sh
#   sh tests/run.sh test_detect          # run only matching files
#
# Exits non-zero if any test file fails.

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
UNIT_DIR="$ROOT/tests/unit"
SHELL_UNDER_TEST=${S5_TEST_SHELL:-sh}
FILTER=${1:-}

total_pass=0
total_fail=0
total_skip=0
files=0
bad_files=0

for f in "$UNIT_DIR"/*.sh; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    if [ -n "$FILTER" ]; then
        case "$base" in
        *"$FILTER"*) ;;
        *) continue ;;
        esac
    fi
    files=$((files + 1))

    # Each test file runs in its own process with a clean environment so that one
    # file's S5_* variables cannot leak into the next.
    if out=$(env -u S5_TEST_MODE -u S5_TEST_ROOT -u S5_LIB_ONLY \
        S5_SRC="$ROOT/socks5.sh" S5_REPO_ROOT="$ROOT" \
        $SHELL_UNDER_TEST "$f" 2>&1); then
        st=0
    else
        st=$?
    fi

    counts=$(printf '%s\n' "$out" | grep '^TESTS ' | tail -n 1)
    skips=$(printf '%s\n' "$out" | grep '^SKIPS ' | tail -n 1)
    sk=0
    if [ -n "$skips" ]; then
        sk=$(printf '%s\n' "$skips" | cut -d' ' -f2)
        total_skip=$((total_skip + sk))
    fi

    # A file that never reaches t_summary emits no TESTS line. Without this
    # guard such a file would be reported as "ok" while asserting nothing.
    if [ -z "$counts" ]; then
        bad_files=$((bad_files + 1))
        printf 'FAIL %s (no TESTS line: the file asserted nothing)\n' "$base"
        printf '%s\n' "$out" | sed 's/^/     | /'
        continue
    fi
    p=$(printf '%s\n' "$counts" | cut -d' ' -f2)
    fl=$(printf '%s\n' "$counts" | cut -d' ' -f3)
    total_pass=$((total_pass + p))
    total_fail=$((total_fail + fl))
    if [ "$p" -eq 0 ] && [ "$fl" -eq 0 ] && [ "$sk" -eq 0 ]; then
        bad_files=$((bad_files + 1))
        printf 'FAIL %s (no assertions and no skips)\n' "$base"
        continue
    fi

    if [ "$st" -eq 0 ]; then
        printf 'ok   %s\n' "$base"
    else
        bad_files=$((bad_files + 1))
        printf 'FAIL %s (exit %s)\n' "$base" "$st"
        printf '%s\n' "$out" | sed 's/^/     | /'
    fi
done

# The number of unit files is pinned. Without this the suite's own coverage is
# unfalsifiable: deleting a test file, or renaming one out of the *.sh glob,
# drops it silently and the run still reports green -- so "the tests pass" would
# survive removing the test that fails. Only meaningful for a full run; a FILTER
# is expected to select a subset. Bumping this number must be a deliberate act.
EXPECTED_UNIT_FILES=20
if [ -z "$FILTER" ] && [ "$files" -ne "$EXPECTED_UNIT_FILES" ]; then
    bad_files=$((bad_files + 1))
    printf 'FAIL unit file count is %d, expected %d\n' \
        "$files" "$EXPECTED_UNIT_FILES"
    printf '     A test file was added or removed. Update EXPECTED_UNIT_FILES\n'
    printf '     in tests/run.sh deliberately, in the same change.\n'
fi

printf -- '----\n'
printf 'shell: %s\n' "$SHELL_UNDER_TEST"
printf 'files: %d, failed files: %d\n' "$files" "$bad_files"
printf 'assertions: %d passed, %d failed\n' "$total_pass" "$total_fail"
if [ "$total_skip" -ne 0 ]; then
    printf 'skipped: %d (a skip is NOT a pass)\n' "$total_skip"
fi

if [ "$files" -eq 0 ]; then
    printf 'no test files matched\n' >&2
    exit 1
fi
if [ "$bad_files" -ne 0 ] || [ "$total_fail" -ne 0 ]; then
    exit 1
fi
exit 0
