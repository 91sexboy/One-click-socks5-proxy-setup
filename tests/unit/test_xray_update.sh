#!/bin/sh
# Update transaction: the happy in-place update, and the rollback ladder.

S5T_NAME=test_xray_update
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
# shellcheck disable=SC1091
. "$ROOT/socks5.sh"

S5_LANG=en
# socks5.sh initialises its own globals, so the architecture has to be set after
# sourcing or the state it writes records an empty arch.
S5_ARCHNAME=amd64
S5_PORT=23456
S5_USERNAME=alice
S5_PASSWORD='Secret_123~x'
S5_SECRET=$S5_PASSWORD
S5_LISTEN=127.0.0.1
# The real flow always detects the platform first, and the update guard reads the
# family and init it establishes.
s5_detect_platform || { printf 'platform detection failed\n' >&2; exit 1; }
S5_PORT_PROBE="$S5_TEST_ROOT/portprobe"
cat >"$S5_PORT_PROBE" <<'PROBE'
#!/bin/sh
if [ -f "$S5_TEST_ROOT/svc_active" ] && [ "$(cat "$S5_TEST_ROOT/svc_active")" = "$1" ]; then exit 1; fi
exit 0
PROBE
chmod 0755 "$S5_PORT_PROBE"
export S5_PORT_PROBE

S5_ASSET_NAME=Xray-linux-64.zip
S5_ASSET_SIZE=1
S5_ASSET_SHA256=deadbeef
S5_ASSET_BINARY_SIZE=1
S5_ASSET_BINARY_SHA256=deadbeef
s5_asset_select() { return 0; }
s5_download_engine() {
    mkdir -p "$S5_PREFIX"
    printf '#!/bin/sh\nexit 0\n' >"$S5_BIN"
    chmod 0755 "$S5_BIN"
    S5_CREATED_BIN=1
    # State validation re-hashes the installed binary, so the recorded asset
    # metadata has to describe the stub rather than a placeholder.
    S5_ASSET_BINARY_SIZE=$(wc -c <"$S5_BIN" | tr -d '[:space:]')
    S5_ASSET_BINARY_SHA256=$(sha256sum "$S5_BIN" | awk '{print $1}')
    S5_BINARY_SHA256=$S5_ASSET_BINARY_SHA256
    return 0
}
s5_config_test() { return "$(cat "$S5_TEST_ROOT/cfgtest" 2>/dev/null || printf 0)"; }
s5_verify_dataplane() { return 0; }

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

mkdir -p "$S5_UNITDIR"
s5_account_create() {
    S5_CREATED_GROUP=1
    S5_CREATED_USER=1
    S5_ACCOUNT_UID=900
    S5_ACCOUNT_GID=900
    return 0
}
s5_account_identity() { return 0; }
s5_confirm_install() { return 0; }
s5_confirm_update() { return 0; }
s5_prompt_username() { return 0; }
s5_prompt_password() { return 0; }
s5_prompt_port() { return 0; }

s5_install_new || { printf 'setup install failed\n' >&2; exit 1; }
assert_eq "state records the installed port" 23456 "$(s5_state_get port)"

# debian and el share the systemd unit path, so the init cross-check alone accepts
# a state file written on the other family, and the family is what chooses the
# package manager an update installs from. The recorded value was read into a
# variable nothing ever compared.
_upfamily=$S5_OS_FAMILY
t_run s5_state_load
assert_eq "the recorded family is accepted on the host that wrote it" \
    0 "$T_STATUS"
S5_OS_FAMILY=el
t_run s5_state_load
assert_ne "a state file from another OS family is refused" 0 "$T_STATUS"
S5_OS_FAMILY=$_upfamily
t_run s5_state_load
assert_eq "the family check does not reject the recorded family" 0 "$T_STATUS"

# The update reuses the installed binary rather than downloading again.
s5_binary_ready() { return 0; }

# An update swaps in a new config, restarts, and records the new state, leaving
# no transaction directory behind.
s5_prompt_port() { S5_PORT=23999; return 0; }
s5_install_update
assert_eq "update completes" 0 "$?"
assert_contains "config carries the new port" '"port": 23999' "$(cat "$S5_CFG")"
assert_eq "state records the new port" 23999 "$(s5_state_get port)"
assert_file_absent "update leaves no transaction directory" "$S5_TXNDIR"
assert_eq "service listens on the new port" 23999 "$(cat "$S5_TEST_ROOT/svc_active")"
s5_prompt_port() { return 0; }

# An update has to be able to keep its own port. The running service holds that
# listener, so the generic in-use probe reports it busy and the prompt would
# refuse the port the installation already owns.
s5_port_free 23999
assert_eq "the running port reads as busy" 1 "$?"
S5_PORT=23999
t_run s5_port_owned_by_service 23999
assert_eq "the port this service owns is accepted" 0 "$T_STATUS"
t_run s5_port_owned_by_service 24001
assert_ne "a port this service does not own is refused" 0 "$T_STATUS"

# Ownership is verified rather than assumed, so an unowned or unobservable
# listener on the recorded port is still refused.
S5_LISTENER_PROBE=$S5_TEST_ROOT/foreignprobe
cat >"$S5_LISTENER_PROBE" <<'FP'
#!/bin/sh
exit 2
FP
chmod 0755 "$S5_LISTENER_PROBE"
export S5_LISTENER_PROBE
t_run s5_port_owned_by_service 23999
assert_ne "a foreign listener on the recorded port is refused" 0 "$T_STATUS"
unset S5_LISTENER_PROBE

# SPEC 5: a rejected candidate config is caught before a healthy service is
# stopped, and it leaves the published config in place.
_upcfg=$(sha256sum "$S5_CFG" | awk '{print $1}')
_upstops=$(grep -c 'systemctl stop' "$S5_TEST_ROOT/transcript" || true)
printf 1 >"$S5_TEST_ROOT/cfgtest"
s5_prompt_port() { S5_PORT=24555; return 0; }
t_run s5_install_update
assert_ne "a rejected candidate config fails the update" 0 "$T_STATUS"
assert_eq "the published config is untouched" \
    "$_upcfg" "$(sha256sum "$S5_CFG" | awk '{print $1}')"
assert_eq "a healthy service is never stopped" \
    "$_upstops" "$(grep -c 'systemctl stop' "$S5_TEST_ROOT/transcript" || true)"
assert_eq "the service keeps its previous port" 23999 "$(cat "$S5_TEST_ROOT/svc_active")"
rm -f "$S5_TEST_ROOT/cfgtest"

# When the swapped-in config starts but never reaches the listener, the old
# config and state come back and the transaction evidence is removed.
_upcfg=$(sha256sum "$S5_CFG" | awk '{print $1}')
_upstate=$(sha256sum "$S5_STATE" | awk '{print $1}')
s5_wait_listening() { return 1; }
s5_prompt_port() { S5_PORT=24777; return 0; }
t_run s5_install_update
assert_ne "an unreachable listener fails the update" 0 "$T_STATUS"
assert_eq "the old config is restored" \
    "$_upcfg" "$(sha256sum "$S5_CFG" | awk '{print $1}')"
assert_eq "the old state is restored" \
    "$_upstate" "$(sha256sum "$S5_STATE" | awk '{print $1}')"
assert_file_absent "the transaction evidence is removed" "$S5_TXNDIR"

# Uninstall had no unit coverage at all, and it removed the unit, config, binary,
# account and state before checking that the directories were empty. A leftover
# from an interrupted update therefore aborted it after the destructive half, and
# the re-run reported success through the state.missing short-circuit while the
# namespace, including a transaction copy of the old config, survived.
s5_precheck() { return 0; }
s5_wait_stopped() { return 0; }
s5_service_disable() { return 0; }
s5_account_remove() { S5_CREATED_USER=0; S5_CREATED_GROUP=0; return 0; }
mkdir -p "$S5_TXNDIR"
printf '{}\n' >"$S5_TXNDIR/old.config.json"
printf 'engine\txray\n' >"$S5_TXNDIR/old.state"
chmod 0600 "$S5_TXNDIR/old.config.json" "$S5_TXNDIR/old.state"
: >"$S5_SYSCONFDIR/.s5new.leftover.json"
printf 'y\n' >"$S5_TEST_ROOT/answers.uninstall"
T_OUT=$(s5_cmd_uninstall <"$S5_TEST_ROOT/answers.uninstall" 2>&1) &&
    T_STATUS=0 || T_STATUS=$?
assert_eq "uninstall completes despite an interrupted update's leftovers" \
    0 "$T_STATUS"
assert_file_absent "uninstall removes the config directory" "$S5_SYSCONFDIR"
assert_file_absent "uninstall removes the state directory" "$S5_STATEDIR"
assert_file_absent "uninstall removes the install prefix" "$S5_PREFIX"

# A second run must not call an empty state file success while residue survives.
mkdir -p "$S5_STATEDIR"
: >"$S5_STATEDIR/.s5state.residue"
T_OUT=$(s5_cmd_uninstall <"$S5_TEST_ROOT/answers.uninstall" 2>&1) &&
    T_STATUS=0 || T_STATUS=$?
assert_ne "a missing state file with residue is not success" 0 "$T_STATUS"
rm -rf "$S5_STATEDIR"
T_OUT=$(s5_cmd_uninstall <"$S5_TEST_ROOT/answers.uninstall" 2>&1) &&
    T_STATUS=0 || T_STATUS=$?
assert_eq "a clean namespace reports nothing installed" 0 "$T_STATUS"

t_summary
