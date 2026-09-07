#!/bin/sh
# Run one socks5.sh subcommand as root and, on failure, print evidence with the
# password removed.
#
# SPEC 7 keeps credentials out of CI output and SPEC 8 needs a failed lifecycle
# to be diagnosable; a job that redirects the installer log to a file and never
# prints it satisfies the first by destroying the second.
set -u
umask 077

CMD=${1:?usage: run-socks5.sh SUBCOMMAND ANSWERS LOG PASSFILE}
ANSWERS=${2:?usage: run-socks5.sh SUBCOMMAND ANSWERS LOG PASSFILE}
LOG=${3:?usage: run-socks5.sh SUBCOMMAND ANSWERS LOG PASSFILE}
PASSFILE=${4:?usage: run-socks5.sh SUBCOMMAND ANSWERS LOG PASSFILE}

# An empty pattern would match every line, so -v would print nothing at all and
# the redaction would silently become a blackout.
[ "$(sed -n '2p' "$PASSFILE" | wc -c | tr -d '[:space:]')" -gt 1 ] || {
    printf 'PASSFILE has no password on line 2: %s\n' "$PASSFILE" >&2
    exit 2
}

status=0
printf 'runner: invoking socks5.sh %s\n' "$CMD" >&2
sh socks5.sh "$CMD" <"$ANSWERS" >"$LOG" 2>&1 || status=$?
printf 'runner: socks5.sh %s returned %s\n' "$CMD" "$status" >&2
if [ "$status" -eq 0 ]; then
    cat "$LOG"
    exit 0
fi

printf 'socks5.sh %s failed with status %s; redacted evidence follows\n' "$CMD" "$status" >&2
# Keep the password out of grep's argv (and so out of this script's
# /proc/<pid>/cmdline) by reading the pattern from a file -- -f is the only form
# that does. mktemp creates it 0600 and the trap removes it even under a signal.
# The status and journal dumps carry the credential as readily as the log did,
# so all three share one filter rather than only the log being redacted.
_pat=$(mktemp) || { printf 'runner: no redaction pattern file\n' >&2; exit 1; }
trap 'rm -f "$_pat"' EXIT HUP INT TERM
sed -n '2p' "$PASSFILE" >"$_pat"
redact() { grep -vFf "$_pat" || true; }
redact <"$LOG" >&2
printf -- '--- systemctl status ---\n' >&2
systemctl status xray-socks5.service --no-pager -l 2>&1 | redact >&2
printf -- '--- journal ---\n' >&2
journalctl -u xray-socks5.service --no-pager -n 120 2>&1 | redact >&2
printf -- '--- listener ---\n' >&2
ss -ltnp 2>&1 | redact >&2
exit 1
