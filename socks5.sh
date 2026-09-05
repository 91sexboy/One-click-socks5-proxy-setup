#!/bin/sh
# xray-only authenticated mixed proxy installer and manager.
# Xray-core supplies the SOCKS5 and HTTP proxy implementations.

umask 077
set +x
set -u

S5_PROJECT=xray-socks5
S5_XRAY_VERSION=v26.3.27
S5_XRAY_COMMIT=d2758a023cd7f4174a5a5fa4ff66e487d4342ba0
S5_XRAY_BASE=https://github.com/XTLS/Xray-core/releases/download/$S5_XRAY_VERSION
S5_ADDR_ENDPOINT=https://icanhazip.com
S5_SERVICE_USER=xray-socks5
S5_SERVICE_GROUP=xray-socks5
S5_LANG=''
# A plain assignment keeps an export attribute inherited from the caller, which
# would put the entered credential into every child environment. The username is
# half the SOCKS5 and HTTP auth pair, so it belongs here with the password.
unset S5_SECRET S5_PASSWORD S5_USERNAME
S5_SECRET=''
S5_PASSWORD=''
S5_USERNAME=''
S5_PORT=''
S5_ARCHNAME=''
S5_OS_ID=''
S5_OS_VERSION_ID=''
S5_OS_FAMILY=''
S5_PKGMGR=''
S5_INIT=''
S5_WORKDIR=''
S5_LOCK_HELD=0
S5_LOCK_TOKEN=''
S5_VERIFY_TEMP=''
S5_CARD_ADDR=''
S5_CARD_KIND=''
S5_CREATED_USER=0
S5_CREATED_GROUP=0
S5_CREATED_USER_NAMED=0
S5_CREATED_GROUP_NAMED=0
S5_CREATED_PREFIX=0
S5_CREATED_CONFDIR=0
S5_CREATED_STATEDIR=0
S5_CREATED_BIN=0
S5_CREATED_CFG=0
S5_CREATED_UNIT=0
S5_UNIT_ENABLED=0
S5_SERVICE_STARTED=0
S5_INSTALL_COMPLETE=0
S5_IN_CLEANUP=0
S5_CONFIG_SHA256=''
S5_BINARY_SHA256=''
S5_UNIT_SHA256=''
S5_ACCOUNT_UID=''
S5_ACCOUNT_GID=''
S5_ASSET_NAME=''
S5_ASSET_SIZE=''
S5_ASSET_SHA256=''
S5_ASSET_BINARY_SIZE=''
S5_ASSET_BINARY_SHA256=''

s5_guard_environment() {
    if [ "${S5_TEST_MODE:-0}" = 1 ]; then
        [ -n "${S5_TEST_ROOT:-}" ] || {
            printf '%s\n' 'refusing test mode without S5_TEST_ROOT' >&2
            return 1
        }
        [ -f "$S5_TEST_ROOT/.s5-test-root" ] || {
            printf '%s\n' 'refusing test mode without the test-root sentinel' >&2
            return 1
        }
        return 0
    fi
    _sgef=''
    # S5_LIB_ONLY makes the script define its functions and skip s5_main, so an
    # outside caller exporting it turned every command into a silent no-op that
    # still exited 0: install reported success and installed nothing.
    [ -n "${S5_LIB_ONLY:-}" ] && _sgef="$_sgef S5_LIB_ONLY"
    [ -n "${S5_TEST_ROOT:-}" ] && _sgef="$_sgef S5_TEST_ROOT"
    [ -n "${S5_ASSUME_ROOT:-}" ] && _sgef="$_sgef S5_ASSUME_ROOT"
    [ -n "${S5_SKIP_OWNERSHIP:-}" ] && _sgef="$_sgef S5_SKIP_OWNERSHIP"
    [ -n "${S5_PORT_PROBE:-}" ] && _sgef="$_sgef S5_PORT_PROBE"
    [ -n "${S5_LISTENER_PROBE:-}" ] && _sgef="$_sgef S5_LISTENER_PROBE"
    [ -n "${S5_TEST_ASSET_PATH:-}" ] && _sgef="$_sgef S5_TEST_ASSET_PATH"
    [ -n "${S5_TEST_ADDR_PATH:-}" ] && _sgef="$_sgef S5_TEST_ADDR_PATH"
    [ -n "${S5_OSRELEASE:-}" ] && _sgef="$_sgef S5_OSRELEASE"
    [ -n "${S5_LISTEN+x}" ] && _sgef="$_sgef S5_LISTEN"
    if [ -n "$_sgef" ]; then
        printf '%s: refusing test-mode variable(s) outside test mode:%s\n' "$0" "$_sgef" >&2
        printf '%s: 拒绝在测试模式之外使用测试变量：%s\n' "$0" "$_sgef" >&2
        return 1
    fi
    return 0
}

s5_guard_environment || exit 2
if [ "${S5_TEST_MODE:-0}" = 1 ]; then
    S5_ROOTDIR=${S5_TEST_ROOT:?S5_TEST_ROOT is required in test mode}
    S5_LISTEN=${S5_LISTEN:-127.0.0.1}
else
    S5_ROOTDIR=''
    S5_LISTEN=0.0.0.0
fi
S5_PREFIX=$S5_ROOTDIR/usr/local/libexec/$S5_PROJECT
S5_SYSCONFDIR=$S5_ROOTDIR/etc/$S5_PROJECT
S5_STATEDIR=$S5_ROOTDIR/var/lib/$S5_PROJECT
S5_UNITDIR=$S5_ROOTDIR/etc/systemd/system
S5_BIN=$S5_PREFIX/xray
S5_CFG=$S5_SYSCONFDIR/config.json
S5_STATE=$S5_STATEDIR/state
S5_UNIT=$S5_UNITDIR/$S5_PROJECT.service
S5_INITSCRIPTDIR=$S5_ROOTDIR/etc/init.d
S5_INITSCRIPT=$S5_INITSCRIPTDIR/$S5_PROJECT
S5_SERVICE_ARTIFACT=$S5_UNIT
S5_LOCKDIR=$S5_ROOTDIR/run/$S5_PROJECT.lock
S5_LOCK_OWNER=$S5_LOCKDIR/owner
S5_TXNDIR=$S5_STATEDIR/transaction
S5_PIDFILE=$S5_ROOTDIR/run/$S5_PROJECT.pid
S5_OPENRC_OPTION_DIR=$S5_ROOTDIR/run/openrc/options/$S5_PROJECT

s5_redact() {
    if [ -z "${S5_SECRET:-}" ]; then
        printf '%s' "$1"
        return 0
    fi
    { printf '%s\n' "$S5_SECRET"; printf '%s\n' "$1"; } | awk '
        NR == 1 { s=$0; n=length(s); next }
        { line=$0; out=""; while (n > 0) { i=index(line,s); if (i == 0) break; out=out substr(line,1,i-1) "***REDACTED***"; line=substr(line,i+n) } printf "%s%s\n", out, line }
    '
}

s5_say() { printf '%s\n' "$1"; }
s5_log() { printf '[*] %s\n' "$(s5_redact "$1")"; }
s5_warn() { printf '[!] %s\n' "$(s5_redact "$1")" >&2; }
s5_err() { printf '[x] %s\n' "$(s5_redact "$1")" >&2; }

s5_msg() {
    _smk=$1
    shift
    # Every key except the two lang.* ones renders through `case "$S5_LANG"`, so
    # an unset or unknown language would yield the empty string with status 0 and
    # silence whatever the caller was reporting. The lang.* pair is bilingual by
    # construction because they are the only messages issued before a language is
    # chosen.
    case "$_smk" in
    lang.prompt | lang.invalid) ;;
    *) case "$S5_LANG" in zh | en) ;; *) return 1 ;; esac ;;
    esac
    case "$_smk" in
    lang.prompt) printf '%s\n' '请选择语言 / Choose language:' '  1) 中文' '  2) English' ;;
    lang.invalid) [ "$#" -eq 0 ] || return 1; printf '语言无效，请输入 1 或 2 / invalid language; enter 1 or 2.' ;;
    root.required) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '安装和管理需要 root 权限。' ;; en) printf 'installation and management require root privileges.' ;; esac ;;
    detect.unsupported) [ "$#" -eq 3 ] || return 1; case "$S5_LANG" in zh) printf '不支持的系统：ID=%s VERSION_ID=%s ARCH=%s。' "$1" "$2" "$3" ;; en) printf 'unsupported system: ID=%s VERSION_ID=%s ARCH=%s.' "$1" "$2" "$3" ;; esac ;;
    detect.commands) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '缺少必要命令：%s。' "$1" ;; en) printf 'required command(s) are missing: %s.' "$1" ;; esac ;;
    detect.init) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '需要可用的 systemd。' ;; en) printf 'a working systemd is required.' ;; esac ;;
    detect.probe) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '无法确认端口 %s 是否空闲。' "$1" ;; en) printf 'could not determine whether port %s is free.' "$1" ;; esac ;;
    input.port) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '端口 [回车 = 随机 20000-60000]：' ;; en) printf 'Port [Enter = random 20000-60000]: ' ;; esac ;;
    input.port.invalid) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '端口必须是 1024-65535 的十进制数字。' ;; en) printf 'port must be a decimal number from 1024 to 65535.' ;; esac ;;
    input.port.used) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '端口 %s 已被占用。' "$1" ;; en) printf 'port %s is already in use.' "$1" ;; esac ;;
    input.username) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '账户名 [回车 = 随机]：' ;; en) printf 'Username [Enter = random]: ' ;; esac ;;
    input.username.invalid) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '账户名必须是 3-32 个字母、数字、下划线或短横线。' ;; en) printf 'username must be 3-32 letters, digits, underscores or hyphens.' ;; esac ;;
    input.password) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '密码（输入时可见）[回车 = 随机]：' ;; en) printf 'Password (visible while typed) [Enter = random]: ' ;; esac ;;
    input.password.invalid) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '密码必须是 12-128 个安全字符。' ;; en) printf 'password must be 12-128 safe characters.' ;; esac ;;
    install.start) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '正在安装并验证 Xray mixed 代理……' ;; en) printf 'installing and verifying the Xray mixed proxy...' ;; esac ;;
    install.done) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf 'Xray mixed 代理安装完成。' ;; en) printf 'Xray mixed proxy installation completed.' ;; esac ;;
    install.updated) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '配置已更新，Xray 已重新启动并验证。' ;; en) printf 'configuration updated; Xray restarted and verified.' ;; esac ;;
    install.cancelled) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '操作已取消。' ;; en) printf 'operation cancelled.' ;; esac ;;
    asset.download) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '正在下载并校验 Xray 资产：%s。' "$1" ;; en) printf 'downloading and verifying Xray asset: %s.' "$1" ;; esac ;;
    asset.invalid) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf 'Xray 资产校验失败：%s。' "$1" ;; en) printf 'Xray asset verification failed: %s.' "$1" ;; esac ;;
    config.invalid) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf 'Xray 配置测试失败；旧配置未改变。' ;; en) printf 'Xray configuration test failed; the old configuration was unchanged.' ;; esac ;;
    config.external) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '配置文件已被外部修改；拒绝继续。' ;; en) printf 'the configuration was changed externally; refusing to continue.' ;; esac ;;
    service.start) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf 'Xray 服务启动失败。' ;; en) printf 'the Xray service failed to start.' ;; esac ;;
    service.stop) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '无法确认 Xray 服务已停止。' ;; en) printf 'could not verify that the Xray service stopped.' ;; esac ;;
    service.inactive) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '无法确认 Xray 服务正在运行。' ;; en) printf 'could not verify that the Xray service is running.' ;; esac ;;
    service.listen) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf 'Xray 未在端口 %s 上监听。' "$1" ;; en) printf 'Xray is not listening on port %s.' "$1" ;; esac ;;
    service.ready) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf 'Xray 正在端口 %s 上监听。' "$1" ;; en) printf 'Xray is listening on port %s.' "$1" ;; esac ;;
    service.unverified) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '无法验证端口 %s 的监听状态。' "$1" ;; en) printf 'the listen state of port %s could not be verified.' "$1" ;; esac ;;
    account.exists) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '账户或组 %s 已存在；拒绝采用外部身份。' "$1" ;; en) printf 'account or group %s already exists; refusing to adopt an external identity.' "$1" ;; esac ;;
    account.failed) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '无法创建服务账户：%s。' "$1" ;; en) printf 'could not create the service account: %s.' "$1" ;; esac ;;
    account.identity) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '服务账户身份已改变；拒绝删除。' ;; en) printf 'the service account identity changed; refusing to delete it.' ;; esac ;;
    lock.busy) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '另一个管理操作正在运行。' ;; en) printf 'another management operation is already running.' ;; esac ;;
    state.missing) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '没有已安装的 %s。' "$1" ;; en) printf 'no %s installation was found.' "$1" ;; esac ;;
    state.invalid) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf 'state 文件无效：%s。拒绝删除或覆盖资源。' "$1" ;; en) printf 'invalid state file: %s. Refusing to delete or overwrite resources.' "$1" ;; esac ;;
    status.heading) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf 'Xray mixed 代理状态：' ;; en) printf 'Xray mixed proxy status:' ;; esac ;;
    status.line) [ "$#" -eq 3 ] || return 1; case "$S5_LANG" in zh) printf '服务：%s；端口：%s；账户：%s；协议：mixed（SOCKS5 + HTTP）；认证：password；UDP：关闭' "$1" "$2" "$3" ;; en) printf 'service: %s; port: %s; username: %s; protocol: mixed (SOCKS5 + HTTP); auth: password; UDP: disabled' "$1" "$2" "$3" ;; esac ;;
    status.version) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf 'Xray 版本：%s' "$1" ;; en) printf 'Xray version: %s' "$1" ;; esac ;;
    show.terminal) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf 'show 仅在真实 TTY 中显示凭据。' ;; en) printf 'show displays credentials only on a real TTY.' ;; esac ;;
    show.heading) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '凭据卡（mixed：SOCKS5 + HTTP）：' ;; en) printf 'credential card (mixed: SOCKS5 + HTTP):' ;; esac ;;
    show.placeholder) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '警告：无法确定服务器的公网地址，请把下面的 %s 替换为该服务器的公网 IPv4。' "$1" ;; en) printf "WARNING: the server's public address could not be determined; replace %s below with the server's public IPv4." "$1" ;; esac ;;
    show.socks) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf 'SOCKS5：%s' "$1" ;; en) printf 'SOCKS5: %s' "$1" ;; esac ;;
    show.http) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf 'HTTP：%s' "$1" ;; en) printf 'HTTP: %s' "$1" ;; esac ;;
    show.warning) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '认证信息会在网络上传输，密码以明文保存在受保护的配置文件中。' ;; en) printf 'credentials are sent on the wire, and the password is stored in cleartext in the protected config file.' ;; esac ;;
    uninstall.confirm) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '确认删除 Xray mixed 代理及其账户？[y/N] ' ;; en) printf 'Remove the Xray mixed proxy and its account? [y/N] ' ;; esac ;;
    uninstall.done) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '卸载完成；系统软件包和防火墙规则未修改。' ;; en) printf 'uninstall completed; system packages and firewall rules were not modified.' ;; esac ;;
    install.confirm) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '确认安装 Xray mixed 代理？[Y/n] ' ;; en) printf 'Install the Xray mixed proxy? [Y/n] ' ;; esac ;;
    update.confirm) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '更新现有 Xray 配置？[y/N] ' ;; en) printf 'Update the existing Xray configuration? [y/N] ' ;; esac ;;
    usage) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '用法：sh socks5.sh [install|status|show|restart|uninstall|help]' ;; en) printf 'Usage: sh socks5.sh [install|status|show|restart|uninstall|help]' ;; esac ;;
    extra) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '命令不接受额外参数：%s。' "$1" ;; en) printf 'the command does not accept extra arguments: %s.' "$1" ;; esac ;;
    *) return 1 ;;
    esac
}

# A key that does not resolve -- misspelled, or called with the wrong number of
# arguments -- must not silence its caller. Reporting the key keeps a fatal error
# visible and traceable instead of leaving a bare non-zero exit with no output.
s5_msg_fallback() {
    s5_err "internal: cannot render message '$1' (lang=${S5_LANG:-unset})"
    return 1
}

s5_msg_print() { _smp=$(s5_msg "$@") || { s5_msg_fallback "$1"; return 1; }; s5_say "$_smp"; _smp=''; }
s5_msg_err() { _sme=$(s5_msg "$@") || { s5_msg_fallback "$1"; return 1; }; s5_err "$_sme"; _sme=''; }
s5_msg_warn() { _smw=$(s5_msg "$@") || { s5_msg_fallback "$1"; return 1; }; s5_warn "$_smw"; _smw=''; }

s5_is_root() {
    if [ "${S5_TEST_MODE:-0}" = 1 ] && [ -n "${S5_ASSUME_ROOT:-}" ]; then
        [ "$S5_ASSUME_ROOT" = 1 ]
        return $?
    fi
    [ "$(id -u)" = 0 ]
}

s5_select_language() {
    _sli=0
    while [ "$_sli" -lt 3 ]; do
        _sli=$((_sli + 1))
        s5_msg_print lang.prompt >&2
        _sl=''
        IFS= read -r _sl || return 1
        case "$_sl" in
        '' | 1) S5_LANG=zh ;;
        2) S5_LANG=en ;;
        *) s5_msg_err lang.invalid; continue ;;
        esac
        export S5_LANG
        return 0
    done
    return 1
}

s5_osrel_get() {
    [ -r "$1" ] || return 1
    sed -n "s/^$2=//p" "$1" | tail -n 1 | tr -d '\r' | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

s5_ver_ge() {
    _vga=$1
    _vgb=$2
    while [ -n "$_vga" ] || [ -n "$_vgb" ]; do
        _vca=${_vga%%.*}
        _vcb=${_vgb%%.*}
        [ -n "$_vca" ] || _vca=0
        [ -n "$_vcb" ] || _vcb=0
        case "$_vca:$_vcb" in *[!0-9:]* | *::* | :* | *:) return 2 ;; esac
        _vca=${_vca#"${_vca%%[!0]*}"}
        _vcb=${_vcb#"${_vcb%%[!0]*}"}
        [ -n "$_vca" ] || _vca=0
        [ -n "$_vcb" ] || _vcb=0
        [ "${#_vca}" -le 18 ] && [ "${#_vcb}" -le 18 ] || return 2
        if [ "${#_vca}" -gt "${#_vcb}" ]; then return 0; fi
        if [ "${#_vca}" -lt "${#_vcb}" ]; then return 1; fi
        if [ "$_vca" != "$_vcb" ]; then
            _vgr=$(awk -v a="$_vca" -v b="$_vcb" 'BEGIN { print (a > b) ? 0 : 1 }')
            [ "$_vgr" = 0 ] && return 0
            return 1
        fi
        case "$_vga" in *.*) _vga=${_vga#*.}; [ -n "$_vga" ] || return 2 ;; *) _vga='' ;; esac
        case "$_vgb" in *.*) _vgb=${_vgb#*.}; [ -n "$_vgb" ] || return 2 ;; *) _vgb='' ;; esac
    done
    return 0
}

s5_map_arch() {
    case "$1" in
    x86_64 | amd64) printf 'amd64' ;;
    aarch64 | arm64) printf 'arm64' ;;
    *) return 1 ;;
    esac
}

s5_detect_platform() {
    _sdf=${S5_OSRELEASE:-/etc/os-release}
    S5_OS_ID=$(s5_osrel_get "$_sdf" ID) || return 1
    S5_OS_VERSION_ID=$(s5_osrel_get "$_sdf" VERSION_ID) || return 1
    case "$S5_OS_ID" in
    ubuntu)
        case "$S5_ARCHNAME:$S5_OS_VERSION_ID" in
        amd64:20.04) ;;
        amd64:*) s5_ver_ge "$S5_OS_VERSION_ID" 22.04 || return 1 ;;
        arm64:*) s5_ver_ge "$S5_OS_VERSION_ID" 22.04 || return 1 ;;
        *) return 1 ;;
        esac
        S5_OS_FAMILY=debian
        S5_PKGMGR=apt
        S5_INIT=systemd
        ;;
    debian)
        s5_ver_ge "$S5_OS_VERSION_ID" 12 || return 1
        S5_OS_FAMILY=debian
        S5_PKGMGR=apt
        S5_INIT=systemd
        ;;
    alpine)
        s5_ver_ge "$S5_OS_VERSION_ID" 3.20 || return 1
        S5_OS_FAMILY=alpine
        S5_PKGMGR=apk
        S5_INIT=openrc
        ;;
    centos)
        s5_ver_ge "$S5_OS_VERSION_ID" 9 || return 1
        S5_OS_FAMILY=el
        S5_PKGMGR=dnf
        S5_INIT=systemd
        export S5_PKGMGR
        ;;
    *) return 1 ;;
    esac
    if [ "$S5_INIT" = openrc ]; then
        S5_UNIT=$S5_INITSCRIPT
    else
        S5_UNIT=$S5_UNITDIR/$S5_PROJECT.service
    fi
    return 0
}

s5_require_commands() {
    _srcmiss=''
    for _src in "$@"; do
        command -v "$_src" >/dev/null 2>&1 || _srcmiss="$_srcmiss $_src"
    done
    if [ -n "$_srcmiss" ]; then
        s5_msg_err detect.commands "$_srcmiss"
        return 1
    fi
    return 0
}

s5_valid_port() {
    case "${1:-}" in '' | 0* | *[!0-9]*) return 1 ;; esac
    [ "${#1}" -le 5 ] || return 1
    [ "$1" -ge 1024 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null
}

s5_ipv4_is_canonical() {
    case "${1:-}" in '' | *[!0-9.]*) return 1 ;; esac
    case "$1" in .* | *. | *..*) return 1 ;; esac
    _ivoldifs=$IFS
    IFS=.
    set -f
    # shellcheck disable=SC2086
    set -- $1
    set +f
    IFS=$_ivoldifs
    [ "$#" -eq 4 ] || return 1
    for _iv in "$1" "$2" "$3" "$4"; do
        case "$_iv" in '' | *[!0-9]*) return 1 ;; esac
        [ "${#_iv}" -le 3 ] || return 1
        case "$_iv" in 0 | 0*) [ "$_iv" = 0 ] || return 1 ;; esac
        [ "$_iv" -le 255 ] 2>/dev/null || return 1
    done
    return 0
}

s5_ipv4_is_public() {
    # Conservative: every IANA special-purpose range is refused, so a private,
    # CGNAT, loopback or documentation address is never advertised as an
    # Internet-reachable host.
    s5_ipv4_is_canonical "${1:-}" || return 1
    _ipo1=${1%%.*}
    _ipore=${1#*.}
    _ipo2=${_ipore%%.*}
    _ipore=${_ipore#*.}
    _ipo3=${_ipore%%.*}
    _ipore=''
    [ "$_ipo1" -eq 0 ] && return 1
    [ "$_ipo1" -eq 10 ] && return 1
    [ "$_ipo1" -eq 127 ] && return 1
    [ "$_ipo1" -ge 224 ] && return 1
    case "$_ipo1.$_ipo2" in
    100.6[4-9] | 100.[7-9]? | 100.1[01]? | 100.12[0-7]) return 1 ;;
    169.254) return 1 ;;
    172.1[6-9] | 172.2? | 172.3[01]) return 1 ;;
    192.168) return 1 ;;
    198.18 | 198.19) return 1 ;;
    esac
    case "$_ipo1.$_ipo2.$_ipo3" in
    192.0.0 | 192.0.2 | 192.31.196 | 192.52.193 | 192.88.99 | 192.175.48) return 1 ;;
    198.51.100 | 203.0.113) return 1 ;;
    esac
    return 0
}

s5_valid_username() {
    case "${1:-}" in '' | *[!A-Za-z0-9_-]*) return 1 ;; esac
    [ "${#1}" -ge 3 ] && [ "${#1}" -le 32 ]
}

s5_valid_password() {
    case "${1:-}" in '' | *[!A-Za-z0-9._~-]*) return 1 ;; esac
    [ "${#1}" -ge 12 ] && [ "${#1}" -le 128 ]
}

s5_random_string() {
    _srsn=$1
    _srsset=$2
    [ "$_srsn" -gt 0 ] || return 1
    _srsraw=$(od -An -N512 -tu1 /dev/urandom 2>/dev/null) || return 1
    printf '%s\n' "$_srsraw" | awk -v n="$_srsn" -v set="$_srsset" '
        { for (i=1; i<=NF && length(out)<n; i++) out=out substr(set,($i % length(set))+1,1) }
        END { if (length(out)==n) print out; else exit 1 }
    '
}

s5_random_port() {
    _srp=$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d '[:space:]') || return 1
    case "$_srp" in '' | *[!0-9]*) return 1 ;; esac
    printf '%s' "$((20000 + (_srp % 40001)))"
}

s5_port_free() {
    _spfp=$1
    if [ "${S5_TEST_MODE:-0}" = 1 ] && [ -n "${S5_PORT_PROBE:-}" ]; then
        "$S5_PORT_PROBE" "$_spfp"
        return $?
    fi
    if command -v ss >/dev/null 2>&1; then
        _spfo=$(ss -ltnH 2>/dev/null) || return 2
        printf '%s\n' "$_spfo" | awk -v p="$_spfp" '$1 == "LISTEN" && $4 ~ (":" p "$") { found=1 } END { exit found ? 1 : 0 }'
        _spfr=$?
        case "$_spfr" in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
    fi
    if command -v netstat >/dev/null 2>&1; then
        _spfo=$(netstat -lnt 2>/dev/null) || return 2
        printf '%s\n' "$_spfo" | awk -v p="$_spfp" '$1 ~ /tcp/ && $6 == "LISTEN" && $4 ~ (":" p "$") { found=1 } END { exit found ? 1 : 0 }'
        _spfr=$?
        case "$_spfr" in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
    fi
    return 2
}

s5_port_owned_by_service() {
    # An update keeps the port it already runs on: the live service holds that
    # listener, so the generic in-use probe reports it busy. Ownership is
    # verified rather than assumed, so a foreign or unobservable listener on the
    # recorded port is still refused. On a fresh install S5_PORT is empty and no
    # candidate can match it.
    [ -n "${S5_PORT:-}" ] || return 1
    [ "$1" = "$S5_PORT" ] || return 1
    s5_listener_state
}

s5_prompt_port() {
    while :; do
        s5_msg input.port >&2
        _spp=''
        IFS= read -r _spp || return 1
        [ -n "$_spp" ] || _spp=$(s5_random_port) || return 1
        if ! s5_valid_port "$_spp"; then
            s5_msg_err input.port.invalid
            continue
        fi
        s5_port_free "$_spp"
        _sppr=$?
        case "$_sppr" in
        0) S5_PORT=$_spp; return 0 ;;
        1)
            if s5_port_owned_by_service "$_spp"; then
                S5_PORT=$_spp
                return 0
            fi
            s5_msg_err input.port.used "$_spp"
            ;;
        *) s5_msg_err detect.probe "$_spp"; return 1 ;;
        esac
    done
}

s5_prompt_username() {
    while :; do
        s5_msg input.username >&2
        _spu=''
        IFS= read -r _spu || return 1
        [ -n "$_spu" ] || _spu=$(s5_random_string 12 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-') || return 1
        if s5_valid_username "$_spu"; then
            S5_USERNAME=$_spu
            return 0
        fi
        s5_msg_err input.username.invalid
    done
}

s5_prompt_password() {
    while :; do
        s5_msg input.password >&2
        _sppw=''
        IFS= read -r _sppw || return 1
        [ -n "$_sppw" ] || _sppw=$(s5_random_string 32 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~-') || return 1
        if s5_valid_password "$_sppw"; then
            S5_PASSWORD=$_sppw
            S5_SECRET=$_sppw
            return 0
        fi
        s5_msg_err input.password.invalid
    done
}

s5_asset_select() {
    case "$S5_ARCHNAME" in
    amd64)
        S5_ASSET_NAME=Xray-linux-64.zip
        S5_ASSET_SIZE=21136402
        S5_ASSET_SHA256=23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae
        S5_ASSET_BINARY_SIZE=36577406
        S5_ASSET_BINARY_SHA256=8255dd939c34cf966cc91517b6324dd3c8d0bcf49ffac8beca049a38c46845ed
        ;;
    arm64)
        S5_ASSET_NAME=Xray-linux-arm64-v8a.zip
        S5_ASSET_SIZE=19716427
        S5_ASSET_SHA256=4d30283ae614e3057f730f67cd088a42be6fdf91f8639d82cb69e48cde80413c
        S5_ASSET_BINARY_SIZE=34209918
        S5_ASSET_BINARY_SHA256=c2d20a7045250497083afea0d79db0672f6c89a25aaaf37c92de034d6b764b04
        ;;
    *) return 1 ;;
    esac
}

s5_mkdir_parents() {
    case "$1" in
    '' | /) return 0 ;;
    esac
    if [ -L "$1" ]; then return 1; fi
    if [ -d "$1" ]; then return 0; fi
    if [ -e "$1" ]; then return 1; fi
    _smpp=${1%/*}
    [ "$_smpp" != "$1" ] || _smpp=.
    s5_mkdir_parents "$_smpp" || return 1
    mkdir "$1" || return 1
    chmod 0755 "$1"
}

s5_mkdir_private() {
    if [ -L "$1" ]; then return 1; fi
    _smpp=${1%/*}
    [ "$_smpp" != "$1" ] || _smpp=.
    if [ "$_smpp" != "$1" ]; then
        s5_mkdir_parents "$_smpp" || return 1
    fi
    if [ ! -d "$1" ]; then
        mkdir "$1" || return 1
        chmod 0700 "$1" || return 1
        return 0
    fi
    [ -w "$1" ] || return 1
    case "$1" in
    /run | /var | /etc | /usr | /usr/local) return 0 ;;
    esac
    chmod 0700 "$1"
}

s5_lock_try() {
    mkdir "$S5_LOCKDIR" 2>/dev/null || return 1
    _sltmp=$(mktemp "$S5_LOCKDIR/.owner.XXXXXX") || { rmdir "$S5_LOCKDIR" 2>/dev/null || true; return 1; }
    _slboot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || uname -n)
    _sltoken="$_slboot
$$"
    if ! printf '%s\n' "$_sltoken" >"$_sltmp" || ! chmod 0600 "$_sltmp"; then
        rm -f "$_sltmp" 2>/dev/null || true
        rmdir "$S5_LOCKDIR" 2>/dev/null || true
        return 1
    fi
    if ! ln -T "$_sltmp" "$S5_LOCK_OWNER" 2>/dev/null; then
        rm -f "$_sltmp" 2>/dev/null || true
        rmdir "$S5_LOCKDIR" 2>/dev/null || true
        return 1
    fi
    rm -f "$_sltmp" 2>/dev/null || true
    S5_LOCK_TOKEN=$_sltoken
    S5_LOCK_HELD=1
    return 0
}

# Reclaim a lock whose owner is provably gone: a different boot, or this boot with
# a dead pid. A live pid is never touched, so a genuine concurrent operation still
# wins, and pid reuse can only make this refuse. An owner file that is absent
# entirely is left alone, because that is also the brief window a legitimate
# acquisition passes through between mkdir and the link.
s5_lock_reclaim() {
    [ -f "$S5_LOCK_OWNER" ] || return 1
    _slrowner=$(cat "$S5_LOCK_OWNER" 2>/dev/null) || return 1
    _slrboot=$(printf '%s\n' "$_slrowner" | sed -n '1p')
    _slrpid=$(printf '%s\n' "$_slrowner" | sed -n '2p')
    _slrnow=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || uname -n)
    if [ -n "$_slrboot" ] && [ "$_slrboot" != "$_slrnow" ]; then
        :
    elif [ -n "$_slrpid" ] && ! kill -0 "$_slrpid" 2>/dev/null; then
        :
    else
        return 1
    fi
    rm -f "$S5_LOCK_OWNER" "$S5_LOCKDIR"/.owner.* 2>/dev/null || true
    rmdir "$S5_LOCKDIR" 2>/dev/null || return 1
    return 0
}

s5_lock_acquire() {
    [ "$S5_LOCK_HELD" = 1 ] && return 0
    _slparent=${S5_LOCKDIR%/*}
    s5_mkdir_private "$_slparent" 2>/dev/null || return 1
    s5_lock_try && return 0
    # /run is tmpfs, so nothing else ever clears a lock left by a killed run: an
    # interrupt during status, show, restart or uninstall used to wedge every
    # later command, uninstall included, until the host rebooted.
    if s5_lock_reclaim; then
        s5_lock_try && return 0
    fi
    s5_msg_err lock.busy
    return 1
}

s5_lock_release() {
    [ "$S5_LOCK_HELD" = 1 ] || return 0
    [ -f "$S5_LOCK_OWNER" ] && [ "$(cat "$S5_LOCK_OWNER" 2>/dev/null)" = "$S5_LOCK_TOKEN" ] || return 1
    rm -f "$S5_LOCK_OWNER" "$S5_LOCKDIR"/.owner.* 2>/dev/null || true
    rmdir "$S5_LOCKDIR" || return 1
    S5_LOCK_HELD=0
    S5_LOCK_TOKEN=''
    return 0
}

s5_atomic_write() {
    _sawp=$1
    _sawo=$2
    _sawm=$3
    _sawd=${_sawp%/*}
    [ "$_sawd" != "$_sawp" ] || _sawd=.
    [ -d "$_sawd" ] && [ ! -L "$_sawd" ] || return 1
    _sawt=$(mktemp "$_sawd/.s5tmp.XXXXXX") || return 1
    chmod 0600 "$_sawt" || { rm -f "$_sawt"; return 1; }
    if ! cat >"$_sawt"; then rm -f "$_sawt"; return 1; fi
    if [ "${S5_SKIP_OWNERSHIP:-0}" != 1 ] && ! chown "$_sawo" "$_sawt"; then
        rm -f "$_sawt"
        return 1
    fi
    chmod "$_sawm" "$_sawt" || { rm -f "$_sawt"; return 1; }
    mv -f "$_sawt" "$_sawp" || { rm -f "$_sawt"; return 1; }
    return 0
}

s5_config_render() {
    s5_valid_port "$S5_PORT" && s5_valid_username "$S5_USERNAME" && s5_valid_password "$S5_PASSWORD" || return 1
    s5_ipv4_is_canonical "$S5_LISTEN" || return 1
    printf '%s\n' '{'
    printf '%s\n' '  "log": {"loglevel": "warning", "access": "none", "error": ""},'
    printf '%s\n' '  "inbounds": [{'
    printf '    "listen": "%s",\n' "$S5_LISTEN"
    printf '    "port": %s,\n' "$S5_PORT"
    printf '%s\n' '    "protocol": "mixed",'
    printf '%s\n' '    "settings": {'
    printf '%s\n' '      "auth": "password",'
    printf '%s' '      "accounts": [{"user": "'
    printf '%s' "$S5_USERNAME"
    printf '%s' '", "pass": "'
    printf '%s' "$S5_PASSWORD"
    printf '%s\n' '"}],'
    printf '%s\n' '      "udp": false'
    printf '%s\n' '    },'
    printf '%s\n' '    "tag": "xray-mixed-in"'
    printf '%s\n' '  }],'
    printf '%s\n' '  "outbounds": ['
    printf '%s\n' '    {"protocol": "freedom", "settings": {}, "tag": "direct"},'
    printf '%s\n' '    {"protocol": "blackhole", "settings": {}, "tag": "blocked"}'
    printf '%s\n' '  ],'
    # The destination boundary. An authenticated client must not be able to use
    # the tunnel to reach the proxy host's own loopback, the private and CGNAT
    # ranges behind it, or the link-local range that carries cloud instance
    # metadata at 169.254.169.254. These are blackholed ahead of the direct
    # outbound, which is the default for everything else.
    #
    # Literal CIDRs rather than geoip:private: the installer inspects geoip.dat
    # inside the archive but extracts only the xray executable, so no geoip
    # database is ever on disk and a geoip rule would fail at runtime.
    #
    # IPIfNonMatch is what makes a hostname target subject to these rules. With
    # the default AsIs an "ip" rule can only ever match a literal address, so
    # any name resolving into a denied range would be routed direct.
    printf '%s\n' '  "routing": {'
    printf '%s\n' '    "domainStrategy": "IPIfNonMatch",'
    printf '%s\n' '    "rules": [{'
    printf '%s\n' '      "type": "field",'
    printf '%s\n' '      "outboundTag": "blocked",'
    printf '%s\n' '      "ip": ['
    printf '%s\n' '        "0.0.0.0/8",'
    printf '%s\n' '        "10.0.0.0/8",'
    printf '%s\n' '        "100.64.0.0/10",'
    printf '%s\n' '        "127.0.0.0/8",'
    printf '%s\n' '        "169.254.0.0/16",'
    printf '%s\n' '        "172.16.0.0/12",'
    printf '%s\n' '        "192.168.0.0/16",'
    printf '%s\n' '        "224.0.0.0/4",'
    printf '%s\n' '        "240.0.0.0/4",'
    printf '%s\n' '        "::1/128",'
    printf '%s\n' '        "fc00::/7",'
    printf '%s\n' '        "fe80::/10"'
    printf '%s\n' '      ]'
    printf '%s\n' '    }]'
    printf '%s\n' '  }'
    printf '%s\n' '}'
}

s5_config_test() {
    _sct=''
    if _sct=$("$S5_BIN" run -test -c "$1" 2>&1); then
        _sct=''
        return 0
    fi
    # The engine's own diagnostic is the only thing that says why a candidate was
    # rejected. s5_warn removes the password before it reaches a log or CI output.
    s5_warn "$_sct"
    _sct=''
    return 1
}

s5_config_extract() {
    [ -f "$S5_CFG" ] && [ ! -L "$S5_CFG" ] || return 1
    # The account keys sit inside the accounts array, so they are matched
    # anywhere on their line rather than anchored to its start.
    _sceuser=$(sed -n 's/.*"user":[[:space:]]*"\([A-Za-z0-9_-]*\)".*/\1/p' "$S5_CFG" | head -n 1)
    _scepass=$(sed -n 's/.*"pass":[[:space:]]*"\([A-Za-z0-9._~-]*\)".*/\1/p' "$S5_CFG" | head -n 1)
    [ "$(grep -cF '"protocol": "mixed"' "$S5_CFG")" = 1 ] || return 1
    [ "$(grep -cF '"auth": "password"' "$S5_CFG")" = 1 ] || return 1
    [ "$(grep -cF '"udp": false' "$S5_CFG")" = 1 ] || return 1
    [ "$(grep -cF '"user":' "$S5_CFG")" = 1 ] || return 1
    [ "$(grep -cF '"pass":' "$S5_CFG")" = 1 ] || return 1
    s5_valid_username "$_sceuser" && s5_valid_password "$_scepass" || return 1
    S5_USERNAME=$_sceuser
    S5_PASSWORD=$_scepass
    S5_SECRET=$_scepass
    return 0
}

s5_tmp_base() {
    if [ -d /var/tmp ] && [ ! -L /var/tmp ] && [ -w /var/tmp ]; then
        printf '/var/tmp'
    else
        printf '/tmp'
    fi
}

s5_download_engine() {
    s5_asset_select || return 1
    if [ ! -d "$S5_PREFIX" ]; then S5_CREATED_PREFIX=1; fi
    s5_mkdir_private "$S5_PREFIX" || return 1
    [ -n "$S5_WORKDIR" ] || S5_WORKDIR=$(mktemp -d "$(s5_tmp_base)/xray-socks5-download.XXXXXX") || return 1
    _sdezip=$S5_WORKDIR/$S5_ASSET_NAME
    if [ -n "${S5_TEST_ASSET_PATH:-}" ]; then
        cp "$S5_TEST_ASSET_PATH" "$_sdezip" || return 1
    else
        s5_msg_print asset.download "$S5_ASSET_NAME" >&2
        # curl enforces the hard upper bound while streaming; the exact byte
        # count below remains the independent acceptance check.
        curl -fsSL --proto '=https' --proto-redir '=https' \
            --max-time 120 --max-filesize "$((S5_ASSET_SIZE + 1))" \
            -o "$_sdezip" "$S5_XRAY_BASE/$S5_ASSET_NAME" || {
            s5_msg_err asset.invalid download
            return 1
        }
        [ "$(wc -c <"$_sdezip" | tr -d '[:space:]')" -le "$((S5_ASSET_SIZE + 1))" ] || {
            s5_msg_err asset.invalid size
            return 1
        }
    fi
    [ "$(wc -c <"$_sdezip" | tr -d '[:space:]')" = "$S5_ASSET_SIZE" ] || { s5_msg_err asset.invalid size; return 1; }
    [ "$(sha256sum "$_sdezip" | awk '{print $1}')" = "$S5_ASSET_SHA256" ] || { s5_msg_err asset.invalid sha256; return 1; }
    _sdem=$S5_WORKDIR/members
    unzip -Z1 "$_sdezip" >"$_sdem" 2>/dev/null || { s5_msg_err asset.invalid members; return 1; }
    [ "$(grep -cxF xray "$_sdem" || true)" = 1 ] || { s5_msg_err asset.invalid members; return 1; }
    for _sden in geoip.dat geosite.dat LICENSE README.md; do
        [ "$(grep -cxF "$_sden" "$_sdem" || true)" = 1 ] || { s5_msg_err asset.invalid members; return 1; }
    done
    [ "$(wc -l <"$_sdem" | tr -d '[:space:]')" = 5 ] || { s5_msg_err asset.invalid members; return 1; }
    while IFS= read -r _sden; do
        case "$_sden" in '' | */* | *..* | *\\*) s5_msg_err asset.invalid members; return 1 ;; esac
    done <"$_sdem"
    if ! unzip -Z -v "$_sdezip" 2>/dev/null |
        awk '/Unix file attributes/ { seen++; if ($4 !~ /^\(10[0-7]/) bad=1 }
             END { exit (seen == 5 && !bad) ? 0 : 1 }'; then
        s5_msg_err asset.invalid members
        return 1
    fi
    _sdev=$S5_WORKDIR/xray
    unzip -p "$_sdezip" xray >"$_sdev" 2>/dev/null || return 1
    [ "$(wc -c <"$_sdev" | tr -d '[:space:]')" = "$S5_ASSET_BINARY_SIZE" ] || { s5_msg_err asset.invalid binary-size; return 1; }
    [ "$(sha256sum "$_sdev" | awk '{print $1}')" = "$S5_ASSET_BINARY_SHA256" ] || { s5_msg_err asset.invalid binary-sha256; return 1; }
    chmod 0755 "$_sdev" || return 1
    _sdef=$(file -b "$_sdev" 2>/dev/null) || return 1
    case "$S5_ARCHNAME:$_sdef" in
    amd64:*'ELF 64-bit LSB executable, x86-64'*) ;;
    arm64:*'ELF 64-bit LSB executable, ARM aarch64'*) ;;
    *) s5_msg_err asset.invalid architecture; return 1 ;;
    esac
    _sdet=$(mktemp "$S5_PREFIX/.xray.XXXXXX") || return 1
    chmod 0755 "$_sdet" || { rm -f "$_sdet"; return 1; }
    cat "$_sdev" >"$_sdet" || { rm -f "$_sdet"; return 1; }
    mv -f "$_sdet" "$S5_BIN" || { rm -f "$_sdet"; return 1; }
    S5_CREATED_BIN=1
    S5_BINARY_SHA256=$(sha256sum "$S5_BIN" | awk '{print $1}')
    [ "$S5_BINARY_SHA256" = "$S5_ASSET_BINARY_SHA256" ]
}

s5_binary_ready() {
    [ -x "$S5_BIN" ] && [ ! -L "$S5_BIN" ] || return 1
    [ "$(sha256sum "$S5_BIN" 2>/dev/null | awk '{print $1}')" = "$S5_ASSET_BINARY_SHA256" ]
}

s5_getent_state() {
    _sges_kind=$1
    _sges_name=$2
    getent "$_sges_kind" "$_sges_name" >/dev/null 2>&1
    case $? in
    0) return 0 ;;
    2) return 1 ;;
    *) return 2 ;;
    esac
}

s5_nologin_path() {
    case "$S5_OS_FAMILY" in alpine) printf '/sbin/nologin' ;; *) printf '/usr/sbin/nologin' ;; esac
}

s5_account_create() {
    _s5nologin=$(s5_nologin_path)
    s5_getent_state passwd "$S5_SERVICE_USER"
    case $? in
    0) s5_msg_err account.exists "$S5_SERVICE_USER"; return 1 ;;
    1) ;;
    *) s5_msg_err account.identity; return 1 ;;
    esac
    s5_getent_state group "$S5_SERVICE_GROUP"
    case $? in
    0) s5_msg_err account.exists "$S5_SERVICE_GROUP"; return 1 ;;
    1) ;;
    *) s5_msg_err account.identity; return 1 ;;
    esac
    if [ "$S5_OS_FAMILY" = alpine ]; then
        addgroup -S "$S5_SERVICE_GROUP" >/dev/null 2>&1 || { s5_msg_err account.failed "$S5_SERVICE_GROUP"; return 1; }
        S5_CREATED_GROUP=1
        S5_CREATED_GROUP_NAMED=1
        adduser -S -D -H -h /nonexistent -G "$S5_SERVICE_GROUP" -s "$_s5nologin" "$S5_SERVICE_USER" >/dev/null 2>&1 || {
            s5_msg_err account.failed "$S5_SERVICE_USER"
            delgroup "$S5_SERVICE_GROUP" >/dev/null 2>&1 || true
            S5_CREATED_GROUP=0
            S5_CREATED_GROUP_NAMED=0
            return 1
        }
    else
        groupadd -r "$S5_SERVICE_GROUP" >/dev/null 2>&1 || { s5_msg_err account.failed "$S5_SERVICE_GROUP"; return 1; }
        S5_CREATED_GROUP=1
        S5_CREATED_GROUP_NAMED=1
        useradd -r -g "$S5_SERVICE_GROUP" -M -d /nonexistent -s "$_s5nologin" "$S5_SERVICE_USER" >/dev/null 2>&1 || {
            s5_msg_err account.failed "$S5_SERVICE_USER"
            groupdel "$S5_SERVICE_GROUP" >/dev/null 2>&1 || true
            return 1
        }
    fi
    S5_CREATED_USER=1
    S5_CREATED_USER_NAMED=1
    S5_ACCOUNT_UID=$(id -u "$S5_SERVICE_USER" 2>/dev/null) || return 1
    S5_ACCOUNT_GID=$(id -g "$S5_SERVICE_USER" 2>/dev/null) || return 1
    return 0
}

s5_account_identity() {
    [ -n "$S5_ACCOUNT_UID" ] && [ -n "$S5_ACCOUNT_GID" ] || return 1
    _saiu=$(id -u "$S5_SERVICE_USER" 2>/dev/null) || return 1
    _saig=$(id -g "$S5_SERVICE_USER" 2>/dev/null) || return 1
    [ "$_saiu" = "$S5_ACCOUNT_UID" ] && [ "$_saig" = "$S5_ACCOUNT_GID" ] || return 1
    if [ "$S5_OS_FAMILY" = alpine ]; then
        _saig_named=$(getent group "$S5_SERVICE_GROUP" 2>/dev/null | awk -F: 'NR == 1 { print $3 }') || return 1
        [ "$_saig_named" = "$S5_ACCOUNT_GID" ]
    else
        return 0
    fi
}

s5_account_remove() {
    if [ -n "$S5_ACCOUNT_UID" ] && [ -n "$S5_ACCOUNT_GID" ]; then
        s5_account_identity || {
            s5_warn "account identity mismatch: recorded $S5_ACCOUNT_UID/$S5_ACCOUNT_GID"
            s5_msg_err account.identity
            return 1
        }
    elif [ "$S5_CREATED_USER_NAMED" != 1 ] && [ "$S5_CREATED_GROUP_NAMED" != 1 ]; then
        s5_msg_err account.identity
        return 1
    fi
    if [ "$S5_CREATED_USER" = 1 ] || [ -n "$S5_ACCOUNT_UID" ]; then
    if [ "$S5_OS_FAMILY" = alpine ]; then
        deluser "$S5_SERVICE_USER" >/dev/null 2>&1 || {
            s5_warn "could not remove service account: $S5_SERVICE_USER"
            return 1
        }
    else
        if ! userdel "$S5_SERVICE_USER" >/dev/null 2>&1; then
            s5_warn "could not remove service account: $S5_SERVICE_USER"
            return 1
        fi
    fi
    s5_getent_state passwd "$S5_SERVICE_USER"
        case $? in
        1) ;;
        0) s5_warn "service account still exists after removal: $S5_SERVICE_USER"; return 1 ;;
        *) s5_warn "could not verify service account removal: $S5_SERVICE_USER"; return 1 ;;
        esac
    fi
    if [ "$S5_CREATED_GROUP" = 1 ] || [ -n "$S5_ACCOUNT_GID" ]; then
        s5_getent_state group "$S5_SERVICE_GROUP"
        case $? in
        0)
            if [ "$S5_OS_FAMILY" = alpine ]; then
                delgroup "$S5_SERVICE_GROUP" >/dev/null 2>&1 || return 1
            elif ! groupdel "$S5_SERVICE_GROUP" >/dev/null 2>&1; then
                s5_warn "could not remove service group: $S5_SERVICE_GROUP"
                return 1
            fi
            ;;
        1) ;;
        *) s5_warn "could not verify service group before removal: $S5_SERVICE_GROUP"; return 1 ;;
        esac
        s5_getent_state group "$S5_SERVICE_GROUP"
        case $? in
        1) ;;
        0) s5_warn "service group still exists after removal: $S5_SERVICE_GROUP"; return 1 ;;
        *) s5_warn "could not verify service group removal: $S5_SERVICE_GROUP"; return 1 ;;
        esac
    fi
    S5_CREATED_USER=0
    S5_CREATED_GROUP=0
    S5_CREATED_USER_NAMED=0
    S5_CREATED_GROUP_NAMED=0
    S5_ACCOUNT_UID=''
    S5_ACCOUNT_GID=''
    return 0
}

s5_write_config_candidate() {
    _swct=$(mktemp "$S5_SYSCONFDIR/.s5new.XXXXXX") || return 1
    rm -f "$_swct" || return 1
    _swcc=$_swct.json
    _swraw=$(mktemp "$S5_SYSCONFDIR/.s5tmp.XXXXXX") || return 1
    chmod 0600 "$_swraw" || { rm -f "$_swraw"; return 1; }
    if ! s5_config_render >"$_swraw"; then
        rm -f "$_swraw"
        return 1
    fi
    if ! s5_atomic_write "$_swcc" "root:$S5_SERVICE_GROUP" 0640 <"$_swraw"; then
        rm -f "$_swraw"
        return 1
    fi
    rm -f "$_swraw" || return 1
    s5_config_test "$_swcc" || { rm -f "$_swcc"; s5_msg_err config.invalid; return 1; }
    printf '%s' "$_swcc"
}

s5_write_unit() {
    case "${S5_INIT:-systemd}" in
    openrc)
        if [ ! -d "$S5_INITSCRIPTDIR" ]; then
            s5_mkdir_parents "$S5_INITSCRIPTDIR" || return 1
        fi
        s5_atomic_write "$S5_INITSCRIPT" root:root 0755 <<UNIT
#!/sbin/openrc-run

name="$S5_PROJECT"
description="Xray mixed SOCKS5 and HTTP proxy"
command="$S5_BIN"
command_args="run -c $S5_CFG"
command_user="$S5_SERVICE_USER:$S5_SERVICE_GROUP"
supervisor="supervise-daemon"
respawn_max=1
respawn_period=60
respawn_delay=1
output_logger="logger -t $S5_PROJECT -p daemon.info"
error_logger="logger -t $S5_PROJECT -p daemon.err"
pidfile="$S5_PIDFILE"

depend() {
	after firewall
	use dns logger
}
UNIT
        # The status has to be captured before the assignment: a plain assignment
        # always succeeds, so `return $?` after it reported a failed init-script
        # write as success and the caller set S5_CREATED_UNIT for a missing file.
        _swurc=$?
        S5_UNIT=$S5_INITSCRIPT
        return "$_swurc"
        ;;
    systemd)
        if [ ! -d "$S5_UNITDIR" ]; then
            s5_mkdir_parents "$S5_UNITDIR" || return 1
        fi
        s5_atomic_write "$S5_UNIT" root:root 0644 <<UNIT
[Unit]
Description=Xray mixed SOCKS5 and HTTP proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$S5_SERVICE_USER
Group=$S5_SERVICE_GROUP
ExecStart=$S5_BIN run -c $S5_CFG
Restart=on-failure
RestartPreventExitStatus=23
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
UNIT
    esac
}

s5_state_get() {
    awk -F '\t' -v k="$1" '$1 == k { print $2; exit }' "$S5_STATE" 2>/dev/null
}

s5_state_schema_valid() {
    awk -F '\t' '
        BEGIN { valid=1 }
        {
            if (NF != 2 || $1 == "" || $2 == "") valid=0
            if ($1 !~ /^(engine|release|commit|asset|archive_size|archive_sha256|binary_size|binary_sha256|protocol|auth|udp|listen|port|username|os|arch|family|init|account_uid|account_gid|config_sha256|unit_sha256|status)$/) valid=0
            seen[$1]++
        }
        END {
            if (NR != 22 && NR != 23) valid=0
            if (NR == 22 && seen["family"]) valid=0
            for (key in seen) if (seen[key] != 1) valid=0
            exit valid ? 0 : 1
        }
    ' "$S5_STATE" 2>/dev/null
}

s5_state_write() {
    _sswtmp=$(mktemp "$S5_STATEDIR/.s5state.XXXXXX") || return 1
    rm -f "$_sswtmp" || return 1
    s5_atomic_write "$S5_STATE" root:root 0600 <<STATE
engine	xray
release	$S5_XRAY_VERSION
commit	$S5_XRAY_COMMIT
asset	$S5_ASSET_NAME
archive_size	$S5_ASSET_SIZE
archive_sha256	$S5_ASSET_SHA256
binary_size	$S5_ASSET_BINARY_SIZE
binary_sha256	$S5_BINARY_SHA256
protocol	mixed
auth	password
udp	false
listen	$S5_LISTEN
port	$S5_PORT
username	$S5_USERNAME
os	$S5_OS_ID-$S5_OS_VERSION_ID
arch	$S5_ARCHNAME
family	$S5_OS_FAMILY
init	$S5_INIT
account_uid	$S5_ACCOUNT_UID
account_gid	$S5_ACCOUNT_GID
config_sha256	$S5_CONFIG_SHA256
unit_sha256	$S5_UNIT_SHA256
status	complete
STATE
}

s5_state_load() {
    _slcurrent_family=$S5_OS_FAMILY
    _slcurrent_init=$S5_INIT
    [ -f "$S5_STATE" ] && [ ! -L "$S5_STATE" ] || return 1
    [ "$(stat -c '%a' "$S5_STATE" 2>/dev/null)" = 600 ] || return 1
    s5_state_schema_valid || return 1
    [ -d "$S5_PREFIX" ] && [ ! -L "$S5_PREFIX" ] || return 1
    [ -d "$S5_SYSCONFDIR" ] && [ ! -L "$S5_SYSCONFDIR" ] || return 1
    [ -d "$S5_STATEDIR" ] && [ ! -L "$S5_STATEDIR" ] || return 1
    [ "$(s5_state_get engine)" = xray ] || return 1
    [ "$(s5_state_get release)" = "$S5_XRAY_VERSION" ] || return 1
    [ "$(s5_state_get commit)" = "$S5_XRAY_COMMIT" ] || return 1
    [ "$(s5_state_get protocol)" = mixed ] || return 1
    [ "$(s5_state_get auth)" = password ] || return 1
    [ "$(s5_state_get udp)" = false ] || return 1
    [ "$(s5_state_get status)" = complete ] || return 1
    S5_ARCHNAME=$(s5_state_get arch)
    s5_asset_select || return 1
    _slasset=$(s5_state_get asset)
    _slsize=$(s5_state_get archive_size)
    _slsha=$(s5_state_get archive_sha256)
    _slbinsize=$(s5_state_get binary_size)
    _slbinsha=$(s5_state_get binary_sha256)
    [ "$S5_ASSET_NAME" = "$_slasset" ] &&
        [ "$S5_ASSET_SIZE" = "$_slsize" ] &&
        [ "$S5_ASSET_SHA256" = "$_slsha" ] &&
        [ "$S5_ASSET_BINARY_SIZE" = "$_slbinsize" ] &&
        [ "$S5_ASSET_BINARY_SHA256" = "$_slbinsha" ] || return 1
    S5_ASSET_NAME=$_slasset
    S5_ASSET_SIZE=$_slsize
    S5_ASSET_SHA256=$_slsha
    S5_ASSET_BINARY_SIZE=$_slbinsize
    S5_BINARY_SHA256=$_slbinsha
    S5_LISTEN=$(s5_state_get listen)
    S5_PORT=$(s5_state_get port)
    S5_USERNAME=$(s5_state_get username)
    S5_ARCHNAME=$(s5_state_get arch)
    S5_OS_FAMILY=$(s5_state_get family)
    S5_INIT=$(s5_state_get init)
    # The recorded family is cross-checked like the init is below. debian and el
    # share the systemd unit path, so the init check alone accepts a state file
    # written on the other one, and the family is what picks the package manager
    # an update installs from. An empty value is left to the fallback: it means an
    # older state file recorded no family, not that the host disagrees.
    if [ -n "$S5_OS_FAMILY" ] && [ -n "$_slcurrent_family" ]; then
        [ "$S5_OS_FAMILY" = "$_slcurrent_family" ] || return 1
    fi
    if [ -z "$S5_OS_FAMILY" ]; then
        case "$S5_INIT" in
        systemd) S5_OS_FAMILY=debian ;;
        *) return 1 ;;
        esac
    fi
    [ -n "$_slcurrent_init" ] && [ "$_slcurrent_init" = "$S5_INIT" ] || return 1
    case "$S5_OS_FAMILY:$S5_INIT" in
    alpine:openrc) S5_INITSCRIPT=$S5_ROOTDIR/etc/init.d/$S5_PROJECT; S5_UNIT=$S5_INITSCRIPT ;;
    debian:systemd | el:systemd) S5_UNIT=$S5_UNITDIR/$S5_PROJECT.service ;;
    *) return 1 ;;
    esac
    S5_SERVICE_ARTIFACT=$S5_UNIT
    S5_ACCOUNT_UID=$(s5_state_get account_uid)
    S5_ACCOUNT_GID=$(s5_state_get account_gid)
    S5_CONFIG_SHA256=$(s5_state_get config_sha256)
    S5_UNIT_SHA256=$(s5_state_get unit_sha256)
    [ -n "$S5_ASSET_NAME" ] && [ -n "$S5_ASSET_SIZE" ] && [ -n "$S5_ASSET_SHA256" ] || return 1
    [ -n "$S5_ASSET_BINARY_SIZE" ] && [ -n "$S5_BINARY_SHA256" ] || return 1
    [ -n "$S5_UNIT_SHA256" ] || return 1
    s5_valid_port "$S5_PORT" && s5_valid_username "$S5_USERNAME" && s5_ipv4_is_canonical "$S5_LISTEN" || return 1
    [ -f "$S5_UNIT" ] && [ ! -L "$S5_UNIT" ] || return 1
    [ "$(sha256sum "$S5_UNIT" 2>/dev/null | awk '{print $1}')" = "$S5_UNIT_SHA256" ] || return 1
    [ "$(sha256sum "$S5_CFG" 2>/dev/null | awk '{print $1}')" = "$S5_CONFIG_SHA256" ] || return 2
    [ -f "$S5_BIN" ] && [ ! -L "$S5_BIN" ] && [ -x "$S5_BIN" ] || return 1
    [ "$(sha256sum "$S5_BIN" 2>/dev/null | awk '{print $1}')" = "$S5_BINARY_SHA256" ] || return 1
    s5_account_identity || return 1
    return 0
}

s5_verify_dataplane() {
    # What this can prove on the operator's host is bounded by the destination
    # boundary the config carries: every address reachable without changing the
    # host's own networking is inside it, so a payload round trip through the
    # proxy is not available here. It is proven in CI on both backends instead.
    # What runs here is what only this host can answer: that its listener speaks
    # both protocols, that both discriminate on the credential, and that its
    # boundary actually refuses a destination that is listening and answering.
    if [ "${S5_TEST_MODE:-0}" = 1 ]; then
        if [ -n "${S5_PROTOCOL_VERIFY:-}" ]; then
            "$S5_PROTOCOL_VERIFY" "$S5_PORT"
            return $?
        fi
        return 0
    fi
    _svpf=$(mktemp "${S5_WORKDIR:-${S5_ROOTDIR:-/var/tmp}}/.s5pass.XXXXXX") || return 1
    # Recorded so a signal handler can remove it: on the restart path there is no
    # workdir, so this lands in /var/tmp and the normal `rm -f` below is skipped
    # when the process is killed mid-verification, leaving the credential on disk.
    S5_VERIFY_TEMP=$_svpf
    chmod 0600 "$_svpf" || { rm -f "$_svpf"; S5_VERIFY_TEMP=''; return 1; }
    printf '%s\n%s\n' "$S5_USERNAME" "$S5_PASSWORD" >"$_svpf" || { rm -f "$_svpf"; S5_VERIFY_TEMP=''; return 1; }
    python3 - "$S5_PORT" "$_svpf" <<'PY'
import base64
import socket
import sys
import threading

port = int(sys.argv[1])
with open(sys.argv[2], encoding="ascii") as handle:
    user, password = handle.read().splitlines()
stop = threading.Event()
ready = threading.Event()

def target():
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(8)
    target.port = srv.getsockname()[1]
    ready.set()
    srv.settimeout(.5)
    while not stop.is_set():
        try: conn, _ = srv.accept()
        except socket.timeout: continue
        threading.Thread(target=relay, args=(conn,), daemon=True).start()
    srv.close()

def relay(conn):
    try:
        while True:
            data = conn.recv(4096)
            if not data: return
            conn.sendall(data)
    finally: conn.close()

def exact(conn, n):
    data = b""
    while len(data) < n:
        part = conn.recv(n-len(data))
        if not part: raise RuntimeError("closed")
        data += part
    return data

class BoundaryBypassed(Exception):
    pass

def direct_echo():
    """The positive control for the boundary case below.

    Without it a refusal through the proxy could just as well mean nothing was
    listening at the destination.
    """
    conn = socket.create_connection(("127.0.0.1", target.port), 5)
    try:
        conn.settimeout(5)
        conn.sendall(b"direct-echo")
        if exact(conn, 11) != b"direct-echo": raise RuntimeError("target echo")
    finally: conn.close()

def socks_auth_then_refused():
    """RFC 1929 with the real credential is accepted, and the destination inside
    the boundary is then refused even though it is listening and answering."""
    conn = socket.create_connection(("127.0.0.1", port), 5)
    try:
        conn.settimeout(5)
        conn.sendall(b"\x05\x01\x02")
        if exact(conn, 2) != b"\x05\x02": raise RuntimeError("auth method")
        ub, pb = user.encode(), password.encode()
        conn.sendall(b"\x01" + bytes([len(ub)]) + ub + bytes([len(pb)]) + pb)
        if exact(conn, 2) != b"\x01\x00": raise RuntimeError("auth")
        conn.sendall(b"\x05\x01\x00\x01" + socket.inet_aton("127.0.0.1") + target.port.to_bytes(2, "big"))
        try:
            if exact(conn, 10)[:2] != b"\x05\x00": return
            conn.sendall(b"boundary-probe")
            echoed = exact(conn, 14)
        except (RuntimeError, OSError):
            return
        if echoed == b"boundary-probe": raise BoundaryBypassed("loopback reached")
    finally: conn.close()

def socks_bad_auth_refused():
    conn = socket.create_connection(("127.0.0.1", port), 5)
    try:
        conn.settimeout(5)
        conn.sendall(b"\x05\x01\x02")
        if exact(conn, 2) != b"\x05\x02": raise RuntimeError("negative auth method")
        ub, pb = user.encode(), (password + "x").encode()
        conn.sendall(b"\x01" + bytes([len(ub)]) + ub + bytes([len(pb)]) + pb)
        if exact(conn, 2) == b"\x01\x00": raise RuntimeError("bad auth accepted")
    finally: conn.close()

def http_status(secret):
    conn = socket.create_connection(("127.0.0.1", port), 5)
    try:
        conn.settimeout(5)
        token = base64.b64encode((user + ":" + secret).encode()).decode()
        request = ("CONNECT 127.0.0.1:%d HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                   "Proxy-Authorization: Basic %s\r\n\r\n") % (target.port, token)
        conn.sendall(request.encode())
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = conn.recv(4096)
            if not chunk: break
            data += chunk
            if len(data) > 8192: raise RuntimeError("http response")
        return data.split(b"\r\n", 1)[0]
    finally: conn.close()

def http_auth_discriminates():
    """A wrong credential has to be refused with 407 and the real one must not be.

    The destination is inside the boundary, so a 200 is neither expected nor
    required; what the differential rules out is a proxy that answers the same way
    to both, which an empty reply from a broken inbound would otherwise pass.
    """
    if b"407" not in http_status(password + "x"): raise RuntimeError("http bad auth accepted")
    if b"407" in http_status(password): raise RuntimeError("http auth")

t = threading.Thread(target=target, daemon=True)
t.start()
try:
    if not ready.wait(5): raise RuntimeError("target")
    direct_echo()
    socks_auth_then_refused()
    socks_bad_auth_refused()
    http_auth_discriminates()
except Exception as exc:
    raise SystemExit("data-plane verification failed: %s" % type(exc).__name__)
finally:
    stop.set()
PY
    _svd=$?
    rm -f "$_svpf"
    S5_VERIFY_TEMP=''
    [ "$_svd" -eq 0 ] || { s5_msg_err service.unverified "$S5_PORT"; return 1; }
    return 0
}

s5_service_active() {
    case "$S5_INIT" in
    openrc)
        rc-service "$S5_PROJECT" status >/dev/null 2>&1
        # Only 3 (stopped) proves the service is down. 16 is OpenRC's `inactive`,
        # which supervise-daemon leaves behind while the supervised process is
        # still alive and still holding the port, and 1 is a plain rc-service
        # error; treating either as stopped let uninstall delete everything from
        # under a live proxy. Unknown means unverified, as on systemd.
        case $? in 0 | 8) return 0 ;; 3) return 1 ;; *) return 2 ;; esac
        ;;
    *)
        systemctl is-active "$S5_PROJECT.service" >/dev/null 2>&1
        case $? in 0) return 0 ;; 3) return 1 ;; *) return 2 ;; esac
        ;;
    esac
}

s5_openrc_start() {
    # The "nonzero but already active" fallback is only sound for start, which is
    # idempotent. For restart an old instance that survived a failed stop also
    # looks active, so restart propagates rc-service's status directly.
    rc-service "$S5_PROJECT" "$1"
    _sosrc=$?
    [ "$_sosrc" -eq 0 ] && return 0
    s5_service_active
    _sosactive=$?
    [ "$_sosactive" -eq 0 ] && return 0
    return "$_sosrc"
}

s5_service_start() {
    if [ "$S5_INIT" = openrc ]; then s5_openrc_start start; else systemctl start "$S5_PROJECT.service" >/dev/null 2>&1; fi
}
s5_service_stop() {
    if [ "$S5_INIT" = openrc ]; then rc-service "$S5_PROJECT" stop; else systemctl stop "$S5_PROJECT.service" >/dev/null 2>&1; fi
}
s5_service_restart() {
    if [ "$S5_INIT" = openrc ]; then rc-service "$S5_PROJECT" restart; else systemctl restart "$S5_PROJECT.service" >/dev/null 2>&1; fi
}
s5_service_enable() {
    if [ "$S5_INIT" = openrc ]; then rc-update add "$S5_PROJECT" default >/dev/null 2>&1; else systemctl enable "$S5_PROJECT.service" >/dev/null 2>&1; fi
}
s5_service_disable() {
    if [ "$S5_INIT" = openrc ]; then rc-update del "$S5_PROJECT" default >/dev/null 2>&1; else systemctl disable "$S5_PROJECT.service" >/dev/null 2>&1; fi
}

s5_wait_stopped() {
    _swsi=0
    while [ "$_swsi" -lt 15 ]; do
        s5_service_active
        case $? in 1) return 0 ;; 0 | 2) ;; *) return 2 ;; esac
        _swsi=$((_swsi + 1))
        sleep 1
    done
    return 1
}

s5_listener_state() {
    if [ "${S5_TEST_MODE:-0}" = 1 ]; then
        if [ -n "${S5_LISTENER_PROBE:-}" ]; then
            "$S5_LISTENER_PROBE" "$S5_LISTEN" "$S5_PORT"
            return $?
        fi
        if [ -n "${S5_PORT_PROBE:-}" ]; then
            "$S5_PORT_PROBE" "$S5_PORT"
            case $? in 1) return 0 ;; 0) return 1 ;; *) return 2 ;; esac
        fi
    fi
    _slpid=''
    if [ "$S5_INIT" = openrc ]; then
        # supervise-daemon records the supervised process in child_pid and its
        # own pid in the pidfile, so child_pid is already the listener owner.
        # Xray spawns a logger child per output stream, which makes any walk
        # below child_pid ambiguous.
        _slpid=$(cat "$S5_OPENRC_OPTION_DIR/child_pid" 2>/dev/null) || return 1
        case "$_slpid" in '' | *[!0-9]* | 0) return 1 ;; esac
    else
        _slpid=$(systemctl show "$S5_PROJECT.service" -p MainPID --value 2>/dev/null) || return 2
    fi
    case "$_slpid" in '' | *[!0-9]* | 0) return 2 ;; esac
    command -v ss >/dev/null 2>&1 || return 2
    _slss=$(ss -H -ltnp 2>/dev/null) || return 2
    _slcount=0
    _slmatch=0
    _slmatchstate=''
    while IFS= read -r _slrow; do
        [ -n "$_slrow" ] || continue
        _slstate=$(printf '%s\n' "$_slrow" | awk '{print $1}')
        _sladdr=$(printf '%s\n' "$_slrow" | awk '{print $4}')
        case "$_sladdr" in
        "$S5_LISTEN:$S5_PORT") ;;
        "0.0.0.0:$S5_PORT")
            [ "$S5_LISTEN" = 0.0.0.0 ] || continue
            ;;
        "*:$S5_PORT")
            [ "$S5_LISTEN" = 0.0.0.0 ] || continue
            [ "$_sladdr" = "*:$S5_PORT" ] || continue
            ;;
        *) continue ;;
        esac
        _slcount=$((_slcount + 1))
        case "$_slrow" in
        *pid=$_slpid,*) _slmatch=$((_slmatch + 1)); _slmatchstate=$_slstate ;;
        *pid=$_slpid\)*) _slmatch=$((_slmatch + 1)); _slmatchstate=$_slstate ;;
        esac
    done <<EOF
$_slss
EOF
    [ "$_slcount" -eq 0 ] && return 1
    [ "$_slcount" -eq 1 ] && [ "$_slmatch" -eq 1 ] || return 2
    [ "$_slmatchstate" = LISTEN ] || return 2
    return 0
}

s5_wait_listening() {
    _swlp=$1
    _swli=0
    while [ "$_swli" -lt 30 ]; do
        S5_PORT=$_swlp
        s5_listener_state
        case $? in 0) return 0 ;; 1) ;; 2) [ "$S5_INIT" = openrc ] || return 2 ;; *) return 2 ;; esac
        _swli=$((_swli + 1))
        sleep 1
    done
    return 1
}

s5_cleanup_transaction() {
    [ -d "$S5_TXNDIR" ] || return 0
    for _sctf in "$S5_TXNDIR"/old.config.json "$S5_TXNDIR"/old.state "$S5_TXNDIR"/.s5new.* "$S5_TXNDIR"/.s5tmp.*; do
        [ -e "$_sctf" ] || continue
        rm -f "$_sctf" || return 1
    done
    rmdir "$S5_TXNDIR" 2>/dev/null || return 1
    return 0
}

s5_cleanup_own_temps() {
    _scotd=$1
    [ -d "$_scotd" ] || return 0
    # The patterns are quoted so they reach the inner glob intact. Unquoted, the
    # shell expanded them against the caller's working directory, and a match
    # there turned each word into a literal filename that the inner glob could
    # never find -- so running from an install directory skipped the cleanup.
    for _scotp in '.s5tmp.*' '.s5new.*' '.s5state.*' '.xray.*'; do
        for _scotf in "$_scotd"/$_scotp; do
            if [ -e "$_scotf" ] || [ -L "$_scotf" ]; then
                rm -f "$_scotf" || return 1
            fi
        done
    done
    return 0
}

s5_cleanup() {
    [ "$S5_IN_CLEANUP" = 1 ] && return 0
    S5_IN_CLEANUP=1
    trap '' HUP INT TERM
    if [ "$S5_INSTALL_COMPLETE" != 1 ]; then
        # Whether this run owns the service's runtime files has to be decided
        # before S5_SERVICE_STARTED is cleared just below.
        _sclruntime=0
        if [ "$S5_SERVICE_STARTED" = 1 ] || [ "$S5_CREATED_UNIT" = 1 ]; then
            _sclruntime=1
        fi
        if [ "$S5_SERVICE_STARTED" = 1 ]; then
            s5_service_stop || true
            S5_SERVICE_STARTED=0
        fi
        if [ "$S5_UNIT_ENABLED" = 1 ]; then
            s5_service_disable || true
            if [ "$S5_INIT" = systemd ]; then
                systemctl daemon-reload >/dev/null 2>&1 || true
            fi
            S5_UNIT_ENABLED=0
        fi
        if [ "$S5_CREATED_UNIT" = 1 ]; then rm -f "$S5_UNIT" 2>/dev/null || true; fi
        # supervise-daemon's pidfile and child_pid belong to whatever service is
        # running. Removing them for an installation this run never touched left a
        # healthy Alpine proxy unstoppable and unobservable: status reports no
        # listener, uninstall cannot signal the supervisor, and the next update
        # sees its own port as foreign. Declining the update prompt reached this.
        if [ "$S5_INIT" = openrc ] && [ "$_sclruntime" = 1 ]; then
            rm -f "$S5_PIDFILE" "$S5_OPENRC_OPTION_DIR/child_pid" 2>/dev/null || true
        fi
        if [ "$S5_CREATED_CFG" = 1 ]; then rm -f "$S5_CFG" 2>/dev/null || true; fi
        if [ "$S5_CREATED_BIN" = 1 ]; then rm -f "$S5_BIN" 2>/dev/null || true; fi
        if [ "$S5_CREATED_USER" = 1 ]; then
            s5_account_remove || true
        elif [ "$S5_CREATED_GROUP" = 1 ]; then
            if [ "$S5_OS_FAMILY" = alpine ]; then
                delgroup "$S5_SERVICE_GROUP" >/dev/null 2>&1 || true
            else
                groupdel "$S5_SERVICE_GROUP" >/dev/null 2>&1 || true
            fi
        fi
        # An interrupted atomic write leaves a private temporary behind; the
        # rmdir below, and uninstall later, both refuse a non-empty directory.
        s5_cleanup_own_temps "$S5_SYSCONFDIR" || true
        s5_cleanup_own_temps "$S5_STATEDIR" || true
        # The transaction directory holds the only copy of the pre-update config
        # and state. Deleting it without restoring left the newly published config
        # live against the old recorded hash, which s5_state_load then refuses
        # forever: the installation could be neither repaired nor removed through
        # the CLI. If the restore itself fails, keep the evidence for the next run
        # rather than destroying it.
        if [ -f "$S5_TXNDIR/old.config.json" ] && [ -f "$S5_TXNDIR/old.state" ]; then
            if s5_restore_transaction "$S5_TXNDIR/old.config.json" "$S5_TXNDIR/old.state"; then
                s5_service_restart || true
                s5_cleanup_transaction || true
            fi
        else
            s5_cleanup_transaction || true
        fi
        s5_cleanup_own_temps "$S5_PREFIX" || true
        if [ "$S5_CREATED_CONFDIR" = 1 ]; then rmdir "$S5_SYSCONFDIR" 2>/dev/null || true; fi
        if [ "$S5_CREATED_STATEDIR" = 1 ]; then rmdir "$S5_STATEDIR" 2>/dev/null || true; fi
        if [ "$S5_CREATED_PREFIX" = 1 ]; then rmdir "$S5_PREFIX" 2>/dev/null || true; fi
    fi
    if [ -n "$S5_WORKDIR" ]; then
        rm -rf "$S5_WORKDIR" 2>/dev/null || true
    fi
    if [ "$S5_LOCK_HELD" = 1 ]; then
        s5_lock_release || true
    fi
    S5_WORKDIR=''
    S5_IN_CLEANUP=0
    return 0
}

s5_on_signal() {
    trap '' HUP INT TERM
    s5_cleanup
    trap - EXIT
    exit "$1"
}

# The read-only and single-purpose commands hold the lock but have nothing to roll
# back, so they unwind with the lock and the verifier's credential temporary only.
# Without this an interrupt left both behind.
s5_on_signal_lock() {
    trap '' HUP INT TERM
    s5_release_verify_temp
    s5_lock_release || true
    trap - EXIT
    exit "$1"
}

s5_release_verify_temp() {
    if [ -n "$S5_VERIFY_TEMP" ]; then
        rm -f "$S5_VERIFY_TEMP" 2>/dev/null || true
        S5_VERIFY_TEMP=''
    fi
}

# Only the signal traps: every one of these commands releases the lock on each of
# its own return paths, so an EXIT trap would add nothing and would displace the
# EXIT handler of whatever sourced the script.
s5_trap_lock_only() {
    trap 's5_on_signal_lock 129' HUP
    trap 's5_on_signal_lock 130' INT
    trap 's5_on_signal_lock 143' TERM
}

s5_runtime_packages() {
    case "${1:-}" in install | update) ;; *) return 0 ;; esac
    [ "$S5_INIT" = openrc ] || return 0
    _srp=''
    command -v curl >/dev/null 2>&1 || _srp="$_srp curl ca-certificates"
    # BusyBox provides a stripped unzip without -Z, so a present unzip proves
    # nothing about archive inspection; Info-ZIP is always requested.
    _srp="$_srp unzip"
    command -v file >/dev/null 2>&1 || _srp="$_srp file"
    command -v python3 >/dev/null 2>&1 || _srp="$_srp python3"
    command -v ss >/dev/null 2>&1 || _srp="$_srp iproute2"
    printf '%s' "${_srp# }"
}

s5_install_runtime_dependencies() {
    [ "${S5_TEST_MODE:-0}" = 1 ] && return 0
    _sird=$(s5_runtime_packages "${1:-}") || return 1
    [ -n "$_sird" ] || return 0
    command -v apk >/dev/null 2>&1 || return 1
    # Package names are fixed, and only runtime tools are requested.
    # No compiler, VCS, build system, or source headers are installed.
    set -f
    # shellcheck disable=SC2086
    apk add --no-cache $_sird >/dev/null 2>&1
    _s5apk=$?
    set +f
    [ "$_s5apk" -eq 0 ] || {
        s5_msg_err detect.commands "Alpine runtime packages"
        return 1
    }
    return 0
}

# BusyBox ships a stripped unzip that rejects -Z outright, and the member listing
# the archive inspection reads comes from -Z1, so a present unzip proves nothing.
# Bare -Z prints the zipinfo usage on Info-ZIP; either a zero status or that
# banner is proof, and accepting both keeps an unusual Info-ZIP build from being
# refused.
s5_unzip_lists_members() {
    if _suzl=$(unzip -Z 2>&1); then
        _suzl=''
        return 0
    fi
    case "$_suzl" in
    *ZipInfo* | *zipinfo*) _suzl=''; return 0 ;;
    esac
    _suzl=''
    return 1
}

s5_precheck() {
    _spcmode=${1:-install}
    s5_is_root || { s5_msg_err root.required; return 1; }
    S5_ARCHNAME=$(s5_map_arch "$(uname -m)") || {
        s5_msg_err detect.unsupported unknown unknown unknown
        return 1
    }
    s5_detect_platform || {
        s5_msg_err detect.unsupported "$S5_OS_ID" "$S5_OS_VERSION_ID" "$S5_ARCHNAME"
        return 1
    }
    s5_install_runtime_dependencies "$_spcmode" || return 1
    s5_require_commands awk sed grep tr tail head id getent mkdir rmdir rm mv cp cat printf stat sha256sum mktemp ln sleep wc chmod || return 1
    case "$S5_INIT:$_spcmode" in
    openrc:install|openrc:update)
        s5_require_commands addgroup adduser delgroup deluser rc-service rc-update rc-status logger unzip curl file od chown python3 ss || return 1
        ;;
    systemd:install|systemd:update)
        s5_require_commands groupadd groupdel useradd userdel unzip curl file od chown python3 || return 1
        command -v ss >/dev/null 2>&1 || { s5_msg_err detect.commands ss; return 1; }
        ;;
    openrc:status)
        s5_require_commands rc-service rc-status ss || return 1
        ;;
    systemd:status)
        s5_require_commands systemctl ss || return 1
        ;;
    # restart keeps python3: it re-runs the data-plane verification, which status
    # does not. status only reads service and listener state.
    openrc:restart)
        s5_require_commands python3 rc-service rc-status ss || return 1
        ;;
    systemd:restart)
        s5_require_commands python3 systemctl ss || return 1
        ;;
    openrc:uninstall)
        s5_require_commands delgroup deluser rc-service rc-update rc-status || return 1
        ;;
    systemd:uninstall)
        s5_require_commands groupdel userdel systemctl || return 1
        ;;
    *) s5_msg_err detect.init; return 1 ;;
    esac
    # Checked after the command list so a missing unzip is still reported as a
    # missing command. Without it the 21 MB archive downloads and hash-verifies
    # and only then fails member inspection, reporting a bad archive when the
    # tool is what cannot do the job.
    case "$_spcmode" in
    install | update)
        s5_unzip_lists_members || {
            s5_msg_err detect.commands 'unzip with -Z (Info-ZIP)'
            return 1
        }
        ;;
    esac
    s5_asset_select || return 1
    return 0
}

s5_confirm_install() {
    s5_msg install.confirm >&2
    _sci=''
    IFS= read -r _sci || return 1
    case "$_sci" in '' | y | Y | yes | YES | Yes) return 0 ;; *) s5_msg_print install.cancelled; return 1 ;; esac
}

s5_confirm_update() {
    s5_msg update.confirm >&2
    _scu=''
    IFS= read -r _scu || return 1
    case "$_scu" in y | Y) return 0 ;; *) s5_msg_print install.cancelled; return 1 ;; esac
}

s5_restore_transaction() {
    _srtcfg=$1
    _srtstate=$2
    if ! s5_atomic_write "$S5_CFG" "root:$S5_SERVICE_GROUP" 0640 <"$_srtcfg"; then return 1; fi
    if ! s5_atomic_write "$S5_STATE" root:root 0600 <"$_srtstate"; then return 1; fi
    return 0
}

# Every failure after the new config is published unwinds the same way: put the
# old config and state back, bring the service up on them, and drop the
# transaction evidence. Each step is best-effort because a rollback that aborts
# halfway leaves the installation in a worse state than the failure it handles.
s5_update_rollback() {
    s5_restore_transaction "$1" "$2" || true
    s5_service_restart || true
    s5_cleanup_transaction || true
    S5_SERVICE_STARTED=0
}

s5_install_new() {
    if [ -e "$S5_PREFIX" ] || [ -L "$S5_PREFIX" ] ||
        [ -e "$S5_SYSCONFDIR" ] || [ -L "$S5_SYSCONFDIR" ] ||
        [ -e "$S5_STATEDIR" ] || [ -L "$S5_STATEDIR" ] ||
        [ -e "$S5_UNIT" ] || [ -L "$S5_UNIT" ]; then
        s5_msg_err state.invalid "$S5_PROJECT"
        return 1
    fi
    s5_prompt_port || return 1
    s5_prompt_username || return 1
    s5_prompt_password || return 1
    s5_download_engine || return 1
    s5_mkdir_private "$S5_SYSCONFDIR" || return 1
    S5_CREATED_CONFDIR=1
    s5_mkdir_private "$S5_STATEDIR" || return 1
    S5_CREATED_STATEDIR=1
    s5_account_create || return 1
    if [ "${S5_SKIP_OWNERSHIP:-0}" != 1 ]; then
        chown root:"$S5_SERVICE_GROUP" "$S5_SYSCONFDIR" || return 1
    fi
    chmod 0750 "$S5_SYSCONFDIR" || return 1
    if [ "${S5_SKIP_OWNERSHIP:-0}" != 1 ]; then
        chown root:root "$S5_PREFIX" || return 1
    fi
    chmod 0755 "$S5_PREFIX" || return 1
    _sinc=$(s5_write_config_candidate) || return 1
    mv -f "$_sinc" "$S5_CFG" || return 1
    S5_CREATED_CFG=1
    if [ "$S5_INIT" = openrc ]; then
        S5_UNIT=$S5_INITSCRIPT
    else
        S5_UNIT=$S5_UNITDIR/$S5_PROJECT.service
    fi
    s5_write_unit || return 1
    S5_CREATED_UNIT=1
    if [ "$S5_INIT" = openrc ]; then
        S5_SERVICE_ARTIFACT=$S5_INITSCRIPT
    else
        S5_SERVICE_ARTIFACT=$S5_UNIT
    fi
    S5_UNIT_SHA256=$(sha256sum "$S5_SERVICE_ARTIFACT" | awk '{print $1}')
    if [ "$S5_INIT" = openrc ]; then
        s5_service_enable || return 1
    else
        systemctl daemon-reload >/dev/null 2>&1 || return 1
        s5_service_enable || return 1
    fi
    S5_UNIT_ENABLED=1
    s5_service_start || { s5_msg_err service.start; return 1; }
    S5_SERVICE_STARTED=1
    s5_service_active; _sina=$?
    case "$_sina" in 0) ;; 1) s5_msg_err service.start; return 1 ;; *) s5_msg_err service.inactive; return 1 ;; esac
    s5_wait_listening "$S5_PORT"
    case $? in 0) ;; 1) s5_msg_err service.listen "$S5_PORT"; return 1 ;; *) s5_msg_err service.unverified "$S5_PORT"; return 1 ;; esac
    s5_verify_dataplane || return 1
    S5_CONFIG_SHA256=$(sha256sum "$S5_CFG" | awk '{print $1}')
    s5_state_write || return 1
    S5_INSTALL_COMPLETE=1
    return 0
}

s5_backend_supported() {
    if [ "$S5_OS_FAMILY" = alpine ]; then
        [ "$S5_INIT" = openrc ]
    else
        [ "$S5_INIT" = systemd ]
    fi
}

# s5_report_state_load <status>: one diagnosis for every command that loads
# state. Return 2 means the published config no longer matches the recorded hash,
# so the state file is intact and the config is the file that changed; collapsing
# that into state.invalid told the operator the state was corrupt and to expect
# nothing to have been touched. An absent state file is not an invalid one
# either: it means nothing is installed.
s5_report_state_load() {
    case "${1:-1}" in
    0) return 0 ;;
    2) s5_msg_err config.external ;;
    *)
        if [ -e "$S5_STATE" ] || [ -L "$S5_STATE" ]; then
            s5_msg_err state.invalid "$S5_STATE"
        else
            s5_msg_err state.missing "$S5_PROJECT"
        fi
        ;;
    esac
    return 1
}

s5_install_update() {
    s5_state_load
    s5_report_state_load $? || return 1
    s5_backend_supported || { s5_msg_err state.invalid "$S5_STATE"; return 1; }
    s5_config_extract || return 1
    s5_confirm_update || return 1
    s5_prompt_port || return 1
    s5_prompt_username || return 1
    s5_prompt_password || return 1
    s5_asset_select || return 1
    s5_mkdir_private "$S5_TXNDIR" || return 1
    _sioldcfg=$S5_TXNDIR/old.config.json
    _sioldstate=$S5_TXNDIR/old.state
    cp "$S5_CFG" "$_sioldcfg" || return 1
    cp "$S5_STATE" "$_sioldstate" || return 1
    chmod 0600 "$_sioldcfg" "$_sioldstate" || return 1
    s5_binary_ready || { s5_msg_err asset.invalid binary; return 1; }
    _siinc=$(s5_write_config_candidate) || return 1
    s5_service_stop || { s5_msg_err service.stop; rm -f "$_siinc"; return 1; }
    s5_wait_stopped
    case $? in 0) ;; *) s5_msg_err service.stop; rm -f "$_siinc"; return 1 ;; esac
    if ! mv -f "$_siinc" "$S5_CFG"; then
        rm -f "$_siinc"
        s5_restore_transaction "$_sioldcfg" "$_sioldstate" || true
        s5_service_start || true
        return 1
    fi
    if ! s5_service_start; then
        s5_restore_transaction "$_sioldcfg" "$_sioldstate" || true
        s5_service_start || true
        rm -f "$_siinc"
        return 1
    fi
    S5_SERVICE_STARTED=1
    s5_wait_listening "$S5_PORT"
    _siwait=$?
    if [ "$_siwait" -ne 0 ]; then
        s5_update_rollback "$_sioldcfg" "$_sioldstate"
        s5_msg_err service.listen "$S5_PORT"
        return 1
    fi
    s5_verify_dataplane || {
        s5_update_rollback "$_sioldcfg" "$_sioldstate"
        return 1
    }
    S5_CONFIG_SHA256=$(sha256sum "$S5_CFG" | awk '{print $1}')
    if ! s5_state_write; then
        s5_update_rollback "$_sioldcfg" "$_sioldstate"
        return 1
    fi
    rm -f "$_sioldcfg" "$_sioldstate"
    rmdir "$S5_TXNDIR" 2>/dev/null || true
    S5_INSTALL_COMPLETE=1
    return 0
}

s5_cmd_install() {
    s5_precheck install || return 1
    s5_lock_acquire || return 1
    trap 's5_on_signal 129' HUP
    trap 's5_on_signal 130' INT
    trap 's5_on_signal 143' TERM
    trap 's5_cleanup' EXIT
    s5_msg_print install.start >&2
    if [ -f "$S5_STATE" ]; then
        s5_install_update
        _sic=$?
        _siupdate=1
    else
        s5_confirm_install || return 1
        s5_install_new
        _sic=$?
        _siupdate=0
    fi
    if [ "$_sic" -ne 0 ]; then
        s5_cleanup
        return 1
    fi
    s5_lock_release || return 1
    trap - EXIT HUP INT TERM
    if [ "$_siupdate" = 1 ]; then s5_msg_print install.updated; else s5_msg_print install.done; fi
    return 0
}

s5_cmd_status() {
    s5_precheck status || return 1
    s5_lock_acquire || return 1
    s5_trap_lock_only
    s5_state_load
    _ssr=$?
    s5_report_state_load "$_ssr" || { s5_lock_release || true; return 1; }
    s5_config_extract || { s5_lock_release || true; s5_msg_err state.invalid "$S5_STATE"; return 1; }
    s5_service_active
    _ssa=$?
    case "$_ssa" in 0) _ssv=running ;; 1) _ssv=stopped ;; *) _ssv=unverified ;; esac
    s5_msg_print status.heading
    s5_msg_print status.line "$_ssv" "$S5_PORT" "$S5_USERNAME"
    s5_msg_print status.version "$S5_XRAY_VERSION"
    s5_listener_state
    _ssls=$?
    case "$_ssls" in
    0) s5_msg_print service.ready "$S5_PORT" ;;
    1) s5_msg_print service.listen "$S5_PORT" ;;
    *) s5_msg_print service.unverified "$S5_PORT" ;;
    esac
    s5_lock_release || return 1
    return 0
}

# Reads one candidate address into $_lpb. One hardened request to the fixed
# endpoint: -q so no user or system curlrc can alter it, --noproxy '*' so an
# ambient proxy variable cannot redirect or observe it, IPv4 only, HTTPS only, no
# redirects, bounded, stdin detached. The body is captured to a private file
# rather than through a pipe, because a pipe reports the last command's status
# and would mask curl's own failure. S5_TEST_ADDR_PATH substitutes a local body
# for the request and nothing else, so the parsing below is the same code a real
# response goes through.
s5_read_public_ipv4() {
    _lpb=''
    _lpf=$(mktemp "${TMPDIR:-/tmp}/.s5ip.XXXXXX") || return 1
    if [ "${S5_TEST_MODE:-0}" = 1 ] && [ -n "${S5_TEST_ADDR_PATH:-}" ]; then
        cp "$S5_TEST_ADDR_PATH" "$_lpf" || { rm -f "$_lpf"; _lpf=''; return 1; }
    else
        if ! command -v curl >/dev/null 2>&1; then
            rm -f "$_lpf"
            _lpf=''
            return 1
        fi
        if ! curl -q -4 --noproxy '*' --proto '=https' --fail --silent \
            --connect-timeout 3 --max-time 5 --max-filesize 17 \
            --output "$_lpf" "$S5_ADDR_ENDPOINT" </dev/null 2>/dev/null; then
            rm -f "$_lpf"
            _lpf=''
            return 1
        fi
    fi
    _lpsz=$(wc -c <"$_lpf" 2>/dev/null | tr -d '[:space:]')
    case "$_lpsz" in '' | *[!0-9]*) _lpsz=18 ;; esac
    # The longest address is 15 bytes and one terminator is allowed two, so a
    # larger body cannot be a single address. Checked before the read so an
    # endpoint that ignores --max-filesize cannot stream an unbounded line.
    if [ "$_lpsz" -gt 17 ]; then
        rm -f "$_lpf"
        _lpf=''
        _lpsz=''
        return 1
    fi
    IFS= read -r _lpb <"$_lpf" 2>/dev/null || true
    rm -f "$_lpf"
    _lpf=''
    # The raw line still carries the CR of a CRLF terminator, so its length is
    # the exact byte count of everything before the LF.
    _lpn=${#_lpb}
    # read leaves that CR on the line, and a command substitution strips trailing
    # newlines but not a CR.
    _lpcr=$(printf 'x\r')
    _lpcr=${_lpcr#x}
    _lpb=${_lpb%"$_lpcr"}
    _lpcr=''
    # The body has to be one line and one optional terminator. Comparing the
    # file's byte count against the raw line plus that terminator rejects a
    # second line, a double terminator and unterminated trailing bytes without
    # enumerating them, which a command substitution cannot do because it strips
    # every trailing newline.
    if [ "$_lpsz" -gt "$((_lpn + 1))" ]; then
        _lpb=''
        _lpsz=''
        _lpn=''
        return 1
    fi
    _lpsz=''
    _lpn=''
    [ -n "$_lpb" ] || return 1
    return 0
}

# Resolves once per card, so the SOCKS5 and HTTP URIs always agree. Validation
# lives here rather than in the caller: S5_SERVER_IPV4 and the response body both
# reach the card through this, so neither can turn into a way past the check.
s5_resolve_card_address() {
    S5_CARD_ADDR=''
    S5_CARD_KIND=''
    if [ -n "${S5_SERVER_IPV4:-}" ] && s5_ipv4_is_canonical "$S5_SERVER_IPV4"; then
        S5_CARD_ADDR=$S5_SERVER_IPV4
        S5_CARD_KIND=configured
        return 0
    fi
    if s5_read_public_ipv4 && s5_ipv4_is_public "$_lpb"; then
        S5_CARD_ADDR=$_lpb
        S5_CARD_KIND=external
        _lpb=''
        return 0
    fi
    _lpb=''
    S5_CARD_ADDR=SERVER_IPV4
    S5_CARD_KIND=placeholder
    return 0
}

# The card body, callable directly by tests. The terminal-only guard stays in
# s5_cmd_show, because a test that satisfied it would not be testing the guard.
s5_render_card() {
    s5_resolve_card_address
    _sss="socks5://$S5_USERNAME:$S5_PASSWORD@$S5_CARD_ADDR:$S5_PORT"
    _sshttp="http://$S5_USERNAME:$S5_PASSWORD@$S5_CARD_ADDR:$S5_PORT"
    s5_msg_print show.heading || return 1
    case "$S5_CARD_KIND" in
    placeholder) s5_msg_print show.placeholder "$S5_CARD_ADDR" || return 1 ;;
    esac
    s5_msg_print show.socks "$_sss" || return 1
    s5_msg_print show.http "$_sshttp" || return 1
    s5_msg_print show.warning || return 1
    _sss=''
    _sshttp=''
    return 0
}

s5_cmd_show() {
    s5_is_root || { s5_msg_err root.required; return 1; }
    if [ ! -t 1 ]; then s5_msg_err show.terminal; return 1; fi
    s5_precheck status || return 1
    s5_lock_acquire || return 1
    s5_trap_lock_only
    s5_state_load
    s5_report_state_load $? || { s5_lock_release || true; return 1; }
    s5_config_extract || { s5_lock_release || true; return 1; }
    s5_render_card || { s5_lock_release || true; return 1; }
    s5_lock_release || return 1
    return 0
}

s5_cmd_restart() {
    s5_precheck restart || return 1
    s5_lock_acquire || return 1
    s5_trap_lock_only
    s5_state_load
    s5_report_state_load $? || { s5_lock_release || true; return 1; }
    s5_config_extract || { s5_lock_release || true; return 1; }
    s5_config_test "$S5_CFG" || { s5_lock_release || true; s5_msg_err config.invalid; return 1; }
    s5_service_restart || { s5_lock_release || true; s5_msg_err service.start; return 1; }
    s5_wait_listening "$S5_PORT"
    _srr=$?
    if [ "$_srr" -eq 0 ]; then
        s5_verify_dataplane || _srr=2
    fi
    s5_lock_release || return 1
    case "$_srr" in 0) return 0 ;; 1) s5_msg_err service.listen "$S5_PORT" ;; *) s5_msg_err service.unverified "$S5_PORT" ;; esac
    return 1
}

s5_remove_owned_file() {
    _srof=$1
    [ -e "$_srof" ] || [ -L "$_srof" ] || return 0
    [ -L "$_srof" ] && { s5_warn "refusing symlink during uninstall: $_srof"; return 1; }
    rm -f "$_srof" || { s5_warn "could not remove owned file: $_srof"; return 1; }
    return 0
}

s5_remove_owned_dir() {
    _srod=$1
    [ -e "$_srod" ] || [ -L "$_srod" ] || return 0
    [ -L "$_srod" ] || [ -d "$_srod" ] || { s5_warn "owned path is not a directory: $_srod"; return 1; }
    for _sroe in "$_srod"/* "$_srod"/.[!.]* "$_srod"/..?*; do
        if [ -e "$_sroe" ] || [ -L "$_sroe" ]; then
            s5_warn "refusing non-empty owned directory: $_sroe"
            return 1
        fi
    done
    rmdir "$_srod" || { s5_warn "could not remove owned directory: $_srod"; return 1; }
    return 0
}

s5_cmd_uninstall() {
    s5_precheck uninstall || return 1
    s5_lock_acquire || return 1
    s5_trap_lock_only
    s5_state_load
    _sur=$?
    if [ ! -e "$S5_STATE" ] && [ ! -L "$S5_STATE" ]; then
        s5_lock_release || true
        # The state file can be absent while an interrupted uninstall left the
        # namespace behind. Reporting success then hides real residue, including a
        # transaction copy of the previous config with its password in cleartext.
        if [ -e "$S5_SYSCONFDIR" ] || [ -e "$S5_STATEDIR" ] || [ -e "$S5_PREFIX" ]; then
            s5_msg_err state.invalid "$S5_STATE"
            return 1
        fi
        s5_msg_print state.missing "$S5_PROJECT"
        return 0
    fi
    # The state file exists here, so the shared diagnosis reports an invalid state
    # rather than a missing one.
    s5_report_state_load "$_sur" || { s5_lock_release || true; return 1; }
    s5_config_extract || { s5_lock_release || true; return 1; }
    s5_msg_print uninstall.confirm >&2
    _suc=''
    IFS= read -r _suc || { s5_lock_release || true; return 1; }
    case "$_suc" in y | Y) ;; *) s5_lock_release || true; s5_msg_print install.cancelled; return 1 ;; esac
    s5_service_stop || { s5_lock_release || true; s5_msg_err service.stop; return 1; }
    s5_wait_stopped
    case $? in 0) ;; *) s5_lock_release || true; s5_msg_err service.stop; return 1 ;; esac
    s5_account_identity || { s5_lock_release || true; s5_msg_err account.identity; return 1; }
    # Clear this installation's own leftovers before anything destructive runs. An
    # interrupted update leaves a transaction directory, and s5_remove_owned_dir
    # refuses a non-empty directory -- which used to abort uninstall only after the
    # unit, config, binary, account and state were already gone. Junk that is not
    # ours still stops us here, now before the first deletion rather than after.
    s5_cleanup_own_temps "$S5_SYSCONFDIR" || { s5_lock_release || true; return 1; }
    s5_cleanup_own_temps "$S5_STATEDIR" || { s5_lock_release || true; return 1; }
    s5_cleanup_own_temps "$S5_PREFIX" || { s5_lock_release || true; return 1; }
    s5_cleanup_transaction || { s5_lock_release || true; return 1; }
    s5_service_disable || { s5_lock_release || true; return 1; }
    s5_remove_owned_file "$S5_UNIT" || { s5_lock_release || true; return 1; }
    s5_remove_owned_file "$S5_CFG" || { s5_lock_release || true; return 1; }
    s5_remove_owned_file "$S5_BIN" || { s5_lock_release || true; return 1; }
    if [ "$S5_INIT" = systemd ]; then
        systemctl daemon-reload >/dev/null 2>&1 || { s5_lock_release || true; return 1; }
    fi
    s5_account_remove || { s5_lock_release || true; return 1; }
    s5_remove_owned_file "$S5_STATE" || { s5_lock_release || true; return 1; }
    s5_remove_owned_dir "$S5_SYSCONFDIR" || { s5_lock_release || true; return 1; }
    s5_remove_owned_dir "$S5_STATEDIR" || { s5_lock_release || true; return 1; }
    s5_remove_owned_dir "$S5_PREFIX" || { s5_lock_release || true; return 1; }
    s5_lock_release || return 1
    s5_msg_print uninstall.done
    return 0
}

s5_main() {
    s5_select_language || return 1
    _smcmd=${1:-}
    # shift is a POSIX special built-in, so shifting past the end terminates a
    # non-interactive shell outright -- neither the redirect nor the `|| true`
    # can catch it. Under dash, which is /bin/sh on Debian and Ubuntu, that
    # killed the documented zero-argument invocation before it dispatched.
    if [ "$#" -gt 0 ]; then
        shift
    fi
    if [ "$#" -gt 0 ]; then
        s5_msg_err extra "$*"
        return 64
    fi
    case "$_smcmd" in
    '' | install) s5_cmd_install ;;
    status) s5_cmd_status ;;
    show) s5_cmd_show ;;
    restart) s5_cmd_restart ;;
    uninstall) s5_cmd_uninstall ;;
    help | -h | --help) s5_msg_print usage ;;
    *) s5_msg_err extra "$_smcmd"; s5_msg_print usage >&2; return 64 ;;
    esac
}

if [ "${S5_LIB_ONLY:-0}" != 1 ]; then
    s5_main "$@"
    exit $?
fi
