#!/bin/sh
# tests/unit/test_docs.sh - Task 8, the locally verifiable part: documentation
# rules, probe syntax, and the test-only nature of the protocol tooling.
#
# The live protocol matrix itself is CI-only (no container runtime, no compiler,
# and starting a listener is forbidden on a development machine).

S5T_NAME=test_docs
. "${S5_REPO_ROOT}/tests/lib/assert.sh"

R="${S5_REPO_ROOT}"

# --------------------------------------------------------------- deliverables
assert_file_exists "README.md exists" "$R/README.md"
assert_file_exists "LICENSE exists" "$R/LICENSE"
assert_file_exists "CI workflow exists" "$R/.github/workflows/ci.yml"
assert_file_exists "protocol runner exists" "$R/tests/protocol/run_protocol.sh"
assert_file_exists "protocol probe exists" "$R/tests/protocol/socks_probe.py"
assert_file_exists "engine starter exists" "$R/tests/protocol/start_engine.sh"
assert_file_exists "ACL resolution test exists" "$R/tests/protocol/acl_resolution.sh"
assert_file_exists "pty interrupt test exists" "$R/tests/pty/interrupt.py"

# ----------------------------------------------------- shell syntax of tooling
for f in "$R/tests/protocol/run_protocol.sh" "$R/tests/protocol/start_engine.sh" \
    "$R/tests/protocol/acl_resolution.sh"; do
    t_run sh -n "$f"
    assert_eq "sh -n clean: $(basename "$f")" 0 "$T_STATUS"
done

# ------------------------------------------------------------- probe compiles
if command -v python3 >/dev/null 2>&1; then
    t_run python3 -m py_compile "$R/tests/protocol/socks_probe.py"
    assert_eq "socks_probe.py compiles" 0 "$T_STATUS"
    t_run python3 -m py_compile "$R/tests/pty/interrupt.py"
    assert_eq "interrupt.py compiles" 0 "$T_STATUS"
else
    t_skip "python syntax checks" "python3 is not available"
fi

# ------------------------- the probe must never become a runtime dependency
if grep -q 'socks_probe' "$R/socks5.sh"; then
    t_bad "socks5.sh must not reference the test-only python probe"
else
    t_ok
fi
if grep -qE '(^|[^a-z_])python3?([^a-z]|$)' "$R/socks5.sh"; then
    t_bad "socks5.sh must not depend on python"
else
    t_ok
fi

# --------------------------------------------------- README: SOCKS5 only
readme=$(cat "$R/README.md")
assert_contains "README states SOCKS5 is not a VPN" "not a VPN" "$readme"
assert_contains "README warns authentication is cleartext" "cleartext" "$readme"
assert_contains "README says the password is stored in plaintext" "plaintext" "$readme"
assert_contains "README explains root can read the credentials" "root" "$readme"
assert_contains "README recommends SSH/TLS/VPN for sensitive use" "SSH" "$readme"
assert_contains "README lists the build dependencies" "build-essential" "$readme"
assert_contains "README names the apt CA bundle the installer adds" \
    "build-essential ca-certificates" "$readme"
assert_contains "README says packages are left in place" "left in place" "$readme"
assert_contains "README says updates are the operator's job" "responsibility" "$readme"
assert_contains "README names the pinned commit" "da99424eac4092e3722f1a5b1844cfe80478f580" "$readme"
# The primary install form is the one-click one-liner over the real raw URL,
# in both the wget and curl variants. It must use bash process substitution
# (dash and busybox sh cannot parse `<(...)`), and it must not be a pipe --
# `wget -qO- URL | sh` would feed the script itself to the prompts' stdin and
# break the interactive flow.
assert_contains "README shows the one-click wget one-liner" \
    "bash <(wget -qO- https://raw.githubusercontent.com/" "$readme"
assert_contains "README shows the one-click curl one-liner" \
    "bash <(curl -fsSL https://raw.githubusercontent.com/" "$readme"
assert_contains "README warns that Alpine lacks bash" "apk add bash" "$readme"
assert_not_contains "README never uses a fixed /tmp path" "/tmp/socks5.sh" "$readme"
assert_contains "README shows only the socks5 scheme" "socks5://" "$readme"
assert_not_contains "README never shows a socks4 URI" "socks4://" "$readme"

# Every SOCKS4 mention must be a rejection statement, never an offer.
#
# The allowlist exempts a line from this check, so every token in it is a hole.
# Each token below is the sole cover for exactly one README line and is specific
# enough that it cannot occur in an advertisement. The list this replaced carried
# bare negations (`never`, `does not`, `cannot`, `refus`, `fails`), which exempt
# a line for negating anything at all -- "SOCKS4 is fully supported; the password
# is never logged" passed it -- and `enable SOCKS4`, which exempted the literal
# sentence "We enable SOCKS4 for legacy clients". Six of its thirteen tokens
# covered no line at all. This pattern must stay byte-identical to the one in
# .github/workflows/ci.yml; test_ci_lint.sh asserts that.
badlines=$(grep -niE 'socks4' "$R/README.md" |
    grep -viE 'not supported|rejection tests|no option|only a user-ID|not[^ ]* enable SOCKS4|fails the job' || true)
if [ -z "$badlines" ]; then
    t_ok
else
    t_bad "README mentions SOCKS4 outside a rejection context: $badlines"
fi
# The count is pinned too. An allowlist alone cannot catch a NEW advertisement
# that happens to contain a token intended for a different line; requiring the
# count to be updated deliberately forces any added line to be read.
assert_eq "the number of SOCKS4-mentioning README lines is pinned" \
    6 "$(grep -ciE 'socks4' "$R/README.md")"
# Each token must still be load-bearing: dropping any one of them must leave a
# README line uncovered. A token that covers nothing is a hole with no purpose.
socks4_lines=$(grep -niE 'socks4' "$R/README.md")
for _tok in 'not supported' 'rejection tests' 'no option' 'only a user-ID' \
    'not[^ ]* enable SOCKS4' 'fails the job'; do
    if printf '%s\n' "$socks4_lines" | grep -qiE -- "$_tok"; then
        t_ok
    else
        t_bad "allowlist token covers no README line and is a pure hole: $_tok"
    fi
done

# --------------------------------------- README explains the -4 / -u2 flags
assert_contains "README explains -4" "IPv4 destination resolution only" "$readme"
assert_contains "README explains -u2" "require username/password" "$readme"

# ---------------------------------------------- protocol suite covers 7 cases
proto=$(cat "$R/tests/protocol/run_protocol.sh")
assert_contains "case 1 present" "socks5-connect" "$proto"
assert_contains "case 2 present" "wrong password" "$proto"
assert_contains "case 3 present" "socks5-noauth" "$proto"
assert_contains "case 4 present" "socks4-connect" "$proto"
assert_contains "case 5 present" "socks4a-connect" "$proto"
assert_contains "case 6 present" "socks5-bind" "$proto"
assert_contains "case 7 present" "socks5-udpassoc" "$proto"
assert_contains "release gate present" "RELEASE GATE FAILURE" "$proto"
assert_contains "release gate has a distinct exit code" "exit 3" "$proto"
assert_not_contains "release gate has no skip flag" "SKIP_GATE" "$proto"
assert_not_contains "release gate cannot be forced" "FORCE" "$proto"

# credentials must reach the probe and curl via stdin, never argv
assert_not_contains "probe is not given a password argument" "--password" "$proto"
assert_contains "curl reads its config from stdin" "curl --config -" "$proto"

# M7: the ambient USER variable must not be used as a parameter
assert_contains "runner uses PROXY_USER" "PROXY_USER" "$proto"
if printf '%s\n' "$proto" | grep -qE '\$\{?USER[:}]|\$USER\b'; then
    t_bad "the runner must not read the ambient USER variable"
else
    t_ok
fi

# M4: an EOF after a SOCKS5 request is a refusal, not a probe error.
# The no-auth mode is deliberately exempt: there the method selection itself
# is the verdict (an accepted 0x00 is a security failure no later reply can
# rehabilitate), so it never reaches a request and has no EOF-after-request
# branch to count.
probe_src=$(cat "$R/tests/protocol/socks_probe.py")
assert_contains "probe documents three distinct outcomes" "GRANTED" "$probe_src"
assert_contains "probe documents REFUSED" "REFUSED" "$probe_src"
assert_contains "probe documents ERROR as inconclusive" "never a pass" "$probe_src"
eofrefusals=$(printf '%s\n' "$probe_src" | grep -c 'closed after the request (EOF)')
if [ "$eofrefusals" -ge 2 ]; then
    t_ok
else
    t_bad "every request-sending SOCKS mode must treat EOF after the request as REFUSED (found $eofrefusals)"
fi

# H1: the ACL resolution test refuses to run outside an isolated environment
acl=$(cat "$R/tests/protocol/acl_resolution.sh")
assert_contains "ACL test requires explicit isolation" "S5_ISOLATED" "$acl"
assert_contains "ACL test refuses without isolation" "REFUSING TO RUN" "$acl"
assert_contains "ACL test checks the hostname path" "metadata-probe.invalid" "$acl"
assert_contains "ACL test checks the literal IP path" "by literal IP" "$acl"
assert_contains "ACL test blocks the release on bypass" "RELEASE BLOCKER" "$acl"
assert_contains "ACL test cites the pinned source evidence" "src/acl.c" "$acl"

# ---------------------------------------------------- CI defines 16 build cells
ci=$(cat "$R/.github/workflows/ci.yml")
for img in 'ubuntu:22.04' 'ubuntu:24.04' 'debian:12' 'debian:13' \
    'alpine:3.20' 'alpine:3.24' 'centos:stream9' 'centos:stream10'; do
    assert_contains "CI covers $img" "$img" "$ci"
done
# 8 images x 2 runners in both the build and protocol matrices = 16 cells each
buildimgs=$(printf '%s\n' "$ci" | awk '/^  build-matrix:/,/^  protocol:/' | grep -c '^          - "')
assert_eq "build matrix declares 8 images" 8 "$buildimgs"
protoimgs=$(printf '%s\n' "$ci" | awk '/^  protocol:/,/^  acl-resolution:/' | grep -c '^          - "')
assert_eq "protocol matrix declares 8 images" 8 "$protoimgs"
assert_contains "CI uses the native arm64 runner" "ubuntu-24.04-arm" "$ci"
assert_contains "CI pins checkout to a full commit SHA" \
    "actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09" "$ci"
if printf '%s\n' "$ci" | grep -qE 'uses:.*@v[0-9]+$'; then
    t_bad "no action may be pinned to a mutable tag"
else
    t_ok
fi
assert_contains "workflow permissions are minimised" "contents: read" "$ci"

# ------------------------------------- the unit job must run all three shells
#
# The whole suite is written to be portable across sh, dash and busybox sh, and
# several defects in this project were visible in exactly one of them (the
# busybox applet-resolution class most recently). Nothing pinned those three run
# steps, though: deleting the dash and busybox lines would leave CI green while
# silently dropping two thirds of the shell coverage the suite exists to give.
# Each step is asserted individually, and the total is pinned so an added shell
# has to be acknowledged here.
unitjob=$(printf '%s\n' "$ci" | awk '/^  unit:/,/^  # ---/')
assert_ne "the unit job was located" "" "$unitjob"
for step in 'sh tests/run.sh' \
    "S5_TEST_SHELL=dash sh tests/run.sh" \
    "S5_TEST_SHELL='busybox sh' sh tests/run.sh"; do
    if printf '%s\n' "$unitjob" | grep -qF -- "- run: $step"; then
        t_ok
    else
        t_bad "the unit job must run the suite as: $step"
    fi
done
runsteps=$(printf '%s\n' "$unitjob" | grep -cF -- 'sh tests/run.sh')
assert_eq "the unit job runs the suite under exactly 3 shells" 3 "$runsteps"
# ...and syntax-checks socks5.sh under each of them too.
for sh1 in 'sh -n socks5.sh' 'dash -n socks5.sh' 'busybox sh -n socks5.sh'; do
    if printf '%s\n' "$unitjob" | grep -qF -- "- run: $sh1"; then
        t_ok
    else
        t_bad "the unit job must syntax-check with: $sh1"
    fi
done
# The suite is run through tests/run.sh, which must honour S5_TEST_SHELL -- a
# pinned step that the runner ignored would be theatre.
assert_contains "the runner honours S5_TEST_SHELL" \
    "S5_TEST_SHELL" "$(cat "$R/tests/run.sh")"
# every job has a timeout
jobcount=$(printf '%s\n' "$ci" | awk '/^jobs:/{f=1;next} f && /^  [a-z][a-z0-9-]*:$/{n++} END{print n+0}')
timeouts=$(printf '%s\n' "$ci" | grep -c '^[[:space:]]*timeout-minutes:')
assert_eq "every job has a timeout" "$jobcount" "$timeouts"
if [ "$jobcount" -ge 7 ]; then t_ok; else t_bad "expected at least 7 jobs, found $jobcount"; fi
# no experimental tier, no gate bypass anywhere
if printf '%s\n' "$ci" | grep -qE '^[[:space:]]+continue-on-error[[:space:]]*:'; then
    t_bad "no job may declare continue-on-error"
else
    t_ok
fi
assert_not_contains "no self-hosted runner" "self-hosted" "$ci"
assert_not_contains "no committed CI password" "CiPassword" "$ci"
assert_not_contains "no credentials written to /tmp/creds" "/tmp/creds" "$ci"
assert_contains "CI generates its password at runtime" "dev/urandom" "$ci"
assert_contains "CI confines the protocol engine to loopback" "S5_LISTEN" "$ci"
assert_contains "CI has the ACL resolution job" "acl-resolution" "$ci"
assert_contains "CI states the protocol job installs no service" "does NOT install a service" "$ci"
assert_contains "CI runs shellcheck" "shellcheck" "$ci"
assert_contains "CI runs the unit suite under dash" "S5_TEST_SHELL=dash" "$ci"
assert_contains "CI runs the unit suite under busybox" "busybox sh" "$ci"
assert_contains "CI has a protocol job" "run_protocol.sh" "$ci"
assert_contains "CI has real systemd integration" "systemd-integration" "$ci"
assert_contains "CI has OpenRC integration" "openrc-integration" "$ci"

# README must document iptables non-persistence and the CI scope split.
assert_contains "README documents reboot persistence" "Persistent across reboot" "$readme"
assert_contains "README says iptables rules are not persistent" "kernel memory only" "$readme"
assert_contains "README distinguishes the CI job scopes" "real engine running the rendered config" "$readme"
# CI has run; the README now states what the runs proved and what failed. The
# status passage is deliberately rewritten as evidence changes, so pin the
# sentence that carries the current honest limit: no real systemd install
# lifecycle has completed yet. That claim is checkable against the actual CI
# runs today; when a systemd lifecycle does go green, the README AND this pin
# must be updated in the same change -- the pin's purpose is to make the README
# rot loudly instead of silently overclaiming (or drifting back to stale text).
assert_contains "README admits no real systemd lifecycle has completed" \
    "real systemd install lifecycle has completed" "$readme"
assert_not_contains "README no longer claims CI has not been run" \
    "CI has not been run" "$readme"
assert_not_contains "README no longer calls Alpine experimental" "experimental" "$readme"

# ==========================================================================
# F12: SPEC must not contradict the shipped artifact.
#
# SPEC 9 and 18 still described the pre-decision OpenRC behaviour (`need net`
# and an ordinary `output_log` file) after the locked decision changed it to
# syslog-via-logger with no `need net`. The golden fixture and test_render.sh
# assert the new behaviour, so the SPEC was the only stale copy.
# ==========================================================================
spec=$(cat "$R/SPEC.md")
gold=$(cat "$R/tests/golden/openrc-init")

# Whatever the golden script does, the SPEC must agree. A SPEC line that
# explicitly NEGATES a directive ("`need net` is deliberately not used") is
# correct documentation, so only affirmative claims are rejected.
spec_affirms() {
    printf '%s\n' "$spec" | grep -F -- "$1" |
        grep -viE 'not used|never used|deliberately|no ordinary|rather than|instead of' |
        grep -q .
}
if printf '%s\n' "$gold" | grep -q 'need net'; then
    assert_contains "SPEC documents need net because the artifact uses it" "need net" "$spec"
else
    if spec_affirms 'need net'; then
        t_bad "SPEC affirmatively claims need net although the artifact omits it"
    else
        t_ok
    fi
fi
if printf '%s\n' "$gold" | grep -q '^output_log='; then
    assert_contains "SPEC documents an ordinary log file" "output_log=" "$spec"
else
    if spec_affirms 'output_log='; then
        t_bad "SPEC affirmatively claims an output_log file although the artifact logs to syslog"
    else
        t_ok
    fi
fi
if printf '%s\n' "$gold" | grep -q 'output_logger='; then
    assert_contains "SPEC documents syslog logging via logger" "logger" "$spec"
else
    t_ok
fi

# the self-test URL is a locked decision, not an open question
assert_contains "SPEC states the fixed self-test URL" "https://example.com/" "$spec"
if printf '%s\n' "$spec" | grep -qiE 'Open:.*self-test URL'; then
    t_bad "SPEC still lists the self-test URL as an open question"
else
    t_ok
fi

t_summary
