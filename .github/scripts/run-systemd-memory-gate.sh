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
cat >"$RUNNER" <<EOF
#!/bin/sh
set -eu
umask 077
exec "\$@" <"$INPUT" >"$OUTPUT" 2>&1
EOF
chmod 0700 "$RUNNER"
cleanup() {
    systemctl stop "$UNIT.service" >/dev/null 2>&1 || true
    systemctl reset-failed "$UNIT.service" >/dev/null 2>&1 || true
    rm -f "$RUNNER"
}
trap cleanup EXIT HUP INT TERM

systemd-run --quiet --unit="$UNIT" \
    --property=Type=oneshot \
    --property=RemainAfterExit=yes \
    --property=MemoryMax=134217728 \
    --property=MemorySwapMax=0 \
    "$RUNNER" "$@"

i=0
while [ "$i" -lt 120 ]; do
    state=$(systemctl show "$UNIT.service" -p ActiveState --value)
    case "$state" in active | failed) break;; esac
    i=$((i + 1))
    sleep 1
done
[ "$i" -lt 120 ] || { printf '%s did not finish\n' "$UNIT" >&2; exit 1; }
status=$(systemctl show "$UNIT.service" -p ExecMainStatus --value)
peak=$(systemctl show "$UNIT.service" -p MemoryPeak --value)
case "$status:$peak" in
    0:[0-9]*) ;;
    *) printf '%s failed: status=%s peak=%s\n' "$UNIT" "$status" "$peak" >&2; exit 1;;
esac
[ "$peak" -le 134217728 ] || { printf '%s exceeded 128 MiB: %s\n' "$UNIT" "$peak" >&2; exit 1; }
printf '%s\n' "$peak"
