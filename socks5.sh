#!/bin/sh
# socks5.sh - one-click SOCKS5 proxy installer and manager.
#
# Engine: 3proxy 0.9.9.0, built from a pinned upstream commit.
# Protocol scope: SOCKS5 only, RFC 1929 username/password auth, CONNECT only.
# SOCKS4 / SOCKS4a / SOCKS4.5, unauthenticated SOCKS5, BIND and UDP ASSOCIATE are all rejected.
#
# SPEC.md is the authority for every decision in this file.
# POSIX sh only: must run under dash, busybox ash and bash.

# Secrets are written to disk before their final mode is applied, so the
# process umask is set here and never inherited from the caller.
umask 077

# Never trace: an inherited `sh -x` would echo the credential.
set +x
set -u

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

S5_PROJECT=socks5-manager
S5_SERVICE_USER=socks5proxy
S5_SERVICE_GROUP=socks5proxy
S5_PINNED_COMMIT=da99424eac4092e3722f1a5b1844cfe80478f580
S5_UPSTREAM_TAG=0.9.9.0
S5_REPO_URL=https://github.com/3proxy/3proxy
S5_ENGINE_RELEASE=engine-3proxy-0.9.9.0-r2
S5_ENGINE_BASE_URL=https://github.com/91sexboy/One-click-socks5-proxy-setup/releases/download/$S5_ENGINE_RELEASE
S5_ASSET_GLIBC_AMD64=3proxy-0.9.9.0-da99424-linux-glibc-amd64
S5_ASSET_GLIBC_AMD64_SHA=9c2892b46121439f3c5a05fc19ec07fe68d2ce3498110cac29c165749efaafcf
S5_ASSET_GLIBC_AMD64_SIZE=294552
S5_ASSET_GLIBC_ARM64=3proxy-0.9.9.0-da99424-linux-glibc-arm64
S5_ASSET_GLIBC_ARM64_SHA=344e482272e5c16d1f9c762d7ed240cda43bb050a53be767e5393a616607ccf5
S5_ASSET_GLIBC_ARM64_SIZE=279288
S5_ASSET_MUSL_AMD64=3proxy-0.9.9.0-da99424-linux-musl-amd64
S5_ASSET_MUSL_AMD64_SHA=ac3fe1a7d52d2b1494d4d00884fc7517acb2340454c2653c95a7346c05d69298
S5_ASSET_MUSL_AMD64_SIZE=298280
S5_ASSET_MUSL_ARM64=3proxy-0.9.9.0-da99424-linux-musl-arm64
S5_ASSET_MUSL_ARM64_SHA=38f2733dfc5d375a4faaebe79f66bd181c7cc3e7b3eb9443c3ac4476fbfeebeb
S5_ASSET_MUSL_ARM64_SIZE=277624
S5_ASSET_NAME=''
S5_ASSET_SHA256=''
S5_ASSET_SIZE=''
# Fixed by decision: the self-test target is not configurable.
S5_SELFTEST_URL=https://example.com/

S5_PORT_MIN=1024
S5_PORT_MAX=65535
S5_RANDPORT_MIN=20000
S5_RANDPORT_MAX=60000
S5_PASS_GEN_LEN=32
S5_PASS_MIN=12
S5_PASS_MAX=128
S5_USER_MIN=3
S5_USER_MAX=32

# curl's CURLE_PROXY. The only exit status that proves a SOCKS handshake was
# refused by the proxy rather than failing for an unrelated reason.
S5_CURL_PROXY_ERR=97
# curl before CURLE_PROXY existed reports an explicit SOCKS5 credential rejection
# as CURLE_COULDNT_CONNECT, while emitting a protocol-specific libcurl error.
S5_CURL_LEGACY_PROXY_ERR=7
S5_CURL_LEGACY_AUTH_TEXT='User was rejected by the SOCKS5 server'
# curl's CURLE_HTTP_RETURNED_ERROR, emitted only when --fail is active.
S5_CURL_HTTP_ERR=22

# Exit codes
EX_OK=0
EX_FAIL=1
EX_UNSUPPORTED=4
EX_USAGE=64

# ---------------------------------------------------------------------------
# Test-mode isolation guard  (runs before anything else touches the filesystem)
#
#   * Coverage/override variables take effect ONLY when S5_TEST_MODE=1.
#   * Test mode requires S5_TEST_ROOT plus a verified .s5-test-root sentinel.
#   * Production mode exits immediately if any coverage variable is present.
#
# No eval anywhere: each variable is checked by name explicitly.
# ---------------------------------------------------------------------------

s5_found_overrides=''

s5_note_override() {
    if [ -n "$2" ]; then
        s5_found_overrides="$s5_found_overrides $1"
    fi
}

# Test-mode paths must remain beneath the sentinel root. The lexical checks reject
# parent traversal, and the component walk rejects an existing symlink anywhere
# between the root and the requested path. This is deliberately checked before
# any path override is assigned or used.
s5_test_root_ok() {
    _tro=$1
    case "$_tro" in
    *'//'*) return 1 ;;
    *'/../'* | */.. | ../* | ..) return 1 ;;
    esac
    _tp=$_tro
    while :; do
        if [ -L "$_tp" ]; then
            return 1
        fi
        [ "$_tp" = "/" ] && break
        case "$_tp" in
        */*) _tp=${_tp%/*} ;;
        *) _tp=/ ;;
        esac
        [ -n "$_tp" ] || _tp=/
    done
    return 0
}

s5_test_path_ok() {
    _tpo=$1
    case "$_tpo" in
    "$S5_TEST_ROOT" | "$S5_TEST_ROOT"/*) ;;
    *) return 1 ;;
    esac
    case "$_tpo" in
    *'/../'* | */.. | ../* | ..) return 1 ;;
    esac
    _tp=$_tpo
    while [ "$_tp" != "$S5_TEST_ROOT" ]; do
        if [ -L "$_tp" ]; then
            return 1
        fi
        case "$_tp" in
        "$S5_TEST_ROOT"/*) _tp=${_tp%/*} ;;
        *) return 1 ;;
        esac
        [ -n "$_tp" ] || _tp=/
    done
    return 0
}

s5_guard_environment() {
    _s5_tm=${S5_TEST_MODE:-0}

    if [ "$_s5_tm" = "1" ]; then
        if [ -z "${S5_TEST_ROOT:-}" ]; then
            printf '%s: S5_TEST_MODE=1 requires S5_TEST_ROOT to be set\n' "$0" >&2
            printf '%s: S5_TEST_MODE=1 需要设置 S5_TEST_ROOT\n' "$0" >&2
            exit 2
        fi
        case "$S5_TEST_ROOT" in
        /*) ;;
        *)
            printf '%s: S5_TEST_ROOT must be an absolute path\n' "$0" >&2
            printf '%s: S5_TEST_ROOT 必须是绝对路径\n' "$0" >&2
            exit 2
            ;;
        esac
        if ! s5_test_root_ok "$S5_TEST_ROOT"; then
            printf '%s: refusing to run: unsafe S5_TEST_ROOT path: %s\n' "$0" \
                "$S5_TEST_ROOT" >&2
            printf '%s: 拒绝运行：S5_TEST_ROOT 路径不安全：%s\n' "$0" \
                "$S5_TEST_ROOT" >&2
            exit 2
        fi
        if [ -L "$S5_TEST_ROOT" ]; then
            printf '%s: refusing to run: S5_TEST_ROOT must not be a symbolic link: %s\n' \
                "$0" "$S5_TEST_ROOT" >&2
            printf '%s: 拒绝运行：S5_TEST_ROOT 不能是符号链接：%s\n' \
                "$0" "$S5_TEST_ROOT" >&2
            exit 2
        fi
        if [ ! -d "$S5_TEST_ROOT" ]; then
            printf '%s: S5_TEST_ROOT is not a directory: %s\n' "$0" "$S5_TEST_ROOT" >&2
            printf '%s: S5_TEST_ROOT 不是目录：%s\n' "$0" "$S5_TEST_ROOT" >&2
            exit 2
        fi
        if [ ! -f "$S5_TEST_ROOT/.s5-test-root" ]; then
            printf '%s: refusing to run: sentinel .s5-test-root not found in %s\n' \
                "$0" "$S5_TEST_ROOT" >&2
            printf '%s: 拒绝运行：在 %s 中找不到哨兵文件 .s5-test-root\n' \
                "$0" "$S5_TEST_ROOT" >&2
            exit 2
        fi
        if [ -n "${S5_PREFIX:-}" ] && ! s5_test_path_ok "$S5_PREFIX"; then
            printf '%s: refusing to run: S5_PREFIX escapes S5_TEST_ROOT\n' "$0" >&2
            printf '%s: 拒绝运行：S5_PREFIX 超出了 S5_TEST_ROOT 范围\n' "$0" >&2
            exit 2
        fi
        if [ -n "${S5_SYSCONFDIR:-}" ] && ! s5_test_path_ok "$S5_SYSCONFDIR"; then
            printf '%s: refusing to run: S5_SYSCONFDIR escapes S5_TEST_ROOT\n' "$0" >&2
            printf '%s: 拒绝运行：S5_SYSCONFDIR 超出了 S5_TEST_ROOT 范围\n' "$0" >&2
            exit 2
        fi
        if [ -n "${S5_STATEDIR:-}" ] && ! s5_test_path_ok "$S5_STATEDIR"; then
            printf '%s: refusing to run: S5_STATEDIR escapes S5_TEST_ROOT\n' "$0" >&2
            printf '%s: 拒绝运行：S5_STATEDIR 超出了 S5_TEST_ROOT 范围\n' "$0" >&2
            exit 2
        fi
        if [ -n "${S5_UNITDIR:-}" ] && ! s5_test_path_ok "$S5_UNITDIR"; then
            printf '%s: refusing to run: S5_UNITDIR escapes S5_TEST_ROOT\n' "$0" >&2
            printf '%s: 拒绝运行：S5_UNITDIR 超出了 S5_TEST_ROOT 范围\n' "$0" >&2
            exit 2
        fi
        if [ -n "${S5_INITDIR:-}" ] && ! s5_test_path_ok "$S5_INITDIR"; then
            printf '%s: refusing to run: S5_INITDIR escapes S5_TEST_ROOT\n' "$0" >&2
            printf '%s: 拒绝运行：S5_INITDIR 超出了 S5_TEST_ROOT 范围\n' "$0" >&2
            exit 2
        fi
        if [ -n "${S5_BUILD_DIR:-}" ] && ! s5_test_path_ok "$S5_BUILD_DIR"; then
            printf '%s: refusing to run: S5_BUILD_DIR escapes S5_TEST_ROOT\n' "$0" >&2
            printf '%s: 拒绝运行：S5_BUILD_DIR 超出了 S5_TEST_ROOT 范围\n' "$0" >&2
            exit 2
        fi
        # S5_LOGSINK and S5_TMPMODE_LOG are files this script WRITES. Unlike
        # S5_OSRELEASE and S5_PORT_PROBE -- inputs the harness itself chooses,
        # which stay unconfined -- a write path that escapes the sentinel root
        # would let a misconfigured test drop redacted diagnostics or mode
        # observations anywhere on the host filesystem.
        if [ -n "${S5_LOGSINK:-}" ] && ! s5_test_path_ok "$S5_LOGSINK"; then
            printf '%s: refusing to run: S5_LOGSINK escapes S5_TEST_ROOT\n' "$0" >&2
            printf '%s: 拒绝运行：S5_LOGSINK 超出了 S5_TEST_ROOT 范围\n' "$0" >&2
            exit 2
        fi
        if [ -n "${S5_TMPMODE_LOG:-}" ] && ! s5_test_path_ok "$S5_TMPMODE_LOG"; then
            printf '%s: refusing to run: S5_TMPMODE_LOG escapes S5_TEST_ROOT\n' "$0" >&2
            printf '%s: 拒绝运行：S5_TMPMODE_LOG 超出了 S5_TEST_ROOT 范围\n' "$0" >&2
            exit 2
        fi
        return 0
    fi

    if [ "$_s5_tm" != "0" ]; then
        printf '%s: refusing to run: test-mode variable S5_TEST_MODE has invalid value "%s"\n' \
            "$0" "$_s5_tm" >&2
        printf '%s: 拒绝运行：测试模式变量 S5_TEST_MODE 的值无效："%s"\n' \
            "$0" "$_s5_tm" >&2
        exit 2
    fi

    s5_note_override S5_TEST_ROOT "${S5_TEST_ROOT:-}"
    s5_note_override S5_LIB_ONLY "${S5_LIB_ONLY:-}"
    s5_note_override S5_PREFIX "${S5_PREFIX:-}"
    s5_note_override S5_SYSCONFDIR "${S5_SYSCONFDIR:-}"
    s5_note_override S5_STATEDIR "${S5_STATEDIR:-}"
    s5_note_override S5_UNITDIR "${S5_UNITDIR:-}"
    s5_note_override S5_INITDIR "${S5_INITDIR:-}"
    s5_note_override S5_OSRELEASE "${S5_OSRELEASE:-}"
    s5_note_override S5_PORT_PROBE "${S5_PORT_PROBE:-}"
    s5_note_override S5_ASSUME_ROOT "${S5_ASSUME_ROOT:-}"
    s5_note_override S5_SKIP_OWNERSHIP "${S5_SKIP_OWNERSHIP:-}"
    s5_note_override S5_BUILD_DIR "${S5_BUILD_DIR:-}"
    s5_note_override S5_LOGSINK "${S5_LOGSINK:-}"
    s5_note_override S5_LISTEN "${S5_LISTEN:-}"
    s5_note_override S5_TMPMODE_LOG "${S5_TMPMODE_LOG:-}"
    s5_note_override S5_TEST_ASSET_SHA256 "${S5_TEST_ASSET_SHA256:-}"
    s5_note_override S5_TEST_ASSET_SIZE "${S5_TEST_ASSET_SIZE:-}"
    s5_note_override S5_PROC_NET_TCP "${S5_PROC_NET_TCP:-}"
    s5_note_override S5_PROC_NET_TCP6 "${S5_PROC_NET_TCP6:-}"

    if [ -n "$s5_found_overrides" ]; then
        printf '%s: refusing to run: test-mode variable(s) set outside test mode:%s\n' \
            "$0" "$s5_found_overrides" >&2
        printf '%s: 拒绝运行：在测试模式之外设置了测试模式变量：%s\n' \
            "$0" "$s5_found_overrides" >&2
        printf '%s: unset them, or set S5_TEST_MODE=1 with a valid S5_TEST_ROOT\n' "$0" >&2
        printf '%s: 请清除它们，或设置 S5_TEST_MODE=1 并提供有效的 S5_TEST_ROOT\n' "$0" >&2
        exit 2
    fi
    return 0
}

s5_guard_environment

# ---------------------------------------------------------------------------
# How the operator re-invokes this script. The documented one-click form is
#   bash <(wget -qO- <RAW_URL>)
# under which $0 is a transient /dev/fd/* descriptor that will not exist
# after this run. Every message that tells the operator how to run a
# subcommand must therefore either name a real path -- or, when the script
# was piped in, point at re-running the install command: its no-argument
# mode opens the management menu, which reaches every subcommand.
# ---------------------------------------------------------------------------
S5_SELF=$0
case "$S5_SELF" in
/dev/fd/* | /proc/self/fd/* | bash | sh | -bash | -sh) S5_SELF='' ;;
esac

# s5_cmd_hint <subcommand>: phrase describing how the operator runs it.
s5_cmd_hint() {
    if [ -n "$S5_SELF" ]; then
        _chf=$(s5_msg cmd.hint.file "$S5_SELF" "$1")
        printf '%s' "$_chf"
        _chf=''
    else
        _chr=$(s5_msg cmd.hint.rerun "$1")
        printf '%s' "$_chr"
        _chr=''
    fi
}

# The summary's closing line: how to see the credentials again.
s5_redisplay_hint() {
    if [ -n "$S5_SELF" ]; then
        _rdh=$(s5_msg show.redisplay_with "$S5_SELF")
        s5_say "$_rdh"
        _rdh=''
    else
        s5_say_msg show.redisplay_rerun
        s5_say_msg show.redisplay_rerun2
    fi
}

# ---------------------------------------------------------------------------
# Paths.  In test mode every path is rooted inside S5_TEST_ROOT.
# ---------------------------------------------------------------------------

if [ "${S5_TEST_MODE:-0}" = "1" ]; then
    S5_ROOTDIR=$S5_TEST_ROOT
else
    S5_ROOTDIR=''
fi

S5_PREFIX=${S5_PREFIX:-$S5_ROOTDIR/usr/local/libexec/$S5_PROJECT}
S5_SYSCONFDIR=${S5_SYSCONFDIR:-$S5_ROOTDIR/etc/$S5_PROJECT}
S5_STATEDIR=${S5_STATEDIR:-$S5_ROOTDIR/var/lib/$S5_PROJECT}
S5_UNITDIR=${S5_UNITDIR:-$S5_ROOTDIR/etc/systemd/system}
S5_INITDIR=${S5_INITDIR:-$S5_ROOTDIR/etc/init.d}

# Production always listens on every interface. The override exists so CI can
# confine the engine to loopback, and it is rejected outside test mode.
S5_LISTEN=${S5_LISTEN:-0.0.0.0}

S5_BIN="$S5_PREFIX/3proxy"
S5_CFG="$S5_SYSCONFDIR/3proxy.cfg"
S5_USERSCFG="$S5_SYSCONFDIR/users.cfg"
S5_STATE="$S5_STATEDIR/state"
S5_UNIT="$S5_UNITDIR/$S5_PROJECT.service"
S5_INITSCRIPT="$S5_INITDIR/$S5_PROJECT"
S5_PROC_NET_TCP=${S5_PROC_NET_TCP:-/proc/net/tcp}
S5_PROC_NET_TCP6=${S5_PROC_NET_TCP6:-/proc/net/tcp6}
S5_LOCKDIR="$S5_ROOTDIR/run/$S5_PROJECT.lock"
S5_LOCK_OWNER="$S5_LOCKDIR/owner"
S5_TXNDIR="$S5_STATEDIR/reconfigure-transaction"
S5_TXN_PHASE="$S5_TXNDIR/phase"
S5_TXN_NEW_USERS="$S5_TXNDIR/new.users.cfg"
S5_TXN_NEW_CFG="$S5_TXNDIR/new.3proxy.cfg"
S5_TXN_OLD_USERS="$S5_TXNDIR/old.users.cfg"
S5_TXN_OLD_CFG="$S5_TXNDIR/old.3proxy.cfg"
S5_TXN_OLD_STATE="$S5_TXNDIR/old.state"

# ---------------------------------------------------------------------------
# Logging.  Every message passes through redaction so a live credential can
# never reach stdout, stderr or a log sink.
# ---------------------------------------------------------------------------

# POSIX assignment preserves an inherited export attribute. Clear every variable
# that can hold a plaintext credential before assigning to it, so an invoking
# environment cannot cause later child processes to inherit a live password.
unset S5_SECRET S5_PASSWORD _vp _pw1 _lcline _lcp _stp _isu _scline _scpass \
    _rc_old_password _rc_bad_password _tx_old_password _tx_new_password \
    _tx_users_body _tx_cfg_body
S5_SECRET=''

# Literal, non-regex substring replacement. The secret is passed on stdin
# rather than through -v or a sed pattern, so no character in it is ever
# interpreted as syntax.
s5_redact() {
    if [ -z "${S5_SECRET:-}" ]; then
        printf '%s' "$1"
        return 0
    fi
    { printf '%s\n' "$S5_SECRET"; printf '%s\n' "$1"; } | awk '
        NR == 1 { s = $0; n = length(s); next }
        {
            line = $0; out = ""
            while (n > 0) {
                i = index(line, s)
                if (i == 0) break
                out = out substr(line, 1, i - 1) "***REDACTED***"
                line = substr(line, i + n)
            }
            printf "%s%s\n", out, line
        }
    '
}

# s5_sink <text> : append to the log sink when one is configured (test mode only).
s5_sink() {
    if [ -n "${S5_LOGSINK:-}" ]; then
        printf '%s\n' "$1" >>"$S5_LOGSINK"
    fi
}

s5_log() {
    _m=$(s5_redact "$1")
    printf '[*] %s\n' "$_m"
    s5_sink "$_m"
}

s5_warn() {
    _m=$(s5_redact "$1")
    printf '[!] %s\n' "$_m" >&2
    s5_sink "$_m"
}

s5_err() {
    _m=$(s5_redact "$1")
    printf '[x] %s\n' "$_m" >&2
    s5_sink "$_m"
}

# s5_say <text> : operator-facing output that must never be redacted away
# (used by `show`, which deliberately prints the credential to the terminal).
s5_say() {
    printf '%s\n' "$1"
}

# ---------------------------------------------------------------------------
# Bilingual message catalog (Round 16).
#
# Every script-owned operator message lives in one keyed
# catalog. Each key is declared by a `# @s5-msg <key> <arity>` marker and owns
# BOTH locales in the same case arm, so an untranslated key cannot be added
# without the parity test seeing it. The catalog has hard rules:
#
#   * keys are literals at every call site -- no computed keys;
#   * each key has a declared arity, enforced at runtime;
#   * formats are catalog-owned literals; caller data is %s DATA only, so no
#     argument can ever become a printf format or be executed;
#   * arity/locale failures print the key and the counts ONLY -- never
#     argument values, which may carry secrets;
#   * _s5_i18n_* scratch names are reserved for this section.
# ---------------------------------------------------------------------------
unset S5_LANG _s5_i18n_text
S5_LANG=en

s5_msg() {
    # Messages are complete lines; the trailing newline belongs to the
    # channel adapters so prompts can stay on one line.
    _s5_i18n_key=$1
    shift
    case "$_s5_i18n_key" in
    # @s5-msg detect.unsupported 3
    detect.unsupported)
        [ "$#" -eq 3 ] || { s5_msg_contract_error detect.unsupported 3 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '不支持此系统：ID=%s VERSION_ID=%s ARCH=%s（支持：Ubuntu 20.04（仅 amd64）、Ubuntu 22.04+（amd64/arm64）、Debian 12+、Alpine 3.20+、CentOS Stream 9+）' "${1}" "${2}" "${3}" ;;
        en) printf 'unsupported system: ID=%s VERSION_ID=%s ARCH=%s (supported: Ubuntu 20.04 (amd64 only), Ubuntu 22.04+ (amd64/arm64), Debian 12+, Alpine 3.20+, CentOS Stream 9+)' "${1}" "${2}" "${3}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg detect.likely_compatible 3
    detect.likely_compatible)
        [ "$#" -eq 3 ] || { s5_msg_contract_error detect.likely_compatible 3 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf 'ID=%s VERSION_ID=%s ARCH=%s 可能与 3proxy 兼容，但本脚本不支持。支持：Ubuntu 20.04（仅 amd64）、Ubuntu 22.04+（amd64/arm64）、Debian 12+、Alpine 3.20+、CentOS Stream 9+。' "${1}" "${2}" "${3}" ;;
        en) printf 'ID=%s VERSION_ID=%s ARCH=%s is likely compatible with 3proxy, but it is not supported by this script. Supported: Ubuntu 20.04 (amd64 only), Ubuntu 22.04+ (amd64/arm64), Debian 12+, Alpine 3.20+, CentOS Stream 9+.' "${1}" "${2}" "${3}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg input.port_range 2
    input.port_range)
        [ "$#" -eq 2 ] || { s5_msg_contract_error input.port_range 2 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '端口必须在 %s 到 %s 之间' "${1}" "${2}" ;;
        en) printf 'port must be between %s and %s' "${1}" "${2}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg input.port_leading_zero 0
    input.port_leading_zero)
        [ "$#" -eq 0 ] || { s5_msg_contract_error input.port_leading_zero 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '端口不能有前导零' ;;
        en) printf 'port must not have leading zeros' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg install.warning_cleartext 0
    install.warning_cleartext)
        [ "$#" -eq 0 ] || { s5_msg_contract_error install.warning_cleartext 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  * SOCKS5 用户名/密码认证（RFC 1929）在网络上以明文传输。' ;;
        en) printf '  * SOCKS5 username/password authentication (RFC 1929) is sent in CLEARTEXT' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg install.warning_cleartext2 0
    install.warning_cleartext2)
        [ "$#" -eq 0 ] || { s5_msg_contract_error install.warning_cleartext2 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '    在网络上。SOCKS5 不提供传输加密，也不提供完整性保护。它不是 VPN。' ;;
        en) printf '    on the wire. SOCKS5 provides NO transport encryption and NO integrity' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg install.warning_cleartext3 0
    install.warning_cleartext3)
        [ "$#" -eq 0 ] || { s5_msg_contract_error install.warning_cleartext3 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '' ;;
        en) printf '    protection. It is NOT a VPN.' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg install.warning_firewall 0
    install.warning_firewall)
        [ "$#" -eq 0 ] || { s5_msg_contract_error install.warning_firewall 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  * 你需要自行负责本地防火墙以及云服务商的安全组规则。' ;;
        en) printf '  * You are responsible for your own local firewall and for your cloud' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg install.warning_firewall2 0
    install.warning_firewall2)
        [ "$#" -eq 0 ] || { s5_msg_contract_error install.warning_firewall2 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '' ;;
        en) printf "    provider's security group rules." ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg install.warning_anyone 0
    install.warning_anyone)
        [ "$#" -eq 0 ] || { s5_msg_contract_error install.warning_anyone 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  * 任何获得凭据并能访问该端口的人都可以使用此代理，' ;;
        en) printf '  * ANYONE who learns the credentials and can reach the port can use this' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg install.warning_anyone2 0
    install.warning_anyone2)
        [ "$#" -eq 0 ] || { s5_msg_contract_error install.warning_anyone2 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '    其流量将看似来自本服务器。' ;;
        en) printf '    proxy, and their traffic will appear to originate from this server.' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg install.warning_protocols 0
    install.warning_protocols)
        [ "$#" -eq 0 ] || { s5_msg_contract_error install.warning_protocols 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '仅启用带用户名/密码的 SOCKS5 和 CONNECT。其他代理协议、BIND 和 UDP ASSOCIATE 均不支持。' ;;
        en) printf 'Only SOCKS5 with username/password and CONNECT is enabled. Other proxy protocols,' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg install.warning_protocols2 0
    install.warning_protocols2)
        [ "$#" -eq 0 ] || { s5_msg_contract_error install.warning_protocols2 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '' ;;
        en) printf 'BIND and UDP ASSOCIATE are not supported.' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg install.warning_header 0
    install.warning_header)
        [ "$#" -eq 0 ] || { s5_msg_contract_error install.warning_header 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '=============================== 请仔细阅读 ===============================' ;;
        en) printf '=============================== PLEASE READ ===============================' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg install.warning_packages_kept 0
    install.warning_packages_kept)
        [ "$#" -eq 0 ] || { s5_msg_contract_error install.warning_packages_kept 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '这些软件包在卸载后仍会保留。' ;;
        en) printf 'These packages are kept after uninstall.' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg install.warning_packages 1
    install.warning_packages)
        [ "$#" -eq 1 ] || { s5_msg_contract_error install.warning_packages 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '将安装的软件包：%s' "${1}" ;;
        en) printf 'Packages to install: %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg install.warning_listens 1
    install.warning_listens)
        [ "$#" -eq 1 ] || { s5_msg_contract_error install.warning_listens 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '即将安装一个监听 %s 的 SOCKS5 代理。' "${1}" ;;
        en) printf 'This installs a SOCKS5 proxy that listens on %s.' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg install.warning_detected 4
    install.warning_detected)
        [ "$#" -eq 4 ] || { s5_msg_contract_error install.warning_detected 4 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '检测到的目标系统：%s %s（%s，%s）。' "${1}" "${2}" "${3}" "${4}" ;;
        en) printf 'Detected target: %s %s (%s, %s).' "${1}" "${2}" "${3}" "${4}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg install.confirm 0
    install.confirm)
        [ "$#" -eq 0 ] || { s5_msg_contract_error install.confirm 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '确认开始安装？' ;;
        en) printf 'Continue with the installation?' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg input.port_prompt 2
    input.port_prompt)
        [ "$#" -eq 2 ] || { s5_msg_contract_error input.port_prompt 2 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf 'SOCKS5 端口 [回车 = 随机 %s-%s]：' "${1}" "${2}" ;;
        en) printf 'SOCKS5 port [Enter = random %s-%s]: ' "${1}" "${2}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg input.port_eof 0
    input.port_eof)
        [ "$#" -eq 0 ] || { s5_msg_contract_error input.port_eof 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '读取端口时输入意外结束' ;;
        en) printf 'unexpected end of input while reading the port' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg input.port_in_use 1
    input.port_in_use)
        [ "$#" -eq 1 ] || { s5_msg_contract_error input.port_in_use 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '端口 %s 已被占用' "${1}" ;;
        en) printf 'port %s is already in use' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg input.port_probe_failed 1
    input.port_probe_failed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error input.port_probe_failed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法确定端口 %s 是否空闲：监听状态探测失败' "${1}" ;;
        en) printf 'cannot determine whether port %s is free: the listen-state probe failed' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg input.port_too_many 0
    input.port_too_many)
        [ "$#" -eq 0 ] || { s5_msg_contract_error input.port_too_many 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无效端口输入次数过多' ;;
        en) printf 'too many invalid port entries' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg input.username_prompt 0
    input.username_prompt)
        [ "$#" -eq 0 ] || { s5_msg_contract_error input.username_prompt 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf 'SOCKS5 用户名 [回车 = 随机]：' ;;
        en) printf 'SOCKS5 username [Enter = random]: ' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg input.username_eof 0
    input.username_eof)
        [ "$#" -eq 0 ] || { s5_msg_contract_error input.username_eof 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '读取用户名时输入意外结束' ;;
        en) printf 'unexpected end of input while reading the username' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg input.username_gen_failed 0
    input.username_gen_failed)
        [ "$#" -eq 0 ] || { s5_msg_contract_error input.username_gen_failed 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法生成随机用户名' ;;
        en) printf 'could not generate a random username' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg input.username_too_many 0
    input.username_too_many)
        [ "$#" -eq 0 ] || { s5_msg_contract_error input.username_too_many 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无效用户名输入次数过多' ;;
        en) printf 'too many invalid username entries' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg input.password_prompt 1
    input.password_prompt)
        [ "$#" -eq 1 ] || { s5_msg_contract_error input.password_prompt 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf 'SOCKS5 密码（输入时可见）[回车 = 生成 %s 位随机字符]：' "${1}" ;;
        en) printf 'SOCKS5 password (visible while typed) [Enter = generate %s random chars]: ' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg input.password_eof 0
    input.password_eof)
        [ "$#" -eq 0 ] || { s5_msg_contract_error input.password_eof 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '读取密码时输入意外结束' ;;
        en) printf 'unexpected end of input while reading the password' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg input.password_gen_failed 0
    input.password_gen_failed)
        [ "$#" -eq 0 ] || { s5_msg_contract_error input.password_gen_failed 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法生成随机密码' ;;
        en) printf 'could not generate a random password' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg input.password_gen_log 1
    input.password_gen_log)
        [ "$#" -eq 1 ] || { s5_msg_contract_error input.password_gen_log 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '已生成 %s 位随机密码' "${1}" ;;
        en) printf 'generated a random %s-character password' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg input.password_too_many 0
    input.password_too_many)
        [ "$#" -eq 0 ] || { s5_msg_contract_error input.password_too_many 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '密码输入失败次数过多' ;;
        en) printf 'too many failed password attempts' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg validation.username_len 3
    validation.username_len)
        [ "$#" -eq 3 ] || { s5_msg_contract_error validation.username_len 3 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '用户名长度必须是 %s-%s 个字符（当前 %s）' "${1}" "${2}" "${3}" ;;
        en) printf 'username must be %s-%s characters long (got %s)' "${1}" "${2}" "${3}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg validation.username_charset 0
    validation.username_charset)
        [ "$#" -eq 0 ] || { s5_msg_contract_error validation.username_charset 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '用户名只能包含 A-Z a-z 0-9 下划线和连字符' ;;
        en) printf 'username may contain only A-Z a-z 0-9 underscore and hyphen' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg validation.password_len 3
    validation.password_len)
        [ "$#" -eq 3 ] || { s5_msg_contract_error validation.password_len 3 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '密码长度必须是 %s-%s 个字符（当前 %s）' "${1}" "${2}" "${3}" ;;
        en) printf 'password must be %s-%s characters long (got %s)' "${1}" "${2}" "${3}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg validation.password_charset 0
    validation.password_charset)
        [ "$#" -eq 0 ] || { s5_msg_contract_error validation.password_charset 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '密码只能包含 A-Z a-z 0-9 点、下划线、波浪线和连字符' ;;
        en) printf 'password may contain only A-Z a-z 0-9 dot underscore tilde and hyphen' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg cmd.not_installed 1
    cmd.not_installed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error cmd.not_installed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '%s 尚未安装。' "${1}" ;;
        en) printf '%s is not installed.' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg lock.parent_missing 1
    lock.parent_missing)
        [ "$#" -eq 1 ] || { s5_msg_contract_error lock.parent_missing 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '锁目录的父目录不存在：%s' "${1}" ;;
        en) printf 'the lock parent directory does not exist: %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg lock.parent_denied 1
    lock.parent_denied)
        [ "$#" -eq 1 ] || { s5_msg_contract_error lock.parent_denied 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '没有权限在 %s 中创建操作锁；此命令需要 root' "${1}" ;;
        en) printf 'no permission to create the operation lock in %s; this command requires root' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg lock.parent_invalid 1
    lock.parent_invalid)
        [ "$#" -eq 1 ] || { s5_msg_contract_error lock.parent_invalid 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '锁目录的父路径不安全：%s' "${1}" ;;
        en) printf 'the lock parent path is unsafe: %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg lock.create_failed 1
    lock.create_failed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error lock.create_failed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法安全创建操作锁：%s' "${1}" ;;
        en) printf 'could not create the operation lock safely: %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg lock.identity_failed 0
    lock.identity_failed)
        [ "$#" -eq 0 ] || { s5_msg_contract_error lock.identity_failed 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法确定当前进程身份；拒绝获取操作锁' ;;
        en) printf 'could not determine the current process identity; refusing the operation lock' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg lock.owner_failed 1
    lock.owner_failed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error lock.owner_failed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法写入操作锁所有者：%s' "${1}" ;;
        en) printf 'could not write the operation lock owner: %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg lock.invalid 1
    lock.invalid)
        [ "$#" -eq 1 ] || { s5_msg_contract_error lock.invalid 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '操作锁无效；请人工检查：%s' "${1}" ;;
        en) printf 'the operation lock is invalid; inspect it manually: %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg lock.busy 1
    lock.busy)
        [ "$#" -eq 1 ] || { s5_msg_contract_error lock.busy 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '另一个管理操作正在运行（PID %s）' "${1}" ;;
        en) printf 'another management operation is running (PID %s)' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg lock.stale_remove_failed 1
    lock.stale_remove_failed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error lock.stale_remove_failed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法清理失效的操作锁：%s' "${1}" ;;
        en) printf 'could not remove the stale operation lock: %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg lock.release_refused 1
    lock.release_refused)
        [ "$#" -eq 1 ] || { s5_msg_contract_error lock.release_refused 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '操作锁所有权已改变；拒绝删除：%s' "${1}" ;;
        en) printf 'the operation lock ownership changed; refusing to remove it: %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg lock.release_failed 1
    lock.release_failed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error lock.release_failed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法释放操作锁：%s' "${1}" ;;
        en) printf 'could not release the operation lock: %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;

    # @s5-msg reconfigure.summary 0
    reconfigure.summary)
        [ "$#" -eq 0 ] || { s5_msg_contract_error reconfigure.summary 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '将更新 SOCKS5 端口、用户名和密码。' ;;
        en) printf 'The SOCKS5 port, username and password will be updated.' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg reconfigure.reuses_install 0
    reconfigure.reuses_install)
        [ "$#" -eq 0 ] || { s5_msg_contract_error reconfigure.reuses_install 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '现有二进制、服务账户和服务定义将继续复用。' ;;
        en) printf 'The existing binary, service account and service definition will be reused.' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg reconfigure.no_firewall 0
    reconfigure.no_firewall)
        [ "$#" -eq 0 ] || { s5_msg_contract_error reconfigure.no_firewall 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '本脚本不会修改防火墙；若端口改变，请自行更新本机规则和云安全组。' ;;
        en) printf 'The script will not modify the firewall; update host and cloud rules yourself if the port changes.' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg reconfigure.confirm 0
    reconfigure.confirm)
        [ "$#" -eq 0 ] || { s5_msg_contract_error reconfigure.confirm 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '确认原地更新端口和凭据？' ;;
        en) printf 'Update the port and credentials in place?' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg reconfigure.confirm_invalid 0
    reconfigure.confirm_invalid)
        [ "$#" -eq 0 ] || { s5_msg_contract_error reconfigure.confirm_invalid 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '请输入 y 或 n' ;;
        en) printf 'enter y or n' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg reconfigure.confirm_failed 0
    reconfigure.confirm_failed)
        [ "$#" -eq 0 ] || { s5_msg_contract_error reconfigure.confirm_failed 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法确认是否更新；未做任何修改' ;;
        en) printf 'could not confirm reconfiguration; nothing was changed' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg reconfigure.cancelled 0
    reconfigure.cancelled)
        [ "$#" -eq 0 ] || { s5_msg_contract_error reconfigure.cancelled 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '已取消更新；现有代理保持不变' ;;
        en) printf 'reconfiguration cancelled; the existing proxy is unchanged' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg reconfigure.state_invalid 0
    reconfigure.state_invalid)
        [ "$#" -eq 0 ] || { s5_msg_contract_error reconfigure.state_invalid 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '现有安装状态不足以安全更新' ;;
        en) printf 'the existing install state is not sufficient for a safe reconfiguration' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg reconfigure.files_invalid 0
    reconfigure.files_invalid)
        [ "$#" -eq 0 ] || { s5_msg_contract_error reconfigure.files_invalid 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '现有二进制、配置或凭据文件未通过安全检查' ;;
        en) printf 'the existing binary, configuration or credentials failed validation' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg reconfigure.current_not_healthy 0
    reconfigure.current_not_healthy)
        [ "$#" -eq 0 ] || { s5_msg_contract_error reconfigure.current_not_healthy 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '现有代理未处于已验证的运行和监听状态；请先排查或卸载' ;;
        en) printf 'the existing proxy is not verifiably active and listening; diagnose or uninstall it first' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg reconfigure.transaction_exists 1
    reconfigure.transaction_exists)
        [ "$#" -eq 1 ] || { s5_msg_contract_error reconfigure.transaction_exists 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '重配事务已存在：%s' "${1}" ;;
        en) printf 'a reconfiguration transaction already exists: %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg reconfigure.transaction_create_failed 1
    reconfigure.transaction_create_failed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error reconfigure.transaction_create_failed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法创建重配事务目录：%s' "${1}" ;;
        en) printf 'could not create the reconfiguration transaction directory: %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg reconfigure.transaction_invalid 1
    reconfigure.transaction_invalid)
        [ "$#" -eq 1 ] || { s5_msg_contract_error reconfigure.transaction_invalid 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '重配事务无效；请人工检查：%s' "${1}" ;;
        en) printf 'the reconfiguration transaction is invalid; inspect it manually: %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg reconfigure.transaction_cleanup_failed 1
    reconfigure.transaction_cleanup_failed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error reconfigure.transaction_cleanup_failed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法清理重配事务目录：%s' "${1}" ;;
        en) printf 'could not clean the reconfiguration transaction directory: %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg reconfigure.stage_failed 0
    reconfigure.stage_failed)
        [ "$#" -eq 0 ] || { s5_msg_contract_error reconfigure.stage_failed 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法准备重配候选文件；现有代理未改变' ;;
        en) printf 'could not stage the reconfiguration; the existing proxy is unchanged' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg reconfigure.stop_unverified 0
    reconfigure.stop_unverified)
        [ "$#" -eq 0 ] || { s5_msg_contract_error reconfigure.stop_unverified 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法确认代理服务已停止；拒绝替换配置' ;;
        en) printf 'could not verify that the proxy stopped; refusing to replace its configuration' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg reconfigure.still_active 0
    reconfigure.still_active)
        [ "$#" -eq 0 ] || { s5_msg_contract_error reconfigure.still_active 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '代理服务仍在运行；拒绝替换配置' ;;
        en) printf 'the proxy is still running; refusing to replace its configuration' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg reconfigure.port_not_free 1
    reconfigure.port_not_free)
        [ "$#" -eq 1 ] || { s5_msg_contract_error reconfigure.port_not_free 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '停止旧代理后端口 %s 仍不可用' "${1}" ;;
        en) printf 'port %s is still unavailable after stopping the old proxy' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg reconfigure.port_unverified 1
    reconfigure.port_unverified)
        [ "$#" -eq 1 ] || { s5_msg_contract_error reconfigure.port_unverified 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '停止旧代理后无法确定端口 %s 是否可用：监听状态探测失败' "${1}" ;;
        en) printf 'could not determine whether port %s is free after stopping the old proxy: the listen-state probe failed' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg reconfigure.apply_failed 0
    reconfigure.apply_failed)
        [ "$#" -eq 0 ] || { s5_msg_contract_error reconfigure.apply_failed 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '新配置未能启用；正在恢复旧配置' ;;
        en) printf 'the new configuration could not be activated; restoring the previous configuration' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg reconfigure.pending_cleanup 0
    reconfigure.pending_cleanup)
        [ "$#" -eq 0 ] || { s5_msg_contract_error reconfigure.pending_cleanup 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '发现尚未提交的重配准备目录；正在安全清理' ;;
        en) printf 'found an uncommitted reconfiguration staging directory; cleaning it safely' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg reconfigure.pending_recovery 0
    reconfigure.pending_recovery)
        [ "$#" -eq 0 ] || { s5_msg_contract_error reconfigure.pending_recovery 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '发现未完成的重配事务；正在恢复旧配置' ;;
        en) printf 'found an incomplete reconfiguration transaction; restoring the previous configuration' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg reconfigure.restore_missing 1
    reconfigure.restore_missing)
        [ "$#" -eq 1 ] || { s5_msg_contract_error reconfigure.restore_missing 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '恢复文件不完整；已保留事务目录：%s' "${1}" ;;
        en) printf 'recovery files are incomplete; the transaction directory was kept: %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg reconfigure.restore_invalid 0
    reconfigure.restore_invalid)
        [ "$#" -eq 0 ] || { s5_msg_contract_error reconfigure.restore_invalid 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '恢复后的旧配置或状态无效' ;;
        en) printf 'the restored previous configuration or state is invalid' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg reconfigure.restore_stop_failed 0
    reconfigure.restore_stop_failed)
        [ "$#" -eq 0 ] || { s5_msg_contract_error reconfigure.restore_stop_failed 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法安全停止服务以恢复旧配置' ;;
        en) printf 'could not stop the service safely to restore the previous configuration' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg reconfigure.restore_files_failed 1
    reconfigure.restore_files_failed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error reconfigure.restore_files_failed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法恢复全部旧文件；已保留事务目录：%s' "${1}" ;;
        en) printf 'could not restore all previous files; the transaction directory was kept: %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg reconfigure.restoring 0
    reconfigure.restoring)
        [ "$#" -eq 0 ] || { s5_msg_contract_error reconfigure.restoring 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '正在重新启动并验证旧配置' ;;
        en) printf 'restarting and verifying the previous configuration' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg reconfigure.restore_service_failed 1
    reconfigure.restore_service_failed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error reconfigure.restore_service_failed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '旧配置未能恢复运行；恢复资料保留在 %s' "${1}" ;;
        en) printf 'the previous configuration could not be restored to service; recovery data remains at %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg reconfigure.restored_for_uninstall 0
    reconfigure.restored_for_uninstall)
        [ "$#" -eq 0 ] || { s5_msg_contract_error reconfigure.restored_for_uninstall 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '旧配置文件已恢复；继续卸载' ;;
        en) printf 'the previous configuration files were restored; continuing uninstall' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg reconfigure.restored 0
    reconfigure.restored)
        [ "$#" -eq 0 ] || { s5_msg_contract_error reconfigure.restored 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '旧配置已恢复并通过验证' ;;
        en) printf 'the previous configuration was restored and verified' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg reconfigure.recovery_failed 1
    reconfigure.recovery_failed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error reconfigure.recovery_failed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '自动恢复失败；请保留并检查 %s' "${1}" ;;
        en) printf 'automatic recovery failed; preserve and inspect %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg reconfigure.commit_cleanup_failed 1
    reconfigure.commit_cleanup_failed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error reconfigure.commit_cleanup_failed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '新配置已启用，但无法清理事务目录：%s' "${1}" ;;
        en) printf 'the new configuration is active, but the transaction directory could not be cleaned: %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg reconfigure.complete 0
    reconfigure.complete)
        [ "$#" -eq 0 ] || { s5_msg_contract_error reconfigure.complete 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '端口和凭据已更新并通过验证' ;;
        en) printf 'the port and credentials were updated and verified' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg reconfigure.completed_no_display 0
    reconfigure.completed_no_display)
        [ "$#" -eq 0 ] || { s5_msg_contract_error reconfigure.completed_no_display 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '更新已完成；由于 stdout 不是终端，凭据未显示。' ;;
        en) printf 'Reconfiguration completed; credentials were not displayed because stdout is not a terminal.' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg reconfigure.read_blocked 0
    reconfigure.read_blocked)
        [ "$#" -eq 0 ] || { s5_msg_contract_error reconfigure.read_blocked 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '存在未完成的重配事务；请先运行 install、restart 或 uninstall 触发恢复' ;;
        en) printf 'an incomplete reconfiguration exists; run install, restart or uninstall to recover it first' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;

    # @s5-msg cmd.uninstall.nothing 1
    cmd.uninstall.nothing)
        [ "$#" -eq 1 ] || { s5_msg_contract_error cmd.uninstall.nothing 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '此脚本未安装 %s；无需移除。' "${1}" ;;
        en) printf '%s is not installed by this script; nothing to remove.' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg cmd.restarted 1
    cmd.restarted)
        [ "$#" -eq 1 ] || { s5_msg_contract_error cmd.restarted 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '%s 已重启' "${1}" ;;
        en) printf '%s restarted' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg menu.heading 1
    menu.heading)
        [ "$#" -eq 1 ] || { s5_msg_contract_error menu.heading 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '%s 已安装。请选择操作：' "${1}" ;;
        en) printf '%s is installed. Choose an action:' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg menu.choice_prompt 0
    menu.choice_prompt)
        [ "$#" -eq 0 ] || { s5_msg_contract_error menu.choice_prompt 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '请选择 [1-6]：' ;;
        en) printf 'Choice [1-6]: ' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg uninstall.confirm 0
    uninstall.confirm)
        [ "$#" -eq 0 ] || { s5_msg_contract_error uninstall.confirm 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '确认卸载？' ;;
        en) printf 'Proceed with uninstall?' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg usage.extra_args 2
    usage.extra_args)
        [ "$#" -eq 2 ] || { s5_msg_contract_error usage.extra_args 2 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '%s 不接受参数：%s' "${1}" "${2}" ;;
        en) printf '%s takes no arguments: %s' "${1}" "${2}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg cmd.hint.file 2
    cmd.hint.file)
        [ "$#" -eq 2 ] || { s5_msg_contract_error cmd.hint.file 2 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf "运行 '%s %s'" "${1}" "${2}" ;;
        en) printf "run '%s %s'" "${1}" "${2}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg cmd.hint.rerun 1
    cmd.hint.rerun)
        [ "$#" -eq 1 ] || { s5_msg_contract_error cmd.hint.rerun 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf "重新运行安装命令并从菜单中选择 '%s'" "${1}" ;;
        en) printf "re-run the install command and choose '%s' from the menu" "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg input.log_random_port 1
    input.log_random_port)
        [ "$#" -eq 1 ] || { s5_msg_contract_error input.log_random_port 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '已选择随机端口 %s' "${1}" ;;
        en) printf 'selected random port %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg usage.line_usage 1
    usage.line_usage)
        [ "$#" -eq 1 ] || { s5_msg_contract_error usage.line_usage 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '用法：%s [command]' "${1}" ;;
        en) printf 'Usage: %s [command]' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg usage.line_commands 0
    usage.line_commands)
        [ "$#" -eq 0 ] || { s5_msg_contract_error usage.line_commands 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '命令：' ;;
        en) printf 'Commands:' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg usage.cmd_install 0
    usage.cmd_install)
        [ "$#" -eq 0 ] || { s5_msg_contract_error usage.cmd_install 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  install      安装或原地更新 SOCKS5 代理' ;;
        en) printf '  install      Install or update the SOCKS5 proxy in place' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg usage.cmd_status 0
    usage.cmd_status)
        [ "$#" -eq 0 ] || { s5_msg_contract_error usage.cmd_status 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  status       查看服务、端口和版本信息' ;;
        en) printf '  status       Show service, port and version information' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg usage.cmd_show 0
    usage.cmd_show)
        [ "$#" -eq 0 ] || { s5_msg_contract_error usage.cmd_show 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  show         重新显示完整连接信息（仅限 root）' ;;
        en) printf '  show         Re-display the full connection details (root only)' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg usage.cmd_restart 0
    usage.cmd_restart)
        [ "$#" -eq 0 ] || { s5_msg_contract_error usage.cmd_restart 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  restart      重启代理服务' ;;
        en) printf '  restart      Restart the proxy service' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg usage.cmd_uninstall 0
    usage.cmd_uninstall)
        [ "$#" -eq 0 ] || { s5_msg_contract_error usage.cmd_uninstall 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  uninstall    删除本脚本创建的所有内容' ;;
        en) printf '  uninstall    Remove everything this script created' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg usage.line_no_command 0
    usage.line_no_command)
        [ "$#" -eq 0 ] || { s5_msg_contract_error usage.line_no_command 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '不带命令运行：未安装时执行安装，已安装时显示管理菜单。' ;;
        en) printf 'With no command: installs if absent, otherwise shows a management menu.' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg usage.line_protocol 0
    usage.line_protocol)
        [ "$#" -eq 0 ] || { s5_msg_contract_error usage.line_protocol 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '协议支持：仅 SOCKS5，仅带 RFC 1929 用户名/密码认证和 CONNECT。' ;;
        en) printf 'Protocol support: SOCKS5 only, with RFC 1929 username/password authentication' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg usage.line_protocol2 0
    usage.line_protocol2)
        [ "$#" -eq 0 ] || { s5_msg_contract_error usage.line_protocol2 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '其他代理协议、未认证 SOCKS5、BIND 和 UDP ASSOCIATE 均被拒绝。' ;;
        en) printf 'and CONNECT only. Other proxy protocols, unauthenticated SOCKS5, BIND and UDP ASSOCIATE' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg usage.line_protocol3 0
    usage.line_protocol3)
        [ "$#" -eq 0 ] || { s5_msg_contract_error usage.line_protocol3 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf 'SOCKS5 不是加密 VPN。' ;;
        en) printf 'are rejected. SOCKS5 is not an encrypted VPN.' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;

    # @s5-msg show.redisplay_with 1
    show.redisplay_with)
        [ "$#" -eq 1 ] || { s5_msg_contract_error show.redisplay_with 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  稍后重新查看这些信息：%s show' "${1}" ;;
        en) printf '  Re-display these details later with: %s show' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg show.redisplay_rerun 0
    show.redisplay_rerun)
        [ "$#" -eq 0 ] || { s5_msg_contract_error show.redisplay_rerun 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf "  稍后重新运行安装命令，并从菜单中选择 'show'，" ;;
        en) printf '  Re-display these details later by re-running the install' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg show.redisplay_rerun2 0
    show.redisplay_rerun2)
        [ "$#" -eq 0 ] || { s5_msg_contract_error show.redisplay_rerun2 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  即可再次查看这些信息。' ;;
        en) printf "  command and choosing 'show' from the menu." ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg collision.remove_or_rename 1
    collision.remove_or_rename)
        [ "$#" -eq 1 ] || { s5_msg_contract_error collision.remove_or_rename 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '请删除或重命名它们，或%s，然后重试。' "${1}" ;;
        en) printf 'Remove or rename them, or %s, then retry.' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg uninstall.label_file 1
    uninstall.label_file)
        [ "$#" -eq 1 ] || { s5_msg_contract_error uninstall.label_file 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  文件     ：%s' "${1}" ;;
        en) printf '  file      : %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg uninstall.label_directory 1
    uninstall.label_directory)
        [ "$#" -eq 1 ] || { s5_msg_contract_error uninstall.label_directory 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  目录     ：%s' "${1}" ;;
        en) printf '  directory : %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg uninstall.label_account 1
    uninstall.label_account)
        [ "$#" -eq 1 ] || { s5_msg_contract_error uninstall.label_account 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  账户     ：%s' "${1}" ;;
        en) printf '  account   : %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg card.warn_placeholder 0
    card.warn_placeholder)
        [ "$#" -eq 0 ] || { s5_msg_contract_error card.warn_placeholder 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  警告：无法确定服务器地址。请把下面的 SERVER_IPV4 替换为服务器的公网 IPv4。' ;;
        en) printf "  WARNING: the server address could not be determined. Replace SERVER_IPV4 below with your server's public IPv4." ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg card.ready_header 0
    card.ready_header)
        [ "$#" -eq 0 ] || { s5_msg_contract_error card.ready_header 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '================= SOCKS5 代理已就绪 =================' ;;
        en) printf '================= SOCKS5 proxy is ready =================' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg card.label_server 0
    card.label_server)
        [ "$#" -eq 0 ] || { s5_msg_contract_error card.label_server 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  服务器地址     ：' ;;
        en) printf '  Server address : ' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg card.label_port 0
    card.label_port)
        [ "$#" -eq 0 ] || { s5_msg_contract_error card.label_port 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  端口           ：' ;;
        en) printf '  Port           : ' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg card.label_username 0
    card.label_username)
        [ "$#" -eq 0 ] || { s5_msg_contract_error card.label_username 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  用户名         ：' ;;
        en) printf '  Username       : ' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg card.label_password 0
    card.label_password)
        [ "$#" -eq 0 ] || { s5_msg_contract_error card.label_password 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  密码           ：' ;;
        en) printf '  Password       : ' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg card.label_firewall 0
    card.label_firewall)
        [ "$#" -eq 0 ] || { s5_msg_contract_error card.label_firewall 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  本地防火墙     ：' ;;
        en) printf '  Local firewall : ' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg card.firewall_untouched 0
    card.firewall_untouched)
        [ "$#" -eq 0 ] || { s5_msg_contract_error card.firewall_untouched 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '本脚本未做任何修改' ;;
        en) printf 'not modified by this script' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg card.cloud_provider 1
    card.cloud_provider)
        [ "$#" -eq 1 ] || { s5_msg_contract_error card.cloud_provider 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  云服务商       ：你还必须在自己的云安全组 / 网络 ACL 中允许入站 TCP %s。' "${1}" ;;
        en) printf '  Cloud provider : you must ALSO allow inbound TCP %s in your cloud security group / network ACL.' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;

    # @s5-msg card.warning_encrypted 0
    card.warning_encrypted)
        [ "$#" -eq 0 ] || { s5_msg_contract_error card.warning_encrypted 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  警告：SOCKS5 认证和流量未加密。' ;;
        en) printf '  WARNING: SOCKS5 authentication and traffic are NOT encrypted.' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg card.warning_vpn 0
    card.warning_vpn)
        [ "$#" -eq 0 ] || { s5_msg_contract_error card.warning_vpn 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '           SOCKS5 不是 VPN。任何持有这些凭据并能访问' ;;
        en) printf '           SOCKS5 is not a VPN. Anyone with these credentials who can' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg card.warning_vpn2 0
    card.warning_vpn2)
        [ "$#" -eq 0 ] || { s5_msg_contract_error card.warning_vpn2 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '           该端口的人都可以使用此代理。' ;;
        en) printf '           reach the port can use this proxy.' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg card.rule_end 0
    card.rule_end)
        [ "$#" -eq 0 ] || { s5_msg_contract_error card.rule_end 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '========================================================' ;;
        en) printf '========================================================' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg status.heading 1
    status.heading)
        [ "$#" -eq 1 ] || { s5_msg_contract_error status.heading 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '%s 状态' "${1}" ;;
        en) printf '%s status' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg status.service_running 0
    status.service_running)
        [ "$#" -eq 0 ] || { s5_msg_contract_error status.service_running 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '运行中' ;;
        en) printf 'running' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg status.service_not_running 0
    status.service_not_running)
        [ "$#" -eq 0 ] || { s5_msg_contract_error status.service_not_running 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '未运行' ;;
        en) printf 'not running' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg status.service_unverified 0
    status.service_unverified)
        [ "$#" -eq 0 ] || { s5_msg_contract_error status.service_unverified 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '状态未验证' ;;
        en) printf 'state not verified' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg status.listening 2
    status.listening)
        [ "$#" -eq 2 ] || { s5_msg_contract_error status.listening 2 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '监听于 %s:%s' "${1}" "${2}" ;;
        en) printf 'listening on %s:%s' "${1}" "${2}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg status.not_listening 1
    status.not_listening)
        [ "$#" -eq 1 ] || { s5_msg_contract_error status.not_listening 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '未监听端口 %s' "${1}" ;;
        en) printf 'NOT listening on port %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg status.listen_unverified 1
    status.listen_unverified)
        [ "$#" -eq 1 ] || { s5_msg_contract_error status.listen_unverified 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '%s（监听状态未验证：未找到 ss 或 netstat）' "${1}" ;;
        en) printf '%s (listen state not verified: neither ss nor netstat found)' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg status.label_service 0
    status.label_service)
        [ "$#" -eq 0 ] || { s5_msg_contract_error status.label_service 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  服务     ：' ;;
        en) printf '  service   : ' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg status.label_port 0
    status.label_port)
        [ "$#" -eq 0 ] || { s5_msg_contract_error status.label_port 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  端口     ：' ;;
        en) printf '  port      : ' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg status.label_username 0
    status.label_username)
        [ "$#" -eq 0 ] || { s5_msg_contract_error status.label_username 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  用户名   ：' ;;
        en) printf '  username  : ' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg status.label_engine 0
    status.label_engine)
        [ "$#" -eq 0 ] || { s5_msg_contract_error status.label_engine 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  引擎     ：' ;;
        en) printf '  engine    : ' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg status.engine_value 2
    status.engine_value)
        [ "$#" -eq 2 ] || { s5_msg_contract_error status.engine_value 2 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '3proxy %s（提交 %s）' "${1}" "${2}" ;;
        en) printf '3proxy %s (commit %s)' "${1}" "${2}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg status.label_origin 0
    status.label_origin)
        [ "$#" -eq 0 ] || { s5_msg_contract_error status.label_origin 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  来源     ：' ;;
        en) printf '  origin    : ' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg status.label_asset 0
    status.label_asset)
        [ "$#" -eq 0 ] || { s5_msg_contract_error status.label_asset 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  资产     ：' ;;
        en) printf '  asset     : ' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg status.label_sha256 0
    status.label_sha256)
        [ "$#" -eq 0 ] || { s5_msg_contract_error status.label_sha256 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  SHA-256  ：' ;;
        en) printf '  SHA-256   : ' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg status.label_binary 0
    status.label_binary)
        [ "$#" -eq 0 ] || { s5_msg_contract_error status.label_binary 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  二进制   ：' ;;
        en) printf '  binary    : ' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg status.label_firewall 0
    status.label_firewall)
        [ "$#" -eq 0 ] || { s5_msg_contract_error status.label_firewall 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  防火墙   ：' ;;
        en) printf '  firewall  : ' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;

    # @s5-msg collision.refuse_overwrite 0
    collision.refuse_overwrite)
        [ "$#" -eq 0 ] || { s5_msg_contract_error collision.refuse_overwrite 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '拒绝覆盖本脚本未创建的资源。' ;;
        en) printf 'Refusing to overwrite resources this script did not create.' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg rollback.rm_file_failed 1
    rollback.rm_file_failed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error rollback.rm_file_failed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法删除 %s' "${1}" ;;
        en) printf 'could not remove %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg rollback.keep_symlink 1
    rollback.keep_symlink)
        [ "$#" -eq 1 ] || { s5_msg_contract_error rollback.keep_symlink 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '保留 %s：它是符号链接' "${1}" ;;
        en) printf 'keeping %s: it is a symbolic link' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg rollback.keep_foreign_files 1
    rollback.keep_foreign_files)
        [ "$#" -eq 1 ] || { s5_msg_contract_error rollback.keep_foreign_files 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '保留 %s：它包含本脚本未创建的文件：' "${1}" ;;
        en) printf 'keeping %s: it contains files this script did not create:' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg rollback.rm_dir_failed 1
    rollback.rm_dir_failed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error rollback.rm_dir_failed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法删除目录 %s' "${1}" ;;
        en) printf 'could not remove the directory %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg rollback.stop_failed 0
    rollback.stop_failed)
        [ "$#" -eq 0 ] || { s5_msg_contract_error rollback.stop_failed 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法停止代理服务；拒绝删除其资源' ;;
        en) printf 'could not stop the proxy service; refusing to remove its resources' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg rollback.still_active 0
    rollback.still_active)
        [ "$#" -eq 0 ] || { s5_msg_contract_error rollback.still_active 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '代理服务仍在运行；拒绝删除其资源' ;;
        en) printf 'the proxy service is still active; refusing to remove its resources' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg rollback.stop_unverified 0
    rollback.stop_unverified)
        [ "$#" -eq 0 ] || { s5_msg_contract_error rollback.stop_unverified 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法确认代理服务已停止；拒绝删除其资源' ;;
        en) printf 'could not verify that the proxy service stopped; refusing to remove its resources' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg rollback.removed_account 1
    rollback.removed_account)
        [ "$#" -eq 1 ] || { s5_msg_contract_error rollback.removed_account 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '已删除 %s 服务账户' "${1}" ;;
        en) printf 'removed the %s service account' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg rollback.reload_after_remove 0
    rollback.reload_after_remove)
        [ "$#" -eq 0 ] || { s5_msg_contract_error rollback.reload_after_remove 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '删除 unit 后无法重新加载 systemd 管理器' ;;
        en) printf 'could not reload the systemd manager after removing its unit' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg rollback.starting 0
    rollback.starting)
        [ "$#" -eq 0 ] || { s5_msg_contract_error rollback.starting 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '安装失败；正在删除本次运行创建的资源' ;;
        en) printf 'installation failed; removing the resources created by this run' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg rollback.no_state 0
    rollback.no_state)
        [ "$#" -eq 0 ] || { s5_msg_contract_error rollback.no_state 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '没有可用的状态文件；无法自动回滚' ;;
        en) printf 'no usable state file; nothing could be rolled back automatically' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg rollback.incomplete 1
    rollback.incomplete)
        [ "$#" -eq 1 ] || { s5_msg_contract_error rollback.incomplete 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '回滚未完成；状态文件保留在 %s，可以重试' "${1}" ;;
        en) printf 'rollback was incomplete; the state file is kept at %s so you can retry' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg rollback.retry_uninstall 1
    rollback.retry_uninstall)
        [ "$#" -eq 1 ] || { s5_msg_contract_error rollback.retry_uninstall 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '解决上述问题后，%s' "${1}" ;;
        en) printf '%s once the problem above is resolved' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg rollback.state_dir_foreign 1
    rollback.state_dir_foreign)
        [ "$#" -eq 1 ] || { s5_msg_contract_error rollback.state_dir_foreign 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '回滚无法删除 %s：它包含本脚本未创建的文件' "${1}" ;;
        en) printf 'rollback cannot remove %s: it contains files this script did not create' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg rollback.rm_state_failed 1
    rollback.rm_state_failed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error rollback.rm_state_failed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法删除状态文件 %s' "${1}" ;;
        en) printf 'rollback could not remove the state file %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg rollback.complete 0
    rollback.complete)
        [ "$#" -eq 0 ] || { s5_msg_contract_error rollback.complete 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '回滚完成；未删除任何软件包' ;;
        en) printf 'rollback complete; no packages were removed' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg rollback.restore_failed 1
    rollback.restore_failed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error rollback.restore_failed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '删除状态目录后无法恢复状态文件 %s' "${1}" ;;
        en) printf 'rollback could not restore its state file after removing %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg rollback.rm_dir_retained 1
    rollback.rm_dir_retained)
        [ "$#" -eq 1 ] || { s5_msg_contract_error rollback.rm_dir_retained 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法删除状态目录 %s；状态已保留以便重试' "${1}" ;;
        en) printf 'rollback could not remove the state directory; the state file is kept at %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg card.refusing_display 0
    card.refusing_display)
        [ "$#" -eq 0 ] || { s5_msg_contract_error card.refusing_display 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '拒绝显示代理密码：stdout 不是终端' ;;
        en) printf 'refusing to display the proxy password: stdout is not a terminal' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg card.completed_no_display 0
    card.completed_no_display)
        [ "$#" -eq 0 ] || { s5_msg_contract_error card.completed_no_display 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '安装已完成；由于 stdout 不是终端，凭据未显示。' ;;
        en) printf 'Installation completed; credentials were not displayed because stdout is not a terminal.' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg install.starting_service 1
    install.starting_service)
        [ "$#" -eq 1 ] || { s5_msg_contract_error install.starting_service 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '正在启动 %s' "${1}" ;;
        en) printf 'starting %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg install.start_failed 0
    install.start_failed)
        [ "$#" -eq 0 ] || { s5_msg_contract_error install.start_failed 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '服务启动失败' ;;
        en) printf 'the service failed to start' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg install.not_active_after_start 0
    install.not_active_after_start)
        [ "$#" -eq 0 ] || { s5_msg_contract_error install.not_active_after_start 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '启动后服务未处于运行状态' ;;
        en) printf 'the service is not active after start' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg install.active_unverified 0
    install.active_unverified)
        [ "$#" -eq 0 ] || { s5_msg_contract_error install.active_unverified 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法确认启动后服务处于运行状态' ;;
        en) printf 'could not verify that the service is active after start' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg install.verifying_bad 0
    install.verifying_bad)
        [ "$#" -eq 0 ] || { s5_msg_contract_error install.verifying_bad 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '正在验证无效凭据会被拒绝' ;;
        en) printf 'verifying that invalid credentials are refused' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg install.verifying_good 0
    install.verifying_good)
        [ "$#" -eq 0 ] || { s5_msg_contract_error install.verifying_good 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '正在验证有效凭据可以工作' ;;
        en) printf 'verifying that valid credentials work' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg install.selftest_failed 1
    install.selftest_failed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error install.selftest_failed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '有效凭据的自检失败（%s）' "${1}" ;;
        en) printf 'the self-test with valid credentials failed (%s)' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg install.aborted 0
    install.aborted)
        [ "$#" -eq 0 ] || { s5_msg_contract_error install.aborted 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '操作员请求中止安装' ;;
        en) printf "installation aborted at the operator's request" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg show.username_invalid 1
    show.username_invalid)
        [ "$#" -eq 1 ] || { s5_msg_contract_error show.username_invalid 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '%s 中的用户名无效；拒绝显示' "${1}" ;;
        en) printf 'the username in %s is not valid; refusing to display it' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg show.credential_line_count 1
    show.credential_line_count)
        [ "$#" -eq 1 ] || { s5_msg_contract_error show.credential_line_count 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '%s 必须恰好包含一行凭据' "${1}" ;;
        en) printf '%s must contain exactly one credential line' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg show.credential_format 1
    show.credential_format)
        [ "$#" -eq 1 ] || { s5_msg_contract_error show.credential_format 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '%s 不符合预期的 user:CL:password 格式' "${1}" ;;
        en) printf '%s is not in the expected user:CL:password form' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg show.password_invalid 1
    show.password_invalid)
        [ "$#" -eq 1 ] || { s5_msg_contract_error show.password_invalid 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '%s 中的密码无效；拒绝显示' "${1}" ;;
        en) printf 'the password in %s is not valid; refusing to display it' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg show.requires_root 0
    show.requires_root)
        [ "$#" -eq 0 ] || { s5_msg_contract_error show.requires_root 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf 'show 会显示代理密码，因此需要 root 权限' ;;
        en) printf "'show' displays the proxy password and therefore requires root" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg show.cred_unreadable 1
    show.cred_unreadable)
        [ "$#" -eq 1 ] || { s5_msg_contract_error show.cred_unreadable 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法从 %s 读取有效凭据' "${1}" ;;
        en) printf 'cannot read valid credentials from %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg restart.requires_root 0
    restart.requires_root)
        [ "$#" -eq 0 ] || { s5_msg_contract_error restart.requires_root 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '重启服务需要 root 权限' ;;
        en) printf 'restarting the service requires root' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg restart.failed 0
    restart.failed)
        [ "$#" -eq 0 ] || { s5_msg_contract_error restart.failed 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '服务重启失败' ;;
        en) printf 'the service failed to restart' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg restart.not_active 0
    restart.not_active)
        [ "$#" -eq 0 ] || { s5_msg_contract_error restart.not_active 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '重启后服务未处于运行状态' ;;
        en) printf 'the service is not active after restart' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg restart.active_unverified 0
    restart.active_unverified)
        [ "$#" -eq 0 ] || { s5_msg_contract_error restart.active_unverified 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法确认重启后服务处于运行状态' ;;
        en) printf 'could not verify that the service is active after restart' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg uninstall.requires_root 0
    uninstall.requires_root)
        [ "$#" -eq 0 ] || { s5_msg_contract_error uninstall.requires_root 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '卸载需要 root 权限' ;;
        en) printf 'uninstalling requires root privileges' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg uninstall.state_invalid 0
    uninstall.state_invalid)
        [ "$#" -eq 0 ] || { s5_msg_contract_error uninstall.state_invalid 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '状态文件无法通过校验；拒绝删除任何内容' ;;
        en) printf 'the state file could not be validated; refusing to delete anything' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg uninstall.state_invalid_hint 1
    uninstall.state_invalid_hint)
        [ "$#" -eq 1 ] || { s5_msg_contract_error uninstall.state_invalid_hint 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '请手动检查 %s，然后自行删除本项目的资源' "${1}" ;;
        en) printf "inspect %s by hand, then remove the project's resources yourself" "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg uninstall.removing_only 0
    uninstall.removing_only)
        [ "$#" -eq 0 ] || { s5_msg_contract_error uninstall.removing_only 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '只会删除本脚本记录创建的固定资源：' ;;
        en) printf 'This will remove only the fixed resources this script recorded creating:' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg uninstall.no_firewall_removed 0
    uninstall.no_firewall_removed)
        [ "$#" -eq 0 ] || { s5_msg_contract_error uninstall.no_firewall_removed 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '不会删除任何防火墙规则：本脚本从未创建过。' ;;
        en) printf 'No firewall rule is removed: this script never created one.' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg uninstall.packages_kept 0
    uninstall.packages_kept)
        [ "$#" -eq 0 ] || { s5_msg_contract_error uninstall.packages_kept 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '已安装的软件包不会被删除。' ;;
        en) printf 'Installed packages are NOT removed.' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg uninstall.aborted 0
    uninstall.aborted)
        [ "$#" -eq 0 ] || { s5_msg_contract_error uninstall.aborted 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '操作员请求中止卸载' ;;
        en) printf "uninstall aborted at the operator's request" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg uninstall.incomplete 1
    uninstall.incomplete)
        [ "$#" -eq 1 ] || { s5_msg_contract_error uninstall.incomplete 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '卸载未完成；状态文件保留在 %s' "${1}" ;;
        en) printf 'uninstall did NOT complete; the state file is kept at %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg uninstall.resolve_then 0
    uninstall.resolve_then)
        [ "$#" -eq 0 ] || { s5_msg_contract_error uninstall.resolve_then 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '请先解决上面列出的问题，然后' ;;
        en) printf 'resolve the problems listed above, then' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg uninstall.keep_state_foreign 1
    uninstall.keep_state_foreign)
        [ "$#" -eq 1 ] || { s5_msg_contract_error uninstall.keep_state_foreign 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '保留 %s：它包含本脚本未创建的文件：' "${1}" ;;
        en) printf 'keeping %s: it contains files this script did not create:' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg uninstall.rm_state_failed 1
    uninstall.rm_state_failed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error uninstall.rm_state_failed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法删除状态文件 %s' "${1}" ;;
        en) printf 'could not remove the state file %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg uninstall.complete 0
    uninstall.complete)
        [ "$#" -eq 0 ] || { s5_msg_contract_error uninstall.complete 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '卸载完成；未删除任何系统软件包' ;;
        en) printf 'uninstall complete; no system packages were removed' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg uninstall.restore_failed 1
    uninstall.restore_failed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error uninstall.restore_failed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '状态目录仍存在，无法恢复 %s' "${1}" ;;
        en) printf 'could not restore %s after the state directory remained' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg uninstall.rm_dir_retained 1
    uninstall.rm_dir_retained)
        [ "$#" -eq 1 ] || { s5_msg_contract_error uninstall.rm_dir_retained 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法删除状态目录 %s；状态已保留以便重试' "${1}" ;;
        en) printf 'could not remove the state directory %s; state was retained for retry' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg menu.option_status 0
    menu.option_status)
        [ "$#" -eq 0 ] || { s5_msg_contract_error menu.option_status 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  1) status     查看服务、端口和版本' ;;
        en) printf '  1) status     show service, port and version' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg menu.option_show 0
    menu.option_show)
        [ "$#" -eq 0 ] || { s5_msg_contract_error menu.option_show 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  2) show       重新显示完整连接信息（仅限 root）' ;;
        en) printf '  2) show       re-display the full connection details (root only)' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg menu.option_restart 0
    menu.option_restart)
        [ "$#" -eq 0 ] || { s5_msg_contract_error menu.option_restart 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  3) restart    重启代理服务' ;;
        en) printf '  3) restart    restart the proxy service' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg menu.option_uninstall 0
    menu.option_uninstall)
        [ "$#" -eq 0 ] || { s5_msg_contract_error menu.option_uninstall 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  4) uninstall  删除本脚本创建的所有内容' ;;
        en) printf '  4) uninstall  remove everything this script created' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg menu.option_quit 0
    menu.option_quit)
        [ "$#" -eq 0 ] || { s5_msg_contract_error menu.option_quit 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  5) quit       退出' ;;
        en) printf '  5) quit' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg menu.option_reconfigure 0
    menu.option_reconfigure)
        [ "$#" -eq 0 ] || { s5_msg_contract_error menu.option_reconfigure 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  6) update     更新端口、用户名和密码' ;;
        en) printf '  6) update     update the port, username and password' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg menu.eof 0
    menu.eof)
        [ "$#" -eq 0 ] || { s5_msg_contract_error menu.eof 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '输入意外结束' ;;
        en) printf 'unexpected end of input' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg menu.nothing_to_do 0
    menu.nothing_to_do)
        [ "$#" -eq 0 ] || { s5_msg_contract_error menu.nothing_to_do 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无事可做' ;;
        en) printf 'nothing to do' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg menu.invalid_choice 1
    menu.invalid_choice)
        [ "$#" -eq 1 ] || { s5_msg_contract_error menu.invalid_choice 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无效选择：%s' "${1}" ;;
        en) printf 'invalid choice: %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg usage.unknown_subcommand 1
    usage.unknown_subcommand)
        [ "$#" -eq 1 ] || { s5_msg_contract_error usage.unknown_subcommand 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '未知子命令：%s' "${1}" ;;
        en) printf 'unknown subcommand: %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;

    # @s5-msg collision.path_exists 1
    collision.path_exists)
        [ "$#" -eq 1 ] || { s5_msg_contract_error collision.path_exists 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '%s 已存在且不是本脚本创建的' "${1}" ;;
        en) printf '%s already exists and was not created by this script' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg collision.user_exists 1
    collision.user_exists)
        [ "$#" -eq 1 ] || { s5_msg_contract_error collision.user_exists 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '%s 账户已存在且不是本脚本创建的' "${1}" ;;
        en) printf 'the %s account already exists and was not created by this script' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg collision.group_exists 1
    collision.group_exists)
        [ "$#" -eq 1 ] || { s5_msg_contract_error collision.group_exists 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '%s 组已存在且不是本脚本创建的' "${1}" ;;
        en) printf 'the %s group already exists and was not created by this script' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;

    # @s5-msg account.remove_uid_missing 1
    account.remove_uid_missing)
        [ "$#" -eq 1 ] || { s5_msg_contract_error account.remove_uid_missing 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '状态文件未记录可用的账户 uid；如果 %s 是你的，请手动删除' "${1}" ;;
        en) printf 'the state does not record a usable account uid; remove %s manually if it is yours' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg account.remove_gid_missing 1
    account.remove_gid_missing)
        [ "$#" -eq 1 ] || { s5_msg_contract_error account.remove_gid_missing 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '状态文件未记录可用的组 gid；如果 %s 是你的，请手动删除' "${1}" ;;
        en) printf 'the state does not record a usable group gid; remove %s manually if it is yours' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg account.current_uid_unknown 1
    account.current_uid_unknown)
        [ "$#" -eq 1 ] || { s5_msg_contract_error account.current_uid_unknown 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法确定 %s 的当前 uid' "${1}" ;;
        en) printf 'could not determine the current uid of %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg account.current_gid_unknown 1
    account.current_gid_unknown)
        [ "$#" -eq 1 ] || { s5_msg_contract_error account.current_gid_unknown 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法确定 %s 的当前 gid' "${1}" ;;
        en) printf 'could not determine the current gid of %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg account.remove_uid_reused 3
    account.remove_uid_reused)
        [ "$#" -eq 3 ] || { s5_msg_contract_error account.remove_uid_reused 3 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '拒绝删除 %s：该名称现在对应 uid %s，而不是本脚本创建的 uid %s（名称被复用）' "${1}" "${2}" "${3}" ;;
        en) printf 'refusing to remove %s: the name now answers to uid %s, not the uid %s this script created (the name was reused)' "${1}" "${2}" "${3}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg account.remove_gid_reused 3
    account.remove_gid_reused)
        [ "$#" -eq 3 ] || { s5_msg_contract_error account.remove_gid_reused 3 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '拒绝删除 %s：该名称现在对应 gid %s，而不是本脚本创建的 gid %s（名称被复用）' "${1}" "${2}" "${3}" ;;
        en) printf 'refusing to remove %s: the name now answers to gid %s, not the gid %s this script created (the name was reused)' "${1}" "${2}" "${3}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg account.remove_user_failed 1
    account.remove_user_failed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error account.remove_user_failed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '删除尝试后 %s 账户仍然存在' "${1}" ;;
        en) printf 'the %s account still exists after the removal attempt' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg account.remove_group_failed 1
    account.remove_group_failed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error account.remove_group_failed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '删除尝试后 %s 组仍然存在' "${1}" ;;
        en) printf 'the %s group still exists after the removal attempt' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg account.remove_user_unknown 1
    account.remove_user_unknown)
        [ "$#" -eq 1 ] || { s5_msg_contract_error account.remove_user_unknown 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法确定 %s 账户是否已被删除' "${1}" ;;
        en) printf 'could not determine whether the %s account was removed' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg account.remove_group_unknown 1
    account.remove_group_unknown)
        [ "$#" -eq 1 ] || { s5_msg_contract_error account.remove_group_unknown 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法确定 %s 组是否已被删除' "${1}" ;;
        en) printf 'could not determine whether the %s group was removed' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg account.exists_unknown 1
    account.exists_unknown)
        [ "$#" -eq 1 ] || { s5_msg_contract_error account.exists_unknown 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法确定 %s 账户是否存在' "${1}" ;;
        en) printf 'could not determine whether the %s account exists' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg account.group_exists_unknown2 1
    account.group_exists_unknown2)
        [ "$#" -eq 1 ] || { s5_msg_contract_error account.group_exists_unknown2 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法确定 %s 组是否存在' "${1}" ;;
        en) printf 'could not determine whether the %s group exists' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg selftest.security_accepted 0
    selftest.security_accepted)
        [ "$#" -eq 0 ] || { s5_msg_contract_error selftest.security_accepted 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '安全错误：代理接受了本应被拒绝的凭据' ;;
        en) printf 'SECURITY: the proxy accepted credentials that should have been refused' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg selftest.inconclusive 2
    selftest.inconclusive)
        [ "$#" -eq 2 ] || { s5_msg_contract_error selftest.inconclusive 2 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '结论不明：错误凭据探测以 curl 状态 %s 失败，而不是 %s（代理握手错误）' "${1}" "${2}" ;;
        en) printf 'inconclusive: the bad-credential probe failed with curl status %s, not %s (proxy handshake error)' "${1}" "${2}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg selftest.rejection_unproven 0
    selftest.rejection_unproven)
        [ "$#" -eq 0 ] || { s5_msg_contract_error selftest.rejection_unproven 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法证明代理拒绝无效凭据；拒绝继续' ;;
        en) printf "the proxy's rejection of invalid credentials could not be proven; refusing to continue" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg network.cause_dns 0
    network.cause_dns)
        [ "$#" -eq 0 ] || { s5_msg_contract_error network.cause_dns 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  原因：此服务器无法解析 DNS 名称。' ;;
        en) printf '  Cause: this server cannot resolve DNS names.' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg network.cause_no_egress 0
    network.cause_no_egress)
        [ "$#" -eq 0 ] || { s5_msg_contract_error network.cause_no_egress 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  原因：此服务器没有出站网络访问。' ;;
        en) printf '  Cause: this server has no outbound network access.' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg network.cause_external_service 0
    network.cause_external_service)
        [ "$#" -eq 0 ] || { s5_msg_contract_error network.cause_external_service 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  原因：固定的外部自检服务返回了 HTTP 错误；这不能证明代理本身有故障。' ;;
        en) printf '  Cause: the fixed external self-test service returned an HTTP error; this does not prove the proxy itself is faulty.' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg network.cause_proxy_refused 0
    network.cause_proxy_refused)
        [ "$#" -eq 0 ] || { s5_msg_contract_error network.cause_proxy_refused 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  原因：出站网络正常，因此是代理本身拒绝了请求。' ;;
        en) printf '  Cause: outbound network works, so the proxy itself refused the request.' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg network.cause_check_sgp 0
    network.cause_check_sgp)
        [ "$#" -eq 0 ] || { s5_msg_contract_error network.cause_check_sgp 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  如果客户端也无法访问该端口，请检查你的云安全组。' ;;
        en) printf '  If clients also cannot reach the port, check your cloud security group.' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg network.cause_unknown 0
    network.cause_unknown)
        [ "$#" -eq 0 ] || { s5_msg_contract_error network.cause_unknown 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '  原因：无法确定。' ;;
        en) printf '  Cause: undetermined.' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg service.reload_failed 1
    service.reload_failed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error service.reload_failed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '写入 %s 后无法重新加载 systemd 管理器' "${1}" ;;
        en) printf 'could not reload the systemd manager after writing %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg service.enable_failed 1
    service.enable_failed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error service.enable_failed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法启用 %s.service' "${1}" ;;
        en) printf 'could not enable %s.service' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg service.rcupdate_failed 1
    service.rcupdate_failed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error service.rcupdate_failed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法将 %s 加入默认运行级别' "${1}" ;;
        en) printf 'could not add %s to the default runlevel' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg service.unsupported_init 1
    service.unsupported_init)
        [ "$#" -eq 1 ] || { s5_msg_contract_error service.unsupported_init 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '不支持的 init 系统：%s' "${1}" ;;
        en) printf 'unsupported init system: %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg service.disable_failed 1
    service.disable_failed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error service.disable_failed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法禁用 %s.service' "${1}" ;;
        en) printf 'could not disable %s.service' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg service.rcdel_failed 1
    service.rcdel_failed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error service.rcdel_failed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法将 %s 从默认运行级别移除' "${1}" ;;
        en) printf 'could not remove %s from the default runlevel' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg service.wait_no_probe 1
    service.wait_no_probe)
        [ "$#" -eq 1 ] || { s5_msg_contract_error service.wait_no_probe 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法验证端口 %s 正在监听（找不到 ss 和 netstat）' "${1}" ;;
        en) printf 'cannot verify that port %s is listening (neither ss nor netstat found)' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg service.wait_exited 1
    service.wait_exited)
        [ "$#" -eq 1 ] || { s5_msg_contract_error service.wait_exited 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '服务在端口 %s 开始监听前已退出' "${1}" ;;
        en) printf 'the service exited before port %s was listening' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg service.wait_timeout 1
    service.wait_timeout)
        [ "$#" -eq 1 ] || { s5_msg_contract_error service.wait_timeout 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '服务未能在 15 秒内开始在端口 %s 上监听' "${1}" ;;
        en) printf 'the service did not begin listening on port %s within 15 seconds' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg install.user_appeared 1
    install.user_appeared)
        [ "$#" -eq 1 ] || { s5_msg_contract_error install.user_appeared 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '%s 账户在冲突检查之后出现；拒绝收养它' "${1}" ;;
        en) printf 'the %s account appeared after the collision check; refusing to adopt it' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg install.group_appeared 1
    install.group_appeared)
        [ "$#" -eq 1 ] || { s5_msg_contract_error install.group_appeared 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '%s 组在冲突检查之后出现；拒绝收养它' "${1}" ;;
        en) printf 'the %s group appeared after the collision check; refusing to adopt it' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg install.acct_exists_unknown 0
    install.acct_exists_unknown)
        [ "$#" -eq 0 ] || { s5_msg_contract_error install.acct_exists_unknown 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法确定服务账户是否存在' ;;
        en) printf 'could not determine whether the service account exists' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg install.grp_exists_unknown 0
    install.grp_exists_unknown)
        [ "$#" -eq 0 ] || { s5_msg_contract_error install.grp_exists_unknown 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法确定服务组是否存在' ;;
        en) printf 'could not determine whether the service group exists' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg install.uid_unknown 0
    install.uid_unknown)
        [ "$#" -eq 0 ] || { s5_msg_contract_error install.uid_unknown 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法确定分配给新账户的 uid' ;;
        en) printf 'could not determine the uid assigned to the new account' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg install.gid_unknown 0
    install.gid_unknown)
        [ "$#" -eq 0 ] || { s5_msg_contract_error install.gid_unknown 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法确定分配给新组的 gid' ;;
        en) printf 'could not determine the gid assigned to the new group' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg install.pkg_meta_failed 0
    install.pkg_meta_failed)
        [ "$#" -eq 0 ] || { s5_msg_contract_error install.pkg_meta_failed 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '软件包元数据更新失败；拒绝使用过期索引安装' ;;
        en) printf 'package metadata update failed; refusing to install from stale indexes' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg install.pkg_install_failed 0
    install.pkg_install_failed)
        [ "$#" -eq 0 ] || { s5_msg_contract_error install.pkg_install_failed 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '软件包安装失败' ;;
        en) printf 'package installation failed' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg install.pkg_unknown 1
    install.pkg_unknown)
        [ "$#" -eq 1 ] || { s5_msg_contract_error install.pkg_unknown 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '未知的包管理器：%s' "${1}" ;;
        en) printf 'unknown package manager: %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;

    # @s5-msg build.rm_refuse_empty 0
    build.rm_refuse_empty)
        [ "$#" -eq 0 ] || { s5_msg_contract_error build.rm_refuse_empty 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '拒绝删除临时目录：<empty>' ;;
        en) printf 'refusing to remove temporary directory: <empty>' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg build.rm_failed 1
    build.rm_failed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error build.rm_failed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法删除临时目录 %s' "${1}" ;;
        en) printf 'could not remove temporary directory %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg build.rm_still_exists 1
    build.rm_still_exists)
        [ "$#" -eq 1 ] || { s5_msg_contract_error build.rm_still_exists 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '删除后临时目录仍然存在：%s' "${1}" ;;
        en) printf 'temporary directory still exists after removal: %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg build.rm_unexpected 1
    build.rm_unexpected)
        [ "$#" -eq 1 ] || { s5_msg_contract_error build.rm_unexpected 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '拒绝删除非预期的临时目录：%s' "${1}" ;;
        en) printf 'refusing to remove unexpected temporary directory: %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg build.tmp_in_prefix 0
    build.tmp_in_prefix)
        [ "$#" -eq 0 ] || { s5_msg_contract_error build.tmp_in_prefix 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法在安装前缀目录中创建临时文件' ;;
        en) printf 'cannot create a temporary file in the install prefix' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg build.copy_failed 0
    build.copy_failed)
        [ "$#" -eq 0 ] || { s5_msg_contract_error build.copy_failed 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法将已验证的二进制复制到安装位置' ;;
        en) printf 'cannot copy the verified binary to the install location' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg build.install_failed 1
    build.install_failed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error build.install_failed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法在 %s 安装二进制' "${1}" ;;
        en) printf 'cannot install the binary at %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg build.mktmpdir_failed 0
    build.mktmpdir_failed)
        [ "$#" -eq 0 ] || { s5_msg_contract_error build.mktmpdir_failed 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法创建下载临时目录' ;;
        en) printf 'cannot create a download temporary directory' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg asset.unsupported 2
    asset.unsupported)
        [ "$#" -eq 2 ] || { s5_msg_contract_error asset.unsupported 2 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '没有适用于 %s/%s 的预编译引擎' "${1}" "${2}" ;;
        en) printf 'no prebuilt engine is available for %s/%s' "${1}" "${2}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg asset.metadata_invalid 1
    asset.metadata_invalid)
        [ "$#" -eq 1 ] || { s5_msg_contract_error asset.metadata_invalid 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '预编译资产元数据无效：%s' "${1}" ;;
        en) printf 'invalid prebuilt asset metadata: %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg asset.fetching 2
    asset.fetching)
        [ "$#" -eq 2 ] || { s5_msg_contract_error asset.fetching 2 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '正在下载已验证的 %s（发布 %s）' "${1}" "${2}" ;;
        en) printf 'downloading verified %s (release %s)' "${1}" "${2}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg asset.download_failed 1
    asset.download_failed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error asset.download_failed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '下载预编译引擎失败：%s' "${1}" ;;
        en) printf 'failed to download the prebuilt engine: %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg asset.size_mismatch 2
    asset.size_mismatch)
        [ "$#" -eq 2 ] || { s5_msg_contract_error asset.size_mismatch 2 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '预编译引擎大小校验失败：期望 %s 字节，实际 %s 字节' "${1}" "${2}" ;;
        en) printf 'prebuilt engine size check failed: expected %s bytes, got %s bytes' "${1}" "${2}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg asset.checksum_mismatch 1
    asset.checksum_mismatch)
        [ "$#" -eq 1 ] || { s5_msg_contract_error asset.checksum_mismatch 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '预编译引擎 SHA-256 校验失败：%s' "${1}" ;;
        en) printf 'prebuilt engine SHA-256 verification failed: %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg asset.installed_checksum_mismatch 1
    asset.installed_checksum_mismatch)
        [ "$#" -eq 1 ] || { s5_msg_contract_error asset.installed_checksum_mismatch 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '安装后的二进制 SHA-256 校验失败：%s' "${1}" ;;
        en) printf 'installed binary SHA-256 verification failed: %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg asset.verified 1
    asset.verified)
        [ "$#" -eq 1 ] || { s5_msg_contract_error asset.verified 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '预编译引擎已通过 SHA-256 校验：%s' "${1}" ;;
        en) printf 'prebuilt engine passed SHA-256 verification: %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg build.no_artifact 0
    build.no_artifact)
        [ "$#" -eq 0 ] || { s5_msg_contract_error build.no_artifact 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '下载未产生常规的 3proxy 二进制文件' ;;
        en) printf 'download produced no regular 3proxy binary' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg build.installed 1
    build.installed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error build.installed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '已安装 %s' "${1}" ;;
        en) printf 'installed %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg render.cfg_bad_port 0
    render.cfg_bad_port)
        [ "$#" -eq 0 ] || { s5_msg_contract_error render.cfg_bad_port 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法渲染配置：端口无效' ;;
        en) printf 'cannot render configuration: invalid port' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg render.cfg_bad_username 0
    render.cfg_bad_username)
        [ "$#" -eq 0 ] || { s5_msg_contract_error render.cfg_bad_username 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法渲染配置：用户名无效' ;;
        en) printf 'cannot render configuration: invalid username' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg render.users_bad_username 0
    render.users_bad_username)
        [ "$#" -eq 0 ] || { s5_msg_contract_error render.users_bad_username 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '拒绝渲染凭据：用户名无效' ;;
        en) printf 'refusing to render credentials: username is not valid' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg render.users_bad_password 0
    render.users_bad_password)
        [ "$#" -eq 0 ] || { s5_msg_contract_error render.users_bad_password 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '拒绝渲染凭据：密码无效' ;;
        en) printf 'refusing to render credentials: password is not valid' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg account.group_create_failed 1
    account.group_create_failed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error account.group_create_failed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '创建 %s 组失败' "${1}" ;;
        en) printf 'failed to create the %s group' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg account.group_exists_unknown 1
    account.group_exists_unknown)
        [ "$#" -eq 1 ] || { s5_msg_contract_error account.group_exists_unknown 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法确定 %s 组是否存在' "${1}" ;;
        en) printf 'could not determine whether the %s group exists' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg account.user_create_failed 1
    account.user_create_failed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error account.user_create_failed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '创建 %s 账户失败' "${1}" ;;
        en) printf 'failed to create the %s account' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg static.not_found 1
    static.not_found)
        [ "$#" -eq 1 ] || { s5_msg_contract_error static.not_found 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '静态检查：找不到配置：%s' "${1}" ;;
        en) printf 'static check: configuration not found: %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg static.missing_log 0
    static.missing_log)
        [ "$#" -eq 0 ] || { s5_msg_contract_error static.missing_log 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf "静态检查：缺少 'log'" ;;
        en) printf "static check: missing 'log'" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg static.missing_auth_strong 0
    static.missing_auth_strong)
        [ "$#" -eq 0 ] || { s5_msg_contract_error static.missing_auth_strong 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf "静态检查：缺少 'auth strong'" ;;
        en) printf "static check: missing 'auth strong'" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg static.one_flush 0
    static.one_flush)
        [ "$#" -eq 0 ] || { s5_msg_contract_error static.one_flush 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '静态检查：应恰好有一个 flush 指令' ;;
        en) printf 'static check: expected exactly one flush directive' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg static.missing_allow_connect 0
    static.missing_allow_connect)
        [ "$#" -eq 0 ] || { s5_msg_contract_error static.missing_allow_connect 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf "静态检查：缺少显式的 'allow ... CONNECT' 规则" ;;
        en) printf "static check: missing an explicit 'allow ... CONNECT' rule" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg static.one_terminal_deny 0
    static.one_terminal_deny)
        [ "$#" -eq 0 ] || { s5_msg_contract_error static.one_terminal_deny 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '静态检查：应恰好有一个终端 deny' ;;
        en) printf 'static check: expected exactly one terminal deny' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg static.missing_socks_line 0
    static.missing_socks_line)
        [ "$#" -eq 0 ] || { s5_msg_contract_error static.missing_socks_line 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf "静态检查：缺少 'socks -4 -u2 -p<端口> -i<地址>'" ;;
        en) printf "static check: missing 'socks -4 -u2 -p<port> -i<address>'" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg static.one_credentials_include 0
    static.one_credentials_include)
        [ "$#" -eq 0 ] || { s5_msg_contract_error static.one_credentials_include 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '静态检查：应恰好有一个凭据包含' ;;
        en) printf 'static check: expected exactly one credentials include' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg static.one_socks_line 2
    static.one_socks_line)
        [ "$#" -eq 2 ] || { s5_msg_contract_error static.one_socks_line 2 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '静态检查：应恰好有一行 socks -4 -u2 -p%s -i%s' "${1}" "${2}" ;;
        en) printf 'static check: expected exactly one socks -4 -u2 -p%s -i%s line' "${1}" "${2}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg static.one_allow_rule 1
    static.one_allow_rule)
        [ "$#" -eq 1 ] || { s5_msg_contract_error static.one_allow_rule 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '静态检查：应恰好有一条 allow %s * * * CONNECT 规则' "${1}" ;;
        en) printf 'static check: expected exactly one allow %s * * * CONNECT rule' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg static.flush_before_deny 0
    static.flush_before_deny)
        [ "$#" -eq 0 ] || { s5_msg_contract_error static.flush_before_deny 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '静态检查：flush 必须位于所有目标 deny 规则之前' ;;
        en) printf 'static check: flush must precede all destination deny rules' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg static.deny_after_allow 0
    static.deny_after_allow)
        [ "$#" -eq 0 ] || { s5_msg_contract_error static.deny_after_allow 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '静态检查：终端 deny 必须位于 allow 规则之后' ;;
        en) printf 'static check: terminal deny must follow the allow rule' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg static.missing_deny_rules 1
    static.missing_deny_rules)
        [ "$#" -eq 1 ] || { s5_msg_contract_error static.missing_deny_rules 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '静态检查：缺少目标 deny 规则：%s' "${1}" ;;
        en) printf 'static check: missing destination deny rule(s):%s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg static.no_deny_rules 0
    static.no_deny_rules)
        [ "$#" -eq 0 ] || { s5_msg_contract_error static.no_deny_rules 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '静态检查：未找到任何目标 deny 规则' ;;
        en) printf 'static check: no destination deny rules found' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg static.deny_before_allow 0
    static.deny_before_allow)
        [ "$#" -eq 0 ] || { s5_msg_contract_error static.deny_before_allow 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '静态检查：目标 deny 规则必须位于 allow 规则之前' ;;
        en) printf 'static check: destination deny rules must precede the allow rule' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg static.deny_count 2
    static.deny_count)
        [ "$#" -eq 2 ] || { s5_msg_contract_error static.deny_count 2 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '静态检查：应有 %s 条目标 deny 规则，实际 %s 条' "${1}" "${2}" ;;
        en) printf 'static check: expected %s destination deny rules, found %s' "${1}" "${2}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg static.socks_count 1
    static.socks_count)
        [ "$#" -eq 1 ] || { s5_msg_contract_error static.socks_count 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '静态检查：应恰好有一行 socks 服务行，实际 %s 行' "${1}" ;;
        en) printf 'static check: expected exactly one socks service line, found %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg static.forbidden_directive 1
    static.forbidden_directive)
        [ "$#" -eq 1 ] || { s5_msg_contract_error static.forbidden_directive 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '静态检查：出现禁止的指令：%s' "${1}" ;;
        en) printf 'static check: forbidden directive present: %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg static.weak_auth 0
    static.weak_auth)
        [ "$#" -eq 0 ] || { s5_msg_contract_error static.weak_auth 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '静态检查：出现弱认证指令' ;;
        en) printf 'static check: weak authentication directive present' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg static.forbidden_op 0
    static.forbidden_op)
        [ "$#" -eq 0 ] || { s5_msg_contract_error static.forbidden_op 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '静态检查：出现禁止的操作（BIND 或 UDPASSOC）' ;;
        en) printf 'static check: forbidden operation present (BIND or UDPASSOC)' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg static.cred_not_regular 0
    static.cred_not_regular)
        [ "$#" -eq 0 ] || { s5_msg_contract_error static.cred_not_regular 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '静态检查：凭据文件必须是常规文件且不能是符号链接' ;;
        en) printf 'static check: credentials file must be a regular non-symbolic-link file' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg static.cred_mode 1
    static.cred_mode)
        [ "$#" -eq 1 ] || { s5_msg_contract_error static.cred_mode 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '静态检查：凭据文件必须是 0600 或 0640 模式，实际为 %s' "${1}" ;;
        en) printf 'static check: credentials file must be mode 0600 or 0640, found %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg static.cred_owner 2
    static.cred_owner)
        [ "$#" -eq 2 ] || { s5_msg_contract_error static.cred_owner 2 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '静态检查：凭据文件的属主必须是 root:%s，实际为 %s' "${1}" "${2}" ;;
        en) printf 'static check: credentials file must be owned by root:%s, found %s' "${1}" "${2}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg static.cred_unreadable 0
    static.cred_unreadable)
        [ "$#" -eq 0 ] || { s5_msg_contract_error static.cred_unreadable 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '静态检查：无法读取凭据文件' ;;
        en) printf 'static check: cannot read credentials file' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg static.cred_one_line 0
    static.cred_one_line)
        [ "$#" -eq 0 ] || { s5_msg_contract_error static.cred_one_line 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '静态检查：凭据文件必须恰好包含所配置用户名的一条凭据' ;;
        en) printf 'static check: credentials file must contain exactly one credential for the configured username' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;

    # @s5-msg fs.write_symlink 1
    fs.write_symlink)
        [ "$#" -eq 1 ] || { s5_msg_contract_error fs.write_symlink 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '拒绝写入 %s：它是符号链接' "${1}" ;;
        en) printf 'refusing to write %s: it is a symbolic link' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg fs.write_not_regular 1
    fs.write_not_regular)
        [ "$#" -eq 1 ] || { s5_msg_contract_error fs.write_not_regular 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '拒绝写入 %s：不是普通文件' "${1}" ;;
        en) printf 'refusing to write %s: not a regular file' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg fs.write_mode0600 1
    fs.write_mode0600)
        [ "$#" -eq 1 ] || { s5_msg_contract_error fs.write_mode0600 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法将 %s 设置为 0600 模式' "${1}" ;;
        en) printf 'cannot set mode 0600 on %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg fs.use_symlink 1
    fs.use_symlink)
        [ "$#" -eq 1 ] || { s5_msg_contract_error fs.use_symlink 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '拒绝使用 %s：它是符号链接' "${1}" ;;
        en) printf 'refusing to use %s: it is a symbolic link' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg fs.use_not_dir 1
    fs.use_not_dir)
        [ "$#" -eq 1 ] || { s5_msg_contract_error fs.use_not_dir 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '拒绝使用 %s：它不是目录' "${1}" ;;
        en) printf 'refusing to use %s: it is not a directory' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg fs.create_failed 1
    fs.create_failed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error fs.create_failed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法创建 %s' "${1}" ;;
        en) printf 'cannot create %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg fs.restrict_0700 1
    fs.restrict_0700)
        [ "$#" -eq 1 ] || { s5_msg_contract_error fs.restrict_0700 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法将 %s 限制为 0700 模式' "${1}" ;;
        en) printf 'cannot restrict %s to mode 0700' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg fs.atomic_dir_missing 2
    fs.atomic_dir_missing)
        [ "$#" -eq 2 ] || { s5_msg_contract_error fs.atomic_dir_missing 2 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法写入 %s：目录 %s 不存在' "${1}" "${2}" ;;
        en) printf 'cannot write %s: directory %s does not exist' "${1}" "${2}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg fs.atomic_symlink 1
    fs.atomic_symlink)
        [ "$#" -eq 1 ] || { s5_msg_contract_error fs.atomic_symlink 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '拒绝写入 %s：它是符号链接' "${1}" ;;
        en) printf 'refusing to write %s: it is a symbolic link' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg fs.atomic_mktemp_failed 1
    fs.atomic_mktemp_failed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error fs.atomic_mktemp_failed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法在 %s 中创建临时文件' "${1}" ;;
        en) printf 'cannot create a temporary file in %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg fs.atomic_write_tmp 1
    fs.atomic_write_tmp)
        [ "$#" -eq 1 ] || { s5_msg_contract_error fs.atomic_write_tmp 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法写入 %s' "${1}" ;;
        en) printf 'cannot write %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg fs.atomic_install 1
    fs.atomic_install)
        [ "$#" -eq 1 ] || { s5_msg_contract_error fs.atomic_install 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法安装 %s' "${1}" ;;
        en) printf 'cannot install %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg fs.atomic_mode 2
    fs.atomic_mode)
        [ "$#" -eq 2 ] || { s5_msg_contract_error fs.atomic_mode 2 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法对 %s 设置模式 %s' "${2}" "${1}" ;;
        en) printf 'cannot set mode %s on %s' "${1}" "${2}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg fs.atomic_owner 2
    fs.atomic_owner)
        [ "$#" -eq 2 ] || { s5_msg_contract_error fs.atomic_owner 2 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法对 %s 设置属主 %s' "${2}" "${1}" ;;
        en) printf 'cannot set ownership %s on %s' "${1}" "${2}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg state.disallowed_char 1
    state.disallowed_char)
        [ "$#" -eq 1 ] || { s5_msg_contract_error state.disallowed_char 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf "state：'%s' 的值包含不允许的字符" "${1}" ;;
        en) printf "state: value for '%s' contains a disallowed character" "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg state.flag_not_1 1
    state.flag_not_1)
        [ "$#" -eq 1 ] || { s5_msg_contract_error state.flag_not_1 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf "state：标志 '%s' 必须恰好为 1" "${1}" ;;
        en) printf "state: flag '%s' must be exactly 1" "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg state.port_not_numeric 0
    state.port_not_numeric)
        [ "$#" -eq 0 ] || { s5_msg_contract_error state.port_not_numeric 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf 'state：端口不是数字' ;;
        en) printf 'state: port is not numeric' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg state.port_leading_zero 0
    state.port_leading_zero)
        [ "$#" -eq 0 ] || { s5_msg_contract_error state.port_leading_zero 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf 'state：端口不能有前导零' ;;
        en) printf 'state: port must not have leading zeros' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg state.port_out_of_range 0
    state.port_out_of_range)
        [ "$#" -eq 0 ] || { s5_msg_contract_error state.port_out_of_range 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf 'state：端口超出范围' ;;
        en) printf 'state: port out of range' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg state.username_invalid 0
    state.username_invalid)
        [ "$#" -eq 0 ] || { s5_msg_contract_error state.username_invalid 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf 'state：用户名无效' ;;
        en) printf 'state: username is not valid' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg state.listen_invalid 0
    state.listen_invalid)
        [ "$#" -eq 0 ] || { s5_msg_contract_error state.listen_invalid 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf 'state：监听地址无效' ;;
        en) printf 'state: listen address is not valid' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg state.origin_invalid 0
    state.origin_invalid)
        [ "$#" -eq 0 ] || { s5_msg_contract_error state.origin_invalid 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf 'state：安装来源无效' ;;
        en) printf 'state: install origin is invalid' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg state.asset_invalid 0
    state.asset_invalid)
        [ "$#" -eq 0 ] || { s5_msg_contract_error state.asset_invalid 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf 'state：预编译资产名称无效' ;;
        en) printf 'state: prebuilt asset name is invalid' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg state.sha256_invalid 0
    state.sha256_invalid)
        [ "$#" -eq 0 ] || { s5_msg_contract_error state.sha256_invalid 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf 'state：预编译资产 SHA-256 无效' ;;
        en) printf 'state: prebuilt asset SHA-256 is invalid' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg state.asset_mismatch 0
    state.asset_mismatch)
        [ "$#" -eq 0 ] || { s5_msg_contract_error state.asset_mismatch 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf 'state：预编译资产与记录的平台或 SHA-256 不一致' ;;
        en) printf 'state: prebuilt asset does not match the recorded platform or SHA-256' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg state.commit_len 0
    state.commit_len)
        [ "$#" -eq 0 ] || { s5_msg_contract_error state.commit_len 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf 'state：commit 必须恰好是 40 个十六进制字符' ;;
        en) printf 'state: commit must be exactly 40 hexadecimal characters' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg state.commit_not_hex 0
    state.commit_not_hex)
        [ "$#" -eq 0 ] || { s5_msg_contract_error state.commit_not_hex 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf 'state：commit 不是十六进制对象名' ;;
        en) printf 'state: commit is not a hex object name' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg state.unknown_init 1
    state.unknown_init)
        [ "$#" -eq 1 ] || { s5_msg_contract_error state.unknown_init 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf "state：未知的 init 系统 '%s'" "${1}" ;;
        en) printf "state: unknown init system '%s'" "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg state.not_numeric 1
    state.not_numeric)
        [ "$#" -eq 1 ] || { s5_msg_contract_error state.not_numeric 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf 'state：%s 必须是数字' "${1}" ;;
        en) printf 'state: %s must be numeric' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg state.unknown_status 1
    state.unknown_status)
        [ "$#" -eq 1 ] || { s5_msg_contract_error state.unknown_status 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf "state：未知状态 '%s'" "${1}" ;;
        en) printf "state: unknown status '%s'" "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg state.read_symlink 1
    state.read_symlink)
        [ "$#" -eq 1 ] || { s5_msg_contract_error state.read_symlink 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '拒绝读取 %s：它是符号链接' "${1}" ;;
        en) printf 'refusing to read %s: it is a symbolic link' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg state.read_not_regular 1
    state.read_not_regular)
        [ "$#" -eq 1 ] || { s5_msg_contract_error state.read_not_regular 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '拒绝读取 %s：不是普通文件' "${1}" ;;
        en) printf 'refusing to read %s: not a regular file' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg state.read_failed 1
    state.read_failed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error state.read_failed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法读取状态文件 %s' "${1}" ;;
        en) printf 'cannot read the state file %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg state.read_mode 2
    state.read_mode)
        [ "$#" -eq 2 ] || { s5_msg_contract_error state.read_mode 2 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '拒绝读取 %s：状态文件必须是 0600 模式（实际为 %s）' "${1}" "${2}" ;;
        en) printf 'refusing to read %s: state file must be mode 0600 (found %s)' "${1}" "${2}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg state.read_error 1
    state.read_error)
        [ "$#" -eq 1 ] || { s5_msg_contract_error state.read_error 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法读取状态文件 %s' "${1}" ;;
        en) printf 'could not read the state file %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg state.line_malformed 1
    state.line_malformed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error state.line_malformed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf 'state：第 %s 行格式错误（缺少字段分隔符）' "${1}" ;;
        en) printf 'state: line %s is malformed (no field separator)' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg state.unknown_key 2
    state.unknown_key)
        [ "$#" -eq 2 ] || { s5_msg_contract_error state.unknown_key 2 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf "state：第 %s 行出现未知键 '%s'" "${2}" "${1}" ;;
        en) printf "state: unknown key '%s' on line %s" "${1}" "${2}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg state.duplicate_key 2
    state.duplicate_key)
        [ "$#" -eq 2 ] || { s5_msg_contract_error state.duplicate_key 2 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf "state：第 %s 行出现重复键 '%s'" "${2}" "${1}" ;;
        en) printf "state: duplicate key '%s' on line %s" "${1}" "${2}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg state.corrupt 0
    state.corrupt)
        [ "$#" -eq 0 ] || { s5_msg_contract_error state.corrupt 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '状态文件已损坏；拒绝据此操作' ;;
        en) printf 'state file is corrupt; refusing to act on it' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg state.complete_missing 1
    state.complete_missing)
        [ "$#" -eq 1 ] || { s5_msg_contract_error state.complete_missing 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf 'state：声称已安装完成但缺少：%s' "${1}" ;;
        en) printf 'state: claims to be complete but is missing:%s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg state.mktemp_failed 1
    state.mktemp_failed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error state.mktemp_failed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法在 %s 中创建临时状态文件' "${1}" ;;
        en) printf 'cannot create a temporary state file in %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg state.write_failed 0
    state.write_failed)
        [ "$#" -eq 0 ] || { s5_msg_contract_error state.write_failed 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法写入状态文件' ;;
        en) printf 'cannot write the state file' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg state.install_failed 0
    state.install_failed)
        [ "$#" -eq 0 ] || { s5_msg_contract_error state.install_failed 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法安装状态文件' ;;
        en) printf 'cannot install the state file' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg state.record_unknown_key 1
    state.record_unknown_key)
        [ "$#" -eq 1 ] || { s5_msg_contract_error state.record_unknown_key 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf "state：拒绝记录未知键 '%s'" "${1}" ;;
        en) printf "state: refusing to record unknown key '%s'" "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg state.persist_failed 1
    state.persist_failed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error state.persist_failed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf "state：无法持久化 '%s'；中止以避免产生孤立资源" "${1}" ;;
        en) printf "state: could not persist '%s'; aborting to avoid orphaned resources" "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;

    # @s5-msg detect.unsupported_arch 1
    detect.unsupported_arch)
        [ "$#" -eq 1 ] || { s5_msg_contract_error detect.unsupported_arch 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '不支持此架构：%s（仅支持 x86_64/amd64 和 aarch64/arm64）' "${1}" ;;
        en) printf 'unsupported architecture: %s (only x86_64/amd64 and aarch64/arm64 are supported)' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg detect.cannot_read_osrelease 1
    detect.cannot_read_osrelease)
        [ "$#" -eq 1 ] || { s5_msg_contract_error detect.cannot_read_osrelease 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法读取 %s：不能识别此系统' "${1}" ;;
        en) printf 'cannot read %s: unable to identify this system' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg detect.no_probe_package 1
    detect.no_probe_package)
        [ "$#" -eq 1 ] || { s5_msg_contract_error detect.no_probe_package 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '没有适用于此包管理器的监听探测软件包：%s' "${1}" ;;
        en) printf 'no port-probe package for package manager: %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg detect.missing_commands 1
    detect.missing_commands)
        [ "$#" -eq 1 ] || { s5_msg_contract_error detect.missing_commands 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '缺少必需命令：%s' "${1}" ;;
        en) printf 'required command(s) not found:%s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg detect.no_base_utilities 0
    detect.no_base_utilities)
        [ "$#" -eq 0 ] || { s5_msg_contract_error detect.no_base_utilities 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '没有上述基础工具无法继续' ;;
        en) printf 'cannot continue without the base utilities listed above' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg detect.require_root 0
    detect.require_root)
        [ "$#" -eq 0 ] || { s5_msg_contract_error detect.require_root 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '安装需要 root 权限；请用 sudo 重新运行' ;;
        en) printf 'installation requires root privileges; re-run with sudo' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg detect.account_tools_missing 1
    detect.account_tools_missing)
        [ "$#" -eq 1 ] || { s5_msg_contract_error detect.account_tools_missing 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '缺少账户管理工具（%s 系列）；请安装后重试' "${1}" ;;
        en) printf 'account-management tools for %s are missing; install them and retry' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg detect.no_replace_primitive 0
    detect.no_replace_primitive)
        [ "$#" -eq 0 ] || { s5_msg_contract_error detect.no_replace_primitive 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '此主机或目标文件系统不支持使用 ln -T 的免替换创建' ;;
        en) printf 'this host or target filesystem does not support no-replace creation with ln -T' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg detect.pkgmgr_missing 1
    detect.pkgmgr_missing)
        [ "$#" -eq 1 ] || { s5_msg_contract_error detect.pkgmgr_missing 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '检测到的包管理器（%s）未安装在此系统上' "${1}" ;;
        en) printf 'the detected package manager (%s) is not installed on this system' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg detect.pkgmgr_missing_hint 0
    detect.pkgmgr_missing_hint)
        [ "$#" -eq 0 ] || { s5_msg_contract_error detect.pkgmgr_missing_hint 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '请安装它，或使用受支持的镜像后重试' ;;
        en) printf 'install it, or use a supported image, then retry' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg input.port_not_decimal 0
    input.port_not_decimal)
        [ "$#" -eq 0 ] || { s5_msg_contract_error input.port_not_decimal 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '端口必须是十进制数字' ;;
        en) printf 'port must be a decimal number' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg input.random_chars_failed 2
    input.random_chars_failed)
        [ "$#" -eq 2 ] || { s5_msg_contract_error input.random_chars_failed 2 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法从 /dev/urandom 读取 %s 个随机字符（实际得到 %s）' "${1}" "${2}" ;;
        en) printf 'could not draw %s random characters from /dev/urandom (got %s)' "${1}" "${2}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg input.random_int_range 1
    input.random_int_range)
        [ "$#" -eq 1 ] || { s5_msg_contract_error input.random_int_range 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf 's5_random_int：count 超出支持范围：%s' "${1}" ;;
        en) printf 's5_random_int: count out of supported range: %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg network.no_probe_cmd 0
    network.no_probe_cmd)
        [ "$#" -eq 0 ] || { s5_msg_contract_error network.no_probe_cmd 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法确定端口是否空闲（找不到 ss 和 netstat）' ;;
        en) printf 'cannot determine whether a port is free (neither ss nor netstat found)' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg network.no_probe_hint 0
    network.no_probe_hint)
        [ "$#" -eq 0 ] || { s5_msg_contract_error network.no_probe_hint 0 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '请安装 iproute2（提供 ss）或 net-tools（提供 netstat）后重试' ;;
        en) printf 'install iproute2 (for ss) or net-tools (for netstat), then retry' ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg network.port_free_unknown 1
    network.port_free_unknown)
        [ "$#" -eq 1 ] || { s5_msg_contract_error network.port_free_unknown 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法确定端口 %s 是否空闲（找不到 ss 和 netstat）' "${1}" ;;
        en) printf 'cannot determine whether port %s is free (neither ss nor netstat found)' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg network.port_probe_cmd_failed 2
    network.port_probe_cmd_failed)
        [ "$#" -eq 2 ] || { s5_msg_contract_error network.port_probe_cmd_failed 2 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法确定端口 %s 是否空闲：%s 失败' "${1}" "${2}" ;;
        en) printf 'cannot determine whether port %s is free: %s failed' "${1}" "${2}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg network.random_port_probe_failed 1
    network.random_port_probe_failed)
        [ "$#" -eq 1 ] || { s5_msg_contract_error network.random_port_probe_failed 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '无法确定端口 %s 是否空闲：监听状态探测失败' "${1}" ;;
        en) printf 'cannot determine whether port %s is free: the listen-state probe failed' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg network.no_free_port 2
    network.no_free_port)
        [ "$#" -eq 2 ] || { s5_msg_contract_error network.no_free_port 2 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '在 %s-%s 范围内尝试 50 次后仍未找到空闲端口' "${1}" "${2}" ;;
        en) printf 'no free port found in %s-%s after 50 attempts' "${1}" "${2}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;
    # @s5-msg selftest.interrupted 1
    selftest.interrupted)
        [ "$#" -eq 1 ] || { s5_msg_contract_error selftest.interrupted 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '被 SIG%s 中断；正在清理' "${1}" ;;
        en) printf 'interrupted by SIG%s; cleaning up' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;

    # @s5-msg input.log_random_username 1
    input.log_random_username)
        [ "$#" -eq 1 ] || { s5_msg_contract_error input.log_random_username 1 "$#"; return 1; }
        case "$S5_LANG" in
        zh) printf '已生成随机用户名 %s' "${1}" ;;
        en) printf 'generated random username %s' "${1}" ;;
        *) s5_msg_locale_error; return 1 ;;
        esac
        ;;

    *)
        printf 's5: internal message error: unknown key %s\n' "$_s5_i18n_key" >&2
        return 1
        ;;
    esac
    _s5_i18n_key=''
    return 0
}

# Contract failures are fixed bilingual text naming only the key and the
# expected/received counts. Argument values are never printed: any of them
# may carry a credential.
s5_msg_contract_error() {
    printf 's5: internal message error: key %s expects %s arguments, got %s\n' \
        "$1" "$2" "$3" >&2
    printf 's5: 内部消息错误：键 %s 需要 %s 个参数，实际 %s 个\n' \
        "$1" "$2" "$3" >&2
    _s5_i18n_key=''
    return 0
}

s5_msg_locale_error() {
    printf 's5: internal message error: no language selected\n' >&2
    printf 's5: 内部消息错误：未选择语言\n' >&2
    _s5_i18n_key=''
    return 0
}

# Keyed channel adapters: same channels, prefixes, redaction and sink as the
# raw wrappers above. Callers pass a literal key plus that key's data.
s5_log_msg() {
    _s5_i18n_text=$(s5_msg "$@") || { _s5_i18n_text=''; return 1; }
    s5_log "$_s5_i18n_text"
    _s5_i18n_text=''
}

s5_warn_msg() {
    _s5_i18n_text=$(s5_msg "$@") || { _s5_i18n_text=''; return 1; }
    s5_warn "$_s5_i18n_text"
    _s5_i18n_text=''
}

s5_err_msg() {
    _s5_i18n_text=$(s5_msg "$@") || { _s5_i18n_text=''; return 1; }
    s5_err "$_s5_i18n_text"
    _s5_i18n_text=''
}

s5_say_msg() {
    _s5_i18n_text=$(s5_msg "$@") || { _s5_i18n_text=''; return 1; }
    s5_say "$_s5_i18n_text"
    _s5_i18n_text=''
}

# Prompts render to stderr without a newline, like the raw prompt printf
# sites, so stdout stays clean for piped/redirected operation.
s5_prompt_msg() {
    _s5_i18n_text=$(s5_msg "$@") || { _s5_i18n_text=''; return 1; }
    printf '%s' "$_s5_i18n_text" >&2
    _s5_i18n_text=''
}

# ---------------------------------------------------------------------------
# Language selection.
#
# s5_main calls this once per invocation, before any command dispatch: blank
# or 1 selects Chinese, 2 selects English, anything else re-prompts (bounded,
# like every other prompt), EOF fails without dispatching. The prompt is
# bilingual by necessity -- no locale exists until the operator answers. The
# choice lives only in S5_LANG for this process: it is never exported,
# persisted, or written to state.
# ---------------------------------------------------------------------------
s5_select_language() {
    _sla=0
    while [ "$_sla" -lt 5 ]; do
        _sla=$((_sla + 1))
        printf '请选择语言 / Please select language:\n' >&2
        printf '  1. 中文\n' >&2
        printf '  2. English\n' >&2
        printf '请选择 [1-2，默认 1] / Select [1-2, default 1]: ' >&2
        _slin=''
        if ! read -r _slin; then
            printf '\n' >&2
            printf '未选择语言，退出 / No language selected, exiting\n' >&2
            _slin=''
            return 1
        fi
        case "$_slin" in
        '' | 1)
            S5_LANG=zh
            _slin=''
            return 0
            ;;
        2)
            S5_LANG=en
            _slin=''
            return 0
            ;;
        *)
            printf '无效选择，请输入 1 或 2 / Invalid choice, enter 1 or 2\n' >&2
            ;;
        esac
    done
    printf '无效输入次数过多，退出 / Too many invalid entries, exiting\n' >&2
    _slin=''
    return 1
}

# s5_modelog <label> <path> : record an observed mode. Test mode only; this is
# how the regression tests observe that a secret file is 0600 at write time and
# that the config directory is never briefly group/world readable.
s5_modelog() {
    if [ -n "${S5_TMPMODE_LOG:-}" ]; then
        printf '%s %s\n' "$1" "$(stat -c '%a' "$2" 2>/dev/null || printf 'unknown')" \
            >>"$S5_TMPMODE_LOG"
    fi
}

# ---------------------------------------------------------------------------
# Signal traps and cleanup.
# ---------------------------------------------------------------------------

S5_ROLLBACK_ARMED=0
S5_RECONFIG_ARMED=0
S5_INSTALL_COMPLETE=0
S5_WORKDIR=''
S5_FETCH_READER_PID=''
S5_PENDING_CLAIM_PATH=''
S5_PENDING_CLAIM_KIND=''
S5_PENDING_CLAIM_ID=''
S5_PENDING_CLAIM_TEMP=''
S5_STATE_DIR_CLAIM_ID=''
S5_STATE_FILE_CLAIM_ID=''
S5_CREATED_ACCOUNT_UID=''
S5_CREATED_ACCOUNT_GID=''
# Set the instant a principal exists, before its numeric id is read. The id is
# the fingerprint that makes removal safe against name reuse, but it is read
# AFTER the create tool returns, so a failed read used to leave a principal on
# the host with nothing at all recording that this run made it.
S5_CREATED_USER_NAMED=0
S5_CREATED_GROUP_NAMED=0
S5_ACCOUNT_UID=''
S5_ACCOUNT_GID=''
S5_CLAIM_PREFIX_ID=''
S5_CLAIM_BIN_ID=''
S5_CLAIM_CONFDIR_ID=''
S5_CLAIM_USERS_ID=''
S5_CLAIM_CFG_ID=''
S5_CLAIM_UNIT_ID=''
S5_CLAIM_INITSCRIPT_ID=''
S5_IN_CLEANUP=0
S5_LOCK_HELD=0
S5_LOCK_TOKEN=''

# s5_fetch_reader_stop : terminate and reap the private bounded-download reader.
s5_fetch_reader_stop() {
    if [ -z "$S5_FETCH_READER_PID" ]; then
        return 0
    fi
    kill "$S5_FETCH_READER_PID" 2>/dev/null || true
    wait "$S5_FETCH_READER_PID" 2>/dev/null || true
    S5_FETCH_READER_PID=''
    return 0
}

# s5_cleanup : idempotent. Removes a download tree, restores an interrupted
# reconfiguration, rolls back an incomplete install, then releases the lock.
s5_cleanup() {
    if [ "$S5_IN_CLEANUP" = "1" ]; then
        return 0
    fi
    S5_IN_CLEANUP=1
    _clbad=0

    s5_fetch_reader_stop

    if [ -n "$S5_WORKDIR" ]; then
        if s5_rm_workdir "$S5_WORKDIR"; then
            S5_WORKDIR=''
        else
            _clbad=1
        fi
    fi

    if [ -n "$S5_PENDING_CLAIM_PATH" ]; then
        s5_pending_claim_remove || _clbad=1
    fi

    if [ -n "$S5_CREATED_ACCOUNT_UID" ] || [ -n "$S5_CREATED_ACCOUNT_GID" ] ||
        [ "$S5_CREATED_USER_NAMED" = "1" ] || [ "$S5_CREATED_GROUP_NAMED" = "1" ]; then
        s5_pending_account_remove || _clbad=1
    fi

    if [ "$S5_RECONFIG_ARMED" = "1" ]; then
        S5_RECONFIG_ARMED=0
        s5_reconfigure_recover_pending || _clbad=1
    fi

    if [ "$S5_ROLLBACK_ARMED" = "1" ] && [ "$S5_INSTALL_COMPLETE" != "1" ]; then
        S5_ROLLBACK_ARMED=0
        s5_rollback || true
    fi

    if [ "$S5_LOCK_HELD" = "1" ]; then
        s5_lock_release || _clbad=1
    fi

    S5_IN_CLEANUP=0
    return "${_clbad:-0}"
}

s5_on_signal() {
    # Block further HUP/INT/TERM for the duration of cleanup. s5_cleanup's
    # re-entrancy guard makes a nested call return immediately, and this handler
    # then runs `trap - EXIT; exit` -- from inside the still-executing first
    # cleanup. A second Ctrl-C during a multi-second rollback therefore abandoned
    # it half-done, left the /var/tmp download tree in place, and left the lock
    # directory behind. Idempotence is what the guard is for; not being
    # interrupted is what this trap is for.
    trap '' HUP INT TERM
    s5_warn_msg selftest.interrupted "$1"
    s5_cleanup
    trap - EXIT
    exit "$2"
}

s5_install_traps() {
    trap 's5_cleanup' EXIT
    trap 's5_on_signal HUP 129' HUP
    trap 's5_on_signal INT 130' INT
    trap 's5_on_signal TERM 143' TERM
}

# ---------------------------------------------------------------------------
# Detection: OS, version, architecture, init system, package manager,
# privileges, and dependencies.  Nothing here installs, escalates, or mutates.
# ---------------------------------------------------------------------------

S5_OSRELEASE=${S5_OSRELEASE:-/etc/os-release}
S5_OS_ID=''
S5_OS_VERSION_ID=''
S5_OS_ID_LIKE=''
S5_OS_FAMILY=''
S5_PKGMGR=''
S5_INIT=''
S5_ARCHNAME=''

# s5_osrel_get <file> <key> : print the unquoted value of a KEY=VALUE line.
# Implemented with sed rather than sourcing the file, so a hostile os-release
# cannot execute anything, and without eval.
s5_osrel_get() {
    if [ ! -r "$1" ]; then
        return 1
    fi
    sed -n "s/^$2=//p" "$1" | tail -n 1 | tr -d '\r' | \
        sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

# s5_ver_ge <a> <b> : true when dotted-numeric version a >= b.
s5_ver_ge() {
    _va=$1
    _vb=$2
    while [ -n "$_va" ] || [ -n "$_vb" ]; do
        if [ -n "$_va" ]; then
            _ca=${_va%%.*}
            case "$_ca" in
            '' | *[!0-9]*) return 2 ;;
            esac
        else
            _ca=0
        fi
        if [ -n "$_vb" ]; then
            _cb=${_vb%%.*}
            case "$_cb" in
            '' | *[!0-9]*) return 2 ;;
            esac
        else
            _cb=0
        fi
        _ca=${_ca#"${_ca%%[!0]*}"}
        _cb=${_cb#"${_cb%%[!0]*}"}
        if [ -z "$_ca" ]; then _ca=0; fi
        if [ -z "$_cb" ]; then _cb=0; fi
        if [ "${#_ca}" -gt 18 ] || [ "${#_cb}" -gt 18 ]; then
            return 2
        fi
        if [ "${#_ca}" -gt "${#_cb}" ]; then return 0; fi
        if [ "${#_ca}" -lt "${#_cb}" ]; then return 1; fi
        if [ "$_ca" != "$_cb" ]; then
            awk -v a="x$_ca" -v b="x$_cb" \
                'BEGIN { if (a == b) exit 0; if (a > b) exit 1; exit 2 }'
            _vcrc=$?
            case "$_vcrc" in
            1) return 0 ;;
            2) return 1 ;;
            *) ;;
            esac
        fi
        case "$_va" in
        *.*)
            _va=${_va#*.}
            [ -n "$_va" ] || return 2
            ;;
        *) _va='' ;;
        esac
        case "$_vb" in
        *.*)
            _vb=${_vb#*.}
            [ -n "$_vb" ] || return 2
            ;;
        *) _vb='' ;;
        esac
    done
    return 0
}

s5_map_arch() {
    case "$1" in
    x86_64 | amd64)
        printf 'amd64\n'
        return 0
        ;;
    aarch64 | arm64)
        printf 'arm64\n'
        return 0
        ;;
    *)
        s5_err_msg detect.unsupported_arch "$1"
        return "$EX_UNSUPPORTED"
        ;;
    esac
}

s5_select_engine_asset() {
    _sea_mode=${1:-runtime}
    case "$S5_OS_FAMILY:$S5_ARCHNAME" in
    debian:amd64 | el:amd64)
        S5_ASSET_NAME=$S5_ASSET_GLIBC_AMD64
        S5_ASSET_SHA256=$S5_ASSET_GLIBC_AMD64_SHA
        S5_ASSET_SIZE=$S5_ASSET_GLIBC_AMD64_SIZE
        ;;
    debian:arm64 | el:arm64)
        S5_ASSET_NAME=$S5_ASSET_GLIBC_ARM64
        S5_ASSET_SHA256=$S5_ASSET_GLIBC_ARM64_SHA
        S5_ASSET_SIZE=$S5_ASSET_GLIBC_ARM64_SIZE
        ;;
    alpine:amd64)
        S5_ASSET_NAME=$S5_ASSET_MUSL_AMD64
        S5_ASSET_SHA256=$S5_ASSET_MUSL_AMD64_SHA
        S5_ASSET_SIZE=$S5_ASSET_MUSL_AMD64_SIZE
        ;;
    alpine:arm64)
        S5_ASSET_NAME=$S5_ASSET_MUSL_ARM64
        S5_ASSET_SHA256=$S5_ASSET_MUSL_ARM64_SHA
        S5_ASSET_SIZE=$S5_ASSET_MUSL_ARM64_SIZE
        ;;
    *)
        s5_err_msg asset.unsupported "$S5_OS_FAMILY" "$S5_ARCHNAME"
        return "$EX_UNSUPPORTED"
        ;;
    esac
    if [ "$_sea_mode" = runtime ] && [ "${S5_TEST_MODE:-0}" = 1 ] &&
        { [ -n "${S5_TEST_ASSET_SHA256:-}" ] || [ -n "${S5_TEST_ASSET_SIZE:-}" ]; }; then
        if [ -z "${S5_TEST_ASSET_SHA256:-}" ] || [ -z "${S5_TEST_ASSET_SIZE:-}" ]; then
            s5_err_msg asset.metadata_invalid "$S5_ASSET_NAME"
            return 1
        fi
        S5_ASSET_SHA256=$S5_TEST_ASSET_SHA256
        S5_ASSET_SIZE=$S5_TEST_ASSET_SIZE
    fi
    if [ "${#S5_ASSET_SHA256}" -ne 64 ]; then
        s5_err_msg asset.metadata_invalid "$S5_ASSET_NAME"
        return 1
    fi
    case "$S5_ASSET_SHA256" in
    *[!0-9a-f]*) s5_err_msg asset.metadata_invalid "$S5_ASSET_NAME"; return 1 ;;
    esac
    case "$S5_ASSET_SIZE" in
    '' | *[!0-9]* | 0) s5_err_msg asset.metadata_invalid "$S5_ASSET_NAME"; return 1 ;;
    esac
    S5_ASSET_URL="$S5_ENGINE_BASE_URL/$S5_ASSET_NAME"
    return 0
}

# ID_LIKE is deliberately NEVER used to authorise an install.  RHEL, Rocky and
# AlmaLinux are recognised only so we can tell the operator they are likely
# compatible, and then refuse.
s5_detect_platform() {
    _dparch=${1:-}
    _osf=${S5_OSRELEASE:-/etc/os-release}
    S5_OS_ID=''
    S5_OS_VERSION_ID=''
    S5_OS_ID_LIKE=''
    S5_OS_FAMILY=''
    S5_PKGMGR=''
    S5_INIT=''
    case "$_dparch" in
    amd64 | arm64) ;;
    *)
        s5_err_msg detect.unsupported unknown unknown "${_dparch:-missing}"
        return "$EX_UNSUPPORTED"
        ;;
    esac
    if [ ! -r "$_osf" ]; then
        s5_err_msg detect.cannot_read_osrelease "$_osf"
        return "$EX_UNSUPPORTED"
    fi

    S5_OS_ID=$(s5_osrel_get "$_osf" ID)
    S5_OS_VERSION_ID=$(s5_osrel_get "$_osf" VERSION_ID)
    S5_OS_ID_LIKE=$(s5_osrel_get "$_osf" ID_LIKE)

    case "$S5_OS_ID" in
    ubuntu)
        if [ "$S5_OS_VERSION_ID:$_dparch" = 20.04:amd64 ] ||
            s5_ver_ge "$S5_OS_VERSION_ID" 22.04; then
            S5_OS_FAMILY=debian
            S5_PKGMGR=apt
            S5_INIT=systemd
            return 0
        fi
        ;;
    debian)
        if s5_ver_ge "$S5_OS_VERSION_ID" 12; then
            S5_OS_FAMILY=debian
            S5_PKGMGR=apt
            S5_INIT=systemd
            return 0
        fi
        ;;
    alpine)
        if s5_ver_ge "$S5_OS_VERSION_ID" 3.20; then
            S5_OS_FAMILY=alpine
            S5_PKGMGR=apk
            S5_INIT=openrc
            return 0
        fi
        ;;
    centos)
        if s5_ver_ge "$S5_OS_VERSION_ID" 9; then
            S5_OS_FAMILY=el
            S5_PKGMGR=dnf
            S5_INIT=systemd
            return 0
        fi
        S5_OS_ID_LIKE=''
        ;;
    rhel | rocky | almalinux)
        s5_err_msg detect.likely_compatible "$S5_OS_ID" "$S5_OS_VERSION_ID" "$_dparch"
        return "$EX_UNSUPPORTED"
        ;;
    esac

    case " $S5_OS_ID_LIKE " in
    *" rhel "*)
        s5_err_msg detect.likely_compatible "$S5_OS_ID" "$S5_OS_VERSION_ID" "$_dparch"
        return "$EX_UNSUPPORTED"
        ;;
    esac

    s5_err_msg detect.unsupported "$S5_OS_ID" "$S5_OS_VERSION_ID" "$_dparch"
    return "$EX_UNSUPPORTED"
}

s5_ca_bundle_available() {
    for _caf in /etc/ssl/certs/ca-certificates.crt \
        /etc/pki/tls/certs/ca-bundle.crt \
        /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem; do
        if [ -s "$_caf" ]; then
            return 0
        fi
    done
    return 1
}

# Runtime-only dependencies. The target host never receives a compiler, make,
# headers, or Git merely to install the proxy.
s5_runtime_deps() {
    _rt=''
    if ! command -v curl >/dev/null 2>&1; then
        _rt='curl'
    fi
    if ! s5_ca_bundle_available; then
        if [ -n "$_rt" ]; then _rt="$_rt ca-certificates"; else _rt='ca-certificates'; fi
    fi
    if ! s5_port_probe_available; then
        case "$S5_PKGMGR" in
        apt | apk) _rtprobe=iproute2 ;;
        dnf | yum) _rtprobe=iproute ;;
        *)
            s5_err_msg detect.no_probe_package "${S5_PKGMGR:-unknown}"
            return 1
            ;;
        esac
        if [ -n "$_rt" ]; then
            _rt="$_rt $_rtprobe"
        else
            _rt=$_rtprobe
        fi
    fi
    printf '%s' "$_rt"
}

# Commands that must already exist before installation can start. Compiler,
# make and git are deliberately absent: target hosts never install or invoke
# a source-build toolchain.
#
# Everything the script invokes at a site that hard-fails belongs here, so a
# missing utility is named by this gate instead of surfacing as an obscure error
# mid-install (chown while applying credential-file ownership, uname on the very
# next line of s5_precheck, tail in the destination-deny ordering check, rmdir
# during uninstall, cp for transactional backups, wc for response bounds, and
# mkfifo for the bounded engine-download stream).
S5_BASE_COMMANDS='sed awk grep tr head tail cut id chown chmod mkdir rmdir rm mv cp cat printf stat ln mktemp mkfifo dirname uname wc sha256sum'

s5_no_replace_supported() {
    _nrdir=$(s5_make_workdir) || return 1
    if ! chmod 0700 "$_nrdir" ||
        ! printf 'probe\n' >"$_nrdir/source"; then
        rm -f "$_nrdir/source" "$_nrdir/link" 2>/dev/null || true
        rmdir "$_nrdir" 2>/dev/null || true
        return 1
    fi
    if ! ln -T "$_nrdir/source" "$_nrdir/link" 2>/dev/null ||
        [ "$(stat -c '%d:%i' "$_nrdir/source" 2>/dev/null)" != \
          "$(stat -c '%d:%i' "$_nrdir/link" 2>/dev/null)" ]; then
        rm -f "$_nrdir/source" "$_nrdir/link" 2>/dev/null || true
        rmdir "$_nrdir" 2>/dev/null || true
        return 1
    fi
    rm -f "$_nrdir/link"
    mkdir "$_nrdir/target-dir" || { rm -f "$_nrdir/source"; rmdir "$_nrdir" 2>/dev/null || true; return 1; }
    if ln -T "$_nrdir/source" "$_nrdir/target-dir" 2>/dev/null; then
        rm -f "$_nrdir/target-dir/source" "$_nrdir/source" 2>/dev/null || true
        rmdir "$_nrdir/target-dir" "$_nrdir" 2>/dev/null || true
        return 1
    fi
    _nrextra=$(s5_dir_extras "$_nrdir/target-dir")
    rm -f "$_nrdir/source"
    rmdir "$_nrdir/target-dir" "$_nrdir" 2>/dev/null || return 1
    [ -z "$_nrextra" ]
}

s5_require_commands() {
    _miss=''
    for _rc in "$@"; do
        if ! command -v "$_rc" >/dev/null 2>&1; then
            _miss="$_miss $_rc"
        fi
    done
    if [ -n "$_miss" ]; then
        s5_err_msg detect.missing_commands "$_miss"
        return 1
    fi
    return 0
}

s5_pkgmgr_available() {
    case "$S5_PKGMGR" in
    apt) command -v apt-get >/dev/null 2>&1 ;;
    apk) command -v apk >/dev/null 2>&1 ;;
    dnf) command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1 ;;
    *) return 1 ;;
    esac
}

s5_account_tools_available() {
    case "$S5_OS_FAMILY" in
    alpine)
        command -v adduser >/dev/null 2>&1 && command -v addgroup >/dev/null 2>&1
        ;;
    *)
        command -v useradd >/dev/null 2>&1 && command -v groupadd >/dev/null 2>&1
        ;;
    esac
}

# s5_is_root : privilege check. Reports only; it never escalates or calls sudo.
s5_is_root() {
    if [ "${S5_TEST_MODE:-0}" = "1" ] && [ -n "${S5_ASSUME_ROOT:-}" ]; then
        [ "$S5_ASSUME_ROOT" = "1" ]
        return $?
    fi
    [ "$(id -u)" = "0" ]
}

# s5_precheck : every gate that must pass BEFORE the first prompt, before any
# state file exists, and before anything on the system is modified.
s5_precheck() {
    # Word splitting is intentional: S5_BASE_COMMANDS is a space-separated
    # command list that must reach s5_require_commands as separate words.
    # shellcheck disable=SC2086
    if ! s5_require_commands $S5_BASE_COMMANDS; then
        s5_err_msg detect.no_base_utilities
        return "$EX_FAIL"
    fi
    S5_ARCHNAME=$(s5_map_arch "$(uname -m)") || return "$EX_UNSUPPORTED"
    if ! s5_detect_platform "$S5_ARCHNAME"; then
        return "$EX_UNSUPPORTED"
    fi
    if ! s5_select_engine_asset production; then
        return "$EX_UNSUPPORTED"
    fi
    if ! s5_is_root; then
        s5_err_msg detect.require_root
        return "$EX_FAIL"
    fi
    if ! s5_pkgmgr_available; then
        s5_err_msg detect.pkgmgr_missing "$S5_PKGMGR"
        s5_err_msg detect.pkgmgr_missing_hint
        return "$EX_FAIL"
    fi
    if ! s5_account_tools_available; then
        s5_err_msg detect.account_tools_missing "$S5_OS_FAMILY"
        return "$EX_FAIL"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Validation, generation, and interactive prompts.
# ---------------------------------------------------------------------------

# RFC 3986 unreserved characters only, so the socks5:// URI needs no escaping,
# and every 3proxy config metacharacter (: # $ " whitespace) is excluded.
S5_PASS_CHARSET='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~-'
S5_USER_CHARSET='abcdefghijklmnopqrstuvwxyz0123456789'
S5_USER_FIRST_CHARSET='abcdefghijklmnopqrstuvwxyz'

S5_PORT=''
S5_USERNAME=''
S5_PASSWORD=''

s5_valid_port() {
    case "${1:-}" in
    '' | *[!0-9]*)
        s5_err_msg input.port_not_decimal
        return 1
        ;;
    esac
    # Leading zeros are octal to POSIX test arithmetic ([ 01080 ] is 1080)
    # but a literal string to the engine and to `ss`, so a "valid" 01080
    # would never match the listener it actually collides with. They are a
    # syntax error, decided before any arithmetic happens. No valid port
    # begins with a zero (the minimum is 1024), so 0* is the whole class.
    case "$1" in
    0*)
        s5_err_msg input.port_leading_zero
        return 1
        ;;
    esac
    # Compare only after bounding the digit count. POSIX test arithmetic may
    # diagnose an oversized integer and return false; two false comparisons used
    # to accept an arbitrarily long digit string as a valid port.
    if [ "${#1}" -gt 5 ]; then
        s5_err_msg input.port_range "$S5_PORT_MIN" "$S5_PORT_MAX"
        return 1
    fi
    if [ "$1" -lt "$S5_PORT_MIN" ] || [ "$1" -gt "$S5_PORT_MAX" ]; then
        s5_err_msg input.port_range "$S5_PORT_MIN" "$S5_PORT_MAX"
        return 1
    fi
    return 0
}

s5_valid_username() {
    _vu=${1:-}
    _vul=${#_vu}
    if [ "$_vul" -lt "$S5_USER_MIN" ] || [ "$_vul" -gt "$S5_USER_MAX" ]; then
        s5_err_msg validation.username_len "$S5_USER_MIN" "$S5_USER_MAX" "$_vul"
        return 1
    fi
    case "$_vu" in
    *[!A-Za-z0-9_-]*)
        s5_err_msg validation.username_charset
        return 1
        ;;
    esac
    return 0
}

# Deliberately never prints the candidate: an invalid password is still a secret.
s5_valid_password() {
    _vp=${1:-}
    _vpl=${#_vp}
    if [ "$_vpl" -lt "$S5_PASS_MIN" ] || [ "$_vpl" -gt "$S5_PASS_MAX" ]; then
        s5_err_msg validation.password_len "$S5_PASS_MIN" "$S5_PASS_MAX" "$_vpl"
        return 1
    fi
    case "$_vp" in
    *[!A-Za-z0-9._~-]*)
        s5_err_msg validation.password_charset
        return 1
        ;;
    esac
    return 0
}

# tr -dc over /dev/urandom is rejection sampling: bytes outside the set are
# discarded, so surviving characters are uniform over the set. No modulo bias.
#
# The length that came back is verified rather than assumed. `head -c N` exits 0
# on short input and the pipeline's status is head's, so nothing in the pipeline
# reports a partial draw: an unreadable /dev/urandom (a stripped container
# image, a /dev that was never populated) made tr fail, its only diagnosis went
# to /dev/null, and the function returned an empty string with status 0. Every
# caller then accepted the partial value -- a 12-to-31-character password still
# satisfies s5_valid_password, so the install completed while the operator was
# told a 32-character password had been generated, and s5_random_int collapsed
# to always returning 0, which pinned every "random" port to S5_RANDPORT_MIN.
s5_random_string() {
    _rgn=$1
    _rgv=$(LC_ALL=C tr -dc "$2" </dev/urandom 2>/dev/null | head -c "$_rgn")
    if [ "${#_rgv}" -ne "$_rgn" ]; then
        s5_err_msg input.random_chars_failed "$_rgn" "${#_rgv}"
        return 1
    fi
    printf '%s' "$_rgv"
    return 0
}

s5_random_password() {
    s5_random_string "$S5_PASS_GEN_LEN" "$S5_PASS_CHARSET"
}

# The two halves are drawn into variables before being joined. A command
# substitution discards the exit status of what ran inside it, so the previous
# `printf '%s%s' "$(...)" "$(...)"` would have printed a short username and
# still reported success.
s5_random_username() {
    _runf=$(s5_random_string 1 "$S5_USER_FIRST_CHARSET") || return 1
    _runr=$(s5_random_string 11 "$S5_USER_CHARSET") || return 1
    printf '%s%s' "$_runf" "$_runr"
}

# s5_random_int <count> : uniform integer in 0..count-1, no modulo bias.
s5_random_int() {
    _ricnt=$1
    if [ "$_ricnt" -lt 1 ] || [ "$_ricnt" -gt 100000 ]; then
        s5_err_msg input.random_int_range "$_ricnt"
        return 1
    fi
    while :; do
        _rid=$(s5_random_string 5 '0123456789') || return 1
        # Pure parameter expansion, no process. This strip used to run
        # `printf | sed` in a command substitution, and the [ -z ] arm below
        # turned an empty result into the integer 0 -- so a sed that failed for
        # any reason (a fork refused under RLIMIT_NPROC, a shadowed or broken
        # sed, any nonzero exit) made this function answer 0 with status 0.
        # Every "random" port then became S5_RANDPORT_MIN while the caller
        # logged it as a real selection. That is the same partial-draw class the
        # comment above s5_random_string describes, and the guard added there
        # had no counterpart here. Removing the process removes the failure.
        _riv=${_rid#"${_rid%%[!0]*}"}
        if [ -z "$_riv" ]; then
            _riv=0
        fi
        if [ "$_riv" -lt "$_ricnt" ]; then
            printf '%s' "$_riv"
            return 0
        fi
    done
}

# Prefer the Linux kernel socket table, which needs no extra package. Fall back
# to ss/netstat when /proc is unavailable; every candidate must actually work.
#
# The two tables disagree on the third column's name: net/ipv4/tcp_ipv4.c prints
# "rem_address" and net/ipv6/tcp_ipv6.c prints "remote_address". Accepting only
# the IPv4 spelling rejected /proc/net/tcp6 on every IPv6-enabled host, which
# demoted this adapter to ss/netstat everywhere and made s5_runtime_deps plan an
# iproute package the host did not need. The column is a header sanity check
# only -- no row rule reads $3 -- so both spellings are accepted.
s5_proc_table_valid() {
    _ptv=$1
    [ -r "$_ptv" ] || return 1
    awk '
        NR == 1 {
            if ($1 != "sl" || $2 != "local_address" || $4 != "st") exit 2
            if ($3 != "rem_address" && $3 != "remote_address") exit 2
            header=1
            next
        }
        NF < 4 { exit 2 }
        $1 !~ /^[0-9]+:$/ || $2 !~ /^[0-9A-F]+:[0-9A-F][0-9A-F][0-9A-F][0-9A-F]$/ ||
            $3 !~ /^[0-9A-F]+:[0-9A-F][0-9A-F][0-9A-F][0-9A-F]$/ ||
            $4 !~ /^[0-9A-F][0-9A-F]$/ { exit 2 }
        END { if (!header) exit 2 }
    ' "$_ptv" >/dev/null 2>&1
}

s5_proc_net_available() {
    s5_proc_table_valid "$S5_PROC_NET_TCP" || return 1
    if [ -e "$S5_PROC_NET_TCP6" ] || [ -L "$S5_PROC_NET_TCP6" ]; then
        s5_proc_table_valid "$S5_PROC_NET_TCP6" || return 1
    fi
    return 0
}

s5_ipv4_to_proc_hex() {
    s5_ipv4_is_canonical "$1" || return 1
    printf '%s\n' "$1" | awk -F. '{ printf "%02X%02X%02X%02X", $4, $3, $2, $1 }'
}

# Return 0 when free, 1 when a LISTEN socket owns the port, 2 on read failure.
s5_proc_port_free() {
    s5_proc_table_valid "$S5_PROC_NET_TCP" || return 2
    if [ -e "$S5_PROC_NET_TCP6" ] || [ -L "$S5_PROC_NET_TCP6" ]; then
        s5_proc_table_valid "$S5_PROC_NET_TCP6" || return 2
    fi
    _ppfport=$(printf '%04X' "$1") || return 2
    if [ -n "${2:-}" ]; then
        _ppfaddr=$(s5_ipv4_to_proc_hex "$2") || return 2
        awk -v endpoint="$_ppfaddr:$_ppfport" '
            NR > 1 && $2 == endpoint && $4 == "0A" { found=1 }
            END { exit found ? 0 : 1 }
        ' "$S5_PROC_NET_TCP" >/dev/null 2>&1
        _ppfrc=$?
    else
        _ppffiles=$S5_PROC_NET_TCP
        if [ -r "$S5_PROC_NET_TCP6" ]; then
            _ppffiles="$_ppffiles $S5_PROC_NET_TCP6"
        fi
        # shellcheck disable=SC2086
        awk -v suffix=":$_ppfport" '
            NR > 1 && substr($2, length($2) - 4) == suffix && $4 == "0A" { found=1 }
            END { exit found ? 0 : 1 }
        ' $_ppffiles >/dev/null 2>&1
        _ppfrc=$?
    fi
    case "$_ppfrc" in
    0) return 1 ;;
    1) return 0 ;;
    *) return 2 ;;
    esac
}

s5_probe_cmd() {
    if s5_proc_net_available; then
        printf 'proc'
        return 0
    fi
    if command -v ss >/dev/null 2>&1 && ss -ltn >/dev/null 2>&1; then
        printf 'ss'
        return 0
    fi
    if command -v netstat >/dev/null 2>&1 && netstat -ltn >/dev/null 2>&1; then
        printf 'netstat'
        return 0
    fi
    return 1
}

# The one diagnosis for "the listen state cannot be observed at all", shared by
# both port paths so their advice cannot drift apart. s5_port_free deliberately
# still answers "not free" in that situation; the callers below use this instead
# of repeating that answer as though a port had really been seen in use.
s5_err_no_probe() {
    s5_err_msg network.no_probe_cmd
    s5_err_msg network.no_probe_hint
}

# s5_port_free <port> [address] : true when nothing is listening. Never binds.
# With an address, readiness/status require an exact Local Address:Port match.
# Without one, prompt-time collision detection rejects the port on any address.
# Fail-closed: with no probe available we report "not free".
s5_port_free() {
    _pfaddr=${2:-}
    if [ "${S5_TEST_MODE:-0}" = "1" ] && [ -n "${S5_PORT_PROBE:-}" ]; then
        "$S5_PORT_PROBE" "$1" "$_pfaddr"
        return $?
    fi
    if ! _pfc=$(s5_probe_cmd); then
        s5_warn_msg network.port_free_unknown "$1"
        return 1
    fi
    case "$_pfc" in
    proc)
        s5_proc_port_free "$1" "$_pfaddr"
        return $?
        ;;
    ss) _pfout=$(ss -ltn 2>/dev/null); _pfr=$? ;;
    netstat) _pfout=$(netstat -ltn 2>/dev/null); _pfr=$? ;;
    *) return 1 ;;
    esac
    if [ "$_pfr" -ne 0 ]; then
        s5_warn_msg network.port_probe_cmd_failed "$1" "$_pfc"
        return 2
    fi
    if [ -n "$_pfaddr" ]; then
        # The proc backend answers 2 for an address it cannot parse, because
        # s5_ipv4_to_proc_hex refuses it. This branch used to skip validation
        # entirely and fall through its non-match path to "free", so the two
        # backends gave opposite answers for the same unobservable input -- the
        # asymmetry s5_port_probe_available's comment says cannot exist.
        if ! s5_ipv4_is_canonical "$_pfaddr"; then
            return 2
        fi
        if printf '%s\n' "$_pfout" |
            awk -v endpoint="$_pfaddr:$1" '$4 == endpoint { found=1 } END { exit found ? 0 : 1 }'; then
            return 1
        fi
        return 0
    fi
    if printf '%s\n' "$_pfout" | grep -q "[:.]$1[[:space:]]"; then
        return 1
    fi
    return 0
}

# s5_port_probe_available : true when the listen state can be observed at all.
# Gates on exactly the same conditions as s5_port_free, so the two can never
# disagree about whether a probe exists. Lives here, beside that function, and
# ahead of all three callers.
s5_port_probe_available() {
    if [ "${S5_TEST_MODE:-0}" = "1" ] && [ -n "${S5_PORT_PROBE:-}" ]; then
        return 0
    fi
    s5_probe_cmd >/dev/null 2>&1
}

s5_random_port() {
    # Without a probe every candidate looks busy, so the loop below would warn
    # fifty times and then blame a port range it had never managed to observe.
    if ! s5_port_probe_available; then
        s5_err_no_probe
        return 1
    fi
    _rprange=$((S5_RANDPORT_MAX - S5_RANDPORT_MIN + 1))
    _rptry=0
    while [ "$_rptry" -lt 50 ]; do
        _rptry=$((_rptry + 1))
        _rpoff=$(s5_random_int "$_rprange") || return 1
        _rpp=$((S5_RANDPORT_MIN + _rpoff))
        # Status 1 is a busy port; status 2 means the probe could not
        # observe anything, and pretending the range was exhausted would be a
        # diagnosis nobody can act on.
        s5_port_free "$_rpp"
        _rpfr=$?
        case "$_rpfr" in
        0)
            printf '%s' "$_rpp"
            return 0
            ;;
        1) ;;
        *)
            s5_err_msg network.random_port_probe_failed "$_rpp"
            return 1
            ;;
        esac
    done
    s5_err_msg network.no_free_port "$S5_RANDPORT_MIN" "$S5_RANDPORT_MAX"
    return 1
}

s5_prompt_port() {
    _ppcurrent=${1:-}
    # Nothing here can be answered without a probe: a random port cannot be
    # picked, and an operator's own port would be reported as "already in use"
    # when the truth is that no listen state was ever seen. Say so before
    # asking a question whose answer cannot be checked.
    if ! s5_port_probe_available; then
        s5_err_no_probe
        return 1
    fi
    _ppa=0
    while [ "$_ppa" -lt 5 ]; do
        _ppa=$((_ppa + 1))
        s5_prompt_msg input.port_prompt "$S5_RANDPORT_MIN" "$S5_RANDPORT_MAX"
        _ppin=''
        if ! read -r _ppin; then
            s5_err_msg input.port_eof
            return 1
        fi
        if [ -z "$_ppin" ]; then
            _pprand=$(s5_random_port) || return 1
            S5_PORT=$_pprand
            s5_log_msg input.log_random_port "$S5_PORT"
            return 0
        fi
        if ! s5_valid_port "$_ppin"; then
            continue
        fi
        if [ -n "$_ppcurrent" ] && [ "$_ppin" = "$_ppcurrent" ]; then
            S5_PORT=$_ppin
            return 0
        fi
        # Three-valued like every other observation: a probe failure (status
        # 2) is not evidence that the port is busy, and blaming the operator's
        # port for the probe's failure sends them hunting the wrong problem.
        s5_port_free "$_ppin"
        _ppr=$?
        case "$_ppr" in
        0) ;;
        1)
            s5_err_msg input.port_in_use "$_ppin"
            continue
            ;;
        *)
            s5_err_msg input.port_probe_failed "$_ppin"
            continue
            ;;
        esac
        S5_PORT=$_ppin
        return 0
    done
    s5_err_msg input.port_too_many
    return 1
}

s5_prompt_username() {
    _una=0
    while [ "$_una" -lt 5 ]; do
        _una=$((_una + 1))
        s5_prompt_msg input.username_prompt
        _unin=''
        if ! read -r _unin; then
            s5_err_msg input.username_eof
            return 1
        fi
        if [ -z "$_unin" ]; then
            if ! S5_USERNAME=$(s5_random_username); then
                S5_USERNAME=''
                s5_err_msg input.username_gen_failed
                return 1
            fi
            s5_log_msg input.log_random_username "$S5_USERNAME"
            return 0
        fi
        if ! s5_valid_username "$_unin"; then
            continue
        fi
        S5_USERNAME=$_unin
        return 0
    done
    s5_err_msg input.username_too_many
    return 1
}

s5_prompt_password() {
    _pwa=0
    while [ "$_pwa" -lt 5 ]; do
        _pwa=$((_pwa + 1))
        s5_prompt_msg input.password_prompt "$S5_PASS_GEN_LEN"
        _pw1=''
        if ! read -r _pw1; then
            s5_err_msg input.password_eof
            return 1
        fi
        if [ -z "$_pw1" ]; then
            # The announcement below states a length, so it must not be printed
            # unless a string of exactly that length was really produced.
            if ! S5_PASSWORD=$(s5_random_password); then
                S5_PASSWORD=''
                s5_err_msg input.password_gen_failed
                return 1
            fi
            S5_SECRET=$S5_PASSWORD
            s5_log_msg input.password_gen_log "$S5_PASS_GEN_LEN"
            return 0
        fi
        if ! s5_valid_password "$_pw1"; then
            _pw1=''
            continue
        fi
        # Read once, no confirmation: the final credential card reprints the
        # adopted password to the terminal, which is where a typo becomes
        # visible -- the old confirm prompt only protected against typos
        # before that card existed.
        S5_PASSWORD=$_pw1
        S5_SECRET=$S5_PASSWORD
        _pw1=''
        return 0
    done
    s5_err_msg input.password_too_many
    return 1
}

# ---------------------------------------------------------------------------
# Secure file primitives.
#
# Every temporary file is created with mktemp (unpredictable name, mode 0600 by
# construction), verified to be a regular file and not a symlink, and confirmed
# to be 0600 BEFORE any secret is written into it.
# ---------------------------------------------------------------------------

# s5_secure_tmp <path> : assert the freshly created temp file is safe to write
# a secret into, and that it is mode 0600.
s5_secure_tmp() {
    if [ -L "$1" ]; then
        s5_err_msg fs.write_symlink "$1"
        return 1
    fi
    if [ ! -f "$1" ]; then
        s5_err_msg fs.write_not_regular "$1"
        return 1
    fi
    if ! chmod 0600 "$1"; then
        s5_err_msg fs.write_mode0600 "$1"
        return 1
    fi
    return 0
}

# s5_mkdir_secure <dir> <owner:group> <final-mode>
# The directory is clamped to 0700 the instant it exists, independently of the
# ambient umask, so it is never briefly group- or world-accessible. Only then
# is it widened to the final mode.
# Create one missing path component at a time. Existing components are never
# chmod'ed or chown'ed: callers use this helper for both project-owned private
# directories and shared administrator-owned paths such as /etc/init.d.
_s5_mkdir_component() {
    if [ -L "$1" ]; then
        s5_err_msg fs.use_symlink "$1"
        return 1
    fi
    if [ -d "$1" ]; then
        _mcpp=$(dirname "$1")
        if [ "$_mcpp" != "$1" ] && ! _s5_mkdir_component "$_mcpp" "$2" "$3" "$4"; then
            return 1
        fi
        return 0
    fi
    if [ -e "$1" ]; then
        s5_err_msg fs.use_not_dir "$1"
        return 1
    fi
    if ! _s5_mkdir_component "$(dirname "$1")" "$2" "$3" "$4"; then
        return 1
    fi
    if ! mkdir "$1"; then
        s5_err_msg fs.create_failed "$1"
        return 1
    fi
    # Restrict the new inode before applying its intended traversable mode.
    if ! chmod 0700 "$1"; then
        s5_err_msg fs.restrict_0700 "$1"
        return 1
    fi
    s5_modelog "dir-created:$1" "$1"
    _mcfinal=0755
    if [ "$1" = "$4" ]; then
        _mcfinal=$3
    fi
    if ! s5_apply_owner_mode "$1" "$2" "$_mcfinal"; then
        return 1
    fi
    s5_modelog "dir-final:$1" "$1"
    return 0
}

s5_mkdir_secure() {
    if [ -L "$1" ]; then
        s5_err_msg fs.use_symlink "$1"
        return 1
    fi
    # Existing directories may be shared with the host administrator. Do not
    # silently replace their owner or mode merely because this script needs to
    # place a file below them. The helper still walks their ancestors so a
    # symlinked parent cannot redirect the operation outside the intended tree.
    _s5_mkdir_component "$1" "$2" "$3" "$1"
}

# s5_claim_dir <dir> <owner:group> <final-mode>
# Unlike s5_mkdir_secure, the final directory is project-owned and must not
# already exist. Shared ancestors may exist, but the final mkdir is exclusive.
s5_claim_dir() {
    _cdp=$1
    _cdo=$2
    _cdm=$3
    _cdparent=$(dirname "$_cdp")
    if ! s5_mkdir_secure "$_cdparent" "root:root" 0755; then
        return 1
    fi
    if [ -e "$_cdp" ] || [ -L "$_cdp" ]; then
        s5_err_msg collision.path_exists "$_cdp"
        s5_say_msg collision.refuse_overwrite
        return 1
    fi
    if ! mkdir "$_cdp"; then
        if [ -e "$_cdp" ] || [ -L "$_cdp" ]; then
            s5_err_msg collision.path_exists "$_cdp"
            s5_say_msg collision.refuse_overwrite
        else
            s5_err_msg fs.create_failed "$_cdp"
        fi
        return 1
    fi
    if ! chmod 0700 "$_cdp"; then
        rmdir "$_cdp" 2>/dev/null || true
        s5_err_msg fs.restrict_0700 "$_cdp"
        return 1
    fi
    s5_modelog "dir-created:$_cdp" "$_cdp"
    _cdid=$(stat -c '%d:%i' "$_cdp" 2>/dev/null)
    if [ -z "$_cdid" ] || ! s5_apply_owner_mode "$_cdp" "$_cdo" "$_cdm" ||
        [ "$(stat -c '%d:%i' "$_cdp" 2>/dev/null)" != "$_cdid" ]; then
        if [ "$(stat -c '%d:%i' "$_cdp" 2>/dev/null)" = "$_cdid" ]; then
            rmdir "$_cdp" 2>/dev/null || true
        fi
        return 1
    fi
    s5_modelog "dir-final:$_cdp" "$_cdp"
    S5_PENDING_CLAIM_PATH=$_cdp
    S5_PENDING_CLAIM_KIND=dir
    S5_PENDING_CLAIM_ID=$_cdid
    return 0
}

# s5_atomic_write <final-path> <owner:group> <final-mode>   (content on stdin)
s5_atomic_write() {
    _awp=$1
    _awo=$2
    _awm=$3
    _awd=$(dirname "$_awp")
    if [ ! -d "$_awd" ]; then
        s5_err_msg fs.atomic_dir_missing "$_awp" "$_awd"
        return 1
    fi
    if [ -L "$_awp" ]; then
        s5_err_msg fs.atomic_symlink "$_awp"
        return 1
    fi
    if ! _awt=$(mktemp "$_awd/.s5tmp.XXXXXX"); then
        s5_err_msg fs.atomic_mktemp_failed "$_awd"
        return 1
    fi
    if ! s5_secure_tmp "$_awt"; then
        rm -f "$_awt"
        return 1
    fi
    s5_modelog "tmp-created:$_awp" "$_awt"
    if ! cat >"$_awt"; then
        s5_err_msg fs.atomic_write_tmp "$_awt"
        rm -f "$_awt"
        return 1
    fi
    s5_modelog "tmp-written:$_awp" "$_awt"
    if ! s5_apply_owner_mode "$_awt" "$_awo" "$_awm"; then
        rm -f "$_awt"
        return 1
    fi
    if ! mv "$_awt" "$_awp"; then
        s5_err_msg fs.atomic_install "$_awp"
        rm -f "$_awt"
        return 1
    fi
    return 0
}

# _s5_publish_new <final-path> <owner:group> <final-mode> <text|file> <payload>
# Publish a fully prepared file without replacing any path that appeared after
# collision detection. The hard link and destination share a filesystem because
# the temporary file is created beside the final path. Callers invoke this
# directly, never in a pipeline, so the pending-claim fingerprint remains in the
# managing shell for signal cleanup and state handoff.
_s5_publish_new() {
    _pnp=$1
    _pno=$2
    _pnm=$3
    _pnkind=$4
    _pnpayload=$5
    _pnd=$(dirname "$_pnp")
    if [ ! -d "$_pnd" ]; then
        s5_err_msg fs.atomic_dir_missing "$_pnp" "$_pnd"
        return 1
    fi
    if ! _pnt=$(mktemp "$_pnd/.s5new.XXXXXX"); then
        s5_err_msg fs.atomic_mktemp_failed "$_pnd"
        return 1
    fi
    if ! s5_secure_tmp "$_pnt"; then
        rm -f "$_pnt"
        return 1
    fi
    s5_modelog "tmp-created:$_pnp" "$_pnt"
    case "$_pnkind" in
    text)
        if ! printf '%s\n' "$_pnpayload" >"$_pnt"; then
            s5_err_msg fs.atomic_write_tmp "$_pnt"
            rm -f "$_pnt"
            return 1
        fi
        ;;
    file)
        if ! cat <"$_pnpayload" >"$_pnt"; then
            s5_err_msg fs.atomic_write_tmp "$_pnt"
            rm -f "$_pnt"
            return 1
        fi
        ;;
    *) rm -f "$_pnt"; return 1 ;;
    esac
    s5_modelog "tmp-written:$_pnp" "$_pnt"
    if ! s5_apply_owner_mode "$_pnt" "$_pno" "$_pnm"; then
        rm -f "$_pnt"
        return 1
    fi
    _pnid=$(stat -c '%d:%i' "$_pnt" 2>/dev/null)
    if [ -z "$_pnid" ]; then
        s5_err_msg fs.atomic_install "$_pnp"
        rm -f "$_pnt"
        return 1
    fi
    if ! ln -T "$_pnt" "$_pnp" 2>/dev/null; then
        if [ -e "$_pnp" ] || [ -L "$_pnp" ]; then
            s5_err_msg collision.path_exists "$_pnp"
            s5_say_msg collision.refuse_overwrite
        else
            s5_err_msg fs.atomic_install "$_pnp"
        fi
        rm -f "$_pnt"
        return 1
    fi
    if [ "$(stat -c '%d:%i' "$_pnp" 2>/dev/null)" != "$_pnid" ]; then
        s5_err_msg fs.atomic_install "$_pnp"
        rm -f "$_pnt"
        return 1
    fi
    S5_PENDING_CLAIM_PATH=$_pnp
    S5_PENDING_CLAIM_KIND='file'
    S5_PENDING_CLAIM_ID=$_pnid
    S5_PENDING_CLAIM_TEMP=$_pnt
    return 0
}

s5_publish_new_text() {
    _s5_publish_new "$1" "$2" "$3" text "$4"
}

s5_publish_new_file() {
    _s5_publish_new "$1" "$2" "$3" file "$4"
}

s5_pending_claim_clear() {
    if [ -n "$S5_PENDING_CLAIM_TEMP" ]; then
        rm -f "$S5_PENDING_CLAIM_TEMP" || return 1
    fi
    S5_PENDING_CLAIM_PATH=''
    S5_PENDING_CLAIM_KIND=''
    S5_PENDING_CLAIM_ID=''
    S5_PENDING_CLAIM_TEMP=''
    return 0
}

s5_pending_claim_remove() {
    if [ -z "$S5_PENDING_CLAIM_PATH" ]; then
        return 0
    fi
    _pcrid=$(stat -c '%d:%i' "$S5_PENDING_CLAIM_PATH" 2>/dev/null)
    if [ "$_pcrid" != "$S5_PENDING_CLAIM_ID" ]; then
        s5_err_msg rollback.keep_foreign_files "$S5_PENDING_CLAIM_PATH"
        s5_pending_claim_clear >/dev/null 2>&1 || true
        return 1
    fi
    case "$S5_PENDING_CLAIM_KIND" in
    file) rm -f "$S5_PENDING_CLAIM_PATH" || return 1 ;;
    dir) rmdir "$S5_PENDING_CLAIM_PATH" || return 1 ;;
    *) return 1 ;;
    esac
    s5_pending_claim_clear
    return $?
}

s5_state_mark_claim() {
    _smckey=$1
    _smcid=$S5_PENDING_CLAIM_ID
    if [ -z "$S5_PENDING_CLAIM_PATH" ] ||
        [ "$(stat -c '%d:%i' "$S5_PENDING_CLAIM_PATH" 2>/dev/null)" != "$_smcid" ]; then
        s5_err_msg rollback.keep_foreign_files "${S5_PENDING_CLAIM_PATH:-unknown}"
        s5_pending_claim_clear >/dev/null 2>&1 || true
        return 1
    fi
    if s5_state_mark "$_smckey"; then
        case "$_smckey" in
        created_prefix) S5_CLAIM_PREFIX_ID=$_smcid ;;
        created_bin) S5_CLAIM_BIN_ID=$_smcid ;;
        created_confdir) S5_CLAIM_CONFDIR_ID=$_smcid ;;
        created_users) S5_CLAIM_USERS_ID=$_smcid ;;
        created_cfg) S5_CLAIM_CFG_ID=$_smcid ;;
        created_unit) S5_CLAIM_UNIT_ID=$_smcid ;;
        created_initscript) S5_CLAIM_INITSCRIPT_ID=$_smcid ;;
        esac
        if ! s5_pending_claim_clear; then
            s5_err_msg rollback.rm_file_failed "$S5_PENDING_CLAIM_TEMP"
            return 1
        fi
        return 0
    fi
    s5_pending_claim_remove || true
    return 1
}

# s5_apply_owner_mode <path> <owner:group> <mode>
s5_apply_owner_mode() {
    if ! chmod "$3" "$1"; then
        s5_err_msg fs.atomic_mode "$3" "$1"
        return 1
    fi
    if [ "${S5_TEST_MODE:-0}" = "1" ] && [ "${S5_SKIP_OWNERSHIP:-0}" = "1" ]; then
        return 0
    fi
    if ! chown "$2" "$1"; then
        s5_err_msg fs.atomic_owner "$2" "$1"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# State file.
#
# The state file records FLAGS and identifiers, never paths to delete. Every
# path removed during rollback or uninstall is recomputed from the constants at
# the top of this script, so a corrupted or hostile state file can never turn
# into an arbitrary recursive delete.
#
# Reads are validated against a key allowlist and fail closed.
# ---------------------------------------------------------------------------

S5_STATE_KEYS_REQUIRED='tag commit origin port username os family arch init listen account_uid account_gid status'
S5_STATE_KEYS_OPTIONAL='asset sha256'
S5_STATE_KEYS_FLAG='created_account created_group created_confdir created_prefix created_bin created_cfg created_users created_unit created_initscript'
S5_STATE_KEYS_MULTI='package'
S5_STATE_BUF=''
S5_STATE_LOADED=0

s5_state_release_asset_ok() {
    _sraoos=$1
    _sraofamily=$2
    _sraoarch=$3
    _sraoasset=$4
    _sraosha=$5
    case "$_sraofamily:$_sraoarch:$_sraoasset:$_sraosha" in
    debian:amd64:3proxy-0.9.9.0-da99424-linux-glibc-amd64:ce3c604d0133df0028b4e9cd93c326b36790db789c769b2a2c78b400b9967a80 | \
    el:amd64:3proxy-0.9.9.0-da99424-linux-glibc-amd64:ce3c604d0133df0028b4e9cd93c326b36790db789c769b2a2c78b400b9967a80)
        [ "$_sraoos" != ubuntu-20.04 ]
        ;;
    debian:amd64:3proxy-0.9.9.0-da99424-linux-glibc-amd64:9c2892b46121439f3c5a05fc19ec07fe68d2ce3498110cac29c165749efaafcf | \
    el:amd64:3proxy-0.9.9.0-da99424-linux-glibc-amd64:9c2892b46121439f3c5a05fc19ec07fe68d2ce3498110cac29c165749efaafcf) return 0 ;;
    debian:arm64:3proxy-0.9.9.0-da99424-linux-glibc-arm64:344e482272e5c16d1f9c762d7ed240cda43bb050a53be767e5393a616607ccf5 | \
    el:arm64:3proxy-0.9.9.0-da99424-linux-glibc-arm64:344e482272e5c16d1f9c762d7ed240cda43bb050a53be767e5393a616607ccf5) return 0 ;;
    alpine:amd64:3proxy-0.9.9.0-da99424-linux-musl-amd64:ac3fe1a7d52d2b1494d4d00884fc7517acb2340454c2653c95a7346c05d69298) return 0 ;;
    alpine:arm64:3proxy-0.9.9.0-da99424-linux-musl-arm64:38f2733dfc5d375a4faaebe79f66bd181c7cc3e7b3eb9443c3ac4476fbfeebeb) return 0 ;;
    *) return 1 ;;
    esac
}

s5_state_key_known() {
    for _skk in $S5_STATE_KEYS_REQUIRED $S5_STATE_KEYS_OPTIONAL $S5_STATE_KEYS_FLAG $S5_STATE_KEYS_MULTI; do
        if [ "$_skk" = "$1" ]; then
            return 0
        fi
    done
    return 1
}

s5_state_key_is_flag() {
    for _sfk in $S5_STATE_KEYS_FLAG; do
        if [ "$_sfk" = "$1" ]; then
            return 0
        fi
    done
    return 1
}

s5_state_key_is_once() {
    for _sok in $S5_STATE_KEYS_REQUIRED $S5_STATE_KEYS_OPTIONAL; do
        if [ "$_sok" = "$1" ]; then
            return 0
        fi
    done
    return 1
}

# s5_state_value_ok <key> <value>
s5_state_value_ok() {
    case "$2" in
    *[!A-Za-z0-9._~:/-]*)
        s5_err_msg state.disallowed_char "$1"
        return 1
        ;;
    esac
    if s5_state_key_is_flag "$1"; then
        if [ "$2" != "1" ]; then
            s5_err_msg state.flag_not_1 "$1"
            return 1
        fi
        return 0
    fi
    case "$1" in
    port)
        # Same syntax rule as the interactive validator, and for the same
        # reasons: a leading zero is octal to arithmetic but a literal to the
        # engine and to ss, and an oversized decimal makes POSIX test
        # arithmetic diagnose and return false on BOTH range comparisons,
        # which used to fall through as acceptance. Length and lexical shape
        # are decided before any arithmetic runs.
        case "$2" in
        '' | *[!0-9]*)
            s5_err_msg state.port_not_numeric
            return 1
            ;;
        0*)
            s5_err_msg state.port_leading_zero
            return 1
            ;;
        ??????*)
            s5_err_msg state.port_out_of_range
            return 1
            ;;
        esac
        if [ "$2" -lt "$S5_PORT_MIN" ] || [ "$2" -gt "$S5_PORT_MAX" ]; then
            s5_err_msg state.port_out_of_range
            return 1
        fi
        ;;
    username)
        if ! s5_valid_username "$2" >/dev/null 2>&1; then
            s5_err_msg state.username_invalid
            return 1
        fi
        ;;
    listen)
        # The only required key that had no validator arm. Every consumer treats
        # this value as a bind address: s5_render_cfg interpolates it into the
        # socks service line and s5_port_listening hands it to the probe as the
        # exact endpoint to match, so an unvalidated value from a hand-edited
        # state file decided both what the engine binds and what "listening"
        # means for it.
        if ! s5_ipv4_is_canonical "$2"; then
            s5_err_msg state.listen_invalid
            return 1
        fi
        ;;
    origin)
        case "$2" in
        source-build | release-asset) ;;
        *) s5_err_msg state.origin_invalid; return 1 ;;
        esac
        ;;
    asset)
        case "$2" in
        3proxy-0.9.9.0-da99424-linux-glibc-amd64 | \
        3proxy-0.9.9.0-da99424-linux-glibc-arm64 | \
        3proxy-0.9.9.0-da99424-linux-musl-amd64 | \
        3proxy-0.9.9.0-da99424-linux-musl-arm64) ;;
        *) s5_err_msg state.asset_invalid; return 1 ;;
        esac
        ;;
    sha256)
        if [ "${#2}" -ne 64 ]; then
            s5_err_msg state.sha256_invalid
            return 1
        fi
        case "$2" in
        *[!0-9a-f]*) s5_err_msg state.sha256_invalid; return 1 ;;
        esac
        ;;
    commit)
        # A git object name is exactly 40 hexadecimal characters. The old
        # pattern was 8 hex characters followed by an unbounded '*', which in
        # a shell case pattern means "then anything", so any 8-hex prefix
        # with an allowed trailing character was accepted.
        if [ "${#2}" -ne 40 ]; then
            s5_err_msg state.commit_len
            return 1
        fi
        case "$2" in
        *[!0-9a-f]*)
            s5_err_msg state.commit_not_hex
            return 1
            ;;
        esac
        ;;
    init)
        case "$2" in
        systemd | openrc) ;;
        *)
            s5_err_msg state.unknown_init "$2"
            return 1
            ;;
        esac
        ;;
    account_uid | account_gid)
        _savok=0
        case "$2" in
        '' | *[!0-9]*) _savok=1 ;;
        esac
        if [ "$_savok" -ne 0 ]; then
            s5_err_msg state.not_numeric "$1"
            return 1
        fi
        ;;
    status)
        case "$2" in
        complete) ;;
        *)
            s5_err_msg state.unknown_status "$2"
            return 1
            ;;
        esac
        ;;
    esac
    return 0
}

# s5_state_load : read, validate and cache the state file. Fails closed.
s5_state_load() {
    S5_STATE_BUF=''
    S5_STATE_LOADED=0
    if [ ! -e "$S5_STATE" ]; then
        return 1
    fi
    if [ -L "$S5_STATE" ]; then
        s5_err_msg state.read_symlink "$S5_STATE"
        return 1
    fi
    if [ ! -f "$S5_STATE" ]; then
        s5_err_msg state.read_not_regular "$S5_STATE"
        return 1
    fi
    if [ ! -r "$S5_STATE" ]; then
        s5_err_msg state.read_failed "$S5_STATE"
        return 1
    fi

    _slmode=$(stat -c '%a' "$S5_STATE" 2>/dev/null || printf '')
    if [ "$_slmode" != 600 ]; then
        s5_err_msg state.read_mode "$S5_STATE" "${_slmode:-unknown}"
        return 1
    fi
    if ! _slcontents=$(cat "$S5_STATE"); then
        s5_err_msg state.read_error "$S5_STATE"
        return 1
    fi

    _slseen=''
    _slbuf=''
    _slbad=0
    _slline=0
    while IFS= read -r _sl || [ -n "$_sl" ]; do
        _slline=$((_slline + 1))
        if [ -z "$_sl" ]; then
            continue
        fi
        case "$_sl" in
        *"	"*) ;;
        *)
            s5_err_msg state.line_malformed "$_slline"
            _slbad=1
            continue
            ;;
        esac
        _slk=${_sl%%	*}
        _slv=${_sl#*	}
        if ! s5_state_key_known "$_slk"; then
            s5_err_msg state.unknown_key "$_slk" "$_slline"
            _slbad=1
            continue
        fi
        if ! s5_state_value_ok "$_slk" "$_slv"; then
            _slbad=1
            continue
        fi
        if s5_state_key_is_once "$_slk"; then
            for _sls in $_slseen; do
                if [ "$_sls" = "$_slk" ]; then
                    s5_err_msg state.duplicate_key "$_slk" "$_slline"
                    _slbad=1
                fi
            done
            _slseen="$_slseen $_slk"
        fi
        if [ -n "$_slbuf" ]; then
            _slbuf="$_slbuf
$_sl"
        else
            _slbuf=$_sl
        fi
    done <<EOF
$_slcontents
EOF
    _slread=$?
    if [ "$_slread" -ne 0 ]; then
        s5_err_msg state.read_error "$S5_STATE"
        return 1
    fi

    if [ "$_slbad" -ne 0 ]; then
        s5_err_msg state.corrupt
        return 1
    fi
    S5_STATE_BUF=$_slbuf
    S5_STATE_LOADED=1

    # Completeness: "status complete" claims the install flow ran to the end,
    # and that flow records every singleton key before status is written. A
    # state claiming completeness while missing keys is not a finished
    # installation -- a bare "status complete" used to load as installed,
    # making `install` a no-op and every lifecycle command operate on empty
    # fields. States WITHOUT the status key are mid-install records and load
    # normally: rollback and the uninstall retry path depend on that.
    if [ "$(s5_state_get status)" = "complete" ]; then
        _slmiss=''
        for _slk in $S5_STATE_KEYS_REQUIRED; do
            if [ "$_slk" != status ] && [ -z "$(s5_state_get "$_slk")" ]; then
                _slmiss="$_slmiss $_slk"
            fi
        done
        if [ -n "$_slmiss" ]; then
            s5_err_msg state.complete_missing "$_slmiss"
            S5_STATE_BUF=''
            S5_STATE_LOADED=0
            return 1
        fi
        if [ "$(s5_state_get origin)" = release-asset ]; then
            _slasset=$(s5_state_get asset)
            _slsha=$(s5_state_get sha256)
            if [ -z "$_slasset" ] || [ -z "$_slsha" ]; then
                s5_err_msg state.complete_missing " asset sha256"
                S5_STATE_BUF=''
                S5_STATE_LOADED=0
                return 1
            fi
            _slfamily=$(s5_state_get family)
            _slarch=$(s5_state_get arch)
            _slos=$(s5_state_get os)
            if ! s5_state_release_asset_ok "$_slos" "$_slfamily" "$_slarch" \
                "$_slasset" "$_slsha"; then
                s5_err_msg state.asset_mismatch
                S5_STATE_BUF=''
                S5_STATE_LOADED=0
                return 1
            fi
        fi
    fi
    return 0
}

# s5_state_flush : atomic rewrite of the whole state file. Return value checked
# by every caller.
s5_state_flush() {
    # The guard exists to refuse a state file some other process swapped out from
    # under this run. An ABSENT path is not that: s5_rollback removes the state
    # file and then, if the final rmdir fails, writes it back as the retry
    # handle -- and the inode of a deleted path never matches, so that restore
    # was unreachable and reported "keeping ...: it contains files this script
    # did not create" about a file the script itself had just deleted. The
    # identical sequence in _s5_cmd_uninstall_locked worked only because its
    # claim id happens to be empty.
    if [ -n "$S5_STATE_FILE_CLAIM_ID" ] &&
        { [ -e "$S5_STATE" ] || [ -L "$S5_STATE" ]; } &&
        ! s5_runtime_claim_matches "$S5_STATE"; then
        s5_err_msg rollback.keep_foreign_files "$S5_STATE"
        return 1
    fi
    if ! _sft=$(mktemp "$S5_STATEDIR/.s5state.XXXXXX"); then
        s5_err_msg state.mktemp_failed "$S5_STATEDIR"
        return 1
    fi
    if ! s5_secure_tmp "$_sft"; then
        rm -f "$_sft"
        return 1
    fi
    s5_modelog "tmp-created:$S5_STATE" "$_sft"
    if ! printf '%s\n' "$S5_STATE_BUF" >"$_sft"; then
        s5_err_msg state.write_failed
        rm -f "$_sft"
        return 1
    fi
    s5_modelog "tmp-written:$S5_STATE" "$_sft"
    if ! s5_apply_owner_mode "$_sft" "root:root" 0600; then
        rm -f "$_sft"
        return 1
    fi
    if ! mv "$_sft" "$S5_STATE"; then
        s5_err_msg state.install_failed
        rm -f "$_sft"
        return 1
    fi
    if [ -n "$S5_STATE_FILE_CLAIM_ID" ]; then
        S5_STATE_FILE_CLAIM_ID=$(stat -c '%d:%i' "$S5_STATE" 2>/dev/null)
        if [ -z "$S5_STATE_FILE_CLAIM_ID" ]; then
            s5_err_msg state.install_failed
            return 1
        fi
    fi
    return 0
}

# Undo what s5_state_begin managed to create before its first records could
# be persisted. Nothing exists outside the state directory at that point, so
# removing the directory is complete; rmdir also refuses to remove anything a
# concurrent foreign file landed in.
_s5_state_begin_undo() {
    if [ -n "$S5_PENDING_CLAIM_PATH" ]; then
        s5_pending_claim_remove >/dev/null 2>&1 || true
    fi
    if [ -n "$S5_STATE_FILE_CLAIM_ID" ] &&
        [ "$(stat -c '%d:%i' "$S5_STATE" 2>/dev/null)" = "$S5_STATE_FILE_CLAIM_ID" ]; then
        rm -f "$S5_STATE" 2>/dev/null || true
    fi
    if [ -n "$S5_STATE_DIR_CLAIM_ID" ] &&
        [ "$(stat -c '%d:%i' "$S5_STATEDIR" 2>/dev/null)" = "$S5_STATE_DIR_CLAIM_ID" ]; then
        rmdir "$S5_STATEDIR" 2>/dev/null || true
    fi
    S5_STATE_FILE_CLAIM_ID=''
    S5_STATE_DIR_CLAIM_ID=''
    S5_STATE_BUF=''
    S5_STATE_LOADED=0
}

s5_state_begin() {
    if ! s5_claim_dir "$S5_STATEDIR" "root:root" 0700; then
        return 1
    fi
    S5_STATE_DIR_CLAIM_ID=$S5_PENDING_CLAIM_ID
    s5_pending_claim_clear
    S5_STATE_BUF="tag	$S5_UPSTREAM_TAG
commit	$S5_PINNED_COMMIT
origin	release-asset
asset	$S5_ASSET_NAME
sha256	$S5_ASSET_SHA256"
    S5_STATE_LOADED=1
    if ! s5_publish_new_text "$S5_STATE" "root:root" 0600 "$S5_STATE_BUF"; then
        _s5_state_begin_undo
        return 1
    fi
    S5_STATE_FILE_CLAIM_ID=$S5_PENDING_CLAIM_ID
    s5_pending_claim_clear
    return 0
}

# s5_state_add <key> <value> : validate, append, and atomically rewrite.
s5_state_add() {
    if ! s5_state_key_known "$1"; then
        s5_err_msg state.record_unknown_key "$1"
        return 1
    fi
    if ! s5_state_value_ok "$1" "$2"; then
        return 1
    fi
    _saold=$S5_STATE_BUF
    if [ -n "$S5_STATE_BUF" ]; then
        S5_STATE_BUF="$S5_STATE_BUF
$1	$2"
    else
        S5_STATE_BUF="$1	$2"
    fi
    if ! s5_state_flush; then
        S5_STATE_BUF=$_saold
        _saold=''
        s5_err_msg state.persist_failed "$1"
        return 1
    fi
    _saold=''
    return 0
}

# Replace the mutable identity fields together and flush state once. All other
# provenance and ownership flags remain byte-for-byte equivalent in meaning.
s5_state_replace_identity() {
    if [ "$S5_STATE_LOADED" != "1" ] ||
        ! s5_state_value_ok port "$1" ||
        ! s5_state_value_ok username "$2"; then
        return 1
    fi
    _sriold=$S5_STATE_BUF
    if ! _srinew=$(printf '%s\n' "$S5_STATE_BUF" | awk -F'\t' -v p="$1" -v u="$2" '
        BEGIN { OFS="\t"; pc=0; uc=0 }
        $1=="port" { $2=p; pc++ }
        $1=="username" { $2=u; uc++ }
        { print }
        END { if (pc != 1 || uc != 1) exit 1 }
    '); then
        _sriold=''
        return 1
    fi
    S5_STATE_BUF=$_srinew
    _srinew=''
    if ! s5_state_flush; then
        S5_STATE_BUF=$_sriold
        _sriold=''
        return 1
    fi
    _sriold=''
    return 0
}

# s5_state_mark <flag-key> : record that this run created a fixed resource.
s5_state_mark() {
    s5_state_add "$1" 1
}

s5_state_claim_account() {
    # The writer must accept exactly what the loader accepts. The inline pattern
    # this replaced tested both ids as one colon-joined string, so a value that
    # itself contained a colon passed: "1:2" and "900" join to "1:2:900", which
    # has no disallowed character, no leading colon and no trailing colon. The
    # loader's account_uid arm rejects it, so the state file this wrote could
    # never be read back -- and with state unloadable, uninstall and rollback
    # both refuse to act, orphaning the account, the directories and the
    # cleartext credential file with no supported way to remove them.
    if ! s5_state_value_ok account_uid "$S5_CREATED_ACCOUNT_UID" ||
        ! s5_state_value_ok account_gid "$S5_CREATED_ACCOUNT_GID"; then
        return 1
    fi
    _scaold=$S5_STATE_BUF
    S5_STATE_BUF="$S5_STATE_BUF
account_uid	$S5_CREATED_ACCOUNT_UID
account_gid	$S5_CREATED_ACCOUNT_GID
created_account	1
created_group	1"
    if ! s5_state_flush; then
        S5_STATE_BUF=$_scaold
        _scaold=''
        s5_err_msg state.persist_failed created_account
        return 1
    fi
    _scaold=''
    S5_ACCOUNT_UID=$S5_CREATED_ACCOUNT_UID
    S5_ACCOUNT_GID=$S5_CREATED_ACCOUNT_GID
    S5_CREATED_ACCOUNT_UID=''
    S5_CREATED_ACCOUNT_GID=''
    S5_CREATED_USER_NAMED=0
    S5_CREATED_GROUP_NAMED=0
    return 0
}

s5_state_get() {
    if [ "$S5_STATE_LOADED" != "1" ]; then
        return 1
    fi
    printf '%s\n' "$S5_STATE_BUF" | awk -F'\t' -v k="$1" '$1==k {print $2}'
}

s5_state_flagged() {
    if [ "$S5_STATE_LOADED" != "1" ]; then
        return 1
    fi
    printf '%s\n' "$S5_STATE_BUF" | awk -F'\t' -v k="$1" '$1==k && $2=="1" {f=1} END {exit f?0:1}'
}

s5_is_installed() {
    if ! s5_state_load; then
        return 1
    fi
    [ "$(s5_state_get status)" = "complete" ]
}

# ---------------------------------------------------------------------------
# Mutation lock. mkdir is the portable atomic primitive available on every
# supported host; PID + boot ID + process start time distinguish a live owner
# from a stale directory without a time-based lease.
# ---------------------------------------------------------------------------

s5_process_start_id() {
    _pspid=$1
    if [ ! -r "/proc/$_pspid/stat" ]; then
        return 1
    fi
    _psline=$(cat "/proc/$_pspid/stat" 2>/dev/null) || return 1
    _psrest=$(printf '%s\n' "$_psline" | sed 's/^.*) //') || return 1
    _psstart=$(printf '%s\n' "$_psrest" | awk '{ if (NF >= 20) print $20 }')
    case "$_psstart" in
    '' | *[!0-9]*) return 1 ;;
    esac
    printf '%s' "$_psstart"
}

s5_process_state() {
    _pspid=$1
    if [ ! -r "/proc/$_pspid/stat" ]; then
        return 1
    fi
    _psline=$(cat "/proc/$_pspid/stat" 2>/dev/null) || return 1
    _psrest=$(printf '%s\n' "$_psline" | sed 's/^.*) //') || return 1
    _psstate=${_psrest%% *}
    case "$_psstate" in
    [A-Za-z]) printf '%s' "$_psstate" ;;
    *) return 1 ;;
    esac
}

s5_boot_id() {
    if [ ! -r /proc/sys/kernel/random/boot_id ]; then
        return 1
    fi
    IFS= read -r _sbid </proc/sys/kernel/random/boot_id || return 1
    case "$_sbid" in
    '' | *[!A-Fa-f0-9-]*) return 1 ;;
    esac
    printf '%s' "$_sbid"
}

# _s5_lock_claim : atomically claim the operation lock for this process.
# 0 = claimed and S5_LOCK_TOKEN is set, 1 = someone else already owns it,
# 2 = the attempt could not be made at all.
#
# The claim is the OWNER FILE, not the directory. mkdir used to be the claim,
# which left the lock present but unidentifiable for the several forks it took to
# read the boot id and this process's start time -- and the contention path
# treated an owner-less lock directory as garbage to rmdir, so a competitor
# caught inside that window had its live lock destroyed and taken. Verified:
# against a bare `mkdir $S5_LOCKDIR`, s5_lock_acquire returned 0 and wrote its
# own PID. `ln -T` is the same atomic no-replace primitive _s5_publish_new uses
# and s5_no_replace_supported already gates on, so the owner either appears whole
# or the link fails. There is no unowned instant to steal.
_s5_lock_claim() {
    if [ -L "$S5_LOCKDIR" ]; then
        return 2
    fi
    if [ ! -d "$S5_LOCKDIR" ]; then
        mkdir "$S5_LOCKDIR" 2>/dev/null || true
    fi
    if [ -L "$S5_LOCKDIR" ] || [ ! -d "$S5_LOCKDIR" ]; then
        return 2
    fi
    # umask 077 already makes a fresh mkdir 0700; this only narrows a directory
    # that survived from an earlier run.
    chmod 0700 "$S5_LOCKDIR" 2>/dev/null || true
    _lcboot=$(s5_boot_id) || return 2
    _lcstart=$(s5_process_start_id "$$") || return 2
    _lctmp=$(mktemp "$S5_LOCKDIR/.owner.XXXXXX" 2>/dev/null) || return 2
    S5_LOCK_TOKEN="$$
$_lcboot
$_lcstart"
    if ! printf '%s\n' "$S5_LOCK_TOKEN" >"$_lctmp" || ! chmod 0600 "$_lctmp"; then
        rm -f "$_lctmp" 2>/dev/null || true
        _lctmp=''
        S5_LOCK_TOKEN=''
        return 2
    fi
    if ln -T "$_lctmp" "$S5_LOCK_OWNER" 2>/dev/null; then
        rm -f "$_lctmp" 2>/dev/null || true
        _lctmp=''
        return 0
    fi
    rm -f "$_lctmp" 2>/dev/null || true
    _lctmp=''
    S5_LOCK_TOKEN=''
    return 1
}

# _s5_lock_break <owner-bytes-that-were-judged> : drop an owner record judged
# stale, but only while it is still byte-for-byte the record that was judged.
# Two processes can reach the same stale verdict; without the re-read the second
# would delete the fresh owner the first had already installed. Mutual exclusion
# no longer rests on this -- only one _s5_lock_claim can win afterwards -- but a
# fresh holder should not lose its lock to a straggler's stale verdict either.
_s5_lock_break() {
    if [ "$(cat "$S5_LOCK_OWNER" 2>/dev/null)" != "$1" ]; then
        return 1
    fi
    rm -f "$S5_LOCK_OWNER" 2>/dev/null
}

s5_lock_acquire() {
    if [ "$S5_LOCK_HELD" = "1" ]; then
        return 0
    fi
    _lap=${S5_LOCKDIR%/*}
    if [ ! -d "$_lap" ]; then
        if [ "${S5_TEST_MODE:-0}" = "1" ]; then
            mkdir -p "$_lap" || return 1
        else
            s5_err_msg lock.parent_missing "$_lap"
            return 1
        fi
    fi
    if [ -L "$_lap" ] || [ ! -d "$_lap" ]; then
        s5_err_msg lock.parent_invalid "$_lap"
        return 1
    fi
    if [ ! -w "$_lap" ]; then
        s5_err_msg lock.parent_denied "$_lap"
        return 1
    fi
    _latry=0
    while [ "$_latry" -lt 2 ]; do
        _latry=$((_latry + 1))
        _s5_lock_claim
        _lacl=$?
        case "$_lacl" in
        0)
            S5_LOCK_HELD=1
            return 0
            ;;
        2)
            s5_err_msg lock.create_failed "$S5_LOCKDIR"
            return 1
            ;;
        esac

        if [ -L "$S5_LOCK_OWNER" ] || [ ! -f "$S5_LOCK_OWNER" ]; then
            s5_err_msg lock.invalid "$S5_LOCKDIR"
            return 1
        fi
        # Read the record once. Every staleness verdict below is about THESE
        # bytes, and _s5_lock_break refuses to remove anything else.
        _laowner=$(cat "$S5_LOCK_OWNER" 2>/dev/null)
        _lapid=$(sed -n '1p' "$S5_LOCK_OWNER" 2>/dev/null)
        _laboot=$(sed -n '2p' "$S5_LOCK_OWNER" 2>/dev/null)
        _lastart=$(sed -n '3p' "$S5_LOCK_OWNER" 2>/dev/null)
        _lalines=$(wc -l <"$S5_LOCK_OWNER" 2>/dev/null | tr -d '[:space:]')
        case "$_lapid:$_lastart:$_lalines" in
        *[!0-9:]* | *::* | :* | *:)
            if _s5_lock_break "$_laowner"; then
                continue
            fi
            s5_err_msg lock.invalid "$S5_LOCKDIR"
            return 1
            ;;
        esac
        if [ "$_lalines" -ne 3 ]; then
            if _s5_lock_break "$_laowner"; then
                continue
            fi
            s5_err_msg lock.invalid "$S5_LOCKDIR"
            return 1
        fi
        case "$_laboot" in
        '' | *[!A-Fa-f0-9-]*) s5_err_msg lock.invalid "$S5_LOCKDIR"; return 1 ;;
        esac
        _lacurrentboot=$(s5_boot_id) || {
            s5_err_msg lock.identity_failed
            return 1
        }
        if [ "$_laboot" = "$_lacurrentboot" ] && [ -d "/proc/$_lapid" ]; then
            if ! _laprocessstate=$(s5_process_state "$_lapid"); then
                if [ ! -d "/proc/$_lapid" ]; then
                    if _s5_lock_break "$_laowner"; then
                        continue
                    fi
                fi
                s5_err_msg lock.invalid "$S5_LOCKDIR"
                return 1
            fi
            case "$_laprocessstate" in
            Z | X | x) ;;
            *)
                if ! _lacurrentstart=$(s5_process_start_id "$_lapid"); then
                    if [ ! -d "/proc/$_lapid" ]; then
                        if _s5_lock_break "$_laowner"; then
                            continue
                        fi
                    fi
                    s5_err_msg lock.invalid "$S5_LOCKDIR"
                    return 1
                fi
                if [ "$_lastart" = "$_lacurrentstart" ]; then
                    s5_err_msg lock.busy "$_lapid"
                    return 1
                fi
                ;;
            esac
        fi
        if ! _s5_lock_break "$_laowner"; then
            s5_err_msg lock.stale_remove_failed "$S5_LOCKDIR"
            return 1
        fi
    done
    s5_err_msg lock.busy unknown
    return 1
}

s5_lock_release() {
    if [ "$S5_LOCK_HELD" != "1" ]; then
        return 0
    fi
    if [ -L "$S5_LOCKDIR" ] || [ ! -d "$S5_LOCKDIR" ] ||
        [ -L "$S5_LOCK_OWNER" ] || [ ! -f "$S5_LOCK_OWNER" ] ||
        [ "$(cat "$S5_LOCK_OWNER" 2>/dev/null)" != "$S5_LOCK_TOKEN" ]; then
        s5_err_msg lock.release_refused "$S5_LOCKDIR"
        return 1
    fi
    if ! rm -f "$S5_LOCK_OWNER" || ! rmdir "$S5_LOCKDIR"; then
        # _s5_lock_claim stages its owner record as .owner.XXXXXX inside the lock
        # directory, so a claimant killed between mktemp and its own unlink leaves
        # one behind and rmdir answers ENOTEMPTY. That prefix is ours; sweep it
        # and retry rather than reporting the holder's release as a failure.
        for _lrt in "$S5_LOCKDIR"/.owner.*; do
            if [ -e "$_lrt" ] || [ -L "$_lrt" ]; then
                rm -f "$_lrt" || true
            fi
        done
        if ! rmdir "$S5_LOCKDIR"; then
            s5_err_msg lock.release_failed "$S5_LOCKDIR"
            return 1
        fi
    fi
    S5_LOCK_HELD=0
    S5_LOCK_TOKEN=''
    return 0
}

s5_with_mutation_lock() {
    if ! s5_lock_acquire; then
        return "$EX_FAIL"
    fi
    if ! s5_reconfigure_recover_pending; then
        s5_lock_release || true
        return "$EX_FAIL"
    fi
    "$@"
    _wmlrc=$?
    if ! s5_lock_release; then
        return "$EX_FAIL"
    fi
    return "$_wmlrc"
}

s5_with_uninstall_lock() {
    if ! s5_lock_acquire; then
        return "$EX_FAIL"
    fi
    if ! s5_reconfigure_recover_pending uninstall; then
        s5_lock_release || true
        return "$EX_FAIL"
    fi
    "$@"
    _wulrc=$?
    if ! s5_lock_release; then
        return "$EX_FAIL"
    fi
    return "$_wulrc"
}

s5_with_read_lock() {
    if [ "$S5_LOCK_HELD" = "1" ]; then
        "$@"
        return $?
    fi
    if ! s5_lock_acquire; then
        return "$EX_FAIL"
    fi
    "$@"
    _wrlrc=$?
    if ! s5_lock_release; then
        return "$EX_FAIL"
    fi
    return "$_wrlrc"
}

# ---------------------------------------------------------------------------
# Verified release-asset download and installation.
# ---------------------------------------------------------------------------

s5_make_workdir() {
    if [ "${S5_TEST_MODE:-0}" = "1" ]; then
        _wdbase=${S5_BUILD_DIR:-$S5_TEST_ROOT/build}
        mkdir -p "$_wdbase" || return 1
        mktemp -d "$_wdbase/b.XXXXXX"
        return $?
    fi
    _wdbase=/var/tmp
    if [ ! -d "$_wdbase" ] || [ ! -w "$_wdbase" ]; then
        _wdbase=${TMPDIR:-/tmp}
    fi
    mktemp -d "$_wdbase/socks5-manager-download.XXXXXX"
}

# s5_rm_workdir <dir> : remove a download directory only when its path matches
# this project's private template.
s5_rm_workdir() {
    case "${1:-}" in
    '' | '/')
        s5_warn_msg build.rm_refuse_empty
        return 1
        ;;
    */socks5-manager-download.* | */b.??????)
        if ! rm -rf "$1"; then
            s5_err_msg build.rm_failed "$1"
            return 1
        fi
        if [ -e "$1" ] || [ -L "$1" ]; then
            s5_err_msg build.rm_still_exists "$1"
            return 1
        fi
        return 0
        ;;
    *)
        s5_warn_msg build.rm_unexpected "$1"
        return 1
        ;;
    esac
}

s5_release_workdir() {
    if [ -z "$S5_WORKDIR" ]; then
        return 0
    fi
    if ! s5_rm_workdir "$S5_WORKDIR"; then
        return 1
    fi
    S5_WORKDIR=''
    return 0
}

s5_install_binary() {
    _ibmode=$2
    case "$_ibmode" in managed | ephemeral) ;; *) return 1 ;; esac
    # Shared ancestors may exist, but the project prefix and binary are claimed
    # exclusively at their final paths. Managed installation hands those claims
    # to state; the protocol harness uses an ephemeral private test root.
    if [ ! -d "$S5_ROOTDIR/usr" ]; then
        if ! s5_mkdir_secure "$S5_ROOTDIR/usr" "root:root" 0755; then return 1; fi
    fi
    if [ ! -d "$S5_ROOTDIR/usr/local" ]; then
        if ! s5_mkdir_secure "$S5_ROOTDIR/usr/local" "root:root" 0755; then return 1; fi
    fi
    if [ ! -d "$S5_ROOTDIR/usr/local/libexec" ]; then
        if ! s5_mkdir_secure "$S5_ROOTDIR/usr/local/libexec" "root:root" 0755; then return 1; fi
    fi
    if ! s5_claim_dir "$S5_PREFIX" "root:root" 0755; then
        return 1
    fi
    if [ "$_ibmode" = managed ]; then
        if ! s5_state_mark_claim created_prefix; then return 1; fi
    else
        S5_CLAIM_PREFIX_ID=$S5_PENDING_CLAIM_ID
        if ! s5_pending_claim_clear; then return 1; fi
    fi
    if ! s5_publish_new_file "$S5_BIN" "root:root" 0755 "$1"; then
        return 1
    fi
    if [ "$_ibmode" = managed ]; then
        if ! s5_state_mark_claim created_bin; then return 1; fi
    else
        S5_CLAIM_BIN_ID=$S5_PENDING_CLAIM_ID
        if ! s5_pending_claim_clear; then return 1; fi
    fi
    return 0
}

s5_fetch_verified_engine() {
    _fvemode=$1
    case "$_fvemode" in managed | ephemeral) ;; *) return 1 ;; esac
    if ! s5_select_engine_asset runtime; then
        return 1
    fi
    _bwd=$(s5_make_workdir)
    if [ -z "$_bwd" ] || [ ! -d "$_bwd" ]; then
        s5_err_msg build.mktmpdir_failed
        return 1
    fi
    S5_WORKDIR=$_bwd
    _asset_path="$_bwd/$S5_ASSET_NAME"
    _asset_fifo="$_bwd/asset.pipe"
    _asset_limit=$((S5_ASSET_SIZE + 1))

    if ! mkfifo "$_asset_fifo"; then
        s5_err_msg asset.download_failed "$S5_ASSET_NAME"
        s5_release_workdir
        return 1
    fi
    head -c "$_asset_limit" <"$_asset_fifo" >"$_asset_path" &
    S5_FETCH_READER_PID=$!

    s5_log_msg asset.fetching "$S5_ASSET_NAME" "$S5_ENGINE_RELEASE"
    _asset_curl_rc=0
    curl -q --fail --silent --show-error --location \
        --proto '=https' --proto-redir '=https' \
        --connect-timeout 10 --max-time 120 --max-filesize "$S5_ASSET_SIZE" \
        --output - "$S5_ASSET_URL" </dev/null >"$_asset_fifo" || _asset_curl_rc=$?
    _asset_reader_rc=0
    wait "$S5_FETCH_READER_PID" || _asset_reader_rc=$?
    S5_FETCH_READER_PID=''
    rm -f "$_asset_fifo" || true

    _asset_size=''
    if [ -f "$_asset_path" ] && [ ! -L "$_asset_path" ]; then
        _asset_size=$(wc -c <"$_asset_path" 2>/dev/null | tr -d '[:space:]')
    fi
    case "$_asset_size" in
    '' | *[!0-9]*) ;;
    *)
        if [ "$_asset_size" -gt "$S5_ASSET_SIZE" ]; then
            s5_err_msg asset.size_mismatch "$S5_ASSET_SIZE" "$_asset_size"
            s5_release_workdir
            return 1
        fi
        ;;
    esac
    if [ "$_asset_curl_rc" -ne 0 ] || [ "$_asset_reader_rc" -ne 0 ]; then
        s5_err_msg asset.download_failed "$S5_ASSET_NAME"
        s5_release_workdir
        return 1
    fi
    if [ ! -f "$_asset_path" ] || [ -L "$_asset_path" ]; then
        s5_err_msg build.no_artifact
        s5_release_workdir
        return 1
    fi
    if [ "$_asset_size" != "$S5_ASSET_SIZE" ]; then
        s5_err_msg asset.size_mismatch "$S5_ASSET_SIZE" "${_asset_size:-unknown}"
        s5_release_workdir
        return 1
    fi
    _asset_hash=$(sha256sum "$_asset_path" 2>/dev/null | awk '{ print $1 }')
    if [ "$_asset_hash" != "$S5_ASSET_SHA256" ]; then
        s5_err_msg asset.checksum_mismatch "$S5_ASSET_NAME"
        s5_release_workdir
        return 1
    fi
    s5_log_msg asset.verified "$S5_ASSET_NAME"

    if ! s5_install_binary "$_asset_path" "$_fvemode"; then
        s5_release_workdir
        return 1
    fi
    _installed_hash=$(sha256sum "$S5_BIN" 2>/dev/null | awk '{ print $1 }')
    if [ "$_installed_hash" != "$S5_ASSET_SHA256" ]; then
        s5_err_msg asset.installed_checksum_mismatch "$S5_BIN"
        # Remove it through the runtime inode claim, which BOTH placement modes
        # record. s5_rm_known_file is gated on the state flag, and the ephemeral
        # mode deliberately writes no state, so it returned 0 without removing
        # anything -- leaving an executable whose bytes failed verification
        # installed at $S5_BIN.
        if s5_runtime_claim_matches "$S5_BIN"; then
            rm -f "$S5_BIN" || true
        fi
        s5_release_workdir
        return 1
    fi
    s5_log_msg build.installed "$S5_BIN"
    if ! s5_release_workdir; then
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Rendering.  Pure: writes text to stdout and touches nothing.
#
# Protocol boundary enforced by the generated config:
#   auth strong       - RFC 1929 username/password is mandatory
#   socks -u2         - username/password must appear in the offered methods
#   socks -4          - IPv4 destination resolution only (NOT SOCKS4)
#   allow ... CONNECT - CONNECT is the only permitted operation
#   deny *            - terminal explicit deny
#
# The nine deny rules precede the allow rule, and 3proxy evaluates them against
# the RESOLVED destination address: src/socks.c:134 resolves an ATYP=3 domain
# into param->req before src/socks.c:196 runs the ACL, and src/acl.c:53-55
# matches the CIDR list against param->req. The connect at src/socks.c:186
# reuses that same address, so a hostname cannot bypass these rules.
# ---------------------------------------------------------------------------

S5_DENY_CIDRS='0.0.0.0/8
10.0.0.0/8
100.64.0.0/10
127.0.0.0/8
169.254.0.0/16
172.16.0.0/12
192.168.0.0/16
224.0.0.0/4
240.0.0.0/4'

s5_render_cfg() {
    if ! s5_valid_port "$S5_PORT" >/dev/null 2>&1; then
        s5_err_msg render.cfg_bad_port
        return 1
    fi
    if ! s5_valid_username "$S5_USERNAME" >/dev/null 2>&1; then
        s5_err_msg render.cfg_bad_username
        return 1
    fi
    printf 'log\n'
    printf 'users $%s\n' "$S5_USERSCFG"
    printf 'auth strong\n'
    printf 'flush\n'
    printf '%s\n' "$S5_DENY_CIDRS" | while IFS= read -r _dc; do
        if [ -n "$_dc" ]; then
            printf 'deny * * %s\n' "$_dc"
        fi
    done
    printf 'allow %s * * * CONNECT\n' "$S5_USERNAME"
    printf 'deny *\n'
    printf 'socks -4 -u2 -p%s -i%s\n' "$S5_PORT" "$S5_LISTEN"
    return 0
}

s5_render_users() {
    if ! s5_valid_username "$S5_USERNAME" >/dev/null 2>&1; then
        s5_err_msg render.users_bad_username
        return 1
    fi
    if ! s5_valid_password "$S5_PASSWORD" >/dev/null 2>&1; then
        s5_err_msg render.users_bad_password
        return 1
    fi
    printf '%s:CL:%s\n' "$S5_USERNAME" "$S5_PASSWORD"
    return 0
}

s5_render_systemd_unit() {
    cat <<UNIT_EOF
[Unit]
Description=$S5_PROJECT SOCKS5 proxy (3proxy $S5_UPSTREAM_TAG)
Documentation=$S5_REPO_URL
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$S5_SERVICE_USER
Group=$S5_SERVICE_GROUP
ExecStart=$S5_BIN $S5_CFG
Restart=on-failure
RestartSec=5s
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
LockPersonality=yes
SystemCallArchitectures=native
CapabilityBoundingSet=
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
UNIT_EOF
}

# OpenRC: no ordinary log files - output goes to syslog through logger.
# `need net` is deliberately not used.
s5_render_openrc() {
    cat <<'ORC_HEAD'
#!/sbin/openrc-run

ORC_HEAD
    cat <<ORC_BODY
name="$S5_PROJECT"
description="$S5_PROJECT SOCKS5 proxy (3proxy $S5_UPSTREAM_TAG)"
command="$S5_BIN"
command_args="$S5_CFG"
command_user="$S5_SERVICE_USER:$S5_SERVICE_GROUP"
supervisor="supervise-daemon"
output_logger="logger -t $S5_PROJECT -p daemon.info"
error_logger="logger -t $S5_PROJECT -p daemon.err"
ORC_BODY
    cat <<'ORC_TAIL'

depend() {
	after firewall
	use dns logger
}
ORC_TAIL
}

# ---------------------------------------------------------------------------
# Service account.  No home, nologin shell, never a password.
# Removal is verified, never assumed.
# ---------------------------------------------------------------------------

s5_nologin_path() {
    case "$S5_OS_FAMILY" in
    alpine) printf '/sbin/nologin' ;;
    *) printf '/usr/sbin/nologin' ;;
    esac
}

# s5_account_exists : prefer getent, which queries NSS for the exact name.
# `id` is the fallback for systems without getent (some musl images); it is
# less precise because it also resolves numeric UIDs. Return 0 when found, 1
# when definitely absent, and 2 when the identity database could not be queried.
s5_account_exists() {
    if command -v getent >/dev/null 2>&1; then
        getent passwd "$S5_SERVICE_USER" >/dev/null 2>&1
        _aer=$?
        case "$_aer" in
        0) return 0 ;;
        2) return 1 ;;
        *) return 2 ;;
        esac
    fi
    id "$S5_SERVICE_USER" >/dev/null 2>&1
    _aer=$?
    case "$_aer" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
    esac
}

# s5_current_uid / s5_current_gid : print the numeric id the fixed name
# answers to TODAY. Status 0 = printed, 1 = name definitely absent,
# 2 = the identity database could not be queried. Uninstall compares these
# against the ids recorded at creation time, because the fixed names can be
# removed and recreated by an unrelated workload, and deleting by name alone
# would delete the replacement.
s5_current_uid() {
    if command -v getent >/dev/null 2>&1; then
        _cuout=$(getent passwd "$S5_SERVICE_USER" 2>/dev/null)
        _curc=$?
        case "$_curc" in
        0)
            printf '%s' "$_cuout" | head -n 1 | cut -d: -f3
            return 0
            ;;
        2) return 1 ;;
        *) return 2 ;;
        esac
    fi
    _cuout=$(id -u "$S5_SERVICE_USER" 2>/dev/null) || return 2
    printf '%s' "$_cuout"
    return 0
}

s5_current_gid() {
    if command -v getent >/dev/null 2>&1; then
        _cgout=$(getent group "$S5_SERVICE_GROUP" 2>/dev/null)
        _cgrc=$?
        case "$_cgrc" in
        0)
            printf '%s' "$_cgout" | head -n 1 | cut -d: -f3
            return 0
            ;;
        2) return 1 ;;
        *) return 2 ;;
        esac
    fi
    _cgfile=${S5_ROOTDIR}/etc/group
    _cgout=$(grep "^$S5_SERVICE_GROUP:" "$_cgfile" 2>/dev/null | head -n 1)
    if [ -z "$_cgout" ]; then
        return 1
    fi
    printf '%s' "$_cgout" | cut -d: -f3
    return 0
}

s5_current_user_gid() {
    if command -v getent >/dev/null 2>&1; then
        _cugout=$(getent passwd "$S5_SERVICE_USER" 2>/dev/null)
        _cugrc=$?
        case "$_cugrc" in
        0)
            printf '%s' "$_cugout" | head -n 1 | cut -d: -f4
            return 0
            ;;
        2) return 1 ;;
        *) return 2 ;;
        esac
    fi
    _cugout=$(id -g "$S5_SERVICE_USER" 2>/dev/null) || return 2
    printf '%s' "$_cugout"
    return 0
}

s5_identity_matches() {
    _imuid=$1
    _imgid=$2
    case "$_imuid:$_imgid" in
    *[!0-9:]* | :* | *:) return 1 ;;
    esac
    [ "$(s5_current_uid 2>/dev/null)" = "$_imuid" ] &&
        [ "$(s5_current_gid 2>/dev/null)" = "$_imgid" ] &&
        [ "$(s5_current_user_gid 2>/dev/null)" = "$_imgid" ]
}

s5_group_exists() {
    if command -v getent >/dev/null 2>&1; then
        getent group "$S5_SERVICE_GROUP" >/dev/null 2>&1
        _ger=$?
        case "$_ger" in
        0) return 0 ;;
        2) return 1 ;;
        *) return 2 ;;
        esac
    fi
    # Same rooted database its sibling s5_current_gid reads. Reading the absolute
    # path here made the two disagree on the getent-less path they both exist to
    # serve: s5_current_gid answered from the rooted file while this answered from
    # the host's, so the collision check and the create/rollback paths could
    # disagree about whether the group exists.
    grep -q "^$S5_SERVICE_GROUP:" "${S5_ROOTDIR}/etc/group" 2>/dev/null
    _ger=$?
    case "$_ger" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
    esac
}

s5_account_create() {
    _nl=$(s5_nologin_path)
    S5_CREATED_ACCOUNT_UID=''
    S5_CREATED_ACCOUNT_GID=''
    S5_CREATED_USER_NAMED=0
    S5_CREATED_GROUP_NAMED=0
    case "$S5_OS_FAMILY" in
    alpine)
        s5_group_exists
        _acger=$?
        case "$_acger" in
        0)
            s5_err_msg install.group_appeared "$S5_SERVICE_GROUP"
            return 1
            ;;
        1)
            if ! addgroup -S "$S5_SERVICE_GROUP"; then
                s5_err_msg account.group_create_failed "$S5_SERVICE_GROUP"
                return 1
            fi
            S5_CREATED_GROUP_NAMED=1
            ;;
        *)
            s5_err_msg account.group_exists_unknown "$S5_SERVICE_GROUP"
            return 1
            ;;
        esac
        S5_CREATED_ACCOUNT_GID=$(s5_current_gid)
        _acgidrc=$?
        if [ "$_acgidrc" -ne 0 ] || [ -z "$S5_CREATED_ACCOUNT_GID" ]; then
            s5_err_msg install.gid_unknown
            return 1
        fi
        if [ "$(s5_current_gid)" != "$S5_CREATED_ACCOUNT_GID" ]; then
            s5_err_msg account.remove_gid_reused "$S5_SERVICE_GROUP" \
                "$(s5_current_gid 2>/dev/null || printf unknown)" "$S5_CREATED_ACCOUNT_GID"
            return 1
        fi
        if ! adduser -S -D -H -h /nonexistent -G "$S5_SERVICE_GROUP" -s "$_nl" "$S5_SERVICE_USER"; then
            s5_err_msg account.user_create_failed "$S5_SERVICE_USER"
            return 1
        fi
        S5_CREATED_USER_NAMED=1
        ;;
    *)
        s5_group_exists
        _acger=$?
        case "$_acger" in
        0)
            s5_err_msg install.group_appeared "$S5_SERVICE_GROUP"
            return 1
            ;;
        1)
            if ! groupadd -r "$S5_SERVICE_GROUP"; then
                s5_err_msg account.group_create_failed "$S5_SERVICE_GROUP"
                return 1
            fi
            S5_CREATED_GROUP_NAMED=1
            ;;
        *)
            s5_err_msg account.group_exists_unknown "$S5_SERVICE_GROUP"
            return 1
            ;;
        esac
        S5_CREATED_ACCOUNT_GID=$(s5_current_gid)
        _acgidrc=$?
        if [ "$_acgidrc" -ne 0 ] || [ -z "$S5_CREATED_ACCOUNT_GID" ]; then
            s5_err_msg install.gid_unknown
            return 1
        fi
        _acgidnow=$(s5_current_gid 2>/dev/null)
        if [ "$_acgidnow" != "$S5_CREATED_ACCOUNT_GID" ]; then
            s5_err_msg account.remove_gid_reused "$S5_SERVICE_GROUP" \
                "${_acgidnow:-unknown}" "$S5_CREATED_ACCOUNT_GID"
            return 1
        fi
        if ! useradd -r -g "$S5_SERVICE_GROUP" -M -d /nonexistent \
            -s "$_nl" "$S5_SERVICE_USER"; then
            s5_err_msg account.user_create_failed "$S5_SERVICE_USER"
            return 1
        fi
        S5_CREATED_USER_NAMED=1
        ;;
    esac
    S5_CREATED_ACCOUNT_UID=$(s5_current_uid)
    _acuidrc=$?
    _acgidnow=$(s5_current_gid 2>/dev/null)
    if [ "$_acuidrc" -ne 0 ] || [ -z "$S5_CREATED_ACCOUNT_UID" ]; then
        s5_err_msg install.uid_unknown
        return 1
    fi
    if [ "$_acgidnow" != "$S5_CREATED_ACCOUNT_GID" ]; then
        s5_err_msg account.remove_gid_reused "$S5_SERVICE_GROUP" \
            "${_acgidnow:-unknown}" "$S5_CREATED_ACCOUNT_GID"
        return 1
    fi
    if ! s5_identity_matches "$S5_CREATED_ACCOUNT_UID" "$S5_CREATED_ACCOUNT_GID"; then
        s5_err_msg account.remove_gid_reused "$S5_SERVICE_GROUP" \
            "${_acgidnow:-unknown}" "$S5_CREATED_ACCOUNT_GID"
        return 1
    fi
    return 0
}

# s5_del_user / s5_del_group : try the family's tool, then the other family's,
# without ever assuming success.
# _s5_del_principal <busybox-tool> <shadow-tool> <name> : delete a user or a
# group with whichever tool the target actually provides. The family's native
# tool is tried first -- busybox's deluser/delgroup on Alpine, shadow's
# userdel/groupdel elsewhere -- and the other is the fallback. A tool that is
# absent, or present but failing, falls through to the next candidate; only
# both failing is a failure.
_s5_del_principal() {
    case "$S5_OS_FAMILY" in
    alpine) _dpfirst=$1; _dpsecond=$2 ;;
    *) _dpfirst=$2; _dpsecond=$1 ;;
    esac
    if command -v "$_dpfirst" >/dev/null 2>&1 && "$_dpfirst" "$3" 2>/dev/null; then
        return 0
    fi
    if command -v "$_dpsecond" >/dev/null 2>&1 && "$_dpsecond" "$3" 2>/dev/null; then
        return 0
    fi
    return 1
}

s5_del_user() {
    _s5_del_principal deluser userdel "$S5_SERVICE_USER"
}

s5_del_group() {
    _s5_del_principal delgroup groupdel "$S5_SERVICE_GROUP"
}

s5_pending_account_remove() {
    if [ -n "$S5_CREATED_ACCOUNT_UID" ]; then
        if s5_account_remove 1 "$S5_CREATED_ACCOUNT_UID" "$S5_CREATED_ACCOUNT_GID"; then
            S5_CREATED_ACCOUNT_UID=''
            S5_CREATED_ACCOUNT_GID=''
            S5_CREATED_USER_NAMED=0
            S5_CREATED_GROUP_NAMED=0
            return 0
        fi
        return 1
    fi
    # A principal created moments ago whose id was never readable. The recorded
    # id is what normally licenses the delete, because the fixed names can have
    # been removed and recreated by an unrelated workload since; inside this
    # window there has been no such opportunity, so the name is a sound handle
    # and the only one left. Removal still has to be PROVEN: a database that
    # cannot be queried afterwards is a failed rollback that keeps its record.
    if [ "$S5_CREATED_USER_NAMED" = "1" ]; then
        s5_del_user || true
        s5_account_exists
        _parnu=$?
        case "$_parnu" in
        1) ;;
        0) s5_err_msg account.remove_user_failed "$S5_SERVICE_USER"; return 1 ;;
        *) s5_err_msg account.remove_user_unknown "$S5_SERVICE_USER"; return 1 ;;
        esac
        S5_CREATED_USER_NAMED=0
    fi
    if [ -z "$S5_CREATED_ACCOUNT_GID" ] && [ "$S5_CREATED_GROUP_NAMED" != "1" ]; then
        return 0
    fi
    if [ -n "$S5_CREATED_ACCOUNT_GID" ]; then
        _pargid=$(s5_current_gid 2>/dev/null)
        if [ "$_pargid" != "$S5_CREATED_ACCOUNT_GID" ]; then
            s5_err_msg account.remove_gid_reused "$S5_SERVICE_GROUP" \
                "${_pargid:-unknown}" "$S5_CREATED_ACCOUNT_GID"
            return 1
        fi
    fi
    s5_account_exists
    _paruser=$?
    if [ "$_paruser" -ne 1 ]; then
        s5_err_msg account.remove_user_unknown "$S5_SERVICE_USER"
        return 1
    fi
    s5_del_group || true
    # Tri-state, like every other identity query. A bare `if` here read status 2
    # ("the identity database could not be queried") as "absent", so an NSS error
    # made this report a clean rollback, clear the only fingerprint of the group
    # it had created, and leave that group on the host with nothing recording it
    # -- after which every later install refused at the collision check forever.
    # s5_account_remove dispatches the identical query correctly.
    s5_group_exists
    _pargr=$?
    case "$_pargr" in
    1) ;;
    0)
        s5_err_msg account.remove_group_failed "$S5_SERVICE_GROUP"
        return 1
        ;;
    *)
        s5_err_msg account.remove_group_unknown "$S5_SERVICE_GROUP"
        return 1
        ;;
    esac
    S5_CREATED_ACCOUNT_GID=''
    S5_CREATED_GROUP_NAMED=0
    return 0
}

# s5_account_remove <wantgroup> <recorded-uid> <recorded-gid> : returns
# non-zero unless the account (and the group, when this script created it) is
# verifiably gone afterwards. The recorded numeric ids are the fingerprint of
# what THIS script created: the fixed names may since have been removed and
# recreated by an unrelated workload, and a name-only match would delete the
# replacement. Without a recorded fingerprint nothing is deleted either --
# "created_account" alone only says the name was created once.
s5_account_remove() {
    _arwantgroup=$1
    _aruid=${2:-}
    _arbad=0

    case "$_aruid" in
    '' | *[!0-9]*)
        s5_err_msg account.remove_uid_missing "$S5_SERVICE_USER"
        return 1
        ;;
    esac
    _argid=''
    if [ "$_arwantgroup" = "1" ]; then
        case "${3:-}" in
        '' | *[!0-9]*)
            s5_err_msg account.remove_gid_missing "$S5_SERVICE_GROUP"
            return 1
            ;;
        esac
        _argid=$3
    fi

    s5_account_exists
    _arer=$?
    case "$_arer" in
    0)
        _arcuid=$(s5_current_uid)
        _arcus=$?
        if [ "$_arcus" -ne 0 ]; then
            s5_err_msg account.current_uid_unknown "$S5_SERVICE_USER"
            _arbad=1
        elif [ "$_arcuid" != "$_aruid" ]; then
            s5_err_msg account.remove_uid_reused "$S5_SERVICE_USER" "$_arcuid" "$_aruid"
            _arbad=1
        else
            s5_del_user || true
            s5_account_exists
            _arer=$?
            case "$_arer" in
            0)
                s5_err_msg account.remove_user_failed "$S5_SERVICE_USER"
                _arbad=1
                ;;
            1) ;;
            *)
                s5_err_msg account.remove_user_unknown "$S5_SERVICE_USER"
                _arbad=1
                ;;
            esac
        fi
        ;;
    1) ;;
    *)
        s5_err_msg account.exists_unknown "$S5_SERVICE_USER"
        _arbad=1
        ;;
    esac

    if [ "$_arwantgroup" = "1" ]; then
        s5_group_exists
        _ager=$?
        case "$_ager" in
        0)
            _arcgid=$(s5_current_gid)
            _arcgs=$?
            if [ "$_arcgs" -ne 0 ]; then
                s5_err_msg account.current_gid_unknown "$S5_SERVICE_GROUP"
                _arbad=1
            elif [ "$_arcgid" != "$_argid" ]; then
                s5_err_msg account.remove_gid_reused "$S5_SERVICE_GROUP" "$_arcgid" "$_argid"
                _arbad=1
            else
                s5_del_group || true
                s5_group_exists
                _ager=$?
                case "$_ager" in
                0)
                    s5_err_msg account.remove_group_failed "$S5_SERVICE_GROUP"
                    _arbad=1
                    ;;
                1) ;;
                *)
                    s5_err_msg account.remove_group_unknown "$S5_SERVICE_GROUP"
                    _arbad=1
                    ;;
                esac
            fi
            ;;
        1) ;;
        *)
            s5_err_msg account.group_exists_unknown2 "$S5_SERVICE_GROUP"
            _arbad=1
            ;;
        esac
    fi

    if [ "$_arbad" -ne 0 ]; then
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Static configuration check.
#
# 3proxy 0.9 has no documented config dry-run mode, so this is a textual check
# only; it does not prove the daemon will accept the file.
# ---------------------------------------------------------------------------

S5_FORBIDDEN_DIRECTIVES='proxy admin ftppr smtpp pop3p imapp tlspr tcppm udppm dnspr writable system plugin parent authcache chroot setuid setgid'

# s5_static_check_cfg <config-path> [credentials-path]
s5_static_check_cfg() {
    _scf=$1
    _scu=${2:-$S5_USERSCFG}
    if [ ! -f "$_scf" ]; then
        s5_err_msg static.not_found "$_scf"
        return 1
    fi
    _scbad=0

    if ! grep -q '^log$' "$_scf"; then
        s5_err_msg static.missing_log
        _scbad=1
    fi
    if ! grep -q '^auth strong$' "$_scf"; then
        s5_err_msg static.missing_auth_strong
        _scbad=1
    fi
    _scflushcount=$(grep -c '^flush$' "$_scf" || true)
    _scflush=$(grep -n '^flush$' "$_scf" | head -n 1 | cut -d: -f1)
    if [ "$_scflushcount" -ne 1 ]; then
        s5_err_msg static.one_flush
        _scbad=1
    fi
    if ! grep -q '^allow .* CONNECT$' "$_scf"; then
        s5_err_msg static.missing_allow_connect
        _scbad=1
    fi
    _scdenycount=$(grep -c '^deny \*$' "$_scf" || true)
    _scdenyline=$(grep -n '^deny \*$' "$_scf" | head -n 1 | cut -d: -f1)
    if [ "$_scdenycount" -ne 1 ]; then
        s5_err_msg static.one_terminal_deny
        _scbad=1
    fi
    if ! grep -q '^socks -4 -u2 -p[0-9][0-9]* -i' "$_scf"; then
        s5_err_msg static.missing_socks_line
        _scbad=1
    fi
    _scinclude=$(grep -cFx "users \$$S5_USERSCFG" "$_scf" || true)
    if [ "$_scinclude" -ne 1 ]; then
        s5_err_msg static.one_credentials_include
        _scbad=1
    fi
    # One socks line, and it must be exactly the one this port and listen
    # address call for. The count and the exact-line test are separate defects
    # with separate messages, so each is reported once rather than both firing
    # for a single miscount.
    _scsockcount=$(grep -c '^socks[[:space:]]' "$_scf" || true)
    if [ "$_scsockcount" -ne 1 ]; then
        s5_err_msg static.socks_count "$_scsockcount"
        _scbad=1
    elif ! grep -qxF "socks -4 -u2 -p$S5_PORT -i$S5_LISTEN" "$_scf"; then
        s5_err_msg static.one_socks_line "$S5_PORT" "$S5_LISTEN"
        _scbad=1
    fi

    # All nine destination denies must be present, and every one of them must
    # appear before the allow rule.
    #
    # This check uses NO scratch file. An earlier version wrote its findings to
    # "$cfg.denycheck.$$" with the redirect wrapped in `|| true`; when that write
    # failed (read-only directory, full disk, hostile pre-created path) the
    # result file was empty and a config MISSING deny rules passed. Counting in
    # the shell removes that fail-open entirely, and leaves nothing behind in the
    # configuration directory.
    _scallow=$(grep -n '^allow ' "$_scf" | head -n 1 | cut -d: -f1)
    _scallowcount=$(grep -c '^allow ' "$_scf" || true)
    if [ "$_scallowcount" -ne 1 ] ||
        ! grep -qxF "allow $S5_USERNAME * * * CONNECT" "$_scf"; then
        s5_err_msg static.one_allow_rule "$S5_USERNAME"
        _scbad=1
    fi
    if [ -z "$_scallow" ]; then
        _scallow=0
    fi
    _scfirstdeny=$(grep -n '^deny \* \* ' "$_scf" | head -n 1 | cut -d: -f1)
    if [ -z "$_scflush" ] || [ -z "$_scfirstdeny" ] ||
        [ "$_scflush" -ge "$_scfirstdeny" ]; then
        s5_err_msg static.flush_before_deny
        _scbad=1
    fi
    if [ -z "$_scdenyline" ] || [ "$_scallow" -eq 0 ] ||
        [ "$_scdenyline" -le "$_scallow" ]; then
        s5_err_msg static.deny_after_allow
        _scbad=1
    fi
    _scmissing=''
    _scwant=0
    for _scc in $S5_DENY_CIDRS; do
        _scwant=$((_scwant + 1))
        if ! grep -qxF "deny * * $_scc" "$_scf"; then
            _scmissing="$_scmissing $_scc"
        fi
    done
    if [ -n "$_scmissing" ]; then
        s5_err_msg static.missing_deny_rules "$_scmissing"
        _scbad=1
    fi

    _sclastdeny=$(grep -n '^deny \* \* ' "$_scf" | tail -n 1 | cut -d: -f1)
    if [ -z "$_sclastdeny" ]; then
        s5_err_msg static.no_deny_rules
        _scbad=1
    elif [ "$_scallow" -eq 0 ] || [ "$_sclastdeny" -ge "$_scallow" ]; then
        s5_err_msg static.deny_before_allow
        _scbad=1
    fi
    _sccidrcount=$(grep -c '^deny \* \* ' "$_scf" || true)
    if [ "$_sccidrcount" -ne "$_scwant" ]; then
        s5_err_msg static.deny_count "$_scwant" "$_sccidrcount"
        _scbad=1
    fi

    # Alternation is written as an ERE throughout. POSIX does not define \| in a
    # basic regular expression, and a grep that follows POSIX to the letter
    # matches such a pattern literally: a config carrying `auth none` or a
    # `plugin` line would then sail through this check. -E makes the alternation
    # portable, and the trailing group keeps `systemctlish` from being read as
    # the forbidden `system`.
    for _scd in $S5_FORBIDDEN_DIRECTIVES; do
        if grep -qE "^$_scd([[:space:]]|\$)" "$_scf"; then
            s5_err_msg static.forbidden_directive "$_scd"
            _scbad=1
        fi
    done
    if grep -qE 'auth none|auth iponly' "$_scf"; then
        s5_err_msg static.weak_auth
        _scbad=1
    fi
    if grep -qE 'BIND|UDPASSOC' "$_scf"; then
        s5_err_msg static.forbidden_op
        _scbad=1
    fi

    if [ ! -f "$_scu" ] || [ -L "$_scu" ]; then
        s5_err_msg static.cred_not_regular
        _scbad=1
    else
        _scm=$(stat -c '%a' "$_scu" 2>/dev/null || printf '')
        _sco=$(stat -c '%u:%g' "$_scu" 2>/dev/null || printf '')
        case "$_scm" in
        600 | 640) ;;
        *)
            s5_err_msg static.cred_mode "${_scm:-unknown}"
            _scbad=1
            ;;
        esac
        if [ "${S5_TEST_MODE:-0}" != 1 ] && [ "$_sco" != "0:$S5_ACCOUNT_GID" ]; then
            s5_err_msg static.cred_owner "$S5_SERVICE_GROUP" "${_sco:-unknown}"
            _scbad=1
        fi
        _screccount=$(grep -c '' "$_scu" 2>/dev/null)
        _scread=$?
        if [ "$_scread" -gt 1 ]; then
            s5_err_msg static.cred_unreadable
            _scbad=1
        elif [ "$_screccount" -ne 1 ]; then
            s5_err_msg static.cred_one_line
            _scbad=1
        else
            _scline=$(cat "$_scu" 2>/dev/null)
            _scread=$?
            if [ "$_scread" -ne 0 ]; then
                s5_err_msg static.cred_unreadable
                _scbad=1
            else
                case "$_scline" in
                *:CL:*)
                    _scuser=${_scline%%:CL:*}
                    _scpass=${_scline#*:CL:}
                    ;;
                *)
                    _scuser=''
                    _scpass=''
                    ;;
                esac
                if [ "$_scuser" != "$S5_USERNAME" ] ||
                    ! s5_valid_password "$_scpass" >/dev/null 2>&1 ||
                    [ "$_scpass" != "$S5_PASSWORD" ]; then
                    s5_err_msg static.cred_one_line
                    _scbad=1
                fi
            fi
        fi
    fi

    _scline=''; _scuser=''; _scpass=''
    if [ "$_scbad" -ne 0 ]; then
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Self-test. Credentials reach curl through `-q --config -` on stdin only.
# ---------------------------------------------------------------------------

s5_curl_config() {
    printf 'socks5-hostname = "127.0.0.1:%s"\n' "$S5_PORT"
    printf 'proxy-user = "%s:%s"\n' "$1" "$2"
    printf 'url = "%s"\n' "$S5_SELFTEST_URL"
    printf 'output = "/dev/null"\n'
    printf 'max-time = 20\n'
    printf 'silent\n'
    printf 'show-error\n'
    printf 'fail\n'
}

s5_selftest_good() {
    s5_curl_config "$1" "$2" | curl -q --config -
}

# The configured username paired with a guaranteed-different password must be
# refused BY THE PROXY. Current curl uses CURLE_PROXY (97). For curl 7.68,
# accept either its protocol-specific rejection text or a bad-good-bad
# differential where only the password changes. Every other combination is
# inconclusive.
s5_selftest_bad() {
    _stu=$1
    case "$2" in
    A*) _stp="B${2#?}" ;;
    *) _stp="A${2#?}" ;;
    esac
    _sterr=$(s5_curl_config "$_stu" "$_stp" | curl -q --config - 2>&1)
    _strc=$?
    _stlegacy=0
    if [ "$_strc" -eq "$S5_CURL_LEGACY_PROXY_ERR" ] &&
        ! printf '%s\n' "$_sterr" | grep -Fq "$S5_CURL_LEGACY_AUTH_TEXT"; then
        if s5_selftest_good "$_stu" "$2" >/dev/null 2>&1; then
            _sterr2=$(s5_curl_config "$_stu" "$_stp" | curl -q --config - 2>&1)
            _strc2=$?
            if [ "$_strc2" -eq "$S5_CURL_LEGACY_PROXY_ERR" ]; then
                _stlegacy=1
            fi
            _sterr2=''
        fi
    fi
    _stresult=0
    if [ "$_strc" -eq 0 ]; then
        s5_err_msg selftest.security_accepted
        _stresult=1
    elif [ "$_strc" -eq "$S5_CURL_PROXY_ERR" ] ||
        { [ "$_strc" -eq "$S5_CURL_LEGACY_PROXY_ERR" ] &&
          { [ "$_stlegacy" -eq 1 ] ||
            printf '%s\n' "$_sterr" | grep -Fq "$S5_CURL_LEGACY_AUTH_TEXT"; }; }; then
        _stresult=0
    else
        s5_err_msg selftest.inconclusive "$_strc" "$S5_CURL_PROXY_ERR"
        s5_err_msg selftest.rejection_unproven
        _stresult=1
    fi
    _stu=''; _stp=''; _sterr=''
    return "$_stresult"
}

s5_direct_egress_ok() {
    curl -q -fsS -o /dev/null --max-time 15 "$S5_SELFTEST_URL" >/dev/null 2>&1
}

s5_dns_ok() {
    if command -v getent >/dev/null 2>&1; then
        getent hosts example.com >/dev/null 2>&1
        return $?
    fi
    return 0
}

s5_diagnose_failure() {
    if s5_direct_egress_ok; then
        printf 'proxy-failure'
        return 0
    else
        _sdfr=$?
    fi
    if ! s5_dns_ok; then
        printf 'dns-failure'
        return 0
    fi
    if [ "$_sdfr" -eq "$S5_CURL_HTTP_ERR" ]; then
        printf 'external-service-failure'
        return 0
    fi
    printf 'no-egress'
    return 0
}

s5_explain_failure() {
    case "$1" in
    dns-failure) s5_say_msg network.cause_dns ;;
    no-egress) s5_say_msg network.cause_no_egress ;;
    external-service-failure) s5_say_msg network.cause_external_service ;;
    proxy-failure)
        s5_say_msg network.cause_proxy_refused
        s5_say_msg network.cause_check_sgp
        ;;
    *) s5_say_msg network.cause_unknown ;;
    esac
}

# ---------------------------------------------------------------------------
# Service management
# ---------------------------------------------------------------------------

s5_service_install() {
    case "$S5_INIT" in
    systemd)
        if ! s5_mkdir_secure "$S5_UNITDIR" "root:root" 0755; then
            return 1
        fi
        _sut=$(s5_render_systemd_unit) || return 1
        if ! s5_publish_new_text "$S5_UNIT" "root:root" 0644 "$_sut"; then
            return 1
        fi
        if ! s5_state_mark_claim created_unit; then return 1; fi
        if ! systemctl daemon-reload >/dev/null 2>&1; then
            s5_err_msg service.reload_failed "$S5_UNIT"
            return 1
        fi
        if ! systemctl enable "$S5_PROJECT.service" >/dev/null 2>&1; then
            s5_err_msg service.enable_failed "$S5_PROJECT"
            return 1
        fi
        ;;
    openrc)
        if ! s5_mkdir_secure "$S5_INITDIR" "root:root" 0755; then
            return 1
        fi
        _sot=$(s5_render_openrc) || return 1
        if ! s5_publish_new_text "$S5_INITSCRIPT" "root:root" 0755 "$_sot"; then
            return 1
        fi
        if ! s5_state_mark_claim created_initscript; then return 1; fi
        if ! rc-update add "$S5_PROJECT" default >/dev/null 2>&1; then
            s5_err_msg service.rcupdate_failed "$S5_PROJECT"
            return 1
        fi
        ;;
    *)
        s5_err_msg service.unsupported_init "${S5_INIT:-unknown}"
        return 1
        ;;
    esac
    return 0
}

# _s5_openrc_start <verb> : run `rc-service <svc> <verb>` (verb: start or
# restart) and classify its exit status instead of trusting it.
#
# Why rc-service's nonzero exit cannot be read as a verdict: OpenRC 0.53
# (Alpine 3.20) under supervisor="supervise-daemon" marks the service
# "starting" while the supervised daemon is still coming up, and a start or
# restart command issued against a "starting" service is refused with
# " * WARNING: <svc> is already starting" and a nonzero exit -- even when
# the daemon is in fact on its way up; newer OpenRC completes the same
# install without the warning. The exit code answers for the
# COMMAND; only the manager's status answers for the SERVICE. So a nonzero
# exit is re-classified through the tri-state s5_service_active:
#   active (0)        -> the service really is starting/started: success,
#                        and s5_wait_listening covers the not-yet-bound
#                        socket, exactly as for a zero exit.
#   inactive (1)      -> genuinely failed: report the original nonzero.
#   unobservable (2)  -> fail closed, reporting the original nonzero.
# The re-query is a classification, not a wait: readiness itself is settled by
# the bounded port wait that follows. The inactive arm is the one exception --
# a start refused under lock contention answers inactive before the lock's
# holder finishes -- so that arm alone retries, four attempts one second
# apart, before reporting the original nonzero.
_s5_openrc_start() {
    # rc-service's exit status reports the start COMMAND, and openrc-run
    # prints "already starting" with a nonzero exit when the service's
    # exclusive lock cannot be flocked (svc_lock/EWOULDBLOCK) -- a contention
    # with another process, not a verdict that the service cannot run. So a
    # nonzero start is re-queried against the manager's own tri-state: active
    # means the start took (the port wait settles readiness); definitely
    # inactive gets a bounded retry for the lock-contention shape (Alpine
    # 3.20's re-query can answer stopped while the lock is held); anything
    # else fails closed on the first attempt.
    _oon=0
    while [ "$_oon" -le 3 ]; do
        rc-service "$S5_PROJECT" "$1"
        _oos=$?
        if [ "$_oos" -eq 0 ]; then
            return 0
        fi
        s5_service_active
        _ooa=$?
        case "$_ooa" in
        0) return 0 ;;
        1) ;;
        *) return "$_oos" ;;
        esac
        _oon=$((_oon + 1))
        if [ "$_oon" -le 3 ]; then
            sleep 1
        fi
    done
    return "$_oos"
}

s5_service_start() {
    case "$S5_INIT" in
    systemd) systemctl start "$S5_PROJECT.service" ;;
    openrc) _s5_openrc_start start ;;
    *) return 1 ;;
    esac
}

s5_service_stop() {
    case "$S5_INIT" in
    systemd) systemctl stop "$S5_PROJECT.service" ;;
    openrc) rc-service "$S5_PROJECT" stop ;;
    *) return 1 ;;
    esac
}

s5_service_restart() {
    case "$S5_INIT" in
    systemd) systemctl restart "$S5_PROJECT.service" ;;
    openrc) _s5_openrc_start restart ;;
    *) return 1 ;;
    esac
}

s5_service_disable() {
    case "$S5_INIT" in
    systemd)
        if ! systemctl disable "$S5_PROJECT.service" >/dev/null 2>&1; then
            s5_err_msg service.disable_failed "$S5_PROJECT"
            return 1
        fi
        ;;
    openrc)
        if ! rc-update del "$S5_PROJECT" default >/dev/null 2>&1; then
            s5_err_msg service.rcdel_failed "$S5_PROJECT"
            return 1
        fi
        ;;
    *) : ;;
    esac
    return 0
}

s5_service_active() {
    case "$S5_INIT" in
    systemd)
        systemctl is-active "$S5_PROJECT.service" >/dev/null 2>&1
        _sar=$?
        case "$_sar" in
        0) return 0 ;;
        3) return 1 ;;
        *) return 2 ;;
        esac
        ;;
    openrc)
        rc-service "$S5_PROJECT" status >/dev/null 2>&1
        _sar=$?
        # openrc-run's status verb returns the service state as the exit
        # code: started=0, stopped=3, stopping=4, starting=8, inactive=16,
        # crashed=32; rc-service itself exits 1 when the service script
        # does not exist at all. 8 (starting) is the supervise-daemon
        # startup phase -- the manager vouches the service exists and is
        # coming up -- so it counts as active and the port wait settles
        # readiness; stopped, crashed and never-written are definitively
        # not running; stopping and inactive are not an answer either way.
        case "$_sar" in
        0 | 8) return 0 ;;
        1 | 3 | 32) return 1 ;;
        *) return 2 ;;
        esac
        ;;
    *) return 2 ;;
    esac
}

# s5_port_listening : 0 = listening, 1 = not listening, 2 = cannot observe.
#
# Three states, not two. s5_port_free is fail-closed and answers "not free"
# when it cannot look at all; negating that answer would turn "cannot observe"
# into an affirmative "listening", so callers must dispatch on the status
# instead of negating this function.
s5_port_listening() {
    if ! s5_port_probe_available; then
        return 2
    fi
    s5_port_free "$S5_PORT" "$S5_LISTEN"
    _spl=$?
    case "$_spl" in
    0) return 1 ;;
    1) return 0 ;;
    *) return 2 ;;
    esac
}

# s5_wait_listening <port> : bounded poll of s5_port_listening.
#
# Why a wait exists at all: the shipped unit is Type=simple, and OpenRC under
# supervise-daemon behaves the same way -- the manager reports the service
# active the moment the process is forked, before any socket is bound. A
# single immediate probe therefore fails on every host slower than the
# manager's fork and rolls back a perfectly good install (observed in the
# first real CI run on both systemd and OpenRC cells). Fifteen one-second
# tries is ample for a local process binding a socket.
#
# Constraints the shape must honour:
#   * whole seconds only -- fractional sleep is a GNU/busybox extension, not
#     POSIX, and this script must run under any POSIX sh.
#   * status 2 from s5_port_listening is "cannot observe", not "not yet".
#     Retrying it could only turn an unobservable state into a false success,
#     so it is reported and fails immediately, exactly as the single probe
#     before the wait did.
#   * fail fast only on DEFINITE inactivity (status 1 from s5_service_active).
#     OpenRC's "starting" answers active, and an unobservable manager (status
#     2) is not evidence of death; a service in either state may still bind,
#     so neither may abort the wait.
s5_wait_listening() {
    _wlport=${1:-$S5_PORT}
    # s5_port_listening observes S5_PORT rather than its arguments, so the
    # port becomes S5_PORT for the duration of the wait. Both callers pass
    # their own S5_PORT; a direct caller naming another port still gets an
    # answer about that port.
    S5_PORT=$_wlport
    _wltry=0
    while :; do
        s5_port_listening
        _wls=$?
        case "$_wls" in
        0) return 0 ;;
        2)
            s5_err_msg service.wait_no_probe "$_wlport"
            return 1
            ;;
        esac
        s5_service_active
        _wla=$?
        if [ "$_wla" -eq 1 ]; then
            s5_err_msg service.wait_exited "$_wlport"
            return 1
        fi
        _wltry=$((_wltry + 1))
        if [ "$_wltry" -ge 15 ]; then
            break
        fi
        sleep 1
    done
    s5_err_msg service.wait_timeout "$_wlport"
    return 1
}

# Shared post-start verification for initial installation, reconfiguration and
# recovery. Every property must be observed; an indeterminate result fails.
s5_verify_running_config() {
    s5_service_active
    _vrc=$?
    case "$_vrc" in
    0) ;;
    1)
        s5_err_msg install.not_active_after_start
        return 1
        ;;
    *)
        s5_err_msg install.active_unverified
        return 1
        ;;
    esac
    if ! s5_wait_listening "$S5_PORT"; then
        return 1
    fi
    s5_log_msg install.verifying_bad
    if ! s5_selftest_bad "$S5_USERNAME" "$S5_PASSWORD"; then
        return 1
    fi
    s5_log_msg install.verifying_good
    if ! s5_selftest_good "$S5_USERNAME" "$S5_PASSWORD"; then
        _vrd=$(s5_diagnose_failure)
        s5_err_msg install.selftest_failed "$_vrd"
        s5_explain_failure "$_vrd"
        _vrd=''
        return 1
    fi
    return 0
}

# Stop the managed proxy and prove it is no longer active before replacing any
# file it may have open.
s5_stop_and_confirm() {
    s5_service_active
    _sacr=$?
    case "$_sacr" in
    0) s5_service_stop >/dev/null 2>&1 || true ;;
    1) return 0 ;;
    *)
        s5_err_msg reconfigure.stop_unverified
        return 1
        ;;
    esac
    s5_service_active
    _sacr=$?
    case "$_sacr" in
    1) return 0 ;;
    0) s5_err_msg reconfigure.still_active ;;
    *) s5_err_msg reconfigure.stop_unverified ;;
    esac
    return 1
}

# ---------------------------------------------------------------------------
# Reconfiguration transaction. The interface is intentionally one function:
# validated candidate values enter through S5_PORT/S5_USERNAME/S5_PASSWORD;
# success means the new proxy is verified, while failure restores and verifies
# the prior proxy or leaves a root-only recovery bundle for the next run.
# ---------------------------------------------------------------------------

_s5_copy_file_secure() {
    _cfsrc=$1
    _cfdst=$2
    _cfowner=$3
    _cfmode=$4
    if [ ! -f "$_cfsrc" ] || [ -L "$_cfsrc" ] || [ -L "$_cfdst" ]; then
        return 1
    fi
    _cfdir=${_cfdst%/*}
    _cftmp=$(mktemp "$_cfdir/.s5copy.XXXXXX") || return 1
    if ! s5_secure_tmp "$_cftmp" || ! cp "$_cfsrc" "$_cftmp" ||
        ! s5_apply_owner_mode "$_cftmp" "$_cfowner" "$_cfmode" ||
        ! mv "$_cftmp" "$_cfdst"; then
        rm -f "$_cftmp" 2>/dev/null || true
        _cftmp=''
        return 1
    fi
    _cftmp=''
    return 0
}

_s5_txn_write_phase() {
    printf '%s\n' "$1" | s5_atomic_write "$S5_TXN_PHASE" "root:root" 0600
}

_s5_txn_read_phase() {
    if [ ! -f "$S5_TXN_PHASE" ] || [ -L "$S5_TXN_PHASE" ]; then
        return 1
    fi
    _trp=$(cat "$S5_TXN_PHASE" 2>/dev/null) || return 1
    case "$_trp" in
    staging | armed | committed) printf '%s' "$_trp" ;;
    *) return 1 ;;
    esac
}

_s5_txn_cleanup() {
    if [ ! -e "$S5_TXNDIR" ] && [ ! -L "$S5_TXNDIR" ]; then
        return 0
    fi
    if [ -L "$S5_TXNDIR" ] || [ ! -d "$S5_TXNDIR" ]; then
        s5_err_msg reconfigure.transaction_invalid "$S5_TXNDIR"
        return 1
    fi
    for _tcf in "$S5_TXNDIR"/.s5tmp.* "$S5_TXNDIR"/.s5copy.*; do
        if [ -e "$_tcf" ] || [ -L "$_tcf" ]; then
            rm -f "$_tcf" || return 1
        fi
    done
    _tcextra=$(s5_dir_extras "$S5_TXNDIR" phase new.users.cfg new.3proxy.cfg \
        old.users.cfg old.3proxy.cfg old.state)
    if [ -n "$_tcextra" ]; then
        s5_err_msg reconfigure.transaction_cleanup_failed "$S5_TXNDIR"
        return 1
    fi
    _tcphase=$(_s5_txn_read_phase 2>/dev/null || printf '')
    for _tcf in "$S5_TXN_NEW_USERS" "$S5_TXN_NEW_CFG" \
        "$S5_TXN_OLD_USERS" "$S5_TXN_OLD_CFG" "$S5_TXN_OLD_STATE"; do
        rm -f "$_tcf" || return 1
    done
    rm -f "$S5_TXN_PHASE" || return 1
    if ! rmdir "$S5_TXNDIR"; then
        if [ -d "$S5_TXNDIR" ] && [ -n "$_tcphase" ]; then
            _s5_txn_write_phase "$_tcphase" >/dev/null 2>&1 || true
        fi
        s5_err_msg reconfigure.transaction_cleanup_failed "$S5_TXNDIR"
        return 1
    fi
    return 0
}

_s5_reconfigure_precheck() {
    if ! s5_state_load || [ "$(s5_state_get status)" != complete ]; then
        s5_err_msg reconfigure.state_invalid
        return 1
    fi
    for _rpf in created_bin created_cfg created_users; do
        if ! s5_state_flagged "$_rpf"; then
            s5_err_msg reconfigure.state_invalid
            return 1
        fi
    done
    S5_INIT=$(s5_state_get init)
    S5_OS_FAMILY=$(s5_state_get family)
    S5_LISTEN=$(s5_state_get listen)
    S5_PORT=$(s5_state_get port)
    S5_ACCOUNT_UID=$(s5_state_get account_uid)
    S5_ACCOUNT_GID=$(s5_state_get account_gid)
    if ! s5_identity_matches "$S5_ACCOUNT_UID" "$S5_ACCOUNT_GID"; then
        s5_err_msg reconfigure.state_invalid
        return 1
    fi
    case "$S5_INIT" in
    systemd)
        s5_state_flagged created_unit || { s5_err_msg reconfigure.state_invalid; return 1; }
        _rpservice=$S5_UNIT
        ;;
    openrc)
        s5_state_flagged created_initscript || { s5_err_msg reconfigure.state_invalid; return 1; }
        _rpservice=$S5_INITSCRIPT
        ;;
    *) s5_err_msg reconfigure.state_invalid; return 1 ;;
    esac
    if [ ! -x "$S5_BIN" ] || [ -L "$S5_BIN" ] ||
        [ ! -f "$S5_CFG" ] || [ -L "$S5_CFG" ] ||
        [ ! -f "$S5_USERSCFG" ] || [ -L "$S5_USERSCFG" ] ||
        [ ! -f "$S5_STATE" ] || [ -L "$S5_STATE" ] ||
        [ ! -f "$_rpservice" ] || [ -L "$_rpservice" ]; then
        s5_err_msg reconfigure.files_invalid
        return 1
    fi
    if [ "$(stat -c '%a' "$S5_CFG" 2>/dev/null)" != 640 ] ||
        [ "$(stat -c '%a' "$S5_USERSCFG" 2>/dev/null)" != 640 ] ||
        [ "$(stat -c '%a' "$S5_STATE" 2>/dev/null)" != 600 ]; then
        s5_err_msg reconfigure.files_invalid
        return 1
    fi
    if [ "${S5_TEST_MODE:-0}" != 1 ]; then
        if [ "$(stat -c '%u:%g' "$S5_CFG" 2>/dev/null)" != "0:$S5_ACCOUNT_GID" ] ||
            [ "$(stat -c '%u:%g' "$S5_USERSCFG" 2>/dev/null)" != "0:$S5_ACCOUNT_GID" ] ||
            [ "$(stat -c '%u:%g' "$S5_STATE" 2>/dev/null)" != 0:0 ]; then
            s5_err_msg reconfigure.files_invalid
            return 1
        fi
    fi
    if ! s5_load_credentials ||
        [ "$S5_USERNAME" != "$(s5_state_get username)" ] ||
        ! s5_static_check_cfg "$S5_CFG" "$S5_USERSCFG"; then
        s5_err_msg reconfigure.files_invalid
        return 1
    fi
    s5_service_active
    _rpa=$?
    if [ "$_rpa" -ne 0 ]; then
        s5_err_msg reconfigure.current_not_healthy
        return 1
    fi
    s5_port_listening
    _rpl=$?
    if [ "$_rpl" -ne 0 ]; then
        s5_err_msg reconfigure.current_not_healthy
        return 1
    fi
    return 0
}

_s5_reconfigure_stage() {
    if [ -e "$S5_TXNDIR" ] || [ -L "$S5_TXNDIR" ]; then
        s5_err_msg reconfigure.transaction_exists "$S5_TXNDIR"
        return 1
    fi
    if ! mkdir "$S5_TXNDIR"; then
        s5_err_msg reconfigure.transaction_create_failed "$S5_TXNDIR"
        return 1
    fi
    if ! s5_apply_owner_mode "$S5_TXNDIR" "root:root" 0700; then
        rmdir "$S5_TXNDIR" 2>/dev/null || true
        s5_err_msg reconfigure.transaction_create_failed "$S5_TXNDIR"
        return 1
    fi
    if ! _s5_txn_write_phase staging ||
        ! _s5_copy_file_secure "$S5_USERSCFG" "$S5_TXN_OLD_USERS" "root:root" 0600 ||
        ! _s5_copy_file_secure "$S5_CFG" "$S5_TXN_OLD_CFG" "root:root" 0600 ||
        ! _s5_copy_file_secure "$S5_STATE" "$S5_TXN_OLD_STATE" "root:root" 0600; then
        s5_err_msg reconfigure.stage_failed
        _s5_txn_cleanup || true
        return 1
    fi

    _tx_users_body=$(s5_render_users) || {
        _tx_users_body=''
        _s5_txn_cleanup || true
        return 1
    }
    if ! printf '%s\n' "$_tx_users_body" |
        s5_atomic_write "$S5_TXN_NEW_USERS" "0:$S5_ACCOUNT_GID" 0640; then
        _tx_users_body=''
        s5_err_msg reconfigure.stage_failed
        _s5_txn_cleanup || true
        return 1
    fi
    _tx_users_body=''
    _tx_cfg_body=$(s5_render_cfg) || {
        _tx_cfg_body=''
        _s5_txn_cleanup || true
        return 1
    }
    if ! printf '%s\n' "$_tx_cfg_body" |
        s5_atomic_write "$S5_TXN_NEW_CFG" "root:root" 0600; then
        _tx_cfg_body=''
        s5_err_msg reconfigure.stage_failed
        _s5_txn_cleanup || true
        return 1
    fi
    _tx_cfg_body=''
    if ! s5_static_check_cfg "$S5_TXN_NEW_CFG" "$S5_TXN_NEW_USERS" ||
        ! _s5_txn_write_phase armed; then
        s5_err_msg reconfigure.stage_failed
        _s5_txn_cleanup || true
        return 1
    fi
    S5_RECONFIG_ARMED=1
    return 0
}

_s5_reconfigure_restore() {
    _rrmode=${1:-verify}
    case "$_rrmode" in
    verify | uninstall) ;;
    *) return 1 ;;
    esac
    for _rrf in "$S5_TXN_OLD_USERS" "$S5_TXN_OLD_CFG" "$S5_TXN_OLD_STATE"; do
        if [ ! -f "$_rrf" ] || [ -L "$_rrf" ]; then
            s5_err_msg reconfigure.restore_missing "$S5_TXNDIR"
            return 1
        fi
    done
    _rrinit=$(awk -F'\t' '$1=="init" { print $2 }' "$S5_TXN_OLD_STATE")
    _rruid=$(awk -F'\t' '$1=="account_uid" { print $2 }' "$S5_TXN_OLD_STATE")
    _rrgid=$(awk -F'\t' '$1=="account_gid" { print $2 }' "$S5_TXN_OLD_STATE")
    case "$_rrinit" in
    systemd | openrc) S5_INIT=$_rrinit ;;
    *) s5_err_msg reconfigure.restore_invalid; return 1 ;;
    esac
    if ! s5_identity_matches "$_rruid" "$_rrgid"; then
        s5_err_msg reconfigure.restore_invalid
        return 1
    fi
    S5_ACCOUNT_UID=$_rruid
    S5_ACCOUNT_GID=$_rrgid
    if ! s5_stop_and_confirm; then
        s5_err_msg reconfigure.restore_stop_failed
        return 1
    fi
    if ! _s5_copy_file_secure "$S5_TXN_OLD_USERS" "$S5_USERSCFG" "0:$S5_ACCOUNT_GID" 0640 ||
        ! _s5_copy_file_secure "$S5_TXN_OLD_CFG" "$S5_CFG" "0:$S5_ACCOUNT_GID" 0640 ||
        ! _s5_copy_file_secure "$S5_TXN_OLD_STATE" "$S5_STATE" "root:root" 0600; then
        s5_err_msg reconfigure.restore_files_failed "$S5_TXNDIR"
        return 1
    fi
    if ! s5_state_load; then
        s5_err_msg reconfigure.restore_invalid
        return 1
    fi
    S5_INIT=$(s5_state_get init)
    S5_OS_FAMILY=$(s5_state_get family)
    S5_LISTEN=$(s5_state_get listen)
    S5_PORT=$(s5_state_get port)
    if ! s5_load_credentials || ! s5_static_check_cfg "$S5_CFG" "$S5_USERSCFG"; then
        s5_err_msg reconfigure.restore_invalid
        return 1
    fi
    S5_SECRET=$S5_PASSWORD
    if [ "$_rrmode" = uninstall ]; then
        if ! _s5_txn_write_phase committed || ! _s5_txn_cleanup; then
            return 1
        fi
        s5_log_msg reconfigure.restored_for_uninstall
        return 0
    fi
    s5_log_msg reconfigure.restoring
    if ! s5_service_start || ! s5_verify_running_config; then
        s5_err_msg reconfigure.restore_service_failed "$S5_TXNDIR"
        return 1
    fi
    if ! _s5_txn_write_phase committed; then
        s5_err_msg reconfigure.restore_files_failed "$S5_TXNDIR"
        return 1
    fi
    if ! _s5_txn_cleanup; then
        return 1
    fi
    s5_log_msg reconfigure.restored
    return 0
}

s5_reconfigure_recover_pending() {
    _rrmode=${1:-verify}
    if [ ! -e "$S5_TXNDIR" ] && [ ! -L "$S5_TXNDIR" ]; then
        return 0
    fi
    if [ -L "$S5_TXNDIR" ] || [ ! -d "$S5_TXNDIR" ]; then
        s5_err_msg reconfigure.transaction_invalid "$S5_TXNDIR"
        return 1
    fi
    if [ ! -e "$S5_TXN_PHASE" ] && [ ! -L "$S5_TXN_PHASE" ]; then
        s5_warn_msg reconfigure.pending_cleanup
        _s5_txn_cleanup
        return $?
    fi
    _rrphase=$(_s5_txn_read_phase) || {
        s5_err_msg reconfigure.transaction_invalid "$S5_TXNDIR"
        return 1
    }
    case "$_rrphase" in
    staging | committed)
        _s5_txn_cleanup
        ;;
    armed)
        s5_warn_msg reconfigure.pending_recovery
        if _s5_reconfigure_restore "$_rrmode"; then
            S5_PASSWORD=''; S5_SECRET=''
            return 0
        fi
        S5_PASSWORD=''; S5_SECRET=''
        return 1
        ;;
    esac
}

_s5_reconfigure_fail() {
    s5_err_msg reconfigure.apply_failed
    if ! _s5_reconfigure_restore; then
        s5_err_msg reconfigure.recovery_failed "$S5_TXNDIR"
    fi
    S5_RECONFIG_ARMED=0
    return 1
}

s5_reconfigure_apply() {
    if ! _s5_reconfigure_stage; then
        return 1
    fi
    if ! s5_stop_and_confirm; then
        _s5_reconfigure_fail
        return 1
    fi
    # Three-valued like every other listen observation. Folding status 2 into
    # "in use" reported a collision the probe had never seen -- one line after
    # the probe itself said it could not tell -- and rolled back a healthy
    # install for it.
    s5_port_free "$S5_PORT"
    _rapf=$?
    case "$_rapf" in
    0) ;;
    1)
        s5_err_msg reconfigure.port_not_free "$S5_PORT"
        _s5_reconfigure_fail
        return 1
        ;;
    *)
        s5_err_msg reconfigure.port_unverified "$S5_PORT"
        _s5_reconfigure_fail
        return 1
        ;;
    esac
    if ! _s5_copy_file_secure "$S5_TXN_NEW_USERS" "$S5_USERSCFG" "0:$S5_ACCOUNT_GID" 0640 ||
        ! _s5_copy_file_secure "$S5_TXN_NEW_CFG" "$S5_CFG" "0:$S5_ACCOUNT_GID" 0640 ||
        ! s5_state_replace_identity "$S5_PORT" "$S5_USERNAME"; then
        _s5_reconfigure_fail
        return 1
    fi
    s5_log_msg install.starting_service "$S5_PROJECT"
    if ! s5_service_start || ! s5_verify_running_config; then
        _s5_reconfigure_fail
        return 1
    fi
    if ! _s5_txn_write_phase committed; then
        _s5_reconfigure_fail
        return 1
    fi
    S5_RECONFIG_ARMED=0
    if ! _s5_txn_cleanup; then
        s5_err_msg reconfigure.commit_cleanup_failed "$S5_TXNDIR"
        return 1
    fi
    s5_log_msg reconfigure.complete
    return 0
}

# ---------------------------------------------------------------------------
# Collision detection, warnings, dependencies, rollback, uninstall
# ---------------------------------------------------------------------------

s5_collision_check() {
    if s5_is_installed; then
        return 0
    fi
    _ccbad=0
    for _ccp in "$S5_SYSCONFDIR" "$S5_STATEDIR" "$S5_PREFIX" "$S5_BIN" \
        "$S5_UNIT" "$S5_INITSCRIPT"; do
        if [ -e "$_ccp" ] || [ -L "$_ccp" ]; then
            s5_err_msg collision.path_exists "$_ccp"
            _ccbad=1
        fi
    done
    s5_account_exists
    _ccar=$?
    case "$_ccar" in
    0)
        s5_err_msg collision.user_exists "$S5_SERVICE_USER"
        _ccbad=1
        ;;
    1) ;;
    *)
        s5_err_msg install.acct_exists_unknown
        _ccbad=1
        ;;
    esac
    s5_group_exists
    _ccgr=$?
    case "$_ccgr" in
    0)
        s5_err_msg collision.group_exists "$S5_SERVICE_GROUP"
        _ccbad=1
        ;;
    1) ;;
    *)
        s5_err_msg install.grp_exists_unknown
        _ccbad=1
        ;;
    esac
    if [ "$_ccbad" -ne 0 ]; then
        s5_say_msg collision.refuse_overwrite
        _crh=$(s5_cmd_hint uninstall)
        s5_say_msg collision.remove_or_rename "$_crh"
        _crh=''
        return 1
    fi
    return 0
}

s5_confirm() {
    printf '%s [y/N]: ' "$1" >&2
    _cfa=''
    if ! read -r _cfa; then
        return 1
    fi
    case "$_cfa" in
    y | Y | yes | YES | Yes) return 0 ;;
    *) return 1 ;;
    esac
}

# Bounded default-no confirmation for reconfiguration. Return 0 for yes, 1 for
# an explicit/default no, and 2 when input ends or never becomes valid.
s5_confirm_no() {
    _cfn=0
    while [ "$_cfn" -lt 5 ]; do
        _cfn=$((_cfn + 1))
        printf '%s [y/N]: ' "${1:-}" >&2
        _cfa=''
        if ! read -r _cfa; then
            return 2
        fi
        case "$_cfa" in
        y | Y | yes | YES | Yes) return 0 ;;
        '' | n | N | no | NO | No) return 1 ;;
        *) s5_err_msg reconfigure.confirm_invalid ;;
        esac
    done
    return 2
}

# s5_confirm_yes <question>: the INSTALL confirmation only. Enter means
# continue -- the operator already chose to run the installer, and the
# destructive question below stays default-NO, so the two helpers are
# deliberately separate: the safe default can never leak into the dangerous
# question. Unsupported input re-prompts (bounded like every other prompt);
# EOF fails.
s5_confirm_yes() {
    _cfy=0
    while [ "$_cfy" -lt 5 ]; do
        _cfy=$((_cfy + 1))
        printf '%s [Y/n]: ' "${1:-}" >&2
        _cfa=''
        if ! read -r _cfa; then
            return 1
        fi
        case "$_cfa" in
        '' | y | Y | yes | YES | Yes) return 0 ;;
        n | N | no | NO | No) return 1 ;;
        *) ;;
        esac
    done
    return 1
}

s5_required_packages() {
    s5_runtime_deps
}

s5_preinstall_warning() {
    _spwpkgs=$(s5_required_packages) || return 1
    s5_say ""
    s5_say_msg install.warning_header
    s5_say_msg install.warning_listens "$S5_LISTEN"
    s5_say_msg install.warning_detected "$S5_OS_ID" "$S5_OS_VERSION_ID" "$S5_PKGMGR" "$S5_INIT"
    s5_say_msg install.warning_packages "$_spwpkgs"
    s5_say_msg install.warning_packages_kept
    s5_say ""
    s5_say_msg install.warning_cleartext
    s5_say_msg install.warning_cleartext2
    s5_say_msg install.warning_cleartext3
    s5_say_msg install.warning_firewall
    s5_say_msg install.warning_firewall2
    s5_say_msg install.warning_anyone
    s5_say_msg install.warning_anyone2
    s5_say ""
    s5_say_msg install.warning_protocols
    s5_say_msg install.warning_protocols2
    s5_say "==========================================================================="
    s5_say ""
    return 0
}

s5_install_dependencies() {
    _idall=$(s5_required_packages) || return 1
    if [ -z "$_idall" ]; then
        return 0
    fi
    case "$S5_PKGMGR" in
    apt)
        DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null 2>&1 || {
            s5_err_msg install.pkg_meta_failed
            return 1
        }
        # shellcheck disable=SC2086
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $_idall; then
            s5_err_msg install.pkg_install_failed
            return 1
        fi
        ;;
    apk)
        # shellcheck disable=SC2086
        if ! apk add --no-cache $_idall; then
            s5_err_msg install.pkg_install_failed
            return 1
        fi
        ;;
    dnf)
        if command -v dnf >/dev/null 2>&1; then
            # shellcheck disable=SC2086
            if ! dnf install -y --setopt=install_weak_deps=False $_idall; then
                s5_err_msg install.pkg_install_failed
                return 1
            fi
        else
            # shellcheck disable=SC2086
            if ! yum install -y --setopt=install_weak_deps=False $_idall; then
                s5_err_msg install.pkg_install_failed
                return 1
            fi
        fi
        ;;
    *)
        s5_err_msg install.pkg_unknown "$S5_PKGMGR"
        return 1
        ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# Teardown helpers.
#
# Every path is a constant from the top of this script. The state file only
# says WHETHER we created a resource, never WHERE it is.
# ---------------------------------------------------------------------------

# s5_runtime_claim_id <fixed-path> : print the current-install inode claim when
# one exists. Old installs and a later process have no runtime claim and retain
# the validated legacy fixed-path behavior.
s5_runtime_claim_id() {
    case "$1" in
    "$S5_PREFIX") printf '%s' "$S5_CLAIM_PREFIX_ID" ;;
    "$S5_BIN") printf '%s' "$S5_CLAIM_BIN_ID" ;;
    "$S5_SYSCONFDIR") printf '%s' "$S5_CLAIM_CONFDIR_ID" ;;
    "$S5_USERSCFG") printf '%s' "$S5_CLAIM_USERS_ID" ;;
    "$S5_CFG") printf '%s' "$S5_CLAIM_CFG_ID" ;;
    "$S5_UNIT") printf '%s' "$S5_CLAIM_UNIT_ID" ;;
    "$S5_INITSCRIPT") printf '%s' "$S5_CLAIM_INITSCRIPT_ID" ;;
    "$S5_STATE") printf '%s' "$S5_STATE_FILE_CLAIM_ID" ;;
    "$S5_STATEDIR") printf '%s' "$S5_STATE_DIR_CLAIM_ID" ;;
    esac
}

s5_runtime_claim_matches() {
    _rcmid=$(s5_runtime_claim_id "$1")
    if [ -z "$_rcmid" ]; then
        return 0
    fi
    [ "$(stat -c '%d:%i' "$1" 2>/dev/null)" = "$_rcmid" ]
}

# s5_rm_known_file <flag-key> <path> : remove one fixed project file.
s5_rm_known_file() {
    if ! s5_state_flagged "$1"; then
        return 0
    fi
    if [ ! -e "$2" ] && [ ! -L "$2" ]; then
        return 0
    fi
    if ! s5_runtime_claim_matches "$2"; then
        s5_err_msg rollback.keep_foreign_files "$2"
        return 1
    fi
    if ! rm -f "$2"; then
        s5_err_msg rollback.rm_file_failed "$2"
        return 1
    fi
    return 0
}

# s5_dir_extras <dir> <known...> : list entries that are not in the known set.
s5_dir_extras() {
    _dedir=$1
    shift
    if [ ! -d "$_dedir" ]; then
        return 0
    fi
    for _dee in "$_dedir"/* "$_dedir"/.[!.]* "$_dedir"/..?*; do
        if [ ! -e "$_dee" ] && [ ! -L "$_dee" ]; then
            continue
        fi
        _debase=${_dee##*/}
        _deknown=0
        for _dek in "$@"; do
            if [ "$_debase" = "$_dek" ]; then
                _deknown=1
            fi
        done
        if [ "$_deknown" -eq 0 ]; then
            printf '%s\n' "$_debase"
        fi
    done
}

# s5_rmdir_known <flag-key> <dir> <known-basenames...>
# Never recursive. Keeps the directory and reports an error when it still
# contains anything this script did not create.
s5_rmdir_known() {
    _rkflag=$1
    _rkdir=$2
    shift 2
    if ! s5_state_flagged "$_rkflag"; then
        return 0
    fi
    if [ ! -d "$_rkdir" ] && [ ! -L "$_rkdir" ]; then
        return 0
    fi
    if [ -L "$_rkdir" ]; then
        s5_err_msg rollback.keep_symlink "$_rkdir"
        return 1
    fi
    if ! s5_runtime_claim_matches "$_rkdir"; then
        s5_err_msg rollback.keep_foreign_files "$_rkdir"
        return 1
    fi
    _rkextra=$(s5_dir_extras "$_rkdir" "$@")
    if [ -n "$_rkextra" ]; then
        s5_err_msg rollback.keep_foreign_files "$_rkdir"
        printf '%s\n' "$_rkextra" | while IFS= read -r _rkl; do
            if [ -n "$_rkl" ]; then s5_err "    $_rkl"; fi
        done
        return 1
    fi
    if ! rmdir "$_rkdir"; then
        s5_err_msg rollback.rm_dir_failed "$_rkdir"
        return 1
    fi
    return 0
}

# s5_teardown : shared by rollback and uninstall. Returns non-zero when
# anything could not be removed.
s5_teardown() {
    _tdbad=0
    # Rollback calls teardown immediately after loading state, while uninstall
    # populates these globals itself. Derive them here too so a flagged service
    # is stopped using the recorded init system rather than an empty inherited
    # variable.
    _tdinit=$(s5_state_get init)
    _tdfamily=$(s5_state_get family)
    if [ -n "$_tdinit" ]; then S5_INIT=$_tdinit; fi
    if [ -n "$_tdfamily" ]; then S5_OS_FAMILY=$_tdfamily; fi

    _tdhasunit=0
    if s5_state_flagged created_unit || s5_state_flagged created_initscript; then
        _tdhasunit=1
    fi
    # The ownership flag is recorded BEFORE the unit file is written, so a
    # failed write leaves the flag with no file. Managers refuse stop and
    # disable for a unit they never loaded (observed: systemd exits 1 for
    # both), and those refusals used to abort teardown before a single
    # resource was removed -- retrying uninstall then repeated the same
    # unsatisfiable stop forever. With the unit/init script file absent the
    # failed stop and disable are no-ops; the is-active check below stays the
    # authority on whether anything is actually still running.
    _tdunitfile=$S5_UNIT
    if [ "$_tdinit" = "openrc" ]; then
        _tdunitfile=$S5_INITSCRIPT
    fi
    _tdfilepresent=0
    if [ -e "$_tdunitfile" ] || [ -L "$_tdunitfile" ]; then
        _tdfilepresent=1
    fi
    if [ "$_tdfilepresent" -eq 1 ] && ! s5_runtime_claim_matches "$_tdunitfile"; then
        s5_err_msg rollback.keep_foreign_files "$_tdunitfile"
        return 1
    fi
    if [ "$_tdhasunit" -eq 1 ]; then
        if [ "$_tdfilepresent" -eq 1 ]; then
            if ! s5_service_stop >/dev/null 2>&1; then
                s5_err_msg rollback.stop_failed
                _tdbad=1
            fi
        else
            # Never written: the manager cannot know this unit, so a refused
            # stop is expected, not fatal. The stop is still attempted in
            # case the manager holds a definition from before the file
            # disappeared; the is-active check below stays the authority on
            # whether anything is actually still running.
            s5_service_stop >/dev/null 2>&1 || true
        fi
        s5_service_active >/dev/null 2>&1
        _tdactive=$?
        case "$_tdactive" in
        0)
            s5_err_msg rollback.still_active
            _tdbad=1
            ;;
        1) ;;
        *)
            s5_err_msg rollback.stop_unverified
            _tdbad=1
            ;;
        esac
        if [ "$_tdfilepresent" -eq 1 ]; then
            if ! s5_service_disable; then
                _tdbad=1
            fi
        else
            s5_service_disable >/dev/null 2>&1 || true
        fi
        if [ "$_tdbad" -ne 0 ]; then
            return "$_tdbad"
        fi
    fi

    s5_rm_known_file created_cfg "$S5_CFG" || _tdbad=1
    s5_rm_known_file created_users "$S5_USERSCFG" || _tdbad=1
    s5_rm_known_file created_unit "$S5_UNIT" || _tdbad=1
    s5_rm_known_file created_initscript "$S5_INITSCRIPT" || _tdbad=1
    s5_rm_known_file created_bin "$S5_BIN" || _tdbad=1

    s5_rmdir_known created_prefix "$S5_PREFIX" 3proxy || _tdbad=1
    s5_rmdir_known created_confdir "$S5_SYSCONFDIR" 3proxy.cfg users.cfg || _tdbad=1

    if s5_state_flagged created_account; then
        _tdgrp=0
        if s5_state_flagged created_group; then
            _tdgrp=1
        fi
        if s5_account_remove "$_tdgrp" \
            "$(s5_state_get account_uid)" "$(s5_state_get account_gid)"; then
            s5_log_msg rollback.removed_account "$S5_SERVICE_USER"
        else
            _tdbad=1
        fi
    fi

    if [ "$S5_INIT" = "systemd" ]; then
        if ! systemctl daemon-reload >/dev/null 2>&1; then
            s5_err_msg rollback.reload_after_remove
            _tdbad=1
        fi
    fi

    return "$_tdbad"
}

s5_rollback() {
    s5_warn_msg rollback.starting
    if ! s5_state_load; then
        if [ -n "$S5_STATE_DIR_CLAIM_ID" ]; then
            _s5_state_begin_undo
        fi
        s5_warn_msg rollback.no_state
        return 1
    fi
    if ! s5_teardown; then
        s5_err_msg rollback.incomplete "$S5_STATE"
        s5_err_msg rollback.retry_uninstall "$(s5_cmd_hint uninstall)"
        return 1
    fi
    _rbstbuf=$S5_STATE_BUF
    _rbextra=$(s5_dir_extras "$S5_STATEDIR" state)
    if [ -n "$_rbextra" ]; then
        s5_err_msg rollback.state_dir_foreign "$S5_STATEDIR"
        printf '%s\n' "$_rbextra" | while IFS= read -r _rbl; do
            [ -n "$_rbl" ] && s5_err "    $_rbl"
        done
        return 1
    fi
    if [ -n "$S5_STATE_FILE_CLAIM_ID" ] &&
        ! s5_runtime_claim_matches "$S5_STATE"; then
        s5_err_msg rollback.keep_foreign_files "$S5_STATE"
        return 1
    fi
    if ! rm -f "$S5_STATE"; then
        s5_err_msg rollback.rm_state_failed "$S5_STATE"
        return 1
    fi
    if [ -n "$S5_STATE_DIR_CLAIM_ID" ] &&
        ! s5_runtime_claim_matches "$S5_STATEDIR"; then
        s5_err_msg rollback.keep_foreign_files "$S5_STATEDIR"
        return 1
    fi
    if rmdir "$S5_STATEDIR" 2>/dev/null; then
        s5_log_msg rollback.complete
        return 0
    fi
    # Keep retry state if the final directory removal was ambiguous or failed.
    S5_STATE_BUF=$_rbstbuf
    if ! s5_state_flush; then
        s5_err_msg rollback.restore_failed "$S5_STATE"
        return 1
    fi
    s5_err_msg rollback.rm_dir_retained "$S5_STATE"
    return 1
}

# ---------------------------------------------------------------------------
# IPv4 address resolution for the credential card (Round 16 T11).
#
# Two pure predicates, one hardened external lookup, one explicit fallback.
# The external result is an OBSERVED EGRESS address: it proves nothing about
# inbound NAT, port forwarding, firewalls or security groups. All failures are
# nonfatal -- the card renders with an explicit SERVER_IPV4 placeholder and an
# actionable warning; installation and show never fail here.
#
# The longest legal body is a 15-byte address plus CRLF, so curl and a second
# on-disk size check both enforce a 17-byte response limit before parsing.
# ---------------------------------------------------------------------------

s5_ipv4_is_canonical() {
    # Exactly four fields of 0-255, no leading zeros (except bare 0), nothing
    # else. Pure: strips nothing -- the external-body handler owns terminator
    # stripping.
    case "$1" in
    '' | *[!0-9.]*) return 1 ;;
    esac
    case "$1" in
    .* | *. | *..*) return 1 ;;
    esac
    # Split on dots with IFS instead of eval indirection: the no-eval rule is
    # one of the catalog's own invariants and this parser must honor it too.
    _ivcoldIFS=${IFS}
    IFS=.
    set -f
    # shellcheck disable=SC2086  # the unquoted expansion IS the dot-split
    set -- $1
    set +f
    IFS=${_ivcoldIFS}
    [ "$#" -eq 4 ] || { _ivcoldIFS=''; return 1; }
    for _ivcv in "$1" "$2" "$3" "$4"; do
        case "$_ivcv" in
        '' | *[!0-9]*) return 1 ;;
        esac
        [ "${#_ivcv}" -gt 3 ] && return 1
        case "$_ivcv" in
        0) ;;
        0*) return 1 ;;
        esac
        [ "$_ivcv" -gt 255 ] && return 1
    done
    _ivcoldIFS=''
    return 0
}

s5_ipv4_is_public() {
    # Conservative: rejects every IANA special-purpose range. RFC1918 and
    # CGNAT are rejected here but accepted by the usable-local classifier.
    s5_ipv4_is_canonical "$1" || return 1
    _ipo1=${1%%.*}
    _ipore=${1#*.}
    _ipo2=${_ipore%%.*}
    _ipore=${_ipore#*.}
    _ipo3=${_ipore%%.*}
    [ "$_ipo1" -eq 0 ] && return 1
    [ "$_ipo1" -eq 10 ] && return 1
    if [ "$_ipo1" -eq 100 ]; then
        [ "$_ipo2" -ge 64 ] && [ "$_ipo2" -le 127 ] && return 1
    fi
    [ "$_ipo1" -eq 127 ] && return 1
    if [ "$_ipo1" -eq 169 ]; then
        [ "$_ipo2" -eq 254 ] && return 1
    fi
    if [ "$_ipo1" -eq 172 ]; then
        [ "$_ipo2" -ge 16 ] && [ "$_ipo2" -le 31 ] && return 1
    fi
    if [ "$_ipo1" -eq 192 ]; then
        [ "$_ipo2" -eq 0 ] && [ "$_ipo3" -eq 0 ] && return 1
        [ "$_ipo2" -eq 0 ] && [ "$_ipo3" -eq 2 ] && return 1
        [ "$_ipo2" -eq 31 ] && [ "$_ipo3" -eq 196 ] && return 1
        [ "$_ipo2" -eq 52 ] && [ "$_ipo3" -eq 193 ] && return 1
        [ "$_ipo2" -eq 88 ] && [ "$_ipo3" -eq 99 ] && return 1
        [ "$_ipo2" -eq 168 ] && return 1
        [ "$_ipo2" -eq 175 ] && [ "$_ipo3" -eq 48 ] && return 1
    fi
    if [ "$_ipo1" -eq 198 ]; then
        [ "$_ipo2" -eq 18 ] && return 1
        [ "$_ipo2" -eq 19 ] && return 1
        [ "$_ipo2" -eq 51 ] && [ "$_ipo3" -eq 100 ] && return 1
    fi
    if [ "$_ipo1" -eq 203 ]; then
        [ "$_ipo2" -eq 0 ] && [ "$_ipo3" -eq 113 ] && return 1
    fi
    [ "$_ipo1" -ge 224 ] && return 1
    return 0
}

s5_lookup_public_ipv4() {
    # One hardened request to the fixed endpoint. -q first so no user or
    # system curlrc can alter it; --noproxy '*' so an ambient proxy variable
    # cannot redirect or observe the request; IPv4 only; HTTPS only; no
    # redirects; bounded; stdin detached. On any failure prints nothing and
    # returns nonzero. The response is captured to a 0600 file, never through
    # a pipe or command substitution: a pipe's status is the LAST command's
    # (so curl's failure was masked) and substitution strips trailing
    # newlines (so multi-line and double-terminator bodies collapsed into
    # valid-looking addresses). The file preserves exact bytes; length and
    # terminator structure are validated BEFORE any parsing.
    if ! command -v curl >/dev/null 2>&1; then
        return 1
    fi
    _lpf=$(mktemp "${TMPDIR:-/tmp}/s5ip.XXXXXX") || return 1
    if ! curl -q -4 --noproxy '*' --proto '=https' --fail --silent \
        --connect-timeout 3 --max-time 5 --max-filesize 17 \
        --output "$_lpf" "https://icanhazip.com" </dev/null 2>/dev/null; then
        rm -f "$_lpf"
        _lpf=''
        return 1
    fi
    _lpsz=$(wc -c <"$_lpf" 2>/dev/null | tr -d '[:space:]')
    case "$_lpsz" in
    '' | *[!0-9]*) _lpsz=18 ;;
    esac
    if [ "$_lpsz" -gt 17 ]; then
        rm -f "$_lpf"
        _lpf=''; _lpsz=''
        return 1
    fi
    _lpsz=''
    # Validate the file's line structure with read, not pattern matching: a
    # trailing-newline byte cannot be built in a shell variable (command
    # substitution strips it, so every \n-bearing pattern was silently an
    # empty string), and one read plus one EOF-proving second read rejects a
    # second line, a double terminator and trailing garbage in one stroke.
    # Both reads share one descriptor: reopening the path would restart at
    # byte 0 and make every file look like it had a second identical line.
    # read's exit status cannot distinguish EOF from EOF-after-a-partial-line
    # (both nonzero), so content presence is decided by the variable; an
    # unterminated final line is still one line.
    exec 3<"$_lpf"
    _lpb=''
    IFS= read -r _lpb <&3
    if [ -z "$_lpb" ]; then
        exec 3<&-
        rm -f "$_lpf"
        _lpb=''
        _lpf=''
        return 1
    fi
    # A second read returning success means another line exists even when it
    # is empty (a double terminator reads as an empty line with rc 0); a
    # nonzero return with an empty variable is the only clean EOF.
    _lpx=''
    if IFS= read -r _lpx <&3 || [ -n "$_lpx" ]; then
        exec 3<&-
        rm -f "$_lpf"
        _lpb=''
        _lpx=''
        _lpf=''
        return 1
    fi
    exec 3<&-
    _lpx=''
    rm -f "$_lpf"
    _lpf=''
    # read consumes the LF but leaves a CR from a CRLF terminator on the line.
    _lpcr=$(printf 'x\r')
    _lpcr=${_lpcr#x}
    _lpb=${_lpb%"$_lpcr"}
    _lpcr=''
    if [ -z "$_lpb" ]; then
        return 1
    fi
    if ! s5_ipv4_is_public "$_lpb"; then
        _lpb=''
        return 1
    fi
    printf '%s' "$_lpb"
    _lpb=''
    return 0
}

s5_resolve_card_address() {
    # Resolves once per card. A strictly validated public IPv4 is used when the
    # fixed endpoint answers; otherwise the card uses an explicit placeholder
    # rather than presenting a private address as an Internet-reachable host.
    S5_CARD_ADDR=''
    S5_CARD_KIND=''
    if _rca=$(s5_lookup_public_ipv4); then
        S5_CARD_ADDR=$_rca
        S5_CARD_KIND=external
        _rca=''
        return 0
    fi
    _rca=''
    S5_CARD_ADDR=SERVER_IPV4
    S5_CARD_KIND=placeholder
    return 0
}


# Secret-bearing operator output is permitted only when stdout is the terminal
# being used by the operator. In particular, a pipe or redirected file must
# never receive a plaintext password.
s5_require_secret_terminal() {
    if [ ! -t 1 ]; then
        s5_err_msg card.refusing_display
        return 1
    fi
    return 0
}

# Printed to the terminal only. s5_say bypasses the log sink deliberately:
# the credential must reach the operator's screen and nothing else.
# The card body, callable directly by tests: renders the resolved address,
# fields and warnings. The terminal-only guard lives in s5_print_summary.
s5_render_card() {
    # One resolution per card: the Host field and the URI must agree, and the
    # lookup happens only when a card is actually rendered.
    s5_resolve_card_address
    s5_say ""
    s5_say_msg card.ready_header
    _cvs=$(s5_msg card.label_server); s5_say "$_cvs$S5_CARD_ADDR"
    _cvp=$(s5_msg card.label_port); s5_say "$_cvp$S5_PORT"
    _cvu=$(s5_msg card.label_username); s5_say "$_cvu$S5_USERNAME"
    _cvw=$(s5_msg card.label_password); s5_say "$_cvw$S5_PASSWORD"
    s5_say ""
    s5_say "socks5://$S5_USERNAME:$S5_PASSWORD@$S5_CARD_ADDR:$S5_PORT"
    s5_say ""
    _cvf=$(s5_msg card.label_firewall); _cvfw=$(s5_msg card.firewall_untouched); s5_say "$_cvf$_cvfw"
    _cvc=$(s5_msg card.cloud_provider "$S5_PORT"); s5_say "$_cvc"
    s5_say ""
    case "$S5_CARD_KIND" in
    placeholder) s5_say_msg card.warn_placeholder ;;
    esac
    s5_say_msg card.warning_encrypted
    s5_say_msg card.warning_vpn
    s5_say_msg card.warning_vpn2
    s5_say ""
    s5_redisplay_hint
    s5_say_msg card.rule_end
    s5_say ""
}

s5_print_summary() {
    if ! s5_require_secret_terminal; then
        if [ "${1:-install}" = reconfigure ]; then
            s5_say_msg reconfigure.completed_no_display
        else
            s5_say_msg card.completed_no_display
        fi
        return 0
    fi
    s5_render_card
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

# Fresh resources are exclusively claimed at their final paths before their
# ownership flags are persisted. Until that handoff succeeds, runtime inode or
# UID/GID claims provide local compensation; rollback handles only durable flags.
s5_install_steps() {
    # The collision check ran before the confirmation, the package
    # installation and the three value prompts -- a long window. Identities
    # that appear inside it are NOT ours to adopt: accepting them handed the
    # plaintext credentials to whatever group happened to take the name, and
    # recorded no ownership flags either. Appearing after the collision check
    # is a race, and the answer to a race is refusal.
    s5_account_exists
    _isacct=$?
    case "$_isacct" in
    0)
        s5_err_msg install.user_appeared "$S5_SERVICE_USER"
        return 1
        ;;
    1) ;;
    *)
        s5_err_msg install.acct_exists_unknown
        return 1
        ;;
    esac
    s5_group_exists
    _isgrp=$?
    case "$_isgrp" in
    0)
        s5_err_msg install.group_appeared "$S5_SERVICE_GROUP"
        return 1
        ;;
    1) ;;
    *)
        s5_err_msg install.grp_exists_unknown
        return 1
        ;;
    esac

    if ! s5_account_create; then
        s5_pending_account_remove >/dev/null 2>&1 || true
        return 1
    fi
    if ! s5_state_claim_account; then
        s5_pending_account_remove >/dev/null 2>&1 || true
        return 1
    fi

    if ! s5_fetch_verified_engine managed; then
        return 1
    fi

    if [ -z "$S5_ACCOUNT_GID" ] ||
        ! s5_identity_matches "$S5_ACCOUNT_UID" "$S5_ACCOUNT_GID"; then
        s5_err_msg reconfigure.state_invalid
        return 1
    fi
    if ! s5_claim_dir "$S5_SYSCONFDIR" "0:$S5_ACCOUNT_GID" 0750; then
        return 1
    fi
    if ! s5_state_mark_claim created_confdir; then return 1; fi

    _isu=$(s5_render_users) || return 1
    if ! s5_publish_new_text "$S5_USERSCFG" "0:$S5_ACCOUNT_GID" 0640 "$_isu"; then
        _isu=''
        return 1
    fi
    if ! s5_state_mark_claim created_users; then
        _isu=''
        return 1
    fi
    _isu=''

    _isc=$(s5_render_cfg) || return 1
    if ! s5_publish_new_text "$S5_CFG" "0:$S5_ACCOUNT_GID" 0640 "$_isc"; then
        return 1
    fi
    if ! s5_state_mark_claim created_cfg; then return 1; fi

    # Static check happens BEFORE anything is started.
    if ! s5_static_check_cfg "$S5_CFG"; then
        return 1
    fi

    if ! s5_service_install; then
        return 1
    fi

    s5_log_msg install.starting_service "$S5_PROJECT"
    if ! s5_service_start; then
        s5_err_msg install.start_failed
        return 1
    fi
    if ! s5_verify_running_config; then
        return 1
    fi

    return 0
}

s5_cmd_reconfigure_locked() {
    if ! _s5_reconfigure_precheck; then
        return "$EX_FAIL"
    fi
    _rc_old_port=$S5_PORT
    S5_SECRET=$S5_PASSWORD
    if ! s5_cmd_status; then
        S5_PASSWORD=''; S5_SECRET=''
        return "$EX_FAIL"
    fi
    s5_say_msg reconfigure.summary
    s5_say_msg reconfigure.reuses_install
    s5_say_msg reconfigure.no_firewall
    _rcq=$(s5_msg reconfigure.confirm)
    s5_confirm_no "$_rcq"
    _rcc=$?
    _rcq=''
    case "$_rcc" in
    0) ;;
    1)
        s5_log_msg reconfigure.cancelled
        S5_PASSWORD=''; S5_SECRET=''
        return "$EX_OK"
        ;;
    *)
        s5_err_msg reconfigure.confirm_failed
        S5_PASSWORD=''; S5_SECRET=''
        return "$EX_FAIL"
        ;;
    esac
    if ! s5_prompt_port "$_rc_old_port" ||
        ! s5_prompt_username ||
        ! s5_prompt_password; then
        S5_PASSWORD=''; S5_SECRET=''
        return "$EX_FAIL"
    fi
    if ! s5_reconfigure_apply; then
        S5_PASSWORD=''; S5_SECRET=''
        return "$EX_FAIL"
    fi
    s5_print_summary reconfigure
    S5_PASSWORD=''; S5_SECRET=''
    return "$EX_OK"
}

_s5_cmd_install_locked() {
    if s5_is_installed; then
        s5_cmd_reconfigure_locked
        return $?
    fi
    if ! s5_collision_check; then
        return "$EX_FAIL"
    fi

    s5_preinstall_warning
    _ici=$(s5_msg install.confirm)
    if ! s5_confirm_yes "$_ici"; then
        s5_log_msg install.aborted
        return "$EX_FAIL"
    fi

    # Install prerequisites before asking for a port. Port selection must be
    # observable on a clean host, and no secret is collected before packages
    # have been installed and accepted.
    if ! s5_install_dependencies; then return "$EX_FAIL"; fi
    if ! s5_no_replace_supported; then
        s5_err_msg detect.no_replace_primitive
        return "$EX_FAIL"
    fi
    if ! s5_prompt_port; then return "$EX_FAIL"; fi
    if ! s5_prompt_username; then return "$EX_FAIL"; fi
    if ! s5_prompt_password; then return "$EX_FAIL"; fi

    S5_ROLLBACK_ARMED=1
    if ! s5_state_begin; then
        S5_ROLLBACK_ARMED=0
        return "$EX_FAIL"
    fi

    if ! s5_state_add port "$S5_PORT"; then return "$EX_FAIL"; fi
    if ! s5_state_add username "$S5_USERNAME"; then return "$EX_FAIL"; fi
    if ! s5_state_add os "$S5_OS_ID-$S5_OS_VERSION_ID"; then return "$EX_FAIL"; fi
    if ! s5_state_add family "$S5_OS_FAMILY"; then return "$EX_FAIL"; fi
    if ! s5_state_add arch "$S5_ARCHNAME"; then return "$EX_FAIL"; fi
    if ! s5_state_add init "$S5_INIT"; then return "$EX_FAIL"; fi
    if ! s5_state_add listen "$S5_LISTEN"; then return "$EX_FAIL"; fi

    if ! s5_install_steps; then
        s5_rollback || true
        S5_ROLLBACK_ARMED=0
        return "$EX_FAIL"
    fi

    if ! s5_state_add status complete; then
        s5_rollback || true
        S5_ROLLBACK_ARMED=0
        return "$EX_FAIL"
    fi
    S5_ROLLBACK_ARMED=0
    S5_INSTALL_COMPLETE=1
    s5_print_summary
    return "$EX_OK"
}

s5_cmd_install() {
    # Every gate first: base commands, OS, arch, root, package manager.
    s5_precheck
    _cipc=$?
    if [ "$_cipc" -ne 0 ]; then
        return "$_cipc"
    fi
    s5_with_mutation_lock _s5_cmd_install_locked
}

# s5_load_credentials : read the single "user:CL:password" line back from disk
# and re-validate it, so a hand-edited or corrupted users.cfg is rejected
# instead of being echoed into a malformed URI.
s5_load_credentials() {
    if [ ! -f "$S5_USERSCFG" ] || [ -L "$S5_USERSCFG" ]; then
        return 1
    fi
    if [ "$(grep -c '' "$S5_USERSCFG")" -ne 1 ]; then
        s5_err_msg show.credential_line_count "$S5_USERSCFG"
        return 1
    fi
    _lcline=$(head -n 1 "$S5_USERSCFG")
    case "$_lcline" in
    *:CL:*) ;;
    *)
        s5_err_msg show.credential_format "$S5_USERSCFG"
        return 1
        ;;
    esac
    _lcu=${_lcline%%:CL:*}
    _lcp=${_lcline#*:CL:}
    if ! s5_valid_username "$_lcu"; then
        s5_err_msg show.username_invalid "$S5_USERSCFG"
        return 1
    fi
    if ! s5_valid_password "$_lcp"; then
        s5_err_msg show.password_invalid "$S5_USERSCFG"
        return 1
    fi
    S5_USERNAME=$_lcu
    S5_PASSWORD=$_lcp
    _lcline=''; _lcu=''; _lcp=''
    return 0
}

# ---------------------------------------------------------------------------
# Usage and dispatch
# ---------------------------------------------------------------------------

s5_usage() {
    _uu=$(s5_msg usage.line_usage "${S5_SELF:-socks5.sh}")
    printf '%s\n\n' "$_uu"
    s5_say_msg usage.line_commands
    s5_say_msg usage.cmd_install
    s5_say_msg usage.cmd_status
    s5_say_msg usage.cmd_show
    s5_say_msg usage.cmd_restart
    s5_say_msg usage.cmd_uninstall
    s5_say ""
    s5_say_msg usage.line_no_command
    s5_say ""
    s5_say_msg usage.line_protocol
    s5_say_msg usage.line_protocol2
    s5_say_msg usage.line_protocol3
    _uu=''
}

_s5_cmd_status_locked() {
    if [ -e "$S5_TXNDIR" ] || [ -L "$S5_TXNDIR" ]; then
        s5_err_msg reconfigure.read_blocked
        return "$EX_FAIL"
    fi
    if ! s5_is_installed; then
        _ni=$(s5_msg cmd.not_installed "$S5_PROJECT")
        s5_say "$_ni"
        _ni=''
        return "$EX_FAIL"
    fi
    S5_INIT=$(s5_state_get init)
    S5_OS_FAMILY=$(s5_state_get family)
    S5_LISTEN=$(s5_state_get listen)
    _stport=$(s5_state_get port)
    S5_PORT=$_stport
    s5_service_active
    _stsr=$?
    case "$_stsr" in
    0) _stsvc=$(s5_msg status.service_running) ;;
    1) _stsvc=$(s5_msg status.service_not_running) ;;
    *) _stsvc=$(s5_msg status.service_unverified) ;;
    esac
    s5_port_listening
    _stlp=$?
    if [ "$_stlp" -eq 0 ]; then
        _stlisten=$(s5_msg status.listening "$(s5_state_get listen)" "$_stport")
    elif [ "$_stlp" -eq 1 ]; then
        _stlisten=$(s5_msg status.not_listening "$_stport")
    else
        # Being unable to look is not evidence either way, so claim neither.
        _stlisten=$(s5_msg status.listen_unverified "$_stport")
    fi
    s5_say_msg status.heading "$S5_PROJECT"
    _sts=$(s5_msg status.label_service); s5_say "$_sts$_stsvc ($S5_INIT)"
    _stp=$(s5_msg status.label_port); s5_say "$_stp$_stlisten"
    _stu=$(s5_msg status.label_username); s5_say "$_stu$(s5_state_get username)"
    _ste=$(s5_msg status.label_engine)
    _sev=$(s5_msg status.engine_value "$(s5_state_get tag)" "$(s5_state_get commit)")
    s5_say "$_ste$_sev"
    _sto=$(s5_msg status.label_origin); _storigin=$(s5_state_get origin); s5_say "$_sto$_storigin"
    if [ "$_storigin" = release-asset ]; then
        _sta=$(s5_msg status.label_asset); s5_say "$_sta$(s5_state_get asset)"
        _sth=$(s5_msg status.label_sha256); s5_say "$_sth$(s5_state_get sha256)"
    fi
    _stb=$(s5_msg status.label_binary); s5_say "$_stb$S5_BIN"
    _stf=$(s5_msg status.label_firewall); _stfw=$(s5_msg card.firewall_untouched); s5_say "$_stf$_stfw"
    return "$EX_OK"
}

s5_cmd_status() {
    s5_with_read_lock _s5_cmd_status_locked
}

_s5_cmd_show_locked() {
    if [ -e "$S5_TXNDIR" ] || [ -L "$S5_TXNDIR" ]; then
        s5_err_msg reconfigure.read_blocked
        return "$EX_FAIL"
    fi
    if ! s5_is_installed; then
        _ni=$(s5_msg cmd.not_installed "$S5_PROJECT")
        s5_say "$_ni"
        _ni=''
        return "$EX_FAIL"
    fi
    if ! s5_is_root; then
        s5_err_msg show.requires_root
        return "$EX_FAIL"
    fi
    if ! s5_require_secret_terminal; then
        return "$EX_FAIL"
    fi
    if ! s5_load_credentials; then
        s5_err_msg show.cred_unreadable "$S5_USERSCFG"
        return "$EX_FAIL"
    fi
    S5_PORT=$(s5_state_get port)
    # The card is the shared renderer's: show and install must never drift,
    # so show renders the SAME body. The only show-specific line (the cloud
    # reminder) is the renderer's remember line, which already carries the
    # port in both languages.
    s5_render_card
    return "$EX_OK"
}

s5_cmd_show() {
    s5_with_read_lock _s5_cmd_show_locked
}

_s5_cmd_restart_locked() {
    if ! s5_is_installed; then
        _ni=$(s5_msg cmd.not_installed "$S5_PROJECT")
        s5_say "$_ni"
        _ni=''
        return "$EX_FAIL"
    fi
    if ! s5_is_root; then
        s5_err_msg restart.requires_root
        return "$EX_FAIL"
    fi
    S5_INIT=$(s5_state_get init)
    S5_PORT=$(s5_state_get port)
    if ! s5_service_restart; then
        s5_err_msg restart.failed
        return "$EX_FAIL"
    fi
    s5_service_active
    _rstar=$?
    case "$_rstar" in
    0) ;;
    1) s5_err_msg restart.not_active; return "$EX_FAIL" ;;
    *) s5_err_msg restart.active_unverified; return "$EX_FAIL" ;;
    esac
    # The manager's "active" precedes the socket (Type=simple; OpenRC under
    # supervise-daemon), so success is reported only once the port is
    # listening again. Without the wait, restart claimed success while
    # nothing was accepting connections.
    if ! s5_wait_listening "$S5_PORT"; then
        return "$EX_FAIL"
    fi
    s5_log_msg cmd.restarted "$S5_PROJECT"
    return "$EX_OK"
}

s5_cmd_restart() {
    if ! s5_is_root; then
        s5_err_msg restart.requires_root
        return "$EX_FAIL"
    fi
    s5_with_mutation_lock _s5_cmd_restart_locked
}

# Removes only the fixed project resources whose creation this run recorded.
# No system package is ever removed. Nothing is deleted recursively.
_s5_cmd_uninstall_locked() {
    if [ ! -e "$S5_STATE" ] && [ ! -L "$S5_STATE" ]; then
        _un=$(s5_msg cmd.uninstall.nothing "$S5_PROJECT")
        s5_say "$_un"
        _un=''
        return "$EX_OK"
    fi
    if ! s5_is_root; then
        s5_err_msg uninstall.requires_root
        return "$EX_FAIL"
    fi
    if ! s5_state_load; then
        s5_err_msg uninstall.state_invalid
        s5_err_msg uninstall.state_invalid_hint "$S5_STATE"
        return "$EX_FAIL"
    fi

    S5_INIT=$(s5_state_get init)
    S5_OS_FAMILY=$(s5_state_get family)

    s5_say_msg uninstall.removing_only
    if s5_state_flagged created_cfg; then _ulf=$(s5_msg uninstall.label_file "$S5_CFG"); s5_say "$_ulf"; fi
    if s5_state_flagged created_users; then _ulf=$(s5_msg uninstall.label_file "$S5_USERSCFG"); s5_say "$_ulf"; fi
    if s5_state_flagged created_unit; then _ulf=$(s5_msg uninstall.label_file "$S5_UNIT"); s5_say "$_ulf"; fi
    if s5_state_flagged created_initscript; then _ulf=$(s5_msg uninstall.label_file "$S5_INITSCRIPT"); s5_say "$_ulf"; fi
    if s5_state_flagged created_bin; then _ulf=$(s5_msg uninstall.label_file "$S5_BIN"); s5_say "$_ulf"; fi
    if s5_state_flagged created_confdir; then _uld=$(s5_msg uninstall.label_directory "$S5_SYSCONFDIR"); s5_say "$_uld"; fi
    if s5_state_flagged created_prefix; then _uld=$(s5_msg uninstall.label_directory "$S5_PREFIX"); s5_say "$_uld"; fi
    if s5_state_flagged created_account; then _ula=$(s5_msg uninstall.label_account "$S5_SERVICE_USER"); s5_say "$_ula"; fi
    s5_say_msg uninstall.no_firewall_removed
    s5_say_msg uninstall.packages_kept
    _ucq=$(s5_msg uninstall.confirm)
    if ! s5_confirm "$_ucq"; then
        _ucq=''
        s5_log_msg uninstall.aborted
        return "$EX_FAIL"
    fi
    _ucq=''

    if ! s5_teardown; then
        s5_err_msg uninstall.incomplete "$S5_STATE"
        _unh=$(s5_cmd_hint uninstall)
        _unmsg=$(s5_msg uninstall.resolve_then)
        s5_err "$_unmsg $_unh"
        _unh=''; _unmsg=''
        return "$EX_FAIL"
    fi

    _unextra=$(s5_dir_extras "$S5_STATEDIR" state)
    if [ -n "$_unextra" ]; then
        s5_err_msg uninstall.keep_state_foreign "$S5_STATEDIR"
        printf '%s\n' "$_unextra" | while IFS= read -r _unline; do
            [ -n "$_unline" ] && s5_err "    $_unline"
        done
        s5_err_msg uninstall.incomplete "$S5_STATE"
        return "$EX_FAIL"
    fi

    _unstbuf=$S5_STATE_BUF
    if ! rm -f "$S5_STATE"; then
        s5_err_msg uninstall.rm_state_failed "$S5_STATE"
        return "$EX_FAIL"
    fi
    if rmdir "$S5_STATEDIR" 2>/dev/null; then
        s5_log_msg uninstall.complete
        return "$EX_OK"
    fi
    # The state file is the retry handle. Restore it if the final directory
    # removal fails rather than claiming success and abandoning an unexplained
    # project directory.
    S5_STATE_BUF=$_unstbuf
    if ! s5_state_flush; then
        s5_err_msg uninstall.restore_failed "$S5_STATE"
        return "$EX_FAIL"
    fi
    s5_err_msg uninstall.rm_dir_retained "$S5_STATEDIR"
    return "$EX_FAIL"
}

s5_cmd_uninstall() {
    # The unlocked fast path answers "nothing is installed" and nothing else.
    # It used to call the whole locked body without the lock, re-testing only
    # $S5_STATE on entry, so a concurrent install that created the state file
    # between the two tests got its resources torn down by a teardown running
    # outside the mutex -- the one mutating path in this script not serialised
    # by it. The window was two `[` builtins wide; the fix is to not have one.
    if [ ! -e "$S5_STATE" ] && [ ! -L "$S5_STATE" ] &&
        [ ! -e "$S5_TXNDIR" ] && [ ! -L "$S5_TXNDIR" ]; then
        _un=$(s5_msg cmd.uninstall.nothing "$S5_PROJECT")
        s5_say "$_un"
        _un=''
        return "$EX_OK"
    fi
    if ! s5_is_root; then
        s5_err_msg uninstall.requires_root
        return "$EX_FAIL"
    fi
    s5_with_uninstall_lock _s5_cmd_uninstall_locked
}

s5_cmd_auto() {
    if ! s5_is_installed; then
        s5_cmd_install
        return $?
    fi
    s5_say ""
    _mh=$(s5_msg menu.heading "$S5_PROJECT")
    s5_say "$_mh"
    _mh=''
    s5_say_msg menu.option_status
    s5_say_msg menu.option_show
    s5_say_msg menu.option_restart
    s5_say_msg menu.option_uninstall
    s5_say_msg menu.option_quit
    s5_say_msg menu.option_reconfigure
    _mcp=$(s5_msg menu.choice_prompt)
    printf '%s' "$_mcp" >&2
    _mcp=''
    _cha=''
    if ! read -r _cha; then
        s5_err_msg menu.eof
        return "$EX_FAIL"
    fi
    case "$_cha" in
    1) s5_cmd_status ;;
    2) s5_cmd_show ;;
    3) s5_cmd_restart ;;
    4) s5_cmd_uninstall ;;
    5)
        s5_say_msg menu.nothing_to_do
        return "$EX_OK"
        ;;
    6) s5_cmd_install ;;
    *)
        s5_err_msg menu.invalid_choice "$_cha"
        return "$EX_USAGE"
        ;;
    esac
}

s5_main() {
    # Round 16: every invocation selects its language first -- install, direct
    # lifecycle commands, the no-argument menu, help and unknown commands all
    # re-ask in each new process. The selection is never persisted or exported.
    # The environment guard has already run at source time, before this point.
    if ! s5_select_language; then
        return "$EX_FAIL"
    fi
    if [ "$#" -eq 0 ]; then
        s5_cmd_auto
        return $?
    fi
    _cmd=$1
    shift
    # SPEC §10 defines the grammar as a single bare command; none of them takes
    # an argument or an option. Forwarding the extras to the command function,
    # which then discarded them, meant `install --port 1080` ran a plain
    # interactive install with nothing to say that the option was meaningless.
    if [ "$#" -gt 0 ]; then
        case "$_cmd" in
        install | status | show | restart | uninstall)
            _ea=$(s5_msg usage.extra_args "$_cmd" "$*")
            s5_err "$_ea"
            _ea=''
            s5_usage >&2
            return "$EX_USAGE"
            ;;
        esac
    fi
    case "$_cmd" in
    install) s5_cmd_install ;;
    status) s5_cmd_status ;;
    show) s5_cmd_show ;;
    restart) s5_cmd_restart ;;
    uninstall) s5_cmd_uninstall ;;
    -h | --help | help)
        s5_usage
        return "$EX_OK"
        ;;
    *)
        s5_err_msg usage.unknown_subcommand "$_cmd"
        s5_usage >&2
        return "$EX_USAGE"
        ;;
    esac
}

if [ "${S5_LIB_ONLY:-0}" != "1" ]; then
    s5_install_traps
    s5_main "$@"
    _s5rc=$?
    trap - EXIT
    s5_cleanup
    exit "$_s5rc"
fi
