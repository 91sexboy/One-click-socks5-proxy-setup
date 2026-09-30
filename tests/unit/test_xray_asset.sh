#!/bin/sh
# Raw Xray release metadata, direct staging, verification and cleanup.

S5T_NAME=test_xray_asset
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
. "${S5_REPO_ROOT}/tests/lib/xray-fixture.sh"
ROOT=${S5_REPO_ROOT}
t_mktestroot
t_source_production ''
S5_LANG=en

assert_eq "Xray release is stable v26.3.27" v26.3.27 "$S5_XRAY_VERSION"
assert_eq "Xray release commit is pinned" \
    d2758a023cd7f4174a5a5fa4ff66e487d4342ba0 "$S5_XRAY_COMMIT"
assert_eq "raw distribution tag is revisioned" xray-v26.3.27-r1 \
    "$S5_XRAY_DISTRIBUTION_TAG"

S5_ARCHNAME=amd64
# This exercises production before the later quota fixture selector.
# shellcheck disable=SC2218
s5_asset_select
assert_eq "amd64 raw asset name" xray-v26.3.27-linux-amd64 "$S5_ASSET_NAME"
assert_eq "amd64 raw size" 36577406 "$S5_ASSET_SIZE"
assert_eq "amd64 raw digest" \
    8255dd939c34cf966cc91517b6324dd3c8d0bcf49ffac8beca049a38c46845ed \
    "$S5_ASSET_SHA256"
assert_eq "amd64 downloaded and installed sizes are identical" \
    "$S5_ASSET_SIZE" "$S5_ASSET_BINARY_SIZE"
assert_eq "amd64 downloaded and installed digests are identical" \
    "$S5_ASSET_SHA256" "$S5_ASSET_BINARY_SHA256"

S5_ARCHNAME=arm64
# shellcheck disable=SC2218
s5_asset_select
assert_eq "arm64 raw asset name" xray-v26.3.27-linux-arm64 "$S5_ASSET_NAME"
assert_eq "arm64 raw size" 34209918 "$S5_ASSET_SIZE"
assert_eq "arm64 raw digest" \
    c2d20a7045250497083afea0d79db0672f6c89a25aaaf37c92de034d6b764b04 \
    "$S5_ASSET_SHA256"
assert_eq "arm64 downloaded and installed sizes are identical" \
    "$S5_ASSET_SIZE" "$S5_ASSET_BINARY_SIZE"
assert_eq "arm64 downloaded and installed digests are identical" \
    "$S5_ASSET_SHA256" "$S5_ASSET_BINARY_SHA256"

S5_ARCHNAME=riscv64
t_run s5_asset_select
assert_ne "unsupported architecture has no raw asset" 0 "$T_STATUS"

source=$(cat "$ROOT/socks5.sh")
assert_not_contains "asset URL is not latest" '/releases/latest' "$source"
assert_not_contains "asset URL has no upstream fallback" 'XTLS/Xray-core/releases/download' "$source"
assert_contains "asset download is HTTPS-only" "--proto '=https'" "$source"
assert_contains "asset download is bounded" '--max-filesize' "$source"
assert_not_contains "target installer no longer invokes unzip" '/usr/bin/unzip' "$source"
assert_not_contains "target installer no longer creates extraction FIFOs" 'mkfifo' "$source"
assert_contains "candidate is created beside the final binary" \
    'mktemp "$S5_PREFIX/.xray.XXXXXX"' "$source"

# A runnable shell fixture cannot satisfy production file(1)'s ELF gate, so the
# seam reports the architecture while every byte, digest, mode and rename check
# remains production code.
t_raw_fixture() {
    t_xray_fixture 23456 real-download
    S5_TEST_ASSET_PATH=$S5_TEST_ROOT/asset-xray
    export S5_TEST_ASSET_PATH
    s5_file_type_command() {
        printf '%s\n' 'ELF 64-bit LSB executable, x86-64, statically linked'
    }
}

# t_run captures output in a command-substitution subshell, which drops the
# candidate registration cleanup relies on. Staging failures run here instead,
# in the test's own shell, exactly as the command would run them.
t_run_here() {
    "$@" >"$S5_TEST_ROOT/run-here.out" 2>&1 && T_STATUS=0 || T_STATUS=$?
    T_OUT=$(cat "$S5_TEST_ROOT/run-here.out")
}

t_candidate_count() {
    find "$S5_PREFIX" -maxdepth 1 -type f -name '.xray.*' 2>/dev/null |
        wc -l | tr -d '[:space:]'
}

t_raw_fixture
t_run_here s5_download_engine
assert_eq "valid raw candidate installs" 0 "$T_STATUS"
assert_file_exists "raw publication creates final xray" "$S5_BIN"
assert_mode "published xray is executable" 755 "$S5_BIN"
assert_eq "published xray matches the raw candidate" \
    "$S5T_BIN_SHA256" "$(t_sha256 "$S5_BIN")"
assert_eq "successful publication leaves no prefix candidate" 0 "$(t_candidate_count)"
assert_eq "successful publication clears the tracked candidate" '' "$S5_BINARY_TEMP"

# Exact-size and digest gates remove every refused candidate.
t_raw_fixture
S5T_SIZE_OVERRIDE=$((S5T_BIN_SIZE + 1))
t_run_here s5_download_engine
assert_ne "short raw asset is refused" 0 "$T_STATUS"
assert_contains "short raw asset reports observed and expected bytes" \
    "is $S5T_BIN_SIZE bytes, expected $((S5T_BIN_SIZE + 1))" "$T_OUT"
assert_file_absent "short raw asset is never published" "$S5_BIN"
assert_eq "short raw candidate is removed" 0 "$(t_candidate_count)"

# Correct size but wrong digest is independent of the size gate.
t_raw_fixture
S5T_SHA_OVERRIDE=1111111111111111111111111111111111111111111111111111111111111111
t_run_here s5_download_engine
assert_ne "wrong raw digest is refused" 0 "$T_STATUS"
assert_contains "wrong raw digest reports SHA-256" 'sha256' "$T_OUT"
assert_file_absent "wrong-digest asset is never published" "$S5_BIN"
assert_eq "wrong-digest candidate is removed" 0 "$(t_candidate_count)"

# Architecture, linkage and version are checked only after byte identity.
t_raw_fixture
s5_file_type_command() {
    printf '%s\n' 'ELF 64-bit LSB executable, ARM aarch64, statically linked'
}
t_run_here s5_download_engine
assert_ne "wrong ELF architecture is refused" 0 "$T_STATUS"
assert_contains "wrong ELF architecture reports architecture" 'architecture' "$T_OUT"
s5_cleanup
assert_eq "wrong-architecture candidate is removed" 0 "$(t_candidate_count)"

t_raw_fixture
s5_file_type_command() {
    printf '%s\n' 'ELF 64-bit LSB executable, x86-64, dynamically linked, interpreter /lib64/ld-linux.so.2'
}
t_run_here s5_download_engine
assert_ne "dynamically linked candidate is refused" 0 "$T_STATUS"
assert_contains "dynamic candidate reports linkage" 'linkage' "$T_OUT"
s5_cleanup
assert_eq "dynamic candidate is removed" 0 "$(t_candidate_count)"

t_raw_fixture
s5_xray_version_command() { printf '%s\n' 'Xray 99.0.0 (synthetic)'; }
t_run_here s5_download_engine
assert_ne "wrong Xray version is refused" 0 "$T_STATUS"
assert_contains "wrong Xray version reports version" 'version' "$T_OUT"
s5_cleanup
assert_eq "wrong-version candidate is removed" 0 "$(t_candidate_count)"

# A staging step that cannot run is named, not left as a bare nonzero status:
# file(1) failing, a refused chmod, a candidate the kernel will not execute
# (noexec /usr/local), and a digest tool that cannot run at all.
for _stage_fault in filetype permission exec digest; do
    t_raw_fixture
    case "$_stage_fault" in
    filetype) s5_file_type_command() { return 1; } ;;
    permission)
        chmod() {
            case "$1:$2" in 0700:"$S5_PREFIX"/.xray.*) return 1 ;; esac
            command chmod "$@"
        }
        ;;
    exec) s5_xray_version_command() { return 126; } ;;
    digest) s5_sha256_command() { return 1; } ;;
    esac
    t_run_here s5_download_engine
    unset -f chmod
    assert_ne "$_stage_fault staging failure is refused" 0 "$T_STATUS"
    case "$_stage_fault" in
    digest)
        assert_contains "a digest tool failure names the tool, not the bytes" \
            '[x] could not compute SHA-256 for downloaded asset: xray-v26.3.27-linux-amd64.' "$T_OUT"
        assert_not_contains "a digest tool failure is not a SHA mismatch" \
            'verification failed: sha256' "$T_OUT"
        ;;
    *)
        assert_contains "$_stage_fault staging failure names its reason" \
            "[x] Xray asset verification failed: $_stage_fault." "$T_OUT"
        ;;
    esac
    assert_file_absent "$_stage_fault candidate is never published" "$S5_BIN"
    s5_cleanup
    assert_eq "$_stage_fault candidate is removed" 0 "$(t_candidate_count)"
done

# The download seam classifies curl's direct write status without parsing stderr.
t_raw_fixture
S5_TEST_ASSET_PATH=''
unset S5_TEST_ASSET_PATH
s5_curl_command() {
    _tca_out=''
    while [ "$#" -gt 0 ]; do
        if [ "$1" = -o ]; then shift; _tca_out=$1; fi
        shift
    done
    head -c 64 "$S5_TEST_ROOT/asset-xray" >"$_tca_out"
    return 23
}
t_run_here s5_download_engine
assert_ne "curl output write failure is refused" 0 "$T_STATUS"
assert_contains "curl write failure reports observed and expected bytes" \
    "64 bytes written of $S5T_BIN_SIZE" "$T_OUT"
assert_contains "curl write failure is classified as storage" 'full or over quota' "$T_OUT"
assert_eq "curl write failure removes candidate" 0 "$(t_candidate_count)"

t_raw_fixture
S5_TEST_ASSET_PATH=''
unset S5_TEST_ASSET_PATH
s5_curl_command() { return 28; }
t_run_here s5_download_engine
assert_ne "curl transport failure is refused" 0 "$T_STATUS"
assert_contains "transport failure retains the download reason" \
    'Xray asset verification failed: download.' "$T_OUT"
assert_not_contains "transport failure is not reported as storage" 'full or over quota' "$T_OUT"
assert_eq "transport failure removes candidate" 0 "$(t_candidate_count)"

# A successful short transfer is artifact identity failure, not storage evidence.
t_raw_fixture
S5_TEST_ASSET_PATH=''
unset S5_TEST_ASSET_PATH
s5_curl_command() {
    _tcs_out=''
    while [ "$#" -gt 0 ]; do
        if [ "$1" = -o ]; then shift; _tcs_out=$1; fi
        shift
    done
    head -c 64 "$S5_TEST_ROOT/asset-xray" >"$_tcs_out"
    return 0
}
t_run_here s5_download_engine
assert_ne "successful short response is refused" 0 "$T_STATUS"
assert_contains "successful short response is a size failure" 'expected' "$T_OUT"
assert_not_contains "successful short response is not storage" 'full or over quota' "$T_OUT"
assert_eq "successful short response removes candidate" 0 "$(t_candidate_count)"

# Candidate is private during verification and is the same inode renamed into
# place; no extracted or publication copy is introduced.
t_raw_fixture
_s5t_inode_file=$S5_TEST_ROOT/candidate.inode
_s5t_mode_file=$S5_TEST_ROOT/candidate.mode
s5_xray_version_command() {
    stat -c '%i' "$1" >"$_s5t_inode_file"
    stat -c '%a' "$1" >"$_s5t_mode_file"
    printf '%s\n' 'Xray 26.3.27 (synthetic test fixture)'
}
_s5t_runlog=$S5_TEST_ROOT/inode-run.log
s5_download_engine >"$_s5t_runlog" 2>&1
_s5t_status=$?
assert_eq "inode-observation install succeeds" 0 "$_s5t_status"
assert_eq "candidate has private execute mode during version check" 700     "$(cat "$_s5t_mode_file")"
assert_eq "published binary is the verified candidate inode"     "$(cat "$_s5t_inode_file")" "$(stat -c '%i' "$S5_BIN")"

# Fresh capacity is exactly one raw binary. The seam records the request rather
# than depending on this host's current free-space count.
t_raw_fixture
_s5t_space_path=''
_s5t_space_bytes=''
s5_require_space() { _s5t_space_path=$1; _s5t_space_bytes=$2; return 0; }
_s5t_runlog=$S5_TEST_ROOT/capacity-run.log
s5_download_engine >"$_s5t_runlog" 2>&1
_s5t_status=$?
assert_eq "capacity-observation install succeeds" 0 "$_s5t_status"
assert_eq "fresh capacity is checked on the install prefix" "$S5_PREFIX" "$_s5t_space_path"
assert_eq "fresh capacity requires one raw binary" "$S5T_BIN_SIZE" "$_s5t_space_bytes"

# Prefix mode and partial candidate cleanup are both attempted on an existing
# installation even when staging fails.
t_raw_fixture
mkdir -p "$S5_PREFIX"
chmod 0755 "$S5_PREFIX"
printf 'existing\n' >"$S5_BIN"
chmod 0755 "$S5_BIN"
S5_CREATED_PREFIX=0
s5_fetch_binary() { printf 'partial\n' >"$1"; return 1; }
t_run_here s5_download_engine
assert_ne "failed update staging is refused" 0 "$T_STATUS"
assert_mode "failed update restores prefix traversal" 755 "$S5_PREFIX"
assert_eq "failed update removes prefix candidate" 0 "$(t_candidate_count)"
assert_contains "failed update preserves the installed binary" 'existing' "$(cat "$S5_BIN")"

# Unified signal/EXIT cleanup tracks the same candidate path without a FIFO or
# external work directory.
t_raw_fixture
mkdir -p "$S5_PREFIX"
chmod 0700 "$S5_PREFIX"
S5_CREATED_PREFIX=0
S5_PREFIX_PRIVATE=1
S5_BINARY_TEMP=$(mktemp "$S5_PREFIX/.xray.XXXXXX")
printf 'partial\n' >"$S5_BINARY_TEMP"
t_run s5_cleanup
assert_eq "cleanup removes tracked prefix candidate" 0 "$(t_candidate_count)"
assert_mode "cleanup restores existing prefix traversal" 755 "$S5_PREFIX"

# Pin a stat snapshot at the syscall boundary, not the production seam. This
# both avoids the live filesystem read race and proves that changing %f to %a
# loses the root reserve, including on hosts that have no reserve themselves.
t_raw_fixture
_tfs_snapshot() (
    stat() {
        case "$*" in
        "-f -c %f %S $S5_TEST_ROOT") printf '100 4096\n' ;;
        "-f -c %a %S $S5_TEST_ROOT") printf '90 4096\n' ;;
        *) return 1 ;;
        esac
    }
    s5_free_kb "$S5_TEST_ROOT"
)
t_run _tfs_snapshot
assert_eq "production capacity seam reads the stat snapshot" 0 "$T_STATUS"
assert_eq "capacity includes the ten root-reserved blocks" 400 "$T_OUT"
assert_ne "capacity does not substitute unprivileged availability" 360 "$T_OUT"
t_run s5_fs_free_command "$S5_TEST_ROOT"
assert_eq "packaged stat can read real filesystem capacity" 0 "$T_STATUS"
for _tfs_block in 512 1024 4096 65536; do
    s5_fs_free_command() { printf '100 %s\n' "$_tfs_block"; }
    t_run s5_free_kb "$S5_TEST_ROOT"
    assert_eq "capacity converts $_tfs_block byte blocks" "$((100 * _tfs_block / 1024))" "$T_OUT"
done

mkdir -p "$S5_TEST_ROOT/fsid"
assert_eq "filesystem identity is the device" \
    "$(stat -c '%d' "$S5_TEST_ROOT")" "$(s5_fs_id "$S5_TEST_ROOT")"
_asset_fsid=$(s5_fs_id "$S5_TEST_ROOT")
head -c 8388608 /dev/zero >"$S5_TEST_ROOT/fsid/churn" 2>/dev/null
assert_eq "filesystem identity survives free-space churn" \
    "$_asset_fsid" "$(s5_fs_id "$S5_TEST_ROOT/fsid")"
# This command intentionally precedes the later removal-failure double.
# shellcheck disable=SC2218
command rm -f "$S5_TEST_ROOT/fsid/churn"


# Update publication must never acquire fresh-install ownership, including the
# signal window inside rename. Otherwise cleanup removes the live binary before
# rollback verifies it and the old installation becomes unrecoverable.
t_raw_fixture
mkdir -p "$S5_PREFIX"
printf 'old binary\n' >"$S5_BIN"
chmod 0755 "$S5_PREFIX" "$S5_BIN"
S5_BINARY_REPLACED=1
mv() {
    printf '%s\n' "$S5_CREATED_BIN" >"$S5_TEST_ROOT/rename-owner"
    command mv "$@"
}
t_run_here s5_download_engine
assert_eq "update raw publication succeeds" 0 "$T_STATUS"
assert_eq "update rename never marks the binary as fresh" 0 "$(cat "$S5_TEST_ROOT/rename-owner")"
unset -f mv

# A failed removal keeps the tracked path so a later cleanup can retry it.
t_raw_fixture
mkdir -p "$S5_PREFIX"
S5_BINARY_TEMP=$(mktemp "$S5_PREFIX/.xray.XXXXXX")
_s5t_failed_temp=$S5_BINARY_TEMP
rm() { return 1; }
s5_cleanup_binary_temp >"$S5_TEST_ROOT/remove.log" 2>&1
assert_ne "candidate removal failure is observable" 0 "$?"
assert_eq "failed removal retains candidate identity" "$_s5t_failed_temp" "$S5_BINARY_TEMP"
unset -f rm
s5_cleanup_binary_temp
assert_file_absent "later cleanup retries the retained candidate" "$_s5t_failed_temp"
assert_eq "successful retry clears candidate identity" '' "$S5_BINARY_TEMP"

# Combined preflight must happen before making a rollback copy. On independent
# filesystems each requirement belongs to its own path; unknown ids fall back to
# the separate checks rather than disabling the check entirely.
for _s5t_devices in shared split unknown; do
    t_raw_fixture
    mkdir -p "$S5_TXNDIR" "$S5_PREFIX"
    s5_fs_id_command() {
        case "$_s5t_devices:$1" in
        unknown:*) return 1 ;;
        split:"$S5_TXNDIR") printf '2\n' ;;
        *) printf '1\n' ;;
        esac
    }
    s5_require_space() { printf '%s %s\n' "$1" "$2" >>"$S5_TEST_ROOT/space.calls"; }
    t_run s5_require_update_space 123
    assert_eq "$_s5t_devices update preflight succeeds" 0 "$T_STATUS"
    if [ "$_s5t_devices" = shared ]; then
        _s5t_expected="$S5_TXNDIR $((123 + S5_ASSET_SIZE))"
    else
        _s5t_expected="$S5_TXNDIR 123
$S5_PREFIX $S5_ASSET_SIZE"
    fi
    assert_eq "$_s5t_devices preflight accounts for backup and raw candidate" \
        "$_s5t_expected" "$(cat "$S5_TEST_ROOT/space.calls" 2>/dev/null)"
done

# A successful oversized response is refused before any version execution.
t_raw_fixture
S5T_SIZE_OVERRIDE=$((S5T_BIN_SIZE - 1))
t_run_here s5_download_engine
assert_ne "oversized raw fixture is refused" 0 "$T_STATUS"
assert_file_absent "oversized candidate never publishes" "$S5_BIN"
assert_eq "oversized candidate is removed" 0 "$(t_candidate_count)"

# Verification failures must not execute the downloaded bytes.
t_raw_fixture
s5_xray_version_command() { : >"$S5_TEST_ROOT/version-called"; return 0; }
S5T_SHA_OVERRIDE=1111111111111111111111111111111111111111111111111111111111111111
t_run_here s5_download_engine
assert_ne "unverified candidate is refused" 0 "$T_STATUS"
assert_file_absent "digest failure never runs version" "$S5_TEST_ROOT/version-called"

# The exact quota failure that motivated this change stays a storage error even
# when statfs reports ample space. Inject curl's documented write-error status.
t_raw_fixture
unset S5_TEST_ASSET_PATH
s5_asset_select() {
    S5_ASSET_SIZE=36577406
    S5_ASSET_NAME=xray-v26.3.27-linux-amd64
    S5_ASSET_SHA256=8255dd939c34cf966cc91517b6324dd3c8d0bcf49ffac8beca049a38c46845ed
}
s5_fs_free_command() { printf '999999 4096\n'; }
s5_curl_command() {
    while [ "$1" != -o ]; do shift; done
    shift
    head -c 7798784 /dev/zero >"$1"
    return 23
}
t_run_here s5_download_engine
assert_ne "quota-blind raw short write refuses installation" 0 "$T_STATUS"
assert_contains "quota-blind diagnosis retains exact byte counts" \
    '7798784 bytes written of 36577406' "$T_OUT"
assert_contains "quota-blind diagnosis is storage" 'full or over quota' "$T_OUT"
assert_not_contains "quota-blind failure is not artifact corruption" 'asset verification failed' "$T_OUT"
assert_eq "quota-blind failure removes candidate" 0 "$(t_candidate_count)"

# Observe a real handled signal inside download, not a direct cleanup call.
for _tsignal in HUP INT TERM; do
    t_raw_fixture
    mkdir -p "$S5_PREFIX"
    chmod 0755 "$S5_PREFIX"
    printf 'old binary\n' >"$S5_BIN"
    chmod 0755 "$S5_BIN"
    (
        trap 's5_on_signal 129' HUP
        trap 's5_on_signal 130' INT
        trap 's5_on_signal 143' TERM
        s5_fetch_binary() {
            printf 'partial\n' >"$1"
            printf '%s\n' "$1" >"$S5_TEST_ROOT/signal-candidate"
            python3 - "$_tsignal" <<'PY'
import os, signal, sys
os.kill(os.getppid(), getattr(signal, 'SIG' + sys.argv[1]))
PY
            return 1
        }
        s5_download_engine
    ) >"$S5_TEST_ROOT/signal.log" 2>&1
    _tsignal_status=$?
    case "$_tsignal" in HUP) _texpected=129 ;; INT) _texpected=130 ;; TERM) _texpected=143 ;; esac
    assert_eq "$_tsignal returns its signal status" "$_texpected" "$_tsignal_status"
    assert_file_absent "$_tsignal removes partial raw bytes" "$(cat "$S5_TEST_ROOT/signal-candidate")"
    assert_mode "$_tsignal restores existing prefix" 755 "$S5_PREFIX"
    assert_eq "$_tsignal preserves old executable" 'old binary' "$(cat "$S5_BIN")"
done

# Absolute tool seams and MAGIC isolation still hold after removing unzip.
t_raw_fixture
s5_sha256_command() { /usr/bin/sha256sum "$1"; }
mkdir "$S5_TEST_ROOT/hostile-bin"
for _hostile in curl sha256sum file; do
    printf '#!/bin/sh\nprintf called >>"$S5_TEST_ROOT/hostile.calls"\nexit 99\n' \
        >"$S5_TEST_ROOT/hostile-bin/$_hostile"
    chmod 0755 "$S5_TEST_ROOT/hostile-bin/$_hostile"
done
PATH="$S5_TEST_ROOT/hostile-bin:$PATH"
t_run "$S5_TEST_ROOT/hostile-bin/curl"
assert_eq "hostile PATH tool positive control fails" 99 "$T_STATUS"
command rm -f "$S5_TEST_ROOT/hostile.calls"
curl() { : >"$S5_TEST_ROOT/hostile.calls"; return 99; }
sha256sum() { : >"$S5_TEST_ROOT/hostile.calls"; return 99; }
file() { : >"$S5_TEST_ROOT/hostile.calls"; return 99; }
t_run s5_curl_command --version
assert_eq "curl seam bypasses PATH and functions" 0 "$T_STATUS"
t_run s5_sha256 "$S5_TEST_ROOT/asset-xray"
assert_eq "digest seam bypasses PATH and functions" "$S5T_BIN_SHA256" "$T_OUT"
s5_file_type_command() { /usr/bin/file -b "$@"; }
MAGIC=$S5_TEST_ROOT/missing-magic
export MAGIC
t_run s5_file_type "$S5_TEST_ROOT/asset-xray"
assert_eq "file seam ignores hostile MAGIC" 0 "$T_STATUS"
assert_contains "file classification uses packaged magic" 'script' "$T_OUT"
assert_file_absent "verification never invokes hostile tool" "$S5_TEST_ROOT/hostile.calls"
assert_eq "file seam leaves caller MAGIC intact" "$S5_TEST_ROOT/missing-magic" "$MAGIC"
unset MAGIC
unset -f curl sha256sum file

t_summary
