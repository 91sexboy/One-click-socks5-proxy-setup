#!/bin/sh
# CI-only launcher for the pinned Xray mixed proxy.
set -u
umask 077

OUTDIR=${OUTDIR:?OUTDIR must be set}
PASSFILE=${PASSFILE:?PASSFILE must be set}
PORT=${PORT:?PORT must be set}
ARCH=${ARCH:-amd64}

case "$ARCH" in
amd64)
    ASSET=Xray-linux-64.zip
    SIZE=21136402
    SHA=23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae
    ;;
arm64)
    ASSET=Xray-linux-arm64-v8a.zip
    SIZE=19716427
    SHA=4d30283ae614e3057f730f67cd088a42be6fdf91f8639d82cb69e48cde80413c
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
trap cleanup EXIT HUP INT TERM

if ! curl -fsSL --proto '=https' --proto-redir '=https' --max-filesize $((SIZE + 1)) \
    -o "$WORK/$ASSET" "https://github.com/XTLS/Xray-core/releases/download/v26.3.27/$ASSET"; then
    fail 'Xray archive download failed'
fi
archive_size=$(wc -c <"$WORK/$ASSET" | tr -d '[:space:]') || fail 'cannot measure Xray archive'
[ "$archive_size" = "$SIZE" ] || fail "Xray archive size mismatch: $archive_size"
archive_sha=$(sha256sum "$WORK/$ASSET" | awk '{print $1}') || fail 'cannot hash Xray archive'
[ "$archive_sha" = "$SHA" ] || fail 'Xray archive SHA-256 mismatch'
unzip -Z1 "$WORK/$ASSET" >"$WORK/members" || fail 'cannot inspect Xray archive'
[ "$(grep -cxF xray "$WORK/members" || true)" = 1 ] || fail 'archive must contain exactly one xray member'
for member in geoip.dat geosite.dat LICENSE README.md; do
    [ "$(grep -cxF "$member" "$WORK/members" || true)" = 1 ] || fail "archive missing $member"
done
[ "$(wc -l <"$WORK/members" | tr -d '[:space:]')" = 5 ] || fail 'archive contains unexpected member count'
while IFS= read -r member; do
    case "$member" in
    '' | */* | *..* | *\\*) fail 'archive contains an unsafe member name' ;;
    esac
done <"$WORK/members"

unzip -p "$WORK/$ASSET" xray >"$WORK/xray" || fail 'cannot extract xray member'
chmod 0755 "$WORK/xray" || fail 'cannot chmod xray'
_file=$(file -b "$WORK/xray" 2>/dev/null) || fail 'cannot inspect xray executable'
case "$ARCH:$_file" in
amd64:*'ELF 64-bit LSB executable, x86-64'*) ;;
arm64:*'ELF 64-bit LSB executable, ARM aarch64'*) ;;
*) fail 'xray ELF architecture does not match the requested architecture' ;;
esac
ENGINE="$WORK/xray"
: >"$WORK/config.json" || fail 'cannot create Xray config'
chmod 0600 "$WORK/config.json" || fail 'cannot protect Xray config'
# The routing block is the destination boundary of SPEC 3, hand-copied here the
# way the release digests are: this launcher stays independent of socks5.sh so a
# renderer defect cannot mask a protocol defect. test_xray_docs.sh asserts that
# the ranges below and the ones s5_config_render emits are the same set.
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
printf '%s\n' "$PORT" >"$OUTDIR/port"
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
[ "$ready" = 1 ] || fail 'Xray did not become ready within 30 seconds'
printf 'xray ready pid=%s port=%s\n' "$XRAY_PID" "$PORT"
wait "$XRAY_PID"
