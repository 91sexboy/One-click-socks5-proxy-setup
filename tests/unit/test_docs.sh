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
assert_file_exists "README.zh-CN.md exists" "$R/README.zh-CN.md"
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
readme_zh=$(cat "$R/README.zh-CN.md" 2>/dev/null || true)
lang_switch='[English](README.md) | [简体中文](README.zh-CN.md)'
for doc in "$R/README.md" "$R/README.zh-CN.md"; do
    _docname=${doc##*/}
    if [ -f "$doc" ]; then
        assert_eq "$_docname has one language switch" 1 \
            "$(grep -Fxc "$lang_switch" "$doc")"
        _switch_line=$(grep -nFx "$lang_switch" "$doc" | cut -d: -f1)
        if [ -n "$_switch_line" ] && [ "$_switch_line" -le 6 ]; then t_ok; else t_bad "$_docname language switch must be near the top"; fi
    fi
done
assert_contains "Chinese README is genuinely Chinese" "Alpine Linux 部署" "$readme_zh"
assert_contains "Chinese README says SOCKS5 is not a VPN" "不是 VPN" "$readme_zh"
assert_contains "Chinese README says authentication is cleartext" "明文传输" "$readme_zh"
assert_contains "Chinese README says password storage is plaintext" "明文保存" "$readme_zh"
assert_contains "Chinese README says firewall is untouched" "不检测或修改防火墙" "$readme_zh"
assert_contains "Chinese README keeps v1.1 as candidate" "v1.1.0 — 候选版本" "$readme_zh"
assert_contains "Chinese README pins focal amd64-only support" 'Ubuntu 20.04：仅 `amd64`' "$readme_zh"
assert_contains "Chinese README pins modern Ubuntu dual-arch support" 'Ubuntu 22.04+：`amd64` / `arm64`' "$readme_zh"

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
assert_contains "README names the versioned engine release" "engine-3proxy-0.9.9.0-r2" "$readme"
assert_contains "README documents embedded digest verification" "embedded SHA-256" "$readme"
assert_contains "README documents the 128 MiB gate" "128 MiB" "$readme"
# The commands use Bash process substitution. The project-standard Alpine form
# explicitly installs Bash and routes parsing through a quoted `bash -c` string;
# none of the forms may pipe the interactive installer into sh.
expected_wget='bash <(wget -qO- https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/develop/socks5.sh)'
expected_curl='bash <(curl -fsSL https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/develop/socks5.sh)'
assert_contains "README explains Alpine uses explicit Bash parsing" \
    "explicitly make Bash parse" "$readme"
assert_contains "README pins focal amd64 support" \
    'Ubuntu 20.04: `amd64` only' "$readme"
assert_contains "README pins modern Ubuntu dual-arch support" \
    'Ubuntu 22.04+: `amd64` / `arm64`' "$readme"
expected_alpine="apk add --no-cache bash wget && bash -c 'bash <(wget -qO- https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/develop/socks5.sh)'"
release_hash=$(sha256sum "$R/socks5.sh" | cut -d' ' -f1)
v1_hash='acbfbfe3e6ba0f37f4e2a24ba8a6d68ec5a36513caae2e22e44a0ed28322e0b1'
section_markers='<!-- section: alpine -->
<!-- section: general-install -->
<!-- section: credentials -->
<!-- section: management -->
<!-- section: supported-systems -->
<!-- section: protocol -->
<!-- section: security -->
<!-- section: firewall -->
<!-- section: resources -->
<!-- section: dependencies -->
<!-- section: uninstall -->
<!-- section: releases -->
<!-- section: verification -->
<!-- section: license -->'

check_shared_readme_contract() {
    _src=$1
    _name=${_src##*/}
    [ -f "$_src" ] || return 0
    _body=$(cat "$_src")
    assert_eq "$_name pins Alpine bootstrap once" 1 "$(grep -Fxc -- "$expected_alpine" "$_src")"
    assert_eq "$_name pins wget bootstrap once" 1 "$(grep -Fxc -- "$expected_wget" "$_src")"
    assert_eq "$_name pins curl bootstrap once" 1 "$(grep -Fxc -- "$expected_curl" "$_src")"
    _aline=$(grep -nFx "$expected_alpine" "$_src" | cut -d: -f1)
    _gline=$(grep -nFx "$expected_wget" "$_src" | cut -d: -f1)
    if [ -n "$_aline" ] && [ -n "$_gline" ] && [ "$_aline" -lt "$_gline" ]; then t_ok; else t_bad "$_name must put Alpine deployment first"; fi
    assert_eq "$_name has exactly one socks5 URI example" 1 "$(grep -oF 'socks5://' "$_src" | wc -l)"
    assert_eq "$_name contains no legacy SOCKS family name" 0 "$(grep -ciE 'socks4' "$_src" || true)"
    for token in 'RFC 1929' 'CONNECT' 'BIND' 'UDP ASSOCIATE' 'auth strong' 'socks -u2' 'deny *' \
        '0.0.0.0' 'Ubuntu 20.04' 'Ubuntu 22.04+' 'Ubuntu Pro/ESM' \
        'max_required_glibc=2.31' '48-job workflow' \
        'https://example.com/' 'https://icanhazip.com' 'SERVER_IPV4' '17-byte' \
        '20000–60000' '1024–65535' '3–32' '12–128' '32' '[Y/n]' '[y/N]' \
        '/etc/socks5-manager/users.cfg' 'root:socks5proxy 0640' \
        '/var/lib/socks5-manager/reconfigure-transaction/' 'non-recursive' \
        'engine-3proxy-0.9.9.0-r2' 'GLIBC_2.25' 'glibc amd64' 'glibc arm64' 'musl amd64' 'musl arm64' \
        '3proxy-0.9.9.0-da99424-linux-glibc-amd64' '294552' '9c2892b46121439f3c5a05fc19ec07fe68d2ce3498110cac29c165749efaafcf' \
        '3proxy-0.9.9.0-da99424-linux-glibc-arm64' '279288' '344e482272e5c16d1f9c762d7ed240cda43bb050a53be767e5393a616607ccf5' \
        '3proxy-0.9.9.0-da99424-linux-musl-amd64' '298280' 'ac3fe1a7d52d2b1494d4d00884fc7517acb2340454c2653c95a7346c05d69298' \
        '3proxy-0.9.9.0-da99424-linux-musl-arm64' '277624' '38f2733dfc5d375a4faaebe79f66bd181c7cc3e7b3eb9443c3ac4476fbfeebeb' \
        'da99424eac4092e3722f1a5b1844cfe80478f580' '128 MiB' \
        '27ed6d97048f9d3aadd306461f82bb026146e83e' '33473381427' \
        'README.md' 'README.zh-CN.md' 'SPEC.md' 'LICENSE'; do
        assert_contains "$_name keeps shared fact: $token" "$token" "$_body"
    done
    _markers=$(grep '^<!-- section: [a-z-]* -->$' "$_src")
    assert_eq "$_name keeps the canonical section order" "$section_markers" "$_markers"
    _v1=$(awk '/^### v1\.0\.0/{on=1} /^### v1\.1\.0/{on=0} on' "$_src")
    _v11=$(awk '/^### v1\.1\.0/{on=1} on' "$_src")
    assert_eq "$_name pins the released v1 digest once" 1 \
        "$(printf '%s\n' "$_v1" | grep -oF "$v1_hash" | wc -l)"
    assert_not_contains "$_name keeps candidate digest out of v1" "$release_hash" "$_v1"
    assert_eq "$_name pins the candidate digest twice" 2 \
        "$(printf '%s\n' "$_v11" | grep -oF "$release_hash" | wc -l)"
    assert_not_contains "$_name keeps v1 digest out of candidate" "$v1_hash" "$_v11"
    assert_not_contains "$_name never recommends a fixed /tmp script" '/tmp/socks5.sh' "$_body"
}
check_shared_readme_contract "$R/README.md"
check_shared_readme_contract "$R/README.zh-CN.md"

assert_contains "README verifies the release with sha256sum" "sha256sum -c -" "$readme"
assert_contains "README names develop as the moving channel" \
    'moving development channel' "$readme"
assert_contains "README names versioned tags and never-move policy" \
    'never-move release policy' "$readme"
assert_contains "README discloses lack of GitHub tag enforcement" \
    'does not currently enforce tag immutability' "$readme"
assert_contains "README requires the implementation checkpoint" \
    'implementation checkpoint' "$readme"
assert_contains "README requires the expanded implementation CI" \
    '48-job workflow' "$readme"
assert_contains "README requires exact develop closure evidence" \
    'exact closure commit' "$readme"
assert_contains "README records the prior bilingual run" \
    '33473381427' "$readme"
assert_contains "README records the prior bilingual commit" \
    '27ed6d97048f9d3aadd306461f82bb026146e83e' "$readme"

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

# -------------------------------------- CI defines focal-aware product matrices
ci=$(cat "$R/.github/workflows/ci.yml")
for img in 'ubuntu:20.04' 'ubuntu:22.04' 'ubuntu:24.04' 'debian:12' 'debian:13' \
    'alpine:3.20' 'alpine:3.24' 'centos:stream9' 'centos:stream10'; do
    assert_contains "CI covers $img" "$img" "$ci"
done
buildimgs=$(printf '%s\n' "$ci" | awk '/^  build-matrix:/,/^  protocol:/' | grep -c '^          - "')
assert_eq "build matrix declares 9 images" 9 "$buildimgs"
protoimgs=$(printf '%s\n' "$ci" | awk '/^  protocol:/,/^  acl-resolution:/' | grep -c '^          - "')
assert_eq "protocol matrix declares 9 images" 9 "$protoimgs"
assert_contains "CI excludes focal from the arm runner" 'runner: ubuntu-24.04-arm' "$ci"
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
assert_contains "README distinguishes the CI job scopes" "build-matrix" "$readme"
assert_contains "README documents focal protocol scope" "Ubuntu 20.04 amd64" "$readme"
# The public README keeps one auditable released checkpoint and the current
# candidate checkpoint. Detailed historical evidence remains in SPEC.md.
assert_contains "README records the released v1.0.0 closure run" \
    "33282068288" "$readme"
assert_contains "README links the released v1.0.0 closure run" \
    "actions/runs/33282068288" "$readme"
assert_contains "README records the prior bilingual run as historical" \
    "33473381427" "$readme"
assert_contains "README links the prior bilingual run" \
    "actions/runs/33473381427" "$readme"
assert_contains "README records the prior bilingual commit" \
    "27ed6d97048f9d3aadd306461f82bb026146e83e" "$readme"
assert_contains "README gates the current implementation on expanded CI" \
    '48-job workflow' "$readme"
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
assert_contains "SPEC records the prior bilingual run" \
    '33473381427' "$spec"
assert_contains "SPEC records the prior bilingual commit" \
    '27ed6d97048f9d3aadd306461f82bb026146e83e' "$spec"
assert_contains "SPEC says focal implementation evidence is pending" \
    'earn a new 48-job implementation run' "$spec"
assert_contains "SPEC says closure evidence remains pending" \
    'exact closure' "$spec"
assert_not_contains "SPEC has no current raw main install URL" \
    '/main/socks5.sh' "$spec"
assert_contains "SPEC distinguishes the systemd shared slice" \
    "shared systemd slice" "$spec"
assert_contains "SPEC distinguishes the OpenRC container cgroup" \
    "OpenRC target-container cgroup" "$spec"
assert_contains "SPEC records CentOS curl-minimal baseline" \
    'curl-minimal' "$spec"
assert_contains "SPEC says CI reuses curl-minimal" \
    'verifies and reuses' "$spec"

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
