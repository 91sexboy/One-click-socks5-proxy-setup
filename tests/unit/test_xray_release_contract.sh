#!/bin/sh
# Independent release-pin mutations and fixture compatibility.

S5T_NAME=test_xray_release_contract
. "${S5_REPO_ROOT}/tests/lib/assert.sh"

t_run python3 "$S5_REPO_ROOT/tests/lib/release_contract_regression.py" "$S5_REPO_ROOT"
assert_eq "release declarations reject mutations without constraining fixtures" 0 "$T_STATUS"
if [ "$T_STATUS" -ne 0 ]; then
    printf '%s\n' "$T_OUT" >&2
fi
assert_contains "release contract regressions reached completion" \
    'checks passed' "$T_OUT"
t_summary
