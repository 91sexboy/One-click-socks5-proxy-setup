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

path_contract() {
    _pc_path=$1
    _pc_type=$2
    _pc_allowed=$3
    as_root test ! -L "$_pc_path" || return 1
    case "$_pc_type" in
    file) as_root test -f "$_pc_path" ;;
    dir) as_root test -d "$_pc_path" ;;
    *) return 1 ;;
    esac || return 1
    _pc_actual=$(as_root stat -c '%U:%G %a' "$_pc_path") || return 1
    case "|$_pc_allowed|" in *"|$_pc_actual|"*) return 0 ;; esac
    printf 'cleanup: unsafe ownership or mode on %s\n' "$_pc_path" >&2
    return 1
}

if exists /var/lib/xray-socks5/state || exists /var/lib/xray-socks5/uninstall ||
   exists /var/lib/.xray-socks5-uninstall; then
    answers=$(mktemp)
    trap 'rm -f "$answers"' EXIT HUP INT TERM
    printf 'y\n' >"$answers"
    chmod 0600 "$answers"
    as_root sh socks5.sh uninstall <"$answers"
    # Production uninstall retains language preference. This script owns a
    # disposable CI namespace, so remove the safe preference before the next gate.
    if exists /etc/xray-socks5.lang; then
        as_root test -f /etc/xray-socks5.lang
        as_root test ! -L /etc/xray-socks5.lang
        case "$(as_root stat -c '%U:%G %a' /etc/xray-socks5.lang)" in
        'root:root 600'|'root:root 644') ;;
        *) printf 'cleanup: unsafe language preference residue\n' >&2; exit 1 ;;
        esac
        as_root rm -f /etc/xray-socks5.lang
    fi
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

# Prove account ownership before touching files. A user/group pair without a
# state record is accepted only in the exact installer-created CI shape.
if identity_state passwd xray-socks5; then user_state=0; else user_state=$?; fi
if identity_state group xray-socks5; then group_state=0; else group_state=$?; fi
[ "$user_state" -ne 2 ] && [ "$group_state" -ne 2 ] || {
    printf 'cleanup: account identity lookup failed\n' >&2; exit 1;
}
[ "$user_state:$group_state" != 1:0 ] || {
    printf 'cleanup: refusing group-only residue without ownership evidence\n' >&2; exit 1;
}
if [ "$user_state" = 0 ]; then
    [ "$group_state" = 0 ] || { printf 'cleanup: service group is missing\n' >&2; exit 1; }
    account=$(as_root getent passwd xray-socks5)
    IFS=: read -r account_name _ name_uid name_gid _ home shell <<EOF
$account
EOF
    [ "$account_name:$home:$shell" = xray-socks5:/nonexistent:/usr/sbin/nologin ] || {
        printf 'cleanup: refusing foreign service account\n' >&2; exit 1;
    }
    case "$name_uid:$name_gid" in *[!0-9:]*|*::*|:*|*:)
        printf 'cleanup: invalid service account identity\n' >&2; exit 1 ;;
    esac
    [ "$name_uid" -lt 1000 ] && [ "$name_gid" -lt 1000 ] || {
        printf 'cleanup: refusing non-system service account\n' >&2; exit 1;
    }
    group=$(as_root getent group xray-socks5)
    IFS=: read -r group_name _ group_gid members <<EOF
$group
EOF
    [ "$group_name:$name_gid:$members" = "xray-socks5:$group_gid:" ] || {
        printf 'cleanup: refusing foreign service group\n' >&2; exit 1;
    }
fi

if exists /etc/systemd/system/xray-socks5.service; then
    path_contract /etc/systemd/system/xray-socks5.service file 'root:root 644'
fi
if exists /usr/local/libexec/xray-socks5; then
    path_contract /usr/local/libexec/xray-socks5 dir 'root:root 700|root:root 755'
fi
if exists /usr/local/libexec/xray-socks5/xray; then
    path_contract /usr/local/libexec/xray-socks5/xray file 'root:root 755'
fi
if exists /etc/xray-socks5; then
    path_contract /etc/xray-socks5 dir 'root:root 700|root:xray-socks5 750'
fi
if exists /etc/xray-socks5/config.json; then
    path_contract /etc/xray-socks5/config.json file 'root:xray-socks5 640'
fi
for path in /etc/xray-socks5/.s5new.*; do
    if exists "$path"; then path_contract "$path" file 'root:xray-socks5 640'; fi
done
for path in /etc/xray-socks5/.s5tmp.*; do
    if exists "$path"; then path_contract "$path" file 'root:root 600|root:xray-socks5 640'; fi
done
if exists /var/lib/xray-socks5; then
    path_contract /var/lib/xray-socks5 dir 'root:root 700'
fi
if exists /var/lib/xray-socks5/transaction; then
    path_contract /var/lib/xray-socks5/transaction dir 'root:root 700'
    for path in /var/lib/xray-socks5/transaction/* /var/lib/xray-socks5/transaction/.[!.]*; do
        if exists "$path"; then path_contract "$path" file 'root:root 600'; fi
    done
fi
for path in /var/lib/xray-socks5/.s5state.* /var/lib/xray-socks5/.s5tmp.*; do
    if exists "$path"; then path_contract "$path" file 'root:root 600'; fi
done
for path in /usr/local/libexec/xray-socks5/.xray.*; do
    if exists "$path"; then path_contract "$path" file 'root:root 755'; fi
done

load_state=$(manager_load_state || printf unknown)
case "$load_state" in
loaded)
    as_root systemctl stop xray-socks5.service
    active_state=$(as_root systemctl is-active xray-socks5.service 2>/dev/null || true)
    case "$active_state" in
    inactive|failed) ;;
    active|activating|reloading|deactivating) printf 'cleanup: service remains active\n' >&2; exit 1 ;;
    *) printf 'cleanup: stopped service state is unobservable\n' >&2; exit 1 ;;
    esac
    as_root systemctl disable xray-socks5.service
    ;;
not-found) ;;
*) printf 'cleanup: service manager state is unobservable\n' >&2; exit 1 ;;
esac

if [ "$user_state" = 0 ]; then
    process_status=0
    as_root pgrep -u "$name_uid" >/dev/null 2>&1 || process_status=$?
    case "$process_status" in
    0) printf 'cleanup: service account still owns a process\n' >&2; exit 1 ;;
    1) ;;
    *) printf 'cleanup: process ownership is unobservable\n' >&2; exit 1 ;;
    esac
fi

as_root rm -f /etc/systemd/system/xray-socks5.service
for dir in /etc/xray-socks5 /var/lib/xray-socks5 /usr/local/libexec/xray-socks5; do
    if exists "$dir"; then as_root rm -rf "$dir"; fi
done
as_root rm -f /etc/xray-socks5.lang

if [ "$user_state" = 0 ]; then as_root userdel xray-socks5; fi
if [ "$group_state" = 0 ]; then as_root groupdel xray-socks5; fi
if identity_state passwd xray-socks5; then _icu=0; else _icu=$?; fi
if identity_state group xray-socks5; then _icg=0; else _icg=$?; fi
[ "$_icu" = 1 ] || { printf 'cleanup: user residue remains\n' >&2; exit 1; }
[ "$_icg" = 1 ] || { printf 'cleanup: group residue remains\n' >&2; exit 1; }

as_root systemctl daemon-reload
[ "$(manager_load_state || printf unknown)" = not-found ] || {
    printf 'cleanup: service registration residue remains\n' >&2; exit 1;
}
enabled_state=$(as_root systemctl is-enabled xray-socks5.service 2>/dev/null || true)
[ "$enabled_state" = not-found ] || {
    printf 'cleanup: service enablement residue remains or is unobservable\n' >&2
    exit 1
}
