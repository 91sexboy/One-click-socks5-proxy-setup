#!/bin/sh
# tests/unit/test_precheck.sh - H5 regression: every gate runs BEFORE the first
# prompt, before any state file exists, and before anything is modified.

S5T_NAME=test_precheck
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
. "${S5_REPO_ROOT}/tests/lib/stub.sh"
. "${S5_REPO_ROOT}/tests/lib/env.sh"

s5env_setup
s5env_load

# A clean machine: no install, no account, no leftovers from a previous case.
reset_machine() {
    rm -rf "$S5_STATEDIR" "$S5_SYSCONFDIR" "$S5_PREFIX"
    rm -f "$S5_UNIT" "$S5_INITSCRIPT" "$S5_TEST_ROOT/svc_active"
    : >"$S5_TEST_ROOT/stub_passwd"
    : >"$S5_TEST_ROOT/stub_group"
    s5env_reset_transcript
    S5_ASSUME_ROOT=1
    S5_OSRELEASE="${S5_REPO_ROOT}/tests/fixtures/os-release/debian-12"
    s5env_setup_pkgmgrs
    s5env_answers 'y
31080
someuser
GoodPass_123~x
y
y
'
}

# ==========================================================================
# Dead code from the audit must be gone.
# ==========================================================================
for dead in s5_die EX_TODO EX_UNSAFE 'S5_ARCH=' s5_rm_recorded; do
    if grep -q -- "$dead" "${S5_SRC}"; then
        t_bad "dead symbol still present: $dead"
    else
        t_ok
    fi
done

# ==========================================================================
# The gates are referenced from inside s5_precheck, not merely defined.
# ==========================================================================
precheck_body=$(sed -n '/^s5_precheck() {/,/^}/p' "${S5_SRC}")
if [ -z "$precheck_body" ]; then
    t_bad "s5_precheck is not defined"
else
    t_ok
fi
for fn in s5_require_commands s5_detect_platform s5_map_arch s5_is_root s5_pkgmgr_available; do
    if printf '%s\n' "$precheck_body" | grep -q "$fn"; then
        t_ok
    else
        t_bad "s5_precheck does not call $fn"
    fi
done
# ...and s5_precheck itself is called before anything else in the install flow.
install_body=$(sed -n '/^s5_cmd_install() {/,/^}/p' "${S5_SRC}")
pcline=$(printf '%s\n' "$install_body" | grep -n 's5_precheck' | head -n 1 | cut -d: -f1)
firstprompt=$(printf '%s\n' "$install_body" | grep -nE 's5_prompt_|s5_preinstall_warning|s5_state_begin' | head -n 1 | cut -d: -f1)
if [ -n "$pcline" ] && [ -n "$firstprompt" ] && [ "$pcline" -lt "$firstprompt" ]; then
    t_ok
else
    t_bad "s5_precheck must run before the first prompt/warning/state write"
fi

# The base-command list must not include the toolchain we install later.
for later in gcc make git; do
    if printf '%s' "$S5_BASE_COMMANDS" | grep -qw "$later"; then
        t_bad "$later must not be treated as a pre-existing base command"
    else
        t_ok
    fi
done
for base in sed awk grep mktemp stat id; do
    if printf '%s' "$S5_BASE_COMMANDS" | grep -qw "$base"; then
        t_ok
    else
        t_bad "$base should be a required base command"
    fi
done
# Commands invoked at sites that hard-fail must be gated here too, or a missing
# utility surfaces as a confusing mid-install error instead of a named pre-check
# failure:
#   chown  s5_apply_owner_mode - fails the install and triggers rollback
#   uname  read by s5_precheck itself, immediately after this gate
#   tail   build diagnostics and the destination-deny ordering check
#   rmdir  uninstall refuses to continue when it cannot remove a directory
for base in chown uname tail rmdir; do
    if printf '%s' "$S5_BASE_COMMANDS" | grep -qw "$base"; then
        t_ok
    else
        t_bad "$base is used at a hard-failure site and must be a required base command"
    fi
done
# stty is deliberately NOT required: every call site tolerates its absence
# (`stty -g 2>/dev/null || printf ''`), so demanding it would abort installs
# that would otherwise succeed.
if printf '%s' "$S5_BASE_COMMANDS" | grep -qw stty; then
    t_bad "stty must not be required: its call sites already degrade gracefully"
else
    t_ok
fi

# ==========================================================================
# s5_pkgmgr_available is honest about what is present.
# ==========================================================================
reset_machine
S5_PKGMGR=totally-unknown-manager
if s5_pkgmgr_available; then t_bad "an unknown manager must not report as available"; else t_ok; fi
S5_PKGMGR=apt
if s5_pkgmgr_available; then t_ok; else t_bad "the apt-get stub should satisfy availability"; fi
rm -f "$S5_TEST_ROOT/bin/apk"
S5_PKGMGR=apk
if s5_pkgmgr_available; then t_bad "apk must not report available when absent"; else t_ok; fi

# ==========================================================================
# End-to-end: install aborts before ANY prompt or state when a gate fails.
#
# The alpine and centos fixtures are used because this machine genuinely has no
# apk and no dnf, so removing the stub really does remove the manager. The apt
# case cannot be tested this way (a real apt-get exists here), so it is covered
# by the s5_pkgmgr_available unit assertions above.
# ==========================================================================
assert_aborts_before_prompting() {
    _desc=$1
    assert_ne "$_desc: install fails" 0 "$T_STATUS"
    assert_not_contains "$_desc: never showed the pre-install warning" "PLEASE READ" "$T_OUT"
    assert_not_contains "$_desc: never reached the port prompt" "SOCKS5 port" "$T_OUT"
    assert_not_contains "$_desc: never reached the password prompt" "SOCKS5 password" "$T_OUT"
    assert_file_absent "$_desc: no state file was created" "$S5_STATE"
    assert_file_absent "$_desc: no config directory was created" "$S5_SYSCONFDIR"
    t_assert_never_called "$_desc: no account was created" 'useradd'
    t_assert_never_called "$_desc: nothing was built" 'make -f'
    t_assert_never_called "$_desc: no package was installed" 'install -y'
}

reset_machine
rm -f "$S5_TEST_ROOT/bin/apk"
S5_OSRELEASE="${S5_REPO_ROOT}/tests/fixtures/os-release/alpine-3.24"
t_run s5_cmd_install <"$S5_TEST_ROOT/answers"
assert_contains "alpine: names the missing package manager" "apk" "$T_OUT"
assert_aborts_before_prompting "alpine, apk missing"

reset_machine
rm -f "$S5_TEST_ROOT/bin/dnf"
S5_OSRELEASE="${S5_REPO_ROOT}/tests/fixtures/os-release/centos-stream-9"
t_run s5_cmd_install <"$S5_TEST_ROOT/answers"
assert_contains "centos: names the missing package manager" "dnf" "$T_OUT"
assert_aborts_before_prompting "centos, dnf missing"

# ==========================================================================
# Unsupported and refused systems also stop before any prompt.
# ==========================================================================
reset_machine
S5_OSRELEASE="${S5_REPO_ROOT}/tests/fixtures/os-release/rocky-9"
t_run s5_cmd_install <"$S5_TEST_ROOT/answers"
assert_contains "Rocky is told it is likely compatible" "likely compatible" "$T_OUT"
assert_aborts_before_prompting "rocky-9"

reset_machine
S5_OSRELEASE="${S5_REPO_ROOT}/tests/fixtures/os-release/fedora-40"
t_run s5_cmd_install <"$S5_TEST_ROOT/answers"
assert_contains "Fedora error names the ID" "fedora" "$T_OUT"
assert_aborts_before_prompting "fedora-40"

reset_machine
S5_OSRELEASE="${S5_REPO_ROOT}/tests/fixtures/os-release/debian-11"
t_run s5_cmd_install <"$S5_TEST_ROOT/answers"
assert_contains "Debian 11 error names the version" "11" "$T_OUT"
assert_aborts_before_prompting "debian-11 (too old)"

# ==========================================================================
# Non-root stops before any prompt.
# ==========================================================================
reset_machine
S5_ASSUME_ROOT=0
t_run s5_cmd_install <"$S5_TEST_ROOT/answers"
assert_contains "explains that root is required" "root" "$T_OUT"
assert_aborts_before_prompting "non-root"
S5_ASSUME_ROOT=1

# ==========================================================================
# A missing base command is refused with a name.
# ==========================================================================
t_run s5_require_commands sed awk definitely-absent-cmd-xyz
assert_ne "a missing base command fails" 0 "$T_STATUS"
assert_contains "names the missing command" "definitely-absent-cmd-xyz" "$T_OUT"

# ==========================================================================
# A clean host without ss/netstat must install its probe dependency before the
# port prompt. The prompt itself checks an on-disk marker so this assertion
# observes ordering rather than merely checking that both functions exist.
# ===========================================================================
reset_machine
rm -f "$S5_PORT_PROBE"
S5_PORT_PROBE=''
export S5_PORT_PROBE
: >"$S5_TEST_ROOT/order-answers"
s5_confirm() { return 0; }
s5_confirm_yes() { return 0; }
s5_install_dependencies() {
    : >"$S5_TEST_ROOT/dependencies-before-port"
    return 0
}
s5_prompt_port() {
    if [ ! -f "$S5_TEST_ROOT/dependencies-before-port" ]; then
        s5_err "port prompt ran before dependencies"
        return 1
    fi
    S5_PORT=31080
    return 0
}
s5_prompt_username() { S5_USERNAME=someuser; return 0; }
s5_prompt_password() { S5_PASSWORD=GoodPass_123~x; S5_SECRET=$S5_PASSWORD; return 0; }
s5_state_begin() { return 0; }
s5_state_add() { return 0; }
s5_install_steps() { return 0; }
s5_print_summary() { return 0; }
t_run s5_cmd_install <"$S5_TEST_ROOT/order-answers"
assert_eq "dependencies run before the port prompt" 0 "$T_STATUS"
assert_file_exists "dependency step ran before prompting" "$S5_TEST_ROOT/dependencies-before-port"

 t_summary
