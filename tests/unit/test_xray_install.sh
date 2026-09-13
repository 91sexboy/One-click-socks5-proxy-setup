#!/bin/sh
# Xray installer and state validation with isolated lifecycle scenarios.

S5T_NAME=test_xray_install
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
. "${S5_REPO_ROOT}/tests/lib/xray-fixture.sh"

test_install() {
    t_xray_fixture 23456
    t_xray_install
    assert_file_exists "Xray config exists" "$S5_CFG"
    assert_file_exists "Xray state exists" "$S5_STATE"
    assert_file_exists "Xray unit exists" "$S5_SERVICE_ARTIFACT"
    assert_eq "state engine marker" xray "$(s5_state_get engine)"
    assert_eq "state protocol marker" mixed "$(s5_state_get protocol)"
    assert_eq "service command recorded" 1 "$(grep -c 'start xray-socks5.service' "$S5_TEST_ROOT/transcript")"
    assert_eq "install enables the unit on boot" 1 "$(grep -c 'enable xray-socks5.service' "$S5_TEST_ROOT/transcript")"
    assert_contains "config test ran before service start" 'config-test' "$(cat "$S5_TEST_ROOT/xray-calls")"
    assert_not_contains "password is absent from state" "$S5_PASSWORD" "$(cat "$S5_STATE")"
    assert_mode "config is group-readable only" 640 "$S5_CFG"
    assert_mode "state is private" 600 "$S5_STATE"

    # Old namespace remains untouched.
    mkdir -p "$S5_TEST_ROOT/etc/socks5-manager"
    printf legacy >"$S5_TEST_ROOT/etc/socks5-manager/3proxy.cfg"
    assert_file_exists "legacy namespace remains present" "$S5_TEST_ROOT/etc/socks5-manager/3proxy.cfg"
    unit=$(cat "$S5_SERVICE_ARTIFACT")
    assert_not_contains "unit does not expose password" "$S5_PASSWORD" "$unit"
    assert_contains "unit runs Xray" 'run -c' "$unit"
}

test_config_corrupt() {
    t_xray_fixture 23456
    t_xray_install
    # This return-2 assertion was already valid with the old binary metadata:
    # config verification precedes binary verification. The healthy baseline now
    # proves that changing the config is the only reason validation fails.
    printf 'external change\n' >"$S5_CFG"
    t_run s5_state_load
    assert_eq "an externally changed config has its own status" 2 "$T_STATUS"
    t_run s5_report_state_load 2
    assert_contains "the diagnosis names the config, not the state" \
        'changed externally' "$T_OUT"
    assert_not_contains "the diagnosis does not call the state invalid" \
        'invalid state file' "$T_OUT"
}

test_binary_corrupt() {
    t_xray_fixture 23456
    t_xray_install
    printf '# changed executable\n' >>"$S5_BIN"
    t_run s5_state_load
    assert_eq "a changed binary is invalid state, not config drift" 1 "$T_STATUS"
}

test_unit_corrupt() {
    t_xray_fixture 23456
    t_xray_install
    printf '# changed unit\n' >>"$S5_SERVICE_ARTIFACT"
    t_run s5_state_load
    assert_eq "a changed service unit is invalid state" 1 "$T_STATUS"
}

test_account_corrupt() {
    t_xray_fixture 23456
    t_xray_install
    printf '901\n' >"$S5_TEST_ROOT/user-exists"
    t_run s5_state_load
    assert_eq "a changed account identity is invalid state" 1 "$T_STATUS"
}

test_cleanup_temps() {
    t_xray_fixture 23456
    t_xray_install
    # An interrupted atomic write leaves private temporaries behind. This command
    # owns none of the published files from the previous installation process.
    : >"$S5_SYSCONFDIR/.s5tmp.abc123"
    : >"$S5_STATEDIR/.s5state.xyz789"
    : >"$S5_PREFIX/.xray.qqq111"
    s5_cleanup
    assert_file_absent "cleanup removes its own config temporary" "$S5_SYSCONFDIR/.s5tmp.abc123"
    assert_file_absent "cleanup removes its own state temporary" "$S5_STATEDIR/.s5state.xyz789"
    assert_file_absent "cleanup removes its own binary temporary" "$S5_PREFIX/.xray.qqq111"
    assert_file_exists "cleanup leaves the published config alone" "$S5_CFG"
    t_xray_assert_healthy

    # A matching dotfile in the caller's cwd must not expand the cleanup pattern
    # before it reaches the directory being cleaned.
    : >"$S5_SYSCONFDIR/.s5tmp.cwdcase"
    mkdir -p "$S5_TEST_ROOT/decoycwd"
    : >"$S5_TEST_ROOT/decoycwd/.s5tmp.decoy"
    ( cd "$S5_TEST_ROOT/decoycwd" && s5_cleanup_own_temps "$S5_SYSCONFDIR" )
    assert_file_absent "cleanup ignores a matching name in the caller's cwd" "$S5_SYSCONFDIR/.s5tmp.cwdcase"
}

test_openrc_runtime() {
    t_xray_fixture 23456
    # supervise-daemon runtime files belong to the running service until this
    # invocation actually touches it (e.g. declining an update must preserve them).
    S5_INIT=openrc
    mkdir -p "$S5_OPENRC_OPTION_DIR" "$(dirname "$S5_PIDFILE")"
    : >"$S5_PIDFILE"
    : >"$S5_OPENRC_OPTION_DIR/child_pid"
    s5_cleanup
    assert_file_exists "cleanup keeps a foreign OpenRC pidfile" "$S5_PIDFILE"
    assert_file_exists "cleanup keeps a foreign child_pid" "$S5_OPENRC_OPTION_DIR/child_pid"
    S5_SERVICE_STARTED=1
    s5_cleanup
    assert_file_absent "cleanup removes the runtime files it owns" "$S5_PIDFILE"
}

test_locks() {
    t_xray_fixture 23456
    _lkboot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || uname -n)
    # Call directly: t_run's command substitution would lose S5_LOCK_HELD.
    s5_lock_acquire
    assert_eq "the lock is acquired when free" 0 "$?"
    s5_lock_acquire
    assert_eq "acquiring a lock this process holds is a no-op" 0 "$?"
    s5_lock_release
    assert_file_absent "releasing removes the lock directory" "$S5_LOCKDIR"

    mkdir -p "$S5_LOCKDIR"
    printf '%s\n%s\n' "$_lkboot" "$$" >"$S5_LOCK_OWNER"
    s5_lock_acquire 2>/dev/null
    assert_ne "a lock held by a live owner is refused" 0 "$?"
    assert_file_exists "a live owner's lock is left in place" "$S5_LOCK_OWNER"

    (exit 0) &
    _lkdead=$!
    wait "$_lkdead" 2>/dev/null || true
    printf '%s\n%s\n' "$_lkboot" "$_lkdead" >"$S5_LOCK_OWNER"
    s5_lock_acquire 2>/dev/null
    assert_eq "a lock left by a dead owner is reclaimed" 0 "$?"
    s5_lock_release

    mkdir -p "$S5_LOCKDIR"
    printf '%s\n%s\n' "boot-from-a-previous-life" "$$" >"$S5_LOCK_OWNER"
    s5_lock_acquire 2>/dev/null
    assert_eq "a lock from a previous boot is reclaimed" 0 "$?"
    s5_lock_release
    assert_file_absent "the reclaimed lock is released cleanly" "$S5_LOCKDIR"
}

# Optional scenario arguments support isolated runs, permutation and repetition.
if [ "$#" -eq 0 ]; then
    set -- install config_corrupt binary_corrupt unit_corrupt account_corrupt cleanup_temps openrc_runtime locks
fi
for scenario do
    case "$scenario" in
    install|config_corrupt|binary_corrupt|unit_corrupt|account_corrupt|cleanup_temps|openrc_runtime|locks)
        "test_$scenario" ;;
    *) t_bad "unknown install scenario: $scenario" ;;
    esac
done
t_summary
