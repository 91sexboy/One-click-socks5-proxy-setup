#!/bin/sh
# tests/protocol/start_engine.sh - CI ONLY.
#
# Builds 3proxy from the pinned commit, renders the production configuration,
# and starts the engine in the background so run_protocol.sh and
# acl_resolution.sh can exercise the protocol boundary without needing systemd
# or OpenRC.
#
# SCOPE: this proves the engine + the rendered config. It does NOT install a
# service. Real systemd/OpenRC installation is covered by separate CI jobs.
#
# This binds a real TCP port and must never run on a development machine.
# The listener is confined to loopback via the S5_LISTEN override, which
# socks5.sh honours only under S5_TEST_MODE=1; production always binds 0.0.0.0.
#
# The password is read from $PASSFILE (mode 0600), never from argv or the
# environment. Writes $OUTDIR/{port,user,pid,root}. It never writes the password.

set -eu

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH='' cd -- "$HERE/../.." && pwd)
OUTDIR=${OUTDIR:-$(mktemp -d)}

PORT=${PORT:-41080}
PROXY_USER=${PROXY_USER:-ciuser}
PASSFILE=${PASSFILE:?PASSFILE must point at a 0600 file holding the password}

if [ ! -f "$PASSFILE" ] || [ -L "$PASSFILE" ]; then
    printf 'PASSFILE must be a regular non-symlink file: %s\n' "$PASSFILE" >&2
    exit 2
fi
_pfmode=$(stat -c '%a' "$PASSFILE" 2>/dev/null || printf '')
if [ "$_pfmode" != 600 ]; then
    printf 'PASSFILE must have mode 0600, found %s: %s\n' "${_pfmode:-unknown}" "$PASSFILE" >&2
    exit 2
fi

umask 077
ROOT=$(mktemp -d)
: >"$ROOT/.s5-test-root"

S5_TEST_MODE=1
S5_TEST_ROOT="$ROOT"
S5_LIB_ONLY=1
S5_SKIP_OWNERSHIP=1
S5_ASSUME_ROOT=1
# Confine the CI listener to loopback. Rejected outside test mode.
S5_LISTEN=127.0.0.1
export S5_TEST_MODE S5_TEST_ROOT S5_LIB_ONLY S5_SKIP_OWNERSHIP S5_ASSUME_ROOT S5_LISTEN

# shellcheck source=/dev/null
. "$REPO/socks5.sh"

printf 'building 3proxy at pinned commit %s\n' "$S5_PINNED_COMMIT" >&2
s5_build_3proxy

S5_PORT=$PORT
S5_USERNAME=$PROXY_USER
S5_PASSWORD=$(cat "$PASSFILE")
S5_SECRET=$S5_PASSWORD

mkdir -p "$S5_SYSCONFDIR"
chmod 0700 "$S5_SYSCONFDIR"
s5_render_users >"$S5_USERSCFG"
chmod 0640 "$S5_USERSCFG"
s5_render_cfg >"$S5_CFG"
chmod 0640 "$S5_CFG"

# The same static check the installer performs.
s5_static_check_cfg "$S5_CFG"

# The rendered configuration holds no credentials of any kind: the only thing it
# says about them is `users $<confdir>/users.cfg`, and that file is never printed.
# Saying "credentials elided" implied a redaction that was not happening and that
# there was nothing to redact.
printf 'rendered configuration (no credentials appear in it; paths shortened):\n' >&2
sed -e "s|$S5_SYSCONFDIR|<confdir>|g" "$S5_CFG" >&2

"$S5_BIN" "$S5_CFG" &
enginepid=$!

# wait for the port to accept connections
i=0
while [ "$i" -lt 50 ]; do
    if python3 -c "import socket,sys; s=socket.socket(); s.settimeout(1); sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT))==0 else 1)"; then
        break
    fi
    i=$((i + 1))
    sleep 0.2
done
if [ "$i" -ge 50 ]; then
    printf 'engine did not start listening on 127.0.0.1:%s\n' "$PORT" >&2
    kill "$enginepid" 2>/dev/null || true
    exit 1
fi

mkdir -p "$OUTDIR"
chmod 0700 "$OUTDIR"
printf '%s' "$PORT" >"$OUTDIR/port"
printf '%s' "$PROXY_USER" >"$OUTDIR/user"
printf '%s' "$enginepid" >"$OUTDIR/pid"
printf '%s' "$ROOT" >"$OUTDIR/root"
printf 'engine listening on 127.0.0.1:%s (pid %s)\n' "$PORT" "$enginepid" >&2
