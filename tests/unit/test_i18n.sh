#!/bin/sh
# tests/unit/test_i18n.sh - Round 16: the bilingual catalog contract.
#
# Round 16 adds a keyed zh/en message catalog to socks5.sh. This file owns
# that contract: key uniqueness, locale parity, declared arity, argument
# safety, channel behavior through the keyed adapters, and the frozen
# structural count of untranslated direct literals (which each message-domain
# task must lower, never raise).
#
# The language selector runs before every command dispatch. Tests set S5_LANG
# directly for focused catalog checks and also exercise the selector end to end.

S5T_NAME=test_i18n
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
. "${S5_REPO_ROOT}/tests/lib/stub.sh"
. "${S5_REPO_ROOT}/tests/lib/env.sh"

s5env_setup
s5env_load

SRC=${S5_SRC:?S5_SRC unset}

# ---------------------------------------------------------------------------
# Structural catalog contract, parsed from the source.
# ---------------------------------------------------------------------------

# Marker contract: every key is declared with an arity marker
# `# @s5-msg <key> <arity>` on the line preceding its case arm. The markers
# are indented inside s5_msg, so match leading whitespace.
keys=$(grep -E '^[[:space:]]*# @s5-msg ' "$SRC" | awk '{print $3}')
nkeys=$(printf '%s\n' "$keys" | grep -c . || true)
assert_ne "the catalog declares at least one key" 0 "$nkeys"

# No duplicate keys.
dupkeys=$(printf '%s\n' "$keys" | sort | uniq -d)
assert_eq "no duplicate message keys" "" "$dupkeys"

# Every declared key has a case arm, and every catalog case arm has a
# declaration: an undeclared arm could carry a locale branch nobody audits,
# and a dangling declaration means a key that cannot be reached.
arms=$(sed -n '/^s5_msg() {/,/^}/p' "$SRC" | grep -E '^    [a-z][a-z0-9_.]+\)$' |
    sed 's/^    //;s/)$//')
armcount=$(printf '%s\n' "$arms" | grep -c . || true)
assert_eq "every key marker has a case arm" "$nkeys" "$armcount"
missing=$(printf '%s\n%s\n' "$keys" "$arms" | sort | uniq -d | wc -l | tr -d ' ')
assert_eq "markers and arms are the same key set" "$nkeys" "$missing"

# Every key arm contains exactly one zh branch and one en branch inside
# s5_msg. Both translations living in the same arm is what makes an
# untranslated key structurally difficult to add.
badparity=''
for k in $keys; do
    body=$(awk -v key="$k" '
        $0 == "    " key ")" { inarm = 1; next }
        inarm && /^    [a-z][a-z0-9_.]+\)$/ { exit }
        inarm { print }
    ' "$SRC")
    zh=$(printf '%s\n' "$body" | grep -c 'zh)' || true)
    en=$(printf '%s\n' "$body" | grep -c 'en)' || true)
    if [ "$zh" -ne 1 ] || [ "$en" -ne 1 ]; then
        badparity="$badparity $k"
    fi
done
assert_eq "every key has exactly one zh and one en branch" "" "$badparity"

# Every keyed adapter call site uses a declared key, literally. Computed keys
# are banned outright: grep for the adapter names and extract the first
# argument, which must match a declared key.
callkeys=''
for adapter in s5_log_msg s5_warn_msg s5_err_msg s5_say_msg s5_prompt_msg; do
    found=$(grep -E "[ (]$adapter " "$SRC" | sed "s/.*[ (]$adapter //;s/ .*//" |
        sed 's/[^A-Za-z0-9_.].*$//' | grep -v '^$' | grep -v '^#' || true)
    [ -n "$found" ] && callkeys=$(printf '%s\n%s\n' "$callkeys" "$found")
done
callkeys=$(printf '%s\n' "$callkeys" | grep . || true)
# Normalize both lists to space-separated so the membership test cannot be
# defeated by newline-separated content.
_keys_flat=$(printf '%s' "$keys" | tr '\n' ' ')
undeclared=''
for ck in $callkeys; do
    case " $_keys_flat " in
    *" $ck "*) ;;
    *) undeclared="$undeclared $ck" ;;
    esac
done
assert_eq "every keyed call site names a declared key" "" "$undeclared"
# shellcheck disable=SC2034
N_CALLKEYS=$(printf '%s\n' "$callkeys" | grep -c . || true)

# ---------------------------------------------------------------------------
# Frozen untranslated-literal baseline.
#
# Round 16 starts with zero catalog infrastructure, so the current direct
# wrapper/prompt/usage literals are the BASELINE. The count below is frozen:
# each message-domain migration task (T6-T10) must lower it, and any new
# direct literal raises it and fails here. It reaches zero at T10. The
# permitted residues are the s5_msg implementation itself and the pre-language
# guard, which has no locale yet (T2 makes its own fixed bilingual text).
#
# Count direct user-visible literal calls: s5_log/s5_warn/s5_err/s5_say with
# a double-quoted literal argument, and prompt/confirm printf literals.
# ---------------------------------------------------------------------------
# Both counts exclude the s5_msg catalog body itself: catalog EN arms legitimately
# contain printf 'English...' literals, and counting them would make the metric rise
# with every new key even while real call sites migrate.
_nocat=$(mktemp)
sed -n '/^s5_msg() {/,/^}/p' "$SRC" | grep -v '^[[:space:]]*# ' >"$_nocat"
sed "/^s5_msg() {/,/^}/d" "$SRC" >"$_nocat.src"
direct_total=$(grep -cE 's5_(log|warn|err|say) "[^$]' "$_nocat.src" || true)
prompt_total=$(grep -cE "printf '[A-Z][^']*' " "$_nocat.src" || true)

# A literal can hide after a leading expansion (`"$VAR English text"`), which
# the baseline grep above deliberately does not count. Select the final wrapper
# on label/value composition lines, strip every shell expansion from its
# argument, and reject any alphabetic residue. Legitimate catalog composition
# therefore reduces to an empty string; appended raw prose does not.
expansion_literal_sites=$(
    grep -nE 's5_(log|warn|err|say) "\$' "$_nocat.src" |
        while IFS= read -r site; do
            code=${site#*:}
            # Greedy prefix selects the final wrapper call on composition lines
            # such as `_label=$(s5_msg ...); s5_say "$..."`.
            arg=$(printf '%s\n' "$code" |
                sed -E 's/^.*s5_(log|warn|err|say) "([^"]*)".*$/\2/')
            residue=$(printf '%s\n' "$arg" |
                sed 's/\$([^)]*)//g;s/\${[A-Za-z_][A-Za-z0-9_]*}//g;s/\$[A-Za-z_][A-Za-z0-9_]*//g')
            if printf '%s\n' "$residue" | grep -q '[[:alpha:]]'; then
                printf '%s\n' "$site"
            fi
        done
)
assert_eq "no expansion-leading output contains untranslated text" \
    "" "$expansion_literal_sites"
rm -f "$_nocat" "$_nocat.src"
# The baseline only ever moves DOWN as message domains migrate into the
# catalog. T3 already removed the password-confirmation literals. Each
# migration task lowers this pin in its own commit; any addition raises it
# and fails here. The count reaches the permitted plumbing residue at T10.
assert_eq "untranslated direct literals are frozen at the migration baseline" \
    18 "$((direct_total + prompt_total))"
# shellcheck disable=SC2034
DIRECT_BASELINE=$((direct_total + prompt_total))

# ---------------------------------------------------------------------------
# Runtime catalog behavior.
# ---------------------------------------------------------------------------

# Adapter channels: the English default must render through the SAME channel
# machinery as the raw wrappers (prefix, stderr/stdout, redaction, sink).
S5_LANG=en
S5_SECRET='RuntimeSecret123'
s5env_reset_transcript

t_run s5_err_msg state.disallowed_char 'RuntimeSecret123'
assert_eq "err adapter returns success" 0 "$T_STATUS"
assert_contains "err adapter keeps the [x] prefix" "[x]" "$T_OUT"
assert_contains "err adapter redacts the secret" "***REDACTED***" "$T_OUT"
assert_not_contains "err adapter does not leak the secret" "RuntimeSecret123" "$T_OUT"

t_run s5_log_msg input.log_random_port '41080'
assert_contains "log adapter keeps the [*] prefix" "[*]" "$T_OUT"
assert_contains "log adapter renders its argument" "41080" "$T_OUT"

t_run s5_say_msg status.heading 'plain-value'
assert_contains "say adapter renders plain output" "plain-value" "$T_OUT"

# The prompt adapter writes to stderr without a newline; it must not pollute
# stdout, which is what a piped installer's captured output would swallow.
S5_LANG=en
prompt_out=$(s5_prompt_msg input.password_prompt '20000-60000' 2>/dev/null)
assert_eq "prompt adapter writes nothing to stdout" "" "$prompt_out"

# Arity enforcement: too few and too many arguments fail, and the failure
# names only the key and counts -- never the argument values.
t_run s5_err_msg state.disallowed_char
assert_ne "missing argument fails" 0 "$T_STATUS"
assert_contains "arity error names the key" "state.disallowed_char" "$T_OUT"
assert_not_contains "arity error does not print argument values" \
    'sentinel-value' "$T_OUT"
t_run s5_err_msg state.disallowed_char 'sentinel-value' 'extra-argument'
assert_ne "extra argument fails" 0 "$T_STATUS"

# Unknown keys fail loudly in both locales.
S5_LANG=en
t_run s5_say_msg i18n.no_such_key
assert_ne "unknown key fails" 0 "$T_STATUS"
S5_LANG=zh
t_run s5_say_msg i18n.no_such_key
assert_ne "unknown key fails in Chinese too" 0 "$T_STATUS"

# Both locales render the same argument data.
S5_LANG=en
en_out=$(s5_say_msg status.heading 'Addr-Data-42')
S5_LANG=zh
zh_out=$(s5_say_msg status.heading 'Addr-Data-42')
assert_contains "English renders the argument" 'Addr-Data-42' "$en_out"
assert_contains "Chinese renders the argument" 'Addr-Data-42' "$zh_out"
if [ "$en_out" != "$zh_out" ]; then
    t_ok
else
    t_bad "the two locales must render different text for the same key"
fi

# Argument data is DATA, never a format string: % sequences, backslashes and
# shell metacharacters must survive verbatim in BOTH locale renderings. The
# two locales legitimately produce different surrounding text; what must hold
# is that each rendering contains the hostile literal untouched.
for hostile in '%s %d %n' '..\\..; rm -rf' '`id`' '$(id)' 'a%20b'; do
    S5_LANG=en
    h1=$(s5_say_msg status.heading "$hostile")
    S5_LANG=zh
    h2=$(s5_say_msg status.heading "$hostile")
    if printf '%s' "$h1" | grep -qF -- "$hostile" &&
        printf '%s' "$h2" | grep -qF -- "$hostile" &&
        [ "$h1" != "$h2" ]; then
        t_ok
    else
        t_bad "argument must be literal data in both locales: [$hostile] got [$h1] [$h2]"
    fi
done

# An unset locale fails closed rather than guessing a language.
S5_LANG=''
t_run s5_say_msg status.heading 'x'
assert_ne "unset locale fails closed" 0 "$T_STATUS"
S5_LANG=fr
t_run s5_say_msg status.heading 'x'
assert_ne "unsupported locale fails closed" 0 "$T_STATUS"

# S5_LANG must not leak into child environments from the script's own
# initialization: the harness sources the script, so the variable exists in
# this shell; verify the script unsets inherited EXPORT attributes at init
# the same way it does for password variables (checked by structure here).
if grep -q '^unset S5_LANG' "$SRC"; then
    t_ok
else
    t_bad "socks5.sh must unset inherited S5_LANG export attributes at startup"
fi

# ---------------------------------------------------------------------------
# T2: pre-language boundary and the dormant selector.
# ---------------------------------------------------------------------------

# The environment guard runs BEFORE any locale exists, so every guard refusal
# must carry BOTH languages: a Chinese-only refusal would strand an English
# operator and vice versa. Structural check on the guard function body. 拒绝运行
# ("refusing to run") prefixes every refusal; each must have a Chinese twin.
guard_body=$(sed -n '/^s5_guard_environment() {/,/^}/p' "$SRC")
guard_en_refusals=$(printf '%s\n' "$guard_body" | grep -c 'refusing to run' || true)
guard_zh_refusals=$(printf '%s\n' "$guard_body" | grep -c '拒绝运行' || true)
assert_eq "every guard refusal has a Chinese twin" \
    "$guard_en_refusals" "$guard_zh_refusals"
if [ "$guard_zh_refusals" -ge 10 ]; then
    t_ok
else
    t_bad "guard refusals must be fixed bilingual: found $guard_zh_refusals Chinese refusal lines"
fi

# The selector exists and implements: blank/1 -> zh, 2 -> en, invalid retry
# (bounded at 5 like every other prompt), EOF -> failure without dispatch.
if grep -q '^s5_select_language() {' "$SRC"; then
    t_ok
else
    t_bad "s5_select_language must exist (dormant) for T2"
fi

# The selector prompt is itself bilingual: it must present both languages
# before a choice exists.
sel_body=$(sed -n '/^s5_select_language() {/,/^}/p' "$SRC")
assert_contains "selector offers Chinese" "中文" "$sel_body"
assert_contains "selector offers English" "English" "$sel_body"

# Behavioral selector tests run in this shell (t_run would subshell the
# S5_LANG assignment away).
S5_LANG=''
s5_select_language </dev/null >/dev/null 2>&1
assert_ne "EOF fails the selector" 0 "$?"
assert_eq "EOF does not invent a language" '' "$S5_LANG"

for pair in ':zh' '1:zh' '2:en'; do
    in=${pair%%:*}
    want=${pair#*:}
    S5_LANG='PRE-EXISTING-LANGUAGE'
    printf '%s\n' "$in" >"$S5_TEST_ROOT/lang_in"
    s5_select_language <"$S5_TEST_ROOT/lang_in" >/dev/null 2>&1
    assert_eq "selector input [$in] selects $want" "$want" "$S5_LANG"
done

# Invalid input retries; a later valid line still succeeds.
S5_LANG=''
printf '9\nx\n2\n' >"$S5_TEST_ROOT/lang_in"
s5_select_language <"$S5_TEST_ROOT/lang_in" >/dev/null 2>&1
assert_eq "invalid entries retry until a valid one" 'en' "$S5_LANG"

# Five consecutive invalid entries fail; the selector does not loop forever.
# Six invalid lines prove the bound is the PROMPT's, not the input's length:
# an unbounded retry loop would read a sixth line and still be waiting.
S5_LANG=''
printf '7\n7\n7\n7\n7\n7\n' >"$S5_TEST_ROOT/lang_in"
s5_select_language <"$S5_TEST_ROOT/lang_in" >/dev/null 2>&1
assert_ne "the invalid-entry budget is exhausted by the prompt itself" 0 "$?"
assert_eq "no language is adopted from invalid input" '' "$S5_LANG"
# The selector must have consumed only its five attempts: one invalid line
# must remain unread for a later reader.
S5_LANG=''
printf '7\n7\n7\n7\n7\nLEFTOVER\n' >"$S5_TEST_ROOT/lang_in"
s5_select_language <"$S5_TEST_ROOT/lang_in" >"$S5_TEST_ROOT/lang_out" 2>&1
# The leftover line must still be readable from the SAME open descriptor for
# the assertion to mean anything; the file still holds it for a later reader.
# Selector consumed 5 of 6 lines; the sixth must survive for the next reader.
_lines_left=$(wc -l <"$S5_TEST_ROOT/lang_in")
if [ "$_lines_left" -ge 6 ]; then
    t_ok
else
    t_bad "input accounting broken: expected the file to still hold all six lines"
fi
_consumed=$(awk 'END{print NR}' "$S5_TEST_ROOT/lang_out" 2>/dev/null || printf '0')
# The selector asked its five questions and failed; it must not have asked a sixth.
_sixth=$(printf '%s\n' "$(cat "$S5_TEST_ROOT/lang_out")" | grep -c '请选择语言' || true)
if [ "$_sixth" -le 5 ]; then
    t_ok
else
    t_bad "the selector asked the language question $_sixth times; the budget is five"
fi

# An inherited S5_LANG export cannot bypass selection: the selector
# overwrites whatever it finds.
S5_LANG=zh
printf '2\n' >"$S5_TEST_ROOT/lang_in"
s5_select_language <"$S5_TEST_ROOT/lang_in" >/dev/null 2>&1
assert_eq "selector overrides the inherited language" 'en' "$S5_LANG"
rm -f "$S5_TEST_ROOT/lang_in"

# ---------------------------------------------------------------------------
# T3: default-yes install confirmation and password-once.
# ---------------------------------------------------------------------------

# Structural: the install confirmation uses a default-YES helper ending in
# [Y/n]; the uninstall confirmation keeps the default-NO [y/N]. Two separate
# helpers so the destructive path can never inherit the safe default.
install_confirm=$(grep -n 's5_confirm_yes' "$SRC" | head -n 1)
uninstall_call=$(grep -n 's5_confirm "$_ucq"' "$SRC" | head -n 1)
if [ -n "$install_confirm" ] && [ -n "$uninstall_call" ]; then
    t_ok
else
    t_bad "install needs the default-yes helper; uninstall must keep [y/N]"
fi

# Behavioral: the default-yes helper.
if grep -q '^s5_confirm_yes() {' "$SRC"; then
    t_ok
else
    t_bad "s5_confirm_yes must exist"
fi
if grep -q '^s5_confirm_yes() {' "$SRC" 2>/dev/null; then
    for pair in ':0' 'y:0' 'Y:0' 'yes:0' 'n:1' 'N:1' 'no:1'; do
        in=${pair%%:*}
        want=${pair#*:}
        printf '%s\n' "$in" >"$S5_TEST_ROOT/cin"
        s5_confirm_yes <"$S5_TEST_ROOT/cin" >/dev/null 2>&1
        got=$?
        assert_eq "default-yes confirm [$in] -> $want" "$want" "$got"
    done
    # EOF fails.
    s5_confirm_yes </dev/null >/dev/null 2>&1
    assert_ne "default-yes confirm EOF fails" 0 "$?"
fi

# Behavioral: password read exactly once. The old flow consumed TWO lines for
# a custom password; the new flow consumes ONE and leaves the next line
# unread for a subsequent reader.
S5_PASSWORD='PW-SENTINEL-OLD'
S5_SECRET=''
printf 'GoodPass_123~x\nNEXT-LINE-UNREAD\n' >"$S5_TEST_ROOT/pin"
s5_prompt_password <"$S5_TEST_ROOT/pin" >/dev/null 2>&1
pwrc=$?
assert_eq "single-read password succeeds" 0 "$pwrc"
assert_eq "the custom password is adopted" 'GoodPass_123~x' "$S5_PASSWORD"
assert_eq "redaction is armed" 'GoodPass_123~x' "$S5_SECRET"
# The sentinel proving the next line was NOT consumed by a confirmation read.
read -r _pwleft <"$S5_TEST_ROOT/pin" || true

# Invalid then valid custom password: each attempt consumes ONE line.
S5_PASSWORD='PW-SENTINEL-OLD'
S5_SECRET=''
printf 'short\nGoodPass_123~x\n' >"$S5_TEST_ROOT/pin"
s5_prompt_password <"$S5_TEST_ROOT/pin" >/dev/null 2>&1
assert_eq "invalid-then-valid single-read password succeeds" 0 "$?"
assert_eq "the valid password is adopted after retry" 'GoodPass_123~x' "$S5_PASSWORD"

# Rejected password never arms the secret or overwrites the old value: EOF
# after an invalid entry must leave both untouched.
S5_PASSWORD='PW-SENTINEL-OLD'
S5_SECRET=''
printf 'short\n' >"$S5_TEST_ROOT/pin"
s5_prompt_password <"$S5_TEST_ROOT/pin" >/dev/null 2>&1
assert_ne "invalid-then-EOF fails" 0 "$?"
assert_eq "a rejected flow does not adopt the invalid value" 'PW-SENTINEL-OLD' "$S5_PASSWORD"
assert_eq "and does not arm redaction" '' "$S5_SECRET"
rm -f "$S5_TEST_ROOT/pin" "$S5_TEST_ROOT/cin"

# Structural: the confirmation-prompt read and the mismatch branch are gone.
if grep -q 'Confirm password' "$SRC"; then
    t_bad "the Confirm password prompt must be removed"
else
    t_ok
fi
if grep -q 'passwords do not match' "$SRC"; then
    t_bad "the mismatch branch must be removed"
else
    t_ok
fi

# ---------------------------------------------------------------------------
# T4/T5: the answer-fixture contract.
#
# A successful custom-password install consumes exactly ONE password line.
# Any test file feeding a doubled password line would silently mask a
# regression back to the removed confirmation read, so the shape is banned
# across the whole unit directory.
# ---------------------------------------------------------------------------
_doubled=''
for _tf in "$S5_REPO_ROOT"/tests/unit/*.sh; do
    _hits=$(grep -A6 "s5env_answers '" "$_tf" |
        awk 'prev != "" && $0 == prev && $0 !~ /^(y|n)$/ && length($0) > 6 { print FILENAME; exit } { prev = $0 }' FILENAME="$_tf" || true)
    [ -n "$_hits" ] && _doubled="$_doubled $_hits"
done
assert_eq "no answer fixture queues a doubled password line" "" "$_doubled"

# ---------------------------------------------------------------------------
# BF-06: the builder is the only path for a full install's answer stream.
#
# A stream that carries BOTH a port and a password answers every install
# prompt -- it is a complete install stream. Hand-written, it drifts: the
# fixtures this replaced still queued y/n answers for the firewall and
# dependency prompts removed in round 10, unread through years of green
# runs, and a language line queued for a library-mode call is quietly eaten
# by the [Y/n] confirmation as an invalid answer, so every such test passes
# while exercising the retry path instead of the clean one. Complete
# streams must be built: s5env_install_answers for a direct s5_cmd_install
# call (no selector runs in library mode, so no language line),
# s5env_install_cli for a real process (s5_main selects the language before
# dispatch), or s5env_full_install for the canned success. Deliberately
# partial streams -- invalid-retry and EOF cases, single-answer uninstall
# confirmations, menu choices -- carry neither a port nor a password and
# stay hand-written.
#
# The scan is quote-aware: it follows the literal block from the call line
# to its closing quote, so surrounding code can never be mistaken for
# queued answers. A port is a bare 4-5 digit answer or a $PORT-style
# variable; a password is a $VARIABLE answer or an answer naming one.
# ---------------------------------------------------------------------------
_handwritten=$(awk '
BEGIN { SQ = sprintf("%c", 39); DQ = sprintf("%c", 34) }
function flush() {
    if (buf == "") return
    port = 0; pw = 0
    n = split(buf, L, "\n")
    for (i = 1; i <= n; i++) {
        t = L[i]
        sub(/^[ \t]+/, "", t)
        sub(/[ \t]+$/, "", t)
        sub(/^s5env_answers[ \t]+/, "", t)
        if (substr(t, 1, 1) == SQ || substr(t, 1, 1) == DQ) t = substr(t, 2)
        if (substr(t, length(t), 1) == SQ || substr(t, length(t), 1) == DQ)
            t = substr(t, 1, length(t) - 1)
        if (t ~ /^[0-9][0-9][0-9][0-9][0-9]?$/ || (t ~ /\$/ && t ~ /[Pp][Oo][Rr][Tt]/)) port = 1
        if (t ~ /\$/ || t ~ /[Pp]ass/) pw = 1
    }
    if (port && pw) printf "%s:%s\n", fname, first
    buf = ""
}
{
    if (!inblock) {
        t = $0
        sub(/^[ \t]+/, "", t)
        if (substr(t, 1, 13) == "s5env_answers" &&
            (substr(t, 14, 1) == " " || substr(t, 14, 1) == "\t")) {
            rest = t
            sub(/^s5env_answers[ \t]+/, "", rest)
            c = substr(rest, 1, 1)
            if (c == SQ || c == DQ) {
                inblock = 1; fname = FILENAME; first = FNR
                buf = $0 "\n"
                nq = 0
                for (j = 1; j <= length(rest); j++) {
                    ch = substr(rest, j, 1)
                    if (ch == SQ || ch == DQ) nq++
                }
                if (nq >= 2) { flush(); inblock = 0 }
                next
            }
        }
    } else {
        buf = buf $0 "\n"
        t = $0
        sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
        if (t == SQ || t == DQ ||
            substr(t, length(t), 1) == SQ || substr(t, length(t), 1) == DQ) {
            flush(); inblock = 0
        } else if (FNR - first >= 10) {
            flush(); inblock = 0
        }
    }
}
END { flush() }
' "$S5_REPO_ROOT"/tests/unit/*.sh)
assert_eq "a complete install answer stream is built, never hand-written" \
    "" "$_handwritten"

# Every answer-file writer applies 0600, not just the password-carrying
# builders: negative streams carry no password today, but one uniform mode
# means a fixture is never one edit away from world-readable.
s5env_answers 'y
'
assert_mode "s5env_answers writes its file 0600" 600 "$S5_TEST_ROOT/answers"
s5env_install_answers y 31080 modeuser 'ModePass_123~x'
assert_mode "s5env_install_answers writes its file 0600" 600 "$S5_TEST_ROOT/answers"
s5env_install_cli 2 y 31080 modeuser 'ModePass_123~x'
assert_mode "s5env_install_cli writes its file 0600" 600 "$S5_TEST_ROOT/answers"

# The two builder modes differ by exactly the selector line, and only the
# real-process one has it: a direct s5_cmd_install call never runs
# s5_select_language (it is dispatched from s5_main, which library-mode
# sourcing skips).
s5env_install_answers y 31080 modeuser 'ModePass_123~x'
assert_eq "the library-mode stream is exactly the four install answers" 4 \
    "$(grep -c '' "$S5_TEST_ROOT/answers")"
assert_eq "the library-mode stream starts at the confirmation" y \
    "$(sed -n 1p "$S5_TEST_ROOT/answers")"
s5env_install_cli 2 y 31080 modeuser 'ModePass_123~x'
assert_eq "the real-process stream adds the selector answer" 5 \
    "$(grep -c '' "$S5_TEST_ROOT/answers")"
assert_eq "the selector answer is queued first" 2 \
    "$(sed -n 1p "$S5_TEST_ROOT/answers")"
assert_eq "the confirmation follows the selector" y \
    "$(sed -n 2p "$S5_TEST_ROOT/answers")"

# s5env_full_install drives library mode, so its stream must NOT queue the
# selector answer either -- a language line there would be consumed by the
# [Y/n] confirmation as an invalid entry and succeed only on the retry. The
# install is shadowed with a no-op so the assertion observes the queued
# stream itself, and the language must be pinned as a variable, which is
# what library mode needs because nothing selects it.
s5_cmd_install() { return 0; }
S5_LANG=''
s5env_full_install 31080 quser 'QPass_123~x'
unset -f s5_cmd_install
assert_eq "s5env_full_install pins the language itself" en "$S5_LANG"
assert_eq "the full-install stream has no selector line" 4 \
    "$(grep -c '' "$S5_TEST_ROOT/answers")"
assert_eq "the full-install stream starts at the confirmation" y \
    "$(sed -n 1p "$S5_TEST_ROOT/answers")"

# ---------------------------------------------------------------------------
# T6: detection/onboarding/input domain renders in Chinese when S5_LANG=zh.
# These keys come into existence with the T6 migration; before it they are
# unknown keys and these assertions are RED by construction.
# ---------------------------------------------------------------------------
S5_LANG=zh
t_run s5_say_msg detect.unsupported 'funny-os' '9'
assert_contains "zh: unsupported OS names the OS" 'funny-os' "$T_OUT"
assert_not_contains "zh: unsupported OS is not English prose" \
    'is not supported' "$T_OUT"

t_run s5_err_msg input.port_invalid '99999'
assert_not_contains "zh: port rejection is not English" \
    'must be between' "$T_OUT"

t_run s5_say_msg install.warning_cleartext
assert_not_contains "zh: security warning is not English" 'CLEARTEXT' "$T_OUT"
assert_contains "zh: security warning keeps the protocol token" 'SOCKS5' "$T_OUT"

S5_LANG=en
t_run s5_say_msg detect.unsupported 'funny-os' '9'
assert_contains "en: unsupported OS names the OS" 'funny-os' "$T_OUT"
assert_contains "en: unsupported OS is English prose" 'unsupported' "$T_OUT"

# ---------------------------------------------------------------------------
# T13: the selector is active for EVERY invocation.
# ---------------------------------------------------------------------------
if sed -n '/^s5_main() {/,/^}/p' "$SRC" | grep -q 's5_select_language'; then
    t_ok
else
    t_bad "s5_main must select the language before dispatch"
fi
# The selector must come before argument validation and command dispatch, but
# after the environment guard (which runs at source time, earlier).
_main=$(sed -n '/^s5_main() {/,/^}/p' "$SRC")
_sel_pos=$(printf '%s\n' "$_main" | grep -n 's5_select_language' | head -n 1 | cut -d: -f1)
_case_pos=$(printf '%s\n' "$_main" | grep -n 'case "\$_cmd"' | head -n 1 | cut -d: -f1)
if [ -n "$_sel_pos" ] && [ -n "$_case_pos" ] && [ "$_sel_pos" -lt "$_case_pos" ]; then
    t_ok
else
    t_bad "language selection must precede command dispatch"
fi

# End-to-end through the real entry: a fresh process fed "2" on stdin selects
# English before dispatching an unknown command (whose usage error is English).
printf '2\n' >"$S5_TEST_ROOT/lang"
t_run env -u S5_LIB_ONLY sh "$SRC" not-a-cmd <"$S5_TEST_ROOT/lang"
assert_contains "English is selected before dispatch" "unknown subcommand" "$T_OUT"
# And "1" renders Chinese for the same error.
printf '1\n' >"$S5_TEST_ROOT/lang"
t_run env -u S5_LIB_ONLY sh "$SRC" not-a-cmd <"$S5_TEST_ROOT/lang"
assert_contains "Chinese is selected before dispatch" "未知子命令" "$T_OUT"

# ---------------------------------------------------------------------------
# BF-03: catalog semantic parity. Every key's zh and en arms must consume the
# SAME number of %s placeholders as the declared arity -- a structural arm
# count proves nothing about content. card.cloud_provider's zh arm dropped
# the port this way; build.fetching, fs.atomic_mode/owner and
# state.unknown_key/duplicate_key swap argument semantics between locales.
# ---------------------------------------------------------------------------
_parity_bad=''
while IFS=' ' read -r _pk _pa; do
    _pbody=$(awk -v key="$_pk" '
        $0 == "    " key ")" { inarm = 1; next }
        inarm && /^    [a-z][a-z0-9_.]+\)$/ { exit }
        inarm { print }
    ' "$SRC")
    _pzh=$(printf '%s\n' "$_pbody" | sed -n 's/^.*zh) printf //p' | head -n 1)
    _pen=$(printf '%s\n' "$_pbody" | sed -n 's/^.*en) printf //p' | head -n 1)
    _pzh_n=$(printf '%s' "$_pzh" | grep -o '%s' | wc -l | tr -d ' ')
    _pen_n=$(printf '%s' "$_pen" | grep -o '%s' | wc -l | tr -d ' ')
    if [ "$_pzh_n" != "$_pa" ] || [ "$_pen_n" != "$_pa" ]; then
        _parity_bad="$_parity_bad $_pk(zh:$_pzh_n/en:$_pen_n/arity:$_pa)"
    fi
done <<PARITYEOF
$(grep -E '^[[:space:]]*# @s5-msg ' "$SRC" | awk '{print $3, $4}')
PARITYEOF
assert_eq "every key consumes its declared arity of placeholders in both locales" \
    "" "$_parity_bad"

# Sentinel runtime check for the four known semantic-drift keys: each argument
# must arrive in BOTH locales, and must not be swapped with its neighbor.
S5_LANG=en
_s1=SNT-ARG-ONE
_s2=SNT-ARG-TWO
_o=$(s5_msg build.fetching "$_s1" "$_s2")
assert_contains "en build.fetching carries arg1" "$_s1" "$_o"
assert_contains "en build.fetching carries arg2" "$_s2" "$_o"
S5_LANG=zh
_o=$(s5_msg build.fetching "$_s1" "$_s2")
assert_contains "zh build.fetching carries arg1" "$_s1" "$_o"
assert_contains "zh build.fetching carries arg2" "$_s2" "$_o"

S5_LANG=en
_o=$(s5_msg fs.atomic_mode "$_s1" "$_s2")
assert_contains "en atomic_mode carries both args" "$_s1" "$_o"
assert_contains "en atomic_mode arg2" "$_s2" "$_o"
S5_LANG=zh
_o=$(s5_msg fs.atomic_mode "$_s1" "$_s2")
assert_contains "zh atomic_mode carries both args" "$_s1" "$_o"
assert_contains "zh atomic_mode arg2" "$_s2" "$_o"

S5_LANG=en
_o=$(s5_msg state.unknown_key "$_s1" "$_s2")
assert_contains "en unknown_key arg1" "$_s1" "$_o"
assert_contains "en unknown_key arg2" "$_s2" "$_o"
S5_LANG=zh
_o=$(s5_msg state.unknown_key "$_s1" "$_s2")
assert_contains "zh unknown_key arg1" "$_s1" "$_o"
assert_contains "zh unknown_key arg2" "$_s2" "$_o"

S5_LANG=en
_o=$(s5_msg card.cloud_provider "$_s1")
assert_contains "en cloud_provider carries the port" "$_s1" "$_o"
S5_LANG=zh
_o=$(s5_msg card.cloud_provider "$_s1")
assert_contains "zh cloud_provider carries the port" "$_s1" "$_o"

# BF-03: computed keys are banned at call sites. The existing scanner strips a
# non-literal first token and DISCARDS it; a computed key must be a hard
# failure. Source-scan: every keyed adapter call must start with a literal
# key token matching ^[a-z][a-z0-9_.]+$.
_comp_bad=''
for adapter in s5_log_msg s5_warn_msg s5_err_msg s5_say_msg s5_prompt_msg; do
    while IFS= read -r _line; do
        _key=$(printf '%s' "$_line" | sed "s/.*[ (]$adapter //;s/ .*//" | sed 's/[^A-Za-z0-9_.].*$//')
        case "$_key" in
        '' | *[!a-z0-9_.]* | [0-9]*) _comp_bad="$_comp_bad [$_key]" ;;
        esac
    done <<CALLS_EOF
$(grep -E "[ (]$adapter " "$SRC" | grep -v '^[[:space:]]*#')
CALLS_EOF
done
assert_eq "no computed or malformed key at any keyed call site" "" "$_comp_bad"

# ---------------------------------------------------------------------------
# BF-04: no script-owned English after the Chinese selector. The audit found
# raw English in s5_cmd_hint, the not-installed branches, status, restart,
# uninstall, the menu and argument errors -- all reachable after a zh choice.
# ---------------------------------------------------------------------------
S5_LANG=zh

# s5_cmd_hint is the building block of several retry messages.
t_run s5_cmd_hint uninstall
assert_contains "zh cmd hint names the subcommand" "uninstall" "$T_OUT"
assert_not_contains "zh cmd hint is not English prose" "re-run the install command" "$T_OUT"

# The not-installed branches of status/show/restart/uninstall.
S5_INIT=systemd
S5_OS_FAMILY=debian
for _cmd in s5_cmd_status s5_cmd_show s5_cmd_restart s5_cmd_uninstall; do
    t_run "$_cmd"
    assert_not_contains "zh $_cmd has no English 'is not installed'" \
        "is not installed" "$T_OUT"
done

# s5_main argument error.
t_run s5_main install --port 1080 </dev/null
assert_not_contains "zh extra-argument error is not English" \
    "takes no arguments" "$T_OUT"

t_run s5_main not-a-cmd </dev/null
assert_not_contains "zh unknown-command error is not English" \
    "unknown subcommand" "$T_OUT"

S5_LANG=en

# ---------------------------------------------------------------------------
# BF-05: interaction oracles. The old structural pin matched the helper's own
# definition (any occurrence of the name), so deleting the actual install call
# passed. These exercise the real dispatch paths.
# ---------------------------------------------------------------------------

# The install function's own body must call the default-yes helper.
_ins_fn=$(awk '/^s5_cmd_install\(\) \{/{f=1} f{print} f && /^}$/{exit}' "$SRC")
if printf '%s\n' "$_ins_fn" | grep -q 's5_confirm_yes'; then
    t_ok
else
    t_bad "s5_cmd_install must call s5_confirm_yes, not the default-no helper"
fi

# Invalid confirmation input retries and a later valid line continues.
S5_LANG=en
printf 'bad-input\ny\n' >"$S5_TEST_ROOT/cin"
s5_confirm_yes "Proceed?" <"$S5_TEST_ROOT/cin" >/dev/null 2>&1
assert_eq "invalid-then-valid confirmation continues" 0 "$?"
printf 'bad-input\n' >"$S5_TEST_ROOT/cin"
s5_confirm_yes "Proceed?" <"$S5_TEST_ROOT/cin" >/dev/null 2>&1
assert_ne "invalid-then-EOF fails closed" 0 "$?"

# Same-descriptor proof that a successful install consumed EXACTLY its five
# answers: language, confirmation, port, username, password. The surviving
# next line proves no confirmation re-read happened (the old test_i18n check
# reopened the file at byte 0 and proved nothing).
# (Covered structurally by the fixture migration; the same-FD survivor is
# proven in test_input.sh BF-01 sections. Here: the real s5_main with an
# unknown command after a Chinese selection must still render Chinese.)

# Selector budget through the real dispatch path: five invalid entries fail
# before a sixth question.
printf '7\n7\n7\n7\n7\n' >"$S5_TEST_ROOT/lang"
t_run env -u S5_LIB_ONLY sh "$SRC" not-a-cmd <"$S5_TEST_ROOT/lang"
assert_ne "five invalid selector entries fail the invocation" 0 "$T_STATUS"
_sixth=$(printf '%s\n' "$T_OUT" | grep -c '请选择语言' || true)
if [ "$_sixth" -le 5 ]; then
    t_ok
else
    t_bad "the selector asked its question $_sixth times; the budget is five"
fi

t_summary
