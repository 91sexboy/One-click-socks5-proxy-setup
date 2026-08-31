#!/bin/sh
set -eu

LOCALE_STREAM=${1:?usage: run-openrc-memory-gate.sh invalid-then-zh|invalid-then-en}
case "$LOCALE_STREAM" in invalid-then-zh | invalid-then-en) ;; *) exit 2;; esac

cd /src
mkdir -p /run/openrc
touch /run/openrc/softlevel
rc-status -a >/dev/null 2>&1
command -v logger >/dev/null
if [ ! -S /dev/log ] && command -v syslogd >/dev/null 2>&1; then syslogd; fi
logger -t socks5-manager-ci -p daemon.info "openrc logger probe"
if command -v curl >/dev/null 2>&1; then
    printf 'target unexpectedly contains curl before install\n' >&2
    exit 1
fi

umask 077
SECRETS=$(mktemp -d)
chmod 0700 "$SECRETS"
cleanup() { rm -rf "$SECRETS"; }
trap cleanup EXIT HUP INT TERM
tr -dc 'A-Za-z0-9._~-' </dev/urandom | head -c 32 >"$SECRETS/pass"
chmod 0600 "$SECRETS/pass"
case "$LOCALE_STREAM" in
invalid-then-zh) printf '9\n\ny\n41080\nciuser\n' >"$SECRETS/answers" ;;
invalid-then-en) printf '9\n2\ny\n41080\nciuser\n' >"$SECRETS/answers" ;;
esac
cat "$SECRETS/pass" >>"$SECRETS/answers"
printf '\n' >>"$SECRETS/answers"
{ printf 's|'; cat "$SECRETS/pass"; printf '|***REDACTED***|g\n'; } >"$SECRETS/redact.sed"

if ! sh socks5.sh install <"$SECRETS/answers" >"$SECRETS/install.log" 2>&1; then
    sed -f "$SECRETS/redact.sed" "$SECRETS/install.log" >&2
    exit 1
fi

NEW_PORT=41081
NEW_USER=ciuser2
tr -dc 'A-Za-z0-9._~-' </dev/urandom | head -c 32 >"$SECRETS/pass2"
chmod 0600 "$SECRETS/pass2"
{ printf 's|'; cat "$SECRETS/pass2"; printf '|***REDACTED***|g\n'; } >>"$SECRETS/redact.sed"
printf '2\ny\n%s\n%s\n' "$NEW_PORT" "$NEW_USER" >"$SECRETS/update.answers"
cat "$SECRETS/pass2" >>"$SECRETS/update.answers"
printf '\n' >>"$SECRETS/update.answers"
if ! sh socks5.sh install <"$SECRETS/update.answers" >"$SECRETS/update.log" 2>&1; then
    sed -f "$SECRETS/redact.sed" "$SECRETS/update.log" >&2
    exit 1
fi

test ! -e /var/lib/socks5-manager/reconfigure-transaction
test ! -e /run/socks5-manager.lock
sh tests/protocol/post_install_audit.sh openrc "$SECRETS" /root
printf '2\n' | sh socks5.sh status
printf 'S5_STAGE=status\n'
rc-service socks5-manager status
printf 'S5_STAGE=active-before-restart\n'
sh .github/scripts/check-listen-port.sh "$NEW_PORT" present
sh .github/scripts/check-listen-port.sh 41080 absent
printf 'S5_STAGE=listening-before-restart\n'
printf '2\n' | sh socks5.sh restart
printf 'S5_STAGE=restart\n'
rc-service socks5-manager status
printf 'S5_STAGE=active-after-restart\n'
sh .github/scripts/check-listen-port.sh "$NEW_PORT" present
printf 'S5_STAGE=listening-after-restart\n'
PORT=$NEW_PORT PROXY_USER=$NEW_USER PASSFILE="$SECRETS/pass2" \
    sh tests/protocol/run_protocol.sh
printf 'S5_STAGE=protocol\n'
printf '2\ny\n' | sh socks5.sh uninstall
printf 'S5_STAGE=uninstall\n'

test ! -e /etc/socks5-manager
test ! -e /var/lib/socks5-manager
test ! -e /usr/local/libexec/socks5-manager
test ! -e /etc/init.d/socks5-manager
if id socks5proxy >/dev/null 2>&1; then exit 1; fi
if getent group socks5proxy >/dev/null 2>&1; then exit 1; fi
for cmd in git make gcc cc; do
    if command -v "$cmd" >/dev/null 2>&1; then
        printf 'target unexpectedly contains %s\n' "$cmd" >&2
        exit 1
    fi
done

PEAK=$(cat /sys/fs/cgroup/memory.peak 2>/dev/null ||
    cat /sys/fs/cgroup/memory/memory.max_usage_in_bytes)
case "$PEAK" in '' | *[!0-9]*) printf 'invalid memory peak: %s\n' "$PEAK" >&2; exit 1;; esac
[ "$PEAK" -le 134217728 ] || { printf 'memory peak exceeds 128 MiB: %s\n' "$PEAK" >&2; exit 1; }
printf 'S5_MEMORY_PEAK=%s\n' "$PEAK"
