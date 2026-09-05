#!/bin/sh
# The credential card: address resolution, and the terminal-only guard.
#
# show had no coverage anywhere. Its only host source was
# ${S5_SERVER_IPV4:-SERVER_IPV4} and nothing in the branch ever set that
# variable, so every card printed a URI with a literal SERVER_IPV4 in it and no
# hint that it was a placeholder.

S5T_NAME=test_xray_show
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
ROOT=${S5_REPO_ROOT}
t_mktestroot
S5_LIB_ONLY=1
S5_ASSUME_ROOT=1
S5_SKIP_OWNERSHIP=1
S5_OSRELEASE="$ROOT/tests/fixtures/os-release/debian-12"
export S5_LIB_ONLY S5_ASSUME_ROOT S5_SKIP_OWNERSHIP S5_OSRELEASE
# shellcheck source=/dev/null
. "$ROOT/socks5.sh"

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
    # shellcheck disable=SC2059
    printf "$1" >"$S5_TEST_ADDR_PATH"
    _lpb=''
    s5_read_public_ipv4
}

s5t_body '198.100.20.30\n'
assert_eq "a single terminated line is read" 0 "$?"
assert_eq "the address is the line" 198.100.20.30 "$_lpb"
s5t_body '198.100.20.30'
assert_eq "an unterminated line is read" 0 "$?"
assert_eq "an unterminated address is the line" 198.100.20.30 "$_lpb"
s5t_body '198.100.20.30\r\n'
assert_eq "a CRLF terminator is read" 0 "$?"
assert_eq "the CR is not part of the address" 198.100.20.30 "$_lpb"
s5t_body '1.2.3.4\n\n'
assert_ne "a double terminator is refused" 0 "$?"
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
s5_ipv4_is_public "$_lpb"
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

t_summary
