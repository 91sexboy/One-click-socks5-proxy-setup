#!/bin/sh

S5T_NAME=test_xray_lifecycle_assert
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
t_mktestroot
SHELL_UNDER_TEST=${S5_TEST_SHELL:-sh}
fixture=$S5_TEST_ROOT/fixture
mkdir -p "$fixture/etc/xray-socks5" "$fixture/var/lib/xray-socks5"
config=$fixture/etc/xray-socks5/config.json
state=$fixture/var/lib/xray-socks5/state
transaction=$fixture/var/lib/xray-socks5/transaction
assertion=$S5_TEST_ROOT/assert.sh
owner=$(stat -c '%U:%G' "$fixture")
# Paths and the expected host identity are adapted only in this disposable copy;
# the CI module has no environment override for either its root or its policy.
sed -e "s#=/etc/#=$fixture/etc/#g" -e "s#=/var/#=$fixture/var/#g" \
    -e "s/root:xray-socks5 640/$owner 640/" \
    "$S5_REPO_ROOT/.github/scripts/lifecycle-update-assert.sh" >"$assertion"
cat >"$S5_TEST_ROOT/healthy.json" <<'JSON'
{"inbounds":[{"settings":{"accounts":[{"user":"ciuser2","pass":"synthetic"}]}}]}
JSON
cp "$S5_TEST_ROOT/healthy.json" "$config"
printf 'username\tciuser2\n' >"$state"
chmod 0640 "$config"
chmod 0600 "$state"

run_assertion() {
    # A function also overrides BusyBox's preferred id applet. File, JSON, grep
    # and stat observations still execute against the real fixture.
    # shellcheck disable=SC2086
    $SHELL_UNDER_TEST -c 'fixture_uid=$2; id() { printf "%s\n" "$fixture_uid"; }; . "$1"' \
        fixture "$assertion" "${fixture_uid:-0}"
}
expect_refusal() {
    t_run run_assertion
    assert_ne "$1 fails" 0 "$T_STATUS"
    assert_contains "$1 identifies the failed guarantee" "$2" "$T_OUT"
}

t_run run_assertion
assert_eq "healthy fixture passes real post-update assertions" 0 "$T_STATUS"
assert_contains "healthy assertion is actually reached" 'lifecycle-update-assert: reached' "$T_OUT"

sed 's/"user":"ciuser2"/"user":"wrong","note":{"user":"ciuser2"}/' \
    "$S5_TEST_ROOT/healthy.json" >"$config"
expect_refusal "identity in an unrelated field" 'updated config has the wrong identity'
printf '{invalid-json\n' >"$config"
expect_refusal "malformed config" 'updated config has the wrong identity'
cp "$S5_TEST_ROOT/healthy.json" "$config"
printf 'username\twrong\n' >"$state"
expect_refusal "wrong state identity" 'updated state has the wrong identity'
printf 'username\tciuser2\n' >"$state"
chmod 0600 "$config"
expect_refusal "wrong config mode" 'updated config ownership or mode is wrong'
chmod 0640 "$config"
# Non-root tests cannot chown a fixture to root; vary the expected identity in
# another disposable copy while retaining the real stat result.
sed "s/$owner 640/unmatched-owner:unmatched-group 640/" "$assertion" >"$S5_TEST_ROOT/wrong-owner.sh"
original_assertion=$assertion
assertion=$S5_TEST_ROOT/wrong-owner.sh
expect_refusal "owner mismatch" 'updated config ownership or mode is wrong'
assertion=$original_assertion
mkdir "$transaction"
expect_refusal "transaction directory residue" 'update transaction evidence remains'
rmdir "$transaction"
ln -s missing-transaction "$transaction"
expect_refusal "dangling transaction symlink" 'update transaction evidence remains'
rm "$transaction"
mv "$config" "$config.real"
ln -s config.json.real "$config"
expect_refusal "config symlink" 'updated config is not a regular file'
rm "$config"
mv "$config.real" "$config"
fixture_uid=1000
expect_refusal "non-root observation" 'lifecycle update assertions require root'
assert_not_contains "non-root refusal occurs before any observation" 'lifecycle-update-assert: reached' "$T_OUT"
fixture_uid=0

t_run run_assertion
assert_eq "restored healthy fixture passes after all mutations" 0 "$T_STATUS"

# Reproduce the original false absence without touching a system path.
if [ "$(id -u)" -ne 0 ]; then
    private=$S5_TEST_ROOT/inaccessible
    mkdir -p "$private/transaction"
    chmod 000 "$private"
    t_run test ! -e "$private/transaction"
    chmod 0700 "$private"
    assert_eq "unprivileged absence test falsely succeeds through inaccessible parent" 0 "$T_STATUS"
    assert_dir_exists "restoring traversal reveals the transaction" "$private/transaction"
else
    t_skip "permission-denied absence reproduction" "requires an unprivileged test process"
fi

t_run python3 "$S5_REPO_ROOT/tests/lib/lifecycle_control_regression.py" "$S5_REPO_ROOT"
assert_eq "native-control driver has nonprivileged regression coverage" 0 "$T_STATUS"
if [ "$T_STATUS" -ne 0 ]; then printf '%s\n' "$T_OUT" >&2; fi
assert_contains "control regression completes without running native services" \
    'checks passed (no native lifecycle run)' "$T_OUT"
t_summary
