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
# F8: the two SOCKS4 doc-lint allowlists must be byte-identical, and the CI
# pipeline must actually pass against the real README.
# ==========================================================================
ci_pat=$(grep -F 'grep -viE' "$CI" | head -n 1 | sed -e "s/.*grep -viE '//" -e "s/'.*//")
doc_pat=$(grep -F 'grep -viE' "$R/tests/unit/test_docs.sh" | head -n 1 | sed -e "s/.*grep -viE '//" -e "s/'.*//")
assert_ne "the CI allowlist was found" "" "$ci_pat"
assert_ne "the test_docs allowlist was found" "" "$doc_pat"
assert_eq "the two SOCKS4 doc-lint allowlists are identical" "$ci_pat" "$doc_pat"

# Run the CI job's exact pipeline. It must produce no output.
ci_hits=$(grep -rniE 'socks4' "$R/README.md" | grep -viE "$ci_pat" || true)
if [ -z "$ci_hits" ]; then
    t_ok
else
    t_bad "the CI doc-lint would fail on: $ci_hits"
fi

# And the local pipeline, for symmetry.
doc_hits=$(grep -rniE 'socks4' "$R/README.md" | grep -viE "$doc_pat" || true)
assert_eq "both pipelines agree on the same README" "$ci_hits" "$doc_hits"

# The allowlist must not have become a catch-all: a genuine advertisement in a
# scratch copy still has to be caught.
SCRATCH=$(mktemp -d)
cp "$R/README.md" "$SCRATCH/R.md"
printf '\nYou can also point legacy clients at socks4://host:port for convenience.\n' >>"$SCRATCH/R.md"
scratch_hits=$(grep -rniE 'socks4' "$SCRATCH/R.md" | grep -viE "$ci_pat" || true)
assert_contains "the allowlist still catches a real advertisement" "socks4://" "$scratch_hits"
rm -rf "$SCRATCH"

# ...and specifically the advertisements the PREVIOUS allowlist let through. Its
# bare negations exempted a line for negating anything at all, and `enable
# SOCKS4` exempted the very sentence an operator would write to offer it. Each
# line below is an offer of SOCKS4 and must be reported by the shipped pattern.
ADS=$(mktemp -d)
adcount=0
while IFS= read -r ad; do
    [ -n "$ad" ] || continue
    printf '%s\n' "$ad" >"$ADS/line.md"
    if grep -niE 'socks4' "$ADS/line.md" | grep -viE "$ci_pat" >/dev/null; then
        t_ok
    else
        t_bad "the allowlist exempts an advertisement: $ad"
    fi
    adcount=$((adcount + 1))
done <<'ADEOF'
SOCKS4 is fully supported; the password is never logged.
We enable SOCKS4 for legacy clients.
SOCKS4 works and the connection fails only on timeout.
SOCKS4a is offered too, though DNS does not leak.
Legacy clients cannot use SOCKS5, so SOCKS4 is available as a fallback.
ADEOF
assert_eq "every advertisement sample was actually tested" 5 "$adcount"
rm -rf "$ADS"

# Every token in the shipped allowlist must be load-bearing against the real
# README: one that covers no line is a hole with no purpose. The tokens are read
# out of the pattern the pipeline actually uses, split on the ERE alternation.
# Read from a file, not a pipe: a `while read` on the right of a pipe runs in a
# subshell in most shells, so the accumulated result would be discarded.
TOKD=$(mktemp -d)
s4lines=$(grep -niE 'socks4' "$R/README.md")
printf '%s\n' "$ci_pat" | tr '|' '\n' >"$TOKD/toks"
untok=''
ntok=0
while IFS= read -r _t; do
    [ -n "$_t" ] || continue
    ntok=$((ntok + 1))
    printf '%s\n' "$s4lines" | grep -qiE -- "$_t" || untok="$untok [$_t]"
done <"$TOKD/toks"
assert_eq "no allowlist token covers zero README lines" "" "$untok"
if [ "$ntok" -ge 1 ]; then t_ok; else t_bad "the allowlist split yielded no tokens"; fi
rm -rf "$TOKD"

# The count pin is read out of the CI job rather than restated here, so this
# cannot pass by checking a number the pipeline does not use.
ci_pin=$(grep -F 'if [ "$n" -ne ' "$CI" | head -n 1 | sed -e 's/.*-ne //' -e 's/[^0-9].*//')
case "$ci_pin" in
'' | *[!0-9]*) t_bad "the CI pipeline does not pin the SOCKS4 line count (found: '$ci_pin')" ;;
*) t_ok ;;
esac
assert_eq "the CI count pin matches the real README" \
    "$ci_pin" "$(grep -ciE 'socks4' "$R/README.md")"

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
# build matrix only compiles, and the protocol job runs the engine directly
# without installing a service, so neither can stand in for this.
assert_contains "Ubuntu has a real systemd lifecycle" \
    "ubuntu-24.04" "$(ci_job_block systemd-integration)"
assert_contains "Alpine has a real OpenRC lifecycle" \
    "alpine:3." "$(ci_job_block openrc-integration)"

# The OpenRC job is one outer shell script containing `docker ... sh -c '...'.
# A raw single quote anywhere in that inner body closes the outer quote early:
# `sh -n` can still report a syntactically valid (but completely rearranged)
# script, while the runner executes fragments as host commands and the
# container sees an unterminated block. Exactly three LINES in the RAW job
# block (comments included -- a shell quote in a comment still participates in
# lexing when the whole comment is inside the outer quote) may contain a single
# quote: the opening `sh -c '`, the redaction line's established `"'"'"'`
# escape, and the closing quote. Any fourth line is an unescaped quote that
# corrupts the boundary; force deliberate review if the quoting strategy ever
# changes. Do NOT use ci_job_block here: it strips comments and once made this
# guard miss the two apostrophes that broke the sixth CI run.
_openrc_raw_block=$(awk '
    $0 == "  openrc-integration:" { in_job = 1; next }
    in_job && /^  [a-z][a-z0-9-]*:$/ { exit }
    in_job { print }
' "$CI")
_openrc_quote_lines=$(printf '%s\n' "$_openrc_raw_block" | grep -c "'")
assert_eq "OpenRC job has exactly its three reviewed quote-bearing lines" \
    3 "$_openrc_quote_lines"

# A normal Alpine boot invokes OpenRC and initializes every runtime state
# directory (`starting`, `started`, `exclusive`, ...). The lifecycle container
# has no PID-1 OpenRC and a bare `touch softlevel` is not equivalent: OpenRC
# 0.54's svc_lock then cannot open /run/openrc/exclusive and misleadingly says
# "already starting" forever. rc-status -a drives rc_deptree_update_needed(),
# which creates the full directory set; it must happen BEFORE the installer.
_openrc_init_line=$(printf '%s\n' "$_openrc_raw_block" |
    grep -n 'rc-status -a.*initial' | head -n 1 | cut -d: -f1)
_openrc_install_line=$(printf '%s\n' "$_openrc_raw_block" |
    grep -n 'socks5\.sh install' | head -n 1 | cut -d: -f1)
assert_ne "OpenRC runtime initialization is present" "" "$_openrc_init_line"
if [ -n "$_openrc_init_line" ] && [ -n "$_openrc_install_line" ] &&
    [ "$_openrc_init_line" -lt "$_openrc_install_line" ]; then
    t_ok
else
    t_bad "OpenRC runtime initialization must precede the installer"
fi

_distro=$(ci_job_block distro-systemd-integration)
assert_contains "Debian has a real systemd lifecycle" "debian:13" "$_distro"
assert_contains "CentOS Stream has a real systemd lifecycle" "centos:stream10" "$_distro"
assert_contains "the distro lifecycle boots a real init as PID 1" "/sbin/init" "$_distro"
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

t_summary
