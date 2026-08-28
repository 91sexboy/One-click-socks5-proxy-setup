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
            exit 2
        fi
        case "$S5_TEST_ROOT" in
        /*) ;;
        *)
            printf '%s: S5_TEST_ROOT must be an absolute path\n' "$0" >&2
            exit 2
            ;;
        esac
        if ! s5_test_root_ok "$S5_TEST_ROOT"; then
            printf '%s: refusing to run: unsafe S5_TEST_ROOT path: %s\n' "$0" \
                "$S5_TEST_ROOT" >&2
            exit 2
        fi
        if [ -L "$S5_TEST_ROOT" ]; then
            printf '%s: refusing to run: S5_TEST_ROOT must not be a symbolic link: %s\n' \
                "$0" "$S5_TEST_ROOT" >&2
            exit 2
        fi
        if [ ! -d "$S5_TEST_ROOT" ]; then
            printf '%s: S5_TEST_ROOT is not a directory: %s\n' "$0" "$S5_TEST_ROOT" >&2
            exit 2
        fi
        if [ ! -f "$S5_TEST_ROOT/.s5-test-root" ]; then
            printf '%s: refusing to run: sentinel .s5-test-root not found in %s\n' \
                "$0" "$S5_TEST_ROOT" >&2
            exit 2
        fi
        if [ -n "${S5_PREFIX:-}" ] && ! s5_test_path_ok "$S5_PREFIX"; then
            printf '%s: refusing to run: S5_PREFIX escapes S5_TEST_ROOT\n' "$0" >&2
            exit 2
        fi
        if [ -n "${S5_SYSCONFDIR:-}" ] && ! s5_test_path_ok "$S5_SYSCONFDIR"; then
            printf '%s: refusing to run: S5_SYSCONFDIR escapes S5_TEST_ROOT\n' "$0" >&2
            exit 2
        fi
        if [ -n "${S5_STATEDIR:-}" ] && ! s5_test_path_ok "$S5_STATEDIR"; then
            printf '%s: refusing to run: S5_STATEDIR escapes S5_TEST_ROOT\n' "$0" >&2
            exit 2
        fi
        if [ -n "${S5_UNITDIR:-}" ] && ! s5_test_path_ok "$S5_UNITDIR"; then
            printf '%s: refusing to run: S5_UNITDIR escapes S5_TEST_ROOT\n' "$0" >&2
            exit 2
        fi
        if [ -n "${S5_INITDIR:-}" ] && ! s5_test_path_ok "$S5_INITDIR"; then
            printf '%s: refusing to run: S5_INITDIR escapes S5_TEST_ROOT\n' "$0" >&2
            exit 2
        fi
        if [ -n "${S5_BUILD_DIR:-}" ] && ! s5_test_path_ok "$S5_BUILD_DIR"; then
            printf '%s: refusing to run: S5_BUILD_DIR escapes S5_TEST_ROOT\n' "$0" >&2
            exit 2
        fi
        # S5_LOGSINK and S5_TMPMODE_LOG are files this script WRITES. Unlike
        # S5_OSRELEASE and S5_PORT_PROBE -- inputs the harness itself chooses,
        # which stay unconfined -- a write path that escapes the sentinel root
        # would let a misconfigured test drop redacted diagnostics or mode
        # observations anywhere on the host filesystem.
        if [ -n "${S5_LOGSINK:-}" ] && ! s5_test_path_ok "$S5_LOGSINK"; then
            printf '%s: refusing to run: S5_LOGSINK escapes S5_TEST_ROOT\n' "$0" >&2
            exit 2
        fi
        if [ -n "${S5_TMPMODE_LOG:-}" ] && ! s5_test_path_ok "$S5_TMPMODE_LOG"; then
            printf '%s: refusing to run: S5_TMPMODE_LOG escapes S5_TEST_ROOT\n' "$0" >&2
            exit 2
        fi
        return 0
    fi

    if [ "$_s5_tm" != "0" ]; then
        printf '%s: refusing to run: test-mode variable S5_TEST_MODE has invalid value "%s"\n' \
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

    if [ -n "$s5_found_overrides" ]; then
        printf '%s: refusing to run: test-mode variable(s) set outside test mode:%s\n' \
            "$0" "$s5_found_overrides" >&2
        printf '%s: unset them, or set S5_TEST_MODE=1 with a valid S5_TEST_ROOT\n' "$0" >&2
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
        printf "run '%s %s'" "$S5_SELF" "$1"
    else
        printf "re-run the install command and choose '%s' from the menu" "$1"
    fi
}

# The summary's closing line: how to see the credentials again.
s5_redisplay_hint() {
    if [ -n "$S5_SELF" ]; then
        s5_say "  Re-display these details later with: $S5_SELF show"
    else
        s5_say "  Re-display these details later by re-running the install"
        s5_say "  command and choosing 'show' from the menu."
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

# ---------------------------------------------------------------------------
# Logging.  Every message passes through redaction so a live credential can
# never reach stdout, stderr or a log sink.
# ---------------------------------------------------------------------------

# POSIX assignment preserves an inherited export attribute. Clear every variable
# that can hold a plaintext credential before assigning to it, so an invoking
# environment cannot cause later child processes to inherit a live password.
unset S5_SECRET S5_PASSWORD S5_READ_VALUE _vp _pw1 _pw2 _lcline _lcp _stp
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
# Terminal state, signal traps, and cleanup.
#
# The full termios state is captured with `stty -g` before echo is disabled and
# restored verbatim, so an interrupt at the password prompt can never leave the
# operator's terminal with echo off.
# ---------------------------------------------------------------------------

S5_TERM_STATE=''
S5_TERM_MODIFIED=0
S5_ROLLBACK_ARMED=0
S5_INSTALL_COMPLETE=0
S5_WORKDIR=''
S5_IN_CLEANUP=0

s5_term_save() {
    if [ -t 0 ]; then
        # Checked directly, not via $?: the assignment's status IS stty's.
        # The -z test is load-bearing on its own -- stty can succeed yet
        # print nothing, and restoring an empty state would be worse than
        # not restoring at all.
        if ! S5_TERM_STATE=$(stty -g 2>/dev/null) || [ -z "$S5_TERM_STATE" ]; then
            S5_TERM_STATE=''
            S5_TERM_MODIFIED=0
            return 1
        fi
        S5_TERM_MODIFIED=1
    fi
    return 0
}

s5_term_restore() {
    if [ "$S5_TERM_MODIFIED" = "1" ] && [ -n "$S5_TERM_STATE" ]; then
        stty "$S5_TERM_STATE" 2>/dev/null || true
        S5_TERM_MODIFIED=0
    fi
    return 0
}

# s5_cleanup : idempotent. Always restores the terminal and removes a build
# tree; rolls back only when an install is armed and did not complete.
s5_cleanup() {
    if [ "$S5_IN_CLEANUP" = "1" ]; then
        return 0
    fi
    S5_IN_CLEANUP=1
    _clbad=0

    s5_term_restore

    if [ -n "$S5_WORKDIR" ]; then
        if s5_rm_workdir "$S5_WORKDIR"; then
            S5_WORKDIR=''
        else
            _clbad=1
        fi
    fi

    if [ "$S5_ROLLBACK_ARMED" = "1" ] && [ "$S5_INSTALL_COMPLETE" != "1" ]; then
        S5_ROLLBACK_ARMED=0
        s5_rollback || true
    fi

    S5_IN_CLEANUP=0
    return "${_clbad:-0}"
}

s5_on_signal() {
    s5_warn "interrupted by SIG$1; cleaning up"
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
    sed -n "s/^$2=//p" "$1" | head -n 1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

# s5_ver_ge <a> <b> : true when dotted-numeric version a >= b.
s5_ver_ge() {
    _va=$1
    _vb=$2
    while [ -n "$_va" ] || [ -n "$_vb" ]; do
        _ca=${_va%%.*}
        _cb=${_vb%%.*}
        _ca=$(printf '%s' "$_ca" | tr -cd '0-9')
        _cb=$(printf '%s' "$_cb" | tr -cd '0-9')
        if [ -z "$_ca" ]; then _ca=0; fi
        if [ -z "$_cb" ]; then _cb=0; fi
        if [ "$_ca" -gt "$_cb" ]; then return 0; fi
        if [ "$_ca" -lt "$_cb" ]; then return 1; fi
        case "$_va" in
        *.*) _va=${_va#*.} ;;
        *) _va='' ;;
        esac
        case "$_vb" in
        *.*) _vb=${_vb#*.} ;;
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
        s5_err "unsupported architecture: $1 (only x86_64/amd64 and aarch64/arm64 are supported)"
        return "$EX_UNSUPPORTED"
        ;;
    esac
}

# ID_LIKE is deliberately NEVER used to authorise an install.  RHEL, Rocky and
# AlmaLinux are recognised only so we can tell the operator they are likely
# compatible, and then refuse.
s5_detect_platform() {
    _osf=${S5_OSRELEASE:-/etc/os-release}
    if [ ! -r "$_osf" ]; then
        s5_err "cannot read $_osf: unable to identify this system"
        return "$EX_UNSUPPORTED"
    fi

    S5_OS_ID=$(s5_osrel_get "$_osf" ID)
    S5_OS_VERSION_ID=$(s5_osrel_get "$_osf" VERSION_ID)

    case "$S5_OS_ID" in
    ubuntu)
        if s5_ver_ge "$S5_OS_VERSION_ID" 22.04; then
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
        ;;
    rhel | rocky | almalinux)
        s5_err "ID=$S5_OS_ID VERSION_ID=$S5_OS_VERSION_ID is likely compatible with 3proxy, but it is not supported by this script. Supported: Ubuntu 22.04+, Debian 12+, Alpine 3.20+, CentOS Stream 9+."
        return "$EX_UNSUPPORTED"
        ;;
    esac

    s5_err "unsupported system: ID=$S5_OS_ID VERSION_ID=$S5_OS_VERSION_ID (supported: Ubuntu 22.04+, Debian 12+, Alpine 3.20+, CentOS Stream 9+)"
    return "$EX_UNSUPPORTED"
}

# s5_build_deps <pkgmgr> : packages needed only to compile 3proxy.
# ca-certificates is explicit on apt because Debian's git merely recommends
# it: with APT::Install-Recommends=false the HTTPS clone then fails
# certificate verification on an otherwise clean host. apk and dnf both pull
# it as a hard dependency of git, so it is not listed for them.
s5_build_deps() {
    case "$1" in
    apt) printf 'git build-essential ca-certificates\n' ;;
    apk) printf 'git build-base musl-dev linux-headers\n' ;;
    dnf | yum) printf 'git gcc make\n' ;;
    *) return 1 ;;
    esac
}

# s5_runtime_deps : tools needed to verify and self-test the installed proxy.
# curl is added only when absent. A clean host also needs one reliable way to
# inspect listening TCP ports before the port prompt; install the distro package
# that provides ss only when neither ss nor netstat (nor a test probe) exists.
s5_runtime_deps() {
    _rt=''
    if ! command -v curl >/dev/null 2>&1; then
        _rt='curl'
    fi
    if ! s5_port_probe_available; then
        case "$S5_PKGMGR" in
        apt | apk) _rtprobe=iproute2 ;;
        dnf | yum) _rtprobe=iproute ;;
        *)
            s5_err "no port-probe package for package manager: ${S5_PKGMGR:-unknown}"
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

# Commands that must already exist before installation can start. The compiler,
# make and git are installed later and are deliberately NOT listed here.
#
# Everything the script invokes at a site that hard-fails belongs here, so a
# missing utility is named by this gate instead of surfacing as an obscure error
# mid-install (chown while applying credential-file ownership, uname on the very
# next line of s5_precheck, tail in the destination-deny ordering check, rmdir
# during uninstall). stty is deliberately absent: every stty call site already
# tolerates its absence, so requiring it would abort installs that would
# otherwise succeed.
S5_BASE_COMMANDS='sed awk grep tr head tail cut id chown chmod mkdir rmdir rm mv cat printf stat mktemp dirname uname'

s5_require_commands() {
    _miss=''
    for _rc in "$@"; do
        if ! command -v "$_rc" >/dev/null 2>&1; then
            _miss="$_miss $_rc"
        fi
    done
    if [ -n "$_miss" ]; then
        s5_err "required command(s) not found:$_miss"
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
        s5_err "cannot continue without the base utilities listed above"
        return "$EX_FAIL"
    fi
    if ! s5_detect_platform; then
        return "$EX_UNSUPPORTED"
    fi
    S5_ARCHNAME=$(s5_map_arch "$(uname -m)") || return "$EX_UNSUPPORTED"
    if ! s5_is_root; then
        s5_err "installation requires root privileges; re-run with sudo"
        return "$EX_FAIL"
    fi
    if ! s5_pkgmgr_available; then
        s5_err "the detected package manager ($S5_PKGMGR) is not installed on this system"
        s5_err "install it, or use a supported image, then retry"
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
S5_READ_VALUE=''

s5_valid_port() {
    case "${1:-}" in
    '' | *[!0-9]*)
        s5_err "port must be a decimal number"
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
        s5_err "port must not have leading zeros"
        return 1
        ;;
    esac
    # Compare only after bounding the digit count. POSIX test arithmetic may
    # diagnose an oversized integer and return false; two false comparisons used
    # to accept an arbitrarily long digit string as a valid port.
    if [ "${#1}" -gt 5 ]; then
        s5_err "port must be between $S5_PORT_MIN and $S5_PORT_MAX"
        return 1
    fi
    if [ "$1" -lt "$S5_PORT_MIN" ] || [ "$1" -gt "$S5_PORT_MAX" ]; then
        s5_err "port must be between $S5_PORT_MIN and $S5_PORT_MAX"
        return 1
    fi
    return 0
}

s5_valid_username() {
    _vu=${1:-}
    _vul=${#_vu}
    if [ "$_vul" -lt "$S5_USER_MIN" ] || [ "$_vul" -gt "$S5_USER_MAX" ]; then
        s5_err "username must be $S5_USER_MIN-$S5_USER_MAX characters long (got $_vul)"
        return 1
    fi
    case "$_vu" in
    *[!A-Za-z0-9_-]*)
        s5_err "username may contain only A-Z a-z 0-9 underscore and hyphen"
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
        s5_err "password must be $S5_PASS_MIN-$S5_PASS_MAX characters long (got $_vpl)"
        return 1
    fi
    case "$_vp" in
    *[!A-Za-z0-9._~-]*)
        s5_err "password may contain only A-Z a-z 0-9 dot underscore tilde and hyphen"
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
        s5_err "could not draw $_rgn random characters from /dev/urandom (got ${#_rgv})"
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
        s5_err "s5_random_int: count out of supported range: $_ricnt"
        return 1
    fi
    while :; do
        _rid=$(s5_random_string 5 '0123456789') || return 1
        _riv=$(printf '%s' "$_rid" | sed 's/^0*//')
        if [ -z "$_riv" ]; then
            _riv=0
        fi
        if [ "$_riv" -lt "$_ricnt" ]; then
            printf '%s' "$_riv"
            return 0
        fi
    done
}

# Split out so the fail-closed path in s5_port_free is directly testable
# (busybox ships netstat as a built-in applet that PATH cannot hide).
#
# A probe must WORK, not merely exist: `command -v` alone used to treat a
# broken ss on PATH as available, which suppressed the iproute2 repair and
# masked a working netstat behind it. Each candidate is actually run once.
s5_probe_cmd() {
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
    s5_err "cannot determine whether a port is free (neither ss nor netstat found)"
    s5_err "install iproute2 (for ss) or net-tools (for netstat), then retry"
}

# s5_port_free <port> : true when nothing is listening. Never binds.
# Fail-closed: with no probe available we report "not free".
s5_port_free() {
    if [ "${S5_TEST_MODE:-0}" = "1" ] && [ -n "${S5_PORT_PROBE:-}" ]; then
        "$S5_PORT_PROBE" "$1"
        return $?
    fi
    if ! _pfc=$(s5_probe_cmd); then
        s5_warn "cannot determine whether port $1 is free (neither ss nor netstat found)"
        return 1
    fi
    case "$_pfc" in
    ss) _pfout=$(ss -ltn 2>/dev/null); _pfr=$? ;;
    netstat) _pfout=$(netstat -ltn 2>/dev/null); _pfr=$? ;;
    *) return 1 ;;
    esac
    if [ "$_pfr" -ne 0 ]; then
        s5_warn "cannot determine whether port $1 is free: $_pfc failed"
        return 2
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
            s5_err "cannot determine whether port $_rpp is free: the listen-state probe failed"
            return 1
            ;;
        esac
    done
    s5_err "no free port found in $S5_RANDPORT_MIN-$S5_RANDPORT_MAX after 50 attempts"
    return 1
}

# s5_read_secret : read one line into S5_READ_VALUE with echo suppressed.
# The full termios state is saved first and restored via the same path the
# signal traps use, so an interrupt cannot leave echo disabled.
s5_read_secret() {
    S5_READ_VALUE=''
    _rsok=0
    if [ -t 0 ]; then
        if ! s5_term_save; then
            s5_err "cannot save terminal state; refusing to read a password"
            return 1
        fi
        stty -echo 2>/dev/null || {
            s5_term_restore
            s5_err "cannot disable terminal echo; refusing to read a password"
            return 1
        }
        if read -r S5_READ_VALUE; then _rsok=1; fi
        s5_term_restore
        printf '\n' >&2
    else
        if read -r S5_READ_VALUE; then _rsok=1; fi
    fi
    if [ "$_rsok" = "1" ]; then
        return 0
    fi
    return 1
}

s5_prompt_port() {
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
        printf 'SOCKS5 port [Enter = random %s-%s]: ' \
            "$S5_RANDPORT_MIN" "$S5_RANDPORT_MAX" >&2
        _ppin=''
        if ! read -r _ppin; then
            s5_err "unexpected end of input while reading the port"
            return 1
        fi
        if [ -z "$_ppin" ]; then
            _pprand=$(s5_random_port) || return 1
            S5_PORT=$_pprand
            s5_log "selected random port $S5_PORT"
            return 0
        fi
        if ! s5_valid_port "$_ppin"; then
            continue
        fi
        # Three-valued like every other observation: a probe failure (status
        # 2) is not evidence that the port is busy, and blaming the operator's
        # port for the probe's failure sends them hunting the wrong problem.
        s5_port_free "$_ppin"
        _ppr=$?
        case "$_ppr" in
        0) ;;
        1)
            s5_err "port $_ppin is already in use"
            continue
            ;;
        *)
            s5_err "cannot determine whether port $_ppin is free: the listen-state probe failed"
            continue
            ;;
        esac
        S5_PORT=$_ppin
        return 0
    done
    s5_err "too many invalid port entries"
    return 1
}

s5_prompt_username() {
    _una=0
    while [ "$_una" -lt 5 ]; do
        _una=$((_una + 1))
        printf 'SOCKS5 username [Enter = random]: ' >&2
        _unin=''
        if ! read -r _unin; then
            s5_err "unexpected end of input while reading the username"
            return 1
        fi
        if [ -z "$_unin" ]; then
            if ! S5_USERNAME=$(s5_random_username); then
                S5_USERNAME=''
                s5_err "could not generate a random username"
                return 1
            fi
            s5_log "generated random username $S5_USERNAME"
            return 0
        fi
        if ! s5_valid_username "$_unin"; then
            continue
        fi
        S5_USERNAME=$_unin
        return 0
    done
    s5_err "too many invalid username entries"
    return 1
}

s5_prompt_password() {
    _pwa=0
    while [ "$_pwa" -lt 5 ]; do
        _pwa=$((_pwa + 1))
        printf 'SOCKS5 password [Enter = generate %s random chars]: ' "$S5_PASS_GEN_LEN" >&2
        if ! s5_read_secret; then
            s5_err "unexpected end of input while reading the password"
            return 1
        fi
        _pw1=$S5_READ_VALUE
        S5_READ_VALUE=''
        if [ -z "$_pw1" ]; then
            # The announcement below states a length, so it must not be printed
            # unless a string of exactly that length was really produced.
            if ! S5_PASSWORD=$(s5_random_password); then
                S5_PASSWORD=''
                s5_err "could not generate a random password"
                return 1
            fi
            S5_SECRET=$S5_PASSWORD
            s5_log "generated a random $S5_PASS_GEN_LEN-character password"
            return 0
        fi
        if ! s5_valid_password "$_pw1"; then
            _pw1=''
            continue
        fi
        printf 'Confirm password: ' >&2
        if ! s5_read_secret; then
            _pw1=''
            s5_err "unexpected end of input while confirming the password"
            return 1
        fi
        _pw2=$S5_READ_VALUE
        S5_READ_VALUE=''
        if [ "$_pw1" != "$_pw2" ]; then
            _pw1=''
            _pw2=''
            s5_err "passwords do not match"
            continue
        fi
        S5_PASSWORD=$_pw1
        S5_SECRET=$S5_PASSWORD
        _pw1=''
        _pw2=''
        return 0
    done
    s5_err "too many failed password attempts"
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
        s5_err "refusing to write $1: it is a symbolic link"
        return 1
    fi
    if [ ! -f "$1" ]; then
        s5_err "refusing to write $1: not a regular file"
        return 1
    fi
    if ! chmod 0600 "$1"; then
        s5_err "cannot set mode 0600 on $1"
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
        s5_err "refusing to use $1: it is a symbolic link"
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
        s5_err "refusing to use $1: it is not a directory"
        return 1
    fi
    if ! _s5_mkdir_component "$(dirname "$1")" "$2" "$3" "$4"; then
        return 1
    fi
    if ! mkdir "$1"; then
        s5_err "cannot create $1"
        return 1
    fi
    # Restrict the new inode before applying its intended traversable mode.
    if ! chmod 0700 "$1"; then
        s5_err "cannot restrict $1 to mode 0700"
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
        s5_err "refusing to use $1: it is a symbolic link"
        return 1
    fi
    # Existing directories may be shared with the host administrator. Do not
    # silently replace their owner or mode merely because this script needs to
    # place a file below them. The helper still walks their ancestors so a
    # symlinked parent cannot redirect the operation outside the intended tree.
    _s5_mkdir_component "$1" "$2" "$3" "$1"
}

# s5_atomic_write <final-path> <owner:group> <final-mode>   (content on stdin)
s5_atomic_write() {
    _awp=$1
    _awo=$2
    _awm=$3
    _awd=$(dirname "$_awp")
    if [ ! -d "$_awd" ]; then
        s5_err "cannot write $_awp: directory $_awd does not exist"
        return 1
    fi
    if [ -L "$_awp" ]; then
        s5_err "refusing to write $_awp: it is a symbolic link"
        return 1
    fi
    if ! _awt=$(mktemp "$_awd/.s5tmp.XXXXXX"); then
        s5_err "cannot create a temporary file in $_awd"
        return 1
    fi
    if ! s5_secure_tmp "$_awt"; then
        rm -f "$_awt"
        return 1
    fi
    s5_modelog "tmp-created:$_awp" "$_awt"
    if ! cat >"$_awt"; then
        s5_err "cannot write $_awt"
        rm -f "$_awt"
        return 1
    fi
    s5_modelog "tmp-written:$_awp" "$_awt"
    if ! s5_apply_owner_mode "$_awt" "$_awo" "$_awm"; then
        rm -f "$_awt"
        return 1
    fi
    if ! mv "$_awt" "$_awp"; then
        s5_err "cannot install $_awp"
        rm -f "$_awt"
        return 1
    fi
    return 0
}

# s5_apply_owner_mode <path> <owner:group> <mode>
s5_apply_owner_mode() {
    if ! chmod "$3" "$1"; then
        s5_err "cannot set mode $3 on $1"
        return 1
    fi
    if [ "${S5_TEST_MODE:-0}" = "1" ] && [ "${S5_SKIP_OWNERSHIP:-0}" = "1" ]; then
        return 0
    fi
    if ! chown "$2" "$1"; then
        s5_err "cannot set ownership $2 on $1"
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

S5_STATE_KEYS_ONCE='tag commit origin port username os family arch init listen account_uid account_gid status'
S5_STATE_KEYS_FLAG='created_account created_group created_confdir created_prefix created_bin created_cfg created_users created_unit created_initscript'
S5_STATE_KEYS_MULTI='package'
S5_STATE_BUF=''
S5_STATE_LOADED=0

s5_state_key_known() {
    for _skk in $S5_STATE_KEYS_ONCE $S5_STATE_KEYS_FLAG $S5_STATE_KEYS_MULTI; do
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
    for _sok in $S5_STATE_KEYS_ONCE; do
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
        s5_err "state: value for '$1' contains a disallowed character"
        return 1
        ;;
    esac
    if s5_state_key_is_flag "$1"; then
        if [ "$2" != "1" ]; then
            s5_err "state: flag '$1' must be exactly 1"
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
            s5_err "state: port is not numeric"
            return 1
            ;;
        0*)
            s5_err "state: port must not have leading zeros"
            return 1
            ;;
        ??????*)
            s5_err "state: port out of range"
            return 1
            ;;
        esac
        if [ "$2" -lt "$S5_PORT_MIN" ] || [ "$2" -gt "$S5_PORT_MAX" ]; then
            s5_err "state: port out of range"
            return 1
        fi
        ;;
    username)
        if ! s5_valid_username "$2" >/dev/null 2>&1; then
            s5_err "state: username is not valid"
            return 1
        fi
        ;;
    commit)
        # A git object name is exactly 40 hexadecimal characters. The old
        # pattern was 8 hex characters followed by an unbounded '*', which in
        # a shell case pattern means "then anything", so any 8-hex prefix
        # with an allowed trailing character was accepted.
        if [ "${#2}" -ne 40 ]; then
            s5_err "state: commit must be exactly 40 hexadecimal characters"
            return 1
        fi
        case "$2" in
        *[!0-9a-f]*)
            s5_err "state: commit is not a hex object name"
            return 1
            ;;
        esac
        ;;
    init)
        case "$2" in
        systemd | openrc) ;;
        *)
            s5_err "state: unknown init system '$2'"
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
            s5_err "state: $1 must be numeric"
            return 1
        fi
        ;;
    status)
        case "$2" in
        complete) ;;
        *)
            s5_err "state: unknown status '$2'"
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
        s5_err "refusing to read $S5_STATE: it is a symbolic link"
        return 1
    fi
    if [ ! -f "$S5_STATE" ]; then
        s5_err "refusing to read $S5_STATE: not a regular file"
        return 1
    fi
    if [ ! -r "$S5_STATE" ]; then
        s5_err "cannot read the state file $S5_STATE"
        return 1
    fi

    _slmode=$(stat -c '%a' "$S5_STATE" 2>/dev/null || printf '')
    if [ "$_slmode" != 600 ]; then
        s5_err "refusing to read $S5_STATE: state file must be mode 0600 (found ${_slmode:-unknown})"
        return 1
    fi
    if ! _slcontents=$(cat "$S5_STATE"); then
        s5_err "could not read the state file $S5_STATE"
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
            s5_err "state: line $_slline is malformed (no field separator)"
            _slbad=1
            continue
            ;;
        esac
        _slk=${_sl%%	*}
        _slv=${_sl#*	}
        if ! s5_state_key_known "$_slk"; then
            s5_err "state: unknown key '$_slk' on line $_slline"
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
                    s5_err "state: duplicate key '$_slk' on line $_slline"
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
        s5_err "could not read the state file $S5_STATE"
        return 1
    fi

    if [ "$_slbad" -ne 0 ]; then
        s5_err "state file is corrupt; refusing to act on it"
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
        for _slk in $S5_STATE_KEYS_ONCE; do
            if [ "$_slk" != status ] && [ -z "$(s5_state_get "$_slk")" ]; then
                _slmiss="$_slmiss $_slk"
            fi
        done
        if [ -n "$_slmiss" ]; then
            s5_err "state: claims to be complete but is missing:$_slmiss"
            S5_STATE_BUF=''
            S5_STATE_LOADED=0
            return 1
        fi
    fi
    return 0
}

# s5_state_flush : atomic rewrite of the whole state file. Return value checked
# by every caller.
s5_state_flush() {
    if ! _sft=$(mktemp "$S5_STATEDIR/.s5state.XXXXXX"); then
        s5_err "cannot create a temporary state file in $S5_STATEDIR"
        return 1
    fi
    if ! s5_secure_tmp "$_sft"; then
        rm -f "$_sft"
        return 1
    fi
    s5_modelog "tmp-created:$S5_STATE" "$_sft"
    if ! printf '%s\n' "$S5_STATE_BUF" >"$_sft"; then
        s5_err "cannot write the state file"
        rm -f "$_sft"
        return 1
    fi
    s5_modelog "tmp-written:$S5_STATE" "$_sft"
    if ! s5_apply_owner_mode "$_sft" "root:root" 0600; then
        rm -f "$_sft"
        return 1
    fi
    if ! mv "$_sft" "$S5_STATE"; then
        s5_err "cannot install the state file"
        rm -f "$_sft"
        return 1
    fi
    return 0
}

# Undo what s5_state_begin managed to create before its first records could
# be persisted. Nothing exists outside the state directory at that point, so
# removing the directory is complete; rmdir also refuses to remove anything a
# concurrent foreign file landed in.
_s5_state_begin_undo() {
    rm -f "$S5_STATE" 2>/dev/null || true
    rmdir "$S5_STATEDIR" 2>/dev/null || true
    S5_STATE_BUF=''
    S5_STATE_LOADED=0
}

s5_state_begin() {
    if ! s5_mkdir_secure "$S5_STATEDIR" "root:root" 0700; then
        return 1
    fi
    S5_STATE_BUF=''
    S5_STATE_LOADED=1
    if ! s5_state_add tag "$S5_UPSTREAM_TAG"; then
        _s5_state_begin_undo
        return 1
    fi
    if ! s5_state_add commit "$S5_PINNED_COMMIT"; then
        _s5_state_begin_undo
        return 1
    fi
    if ! s5_state_add origin "source-build"; then
        _s5_state_begin_undo
        return 1
    fi
    return 0
}

# s5_state_add <key> <value> : validate, append, and atomically rewrite.
s5_state_add() {
    if ! s5_state_key_known "$1"; then
        s5_err "state: refusing to record unknown key '$1'"
        return 1
    fi
    if ! s5_state_value_ok "$1" "$2"; then
        return 1
    fi
    if [ -n "$S5_STATE_BUF" ]; then
        S5_STATE_BUF="$S5_STATE_BUF
$1	$2"
    else
        S5_STATE_BUF="$1	$2"
    fi
    if ! s5_state_flush; then
        s5_err "state: could not persist '$1'; aborting to avoid orphaned resources"
        return 1
    fi
    return 0
}

# s5_state_mark <flag-key> : record that this run created a fixed resource.
s5_state_mark() {
    s5_state_add "$1" 1
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
# Source fetch, pinned-commit verification, and build.
# ---------------------------------------------------------------------------

s5_make_workdir() {
    if [ "${S5_TEST_MODE:-0}" = "1" ]; then
        _wdbase=${S5_BUILD_DIR:-$S5_TEST_ROOT/build}
        mkdir -p "$_wdbase" || return 1
        mktemp -d "$_wdbase/b.XXXXXX"
        return $?
    fi
    mktemp -d "${TMPDIR:-/tmp}/socks5-manager-build.XXXXXX"
}

# s5_rm_workdir <dir> : remove a build directory, but only one that looks like
# ours, so a bug can never turn this into an arbitrary recursive delete.
s5_rm_workdir() {
    case "${1:-}" in
    '' | '/')
        s5_warn "refusing to remove build directory: ${1:-<empty>}"
        return 1
        ;;
    */socks5-manager-build.* | */b.??????)
        if ! rm -rf "$1"; then
            s5_err "could not remove build directory $1"
            return 1
        fi
        if [ -e "$1" ] || [ -L "$1" ]; then
            s5_err "build directory still exists after removal: $1"
            return 1
        fi
        return 0
        ;;
    *)
        s5_warn "refusing to remove unexpected build directory: $1"
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
    # /usr/local/libexec may be absent on a clean host. Creating the complete
    # prefix with one `mkdir -p` under umask 077 leaves newly-created parents at
    # 0700, so the unprivileged service cannot traverse to the binary. Build the
    # fixed prefix one component at a time and clamp each project-owned parent to
    # its required traversable mode. Existing parents are left at their existing
    # modes apart from the standard secure helper's explicit final mode.
    if [ ! -d "$S5_ROOTDIR/usr" ]; then
        if ! s5_mkdir_secure "$S5_ROOTDIR/usr" "root:root" 0755; then return 1; fi
    fi
    if [ ! -d "$S5_ROOTDIR/usr/local" ]; then
        if ! s5_mkdir_secure "$S5_ROOTDIR/usr/local" "root:root" 0755; then return 1; fi
    fi
    if [ ! -d "$S5_ROOTDIR/usr/local/libexec" ]; then
        if ! s5_mkdir_secure "$S5_ROOTDIR/usr/local/libexec" "root:root" 0755; then return 1; fi
    fi
    if ! s5_mkdir_secure "$S5_PREFIX" "root:root" 0755; then
        return 1
    fi
    if ! _ibt=$(mktemp "$S5_PREFIX/.s5bin.XXXXXX"); then
        s5_err "cannot create a temporary file in $S5_PREFIX"
        return 1
    fi
    if ! s5_secure_tmp "$_ibt"; then
        rm -f "$_ibt"
        return 1
    fi
    if ! cat <"$1" >"$_ibt"; then
        s5_err "cannot copy the built binary to $S5_PREFIX"
        rm -f "$_ibt"
        return 1
    fi
    if ! s5_apply_owner_mode "$_ibt" "root:root" 0755; then
        rm -f "$_ibt"
        return 1
    fi
    if ! mv "$_ibt" "$S5_BIN"; then
        s5_err "cannot install the binary at $S5_BIN"
        rm -f "$_ibt"
        return 1
    fi
    return 0
}

s5_build_3proxy() {
    _bwd=$(s5_make_workdir)
    if [ -z "$_bwd" ] || [ ! -d "$_bwd" ]; then
        s5_err "cannot create a build directory"
        return 1
    fi
    S5_WORKDIR=$_bwd
    _bsrc="$_bwd/3proxy"

    s5_log "fetching 3proxy $S5_UPSTREAM_TAG from $S5_REPO_URL"
    if ! git clone --quiet "$S5_REPO_URL" "$_bsrc"; then
        s5_err "git clone failed"
        s5_release_workdir
        return 1
    fi

    s5_log "checking out pinned commit $S5_PINNED_COMMIT"
    if ! git -C "$_bsrc" checkout --quiet --detach "$S5_PINNED_COMMIT"; then
        s5_err "git checkout of the pinned commit failed"
        s5_release_workdir
        return 1
    fi

    _bhead=$(git -C "$_bsrc" rev-parse HEAD 2>/dev/null | tr -d ' \t\n')
    if [ "$_bhead" != "$S5_PINNED_COMMIT" ]; then
        s5_err "HEAD verification failed: expected $S5_PINNED_COMMIT, got ${_bhead:-<empty>}"
        s5_release_workdir
        return 1
    fi
    s5_log "HEAD verified against the pinned commit"

    if ! _bout=$(cd "$_bsrc" && make -f Makefile.Linux 2>&1); then
        s5_err "build failed (make -f Makefile.Linux)"
        printf '%s\n' "$_bout" | tail -n 20 >&2
        s5_release_workdir
        return 1
    fi

    if [ ! -f "$_bsrc/bin/3proxy" ] || [ -L "$_bsrc/bin/3proxy" ]; then
        s5_err "build produced no regular bin/3proxy artifact"
        s5_release_workdir
        return 1
    fi
    if [ ! -x "$_bsrc/bin/3proxy" ]; then
        s5_err "built bin/3proxy is not executable"
        s5_release_workdir
        return 1
    fi

    if ! s5_install_binary "$_bsrc/bin/3proxy"; then
        s5_release_workdir
        return 1
    fi

    s5_log "installed $S5_BIN"
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
        s5_err "cannot render configuration: invalid port"
        return 1
    fi
    if ! s5_valid_username "$S5_USERNAME" >/dev/null 2>&1; then
        s5_err "cannot render configuration: invalid username"
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
        s5_err "refusing to render credentials: username is not valid"
        return 1
    fi
    if ! s5_valid_password "$S5_PASSWORD" >/dev/null 2>&1; then
        s5_err "refusing to render credentials: password is not valid"
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
    _cgout=$(id -g "$S5_SERVICE_GROUP" 2>/dev/null) || return 2
    printf '%s' "$_cgout"
    return 0
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
    grep -q "^$S5_SERVICE_GROUP:" /etc/group 2>/dev/null
    _ger=$?
    case "$_ger" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
    esac
}

s5_account_create() {
    _nl=$(s5_nologin_path)
    case "$S5_OS_FAMILY" in
    alpine)
        s5_group_exists
        _acger=$?
        case "$_acger" in
        0) ;;
        1)
            if ! addgroup -S "$S5_SERVICE_GROUP"; then
                s5_err "failed to create the $S5_SERVICE_GROUP group"
                return 1
            fi
            ;;
        *)
            s5_err "could not determine whether the $S5_SERVICE_GROUP group exists"
            return 1
            ;;
        esac
        if ! adduser -S -D -H -G "$S5_SERVICE_GROUP" -s "$_nl" "$S5_SERVICE_USER"; then
            s5_err "failed to create the $S5_SERVICE_USER account"
            return 1
        fi
        ;;
    *)
        s5_group_exists
        _acger=$?
        case "$_acger" in
        0) ;;
        1)
            if ! groupadd -r "$S5_SERVICE_GROUP"; then
                s5_err "failed to create the $S5_SERVICE_GROUP group"
                return 1
            fi
            ;;
        *)
            s5_err "could not determine whether the $S5_SERVICE_GROUP group exists"
            return 1
            ;;
        esac
        if ! useradd -r -g "$S5_SERVICE_GROUP" -M -d /nonexistent \
            -s "$_nl" "$S5_SERVICE_USER"; then
            s5_err "failed to create the $S5_SERVICE_USER account"
            return 1
        fi
        ;;
    esac
    return 0
}

# s5_del_user / s5_del_group : try the family's tool, then the other family's,
# without ever assuming success.
s5_del_user() {
    case "$S5_OS_FAMILY" in
    alpine)
        if command -v deluser >/dev/null 2>&1 && deluser "$S5_SERVICE_USER" 2>/dev/null; then
            return 0
        fi
        if command -v userdel >/dev/null 2>&1 && userdel "$S5_SERVICE_USER" 2>/dev/null; then
            return 0
        fi
        ;;
    *)
        if command -v userdel >/dev/null 2>&1 && userdel "$S5_SERVICE_USER" 2>/dev/null; then
            return 0
        fi
        if command -v deluser >/dev/null 2>&1 && deluser "$S5_SERVICE_USER" 2>/dev/null; then
            return 0
        fi
        ;;
    esac
    return 1
}

s5_del_group() {
    case "$S5_OS_FAMILY" in
    alpine)
        if command -v delgroup >/dev/null 2>&1 && delgroup "$S5_SERVICE_GROUP" 2>/dev/null; then
            return 0
        fi
        if command -v groupdel >/dev/null 2>&1 && groupdel "$S5_SERVICE_GROUP" 2>/dev/null; then
            return 0
        fi
        ;;
    *)
        if command -v groupdel >/dev/null 2>&1 && groupdel "$S5_SERVICE_GROUP" 2>/dev/null; then
            return 0
        fi
        if command -v delgroup >/dev/null 2>&1 && delgroup "$S5_SERVICE_GROUP" 2>/dev/null; then
            return 0
        fi
        ;;
    esac
    return 1
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
        s5_err "the state does not record a usable account uid; remove $S5_SERVICE_USER manually if it is yours"
        return 1
        ;;
    esac
    _argid=''
    if [ "$_arwantgroup" = "1" ]; then
        case "${3:-}" in
        '' | *[!0-9]*)
            s5_err "the state does not record a usable group gid; remove $S5_SERVICE_GROUP manually if it is yours"
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
            s5_err "could not determine the current uid of $S5_SERVICE_USER"
            _arbad=1
        elif [ "$_arcuid" != "$_aruid" ]; then
            s5_err "refusing to remove $S5_SERVICE_USER: the name now answers to uid $_arcuid, not the uid $_aruid this script created (the name was reused)"
            _arbad=1
        else
            s5_del_user || true
            s5_account_exists
            _arer=$?
            case "$_arer" in
            0)
                s5_err "the $S5_SERVICE_USER account still exists after the removal attempt"
                _arbad=1
                ;;
            1) ;;
            *)
                s5_err "could not determine whether the $S5_SERVICE_USER account was removed"
                _arbad=1
                ;;
            esac
        fi
        ;;
    1) ;;
    *)
        s5_err "could not determine whether the $S5_SERVICE_USER account exists"
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
                s5_err "could not determine the current gid of $S5_SERVICE_GROUP"
                _arbad=1
            elif [ "$_arcgid" != "$_argid" ]; then
                s5_err "refusing to remove $S5_SERVICE_GROUP: the name now answers to gid $_arcgid, not the gid $_argid this script created (the name was reused)"
                _arbad=1
            else
                s5_del_group || true
                s5_group_exists
                _ager=$?
                case "$_ager" in
                0)
                    s5_err "the $S5_SERVICE_GROUP group still exists after the removal attempt"
                    _arbad=1
                    ;;
                1) ;;
                *)
                    s5_err "could not determine whether the $S5_SERVICE_GROUP group was removed"
                    _arbad=1
                    ;;
                esac
            fi
            ;;
        1) ;;
        *)
            s5_err "could not determine whether the $S5_SERVICE_GROUP group exists"
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

s5_static_check_cfg() {
    _scf=$1
    if [ ! -f "$_scf" ]; then
        s5_err "static check: configuration not found: $_scf"
        return 1
    fi
    _scbad=0

    if ! grep -q '^log$' "$_scf"; then
        s5_err "static check: missing 'log'"
        _scbad=1
    fi
    if ! grep -q '^auth strong$' "$_scf"; then
        s5_err "static check: missing 'auth strong'"
        _scbad=1
    fi
    _scflushcount=$(grep -c '^flush$' "$_scf" || true)
    _scflush=$(grep -n '^flush$' "$_scf" | head -n 1 | cut -d: -f1)
    if [ "$_scflushcount" -ne 1 ]; then
        s5_err "static check: expected exactly one flush directive"
        _scbad=1
    fi
    if ! grep -q '^allow .* CONNECT$' "$_scf"; then
        s5_err "static check: missing an explicit 'allow ... CONNECT' rule"
        _scbad=1
    fi
    _scdenycount=$(grep -c '^deny \*$' "$_scf" || true)
    _scdenyline=$(grep -n '^deny \*$' "$_scf" | head -n 1 | cut -d: -f1)
    if [ "$_scdenycount" -ne 1 ]; then
        s5_err "static check: expected exactly one terminal deny"
        _scbad=1
    fi
    if ! grep -q '^socks -4 -u2 -p[0-9][0-9]* -i' "$_scf"; then
        s5_err "static check: missing 'socks -4 -u2 -p<port> -i<address>'"
        _scbad=1
    fi
    _scinclude=$(grep -cFx "users \$$S5_USERSCFG" "$_scf" || true)
    if [ "$_scinclude" -ne 1 ]; then
        s5_err "static check: expected exactly one credentials include"
        _scbad=1
    fi
    _scsockcount=$(grep -c '^socks[[:space:]]' "$_scf" || true)
    if [ "$_scsockcount" -ne 1 ] ||
        ! grep -qxF "socks -4 -u2 -p$S5_PORT -i$S5_LISTEN" "$_scf"; then
        s5_err "static check: expected exactly one socks -4 -u2 -p$S5_PORT -i$S5_LISTEN line"
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
        s5_err "static check: expected exactly one allow $S5_USERNAME * * * CONNECT rule"
        _scbad=1
    fi
    if [ -z "$_scallow" ]; then
        _scallow=0
    fi
    _scfirstdeny=$(grep -n '^deny \* \* ' "$_scf" | head -n 1 | cut -d: -f1)
    if [ -z "$_scflush" ] || [ -z "$_scfirstdeny" ] ||
        [ "$_scflush" -ge "$_scfirstdeny" ]; then
        s5_err "static check: flush must precede all destination deny rules"
        _scbad=1
    fi
    if [ -z "$_scdenyline" ] || [ "$_scallow" -eq 0 ] ||
        [ "$_scdenyline" -le "$_scallow" ]; then
        s5_err "static check: terminal deny must follow the allow rule"
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
        s5_err "static check: missing destination deny rule(s):$_scmissing"
        _scbad=1
    fi

    _sclastdeny=$(grep -n '^deny \* \* ' "$_scf" | tail -n 1 | cut -d: -f1)
    if [ -z "$_sclastdeny" ]; then
        s5_err "static check: no destination deny rules found"
        _scbad=1
    elif [ "$_scallow" -eq 0 ] || [ "$_sclastdeny" -ge "$_scallow" ]; then
        s5_err "static check: destination deny rules must precede the allow rule"
        _scbad=1
    fi
    _sccidrcount=$(grep -c '^deny \* \* ' "$_scf" || true)
    if [ "$_sccidrcount" -ne "$_scwant" ]; then
        s5_err "static check: expected $_scwant destination deny rules, found $_sccidrcount"
        _scbad=1
    fi

    _sccount=$(grep -c '^socks[[:space:]]' "$_scf" || true)
    if [ "$_sccount" -ne 1 ]; then
        s5_err "static check: expected exactly one socks service line, found $_sccount"
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
            s5_err "static check: forbidden directive present: $_scd"
            _scbad=1
        fi
    done
    if grep -qE 'auth none|auth iponly' "$_scf"; then
        s5_err "static check: weak authentication directive present"
        _scbad=1
    fi
    if grep -qE 'BIND|UDPASSOC' "$_scf"; then
        s5_err "static check: forbidden operation present (BIND or UDPASSOC)"
        _scbad=1
    fi

    if [ ! -f "$S5_USERSCFG" ] || [ -L "$S5_USERSCFG" ]; then
        s5_err "static check: credentials file must be a regular non-symbolic-link file"
        _scbad=1
    else
        _scm=$(stat -c '%a' "$S5_USERSCFG" 2>/dev/null || printf '')
        _sco=$(stat -c '%U:%G' "$S5_USERSCFG" 2>/dev/null || printf '')
        case "$_scm" in
        600 | 640) ;;
        *)
            s5_err "static check: credentials file must be mode 0600 or 0640, found ${_scm:-unknown}"
            _scbad=1
            ;;
        esac
        if [ "${S5_TEST_MODE:-0}" != 1 ] && [ "$_sco" != "root:$S5_SERVICE_GROUP" ]; then
            s5_err "static check: credentials file must be owned by root:$S5_SERVICE_GROUP, found ${_sco:-unknown}"
            _scbad=1
        fi
        _screccount=$(grep -c '' "$S5_USERSCFG" 2>/dev/null)
        _scread=$?
        if [ "$_scread" -gt 1 ]; then
            s5_err "static check: cannot read credentials file"
            _scbad=1
        elif [ "$_screccount" -ne 1 ]; then
            s5_err "static check: credentials file must contain exactly one credential for the configured username"
            _scbad=1
        else
            _scline=$(cat "$S5_USERSCFG" 2>/dev/null)
            _scread=$?
            if [ "$_scread" -ne 0 ]; then
                s5_err "static check: cannot read credentials file"
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
                    s5_err "static check: credentials file must contain exactly one credential for the configured username"
                    _scbad=1
                fi
            fi
        fi
    fi

    if [ "$_scbad" -ne 0 ]; then
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Self-test.  Credentials reach curl through `--config -` on stdin only.
# ---------------------------------------------------------------------------

s5_curl_config() {
    printf 'socks5-hostname = "127.0.0.1:%s"\n' "$S5_PORT"
    printf 'proxy-user = "%s:%s"\n' "$1" "$2"
    printf 'url = "%s"\n' "$S5_SELFTEST_URL"
    printf 'output = "/dev/null"\n'
    printf 'max-time = 20\n'
    printf 'silent\n'
    printf 'show-error\n'
}

s5_selftest_good() {
    s5_curl_config "$1" "$2" | curl --config -
}

# Wrong credentials must be refused BY THE PROXY. Only curl's CURLE_PROXY (97)
# proves that; any other status means the attempt failed for an unrelated
# reason and the security property is unproven, which is not a pass.
s5_selftest_bad() {
    # An unusable generator makes this probe unusable too: an empty username or
    # password is refused by the proxy for a reason that has nothing to do with
    # the credential being wrong, and this function's whole job is to prove the
    # rejection happened for the right reason.
    _strnd=$(s5_random_string 6 "$S5_USER_CHARSET") || return 1
    _stu="s5probe$_strnd"
    _stp=$(s5_random_password) || return 1
    s5_curl_config "$_stu" "$_stp" | curl --config - >/dev/null 2>&1
    _strc=$?
    if [ "$_strc" -eq 0 ]; then
        s5_err "SECURITY: the proxy accepted credentials that should have been refused"
        return 1
    fi
    if [ "$_strc" -ne "$S5_CURL_PROXY_ERR" ]; then
        s5_err "inconclusive: the bad-credential probe failed with curl status $_strc, not $S5_CURL_PROXY_ERR (proxy handshake error)"
        s5_err "the proxy's rejection of invalid credentials could not be proven; refusing to continue"
        return 1
    fi
    return 0
}

s5_direct_egress_ok() {
    curl -sS -o /dev/null --max-time 15 "$S5_SELFTEST_URL" >/dev/null 2>&1
}

s5_dns_ok() {
    if command -v getent >/dev/null 2>&1; then
        getent hosts example.com >/dev/null 2>&1
        return $?
    fi
    return 0
}

s5_diagnose_failure() {
    if ! s5_direct_egress_ok; then
        if ! s5_dns_ok; then
            printf 'dns-failure'
            return 0
        fi
        printf 'no-egress'
        return 0
    fi
    printf 'proxy-failure'
    return 0
}

s5_explain_failure() {
    case "$1" in
    dns-failure) s5_say "  Cause: this server cannot resolve DNS names." ;;
    no-egress) s5_say "  Cause: this server has no outbound network access." ;;
    proxy-failure)
        s5_say "  Cause: outbound network works, so the proxy itself refused the request."
        s5_say "  If clients also cannot reach the port, check your cloud security group."
        ;;
    *) s5_say "  Cause: undetermined." ;;
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
        if ! s5_state_mark created_unit; then return 1; fi
        if ! printf '%s\n' "$_sut" | s5_atomic_write "$S5_UNIT" "root:root" 0644; then
            return 1
        fi
        if ! systemctl daemon-reload >/dev/null 2>&1; then
            s5_err "could not reload the systemd manager after writing $S5_UNIT"
            return 1
        fi
        if ! systemctl enable "$S5_PROJECT.service" >/dev/null 2>&1; then
            s5_err "could not enable $S5_PROJECT.service"
            return 1
        fi
        ;;
    openrc)
        if ! s5_mkdir_secure "$S5_INITDIR" "root:root" 0755; then
            return 1
        fi
        _sot=$(s5_render_openrc) || return 1
        if ! s5_state_mark created_initscript; then return 1; fi
        if ! printf '%s\n' "$_sot" | s5_atomic_write "$S5_INITSCRIPT" "root:root" 0755; then
            return 1
        fi
        if ! rc-update add "$S5_PROJECT" default >/dev/null 2>&1; then
            s5_err "could not add $S5_PROJECT to the default runlevel"
            return 1
        fi
        ;;
    *)
        s5_err "unsupported init system: ${S5_INIT:-unknown}"
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
# the daemon is in fact on its way up (observed in the first real CI run;
# newer OpenRC completes the same install). The exit code answers for the
# COMMAND; only the manager's status answers for the SERVICE. So a nonzero
# exit is re-classified through the tri-state s5_service_active:
#   active (0)        -> the service really is starting/started: success,
#                        and s5_wait_listening covers the not-yet-bound
#                        socket, exactly as for a zero exit.
#   inactive (1)      -> genuinely failed: report the original nonzero.
#   unobservable (2)  -> fail closed, reporting the original nonzero.
# No sleep is needed: the re-query is a classification, not a wait, and the
# bounded port wait that follows is already the readiness mechanism.
_s5_openrc_start() {
    rc-service "$S5_PROJECT" "$1"
    _oos=$?
    if [ "$_oos" -eq 0 ]; then
        return 0
    fi
    s5_service_active
    _ooa=$?
    case "$_ooa" in
    0) return 0 ;;
    1) return "$_oos" ;;
    *) return "$_oos" ;;
    esac
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
            s5_err "could not disable $S5_PROJECT.service"
            return 1
        fi
        ;;
    openrc)
        if ! rc-update del "$S5_PROJECT" default >/dev/null 2>&1; then
            s5_err "could not remove $S5_PROJECT from the default runlevel"
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
        case "$_sar" in
        0) return 0 ;;
        1 | 3) return 1 ;;
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
    s5_port_free "$S5_PORT"
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
            s5_err "cannot verify that port $_wlport is listening (neither ss nor netstat found)"
            return 1
            ;;
        esac
        s5_service_active
        _wla=$?
        if [ "$_wla" -eq 1 ]; then
            s5_err "the service exited before port $_wlport was listening"
            return 1
        fi
        _wltry=$((_wltry + 1))
        if [ "$_wltry" -ge 15 ]; then
            break
        fi
        sleep 1
    done
    s5_err "the service did not begin listening on port $_wlport within 15 seconds"
    return 1
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
            s5_err "$_ccp already exists and was not created by this script"
            _ccbad=1
        fi
    done
    s5_account_exists
    _ccar=$?
    case "$_ccar" in
    0)
        s5_err "the $S5_SERVICE_USER account already exists and was not created by this script"
        _ccbad=1
        ;;
    1) ;;
    *)
        s5_err "could not determine whether the $S5_SERVICE_USER account already exists"
        _ccbad=1
        ;;
    esac
    s5_group_exists
    _ccgr=$?
    case "$_ccgr" in
    0)
        s5_err "the $S5_SERVICE_GROUP group already exists and was not created by this script"
        _ccbad=1
        ;;
    1) ;;
    *)
        s5_err "could not determine whether the $S5_SERVICE_GROUP group already exists"
        _ccbad=1
        ;;
    esac
    if [ "$_ccbad" -ne 0 ]; then
        s5_say "Refusing to overwrite resources this script did not create."
        s5_say "Remove or rename them, or $(s5_cmd_hint uninstall), then retry."
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

s5_required_packages() {
    _srpb=$(s5_build_deps "$S5_PKGMGR") || {
        s5_err "no dependency list for package manager: $S5_PKGMGR"
        return 1
    }
    _srpr=$(s5_runtime_deps) || return 1
    if [ -n "$_srpr" ]; then
        printf '%s %s' "$_srpb" "$_srpr"
    else
        printf '%s' "$_srpb"
    fi
}

s5_preinstall_warning() {
    _spwpkgs=$(s5_required_packages) || return 1
    s5_say ""
    s5_say "=============================== PLEASE READ ==============================="
    s5_say "This installs a SOCKS5 proxy that listens on $S5_LISTEN."
    s5_say "Detected target: $S5_OS_ID $S5_OS_VERSION_ID ($S5_PKGMGR, $S5_INIT)."
    s5_say "Packages to install: $_spwpkgs"
    s5_say "These packages are kept after uninstall."
    s5_say ""
    s5_say "  * SOCKS5 username/password authentication (RFC 1929) is sent in CLEARTEXT"
    s5_say "    on the wire. SOCKS5 provides NO transport encryption and NO integrity"
    s5_say "    protection. It is NOT a VPN."
    s5_say "  * You are responsible for your own local firewall and for your cloud"
    s5_say "    provider's security group rules."
    s5_say "  * ANYONE who learns the credentials and can reach the port can use this"
    s5_say "    proxy, and their traffic will appear to originate from this server."
    s5_say ""
    s5_say "Only SOCKS5 with username/password and CONNECT is enabled. SOCKS4, SOCKS4a,"
    s5_say "BIND and UDP ASSOCIATE are not supported."
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
            s5_err "package metadata update failed; refusing to install from stale indexes"
            return 1
        }
        # shellcheck disable=SC2086
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y $_idall; then
            s5_err "package installation failed"
            return 1
        fi
        ;;
    apk)
        # shellcheck disable=SC2086
        if ! apk add --no-cache $_idall; then
            s5_err "package installation failed"
            return 1
        fi
        ;;
    dnf)
        if command -v dnf >/dev/null 2>&1; then
            # shellcheck disable=SC2086
            if ! dnf install -y $_idall; then
                s5_err "package installation failed"
                return 1
            fi
        else
            # shellcheck disable=SC2086
            if ! yum install -y $_idall; then
                s5_err "package installation failed"
                return 1
            fi
        fi
        ;;
    *)
        s5_err "unknown package manager: $S5_PKGMGR"
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

# s5_rm_known_file <flag-key> <path> : remove one fixed project file.
s5_rm_known_file() {
    if ! s5_state_flagged "$1"; then
        return 0
    fi
    if [ ! -e "$2" ] && [ ! -L "$2" ]; then
        return 0
    fi
    if ! rm -f "$2"; then
        s5_err "could not remove $2"
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
        s5_err "keeping $_rkdir: it is a symbolic link"
        return 1
    fi
    _rkextra=$(s5_dir_extras "$_rkdir" "$@")
    if [ -n "$_rkextra" ]; then
        s5_err "keeping $_rkdir: it contains files this script did not create:"
        printf '%s\n' "$_rkextra" | while IFS= read -r _rkl; do
            if [ -n "$_rkl" ]; then s5_err "    $_rkl"; fi
        done
        return 1
    fi
    if ! rmdir "$_rkdir"; then
        s5_err "could not remove the directory $_rkdir"
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
    if [ "$_tdhasunit" -eq 1 ]; then
        if [ "$_tdfilepresent" -eq 1 ]; then
            if ! s5_service_stop >/dev/null 2>&1; then
                s5_err "could not stop the proxy service; refusing to remove its resources"
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
            s5_err "the proxy service is still active; refusing to remove its resources"
            _tdbad=1
            ;;
        1) ;;
        *)
            s5_err "could not verify that the proxy service stopped; refusing to remove its resources"
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
            s5_log "removed the $S5_SERVICE_USER service account"
        else
            _tdbad=1
        fi
    fi

    if [ "$S5_INIT" = "systemd" ]; then
        if ! systemctl daemon-reload >/dev/null 2>&1; then
            s5_err "could not reload the systemd manager after removing its unit"
            _tdbad=1
        fi
    fi

    return "$_tdbad"
}

s5_rollback() {
    s5_warn "installation failed; removing the resources created by this run"
    if ! s5_state_load; then
        s5_warn "no usable state file; nothing could be rolled back automatically"
        return 1
    fi
    if ! s5_teardown; then
        s5_err "rollback was incomplete; the state file is kept at $S5_STATE so you can retry"
        s5_err "$(s5_cmd_hint uninstall) once the problem above is resolved"
        return 1
    fi
    _rbstbuf=$S5_STATE_BUF
    _rbextra=$(s5_dir_extras "$S5_STATEDIR" state)
    if [ -n "$_rbextra" ]; then
        s5_err "rollback cannot remove $S5_STATEDIR: it contains files this script did not create"
        printf '%s\n' "$_rbextra" | while IFS= read -r _rbl; do
            [ -n "$_rbl" ] && s5_err "    $_rbl"
        done
        return 1
    fi
    if ! rm -f "$S5_STATE"; then
        s5_err "rollback could not remove the state file $S5_STATE"
        return 1
    fi
    if rmdir "$S5_STATEDIR" 2>/dev/null; then
        s5_log "rollback complete; no packages were removed"
        return 0
    fi
    # Keep retry state if the final directory removal was ambiguous or failed.
    S5_STATE_BUF=$_rbstbuf
    if ! s5_state_flush; then
        s5_err "rollback could not restore its state file after removing it"
        return 1
    fi
    s5_err "rollback could not remove the state directory; the state file is kept at $S5_STATE"
    return 1
}

s5_server_ip() {
    if command -v ip >/dev/null 2>&1; then
        _sip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1)
        if [ -n "$_sip" ]; then
            printf '%s' "$_sip"
            return 0
        fi
    fi
    if command -v hostname >/dev/null 2>&1; then
        _sip=$(hostname -I 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {print $i; exit}}')
        if [ -n "$_sip" ]; then
            printf '%s' "$_sip"
            return 0
        fi
    fi
    printf '<server-ip>'
}

# Secret-bearing operator output is permitted only when stdout is the terminal
# being used by the operator. In particular, a pipe or redirected file must
# never receive a plaintext password.
s5_require_secret_terminal() {
    if [ ! -t 1 ]; then
        s5_err "refusing to display the proxy password: stdout is not a terminal"
        return 1
    fi
    return 0
}

# Printed to the terminal only. s5_say bypasses the log sink deliberately:
# the credential must reach the operator's screen and nothing else.
s5_print_summary() {
    if ! s5_require_secret_terminal; then
        s5_say "Installation completed; credentials were not displayed because stdout is not a terminal."
        return 0
    fi
    _psfw="not modified by this script"
    s5_say ""
    s5_say "================= SOCKS5 proxy is ready ================="
    s5_say "  Server address : $(s5_server_ip)"
    s5_say "  Port           : $S5_PORT"
    s5_say "  Username       : $S5_USERNAME"
    s5_say "  Password       : $S5_PASSWORD"
    s5_say ""
    s5_say "  socks5://$S5_USERNAME:$S5_PASSWORD@$(s5_server_ip):$S5_PORT"
    s5_say ""
    s5_say "  Local firewall : $_psfw"
    s5_say "  Cloud provider : you must ALSO allow inbound TCP $S5_PORT in your"
    s5_say "                   cloud security group / network ACL."
    s5_say ""
    s5_say "  WARNING: SOCKS5 authentication and traffic are NOT encrypted."
    s5_say "           SOCKS5 is not a VPN. Anyone with these credentials who can"
    s5_say "           reach the port can use this proxy."
    s5_say ""
    s5_redisplay_hint
    s5_say "========================================================"
    s5_say ""
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

# Resources are RECORDED BEFORE they are created. If a state write fails the
# install aborts, and rollback still knows about anything that may already have
# been made; the teardown helpers treat a flagged-but-absent resource as
# already gone. Recording afterwards would orphan a resource whenever the state
# write itself failed.
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
        s5_err "the $S5_SERVICE_USER account appeared after the collision check; refusing to adopt it"
        return 1
        ;;
    1) ;;
    *)
        s5_err "could not determine whether the service account exists"
        return 1
        ;;
    esac
    s5_group_exists
    _isgrp=$?
    case "$_isgrp" in
    0)
        s5_err "the $S5_SERVICE_GROUP group appeared after the collision check; refusing to adopt it"
        return 1
        ;;
    1) ;;
    *)
        s5_err "could not determine whether the service group exists"
        return 1
        ;;
    esac

    if ! s5_state_mark created_account; then return 1; fi
    if ! s5_state_mark created_group; then return 1; fi
    if ! s5_account_create; then
        return 1
    fi
    # Record the numeric identity of what was just created. Removal verifies
    # against these fingerprints: the fixed names can later be removed and
    # recreated by an unrelated workload, and a name-only match would delete
    # the replacement.
    _isauid=$(s5_current_uid)
    _isauis=$?
    if [ "$_isauis" -ne 0 ]; then
        s5_err "could not determine the uid assigned to the new account"
        return 1
    fi
    _isagid=$(s5_current_gid)
    _isagis=$?
    if [ "$_isagis" -ne 0 ]; then
        s5_err "could not determine the gid assigned to the new group"
        return 1
    fi
    if ! s5_state_add account_uid "$_isauid"; then return 1; fi
    if ! s5_state_add account_gid "$_isagid"; then return 1; fi

    if ! s5_state_mark created_prefix; then return 1; fi
    if ! s5_state_mark created_bin; then return 1; fi
    if ! s5_build_3proxy; then
        return 1
    fi

    if ! s5_state_mark created_confdir; then return 1; fi
    if ! s5_mkdir_secure "$S5_SYSCONFDIR" "root:$S5_SERVICE_GROUP" 0750; then
        return 1
    fi

    _isu=$(s5_render_users) || return 1
    if ! s5_state_mark created_users; then return 1; fi
    if ! printf '%s\n' "$_isu" | s5_atomic_write "$S5_USERSCFG" "root:$S5_SERVICE_GROUP" 0640; then
        return 1
    fi
    _isu=''

    _isc=$(s5_render_cfg) || return 1
    if ! s5_state_mark created_cfg; then return 1; fi
    if ! printf '%s\n' "$_isc" | s5_atomic_write "$S5_CFG" "root:$S5_SERVICE_GROUP" 0640; then
        return 1
    fi

    # Static check happens BEFORE anything is started.
    if ! s5_static_check_cfg "$S5_CFG"; then
        return 1
    fi

    if ! s5_service_install; then
        return 1
    fi

    s5_log "starting $S5_PROJECT"
    if ! s5_service_start; then
        s5_err "the service failed to start"
        return 1
    fi
    # Three-valued, like every other service-state observation: a failed manager
    # query is not an observed inactive service. Both cases fail closed, but the
    # operator is told which one actually happened.
    s5_service_active
    _isact=$?
    case "$_isact" in
    0) ;;
    1)
        s5_err "the service is not active after start"
        return 1
        ;;
    *)
        s5_err "could not verify that the service is active after start"
        return 1
        ;;
    esac
    # The listen check is a bounded wait, not a single probe: a manager may
    # report the service active before its socket is bound (Type=simple;
    # OpenRC under supervise-daemon), and the one-shot probe that used to be
    # here failed the install on every host slower than the manager's fork.
    # s5_wait_listening is two-valued -- every outcome of the three-valued
    # s5_port_listening it polls gets its own diagnostic -- so negating it
    # cannot read "cannot observe" as a passed verification.
    if ! s5_wait_listening "$S5_PORT"; then
        return 1
    fi

    s5_log "verifying that invalid credentials are refused"
    if ! s5_selftest_bad; then
        return 1
    fi
    s5_log "verifying that valid credentials work"
    if ! s5_selftest_good "$S5_USERNAME" "$S5_PASSWORD"; then
        _isd=$(s5_diagnose_failure)
        s5_err "the self-test with valid credentials failed ($_isd)"
        s5_explain_failure "$_isd"
        return 1
    fi

    return 0
}

s5_cmd_install() {
    # Every gate first: base commands, OS, arch, root, package manager.
    # The status is captured before any negation: `if ! cmd; then return $?`
    # would return 0, because $? is the status of the *negation*.
    s5_precheck
    _cipc=$?
    if [ "$_cipc" -ne 0 ]; then
        return "$_cipc"
    fi
    if s5_is_installed; then
        s5_log "$S5_PROJECT is already installed; nothing to do"
        s5_cmd_status
        return 0
    fi
    if ! s5_collision_check; then
        return "$EX_FAIL"
    fi

    s5_preinstall_warning
    if ! s5_confirm "Continue with the installation?"; then
        s5_log "installation aborted at the operator's request"
        return "$EX_FAIL"
    fi

    # Install prerequisites before asking for a port. Port selection must be
    # observable on a clean host, and no secret is collected before packages
    # have been installed and accepted.
    if ! s5_install_dependencies; then return "$EX_FAIL"; fi
    if ! s5_prompt_port; then return "$EX_FAIL"; fi
    if ! s5_prompt_username; then return "$EX_FAIL"; fi
    if ! s5_prompt_password; then return "$EX_FAIL"; fi

    if ! s5_state_begin; then
        return "$EX_FAIL"
    fi
    S5_ROLLBACK_ARMED=1

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

# s5_load_credentials : read the single "user:CL:password" line back from disk
# and re-validate it, so a hand-edited or corrupted users.cfg is rejected
# instead of being echoed into a malformed URI.
s5_load_credentials() {
    if [ ! -f "$S5_USERSCFG" ] || [ -L "$S5_USERSCFG" ]; then
        return 1
    fi
    if [ "$(grep -c '' "$S5_USERSCFG")" -ne 1 ]; then
        s5_err "$S5_USERSCFG must contain exactly one credential line"
        return 1
    fi
    _lcline=$(head -n 1 "$S5_USERSCFG")
    case "$_lcline" in
    *:CL:*) ;;
    *)
        s5_err "$S5_USERSCFG is not in the expected user:CL:password form"
        return 1
        ;;
    esac
    _lcu=${_lcline%%:CL:*}
    _lcp=${_lcline#*:CL:}
    if ! s5_valid_username "$_lcu"; then
        s5_err "the username in $S5_USERSCFG is not valid; refusing to display it"
        return 1
    fi
    if ! s5_valid_password "$_lcp"; then
        s5_err "the password in $S5_USERSCFG is not valid; refusing to display it"
        return 1
    fi
    S5_USERNAME=$_lcu
    S5_PASSWORD=$_lcp
    return 0
}

# ---------------------------------------------------------------------------
# Usage and dispatch
# ---------------------------------------------------------------------------

s5_usage() {
    cat <<EOF
Usage: ${S5_SELF:-socks5.sh} [command]

Commands:
  install      Interactively install the SOCKS5 proxy
  status       Show service, port and version information
  show         Re-display the full connection details (root only)
  restart      Restart the proxy service
  uninstall    Remove everything this script created

With no command: installs if absent, otherwise shows a management menu.

Protocol support: SOCKS5 only, with RFC 1929 username/password authentication
and CONNECT only. SOCKS4/4a/4.5, unauthenticated SOCKS5, BIND and UDP ASSOCIATE
are rejected. SOCKS5 is not an encrypted VPN.
EOF
}

s5_cmd_status() {
    if ! s5_is_installed; then
        s5_say "$S5_PROJECT is not installed."
        return "$EX_FAIL"
    fi
    S5_INIT=$(s5_state_get init)
    S5_OS_FAMILY=$(s5_state_get family)
    _stport=$(s5_state_get port)
    S5_PORT=$_stport
    s5_service_active
    _stsr=$?
    case "$_stsr" in
    0) _stsvc=running ;;
    1) _stsvc="not running" ;;
    *) _stsvc="state not verified" ;;
    esac
    s5_port_listening
    _stlp=$?
    if [ "$_stlp" -eq 0 ]; then
        _stlisten="listening on $(s5_state_get listen):$_stport"
    elif [ "$_stlp" -eq 1 ]; then
        _stlisten="NOT listening on port $_stport"
    else
        # Being unable to look is not evidence either way, so claim neither.
        _stlisten="$_stport (listen state not verified: neither ss nor netstat found)"
    fi
    s5_say "$S5_PROJECT status"
    s5_say "  service   : $_stsvc ($S5_INIT)"
    s5_say "  port      : $_stlisten"
    s5_say "  username  : $(s5_state_get username)"
    s5_say "  engine    : 3proxy $(s5_state_get tag) (commit $(s5_state_get commit))"
    s5_say "  origin    : $(s5_state_get origin)"
    s5_say "  binary    : $S5_BIN"
    s5_say "  firewall  : not modified by this script"
    return "$EX_OK"
}

s5_cmd_show() {
    if ! s5_is_installed; then
        s5_say "$S5_PROJECT is not installed."
        return "$EX_FAIL"
    fi
    if ! s5_is_root; then
        s5_err "'show' displays the proxy password and therefore requires root"
        return "$EX_FAIL"
    fi
    if ! s5_require_secret_terminal; then
        return "$EX_FAIL"
    fi
    if ! s5_load_credentials; then
        s5_err "cannot read valid credentials from $S5_USERSCFG"
        return "$EX_FAIL"
    fi
    S5_PORT=$(s5_state_get port)
    _shfw="not modified by this script"
    s5_say ""
    s5_say "================= SOCKS5 connection details ================="
    s5_say "  Server address : $(s5_server_ip)"
    s5_say "  Port           : $S5_PORT"
    s5_say "  Username       : $S5_USERNAME"
    s5_say "  Password       : $S5_PASSWORD"
    s5_say ""
    s5_say "  socks5://$S5_USERNAME:$S5_PASSWORD@$(s5_server_ip):$S5_PORT"
    s5_say ""
    s5_say "  Local firewall : $_shfw"
    s5_say "  Remember to allow inbound TCP $S5_PORT in your cloud security group."
    s5_say ""
    s5_say "  WARNING: SOCKS5 authentication and traffic are NOT encrypted."
    s5_say "           SOCKS5 is not a VPN."
    s5_say "============================================================"
    s5_say ""
    return "$EX_OK"
}

s5_cmd_restart() {
    if ! s5_is_installed; then
        s5_say "$S5_PROJECT is not installed."
        return "$EX_FAIL"
    fi
    if ! s5_is_root; then
        s5_err "restarting the service requires root"
        return "$EX_FAIL"
    fi
    S5_INIT=$(s5_state_get init)
    S5_PORT=$(s5_state_get port)
    if ! s5_service_restart; then
        s5_err "the service failed to restart"
        return "$EX_FAIL"
    fi
    s5_service_active
    _rstar=$?
    case "$_rstar" in
    0) ;;
    1) s5_err "the service is not active after restart"; return "$EX_FAIL" ;;
    *) s5_err "could not verify that the service is active after restart"; return "$EX_FAIL" ;;
    esac
    # The manager's "active" precedes the socket (Type=simple; OpenRC under
    # supervise-daemon), so success is reported only once the port is
    # listening again. Without the wait, restart claimed success while
    # nothing was accepting connections.
    if ! s5_wait_listening "$S5_PORT"; then
        return "$EX_FAIL"
    fi
    s5_log "$S5_PROJECT restarted"
    return "$EX_OK"
}

# Removes only the fixed project resources whose creation this run recorded.
# No system package is ever removed. Nothing is deleted recursively.
s5_cmd_uninstall() {
    if [ ! -e "$S5_STATE" ] && [ ! -L "$S5_STATE" ]; then
        s5_say "$S5_PROJECT is not installed by this script; nothing to remove."
        return "$EX_OK"
    fi
    if ! s5_is_root; then
        s5_err "uninstalling requires root privileges"
        return "$EX_FAIL"
    fi
    if ! s5_state_load; then
        s5_err "the state file could not be validated; refusing to delete anything"
        s5_err "inspect $S5_STATE by hand, then remove the project's resources yourself"
        return "$EX_FAIL"
    fi

    S5_INIT=$(s5_state_get init)
    S5_OS_FAMILY=$(s5_state_get family)

    s5_say "This will remove only the fixed resources this script recorded creating:"
    if s5_state_flagged created_cfg; then s5_say "  file      : $S5_CFG"; fi
    if s5_state_flagged created_users; then s5_say "  file      : $S5_USERSCFG"; fi
    if s5_state_flagged created_unit; then s5_say "  file      : $S5_UNIT"; fi
    if s5_state_flagged created_initscript; then s5_say "  file      : $S5_INITSCRIPT"; fi
    if s5_state_flagged created_bin; then s5_say "  file      : $S5_BIN"; fi
    if s5_state_flagged created_confdir; then s5_say "  directory : $S5_SYSCONFDIR"; fi
    if s5_state_flagged created_prefix; then s5_say "  directory : $S5_PREFIX"; fi
    if s5_state_flagged created_account; then s5_say "  account   : $S5_SERVICE_USER"; fi
    s5_say "No firewall rule is removed: this script never created one."
    s5_say "Installed packages are NOT removed."
    if ! s5_confirm "Proceed with uninstall?"; then
        s5_log "uninstall aborted at the operator's request"
        return "$EX_FAIL"
    fi

    if ! s5_teardown; then
        s5_err "uninstall did NOT complete; the state file is kept at $S5_STATE"
        s5_err "resolve the problems listed above, then $(s5_cmd_hint uninstall)"
        return "$EX_FAIL"
    fi

    _unextra=$(s5_dir_extras "$S5_STATEDIR" state)
    if [ -n "$_unextra" ]; then
        s5_err "keeping $S5_STATEDIR: it contains files this script did not create:"
        printf '%s\n' "$_unextra" | while IFS= read -r _unline; do
            [ -n "$_unline" ] && s5_err "    $_unline"
        done
        s5_err "uninstall did NOT complete; the state file is kept at $S5_STATE"
        return "$EX_FAIL"
    fi

    _unstbuf=$S5_STATE_BUF
    if ! rm -f "$S5_STATE"; then
        s5_err "could not remove the state file $S5_STATE"
        return "$EX_FAIL"
    fi
    if rmdir "$S5_STATEDIR" 2>/dev/null; then
        s5_log "uninstall complete; no system packages were removed"
        return "$EX_OK"
    fi
    # The state file is the retry handle. Restore it if the final directory
    # removal fails rather than claiming success and abandoning an unexplained
    # project directory.
    S5_STATE_BUF=$_unstbuf
    if ! s5_state_flush; then
        s5_err "could not restore $S5_STATE after the state directory remained"
        return "$EX_FAIL"
    fi
    s5_err "could not remove the state directory $S5_STATEDIR; state was retained for retry"
    return "$EX_FAIL"
}

s5_cmd_auto() {
    if ! s5_is_installed; then
        s5_cmd_install
        return $?
    fi
    s5_say ""
    s5_say "$S5_PROJECT is installed. Choose an action:"
    s5_say "  1) status     show service, port and version"
    s5_say "  2) show       re-display the full connection details (root only)"
    s5_say "  3) restart    restart the proxy service"
    s5_say "  4) uninstall  remove everything this script created"
    s5_say "  5) quit"
    printf 'Choice [1-5]: ' >&2
    _cha=''
    if ! read -r _cha; then
        s5_err "unexpected end of input"
        return "$EX_FAIL"
    fi
    case "$_cha" in
    1) s5_cmd_status ;;
    2) s5_cmd_show ;;
    3) s5_cmd_restart ;;
    4) s5_cmd_uninstall ;;
    5)
        s5_say "nothing to do"
        return "$EX_OK"
        ;;
    *)
        s5_err "invalid choice: $_cha"
        return "$EX_USAGE"
        ;;
    esac
}

s5_main() {
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
            s5_err "$_cmd takes no arguments: $*"
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
        s5_err "unknown subcommand: $_cmd"
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
