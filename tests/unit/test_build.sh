#!/bin/sh
# tests/unit/test_build.sh - Task 4: pinned-commit fetch, HEAD verification, build.
# No compiler runs here; git and make are stubbed. The real build is CI-only.

S5T_NAME=test_build
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
. "${S5_REPO_ROOT}/tests/lib/stub.sh"

t_mktestroot
t_stub_init

cp "${S5_REPO_ROOT}/tests/stubs/git" "$S5_TEST_ROOT/bin/git"
cp "${S5_REPO_ROOT}/tests/stubs/make" "$S5_TEST_ROOT/bin/make"
chmod 0755 "$S5_TEST_ROOT/bin/git" "$S5_TEST_ROOT/bin/make"

# systemctl is stubbed here purely so that "no systemctl during build" below can
# fail. It is not forbidden in general -- install and uninstall use it -- so it
# is not in t_stub_init's forbidden set; but with no stub in this file the
# transcript could never have contained it and the assertion could never fail.
t_stub systemctl 1

S5_LIB_ONLY=1
S5_SKIP_OWNERSHIP=1
export S5_LIB_ONLY S5_SKIP_OWNERSHIP
# shellcheck source=/dev/null
. "${S5_SRC}"

PINNED=da99424eac4092e3722f1a5b1844cfe80478f580
assert_eq "pinned commit constant" "$PINNED" "$S5_PINNED_COMMIT"
assert_eq "repo URL constant" "https://github.com/3proxy/3proxy" "$S5_REPO_URL"

reset_case() {
    rm -rf "$S5_TEST_ROOT/build" "$S5_PREFIX"
    rm -f "$S5_TEST_ROOT/stub_clone_fail" "$S5_TEST_ROOT/stub_checkout_fail" \
        "$S5_TEST_ROOT/stub_make_fail" "$S5_TEST_ROOT/stub_make_noartifact" \
        "$S5_TEST_ROOT/POSTINSTALL_RAN" "$S5_TEST_ROOT/SERVICEINSTALL_RAN"
    : >"$T_TRANSCRIPT"
    printf '%s\n' "$PINNED" >"$S5_TEST_ROOT/stub_head"
}

count_build_dirs() {
    if [ -d "$S5_TEST_ROOT/build" ]; then
        find "$S5_TEST_ROOT/build" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -c . || true
    else
        printf '0'
    fi
}

# ---------------------------------------------------------------- happy path
reset_case
t_run s5_build_3proxy
assert_eq "successful build returns 0" 0 "$T_STATUS"
assert_file_exists "binary installed" "$S5_BIN"
assert_mode "binary is mode 0755" 755 "$S5_BIN"
assert_mode "new /usr parent remains traversable" 755 "$S5_TEST_ROOT/usr"
assert_mode "new /usr/local parent remains traversable" 755 "$S5_TEST_ROOT/usr/local"
assert_mode "new libexec parent remains traversable" 755 "$S5_TEST_ROOT/usr/local/libexec"
installed=$(find "$S5_PREFIX" -type f | grep -c . || true)
assert_eq "exactly one file installed (only bin/3proxy)" 1 "$installed"
assert_file_absent "no 3proxy_crypt taken" "$S5_PREFIX/3proxy_crypt"
assert_file_absent "no 3proxy_socks taken" "$S5_PREFIX/3proxy_socks"
assert_eq "temporary build tree removed" 0 "$(count_build_dirs)"

t_assert_called "clone was invoked" 'git clone'
t_assert_called "checkout targets the pinned commit" "checkout .*$PINNED"
t_assert_called "HEAD was verified" 'rev-parse HEAD'
t_assert_called "build used Makefile.Linux" 'make -f Makefile.Linux'

# Forbidden upstream installation paths
t_assert_never_called "make install never invoked" 'make .*install'
t_assert_never_called "no postinstall in argv" 'postinstall'
t_assert_never_called "no systemctl during build" 'systemctl'
if [ -x "$S5_BIN" ]; then t_ok; else t_bad "installed binary must be executable"; fi
if [ -L "$S5_BIN" ]; then t_bad "installed binary must not be a symlink"; else t_ok; fi
assert_file_absent "upstream postinstall.sh never executed" "$S5_TEST_ROOT/POSTINSTALL_RAN"
assert_file_absent "upstream service install never executed" "$S5_TEST_ROOT/SERVICEINSTALL_RAN"

# ------------------------------------------------------- HEAD mismatch aborts
reset_case
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' >"$S5_TEST_ROOT/stub_head"
t_run s5_build_3proxy
assert_ne "HEAD mismatch fails" 0 "$T_STATUS"
assert_contains "mismatch names the expected commit" "$PINNED" "$T_OUT"
assert_contains "mismatch is reported as a verification failure" "verification failed" "$T_OUT"
assert_file_absent "nothing installed on mismatch" "$S5_BIN"
assert_eq "build tree removed on mismatch" 0 "$(count_build_dirs)"
t_assert_never_called "no build attempted after mismatch" 'make -f'

# --------------------------------------------------------- empty HEAD aborts
reset_case
: >"$S5_TEST_ROOT/stub_head"
t_run s5_build_3proxy
assert_ne "empty HEAD fails" 0 "$T_STATUS"
assert_file_absent "nothing installed on empty HEAD" "$S5_BIN"
assert_eq "build tree removed on empty HEAD" 0 "$(count_build_dirs)"

# ------------------------------------------------------------ clone failure
reset_case
: >"$S5_TEST_ROOT/stub_clone_fail"
t_run s5_build_3proxy
assert_ne "clone failure fails" 0 "$T_STATUS"
assert_contains "clone failure explained" "clone failed" "$T_OUT"
assert_file_absent "nothing installed on clone failure" "$S5_BIN"
assert_eq "build tree removed on clone failure" 0 "$(count_build_dirs)"

# --------------------------------------------------------- checkout failure
reset_case
: >"$S5_TEST_ROOT/stub_checkout_fail"
t_run s5_build_3proxy
assert_ne "checkout failure fails" 0 "$T_STATUS"
assert_contains "checkout failure explained" "checkout" "$T_OUT"
assert_file_absent "nothing installed on checkout failure" "$S5_BIN"
assert_eq "build tree removed on checkout failure" 0 "$(count_build_dirs)"

# ------------------------------------------------------------ build failure
reset_case
: >"$S5_TEST_ROOT/stub_make_fail"
t_run s5_build_3proxy
assert_ne "build failure fails" 0 "$T_STATUS"
assert_contains "build failure explained" "build failed" "$T_OUT"
assert_file_absent "nothing installed on build failure" "$S5_BIN"
assert_eq "build tree removed on build failure" 0 "$(count_build_dirs)"

# ------------------------------------------- build succeeds but no artifact
reset_case
: >"$S5_TEST_ROOT/stub_make_noartifact"
t_run s5_build_3proxy
assert_ne "missing artifact fails" 0 "$T_STATUS"
assert_contains "missing artifact explained" "bin/3proxy" "$T_OUT"
assert_file_absent "nothing installed when the artifact is missing" "$S5_BIN"
assert_eq "build tree removed when the artifact is missing" 0 "$(count_build_dirs)"

# ------------------------------------------------- build stays in the sandbox
# The previous form of this block could not fail either way. It asserted that
# $S5_TEST_ROOT was a substring of $S5_PREFIX -- a property of how the sandbox
# is constructed, true no matter where the build ran -- and then tested for
# /tmp/socks5-manager-build.probe, a path nothing in this repo ever creates, so
# the `else t_ok` branch fired unconditionally. The build directory is directly
# observable: the git stub's clone destination IS the workdir, and it is in the
# transcript.
count_prod_workdirs() {
    find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'socks5-manager-build.*' 2>/dev/null |
        grep -c . || true
}

reset_case
prod_before=$(count_prod_workdirs)
t_run s5_build_3proxy
assert_eq "build succeeded again" 0 "$T_STATUS"
clonedest=$(t_transcript | grep '^git clone' | tail -n 1 | sed 's/.* //')
assert_ne "the clone destination is recorded" "" "$clonedest"
case "$clonedest" in
"$S5_TEST_ROOT"/build/b.*)
    t_ok
    ;;
*)
    t_bad "the build ran outside the sandbox: $clonedest"
    ;;
esac
assert_eq "the build created nothing under the production template" \
    "$prod_before" "$(count_prod_workdirs)"

# The production branch must use the project-namespaced template under TMPDIR.
# Exercised with TMPDIR redirected into the sandbox, so the real /tmp is never
# written to. TMPDIR is assigned and restored explicitly rather than prefixed
# onto the call: a `VAR=v func` assignment persists in the current shell for a
# function in some shells, so the prefix form would leak into everything after.
mkdir -p "$S5_TEST_ROOT/faketmp"
_savedtmp=${TMPDIR:-}
TMPDIR="$S5_TEST_ROOT/faketmp"
S5_TEST_MODE=0
prodwd=$(s5_make_workdir)
S5_TEST_MODE=1
if [ -n "$_savedtmp" ]; then TMPDIR=$_savedtmp; else unset TMPDIR; fi
case "$prodwd" in
"$S5_TEST_ROOT"/faketmp/socks5-manager-build.*)
    t_ok
    ;;
*)
    t_bad "the production workdir template is wrong: $prodwd"
    ;;
esac
assert_dir_exists "and the production workdir is actually created" "$prodwd"
rm -rf "$S5_TEST_ROOT/faketmp"

t_summary
