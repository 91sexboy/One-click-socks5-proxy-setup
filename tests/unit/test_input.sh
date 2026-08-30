#!/bin/sh
# tests/unit/test_input.sh - Task 3: validation, generation, port probing, prompts.
# No test binds a port; the probe is stubbed.

S5T_NAME=test_input
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
. "${S5_REPO_ROOT}/tests/lib/stub.sh"

t_mktestroot
t_stub_init

S5_LIB_ONLY=1
export S5_LIB_ONLY
# shellcheck source=/dev/null
. "${S5_SRC}"

# --------------------------------------------------------------------------
# Port validation
# --------------------------------------------------------------------------
for p in 1024 1080 20000 40000 65535; do
    t_run s5_valid_port "$p"
    assert_eq "port $p accepted" 0 "$T_STATUS"
done
for p in 0 1 80 443 1023 65536 99999 -1 abc 12a "" " " 1080.5 01080 001080 00; do
    t_run s5_valid_port "$p"
    assert_ne "port [$p] rejected" 0 "$T_STATUS"
done
# Leading zeros are octal to the shell ([ 01080 ] is 1080) but a literal
# string to the engine and to `ss`, so a "valid" 01080 would never match the
# listener it collides with. Rejected as syntax, not by range arithmetic.
t_run s5_valid_port 01080
assert_contains "a leading zero is a syntax error, not a range miss" \
    "leading zero" "$T_OUT"
# 1000 nines in one word: the old printf-'9%.0s'-over-word-splitting form
# collapsed to a single "9" because the awk output was one word, so the
# "oversized" case never actually left the normal range.
huge_port=$(awk 'BEGIN { for (i = 1; i <= 1000; i++) printf "9" }')
t_run s5_valid_port "$huge_port"
assert_ne "an oversized numeric port is rejected before shell arithmetic" 0 "$T_STATUS"

# --------------------------------------------------------------------------
# Username validation, including config-injection attempts
# --------------------------------------------------------------------------
for u in abc user1 A_b-c proxyuser01 abcdefghijklmnopqrstuvwxyz012345; do
    t_run s5_valid_username "$u"
    assert_eq "username [$u] accepted" 0 "$T_STATUS"
done
for u in "" a ab "abcdefghijklmnopqrstuvwxyz0123456" \
    "user:pass" "user#c" 'user$x' 'user"x' "user name" "user/x" 'user\x' \
    "user
name" "user;x" "user*" 'user`x`' "user'x" "üser"; do
    t_run s5_valid_username "$u"
    assert_ne "username [$u] rejected" 0 "$T_STATUS"
done

# --------------------------------------------------------------------------
# Password validation
# --------------------------------------------------------------------------
for p in "abcdefghijkl" "Aa0._~-Aa0._~-" \
    "0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456"; do
    t_run s5_valid_password "$p"
    assert_eq "password of length ${#p} accepted" 0 "$T_STATUS"
done
for p in "" "short" "elevenchars" \
    "01234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890"; do
    t_run s5_valid_password "$p"
    assert_ne "password of length ${#p} rejected" 0 "$T_STATUS"
done
# Injection-relevant characters must be refused
for p in "pass:word:xx" "pass#word#xx" 'pass$wordxxx' 'pass"wordxxx' \
    "pass wordxxx" "pass/wordxxx" 'pass\wordxxx' "pass;wordxxx" \
    'pass`word`xx' "pass'wordxxx" "pass|wordxxx" "pass@wordxxx" "pass=wordxxx"; do
    t_run s5_valid_password "$p"
    assert_ne "password containing an injection char rejected" 0 "$T_STATUS"
done

# A rejection message must never echo the candidate secret
t_run s5_valid_password 'MySecretLeak:12345'
assert_not_contains "rejection does not echo the secret" "MySecretLeak" "$T_OUT"

# --------------------------------------------------------------------------
# Random generation: charset, length, and absence of modulo bias
# --------------------------------------------------------------------------
pw=$(s5_random_password)
assert_eq "generated password is exactly 32 chars" 32 "${#pw}"
t_run s5_valid_password "$pw"
assert_eq "generated password passes validation" 0 "$T_STATUS"

i=0
allok=yes
while [ "$i" -lt 25 ]; do
    g=$(s5_random_password)
    if [ "${#g}" -ne 32 ]; then allok=no; fi
    if ! s5_valid_password "$g" >/dev/null 2>&1; then allok=no; fi
    i=$((i + 1))
done
assert_eq "25 generated passwords all valid and 32 chars" yes "$allok"

# Distinctness (a broken generator that returns a constant would fail here)
assert_ne "two generated passwords differ" "$(s5_random_password)" "$(s5_random_password)"

# Bias / coverage over a single large sample of the same primitive.
SAMPLE=$(s5_random_string 19800 "$S5_PASS_CHARSET")
assert_eq "large sample has the requested length" 19800 "${#SAMPLE}"
t_run s5_valid_password "$(printf '%s' "$SAMPLE" | cut -c1-120)"
assert_eq "sample contains only allowed characters" 0 "$T_STATUS"

# Every character of the 66-char set must appear, and none may dominate.
# Expected count 300, sd ~17.2; a modulo-bias generator would push some past 450.
counts=$(printf '%s' "$SAMPLE" | fold -w1 | sort | uniq -c)
distinct=$(printf '%s\n' "$counts" | grep -c .)
assert_eq "all 66 charset members appear" 66 "$distinct"
maxcount=$(printf '%s\n' "$counts" | awk '{print $1}' | sort -n | tail -1)
mincount=$(printf '%s\n' "$counts" | awk '{print $1}' | sort -n | head -1)
if [ "$maxcount" -le 420 ]; then t_ok; else t_bad "bias: max char count $maxcount > 420"; fi
if [ "$mincount" -ge 190 ]; then t_ok; else t_bad "bias: min char count $mincount < 190"; fi

# Random username
un=$(s5_random_username)
t_run s5_valid_username "$un"
assert_eq "generated username is valid" 0 "$T_STATUS"
assert_ne "two generated usernames differ" "$(s5_random_username)" "$(s5_random_username)"

# Random integer stays in range
j=0
inrange=yes
while [ "$j" -lt 200 ]; do
    r=$(s5_random_int 40001)
    if [ "$r" -lt 0 ] || [ "$r" -gt 40000 ]; then inrange=no; fi
    j=$((j + 1))
done
assert_eq "s5_random_int stays within range" yes "$inrange"

# --------------------------------------------------------------------------
# Port probing via an injected stub - nothing is ever bound
# --------------------------------------------------------------------------
printf '%s\n' 20001 20002 >"$S5_TEST_ROOT/occupied"
cat >"$S5_TEST_ROOT/bin/portprobe" <<'PROBE'
#!/bin/sh
if grep -qx "$1" "$S5_TEST_ROOT/occupied" 2>/dev/null; then exit 1; fi
exit 0
PROBE
chmod 0755 "$S5_TEST_ROOT/bin/portprobe"
S5_PORT_PROBE="$S5_TEST_ROOT/bin/portprobe"

t_run s5_port_free 20001
assert_ne "occupied port reported busy" 0 "$T_STATUS"
t_run s5_port_free 31337
assert_eq "free port reported free" 0 "$T_STATUS"

rp=$(s5_random_port)
if [ "$rp" -ge 20000 ] && [ "$rp" -le 60000 ]; then t_ok; else t_bad "random port $rp out of 20000-60000"; fi
t_run s5_valid_port "$rp"
assert_eq "random port is a valid port" 0 "$T_STATUS"

# --------------------------------------------------------------------------
# A probe that EXISTS but does not WORK must not count as available. A broken
# ss on PATH used to suppress the iproute2 repair AND mask a working netstat,
# and every port question then came back "already in use" when the truth was
# "cannot determine".
# --------------------------------------------------------------------------
S5_PORT_PROBE=''
export S5_PORT_PROBE
ss() { return 1; }
netstat() { return 1; }
t_run s5_probe_cmd
assert_eq "a broken ss with no netstat means no probe" 1 "$T_STATUS"
S5_PKGMGR=apt
assert_eq "a broken ss still plans the probe package" "iproute2" "$(s5_runtime_deps 2>/dev/null)"

netstat() { printf 'Proto Recv-Q\n'; return 0; }
t_run s5_probe_cmd
assert_eq "a broken ss falls back to a working netstat" 0 "$T_STATUS"
assert_eq "and netstat is the selected probe" "netstat" "$(s5_probe_cmd)"
unset -f ss netstat

# A probe that answers "cannot determine" (status 2) is never reported as a
# busy port, in either the manual or the random path.
cat >"$S5_TEST_ROOT/bin/portprobe" <<'PROBE'
#!/bin/sh
exit 2
PROBE
chmod 0755 "$S5_TEST_ROOT/bin/portprobe"
S5_PORT_PROBE="$S5_TEST_ROOT/bin/portprobe"
S5_PORT=''
printf '45678\n' >"$S5_TEST_ROOT/in"
s5_prompt_port <"$S5_TEST_ROOT/in" >"$S5_TEST_ROOT/ppout" 2>&1
ppstatus=$?
assert_ne "the prompt fails when the probe cannot observe" 0 "$ppstatus"
ppout=$(cat "$S5_TEST_ROOT/ppout")
assert_contains "an unobservable port is not called busy" \
    "cannot determine" "$ppout"
assert_not_contains "the honest message replaces the busy message" \
    "already in use" "$ppout"

t_run s5_random_port
assert_ne "random selection fails honestly on an unobservable probe" 0 "$T_STATUS"
assert_contains "random selection names the probe failure" \
    "cannot determine" "$T_OUT"
assert_not_contains "and does not blame the port range" "after 50 attempts" "$T_OUT"
rm -f "$S5_TEST_ROOT/ppout"

# Restore the stateful probe stub for the prompt tests that follow.
cat >"$S5_TEST_ROOT/bin/portprobe" <<'PROBE'
#!/bin/sh
if grep -qx "$1" "$S5_TEST_ROOT/occupied" 2>/dev/null; then exit 1; fi
exit 0
PROBE
chmod 0755 "$S5_TEST_ROOT/bin/portprobe"
S5_PORT_PROBE="$S5_TEST_ROOT/bin/portprobe"


# When no probe exists at all, behaviour is fail-closed (never "assume free").
# The probe selector is shadowed rather than emptying PATH, because busybox
# ships netstat as a built-in applet that PATH manipulation cannot hide.
S5_PORT_PROBE=''
s5_probe_cmd() { return 1; }
t_run s5_port_free 31337
assert_ne "no probe available: fail closed" 0 "$T_STATUS"
assert_contains "fail-closed path explains itself" "cannot determine" "$T_OUT"
S5_PORT_PROBE="$S5_TEST_ROOT/bin/portprobe"

# --------------------------------------------------------------------------
# Prompts driven from a file (no TTY), and secret hygiene.
# A pipeline would run the reader in a subshell and lose the assignment,
# so input is fed by redirection instead.
# --------------------------------------------------------------------------
feed() { printf '%s' "$1" >"$S5_TEST_ROOT/in"; }

S5_PORT=''
feed '
'
s5_prompt_port <"$S5_TEST_ROOT/in" >/dev/null 2>&1
if [ "$S5_PORT" -ge 20000 ] && [ "$S5_PORT" -le 60000 ]; then t_ok; else t_bad "empty input should generate a random port, got [$S5_PORT]"; fi

S5_PORT=''
feed '45678
'
s5_prompt_port <"$S5_TEST_ROOT/in" >/dev/null 2>&1
assert_eq "explicit port accepted" 45678 "$S5_PORT"

S5_PORT=''
feed '20001
33333
'
s5_prompt_port <"$S5_TEST_ROOT/in" >/dev/null 2>&1
assert_eq "occupied port retried, then accepted" 33333 "$S5_PORT"

# --------------------------------------------------------------------------
# With no probe at all, both port paths must fail closed *and say why*.
#
# s5_port_free answers "not free" when it cannot observe anything, which is the
# right answer for a fail-closed check but the wrong thing to repeat verbatim:
# s5_random_port used to run all 50 attempts, emit 50 identical "cannot
# determine" warnings, and then blame a port range it had never observed, while
# s5_prompt_port reported the operator's own port as "already in use". Both now
# name the missing probe once and stop.
# --------------------------------------------------------------------------
S5_PORT_PROBE=''
s5_probe_cmd() { return 1; }

t_run s5_random_port
assert_ne "no probe available: no random port is invented" 0 "$T_STATUS"
assert_contains "the missing probe is the stated reason" \
    "neither ss nor netstat" "$T_OUT"
assert_not_contains "the port range is not blamed" "after 50 attempts" "$T_OUT"
floods=$(printf '%s\n' "$T_OUT" | grep -c 'cannot determine' || true)
if [ "$floods" -le 1 ]; then
    t_ok
else
    t_bad "the missing probe is reported $floods times, not once"
fi

# The prompt runs in this shell, not through t_run: t_run captures output in a
# command substitution, so S5_PORT could not be observed afterwards and the
# post-condition would pass no matter what the function did.
S5_PORT='SENTINEL-NOT-A-PORT'
feed '45678
'
s5_prompt_port <"$S5_TEST_ROOT/in" >"$S5_TEST_ROOT/ppout" 2>&1
ppstatus=$?
ppout=$(cat "$S5_TEST_ROOT/ppout")
assert_ne "no probe available: the port prompt fails closed" 0 "$ppstatus"
assert_eq "no port is adopted" 'SENTINEL-NOT-A-PORT' "$S5_PORT"
assert_not_contains "a port that was never observed is not called 'in use'" \
    "already in use" "$ppout"
assert_contains "the prompt names the missing probe too" "neither ss nor netstat" "$ppout"
assert_not_contains "and does not pretend the entry was invalid" \
    "too many invalid port entries" "$ppout"
rm -f "$S5_TEST_ROOT/ppout"
S5_PORT_PROBE="$S5_TEST_ROOT/bin/portprobe"
S5_PORT=''

S5_USERNAME=''
feed '
'
s5_prompt_username <"$S5_TEST_ROOT/in" >/dev/null 2>&1
assert_eq "empty input generates a 12-character username" 12 "${#S5_USERNAME}"
case "$S5_USERNAME" in
[a-z][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9]) t_ok ;;
*) t_bad "generated username has the wrong shape: [$S5_USERNAME]" ;;
esac
t_run s5_valid_username "$S5_USERNAME"
assert_eq "empty input generates a valid username" 0 "$T_STATUS"

S5_USERNAME=''
feed 'chosenuser
'
s5_prompt_username <"$S5_TEST_ROOT/in" >/dev/null 2>&1
assert_eq "explicit username accepted" chosenuser "$S5_USERNAME"

S5_USERNAME=''
feed 'bad:name
gooduser
'
s5_prompt_username <"$S5_TEST_ROOT/in" >/dev/null 2>&1
assert_eq "invalid username retried, then accepted" gooduser "$S5_USERNAME"

S5_PASSWORD=''
feed '
'
s5_prompt_password <"$S5_TEST_ROOT/in" >/dev/null 2>&1
assert_eq "empty input generates a 32-char password" 32 "${#S5_PASSWORD}"

S5_PASSWORD=''
S5_SECRET=''
feed 'GoodPass_123~x
SecondLineMustSurvive
'
# One open descriptor for both the function and the follow-up read: re-opening
# the file would restart at byte 0 and the survivor check could never fail.
exec 3<"$S5_TEST_ROOT/in"
s5_prompt_password <&3 >/dev/null 2>&1
assert_eq "single-read custom password accepted" 'GoodPass_123~x' "$S5_PASSWORD"
assert_eq "and arms redaction" 'GoodPass_123~x' "$S5_SECRET"
read -r _pw_survivor <&3
exec 3<&-
assert_eq "the next queued line survives unread" 'SecondLineMustSurvive' "$_pw_survivor"
_pw_survivor='' 

# Mismatch must not be silently accepted; end of input must not fall back to
# generating a password.
#
# This case deliberately does NOT use t_run: t_run captures output through a
# command substitution, so the callee runs in a subshell and no global it sets
# can be observed afterwards. Asserting on S5_PASSWORD through t_run passes no
# matter what the function does. Running it in this shell, with a sentinel
# already in S5_PASSWORD, makes the post-condition real.
S5_PASSWORD='SENTINEL-NOT-A-REAL-PASSWORD'
S5_SECRET=''
feed 'short
'
s5_prompt_password <"$S5_TEST_ROOT/in" >"$S5_TEST_ROOT/pwout" 2>&1
pwstatus=$?
pwout=$(cat "$S5_TEST_ROOT/pwout")
assert_ne "invalid-then-EOF fails" 0 "$pwstatus"
assert_eq "a rejected flow does not adopt the invalid value" \
    'SENTINEL-NOT-A-REAL-PASSWORD' "$S5_PASSWORD"
assert_eq "the redaction secret is not armed with a rejected password" "" "$S5_SECRET"
assert_not_contains "rejection does not echo the candidate" "short" "$pwout"
rm -f "$S5_TEST_ROOT/pwout"
S5_PASSWORD='' 

# The secret must never be exported into the environment of a child process.
S5_PASSWORD='NeverExportMe1234'
leak=$(env | grep -c 'NeverExportMe1234' || true)
assert_eq "password is not exported to child processes" 0 "$leak"

# Assignment does not clear an inherited export attribute in POSIX shells. An
# invoking environment can pre-export each name that later carries credentials;
# simply overwriting it with an empty value at startup leaves every subsequent
# password assignment exported. Exercise a fresh shell because this property is
# fixed (or inherited) when socks5.sh is sourced.
cat >"$S5_TEST_ROOT/check-secret-exports.sh" <<'EXPORT_CHECK'
#!/bin/sh
export S5_PASSWORD=InheritedPassword123
export S5_SECRET=InheritedSecret123
export _vp=InheritedValidator123
export _pw1=InheritedPromptOne123
export _lcline=InheritedCredentialLine123
export _lcp=InheritedLoadedPassword123
export _stp=InheritedProbePassword123
export _isu=InheritedRenderedUsers123
export _scline=InheritedStaticLine123
export _scpass=InheritedStaticPassword123
export _tx_users_body=InheritedTransactionUsers123
export _tx_cfg_body=InheritedTransactionConfig123
S5_LIB_ONLY=1
export S5_LIB_ONLY
. "$S5_SRC"
S5_PASSWORD=FreshPassword123
S5_SECRET=FreshSecret123
_vp=FreshValidator123
_pw1=FreshPromptOne123
_lcline='freshuser:CL:FreshCredentialLine123'
_lcp=FreshLoadedPassword123
_stp=FreshProbePassword123
_isu='freshuser:CL:FreshRenderedUsers123'
_scline='freshuser:CL:FreshStaticLine123'
_scpass=FreshStaticPassword123
_tx_users_body='freshuser:CL:FreshTransactionUsers123'
_tx_cfg_body=FreshTransactionConfig123
env
EXPORT_CHECK
chmod 0700 "$S5_TEST_ROOT/check-secret-exports.sh"
t_run sh "$S5_TEST_ROOT/check-secret-exports.sh"
assert_eq "the inherited-export probe itself runs" 0 "$T_STATUS"
for secret_name in S5_PASSWORD S5_SECRET _vp _pw1 _lcline _lcp _stp \
    _isu _scline _scpass _tx_users_body _tx_cfg_body; do
    assert_not_contains "[$secret_name] has no inherited export attribute" \
        "$secret_name=" "$T_OUT"
done

# ...nor reach any stub's argv.
t_stub curl 0
t_assert_no_secret_in_argv "no secret in stub argv" 'NeverExportMe1234'
S5_PASSWORD=''

# --------------------------------------------------------------------------
# A generated credential must be exactly as long as the generator promised.
#
# s5_random_string draws through `tr -dc SET </dev/urandom | head -c N`. head
# exits 0 on short input and a pipeline reports only its last command's status,
# so a partial draw used to be indistinguishable from a full one: an unreadable
# /dev/urandom (a stripped container image, a /dev that was never populated)
# made tr fail into 2>/dev/null and the function returned an empty string with
# status 0. Nothing downstream noticed, because a 12-to-31-character password
# still satisfies s5_valid_password -- so the install completed while the
# operator was told a 32-character password had been generated, and
# s5_random_int collapsed to a constant 0, pinning every "random" port to
# S5_RANDPORT_MIN.
#
# The short draw is forced by shadowing `tr` with a shell function. A function
# takes precedence over both a PATH lookup and busybox's built-in applet, which
# a PATH stub cannot hide, so this behaves identically under sh, dash and
# busybox sh.
# --------------------------------------------------------------------------
t_run s5_random_string 24 "$S5_PASS_CHARSET"
assert_eq "an unhampered draw succeeds" 0 "$T_STATUS"
assert_eq "and returns exactly the number of characters asked for" 24 "${#T_OUT}"

tr() { printf 'abcd'; }        # four characters, whatever was requested
t_run s5_random_string 24 "$S5_PASS_CHARSET"
assert_ne "a short draw is refused, not returned" 0 "$T_STATUS"
assert_contains "and the shortfall is named" "got 4" "$T_OUT"

tr() { :; }                    # nothing at all: the unreadable-/dev/urandom shape
t_run s5_random_string 24 "$S5_PASS_CHARSET"
assert_ne "an empty draw is refused" 0 "$T_STATUS"
assert_contains "and reported as zero characters" "got 0" "$T_OUT"
assert_contains "and blamed on the entropy source" "/dev/urandom" "$T_OUT"

# Every caller must propagate that refusal instead of adopting a partial value.
tr() { printf 'abcd'; }
t_run s5_random_password
assert_ne "s5_random_password propagates a short draw" 0 "$T_STATUS"

# The username is two draws joined by printf. A command substitution discards
# the status of what ran inside it, so `printf '%s%s' "$(...)" "$(...)"` printed
# a short username and still reported success.
t_run s5_random_username
assert_ne "s5_random_username propagates a short draw" 0 "$T_STATUS"
assert_not_contains "and emits no partial username" "abcd" "$T_OUT"

tr() { :; }
t_run s5_random_int 40001
assert_ne "s5_random_int refuses rather than silently returning 0" 0 "$T_STATUS"
assert_contains "and names the failed draw" "could not draw" "$T_OUT"

t_run s5_random_port
assert_ne "s5_random_port refuses rather than always picking the lowest port" 0 "$T_STATUS"
assert_not_contains "and does not blame a port range it never sampled" \
    "after 50 attempts" "$T_OUT"
assert_not_contains "and never returns S5_RANDPORT_MIN" "$S5_RANDPORT_MIN" "$T_OUT"

# The prompts announce what they generated, so they must not announce anything
# they did not really produce. Run in this shell, not through t_run: t_run
# captures output in a command substitution, so no global it sets is observable
# afterwards and the post-conditions below would pass unconditionally.
tr() { printf 'abcd'; }
S5_USERNAME='SENTINEL-NOT-A-USERNAME'
feed '
'
s5_prompt_username <"$S5_TEST_ROOT/in" >"$S5_TEST_ROOT/genout" 2>&1
genstatus=$?
genout=$(cat "$S5_TEST_ROOT/genout")
assert_ne "the username prompt fails when the draw is short" 0 "$genstatus"
assert_not_contains "and announces no generated username" \
    "generated random username" "$genout"
assert_eq "and leaves no partial username behind" "" "$S5_USERNAME"

S5_PASSWORD='SENTINEL-NOT-A-REAL-PASSWORD'
S5_SECRET=''
feed '
'
s5_prompt_password <"$S5_TEST_ROOT/in" >"$S5_TEST_ROOT/genout" 2>&1
genstatus=$?
genout=$(cat "$S5_TEST_ROOT/genout")
assert_ne "the password prompt fails when the draw is short" 0 "$genstatus"
assert_not_contains "and does not claim a length it never produced" \
    "generated a random" "$genout"
assert_eq "and leaves no partial secret in S5_PASSWORD" "" "$S5_PASSWORD"
assert_eq "and does not arm the redaction secret" "" "$S5_SECRET"
rm -f "$S5_TEST_ROOT/genout"
unset -f tr

# With tr restored, the generators work again -- proof the block above failed
# because of the shadow and not because it broke something permanently.
t_run s5_random_password
assert_eq "the generator recovers once tr is restored" 0 "$T_STATUS"
assert_eq "and produces the full advertised length" "$S5_PASS_GEN_LEN" "${#T_OUT}"

t_summary
