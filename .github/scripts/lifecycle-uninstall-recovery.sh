#!/bin/sh
# lifecycle-uninstall-recovery.sh <systemd|openrc> <workdir>: interrupt a real
# uninstall of the running reinstalled proxy twice and resume it, as root.
#
# 1. The manager's disable step fails once, so the recovery record says stopped
#    while the service is still enabled. The service is then started again, as a
#    reboot would start it, and restart must refuse the pending uninstall.
# 2. The resumed uninstall must stop that service again before removing
#    anything. Its user deletion succeeds but reports failure, leaving the record
#    at manager-reloaded; the group is then deleted as a crash before the next
#    checkpoint would leave it, so its name no longer resolves while the config
#    directory still carries its GID.
# 3. The last resume must recognise that directory by its recorded numeric owner
#    and finish. Its log is the gate's uninstall-reinstall.log.
#
# The shims sit on PATH only for the command they fail, record every call they
# intercept, and are required to have been reached, so a shell that bypassed
# PATH would fail here rather than pass vacuously.
set -eu
# shellcheck source=.github/scripts/lifecycle-common.sh
. "$(dirname "$0")/lifecycle-common.sh"
backend=${1:?usage: lifecycle-uninstall-recovery.sh systemd|openrc WORKDIR}
work=${2:?usage: lifecycle-uninstall-recovery.sh systemd|openrc WORKDIR}
case "$backend" in
systemd) manager=systemctl; disable_verb=disable; user_tool=userdel; group_tool=groupdel ;;
openrc) manager=rc-update; disable_verb=del; user_tool=deluser; group_tool=delgroup ;;
*) printf 'recovery gate: unknown backend %s\n' "$backend" >&2; exit 2 ;;
esac
record=/var/lib/xray-socks5/uninstall
shim=$(mktemp -d)
trap 'rm -rf "$shim"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
calls=$shim/calls

recovery_real() {
    _rr=$(command -v "$1") || { printf 'recovery gate: %s is missing\n' "$1" >&2; return 1; }
    case "$_rr" in
    /*) printf '%s\n' "$_rr" ;;
    *) printf 'recovery gate: %s resolves to %s, not a file PATH can shadow\n' "$1" "$_rr" >&2; return 1 ;;
    esac
}

# recovery_shim <tool> <first-argument> <fail|after>: <tool> fails when called
# with <first-argument>, after running the real tool in "after" mode.
recovery_shim() {
    _rs_real=$(recovery_real "$1")
    cat >"$shim/bin/$1" <<SHIM
#!/bin/sh
if [ "\${1:-}" = '$2' ]; then
    printf '%s %s\n' '$1' "\$*" >>'$calls'
    if [ '$3' = after ]; then '$_rs_real' "\$@" || exit \$?; fi
    exit 1
fi
exec '$_rs_real' "\$@"
SHIM
    chmod 0755 "$shim/bin/$1"
}

recovery_phase() {
    awk -F '\t' '$1 == "phase" { print $2 }' "$record"
}

recovery_listening() {
    python3 -c 'import socket, sys; s = socket.socket(); s.settimeout(2); sys.exit(0 if s.connect_ex(("127.0.0.1", 23456)) == 0 else 1)'
}

recovery_quiet() {
    ! recovery_listening
}

# recovery_uninstall_fails <log>: uninstall through the shims must fail.
recovery_uninstall_fails() {
    if env PATH="$shim/bin:$PATH" sh .github/scripts/run-socks5.sh uninstall \
        "$work/answers.empty" "$1" "$work/pass"; then
        printf 'recovery gate: the shimmed uninstall did not fail\n' >&2
        return 1
    fi
    lifecycle_generation_absent "$1" "$work/pass"
}

mkdir "$shim/bin"
lifecycle_wait_until 30 1 recovery_listening

printf 'lifecycle: uninstall-recovery-interrupt-stopped\n'
recovery_shim "$manager" "$disable_verb" fail
if env PATH="$shim/bin:$PATH" sh .github/scripts/run-socks5.sh uninstall \
    "$work/answers.uninstall" "$work/uninstall-interrupted.log" "$work/pass"; then
    printf 'recovery gate: uninstall survived a failed disable\n' >&2
    exit 1
fi
lifecycle_generation_absent "$work/uninstall-interrupted.log" "$work/pass"
grep -q "^$manager $disable_verb " "$calls"
rm -f "$shim/bin/$manager"
test "$(recovery_phase)" = stopped
lifecycle_wait_until 15 1 recovery_quiet
test -e /etc/xray-socks5/config.json

printf 'lifecycle: uninstall-recovery-running-again\n'
# The service is still enabled, so this is what a reboot would do.
case "$backend" in
systemd) systemctl start xray-socks5.service ;;
openrc) rc-service xray-socks5 start ;;
esac
lifecycle_wait_until 30 1 recovery_listening
if sh .github/scripts/run-socks5.sh restart \
    "$work/answers.empty" "$work/restart-pending.log" "$work/pass"; then
    printf 'recovery gate: restart ran under a pending uninstall\n' >&2
    exit 1
fi
lifecycle_generation_absent "$work/restart-pending.log" "$work/pass"
grep -q 'an interrupted uninstall is pending; run uninstall to finish it.' "$work/restart-pending.log"
test "$(recovery_phase)" = stopped

printf 'lifecycle: uninstall-recovery-restops\n'
recovery_shim "$user_tool" xray-socks5 after
recovery_uninstall_fails "$work/uninstall-resumed.log"
grep -q "^$user_tool xray-socks5" "$calls"
rm -f "$shim/bin/$user_tool"
test "$(recovery_phase)" = manager-reloaded
# The resume stopped the service it found running before removing its unit,
# config and binary; a proxy left running would still hold the port.
recovery_quiet
test ! -e /etc/xray-socks5/config.json
test ! -e /usr/local/libexec/xray-socks5/xray
if getent passwd xray-socks5 >/dev/null 2>&1; then exit 1; fi

printf 'lifecycle: uninstall-recovery-group-gone\n'
if getent group xray-socks5 >/dev/null 2>&1; then "$(recovery_real "$group_tool")" xray-socks5; fi
if getent group xray-socks5 >/dev/null 2>&1; then exit 1; fi
test -d /etc/xray-socks5
stat -c '%u:%g %U:%G %a %n' /etc/xray-socks5
sh .github/scripts/run-socks5.sh uninstall \
    "$work/answers.empty" "$work/uninstall-reinstall.log" "$work/pass"
test ! -e /etc/xray-socks5
test ! -e /var/lib/xray-socks5
test ! -e /var/lib/.xray-socks5-uninstall
test ! -e /usr/local/libexec/xray-socks5
case "$backend" in
systemd) test ! -e /etc/systemd/system/xray-socks5.service ;;
openrc) test ! -e /etc/init.d/xray-socks5 ;;
esac
recovery_quiet
printf 'lifecycle: uninstall-recovery-ok\n'
