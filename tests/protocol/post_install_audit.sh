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

[ -f "$cfg" ] && [ ! -L "$cfg" ]
[ -f "$state" ] && [ ! -L "$state" ]
[ -f "$bin" ] && [ ! -L "$bin" ]
[ -f "$unit" ] && [ ! -L "$unit" ]
[ "$(stat -c '%a' "$cfg")" = 640 ]
[ "$(stat -c '%a' "$state")" = 600 ]
[ "$(stat -c '%a' "$bin")" = 755 ]
[ "$(stat -c '%a' "$unit")" = "$unit_mode" ]
[ "$(stat -c '%a' "$PASSFILE")" = 600 ]
[ "$(sed -n '2p' "$PASSFILE" | wc -c | tr -d '[:space:]')" -gt 1 ]

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

grep -qF 'engine	xray' "$state"
grep -qF 'protocol	mixed' "$state"
grep -qF 'auth	password' "$state"
grep -qF 'udp	false' "$state"
grep -qF "$unit_cmd" "$unit"
