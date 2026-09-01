#!/bin/sh
# tests/unit/test_render.sh - Task 5: configuration, credentials, unit/init-script
# and service-account rendering. Pure text generation; nothing is written or executed.

S5T_NAME=test_render
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
. "${S5_REPO_ROOT}/tests/lib/stub.sh"
. "${S5_REPO_ROOT}/tests/lib/env.sh"

t_mktestroot
t_stub_init

GOLD="${S5_REPO_ROOT}/tests/golden"
S5_LIB_ONLY=1
export S5_LIB_ONLY
# shellcheck source=/dev/null
. "${S5_SRC}"

S5_PORT=31080
S5_USERNAME=gooduser
S5_PASSWORD='TestPassword_123~x'
S5_SECRET=''

# Paths are test-root relative, so normalise them to placeholders before diffing.
norm() {
    sed -e "s|$S5_PREFIX|@PREFIX@|g" -e "s|$S5_SYSCONFDIR|@SYSCONFDIR@|g"
}

# ------------------------------------------------------------ 3proxy.cfg golden
actual=$(s5_render_cfg | norm)
expected=$(cat "$GOLD/3proxy.cfg")
assert_eq "3proxy.cfg matches golden byte for byte" "$expected" "$actual"

cfg=$(s5_render_cfg)
assert_contains "startup line uses -4 and -u2" "socks -4 -u2 -p31080 -i0.0.0.0" "$cfg"
assert_contains "auth strong present" "auth strong" "$cfg"
assert_contains "explicit allow with CONNECT only" "allow gooduser * * * CONNECT" "$cfg"
assert_contains "terminal explicit deny" "deny *" "$cfg"
assert_contains "credentials are included, not inlined" "users \$$S5_SYSCONFDIR/users.cfg" "$cfg"
assert_not_contains "no cleartext password in the main config" "TestPassword_123" "$cfg"

# last line must be the socks service line; the terminal rule must precede it
lastline=$(printf '%s\n' "$cfg" | tail -n 1)
assert_eq "socks line is last" "socks -4 -u2 -p31080 -i0.0.0.0" "$lastline"
denyline=$(printf '%s\n' "$cfg" | grep -n '^deny \*$' | tail -n 1 | cut -d: -f1)
allowline=$(printf '%s\n' "$cfg" | grep -n '^allow ' | tail -n 1 | cut -d: -f1)
if [ "$denyline" -gt "$allowline" ]; then t_ok; else t_bad "terminal deny must come after allow"; fi

# ---------------------------------------------- listen address override
assert_eq "production default listen address" "0.0.0.0" "$S5_LISTEN"
S5_LISTEN=127.0.0.1
assert_contains "the listen override is honoured in test mode" \
    "socks -4 -u2 -p31080 -i127.0.0.1" "$(s5_render_cfg)"
S5_LISTEN=0.0.0.0
assert_contains "default restored" "socks -4 -u2 -p31080 -i0.0.0.0" "$(s5_render_cfg)"

# ------------------------- private / loopback / metadata destination rejection
for cidr in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 \
    172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
    assert_contains "denies destination $cidr" "deny * * $cidr" "$cfg"
done
# every deny-by-CIDR rule must precede the allow rule
firstdeny=$(printf '%s\n' "$cfg" | grep -n '^deny \* \* ' | head -n 1 | cut -d: -f1)
lastcidrdeny=$(printf '%s\n' "$cfg" | grep -n '^deny \* \* ' | tail -n 1 | cut -d: -f1)
if [ "$firstdeny" -lt "$allowline" ] && [ "$lastcidrdeny" -lt "$allowline" ]; then
    t_ok
else
    t_bad "CIDR denies must all precede the allow rule"
fi

# ------------------------------------------------- SPEC section 6 denylist
# Two greps rather than one BRE alternation: GNU's alternation operator is not
# POSIX, so under a conforming grep the old single-pattern form matched nothing
# and this entire 20-directive loop passed silently -- the widest fail-open in
# the suite, since it is the only check that the *rendered config* carries no
# forbidden directive. A bracketed-class anchor for the directive-with-arguments
# form, `-x -F` for a bare directive line; neither uses an extension.
for d in proxy admin ftppr smtpp pop3p imapp tlspr tcppm udppm dnspr \
    writable system plugin parent authcache chroot setuid setgid; do
    if printf '%s\n' "$cfg" | grep -q "^${d}[[:space:]]" ||
        printf '%s\n' "$cfg" | grep -qxF "$d"; then
        t_bad "forbidden directive present: $d"
    else
        t_ok
    fi
done
assert_not_contains "no auth none" "auth none" "$cfg"
assert_not_contains "no auth iponly" "auth iponly" "$cfg"
assert_not_contains "no BIND operation" "BIND" "$cfg"
assert_not_contains "no UDPASSOC operation" "UDPASSOC" "$cfg"
assert_not_contains "no include of an unapproved file" "\$/etc/3proxy" "$cfg"

# ------------------------------------------------------------- users.cfg golden
uactual=$(s5_render_users | norm)
uexpected=$(cat "$GOLD/users.cfg")
assert_eq "users.cfg matches golden" "$uexpected" "$uactual"
ulines=$(s5_render_users | grep -c '')
assert_eq "users.cfg is exactly one line" 1 "$ulines"
if s5_render_users | grep -q '^users'; then
    t_bad "users.cfg must not repeat the users directive"
else
    t_ok
fi

# A password outside the allowed charset must be refused, not emitted.
S5_PASSWORD='bad:password:here'
t_run s5_render_users
assert_ne "out-of-charset password refused" 0 "$T_STATUS"
assert_not_contains "refusal does not echo the secret" "bad:password" "$T_OUT"
S5_PASSWORD='TestPassword_123~x'

S5_USERNAME='bad:user'
t_run s5_render_users
assert_ne "out-of-charset username refused" 0 "$T_STATUS"
S5_USERNAME=gooduser

# ----------------------------------------------------------- systemd unit golden
sactual=$(s5_render_systemd_unit | norm)
sexpected=$(cat "$GOLD/socks5-manager.service")
assert_eq "systemd unit matches golden" "$sexpected" "$sactual"
unit=$(s5_render_systemd_unit)
assert_contains "unit runs as the service user" "User=socks5proxy" "$unit"
assert_contains "unit runs in the service group" "Group=socks5proxy" "$unit"
assert_contains "unit hardening: NoNewPrivileges" "NoNewPrivileges=yes" "$unit"
assert_contains "unit hardening: ProtectSystem" "ProtectSystem=strict" "$unit"
assert_contains "unit drops all capabilities" "CapabilityBoundingSet=" "$unit"
assert_not_contains "no CAP_NET_BIND_SERVICE (ports are >=1024)" "CAP_NET_BIND_SERVICE" "$unit"
assert_not_contains "no reload support in v1" "ExecReload" "$unit"

# --------------------------------------------------------- OpenRC script golden
oactual=$(s5_render_openrc | norm)
oexpected=$(cat "$GOLD/openrc-init")
assert_eq "OpenRC script matches golden" "$oexpected" "$oactual"
orc=$(s5_render_openrc)
assert_contains "OpenRC drops privileges" 'command_user="socks5proxy:socks5proxy"' "$orc"
assert_contains "OpenRC uses supervise-daemon" 'supervisor="supervise-daemon"' "$orc"
assert_contains "OpenRC logs to syslog via logger" 'logger -t socks5-manager' "$orc"
assert_contains "OpenRC orders after firewall" "after firewall" "$orc"
assert_not_contains "OpenRC does not use need net" "need net" "$orc"
assert_not_contains "OpenRC creates no ordinary log file" "output_log=" "$orc"
assert_not_contains "OpenRC creates no ordinary error log file" "error_log=" "$orc"

# Server address output is for the IPv4-only deployed listener. If the fixed
# external lookup fails, neither IPv6 nor private local addresses are guessed;
# the operator receives the explicit replacement placeholder.
mkdir -p "$S5_TEST_ROOT/iptest"
ip() { return 1; }
curl() { return 7; }
hostname() { printf '%s\n' '2001:db8::10 10.20.30.40'; }
s5_resolve_card_address
assert_eq "failed public lookup uses the placeholder" SERVER_IPV4 "$S5_CARD_ADDR"
assert_eq "and reports the placeholder kind" placeholder "$S5_CARD_KIND"

# The old behavior silently accepted documentation space; it must not return.
hostname() { printf '%s\n' '2001:db8::10 192.0.2.25'; }
s5_resolve_card_address
assert_ne "TEST-NET is never shown as the server address" 192.0.2.25 "$S5_CARD_ADDR"

unset -f ip
unset -f hostname
unset -f curl

t_stub id 1
t_stub useradd 0
t_stub groupadd 0
t_stub adduser 0
t_stub addgroup 0
t_stub chown 0

S5_OS_FAMILY=debian
assert_eq "nologin path on debian" "/usr/sbin/nologin" "$(s5_nologin_path)"
S5_OS_FAMILY=el
assert_eq "nologin path on el" "/usr/sbin/nologin" "$(s5_nologin_path)"
S5_OS_FAMILY=alpine
assert_eq "nologin path on alpine" "/sbin/nologin" "$(s5_nologin_path)"

: >"$T_TRANSCRIPT"
s5env_account_stubs
S5_OS_FAMILY=debian
t_run s5_account_create
assert_eq "account creation succeeds on debian" 0 "$T_STATUS"
t_assert_called "groupadd used" 'groupadd'
t_assert_called "useradd used" 'useradd'
t_assert_called "no home directory" '[-]M|--no-create-home'
t_assert_called "nologin shell" 'nologin'
t_assert_cmd_never_called "no password is ever set on the account" passwd chpasswd

: >"$T_TRANSCRIPT"
: >"$S5_TEST_ROOT/stub_passwd"
: >"$S5_TEST_ROOT/stub_group"
rm -f "$S5_TEST_ROOT/stub_group_created"
S5_OS_FAMILY=alpine
t_run s5_account_create
assert_eq "account creation succeeds on alpine" 0 "$T_STATUS"
t_assert_called "addgroup used on alpine" 'addgroup'
t_assert_called "adduser used on alpine" 'adduser'
t_assert_called "alpine account is system, no home" 'adduser .*-S'
t_assert_cmd_never_called "no password on alpine either" passwd chpasswd

# the account helper must never receive the credential
t_assert_no_secret_in_argv "account creation never sees the proxy password" 'TestPassword_123'

# ---------------------------------------------- permission/ownership encapsulation
mkdir -p "$S5_TEST_ROOT/permtest"
target="$S5_TEST_ROOT/permtest/f"
: >"$target"
S5_SKIP_OWNERSHIP=1
t_run s5_apply_owner_mode "$target" "root:socks5proxy" 0640
assert_eq "mode/ownership helper succeeds" 0 "$T_STATUS"
assert_mode "mode applied" 640 "$target"
S5_SKIP_OWNERSHIP=0

t_summary
