#!/bin/sh
# Update transactions and cleanup, each starting at a fresh invocation boundary.

S5T_NAME=test_xray_update
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
. "${S5_REPO_ROOT}/tests/lib/xray-fixture.sh"

test_family() {
    t_xray_fixture 23456
    t_xray_install
    assert_eq "state records the installed port" 23456 "$(s5_state_get port)"
    # Debian and EL share the systemd path; family must still match the host.
    S5_OS_FAMILY=el
    t_run s5_state_load
    assert_ne "a state file from another OS family is refused" 0 "$T_STATUS"
    S5_OS_FAMILY=debian
    t_run s5_state_load
    assert_eq "the family check does not reject the recorded family" 0 "$T_STATUS"
}

test_update() {
    t_xray_fixture 23456
    t_xray_install
    # A successful update deliberately runs in this shell. Running another
    # scenario after it checks that initialization discards its completed flags.
    s5_prompt_port() { S5_PORT=23999; return 0; }
    s5_install_update
    assert_eq "update completes" 0 "$?"
    assert_contains "config carries the new port" '"port": 23999' "$(cat "$S5_CFG")"
    assert_eq "state records the new port" 23999 "$(s5_state_get port)"
    assert_file_absent "update leaves no transaction directory" "$S5_TXNDIR"
    assert_eq "service listens on the new port" 23999 "$(cat "$S5_TEST_ROOT/svc_active")"
    t_xray_assert_healthy
}

test_owned_port() {
    t_xray_fixture 23999
    t_xray_install
    # A listener this installation already owns is allowed during update.
    s5_port_free 23999
    assert_eq "the running port reads as busy" 1 "$?"
    t_run s5_port_owned_by_service 23999
    assert_eq "the port this service owns is accepted" 0 "$T_STATUS"
    t_run s5_port_owned_by_service 24001
    assert_ne "a port this service does not own is refused" 0 "$T_STATUS"

    # Ownership is verified, not assumed from the recorded port.
    S5_LISTENER_PROBE=$S5_TEST_ROOT/foreignprobe
    printf '#!/bin/sh\nexit 2\n' >"$S5_LISTENER_PROBE"
    chmod 0755 "$S5_LISTENER_PROBE"
    export S5_LISTENER_PROBE
    t_run s5_port_owned_by_service 23999
    assert_ne "a foreign listener on the recorded port is refused" 0 "$T_STATUS"
}

test_rejected_candidate() {
    t_xray_fixture 23999
    t_xray_install
    # Config-test precedes service stop and leaves the published config alone.
    _upcfg=$(t_sha256 "$S5_CFG")
    _upstops=$(grep -c 'systemctl stop' "$S5_TEST_ROOT/transcript" || true)
    printf 1 >"$S5_TEST_ROOT/cfgtest"
    s5_prompt_port() { S5_PORT=24555; return 0; }
    t_run s5_install_update
    assert_ne "a rejected candidate config fails the update" 0 "$T_STATUS"
    assert_eq "the published config is untouched" \
        "$_upcfg" "$(t_sha256 "$S5_CFG")"
    assert_eq "a healthy service is never stopped" \
        "$_upstops" "$(grep -c 'systemctl stop' "$S5_TEST_ROOT/transcript" || true)"
    assert_eq "the service keeps its previous port" 23999 "$(cat "$S5_TEST_ROOT/svc_active")"
}

test_listener_failure() {
    t_xray_fixture 23999
    t_xray_install
    # If the published config never reaches the listener, old config/state return.
    _upcfg=$(t_sha256 "$S5_CFG")
    _upstate=$(t_sha256 "$S5_STATE")
    s5_wait_listening() { return 1; }
    s5_prompt_port() { S5_PORT=24777; return 0; }
    t_run s5_install_update
    assert_ne "an unreachable listener fails the update" 0 "$T_STATUS"
    assert_eq "the old config is restored" \
        "$_upcfg" "$(t_sha256 "$S5_CFG")"
    assert_eq "the old state is restored" \
        "$_upstate" "$(t_sha256 "$S5_STATE")"
    assert_file_absent "the transaction evidence is removed" "$S5_TXNDIR"
    t_xray_assert_healthy
}

test_rejected_command() {
    t_xray_fixture 23999
    t_xray_install
    # Unlike the direct-update case, the command's EXIT trap must run. A rejected
    # candidate has full backups but no published config: cleanup must not replace
    # even a byte-identical live file, nor restart a service it never stopped.
    _upinode=$(stat -c '%i' "$S5_CFG")
    _upcfg=$(t_sha256 "$S5_CFG")
    _upstate=$(t_sha256 "$S5_STATE")
    _uprestarts=$(grep -c 'systemctl restart' "$S5_TEST_ROOT/transcript" || true)
    s5_precheck() { return 0; }
    printf 1 >"$S5_TEST_ROOT/cfgtest"
    s5_prompt_port() { S5_PORT=24999; return 0; }
    # The subshell fires the real EXIT trap without replacing the harness trap.
    ( s5_cmd_install ) >"$S5_TEST_ROOT/cmdinstall.log" 2>&1
    _upstatus=$?
    assert_ne "a rejected candidate fails the install command" 0 "$_upstatus"
    assert_eq "the live config file is not replaced" \
        "$_upinode" "$(stat -c '%i' "$S5_CFG")"
    assert_eq "the live config content is unchanged" \
        "$_upcfg" "$(t_sha256 "$S5_CFG")"
    assert_eq "the live state is unchanged" \
        "$_upstate" "$(t_sha256 "$S5_STATE")"
    assert_eq "a healthy service is not restarted" "$_uprestarts" \
        "$(grep -c 'systemctl restart' "$S5_TEST_ROOT/transcript" || true)"
    assert_file_absent "the transaction is not left behind" "$S5_TXNDIR"
    assert_eq "the service still listens on its own port" 23999 \
        "$(cat "$S5_TEST_ROOT/svc_active")"
    t_xray_assert_healthy
}

test_publish_signal() {
    t_xray_fixture 23999
    t_xray_install
    # Deliver the signal after the publish rename returns, before its caller can
    # update flags. Cleanup must restore the old config against the old state.
    _winold=$(t_sha256 "$S5_CFG")
    s5_precheck() { return 0; }
    s5_prompt_port() { S5_PORT=24333; return 0; }
    (
        S5T_MV_FIRED=0
        mv() {
            command mv "$@" || return $?
            _mvdest=''
            for _mvdest in "$@"; do :; done
            if [ "$_mvdest" = "$S5_CFG" ] && [ "$S5T_MV_FIRED" = 0 ]; then
                S5T_MV_FIRED=1
                s5_on_signal 143
            fi
        }
        s5_cmd_install
    ) >"$S5_TEST_ROOT/winsignal.log" 2>&1
    _winstatus=$?
    assert_eq "a signal in the publish window exits through the signal handler" 143 "$_winstatus"
    assert_eq "a signal in the publish window leaves the recoverable old config live" \
        "$_winold" "$(t_sha256 "$S5_CFG")"
    t_run s5_state_load
    assert_eq "the installation is still loadable after an interrupted publish" 0 "$T_STATUS"
    assert_eq "the restored service listens on the port it owned" 23999 \
        "$(cat "$S5_TEST_ROOT/svc_active" 2>/dev/null || printf missing)"
}

test_config_symlink() {
    t_xray_fixture 23999
    t_xray_install
    # Byte-identical content isolates the symlink guard from hash verification.
    cp "$S5_CFG" "$S5_TEST_ROOT/realcfg"
    rm -f "$S5_CFG"
    ln -s "$S5_TEST_ROOT/realcfg" "$S5_CFG"
    t_run s5_state_load
    assert_eq "a symlinked config is refused even with matching content" 1 "$T_STATUS"
    rm -f "$S5_CFG"
    mv "$S5_TEST_ROOT/realcfg" "$S5_CFG"
    t_run s5_state_load
    assert_eq "the regular config still loads after the symlink check" 0 "$T_STATUS"
}

test_uninstall_leftovers() {
    t_xray_fixture 23999
    t_xray_install
    # An interrupted update's known private leftovers are safe to remove.
    s5_precheck() { return 0; }
    mkdir -p "$S5_TXNDIR"
    printf '{}\n' >"$S5_TXNDIR/old.config.json"
    printf 'engine\txray\n' >"$S5_TXNDIR/old.state"
    chmod 0600 "$S5_TXNDIR/old.config.json" "$S5_TXNDIR/old.state"
    : >"$S5_SYSCONFDIR/.s5new.leftover.json"
    printf 'y\n' >"$S5_TEST_ROOT/answers.uninstall"
    t_legacy_fixture
    # Split streams: merging the prompt with stdout hides its newline regression.
    s5_cmd_uninstall <"$S5_TEST_ROOT/answers.uninstall" \
        >"$S5_TEST_ROOT/uninst.out" 2>"$S5_TEST_ROOT/uninst.err" &&
        T_STATUS=0 || T_STATUS=$?
    assert_eq "uninstall completes despite an interrupted update's leftovers" 0 "$T_STATUS"
    assert_eq "uninstall preserves the legacy config" 'legacy config' "$(cat "$S5_TEST_ROOT/etc/socks5-manager/3proxy.cfg")"
    assert_eq "uninstall preserves the legacy state" 'legacy state' "$(cat "$S5_TEST_ROOT/var/lib/socks5-manager/state")"
    assert_eq "uninstall preserves the legacy binary" 'legacy binary' "$(cat "$S5_TEST_ROOT/usr/local/libexec/socks5-manager/3proxy")"
    assert_eq "the redirected uninstall confirmation terminates its line" 1 \
        "$(wc -l <"$S5_TEST_ROOT/uninst.err" | tr -d '[:space:]')"
    assert_file_absent "uninstall removes the config directory" "$S5_SYSCONFDIR"
    assert_file_absent "uninstall removes the state directory" "$S5_STATEDIR"
    assert_file_absent "uninstall removes the install prefix" "$S5_PREFIX"
}

test_uninstall_residue() {
    t_xray_fixture 23456
    s5_precheck() { return 0; }
    printf 'y\n' >"$S5_TEST_ROOT/answers.uninstall"
    # A missing state is not success if namespace residue survives.
    mkdir -p "$S5_STATEDIR"
    : >"$S5_STATEDIR/.s5state.residue"
    T_OUT=$(s5_cmd_uninstall <"$S5_TEST_ROOT/answers.uninstall" 2>&1) &&
        T_STATUS=0 || T_STATUS=$?
    assert_ne "a missing state file with residue is not success" 0 "$T_STATUS"
    rm -rf "$S5_STATEDIR"
    T_OUT=$(s5_cmd_uninstall <"$S5_TEST_ROOT/answers.uninstall" 2>&1) &&
        T_STATUS=0 || T_STATUS=$?
    assert_eq "a clean namespace reports nothing installed" 0 "$T_STATUS"

    # The unit lives outside the three namespace directories, but is residue too.
    : >"$S5_SERVICE_ARTIFACT"
    T_OUT=$(s5_cmd_uninstall <"$S5_TEST_ROOT/answers.uninstall" 2>&1) &&
        T_STATUS=0 || T_STATUS=$?
    assert_ne "a surviving unit file is residue, not nothing-installed" 0 "$T_STATUS"
    rm -f "$S5_SERVICE_ARTIFACT"
    T_OUT=$(s5_cmd_uninstall <"$S5_TEST_ROOT/answers.uninstall" 2>&1) &&
        T_STATUS=0 || T_STATUS=$?
    assert_eq "the namespace with the unit gone reports nothing installed" 0 "$T_STATUS"
}

test_verifier_cleanup() {
    t_xray_fixture 23456
    # Updates have no workdir: the recorded cleartext verifier temp must still be
    # removed by cleanup, including on repeated cleanup attempts.
    _verifier_dir=$S5_TEST_ROOT/vtmp
    mkdir -p "$_verifier_dir"
    _verifier_credential=$_verifier_dir/.s5pass.leaked
    printf '%s\n%s\n' "$S5_USERNAME" "$S5_PASSWORD" >"$_verifier_credential"
    chmod 0600 "$_verifier_credential"
    S5_VERIFY_TEMP=$_verifier_credential
    s5_cleanup
    assert_file_absent "s5_cleanup releases the recorded verifier credential temp" "$_verifier_credential"
    assert_eq "s5_cleanup clears S5_VERIFY_TEMP after releasing it" '' "$S5_VERIFY_TEMP"
    s5_cleanup
    assert_file_absent "repeated cleanup does not recreate the verifier credential temp" "$_verifier_credential"
}

test_restore_failure() {
    for _restore_target in config state; do
        t_xray_fixture 23456
        t_xray_install
        _restore_cfg=$(t_sha256 "$S5_CFG")
        _restore_state=$(t_sha256 "$S5_STATE")
        (
            s5_precheck() { return 0; }
            s5_prompt_port() { S5_PORT=24567; }
            s5_state_write() { : >"$S5_TEST_ROOT/fail-restore"; return 1; }
            mktemp() {
                if [ -f "$S5_TEST_ROOT/fail-restore" ]; then
                    case "$_restore_target:$1" in
                    config:"$S5_SYSCONFDIR"/.s5tmp.* | state:"$S5_STATEDIR"/.s5tmp.*) return 1 ;;
                    esac
                fi
                command mktemp "$@"
            }
            s5_cmd_install
        ) >"$S5_TEST_ROOT/restore.log" 2>&1
        _restore_rc=$?
        assert_ne "$_restore_target restore failure fails the command" 0 "$_restore_rc"
        assert_eq "$_restore_target failure preserves old config through EXIT cleanup" \
            "$_restore_cfg" "$(t_sha256 "$S5_TXNDIR/old.config.json" 2>/dev/null)"
        assert_eq "$_restore_target failure preserves old state through EXIT cleanup" \
            "$_restore_state" "$(t_sha256 "$S5_TXNDIR/old.state" 2>/dev/null)"
        assert_eq "$_restore_target restore failure never restarts an unrestored service" 0 \
            "$(grep -c 'systemctl restart' "$S5_TEST_ROOT/transcript" || true)"
        assert_file_absent "failed update is stopped during cleanup" "$S5_TEST_ROOT/svc_active"
        assert_contains "restore failure identifies retained recovery data" \
            'recovery copies retained' "$(cat "$S5_TEST_ROOT/restore.log")"
        if [ -f "$S5_TXNDIR/old.config.json" ] && [ -f "$S5_TXNDIR/old.state" ]; then
            _restore_events=$(cat "$S5_TEST_ROOT/transcript")
            (
                s5_precheck() { return 0; }
                s5_confirm_update() { printf 'update confirmation reached\n' >>"$S5_TEST_ROOT/transcript"; }
                s5_cmd_install
            ) >"$S5_TEST_ROOT/next-install.log" 2>&1
            assert_ne "a later install cannot overwrite pending recovery data" 0 "$?"
            if [ "$_restore_target" = state ]; then
                assert_contains "pending recovery is reported before asking to update" \
                    'pending recovery directory' "$(cat "$S5_TEST_ROOT/next-install.log")"
            fi
            assert_eq "a later install preserves retained config backup" "$_restore_cfg" \
                "$(t_sha256 "$S5_TXNDIR/old.config.json" 2>/dev/null)"
            assert_eq "a later install preserves retained state backup" "$_restore_state" \
                "$(t_sha256 "$S5_TXNDIR/old.state" 2>/dev/null)"
            assert_eq "a later install leaves the service untouched until recovery" \
                "$_restore_events" "$(cat "$S5_TEST_ROOT/transcript")"
            if [ ! -f "$S5_TXNDIR/old.config.json" ] || [ ! -f "$S5_TXNDIR/old.state" ]; then
                t_bad "a failed restore must retain both recovery backups before retry"
                continue
            fi
            ( s5_update_rollback "$S5_TXNDIR/old.config.json" "$S5_TXNDIR/old.state" ) \
                >"$S5_TEST_ROOT/retry.log" 2>&1
            assert_eq "retained backups allow a later restore" 0 "$?"
            t_xray_assert_healthy
            assert_file_absent "successful restore removes the transaction" "$S5_TXNDIR"
            assert_eq "successful restore starts the previous port" 23456 "$(cat "$S5_TEST_ROOT/svc_active")"
        else
            t_bad "a failed restore must retain both recovery backups"
        fi
    done
}

test_uninstall_unknown() {
    for _unknown_dir in config state binary transaction; do
        for _unknown_kind in file directory symlink; do
            t_xray_fixture 23456
            t_xray_install
            s5_precheck() { return 0; }
            case "$_unknown_dir" in
            config) _unknown_parent=$S5_SYSCONFDIR ;;
            state) _unknown_parent=$S5_STATEDIR ;;
            binary) _unknown_parent=$S5_PREFIX ;;
            transaction) _unknown_parent=$S5_TXNDIR; mkdir "$S5_TXNDIR" ;;
            esac
            _unknown_path=$_unknown_parent/operator-note
            case "$_unknown_kind" in
            file) printf 'preserve me\n' >"$_unknown_path" ;;
            directory) mkdir "$_unknown_path" ;;
            symlink) ln -s "$S5_TEST_ROOT/no-such-target" "$_unknown_path" ;;
            esac
            _unknown_hashes=$(sha256sum "$S5_CFG" "$S5_STATE" "$S5_BIN" "$S5_SERVICE_ARTIFACT")
            _unknown_events=$(cat "$S5_TEST_ROOT/transcript")
            printf 'y\n' >"$S5_TEST_ROOT/answers.uninstall"
            ( s5_cmd_uninstall <"$S5_TEST_ROOT/answers.uninstall" ) >"$S5_TEST_ROOT/uninstall.log" 2>&1
            assert_ne "$_unknown_dir $_unknown_kind refuses uninstall" 0 "$?"
            assert_eq "$_unknown_dir $_unknown_kind leaves every managed artifact unchanged" \
                "$_unknown_hashes" "$(sha256sum "$S5_CFG" "$S5_STATE" "$S5_BIN" "$S5_SERVICE_ARTIFACT" 2>/dev/null)"
            assert_eq "$_unknown_dir $_unknown_kind leaves the service untouched" \
                "$_unknown_events" "$(cat "$S5_TEST_ROOT/transcript")"
            assert_file_exists "refusal preserves the service account" "$S5_TEST_ROOT/user-exists"
            assert_file_exists "refusal preserves the service group" "$S5_TEST_ROOT/group-exists"
            if [ -e "$_unknown_path" ] || [ -L "$_unknown_path" ]; then t_ok; else t_bad 'unknown entry was deleted'; fi
            case "$_unknown_kind" in
            directory) rmdir "$_unknown_path" ;;
            *) rm -f "$_unknown_path" ;;
            esac
            ( s5_cmd_uninstall <"$S5_TEST_ROOT/answers.uninstall" ) >"$S5_TEST_ROOT/retry.log" 2>&1
            assert_eq "uninstall can retry after the unknown entry is removed" 0 "$?"
            assert_file_absent "successful retry removes the managed state" "$S5_STATE"
        done
    done
}

s5t_txn_fault() {
    if [ "$S5_LOCK_HELD" != 1 ] ||
        [ "$(cat "$S5_LOCK_OWNER" 2>/dev/null)" != "$S5_LOCK_TOKEN" ]; then
        printf 'unowned\n' >>"$S5_TEST_ROOT/txn.fault"
    else
        printf '%s\n' "$_txn_fault" >>"$S5_TEST_ROOT/txn.fault"
    fi
    t_sha256 "$S5_CFG" >"$S5_TEST_ROOT/txn.config-at-fault"
    return 1
}

s5t_txn_run() {
    _txn_fault=$1
    s5_precheck() { return 0; }
    case "$_txn_fault" in
    mkdir)
        mkdir() {
            if [ "${1:-}" = -m ] && [ "${3:-}" = "$S5_TXNDIR" ]; then
                s5t_txn_fault
            else
                command mkdir "$@"
            fi
        }
        ;;
    copy-config|copy-state)
        _txn_copy=$S5_TXNDIR/old.config.json
        [ "$_txn_fault" != copy-state ] || _txn_copy=$S5_TXNDIR/old.state
        cp() {
            if [ "${2:-}" = "$_txn_copy" ]; then s5t_txn_fault; else command cp "$@"; fi
        }
        ;;
    chmod)
        chmod() {
            if [ "${1:-}:${2:-}" = "0600:$S5_TXNDIR/old.config.json" ]; then
                s5t_txn_fault
            else
                command chmod "$@"
            fi
        }
        ;;
    stop|start|restart)
        # Delegate every other verb to the existing external fixture; do not
        # copy its service-state implementation into another failure double.
        systemctl() {
            if [ "${1:-}" = "$_txn_fault" ]; then
                s5t_txn_fault
            else
                "$S5_TEST_ROOT/bin/systemctl" "$@"
            fi
        }
        if [ "$_txn_fault" = restart ]; then s5_verify_dataplane() { return 1; }; fi
        ;;
    wait) s5_wait_stopped() { s5t_txn_fault; } ;;
    publish)
        _txn_publish_failed=0
        mv() {
            _txn_last=''
            for _txn_arg do _txn_last=$_txn_arg; done
            if [ "$_txn_last" = "$S5_CFG" ] && [ "$_txn_publish_failed" = 0 ]; then
                _txn_publish_failed=1
                s5t_txn_fault
            else
                command mv "$@"
            fi
        }
        ;;
    dataplane) s5_verify_dataplane() { s5t_txn_fault; } ;;
    state) s5_state_write() { s5t_txn_fault; } ;;
    *) return 2 ;;
    esac
    s5_prompt_port() { S5_PORT=24500; return 0; }
    s5_cmd_install
}

s5t_txn_case() {
    _txn_fault=$1
    t_xray_fixture 23456
    t_xray_install
    _txn_cfg=$(t_sha256 "$S5_CFG")
    _txn_state=$(t_sha256 "$S5_STATE")
    # The command owns its real lock and traps. Fault doubles cannot escape
    # this invocation into fixture initialization or a later scenario.
    ( s5t_txn_run "$_txn_fault" ) >"$S5_TEST_ROOT/txn.log" 2>&1
    _txn_status=$?
    assert_ne "$_txn_fault failure aborts command" 0 "$_txn_status"
    assert_contains "$_txn_fault reaches its fault while owning the lock" "$_txn_fault" \
        "$(cat "$S5_TEST_ROOT/txn.fault" 2>/dev/null)"
    assert_not_contains "$_txn_fault never retries after losing lock ownership" unowned \
        "$(cat "$S5_TEST_ROOT/txn.fault" 2>/dev/null)"
    assert_eq "$_txn_fault preserves config" "$_txn_cfg" "$(t_sha256 "$S5_CFG")"
    assert_eq "$_txn_fault preserves state" "$_txn_state" "$(t_sha256 "$S5_STATE")"
    assert_mode "$_txn_fault leaves private config permissions" 640 "$S5_CFG"
    assert_mode "$_txn_fault leaves private state permissions" 600 "$S5_STATE"
    assert_file_absent "$_txn_fault releases lock" "$S5_LOCKDIR"
    case "$_txn_fault" in
    start|dataplane|state)
        assert_ne "$_txn_fault occurs after candidate publication" "$_txn_cfg" \
            "$(cat "$S5_TEST_ROOT/txn.config-at-fault" 2>/dev/null)"
        ;;
    *)
        assert_eq "$_txn_fault observes the old published config" "$_txn_cfg" \
            "$(cat "$S5_TEST_ROOT/txn.config-at-fault" 2>/dev/null)"
        ;;
    esac
    case "$_txn_fault" in
    restart)
        assert_file_exists "restart failure retains config backup" "$S5_TXNDIR/old.config.json"
        assert_file_exists "restart failure retains state backup" "$S5_TXNDIR/old.state"
        assert_eq "config recovery copy retains original bytes" "$_txn_cfg" \
            "$(t_sha256 "$S5_TXNDIR/old.config.json")"
        assert_eq "state recovery copy retains original bytes" "$_txn_state" \
            "$(t_sha256 "$S5_TXNDIR/old.state")"
        assert_mode "config recovery copy remains private" 600 "$S5_TXNDIR/old.config.json"
        assert_mode "state recovery copy remains private" 600 "$S5_TXNDIR/old.state"
        ;;
    *) assert_file_absent "$_txn_fault cleanup removes the owned transaction" "$S5_TXNDIR" ;;
    esac
    case "$_txn_fault" in
    wait) assert_file_absent "failed stop observation does not claim a running service" "$S5_TEST_ROOT/svc_active" ;;
    restart) : ;;
    *) assert_eq "$_txn_fault leaves or restores the old listener" 23456 "$(cat "$S5_TEST_ROOT/svc_active")" ;;
    esac
}

test_txn_mkdir_failure() { s5t_txn_case mkdir; }
test_txn_copy_failure() {
    s5t_txn_case copy-config
    s5t_txn_case copy-state
}
test_txn_chmod_failure() { s5t_txn_case chmod; }
test_stop_failure() { s5t_txn_case stop; }
test_wait_stopped_failure() { s5t_txn_case wait; }
test_publication_failure() { s5t_txn_case publish; }
test_new_start_failure() { s5t_txn_case start; }
test_dataplane_failure() { s5t_txn_case dataplane; }
test_state_write_failure() { s5t_txn_case state; }
test_rollback_restart_failure() { s5t_txn_case restart; }

test_rollback_exit() {
    t_run python3 "$S5_REPO_ROOT/tests/lib/lock_reclaim.py" "$S5_REPO_ROOT/socks5.sh" \
        "${S5_TEST_SHELL:-sh}" rollback-exit
    assert_eq "EXIT cannot retry rollback while another command holds the lock" 0 "$T_STATUS"
    assert_contains "the competing operation retained its lock and recovery evidence" \
        'rollback stops before releasing operation lock' "$T_OUT"
}

test_uninstall_messages() {
    for _message_fault in account file; do
        for _message_lang in en zh; do
            t_xray_fixture 23456
            t_xray_install
            S5_LANG=$_message_lang
            s5_precheck() { return 0; }
            printf 'y\n' >"$S5_TEST_ROOT/answers.uninstall"
            T_OUT=$( (
                userdel() { return 1; }
                rm() {
                    if [ "$_message_fault" = file ] && [ "$*" = "-f $S5_SERVICE_ARTIFACT" ]; then return 1; fi
                    command rm "$@"
                }
                s5_cmd_uninstall <"$S5_TEST_ROOT/answers.uninstall"
            ) 2>&1) && T_STATUS=0 || T_STATUS=$?
            assert_ne "uninstall reports $_message_fault failure in $S5_LANG" 0 "$T_STATUS"
            case "$S5_LANG:$_message_fault" in
            en:account) _message_expected='[!] could not remove service account: xray-socks5' ;;
            zh:account) _message_expected='[!] 无法删除服务账户：xray-socks5。' ;;
            en:file) _message_expected="[!] could not remove owned file: $S5_SERVICE_ARTIFACT" ;;
            zh:file) _message_expected="[!] 无法删除自有文件：$S5_SERVICE_ARTIFACT。" ;;
            esac
            assert_contains "uninstall translates $_message_fault failure in $S5_LANG" "$_message_expected" "$T_OUT"
            assert_file_absent "failed uninstall releases the operation lock" "$S5_LOCKDIR"
        done
    done
}

test_uninstall_confirmation() {
    for _uninstall_answer in '' y Y yes YES Yes n eof prompt-failure; do
        t_xray_fixture 23456
        t_xray_install
        s5_precheck() { return 0; }
        if [ "$_uninstall_answer" = eof ]; then
            : >"$S5_TEST_ROOT/answers.uninstall"
        else
            printf '%s\n' "$_uninstall_answer" >"$S5_TEST_ROOT/answers.uninstall"
        fi
        T_OUT=$( (
            rmdir() {
                command rmdir "$@" || return $?
                if [ "$1" = "$S5_LOCKDIR" ]; then printf 'lock-released\n'; fi
            }
            if [ "$_uninstall_answer" = prompt-failure ]; then s5_msg() { return 1; }; fi
            s5_cmd_uninstall <"$S5_TEST_ROOT/answers.uninstall"
        ) 2>&1) && T_STATUS=0 || T_STATUS=$?
        case "$_uninstall_answer" in
        y|Y)
            assert_eq "uninstall accepts $_uninstall_answer" 0 "$T_STATUS"
            assert_file_absent "confirmed uninstall removes config" "$S5_CFG"
            ;;
        *)
            assert_eq "uninstall refuses a non-confirming answer" 1 "$T_STATUS"
            assert_file_exists "unconfirmed uninstall preserves config" "$S5_CFG"
            assert_eq "unconfirmed uninstall preserves the listener" 23456 "$(cat "$S5_TEST_ROOT/svc_active")"
            case "$_uninstall_answer" in
            eof|prompt-failure) assert_not_contains "failed input is not called cancellation" 'operation cancelled.' "$T_OUT" ;;
            *) assert_contains "uninstall unlocks before reporting cancellation" 'lock-released
operation cancelled.' "$T_OUT" ;;
            esac
            ;;
        esac
        assert_file_absent "uninstall confirmation leaves no lock" "$S5_LOCKDIR"
        assert_eq "uninstall confirmation releases its lock once" 1 "$(printf '%s\n' "$T_OUT" | grep -c '^lock-released$')"
    done
}

SCENARIOS='uninstall_confirmation uninstall_messages family update owned_port rejected_candidate listener_failure rejected_command publish_signal config_symlink uninstall_leftovers uninstall_residue verifier_cleanup txn_mkdir_failure txn_copy_failure txn_chmod_failure stop_failure wait_stopped_failure publication_failure new_start_failure dataplane_failure state_write_failure rollback_restart_failure restore_failure uninstall_unknown rollback_exit'
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
        t_bad "unknown update scenario: $scenario"
    fi
done
t_summary
