#!/bin/sh
# Xray mixed installer input, state, namespace and service contract tests.

S5T_NAME=test_xray_contract
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
ROOT=${S5_REPO_ROOT}
t_mktestroot
S5_LIB_ONLY=1
S5_ASSUME_ROOT=1
S5_SKIP_OWNERSHIP=1
export S5_LIB_ONLY S5_ASSUME_ROOT S5_SKIP_OWNERSHIP
# shellcheck source=/dev/null
. "$ROOT/socks5.sh"

S5_LANG=en
S5_PORT_PROBE="$S5_TEST_ROOT/portprobe"
cat >"$S5_PORT_PROBE" <<'PROBE'
#!/bin/sh
if [ -f "$S5_TEST_ROOT/occupied" ] && grep -qx "$1" "$S5_TEST_ROOT/occupied"; then exit 1; fi
if [ -f "$S5_TEST_ROOT/unobservable" ]; then exit 2; fi
exit 0
PROBE
chmod 0755 "$S5_PORT_PROBE"
export S5_PORT_PROBE

printf '1\n' >"$S5_TEST_ROOT/lang"
S5_LANG=''
s5_select_language <"$S5_TEST_ROOT/lang" >"$S5_TEST_ROOT/lang.out" 2>&1
assert_eq "language 1 selects Chinese" 0 "$?"
assert_eq "language 1 sets zh" zh "$S5_LANG"
printf '2\n' >"$S5_TEST_ROOT/lang"
s5_select_language <"$S5_TEST_ROOT/lang" >"$S5_TEST_ROOT/lang.out" 2>&1
assert_eq "language 2 selects English" 0 "$?"
assert_eq "language 2 sets en" en "$S5_LANG"

S5_PORT=''
S5_USERNAME=''
S5_PASSWORD=''
s5env_answers_placeholder=''
printf '\n\n\n' >"$S5_TEST_ROOT/values"
S5_LANG=en
t_run sh -c '. "$1"; S5_LANG=en; S5_PORT_PROBE="$2"; export S5_PORT_PROBE; s5_prompt_port; s5_prompt_username; s5_prompt_password' sh "$ROOT/socks5.sh" "$S5_PORT_PROBE" <"$S5_TEST_ROOT/values"
assert_eq "empty value stream reaches random generation" 0 "$T_STATUS"

S5_PORT=23456
S5_USERNAME=alice
S5_PASSWORD='Secret_123~x'
S5_SECRET=$S5_PASSWORD
S5_LISTEN=127.0.0.1
mkdir -p "$S5_SYSCONFDIR" "$S5_STATEDIR"
config=$(s5_config_render)
printf '%s\n' "$config" >"$S5_CFG"
S5_CONFIG_SHA256=$(sha256sum "$S5_CFG" | awk '{print $1}')
S5_ARCHNAME=amd64
s5_asset_select
S5_INIT=systemd
S5_ACCOUNT_UID=900
S5_ACCOUNT_GID=900
mkdir -p "$S5_UNITDIR"
s5_write_unit >/dev/null 2>&1
# S5_UNIT comes from the sourced socks5.sh; it is not a typo for S5_INIT.
# shellcheck disable=SC2153
S5_UNIT_SHA256=$(sha256sum "$S5_UNIT" | awk '{print $1}')
s5_state_write
assert_file_exists "Xray state is written" "$S5_STATE"
assert_mode "Xray state is root-only" 600 "$S5_STATE"
assert_not_contains "state never stores password" "$S5_PASSWORD" "$(cat "$S5_STATE")"
assert_eq "state identifies Xray" xray "$(s5_state_get engine)"
assert_eq "state identifies mixed" mixed "$(s5_state_get protocol)"
assert_eq "state disables UDP" false "$(s5_state_get udp)"
assert_eq "state has unit ownership hash" "$S5_UNIT_SHA256" "$(s5_state_get unit_sha256)"

# Old 3proxy namespace is deliberately untouched by this branch.
mkdir -p "$S5_TEST_ROOT/etc/socks5-manager" "$S5_TEST_ROOT/var/lib/socks5-manager" "$S5_TEST_ROOT/usr/local/libexec/socks5-manager"
printf 'legacy\n' >"$S5_TEST_ROOT/etc/socks5-manager/3proxy.cfg"
printf 'legacy\n' >"$S5_TEST_ROOT/var/lib/socks5-manager/state"
printf 'legacy\n' >"$S5_TEST_ROOT/usr/local/libexec/socks5-manager/3proxy"
source=$(cat "$ROOT/socks5.sh")
assert_not_contains "production has no legacy namespace" 'socks5-manager' "$source"
assert_not_contains "production has no 3proxy binary" '3proxy' "$source"
assert_file_exists "legacy config survives" "$S5_TEST_ROOT/etc/socks5-manager/3proxy.cfg"
assert_file_exists "legacy state survives" "$S5_TEST_ROOT/var/lib/socks5-manager/state"

# The service unit has no credential-bearing argument and runs as the dedicated user.
mkdir -p "$S5_UNITDIR"
s5_write_unit >/dev/null 2>&1
# S5_UNIT comes from the sourced socks5.sh; it is not a typo for S5_INIT.
# shellcheck disable=SC2153
unit=$(cat "$S5_UNIT")
assert_contains "unit uses the dedicated user" 'User=xray-socks5' "$unit"
assert_contains "unit invokes Xray run" 'ExecStart=' "$unit"
assert_contains "unit uses explicit config" 'run -c' "$unit"
assert_contains "unit restarts on failure" 'Restart=on-failure' "$unit"
assert_not_contains "unit does not contain password" "$S5_PASSWORD" "$unit"

# A config the state does not describe is refused. The status that separates it
# from a corrupt state file is asserted in test_xray_install.sh, where an install
# has actually run: this file writes no binary, so the asset comparison fails
# first and s5_state_load never reaches the configuration hash.
printf 'changed\n' >"$S5_CFG"
t_run s5_state_load
assert_ne "external config change is refused" 0 "$T_STATUS"

# One diagnosis serves every command that loads state. A config the operator
# changed is not a corrupt state file -- the state is intact and nothing has been
# touched -- and an absent state file is not an invalid one either.
t_run s5_report_state_load 0
assert_eq "a loaded state is not an error" 0 "$T_STATUS"
assert_eq "a loaded state reports nothing" '' "$T_OUT"
t_run s5_report_state_load 2
assert_ne "an externally changed config is refused" 0 "$T_STATUS"
assert_contains "an externally changed config says so" \
    'changed externally' "$T_OUT"
t_run s5_report_state_load 1
assert_contains "a present but unusable state file says so" \
    'invalid state file' "$T_OUT"
_ctstate=$S5_STATE
S5_STATE=$S5_TEST_ROOT/nothing-installed.state
t_run s5_report_state_load 1
assert_contains "an absent state file reports nothing installed" \
    'no xray-socks5 installation was found' "$T_OUT"
assert_not_contains "an absent state file is not called invalid" \
    'invalid state file' "$T_OUT"
S5_STATE=$_ctstate

# S5_LIB_ONLY makes the script define its functions and skip dispatch, so an
# outside caller exporting it turned install into a silent no-op that still
# exited 0. The subshell clears every other test-mode variable so the refusal is
# attributable to this one, and the control proves the guard passes without it.
_ctguard=$( (
    S5_TEST_MODE=0
    unset S5_LIB_ONLY S5_TEST_ROOT S5_ASSUME_ROOT S5_SKIP_OWNERSHIP
    unset S5_PORT_PROBE S5_LISTENER_PROBE S5_TEST_ASSET_PATH S5_TEST_ADDR_PATH
    unset S5_OSRELEASE S5_LISTEN
    s5_guard_environment
) 2>&1 ) && _ctgs=0 || _ctgs=$?
assert_eq "the guard passes with no test-mode variable set" 0 "$_ctgs"
_ctguard=$( (
    S5_TEST_MODE=0
    unset S5_LIB_ONLY S5_TEST_ROOT S5_ASSUME_ROOT S5_SKIP_OWNERSHIP
    unset S5_PORT_PROBE S5_LISTENER_PROBE S5_TEST_ASSET_PATH S5_TEST_ADDR_PATH
    unset S5_OSRELEASE S5_LISTEN
    S5_LIB_ONLY=1
    s5_guard_environment
) 2>&1 ) && _ctgs=0 || _ctgs=$?
assert_ne "S5_LIB_ONLY is refused outside test mode" 0 "$_ctgs"
assert_contains "the refusal names S5_LIB_ONLY" 'S5_LIB_ONLY' "$_ctguard"

# All supported input values are bounded before JSON generation.
for bad in '1:2' 'line
break' '"quoted"'; do
    S5_PASSWORD=$bad
    t_run s5_config_render
    assert_ne "invalid password is refused" 0 "$T_STATUS"
done
S5_PASSWORD='Secret_123~x'
S5_LISTEN='127.0.0.1
include evil'
t_run s5_config_render
assert_ne "multiline listen is refused" 0 "$T_STATUS"

# A catalog miss must not be silent. Every key but the bilingual lang.* pair
# renders through `case "$S5_LANG"`, so an unset language used to return the empty
# string with status 0 -- a mistyped key made a fatal error print nothing while
# the caller still exited non-zero, which is the undiagnosable failure this
# branch spent a dozen CI commits chasing.
_msglang=$S5_LANG
S5_LANG=en
t_run s5_msg bogus.key.no.such
assert_ne "an unknown message key is refused" 0 "$T_STATUS"
t_run s5_msg_err bogus.key.no.such
assert_contains "an unknown key is still reported" 'bogus.key.no.such' "$T_OUT"
t_run s5_msg_err state.invalid
assert_contains "a wrong-arity call is still reported" 'state.invalid' "$T_OUT"
S5_LANG=fr
t_run s5_msg install.cancelled
assert_ne "an unknown language is refused" 0 "$T_STATUS"
S5_LANG=''
t_run s5_msg lang.prompt
assert_eq "the language prompt renders before a language is chosen" 0 "$T_STATUS"
assert_contains "the language prompt is bilingual" 'Choose language' "$T_OUT"
S5_LANG=$_msglang

# Each operation must require only what it runs. status reads service and
# listener state; restart re-runs the data-plane verification and so does need
# python3. Requiring it for status made status refuse to start on a minimal
# systemd image, where nothing on that path provisions it either. The backend is
# pinned through the os-release fixture and then asserted, because s5_precheck
# detects the platform itself and would otherwise test one backend twice.
s5_require_commands() { printf '%s\n' "$*"; return 0; }
s5_install_runtime_dependencies() { return 0; }
for _pccase in systemd:debian-12 openrc:alpine-3.20; do
    _pcinit=${_pccase%%:*}
    S5_OSRELEASE="$ROOT/tests/fixtures/os-release/${_pccase#*:}"
    # Redirected to a file rather than captured: a command substitution runs
    # s5_precheck in a subshell, so the backend it detects would be lost and both
    # iterations would silently test the host's own init.
    s5_precheck status >"$S5_TEST_ROOT/pc.status" 2>&1
    _pcstatus=$(cat "$S5_TEST_ROOT/pc.status")
    assert_eq "the $_pcinit fixture selects that backend" "$_pcinit" "$S5_INIT"
    s5_precheck restart >"$S5_TEST_ROOT/pc.restart" 2>&1
    _pcrestart=$(cat "$S5_TEST_ROOT/pc.restart")
    assert_not_contains "$_pcinit status does not require python3" \
        'python3' "$_pcstatus"
    assert_contains "$_pcinit restart still requires python3" \
        'python3' "$_pcrestart"
done
S5_OSRELEASE="$ROOT/tests/fixtures/os-release/debian-12"
s5_precheck status >/dev/null 2>&1

# BusyBox ships an unzip that rejects -Z outright, and -Z1 is where the archive
# inspection gets its member list, so a present unzip proves nothing. Detecting it
# in the precheck tells the operator the tool cannot do the job; without that the
# 21 MB archive downloads and hash-verifies and is then reported invalid.
# Substituted as a shell function rather than through PATH: BusyBox sh resolves
# applet names such as unzip before PATH, so a stub directory would be ignored
# there while a function shadows the applet in all three shells.
unzip() {
    [ "$1" = -Z ] || return 0
    case "$(cat "$S5_TEST_ROOT/unzip-mode" 2>/dev/null)" in
    busybox) printf 'unzip: invalid option -- %s\n' "'Z'" >&2; return 1 ;;
    banner) printf 'ZipInfo 3.00 of 20 April 2009, by the Info-ZIP group.\n'; return 2 ;;
    *) printf 'ZipInfo 3.00 of 20 April 2009, by the Info-ZIP group.\n'; return 0 ;;
    esac
}
printf 'infozip\n' >"$S5_TEST_ROOT/unzip-mode"
s5_unzip_lists_members
assert_eq "an Info-ZIP unzip lists members" 0 "$?"
printf 'banner\n' >"$S5_TEST_ROOT/unzip-mode"
s5_unzip_lists_members
assert_eq "a nonzero status with the zipinfo banner still counts" 0 "$?"
printf 'busybox\n' >"$S5_TEST_ROOT/unzip-mode"
s5_unzip_lists_members
assert_ne "a BusyBox unzip cannot list members" 0 "$?"

_pcinstall=$(s5_precheck install 2>&1) && _pcis=0 || _pcis=$?
assert_ne "install refuses an unzip that cannot list members" 0 "$_pcis"
assert_contains "the refusal names the tool rather than the archive" \
    'unzip with -Z' "$_pcinstall"
_pcstat=$(s5_precheck status 2>&1) && _pcss=0 || _pcss=$?
assert_eq "status never needs the member listing" 0 "$_pcss"
printf 'infozip\n' >"$S5_TEST_ROOT/unzip-mode"
_pcinstall=$(s5_precheck install 2>&1) && _pcis=0 || _pcis=$?
assert_eq "install accepts an unzip that lists members" 0 "$_pcis"
unset -f unzip
t_summary
