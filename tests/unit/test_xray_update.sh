#!/bin/sh
# Update transactions and cleanup, each starting at a fresh invocation boundary.

S5T_NAME=test_xray_update
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
. "${S5_REPO_ROOT}/tests/lib/xray-fixture.sh"

test_family() {
    t_xray_fixture 23456
    t_xray_install
    assert_eq "state records the installed port" 23456 "$(t_state_get port)"
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
    assert_eq "state records the new port" 23999 "$(t_state_get port)"
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
    chmod 0640 "$S5_CFG"
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
            # The next command recovers the complete pair before asking for a
            # new update, then may proceed through the ordinary update path.
            (
                s5_precheck() { return 0; }
                s5_confirm_update() { printf 'update confirmation reached\n' >>"$S5_TEST_ROOT/transcript"; }
                s5_cmd_install
            ) >"$S5_TEST_ROOT/next-install.log" 2>&1
            assert_eq "a later install recovers and completes" 0 "$?"
            assert_contains "recovery completes before asking to update"                 'update confirmation reached' "$(cat "$S5_TEST_ROOT/transcript")"
            assert_file_absent "successful recovery and update remove the transaction" "$S5_TXNDIR"
            t_xray_assert_healthy
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
    wait) assert_eq "failed stop observation restores the old listener" 23456         "$(cat "$S5_TEST_ROOT/svc_active")" ;;
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

test_uninstall_group_residue() {
    t_xray_fixture 23456
    s5_precheck() { return 0; }
    printf '900\n' >"$S5_TEST_ROOT/group-exists"
    printf 'y\n' >"$S5_TEST_ROOT/answers.uninstall"
    t_run s5_cmd_uninstall <"$S5_TEST_ROOT/answers.uninstall"
    assert_ne "group-only residue is not reported absent" 0 "$T_STATUS"
    assert_file_exists "foreign group-only residue is preserved" "$S5_TEST_ROOT/group-exists"
    rm -f "$S5_TEST_ROOT/group-exists"
    t_run s5_cmd_uninstall <"$S5_TEST_ROOT/answers.uninstall"
    assert_eq "clean namespace is idempotently absent after residue removal" 0 "$T_STATUS"
    s5_install_new
    assert_eq "fresh install succeeds after residue removal" 0 "$?"
}

s5t_uninstall_injector() {
    [ "$1" = "$S5T_UNINSTALL_FAIL_PHASE" ] || return 0
    [ -f "$S5_TEST_ROOT/uninstall-injected" ] && return 0
    : >"$S5_TEST_ROOT/uninstall-injected"
    return 79
}

test_uninstall_resume() {
    for _urp in prepared stopped disabled service-artifact-removed config-removed \
        binary-removed manager-reloaded account-removed state-finalizing complete; do
        t_xray_fixture 23456
        t_xray_install
        s5_precheck() { return 0; }
        printf 'y\n' >"$S5_TEST_ROOT/answers.uninstall"
        S5T_UNINSTALL_FAIL_PHASE=$_urp
        S5_UNINSTALL_INJECT=s5t_uninstall_injector
        t_run s5_cmd_uninstall <"$S5_TEST_ROOT/answers.uninstall"
        assert_ne "$_urp injection fails the first uninstall" 0 "$T_STATUS"
        assert_file_exists "$_urp injection leaves durable recovery" "$S5_UNINSTALL_STATE"
        unset S5_UNINSTALL_INJECT
        t_run s5_cmd_uninstall </dev/null
        assert_eq "$_urp recovery resumes in a fresh invocation" 0 "$T_STATUS"
        assert_file_absent "$_urp recovery removes state namespace" "$S5_STATEDIR"
        assert_file_absent "$_urp recovery removes binary namespace" "$S5_PREFIX"
        assert_file_absent "$_urp recovery removes config namespace" "$S5_SYSCONFDIR"
    done
}

s5t_uninstall_signal_injector() {
    [ "$1" = "$S5T_UNINSTALL_SIGNAL_PHASE" ] || return 0
    [ -f "$S5_TEST_ROOT/uninstall-signalled" ] && return 0
    : >"$S5_TEST_ROOT/uninstall-signalled"
    case "$S5T_UNINSTALL_SIGNAL" in
    HUP) s5_on_signal_lock 129 ;;
    INT) s5_on_signal_lock 130 ;;
    TERM) s5_on_signal_lock 143 ;;
    esac
}

test_uninstall_signal_resume() {
    for _ursig in HUP INT TERM; do
        t_xray_fixture 23456
        t_xray_install
        s5_precheck() { return 0; }
        printf 'y\n' >"$S5_TEST_ROOT/answers.uninstall"
        S5T_UNINSTALL_SIGNAL_PHASE=disabled
        S5T_UNINSTALL_SIGNAL=$_ursig
        S5_UNINSTALL_INJECT=s5t_uninstall_signal_injector
        ( s5_cmd_uninstall <"$S5_TEST_ROOT/answers.uninstall" ) \
            >"$S5_TEST_ROOT/uninstall-signal.log" 2>&1
        _urs=$?
        case "$_ursig" in HUP) _urwant=129 ;; INT) _urwant=130 ;; TERM) _urwant=143 ;; esac
        assert_eq "$_ursig preserves its signal status" "$_urwant" "$_urs"
        assert_file_exists "$_ursig leaves durable recovery" "$S5_UNINSTALL_STATE"
        unset S5_UNINSTALL_INJECT
        t_run s5_cmd_uninstall </dev/null
        assert_eq "$_ursig recovery resumes" 0 "$T_STATUS"
        assert_file_absent "$_ursig recovery removes state namespace" "$S5_STATEDIR"
    done
}

test_uninstall_resume_drift() {
    for _urd_phase in disabled service-artifact-removed config-removed; do
        t_xray_fixture 23456
        t_xray_install
        s5_precheck() { return 0; }
        printf 'y\n' >"$S5_TEST_ROOT/answers.uninstall"
        S5T_UNINSTALL_FAIL_PHASE=$_urd_phase
        S5_UNINSTALL_INJECT=s5t_uninstall_injector
        t_run s5_cmd_uninstall <"$S5_TEST_ROOT/answers.uninstall"
        assert_ne "$_urd_phase setup stops at its checkpoint" 0 "$T_STATUS"
        unset S5_UNINSTALL_INJECT
        case "$_urd_phase" in
        disabled) _urd_path=$S5_SERVICE_ARTIFACT ;;
        service-artifact-removed) _urd_path=$S5_CFG ;;
        config-removed) _urd_path=$S5_BIN ;;
        esac
        printf 'foreign replacement\n' >>"$_urd_path"
        _urd_hash=$(t_sha256 "$_urd_path")
        t_run s5_cmd_uninstall </dev/null
        assert_ne "$_urd_phase resume refuses replacement drift" 0 "$T_STATUS"
        assert_eq "$_urd_phase resume preserves the replacement" "$_urd_hash" \
            "$(t_sha256 "$_urd_path")"
        assert_file_exists "$_urd_phase drift retains recovery evidence" "$S5_UNINSTALL_STATE"
    done

    t_xray_fixture 23456
    t_xray_install
    s5_precheck() { return 0; }
    printf 'y\n' >"$S5_TEST_ROOT/answers.uninstall"
    S5T_UNINSTALL_FAIL_PHASE=disabled
    S5_UNINSTALL_INJECT=s5t_uninstall_injector
    t_run s5_cmd_uninstall <"$S5_TEST_ROOT/answers.uninstall"
    assert_ne "same-byte replacement setup stops at disabled" 0 "$T_STATUS"
    unset S5_UNINSTALL_INJECT
    cp "$S5_SERVICE_ARTIFACT" "$S5_TEST_ROOT/replacement-unit"
    chmod 0644 "$S5_TEST_ROOT/replacement-unit"
    rm "$S5_SERVICE_ARTIFACT"
    mv "$S5_TEST_ROOT/replacement-unit" "$S5_SERVICE_ARTIFACT"
    _urd_hash=$(t_sha256 "$S5_SERVICE_ARTIFACT")
    t_run s5_cmd_uninstall </dev/null
    assert_ne "resume refuses a same-byte service replacement" 0 "$T_STATUS"
    assert_eq "resume preserves the same-byte replacement" "$_urd_hash" \
        "$(t_sha256 "$S5_SERVICE_ARTIFACT")"

    t_xray_fixture 23456
    t_xray_install
    s5_precheck() { return 0; }
    printf 'y\n' >"$S5_TEST_ROOT/answers.uninstall"
    S5T_UNINSTALL_FAIL_PHASE=account-removed
    S5_UNINSTALL_INJECT=s5t_uninstall_injector
    t_run s5_cmd_uninstall <"$S5_TEST_ROOT/answers.uninstall"
    assert_ne "account-removed setup stops at its checkpoint" 0 "$T_STATUS"
    unset S5_UNINSTALL_INJECT
    printf '901\n' >"$S5_TEST_ROOT/group-exists"
    t_run s5_cmd_uninstall </dev/null
    assert_ne "resume refuses a recreated foreign group" 0 "$T_STATUS"
    assert_file_exists "resume preserves a recreated foreign group" "$S5_TEST_ROOT/group-exists"
    assert_file_exists "account drift retains recovery evidence" "$S5_UNINSTALL_STATE"
}

test_uninstall_phase_gap_resume() {
    for _ugr_case in disabled:unit service-artifact-removed:config config-removed:binary account-removed:state; do
        _ugr_phase=${_ugr_case%%:*}
        _ugr_resource=${_ugr_case#*:}
        t_xray_fixture 23456
        t_xray_install
        s5_precheck() { return 0; }
        printf 'y\n' >"$S5_TEST_ROOT/answers.uninstall"
        S5T_UNINSTALL_FAIL_PHASE=$_ugr_phase
        S5_UNINSTALL_INJECT=s5t_uninstall_injector
        t_run s5_cmd_uninstall <"$S5_TEST_ROOT/answers.uninstall"
        assert_ne "$_ugr_phase setup stops at its checkpoint" 0 "$T_STATUS"
        unset S5_UNINSTALL_INJECT
        case "$_ugr_resource" in
        unit) rm -f "$S5_SERVICE_ARTIFACT" ;;
        config) rm -f "$S5_CFG" ;;
        binary) rm -f "$S5_BIN" ;;
        state) rm -f "$S5_STATE" ;;
        esac
        t_run s5_cmd_uninstall </dev/null
        assert_eq "$_ugr_phase resumes when its next removal already completed" 0 "$T_STATUS"
        assert_file_absent "$_ugr_phase gap recovery removes state namespace" "$S5_STATEDIR"
    done
}

test_uninstall_final_window() {
    t_xray_fixture 23456
    t_xray_install
    s5_precheck() { return 0; }
    printf 'y\n' >"$S5_TEST_ROOT/answers.uninstall"
    S5T_UNINSTALL_FAIL_PHASE=complete-moved
    S5_UNINSTALL_INJECT=s5t_uninstall_injector
    t_run s5_cmd_uninstall <"$S5_TEST_ROOT/answers.uninstall"
    assert_ne "final-marker window fails the first uninstall" 0 "$T_STATUS"
    assert_file_exists "final-marker window retains ownership evidence" "$S5_UNINSTALL_FINAL"
    assert_file_absent "final-marker move removes the in-directory record" "$S5_UNINSTALL_STATE"
    unset S5_UNINSTALL_INJECT
    t_run s5_cmd_uninstall </dev/null
    assert_eq "final-marker window resumes" 0 "$T_STATUS"
    assert_file_absent "final-marker recovery removes the state directory" "$S5_STATEDIR"
    assert_file_absent "final-marker recovery removes its last marker" "$S5_UNINSTALL_FINAL"
}

s5t_make_older_state() {
    _mos_oldbin=$S5_TEST_ROOT/older-xray
    printf '#!/bin/sh\nprintf older\\n\n' >"$_mos_oldbin"
    chmod 0755 "$_mos_oldbin"
    cp "$_mos_oldbin" "$S5_BIN"
    _mos_sha=$(t_sha256 "$S5_BIN")
    _mos_size=$(wc -c <"$S5_BIN" | tr -d '[:space:]')
    awk -F '\t' -v sha="$_mos_sha" -v size="$_mos_size" '
        BEGIN { OFS="\t" }
        $1 == "release" { $2="v25.1.1" }
        $1 == "commit" { $2="1111111111111111111111111111111111111111" }
        $1 == "archive_size" { $2="123456" }
        $1 == "archive_sha256" { $2="2222222222222222222222222222222222222222222222222222222222222222" }
        $1 == "binary_size" { $2=size }
        $1 == "binary_sha256" { $2=sha }
        { print }
    ' "$S5_STATE" >"$S5_STATE.next"
    mv "$S5_STATE.next" "$S5_STATE"
    chmod 0600 "$S5_STATE"
}

test_older_release_operations() {
    t_xray_fixture 23999
    t_xray_install
    s5t_make_older_state
    s5_precheck() { return 0; }
    t_run s5_cmd_restart
    assert_eq "older release restart succeeds through the operate interface" 0 "$T_STATUS"
    assert_eq "older release restart keeps its installed listener" 23999 \
        "$(cat "$S5_TEST_ROOT/svc_active")"

    printf 'y\n' >"$S5_TEST_ROOT/answers.uninstall"
    t_run s5_cmd_uninstall <"$S5_TEST_ROOT/answers.uninstall"
    assert_eq "older release uninstall succeeds through the uninstall interface" 0 "$T_STATUS"
    assert_file_absent "older release uninstall removes the namespace" "$S5_STATEDIR"
    assert_file_absent "older release uninstall removes the binary" "$S5_BIN"
}

test_older_release_update() {
    t_xray_fixture 23999
    t_xray_install
    _oru_oldbin=$S5_TEST_ROOT/older-xray
    printf '#!/bin/sh\nprintf older\\n\n' >"$_oru_oldbin"
    chmod 0755 "$_oru_oldbin"
    cp "$_oru_oldbin" "$S5_BIN"
    _oru_oldsha=$(t_sha256 "$S5_BIN")
    awk -F '\t' -v sha="$_oru_oldsha" -v size="$(wc -c <"$S5_BIN" | tr -d '[:space:]')" '
        BEGIN { OFS="\t" }
        $1 == "release" { $2="v25.1.1" }
        $1 == "commit" { $2="1111111111111111111111111111111111111111" }
        $1 == "archive_size" { $2="123456" }
        $1 == "archive_sha256" { $2="2222222222222222222222222222222222222222222222222222222222222222" }
        $1 == "binary_size" { $2=size }
        $1 == "binary_sha256" { $2=sha }
        { print }
    ' "$S5_STATE" >"$S5_STATE.next"
    mv "$S5_STATE.next" "$S5_STATE"
    chmod 0600 "$S5_STATE"
    _oru_downloaded=0
    s5_download_engine() {
        _oru_downloaded=1
        cp "$S5_TEST_ROOT/asset-xray" "$S5_BIN"
        chmod 0755 "$S5_BIN"
        S5_BINARY_SHA256=$S5_ASSET_BINARY_SHA256
    }
    s5_prompt_port() { S5_PORT=23999; return 0; }
    s5_install_update
    assert_eq "older release updates successfully" 0 "$?"
    assert_eq "older release update downloads the current candidate" 1 "$_oru_downloaded"
    assert_eq "updated state records current release" "$S5_XRAY_VERSION" "$(t_state_get release)"
    assert_eq "updated binary matches current candidate" "$S5_ASSET_BINARY_SHA256" "$(t_sha256 "$S5_BIN")"
    t_xray_assert_healthy
}

test_older_release_download_failure() {
    t_xray_fixture 23999
    t_xray_install
    _ord_bin=$(t_sha256 "$S5_BIN")
    _ord_cfg=$(t_sha256 "$S5_CFG")
    awk -F '\t' '
        BEGIN { OFS="\t" }
        $1 == "release" { $2="v25.1.1" }
        $1 == "commit" { $2="1111111111111111111111111111111111111111" }
        $1 == "archive_size" { $2="123456" }
        $1 == "archive_sha256" { $2="2222222222222222222222222222222222222222222222222222222222222222" }
        { print }
    ' "$S5_STATE" >"$S5_STATE.next"
    mv "$S5_STATE.next" "$S5_STATE"
    chmod 0600 "$S5_STATE"
    _ord_state=$(t_sha256 "$S5_STATE")
    s5_download_engine() { printf 'candidate bytes\n' >"$S5_BIN"; return 1; }
    s5_prompt_port() { S5_PORT=23999; return 0; }
    s5_install_update
    assert_ne "older release candidate download failure aborts update" 0 "$?"
    s5_cleanup
    assert_eq "download failure restores the exact installed binary" "$_ord_bin" "$(t_sha256 "$S5_BIN")"
    assert_eq "download failure preserves config" "$_ord_cfg" "$(t_sha256 "$S5_CFG")"
    assert_eq "download failure preserves historical state" "$_ord_state" "$(t_sha256 "$S5_STATE")"
    assert_eq "download failure never stops the old listener" 23999 "$(cat "$S5_TEST_ROOT/svc_active")"
    assert_file_absent "download failure removes transaction evidence" "$S5_TXNDIR"
}

test_transaction_contract_drift() {
    for _tcd_path in old.config.json old.state old.xray committed stopping; do
        t_xray_fixture 23999
        t_xray_install
        mkdir -m 0700 "$S5_TXNDIR"
        case "$_tcd_path" in
        old.config.json) cp "$S5_CFG" "$S5_TXNDIR/old.config.json" ;;
        old.state) cp "$S5_STATE" "$S5_TXNDIR/old.state" ;;
        old.xray) cp "$S5_BIN" "$S5_TXNDIR/old.xray" ;;
        committed) printf 'committed\n' >"$S5_TXN_COMMITTED" ;;
        stopping) printf 'stopping\n' >"$S5_TXN_STOPPING" ;;
        esac
        chmod 0644 "$S5_TXNDIR/$_tcd_path"
        t_run s5_transaction_recover
        assert_ne "transaction rejects mode drift on $_tcd_path" 0 "$T_STATUS"
        assert_file_exists "transaction preserves drifted $_tcd_path" "$S5_TXNDIR/$_tcd_path"
    done

    t_xray_fixture 23999
    t_xray_install
    mkdir -m 0700 "$S5_TXNDIR"
    cp "$S5_BIN" "$S5_TXNDIR/old.xray"
    chmod 0600 "$S5_TXNDIR/old.xray"
    assert_mode "binary recovery backup is data-only" 600 "$S5_TXNDIR/old.xray"
    s5_cleanup_transaction
    assert_eq "valid binary backup cleanup succeeds" 0 "$?"
}

test_rollback_backup_drift() {
    for _rbd_target in config state binary; do
        t_xray_fixture 23456
        t_xray_install
        mkdir -m 0700 "$S5_TXNDIR"
        cp "$S5_CFG" "$S5_TXNDIR/old.config.json"
        cp "$S5_STATE" "$S5_TXNDIR/old.state"
        chmod 0600 "$S5_TXNDIR/old.config.json" "$S5_TXNDIR/old.state"
        case "$_rbd_target" in
        config) printf 'foreign config\n' >>"$S5_TXNDIR/old.config.json" ;;
        state) printf 'foreign\tfield\n' >>"$S5_TXNDIR/old.state" ;;
        binary)
            cp "$S5_BIN" "$S5_TXNDIR/old.xray"
            chmod 0600 "$S5_TXNDIR/old.xray"
            printf 'foreign binary\n' >>"$S5_TXNDIR/old.xray" ;;
        esac
        _rbd_live_cfg=$(t_sha256 "$S5_CFG")
        _rbd_live_state=$(t_sha256 "$S5_STATE")
        t_run s5_update_rollback "$S5_TXNDIR/old.config.json" "$S5_TXNDIR/old.state"
        assert_ne "rollback refuses $_rbd_target backup drift" 0 "$T_STATUS"
        assert_eq "$_rbd_target drift leaves live config unchanged" \
            "$_rbd_live_cfg" "$(t_sha256 "$S5_CFG")"
        assert_eq "$_rbd_target drift leaves live state unchanged" \
            "$_rbd_live_state" "$(t_sha256 "$S5_STATE")"
        assert_dir_exists "$_rbd_target drift retains recovery evidence" "$S5_TXNDIR"
    done
}

test_uninstall_directory_drift() {
    for _udd_case in state-finalizing:config state-finalizing:prefix complete-moved:state; do
        _udd_phase=${_udd_case%%:*}
        _udd_dir=${_udd_case#*:}
        t_xray_fixture 23456
        t_xray_install
        s5_precheck() { return 0; }
        printf 'y\n' >"$S5_TEST_ROOT/answers.uninstall"
        S5T_UNINSTALL_FAIL_PHASE=$_udd_phase
        S5_UNINSTALL_INJECT=s5t_uninstall_injector
        t_run s5_cmd_uninstall <"$S5_TEST_ROOT/answers.uninstall"
        assert_ne "$_udd_phase setup reaches directory window" 0 "$T_STATUS"
        unset S5_UNINSTALL_INJECT
        case "$_udd_dir" in
        config) _udd_path=$S5_SYSCONFDIR ;;
        prefix) _udd_path=$S5_PREFIX ;;
        state) _udd_path=$S5_STATEDIR ;;
        esac
        _udd_hold=$S5_TEST_ROOT/held-$_udd_dir
        mv "$_udd_path" "$_udd_hold"
        case "$_udd_dir" in state) _udd_mode=0700 ;; prefix) _udd_mode=0755 ;; config) _udd_mode=0750 ;; esac
        mkdir -m "$_udd_mode" "$_udd_path"
        t_run s5_cmd_uninstall </dev/null
        assert_ne "$_udd_phase refuses replaced $_udd_dir directory" 0 "$T_STATUS"
        assert_dir_exists "$_udd_phase preserves replaced $_udd_dir directory" "$_udd_path"
    done
}

test_transaction_all_commands() {
    for _tac_command in status restart uninstall; do
        t_xray_fixture 23999
        t_xray_install
        s5_precheck() { return 0; }
        mkdir -m 0700 "$S5_TXNDIR"
        cp "$S5_CFG" "$S5_TXNDIR/old.config.json"
        cp "$S5_STATE" "$S5_TXNDIR/old.state"
        chmod 0600 "$S5_TXNDIR/old.config.json" "$S5_TXNDIR/old.state"
        case "$_tac_command" in
        status) t_run s5_cmd_status ;;
        restart) t_run s5_cmd_restart ;;
        uninstall)
            printf 'n\n' >"$S5_TEST_ROOT/answers.uninstall"
            t_run s5_cmd_uninstall <"$S5_TEST_ROOT/answers.uninstall" ;;
        esac
        case "$_tac_command" in uninstall) assert_ne "uninstall cancellation stays nonzero" 0 "$T_STATUS" ;; *) assert_eq "$_tac_command succeeds after recovery" 0 "$T_STATUS" ;; esac
        assert_file_absent "$_tac_command leaves no pre-stop transaction residue" "$S5_TXNDIR"
    done

    t_xray_fixture 23999
    t_xray_install
    mkdir -m 0700 "$S5_TXNDIR"
    cp "$S5_CFG" "$S5_TXNDIR/old.config.json"
    cp "$S5_STATE" "$S5_TXNDIR/old.state"
    chmod 0600 "$S5_TXNDIR/old.config.json" "$S5_TXNDIR/old.state"
    printf 'committed\n' >"$S5_TXN_COMMITTED"
    chmod 0600 "$S5_TXN_COMMITTED"
    printf 'drift\n' >>"$S5_CFG"
    t_run s5_open_managed_state inspect
    assert_eq "committed cleanup refuses invalid new state" 5 "$T_STATUS"
    assert_file_exists "committed cleanup preserves old config backup on drift" "$S5_TXNDIR/old.config.json"
    assert_file_exists "committed cleanup preserves old state backup on drift" "$S5_TXNDIR/old.state"
    assert_file_exists "committed cleanup preserves its marker on drift" "$S5_TXN_COMMITTED"
}

test_sha256_binary_update_failure() {
    t_xray_fixture 23999
    t_xray_install
    _sbu_old_bin=$(t_sha256 "$S5_BIN")
    _sbu_old_cfg=$(t_sha256 "$S5_CFG")
    _sbu_old_state=$(t_sha256 "$S5_STATE")
    awk -F '\t' '
        BEGIN { OFS="\t" }
        $1 == "release" { $2="v25.1.1" }
        $1 == "commit" { $2="1111111111111111111111111111111111111111" }
        $1 == "archive_size" { $2="123456" }
        $1 == "archive_sha256" { $2="2222222222222222222222222222222222222222222222222222222222222222" }
        { print }
    ' "$S5_STATE" >"$S5_STATE.next"
    mv "$S5_STATE.next" "$S5_STATE"
    chmod 0600 "$S5_STATE"
    _sbu_old_state=$(t_sha256 "$S5_STATE")
    s5_download_engine() {
        printf '#!/bin/sh\nprintf candidate\\n\n' >"$S5_BIN"
        chmod 0755 "$S5_BIN"
        s5_record_digest binary "$S5_BIN" || return 1
        S5_BINARY_SHA256=$S5_RECORDED_DIGEST
        return 91
    }
    s5_prompt_port() { S5_PORT=23999; return 0; }
    s5_install_update
    assert_ne "candidate binary digest/download failure aborts update" 0 "$?"
    s5_cleanup
    assert_eq "candidate failure restores the exact old binary" "$_sbu_old_bin" "$(t_sha256 "$S5_BIN")"
    assert_eq "candidate failure preserves config" "$_sbu_old_cfg" "$(t_sha256 "$S5_CFG")"
    assert_eq "candidate failure preserves historical state" "$_sbu_old_state" "$(t_sha256 "$S5_STATE")"
    assert_eq "candidate failure keeps the old listener" 23999 "$(cat "$S5_TEST_ROOT/svc_active")"
    assert_file_absent "candidate failure removes transaction evidence" "$S5_TXNDIR"
}

test_transaction_unknown_residue() {
    for _tur_kind in file directory symlink; do
        t_xray_fixture 23999
        t_xray_install
        mkdir -m 0700 "$S5_TXNDIR"
        cp "$S5_CFG" "$S5_TXNDIR/old.config.json"
        cp "$S5_STATE" "$S5_TXNDIR/old.state"
        chmod 0600 "$S5_TXNDIR/old.config.json" "$S5_TXNDIR/old.state"
        _tur_path=$S5_TXNDIR/operator-note
        case "$_tur_kind" in
        file) printf 'preserve\n' >"$_tur_path" ;;
        directory) mkdir "$_tur_path" ;;
        symlink) ln -s "$S5_TEST_ROOT/no-target" "$_tur_path" ;;
        esac
        _tur_cfg=$(t_sha256 "$S5_TXNDIR/old.config.json")
        _tur_state=$(t_sha256 "$S5_TXNDIR/old.state")
        t_run s5_transaction_recover
        assert_ne "unknown transaction $_tur_kind is refused" 0 "$T_STATUS"
        assert_eq "$_tur_kind refusal preserves config recovery evidence" \
            "$_tur_cfg" "$(t_sha256 "$S5_TXNDIR/old.config.json")"
        assert_eq "$_tur_kind refusal preserves state recovery evidence" \
            "$_tur_state" "$(t_sha256 "$S5_TXNDIR/old.state")"
        if [ -e "$_tur_path" ] || [ -L "$_tur_path" ]; then t_ok; else t_bad "$_tur_kind residue was deleted"; fi
    done
}

test_sha256_config_update_failure() {
    t_xray_fixture 23999
    t_xray_install
    _sdu_cfg=$(t_sha256 "$S5_CFG")
    _sdu_state=$(t_sha256 "$S5_STATE")
    _sdu_real_sha=/usr/bin/sha256sum
    [ -x "$_sdu_real_sha" ] || _sdu_real_sha=/bin/sha256sum
    _sdu_fail=1
    s5_sha256_command() {
        if [ "$_sdu_fail" = 1 ] && [ "$1" = "$S5_CFG" ] &&
            [ "$(cat "$S5_TEST_ROOT/svc_active" 2>/dev/null)" = 24777 ]; then
            return 91
        fi
        "$_sdu_real_sha" "$1"
    }
    s5_prompt_port() { S5_PORT=24777; return 0; }
    s5_install_update >"$S5_TEST_ROOT/update-digest.log" 2>&1
    assert_ne "config digest failure aborts update" 0 "$?"
    assert_contains "update digest failure has a specific diagnosis" \
        'could not compute SHA-256 for installed artifact: config' \
        "$(cat "$S5_TEST_ROOT/update-digest.log")"
    assert_eq "update digest failure restores exact old config" \
        "$_sdu_cfg" "$(t_sha256 "$S5_CFG")"
    assert_eq "update digest failure restores exact old state" \
        "$_sdu_state" "$(t_sha256 "$S5_STATE")"
    assert_eq "update digest failure restores old listener" 23999 \
        "$(cat "$S5_TEST_ROOT/svc_active")"
    assert_file_absent "update digest rollback removes transaction" "$S5_TXNDIR"
    _sdu_fail=0
    t_xray_assert_healthy
}

test_update_commit_cleanup_failure() {
    for _ucc_fault in first second rmdir; do
        t_xray_fixture 23999
        t_xray_install
        _ucc_old_state=$(t_sha256 "$S5_STATE")
        _ucc_real_rm=/usr/bin/rm
        _ucc_real_rmdir=/usr/bin/rmdir
        [ -x "$_ucc_real_rm" ] || _ucc_real_rm=/bin/rm
        [ -x "$_ucc_real_rmdir" ] || _ucc_real_rmdir=/bin/rmdir
        _ucc_fired=0
        rm() {
            if [ "$_ucc_fault" = first ] && [ "${2:-}" = "$S5_TXNDIR/old.config.json" ] && [ "$_ucc_fired" = 0 ]; then
                _ucc_fired=1; return 71
            fi
            if [ "$_ucc_fault" = second ] && [ "${2:-}" = "$S5_TXNDIR/old.state" ] && [ "$_ucc_fired" = 0 ]; then
                _ucc_fired=1; return 72
            fi
            "$_ucc_real_rm" "$@"
        }
        rmdir() {
            if [ "$_ucc_fault" = rmdir ] && [ "${1:-}" = "$S5_TXNDIR" ] && [ "$_ucc_fired" = 0 ]; then
                _ucc_fired=1; return 73
            fi
            "$_ucc_real_rmdir" "$@"
        }
        s5_prompt_port() { S5_PORT=24777; return 0; }
        s5_install_update >"$S5_TEST_ROOT/commit-cleanup.log" 2>&1
        assert_ne "$_ucc_fault post-commit cleanup failure is reported" 0 "$?"
        assert_file_exists "$_ucc_fault leaves a committed marker" "$S5_TXN_COMMITTED"
        assert_ne "$_ucc_fault keeps the new state authoritative" \
            "$_ucc_old_state" "$(t_sha256 "$S5_STATE")"
        assert_eq "$_ucc_fault leaves the new listener active" 24777 \
            "$(cat "$S5_TEST_ROOT/svc_active")"
        assert_contains "$_ucc_fault explains delete-only retry" \
            'next operation will retry cleanup' "$(cat "$S5_TEST_ROOT/commit-cleanup.log")"
        _ucc_fired=1
        s5_transaction_recover
        assert_eq "$_ucc_fault cleanup retries deterministically" 0 "$?"
        assert_file_absent "$_ucc_fault retry removes transaction" "$S5_TXNDIR"
        t_xray_assert_healthy
    done
}

SCENARIOS='uninstall_confirmation uninstall_messages family update owned_port rejected_candidate listener_failure rejected_command publish_signal config_symlink uninstall_leftovers uninstall_residue verifier_cleanup txn_mkdir_failure txn_copy_failure txn_chmod_failure stop_failure wait_stopped_failure publication_failure new_start_failure dataplane_failure state_write_failure rollback_restart_failure restore_failure uninstall_unknown rollback_exit uninstall_group_residue uninstall_resume uninstall_signal_resume uninstall_resume_drift uninstall_phase_gap_resume uninstall_final_window older_release_operations older_release_update older_release_download_failure transaction_contract_drift rollback_backup_drift uninstall_directory_drift transaction_all_commands transaction_unknown_residue sha256_binary_update_failure sha256_config_update_failure update_commit_cleanup_failure'
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
