#!/bin/sh
set -eu

UNIT=${1:?usage: run-systemd-memory-gate.sh UNIT INPUT OUTPUT COMMAND...}
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

systemd-run --quiet --unit="$UNIT" \
    --property=MemoryMax=134217728 \
    --property=MemorySwapMax=0 \
    "$RUNNER" "$@"

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
cgroup=$(systemctl show "$UNIT.service" -p ControlGroup --value)
case "$cgroup" in /*) ;; *) printf '%s has invalid cgroup: %s\n' "$UNIT" "$cgroup" >&2; exit 1;; esac
peak_file="/sys/fs/cgroup${cgroup}/memory.peak"
[ -r "$peak_file" ] || { printf '%s memory peak file is unreadable: %s\n' "$UNIT" "$peak_file" >&2; exit 1; }
peak=$(cat "$peak_file")
case "$status:$peak" in
    0:[0-9]*) ;;
    *) printf '%s failed: status=%s peak=%s\n' "$UNIT" "$status" "$peak" >&2; exit 1;;
esac
[ "$peak" -le 134217728 ] || { printf '%s exceeded 128 MiB: %s\n' "$UNIT" "$peak" >&2; exit 1; }
printf '%s\n' "$peak"
