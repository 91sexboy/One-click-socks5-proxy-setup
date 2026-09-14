#!/bin/sh
# xray-only authenticated mixed proxy installer and manager.
# Xray-core supplies the SOCKS5 and HTTP proxy implementations.

umask 077
set +x
set -u

S5_PROJECT=xray-socks5
S5_XRAY_VERSION=v26.3.27
S5_XRAY_COMMIT=d2758a023cd7f4174a5a5fa4ff66e487d4342ba0
S5_XRAY_BASE=https://github.com/91sexboy/One-click-socks5-proxy-setup/releases/download/xray-$S5_XRAY_VERSION
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
S5_INIT=''
S5_WORKDIR=''
S5_LOCK_HELD=0
S5_LOCK_TOKEN=''
S5_VERIFY_TEMP=''
S5_PUBLIC_IPV4_CANDIDATE=''
S5_CARD_ADDR=''
S5_CARD_KIND=''
S5_CONFIG_REPLACED=0
S5_CREATED_USER=0
S5_CREATED_GROUP=0
S5_CREATED_PREFIX=0
S5_CREATED_CONFDIR=0
S5_CREATED_STATEDIR=0
S5_CREATED_TRANSACTION=0
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
S5_LANG_FILE=$S5_ROOTDIR/etc/$S5_PROJECT.lang
S5_STATEDIR=$S5_ROOTDIR/var/lib/$S5_PROJECT
S5_UNITDIR=$S5_ROOTDIR/etc/systemd/system
S5_BIN=$S5_PREFIX/xray
S5_CFG=$S5_SYSCONFDIR/config.json
S5_STATE=$S5_STATEDIR/state
S5_INITSCRIPTDIR=$S5_ROOTDIR/etc/init.d
S5_INITSCRIPT=$S5_INITSCRIPTDIR/$S5_PROJECT
S5_SERVICE_ARTIFACT=''
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
        { line=$0; out=""; while (n > 0) { i=index(line,s); if (i == 0) break; out=out substr(line,1,i-1) "<REDACTED>"; line=substr(line,i+n) } printf "%s%s\n", out, line }
    '
}

s5_say() { printf '%s\n' "$1"; }
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
    lang.unsaved) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '无法保存语言设置；本次选择仅对当前运行有效。' ;; en) printf 'could not save the language preference; this choice applies only to the current invocation.' ;; esac ;;
    lang.saved) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '语言设置已保存。' ;; en) printf 'language preference saved.' ;; esac ;;
    root.required) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '安装和管理需要 root 权限。' ;; en) printf 'installation and management require root privileges.' ;; esac ;;
    detect.unsupported) [ "$#" -eq 3 ] || return 1; case "$S5_LANG" in zh) printf '不支持的系统：ID=%s VERSION_ID=%s ARCH=%s。' "$1" "$2" "$3" ;; en) printf 'unsupported system: ID=%s VERSION_ID=%s ARCH=%s.' "$1" "$2" "$3" ;; esac ;;
    detect.commands) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '缺少必要命令：%s。' "$1" ;; en) printf 'required command(s) are missing: %s.' "$1" ;; esac ;;
    detect.init) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '未找到受支持的服务管理器：需要 systemd 或 OpenRC。' ;; en) printf 'no supported service manager was found: systemd or OpenRC is required.' ;; esac ;;
    packages.failed) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '无法用 %s 安装运行时软件包。' "$1" ;; en) printf 'could not install the runtime packages with %s.' "$1" ;; esac ;;
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
    install.card.hidden) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '连接信息未显示；请在终端运行 sh socks5.sh show 查看。' ;; en) printf 'connection details were not displayed; run sh socks5.sh show in a terminal to view them.' ;; esac ;;
    install.cancelled) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '操作已取消。' ;; en) printf 'operation cancelled.' ;; esac ;;
    asset.download) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '正在下载并校验 Xray 资产：%s。' "$1" ;; en) printf 'downloading and verifying Xray asset: %s.' "$1" ;; esac ;;
    asset.invalid) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf 'Xray 资产校验失败：%s。' "$1" ;; en) printf 'Xray asset verification failed: %s.' "$1" ;; esac ;;
    cleanup.service) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '无法确认 Xray 服务已停止；已保留安装文件和账户。' ;; en) printf 'could not verify that the Xray service stopped; installation files and account were retained.' ;; esac ;;
    cleanup.download) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '无法删除下载临时目录：%s。' "$1" ;; en) printf 'could not remove temporary download directory: %s.' "$1" ;; esac ;;
    config.invalid) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf 'Xray 配置测试失败；旧配置未改变。' ;; en) printf 'Xray configuration test failed; the old configuration was unchanged.' ;; esac ;;
    transaction.pending) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '存在待处理的恢复目录，拒绝覆盖：%s。' "$1" ;; en) printf 'pending recovery directory must be resolved before updating: %s.' "$1" ;; esac ;;
    transaction.restore) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '无法恢复旧配置和状态；恢复备份保留在 %s。' "$1" ;; en) printf 'could not restore the previous config and state; recovery copies retained at %s.' "$1" ;; esac ;;
    config.external) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '配置文件已被外部修改；拒绝继续。' ;; en) printf 'the configuration was changed externally; refusing to continue.' ;; esac ;;
    config.unreadable) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '无法读取或校验配置文件：%s。' "$1" ;; en) printf 'the configuration file could not be read or validated: %s.' "$1" ;; esac ;;
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
    status.state.running) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '运行中' ;; en) printf 'running' ;; esac ;;
    status.state.stopped) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '已停止' ;; en) printf 'stopped' ;; esac ;;
    status.state.unverified) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '未验证' ;; en) printf 'unverified' ;; esac ;;
    status.heading) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf 'Xray mixed 代理状态：' ;; en) printf 'Xray mixed proxy status:' ;; esac ;;
    status.line) [ "$#" -eq 3 ] || return 1; case "$S5_LANG" in zh) printf '服务：%s；端口：%s；账户：%s；协议：mixed（SOCKS5 + HTTP）；认证：password；UDP：关闭' "$1" "$2" "$3" ;; en) printf 'service: %s; port: %s; username: %s; protocol: mixed (SOCKS5 + HTTP); auth: password; UDP: disabled' "$1" "$2" "$3" ;; esac ;;
    status.version) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf 'Xray 版本：%s' "$1" ;; en) printf 'Xray version: %s' "$1" ;; esac ;;
    show.terminal) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf 'show 仅在真实 TTY 中显示凭据。' ;; en) printf 'show displays credentials only on a real TTY.' ;; esac ;;
    show.heading) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '凭据卡（mixed：SOCKS5 + HTTP）：' ;; en) printf 'credential card (mixed: SOCKS5 + HTTP):' ;; esac ;;
    show.placeholder) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '警告：无法确定服务器的公网地址，请把下面的 %s 替换为该服务器的公网 IPv4。' "$1" ;; en) printf "WARNING: the server's public address could not be determined; replace %s below with the server's public IPv4." "$1" ;; esac ;;
    show.socks) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf 'SOCKS5：%s' "$1" ;; en) printf 'SOCKS5: %s' "$1" ;; esac ;;
    show.http) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf 'HTTP：%s' "$1" ;; en) printf 'HTTP: %s' "$1" ;; esac ;;
    show.warning) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '认证信息会在网络上传输，密码以明文保存在受保护的配置文件中。' ;; en) printf 'credentials are sent on the wire, and the password is stored in cleartext in the protected config file.' ;; esac ;;
    uninstall.residue) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '发现未知或不安全的残留，拒绝卸载：%s。' "$1" ;; en) printf 'refusing uninstall with unknown or unsafe residue: %s.' "$1" ;; esac ;;
    uninstall.confirm) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '确认删除 Xray mixed 代理及其账户？[y/N] ' ;; en) printf 'Remove the Xray mixed proxy and its account? [y/N] ' ;; esac ;;
    uninstall.done) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '卸载完成；系统软件包和防火墙规则未修改。' ;; en) printf 'uninstall completed; system packages and firewall rules were not modified.' ;; esac ;;
    install.confirm) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '确认安装 Xray mixed 代理？[Y/n] ' ;; en) printf 'Install the Xray mixed proxy? [Y/n] ' ;; esac ;;
    update.confirm) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '更新现有 Xray 配置？[y/N] ' ;; en) printf 'Update the existing Xray configuration? [y/N] ' ;; esac ;;
    usage) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '用法：sh socks5.sh [install|status|show|restart|uninstall|language|help]' ;; en) printf 'Usage: sh socks5.sh [install|status|show|restart|uninstall|language|help]' ;; esac ;;
    account.remove.identity) [ "$#" -eq 2 ] || return 1; case "$S5_LANG" in zh) printf '账户身份不匹配：记录值为 %s/%s。' "$1" "$2" ;; en) printf 'account identity mismatch: recorded %s/%s' "$1" "$2" ;; esac ;;
    account.remove.user) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '无法删除服务账户：%s。' "$1" ;; en) printf 'could not remove service account: %s' "$1" ;; esac ;;
    account.remove.user.exists) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '删除后服务账户仍然存在：%s。' "$1" ;; en) printf 'service account still exists after removal: %s' "$1" ;; esac ;;
    account.remove.user.verify) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '无法验证服务账户已删除：%s。' "$1" ;; en) printf 'could not verify service account removal: %s' "$1" ;; esac ;;
    account.remove.group) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '无法删除服务组：%s。' "$1" ;; en) printf 'could not remove service group: %s' "$1" ;; esac ;;
    account.remove.group.before) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '删除前无法验证服务组：%s。' "$1" ;; en) printf 'could not verify service group before removal: %s' "$1" ;; esac ;;
    account.remove.group.exists) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '删除后服务组仍然存在：%s。' "$1" ;; en) printf 'service group still exists after removal: %s' "$1" ;; esac ;;
    account.remove.group.verify) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '无法验证服务组已删除：%s。' "$1" ;; en) printf 'could not verify service group removal: %s' "$1" ;; esac ;;
    uninstall.symlink) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '卸载时拒绝符号链接：%s。' "$1" ;; en) printf 'refusing symlink during uninstall: %s' "$1" ;; esac ;;
    uninstall.file) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '无法删除自有文件：%s。' "$1" ;; en) printf 'could not remove owned file: %s' "$1" ;; esac ;;
    uninstall.notdir) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '自有路径不是目录：%s。' "$1" ;; en) printf 'owned path is not a directory: %s' "$1" ;; esac ;;
    uninstall.nonempty) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '拒绝删除非空自有目录：%s。' "$1" ;; en) printf 'refusing non-empty owned directory: %s' "$1" ;; esac ;;
    uninstall.directory) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '无法删除自有目录：%s。' "$1" ;; en) printf 'could not remove owned directory: %s' "$1" ;; esac ;;
    detect.unzip) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '缺少必要命令：支持 -Z 的 unzip（Info-ZIP）。' ;; en) printf 'required command(s) are missing: unzip with -Z (Info-ZIP).' ;; esac ;;
    usage.unknown) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '未知命令：%s。' "$1" ;; en) printf 'unknown command: %s.' "$1" ;; esac ;;
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
s5_msg_ask() {
    _sma=$(s5_msg "$@") || { s5_msg_fallback "$1"; return 1; }
    # Redirected input or prompts cannot rely on terminal echo for a line break.
    if [ -t 0 ] && [ -t 2 ]; then
        printf '%s' "$_sma" >&2
    else
        printf '%s\n' "$_sma" >&2
    fi
    _sma=''
}

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

s5_language_file_safe() {
    [ -d "${S5_LANG_FILE%/*}" ] && [ ! -L "${S5_LANG_FILE%/*}" ] || return 1
    [ -f "$S5_LANG_FILE" ] && [ ! -L "$S5_LANG_FILE" ] || return 1
    if [ "${S5_SKIP_OWNERSHIP:-0}" != 1 ]; then
        [ "$(stat -c '%u' "$S5_LANG_FILE" 2>/dev/null)" = 0 ] || return 1
    fi
    case "$(stat -c '%a' "$S5_LANG_FILE" 2>/dev/null)" in 600 | 644) ;; *) return 1 ;; esac
}

s5_language_load() {
    s5_language_file_safe || return 1
    [ "$(s5_bytecount "$S5_LANG_FILE")" = 3 ] || return 1
    IFS= read -r S5_LANG <"$S5_LANG_FILE" || return 1
    case "$S5_LANG" in zh | en) export S5_LANG ;; *) S5_LANG=''; return 1 ;; esac
}

s5_language_save() {
    s5_is_root || return 1
    if [ -e "$S5_LANG_FILE" ] || [ -L "$S5_LANG_FILE" ]; then
        s5_language_file_safe || return 1
    fi
    s5_mkdir_parents "${S5_LANG_FILE%/*}" || return 1
    printf '%s\n' "$S5_LANG" | s5_atomic_write "$S5_LANG_FILE" root:root 0644
}

s5_init_language() {
    if [ "$#" -ne 1 ] || [ "$1" != language ]; then
        s5_language_load && return 0
    fi
    s5_select_language || return 1
    if ! s5_language_save; then
        s5_msg_warn lang.unsaved
        [ "${1:-}" != language ]
    fi
}

s5_osrel_get() {
    [ -r "$1" ] || return 1
    sed -n "s/^$2=//p" "$1" | tail -n 1 | tr -d '\r' | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

s5_ver_ge() {
    _svg_left=$1
    _svg_right=$2
    while [ -n "$_svg_left" ] || [ -n "$_svg_right" ]; do
        _svg_left_part=${_svg_left%%.*}
        _svg_right_part=${_svg_right%%.*}
        [ -n "$_svg_left_part" ] || _svg_left_part=0
        [ -n "$_svg_right_part" ] || _svg_right_part=0
        case "$_svg_left_part:$_svg_right_part" in *[!0-9:]* | *::* | :* | *:) return 2 ;; esac
        _svg_left_part=${_svg_left_part#"${_svg_left_part%%[!0]*}"}
        _svg_right_part=${_svg_right_part#"${_svg_right_part%%[!0]*}"}
        [ -n "$_svg_left_part" ] || _svg_left_part=0
        [ -n "$_svg_right_part" ] || _svg_right_part=0
        [ "${#_svg_left_part}" -le 18 ] && [ "${#_svg_right_part}" -le 18 ] || return 2
        if [ "${#_svg_left_part}" -gt "${#_svg_right_part}" ]; then return 0; fi
        if [ "${#_svg_left_part}" -lt "${#_svg_right_part}" ]; then return 1; fi
        if [ "$_svg_left_part" != "$_svg_right_part" ]; then
            _svg_result=$(awk -v a="$_svg_left_part" -v b="$_svg_right_part" 'BEGIN { print (a > b) ? 0 : 1 }')
            [ "$_svg_result" = 0 ] && return 0
            return 1
        fi
        case "$_svg_left" in *.*) _svg_left=${_svg_left#*.}; [ -n "$_svg_left" ] || return 2 ;; *) _svg_left='' ;; esac
        case "$_svg_right" in *.*) _svg_right=${_svg_right#*.}; [ -n "$_svg_right" ] || return 2 ;; *) _svg_right='' ;; esac
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

# The selected backend owns one service-definition path. Writers also call this
# boundary so standalone generation cannot reuse a previous backend's path.
s5_select_service_artifact() {
    S5_SERVICE_ARTIFACT=''
    case "${S5_INIT:-systemd}" in
    systemd) S5_SERVICE_ARTIFACT=$S5_UNITDIR/$S5_PROJECT.service ;;
    openrc) S5_SERVICE_ARTIFACT=$S5_INITSCRIPT ;;
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
        S5_INIT=systemd
        ;;
    debian)
        s5_ver_ge "$S5_OS_VERSION_ID" 12 || return 1
        S5_OS_FAMILY=debian
        S5_INIT=systemd
        ;;
    alpine)
        s5_ver_ge "$S5_OS_VERSION_ID" 3.20 || return 1
        S5_OS_FAMILY=alpine
        S5_INIT=openrc
        ;;
    centos)
        s5_ver_ge "$S5_OS_VERSION_ID" 9 || return 1
        S5_OS_FAMILY=el
        S5_INIT=systemd
        ;;
    *) return 1 ;;
    esac
    s5_select_service_artifact
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
    _siic_oldifs=$IFS
    IFS=.
    set -f
    # Split the canonical address at dots with pathname expansion disabled.
    # shellcheck disable=SC2086
    set -- $1
    set +f
    IFS=$_siic_oldifs
    [ "$#" -eq 4 ] || return 1
    for _siic_octet in "$1" "$2" "$3" "$4"; do
        case "$_siic_octet" in '' | *[!0-9]*) return 1 ;; esac
        [ "${#_siic_octet}" -le 3 ] || return 1
        case "$_siic_octet" in 0 | 0*) [ "$_siic_octet" = 0 ] || return 1 ;; esac
        [ "$_siic_octet" -le 255 ] 2>/dev/null || return 1
    done
    return 0
}

s5_ipv4_is_public() {
    # Conservative: every IANA special-purpose range is refused, so a private,
    # CGNAT, loopback or documentation address is never advertised as an
    # Internet-reachable host.
    #
    # This is the advertise-safety check for the card's own detected address. It is
    # deliberately separate from the tunnel destination boundary in s5_config_render
    # and shares no encoding with it: the two answer different questions (is this
    # host safe to advertise as reachable, vs. may the tunnel egress to this
    # destination) over overlapping-but-different sets, so neither derives from the
    # other. This one adds the documentation/benchmarking ranges the boundary omits
    # and is IPv4-only.
    s5_ipv4_is_canonical "${1:-}" || return 1
    _siip_first=${1%%.*}
    _siip_rest=${1#*.}
    _siip_second=${_siip_rest%%.*}
    _siip_rest=${_siip_rest#*.}
    _siip_third=${_siip_rest%%.*}
    _siip_rest=''
    [ "$_siip_first" -eq 0 ] && return 1
    [ "$_siip_first" -eq 10 ] && return 1
    [ "$_siip_first" -eq 127 ] && return 1
    [ "$_siip_first" -ge 224 ] && return 1
    case "$_siip_first.$_siip_second" in
    100.6[4-9] | 100.[7-9]? | 100.1[01]? | 100.12[0-7]) return 1 ;;
    169.254) return 1 ;;
    172.1[6-9] | 172.2? | 172.3[01]) return 1 ;;
    192.168) return 1 ;;
    198.18 | 198.19) return 1 ;;
    esac
    case "$_siip_first.$_siip_second.$_siip_third" in
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
    # Keep only decimal digits: BusyBox tr can treat '[:space:]' literally,
    # leaving od's leading spaces in a value used for shell arithmetic.
    _srandport_value=$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -cd '0-9') || return 1
    case "$_srandport_value" in '' | *[!0-9]*) return 1 ;; esac
    printf '%s' "$((20000 + (_srandport_value % 40001)))"
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
        s5_msg_ask input.port || return 1
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
        s5_msg_ask input.username || return 1
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
        s5_msg_ask input.password || return 1
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
    _smp_parent=${1%/*}
    [ "$_smp_parent" != "$1" ] || _smp_parent=.
    s5_mkdir_parents "$_smp_parent" || return 1
    mkdir "$1" || return 1
    chmod 0755 "$1"
}

s5_mkdir_private() {
    if [ -L "$1" ]; then return 1; fi
    _smpriv_parent=${1%/*}
    [ "$_smpriv_parent" != "$1" ] || _smpriv_parent=.
    if [ "$_smpriv_parent" != "$1" ]; then
        s5_mkdir_parents "$_smpriv_parent" || return 1
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

# The working directory pins the inspected directory inode. Another reclaimer
# may remove it and acquire a new lock at the same pathname; relative unlinks
# must never touch that replacement. Its owner (or publication temp) prevents
# the final rmdir from removing a lock that is already held.
s5_lock_reclaim() (
    [ -d "$S5_LOCKDIR" ] && [ ! -L "$S5_LOCKDIR" ] || return 1
    CDPATH='' cd -P "$S5_LOCKDIR" || return 1
    [ -f owner ] && [ ! -L owner ] || return 1
    {
        IFS= read -r _slrboot && IFS= read -r _slrpid && ! IFS= read -r _slrextra
    } <owner || return 1
    [ -n "$_slrboot" ] && [ -z "$_slrextra" ] || return 1
    case "$_slrpid" in '' | *[!0-9]* | 0) return 1 ;; esac
    _slrnow=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || uname -n)
    if [ "$_slrboot" != "$_slrnow" ]; then
        :
    elif ! kill -0 "$_slrpid" 2>/dev/null; then
        :
    else
        return 1
    fi
    rm -f owner .owner.* 2>/dev/null || return 1
    rmdir "$S5_LOCKDIR" 2>/dev/null || return 1
    return 0
)

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

s5_fail_locked() {
    # The error-path tail shared by the locked commands: release the lock without
    # letting a release failure mask the original error, then report the given
    # message (a msg key + args, or nothing) and fail. The caller still issues its
    # own `return`, since a return cannot cross a function boundary -- this only
    # collapses the repeated release-then-report shape into one place.
    s5_lock_release || true
    [ "$#" -eq 0 ] || s5_msg_err "$@"
    return 1
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
    #
    # test_xray_docs.sh compares this boundary and tests/protocol/start_engine.sh
    # against the independent tests/fixtures/denied-destinations.txt set.
    # It is a separate concern from
    # s5_ipv4_is_public (the advertise-safety check for the card's own address),
    # which encodes a different set for a different purpose.
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

# Byte size of $1 as bare digits, with wc's leading padding and trailing newline
# stripped (the same digit-only sanitiser used elsewhere for wc output).
s5_bytecount() { wc -c <"$1" | tr -cd '0-9'; }

# Callers retain their own diagnostic policy for unreadable artifacts.
s5_sha256() { sha256sum "$1" | awk '{print $1}'; }

s5_fetch_archive() {
    # $1: destination path for the release archive. Acquire it (a local fixture in
    # test mode, else the pinned HTTPS download) and accept it only as the pinned
    # artifact byte for byte -- exact size and SHA-256.
    if [ -n "${S5_TEST_ASSET_PATH:-}" ]; then
        cp "$S5_TEST_ASSET_PATH" "$1" || return 1
    else
        s5_msg_print asset.download "$S5_ASSET_NAME" >&2
        # --proto/--proto-redir pin HTTPS, --max-time caps the transfer, and
        # --max-filesize aborts mid-stream only when the response advertises a
        # Content-Length over the limit -- a chunked reply with no length escapes it.
        # The exact-size and SHA-256 checks below are therefore the authoritative
        # acceptance: they reject anything that is not the pinned artifact byte for
        # byte, and the size check also bounds what a length-less reply left on disk.
        curl -fsSL --proto '=https' --proto-redir '=https' \
            --max-time 120 --max-filesize "$((S5_ASSET_SIZE + 1))" \
            -o "$1" "$S5_XRAY_BASE/$S5_ASSET_NAME" || {
            s5_msg_err asset.invalid download
            return 1
        }
        [ "$(s5_bytecount "$1")" -le "$((S5_ASSET_SIZE + 1))" ] || {
            s5_msg_err asset.invalid size
            return 1
        }
    fi
    [ "$(s5_bytecount "$1")" = "$S5_ASSET_SIZE" ] || { s5_msg_err asset.invalid size; return 1; }
    [ "$(s5_sha256 "$1")" = "$S5_ASSET_SHA256" ] || { s5_msg_err asset.invalid sha256; return 1; }
}

s5_verify_archive_members() {
    # $1: the accepted archive. $2: scratch path for its member listing. Refuse any
    # archive that is not exactly {xray, geoip.dat, geosite.dat, LICENSE, README.md},
    # carries a path-bearing or traversing member name, or holds a member whose Unix
    # mode is not a regular 10xx file.
    unzip -Z1 "$1" >"$2" 2>/dev/null || { s5_msg_err asset.invalid members; return 1; }
    [ "$(grep -cxF xray "$2" || true)" = 1 ] || { s5_msg_err asset.invalid members; return 1; }
    for _svam_entry in geoip.dat geosite.dat LICENSE README.md; do
        [ "$(grep -cxF "$_svam_entry" "$2" || true)" = 1 ] || { s5_msg_err asset.invalid members; return 1; }
    done
    [ "$(wc -l <"$2" | tr -cd '0-9')" = 5 ] || { s5_msg_err asset.invalid members; return 1; }
    while IFS= read -r _svam_entry; do
        case "$_svam_entry" in '' | */* | *..* | *\\*) s5_msg_err asset.invalid members; return 1 ;; esac
    done <"$2"
    if ! unzip -Z -v "$1" 2>/dev/null |
        awk '/Unix file attributes/ { seen++; if ($4 !~ /^\(10[0-7]/) bad=1 }
             END { exit (seen == 5 && !bad) ? 0 : 1 }'; then
        s5_msg_err asset.invalid members
        return 1
    fi
}

s5_extract_binary() {
    # $1: the verified archive. $2: scratch path for the extracted xray. Accept the
    # binary only at the pinned size and SHA-256 and an arch-matching ELF type, then
    # install it atomically at $S5_BIN and record its digest.
    unzip -p "$1" xray >"$2" 2>/dev/null || return 1
    [ "$(s5_bytecount "$2")" = "$S5_ASSET_BINARY_SIZE" ] || { s5_msg_err asset.invalid binary-size; return 1; }
    [ "$(s5_sha256 "$2")" = "$S5_ASSET_BINARY_SHA256" ] || { s5_msg_err asset.invalid binary-sha256; return 1; }
    chmod 0755 "$2" || return 1
    _seb_file=$(file -b "$2" 2>/dev/null) || return 1
    case "$S5_ARCHNAME:$_seb_file" in
    amd64:*'ELF 64-bit LSB executable, x86-64'*) ;;
    arm64:*'ELF 64-bit LSB executable, ARM aarch64'*) ;;
    *) s5_msg_err asset.invalid architecture; return 1 ;;
    esac
    _seb_temp=$(mktemp "$S5_PREFIX/.xray.XXXXXX") || return 1
    chmod 0755 "$_seb_temp" || { rm -f "$_seb_temp"; return 1; }
    cat "$2" >"$_seb_temp" || { rm -f "$_seb_temp"; return 1; }
    mv -f "$_seb_temp" "$S5_BIN" || { rm -f "$_seb_temp"; return 1; }
    S5_CREATED_BIN=1
    S5_BINARY_SHA256=$(s5_sha256 "$S5_BIN")
    [ "$S5_BINARY_SHA256" = "$S5_ASSET_BINARY_SHA256" ]
}

s5_download_engine() {
    s5_asset_select || return 1
    if [ ! -d "$S5_PREFIX" ]; then S5_CREATED_PREFIX=1; fi
    s5_mkdir_private "$S5_PREFIX" || return 1
    [ -n "$S5_WORKDIR" ] || S5_WORKDIR=$(mktemp -d "$(s5_tmp_base)/xray-socks5-download.XXXXXX") || return 1
    _sdezip=$S5_WORKDIR/$S5_ASSET_NAME
    s5_fetch_archive "$_sdezip" || return 1
    s5_verify_archive_members "$_sdezip" "$S5_WORKDIR/members" || return 1
    s5_extract_binary "$_sdezip" "$S5_WORKDIR/xray" || return 1
}

s5_binary_ready() {
    [ -x "$S5_BIN" ] && [ ! -L "$S5_BIN" ] || return 1
    [ "$(s5_sha256 "$S5_BIN" 2>/dev/null)" = "$S5_ASSET_BINARY_SHA256" ]
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

s5_account_tool() {
    if [ "$S5_OS_FAMILY" = alpine ]; then
        case "$1" in
        create-group) addgroup -S "$S5_SERVICE_GROUP" ;;
        create-user) adduser -S -D -H -h /nonexistent -G "$S5_SERVICE_GROUP" -s "$(s5_nologin_path)" "$S5_SERVICE_USER" ;;
        delete-user) deluser "$S5_SERVICE_USER" ;;
        delete-group) delgroup "$S5_SERVICE_GROUP" ;;
        *) return 1 ;;
        esac
    else
        case "$1" in
        create-group) groupadd -r "$S5_SERVICE_GROUP" ;;
        create-user) useradd -r -g "$S5_SERVICE_GROUP" -M -d /nonexistent -s "$(s5_nologin_path)" "$S5_SERVICE_USER" ;;
        delete-user) userdel "$S5_SERVICE_USER" ;;
        delete-group) groupdel "$S5_SERVICE_GROUP" ;;
        *) return 1 ;;
        esac
    fi >/dev/null 2>&1
}

s5_account_create() {
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
    s5_account_tool create-group || { s5_msg_err account.failed "$S5_SERVICE_GROUP"; return 1; }
    S5_CREATED_GROUP=1
    if ! s5_account_tool create-user; then
        s5_msg_err account.failed "$S5_SERVICE_USER"
        if s5_account_tool delete-group; then S5_CREATED_GROUP=0; fi
        return 1
    fi
    S5_CREATED_USER=1
    S5_ACCOUNT_UID=$(id -u "$S5_SERVICE_USER" 2>/dev/null) || return 1
    S5_ACCOUNT_GID=$(id -g "$S5_SERVICE_USER" 2>/dev/null) || return 1
    return 0
}

s5_account_identity() {
    [ -n "$S5_ACCOUNT_UID" ] && [ -n "$S5_ACCOUNT_GID" ] || return 1
    _saiu=$(id -u "$S5_SERVICE_USER" 2>/dev/null) || return 1
    _saig=$(id -g "$S5_SERVICE_USER" 2>/dev/null) || return 1
    [ "$_saiu" = "$S5_ACCOUNT_UID" ] && [ "$_saig" = "$S5_ACCOUNT_GID" ] || return 1
    # The group is removed by name at uninstall, so on every backend -- not only
    # Alpine -- the name must still resolve to the recorded GID. A group that drifted
    # to a new GID, or a same-named group created by something else, must not be
    # deleted: SPEC 7 removes only the resources this installation recorded.
    _saig_named=$(getent group "$S5_SERVICE_GROUP" 2>/dev/null | awk -F: 'NR == 1 { print $3 }') || return 1
    [ "$_saig_named" = "$S5_ACCOUNT_GID" ]
}

s5_account_remove() {
    if [ -n "$S5_ACCOUNT_UID" ] && [ -n "$S5_ACCOUNT_GID" ]; then
        s5_account_identity || {
            s5_msg_warn account.remove.identity "$S5_ACCOUNT_UID" "$S5_ACCOUNT_GID"
            s5_msg_err account.identity
            return 1
        }
    elif [ "$S5_CREATED_USER" != 1 ] && [ "$S5_CREATED_GROUP" != 1 ]; then
        s5_msg_err account.identity
        return 1
    fi
    if [ "$S5_CREATED_USER" = 1 ] || [ -n "$S5_ACCOUNT_UID" ]; then
        s5_account_tool delete-user || {
            s5_msg_warn account.remove.user "$S5_SERVICE_USER"
            return 1
        }
        s5_getent_state passwd "$S5_SERVICE_USER"
        case $? in
        1) ;;
        0) s5_msg_warn account.remove.user.exists "$S5_SERVICE_USER"; return 1 ;;
        *) s5_msg_warn account.remove.user.verify "$S5_SERVICE_USER"; return 1 ;;
        esac
    fi
    if [ "$S5_CREATED_GROUP" = 1 ] || [ -n "$S5_ACCOUNT_GID" ]; then
        s5_getent_state group "$S5_SERVICE_GROUP"
        case $? in
        0)
            if ! s5_account_tool delete-group; then
                [ "$S5_OS_FAMILY" = alpine ] || s5_msg_warn account.remove.group "$S5_SERVICE_GROUP"
                return 1
            fi
            ;;
        1) ;;
        *) s5_msg_warn account.remove.group.before "$S5_SERVICE_GROUP"; return 1 ;;
        esac
        s5_getent_state group "$S5_SERVICE_GROUP"
        case $? in
        1) ;;
        0) s5_msg_warn account.remove.group.exists "$S5_SERVICE_GROUP"; return 1 ;;
        *) s5_msg_warn account.remove.group.verify "$S5_SERVICE_GROUP"; return 1 ;;
        esac
    fi
    S5_CREATED_USER=0
    S5_CREATED_GROUP=0
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
    s5_select_service_artifact || return 1
    case "${S5_INIT:-systemd}" in
    openrc)
        if [ ! -d "$S5_INITSCRIPTDIR" ]; then
            s5_mkdir_parents "$S5_INITSCRIPTDIR" || return 1
        fi
        s5_atomic_write "$S5_SERVICE_ARTIFACT" root:root 0755 <<UNIT
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
        ;;
    systemd)
        if [ ! -d "$S5_UNITDIR" ]; then
            s5_mkdir_parents "$S5_UNITDIR" || return 1
        fi
        s5_atomic_write "$S5_SERVICE_ARTIFACT" root:root 0644 <<UNIT
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

# Queries are for individual callers; state loading uses one validated snapshot.
s5_state_get() {
    awk -F '\t' -v k="$1" '$1 == k { print $2; exit }' "$S5_STATE" 2>/dev/null
}

# Emit one value per line in this fixed order only after the whole schema passes.
# Values cannot contain tabs/newlines; read -r consumes them as data, never code.
# The legacy schema omits family, represented by an empty line in that slot.
s5_state_parse() {
    awk -F '\t' '
        BEGIN {
            count=split("engine release commit asset archive_size archive_sha256 binary_size binary_sha256 protocol auth udp listen port username os arch family init account_uid account_gid config_sha256 unit_sha256 status", keys, " ")
            for (i=1; i<=count; i++) allowed[keys[i]]=1
            valid=1
        }
        {
            if (NF != 2 || $1 == "" || $2 == "") valid=0
            if (!($1 in allowed) || seen[$1]++) valid=0
            values[$1]=$2
        }
        END {
            if (NR != 22 && NR != 23) valid=0
            if (NR == 22 && ("family" in seen)) valid=0
            if (!valid) exit 1
            for (i=1; i<=count; i++) print values[keys[i]]
        }
    ' "$S5_STATE" 2>/dev/null
}

s5_state_write() {
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

s5_verify_installed_artifacts() {
    # Every recorded artifact must still be present, a non-symlink regular file, and
    # hash-identical to what the state file pinned. A config-hash mismatch returns 2
    # -- the state is intact and the config is the file that changed, which
    # s5_report_state_load renders differently from an invalid state -- while every
    # other failure returns 1.
    [ -f "$S5_SERVICE_ARTIFACT" ] && [ ! -L "$S5_SERVICE_ARTIFACT" ] || return 1
    [ "$(s5_sha256 "$S5_SERVICE_ARTIFACT" 2>/dev/null)" = "$S5_UNIT_SHA256" ] || return 1
    [ -f "$S5_CFG" ] && [ ! -L "$S5_CFG" ] || return 1
    [ "$(s5_sha256 "$S5_CFG" 2>/dev/null)" = "$S5_CONFIG_SHA256" ] || return 2
    [ -f "$S5_BIN" ] && [ ! -L "$S5_BIN" ] && [ -x "$S5_BIN" ] || return 1
    [ "$(s5_sha256 "$S5_BIN" 2>/dev/null)" = "$S5_BINARY_SHA256" ] || return 1
    return 0
}

s5_state_load() {
    _sload_current_family=$S5_OS_FAMILY
    _sload_current_init=$S5_INIT
    [ -f "$S5_STATE" ] && [ ! -L "$S5_STATE" ] || return 1
    [ "$(stat -c '%a' "$S5_STATE" 2>/dev/null)" = 600 ] || return 1
    _sload_fields=$(s5_state_parse) || return 1
    [ -d "$S5_PREFIX" ] && [ ! -L "$S5_PREFIX" ] || return 1
    [ -d "$S5_SYSCONFDIR" ] && [ ! -L "$S5_SYSCONFDIR" ] || return 1
    [ -d "$S5_STATEDIR" ] && [ ! -L "$S5_STATEDIR" ] || return 1
    # Separate reads preserve the empty legacy family and literal whitespace or
    # backslashes. A pipeline would lose assignments in a subshell on POSIX sh.
    {
        IFS= read -r _sload_engine
        IFS= read -r _sload_release
        IFS= read -r _sload_commit
        IFS= read -r _sload_asset
        IFS= read -r _sload_size
        IFS= read -r _sload_sha
        IFS= read -r _sload_binsize
        IFS= read -r _sload_binsha
        IFS= read -r _sload_protocol
        IFS= read -r _sload_auth
        IFS= read -r _sload_udp
        IFS= read -r S5_LISTEN
        IFS= read -r S5_PORT
        IFS= read -r S5_USERNAME
        IFS= read -r _sload_os
        IFS= read -r S5_ARCHNAME
        IFS= read -r S5_OS_FAMILY
        IFS= read -r S5_INIT
        IFS= read -r S5_ACCOUNT_UID
        IFS= read -r S5_ACCOUNT_GID
        IFS= read -r S5_CONFIG_SHA256
        IFS= read -r S5_UNIT_SHA256
        IFS= read -r _sload_status
    } <<STATE_FIELDS
$_sload_fields
STATE_FIELDS
    _sload_fields=''
    [ "$_sload_engine" = xray ] || return 1
    [ "$_sload_release" = "$S5_XRAY_VERSION" ] || return 1
    [ "$_sload_commit" = "$S5_XRAY_COMMIT" ] || return 1
    [ "$_sload_protocol" = mixed ] || return 1
    [ "$_sload_auth" = password ] || return 1
    [ "$_sload_udp" = false ] || return 1
    [ "$_sload_status" = complete ] || return 1
    s5_asset_select || return 1
    [ "$S5_ASSET_NAME" = "$_sload_asset" ] &&
        [ "$S5_ASSET_SIZE" = "$_sload_size" ] &&
        [ "$S5_ASSET_SHA256" = "$_sload_sha" ] &&
        [ "$S5_ASSET_BINARY_SIZE" = "$_sload_binsize" ] &&
        [ "$S5_ASSET_BINARY_SHA256" = "$_sload_binsha" ] || return 1
    S5_BINARY_SHA256=$_sload_binsha
    # The recorded family is cross-checked like the init is below. debian and el
    # share the systemd unit path, so the init check alone accepts a state file
    # written on the other one, and the family is what picks the package manager
    # an update installs from. Legacy state implies Debian; apply that fallback
    # before comparing so an absent family cannot bypass host-family verification.
    if [ -z "$S5_OS_FAMILY" ]; then
        case "$S5_INIT" in
        systemd) S5_OS_FAMILY=debian ;;
        *) return 1 ;;
        esac
    fi
    if [ -n "$_sload_current_family" ]; then
        [ "$S5_OS_FAMILY" = "$_sload_current_family" ] || return 1
    fi
    [ -n "$_sload_current_init" ] && [ "$_sload_current_init" = "$S5_INIT" ] || return 1
    s5_backend_supported || return 1
    s5_select_service_artifact || return 1
    s5_valid_port "$S5_PORT" && s5_valid_username "$S5_USERNAME" && s5_ipv4_is_canonical "$S5_LISTEN" || return 1
    s5_verify_installed_artifacts
    _sload_result=$?
    [ "$_sload_result" -eq 0 ] || return "$_sload_result"
    s5_account_identity || return 1
    return 0
}

s5_verify_protocols() {
    python3 - "$1" "$2" <<'PY'
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
    # Keep the reason, not just the type: eleven distinct RuntimeError messages and
    # BoundaryBypassed("loopback reached") otherwise collapse to one word, so the
    # operator cannot tell an auth failure from a boundary bypass. Every raise site
    # uses a fixed literal that never carries the credential, so naming the reason
    # costs no secrecy.
    reason = str(exc) or type(exc).__name__
    raise SystemExit("data-plane verification failed: %s: %s"
                     % (type(exc).__name__, reason))
finally:
    stop.set()
PY
}

s5_verify_dataplane() {
    # Local checks prove authentication and refusal; successful public traffic is proven in CI.
    _svd=0
    if [ "${S5_TEST_MODE:-0}" = 1 ]; then
        if [ -n "${S5_PROTOCOL_VERIFY:-}" ]; then
            "$S5_PROTOCOL_VERIFY" "$S5_PORT"
            _svd=$?
        fi
    else
        _svpf=$(mktemp "${S5_WORKDIR:-${S5_ROOTDIR:-/var/tmp}}/.s5pass.XXXXXX") || return 1
        # Restart has no workdir, so signal cleanup must track this credential file explicitly.
        S5_VERIFY_TEMP=$_svpf
        chmod 0600 "$_svpf" || { rm -f "$_svpf"; S5_VERIFY_TEMP=''; return 1; }
        printf '%s\n%s\n' "$S5_USERNAME" "$S5_PASSWORD" >"$_svpf" || { rm -f "$_svpf"; S5_VERIFY_TEMP=''; return 1; }
        s5_verify_protocols "$S5_PORT" "$_svpf"
        _svd=$?
        rm -f "$_svpf"
        S5_VERIFY_TEMP=''
    fi
    [ "$_svd" -eq 0 ] || { s5_msg_err service.unverified "$S5_PORT"; return 1; }
    return 0
}

s5_service_state() {
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
    s5_service_state
    _sosactive=$?
    [ "$_sosactive" -eq 0 ] && return 0
    return "$_sosrc"
}

s5_svc() {
    # The single place that branches on the init backend for the lifecycle verbs.
    # Each of start/stop/restart/enable/disable maps to one backend command, so the
    # backend decision is made once here rather than repeated per verb. start keeps
    # OpenRC's idempotent fallback (s5_openrc_start); s5_service_state and
    # s5_listener_state stay separate, since each carries a backend-specific
    # exit-code contract rather than this shared verb switch.
    if [ "$S5_INIT" = openrc ]; then
        case "$1" in
        start) s5_openrc_start start ;;
        stop) rc-service "$S5_PROJECT" stop ;;
        restart) rc-service "$S5_PROJECT" restart ;;
        enable) rc-update add "$S5_PROJECT" default >/dev/null 2>&1 ;;
        disable) rc-update del "$S5_PROJECT" default >/dev/null 2>&1 ;;
        reload) return 0 ;;
        *) return 1 ;;
        esac
    else
        case "$1" in
        start) systemctl start "$S5_PROJECT.service" >/dev/null 2>&1 ;;
        stop) systemctl stop "$S5_PROJECT.service" >/dev/null 2>&1 ;;
        restart) systemctl restart "$S5_PROJECT.service" >/dev/null 2>&1 ;;
        enable) systemctl enable "$S5_PROJECT.service" >/dev/null 2>&1 ;;
        disable) systemctl disable "$S5_PROJECT.service" >/dev/null 2>&1 ;;
        reload) systemctl daemon-reload >/dev/null 2>&1 ;;
        *) return 1 ;;
        esac
    fi
}

s5_wait_stopped() {
    _swsi=0
    while [ "$_swsi" -lt 15 ]; do
        s5_service_state
        case $? in 1) return 0 ;; 0 | 2) ;; *) return 2 ;; esac
        _swsi=$((_swsi + 1))
        sleep 1
    done
    return 1
}

s5_listener_state() {
    _slsport=${1:-$S5_PORT}
    if [ "${S5_TEST_MODE:-0}" = 1 ]; then
        if [ -n "${S5_LISTENER_PROBE:-}" ]; then
            "$S5_LISTENER_PROBE" "$S5_LISTEN" "$_slsport"
            return $?
        fi
        if [ -n "${S5_PORT_PROBE:-}" ]; then
            "$S5_PORT_PROBE" "$_slsport"
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
        read -r _slstate _slignored _slignored _sladdr _slignored <<EOF
$_slrow
EOF
        case "$_sladdr" in
        "$S5_LISTEN:$_slsport") ;;
        "0.0.0.0:$_slsport")
            [ "$S5_LISTEN" = 0.0.0.0 ] || continue
            ;;
        "*:$_slsport")
            [ "$S5_LISTEN" = 0.0.0.0 ] || continue
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
        s5_listener_state "$_swlp"
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
    S5_CREATED_TRANSACTION=0
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

s5_cleanup_download() {
    [ -n "$S5_WORKDIR" ] || return 0
    if ! rm -rf "$S5_WORKDIR" 2>/dev/null; then
        s5_msg_err cleanup.download "$S5_WORKDIR"
        return 1
    fi
    S5_WORKDIR=''
}

s5_cleanup() {
    [ "$S5_IN_CLEANUP" = 1 ] && return 0
    S5_IN_CLEANUP=1
    trap '' HUP INT TERM
    _sclstatus=0
    if [ "$S5_INSTALL_COMPLETE" != 1 ] && [ "$S5_SERVICE_STARTED" = 1 ]; then
        if ! s5_svc stop || ! s5_wait_stopped; then
            s5_msg_err cleanup.service
            _sclstatus=1
        fi
    fi
    if [ "$S5_INSTALL_COMPLETE" != 1 ] && [ "$_sclstatus" -eq 0 ]; then
        # Whether this run owns the service's runtime files has to be decided
        # before S5_SERVICE_STARTED is cleared just below.
        _sclruntime=0
        if [ "$S5_SERVICE_STARTED" = 1 ] || [ "$S5_CREATED_UNIT" = 1 ]; then
            _sclruntime=1
        fi
        S5_SERVICE_STARTED=0
        if [ "$S5_UNIT_ENABLED" = 1 ]; then
            s5_svc disable || true
            s5_svc reload || true
            S5_UNIT_ENABLED=0
        fi
        if [ "$S5_CREATED_UNIT" = 1 ]; then rm -f "$S5_SERVICE_ARTIFACT" 2>/dev/null || true; fi
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
            s5_account_tool delete-group || true
        fi
        # An interrupted atomic write leaves a private temporary behind; the
        # rmdir below, and uninstall later, both refuse a non-empty directory.
        s5_cleanup_own_temps "$S5_SYSCONFDIR" || true
        s5_cleanup_own_temps "$S5_STATEDIR" || true
        # Recovery copies remain until both files have been restored, including
        # when a signal interrupts publication or only one backup is readable.
        if [ "$S5_CONFIG_REPLACED" = 1 ]; then
            s5_update_rollback "$S5_TXNDIR/old.config.json" "$S5_TXNDIR/old.state" || true
        elif [ "$S5_CREATED_TRANSACTION" = 1 ]; then
            s5_cleanup_transaction || true
        fi
        s5_cleanup_own_temps "$S5_PREFIX" || true
        if [ "$S5_CREATED_CONFDIR" = 1 ]; then rmdir "$S5_SYSCONFDIR" 2>/dev/null || true; fi
        if [ "$S5_CREATED_STATEDIR" = 1 ]; then rmdir "$S5_STATEDIR" 2>/dev/null || true; fi
        if [ "$S5_CREATED_PREFIX" = 1 ]; then rmdir "$S5_PREFIX" 2>/dev/null || true; fi
    fi
    # The verifier's credential temp is recorded in S5_VERIFY_TEMP. On the update
    # path it lands in /var/tmp with no S5_WORKDIR to sweep it, so release it here
    # too: s5_on_signal_lock is not the only handler that reaches a live temp, and a
    # successful run has already cleared it, so this is a no-op there.
    s5_release_verify_temp
    s5_cleanup_download || true
    if [ "$S5_LOCK_HELD" = 1 ]; then
        s5_lock_release || true
    fi
    S5_IN_CLEANUP=0
    return "$_sclstatus"
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
    _spkgs_list=''
    command -v curl >/dev/null 2>&1 || _spkgs_list="$_spkgs_list curl ca-certificates"
    # BusyBox provides a stripped unzip without -Z, so a present unzip proves
    # nothing about archive inspection; Info-ZIP is always requested.
    _spkgs_list="$_spkgs_list unzip"
    command -v file >/dev/null 2>&1 || _spkgs_list="$_spkgs_list file"
    command -v python3 >/dev/null 2>&1 || _spkgs_list="$_spkgs_list python3"
    command -v ss >/dev/null 2>&1 || _spkgs_list="$_spkgs_list iproute2"
    printf '%s' "${_spkgs_list# }"
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
    _sird_status=$?
    set +f
    [ "$_sird_status" -eq 0 ] || {
        s5_msg_err packages.failed apk
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
    case "$S5_INIT:$_spcmode" in
    systemd:install | systemd:update)
        [ -d "$S5_ROOTDIR/run/systemd/system" ] || { s5_msg_err detect.init; return 1; }
        ;;
    openrc:install | openrc:update)
        [ -f "$S5_ROOTDIR/run/openrc/softlevel" ] || { s5_msg_err detect.init; return 1; }
        ;;
    esac
    s5_install_runtime_dependencies "$_spcmode" || return 1
    s5_require_commands awk sed grep tr tail head id getent mkdir rmdir rm mv cp cat printf stat sha256sum mktemp ln sleep wc chmod || return 1
    case "$S5_INIT:$_spcmode" in
    openrc:install|openrc:update)
        s5_require_commands addgroup adduser delgroup deluser rc-service rc-update rc-status logger unzip curl file od chown python3 ss || return 1
        ;;
    systemd:install|systemd:update)
        s5_require_commands groupadd groupdel useradd userdel systemctl unzip curl file od chown python3 || return 1
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
            s5_msg_err detect.unzip
            return 1
        }
        ;;
    esac
    s5_asset_select || return 1
    return 0
}

s5_confirm() {
    _sc_answer=''
    if ! { s5_msg_ask "$1.confirm" && IFS= read -r _sc_answer; }; then
        [ "$1" != uninstall ] || s5_fail_locked
        return 1
    fi
    case "$1:$_sc_answer" in
    install: | install:y | install:Y | install:yes | install:YES | install:Yes | update:y | update:Y | uninstall:y | uninstall:Y) return 0 ;;
    esac
    [ "$1" != uninstall ] || s5_lock_release || true
    s5_msg_print install.cancelled
    return 1
}

s5_confirm_install() { s5_confirm install; }
s5_confirm_update() { s5_confirm update; }

s5_restore_transaction() {
    _srtcfg=$1
    _srtstate=$2
    if ! s5_atomic_write "$S5_CFG" "root:$S5_SERVICE_GROUP" 0640 <"$_srtcfg"; then return 1; fi
    if ! s5_atomic_write "$S5_STATE" root:root 0600 <"$_srtstate"; then return 1; fi
    return 0
}

# Explicit failure and EXIT cleanup share the same recovery policy. A failed
# restore leaves the publication flag set so later cleanup cannot discard backups.
s5_update_rollback() {
    if ! s5_restore_transaction "$1" "$2"; then
        s5_msg_err transaction.restore "$S5_TXNDIR"
        return 1
    fi
    S5_SERVICE_STARTED=0
    s5_svc restart || { s5_msg_err service.start; return 1; }
    S5_CONFIG_REPLACED=0
    s5_cleanup_transaction
}

s5_install_new() {
    s5_select_service_artifact || return 1
    if [ -e "$S5_PREFIX" ] || [ -L "$S5_PREFIX" ] ||
        [ -e "$S5_SYSCONFDIR" ] || [ -L "$S5_SYSCONFDIR" ] ||
        [ -e "$S5_STATEDIR" ] || [ -L "$S5_STATEDIR" ] ||
        [ -e "$S5_SERVICE_ARTIFACT" ] || [ -L "$S5_SERVICE_ARTIFACT" ]; then
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
    s5_write_unit || return 1
    S5_CREATED_UNIT=1
    S5_UNIT_SHA256=$(s5_sha256 "$S5_SERVICE_ARTIFACT")
    s5_svc reload || return 1
    s5_svc enable || return 1
    S5_UNIT_ENABLED=1
    # A failed start or a signal can still leave a managed process running.
    S5_SERVICE_STARTED=1
    s5_svc start || { s5_msg_err service.start; return 1; }
    s5_service_state; _sina=$?
    case "$_sina" in 0) ;; 1) s5_msg_err service.start; return 1 ;; *) s5_msg_err service.inactive; return 1 ;; esac
    s5_wait_listening "$S5_PORT"
    case $? in 0) ;; 1) s5_msg_err service.listen "$S5_PORT"; return 1 ;; *) s5_msg_err service.unverified "$S5_PORT"; return 1 ;; esac
    s5_verify_dataplane || return 1
    S5_CONFIG_SHA256=$(s5_sha256 "$S5_CFG")
    s5_state_write || return 1
    S5_INSTALL_COMPLETE=1
    return 0
}

s5_backend_supported() {
    case "$S5_OS_FAMILY:$S5_INIT" in
    alpine:openrc | debian:systemd | el:systemd) return 0 ;;
    *) return 1 ;;
    esac
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
    if [ -e "$S5_TXNDIR" ] || [ -L "$S5_TXNDIR" ]; then
        s5_msg_err transaction.pending "$S5_TXNDIR"
        return 1
    fi
    s5_config_extract || { s5_msg_err config.unreadable "$S5_CFG"; return 1; }
    s5_confirm_update || return 1
    s5_prompt_port || return 1
    s5_prompt_username || return 1
    s5_prompt_password || return 1
    mkdir -m 0700 "$S5_TXNDIR" || return 1
    S5_CREATED_TRANSACTION=1
    _sioldcfg=$S5_TXNDIR/old.config.json
    _sioldstate=$S5_TXNDIR/old.state
    cp "$S5_CFG" "$_sioldcfg" || return 1
    cp "$S5_STATE" "$_sioldstate" || return 1
    chmod 0600 "$_sioldcfg" "$_sioldstate" || return 1
    s5_binary_ready || { s5_msg_err asset.invalid binary; return 1; }
    _siinc=$(s5_write_config_candidate) || return 1
    s5_svc stop || { s5_msg_err service.stop; rm -f "$_siinc"; return 1; }
    s5_wait_stopped
    case $? in 0) ;; *) s5_msg_err service.stop; rm -f "$_siinc"; return 1 ;; esac
    # Mark the publish before performing it, not after. A signal delivered between
    # the mv and the flag would take s5_cleanup down its "nothing published" path,
    # deleting the transaction backup and leaving this run's unverified config live
    # against the old state hash -- unrecoverable. Setting the flag first means a
    # signal anywhere around the rename still finds a restorable transaction. In the
    # remaining gap (flag set, rename not yet done) the old config is still on disk,
    # so the cleanup restore rewrites it with an identical copy and restarts the
    # service this path had already stopped: the correct recovery, not a regression.
    S5_CONFIG_REPLACED=1
    if ! mv -f "$_siinc" "$S5_CFG"; then
        S5_CONFIG_REPLACED=0
        rm -f "$_siinc"
        s5_restore_transaction "$_sioldcfg" "$_sioldstate" || true
        s5_svc start || true
        return 1
    fi
    if ! s5_svc start; then
        s5_update_rollback "$_sioldcfg" "$_sioldstate"
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
    S5_CONFIG_SHA256=$(s5_sha256 "$S5_CFG")
    if ! s5_state_write; then
        s5_update_rollback "$_sioldcfg" "$_sioldstate"
        return 1
    fi
    rm -f "$_sioldcfg" "$_sioldstate"
    rmdir "$S5_TXNDIR" 2>/dev/null || true
    # The flag's lifetime is the transaction's: once there is nothing to roll back
    # to, nothing may try.
    S5_CONFIG_REPLACED=0
    S5_CREATED_TRANSACTION=0
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
        trap - EXIT HUP INT TERM
        return 1
    fi
    _siccleanup=0
    s5_cleanup_download || _siccleanup=$?
    s5_lock_release || return 1
    trap - EXIT HUP INT TERM
    [ "$_siccleanup" -eq 0 ] || return 1
    if [ "$_siupdate" = 1 ]; then s5_msg_print install.updated; else s5_msg_print install.done; fi
    if [ -t 1 ]; then
        s5_render_card || s5_msg_warn install.card.hidden
    else
        s5_msg_print install.card.hidden
    fi
    return 0
}

s5_cmd_status() {
    s5_precheck status || return 1
    s5_lock_acquire || return 1
    s5_trap_lock_only
    s5_state_load
    _ssr=$?
    s5_report_state_load "$_ssr" || { s5_fail_locked; return 1; }
    s5_config_extract || { s5_fail_locked config.unreadable "$S5_CFG"; return 1; }
    s5_service_state
    _ssa=$?
    case "$_ssa" in 0) _ssv=status.state.running ;; 1) _ssv=status.state.stopped ;; *) _ssv=status.state.unverified ;; esac
    s5_msg_print status.heading
    s5_msg_print status.line "$(s5_msg "$_ssv")" "$S5_PORT" "$S5_USERNAME"
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

# Returns a candidate line in S5_PUBLIC_IPV4_CANDIDATE, empty on failure; the
# caller must still validate the address. One hardened request to the fixed
# endpoint: -q so no user or system curlrc can alter it, --noproxy '*' so an
# ambient proxy variable cannot redirect or observe it, IPv4 only, HTTPS only, no
# redirects, bounded, stdin detached. The body is captured to a private file
# rather than through a pipe, because a pipe reports the last command's status
# and would mask curl's own failure. S5_TEST_ADDR_PATH substitutes a local body
# for the request and nothing else, so the parsing below is the same code a real
# response goes through.
s5_read_public_ipv4() {
    S5_PUBLIC_IPV4_CANDIDATE=''
    _sripv4_file=$(mktemp "${TMPDIR:-/tmp}/.s5ip.XXXXXX") || return 1
    if [ "${S5_TEST_MODE:-0}" = 1 ] && [ -n "${S5_TEST_ADDR_PATH:-}" ]; then
        cp "$S5_TEST_ADDR_PATH" "$_sripv4_file" || { rm -f "$_sripv4_file"; _sripv4_file=''; return 1; }
    else
        if ! command -v curl >/dev/null 2>&1; then
            rm -f "$_sripv4_file"
            _sripv4_file=''
            return 1
        fi
        if ! curl -q -4 --noproxy '*' --proto '=https' --fail --silent \
            --connect-timeout 3 --max-time 5 --max-filesize 17 \
            --output "$_sripv4_file" "$S5_ADDR_ENDPOINT" </dev/null 2>/dev/null; then
            rm -f "$_sripv4_file"
            _sripv4_file=''
            return 1
        fi
    fi
    _sripv4_size=$(s5_bytecount "$_sripv4_file" 2>/dev/null)
    case "$_sripv4_size" in '' | *[!0-9]*) _sripv4_size=18 ;; esac
    # The longest address is 15 bytes and one terminator is allowed two, so a
    # larger body cannot be a single address. Checked before the read so an
    # endpoint that ignores --max-filesize cannot stream an unbounded line.
    if [ "$_sripv4_size" -gt 17 ]; then
        rm -f "$_sripv4_file"
        _sripv4_file=''
        _sripv4_size=''
        return 1
    fi
    IFS= read -r S5_PUBLIC_IPV4_CANDIDATE <"$_sripv4_file" 2>/dev/null || true
    rm -f "$_sripv4_file"
    _sripv4_file=''
    # The raw line still carries the CR of a CRLF terminator, so its length is
    # the exact byte count of everything before the LF.
    _sripv4_length=${#S5_PUBLIC_IPV4_CANDIDATE}
    # read leaves that CR on the line, and a command substitution strips trailing
    # newlines but not a CR.
    _sripv4_cr=$(printf 'x\r')
    _sripv4_cr=${_sripv4_cr#x}
    S5_PUBLIC_IPV4_CANDIDATE=${S5_PUBLIC_IPV4_CANDIDATE%"$_sripv4_cr"}
    _sripv4_cr=''
    # The body has to be one line and one optional terminator. Comparing the
    # file's byte count against the raw line plus that terminator rejects a
    # second line, a double terminator and unterminated trailing bytes without
    # enumerating them, which a command substitution cannot do because it strips
    # every trailing newline.
    if [ "$_sripv4_size" -gt "$((_sripv4_length + 1))" ]; then
        S5_PUBLIC_IPV4_CANDIDATE=''
        _sripv4_size=''
        _sripv4_length=''
        return 1
    fi
    _sripv4_size=''
    _sripv4_length=''
    [ -n "$S5_PUBLIC_IPV4_CANDIDATE" ] || return 1
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
    if s5_read_public_ipv4 && s5_ipv4_is_public "$S5_PUBLIC_IPV4_CANDIDATE"; then
        S5_CARD_ADDR=$S5_PUBLIC_IPV4_CANDIDATE
        S5_CARD_KIND=external
        S5_PUBLIC_IPV4_CANDIDATE=''
        return 0
    fi
    S5_PUBLIC_IPV4_CANDIDATE=''
    S5_CARD_ADDR=SERVER_IPV4
    S5_CARD_KIND=placeholder
    return 0
}

# Callers must verify root privileges and a terminal stdout before showing credentials.
s5_render_card() {
    s5_resolve_card_address
    _src_socks="socks5://$S5_USERNAME:$S5_PASSWORD@$S5_CARD_ADDR:$S5_PORT"
    _src_http="http://$S5_USERNAME:$S5_PASSWORD@$S5_CARD_ADDR:$S5_PORT"
    s5_msg_print show.heading || return 1
    case "$S5_CARD_KIND" in
    placeholder) s5_msg_print show.placeholder "$S5_CARD_ADDR" || return 1 ;;
    esac
    s5_msg_print show.socks "$_src_socks" || return 1
    s5_msg_print show.http "$_src_http" || return 1
    s5_msg_print show.warning || return 1
    _src_socks=''
    _src_http=''
    return 0
}

s5_cmd_show() {
    s5_is_root || { s5_msg_err root.required; return 1; }
    if [ ! -t 1 ]; then s5_msg_err show.terminal; return 1; fi
    s5_precheck status || return 1
    s5_lock_acquire || return 1
    s5_trap_lock_only
    s5_state_load
    s5_report_state_load $? || { s5_fail_locked; return 1; }
    s5_config_extract || { s5_fail_locked config.unreadable "$S5_CFG"; return 1; }
    s5_render_card || { s5_fail_locked; return 1; }
    s5_lock_release || return 1
    return 0
}

s5_cmd_restart() {
    s5_precheck restart || return 1
    s5_lock_acquire || return 1
    s5_trap_lock_only
    s5_state_load
    s5_report_state_load $? || { s5_fail_locked; return 1; }
    s5_config_extract || { s5_fail_locked config.unreadable "$S5_CFG"; return 1; }
    s5_config_test "$S5_CFG" || { s5_fail_locked config.invalid; return 1; }
    s5_svc restart || { s5_fail_locked service.start; return 1; }
    s5_wait_listening "$S5_PORT"
    _srr=$?
    if [ "$_srr" -eq 0 ]; then
        # 3 rather than 2: s5_verify_dataplane has already named its own reason,
        # and the case below must not restate it as the vaguer service.unverified.
        s5_verify_dataplane || _srr=3
    fi
    s5_lock_release || return 1
    case "$_srr" in
    0) return 0 ;;
    1) s5_msg_err service.listen "$S5_PORT" ;;
    3) ;;
    *) s5_msg_err service.unverified "$S5_PORT" ;;
    esac
    return 1
}

s5_remove_owned_file() {
    _srof=$1
    [ -e "$_srof" ] || [ -L "$_srof" ] || return 0
    [ -L "$_srof" ] && { s5_msg_warn uninstall.symlink "$_srof"; return 1; }
    rm -f "$_srof" || { s5_msg_warn uninstall.file "$_srof"; return 1; }
    return 0
}

s5_remove_owned_dir() {
    _srod=$1
    [ -e "$_srod" ] || [ -L "$_srod" ] || return 0
    [ -L "$_srod" ] || [ -d "$_srod" ] || { s5_msg_warn uninstall.notdir "$_srod"; return 1; }
    for _sroe in "$_srod"/* "$_srod"/.[!.]* "$_srod"/..?*; do
        if [ -e "$_sroe" ] || [ -L "$_sroe" ]; then
            s5_msg_warn uninstall.nonempty "$_sroe"
            return 1
        fi
    done
    rmdir "$_srod" || { s5_msg_warn uninstall.directory "$_srod"; return 1; }
    return 0
}

s5_uninstall_preflight() {
    for _supdir in "$S5_PREFIX" "$S5_SYSCONFDIR" "$S5_STATEDIR" "$S5_TXNDIR"; do
        [ -e "$_supdir" ] || [ -L "$_supdir" ] || continue
        if [ ! -d "$_supdir" ] || [ -L "$_supdir" ]; then
            s5_msg_err uninstall.residue "$_supdir"
            return 1
        fi
        for _supentry in "$_supdir"/* "$_supdir"/.[!.]* "$_supdir"/..?*; do
            [ -e "$_supentry" ] || [ -L "$_supentry" ] || continue
            _supvalid=0
            case "$_supentry" in
            "$S5_TXNDIR")
                [ -d "$_supentry" ] && [ ! -L "$_supentry" ] || _supvalid=1 ;;
            "$S5_CFG" | "$S5_STATE" | "$S5_BIN" | "$S5_TXNDIR/old.config.json" | "$S5_TXNDIR/old.state" | "$_supdir"/.s5tmp.* | "$_supdir"/.s5new.*)
                [ -f "$_supentry" ] && [ ! -L "$_supentry" ] || _supvalid=1 ;;
            "$_supdir"/.s5state.* | "$_supdir"/.xray.*)
                [ "$_supdir" != "$S5_TXNDIR" ] && [ -f "$_supentry" ] && [ ! -L "$_supentry" ] || _supvalid=1 ;;
            *) _supvalid=1 ;;
            esac
            if [ "$_supvalid" != 0 ]; then
                s5_msg_err uninstall.residue "$_supentry"
                return 1
            fi
        done
    done
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
        # The three directories are not the whole namespace: the service unit lives
        # outside them and so does the account, so a partial cleanup that spared
        # either would otherwise read as "nothing installed".
        s5_select_service_artifact || return 1
        s5_getent_state passwd "$S5_SERVICE_USER"
        _suacct=$?
        if [ -e "$S5_SYSCONFDIR" ] || [ -e "$S5_STATEDIR" ] || [ -e "$S5_PREFIX" ] ||
            [ -e "$S5_SERVICE_ARTIFACT" ] || [ -L "$S5_SERVICE_ARTIFACT" ] || [ "$_suacct" = 0 ]; then
            s5_msg_err state.invalid "$S5_STATE"
            return 1
        fi
        s5_msg_print state.missing "$S5_PROJECT"
        return 0
    fi
    # The state file exists here, so the shared diagnosis reports an invalid state
    # rather than a missing one.
    s5_report_state_load "$_sur" || { s5_fail_locked; return 1; }
    s5_config_extract || { s5_fail_locked config.unreadable "$S5_CFG"; return 1; }
    s5_confirm uninstall || return 1
    s5_uninstall_preflight || { s5_fail_locked; return 1; }
    s5_svc stop || { s5_fail_locked service.stop; return 1; }
    s5_wait_stopped
    case $? in 0) ;; *) s5_fail_locked service.stop; return 1 ;; esac
    s5_account_identity || { s5_fail_locked account.identity; return 1; }
    # Preflight rejects unknown entries before stopping the service. Keep the
    # deletion-time checks too: the operation lock does not exclude outside edits.
    s5_cleanup_own_temps "$S5_SYSCONFDIR" || { s5_fail_locked; return 1; }
    s5_cleanup_own_temps "$S5_STATEDIR" || { s5_fail_locked; return 1; }
    s5_cleanup_own_temps "$S5_PREFIX" || { s5_fail_locked; return 1; }
    s5_cleanup_transaction || { s5_fail_locked; return 1; }
    s5_svc disable || { s5_fail_locked; return 1; }
    s5_remove_owned_file "$S5_SERVICE_ARTIFACT" || { s5_fail_locked; return 1; }
    s5_remove_owned_file "$S5_CFG" || { s5_fail_locked; return 1; }
    s5_remove_owned_file "$S5_BIN" || { s5_fail_locked; return 1; }
    s5_svc reload || { s5_fail_locked; return 1; }
    s5_account_remove || { s5_fail_locked; return 1; }
    s5_remove_owned_file "$S5_STATE" || { s5_fail_locked; return 1; }
    s5_remove_owned_dir "$S5_SYSCONFDIR" || { s5_fail_locked; return 1; }
    s5_remove_owned_dir "$S5_STATEDIR" || { s5_fail_locked; return 1; }
    s5_remove_owned_dir "$S5_PREFIX" || { s5_fail_locked; return 1; }
    s5_lock_release || return 1
    s5_msg_print uninstall.done
    return 0
}

s5_main() {
    s5_init_language "$@" || return 1
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
    language) s5_msg_print lang.saved ;;
    help | -h | --help) s5_msg_print usage ;;
    *) s5_msg_err usage.unknown "$_smcmd"; s5_msg_print usage >&2; return 64 ;;
    esac
}

if [ "${S5_LIB_ONLY:-0}" != 1 ]; then
    s5_main "$@"
    exit $?
fi
