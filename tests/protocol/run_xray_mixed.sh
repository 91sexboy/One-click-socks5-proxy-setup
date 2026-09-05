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
# SPEC 6's local target sits outside the SPEC 3 destination boundary, so the
# boundary holds in full while the data-plane cases run. The denied host is where
# the same target also listens, which is what makes a bypass visible.
TARGET_HOST=${TARGET_HOST:-192.0.2.1}
TARGET_HOSTNAME=${TARGET_HOSTNAME:-xray-target.test}
TARGET_IPV6=${TARGET_IPV6:-2001:db8::1}
DENIED_HOST=${DENIED_HOST:-127.0.0.1}
DENIED_HOSTNAME=${DENIED_HOSTNAME:-denied-target.test}

[ -f "$PASSFILE" ] || exit 2
[ ! -L "$PASSFILE" ] || exit 2
[ "$(stat -c '%a' "$PASSFILE" 2>/dev/null)" = 600 ] || exit 2
mkdir -p "$OUT" || exit 2

if ! python3 "$PROBE" --host 127.0.0.1 --port "$PORT" \
    --target-host "$TARGET_HOST" --target-port "$TARGET_PORT" \
    --target-hostname "$TARGET_HOSTNAME" --target-ipv6 "$TARGET_IPV6" \
    --denied-host "$DENIED_HOST" --denied-hostname "$DENIED_HOSTNAME" \
    --passfile "$PASSFILE" --stats-file "$OUT/stats" >"$OUT/probe.log" 2>&1; then
    cat "$OUT/probe.log" >&2
    exit 1
fi
cat "$OUT/probe.log"

grep -q '^mixed_target_ipv4=ok$' "$OUT/probe.log" || exit 1
grep -q '^mixed_target_hostname=ok$' "$OUT/probe.log" || exit 1
grep -qE '^mixed_target_ipv6=(ok|unavailable)$' "$OUT/probe.log" || exit 1
grep -q '^mixed_denied_destination=ok$' "$OUT/probe.log" || exit 1
grep -q '^mixed_denied_hostname=ok$' "$OUT/probe.log" || exit 1

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
