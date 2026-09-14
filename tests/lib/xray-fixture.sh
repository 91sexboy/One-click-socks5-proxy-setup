#!/bin/sh
# A non-privileged installed-Xray fixture. External account/service commands,
# engine/config-test outcomes and interactive inputs are controlled; state loading,
# artifact verification, account identity and lifecycle code stay real.

S5T_FIXTURE_PATH=$PATH

t_legacy_fixture() {
    mkdir -p "$S5_TEST_ROOT/etc/socks5-manager" "$S5_TEST_ROOT/var/lib/socks5-manager" "$S5_TEST_ROOT/usr/local/libexec/socks5-manager"
    printf 'legacy config\n' >"$S5_TEST_ROOT/etc/socks5-manager/3proxy.cfg"
    printf 'legacy state\n' >"$S5_TEST_ROOT/var/lib/socks5-manager/state"
    printf 'legacy binary\n' >"$S5_TEST_ROOT/usr/local/libexec/socks5-manager/3proxy"
}

# Fixture pins describe independent source bytes, never the installed executable.
t_use_asset_fixture() {
    S5T_ASSET_BINARY=$1
    S5T_ASSET_SOURCE=${2:-binary}
    S5T_SIZE_OVERRIDE=''
    S5T_SHA_OVERRIDE=''
    S5T_BIN_SIZE=$(wc -c <"$S5T_ASSET_BINARY" | tr -d '[:space:]')
    S5T_BIN_SHA256=$(t_sha256 "$S5T_ASSET_BINARY")
    s5_asset_select() {
        [ "$S5_ARCHNAME" = amd64 ] || return 1
        _tsas_archive=$S5T_ASSET_BINARY
        if [ "$S5T_ASSET_SOURCE" = archive ]; then _tsas_archive=$S5_TEST_ASSET_PATH; fi
        S5_ASSET_NAME=Xray-linux-64.zip
        S5_ASSET_SIZE=${S5T_SIZE_OVERRIDE:-$(wc -c <"$_tsas_archive" | tr -d '[:space:]')}
        S5_ASSET_SHA256=${S5T_SHA_OVERRIDE:-$(t_sha256 "$_tsas_archive")}
        S5_ASSET_BINARY_SIZE=$S5T_BIN_SIZE
        S5_ASSET_BINARY_SHA256=$S5T_BIN_SHA256
    }
}

t_xray_fixture() {
    # One authoritative initialization boundary: reload production defaults and
    # functions, not a copied list of lifecycle flags. Each scenario gets fresh
    # disk state too. Command-local fault doubles belong inside a subshell.
    t_cleanup_root
    t_mktestroot
    PATH=$S5T_FIXTURE_PATH
    unset S5_LISTENER_PROBE S5_PROTOCOL_VERIFY
    t_source_production "$S5_REPO_ROOT/tests/fixtures/os-release/debian-12"
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

    t_use_asset_fixture "$S5_TEST_ROOT/asset-xray"
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
    t_stub systemctl <<'SYSTEMCTL'
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
    t_stub rc-service <<'RCSERVICE'
#!/bin/sh
case "$2" in
stop) rm -f "$S5_TEST_ROOT/svc_active" ;;
status) if [ -f "$S5_TEST_ROOT/svc_active" ]; then exit 0; else exit 3; fi ;;
esac
exit 0
RCSERVICE
    for _acct_cmd in getent groupadd groupdel useradd userdel addgroup delgroup adduser deluser id; do
        t_stub "$_acct_cmd" <<'ACCT'
#!/bin/sh
case "${0##*/}" in
groupadd|groupdel|useradd|userdel|addgroup|delgroup|adduser|deluser)
    printf '%s' "${0##*/}" >>"$S5_TEST_ROOT/account-transcript"
    for argument do printf ' %s' "$argument" >>"$S5_TEST_ROOT/account-transcript"; done
    printf '\n' >>"$S5_TEST_ROOT/account-transcript"
    ;;
esac
case "${0##*/}" in
getent)
    case "$1" in
    passwd) test -f "$S5_TEST_ROOT/user-exists" || exit 2
        printf 'xray-socks5:x:900:900::/nonexistent:/usr/sbin/nologin\n' ;;
    group) test -f "$S5_TEST_ROOT/group-exists" || exit 2
        printf 'xray-socks5:x:%s:\n' "$(cat "$S5_TEST_ROOT/group-exists")" ;;
    *) exit 2 ;;
    esac ;;
groupadd|addgroup) printf '900\n' >"$S5_TEST_ROOT/group-exists" ;;
useradd|adduser)
    [ ! -f "$S5_TEST_ROOT/fail-useradd" ] || exit 1
    printf '900\n' >"$S5_TEST_ROOT/user-exists" ;;
groupdel|delgroup)
    [ ! -f "$S5_TEST_ROOT/fail-groupdel" ] || exit 1
    rm -f "$S5_TEST_ROOT/group-exists" ;;
userdel|deluser) rm -f "$S5_TEST_ROOT/user-exists" ;;
id)
    test -f "$S5_TEST_ROOT/user-exists" || exit 1
    case "$1" in
    -u) cat "$S5_TEST_ROOT/user-exists" ;;
    -g) cat "$S5_TEST_ROOT/group-exists" ;;
    *) exit 1 ;;
    esac ;;
esac
ACCT
    done
    # Some BusyBox shells prefer their built-in id applet over PATH. Route the
    # external account command explicitly, without replacing account validation.
    id() { "$S5_TEST_ROOT/bin/id" "$@"; }
    addgroup() { "$S5_TEST_ROOT/bin/addgroup" "$@"; }
    adduser() { "$S5_TEST_ROOT/bin/adduser" "$@"; }
    delgroup() { "$S5_TEST_ROOT/bin/delgroup" "$@"; }
    deluser() { "$S5_TEST_ROOT/bin/deluser" "$@"; }
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
