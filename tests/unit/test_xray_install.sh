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

s5t_download_fixture() {
    t_xray_fixture 23456 real-download
    python3 "$S5_REPO_ROOT/tests/lib/mkasset.py" "$S5_TEST_ROOT" good >/dev/null || return 1
    S5_TEST_ASSET_PATH=$S5_TEST_ROOT/good.zip
    export S5_TEST_ASSET_PATH
    t_use_asset_fixture "$S5_TEST_ROOT/asset-xray" archive
    s5_asset_select
    s5_precheck() { return 0; }
    s5_tmp_base() { printf '%s\n' "$S5_TEST_ROOT"; }
    mkdir -p "$S5_TEST_ROOT/unrelated/transaction" "$S5_TEST_ROOT/xray-socks5-download.foreign"
    printf 'recovery evidence\n' >"$S5_TEST_ROOT/unrelated/transaction/old.config.json"
    printf 'foreign download\n' >"$S5_TEST_ROOT/xray-socks5-download.foreign/asset.zip"
}

s5t_download_run() {
    _tdfault=${1:-none}
    if [ "$_tdfault" = remove-zh ]; then S5_LANG=zh; fi
    case "$_tdfault" in
    candidate|candidate-remove) printf '23\n' >"$S5_TEST_ROOT/cfgtest" ;;
    esac
    mktemp() {
        _tdtemp=$(command mktemp "$@") || return 1
        case "$_tdtemp" in
        */xray-socks5-download.*) printf '%s\n' "$_tdtemp" >"$S5_TEST_ROOT/download.path" ;;
        esac
        printf '%s\n' "$_tdtemp"
    }
    rm() {
        if [ "${1:-}" = -rf ] && [ -n "$S5_WORKDIR" ] && [ "${2:-}" = "$S5_WORKDIR" ]; then
            if [ "$S5_LOCK_HELD" = 1 ] &&
                [ "$(cat "$S5_LOCK_OWNER" 2>/dev/null)" = "$S5_LOCK_TOKEN" ]; then
                printf 'owned\n' >>"$S5_TEST_ROOT/download.cleanup"
            else
                printf 'unowned\n' >>"$S5_TEST_ROOT/download.cleanup"
            fi
            if [ -f "$S5_WORKDIR/Xray-linux-64.zip" ] && [ -f "$S5_WORKDIR/members" ] &&
                [ -f "$S5_WORKDIR/xray" ]; then
                printf 'verified scratch exists\n' >>"$S5_TEST_ROOT/download.cleanup"
            fi
            case "$_tdfault" in remove|remove-zh|candidate-remove) return 1 ;; esac
        fi
        command rm "$@"
    }
    rmdir() {
        if [ "$_tdfault" = release ] && [ "${1:-}" = "$S5_LOCKDIR" ]; then
            printf 'release failed\n' >>"$S5_TEST_ROOT/download.release"
            return 1
        fi
        command rmdir "$@"
    }
    chmod() {
        if [ "$_tdfault" = signal ] && [ "${1:-}:${2:-}" = "0750:$S5_SYSCONFDIR" ]; then
            # getppid addresses this test invocation, unlike POSIX subshell $$.
            python3 -c 'import os, signal; os.kill(os.getppid(), signal.SIGTERM)'
            return 1
        fi
        command chmod "$@"
    }
    s5_cmd_install
    _tdstatus=$?
    printf '%s\n' "$S5_WORKDIR" >"$S5_TEST_ROOT/download.retained"
    return "$_tdstatus"
}

test_download_cleanup() {
    s5t_download_fixture
    if ! unzip -Z1 "$S5_TEST_ASSET_PATH" >/dev/null 2>&1; then
        t_skip "command-level download cleanup" "requires Info-ZIP unzip with -Z"
        return
    fi
    t_run s5t_download_run
    assert_eq "command-level installation with verified archive succeeds" 0 "$T_STATUS"
    _tdpath=$(cat "$S5_TEST_ROOT/download.path")
    assert_file_absent "successful install removes its downloaded archive" "$_tdpath/Xray-linux-64.zip"
    assert_file_absent "successful install removes its extracted temporary binary" "$_tdpath/xray"
    assert_file_absent "successful install removes its member list and workdir" "$_tdpath"
    assert_eq "successful cleanup clears its workdir reference" '' "$(cat "$S5_TEST_ROOT/download.retained")"
    assert_contains "download cleanup runs while the command owns its lock" owned \
        "$(cat "$S5_TEST_ROOT/download.cleanup" 2>/dev/null)"
    assert_not_contains "download cleanup never runs after unlocking" unowned \
        "$(cat "$S5_TEST_ROOT/download.cleanup" 2>/dev/null)"
    assert_contains "the command really downloaded and extracted scratch files" 'verified scratch exists' \
        "$(cat "$S5_TEST_ROOT/download.cleanup" 2>/dev/null)"
    assert_file_exists "successful cleanup preserves the installed binary" "$S5_BIN"
    assert_file_exists "successful cleanup preserves config" "$S5_CFG"
    assert_file_exists "successful cleanup preserves state" "$S5_STATE"
    assert_file_absent "successful cleanup releases the operation lock" "$S5_LOCKDIR"
    assert_file_exists "cleanup preserves a different download directory" "$S5_TEST_ROOT/xray-socks5-download.foreign/asset.zip"
    assert_file_exists "cleanup preserves unrelated recovery evidence" "$S5_TEST_ROOT/unrelated/transaction/old.config.json"
    assert_not_contains "command output contains no password" "$S5_PASSWORD" "$T_OUT"
    t_xray_assert_healthy
    t_run s5t_download_run
    assert_eq "configuration update without a download workdir still succeeds" 0 "$T_STATUS"
    assert_eq "configuration update keeps the workdir reference empty" '' "$(cat "$S5_TEST_ROOT/download.retained")"
    assert_file_exists "configuration update leaves the foreign download alone" "$S5_TEST_ROOT/xray-socks5-download.foreign/asset.zip"
    t_xray_assert_healthy
}

s5t_download_fault_case() {
    _tdcase=$1
    s5t_download_fixture
    if ! unzip -Z1 "$S5_TEST_ASSET_PATH" >/dev/null 2>&1; then
        t_skip "command-level download $_tdcase" "requires Info-ZIP unzip with -Z"
        return
    fi
    t_run s5t_download_run "$_tdcase"
    case "$_tdcase" in
    signal) assert_eq "download-stage signal propagates its signal status" 143 "$T_STATUS" ;;
    *) assert_eq "$_tdcase failure remains nonzero" 1 "$T_STATUS" ;;
    esac
    _tdpath=$(cat "$S5_TEST_ROOT/download.path")
    assert_contains "$_tdcase cleanup reaches the command's owned lock" owned \
        "$(cat "$S5_TEST_ROOT/download.cleanup" 2>/dev/null)"
    assert_not_contains "$_tdcase never cleans the download after unlocking" unowned \
        "$(cat "$S5_TEST_ROOT/download.cleanup" 2>/dev/null)"
    case "$_tdcase" in
    remove|remove-zh|candidate-remove)
        assert_dir_exists "$_tdcase retains the workdir on deletion failure" "$_tdpath"
        assert_eq "$_tdcase retains the failed cleanup path" "$_tdpath" "$(cat "$S5_TEST_ROOT/download.retained")"
        case "$_tdcase" in
        remove-zh) _tddiagnostic='无法删除下载临时目录' ;;
        *) _tddiagnostic='could not remove temporary download directory' ;;
        esac
        assert_contains "$_tdcase reports cleanup failure in the selected language" "$_tddiagnostic" "$T_OUT"
        assert_contains "$_tdcase identifies only its owned cleanup path" "$_tdpath" "$T_OUT"
        ;;
    *) assert_file_absent "$_tdcase removes the owned download workdir" "$_tdpath" ;;
    esac
    case "$_tdcase" in
    release)
        assert_dir_exists "failed lock release remains observable" "$S5_LOCKDIR"
        assert_contains "the lock release failure was reached" 'release failed' "$(cat "$S5_TEST_ROOT/download.release")"
        ;;
    *) assert_file_absent "$_tdcase releases its operation lock" "$S5_LOCKDIR" ;;
    esac
    assert_eq "$_tdcase preserves a different download's bytes" 'foreign download' \
        "$(cat "$S5_TEST_ROOT/xray-socks5-download.foreign/asset.zip")"
    assert_eq "$_tdcase preserves unrelated recovery evidence" 'recovery evidence' \
        "$(cat "$S5_TEST_ROOT/unrelated/transaction/old.config.json")"
    assert_not_contains "$_tdcase never announces English installation success" 'installation completed' "$T_OUT"
    assert_not_contains "$_tdcase never announces Chinese installation success" '安装完成' "$T_OUT"
    assert_not_contains "$_tdcase output contains no password" "$S5_PASSWORD" "$T_OUT"
    case "$_tdcase" in
    candidate|candidate-remove|signal)
        assert_file_absent "$_tdcase removes the failed new-install binary" "$S5_BIN"
        assert_file_absent "$_tdcase does not leave an installed state" "$S5_STATE"
        ;;
    *)
        assert_eq "$_tdcase leaves the healthy listener running" 23456 "$(cat "$S5_TEST_ROOT/svc_active")"
        assert_eq "$_tdcase never stops the healthy installation" 0 \
            "$(grep -c 'systemctl stop ' "$S5_TEST_ROOT/transcript")"
        t_xray_assert_healthy
        ;;
    esac
}

test_download_remove_failure() { s5t_download_fault_case remove; }
test_download_remove_zh() { s5t_download_fault_case remove-zh; }
test_download_release_failure() { s5t_download_fault_case release; }
test_download_candidate_failure() { s5t_download_fault_case candidate; }
test_download_candidate_remove_failure() { s5t_download_fault_case candidate-remove; }
test_download_signal() { s5t_download_fault_case signal; }

test_fresh_stage_failure_cleanup() {
    t_xray_fixture 23456 real-download
    s5_stage_engine() {
        S5_WORKDIR=$S5_TEST_ROOT/fresh-stage
        mkdir -p "$S5_WORKDIR"
        printf 'partial xray\n' >"$S5_WORKDIR/xray"
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
    assert_contains "fresh staging retains its original diagnosis" \
        'stage write failed' "$T_OUT"
    assert_not_contains "fresh staging failure does not describe an existing installation as unusable" \
        'service account cannot use this installation' "$T_OUT"
    assert_not_contains "fresh staging failure does not attempt to restore a disposable prefix" \
        'unexpected prefix restore' "$(cat "$S5_TEST_ROOT/fresh-stage.events" 2>/dev/null)"
    assert_file_absent "fresh staging cleanup removes its work directory" "$S5_TEST_ROOT/fresh-stage"
    assert_file_absent "fresh staging cleanup removes its newly created prefix" "$S5_PREFIX"
    assert_file_absent "fresh staging failure publishes no binary" "$S5_BIN"
    assert_file_absent "fresh staging failure publishes no config" "$S5_CFG"
    assert_file_absent "fresh staging failure publishes no state" "$S5_STATE"
    assert_file_absent "fresh staging failure publishes no service artifact" "$S5_SERVICE_ARTIFACT"
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
    s5_precheck() { return 0; }
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
    [ -f "$S5_TEST_ROOT/svc_active" ] && exit 0
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
    S5_WORKDIR=$S5_TEST_ROOT/download
    mkdir -p "$S5_WORKDIR"
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
                assert_file_absent "$_cscase removes download scratch" "$S5_TEST_ROOT/download"
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

test_sha256_unit_failure() { s5t_digest_failure_install unit; }
test_sha256_config_install_failure() { s5t_digest_failure_install config; }

SCENARIOS='cleanup_stop_failure account_creation_failure account_lifecycle install config_corrupt binary_corrupt unit_corrupt account_corrupt cleanup_temps openrc_runtime locks download_cleanup download_remove_failure download_remove_zh download_release_failure download_candidate_failure download_candidate_remove_failure download_signal fresh_stage_failure_cleanup sha256_unit_failure sha256_config_install_failure'
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
        "test_$scenario"
    else
        t_bad "unknown install scenario: $scenario"
    fi
done
t_summary
