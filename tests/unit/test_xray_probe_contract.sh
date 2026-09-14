#!/bin/sh
# Protocol marker requirements and destination-control ordering.

S5T_NAME=test_xray_probe_contract
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
ROOT=${S5_REPO_ROOT}

_boundary_probe=$(cat "$ROOT/tests/protocol/xray_mixed.py")
assert_contains "the probe reaches the denied address without the proxy" \
    'direct_control(denied)' "$_boundary_probe"
assert_contains "the probe reaches the denied hostname without the proxy" \
    'direct_control(denied_by_name)' "$_boundary_probe"
assert_eq "the mixed gate requires HTTP CONNECT to have run" 1 \
    "$(grep -c 'mixed_http_connect=ok' "$ROOT/tests/protocol/run_xray_mixed.sh")"
assert_eq "the mixed gate requires the boundary control to have run" 1 \
    "$(grep -c 'mixed_denied_control=ok' "$ROOT/tests/protocol/run_xray_mixed.sh")"
_boundary_control_line=$(grep -n 'direct_control(denied_by_name)' \
    "$ROOT/tests/protocol/xray_mixed.py" | head -n 1 | cut -d: -f1)
_boundary_refusal_line=$(grep -n 'atyp="hostname"' \
    "$ROOT/tests/protocol/xray_mixed.py" | head -n 1 | cut -d: -f1)
if [ -n "$_boundary_control_line" ] && [ -n "$_boundary_refusal_line" ] && [ "$_boundary_control_line" -lt "$_boundary_refusal_line" ]; then
    t_ok
else
    t_bad "the hostname control must run before the hostname refusal is asserted (control at ${_boundary_control_line:-none}, refusal at ${_boundary_refusal_line:-none})"
fi
assert_contains "the long-lived case prints its own marker" 'mixed_longlived=ok' "$_boundary_probe"
assert_eq "the mixed gate requires the long-lived tunnel to have run" 1 \
    "$(grep -c 'mixed_longlived=ok' "$ROOT/tests/protocol/run_xray_mixed.sh")"
for _dcconcurrency in 1 32 128; do
    assert_eq "the mixed gate requires $_dcconcurrency concurrent tunnels" 1 \
        "$(grep -c "mixed_concurrency_$_dcconcurrency=ok" "$ROOT/tests/protocol/run_xray_mixed.sh")"
done
assert_contains "the probe emits concurrency completion markers" \
    'mixed_concurrency_%d=ok' "$_boundary_probe"

t_summary
