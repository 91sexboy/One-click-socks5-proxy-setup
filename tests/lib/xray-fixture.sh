#!/bin/sh
# A non-privileged installed-Xray fixture. External account/service commands,
# engine/config-test outcomes and interactive inputs are controlled; state loading,
# artifact verification, account identity and lifecycle code stay real.

S5T_FIXTURE_PATH=$PATH

t_xray_fixture() {
    # One authoritative initialization boundary: reload production defaults and
    # functions, not a copied list of lifecycle flags. Each scenario gets fresh
    # disk state too. Command-local fault doubles belong inside a subshell.
    t_cleanup_root
    t_mktestroot
    PATH=$S5T_FIXTURE_PATH
    unset S5_LISTENER_PROBE S5_PROTOCOL_VERIFY
    S5_LIB_ONLY=1
    S5_ASSUME_ROOT=1
    S5_SKIP_OWNERSHIP=1
    S5_OSRELEASE="$S5_REPO_ROOT/tests/fixtures/os-release/debian-12"
    export S5_LIB_ONLY S5_ASSUME_ROOT S5_SKIP_OWNERSHIP S5_OSRELEASE
    # shellcheck source=/dev/null
    . "$S5_REPO_ROOT/socks5.sh"
    S5_LANG=en
    S5_ARCHNAME=amd64
    S5_OS_ID=debian
    S5_OS_VERSION_ID=12
    S5_OS_FAMILY=debian
    S5_INIT=systemd
    s5_select_service_artifact || return 1
    S5_PORT=${1:-23456}
    S5_USERNAME=alice
    S5_PASSWORD='Secret_123~x'
    S5_SECRET=$S5_PASSWORD
    S5_LISTEN=127.0.0.1
    mkdir -p "$S5_TEST_ROOT/bin" "$S5_UNITDIR"
    printf '#!/bin/sh\nexit 0\n' >"$S5_TEST_ROOT/asset-xray"
    chmod 0755 "$S5_TEST_ROOT/asset-xray"

    s5_asset_select() {
        # No archive is downloaded here. Metadata describes the immutable local
        # asset, independently of the installed copy that validation re-hashes.
        [ "$S5_ARCHNAME" = amd64 ] || return 1
        S5_ASSET_NAME=Xray-linux-64.zip
        S5_ASSET_BINARY_SIZE=$(wc -c <"$S5_TEST_ROOT/asset-xray" | tr -d '[:space:]')
        S5_ASSET_BINARY_SHA256=$(sha256sum "$S5_TEST_ROOT/asset-xray" | awk '{print $1}')
        S5_ASSET_SIZE=$S5_ASSET_BINARY_SIZE
        S5_ASSET_SHA256=$S5_ASSET_BINARY_SHA256
    }
    if [ "${2:-}" != real-download ]; then
        s5_download_engine() {
            mkdir -p "$S5_PREFIX" || return 1
            cp "$S5_TEST_ROOT/asset-xray" "$S5_BIN" || return 1
            chmod 0755 "$S5_BIN" || return 1
            S5_CREATED_BIN=1
            S5_BINARY_SHA256=$S5_ASSET_BINARY_SHA256
        }
    fi
    s5_config_test() {
        printf 'config-test %s\n' "$1" >>"$S5_TEST_ROOT/xray-calls"
        return "$(cat "$S5_TEST_ROOT/cfgtest" 2>/dev/null || printf 0)"
    }
    s5_prompt_port() { return 0; }
    s5_prompt_username() { return 0; }
    s5_prompt_password() { return 0; }
    s5_confirm_install() { return 0; }
    s5_confirm_update() { return 0; }

    S5_PORT_PROBE="$S5_TEST_ROOT/portprobe"
    cat >"$S5_PORT_PROBE" <<'PROBE'
#!/bin/sh
if [ -f "$S5_TEST_ROOT/svc_active" ] && [ "$(cat "$S5_TEST_ROOT/svc_active")" = "$1" ]; then exit 1; fi
exit 0
PROBE
    chmod 0755 "$S5_PORT_PROBE"
    export S5_PORT_PROBE
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
    cat >"$S5_TEST_ROOT/bin/rc-service" <<'RCSERVICE'
#!/bin/sh
case "$2" in
stop) rm -f "$S5_TEST_ROOT/svc_active" ;;
status) test -f "$S5_TEST_ROOT/svc_active"; exit $? ;;
esac
exit 0
RCSERVICE
    chmod 0755 "$S5_TEST_ROOT/bin/systemctl" "$S5_TEST_ROOT/bin/rc-service"
    for _acct_cmd in getent groupadd groupdel useradd userdel id; do
        cat >"$S5_TEST_ROOT/bin/$_acct_cmd" <<'ACCT'
#!/bin/sh
case "${0##*/}" in
getent)
    case "$1" in
    passwd) test -f "$S5_TEST_ROOT/user-exists" || exit 2
        printf 'xray-socks5:x:900:900::/nonexistent:/usr/sbin/nologin\n' ;;
    group) test -f "$S5_TEST_ROOT/group-exists" || exit 2
        printf 'xray-socks5:x:%s:\n' "$(cat "$S5_TEST_ROOT/group-exists")" ;;
    *) exit 2 ;;
    esac ;;
groupadd) printf '900\n' >"$S5_TEST_ROOT/group-exists" ;;
useradd) printf '900\n' >"$S5_TEST_ROOT/user-exists" ;;
groupdel) rm -f "$S5_TEST_ROOT/group-exists" ;;
userdel) rm -f "$S5_TEST_ROOT/user-exists" ;;
id)
    test -f "$S5_TEST_ROOT/user-exists" || exit 1
    case "$1" in
    -u) cat "$S5_TEST_ROOT/user-exists" ;;
    -g) cat "$S5_TEST_ROOT/group-exists" ;;
    *) exit 1 ;;
    esac ;;
esac
ACCT
        chmod 0755 "$S5_TEST_ROOT/bin/$_acct_cmd"
    done
    # Some BusyBox shells prefer their built-in id applet over PATH. Route the
    # external account command explicitly, without replacing account validation.
    id() { "$S5_TEST_ROOT/bin/id" "$@"; }
    PATH="$S5_TEST_ROOT/bin:$PATH"
    S5_STUB_CFG=$S5_CFG
    export PATH S5_STUB_CFG
    s5_asset_select
}

t_xray_assert_healthy() {
    t_run s5_state_load
    assert_eq "the installed fixture passes real state validation before mutation" 0 "$T_STATUS"
    # Never proceed to a corruption test on an invalid baseline.
    [ "$T_STATUS" -eq 0 ] || t_summary
}

t_xray_install() {
    # A completed install is a previous invocation, not this command's lifecycle
    # flags. Keep its filesystem effects but not its shell state.
    ( s5_install_new )
    _txi_status=$?
    assert_eq "fixture installation completes" 0 "$_txi_status"
    [ "$_txi_status" -eq 0 ] || t_summary
    t_xray_assert_healthy
}
