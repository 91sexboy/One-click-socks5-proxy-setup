#!/bin/sh
# Xray mixed installer input, state, namespace and service contract tests.

S5T_NAME=test_xray_contract
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
ROOT=${S5_REPO_ROOT}
t_mktestroot
t_run python3 - "$ROOT/socks5.sh" "$ROOT/tests/run.sh" <<'PY'
from pathlib import Path
import re
import sys

source, runner = (Path(path).read_text() for path in sys.argv[1:])
reads = set(re.findall(r'\$\{?(S5_[A-Z0-9_]+)', source))
initialized = set(re.findall(r'^\s*(S5_[A-Z0-9_]+)=', source, re.M))
guard = source.split('s5_guard_environment() {', 1)[1].split('\n}', 1)[0]
guarded = set(re.findall(r'\$\{?(S5_[A-Z0-9_]+)', guard))
expected = (reads - initialized - {'S5_SERVER_IPV4'}) | guarded
actual = set(re.findall(r'-u (S5_[A-Z0-9_]+)', runner))
if actual != expected:
    raise AssertionError('runner test environment mismatch: missing=' +
                         ','.join(sorted(expected - actual)) + ' extra=' +
                         ','.join(sorted(actual - expected)))
PY
assert_eq "runner clears exactly the production test environment" 0 "$T_STATUS"
if [ "$T_STATUS" -ne 0 ]; then printf '%s\n' "$T_OUT" >&2; fi
t_source_production ''

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
printf '\n\n\n' >"$S5_TEST_ROOT/values"
S5_LANG=en
# A blank answer to each prompt has to reach generation and produce a value the
# validators accept. Asserting only the exit status let a prompt return 0 having
# generated nothing. The subshell reports whether the three values validate, never
# the values themselves, so a failure here cannot publish the password.
S5T_PROMPT_SHELL=${S5_TEST_SHELL:-sh}
export S5T_PROMPT_SHELL
t_stub 'prompt shell' <<'SHELL'
#!/bin/sh
printf '%s\n' "$S5T_PROMPT_SHELL" >"$S5_TEST_ROOT/prompt-shell-used"
# A configured interpreter can contain multiple words, such as busybox sh.
# shellcheck disable=SC2086
exec $S5T_PROMPT_SHELL "$@"
SHELL
S5_TEST_SHELL="$S5_TEST_ROOT/bin/prompt shell"
t_run "$S5_TEST_SHELL" -c '. "$1"; S5_LANG=en; S5_PORT_PROBE="$2"; export S5_PORT_PROBE; s5_prompt_port; s5_prompt_username; s5_prompt_password; s5_valid_port "$S5_PORT" && s5_valid_username "$S5_USERNAME" && s5_valid_password "$S5_PASSWORD" && printf generated' sh "$ROOT/socks5.sh" "$S5_PORT_PROBE" <"$S5_TEST_ROOT/values"
S5_TEST_SHELL=$S5T_PROMPT_SHELL
assert_file_exists "blank prompts run through the configured interpreter" "$S5_TEST_ROOT/prompt-shell-used"
assert_eq "prompt interpreter matches the selected shell" "$S5T_PROMPT_SHELL" "$(cat "$S5_TEST_ROOT/prompt-shell-used" 2>/dev/null)"
assert_eq "empty value stream reaches random generation" 0 "$T_STATUS"
assert_contains "each generated value satisfies its own validator" \
    generated "$T_OUT"

# s5_random_port must also generate a valid port under BusyBox, where od emits a
# leading space that the old 'tr -d [:space:]' idiom left in place (BusyBox reads
# that as a literal character set, not the whitespace class). This call runs under
# the shell the suite was invoked with, so the BusyBox leg exercises BusyBox od/tr
# directly; a blank port answer on Alpine used to abort the install here.
_rp=$(s5_random_port) && _rprc=0 || _rprc=$?
assert_eq "random port generation succeeds" 0 "$_rprc"
s5_valid_port "$_rp"; _rpv=$?
assert_eq "the generated random port is valid" 0 "$_rpv"

# An update leaves S5_PORT holding the port the running service owns; a blank
# answer must keep it rather than rotate to a random one (SPEC 5: the port the
# service already owns is accepted, ownership verified through the listener).
# The port probe reports 25000 busy, and in test mode s5_listener_state reads
# that same probe, so s5_port_owned_by_service confirms ownership.
S5_PORT=25000
printf '25000\n' >"$S5_TEST_ROOT/occupied"
printf '\n' >"$S5_TEST_ROOT/port.blank"
s5_prompt_port <"$S5_TEST_ROOT/port.blank" >/dev/null 2>&1
assert_eq "a blank port on update keeps the owned port" 25000 "$S5_PORT"
# A blank answer with no current port (a fresh install) still generates one.
S5_PORT=''
s5_prompt_port <"$S5_TEST_ROOT/port.blank" >/dev/null 2>&1
s5_valid_port "$S5_PORT"; _rpfresh=$?
assert_eq "a blank port on a fresh install still generates a valid port" 0 "$_rpfresh"
assert_ne "a fresh install does not reuse the update's owned port" 25000 "$S5_PORT"
rm -f "$S5_TEST_ROOT/occupied"

S5_PORT=23456
S5_USERNAME=alice
S5_PASSWORD='Secret_123~x'
S5_SECRET=$S5_PASSWORD
S5_LISTEN=127.0.0.1
mkdir -p "$S5_SYSCONFDIR" "$S5_STATEDIR"
config=$(s5_config_render)
printf '%s\n' "$config" >"$S5_CFG"
S5_CONFIG_SHA256=$(t_sha256 "$S5_CFG")
S5_ARCHNAME=amd64
s5_asset_select
S5_INIT=systemd
S5_ACCOUNT_UID=900
S5_ACCOUNT_GID=900
mkdir -p "$S5_UNITDIR"
s5_write_unit >/dev/null 2>&1
S5_UNIT_SHA256=$(t_sha256 "$S5_SERVICE_ARTIFACT")
s5_state_write
assert_file_exists "Xray state is written" "$S5_STATE"
assert_mode "Xray state is root-only" 600 "$S5_STATE"
assert_not_contains "state never stores password" "$S5_PASSWORD" "$(cat "$S5_STATE")"
assert_eq "state identifies Xray" xray "$(t_state_get engine)"
assert_eq "state identifies mixed" mixed "$(t_state_get protocol)"
assert_eq "state disables UDP" false "$(t_state_get udp)"
assert_eq "state has unit ownership hash" "$S5_UNIT_SHA256" "$(t_state_get unit_sha256)"

source=$(cat "$ROOT/socks5.sh")
assert_not_contains "production has no legacy namespace" 'socks5-manager' "$source"
assert_not_contains "production has no 3proxy binary" '3proxy' "$source"

# The service unit has no credential-bearing argument and runs as the dedicated user.
mkdir -p "$S5_UNITDIR"
s5_write_unit >/dev/null 2>&1
unit=$(cat "$S5_SERVICE_ARTIFACT")
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

# detect.init is the catch-all for an init this script does not recognise, on a
# branch that supports both systemd and OpenRC, so naming only systemd sends the
# operator after the wrong thing. An apk failure is likewise not a missing command.
S5_LANG=en
t_run s5_msg detect.init
assert_eq "the init diagnostic renders" 0 "$T_STATUS"
assert_not_contains "the init diagnostic does not name systemd alone" \
    'a working systemd is required' "$T_OUT"
assert_contains "the init diagnostic names OpenRC too" 'OpenRC' "$T_OUT"
t_run s5_msg packages.failed apk
assert_eq "a package-install failure has its own key" 0 "$T_STATUS"
assert_contains "it names the package manager" 'apk' "$T_OUT"
S5_LANG=zh
t_run s5_msg packages.failed apk
assert_eq "the package-install failure renders in Chinese" 0 "$T_STATUS"
S5_LANG=$_msglang

# Each operation must require only what it runs. status reads service and
# listener state; restart re-runs the data-plane verification and so does need
# python3. Requiring it for status made status refuse to start on a minimal
# systemd image, where nothing on that path provisions it either. The backend is
# pinned through the os-release fixture and then asserted, because s5_precheck
# detects the platform itself and would otherwise test one backend twice.
s5_require_commands() { printf '%s\n' "$*"; return 0; }
s5_install_runtime_dependencies() { return 0; }
mkdir -p "$S5_TEST_ROOT/run/systemd/system" "$S5_TEST_ROOT/run/openrc"
: >"$S5_TEST_ROOT/run/openrc/softlevel"
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

# SPEC 5 runs the service through the platform's native manager, so install and
# update must require that manager up front like every other command does. The
# systemd install/update case listed the account and archive tools but not
# systemctl, so a systemd host missing it passed precheck and failed later with no
# diagnostic naming the tool. The OpenRC case has always required rc-service.
S5_OSRELEASE="$ROOT/tests/fixtures/os-release/debian-12"
_pcreq=$(s5_precheck install 2>&1)
assert_contains "systemd install requires systemctl" 'systemctl' "$_pcreq"
_pcreq=$(s5_precheck update 2>&1)
assert_contains "systemd update requires systemctl" 'systemctl' "$_pcreq"
S5_OSRELEASE="$ROOT/tests/fixtures/os-release/alpine-3.20"
_pcreq=$(s5_precheck install 2>&1)
assert_contains "openrc install requires its service manager" 'rc-service' "$_pcreq"
for _init_case in systemd:debian-12 openrc:alpine-3.20; do
    _init_backend=${_init_case%%:*}
    S5_OSRELEASE="$ROOT/tests/fixtures/os-release/${_init_case#*:}"
    case "$_init_backend" in
    systemd) rmdir "$S5_TEST_ROOT/run/systemd/system" ;;
    openrc) rm "$S5_TEST_ROOT/run/openrc/softlevel" ;;
    esac
    for _init_mode in install update; do
        t_run s5_precheck "$_init_mode"
        assert_ne "$_init_mode refuses an unbooted $_init_backend" 0 "$T_STATUS"
        assert_contains "unbooted $_init_backend is diagnosed before installation" 'no supported service manager was found' "$T_OUT"
    done
    rm -f "$S5_TEST_ROOT/init-download" "$S5_TEST_ROOT/init-account" "$S5_TEST_ROOT/init-unit"
    T_OUT=$( (
        s5_download_engine() { : >"$S5_TEST_ROOT/init-download"; return 1; }
        s5_account_create() { : >"$S5_TEST_ROOT/init-account"; return 1; }
        s5_write_unit() { : >"$S5_TEST_ROOT/init-unit"; return 1; }
        s5_cmd_install
    ) 2>&1) && T_STATUS=0 || T_STATUS=$?
    assert_ne "install command refuses unbooted $_init_backend" 0 "$T_STATUS"
    assert_contains "install command reports the init refusal" 'no supported service manager was found' "$T_OUT"
    assert_file_absent "unbooted $_init_backend never reaches download" "$S5_TEST_ROOT/init-download"
    assert_file_absent "unbooted $_init_backend never creates an account" "$S5_TEST_ROOT/init-account"
    assert_file_absent "unbooted $_init_backend never writes a service artifact" "$S5_TEST_ROOT/init-unit"
    for _init_mode in status restart uninstall; do
        t_run s5_precheck "$_init_mode"
        assert_eq "$_init_mode remains available without $_init_backend startup marker" 0 "$T_STATUS"
    done
    case "$_init_backend" in
    systemd) mkdir "$S5_TEST_ROOT/run/systemd/system" ;;
    openrc) : >"$S5_TEST_ROOT/run/openrc/softlevel" ;;
    esac
    for _init_mode in install update; do
        t_run s5_precheck "$_init_mode"
        assert_eq "$_init_mode accepts booted $_init_backend" 0 "$T_STATUS"
    done
done
S5_OSRELEASE="$ROOT/tests/fixtures/os-release/debian-12"
unset -f unzip

# Redirected prompts cannot rely on terminal echo to supply their line breaks.
_prompt_output=$S5_TEST_ROOT/prompt.out
s5_msg_ask uninstall.confirm 2>"$_prompt_output"
assert_eq "the uninstall question renders" 0 "$?"
assert_eq "the redirected uninstall question terminates its line" 1 \
    "$(wc -l <"$_prompt_output" | tr -d '[:space:]')"
assert_contains "the uninstall question is the catalog text" \
    'Remove the Xray mixed proxy' "$(cat "$_prompt_output")"

printf 'y\n' | s5_confirm_install 2>"$_prompt_output" >/dev/null
assert_eq "the redirected install question terminates its line" 1 \
    "$(wc -l <"$_prompt_output" | tr -d '[:space:]')"
printf 'y\n' | s5_confirm_update 2>"$_prompt_output" >/dev/null
assert_eq "the redirected update question terminates its line" 1 \
    "$(wc -l <"$_prompt_output" | tr -d '[:space:]')"

# An unrenderable prompt must not be answered on the operator's behalf. The stub
# lives in a subshell so the real catalog survives for anything after this.
if ( s5_msg() { return 1; }; printf 'y\n' | s5_confirm_install ) 2>"$_prompt_output" >/dev/null
then _prompt_status=0; else _prompt_status=$?; fi
assert_ne "an unrenderable install prompt is not taken as consent" 0 "$_prompt_status"
assert_contains "an unrenderable install prompt says so" \
    'cannot render message' "$(cat "$_prompt_output")"
if ( s5_msg() { return 1; }; printf 'y\n' | s5_confirm_update ) 2>"$_prompt_output" >/dev/null
then _prompt_status=0; else _prompt_status=$?; fi
assert_ne "an unrenderable update prompt is not taken as consent" 0 "$_prompt_status"

while IFS='|' read -r _catalog_key _catalog_arg1 _catalog_arg2 _catalog_en _catalog_zh; do
    set --
    [ -z "$_catalog_arg1" ] || set -- "$_catalog_arg1"
    [ -z "$_catalog_arg2" ] || set -- "$@" "$_catalog_arg2"
    for S5_LANG in en zh; do
        t_run s5_msg "$_catalog_key" "$@"
        assert_eq "$_catalog_key renders in $S5_LANG" 0 "$T_STATUS"
        case "$S5_LANG" in en) _catalog_expected=$_catalog_en ;; zh) _catalog_expected=$_catalog_zh ;; esac
        assert_eq "$_catalog_key has the expected $S5_LANG text" "$_catalog_expected" "$T_OUT"
    done
done <<'CATALOG'
status.state.running|||running|运行中
status.state.stopped|||stopped|已停止
status.state.unverified|||unverified|未验证
account.remove.identity|900|901|account identity mismatch: recorded 900/901|账户身份不匹配：记录值为 900/901。
account.remove.user|xray-socks5||could not remove service account: xray-socks5|无法删除服务账户：xray-socks5。
account.remove.user.exists|xray-socks5||service account still exists after removal: xray-socks5|删除后服务账户仍然存在：xray-socks5。
account.remove.user.verify|xray-socks5||could not verify service account removal: xray-socks5|无法验证服务账户已删除：xray-socks5。
account.remove.group|xray-socks5||could not remove service group: xray-socks5|无法删除服务组：xray-socks5。
account.remove.group.before|xray-socks5||could not verify service group before removal: xray-socks5|删除前无法验证服务组：xray-socks5。
account.remove.group.exists|xray-socks5||service group still exists after removal: xray-socks5|删除后服务组仍然存在：xray-socks5。
account.remove.group.verify|xray-socks5||could not verify service group removal: xray-socks5|无法验证服务组已删除：xray-socks5。
uninstall.symlink|/owned||refusing symlink during uninstall: /owned|卸载时拒绝符号链接：/owned。
uninstall.file|/owned||could not remove owned file: /owned|无法删除自有文件：/owned。
uninstall.notdir|/owned||owned path is not a directory: /owned|自有路径不是目录：/owned。
uninstall.nonempty|/owned||refusing non-empty owned directory: /owned|拒绝删除非空自有目录：/owned。
uninstall.directory|/owned||could not remove owned directory: /owned|无法删除自有目录：/owned。
detect.unzip|||required command(s) are missing: unzip with -Z (Info-ZIP).|缺少必要命令：支持 -Z 的 unzip（Info-ZIP）。
usage.unknown|bogus||unknown command: bogus.|未知命令：bogus。
CATALOG

S5_LANG=en
while IFS='|' read -r _confirm_mode _confirm_answer _confirm_status; do
    printf '%s\n' "$_confirm_answer" >"$S5_TEST_ROOT/confirm.answer"
    t_run "s5_confirm_$_confirm_mode" <"$S5_TEST_ROOT/confirm.answer"
    assert_eq "$_confirm_mode accepts exactly its documented confirmation answers" "$_confirm_status" "$T_STATUS"
    if [ "$_confirm_status" = 1 ]; then
        assert_contains "$_confirm_mode reports a declined answer" 'operation cancelled.' "$T_OUT"
    else
        assert_not_contains "$_confirm_mode never calls an accepted answer cancelled" 'operation cancelled.' "$T_OUT"
    fi
done <<'CONFIRM'
install||0
install|y|0
install|Y|0
install|yes|0
install|YES|0
install|Yes|0
install|n|1
install|true|1
install| y|1
update||1
update|y|0
update|Y|0
update|yes|1
update|YES|1
update|Yes|1
update|n|1
CONFIRM
for _confirm_mode in install update; do
    t_run "s5_confirm_$_confirm_mode" </dev/null
    assert_eq "$_confirm_mode rejects confirmation EOF" 1 "$T_STATUS"
    assert_not_contains "$_confirm_mode distinguishes EOF from declining" 'operation cancelled.' "$T_OUT"
done

t_summary
