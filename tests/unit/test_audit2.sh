#!/bin/sh
# tests/unit/test_audit2.sh - second-audit regressions:
#   * every S5_* override the script reads is covered by the production guard
#   * resources are RECORDED BEFORE they are created, so a state-write failure
#     cannot orphan them
#   * `status` never claims a firewall rule is gone when it simply could not
#     check (a non-root query is not evidence of absence)
#   * no dead variables
#   * CI never puts a credential into an environment variable

S5T_NAME=test_audit2
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
. "${S5_REPO_ROOT}/tests/lib/stub.sh"
. "${S5_REPO_ROOT}/tests/lib/env.sh"

s5env_setup
s5env_load

R="${S5_REPO_ROOT}"

# ==========================================================================
# Environment-influence completeness.
#
# For every S5_* variable the script reads with a `${VAR:-default}` fallback,
# an inherited environment value must be unable to influence behaviour. That
# holds if EITHER the variable is refused in production by the guard, OR the
# script unconditionally assigns it before the first read (so whatever the
# caller exported is discarded).
# ==========================================================================
reads=$(grep -oE '\$\{S5_[A-Z_]+:-' "${S5_SRC}" | sed -e 's/\${//' -e 's/:-//' | sort -u)
guarded=$(grep 's5_note_override' "${S5_SRC}" | grep -oE 'S5_[A-Z_]+ ' | tr -d ' ' | sort -u)

# The harness exports several overrides, so a production-mode probe must clear
# every one of them. The clear-list is derived from the guard list itself, so it
# can never drift out of step with the implementation.
clear_args=''
for v in $guarded; do
    clear_args="$clear_args -u $v"
done
# shellcheck disable=SC2086
clean_env() {
    env -u S5_TEST_MODE $clear_args "$@"
}

# Baseline: with every override cleared, the script runs normally. Round 16:
# the language selector reads stdin before dispatch, so the answer file feeds it.
_langf=$(mktemp "${TMPDIR:-/tmp}/s5lang.XXXXXX")
printf '2\n' >"$_langf"
t_run clean_env sh "${S5_SRC}" --help <"$_langf"
assert_eq "baseline: production mode runs with no overrides set" 0 "$T_STATUS"
assert_contains "baseline prints usage" "Usage" "$T_OUT"

for v in $reads; do
    if [ "$v" = "S5_TEST_MODE" ]; then continue; fi
    if printf '%s\n' "$guarded" | grep -qx "$v"; then
        t_ok
        continue
    fi
    # not guarded: it must be unconditionally initialised before its first read
    firstread=$(grep -n "\${$v:-" "${S5_SRC}" | head -n 1 | cut -d: -f1)
    firstinit=$(grep -nE "^$v=" "${S5_SRC}" | head -n 1 | cut -d: -f1)
    if [ -n "$firstinit" ] && [ -n "$firstread" ] && [ "$firstinit" -lt "$firstread" ]; then
        t_ok
    else
        t_bad "$v is read from the environment, is not guarded, and is not initialised first"
    fi
done
# ...and every guarded variable really does cause a refusal outside test mode,
# on its own, with all the others cleared.
for v in $guarded; do
    t_run clean_env "$v=x" sh "${S5_SRC}" status
    assert_eq "production refuses $v on its own" 2 "$T_STATUS"
    assert_contains "and names it" "$v" "$T_OUT"
done
# The two internal variables that are read with a default must be provably
# initialised, so an exported value cannot reach them.
for v in S5_SECRET S5_INIT; do
    if grep -qE "^$v=''" "${S5_SRC}"; then
        t_ok
    else
        t_bad "$v must be unconditionally initialised to a known value"
    fi
done
t_run clean_env S5_SECRET=leak S5_INIT=bogus sh "${S5_SRC}" --help <"$_langf"
assert_eq "exported S5_SECRET/S5_INIT are harmless, not a refusal" 0 "$T_STATUS"
assert_not_contains "and never echoed" "leak" "$T_OUT"

# ==========================================================================
# No dead variables.
# ==========================================================================
if grep -q S5_INSTALL_ACTIVE "${S5_SRC}"; then
    t_bad "dead variable still present: S5_INSTALL_ACTIVE"
else
    t_ok
fi
# every S5_* variable assigned at top level is read somewhere
for v in S5_ARCHNAME S5_WORKDIR S5_TERM_STATE S5_TERM_MODIFIED \
    S5_ROLLBACK_ARMED S5_INSTALL_COMPLETE S5_IN_CLEANUP; do
    n=$(grep -c "$v" "${S5_SRC}")
    if [ "$n" -ge 2 ]; then t_ok; else t_bad "$v is assigned but never used"; fi
done

# ==========================================================================
# Record-before-create: a state-write failure must never orphan a resource.
# Structural: in s5_install_steps every s5_state_mark must appear BEFORE the
# call that creates the thing it describes.
# ==========================================================================
steps=$(sed -n '/^s5_install_steps() {/,/^}/p' "${S5_SRC}")
line_of() { printf '%s\n' "$steps" | grep -n -- "$1" | head -n 1 | cut -d: -f1; }

mk_confdir=$(line_of 's5_mkdir_secure "\$S5_SYSCONFDIR"')
mark_confdir=$(line_of 's5_state_mark created_confdir')
if [ -n "$mark_confdir" ] && [ -n "$mk_confdir" ] && [ "$mark_confdir" -lt "$mk_confdir" ]; then
    t_ok
else
    t_bad "created_confdir must be recorded before the directory is created"
fi

build=$(line_of 's5_build_3proxy')
mark_prefix=$(line_of 's5_state_mark created_prefix')
mark_bin=$(line_of 's5_state_mark created_bin')
if [ -n "$mark_prefix" ] && [ -n "$build" ] && [ "$mark_prefix" -lt "$build" ]; then
    t_ok
else
    t_bad "created_prefix must be recorded before the build installs the binary"
fi
if [ -n "$mark_bin" ] && [ -n "$build" ] && [ "$mark_bin" -lt "$build" ]; then
    t_ok
else
    t_bad "created_bin must be recorded before the build installs the binary"
fi

w_users=$(line_of 's5_atomic_write "\$S5_USERSCFG"')
mark_users=$(line_of 's5_state_mark created_users')
if [ -n "$mark_users" ] && [ -n "$w_users" ] && [ "$mark_users" -lt "$w_users" ]; then
    t_ok
else
    t_bad "created_users must be recorded before users.cfg is written"
fi

w_cfg=$(line_of 's5_atomic_write "\$S5_CFG"')
mark_cfg=$(line_of 's5_state_mark created_cfg')
if [ -n "$mark_cfg" ] && [ -n "$w_cfg" ] && [ "$mark_cfg" -lt "$w_cfg" ]; then
    t_ok
else
    t_bad "created_cfg must be recorded before 3proxy.cfg is written"
fi

svc=$(sed -n '/^s5_service_install() {/,/^}/p' "${S5_SRC}")
svcline() { printf '%s\n' "$svc" | grep -n -- "$1" | head -n 1 | cut -d: -f1; }
if [ "$(svcline 's5_state_mark created_unit')" -lt "$(svcline 's5_atomic_write "\$S5_UNIT"')" ]; then
    t_ok
else
    t_bad "created_unit must be recorded before the unit file is written"
fi
if [ "$(svcline 's5_state_mark created_initscript')" -lt "$(svcline 's5_atomic_write "\$S5_INITSCRIPT"')" ]; then
    t_ok
else
    t_bad "created_initscript must be recorded before the init script is written"
fi

# Functional: flags recorded for resources that were never created must make
# teardown succeed, not fail.
rm -rf "$S5_SYSCONFDIR" "$S5_PREFIX" "$S5_STATEDIR"
mkdir -p "$S5_STATEDIR"
printf 'port\t31080\ninit\tsystemd\nfamily\tdebian\ncreated_confdir\t1\ncreated_cfg\t1\ncreated_users\t1\ncreated_prefix\t1\ncreated_bin\t1\ncreated_unit\t1\n' >"$S5_STATE"
chmod 0600 "$S5_STATE"
s5_state_load >/dev/null 2>&1
t_run s5_teardown
assert_eq "teardown tolerates flagged-but-absent resources" 0 "$T_STATUS"

# Functional: creation fails right after the flag is recorded -> rollback still
# cleans up and reports honestly.
rm -rf "${S5_SYSCONFDIR:?}" "${S5_PREFIX:?}" "${S5_STATEDIR:?}" "${S5_TEST_ROOT:?}/etc"
rm -f "$S5_UNIT" "$S5_INITSCRIPT" "$S5_TEST_ROOT/svc_active"
: >"$S5_TEST_ROOT/stub_passwd"
: >"$S5_TEST_ROOT/stub_group"
mkdir -p "$S5_TEST_ROOT/etc" "$S5_UNITDIR"
chmod 0500 "$S5_TEST_ROOT/etc"
s5env_install_answers y 31080 orphanuser 'OrphanPass_123~x'
t_run s5_cmd_install <"$S5_TEST_ROOT/answers"
chmod 0700 "$S5_TEST_ROOT/etc"
assert_ne "install fails when the config directory cannot be created" 0 "$T_STATUS"
assert_file_absent "the binary was rolled back" "$S5_BIN"
assert_file_absent "the prefix directory was rolled back" "$S5_PREFIX"
assert_file_absent "no state file survives a clean rollback" "$S5_STATE"
if s5_account_exists; then t_bad "the account must be rolled back too"; else t_ok; fi

# ==========================================================================
# `status` reports the firewall as untouched, because v1 never changes it.
# The old tri-state reporting (present / vanished / unverified) existed only for
# a rule this script had recorded owning; there is no such rule any more, and
# `firewall` is no longer even a valid state key.
# ==========================================================================
rm -rf "$S5_STATEDIR"
mkdir -p "$S5_STATEDIR"
printf 'tag\t0.9.9.0\ncommit\tda99424eac4092e3722f1a5b1844cfe80478f580\norigin\tsource-build\nport\t31080\nusername\tstatususer\nos\tdebian-12\nfamily\tdebian\narch\tamd64\ninit\tsystemd\nlisten\t0.0.0.0\naccount_uid\t900\naccount_gid\t900\nstatus\tcomplete\n' >"$S5_STATE"
chmod 0600 "$S5_STATE"

S5_ASSUME_ROOT=0
t_run s5_cmd_status
assert_eq "status works for a non-root reader" 0 "$T_STATUS"
assert_contains "status says the firewall was not modified" \
    "not modified by this script" "$T_OUT"
assert_not_contains "status never claims a rule vanished" \
    "NO LONGER PRESENT" "$T_OUT"
S5_ASSUME_ROOT=1

# It must reach that conclusion without querying any firewall backend.
s5env_reset_transcript
t_stub iptables 0
t_run s5_cmd_status
assert_eq "root status works" 0 "$T_STATUS"
assert_contains "root status also reports it untouched" \
    "not modified by this script" "$T_OUT"
t_assert_cmd_never_called "status queries no firewall backend" iptables ufw firewall-cmd
t_stub iptables 1

# ==========================================================================
# CI must never place a credential in an environment variable or argv.
# ==========================================================================
ci=$(cat "$R/.github/workflows/ci.yml")
if printf '%s\n' "$ci" | grep -qE 'PROXY_PASS[[:space:]]*='; then
    t_bad "CI passes the credential through the PROXY_PASS environment variable"
else
    t_ok
fi
if printf '%s\n' "$ci" | grep -qE '(PASSWORD|PASS)=\$\(cat'; then
    t_bad "CI expands a credential into an environment assignment"
else
    t_ok
fi
assert_contains "CI hands the credential over as a 0600 file" "PASSFILE" "$ci"

# the protocol scripts must take a file, not an environment secret
proto=$(cat "$R/tests/protocol/run_protocol.sh")
acl=$(cat "$R/tests/protocol/acl_resolution.sh")
assert_contains "run_protocol reads a PASSFILE" "PASSFILE" "$proto"
assert_contains "acl_resolution reads a PASSFILE" "PASSFILE" "$acl"
if printf '%s\n' "$proto" | grep -qE '^PROXY_PASS='; then
    t_bad "run_protocol.sh must not take the password from the environment"
else
    t_ok
fi
if printf '%s\n' "$acl" | grep -qE '^PROXY_PASS='; then
    t_bad "acl_resolution.sh must not take the password from the environment"
else
    t_ok
fi

# ==========================================================================
# The runner's own gates, driven rather than grepped.
#
# This was `assert_contains "TESTS line" "$(cat tests/run.sh)"`, which proves a
# string exists in the source -- satisfied equally by a working gate and by a
# comment mentioning one, and blind to whether the gate's exit status actually
# propagates. The real runner is instead executed against a synthetic tests/unit
# tree, once per failure mode it is supposed to catch.
# ==========================================================================
rr="$S5_TEST_ROOT/runner"
mkdir -p "$rr/tests/unit"
cp "$R/tests/run.sh" "$rr/tests/run.sh"
: >"$rr/socks5.sh"

expected=$(grep '^EXPECTED_UNIT_FILES=' "$R/tests/run.sh" | cut -d= -f2)
case "$expected" in
'' | *[!0-9]*)
    t_bad "the runner must pin an expected unit-file count (found: '$expected')"
    expected=1
    ;;
*)
    t_ok
    ;;
esac

mk_units() { # <count> <body written into each synthetic test file>
    rm -f "$rr"/tests/unit/*.sh
    _mki=1
    while [ "$_mki" -le "$1" ]; do
        printf '%s\n' "$2" >"$rr/tests/unit/test_gen$_mki.sh"
        _mki=$((_mki + 1))
    done
}
drive() {
    (cd "$rr" && sh tests/run.sh >"$rr/out" 2>&1)
    printf '%s' "$?"
}
out_has() { # <desc> <fixed-string>  -- greps the file; a failing assert_contains
    if grep -qF -- "$2" "$rr/out"; then # would dump the whole runner log
        t_ok
    else
        t_bad "$1 (not in the runner's output: $2)"
    fi
}

mk_units "$expected" 'printf "TESTS 3 0\n"'
assert_eq "a fully green tree exits 0" 0 "$(drive)"

mk_units "$expected" 'printf "TESTS 2 1\n"; exit 1'
assert_eq "a failed assertion exits non-zero" 1 "$(drive)"

# A file that reports failures but exits 0 anyway must still sink the run: the
# runner adds up the TESTS counts instead of trusting the exit status alone.
mk_units "$expected" 'printf "TESTS 2 1\n"'
assert_eq "a failed assertion counts even when the file exits 0" 1 "$(drive)"

mk_units "$expected" 'printf "nothing to see here\n"'
assert_eq "a file with no TESTS line fails the run" 1 "$(drive)"
out_has "and the reason is reported" "asserted nothing"

mk_units "$expected" 'printf "TESTS 0 0\n"'
assert_eq "a file that asserts nothing at all fails the run" 1 "$(drive)"
out_has "and that reason is reported too" "no assertions and no skips"

mk_units "$expected" 'printf "TESTS 3 0\n"'
rm -f "$rr/tests/unit/test_gen1.sh"
assert_eq "deleting a test file fails the run" 1 "$(drive)"
out_has "and the expected count is named" "expected $expected"

mk_units "$expected" 'printf "TESTS 3 0\n"'
printf 'printf "TESTS 1 0\\n"\n' >"$rr/tests/unit/test_extra.sh"
assert_eq "adding one without bumping the pin also fails" 1 "$(drive)"

# A filtered run is a deliberate subset, so the pin must not apply to it.
mk_units "$expected" 'printf "TESTS 3 0\n"'
(cd "$rr" && sh tests/run.sh test_gen1 >"$rr/out" 2>&1)
assert_eq "a filtered subset is still allowed to pass" 0 "$?"

rm -rf "$rr"

t_summary
