#!/bin/sh
# tests/unit/test_card.sh - strict public IPv4 resolution and the shared
# localized credential card.
#
# The card accepts only a validated external IPv4. Lookup failure yields an
# explicit SERVER_IPV4 placeholder; local interface addresses are never guessed.
# This file owns the canonical/public validators, hardened response boundary,
# one warning per card, and Host/URI agreement.

S5T_NAME=test_card
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
. "${S5_REPO_ROOT}/tests/lib/stub.sh"
. "${S5_REPO_ROOT}/tests/lib/env.sh"

s5env_setup
s5env_load

SRC=${S5_SRC:?S5_SRC unset}

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
# 2. Classification: only strictly public IPv4 addresses are eligible.
# ---------------------------------------------------------------------------
public_reject() {
    t_run s5_ipv4_is_public "$1"
    assert_eq "public rejects: $1" 1 "$T_STATUS"
}
public_accept() {
    t_run s5_ipv4_is_public "$1"
    assert_eq "public accepts: $1" 0 "$T_STATUS"
}

for _ip in 0.0.0.0 0.255.255.255 10.0.0.0 10.255.255.255 \
    100.64.0.0 100.100.1.1 100.127.255.255 127.0.0.1 127.255.255.255 \
    169.254.0.0 169.254.42.99 169.254.255.255 172.16.0.0 172.20.10.3 \
    172.31.255.255 192.0.0.0 192.0.0.255 192.0.2.0 192.0.2.100 \
    192.168.0.0 192.168.255.255 198.18.0.0 198.19.17.42 \
    198.51.100.0 198.51.100.77 203.0.113.0 203.0.113.200 \
    224.0.0.0 230.1.2.3 239.255.255.255 240.0.0.1 250.0.0.1 \
    255.255.255.254 255.255.255.255; do
    public_reject "$_ip"
done

for _ip in 1.0.0.1 9.255.255.255 99.1.2.3 100.63.255.255 \
    100.128.0.0 101.1.2.3 126.255.255.255 128.0.0.0 \
    169.253.255.255 169.255.0.0 170.0.0.1 172.15.255.255 \
    172.32.0.0 191.255.255.255 192.0.1.0 192.0.3.0 192.0.44.5 \
    192.5.5.5 192.167.255.255 192.169.0.0 198.17.255.255 \
    198.20.0.0 198.51.99.255 198.51.101.0 199.0.0.1 \
    203.0.112.255 203.0.114.0 223.255.255.255 45.77.10.22 96.30.11.5; do
    public_accept "$_ip"
done

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

# Local interface addresses are deliberately ignored: a private address is not
# a safe guess for the host an Internet client should copy.
ip() {
    printf '2: eth0    inet 192.168.1.10/24 brd 192.168.1.255 scope global eth0\n'
    return 0
}
hostname() { printf '10.0.0.5\n'; }
S5_CARD_ADDR=''
S5_CARD_KIND=''
s5_resolve_card_address
assert_eq "local addresses do not replace the public host" "SERVER_IPV4" "$S5_CARD_ADDR"
assert_eq "failed public lookup uses the placeholder kind" "placeholder" "$S5_CARD_KIND"
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
t_assert_called "lookup caps the downloaded body" '--max-filesize 17'

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
# 7. Card contract: one resolution, Host=URI, one warning, exact URI.
# ---------------------------------------------------------------------------
# A failed public lookup uses the explicit placeholder even when local address
# commands would return a private address.
ip() { printf '2: eth0    inet 10.20.30.40/24 scope global eth0\n'; }
hostname() { printf '%s\n' '10.20.30.40'; }
S5_LANG=en
S5_USERNAME=carduser
S5_PASSWORD='CardPass_123~x'
S5_SECRET=$S5_PASSWORD
S5_PORT=41080
S5_SELF=''

_card=$(s5_render_card 2>/dev/null)
assert_contains "fallback card shows the explicit placeholder" "SERVER_IPV4" "$_card"
assert_contains "fallback card shows the exact URI" \
    "socks5://carduser:CardPass_123~x@SERVER_IPV4:41080" "$_card"
_warns=$(printf '%s' "$_card" | grep -c 'Replace SERVER_IPV4' || true)
assert_eq "exactly one placeholder warning" 1 "$_warns"

# Repeated placeholder rendering stays singular and actionable.
_card=$(s5_render_card 2>/dev/null)
assert_contains "placeholder card uses SERVER_IPV4 in the URI" \
    "socks5://carduser:CardPass_123~x@SERVER_IPV4:41080" "$_card"
_pw=$(printf '%s' "$_card" | grep -c 'Replace SERVER_IPV4' || true)
assert_eq "exactly one placeholder warning on each card" 1 "$_pw"

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

# ---------------------------------------------------------------------------
# BF-01: the external lookup's response boundary. The curl|head pipeline masks
# curl's own failure status (pipe status is head's 0), truncates an oversized
# response to its valid prefix, and command substitution strips trailing
# newlines -- so a dead endpoint that prints a body, a body with trailing
# garbage, and a multi-LF body were all accepted. These must fail closed.
# ---------------------------------------------------------------------------
S5_LANG=en
ip() { return 1; }
hostname() { return 1; }

# curl prints a valid body but FAILS: the lookup must not adopt the address.
printf '123.123.123.123' >"$S5_TEST_ROOT/stub_ip_body"
printf '22' >"$S5_TEST_ROOT/stub_ip_code"
S5_CARD_ADDR='PRIOR-VALUE'
S5_CARD_KIND=''
s5_resolve_card_address
assert_eq "a failed curl with a valid body is not adopted" "SERVER_IPV4" "$S5_CARD_ADDR"
assert_eq "and falls to the placeholder" "placeholder" "$S5_CARD_KIND"
rm -f "$S5_TEST_ROOT/stub_ip_body" "$S5_TEST_ROOT/stub_ip_code"

# A body longer than one valid address + one terminator: the extra bytes prove
# the response is not a single address line, truncation must not rescue it.
printf '123.123.123.123\r\nX' >"$S5_TEST_ROOT/stub_ip_body"
S5_CARD_ADDR='PRIOR-VALUE'
S5_CARD_KIND=''
s5_resolve_card_address
assert_eq "oversized valid-prefix body is rejected" "SERVER_IPV4" "$S5_CARD_ADDR"
rm -f "$S5_TEST_ROOT/stub_ip_body"

# Double trailing LF: a second terminator survives one strip and must reject.
printf '123.123.123.123\n\n' >"$S5_TEST_ROOT/stub_ip_body"
S5_CARD_ADDR='PRIOR-VALUE'
S5_CARD_KIND=''
s5_resolve_card_address
assert_eq "double-terminator body is rejected" "SERVER_IPV4" "$S5_CARD_ADDR"
rm -f "$S5_TEST_ROOT/stub_ip_body"

# Two full lines must reject (the second line is lost to substitution today).
printf '123.123.123.123\n45.77.10.22\n' >"$S5_TEST_ROOT/stub_ip_body"
S5_CARD_ADDR='PRIOR-VALUE'
S5_CARD_KIND=''
s5_resolve_card_address
assert_eq "two-line body is rejected" "SERVER_IPV4" "$S5_CARD_ADDR"
rm -f "$S5_TEST_ROOT/stub_ip_body"

# Exactly one address + one CRLF is the largest legal body: still accepted.
printf '123.123.123.123\r\n' >"$S5_TEST_ROOT/stub_ip_body"
S5_CARD_ADDR='PRIOR-VALUE'
S5_CARD_KIND=''
s5_resolve_card_address
assert_eq "exactly-at-cap body is accepted" "123.123.123.123" "$S5_CARD_ADDR"
assert_eq "with the external kind" "external" "$S5_CARD_KIND"
rm -f "$S5_TEST_ROOT/stub_ip_body"

# ---------------------------------------------------------------------------
# BF-01: missed IANA special-purpose ranges. The classifier's comment claims
# every special-purpose range is rejected; these four were not.
# ---------------------------------------------------------------------------
for _sp in 192.31.196.1 192.31.196.254 192.175.48.1 192.175.48.254 \
    192.52.193.1 192.52.193.254 192.88.99.1 192.88.99.254; do
    t_run s5_ipv4_is_public "$_sp"
    assert_eq "special-purpose address is not public: $_sp" 1 "$T_STATUS"
done

unset -f ip hostname

# ---------------------------------------------------------------------------
# BF-02: the card contract. SPEC 10: install and show share ONE renderer, the
# URI is a single unindented line, Host and URI use the same resolved address,
# and the zh cloud-provider warning carries the port.
# ---------------------------------------------------------------------------
S5_LANG=en
ip() { printf '2: eth0    inet 10.20.30.40/24 scope global eth0\n'; }
hostname() { return 1; }
S5_USERNAME=bfuser
S5_PASSWORD='BfPass_123~x'
S5_SECRET=$S5_PASSWORD
S5_PORT=41080

_card=$(s5_render_card 2>/dev/null)

# URI: exactly one, unindented, alone on its line.
_uri_count=$(printf '%s\n' "$_card" | grep -c '^socks5://' || true)
assert_eq "the URI is unindented (exactly one line starts at column 0)" 1 "$_uri_count"
_uri_indented=$(printf '%s\n' "$_card" | grep -c '^[[:space:]]+socks5://' || true)
assert_eq "no indented copy of the URI exists" 0 "$_uri_indented"

# Host/URI agreement: both use the same explicit placeholder on lookup failure.
assert_contains "the host field carries the placeholder" "SERVER_IPV4" "$_card"
_uri_line=$(printf '%s\n' "$_card" | grep '^socks5://' | head -n 1)
assert_contains "the URI carries the same placeholder" "@SERVER_IPV4:41080" "$_uri_line"

# The zh cloud-provider warning must name the port (the zh catalog arm dropped it).
S5_LANG=zh
_cardzh=$(s5_render_card 2>/dev/null)
assert_contains "zh cloud-provider warning names the port" "41080" "$_cardzh"
assert_contains "zh warning mentions TCP" "TCP" "$_cardzh"
S5_LANG=en

# Structural: install AND show both go through the shared renderer. s5_cmd_show
# currently duplicates the card body; this structural pin makes the duplicate
# visible.
_show_body=$(sed -n '/^_s5_cmd_show_locked() {/,/^}/p' "$SRC")
if printf '%s\n' "$_show_body" | grep -q 's5_render_card'; then
    t_ok
else
    t_bad "s5_cmd_show must call the shared s5_render_card, not a duplicate body"
fi
# A duplicated card body would re-print the URI; show must render exactly one.
_dup_markers=$(printf '%s\n' "$_show_body" | grep -c 'socks5://\$S5_USERNAME' || true)
assert_eq "show does not carry its own URI interpolation" 0 "$_dup_markers"

unset -f ip hostname
S5_SECRET=''

t_summary
