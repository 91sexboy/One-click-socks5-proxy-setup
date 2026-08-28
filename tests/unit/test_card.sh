#!/bin/sh
# tests/unit/test_card.sh - Round 16 T11/T12: strict public/local IPv4 resolution
# and the shared localized credential card.
#
# The old s5_server_ip answered with the first local scope-global IPv4, then any
# dotted-decimal token from hostname -I, then a bare <server-ip> placeholder --
# silently, with no validation and no warning. This file owns its replacement:
# pure canonical/public/usable-local validators, a hardened fixed-endpoint
# external lookup, a validated fallback chain, one warning per card, and the
# Host/URI agreement.

S5T_NAME=test_card
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
. "${S5_REPO_ROOT}/tests/lib/stub.sh"
. "${S5_REPO_ROOT}/tests/lib/env.sh"

s5env_setup
s5env_load

# ---------------------------------------------------------------------------
# 1. Pure validators (no I/O): s5_ipv4_is_canonical
# ---------------------------------------------------------------------------
for v in 0.0.0.0 8.8.8.8 99.1.2.3 100.64.0.1 126.255.255.254 172.31.255.255 \
    192.168.1.10 198.51.100.9 223.255.255.254 239.255.255.255 240.0.0.1 \
    255.255.255.255 1.0.0.1 9.255.255.255 128.0.0.0 192.0.44.5 192.5.5.5 \
    199.0.0.1 45.77.10.22 96.30.11.5 123.123.123.123; do
    t_run s5_ipv4_is_canonical "$v"
    assert_eq "canonical: $v" 0 "$T_STATUS"
done

# Rejections: syntax and shape. Control bytes are built with printf.
mk_reject() {
    t_run s5_ipv4_is_canonical "$1"
    assert_ne "not canonical: $2" 0 "$T_STATUS"
}
mk_reject 192.168.1 'three fields'
mk_reject 192.168.1.1.1 'five fields'
mk_reject 192.168.01.1 'interior leading zero'
mk_reject 01.2.3.4 'first leading zero'
mk_reject 1.2.3.00 '00 is not 0'
mk_reject 1.2.3.256 'octet over 255 (last)'
mk_reject 256.0.0.1 'octet over 255 (first)'
mk_reject 1.2.3. 'empty last field'
mk_reject .1.2.3 'empty first field'
mk_reject 1..2.3 'empty interior field'
mk_reject a.b.c.d 'letters'
mk_reject +1.2.3.4 'sign'
t_run s5_ipv4_is_canonical "$(printf ' 1.2.3.4')"
assert_ne 'not canonical: leading space' 0 "$T_STATUS"
t_run s5_ipv4_is_canonical "$(printf '1.2.3.4 ')"
assert_ne 'not canonical: trailing space' 0 "$T_STATUS"
t_run s5_ipv4_is_canonical "$(printf '1.2.3.4\t')"
assert_ne 'not canonical: tab' 0 "$T_STATUS"
# The trailing-LF case cannot go through t_run: command substitution strips
# the newline before the validator would see it, making the test vacuous.
# read -r preserves it.
# Driven in this shell with the sentinel-suffix construction: plain command
# substitution strips the newline under test; appending x and peeling it off
# preserves the byte in the argument.
printf '1.2.3.4\n' >"$S5_TEST_ROOT/lfvec"
_cvlf=$(cat "$S5_TEST_ROOT/lfvec"; printf x)
_cvlf=${_cvlf%x}
if s5_ipv4_is_canonical "$_cvlf"; then
    t_bad 'not canonical: trailing LF (pure validator never strips)'
else
    t_ok
fi
_cvlf='' 
t_run s5_ipv4_is_canonical "$(printf '1.2.3.4\r\n')"
assert_ne 'not canonical: CRLF' 0 "$T_STATUS"
t_run s5_ipv4_is_canonical "$(printf '1.2.3.4\n5.6.7.8')"
assert_ne 'not canonical: second line' 0 "$T_STATUS"
mk_reject 192.168.1.10/24 'CIDR suffix'
mk_reject 1.2.3.4:1080 'port suffix'
mk_reject 1.2.3.4/255.255.255.0 'netmask suffix'
mk_reject ::1 'IPv6 loopback'
mk_reject 2001:db8::1 'IPv6'
t_run s5_ipv4_is_canonical ''
assert_ne 'not canonical: empty' 0 "$T_STATUS"

# ---------------------------------------------------------------------------
# 2. Classification: s5_ipv4_is_public / s5_ipv4_is_usable_local
# Both presuppose canonical input.
# ---------------------------------------------------------------------------
both_reject() {
    t_run s5_ipv4_is_public "$1"
    assert_eq "public rejects: $1" 1 "$T_STATUS"
    t_run s5_ipv4_is_usable_local "$1"
    assert_eq "usable rejects: $1" 1 "$T_STATUS"
}
private_for_public_only() {
    t_run s5_ipv4_is_public "$1"
    assert_eq "public rejects RFC1918/CGNAT: $1" 1 "$T_STATUS"
    t_run s5_ipv4_is_usable_local "$1"
    assert_eq "usable accepts RFC1918/CGNAT: $1" 0 "$T_STATUS"
}
both_accept() {
    t_run s5_ipv4_is_public "$1"
    assert_eq "public accepts: $1" 0 "$T_STATUS"
    t_run s5_ipv4_is_usable_local "$1"
    assert_eq "usable accepts: $1" 0 "$T_STATUS"
}

both_reject 0.0.0.0
both_reject 0.255.255.255
private_for_public_only 10.0.0.0
private_for_public_only 10.255.255.255
private_for_public_only 100.64.0.0
private_for_public_only 100.100.1.1
private_for_public_only 100.127.255.255
both_reject 127.0.0.1
both_reject 127.255.255.255
both_reject 169.254.0.0
both_reject 169.254.42.99
both_reject 169.254.255.255
private_for_public_only 172.16.0.0
private_for_public_only 172.20.10.3
private_for_public_only 172.31.255.255
both_reject 192.0.0.0
both_reject 192.0.0.255
both_reject 192.0.2.0
both_reject 192.0.2.100
private_for_public_only 192.168.0.0
private_for_public_only 192.168.255.255
both_reject 198.18.0.0
both_reject 198.19.17.42
both_reject 198.51.100.0
both_reject 198.51.100.77
both_reject 203.0.113.0
both_reject 203.0.113.200
both_reject 224.0.0.0
both_reject 230.1.2.3
both_reject 239.255.255.255
both_reject 240.0.0.1
both_reject 250.0.0.1
both_reject 255.255.255.254
both_reject 255.255.255.255

both_accept 1.0.0.1
both_accept 9.255.255.255
both_accept 99.1.2.3
both_accept 100.63.255.255
both_accept 100.128.0.0
both_accept 101.1.2.3
both_accept 126.255.255.255
both_accept 128.0.0.0
both_accept 169.253.255.255
both_accept 169.255.0.0
both_accept 170.0.0.1
both_accept 172.15.255.255
both_accept 172.32.0.0
both_accept 191.255.255.255
both_accept 192.0.1.0
both_accept 192.0.3.0
both_accept 192.0.44.5
both_accept 192.5.5.5
both_accept 192.167.255.255
both_accept 192.169.0.0
both_accept 198.17.255.255
both_accept 198.20.0.0
both_accept 198.51.99.255
both_accept 198.51.101.0
both_accept 199.0.0.1
both_accept 203.0.112.255
both_accept 203.0.114.0
both_accept 223.255.255.255
both_accept 45.77.10.22
both_accept 96.30.11.5

# ---------------------------------------------------------------------------
# 3. Resolver behavior through the curl stub (no real network).
# ---------------------------------------------------------------------------
# The curl stub records argv and returns a scripted body when the marker file
# exists; without the marker it models a transport failure.
: >"$S5_TEST_ROOT/curl_public_ip_body"
printf '45.77.10.22\n' >"$S5_TEST_ROOT/curl_public_ip_body"
rm -f "$S5_TEST_ROOT/curl_public_ip_body"

# Structural contract: the lookup uses the fixed endpoint with hardened flags.
t_run s5_lookup_public_ipv4
assert_ne "without a stub body the lookup fails" 0 "$T_STATUS"

# ---------------------------------------------------------------------------
# 4. Card-level contract: resolver runs once, Host and URI agree, warnings.
# ---------------------------------------------------------------------------
# The resolver is nonfatal in EVERY path (even placeholder returns 0), so
# existence and effect are observed in this shell through its globals. The
# real ip/hostname on this host return live addresses, so both are shadowed
# by shell functions (PATH stubs cannot hide busybox applets -- the repo's
# own convention) and the lookup already fails through the real curl stub's
# no-body default.
ip() { return 1; }
hostname() { return 1; }
S5_CARD_ADDR=''
S5_CARD_KIND=''
if s5_resolve_card_address; then
    t_ok
else
    t_bad "the resolver must be nonfatal even in the placeholder path"
fi
assert_eq "no candidates resolves to the placeholder" "SERVER_IPV4" "$S5_CARD_ADDR"
assert_eq "with the placeholder kind" "placeholder" "$S5_CARD_KIND"
unset -f ip hostname

# With a usable local candidate (ip shadow returning one line), the resolver
# picks it up in order, kind local.
ip() {
    printf '2: eth0    inet 192.168.1.10/24 brd 192.168.1.255 scope global eth0\n'
    return 0
}
hostname() { return 1; }
S5_CARD_ADDR=''
S5_CARD_KIND=''
s5_resolve_card_address
assert_eq "the raw ip -o token is stripped and adopted" "192.168.1.10" "$S5_CARD_ADDR"
assert_eq "with the local kind" "local" "$S5_CARD_KIND"
unset -f ip hostname

# hostname -I is the second source; loopback tokens are skipped, first
# usable wins.
ip() { return 1; }
hostname() {
    printf '127.0.0.1 fe80::1 10.0.0.5\n'
    return 0
}
S5_CARD_ADDR=''
S5_CARD_KIND=''
s5_resolve_card_address
assert_eq "loopback and IPv6 tokens skipped, first usable wins" "10.0.0.5" "$S5_CARD_ADDR"
assert_eq "with the local kind from hostname" "local" "$S5_CARD_KIND"
unset -f ip hostname

# ---------------------------------------------------------------------------
# 5. External-body handling through the curl stub (§3 of the test table).
# ---------------------------------------------------------------------------
S5_LANG=en
ip() { return 1; }
hostname() { return 1; }

body_case() {
    # _bd carries real control bytes when produced with printf '%b'; the
    # expected value strips one trailing CR/LF pair the same way the
    # production handler does.
    _bd=$1
    _bw=$2
    printf '%b' "$_bd" >"$S5_TEST_ROOT/stub_ip_body"
    S5_CARD_ADDR=''
    S5_CARD_KIND=''
    s5_resolve_card_address
    if [ "$S5_CARD_KIND" = external ]; then
        if [ "$_bw" = accept ]; then
            _bde=$(printf '%b' "$_bd")
            _bde=${_bde%"$(printf '\r')"}
            _bde=${_bde%"$(printf '\n')"}
            assert_eq "body accepted: $_bd" "$S5_CARD_ADDR" "$_bde"
            _bde=''
        else
            t_bad "body should be rejected: $_bd"
        fi
    else
        if [ "$_bw" = accept ]; then
            t_bad "body should be accepted: $_bd"
        else
            t_ok
        fi
    fi
    rm -f "$S5_TEST_ROOT/stub_ip_body"
    _bd=''
}

body_case '45.77.10.22' accept
body_case '45.77.10.22\n' accept
body_case '45.77.10.22\r\n' accept
body_case '' reject
body_case ' 45.77.10.22' reject
body_case '45.77.10.22 ' reject
body_case '45.77.10.22\t' reject
body_case '10.0.0.5' reject
body_case '192.168.1.10' reject
body_case '169.254.9.9' reject
body_case '203.0.113.7' reject
body_case '255.255.255.255' reject
body_case '2001:db8::1' reject
body_case '<html>404</html>' reject
body_case '123.123.123.123\r\n' accept
body_case '045.77.10.22' reject
body_case '45.77.10.22x' reject
body_case '45.77.10.999' reject

# ---------------------------------------------------------------------------
# 6. Security assertions: no secret anywhere near the lookup, one lookup per
# card, raw body never surfaces.
# ---------------------------------------------------------------------------
S5_SECRET='CardSecret_99'
printf '45.77.10.22\n' >"$S5_TEST_ROOT/stub_ip_body"
s5env_reset_transcript
S5_CARD_ADDR=''
S5_CARD_KIND=''
s5_resolve_card_address
assert_eq "external body resolves" "45.77.10.22" "$S5_CARD_ADDR"
# argv recorded by the stub carries no secret:
if t_transcript | grep -q 'CardSecret_99'; then
    t_bad "the secret leaked into lookup argv"
else
    t_ok
fi
# hardened flags and fixed endpoint present:
t_assert_called "lookup uses the fixed endpoint" 'https://icanhazip.com'
t_assert_called "lookup neutralizes ambient proxies" '--noproxy'
t_assert_called "lookup is IPv4-only" '-4'
t_assert_called "lookup refuses redirects implicitly via proto" "--proto =https"
t_assert_called "lookup fails on HTTP errors" '--fail'
t_assert_called "lookup ignores curlrc" '-q'

# exactly one lookup per resolution
_lookups=$(t_transcript | grep -c 'https://icanhazip.com' || true)
assert_eq "exactly one lookup per card" 1 "$_lookups"

# raw body never surfaces anywhere
rm -f "$S5_TEST_ROOT/stub_ip_body"
printf 'RAWBODY-7c31e9-SENTINEL\n' >"$S5_TEST_ROOT/stub_ip_body"
S5_CARD_ADDR=''
S5_CARD_KIND=''
_cardout=$(s5_resolve_card_address 2>&1)
if printf '%s' "$_cardout" | grep -q 'RAWBODY'; then
    t_bad "raw lookup body surfaced in resolver output"
else
    t_ok
fi
rm -f "$S5_TEST_ROOT/stub_ip_body"

# HTTP failure code: body ignored
printf '45.77.10.22\n' >"$S5_TEST_ROOT/stub_ip_body"
printf '22' >"$S5_TEST_ROOT/stub_ip_code"
S5_CARD_ADDR=''
S5_CARD_KIND=''
s5_resolve_card_address
assert_eq "HTTP error falls back past the external path" "SERVER_IPV4" "$S5_CARD_ADDR"
rm -f "$S5_TEST_ROOT/stub_ip_body" "$S5_TEST_ROOT/stub_ip_code"

S5_SECRET=''
unset -f ip hostname

# ---------------------------------------------------------------------------
# 7. T12 card contract: one resolution, Host=URI, one warning, exact URI.
# ---------------------------------------------------------------------------
ip() { return 1; }
hostname() { printf '%s\n' '10.20.30.40'; }
S5_LANG=en
S5_USERNAME=carduser
S5_PASSWORD='CardPass_123~x'
S5_SECRET=$S5_PASSWORD
S5_PORT=41080
S5_SELF=''

_card=$(s5_render_card 2>/dev/null)
assert_contains "local card shows the resolved host" "10.20.30.40" "$_card"
assert_contains "local card shows the exact URI"     "socks5://carduser:CardPass_123~x@10.20.30.40:41080" "$_card"
_warns=$(printf '%s' "$_card" | grep -c 'WARNING: the public egress' || true)
assert_eq "exactly one local-fallback warning" 1 "$_warns"

# placeholder path: one actionable warning, URI uses the placeholder.
ip() { return 1; }
hostname() { return 1; }
_card=$(s5_render_card 2>/dev/null)
assert_contains "placeholder card uses SERVER_IPV4 in the URI"     "socks5://carduser:CardPass_123~x@SERVER_IPV4:41080" "$_card"
_pw=$(printf '%s' "$_card" | grep -c 'Replace SERVER_IPV4' || true)
assert_eq "exactly one placeholder warning" 1 "$_pw"

# external path: no fallback warning at all.
printf '45.77.10.22\n' >"$S5_TEST_ROOT/stub_ip_body"
_card=$(s5_render_card 2>/dev/null)
assert_contains "external card shows the observed address" "45.77.10.22" "$_card"
_nw=$(printf '%s' "$_card" | grep -c 'WARNING: the public egress\|Replace SERVER_IPV4' || true)
assert_eq "no fallback warning on external success" 0 "$_nw"
rm -f "$S5_TEST_ROOT/stub_ip_body"

# Host field and URI agree byte-for-byte in the Chinese rendering too.
S5_LANG=zh
printf '45.77.10.22\n' >"$S5_TEST_ROOT/stub_ip_body"
_card=$(s5_render_card 2>/dev/null)
assert_contains "zh card keeps the language-independent URI"     "socks5://carduser:CardPass_123~x@45.77.10.22:41080" "$_card"
assert_contains "zh card labels the host in Chinese" "服务器地址" "$_card"
rm -f "$S5_TEST_ROOT/stub_ip_body"
S5_LANG=en

S5_SECRET=''
unset -f ip hostname

t_summary
