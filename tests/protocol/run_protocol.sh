#!/bin/sh
# tests/protocol/run_protocol.sh - the seven protocol-acceptance cases.
#
# CI ONLY. This starts a real 3proxy and binds a real port, so it must never be
# run on a development machine.
#
# Usage:
#   PORT=41080 PROXY_USER=u PASSFILE=/path/to/pass PROXY_HOST=127.0.0.1 \
#       sh tests/protocol/run_protocol.sh
#
# The password is read from PASSFILE (a 0600 file), never from an environment
# variable and never from argv, so it cannot reach a CI log, `ps`, or a child
# process's environment.
#
# PROXY_USER is used rather than USER because USER is already set in almost
# every environment, so a missing override would be silently accepted and the
# wrong account tested.
#
# Exit codes:
#   0  all seven cases behaved correctly
#   1  a case failed
#   3  RELEASE GATE: SOCKS4 or SOCKS4a established a proxy connection
#
# There is no skip flag and no environment override for the release gate.

set -u

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PROBE="$HERE/socks_probe.py"
PROXY_HOST=${PROXY_HOST:-127.0.0.1}
PORT=${PORT:?PORT must be set}
PROXY_USER=${PROXY_USER:?PROXY_USER must be set}
PASSFILE=${PASSFILE:?PASSFILE must point at a 0600 file holding the password}
TARGET=${TARGET:-example.com}
TARGET_PORT=${TARGET_PORT:-80}

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
    printf 'PASSFILE is empty: %s\n' "$PASSFILE" >&2
    exit 2
fi

pass=0
fail=0
inconclusive=0
gate_violation=0

# curl's CURLE_PROXY. Only this status proves the PROXY refused the handshake;
# any other non-zero status means the attempt failed for an unrelated reason.
S5_CURL_PROXY_ERR=97

ok() {
    pass=$((pass + 1))
    printf 'ok   %s\n' "$1"
}

bad() {
    fail=$((fail + 1))
    printf 'FAIL %s\n' "$1"
}

# A third outcome, for a curl attempt that failed for a reason not attributable
# to the proxy. It is NOT scored as a pass: a proxy that was down, a DNS failure
# or a curl built without SOCKS4/SOCKS5 support all land here, and none of them
# is evidence that anything was refused. Printing "ok" for them made the summary
# claim more than the run had proved. It does not fail the run either, because
# the matching probe case is authoritative and treats its own inconclusive
# result as a failure -- so a genuinely broken environment still fails, there.
note() {
    inconclusive=$((inconclusive + 1))
    printf 'note %s\n' "$1"
}

# A password that must never be the configured one. Compared against the real
# credential below rather than assumed to differ: if they ever collided, case 2
# would be testing the CORRECT password and would score the proxy accepting it
# as a rejection failure -- or worse, quietly invert into a pass.
S5_WRONG_PASS='wrongpassword_zzzz'
if [ "$S5_WRONG_PASS" = "$_ppass" ]; then
    printf 'the configured password equals the deliberately-wrong one; case 2 cannot test anything\n' >&2
    exit 2
fi

# probe <mode> [--with-creds|wrong-creds]
probe() {
    _mode=$1
    _creds=${2:-no}
    if [ "$_creds" = "with-creds" ]; then
        printf '%s\n%s\n' "$PROXY_USER" "$_ppass" |
            python3 "$PROBE" --host "$PROXY_HOST" --port "$PORT" --mode "$_mode" \
                --target-host "$TARGET" --target-port "$TARGET_PORT"
    elif [ "$_creds" = "wrong-creds" ]; then
        printf '%s\n%s\n' "$PROXY_USER" "$S5_WRONG_PASS" |
            python3 "$PROBE" --host "$PROXY_HOST" --port "$PORT" --mode "$_mode" \
                --target-host "$TARGET" --target-port "$TARGET_PORT"
    else
        python3 "$PROBE" --host "$PROXY_HOST" --port "$PORT" --mode "$_mode" \
            --target-host "$TARGET" --target-port "$TARGET_PORT" </dev/null
    fi
}

# curl_socks5 <user> <password> : credentials on stdin only, never in argv.
# The URL rides TARGET/TARGET_PORT so curl and the raw probes below test the
# SAME destination; a hard-coded one let the two halves disagree for unrelated
# DNS, TLS or egress reasons while each looked individually fine.
curl_socks5() {
    printf 'socks5-hostname = "%s:%s"\nproxy-user = "%s:%s"\nurl = "http://%s:%s/"\noutput = "/dev/null"\nmax-time = 20\nsilent\nshow-error\n' \
        "$PROXY_HOST" "$PORT" "$1" "$2" "$TARGET" "$TARGET_PORT" | curl --config -
}

printf '== SOCKS5 protocol acceptance, proxy %s:%s ==\n' "$PROXY_HOST" "$PORT"

# ---------------------------------------------------------------- case 1
# SOCKS5 + correct credentials + CONNECT must SUCCEED.
if curl_socks5 "$PROXY_USER" "$_ppass"; then
    ok "1a curl: SOCKS5 + correct credentials + CONNECT succeeded"
else
    bad "1a curl: SOCKS5 + correct credentials + CONNECT should have succeeded"
fi
probe socks5-connect with-creds
case $? in
0) ok "1b probe: SOCKS5 + correct credentials + CONNECT granted" ;;
1) bad "1b probe: SOCKS5 CONNECT was refused with valid credentials" ;;
*) bad "1b probe: inconclusive transport error" ;;
esac

# ---------------------------------------------------------------- case 2
# SOCKS5 + wrong password must FAIL.
#
# curl alone cannot answer this. Its `else` branch used to score a pass for ANY
# non-zero exit, so a proxy that was down, a DNS failure, or a curl built
# without SOCKS5 support all read as "the wrong password was refused" -- the one
# case that proves authentication is enforced was the easiest in the file to
# pass accidentally. curl is now classified the same way as cases 4a/5a (only
# CURLE_PROXY is attributable to the proxy) and probe 2b is authoritative.
curl_socks5 "$PROXY_USER" "$S5_WRONG_PASS" >/dev/null 2>&1
rc2=$?
if [ "$rc2" -eq 0 ]; then
    bad "2a curl: SOCKS5 accepted a wrong password"
elif [ "$rc2" -eq "$S5_CURL_PROXY_ERR" ]; then
    ok "2a curl: SOCKS5 + wrong password refused by the proxy (curl $S5_CURL_PROXY_ERR)"
else
    note "2a curl: SOCKS5 + wrong password did not succeed (curl $rc2, indicative only; 2b is authoritative)"
fi
probe socks5-badauth wrong-creds
case $? in
1) ok "2b probe: wrong credentials caused the proxy to reject CONNECT" ;;
0) bad "2b probe: SOCKS5 ACCEPTED a wrong password and granted CONNECT" ;;
*) bad "2b probe: inconclusive transport error" ;;
esac

# ---------------------------------------------------------------- case 3
# SOCKS5 offering no authentication method must FAIL.
probe socks5-noauth
case $? in
1) ok "3 probe: SOCKS5 with no authentication method refused" ;;
0) bad "3 probe: SOCKS5 granted an unauthenticated CONNECT" ;;
*) bad "3 probe: inconclusive transport error" ;;
esac

# ---------------------------------------------------------------- case 4
# SOCKS4 CONNECT must be REJECTED. This is a rejection test, never a feature.
# The probe sends the CONFIGURED user id: the gate exists to catch an engine
# regression that allows SOCKS4 for the ACL user, and a stranger's user id
# would reject that regression as unknown-user and misreport it as safe.
curl --socks4 "$PROXY_HOST:$PORT" -sS -o /dev/null --max-time 20 \
    "http://$TARGET:$TARGET_PORT/" >/dev/null 2>&1
rc4=$?
if [ "$rc4" -eq 0 ]; then
    bad "4a curl: SOCKS4 CONNECT succeeded"
    gate_violation=1
elif [ "$rc4" -eq "$S5_CURL_PROXY_ERR" ]; then
    ok "4a curl: SOCKS4 CONNECT refused by the proxy (curl $S5_CURL_PROXY_ERR)"
else
    # Not a pass on its own: curl may lack SOCKS4 support, or the network may
    # have failed. The load-bearing evidence is probe 4b, which treats an
    # inconclusive result as a failure.
    note "4a curl: SOCKS4 CONNECT did not succeed (curl $rc4, indicative only; 4b is authoritative)"
fi
probe socks4-connect with-creds
case $? in
1) ok "4b probe: SOCKS4 CONNECT rejected" ;;
0)
    bad "4b probe: SOCKS4 CONNECT was GRANTED"
    gate_violation=1
    ;;
*) bad "4b probe: inconclusive transport error" ;;
esac

# ---------------------------------------------------------------- case 5
# SOCKS4a CONNECT must be REJECTED.
curl --socks4a "$PROXY_HOST:$PORT" -sS -o /dev/null --max-time 20 \
    "http://$TARGET:$TARGET_PORT/" >/dev/null 2>&1
rc5=$?
if [ "$rc5" -eq 0 ]; then
    bad "5a curl: SOCKS4a CONNECT succeeded"
    gate_violation=1
elif [ "$rc5" -eq "$S5_CURL_PROXY_ERR" ]; then
    ok "5a curl: SOCKS4a CONNECT refused by the proxy (curl $S5_CURL_PROXY_ERR)"
else
    note "5a curl: SOCKS4a CONNECT did not succeed (curl $rc5, indicative only; 5b is authoritative)"
fi
probe socks4a-connect with-creds
case $? in
1) ok "5b probe: SOCKS4a CONNECT rejected" ;;
0)
    bad "5b probe: SOCKS4a CONNECT was GRANTED"
    gate_violation=1
    ;;
*) bad "5b probe: inconclusive transport error" ;;
esac

# ---------------------------------------------------------------- case 6
# SOCKS5 BIND must be REJECTED even with valid credentials.
probe socks5-bind with-creds
case $? in
1) ok "6 probe: SOCKS5 BIND rejected" ;;
0) bad "6 probe: SOCKS5 BIND was granted" ;;
*) bad "6 probe: inconclusive transport error" ;;
esac

# ---------------------------------------------------------------- case 7
# SOCKS5 UDP ASSOCIATE must be REJECTED even with valid credentials.
probe socks5-udpassoc with-creds
case $? in
1) ok "7 probe: SOCKS5 UDP ASSOCIATE rejected" ;;
0) bad "7 probe: SOCKS5 UDP ASSOCIATE was granted" ;;
*) bad "7 probe: inconclusive transport error" ;;
esac

printf -- '----\n%d passed, %d failed, %d inconclusive (not counted as passes)\n' \
    "$pass" "$fail" "$inconclusive"

if [ "$gate_violation" -ne 0 ]; then
    printf '\n'
    printf '########################################################\n'
    printf '# RELEASE GATE FAILURE                                 #\n'
    printf '# A SOCKS4-family request established a proxy           #\n'
    printf '# connection. Release MUST NOT proceed.                 #\n'
    printf '#                                                       #\n'
    printf '# Do not relax this test. Either re-evaluate the engine  #\n'
    printf '# or carry a minimal protocol-restriction patch.         #\n'
    printf '########################################################\n'
    exit 3
fi

if [ "$fail" -ne 0 ]; then
    exit 1
fi
exit 0
