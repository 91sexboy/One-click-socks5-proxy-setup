#!/bin/sh
# Xray mixed configuration contract and config-test ordering.

S5T_NAME=test_xray_config
. "${S5_REPO_ROOT}/tests/lib/assert.sh"

t_mktestroot
S5_LIB_ONLY=1
S5_ASSUME_ROOT=1
S5_SKIP_OWNERSHIP=1
export S5_LIB_ONLY S5_ASSUME_ROOT S5_SKIP_OWNERSHIP
# shellcheck source=/dev/null
. "${S5_REPO_ROOT}/socks5.sh"

S5_LANG=en
S5_PORT=23456
S5_USERNAME=alice
S5_PASSWORD='Secret_123~x'
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
S5_PASSWORD='TestPassword_123~x'
S5_SECRET=$S5_PASSWORD
golden_config=$(cat "${S5_REPO_ROOT}/tests/golden/xray.config.json")
assert_eq "rendered config matches the golden config" \
    "$golden_config" "$(s5_config_render)"

mkdir -p "$S5_UNITDIR"
s5_write_unit >/dev/null 2>&1
golden_unit=$(cat "${S5_REPO_ROOT}/tests/golden/xray-socks5.service")
rendered_unit=$(sed "s|$S5_TEST_ROOT||g" "$S5_UNIT")
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
assert_eq "extract recovers the password" 'TestPassword_123~x' "$S5_PASSWORD"

S5_USERNAME=alice
S5_PASSWORD='Secret_123~x'
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
    'run -test -c /tmp' "$(cat "$S5_TEST_ROOT/xray-calls")"

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
printf 'xray: refusing config carrying pass Secret_123~x\n' >&2
exit 23
XRAY
chmod 0755 "$S5_BIN"
S5_SECRET='Secret_123~x'
t_run s5_config_test "$S5_CFG"
assert_ne "a rejected candidate fails" 0 "$T_STATUS"
assert_contains "the engine reason reaches the operator" 'refusing config' "$T_OUT"
assert_not_contains "the engine reason is redacted" 'Secret_123~x' "$T_OUT"
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
assert_file_absent "config-test failure leaves no candidate output" "$T_OUT"

# The mixed contract is strict: a caller cannot accidentally downgrade auth or
# enable UDP by changing the renderer inputs.
S5_PASSWORD='Bad:password'
t_run s5_config_render
assert_ne "password characters outside the URI-safe set are rejected" 0 "$T_STATUS"
S5_PASSWORD='Secret_123~x'
S5_LISTEN='127.0.0.1
include /tmp/extra'
t_run s5_config_render
assert_ne "multiline listen values are rejected" 0 "$T_STATUS"

t_summary
