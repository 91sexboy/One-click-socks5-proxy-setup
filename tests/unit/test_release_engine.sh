#!/bin/sh
# tests/unit/test_release_engine.sh - immutable prebuilt-engine workflow contract.

S5T_NAME=test_release_engine
. "${S5_REPO_ROOT}/tests/lib/assert.sh"

R=${S5_REPO_ROOT:?S5_REPO_ROOT unset}
BUILDER="$R/.github/scripts/build-engine.sh"
WORKFLOW="$R/.github/workflows/release-engine.yml"

assert_file_exists "engine build script exists" "$BUILDER"
assert_file_exists "engine release workflow exists" "$WORKFLOW"

t_run sh -n "$BUILDER"
assert_eq "engine build script is POSIX-shell syntax" 0 "$T_STATUS"

build=$(cat "$BUILDER")
workflow=$(cat "$WORKFLOW")

for required in \
    'UPSTREAM_TAG=0.9.9.0' \
    'UPSTREAM_COMMIT=da99424eac4092e3722f1a5b1844cfe80478f580' \
    '--depth 1' \
    '--single-branch' \
    '--no-checkout' \
    'rev-parse HEAD' \
    'make -j1 -C "$SRC/src" -f ../Makefile.Linux' \
    'WOLFSSL_CHECK=false' \
    'OPENSSL_CHECK=false' \
    'PCRE_CHECK=false' \
    'PAM_CHECK=false' \
    'PLUGINS=' \
    "EXTRA_CFLAGS='-O2 -fno-lto'" \
    "EXTRA_LDFLAGS='-fno-lto'" \
    'strip "$BIN"' \
    'readelf -h' \
    'RPATH|RUNPATH'; do
    assert_contains "builder keeps required invariant: $required" "$required" "$build"
done
assert_not_contains "builder never invokes upstream make install" 'make install' "$build"
assert_not_contains "builder does not invoke the full default target" 'make -f Makefile.Linux' "$build"

for asset in \
    3proxy-0.9.9.0-da99424-linux-glibc-amd64 \
    3proxy-0.9.9.0-da99424-linux-glibc-arm64 \
    3proxy-0.9.9.0-da99424-linux-musl-amd64 \
    3proxy-0.9.9.0-da99424-linux-musl-arm64; do
    assert_contains "workflow names release asset $asset" "$asset" "$workflow"
done
assert_contains "workflow pins the engine release tag" \
    'ENGINE_TAG: engine-3proxy-0.9.9.0-r1' "$workflow"
assert_contains "workflow pins the CentOS builder image" \
    'stream9@sha256:64e5a212e4f2e7b706dbd822968914bb8def7de0a7fdfd3bf248241f8758101c' "$workflow"
assert_contains "workflow pins the Alpine builder image" \
    'alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc' "$workflow"
assert_contains "workflow attests the exact release binaries" \
    'actions/attest-build-provenance@43d14bc2b83dec42d39ecae14e916627a18bb661' "$workflow"
assert_contains "workflow refuses to replace an existing release" \
    'gh release view "$ENGINE_TAG"' "$workflow"
assert_contains "workflow refuses to move an existing tag" \
    'git ls-remote --exit-code --tags origin' "$workflow"
assert_contains "workflow publishes a prerelease" '--prerelease' "$workflow"
assert_contains "workflow emits one checksum manifest" 'SHA256SUMS' "$workflow"

if grep -Eq 'uses: [^@[:space:]]+@v[0-9]' "$WORKFLOW"; then
    t_bad "every third-party action must be pinned to a full commit"
else
    t_ok
fi

if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    t_run python3 - "$WORKFLOW" <<'PY'
import sys
import yaml
with open(sys.argv[1], encoding="utf-8") as handle:
    workflow = yaml.safe_load(handle)
jobs = workflow["jobs"]
assert len(jobs["build"]["strategy"]["matrix"]["include"]) == 4
assert jobs["build"]["permissions"] if "permissions" in jobs["build"] else True
assert jobs["release"]["permissions"] == {
    "contents": "write",
    "id-token": "write",
    "attestations": "write",
}
PY
    assert_eq "release workflow parses and has four build tuples" 0 "$T_STATUS"
else
    t_skip "release workflow YAML parse" "python3/PyYAML is unavailable"
fi

t_summary
