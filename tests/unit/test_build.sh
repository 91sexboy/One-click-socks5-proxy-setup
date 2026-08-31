#!/bin/sh
# tests/unit/test_build.sh - verified release-asset selection and installation.

S5T_NAME=test_build
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
. "${S5_REPO_ROOT}/tests/lib/stub.sh"
. "${S5_REPO_ROOT}/tests/lib/env.sh"

s5env_setup
s5env_load

assert_eq "engine release tag is pinned" \
    engine-3proxy-0.9.9.0-r1 "$S5_ENGINE_RELEASE"
assert_eq "upstream version remains pinned" 0.9.9.0 "$S5_UPSTREAM_TAG"
assert_eq "upstream commit remains pinned" \
    da99424eac4092e3722f1a5b1844cfe80478f580 "$S5_PINNED_COMMIT"

_test_sha=$S5_TEST_ASSET_SHA256
_test_size=$S5_TEST_ASSET_SIZE
unset S5_TEST_ASSET_SHA256 S5_TEST_ASSET_SIZE

check_asset() {
    S5_OS_FAMILY=$1
    S5_ARCHNAME=$2
    s5_select_engine_asset >/dev/null 2>&1
    assert_eq "$1/$2 asset name" "$3" "$S5_ASSET_NAME"
    assert_eq "$1/$2 asset sha256" "$4" "$S5_ASSET_SHA256"
    assert_eq "$1/$2 asset size" "$5" "$S5_ASSET_SIZE"
    assert_contains "$1/$2 URL uses immutable engine release" \
        "/releases/download/$S5_ENGINE_RELEASE/$3" "$S5_ASSET_URL"
}

check_asset debian amd64 3proxy-0.9.9.0-da99424-linux-glibc-amd64 \
    ce3c604d0133df0028b4e9cd93c326b36790db789c769b2a2c78b400b9967a80 263168
check_asset el amd64 3proxy-0.9.9.0-da99424-linux-glibc-amd64 \
    ce3c604d0133df0028b4e9cd93c326b36790db789c769b2a2c78b400b9967a80 263168
check_asset debian arm64 3proxy-0.9.9.0-da99424-linux-glibc-arm64 \
    344e482272e5c16d1f9c762d7ed240cda43bb050a53be767e5393a616607ccf5 279288
check_asset alpine amd64 3proxy-0.9.9.0-da99424-linux-musl-amd64 \
    ac3fe1a7d52d2b1494d4d00884fc7517acb2340454c2653c95a7346c05d69298 298280
check_asset alpine arm64 3proxy-0.9.9.0-da99424-linux-musl-arm64 \
    38f2733dfc5d375a4faaebe79f66bd181c7cc3e7b3eb9443c3ac4476fbfeebeb 277624

S5_OS_FAMILY=debian
S5_ARCHNAME=riscv64
t_run s5_select_engine_asset
assert_eq "unsupported asset tuple is rejected" "$EX_UNSUPPORTED" "$T_STATUS"

S5_TEST_ASSET_SHA256=$_test_sha
S5_TEST_ASSET_SIZE=$_test_size
export S5_TEST_ASSET_SHA256 S5_TEST_ASSET_SIZE

count_transfer_dirs() {
    if [ -d "$S5_TEST_ROOT/build" ]; then
        find "$S5_TEST_ROOT/build" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -c . || true
    else
        printf '0'
    fi
}

reset_case() {
    rm -rf "${S5_TEST_ROOT:?}/build" "${S5_PREFIX:?}"
    rm -f "$S5_TEST_ROOT/stub_asset_download_fail" \
        "$S5_TEST_ROOT/stub_asset_truncated" "$S5_TEST_ROOT/stub_asset_corrupt" \
        "$S5_TEST_ROOT/stub_asset_oversized_unknown"
    : >"$T_TRANSCRIPT"
    S5_OS_FAMILY=debian
    S5_ARCHNAME=amd64
    s5_select_engine_asset
}

# Happy path: one bounded HTTPS download, exact size/hash, one installed binary.
reset_case
t_run s5_fetch_verified_engine
assert_eq "verified asset installation succeeds" 0 "$T_STATUS"
assert_file_exists "binary installed" "$S5_BIN"
assert_mode "binary is mode 0755" 755 "$S5_BIN"
assert_eq "installed bytes match the fixture" \
    "$(sha256sum "$S5_TEST_ROOT/stub_engine_asset" | cut -d' ' -f1)" \
    "$(sha256sum "$S5_BIN" | cut -d' ' -f1)"
assert_eq "temporary download tree removed" 0 "$(count_transfer_dirs)"
t_assert_called "download uses the immutable release asset" "$S5_ASSET_URL"
t_assert_called "download follows HTTPS redirects only" "--proto-redir =https"
t_assert_called "download caps response size" "--max-filesize $S5_ASSET_SIZE"
t_assert_cmd_never_called "target host never invokes source-build tools" git make gcc cc

# A transport/HTTP failure leaves no binary or transfer directory.
reset_case
: >"$S5_TEST_ROOT/stub_asset_download_fail"
t_run s5_fetch_verified_engine
assert_ne "asset download failure aborts" 0 "$T_STATUS"
assert_contains "asset download failure is explained" "failed to download" "$T_OUT"
assert_file_absent "download failure installs nothing" "$S5_BIN"
assert_eq "download failure removes temporary files" 0 "$(count_transfer_dirs)"

# Unknown-length responses must be stopped while bytes are arriving. The N+1
# sentinel proves a valid N-byte prefix followed by junk cannot be accepted, and
# that old curl versions cannot fill the workdir before the size check runs.
reset_case
: >"$S5_TEST_ROOT/stub_asset_oversized_unknown"
t_run s5_fetch_verified_engine
assert_ne "unknown-length oversized asset aborts" 0 "$T_STATUS"
assert_contains "oversized asset reports the bounded sentinel size" \
    "got $((S5_ASSET_SIZE + 1)) bytes" "$T_OUT"
assert_file_absent "oversized asset installs nothing" "$S5_BIN"
assert_eq "oversized asset removes FIFO and workdir" 0 "$(count_transfer_dirs)"

# A short response is rejected before hashing or installation.
reset_case
: >"$S5_TEST_ROOT/stub_asset_truncated"
t_run s5_fetch_verified_engine
assert_ne "truncated asset aborts" 0 "$T_STATUS"
assert_contains "truncated asset reports the size mismatch" "size check failed" "$T_OUT"
assert_file_absent "truncated asset installs nothing" "$S5_BIN"
assert_eq "truncated asset leaves no temporary tree" 0 "$(count_transfer_dirs)"

# Same-size corruption reaches and fails the embedded digest check.
reset_case
: >"$S5_TEST_ROOT/stub_asset_corrupt"
t_run s5_fetch_verified_engine
assert_ne "same-size corrupt asset aborts" 0 "$T_STATUS"
assert_contains "corrupt asset reports SHA-256 failure" "SHA-256 verification failed" "$T_OUT"
assert_file_absent "corrupt asset installs nothing" "$S5_BIN"
assert_eq "corrupt asset leaves no temporary tree" 0 "$(count_transfer_dirs)"

# Final installed bytes are verified again after the atomic copy.
reset_case
s5_install_binary() {
    mkdir -p "$S5_PREFIX"
    cp "$1" "$S5_BIN"
    printf X >>"$S5_BIN"
    chmod 0755 "$S5_BIN"
}
t_run s5_fetch_verified_engine
unset -f s5_install_binary
assert_ne "post-install digest mismatch aborts" 0 "$T_STATUS"
assert_contains "post-install mismatch is explained" "installed binary SHA-256" "$T_OUT"
assert_file_absent "post-install mismatch removes the target" "$S5_BIN"
assert_eq "post-install mismatch leaves no temporary tree" 0 "$(count_transfer_dirs)"

# The production path prefers disk-backed /var/tmp and falls back only when it
# cannot use that directory. This is structural to avoid writing outside tests.
workdir_fn=$(sed -n '/^s5_make_workdir() {/,/^}/p' "$S5_SRC")
assert_contains "production download prefers /var/tmp" '_wdbase=/var/tmp' "$workdir_fn"
assert_contains "production download has a /tmp fallback" '${TMPDIR:-/tmp}' "$workdir_fn"

src=$(cat "$S5_SRC")
assert_not_contains "installer no longer clones source" 'git clone' "$src"
assert_not_contains "installer no longer invokes make" 'make -f Makefile.Linux' "$src"
assert_not_contains "installer no longer stores compiler output" '_bout=' "$src"

t_summary
