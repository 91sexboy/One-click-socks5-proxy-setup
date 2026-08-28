#!/bin/sh
# tests/unit/test_static_check.sh - second-audit regression: the destination-deny
# check must never fail OPEN, and must not create files in the config directory.
#
# Reproduces the fail-open found in the second audit: the nine-deny check used to
# write its findings to a predictable temp file ("$cfg.denycheck.$$") with the
# redirect wrapped in `2>/dev/null || true`. When that write failed (read-only
# directory, full disk, hostile pre-created path) the result file was empty, the
# `[ -s ]` test was false, and a configuration MISSING destination deny rules
# passed the security check.

S5T_NAME=test_static_check
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
. "${S5_REPO_ROOT}/tests/lib/stub.sh"
. "${S5_REPO_ROOT}/tests/lib/env.sh"

s5env_setup
s5env_load

S5_PORT=31080
S5_USERNAME=gooduser
S5_PASSWORD='TestPassword_123~x'

fresh_cfgdir() {
    rm -rf "$S5_SYSCONFDIR"
    mkdir -p "$S5_SYSCONFDIR"
    chmod 0700 "$S5_SYSCONFDIR"
    s5_render_users >"$S5_USERSCFG"
    chmod 0640 "$S5_USERSCFG"
}

# A config with three of the nine destination denies stripped out.
render_missing_denies() {
    s5_render_cfg |
        grep -v '^deny \* \* 169\.254' |
        grep -v '^deny \* \* 127\.' |
        grep -v '^deny \* \* 10\.'
}

# ==========================================================================
# The static check must not write anything into the config directory.
# ==========================================================================
fresh_cfgdir
s5_render_cfg >"$S5_CFG"
before=$(find "$S5_SYSCONFDIR" -mindepth 1 -maxdepth 1 | sort | tr '\n' ' ')
t_run s5_static_check_cfg "$S5_CFG"
assert_eq "a correct config passes" 0 "$T_STATUS"
after=$(find "$S5_SYSCONFDIR" -mindepth 1 -maxdepth 1 | sort | tr '\n' ' ')
assert_eq "the static check creates no file in the config directory" "$before" "$after"
stray=$(find "$S5_SYSCONFDIR" -name '*denycheck*' | grep -c . || true)
assert_eq "no denycheck scratch file exists" 0 "$stray"

# The implementation must not use a predictable scratch path at all.
# Comment lines are excluded: the fix documents the old bug by name.
if grep -v '^[[:space:]]*#' "${S5_SRC}" | grep -q 'denycheck'; then
    t_bad "the static check still uses a predictable scratch file"
else
    t_ok
fi
# ...and no redirection into a path derived from the config file name.
if grep -v '^[[:space:]]*#' "${S5_SRC}" | grep -qE '>"\$_scf\.'; then
    t_bad "the static check still redirects into a file beside the config"
else
    t_ok
fi

# ==========================================================================
# Missing destination denies are rejected - normal conditions.
# ==========================================================================
fresh_cfgdir
render_missing_denies >"$S5_CFG"
assert_eq "the crafted config really is missing denies" 6 \
    "$(grep -c '^deny \* \* ' "$S5_CFG")"
t_run s5_static_check_cfg "$S5_CFG"
assert_ne "missing denies are rejected" 0 "$T_STATUS"
assert_contains "and the missing ones are named" "169.254.0.0/16" "$T_OUT"

# ==========================================================================
# FAIL-OPEN REGRESSION: the same config must still be rejected when the
# check cannot create a scratch file, because the directory is read-only.
# ==========================================================================
fresh_cfgdir
render_missing_denies >"$S5_CFG"
chmod 0500 "$S5_SYSCONFDIR"
t_run s5_static_check_cfg "$S5_CFG"
chmod 0700 "$S5_SYSCONFDIR"
assert_ne "missing denies are STILL rejected with a read-only config dir" 0 "$T_STATUS"
assert_contains "the rejection names a missing CIDR" "169.254.0.0/16" "$T_OUT"

# ...and with the whole config file read-only too.
fresh_cfgdir
render_missing_denies >"$S5_CFG"
chmod 0400 "$S5_CFG"
chmod 0500 "$S5_SYSCONFDIR"
t_run s5_static_check_cfg "$S5_CFG"
chmod 0700 "$S5_SYSCONFDIR"
chmod 0640 "$S5_CFG"
assert_ne "missing denies rejected with a read-only config file" 0 "$T_STATUS"

# ==========================================================================
# Each individual CIDR is required, one at a time.
# ==========================================================================
for cidr in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 \
    172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
    fresh_cfgdir
    s5_render_cfg | grep -vF "deny * * $cidr" >"$S5_CFG"
    t_run s5_static_check_cfg "$S5_CFG"
    assert_ne "removing $cidr is rejected" 0 "$T_STATUS"
done

# ==========================================================================
# Ordering: a deny moved AFTER the allow rule must be rejected.
# ==========================================================================
fresh_cfgdir
{
    s5_render_cfg | grep -vF 'deny * * 169.254.0.0/16' | grep -v '^socks '
    printf 'deny * * 169.254.0.0/16\n'
    s5_render_cfg | grep '^socks '
} >"$S5_CFG"
assert_eq "the reordered config still has nine denies" 9 \
    "$(grep -c '^deny \* \* ' "$S5_CFG")"
t_run s5_static_check_cfg "$S5_CFG"
assert_ne "a deny placed after the allow is rejected" 0 "$T_STATUS"
assert_contains "and the ordering rule is named" "precede the allow" "$T_OUT"

# ==========================================================================
# A duplicated deny must not be able to satisfy the count for a missing one.
# ==========================================================================
fresh_cfgdir
s5_render_cfg | sed 's|^deny \* \* 169\.254\.0\.0/16$|deny * * 10.0.0.0/8|' >"$S5_CFG"
assert_eq "count is still nine after the substitution" 9 \
    "$(grep -c '^deny \* \* ' "$S5_CFG")"
t_run s5_static_check_cfg "$S5_CFG"
assert_ne "a duplicate cannot stand in for a missing CIDR" 0 "$T_STATUS"
assert_contains "the genuinely missing CIDR is named" "169.254.0.0/16" "$T_OUT"

# Required-CIDR presence is an exact effective-line property. Text in a comment
# or on a malformed directive with trailing fields must not satisfy it.
fresh_cfgdir
s5_render_cfg |
    sed 's|^deny \* \* 169\.254\.0\.0/16$|deny * * 10.0.0.0/8\
# deny * * 169.254.0.0/16|' >"$S5_CFG"
assert_eq "the comment-bypass config still has nine effective deny lines" 9 \
    "$(grep -c '^deny \* \* ' "$S5_CFG")"
t_run s5_static_check_cfg "$S5_CFG"
assert_ne "a comment cannot satisfy a required destination deny" 0 "$T_STATUS"
assert_contains "the comment-bypass rejection names the missing CIDR" \
    "169.254.0.0/16" "$T_OUT"

fresh_cfgdir
s5_render_cfg |
    sed 's|^deny \* \* 169\.254\.0\.0/16$|deny * * 169.254.0.0/16 unexpected|' >"$S5_CFG"
t_run s5_static_check_cfg "$S5_CFG"
assert_ne "a deny with extra fields is rejected" 0 "$T_STATUS"
assert_contains "the malformed-deny rejection names the missing CIDR" \
    "169.254.0.0/16" "$T_OUT"

# `flush` clears the accumulated ACL. A second one after the destination denies
# makes their exact text and ordering irrelevant, so exactly one flush must
# precede the ACL block.
fresh_cfgdir
s5_render_cfg |
    sed 's|^allow gooduser \* \* \* CONNECT$|flush\
allow gooduser * * * CONNECT|' >"$S5_CFG"
t_run s5_static_check_cfg "$S5_CFG"
assert_ne "a second flush after the destination denies is rejected" 0 "$T_STATUS"
assert_contains "the duplicate-flush rejection names flush" "exactly one flush" "$T_OUT"

# The terminal deny must be exactly once and after the sole allow. Merely finding
# `deny *` somewhere accepts a configuration that denies every client before the
# intended grant is reached.
fresh_cfgdir
s5_render_cfg | grep -v '^deny \*$' |
    sed 's|^allow gooduser \* \* \* CONNECT$|deny *\
allow gooduser * * * CONNECT|' >"$S5_CFG"
t_run s5_static_check_cfg "$S5_CFG"
assert_ne "a terminal deny before the allow is rejected" 0 "$T_STATUS"
assert_contains "the terminal-deny rejection names its required position" \
    "terminal deny" "$T_OUT"

# The credentials include is an exact effective directive, not a substring in a
# comment or an extra field.
fresh_cfgdir
s5_render_cfg >"$S5_CFG"
s5_render_cfg |
    sed "s|^users .*|# users \$$S5_USERSCFG|" >"$S5_CFG"
t_run s5_static_check_cfg "$S5_CFG"
assert_ne "a commented credentials include is rejected" 0 "$T_STATUS"
assert_contains "the include rejection names the credentials include" \
    "credentials include" "$T_OUT"

# The credentials file must contain exactly the configured account and one
# record. An additional valid record would be accepted by 3proxy as another
# proxy identity even though the generated config names only one operator.
fresh_cfgdir
s5_render_cfg >"$S5_CFG"
s5_render_users >>"$S5_USERSCFG"
t_run s5_static_check_cfg "$S5_CFG"
assert_ne "an extra credential record is rejected" 0 "$T_STATUS"
assert_contains "the extra credential rejection names one credential line" \
    "exactly one credential" "$T_OUT"

fresh_cfgdir
s5_render_cfg >"$S5_CFG"
s5_render_users | sed 's/^gooduser:/otheruser:/' >"$S5_USERSCFG"
t_run s5_static_check_cfg "$S5_CFG"
assert_ne "a credential for another user is rejected" 0 "$T_STATUS"
assert_contains "the wrong-user credential rejection names the configured user" \
    "configured username" "$T_OUT"

fresh_cfgdir
s5_render_cfg >"$S5_CFG"
printf '%s\n' 'gooduser:CL:DifferentPassword_123~x' >"$S5_USERSCFG"
t_run s5_static_check_cfg "$S5_CFG"
assert_ne "a credential carrying a different password is rejected" 0 "$T_STATUS"

fresh_cfgdir
s5_render_cfg >"$S5_CFG"
: >"$S5_USERSCFG"
t_run s5_static_check_cfg "$S5_CFG"
assert_ne "an empty credentials file is rejected" 0 "$T_STATUS"

fresh_cfgdir
s5_render_cfg >"$S5_CFG"
mv "$S5_USERSCFG" "$S5_TEST_ROOT/users-target"
ln -s "$S5_TEST_ROOT/users-target" "$S5_USERSCFG"
t_run s5_static_check_cfg "$S5_CFG"
assert_ne "a symlinked credentials file is rejected" 0 "$T_STATUS"
assert_contains "the symlink rejection requires a regular non-symlink file" \
    "symbolic" "$T_OUT"
rm -f "$S5_TEST_ROOT/users-target"

# ==========================================================================
# Weak authentication, the forbidden operations and every forbidden directive
# are actually detected.
#
# These three checks were the only ones with no coverage at all, and they were
# also the only ones written as BRE alternations ('auth none\|auth iponly').
# POSIX does not define \| in a basic regular expression: it is a GNU extension
# that busybox and ugrep also implement. On a grep that follows POSIX to the
# letter the pattern matches the literal text "auth none|auth iponly", nothing
# matches it, and a configuration with `auth none` passes the security check.
# The patterns are ERE now, and these cases pin the behaviour they must produce.
# ==========================================================================
for weak in 'auth none' 'auth iponly'; do
    fresh_cfgdir
    s5_render_cfg | sed "s|^auth strong\$|$weak|" >"$S5_CFG"
    assert_contains "the crafted config really contains [$weak]" \
        "$weak" "$(cat "$S5_CFG")"
    t_run s5_static_check_cfg "$S5_CFG"
    assert_ne "[$weak] is rejected" 0 "$T_STATUS"
    assert_contains "[$weak] is named as weak authentication" \
        "weak authentication" "$T_OUT"
done

# BIND and UDP ASSOCIATE, granted the way an operator would actually grant them.
for op in BIND UDPASSOC; do
    fresh_cfgdir
    s5_render_cfg | sed "s|CONNECT\$|CONNECT,$op|" >"$S5_CFG"
    assert_contains "the crafted config really grants [$op]" "$op" "$(cat "$S5_CFG")"
    t_run s5_static_check_cfg "$S5_CFG"
    assert_ne "[$op] is rejected" 0 "$T_STATUS"
    assert_contains "[$op] is named as a forbidden operation" \
        "forbidden operation" "$T_OUT"
done

# Every directive on the denylist, one at a time, with an argument.
for d in $S5_FORBIDDEN_DIRECTIVES; do
    fresh_cfgdir
    { s5_render_cfg; printf '%s /some/argument\n' "$d"; } >"$S5_CFG"
    t_run s5_static_check_cfg "$S5_CFG"
    assert_ne "forbidden directive [$d] is rejected" 0 "$T_STATUS"
    assert_contains "and [$d] is named" "forbidden directive present: $d" "$T_OUT"
done

# ...and one with nothing after it, which is the other half of the alternation.
fresh_cfgdir
{ s5_render_cfg; printf 'writable\n'; } >"$S5_CFG"
t_run s5_static_check_cfg "$S5_CFG"
assert_ne "a bare forbidden directive is rejected" 0 "$T_STATUS"
assert_contains "the bare directive is named" "forbidden directive present: writable" "$T_OUT"

# The allow rule must be exactly the configured user, exactly once. A broad
# `allow .* CONNECT` check accepts `allow * * * * CONNECT`, which defeats the
# single-account boundary, and accepts duplicate/extra allow entries.
fresh_cfgdir
s5_render_cfg | sed 's/^allow gooduser \* \* \* CONNECT$/allow * * * * CONNECT/' >"$S5_CFG"
t_run s5_static_check_cfg "$S5_CFG"
assert_ne "a wildcard-user allow is rejected" 0 "$T_STATUS"
assert_contains "wildcard-user rejection names the exact allow rule" \
    "exactly one allow" "$T_OUT"

fresh_cfgdir
{ s5_render_cfg; printf 'allow otheruser * * * CONNECT\n'; } >"$S5_CFG"
t_run s5_static_check_cfg "$S5_CFG"
assert_ne "an extra allow entry is rejected" 0 "$T_STATUS"
assert_contains "extra allow rejection names the exact allow rule" \
    "exactly one allow" "$T_OUT"

# The configured username is the only accepted allow subject.
fresh_cfgdir
s5_render_cfg >"$S5_CFG"
t_run s5_static_check_cfg "$S5_CFG"
assert_eq "the exact configured allow rule passes" 0 "$T_STATUS"

t_summary