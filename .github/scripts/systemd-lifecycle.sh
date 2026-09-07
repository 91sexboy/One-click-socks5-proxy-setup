#!/bin/sh
# The systemd lifecycle gate, run on the runner by ci.yml.
#
# Extracted from an inline `run:` block for the same reason as its OpenRC
# sibling: 129 lines of shell in YAML are read by nothing. As a file it goes
# through sh -n and shellcheck with every other script in this directory, which
# is how the Alpine extraction surfaced an early-expanding trap and two
# credential checks that could not fail.
set -eu
printf 'lifecycle: start\n'
work=$(mktemp -d)
printf 'lifecycle: workdir-ready\n'
cleanup() {
  rm -f "$work/pass" "$work/answers" "$work/target.log" "$work/install.log" "$work/status.log" "$work/restart.log" "$work/uninstall.log" "$work/pass.update" "$work/answers.update" "$work/update.log"
  sh .github/scripts/remove-xray-namespace.sh
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM
chmod 0700 "$work"
printf '2\ny\n23456\nciuser\nCISecret_123~x\n' >"$work/answers"
chmod 0600 "$work/answers"
printf '2\n' >"$work/answers.lang"
printf '2\ny\n' >"$work/answers.uninstall"
printf 'ciuser\nCISecret_123~x\n' >"$work/pass"
chmod 0600 "$work/pass"
sudo sh .github/scripts/run-socks5.sh install \
  "$work/answers" "$work/install.log" "$work/pass"
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
sudo sh .github/scripts/run-socks5.sh status \
  "$work/answers.lang" "$work/status.log" "$work/pass"
printf 'lifecycle: status-ok\n'
printf 'lifecycle: status-log='
sudo cat "$work/status.log" | tr '\n' ' '
printf '\n'
sudo grep -q 'mixed' "$work/status.log"
printf 'lifecycle: status-content-ok\n'
sudo sh .github/scripts/run-socks5.sh restart \
  "$work/answers.lang" "$work/restart.log" "$work/pass"
printf 'lifecycle: restart-command-ok\n'
sudo systemctl is-active --quiet xray-socks5.service
printf 'lifecycle: restart-active-ok\n'
# SPEC 5: systemd recovers a crash, and a configuration error exits 23
# without entering a restart loop.
restarts_before=$(systemctl show xray-socks5.service -p NRestarts --value)
crash_pid=$(systemctl show xray-socks5.service -p MainPID --value)
test "$crash_pid" -gt 0
sudo kill -9 "$crash_pid"
for n in $(seq 1 60); do
  new_pid=$(systemctl show xray-socks5.service -p MainPID --value)
  if test "$new_pid" != "$crash_pid" && test "$new_pid" -gt 0; then break; fi
  sleep 1
done
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
for n in $(seq 1 30); do
  sudo systemctl is-active --quiet xray-socks5.service || break
  sleep 1
done
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
for n in $(seq 1 50); do test -s "$work/target.port" && break; sleep 0.1; done
target_port=$(cat "$work/target.port")
PASSFILE="$work/pass" PORT=23456 TARGET_PORT="$target_port" \
  REPORT="$work/report" OUT="$work/probe" \
  sh tests/protocol/run_xray_mixed.sh
sudo sh tests/protocol/post_install_audit.sh / "$work/pass" systemd
printf 'lifecycle: audit-ok\n'
# SPEC 5: re-running install over an existing installation is an
# in-place update. Rotate the credentials, keep the port, and require
# the new identity in both the config and the state.
printf '2\ny\n23456\nciuser2\nCISecret_456~y\n' >"$work/answers.update"
printf 'ciuser2\nCISecret_456~y\n' >"$work/pass.update"
chmod 0600 "$work/answers.update" "$work/pass.update"
sudo sh .github/scripts/run-socks5.sh install \
  "$work/answers.update" "$work/update.log" "$work/pass.update"
printf 'lifecycle: update-ok\n'
sudo grep -q 'ciuser2' /etc/xray-socks5/config.json
sudo grep -qE '^username[[:space:]]+ciuser2$' /var/lib/xray-socks5/state
test ! -e /var/lib/xray-socks5/transaction
test "$(sudo stat -c '%U:%G %a' /etc/xray-socks5/config.json)" = "root:xray-socks5 640"
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
  "$work/answers.uninstall" "$work/uninstall.log" "$work/pass"
test ! -e /etc/xray-socks5
test ! -e /var/lib/xray-socks5
test ! -e /usr/local/libexec/xray-socks5
no_credential_in() {
  # A status other than 1 is a broken check rather than a clean log, and the
  # inline form exited 1 with no output, so a leak and an unreadable file looked
  # the same in the job log.
  _ncst=0
  sudo grep -q "$2" "$1" || _ncst=$?
  if [ "$_ncst" = 0 ]; then
    printf 'a credential reached %s\n' "$1" >&2
    exit 1
  fi
  if [ "$_ncst" != 1 ]; then
    printf 'the credential check on %s failed with status %s\n' "$1" "$_ncst" >&2
    exit 1
  fi
}
no_credential_in "$work/install.log" 'CISecret_123~x'
no_credential_in "$work/status.log" 'CISecret_123~x'
no_credential_in "$work/update.log" 'CISecret_456~y'
