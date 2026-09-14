#!/bin/sh
# Memory evidence contracts remain separate from native workflow execution.

S5T_NAME=test_xray_memory_contract
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
_memory_reset=$(grep -n 'sample_request reset "conn\$stage"' "$ROOT/.github/scripts/memory-report.sh" | cut -d: -f1)
_memory_clear=$(grep -n 'rm -f "\$root/held"' "$ROOT/.github/scripts/memory-report.sh" | cut -d: -f1)
_memory_hold=$(grep -n 'python3 tests/protocol/hold_connections.py' "$ROOT/.github/scripts/memory-report.sh" | cut -d: -f1)
if [ -n "$_memory_reset" ] && [ -n "$_memory_clear" ] && [ -n "$_memory_hold" ] && \
    [ "$_memory_reset" -lt "$_memory_clear" ] && [ "$_memory_clear" -lt "$_memory_hold" ]; then
    t_ok
else
    t_bad "each stage resets peak and clears readiness before establishing connections"
fi
assert_contains "the memory job resolves the service cgroup" 'ControlGroup' "$memory_text"
assert_contains "the memory job records startup time" 'xray_startup_usec' "$memory_text"
assert_contains "the memory job samples 1, 32 and 128 connections" 'for stage in 1 32 128; do' "$memory_text"
assert_contains "the memory job proves the driver is outside the Xray cgroup" 'cgroup.procs' "$memory_text"
assert_contains "it names the pids that must stay outside" 'is inside the Xray cgroup' "$memory_text"
assert_contains "the memory job proves xray itself is inside the cgroup" 'not in its own cgroup' "$memory_text"
assert_contains "each connection stage carries its own label" 'sample_request sample "conn$stage"' "$memory_text"
assert_contains "the memory job asserts the cgroup OOM counters" 'memory.events' "$memory_text"
assert_contains "the memory job loads connections to sample under" 'hold_connections.py' "$memory_text"
assert_contains "the memory job runs paired comparison with explicit CI environment" \
    'sudo env GITHUB_ACTIONS=true python3 .github/scripts/memory-compare.py' "$memory_text"
assert_contains "paired comparison uses the installed verified binary" \
    '--binary /usr/local/libexec/xray-socks5/xray' "$memory_text"
assert_eq "the memory job drives the permitted target" 1 \
    "$(grep -c 'target-host 192.0.2.1' "$ROOT/.github/scripts/memory-report.sh")"
assert_eq "the memory target answers at denied addresses too" 1 \
    "$(grep -c 'duplex_target.py --host 0.0.0.0 --host6 ::' "$ROOT/.github/scripts/memory-report.sh")"
assert_contains "memory uses shared install credentials" 'lifecycle_write_fixtures "$root"' "$memory_text"
assert_contains "install credential checks use the fail-closed shared helper" \
    'lifecycle_no_credential_in "$root/install.log" "$install_secret" sudo' "$memory_text"
assert_contains "holder credential checks use the fail-closed shared helper" \
    'lifecycle_no_credential_in "$root/held.log" "$install_secret"' "$memory_text"
assert_not_contains "memory does not duplicate the fixture password" 'CISecret_123~x' "$memory_text"
assert_not_contains "workflow does not duplicate the fixture password" \
    'CISecret_123~x' "$(cat "$ROOT/.github/workflows/ci.yml")"
t_run env GITHUB_ACTIONS= sh "$ROOT/.github/scripts/memory-report.sh"
assert_eq "memory orchestration refuses outside GitHub Actions" 1 "$T_STATUS"
assert_contains "memory refusal explains the execution restriction" \
    'restricted to GitHub Actions' "$T_OUT"

t_summary
