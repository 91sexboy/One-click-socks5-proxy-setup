#!/bin/sh
# Put the data-plane test target's addresses on this host.
#
# SPEC 6's local target has to sit outside the SPEC 3 destination boundary, or
# the boundary would have to be relaxed for the gate to pass. TEST-NET-1
# (192.0.2.0/24) and the IPv6 documentation prefix (2001:db8::/32) are in none of
# the denied ranges, so the boundary can hold in full while the data-plane cases
# run against them.
#
# The addresses go on lo rather than on a dummy interface: dummy needs a kernel
# module a container cannot load, and the boundary matches on the address and not
# on the interface, so loopback delivery exercises it exactly the same way.
#
# IPv6 is best-effort. A host without it makes the probe report
# mixed_target_ipv6=unavailable, which is the existing honest outcome; IPv4 and
# the hostname are required.
set -eu

TARGET4=${TARGET4:-192.0.2.1}
TARGET6=${TARGET6:-2001:db8::1}
TARGET_NAME=${TARGET_NAME:-xray-target.test}
# A name resolving into the boundary. The literal case cannot tell IPIfNonMatch
# from the default AsIs; only a request carrying a name can.
DENIED4=${DENIED4:-127.0.0.1}
DENIED_NAME=${DENIED_NAME:-denied-target.test}

ip addr add "$TARGET4/32" dev lo 2>/dev/null || true
if ! ip addr show dev lo | grep -qF "$TARGET4"; then
    printf 'could not add %s to lo\n' "$TARGET4" >&2
    exit 1
fi

# nodad skips duplicate address detection. BusyBox ip does not take it, so the
# plain form is the fallback rather than the failure.
ip addr add "$TARGET6/128" dev lo nodad 2>/dev/null ||
    ip addr add "$TARGET6/128" dev lo 2>/dev/null || true

if ! grep -qF " $TARGET_NAME" /etc/hosts; then
    printf '%s %s\n' "$TARGET4" "$TARGET_NAME" >>/etc/hosts
fi
if ! grep -qF " $DENIED_NAME" /etc/hosts; then
    printf '%s %s\n' "$DENIED4" "$DENIED_NAME" >>/etc/hosts
fi
# The hostname target paths need the resolver to answer, not just the file to
# carry the line, and each must answer with the address its case expects.
python3 - "$TARGET_NAME" "$TARGET4" "$DENIED_NAME" "$DENIED4" <<'PY'
import socket
import sys

for name, expected in ((sys.argv[1], sys.argv[2]), (sys.argv[3], sys.argv[4])):
    try:
        resolved = socket.gethostbyname(name)
    except OSError as exc:
        sys.exit("%s does not resolve: %s" % (name, exc))
    if resolved != expected:
        sys.exit("%s resolves to %s, expected %s" % (name, resolved, expected))
PY

if ip addr show dev lo | grep -qF "$TARGET6"; then
    printf 'test target ready: %s %s %s, denied %s\n' \
        "$TARGET4" "$TARGET6" "$TARGET_NAME" "$DENIED_NAME"
else
    printf 'test target ready: %s (no IPv6) %s, denied %s\n' \
        "$TARGET4" "$TARGET_NAME" "$DENIED_NAME"
fi
