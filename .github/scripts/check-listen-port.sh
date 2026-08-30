#!/bin/sh
set -eu

PORT=${1:?usage: check-listen-port.sh PORT present|absent}
WANT=${2:?present or absent required}
case "$PORT" in '' | *[!0-9]* | 0*) exit 2;; esac
[ "$PORT" -le 65535 ] || exit 2
case "$WANT" in present | absent) ;; *) exit 2;; esac

hex=$(printf '%04X' "$PORT")
files=/proc/net/tcp
[ -r /proc/net/tcp6 ] && files="$files /proc/net/tcp6"
# shellcheck disable=SC2086
if awk -v suffix=":$hex" '
    NR > 1 && substr($2, length($2) - 4) == suffix && $4 == "0A" { found=1 }
    END { exit found ? 0 : 1 }
' $files; then
    found=present
else
    found=absent
fi
[ "$found" = "$WANT" ] || {
    printf 'port %s: expected %s, observed %s\n' "$PORT" "$WANT" "$found" >&2
    exit 1
}
