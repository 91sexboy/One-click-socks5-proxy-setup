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

# Configuration hash mismatch is distinguished from an absent state.
printf 'changed\n' >"$S5_CFG"
t_run s5_state_load
assert_ne "external config change is refused" 0 "$T_STATUS"

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

t_summary
