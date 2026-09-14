#!/bin/sh
# Account identity and stale-lock ownership regressions.
#
# s5_account_identity must confirm the service group name still maps to the
# recorded GID on every backend, not only Alpine. account_identity gates
# account_remove, which deletes the group by name (groupdel/delgroup), so a
# same-named group that drifted to a different GID would otherwise be deleted --
# SPEC 7 removes only the resources this installation recorded.

S5T_NAME=test_xray_hardening
# shellcheck source=/dev/null
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
ROOT=${S5_REPO_ROOT}
t_mktestroot
t_source_production ''
S5_LANG=en

# id reports the recorded identity for the user; the group's GID is whatever the
# scenario file holds. Shell functions shadow the applets under BusyBox too, where
# applet names resolve before PATH.
S5_ACCOUNT_UID=900
S5_ACCOUNT_GID=900
id() { case "${1:-}" in -u) printf 900 ;; -g) printf 900 ;; *) return 1 ;; esac; }
getent() {
    [ "${1:-}" = group ] || return 0
    printf '%s:x:%s:\n' "$2" "$(cat "$S5_TEST_ROOT/groupgid" 2>/dev/null)"
}

for _fam in debian el alpine; do
    S5_OS_FAMILY=$_fam
    printf '900\n' >"$S5_TEST_ROOT/groupgid"
    s5_account_identity
    assert_eq "$_fam: a group mapping to the recorded GID passes identity" 0 "$?"
    printf '777\n' >"$S5_TEST_ROOT/groupgid"
    s5_account_identity
    assert_ne "$_fam: a same-named group at a different GID fails identity" 0 "$?"
done

unset -f id getent

t_run python3 "$ROOT/tests/lib/lock_reclaim.py" "$ROOT/socks5.sh" "${S5_TEST_SHELL:-sh}"
assert_eq "a paused stale-lock reclaimer cannot remove a new live lock" 0 "$T_STATUS"
assert_contains "the interleaving reaches the lock ownership assertions" \
    'stale-lock interleaving preserves mutual exclusion' "$T_OUT"

t_summary
