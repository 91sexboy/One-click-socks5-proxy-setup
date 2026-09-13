#!/bin/sh
# Shared cleanup seam for the systemd gate and its nonprivileged process test.
# The caller supplies work and lifecycle_cleanup_namespace (external teardown).
lifecycle_cleanup_init() {
    target_pid=''
    trap 'lifecycle_cleanup "$?"; exit "$?"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

lifecycle_cleanup() {
    # Keep the primary error; otherwise make the first cleanup error fail the gate.
    _lc_status=${1:-0}
    # Don't re-enter if a second signal arrives while stopping the target.
    trap '' HUP INT TERM
    lifecycle_stop_target
    if lifecycle_cleanup_namespace; then :; else
        _lc_failure=$?
        printf 'lifecycle: namespace cleanup failed with status %s\n' "$_lc_failure" >&2
        [ "$_lc_status" -ne 0 ] || _lc_status=$_lc_failure
    fi
    # work is the caller's mktemp directory, retained until the child is reaped.
    # shellcheck disable=SC2154
    if rm -rf "$work"; then :; else
        _lc_failure=$?
        printf 'lifecycle: workdir cleanup failed with status %s\n' "$_lc_failure" >&2
        [ "$_lc_status" -ne 0 ] || _lc_status=$_lc_failure
    fi
    return "$_lc_status"
}

# target_pid is assigned only from the caller's own $!.
# Stop and reap that direct child before deleting any of its output paths.
lifecycle_stop_target() {
    [ -n "${target_pid:-}" ] || return 0
    _lst_pid=$target_pid
    target_pid=''
    kill -TERM "$_lst_pid" 2>/dev/null || true
    _lst_tries=0
    while kill -0 "$_lst_pid" 2>/dev/null && [ "$_lst_tries" -lt 30 ]; do
        sleep 0.1
        _lst_tries=$((_lst_tries + 1))
    done
    if kill -0 "$_lst_pid" 2>/dev/null; then
        kill -KILL "$_lst_pid" 2>/dev/null || true
    fi
    wait "$_lst_pid" 2>/dev/null || true
}
