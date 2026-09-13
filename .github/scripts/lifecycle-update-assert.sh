#!/bin/sh
# The state directory is 0700: unprivileged -e cannot distinguish absence from
# an inaccessible parent, so all shared post-update observations require root.
set -eu

[ "$(id -u)" = 0 ] || {
    printf '%s\n' 'lifecycle update assertions require root' >&2
    exit 1
}
_cfg=/etc/xray-socks5/config.json
_state=/var/lib/xray-socks5/state
_txn=/var/lib/xray-socks5/transaction
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
