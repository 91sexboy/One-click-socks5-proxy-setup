#!/bin/sh
# The Alpine/OpenRC lifecycle gate, run inside the container by ci.yml.
#
# It lived inline as one single-quoted docker run argument, where a single
# apostrophe in a comment closed the argument and handed the rest to the host
# shell. That broke the gate twice and needed an oracle counting apostrophes to
# hold it. As a file it is ordinary shell, read by the lint job's sh -n (dash
# on the runner) and shellcheck like any other script in this directory, and
# executed by BusyBox ash inside the container.
set -eu
# shellcheck source=.github/scripts/lifecycle-common.sh
. "$(dirname "$0")/lifecycle-common.sh"
apk add --no-cache openrc >/dev/null
mkdir -p /run/openrc
touch /run/openrc/softlevel
rc-status -a >/dev/null 2>&1 || true
umask 077
work=$(mktemp -d)
capacity_mounted=0
alpine_cleanup() {
    if [ "$capacity_mounted" = 1 ]; then
        rc-service xray-socks5 stop >/dev/null 2>&1 || true
        umount /usr/local/libexec || true
    fi
    rm -rf "$work"
}
trap alpine_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
lifecycle_write_fixtures "$work"
original_path=$PATH
if [ "${ALPINE_HOSTILE_CURL:-0}" = 1 ]; then
    mkdir "$work/hostile-bin"
    ALPINE_HOSTILE_CURL_LOG=$work/hostile-curl.calls
    export ALPINE_HOSTILE_CURL_LOG
    cat >"$work/hostile-bin/curl" <<'HOSTILE_CURL'
#!/bin/sh
printf 'called\n' >>"$ALPINE_HOSTILE_CURL_LOG"
exit 99
HOSTILE_CURL
    chmod 0755 "$work/hostile-bin/curl"
    PATH=$work/hostile-bin:$PATH
    export PATH
fi
if apk info -e unzip >/dev/null 2>&1; then
    printf 'base image unexpectedly contains the unzip package\n' >&2
    exit 1
fi
pkgs_before_install=$(apk info | sort | sha256sum)
# A bare Alpine container has no syslog endpoint. The installer must expose that
# fact rather than letting logger discard Xray diagnostics silently.
test ! -e /dev/log
sh .github/scripts/run-socks5.sh install \
    "$work/answers" "$work/install.log" "$work/pass"
test "$(grep -cF '/dev/log' "$work/install.log")" = 1
if apk info -e unzip >/dev/null 2>&1; then
    printf 'raw installation added an unnecessary unzip package\n' >&2
    exit 1
fi
test "$(stat -c "%U:%G %a" /etc/init.d/xray-socks5)" = "root:root 755"
test "$(stat -c "%U:%G %a" /etc/xray-socks5/config.json)" = "root:xray-socks5 640"
test "$(stat -c "%U:%G %a" /var/lib/xray-socks5/state)" = "root:root 600"
test "$(wc -c </usr/local/libexec/xray-socks5/xray | tr -cd '0-9')" = 36577406
test "$(sha256sum /usr/local/libexec/xray-socks5/xray | awk '{print $1}')" = \
    8255dd939c34cf966cc91517b6324dd3c8d0bcf49ffac8beca049a38c46845ed
if [ "${ALPINE_HOSTILE_CURL:-0}" = 1 ]; then
    test ! -e "$ALPINE_HOSTILE_CURL_LOG"
    if "$work/hostile-bin/curl" --version >/dev/null 2>&1; then
        printf "the hostile curl wrapper unexpectedly succeeded\n" >&2
        exit 1
    fi
    test -s "$ALPINE_HOSTILE_CURL_LOG"
    rm -f "$ALPINE_HOSTILE_CURL_LOG"
    PATH=$original_path
    unset ALPINE_HOSTILE_CURL_LOG original_path
    export PATH
fi

# Exercise upgrade, not only fresh generation: make the installed OpenRC
# artifact and its recorded digest a self-consistent pre-fix installation with
# one respawn. Updating must transactionally migrate both back to the new policy.
sed 's/^respawn_max=2$/respawn_max=1/' /etc/init.d/xray-socks5 >"$work/legacy.unit"
cat "$work/legacy.unit" >/etc/init.d/xray-socks5
chmod 0755 /etc/init.d/xray-socks5
legacy_unit_sha=$(sha256sum /etc/init.d/xray-socks5 | awk '{print $1}')
awk -F '\t' -v h="$legacy_unit_sha" 'BEGIN {OFS="\t"} $1=="unit_sha256" {$2=h} {print}' \
    /var/lib/xray-socks5/state >"$work/legacy.state"
cat "$work/legacy.state" >/var/lib/xray-socks5/state
chmod 0600 /var/lib/xray-socks5/state
grep -qxF 'respawn_max=1' /etc/init.d/xray-socks5
grep -qxF "unit_sha256	$legacy_unit_sha" /var/lib/xray-socks5/state

# SPEC 5: re-running install over an existing installation is an
# in-place update. Rotate the credentials, keep the port, migrate the service
# policy, and require the new identity/digest in config and state.
sh .github/scripts/run-socks5.sh install \
    "$work/answers.update" "$work/update.log" "$work/pass.update" "$work/pass"
test "$(grep -cF '/dev/log' "$work/update.log")" = 1
test ! -e /dev/log
grep -qxF 'respawn_max=2' /etc/init.d/xray-socks5
updated_unit_sha=$(sha256sum /etc/init.d/xray-socks5 | awk '{print $1}')
test "$updated_unit_sha" != "$legacy_unit_sha"
grep -qxF "unit_sha256	$updated_unit_sha" /var/lib/xray-socks5/state
sh .github/scripts/lifecycle-update-assert.sh
rc-service xray-socks5 status
pkgs_after_install=$(apk info | sort | sha256sum)
printf 'openrc: package-set before-install=%s after-install=%s\n' \
    "$pkgs_before_install" "$pkgs_after_install"
sh .github/scripts/run-socks5.sh status \
    "$work/answers.empty" "$work/status.log" "$work/pass.update" "$work/pass"
sh .github/scripts/run-socks5.sh restart \
    "$work/answers.empty" "$work/restart.log" "$work/pass.update" "$work/pass"
rc-service xray-socks5 status
# Healthy, stopped and unverified status are informational; only an explicit
# OpenRC crash is nonzero, so this healthy case needs output evidence.
lifecycle_assert_ready_status "$work/status.log" 23456
# SPEC 5: OpenRC recovers two rapid ordinary crashes with the listener
# returning, while a configuration error remains bounded below. Record the
# window so a slow runner cannot accidentally issue the second kill after the
# configured 60-second retry period and make a broken counter look healthy.
crash_window_started=$(date +%s)
crash_pid=$(cat /run/openrc/options/xray-socks5/child_pid)
test "$crash_pid" -gt 0
kill -9 "$crash_pid"
new_pid=0
crash_recovered() {
    new_pid=$(cat /run/openrc/options/xray-socks5/child_pid 2>/dev/null || printf 0)
    test "$new_pid" != "$crash_pid" && test "$new_pid" -gt 0
}
# The assertions below remain authoritative after the final sleep.
lifecycle_wait_until 45 1 crash_recovered || true
test "$new_pid" != "$crash_pid"
test "$new_pid" -gt 0
listener_recovered() {
    ss -H -ltnp 2>/dev/null | grep -q "pid=$new_pid,"
}
lifecycle_wait_until 45 1 listener_recovered || true
ss -H -ltnp | grep -q "pid=$new_pid,"

# The second death is deliberately inside the same retry period. With the old
# historical respawn_max=1 policy no second replacement child appeared. The
# migrated policy grants exactly this second recoverable respawn.
crash_pid=$new_pid
new_pid=0
kill -9 "$crash_pid"
lifecycle_wait_until 45 1 crash_recovered || true
test "$new_pid" != "$crash_pid"
test "$new_pid" -gt 0
lifecycle_wait_until 45 1 listener_recovered || true
ss -H -ltnp | grep -q "pid=$new_pid,"
test "$(( $(date +%s) - crash_window_started ))" -lt 60

# SPEC 5: a third death inside the same period spends the respawn budget. On
# every tested Alpine release supervise-daemon then gives up and OpenRC records
# the service as stopped (status 3), not crashed, so socks5.sh status reports
# it stopped without failing, and restart starts it again.
crash_pid=$new_pid
kill -9 "$crash_pid"
rc_status=0
openrc_state_is() {
    rc_status=0
    rc-service xray-socks5 status >/dev/null 2>&1 || rc_status=$?
    test "$rc_status" = "$1"
}
lifecycle_wait_until 20 1 openrc_state_is 3 || true
if ! openrc_state_is 3; then
    printf 'a spent respawn budget left rc-service status %s, expected 3\n' "$rc_status" >&2
    exit 1
fi
test "$(( $(date +%s) - crash_window_started ))" -lt 60
sh .github/scripts/run-socks5.sh status \
    "$work/answers.empty" "$work/spent-status.log" "$work/pass.update" "$work/pass"
grep -qF 'service: stopped; port: 23456;' "$work/spent-status.log"
sh .github/scripts/run-socks5.sh restart \
    "$work/answers.empty" "$work/spent-restart.log" "$work/pass.update" "$work/pass"
rc-service xray-socks5 status
printf 'openrc: spent-budget-stopped-ok\n'

# A supervisor killed outright leaves its child record behind, which
# supervise-daemon's status reports as unsupervised (64); crashed (32) is the
# same loss after that record was cleared. Kill the supervisor, then its child,
# so nothing of ours is left: status must name the state and fail, and
# socks5.sh restart must recover what OpenRC's own restart cannot stop.
supervisor_pid=$(cat /run/xray-socks5.pid)
crash_pid=$(cat /run/openrc/options/xray-socks5/child_pid)
test "$supervisor_pid" -gt 0
test "$crash_pid" -gt 0
kill -9 "$supervisor_pid"
kill -9 "$crash_pid"
lifecycle_wait_until 20 1 openrc_state_is 64 || true
if ! openrc_state_is 64; then
    printf 'a dead supervisor left rc-service status %s, expected 64\n' "$rc_status" >&2
    exit 1
fi
crashed_status=0
sh .github/scripts/run-socks5.sh status \
    "$work/answers.empty" "$work/crashed-status.log" "$work/pass.update" "$work/pass" ||
    crashed_status=$?
lifecycle_assert_exited_status "$crashed_status" "$work/crashed-status.log" unsupervised 23456
grep -qxF 'Xray is not listening on port 23456.' "$work/crashed-status.log"
test ! -e /run/xray-socks5.lock
printf 'openrc: unsupervised-status-ok\n'
sh .github/scripts/run-socks5.sh restart \
    "$work/answers.empty" "$work/crashed-restart.log" "$work/pass.update" "$work/pass"
rc-service xray-socks5 status
restarted_pid=$(cat /run/openrc/options/xray-socks5/child_pid)
test "$restarted_pid" -gt 0
test "$restarted_pid" != "$crash_pid"
ss -H -ltnp | grep -q "pid=$restarted_pid,"
printf 'openrc: unsupervised-restart-ok\n'
cp /etc/xray-socks5/config.json "$work/good.json"
printf "{broken\n" >/etc/xray-socks5/config.json
# First prove the real pinned Xray classifies this exact configuration as exit
# 23. The supervisor is count-bounded rather than exit-code-aware, so a temporary
# transparent counter wrapper then execs the real binary and records every native
# supervise-daemon attempt.
broken_status=0
/usr/local/libexec/xray-socks5/xray run -c /etc/xray-socks5/config.json \
    >"$work/broken.log" 2>&1 || broken_status=$?
if test "$broken_status" != 23; then
    printf "a broken config exited %s, expected 23\n" "$broken_status" >&2
    cat "$work/broken.log" >&2
    exit 1
fi
rc-service xray-socks5 stop
mv /usr/local/libexec/xray-socks5/xray \
    /usr/local/libexec/xray-socks5/.xray-exit23-real
attempts=/run/xray-socks5-exit23-attempts
: >"$attempts"
chown xray-socks5:xray-socks5 "$attempts"
chmod 0600 "$attempts"
cat >/usr/local/libexec/xray-socks5/xray <<'EXIT23_WRAPPER'
#!/bin/sh
attempts=/run/xray-socks5-exit23-attempts
count=$(cat "$attempts" 2>/dev/null || printf 0)
printf '%s\n' "$((count + 1))" >"$attempts"
exec /usr/local/libexec/xray-socks5/.xray-exit23-real "$@"
EXIT23_WRAPPER
chmod 0755 /usr/local/libexec/xray-socks5/xray
rc-service xray-socks5 start || true

three_attempts_and_stopped() {
    test "$(cat "$attempts" 2>/dev/null || printf 0)" = 3 &&
        ! rc-service xray-socks5 status >/dev/null 2>&1
}
lifecycle_wait_until 20 1 three_attempts_and_stopped || true
if ! three_attempts_and_stopped; then
    printf "bad-config attempts=%s; expected exactly 3 and stopped\n" \
        "$(cat "$attempts" 2>/dev/null || printf 0)" >&2
    exit 1
fi
for n in $(seq 1 5); do
    if ss -H -ltn 2>/dev/null | grep -q ":23456 "; then
        printf "a broken config produced a listener\n" >&2
        exit 1
    fi
    if rc-service xray-socks5 status >/dev/null 2>&1; then
        printf "a broken config brought the service back up\n" >&2
        exit 1
    fi
    test "$(cat "$attempts")" = 3
    sleep 1
done
if rc-service xray-socks5 status >/dev/null 2>&1; then
    printf "a broken config was active after the stable window\n" >&2
    exit 1
fi
printf 'openrc: bad-config attempts=%s, stopped, and stable\n' "$(cat "$attempts")"
rm -f /usr/local/libexec/xray-socks5/xray
mv /usr/local/libexec/xray-socks5/.xray-exit23-real \
    /usr/local/libexec/xray-socks5/xray
rm -f "$attempts"
# Redirection truncates in place, so the config keeps the owner and
# mode the installer gave it. BusyBox cp replaces the destination and
# would hand it the private attributes of the backup copy.
cat "$work/good.json" >/etc/xray-socks5/config.json
test "$(stat -c "%U:%G %a" /etc/xray-socks5/config.json)" = "root:xray-socks5 640"
rc-service xray-socks5 restart
rc-service xray-socks5 status
sh tests/protocol/post_install_audit.sh / "$work/pass.update" openrc
# SPEC 7: credentials reach neither argv nor the service environment.
live_pid=$(cat /run/openrc/options/xray-socks5/child_pid)
lifecycle_process_clean "$live_pid" "$work" "$work/pass" "$work/pass.update"
# SPEC 6: independent SOCKS5 and HTTP verification, separate from the
# data-plane check the installer runs itself. The target binds every
# address so it answers at both the permitted 192.0.2.1 and the denied
# 127.0.0.1, which is what makes a boundary bypass visible.
sh .github/scripts/add-test-target-addresses.sh
python3 tests/protocol/duplex_target.py --host 0.0.0.0 --host6 :: \
    --ready-file "$work/target.port" \
    --count-file "$work/count" --report-file "$work/report" >"$work/target.log" 2>&1 &
lifecycle_wait_until 50 0.2 test -s "$work/target.port" || true
test -s "$work/target.port"
test "$(python3 -c 'import json; print(json.load(open("/etc/xray-socks5/config.json"))["inbounds"][0]["listen"])')" = 0.0.0.0
PROXY_HOST=192.0.2.1 PASSFILE="$work/pass.update" PORT=23456 TARGET_PORT="$(cat "$work/target.port")" \
    REPORT="$work/report" OUT="$work/probe" \
    sh tests/protocol/run_xray_mixed.sh
sh .github/scripts/run-socks5.sh uninstall \
    "$work/answers.uninstall" "$work/uninstall.log" "$work/pass.update" "$work/pass"
test "$(apk info | sort | sha256sum)" = "$pkgs_after_install"
test ! -e /etc/xray-socks5
test ! -e /var/lib/xray-socks5
test ! -e /usr/local/libexec/xray-socks5
test ! -e /etc/init.d/xray-socks5
test ! -e /run/xray-socks5.pid
if getent passwd xray-socks5 >/dev/null 2>&1 || getent group xray-socks5 >/dev/null 2>&1; then exit 1; fi
sh .github/scripts/run-socks5.sh uninstall \
    "$work/answers.uninstall" "$work/uninstall-second.log" "$work/pass.update" "$work/pass"
python3 tests/protocol/terminal_install.py \
    "$work/answers.reinstall" "$work/pass" 23456 0 >"$work/reinstall.log"
sh .github/scripts/run-socks5.sh uninstall \
    "$work/answers.uninstall" "$work/uninstall-reinstall.log" "$work/pass"
# The Alpine 3.22 quota-blind row runs the production writer seam with a
# deterministic short-write injection. The focused asset suite proves that
# statfs can report ample capacity while direct raw download writing fails and
# that the prefix-local partial candidate is reclaimed.
# Run it only after uninstall so any namespace residue is attributable to the
# regression itself rather than the real lifecycle above.
if [ "${ALPINE_QUOTA_BLIND:-0}" = 1 ]; then
    S5_REPO_ROOT=$PWD sh tests/unit/test_xray_asset.sh \
        >"$work/quota-blind.log" 2>&1
    grep -Eq '^TESTS [1-9][0-9]* 0$' "$work/quota-blind.log"
    grep -qxF 'SKIPS 0' "$work/quota-blind.log"
    lifecycle_generation_absent "$work/quota-blind.log" "$work/pass"
    lifecycle_generation_absent "$work/quota-blind.log" "$work/pass.update"
    test ! -e /usr/local/libexec/xray-socks5
    test ! -e /etc/xray-socks5
    test ! -e /var/lib/xray-socks5
    test ! -e /etc/init.d/xray-socks5
    test ! -e /run/xray-socks5.pid
    if getent passwd xray-socks5 >/dev/null 2>&1 ||
            getent group xray-socks5 >/dev/null 2>&1; then
        exit 1
    fi
    if find /usr/local/libexec -type f -name '.xray.*' -print -quit 2>/dev/null |
            grep -q .; then
        printf 'quota-blind regression left a prefix-local candidate\n' >&2
        exit 1
    fi
    if find /tmp /var/tmp -maxdepth 1 -type d -name 's5test.*' -print -quit 2>/dev/null |
            grep -q .; then
        printf 'quota-blind regression left test or short-write scratch\n' >&2
        exit 1
    fi
fi
sh socks5.sh help </dev/null >"$work/help-after-uninstall.log"
grep -q 'Usage: sh socks5.sh' "$work/help-after-uninstall.log"
# The raw candidate is downloaded directly under the install prefix. A 40-MiB
# filesystem is too small for the old ~90-MiB path but large enough for the
# 35,721-KiB amd64 candidate; a 32-MiB filesystem must fail with that exact need.
test "$(stat -f -c '%f %S' / | awk '{print ($1 > 0 && $2 > 0) ? "ok" : "bad"}')" = ok
test "$(stat -c '%d' / | awk '{print ($1 > 0) ? "ok" : "bad"}')" = ok
mkdir -p /usr/local/libexec
mount -t tmpfs -o size=40m,mode=755 tmpfs /usr/local/libexec
capacity_mounted=1
sh .github/scripts/run-socks5.sh install \
    "$work/answers.reinstall" "$work/capacity-success.log" "$work/pass"
sh .github/scripts/run-socks5.sh uninstall \
    "$work/answers.uninstall" "$work/capacity-success-uninstall.log" "$work/pass"
umount /usr/local/libexec
capacity_mounted=0
mount -t tmpfs -o size=32m,mode=755 tmpfs /usr/local/libexec
capacity_mounted=1
capacity_status=0
sh .github/scripts/run-socks5.sh install \
    "$work/answers.reinstall" "$work/capacity.log" "$work/pass" || capacity_status=$?
umount /usr/local/libexec
capacity_mounted=0
test "$capacity_status" -ne 0
grep -q 'not enough space on the filesystem holding' "$work/capacity.log"
grep -q '35721 KiB required' "$work/capacity.log"
test ! -e /usr/local/libexec/xray-socks5
test ! -e /etc/xray-socks5
test ! -e /var/lib/xray-socks5
lifecycle_generation_absent "$work/capacity-success.log" "$work/pass"
lifecycle_generation_absent "$work/capacity-success-uninstall.log" "$work/pass"
lifecycle_generation_absent "$work/capacity.log" "$work/pass"
lifecycle_assert_logs_redacted "$work"
