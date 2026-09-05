#!/bin/sh
# Credential containment in the CI audit and launcher scripts.
#
# SPEC 7 keeps credentials out of argv, xtrace, logs, journal and CI output. A
# detector that prints the line it matched leaks the secret it exists to
# protect, so these assert on what the scripts print, not only on exit status.

S5T_NAME=test_xray_secret
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
ROOT=${S5_REPO_ROOT}
t_mktestroot

SECRET='CIAudit_secret~9'
FAKE="$S5_TEST_ROOT/root"
UNIT="$FAKE/etc/systemd/system/xray-socks5.service"

build_tree() {
    rm -rf "$FAKE"
    mkdir -p "$FAKE/etc/xray-socks5" "$FAKE/var/lib/xray-socks5" \
        "$FAKE/usr/local/libexec/xray-socks5" "$FAKE/etc/systemd/system" \
        "$FAKE/var/log"
    printf '{"pass": "%s"}\n' "$SECRET" >"$FAKE/etc/xray-socks5/config.json"
    chmod 0640 "$FAKE/etc/xray-socks5/config.json"
    printf 'engine\txray\nprotocol\tmixed\nauth\tpassword\nudp\tfalse\n' \
        >"$FAKE/var/lib/xray-socks5/state"
    chmod 0600 "$FAKE/var/lib/xray-socks5/state"
    printf '#!/bin/sh\n' >"$FAKE/usr/local/libexec/xray-socks5/xray"
    chmod 0755 "$FAKE/usr/local/libexec/xray-socks5/xray"
    printf '%s\n' \
        'ExecStart=/usr/local/libexec/xray-socks5/xray run -c /etc/xray-socks5/config.json' \
        >"$UNIT"
    chmod 0644 "$UNIT"
    printf 'ciuser\n%s\n' "$SECRET" >"$S5_TEST_ROOT/pass"
    chmod 0600 "$S5_TEST_ROOT/pass"
}

audit() {
    # shellcheck disable=SC2086
    T_OUT=$(${S5_TEST_SHELL:-sh} "$ROOT/tests/protocol/post_install_audit.sh" \
        "$FAKE" "$S5_TEST_ROOT/pass" 2>&1) && T_STATUS=0 || T_STATUS=$?
    return 0
}

build_tree
audit
assert_eq "a clean namespace passes the audit" 0 "$T_STATUS"
assert_not_contains "a passing audit prints no credential" "$SECRET" "$T_OUT"

build_tree
printf 'proxy started for %s\n' "$SECRET" >"$FAKE/var/log/leak.log"
audit
assert_ne "a credential under var/log fails the audit" 0 "$T_STATUS"
assert_not_contains "a var/log leak is reported without the credential" \
    "$SECRET" "$T_OUT"

build_tree
printf 'Environment=PASS=%s\n' "$SECRET" >>"$UNIT"
audit
assert_ne "a credential in the unit fails the audit" 0 "$T_STATUS"
assert_not_contains "a unit leak is reported without the credential" \
    "$SECRET" "$T_OUT"

# SPEC 7 fails closed on unobservable state: a scan that cannot run must not be
# reported as a clean namespace.
build_tree
rmdir "$FAKE/var/log"
audit
assert_ne "an unscannable target fails the audit" 0 "$T_STATUS"

# The launcher redacts its engine logs. Passing the secret as an argument would
# publish it through /proc/<pid>/cmdline for the lifetime of the grep.
launcher=$(cat "$ROOT/tests/protocol/start_engine.sh")
assert_not_contains "launcher keeps the password out of grep argv" \
    'grep -v "$pass"' "$launcher"

# SPEC 7: restrictive permissions come before the credential is written.
t_line_of() {
    grep -nF "$2" "$1" | head -n 1 | cut -d: -f1
}
_engine=$ROOT/tests/protocol/start_engine.sh
_chmod_at=$(t_line_of "$_engine" 'chmod 0600 "$WORK/config.json"')
_write_at=$(t_line_of "$_engine" 'cat >"$WORK/config.json"')
if [ -n "$_chmod_at" ] && [ -n "$_write_at" ] && [ "$_chmod_at" -lt "$_write_at" ]; then
    t_ok
else
    t_bad "launcher must chmod the config before writing it (chmod at ${_chmod_at:-none}, write at ${_write_at:-none})"
fi

# SPEC 7 keeps credentials out of the environment. A plain assignment preserves
# an inherited export attribute, so a caller that exported any of these names
# would have the entered value pushed into every child environment. The username
# counts: it is half the auth pair. The probe reports a count rather than the
# matched line, because a failure message must not publish the credential it is
# checking for.
_probe=$S5_TEST_ROOT/exportprobe.sh
cat >"$_probe" <<'EOF'
_probesrc=$1
_probeans=$2
S5_LIB_ONLY=1
S5_ASSUME_ROOT=1
S5_SKIP_OWNERSHIP=1
. "$_probesrc"
S5_LANG=en
{
    s5_prompt_username >/dev/null 2>&1 || exit 3
    s5_prompt_password >/dev/null 2>&1 || exit 3
} <"$_probeans"
env | grep -cE '^(S5_PASSWORD|S5_SECRET|S5_USERNAME)=' || true
EOF
_answers=$S5_TEST_ROOT/answers.credentials
printf 'chosenuser\nExported_secret~1\n' >"$_answers"

# shellcheck disable=SC2086
t_run env S5_PASSWORD=placeholder S5_SECRET=placeholder S5_USERNAME=placeholder \
    ${S5_TEST_SHELL:-sh} "$_probe" "$ROOT/socks5.sh" "$_answers"
assert_eq "the prompts succeed when the caller exported the names" 0 "$T_STATUS"
assert_eq "an exported credential name leaves nothing in the environment" \
    0 "$T_OUT"

# shellcheck disable=SC2086
t_run env -u S5_PASSWORD -u S5_SECRET -u S5_USERNAME \
    ${S5_TEST_SHELL:-sh} "$_probe" "$ROOT/socks5.sh" "$_answers"
assert_eq "the prompts succeed with a clean environment" 0 "$T_STATUS"
assert_eq "a clean caller leaves nothing in the environment" 0 "$T_OUT"

t_summary
