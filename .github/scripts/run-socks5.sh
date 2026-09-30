#!/bin/sh
# Run one socks5.sh subcommand and redact every replay before it reaches CI.
# Keep raw evidence private on disk; preserve command status and useful diagnostics.
set -u
umask 077

MODE=run
if [ "${1:-}" = --diagnose ]; then
    MODE=diagnose
    shift
fi
CMD=${1:?usage: run-socks5.sh [--diagnose] SUBCOMMAND ANSWERS LOG PASSFILE [PASSFILE...]}
ANSWERS=${2:?usage: run-socks5.sh SUBCOMMAND ANSWERS LOG PASSFILE [PASSFILE...]}
LOG=${3:?usage: run-socks5.sh SUBCOMMAND ANSWERS LOG PASSFILE [PASSFILE...]}
PASSFILE=${4:?usage: run-socks5.sh SUBCOMMAND ANSWERS LOG PASSFILE [PASSFILE...]}
shift 4
set -- "$PASSFILE" "$@"
# shellcheck source=.github/scripts/lifecycle-common.sh
. "$(dirname "$0")/lifecycle-common.sh"

# Set up filtering BEFORE running anything that might publish a credential.
# Patterns travel only through a private file, never argv or the environment.
_pat=$(mktemp) || { printf 'runner: no redaction pattern file\n' >&2; exit 2; }
_err=''
trap 'rm -f "$_pat" "$_err"' EXIT
_err=$(mktemp) || { printf 'runner: no private error file\n' >&2; exit 2; }
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
lifecycle_redaction_file "$_pat" "$@" || {
    printf 'runner: unreadable or incomplete credential file\n' >&2
    exit 2
}
redact() { lifecycle_redact "$_pat"; }

status=1
if [ "$MODE" = run ]; then
    status=0
    printf 'runner: invoking socks5.sh %s\n' "$CMD" | redact >&2
    # The group's stderr includes shell-level errors opening ANSWERS or LOG.
    { sh socks5.sh "$CMD" <"$ANSWERS" >"$LOG" 2>&1; } 2>"$_err" || status=$?
    if [ -s "$_err" ]; then redact <"$_err" >&2; fi
    rm -f "$_err"
    printf 'runner: socks5.sh %s returned %s\n' "$CMD" "$status" | redact >&2
    if [ "$status" -eq 0 ]; then
        { cat "$LOG"; } 2>&1 | redact
        exit $?
    fi
    printf 'socks5.sh %s failed with status %s; redacted evidence follows\n' "$CMD" "$status" | redact >&2
else
    printf 'socks5.sh %s terminal verification failed; redacted evidence follows\n' "$CMD" | redact >&2
fi
{ cat "$LOG"; } 2>&1 | redact >&2
if command -v systemctl >/dev/null 2>&1; then
    printf -- '--- systemctl status ---\n' >&2
    systemctl status xray-socks5.service --no-pager -l 2>&1 | redact >&2
    printf -- '--- journal ---\n' >&2
    journalctl -u xray-socks5.service --no-pager -n 120 2>&1 | redact >&2
elif command -v rc-service >/dev/null 2>&1; then
    printf -- '--- OpenRC status ---\n' >&2
    rc-service xray-socks5 status 2>&1 | redact >&2
fi
printf -- '--- listener ---\n' >&2
ss -ltnp 2>&1 | redact >&2
exit "$status"
