#!/bin/sh
# The memory-report gate: what it samples and asserts, and that it refuses to run
# outside GitHub Actions.

S5T_NAME=test_xray_memory_report
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
ROOT=${S5_REPO_ROOT}
t_mktestroot

sampler_text=$(cat "$ROOT/.github/scripts/memory-sampler.py")
memory_text=$(cat "$ROOT/.github/scripts/memory-report.sh")
assert_contains "the sampler records cgroup OOM counters" '_cgroup_oom=' "$sampler_text"
assert_contains "the sampler records cgroup OOM kills" '_cgroup_oom_kill=' "$sampler_text"
assert_contains "the sampler records the actual kernel release" 'kernel_release=' "$sampler_text"
assert_contains "the memory job starts one sampler with the service cgroup" \
    'memory-sample.sh "$pid" "$cgdir"' "$memory_text"
assert_contains "the memory job resets its idle stage through the persistent sampler" \
    'sample_request reset idle' "$memory_text"
assert_contains "systemd transition timing is not called listener readiness" \
    'xray_startup_measurement=systemd_state_transition_not_listener_readiness' "$memory_text"
hold_text=$(cat "$ROOT/.github/scripts/memory-hold.sh")
_memory_reset=$(grep -n 'sample_request reset "conn\$stage"' "$ROOT/.github/scripts/memory-report.sh" | cut -d: -f1)
_memory_start=$(grep -n 'memory_hold_start "\$root" "\$stage"' "$ROOT/.github/scripts/memory-report.sh" | cut -d: -f1)
_memory_before=$(grep -n 'memory_hold_verify "\$root" "\$stage" before_sample' "$ROOT/.github/scripts/memory-report.sh" | cut -d: -f1)
_memory_sample=$(grep -n 'sample_request sample "conn\$stage"' "$ROOT/.github/scripts/memory-report.sh" | cut -d: -f1)
_memory_after=$(grep -n 'memory_hold_verify "\$root" "\$stage" after_sample' "$ROOT/.github/scripts/memory-report.sh" | cut -d: -f1)
_memory_stop=$(grep -n 'memory_hold_stop "\$root" "\$stage"' "$ROOT/.github/scripts/memory-report.sh" | cut -d: -f1)
if [ -n "$_memory_reset" ] && [ -n "$_memory_start" ] && [ -n "$_memory_before" ] && \
    [ -n "$_memory_sample" ] && [ -n "$_memory_after" ] && [ -n "$_memory_stop" ] && \
    [ "$_memory_reset" -lt "$_memory_start" ] && [ "$_memory_start" -lt "$_memory_before" ] && \
    [ "$_memory_before" -lt "$_memory_sample" ] && [ "$_memory_sample" -lt "$_memory_after" ] && \
    [ "$_memory_after" -lt "$_memory_stop" ]; then
    t_ok
else
    t_bad "each stage resets its peak, then proves its tunnels live before and after the sample and stops the holder"
fi
_hold_launch=$(grep -n 'python3 tests/protocol/hold_connections.py' "$ROOT/.github/scripts/memory-hold.sh" | cut -d: -f1)
_hold_clear=$(sed -n "$((${_hold_launch:-1} - 1))p" "$ROOT/.github/scripts/memory-hold.sh")
if [ -n "$_hold_launch" ] && [ "$_hold_clear" = '    rm -f "$1/held" "$1/held.check"' ]; then
    t_ok
else
    t_bad "each stage clears the holder's answers before establishing connections"
fi
assert_contains "the idle stage proves the target holds no tunnel around its sample" \
    'memory_hold_idle "$root" after_sample' "$memory_text"
assert_contains "the memory job resolves the service cgroup" 'ControlGroup' "$memory_text"
assert_contains "the memory job records startup time" 'xray_startup_usec' "$memory_text"
assert_contains "the memory job samples 1, 32 and 128 connections" 'for stage in 1 32 128; do' "$memory_text"
assert_contains "the memory job proves the driver is outside the Xray cgroup" 'cgroup.procs' "$memory_text"
assert_contains "it names the pids that must stay outside" 'is inside the Xray cgroup' "$memory_text"
assert_contains "the memory job proves xray itself is inside the cgroup" 'not in its own cgroup' "$memory_text"
assert_contains "each connection stage carries its own label" 'sample_request sample "conn$stage"' "$memory_text"
assert_contains "the memory job asserts the cgroup OOM counters" 'memory.events' "$memory_text"
assert_contains "the memory job loads connections to sample under" 'hold_connections.py' "$hold_text"
assert_contains "the memory job runs paired comparison with explicit CI environment" \
    'sudo env GITHUB_ACTIONS=true python3 .github/scripts/memory-compare.py' "$memory_text"
assert_contains "paired comparison uses the installed verified binary" \
    '--binary /usr/local/libexec/xray-socks5/xray' "$memory_text"
assert_eq "the memory job drives the permitted target" 1 \
    "$(grep -c '23456 192.0.2.1 "$target_port"' "$ROOT/.github/scripts/memory-report.sh")"
assert_eq "the memory job starts the shared duplex target" 1 \
    "$(grep -c 'lifecycle_start_duplex_target "$root"' "$ROOT/.github/scripts/memory-report.sh")"
assert_eq "the memory job writes no wait loop of its own" 0 \
    "$(grep -c 'seq 1' "$ROOT/.github/scripts/memory-report.sh")"
assert_contains "the memory job cleans up through the shared seam" \
    'lifecycle_cleanup_init' "$memory_text"
assert_contains "memory uses shared install credentials" 'lifecycle_write_fixtures "$root"' "$memory_text"
assert_contains "install credential checks cover every credential form" \
    'lifecycle_generation_absent "$root/install.log" "$root/pass" sudo' "$memory_text"
assert_contains "holder credential checks cover every credential form" \
    'lifecycle_generation_absent "$root/held.log" "$root/pass"' "$memory_text"
assert_not_contains "memory does not duplicate the fixture password" 'CISecret123x' "$memory_text"
assert_not_contains "workflow does not duplicate the fixture password" \
    'CISecret123x' "$(cat "$ROOT/.github/workflows/ci.yml")"
# The holder and its coordinator against the real duplex target, with a SOCKS5
# stand-in that grants before it dials, as Xray does.
t_run python3 "$ROOT/tests/protocol/memory_holder_selftest.py" --shell "${S5_TEST_SHELL:-sh}"
assert_eq "held-connection labels need live, target-counted tunnels" 0 "$T_STATUS"
assert_not_contains "the holder self-test has no failing check" 'not ok' "$T_OUT"
for _held_case in \
    'a granted handshake to an unreachable target is refused at its own step' \
    'a tunnel that never answers its hello is refused at its own step' \
    'echoes the target never counted is refused at its own step' \
    'tunnels cut after readiness is refused at its own step' \
    'tunnels cut across the sample is refused at its own step' \
    'a holder killed after readiness is refused at its own step' \
    'a holder gone before its stop request fails the stage'; do
    assert_contains "holder self-test: $_held_case" "ok - $_held_case" "$T_OUT"
done
# Split a configured multiword shell such as busybox sh.
# shellcheck disable=SC2086
t_run env GITHUB_ACTIONS= ${S5_TEST_SHELL:-sh} "$ROOT/.github/scripts/memory-report.sh"
assert_eq "memory orchestration refuses outside GitHub Actions" 1 "$T_STATUS"
assert_contains "memory refusal explains the execution restriction" \
    'restricted to GitHub Actions' "$T_OUT"

t_summary
