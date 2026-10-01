#!/bin/sh
# Platform acceptance matrix: which systems are supported, and on which arches.

S5T_NAME=test_xray_detect
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
ROOT=${S5_REPO_ROOT}
t_mktestroot
t_source_production ''
S5_LANG=en

# Each row is a fixture, an architecture, and either the expected
# family:init pair or "reject". Ubuntu 20.04 is amd64-only; every other
# accepted release covers both arches. Enterprise rebuilds are deliberately not
# adopted: only CentOS Stream itself is accepted in that family.
while read -r _dfix _darch _dwant; do
    [ -n "$_dfix" ] || continue
    S5_OSRELEASE="$ROOT/tests/fixtures/os-release/$_dfix"
    S5_ARCHNAME=$_darch
    S5_OS_FAMILY=''
    S5_INIT=''
    S5_SERVICE_ARTIFACT=''
    if [ "$_dwant" = reject ]; then
        t_run s5_detect_platform
        assert_ne "$_dfix on $_darch is refused" 0 "$T_STATUS"
        continue
    fi
    s5_detect_platform
    assert_eq "$_dfix on $_darch is accepted" 0 "$?"
    assert_eq "$_dfix on $_darch backend" "$_dwant" \
        "$S5_OS_FAMILY:$S5_INIT"
    if [ "$S5_INIT" = openrc ]; then
        assert_eq "$_dfix service artifact is an init script" \
            "$S5_INITSCRIPT" "$S5_SERVICE_ARTIFACT"
    else
        assert_eq "$_dfix service artifact is a systemd unit" \
            "$S5_UNITDIR/$S5_PROJECT.service" "$S5_SERVICE_ARTIFACT"
    fi
done <<'TABLE'
ubuntu-20.04 amd64 debian:systemd
ubuntu-20.04 arm64 reject
ubuntu-22.04 amd64 debian:systemd
ubuntu-22.04 arm64 debian:systemd
ubuntu-24.04 amd64 debian:systemd
ubuntu-24.04 arm64 debian:systemd
ubuntu-24.04 riscv64 reject
debian-11 amd64 reject
debian-12 amd64 debian:systemd
debian-12 arm64 debian:systemd
debian-13 amd64 debian:systemd
centos-stream-8 amd64 reject
centos-stream-9 amd64 el:systemd
centos-stream-9 arm64 el:systemd
centos-stream-10 amd64 el:systemd
alpine-3.19 amd64 reject
alpine-3.20 amd64 alpine:openrc
alpine-3.20 arm64 alpine:openrc
alpine-3.22 amd64 alpine:openrc
alpine-3.22 arm64 alpine:openrc
alpine-3.24 amd64 alpine:openrc
rhel-9 amd64 reject
rocky-9 amd64 reject
almalinux-9 amd64 reject
oracle-9 amd64 reject
fedora-40 amd64 reject
notrhel-9 amd64 reject
TABLE

# A missing or unreadable os-release is not a supported platform.
S5_ARCHNAME=amd64
S5_OSRELEASE="$S5_TEST_ROOT/absent-os-release"
t_run s5_detect_platform
assert_ne "an absent os-release is refused" 0 "$T_STATUS"

# Equal-width numeric fields are compared lexically, not through signed shell
# arithmetic, so values around and beyond 64-bit limits behave identically.
for _dvcase in \
    922337203685477580:922337203685477579:0 \
    999999999999999999:922337203685477580:0 \
    999999999999999999:100000000000000000:0 \
    100000000000000000:999999999999999999:1 \
    184467440737095516:184467440737095516:0; do
    _dvleft=${_dvcase%%:*}
    _dvrest=${_dvcase#*:}
    _dvright=${_dvrest%%:*}
    _dvwant=${_dvrest##*:}
    t_run s5_ver_ge "$_dvleft" "$_dvright"
    assert_eq "version comparison $_dvleft >= $_dvright" "$_dvwant" "$T_STATUS"
done

# Malformed versions are invalid (2), never ordered. A colon inside a field used
# to pass as a separator, so VERSION_ID=1:0 compared as a number above 22.04.
for _dvbad in '1:0|22.04' 'a.b|3.20' '|12' '12|' '22.|22.04' '3.x|3.20'; do
    t_run s5_ver_ge "${_dvbad%%|*}" "${_dvbad#*|}"
    assert_eq "malformed version comparison [$_dvbad] is invalid" 2 "$T_STATUS"
done
S5_OSRELEASE="$S5_TEST_ROOT/colon-os-release"
printf 'ID=ubuntu\nVERSION_ID="1:0"\n' >"$S5_OSRELEASE"
t_run s5_detect_platform
assert_ne "a colon-bearing VERSION_ID is not a supported Ubuntu" 0 "$T_STATUS"

# There is no default backend: without S5_INIT the artifact path and the
# service definition are refused and named, not silently systemd.
S5_INIT=''
t_run s5_select_service_artifact
assert_ne "no backend selects no service artifact" 0 "$T_STATUS"
assert_contains "no backend is reported as an init failure" \
    'no supported service manager was found' "$T_OUT"
t_run s5_write_unit
assert_ne "no backend writes no service definition" 0 "$T_STATUS"

# Every command precheck requires is one the script actually runs. A required
# command nothing calls turns a host without it into a false refusal.
t_run python3 - "$S5_REPO_ROOT/socks5.sh" <<'PY'
import re
import sys
from pathlib import Path


def unused(source):
    # A long requirement list continues over backslash-newlines; read it whole.
    lines = re.sub(r'\\\n\s*', ' ', source).split('\n')
    required = set()
    for line in lines:
        match = re.match(r'\s*s5_require_commands (.*?)\|\|', line)
        if match:
            required |= set(match.group(1).split())
    body = '\n'.join(line for line in lines
                     if not line.lstrip().startswith('#') and 's5_require_commands' not in line)
    return sorted(command for command in required if not re.search(
        r'(^|[\s;|&(!{`]|\$\()' + re.escape(command) + r'(?=[\s;|&)`]|$)', body, re.M))


source = Path(sys.argv[1]).read_text()
if unused(source):
    raise SystemExit('required but never run: ' + ' '.join(unused(source)))
mutated = source.replace('s5_require_commands awk ', 's5_require_commands rc-status awk ', 1)
if unused(mutated) != ['rc-status']:
    raise SystemExit('the oracle missed a required command that is never run')
PY
assert_eq "precheck requires only commands the script runs" 0 "$T_STATUS"
if [ "$T_STATUS" -ne 0 ]; then printf '%s\n' "$T_OUT" >&2; fi

t_summary
