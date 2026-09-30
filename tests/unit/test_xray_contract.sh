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


def mismatch(source, runner):
    # Every S5_* the script reads without assigning it first comes from the
    # environment, test seam or operator override alike, so the runner clears
    # all of them. No name is exempt: an exemption is where a leak hides.
    reads = set(re.findall(r'\$\{?(S5_[A-Z0-9_]+)', source))
    initialized = set(re.findall(r'^\s*(S5_[A-Z0-9_]+)=', source, re.M))
    guard = source.split('s5_guard_environment() {', 1)[1].split('\n}', 1)[0]
    guarded = set(re.findall(r'\$\{?(S5_[A-Z0-9_]+)', guard))
    expected = (reads - initialized) | guarded
    actual = set(re.findall(r'-u (S5_[A-Z0-9_]+)', runner))
    if actual != expected:
        return ('missing=' + ','.join(sorted(expected - actual)) +
                ' extra=' + ','.join(sorted(actual - expected)))
    return ''


problem = mismatch(source, runner)
if problem:
    raise AssertionError('runner test environment mismatch: ' + problem)
# Controls: a new production override read, and a dropped runner entry, must
# both be caught, or the oracle above proves nothing.
if mismatch(source + '\nx=${S5_FAKE_OVERRIDE:-}\n', runner) != 'missing=S5_FAKE_OVERRIDE extra=':
    raise AssertionError('a new production override read was not caught')
if mismatch(source, runner.replace('-u S5_SERVER_PORT ', '')) != 'missing=S5_SERVER_PORT extra=':
    raise AssertionError('a dropped runner entry was not caught')
PY
assert_eq "runner clears exactly the production test environment" 0 "$T_STATUS"
if [ "$T_STATUS" -ne 0 ]; then printf '%s\n' "$T_OUT" >&2; fi
# The same guarantee observed end to end: a maintainer's exported overrides do
# not reach a test file that asserts listen ports and card contents.
# shellcheck disable=SC2086
t_run env S5_LISTEN_PORT=1 S5_SERVER_IPV4=198.51.100.7 S5_SERVER_PORT=443 \
    S5_TEST_SHELL="${S5_TEST_SHELL:-sh}" sh "$ROOT/tests/run.sh" test_xray_show
assert_eq "exported operator overrides do not change test results" 0 "$T_STATUS"
if [ "$T_STATUS" -ne 0 ]; then printf '%s\n' "$T_OUT" >&2; fi

# A test interrupted by a signal cleans its root and stops; it used to clean up
# and then keep running assertions against the deleted root.
cat >"$S5_TEST_ROOT/interrupted.sh" <<'INTERRUPTED'
. "$S5_REPO_ROOT/tests/lib/assert.sh"
t_mktestroot
printf '%s\n' "$S5_TEST_ROOT" >"$1"
kill -TERM $$
printf 'continued after TERM\n'
INTERRUPTED
# shellcheck disable=SC2086
t_run env -u S5_TEST_ROOT ${S5_TEST_SHELL:-sh} "$S5_TEST_ROOT/interrupted.sh" "$S5_TEST_ROOT/interrupted.root"
assert_eq "a test killed by TERM exits with the signal status" 143 "$T_STATUS"
assert_not_contains "a test killed by TERM stops running" 'continued after TERM' "$T_OUT"
assert_file_absent "a test killed by TERM removes its root" "$(cat "$S5_TEST_ROOT/interrupted.root")"
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

# Rejection sampling is tested with deterministic od bytes: rejected values must
# not bias output, accepted endpoints remain in range, and retries are bounded.
od() { printf '255 0 2\n'; }
assert_eq "random strings discard the uneven byte tail" ac "$(s5_random_string 2 abc)"
_od_values=$S5_TEST_ROOT/od-values
printf '0\n40000\n40001\n1\n' >"$_od_values"
od() {
    _od_value=$(sed -n '1p' "$_od_values")
    sed '1d' "$_od_values" >"$_od_values.next"
    mv "$_od_values.next" "$_od_values"
    printf '%s\n' "$_od_value"
}
assert_eq "random port accepts the lower bound" 20000 "$(s5_random_port)"
assert_eq "random port accepts the upper bound" 60000 "$(s5_random_port)"
assert_eq "random port rejects an out-of-range draw before retry" 20001 "$(s5_random_port)"
: >"$_od_values"
_i=0
while [ "$_i" -lt 64 ]; do printf '65535\n' >>"$_od_values"; _i=$((_i + 1)); done
t_run s5_random_port
assert_ne "random port retry exhaustion fails" 0 "$T_STATUS"
unset -f od

# An update leaves S5_PORT holding the port the running service owns; a blank
# answer must keep it rather than rotate to a random one (SPEC 5: the port the
# service already owns is accepted, ownership verified through the listener).
# The port probe reports 25000 busy, and in test mode s5_listener_state reads
# that same probe, so s5_port_owned_by_service confirms ownership.
S5_PORT=25000
printf '25000\n' >"$S5_TEST_ROOT/occupied"
printf '\n' >"$S5_TEST_ROOT/port.blank"
s5_prompt_port <"$S5_TEST_ROOT/port.blank" 2>"$S5_TEST_ROOT/port.out" >/dev/null
assert_eq "a blank port on update keeps the owned port" 25000 "$S5_PORT"
assert_not_contains "a verified recorded port is kept without a diagnosis" \
    'could not verify' "$(cat "$S5_TEST_ROOT/port.out")"
# A blank answer with no current port (a fresh install) still generates one.
S5_PORT=''
s5_prompt_port <"$S5_TEST_ROOT/port.blank" >/dev/null 2>&1
s5_valid_port "$S5_PORT"; _rpfresh=$?
assert_eq "a blank port on a fresh install still generates a valid port" 0 "$_rpfresh"
assert_ne "a fresh install does not reuse the update's owned port" 25000 "$S5_PORT"
rm -f "$S5_TEST_ROOT/occupied"

# The other blank-answer outcome on update: nothing answers on the recorded port,
# so ownership cannot be verified. Rotating to a random port there would move the
# operator's listener without a word, so the port is named and the question is
# asked again -- and the loop has to accept the explicit answer that follows.
S5_PORT=25000
printf '\n\n24500\n' >"$S5_TEST_ROOT/port.unverified"
s5_prompt_port <"$S5_TEST_ROOT/port.unverified" 2>"$S5_TEST_ROOT/port.out" >/dev/null
_rpunv=$?
assert_eq "an unverified recorded port re-asks instead of failing" 0 "$_rpunv"
assert_contains "the unverified recorded port is named" \
    'could not verify that port 25000 belongs to this installation' \
    "$(cat "$S5_TEST_ROOT/port.out")"
assert_contains "the re-ask requires an explicit port" \
    'Port [enter explicitly]' "$(cat "$S5_TEST_ROOT/port.out")"
assert_eq "the rejected keep prompt is shown only once" 1 \
    "$(grep -c 'keep current 25000' "$S5_TEST_ROOT/port.out")"
assert_eq "the explicit answer after the refusal is taken" 24500 "$S5_PORT"

# A provider that forwards one fixed external port needs that exact port bound,
# and a blank answer must be able to mean it. The existing probe fixture controls
# which port is occupied, so these assertions remain in the parent shell and are
# counted by t_summary rather than disappearing inside a subshell.
S5_PORT=''
S5_LISTEN_PORT=56447
printf '\n' >"$S5_TEST_ROOT/listen.answers"
s5_prompt_port <"$S5_TEST_ROOT/listen.answers" 2>"$S5_TEST_ROOT/listen-override.out" >/dev/null
assert_eq "a blank answer takes the listen-port override" 56447 "$S5_PORT"
assert_contains "the prompt says which override blank will use" \
    'use S5_LISTEN_PORT' "$(cat "$S5_TEST_ROOT/listen-override.out")"

S5_PORT=''
S5_LISTEN_PORT=56447
printf '23456\n' >"$S5_TEST_ROOT/listen.answers"
s5_prompt_port <"$S5_TEST_ROOT/listen.answers" >/dev/null 2>&1
assert_eq "a typed port still wins over the override" 23456 "$S5_PORT"

S5_PORT=''
S5_LISTEN_PORT=99
printf '\n23456\n' >"$S5_TEST_ROOT/listen.answers"
s5_prompt_port <"$S5_TEST_ROOT/listen.answers" 2>"$S5_TEST_ROOT/listen-invalid.out" >/dev/null
assert_eq "an invalid override is consumed and re-asked once" 23456 "$S5_PORT"
assert_contains "an invalid override names the validation rule" \
    'port must be a decimal number from 1024 to 65535' \
    "$(cat "$S5_TEST_ROOT/listen-invalid.out")"
assert_contains "the re-ask falls back to the normal blank meaning" \
    'Enter = random 20000-60000' "$(cat "$S5_TEST_ROOT/listen-invalid.out")"

S5_PORT=''
S5_LISTEN_PORT='bad
injected-line'
printf '\n23456\n' >"$S5_TEST_ROOT/listen.answers"
s5_prompt_port <"$S5_TEST_ROOT/listen.answers" 2>"$S5_TEST_ROOT/listen-hostile.out" >/dev/null
assert_eq "a hostile invalid override is consumed and re-asked" 23456 "$S5_PORT"
assert_not_contains "an unvalidated override is never rendered" \
    'injected-line' "$(cat "$S5_TEST_ROOT/listen-hostile.out")"

S5_PORT=25000
S5_LISTEN_PORT=56447
printf '\n' >"$S5_TEST_ROOT/listen.answers"
s5_prompt_port <"$S5_TEST_ROOT/listen.answers" 2>"$S5_TEST_ROOT/listen-update.out" >/dev/null
assert_eq "the override takes precedence over keeping the current port" 56447 "$S5_PORT"
assert_contains "an update prompt does not falsely promise to keep the old port" \
    'use S5_LISTEN_PORT' "$(cat "$S5_TEST_ROOT/listen-update.out")"
assert_not_contains "the override prompt never promises a different action" \
    'keep current 25000' "$(cat "$S5_TEST_ROOT/listen-update.out")"

S5_PORT=''
S5_LISTEN_PORT=56447
printf '56447\n' >"$S5_TEST_ROOT/occupied"
printf '\n23456\n' >"$S5_TEST_ROOT/listen.answers"
s5_prompt_port <"$S5_TEST_ROOT/listen.answers" 2>"$S5_TEST_ROOT/listen-busy.out" >/dev/null
assert_eq "a busy foreign override is refused and re-asked" 23456 "$S5_PORT"
assert_contains "a busy foreign override is named" \
    'port 56447 is already in use' "$(cat "$S5_TEST_ROOT/listen-busy.out")"
rm -f "$S5_TEST_ROOT/occupied"
unset S5_LISTEN_PORT

# Length boundaries on both sides of every bound, through the prompt that
# writes a credential and through the validator that reads one back from an
# installed config. A prompt that refuses re-asks, so each rejected value is
# followed by a known good one and the result shows which was taken.
s5t_repeat() { _rep_out=''; _rep_i=0; while [ "$_rep_i" -lt "$2" ]; do _rep_out=$_rep_out$1; _rep_i=$((_rep_i + 1)); done; printf '%s' "$_rep_out"; }
S5_LANG=en
for _len_case in 2:1 3:0 32:0 33:1; do
    _len=${_len_case%%:*}
    _len_refused=${_len_case#*:}
    _len_value=$(s5t_repeat a "$_len")
    S5_USERNAME=''
    printf '%s\nfallback\n' "$_len_value" >"$S5_TEST_ROOT/len.answers"
    s5_prompt_username <"$S5_TEST_ROOT/len.answers" >/dev/null 2>"$S5_TEST_ROOT/len.out"
    if [ "$_len_refused" = 1 ]; then
        assert_eq "a $_len-character username is refused at the prompt" fallback "$S5_USERNAME"
        assert_contains "a $_len-character username names the rule" \
            'username must be 3-32 letters or digits' "$(cat "$S5_TEST_ROOT/len.out")"
        if s5_valid_stored_username "$_len_value"; then t_bad "a stored $_len-character username is refused"; else t_ok; fi
    else
        assert_eq "a $_len-character username is accepted at the prompt" "$_len_value" "$S5_USERNAME"
        if s5_valid_stored_username "$_len_value"; then t_ok; else t_bad "a stored $_len-character username is accepted"; fi
    fi
done
for _len_case in 11:1 12:0 128:0 129:1; do
    _len=${_len_case%%:*}
    _len_refused=${_len_case#*:}
    _len_value=$(s5t_repeat a "$_len")
    S5_PASSWORD=''
    printf '%s\nFallback12345\n' "$_len_value" >"$S5_TEST_ROOT/len.answers"
    s5_prompt_password <"$S5_TEST_ROOT/len.answers" >/dev/null 2>"$S5_TEST_ROOT/len.out"
    if [ "$_len_refused" = 1 ]; then
        assert_eq "a $_len-character password is refused at the prompt" Fallback12345 "$S5_PASSWORD"
        assert_contains "a $_len-character password names the rule" \
            'password must be 12-128 letters or digits' "$(cat "$S5_TEST_ROOT/len.out")"
        if s5_valid_stored_password "$_len_value"; then t_bad "a stored $_len-character password is refused"; else t_ok; fi
    else
        assert_eq "a $_len-character password is accepted at the prompt" "$_len_value" "$S5_PASSWORD"
        if s5_valid_stored_password "$_len_value"; then t_ok; else t_bad "a stored $_len-character password is accepted"; fi
    fi
done
S5_USERNAME=''
S5_PASSWORD=''

# The listening-port bounds, typed and through S5_LISTEN_PORT alike.
for _port_case in 1023:1 1024:0 65535:0 65536:1; do
    _port=${_port_case%%:*}
    _port_refused=${_port_case#*:}
    for _port_source in typed override; do
        S5_PORT=''
        if [ "$_port_source" = typed ]; then
            unset S5_LISTEN_PORT
            printf '%s\n23456\n' "$_port" >"$S5_TEST_ROOT/port.answers"
        else
            S5_LISTEN_PORT=$_port
            printf '\n23456\n' >"$S5_TEST_ROOT/port.answers"
        fi
        s5_prompt_port <"$S5_TEST_ROOT/port.answers" >/dev/null 2>"$S5_TEST_ROOT/port.out"
        if [ "$_port_refused" = 1 ]; then
            assert_eq "$_port_source port $_port is refused" 23456 "$S5_PORT"
            assert_contains "$_port_source port $_port names the rule" \
                'port must be a decimal number from 1024 to 65535' "$(cat "$S5_TEST_ROOT/port.out")"
        else
            assert_eq "$_port_source port $_port is accepted" "$_port" "$S5_PORT"
        fi
    done
done
unset S5_LISTEN_PORT
S5_PORT=''

# The other two prompts now share the port's blank-answer contract: on update a
# blank answer keeps the current value, while the empty fresh-install state still
# generates. The password question names the action but never the value it keeps.
S5_USERNAME=keptuser
printf '\n' >"$S5_TEST_ROOT/credential.blank"
s5_prompt_username <"$S5_TEST_ROOT/credential.blank" \
    2>"$S5_TEST_ROOT/username.out" >/dev/null
assert_eq "a blank username on update keeps the current account" keptuser "$S5_USERNAME"
assert_contains "the username question says blank keeps the current account" \
    'keep current keptuser' "$(cat "$S5_TEST_ROOT/username.out")"
S5_USERNAME=''
s5_prompt_username <"$S5_TEST_ROOT/credential.blank" >/dev/null 2>&1
s5_valid_username "$S5_USERNAME"; _spufresh=$?
assert_eq "a blank username on a fresh install still generates a valid value" 0 "$_spufresh"
assert_ne "fresh username generation does not reuse the old account" keptuser "$S5_USERNAME"

# A historical value can pass read-back validation while failing the narrowed
# write validator. It is diagnosed before the candidate render instead of making
# the update fail later without naming the cause; the blank re-answer generates.
S5_USERNAME=legacy_name
s5_prompt_username <"$S5_TEST_ROOT/credential.blank" \
    2>"$S5_TEST_ROOT/username.out" >/dev/null
s5_valid_username "$S5_USERNAME"; _spulegacy=$?
assert_eq "a legacy username is replaced by a write-valid value" 0 "$_spulegacy"
assert_ne "a legacy username is not silently kept" legacy_name "$S5_USERNAME"
assert_contains "a legacy username names why it cannot be kept" \
    'no longer writes' "$(cat "$S5_TEST_ROOT/username.out")"

S5_PASSWORD=Keptpassword12
S5_SECRET=$S5_PASSWORD
s5_prompt_password <"$S5_TEST_ROOT/credential.blank" \
    2>"$S5_TEST_ROOT/password.out" >/dev/null
assert_eq "a blank password on update keeps the current secret" \
    Keptpassword12 "$S5_PASSWORD"
assert_eq "a kept password also refreshes S5_SECRET" \
    Keptpassword12 "$S5_SECRET"
assert_contains "the password question says blank keeps the current secret" \
    'keep current' "$(cat "$S5_TEST_ROOT/password.out")"
assert_not_contains "the keep question never prints the password" \
    Keptpassword12 "$(cat "$S5_TEST_ROOT/password.out")"

S5_PASSWORD='legacy.pass~01'
S5_SECRET=$S5_PASSWORD
s5_prompt_password <"$S5_TEST_ROOT/credential.blank" \
    2>"$S5_TEST_ROOT/password.out" >/dev/null
s5_valid_password "$S5_PASSWORD"; _sppwlegacy=$?
assert_eq "a legacy password is replaced by a write-valid value" 0 "$_sppwlegacy"
assert_ne "a legacy password is not silently kept" 'legacy.pass~01' "$S5_PASSWORD"
assert_contains "a legacy password names why it cannot be kept" \
    'no longer writes' "$(cat "$S5_TEST_ROOT/password.out")"
assert_not_contains "the legacy diagnosis never prints the password" \
    'legacy.pass~01' "$(cat "$S5_TEST_ROOT/password.out")"
assert_eq "the generated replacement also refreshes S5_SECRET" \
    "$S5_PASSWORD" "$S5_SECRET"

S5_PASSWORD=''
S5_SECRET=''
s5_prompt_password <"$S5_TEST_ROOT/credential.blank" >/dev/null 2>&1
s5_valid_password "$S5_PASSWORD"; _sppwfresh=$?
assert_eq "a blank password on a fresh install still generates a valid value" 0 "$_sppwfresh"
assert_eq "fresh password generation also sets S5_SECRET" "$S5_PASSWORD" "$S5_SECRET"

S5_PORT=23456
S5_USERNAME=alice
S5_PASSWORD='Secret123xyz'
S5_SECRET=$S5_PASSWORD
S5_LISTEN=127.0.0.1
mkdir -p "$S5_SYSCONFDIR" "$S5_STATEDIR" "$S5_PREFIX"
config=$(s5_config_render)
printf '%s\n' "$config" >"$S5_CFG"
S5_CONFIG_SHA256=$(t_sha256 "$S5_CFG")
S5_ARCHNAME=amd64
printf '#!/bin/sh\nexit 0\n' >"$S5_BIN"
chmod 0755 "$S5_BIN"
S5_ASSET_NAME=xray-v26.3.27-linux-amd64
S5_ASSET_SIZE=$(wc -c <"$S5_BIN" | tr -d '[:space:]')
S5_ASSET_SHA256=$(t_sha256 "$S5_BIN")
S5_BINARY_SHA256=$S5_ASSET_SHA256
S5_INIT=systemd
S5_OS_FAMILY=debian
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
S5_PASSWORD='Secret123xyz'
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

# Raw target installation has no archive tool capability gate. Install/update
# still require the absolute transport and ELF classifier; status does not.
_pcinstall=$(s5_precheck install 2>&1)
assert_eq "install has no unzip capability probe" 0     "$(printf '%s' "$_pcinstall" | grep -c 'unzip with -Z' || true)"
_pcstat=$(s5_precheck status 2>&1) && _pcss=0 || _pcss=$?
assert_eq "status remains independent of raw transport tools" 0 "$_pcss"

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

while IFS='|' read -r _catalog_key _catalog_arg1 _catalog_arg2 _catalog_arg3 _catalog_en _catalog_zh; do
    set --
    [ -z "$_catalog_arg1" ] || set -- "$_catalog_arg1"
    [ -z "$_catalog_arg2" ] || set -- "$@" "$_catalog_arg2"
    [ -z "$_catalog_arg3" ] || set -- "$@" "$_catalog_arg3"
    for S5_LANG in en zh; do
        t_run s5_msg "$_catalog_key" "$@"
        assert_eq "$_catalog_key renders in $S5_LANG" 0 "$T_STATUS"
        case "$S5_LANG" in en) _catalog_expected=$_catalog_en ;; zh) _catalog_expected=$_catalog_zh ;; esac
        assert_eq "$_catalog_key has the expected $S5_LANG text" "$_catalog_expected" "$T_OUT"
    done
done <<'CATALOG'
status.state.running||||running|运行中
status.state.stopped||||stopped|已停止
status.state.crashed||||crashed|已崩溃
status.state.failed||||failed|已失败
status.state.unsupervised||||unsupervised|失去守护
status.state.unverified||||unverified|未验证
show.service|running|||service: running|服务：running
openrc.logging.unavailable||||Xray stdout and stderr logging may be unavailable because /dev/log was not found; on Alpine, run rc-service syslog start and rc-update add syslog default, then run sh socks5.sh restart.|未发现 /dev/log，Xray 的标准输出和错误日志可能不可用；请在 Alpine 上运行 rc-service syslog start 和 rc-update add syslog default，然后运行 sh socks5.sh restart。
account.remove.identity|900|901||account identity mismatch: recorded 900/901.|账户身份不匹配：记录值为 900/901。
account.remove.user|xray-socks5|||could not remove service account: xray-socks5.|无法删除服务账户：xray-socks5。
account.remove.user.exists|xray-socks5|||service account still exists after removal: xray-socks5.|删除后服务账户仍然存在：xray-socks5。
account.remove.user.verify|xray-socks5|||could not verify service account removal: xray-socks5.|无法验证服务账户已删除：xray-socks5。
account.remove.group|xray-socks5|||could not remove service group: xray-socks5.|无法删除服务组：xray-socks5。
account.remove.group.before|xray-socks5|||could not verify service group before removal: xray-socks5.|删除前无法验证服务组：xray-socks5。
account.remove.group.exists|xray-socks5|||service group still exists after removal: xray-socks5.|删除后服务组仍然存在：xray-socks5。
account.remove.group.verify|xray-socks5|||could not verify service group removal: xray-socks5.|无法验证服务组已删除：xray-socks5。
uninstall.symlink|/owned|||refusing symlink during uninstall: /owned.|卸载时拒绝符号链接：/owned。
uninstall.file|/owned|||could not remove owned file: /owned.|无法删除自有文件：/owned。
uninstall.notdir|/owned|||owned path is not a directory: /owned.|自有路径不是目录：/owned。
uninstall.nonempty|/owned|||refusing non-empty owned directory: /owned.|拒绝删除非空自有目录：/owned。
uninstall.directory|/owned|||could not remove owned directory: /owned.|无法删除自有目录：/owned。
usage.unknown|bogus|||unknown command: bogus.|未知命令：bogus。
show.nat|212.189.21.55|10.66.147.248|59093|WARNING: 212.189.21.55 is the address this server egresses from, and this machine does not hold it (local address: 10.66.147.248). The proxy listens on port 59093. The links below work only if something upstream forwards inbound connections for that address to this machine; otherwise set S5_SERVER_IPV4 and S5_SERVER_PORT to the address and port your clients actually use.|警告：212.189.21.55 是本服务器出站流量的来源地址，本机并未持有它（本机地址：10.66.147.248）。代理监听在端口 59093。只有当上级把发往该地址的入站连接转发到本机时，下面的链接才可用；否则请用 S5_SERVER_IPV4 和 S5_SERVER_PORT 指定客户端真正使用的地址和端口。
input.port.keep|25000|||Port [Enter = keep current 25000]: |端口 [回车 = 保留当前的 25000]：
input.port.override||||Port [Enter = use S5_LISTEN_PORT]: |端口 [回车 = 使用 S5_LISTEN_PORT]：
input.port.explicit||||Port [enter explicitly]: |端口 [请明确输入]：
input.username.keep|keptuser|||Username [Enter = keep current keptuser]: |账户名 [回车 = 保留当前的 keptuser]：
input.username.legacy||||the current username contains characters this version no longer writes and cannot be kept; enter a new username, or press Enter to generate one.|当前账户名含有本版本不再写入的字符，无法保留；请输入新账户名，或回车生成随机值。
input.password.keep||||Password (visible while typed) [Enter = keep current]: |密码（输入时可见）[回车 = 保留当前密码]：
input.password.legacy||||the current password contains characters this version no longer writes and cannot be kept; enter a new password, or press Enter to generate one.|当前密码含有本版本不再写入的字符，无法保留；请输入新密码，或回车生成随机值。
show.nat.unnamed|212.189.21.55|59093||WARNING: 212.189.21.55 is the address this server egresses from, and this machine does not hold it. The proxy listens on port 59093. The links below work only if something upstream forwards inbound connections for that address to this machine; otherwise set S5_SERVER_IPV4 and S5_SERVER_PORT to the address and port your clients actually use.|警告：212.189.21.55 是本服务器出站流量的来源地址，本机并未持有它。代理监听在端口 59093。只有当上级把发往该地址的入站连接转发到本机时，下面的链接才可用；否则请用 S5_SERVER_IPV4 和 S5_SERVER_PORT 指定客户端真正使用的地址和端口。
show.port.mapped|56447|59093||the links below use port 56447 while the proxy listens on port 59093. That mapping comes from S5_SERVER_PORT; the script does not create it.|下面的链接使用端口 56447，而代理监听在端口 59093。该映射来自 S5_SERVER_PORT，脚本不会创建它。
config.invalid.fresh||||Xray configuration test failed; no configuration was installed.|Xray 配置测试失败；未安装任何配置。
config.invalid.installed||||the installed Xray configuration failed the configuration test; the service was not restarted.|已安装的 Xray 配置未通过配置测试；服务未重启。
service.dataplane.reason|23456|RuntimeError: http auth||authenticated proxy traffic could not be verified on port 23456: RuntimeError: http auth.|端口 23456 上的认证代理流量验证失败：RuntimeError: http auth。
transaction.pending|/txn|||a pending recovery directory could not be resolved automatically; stopping: /txn.|存在无法自动恢复的待处理恢复目录，已停止操作：/txn。
digest.candidate|xray-v26.3.27-linux-amd64|||could not compute SHA-256 for downloaded asset: xray-v26.3.27-linux-amd64.|无法计算下载资产的 SHA-256：xray-v26.3.27-linux-amd64。
transaction.prepare|/txn|||could not prepare the update recovery copies in /txn; the installation was not changed.|无法在 /txn 中准备更新的恢复副本；当前安装未被修改。
transaction.publish|/cfg|||could not publish the new configuration: /cfg.|无法发布新配置：/cfg。
transaction.rolledback||||the update was rolled back; the previous configuration and state were restored.|更新已回滚，已恢复原来的配置和状态。
service.unit|/unit|||could not write the service definition: /unit.|无法写入服务定义：/unit。
service.reload||||the service manager could not reload the service definitions.|服务管理器无法重新加载服务定义。
service.enable||||could not enable the Xray service at boot.|无法设置 Xray 服务开机启动。
service.disable||||could not disable the Xray service at boot.|无法取消 Xray 服务开机启动。
service.dataplane|23456|||authenticated proxy traffic could not be verified on port 23456.|端口 23456 上的认证代理流量验证失败。
state.write|/state|||could not write the state file: /state.|无法写入 state 文件：/state。
uninstall.progress|/uninstall|||could not record uninstall progress: /uninstall.|无法记录卸载进度：/uninstall。
uninstall.identity||||could not record the identity of the installed paths; nothing was removed.|无法记录已安装路径的身份；未删除任何内容。
cleanup.residue|/prefix/.xray.old|||kept a temporary file this run did not create: /prefix/.xray.old; remove it manually once it is no longer needed.|保留了不属于本次运行的临时文件：/prefix/.xray.old；确认不再需要后可手动删除。
CATALOG

# Every key ends alike in both languages: a sentence with "." has "。", an
# ellipsis "..." has "……", and a label or prompt has neither in both. The two
# lang.* keys are bilingual by construction and exempt.
s5t_ending() {
    case "$1" in
    *...|*……) printf ellipsis ;;
    *.|*。) printf period ;;
    *) printf none ;;
    esac
}
_punct_bad=''
_punct_keys=0
while read -r _punct_key _punct_arity; do
    case "$_punct_key" in lang.*) continue ;; esac
    set --
    _punct_i=0
    while [ "$_punct_i" -lt "$_punct_arity" ]; do
        _punct_i=$((_punct_i + 1))
        set -- "$@" "a$_punct_i"
    done
    S5_LANG=en
    _punct_en=$(s5_msg "$_punct_key" "$@") || _punct_bad="$_punct_bad $_punct_key(render)"
    S5_LANG=zh
    _punct_zh=$(s5_msg "$_punct_key" "$@") || _punct_bad="$_punct_bad $_punct_key(render)"
    _punct_keys=$((_punct_keys + 1))
    if [ "$(s5t_ending "$_punct_en")" != "$(s5t_ending "$_punct_zh")" ]; then
        _punct_bad="$_punct_bad $_punct_key"
    fi
done <<EOF
$(sed -n 's/^    \([a-z][a-z.]*\)) \[ "\$#" -eq \([0-9]\) \].*/\1 \2/p' "$ROOT/socks5.sh")
EOF
assert_ne "the punctuation check reads the whole catalog" 0 "$_punct_keys"
assert_eq "every key ends alike in English and Chinese" '' "$_punct_bad"

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
