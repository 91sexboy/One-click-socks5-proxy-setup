#!/bin/sh
# Xray installer and state validation with isolated lifecycle scenarios.

S5T_NAME=test_xray_install
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
. "${S5_REPO_ROOT}/tests/lib/xray-fixture.sh"

test_install() {
    t_xray_fixture 23456
    t_legacy_fixture
    t_xray_install
    assert_eq "install preserves the legacy config" 'legacy config' "$(cat "$S5_TEST_ROOT/etc/socks5-manager/3proxy.cfg")"
    assert_eq "install preserves the legacy state" 'legacy state' "$(cat "$S5_TEST_ROOT/var/lib/socks5-manager/state")"
    assert_eq "install preserves the legacy binary" 'legacy binary' "$(cat "$S5_TEST_ROOT/usr/local/libexec/socks5-manager/3proxy")"
    assert_file_exists "Xray config exists" "$S5_CFG"
    assert_file_exists "Xray state exists" "$S5_STATE"
    assert_file_exists "Xray unit exists" "$S5_SERVICE_ARTIFACT"
    assert_eq "state engine marker" xray "$(t_state_get engine)"
    assert_eq "state protocol marker" mixed "$(t_state_get protocol)"
    assert_eq "service command recorded" 1 "$(grep -c 'start xray-socks5.service' "$S5_TEST_ROOT/transcript")"
    assert_eq "install enables the unit on boot" 1 "$(grep -c 'enable xray-socks5.service' "$S5_TEST_ROOT/transcript")"
    assert_contains "config test ran before service start" 'config-test' "$(cat "$S5_TEST_ROOT/xray-calls")"
    assert_not_contains "password is absent from state" "$S5_PASSWORD" "$(cat "$S5_STATE")"
    assert_mode "config is group-readable only" 640 "$S5_CFG"
    assert_mode "state is private" 600 "$S5_STATE"

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
    : >"$S5_STATEDIR/.s5tmp.xyz789"
    # A binary candidate is removed only when this run registered it. Another
    # run's .xray.* in an existing prefix is kept and named: failure cleanup
    # does not sweep files it cannot prove it created.
    : >"$S5_PREFIX/.xray.qqq111"
    : >"$S5_PREFIX/.xray.own222"
    S5_BINARY_TEMP=$S5_PREFIX/.xray.own222
    s5_cleanup 2>"$S5_TEST_ROOT/cleanup-temps.err"
    assert_file_absent "cleanup removes its own config temporary" "$S5_SYSCONFDIR/.s5tmp.abc123"
    assert_file_absent "cleanup removes its own state temporary" "$S5_STATEDIR/.s5tmp.xyz789"
    assert_file_absent "cleanup removes its registered binary temporary" "$S5_PREFIX/.xray.own222"
    assert_file_exists "cleanup keeps another run's binary temporary" "$S5_PREFIX/.xray.qqq111"
    assert_contains "cleanup names the binary temporary it kept" \
        "[!] kept a temporary file this run did not create: $S5_PREFIX/.xray.qqq111" \
        "$(cat "$S5_TEST_ROOT/cleanup-temps.err")"
    rm -f "$S5_PREFIX/.xray.qqq111"
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

test_openrc_logging_warning() {
    t_xray_fixture 23456
    S5_INIT=openrc
    S5_OS_FAMILY=alpine
    s5_select_service_artifact
    s5_precheck_host() { return 0; }; s5_precheck_tools() { return 0; }
    t_stub rc-service <<'RCSERVICE'
#!/bin/sh
exec "$S5_TEST_ROOT/bin/systemctl" "$2"
RCSERVICE
    t_stub rc-update <<'RCUPDATE'
#!/bin/sh
exec "$S5_TEST_ROOT/bin/systemctl" "$1"
RCUPDATE

    t_run s5_cmd_install
    assert_eq "OpenRC install succeeds without a syslog endpoint" 0 "$T_STATUS"
    assert_contains "OpenRC install warns when /dev/log is absent" \
        '/dev/log' "$T_OUT"
    assert_eq "OpenRC install emits the missing-syslog warning once" 1 \
        "$(printf '%s\n' "$T_OUT" | grep -c '/dev/log')"
    assert_file_absent "the logging warning is issued after releasing the lock" \
        "$S5_LOCKDIR"

    t_xray_fixture 23456
    S5_INIT=openrc
    S5_OS_FAMILY=alpine
    s5_select_service_artifact
    s5_precheck_host() { return 0; }; s5_precheck_tools() { return 0; }
    mkdir -p "$S5_ROOTDIR/dev"
    : >"$S5_ROOTDIR/dev/log"
    t_stub rc-service <<'RCSERVICE'
#!/bin/sh
exec "$S5_TEST_ROOT/bin/systemctl" "$2"
RCSERVICE
    t_stub rc-update <<'RCUPDATE'
#!/bin/sh
exec "$S5_TEST_ROOT/bin/systemctl" "$1"
RCUPDATE
    t_run s5_cmd_install
    assert_eq "OpenRC install succeeds with /dev/log present" 0 "$T_STATUS"
    assert_not_contains "OpenRC install does not warn when /dev/log exists" \
        '/dev/log' "$T_OUT"

    t_xray_fixture 23456
    s5_precheck_host() { return 0; }; s5_precheck_tools() { return 0; }
    t_run s5_cmd_install
    assert_eq "systemd install succeeds without /dev/log" 0 "$T_STATUS"
    assert_not_contains "systemd install never emits the OpenRC logging warning" \
        '/dev/log' "$T_OUT"
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
    assert_file_absent "releasing removes the lock directory" "${S5_LOCKDIR:?}"

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

s5t_raw_command_fixture() {
    t_xray_fixture 23456 real-download
    S5_TEST_ASSET_PATH=$S5_TEST_ROOT/asset-xray
    export S5_TEST_ASSET_PATH
    s5_file_type_command() {
        printf '%s\n' 'ELF 64-bit LSB executable, x86-64, statically linked'
    }
    s5_precheck_host() { return 0; }; s5_precheck_tools() { return 0; }
}

s5t_raw_command_run() {
    _tdfault=${1:-none}
    case "$_tdfault" in candidate) printf '23\n' >"$S5_TEST_ROOT/cfgtest" ;; esac
    rmdir() {
        if [ "$_tdfault" = release ] && [ "${1:-}" = "$S5_LOCKDIR" ]; then
            printf 'release failed\n' >>"$S5_TEST_ROOT/download.release"
            return 1
        fi
        command rmdir "$@"
    }
    chmod() {
        if [ "$_tdfault" = signal ] && [ "${1:-}:${2:-}" = "0750:$S5_SYSCONFDIR" ]; then
            python3 -c 'import os, signal; os.kill(os.getppid(), signal.SIGTERM)'
            return 1
        fi
        command chmod "$@"
    }
    s5_cmd_install
    _tdstatus=$?
    return "$_tdstatus"
}

test_raw_command_cleanup() {
    s5t_raw_command_fixture
    t_run s5t_raw_command_run
    assert_eq "command-level installation with verified raw asset succeeds" 0 "$T_STATUS"
    assert_file_exists "successful raw install preserves binary" "$S5_BIN"
    assert_file_exists "successful raw install preserves config" "$S5_CFG"
    assert_file_exists "successful raw install preserves state" "$S5_STATE"
    assert_eq "successful raw install writes schema 2" 2 "$(t_state_get schema)"
    assert_eq "successful raw install leaves no prefix candidate" 0 \
        "$(find "$S5_PREFIX" -maxdepth 1 -type f -name '.xray.*' | wc -l | tr -d '[:space:]')"
    assert_file_absent "successful raw install releases operation lock" "$S5_LOCKDIR"
    assert_not_contains "command output contains no password" "$S5_PASSWORD" "$T_OUT"
    t_xray_assert_healthy
    t_run s5t_raw_command_run
    assert_eq "configuration-only update without binary staging succeeds" 0 "$T_STATUS"
    t_xray_assert_healthy
}

s5t_raw_fault_case() {
    _tdcase=$1
    s5t_raw_command_fixture
    t_run s5t_raw_command_run "$_tdcase"
    case "$_tdcase" in
    signal) assert_eq "raw-stage signal propagates its signal status" 143 "$T_STATUS" ;;
    *) assert_eq "$_tdcase failure remains nonzero" 1 "$T_STATUS" ;;
    esac
    case "$_tdcase" in
    release)
        assert_dir_exists "failed lock release remains observable" "$S5_LOCKDIR"
        assert_contains "the lock release failure was reached" 'release failed' \
            "$(cat "$S5_TEST_ROOT/download.release")"
        ;;
    *) assert_file_absent "$_tdcase releases its operation lock" "$S5_LOCKDIR" ;;
    esac
    assert_not_contains "$_tdcase never announces English success" 'installation completed' "$T_OUT"
    assert_not_contains "$_tdcase never announces Chinese success" '安装完成' "$T_OUT"
    assert_not_contains "$_tdcase output contains no password" "$S5_PASSWORD" "$T_OUT"
    case "$_tdcase" in
    candidate|signal)
        assert_file_absent "$_tdcase removes failed fresh binary" "$S5_BIN"
        assert_file_absent "$_tdcase leaves no installed state" "$S5_STATE"
        assert_file_absent "$_tdcase removes the fresh prefix" "$S5_PREFIX"
        ;;
    *)
        assert_eq "$_tdcase leaves healthy listener running" 23456 \
            "$(cat "$S5_TEST_ROOT/svc_active")"
        t_xray_assert_healthy
        ;;
    esac
}

test_raw_release_failure() { s5t_raw_fault_case release; }
test_raw_candidate_failure() { s5t_raw_fault_case candidate; }
test_raw_signal() { s5t_raw_fault_case signal; }

test_fresh_stage_failure_cleanup() {
    t_xray_fixture 23456 real-download
    s5_stage_engine() {
        S5_BINARY_TEMP=$(mktemp "$S5_PREFIX/.xray.XXXXXX") || return 1
        printf 'partial xray\n' >"$S5_BINARY_TEMP"
        printf 'stage write failed\n' >&2
        return 74
    }
    chmod() {
        if [ "${1:-}:${2:-}" = "0755:$S5_PREFIX" ]; then
            printf 'unexpected prefix restore\n' >>"$S5_TEST_ROOT/fresh-stage.events"
            return 75
        fi
        command chmod "$@"
    }
    T_OUT=$( (
        s5_download_engine
        _fsfc_status=$?
        s5_cleanup
        exit "$_fsfc_status"
    ) 2>&1) && T_STATUS=0 || T_STATUS=$?
    assert_ne "fresh staging failure aborts installation" 0 "$T_STATUS"
    assert_contains "fresh staging retains original diagnosis" 'stage write failed' "$T_OUT"
    assert_not_contains "fresh staging does not restore disposable prefix" \
        'unexpected prefix restore' "$(cat "$S5_TEST_ROOT/fresh-stage.events" 2>/dev/null)"
    assert_file_absent "fresh staging cleanup removes newly created prefix" "$S5_PREFIX"
    assert_file_absent "fresh staging failure publishes no binary" "$S5_BIN"
    assert_file_absent "fresh staging failure publishes no state" "$S5_STATE"
    unset -f chmod s5_stage_engine
}


test_account_creation_failure() {
    for _acfamily in debian alpine; do
        for _acfailure in 0 1; do
            t_xray_fixture 23456
            S5_OS_FAMILY=$_acfamily
            : >"$S5_TEST_ROOT/fail-useradd"
            if [ "$_acfailure" = 1 ]; then : >"$S5_TEST_ROOT/fail-groupdel"; fi
            s5_account_create >"$S5_TEST_ROOT/account.log" 2>&1
            assert_eq "$_acfamily rejects failed account creation" 1 "$?"
            assert_eq "$_acfamily records no uncreated user" 0 "$S5_CREATED_USER"
            assert_eq "$_acfamily retains group ownership only while cleanup is incomplete" "$_acfailure" "$S5_CREATED_GROUP"
            case "$_acfamily" in
            debian) _actranscript='groupadd -r xray-socks5
useradd -r -g xray-socks5 -M -d /nonexistent -s /usr/sbin/nologin xray-socks5
groupdel xray-socks5' ;;
            alpine) _actranscript='addgroup -S xray-socks5
adduser -S -D -H -h /nonexistent -G xray-socks5 -s /sbin/nologin xray-socks5
delgroup xray-socks5' ;;
            esac
            assert_eq "$_acfamily failure preserves account command ordering and arguments" \
                "$_actranscript" "$(cat "$S5_TEST_ROOT/account-transcript")"
            if [ "$_acfailure" = 1 ]; then
                assert_file_exists "$_acfamily failed cleanup leaves its owned group" "$S5_TEST_ROOT/group-exists"
                rm "$S5_TEST_ROOT/fail-groupdel"
                s5_cleanup
                assert_file_absent "$_acfamily cleanup retries the owned group" "$S5_TEST_ROOT/group-exists"
            else
                assert_file_absent "$_acfamily successful cleanup removes its group" "$S5_TEST_ROOT/group-exists"
            fi
        done
    done
}

test_account_lifecycle() {
    for _acfamily in debian alpine; do
        t_xray_fixture 23456
        S5_OS_FAMILY=$_acfamily
        s5_account_create
        assert_eq "$_acfamily creates its dedicated account" 0 "$?"
        assert_eq "$_acfamily records the created user" 1 "$S5_CREATED_USER"
        assert_eq "$_acfamily records the created group" 1 "$S5_CREATED_GROUP"
        s5_account_remove
        assert_eq "$_acfamily removes its dedicated account" 0 "$?"
        assert_eq "$_acfamily clears user ownership after removal" 0 "$S5_CREATED_USER"
        assert_eq "$_acfamily clears group ownership after removal" 0 "$S5_CREATED_GROUP"
        case "$_acfamily" in
        debian) _actranscript='groupadd -r xray-socks5
useradd -r -g xray-socks5 -M -d /nonexistent -s /usr/sbin/nologin xray-socks5
userdel xray-socks5
groupdel xray-socks5' ;;
        alpine) _actranscript='addgroup -S xray-socks5
adduser -S -D -H -h /nonexistent -G xray-socks5 -s /sbin/nologin xray-socks5
deluser xray-socks5
delgroup xray-socks5' ;;
        esac
        assert_eq "$_acfamily lifecycle preserves account command ordering and arguments" \
            "$_actranscript" "$(cat "$S5_TEST_ROOT/account-transcript")"
    done
}

s5t_cleanup_run() {
    s5_precheck_host() { return 0; }; s5_precheck_tools() { return 0; }
    sleep() { :; }
    s5_verify_dataplane() {
        : >"$S5_TEST_ROOT/verification-failed"
        return 1
    }
    S5T_CLEANUP_FAULT=$1
    export S5T_CLEANUP_FAULT S5_INIT S5_PIDFILE S5_OPENRC_OPTION_DIR
    export S5_LOCK_HELD S5_LOCK_OWNER S5_LOCK_TOKEN
    t_stub systemctl <<'MANAGER'
#!/bin/sh
printf '%s\n' "$1" >>"$S5_TEST_ROOT/manager-calls"
case "$1" in
start)
    printf '23456\n' >"$S5_TEST_ROOT/svc_active"
    if [ "$S5_INIT" = openrc ]; then
        mkdir -p "$S5_OPENRC_OPTION_DIR"
        printf '100\n' >"$S5_PIDFILE"
        printf '101\n' >"$S5_OPENRC_OPTION_DIR/child_pid"
    fi
    [ "$S5T_CLEANUP_FAULT" != start-failure ] || exit 1
    ;;
stop)
    : >"$S5_TEST_ROOT/stop-attempted"
    if [ "$S5_LOCK_HELD" = 1 ] && [ "$(cat "$S5_LOCK_OWNER")" = "$S5_LOCK_TOKEN" ]; then
        : >"$S5_TEST_ROOT/stop-under-lock"
    fi
    case "$S5T_CLEANUP_FAULT" in
    stop-failure|start-failure) exit 1 ;;
    stopped) rm -f "$S5_TEST_ROOT/svc_active" ;;
    esac
    ;;
is-active|status)
    if [ "$S5T_CLEANUP_FAULT" = start-failure ] ||
        { [ "$S5T_CLEANUP_FAULT" = unknown ] && [ -f "$S5_TEST_ROOT/stop-attempted" ]; }; then
        exit 4
    fi
    [ -f "$S5_TEST_ROOT/svc_active" ] && { printf 'active\n'; exit 0; }
    printf 'inactive\n'
    exit 3
    ;;
esac
exit 0
MANAGER
    t_stub rc-service <<'RCSERVICE'
#!/bin/sh
exec "$S5_TEST_ROOT/bin/systemctl" "$2"
RCSERVICE
    t_stub rc-update <<'RCUPDATE'
#!/bin/sh
exec "$S5_TEST_ROOT/bin/systemctl" "$1"
RCUPDATE
    S5_VERIFY_TEMP=$S5_TEST_ROOT/verify-temp
    printf '%s\n' "$S5_PASSWORD" >"$S5_VERIFY_TEMP"
    chmod 0600 "$S5_VERIFY_TEMP"
    s5_cmd_install
    _scrstatus=$?
    printf '%s\n' "$S5_SERVICE_STARTED" >"$S5_TEST_ROOT/service-owned"
    return "$_scrstatus"
}

test_cleanup_stop_failure() {
    for _csbackend in systemd openrc; do
        for _csfault in stop-failure active unknown start-failure stopped; do
            for _cslang in en zh; do
                t_xray_fixture 23456
                S5_INIT=$_csbackend
                if [ "$S5_INIT" = openrc ]; then S5_OS_FAMILY=alpine; fi
                S5_LANG=$_cslang
                s5_select_service_artifact
                t_run s5t_cleanup_run "$_csfault"
                _cscase="$_csbackend/$_csfault/$_cslang"
                assert_ne "$_cscase remains an installation failure" 0 "$T_STATUS"
                if [ "$_csfault" != start-failure ]; then
                    assert_file_exists "$_cscase failed verification after starting" "$S5_TEST_ROOT/verification-failed"
                fi
                assert_file_exists "$_cscase attempts native stop" "$S5_TEST_ROOT/stop-attempted"
                assert_file_exists "$_cscase stops under its owned lock" "$S5_TEST_ROOT/stop-under-lock"
                if [ "$_csfault" = stopped ]; then
                    assert_file_absent "$_cscase proves the service stopped" "$S5_TEST_ROOT/svc_active"
                    assert_eq "$_cscase clears service ownership" 0 "$(cat "$S5_TEST_ROOT/service-owned")"
                    for _cspath in "$S5_CFG" "$S5_BIN" "$S5_SERVICE_ARTIFACT" "$S5_TEST_ROOT/user-exists" "$S5_TEST_ROOT/group-exists"; do
                        assert_file_absent "$_cscase removes the stopped installation" "$_cspath"
                    done
                    if [ "$S5_INIT" = openrc ]; then
                        assert_file_absent "$_cscase removes its stopped supervisor pid" "$S5_PIDFILE"
                        assert_file_absent "$_cscase removes its stopped child pid" "$S5_OPENRC_OPTION_DIR/child_pid"
                    fi
                else
                    assert_file_exists "$_cscase still has a live service" "$S5_TEST_ROOT/svc_active"
                    assert_eq "$_cscase retains service ownership" 1 "$(cat "$S5_TEST_ROOT/service-owned")"
                    for _cspath in "$S5_CFG" "$S5_BIN" "$S5_SERVICE_ARTIFACT" "$S5_TEST_ROOT/user-exists" "$S5_TEST_ROOT/group-exists"; do
                        assert_file_exists "$_cscase retains live resources" "$_cspath"
                    done
                    assert_mode "$_cscase keeps the retained config private" 640 "$S5_CFG"
                    if [ "$S5_INIT" = openrc ]; then
                        assert_eq "$_cscase preserves supervisor tracking" 100 "$(cat "$S5_PIDFILE" 2>/dev/null)"
                        assert_eq "$_cscase preserves child tracking" 101 "$(cat "$S5_OPENRC_OPTION_DIR/child_pid" 2>/dev/null)"
                    fi
                    case "$_cslang" in
                    en) _csdiagnosis='installation files and account were retained' ;;
                    zh) _csdiagnosis='已保留安装文件和账户' ;;
                    esac
                    assert_contains "$_cscase explains retained resources" "$_csdiagnosis" "$T_OUT"
                    assert_not_contains "$_cscase does not disable the live service" 'disable' "$(cat "$S5_TEST_ROOT/manager-calls")"
                    assert_not_contains "$_cscase does not remove OpenRC boot registration" 'del' "$(cat "$S5_TEST_ROOT/manager-calls")"
                fi
                assert_file_absent "$_cscase releases its lock" "$S5_LOCKDIR"
                assert_file_absent "$_cscase removes the verification secret" "$S5_TEST_ROOT/verify-temp"
                assert_not_contains "$_cscase does not expose the password" "$S5_PASSWORD" "$T_OUT"
            done
        done
    done
}

s5t_digest_failure_install() {
    _sdf_target=$1
    t_xray_fixture 23456
    _sdf_real_sha256_command=$(command -v sha256sum)
    s5_sha256_command() {
        case "$_sdf_target:$1" in
        unit:"$S5_SERVICE_ARTIFACT" | config:"$S5_CFG") return 91 ;;
        esac
        "$_sdf_real_sha256_command" "$1"
    }
    s5_install_new >"$S5_TEST_ROOT/sha-install.log" 2>&1
    _sdf_status=$?
    assert_ne "$_sdf_target digest failure aborts fresh installation" 0 "$_sdf_status"
    assert_contains "$_sdf_target digest failure has a specific diagnosis" \
        'could not compute SHA-256 for installed artifact' "$(cat "$S5_TEST_ROOT/sha-install.log")"
    assert_not_contains "$_sdf_target digest failure prints no credential card" \
        socks5:// "$(cat "$S5_TEST_ROOT/sha-install.log")"
    assert_file_absent "$_sdf_target digest failure writes no successful state" "$S5_STATE"
    s5_cleanup
    assert_file_absent "$_sdf_target digest cleanup removes config" "$S5_CFG"
    assert_file_absent "$_sdf_target digest cleanup removes binary" "$S5_BIN"
    assert_file_absent "$_sdf_target digest cleanup removes service artifact" "$S5_SERVICE_ARTIFACT"
    assert_file_absent "$_sdf_target digest cleanup removes the service account" "$S5_TEST_ROOT/user-exists"
    assert_file_absent "$_sdf_target digest cleanup removes the service group" "$S5_TEST_ROOT/group-exists"
}

# Every fresh-install step that fails names itself; the operator used to see
# a bare nonzero exit for these.
s5t_fresh_step_fault() {
    case "$1" in
    unit) s5_write_unit() { return 1; } ;;
    reload | enable)
        systemctl() {
            case "$_fsm_fault:${1:-}" in reload:daemon-reload | enable:enable) return 1 ;; esac
            "$S5_TEST_ROOT/bin/systemctl" "$@"
        }
        ;;
    state) s5_state_write() { return 1; } ;;
    dataplane) S5_PROTOCOL_VERIFY=false ;;
    esac
    s5_install_new
}

test_fresh_step_messages() {
    for _fsm_fault in unit reload enable state dataplane; do
        t_xray_fixture 23456
        T_OUT=$( ( s5t_fresh_step_fault "$_fsm_fault" ) 2>&1) && T_STATUS=0 || T_STATUS=$?
        assert_ne "fresh $_fsm_fault failure aborts installation" 0 "$T_STATUS"
        case "$_fsm_fault" in
        unit) _fsm_said="could not write the service definition: $S5_SERVICE_ARTIFACT." ;;
        reload) _fsm_said='the service manager could not reload the service definitions.' ;;
        enable) _fsm_said='could not enable the Xray service at boot.' ;;
        state) _fsm_said="could not write the state file: $S5_STATE." ;;
        dataplane) _fsm_said='authenticated proxy traffic could not be verified on port 23456.' ;;
        esac
        assert_contains "fresh $_fsm_fault failure names itself" "[x] $_fsm_said" "$T_OUT"
        assert_not_contains "a data-plane failure is not a listener diagnosis" \
            'listen state of port' "$T_OUT"
    done
}

# Alpine deletes the group with delgroup; a refusal there is warned about on
# every backend, not only on the systemd families.
test_alpine_group_warning() {
    t_xray_fixture 23456
    S5_OS_FAMILY=alpine
    S5_CREATED_GROUP=1
    printf '900\n' >"$S5_TEST_ROOT/group-exists"
    : >"$S5_TEST_ROOT/fail-groupdel"
    t_run s5_account_remove
    assert_ne "a refused Alpine group deletion fails" 0 "$T_STATUS"
    assert_contains "a refused Alpine group deletion is warned about" \
        '[!] could not remove service group: xray-socks5' "$T_OUT"
    rm -f "$S5_TEST_ROOT/fail-groupdel"
}

# One removal serves install cleanup and uninstall. A half already gone is
# skipped, a present half is deleted only while it matches the record, and a
# mismatch is named rather than deleted.
test_account_remove_halves() {
    t_xray_fixture 23456
    S5_ACCOUNT_UID=900
    S5_ACCOUNT_GID=900
    printf '900\n' >"$S5_TEST_ROOT/group-exists"
    rm -f "$S5_TEST_ROOT/user-exists"
    t_run s5_account_remove
    assert_eq "a resumed removal finishes the remaining group" 0 "$T_STATUS"
    assert_file_absent "the remaining group is removed" "$S5_TEST_ROOT/group-exists"
    printf '777\n' >"$S5_TEST_ROOT/group-exists"
    t_run s5_account_remove
    assert_eq "a group at another GID is refused as an identity mismatch" 1 "$T_STATUS"
    assert_contains "the mismatch is named" 'account identity mismatch: recorded 900/900' "$T_OUT"
    assert_file_exists "a mismatched group is left in place" "$S5_TEST_ROOT/group-exists"
    rm -f "$S5_TEST_ROOT/group-exists"
}

# c. A signal just after an account tool succeeds must still let cleanup find
# the account, so the next install is not refused by its own leftover.
s5t_account_signal() {
    case "$1" in
    group) groupadd() { "$S5_TEST_ROOT/bin/groupadd" "$@" && s5t_signal_self; } ;;
    user) useradd() { "$S5_TEST_ROOT/bin/useradd" "$@" && s5t_signal_self; } ;;
    esac
    trap 's5_on_signal 143' TERM
    s5_install_new || { s5_cleanup; return 1; }
}

s5t_signal_self() {
    python3 -c 'import os, signal; os.kill(os.getppid(), signal.SIGTERM)'
}

test_account_signal() {
    for _as_tool in group user; do
        t_xray_fixture 23456
        ( s5t_account_signal "$_as_tool" ) >"$S5_TEST_ROOT/account-signal.log" 2>&1
        assert_eq "a signal after $_as_tool creation exits with its status" 143 "$?"
        assert_file_absent "a signal after $_as_tool creation leaves no user" "$S5_TEST_ROOT/user-exists"
        assert_file_absent "a signal after $_as_tool creation leaves no group" "$S5_TEST_ROOT/group-exists"
        t_run s5_install_new
        assert_eq "install succeeds after a signal during $_as_tool creation" 0 "$T_STATUS"
        [ "$T_STATUS" -eq 0 ] || printf '%s\n--- signal log ---\n%s\n' "$T_OUT" "$(cat "$S5_TEST_ROOT/account-signal.log")" >&2
    done
}

# e. The manager reloads after the unit file is gone, and whenever this run
# created it, including when enable was never reached.
s5t_reload_order() {
    systemctl() {
        if [ "${1:-}" = daemon-reload ]; then
            if [ -e "$S5_SERVICE_ARTIFACT" ]; then echo present; else echo absent; fi >>"$S5_TEST_ROOT/reload-order"
        fi
        case "$S5T_RELOAD_FAULT:${1:-}" in start:start | enable:enable) return 1 ;; esac
        "$S5_TEST_ROOT/bin/systemctl" "$@"
    }
    s5_install_new
    s5_cleanup
}

test_cleanup_reload_order() {
    for S5T_RELOAD_FAULT in start enable; do
        t_xray_fixture 23456
        ( s5t_reload_order ) >"$S5_TEST_ROOT/reload.log" 2>&1
        assert_file_absent "a failed $S5T_RELOAD_FAULT removes the unit" "$S5_SERVICE_ARTIFACT"
        assert_eq "the last reload after a failed $S5T_RELOAD_FAULT sees the unit gone" absent \
            "$(tail -n 1 "$S5_TEST_ROOT/reload-order" 2>/dev/null)"
    done
}

# install cleans up on each of its own return paths and sets no EXIT trap. A
# declined or refused install used to return with the lock still held and leave
# its release to an EXIT trap, which also replaced the EXIT handler of whatever
# sourced the script.
test_install_exit_handler() {
    for _ieh_case in declined refused failed; do
        t_xray_fixture 23456
        s5_precheck_host() { return 0; }; s5_precheck_tools() { return 0; }
        (
            trap 'printf "caller-exit\n"' EXIT
            case "$_ieh_case" in
            declined) s5_confirm_install() { return 1; } ;;
            refused) s5_namespace_absent() { return 1; } ;;
            failed)
                s5_confirm_install() { return 0; }
                s5_install_new() { return 1; }
                ;;
            esac
            s5_cmd_install
            printf 'returned=%s\n' "$?"
            if [ -e "$S5_LOCKDIR" ]; then printf 'lock-held\n'; fi
        ) >"$S5_TEST_ROOT/exit-handler.log" 2>&1
        _ieh_out=$(cat "$S5_TEST_ROOT/exit-handler.log")
        assert_contains "a $_ieh_case install fails to its caller" 'returned=1' "$_ieh_out"
        assert_not_contains "a $_ieh_case install releases its lock before returning" 'lock-held' "$_ieh_out"
        assert_contains "a $_ieh_case install keeps the caller's EXIT handler" 'caller-exit' "$_ieh_out"
    done
}

test_sha256_unit_failure() { s5t_digest_failure_install unit; }
test_sha256_config_install_failure() { s5t_digest_failure_install config; }

SCENARIOS='account_signal account_remove_halves install_exit_handler cleanup_reload_order fresh_step_messages alpine_group_warning cleanup_stop_failure account_creation_failure account_lifecycle install openrc_logging_warning config_corrupt binary_corrupt unit_corrupt account_corrupt cleanup_temps openrc_runtime locks raw_command_cleanup raw_release_failure raw_candidate_failure raw_signal fresh_stage_failure_cleanup sha256_unit_failure sha256_config_install_failure'
if [ "$#" -eq 0 ]; then
    # Expand the fixed scenario words into the default argument list.
    # shellcheck disable=SC2086
    set -- $SCENARIOS
fi
for scenario do
    _scenario_known=0
    for _scenario_name in $SCENARIOS; do
        if [ "$scenario" = "$_scenario_name" ]; then _scenario_known=1; break; fi
    done
    if [ "$_scenario_known" = 1 ]; then
        if ! command -v "test_$scenario" >/dev/null 2>&1; then
            t_bad "missing install scenario: $scenario"
        else
            "test_$scenario"
        fi
    else
        t_bad "unknown install scenario: $scenario"
    fi
done
t_summary
