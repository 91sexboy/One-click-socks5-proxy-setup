#!/bin/sh
# tests/unit/test_account_tristate.sh - regression: an identity database that
# cannot be queried is never proof that a principal is absent.
#
# s5_account_exists and s5_group_exists both answer three ways: 0 present,
# 1 definitely absent, 2 the database could not be queried. s5_account_remove
# dispatches all three through a case. s5_pending_account_remove -- the
# mid-install rollback that undoes a group created before its fingerprint could
# be persisted -- ended with a bare `if s5_group_exists`, which is true only for
# status 0. Status 2 therefore fell through to success: it reported a clean
# rollback, cleared S5_CREATED_ACCOUNT_GID (the only record that this run created
# the group), and left the group on the host with no state flag to remove it by,
# after which every later install refused at the collision check forever.
#
# This file lives apart from test_account.sh because it substitutes
# s5_group_exists, and a shell has no way to restore a shadowed function: an
# `unset -f` would delete the real one for every case that followed. Nothing
# here needs it back.

S5T_NAME=test_account_tristate
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
. "${S5_REPO_ROOT}/tests/lib/stub.sh"
. "${S5_REPO_ROOT}/tests/lib/env.sh"

s5env_setup
s5env_load

S5_OS_FAMILY=debian

# A group this run created, with the user already gone -- the exact state
# s5_pending_account_remove exists to unwind.
prepare_group_only() {
    printf '' >"$S5_TEST_ROOT/stub_passwd"
    printf '' >"$S5_TEST_ROOT/stub_group"
    s5_account_create >/dev/null 2>&1
    _pend_gid=$(s5_current_gid)
    printf '' >"$S5_TEST_ROOT/stub_passwd"
    S5_CREATED_ACCOUNT_UID=''
    S5_CREATED_ACCOUNT_GID=$_pend_gid
    s5env_reset_transcript
}

# t_run captures output in a command substitution, so the callee runs in a
# subshell and every global it sets is lost. The fingerprint is the whole point
# here, so call directly and keep the output in a file.
run_pending() {
    s5_pending_account_remove >"$S5_TEST_ROOT/pending.out" 2>&1
    PEND_STATUS=$?
    PEND_OUT=$(cat "$S5_TEST_ROOT/pending.out")
}

# ==========================================================================
# The group is provably gone: the rollback completes and drops the fingerprint.
# This runs first so the refusal below cannot pass for a build that simply
# refuses everything.
# ==========================================================================
prepare_group_only
assert_ne "the fixture recorded a group fingerprint" "" "$_pend_gid"
run_pending
assert_eq "a provably removed group completes the rollback" 0 "$PEND_STATUS"
assert_eq "a completed rollback clears the fingerprint" "" "$S5_CREATED_ACCOUNT_GID"

# ==========================================================================
# The group survives and is observable: that is a failed rollback, and the
# fingerprint must be kept so a later uninstall can still act on it.
# ==========================================================================
prepare_group_only
: >"$S5_TEST_ROOT/stub_groupdel_fail"
run_pending
rm -f "$S5_TEST_ROOT/stub_groupdel_fail"
assert_ne "a surviving group is not a completed rollback" 0 "$PEND_STATUS"
assert_contains "the surviving group is named" "group still exists" "$PEND_OUT"
assert_eq "a failed rollback keeps the fingerprint" "$_pend_gid" "$S5_CREATED_ACCOUNT_GID"

# ==========================================================================
# The group's presence cannot be observed at all. Not proof of absence.
# ==========================================================================
prepare_group_only
s5_group_exists() { return 2; }
run_pending
assert_ne "an unobservable group is not a completed rollback" 0 "$PEND_STATUS"
assert_contains "the unobservable group is named" "could not determine" "$PEND_OUT"
assert_eq "the fingerprint survives an unobservable query" \
    "$_pend_gid" "$S5_CREATED_ACCOUNT_GID"
t_assert_cmd_never_called "an unobservable query claims no removal" groupadd useradd

t_summary
