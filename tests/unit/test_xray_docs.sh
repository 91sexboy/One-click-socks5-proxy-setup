#!/bin/sh
# Workflow wiring, lint coverage and native lifecycle assertion contracts.

S5T_NAME=test_xray_docs
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
ROOT=${S5_REPO_ROOT}
t_mktestroot

CI=$ROOT/.github/workflows/ci.yml
ci_text=$(cat "$CI")
ALPINE_GATE=$ROOT/.github/scripts/alpine-lifecycle.sh
alpine_text=$(cat "$ALPINE_GATE")
SYSTEMD_GATE=$ROOT/.github/scripts/systemd-lifecycle.sh
systemd_text=$(cat "$SYSTEMD_GATE")
gates_text=$(printf '%s\n%s\n' "$systemd_text" "$alpine_text")
workflow_oracle=$(cat "$ROOT/.github/scripts/check-workflow.py")

for _entry in 'python3 .github/scripts/check-workflow.py .github/workflows/ci.yml' \
    'python3 tests/lib/workflow_contract_regression.py' \
    'python3 -O tests/lib/workflow_contract_regression.py'; do
    assert_contains "the lint job executes $_entry" "$_entry" "$ci_text"
done
for _contract in timeout-minutes continue-on-error CHECKOUT UPLOADER RUNNERS LIFECYCLE_ROWS CONTROL_IMAGES MUTATIONS \
    'matrix.shell.command' 'memory-report.sh' 'run_xray_mixed.sh' 'lifecycle-assert-control.py'; do
    assert_contains "the parsed workflow oracle covers $_contract" "$_contract" "$workflow_oracle"
done
assert_not_contains "the workflow oracle does not lose assertions under optimization" \
    'assert ' "$workflow_oracle"
assert_contains "shellcheck is pinned, not taken from the distro" \
    'shellcheck-v0.10.0' "$ci_text"
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
assert_contains "the lint job checks the workflow's own inline shell" \
    'lint-workflow-shell.sh' "$ci_text"
_wfltext=$(cat "$ROOT/.github/scripts/lint-workflow-shell.sh")
assert_contains "the inline-shell linter runs the syntax check" 'sh -n "$f"' "$_wfltext"
assert_contains "the inline-shell linter runs shellcheck" 'shellcheck -s sh' "$_wfltext"
assert_contains "the inline-shell linter fails when it extracts nothing" \
    'no inline run blocks were extracted' "$_wfltext"
if command -v git >/dev/null 2>&1 && [ -e "$ROOT/.git" ]; then
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
_defused=$(grep -n 'grep -q' "$CI" "$SYSTEMD_GATE" "$ALPINE_GATE" \
    "$ROOT/.github/scripts/memory-report.sh" | grep '|| true' | grep -v '&& exit' || true)
if [ -z "$_defused" ]; then
    t_ok
else
    t_bad "a CI gate has a grep check defused by || true: $_defused"
fi

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
assert_contains "Alpine gate keeps credentials out of argv" '/proc/$live_pid/cmdline' "$alpine_text"
assert_contains "Alpine gate keeps credentials out of the environment" '/proc/$live_pid/environ' "$alpine_text"
assert_contains "Alpine gate snapshots packages before installation" \
    'pkgs_before_install=$(apk info | sort | sha256sum)' "$alpine_text"
assert_contains "Alpine gate records its package-set baseline" \
    'openrc: package-set before-install=%s after-install=%s' "$alpine_text"
assert_contains "Alpine gate proves uninstall retains installed dependencies" \
    'test "$(apk info | sort | sha256sum)" = "$pkgs_after_install"' "$alpine_text"
assert_contains "Alpine gate restores the config in place" \
    'cat "$work/good.json" >/etc/xray-socks5/config.json' "$alpine_text"
assert_contains "systemd gate restores the config in place" 'cat "$1" >"$2"' "$systemd_text"
assert_not_contains "no gate restores the config with cp" \
    'cp "$work/good.json" /etc/xray-socks5/config.json' "$gates_text"
assert_eq "Alpine preserves config owner and mode after install and restore" 2 \
    "$(printf '%s\n' "$alpine_text" | grep -c 'root:xray-socks5 640')"
assert_eq "systemd preserves config owner and mode after restore" 1 \
    "$(printf '%s\n' "$systemd_text" | grep -c 'root:xray-socks5 640')"
assert_not_contains "the Alpine lifecycle body is not inlined in the YAML" \
    'apk add --no-cache openrc' "$ci_text"
assert_contains "the lifecycle script is what installs OpenRC" \
    'apk add --no-cache openrc' "$alpine_text"
assert_contains "Alpine lifecycle injects a hostile unzip PATH control" \
    'hostile-bin/unzip' "$alpine_text"
assert_contains "Alpine lifecycle pins the installed Xray byte count" \
    '= 36577406' "$alpine_text"
assert_contains "Alpine lifecycle pins the installed Xray digest" \
    '8255dd939c34cf966cc91517b6324dd3c8d0bcf49ffac8beca049a38c46845ed' \
    "$alpine_text"
assert_contains "Alpine lifecycle proves the hostile unzip was bypassed" \
    'test ! -e "$ALPINE_HOSTILE_UNZIP_LOG"' "$alpine_text"
assert_contains "Alpine 3.22 enables quota-blind extraction coverage" \
    'quota_blind: "1"' "$ci_text"
assert_contains "the quota-blind matrix flag reaches the container" \
    '-e ALPINE_QUOTA_BLIND="$ALPINE_QUOTA_BLIND"' "$ci_text"
assert_contains "the quota-blind row runs the production-seam asset regressions" \
    'S5_REPO_ROOT=$PWD sh tests/unit/test_xray_asset.sh' "$alpine_text"
assert_contains "quota-blind lifecycle rejects failed regression assertions" \
    "grep -Eq '^TESTS [1-9][0-9]* 0$'" "$alpine_text"
assert_contains "quota-blind lifecycle rechecks lifecycle log redaction" \
    'lifecycle_assert_logs_redacted "$work"' "$alpine_text"
assert_contains "quota-blind regression log is checked against the install credential" \
    'lifecycle_generation_absent "$work/quota-blind.log" "$work/pass"' "$alpine_text"
assert_contains "quota-blind regression log is checked against the update credential" \
    'lifecycle_generation_absent "$work/quota-blind.log" "$work/pass.update"' "$alpine_text"
assert_contains "quota-blind lifecycle rejects leftover extraction FIFOs" \
    "-name '.xray-stream.*'" "$alpine_text"
assert_contains "quota-blind lifecycle rechecks namespace removal" \
    'test ! -e /usr/local/libexec/xray-socks5' "$alpine_text"
# An untouched log is only evidence that the installer bypassed the wrapper if the
# wrapper would have corrupted what it extracted and would have recorded the call.
# The positive control extracts one local member both ways and requires the bytes
# to differ; without these four lines it could lapse into proving neither.
assert_contains "Alpine lifecycle extracts the control member through clean Info-ZIP" \
    '/usr/bin/unzip -p "$work/control.zip" xray >"$work/control.clean"' "$alpine_text"
assert_contains "Alpine lifecycle extracts the same member through the hostile wrapper" \
    '"$work/hostile-bin/unzip" -p "$work/control.zip" xray >"$work/control.hostile"' "$alpine_text"
assert_contains "Alpine lifecycle proves the hostile wrapper records its invocations" \
    'test -s "$ALPINE_HOSTILE_UNZIP_LOG"' "$alpine_text"
assert_contains "Alpine lifecycle fails when the hostile wrapper corrupts nothing" \
    'if cmp -s "$work/control.clean" "$work/control.hostile"; then' "$alpine_text"
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
assert_contains "shared update assertion requires the install directory owner and mode" \
    'root:root 755' "$update_assert_text"
assert_contains "native assertion controls retain their behavioral regression" \
    'lifecycle_control_regression.py' "$(cat "$ROOT/tests/unit/test_xray_lifecycle_assert.sh")"
assert_contains "update diagnostics filter both known credential generations" \
    '"$work/answers.update" "$work/update.log" "$work/pass.update" "$work/pass"' "$systemd_text"
assert_contains "uninstall diagnostics filter the rotated and previous credentials" \
    '"$work/answers.uninstall" "$work/uninstall.log" "$work/pass.update" "$work/pass"' "$systemd_text"
audit_text=$(cat "$ROOT/tests/protocol/post_install_audit.sh")
assert_contains "the audit accepts an init backend" 'INIT=${3:-systemd}' "$audit_text"
assert_contains "the audit knows the OpenRC artifact" 'unit="$ROOT/etc/init.d/xray-socks5"' "$audit_text"
assert_contains "the lifecycle job kills the service to prove recovery" \
    'sudo kill -9 "$crash_pid"' "$systemd_text"
assert_contains "the lifecycle job proves the exit-23 restart guard" 'ExecMainStatus' "$systemd_text"
assert_contains "the Alpine gate requires the configuration error to exit 23" \
    'if test "$broken_status" != 23' "$alpine_text"
assert_contains "the Alpine gate requires no respawn after a configuration error" \
    'if test "$respawn_after" != "$respawn_before"' "$alpine_text"
assert_contains "the Alpine gate requires the service to stay down" \
    'a broken config brought the service back up' "$alpine_text"
assert_contains "the Alpine gate records the observed child_pid values" \
    'openrc: child_pid %s then %s' "$alpine_text"
assert_contains "OpenRC adds target addresses inside its native container" \
    'sh .github/scripts/add-test-target-addresses.sh' "$alpine_text"
assert_eq "both native gates run the mixed gate" 2 \
    "$(printf '%s\n' "$gates_text" | grep -c 'run_xray_mixed.sh')"
assert_eq "both native duplex targets answer at denied addresses too" 2 \
    "$(printf '%s\n' "$gates_text" | grep -c 'duplex_target.py --host 0.0.0.0 --host6 ::')"

assert_eq "both native gates prove the configured production listen address" 2 \
    "$(printf '%s\n' "$gates_text" | grep -c '\["inbounds"\]\[0\]\["listen"\]')"
assert_eq "both native gates connect through the nonloopback proxy address" 2 \
    "$(printf '%s\n' "$gates_text" | grep -c 'PROXY_HOST=192.0.2.1')"
assert_eq "both native gates prove idempotent second uninstall" 2 \
    "$(printf '%s\n' "$gates_text" | grep -c 'uninstall-second.log')"
assert_contains "systemd proves a fresh reinstall without a language prompt" \
    '"$work/answers.reinstall" "$work/pass" "$work/reinstall.log"' "$systemd_text"
assert_contains "OpenRC proves a fresh reinstall without a language prompt" \
    '"$work/answers.reinstall" "$work/pass" 23456 0' "$alpine_text"

assert_contains "OpenRC install uses the shared redacting command runner" \
    'run-socks5.sh install' "$alpine_text"
assert_contains "systemd fixture credentials become root-owned before execution" \
    'sudo chown root:root "$work"/answers* "$work"/pass*' "$systemd_text"
assert_contains "systemd protocol gate reads the root-only passfile as root" \
    'sudo env PROXY_HOST=192.0.2.1 PASSFILE="$work/pass"' "$systemd_text"

assert_contains "systemd parses the protected production config as root" \
    'sudo python3 -c' "$systemd_text"

assert_contains "systemd removes root-owned probe scratch before workdir cleanup" \
    'sudo rm -rf "$work/probe"' "$systemd_text"

t_summary
