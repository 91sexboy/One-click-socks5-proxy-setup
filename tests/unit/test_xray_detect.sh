#!/bin/sh
# Platform acceptance matrix: which systems are supported, and on which arches.

S5T_NAME=test_xray_detect
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
ROOT=${S5_REPO_ROOT}
t_mktestroot
S5_LIB_ONLY=1
S5_ASSUME_ROOT=1
S5_SKIP_OWNERSHIP=1
export S5_LIB_ONLY S5_ASSUME_ROOT S5_SKIP_OWNERSHIP
# shellcheck disable=SC1091
. "$ROOT/socks5.sh"
S5_LANG=en

# Each row is a fixture, an architecture, and either the expected
# family:pkgmgr:init triple or "reject". Ubuntu 20.04 is amd64-only; every other
# accepted release covers both arches. Enterprise rebuilds are deliberately not
# adopted: only CentOS Stream itself is accepted in that family.
while read -r _dfix _darch _dwant; do
    [ -n "$_dfix" ] || continue
    S5_OSRELEASE="$ROOT/tests/fixtures/os-release/$_dfix"
    S5_ARCHNAME=$_darch
    S5_OS_FAMILY=''
    S5_PKGMGR=''
    S5_INIT=''
    S5_UNIT=''
    if [ "$_dwant" = reject ]; then
        t_run s5_detect_platform
        assert_ne "$_dfix on $_darch is refused" 0 "$T_STATUS"
        continue
    fi
    s5_detect_platform
    assert_eq "$_dfix on $_darch is accepted" 0 "$?"
    assert_eq "$_dfix on $_darch backend" "$_dwant" \
        "$S5_OS_FAMILY:$S5_PKGMGR:$S5_INIT"
    if [ "$S5_INIT" = openrc ]; then
        assert_eq "$_dfix service artifact is an init script" \
            "$S5_INITSCRIPT" "$S5_UNIT"
    else
        assert_eq "$_dfix service artifact is a systemd unit" \
            "$S5_UNITDIR/$S5_PROJECT.service" "$S5_UNIT"
    fi
done <<'TABLE'
ubuntu-20.04 amd64 debian:apt:systemd
ubuntu-20.04 arm64 reject
ubuntu-22.04 amd64 debian:apt:systemd
ubuntu-22.04 arm64 debian:apt:systemd
ubuntu-24.04 amd64 debian:apt:systemd
ubuntu-24.04 arm64 debian:apt:systemd
ubuntu-24.04 riscv64 reject
debian-11 amd64 reject
debian-12 amd64 debian:apt:systemd
debian-12 arm64 debian:apt:systemd
debian-13 amd64 debian:apt:systemd
centos-stream-8 amd64 reject
centos-stream-9 amd64 el:dnf:systemd
centos-stream-9 arm64 el:dnf:systemd
centos-stream-10 amd64 el:dnf:systemd
alpine-3.19 amd64 reject
alpine-3.20 amd64 alpine:apk:openrc
alpine-3.20 arm64 alpine:apk:openrc
alpine-3.24 amd64 alpine:apk:openrc
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

t_summary
