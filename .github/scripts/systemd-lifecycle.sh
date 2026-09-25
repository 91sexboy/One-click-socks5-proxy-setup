#!/bin/sh
# The systemd lifecycle gate, run on the runner by ci.yml.
#
# Extracted from an inline `run:` block for the same reason as its OpenRC
# sibling: 129 lines of shell in YAML are read by nothing. As a file it goes
# through sh -n and shellcheck with every other script in this directory, which
# is how the Alpine extraction surfaced an early-expanding trap and two
# credential checks that could not fail.
set -eu
# shellcheck source=.github/scripts/lifecycle-common.sh
. "$(dirname "$0")/lifecycle-common.sh"
# shellcheck source=.github/scripts/lifecycle-target.sh
. "$(dirname "$0")/lifecycle-target.sh"
printf 'lifecycle: start\n'
work=$(mktemp -d)
printf 'lifecycle: workdir-ready\n'
lifecycle_cleanup_namespace() {
  sh .github/scripts/remove-xray-namespace.sh
}
lifecycle_cleanup_init
chmod 0700 "$work"
lifecycle_write_fixtures "$work"
sudo chown root:root "$work"/answers* "$work"/pass*
sudo sh -c 'python3 tests/protocol/terminal_install.py "$1" "$2" 23456 1 >"$3"' \
  sh "$work/answers" "$work/pass" "$work/install.log"
printf 'lifecycle: install-ok\n'
sudo find /etc/xray-socks5 /var/lib/xray-socks5 /usr/local/libexec/xray-socks5 \
  -maxdepth 2 -printf '%M %u:%g %p\n' 2>&1 || true
test -e /etc/xray-socks5
printf 'lifecycle: config-dir-entry-ok\n'
sudo test -f /etc/xray-socks5/config.json
printf 'lifecycle: config-file-ok\n'
sudo test -f /var/lib/xray-socks5/state
printf 'lifecycle: state-file-ok\n'
sudo test -x /usr/local/libexec/xray-socks5/xray
printf 'lifecycle: binary-file-ok\n'
printf 'lifecycle: files-ok\n'
test "$(sudo stat -c '%a' /etc/xray-socks5/config.json)" = 640
test "$(sudo stat -c '%a' /var/lib/xray-socks5/state)" = 600
printf 'lifecycle: modes-ok\n'
sudo systemctl is-active --quiet xray-socks5.service
printf 'lifecycle: active-ok\n'
python3 - <<'PY'
import socket
s = socket.create_connection(('127.0.0.1', 23456), 5)
s.close()
PY
sudo sh .github/scripts/run-socks5.sh restart \
  "$work/answers.empty" "$work/restart.log" "$work/pass"
printf 'lifecycle: restart-command-ok\n'
sudo systemctl is-active --quiet xray-socks5.service
printf 'lifecycle: restart-active-ok\n'
# SPEC 5: systemd recovers a crash, and a configuration error exits 23
# without entering a restart loop.
restarts_before=$(systemctl show xray-socks5.service -p NRestarts --value)
crash_pid=$(systemctl show xray-socks5.service -p MainPID --value)
test "$crash_pid" -gt 0
sudo kill -9 "$crash_pid"
crash_recovered() {
  new_pid=$(systemctl show xray-socks5.service -p MainPID --value)
  test "$new_pid" != "$crash_pid" && test "$new_pid" -gt 0
}
# The assertions below also observe changes during the final sleep.
lifecycle_wait_until 60 1 crash_recovered || true
sudo systemctl is-active --quiet xray-socks5.service
test "$(systemctl show xray-socks5.service -p MainPID --value)" != "$crash_pid"
test "$(systemctl show xray-socks5.service -p NRestarts --value)" -gt "$restarts_before"
python3 - <<'PY'
import socket
sock = socket.create_connection(('127.0.0.1', 23456), 20)
sock.close()
PY
sudo cp /etc/xray-socks5/config.json "$work/good.json"
printf '{broken\n' | sudo tee /etc/xray-socks5/config.json >/dev/null
sudo systemctl restart xray-socks5.service || true
service_stopped() {
  if sudo systemctl is-active --quiet xray-socks5.service; then return 1; fi
}
lifecycle_wait_until 30 1 service_stopped || true
# set -e does not apply to a command a ! inverts, so `! systemctl is-active` did
# not fail the gate when the broken config left the service running: the check
# below was dead, and SPEC 5's guarantee was unproven on this backend.
if sudo systemctl is-active --quiet xray-socks5.service; then
  printf 'a broken config left the service running\n' >&2
  exit 1
fi
test "$(systemctl show xray-socks5.service -p ExecMainStatus --value)" = 23
loop_restarts=$(systemctl show xray-socks5.service -p NRestarts --value)
sleep 12
test "$(systemctl show xray-socks5.service -p NRestarts --value)" = "$loop_restarts"
sudo sh -c 'cat "$1" >"$2"' restore "$work/good.json" /etc/xray-socks5/config.json
test "$(sudo stat -c '%U:%G %a' /etc/xray-socks5/config.json)" = "root:xray-socks5 640"
sudo systemctl restart xray-socks5.service
sudo systemctl is-active --quiet xray-socks5.service
python3 tests/protocol/duplex_target.py --host 0.0.0.0 --host6 :: --ready-file "$work/target.port" --count-file "$work/count" --report-file "$work/report" >"$work/target.log" 2>&1 &
target_pid=$!
lifecycle_wait_until 50 0.1 test -s "$work/target.port" || true
target_port=$(cat "$work/target.port")
test "$(python3 -c 'import json; print(json.load(open("/etc/xray-socks5/config.json"))["inbounds"][0]["listen"])')" = 0.0.0.0
sudo env PROXY_HOST=192.0.2.1 PASSFILE="$work/pass" PORT=23456 TARGET_PORT="$target_port" \
  REPORT="$work/report" OUT="$work/probe" \
  sh tests/protocol/run_xray_mixed.sh
sudo sh tests/protocol/post_install_audit.sh / "$work/pass" systemd
printf 'lifecycle: audit-ok\n'
# SPEC 5: re-running install over an existing installation is an
# in-place update. Rotate the credentials, keep the port, and require
# the new identity in both the config and the state.
sudo sh .github/scripts/run-socks5.sh install \
  "$work/answers.update" "$work/update.log" "$work/pass.update" "$work/pass"
printf 'lifecycle: update-ok\n'
sudo sh .github/scripts/run-socks5.sh status \
  "$work/answers.empty" "$work/status.log" "$work/pass.update" "$work/pass"
printf 'lifecycle: status-ok\n'
sudo grep -q 'mixed' "$work/status.log"
printf 'lifecycle: status-content-ok\n'
sudo sh .github/scripts/lifecycle-update-assert.sh
sudo systemctl is-active --quiet xray-socks5.service
sudo sh tests/protocol/post_install_audit.sh / "$work/pass.update" systemd
printf 'lifecycle: update-audit-ok\n'
printf 'lifecycle: uninstall-preflight\n'
sudo systemctl is-active xray-socks5.service || true
sudo systemctl show xray-socks5.service -p MainPID -p ExecMainStatus -p NRestarts
sudo id xray-socks5
sudo stat -c '%M %U:%G %n' /etc/xray-socks5/config.json /var/lib/xray-socks5/state /usr/local/libexec/xray-socks5/xray
sudo find /etc/xray-socks5 /var/lib/xray-socks5 /usr/local/libexec/xray-socks5 -maxdepth 2 -printf '%M %U:%G %p\n'
sudo sh .github/scripts/run-socks5.sh uninstall \
  "$work/answers.uninstall" "$work/uninstall.log" "$work/pass.update" "$work/pass"
test ! -e /etc/xray-socks5
test ! -e /var/lib/xray-socks5
test ! -e /usr/local/libexec/xray-socks5
test ! -e /etc/systemd/system/xray-socks5.service
if sudo systemctl is-enabled --quiet xray-socks5.service; then exit 1; fi
if getent passwd xray-socks5 >/dev/null 2>&1 || getent group xray-socks5 >/dev/null 2>&1; then exit 1; fi
sudo sh .github/scripts/run-socks5.sh uninstall \
  "$work/answers.uninstall" "$work/uninstall-second.log" "$work/pass.update" "$work/pass"
# The repeated uninstall is idempotent; a fresh install must recreate the namespace.
sudo sh -c 'python3 tests/protocol/terminal_install.py "$1" "$2" 23456 0 >"$3"' \
  sh "$work/answers.reinstall" "$work/pass" "$work/reinstall.log"
sudo sh .github/scripts/run-socks5.sh uninstall \
  "$work/answers.uninstall" "$work/uninstall-reinstall.log" "$work/pass"
sudo sh -c 'sh socks5.sh help </dev/null >"$1"' sh "$work/help-after-uninstall.log"
sudo grep -q 'Usage: sh socks5.sh' "$work/help-after-uninstall.log"
lifecycle_assert_logs_redacted "$work" sudo
