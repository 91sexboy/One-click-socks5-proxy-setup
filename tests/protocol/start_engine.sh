#!/bin/sh
# CI-only launcher for the pinned Xray mixed proxy.
set -u
umask 077

OUTDIR=${OUTDIR:?OUTDIR must be set}
# Reused output must never release a consumer on a previous run's success, even
# when this invocation fails before credential/architecture validation.
rm -f "$OUTDIR/ready" "$OUTDIR/ready.tmp" "$OUTDIR/port" || exit 1
PASSFILE=${PASSFILE:?PASSFILE must be set}
PORT=${PORT:?PORT must be set}
ARCH=${ARCH:-amd64}

case "$ARCH" in
amd64)
    ASSET=xray-v26.3.27-linux-amd64
    SIZE=36577406
    SHA=8255dd939c34cf966cc91517b6324dd3c8d0bcf49ffac8beca049a38c46845ed
    ;;
arm64)
    ASSET=xray-v26.3.27-linux-arm64
    SIZE=34209918
    SHA=c2d20a7045250497083afea0d79db0672f6c89a25aaaf37c92de034d6b764b04
    ;;
*)
    printf 'unsupported architecture: %s\n' "$ARCH" >&2
    exit 2
    ;;
esac

fail() {
    printf 'xray launcher: %s\n' "$1" >&2
    exit 1
}

# Keep this independent launcher on the same packaged verification tools as
# production. Test selftests substitute these narrow seams explicitly.
if ! command -v curl_command >/dev/null 2>&1; then
    curl_command() { /usr/bin/curl "$@"; }
fi
if ! command -v sha256_command >/dev/null 2>&1; then
    sha256_command() { /usr/bin/sha256sum "$1"; }
fi
if ! command -v file_type_command >/dev/null 2>&1; then
    file_type_command() { /usr/bin/file -b "$1"; }
fi
file_type_isolated() (
    unset MAGIC
    file_type_command "$1"
)

# Engine logs are echoed on failure with the password removed. The pattern
# arrives on stdin so it never enters an external command's argv.
redact() {
    printf '%s\n' "$pass" | grep -vFf - "$1" >&2 || true
}

[ -f "$PASSFILE" ] || fail 'invalid PASSFILE'
[ ! -L "$PASSFILE" ] || fail 'invalid PASSFILE'
[ "$(stat -c '%a' "$PASSFILE" 2>/dev/null)" = 600 ] || fail 'PASSFILE must have mode 0600'
user=$(sed -n '1p' "$PASSFILE") || fail 'cannot read PASSFILE username'
pass=$(sed -n '2p' "$PASSFILE") || fail 'cannot read PASSFILE password'
[ -n "$user" ] || fail 'PASSFILE is incomplete'
[ -n "$pass" ] || fail 'PASSFILE is incomplete'

mkdir -p "$OUTDIR" || fail 'cannot create output directory'
chmod 0700 "$OUTDIR" || fail 'cannot protect output directory'
WORK=$(mktemp -d "${TMPDIR:-/tmp}/xray-mixed.XXXXXX") || fail 'cannot create private workdir'
XRAY_PID=''
TARGET_PID=''
cleanup() {
    trap - EXIT HUP INT TERM
    rm -f "$OUTDIR/ready" "$OUTDIR/ready.tmp"
    if [ -n "$XRAY_PID" ]; then
        kill "$XRAY_PID" 2>/dev/null || true
        wait "$XRAY_PID" 2>/dev/null || true
    fi
    if [ -n "$TARGET_PID" ]; then
        kill "$TARGET_PID" 2>/dev/null || true
        wait "$TARGET_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

if ! curl_command -q -fsSL --proto '=https' --proto-redir '=https' --max-filesize $((SIZE + 1)) \
    -o "$WORK/xray" "https://github.com/91sexboy/One-click-socks5-proxy-setup/releases/download/xray-v26.3.27-r1/$ASSET"; then
    fail 'Xray raw asset download failed'
fi
binary_size=$(wc -c <"$WORK/xray" | tr -d '[:space:]') || fail 'cannot measure Xray raw asset'
[ "$binary_size" = "$SIZE" ] || fail "Xray raw asset size mismatch: $binary_size"
binary_sha=$(sha256_command "$WORK/xray" | awk '{print $1}') || fail 'cannot hash Xray raw asset'
[ "$binary_sha" = "$SHA" ] || fail 'Xray raw asset SHA-256 mismatch'
chmod 0755 "$WORK/xray" || fail 'cannot chmod xray'
_file=$(file_type_isolated "$WORK/xray" 2>/dev/null) || fail 'cannot inspect xray executable'
case "$ARCH:$_file" in
amd64:*'ELF 64-bit LSB executable, x86-64'*) ;;
arm64:*'ELF 64-bit LSB executable, ARM aarch64'*) ;;
*) fail 'xray ELF architecture does not match the requested architecture' ;;
esac
case "$_file" in
*'dynamically linked'* | *'interpreter '*) fail 'xray executable is dynamically linked' ;;
esac
_version=$("$WORK/xray" version 2>/dev/null) || fail 'cannot read Xray version'
case "${_version%%
*}" in 'Xray 26.3.27 '*) ;; *) fail 'Xray version mismatch' ;; esac
ENGINE="$WORK/xray"

: >"$WORK/config.json" || fail 'cannot create Xray config'
chmod 0600 "$WORK/config.json" || fail 'cannot protect Xray config'
# This launcher stays independent of socks5.sh so a renderer defect cannot mask
# a protocol defect. test_xray_boundary.sh compares both sets of destination ranges
# against the independent tests/fixtures/denied-destinations.txt expectation.
cat >"$WORK/config.json" <<CONFIG
{
  "log": {"loglevel": "warning", "access": "none", "error": ""},
  "inbounds": [{
    "listen": "127.0.0.1",
    "port": $PORT,
    "protocol": "mixed",
    "settings": {"auth": "password", "accounts": [{"user": "$user", "pass": "$pass"}], "udp": false},
    "tag": "xray-mixed-in"
  }],
  "outbounds": [
    {"protocol": "freedom", "settings": {}, "tag": "direct"},
    {"protocol": "blackhole", "settings": {}, "tag": "blocked"}
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [{
      "type": "field",
      "outboundTag": "blocked",
      "ip": [
        "0.0.0.0/8",
        "10.0.0.0/8",
        "100.64.0.0/10",
        "127.0.0.0/8",
        "169.254.0.0/16",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "224.0.0.0/4",
        "240.0.0.0/4",
        "::1/128",
        "fc00::/7",
        "fe80::/10"
      ]
    }]
  }
}
CONFIG
"$ENGINE" run -test -c "$WORK/config.json" >"$WORK/config-test.log" 2>&1 || {
    printf 'xray config-test failed\n' >&2
    redact "$WORK/config-test.log"
    fail 'Xray config-test rejected the generated config'
}
"$ENGINE" run -c "$WORK/config.json" >"$WORK/xray.log" 2>&1 &
XRAY_PID=$!
printf '%s\n' "$XRAY_PID" >"$OUTDIR/xray.pid"
printf '%s\n' "$WORK/config.json" >"$OUTDIR/config.path"

ready=0
n=0
while [ "$n" -lt 30 ]; do
    if ! kill -0 "$XRAY_PID" 2>/dev/null; then
        printf 'xray exited before readiness\n' >&2
        redact "$WORK/xray.log"
        fail 'Xray exited before the listener became ready'
    fi
    if python3 - "$PORT" <<'PY'
import socket, sys
sock = socket.socket()
sock.settimeout(0.5)
try:
    result = sock.connect_ex(("127.0.0.1", int(sys.argv[1])))
finally:
    sock.close()
sys.exit(0 if result == 0 else 1)
PY
    then
        ready=1
        break
    fi
    n=$((n + 1))
    sleep 1
done
if [ "$ready" != 1 ] || ! kill -0 "$XRAY_PID" 2>/dev/null; then
    redact "$WORK/xray.log"
    fail 'Xray did not become ready within 30 seconds'
fi
# PORT is startup input; ready is the only consumer release signal. Rename so a
# reader sees either no marker or the complete port, never a partially written one.
printf '%s\n' "$PORT" >"$OUTDIR/ready.tmp" || fail 'cannot stage readiness marker'
mv -f "$OUTDIR/ready.tmp" "$OUTDIR/ready" || fail 'cannot publish readiness marker'
printf 'xray ready pid=%s port=%s\n' "$XRAY_PID" "$PORT"
wait "$XRAY_PID"
