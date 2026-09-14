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
# shellcheck source=/dev/null
. "${S5_REPO_ROOT}/tests/lib/assert.sh"

SRC=${S5_SRC:-${S5_REPO_ROOT}/socks5.sh}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/s5verify.XXXXXX") || { printf 'cannot create workdir\n' >&2; exit 1; }
# Capture the owned scratch directory before any test can change WORK.
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
s5t_run_case() {
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
    _direct_status=$?
    (
        S5_LIB_ONLY=1
        S5_TEST_MODE=1
        S5_TEST_ROOT=$WORK
        : >"$S5_TEST_ROOT/.s5-test-root"
        export S5_LIB_ONLY S5_TEST_MODE S5_TEST_ROOT
        # Production is selected dynamically for mutation checks.
        # shellcheck source=/dev/null
        . "$SRC"
        s5_verify_protocols "$_port" "$WORK/pass"
    ) >"$WORK/helper.$_behavior" 2>&1
    assert_eq "$_behavior helper preserves Python exit status" "$_direct_status" "$?"
    assert_eq "$_behavior helper preserves Python diagnostics" \
        "$(cat "$WORK/out.$_behavior")" "$(cat "$WORK/helper.$_behavior")"
    kill "$_mockpid" 2>/dev/null || true
    wait "$_mockpid" 2>/dev/null || true
}

s5t_run_case close
s5t_run_case authmethod

_diag_close=$(grep 'data-plane verification failed' "$WORK/out.close" || true)
_diag_auth=$(grep 'data-plane verification failed' "$WORK/out.authmethod" || true)

assert_ne "the closed-inbound case produced a diagnostic" "" "$_diag_close"
assert_ne "the auth-method case produced a diagnostic" "" "$_diag_auth"
assert_ne "two distinct failures produce distinct diagnostics" "$_diag_close" "$_diag_auth"
assert_contains "a closed inbound names its reason" "closed" "$_diag_close"
assert_contains "a rejected auth method names its reason" "auth method" "$_diag_auth"

S5_TEST_MODE=1
S5_TEST_ROOT=$WORK
S5_LIB_ONLY=1
: >"$S5_TEST_ROOT/.s5-test-root"
export S5_TEST_MODE S5_TEST_ROOT S5_LIB_ONLY
# Production is selected dynamically for mutation checks.
# shellcheck source=/dev/null
. "$SRC"
S5_TEST_MODE=0
S5_WORKDIR=$WORK
S5_LANG=en
S5_PORT=23456
S5_USERNAME=alice
S5_PASSWORD='Secret_123~x'
s5_verify_protocols() {
    assert_eq "wrapper passes the listener port" 23456 "$1"
    assert_eq "credential file is registered before probing" "$2" "$S5_VERIFY_TEMP"
    assert_mode "probe credentials remain private" 600 "$2"
    cmp -s "$WORK/pass" "$2"
    assert_eq "wrapper passes credentials through the file" 0 "$?"
    _verifier_path=$2
    return "$_wrapper_status"
}
for _wrapper_status in 0 17; do
    s5_verify_dataplane >"$WORK/wrapper" 2>&1
    _wrapper_result=$?
    if [ "$_wrapper_status" = 0 ]; then
        assert_eq "successful protocol probe is accepted" 0 "$_wrapper_result"
        assert_eq "successful protocol probe has no error report" '' "$(cat "$WORK/wrapper")"
    else
        assert_eq "protocol failure is normalized to command failure" 1 "$_wrapper_result"
        assert_eq "protocol failure is reported once" 1 "$(wc -l <"$WORK/wrapper" | tr -d ' ')"
    fi
    assert_file_absent "wrapper removes credentials after probing" "$_verifier_path"
    assert_eq "wrapper clears credential ownership after probing" '' "$S5_VERIFY_TEMP"
done

t_summary
