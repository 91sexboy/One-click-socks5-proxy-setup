#!/bin/sh
# tests/unit/test_release_engine.sh - versioned prebuilt-engine workflow contract.

S5T_NAME=test_release_engine
. "${S5_REPO_ROOT}/tests/lib/assert.sh"

R=${S5_REPO_ROOT:?S5_REPO_ROOT unset}
BUILDER="$R/.github/scripts/build-engine.sh"
GLIBC_VERIFIER="$R/.github/scripts/verify-glibc-floor.sh"
WORKFLOW="$R/.github/workflows/release-engine.yml"

assert_file_exists "engine build script exists" "$BUILDER"
assert_file_exists "GLIBC floor verifier exists" "$GLIBC_VERIFIER"
assert_file_exists "engine release workflow exists" "$WORKFLOW"

t_run sh -n "$BUILDER"
assert_eq "engine build script is POSIX-shell syntax" 0 "$T_STATUS"
t_run sh -n "$GLIBC_VERIFIER"
assert_eq "GLIBC floor verifier is POSIX-shell syntax" 0 "$T_STATUS"

_floor_tmp=$(mktemp -d)
printf 'fixture\n' >"$_floor_tmp/asset"
mkdir "$_floor_tmp/bin"
cat >"$_floor_tmp/bin/readelf" <<'READELF_OK'
#!/bin/sh
printf 'Version needs section: GLIBC_2.2.5 GLIBC_2.31\n'
READELF_OK
chmod 0755 "$_floor_tmp/bin/readelf"
t_run env PATH="$_floor_tmp/bin:$PATH" sh "$GLIBC_VERIFIER" "$_floor_tmp/asset" 2 31
assert_eq "GLIBC 2.31 floor accepts patch-level and exact requirements" 0 "$T_STATUS"
assert_contains "GLIBC verifier reports the exact maximum" 'max_required_glibc=2.31' "$T_OUT"
cat >"$_floor_tmp/bin/readelf" <<'READELF_NEW'
#!/bin/sh
printf 'Version needs section: GLIBC_2.2.5 GLIBC_2.34\n'
READELF_NEW
chmod 0755 "$_floor_tmp/bin/readelf"
t_run env PATH="$_floor_tmp/bin:$PATH" sh "$GLIBC_VERIFIER" "$_floor_tmp/asset" 2 31
assert_ne "GLIBC 2.31 floor rejects a 2.34 requirement" 0 "$T_STATUS"
assert_contains "GLIBC rejection names the incompatible requirement" 'GLIBC_2.34' "$T_OUT"
rm -rf "$_floor_tmp"

build=$(cat "$BUILDER")
verifier=$(cat "$GLIBC_VERIFIER")
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
    'verify-glibc-floor.sh' \
    'builder_image=' \
    'builder_libc_version=' \
    'RPATH|RUNPATH'; do
    assert_contains "builder keeps required invariant: $required" "$required" "$build"
done
for required in \
    'readelf --version-info' \
    'MAX_MAJOR=' \
    'MAX_MINOR=' \
    'required_glibc_versions=' \
    'max_required_glibc='; do
    assert_contains "GLIBC verifier keeps required invariant: $required" "$required" "$verifier"
done
assert_contains "builder enforces GLIBC 2.31 through shared verifier" \
    'verify-glibc-floor.sh" "$OUTDIR/$ASSET" 2 31' "$build"
assert_contains "assembled payload reuses shared GLIBC verifier" \
    'verify-glibc-floor.sh' "$workflow"

assert_not_contains "builder never invokes upstream make install" 'make install' "$build"
assert_not_contains "builder does not invoke the full default target" 'make -f Makefile.Linux' "$build"

for asset in \
    3proxy-0.9.9.0-da99424-linux-glibc-amd64 \
    3proxy-0.9.9.0-da99424-linux-glibc-arm64 \
    3proxy-0.9.9.0-da99424-linux-musl-amd64 \
    3proxy-0.9.9.0-da99424-linux-musl-arm64; do
    assert_contains "workflow names release asset $asset" "$asset" "$workflow"
done
assert_contains "workflow pins the engine r2 release tag" \
    'ENGINE_TAG: engine-3proxy-0.9.9.0-r2' "$workflow"
assert_contains "workflow pins the source r1 release tag" \
    'SOURCE_ENGINE_TAG: engine-3proxy-0.9.9.0-r1' "$workflow"
assert_contains "workflow pins the Ubuntu 20.04 amd64 builder image" \
    'ubuntu:20.04@sha256:c664f8f86ed5a386b0a340d981b8f81714e21a8b9c73f658c4bea56aa179d54a' "$workflow"
assert_not_contains "r2 never rebuilds glibc arm64" 'build-glibc-arm64' "$workflow"
assert_not_contains "r2 never rebuilds musl assets" 'build-musl-' "$workflow"
for carried in \
    '3proxy-0.9.9.0-da99424-linux-glibc-arm64 279288 344e482272e5c16d1f9c762d7ed240cda43bb050a53be767e5393a616607ccf5' \
    '3proxy-0.9.9.0-da99424-linux-musl-amd64 298280 ac3fe1a7d52d2b1494d4d00884fc7517acb2340454c2653c95a7346c05d69298' \
    '3proxy-0.9.9.0-da99424-linux-musl-arm64 277624 38f2733dfc5d375a4faaebe79f66bd181c7cc3e7b3eb9443c3ac4476fbfeebeb'; do
    assert_contains "workflow pins carried r1 bytes: $carried" "$carried" "$workflow"
done
assert_contains "workflow records carried provenance" \
    "printf 'carried_from_release=%s" "$workflow"
assert_contains "workflow preserves original compiler provenance" \
    "grep -Fx 'upstream_commit=da99424eac4092e3722f1a5b1844cfe80478f580'" "$workflow"
assert_contains "assembled payload rechecks symbol versions" \
    'verify-glibc-floor.sh' "$workflow"
assert_contains "aggregate build info keeps asset stanzas" \
    '### asset=' "$workflow"
assert_contains "workflow attests only the newly built binary" \
    'subject-path: dist/3proxy-0.9.9.0-da99424-linux-glibc-amd64' "$workflow"
_attest_block=$(awk '/name: Attest newly built/{f=1} f && /name: Atomically claim/{exit} f' "$WORKFLOW")
assert_not_contains "carried glibc arm64 is not re-attested as newly built" \
    'glibc-arm64' "$_attest_block"
assert_not_contains "carried musl assets are not re-attested as newly built" \
    'musl-' "$_attest_block"
assert_contains "workflow refuses non-develop dispatches" \
    'test "$GITHUB_REF" = refs/heads/develop' "$workflow"
assert_contains "workflow atomically claims the tag ref" \
    '--method POST "repos/$GITHUB_REPOSITORY/git/refs"' "$workflow"
assert_contains "workflow creates a draft before uploading" '--draft' "$workflow"
assert_contains "workflow verifies the tag points at the dispatch SHA" \
    'test "$actual" = "$GITHUB_SHA"' "$workflow"
assert_contains "workflow publishes the verified draft through Releases API" \
    '--method PATCH "repos/$GITHUB_REPOSITORY/releases/$release_id"' "$workflow"
assert_contains "workflow marks the release as prerelease" \
    '-F draft=false -F prerelease=true' "$workflow"
assert_contains "workflow refuses to replace an existing release" \
    'gh release view "$ENGINE_TAG"' "$workflow"
assert_contains "release commands select the repository explicitly" \
    '--repo "$GITHUB_REPOSITORY"' "$workflow"
assert_contains "workflow refuses to move an existing tag" \
    'gh api "repos/$GITHUB_REPOSITORY/git/ref/tags/$ENGINE_TAG"' "$workflow"
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
assert "strategy" not in jobs["build"]
assert jobs["build"]["runs-on"] == "ubuntu-24.04"
assert jobs["build"]["name"] == "build-glibc-amd64"
assert jobs["build"]["permissions"] if "permissions" in jobs["build"] else True
assert jobs["release"]["permissions"] == {
    "contents": "write",
    "id-token": "write",
    "attestations": "write",
}
PY
    assert_eq "release workflow parses and has one focal glibc build" 0 "$T_STATUS"
else
    t_skip "release workflow YAML parse" "python3/PyYAML is unavailable"
fi

t_summary
