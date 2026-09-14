#!/bin/sh
# Native memory orchestration; target and load driver stay outside the service cgroup.
set -eu
if [ "${GITHUB_ACTIONS:-}" != true ]; then
  printf 'memory-report is restricted to GitHub Actions\n' >&2
  exit 1
fi
# shellcheck source=.github/scripts/lifecycle-common.sh
. "$(dirname "$0")/lifecycle-common.sh"
root=$(mktemp -d)
stop_background() {
  stop_pid=$1
  kill -TERM "$stop_pid" 2>/dev/null || true
  for n in $(seq 1 30); do kill -0 "$stop_pid" 2>/dev/null || break; sleep 0.1; done
  kill -KILL "$stop_pid" 2>/dev/null || true
  wait "$stop_pid" 2>/dev/null || true
}
cleanup() {
  cleanup_status=$?
  trap '' HUP INT TERM
  if test -n "${sampler_pid:-}"; then
    printf 'quit\n' >&3 || true
    exec 3>&-
    for n in $(seq 1 30); do test -e "/proc/$sampler_pid" || break; sleep 0.1; done
    sudo kill -TERM "$sampler_pid" 2>/dev/null || true
    wait "$sampler_pid" 2>/dev/null || true
  fi
  if test -n "${holder_pid:-}"; then stop_background "$holder_pid"; fi
  if test -n "${target_pid:-}"; then stop_background "$target_pid"; fi
  if sh .github/scripts/remove-xray-namespace.sh; then :; else
    cleanup_failure=$?
    printf 'memory: namespace cleanup failed with status %s\n' "$cleanup_failure" >&2
    test "$cleanup_status" -ne 0 || cleanup_status=$cleanup_failure
  fi
  if rm -rf "$root"; then :; else
    cleanup_failure=$?
    printf 'memory: workdir cleanup failed with status %s\n' "$cleanup_failure" >&2
    test "$cleanup_status" -ne 0 || cleanup_status=$cleanup_failure
  fi
  exit "$cleanup_status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
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
python3 tests/protocol/duplex_target.py --host 0.0.0.0 --host6 :: \
  --ready-file "$root/target.port" --count-file "$root/count" \
  --report-file "$root/report" >"$root/target.log" 2>&1 &
target_pid=$!
for n in $(seq 1 50); do test -s "$root/target.port" && break; sleep 0.1; done
test -s "$root/target.port"
target_port=$(cat "$root/target.port")
# One process retains the descriptor across every reset and sample.
mkfifo "$root/sample.commands"
exec 3<>"$root/sample.commands"
# The runner owns these channels; only the cgroup descriptor needs root.
# shellcheck disable=SC2024
sudo timeout --kill-after=5 180 sh .github/scripts/memory-sample.sh "$pid" "$cgdir" \
  <"$root/sample.commands" 3>&- >"$root/samples" 2>"$root/sample.errors" &
sampler_pid=$!
sample_request() {
  printf '%s %s\n' "$1" "$2" >&3
  for n in $(seq 1 150); do
    if grep -qx "${2}_${1}=ok" "$root/samples"; then return 0; fi
    test -e "/proc/$sampler_pid" || break
    sleep 0.2
  done
  printf 'memory sampler did not acknowledge %s %s\n' "$1" "$2" >&2
  cat "$root/sample.errors" >&2
  return 1
}
printf 'memory_workload=held_authenticated_tunnels_target_and_driver_outside_xray_cgroup\n'
sample_request reset idle
sample_request sample idle
for stage in 1 32 128; do
  # Reset before establishment so the peak includes opening the tunnels.
  sample_request reset "conn$stage"
  rm -f "$root/held"
  python3 tests/protocol/hold_connections.py --host 127.0.0.1 --port 23456 \
    --target-host 192.0.2.1 --target-port "$target_port" \
    --passfile "$root/pass" --count "$stage" \
    --ready-file "$root/held" --max-seconds 60 3>&- >"$root/held.log" 2>&1 &
  holder_pid=$!
  for n in $(seq 1 150); do test -s "$root/held" && break; sleep 0.2; done
  if ! test "$(cat "$root/held" 2>/dev/null)" = "$stage"; then
    sudo sh .github/scripts/run-socks5.sh --diagnose memory-holder \
      "$root/answers" "$root/held.log" "$root/pass" || true
    exit 1
  fi
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
  sample_request sample "conn$stage"
  kill -TERM "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  holder_pid=''
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
install_secret=$(sed -n '2p' "$root/pass")
lifecycle_no_credential_in "$root/install.log" "$install_secret" sudo
lifecycle_no_credential_in "$root/held.log" "$install_secret"
sudo env GITHUB_ACTIONS=true python3 .github/scripts/memory-compare.py \
  --binary /usr/local/libexec/xray-socks5/xray \
  --config /etc/xray-socks5/config.json \
  --target-port "$target_port" --output "$root/memory-comparison.json"
sudo install -m 0644 "$root/memory-comparison.json" \
  "$GITHUB_WORKSPACE/memory-comparison-$XRAY_ARCH.json"
