#!/bin/sh
# Shared fixtures, bounded waits and credential checks for native lifecycle gates.
#
# lifecycle_write_fixtures <workdir>: write the install and in-place-update answer
# and password files into <workdir> and lock them to 0600. The in-place update
# rotates to ciuser2/CISecret_456~y on the same port, which each gate then asserts
# landed in the config and the state.
lifecycle_write_fixtures() {
    _lcw=$1
    printf 'ciuser\nCISecret_123~x\n' >"$_lcw/pass"
    printf 'ciuser2\nCISecret_456~y\n' >"$_lcw/pass.update"
    { printf '2\ny\n23456\n'; cat "$_lcw/pass"; } >"$_lcw/answers"
    { printf 'y\n23456\n'; cat "$_lcw/pass.update"; } >"$_lcw/answers.update"
    : >"$_lcw/answers.empty"
    printf 'y\n' >"$_lcw/answers.uninstall"
    chmod 0600 "$_lcw/answers" "$_lcw/pass" "$_lcw/answers.update" "$_lcw/pass.update" \
        "$_lcw/answers.empty" "$_lcw/answers.uninstall"
}

lifecycle_wait_until() {
    _lcwu_attempts=$1
    _lcwu_interval=$2
    shift 2
    _lcwu_count=0
    while [ "$_lcwu_count" -lt "$_lcwu_attempts" ]; do
        _lcwu_count=$((_lcwu_count + 1))
        if "$@"; then return 0; fi
        sleep "$_lcwu_interval"
    done
    return 1
}

lifecycle_no_credential_in() {
    _lcn_file=$1
    _lcn_secret=$2
    shift 2
    _lcn_status=0
    "$@" grep -qF -- "$_lcn_secret" "$_lcn_file" 2>/dev/null || _lcn_status=$?
    case "$_lcn_status" in
    1) return 0 ;;
    0) printf 'a credential reached %s\n' "$_lcn_file" >&2 ;;
    *) printf 'the credential check on %s failed with status %s\n' "$_lcn_file" "$_lcn_status" >&2 ;;
    esac
    return 1
}

lifecycle_assert_logs_redacted() {
    _lalr_work=$1
    shift
    if [ "$#" -gt 0 ]; then
        _lalr_install=$("$@" sed -n '2p' "$_lalr_work/pass") || return 1
        _lalr_update=$("$@" sed -n '2p' "$_lalr_work/pass.update") || return 1
    else
        _lalr_install=$(sed -n '2p' "$_lalr_work/pass") || return 1
        _lalr_update=$(sed -n '2p' "$_lalr_work/pass.update") || return 1
    fi
    # Each command log is checked against every credential generation that
    # existed when the command ran. This list is the shared lifecycle contract.
    lifecycle_no_credential_in "$_lalr_work/install.log" "$_lalr_install" "$@" || return 1
    for _lalr_log in update.log status.log restart.log uninstall.log uninstall-second.log; do
        lifecycle_no_credential_in "$_lalr_work/$_lalr_log" "$_lalr_install" "$@" || return 1
        lifecycle_no_credential_in "$_lalr_work/$_lalr_log" "$_lalr_update" "$@" || return 1
    done
    # Reinstall rotates back to the install fixture, so its own log and the final
    # uninstall may contain that username by design but neither password.
    lifecycle_no_credential_in "$_lalr_work/reinstall.log" "$_lalr_install" "$@" || return 1
    lifecycle_no_credential_in "$_lalr_work/uninstall-reinstall.log" "$_lalr_install" "$@" || return 1
}
