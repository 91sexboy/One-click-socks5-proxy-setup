#!/bin/sh
# tests/unit/test_ci_lint.sh - third-round regressions found by the independent
# reviewer.
#
# F8 (HIGH)  The SOCKS4 doc-lint allowlist in .github/workflows/ci.yml had
#            drifted out of step with the identical guard in test_docs.sh. The
#            local suite was green while the CI lint job would have exited 1 on
#            README.md's own "a SOCKS4-family success ... fails the job" line.
#            This test runs BOTH pipelines and requires them to agree.
#
# F9 (MED)   The systemd-integration job redacted its install log with
#            `sed -e "s/$(cat pass)/***/g"`, which places the plaintext password
#            in sed's argv, visible to `ps`. The invariant claimed two lines
#            above is "never enters argv".

S5T_NAME=test_ci_lint
. "${S5_REPO_ROOT}/tests/lib/assert.sh"

R="${S5_REPO_ROOT}"
CI="$R/.github/workflows/ci.yml"

# ==========================================================================
# F8: public operator documentation must contain no legacy SOCKS-family token.
# The CI gate is deliberately allowlist-free: any occurrence is a failure.
# ==========================================================================
assert_eq "the real README contains no legacy family token" 0 \
    "$(grep -rciE 'socks4' "$R/README.md" || true)"
if grep -F "grep -rniE 'socks4' README.md" "$CI" >/dev/null &&
    ! grep -F "grep -rniE 'socks4' README.md |" "$CI" >/dev/null; then
    t_ok
else
    t_bad "CI must reject every README SOCKS4 occurrence without an allowlist"
fi
if grep -F 'grep -viE' "$CI" | grep -qi 'socks4'; then
    t_bad "the README legacy-family gate must not carry an allowlist"
else
    t_ok
fi

SCRATCH=$(mktemp -d)
cp "$R/README.md" "$SCRATCH/R.md"
printf '\nYou can also point legacy clients at socks4://host:port for convenience.\n' >>"$SCRATCH/R.md"
scratch_hits=$(grep -rniE 'socks4' "$SCRATCH/R.md" || true)
assert_contains "the strict gate catches a legacy-family advertisement" \
    "socks4://" "$scratch_hits"
rm -rf "$SCRATCH"

# ==========================================================================
# F9: no CI step may place a credential in a command's argv.
# ==========================================================================
# A command substitution that reads the password file inside a command line is
# the argv-leak shape. Assignments of the form VAR=$(cat pass) are a separate
# (already-fixed) leak and are covered in test_audit2.sh.
if grep -nE '(sed|awk|grep|printf|echo)[^|]*\$\(cat "?\$SECRETS/pass' "$CI"; then
    t_bad "a CI command receives the password through argv (visible to ps)"
else
    t_ok
fi
# More generally: the password file must only ever be read into a redirect, a
# pipe, or a variable assignment - never interpolated into an argument list.
if grep -nE '"s/\$\(cat' "$CI"; then
    t_bad "a CI sed expression interpolates the password into argv"
else
    t_ok
fi
# The OpenRC job must capture and redact the installer output too: its success
# summary contains the password. A direct `sh socks5.sh install < answers` leaks
# it into durable GitHub Actions output.
if grep -nE 'sh socks5\.sh install <[^>]*$' "$CI" | grep -v 'install.log'; then
    t_bad "OpenRC must not stream installer output containing the password"
else
    t_ok
fi
# Per-job scope, not a whole-file search. The three assertions this replaced
# looked at the entire workflow, so the systemd job's text satisfied them and
# deleting OpenRC's redaction or its cleanup checks left the test green.
# Comments are stripped so prose describing a step cannot stand in for the step.
ci_job_block() { # <job-name> -> that job's code lines only
    awk -v want="  $1:" '
        $0 == want { inj = 1; next }
        inj && /^  [a-z][a-z0-9-]*:$/ { inj = 0 }
        inj && !/^[[:space:]]*#/ { print }
    ' "$CI"
}

# Every job that performs a real service install must capture the installer
# output and redact it, because the success summary contains the password.
for _job in systemd-integration openrc-integration distro-systemd-integration; do
    _blk=$(ci_job_block "$_job")
    if [ "$_job" = openrc-integration ]; then
        _blk="$_blk
$(cat "$R/.github/scripts/run-openrc-memory-gate.sh")"
    fi
    assert_ne "$_job: the job block was located" "" "$_blk"
    assert_contains "$_job captures the installer output to a file" \
        'install.log' "$_blk"
    assert_contains "$_job redacts through a sed script file" \
        'redact.sed' "$_blk"
    if printf '%s\n' "$_blk" | grep -qE 'socks5\.sh install <[^>]*$'; then
        t_bad "$_job streams unredacted installer output containing the password"
    else
        t_ok
    fi
    # ...and each must prove its own cleanup, not rely on another job's.
    assert_contains "$_job cleanup checks the config directory" \
        "/etc/socks5-manager" "$_blk"
    assert_contains "$_job cleanup checks the state directory" \
        "/var/lib/socks5-manager" "$_blk"
    assert_contains "$_job cleanup checks the install prefix" \
        "/usr/local/libexec/socks5-manager" "$_blk"
    assert_contains "$_job cleanup checks the service account" \
        "id socks5proxy" "$_blk"
    assert_contains "$_job cleanup checks the service group" \
        "getent group socks5proxy" "$_blk"
done

# All four promised OS families must have a REAL service-install lifecycle. The
# The compatibility matrix loads one published asset; the protocol job runs the engine directly
# without installing a service, so neither can stand in for this.
assert_contains "Ubuntu has a real systemd lifecycle" \
    "ubuntu-24.04" "$(ci_job_block systemd-integration)"
assert_contains "Alpine has a real OpenRC lifecycle" \
    "alpine:3." "$(ci_job_block openrc-integration)"

# The OpenRC workflow delegates the inner lifecycle to one POSIX helper, so the
# workflow itself has no fragile single-quoted command body to audit.
_openrc_raw_block=$(awk '
    $0 == "  openrc-integration:" { in_job = 1; next }
    in_job && /^  [a-z][a-z0-9-]*:$/ { exit }
    in_job { print }
' "$CI")
assert_contains "OpenRC workflow invokes the reviewed helper" \
    'run-openrc-memory-gate.sh' "$_openrc_raw_block"
_openrc_helper=$(cat "$R/.github/scripts/run-openrc-memory-gate.sh")
_openrc_init_line=$(printf '%s\n' "$_openrc_helper" |
    grep -n 'rc-status -a' | head -n 1 | cut -d: -f1)
_openrc_install_line=$(printf '%s\n' "$_openrc_helper" |
    grep -n 'socks5\.sh install' | head -n 1 | cut -d: -f1)
assert_ne "OpenRC runtime initialization is present" "" "$_openrc_init_line"
if [ -n "$_openrc_init_line" ] && [ -n "$_openrc_install_line" ] &&
    [ "$_openrc_init_line" -lt "$_openrc_install_line" ]; then
    t_ok
else
    t_bad "OpenRC runtime initialization must precede the installer"
fi

_distro=$(ci_job_block distro-systemd-integration)
assert_contains "Debian has a real systemd lifecycle" "debian:12" "$_distro"
assert_contains "CentOS Stream has a real systemd lifecycle" "centos:stream9" "$_distro"
assert_contains "the distro lifecycle boots a real init as PID 1" "/sbin/init" "$_distro"
assert_contains "the distro lifecycle exposes the host cgroup hierarchy to systemd" \
    '--cgroupns=host' "$_distro"
assert_contains "and waits for the manager before installing" \
    "is-system-running" "$_distro"

# `show` deliberately refuses unless stdout is a terminal, so piping it into grep
# fails. It must be given a pty and its output kept out of the job log.
_sysd=$(ci_job_block systemd-integration)
if printf '%s\n' "$_sysd" | grep -qE 'socks5\.sh show[[:space:]]*\|'; then
    t_bad "show must not be piped: it refuses to disclose unless stdout is a terminal"
else
    t_ok
fi
assert_contains "show is run under a pty" "script -qec" "$_sysd"

# v1 never changes the firewall, so every lifecycle job must assert that no rule
# was created rather than assuming it.
for _job in systemd-integration distro-systemd-integration; do
    assert_contains "$_job asserts no firewall rule was created" \
        "must not" "$(ci_job_block "$_job")"
done
# Both protocol drivers must reject symlinked or non-0600 PASSFILE paths.
for drv in run_protocol.sh acl_resolution.sh start_engine.sh; do
    assert_contains "$drv rejects symlinked PASSFILE" \
        'PASSFILE must be a regular non-symlink file' "$(cat "$R/tests/protocol/$drv")"
    assert_contains "$drv enforces PASSFILE mode" \
        'PASSFILE must have mode 0600' "$(cat "$R/tests/protocol/$drv")"
done


# ==========================================================================
# F10: a SOCKS4 curl probe that fails for an unrelated reason must not be
# reported as a rejection without qualification.
# ==========================================================================
proto=$(cat "$R/tests/protocol/run_protocol.sh")
assert_contains "the SOCKS4 curl case distinguishes exit codes" "S5_CURL_PROXY_ERR" "$proto"
assert_contains "and says so when the result is only indicative" "indicative" "$proto"
# The load-bearing probe cases must still treat ERROR as a failure.
assert_contains "probe ERROR is still a failure for case 4b" \
    'bad "4b probe: inconclusive' "$proto"
assert_contains "probe ERROR is still a failure for case 5b" \
    'bad "5b probe: inconclusive' "$proto"

# ==========================================================================
# F11: a truncated SOCKS5 GRANT reply must not read as a refusal.
# ==========================================================================
probe=$(cat "$R/tests/protocol/socks_probe.py")
assert_contains "the probe has a distinct truncated-reply error" "TruncatedReply" "$probe"
assert_contains "and it is documented as an ERROR, not a refusal" \
    "truncated GRANT" "$probe"
# The reply code must only be returned AFTER the address tail has been read,
# and a truncated tail must raise rather than fall through to a return.
tailread=$(printf '%s\n' "$probe" | grep -n 'raise TruncatedReply' | head -n 1 | cut -d: -f1)
retcode=$(printf '%s\n' "$probe" | grep -n 'return head\[1\]' | head -n 1 | cut -d: -f1)
if [ -n "$tailread" ] && [ -n "$retcode" ] && [ "$tailread" -lt "$retcode" ]; then
    t_ok
else
    t_bad "the reply code must not be returned before the tail read can raise"
fi
# Both SOCKS5 modes must handle TruncatedReply, and neither may map it to REFUSED.
handlers=$(printf '%s\n' "$probe" | grep -c 'except TruncatedReply')
if [ "$handlers" -ge 3 ]; then
    t_ok
else
    t_bad "every SOCKS5 mode plus the top level must handle TruncatedReply (found $handlers)"
fi
if printf '%s\n' "$probe" | grep -A1 'except TruncatedReply' | grep -q 'return REFUSED'; then
    t_bad "a truncated reply must never be reported as a refusal"
else
    t_ok
fi

# ==========================================================================
# F13: the lint job's own self-checks must pass against the real workflow.
#
# The lint job greps its own file. A pattern that matches the guard's own text
# would make the job fail on its own source - the same drift class as F8. Run
# both self-checks verbatim here so a local run catches it.
# ==========================================================================
# Extract the patterns the lint job ACTUALLY uses, so this test cannot pass by
# using a different (correct) pattern of its own.
jobs_pat=$(grep -F 'jobs=$(awk' "$CI" | sed -e "s/.*awk '//" -e "s/' .github.*//")
tos_pat=$(grep -F 'tos=$(grep -c' "$CI" | sed -e "s/.*grep -c '//" -e "s/' .github.*//")
assert_ne "the lint job-count pattern was found" "" "$jobs_pat"
assert_ne "the lint timeout-count pattern was found" "" "$tos_pat"

lint_jobs=$(awk "$jobs_pat" "$CI")
lint_tos=$(grep -c "$tos_pat" "$CI")
assert_eq "the lint job's OWN timeout self-check balances (jobs == timeouts)" \
    "$lint_jobs" "$lint_tos"
if [ "$lint_jobs" -ge 7 ]; then t_ok; else t_bad "expected at least 7 jobs, counted $lint_jobs"; fi

# The timeout pattern must be anchored to the JOB level -- a key at exactly four
# spaces -- not to "any indentation". `^[[:space:]]*timeout-minutes:` also counts
# a step-level timeout, so one added inside a step would offset a job that has
# none: the two totals balance and the guard passes with a job left unbounded.
case "$tos_pat" in
'^    timeout-minutes:')
    t_ok
    ;;
*)
    t_bad "the timeout pattern must match job-level keys only: [$tos_pat]"
    ;;
esac
# ...and prove the anchoring does the work, by injecting a step-level timeout
# into a scratch copy. The real pattern must ignore it; the permissive form the
# anchor replaced must not.
ANCHOR=$(mktemp -d)
awk '{print} /^      - name: shellcheck$/{print "        timeout-minutes: 5"}' \
    "$CI" >"$ANCHOR/ci.yml"
injected=$(grep -c 'timeout-minutes' "$ANCHOR/ci.yml")
base=$(grep -c 'timeout-minutes' "$CI")
assert_eq "the scratch copy really has one extra timeout key" \
    "$((base + 1))" "$injected"
assert_eq "the job-level pattern ignores a step-level timeout" \
    "$lint_tos" "$(grep -c "$tos_pat" "$ANCHOR/ci.yml")"
assert_ne "the any-indent pattern it replaced would have counted it" \
    "$lint_tos" "$(grep -c '^[[:space:]]*timeout-minutes:' "$ANCHOR/ci.yml")"
rm -rf "$ANCHOR"

# Per-job structural scan, with no optional dependency. This is the oracle that
# the two counts above cannot be: they only compare totals, so two timeouts on
# one job plus none on another still balances. Written in awk so it always runs
# -- when this was PyYAML-only it was skipped on any machine without the module,
# and a skipped check is not a check.
scan=$(awk '
    /^jobs:/ { injobs = 1; next }
    injobs && /^[^ ]/ { injobs = 0 }
    injobs && /^  [a-z][a-z0-9-]*: *$/ { cur = $1; n++; seen[cur] = 0; next }
    injobs && cur != "" && /^    timeout-minutes:/ { seen[cur] = 1 }
    END {
        miss = ""
        for (j in seen) { if (seen[j] == 0) { miss = miss " " j } }
        printf "%d%s\n", n + 0, miss
    }
' "$CI")
scan_jobs=$(printf '%s' "$scan" | cut -d' ' -f1)
scan_miss=$(printf '%s' "$scan" | sed 's/^[0-9]*//')
assert_eq "the per-job scan agrees on the job count" "$lint_jobs" "$scan_jobs"
assert_eq "every job declares a job-level timeout" "" "$scan_miss"

# The scan has to be able to fail: a job with its timeout removed must be named.
NOTO=$(mktemp -d)
awk '!(/^    timeout-minutes: 20$/ && ++seen == 1)' "$CI" >"$NOTO/ci.yml"
mutscan=$(awk '
    /^jobs:/ { injobs = 1; next }
    injobs && /^[^ ]/ { injobs = 0 }
    injobs && /^  [a-z][a-z0-9-]*: *$/ { cur = $1; n++; seen[cur] = 0; next }
    injobs && cur != "" && /^    timeout-minutes:/ { seen[cur] = 1 }
    END {
        miss = ""
        for (j in seen) { if (seen[j] == 0) { miss = miss " " j } }
        printf "%d%s\n", n + 0, miss
    }
' "$NOTO/ci.yml")
assert_contains "removing a job timeout is detected and the job named" \
    "lint:" "$mutscan"
rm -rf "$NOTO"

# The YAML parse stays as a second, independent cross-check where PyYAML exists.
# It is no longer load-bearing locally; in CI it is mandatory (python3-yaml is
# installed by the lint job) and the workflow itself runs it.
#
# Comment lines are stripped first. Both facts below are also *described* in a
# ci.yml comment, so a whole-file search is satisfied by the prose and survives
# deleting the thing it describes -- which is how the first version of this
# check missed the mutation that dropped the install.
ci_code() { grep -v '^[[:space:]]*#' "$CI"; }
code_has_ci() { # <desc> <fixed-string>
    if ci_code | grep -qF -- "$2"; then t_ok; else t_bad "$1 (no code line in ci.yml: $2)"; fi
}
code_has_ci "the lint job installs PyYAML rather than assuming it" \
    "install -y python3-yaml"
# The linter must be pinned, not whatever apt ships: a distro version bump
# changes which findings fire, so local verification could never reproduce a
# lint failure. The pin is the checksummed upstream tarball.
code_has_ci "shellcheck comes from a pinned upstream tarball, not apt" \
    "shellcheck-v0.10.0.linux.x86_64.tar.xz"
code_has_ci "the shellcheck tarball is verified against a sha256" \
    "sha256sum -c"
# Production stays exclusion-free: its invocation is pinned verbatim, so an
# -e flag added where a real defect could hide fails here instead of passing
# silently in CI.
if ci_code | sed 's/^[[:space:]]*//' | grep -qxF 'shellcheck -s sh socks5.sh'; then
    t_ok
else
    t_bad "production must be linted by exactly 'shellcheck -s sh socks5.sh', no -e"
fi
# The test corpora carry targeted exclusions, and ONLY those: the invocation
# lines are pinned verbatim too, so widening an exclusion is a deliberate edit
# that this test forces someone to read, not a silent CI-only change.
_n=0
ci_code | sed 's/^[[:space:]]*//' | grep -qxF \
    'shellcheck -s sh -e SC2317,SC2034,SC2016 tests/run.sh tests/lib/*.sh tests/unit/*.sh' \
    && _n=$((_n + 1))
ci_code | sed 's/^[[:space:]]*//' | grep -qxF \
    'shellcheck -s sh -e SC2317,SC2034,SC2016 tests/protocol/*.sh' \
    && _n=$((_n + 1))
assert_eq "both test-corpus invocations carry exactly the targeted -e set" 2 "$_n"
code_has_ci "and the lint job runs the parse itself" "jobs without timeout-minutes"

if command -v python3 >/dev/null 2>&1; then
    parsed=$(python3 - "$CI" <<'PYEOF'
import sys
try:
    import yaml
except ImportError:
    print("skip"); raise SystemExit(0)
d = yaml.safe_load(open(sys.argv[1]))
jobs = d["jobs"]
missing = [n for n, j in jobs.items() if not j.get("timeout-minutes")]
print("%d %d %s" % (len(jobs), len(jobs) - len(missing), ",".join(missing) or "none"))
PYEOF
)
    if [ "$parsed" = "skip" ]; then
        t_skip "YAML cross-check of job timeouts" "PyYAML is not installed"
    else
        pjobs=$(printf '%s' "$parsed" | cut -d' ' -f1)
        pwith=$(printf '%s' "$parsed" | cut -d' ' -f2)
        pmiss=$(printf '%s' "$parsed" | cut -d' ' -f3)
        assert_eq "the parser agrees on the job count" "$lint_jobs" "$pjobs"
        assert_eq "every parsed job has a timeout" "$pjobs" "$pwith"
        assert_eq "no job is missing a timeout" "none" "$pmiss"
    fi
else
    t_skip "YAML cross-check of job timeouts" "python3 is not available"
fi

# The continue-on-error guard must likewise not match its own text.
coe=$(grep -cE '^[[:space:]]+continue-on-error[[:space:]]*:' "$CI")
assert_eq "no job declares continue-on-error" 0 "$coe"

# =========================================================================
# Round 16 T16: the lifecycle answer streams feed the language selector, use
# the [Y/n] default-yes confirmation, and queue the password EXACTLY once.
# =========================================================================

# Each lifecycle job's install answer builder must concatenate the password
# file exactly once. Scoped per job block so a new job cannot borrow another's
# compliance.
for _job in systemd-integration openrc-integration distro-systemd-integration; do
    _blk=$(ci_job_block "$_job")
    if [ "$_job" = openrc-integration ]; then
        _blk="$_blk
$(cat "$R/.github/scripts/run-openrc-memory-gate.sh")"
    fi
    # The ANSWERS builder must read the password exactly once. Scope to the lines
    # that WRITE the answers file, so the redaction builder (which legitimately
    # reads the password) and the PASSFILE handoff cannot mask a doubled entry.
    _anslines=$(printf '%s\n' "$_blk" |
        grep 'SECRETS/answers' | grep -v 'chmod\|install <\|cat >\|< "\$SECRETS/answers"\|<"\$SECRETS/answers"' || true)
    _anspw=$(printf '%s\n' "$_anslines" | grep -c 'SECRETS/pass' || true)
    assert_eq "$_job concatenates the password exactly once into answers" \
        1 "$_anspw"
    # The language answer precedes the confirmation in every install stream:
    # blank (Chinese default), explicit 2 (English) or invalid-then-2 (retry).
    # The answers-builder lines carry the evidence.
    if printf '%s\n' "$_anslines" | grep -qF "printf '\ny" ||
        printf '%s\n' "$_anslines" | grep -qF '2\ny' ||
        printf '%s\n' "$_anslines" | grep -qF '9\n2\ny'; then
        t_ok
    else
        t_bad "$_job install answers must begin with a language selection"
    fi
done

# At least one cell exercises the invalid-language retry (openrc 3.20).
if grep -q 'printf "9' "$CI" || grep -q "printf '9" "$CI"; then
    t_ok
else
    t_bad "no CI cell exercises the invalid-language retry"
fi
# At least one cell exercises the blank-default Chinese selection: an answers
# builder whose stream opens with a bare newline before the y confirmation.
if grep "SECRETS/answers" "$CI" | grep -v 'chmod\|install <\|cat >' | grep -qF "printf '\ny"; then
    t_ok
else
    t_bad "no CI cell exercises the blank (Chinese default) language selection"
fi
# Direct lifecycle commands all feed a language answer: no naked invocation
# reaches the selector's stdin without one.
if grep -nE '(sudo )?sh (socks5|/src/socks5)\.sh (status|restart|uninstall)( |$)' "$CI" |
    grep -vE 'printf|run-systemd-memory-gate|s5-(status|restart|uninstall)'; then
    t_bad "a direct lifecycle command reaches stdin without a language answer"
else
    t_ok
fi
if grep -nE 'docker exec "\$CID" sh /src/socks5\.sh (status|restart)$' "$CI"; then
    t_bad "a container lifecycle command reaches stdin without a language answer"
else
    t_ok
fi

# =========================================================================
# Round 17/19: real-host post-install audit and in-place reconfiguration are
# present in applicable lifecycles. The helper owns the security-sensitive
# details once; each job must invoke it explicitly so one job cannot borrow
# another's proof.
# =========================================================================
post_audit="$R/tests/protocol/post_install_audit.sh"
assert_file_exists "post-install audit helper exists" "$post_audit"
post_code=$(grep -v '^[[:space:]]*#' "$post_audit")
for required in \
    "stat -c '%U:%G %a'" \
    '/usr/local/libexec/$project/3proxy' \
    '/etc/$project' \
    '/var/lib/$project/state' \
    '/etc/systemd/system/$project.service' \
    '/etc/init.d/$project' \
    '/nonexistent' \
    '/etc/shadow' \
    '*/nologin | */false' \
    'grep -F -l -f' \
    '/var/log' \
    '.bash_history' \
    '.ash_history' \
    '.sh_history' \
    '.zsh_history' \
    'cannot read shell history' \
    'journalctl --no-pager -o cat' \
    'cannot read the systemd journal' \
    's5-ci-secret-probe' \
    'rm -f "$probe"'; do
    assert_contains "post-install audit carries $required" "$required" "$post_code"
done
assert_not_contains "post-install audit never prints matching secret lines" \
    'grep -F -n' "$post_code"

for _job in systemd-integration openrc-integration distro-systemd-integration; do
    _blk=$(ci_job_block "$_job")
    if [ "$_job" = openrc-integration ]; then
        _blk="$_blk
$(cat "$R/.github/scripts/run-openrc-memory-gate.sh")"
    fi
    assert_contains "$_job runs the real post-install audit" \
        'tests/protocol/post_install_audit.sh' "$_blk"
done
openrc_block="$(ci_job_block openrc-integration)
$(cat "$R/.github/scripts/run-openrc-memory-gate.sh")"
for required in 'command -v logger' 'command -v syslogd' 'openrc logger probe'; do
    assert_contains "OpenRC verifies its logger path with $required" "$required" "$openrc_block"
done
systemd_block=$(ci_job_block systemd-integration)
_second_installs=$(printf '%s\n' "$systemd_block" | grep -c 'socks5.sh install' || true)
assert_eq "systemd integration invokes install twice in one existing cell" 2 "$_second_installs"
for required in 'sha256sum --check "$SECRETS/bin.before"' \
    'sha256sum --check "$SECRETS/unit.before"' \
    'reconfigure-transaction' 'getent passwd socks5proxy' \
    'getent group socks5proxy' 'systemctl list-unit-files --no-legend'; do
    assert_contains "systemd reconfiguration carries $required" "$required" "$systemd_block"
done
_openrc=$(ci_job_block openrc-integration)
_openrc_helper=$(cat "$R/.github/scripts/run-openrc-memory-gate.sh")
assert_contains "OpenRC enforces the 128 MiB container limit" \
    '--memory=128m --memory-swap=128m' "$_openrc"
assert_contains "OpenRC records target memory peak" 'memory.peak' "$_openrc_helper"
assert_contains "OpenRC performs a real in-place update" 'update.answers' "$_openrc_helper"
assert_contains "OpenRC checks transaction cleanup" 'reconfigure-transaction' "$_openrc_helper"

# The lifecycle stages are independent evidence and must remain in strict order.
_openrc_code=$(printf '%s\n' "$_openrc_helper" | grep -v '^[[:space:]]*#')
_stage_after=0
for stage in \
    'sh socks5.sh status' \
    'rc-service socks5-manager status' \
    'check-listen-port.sh "$NEW_PORT" present' \
    'check-listen-port.sh 41080 absent' \
    'sh socks5.sh restart' \
    'rc-service socks5-manager status' \
    'check-listen-port.sh "$NEW_PORT" present' \
    'sh tests/protocol/run_protocol.sh' \
    'sh socks5.sh uninstall'; do
    _stage_line=$(printf '%s\n' "$_openrc_code" | grep -nF "$stage" | awk -F: -v after="$_stage_after" '$1 > after { print $1; exit }')
    if [ -n "$_stage_line" ]; then
        t_ok
        _stage_after=$_stage_line
    else
        t_bad "OpenRC lifecycle is missing or misorders stage after line $_stage_after: $stage"
    fi
done
assert_contains "OpenRC proves curl is initially absent" \
    'command -v curl' "$_openrc_code"
assert_contains "OpenRC fails when curl is initially present" \
    'target unexpectedly contains curl' "$_openrc_code"

_distro_mem=$(ci_job_block distro-systemd-integration)
_distro_code=$(printf '%s\n' "$_distro_mem" | grep -v '^[[:space:]]*#')
for required in \
    'ubuntu | debian)' \
    'if command -v curl' \
    'target unexpectedly contains curl before install' \
    'centos)' \
    'command -v curl' \
    'rpm -q curl-minimal'; do
    assert_contains "systemd lifecycle pins curl precondition: $required" \
        "$required" "$_distro_code"
done
_curl_precondition_line=$(printf '%s\n' "$_distro_code" | grep -nF 'rpm -q curl-minimal' | cut -d: -f1)
_first_install_line=$(printf '%s\n' "$_distro_code" | grep -nF 's5-install /tmp/answers' | cut -d: -f1)
if [ -n "$_curl_precondition_line" ] && [ -n "$_first_install_line" ] &&
    [ "$_curl_precondition_line" -lt "$_first_install_line" ]; then
    t_ok
else
    t_bad "family-specific curl preconditions must precede the systemd installer"
fi
_systemd_gate=$(grep -v '^[[:space:]]*#' "$R/.github/scripts/run-systemd-memory-gate.sh")
assert_contains "systemd operations run through the memory gate" \
    'run-systemd-memory-gate.sh' "$_distro_mem"
_systemd_contract="$_distro_mem
$_systemd_gate"
for required in \
    'system-s5target.slice' \
    'LIMIT=134217728' \
    'MemoryAccounting=yes' \
    'MemoryMax=$LIMIT' \
    'MemorySwapMax=0' \
    'Slice=$SLICE'; do
    assert_contains "systemd lifecycle defines shared slice contract: $required" \
        "$required" "$_systemd_contract"
done
assert_contains "transient operations join the shared slice" \
    '--slice=system-s5target.slice' "$_systemd_gate"
assert_contains "gate queries the shared slice ControlGroup" \
    'system-s5target.slice -p ControlGroup' "$_systemd_gate"
assert_contains "gate queries the runner ControlGroup" \
    '"$UNIT.service" -p ControlGroup' "$_systemd_gate"
assert_contains "gate verifies manager placement" \
    'socks5-manager.service -p ControlGroup' "$_systemd_gate"
for required in memory.peak memory.max memory.swap.max memory.events oom_kill; do
    assert_contains "systemd gate verifies shared cgroup value: $required" \
        "$required" "$_systemd_gate"
done
assert_not_contains "runner cgroup no longer owns the memory limit" \
    '--property=MemoryMax' "$_systemd_gate"
assert_contains "systemd performs a real in-place update" 'update.answers' "$_distro_mem"
assert_contains "systemd checks transaction cleanup" 'reconfigure-transaction' "$_distro_mem"

# =========================================================================
# BF-08: precise workflow-shape and application guards.
# =========================================================================

# The workflow expands to EXACTLY 45 jobs. A matrix shrink must fail here,
# not in a CI run.
_jobs_count=$(awk '/^jobs:/{f=1;next} f && /^  [a-z][a-z0-9-]*:$/{n++} END{print n+0}' "$CI")
_timeouts=$(grep -c '^[[:space:]]*timeout-minutes:' "$CI")
assert_eq "eight job definitions (expanding to 45)" 8 "$_jobs_count"
assert_eq "every definition carries a timeout" "$_jobs_count" "$_timeouts"

# The expansion is 1 lint + 2 unit + 16 build + 16 protocol + 3 acl + 2 systemd
# + 2 openrc + 3 distro. The structure test must compute this from the
# definitions themselves.
_build_imgs=$(awk '/^  build-matrix:/{f=1} f && /^  protocol:/{exit} f && /- "/{c++} END{print c+0}' "$CI")
_proto_imgs=$(awk '/^  protocol:/{f=1} f && /^  acl-resolution:/{exit} f && /- "/{c++} END{print c+0}' "$CI")
assert_eq "build matrix has 8 images x 2 runners = 16 cells" 8 "$_build_imgs"
assert_eq "protocol matrix has 8 images x 2 runners = 16 cells" 8 "$_proto_imgs"
_expanded=$((1 + 2 + _build_imgs*2 + _proto_imgs*2 + 3 + 2 + 2 + 3))
assert_eq "workflow expands to exactly 45 jobs" 45 "$_expanded"

# The redaction is APPLIED in every lifecycle job that can emit a generated
# password on failure.
_sedf=$(grep -c 'sed -f.*redact.sed' "$CI")
if [ "$_sedf" -ge 3 ]; then
    t_ok
else
    t_bad "each lifecycle job must APPLY sed -f redact.sed to its install log"
fi

# All three Python tools are explicitly compiled.
_comp3=$(grep -c 'py_compile' "$CI")
assert_eq "the lint job compiles all 3 Python tools" 3 "$_comp3"

t_summary
