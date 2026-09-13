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
    _upcfg=$(sha256sum "$S5_CFG" | awk '{print $1}')
    _upstops=$(grep -c 'systemctl stop' "$S5_TEST_ROOT/transcript" || true)
    printf 1 >"$S5_TEST_ROOT/cfgtest"
    s5_prompt_port() { S5_PORT=24555; return 0; }
    t_run s5_install_update
    assert_ne "a rejected candidate config fails the update" 0 "$T_STATUS"
    assert_eq "the published config is untouched" \
        "$_upcfg" "$(sha256sum "$S5_CFG" | awk '{print $1}')"
    assert_eq "a healthy service is never stopped" \
        "$_upstops" "$(grep -c 'systemctl stop' "$S5_TEST_ROOT/transcript" || true)"
    assert_eq "the service keeps its previous port" 23999 "$(cat "$S5_TEST_ROOT/svc_active")"
}

test_listener_failure() {
    t_xray_fixture 23999
    t_xray_install
    # If the published config never reaches the listener, old config/state return.
    _upcfg=$(sha256sum "$S5_CFG" | awk '{print $1}')
    _upstate=$(sha256sum "$S5_STATE" | awk '{print $1}')
    s5_wait_listening() { return 1; }
    s5_prompt_port() { S5_PORT=24777; return 0; }
    t_run s5_install_update
    assert_ne "an unreachable listener fails the update" 0 "$T_STATUS"
    assert_eq "the old config is restored" \
        "$_upcfg" "$(sha256sum "$S5_CFG" | awk '{print $1}')"
    assert_eq "the old state is restored" \
        "$_upstate" "$(sha256sum "$S5_STATE" | awk '{print $1}')"
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
    _upcfg=$(sha256sum "$S5_CFG" | awk '{print $1}')
    _upstate=$(sha256sum "$S5_STATE" | awk '{print $1}')
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
        "$_upcfg" "$(sha256sum "$S5_CFG" | awk '{print $1}')"
    assert_eq "the live state is unchanged" \
        "$_upstate" "$(sha256sum "$S5_STATE" | awk '{print $1}')"
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
    _winold=$(sha256sum "$S5_CFG" | awk '{print $1}')
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
        "$_winold" "$(sha256sum "$S5_CFG" | awk '{print $1}')"
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
    # Split streams: merging the prompt with stdout hides its newline regression.
    s5_cmd_uninstall <"$S5_TEST_ROOT/answers.uninstall" \
        >"$S5_TEST_ROOT/uninst.out" 2>"$S5_TEST_ROOT/uninst.err" &&
        T_STATUS=0 || T_STATUS=$?
    assert_eq "uninstall completes despite an interrupted update's leftovers" 0 "$T_STATUS"
    assert_eq "the uninstall confirmation keeps the answer on its own line" 0 \
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
    _v1dir=$S5_TEST_ROOT/vtmp
    mkdir -p "$_v1dir"
    _v1cred=$_v1dir/.s5pass.leaked
    printf '%s\n%s\n' "$S5_USERNAME" "$S5_PASSWORD" >"$_v1cred"
    chmod 0600 "$_v1cred"
    S5_VERIFY_TEMP=$_v1cred
    s5_cleanup
    assert_file_absent "s5_cleanup releases the recorded verifier credential temp" "$_v1cred"
    assert_eq "s5_cleanup clears S5_VERIFY_TEMP after releasing it" '' "$S5_VERIFY_TEMP"
    s5_cleanup
    assert_file_absent "repeated cleanup does not recreate the verifier credential temp" "$_v1cred"
}

test_restore_failure() {
    for _restore_target in config state; do
        t_xray_fixture 23456
        t_xray_install
        _restore_cfg=$(sha256sum "$S5_CFG" | awk '{print $1}')
        _restore_state=$(sha256sum "$S5_STATE" | awk '{print $1}')
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
            "$_restore_cfg" "$(sha256sum "$S5_TXNDIR/old.config.json" 2>/dev/null | awk '{print $1}')"
        assert_eq "$_restore_target failure preserves old state through EXIT cleanup" \
            "$_restore_state" "$(sha256sum "$S5_TXNDIR/old.state" 2>/dev/null | awk '{print $1}')"
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
                "$(sha256sum "$S5_TXNDIR/old.config.json" 2>/dev/null | awk '{print $1}')"
            assert_eq "a later install preserves retained state backup" "$_restore_state" \
                "$(sha256sum "$S5_TXNDIR/old.state" 2>/dev/null | awk '{print $1}')"
            assert_eq "a later install leaves the service untouched until recovery" \
                "$_restore_events" "$(cat "$S5_TEST_ROOT/transcript")"
            if [ ! -f "$S5_TXNDIR/old.config.json" ] || [ ! -f "$S5_TXNDIR/old.state" ]; then
                continue
            fi
            ( s5_update_rollback "$S5_TXNDIR/old.config.json" "$S5_TXNDIR/old.state" ) \
                >"$S5_TEST_ROOT/retry.log" 2>&1
            assert_eq "retained backups allow a later restore" 0 "$?"
            t_xray_assert_healthy
            assert_file_absent "successful restore removes the transaction" "$S5_TXNDIR"
            assert_eq "successful restore starts the previous port" 23456 "$(cat "$S5_TEST_ROOT/svc_active")"
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

test_rollback_exit() {
    t_run python3 "$S5_REPO_ROOT/tests/lib/lock_reclaim.py" "$S5_REPO_ROOT/socks5.sh" \
        "${S5_TEST_SHELL:-sh}" rollback-exit
    assert_eq "EXIT cannot retry rollback while another command holds the lock" 0 "$T_STATUS"
    assert_contains "the competing operation retained its lock and recovery evidence" \
        'rollback stops before releasing operation lock' "$T_OUT"
}

# Optional scenario arguments support isolated runs, permutation and repetition.
if [ "$#" -eq 0 ]; then
    set -- family update owned_port rejected_candidate listener_failure rejected_command publish_signal config_symlink uninstall_leftovers uninstall_residue verifier_cleanup restore_failure uninstall_unknown rollback_exit
fi
for scenario do
    case "$scenario" in
    family|update|owned_port|rejected_candidate|listener_failure|rejected_command|publish_signal|config_symlink|uninstall_leftovers|uninstall_residue|verifier_cleanup|restore_failure|uninstall_unknown|rollback_exit)
        "test_$scenario" ;;
    *) t_bad "unknown update scenario: $scenario" ;;
    esac
done
t_summary
