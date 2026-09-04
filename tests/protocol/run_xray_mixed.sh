#!/bin/sh
# Shared entry point for the Xray mixed protocol gate.
#
# Runs the probe, checks that the three SPEC 6 target paths were each recorded,
# then reconciles the target's frame counters against the probe's own. A
# handshake that succeeds while frames are lost would otherwise look like a pass.
set -u

PASSFILE=${PASSFILE:?PASSFILE must be set}
PORT=${PORT:?PORT must be set}
TARGET_PORT=${TARGET_PORT:?TARGET_PORT must be set}
REPORT=${REPORT:?REPORT must be set}
OUT=${OUT:?OUT must be set}
PROBE=${PROBE:-$(dirname "$0")/xray_mixed.py}

[ -f "$PASSFILE" ] || exit 2
[ ! -L "$PASSFILE" ] || exit 2
[ "$(stat -c '%a' "$PASSFILE" 2>/dev/null)" = 600 ] || exit 2
mkdir -p "$OUT" || exit 2

if ! python3 "$PROBE" --host 127.0.0.1 --port "$PORT" \
    --target-host 127.0.0.1 --target-port "$TARGET_PORT" \
    --passfile "$PASSFILE" --stats-file "$OUT/stats" >"$OUT/probe.log" 2>&1; then
    cat "$OUT/probe.log" >&2
    exit 1
fi
cat "$OUT/probe.log"

grep -q '^mixed_target_ipv4=ok$' "$OUT/probe.log" || exit 1
grep -q '^mixed_target_hostname=ok$' "$OUT/probe.log" || exit 1
grep -qE '^mixed_target_ipv6=(ok|unavailable)$' "$OUT/probe.log" || exit 1

# The target flushes its counters as each tunnel closes, so the two sides
# converge shortly after the probe exits rather than only at shutdown.
python3 - "$REPORT" "$OUT/stats" <<'PY'
import json
import sys
import time


def load(path):
    with open(path, encoding="ascii") as handle:
        return json.load(handle)


deadline = time.monotonic() + 15
while True:
    report = load(sys.argv[1])
    stats = load(sys.argv[2])
    if (report["accepted"] == stats["tunnels"]
            and report["frames"] == stats["client_frames"]):
        break
    if time.monotonic() >= deadline:
        sys.exit(
            "duplex counters never reconciled: target accepted=%d frames=%d, "
            "probe tunnels=%d frames=%d"
            % (report["accepted"], report["frames"],
               stats["tunnels"], stats["client_frames"])
        )
    time.sleep(0.2)
print("target_families=%s" % ",".join(report["families"]))
print("duplex_tunnels=%d" % report["accepted"])
print("duplex_frames=%d" % report["frames"])
PY
