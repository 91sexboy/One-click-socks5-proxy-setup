#!/bin/sh
# xray-only authenticated mixed proxy installer and manager.
# Xray-core supplies the SOCKS5 and HTTP proxy implementations.

umask 077
set +x
set -u

S5_PROJECT=xray-socks5
S5_XRAY_VERSION=v26.3.27
S5_XRAY_COMMIT=d2758a023cd7f4174a5a5fa4ff66e487d4342ba0
S5_XRAY_DISTRIBUTION_TAG=xray-v26.3.27-r1
S5_XRAY_BASE=https://github.com/91sexboy/One-click-socks5-proxy-setup/releases/download/$S5_XRAY_DISTRIBUTION_TAG
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
S5_BINARY_TEMP=''
S5_LOCK_HELD=0
S5_LOCK_TOKEN=''
S5_VERIFY_TEMP=''
S5_PUBLIC_IPV4_CANDIDATE=''
S5_ADVERTISED_ADDR=''
S5_ADVERTISED_KIND=''
S5_ADVERTISED_LOCAL=''
# The service-state message key (a status.state.* catalog key, not text), the
# listener state (0 ready, 1 absent, 2 unobservable), and the exit status the
# service state implies for status and show.
S5_SERVICE_STATE_KEY=''
S5_LISTENER_STATE=2
S5_SERVICE_RC=0
S5_RECORDED_DIGEST=
S5_CONFIG_REPLACED=0
S5_BINARY_REPLACED=0
S5_SERVICE_TOUCHED=0
S5_CREATED_USER=0
S5_CREATED_GROUP=0
S5_CREATED_PREFIX=0
S5_PREFIX_PRIVATE=0
S5_CREATED_CONFDIR=0
S5_CREATED_STATEDIR=0
S5_CREATED_TRANSACTION=0
S5_CREATED_BIN=0
S5_CREATED_CFG=0
S5_CREATED_STATE=0
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
S5_INSTALLED_SCHEMA=''
S5_INSTALLED_RELEASE=''
S5_INSTALLED_COMMIT=''
S5_INSTALLED_DISTRIBUTION_TAG=''
S5_INSTALLED_ASSET_FORMAT=''
S5_INSTALLED_ASSET_NAME=''
S5_INSTALLED_ASSET_SIZE=''
S5_INSTALLED_ASSET_SHA256=''
S5_INSTALLED_BINARY_SIZE=''
S5_INSTALLED_BINARY_SHA256=''
S5_UPDATE_NEEDS_BINARY=0
S5_UNINSTALL_PREFIX_ID=''
S5_UNINSTALL_CONFDIR_ID=''
S5_UNINSTALL_STATEDIR_ID=''
S5_UNINSTALL_SERVICE_ID=''
S5_UNINSTALL_CONFIG_ID=''
S5_UNINSTALL_BINARY_ID=''
S5_UNINSTALL_STATE_ID=''
S5_RCV_INIT=''
# The shell's default field separators -- space, tab and newline -- for
# s5_split_words; the x keeps the command substitution from eating the newline.
S5_WORD_IFS=$(printf ' \t\nx')
S5_WORD_IFS=${S5_WORD_IFS%x}
# Credentials generated or entered from now on use the first set; values read
# back from an installation made before the narrowing may use the wider ones.
S5_CREDENTIAL_CHARS='A-Za-z0-9'
S5_CREDENTIAL_ALPHABET='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
S5_STORED_USERNAME_CHARS='A-Za-z0-9_-'
S5_STORED_PASSWORD_CHARS='A-Za-z0-9._~-'
S5_UNIT_TYPE=''
S5_UNIT_MODE=''
S5_RCV_FAMILY=''
S5_STATE_PRELOADED=0

# The normalized state record, in order. Schema 2 stores exactly these keys, and
# every reader receives them in this order whatever the schema on disk.
S5_STATE_FIELDS='schema engine release commit distribution_tag asset_format asset asset_size'
S5_STATE_FIELDS="$S5_STATE_FIELDS asset_sha256 binary_size binary_sha256 protocol auth udp listen"
S5_STATE_FIELDS="$S5_STATE_FIELDS port username os arch family init account_uid account_gid"
S5_STATE_FIELDS="$S5_STATE_FIELDS config_sha256 unit_sha256 status"
# Schema 1 stored the archive's size and digest instead of the asset's, and no
# distribution tag or format. Legacy is schema 1 without the schema line and
# possibly without family.
S5_STATE_V1_FIELDS='schema engine release commit asset archive_size archive_sha256 binary_size'
S5_STATE_V1_FIELDS="$S5_STATE_V1_FIELDS binary_sha256 protocol auth udp listen port username"
S5_STATE_V1_FIELDS="$S5_STATE_V1_FIELDS os arch family init account_uid account_gid config_sha256"
S5_STATE_V1_FIELDS="$S5_STATE_V1_FIELDS unit_sha256 status"
# The uninstall recovery record as "key:variable", in order. init and family are
# compared with this host's rather than loaded, so they pass through their own
# variables.
S5_RECOVERY_TABLE='phase:S5_UNINSTALL_PHASE init:S5_RCV_INIT family:S5_RCV_FAMILY'
S5_RECOVERY_TABLE="$S5_RECOVERY_TABLE uid:S5_ACCOUNT_UID gid:S5_ACCOUNT_GID"
S5_RECOVERY_TABLE="$S5_RECOVERY_TABLE config_sha256:S5_CONFIG_SHA256"
S5_RECOVERY_TABLE="$S5_RECOVERY_TABLE binary_sha256:S5_INSTALLED_BINARY_SHA256"
S5_RECOVERY_TABLE="$S5_RECOVERY_TABLE unit_sha256:S5_UNIT_SHA256"
S5_RECOVERY_TABLE="$S5_RECOVERY_TABLE prefix_id:S5_UNINSTALL_PREFIX_ID"
S5_RECOVERY_TABLE="$S5_RECOVERY_TABLE confdir_id:S5_UNINSTALL_CONFDIR_ID"
S5_RECOVERY_TABLE="$S5_RECOVERY_TABLE statedir_id:S5_UNINSTALL_STATEDIR_ID"
S5_RECOVERY_TABLE="$S5_RECOVERY_TABLE service_id:S5_UNINSTALL_SERVICE_ID"
S5_RECOVERY_TABLE="$S5_RECOVERY_TABLE config_id:S5_UNINSTALL_CONFIG_ID"
S5_RECOVERY_TABLE="$S5_RECOVERY_TABLE binary_id:S5_UNINSTALL_BINARY_ID"
S5_RECOVERY_TABLE="$S5_RECOVERY_TABLE state_id:S5_UNINSTALL_STATE_ID"
# The uninstall phases in the order uninstall passes through them. Each phase
# names the step that is done or under way, so a recorded phase says exactly
# what recovery still has to do.
S5_UNINSTALL_PHASES='prepared stopped disabled service-artifact-removed config-removed'
S5_UNINSTALL_PHASES="$S5_UNINSTALL_PHASES binary-removed manager-reloaded account-removed"
S5_UNINSTALL_PHASES="$S5_UNINSTALL_PHASES state-finalizing complete"
# The rollback copies a transaction may hold; with the markers below they are
# the only names the transaction directory may contain.
S5_TXN_BACKUPS='old.config.json old.state old.xray old.unit'
S5_TXN_MARKERS='committed rolled-back stopping unit-replacing'

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
    [ -n "${S5_UNINSTALL_INJECT:-}" ] && _sgef="$_sgef S5_UNINSTALL_INJECT"
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
S5_TXN_COMMITTED=$S5_TXNDIR/committed
S5_TXN_ROLLED_BACK=$S5_TXNDIR/rolled-back
S5_TXN_STOPPING=$S5_TXNDIR/stopping
S5_TXN_UNIT_REPLACING=$S5_TXNDIR/unit-replacing
S5_UNINSTALL_STATE=$S5_STATEDIR/uninstall
S5_UNINSTALL_FINAL=$S5_ROOTDIR/var/lib/.xray-socks5-uninstall
S5_PIDFILE=$S5_ROOTDIR/run/$S5_PROJECT.pid
S5_OPENRC_OPTION_DIR=$S5_ROOTDIR/run/openrc/options/$S5_PROJECT

# Redaction covers the password only. The username is deliberately not secret:
# status reports it by design, and it is only 3 characters at the shortest, so
# folding it into this substring replacement would blank unrelated words in an
# engine diagnostic and hide the failure the operator is reading.
s5_redact() {
    if [ -z "${S5_SECRET:-}" ]; then
        printf '%s' "$1"
        return 0
    fi
    { printf '%s\n' "$S5_SECRET"; printf '%s\n' "$1"; } | awk '
        NR == 1 { s=$0; n=length(s); next }
        {
            line=$0; out=""
            while (n > 0) {
                i=index(line,s)
                if (i == 0) break
                out=out substr(line,1,i-1) "<REDACTED>"; line=substr(line,i+n)
            }
            printf "%s%s\n", out, line
        }
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
    input.port.unverified) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '无法确认端口 %s 属于本安装；请明确输入端口。' "$1" ;; en) printf 'could not verify that port %s belongs to this installation; enter a port explicitly.' "$1" ;; esac ;;
    input.port.keep) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '端口 [回车 = 保留当前的 %s]：' "$1" ;; en) printf 'Port [Enter = keep current %s]: ' "$1" ;; esac ;;
    input.port.override) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '端口 [回车 = 使用 S5_LISTEN_PORT]：' ;; en) printf 'Port [Enter = use S5_LISTEN_PORT]: ' ;; esac ;;
    input.port.explicit) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '端口 [请明确输入]：' ;; en) printf 'Port [enter explicitly]: ' ;; esac ;;
    input.username) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '账户名 [回车 = 随机]：' ;; en) printf 'Username [Enter = random]: ' ;; esac ;;
    input.username.invalid) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '账户名必须是 3-32 个字母或数字。' ;; en) printf 'username must be 3-32 letters or digits.' ;; esac ;;
    input.username.keep) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '账户名 [回车 = 保留当前的 %s]：' "$1" ;; en) printf 'Username [Enter = keep current %s]: ' "$1" ;; esac ;;
    input.username.legacy) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '当前账户名含有本版本不再写入的字符，无法保留；请输入新账户名，或回车生成随机值。' ;; en) printf 'the current username contains characters this version no longer writes and cannot be kept; enter a new username, or press Enter to generate one.' ;; esac ;;
    input.password) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '密码（输入时可见）[回车 = 随机]：' ;; en) printf 'Password (visible while typed) [Enter = random]: ' ;; esac ;;
    input.password.invalid) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '密码必须是 12-128 个字母或数字。' ;; en) printf 'password must be 12-128 letters or digits.' ;; esac ;;
    input.password.keep) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '密码（输入时可见）[回车 = 保留当前密码]：' ;; en) printf 'Password (visible while typed) [Enter = keep current]: ' ;; esac ;;
    input.password.legacy) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '当前密码含有本版本不再写入的字符，无法保留；请输入新密码，或回车生成随机值。' ;; en) printf 'the current password contains characters this version no longer writes and cannot be kept; enter a new password, or press Enter to generate one.' ;; esac ;;
    install.start) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '正在安装并验证 Xray mixed 代理……' ;; en) printf 'installing and verifying the Xray mixed proxy...' ;; esac ;;
    install.done) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf 'Xray mixed 代理安装完成。' ;; en) printf 'Xray mixed proxy installation completed.' ;; esac ;;
    install.updated) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '配置已更新，Xray 已重新启动并验证。' ;; en) printf 'configuration updated; Xray restarted and verified.' ;; esac ;;
    install.card.hidden) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '连接信息未显示；请在终端运行 sh socks5.sh show 查看。' ;; en) printf 'connection details were not displayed; run sh socks5.sh show in a terminal to view them.' ;; esac ;;
    openrc.logging.unavailable) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '未发现 /dev/log，Xray 的标准输出和错误日志可能不可用；请在 Alpine 上运行 rc-service syslog start 和 rc-update add syslog default，然后运行 sh socks5.sh restart。' ;; en) printf 'Xray stdout and stderr logging may be unavailable because /dev/log was not found; on Alpine, run rc-service syslog start and rc-update add syslog default, then run sh socks5.sh restart.' ;; esac ;;
    install.cancelled) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '操作已取消。' ;; en) printf 'operation cancelled.' ;; esac ;;
    asset.download) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '正在下载并校验 Xray 资产：%s。' "$1" ;; en) printf 'downloading and verifying Xray asset: %s.' "$1" ;; esac ;;
    asset.invalid) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf 'Xray 资产校验失败：%s。' "$1" ;; en) printf 'Xray asset verification failed: %s.' "$1" ;; esac ;;
    asset.size) [ "$#" -eq 3 ] || return 1; case "$S5_LANG" in zh) printf 'Xray 资产校验失败：%s 为 %s 字节，应为 %s 字节。' "$1" "$2" "$3" ;; en) printf 'Xray asset verification failed: %s is %s bytes, expected %s.' "$1" "$2" "$3" ;; esac ;;
    disk.space) [ "$#" -eq 3 ] || return 1; case "$S5_LANG" in zh) printf '%s 所在文件系统空间不足：需要 %s KiB，仅剩 %s KiB。' "$1" "$2" "$3" ;; en) printf 'not enough space on the filesystem holding %s: %s KiB required, %s KiB available.' "$1" "$2" "$3" ;; esac ;;
    disk.write) [ "$#" -eq 3 ] || return 1; case "$S5_LANG" in zh) printf '无法写完 %s：已写入 %s 字节，应为 %s 字节；文件系统已满或超出配额。' "$1" "$2" "$3" ;; en) printf 'could not write all of %s: %s bytes written of %s; the filesystem is full or over quota.' "$1" "$2" "$3" ;; esac ;;
    digest.candidate) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '无法计算下载资产的 SHA-256：%s。' "$1" ;; en) printf 'could not compute SHA-256 for downloaded asset: %s.' "$1" ;; esac ;;
    digest.failed) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '无法计算已安装资源的 SHA-256：%s。' "$1" ;; en) printf 'could not compute SHA-256 for installed artifact: %s.' "$1" ;; esac ;;
    cleanup.service) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '无法确认 Xray 服务已停止；已保留安装文件和账户。' ;; en) printf 'could not verify that the Xray service stopped; installation files and account were retained.' ;; esac ;;
    cleanup.residue) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '保留了不属于本次运行的临时文件：%s；确认不再需要后可手动删除。' "$1" ;; en) printf 'kept a temporary file this run did not create: %s; remove it manually once it is no longer needed.' "$1" ;; esac ;;
    cleanup.download) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '无法删除下载临时文件：%s。' "$1" ;; en) printf 'could not remove temporary download file: %s.' "$1" ;; esac ;;
    prefix.mode) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '无法将安装目录恢复为 0755：%s；在该权限恢复之前，服务账户无法使用本安装，后续命令也会拒绝执行。' "$1" ;; en) printf 'could not restore installation directory %s to 0755; until that mode is restored the service account cannot use this installation and later commands refuse to run.' "$1" ;; esac ;;
    config.invalid) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf 'Xray 配置测试失败；旧配置未改变。' ;; en) printf 'Xray configuration test failed; the old configuration was unchanged.' ;; esac ;;
    config.invalid.fresh) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf 'Xray 配置测试失败；未安装任何配置。' ;; en) printf 'Xray configuration test failed; no configuration was installed.' ;; esac ;;
    config.invalid.installed) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '已安装的 Xray 配置未通过配置测试；服务未重启。' ;; en) printf 'the installed Xray configuration failed the configuration test; the service was not restarted.' ;; esac ;;
    transaction.pending) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '存在无法自动恢复的待处理恢复目录，已停止操作：%s。' "$1" ;; en) printf 'a pending recovery directory could not be resolved automatically; stopping: %s.' "$1" ;; esac ;;
    transaction.restore) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '无法恢复旧配置和状态；恢复备份保留在 %s。' "$1" ;; en) printf 'could not restore the previous config and state; recovery copies retained at %s.' "$1" ;; esac ;;
    transaction.prepare) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '无法在 %s 中准备更新的恢复副本；当前安装未被修改。' "$1" ;; en) printf 'could not prepare the update recovery copies in %s; the installation was not changed.' "$1" ;; esac ;;
    transaction.publish) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '无法发布新配置：%s。' "$1" ;; en) printf 'could not publish the new configuration: %s.' "$1" ;; esac ;;
    transaction.rolledback) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '更新已回滚，已恢复原来的配置和状态。' ;; en) printf 'the update was rolled back; the previous configuration and state were restored.' ;; esac ;;
    transaction.cleanup) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '新配置已提交，但无法删除旧事务备份：%s；下次操作将继续清理。' "$1" ;; en) printf 'the new configuration was committed, but old transaction backups could not be removed: %s; the next operation will retry cleanup.' "$1" ;; esac ;;
    config.external) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '配置文件已被外部修改；拒绝继续。' ;; en) printf 'the configuration was changed externally; refusing to continue.' ;; esac ;;
    config.unreadable) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '无法读取或校验配置文件：%s。' "$1" ;; en) printf 'the configuration file could not be read or validated: %s.' "$1" ;; esac ;;
    service.start) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf 'Xray 服务启动失败。' ;; en) printf 'the Xray service failed to start.' ;; esac ;;
    service.unit) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '无法写入服务定义：%s。' "$1" ;; en) printf 'could not write the service definition: %s.' "$1" ;; esac ;;
    service.reload) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '服务管理器无法重新加载服务定义。' ;; en) printf 'the service manager could not reload the service definitions.' ;; esac ;;
    service.enable) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '无法设置 Xray 服务开机启动。' ;; en) printf 'could not enable the Xray service at boot.' ;; esac ;;
    service.disable) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '无法取消 Xray 服务开机启动。' ;; en) printf 'could not disable the Xray service at boot.' ;; esac ;;
    service.stop) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '无法确认 Xray 服务已停止。' ;; en) printf 'could not verify that the Xray service stopped.' ;; esac ;;
    service.inactive) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '无法确认 Xray 服务正在运行。' ;; en) printf 'could not verify that the Xray service is running.' ;; esac ;;
    service.listen) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf 'Xray 未在端口 %s 上监听。' "$1" ;; en) printf 'Xray is not listening on port %s.' "$1" ;; esac ;;
    service.ready) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf 'Xray 正在端口 %s 上监听。' "$1" ;; en) printf 'Xray is listening on port %s.' "$1" ;; esac ;;
    service.unverified) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '无法验证端口 %s 的监听状态。' "$1" ;; en) printf 'the listen state of port %s could not be verified.' "$1" ;; esac ;;
    service.dataplane) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '端口 %s 上的认证代理流量验证失败。' "$1" ;; en) printf 'authenticated proxy traffic could not be verified on port %s.' "$1" ;; esac ;;
    service.dataplane.reason) [ "$#" -eq 2 ] || return 1; case "$S5_LANG" in zh) printf '端口 %s 上的认证代理流量验证失败：%s。' "$1" "$2" ;; en) printf 'authenticated proxy traffic could not be verified on port %s: %s.' "$1" "$2" ;; esac ;;
    account.exists) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '账户或组 %s 已存在；拒绝采用外部身份。' "$1" ;; en) printf 'account or group %s already exists; refusing to adopt an external identity.' "$1" ;; esac ;;
    account.failed) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '无法创建服务账户：%s。' "$1" ;; en) printf 'could not create the service account: %s.' "$1" ;; esac ;;
    account.identity) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '服务账户身份已改变；拒绝删除。' ;; en) printf 'the service account identity changed; refusing to delete it.' ;; esac ;;
    lock.busy) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '另一个管理操作正在运行。' ;; en) printf 'another management operation is already running.' ;; esac ;;
    state.missing) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '没有已安装的 %s。' "$1" ;; en) printf 'no %s installation was found.' "$1" ;; esac ;;
    state.invalid) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf 'state 文件无效：%s。拒绝删除或覆盖资源。' "$1" ;; en) printf 'invalid state file: %s. Refusing to delete or overwrite resources.' "$1" ;; esac ;;
    state.write) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '无法写入 state 文件：%s。' "$1" ;; en) printf 'could not write the state file: %s.' "$1" ;; esac ;;
    state.unsupported) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf 'state 架构不受支持：%s。已保留资源。' "$1" ;; en) printf 'unsupported state schema: %s. Resources were preserved.' "$1" ;; esac ;;
    status.state.running) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '运行中' ;; en) printf 'running' ;; esac ;;
    status.state.stopped) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '已停止' ;; en) printf 'stopped' ;; esac ;;
    status.state.crashed) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '已崩溃' ;; en) printf 'crashed' ;; esac ;;
    status.state.failed) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '已失败' ;; en) printf 'failed' ;; esac ;;
    status.state.unsupervised) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '失去守护' ;; en) printf 'unsupervised' ;; esac ;;
    status.state.unverified) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '未验证' ;; en) printf 'unverified' ;; esac ;;
    status.heading) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf 'Xray mixed 代理状态：' ;; en) printf 'Xray mixed proxy status:' ;; esac ;;
    status.line) [ "$#" -eq 3 ] || return 1; case "$S5_LANG" in zh) printf '服务：%s；端口：%s；账户：%s；协议：mixed（SOCKS5 + HTTP）；认证：密码；UDP：关闭' "$1" "$2" "$3" ;; en) printf 'service: %s; port: %s; username: %s; protocol: mixed (SOCKS5 + HTTP); auth: password; UDP: disabled' "$1" "$2" "$3" ;; esac ;;
    status.version) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf 'Xray 版本：%s' "$1" ;; en) printf 'Xray version: %s' "$1" ;; esac ;;
    show.terminal) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf 'show 仅在真实 TTY 中显示凭据。' ;; en) printf 'show displays credentials only on a real TTY.' ;; esac ;;
    show.service) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '服务：%s' "$1" ;; en) printf 'service: %s' "$1" ;; esac ;;
    show.heading) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '凭据卡（mixed：SOCKS5 + HTTP）：' ;; en) printf 'credential card (mixed: SOCKS5 + HTTP):' ;; esac ;;
    show.placeholder) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '警告：无法确定服务器的公网地址，请把下面的 %s 替换为该服务器的公网 IPv4。' "$1" ;; en) printf "WARNING: the server's public address could not be determined; replace %s below with the server's public IPv4." "$1" ;; esac ;;
    show.nat) [ "$#" -eq 3 ] || return 1; _smnat=$(s5_msg show.nat.forward) || return 1; case "$S5_LANG" in zh) printf '警告：%s 是本服务器出站流量的来源地址，本机并未持有它（本机地址：%s）。代理监听在端口 %s。%s' "$1" "$2" "$3" "$_smnat" ;; en) printf 'WARNING: %s is the address this server egresses from, and this machine does not hold it (local address: %s). The proxy listens on port %s. %s' "$1" "$2" "$3" "$_smnat" ;; esac ;;
    show.nat.unnamed) [ "$#" -eq 2 ] || return 1; _smnat=$(s5_msg show.nat.forward) || return 1; case "$S5_LANG" in zh) printf '警告：%s 是本服务器出站流量的来源地址，本机并未持有它。代理监听在端口 %s。%s' "$1" "$2" "$_smnat" ;; en) printf 'WARNING: %s is the address this server egresses from, and this machine does not hold it. The proxy listens on port %s. %s' "$1" "$2" "$_smnat" ;; esac ;;
    show.nat.forward) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '只有当上级把发往该地址的入站连接转发到本机时，下面的链接才可用；否则请用 S5_SERVER_IPV4 和 S5_SERVER_PORT 指定客户端真正使用的地址和端口。' ;; en) printf 'The links below work only if something upstream forwards inbound connections for that address to this machine; otherwise set S5_SERVER_IPV4 and S5_SERVER_PORT to the address and port your clients actually use.' ;; esac ;;
    show.port.mapped) [ "$#" -eq 2 ] || return 1; case "$S5_LANG" in zh) printf '下面的链接使用端口 %s，而代理监听在端口 %s。该映射来自 S5_SERVER_PORT，脚本不会创建它。' "$1" "$2" ;; en) printf 'the links below use port %s while the proxy listens on port %s. That mapping comes from S5_SERVER_PORT; the script does not create it.' "$1" "$2" ;; esac ;;
    show.socks) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf 'SOCKS5：%s' "$1" ;; en) printf 'SOCKS5: %s' "$1" ;; esac ;;
    show.http) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf 'HTTP：%s' "$1" ;; en) printf 'HTTP: %s' "$1" ;; esac ;;
    show.warning) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '认证信息会在网络上传输，密码以明文保存在受保护的配置文件中。' ;; en) printf 'credentials are sent on the wire, and the password is stored in cleartext in the protected config file.' ;; esac ;;
    uninstall.residue) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '发现未知或不安全的残留，拒绝卸载：%s。' "$1" ;; en) printf 'refusing uninstall with unknown or unsafe residue: %s.' "$1" ;; esac ;;
    uninstall.confirm) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '确认删除 Xray mixed 代理及其账户？[y/N] ' ;; en) printf 'Remove the Xray mixed proxy and its account? [y/N] ' ;; esac ;;
    uninstall.done) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '卸载完成；系统软件包和防火墙规则未修改。' ;; en) printf 'uninstall completed; system packages and firewall rules were not modified.' ;; esac ;;
    install.confirm) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '确认安装 Xray mixed 代理？[Y/n] ' ;; en) printf 'Install the Xray mixed proxy? [Y/n] ' ;; esac ;;
    update.confirm) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '更新现有 Xray 配置？[y/N] ' ;; en) printf 'Update the existing Xray configuration? [y/N] ' ;; esac ;;
    usage) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '用法：sh socks5.sh [install|status|show|restart|uninstall|language|help]' ;; en) printf 'Usage: sh socks5.sh [install|status|show|restart|uninstall|language|help]' ;; esac ;;
    account.remove.identity) [ "$#" -eq 2 ] || return 1; case "$S5_LANG" in zh) printf '账户身份不匹配：记录值为 %s/%s。' "$1" "$2" ;; en) printf 'account identity mismatch: recorded %s/%s.' "$1" "$2" ;; esac ;;
    account.remove.user) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '无法删除服务账户：%s。' "$1" ;; en) printf 'could not remove service account: %s.' "$1" ;; esac ;;
    account.remove.user.exists) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '删除后服务账户仍然存在：%s。' "$1" ;; en) printf 'service account still exists after removal: %s.' "$1" ;; esac ;;
    account.remove.user.verify) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '无法验证服务账户已删除：%s。' "$1" ;; en) printf 'could not verify service account removal: %s.' "$1" ;; esac ;;
    account.remove.group) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '无法删除服务组：%s。' "$1" ;; en) printf 'could not remove service group: %s.' "$1" ;; esac ;;
    account.remove.group.before) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '删除前无法验证服务组：%s。' "$1" ;; en) printf 'could not verify service group before removal: %s.' "$1" ;; esac ;;
    account.remove.group.exists) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '删除后服务组仍然存在：%s。' "$1" ;; en) printf 'service group still exists after removal: %s.' "$1" ;; esac ;;
    account.remove.group.verify) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '无法验证服务组已删除：%s。' "$1" ;; en) printf 'could not verify service group removal: %s.' "$1" ;; esac ;;
    uninstall.symlink) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '卸载时拒绝符号链接：%s。' "$1" ;; en) printf 'refusing symlink during uninstall: %s.' "$1" ;; esac ;;
    uninstall.file) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '无法删除自有文件：%s。' "$1" ;; en) printf 'could not remove owned file: %s.' "$1" ;; esac ;;
    uninstall.notdir) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '自有路径不是目录：%s。' "$1" ;; en) printf 'owned path is not a directory: %s.' "$1" ;; esac ;;
    uninstall.nonempty) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '拒绝删除非空自有目录：%s。' "$1" ;; en) printf 'refusing non-empty owned directory: %s.' "$1" ;; esac ;;
    uninstall.progress) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '无法记录卸载进度：%s。' "$1" ;; en) printf 'could not record uninstall progress: %s.' "$1" ;; esac ;;
    uninstall.identity) [ "$#" -eq 0 ] || return 1; case "$S5_LANG" in zh) printf '无法记录已安装路径的身份；未删除任何内容。' ;; en) printf 'could not record the identity of the installed paths; nothing was removed.' ;; esac ;;
    uninstall.directory) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '无法删除自有目录：%s。' "$1" ;; en) printf 'could not remove owned directory: %s.' "$1" ;; esac ;;
    usage.unknown) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '未知命令：%s。' "$1" ;; en) printf 'unknown command: %s.' "$1" ;; esac ;;
    usage.extra) [ "$#" -eq 1 ] || return 1; case "$S5_LANG" in zh) printf '命令不接受额外参数：%s。' "$1" ;; en) printf 'the command does not accept extra arguments: %s.' "$1" ;; esac ;;
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
    _sslang_try=0
    while [ "$_sslang_try" -lt 3 ]; do
        _sslang_try=$((_sslang_try + 1))
        s5_msg_print lang.prompt >&2
        _sslang_answer=''
        IFS= read -r _sslang_answer || return 1
        case "$_sslang_answer" in
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

# The language every command but `language` speaks: the saved preference, or a
# fresh answer. Failing to save that answer only costs the next run a prompt, so
# it is a warning here and never this command's failure.
s5_init_language() {
    s5_language_load && return 0
    s5_select_language || return 1
    s5_language_save || s5_msg_warn lang.unsaved
    return 0
}

# The language command exists to save a preference, so an unsaved one fails it.
s5_cmd_language() {
    s5_select_language || return 1
    s5_language_save || { s5_msg_warn lang.unsaved; return 1; }
    s5_msg_print lang.saved
}

s5_osrel_get() {
    [ -r "$1" ] || return 1
    # Single awk pass replaces sed|tail|tr|sed: keep the last "key=" line, strip
    # CR, then peel one matching pair of surrounding quotes. An absent key prints
    # nothing (like the old empty sed output), preserving callers' return value.
    awk -v key="$2" '
        index($0, key "=") == 1 { v = substr($0, length(key) + 2); found = 1 }
        END {
            if (!found) exit 0
            gsub(/\r/, "", v)
            if (v ~ /^".*"$/) v = substr(v, 2, length(v) - 2)
            else if (v ~ /^'\''.*'\''$/) v = substr(v, 2, length(v) - 2)
            print v
        }
    ' "$1"
}

s5_ver_ge() {
    _svg_left=$1
    _svg_right=$2
    # An absent version is not version 0.
    [ -n "$_svg_left" ] && [ -n "$_svg_right" ] || return 2
    while [ -n "$_svg_left" ] || [ -n "$_svg_right" ]; do
        _svg_left_part=${_svg_left%%.*}
        _svg_right_part=${_svg_right%%.*}
        [ -n "$_svg_left_part" ] || _svg_left_part=0
        [ -n "$_svg_right_part" ] || _svg_right_part=0
        # Each field on its own: checked joined by a colon, a colon inside a
        # field (VERSION_ID=1:0) passed as a digit separator and compared as a
        # three-character number.
        case "$_svg_left_part" in *[!0-9]*) return 2 ;; esac
        case "$_svg_right_part" in *[!0-9]*) return 2 ;; esac
        _svg_left_part=${_svg_left_part#"${_svg_left_part%%[!0]*}"}
        _svg_right_part=${_svg_right_part#"${_svg_right_part%%[!0]*}"}
        [ -n "$_svg_left_part" ] || _svg_left_part=0
        [ -n "$_svg_right_part" ] || _svg_right_part=0
        [ "${#_svg_left_part}" -le 18 ] && [ "${#_svg_right_part}" -le 18 ] || return 2
        if [ "${#_svg_left_part}" -gt "${#_svg_right_part}" ]; then return 0; fi
        if [ "${#_svg_left_part}" -lt "${#_svg_right_part}" ]; then return 1; fi
        if [ "$_svg_left_part" != "$_svg_right_part" ]; then
            # Prefixing forces a lexical comparison, which is exact for equal-length
            # decimal fields and avoids signed shell-arithmetic overflow.
            _svg_result=$(awk -v a="$_svg_left_part" -v b="$_svg_right_part" \
                'BEGIN { print (("x" a) > ("x" b)) ? 0 : 1 }') || return 2
            [ "$_svg_result" = 0 ] && return 0
            return 1
        fi
        case "$_svg_left" in
        *.*) _svg_left=${_svg_left#*.}; [ -n "$_svg_left" ] || return 2 ;;
        *) _svg_left='' ;;
        esac
        case "$_svg_right" in
        *.*) _svg_right=${_svg_right#*.}; [ -n "$_svg_right" ] || return 2 ;;
        *) _svg_right='' ;;
        esac
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
# s5_unit_mode: the type and mode of this backend's service artifact, in
# S5_UNIT_TYPE and S5_UNIT_MODE.
s5_unit_mode() {
    case "$S5_INIT" in
    systemd) S5_UNIT_TYPE='file'; S5_UNIT_MODE=644 ;;
    openrc) S5_UNIT_TYPE='exec'; S5_UNIT_MODE=755 ;;
    *) return 1 ;;
    esac
}

s5_select_service_artifact() {
    S5_SERVICE_ARTIFACT=''
    # No default backend: an unset S5_INIT used to become systemd silently.
    case "$S5_INIT" in
    systemd) S5_SERVICE_ARTIFACT=$S5_UNITDIR/$S5_PROJECT.service ;;
    openrc) S5_SERVICE_ARTIFACT=$S5_INITSCRIPT ;;
    *) s5_msg_err detect.init; return 1 ;;
    esac
}

s5_detect_platform() {
    _sdp_osrelease=${S5_OSRELEASE:-/etc/os-release}
    S5_OS_ID=$(s5_osrel_get "$_sdp_osrelease" ID) || return 1
    S5_OS_VERSION_ID=$(s5_osrel_get "$_sdp_osrelease" VERSION_ID) || return 1
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
        # The accumulator opens with a separator, so peel it the way
        # s5_runtime_packages does before the list reaches a message.
        s5_msg_err detect.commands "${_srcmiss# }"
        return 1
    fi
    return 0
}

# s5_valid_port_from <port> <lowest>: a canonical decimal port from <lowest> to
# 65535.
s5_valid_port_from() {
    case "${1:-}" in '' | 0* | *[!0-9]*) return 1 ;; esac
    [ "${#1}" -le 5 ] || return 1
    [ "$1" -ge "$2" ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null
}

s5_valid_port() { s5_valid_port_from "${1:-}" 1024; }

# The advertised port is what a client dials, so it has no privilege
# constraint: a provider mapping external 443 to an internal high port is a
# common shape, chosen precisely to survive restrictive client networks.
# s5_valid_port's 1024 floor exists because the listener runs unprivileged,
# which says nothing about what the other end of a forward looks like.
s5_valid_advertised_port() { s5_valid_port_from "${1:-}" 1; }

# s5_split_words <separators> <text> <command> [args...]: run the command with its
# args followed by the fields of text, split at the separators with pathname
# expansion off, so no field can expand into file names.
s5_split_words() {
    _sspl_oldifs=$IFS
    IFS=$1
    _sspl_text=$2
    shift 2
    set -f
    # Splitting is the point; globbing is off.
    # shellcheck disable=SC2086
    set -- "$@" $_sspl_text
    set +f
    IFS=$_sspl_oldifs
    _sspl_text=''
    "$@"
}

s5_ipv4_is_canonical() {
    case "${1:-}" in '' | *[!0-9.]*) return 1 ;; esac
    case "$1" in .* | *. | *..*) return 1 ;; esac
    s5_split_words . "$1" s5_ipv4_octets_valid
}

# s5_ipv4_octets_valid <octet>...: four canonical decimal octets.
s5_ipv4_octets_valid() {
    [ "$#" -eq 4 ] || return 1
    for _siov_octet in "$1" "$2" "$3" "$4"; do
        case "$_siov_octet" in '' | *[!0-9]*) return 1 ;; esac
        [ "${#_siov_octet}" -le 3 ] || return 1
        case "$_siov_octet" in 0 | 0*) [ "$_siov_octet" = 0 ] || return 1 ;; esac
        [ "$_siov_octet" -le 255 ] 2>/dev/null || return 1
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

# Split out as a command seam so a test can present a fixed set of addresses
# without depending on the host's real interfaces.
s5_local_ipv4_command() { ip -o addr show; }

# Every IPv4 address this host holds, one per line. Two sources because neither
# is universal: iproute2 is absent from a minimal image, and /proc/net/fib_trie
# is Linux-only and unreadable in some sandboxes. Failure means "cannot say",
# never "not local", and every caller has to preserve that distinction.
s5_local_ipv4() {
    # _slip rather than _sslang_try: s5_select_language already owns _sslang_try as its retry
    # counter, and a shared prefix between two functions is how one of them
    # eventually corrupts the other.
    _slip_out=''
    # No `command -v ip` guard: the seam has to be authoritative, or a test that
    # substitutes it would be skipped on a host that happens to lack iproute2.
    # A missing command simply fails the substitution and falls through below.
    _slip=$(s5_local_ipv4_command 2>/dev/null) || _slip=''
    if [ -n "$_slip" ]; then
        _slip_out=$(printf '%s\n' "$_slip" |
            awk '$3 == "inet" { sub("/.*", "", $4); print $4 }')
    fi
    _slip=''
    if [ -z "$_slip_out" ]; then
        # fib_trie marks a genuinely local leaf with "host LOCAL" on the line
        # after it. A network base carries "link UNICAST" and a broadcast
        # "link BROADCAST", so neither is mistaken for an interface address.
        # The file holds both a Main and a Local table, which list the same
        # addresses, so the walk deduplicates rather than relying on table
        # order -- the hint below takes the first address it is given.
        [ -r "$S5_ROOTDIR/proc/net/fib_trie" ] || return 1
        _slip_out=$(awk '
            $1 == "|--" { leaf = $2; next }
            /host LOCAL/ && leaf != "" {
                if (!(leaf in seen)) { seen[leaf] = 1; print leaf }
                leaf = ""
            }
        ' "$S5_ROOTDIR/proc/net/fib_trie" 2>/dev/null)
    fi
    [ -n "$_slip_out" ] || return 1
    printf '%s\n' "$_slip_out"
    _slip_out=''
    return 0
}

# 0 the host holds this address, 1 it does not, 2 neither source could answer.
# The third state is what keeps the card advisory: a host that cannot enumerate
# its own addresses must not have its card annotated with a guess.
s5_ipv4_is_local() {
    _siil_want=${1:-}
    s5_ipv4_is_canonical "$_siil_want" || return 2
    [ -n "${2:-}" ] || return 2
    s5_split_words "$S5_WORD_IFS" "$2" s5_word_listed "$_siil_want"
    _siil_found=$?
    _siil_want=''
    return "$_siil_found"
}

# s5_word_listed <word> <list>...: whether the word is one of the list.
s5_word_listed() {
    _swl_word=$1
    shift
    for _swl_item in "$@"; do
        [ "$_swl_item" != "$_swl_word" ] || return 0
    done
    return 1
}

# The first non-loopback address, named in the NAT advisory so the operator can
# see what this host actually holds. Fails when there is nothing to name.
s5_local_ipv4_hint() {
    [ -n "${1:-}" ] || return 1
    s5_split_words "$S5_WORD_IFS" "$1" s5_first_nonloopback
}

s5_first_nonloopback() {
    for _sfnl_addr in "$@"; do
        case "$_sfnl_addr" in 127.*) continue ;; esac
        printf '%s' "$_sfnl_addr"
        return 0
    done
    return 1
}

# A credential that is generated or entered from now on is letters and digits
# only, so nothing in the printed socks5:// and http:// URIs can be mis-parsed by
# a client that treats the userinfo component loosely. These two gate every write
# path: the prompts, the rendered config, and the state record.
s5_valid_username() { s5_valid_credential "${1:-}" "$S5_CREDENTIAL_CHARS" 3 32; }
s5_valid_password() { s5_valid_credential "${1:-}" "$S5_CREDENTIAL_CHARS" 12 128; }

# s5_valid_credential <value> <chars> <shortest> <longest>: a value of only the
# bracket-expression characters <chars>, within the length bounds.
s5_valid_credential() {
    # The set is expanded unquoted on purpose: it is the bracket expression.
    case "$1" in '' | *[!$2]*) return 1 ;; esac
    [ "${#1}" -ge "$3" ] && [ "${#1}" -le "$4" ]
}

# The read-back pair, deliberately wider than the write pair above: it still
# accepts the historical sets (`_-` in a username, `._~-` in a password). An
# installation made before the narrowing must stay readable, restartable and
# above all uninstallable, and every one of those commands reaches its credential
# through s5_config_extract or a state load. Refusing a legacy value there would
# strand the installation with no supported way to remove it. An update rotates
# the credential through the strict pair, which is the only way a legacy value
# leaves an installation.
s5_valid_stored_username() { s5_valid_credential "${1:-}" "$S5_STORED_USERNAME_CHARS" 3 32; }
s5_valid_stored_password() { s5_valid_credential "${1:-}" "$S5_STORED_PASSWORD_CHARS" 12 128; }

s5_random_string() {
    _srsn=$1
    _srsset=$2
    [ "$_srsn" -gt 0 ] || return 1
    _srsraw=$(od -An -N512 -tu1 /dev/urandom 2>/dev/null) || return 1
    # Rejection sampling: 256 is not a multiple of every set length, so folding
    # each byte with % would make the first 256%len characters more likely.
    # Discard the uneven tail instead and keep the remainder uniform.
    printf '%s\n' "$_srsraw" | awk -v n="$_srsn" -v set="$_srsset" '
        BEGIN { len=length(set); limit=256-(256%len) }
        { for (i=1; i<=NF && length(out)<n; i++) if ($i < limit) out=out substr(set,($i % len)+1,1) }
        END { if (length(out)==n) print out; else exit 1 }
    '
}

s5_random_port() {
    # Keep only decimal digits: BusyBox tr can treat '[:space:]' literally,
    # leaving od's leading spaces in a value used for shell arithmetic.
    # Rejection sampling: 65536 is not a multiple of the 40001-wide range, so
    # accepting every draw would make the low 25535 ports twice as likely.
    # Bounded retries keep a starved entropy source from looping forever.
    _srandport_tries=0
    while [ "$_srandport_tries" -lt 64 ]; do
        _srandport_tries=$((_srandport_tries + 1))
        _srandport_value=$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -cd '0-9') || return 1
        [ -n "$_srandport_value" ] || return 1
        [ "$_srandport_value" -le 40000 ] || continue
        printf '%s' "$((20000 + _srandport_value))"
        return 0
    done
    return 1
}

s5_port_free() {
    _spfp=$1
    if [ "${S5_TEST_MODE:-0}" = 1 ] && [ -n "${S5_PORT_PROBE:-}" ]; then
        "$S5_PORT_PROBE" "$_spfp"
        return $?
    fi
    if command -v ss >/dev/null 2>&1; then
        _spfo=$(ss -ltnH 2>/dev/null) || return 2
        printf '%s\n' "$_spfo" | awk -v p="$_spfp" '
            $1 == "LISTEN" && $4 ~ (":" p "$") { found=1 }
            END { exit found ? 1 : 0 }'
        _spfr=$?
        case "$_spfr" in 0) return 0 ;; 1) return 1 ;; *) return 2 ;; esac
    fi
    if command -v netstat >/dev/null 2>&1; then
        _spfo=$(netstat -lnt 2>/dev/null) || return 2
        printf '%s\n' "$_spfo" | awk -v p="$_spfp" '
            $1 ~ /tcp/ && $6 == "LISTEN" && $4 ~ (":" p "$") { found=1 }
            END { exit found ? 1 : 0 }'
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
    # On update S5_PORT holds the port the running service owns; a blank answer
    # keeps it only once the listener verifies that ownership, and otherwise
    # re-asks rather than rotating the operator's port behind their back. On a
    # fresh install S5_PORT is empty, so a blank answer generates one as before.
    # Which of the two a blank answer means is now in the question itself: the
    # port, username and password prompts share one screen, and an operator who
    # read "random" on one and carried the assumption to the others lost values
    # they meant to keep.
    _spp_current=${S5_PORT:-}
    # A provider that DNATs one fixed external port needs that exact port bound,
    # and until now the only way to say so was to type it at this prompt. The
    # override supplies the blank answer, which still passes the same validator
    # and free-or-owned checks as a typed port. It is consumed on first use so a
    # rejected value cannot feed itself into the re-ask forever. Distinct from
    # S5_SERVER_PORT, which changes only what the card advertises.
    _spp_override=${S5_LISTEN_PORT:-}
    _spp_explicit=0
    while :; do
        if [ -n "$_spp_override" ]; then
            # The environment value is not rendered before validation: an
            # invalid override may contain control characters, while a valid
            # port is named after Enter by the normal accepted/error path.
            s5_msg_ask input.port.override || return 1
        elif [ "$_spp_explicit" -eq 1 ]; then
            s5_msg_ask input.port.explicit || return 1
        elif [ -n "$_spp_current" ]; then
            s5_msg_ask input.port.keep "$_spp_current" || return 1
        else
            s5_msg_ask input.port || return 1
        fi
        _spp=''
        IFS= read -r _spp || return 1
        if [ -z "$_spp" ] && [ -n "$_spp_override" ]; then
            _spp=$_spp_override
            _spp_override=''
        fi
        if [ -z "$_spp" ]; then
            if [ -n "$_spp_current" ]; then
                if s5_port_owned_by_service "$_spp_current"; then
                    S5_PORT=$_spp_current
                    return 0
                fi
                # Falling through to a random port moved the operator's listener
                # without a word; an unverified port is reported and re-asked.
                s5_msg_err input.port.unverified "$_spp_current"
                # The diagnosis requires an explicit answer. Stop offering the
                # rejected keep action, and do not let another blank turn into a
                # random port behind the operator's back.
                _spp_current=''
                _spp_explicit=1
                continue
            fi
            if [ "$_spp_explicit" -eq 1 ]; then
                s5_msg_err input.port.invalid
                continue
            fi
            _spp=$(s5_random_port) || return 1
        fi
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
    # On update s5_state_load and s5_config_extract leave S5_USERNAME holding the
    # account the installation runs, so a blank answer keeps it: an operator
    # re-running install to change the port alone must not have their account
    # rotated without a word. On a fresh install S5_USERNAME is empty -- the
    # globals are unset and re-blanked at the top of this script, so a caller's
    # environment cannot forge a current value -- and a blank answer generates.
    s5_prompt_credential username
}

s5_prompt_password() {
    # The username's rule, with one difference: the question never echoes the
    # value it would keep. s5_msg_ask writes its rendered text straight to
    # stderr without passing it through s5_redact, so input.password.keep takes
    # no argument; the card and show stay the only places a password is printed,
    # and both gate on root and a real TTY.
    s5_prompt_credential password
}

# s5_prompt_credential username|password: ask for one credential, keeping the
# current value on a blank answer when there is one and generating one otherwise.
#
# A value from before the narrowing cannot be kept: s5_config_extract reads it
# back through the wide validator, while s5_config_render and s5_state_write both
# gate on the narrow one, so keeping it would abort the update inside the config
# candidate with nothing naming the credential. It is reported and offered for
# replacement instead.
s5_prompt_credential() {
    case "$1" in
    username) _spcr_current=${S5_USERNAME:-}; _spcr_length=12; _spcr_keep=$_spcr_current ;;
    password) _spcr_current=${S5_PASSWORD:-}; _spcr_length=32; _spcr_keep='' ;;
    *) return 1 ;;
    esac
    if [ -n "$_spcr_current" ] && ! "s5_valid_$1" "$_spcr_current"; then
        s5_msg_warn "input.$1.legacy"
        _spcr_current=''
    fi
    while :; do
        if [ -z "$_spcr_current" ]; then
            s5_msg_ask "input.$1" || return 1
        elif [ -n "$_spcr_keep" ]; then
            s5_msg_ask "input.$1.keep" "$_spcr_keep" || return 1
        else
            s5_msg_ask "input.$1.keep" || return 1
        fi
        _spcr_answer=''
        IFS= read -r _spcr_answer || return 1
        if [ -z "$_spcr_answer" ]; then
            _spcr_answer=$_spcr_current
            [ -n "$_spcr_answer" ] ||
                _spcr_answer=$(s5_random_string "$_spcr_length" "$S5_CREDENTIAL_ALPHABET") || return 1
        fi
        if "s5_valid_$1" "$_spcr_answer"; then
            case "$1" in
            username) S5_USERNAME=$_spcr_answer ;;
            password) S5_PASSWORD=$_spcr_answer; S5_SECRET=$_spcr_answer ;;
            esac
            _spcr_answer=''
            _spcr_current=''
            _spcr_keep=''
            return 0
        fi
        s5_msg_err "input.$1.invalid"
    done
}

s5_asset_select() {
    case "$S5_ARCHNAME" in
    amd64)
        S5_ASSET_NAME=xray-v26.3.27-linux-amd64
        S5_ASSET_SIZE=36577406
        S5_ASSET_SHA256=8255dd939c34cf966cc91517b6324dd3c8d0bcf49ffac8beca049a38c46845ed
        ;;
    arm64)
        S5_ASSET_NAME=xray-v26.3.27-linux-arm64
        S5_ASSET_SIZE=34209918
        S5_ASSET_SHA256=c2d20a7045250497083afea0d79db0672f6c89a25aaaf37c92de034d6b764b04
        ;;
    *) return 1 ;;
    esac
    # Raw distribution performs no transformation, so these are also the
    # installed executable's size and digest; state schema 2 records both.
}

s5_mkdir_parents() {
    case "$1" in
    '' | /) return 0 ;;
    esac
    if [ -L "$1" ]; then return 1; fi
    if [ -d "$1" ]; then return 0; fi
    if [ -e "$1" ]; then return 1; fi
    _smkp_parent=${1%/*}
    [ "$_smkp_parent" != "$1" ] || _smkp_parent=.
    s5_mkdir_parents "$_smkp_parent" || return 1
    mkdir "$1" || return 1
    chmod 0755 "$1"
}

# s5_mkdir_new <dir>: create a private directory that must not exist yet. Plain
# mkdir refuses every existing name, a symlink included, so its success alone
# proves this run created the directory. Returns 2 when nothing was created, so a
# caller that armed cleanup beforehand disarms it, and 1 when the new directory
# could not be made private.
s5_mkdir_new() {
    _smnew_parent=${1%/*}
    [ "$_smnew_parent" != "$1" ] || _smnew_parent=.
    s5_mkdir_parents "$_smnew_parent" || return 2
    mkdir "$1" || return 2
    chmod 0700 "$1" || return 1
}

s5_mkdir_private() {
    if [ -L "$1" ]; then return 1; fi
    _smpriv_parent=${1%/*}
    [ "$_smpriv_parent" != "$1" ] || _smpriv_parent=.
    s5_mkdir_parents "$_smpriv_parent" || return 1
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
    _slboot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || uname -n)
    _sltoken="$_slboot
$$"
    _slstatus=1
    if _sltmp=$(mktemp "$S5_LOCKDIR/.owner.XXXXXX") &&
        printf '%s\n' "$_sltoken" >"$_sltmp" && chmod 0600 "$_sltmp" &&
        ln -T "$_sltmp" "$S5_LOCK_OWNER" 2>/dev/null; then
        _slstatus=0
    fi
    # The one exit. The owner temp goes either way; without a linked owner the
    # directory this call created is removed too, so it never reads as held.
    [ -z "$_sltmp" ] || rm -f "$_sltmp" 2>/dev/null || true
    _sltmp=''
    if [ "$_slstatus" -ne 0 ]; then
        rmdir "$S5_LOCKDIR" 2>/dev/null || true
        return 1
    fi
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
    # Reclaimable only when the owner cannot still hold it: a previous boot, or
    # a process that no longer exists.
    if [ "$_slrboot" = "$_slrnow" ] && kill -0 "$_slrpid" 2>/dev/null; then
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
    # Literal CIDRs rather than geoip:private: raw executable delivery installs
    # no GeoIP database, so a geoip rule would fail at runtime.
    #
    # IPIfNonMatch is what makes a hostname target subject to these rules. With
    # the default AsIs an "ip" rule can only ever match a literal address, so
    # any name resolving into a denied range would be routed direct.
    #
    # NAT64 translation is outside this static boundary: the well-known and
    # local-use prefixes do not cover operator-defined Network-Specific Prefixes,
    # and denying the well-known prefix can break IPv4 reachability on a
    # NAT64-dependent host. Do not describe these literal CIDRs as exhaustive
    # NAT64 protection.
    #
    # test_xray_boundary.sh compares this boundary and tests/protocol/start_engine.sh
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
    _sceuser=$(sed -n "s/.*\"user\":[[:space:]]*\"\([$S5_STORED_USERNAME_CHARS]*\)\".*/\1/p" \
        "$S5_CFG" | head -n 1)
    _scepass=$(sed -n "s/.*\"pass\":[[:space:]]*\"\([$S5_STORED_PASSWORD_CHARS]*\)\".*/\1/p" \
        "$S5_CFG" | head -n 1)
    [ "$(grep -cF '"protocol": "mixed"' "$S5_CFG")" = 1 ] || return 1
    [ "$(grep -cF '"auth": "password"' "$S5_CFG")" = 1 ] || return 1
    [ "$(grep -cF '"udp": false' "$S5_CFG")" = 1 ] || return 1
    [ "$(grep -cF '"user":' "$S5_CFG")" = 1 ] || return 1
    [ "$(grep -cF '"pass":' "$S5_CFG")" = 1 ] || return 1
    s5_valid_stored_username "$_sceuser" && s5_valid_stored_password "$_scepass" || return 1
    S5_USERNAME=$_sceuser
    S5_PASSWORD=$_scepass
    _scepass=''
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

# Byte size of $1 as bare digits: wc pads its count with spaces on some systems
# and ends it with a newline, and only the digits are kept.
s5_bytecount() { wc -c <"$1" | tr -cd '0-9'; }

# Capacity is advisory, never an acceptance gate: it decides whether to refuse
# before tens of megabytes are written, while the pinned size and SHA-256 stay the
# only authority over what gets installed. Every unusable answer below therefore
# leaves the operation alone rather than refusing a working host, and both answers
# come from stat -- reached the same way s5_path_contract reaches it -- rather than
# from df. df reports the space available to unprivileged users, which excludes the
# reserve only root may write into; every command that stages an engine runs as
# root, that reserve is gigabytes on a nearly full ext4 root filesystem, and
# refusing a host that would have installed is the one outcome this check must never
# produce. stat also answers without columns to split, so a device or mount point
# containing a space cannot shift the number being read.
s5_fs_free_command() { stat -f -c '%f %S' "$1"; }

# The filesystem id for $1. Two paths reporting the same id draw on the same free
# space. A df row cannot answer this: its used, available and capacity columns move
# between the two calls, so one filesystem compares unequal to itself whenever
# anything else on the host is writing -- which silently skips the combined check
# exactly when a busy single-filesystem container needs it.
s5_fs_id_command() { stat -c '%d' "$1"; }

s5_fs_id() {
    _sfi=$(s5_fs_id_command "$1" 2>/dev/null) || return 1
    case "$_sfi" in '' | *[!0-9]*) return 1 ;; esac
    printf '%s\n' "$_sfi"
}

# Free kibibytes on the filesystem holding $1, counting the reserve root can write
# into, or failure when stat cannot say. The count is in fundamental blocks, so an
# unrecognised block size is treated as no answer rather than converted by guess.
s5_free_kb() {
    _sfk=$(s5_fs_free_command "$1" 2>/dev/null) || return 1
    _sfk_blocks=${_sfk%% *}
    _sfk_bytes=${_sfk##* }
    case "$_sfk_blocks" in '' | *[!0-9]*) return 1 ;; esac
    case "$_sfk_bytes" in
    512) printf '%s\n' "$((_sfk_blocks / 2))" ;;
    1024 | 2048 | 4096 | 8192 | 16384 | 32768 | 65536)
        printf '%s\n' "$((_sfk_blocks * (_sfk_bytes / 1024)))"
        ;;
    *) return 1 ;;
    esac
}

s5_require_space() {
    # $1: the directory about to receive bytes. $2: how many. Refuse only on a
    # usable capacity answer that is short of the requirement.
    case "${2:-}" in '' | *[!0-9]*) return 0 ;; esac
    _sreq_free=$(s5_free_kb "$1") || return 0
    _sreq_need=$(((${2} + 1023) / 1024))
    [ "$_sreq_free" -lt "$_sreq_need" ] || return 0
    s5_msg_err disk.space "$1" "$_sreq_need" "$_sreq_free"
    return 1
}

s5_accept_size() {
    # $1: the file just written. $2: the gate's stable reason slug. $3: the pinned
    # byte count. This gate answers only whether completed bytes match the pin.
    # A short completed stream can be a rewritten artifact; only a nonzero writer
    # status is direct evidence that storage refused the write (ADR-0007, and
    # ADR-0008 for the raw candidate this now measures).
    _sas_size=$(s5_bytecount "$1")
    case "$_sas_size" in '' | *[!0-9]*) _sas_size=0 ;; esac
    [ "$_sas_size" = "$3" ] && return 0
    s5_msg_err asset.size "$2" "$_sas_size" "$3"
    return 1
}

# Both HTTPS requests use the distribution package at its supported path. The
# narrow seam keeps focused tests able to observe the complete transport argv.
s5_curl_command() { /usr/bin/curl "$@"; }

# The digest is the authoritative acceptance for every pinned value, so an
# absolute command seam keeps a same-named PATH wrapper from making any file
# match any pin; every supported family ships the tool at this path, BusyBox
# applet symlink included. One line keeps tests able to inject digest-command
# failures under every shell, including BusyBox shells that resolve applets
# before PATH.
s5_sha256_command() { /usr/bin/sha256sum "$1"; }

s5_first_word() {
    [ "$#" -ge 1 ] || return 1
    printf '%s' "$1"
}

s5_sha256() {
    _ssha_output=$(s5_sha256_command "$1" 2>/dev/null) || return 1
    # "digest  path": the digest is the first field.
    _ssha_hash=$(s5_split_words "$S5_WORD_IFS" "$_ssha_output" s5_first_word) || return 1
    _ssha_output=''
    [ "${#_ssha_hash}" -eq 64 ] || return 1
    case "$_ssha_hash" in *[!0-9a-fA-F]*) return 1 ;; esac
    printf '%s\n' "$_ssha_hash"
}

s5_record_digest() {
    # $1 is a stable, non-secret artifact label; $2 is the path.
    if ! S5_RECORDED_DIGEST=$(s5_sha256 "$2"); then
        s5_msg_err digest.failed "$1"
        S5_RECORDED_DIGEST=''
        return 1
    fi
}

s5_fetch_binary() {
    # $1 is a private same-directory candidate. Acceptance remains exact size and
    # SHA-256; curl's status only distinguishes a storage write refusal from a
    # transport failure.
    if [ -n "${S5_TEST_ASSET_PATH:-}" ]; then
        cp "$S5_TEST_ASSET_PATH" "$1" || { rm -f "$1" 2>/dev/null || true; return 1; }
    else
        s5_msg_print asset.download "$S5_ASSET_NAME" >&2
        s5_curl_command -q -fsSL --proto '=https' --proto-redir '=https' \
            --max-time 120 --max-filesize "$((S5_ASSET_SIZE + 1))" \
            -o "$1" "$S5_XRAY_BASE/$S5_ASSET_NAME"
        _sfb_curl=$?
        if [ "$_sfb_curl" -ne 0 ]; then
            if [ "$_sfb_curl" -eq 23 ]; then
                _sfb_size=$(s5_bytecount "$1" 2>/dev/null)
                case "$_sfb_size" in '' | *[!0-9]*) _sfb_size=0 ;; esac
                s5_msg_err disk.write "$1" "$_sfb_size" "$S5_ASSET_SIZE"
            else
                s5_msg_err asset.invalid download
            fi
            rm -f "$1" 2>/dev/null || true
            return 1
        fi
    fi
    # One size gate for every source. An endpoint that ignored --max-filesize
    # and sent more is reported here with both byte counts, as ADR-0006 asks.
    s5_accept_size "$1" size "$S5_ASSET_SIZE" || { rm -f "$1" 2>/dev/null || true; return 1; }
    # A digest tool that cannot run says nothing about the bytes; reporting it
    # as a SHA mismatch sent the operator after a corrupt download.
    _sfb_sha=$(s5_sha256 "$1") || {
        s5_msg_err digest.candidate "$S5_ASSET_NAME"
        rm -f "$1" 2>/dev/null || true
        return 1
    }
    [ "$_sfb_sha" = "$S5_ASSET_SHA256" ] || {
        s5_msg_err asset.invalid sha256
        rm -f "$1" 2>/dev/null || true
        return 1
    }
}

# The packaged file(1) is selected absolutely and isolated from MAGIC so PATH or
# an inherited database cannot decide whether verified bytes match the target.
s5_file_type_command() { /usr/bin/file -b "$@"; }
s5_file_type() (
    unset MAGIC
    s5_file_type_command "$@"
)

# Narrow execution seam: tests can provide a synthetic version answer without
# bypassing the preceding byte and ELF gates.
s5_xray_version_command() { "$1" version; }

# The executable gates. Exact size and SHA-256 were proven by s5_fetch_binary
# on this same private file a moment ago, so they are not repeated here: the
# repeat hashed 35 MB twice and made its own two refusal reasons unreachable.
s5_verify_binary_candidate() {
    _svbc_file=$(s5_file_type "$1" 2>/dev/null) || { s5_msg_err asset.invalid filetype; return 1; }
    case "$S5_ARCHNAME:$_svbc_file" in
    amd64:*'ELF 64-bit LSB executable, x86-64'*) ;;
    arm64:*'ELF 64-bit LSB executable, ARM aarch64'*) ;;
    *) s5_msg_err asset.invalid architecture; return 1 ;;
    esac
    case "$_svbc_file" in
    *'dynamically linked'* | *'interpreter '*) s5_msg_err asset.invalid linkage; return 1 ;;
    esac
    chmod 0700 "$1" || { s5_msg_err asset.invalid permission; return 1; }
    # A noexec mount or a missing loader fails here, before any version text.
    _svbc_version=$(s5_xray_version_command "$1" 2>/dev/null) || { s5_msg_err asset.invalid exec; return 1; }
    _svbc_first=${_svbc_version%%
*}
    case "$_svbc_first" in
    "Xray ${S5_XRAY_VERSION#v} "*) ;;
    *) s5_msg_err asset.invalid version; return 1 ;;
    esac
}

s5_publish_binary_candidate() {
    [ -n "$S5_BINARY_TEMP" ] || return 1
    chmod 0755 "$S5_BINARY_TEMP" || return 1
    if [ "${S5_SKIP_OWNERSHIP:-0}" != 1 ]; then
        chown root:root "$S5_BINARY_TEMP" || return 1
    fi
    # Arm fresh-install cleanup before the pathname becomes authoritative. Update
    # already has its rollback copy and S5_BINARY_REPLACED set.
    if [ "$S5_BINARY_REPLACED" != 1 ]; then S5_CREATED_BIN=1; fi
    mv -f "$S5_BINARY_TEMP" "$S5_BIN" || return 1
    S5_BINARY_TEMP=''
    s5_record_digest binary "$S5_BIN" || return 1
    S5_BINARY_SHA256=$S5_RECORDED_DIGEST
    [ "$S5_BINARY_SHA256" = "$S5_ASSET_SHA256" ]
}

s5_cleanup_binary_temp() {
    [ -n "$S5_BINARY_TEMP" ] || return 0
    if ! rm -f "$S5_BINARY_TEMP" 2>/dev/null; then
        s5_msg_err cleanup.download "$S5_BINARY_TEMP"
        return 1
    fi
    S5_BINARY_TEMP=''
}

s5_require_update_space() {
    # $1 is the already verified installed byte count. The backup and candidate
    # coexist; two independent checks on one filesystem can each pass while the
    # sum cannot fit. Check their sum before writing either large file.
    s5_valid_decimal "$1" || return 1
    _srus_id=$(s5_fs_id "$S5_TXNDIR" 2>/dev/null) || _srus_id=''
    if [ -n "$_srus_id" ] && [ "$_srus_id" = "$(s5_fs_id "$S5_PREFIX" 2>/dev/null)" ]; then
        s5_require_space "$S5_TXNDIR" "$(($1 + S5_ASSET_SIZE))"
    else
        s5_require_space "$S5_TXNDIR" "$1" || return 1
        s5_require_space "$S5_PREFIX" "$S5_ASSET_SIZE"
    fi
}

s5_stage_engine() {
    # The candidate is downloaded directly beside its final pathname and becomes
    # the installed file by rename, so fresh staging needs one raw binary only.
    s5_require_space "$S5_PREFIX" "$S5_ASSET_SIZE" || return 1
    S5_BINARY_TEMP=$(mktemp "$S5_PREFIX/.xray.XXXXXX") || return 1
    s5_fetch_binary "$S5_BINARY_TEMP" || return 1
    s5_verify_binary_candidate "$S5_BINARY_TEMP" || return 1
    s5_publish_binary_candidate
}

s5_release_prefix_private() {
    [ "$S5_PREFIX_PRIVATE" = 1 ] || return 0
    # Leaving the prefix at 0700 locks the service account out of its own
    # installation, so this failure is named. Without a message the operator saw
    # only chmod's own untranslated line and no statement of what it meant.
    if [ ! -d "$S5_PREFIX" ] || [ -L "$S5_PREFIX" ] || ! chmod 0755 "$S5_PREFIX"; then
        s5_msg_err prefix.mode "$S5_PREFIX"
        return 1
    fi
    S5_PREFIX_PRIVATE=0
}

s5_download_engine() {
    s5_asset_select || return 1
    if [ ! -d "$S5_PREFIX" ]; then S5_CREATED_PREFIX=1; fi
    # The private mode shields the staging window, where the partially written
    # .xray.XXXXXX temporary lives. Publication must hand back the documented 0755
    # on failure as well as success: an update reuses an existing directory, and
    # leaving it private locks the service account out of its own installation.
    # Staging is its own function so no early return can skip the restore.
    # Arm cleanup before changing the mode: a signal between chmod and the next
    # shell statement must still know that an existing prefix needs restoring.
    S5_PREFIX_PRIVATE=1
    if ! s5_mkdir_private "$S5_PREFIX"; then
        # A normal failure returned without opening the window; only an
        # asynchronous signal inside the function needs cleanup to close it.
        S5_PREFIX_PRIVATE=0
        return 1
    fi
    s5_stage_engine
    _sde_stage=$?
    _sde_cleanup=0
    _sde_restore=0
    if [ "$S5_CREATED_PREFIX" = 1 ]; then
        if [ "$_sde_stage" -ne 0 ]; then
            # A failed fresh install owns this disposable private prefix. Unified
            # cleanup removes it and its partial files; restoring 0755 would expose a
            # namespace that was never a usable installation and emit a false warning.
            return "$_sde_stage"
        fi
        # A successful fresh install has already renamed its only candidate.
        s5_release_prefix_private
        return $?
    fi
    s5_close_staging
    _sde_close=$?
    [ "$_sde_stage" -eq 0 ] || return "$_sde_stage"
    [ "$_sde_close" -eq 0 ] || return 1
    return 0
}

# s5_close_staging: release a partial prefix-local candidate, then hand an
# existing installation's prefix back its traversal; a fresh prefix stays private
# until its cleanup removes it. Both steps are attempted so both diagnostics
# survive. Returns 1 when the candidate stayed, 2 when the prefix did, 3 for both.
s5_close_staging() {
    _scst=0
    s5_cleanup_binary_temp || _scst=1
    if [ "$S5_CREATED_PREFIX" != 1 ] && ! s5_release_prefix_private; then
        _scst=$((_scst + 2))
    fi
    return "$_scst"
}

# A configuration-only update hashes the installed executable three times, and
# each one closes a different window: the state load before the prompts, this
# re-check after them and before the healthy service is stopped, and the state
# writer's check before it records the digest. None of them is a repeat.
s5_binary_ready() {
    [ -x "$S5_BIN" ] && [ ! -L "$S5_BIN" ] || return 1
    [ "$(s5_sha256 "$S5_BIN" 2>/dev/null)" = "$S5_ASSET_SHA256" ]
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
        create-user)
            adduser -S -D -H -h /nonexistent -G "$S5_SERVICE_GROUP" \
                -s "$(s5_nologin_path)" "$S5_SERVICE_USER"
            ;;
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

s5_require_absent() {
    # Fail closed on an identity we did not create: an existing name must never
    # be adopted, and one we cannot resolve is treated as unsafe rather than free.
    s5_getent_state "$1" "$2"
    case $? in
    0) s5_msg_err account.exists "$2"; return 1 ;;
    1) return 0 ;;
    *) s5_msg_err account.identity; return 1 ;;
    esac
}

s5_account_create() {
    s5_require_absent passwd "$S5_SERVICE_USER" || return 1
    s5_require_absent group "$S5_SERVICE_GROUP" || return 1
    # Each flag is armed before its tool runs. Armed after, a signal landing
    # between a successful tool and the assignment leaked the account, and the
    # next install refused it as a foreign identity. A flag armed for an account
    # the tool never created is harmless: removal tolerates an absent name.
    S5_CREATED_GROUP=1
    s5_account_tool create-group || { S5_CREATED_GROUP=0; s5_msg_err account.failed "$S5_SERVICE_GROUP"; return 1; }
    S5_CREATED_USER=1
    if ! s5_account_tool create-user; then
        S5_CREATED_USER=0
        s5_msg_err account.failed "$S5_SERVICE_USER"
        if s5_account_tool delete-group; then S5_CREATED_GROUP=0; fi
        return 1
    fi
    S5_ACCOUNT_UID=$(id -u "$S5_SERVICE_USER" 2>/dev/null) || return 1
    S5_ACCOUNT_GID=$(id -g "$S5_SERVICE_USER" 2>/dev/null) || return 1
    return 0
}

# s5_group_gid: the GID the service group name resolves to.
s5_group_gid() {
    getent group "$S5_SERVICE_GROUP" 2>/dev/null | awk -F: 'NR == 1 { print $3 }'
}

# s5_account_user_matches <uid> <gid>: the service user has exactly that identity.
s5_account_user_matches() {
    _saum_uid=$(id -u "$S5_SERVICE_USER" 2>/dev/null) || return 1
    _saum_gid=$(id -g "$S5_SERVICE_USER" 2>/dev/null) || return 1
    [ "$_saum_uid:$_saum_gid" = "$1:$2" ]
}

# s5_account_group_matches <gid>: the service group name resolves to that GID.
# The group is removed by name, so on every backend -- not only Alpine -- the name
# must still resolve to the recorded GID. A group that drifted to a new GID, or a
# same-named group created by something else, must not be deleted: uninstall
# removes only the resources this installation recorded.
s5_account_group_matches() {
    _sagm_gid=$(s5_group_gid) || return 1
    [ -n "$_sagm_gid" ] && [ "$_sagm_gid" = "$1" ]
}

# s5_account_identity <uid> <gid>: both halves of the account match that record.
s5_account_identity() {
    [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
    s5_account_user_matches "$1" "$2" && s5_account_group_matches "$2"
}

# The one account removal, for install cleanup and uninstall alike. Each half that
# is still present must match the recorded identity before it is deleted, so an
# uninstall resumed between the two deletions finishes the second. Without a
# record -- a cleanup before the account was read back -- only a half this run
# created is removed. Returns 1 for an identity that no longer matches, having
# said so, and 2 once a lookup or a deletion tool failed and was warned about.
s5_account_remove() {
    if [ "$S5_CREATED_USER" = 1 ] || [ -n "$S5_ACCOUNT_UID" ]; then
        s5_getent_state passwd "$S5_SERVICE_USER"
        case $? in
        0)
            if [ -n "$S5_ACCOUNT_UID" ] &&
                ! s5_account_user_matches "$S5_ACCOUNT_UID" "$S5_ACCOUNT_GID"; then
                s5_account_mismatch
                return 1
            fi
            s5_account_tool delete-user || {
                s5_msg_warn account.remove.user "$S5_SERVICE_USER"
                return 2
            }
            ;;
        1) ;;
        *) s5_msg_warn account.remove.user.verify "$S5_SERVICE_USER"; return 2 ;;
        esac
        s5_getent_state passwd "$S5_SERVICE_USER"
        case $? in
        1) ;;
        0) s5_msg_warn account.remove.user.exists "$S5_SERVICE_USER"; return 2 ;;
        *) s5_msg_warn account.remove.user.verify "$S5_SERVICE_USER"; return 2 ;;
        esac
    fi
    if [ "$S5_CREATED_GROUP" = 1 ] || [ -n "$S5_ACCOUNT_GID" ]; then
        s5_getent_state group "$S5_SERVICE_GROUP"
        case $? in
        0)
            if [ -n "$S5_ACCOUNT_GID" ] && ! s5_account_group_matches "$S5_ACCOUNT_GID"; then
                s5_account_mismatch
                return 1
            fi
            s5_account_tool delete-group || {
                s5_msg_warn account.remove.group "$S5_SERVICE_GROUP"
                return 2
            }
            ;;
        1) ;;
        *) s5_msg_warn account.remove.group.before "$S5_SERVICE_GROUP"; return 2 ;;
        esac
        s5_getent_state group "$S5_SERVICE_GROUP"
        case $? in
        1) ;;
        0) s5_msg_warn account.remove.group.exists "$S5_SERVICE_GROUP"; return 2 ;;
        *) s5_msg_warn account.remove.group.verify "$S5_SERVICE_GROUP"; return 2 ;;
        esac
    fi
    S5_CREATED_USER=0
    S5_CREATED_GROUP=0
    return 0
}

s5_account_mismatch() {
    s5_msg_warn account.remove.identity "$S5_ACCOUNT_UID" "$S5_ACCOUNT_GID"
    s5_msg_err account.identity
}

s5_write_config_candidate() {
    _swct=$(mktemp "$S5_SYSCONFDIR/.s5new.XXXXXX") || return 1
    rm -f "$_swct" || return 1
    _swcc=$_swct.json
    # Rendered in memory and written once through the private atomic writer: a
    # separate plaintext staging file was one more copy of the credential on
    # disk. A render failure is caught before anything is written.
    _swcc_body=$(s5_config_render) || return 1
    if ! printf '%s\n' "$_swcc_body" | s5_atomic_write "$_swcc" "root:$S5_SERVICE_GROUP" 0640; then
        _swcc_body=''
        return 1
    fi
    _swcc_body=''
    # An update has a published config the rejection leaves alone; a fresh
    # install has none, and saying the old one was unchanged misled it.
    if ! s5_config_test "$_swcc"; then
        rm -f "$_swcc"
        if [ -e "$S5_CFG" ] || [ -L "$S5_CFG" ]; then
            s5_msg_err config.invalid
        else
            s5_msg_err config.invalid.fresh
        fi
        return 1
    fi
    printf '%s' "$_swcc"
}

s5_write_unit() {
    s5_select_service_artifact && s5_unit_mode || return 1
    case "$S5_INIT" in
    openrc)
        if [ ! -d "$S5_INITSCRIPTDIR" ]; then
            s5_mkdir_parents "$S5_INITSCRIPTDIR" || return 1
        fi
        s5_atomic_write "$S5_SERVICE_ARTIFACT" root:root "0$S5_UNIT_MODE" <<UNIT
#!/sbin/openrc-run

name="$S5_PROJECT"
description="Xray mixed SOCKS5 and HTTP proxy"
command="$S5_BIN"
command_args="run -c $S5_CFG"
command_user="$S5_SERVICE_USER:$S5_SERVICE_GROUP"
supervisor="supervise-daemon"
respawn_max=2
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
        s5_atomic_write "$S5_SERVICE_ARTIFACT" root:root "0$S5_UNIT_MODE" <<UNIT
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

# The schema discriminator: 1 or 2 from a single well-formed schema line, or
# "legacy" when the line is absent. A duplicate or empty line is invalid.
s5_state_schema() {
    awk -F '\t' '
        $1 == "schema" {
            if (NF != 2 || $2 == "" || seen++) exit 1
            schema=$2
        }
        END {
            if (seen > 1) exit 1
            print seen == 1 ? schema : "legacy"
        }
    ' "$1" 2>/dev/null
}

# Parse every supported on-disk schema into one normalized record in
# S5_STATE_FIELDS order. The schema-specific key sets remain strict: accepting
# schema-2 names in schema 1 would make a partially migrated state look
# authoritative, while rejecting old archive fields would strand installations
# created by earlier scripts. Emit one value per line only after the whole schema
# passes. Values cannot contain tabs/newlines; read -r consumes them as data,
# never code. The legacy schema omits family, represented by an empty line.
s5_state_parse_file() {
    _sspf_schema=$(s5_state_schema "$1") || return 1
    case "$_sspf_schema" in
    legacy | 1)
        awk -F '\t' -v expected="$_sspf_schema" -v stored="$S5_STATE_V1_FIELDS" \
            -v record="$S5_STATE_FIELDS" '
            BEGIN {
                count=split(stored, keys, " ")
                fields=split(record, out, " ")
                for (i=1; i<=count; i++) allowed[keys[i]]=1
                valid=1
            }
            {
                if (NF != 2 || $1 == "" || $2 == "") valid=0
                if (!($1 in allowed) || seen[$1]++) valid=0
                values[$1]=$2
            }
            END {
                if (expected == "legacy") {
                    if ((NR != count - 2 && NR != count - 1) || ("schema" in seen)) valid=0
                    if (!("family" in seen)) values["family"]=""
                    values["schema"]="legacy"
                } else {
                    if (NR != count || values["schema"] != "1" || !("family" in seen)) valid=0
                }
                for (i=1; i<=count; i++) {
                    if (keys[i] == "schema") continue
                    if (keys[i] == "family" && expected == "legacy" && !("family" in seen)) continue
                    if (!(keys[i] in seen)) valid=0
                }
                if (!valid) exit 1
                for (i=1; i<=fields; i++) {
                    if (out[i] == "distribution_tag") print "xray-" values["release"]
                    else if (out[i] == "asset_format") print "zip"
                    else if (out[i] == "asset_size") print values["archive_size"]
                    else if (out[i] == "asset_sha256") print values["archive_sha256"]
                    else print values[out[i]]
                }
            }
        ' "$1" 2>/dev/null
        ;;
    2)
        awk -F '\t' -v stored="$S5_STATE_FIELDS" '
            BEGIN {
                count=split(stored, keys, " ")
                for (i=1; i<=count; i++) allowed[keys[i]]=1
                valid=1
            }
            {
                if (NF != 2 || $1 == "" || $2 == "") valid=0
                if (!($1 in allowed) || seen[$1]++) valid=0
                values[$1]=$2
            }
            END {
                if (NR != count || values["schema"] != "2") valid=0
                for (i=1; i<=count; i++) if (!(keys[i] in seen)) valid=0
                if (!valid) exit 1
                for (i=1; i<=count; i++) print values[keys[i]]
            }
        ' "$1" 2>/dev/null
        ;;
    *) return 4 ;;
    esac
}

# s5_state_table <schema> <prefix>: the "key:variable" table of a schema's
# stored keys, each held in <prefix><normalized key>, so schema 1's archive
# fields share the asset fields' variables. The prefix is the caller's own.
s5_state_table() {
    case "$1" in 2) _sst_fields=$S5_STATE_FIELDS ;; *) _sst_fields=$S5_STATE_V1_FIELDS ;; esac
    for _sst_key in $_sst_fields; do
        case "$_sst_key" in
        archive_size) printf ' %s:%sasset_size' "$_sst_key" "$2" ;;
        archive_sha256) printf ' %s:%sasset_sha256' "$_sst_key" "$2" ;;
        *) printf ' %s:%s%s' "$_sst_key" "$2" "$_sst_key" ;;
        esac
    done
}

# s5_record_read <table>: read one line per "key:variable" word of the table from
# stdin into that variable. Both the tables and their names are constants of this
# script, and eval sees the value only as a reference, never as code.
s5_record_read() {
    for _srcr_pair in $1; do
        IFS= read -r _srcr_value || return 1
        eval "${_srcr_pair#*:}=\$_srcr_value"
    done
    _srcr_value=''
}

# s5_record_print <table>: print "key<TAB>value" for every word of the table.
s5_record_print() {
    for _srcp_pair in $1; do
        eval "_srcp_value=\${${_srcp_pair#*:}}"
        printf '%s\t%s\n' "${_srcp_pair%%:*}" "$_srcp_value"
    done
    _srcp_value=''
}

s5_valid_commit() {
    [ "${#1}" -eq 40 ] || return 1
    case "$1" in *[!0-9a-fA-F]*) return 1 ;; esac
}

s5_valid_distribution_tag() {
    _svdt_release=$1
    _svdt_tag=$2
    case "$_svdt_tag" in
    "xray-$_svdt_release-r"*) _svdt_revision=${_svdt_tag#"xray-$_svdt_release-r"} ;;
    *) return 1 ;;
    esac
    s5_valid_decimal "$_svdt_revision"
}

# s5_asset_identity <prefix>: whether <prefix>schema, release, distribution_tag,
# asset_format, asset, asset_size, asset_sha256, binary_size, binary_sha256 and
# arch describe one asset this script can have installed. The loop assigns the
# fields by name, which ShellCheck cannot see.
# shellcheck disable=SC2154
s5_asset_identity() {
    for _said_key in schema release distribution_tag asset_format asset asset_size \
        asset_sha256 binary_size binary_sha256 arch; do
        eval "_said_$_said_key=\${$1$_said_key}"
    done
    case "$_said_schema:$_said_asset_format" in
    legacy:zip | 1:zip)
        [ "$_said_distribution_tag" = "xray-$_said_release" ] || return 1
        case "$_said_arch:$_said_asset" in
        amd64:Xray-linux-64.zip | arm64:Xray-linux-arm64-v8a.zip) ;;
        *) return 1 ;;
        esac
        ;;
    2:raw)
        s5_valid_distribution_tag "$_said_release" "$_said_distribution_tag" || return 1
        case "$_said_arch:$_said_asset" in
        amd64:"xray-$_said_release-linux-amd64" | arm64:"xray-$_said_release-linux-arm64") ;;
        *) return 1 ;;
        esac
        [ "$_said_asset_size" = "$_said_binary_size" ] &&
            [ "$_said_asset_sha256" = "$_said_binary_sha256" ] || return 1
        ;;
    *) return 1 ;;
    esac
    s5_valid_decimal "$_said_asset_size" && s5_valid_sha256 "$_said_asset_sha256" &&
        s5_valid_decimal "$_said_binary_size" && s5_valid_sha256 "$_said_binary_sha256"
}

s5_state_write() {
    s5_valid_port "$S5_PORT" && s5_valid_username "$S5_USERNAME" &&
        s5_ipv4_is_canonical "$S5_LISTEN" || return 1
    s5_backend_supported || return 1
    s5_valid_decimal "$S5_ACCOUNT_UID" && s5_valid_decimal "$S5_ACCOUNT_GID" &&
        s5_valid_sha256 "$S5_CONFIG_SHA256" && s5_valid_sha256 "$S5_UNIT_SHA256" || return 1

    # A configuration-only update records how the installed bytes were actually
    # acquired. In particular, a ZIP-era installation is not relabelled as raw
    # merely because a later script distributes identical executable bytes.
    case "$S5_UPDATE_NEEDS_BINARY:$S5_INSTALLED_SCHEMA" in
    0:legacy | 0:1 | 0:2)
        _ssw_schema=$S5_INSTALLED_SCHEMA
        [ "$_ssw_schema" != legacy ] || _ssw_schema=1
        _ssw_release=$S5_INSTALLED_RELEASE
        _ssw_commit=$S5_INSTALLED_COMMIT
        _ssw_distribution_tag=$S5_INSTALLED_DISTRIBUTION_TAG
        _ssw_asset_format=$S5_INSTALLED_ASSET_FORMAT
        _ssw_asset=$S5_INSTALLED_ASSET_NAME
        _ssw_asset_size=$S5_INSTALLED_ASSET_SIZE
        _ssw_asset_sha256=$S5_INSTALLED_ASSET_SHA256
        _ssw_binary_size=$S5_INSTALLED_BINARY_SIZE
        _ssw_binary_sha256=$S5_INSTALLED_BINARY_SHA256
        ;;
    *)
        _ssw_schema=2
        _ssw_release=$S5_XRAY_VERSION
        _ssw_commit=$S5_XRAY_COMMIT
        _ssw_distribution_tag=$S5_XRAY_DISTRIBUTION_TAG
        _ssw_asset_format=raw
        _ssw_asset=$S5_ASSET_NAME
        _ssw_asset_size=$S5_ASSET_SIZE
        _ssw_asset_sha256=$S5_ASSET_SHA256
        _ssw_binary_size=$S5_ASSET_SIZE
        _ssw_binary_sha256=$S5_ASSET_SHA256
        ;;
    esac
    _ssw_arch=$S5_ARCHNAME
    s5_valid_release "$_ssw_release" && s5_valid_commit "$_ssw_commit" || return 1
    s5_asset_identity _ssw_ || return 1
    [ "$S5_BINARY_SHA256" = "$_ssw_binary_sha256" ] || return 1
    [ "$(s5_bytecount "$S5_BIN" 2>/dev/null)" = "$_ssw_binary_size" ] || return 1
    [ "$(s5_sha256 "$S5_BIN" 2>/dev/null)" = "$S5_BINARY_SHA256" ] || return 1
    _ssw_engine=xray
    _ssw_protocol=mixed
    _ssw_auth=password
    _ssw_udp=false
    _ssw_listen=$S5_LISTEN
    _ssw_port=$S5_PORT
    _ssw_username=$S5_USERNAME
    # Recorded for diagnosis only, so nothing reads it back by name: the state
    # table writes it out.
    # shellcheck disable=SC2034
    _ssw_os=$S5_OS_ID-$S5_OS_VERSION_ID
    _ssw_family=$S5_OS_FAMILY
    _ssw_init=$S5_INIT
    _ssw_account_uid=$S5_ACCOUNT_UID
    _ssw_account_gid=$S5_ACCOUNT_GID
    _ssw_config_sha256=$S5_CONFIG_SHA256
    _ssw_unit_sha256=$S5_UNIT_SHA256
    _ssw_status=complete
    _ssw_record=$(s5_record_print "$(s5_state_table "$_ssw_schema" _ssw_)") || return 1
    s5_atomic_write "$S5_STATE" root:root 0600 <<STATE
$_ssw_record
STATE
}

s5_valid_decimal() {
    case "${1:-}" in '' | *[!0-9]*) return 1 ;; esac
}

s5_valid_sha256() {
    [ "${#1}" -eq 64 ] || return 1
    case "$1" in *[!0-9a-fA-F]*) return 1 ;; esac
}

s5_valid_release() {
    case "$1" in v*) _svr=${1#v} ;; *) return 1 ;; esac
    _svr_count=0
    while :; do
        _svrp=${_svr%%.*}
        s5_valid_decimal "$_svrp" || return 1
        [ "${#_svrp}" -le 18 ] || return 1
        _svr_count=$((_svr_count + 1))
        case "$_svr" in
        *.*) _svr=${_svr#*.}; [ -n "$_svr" ] || return 1 ;;
        *) break ;;
        esac
    done
    [ "$_svr_count" -eq 3 ]
}

s5_path_contract() {
    # path type owner:group mode. Tests may skip only the host identity lookup;
    # type, symlink and mode checks remain the production implementation.
    _spc_path=$1
    _spc_type=$2
    _spc_owner=$3
    _spc_mode=$4
    [ ! -L "$_spc_path" ] || return 1
    case "$_spc_type" in
    file) [ -f "$_spc_path" ] ;;
    dir) [ -d "$_spc_path" ] ;;
    exec) [ -f "$_spc_path" ] && [ -x "$_spc_path" ] ;;
    *) return 1 ;;
    esac || return 1
    _spc_stat=$(stat -c '%U:%G %a' "$_spc_path" 2>/dev/null) || return 1
    [ "${_spc_stat##* }" = "$_spc_mode" ] || return 1
    if [ "${S5_SKIP_OWNERSHIP:-0}" != 1 ]; then
        [ "${_spc_stat% *}" = "$_spc_owner" ] || return 1
    fi
}

s5_verify_installed_artifacts() {
    # Exact type, ownership and mode are part of installed identity, not merely
    # hardening applied at creation time. Config drift retains its distinct class.
    s5_path_contract "$S5_PREFIX" dir root:root 755 || return 1
    s5_path_contract "$S5_BIN" exec root:root 755 || return 1
    s5_path_contract "$S5_SYSCONFDIR" dir "root:$S5_SERVICE_GROUP" 750 || return 1
    s5_path_contract "$S5_CFG" file "root:$S5_SERVICE_GROUP" 640 || return 1
    s5_path_contract "$S5_STATEDIR" dir root:root 700 || return 1
    s5_path_contract "$S5_STATE" file root:root 600 || return 1
    s5_unit_mode || return 1
    s5_path_contract "$S5_SERVICE_ARTIFACT" "$S5_UNIT_TYPE" root:root "$S5_UNIT_MODE" || return 1
    [ "$(s5_sha256 "$S5_SERVICE_ARTIFACT" 2>/dev/null)" = "$S5_UNIT_SHA256" ] || return 1
    [ "$(s5_sha256 "$S5_CFG" 2>/dev/null)" = "$S5_CONFIG_SHA256" ] || return 2
    [ "$(s5_bytecount "$S5_BIN" 2>/dev/null)" = "$S5_INSTALLED_BINARY_SIZE" ] || return 1
    [ "$(s5_sha256 "$S5_BIN" 2>/dev/null)" = "$S5_INSTALLED_BINARY_SHA256" ] || return 1
    return 0
}

# s5_record_read assigns the record's fields by name, which ShellCheck cannot see.
# shellcheck disable=SC2154
s5_state_load() {
    _sload_current_family=$S5_OS_FAMILY
    _sload_current_init=$S5_INIT
    _sload_current_arch=$S5_ARCHNAME
    if [ ! -e "$S5_STATE" ] && [ ! -L "$S5_STATE" ]; then
        return 3
    fi
    s5_path_contract "$S5_STATE" file root:root 600 || return 1
    _sload_fields=$(s5_state_parse_file "$S5_STATE")
    _sload_parse=$?
    [ "$_sload_parse" -eq 0 ] || { [ "$_sload_parse" -eq 4 ] && return 4; return 1; }
    s5_record_read "$(s5_state_table 2 _sload_)" <<STATE_FIELDS || return 1
$_sload_fields
STATE_FIELDS
    _sload_fields=''
    S5_LISTEN=$_sload_listen
    S5_PORT=$_sload_port
    S5_USERNAME=$_sload_username
    S5_ARCHNAME=$_sload_arch
    S5_OS_FAMILY=$_sload_family
    S5_INIT=$_sload_init
    S5_ACCOUNT_UID=$_sload_account_uid
    S5_ACCOUNT_GID=$_sload_account_gid
    S5_CONFIG_SHA256=$_sload_config_sha256
    S5_UNIT_SHA256=$_sload_unit_sha256
    [ "$_sload_engine" = xray ] || return 1
    s5_valid_release "$_sload_release" && s5_valid_commit "$_sload_commit" || return 1
    s5_asset_identity _sload_ || return 1
    [ "$_sload_protocol" = mixed ] && [ "$_sload_auth" = password ] &&
        [ "$_sload_udp" = false ] || return 1
    [ "$_sload_status" = complete ] || return 4
    S5_INSTALLED_SCHEMA=$_sload_schema
    S5_INSTALLED_RELEASE=$_sload_release
    S5_INSTALLED_COMMIT=$_sload_commit
    S5_INSTALLED_DISTRIBUTION_TAG=$_sload_distribution_tag
    S5_INSTALLED_ASSET_FORMAT=$_sload_asset_format
    S5_INSTALLED_ASSET_NAME=$_sload_asset
    S5_INSTALLED_ASSET_SIZE=$_sload_asset_size
    S5_INSTALLED_ASSET_SHA256=$_sload_asset_sha256
    S5_INSTALLED_BINARY_SIZE=$_sload_binary_size
    S5_INSTALLED_BINARY_SHA256=$_sload_binary_sha256
    S5_BINARY_SHA256=$_sload_binary_sha256
    if [ -z "$S5_OS_FAMILY" ]; then
        case "$S5_INIT" in systemd) S5_OS_FAMILY=debian ;; *) return 1 ;; esac
    fi
    if [ -n "$_sload_current_family" ]; then
        [ "$S5_OS_FAMILY" = "$_sload_current_family" ] || return 1
    fi
    [ -n "$_sload_current_init" ] && [ "$_sload_current_init" = "$S5_INIT" ] || return 1
    # Like family and init, the recorded architecture must be this host's. A
    # state carried from another machine would otherwise select that machine's
    # asset for an update and describe a binary this host cannot run.
    if [ -n "$_sload_current_arch" ]; then
        [ "$S5_ARCHNAME" = "$_sload_current_arch" ] || return 1
    fi
    s5_backend_supported || return 1
    s5_select_service_artifact || return 1
    s5_valid_port "$S5_PORT" && s5_valid_stored_username "$S5_USERNAME" &&
        s5_ipv4_is_canonical "$S5_LISTEN" || return 1
    s5_verify_installed_artifacts
    _sload_result=$?
    case "$_sload_result" in
    0) ;;
    2) return 2 ;;
    *) return 1 ;;
    esac
    s5_account_identity "$S5_ACCOUNT_UID" "$S5_ACCOUNT_GID" || return 1
    return 0
}

# s5_open_managed_state [update]: the command-facing state seam; callers do not
# reimplement schema or release rules. Only update changes what it does: it keeps
# the rollback traps and decides whether the binary must be replaced.
s5_open_managed_state() {
    case "${1:-}" in '' | update) ;; *) return 1 ;; esac
    if [ -e "$S5_TXNDIR" ] || [ -L "$S5_TXNDIR" ]; then
        # Recovery restores files, copies the old executable back and restarts
        # the service, whichever command found the transaction. Under a
        # lock-only trap an interrupt abandoned it half done with an untracked
        # binary temporary; under the rollback traps cleanup resumes it. The
        # lock-only commands get their own traps back once it is over.
        s5_trap_rollback
        s5_transaction_recover
        _somr=$?
        [ "${1:-}" = update ] || s5_trap_lock_only
        [ "$_somr" -eq 0 ] || return 5
    fi
    if [ "$S5_STATE_PRELOADED" = 1 ]; then
        _som_status=0
    else
        s5_state_load
        _som_status=$?
    fi
    S5_STATE_PRELOADED=0
    [ "$_som_status" -eq 0 ] || return "$_som_status"
    S5_UPDATE_NEEDS_BINARY=0
    if [ "${1:-}" = update ]; then
        s5_asset_select || return 1
        if [ "$S5_INSTALLED_RELEASE" != "$S5_XRAY_VERSION" ] ||
            [ "$S5_INSTALLED_COMMIT" != "$S5_XRAY_COMMIT" ] ||
            [ "$S5_INSTALLED_BINARY_SIZE" != "$S5_ASSET_SIZE" ] ||
            [ "$S5_INSTALLED_BINARY_SHA256" != "$S5_ASSET_SHA256" ]; then
            S5_UPDATE_NEEDS_BINARY=1
        fi
    fi
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

def http_status_code(status):
    fields = status.split(b" ", 2)
    if (len(fields) < 2 or fields[0] not in (b"HTTP/1.0", b"HTTP/1.1") or
            len(fields[1]) != 3 or not fields[1].isdigit()):
        raise RuntimeError("http auth response")
    return fields[1]

def http_auth_discriminates():
    """Wrong credentials receive 407; real credentials receive an HTTP response.

    The destination is inside the boundary, so a 200 is neither expected nor
    required. The positive side still has to be a complete HTTP status line: an
    empty or malformed reply from a broken inbound is not evidence that it
    accepted the real credential.
    """
    if http_status_code(http_status(password + "x")) != b"407":
        raise RuntimeError("http bad auth accepted")
    if http_status_code(http_status(password)) == b"407":
        raise RuntimeError("http auth")

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
    # A machine-readable token, not an operator sentence: the shell renders it
    # through the catalog in the chosen language.
    reason = str(exc) or type(exc).__name__
    raise SystemExit("dataplane-reason=%s: %s" % (type(exc).__name__, reason))
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
        _svd_pass=$(mktemp "$(s5_tmp_base)/.s5pass.XXXXXX") || { s5_msg_err service.dataplane "$S5_PORT"; return 1; }
        # Restart has no workdir, so signal cleanup must track this credential file explicitly.
        S5_VERIFY_TEMP=$_svd_pass
        _svd_reason=''
        if chmod 0600 "$_svd_pass" && printf '%s\n%s\n' "$S5_USERNAME" "$S5_PASSWORD" >"$_svd_pass"; then
            # The verifier's output goes to a private file released with the
            # credential file. Only its own reason token is shown, as data in
            # the catalog sentence of the chosen language.
            s5_verify_protocols "$S5_PORT" "$_svd_pass" >"$_svd_pass.reason" 2>&1
            _svd=$?
            _svd_reason=$(sed -n 's/.*dataplane-reason=//p' "$_svd_pass.reason" 2>/dev/null |
                head -n 1 | tr -cd 'A-Za-z0-9 :._-')
        else
            _svd=1
        fi
        rm -f "$_svd_pass" "$_svd_pass.reason"
        S5_VERIFY_TEMP=''
    fi
    # The listener was already proven; saying "could not be verified" here sent
    # the operator after the port instead of the traffic check that failed.
    if [ "$_svd" -ne 0 ]; then
        if [ -n "${_svd_reason:-}" ]; then
            s5_msg_err service.dataplane.reason "$S5_PORT" "$_svd_reason"
        else
            s5_msg_err service.dataplane "$S5_PORT"
        fi
        return 1
    fi
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
        # under a live proxy. 32 positively reports a crashed child but the
        # supervisor is still managed, so it is distinct for status while every
        # destructive stop boundary continues to fail closed on it. 64 is
        # supervise-daemon's "unsupervised": the supervisor is gone but its
        # child record remains, so the child may still run with nothing
        # watching it. Native Alpine reports this for a killed supervisor.
        case $? in 0 | 8) return 0 ;; 3) return 1 ;; 32) return 3 ;; 64) return 5 ;; *) return 2 ;; esac
        ;;
    *)
        # is-active exits 3 for every state that is not active, so only its word
        # separates a stopped unit from one that failed: exit 23, or a spent
        # restart budget. Failed is final and its processes are gone, but it is
        # not what the operator asked for, so it gets its own 4. activating
        # (including a pending auto-restart), deactivating and any unrecognised
        # word leave the state unproven.
        _sssword=$(systemctl is-active "$S5_PROJECT.service" 2>/dev/null)
        case "$?:$_sssword" in
        0:*) return 0 ;;
        3:inactive) return 1 ;;
        3:failed) return 4 ;;
        *) return 2 ;;
        esac
        ;;
    esac
}

s5_openrc_start() {
    # The "nonzero but already active" fallback is only sound for start, which is
    # idempotent. For restart an old instance that survived a failed stop also
    # looks active, so restart propagates rc-service's status directly. This
    # function is start-only, so the verb stays a literal rather than a parameter.
    rc-service "$S5_PROJECT" start
    _sosrc=$?
    [ "$_sosrc" -eq 0 ] && return 0
    s5_service_state
    _sosactive=$?
    [ "$_sosactive" -eq 0 ] && return 0
    return "$_sosrc"
}

s5_svc() {
    # The single place that branches on the init backend for the lifecycle verbs.
    # Each of start/stop/restart/enable/disable/reload maps to one backend command
    # (OpenRC has nothing to reload, so its reload succeeds as a no-op), so the
    # backend decision is made once here rather than repeated per verb. start keeps
    # OpenRC's idempotent fallback (s5_openrc_start); s5_service_state and
    # s5_listener_state stay separate, since each carries a backend-specific
    # exit-code contract rather than this shared verb switch.
    if [ "$S5_INIT" = openrc ]; then
        case "$1" in
        start) s5_openrc_start ;;
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
        # A failed systemd unit is as stopped as an inactive one: nothing will
        # restart it and its processes were killed with the unit. OpenRC's
        # crashed (3) still has a managing supervisor, so it stays fail closed.
        case $? in 1 | 4) return 0 ;; 0 | 2) ;; *) return 2 ;; esac
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
        # Absent means no supervised child, so nothing of ours listens. A file
        # that exists but cannot be read or holds no pid proves nothing either
        # way, and systemd reports that case as unobservable too.
        [ -e "$S5_OPENRC_OPTION_DIR/child_pid" ] || [ -L "$S5_OPENRC_OPTION_DIR/child_pid" ] || return 1
        _slpid=$(cat "$S5_OPENRC_OPTION_DIR/child_pid" 2>/dev/null) || return 2
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
    _swllast=1
    while [ "$_swli" -lt 30 ]; do
        s5_listener_state "$_swlp"
        _swllast=$?
        # OpenRC writes child_pid only once supervise-daemon has spawned the
        # child, so an early poll can be unobservable without anything wrong;
        # systemd knows MainPID as soon as start returns.
        case "$_swllast" in 0) return 0 ;; 1) ;; 2) [ "$S5_INIT" = openrc ] || return 2 ;; *) return 2 ;; esac
        _swli=$((_swli + 1))
        sleep 1
    done
    # The last observation decides the diagnosis: an OpenRC listener that never
    # became observable is unverified, not proven absent.
    return "$_swllast"
}

s5_transaction_file_contract() {
    _stfc_path=$1
    [ ! -e "$_stfc_path" ] && [ ! -L "$_stfc_path" ] && return 0
    s5_path_contract "$_stfc_path" file root:root 600
}

s5_transaction_contract() {
    s5_path_contract "$S5_TXNDIR" dir root:root 700 || return 1
    for _stc_name in $S5_TXN_BACKUPS $S5_TXN_MARKERS; do
        s5_transaction_file_contract "$S5_TXNDIR/$_stc_name" || return 1
    done
    if { [ -e "$S5_TXNDIR/old.unit" ] || [ -L "$S5_TXNDIR/old.unit" ]; } &&
        [ "$S5_INIT" != openrc ]; then return 1; fi
    if [ -f "$S5_TXN_UNIT_REPLACING" ] && [ ! -L "$S5_TXN_UNIT_REPLACING" ] &&
        { { [ ! -f "$S5_TXN_COMMITTED" ] || [ -L "$S5_TXN_COMMITTED" ]; } &&
          { [ ! -f "$S5_TXN_ROLLED_BACK" ] || [ -L "$S5_TXN_ROLLED_BACK" ]; }; }; then
        [ "$S5_INIT" = openrc ] && [ -f "$S5_TXN_STOPPING" ] &&
            [ ! -L "$S5_TXN_STOPPING" ] && [ -f "$S5_TXNDIR/old.unit" ] &&
            [ ! -L "$S5_TXNDIR/old.unit" ] || return 1
    fi
    for _stc_path in "$S5_TXNDIR"/.s5new.* "$S5_TXNDIR"/.s5tmp.*; do
        [ -e "$_stc_path" ] || [ -L "$_stc_path" ] || continue
        s5_path_contract "$_stc_path" file root:root 600 || return 1
    done
    for _stc_path in "$S5_TXNDIR"/* "$S5_TXNDIR"/.[!.]* "$S5_TXNDIR"/..?*; do
        [ -e "$_stc_path" ] || [ -L "$_stc_path" ] || continue
        _stc_name=${_stc_path#"$S5_TXNDIR"/}
        case "$_stc_name" in
        .s5new.* | .s5tmp.*) ;;
        *) s5_transaction_member "$_stc_name" || return 1 ;;
        esac
    done
    return 0
}

# s5_transaction_member <name>: whether a name is a backup or marker the
# transaction directory may hold.
s5_transaction_member() {
    case " $S5_TXN_BACKUPS $S5_TXN_MARKERS " in *" $1 "*) return 0 ;; esac
    return 1
}

s5_cleanup_transaction() {
    [ -e "$S5_TXNDIR" ] || [ -L "$S5_TXNDIR" ] || return 0
    s5_transaction_contract || return 1
    _sct_authority=''
    [ ! -f "$S5_TXN_COMMITTED" ] || _sct_authority=committed
    [ ! -f "$S5_TXN_ROLLED_BACK" ] || _sct_authority=rolled-back
    # Remove the intent marker before old.unit. A hard kill between those two
    # deletions then leaves a replayable extra backup, never a marker whose
    # required rollback copy has already disappeared.
    set -- "$S5_TXN_UNIT_REPLACING"
    for _sctn in $S5_TXN_BACKUPS; do set -- "$@" "$S5_TXNDIR/$_sctn"; done
    for _sctf in "$@" "$S5_TXNDIR"/.s5new.* "$S5_TXNDIR"/.s5tmp.* "$S5_TXN_STOPPING"; do
        [ -e "$_sctf" ] || [ -L "$_sctf" ] || continue
        [ ! -L "$_sctf" ] && [ -f "$_sctf" ] || return 1
        rm -f "$_sctf" || return 1
    done
    # Keep the commit marker through a failed rmdir so the next process cannot
    # mistake a partial delete-only cleanup for a rollback pair.
    rm -f "$S5_TXN_COMMITTED" "$S5_TXN_ROLLED_BACK" || return 1
    rmdir "$S5_TXNDIR" || {
        case "$_sct_authority" in
        rolled-back)
            s5_atomic_write "$S5_TXN_ROLLED_BACK" root:root 0600 <<ROLLED_BACK || return 1
rolled-back
ROLLED_BACK
            ;;
        *)
            s5_atomic_write "$S5_TXN_COMMITTED" root:root 0600 <<COMMITTED || return 1
committed
COMMITTED
            ;;
        esac
        return 1
    }
    S5_CREATED_TRANSACTION=0
    return 0
}

s5_transaction_recover() {
    [ -e "$S5_TXNDIR" ] || [ -L "$S5_TXNDIR" ] || return 0
    s5_transaction_contract || return 1
    if { [ -f "$S5_TXN_COMMITTED" ] && [ ! -L "$S5_TXN_COMMITTED" ]; } ||
        { [ -f "$S5_TXN_ROLLED_BACK" ] && [ ! -L "$S5_TXN_ROLLED_BACK" ]; }; then
        # Delete-only cleanup is allowed only while the authoritative state still
        # validates. Drift preserves remaining backups for diagnosis; a committed
        # update and a completed rollback are never reversed during cleanup.
        s5_state_load || return 1
        # The caller loads the state next; this validated load is the same one.
        S5_STATE_PRELOADED=1
        s5_cleanup_transaction
        return $?
    fi
    if [ -f "$S5_TXN_STOPPING" ] && [ ! -L "$S5_TXN_STOPPING" ]; then
        [ -f "$S5_TXNDIR/old.config.json" ] && [ -f "$S5_TXNDIR/old.state" ] || return 1
        S5_SERVICE_TOUCHED=1
        [ -f "$S5_TXNDIR/old.xray" ] || S5_BINARY_REPLACED=0
        s5_update_rollback "$S5_TXNDIR/old.config.json" "$S5_TXNDIR/old.state"
        return $?
    fi
    if [ -f "$S5_TXNDIR/old.xray" ]; then
        [ -f "$S5_TXNDIR/old.config.json" ] && [ -f "$S5_TXNDIR/old.state" ] || return 1
        S5_SERVICE_TOUCHED=0
        S5_BINARY_REPLACED=1
        s5_update_rollback "$S5_TXNDIR/old.config.json" "$S5_TXNDIR/old.state"
        return $?
    fi
    # Before binary replacement or stop, every live resource is untouched. A
    # hard crash can leave an empty or partial backup directory; deleting only
    # that private transaction is deterministic and does not rewrite live files.
    s5_cleanup_transaction
}

# s5_cleanup_own_temps <dir> [binaries]: remove the small private temporaries an
# interrupted write leaves. Binary candidates (.xray.*) are removed only when
# asked: uninstall approved them in preflight, and a prefix this run created
# holds nothing else. Failure cleanup of an existing prefix removes only the
# candidate it registered in S5_BINARY_TEMP and leaves any other run's.
s5_cleanup_own_temps() {
    _scotd=$1
    [ -d "$_scotd" ] || return 0
    # The patterns are quoted so they reach the inner glob intact. Unquoted, the
    # shell expanded them against the caller's working directory, and a match
    # there turned each word into a literal filename that the inner glob could
    # never find -- so running from an install directory skipped the cleanup.
    for _scotp in '.s5tmp.*' '.s5new.*' '.xray.*'; do
        [ "$_scotp" != '.xray.*' ] || [ "${2:-}" = binaries ] || continue
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
    # Ignore signals before claiming the cleanup. In the other order a signal
    # between the two lines entered a nested cleanup that saw the flag, returned
    # at once and exited: no rollback, and the lock left held.
    trap '' HUP INT TERM
    S5_IN_CLEANUP=1
    _sclstatus=0
    _scldownload=0
    # A handled signal can enter cleanup from inside the staging function, before
    # s5_download_engine regains control, so staging is closed here too.
    s5_close_staging
    case $? in
    1) _scldownload=1 ;;
    2) _sclstatus=1 ;;
    3) _scldownload=1; _sclstatus=1 ;;
    esac
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
            S5_UNIT_ENABLED=0
        fi
        if [ "$S5_CREATED_UNIT" = 1 ]; then
            rm -f "$S5_SERVICE_ARTIFACT" 2>/dev/null || true
            # After the removal, and whether or not enable was reached: a reload
            # before it left the manager holding the deleted unit.
            s5_svc reload || true
        fi
        # supervise-daemon's pidfile and child_pid belong to whatever service is
        # running. Removing them for an installation this run never touched left a
        # healthy Alpine proxy unstoppable and unobservable: status reports no
        # listener, uninstall cannot signal the supervisor, and the next update
        # sees its own port as foreign. Declining the update prompt reached this.
        if [ "$S5_INIT" = openrc ] && [ "$_sclruntime" = 1 ]; then
            rm -f "$S5_PIDFILE" "$S5_OPENRC_OPTION_DIR/child_pid" 2>/dev/null || true
        fi
        if [ "$S5_CREATED_STATE" = 1 ]; then rm -f "$S5_STATE" 2>/dev/null || true; fi
        if [ "$S5_CREATED_CFG" = 1 ]; then rm -f "$S5_CFG" 2>/dev/null || true; fi
        if [ "$S5_CREATED_BIN" = 1 ]; then rm -f "$S5_BIN" 2>/dev/null || true; fi
        if [ "$S5_CREATED_USER" = 1 ] || [ "$S5_CREATED_GROUP" = 1 ]; then
            s5_account_remove || true
        fi
        # An interrupted atomic write leaves a private temporary behind; the
        # rmdir below, and uninstall later, both refuse a non-empty directory.
        s5_cleanup_own_temps "$S5_SYSCONFDIR" || true
        s5_cleanup_own_temps "$S5_STATEDIR" || true
        # Recovery copies remain until both files have been restored, including
        # when a signal interrupts publication or only one backup is readable.
        if [ "$S5_CONFIG_REPLACED" = 1 ] || [ "$S5_BINARY_REPLACED" = 1 ] ||
            [ "$S5_SERVICE_TOUCHED" = 1 ]; then
            s5_update_rollback "$S5_TXNDIR/old.config.json" "$S5_TXNDIR/old.state" || true
        elif [ "$S5_CREATED_TRANSACTION" = 1 ]; then
            # Before binary replacement/service stop/publication the live files
            # were untouched, so deleting only this invocation's complete or
            # partial backup is the non-destructive cleanup.
            s5_cleanup_transaction || true
        fi
        if [ "$S5_CREATED_PREFIX" = 1 ]; then
            s5_cleanup_own_temps "$S5_PREFIX" binaries || true
        else
            s5_cleanup_own_temps "$S5_PREFIX" || true
            for _sclresidue in "$S5_PREFIX"/.xray.*; do
                [ -e "$_sclresidue" ] || [ -L "$_sclresidue" ] || continue
                s5_msg_warn cleanup.residue "$_sclresidue" || true
            done
        fi
        if [ "$S5_CREATED_CONFDIR" = 1 ]; then rmdir "$S5_SYSCONFDIR" 2>/dev/null || true; fi
        if [ "$S5_CREATED_STATEDIR" = 1 ]; then rmdir "$S5_STATEDIR" 2>/dev/null || true; fi
        if [ "$S5_CREATED_PREFIX" = 1 ]; then
            rmdir "$S5_PREFIX" 2>/dev/null || true
            S5_PREFIX_PRIVATE=0
        fi
    fi
    # The verifier's credential temp is recorded in S5_VERIFY_TEMP. Release it
    # too: s5_on_signal_lock is not the only handler that reaches a live temp, and a
    # successful run has already cleared it, so this is a no-op there.
    s5_release_verify_temp
    if [ "$S5_LOCK_HELD" = 1 ]; then
        s5_lock_release || true
    fi
    S5_IN_CLEANUP=0
    [ "$_sclstatus" -ne 0 ] && return "$_sclstatus"
    return "$_scldownload"
}

s5_on_signal() {
    trap '' HUP INT TERM
    s5_cleanup
    trap - EXIT
    exit "$1"
}

# The signal traps of a command that can change the installation. Signal
# handling only: the command's own return paths run s5_cleanup explicitly.
s5_trap_rollback() {
    trap 's5_on_signal 129' HUP
    trap 's5_on_signal 130' INT
    trap 's5_on_signal 143' TERM
}

# The read-only and single-purpose commands hold the lock and have nothing of
# their own to roll back, so they unwind with the lock and the verifier's
# credential temporary only; without this an interrupt left both behind.
# Transaction recovery they trigger is the exception and runs under
# s5_trap_rollback (see s5_open_managed_state).
s5_on_signal_lock() {
    trap '' HUP INT TERM
    s5_release_verify_temp
    s5_lock_release || true
    trap - EXIT
    exit "$1"
}

s5_release_verify_temp() {
    if [ -n "$S5_VERIFY_TEMP" ]; then
        rm -f "$S5_VERIFY_TEMP" "$S5_VERIFY_TEMP.reason" 2>/dev/null || true
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
    _srp_list=''
    [ -x /usr/bin/curl ] || _srp_list="$_srp_list curl ca-certificates"
    # file(1) is invoked by absolute path, so provisioning asks about that path
    # too: a copy elsewhere on PATH would skip the package the precheck needs.
    [ -x /usr/bin/file ] || _srp_list="$_srp_list file"
    command -v python3 >/dev/null 2>&1 || _srp_list="$_srp_list python3"
    command -v ss >/dev/null 2>&1 || _srp_list="$_srp_list iproute2"
    printf '%s' "${_srp_list# }"
}

s5_install_runtime_dependencies() {
    [ "${S5_TEST_MODE:-0}" = 1 ] && return 0
    _sird=$(s5_runtime_packages "${1:-}") || return 1
    [ -n "$_sird" ] || return 0
    command -v apk >/dev/null 2>&1 || return 1
    # Package names are fixed, and only runtime tools are requested.
    # No compiler, VCS, build system, or source headers are installed.
    # One package per word.
    s5_split_words "$S5_WORD_IFS" "$_sird" apk add --no-cache >/dev/null 2>&1
    _sird_status=$?
    [ "$_sird_status" -eq 0 ] || {
        s5_msg_err packages.failed apk
        return 1
    }
    return 0
}


# s5_precheck <mode>: the whole check a command runs before it takes the lock.
# It only inspects the host; install provisions packages between the two stages
# itself (s5_cmd_install), so no other caller can inherit that side effect.
s5_precheck() {
    s5_precheck_host "${1:-install}" || return 1
    s5_precheck_tools "${1:-install}"
}

# s5_precheck_host <mode>: root, a supported architecture and platform, and for
# install and update a booted init, so a host that cannot be served is refused
# before anything is provisioned.
s5_precheck_host() {
    _sph_mode=$1
    s5_is_root || { s5_msg_err root.required; return 1; }
    S5_ARCHNAME=$(s5_map_arch "$(uname -m)") || {
        s5_msg_err detect.unsupported unknown unknown unknown
        return 1
    }
    s5_detect_platform || {
        s5_msg_err detect.unsupported "$S5_OS_ID" "$S5_OS_VERSION_ID" "$S5_ARCHNAME"
        return 1
    }
    case "$S5_INIT:$_sph_mode" in
    systemd:install | systemd:update)
        [ -d "$S5_ROOTDIR/run/systemd/system" ] || { s5_msg_err detect.init; return 1; }
        ;;
    openrc:install | openrc:update)
        [ -f "$S5_ROOTDIR/run/openrc/softlevel" ] || { s5_msg_err detect.init; return 1; }
        ;;
    esac
    return 0
}

# s5_precheck_tools <mode>: the commands the mode runs, the pinned tools by
# absolute path, and the asset for this architecture.
s5_precheck_tools() {
    _spt_mode=$1
    # Only commands the script runs; tail and rc-status were required and never called.
    s5_require_commands awk sed grep tr head id getent mkdir rmdir rm mv cp cat printf \
        stat mktemp ln sleep wc chmod || return 1
    # Every mode reads a recorded digest, so the pinned digest tool is required
    # here rather than per mode, and by absolute path: a same-named PATH wrapper
    # would otherwise decide what counts as the pinned artifact.
    [ -x /usr/bin/sha256sum ] || { s5_msg_err detect.commands sha256sum; return 1; }
    case "$S5_INIT:$_spt_mode" in
    openrc:install | openrc:update)
        s5_require_commands addgroup adduser delgroup deluser rc-service rc-update logger \
            od chown python3 ss || return 1
        ;;
    systemd:install | systemd:update)
        s5_require_commands groupadd groupdel useradd userdel systemctl od chown python3 || return 1
        command -v ss >/dev/null 2>&1 || { s5_msg_err detect.commands ss; return 1; }
        ;;
    openrc:status)
        s5_require_commands rc-service ss || return 1
        ;;
    systemd:status)
        s5_require_commands systemctl ss || return 1
        ;;
    # restart keeps python3: it re-runs the data-plane verification, which status
    # does not. status only reads service and listener state.
    openrc:restart)
        s5_require_commands python3 rc-service ss || return 1
        ;;
    systemd:restart)
        s5_require_commands python3 systemctl ss || return 1
        ;;
    openrc:uninstall)
        s5_require_commands delgroup deluser rc-service rc-update || return 1
        ;;
    systemd:uninstall)
        s5_require_commands groupdel userdel systemctl || return 1
        ;;
    *) s5_msg_err detect.init; return 1 ;;
    esac
    # The packaged absolute paths prevent PATH wrappers from altering transport
    # or binary classification.
    case "$_spt_mode" in
    install | update)
        [ -x /usr/bin/curl ] || {
            s5_msg_err detect.commands curl
            return 1
        }
        [ -x /usr/bin/file ] || {
            s5_msg_err detect.commands file
            return 1
        }
        ;;
    esac
    s5_asset_select || return 1
    return 0
}

s5_confirm() {
    # Confirmation and its cancellation report. The lock belongs to the calling
    # command, so releasing it is delegated through the optional $2 hook: install
    # and update pass nothing and unwind through their own error paths, while
    # uninstall passes s5_lock_release to keep the documented order of releasing
    # the lock before the cancellation is reported.
    _sconf_answer=''
    if ! { s5_msg_ask "$1.confirm" && IFS= read -r _sconf_answer; }; then
        [ "$#" -lt 2 ] || "$2" || true
        return 1
    fi
    case "$1:$_sconf_answer" in
    install: | install:y | install:Y | install:yes | install:YES | install:Yes | \
    update:y | update:Y | uninstall:y | uninstall:Y) return 0 ;;
    esac
    [ "$#" -lt 2 ] || "$2" || true
    s5_msg_print install.cancelled
    return 1
}

s5_confirm_install() { s5_confirm install; }
s5_confirm_update() { s5_confirm update; }

# s5_record_read assigns the record's fields by name, which ShellCheck cannot see.
# shellcheck disable=SC2154
s5_transaction_verify_rollback() {
    s5_transaction_contract || return 1
    _stvr_fields=$(s5_state_parse_file "$S5_TXNDIR/old.state")
    _stvr_parse=$?
    [ "$_stvr_parse" -eq 0 ] || return 1
    s5_record_read "$(s5_state_table 2 _stvr_)" <<ROLLBACK_FIELDS || return 1
$_stvr_fields
ROLLBACK_FIELDS
    _stvr_fields=''
    [ "$_stvr_engine:$_stvr_protocol:$_stvr_auth:$_stvr_udp:$_stvr_status" = \
        xray:mixed:password:false:complete ] || return 1
    s5_valid_release "$_stvr_release" && s5_valid_commit "$_stvr_commit" || return 1
    s5_asset_identity _stvr_ || return 1
    s5_valid_sha256 "$_stvr_config_sha256" && s5_valid_sha256 "$_stvr_unit_sha256" || return 1
    s5_valid_port "$_stvr_port" && s5_valid_stored_username "$_stvr_username" &&
        s5_ipv4_is_canonical "$_stvr_listen" || return 1
    [ "${_stvr_family:-debian}:$_stvr_init" = "$S5_OS_FAMILY:$S5_INIT" ] || return 1
    s5_valid_decimal "$_stvr_account_uid" && s5_valid_decimal "$_stvr_account_gid" || return 1
    s5_account_identity "$_stvr_account_uid" "$_stvr_account_gid" || return 1
    s5_unit_mode || return 1
    _stvr_unit=$S5_SERVICE_ARTIFACT
    if [ -f "$S5_TXNDIR/old.unit" ] && [ ! -L "$S5_TXNDIR/old.unit" ]; then
        s5_path_contract "$S5_TXNDIR/old.unit" file root:root 600 || return 1
        _stvr_unit=$S5_TXNDIR/old.unit
    else
        s5_path_contract "$S5_SERVICE_ARTIFACT" "$S5_UNIT_TYPE" root:root "$S5_UNIT_MODE" || return 1
    fi
    s5_path_contract "$S5_CFG" file "root:$S5_SERVICE_GROUP" 640 || return 1
    s5_path_contract "$S5_STATE" file root:root 600 || return 1
    s5_path_contract "$S5_BIN" exec root:root 755 || return 1
    [ "$(s5_sha256 "$_stvr_unit" 2>/dev/null)" = "$_stvr_unit_sha256" ] || return 1
    [ "$(s5_sha256 "$S5_TXNDIR/old.config.json" 2>/dev/null)" = "$_stvr_config_sha256" ] || return 1
    _stvr_binary=$S5_BIN
    [ ! -e "$S5_TXNDIR/old.xray" ] || _stvr_binary=$S5_TXNDIR/old.xray
    [ "$(s5_bytecount "$_stvr_binary" 2>/dev/null)" = "$_stvr_binary_size" ] || return 1
    [ "$(s5_sha256 "$_stvr_binary" 2>/dev/null)" = "$_stvr_binary_sha256" ] || return 1
    return 0
}

s5_restore_transaction() {
    _srtcfg=$1
    _srtstate=$2
    if [ -f "$S5_TXNDIR/old.unit" ] && [ ! -L "$S5_TXNDIR/old.unit" ]; then
        if ! s5_atomic_write "$S5_SERVICE_ARTIFACT" root:root 0755 \
            <"$S5_TXNDIR/old.unit"; then return 1; fi
        s5_svc reload || return 1
    fi
    s5_atomic_write "$S5_CFG" "root:$S5_SERVICE_GROUP" 0640 <"$_srtcfg" || return 1
    s5_atomic_write "$S5_STATE" root:root 0600 <"$_srtstate" || return 1
    return 0
}

# Explicit failure and signal cleanup share the same recovery policy. A failed
# restore leaves the publication flag set so later cleanup cannot discard backups.
s5_update_rollback() {
    s5_transaction_verify_rollback || {
        s5_msg_err transaction.restore "$S5_TXNDIR"
        return 1
    }
    if ! s5_restore_transaction "$1" "$2"; then
        s5_msg_err transaction.restore "$S5_TXNDIR"
        return 1
    fi
    if [ -f "$S5_TXNDIR/old.xray" ] && [ ! -L "$S5_TXNDIR/old.xray" ]; then
        _sur_tmp=$(mktemp "$S5_PREFIX/.xray.XXXXXX") || { s5_msg_err transaction.restore "$S5_TXNDIR"; return 1; }
        # Registered like a download candidate, so an interrupted restore is
        # removed by cleanup instead of left as an untracked 35 MB file.
        S5_BINARY_TEMP=$_sur_tmp
        if ! chmod 0755 "$_sur_tmp" || ! cat "$S5_TXNDIR/old.xray" >"$_sur_tmp" ||
            ! mv -f "$_sur_tmp" "$S5_BIN"; then
            rm -f "$_sur_tmp"
            S5_BINARY_TEMP=''
            s5_msg_err transaction.restore "$S5_TXNDIR"
            return 1
        fi
        S5_BINARY_TEMP=''
    fi
    S5_SERVICE_STARTED=0
    if [ "$S5_SERVICE_TOUCHED" = 1 ]; then
        s5_svc restart || { s5_msg_err service.start; return 1; }
    fi
    s5_atomic_write "$S5_TXN_ROLLED_BACK" root:root 0600 <<ROLLED_BACK || {
rolled-back
ROLLED_BACK
        s5_msg_err transaction.restore "$S5_TXNDIR"
        return 1
    }
    S5_CONFIG_REPLACED=0
    S5_BINARY_REPLACED=0
    S5_SERVICE_TOUCHED=0
    s5_cleanup_transaction
}

# s5_update_abort [key [args]]: the failure tail after publication began. Name
# the failure (a step that already reported its own reason passes no key), roll
# back, and say whether the previous installation came back, so an update never
# fails without a word. A failed rollback reports transaction.restore itself.
s5_update_abort() {
    [ "$#" -eq 0 ] || s5_msg_err "$@"
    s5_update_rollback "$S5_TXNDIR/old.config.json" "$S5_TXNDIR/old.state" || return 1
    s5_msg_err transaction.rolledback
    return 1
}

# Copies the recovery pair, and the OpenRC service script, before anything live
# changes, so every failure in here leaves the installation as it was.
s5_update_backup() {
    mkdir -m 0700 "$S5_TXNDIR" || return 1
    S5_CREATED_TRANSACTION=1
    cp "$S5_CFG" "$S5_TXNDIR/old.config.json" || return 1
    cp "$S5_STATE" "$S5_TXNDIR/old.state" || return 1
    chmod 0600 "$S5_TXNDIR/old.config.json" "$S5_TXNDIR/old.state" || return 1
    if [ "$S5_INIT" = openrc ]; then
        cp "$S5_SERVICE_ARTIFACT" "$S5_TXNDIR/old.unit" || return 1
        if [ "${S5_SKIP_OWNERSHIP:-0}" != 1 ]; then chown root:root "$S5_TXNDIR/old.unit" || return 1; fi
        chmod 0600 "$S5_TXNDIR/old.unit" || return 1
    fi
    return 0
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
    # Each cleanup flag is armed before its resource appears. Armed after, a
    # handled signal between a step's effect and its return left residue that a
    # retry refuses as a foreign namespace and uninstall has no state to remove.
    # Arming early is safe only for a name proven free: the directories by an
    # exclusive mkdir, which disarms when it created nothing, and the files by the
    # fresh directories that hold them or a re-check of the shared unit directory.
    S5_CREATED_CONFDIR=1
    s5_mkdir_new "$S5_SYSCONFDIR"
    case $? in 0) ;; 2) S5_CREATED_CONFDIR=0; return 1 ;; *) return 1 ;; esac
    S5_CREATED_STATEDIR=1
    s5_mkdir_new "$S5_STATEDIR"
    case $? in 0) ;; 2) S5_CREATED_STATEDIR=0; return 1 ;; *) return 1 ;; esac
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
    S5_CREATED_CFG=1
    mv -f "$_sinc" "$S5_CFG" || return 1
    # The prompts and the download ran since the namespace check, and the unit
    # directory is shared, so the claim waits until the name is free right now.
    if [ -e "$S5_SERVICE_ARTIFACT" ] || [ -L "$S5_SERVICE_ARTIFACT" ]; then
        s5_msg_err state.invalid "$S5_PROJECT"
        return 1
    fi
    S5_CREATED_UNIT=1
    s5_write_unit || { s5_msg_err service.unit "$S5_SERVICE_ARTIFACT"; return 1; }
    s5_record_digest service-artifact "$S5_SERVICE_ARTIFACT" || return 1
    S5_UNIT_SHA256=$S5_RECORDED_DIGEST
    s5_svc reload || { s5_msg_err service.reload; return 1; }
    # A partial or interrupted enable can register this run's own unit at boot;
    # disabling a unit that never got that far is harmless.
    S5_UNIT_ENABLED=1
    s5_svc enable || { s5_msg_err service.enable; return 1; }
    # A failed start or a signal can still leave a managed process running.
    S5_SERVICE_STARTED=1
    s5_svc start || { s5_msg_err service.start; return 1; }
    s5_service_state; _sina=$?
    case "$_sina" in 0) ;; 1 | 4) s5_msg_err service.start; return 1 ;; *) s5_msg_err service.inactive; return 1 ;; esac
    s5_wait_listening "$S5_PORT"
    case $? in
    0) ;;
    1) s5_msg_err service.listen "$S5_PORT"; return 1 ;;
    *) s5_msg_err service.unverified "$S5_PORT"; return 1 ;;
    esac
    s5_verify_dataplane || return 1
    s5_record_digest config "$S5_CFG" || return 1
    S5_CONFIG_SHA256=$S5_RECORDED_DIGEST
    S5_CREATED_STATE=1
    s5_state_write || { s5_msg_err state.write "$S5_STATE"; return 1; }
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
    4) s5_msg_err state.unsupported "$S5_STATE" ;;
    5) s5_msg_err transaction.pending "$S5_TXNDIR" ;;
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
    s5_open_managed_state update
    s5_report_state_load $? || return 1
    s5_config_extract || { s5_msg_err config.unreadable "$S5_CFG"; return 1; }
    s5_confirm_update || return 1
    s5_prompt_port || return 1
    s5_prompt_username || return 1
    s5_prompt_password || return 1
    s5_update_backup || { s5_msg_err transaction.prepare "$S5_TXNDIR"; return 1; }
    _sioldcfg=$S5_TXNDIR/old.config.json
    _sioldstate=$S5_TXNDIR/old.state
    _sioldbin=$S5_TXNDIR/old.xray
    if [ "$S5_UPDATE_NEEDS_BINARY" = 1 ]; then
        # The rollback copy is as large as the engine itself, and it is written
        # before anything is replaced, so a filesystem without room for it is named
        # here rather than while a live installation is half updated.
        s5_require_update_space "$S5_INSTALLED_BINARY_SIZE" || return 1
        if ! cp "$S5_BIN" "$_sioldbin" ||
            { [ "${S5_SKIP_OWNERSHIP:-0}" != 1 ] && ! chown root:root "$_sioldbin"; } ||
            ! chmod 0600 "$_sioldbin"; then
            s5_msg_err transaction.prepare "$S5_TXNDIR"
            return 1
        fi
        S5_BINARY_REPLACED=1
        s5_download_engine || return 1
        # The binary path existed before this operation; cleanup must restore it,
        # never classify it as a fresh-install artifact to delete.
        S5_CREATED_BIN=0
    else
        s5_binary_ready || { s5_msg_err asset.invalid binary; return 1; }
    fi
    _siinc=$(s5_write_config_candidate) || return 1
    if ! s5_atomic_write "$S5_TXN_STOPPING" root:root 0600 <<STOPPING
stopping
STOPPING
    then
        s5_msg_err transaction.prepare "$S5_TXNDIR"
        rm -f "$_siinc"
        return 1
    fi
    S5_SERVICE_TOUCHED=1
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
        # One rollback point: restoring and restarting here, and then again
        # in the command's failure cleanup, restarted the service twice.
        S5_CONFIG_REPLACED=0
        rm -f "$_siinc"
        s5_update_abort transaction.publish "$S5_CFG"
        return 1
    fi
    if [ "$S5_INIT" = openrc ]; then
        s5_atomic_write "$S5_TXN_UNIT_REPLACING" root:root 0600 <<UNIT_REPLACING || {
unit-replacing
UNIT_REPLACING
            s5_update_abort transaction.prepare "$S5_TXNDIR"
            return 1
        }
        s5_write_unit || { s5_update_abort service.unit "$S5_SERVICE_ARTIFACT"; return 1; }
        s5_record_digest service-artifact "$S5_SERVICE_ARTIFACT" || { s5_update_abort; return 1; }
        S5_UNIT_SHA256=$S5_RECORDED_DIGEST
        s5_svc reload || { s5_update_abort service.reload; return 1; }
    fi
    s5_svc start || { s5_update_abort service.start; return 1; }
    S5_SERVICE_STARTED=1
    # The same three-way diagnosis as a fresh install: an unobservable listener
    # is not reported as a proven-absent one.
    s5_wait_listening "$S5_PORT"
    case $? in
    0) ;;
    1) s5_update_abort service.listen "$S5_PORT"; return 1 ;;
    *) s5_update_abort service.unverified "$S5_PORT"; return 1 ;;
    esac
    s5_verify_dataplane || { s5_update_abort; return 1; }
    s5_record_digest config "$S5_CFG" || { s5_update_abort; return 1; }
    S5_CONFIG_SHA256=$S5_RECORDED_DIGEST
    s5_state_write || { s5_update_abort state.write "$S5_STATE"; return 1; }
    # The marker switches recovery from rollback-required to delete-only. Write it
    # before deleting either half of the old recovery pair.
    s5_atomic_write "$S5_TXN_COMMITTED" root:root 0600 <<COMMITTED || return 1
committed
COMMITTED
    S5_CONFIG_REPLACED=0
    S5_BINARY_REPLACED=0
    S5_SERVICE_TOUCHED=0
    S5_INSTALL_COMPLETE=1
    if ! s5_cleanup_transaction; then
        s5_msg_err transaction.cleanup "$S5_TXNDIR"
        return 1
    fi
    return 0
}

s5_warn_openrc_logging() {
    [ "$S5_INIT" = openrc ] || return 0
    [ -e "$S5_ROOTDIR/dev/log" ] || [ -L "$S5_ROOTDIR/dev/log" ] ||
        s5_msg_warn openrc.logging.unavailable || true
}

s5_cmd_install() {
    s5_precheck_host install || return 1
    s5_install_runtime_dependencies install || return 1
    s5_precheck_tools install || return 1
    s5_lock_acquire || return 1
    # Signals only: every return below cleans up explicitly, as the lock-only
    # commands do, so an EXIT trap would add a second path to the same cleanup
    # and displace the EXIT handler of whatever sourced the script.
    s5_trap_rollback
    s5_msg_print install.start >&2
    if [ -f "$S5_STATE" ]; then
        s5_install_update
        _sci_status=$?
        _sci_update=1
    else
        if [ -e "$S5_UNINSTALL_STATE" ] || [ -L "$S5_UNINSTALL_STATE" ] ||
            [ -e "$S5_UNINSTALL_FINAL" ] || [ -L "$S5_UNINSTALL_FINAL" ] ||
            ! s5_namespace_absent; then
            s5_msg_err state.invalid "$S5_STATE"
            _sci_status=1
        elif s5_confirm_install; then
            s5_install_new
            _sci_status=$?
        else
            _sci_status=1
        fi
        _sci_update=0
    fi
    if [ "$_sci_status" -ne 0 ]; then
        s5_cleanup
        trap - HUP INT TERM
        return 1
    fi
    s5_lock_release
    _sci_status=$?
    trap - HUP INT TERM
    [ "$_sci_status" -eq 0 ] || return 1
    s5_warn_openrc_logging
    if [ "$_sci_update" = 1 ]; then s5_msg_print install.updated; else s5_msg_print install.done; fi
    if [ -t 1 ]; then
        s5_render_card || s5_msg_warn install.card.hidden
    else
        s5_msg_print install.card.hidden
    fi
    return 0
}

# s5_enter_locked <mode>: the opening every lock-only command shares --
# prechecked, locked, then trapped so an interrupt releases the lock. A failure
# here leaves no lock held, so the caller just returns.
s5_enter_locked() {
    s5_precheck "$1" || return 1
    s5_lock_acquire || return 1
    s5_trap_lock_only
}

# s5_accept_state <load-status>: report a failed state load, or read the
# configuration the caller works from. Either failure releases the lock through
# s5_fail_locked, so each caller only handles its own work.
s5_accept_state() {
    s5_report_state_load "$1" || { s5_fail_locked; return 1; }
    s5_config_extract || { s5_fail_locked config.unreadable "$S5_CFG"; return 1; }
}

# The opening of every locked read command: entered, then the validated state
# and configuration. Uninstall shares both halves but decides between them
# whether a recovery record or a missing state comes first.
s5_open_locked() {
    s5_enter_locked "$1" || return 1
    s5_open_managed_state
    s5_accept_state $?
}

# The one place that maps the two state probes onto reported values, so status
# and show cannot drift apart. Only a manager that positively reports the proxy
# exited -- OpenRC's crashed child or a failed systemd unit -- makes a read-only
# command fail; an unobservable listener never raises a false alarm.
s5_probe_states() {
    s5_service_state
    case $? in
    0) S5_SERVICE_STATE_KEY=status.state.running; S5_SERVICE_RC=0 ;;
    1) S5_SERVICE_STATE_KEY=status.state.stopped; S5_SERVICE_RC=0 ;;
    3) S5_SERVICE_STATE_KEY=status.state.crashed; S5_SERVICE_RC=1 ;;
    4) S5_SERVICE_STATE_KEY=status.state.failed; S5_SERVICE_RC=1 ;;
    5) S5_SERVICE_STATE_KEY=status.state.unsupervised; S5_SERVICE_RC=1 ;;
    *) S5_SERVICE_STATE_KEY=status.state.unverified; S5_SERVICE_RC=0 ;;
    esac
    s5_listener_state
    S5_LISTENER_STATE=$?
    return 0
}

s5_report_listener() {
    case "$S5_LISTENER_STATE" in
    0) s5_msg_print service.ready "$S5_PORT" ;;
    1) s5_msg_print service.listen "$S5_PORT" ;;
    *) s5_msg_print service.unverified "$S5_PORT" ;;
    esac
}

s5_cmd_status() {
    s5_open_locked status || return 1
    s5_probe_states
    s5_msg_print status.heading
    s5_msg_print status.line "$(s5_msg "$S5_SERVICE_STATE_KEY")" "$S5_PORT" "$S5_USERNAME"
    s5_msg_print status.version "$S5_INSTALLED_RELEASE"
    s5_report_listener
    s5_lock_release || return 1
    return "$S5_SERVICE_RC"
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
    _sripv4_file=$(mktemp "$(s5_tmp_base)/.s5ip.XXXXXX") || return 1
    s5_fetch_public_ipv4 "$_sripv4_file" && s5_parse_public_ipv4 "$_sripv4_file"
    _sripv4_status=$?
    # The one exit: the body file goes whatever the outcome, and a refused body
    # leaves no candidate behind.
    rm -f "$_sripv4_file"
    _sripv4_file=''
    [ "$_sripv4_status" -eq 0 ] || S5_PUBLIC_IPV4_CANDIDATE=''
    return "$_sripv4_status"
}

# s5_fetch_public_ipv4 <file>: write the response body to the caller's file.
s5_fetch_public_ipv4() {
    if [ "${S5_TEST_MODE:-0}" = 1 ] && [ -n "${S5_TEST_ADDR_PATH:-}" ]; then
        cp "$S5_TEST_ADDR_PATH" "$1"
        return $?
    fi
    [ -x /usr/bin/curl ] || return 1
    s5_curl_command -q -4 --noproxy '*' --proto '=https' --fail --silent \
        --connect-timeout 3 --max-time 5 --max-filesize 17 \
        --output "$1" "$S5_ADDR_ENDPOINT" </dev/null 2>/dev/null
}

# s5_parse_public_ipv4 <file>: accept a body of one line and one optional
# terminator into S5_PUBLIC_IPV4_CANDIDATE.
s5_parse_public_ipv4() {
    _sppi_size=$(s5_bytecount "$1" 2>/dev/null)
    case "$_sppi_size" in '' | *[!0-9]*) _sppi_size=18 ;; esac
    # The longest address is 15 bytes and one terminator is allowed two, so a
    # larger body cannot be a single address. Checked before the read so an
    # endpoint that ignores --max-filesize cannot stream an unbounded line.
    [ "$_sppi_size" -le 17 ] || return 1
    IFS= read -r S5_PUBLIC_IPV4_CANDIDATE <"$1" 2>/dev/null || true
    # The raw line still carries the CR of a CRLF terminator, so its length is
    # the exact byte count of everything before the LF.
    _sppi_length=${#S5_PUBLIC_IPV4_CANDIDATE}
    # read leaves that CR on the line, and a command substitution strips trailing
    # newlines but not a CR.
    _sppi_cr=$(printf 'x\r')
    _sppi_cr=${_sppi_cr#x}
    S5_PUBLIC_IPV4_CANDIDATE=${S5_PUBLIC_IPV4_CANDIDATE%"$_sppi_cr"}
    # The body has to be one line and one optional terminator. Comparing the
    # file's byte count against the raw line plus that terminator rejects a
    # second line, a double terminator and unterminated trailing bytes without
    # enumerating them, which a command substitution cannot do because it strips
    # every trailing newline.
    [ "$_sppi_size" -le "$((_sppi_length + 1))" ] || return 1
    [ -n "$S5_PUBLIC_IPV4_CANDIDATE" ]
}

# Resolves once per card, so the SOCKS5 and HTTP URIs always agree. Validation
# lives here rather than in the caller: S5_SERVER_IPV4 and the response body both
# reach the card through this, so neither can turn into a way past the check.
s5_resolve_advertised_address() {
    S5_ADVERTISED_ADDR=''
    S5_ADVERTISED_KIND=''
    S5_ADVERTISED_LOCAL=''
    if [ -n "${S5_SERVER_IPV4:-}" ] && s5_ipv4_is_canonical "$S5_SERVER_IPV4"; then
        # Deliberately not locality-checked. An explicit answer is the operator
        # describing a topology this host cannot see, which is the whole reason
        # the override exists.
        S5_ADVERTISED_ADDR=$S5_SERVER_IPV4
        S5_ADVERTISED_KIND=configured
        return 0
    fi
    if s5_read_public_ipv4 && s5_ipv4_is_public "$S5_PUBLIC_IPV4_CANDIDATE"; then
        S5_ADVERTISED_ADDR=$S5_PUBLIC_IPV4_CANDIDATE
        S5_PUBLIC_IPV4_CANDIDATE=''
        # The endpoint reports the address the request left from, which is this
        # server's own only when nothing translates it. Behind NAT the card
        # advertised an address the host does not hold and no client could
        # reach, and every verification still passed because they dial loopback.
        # Only a definite "not mine" annotates the card: an unanswerable probe
        # leaves it exactly as it was. Classification and the displayed local
        # hint consume the same immutable snapshot; enumerating twice let an
        # interface change make one card contradict itself.
        _srca_local=$(s5_local_ipv4) || _srca_local=''
        if [ -n "$_srca_local" ]; then
            s5_ipv4_is_local "$S5_ADVERTISED_ADDR" "$_srca_local"
            case $? in
            1)
                S5_ADVERTISED_KIND=nat
                S5_ADVERTISED_LOCAL=$(s5_local_ipv4_hint "$_srca_local") || S5_ADVERTISED_LOCAL=''
                ;;
            *) S5_ADVERTISED_KIND=external ;;
            esac
        else
            S5_ADVERTISED_KIND=external
        fi
        _srca_local=''
        return 0
    fi
    S5_PUBLIC_IPV4_CANDIDATE=''
    S5_ADVERTISED_ADDR=SERVER_IPV4
    S5_ADVERTISED_KIND=placeholder
    return 0
}

# Separate from S5_PORT: the port a client dials is not always the port the
# daemon binds, and the card is about the former. An invalid override falls back
# to the listening port, matching how an invalid S5_SERVER_IPV4 falls back to
# the lookup.
s5_resolve_advertised_port() {
    S5_ADVERTISED_PORT=$S5_PORT
    [ -n "${S5_SERVER_PORT:-}" ] || return 0
    s5_valid_advertised_port "$S5_SERVER_PORT" || return 0
    S5_ADVERTISED_PORT=$S5_SERVER_PORT
    return 0
}

# Callers must verify root privileges and a terminal stdout before showing credentials.
s5_render_card() {
    s5_resolve_advertised_address
    s5_resolve_advertised_port
    _srdc_socks="socks5://$S5_USERNAME:$S5_PASSWORD@$S5_ADVERTISED_ADDR:$S5_ADVERTISED_PORT"
    _srdc_http="http://$S5_USERNAME:$S5_PASSWORD@$S5_ADVERTISED_ADDR:$S5_ADVERTISED_PORT"
    s5_msg_print show.heading || return 1
    case "$S5_ADVERTISED_KIND" in
    placeholder) s5_msg_print show.placeholder "$S5_ADVERTISED_ADDR" || return 1 ;;
    nat)
        if [ -n "$S5_ADVERTISED_LOCAL" ]; then
            s5_msg_print show.nat "$S5_ADVERTISED_ADDR" "$S5_ADVERTISED_LOCAL" "$S5_PORT" || return 1
        else
            s5_msg_print show.nat.unnamed "$S5_ADVERTISED_ADDR" "$S5_PORT" || return 1
        fi
        ;;
    esac
    if [ "$S5_ADVERTISED_PORT" != "$S5_PORT" ]; then
        s5_msg_print show.port.mapped "$S5_ADVERTISED_PORT" "$S5_PORT" || return 1
    fi
    s5_msg_print show.socks "$_srdc_socks" || return 1
    s5_msg_print show.http "$_srdc_http" || return 1
    s5_msg_print show.warning || return 1
    _srdc_socks=''
    _srdc_http=''
    return 0
}

s5_cmd_show() {
    # The card is recorded state and stays useful while the daemon is down, so
    # the service state is reported rather than used to withhold credentials. It stays on
    # stdout because only stdout is proven to be a terminal here; sending it to
    # redirected stderr would recreate the pristine-card defect. The return code
    # mirrors status: only a positively reported exit (crashed or failed) fails.
    s5_is_root || { s5_msg_err root.required; return 1; }
    if [ ! -t 1 ]; then s5_msg_err show.terminal; return 1; fi
    s5_open_locked status || return 1
    s5_probe_states
    s5_msg_print show.service "$(s5_msg "$S5_SERVICE_STATE_KEY")" || { s5_fail_locked; return 1; }
    s5_report_listener || { s5_fail_locked; return 1; }
    s5_render_card || { s5_fail_locked; return 1; }
    s5_lock_release || return 1
    return "$S5_SERVICE_RC"
}

# A supervised child still alive after its supervisor died: OpenRC's crashed
# state does not say whether one is, so child_pid is asked directly.
s5_openrc_child_alive() {
    _soca_pid=$(cat "$S5_OPENRC_OPTION_DIR/child_pid" 2>/dev/null) || return 1
    case "$_soca_pid" in '' | *[!0-9]* | 0) return 1 ;; esac
    kill -0 "$_soca_pid" 2>/dev/null
}

# OpenRC reports crashed (3 here) or unsupervised (5) when the supervisor is
# gone while the service is still marked started. Its restart then has no
# supervisor to stop and fails, so the service stays that way until the record
# is reset. That reset (zap) is sound only when no supervised child survives: a
# live child could still hold the port, so it stays fail closed. Every other
# state restarts normally.
s5_restart_service() {
    if [ "$S5_INIT" = openrc ]; then
        s5_service_state
        _srsvc_state=$?
        if [ "$_srsvc_state" -eq 3 ] || [ "$_srsvc_state" -eq 5 ]; then
            s5_openrc_child_alive && return 1
            rc-service "$S5_PROJECT" zap >/dev/null 2>&1 || return 1
            s5_svc start
            return $?
        fi
    fi
    s5_svc restart
}

s5_cmd_restart() {
    s5_open_locked restart || return 1
    s5_config_test "$S5_CFG" || { s5_fail_locked config.invalid.installed; return 1; }
    s5_restart_service || { s5_fail_locked service.start; return 1; }
    s5_wait_listening "$S5_PORT"
    _scr_status=$?
    if [ "$_scr_status" -eq 0 ]; then
        # 3 rather than 2: s5_verify_dataplane has already named its own reason,
        # and the case below must not restate it as the vaguer service.unverified.
        s5_verify_dataplane || _scr_status=3
    fi
    s5_lock_release || return 1
    case "$_scr_status" in
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
    # Refused before the emptiness glob, which would otherwise walk the target.
    [ -L "$_srod" ] && { s5_msg_warn uninstall.symlink "$_srod"; return 1; }
    [ -d "$_srod" ] || { s5_msg_warn uninstall.notdir "$_srod"; return 1; }
    for _sroe in "$_srod"/* "$_srod"/.[!.]* "$_srod"/..?*; do
        if [ -e "$_sroe" ] || [ -L "$_sroe" ]; then
            s5_msg_warn uninstall.nonempty "$_sroe"
            return 1
        fi
    done
    rmdir "$_srod" || { s5_msg_warn uninstall.directory "$_srod"; return 1; }
    return 0
}

s5_uninstall_phase_valid() {
    s5_uninstall_phase_index "$1" >/dev/null
}

# s5_uninstall_phase_index <phase>: the phase's position in S5_UNINSTALL_PHASES.
s5_uninstall_phase_index() {
    _supi_n=0
    for _supi_phase in $S5_UNINSTALL_PHASES; do
        _supi_n=$((_supi_n + 1))
        if [ "$_supi_phase" = "$1" ]; then
            printf '%s' "$_supi_n"
            return 0
        fi
    done
    return 1
}

# s5_uninstall_phase_after <phase>: the phase that follows it.
s5_uninstall_phase_after() {
    _supa_found=0
    for _supa_phase in $S5_UNINSTALL_PHASES; do
        if [ "$_supa_found" = 1 ]; then
            printf '%s' "$_supa_phase"
            return 0
        fi
        [ "$_supa_phase" != "$1" ] || _supa_found=1
    done
    return 1
}

# s5_uninstall_expect <from> <until>: what the recorded phase says of a resource
# whose removal may have begun at phase <from> and is finished after <until>:
# present before <from>, optional through <until>, absent afterwards.
s5_uninstall_expect() {
    _sue_now=$(s5_uninstall_phase_index "$S5_UNINSTALL_PHASE") || return 1
    _sue_from=$(s5_uninstall_phase_index "$1") || return 1
    _sue_until=$(s5_uninstall_phase_index "$2") || return 1
    if [ "$_sue_now" -lt "$_sue_from" ]; then
        printf present
    elif [ "$_sue_now" -le "$_sue_until" ]; then
        printf optional
    else
        printf absent
    fi
}

s5_path_identity() {
    _spi=$(stat -c '%d:%i' "$1" 2>/dev/null) || return 1
    case "$_spi" in *[!0-9:]* | *::* | :* | *:) return 1 ;; esac
    printf '%s\n' "$_spi"
}

s5_path_identity_matches() {
    [ "$(s5_path_identity "$1")" = "$2" ]
}

s5_uninstall_capture_identities() {
    S5_UNINSTALL_PREFIX_ID=$(s5_path_identity "$S5_PREFIX") || return 1
    S5_UNINSTALL_CONFDIR_ID=$(s5_path_identity "$S5_SYSCONFDIR") || return 1
    S5_UNINSTALL_STATEDIR_ID=$(s5_path_identity "$S5_STATEDIR") || return 1
    S5_UNINSTALL_SERVICE_ID=$(s5_path_identity "$S5_SERVICE_ARTIFACT") || return 1
    S5_UNINSTALL_CONFIG_ID=$(s5_path_identity "$S5_CFG") || return 1
    S5_UNINSTALL_BINARY_ID=$(s5_path_identity "$S5_BIN") || return 1
    S5_UNINSTALL_STATE_ID=$(s5_path_identity "$S5_STATE") || return 1
}

s5_uninstall_recovery_write() {
    s5_uninstall_phase_valid "$1" || return 1
    S5_UNINSTALL_PHASE=$1
    S5_RCV_INIT=$S5_INIT
    S5_RCV_FAMILY=$S5_OS_FAMILY
    _surw_record=$(s5_record_print "$S5_RECOVERY_TABLE") || return 1
    s5_atomic_write "$S5_UNINSTALL_STATE" root:root 0600 <<RECOVERY
$_surw_record
RECOVERY
}

s5_uninstall_recovery_load() {
    _surl_path=${1:-$S5_UNINSTALL_STATE}
    s5_path_contract "$_surl_path" file root:root 600 || return 1
    _surl_keys=''
    for _surl_pair in $S5_RECOVERY_TABLE; do _surl_keys="$_surl_keys ${_surl_pair%%:*}"; done
    _surl_fields=$(awk -F '\t' -v stored="$_surl_keys" '
        BEGIN { count=split(stored, k, " "); for(i=1;i<=count;i++) a[k[i]]=1 }
        NF != 2 || !($1 in a) || seen[$1]++ || $2 == "" { bad=1 }
        { v[$1]=$2 }
        END { if (bad || NR != count) exit 1; for(i=1;i<=count;i++) print v[k[i]] }
    ' "$_surl_path" 2>/dev/null) || return 1
    s5_record_read "$S5_RECOVERY_TABLE" <<RECOVERY_FIELDS || return 1
$_surl_fields
RECOVERY_FIELDS
    _surl_fields=''
    s5_uninstall_phase_valid "$S5_UNINSTALL_PHASE" || return 1
    [ "$S5_RCV_INIT" = "$S5_INIT" ] && [ "$S5_RCV_FAMILY" = "$S5_OS_FAMILY" ] || return 1
    s5_valid_decimal "$S5_ACCOUNT_UID" && s5_valid_decimal "$S5_ACCOUNT_GID" &&
        s5_valid_sha256 "$S5_CONFIG_SHA256" &&
        s5_valid_sha256 "$S5_INSTALLED_BINARY_SHA256" &&
        s5_valid_sha256 "$S5_UNIT_SHA256" || return 1
    for _surl_pair in $S5_RECOVERY_TABLE; do
        case "${_surl_pair%%:*}" in *_id) ;; *) continue ;; esac
        _surl_id=''
        eval "_surl_id=\${${_surl_pair#*:}}"
        case "$_surl_id" in '' | *[!0-9:]* | *::* | :* | *:) return 1 ;; esac
    done
}

s5_uninstall_expect_absent() {
    [ ! -e "$1" ] && [ ! -L "$1" ]
}

s5_uninstall_verify_file() {
    _suvf_path=$1
    _suvf_type=$2
    _suvf_owner=$3
    _suvf_mode=$4
    _suvf_sha=$5
    _suvf_id=$6
    s5_path_contract "$_suvf_path" "$_suvf_type" "$_suvf_owner" "$_suvf_mode" || return 1
    s5_path_identity_matches "$_suvf_path" "$_suvf_id" || return 1
    [ "$(s5_sha256 "$_suvf_path" 2>/dev/null)" = "$_suvf_sha" ]
}
s5_uninstall_verify_optional_file() {
    _suvo_path=$1
    shift
    if [ ! -e "$_suvo_path" ] && [ ! -L "$_suvo_path" ]; then return 0; fi
    s5_uninstall_verify_file "$_suvo_path" "$@"
}


s5_uninstall_verify_accounts() {
    _suva_mode=$1
    s5_getent_state passwd "$S5_SERVICE_USER"; _suva_user=$?
    s5_getent_state group "$S5_SERVICE_GROUP"; _suva_group=$?
    case "$_suva_user:$_suva_group" in 2:* | *:2) return 1 ;; esac
    if [ "$_suva_mode" = absent ]; then
        [ "$_suva_user:$_suva_group" = 1:1 ]
        return $?
    fi
    if [ "$_suva_user" = 0 ]; then
        s5_account_user_matches "$S5_ACCOUNT_UID" "$S5_ACCOUNT_GID" || return 1
    elif [ "$_suva_mode" = present ]; then
        return 1
    fi
    if [ "$_suva_group" = 0 ]; then
        s5_account_group_matches "$S5_ACCOUNT_GID" || return 1
    elif [ "$_suva_mode" = present ]; then
        return 1
    fi
    return 0
}

# s5_uninstall_check_path <expectation> <path> <type> <owner> <mode> <identity>:
# a resource recovery verifies by contract and recorded identity alone.
s5_uninstall_check_path() {
    case "$1" in
    present) ;;
    optional) [ -e "$2" ] || [ -L "$2" ] || return 0 ;;
    absent) s5_uninstall_expect_absent "$2"; return $? ;;
    *) return 1 ;;
    esac
    s5_path_contract "$2" "$3" "$4" "$5" && s5_path_identity_matches "$2" "$6"
}

# s5_uninstall_check_file <expectation> <path> <type> <owner> <mode> <sha> <identity>:
# a resource recovery also verifies by content.
s5_uninstall_check_file() {
    case "$1" in
    present) shift; s5_uninstall_verify_file "$@" ;;
    optional) shift; s5_uninstall_verify_optional_file "$@" ;;
    absent) s5_uninstall_expect_absent "$2" ;;
    *) return 1 ;;
    esac
}

s5_uninstall_verify_recovery() {
    s5_unit_mode || return 1
    # Directories that should remain are always checked before their contents. A
    # directory stays strict while its content exists and is optional from then
    # until its own removal.
    s5_uninstall_check_path "$(s5_uninstall_expect complete complete)" \
        "$S5_STATEDIR" dir root:root 700 "$S5_UNINSTALL_STATEDIR_ID" || return 1
    s5_uninstall_check_path "$(s5_uninstall_expect binary-removed state-finalizing)" \
        "$S5_PREFIX" dir root:root 755 "$S5_UNINSTALL_PREFIX_ID" || return 1
    s5_uninstall_check_path "$(s5_uninstall_expect config-removed state-finalizing)" \
        "$S5_SYSCONFDIR" dir "root:$S5_SERVICE_GROUP" 750 "$S5_UNINSTALL_CONFDIR_ID" || return 1
    s5_uninstall_check_file "$(s5_uninstall_expect disabled disabled)" \
        "$S5_SERVICE_ARTIFACT" "$S5_UNIT_TYPE" root:root "$S5_UNIT_MODE" \
        "$S5_UNIT_SHA256" "$S5_UNINSTALL_SERVICE_ID" || return 1
    s5_uninstall_check_file "$(s5_uninstall_expect service-artifact-removed service-artifact-removed)" \
        "$S5_CFG" file "root:$S5_SERVICE_GROUP" 640 \
        "$S5_CONFIG_SHA256" "$S5_UNINSTALL_CONFIG_ID" || return 1
    s5_uninstall_check_file "$(s5_uninstall_expect config-removed config-removed)" \
        "$S5_BIN" exec root:root 755 \
        "$S5_INSTALLED_BINARY_SHA256" "$S5_UNINSTALL_BINARY_ID" || return 1
    # Account removal can crash between user and group deletion.
    case "$(s5_uninstall_expect manager-reloaded manager-reloaded)" in
    present) s5_uninstall_verify_accounts present || return 1 ;;
    optional) s5_uninstall_verify_accounts partial || return 1 ;;
    absent) s5_uninstall_verify_accounts absent || return 1 ;;
    *) return 1 ;;
    esac
    s5_uninstall_check_path "$(s5_uninstall_expect account-removed account-removed)" \
        "$S5_STATE" file root:root 600 "$S5_UNINSTALL_STATE_ID" || return 1
    return 0
}

s5_uninstall_preflight() {
    if [ -e "$S5_TXNDIR" ] || [ -L "$S5_TXNDIR" ]; then
        s5_msg_err uninstall.residue "$S5_TXNDIR"
        return 1
    fi
    for _supdir in "$S5_PREFIX" "$S5_SYSCONFDIR" "$S5_STATEDIR"; do
        [ -e "$_supdir" ] || [ -L "$_supdir" ] || continue
        if [ ! -d "$_supdir" ] || [ -L "$_supdir" ]; then
            s5_msg_err uninstall.residue "$_supdir"
            return 1
        fi
        for _supentry in "$_supdir"/* "$_supdir"/.[!.]* "$_supdir"/..?*; do
            [ -e "$_supentry" ] || [ -L "$_supentry" ] || continue
            _supvalid=0
            # The transaction directory was refused above, so neither it nor
            # its members can appear here.
            case "$_supentry" in
            "$S5_CFG" | "$S5_STATE" | "$S5_UNINSTALL_STATE" | "$S5_BIN" | \
            "$_supdir"/.s5tmp.* | "$_supdir"/.s5new.* | "$_supdir"/.xray.*)
                [ -f "$_supentry" ] && [ ! -L "$_supentry" ] || _supvalid=1 ;;
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

s5_uninstall_checkpoint() {
    S5_UNINSTALL_PHASE=$1
    s5_uninstall_recovery_write "$S5_UNINSTALL_PHASE" || {
        s5_msg_err uninstall.progress "$S5_UNINSTALL_STATE"
        return 1
    }
    # One private seam covers ordinary failure and signal injection in tests.
    if [ -n "${S5_UNINSTALL_INJECT:-}" ]; then
        "$S5_UNINSTALL_INJECT" "$S5_UNINSTALL_PHASE"
    fi
}

# s5_uninstall_step <phase>: the work a phase leaves to do. Its checkpoint names
# the next phase, so a crash after the work and before the checkpoint repeats
# work that is safe to repeat.
s5_uninstall_step() {
    case "$1" in
    prepared)
        # Preflight approved only installer-owned temporary patterns; remove
        # them before the durable artifact phases begin.
        s5_cleanup_own_temps "$S5_SYSCONFDIR" || return 1
        s5_cleanup_own_temps "$S5_STATEDIR" || return 1
        s5_cleanup_own_temps "$S5_PREFIX" binaries || return 1
        s5_cleanup_transaction || return 1
        s5_svc stop || { s5_msg_err service.stop; return 1; }
        s5_wait_stopped || { s5_msg_err service.stop; return 1; }
        ;;
    stopped)
        s5_svc disable || { s5_msg_err service.disable; return 1; }
        ;;
    disabled)
        s5_remove_owned_file "$S5_SERVICE_ARTIFACT" || return 1
        ;;
    service-artifact-removed)
        s5_remove_owned_file "$S5_CFG" || return 1
        ;;
    config-removed)
        s5_remove_owned_file "$S5_BIN" || return 1
        ;;
    binary-removed)
        s5_svc reload || { s5_msg_err service.reload; return 1; }
        ;;
    manager-reloaded)
        s5_account_remove || return 1
        ;;
    account-removed)
        s5_remove_owned_file "$S5_STATE" || return 1
        ;;
    state-finalizing)
        s5_cleanup_transaction || return 1
        s5_remove_owned_dir "$S5_SYSCONFDIR" || return 1
        s5_remove_owned_dir "$S5_PREFIX" || return 1
        ;;
    *) return 1 ;;
    esac
}

s5_uninstall_run() {
    while [ "$S5_UNINSTALL_PHASE" != complete ]; do
        s5_uninstall_step "$S5_UNINSTALL_PHASE" || return 1
        _surun_next=$(s5_uninstall_phase_after "$S5_UNINSTALL_PHASE") || return 1
        s5_uninstall_checkpoint "$_surun_next" || return 1
    done
    # Move the last ownership proof outside the directory being removed.
    # The rename makes every crash window resumable: before it, the state
    # record exists; after it, the final marker exists; after marker
    # removal, the namespace is already absent.
    if [ -f "$S5_UNINSTALL_STATE" ] && [ ! -L "$S5_UNINSTALL_STATE" ]; then
        if [ -e "$S5_UNINSTALL_FINAL" ] || [ -L "$S5_UNINSTALL_FINAL" ]; then
            s5_msg_err uninstall.residue "$S5_UNINSTALL_FINAL"
            return 1
        fi
        mv "$S5_UNINSTALL_STATE" "$S5_UNINSTALL_FINAL" || return 1
    fi
    if [ -n "${S5_UNINSTALL_INJECT:-}" ]; then
        "$S5_UNINSTALL_INJECT" complete-moved || return 1
    fi
    s5_remove_owned_dir "$S5_STATEDIR" || return 1
    s5_remove_owned_file "$S5_UNINSTALL_FINAL" || return 1
    return 0
}

s5_namespace_absent() {
    s5_select_service_artifact || return 1
    for _sna_path in "$S5_SYSCONFDIR" "$S5_STATEDIR" "$S5_PREFIX" "$S5_SERVICE_ARTIFACT" "$S5_UNINSTALL_FINAL"; do
        [ ! -e "$_sna_path" ] && [ ! -L "$_sna_path" ] || return 1
    done
    s5_getent_state passwd "$S5_SERVICE_USER"; [ "$?" = 1 ] || return 1
    s5_getent_state group "$S5_SERVICE_GROUP"; [ "$?" = 1 ] || return 1
}

s5_cmd_uninstall() {
    s5_enter_locked uninstall || return 1
    if [ -f "$S5_UNINSTALL_FINAL" ] && [ ! -L "$S5_UNINSTALL_FINAL" ]; then
        s5_uninstall_recovery_load "$S5_UNINSTALL_FINAL" ||
            { s5_fail_locked state.invalid "$S5_UNINSTALL_FINAL"; return 1; }
        s5_uninstall_verify_recovery || { s5_fail_locked uninstall.residue "$S5_UNINSTALL_FINAL"; return 1; }
    elif [ -f "$S5_UNINSTALL_STATE" ] && [ ! -L "$S5_UNINSTALL_STATE" ]; then
        s5_uninstall_recovery_load "$S5_UNINSTALL_STATE" ||
            { s5_fail_locked state.invalid "$S5_UNINSTALL_STATE"; return 1; }
        s5_uninstall_verify_recovery || { s5_fail_locked uninstall.residue "$S5_UNINSTALL_STATE"; return 1; }
    else
        s5_open_managed_state
        _scu_state=$?
        if [ "$_scu_state" = 3 ]; then
            if s5_namespace_absent; then
                s5_lock_release || true
                s5_msg_print state.missing "$S5_PROJECT"
                return 0
            fi
            s5_fail_locked state.invalid "$S5_STATE"
            return 1
        fi
        s5_accept_state "$_scu_state" || return 1
        s5_confirm uninstall s5_lock_release || return 1
        s5_uninstall_preflight || { s5_fail_locked; return 1; }
        s5_account_identity "$S5_ACCOUNT_UID" "$S5_ACCOUNT_GID" ||
            { s5_fail_locked account.identity; return 1; }
        s5_uninstall_capture_identities || { s5_fail_locked uninstall.identity; return 1; }
        S5_UNINSTALL_PHASE=prepared
        s5_uninstall_checkpoint prepared || { s5_fail_locked; return 1; }
    fi
    s5_uninstall_run || { s5_fail_locked; return 1; }
    s5_lock_release || return 1
    s5_msg_print uninstall.done
}

s5_main() {
    # A bare `language` asks afresh in s5_cmd_language; every other invocation,
    # including `language` with extra arguments, speaks the saved preference.
    case "$#:${1:-}" in
    1:language) ;;
    *) s5_init_language || return 1 ;;
    esac
    _smcmd=${1:-}
    # shift is a POSIX special built-in, so shifting past the end terminates a
    # non-interactive shell outright -- neither the redirect nor the `|| true`
    # can catch it. Under dash, which is /bin/sh on Debian and Ubuntu, that
    # killed the documented zero-argument invocation before it dispatched.
    if [ "$#" -gt 0 ]; then
        shift
    fi
    if [ "$#" -gt 0 ]; then
        s5_msg_err usage.extra "$*"
        return 64
    fi
    case "$_smcmd" in
    '' | install) s5_cmd_install ;;
    status) s5_cmd_status ;;
    show) s5_cmd_show ;;
    restart) s5_cmd_restart ;;
    uninstall) s5_cmd_uninstall ;;
    language) s5_cmd_language ;;
    help | -h | --help) s5_msg_print usage ;;
    *) s5_msg_err usage.unknown "$_smcmd"; s5_msg_print usage >&2; return 64 ;;
    esac
}

if [ "${S5_LIB_ONLY:-0}" != 1 ]; then
    s5_main "$@"
    exit $?
fi
