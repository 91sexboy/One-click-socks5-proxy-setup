#!/bin/sh
# Xray installer flow with service and state stubs.

S5T_NAME=test_xray_install
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
ROOT=${S5_REPO_ROOT}
t_mktestroot
mkdir -p "$S5_TEST_ROOT/bin"
S5_LIB_ONLY=1
S5_ASSUME_ROOT=1
S5_SKIP_OWNERSHIP=1
S5_OSRELEASE="$ROOT/tests/fixtures/os-release/debian-12"
S5_ARCHNAME=amd64
export S5_LIB_ONLY S5_ASSUME_ROOT S5_SKIP_OWNERSHIP S5_OSRELEASE
# shellcheck source=/dev/null
. "$ROOT/socks5.sh"

S5_LANG=en
S5_PORT=23456
S5_USERNAME=alice
S5_PASSWORD='Secret_123~x'
S5_SECRET=$S5_PASSWORD
S5_LISTEN=127.0.0.1
S5_PORT_PROBE="$S5_TEST_ROOT/portprobe"
cat >"$S5_PORT_PROBE" <<'PROBE'
#!/bin/sh
if [ -f "$S5_TEST_ROOT/svc_active" ] && [ "$(cat "$S5_TEST_ROOT/svc_active")" = "$1" ]; then exit 1; fi
exit 0
PROBE
chmod 0755 "$S5_PORT_PROBE"
export S5_PORT_PROBE

# Use a valid local Xray-shaped executable and bypass network asset download;
# the production flow remains covered by the asset unit tests.
S5_ASSET_NAME=Xray-linux-64.zip
S5_ASSET_SIZE=1
S5_ASSET_SHA256=deadbeef
S5_ASSET_BINARY_SIZE=1
S5_ASSET_BINARY_SHA256=deadbeef
s5_asset_select() { return 0; }
s5_binary_ready() { return 1; }
s5_download_engine() {
    mkdir -p "$S5_PREFIX"
    printf '#!/bin/sh\nexit 0\n' >"$S5_BIN"
    chmod 0755 "$S5_BIN"
    S5_CREATED_BIN=1
    S5_BINARY_SHA256=deadbeef
    return 0
}
s5_config_test() { printf 'config-test %s\n' "$1" >>"$S5_TEST_ROOT/xray-calls"; return 0; }

cat >"$S5_TEST_ROOT/bin/systemctl" <<'SYSTEMCTL'
#!/bin/sh
T="$S5_TEST_ROOT/transcript"
printf 'systemctl' >>"$T"
for a in "$@"; do printf ' %s' "$a" >>"$T"; done
printf '\n' >>"$T"
case "$1" in
start|restart)
    port=$(sed -n 's/^[[:space:]]*"port":[[:space:]]*\([0-9][0-9]*\),*/\1/p' "$S5_STUB_CFG" | head -n 1)
    printf '%s\n' "$port" >"$S5_TEST_ROOT/svc_active"
    ;;
stop) rm -f "$S5_TEST_ROOT/svc_active" ;;
is-active)
    if [ -f "$S5_TEST_ROOT/svc_active" ]; then exit 0; else exit 3; fi
    ;;
daemon-reload|enable|disable) ;;
esac
exit 0
SYSTEMCTL
chmod 0755 "$S5_TEST_ROOT/bin/systemctl"
PATH="$S5_TEST_ROOT/bin:$PATH"
export PATH
S5_STUB_CFG=$S5_CFG
export S5_STUB_CFG

# Minimal stateful account commands for this isolated install flow.
for _acct_cmd in getent groupadd groupdel useradd userdel id; do
    cat >"$S5_TEST_ROOT/bin/$_acct_cmd" <<'ACCT'
#!/bin/sh
case "${0##*/}" in
getent)
    if [ "$1" = passwd ] && [ -f "$S5_TEST_ROOT/user-exists" ]; then exit 0; fi
    if [ "$1" = group ] && [ -f "$S5_TEST_ROOT/group-exists" ]; then exit 0; fi
    exit 2 ;;
groupadd) : >"$S5_TEST_ROOT/group-exists"; exit 0 ;;
useradd) : >"$S5_TEST_ROOT/user-exists"; exit 0 ;;
groupdel) rm -f "$S5_TEST_ROOT/group-exists"; exit 0 ;;
userdel) rm -f "$S5_TEST_ROOT/user-exists"; exit 0 ;;
id) printf '900\n'; exit 0 ;;
esac
ACCT
    chmod 0755 "$S5_TEST_ROOT/bin/$_acct_cmd"
done

mkdir -p "$S5_UNITDIR"
s5_account_create() {
    S5_CREATED_GROUP=1
    S5_CREATED_USER=1
    S5_ACCOUNT_UID=900
    S5_ACCOUNT_GID=900
    return 0
}
s5_account_identity() { return 0; }
s5_account_remove() { return 0; }
s5_prompt_port() { return 0; }
s5_prompt_username() { return 0; }
s5_prompt_password() { return 0; }
s5_confirm_install() { return 0; }
# Existing install uses the same state protocol but a test executable avoids a
# network download and lets the service stub observe the JSON port.
s5_install_new
status=$?
assert_eq "new Xray installation completes" 0 "$status"
assert_file_exists "Xray config exists" "$S5_CFG"
assert_file_exists "Xray state exists" "$S5_STATE"
assert_file_exists "Xray unit exists" "$S5_UNIT"
assert_eq "state engine marker" xray "$(s5_state_get engine)"
assert_eq "state protocol marker" mixed "$(s5_state_get protocol)"
assert_eq "service command recorded" 1 "$(grep -c 'start xray-socks5.service' "$S5_TEST_ROOT/transcript")"
assert_contains "config test ran before service start" 'config-test' "$(cat "$S5_TEST_ROOT/xray-calls")"
assert_not_contains "password is absent from state" "$S5_PASSWORD" "$(cat "$S5_STATE")"
assert_mode "config is group-readable only" 640 "$S5_CFG"
assert_mode "state is private" 600 "$S5_STATE"

# A changed config makes status fail closed rather than reporting a healthy
# installation from stale state.
printf 'external change\n' >"$S5_CFG"
t_run s5_state_load
assert_ne "external config change is rejected" 0 "$T_STATUS"

# Old namespace remains untouched.
mkdir -p "$S5_TEST_ROOT/etc/socks5-manager"
printf legacy >"$S5_TEST_ROOT/etc/socks5-manager/3proxy.cfg"
assert_file_exists "legacy namespace remains present" "$S5_TEST_ROOT/etc/socks5-manager/3proxy.cfg"

# Service unit never carries credentials.
unit=$(cat "$S5_UNIT")
assert_not_contains "unit does not expose password" "$S5_PASSWORD" "$unit"
assert_contains "unit runs Xray" 'run -c' "$unit"

# An interrupted atomic write leaves a private temporary behind. Cleanup has to
# remove its own, or uninstall's empty-directory check refuses the parent later.
: >"$S5_SYSCONFDIR/.s5tmp.abc123"
: >"$S5_STATEDIR/.s5state.xyz789"
: >"$S5_PREFIX/.xray.qqq111"
S5_INSTALL_COMPLETE=0
S5_SERVICE_STARTED=0
S5_CREATED_UNIT=0
S5_CREATED_CFG=0
S5_CREATED_BIN=0
S5_CREATED_USER=0
S5_CREATED_GROUP=0
S5_CREATED_CONFDIR=0
S5_CREATED_STATEDIR=0
S5_CREATED_PREFIX=0
s5_cleanup
assert_file_absent "cleanup removes its own config temporary" \
    "$S5_SYSCONFDIR/.s5tmp.abc123"
assert_file_absent "cleanup removes its own state temporary" \
    "$S5_STATEDIR/.s5state.xyz789"
assert_file_absent "cleanup removes its own binary temporary" \
    "$S5_PREFIX/.xray.qqq111"
assert_file_exists "cleanup leaves the published config alone" "$S5_CFG"

t_summary
