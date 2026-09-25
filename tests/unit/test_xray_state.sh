#!/bin/sh
# State compatibility and fail-closed integrity, through the real load boundary.
S5T_NAME=test_xray_state
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
. "${S5_REPO_ROOT}/tests/lib/xray-fixture.sh"
t_xray_fixture 23456
t_xray_install
cp "$S5_STATE" "$S5_TEST_ROOT/valid-state"

# Every case starts with the same valid disk state and detected host backend.
s5t_state_reset() {
    cp "$S5_TEST_ROOT/valid-state" "$S5_STATE"
    chmod 0600 "$S5_STATE"
    S5_OS_FAMILY=debian
    S5_INIT=systemd
}

s5t_state_field() {
    awk -F '\t' -v key="$1" -v value="$2" '
        BEGIN { OFS="\t" }
        $1 == key { $2=value }
        { print }
    ' "$S5_TEST_ROOT/valid-state" >"$S5_STATE"
}

s5t_state_expect() {
    s5_state_load && _tse_status=0 || _tse_status=$?
    assert_eq "$1" "$2" "$_tse_status"
}

s5t_state_expect "current 24-field state loads" 0
assert_eq "the recorded port loads" 23456 "$S5_PORT"
assert_eq "the recorded username loads" alice "$S5_USERNAME"
assert_eq "the detected backend survives state loading" debian:systemd "$S5_OS_FAMILY:$S5_INIT"

# Field order is not schema, and the last record need not have a trailing LF.
awk '{ rows[NR]=$0 } END { for(i=NR;i>0;i--) printf "%s%s",rows[i],(i==1 ? "" : "\n") }' \
    "$S5_TEST_ROOT/valid-state" >"$S5_STATE"
s5t_state_expect "unordered state without final newline loads" 0

s5t_state_reset
awk -F '\t' '$1 != "schema" && $1 != "family"' "$S5_TEST_ROOT/valid-state" >"$S5_STATE"
s5t_state_expect "legacy 22-field state without schema or family loads" 0
assert_eq "legacy systemd family defaults to Debian" debian "$S5_OS_FAMILY"
S5_OS_FAMILY=el
s5t_state_expect "legacy Debian state is refused on a detected EL host" 1

# A previous load must never cache either metadata or integrity results.
for _tskey in schema engine release commit asset archive_size archive_sha256 binary_size \
    binary_sha256 protocol auth udp listen port username os arch family init \
    account_uid account_gid config_sha256 unit_sha256 status; do
    s5t_state_reset
    awk -F '\t' -v key="$_tskey" '$1 != key' "$S5_TEST_ROOT/valid-state" >"$S5_STATE"
    case "$_tskey" in
    schema) s5t_state_expect "missing schema is recognized as legacy" 0 ;;
    *) s5t_state_expect "missing $_tskey is refused" 1 ;;
    esac
    s5t_state_reset
    awk -F '\t' -v key="$_tskey" '{ print; if ($1 == key) print }' \
        "$S5_TEST_ROOT/valid-state" >"$S5_STATE"
    s5t_state_expect "duplicate $_tskey is refused" 1
    s5t_state_reset
    s5t_state_field "$_tskey" ''
    s5t_state_expect "empty $_tskey is refused" 1
done

for _tsbad in unknown blank-line extra-column duplicate-key; do
    s5t_state_reset
    case "$_tsbad" in
    unknown) awk -F '\t' 'BEGIN { OFS="\t" } $1 == "os" { $1="unexpected" } { print }' \
        "$S5_TEST_ROOT/valid-state" >"$S5_STATE" ;;
    blank-line) printf '\n' >>"$S5_STATE" ;;
    extra-column) awk -F '\t' 'BEGIN { OFS="\t" } $1 == "os" { $3="extra" } { print }' \
        "$S5_TEST_ROOT/valid-state" >"$S5_STATE" ;;
    duplicate-key) awk -F '\t' 'BEGIN { OFS="\t" } $1 == "os" { $1="engine"; $2="xray" } { print }' \
        "$S5_TEST_ROOT/valid-state" >"$S5_STATE" ;;
    esac
    s5t_state_expect "$_tsbad is refused" 1
done


s5t_state_reset
s5t_state_field schema 2
s5t_state_expect "unknown schema is classified unsupported" 4
s5t_state_reset
s5t_state_field schema 2
printf 'future_field\tfuture_value\n' >>"$S5_STATE"
s5t_state_expect "unknown schema with future fields remains unsupported" 4
s5t_state_reset
awk -F '\t' '$1 == "schema" { print; print } $1 != "schema" { print }' \
    "$S5_TEST_ROOT/valid-state" >"$S5_STATE"
s5t_state_expect "duplicate schema discriminator is invalid" 1

for _tsfield in engine:other release:other commit:other asset:other archive_size:bad \
    archive_sha256:bad binary_size:bad binary_sha256:bad protocol:socks auth:none udp:true \
    listen:999.1.2.3 port:1023 username:bad! arch:unknown family:alpine init:openrc \
    account_uid:901 account_gid:901 unit_sha256:bad status:partial; do
    s5t_state_reset
    s5t_state_field "${_tsfield%%:*}" "${_tsfield#*:}"
    if [ "${_tsfield%%:*}" = status ]; then
        s5t_state_expect "unsupported status is classified separately" 4
    else
        s5t_state_expect "invalid ${_tsfield%%:*} is refused" 1
    fi
done

for _tsrelease in v2x.3.4 v2.3y.4 v2.3.4z v2.3 v2.3.4.5 v.3.4; do
    s5t_state_reset
    s5t_state_field release "$_tsrelease"
    s5t_state_expect "malformed release $_tsrelease is refused" 1
done

s5t_state_reset
s5t_state_field family unknown
S5_OS_FAMILY=''
s5t_state_expect "an unknown recorded family is refused without a detected family" 1

s5t_state_reset
s5t_state_field family alpine
S5_OS_FAMILY=alpine
s5t_state_expect "a matching host family does not permit alpine/systemd state" 1
s5t_state_reset
s5t_state_field init unknown
S5_INIT=unknown
s5t_state_expect "an unknown recorded and detected backend is refused" 1

s5t_state_reset
s5t_state_field config_sha256 bad
s5t_state_expect "config and state hash mismatch returns 2" 2
s5t_state_reset
printf 'changed\n' >>"$S5_CFG"
s5t_state_expect "external config edit returns 2" 2
# Restore the exact config from the fixture inputs, not the modified state.
s5_config_render >"$S5_CFG"
s5t_state_expect "a restored config is verified again" 0

# State is data even when a non-executable informational field contains shell syntax.
s5t_state_reset
awk -F '\t' -v marker="$S5_TEST_ROOT/state-executed" '
    BEGIN { OFS="\t" }
    $1 == "os" { $2="$(touch " marker "); `touch " marker "` | * \\" }
    { print }
' "$S5_TEST_ROOT/valid-state" >"$S5_STATE"
s5t_state_expect "shell syntax in the informational OS field is not executed" 0
assert_file_absent "no state command ran" "$S5_TEST_ROOT/state-executed"

s5t_state_reset
chmod 0644 "$S5_STATE"
s5t_state_expect "non-private state is refused" 1
s5t_state_reset
rm -f "$S5_STATE"
ln -s "$S5_TEST_ROOT/valid-state" "$S5_STATE"
s5t_state_expect "symlink state is refused" 1
rm -f "$S5_STATE"
s5t_state_reset

# Both backend artifacts go through the same load/hash path. The other backend's
# valid file must not conceal an externally replaced selected artifact.
for _tsbackend in systemd openrc; do
    s5t_state_reset
    S5_INIT=$_tsbackend
    case "$_tsbackend" in
    systemd) S5_OS_FAMILY=debian; _tspath=$S5_UNITDIR/$S5_PROJECT.service ;;
    openrc) S5_OS_FAMILY=alpine; _tspath=$S5_INITSCRIPT ;;
    esac
    s5_write_unit
    S5_UNIT_SHA256=$(t_sha256 "$_tspath")
    s5_state_write
    s5t_state_expect "$_tsbackend state loads its own service artifact" 0
    cp "$_tspath" "$S5_TEST_ROOT/valid-service"
    printf 'changed\n' >>"$_tspath"
    s5t_state_expect "$_tsbackend external service edit is refused" 1
    cp "$S5_TEST_ROOT/valid-service" "$_tspath"
    s5t_state_expect "$_tsbackend restored service is verified again" 0
    rm -f "$_tspath"
    ln -s "$S5_TEST_ROOT/valid-service" "$_tspath"
    s5t_state_expect "$_tsbackend symlink service is refused" 1
    rm -f "$_tspath"
    cp "$S5_TEST_ROOT/valid-service" "$_tspath"
done

s5t_state_reset
printf '901\n' >"$S5_TEST_ROOT/user-exists"
s5t_state_expect "changed service account UID is refused" 1
printf '900\n' >"$S5_TEST_ROOT/user-exists"
printf '901\n' >"$S5_TEST_ROOT/group-exists"
s5t_state_expect "changed service group GID is refused" 1
printf '900\n' >"$S5_TEST_ROOT/group-exists"
printf 'changed\n' >>"$S5_BIN"
s5t_state_expect "external executable edit is refused" 1

# Installed identity is independent of the current download candidate. A valid
# older release remains operable while a later update still selects current pins.
s5t_state_reset
cp "$S5_TEST_ROOT/asset-xray" "$S5_BIN"
chmod 755 "$S5_PREFIX" "$S5_BIN"
chmod 750 "$S5_SYSCONFDIR"
chmod 640 "$S5_CFG"
chmod 700 "$S5_STATEDIR"
chmod 600 "$S5_STATE"
chmod 644 "$S5_SERVICE_ARTIFACT"
printf '900\n' >"$S5_TEST_ROOT/user-exists"
printf '900\n' >"$S5_TEST_ROOT/group-exists"
awk -F '\t' 'BEGIN { OFS="\t" }
    $1 == "release" { $2="v25.1.1" }
    $1 == "commit" { $2="1111111111111111111111111111111111111111" }
    $1 == "archive_size" { $2="123456" }
    $1 == "archive_sha256" { $2="2222222222222222222222222222222222222222222222222222222222222222" }
    { print }
' "$S5_TEST_ROOT/valid-state" >"$S5_STATE"
s5t_state_expect "a supported older installed release remains loadable" 0
assert_eq "the state seam reports the installed release" v25.1.1 "$S5_INSTALLED_RELEASE"
s5_service_state() { return 1; }
s5_listener_state() { return 1; }
s5_lock_acquire() { S5_LOCK_HELD=1; return 0; }
s5_lock_release() { S5_LOCK_HELD=0; return 0; }
s5_precheck() { return 0; }
t_run s5_cmd_status
assert_contains "status reports the installed historical release"     'Xray version: v25.1.1' "$T_OUT"
assert_not_contains "status does not substitute the current candidate release"     "Xray version: $S5_XRAY_VERSION" "$T_OUT"
s5_asset_select
assert_eq "current candidate selection remains on the script release" Xray-linux-64.zip "$S5_ASSET_NAME"
assert_eq "current candidate digest is not replaced by historical state" "$S5T_BIN_SHA256" "$S5_ASSET_BINARY_SHA256"

# Mode checks are independent of hashes. Every mutation uses unchanged bytes.
for _tsmode_case in \
    config:644 config:666 prefix:775 confdir:755 statedir:755 binary:775 unit:664; do
    s5t_state_reset
    _tswhich=${_tsmode_case%%:*}
    _tsmode=${_tsmode_case#*:}
    case "$_tswhich" in
    config) _tspath=$S5_CFG ;;
    prefix) _tspath=$S5_PREFIX ;;
    confdir) _tspath=$S5_SYSCONFDIR ;;
    statedir) _tspath=$S5_STATEDIR ;;
    binary) _tspath=$S5_BIN ;;
    unit) _tspath=$S5_SERVICE_ARTIFACT ;;
    esac
    chmod "$_tsmode" "$_tspath"
    s5t_state_expect "$_tswhich mode $_tsmode is refused" 1
    case "$_tswhich" in
    config) chmod 640 "$_tspath" ;;
    prefix|binary) chmod 755 "$_tspath" ;;
    confdir) chmod 750 "$_tspath" ;;
    statedir) chmod 700 "$_tspath" ;;
    unit) chmod 644 "$_tspath" ;;
    esac
done

s5t_state_owner_case() (
    _soc_target=$1
    S5_SKIP_OWNERSHIP=0
    stat() {
        if [ "$1" = -c ] && [ "$2" = '%U:%G %a' ]; then
            _soc_mode=$(/usr/bin/stat -c %a "$3") || return 1
            case "$3" in
            "$S5_PREFIX"|"$S5_BIN"|"$S5_STATEDIR"|"$S5_STATE"|"$S5_SERVICE_ARTIFACT") _soc_owner=root:root ;;
            "$S5_SYSCONFDIR"|"$S5_CFG") _soc_owner=root:xray-socks5 ;;
            *) return 1 ;;
            esac
            case "$_soc_target:$3" in
            config-owner:"$S5_CFG") _soc_owner=operator:xray-socks5 ;;
            config-group:"$S5_CFG") _soc_owner=root:operators ;;
            binary-owner:"$S5_BIN") _soc_owner=xray-socks5:root ;;
            state-owner:"$S5_STATE") _soc_owner=operator:root ;;
            unit-group:"$S5_SERVICE_ARTIFACT") _soc_owner=root:xray-socks5 ;;
            confdir-owner:"$S5_SYSCONFDIR") _soc_owner=xray-socks5:xray-socks5 ;;
            esac
            printf '%s %s\n' "$_soc_owner" "$_soc_mode"
        else
            /usr/bin/stat "$@"
        fi
    }
    s5_state_load
)
for _soc_case in healthy config-owner config-group binary-owner state-owner unit-group confdir-owner; do
    t_run s5t_state_owner_case "$_soc_case"
    if [ "$_soc_case" = healthy ]; then
        assert_eq "exact installed ownership baseline loads" 0 "$T_STATUS"
    else
        assert_eq "$_soc_case ownership drift is refused" 1 "$T_STATUS"
    fi
done

t_summary
