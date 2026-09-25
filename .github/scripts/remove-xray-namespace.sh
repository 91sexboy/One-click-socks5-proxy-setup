#!/bin/sh
# Fail-closed CI namespace cleanup. Prefer production uninstall when trusted
# state exists; raw cleanup is limited to the known disposable CI namespace.
set -eu

as_root() { sudo "$@"; }
exists() { as_root test -e "$1" || as_root test -L "$1"; }
manager_load_state() { as_root systemctl show xray-socks5.service -p LoadState --value 2>/dev/null; }
identity_state() {
    _ics_kind=$1
    _ics_name=$2
    as_root getent "$_ics_kind" "$_ics_name" >/dev/null 2>&1
    case $? in 0) return 0 ;; 2) return 1 ;; *) return 2 ;; esac
}

if exists /var/lib/xray-socks5/state || exists /var/lib/xray-socks5/uninstall ||
   exists /var/lib/.xray-socks5-uninstall; then
    answers=$(mktemp)
    trap 'rm -f "$answers"' EXIT HUP INT TERM
    printf 'y\n' >"$answers"
    chmod 0600 "$answers"
    as_root sh socks5.sh uninstall <"$answers"
    exit 0
fi

# No trusted record means raw cleanup may only touch the exact disposable CI
# shape. Every nested transaction entry is checked before any destructive step.
for dir in /etc/xray-socks5 /var/lib/xray-socks5 /usr/local/libexec/xray-socks5; do
    if exists "$dir"; then
        as_root test -d "$dir"
        as_root test ! -L "$dir"
        case "$dir" in
        /etc/xray-socks5) allowed='config.json .s5new.* .s5tmp.*' ;;
        /var/lib/xray-socks5) allowed='transaction .s5state.* .s5tmp.*' ;;
        *) allowed='xray .xray.*' ;;
        esac
        entries=$(as_root find "$dir" -mindepth 1 -maxdepth 1 -printf '%f\n')
        for entry in $entries; do
            ok=0
            for pattern in $allowed; do case "$entry" in $pattern) ok=1 ;; esac; done
            [ "$ok" = 1 ] || { printf 'cleanup: unknown residue %s/%s\n' "$dir" "$entry" >&2; exit 1; }
        done
    fi
done
if exists /var/lib/xray-socks5/transaction; then
    as_root test -d /var/lib/xray-socks5/transaction
    as_root test ! -L /var/lib/xray-socks5/transaction
    entries=$(as_root find /var/lib/xray-socks5/transaction -mindepth 1 -maxdepth 1 -printf '%f\n')
    for entry in $entries; do
        case "$entry" in old.config.json|old.state|old.xray|committed|stopping|.s5new.*|.s5tmp.*) ;;
        *) printf 'cleanup: unknown transaction residue %s\n' "$entry" >&2; exit 1 ;;
        esac
    done
fi

load_state=$(manager_load_state || printf unknown)
case "$load_state" in
loaded)
    as_root systemctl stop xray-socks5.service
    if as_root systemctl is-active --quiet xray-socks5.service; then
        printf 'cleanup: service remains active\n' >&2
        exit 1
    fi
    as_root systemctl disable xray-socks5.service
    ;;
not-found) ;;
*) printf 'cleanup: service manager state is unobservable\n' >&2; exit 1 ;;
esac

as_root rm -f /etc/systemd/system/xray-socks5.service
for dir in /etc/xray-socks5 /var/lib/xray-socks5 /usr/local/libexec/xray-socks5; do
    if exists "$dir"; then as_root rm -rf "$dir"; fi
done
as_root rm -f /etc/xray-socks5.lang

if identity_state passwd xray-socks5; then user_state=0; else user_state=$?; fi
if identity_state group xray-socks5; then group_state=0; else group_state=$?; fi
[ "$user_state" -ne 2 ] && [ "$group_state" -ne 2 ] || {
    printf 'cleanup: account identity lookup failed\n' >&2; exit 1;
}
if [ "$user_state" = 0 ]; then
    account=$(as_root getent passwd xray-socks5)
    IFS=: read -r _ name_uid name_gid _ home shell <<EOF
$account
EOF
    [ "$home:$shell" = /nonexistent:/usr/sbin/nologin ] || {
        printf 'cleanup: refusing foreign service account\n' >&2; exit 1;
    }
    group=$(as_root getent group xray-socks5)
    IFS=: read -r _ _ group_gid _ <<EOF
$group
EOF
    [ "$name_gid" = "$group_gid" ] || { printf 'cleanup: account/group mismatch\n' >&2; exit 1; }
    as_root userdel xray-socks5
fi
if [ "$group_state" = 0 ]; then as_root groupdel xray-socks5; fi
if identity_state passwd xray-socks5; then _icu=0; else _icu=$?; fi
if identity_state group xray-socks5; then _icg=0; else _icg=$?; fi
[ "$_icu" = 1 ] || { printf 'cleanup: user residue remains\n' >&2; exit 1; }
[ "$_icg" = 1 ] || { printf 'cleanup: group residue remains\n' >&2; exit 1; }

as_root systemctl daemon-reload
[ "$(manager_load_state || printf unknown)" = not-found ] || {
    printf 'cleanup: service registration residue remains\n' >&2; exit 1;
}
