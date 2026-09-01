#!/bin/sh
# tests/unit/test_detect.sh - Task 2: OS / version / arch / init / pkg-mgr / root / deps detection.

S5T_NAME=test_detect
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
. "${S5_REPO_ROOT}/tests/lib/stub.sh"

t_mktestroot
t_stub_init

FIX="${S5_REPO_ROOT}/tests/fixtures/os-release"
S5_LIB_ONLY=1
export S5_LIB_ONLY
# shellcheck source=/dev/null
. "${S5_SRC}"

# --- version comparison ---
vge() {
    if s5_ver_ge "$1" "$2"; then printf 'yes'; else printf 'no'; fi
}
assert_eq "22.04 >= 22.04" yes "$(vge 22.04 22.04)"
assert_eq "24.04 >= 22.04" yes "$(vge 24.04 22.04)"
assert_eq "20.04 >= 22.04" no "$(vge 20.04 22.04)"
assert_eq "3.20.3 >= 3.20" yes "$(vge 3.20.3 3.20)"
assert_eq "3.19.9 >= 3.20" no "$(vge 3.19.9 3.20)"
assert_eq "3.24.1 >= 3.20" yes "$(vge 3.24.1 3.20)"
assert_eq "13 >= 12" yes "$(vge 13 12)"
assert_eq "11 >= 12" no "$(vge 11 12)"
assert_eq "10 >= 9" yes "$(vge 10 9)"
assert_eq "9.4 >= 9" yes "$(vge 9.4 9)"

# --- os-release parsing (no eval; quotes stripped) ---
assert_eq "parse ID centos" centos "$(s5_osrel_get "$FIX/centos-stream-9" ID)"
assert_eq "parse VERSION_ID centos" 9 "$(s5_osrel_get "$FIX/centos-stream-9" VERSION_ID)"
assert_eq "parse unquoted ID ubuntu" ubuntu "$(s5_osrel_get "$FIX/ubuntu-22.04" ID)"
assert_eq "parse VERSION_ID ubuntu" 22.04 "$(s5_osrel_get "$FIX/ubuntu-22.04" VERSION_ID)"
assert_eq "parse ID_LIKE" "rhel centos fedora" "$(s5_osrel_get "$FIX/rocky-9" ID_LIKE)"
assert_eq "parse alpine version" 3.24.1 "$(s5_osrel_get "$FIX/alpine-3.24" VERSION_ID)"
assert_eq "absent key yields empty" "" "$(s5_osrel_get "$FIX/alpine-3.24" ID_LIKE)"

# --- supported platforms map to the right package manager and init ---
check_supported() {
    # <fixture> <arch> <expected-pkgmgr> <expected-init>
    S5_OSRELEASE="$FIX/$1"
    if s5_detect_platform "$2" >/dev/null 2>&1; then
        assert_eq "$1/$2 pkgmgr" "$3" "$S5_PKGMGR"
        assert_eq "$1/$2 init" "$4" "$S5_INIT"
    else
        t_bad "$1/$2 should be supported but detection failed"
    fi
}
check_supported ubuntu-20.04 amd64 apt systemd
check_supported ubuntu-22.04 amd64 apt systemd
check_supported ubuntu-22.04 arm64 apt systemd
check_supported ubuntu-24.04 amd64 apt systemd
check_supported ubuntu-24.04 arm64 apt systemd
check_supported debian-12 amd64 apt systemd
check_supported debian-13 arm64 apt systemd
check_supported alpine-3.20 amd64 apk openrc
check_supported alpine-3.24 arm64 apk openrc
check_supported centos-stream-9 amd64 dnf systemd
check_supported centos-stream-10 arm64 dnf systemd

# --- RHEL / Rocky / Alma: recognised, told they are likely compatible, and REFUSED ---
check_rhel_like() {
    S5_OSRELEASE="$FIX/$1"
    t_run s5_detect_platform amd64
    assert_eq "$1 is refused" "$EX_UNSUPPORTED" "$T_STATUS"
    assert_contains "$1 says likely compatible" "likely compatible" "$T_OUT"
    assert_contains "$1 says not supported" "not supported" "$T_OUT"
}
check_rhel_like rhel-9
check_rhel_like rocky-9
check_rhel_like almalinux-9

# An exact whitespace-delimited ID_LIKE=rhel token selects only the more useful
# refusal message. It must never select a package manager or authorize install.
S5_OSRELEASE="$FIX/oracle-9"
detect_with_state() {
    s5_detect_platform amd64
    _dws=$?
    printf '\nSTATE:%s|%s|%s\n' "$S5_OS_FAMILY" "$S5_PKGMGR" "$S5_INIT"
    return "$_dws"
}
t_run detect_with_state
assert_eq "an ID_LIKE-only RHEL derivative is refused" "$EX_UNSUPPORTED" "$T_STATUS"
assert_contains "the derivative receives the likely-compatible refusal" "likely compatible" "$T_OUT"
assert_contains "the refusal leaves family/pkgmgr/init unset" "STATE:||" "$T_OUT"

# Substrings are not tokens: `notrhel` must not be mistaken for `rhel`.
S5_OSRELEASE="$FIX/notrhel-9"
t_run s5_detect_platform amd64
assert_eq "an ID_LIKE substring is refused generically" "$EX_UNSUPPORTED" "$T_STATUS"
assert_not_contains "notrhel does not receive the RHEL-specific wording" "likely compatible" "$T_OUT"
assert_contains "the generic refusal names the derivative ID" "notrhel-linux" "$T_OUT"

# ID_LIKE=rhel alone must never authorise an install
S5_OSRELEASE="$FIX/rocky-9"
t_run s5_detect_platform amd64
assert_ne "ID_LIKE=rhel does not authorise install" 0 "$T_STATUS"

# --- unknown, too-old and unsupported tuples are hard errors naming dimensions ---
check_unsupported() {
    S5_OSRELEASE="$FIX/$1"
    t_run s5_detect_platform "$4"
    assert_eq "$1/$4 unsupported" "$EX_UNSUPPORTED" "$T_STATUS"
    assert_contains "$1/$4 error names ID" "$2" "$T_OUT"
    assert_contains "$1/$4 error names VERSION_ID" "$3" "$T_OUT"
    assert_contains "$1/$4 error names architecture" "$4" "$T_OUT"
}
check_unsupported fedora-40 fedora 40 amd64
check_unsupported ubuntu-20.04 ubuntu 20.04 arm64
check_unsupported debian-11 debian 11 amd64
check_unsupported alpine-3.19 alpine 3.19.9 amd64
check_unsupported centos-stream-8 centos 8 amd64

t_run s5_detect_platform
assert_eq "detector without normalized architecture fails closed" "$EX_UNSUPPORTED" "$T_STATUS"
t_run s5_detect_platform riscv64
assert_eq "detector rejects non-normalized architecture" "$EX_UNSUPPORTED" "$T_STATUS"

# missing os-release file
S5_OSRELEASE="$S5_TEST_ROOT/definitely-absent"
t_run s5_detect_platform amd64
assert_ne "missing os-release is an error" 0 "$T_STATUS"

# --- architecture mapping ---
assert_eq "x86_64 -> amd64" amd64 "$(s5_map_arch x86_64)"
assert_eq "amd64 -> amd64" amd64 "$(s5_map_arch amd64)"
assert_eq "aarch64 -> arm64" arm64 "$(s5_map_arch aarch64)"
assert_eq "arm64 -> arm64" arm64 "$(s5_map_arch arm64)"
for bad in i686 i386 armv7l riscv64 ppc64le s390x mips; do
    t_run s5_map_arch "$bad"
    assert_eq "$bad is rejected" "$EX_UNSUPPORTED" "$T_STATUS"
done

# --- only missing runtime dependencies are installed on target hosts ---
t_stub curl 0
s5_ca_bundle_available() { return 0; }
s5_probe_cmd() { printf 'proc'; return 0; }
assert_eq "complete runtime has no package plan" "" "$(s5_required_packages)"

rm -f "$S5_TEST_ROOT/bin/curl"
OLDPATH=$PATH
PATH="$S5_TEST_ROOT/bin"
export PATH
assert_eq "curl absent: added to deps" "curl" "$(s5_runtime_deps)"
PATH=$OLDPATH
export PATH

t_stub curl 0
s5_ca_bundle_available() { return 1; }
assert_eq "missing CA bundle is installed" "ca-certificates" "$(s5_runtime_deps)"
s5_ca_bundle_available() { return 0; }

# A supported host without /proc socket tables, ss or netstat needs the small
# distro package that supplies ss before the port prompt.
s5_probe_cmd() { return 1; }
S5_PKGMGR=apt
assert_eq "apt adds iproute2 when no port probe exists" "iproute2" "$(s5_runtime_deps)"
S5_PKGMGR=apk
assert_eq "apk adds iproute2 when no port probe exists" "iproute2" "$(s5_runtime_deps)"
S5_PKGMGR=dnf
assert_eq "dnf adds iproute when no port probe exists" "iproute" "$(s5_runtime_deps)"
S5_PKGMGR=yum
assert_eq "yum adds iproute when no port probe exists" "iproute" "$(s5_runtime_deps)"
s5_probe_cmd() { printf 'proc'; return 0; }
S5_PKGMGR=apt
assert_eq "the kernel socket table needs no probe package" "" "$(s5_runtime_deps)"

# The package step must not consume an interactive answer, and apt must avoid
# recommendations when a genuinely missing runtime dependency is installed.
s5_confirm() { return 1; }
s5_ca_bundle_available() { return 1; }
t_stub apt-get 0
S5_PKGMGR=apt
S5_PORT_PROBE="$S5_TEST_ROOT/bin/portprobe"
t_run s5_install_dependencies
assert_eq "runtime dependency installation asks no second confirmation" 0 "$T_STATUS"
t_assert_called "dependency installation updates apt metadata" 'apt-get update'
t_assert_called "apt avoids recommended packages" 'apt-get install -y --no-install-recommends ca-certificates'
: >"$T_TRANSCRIPT"
unset -f s5_confirm

# --- root detection is explicit and never escalates ---
S5_ASSUME_ROOT=1
if s5_is_root; then t_ok; else t_bad "S5_ASSUME_ROOT=1 should report root"; fi
S5_ASSUME_ROOT=0
if s5_is_root; then t_bad "S5_ASSUME_ROOT=0 should report non-root"; else t_ok; fi
S5_ASSUME_ROOT=''
t_assert_cmd_never_called "no sudo invoked during detection" sudo doas su

# --- required base commands ---
t_run s5_require_commands sed grep
assert_eq "present commands accepted" 0 "$T_STATUS"
t_run s5_require_commands definitely-not-a-real-command-xyz
assert_ne "missing command detected" 0 "$T_STATUS"
assert_contains "names the missing command" "definitely-not-a-real-command-xyz" "$T_OUT"

# --- package manager availability check consults PATH, never installs ---
t_stub apt-get 0
S5_PKGMGR=apt
if s5_pkgmgr_available; then t_ok; else t_bad "apt-get stub should satisfy availability"; fi
t_assert_never_called "availability check installs nothing" 'apt-get install'

t_summary
