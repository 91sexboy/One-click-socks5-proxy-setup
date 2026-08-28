#!/bin/sh
# tests/unit/test_account.sh - H4 regression: account removal is verified,
# never assumed, and a failure is reported rather than swallowed.

S5T_NAME=test_account
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
. "${S5_REPO_ROOT}/tests/lib/stub.sh"
. "${S5_REPO_ROOT}/tests/lib/env.sh"

s5env_setup
s5env_account_stubs
s5env_load

reset_db() {
    : >"$S5_TEST_ROOT/stub_passwd"
    : >"$S5_TEST_ROOT/stub_group"
    rm -f "$S5_TEST_ROOT/stub_userdel_fail" "$S5_TEST_ROOT/stub_groupdel_fail" \
        "$S5_TEST_ROOT/stub_no_userdel" "$S5_TEST_ROOT/stub_no_deluser" \
        "$S5_TEST_ROOT/stub_getent_error"
    s5env_reset_transcript
}

# ==========================================================================
# No unconditional `|| true` around the deletion tools.
# ==========================================================================
if grep -nE '(userdel|deluser|groupdel|delgroup) "\$S5_SERVICE_(USER|GROUP)" 2>/dev/null \|\| true' "${S5_SRC}"; then
    t_bad "deletion failures are still swallowed with || true"
else
    t_ok
fi

# ==========================================================================
# Debian family: create then remove, verified at each step.
# ==========================================================================
reset_db
S5_OS_FAMILY=debian
if s5_account_exists; then t_bad "account should not exist yet"; else t_ok; fi
t_run s5_account_create
assert_eq "account created on debian" 0 "$T_STATUS"
t_assert_called "useradd used" 'useradd'
if s5_account_exists; then t_ok; else t_bad "account should exist after creation"; fi
if s5_group_exists; then t_ok; else t_bad "group should exist after creation"; fi

s5env_reset_transcript
t_run s5_account_remove 1 900 900
assert_eq "removal succeeds and is verified" 0 "$T_STATUS"
t_assert_called "userdel used on debian" 'userdel'
t_assert_called "groupdel used on debian" 'groupdel'
if s5_account_exists; then t_bad "account should be gone"; else t_ok; fi
if s5_group_exists; then t_bad "group should be gone"; else t_ok; fi

# ==========================================================================
# Alpine family uses deluser/delgroup.
# ==========================================================================
reset_db
S5_OS_FAMILY=alpine
assert_eq "nologin path on alpine" "/sbin/nologin" "$(s5_nologin_path)"
t_run s5_account_create
assert_eq "account created on alpine" 0 "$T_STATUS"
t_assert_called "adduser used on alpine" 'adduser'
s5env_reset_transcript
t_run s5_account_remove 1 900 900
assert_eq "alpine removal succeeds" 0 "$T_STATUS"
t_assert_called "deluser tried first on alpine" 'deluser'
if s5_account_exists; then t_bad "alpine account should be gone"; else t_ok; fi

# ==========================================================================
# Deletion command FAILS -> reported, non-zero, account still listed.
# ==========================================================================
reset_db
S5_OS_FAMILY=debian
s5_account_create >/dev/null 2>&1
: >"$S5_TEST_ROOT/stub_userdel_fail"
s5env_reset_transcript
t_run s5_account_remove 1 900 900
assert_ne "a failing userdel is reported as a failure" 0 "$T_STATUS"
assert_contains "names the surviving account" "socks5proxy" "$T_OUT"
assert_contains "says it still exists" "still exists" "$T_OUT"
if s5_account_exists; then t_ok; else t_bad "the account should still exist"; fi

# ==========================================================================
# Tool exits 0 but the account survives -> still a failure (no assumed success).
# ==========================================================================
reset_db
s5_account_create >/dev/null 2>&1
: >"$S5_TEST_ROOT/stub_no_userdel"
t_run s5_account_remove 1 900 900
assert_ne "exit 0 with a surviving account is still a failure" 0 "$T_STATUS"
assert_contains "reports the survivor" "still exists" "$T_OUT"

# ==========================================================================
# Partial deletion: user removed, group survives -> failure.
# ==========================================================================
reset_db
s5_account_create >/dev/null 2>&1
: >"$S5_TEST_ROOT/stub_groupdel_fail"
t_run s5_account_remove 1 900 900
assert_ne "partial deletion is a failure" 0 "$T_STATUS"
assert_contains "names the surviving group" "group still exists" "$T_OUT"
if s5_account_exists; then t_bad "user should be gone"; else t_ok; fi
if s5_group_exists; then t_ok; else t_bad "group should still be there"; fi

# ==========================================================================
# ==========================================================================
# An NSS query error is not proof that the account is absent. Teardown must
# retain the account and report failure rather than deleting proxy resources
# around an unobservable identity.
# ==========================================================================
reset_db
S5_OS_FAMILY=debian
s5_account_create >/dev/null 2>&1
: >"$S5_TEST_ROOT/stub_getent_error"
s5env_reset_transcript
t_run s5_account_remove 1 900 900
assert_ne "account query failure is a removal failure" 0 "$T_STATUS"
assert_contains "account query failure is named" "could not determine" "$T_OUT"
t_assert_never_called "query failure does not attempt user deletion" 'userdel'
t_assert_never_called "query failure does not attempt group deletion" 'groupdel'
rm -f "$S5_TEST_ROOT/stub_getent_error"

# Collision checks also fail closed when NSS is unavailable; install must not
# proceed to create a same-named account on an unobservable namespace.
reset_db
: >"$S5_TEST_ROOT/stub_getent_error"
t_run s5_collision_check
assert_ne "collision query failure blocks installation" 0 "$T_STATUS"
assert_contains "collision query failure is named" "could not determine" "$T_OUT"
t_assert_never_called "collision query failure creates no account" 'useradd'
rm -f "$S5_TEST_ROOT/stub_getent_error"

# Low-level account creation must keep the same fail-closed identity invariant as
# collision detection. A direct NSS query error is not evidence that the group is
# absent, so neither group nor user creation may proceed.
reset_db
: >"$S5_TEST_ROOT/stub_getent_error"
t_run s5_account_create
assert_ne "account creation rejects an unobservable group" 0 "$T_STATUS"
assert_contains "account creation names the group query failure" "could not determine" "$T_OUT"
t_assert_never_called "group query failure creates no group" 'groupadd'
t_assert_never_called "group query failure creates no account" 'useradd'
rm -f "$S5_TEST_ROOT/stub_getent_error"

# ==========================================================================
# A pre-existing project group is a namespace collision, not something install
# may adopt: users already in it would gain read access to the 0640 password file.
# ==========================================================================
reset_db
printf 'socks5proxy\n' >"$S5_TEST_ROOT/stub_group"
t_run s5_collision_check
assert_ne "a pre-existing service group blocks installation" 0 "$T_STATUS"
assert_contains "the collision names the group" "group already exists" "$T_OUT"
t_assert_never_called "collision creates no account" 'useradd'

# ==========================================================================
# A group we did NOT create is never touched by the low-level removal helper.
reset_db
printf 'socks5proxy\n' >"$S5_TEST_ROOT/stub_group"
S5_OS_FAMILY=debian
s5_account_create >/dev/null 2>&1
s5env_reset_transcript
t_run s5_account_remove 0 900
assert_eq "removal succeeds without touching the pre-existing group" 0 "$T_STATUS"
t_assert_never_called "groupdel is never called for a foreign group" 'groupdel'
if s5_group_exists; then t_ok; else t_bad "a pre-existing group must survive"; fi

# ==========================================================================
# The collision check runs before the confirmation prompt, the package
# installation and the three value prompts -- a long window. The re-check
# inside s5_install_steps used to ACCEPT identities that appeared inside it,
# silently adopting a foreign account, writing the plaintext credentials
# root:<that group> 0640, and never recording ownership. Appearing after the
# collision check is a race, and the answer to a race is refusal.
# ==========================================================================
reset_db
S5_OS_FAMILY=debian
rm -rf "$S5_STATEDIR" "$S5_SYSCONFDIR" "$S5_PREFIX"
s5_state_begin >/dev/null 2>&1
printf 'socks5proxy\n' >"$S5_TEST_ROOT/stub_passwd"
s5env_reset_transcript
t_run s5_install_steps
assert_ne "install aborts when the account appears after the collision check" \
    0 "$T_STATUS"
assert_contains "the abort says the identity appeared" "appeared" "$T_OUT"
t_assert_never_called "no foreign account is adopted" 'useradd'
assert_file_absent "no credentials are written for a foreign identity" "$S5_USERSCFG"

reset_db
rm -rf "$S5_STATEDIR" "$S5_SYSCONFDIR" "$S5_PREFIX"
s5_state_begin >/dev/null 2>&1
printf 'socks5proxy\n' >"$S5_TEST_ROOT/stub_group"
s5env_reset_transcript
t_run s5_install_steps
assert_ne "install aborts when the group appears after the collision check" \
    0 "$T_STATUS"
assert_contains "the abort names the group" "group" "$T_OUT"
t_assert_never_called "no foreign group is adopted" 'groupadd'

# ==========================================================================
# Ownership fingerprints. The fixed names can be removed and recreated by an
# unrelated workload between install and uninstall; state records the numeric
# uid/gid this script created, and removal verifies the names still answer to
# those numbers before deleting anything.
# ==========================================================================
reset_db
S5_OS_FAMILY=debian
s5_account_create >/dev/null 2>&1
s5env_reset_transcript
t_run s5_account_remove 1 900 900
assert_eq "removal with a matching fingerprint succeeds" 0 "$T_STATUS"
if s5_account_exists; then t_bad "account should be gone"; else t_ok; fi

# The names now belong to somebody else: uid/gid differ.
reset_db
s5_account_create >/dev/null 2>&1
: >"$S5_TEST_ROOT/stub_foreign_identity"
s5env_reset_transcript
t_run s5_account_remove 1 900 900
assert_ne "a reused name is never deleted" 0 "$T_STATUS"
assert_contains "the refusal explains the mismatch" "reused" "$T_OUT"
if s5_account_exists; then t_ok; else t_bad "the replacement account must survive"; fi
if s5_group_exists; then t_ok; else t_bad "the replacement group must survive"; fi
t_assert_never_called "no userdel runs against a foreign identity" 'userdel'
t_assert_never_called "no groupdel runs against a foreign group" 'groupdel'
rm -f "$S5_TEST_ROOT/stub_foreign_identity"

# Without the fingerprint, "created_account" only says the NAME was created
# once -- not that today's holder is ours. Refuse and say what to do.
reset_db
S5_OS_FAMILY=debian
s5_account_create >/dev/null 2>&1
s5env_reset_transcript
t_run s5_account_remove 1 '' 900
assert_ne "an unrecorded fingerprint is refused" 0 "$T_STATUS"
assert_contains "the refusal says the state lacks the fingerprint" \
    "does not record" "$T_OUT"
if s5_account_exists; then t_ok; else t_bad "the account must survive a missing fingerprint"; fi

# End to end: a COMPLETE state whose recorded uid no longer matches the
# current holder. Uninstall must refuse, keep the account, and retain state.
reset_db
S5_OS_FAMILY=debian
s5_account_create >/dev/null 2>&1
rm -rf "$S5_STATEDIR"
mkdir -p "$S5_STATEDIR"
printf 'tag\t0.9.9.0\ncommit\tda99424eac4092e3722f1a5b1844cfe80478f580\norigin\tsource-build\nport\t31080\nusername\tacctuser\nos\tdebian-12\nfamily\tdebian\narch\tamd64\ninit\tsystemd\nlisten\t0.0.0.0\naccount_uid\t900\naccount_gid\t900\ncreated_account\t1\ncreated_group\t1\nstatus\tcomplete\n' >"$S5_STATE"
chmod 0600 "$S5_STATE"
: >"$S5_TEST_ROOT/stub_foreign_identity"
s5env_answers 'y
'
t_run s5_cmd_uninstall <"$S5_TEST_ROOT/answers"
assert_ne "uninstall refuses a reused identity end to end" 0 "$T_STATUS"
if s5_account_exists; then t_ok; else t_bad "the replacement account survives uninstall"; fi
assert_file_exists "state is retained for a retry" "$S5_STATE"
rm -f "$S5_TEST_ROOT/stub_foreign_identity"

# ==========================================================================
# Uninstall surfaces the failure and keeps the state file.
# ==========================================================================
reset_db
S5_OS_FAMILY=debian
s5_account_create >/dev/null 2>&1
: >"$S5_TEST_ROOT/stub_userdel_fail"
rm -rf "$S5_STATEDIR"
mkdir -p "$S5_STATEDIR"
printf 'tag\t0.9.9.0\ncommit\tda99424eac4092e3722f1a5b1844cfe80478f580\norigin\tsource-build\nport\t31080\nusername\tacctuser\nos\tdebian-12\nfamily\tdebian\narch\tamd64\ninit\tsystemd\nlisten\t0.0.0.0\naccount_uid\t900\naccount_gid\t900\ncreated_account\t1\ncreated_group\t1\nstatus\tcomplete\n' >"$S5_STATE"
chmod 0600 "$S5_STATE"
s5env_answers 'y
'
t_run s5_cmd_uninstall <"$S5_TEST_ROOT/answers"
assert_ne "uninstall fails when the account cannot be removed" 0 "$T_STATUS"
assert_not_contains "does NOT claim the uninstall completed" "uninstall complete" "$T_OUT"
assert_contains "tells the operator to retry" "uninstall" "$T_OUT"
assert_file_exists "the state file is retained for a retry" "$S5_STATE"

# once the tool works, the retry completes and reports success
rm -f "$S5_TEST_ROOT/stub_userdel_fail"
s5env_answers 'y
'
t_run s5_cmd_uninstall <"$S5_TEST_ROOT/answers"
assert_eq "retry succeeds" 0 "$T_STATUS"
assert_contains "now reports completion" "uninstall complete" "$T_OUT"
assert_file_absent "state removed on success" "$S5_STATE"

t_summary
