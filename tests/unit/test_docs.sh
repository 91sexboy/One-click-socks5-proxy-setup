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
assert_contains "README says target hosts do not compile" "does not compile" "$readme"
assert_contains "README names the runtime CA dependency" "ca-certificates" "$readme"
assert_not_contains "README no longer requires build-essential on target hosts" "build-essential" "$readme"
assert_contains "README says runtime packages are left in place" "left in place" "$readme"
assert_contains "README says updates are the operator's job" "responsibility" "$readme"
assert_contains "README names the pinned commit" "da99424eac4092e3722f1a5b1844cfe80478f580" "$readme"
assert_contains "README names the immutable engine release" "engine-3proxy-0.9.9.0-r1" "$readme"
assert_contains "README documents embedded digest verification" "embedded SHA-256" "$readme"
assert_contains "README documents the 128 MiB gate" "128 MiB" "$readme"
# The primary install form is the one-click one-liner over the real raw URL,
# in both the wget and curl variants. It must use bash process substitution
# (dash and busybox sh cannot parse `<(...)`), and it must not be a pipe --
# `wget -qO- URL | sh` would feed the script itself to the prompts' stdin and
# break the interactive flow.
expected_wget='bash <(wget -qO- https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/develop/socks5.sh)'
expected_curl='bash <(curl -fsSL https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/develop/socks5.sh)'
assert_eq "README pins the exact one-click wget command once" \
    1 "$(grep -Fxc -- "$expected_wget" "$R/README.md")"
assert_eq "README pins the exact one-click curl command once" \
    1 "$(grep -Fxc -- "$expected_curl" "$R/README.md")"
assert_contains "README explains Alpine needs Bash for process substitution" \
    "Install Bash first" "$readme"
assert_contains "README pins all supported minimum versions" \
    "Ubuntu 22.04+, Debian 12+, Alpine Linux 3.20+, CentOS Stream 9+" "$readme"
expected_alpine="apk add --no-cache bash wget && bash -c 'bash <(wget -qO- https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/develop/socks5.sh)'"
assert_eq "README pins the exact stock-Alpine bootstrap once" \
    1 "$(grep -Fxc -- "$expected_alpine" "$R/README.md")"
assert_not_contains "README never uses a fixed /tmp path" "/tmp/socks5.sh" "$readme"
release_hash=$(sha256sum "$R/socks5.sh" | cut -d' ' -f1)
v1_hash='acbfbfe3e6ba0f37f4e2a24ba8a6d68ec5a36513caae2e22e44a0ed28322e0b1'
v1_section=$(awk '/^### v1\.0\.0/{on=1} /^### v1\.1\.0/{on=0} on' "$R/README.md")
v11_section=$(awk '/^### v1\.1\.0/{on=1} on' "$R/README.md")
assert_contains "README documents the immutable v1.0.0 URL" \
    "/v1.0.0/socks5.sh" "$v1_section"
assert_eq "v1.0 section pins the immutable v1.0 digest once" 1 \
    "$(printf '%s\n' "$v1_section" | grep -oF "$v1_hash" | wc -l)"
assert_not_contains "v1.0 section never uses the moving candidate digest" \
    "$release_hash" "$v1_section"
assert_eq "v1.1 section prints the current candidate digest twice" 2 \
    "$(printf '%s\n' "$v11_section" | grep -oF "$release_hash" | wc -l)"
assert_not_contains "v1.1 section never uses the immutable v1.0 digest" \
    "$v1_hash" "$v11_section"
assert_contains "README verifies the release with sha256sum" "sha256sum -c -" "$readme"
assert_contains "README names develop as the moving channel" \
    'moving development channel' "$readme"
assert_contains "README names version tags as immutable" \
    'immutable semantic-version tag' "$readme"
assert_contains "README requires the implementation checkpoint" \
    'implementation commit must pass 45/45' "$readme"
assert_contains "README requires the evidence-only checkpoint" \
    'evidence-only commit must then pass 45/45' "$readme"
assert_contains "README requires exact develop closure evidence" \
    'exact closure commit must pass 45/45 on `develop`' "$readme"
assert_contains "README creates the immutable tag only after closure" \
    'Only then is the immutable' "$readme"
assert_contains "README records the superseded implementation run" \
    '33355799664' "$readme"
assert_contains "README records the superseded evidence run" \
    '33376645854' "$readme"
assert_contains "README says the safety repair resets release evidence" \
    'superseded by the current safety repair' "$readme"
assert_contains "README shows only the socks5 scheme" "socks5://" "$readme"
assert_not_contains "README never shows a socks4 URI" "socks4://" "$readme"

# The operator contract is public behaviour, not explanatory decoration. Pin
# the load-bearing phrases so deleting any promise fails this test while normal
# prose edits around them remain free.
for contract in \
    '1 中文 / 2 English' \
    'Enter alone selects 中文' \
    'answer is re-asked' \
    'This is the first question on' \
    '`[Y/n]` question controls the fresh installation' \
    'asks five questions in' \
    'Custom input is visible' \
    'another person, terminal recorder, or serial-console logger' \
    'https://icanhazip.com' \
    'exactly one localized warning' \
    'no published support window' \
    'security backports automatically reach' \
    'prints the password to your terminal only' \
    'stdout is a real terminal' \
    'source IP' \
    'No port, username, or password' \
    'SERVER_IPV4' \
    'default-no `[y/N]` confirmation' \
    'updates the configuration in place' \
    'has no firewall functionality at all'; do
    assert_contains "README keeps operator contract: $contract" "$contract" "$readme"
done
prereq_line=$(grep -nF 'Only after that confirmation, the displayed missing runtime prerequisites are installed' "$R/README.md" | cut -d: -f1)
port_line=$(grep -nF '**Port** —' "$R/README.md" | cut -d: -f1)
if [ -n "$prereq_line" ] && [ -n "$port_line" ] && [ "$prereq_line" -lt "$port_line" ]; then
    t_ok
else
    t_bad "README must place prerequisite installation before all value prompts"
fi
assert_contains "README says no secret precedes prerequisites" \
    'No port, username, or password is collected before that step finishes' "$readme"
assert_contains "README documents the systemd shared-slice gate" \
    'shared systemd slice containing both the' "$readme"
assert_contains "README documents the OpenRC container gate" \
    'OpenRC target-container cgroup' "$readme"
assert_contains "README documents CentOS curl-minimal reuse" \
    'CentOS Stream starts with `curl-minimal` and reuses it' "$readme"

# The public operator document names only the supported SOCKS5 surface. Legacy
# family names remain in the developer spec and rejection suite, never README.
assert_eq "README contains no legacy SOCKS family name" 0 \
    "$(grep -ciE 'socks4' "$R/README.md" || true)"

assert_not_contains "public README does not expose internal task ledgers" "tasks/" "$readme"

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

# -------------------------------------- CI defines 16 asset-compatibility cells
ci=$(cat "$R/.github/workflows/ci.yml")
for img in 'ubuntu:22.04' 'ubuntu:24.04' 'debian:12' 'debian:13' \
    'alpine:3.20' 'alpine:3.24' 'centos:stream9' 'centos:stream10'; do
    assert_contains "CI covers $img" "$img" "$ci"
done
# 8 images x 2 runners in both the compatibility and protocol matrices = 16 cells each
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
# The public README keeps one auditable released checkpoint and the current
# candidate checkpoint. Detailed historical evidence remains in SPEC.md.
assert_contains "README records both superseded green checkpoints" \
    "both 45/45" "$readme"
assert_contains "README records the released v1.0.0 closure run" \
    "33282068288" "$readme"
assert_contains "README links the released v1.0.0 closure run" \
    "actions/runs/33282068288" "$readme"
assert_contains "README records the current implementation run" \
    "33355799664" "$readme"
assert_contains "README links the current implementation run" \
    "actions/runs/33355799664" "$readme"
assert_contains "README records the current implementation commit" \
    "f508666e0b31512b32502a3bb1a85b9742671b52" "$readme"
assert_contains "README gates the v1.1.0 candidate on develop closure CI" \
    'exact closure commit must pass 45/45 on `develop`' "$readme"
assert_not_contains "README removes the stale preliminary run" \
    "33324226518" "$readme"
assert_not_contains "README removes the stale unearned-CI claim" \
    "release-asset implementation must earn a new complete CI run" "$readme"
assert_not_contains "README removes the pre-green systemd claim" \
    "No real systemd install lifecycle has completed yet" "$readme"
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

# The published-state run is the newest link in the evidence chain. It was
# asserted in SPEC and the task docs while no test held it, so a doc edit could
# silently drop the only pointer to what is actually published -- and SPEC
# simultaneously claimed FROZEN in its header and "remains pending" in §18.
assert_contains "SPEC retains the previous published evidence run" "33246222640" "$spec"
assert_contains "SPEC names the Round 17 implementation run" "33281392984" "$spec"
assert_contains "SPEC records the full Round 17 implementation commit" \
    "3b58e194887bf91a06b789353c06033b70c49c59" "$spec"
assert_contains "SPEC names the Round 17 evidence run" "33281724740" "$spec"
assert_contains "SPEC records the full Round 17 evidence commit" \
    "a8ed8255fba6c9bf9b8247582d6b77ebf65d8374" "$spec"
assert_contains "SPEC preserves the released v1.0.0 baseline" \
    "v1.0.0 RELEASED / v1.1.0 CANDIDATE" "$spec"
assert_contains "SPEC gates v1.1.0 on implementation CI" \
    "implementation commit must pass 45/45" "$spec"
assert_contains "SPEC gates v1.1.0 on evidence-only CI" \
    "evidence-only commit must then pass 45/45" "$spec"
assert_contains "SPEC gates v1.1.0 on exact develop closure CI" \
    'exact closure commit must pass 45/45 on `develop`' "$spec"
assert_contains "SPEC records the superseded implementation run" \
    '33355799664' "$spec"
assert_contains "SPEC records the superseded evidence run" \
    '33376645854' "$spec"
assert_contains "SPEC marks old v1.1 evidence as superseded" \
    'superseded historical candidate evidence' "$spec"
assert_contains "SPEC says current checkpoints remain pending" \
    'runs remain pending' "$spec"
assert_not_contains "SPEC has no current raw main install URL" \
    '/main/socks5.sh' "$spec"
assert_contains "SPEC distinguishes the systemd shared slice" \
    "shared systemd slice" "$spec"
assert_contains "SPEC distinguishes the OpenRC container cgroup" \
    "OpenRC target-container cgroup" "$spec"
assert_contains "SPEC records CentOS curl-minimal baseline" \
    'CentOS starts with `curl-minimal`' "$spec"

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
