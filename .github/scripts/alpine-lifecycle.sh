#!/bin/sh
# The Alpine/OpenRC lifecycle gate, run inside the container by ci.yml.
#
# It lived inline as one single-quoted docker run argument, where a single
# apostrophe in a comment closed the argument and handed the rest to the host
# shell. That broke the gate twice and needed an oracle counting apostrophes to
# hold it. As a file it is ordinary shell, read by sh -n, dash -n, busybox sh -n
# and the linter like any other script in this directory.
set -eu
# shellcheck source=.github/scripts/lifecycle-common.sh
. "$(dirname "$0")/lifecycle-common.sh"
apk add --no-cache openrc >/dev/null
mkdir -p /run/openrc
touch /run/openrc/softlevel
rc-status -a >/dev/null 2>&1 || true
umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
lifecycle_write_fixtures "$work"
original_path=$PATH
if [ "${ALPINE_HOSTILE_UNZIP:-0}" = 1 ]; then
  mkdir "$work/hostile-bin"
  ALPINE_HOSTILE_UNZIP_LOG=$work/hostile-unzip.calls
  export ALPINE_HOSTILE_UNZIP_LOG
  cat >"$work/hostile-bin/unzip" <<'HOSTILE_UNZIP'
#!/bin/sh
printf 'called\n' >>"$ALPINE_HOSTILE_UNZIP_LOG"
UNZIP=-aa
export UNZIP
exec /usr/bin/unzip "$@"
HOSTILE_UNZIP
  chmod 0755 "$work/hostile-bin/unzip"
  PATH=$work/hostile-bin:$PATH
  UNZIP=-aa
  UNZIPOPT=-aa
  ZIPINFO=-h
  ZIPINFOOPT=-h
  export PATH UNZIP UNZIPOPT ZIPINFO ZIPINFOOPT
fi
pkgs_before_install=$(apk info | sort | sha256sum)
sh .github/scripts/run-socks5.sh install \
  "$work/answers" "$work/install.log" "$work/pass"
test "$(stat -c "%U:%G %a" /etc/init.d/xray-socks5)" = "root:root 755"
test "$(stat -c "%U:%G %a" /etc/xray-socks5/config.json)" = "root:xray-socks5 640"
test "$(stat -c "%U:%G %a" /var/lib/xray-socks5/state)" = "root:root 600"
test "$(wc -c </usr/local/libexec/xray-socks5/xray | tr -cd '0-9')" = 36577406
test "$(sha256sum /usr/local/libexec/xray-socks5/xray | awk '{print $1}')" = \
  8255dd939c34cf966cc91517b6324dd3c8d0bcf49ffac8beca049a38c46845ed
if [ "${ALPINE_HOSTILE_UNZIP:-0}" = 1 ]; then
  test ! -e "$ALPINE_HOSTILE_UNZIP_LOG"
  # The positive control test_xray_asset.sh keeps for the same wrapper. A wrapper
  # that happened to be harmless satisfies the line above exactly as a harmful one
  # does, so run the wrapper itself and require the bytes it produces to differ
  # from a clean extraction of the same member. The call made here also has to
  # reach the log, or "never invoked" would be reading a log that never records.
  # It runs after the install because the install is what brings Info-ZIP in: the
  # BusyBox unzip Alpine ships ignores UNZIP entirely, so the control would prove
  # nothing earlier. A local archive keeps it off the network, and the member only
  # has to carry the CR LF pairs that -aa rewrites.
  python3 - "$work/control.zip" <<'CONTROL_ZIP'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.writestr("xray", b"\r\n".join(bytes([value]) for value in range(256)))
CONTROL_ZIP
  # The wrapper is still first on PATH, so the clean side names Info-ZIP
  # absolutely and drops the inherited options in a subshell, the way socks5.sh's
  # s5_unzip does.
  (
    unset UNZIP UNZIPOPT ZIPINFO ZIPINFOOPT
    /usr/bin/unzip -p "$work/control.zip" xray >"$work/control.clean"
  )
  "$work/hostile-bin/unzip" -p "$work/control.zip" xray >"$work/control.hostile"
  test -s "$ALPINE_HOSTILE_UNZIP_LOG"
  if cmp -s "$work/control.clean" "$work/control.hostile"; then
    printf "the hostile unzip wrapper extracted uncorrupted bytes\n" >&2
    exit 1
  fi
  rm -f "$ALPINE_HOSTILE_UNZIP_LOG"
  PATH=$original_path
  unset UNZIP UNZIPOPT ZIPINFO ZIPINFOOPT ALPINE_HOSTILE_UNZIP_LOG
  export PATH
  unset original_path
fi
# SPEC 5: re-running install over an existing installation is an
# in-place update. Rotate the credentials, keep the port, and require
# the new identity in both the config and the state.
sh .github/scripts/run-socks5.sh install \
  "$work/answers.update" "$work/update.log" "$work/pass.update" "$work/pass"
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
# status always exits 0 by design (README.md), so the log content is the only
# signal. The heading carries "mixed" on its own, which left a listener degraded
# to service.listen or service.unverified passing: match the service.ready line
# for the installed port, and the protocol summary in the status line rather than
# the word in the heading.
grep -qxF 'Xray is listening on port 23456.' "$work/status.log"
grep -qF 'protocol: mixed (SOCKS5 + HTTP); auth: password; UDP: disabled' "$work/status.log"
# SPEC 5: OpenRC recovers a crash with the listener returning, and a
# configuration error does not enter an automatic restart loop.
crash_pid=$(cat /run/openrc/options/xray-socks5/child_pid)
test "$crash_pid" -gt 0
kill -9 "$crash_pid"
new_pid=0
crash_recovered() {
  new_pid=$(cat /run/openrc/options/xray-socks5/child_pid 2>/dev/null || printf 0)
  test "$new_pid" != "$crash_pid" && test "$new_pid" -gt 0
}
# The assertions below remain authoritative after the final sleep.
lifecycle_wait_until 60 1 crash_recovered || true
test "$new_pid" != "$crash_pid"
test "$new_pid" -gt 0
listener_recovered() {
  ss -H -ltnp 2>/dev/null | grep -q "pid=$new_pid,"
}
lifecycle_wait_until 60 1 listener_recovered || true
ss -H -ltnp | grep -q "pid=$new_pid,"
cp /etc/xray-socks5/config.json "$work/good.json"
printf "{broken\n" >/etc/xray-socks5/config.json
rc-service xray-socks5 restart || true
service_stopped() {
  if rc-service xray-socks5 status >/dev/null 2>&1; then return 1; fi
}
lifecycle_wait_until 30 1 service_stopped || true
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
# SPEC 7: credentials reach neither argv nor the service environment.
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
sh socks5.sh help </dev/null >"$work/help-after-uninstall.log"
grep -q 'Usage: sh socks5.sh' "$work/help-after-uninstall.log"
# ADR-0006: the capacity check reads the filesystem through stat, and BusyBox builds
# stat's -f support behind a config option. Without it the check answers nothing and
# disables itself -- silently, and on the one platform whose operator reported the
# failure it exists to explain, which is why a passing lifecycle is not evidence on
# its own. Prove the applet answers, then prove the refusal is reachable end to end
# rather than merely compiled in: a 12 MiB work filesystem cannot hold the 21 MB
# archive and the 36 MB member, and the prefix is on another filesystem, so the
# per-path requirement is the one reported.
test "$(stat -f -c '%f %S' / | awk '{print ($1 > 0 && $2 > 0) ? "ok" : "bad"}')" = ok
test "$(stat -c '%d' / | awk '{print ($1 > 0) ? "ok" : "bad"}')" = ok
mount -t tmpfs -o size=12m,mode=1777 tmpfs /var/tmp
capacity_status=0
sh .github/scripts/run-socks5.sh install \
  "$work/answers.reinstall" "$work/capacity.log" "$work/pass" || capacity_status=$?
umount /var/tmp
test "$capacity_status" -ne 0
grep -q 'not enough space on the filesystem holding' "$work/capacity.log"
grep -q '56362 KiB required' "$work/capacity.log"
# The refusal happens after staging created the prefix, so cleanup owns removing it.
test ! -e /usr/local/libexec/xray-socks5
test ! -e /etc/xray-socks5
test ! -e /var/lib/xray-socks5
lifecycle_generation_absent "$work/capacity.log" "$work/pass"
lifecycle_assert_logs_redacted "$work"
