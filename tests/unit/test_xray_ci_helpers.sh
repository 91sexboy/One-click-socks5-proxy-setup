#!/bin/sh
# Nonprivileged behavioral checks for CI process ownership and memory sampling.
S5T_NAME=test_xray_ci_helpers
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
t_mktestroot
s5t_source_contract() {
    t_source_production "$S5_REPO_ROOT/tests/fixtures/os-release/debian-12" || return 1
    [ "$S5_LIB_ONLY:$S5_ASSUME_ROOT:$S5_SKIP_OWNERSHIP" = 1:1:1 ] || return 1
    s5_map_arch x86_64
}
t_run s5t_source_contract
assert_eq "shared source setup loads isolated production functions" 0 "$T_STATUS"
assert_eq "shared source setup preserves the production interface" amd64 "$T_OUT"
: >"$S5_TEST_ROOT/empty"
t_run t_sha256 "$S5_TEST_ROOT/empty"
assert_eq "shared hash helper hashes the supplied file" \
    e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 "$T_OUT"
t_run t_stub synthetic-command <<'STUB'
#!/bin/sh
printf '%s\n' "$1"
exit 7
STUB
assert_eq "shared stub writer creates an executable command" 0 "$T_STATUS"
t_run "$S5_TEST_ROOT/bin/synthetic-command" argument
assert_eq "a shared stub keeps its supplied exit status" 7 "$T_STATUS"
assert_eq "a shared stub keeps its supplied arguments" argument "$T_OUT"
# shellcheck source=/dev/null
. "$S5_REPO_ROOT/.github/scripts/lifecycle-common.sh"
printf 'ordinary diagnostic\n' >"$S5_TEST_ROOT/clean.log"
printf 'synthetic.[credential]~\n' >"$S5_TEST_ROOT/leaked.log"
t_run lifecycle_no_credential_in "$S5_TEST_ROOT/clean.log" 'synthetic.[credential]~'
assert_eq "a readable credential-free log passes" 0 "$T_STATUS"
t_run lifecycle_no_credential_in "$S5_TEST_ROOT/leaked.log" 'synthetic.[credential]~'
assert_ne "a literal credential match fails" 0 "$T_STATUS"
assert_not_contains "the failure never repeats the credential" 'synthetic.[credential]~' "$T_OUT"
t_run lifecycle_no_credential_in "$S5_TEST_ROOT/missing.log" 'synthetic.[credential]~'
assert_ne "a missing log is not a clean log" 0 "$T_STATUS"
assert_contains "an unreadable log identifies a failed check" 'credential check' "$T_OUT"
s5t_credential_prefix() {
    printf '%s\n' "$1" >"$S5_TEST_ROOT/prefix-command"
    "$@"
}
t_run lifecycle_no_credential_in "$S5_TEST_ROOT/clean.log" 'synthetic.[credential]~' s5t_credential_prefix
assert_eq "a privilege prefix can inspect a clean log" 0 "$T_STATUS"
assert_eq "the privilege prefix executes grep" grep "$(cat "$S5_TEST_ROOT/prefix-command")"
s5t_credential_denied() { return 2; }
t_run lifecycle_no_credential_in "$S5_TEST_ROOT/clean.log" 'synthetic.[credential]~' s5t_credential_denied
assert_ne "a failed privileged read is not a clean log" 0 "$T_STATUS"

# The argv/environ check copies each /proc file before searching it: an
# unreadable one is a failed check (2), not an empty stream that passes.
printf 'ciuser\nCISecret123x\n' >"$S5_TEST_ROOT/proc.pass"
chmod 0600 "$S5_TEST_ROOT/proc.pass"
mkdir -p "$S5_TEST_ROOT/proc-copy"
t_run lifecycle_process_clean 999999999 "$S5_TEST_ROOT/proc-copy" "$S5_TEST_ROOT/proc.pass"
assert_eq "an unreadable process is a failed check" 2 "$T_STATUS"
assert_contains "an unreadable process is named" 'could not read /proc/999999999/cmdline' "$T_OUT"
sleep 30 &
_pc_clean=$!
# The trailing no-op keeps the shell, and its argv, from being replaced by exec.
sh -c 'sleep 30; :' argv-leak CISecret123x &
_pc_argv=$!
env PC_LEAK=ciuser:CISecret123x sleep 30 &
_pc_env=$!
# A child read mid-exec shows an empty or transient argv; wait until each one
# is the program it was started as.
s5t_exec_settled() {
    _es_i=0
    while [ "$_es_i" -lt 50 ]; do
        case "$(tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null)" in *"$2"*) return 0 ;; esac
        _es_i=$((_es_i + 1))
        sleep 0.1
    done
    return 1
}
s5t_exec_settled "$_pc_clean" 'sleep 30'
s5t_exec_settled "$_pc_argv" 'argv-leak CISecret123x'
s5t_exec_settled "$_pc_env" 'sleep 30'
t_run lifecycle_process_clean "$_pc_clean" "$S5_TEST_ROOT/proc-copy" "$S5_TEST_ROOT/proc.pass"
assert_eq "a credential-free process passes" 0 "$T_STATUS"
t_run lifecycle_process_clean "$_pc_argv" "$S5_TEST_ROOT/proc-copy" "$S5_TEST_ROOT/proc.pass"
assert_eq "a password in argv is a leak" 1 "$T_STATUS"
t_run lifecycle_process_clean "$_pc_env" "$S5_TEST_ROOT/proc-copy" "$S5_TEST_ROOT/proc.pass"
assert_eq "a user:pass pair in the environment is a leak" 1 "$T_STATUS"
assert_not_contains "the leak report never repeats the credential" CISecret123x "$T_OUT"
kill "$_pc_clean" "$_pc_argv" "$_pc_env" 2>/dev/null || true
wait "$_pc_clean" "$_pc_argv" "$_pc_env" 2>/dev/null || true

# One redaction for every CI log exit: each form is replaced in place and the
# rest of the line survives, including the base64 of user:pass.
lifecycle_redaction_file "$S5_TEST_ROOT/redact.pat" "$S5_TEST_ROOT/proc.pass"
assert_eq "the redaction patterns are written" 0 "$?"
_rd_b64=$(printf '%s' 'ciuser:CISecret123x' | base64 | tr -d '\n')
printf 'pass=CISecret123x\npair=ciuser:CISecret123x!\nauth=Basic %s\nclean line\n' "$_rd_b64" |
    lifecycle_redact "$S5_TEST_ROOT/redact.pat" >"$S5_TEST_ROOT/redacted.log"
assert_eq "every credential form is replaced in place" 'pass=<REDACTED>
pair=<REDACTED>!
auth=Basic <REDACTED>
clean line' "$(cat "$S5_TEST_ROOT/redacted.log")"
: >"$S5_TEST_ROOT/empty.pass"
t_run lifecycle_redaction_file "$S5_TEST_ROOT/redact.pat" "$S5_TEST_ROOT/empty.pass"
assert_ne "an incomplete credential file writes no patterns" 0 "$T_STATUS"

# The exited-service assertion is the gate's control: a zero status must fail
# it even when the log names the state, and so must a log that does not.
printf 'service: crashed; port: 23456; username: u; protocol: mixed (SOCKS5 + HTTP); auth: password; UDP: disabled\n' \
    >"$S5_TEST_ROOT/crashed.log"
t_run lifecycle_assert_exited_status 1 "$S5_TEST_ROOT/crashed.log" crashed 23456
assert_eq "a nonzero crashed status passes" 0 "$T_STATUS"
t_run lifecycle_assert_exited_status 0 "$S5_TEST_ROOT/crashed.log" crashed 23456
assert_ne "a zero status for a crashed service fails the gate" 0 "$T_STATUS"
assert_contains "the zero status is named" 'status returned 0 for a crashed service' "$T_OUT"
sed 's/service: crashed;/service: running;/' "$S5_TEST_ROOT/crashed.log" >"$S5_TEST_ROOT/running.log"
t_run lifecycle_assert_exited_status 1 "$S5_TEST_ROOT/running.log" crashed 23456
assert_ne "a status that does not name the crash fails the gate" 0 "$T_STATUS"

# The shared ready-status assertion needs the port's ready line and the
# protocol summary, not the heading's word "mixed".
printf 'Xray mixed proxy status:\nservice: running; port: 23456; username: u; protocol: mixed (SOCKS5 + HTTP); auth: password; UDP: disabled\nXray is listening on port 23456.\n' \
    >"$S5_TEST_ROOT/ready.log"
t_run lifecycle_assert_ready_status "$S5_TEST_ROOT/ready.log" 23456
assert_eq "a ready status passes" 0 "$T_STATUS"
sed 's/^Xray is listening.*/the listen state of port 23456 could not be verified./' \
    "$S5_TEST_ROOT/ready.log" >"$S5_TEST_ROOT/unverified.log"
t_run lifecycle_assert_ready_status "$S5_TEST_ROOT/unverified.log" 23456
assert_ne "an unverified listener fails the ready status" 0 "$T_STATUS"

wait_calls=0
wait_ready=3
s5t_wait_predicate() { wait_calls=$((wait_calls + 1)); test "$wait_calls" -ge "$wait_ready"; }
sleep() { printf '%s\n' "$1" >>"$S5_TEST_ROOT/sleeps"; }
lifecycle_wait_until 3 0.2 s5t_wait_predicate
assert_eq "waiting succeeds on its final permitted attempt" 0 "$?"
assert_eq "the predicate runs in the caller shell" 3 "$wait_calls"
assert_eq "successful wait sleeps only between attempts" 2 "$(wc -l <"$S5_TEST_ROOT/sleeps" | tr -d '[:space:]')"
assert_eq "waiting preserves its requested interval" '0.2
0.2' "$(cat "$S5_TEST_ROOT/sleeps")"
wait_calls=0
wait_ready=4
: >"$S5_TEST_ROOT/sleeps"
lifecycle_wait_until 3 1 s5t_wait_predicate
assert_ne "an exhausted wait fails" 0 "$?"
assert_eq "waiting is bounded to the given attempts" 3 "$wait_calls"
assert_eq "an exhausted wait preserves the original full sleep budget" 3 "$(wc -l <"$S5_TEST_ROOT/sleeps" | tr -d '[:space:]')"
unset -f sleep

# The mixed gate waits until the launcher's ready marker appears or the engine
# exits, whichever comes first. Ending the wait is not the verdict: an exited
# engine ends it as early as a ready one, and only a live unready engine runs
# out the bounded attempts.
sleep 30 &
_re_live=$!
sh -c 'exit 0' &
_re_dead=$!
wait "$_re_dead"
: >"$S5_TEST_ROOT/engine.ready"
t_run lifecycle_ready_or_exited "$S5_TEST_ROOT/engine.ready" "$_re_live"
assert_eq "a live engine with an empty ready marker keeps waiting" 1 "$T_STATUS"
t_run lifecycle_ready_or_exited "$S5_TEST_ROOT/absent.ready" "$_re_live"
assert_eq "a live engine with no ready marker keeps waiting" 1 "$T_STATUS"
t_run lifecycle_wait_until 3 0 lifecycle_ready_or_exited "$S5_TEST_ROOT/engine.ready" "$_re_live"
assert_eq "a live unready engine exhausts the bounded wait" 1 "$T_STATUS"
t_run lifecycle_ready_or_exited "$S5_TEST_ROOT/engine.ready" "$_re_dead"
assert_eq "an exited engine ends the wait before the ready marker" 0 "$T_STATUS"
printf '23456\n' >"$S5_TEST_ROOT/engine.ready"
t_run lifecycle_ready_or_exited "$S5_TEST_ROOT/engine.ready" "$_re_live"
assert_eq "a published ready marker ends the wait" 0 "$T_STATUS"
kill "$_re_live" 2>/dev/null || true
wait "$_re_live" 2>/dev/null || true

t_run python3 - "$S5_REPO_ROOT" <<'PY'
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
for ready in ('yes', 'no'):
    with tempfile.TemporaryDirectory(prefix='s5-last-wait-') as work:
        # The target itself is replaced; the wait and the final check are the
        # shared helper's own.
        script = '''set -eu
work=$1
. "$2"
ready=$3
python3() { :; }
calls=0
sleep() {
    calls=$((calls + 1))
    if [ "$calls" = 50 ] && [ "$ready" = yes ]; then printf '23456\\n' >"$work/target.port"; fi
}
lifecycle_start_duplex_target "$work"
test "$target_port" = 23456
'''
        result = subprocess.run(shlex.split(os.environ.get('S5_TEST_SHELL', 'sh')) +
                                ['-c', script, 'wait-test', work,
                                 str(root / '.github/scripts/lifecycle-common.sh'), ready],
                                capture_output=True, text=True, timeout=10)
        if (result.returncode == 0) != (ready == 'yes'):
            raise AssertionError('final-sleep readiness was not independently checked: ' + result.stderr)
PY
assert_eq "gate final assertions observe readiness arriving during the final sleep" 0 "$T_STATUS"
if [ "$T_STATUS" -ne 0 ]; then printf '%s\n' "$T_OUT" >&2; fi

mkdir -p "$S5_TEST_ROOT/bin"
t_stub sudo <<'SUDO'
#!/bin/sh
printf '%s\n' "$*" >>"$S5_TEST_ROOT/cleanup-calls"
case "$1:$2" in
systemctl:show)
    if [ -f "$S5_TEST_ROOT/cleanup-unit-deleted" ]; then printf 'not-found\n';
    else printf '%s\n' "${S5_CLEANUP_LOAD_STATE:-not-found}"; fi ;;
systemctl:stop) [ "${S5_CLEANUP_FAIL:-}" != stop ] || exit 71 ;;
systemctl:is-active)
    case "${S5_CLEANUP_ACTIVE_STATE:-inactive}" in
    inactive) printf 'inactive\n'; exit 3 ;;
    unknown) printf 'unknown\n'; exit 4 ;;
    active) printf 'active\n'; exit 0 ;;
    esac ;;
systemctl:is-enabled) printf 'not-found\n'; exit 1 ;;
systemctl:disable|systemctl:daemon-reload) ;;
pgrep:-u)
    if [ "${S5_CLEANUP_PROCESS:-absent}" = active ] &&
        ! grep -q '^systemctl stop ' "$S5_TEST_ROOT/cleanup-calls"; then exit 0; fi
    exit 1 ;;
test:-e)
    [ "${S5_CLEANUP_SHAPE:-}" = unsafe-unit ] && [ "$3" = /etc/systemd/system/xray-socks5.service ] && exit 0
    [ "${S5_CLEANUP_SHAPE:-}" = residue ] && [ "$3" = /etc/xray-socks5 ] && exit 0
    exit 1 ;;
test:-L) exit 1 ;;
test:-d)
    [ "${S5_CLEANUP_SHAPE:-}" = residue ] && [ "$3" = /etc/xray-socks5 ] && exit 0
    exit 1 ;;
test:-f)
    [ "${S5_CLEANUP_SHAPE:-}" = unsafe-unit ] && [ "$3" = /etc/systemd/system/xray-socks5.service ] && exit 0
    [ "${S5_CLEANUP_SHAPE:-}" = residue ] && [ "$3" = /etc/xray-socks5/.s5new.planted ] && exit 0
    exit 1 ;;
stat:-c)
    [ "${S5_CLEANUP_SHAPE:-}" = unsafe-unit ] && printf 'root:root 666\n' && exit 0
    if [ "${S5_CLEANUP_SHAPE:-}" = residue ]; then
        case "$4" in
        /etc/xray-socks5) printf 'root:xray-socks5 750\n'; exit 0 ;;
        /etc/xray-socks5/.s5new.planted) printf 'root:root 666\n'; exit 0 ;;
        esac
    fi
    exit 1 ;;
find:/etc/xray-socks5)
    # The private directory's residue exists only as root sees it.
    if [ "${S5_CLEANUP_SHAPE:-}" = residue ] && [ "$8" = '.s5new.*' ]; then
        printf '/etc/xray-socks5/.s5new.planted\n'
    fi ;;
getent:passwd)
    [ -f "$S5_TEST_ROOT/cleanup-user-deleted" ] && exit 2
    case "${S5_CLEANUP_ACCOUNT:-absent}" in
    foreign) printf 'xray-socks5:x:900:900::/home/foreign:/bin/sh\n'; exit 0 ;;
    ordinary) printf 'xray-socks5:x:1900:1900::/nonexistent:/usr/sbin/nologin\n'; exit 0 ;;
    owned) printf 'xray-socks5:x:900:900::/nonexistent:/usr/sbin/nologin\n'; exit 0 ;;
    *) exit 2 ;;
    esac ;;
getent:group)
    [ -f "$S5_TEST_ROOT/cleanup-group-deleted" ] && exit 2
    case "${S5_CLEANUP_ACCOUNT:-absent}" in
    foreign|owned) printf 'xray-socks5:x:900:\n'; exit 0 ;;
    ordinary) printf 'xray-socks5:x:1900:\n'; exit 0 ;;
    *) exit 2 ;;
    esac ;;
userdel:*) : >"$S5_TEST_ROOT/cleanup-user-deleted" ;;
groupdel:*) : >"$S5_TEST_ROOT/cleanup-group-deleted" ;;
rm:*)
    [ "${3:-}" != /etc/systemd/system/xray-socks5.service ] || : >"$S5_TEST_ROOT/cleanup-unit-deleted" ;;
*) ;;
esac
exit 0
SUDO
for cleanup_failure in none stop; do
    rm -f "$S5_TEST_ROOT/cleanup-user-deleted" "$S5_TEST_ROOT/cleanup-group-deleted" \
        "$S5_TEST_ROOT/cleanup-unit-deleted"
    : >"$S5_TEST_ROOT/cleanup-calls"
    # Split a configured multiword shell such as busybox sh.
    _cleanup_load=not-found
    [ "$cleanup_failure" != stop ] || _cleanup_load=loaded
# shellcheck disable=SC2086
t_run env PATH="$S5_TEST_ROOT/bin:$PATH" S5_CLEANUP_FAIL="$cleanup_failure" \
        S5_CLEANUP_LOAD_STATE="$_cleanup_load" \
        ${S5_TEST_SHELL:-sh} "$S5_REPO_ROOT/.github/scripts/remove-xray-namespace.sh"
    if [ "$cleanup_failure" = none ]; then
        assert_eq "cleanup tolerates a genuinely absent namespace" 0 "$T_STATUS"
        assert_contains "cleanup verifies the manager namespace is absent" \
            'systemctl show xray-socks5.service -p LoadState --value' \
            "$(cat "$S5_TEST_ROOT/cleanup-calls")"
    else
        assert_eq "cleanup propagates stop failure" 71 "$T_STATUS"
        assert_not_contains "stop failure preserves files and accounts" 'rm -rf' \
            "$(cat "$S5_TEST_ROOT/cleanup-calls")"
        assert_not_contains "stop failure preserves accounts" userdel \
            "$(cat "$S5_TEST_ROOT/cleanup-calls")"
    fi
done

: >"$S5_TEST_ROOT/cleanup-calls"
# shellcheck disable=SC2086
t_run env PATH="$S5_TEST_ROOT/bin:$PATH" S5_CLEANUP_LOAD_STATE=loaded \
    S5_CLEANUP_ACTIVE_STATE=unknown ${S5_TEST_SHELL:-sh} \
    "$S5_REPO_ROOT/.github/scripts/remove-xray-namespace.sh"
assert_ne "cleanup rejects an unobservable stopped state" 0 "$T_STATUS"
assert_not_contains "unknown stopped state preserves files" 'rm -f /etc/systemd/system' \
    "$(cat "$S5_TEST_ROOT/cleanup-calls")"

: >"$S5_TEST_ROOT/cleanup-calls"
# shellcheck disable=SC2086
t_run env PATH="$S5_TEST_ROOT/bin:$PATH" S5_CLEANUP_LOAD_STATE=not-found \
    S5_CLEANUP_ACCOUNT=foreign ${S5_TEST_SHELL:-sh} \
    "$S5_REPO_ROOT/.github/scripts/remove-xray-namespace.sh"
assert_ne "cleanup refuses a foreign same-named account" 0 "$T_STATUS"
assert_not_contains "foreign account refusal precedes file deletion" 'rm -rf' \
    "$(cat "$S5_TEST_ROOT/cleanup-calls")"

: >"$S5_TEST_ROOT/cleanup-calls"
# shellcheck disable=SC2086
t_run env PATH="$S5_TEST_ROOT/bin:$PATH" S5_CLEANUP_LOAD_STATE=not-found \
    S5_CLEANUP_ACCOUNT=ordinary ${S5_TEST_SHELL:-sh} \
    "$S5_REPO_ROOT/.github/scripts/remove-xray-namespace.sh"
assert_ne "cleanup refuses a non-system same-named account" 0 "$T_STATUS"
assert_not_contains "ordinary account refusal precedes file deletion" 'rm -rf' \
    "$(cat "$S5_TEST_ROOT/cleanup-calls")"

: >"$S5_TEST_ROOT/cleanup-calls"
# shellcheck disable=SC2086
t_run env PATH="$S5_TEST_ROOT/bin:$PATH" S5_CLEANUP_LOAD_STATE=not-found \
    S5_CLEANUP_SHAPE=unsafe-unit ${S5_TEST_SHELL:-sh} \
    "$S5_REPO_ROOT/.github/scripts/remove-xray-namespace.sh"
assert_ne "cleanup refuses a service unit mode drift" 0 "$T_STATUS"
assert_not_contains "unit mode refusal precedes file deletion" 'rm -f /etc/systemd/system' \
    "$(cat "$S5_TEST_ROOT/cleanup-calls")"

# Residue in a private directory is enumerated as root; the unprivileged glob
# saw nothing there, so an unsafe temporary passed unchecked.
: >"$S5_TEST_ROOT/cleanup-calls"
# shellcheck disable=SC2086
t_run env PATH="$S5_TEST_ROOT/bin:$PATH" S5_CLEANUP_LOAD_STATE=not-found \
    S5_CLEANUP_SHAPE=residue ${S5_TEST_SHELL:-sh} \
    "$S5_REPO_ROOT/.github/scripts/remove-xray-namespace.sh"
assert_ne "cleanup refuses unsafe residue in a private directory" 0 "$T_STATUS"
assert_contains "the refusal names the planted residue" \
    'unsafe ownership or mode on /etc/xray-socks5/.s5new.planted' "$T_OUT"
assert_not_contains "residue refusal precedes file deletion" 'rm -rf' \
    "$(cat "$S5_TEST_ROOT/cleanup-calls")"

rm -f "$S5_TEST_ROOT/cleanup-user-deleted" "$S5_TEST_ROOT/cleanup-group-deleted" \
        "$S5_TEST_ROOT/cleanup-unit-deleted"
: >"$S5_TEST_ROOT/cleanup-calls"
    # shellcheck disable=SC2086
    t_run env PATH="$S5_TEST_ROOT/bin:$PATH" S5_CLEANUP_LOAD_STATE=loaded \
    S5_CLEANUP_ACCOUNT=owned S5_CLEANUP_PROCESS=active ${S5_TEST_SHELL:-sh} \
    "$S5_REPO_ROOT/.github/scripts/remove-xray-namespace.sh"
assert_eq "cleanup stops an owned service before checking orphan processes" 0 "$T_STATUS"
_cleanup_stop_line=$(grep -n '^systemctl stop ' "$S5_TEST_ROOT/cleanup-calls" | cut -d: -f1)
_cleanup_pgrep_line=$(grep -n '^pgrep -u ' "$S5_TEST_ROOT/cleanup-calls" | cut -d: -f1)
if [ -n "$_cleanup_stop_line" ] && [ -n "$_cleanup_pgrep_line" ] &&
    [ "$_cleanup_stop_line" -lt "$_cleanup_pgrep_line" ]; then t_ok; else t_bad "process check ran before stop"; fi

t_run python3 - "$S5_REPO_ROOT/.github/scripts/memory-peak-check.py" <<'PY'
import contextlib
import io
import os
from pathlib import Path
import runpy
import sys
from unittest.mock import patch

script = sys.argv[1]
for arguments in (["--real-cgroup"], ["--worker", "/synthetic-cgroup"]):
    for ci, uid in (("false", 0), ("true", 1000)):
        output = io.StringIO()
        with patch.dict(os.environ, {"GITHUB_ACTIONS": ci}), patch("os.geteuid", return_value=uid), \
                patch.object(sys, "argv", [script, *arguments]), contextlib.redirect_stderr(output), \
                patch.object(Path, "mkdir", side_effect=AssertionError("native cgroup creation reached")), \
                patch.object(Path, "write_text", side_effect=AssertionError("native cgroup write reached")):
            try:
                runpy.run_path(script, run_name="__main__")
            except SystemExit as error:
                if error.code != 1 or "GitHub Actions" not in output.getvalue():
                    raise AssertionError("peak experiment did not report its CI guard") from error
            else:
                raise AssertionError("peak experiment accepted an unsafe environment")
PY
assert_eq "both peak experiment entrypoints refuse non-CI or non-root before native writes" 0 "$T_STATUS"
if [ "$T_STATUS" -ne 0 ]; then printf '%s\n' "$T_OUT" >&2; fi

t_run python3 "$S5_REPO_ROOT/tests/protocol/ci_cleanup_selftest.py" "$S5_REPO_ROOT"
assert_eq "lifecycle target stops and is reaped on every exit path" 0 "$T_STATUS"
if [ "$T_STATUS" -ne 0 ]; then printf '%s\n' "$T_OUT" >&2; fi

t_run python3 "$S5_REPO_ROOT/tests/protocol/memory_sampler_selftest.py" "$S5_REPO_ROOT"
assert_eq "sampler keeps reset state across high and low workloads" 0 "$T_STATUS"
if [ "$T_STATUS" -ne 0 ]; then printf '%s\n' "$T_OUT" >&2; fi

t_run python3 "$S5_REPO_ROOT/tests/protocol/memory_compare_selftest.py" "$S5_REPO_ROOT"
assert_eq "memory comparison measures owned services and rejects inconclusive evidence" 0 "$T_STATUS"
if [ "$T_STATUS" -ne 0 ]; then printf '%s\n' "$T_OUT" >&2; fi

t_run python3 "$S5_REPO_ROOT/tests/lib/arity_audit_regression.py"
assert_eq "arity audit rejects stale CI and protocol callers" 0 "$T_STATUS"
if [ "$T_STATUS" -ne 0 ]; then printf '%s\n' "$T_OUT" >&2; fi

t_summary
