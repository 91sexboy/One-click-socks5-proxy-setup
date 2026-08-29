#!/bin/sh
# CI-only post-install checks that require real root-owned system resources.

set -eu

mode=${1:?usage: post_install_audit.sh systemd|openrc SCRATCH [HOME]}
scratch=${2:?scratch directory required}
user_home=${3:-}
project=socks5-manager
account=socks5proxy
confdir=/etc/$project
users=$confdir/users.cfg
state=/var/lib/$project/state
binary=/usr/local/libexec/$project/3proxy

fail() {
    printf 'post-install audit: %s\n' "$1" >&2
    exit 1
}

assert_meta() {
    expected=$1
    path=$2
    actual=$(stat -c '%U:%G %a' "$path") || fail "cannot stat $path"
    [ "$actual" = "$expected" ] ||
        fail "$path metadata is $actual, expected $expected"
}

assert_meta 'root:root 755' "$binary"
assert_meta 'root:socks5proxy 750' "$confdir"
assert_meta 'root:socks5proxy 640' "$confdir/3proxy.cfg"
assert_meta 'root:socks5proxy 640' "$users"
assert_meta 'root:root 600' "$state"
case "$mode" in
systemd) assert_meta 'root:root 644' "/etc/systemd/system/$project.service" ;;
openrc) assert_meta 'root:root 755' "/etc/init.d/$project" ;;
*) fail "unknown init mode: $mode" ;;
esac

entry=$(getent passwd "$account") || fail "account is absent"
[ "$(printf '%s\n' "$entry" | cut -d: -f6)" = /nonexistent ] ||
    fail "account home is not /nonexistent"
shell=$(printf '%s\n' "$entry" | cut -d: -f7)
case "$shell" in
*/nologin | */false) ;;
*) fail "account shell is not nologin/false: $shell" ;;
esac
shadow=$(awk -F: -v name="$account" '$1 == name { print $2 }' /etc/shadow)
case "$shadow" in
'!'* | '*'*) ;;
*) fail "account has a usable password field" ;;
esac

pattern=$scratch/installed-pass
umask 077
awk -F: 'NF == 3 { print $3 }' "$users" >"$pattern"
chmod 0600 "$pattern"
[ "$(wc -l <"$pattern")" -eq 1 ] || fail "installed credential is not one line"
[ -s "$pattern" ] || fail "installed password is empty"

log_hits() {
    find /var/log -type f -exec grep -F -l -f "$pattern" {} + 2>/dev/null || true
}

probe=/var/log/s5-ci-secret-probe.$$
cleanup_probe() { rm -f "$probe"; }
trap cleanup_probe EXIT HUP INT TERM
cat "$pattern" >"$probe"
probe_hits=$(log_hits)
case "$probe_hits" in
*"$probe"*) ;;
*) fail "the /var/log secret scanner cannot detect its planted probe" ;;
esac
rm -f "$probe"

hits=$(log_hits)
[ -z "$hits" ] || fail "password found in log file(s): $hits"

check_history() {
    history=$1
    [ -f "$history" ] || return 0
    [ -r "$history" ] || fail "cannot read shell history: $history"
    if grep -F -q -f "$pattern" "$history"; then
        fail "password found in shell history: $history"
    fi
}

for history in /root/.bash_history /root/.ash_history /root/.sh_history /root/.zsh_history; do
    check_history "$history"
done
if [ -n "$user_home" ] && [ "$user_home" != /root ]; then
    for history in "$user_home/.bash_history" "$user_home/.ash_history" \
        "$user_home/.sh_history" "$user_home/.zsh_history"; do
        check_history "$history"
    done
fi

if [ "$mode" = systemd ]; then
    journal=$scratch/journal.log
    if ! journalctl --no-pager -o cat >"$journal" 2>/dev/null; then
        fail "cannot read the systemd journal"
    fi
    chmod 0600 "$journal"
    if grep -F -q -f "$pattern" "$journal"; then
        fail "password found in the systemd journal"
    fi
fi

rm -f "$pattern" "${journal:-}"
trap - EXIT HUP INT TERM
exit 0
