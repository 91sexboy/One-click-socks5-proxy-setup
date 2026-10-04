#!/bin/sh
# Credential cards, status localization and restart diagnostics.

S5T_NAME=test_xray_show
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
ROOT=${S5_REPO_ROOT}
t_mktestroot
t_source_production "$ROOT/tests/fixtures/os-release/debian-12"

S5_LANG=en
S5_PORT=23456
S5_USERNAME=alice
S5_PASSWORD='Secret123xyz'

# A private, CGNAT, loopback, documentation or multicast address must never be
# advertised as an Internet-reachable host, and the range edges are where an
# octet comparison goes wrong. 0 means "usable in a card", 1 means refused.
for _pubcase in 8.8.8.8:0 1.1.1.1:0 203.0.114.5:0 192.0.1.1:0 \
    100.63.255.255:0 100.12.0.1:0 100.128.0.1:0 172.15.255.255:0 172.32.0.1:0 \
    192.169.0.1:0 198.20.0.1:0 223.255.255.255:0 \
    0.0.0.0:1 10.0.0.1:1 127.0.0.1:1 169.254.169.254:1 \
    100.64.0.1:1 100.70.0.1:1 100.100.0.1:1 100.127.255.254:1 \
    172.16.0.1:1 172.20.5.5:1 172.31.255.255:1 192.168.1.1:1 \
    192.0.0.1:1 192.0.2.1:1 192.31.196.1:1 192.52.193.1:1 192.88.99.1:1 \
    192.175.48.1:1 198.18.0.1:1 198.19.255.255:1 198.51.100.7:1 203.0.113.9:1 \
    224.0.0.1:1 239.255.255.255:1 255.255.255.255:1 \
    10.0.0.256:1 1.2.3:1 01.2.3.4:1 '':1; do
    s5_ipv4_is_public "${_pubcase%:*}"
    assert_eq "${_pubcase%:*} is usable in a card: ${_pubcase##*:}" \
        "${_pubcase##*:}" "$?"
done

# The response body is parsed from a file rather than a command substitution,
# which strips every trailing newline and so cannot tell one address from an
# address followed by more content. S5_TEST_ADDR_PATH substitutes the body and
# nothing else, so these run the same parser a real response goes through.
S5_TEST_ADDR_PATH=$S5_TEST_ROOT/body

# Every body file the reader creates is recorded, so each outcome below can be
# checked for leftovers in the shared temporary directory.
mktemp() {
    _s5t_temp=$(command mktemp "$@") || return 1
    printf '%s\n' "$_s5t_temp" >>"$S5_TEST_ROOT/address-temps"
    printf '%s\n' "$_s5t_temp"
}

# s5t_body <printf-format>: write one exact response body and read it back.
s5t_body() {
    # Interpret the fixture's deliberate escape sequences as bytes.
    # shellcheck disable=SC2059
    printf "$1" >"$S5_TEST_ADDR_PATH"
    s5_read_public_ipv4
}

s5t_body '198.100.20.30\n'
assert_eq "a single terminated line is read" 0 "$?"
assert_eq "the address is the line" 198.100.20.30 "$S5_PUBLIC_IPV4_CANDIDATE"
s5t_body '198.100.20.30'
assert_eq "an unterminated line is read" 0 "$?"
assert_eq "an unterminated address is the line" 198.100.20.30 "$S5_PUBLIC_IPV4_CANDIDATE"
s5t_body '198.100.20.30\r\n'
assert_eq "a CRLF terminator is read" 0 "$?"
assert_eq "the CR is not part of the address" 198.100.20.30 "$S5_PUBLIC_IPV4_CANDIDATE"

# These APIs may be interleaved in one shell; unrelated generators and dependency
# queries must not consume the address the reader intentionally returns.
s5_random_port >"$S5_TEST_ROOT/random-port"
S5_INIT=openrc
s5_runtime_packages install >"$S5_TEST_ROOT/packages"
assert_eq "dependency discovery preserves the reader's candidate" 198.100.20.30 "$S5_PUBLIC_IPV4_CANDIDATE"
s5_valid_port "$(cat "$S5_TEST_ROOT/random-port")"
assert_eq "interleaved random generation still produces a port" 0 "$?"
assert_not_contains "interleaved dependency discovery no longer requests unzip" \
    unzip "$(cat "$S5_TEST_ROOT/packages")"
S5_INIT=systemd
s5t_body '1.2.3.4\n\n'
assert_ne "a double terminator is refused" 0 "$?"
assert_eq "a failed read clears the previous candidate" '' "$S5_PUBLIC_IPV4_CANDIDATE"
s5t_body '1.2.3.4\n5.6.7.8\n'
assert_ne "a second line is refused" 0 "$?"
s5t_body '1.2.3.4\nx'
assert_ne "unterminated trailing bytes are refused" 0 "$?"
s5t_body '255.255.255.2555x\n'
assert_ne "a body larger than any address is refused" 0 "$?"
s5t_body '\n'
assert_ne "an empty first line is refused" 0 "$?"
s5t_body ''
assert_ne "an empty body is refused" 0 "$?"

# The parser enforces structure and the classifier enforces the address, so a
# structurally valid body that is not an address still never reaches a card.
s5t_body '255.255.255.2555\n'
assert_eq "an over-long octet parses as a line" 0 "$?"
s5_ipv4_is_public "$S5_PUBLIC_IPV4_CANDIDATE"
assert_ne "an over-long octet is not a usable address" 0 "$?"

unset -f mktemp
_addr_temps=0
_addr_left=''
while IFS= read -r _addr_temp; do
    _addr_temps=$((_addr_temps + 1))
    if [ -e "$_addr_temp" ] || [ -L "$_addr_temp" ]; then _addr_left="$_addr_left $_addr_temp"; fi
done <"$S5_TEST_ROOT/address-temps"
assert_ne "the reader's body files were observed" 0 "$_addr_temps"
assert_eq "no body file survives an accepted or refused response" '' "$_addr_left"

# s5t_card: render into a file. t_run would capture through a command
# substitution, and S5_ADVERTISED_KIND is set by the subject, so a subshell would lose
# the one value that says which branch produced the card.
s5t_card() {
    s5_render_card >"$S5_TEST_ROOT/card" 2>&1
    S5T_CARD_STATUS=$?
    S5T_CARD_OUT=$(cat "$S5_TEST_ROOT/card")
}

# The card resolves once, so the SOCKS5 and HTTP URIs always name the same host.
# A private address from the endpoint is not usable, so the card falls back to the
# placeholder and says so rather than printing an address that cannot be reached.
printf '10.0.0.7\n' >"$S5_TEST_ADDR_PATH"
s5t_card
assert_eq "a card renders" 0 "$S5T_CARD_STATUS"
assert_contains "an unusable lookup falls back to the placeholder" \
    'socks5://alice:Secret123xyz@SERVER_IPV4:23456' "$S5T_CARD_OUT"
assert_contains "the HTTP URI uses the same host" \
    'http://alice:Secret123xyz@SERVER_IPV4:23456' "$S5T_CARD_OUT"
assert_contains "the placeholder is called out" \
    'replace SERVER_IPV4 below' "$S5T_CARD_OUT"
assert_eq "the placeholder kind is recorded" placeholder "$S5_ADVERTISED_KIND"

# s5t_local <ip-o-addr-output>: substitute the host's interface list. The seam
# is a function rather than an environment variable, so it needs no entry in
# s5_guard_environment, tests/run.sh or the contract oracle. The text goes
# through a file rather than a captured argument, because the seam is called
# with no arguments and a redefinition that read $1 would silently print
# nothing -- which looks exactly like a host that cannot enumerate itself.
s5t_local() { printf '%s' "$1" >"$S5_TEST_ROOT/local-addrs"; }
s5_local_ipv4_command() { cat "$S5_TEST_ROOT/local-addrs" 2>/dev/null; }

# A usable public address that this host actually holds reaches the card, and
# then no placeholder survives in it: the URI a caller copies has to be one they
# can connect to.
s5t_local '1: lo    inet 127.0.0.1/8 scope host lo
2: eth0    inet 198.100.20.30/24 brd 198.100.20.255 scope global eth0
'
printf '198.100.20.30\n' >"$S5_TEST_ADDR_PATH"
s5t_card
assert_eq "a card renders with a resolved address" 0 "$S5T_CARD_STATUS"
assert_contains "the resolved address reaches the SOCKS5 URI" \
    'socks5://alice:Secret123xyz@198.100.20.30:23456' "$S5T_CARD_OUT"
assert_contains "the resolved address reaches the HTTP URI" \
    'http://alice:Secret123xyz@198.100.20.30:23456' "$S5T_CARD_OUT"
assert_not_contains "no placeholder survives a resolved address" \
    SERVER_IPV4 "$S5T_CARD_OUT"
assert_eq "the resolved kind is recorded" external "$S5_ADVERTISED_KIND"

# The bug this file exists to prevent: behind NAT the lookup answers with the
# address the request egressed from, which the host does not hold and no client
# can reach. Every local verification still passes, because they dial loopback.
# The card has to say so instead of advertising an endpoint that does not exist.
s5t_local '1: lo    inet 127.0.0.1/8 scope host lo
2: eth0    inet 10.66.147.248/16 brd 10.66.255.255 scope global eth0
'
s5t_card
assert_eq "a card still renders behind NAT" 0 "$S5T_CARD_STATUS"
assert_eq "an egress address the host does not hold is recorded as nat" \
    nat "$S5_ADVERTISED_KIND"
assert_contains "the advisory names the egress address" \
    '198.100.20.30 is the address this server egresses from' "$S5T_CARD_OUT"
assert_contains "the advisory names an address the host does hold" \
    '10.66.147.248' "$S5T_CARD_OUT"
assert_contains "the advisory names the listening port" \
    'listens on port 23456' "$S5T_CARD_OUT"
# The count is the point: a second pair would give the operator two endpoints
# and no way to tell which one to copy, and tests/protocol/terminal_install.py
# counts occurrences for the same reason.
assert_eq "a NAT card still carries exactly one SOCKS5 URI" 1 \
    "$(printf '%s\n' "$S5T_CARD_OUT" | grep -c 'socks5://')"
assert_eq "a NAT card still carries exactly one HTTP URI" 1 \
    "$(printf '%s\n' "$S5T_CARD_OUT" | grep -c 'http://alice')"

# One card must classify and explain locality from one immutable snapshot. The
# seam deliberately changes its answer on a second call: the old implementation
# classified against the first, enumerated again in the renderer, and printed
# the contradiction "does not hold it (local address: 198.100.20.30)".
printf '0\n' >"$S5_TEST_ROOT/local-call-count"
s5_local_ipv4_command() {
    _s5t_count=$(cat "$S5_TEST_ROOT/local-call-count")
    _s5t_count=$((_s5t_count + 1))
    printf '%s\n' "$_s5t_count" >"$S5_TEST_ROOT/local-call-count"
    if [ "$_s5t_count" -eq 1 ]; then
        printf '%s\n' \
            '1: lo    inet 127.0.0.1/8 scope host lo' \
            '2: eth0    inet 10.66.147.248/16 brd 10.66.255.255 scope global eth0'
    else
        printf '%s\n' \
            '1: lo    inet 127.0.0.1/8 scope host lo' \
            '2: eth0    inet 198.100.20.30/24 brd 198.100.20.255 scope global eth0'
    fi
}
s5t_card
assert_eq "one card enumerates local addresses once" 1 \
    "$(cat "$S5_TEST_ROOT/local-call-count")"
assert_eq "a changing interface set keeps the original nat classification" \
    nat "$S5_ADVERTISED_KIND"
assert_contains "the NAT advisory uses the classification snapshot's hint" \
    'local address: 10.66.147.248' "$S5T_CARD_OUT"
assert_not_contains "the NAT advisory never contradicts its classification" \
    'local address: 198.100.20.30' "$S5T_CARD_OUT"
# Restore the stable file-backed seam for the remaining card cases.
s5_local_ipv4_command() { cat "$S5_TEST_ROOT/local-addrs" 2>/dev/null; }

# Nothing but loopback to name, so the advisory drops the local-address clause
# rather than printing an empty one.
s5t_local '1: lo    inet 127.0.0.1/8 scope host lo
'
s5t_card
assert_eq "a host with only loopback is still nat" nat "$S5_ADVERTISED_KIND"
assert_contains "the unnamed advisory still names the egress address" \
    '198.100.20.30 is the address this server egresses from' "$S5T_CARD_OUT"
assert_not_contains "the unnamed advisory has no empty local-address clause" \
    'local address: )' "$S5T_CARD_OUT"

# A host that cannot enumerate its own addresses must not be annotated with a
# guess. s5_ipv4_is_local returns 2 there, and the card reads as it always did.
s5_local_ipv4_command() { return 1; }
S5T_SAVED_ROOTDIR=$S5_ROOTDIR
S5_ROOTDIR=$S5_TEST_ROOT/no-such-root
s5t_card
assert_eq "an unanswerable locality probe leaves the card external" \
    external "$S5_ADVERTISED_KIND"
assert_not_contains "an unanswerable locality probe adds no advisory" \
    'egresses from' "$S5T_CARD_OUT"
S5_ROOTDIR=$S5T_SAVED_ROOTDIR

# S5_SERVER_PORT names the port a client dials when it differs from the port
# Xray binds. The script does not create that mapping and says so.
s5t_local '1: lo    inet 127.0.0.1/8 scope host lo
2: eth0    inet 198.100.20.30/24 brd 198.100.20.255 scope global eth0
'
S5_SERVER_PORT=56447
s5t_card
assert_contains "the advertised port reaches the SOCKS5 URI" \
    'socks5://alice:Secret123xyz@198.100.20.30:56447' "$S5T_CARD_OUT"
assert_contains "the advertised port reaches the HTTP URI" \
    'http://alice:Secret123xyz@198.100.20.30:56447' "$S5T_CARD_OUT"
assert_contains "a mapped port is called out" \
    'use port 56447 while the proxy listens on port 23456' "$S5T_CARD_OUT"
assert_eq "a mapped card still carries exactly one SOCKS5 URI" 1 \
    "$(printf '%s\n' "$S5T_CARD_OUT" | grep -c 'socks5://')"
S5_SERVER_PORT=23456
s5t_card
assert_not_contains "an override equal to the listening port says nothing" \
    'while the proxy listens on port' "$S5T_CARD_OUT"
# The advertised port is what a client dials, so unlike the listening port it
# has no privilege floor: external 443 to an internal high port is a common
# shape, chosen to survive restrictive client networks.
S5_SERVER_PORT=443
s5t_card
assert_contains "a privileged advertised port is accepted" \
    'socks5://alice:Secret123xyz@198.100.20.30:443' "$S5T_CARD_OUT"
assert_contains "a privileged advertised port is still called out" \
    'use port 443 while the proxy listens on port 23456' "$S5T_CARD_OUT"
S5_SERVER_PORT=0
s5t_card
assert_contains "port zero falls back to the listening port" \
    'socks5://alice:Secret123xyz@198.100.20.30:23456' "$S5T_CARD_OUT"
S5_SERVER_PORT=65536
s5t_card
assert_contains "an out-of-range override falls back to the listening port" \
    'socks5://alice:Secret123xyz@198.100.20.30:23456' "$S5T_CARD_OUT"
S5_SERVER_PORT=not-a-port
s5t_card
assert_contains "a non-numeric override falls back to the listening port" \
    'socks5://alice:Secret123xyz@198.100.20.30:23456' "$S5T_CARD_OUT"
assert_not_contains "a rejected override is never printed" \
    'not-a-port' "$S5T_CARD_OUT"
S5_SERVER_PORT=''

# An operator behind NAT can name the address themselves, and that answer is
# taken even when the endpoint would have answered with something else. It is
# still validated, so a hostname or a malformed value cannot reach the URI.
S5_SERVER_IPV4=192.168.5.9
s5t_card
assert_contains "a configured address is used as given" \
    'socks5://alice:Secret123xyz@192.168.5.9:23456' "$S5T_CARD_OUT"
assert_not_contains "a configured address is not called a placeholder" \
    'replace SERVER_IPV4' "$S5T_CARD_OUT"
assert_eq "the configured kind is recorded" configured "$S5_ADVERTISED_KIND"
# An explicit answer describes a topology the host cannot see, so it is never
# locality-checked. 192.168.5.9 is on no interface here, and
# tests/protocol/terminal_install.py installs with S5_SERVER_IPV4=192.0.2.1,
# which is local on no runner: gating this branch would turn that job red.
assert_not_contains "a configured address is never called out as nat" \
    'egresses from' "$S5T_CARD_OUT"
S5_SERVER_IPV4=proxy.example.com
printf '10.0.0.7\n' >"$S5_TEST_ADDR_PATH"
s5t_card
assert_not_contains "a non-address override never reaches the card" \
    proxy.example.com "$S5T_CARD_OUT"
assert_eq "a non-address override is not treated as configured" \
    placeholder "$S5_ADVERTISED_KIND"
S5_SERVER_IPV4=''

# SPEC 2: redirected output never receives the credential card. t_run captures
# through a command substitution, so stdout is a pipe and the guard must fire --
# before the lock is taken, and without printing the password it refused to show.
S5_LOCK_HELD=0
t_run s5_cmd_show
assert_ne "show refuses a non-terminal stdout" 0 "$T_STATUS"
assert_contains "the refusal says why" 'only on a real TTY' "$T_OUT"
assert_not_contains "a refused show prints no URI" 'socks5://' "$T_OUT"
assert_not_contains "the refusal leaks no password" "$S5_PASSWORD" "$T_OUT"
assert_file_absent "a refused show takes no lock" "$S5_LOCKDIR"

# SPEC 8 diagnostics: restart reported one failure twice. s5_verify_dataplane
# reports its own reason and returns non-zero, and the case below it turned that
# into a second, less specific service.unverified -- a failed verification and a
# probe that could not observe the listener arrived as the same status, so the
# case could not tell "already reported" from "nothing reported yet". Counting
# occurrences is the whole point: assert_contains passes on one and on two alike.
S5_TEST_MODE=1
S5_PROTOCOL_VERIFY=$S5_TEST_ROOT/verifyfail
printf '#!/bin/sh\nexit 1\n' >"$S5_PROTOCOL_VERIFY"
chmod 0755 "$S5_PROTOCOL_VERIFY"
s5_trap_lock_only() { return 0; }
s5_precheck_host() { return 0; }; s5_precheck_tools() { return 0; }
s5_lock_acquire() { return 0; }
s5_lock_release() { return 0; }
s5_state_load() { return 0; }
s5_report_state_load() { return 0; }

# SPEC 7 through the restart entrypoint: restart reads the installed account back
# and config-tests the installed file, and a rejection reaches the operator as a
# warning. Extraction, the config-test wrapper and the redactor stay production
# code; the engine is a stand-in that quotes the password it reads from the
# config, a controlled leak rather than a claim about a pinned Xray release. The
# historical password carries every character the read-back still accepts.
mkdir -p "$S5_SYSCONFDIR"
cat >"$S5_CFG" <<'CFG'
{"inbounds": [{"protocol": "mixed", "settings": {"auth": "password",
  "accounts": [{"user": "legacy_user-1", "pass": "Legacy_pass~123.x"}],
  "udp": false}}]}
CFG
_rr_bin=$S5_BIN
S5_BIN="$S5_TEST_ROOT/xray-quoting"
cat >"$S5_BIN" <<'XRAY'
#!/bin/sh
printf 'xray: config %s rejected near "pass": "%s"\n' "$4" \
    "$(sed -n 's/.*"pass": "\([^"]*\)".*/\1/p' "$4")" >&2
exit 23
XRAY
chmod 0755 "$S5_BIN"
S5_SECRET=''
t_run s5_cmd_restart
assert_ne "restart refuses an installed config the engine rejects" 0 "$T_STATUS"
assert_contains "restart keeps the engine diagnostic context" \
    "xray: config $S5_CFG rejected near" "$T_OUT"
assert_contains "restart shows the password as the redaction marker" \
    '"pass": "<REDACTED>"' "$T_OUT"
assert_not_contains "restart's engine diagnostic carries no password" \
    'Legacy_pass~123.x' "$T_OUT"
S5_BIN=$_rr_bin
S5_USERNAME=alice
S5_PASSWORD='Secret123xyz'

s5_config_extract() { return 0; }
s5_config_test() { return 0; }
s5_svc() { return 0; }
s5_wait_listening() { return 0; }
t_run s5_cmd_restart
assert_ne "restart fails when the data plane cannot be verified" 0 "$T_STATUS"
assert_eq "a failed verification is reported exactly once" 1 \
    "$(printf '%s\n' "$T_OUT" | grep -c 'could not be verified')"

# The complementary half, so the fix cannot be "delete the case branch": when the
# probe itself cannot observe the listener the verifier never runs, and that
# failure has nobody else to report it.
s5_wait_listening() { return 2; }
t_run s5_cmd_restart
assert_ne "restart fails when the listener cannot be observed" 0 "$T_STATUS"
assert_eq "an unobservable listener is still reported once" 1 \
    "$(printf '%s\n' "$T_OUT" | grep -c 'could not be verified')"
s5_wait_listening() { return 0; }

# status diagnosed a config it could not extract; show and restart returned 1 in
# silence, so one command named the failure and the other two just exited. There
# is nobody else to report it -- s5_config_extract prints nothing of its own.
# restart is the only one of the three reachable from a test: show refuses a
# non-TTY stdout long before it gets here. Anchored on the config path reaching
# the output rather than on which message key renders it.
s5_config_extract() { return 1; }
t_run s5_cmd_restart
assert_ne "restart fails when the config cannot be extracted" 0 "$T_STATUS"
assert_contains "restart names the config it could not read" "$S5_CFG" "$T_OUT"
s5_config_extract() { return 0; }

t_run python3 "$ROOT/tests/protocol/test_terminal_install.py"
assert_eq "the terminal probe preserves diagnostics without leaking credentials" 0 "$T_STATUS"
if [ "$T_STATUS" -ne 0 ]; then printf '%s\n' "$T_OUT" >&2; fi

. "$ROOT/tests/lib/xray-fixture.sh"
t_xray_fixture 23456
t_xray_install
s5_precheck_host() { return 0; }; s5_precheck_tools() { return 0; }
# systemctl is-active exits 3 for every state that is not active, or 4 on
# systemd 250+ when the unit is not loaded, so the word it prints decides the
# mapping: inactive is stopped, failed (exit 23 or a
# spent restart budget) is failed and fails the command like OpenRC's crashed,
# and any other word, or another exit, is unverified.
for _status_word in active:0:running inactive:3:stopped failed:3:failed \
    inactive:4:stopped failed:4:failed activating:4:unverified activating:3:unverified deactivating:3:unverified :1:unverified; do
    _status_case=${_status_word##*:}
    _status_rc=${_status_word#*:}
    _status_rc=${_status_rc%%:*}
    _status_word=${_status_word%%:*}
    systemctl() {
        if [ "$1" = is-active ]; then
            [ -z "$_status_word" ] || printf '%s\n' "$_status_word"
            return "$_status_rc"
        fi
        "$S5_TEST_ROOT/bin/systemctl" "$@"
    }
    case "$_status_case" in
    running) _status_zh=运行中 ;; stopped) _status_zh=已停止 ;; failed) _status_zh=已失败 ;; *) _status_zh=未验证 ;;
    esac
    case "$_status_case" in failed) _status_exit=1 ;; *) _status_exit=0 ;; esac
    for S5_LANG in en zh; do
        t_run s5_cmd_status
        assert_eq "status reports is-active $_status_word/$_status_rc as $_status_case in $S5_LANG" \
            "$_status_exit" "$T_STATUS"
        if [ "$S5_LANG" = zh ]; then
            assert_contains "Chinese status names its service state" "服务：$_status_zh；" "$T_OUT"
            for _status_en in running stopped failed unverified password; do
                assert_not_contains "Chinese status has no English value" "$_status_en" "$T_OUT"
            done
            assert_contains "Chinese status still reports the listener" '端口 23456' "$T_OUT"
        else
            assert_contains "English status keeps its original line" \
                "service: $_status_case; port: 23456; username: alice; protocol: mixed (SOCKS5 + HTTP); auth: password; UDP: disabled" "$T_OUT"
            assert_contains "English status still reports the listener" 'port 23456' "$T_OUT"
        fi
        assert_file_absent "status releases the operation lock" "$S5_LOCKDIR"
    done
done
unset -f systemctl

# The stop boundary: a failed systemd unit proves the process is gone and
# nothing will restart it, so stop-and-wait accepts it; OpenRC's crashed child
# (3) keeps its supervisor and stays refused. sleep is stubbed because the real
# wait is fifteen one-second polls.
s5t_stop_wait() (
    s5t_stop_state=$1
    s5_service_state() { return "$s5t_stop_state"; }
    sleep() { :; }
    s5_wait_stopped
)
for _stop_case in 1:0 4:0 3:2 2:1 0:1; do
    t_run s5t_stop_wait "${_stop_case%%:*}"
    assert_eq "service state ${_stop_case%%:*} gives stop wait ${_stop_case#*:}" "${_stop_case#*:}" "$T_STATUS"
done

t_summary
