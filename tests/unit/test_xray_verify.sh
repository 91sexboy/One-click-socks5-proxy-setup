#!/bin/sh
# Data-plane verifier diagnostics (SPEC 6). Regression test for the defect where
# s5_verify_dataplane collapsed every failure reason into type(exc).__name__, so an
# auth failure and a boundary bypass reached the operator as the same word.
#
# The verifier's Python is embedded in socks5.sh and only runs outside test mode,
# where the unit harness stubs the whole function. To exercise the real diagnostic
# this test extracts that exact Python from the script (tracking the production
# text, so drift is caught) and drives it against two mock inbounds that fail in two
# different ways. The two diagnostics must differ and each must name its own reason.

S5T_NAME=test_xray_verify
# shellcheck disable=SC1091
. "${S5_REPO_ROOT}/tests/lib/assert.sh"

SRC=${S5_SRC:-${S5_REPO_ROOT}/socks5.sh}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/s5verify.XXXXXX") || { printf 'cannot create workdir\n' >&2; exit 1; }
# shellcheck disable=SC2064
trap "rm -rf \"$WORK\"" EXIT HUP INT TERM

printf 'alice\nSecret_123~x\n' >"$WORK/pass"
chmod 0600 "$WORK/pass"

# Pull the verifier heredoc body out of socks5.sh: the start line carries both "<<"
# and "PY", the terminator is a line that is exactly "PY". Matching on content
# rather than a quoted regex keeps this readable across sh, dash and busybox.
VERIFY_PY="$WORK/verify.py"
awk 'index($0,"<<") && index($0,"PY"){f=1;next} $0=="PY"{f=0} f' "$SRC" >"$VERIFY_PY"
assert_contains "the verifier python was extracted" \
    "data-plane verification failed" "$(cat "$VERIFY_PY")"

# A mock inbound on loopback. "close" accepts and closes without a reply, so the
# verifier's first exact() read returns empty -> RuntimeError("closed"). "authmethod"
# answers with an unacceptable method -> RuntimeError("auth method"). Two distinct
# RuntimeError reasons that the old diagnostic rendered identically.
run_case() {
    _behavior=$1
    python3 - "$_behavior" >"$WORK/port.$_behavior" 2>>"$WORK/mock.log" <<'MOCK' &
import socket, sys, threading
behavior = sys.argv[1]
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0))
srv.listen(8)
print(srv.getsockname()[1], flush=True)
def handle(conn):
    try:
        conn.recv(16)
        if behavior == "authmethod":
            conn.sendall(b"\x05\xff")
    finally:
        conn.close()
while True:
    client, _ = srv.accept()
    threading.Thread(target=handle, args=(client,), daemon=True).start()
MOCK
    _mockpid=$!
    _i=0
    while [ "$_i" -lt 50 ]; do
        [ -s "$WORK/port.$_behavior" ] && break
        _i=$((_i + 1))
        sleep 0.1
    done
    _port=$(cat "$WORK/port.$_behavior" 2>/dev/null)
    python3 "$VERIFY_PY" "$_port" "$WORK/pass" >"$WORK/out.$_behavior" 2>&1
    kill "$_mockpid" 2>/dev/null || true
    wait "$_mockpid" 2>/dev/null || true
}

run_case close
run_case authmethod

_diag_close=$(grep 'data-plane verification failed' "$WORK/out.close" || true)
_diag_auth=$(grep 'data-plane verification failed' "$WORK/out.authmethod" || true)

assert_ne "the closed-inbound case produced a diagnostic" "" "$_diag_close"
assert_ne "the auth-method case produced a diagnostic" "" "$_diag_auth"
assert_ne "two distinct failures produce distinct diagnostics" "$_diag_close" "$_diag_auth"
assert_contains "a closed inbound names its reason" "closed" "$_diag_close"
assert_contains "a rejected auth method names its reason" "auth method" "$_diag_auth"

t_summary
