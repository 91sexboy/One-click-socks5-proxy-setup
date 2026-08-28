#!/bin/sh
# tests/unit/test_lifecycle.sh - Task 7: status, show, restart, uninstall,
# the no-argument menu, precise firewall rollback and idempotency.

S5T_NAME=test_lifecycle
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
. "${S5_REPO_ROOT}/tests/lib/stub.sh"
. "${S5_REPO_ROOT}/tests/lib/env.sh"

s5env_setup
s5env_load

USER_OK=lifeuser
PASS_OK='LifePass_1234~x'
printf '%s:%s' "$USER_OK" "$PASS_OK" >"$S5_TEST_ROOT/expected_creds"
S5_LOGSINK="$S5_TEST_ROOT/logsink"
export S5_LOGSINK
: >"$S5_LOGSINK"

# Plant resources this script must never touch.
mkdir -p "$S5_TEST_ROOT/usr/bin" "$S5_TEST_ROOT/etc/3proxy"
printf 'foreign system 3proxy\n' >"$S5_TEST_ROOT/usr/bin/3proxy"
printf 'foreign 3proxy config with its own users\n' >"$S5_TEST_ROOT/etc/3proxy/3proxy.cfg"
printf 'unrelated config\n' >"$S5_TEST_ROOT/etc/unrelated.conf"

# An already-active iptables firewall with a pre-existing foreign rule.
t_stub_script iptables 'case "${1:-}" in
-S) echo '-A INPUT -p tcp --dport 22 -j ACCEPT'; exit 0 ;;
-C) [ -f "$S5_TEST_ROOT/iptables_rule" ] && exit 0 || exit 1 ;;
-I) : >"$S5_TEST_ROOT/iptables_rule"; exit 0 ;;
-D) rm -f "$S5_TEST_ROOT/iptables_rule"; exit 0 ;;
*) exit 0 ;;
esac'

# ==========================================================================
# Install once so the lifecycle commands have something to act on
# ==========================================================================
mkdir -p "$S5_UNITDIR"
s5env_answers 'y
41080
lifeuser
LifePass_1234~x
LifePass_1234~x
y
y
'
t_run s5_cmd_install <"$S5_TEST_ROOT/answers"
assert_eq "install for lifecycle tests succeeded" 0 "$T_STATUS"
assert_file_exists "config present" "$S5_CFG"
s5_state_load
assert_eq "install records no firewall ownership" "" "$(s5_state_get firewall)"
# No firewall functionality exists at all (owner decision), so an install run
# must not invoke any firewall backend -- not even a read-only detection query.
t_assert_cmd_never_called "install runs no firewall command at all" \
    iptables ufw firewall-cmd nft
assert_not_contains "install log sink has no password" "$PASS_OK" "$(cat "$S5_LOGSINK")"

# ==========================================================================
# status
# ==========================================================================
s5env_reset_transcript
t_run s5_cmd_status
assert_eq "status exits 0 when installed" 0 "$T_STATUS"
assert_contains "status shows the port" "41080" "$T_OUT"
assert_contains "status shows the username" "lifeuser" "$T_OUT"
assert_contains "status shows the engine version" "0.9.9.0" "$T_OUT"
assert_contains "status shows the pinned commit" "da99424e" "$T_OUT"
assert_contains "status shows the install origin" "source-build" "$T_OUT"
assert_contains "status reports the service running" "running" "$T_OUT"
assert_not_contains "status never prints the password" "$PASS_OK" "$T_OUT"

# Service-manager query errors are not proof that the proxy is inactive. Status
# must distinguish an unobservable active state instead of saying "not running".
s5env_reset_transcript
: >"$S5_TEST_ROOT/stub_active_query_fail"
t_run s5_cmd_status
assert_eq "status remains usable when service state cannot be queried" 0 "$T_STATUS"
assert_contains "status names the unverified service state" "not verified" "$T_OUT"
assert_not_contains "status does not call an unverified service inactive" "not running" "$T_OUT"
rm -f "$S5_TEST_ROOT/stub_active_query_fail"

# Install and restart diagnostics must preserve the same tri-state distinction as
# status/teardown: a manager query failure is not an observed inactive service.
: >"$S5_TEST_ROOT/stub_active_query_fail"
t_run s5_cmd_restart
assert_ne "restart fails when active state cannot be queried" 0 "$T_STATUS"
assert_contains "restart names an unverified active state" "could not verify" "$T_OUT"
assert_not_contains "restart does not mislabel a query error inactive" "not active" "$T_OUT"
rm -f "$S5_TEST_ROOT/stub_active_query_fail"

# OpenRC's stopped-service status is exit 3 (not exit 1). Treat that documented
# inactive result as definitely stopped; otherwise every OpenRC teardown retains
# all resources as if the service state were unobservable.
t_stub rc-service 3
S5_INIT=openrc
t_run s5_service_active
assert_eq "OpenRC exit 3 means definitely inactive" 1 "$T_STATUS"
S5_INIT=systemd

# v1 records no firewall ownership at all, and `status` therefore never queries a
# backend. The old recorded-ownership tri-state cases are gone with the keys.
s5env_reset_transcript
t_run s5_cmd_status
assert_eq "status remains usable with no firewall recorded" 0 "$T_STATUS"
assert_contains "status reports the firewall untouched" \
    "not modified by this script" "$T_OUT"
assert_not_contains "status does not call an unverified rule absent" "NO LONGER PRESENT" "$T_OUT"
t_assert_cmd_never_called "status queries no firewall backend" iptables ufw firewall-cmd
# The stub installed at the top of this file stays in place for the rest of the
# run. It is deliberately still a *mutating* stub even though nothing should call
# it: the "never called" assertions below can only observe a command that is
# stubbed, so removing it would make them pass vacuously.

# ==========================================================================
# show : root only, full credentials, terminal only
# ==========================================================================
# `show` is allowed to reveal the credential only on a real terminal. The unit
# harness captures stdout through a pipe, so redirected output must refuse rather
# than persist a plaintext password in a file or CI log.
s5env_reset_transcript
: >"$S5_LOGSINK"
S5_ASSUME_ROOT=1
t_run s5_cmd_show
assert_ne "show refuses when stdout is redirected" 0 "$T_STATUS"
assert_not_contains "redirected show output contains no password" "$PASS_OK" "$T_OUT"
assert_contains "redirected show explains the terminal requirement" \
    "terminal" "$T_OUT"
assert_not_contains "redirected show log diagnostic contains no password" "$PASS_OK" "$(cat "$S5_LOGSINK")"

S5_ASSUME_ROOT=0
t_run s5_cmd_show
assert_ne "show refuses for non-root" 0 "$T_STATUS"
assert_not_contains "non-root show leaks no password" "$PASS_OK" "$T_OUT"
S5_ASSUME_ROOT=1

# ==========================================================================
# Re-invocation hints. When the script arrives through the one-click form
# (bash <(wget -qO- URL)) $0 is a transient /dev/fd/* descriptor. Every
# message that tells the operator how to run a subcommand must either name a
# real path or point at re-running the installer -- never the descriptor.
# ==========================================================================
S5_SELF_SAVED=${S5_SELF:-}

S5_SELF=''
t_run s5_cmd_hint uninstall
assert_contains "piped mode points at re-running the installer" \
    "re-run the install command" "$T_OUT"
assert_contains "and names the subcommand to choose" "'uninstall'" "$T_OUT"
assert_not_contains "never the transient path" "/dev/fd" "$T_OUT"

t_run s5_redisplay_hint
assert_contains "the piped summary hint names the menu" "menu" "$T_OUT"
assert_not_contains "and never prints a descriptor" "/dev/fd" "$T_OUT"

S5_SELF=/root/socks5.sh
t_run s5_cmd_hint uninstall
assert_contains "file mode names the real path" "/root/socks5.sh uninstall" "$T_OUT"
t_run s5_redisplay_hint
assert_contains "file mode keeps the direct command" "/root/socks5.sh show" "$T_OUT"
S5_SELF=$S5_SELF_SAVED

# ==========================================================================
# restart
# ==========================================================================
s5env_reset_transcript
t_run s5_cmd_restart
assert_eq "restart exits 0" 0 "$T_STATUS"
t_assert_called "restart uses the service manager" 'systemctl restart'
t_assert_never_called "restart does not reinstall the unit" 'systemctl enable'
t_assert_never_called "restart does not rebuild" 'make -f'
assert_not_contains "restart never prints the password" "$PASS_OK" "$T_OUT"

# there is no reload and no reconfigure subcommand in v1
t_run env -u S5_LIB_ONLY sh "$S5_SRC" reload
assert_eq "reload is an unknown subcommand" 64 "$T_STATUS"
t_run env -u S5_LIB_ONLY sh "$S5_SRC" reconfigure
assert_eq "reconfigure is an unknown subcommand" 64 "$T_STATUS"

# ==========================================================================
# Restart must not report success until the port is listening again (fix-plan
# Task 7). A Type=simple unit is active the instant the process forks, so
# is-active after `systemctl restart` says nothing about the socket: restart
# used to log "restarted" and exit 0 while nothing was accepting connections
# -- the mirror image of the install-side race (test_install.sh). Same
# harness: svc_latebind hides the port for the first N observations while the
# service is already active (tests/lib/env.sh).
#
# sleep is shadowed for this block only: production polls at one-second
# granularity (fractional sleep is not POSIX), and the oracle here is the
# probe counter, not the clock. A function is used because it shadows PATH
# stubs and busybox applets alike -- the F26 lesson.
# ==========================================================================
sleep() { :; }

# The port never comes back: restart must fail, not claim success.
s5env_reset_transcript
: >"$S5_TEST_ROOT/port_probe_count"
printf '999\n' >"$S5_TEST_ROOT/svc_latebind"
t_run s5_cmd_restart
assert_ne "restart fails when the port never comes back" 0 "$T_STATUS"
assert_contains "restart names the port that never came back" "41080" "$T_OUT"
assert_contains "restart says how long it waited" "15" "$T_OUT"
assert_not_contains "restart does not claim a success it did not verify" \
    "restarted" "$T_OUT"
_rbc=$(cat "$S5_TEST_ROOT/port_probe_count")
assert_eq "restart waited the whole window before failing" 15 "$_rbc"
rm -f "$S5_TEST_ROOT/svc_latebind" "$S5_TEST_ROOT/svc_latebind_seen" \
    "$S5_TEST_ROOT/port_probe_count"

# The port comes back within the window: restart succeeds, and provably
# waited for it rather than trusting the manager's "active".
s5env_reset_transcript
: >"$S5_TEST_ROOT/port_probe_count"
printf '2\n' >"$S5_TEST_ROOT/svc_latebind"
t_run s5_cmd_restart
assert_eq "restart succeeds when the port rebinds within the window" 0 "$T_STATUS"
assert_contains "success is still reported when the wait verifies" "restarted" "$T_OUT"
_rbc=$(cat "$S5_TEST_ROOT/port_probe_count")
if [ -n "$_rbc" ] && [ "$_rbc" -ge 3 ]; then
    t_ok
else
    t_bad "restart must wait for the port, but probed only $_rbc times"
fi
rm -f "$S5_TEST_ROOT/svc_latebind" "$S5_TEST_ROOT/svc_latebind_seen" \
    "$S5_TEST_ROOT/port_probe_count"
unset -f sleep

# ==========================================================================
# no-argument menu
# ==========================================================================
s5env_reset_transcript
s5env_answers '1
'
t_run s5_cmd_auto <"$S5_TEST_ROOT/answers"
assert_eq "menu choice 1 runs status" 0 "$T_STATUS"
assert_contains "menu showed the options" "restart" "$T_OUT"
assert_contains "menu ran status" "41080" "$T_OUT"

s5env_answers '5
'
t_run s5_cmd_auto <"$S5_TEST_ROOT/answers"
assert_eq "menu quit exits 0" 0 "$T_STATUS"

s5env_answers '99
'
t_run s5_cmd_auto <"$S5_TEST_ROOT/answers"
assert_ne "invalid menu choice is rejected" 0 "$T_STATUS"

# ==========================================================================
# uninstall : removes only what this script created
# ==========================================================================
s5env_reset_transcript
: >"$S5_LOGSINK"
s5_state_load
recorded_bin=$S5_BIN
s5env_answers 'y
'
t_run s5_cmd_uninstall <"$S5_TEST_ROOT/answers"
assert_eq "uninstall exits 0" 0 "$T_STATUS"

# ours is gone
assert_file_absent "config removed" "$S5_CFG"
assert_file_absent "credentials removed" "$S5_USERSCFG"
assert_file_absent "config dir removed" "$S5_SYSCONFDIR"
assert_file_absent "binary removed" "$recorded_bin"
assert_file_absent "unit removed" "$S5_UNIT"
assert_file_absent "state removed" "$S5_STATE"

# the service was stopped and disabled
t_assert_called "service stopped" 'systemctl stop'
t_assert_called "service disabled" 'systemctl disable'

# the account we created is removed
t_assert_called "service account removed" 'userdel'
if s5_account_exists; then t_bad "account must be verifiably gone"; else t_ok; fi

# v1 created no firewall rule, so uninstall must not touch the firewall at all --
# in particular it must never delete a rule the administrator owns.
t_assert_never_called "uninstall deletes no iptables rule" 'iptables -D'
t_assert_never_called "uninstall deletes no ufw rule" 'ufw delete'
t_assert_never_called "uninstall removes no firewalld port" 'remove-port'
t_assert_never_called "never flushes iptables" 'iptables -F'
t_assert_never_called "never flushes a chain" '[-]X'
t_assert_never_called "never touches the sshd port rule" 'dport 22'

# nothing foreign was touched
assert_file_exists "foreign system 3proxy survives" "$S5_TEST_ROOT/usr/bin/3proxy"
assert_file_exists "foreign 3proxy config survives" "$S5_TEST_ROOT/etc/3proxy/3proxy.cfg"
assert_file_exists "unrelated config survives" "$S5_TEST_ROOT/etc/unrelated.conf"
assert_dir_exists "systemd unit directory itself survives" "$S5_UNITDIR"

# no system package is ever removed
t_assert_never_called "no apt removal" 'apt-get remove'
t_assert_never_called "no apt purge" 'apt-get purge'
t_assert_never_called "no apk del" 'apk del'
t_assert_never_called "no dnf remove" 'dnf remove'
assert_contains "uninstall states that packages were kept" "packages" "$T_OUT"
assert_not_contains "uninstall never prints the password" "$PASS_OK" "$T_OUT"
assert_not_contains "uninstall log sink has no password" "$PASS_OK" "$(cat "$S5_LOGSINK")"

# ==========================================================================
# uninstall is idempotent
# ==========================================================================
s5env_reset_transcript
s5env_answers 'y
'
t_run s5_cmd_uninstall <"$S5_TEST_ROOT/answers"
assert_eq "second uninstall exits 0" 0 "$T_STATUS"
assert_contains "second uninstall says there is nothing to remove" "nothing" "$T_OUT"
t_assert_never_called "second uninstall removes no account" 'userdel'
t_assert_never_called "second uninstall touches no firewall" 'iptables -D'

# status and show after uninstall
t_run s5_cmd_status
assert_ne "status reports not installed" 0 "$T_STATUS"
assert_contains "status says not installed" "not installed" "$T_OUT"
t_run s5_cmd_show
assert_ne "show reports not installed" 0 "$T_STATUS"
t_run s5_cmd_restart
assert_ne "restart reports not installed" 0 "$T_STATUS"

# a fresh install works after uninstall (no leftover collision)
s5env_reset_transcript
rm -f "$S5_TEST_ROOT/svc_active"
s5env_answers 'y
41081
seconduser
SecondPass_123~x
SecondPass_123~x
y
n
'
printf '%s:%s' seconduser 'SecondPass_123~x' >"$S5_TEST_ROOT/expected_creds"
t_run s5_cmd_install <"$S5_TEST_ROOT/answers"
assert_eq "reinstall after uninstall succeeds" 0 "$T_STATUS"
assert_eq "reinstall wrote fresh credentials" "seconduser:CL:SecondPass_123~x" "$(cat "$S5_USERSCFG")"
assert_eq "still exactly one credential line" 1 "$(grep -c '' "$S5_USERSCFG")"

# ==========================================================================
# OpenRC restart through the 0.53 transient. `rc-service <svc> restart` has
# the same shape as start on OpenRC 0.53 (Alpine 3.20) under
# supervise-daemon: it can exit nonzero after " * WARNING: <svc> is already
# starting" while the supervised service is mid-start and genuinely coming
# up. The restart path must classify the exit through the status re-query,
# not read it as a verdict, and then still verify the port came back --
# the mirror image of the install-side race proven in test_install.sh.
# This needs an OpenRC install, so the systemd one above is uninstalled and
# replaced for this final block.
# ==========================================================================
s5env_reset_transcript
s5env_answers 'y
'
t_run s5_cmd_uninstall <"$S5_TEST_ROOT/answers"
assert_eq "uninstall before the openrc restart test succeeds" 0 "$T_STATUS"

rm -rf "$S5_SYSCONFDIR" "$S5_STATEDIR" "$S5_PREFIX"
rm -f "$S5_UNIT" "$S5_INITSCRIPT" "$S5_TEST_ROOT/svc_active" \
    "$S5_TEST_ROOT/svc_latebind" "$S5_TEST_ROOT/svc_latebind_seen" \
    "$S5_TEST_ROOT/svc_start_transient"
# The exit-3 stub installed for the "OpenRC exit 3 means definitely inactive"
# check above replaced the real model stub for the rest of this file; this
# block needs the full one (start/restart/status state machine).
cp "${S5_REPO_ROOT}/tests/stubs/rc-service" "$S5_TEST_ROOT/bin/rc-service"
chmod 0755 "$S5_TEST_ROOT/bin/rc-service"
: >"$S5_TEST_ROOT/stub_passwd"
: >"$S5_TEST_ROOT/stub_group"
S5_OSRELEASE="${S5_REPO_ROOT}/tests/fixtures/os-release/alpine-3.20"
s5env_answers 'y
41082
alpruser
AlpPass_1234~x
AlpPass_1234~x
y
'
printf '%s:%s' alpruser 'AlpPass_1234~x' >"$S5_TEST_ROOT/expected_creds"
t_run s5_cmd_install <"$S5_TEST_ROOT/answers"
assert_eq "openrc install for the restart transient test succeeds" 0 "$T_STATUS"

s5env_reset_transcript
: >"$S5_TEST_ROOT/port_probe_count"
printf '2\n' >"$S5_TEST_ROOT/svc_latebind"
: >"$S5_TEST_ROOT/svc_start_transient"
t_run s5_cmd_restart
assert_eq "openrc restart succeeds through the transient already-starting refusal" 0 "$T_STATUS"
assert_contains "the transient warning really fired" "already starting" "$T_OUT"
assert_contains "success is still reported once the wait verifies" "restarted" "$T_OUT"
assert_not_contains "a transient restart is not reported as a failure" \
    "the service failed to restart" "$T_OUT"
_trwaited=$(cat "$S5_TEST_ROOT/port_probe_count")
if [ -n "$_trwaited" ] && [ "$_trwaited" -ge 3 ]; then
    t_ok
else
    t_bad "restart must still wait for the late port, but probed only $_trwaited times"
fi
S5_OSRELEASE="${S5_REPO_ROOT}/tests/fixtures/os-release/debian-12"
rm -f "$S5_TEST_ROOT/svc_latebind" "$S5_TEST_ROOT/svc_latebind_seen" \
    "$S5_TEST_ROOT/svc_start_transient" "$S5_TEST_ROOT/port_probe_count"

t_summary
