#!/bin/sh
# The shared cleanup seam of the systemd gate, the memory report and the
# nonprivileged process test. The caller supplies work and
# lifecycle_cleanup_namespace (external teardown), and may supply
# lifecycle_cleanup_children for helpers of its own to stop before the target.
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
    if command -v lifecycle_cleanup_children >/dev/null 2>&1; then
        lifecycle_cleanup_children || true
    fi
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
    lifecycle_stop_child "$_lst_pid"
}

# lifecycle_stop_child <pid>: TERM a direct child, KILL it after three seconds,
# and reap it.
lifecycle_stop_child() {
    kill -TERM "$1" 2>/dev/null || true
    lifecycle_wait_until 30 0.1 lifecycle_child_gone "$1" ||
        kill -KILL "$1" 2>/dev/null || true
    wait "$1" 2>/dev/null || true
}

lifecycle_child_gone() { ! kill -0 "$1" 2>/dev/null; }
