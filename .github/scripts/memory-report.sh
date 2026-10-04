#!/bin/sh
# Native memory orchestration; target and load driver stay outside the service cgroup.
set -eu
if [ "${GITHUB_ACTIONS:-}" != true ]; then
    printf 'memory-report is restricted to GitHub Actions\n' >&2
    exit 1
fi
# shellcheck source=.github/scripts/lifecycle-common.sh
. "$(dirname "$0")/lifecycle-common.sh"
# shellcheck source=.github/scripts/lifecycle-cleanup.sh
. "$(dirname "$0")/lifecycle-cleanup.sh"
# shellcheck source=.github/scripts/memory-hold.sh
. "$(dirname "$0")/memory-hold.sh"
root=$(mktemp -d)
# The cleanup seam removes work once its children are stopped.
work=$root
lifecycle_cleanup_namespace() {
    sh .github/scripts/remove-xray-namespace.sh
}
sampler_gone() { ! test -e "/proc/$sampler_pid"; }
# The sampler and the connection holder are this script's own helpers; the seam
# stops them before the duplex target.
lifecycle_cleanup_children() {
    if test -n "${sampler_pid:-}"; then
        printf 'quit\n' >&3 || true
        exec 3>&-
        lifecycle_wait_until 30 0.1 sampler_gone || true
        sudo kill -TERM "$sampler_pid" 2>/dev/null || true
        wait "$sampler_pid" 2>/dev/null || true
        sampler_pid=''
    fi
    if test -n "${holder_pid:-}"; then
        lifecycle_stop_child "$holder_pid"
        holder_pid=''
    fi
}
lifecycle_cleanup_init
chmod 0700 "$root"
lifecycle_write_fixtures "$root"
sudo sh .github/scripts/run-socks5.sh install \
    "$root/answers" "$root/install.log" "$root/pass"
pid=$(systemctl show xray-socks5.service -p MainPID --value)
test "$pid" -gt 0
printf 'xray_process_pid=%s\n' "$pid"
# This timestamp delta is not listener readiness or an installation benchmark.
printf 'xray_startup_measurement=systemd_state_transition_not_listener_readiness\n'
entered=$(systemctl show xray-socks5.service -p ActiveEnterTimestampMonotonic --value)
exited=$(systemctl show xray-socks5.service -p InactiveExitTimestampMonotonic --value)
test -n "$entered" && test -n "$exited"
printf 'xray_startup_usec=%s\n' "$((entered - exited))"
cgroup=$(systemctl show xray-socks5.service -p ControlGroup --value)
cgdir="/sys/fs/cgroup$cgroup"
lifecycle_start_duplex_target "$root"
# One process retains the descriptor across every reset and sample.
mkfifo "$root/sample.commands"
exec 3<>"$root/sample.commands"
# The runner owns these channels; only the cgroup descriptor needs root.
# shellcheck disable=SC2024
sudo timeout --kill-after=5 180 sh .github/scripts/memory-sample.sh "$pid" "$cgdir" \
    <"$root/sample.commands" 3>&- >"$root/samples" 2>"$root/sample.errors" &
sampler_pid=$!
# Acknowledged, or the sampler is gone and will never acknowledge.
sample_answered() { grep -qx "$1" "$root/samples" || sampler_gone; }
sample_request() {
    printf '%s %s\n' "$1" "$2" >&3
    lifecycle_wait_until 150 0.2 sample_answered "${2}_${1}=ok" || true
    if ! grep -qx "${2}_${1}=ok" "$root/samples"; then
        printf 'memory sampler did not acknowledge %s %s\n' "$1" "$2" >&2
        cat "$root/sample.errors" >&2
        return 1
    fi
}
# Each label is evidence only for tunnels that echoed a frame at readiness and
# again before and after the sample, counted live by the target in every check.
printf 'memory_workload=held_authenticated_tunnels_echo_verified_around_each_sample_target_and_driver_outside_xray_cgroup\n'
# The holder failed a check, or its log explains why it never became ready.
memory_stage_failed() {
    sudo sh .github/scripts/run-socks5.sh --diagnose memory-holder \
        "$root/answers" "$root/held.log" "$root/pass" || true
    exit 1
}
sample_request reset idle
memory_hold_idle "$root" before_sample
sample_request sample idle
memory_hold_idle "$root" after_sample
for stage in 1 32 128; do
    # Reset before establishment so the peak includes opening the tunnels.
    sample_request reset "conn$stage"
    memory_hold_start "$root" "$stage" 23456 192.0.2.1 "$target_port" || memory_stage_failed
    procs=$(sudo cat "$cgdir/cgroup.procs")
    printf 'conn%s_cgroup_procs=%s\n' "$stage" "$(printf '%s' "$procs" | tr '\n' ' ')"
    if ! printf '%s\n' "$procs" | grep -qx "$pid"; then
        printf 'xray pid %s is not in its own cgroup\n' "$pid" >&2
        exit 1
    fi
    for outside in "$target_pid" "$holder_pid"; do
        if printf '%s\n' "$procs" | grep -qx "$outside"; then
            printf 'pid %s is inside the Xray cgroup\n' "$outside" >&2
            exit 1
        fi
    done
    memory_hold_verify "$root" "$stage" before_sample || memory_stage_failed
    sample_request sample "conn$stage"
    memory_hold_verify "$root" "$stage" after_sample || memory_stage_failed
    memory_hold_stop "$root" "$stage" || memory_stage_failed
done
printf 'quit\n' >&3
wait "$sampler_pid"
sampler_pid=''
exec 3>&-
cat "$root/samples"
# systemd's peak remains the lifetime peak, not a stage sample.
printf 'systemd_memory_current_bytes=%s\n' "$(systemctl show xray-socks5.service -p MemoryCurrent --value)"
printf 'systemd_memory_peak_bytes=%s\n' "$(systemctl show xray-socks5.service -p MemoryPeak --value)"
restarts=$(systemctl show xray-socks5.service -p NRestarts --value)
printf 'xray_restart_count=%s\n' "$restarts"
test "$restarts" = 0
test "$(awk '$1 == "oom" {print $2}' "$cgdir/memory.events")" = 0
test "$(awk '$1 == "oom_kill" {print $2}' "$cgdir/memory.events")" = 0
sudo systemctl is-active --quiet xray-socks5.service
# Every form, not only the bare password: user:pass and its base64 as well.
lifecycle_generation_absent "$root/install.log" "$root/pass" sudo
lifecycle_generation_absent "$root/held.log" "$root/pass"
sudo env GITHUB_ACTIONS=true python3 .github/scripts/memory-compare.py \
    --binary /usr/local/libexec/xray-socks5/xray \
    --config /etc/xray-socks5/config.json \
    --target-port "$target_port" --output "$root/memory-comparison.json"
sudo install -m 0644 "$root/memory-comparison.json" \
    "$GITHUB_WORKSPACE/memory-comparison-$XRAY_ARCH.json"
