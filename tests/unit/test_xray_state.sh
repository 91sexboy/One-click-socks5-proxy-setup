#!/bin/sh
# State compatibility and fail-closed integrity, through the real load boundary.
S5T_NAME=test_xray_state
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
. "${S5_REPO_ROOT}/tests/lib/xray-fixture.sh"
t_xray_fixture 23456
t_xray_install
cp "$S5_STATE" "$S5_TEST_ROOT/valid-state"

# Every case starts with the same valid disk state and detected host backend.
t_state_reset() {
    cp "$S5_TEST_ROOT/valid-state" "$S5_STATE"
    chmod 0600 "$S5_STATE"
    S5_OS_FAMILY=debian
    S5_INIT=systemd
}

t_state_field() {
    awk -F '\t' -v key="$1" -v value="$2" '
        BEGIN { OFS="\t" }
        $1 == key { $2=value }
        { print }
    ' "$S5_TEST_ROOT/valid-state" >"$S5_STATE"
}

t_state_expect() {
    s5_state_load && _tse_status=0 || _tse_status=$?
    assert_eq "$1" "$2" "$_tse_status"
}

t_state_expect "current 23-field state loads" 0
assert_eq "the recorded port loads" 23456 "$S5_PORT"
assert_eq "the recorded username loads" alice "$S5_USERNAME"
assert_eq "the detected backend survives state loading" debian:systemd "$S5_OS_FAMILY:$S5_INIT"

# Field order is not schema, and the last record need not have a trailing LF.
awk '{ rows[NR]=$0 } END { for(i=NR;i>0;i--) printf "%s%s",rows[i],(i==1 ? "" : "\n") }' \
    "$S5_TEST_ROOT/valid-state" >"$S5_STATE"
t_state_expect "unordered state without final newline loads" 0

t_state_reset
awk -F '\t' '$1 != "family"' "$S5_TEST_ROOT/valid-state" >"$S5_STATE"
t_state_expect "legacy 22-field state without family loads" 0
assert_eq "legacy systemd family defaults to Debian" debian "$S5_OS_FAMILY"
S5_OS_FAMILY=el
t_state_expect "legacy Debian state is refused on a detected EL host" 1

# A previous load must never cache either metadata or integrity results.
for _tskey in engine release commit asset archive_size archive_sha256 binary_size \
    binary_sha256 protocol auth udp listen port username os arch family init \
    account_uid account_gid config_sha256 unit_sha256 status; do
    t_state_reset
    awk -F '\t' -v key="$_tskey" '$1 != key' "$S5_TEST_ROOT/valid-state" >"$S5_STATE"
    if [ "$_tskey" != family ]; then
        t_state_expect "missing $_tskey is refused" 1
    fi
    t_state_reset
    awk -F '\t' -v key="$_tskey" '{ print; if ($1 == key) print }' \
        "$S5_TEST_ROOT/valid-state" >"$S5_STATE"
    t_state_expect "duplicate $_tskey is refused" 1
    t_state_reset
    t_state_field "$_tskey" ''
    t_state_expect "empty $_tskey is refused" 1
done

for _tsbad in unknown blank-line extra-column duplicate-key; do
    t_state_reset
    case "$_tsbad" in
    unknown) awk -F '\t' 'BEGIN { OFS="\t" } $1 == "os" { $1="unexpected" } { print }' \
        "$S5_TEST_ROOT/valid-state" >"$S5_STATE" ;;
    blank-line) printf '\n' >>"$S5_STATE" ;;
    extra-column) awk -F '\t' 'BEGIN { OFS="\t" } $1 == "os" { $3="extra" } { print }' \
        "$S5_TEST_ROOT/valid-state" >"$S5_STATE" ;;
    duplicate-key) awk -F '\t' 'BEGIN { OFS="\t" } $1 == "os" { $1="engine"; $2="xray" } { print }' \
        "$S5_TEST_ROOT/valid-state" >"$S5_STATE" ;;
    esac
    t_state_expect "$_tsbad is refused" 1
done

for _tsfield in engine:other release:other commit:other asset:other archive_size:1 \
    archive_sha256:bad binary_size:1 binary_sha256:bad protocol:socks auth:none udp:true \
    listen:999.1.2.3 port:1023 username:bad! arch:unknown family:alpine init:openrc \
    account_uid:901 account_gid:901 unit_sha256:bad status:partial; do
    t_state_reset
    t_state_field "${_tsfield%%:*}" "${_tsfield#*:}"
    t_state_expect "invalid ${_tsfield%%:*} is refused" 1
done

t_state_reset
t_state_field family unknown
S5_OS_FAMILY=''
t_state_expect "an unknown recorded family is refused without a detected family" 1

t_state_reset
t_state_field family alpine
S5_OS_FAMILY=alpine
t_state_expect "a matching host family does not permit alpine/systemd state" 1
t_state_reset
t_state_field init unknown
S5_INIT=unknown
t_state_expect "an unknown recorded and detected backend is refused" 1

t_state_reset
t_state_field config_sha256 bad
t_state_expect "config and state hash mismatch returns 2" 2
t_state_reset
printf 'changed\n' >>"$S5_CFG"
t_state_expect "external config edit returns 2" 2
# Restore the exact config from the fixture inputs, not the modified state.
s5_config_render >"$S5_CFG"
t_state_expect "a restored config is verified again" 0

# State is data even when a non-executable informational field contains shell syntax.
t_state_reset
awk -F '\t' -v marker="$S5_TEST_ROOT/state-executed" '
    BEGIN { OFS="\t" }
    $1 == "os" { $2="$(touch " marker "); `touch " marker "` | * \\" }
    { print }
' "$S5_TEST_ROOT/valid-state" >"$S5_STATE"
t_state_expect "shell syntax in the informational OS field is not executed" 0
assert_file_absent "no state command ran" "$S5_TEST_ROOT/state-executed"

t_state_reset
chmod 0644 "$S5_STATE"
t_state_expect "non-private state is refused" 1
t_state_reset
rm -f "$S5_STATE"
ln -s "$S5_TEST_ROOT/valid-state" "$S5_STATE"
t_state_expect "symlink state is refused" 1
rm -f "$S5_STATE"
t_state_reset

# Both backend artifacts go through the same load/hash path. The other backend's
# valid file must not conceal an externally replaced selected artifact.
for _tsbackend in systemd openrc; do
    t_state_reset
    S5_INIT=$_tsbackend
    case "$_tsbackend" in
    systemd) S5_OS_FAMILY=debian; _tspath=$S5_UNITDIR/$S5_PROJECT.service ;;
    openrc) S5_OS_FAMILY=alpine; _tspath=$S5_INITSCRIPT ;;
    esac
    s5_write_unit
    S5_UNIT_SHA256=$(sha256sum "$_tspath" | awk '{print $1}')
    s5_state_write
    t_state_expect "$_tsbackend state loads its own service artifact" 0
    cp "$_tspath" "$S5_TEST_ROOT/valid-service"
    printf 'changed\n' >>"$_tspath"
    t_state_expect "$_tsbackend external service edit is refused" 1
    cp "$S5_TEST_ROOT/valid-service" "$_tspath"
    t_state_expect "$_tsbackend restored service is verified again" 0
    rm -f "$_tspath"
    ln -s "$S5_TEST_ROOT/valid-service" "$_tspath"
    t_state_expect "$_tsbackend symlink service is refused" 1
    rm -f "$_tspath"
    cp "$S5_TEST_ROOT/valid-service" "$_tspath"
done

t_state_reset
printf '901\n' >"$S5_TEST_ROOT/user-exists"
t_state_expect "changed service account UID is refused" 1
printf '900\n' >"$S5_TEST_ROOT/user-exists"
printf '901\n' >"$S5_TEST_ROOT/group-exists"
t_state_expect "changed service group GID is refused" 1
printf '900\n' >"$S5_TEST_ROOT/group-exists"
printf 'changed\n' >>"$S5_BIN"
t_state_expect "external executable edit is refused" 1

t_summary
