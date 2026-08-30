#!/bin/sh
# tests/unit/test_cleanup.sh - B3 regression: trap/cleanup semantics.
# The PTY half (real SIGINT, real terminal) lives in test_interrupt.sh.

S5T_NAME=test_cleanup
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
. "${S5_REPO_ROOT}/tests/lib/stub.sh"
. "${S5_REPO_ROOT}/tests/lib/env.sh"

s5env_setup
s5env_load

# ==========================================================================
# The traps must exist, cover all four events, and not be installed when the
# script is sourced as a library (which would hijack the test harness).
# ==========================================================================
for ev in EXIT HUP INT TERM; do
    if grep -q "trap .* $ev" "${S5_SRC}"; then
        t_ok
    else
        t_bad "no trap for $ev"
    fi
done
if grep -q 'set +x' "${S5_SRC}"; then t_ok; else t_bad "xtrace is not disabled"; fi
# Traps are installed inside the non-library branch ONLY -- a universal, so it
# must be checked as one. The earlier form took `tail -n 1` of the call sites and
# compared it to the library branch, which is satisfied by any call after the
# branch and cannot see an ADDITIONAL unconditional call earlier in the file.
# That matters: an unconditional s5_install_traps replaces `trap ... EXIT` in
# every shell that sources socks5.sh with S5_LIB_ONLY=1 -- i.e. the whole unit
# suite -- so t_mktestroot's cleanup is silently overwritten by s5_cleanup, which
# performs rollback deletions and `rm -rf` of the build workdir in the caller's
# shell. Verified by count, and by requiring the one call site to be the guarded
# one: every occurrence must be either the definition or a call after the branch.
libbranch=$(grep -n 'S5_LIB_ONLY:-0' "${S5_SRC}" | tail -n 1 | cut -d: -f1)
trapcalls=$(grep -c '^[[:space:]]*s5_install_traps[[:space:]]*$' "${S5_SRC}" || true)
assert_eq "s5_install_traps is called exactly once" 1 "$trapcalls"
trapinstall=$(grep -n '^[[:space:]]*s5_install_traps[[:space:]]*$' "${S5_SRC}" | tail -n 1 | cut -d: -f1)
if [ -n "$trapinstall" ] && [ "$trapinstall" -gt "$libbranch" ]; then
    t_ok
else
    t_bad "traps must only be installed when running as a script, not when sourced"
fi
# ...and the property that actually matters, observed rather than inferred:
# sourcing socks5.sh in library mode must leave this shell's EXIT trap alone.
# `trap -p EXIT` is not POSIX, so the whole trap listing is inspected -- and it
# is redirected to a file rather than captured with $(trap), because command
# substitution forks a subshell and POSIX resets traps there, so $(trap) reports
# nothing at all and every assertion built on it would be vacuous.
trap >"$S5_TEST_ROOT/traplist"
trapbefore=$(cat "$S5_TEST_ROOT/traplist")
if printf '%s\n' "$trapbefore" | grep -q 's5_cleanup'; then
    t_bad "sourcing socks5.sh in library mode installed s5_cleanup as an EXIT trap"
else
    t_ok
fi
assert_contains "the harness's own cleanup trap is still in place" \
    "t_cleanup_root" "$trapbefore"

# ==========================================================================
# Password input is intentionally visible and must not alter terminal state.
# ==========================================================================
if grep -qE 'stty|S5_TERM_STATE|S5_TERM_MODIFIED|s5_term_restore' "${S5_SRC}"; then
    t_bad "visible password input must not manipulate terminal echo"
else
    t_ok
fi

# ==========================================================================
# The build directory is always removed, and only if it looks like ours.
# ==========================================================================
mkdir -p "$S5_TEST_ROOT/build"
wd=$(mktemp -d "$S5_TEST_ROOT/build/b.XXXXXX")
printf 'x\n' >"$wd/file"
S5_WORKDIR=$wd
S5_ROLLBACK_ARMED=0
S5_INSTALL_COMPLETE=0
s5_cleanup >/dev/null 2>&1
rc=$?
assert_eq "cleanup succeeds" 0 "$rc"
assert_file_absent "the build directory was removed" "$wd"
assert_eq "cleanup cleared the workdir variable" "" "$S5_WORKDIR"

# A failed recursive removal must remain observable: clearing S5_WORKDIR would
# falsely report cleanup while abandoning a source tree that may hold build
# output or copied source. The function shadow fails only this workdir removal.
wd_fail=$(mktemp -d "$S5_TEST_ROOT/build/b.XXXXXX")
printf 'x\n' >"$wd_fail/file"
rm() {
    if [ "$1" = "-rf" ] && [ "$2" = "$wd_fail" ]; then
        return 1
    fi
    command rm "$@"
}
S5_WORKDIR=$wd_fail
S5_ROLLBACK_ARMED=0
S5_INSTALL_COMPLETE=0
S5_IN_CLEANUP=0
t_run s5_cleanup
unset -f rm
assert_ne "cleanup reports a build-directory removal failure" 0 "$T_STATUS"
assert_dir_exists "failed cleanup leaves the workdir visible for retry" "$wd_fail"
assert_eq "failed cleanup retains workdir ownership" "$wd_fail" "$S5_WORKDIR"
rm -rf "$wd_fail"
S5_WORKDIR=''

# a foreign directory is refused, not deleted
foreign="$S5_TEST_ROOT/not-a-build-dir"
mkdir -p "$foreign"
S5_WORKDIR=$foreign
S5_IN_CLEANUP=0
t_run s5_cleanup
assert_dir_exists "a non-build directory is never removed" "$foreign"
assert_contains "and the refusal is reported" "refusing to remove" "$T_OUT"

# ==========================================================================
# Rollback fires only for an incomplete, armed install.
# ==========================================================================
setup_partial_install() {
    rm -rf "$S5_SYSCONFDIR" "$S5_STATEDIR" "$S5_PREFIX"
    mkdir -p "$S5_SYSCONFDIR" "$S5_PREFIX" "$S5_STATEDIR"
    printf 'cfg\n' >"$S5_CFG"
    printf 'u:CL:p\n' >"$S5_USERSCFG"
    printf 'bin\n' >"$S5_BIN"
    printf 'port\t31080\ninit\tsystemd\nfamily\tdebian\ncreated_confdir\t1\ncreated_cfg\t1\ncreated_users\t1\ncreated_prefix\t1\ncreated_bin\t1\n' >"$S5_STATE"
    chmod 0600 "$S5_STATE"
}

setup_partial_install
S5_WORKDIR=''
S5_ROLLBACK_ARMED=1
S5_INSTALL_COMPLETE=0
S5_IN_CLEANUP=0
t_run s5_cleanup
assert_file_absent "incomplete install: config rolled back" "$S5_CFG"
assert_file_absent "incomplete install: credentials rolled back" "$S5_USERSCFG"
assert_file_absent "incomplete install: binary rolled back" "$S5_BIN"
assert_file_absent "incomplete install: config dir rolled back" "$S5_SYSCONFDIR"
assert_file_absent "incomplete install: state removed" "$S5_STATE"

# a COMPLETED install must survive the normal EXIT trap
setup_partial_install
printf 'status\tcomplete\n' >>"$S5_STATE"
S5_ROLLBACK_ARMED=0
S5_INSTALL_COMPLETE=1
S5_IN_CLEANUP=0
t_run s5_cleanup
assert_file_exists "completed install: config kept" "$S5_CFG"
assert_file_exists "completed install: credentials kept" "$S5_USERSCFG"
assert_file_exists "completed install: binary kept" "$S5_BIN"
assert_file_exists "completed install: state kept" "$S5_STATE"

# armed but already complete: still no rollback
setup_partial_install
printf 'status\tcomplete\n' >>"$S5_STATE"
S5_ROLLBACK_ARMED=1
S5_INSTALL_COMPLETE=1
S5_IN_CLEANUP=0
t_run s5_cleanup
assert_file_exists "complete beats armed: config kept" "$S5_CFG"

# ==========================================================================
# Cleanup is idempotent and does not recurse.
# ==========================================================================
setup_partial_install
S5_ROLLBACK_ARMED=1
S5_INSTALL_COMPLETE=0
S5_IN_CLEANUP=0
s5_cleanup >/dev/null 2>&1
first=$?
S5_IN_CLEANUP=0
t_run s5_cleanup
assert_eq "first cleanup returned 0" 0 "$first"
assert_eq "a second cleanup is harmless" 0 "$T_STATUS"

# Teardown must fail closed if the service manager cannot stop or disable the
# proxy, rather than deleting its resources under a still-running process.
setup_partial_install
s5_state_load >/dev/null 2>&1
S5_INIT=systemd
S5_STATE_LOADED=1
S5_STATE_BUF="port	31080
init	systemd
family	debian
created_confdir	1
created_cfg	1
created_users	1
created_prefix	1
created_bin	1
created_unit	1"
mkdir -p "$S5_UNITDIR"
: >"$S5_UNIT"
: >"$S5_TEST_ROOT/svc_active"
: >"$S5_TEST_ROOT/stub_stop_fail"
S5_ROLLBACK_ARMED=0
S5_INSTALL_COMPLETE=0
S5_IN_CLEANUP=0
t_run s5_teardown
assert_ne "teardown reports a failed service stop" 0 "$T_STATUS"
assert_file_exists "failed-stop teardown keeps the config" "$S5_CFG"
rm -f "$S5_TEST_ROOT/stub_stop_fail" "$S5_TEST_ROOT/svc_active"

setup_partial_install
s5_state_load >/dev/null 2>&1
S5_INIT=systemd
S5_STATE_LOADED=1
S5_STATE_BUF="port	31080
init	systemd
family	debian
created_confdir	1
created_cfg	1
created_users	1
created_prefix	1
created_bin	1
created_unit	1"
mkdir -p "$S5_UNITDIR"
: >"$S5_UNIT"
: >"$S5_TEST_ROOT/stub_disable_fail"
S5_ROLLBACK_ARMED=0
S5_INSTALL_COMPLETE=0
S5_IN_CLEANUP=0
t_run s5_teardown
assert_ne "teardown reports a failed service disable" 0 "$T_STATUS"
assert_file_exists "failed-disable teardown keeps the config" "$S5_CFG"
rm -f "$S5_TEST_ROOT/stub_disable_fail"

# ==========================================================================
# The rollback deadlock. created_unit is recorded BEFORE the unit file is
# written, so a failed write (read-only /etc/systemd/system, no space) leaves
# the flag with no file. A manager that refuses stop and disable for a unit it
# never loaded used to make teardown return before removing the config,
# credentials, binary and account -- and retrying uninstall repeated the same
# unsatisfiable stop forever. With the unit file absent the failed stop and
# disable are no-ops; the is-active check stays the authority on liveness.
# ==========================================================================
setup_partial_install
printf 'u:CL:p\n' >"$S5_TEST_ROOT/stub_passwd.new"
: >"$S5_TEST_ROOT/stub_group"
s5_account_create >/dev/null 2>&1
printf 'tag\t0.9.9.0\ncommit\tda99424eac4092e3722f1a5b1844cfe80478f580\norigin\tsource-build\nport\t31080\nusername\tcleanuser\nos\tdebian-12\nfamily\tdebian\narch\tamd64\ninit\tsystemd\nlisten\t0.0.0.0\naccount_uid\t900\naccount_gid\t900\ncreated_account\t1\ncreated_group\t1\ncreated_confdir\t1\ncreated_cfg\t1\ncreated_users\t1\ncreated_prefix\t1\ncreated_bin\t1\ncreated_unit\t1\n' >"$S5_STATE"
chmod 0600 "$S5_STATE"
s5_state_load >/dev/null 2>&1
S5_INIT=systemd
S5_ROLLBACK_ARMED=0
S5_INSTALL_COMPLETE=0
S5_IN_CLEANUP=0
t_run s5_teardown
assert_eq "teardown completes for a never-written unit file" 0 "$T_STATUS"
assert_file_absent "config removed despite the absent unit" "$S5_CFG"
assert_file_absent "credentials removed despite the absent unit" "$S5_USERSCFG"
assert_file_absent "binary removed despite the absent unit" "$S5_BIN"
if s5_account_exists; then t_bad "account removed despite the absent unit"; else t_ok; fi

# OpenRC variant: the same tolerance for a never-written init script, where
# rc-service and rc-update refuse the unknown service name.
setup_partial_install
s5_account_create >/dev/null 2>&1
printf 'tag\t0.9.9.0\ncommit\tda99424eac4092e3722f1a5b1844cfe80478f580\norigin\tsource-build\nport\t31080\nusername\tcleanuser\nos\talpine-3.24\nfamily\talpine\narch\tamd64\ninit\topenrc\nlisten\t0.0.0.0\naccount_uid\t900\naccount_gid\t900\ncreated_account\t1\ncreated_group\t1\ncreated_confdir\t1\ncreated_cfg\t1\ncreated_users\t1\ncreated_prefix\t1\ncreated_bin\t1\ncreated_initscript\t1\n' >"$S5_STATE"
chmod 0600 "$S5_STATE"
s5_state_load >/dev/null 2>&1
S5_INIT=openrc
S5_OS_FAMILY=alpine
t_stub_script rc-service 'if [ ! -f "$S5_INITSCRIPT" ]; then exit 1; fi; exit 0'
t_stub_script rc-update 'if [ ! -f "$S5_INITSCRIPT" ]; then exit 1; fi; exit 0'
S5_ROLLBACK_ARMED=0
S5_INSTALL_COMPLETE=0
S5_IN_CLEANUP=0
t_run s5_teardown
assert_eq "openrc teardown completes for a never-written init script" 0 "$T_STATUS"
assert_file_absent "config removed despite the absent init script" "$S5_CFG"
if s5_account_exists; then t_bad "account removed despite the absent init script"; else t_ok; fi
# restore the optimistic stubs for any later case
t_stub rc-service 0
t_stub rc-update 0

# An active-state query error is not proof that the service stopped. Teardown
# must retain the files and state so an operator can retry safely.
setup_partial_install
s5_state_load >/dev/null 2>&1
S5_INIT=systemd
S5_STATE_LOADED=1
S5_STATE_BUF="port	31080
init	systemd
family	debian
created_confdir	1
created_cfg	1
created_users	1
created_prefix	1
created_bin	1
created_unit	1"
mkdir -p "$S5_UNITDIR"
: >"$S5_UNIT"
: >"$S5_TEST_ROOT/stub_active_query_fail"
S5_ROLLBACK_ARMED=0
S5_INSTALL_COMPLETE=0
S5_IN_CLEANUP=0
t_run s5_teardown
assert_ne "teardown reports an unobservable service state" 0 "$T_STATUS"
assert_file_exists "query failure keeps the config" "$S5_CFG"
rm -f "$S5_TEST_ROOT/stub_active_query_fail"

# Teardown ownership comes from recorded lifecycle state, not from whether the
# unit file still exists. A manually removed unit must not let a running service
# survive while its config and credentials are deleted.
setup_partial_install
s5_state_load >/dev/null 2>&1
S5_INIT=systemd
S5_STATE_LOADED=1
S5_STATE_BUF="port	31080
init	systemd
family	debian
created_confdir	1
created_cfg	1
created_users	1
created_prefix	1
created_bin	1
created_unit	1"
rm -f "$S5_UNIT"
: >"$S5_TEST_ROOT/svc_active"
: >"$S5_TEST_ROOT/stub_stop_fail"
S5_ROLLBACK_ARMED=0
S5_INSTALL_COMPLETE=0
S5_IN_CLEANUP=0
t_run s5_teardown
assert_ne "missing unit does not skip service stop verification" 0 "$T_STATUS"
assert_file_exists "missing-unit teardown keeps the config" "$S5_CFG"
rm -f "$S5_TEST_ROOT/stub_stop_fail" "$S5_TEST_ROOT/svc_active"

# Removing a systemd unit file is not enough: the manager must successfully
# reload its unit cache before the state can be discarded. A failed final reload
# leaves teardown retryable and must be reported.
setup_partial_install
s5_state_load >/dev/null 2>&1
S5_INIT=systemd
S5_STATE_LOADED=1
S5_STATE_BUF="port	31080
init	systemd
family	debian
created_confdir	1
created_cfg	1
created_users	1
created_prefix	1
created_bin	1
created_unit	1"
mkdir -p "$S5_UNITDIR"
: >"$S5_UNIT"
: >"$S5_TEST_ROOT/stub_daemon_reload_fail"
S5_ROLLBACK_ARMED=0
S5_INSTALL_COMPLETE=0
S5_IN_CLEANUP=0
t_run s5_teardown
assert_ne "teardown reports a failed final daemon reload" 0 "$T_STATUS"
assert_contains "reload failure is actionable during teardown" \
    "reload the systemd manager" "$T_OUT"
assert_file_absent "teardown still removes the owned unit file" "$S5_UNIT"
assert_file_exists "reload failure keeps state for retry" "$S5_STATE"
rm -f "$S5_TEST_ROOT/stub_daemon_reload_fail"

# a re-entrant call while already cleaning up is a no-op
S5_IN_CLEANUP=1
S5_ROLLBACK_ARMED=1
S5_INSTALL_COMPLETE=0
setup_partial_install
t_run s5_cleanup
assert_file_exists "re-entrant cleanup does nothing" "$S5_CFG"
S5_IN_CLEANUP=0

# ==========================================================================
# Signal handlers exit with 128+signal.
# ==========================================================================
if grep -q "s5_on_signal HUP 129" "${S5_SRC}"; then t_ok; else t_bad "HUP must exit 129"; fi
if grep -q "s5_on_signal INT 130" "${S5_SRC}"; then t_ok; else t_bad "INT must exit 130"; fi
if grep -q "s5_on_signal TERM 143" "${S5_SRC}"; then t_ok; else t_bad "TERM must exit 143"; fi

t_summary
