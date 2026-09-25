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

# Set up filtering BEFORE running anything that might publish a credential.
# Patterns travel only through a private file, never argv or the environment.
_pat=$(mktemp) || { printf 'runner: no redaction pattern file\n' >&2; exit 2; }
_err=''
trap 'rm -f "$_pat" "$_err"' EXIT
_err=$(mktemp) || { printf 'runner: no private error file\n' >&2; exit 2; }
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
for _credential_file do
    if [ ! -f "$_credential_file" ] ||
        ! awk 'NR == 2 {print} NR <= 2 && length($0) == 0 {bad = 1} END {exit (NR < 2 || bad) ? 1 : 0}' \
            "$_credential_file" >>"$_pat" 2>/dev/null; then
        printf 'runner: unreadable or incomplete credential file\n' >&2
        exit 2
    fi
    _user=$(sed -n '1p' "$_credential_file") || exit 2
    _pass=$(sed -n '2p' "$_credential_file") || exit 2
    _pair=$_user:$_pass
    printf '%s\n' "$_pair" >>"$_pat" || exit 2
    printf '%s' "$_pair" | base64 | tr -d '\n' >>"$_pat" || exit 2
    printf '\n' >>"$_pat" || exit 2
    _user=''; _pass=''; _pair=''
done
redact() {
    # Match the longest literal at each position, without filtering replacement
    # markers again. A rotated credential can extend a previous one.
    awk '
        BEGIN {
            while ((loaded = getline secret < ARGV[1]) > 0) {
                if (secret == "") exit 2
                secrets[++count] = secret
            }
            if (loaded < 0 || count < 2) exit 2
            close(ARGV[1]); ARGV[1] = ""
        }
        function hide(text, result, i, at, first, width) {
            result = ""
            while (length(text)) {
                first = 0; width = 0
                for (i = 1; i <= count; i++) {
                    at = index(text, secrets[i])
                    if (at && (!first || at < first || (at == first && length(secrets[i]) > width))) {
                        first = at; width = length(secrets[i])
                    }
                }
                if (!first) return result text
                result = result substr(text, 1, first - 1) "<REDACTED>"
                text = substr(text, first + width)
            }
            return result
        }
        {print hide($0)}
    ' "$_pat"
}

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
