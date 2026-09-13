#!/bin/sh
# Xray installer and state validation with isolated lifecycle scenarios.

S5T_NAME=test_xray_install
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
. "${S5_REPO_ROOT}/tests/lib/xray-fixture.sh"

test_install() {
    t_xray_fixture 23456
    t_xray_install
    assert_file_exists "Xray config exists" "$S5_CFG"
    assert_file_exists "Xray state exists" "$S5_STATE"
    assert_file_exists "Xray unit exists" "$S5_SERVICE_ARTIFACT"
    assert_eq "state engine marker" xray "$(s5_state_get engine)"
    assert_eq "state protocol marker" mixed "$(s5_state_get protocol)"
    assert_eq "service command recorded" 1 "$(grep -c 'start xray-socks5.service' "$S5_TEST_ROOT/transcript")"
    assert_eq "install enables the unit on boot" 1 "$(grep -c 'enable xray-socks5.service' "$S5_TEST_ROOT/transcript")"
    assert_contains "config test ran before service start" 'config-test' "$(cat "$S5_TEST_ROOT/xray-calls")"
    assert_not_contains "password is absent from state" "$S5_PASSWORD" "$(cat "$S5_STATE")"
    assert_mode "config is group-readable only" 640 "$S5_CFG"
    assert_mode "state is private" 600 "$S5_STATE"

    # Old namespace remains untouched.
    mkdir -p "$S5_TEST_ROOT/etc/socks5-manager"
    printf legacy >"$S5_TEST_ROOT/etc/socks5-manager/3proxy.cfg"
    assert_file_exists "legacy namespace remains present" "$S5_TEST_ROOT/etc/socks5-manager/3proxy.cfg"
    unit=$(cat "$S5_SERVICE_ARTIFACT")
    assert_not_contains "unit does not expose password" "$S5_PASSWORD" "$unit"
    assert_contains "unit runs Xray" 'run -c' "$unit"
}

test_config_corrupt() {
    t_xray_fixture 23456
    t_xray_install
    # This return-2 assertion was already valid with the old binary metadata:
    # config verification precedes binary verification. The healthy baseline now
    # proves that changing the config is the only reason validation fails.
    printf 'external change\n' >"$S5_CFG"
    t_run s5_state_load
    assert_eq "an externally changed config has its own status" 2 "$T_STATUS"
    t_run s5_report_state_load 2
    assert_contains "the diagnosis names the config, not the state" \
        'changed externally' "$T_OUT"
    assert_not_contains "the diagnosis does not call the state invalid" \
        'invalid state file' "$T_OUT"
}

test_binary_corrupt() {
    t_xray_fixture 23456
    t_xray_install
    printf '# changed executable\n' >>"$S5_BIN"
    t_run s5_state_load
    assert_eq "a changed binary is invalid state, not config drift" 1 "$T_STATUS"
}

test_unit_corrupt() {
    t_xray_fixture 23456
    t_xray_install
    printf '# changed unit\n' >>"$S5_SERVICE_ARTIFACT"
    t_run s5_state_load
    assert_eq "a changed service unit is invalid state" 1 "$T_STATUS"
}

test_account_corrupt() {
    t_xray_fixture 23456
    t_xray_install
    printf '901\n' >"$S5_TEST_ROOT/user-exists"
    t_run s5_state_load
    assert_eq "a changed account identity is invalid state" 1 "$T_STATUS"
}

test_cleanup_temps() {
    t_xray_fixture 23456
    t_xray_install
    # An interrupted atomic write leaves private temporaries behind. This command
    # owns none of the published files from the previous installation process.
    : >"$S5_SYSCONFDIR/.s5tmp.abc123"
    : >"$S5_STATEDIR/.s5state.xyz789"
    : >"$S5_PREFIX/.xray.qqq111"
    s5_cleanup
    assert_file_absent "cleanup removes its own config temporary" "$S5_SYSCONFDIR/.s5tmp.abc123"
    assert_file_absent "cleanup removes its own state temporary" "$S5_STATEDIR/.s5state.xyz789"
    assert_file_absent "cleanup removes its own binary temporary" "$S5_PREFIX/.xray.qqq111"
    assert_file_exists "cleanup leaves the published config alone" "$S5_CFG"
    t_xray_assert_healthy

    # A matching dotfile in the caller's cwd must not expand the cleanup pattern
    # before it reaches the directory being cleaned.
    : >"$S5_SYSCONFDIR/.s5tmp.cwdcase"
    mkdir -p "$S5_TEST_ROOT/decoycwd"
    : >"$S5_TEST_ROOT/decoycwd/.s5tmp.decoy"
    ( cd "$S5_TEST_ROOT/decoycwd" && s5_cleanup_own_temps "$S5_SYSCONFDIR" )
    assert_file_absent "cleanup ignores a matching name in the caller's cwd" "$S5_SYSCONFDIR/.s5tmp.cwdcase"
}

test_openrc_runtime() {
    t_xray_fixture 23456
    # supervise-daemon runtime files belong to the running service until this
    # invocation actually touches it (e.g. declining an update must preserve them).
    S5_INIT=openrc
    mkdir -p "$S5_OPENRC_OPTION_DIR" "$(dirname "$S5_PIDFILE")"
    : >"$S5_PIDFILE"
    : >"$S5_OPENRC_OPTION_DIR/child_pid"
    s5_cleanup
    assert_file_exists "cleanup keeps a foreign OpenRC pidfile" "$S5_PIDFILE"
    assert_file_exists "cleanup keeps a foreign child_pid" "$S5_OPENRC_OPTION_DIR/child_pid"
    S5_SERVICE_STARTED=1
    s5_cleanup
    assert_file_absent "cleanup removes the runtime files it owns" "$S5_PIDFILE"
}

test_locks() {
    t_xray_fixture 23456
    _lkboot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || uname -n)
    # Call directly: t_run's command substitution would lose S5_LOCK_HELD.
    s5_lock_acquire
    assert_eq "the lock is acquired when free" 0 "$?"
    s5_lock_acquire
    assert_eq "acquiring a lock this process holds is a no-op" 0 "$?"
    s5_lock_release
    assert_file_absent "releasing removes the lock directory" "${S5_LOCKDIR:?}"

    mkdir -p "$S5_LOCKDIR"
    printf '%s\n%s\n' "$_lkboot" "$$" >"$S5_LOCK_OWNER"
    s5_lock_acquire 2>/dev/null
    assert_ne "a lock held by a live owner is refused" 0 "$?"
    assert_file_exists "a live owner's lock is left in place" "$S5_LOCK_OWNER"

    (exit 0) &
    _lkdead=$!
    wait "$_lkdead" 2>/dev/null || true
    printf '%s\n%s\n' "$_lkboot" "$_lkdead" >"$S5_LOCK_OWNER"
    s5_lock_acquire 2>/dev/null
    assert_eq "a lock left by a dead owner is reclaimed" 0 "$?"
    s5_lock_release

    mkdir -p "$S5_LOCKDIR"
    printf '%s\n%s\n' "boot-from-a-previous-life" "$$" >"$S5_LOCK_OWNER"
    s5_lock_acquire 2>/dev/null
    assert_eq "a lock from a previous boot is reclaimed" 0 "$?"
    s5_lock_release
    assert_file_absent "the reclaimed lock is released cleanly" "$S5_LOCKDIR"
}

t_download_fixture() {
    t_xray_fixture 23456 real-download
    python3 - "$S5_TEST_ROOT" <<'PY'
from pathlib import Path
import struct
import sys
import zipfile

root = Path(sys.argv[1])
binary = bytearray(64)
binary[:7] = b'\x7fELF\x02\x01\x01'
struct.pack_into('<HHI', binary, 16, 2, 0x3E, 1)
struct.pack_into('<H', binary, 52, 64)
(root / 'asset-xray').write_bytes(binary)
with zipfile.ZipFile(root / 'asset.zip', 'w') as archive:
    for name in ('xray', 'geoip.dat', 'geosite.dat', 'LICENSE', 'README.md'):
        info = zipfile.ZipInfo(name)
        info.external_attr = (0o100755 if name == 'xray' else 0o100644) << 16
        archive.writestr(info, binary if name == 'xray' else b'synthetic\n')
PY
    S5_TEST_ASSET_PATH=$S5_TEST_ROOT/asset.zip
    export S5_TEST_ASSET_PATH
    s5_asset_select() {
        S5_ASSET_NAME=Xray-linux-64.zip
        S5_ASSET_SIZE=$(wc -c <"$S5_TEST_ASSET_PATH" | tr -d '[:space:]')
        S5_ASSET_SHA256=$(sha256sum "$S5_TEST_ASSET_PATH" | awk '{print $1}')
        S5_ASSET_BINARY_SIZE=$(wc -c <"$S5_TEST_ROOT/asset-xray" | tr -d '[:space:]')
        S5_ASSET_BINARY_SHA256=$(sha256sum "$S5_TEST_ROOT/asset-xray" | awk '{print $1}')
    }
    s5_asset_select
    s5_precheck() { return 0; }
    s5_tmp_base() { printf '%s\n' "$S5_TEST_ROOT"; }
    mkdir -p "$S5_TEST_ROOT/unrelated/transaction" "$S5_TEST_ROOT/xray-socks5-download.foreign"
    printf 'recovery evidence\n' >"$S5_TEST_ROOT/unrelated/transaction/old.config.json"
    printf 'foreign download\n' >"$S5_TEST_ROOT/xray-socks5-download.foreign/asset.zip"
}

t_download_run() {
    _tdfault=${1:-none}
    if [ "$_tdfault" = remove-zh ]; then S5_LANG=zh; fi
    case "$_tdfault" in
    candidate|candidate-remove) printf '23\n' >"$S5_TEST_ROOT/cfgtest" ;;
    esac
    mktemp() {
        _tdtemp=$(command mktemp "$@") || return 1
        case "$_tdtemp" in
        */xray-socks5-download.*) printf '%s\n' "$_tdtemp" >"$S5_TEST_ROOT/download.path" ;;
        esac
        printf '%s\n' "$_tdtemp"
    }
    rm() {
        if [ "${1:-}" = -rf ] && [ -n "$S5_WORKDIR" ] && [ "${2:-}" = "$S5_WORKDIR" ]; then
            if [ "$S5_LOCK_HELD" = 1 ] &&
                [ "$(cat "$S5_LOCK_OWNER" 2>/dev/null)" = "$S5_LOCK_TOKEN" ]; then
                printf 'owned\n' >>"$S5_TEST_ROOT/download.cleanup"
            else
                printf 'unowned\n' >>"$S5_TEST_ROOT/download.cleanup"
            fi
            if [ -f "$S5_WORKDIR/Xray-linux-64.zip" ] && [ -f "$S5_WORKDIR/members" ] &&
                [ -f "$S5_WORKDIR/xray" ]; then
                printf 'verified scratch exists\n' >>"$S5_TEST_ROOT/download.cleanup"
            fi
            case "$_tdfault" in remove|remove-zh|candidate-remove) return 1 ;; esac
        fi
        command rm "$@"
    }
    rmdir() {
        if [ "$_tdfault" = release ] && [ "${1:-}" = "$S5_LOCKDIR" ]; then
            printf 'release failed\n' >>"$S5_TEST_ROOT/download.release"
            return 1
        fi
        command rmdir "$@"
    }
    chmod() {
        if [ "$_tdfault" = signal ] && [ "${1:-}:${2:-}" = "0750:$S5_SYSCONFDIR" ]; then
            # getppid addresses this test invocation, unlike POSIX subshell $$.
            python3 -c 'import os, signal; os.kill(os.getppid(), signal.SIGTERM)'
            return 1
        fi
        command chmod "$@"
    }
    s5_cmd_install
    _tdstatus=$?
    printf '%s\n' "$S5_WORKDIR" >"$S5_TEST_ROOT/download.retained"
    return "$_tdstatus"
}

test_download_cleanup() {
    t_download_fixture
    if ! unzip -Z1 "$S5_TEST_ASSET_PATH" >/dev/null 2>&1; then
        t_skip "command-level download cleanup" "requires Info-ZIP unzip with -Z"
        return
    fi
    t_run t_download_run
    assert_eq "command-level installation with verified archive succeeds" 0 "$T_STATUS"
    _tdpath=$(cat "$S5_TEST_ROOT/download.path")
    assert_file_absent "successful install removes its downloaded archive" "$_tdpath/Xray-linux-64.zip"
    assert_file_absent "successful install removes its extracted temporary binary" "$_tdpath/xray"
    assert_file_absent "successful install removes its member list and workdir" "$_tdpath"
    assert_eq "successful cleanup clears its workdir reference" '' "$(cat "$S5_TEST_ROOT/download.retained")"
    assert_contains "download cleanup runs while the command owns its lock" owned \
        "$(cat "$S5_TEST_ROOT/download.cleanup" 2>/dev/null)"
    assert_not_contains "download cleanup never runs after unlocking" unowned \
        "$(cat "$S5_TEST_ROOT/download.cleanup" 2>/dev/null)"
    assert_contains "the command really downloaded and extracted scratch files" 'verified scratch exists' \
        "$(cat "$S5_TEST_ROOT/download.cleanup" 2>/dev/null)"
    assert_file_exists "successful cleanup preserves the installed binary" "$S5_BIN"
    assert_file_exists "successful cleanup preserves config" "$S5_CFG"
    assert_file_exists "successful cleanup preserves state" "$S5_STATE"
    assert_file_absent "successful cleanup releases the operation lock" "$S5_LOCKDIR"
    assert_file_exists "cleanup preserves a different download directory" "$S5_TEST_ROOT/xray-socks5-download.foreign/asset.zip"
    assert_file_exists "cleanup preserves unrelated recovery evidence" "$S5_TEST_ROOT/unrelated/transaction/old.config.json"
    assert_not_contains "command output contains no password" "$S5_PASSWORD" "$T_OUT"
    t_xray_assert_healthy
    t_run t_download_run
    assert_eq "configuration update without a download workdir still succeeds" 0 "$T_STATUS"
    assert_eq "configuration update keeps the workdir reference empty" '' "$(cat "$S5_TEST_ROOT/download.retained")"
    assert_file_exists "configuration update leaves the foreign download alone" "$S5_TEST_ROOT/xray-socks5-download.foreign/asset.zip"
    t_xray_assert_healthy
}

t_download_fault_case() {
    _tdcase=$1
    t_download_fixture
    if ! unzip -Z1 "$S5_TEST_ASSET_PATH" >/dev/null 2>&1; then
        t_skip "command-level download $_tdcase" "requires Info-ZIP unzip with -Z"
        return
    fi
    t_run t_download_run "$_tdcase"
    case "$_tdcase" in
    signal) assert_eq "download-stage signal propagates its signal status" 143 "$T_STATUS" ;;
    *) assert_eq "$_tdcase failure remains nonzero" 1 "$T_STATUS" ;;
    esac
    _tdpath=$(cat "$S5_TEST_ROOT/download.path")
    assert_contains "$_tdcase cleanup reaches the command's owned lock" owned \
        "$(cat "$S5_TEST_ROOT/download.cleanup" 2>/dev/null)"
    assert_not_contains "$_tdcase never cleans the download after unlocking" unowned \
        "$(cat "$S5_TEST_ROOT/download.cleanup" 2>/dev/null)"
    case "$_tdcase" in
    remove|remove-zh|candidate-remove)
        assert_dir_exists "$_tdcase retains the workdir on deletion failure" "$_tdpath"
        assert_eq "$_tdcase retains the failed cleanup path" "$_tdpath" "$(cat "$S5_TEST_ROOT/download.retained")"
        case "$_tdcase" in
        remove-zh) _tddiagnostic='无法删除下载临时目录' ;;
        *) _tddiagnostic='could not remove temporary download directory' ;;
        esac
        assert_contains "$_tdcase reports cleanup failure in the selected language" "$_tddiagnostic" "$T_OUT"
        assert_contains "$_tdcase identifies only its owned cleanup path" "$_tdpath" "$T_OUT"
        ;;
    *) assert_file_absent "$_tdcase removes the owned download workdir" "$_tdpath" ;;
    esac
    case "$_tdcase" in
    release)
        assert_dir_exists "failed lock release remains observable" "$S5_LOCKDIR"
        assert_contains "the lock release failure was reached" 'release failed' "$(cat "$S5_TEST_ROOT/download.release")"
        ;;
    *) assert_file_absent "$_tdcase releases its operation lock" "$S5_LOCKDIR" ;;
    esac
    assert_eq "$_tdcase preserves a different download's bytes" 'foreign download' \
        "$(cat "$S5_TEST_ROOT/xray-socks5-download.foreign/asset.zip")"
    assert_eq "$_tdcase preserves unrelated recovery evidence" 'recovery evidence' \
        "$(cat "$S5_TEST_ROOT/unrelated/transaction/old.config.json")"
    assert_not_contains "$_tdcase never announces English installation success" 'installation completed' "$T_OUT"
    assert_not_contains "$_tdcase never announces Chinese installation success" '安装完成' "$T_OUT"
    assert_not_contains "$_tdcase output contains no password" "$S5_PASSWORD" "$T_OUT"
    case "$_tdcase" in
    candidate|candidate-remove|signal)
        assert_file_absent "$_tdcase removes the failed new-install binary" "$S5_BIN"
        assert_file_absent "$_tdcase does not leave an installed state" "$S5_STATE"
        ;;
    *)
        assert_eq "$_tdcase leaves the healthy listener running" 23456 "$(cat "$S5_TEST_ROOT/svc_active")"
        assert_eq "$_tdcase never stops the healthy installation" 0 \
            "$(grep -c 'systemctl stop ' "$S5_TEST_ROOT/transcript")"
        t_xray_assert_healthy
        ;;
    esac
}

test_download_remove_failure() { t_download_fault_case remove; }
test_download_remove_zh() { t_download_fault_case remove-zh; }
test_download_release_failure() { t_download_fault_case release; }
test_download_candidate_failure() { t_download_fault_case candidate; }
test_download_candidate_remove_failure() { t_download_fault_case candidate-remove; }
test_download_signal() { t_download_fault_case signal; }

# Optional scenario arguments support isolated runs, permutation and repetition.
if [ "$#" -eq 0 ]; then
    set -- install config_corrupt binary_corrupt unit_corrupt account_corrupt cleanup_temps openrc_runtime locks download_cleanup download_remove_failure download_remove_zh download_release_failure download_candidate_failure download_candidate_remove_failure download_signal
fi
for scenario do
    case "$scenario" in
    install|config_corrupt|binary_corrupt|unit_corrupt|account_corrupt|cleanup_temps|openrc_runtime|locks|download_cleanup|download_remove_failure|download_remove_zh|download_release_failure|download_candidate_failure|download_candidate_remove_failure|download_signal)
        "test_$scenario" ;;
    *) t_bad "unknown install scenario: $scenario" ;;
    esac
done
t_summary
