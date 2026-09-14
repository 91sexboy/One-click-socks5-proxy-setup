#!/bin/sh
# Cross-file release, workflow and documentation contracts.

S5T_NAME=test_xray_docs
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
ROOT=${S5_REPO_ROOT}
t_mktestroot
t_source_production ''

t_run python3 "$ROOT/tests/lib/release_contract.py" "$ROOT" "${S5_TEST_SHELL:-sh}"
assert_eq "release declarations agree with independent pins" 0 "$T_STATUS"
if [ "$T_STATUS" -ne 0 ]; then
    printf '%s\n' "$T_OUT" >&2
fi

# SPEC 8: explicit job timeouts, no continue-on-error, and a lint whose
# coverage cannot shrink without this file noticing.
CI=$ROOT/.github/workflows/ci.yml
ci_text=$(cat "$CI")
# Both lifecycle bodies are scripts rather than inline blocks, so the assertions
# about them read those files. gates_text is the triple (ci.yml plus both gate
# scripts), for the counted assertions that require both backends to prove the
# same guarantee -- without the systemd script here those counts silently drop by
# one once its body leaves the YAML.
ALPINE_GATE=$ROOT/.github/scripts/alpine-lifecycle.sh
alpine_text=$(cat "$ALPINE_GATE")
SYSTEMD_GATE=$ROOT/.github/scripts/systemd-lifecycle.sh
systemd_text=$(cat "$SYSTEMD_GATE")
gates_text=$(printf '%s\n%s\n%s\n' "$ci_text" "$systemd_text" "$alpine_text")

if grep -qE '^[[:space:]]+continue-on-error[[:space:]]*:' "$CI"; then
    t_bad 'no job in the workflow may declare continue-on-error'
else
    t_ok
fi
assert_contains "the workflow guards continue-on-error itself" \
    '^[[:space:]]+continue-on-error' "$ci_text"
assert_contains "secret checks use explicit conditionals" \
    "if sudo grep -q 'CISecret_123~x'" "$ci_text"

_jobs=$(awk '/^jobs:/{f=1;next} f && /^  [a-z][a-z0-9-]*:$/{n++} END{print n+0}' "$CI")
_tos=$(grep -c '^    timeout-minutes:' "$CI")
assert_eq "every job declares a job-level timeout" "$_jobs" "$_tos"
assert_contains "the workflow guards its own timeout coverage" \
    "timeout-minutes:" "$ci_text"

assert_contains "shellcheck is pinned, not taken from the distro" \
    'shellcheck-v0.10.0' "$ci_text"
# The asset job verified the archive but never the binary it extracts, and it is
# the only job that runs on arm64, so a wrong arm64 binary pin broke every arm64
# install while CI stayed green. Anchor on the comparisons themselves.
assert_contains "the asset job compares the extracted binary size" \
    '= "$XRAY_BINARY_SIZE"' "$ci_text"
assert_contains "the asset job compares the extracted binary digest" \
    '= "$XRAY_BINARY_SHA"' "$ci_text"
assert_contains "the asset job checks the ELF architecture" \
    '"$XRAY_ELF_ARCH"' "$ci_text"
assert_contains "the shellcheck download is checksum-verified" \
    'sha256sum -c' "$ci_text"

for _root in tests/run.sh 'tests/lib/*.sh' 'tests/unit/*.sh' \
    'tests/protocol/*.sh' '.github/scripts/*.sh'; do
    assert_contains "shellcheck covers $_root" "$_root" "$ci_text"
done
for _root in 'tests/protocol/*.py' 'tests/lib/*.py' '.github/scripts/*.py'; do
    assert_contains "Python syntax checks cover $_root" "$_root" "$ci_text"
done

# Those globs only reach files, so the workflow's own inline run: blocks were read
# by neither lint step -- which is why the two lifecycle gates had to become files
# before anything could check them. Moving three more blocks out would have shrunk
# that hole; extracting every block closes it. The step has to be pinned itself,
# or deleting it silently restores a pile of unchecked shell.
assert_contains "the lint job checks the workflow's own inline shell" \
    'lint-workflow-shell.sh' "$ci_text"
_wfltext=$(cat "$ROOT/.github/scripts/lint-workflow-shell.sh" 2>/dev/null || printf '')
assert_contains "the inline-shell linter runs the syntax check" \
    'sh -n "$f"' "$_wfltext"
assert_contains "the inline-shell linter runs shellcheck" \
    'shellcheck -s sh' "$_wfltext"
# Its own anti-vacuity guard: extracting zero blocks must fail rather than pass.
assert_contains "the inline-shell linter fails when it extracts nothing" \
    'no inline run blocks were extracted' "$_wfltext"

# Every shell file must live in a directory the lint globs actually reach. The
# file list comes from git so that .gitignore decides what CI actually sees;
# tracked-but-deleted paths are filtered by existence.
if command -v git >/dev/null 2>&1 && [ -d "$ROOT/.git" ]; then
    _shlist=$(cd "$ROOT" && {
        git ls-files '*.sh'
        git ls-files --others --exclude-standard '*.sh'
    } 2>/dev/null | sort -u)
    for _sh in $_shlist; do
        [ -f "$ROOT/$_sh" ] || continue
        _dir=${_sh%/*}
        [ "$_dir" = "$_sh" ] && _dir=.
        case "$_dir" in
        . | tests | tests/lib | tests/unit | tests/protocol | .github/scripts) t_ok ;;
        *) t_bad "shell file in a directory the lint does not reach: $_sh" ;;
        esac
    done
else
    t_skip "shell files all live in linted directories" "git is unavailable"
fi

# A check that cannot fail is not a check. The lifecycle guards were extracted from
# ci.yml into the two *-lifecycle.sh gates, so this oracle scans all three: a bare
# `grep -q` defused by `|| true` in any of them would otherwise pass unnoticed.
_defused=$(grep -n 'grep -q' "$CI" "$SYSTEMD_GATE" "$ALPINE_GATE" | grep '|| true' | grep -v '&& exit' || true)
if [ -z "$_defused" ]; then
    t_ok
else
    t_bad "a CI gate has a grep check defused by || true: $_defused"
fi

# SPEC 8 memory evidence: the sampler's cgroup branch has to actually run, OOM
# counters have to be recorded, and the four connection stages kept separate.
sampler_text=$(cat "$ROOT/.github/scripts/memory-sampler.py")
assert_contains "the sampler records cgroup OOM counters" \
    '_cgroup_oom=' "$sampler_text"
assert_contains "the sampler records cgroup OOM kills" \
    '_cgroup_oom_kill=' "$sampler_text"
assert_contains "the memory job starts one sampler with the service cgroup" \
    'memory-sample.sh "$pid" "$cgdir"' "$ci_text"
assert_contains "the memory job resets its idle stage through the persistent sampler" \
    'sample_request reset idle' "$ci_text"
assert_contains "the memory job checks high then low peaks on the actual kernel" \
    'memory-peak-check.py --real-cgroup' "$ci_text"
assert_contains "the sampler records the actual kernel release" \
    'kernel_release=' "$sampler_text"
assert_contains "systemd transition timing is not called listener readiness" \
    'xray_startup_measurement=systemd_state_transition_not_listener_readiness' "$ci_text"
# A stage's peak has to cover establishing its connections, not just holding them.
# Resetting after the holder reported ready left peak measuring a few milliseconds
# of steady state, where it cannot differ meaningfully from current, and threw away
# the allocation spike the number exists to record. The reset therefore precedes
# the holder, and the assertion anchors on that order rather than on either line.
assert_contains "each stage resets peak before its connections are established" \
    'sample_request reset "conn$stage"
            rm -f "$root/held"
            python3 tests/protocol/hold_connections.py' "$ci_text"
assert_contains "the memory job resolves the service cgroup" \
    'ControlGroup' "$ci_text"
assert_contains "the memory job records startup time" \
    'xray_startup_usec' "$ci_text"
assert_contains "the memory job samples 1, 32 and 128 connections" \
    'for stage in 1 32 128; do' "$ci_text"
# SPEC 8 says the target and driver stay outside the Xray cgroup. Structurally true,
# and until now asserted nowhere, so a driver that ended up inside it would have
# been counted as the proxy's memory.
assert_contains "the memory job proves the driver is outside the Xray cgroup" \
    'cgroup.procs' "$ci_text"
assert_contains "it names the pids that must stay outside" \
    'is inside the Xray cgroup' "$ci_text"
# The exclusion checks above pass vacuously over an empty set: they hold whether
# or not xray is present. This pins the complementary membership assertion, so a
# Delegate change that emptied cgroup.procs could not stay green with the peak
# measuring nothing.
assert_contains "the memory job proves xray itself is inside the cgroup" \
    'not in its own cgroup' "$ci_text"
assert_contains "each connection stage carries its own label" \
    'sample_request sample "conn$stage"' "$ci_text"
assert_contains "the memory job asserts the cgroup OOM counters" \
    'memory.events' "$ci_text"
assert_contains "the memory job loads connections to sample under" \
    'hold_connections.py' "$ci_text"
_memory_text=$(awk '
    /^  memory-report:/ {found=1; next}
    found && /^  [a-z][a-z0-9-]*:/ {exit}
    found {print}
' "$CI")
assert_contains "memory measurements run on the matrix runner" \
    'runs-on: ${{ matrix.runner }}' "$_memory_text"
assert_contains "memory measurements cover native amd64" \
    'runner: ubuntu-24.04
            arch: amd64' "$_memory_text"
assert_contains "memory measurements cover native arm64" \
    'runner: ubuntu-24.04-arm
            arch: arm64' "$_memory_text"
assert_contains "the memory job runs paired comparison with explicit CI environment" \
    'sudo env GITHUB_ACTIONS=true python3 .github/scripts/memory-compare.py' "$_memory_text"
assert_contains "paired comparison uses the installed verified binary" \
    '--binary /usr/local/libexec/xray-socks5/xray' "$_memory_text"
assert_contains "measurement artifacts use a pinned uploader" \
    'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02' "$_memory_text"
assert_contains "only the nonsecret comparison report is uploaded" \
    'path: memory-comparison-${{ matrix.arch }}.json' "$_memory_text"
assert_contains "missing comparison evidence fails the job" \
    'if-no-files-found: error' "$_memory_text"
assert_contains "OpenRC lifecycle job covers Alpine" 'openrc-integration' "$ci_text"
assert_contains "OpenRC lifecycle job tests both supported versions" 'alpine:3.20' "$ci_text"
assert_contains "OpenRC lifecycle job tests current Alpine" 'alpine:3.24' "$ci_text"

# The Alpine gate must prove the same SPEC guarantees as the systemd one rather
# than only reaching a healthy install, and it must exercise the installer's own
# provisioning: pre-installing the runtime tools once hid a real BusyBox defect.
assert_contains "Alpine gate installs only OpenRC up front" \
    'apk add --no-cache openrc >/dev/null' "$alpine_text"
assert_not_contains "Alpine gate does not pre-install archive tools" \
    'apk add --no-cache openrc python3' "$alpine_text"
assert_contains "Alpine gate recovers a killed Xray" 'kill -9 "$crash_pid"' "$alpine_text"
assert_contains "Alpine gate proves the listener returns after a crash" \
    'grep -q "pid=$new_pid,"' "$alpine_text"
assert_contains "Alpine gate rejects a broken configuration" \
    'printf "{broken\n" >/etc/xray-socks5/config.json' "$alpine_text"
assert_contains "Alpine gate audits the installed namespace" \
    'post_install_audit.sh / "$work/pass.update" openrc' "$alpine_text"
assert_contains "Alpine gate runs the independent protocol probe" \
    'sh tests/protocol/run_xray_mixed.sh' "$alpine_text"
assert_contains "Alpine gate keeps credentials out of argv" \
    '/proc/$live_pid/cmdline' "$alpine_text"
assert_contains "Alpine gate keeps credentials out of the environment" \
    '/proc/$live_pid/environ' "$alpine_text"
assert_contains "Alpine gate proves no packages are installed outside install" \
    'test "$(apk info | sort | sha256sum)" = "$pkgs_before"' "$alpine_text"

# Restoring the config with cp hands it the backup copy's private attributes on
# BusyBox, which looked like a product defect. Both gates restore by truncating
# in place and then assert the installer's owner and mode survived. Asserting one
# form per gate is what let the systemd half keep using cp: GNU cp happens to
# preserve the destination's attributes, so the comment was true of Alpine only.
assert_contains "Alpine gate restores the config in place" \
    'cat "$work/good.json" >/etc/xray-socks5/config.json' "$alpine_text"
assert_contains "systemd gate restores the config in place" \
    'cat "$1" >"$2"' "$systemd_text"
assert_not_contains "no gate restores the config with cp" \
    'cp "$work/good.json" /etc/xray-socks5/config.json' "$gates_text"
assert_eq "Alpine preserves config owner and mode after install and restore" 2 \
    "$(printf '%s\n' "$alpine_text" | grep -c 'root:xray-socks5 640')"
assert_eq "systemd preserves config owner and mode after restore" 1 \
    "$(printf '%s\n' "$systemd_text" | grep -c 'root:xray-socks5 640')"

# The lifecycle body used to be one single-quoted argument to docker run, where a
# single apostrophe closed the argument and handed the rest of the script to the
# host shell. It broke the gate twice and needed an oracle counting apostrophes to
# hold it. As a file the body is read by sh -n, dash -n, busybox sh -n and the
# linter, so what has to be pinned is that it stays out of the YAML.
openrc_block=$(sed -n '/^  openrc-integration:/,/^  memory-report:/p' "$ROOT/.github/workflows/ci.yml")
assert_contains "the Alpine job runs the lifecycle from a script" \
    'sh /src/.github/scripts/alpine-lifecycle.sh' "$openrc_block"
assert_not_contains "the Alpine lifecycle body is not inlined in the YAML" \
    'apk add --no-cache openrc' "$openrc_block"
assert_contains "the lifecycle script is what installs OpenRC" \
    'apk add --no-cache openrc' "$alpine_text"

# Fixtures and post-update guarantees are shared; driving each native backend
# and observing crash/exit-23 behavior remain local to that gate.
common_text=$(cat "$ROOT/.github/scripts/lifecycle-common.sh")
assert_eq "the shared lifecycle fixtures are defined once" 1 \
    "$(printf '%s\n' "$common_text" | grep -c 'lifecycle_write_fixtures()')"
assert_eq "both lifecycle gates set up the shared fixtures" 2 \
    "$(printf '%s\n' "$gates_text" | grep -c 'lifecycle_write_fixtures "\$work"')"
assert_contains "systemd observes update postconditions with root traversal" \
    'sudo sh .github/scripts/lifecycle-update-assert.sh' "$systemd_text"
assert_contains "OpenRC observes the same postconditions in its root container" \
    'sh .github/scripts/lifecycle-update-assert.sh' "$alpine_text"
update_assert_text=$(cat "$ROOT/.github/scripts/lifecycle-update-assert.sh")
assert_contains "shared update assertion requires the config owner and mode" \
    'root:xray-socks5 640' "$update_assert_text"
# Source checks above supplement execution controls; they cannot prove that a
# reached assertion's error propagates through each native caller.
for _control in systemd-assertion-controls openrc-assertion-controls; do
    _control_text=$(awk -v job="$_control" '
        $0 == "  " job ":" {found=1; next}
        found && /^  [a-z][a-z0-9-]*:/ {exit}
        found {print}
    ' "$CI")
    assert_contains "$_control covers reached, skipped, unreachable and swallowed calls" \
        'mutation: [fail, skip, unreachable, swallow]' "$_control_text"
    assert_contains "$_control executes native controls" \
        'python3 .github/scripts/lifecycle-assert-control.py' "$_control_text"
    case "$_control" in
    systemd-*) assert_contains "systemd controls require their healthy positive gate" \
        'needs: xray-systemd' "$_control_text" ;;
    openrc-*)
        assert_contains "OpenRC controls require their healthy positive gates" \
            'needs: openrc-integration' "$_control_text"
        assert_contains "OpenRC controls cover both native versions" \
            'image: ["alpine:3.20", "alpine:3.24"]' "$_control_text"
        assert_contains "OpenRC controls give orphaned daemons a reaping init" \
            'docker run --rm --init --privileged' "$_control_text"
        ;;
    esac
done
assert_contains "update diagnostics filter both known credential generations" \
    '"$work/answers.update" "$work/update.log" "$work/pass.update" "$work/pass"' "$systemd_text"
assert_contains "uninstall diagnostics filter the rotated and previous credentials" \
    '"$work/answers.uninstall" "$work/uninstall.log" "$work/pass.update" "$work/pass"' "$systemd_text"

# The audit is shared between backends, so it must not hard-code systemd paths.
audit_text=$(cat "$ROOT/tests/protocol/post_install_audit.sh")
assert_contains "the audit accepts an init backend" 'INIT=${3:-systemd}' "$audit_text"
assert_contains "the audit knows the OpenRC artifact" \
    'unit="$ROOT/etc/init.d/xray-socks5"' "$audit_text"

# SPEC 5 crash recovery and the exit-23 guard are documented claims, so each
# needs a step behind it. The backend-specific lifecycle checks must remain
# consistent with the target platform; systemd uses its native guard and Alpine
# uses the OpenRC integration job.
assert_contains "the lifecycle job kills the service to prove recovery" \
    'sudo kill -9 "$crash_pid"' "$systemd_text"
assert_contains "the lifecycle job proves the exit-23 restart guard" \
    'ExecMainStatus' "$systemd_text"
# OpenRC has no exit-status guard, so the Alpine gate takes the status from the
# supervised binary and proves the respawn guard separately. Both assertions
# anchor on the comparison rather than on a variable name or a message, because
# an oracle a deleted guard survives is not an oracle.
assert_contains "the Alpine gate requires the configuration error to exit 23" \
    'if test "$broken_status" != 23' "$alpine_text"
assert_contains "the Alpine gate requires no respawn after a configuration error" \
    'if test "$respawn_after" != "$respawn_before"' "$alpine_text"
# That comparison cannot fail when both sides are absent, which is the state a
# stopped supervise-daemon leaves behind, so the settle window also has to end with
# the service provably still down.
assert_contains "the Alpine gate requires the service to stay down" \
    'a broken config brought the service back up' "$alpine_text"
assert_contains "the Alpine gate records the observed child_pid values" \
    'openrc: child_pid %s then %s' "$alpine_text"
for _doc in README.md README.zh-CN.md; do
    for _platform in Alpine OpenRC; do
        if grep -qi "$_platform" "$ROOT/$_doc"; then
            t_ok
        else
            t_bad "$_doc documents $_platform"
        fi
    done
done

# show makes an outbound request to name the server in the credential card, so
# the endpoint is a documented fact on every surface. Anchored on the constant:
# changing the endpoint in socks5.sh, or dropping the placeholder a card falls
# back to, fails here rather than in the field.
case "$S5_ADDR_ENDPOINT" in
https://*) t_ok ;;
*) t_bad "the card address endpoint is HTTPS: $S5_ADDR_ENDPOINT" ;;
esac
_addrhost=${S5_ADDR_ENDPOINT#https://}
for _doc in README.md README.zh-CN.md; do
    _addrtext=$(cat "$ROOT/$_doc")
    assert_contains "$_doc names the card address endpoint" \
        "$_addrhost" "$_addrtext"
    assert_contains "$_doc documents the card address placeholder" \
        SERVER_IPV4 "$_addrtext"
done

# The expected destination boundary is independent of both renderers, so a range
# dropped from both cannot make their agreement pass as correctness.
S5_PORT=23456
S5_USERNAME=testuser
S5_PASSWORD='TestPassword_123~x'
s5t_boundary_ranges() {
    sed -n '/"ip": \[/,/\]/p' | sed -n 's/.*"\([0-9a-f:.]*\/[0-9]*\)".*/\1/p' | sort
}
_dcrendered=$(s5_config_render | s5t_boundary_ranges)
_dcfixture="$ROOT/tests/fixtures/denied-destinations.txt"
assert_file_exists "the destination boundary fixture exists" "$_dcfixture"
_dcexpected=$(sort "$_dcfixture")
_dcengine=$(s5t_boundary_ranges <"$ROOT/tests/protocol/start_engine.sh")
assert_eq "the destination boundary has twelve distinct ranges" 12 \
    "$(printf '%s\n' "$_dcexpected" | sort -u | wc -l | tr -d '[:space:]')"
assert_eq "the renderer denies exactly the expected ranges" \
    "$_dcexpected" "$_dcrendered"
assert_eq "the protocol launcher denies exactly the expected ranges" \
    "$_dcexpected" "$_dcengine"
assert_contains "the protocol launcher resolves hostname destinations" \
    '"domainStrategy": "IPIfNonMatch"' "$(cat "$ROOT/tests/protocol/start_engine.sh")"
for _dcdoc in README.md README.zh-CN.md; do
    _dctext=$(cat "$ROOT/$_dcdoc")
    # Destination routing exists even when the README omits its details.
    assert_not_contains "$_dcdoc does not deny the routing it describes" \
        'metrics, routing' "$_dctext"
    assert_not_contains "$_dcdoc does not deny the routing it describes (zh)" \
        'metrics、routing' "$_dctext"
    # Install proves auth, the credential differential and the boundary; the
    # payload round trip is proven in CI. Claiming transport here outlived the
    # verifier that did it.
    assert_not_contains "$_dcdoc does not claim install verifies transport" \
        'bidirectional transport locally' "$_dctext"
    assert_not_contains "$_dcdoc does not claim install verifies transport (zh)" \
        '和持续双向传输' "$_dctext"
done

# SPEC 6's local target has to be put on the host before any job drives traffic
# Each host-side driver needs target addresses on its own runner. OpenRC sets
# them inside the container, including when reached through a mutation control.
for _driver in xray-mixed xray-systemd systemd-assertion-controls memory-report; do
    _driver_text=$(awk -v job="$_driver" '
        $0 == "  " job ":" {found=1; next}
        found && /^  [a-z][a-z0-9-]*:/ {exit}
        found {print}
    ' "$CI")
    assert_contains "$_driver adds its test target addresses" \
        'sudo sh .github/scripts/add-test-target-addresses.sh' "$_driver_text"
done
assert_contains "OpenRC adds target addresses inside its native container" \
    'sh .github/scripts/add-test-target-addresses.sh' "$alpine_text"
assert_eq "the mixed gate runs on all three backends" 3 \
    "$(printf '%s\n' "$gates_text" | grep -c 'run_xray_mixed.sh')"
assert_eq "the memory job drives the permitted target" 1 \
    "$(grep -c 'target-host 192.0.2.1' "$ROOT/.github/workflows/ci.yml")"
# A target bound only to the permitted address would make the boundary case pass
# because nothing was listening at the denied one.
assert_eq "the duplex target answers at the denied address too" 4 \
    "$(printf '%s\n' "$gates_text" | grep -c 'duplex_target.py --host 0.0.0.0 --host6 ::')"
# The control above covers the literal address. The hostname case had none, and
# socks5_denied_destination reads a non-zero reply, a closed peer, an OSError and
# post-grant silence all as "refused" -- so "Xray cannot resolve this name" and
# "the boundary refused it" were the same observation, and the case would pass for
# the wrong reason. The probe now reaches the denied endpoint directly, by address
# and by name, before asserting either refusal. Both the probe's control and the
# gate's requirement that it ran are pinned: either can be dropped alone.
_boundary_probe=$(cat "$ROOT/tests/protocol/xray_mixed.py")
assert_contains "the probe reaches the denied address without the proxy" \
    'direct_control(denied)' "$_boundary_probe"
assert_contains "the probe reaches the denied hostname without the proxy" \
    'direct_control(denied_by_name)' "$_boundary_probe"
assert_eq "the mixed gate requires HTTP CONNECT to have run" 1 \
    "$(grep -c 'mixed_http_connect=ok' "$ROOT/tests/protocol/run_xray_mixed.sh")"
assert_eq "the mixed gate requires the boundary control to have run" 1 \
    "$(grep -c 'mixed_denied_control=ok' "$ROOT/tests/protocol/run_xray_mixed.sh")"
# Presence is not order: a control that runs after the refusal it is meant to
# qualify proves nothing about that refusal.
_boundary_control_line=$(grep -n 'direct_control(denied_by_name)' \
    "$ROOT/tests/protocol/xray_mixed.py" | head -n 1 | cut -d: -f1)
_boundary_refusal_line=$(grep -n 'atyp="hostname"' \
    "$ROOT/tests/protocol/xray_mixed.py" | head -n 1 | cut -d: -f1)
if [ -n "$_boundary_control_line" ] && [ -n "$_boundary_refusal_line" ] && [ "$_boundary_control_line" -lt "$_boundary_refusal_line" ]; then
    t_ok
else
    t_bad "the hostname control must run before the hostname refusal is asserted (control at ${_boundary_control_line:-none}, refusal at ${_boundary_refusal_line:-none})"
fi

# SPEC 6:228 lists "one long-lived framed bidirectional tunnel" as a case apart
# from 6:229's "idle then resume". Both used to ride the same tunnel_once path
# (count=4, idle=True), whose only long element was a 4s sleep, so the long-lived
# case was never exercised on its own. It now runs as a distinct case that holds
# one socket open across many frames spaced over time, and prints its own marker.
# Probe emission and gate requirements are independent: either can be dropped alone.
# The marker records the behavior rather than its function name.
assert_contains "the long-lived case prints its own marker" \
    'mixed_longlived=ok' "$_boundary_probe"
assert_eq "the mixed gate requires the long-lived tunnel to have run" 1 \
    "$(grep -c 'mixed_longlived=ok' "$ROOT/tests/protocol/run_xray_mixed.sh")"
for _dcconcurrency in 1 32 128; do
    assert_eq "the mixed gate requires $_dcconcurrency concurrent tunnels" 1 \
        "$(grep -c "mixed_concurrency_$_dcconcurrency=ok" "$ROOT/tests/protocol/run_xray_mixed.sh")"
done
assert_contains "the probe emits concurrency completion markers" \
    'mixed_concurrency_%d=ok' "$_boundary_probe"
assert_contains "the protocol job consumes a listener-verified ready marker" \
    'test -s "$root/out/ready"' "$ci_text"

# On ubuntu-24.04 /bin/sh is dash, so bash needs its own matrix leg to cover the
# /bin/sh implementation used by the supported EL family.
for _dcshell in 'command: sh' 'command: dash' 'command: bash' 'command: busybox sh'; do
    assert_contains "the unit matrix runs $_dcshell" "$_dcshell" "$ci_text"
done
_docrepo=https://github.com/91sexboy/One-click-socks5-proxy-setup
for _doc in README.md README.zh-CN.md; do
    _doctext=$(cat "$ROOT/$_doc")
    assert_contains "$_doc links the CI badge to the project" \
        "[![CI — xray-only]($_docrepo/actions/workflows/ci.yml/badge.svg?branch=xray-only)]($_docrepo)" "$_doctext"
    case "$_doc" in
    README.md) _doclanguage='[简体中文](README.zh-CN.md)' ;;
    README.zh-CN.md) _doclanguage='[English](README.md)' ;;
    esac
    assert_contains "$_doc links to the other language" "$_doclanguage" "$_doctext"
    assert_contains "$_doc links to the verified local release mirror" \
        "($_docrepo/releases/tag/xray-v26.3.27)" "$_doctext"
done

t_summary
