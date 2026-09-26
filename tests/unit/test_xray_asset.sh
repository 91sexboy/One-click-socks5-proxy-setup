#!/bin/sh
# Xray release asset metadata and safe selection tests.

S5T_NAME=test_xray_asset
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
ROOT=${S5_REPO_ROOT}
t_mktestroot
t_source_production ''

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
assert_eq "arm64 extracted xray size" 34209918 "$S5_ASSET_BINARY_SIZE"
assert_eq "arm64 extracted xray digest" \
    c2d20a7045250497083afea0d79db0672f6c89a25aaaf37c92de034d6b764b04 \
    "$S5_ASSET_BINARY_SHA256"

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
# Production reaches both tools only at their absolute paths, so a PATH-probed
# `file` would let this file run in an environment production itself refuses.
if ! command -v python3 >/dev/null 2>&1 ||
    [ ! -x /usr/bin/unzip ] ||
    [ ! -x /usr/bin/file ]; then
    t_skip "crafted Xray archives are inspected" \
        "python3, /usr/bin/unzip or /usr/bin/file is unavailable"
    t_summary
fi

S5_LANG=en
S5_ARCHNAME=amd64
S5T_ASSETS=$S5_TEST_ROOT/assets
mkdir -p "$S5T_ASSETS"
S5T_META=$(python3 "$ROOT/tests/lib/mkasset.py" "$S5T_ASSETS" \
    good noxray duplicate extra subdir traversal symlink device) || S5T_META=''
assert_ne "the crafted archives were built" '' "$S5T_META"

# BusyBox ships an unzip without -Z, and the member listing the installer reads
# comes from -Z1. Without it no member is inspected at all, so refusing to run is
# the only honest outcome.
if ! /usr/bin/unzip -Z1 "$S5T_ASSETS/good.zip" >/dev/null 2>&1; then
    t_skip "crafted Xray archives are inspected" "/usr/bin/unzip has no -Z"
    t_summary
fi

. "$ROOT/tests/lib/xray-fixture.sh"
t_use_asset_fixture "$S5T_ASSETS/asset-xray" archive

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

# s5t_asset_size_reject <case> <subject> <reason> <observed> <pinned>: a size gate
# carries the length it actually saw. A rewritten stream and a write that ran out
# of room both leave a file shorter than its pin, so the reason alone cannot tell
# a maintainer which one happened -- the numbers can (ADR-0006).
s5t_asset_size_reject() {
    s5t_asset_run "$1"
    assert_ne "$2 is refused" 0 "$T_STATUS"
    assert_contains "$2 reports $3 with the bytes it observed" \
        "Xray asset verification failed: $3 is $4 bytes, expected $5." "$T_OUT"
    assert_file_absent "$2 installs no binary" "$S5_BIN"
}

# The positive control. Without it a fixture malformed in some unrelated way
# would make every refusal below pass for the wrong reason.
s5t_asset_run good
assert_eq "a well-formed archive is accepted" 0 "$T_STATUS"
assert_eq "an accepted archive reports nothing" '' "$T_OUT"
assert_file_exists "an accepted archive installs xray" "$S5_BIN"
assert_eq "the installed xray is the verified member" "$S5T_BIN_SHA256" \
    "$(t_sha256 "$S5_BIN")"
assert_mode "the installed xray is executable" 755 "$S5_BIN"

# A same-named PATH executable can reintroduce implicit options after the caller
# cleaned its own environment. Prove the hostile control changes the fixture,
# then require production's absolute command seam to bypass it completely.
_sapath=$PATH
mkdir -p "$S5_TEST_ROOT/hostile-bin"
cat >"$S5_TEST_ROOT/hostile-bin/unzip" <<'HOSTILE_UNZIP'
#!/bin/sh
printf 'called\n' >>"$S5_TEST_ROOT/hostile-unzip.calls"
UNZIP=-aa
export UNZIP
exec /usr/bin/unzip "$@"
HOSTILE_UNZIP
chmod 0755 "$S5_TEST_ROOT/hostile-bin/unzip"
PATH=$S5_TEST_ROOT/hostile-bin:$PATH
export PATH
"$S5_TEST_ROOT/hostile-bin/unzip" -p "$S5T_ASSETS/good.zip" xray \
    >"$S5_TEST_ROOT/hostile-xray"
assert_ne "the hostile PATH control changes extracted xray bytes" "$S5T_BIN_SHA256" \
    "$(t_sha256 "$S5_TEST_ROOT/hostile-xray")"
rm -f "$S5_TEST_ROOT/hostile-unzip.calls"
unzip() {
    printf 'function-called\n' >>"$S5_TEST_ROOT/hostile-unzip.calls"
    UNZIP=-aa
    export UNZIP
    /usr/bin/unzip "$@"
}
s5t_asset_run good
assert_eq "production bypasses a hostile unzip on PATH" 0 "$T_STATUS"
assert_eq "PATH isolation installs the verified xray member" "$S5T_BIN_SHA256" \
    "$(t_sha256 "$S5_BIN")"
assert_file_absent "hostile PATH and function unzips are never invoked" \
    "$S5_TEST_ROOT/hostile-unzip.calls"
PATH=$_sapath
export PATH
# Both doubles end with their case. Restoring PATH does not remove a shell
# function, and leaving it defined would put a hostile unzip under every case
# below, where nothing reads hostile-unzip.calls again.
unset -f unzip

# The tools that acquire and judge the accepted member are pinned for the same
# reason as the extractor. PATH executables or shell functions can otherwise
# replace the download or make arbitrary bytes match an arbitrary pin; file(1)
# also reads MAGIC as a database override and reports the real member as data.
mkdir -p "$S5_TEST_ROOT/hostile-tools"
# Freeze the fixture's archive metadata before PATH becomes hostile. The fixture
# selector otherwise uses the test helper's PATH-resolved sha256sum to build its
# independent expected value, which would test the harness instead of production.
S5T_SIZE_OVERRIDE=$(wc -c <"$S5T_ASSETS/good.zip" | tr -d '[:space:]')
S5T_SHA_OVERRIDE=$(/usr/bin/sha256sum "$S5T_ASSETS/good.zip" | awk '{print $1}')
cat >"$S5_TEST_ROOT/hostile-tools/curl" <<'HOSTILE_CURL'
#!/bin/sh
printf 'path-curl-called\n' >>"$S5_TEST_ROOT/hostile-curl.calls"
exit 90
HOSTILE_CURL
cat >"$S5_TEST_ROOT/hostile-tools/sha256sum" <<'HOSTILE_SHA'
#!/bin/sh
printf 'path-sha-called\n' >>"$S5_TEST_ROOT/hostile-sha.calls"
printf '%064d  %s\n' 0 "$1"
HOSTILE_SHA
cat >"$S5_TEST_ROOT/hostile-tools/file" <<'HOSTILE_FILE'
#!/bin/sh
printf 'path-file-called\n' >>"$S5_TEST_ROOT/hostile-file.calls"
printf '%s\n' 'ELF 64-bit LSB executable, ARM aarch64'
HOSTILE_FILE
chmod 0755 "$S5_TEST_ROOT/hostile-tools/curl" \
    "$S5_TEST_ROOT/hostile-tools/sha256sum" "$S5_TEST_ROOT/hostile-tools/file"
PATH=$S5_TEST_ROOT/hostile-tools:$PATH
export PATH
curl() {
    printf 'function-curl-called\n' >>"$S5_TEST_ROOT/hostile-curl.calls"
    return 90
}
sha256sum() {
    printf 'function-sha-called\n' >>"$S5_TEST_ROOT/hostile-sha.calls"
    printf '%064d  %s\n' 0 "$1"
}
file() {
    printf 'function-file-called\n' >>"$S5_TEST_ROOT/hostile-file.calls"
    printf '%s\n' 'ELF 64-bit LSB executable, ARM aarch64'
}
MAGIC=/dev/null
export MAGIC
"$S5_TEST_ROOT/hostile-tools/curl" --version >/dev/null 2>&1 || :
assert_file_exists "the hostile curl control records a direct invocation" \
    "$S5_TEST_ROOT/hostile-curl.calls"
rm -f "$S5_TEST_ROOT/hostile-curl.calls"
t_run s5_curl_command --version
assert_eq "the packaged curl seam remains callable under hostile resolution" 0 "$T_STATUS"
assert_file_absent "the packaged curl seam bypasses PATH and function wrappers" \
    "$S5_TEST_ROOT/hostile-curl.calls"
s5t_asset_run good
assert_eq "production bypasses hostile digest and type commands" 0 "$T_STATUS"
assert_eq "tool isolation installs the verified xray member" "$S5T_BIN_SHA256" \
    "$(/usr/bin/sha256sum "$S5_BIN" | awk '{print $1}')"
assert_file_absent "hostile transport commands are never invoked" \
    "$S5_TEST_ROOT/hostile-curl.calls"
assert_file_absent "hostile digest commands are never invoked" \
    "$S5_TEST_ROOT/hostile-sha.calls"
assert_file_absent "hostile type commands are never invoked" \
    "$S5_TEST_ROOT/hostile-file.calls"
assert_eq "the caller's MAGIC value is preserved" /dev/null "$MAGIC"
unset MAGIC
unset -f curl sha256sum file
PATH=$_sapath
export PATH
S5T_SIZE_OVERRIDE=''
S5T_SHA_OVERRIDE=''

# Info-ZIP treats UNZIP and UNZIPOPT as leading command-line options. `-aa`
# forces text conversion and used to alter binary bytes while `unzip -p` still
# exited zero. Production must isolate every archive operation from those
# inherited settings without modifying the caller's environment.
UNZIP=-aa
export UNZIP
s5t_asset_run good
assert_eq "UNZIP options cannot alter accepted xray bytes" 0 "$T_STATUS"
assert_eq "UNZIP-isolated extraction installs the verified member" "$S5T_BIN_SHA256" \
    "$(t_sha256 "$S5_BIN")"
assert_eq "the caller's UNZIP value is preserved" -aa "$UNZIP"
unset UNZIP

UNZIPOPT=-aa
export UNZIPOPT
s5t_asset_run good
assert_eq "UNZIPOPT options cannot alter accepted xray bytes" 0 "$T_STATUS"
assert_eq "UNZIPOPT-isolated extraction installs the verified member" "$S5T_BIN_SHA256" \
    "$(t_sha256 "$S5_BIN")"
assert_eq "the caller's UNZIPOPT value is preserved" -aa "$UNZIPOPT"
unset UNZIPOPT

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
s5t_asset_size_reject good "an archive of an unexpected size" size \
    "$(wc -c <"$S5T_ASSETS/good.zip" | tr -cd '0-9')" 1
S5T_SIZE_OVERRIDE=''
S5T_SHA_OVERRIDE=0000000000000000000000000000000000000000000000000000000000000000
s5t_asset_reject good "an archive with an unexpected digest" sha256
S5T_SHA_OVERRIDE=''
# The extracted binary's exact-size gate (distinct from its SHA-256, and checked
# just before it) had no failing input of its own -- only a wrong binary digest was
# injected. Inject a wrong expected size and require the binary-size reason, so the
# gate cannot be dropped with only the archive-size case (a different variable) left
# to notice.
S5T_BIN_SIZE=999999
s5t_asset_size_reject good "an archive whose xray member has an unexpected size" \
    binary-size "${S5T_META%% *}" 999999
S5T_BIN_SIZE=${S5T_META%% *}
S5T_BIN_SHA256=1111111111111111111111111111111111111111111111111111111111111111
s5t_asset_reject good "an archive whose xray member has an unexpected digest" \
    binary-sha256
S5T_BIN_SHA256=${S5T_META##* }

# The verified member must also be an ELF for the architecture being installed.
# mkasset builds one x86-64 stub for every case, so that gate is reached at the
# file(1) seam rather than through PATH -- PATH is the surface production
# deliberately stopped trusting for the type decision. The double delegates to
# the real command while inert, so every other case is still judged by file(1).
S5T_FILE_TYPE=''
s5_file_type_command() {
    if [ -n "$S5T_FILE_TYPE" ]; then printf '%s\n' "$S5T_FILE_TYPE"; return 0; fi
    /usr/bin/file -b "$@"
}
S5T_FILE_TYPE='ELF 64-bit LSB executable, ARM aarch64, version 1 (SYSV)'
s5t_asset_reject good "an archive whose xray member is built for another architecture" \
    architecture
S5T_FILE_TYPE=''

# Extraction has a refusal reason of its own that no crafted archive can reach:
# the member inspection ahead of it has already accepted exactly one readable
# xray. Fail the extraction itself at the unzip seam instead.
S5T_UNZIP_FAIL=''
s5_unzip_command() {
    if [ -n "$S5T_UNZIP_FAIL" ] && [ "$1" = "$S5T_UNZIP_FAIL" ]; then return 9; fi
    /usr/bin/unzip "$@"
}
S5T_UNZIP_FAIL=-p
s5t_asset_reject good "an archive whose xray member cannot be extracted" extract
S5T_UNZIP_FAIL=''

# What capacity answers is judged here, before any double exists. A double that
# delegates to the command it stands in for answers in production's place, so a
# change to production's own seam would leave every assertion below green -- these
# two cases are the ones that must fail when that seam changes, so they cannot run
# inside the doubled region that starts further down.
#
# What df calls Available is the space an unprivileged user may write, excluding the
# reserve only root can use -- and every staging command runs as root, so reading
# that figure can refuse a host with gigabytes of room. Capacity reports the
# filesystem's free blocks instead. The two figures differ only where the filesystem
# keeps a reserve, so the strict case says when it cannot be told apart.
_asset_fs=$(stat -f -c '%f %a %S' "$S5_TEST_ROOT")
_asset_free=$(s5_free_kb "$S5_TEST_ROOT")
assert_eq "capacity reads a usable answer from the filesystem" 0 "$?"
_asset_bfree=$(printf '%s\n' "$_asset_fs" | awk '{ printf "%d\n", $1 * ($3 / 1024) }')
_asset_bavail=$(printf '%s\n' "$_asset_fs" | awk '{ printf "%d\n", $2 * ($3 / 1024) }')
assert_eq "capacity counts every block root can write into" "$_asset_bfree" "$_asset_free"
if [ "$_asset_bfree" -gt "$_asset_bavail" ]; then
    assert_ne "the reserve root can use is not excluded" "$_asset_bavail" "$_asset_free"
else
    t_skip "the reserve root can use is not excluded" \
        "this filesystem keeps no reserve, so the two figures are identical"
fi

# The combined requirement below turns on filesystem identity, and identity must not
# move while the host is writing. A df row does move -- its used, available and
# capacity columns change between the two lookups, so one filesystem compares
# unequal to itself and the sum is silently skipped exactly when a busy
# single-filesystem container needs it. The device is what cannot move, so that is
# what identity has to be.
mkdir -p "$S5_TEST_ROOT/fsid"
assert_eq "filesystem identity is the device, not a figure that moves" \
    "$(stat -c '%d' "$S5_TEST_ROOT")" "$(s5_fs_id "$S5_TEST_ROOT")"
_asset_fsid=$(s5_fs_id "$S5_TEST_ROOT")
head -c 8388608 /dev/zero >"$S5_TEST_ROOT/fsid/churn" 2>/dev/null
assert_eq "two paths on one filesystem still agree after it is written to" \
    "$_asset_fsid" "$(s5_fs_id "$S5_TEST_ROOT/fsid")"
rm -f "$S5_TEST_ROOT/fsid/churn"

# A full or quota-limited filesystem is the other way the pinned size gate fails,
# and it is not an artifact problem: a real Alpine 3.22 container reported
# binary-size while /usr/bin/unzip exited 0 and left 12 MiB of a pinned 36 MiB on
# disk (ADR-0006). Capacity is asked for through one seam, so both the refusal and
# the misdiagnosis it replaces are reachable without filling a filesystem. From here
# down that seam is a double, which is why the two cases above ran before it.
S5T_FREE_KB=''
s5_fs_free_command() {
    # A 1024-byte fundamental block makes the free count and the kibibyte the same
    # number, so each case below states the figure it means.
    if [ -n "$S5T_FREE_KB" ]; then printf '%s 1024\n' "$S5T_FREE_KB"; return 0; fi
    stat -f -c '%f %S' "$1"
}

# Staging refuses before the download when the work directory cannot hold the
# archive and the extracted member together.
S5T_FREE_KB=0
s5t_asset_run good
assert_ne "staging without room is refused" 0 "$T_STATUS"
assert_contains "the refusal names the filesystem it measured" \
    'not enough space on the filesystem holding' "$T_OUT"
assert_contains "the refusal reports what is available" 'KiB available.' "$T_OUT"
assert_not_contains "a full filesystem is never called an asset failure" \
    'asset verification failed' "$T_OUT"
assert_file_absent "a refused staging run installs no binary" "$S5_BIN"

# One root filesystem holds the archive, the extracted member and the published
# copy against the same free space, so the requirement is their sum: two per-path
# checks would both pass on a host that cannot hold all three. Identity comes from
# the filesystem id, which cannot move while the host is writing -- a df row can,
# and comparing rows skipped this branch exactly when a busy container needed it.
# The pinned release sizes are used here because the fixture's bytes round to the
# same kibibyte either way, which would make the two requirements indistinguishable.
S5T_FREE_KB=''
S5T_FS_ID=''
s5_fs_id_command() {
    if [ -n "$S5T_FS_ID" ]; then
        case "$1" in
        "$S5_PREFIX") printf '%s\n' "${S5T_FS_ID##* }" ;;
        *) printf '%s\n' "${S5T_FS_ID%% *}" ;;
        esac
        return 0
    fi
    stat -c '%d' "$1"
}
_asset_size=$S5_ASSET_SIZE
_asset_bin_size=$S5_ASSET_BINARY_SIZE
S5_ASSET_SIZE=21136402
S5_ASSET_BINARY_SIZE=36577406
# 60000 KiB clears each requirement on its own (56362 KiB and 35721 KiB) but not
# the sum of all three files (92082 KiB).
S5T_FREE_KB=60000
S5T_FS_ID='2051 2051'
S5_WORKDIR=$S5_TEST_ROOT/work-shared
mkdir -p "$S5_WORKDIR"
t_run s5_stage_engine
assert_ne "one filesystem short of the whole requirement is refused" 0 "$T_STATUS"
assert_contains "the refusal asks for all three files at once" '92082 KiB required' "$T_OUT"

# Separate filesystems keep the per-path requirements, which this free space meets,
# so staging proceeds past capacity -- it fails later on the deliberately mismatched
# pins, which is not what this case is about.
S5T_FS_ID='2051 2062'
t_run s5_stage_engine
assert_not_contains "separate filesystems are not asked for the sum" \
    'not enough space' "$T_OUT"
S5T_FS_ID=''
S5T_FREE_KB=''
S5_ASSET_SIZE=$_asset_size
S5_ASSET_BINARY_SIZE=$_asset_bin_size

# The same question decides what a short file means, which is the whole point:
# the direction of the mismatch cannot, because a substituted extractor rewriting
# line endings shortens the member too (ADR-0005).
printf 'short\n' >"$S5_TEST_ROOT/truncated"
S5T_FREE_KB=0
t_run s5_accept_size "$S5_TEST_ROOT/truncated" binary-size 36577406
assert_ne "a short file on a full filesystem is refused" 0 "$T_STATUS"
assert_contains "it names the storage, not the artifact" \
    'the filesystem is full or over quota' "$T_OUT"
assert_not_contains "it does not blame asset verification" \
    'asset verification failed' "$T_OUT"
# A file longer than its pin cannot be an unfinished write, so an exhausted
# filesystem must not be offered as its explanation -- that is the same
# misdiagnosis in the other direction.
S5T_FREE_KB=0
t_run s5_accept_size "$S5_TEST_ROOT/truncated" binary-size 3
assert_ne "a file longer than its pin is refused" 0 "$T_STATUS"
assert_contains "a file longer than its pin stays an artifact refusal" \
    'Xray asset verification failed: binary-size is 6 bytes, expected 3.' "$T_OUT"
assert_not_contains "a file longer than its pin is never blamed on the disk" \
    'full or over quota' "$T_OUT"
S5T_FREE_KB=1048576
t_run s5_accept_size "$S5_TEST_ROOT/truncated" binary-size 36577406
assert_ne "the same short file with room available is still refused" 0 "$T_STATUS"
assert_contains "with room available the artifact reason stands, with its numbers" \
    'Xray asset verification failed: binary-size is 6 bytes, expected 36577406.' "$T_OUT"
assert_not_contains "a host with room is not told its filesystem is full" \
    'full or over quota' "$T_OUT"

# Capacity is advisory: the pinned size and SHA-256 remain the authority, so a host
# whose filesystem answers nothing usable must still install rather than be refused.
# The refusal and the exhaustion verdict both read through s5_free_kb, so failing
# the seam it calls is what proves an unknown answer disables the check rather than
# standing in for "no room".
S5T_FREE_KB=''
s5_fs_free_command() { return 1; }
s5t_asset_run good
assert_eq "a host whose filesystem answers nothing still installs" 0 "$T_STATUS"
assert_eq "it installs the verified xray member" "$S5T_BIN_SHA256" \
    "$(t_sha256 "$S5_BIN")"
s5_fs_free_command() {
    if [ -n "$S5T_FREE_KB" ]; then printf '%s 1024\n' "$S5T_FREE_KB"; return 0; fi
    stat -f -c '%f %S' "$1"
}

# Both seams are inert again. Without this control a double left switched on
# would make every later case refuse for the injected reason instead of its own.
s5t_asset_run good
assert_eq "the restored command seams accept a well-formed archive" 0 "$T_STATUS"
assert_eq "the restored seams install the verified xray member" "$S5T_BIN_SHA256" \
    "$(t_sha256 "$S5_BIN")"

# SPEC 4 pins the binary namespace at root:root 0755 and SPEC 5 keeps a
# recognized installation restartable and updatable after the release pins
# change. Staging makes the prefix private so a partially written .xray.XXXXXX
# cannot be read, and an update reuses a directory already at the documented
# mode -- so publication has to hand 0755 back on the refusal path as well as
# the successful one. Nothing else on the update path restores it, and a
# private prefix locks the service account out of its own installation.
mkdir -p "$S5_PREFIX"
chmod 0755 "$S5_PREFIX"
s5t_asset_run good
assert_eq "an update over an existing prefix is accepted" 0 "$T_STATUS"
assert_mode "a successful update leaves the binary namespace at 0755" 755 "$S5_PREFIX"
chmod 0755 "$S5_PREFIX"
S5T_SHA_OVERRIDE=0000000000000000000000000000000000000000000000000000000000000000
s5t_asset_run good
assert_ne "a refused update fails" 0 "$T_STATUS"
assert_contains "the refused update reports the gate it broke" \
    'Xray asset verification failed: sha256.' "$T_OUT"
assert_mode "a refused update leaves the binary namespace at 0755" 755 "$S5_PREFIX"
S5T_SHA_OVERRIDE=''

# When the restore itself cannot run, chmod's own line is untranslated and says
# nothing about the consequence, so the installer has to name it: the operator who
# reported this saw that line and no statement of what it meant. The stub fails
# only the 0755 restore of this prefix, so staging still opens its private window.
# The double is a function, not a PATH stub, because BusyBox shells resolve their
# own chmod applet before PATH and only a function reaches production's bare
# command under every shell in the matrix. It lives inside the substitution so the
# rest of this file keeps calling the real command.
/bin/chmod 0700 "$S5_PREFIX"
S5_PREFIX_PRIVATE=1
if T_OUT=$(
    chmod() {
        case "$1:$2" in
        0755:*/usr/local/libexec/xray-socks5)
            printf "chmod: changing permissions of '%s': Quota exceeded\n" "$2" >&2
            return 1
            ;;
        esac
        /bin/chmod "$@"
    }
    s5_release_prefix_private 2>&1
); then _asset_restore=0; else _asset_restore=$?; fi
assert_ne "a failed mode restore fails" 0 "$_asset_restore"
assert_contains "a failed mode restore is reported in words" \
    'could not restore installation directory' "$T_OUT"
assert_contains "the report names the mode the installation contract requires" \
    'to 0755' "$T_OUT"
# A prefix left private is not a cosmetic loss: s5_verify_installed_artifacts
# holds the prefix to exactly 0755, so every later command -- uninstall included
# -- refuses until the mode is back. The report has to say so.
assert_contains "the report names the consequence for the service account" \
    'service account' "$T_OUT"
assert_contains "the report warns that later commands refuse" \
    'later commands refuse to run' "$T_OUT"
assert_mode "a failed restore leaves the prefix private" 700 "$S5_PREFIX"

# The restore refuses for one more reason, which reaches the same report without a
# double and shows the window stays open so cleanup retries it.
_asset_prefix=$S5_PREFIX
S5_PREFIX=$S5_TEST_ROOT/prefix-not-a-directory
: >"$S5_PREFIX"
S5_PREFIX_PRIVATE=1
# Not t_run: it captures through a command substitution, so an assignment made by
# the function would never reach this shell and the flag assertion below would hold
# whatever production did with it.
if s5_release_prefix_private 2>"$S5_TEST_ROOT/prefix.err"; then
    _asset_notdir=0
else
    _asset_notdir=$?
fi
assert_ne "a prefix that is not a directory fails the restore" 0 "$_asset_notdir"
assert_contains "that refusal is reported too" \
    'could not restore installation directory' "$(cat "$S5_TEST_ROOT/prefix.err")"
# Load-bearing: cleanup retries the restore only while this window is open, and a
# prefix left at 0700 makes every later command, uninstall included, refuse.
assert_eq "a failed restore leaves the private window open" 1 "$S5_PREFIX_PRIVATE"
S5_PREFIX=$_asset_prefix
/bin/chmod 0755 "$S5_PREFIX"
S5_PREFIX_PRIVATE=0

# The signal handler can interrupt inside s5_stage_engine, before the ordinary
# return path closes the private staging window. Drive cleanup from that exact
# point and require it to hand the existing installation's traversal mode back.
chmod 0755 "$S5_PREFIX"
S5_PREFIX_PRIVATE=0
s5_stage_engine() {
    assert_mode "the signal arrives while staging is private" 700 "$S5_PREFIX"
    s5_cleanup
    assert_mode "signal cleanup restores the binary namespace" 755 "$S5_PREFIX"
    return 143
}
t_run s5_download_engine
assert_ne "an interrupted staging run fails" 0 "$T_STATUS"
assert_mode "the interrupted update leaves the binary namespace at 0755" 755 "$S5_PREFIX"
assert_eq "signal cleanup closes the private-prefix window" 0 "$S5_PREFIX_PRIVATE"

# A fresh install owns the prefix and should keep it private until cleanup has
# removed every partial staging file and the directory itself.
rm -rf "$S5_PREFIX"
S5_CREATED_PREFIX=1
S5_PREFIX_PRIVATE=0
s5_stage_engine() {
    assert_mode "fresh staging remains private" 700 "$S5_PREFIX"
    : >"$S5_PREFIX/.xray.interrupted"
    s5_cleanup
    assert_file_absent "fresh signal cleanup removes the owned prefix" "$S5_PREFIX"
    return 143
}
t_run s5_download_engine
assert_ne "an interrupted fresh staging run fails" 0 "$T_STATUS"
assert_file_absent "the interrupted fresh install leaves no prefix" "$S5_PREFIX"
assert_eq "fresh signal cleanup clears the private-prefix window" 0 "$S5_PREFIX_PRIVATE"

t_summary
