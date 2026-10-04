#!/bin/sh
# Uninstall recovery: a resumed uninstall re-establishes what its recorded phase
# can no longer prove. The durable phase says which work is done, not that the
# service is still stopped, and not that a group name still resolves.

S5T_NAME=test_xray_uninstall_recovery
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
. "${S5_REPO_ROOT}/tests/lib/xray-fixture.sh"

s5t_recovery_injector() {
    [ "$1" = "$S5T_RECOVERY_PHASE" ] || return 0
    [ -f "$S5_TEST_ROOT/recovery-injected" ] && return 0
    : >"$S5_TEST_ROOT/recovery-injected"
    return 79
}

# s5t_interrupted_uninstall <phase>: an installed fixture whose uninstall stopped
# right after recording <phase>, so that phase's step has not run yet.
# complete-moved stops after the record became the final marker.
s5t_interrupted_uninstall() {
    t_xray_install
    s5_precheck_host() { return 0; }; s5_precheck_tools() { return 0; }
    sleep() { :; }
    printf 'y\n' >"$S5_TEST_ROOT/answers.uninstall"
    S5T_RECOVERY_PHASE=$1
    S5_UNINSTALL_INJECT=s5t_recovery_injector
    t_run s5_cmd_uninstall <"$S5_TEST_ROOT/answers.uninstall"
    unset S5_UNINSTALL_INJECT
    assert_ne "uninstall is interrupted at $1" 0 "$T_STATUS"
    case "$1" in
    complete-moved) _sti_record=$S5_UNINSTALL_FINAL; _sti_phase=complete ;;
    *) _sti_record=$S5_UNINSTALL_STATE; _sti_phase=$1 ;;
    esac
    assert_eq "the interrupted uninstall records $1" "$_sti_phase" \
        "$(awk -F '\t' '$1 == "phase" { print $2 }' "$_sti_record" 2>/dev/null)"
    : >"$S5_TEST_ROOT/transcript"
}

s5t_assert_uninstalled() {
    assert_file_absent "$1 removes the service artifact" "$S5_SERVICE_ARTIFACT"
    assert_file_absent "$1 removes the config namespace" "$S5_SYSCONFDIR"
    assert_file_absent "$1 removes the binary namespace" "$S5_PREFIX"
    assert_file_absent "$1 removes the state namespace" "$S5_STATEDIR"
    assert_file_absent "$1 removes the service user" "$S5_TEST_ROOT/user-exists"
    assert_file_absent "$1 removes the service group" "$S5_TEST_ROOT/group-exists"
}

# A reboot between the stopped checkpoint and disable starts the still-enabled
# unit again. Resume must stop it before disabling or deleting anything.
test_systemd_running_again_before_resume() {
    for _srr_phase in stopped disabled; do
        t_xray_fixture 23456
        s5t_interrupted_uninstall "$_srr_phase"
        assert_file_absent "the $_srr_phase checkpoint left the service stopped" \
            "$S5_TEST_ROOT/svc_active"
        printf '23456\n' >"$S5_TEST_ROOT/svc_active"
        t_run s5_cmd_uninstall </dev/null
        assert_eq "resume at $_srr_phase stops a service running again" 0 "$T_STATUS"
        assert_file_absent "resume at $_srr_phase leaves the service stopped" \
            "$S5_TEST_ROOT/svc_active"
        assert_eq "resume at $_srr_phase stops before any manager change" \
            'systemctl stop xray-socks5.service' \
            "$(grep -v 'is-active' "$S5_TEST_ROOT/transcript" | head -n 1)"
        s5t_assert_uninstalled "resume at $_srr_phase"
    done
}

# s5t_assert_retained <label>: nothing past the recorded stop boundary went.
s5t_assert_retained() {
    assert_file_exists "$1 keeps the service artifact" "$S5_SERVICE_ARTIFACT"
    assert_file_exists "$1 keeps the config" "$S5_CFG"
    assert_file_exists "$1 keeps the binary" "$S5_BIN"
    assert_file_exists "$1 keeps the service user" "$S5_TEST_ROOT/user-exists"
    assert_file_exists "$1 keeps the service group" "$S5_TEST_ROOT/group-exists"
    assert_file_exists "$1 keeps its recovery record" "$S5_UNINSTALL_STATE"
    assert_eq "$1 never disables or reloads the manager" '' \
        "$(grep -e disable -e daemon-reload "$S5_TEST_ROOT/transcript")"
}

# s5t_resume_with_systemd <stuck|unknown>: resume while the manager refuses to
# give stop evidence -- a stop that fails with the unit still active, or a unit
# that never leaves an unproven state.
s5t_resume_with_systemd() (
    S5T_SYSTEMD_FAULT=$1
    systemctl() {
        case "$S5T_SYSTEMD_FAULT:$1" in
        stuck:stop) printf 'systemctl stop\n' >>"$S5_TEST_ROOT/transcript"; return 1 ;;
        unknown:is-active) printf 'activating\n'; return 3 ;;
        esac
        command systemctl "$@"
    }
    s5_cmd_uninstall </dev/null
)

test_systemd_unproven_stop_keeps_resources() {
    for _sus_fault in stuck unknown; do
        t_xray_fixture 23456
        s5t_interrupted_uninstall stopped
        printf '23456\n' >"$S5_TEST_ROOT/svc_active"
        t_run s5t_resume_with_systemd "$_sus_fault"
        assert_ne "the $_sus_fault service refuses the resumed uninstall" 0 "$T_STATUS"
        assert_contains "the $_sus_fault service names the unproven stop" \
            'could not verify that the Xray service stopped; the interrupted uninstall kept its remaining resources.' \
            "$T_OUT"
        s5t_assert_retained "the $_sus_fault service"
        assert_file_absent "the $_sus_fault service releases the operation lock" "$S5_LOCKDIR"
        # Once the service really stops, the same record finishes the uninstall.
        t_run s5_cmd_uninstall </dev/null
        assert_eq "resume after the $_sus_fault service stops completes" 0 "$T_STATUS"
        s5t_assert_uninstalled "resume after the $_sus_fault service stops"
    done
}

# s5t_openrc_fixture <port>: OpenRC as Alpine runs it. rc-service answers only
# while its init script exists -- without one it says the service does not exist
# and exits 1 -- and a crashed marker makes status report 32 and stop fail.
s5t_openrc_fixture() {
    t_xray_openrc_fixture "$1"
    S5T_INITSCRIPT=$S5_SERVICE_ARTIFACT
    export S5T_INITSCRIPT
    t_stub rc-service <<'RCSERVICE'
#!/bin/sh
printf 'rc-service %s\n' "$*" >>"$S5_TEST_ROOT/transcript"
[ -f "$S5T_INITSCRIPT" ] || exit 1
case "$2" in
start|restart)
    port=$(sed -n 's/^[[:space:]]*"port":[[:space:]]*\([0-9][0-9]*\),*/\1/p' \
        "$S5_STUB_CFG" | head -n 1)
    printf '%s\n' "$port" >"$S5_TEST_ROOT/svc_active"
    ;;
stop)
    [ ! -f "$S5_TEST_ROOT/rc-crashed" ] || exit 1
    rm -f "$S5_TEST_ROOT/svc_active"
    ;;
status)
    [ ! -f "$S5_TEST_ROOT/rc-crashed" ] || exit 32
    [ -f "$S5_TEST_ROOT/svc_active" ] && exit 0
    exit 3
    ;;
esac
exit 0
RCSERVICE
    mkdir -p "$S5_OPENRC_OPTION_DIR"
}

# OpenRC's stopped (3) is the only proof while the init script exists; a service
# started again is stopped again, and a crashed one keeps everything.
test_openrc_running_again_before_resume() {
    s5t_openrc_fixture 23456
    s5t_interrupted_uninstall stopped
    printf '23456\n' >"$S5_TEST_ROOT/svc_active"
    t_run s5_cmd_uninstall </dev/null
    assert_eq "OpenRC resume stops a service running again" 0 "$T_STATUS"
    assert_eq "OpenRC resume stops before any manager change" \
        'rc-service xray-socks5 stop' \
        "$(grep -v ' status$' "$S5_TEST_ROOT/transcript" | head -n 1)"
    s5t_assert_uninstalled "OpenRC resume"

    s5t_openrc_fixture 23456
    s5t_interrupted_uninstall stopped
    : >"$S5_TEST_ROOT/rc-crashed"
    t_run s5_cmd_uninstall </dev/null
    assert_ne "OpenRC resume refuses a crashed service" 0 "$T_STATUS"
    assert_contains "OpenRC crashed resume names the unproven stop" \
        'could not verify that the Xray service stopped' "$T_OUT"
    s5t_assert_retained "OpenRC crashed resume"
}

# s5t_child <none|stale|live|unreadable|empty>: what supervise-daemon left in
# child_pid when the init script was already gone.
s5t_child() {
    rm -rf "$S5_OPENRC_OPTION_DIR/child_pid"
    case "$1" in
    none) ;;
    stale)
        sh -c 'exit 0' &
        _sc_pid=$!
        wait "$_sc_pid"
        printf '%s\n' "$_sc_pid" >"$S5_OPENRC_OPTION_DIR/child_pid"
        ;;
    live)
        command sleep 60 &
        S5T_LIVE_CHILD=$!
        printf '%s\n' "$S5T_LIVE_CHILD" >"$S5_OPENRC_OPTION_DIR/child_pid"
        ;;
    unreadable) mkdir "$S5_OPENRC_OPTION_DIR/child_pid" ;;
    empty) : >"$S5_OPENRC_OPTION_DIR/child_pid" ;;
    esac
}

# Once the init script is gone rc-service cannot answer at all, so a legitimate
# late recovery must not depend on it; the supervised child is the evidence. No
# child, or one that has exited, lets recovery finish; a live or unreadable record
# keeps every remaining resource.
test_openrc_late_phase_child_evidence() {
    for _sol_phase in service-artifact-removed account-removed state-finalizing complete-moved; do
        for _sol_child in none stale live unreadable empty; do
            s5t_openrc_fixture 23456
            s5t_interrupted_uninstall "$_sol_phase"
            S5T_LIVE_CHILD=''
            s5t_child "$_sol_child"
            t_run s5_cmd_uninstall </dev/null
            [ -z "$S5T_LIVE_CHILD" ] || kill "$S5T_LIVE_CHILD" 2>/dev/null || true
            case "$_sol_child" in
            none | stale)
                assert_eq "OpenRC $_sol_phase resume with $_sol_child child completes" 0 "$T_STATUS"
                assert_file_absent "OpenRC $_sol_phase resume with $_sol_child child removes state" \
                    "$S5_STATEDIR"
                assert_file_absent "OpenRC $_sol_phase resume with $_sol_child child removes its marker" \
                    "$S5_UNINSTALL_FINAL"
                ;;
            *)
                assert_ne "OpenRC $_sol_phase resume refuses the $_sol_child child" 0 "$T_STATUS"
                assert_contains "OpenRC $_sol_phase $_sol_child child names the unproven stop" \
                    'could not verify that the Xray service stopped' "$T_OUT"
                if [ -f "$S5_UNINSTALL_FINAL" ]; then
                    assert_file_exists "OpenRC $_sol_phase $_sol_child child keeps the final marker" \
                        "$S5_UNINSTALL_FINAL"
                else
                    assert_file_exists "OpenRC $_sol_phase $_sol_child child keeps its record" \
                        "$S5_UNINSTALL_STATE"
                fi
                assert_dir_exists "OpenRC $_sol_phase $_sol_child child keeps the state directory" \
                    "$S5_STATEDIR"
                ;;
            esac
            [ -z "$S5T_LIVE_CHILD" ] || wait "$S5T_LIVE_CHILD" 2>/dev/null || true
        done
    done
}

# An interrupted uninstall has stopped the service and may have removed part of
# it. restart and update would start it again under a record that says it is
# stopped, so both refuse and leave the record for uninstall to finish.
test_pending_uninstall_refuses_restart_and_update() {
    for _spu_phase in stopped disabled complete-moved; do
        t_xray_fixture 23456
        s5t_interrupted_uninstall "$_spu_phase"
        for _spu_command in restart install; do
            t_run "s5_cmd_$_spu_command" </dev/null
            assert_ne "$_spu_command refuses a pending uninstall at $_spu_phase" 0 "$T_STATUS"
            assert_contains "$_spu_command names the pending uninstall at $_spu_phase" \
                'an interrupted uninstall is pending; run uninstall to finish it.' "$T_OUT"
            assert_file_absent "$_spu_command at $_spu_phase leaves the service stopped" \
                "$S5_TEST_ROOT/svc_active"
            assert_eq "$_spu_command at $_spu_phase never starts the service" '' \
                "$(grep -e start -e enable "$S5_TEST_ROOT/transcript")"
            assert_file_absent "$_spu_command at $_spu_phase releases the operation lock" \
                "$S5_LOCKDIR"
        done
        t_run s5_cmd_uninstall </dev/null
        assert_eq "uninstall still finishes after refused commands at $_spu_phase" 0 "$T_STATUS"
        s5t_assert_uninstalled "uninstall after refused commands at $_spu_phase"
    done
}

# s5t_enforce_ownership: ownership checks run for real against fixture-controlled
# owners. The harness skips them because a non-root test cannot chown; here stat
# reports the owners root would have given -- the config directory and file to
# root and the service group, everything else to root -- or an override from
# $S5_TEST_ROOT/owners ("path uid:gid" lines). Names resolve the way GNU stat
# resolves them: a GID with no group behind it prints UNKNOWN, so deleting the
# fixture group makes its name vanish while the numbers stay.
s5t_enforce_ownership() {
    S5_SKIP_OWNERSHIP=0
    chown() { :; }
    stat() {
        case "$1:${2:-}" in
        '-c:%U:%G %a' | '-c:%u:%g %a') ;;
        *) command stat "$@"; return $? ;;
        esac
        _seo_mode=$(command stat -c '%a' "$3") || return 1
        _seo_ids=$(awk -v p="$3" '$1 == p { ids=$2 } END { print ids }' \
            "$S5_TEST_ROOT/owners" 2>/dev/null)
        if [ -z "$_seo_ids" ]; then
            case "$3" in
            "$S5_SYSCONFDIR" | "$S5_CFG") _seo_ids=0:900 ;;
            *) _seo_ids=0:0 ;;
            esac
        fi
        if [ "$2" = '%u:%g %a' ]; then
            printf '%s %s\n' "$_seo_ids" "$_seo_mode"
            return 0
        fi
        _seo_user=UNKNOWN
        [ "${_seo_ids%%:*}" != 0 ] || _seo_user=root
        case "${_seo_ids#*:}" in
        0) _seo_group=root ;;
        "$(cat "$S5_TEST_ROOT/group-exists" 2>/dev/null)") _seo_group=xray-socks5 ;;
        *) _seo_group=UNKNOWN ;;
        esac
        printf '%s:%s %s\n' "$_seo_user" "$_seo_group" "$_seo_mode"
    }
}

# s5t_account_gone: the account removal ran but its checkpoint was never written.
s5t_account_gone() {
    rm -f "$S5_TEST_ROOT/user-exists" "$S5_TEST_ROOT/group-exists"
}

# The baseline: with real ownership checks an uninterrupted uninstall still
# completes, so the shim reports what an installation really looks like.
test_owned_uninstall_baseline() {
    t_xray_fixture 23456
    t_xray_install
    s5_precheck_host() { return 0; }; s5_precheck_tools() { return 0; }
    s5t_enforce_ownership
    printf 'y\n' >"$S5_TEST_ROOT/answers.uninstall"
    t_run s5_cmd_uninstall <"$S5_TEST_ROOT/answers.uninstall"
    assert_eq "an owned uninstall completes with ownership enforced" 0 "$T_STATUS"
    s5t_assert_uninstalled "an owned uninstall"
}

# Once the service group is deleted its name no longer resolves, but the config
# directory still carries the recorded GID until state-finalizing removes it.
# Recovery compares the recorded numbers, so every window between the group's
# deletion and the directory's removal resumes.
test_group_deleted_before_directory_removal() {
    for _sgd_case in manager-reloaded:gone account-removed: state-finalizing:; do
        _sgd_phase=${_sgd_case%%:*}
        t_xray_fixture 23456
        s5t_interrupted_uninstall "$_sgd_phase"
        [ -z "${_sgd_case#*:}" ] || s5t_account_gone
        assert_file_absent "the group is gone at $_sgd_phase" "$S5_TEST_ROOT/group-exists"
        assert_dir_exists "the config directory remains at $_sgd_phase" "$S5_SYSCONFDIR"
        t_run s5t_resume_owned
        assert_eq "resume at $_sgd_phase accepts the recorded numeric owner" 0 "$T_STATUS"
        s5t_assert_uninstalled "resume at $_sgd_phase"
    done
}

s5t_resume_owned() (
    s5t_enforce_ownership
    s5_cmd_uninstall </dev/null
)

# Numbers do not loosen anything else: a different GID or UID, a replaced or
# symlinked directory, a changed mode, or a same-named group recreated with
# another GID still keep the directory and the record.
test_group_deleted_identity_mismatch() {
    for _sgm_case in gid uid inode mode symlink regroup; do
        t_xray_fixture 23456
        s5t_interrupted_uninstall account-removed
        case "$_sgm_case" in
        gid) printf '%s 0:901\n' "$S5_SYSCONFDIR" >"$S5_TEST_ROOT/owners" ;;
        uid) printf '%s 900:900\n' "$S5_SYSCONFDIR" >"$S5_TEST_ROOT/owners" ;;
        inode)
            # Created while the original still exists, so the replacement
            # cannot reuse its inode number.
            mv "$S5_SYSCONFDIR" "$S5_TEST_ROOT/original-confdir"
            mkdir "$S5_SYSCONFDIR"
            chmod 0750 "$S5_SYSCONFDIR"
            rmdir "$S5_TEST_ROOT/original-confdir"
            ;;
        mode) chmod 0755 "$S5_SYSCONFDIR" ;;
        symlink)
            mv "$S5_SYSCONFDIR" "$S5_TEST_ROOT/moved-confdir"
            ln -s "$S5_TEST_ROOT/moved-confdir" "$S5_SYSCONFDIR"
            ;;
        regroup)
            printf '901\n' >"$S5_TEST_ROOT/group-exists"
            printf '%s 0:901\n' "$S5_SYSCONFDIR" >"$S5_TEST_ROOT/owners"
            ;;
        esac
        t_run s5t_resume_owned
        assert_ne "resume refuses a config directory with a different $_sgm_case" 0 "$T_STATUS"
        assert_contains "the $_sgm_case mismatch is reported as unsafe residue" \
            'refusing uninstall with unknown or unsafe residue' "$T_OUT"
        assert_file_exists "the $_sgm_case mismatch keeps the recovery record" "$S5_UNINSTALL_STATE"
        if [ "$_sgm_case" = symlink ]; then
            assert_dir_exists "the symlink mismatch keeps the moved directory" "$S5_TEST_ROOT/moved-confdir"
        else
            assert_dir_exists "the $_sgm_case mismatch keeps the config directory" "$S5_SYSCONFDIR"
        fi
    done
}

SCENARIOS='systemd_running_again_before_resume systemd_unproven_stop_keeps_resources'
SCENARIOS="$SCENARIOS openrc_running_again_before_resume openrc_late_phase_child_evidence"
SCENARIOS="$SCENARIOS pending_uninstall_refuses_restart_and_update owned_uninstall_baseline"
SCENARIOS="$SCENARIOS group_deleted_before_directory_removal group_deleted_identity_mismatch"
t_run_scenarios uninstall_recovery "$@"
t_summary
