#!/bin/sh
# CI-only post-install audit for the Xray-only namespace.
set -eu

ROOT=${1:?usage: post_install_audit.sh ROOT PASSFILE [INIT]}
PASSFILE=${2:?usage: post_install_audit.sh ROOT PASSFILE [INIT]}
INIT=${3:-systemd}

cfg="$ROOT/etc/xray-socks5/config.json"
state="$ROOT/var/lib/xray-socks5/state"
bin="$ROOT/usr/local/libexec/xray-socks5/xray"

case "$INIT" in
systemd)
    unit="$ROOT/etc/systemd/system/xray-socks5.service"
    unit_mode=644
    unit_cmd='ExecStart=/usr/local/libexec/xray-socks5/xray run -c /etc/xray-socks5/config.json'
    unit_dir="$ROOT/etc/systemd"
    ;;
openrc)
    unit="$ROOT/etc/init.d/xray-socks5"
    unit_mode=755
    unit_cmd='command_args="run -c /etc/xray-socks5/config.json"'
    unit_dir="$ROOT/etc/init.d"
    ;;
*)
    printf 'unknown init backend: %s\n' "$INIT" >&2
    exit 2
    ;;
esac

# A silent bare-test chain reports nothing about which guarantee broke, which
# turns one failing audit into a second CI round trip.
check() {
    _label=$1
    shift
    if ! "$@"; then
        printf 'audit failed on %s: %s\n' "$INIT" "$_label" >&2
        exit 1
    fi
}

# Modes carry the actual owner and mode into the message: "expected 640" alone
# does not say whether the file was created wrong or changed afterwards.
check_mode() {
    _cmlabel=$1
    _cmpath=$2
    _cmwant=$3
    if ! _cmgot=$(stat -c '%U:%G %a' "$_cmpath" 2>/dev/null); then
        printf 'audit failed on %s: %s is missing\n' "$INIT" "$_cmlabel" >&2
        exit 1
    fi
    if [ "${_cmgot##* }" != "$_cmwant" ]; then
        printf 'audit failed on %s: %s is [%s], expected mode %s\n' \
            "$INIT" "$_cmlabel" "$_cmgot" "$_cmwant" >&2
        exit 1
    fi
}

check "config is a regular file" test -f "$cfg"
check "config is not a symlink" test ! -L "$cfg"
check "state is a regular file" test -f "$state"
check "state is not a symlink" test ! -L "$state"
check "binary is a regular file" test -f "$bin"
check "binary is not a symlink" test ! -L "$bin"
check "service artifact is a regular file" test -f "$unit"
check "service artifact is not a symlink" test ! -L "$unit"
check_mode config "$cfg" 640
check_mode state "$state" 600
check_mode binary "$bin" 755
check_mode "service artifact" "$unit" "$unit_mode"
check_mode passfile "$PASSFILE" 600
check "passfile carries a password line" \
    test "$(sed -n '2p' "$PASSFILE" | wc -c | tr -d '[:space:]')" -gt 1

# The password reaches grep on stdin, never as an argument: an argument would be
# published through /proc/<pid>/cmdline, and without -q grep would print the very
# line it matched. -r rather than -R because BusyBox grep has no -R, and a scan
# that cannot run must fail the audit instead of reporting a clean namespace.
pass_leaks() {
    _rc=0
    sed -n '2p' "$PASSFILE" | grep -qrFf - "$@" 2>/dev/null || _rc=$?
    case "$_rc" in
    0) return 0 ;;
    1) return 1 ;;
    esac
    printf 'credential scan could not run (grep exit %s)\n' "$_rc" >&2
    exit 2
}

if pass_leaks "$ROOT/var/log" "$unit_dir"; then
    printf 'credential appeared in audit targets\n' >&2
    exit 1
fi
if pass_leaks "$unit" "$state"; then
    printf 'credential appeared in service or state\n' >&2
    exit 1
fi

check "state records the Xray engine" grep -qF 'engine	xray' "$state"
check "state records the mixed protocol" grep -qF 'protocol	mixed' "$state"
check "state records password auth" grep -qF 'auth	password' "$state"
check "state records UDP disabled" grep -qF 'udp	false' "$state"
check "service artifact runs Xray with the config path" \
    grep -qF "$unit_cmd" "$unit"
