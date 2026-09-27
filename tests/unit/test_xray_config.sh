#!/bin/sh
# Xray mixed configuration contract and config-test ordering.

S5T_NAME=test_xray_config
. "${S5_REPO_ROOT}/tests/lib/assert.sh"

t_mktestroot
t_source_production ''

S5_LANG=en
S5_PORT=23456
S5_USERNAME=alice
S5_PASSWORD='Secret123xyz'
S5_SECRET=$S5_PASSWORD
S5_LISTEN=127.0.0.1
mkdir -p "$S5_SYSCONFDIR"

config=$(s5_config_render)
assert_contains "config has mixed protocol" '"protocol": "mixed"' "$config"
assert_contains "config requires password auth" '"auth": "password"' "$config"
assert_contains "config disables UDP" '"udp": false' "$config"
assert_contains "config has the requested port" '"port": 23456' "$config"
assert_contains "config has the requested account" '"user": "alice"' "$config"
assert_contains "config has one direct outbound" '"protocol": "freedom"' "$config"
assert_not_contains "config has no public API" '"api"' "$config"
assert_not_contains "config has no stats service" '"stats"' "$config"

# SPEC 3 and 7: the destination boundary. An authenticated client must not reach
# the proxy host's own loopback, the private and CGNAT ranges behind it, or the
# link-local range that carries cloud instance metadata at 169.254.169.254. The
# expected ranges are written out here from the spec rather than read back from
# the renderer, so a range dropped from the config cannot also vanish from the
# oracle.
assert_contains "denied destinations reach a blackhole outbound" \
    '{"protocol": "blackhole", "settings": {}, "tag": "blocked"}' "$config"
assert_contains "the deny rule routes to that outbound" \
    '"outboundTag": "blocked"' "$config"
assert_contains "a hostname target is matched on its resolved address" \
    '"domainStrategy": "IPIfNonMatch"' "$config"
# The installer extracts only the xray executable, so a geoip rule would name a
# database that is never on disk.
assert_not_contains "the boundary needs no geoip database" 'geoip' "$config"
for _dc in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 \
    172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4 \
    '::1/128' 'fc00::/7' 'fe80::/10'; do
    assert_contains "the boundary denies $_dc" "\"$_dc\"" "$config"
done
# A range added without a decision is as much a change as one removed.
assert_eq "the boundary denies exactly twelve ranges" 12 \
    "$(printf '%s\n' "$config" | sed -n '/"ip": \[/,/\]/p' | grep -c '/')"

printf '%s\n' "$config" >"$S5_TEST_ROOT/config.json"
if python3 -m json.tool "$S5_TEST_ROOT/config.json" >/dev/null 2>&1; then
    t_ok
else
    t_bad "rendered configuration is valid JSON"
fi

assert_not_contains "config output is not printed by an error path" "$S5_PASSWORD" \
    "$(s5_msg_err config.invalid 2>&1)"

# Byte-for-byte reference renders. The golden config carries the test-mode
# listen address (S5_LISTEN is forced to 127.0.0.1 under S5_TEST_MODE); SPEC 3's
# canonical JSON shows the production 0.0.0.0 for the same shape.
S5_PORT=23456
S5_USERNAME=testuser
S5_PASSWORD='TestPassword123xyz'
S5_SECRET=$S5_PASSWORD
golden_config=$(cat "${S5_REPO_ROOT}/tests/golden/xray.config.json")
assert_eq "rendered config matches the golden config" \
    "$golden_config" "$(s5_config_render)"

mkdir -p "$S5_UNITDIR"
s5_write_unit >/dev/null 2>&1
golden_unit=$(cat "${S5_REPO_ROOT}/tests/golden/xray-socks5.service")
rendered_unit=$(sed "s|$S5_TEST_ROOT||g" "$S5_SERVICE_ARTIFACT")
assert_eq "rendered unit matches the golden unit" "$golden_unit" "$rendered_unit"

# status, show, restart, uninstall and update all recover the account from the
# published config, so what the renderer writes has to be readable back.
s5_config_render >"$S5_CFG"
S5_USERNAME=''
S5_PASSWORD=''
if s5_config_extract; then
    t_ok
else
    t_bad "the published config can be read back"
fi
assert_eq "extract recovers the username" testuser "$S5_USERNAME"
assert_eq "extract recovers the password" 'TestPassword123xyz' "$S5_PASSWORD"

S5_USERNAME=alice
S5_PASSWORD='Secret123xyz'
S5_SECRET=$S5_PASSWORD

S5_ARCHNAME=amd64
s5_asset_select
S5_BIN="$S5_TEST_ROOT/xray"
cat >"$S5_BIN" <<'XRAY'
#!/bin/sh
printf '%s\n' "$*" >>"$S5_TEST_ROOT/xray-calls"
exit 0
XRAY
chmod 0755 "$S5_BIN"
if s5_config_test "$S5_CFG"; then t_ok; else t_bad "config-test wrapper succeeds"; fi
assert_contains "config-test uses run -test -c" \
    "run -test -c $S5_CFG" "$(cat "$S5_TEST_ROOT/xray-calls")"

# The production writer gives Xray's format detector a .json candidate path.
S5_CONFIG_TEST_STATUS=0
candidate=$(s5_write_config_candidate)
assert_contains "candidate config-test path has a JSON suffix" \
    '.s5new.' "$candidate"
case "$candidate" in
*.json) t_ok ;; *) t_bad "candidate path ends in .json: $candidate" ;; esac
rm -f "$candidate"

# A rejected candidate has to explain itself: the engine's own diagnostic is the
# only thing that says why, and it must arrive with the password removed.
cat >"$S5_BIN" <<'XRAY'
#!/bin/sh
printf 'xray: refusing config carrying pass Secret123xyz\n' >&2
exit 23
XRAY
chmod 0755 "$S5_BIN"
S5_SECRET='Secret123xyz'
t_run s5_config_test "$S5_CFG"
assert_ne "a rejected candidate fails" 0 "$T_STATUS"
assert_contains "the engine reason reaches the operator" 'refusing config' "$T_OUT"
assert_not_contains "the engine reason is redacted" 'Secret123xyz' "$T_OUT"
assert_contains "the engine reason uses the standard redaction marker" '<REDACTED>' "$T_OUT"
cat >"$S5_BIN" <<'XRAY'
#!/bin/sh
printf '%s\n' "$*" >>"$S5_TEST_ROOT/xray-calls"
exit 0
XRAY
chmod 0755 "$S5_BIN"

# A malformed candidate must be rejected before it can be published.
S5_CFG="$S5_TEST_ROOT/published.json"
printf '{broken\n' >"$S5_TEST_ROOT/candidate.json"
S5_CONFIG_TEST_STATUS=1
s5_config_test() { return "$S5_CONFIG_TEST_STATUS"; }
t_run s5_write_config_candidate
assert_ne "config-test failure rejects the candidate" 0 "$T_STATUS"
# The failure branch returns no path, so a survivor can only be found by the
# writer's own candidate pattern. An unmatched glob stays literal, which is the
# absent path the assertion then sees.
set -- "$S5_SYSCONFDIR"/.s5new.*.json
assert_file_absent "config-test failure leaves no candidate file" "$1"

# The mixed contract is strict: a caller cannot accidentally downgrade auth or
# enable UDP by changing the renderer inputs.
S5_PASSWORD='Bad:password'
t_run s5_config_render
assert_ne "password characters outside the accepted set are rejected" 0 "$T_STATUS"
S5_PASSWORD='Secret123xyz'
S5_LISTEN='127.0.0.1
include /tmp/extra'
t_run s5_config_render
assert_ne "multiline listen values are rejected" 0 "$T_STATUS"
S5_LISTEN=127.0.0.1

# A credential that is generated or entered from now on is letters and digits
# only, so nothing in a printed URI can be mis-parsed by a client. Each refused
# character is tested at a length the bounds accept, so a charset regression
# cannot hide behind a length refusal.
for _bad_user in 'alice_bob' 'alice-bob' 'alice.bob' 'alice~bob'; do
    if s5_valid_username "$_bad_user"; then
        t_bad "username $_bad_user is refused"
    else
        t_ok
    fi
done
for _bad_pass in 'Secret123xy_z' 'Secret123xy-z' 'Secret123xy.z' 'Secret123xy~z'; do
    if s5_valid_password "$_bad_pass"; then
        t_bad "password $_bad_pass is refused"
    else
        t_ok
    fi
done
if s5_valid_username alicebob && s5_valid_password Secret123xyz; then
    t_ok
else
    t_bad "letters and digits are still accepted"
fi

# The generator must not be able to emit a value its own validator refuses.
_gen_alphabet=ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789
_gen_bad=0
for _gen_round in 1 2 3 4 5 6 7 8 9 10; do
    _gen_user=$(s5_random_string 12 "$_gen_alphabet") || _gen_bad=1
    _gen_pass=$(s5_random_string 32 "$_gen_alphabet") || _gen_bad=1
    s5_valid_username "$_gen_user" || _gen_bad=1
    s5_valid_password "$_gen_pass" || _gen_bad=1
done
assert_eq "every generated credential satisfies its validator" 0 "$_gen_bad"

# Read-back is deliberately wider than the write path. An installation created
# before the narrowing still has to be readable by status and show, restartable,
# and above all uninstallable, and all of those reach the credential through
# s5_config_extract. Refusing a historical value there would strand the
# installation with no supported way to remove it.
S5_CFG="$S5_TEST_ROOT/legacy.json"
cat >"$S5_CFG" <<'LEGACY'
{
  "inbounds": [{
    "protocol": "mixed",
    "settings": {
      "auth": "password",
      "accounts": [{"user": "legacy_user-1", "pass": "Legacy_pass~123.x"}],
      "udp": false
    }
  }]
}
LEGACY
S5_USERNAME=''
S5_PASSWORD=''
if s5_config_extract; then
    t_ok
else
    t_bad "a pre-narrowing installation is still readable"
fi
assert_eq "extract recovers the historical username" legacy_user-1 "$S5_USERNAME"
assert_eq "extract recovers the historical password" 'Legacy_pass~123.x' "$S5_PASSWORD"
if s5_valid_username "$S5_USERNAME" || s5_valid_password "$S5_PASSWORD"; then
    t_bad "the historical pair is still refused as new input"
else
    t_ok
fi

t_summary
