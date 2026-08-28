#!/bin/sh
# tests/unit/test_secure_files.sh - B1 regression: secret files are never
# world/group readable at any instant, regardless of the caller's umask.
#
# The observations are real: socks5.sh records the mode of each temporary file
# and directory at creation time into $S5_TMPMODE_LOG, so these assertions look
# at what actually happened rather than at the final state only.

S5T_NAME=test_secure_files
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
. "${S5_REPO_ROOT}/tests/lib/stub.sh"
. "${S5_REPO_ROOT}/tests/lib/env.sh"

s5env_setup
S5_TMPMODE_LOG="$S5_TEST_ROOT/modelog"
export S5_TMPMODE_LOG
s5env_load

PASS_OK='SecretPass_123~x'

# ==========================================================================
# The script must set its own umask, not inherit the caller's.
# ==========================================================================
if grep -qE '^umask 077$' "${S5_SRC}"; then
    t_ok
else
    t_bad "socks5.sh must set umask 077 itself"
fi
umaskline=$(grep -n '^umask' "${S5_SRC}" | head -n 1 | cut -d: -f1)
setuline=$(grep -n '^set -u' "${S5_SRC}" | head -n 1 | cut -d: -f1)
if [ -n "$umaskline" ] && [ "$umaskline" -lt "$setuline" ]; then
    t_ok
else
    t_bad "umask must be set before anything else runs (umask line $umaskline, set -u line $setuline)"
fi

# ==========================================================================
# Under a hostile inherited umask, the credential temp file is still 0600.
# ==========================================================================
check_under_umask() {
    _u=$1
    rm -rf "$S5_SYSCONFDIR"
    : >"$S5_TMPMODE_LOG"
    S5_PORT=31080
    S5_USERNAME=gooduser
    S5_PASSWORD=$PASS_OK
    (
        umask "$_u"
        s5_mkdir_secure "$S5_SYSCONFDIR" "root:root" 0750 >/dev/null 2>&1
        s5_render_users | s5_atomic_write "$S5_USERSCFG" "root:root" 0640 >/dev/null 2>&1
    )
    log=$(cat "$S5_TMPMODE_LOG" 2>/dev/null)

    # the temp file holding the credential was 0600 when created AND when written
    created=$(printf '%s\n' "$log" | grep "^tmp-created:$S5_USERSCFG " | awk '{print $2}')
    written=$(printf '%s\n' "$log" | grep "^tmp-written:$S5_USERSCFG " | awk '{print $2}')
    assert_eq "umask $_u: credential temp file is 0600 at creation" 600 "$created"
    assert_eq "umask $_u: credential temp file is still 0600 after writing" 600 "$written"

    # the config directory was never 0755, not even for an instant
    dcreated=$(printf '%s\n' "$log" | grep "^dir-created:$S5_SYSCONFDIR " | awk '{print $2}')
    dfinal=$(printf '%s\n' "$log" | grep "^dir-final:$S5_SYSCONFDIR " | awk '{print $2}')
    assert_eq "umask $_u: config dir starts at 0700" 700 "$dcreated"
    assert_eq "umask $_u: config dir ends at 0750" 750 "$dfinal"
    assert_ne "umask $_u: config dir was never 0755" 755 "$dcreated"

    # final artefacts
    assert_mode "umask $_u: credentials file is 0640" 640 "$S5_USERSCFG"
    assert_mode "umask $_u: config dir is 0750" 750 "$S5_SYSCONFDIR"
    assert_eq "umask $_u: credential content is correct" \
        "gooduser:CL:$PASS_OK" "$(cat "$S5_USERSCFG")"

    # no leftover temporary file, and no untracked backup file
    left=$(find "$S5_SYSCONFDIR" -name '.s5tmp.*' | grep -c . || true)
    assert_eq "umask $_u: no temporary file left behind" 0 "$left"
    baks=$(find "$S5_SYSCONFDIR" -name '*.bak-*' | grep -c . || true)
    assert_eq "umask $_u: no untracked backup file created" 0 "$baks"
}
check_under_umask 0022
check_under_umask 0000
check_under_umask 0077

# ==========================================================================
# s5_atomic_write's failure path: if the mode or the ownership cannot be
# applied, the file must NOT appear at its target path.
#
# The existing cases above prove the temp file is 0600 throughout and the
# installed file ends at 0640. Neither can fail if s5_apply_owner_mode were
# moved to AFTER the rename: the transient mode at the target path would be the
# tighter 0600 either way, so the final state is identical. What is genuinely
# security-relevant is that a FAILED chmod or chown installs nothing -- otherwise
# a credential file lands in place with whatever mode and owner it happened to
# have. Both failures are driven here with a real non-zero exit status.
# ==========================================================================
# Structural: the ordering must hold, since only that makes the temp file the
# thing being adjusted. Line numbers within the function, so a reordering fails.
aw=$(sed -n '/^s5_atomic_write() {/,/^}/p' "${S5_SRC}")
aw_apply=$(printf '%s\n' "$aw" | grep -n 's5_apply_owner_mode' | head -n 1 | cut -d: -f1)
aw_mv=$(printf '%s\n' "$aw" | grep -n '^    if ! mv ' | head -n 1 | cut -d: -f1)
if [ -n "$aw_apply" ] && [ -n "$aw_mv" ] && [ "$aw_apply" -lt "$aw_mv" ]; then
    t_ok
else
    t_bad "owner and mode must be applied before the rename (apply $aw_apply, mv $aw_mv)"
fi

# The shadows below call the real binary by absolute path. busybox's `command -v`
# reports a bare applet name for its built-in chmod, and a bare name resolves
# straight back into the shadow -- unbounded recursion, which arrives as a
# segfault rather than as a test failure. So resolve to an absolute path, and
# treat a failure to resolve as a test failure: every target image has /bin/chmod,
# and silently skipping these failure-path cases is exactly the outcome this
# audit exists to prevent.
resolve_real() { # <name> -> absolute path on stdout, non-zero if none
    _rr=$(command -v "$1" 2>/dev/null)
    case "$_rr" in
    /*)
        printf '%s' "$_rr"
        return 0
        ;;
    esac
    for _rd in /bin /usr/bin /sbin /usr/sbin /usr/local/bin; do
        if [ -x "$_rd/$1" ]; then
            printf '%s' "$_rd/$1"
            return 0
        fi
    done
    return 1
}
real_chmod=$(resolve_real chmod) || real_chmod=''
real_chown=$(resolve_real chown) || real_chown=''
case "$real_chmod" in
/*) t_ok ;;
*) t_bad "cannot resolve a real chmod to an absolute path; the shadow would recurse" ;;
esac
case "$real_chown" in
/*) t_ok ;;
*) t_bad "cannot resolve a real chown to an absolute path" ;;
esac

# A pipeline cannot be handed to t_run directly, so it is wrapped in a function
# rather than in `sh -c "... S5_PASSWORD='$PASS_OK' ..."`. The old form put the
# password in a child process's argv, where `ps` shows it to every user on the
# machine - exactly what socks5.sh itself is forbidden to do, and what
# t_assert_no_secret_in_argv exists to catch elsewhere.
write_users_to() { s5_render_users | s5_atomic_write "$1" root:root 0640; }

rm -rf "$S5_SYSCONFDIR"
mkdir -p "$S5_SYSCONFDIR"
S5_USERNAME=gooduser
S5_PASSWORD=$PASS_OK

# Positive control first: the same write must succeed with no stub in place, so a
# failure below is attributable to the stub and not to a broken fixture.
t_run write_users_to "$S5_USERSCFG"
assert_eq "control: the write succeeds with no stub" 0 "$T_STATUS"
assert_file_exists "control: the file is installed" "$S5_USERSCFG"
rm -f "$S5_USERSCFG"

# A chmod that fails ONLY for the final mode. The temp file's own 0600 hardening
# must still succeed, so the injected failure is isolated to s5_apply_owner_mode.
#
# A shell FUNCTION, not a PATH stub: the shell caches command lookups, so by the
# time this runs chmod is already hashed to its absolute path and a new file
# earlier in PATH is never consulted. A function shadows both PATH and the hash
# table. The real binary is invoked through the ABSOLUTE path resolved above --
# a bare name would re-enter this function and recurse until the stack died,
# which under busybox ash presented as a segfault, not as a test failure.
chmod() {
    if [ "$1" = "0640" ]; then
        printf 'chmod: simulated failure\n' >&2
        return 1
    fi
    "$real_chmod" "$@"
}
t_run write_users_to "$S5_USERSCFG"
unset -f chmod
assert_ne "a failed chmod fails the write" 0 "$T_STATUS"
assert_contains "and names the mode it could not set" "cannot set mode" "$T_OUT"
assert_file_absent "the file is NOT installed when its mode cannot be set" "$S5_USERSCFG"
left=$(find "$S5_SYSCONFDIR" -name '.s5tmp.*' | grep -c . || true)
assert_eq "and no temporary file is left behind" 0 "$left"

# The ownership failure path. S5_SKIP_OWNERSHIP is turned off for this case only,
# because with it on chown is never called and the branch is unreachable.
chown() {
    printf 'chown: simulated failure\n' >&2
    return 1
}
_savedskip=${S5_SKIP_OWNERSHIP:-1}
S5_SKIP_OWNERSHIP=0
t_run write_users_to "$S5_USERSCFG"
S5_SKIP_OWNERSHIP=$_savedskip
unset -f chown
assert_ne "a failed chown fails the write" 0 "$T_STATUS"
assert_contains "and names the ownership it could not set" "cannot set ownership" "$T_OUT"
assert_file_absent "the file is NOT installed when its owner cannot be set" "$S5_USERSCFG"
left=$(find "$S5_SYSCONFDIR" -name '.s5tmp.*' | grep -c . || true)
assert_eq "no temporary file survives the ownership failure either" 0 "$left"

# Both failures came from the shadows, not from a broken fixture: with them gone
# the same write succeeds and lands at the right mode.
t_run write_users_to "$S5_USERSCFG"
assert_eq "the write succeeds again once the stubs are gone" 0 "$T_STATUS"
assert_mode "and the installed file is 0640" 640 "$S5_USERSCFG"
rm -f "$S5_USERSCFG"

# ==========================================================================
# Temporary names are unpredictable (mktemp), never .tmp.$$
# ==========================================================================
if grep -q '\.tmp\.\$\$' "${S5_SRC}"; then
    t_bad "predictable .tmp.\$\$ temporary name still present"
else
    t_ok
fi
if grep -q 'mktemp' "${S5_SRC}"; then
    t_ok
else
    t_bad "socks5.sh must use mktemp for temporary files"
fi

# ==========================================================================
# A symlinked target or temp file is refused rather than written through.
# ==========================================================================
rm -rf "$S5_SYSCONFDIR"
mkdir -p "$S5_SYSCONFDIR"
: >"$S5_TEST_ROOT/outside_target"
ln -s "$S5_TEST_ROOT/outside_target" "$S5_USERSCFG"
S5_PASSWORD=$PASS_OK
S5_USERNAME=gooduser
t_run write_users_to "$S5_USERSCFG"
assert_ne "refuses to write through a symlinked target" 0 "$T_STATUS"
assert_contains "explains the symlink refusal" "symbolic link" "$T_OUT"
assert_eq "the symlink target was not written to" "" "$(cat "$S5_TEST_ROOT/outside_target")"
rm -f "$S5_USERSCFG"

# A target that already exists through a symlinked ancestor must be refused as
# well; checking only the final component would permit writes outside the root.
rm -rf "${S5_TEST_ROOT:?}/outside-parent" "${S5_TEST_ROOT:?}/link-parent"
mkdir -p "$S5_TEST_ROOT/outside-parent/existing"
ln -s "$S5_TEST_ROOT/outside-parent" "$S5_TEST_ROOT/link-parent"
t_run s5_mkdir_secure "$S5_TEST_ROOT/link-parent/existing" "root:root" 0750
assert_ne "refuses an existing directory reached through a symlink" 0 "$T_STATUS"
assert_contains "names the symlink ancestor" "symbolic link" "$T_OUT"
rm -f "$S5_TEST_ROOT/link-parent"

# a symlinked config directory is refused too
rm -rf "$S5_SYSCONFDIR"
ln -s "$S5_TEST_ROOT/outside_dir" "$S5_SYSCONFDIR"
t_run s5_mkdir_secure "$S5_SYSCONFDIR" "root:root" 0750
assert_ne "refuses a symlinked config directory" 0 "$T_STATUS"
assert_file_absent "the symlink target directory was not created" "$S5_TEST_ROOT/outside_dir"
rm -f "$S5_SYSCONFDIR"

# ==========================================================================
# Existing shared directories retain administrator-selected metadata, while
# newly-created ancestors remain traversable under a restrictive umask.
# ==========================================================================
shared="$S5_TEST_ROOT/shared-parent"
rm -rf "$shared"
mkdir -p "$shared"
chmod 0711 "$shared"
t_run s5_mkdir_secure "$shared" "root:root" 0755
assert_eq "an existing shared directory is accepted" 0 "$T_STATUS"
assert_mode "an existing shared directory keeps its mode" 711 "$shared"

nested="$S5_TEST_ROOT/missing/parent/target"
rm -rf "${S5_TEST_ROOT:?}/missing"
(
    umask 0077
    t_run s5_mkdir_secure "$nested" "root:root" 0750
)
assert_eq "nested directory creation succeeds" 0 "$T_STATUS"
assert_mode "new intermediate parent is traversable" 755 "$S5_TEST_ROOT/missing"
assert_mode "new nested parent is traversable" 755 "$S5_TEST_ROOT/missing/parent"
assert_mode "new target gets its requested mode" 750 "$nested"

# ========================================================================
# s5_secure_tmp itself
# ========================================================================
mkdir -p "$S5_SYSCONFDIR"
f="$S5_SYSCONFDIR/plain"
: >"$f"
chmod 0666 "$f"
t_run s5_secure_tmp "$f"
assert_eq "secure_tmp accepts a regular file" 0 "$T_STATUS"
assert_mode "secure_tmp forces 0600" 600 "$f"

ln -s "$f" "$S5_SYSCONFDIR/link"
t_run s5_secure_tmp "$S5_SYSCONFDIR/link"
assert_ne "secure_tmp refuses a symlink" 0 "$T_STATUS"

t_run s5_secure_tmp "$S5_SYSCONFDIR"
assert_ne "secure_tmp refuses a directory" 0 "$T_STATUS"

t_summary
