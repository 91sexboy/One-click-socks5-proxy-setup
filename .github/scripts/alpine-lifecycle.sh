#!/bin/sh
# The Alpine/OpenRC lifecycle gate, run inside the container by ci.yml.
#
# It lived inline as one single-quoted docker run argument, where a single
# apostrophe in a comment closed the argument and handed the rest to the host
# shell. That broke the gate twice and needed an oracle counting apostrophes to
# hold it. As a file it is ordinary shell, read by sh -n, dash -n, busybox sh -n
# and the linter like any other script in this directory.
set -eu
apk add --no-cache openrc >/dev/null
mkdir -p /run/openrc
touch /run/openrc/softlevel
rc-status -a >/dev/null 2>&1 || true
umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
printf "2\ny\n23456\nciuser\nCISecret_123~x\n" >"$work/answers"
printf "ciuser\nCISecret_123~x\n" >"$work/pass"
chmod 0600 "$work/answers" "$work/pass"
if ! sh socks5.sh install <"$work/answers" >"$work/install.log" 2>&1; then
  cat "$work/install.log"
  exit 1
fi
test "$(stat -c "%U:%G %a" /etc/init.d/xray-socks5)" = "root:root 755"
test "$(stat -c "%U:%G %a" /etc/xray-socks5/config.json)" = "root:xray-socks5 640"
test "$(stat -c "%U:%G %a" /var/lib/xray-socks5/state)" = "root:root 600"
# SPEC 5: re-running install over an existing installation is an
# in-place update. Rotate the credentials, keep the port, and require
# the new identity in both the config and the state.
printf "2\ny\n23456\nciuser2\nCISecret_456~y\n" >"$work/answers.update"
printf "ciuser2\nCISecret_456~y\n" >"$work/pass.update"
chmod 0600 "$work/answers.update" "$work/pass.update"
if ! sh socks5.sh install <"$work/answers.update" >"$work/update.log" 2>&1; then
  cat "$work/update.log"
  exit 1
fi
grep -q "ciuser2" /etc/xray-socks5/config.json
grep -qE "^username[[:space:]]+ciuser2$" /var/lib/xray-socks5/state
test ! -e /var/lib/xray-socks5/transaction
test "$(stat -c "%U:%G %a" /etc/xray-socks5/config.json)" = "root:xray-socks5 640"
rc-service xray-socks5 status
pkgs_before=$(apk info | sort | sha256sum)
printf "2\n" | sh socks5.sh status >"$work/status.log"
printf "2\n" | sh socks5.sh restart
rc-service xray-socks5 status
grep -q "mixed" "$work/status.log"
# SPEC 5: OpenRC recovers a crash with the listener returning, and a
# configuration error does not enter an automatic restart loop.
crash_pid=$(cat /run/openrc/options/xray-socks5/child_pid)
test "$crash_pid" -gt 0
kill -9 "$crash_pid"
new_pid=0
for n in $(seq 1 60); do
  new_pid=$(cat /run/openrc/options/xray-socks5/child_pid 2>/dev/null || printf 0)
  if test "$new_pid" != "$crash_pid" && test "$new_pid" -gt 0; then break; fi
  sleep 1
done
test "$new_pid" != "$crash_pid"
test "$new_pid" -gt 0
for n in $(seq 1 60); do
  ss -H -ltnp 2>/dev/null | grep -q "pid=$new_pid," && break
  sleep 1
done
ss -H -ltnp | grep -q "pid=$new_pid,"
cp /etc/xray-socks5/config.json "$work/good.json"
printf "{broken\n" >/etc/xray-socks5/config.json
rc-service xray-socks5 restart || true
for n in $(seq 1 30); do
  rc-service xray-socks5 status >/dev/null 2>&1 || break
  sleep 1
done
if rc-service xray-socks5 status >/dev/null 2>&1; then
  printf "a broken config left the service running\n" >&2
  exit 1
fi
# SPEC 8: a configuration error exits 23. OpenRC bounds respawns by
# count rather than by exit status, so the status has to come from the
# supervised binary, and the respawn guard is proven by child_pid
# holding still across the settle window below.
respawn_before=$(cat /run/openrc/options/xray-socks5/child_pid 2>/dev/null || printf none)
broken_status=0
/usr/local/libexec/xray-socks5/xray run -c /etc/xray-socks5/config.json \
  >"$work/broken.log" 2>&1 || broken_status=$?
if test "$broken_status" != 23; then
  printf "a broken config exited %s, expected 23\n" "$broken_status" >&2
  cat "$work/broken.log" >&2
  exit 1
fi
for n in $(seq 1 12); do
  if ss -H -ltn 2>/dev/null | grep -q ":23456 "; then
    printf "a broken config produced a listener\n" >&2
    exit 1
  fi
  sleep 1
done
respawn_after=$(cat /run/openrc/options/xray-socks5/child_pid 2>/dev/null || printf none)
printf "openrc: child_pid %s then %s\n" "$respawn_before" "$respawn_after"
if test "$respawn_after" != "$respawn_before"; then
  printf "a broken config respawned: child_pid %s then %s\n" \
    "$respawn_before" "$respawn_after" >&2
  exit 1
fi
# A stopped supervise-daemon removes its options directory, so the
# comparison above is between two absent values and cannot fail on its
# own. This is the independent half: a respawn that is still alive puts
# the service back up, and one that came and went inside the window is
# caught by the listener loop above.
if rc-service xray-socks5 status >/dev/null 2>&1; then
  printf "a broken config brought the service back up\n" >&2
  exit 1
fi
# Redirection truncates in place, so the config keeps the owner and
# mode the installer gave it. BusyBox cp replaces the destination and
# would hand it the private attributes of the backup copy.
cat "$work/good.json" >/etc/xray-socks5/config.json
test "$(stat -c "%U:%G %a" /etc/xray-socks5/config.json)" = "root:xray-socks5 640"
rc-service xray-socks5 restart
rc-service xray-socks5 status
sh tests/protocol/post_install_audit.sh / "$work/pass.update" openrc
# SPEC 10: credentials reach neither argv nor the service environment.
live_pid=$(cat /run/openrc/options/xray-socks5/child_pid)
if tr "\0" "\n" <"/proc/$live_pid/cmdline" | grep -qE "CISecret_123~x|CISecret_456~y"; then
  printf "credential appeared in argv\n" >&2
  exit 1
fi
if tr "\0" "\n" <"/proc/$live_pid/environ" | grep -qE "CISecret_123~x|CISecret_456~y"; then
  printf "credential appeared in the service environment\n" >&2
  exit 1
fi
# SPEC 6: independent SOCKS5 and HTTP verification, separate from the
# data-plane check the installer runs itself. The target binds every
# address so it answers at both the permitted 192.0.2.1 and the denied
# 127.0.0.1, which is what makes a boundary bypass visible.
sh .github/scripts/add-test-target-addresses.sh
python3 tests/protocol/duplex_target.py --host 0.0.0.0 --host6 :: \
  --ready-file "$work/target.port" \
  --count-file "$work/count" --report-file "$work/report" >"$work/target.log" 2>&1 &
for n in $(seq 1 50); do test -s "$work/target.port" && break; sleep 0.2; done
test -s "$work/target.port"
PASSFILE="$work/pass.update" PORT=23456 TARGET_PORT="$(cat "$work/target.port")" \
  REPORT="$work/report" OUT="$work/probe" \
  sh tests/protocol/run_xray_mixed.sh
printf "2\ny\n" | sh socks5.sh uninstall
test "$(apk info | sort | sha256sum)" = "$pkgs_before"
test ! -e /etc/xray-socks5
test ! -e /var/lib/xray-socks5
test ! -e /usr/local/libexec/xray-socks5
test ! -e /etc/init.d/xray-socks5
test ! -e /run/xray-socks5.pid
# set -e does not apply to a command a ! inverts, so `! grep -q secret log` did
# not fail the gate when it found one. Only the last such line ever mattered, as
# the script's exit status; a credential leaked into install.log went unreported.
if grep -q "CISecret_123~x" "$work/install.log"; then
    printf "a credential reached the install log\n" >&2
    exit 1
fi
if grep -q "CISecret_456~y" "$work/update.log"; then
    printf "a credential reached the update log\n" >&2
    exit 1
fi
