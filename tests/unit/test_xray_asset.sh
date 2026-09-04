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
assert_contains "asset download is bounded" '--max-time' "$source"

# The production service command uses Xray's config-test and explicit config path.
assert_contains "config test uses Xray run test" 'run -test -c' "$source"
assert_contains "service runs Xray with explicit config" 'run -c $S5_CFG' "$source"
assert_contains "service prevents restart on Xray config error" \
    'RestartPreventExitStatus=23' "$source"

# No source-build toolchain belongs in an Xray-only product.
for forbidden in 'git clone' 'make -f' 'gcc' '3proxy' 'users.cfg'; do
    assert_not_contains "Xray path excludes $forbidden" "$forbidden" "$source"
done

t_summary
