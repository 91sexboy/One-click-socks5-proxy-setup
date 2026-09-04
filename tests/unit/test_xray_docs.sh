#!/bin/sh
# Cross-file consistency of the pinned Xray release facts.
#
# The release digests are hand-copied into the spec, both READMEs, the
# installer, the workflow and the protocol launcher. Nothing else makes those
# copies agree, and a test that restates the same literal cannot notice the
# literal is itself malformed.
#
# Provenance of the expected values: the official v26.3.27 release digest
# sidecars (Xray-linux-64.zip.dgst, Xray-linux-arm64-v8a.zip.dgst), confirmed
# by hashing the downloaded archives and their extracted xray members.

S5T_NAME=test_xray_docs
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
ROOT=${S5_REPO_ROOT}
t_mktestroot
S5_LIB_ONLY=1
S5_ASSUME_ROOT=1
S5_SKIP_OWNERSHIP=1
export S5_LIB_ONLY S5_ASSUME_ROOT S5_SKIP_OWNERSHIP
# shellcheck source=/dev/null
. "$ROOT/socks5.sh"

EXPECT_AMD64_ARCHIVE_SIZE=21136402
EXPECT_AMD64_ARCHIVE_SHA=23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae
EXPECT_AMD64_BINARY_SIZE=36577406
EXPECT_AMD64_BINARY_SHA=8255dd939c34cf966cc91517b6324dd3c8d0bcf49ffac8beca049a38c46845ed
EXPECT_ARM64_ARCHIVE_SIZE=19716427
EXPECT_ARM64_ARCHIVE_SHA=4d30283ae614e3057f730f67cd088a42be6fdf91f8639d82cb69e48cde80413c
EXPECT_ARM64_BINARY_SIZE=34209918
EXPECT_ARM64_BINARY_SHA=c2d20a7045250497083afea0d79db0672f6c89a25aaaf37c92de034d6b764b04
# The lint pins its own shellcheck build; verified with `sha256sum -c` against
# the upstream release tarball.
EXPECT_SHELLCHECK_SHA=6c881ab0698e4e6ea235245f22832860544f17ba386442fe7e9d629f8cbedf87

PINNED_FILES='SPEC.md
README.md
README.zh-CN.md
socks5.sh
.github/workflows/ci.yml
tests/protocol/start_engine.sh
tests/unit/test_xray_asset.sh'

t_is_sha256() {
    case "${1:-}" in
    '' | *[!0-9a-f]*) return 1 ;;
    esac
    [ "${#1}" -eq 64 ]
}

KNOWN_DIGESTS="$EXPECT_AMD64_ARCHIVE_SHA
$EXPECT_AMD64_BINARY_SHA
$EXPECT_ARM64_ARCHIVE_SHA
$EXPECT_ARM64_BINARY_SHA
$EXPECT_SHELLCHECK_SHA"

t_known_digest() {
    for _k in $KNOWN_DIGESTS; do
        [ "$_k" = "$1" ] && return 0
    done
    return 1
}

for _e in \
    "amd64 archive:$EXPECT_AMD64_ARCHIVE_SHA" \
    "amd64 binary:$EXPECT_AMD64_BINARY_SHA" \
    "arm64 archive:$EXPECT_ARM64_ARCHIVE_SHA" \
    "arm64 binary:$EXPECT_ARM64_BINARY_SHA" \
    "shellcheck tarball:$EXPECT_SHELLCHECK_SHA"; do
    _label=${_e%%:*}
    _value=${_e#*:}
    if t_is_sha256 "$_value"; then
        t_ok
    else
        t_bad "expected $_label digest is not 64 hex characters (${#_value})"
    fi
done

S5_ARCHNAME=amd64
s5_asset_select
assert_eq "installer amd64 archive size" "$EXPECT_AMD64_ARCHIVE_SIZE" "$S5_ASSET_SIZE"
assert_eq "installer amd64 archive digest" "$EXPECT_AMD64_ARCHIVE_SHA" "$S5_ASSET_SHA256"
assert_eq "installer amd64 binary size" "$EXPECT_AMD64_BINARY_SIZE" "$S5_ASSET_BINARY_SIZE"
assert_eq "installer amd64 binary digest" "$EXPECT_AMD64_BINARY_SHA" "$S5_ASSET_BINARY_SHA256"

S5_ARCHNAME=arm64
s5_asset_select
assert_eq "installer arm64 archive size" "$EXPECT_ARM64_ARCHIVE_SIZE" "$S5_ASSET_SIZE"
assert_eq "installer arm64 archive digest" "$EXPECT_ARM64_ARCHIVE_SHA" "$S5_ASSET_SHA256"
assert_eq "installer arm64 binary size" "$EXPECT_ARM64_BINARY_SIZE" "$S5_ASSET_BINARY_SIZE"
assert_eq "installer arm64 binary digest" "$EXPECT_ARM64_BINARY_SHA" "$S5_ASSET_BINARY_SHA256"

# A hex run that is neither a 40-character revision nor one of the four known
# 64-character digests is a hand-copy that drifted.
for _rel in $PINNED_FILES; do
    _f="$ROOT/$_rel"
    if [ ! -f "$_f" ]; then
        t_bad "pinned file is missing: $_rel"
        continue
    fi
    # A `while read` loop would run in a subshell and lose the assertion
    # counters, so the token list is word-split deliberately. Hex has no IFS
    # characters and no glob characters.
    # shellcheck disable=SC2013
    for _tok in $(grep -ohE '[0-9a-f]{32,}' "$_f" | sort -u); do
        case "${#_tok}" in
        40) t_ok ;;
        64)
            if t_known_digest "$_tok"; then
                t_ok
            else
                t_bad "$_rel carries an unknown 64-character digest: $_tok"
            fi
            ;;
        *) t_bad "$_rel carries a malformed digest of length ${#_tok}: $_tok" ;;
        esac
    done
    if grep -qF "$EXPECT_AMD64_ARCHIVE_SHA" "$_f"; then
        t_ok
    else
        t_bad "$_rel does not carry the amd64 archive digest"
    fi
    if grep -qF "$EXPECT_ARM64_ARCHIVE_SHA" "$_f"; then
        t_ok
    else
        t_bad "$_rel does not carry the arm64 archive digest"
    fi
done

# SPEC 8: explicit job timeouts, no continue-on-error, and a lint whose
# coverage cannot shrink without this file noticing.
CI=$ROOT/.github/workflows/ci.yml
ci_text=$(cat "$CI")

if grep -qE '^[[:space:]]+continue-on-error[[:space:]]*:' "$CI"; then
    t_bad 'no job in the workflow may declare continue-on-error'
else
    t_ok
fi
assert_contains "the workflow guards continue-on-error itself" \
    '^[[:space:]]+continue-on-error' "$ci_text"
assert_contains "secret checks use explicit conditionals" \
    "if sudo grep -q 'CISecret_123~x'" "$ci_text"

_jobs=$(awk '/^jobs:/{f=1;next} f && /^  [a-z][a-z0-9-]*:$/{n++} END{print n+0}' "$CI")
_tos=$(grep -c '^    timeout-minutes:' "$CI")
assert_eq "every job declares a job-level timeout" "$_jobs" "$_tos"
assert_contains "the workflow guards its own timeout coverage" \
    "timeout-minutes:" "$ci_text"

assert_contains "shellcheck is pinned, not taken from the distro" \
    'shellcheck-v0.10.0' "$ci_text"
assert_contains "the shellcheck download is checksum-verified" \
    'sha256sum -c' "$ci_text"
assert_contains "the shellcheck pin carries its digest" \
    "$EXPECT_SHELLCHECK_SHA" "$ci_text"

for _root in tests/run.sh 'tests/lib/*.sh' 'tests/unit/*.sh' \
    'tests/protocol/*.sh' '.github/scripts/*.sh'; do
    assert_contains "shellcheck covers $_root" "$_root" "$ci_text"
done

# Every shell file must live in a directory the lint globs actually reach. The
# file list comes from git so that .gitignore decides what CI actually sees;
# tracked-but-deleted paths are filtered by existence.
if command -v git >/dev/null 2>&1 && [ -d "$ROOT/.git" ]; then
    _shlist=$(cd "$ROOT" && {
        git ls-files '*.sh'
        git ls-files --others --exclude-standard '*.sh'
    } 2>/dev/null | sort -u)
    for _sh in $_shlist; do
        [ -f "$ROOT/$_sh" ] || continue
        _dir=${_sh%/*}
        [ "$_dir" = "$_sh" ] && _dir=.
        case "$_dir" in
        . | tests | tests/lib | tests/unit | tests/protocol | .github/scripts) t_ok ;;
        *) t_bad "shell file in a directory the lint does not reach: $_sh" ;;
        esac
    done
else
    t_skip "shell files all live in linted directories" "git is unavailable"
fi

# A check that cannot fail is not a check.
_defused=$(grep -n 'grep -q' "$CI" | grep '|| true' | grep -v '&& exit' || true)
if [ -z "$_defused" ]; then
    t_ok
else
    t_bad "workflow has a grep check defused by || true: $_defused"
fi

# SPEC 8 memory evidence: the sampler's cgroup branch has to actually run, OOM
# counters have to be recorded, and the four connection stages kept separate.
sampler_text=$(cat "$ROOT/.github/scripts/memory-sample.sh")
assert_contains "the sampler records cgroup OOM counters" \
    '_cgroup_oom=' "$sampler_text"
assert_contains "the sampler records cgroup OOM kills" \
    '_cgroup_oom_kill=' "$sampler_text"
assert_contains "the memory job passes a cgroup directory to the sampler" \
    'memory-sample.sh "$pid" idle "$cgdir"' "$ci_text"
assert_contains "the memory job resets peak before sampling" \
    'memory-sample.sh "$pid" reset "$cgdir"' "$ci_text"
assert_contains "the memory job resolves the service cgroup" \
    'ControlGroup' "$ci_text"
assert_contains "the memory job records startup time" \
    'xray_startup_usec' "$ci_text"
assert_contains "the memory job samples 1, 32 and 128 connections" \
    'for stage in 1 32 128; do' "$ci_text"
assert_contains "each connection stage carries its own label" \
    'memory-sample.sh "$pid" "conn$stage" "$cgdir"' "$ci_text"
assert_contains "the memory job asserts the cgroup OOM counters" \
    'memory.events' "$ci_text"
assert_contains "the memory job loads connections to sample under" \
    'hold_connections.py' "$ci_text"
assert_contains "OpenRC lifecycle job covers Alpine" 'openrc-integration' "$ci_text"
assert_contains "OpenRC lifecycle job tests both supported versions" 'alpine:3.20' "$ci_text"
assert_contains "OpenRC lifecycle job tests current Alpine" 'alpine:3.24' "$ci_text"

# SPEC 5 crash recovery and the exit-23 guard are documented claims, so each
# needs a step behind it. The backend-specific lifecycle checks must remain
# consistent with the target platform; systemd uses its native guard and Alpine
# uses the OpenRC integration job.
assert_contains "the lifecycle job kills the service to prove recovery" \
    'sudo kill -9 "$crash_pid"' "$ci_text"
assert_contains "the lifecycle job proves the exit-23 restart guard" \
    'ExecMainStatus' "$ci_text"
for _doc in README.md README.zh-CN.md SPEC.md; do
    _doctext=$(cat "$ROOT/$_doc")
    if grep -qi 'alpine' "$ROOT/$_doc" && grep -qi 'openrc' "$ROOT/$_doc"; then
        t_ok
        t_ok
    else
        t_bad "$_doc documents the Alpine target"
        t_bad "$_doc documents the OpenRC backend"
    fi
done

t_summary
