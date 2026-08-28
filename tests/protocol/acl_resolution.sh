#!/bin/sh
# tests/protocol/acl_resolution.sh - H1 verification.
#
# Proves that the CIDR destination denies apply to DOMAIN targets, not just to
# literal IPs. This is the property that stops an authenticated client from
# reaching cloud metadata or the private network by hostname.
#
# Source evidence at the pinned commit da99424e:
#   src/socks.c:134   getip46() resolves an ATYP=3 domain into param->req
#   src/socks.c:196   authfunc() (which runs checkACL) is called AFTER that
#   src/acl.c:53-55   acentry->dst (our CIDR list) is matched against param->req
#   src/socks.c:186   the outbound connect reuses that same param->req
# so the ACL sees the resolved address and the connection cannot use a
# different one. This script verifies that behaviour at runtime.
#
# ISOLATION IS MANDATORY. It binds 169.254.169.254, 10.0.0.1 and 192.168.0.1 to
# a local interface and serves a dummy listener on each. It therefore requires an
# isolated network namespace or container and refuses to run otherwise. It NEVER
# contacts a real cloud metadata endpoint or a real private host.
#
# Exit codes:
#   0  all destination denies held
#   1  a deny was bypassed  -> RELEASE BLOCKER
#   2  the environment is not isolated, or setup failed (inconclusive)

set -u

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PROBE="$HERE/socks_probe.py"
PORT=${PORT:?PORT must be set}
PROXY_USER=${PROXY_USER:?PROXY_USER must be set}
PASSFILE=${PASSFILE:?PASSFILE must point at a 0600 file holding the password}

if [ ! -f "$PASSFILE" ] || [ -L "$PASSFILE" ]; then
    printf 'PASSFILE must be a regular non-symlink file: %s\n' "$PASSFILE" >&2
    exit 2
fi
_pfmode=$(stat -c '%a' "$PASSFILE" 2>/dev/null || printf '')
if [ "$_pfmode" != 600 ]; then
    printf 'PASSFILE must have mode 0600, found %s: %s\n' "${_pfmode:-unknown}" "$PASSFILE" >&2
    exit 2
fi
# Held in a shell variable only; never exported, never passed as an argument.
_ppass=$(cat "$PASSFILE")
if [ -z "$_ppass" ]; then
    # Same guard as run_protocol.sh, and for the same reason: an empty password
    # is rejected by the proxy for a reason that has nothing to do with the
    # destination ACL, so all six checks below would "pass" and this script
    # would report that the denies held without ever reaching one. A setup
    # mistake must read as inconclusive (2), never as a verified deny.
    printf 'PASSFILE is empty: %s\n' "$PASSFILE" >&2
    exit 2
fi

# ---------------------------------------------------------------- isolation
if [ "${S5_ISOLATED:-0}" != "1" ]; then
    printf 'REFUSING TO RUN: set S5_ISOLATED=1 only inside a container or a\n' >&2
    printf 'dedicated network namespace. This test binds 169.254.169.254.\n' >&2
    exit 2
fi
if [ ! -f /.dockerenv ] && [ ! -r /run/.containerenv ] &&
    [ "$(readlink /proc/1/ns/net 2>/dev/null)" = "$(readlink /proc/self/ns/net 2>/dev/null)" ] &&
    [ "$(cat /proc/1/comm 2>/dev/null)" != "sh" ]; then
    printf 'REFUSING TO RUN: this does not look like an isolated environment.\n' >&2
    exit 2
fi

pass=0
fail=0
ok() {
    pass=$((pass + 1))
    printf 'ok   %s\n' "$1"
}
bad() {
    fail=$((fail + 1))
    printf 'FAIL %s\n' "$1"
}

WORK=$(mktemp -d)

# Every denied destination gets a real listener behind it. Without one the proxy
# answers 0x04/0x05 (host unreachable / connection refused) and a probe that
# accepts any non-zero reply code cannot tell that apart from the ACL firing --
# so the 10.0.0.1 and 192.168.0.1 checks passed whether or not the deny rules
# existed. The probe is therefore run with --refusal policy below, which is only
# meaningful because these listeners make an unreachable reply anomalous.
# 127.0.0.1 is already on lo and must not be added or deleted.
ADD_ADDRS='169.254.169.254 10.0.0.1 192.168.0.1'
LISTEN_ADDRS="127.0.0.1 $ADD_ADDRS"
added=''
pids=''

cleanup() {
    for _p in $pids; do kill "$_p" 2>/dev/null || true; done
    for _a in $added; do ip addr del "$_a/32" dev lo 2>/dev/null || true; done
    rm -rf "$WORK"
}
trap cleanup EXIT HUP INT TERM

# ------------------------------------------- fake private / metadata endpoints
for a in $ADD_ADDRS; do
    if ! ip addr add "$a/32" dev lo 2>/dev/null; then
        printf 'could not bind %s to lo (need CAP_NET_ADMIN)\n' "$a" >&2
        exit 2
    fi
    added="$added $a"
done

cat >"$WORK/listener.py" <<'PYEOF'
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((sys.argv[1], int(sys.argv[2])))
s.listen(5)
while True:
    c, _ = s.accept()
    c.sendall(b"HTTP/1.0 200 OK\r\n\r\nDUMMY-REACHED\r\n")
    c.close()
PYEOF

for a in $LISTEN_ADDRS; do
    python3 "$WORK/listener.py" "$a" 80 </dev/null &
    pids="$pids $!"
done

# Wait for the listeners to actually answer instead of guessing a delay: the
# first two CI runs failed the 127.0.0.1 sanity check in all three cells because
# a flat `sleep 1` is not reliably enough for four Python interpreters to start
# and bind in a cold container. Bounded per-listener poll, whole-second sleeps
# only (this file runs under plain sh, where fractional sleeps are not
# portable); 30 tries is far beyond any healthy interpreter startup.
# curl's stderr is captured to a file under $WORK -- never argv, never the job
# log -- and printed only when a check fails, so a future failure explains
# itself. These curls carry no credentials, but the file-first habit is kept.
CURL_ERR="$WORK/curl.err"
print_curl_err() {
    if [ -s "$CURL_ERR" ]; then
        printf 'curl reported: %s\n' "$(cat "$CURL_ERR")" >&2
    fi
}
wait_ready() {
    _addr=$1
    _tries=0
    while [ "$_tries" -lt 30 ]; do
        if curl --noproxy '*' -sS --max-time 5 -o /dev/null "http://$_addr/" 2>"$CURL_ERR"; then
            return 0
        fi
        _tries=$((_tries + 1))
        sleep 1
    done
    return 1
}
for a in $LISTEN_ADDRS; do
    if ! wait_ready "$a"; then
        # Same inconclusive path as the sanity checks below: a listener that
        # never came up makes its checks vacuous, and vacuous must read as 2.
        printf 'listener %s is not reachable directly; its checks would be vacuous\n' "$a" >&2
        print_curl_err
        exit 2
    fi
done

# hostnames that resolve into the denied ranges
if ! grep -q 'metadata-probe.invalid' /etc/hosts 2>/dev/null; then
    printf '169.254.169.254 metadata-probe.invalid\n127.0.0.1 loopback-probe.invalid\n' >>/etc/hosts
fi

# Sanity: EVERY target must be reachable directly, or a "refused" result through
# the proxy proves nothing about the ACL. The earlier gate covered only
# metadata-probe.invalid, so a listener that failed to bind -- or a port 80
# already in use -- left the other five checks vacuous while the suite stayed
# green. Inconclusive setup exits 2; it is never reported as a verified deny.
#
# --noproxy '*': an ambient http_proxy would satisfy these checks through some
# OTHER proxy, converting an invalid environment into "directly reachable"
# without the dummy listener ever being contacted.
for a in $LISTEN_ADDRS; do
    if curl --noproxy '*' -sS --max-time 5 -o /dev/null "http://$a/" 2>"$CURL_ERR"; then
        ok "sanity: the dummy listener on $a is reachable directly"
    else
        printf 'listener %s is not reachable directly; its checks would be vacuous\n' "$a" >&2
        print_curl_err
        exit 2
    fi
done
for h in metadata-probe.invalid loopback-probe.invalid; do
    if curl --noproxy '*' -sS --max-time 5 -o /dev/null "http://$h/" 2>"$CURL_ERR"; then
        ok "sanity: $h resolves and is reachable directly"
    else
        printf '%s is not reachable directly; its check would be vacuous\n' "$h" >&2
        print_curl_err
        exit 2
    fi
done

check_refused() {
    _desc=$1
    _host=$2
    # --refusal policy: only a reply code the PROXY is responsible for counts.
    # With a live listener behind every target, an unreachable-destination code
    # is an anomaly to investigate, not proof the ruleset held.
    printf '%s\n%s\n' "$PROXY_USER" "$_ppass" |
        python3 "$PROBE" --host 127.0.0.1 --port "$PORT" --mode socks5-connect \
            --target-host "$_host" --target-port 80 --refusal policy
    case $? in
    1) ok "$_desc refused by the proxy's own ruleset" ;;
    0) bad "$_desc was GRANTED - the destination deny was bypassed" ;;
    *) bad "$_desc inconclusive (probe error)" ;;
    esac
}

# by hostname (the case a CIDR-only ACL could miss)
check_refused "CONNECT to metadata-probe.invalid (resolves to 169.254.169.254)" metadata-probe.invalid
check_refused "CONNECT to loopback-probe.invalid (resolves to 127.0.0.1)" loopback-probe.invalid
# by literal IP
check_refused "CONNECT to 169.254.169.254 by literal IP" 169.254.169.254
check_refused "CONNECT to 127.0.0.1 by literal IP" 127.0.0.1
check_refused "CONNECT to 10.0.0.1 by literal IP" 10.0.0.1
check_refused "CONNECT to 192.168.0.1 by literal IP" 192.168.0.1

printf -- '----\n%d passed, %d failed\n' "$pass" "$fail"

if [ "$fail" -ne 0 ]; then
    printf '\n'
    printf '########################################################\n'
    printf '# RELEASE BLOCKER                                      #\n'
    printf '# A destination deny rule was bypassed. An authenticated #\n'
    printf '# client can reach the private network or the cloud      #\n'
    printf '# metadata endpoint. Release MUST NOT proceed.           #\n'
    printf '#                                                       #\n'
    printf '# Re-evaluate the ACL or the engine. Do not downgrade    #\n'
    printf '# this to a warning.                                     #\n'
    printf '########################################################\n'
    exit 1
fi
exit 0
