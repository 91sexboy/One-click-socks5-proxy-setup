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
S5_PASSWORD='Secret_123~x'

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
assert_contains "interleaved dependency discovery still requests unzip" \
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

# s5t_card: render into a file. t_run would capture through a command
# substitution, and S5_CARD_KIND is set by the subject, so a subshell would lose
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
    'socks5://alice:Secret_123~x@SERVER_IPV4:23456' "$S5T_CARD_OUT"
assert_contains "the HTTP URI uses the same host" \
    'http://alice:Secret_123~x@SERVER_IPV4:23456' "$S5T_CARD_OUT"
assert_contains "the placeholder is called out" \
    'replace SERVER_IPV4 below' "$S5T_CARD_OUT"
assert_eq "the placeholder kind is recorded" placeholder "$S5_CARD_KIND"

# A usable public address reaches the card, and then no placeholder survives in
# it: the URI a caller copies has to be one they can connect to.
printf '198.100.20.30\n' >"$S5_TEST_ADDR_PATH"
s5t_card
assert_eq "a card renders with a resolved address" 0 "$S5T_CARD_STATUS"
assert_contains "the resolved address reaches the SOCKS5 URI" \
    'socks5://alice:Secret_123~x@198.100.20.30:23456' "$S5T_CARD_OUT"
assert_contains "the resolved address reaches the HTTP URI" \
    'http://alice:Secret_123~x@198.100.20.30:23456' "$S5T_CARD_OUT"
assert_not_contains "no placeholder survives a resolved address" \
    SERVER_IPV4 "$S5T_CARD_OUT"
assert_eq "the resolved kind is recorded" external "$S5_CARD_KIND"

# An operator behind NAT can name the address themselves, and that answer is
# taken even when the endpoint would have answered with something else. It is
# still validated, so a hostname or a malformed value cannot reach the URI.
S5_SERVER_IPV4=192.168.5.9
s5t_card
assert_contains "a configured address is used as given" \
    'socks5://alice:Secret_123~x@192.168.5.9:23456' "$S5T_CARD_OUT"
assert_not_contains "a configured address is not called a placeholder" \
    'replace SERVER_IPV4' "$S5T_CARD_OUT"
assert_eq "the configured kind is recorded" configured "$S5_CARD_KIND"
S5_SERVER_IPV4=proxy.example.com
printf '10.0.0.7\n' >"$S5_TEST_ADDR_PATH"
s5t_card
assert_not_contains "a non-address override never reaches the card" \
    proxy.example.com "$S5T_CARD_OUT"
assert_eq "a non-address override is not treated as configured" \
    placeholder "$S5_CARD_KIND"
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
s5_precheck() { return 0; }
s5_lock_acquire() { return 0; }
s5_lock_release() { return 0; }
s5_state_load() { return 0; }
s5_report_state_load() { return 0; }
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
s5_precheck() { return 0; }
for _status_case in running stopped unverified; do
    systemctl() {
        if [ "$1" = is-active ]; then
            case "$_status_case" in running) return 0 ;; stopped) return 3 ;; *) return 1 ;; esac
        fi
        "$S5_TEST_ROOT/bin/systemctl" "$@"
    }
    case "$_status_case" in running) _status_zh=运行中 ;; stopped) _status_zh=已停止 ;; *) _status_zh=未验证 ;; esac
    for S5_LANG in en zh; do
        t_run s5_cmd_status
        assert_eq "status reports $_status_case in $S5_LANG" 0 "$T_STATUS"
        if [ "$S5_LANG" = zh ]; then
            assert_contains "Chinese status names its service state" "服务：$_status_zh；" "$T_OUT"
            for _status_en in running stopped unverified; do
                assert_not_contains "Chinese status has no English state word" "$_status_en" "$T_OUT"
            done
        else
            assert_contains "English status keeps its original line" \
                "service: $_status_case; port: 23456; username: alice; protocol: mixed (SOCKS5 + HTTP); auth: password; UDP: disabled" "$T_OUT"
        fi
        assert_file_absent "status releases the operation lock" "$S5_LOCKDIR"
    done
done

t_summary
