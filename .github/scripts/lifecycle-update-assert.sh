#!/bin/sh
# The state directory is 0700: unprivileged -e cannot distinguish absence from
# an inaccessible parent, so all shared post-update observations require root.
set -eu

[ "$(id -u)" = 0 ] || {
    printf '%s\n' 'lifecycle update assertions require root' >&2
    exit 1
}
ROOT=${1:-/}
_cfg=$ROOT/etc/xray-socks5/config.json
_state=$ROOT/var/lib/xray-socks5/state
_txn=$ROOT/var/lib/xray-socks5/transaction
_prefix=$ROOT/usr/local/libexec/xray-socks5
printf '%s\n' 'lifecycle-update-assert: reached'

if [ ! -f "$_cfg" ] || [ -L "$_cfg" ]; then
    printf '%s\n' 'updated config is not a regular file' >&2
    exit 1
fi
if ! python3 - "$_cfg" <<'PY'
import json
import sys
try:
    with open(sys.argv[1], encoding='utf-8') as handle:
        config = json.load(handle)
    users = [account['user'] for inbound in config['inbounds']
             for account in inbound['settings']['accounts']]
    valid = users == ['ciuser2']
except (OSError, ValueError, KeyError, TypeError):
    valid = False
sys.exit(0 if valid else 1)
PY
then
    printf '%s\n' 'updated config has the wrong identity' >&2
    exit 1
fi
if [ ! -f "$_state" ] || [ -L "$_state" ]; then
    printf '%s\n' 'updated state is not a regular file' >&2
    exit 1
fi
grep -qE '^username[[:space:]]+ciuser2$' "$_state" || {
    printf '%s\n' 'updated state has the wrong identity' >&2
    exit 1
}
if [ -e "$_txn" ] || [ -L "$_txn" ]; then
    printf '%s\n' 'update transaction evidence remains' >&2
    exit 1
fi
[ "$(stat -c '%U:%G %a' "$_cfg")" = 'root:xray-socks5 640' ] || {
    printf '%s\n' 'updated config ownership or mode is wrong' >&2
    exit 1
}
# The install directory is root:root 0755. A binary-replacing update re-creates
# it private to shield its staging window, and a restore that does not run leaves
# the service account unable to traverse its own installation -- while the config,
# the state and the service all still look correct to every check above.
if [ ! -d "$_prefix" ] || [ -L "$_prefix" ]; then
    printf '%s\n' 'updated install directory is not a directory' >&2
    exit 1
fi
[ "$(stat -c '%U:%G %a' "$_prefix")" = 'root:root 755' ] || {
    printf '%s\n' 'updated install directory ownership or mode is wrong' >&2
    exit 1
}
