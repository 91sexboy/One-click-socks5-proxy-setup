#!/bin/sh
# tests/unit/test_state.sh - B2 regression: a corrupted, hostile or unexpected
# state file can never cause a delete outside the project's fixed paths.
#
# Every case plants an external sentinel and proves it survives.

S5T_NAME=test_state
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
. "${S5_REPO_ROOT}/tests/lib/stub.sh"
. "${S5_REPO_ROOT}/tests/lib/env.sh"

s5env_setup
s5env_load

SENTINEL_DIR="$S5_TEST_ROOT/DO_NOT_DELETE"
mkdir -p "$SENTINEL_DIR/etc" "$SENTINEL_DIR/usr"
printf 'external file that must survive\n' >"$SENTINEL_DIR/keepme"
printf 'external etc file\n' >"$SENTINEL_DIR/etc/passwd"
printf 'external usr file\n' >"$SENTINEL_DIR/usr/important"

sentinel_intact() {
    if [ -f "$SENTINEL_DIR/keepme" ] &&
        [ -f "$SENTINEL_DIR/etc/passwd" ] &&
        [ -f "$SENTINEL_DIR/usr/important" ]; then
        return 0
    fi
    return 1
}

write_state() {
    mkdir -p "$S5_STATEDIR"
    printf '%s' "$1" >"$S5_STATE"
    chmod 0600 "$S5_STATE"
}

# ==========================================================================
# The implementation must not contain a state-driven recursive delete at all.
#
# The previous form of this check piped through `grep -qv '^\s*#'`, which could
# never match: the input is `grep -n` output, so every line starts with a digit.
# The outer condition and the inner one also disagreed about which occurrence
# was allowed. It is now a single, exact statement of the invariant.
# ==========================================================================
rmrf=$(grep -n 'rm -rf' "${S5_SRC}" | grep -v '^[0-9][0-9]*:[[:space:]]*#')
rmrf_count=$(printf '%s' "$rmrf" | grep -c 'rm -rf')
assert_eq "exactly one rm -rf remains in the implementation" 1 "$rmrf_count"
if printf '%s\n' "$rmrf" | grep -q 'rm -rf "\$1"'; then
    t_ok
else
    t_bad "the only rm -rf must delete nothing but its own argument: [$rmrf]"
fi
# ...and it must be the guarded build-dir helper that owns it, not some other
# function that happens to take a path argument.
workdir_body=$(sed -n '/^s5_rm_workdir() {/,/^}/p' "${S5_SRC}")
if printf '%s\n' "$workdir_body" | grep -q 'rm -rf "\$1"'; then
    t_ok
else
    t_bad "s5_rm_workdir must be the function that owns the rm -rf"
fi
if grep -q 's5_rm_recorded' "${S5_SRC}"; then
    t_bad "s5_rm_recorded (state-path-driven rm -rf) must be gone"
else
    t_ok
fi

# ==========================================================================
# Hostile / corrupt state files are all rejected, and nothing is deleted.
# ==========================================================================
reject_case() {
    _desc=$1
    _body=$2
    rm -rf "$S5_STATEDIR"
    write_state "$_body"
    t_run s5_state_load
    assert_ne "rejected: $_desc" 0 "$T_STATUS"
    if sentinel_intact; then t_ok; else t_bad "$_desc: external sentinel was deleted"; fi
}

# Paths as values under keys that no longer exist
reject_case "unknown key 'dir' with /" "dir	/
status	complete"
reject_case "unknown key 'dir' with /etc" "dir	$SENTINEL_DIR/etc
status	complete"
reject_case "unknown key 'file' with /usr" "file	$SENTINEL_DIR/usr
status	complete"
reject_case "unknown key 'binary'" "binary	$SENTINEL_DIR/keepme
status	complete"
reject_case "relative path value" "dir	../../etc
status	complete"
reject_case "value containing .." "dir	$SENTINEL_DIR/../DO_NOT_DELETE
status	complete"
reject_case "unknown key entirely" "nonsense	1
status	complete"
reject_case "truncated line (no separator)" "created_confd"
reject_case "duplicate critical key" "port	31080
port	31081
status	complete"
reject_case "duplicate status" "status	complete
status	complete"
reject_case "flag with a non-1 value" "created_confdir	../../etc
status	complete"
reject_case "flag set to a path" "created_bin	/usr/bin/3proxy
status	complete"
reject_case "port out of range" "port	70000
status	complete"
reject_case "port not numeric" "port	31080x
status	complete"
# Integer-width and octal traps. A 1000-digit decimal makes POSIX test
# arithmetic emit a diagnostic and return false on BOTH comparisons, so the
# old validator fell through to success. Leading zeros are valid octal to the
# shell ([ 01080 ] is 1080) but are a literal string to the engine and to ss,
# so "01080" passed validation while nothing listening on ":01080" ever
# matches. Both are rejected as malformed now, before any arithmetic.
reject_case "port exceeding the shell integer width" "port	$(awk 'BEGIN { for (i=1; i<=1000; i++) printf "9" }')
status	complete"
reject_case "port with a leading zero" "port	01080
status	complete"
reject_case "port with leading zeros" "port	001080
status	complete"
reject_case "bogus init system" "init	sysvinit
status	complete"
# v1 never records a firewall, so `firewall` is no longer a known key at all.
# A state file naming one is refused outright rather than validated.
reject_case "the retired firewall key" "firewall	iptables
status	complete"
reject_case "the retired firewall_zone key" "firewall_zone	public
status	complete"
reject_case "bogus status value" "status	half-done"
reject_case "invalid username" "username	bad:user
status	complete"
reject_case "commit not hex" "commit	not-a-commit
status	complete"
# The old pattern was 8 hex chars followed by an unbounded '*', which in a
# shell case pattern means "then anything", not "then more hex". Any
# 8-hex-prefix string with an allowed trailing character passed. A commit is
# exactly 40 hexadecimal characters.
reject_case "commit too short" "commit	deadbeef
status	complete"
reject_case "commit with a non-hex suffix" "commit	da99424eac4092e3722f1a5b1844cfe80478f580Z
status	complete"
reject_case "commit 39 chars" "commit	da99424eac4092e3722f1a5b1844cfe80478f58
status	complete"
reject_case "commit 41 chars" "commit	da99424eac4092e3722f1a5b1844cfe80478f5800
status	complete"
reject_case "control character in a value" "$(printf 'origin\tsource\001build')"

# ==========================================================================
# Completeness: "status complete" claims the install flow ran to the end, and
# that flow records every singleton key. A bare "status complete" used to load
# as an installed system -- `install` became a no-op reporting "already
# installed" and every lifecycle command operated on empty fields.
# ==========================================================================
reject_case "status complete with no other keys" "status	complete"
reject_case "status complete missing most keys" "port	31080
username	gooduser
status	complete"

# A PARTIAL state (no status key) must still load: rollback and the
# uninstall-retry path act on exactly these mid-install records.
rm -rf "$S5_STATEDIR"
write_state "port	31080
created_confdir	1"
s5_state_load >/dev/null 2>&1
assert_eq "a partial install state still loads for rollback" 0 "$?"
S5_STATE_LOADED=0

rm -rf "$S5_STATEDIR"
write_state "status	complete"
if s5_is_installed; then
    t_bad "a bare complete status must not read as an installed system"
else
    t_ok
fi

# ==========================================================================
# A symlinked state file is refused.
# ==========================================================================
rm -rf "$S5_STATEDIR"
mkdir -p "$S5_STATEDIR"
printf 'status\tcomplete\n' >"$S5_TEST_ROOT/elsewhere_state"
ln -s "$S5_TEST_ROOT/elsewhere_state" "$S5_STATE"
t_run s5_state_load
assert_ne "symlinked state file is refused" 0 "$T_STATUS"
assert_contains "explains the symlink refusal" "symbolic link" "$T_OUT"
rm -f "$S5_STATE"

# uninstall must refuse too, and delete nothing. The answer streams from
# here on stay handwritten on purpose: each is a single [y/N] uninstall
# confirmation, not a complete install stream.
ln -s "$S5_TEST_ROOT/elsewhere_state" "$S5_STATE"
s5env_answers 'y
'
t_run s5_cmd_uninstall <"$S5_TEST_ROOT/answers"
assert_ne "uninstall refuses a symlinked state file" 0 "$T_STATUS"
assert_contains "uninstall says it will not delete anything" "refusing to delete" "$T_OUT"
if sentinel_intact; then t_ok; else t_bad "symlinked state: sentinel deleted"; fi
rm -f "$S5_STATE"

# A broken symlink is still a filesystem object. The absence helper must not
# use only -e, because -e follows the link and returns false for a dangling link.
rm -rf "$S5_SYSCONFDIR"
mkdir -p "$S5_SYSCONFDIR"
ln -s "$S5_TEST_ROOT/no-such-target" "$S5_SYSCONFDIR/broken"
_abs_before=$S5T_FAIL
assert_file_absent "a broken symlink is not considered absent" \
    "$S5_SYSCONFDIR/broken"
if [ "$S5T_FAIL" -gt "$_abs_before" ]; then S5T_FAIL=$_abs_before; t_ok; else t_bad "broken symlink absence check did not fail closed"; fi
rm -f "$S5_SYSCONFDIR/broken"

# An unreadable state file is a read failure, not an empty valid state. The
# loader must reject it before any management command can act on an empty cache.
rm -rf "$S5_STATEDIR"
write_state "port	31080"
chmod 000 "$S5_STATE"
t_run s5_state_load
assert_ne "an unreadable state file is rejected" 0 "$T_STATUS"
chmod 0600 "$S5_STATE"

# A dangling project-directory symlink must block teardown rather than being
# mistaken for a missing directory and silently left behind.
rm -rf "$S5_SYSCONFDIR"
ln -s "$S5_TEST_ROOT/missing-project-dir" "$S5_SYSCONFDIR"
S5_STATE_BUF="created_confdir	1"
S5_STATE_LOADED=1
t_run s5_rmdir_known created_confdir "$S5_SYSCONFDIR" 3proxy.cfg users.cfg
assert_ne "teardown rejects a broken project-directory symlink" 0 "$T_STATUS"
assert_eq "the broken project-directory symlink remains visible" yes \
    "$([ -L "$S5_SYSCONFDIR" ] && printf yes || printf no)"
rm -f "$S5_SYSCONFDIR"

# An untracked file in the state directory must prevent uninstall from deleting
# the state record and claiming completion.
rm -rf "$S5_STATEDIR" "$S5_SYSCONFDIR"
write_state "tag	0.9.9.0
commit	da99424eac4092e3722f1a5b1844cfe80478f580
origin	source-build
port	31080
username	stateuser
family	debian
init	systemd
listen	0.0.0.0
arch	amd64
os	debian-12
account_uid	900
account_gid	900
status	complete"
printf 'operator data\n' >"$S5_STATEDIR/operator-note"
s5env_answers 'y
'
t_run s5_cmd_uninstall <"$S5_TEST_ROOT/answers"
assert_ne "uninstall fails with an extra state-directory file" 0 "$T_STATUS"
assert_contains "extra state data is named" "operator-note" "$T_OUT"
assert_not_contains "extra state data cannot claim completion" \
    "uninstall complete" "$T_OUT"
assert_file_exists "state is retained for a retry" "$S5_STATE"
assert_file_exists "extra state data survives" "$S5_STATEDIR/operator-note"
rm -rf "$S5_STATEDIR"

# ==========================================================================
# State-directory removal failures must retain the state record for retry.
# ==========================================================================
rm -rf "$S5_STATEDIR"
write_state "tag	0.9.9.0
commit	da99424eac4092e3722f1a5b1844cfe80478f580
origin	source-build
port	31080
username	stateuser
family	debian
init	systemd
listen	0.0.0.0
arch	amd64
os	debian-12
account_uid	900
account_gid	900
status	complete"
s5env_answers 'y
'
rmdir() {
    if [ "$1" = "$S5_STATEDIR" ]; then
        return 1
    fi
    command rmdir "$@"
}
t_run s5_cmd_uninstall <"$S5_TEST_ROOT/answers"
unset -f rmdir
assert_ne "uninstall reports a state-directory removal failure" 0 "$T_STATUS"
assert_contains "state-directory failure is actionable" "state directory" "$T_OUT"
assert_file_exists "state remains available for retry" "$S5_STATE"
rm -rf "$S5_STATEDIR"

# ==========================================================================
# A valid state file is accepted, and only flags are honoured.
# ==========================================================================
rm -rf "$S5_STATEDIR"
write_state "tag	0.9.9.0
commit	da99424eac4092e3722f1a5b1844cfe80478f580
origin	source-build
port	31080
username	gooduser
family	debian
init	systemd
listen	0.0.0.0
arch	amd64
os	debian-12
account_uid	900
account_gid	900
created_confdir	1
status	complete"
s5_state_load >/dev/null 2>&1
assert_eq "a well-formed state file loads" 0 "$?"
assert_eq "port read back" 31080 "$(s5_state_get port)"
assert_eq "username read back" gooduser "$(s5_state_get username)"
if s5_state_flagged created_confdir; then t_ok; else t_bad "flag should be set"; fi
if s5_state_flagged created_bin; then t_bad "absent flag must not be set"; else t_ok; fi

# ==========================================================================
# Unknown files in a project directory: keep the directory, report, fail.
# ==========================================================================
rm -rf "$S5_SYSCONFDIR" "$S5_STATEDIR"
mkdir -p "$S5_SYSCONFDIR"
printf 'ours\n' >"$S5_CFG"
printf 'ours\n' >"$S5_USERSCFG"
printf 'someone else put this here\n' >"$S5_SYSCONFDIR/operator-notes.txt"
write_state "tag	0.9.9.0
commit	da99424eac4092e3722f1a5b1844cfe80478f580
origin	source-build
port	31080
username	gooduser
family	debian
init	systemd
listen	0.0.0.0
arch	amd64
os	debian-12
account_uid	900
account_gid	900
created_confdir	1
created_cfg	1
created_users	1
status	complete"
s5env_answers 'y
'
t_run s5_cmd_uninstall <"$S5_TEST_ROOT/answers"
assert_ne "uninstall fails when the directory holds unknown files" 0 "$T_STATUS"
assert_contains "names the unknown file" "operator-notes.txt" "$T_OUT"
assert_contains "says it is keeping the directory" "keeping" "$T_OUT"
assert_not_contains "must NOT claim success" "uninstall complete" "$T_OUT"
assert_dir_exists "the directory is kept" "$S5_SYSCONFDIR"
assert_file_exists "the unknown file survives" "$S5_SYSCONFDIR/operator-notes.txt"
assert_file_exists "state is retained for a retry" "$S5_STATE"
assert_file_absent "our own config was still removed" "$S5_CFG"

# after the operator removes the stray file, a retry completes
rm -f "$S5_SYSCONFDIR/operator-notes.txt"
s5env_answers 'y
'
t_run s5_cmd_uninstall <"$S5_TEST_ROOT/answers"
assert_eq "retry succeeds once the directory is clean" 0 "$T_STATUS"
assert_contains "now reports completion" "uninstall complete" "$T_OUT"
assert_file_absent "directory removed" "$S5_SYSCONFDIR"
assert_file_absent "state removed" "$S5_STATE"
if sentinel_intact; then t_ok; else t_bad "sentinel deleted during uninstall"; fi

# ==========================================================================
# A failing state write aborts instead of continuing with a resource unrecorded.
# ==========================================================================
rm -rf "$S5_STATEDIR"
mkdir -p "$S5_STATEDIR"
S5_STATE_BUF=''
S5_STATE_LOADED=1
chmod 0500 "$S5_STATEDIR"
t_run s5_state_add port 31080
assert_ne "a failing state write is reported" 0 "$T_STATUS"
chmod 0700 "$S5_STATEDIR"

# and an unknown key can never be recorded
t_run s5_state_add totally_unknown_key 1
assert_ne "refuses to record an unknown key" 0 "$T_STATUS"
assert_contains "explains the refusal" "unknown key" "$T_OUT"

if sentinel_intact; then t_ok; else t_bad "sentinel deleted at end of run"; fi

t_summary
