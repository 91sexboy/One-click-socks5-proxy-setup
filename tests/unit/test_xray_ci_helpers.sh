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

t_run python3 - "$S5_REPO_ROOT" <<'PY'
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
for backend in ('systemd', 'alpine'):
    lines = (root / '.github/scripts' / (backend + '-lifecycle.sh')).read_text().splitlines()
    waits = [index for index, line in enumerate(lines) if line.startswith('lifecycle_wait_until 50 ')]
    if len(waits) != 1:
        raise AssertionError('expected one target readiness wait')
    index = waits[0]
    for ready in ('yes', 'no'):
        with tempfile.TemporaryDirectory(prefix='s5-last-wait-') as work:
            script = '''set -eu
work=$1
. "$2"
ready=$3
calls=0
sleep() {
    calls=$((calls + 1))
    if [ "$calls" = 50 ] && [ "$ready" = yes ]; then printf '23456\\n' >"$work/target.port"; fi
}
''' + '\n'.join(lines[index:index + 2]) + '\n'
            result = subprocess.run(shlex.split(os.environ.get('S5_TEST_SHELL', 'sh')) +
                                    ['-c', script, 'wait-test', work,
                                     str(root / '.github/scripts/lifecycle-common.sh'), ready],
                                    capture_output=True, text=True, timeout=10)
            if (result.returncode == 0) != (ready == 'yes'):
                raise AssertionError(backend + ': final-sleep readiness was not independently checked')
PY
assert_eq "gate final assertions observe readiness arriving during the final sleep" 0 "$T_STATUS"
if [ "$T_STATUS" -ne 0 ]; then printf '%s\n' "$T_OUT" >&2; fi

mkdir -p "$S5_TEST_ROOT/bin"
t_stub sudo <<'SUDO'
#!/bin/sh
printf '%s\n' "$*" >>"$S5_TEST_ROOT/cleanup-calls"
case "$1:$2" in
systemctl:show) printf '%s\n' "${S5_CLEANUP_LOAD_STATE:-not-found}" ;;
systemctl:stop) [ "${S5_CLEANUP_FAIL:-}" != stop ] || exit 71 ;;
systemctl:is-active) exit 3 ;;
systemctl:disable|systemctl:daemon-reload) ;;
test:-e|test:-L) exit 1 ;;
getent:passwd|getent:group) exit 2 ;;
rm:*) ;;
*) ;;
esac
exit 0
SUDO
for cleanup_failure in none stop; do
    : >"$S5_TEST_ROOT/cleanup-calls"
    # Split a configured multiword shell such as busybox sh.
    # shellcheck disable=SC2086
    _cleanup_load=not-found
    [ "$cleanup_failure" != stop ] || _cleanup_load=loaded
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
