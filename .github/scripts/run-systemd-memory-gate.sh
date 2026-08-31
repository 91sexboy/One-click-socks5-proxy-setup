#!/bin/sh
set -eu

SLICE=system-s5target.slice
SLICE_UNIT=/run/systemd/system/$SLICE
DROPIN_DIR=/run/systemd/system/socks5-manager.service.d
DROPIN=$DROPIN_DIR/50-ci-memory-gate.conf
LIMIT=134217728

setup_gate() {
    mkdir -p "$DROPIN_DIR"
    cat >"$SLICE_UNIT" <<EOF
[Unit]
Description=SOCKS5 target lifecycle memory gate

[Slice]
MemoryAccounting=yes
MemoryMax=$LIMIT
MemorySwapMax=0
EOF
    cat >"$DROPIN" <<EOF
[Service]
Slice=$SLICE
EOF
    chmod 0644 "$SLICE_UNIT" "$DROPIN"
    systemctl daemon-reload
    systemctl start "$SLICE"
    [ "$(systemctl show "$SLICE" -p MemoryMax --value)" = "$LIMIT" ]
    [ "$(systemctl show "$SLICE" -p MemorySwapMax --value)" = 0 ]
}

cleanup_gate() {
    for unit in s5-install s5-update s5-status s5-restart s5-uninstall; do
        : >"/tmp/$unit-release" 2>/dev/null || true
        systemctl stop "$unit.service" >/dev/null 2>&1 || true
        systemctl reset-failed "$unit.service" >/dev/null 2>&1 || true
        rm -f "/tmp/$unit-runner" "/tmp/$unit-status" "/tmp/$unit-done" \
            "/tmp/$unit-release"
    done
    systemctl stop socks5-manager.service >/dev/null 2>&1 || true
    systemctl stop "$SLICE" >/dev/null 2>&1 || true
    systemctl reset-failed "$SLICE" >/dev/null 2>&1 || true
    rm -f "$DROPIN" "$SLICE_UNIT"
    rmdir "$DROPIN_DIR" >/dev/null 2>&1 || true
    systemctl daemon-reload
}

case "${1:-}" in
setup)
    [ "$#" -eq 1 ] || exit 2
    setup_gate
    exit 0
    ;;
cleanup)
    [ "$#" -eq 1 ] || exit 2
    cleanup_gate
    exit 0
    ;;
esac

UNIT=${1:?usage: run-systemd-memory-gate.sh setup|cleanup|UNIT INPUT OUTPUT COMMAND...}
INPUT=${2:?input path required}
OUTPUT=${3:?output path required}
shift 3
[ "$#" -gt 0 ] || { printf 'command required\n' >&2; exit 2; }
case "$UNIT" in s5-[a-z0-9-]*) ;; *) printf 'unsafe unit name: %s\n' "$UNIT" >&2; exit 2;; esac
case "$INPUT:$OUTPUT" in /tmp/*:/tmp/*) ;; *) printf 'input/output must be under /tmp\n' >&2; exit 2;; esac

RUNNER="/tmp/$UNIT-runner"
STATUS_FILE="/tmp/$UNIT-status"
DONE_FILE="/tmp/$UNIT-done"
RELEASE_FILE="/tmp/$UNIT-release"
rm -f "$STATUS_FILE" "$DONE_FILE" "$RELEASE_FILE"
cat >"$RUNNER" <<EOF
#!/bin/sh
set +e
umask 077
"\$@" <"$INPUT" >"$OUTPUT" 2>&1
rc=\$?
printf '%s\n' "\$rc" >"$STATUS_FILE"
: >"$DONE_FILE"
while [ ! -e "$RELEASE_FILE" ]; do sleep 1; done
exit "\$rc"
EOF
chmod 0700 "$RUNNER"
cleanup() {
    : >"$RELEASE_FILE"
    systemctl stop "$UNIT.service" >/dev/null 2>&1 || true
    systemctl reset-failed "$UNIT.service" >/dev/null 2>&1 || true
    rm -f "$RUNNER" "$STATUS_FILE" "$DONE_FILE" "$RELEASE_FILE"
}
trap cleanup EXIT HUP INT TERM

slice_cgroup=$(systemctl show system-s5target.slice -p ControlGroup --value)
case "$slice_cgroup" in /*/?*) ;; *) printf '%s has invalid cgroup: %s\n' "$SLICE" "$slice_cgroup" >&2; exit 1;; esac

case "$UNIT" in
s5-uninstall)
    manager_slice=$(systemctl show socks5-manager.service -p Slice --value)
    manager_cgroup=$(systemctl show socks5-manager.service -p ControlGroup --value)
    [ "$manager_slice" = "$SLICE" ] || { printf 'manager uses wrong slice: %s\n' "$manager_slice" >&2; exit 1; }
    case "$manager_cgroup" in "$slice_cgroup"/*) ;; *) printf 'manager cgroup is outside slice: %s\n' "$manager_cgroup" >&2; exit 1;; esac
    ;;
esac

systemd-run --quiet --unit="$UNIT" --slice=system-s5target.slice "$RUNNER" "$@"

i=0
while [ "$i" -lt 120 ]; do
    [ -e "$DONE_FILE" ] && break
    state=$(systemctl show "$UNIT.service" -p ActiveState --value)
    case "$state" in failed | inactive) break;; esac
    i=$((i + 1))
    sleep 1
done
[ -e "$DONE_FILE" ] || { printf '%s did not finish\n' "$UNIT" >&2; exit 1; }
status=$(cat "$STATUS_FILE")
runner_cgroup=$(systemctl show "$UNIT.service" -p ControlGroup --value)
case "$runner_cgroup" in "$slice_cgroup"/*) ;; *) printf 'runner cgroup is outside slice: %s\n' "$runner_cgroup" >&2; exit 1;; esac

case "$UNIT" in
s5-install | s5-update | s5-status | s5-restart)
    manager_slice=$(systemctl show socks5-manager.service -p Slice --value)
    manager_cgroup=$(systemctl show socks5-manager.service -p ControlGroup --value)
    [ "$manager_slice" = "$SLICE" ] || { printf 'manager uses wrong slice: %s\n' "$manager_slice" >&2; exit 1; }
    case "$manager_cgroup" in "$slice_cgroup"/*) ;; *) printf 'manager cgroup is outside slice: %s\n' "$manager_cgroup" >&2; exit 1;; esac
    ;;
esac

cgroup_dir="/sys/fs/cgroup${slice_cgroup}"
for file in memory.peak memory.max memory.swap.max memory.events; do
    [ -r "$cgroup_dir/$file" ] || { printf 'shared slice file is unreadable: %s\n' "$cgroup_dir/$file" >&2; exit 1; }
done
peak=$(cat "$cgroup_dir/memory.peak")
max=$(cat "$cgroup_dir/memory.max")
swap_max=$(cat "$cgroup_dir/memory.swap.max")
oom_kill=$(awk '$1 == "oom_kill" { print $2 }' "$cgroup_dir/memory.events")
case "$status:$peak:$oom_kill" in
    0:[0-9]*:0) ;;
    *) printf '%s failed: status=%s peak=%s oom_kill=%s\n' "$UNIT" "$status" "$peak" "${oom_kill:-missing}" >&2; exit 1;;
esac
[ "$max" = "$LIMIT" ] || { printf 'shared slice memory.max mismatch: %s\n' "$max" >&2; exit 1; }
[ "$swap_max" = 0 ] || { printf 'shared slice memory.swap.max mismatch: %s\n' "$swap_max" >&2; exit 1; }
[ "$peak" -le "$LIMIT" ] || { printf '%s exceeded 128 MiB: %s\n' "$SLICE" "$peak" >&2; exit 1; }
printf '%s\n' "$peak"
