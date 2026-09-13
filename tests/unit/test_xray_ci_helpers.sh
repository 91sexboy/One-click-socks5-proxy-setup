#!/bin/sh
# Nonprivileged behavioral checks for CI process ownership and memory sampling.
S5T_NAME=test_xray_ci_helpers
. "${S5_REPO_ROOT}/tests/lib/assert.sh"

t_run python3 "$S5_REPO_ROOT/tests/protocol/ci_cleanup_selftest.py" "$S5_REPO_ROOT"
assert_eq "lifecycle target stops and is reaped on every exit path" 0 "$T_STATUS"
if [ "$T_STATUS" -ne 0 ]; then printf '%s\n' "$T_OUT" >&2; fi

t_run python3 "$S5_REPO_ROOT/tests/protocol/memory_sampler_selftest.py" "$S5_REPO_ROOT"
assert_eq "sampler keeps reset state across high and low workloads" 0 "$T_STATUS"
if [ "$T_STATUS" -ne 0 ]; then printf '%s\n' "$T_OUT" >&2; fi

t_summary
