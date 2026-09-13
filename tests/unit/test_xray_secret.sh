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
assert_secret_absent() {
    case "$2" in
        *"$SECRET"*) t_bad "$1: credential reached output" ;;
        *) t_ok ;;
    esac
}
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
assert_secret_absent "a passing audit prints no credential" "$T_OUT"

build_tree
printf 'proxy started for %s\n' "$SECRET" >"$FAKE/var/log/leak.log"
audit
assert_ne "a credential under var/log fails the audit" 0 "$T_STATUS"
assert_secret_absent "a var/log leak is reported without the credential" "$T_OUT"

build_tree
printf 'Environment=PASS=%s\n' "$SECRET" >>"$UNIT"
audit
assert_ne "a credential in the unit fails the audit" 0 "$T_STATUS"
assert_secret_absent "a unit leak is reported without the credential" "$T_OUT"

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

# SPEC 7 names the journal and CI output as channels to keep the credential out of.
# run-socks5.sh redacts its log on the failure path but printed the systemctl-status
# and journalctl dumps verbatim, so a secret in either reached the console. The stub
# socks5.sh fails without emitting the secret, so the only possible source of a leak
# here is those two dumps.
_rundir=$S5_TEST_ROOT/runner
mkdir -p "$_rundir/bin"
printf '#!/bin/sh\nexit 1\n' >"$_rundir/socks5.sh"
chmod 0755 "$_rundir/socks5.sh"
for _rb in systemctl journalctl; do
    printf '#!/bin/sh\nprintf "%s\\n" "leaked %s"\n' '%s' "$SECRET" >"$_rundir/bin/$_rb"
    chmod 0755 "$_rundir/bin/$_rb"
done
printf '#!/bin/sh\nexit 0\n' >"$_rundir/bin/ss"
chmod 0755 "$_rundir/bin/ss"
printf 'ciuser\n%s\n' "$SECRET" >"$_rundir/pass"
chmod 0600 "$_rundir/pass"
: >"$_rundir/answers"
_runout=$(cd "$_rundir" && PATH="$_rundir/bin:$PATH" ${S5_TEST_SHELL:-sh} \
    "$ROOT/.github/scripts/run-socks5.sh" status "$_rundir/answers" \
    "$_rundir/log" "$_rundir/pass" 2>&1) || true
assert_secret_absent "run-socks5.sh redacts the status and journal dumps on failure" "$_runout"

# Exercise the wrapper's public stdout/stderr/status contract with synthetic
# credentials. Never include captured output or credentials in a failing assertion.
runner_no_secret() {
    case "$2" in
        *"$SECRET"* | *ciuser*) t_bad "$1: credential reached output" ;;
        *) t_ok ;;
    esac
}
runner_capture() {
    _runstatus=0
    (cd "$_rundir" && PATH="$_rundir/bin:$PATH" ${S5_TEST_SHELL:-sh} \
        "$ROOT/.github/scripts/run-socks5.sh" "$@" status "$_rundir/answers" \
        "$_rundir/log" "$_rundir/pass") >"$_rundir/stdout" 2>"$_rundir/stderr" || _runstatus=$?
    _runstdout=$(cat "$_rundir/stdout")
    _runstderr=$(cat "$_rundir/stderr")
}
cat >"$_rundir/socks5.sh" <<'EOF'
#!/bin/sh
printf 'normal command diagnostic\n'
printf 'identity: '; cat pass
printf 'stderr identity: ' >&2; cat pass >&2
exit 0
EOF
runner_capture
assert_eq "successful wrapped command retains zero status" 0 "$_runstatus"
runner_no_secret "success stdout is redacted before replay" "$_runstdout"
runner_no_secret "success stderr is redacted before replay" "$_runstderr"
case "$_runstdout" in
    *'normal command diagnostic'*) t_ok ;;
    *) t_bad "success retains useful diagnostics" ;;
esac

printf '\nexit 37\n' >>"$_rundir/socks5.sh"
# Replace the first exit, not the output-producing stub, so failure exercises the
# exact same log as success as well as the extra service/listener diagnostics.
sed 's/exit 0/exit 37/' "$_rundir/socks5.sh" >"$_rundir/failing"
mv "$_rundir/failing" "$_rundir/socks5.sh"
runner_capture
assert_eq "failure retains the wrapped command status" 37 "$_runstatus"
runner_no_secret "failure stdout is redacted" "$_runstdout"
runner_no_secret "failure stderr and service diagnostics are redacted" "$_runstderr"
case "$_runstderr" in
    *'normal command diagnostic'*'--- systemctl status ---'*'--- journal ---'*'--- listener ---'*) t_ok ;;
    *) t_bad "failure retains command and service diagnostics" ;;
esac
runner_capture --diagnose
assert_eq "standalone diagnostics return failure" 1 "$_runstatus"
runner_no_secret "standalone diagnostics are redacted" "$_runstderr"

# Record every external redactor invocation, without putting credentials in its
# argv. This catches a future -v secret=... or grep "$secret" implementation.
_realawk=$(command -v awk)
printf '#!/bin/sh\nprintf "%%s\\n" "$@" >>"%s/argv"\nexec "%s" "$@"\n' \
    "$_rundir" "$_realawk" >"$_rundir/bin/awk"
chmod 0755 "$_rundir/bin/awk"
runner_capture
runner_no_secret "redaction commands keep credentials out of argv" "$(cat "$_rundir/argv")"
# Error diagnostics are filtered too, even when shell redirection cannot open
# the answers file. Credentials are never used as a command argument.
mv "$_rundir/answers" "$_rundir/answers.saved"
_error_status=0
(cd "$_rundir" && PATH="$_rundir/bin:$PATH" ${S5_TEST_SHELL:-sh} \
    "$ROOT/.github/scripts/run-socks5.sh" status "$_rundir/missing-input" \
    "$_rundir/log" "$_rundir/pass") >"$_rundir/error-output" 2>&1 || _error_status=$?
assert_ne "unreadable answers fail the command" 0 "$_error_status"
runner_no_secret "shell-level errors are redacted" "$(cat "$_rundir/error-output")"

# Rotation can leave both credential generations in a failed update journal.
# Overlapping values also require longest-first matching, not repeated filtering
# of already-redacted text. Only credential FILE PATHS enter command arguments.
mv "$_rundir/answers.saved" "$_rundir/answers"
printf 'ciuser-next\n%s_rotated\n' "$SECRET" >"$_rundir/pass.next"
chmod 0600 "$_rundir/pass.next"
cat >"$_rundir/socks5.sh" <<'EOF'
printf 'rotation diagnostic retained\n'
cat pass pass.next
cat pass pass.next >&2
exit "$(cat command-status)"
EOF
for _rb in systemctl journalctl ss; do
    cat >"$_rundir/bin/$_rb" <<'EOF'
#!/bin/sh
printf 'service diagnostic retained\n'
cat pass pass.next
cat pass pass.next >&2
exit 17
EOF
    chmod 0755 "$_rundir/bin/$_rb"
done
runner_generations() {
    _runstatus=0
    (cd "$_rundir" && PATH="$_rundir/bin:$PATH" ${S5_TEST_SHELL:-sh} \
        "$ROOT/.github/scripts/run-socks5.sh" "$@" install "$_rundir/answers" \
        "$_rundir/log" "$_rundir/pass" "$_rundir/pass.next") \
        >"$_rundir/stdout" 2>"$_rundir/stderr" || _runstatus=$?
    _runstdout=$(cat "$_rundir/stdout")
    _runstderr=$(cat "$_rundir/stderr")
}
runner_both_hidden() {
    runner_no_secret "$1" "$2"
    case "$2" in
        *_rotated* | *-next*) t_bad "$1: longer credential only partially redacted" ;;
        *) t_ok ;;
    esac
}
printf '0\n' >"$_rundir/command-status"
runner_generations
assert_eq "rotation success retains zero status" 0 "$_runstatus"
runner_both_hidden "rotation success stdout hides both generations" "$_runstdout"
runner_both_hidden "rotation success stderr hides both generations" "$_runstderr"
case "$_runstdout" in
    *'rotation diagnostic retained'*'<REDACTED>'*) t_ok ;;
    *) t_bad "rotation success retains redacted diagnostics" ;;
esac
printf '37\n' >"$_rundir/command-status"
runner_generations
assert_eq "rotation failure preserves command status" 37 "$_runstatus"
runner_both_hidden "rotation failure stdout hides both generations" "$_runstdout"
runner_both_hidden "rotation failure diagnostics hide both generations" "$_runstderr"
case "$_runstderr" in
    *'rotation diagnostic retained'*'service diagnostic retained'*'<REDACTED>'*) t_ok ;;
    *) t_bad "rotation failure retains command and service diagnostics" ;;
esac
runner_generations --diagnose
assert_eq "rotation standalone diagnostics fail" 1 "$_runstatus"
runner_both_hidden "rotation standalone diagnostics hide both generations" "$_runstderr"
runner_both_hidden "both generations stay out of redactor argv" "$(cat "$_rundir/argv")"
printf 'incomplete\n' >"$_rundir/pass.next"
runner_generations
assert_eq "invalid extra credential file fails before replay" 2 "$_runstatus"
runner_no_secret "invalid extra credential file exposes no old credential" "$_runstderr"

t_summary
