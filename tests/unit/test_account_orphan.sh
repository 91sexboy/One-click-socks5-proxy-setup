#!/bin/sh
# tests/unit/test_account_orphan.sh - E2 regression: a principal that was created
# but whose numeric id could never be read must still be removable.
#
# s5_account_create runs the create tool first and reads the id afterwards, so
# there is a window in which the group (or the user) exists on the host and
# S5_CREATED_ACCOUNT_GID/UID are still empty. A failed read returns 1 from that
# window, and s5_pending_account_remove -- the mid-install rollback -- keyed
# entirely off those two ids: empty meant "nothing was created", so it deleted
# nothing and reported a clean rollback. The group stayed on the host with no
# state flag naming it, teardown never saw it, and every later install refused
# at the collision check forever. The user variant reported failure but likewise
# never deleted the account it had just made.
#
# The fingerprint exists to stop a name-only delete from removing a REPLACEMENT
# principal made by an unrelated workload. Inside this window there has been no
# opportunity for one: the script created the name moments ago and merely failed
# to learn its number. So removal by name is correct here, and must be proven by
# observing the principal absent afterwards -- an unqueryable identity database
# is a failed rollback, not a completed one. The control case below is what
# keeps that from degrading into "always delete by name".
#
# Own file, like test_account_tristate.sh: the stub markers here change what
# `getent` reports for the whole process.

S5T_NAME=test_account_orphan
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
. "${S5_REPO_ROOT}/tests/lib/stub.sh"
. "${S5_REPO_ROOT}/tests/lib/env.sh"

s5env_setup
s5env_load

S5_OS_FAMILY=debian

reset_identity_db() {
    printf '' >"$S5_TEST_ROOT/stub_passwd"
    printf '' >"$S5_TEST_ROOT/stub_group"
    rm -f "$S5_TEST_ROOT/stub_group_gid_blank" \
        "$S5_TEST_ROOT/stub_passwd_uid_blank" \
        "$S5_TEST_ROOT/stub_userdel_fail" \
        "$S5_TEST_ROOT/stub_groupdel_fail"
    S5_CREATED_ACCOUNT_UID=''
    S5_CREATED_ACCOUNT_GID=''
    S5_CREATED_USER_NAMED=0
    S5_CREATED_GROUP_NAMED=0
    s5env_reset_transcript
}

# t_run captures output in a command substitution, so the callee runs in a
# subshell and every global it sets is lost. What the rollback records about
# itself is the whole point here, so call directly and keep the output in a file.
run_pending() {
    s5_pending_account_remove >"$S5_TEST_ROOT/pending.out" 2>&1
    PEND_STATUS=$?
    PEND_OUT=$(cat "$S5_TEST_ROOT/pending.out")
}

group_state() {
    s5_group_exists
    GROUP_STATE=$?
}

user_state() {
    s5_account_exists
    USER_STATE=$?
}

# ==========================================================================
# Control, and it runs first: with no record of having created anything, a group
# that merely shares the fixed name is left alone. Deleting by name is licensed
# by "this run made it", not by the name matching.
# ==========================================================================
reset_identity_db
printf '%s\n' "$S5_SERVICE_GROUP" >"$S5_TEST_ROOT/stub_group"
run_pending
assert_eq "an empty rollback record succeeds" 0 "$PEND_STATUS"
group_state
assert_eq "a group this run did not create is never removed" 0 "$GROUP_STATE"
t_assert_cmd_never_called "and no delete tool is invoked at all" groupdel delgroup

# ==========================================================================
# The group was created and its gid was never readable. The old early exit read
# the empty fingerprint as "nothing to undo" and returned success.
# ==========================================================================
reset_identity_db
: >"$S5_TEST_ROOT/stub_group_gid_blank"
s5_account_create >"$S5_TEST_ROOT/create.out" 2>&1
CREATE_STATUS=$?
assert_ne "an unreadable gid fails the creation" 0 "$CREATE_STATUS"
assert_eq "and leaves no gid fingerprint" "" "$S5_CREATED_ACCOUNT_GID"
group_state
assert_eq "the fixture really did leave the group on the host" 0 "$GROUP_STATE"
run_pending
assert_eq "the rollback completes for a gid-less group" 0 "$PEND_STATUS"
group_state
assert_eq "the group created without a readable gid is provably gone" 1 "$GROUP_STATE"

# ==========================================================================
# The user was created and its uid was never readable. Here the group fingerprint
# does exist, so the old code reported failure -- but it never removed the user
# it had just made, which is what blocks every later install.
# ==========================================================================
reset_identity_db
: >"$S5_TEST_ROOT/stub_passwd_uid_blank"
s5_account_create >"$S5_TEST_ROOT/create.out" 2>&1
CREATE_STATUS=$?
assert_ne "an unreadable uid fails the creation" 0 "$CREATE_STATUS"
assert_eq "and leaves no uid fingerprint" "" "$S5_CREATED_ACCOUNT_UID"
user_state
assert_eq "the fixture really did leave the user on the host" 0 "$USER_STATE"
run_pending
assert_eq "the rollback completes for a uid-less user" 0 "$PEND_STATUS"
user_state
assert_eq "the user created without a readable uid is provably gone" 1 "$USER_STATE"
group_state
assert_eq "and its group goes with it" 1 "$GROUP_STATE"

# ==========================================================================
# A name-only removal is still only as good as its proof. A delete tool that
# fails leaves the principal there, and that is a failed rollback whose record
# must survive for a later retry.
# ==========================================================================
reset_identity_db
: >"$S5_TEST_ROOT/stub_passwd_uid_blank"
s5_account_create >"$S5_TEST_ROOT/create.out" 2>&1
: >"$S5_TEST_ROOT/stub_userdel_fail"
run_pending
rm -f "$S5_TEST_ROOT/stub_userdel_fail"
assert_ne "a surviving user is not a completed rollback" 0 "$PEND_STATUS"
assert_contains "the surviving user is named" "account still exists" "$PEND_OUT"
assert_eq "a failed name-only removal keeps its record" 1 "$S5_CREATED_USER_NAMED"

# ==========================================================================
# The same window reached through s5_cleanup. A signal arriving between the
# create tool and the id read leaves ONLY the named flags set, so the trap's
# gate has to read them too or the group is orphaned by the interrupt instead.
# ==========================================================================
reset_identity_db
: >"$S5_TEST_ROOT/stub_group_gid_blank"
s5_account_create >"$S5_TEST_ROOT/create.out" 2>&1
S5_WORKDIR=''
S5_PENDING_CLAIM_PATH=''
S5_RECONFIG_ARMED=0
S5_ROLLBACK_ARMED=0
S5_INSTALL_COMPLETE=0
S5_LOCK_HELD=0
S5_IN_CLEANUP=0
s5_cleanup >"$S5_TEST_ROOT/cleanup.out" 2>&1
group_state
assert_eq "cleanup unwinds a group whose gid was never read" 1 "$GROUP_STATE"

t_summary
