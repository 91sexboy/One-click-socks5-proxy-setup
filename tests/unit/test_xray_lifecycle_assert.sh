#!/bin/sh
# Rooted post-update ownership, configuration and transaction assertions.

S5T_NAME=test_xray_lifecycle_assert
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
t_mktestroot
SHELL_UNDER_TEST=${S5_TEST_SHELL:-sh}
fixture=$S5_TEST_ROOT/fixture
prefix=$fixture/usr/local/libexec/xray-socks5
mkdir -p "$fixture/etc/xray-socks5" "$fixture/var/lib/xray-socks5" "$prefix"
config=$fixture/etc/xray-socks5/config.json
state=$fixture/var/lib/xray-socks5/state
transaction=$fixture/var/lib/xray-socks5/transaction
assertion=$S5_REPO_ROOT/.github/scripts/lifecycle-update-assert.sh
fixture_owner=root:xray-socks5
prefix_owner=root:root
cat >"$S5_TEST_ROOT/healthy.json" <<'JSON'
{"inbounds":[{"settings":{"accounts":[{"user":"ciuser2","pass":"synthetic"}]}}]}
JSON
cp "$S5_TEST_ROOT/healthy.json" "$config"
printf 'username\tciuser2\n' >"$state"
chmod 0640 "$config"
chmod 0600 "$state"
chmod 0755 "$prefix"

s5t_run_assertion() {
    # Only host identities are substituted; modes and content stay real.
    # Split a configured multiword shell such as busybox sh.
    # shellcheck disable=SC2086
    $SHELL_UNDER_TEST -c '
        assertion=$1; fixture_uid=$2; fixture_owner=$3; prefix_owner=$4; fixture_root=$5
        id() { printf "%s\n" "$fixture_uid"; }
        stat() {
            if [ "$1" = -c ] && [ "$2" = "%U:%G %a" ]; then
                case "$3" in
                "$fixture_root/usr/local/libexec/xray-socks5") _s5t_owner=$prefix_owner ;;
                *) _s5t_owner=$fixture_owner ;;
                esac
                printf "%s %s\n" "$_s5t_owner" "$(command stat -c %a "$3")"
            else
                command stat "$@"
            fi
        }
        set -- "$fixture_root"
        . "$assertion"
    ' fixture "$assertion" "${fixture_uid:-0}" "$fixture_owner" "$prefix_owner" "$fixture"
}
s5t_expect_refusal() {
    t_run s5t_run_assertion
    assert_ne "$1 fails" 0 "$T_STATUS"
    assert_contains "$1 identifies the failed guarantee" "$2" "$T_OUT"
}

t_run s5t_run_assertion
assert_eq "healthy fixture passes real post-update assertions" 0 "$T_STATUS"
assert_contains "healthy assertion is actually reached" 'lifecycle-update-assert: reached' "$T_OUT"

sed 's/"user":"ciuser2"/"user":"wrong","note":{"user":"ciuser2"}/' \
    "$S5_TEST_ROOT/healthy.json" >"$config"
s5t_expect_refusal "identity in an unrelated field" 'updated config has the wrong identity'
printf '{invalid-json\n' >"$config"
s5t_expect_refusal "malformed config" 'updated config has the wrong identity'
cp "$S5_TEST_ROOT/healthy.json" "$config"
printf 'username\twrong\n' >"$state"
s5t_expect_refusal "wrong state identity" 'updated state has the wrong identity'
printf 'username\tciuser2\n' >"$state"
chmod 0600 "$config"
s5t_expect_refusal "wrong config mode" 'updated config ownership or mode is wrong'
chmod 0640 "$config"
fixture_owner=unmatched-owner:unmatched-group
s5t_expect_refusal "owner mismatch" 'updated config ownership or mode is wrong'
fixture_owner=root:xray-socks5
chmod 0700 "$prefix"
s5t_expect_refusal "wrong install directory mode"     'updated install directory ownership or mode is wrong'
chmod 0755 "$prefix"
prefix_owner=unmatched-owner:unmatched-group
s5t_expect_refusal "install directory owner mismatch"     'updated install directory ownership or mode is wrong'
prefix_owner=root:root
rmdir "$prefix"
printf 'not a directory
' >"$prefix"
s5t_expect_refusal "install path is not a directory"     'updated install directory is not a directory'
rm "$prefix"
mkdir "$prefix"
chmod 0755 "$prefix"
mkdir "$transaction"
s5t_expect_refusal "transaction directory residue" 'update transaction evidence remains'
rmdir "$transaction"
ln -s missing-transaction "$transaction"
s5t_expect_refusal "dangling transaction symlink" 'update transaction evidence remains'
rm "$transaction"
mv "$config" "$config.real"
ln -s config.json.real "$config"
s5t_expect_refusal "config symlink" 'updated config is not a regular file'
rm "$config"
mv "$config.real" "$config"
fixture_uid=1000
s5t_expect_refusal "non-root observation" 'lifecycle update assertions require root'
assert_not_contains "non-root refusal occurs before any observation" 'lifecycle-update-assert: reached' "$T_OUT"
fixture_uid=0

t_run s5t_run_assertion
assert_eq "restored healthy fixture passes after all mutations" 0 "$T_STATUS"

t_run python3 "$S5_REPO_ROOT/tests/lib/lifecycle_control_regression.py" "$S5_REPO_ROOT"
assert_eq "native-control driver has nonprivileged regression coverage" 0 "$T_STATUS"
if [ "$T_STATUS" -ne 0 ]; then printf '%s\n' "$T_OUT" >&2; fi
assert_contains "control regression completes without running native services" \
    'checks passed (no native lifecycle run)' "$T_OUT"
# The shared lifecycle log contract names every management command and both
# credential generations where they could coexist. Removing any log pair must
# make the assertion fail rather than silently reducing coverage.
# shellcheck source=/dev/null
. "$S5_REPO_ROOT/.github/scripts/lifecycle-common.sh"
_lacwork=$S5_TEST_ROOT/log-contract
mkdir -p "$_lacwork"
printf 'olduser\nOld_secret~1\n' >"$_lacwork/pass"
printf 'newuser\nNew_secret~2\n' >"$_lacwork/pass.update"
for _laclog in install update status restart uninstall uninstall-second reinstall uninstall-reinstall; do
    : >"$_lacwork/$_laclog.log"
done
t_run lifecycle_assert_logs_redacted "$_lacwork"
assert_eq "complete lifecycle log contract passes" 0 "$T_STATUS"
printf 'Old_secret~1\n' >"$_lacwork/restart.log"
t_run lifecycle_assert_logs_redacted "$_lacwork"
assert_ne "restart log is checked against the old credential" 0 "$T_STATUS"
: >"$_lacwork/restart.log"
printf 'New_secret~2\n' >"$_lacwork/uninstall.log"
t_run lifecycle_assert_logs_redacted "$_lacwork"
assert_ne "uninstall log is checked against the rotated credential" 0 "$T_STATUS"
_lac_pair='newuser:New_secret~2'
_lac_encoded=$(printf '%s' "$_lac_pair" | base64 | tr -d '\n')
printf '%s\n' "$_lac_pair" >"$_lacwork/uninstall.log"
t_run lifecycle_assert_logs_redacted "$_lacwork"
assert_ne "uninstall log is checked against the credential pair" 0 "$T_STATUS"
printf '%s\n' "$_lac_encoded" >"$_lacwork/uninstall.log"
t_run lifecycle_assert_logs_redacted "$_lacwork"
assert_ne "uninstall log is checked against the encoded credential pair" 0 "$T_STATUS"

t_summary
