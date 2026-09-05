#!/bin/sh
# Xray release asset metadata and safe selection tests.

S5T_NAME=test_xray_asset
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
ROOT=${S5_REPO_ROOT}
t_mktestroot
S5_LIB_ONLY=1
S5_ASSUME_ROOT=1
S5_SKIP_OWNERSHIP=1
export S5_LIB_ONLY S5_ASSUME_ROOT S5_SKIP_OWNERSHIP
# shellcheck source=/dev/null
. "$ROOT/socks5.sh"

assert_eq "Xray release is stable v26.3.27" v26.3.27 "$S5_XRAY_VERSION"
assert_eq "Xray release commit is pinned" \
    d2758a023cd7f4174a5a5fa4ff66e487d4342ba0 "$S5_XRAY_COMMIT"

S5_ARCHNAME=amd64
s5_asset_select
assert_eq "amd64 asset name" Xray-linux-64.zip "$S5_ASSET_NAME"
assert_eq "amd64 archive size" 21136402 "$S5_ASSET_SIZE"
assert_eq "amd64 archive digest" \
    23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae \
    "$S5_ASSET_SHA256"
assert_eq "amd64 extracted xray size" 36577406 "$S5_ASSET_BINARY_SIZE"
assert_eq "amd64 extracted xray digest" \
    8255dd939c34cf966cc91517b6324dd3c8d0bcf49ffac8beca049a38c46845ed \
    "$S5_ASSET_BINARY_SHA256"

S5_ARCHNAME=arm64
s5_asset_select
assert_eq "arm64 asset name" Xray-linux-arm64-v8a.zip "$S5_ASSET_NAME"
assert_eq "arm64 archive size" 19716427 "$S5_ASSET_SIZE"
assert_eq "arm64 archive digest" \
    4d30283ae614e3057f730f67cd088a42be6fdf91f8639d82cb69e48cde80413c \
    "$S5_ASSET_SHA256"

S5_ARCHNAME=riscv64
t_run s5_asset_select
assert_ne "unsupported architecture has no Xray asset" 0 "$T_STATUS"

# The downloader must never use an unpinned channel or an unverified sidecar.
source=$(cat "$ROOT/socks5.sh")
assert_not_contains "asset URL is not latest" '/releases/latest' "$source"
assert_not_contains "asset URL is not dev-latest" 'dev-latest' "$source"
assert_contains "asset download is HTTPS-only" "--proto '=https'" "$source"
assert_contains "asset download is bounded" '--max-filesize' "$source"

# The production service command uses Xray's config-test and explicit config path.
assert_contains "config test uses Xray run test" 'run -test -c' "$source"
assert_contains "service runs Xray with explicit config" 'run -c $S5_CFG' "$source"
assert_contains "service prevents restart on Xray config error" \
    'RestartPreventExitStatus=23' "$source"

# No source-build toolchain belongs in an Xray-only product.
for forbidden in 'git clone' 'make -f' 'gcc' '3proxy' 'users.cfg'; do
    assert_not_contains "Xray path excludes $forbidden" "$forbidden" "$source"
done

# SPEC 7: the archive's members are inspected and the unsafe ones refused. Those
# refusals are reachable only through S5_TEST_ASSET_PATH, which makes the
# download step copy a local archive instead of fetching the pinned one. The
# archive's byte size and SHA-256 are verified before any member is looked at, so
# the s5_asset_select override below republishes those two from the fixture
# itself; S5T_SIZE_OVERRIDE and S5T_SHA_OVERRIDE put a wrong one back to prove
# the hook did not turn the gate into a bypass.
if ! command -v python3 >/dev/null 2>&1 ||
    ! command -v unzip >/dev/null 2>&1 ||
    ! command -v file >/dev/null 2>&1; then
    t_skip "crafted Xray archives are inspected" "python3, unzip or file is unavailable"
    t_summary
fi

S5_LANG=en
S5_ARCHNAME=amd64
S5T_ASSETS=$S5_TEST_ROOT/assets
mkdir -p "$S5T_ASSETS"
S5T_SIZE_OVERRIDE=''
S5T_SHA_OVERRIDE=''
S5T_BIN_SIZE=''
S5T_BIN_SHA256=''
cat >"$S5T_ASSETS/mkasset.py" <<'MKASSET'
import hashlib
import struct
import sys
import warnings
import zipfile

# One fixture repeats a member name on purpose, which zipfile reports as a
# UserWarning on stderr.
warnings.filterwarnings('ignore')

REG = 0o100644
EXE = 0o100755
LNK = 0o120777
DEV = 0o020666


def stub_xray():
    # 64 bytes is all file(1) needs to report an x86-64 ELF executable, which is
    # what the installer's architecture check reads. Nothing here is runnable.
    h = bytearray(64)
    h[0:7] = b'\x7fELF\x02\x01\x01'
    struct.pack_into('<HHI', h, 16, 2, 0x3E, 1)
    struct.pack_into('<H', h, 52, 64)
    return bytes(h)


XRAY = stub_xray()
DATA = [
    ('geoip.dat', b'synthetic-geoip\n'),
    ('geosite.dat', b'synthetic-geosite\n'),
    ('LICENSE', b'synthetic-license\n'),
    ('README.md', b'synthetic-readme\n'),
]


def members(case):
    good = [('xray', XRAY, EXE)] + [(n, d, REG) for n, d in DATA]
    if case == 'good':
        return good
    if case == 'noxray':
        return good[1:]
    if case == 'duplicate':
        return [good[0]] + good
    if case == 'extra':
        return good + [('install.sh', b'synthetic-extra\n', REG)]
    if case == 'subdir':
        return [('bin/xray', XRAY, EXE)] + good[1:]
    if case == 'traversal':
        return good + [('../../etc/cron.d/synthetic', b'synthetic-cron\n', REG)]
    if case == 'symlink':
        return [('xray', b'/etc/passwd', LNK)] + good[1:]
    if case == 'device':
        return [good[0], ('geoip.dat', b'', DEV)] + good[2:]
    raise SystemExit('unknown case: ' + case)


def main():
    out = sys.argv[1]
    for case in sys.argv[2:]:
        with zipfile.ZipFile('%s/%s.zip' % (out, case), 'w') as zf:
            for name, data, mode in members(case):
                info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
                info.external_attr = mode << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                zf.writestr(info, data)
    sys.stdout.write('%d %s\n' % (len(XRAY), hashlib.sha256(XRAY).hexdigest()))


main()
MKASSET

S5T_META=$(python3 "$S5T_ASSETS/mkasset.py" "$S5T_ASSETS" \
    good noxray duplicate extra subdir traversal symlink device) || S5T_META=''
assert_ne "the crafted archives were built" '' "$S5T_META"
S5T_BIN_SIZE=${S5T_META%% *}
S5T_BIN_SHA256=${S5T_META##* }

# BusyBox ships an unzip without -Z, and the member listing the installer reads
# comes from -Z1. Without it no member is inspected at all, so refusing to run is
# the only honest outcome.
if ! unzip -Z1 "$S5T_ASSETS/good.zip" >/dev/null 2>&1; then
    t_skip "crafted Xray archives are inspected" "the unzip on PATH has no -Z"
    t_summary
fi

# ShellCheck reads call order statically, so redefining the selector at the top
# level would report the two pinned calls above as calls to a function defined
# later. Installing it from a function keeps it out of that analysis.
s5t_use_fixture_selector() {
    s5_asset_select() {
        S5_ASSET_NAME=Xray-linux-64.zip
        S5_ASSET_SIZE=${S5T_SIZE_OVERRIDE:-$(wc -c <"$S5_TEST_ASSET_PATH" | tr -d '[:space:]')}
        S5_ASSET_SHA256=${S5T_SHA_OVERRIDE:-$(sha256sum "$S5_TEST_ASSET_PATH" | awk '{print $1}')}
        S5_ASSET_BINARY_SIZE=$S5T_BIN_SIZE
        S5_ASSET_BINARY_SHA256=$S5T_BIN_SHA256
    }
}
s5t_use_fixture_selector

# s5t_asset_run <case>: drive the real download path against one crafted archive.
s5t_asset_run() {
    S5_TEST_ASSET_PATH=$S5T_ASSETS/$1.zip
    S5_WORKDIR=$S5_TEST_ROOT/work-$1
    rm -rf "$S5_WORKDIR"
    mkdir -p "$S5_WORKDIR"
    rm -f "$S5_BIN"
    t_run s5_download_engine
}

# s5t_asset_reject <case> <subject> <reason>: a refusal has to name the guarantee
# it broke, so the reported reason is asserted alongside the status.
s5t_asset_reject() {
    s5t_asset_run "$1"
    assert_ne "$2 is refused" 0 "$T_STATUS"
    assert_contains "$2 reports $3" "Xray asset verification failed: $3." "$T_OUT"
    assert_file_absent "$2 installs no binary" "$S5_BIN"
}

# The positive control. Without it a fixture malformed in some unrelated way
# would make every refusal below pass for the wrong reason.
s5t_asset_run good
assert_eq "a well-formed archive is accepted" 0 "$T_STATUS"
assert_eq "an accepted archive reports nothing" '' "$T_OUT"
assert_file_exists "an accepted archive installs xray" "$S5_BIN"
assert_eq "the installed xray is the verified member" "$S5T_BIN_SHA256" \
    "$(sha256sum "$S5_BIN" | awk '{print $1}')"
assert_mode "the installed xray is executable" 755 "$S5_BIN"

s5t_asset_reject noxray "an archive with no xray member" members
s5t_asset_reject duplicate "an archive with a duplicate xray member" members
s5t_asset_reject extra "an archive with an unexpected extra member" members
s5t_asset_reject subdir "an archive whose xray member carries a path separator" members
s5t_asset_reject traversal "an archive with a parent-directory member" members
s5t_asset_reject symlink "an archive whose xray member is a symlink" members
s5t_asset_reject device "an archive with a device member" members

# A local archive still has to clear the archive gate that runs ahead of the
# member inspection, or the hook itself would be the way past it.
S5T_SIZE_OVERRIDE=1
s5t_asset_reject good "an archive of an unexpected size" size
S5T_SIZE_OVERRIDE=''
# The mismatching values are deliberately not 64 hex characters. The pinned-digest
# oracle in test_xray_docs.sh requires every 64-hex string in this file to be a
# real pin, so a plausible-looking placeholder here would read as a mistyped pin.
S5T_SHA_OVERRIDE=not-the-pinned-archive-digest
s5t_asset_reject good "an archive with an unexpected digest" sha256
S5T_SHA_OVERRIDE=''
S5T_BIN_SHA256=not-the-pinned-binary-digest
s5t_asset_reject good "an archive whose xray member has an unexpected digest" \
    binary-sha256
S5T_BIN_SHA256=${S5T_META##* }

t_summary
