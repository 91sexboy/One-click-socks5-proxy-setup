#!/bin/sh
# tests/unit/test_skeleton.sh - Task 1: skeleton, POSIX constraints, test-mode isolation.

S5T_NAME=test_skeleton
. "${S5_REPO_ROOT}/tests/lib/assert.sh"

SRC=${S5_SRC:?S5_SRC unset}

# --- the script exists and is syntactically valid in all three target shells ---
assert_file_exists "socks5.sh exists" "$SRC"

t_run sh -n "$SRC"
assert_eq "sh -n clean" 0 "$T_STATUS"

if command -v dash >/dev/null 2>&1; then
    t_run dash -n "$SRC"
    assert_eq "dash -n clean" 0 "$T_STATUS"
fi

if command -v busybox >/dev/null 2>&1; then
    t_run busybox sh -n "$SRC"
    assert_eq "busybox sh -n clean" 0 "$T_STATUS"
fi

# --- no bashisms and no eval (comment lines are not code, so they are excluded) ---
check_absent() {
    if grep -v '^[[:space:]]*#' "$SRC" | grep -Eq -e "$2"; then
        t_bad "banned construct present: $1"
    else
        t_ok
    fi
}
# `[[` as a command, not the POSIX class `[[:alpha:]]`
check_absent "double-bracket test" '\[\[([^:]|$)'
check_absent "bash equality in test" '\[ *"[^"]*" *== '
check_absent "function keyword" '^ *function '
check_absent "source builtin" '^ *source '
# ANSI-C quoting is $'...' at the start of a word; a regex anchor such as
# '^log$' also yields the two characters $' and must not be flagged.
check_absent "ANSI-C quoting" "(^|[[:space:]]|=)\\\$'"
check_absent "echo -e" 'echo -e'
check_absent "process substitution" '<\('
check_absent "/dev/tcp" '/dev/tcp'
check_absent "bash array append" '\+=\('
check_absent "indirect expansion" '\$\{!'
check_absent "eval" '(^|[[:space:];&|(])eval[[:space:]]'
# `\|` is GNU/busybox alternation inside a *basic* regular expression, which
# POSIX does not define. A strict POSIX grep matches such a pattern literally,
# so a security check written that way silently stops matching and fails OPEN.
# Alternation must be written as an ERE with grep -E.
check_absent "BRE alternation" '\\\|'

# --- unknown subcommand is a usage error ---
t_run env -u S5_TEST_MODE -u S5_TEST_ROOT sh "$SRC" definitely-not-a-subcommand
assert_eq "unknown subcommand exits 64" 64 "$T_STATUS"
assert_contains "unknown subcommand prints usage" "Usage" "$T_OUT"

# --- production mode refuses any coverage/override variable (fail-closed) ---
t_run env -u S5_TEST_MODE S5_TEST_ROOT=/tmp/nope sh "$SRC" status
assert_eq "production + S5_TEST_ROOT exits 2" 2 "$T_STATUS"
assert_contains "explains the refusal" "test-mode variable" "$T_OUT"

t_run env -u S5_TEST_MODE S5_LIB_ONLY=1 sh "$SRC" status
assert_eq "production + S5_LIB_ONLY exits 2" 2 "$T_STATUS"

t_run env -u S5_TEST_MODE S5_PREFIX=/tmp/nope sh "$SRC" status
assert_eq "production + S5_PREFIX exits 2" 2 "$T_STATUS"

t_run env S5_TEST_MODE=yes sh "$SRC" status
assert_eq "S5_TEST_MODE with a non 0/1 value exits 2" 2 "$T_STATUS"

# --- test mode demands S5_TEST_ROOT and the sentinel ---
t_run env -u S5_TEST_ROOT S5_TEST_MODE=1 sh "$SRC" status
assert_eq "test mode without S5_TEST_ROOT exits 2" 2 "$T_STATUS"
assert_contains "names the missing root" "S5_TEST_ROOT" "$T_OUT"

NO_SENTINEL=$(mktemp -d "${TMPDIR:-/tmp}/s5nosentinel.XXXXXX")
t_run env S5_TEST_MODE=1 S5_TEST_ROOT="$NO_SENTINEL" sh "$SRC" status
assert_eq "test root without sentinel exits 2" 2 "$T_STATUS"
assert_contains "names the sentinel" ".s5-test-root" "$T_OUT"
rmdir "$NO_SENTINEL" 2>/dev/null || rm -rf "$NO_SENTINEL"

# A sentinel reached through a symlink is not an isolated root: the lexical
# path names one directory while filesystem resolution reaches another.
# This must be rejected before the guard accepts the sentinel.
SYMLINK_TARGET=$(mktemp -d "${TMPDIR:-/tmp}/s5symlink-target.XXXXXX")
SYMLINK_PARENT=$(mktemp -d "${TMPDIR:-/tmp}/s5symlink-parent.XXXXXX")
: >"$SYMLINK_TARGET/.s5-test-root"
ln -s "$SYMLINK_TARGET" "$SYMLINK_PARENT/root-link"
t_run env S5_TEST_MODE=1 S5_TEST_ROOT="$SYMLINK_PARENT/root-link" sh "$SRC" status
assert_eq "symlinked test root exits 2" 2 "$T_STATUS"
assert_contains "names the invalid symlinked root" "S5_TEST_ROOT" "$T_OUT"
rm -rf "$SYMLINK_PARENT" "$SYMLINK_TARGET"

# A non-symlink root beneath a symlinked parent is also outside the lexical
# boundary supplied by the harness and must be refused.
ROOT_TARGET=$(mktemp -d "${TMPDIR:-/tmp}/s5root-target.XXXXXX")
ROOT_PARENT=$(mktemp -d "${TMPDIR:-/tmp}/s5root-parent.XXXXXX")
mkdir "$ROOT_TARGET/root"
: >"$ROOT_TARGET/root/.s5-test-root"
ln -s "$ROOT_TARGET" "$ROOT_PARENT/parent-link"
t_run env S5_TEST_MODE=1 S5_TEST_ROOT="$ROOT_PARENT/parent-link/root" sh "$SRC" status
assert_eq "test root below a symlinked parent exits 2" 2 "$T_STATUS"
assert_contains "names the unsafe parent root" "S5_TEST_ROOT" "$T_OUT"
rm -rf "$ROOT_PARENT" "$ROOT_TARGET"

# Parent traversal in the root itself is rejected even when it resolves to a
# directory containing the sentinel.
TRAVERSAL_TARGET=$(mktemp -d "${TMPDIR:-/tmp}/s5root-traversal.XXXXXX")
: >"$TRAVERSAL_TARGET/.s5-test-root"
t_run env S5_TEST_MODE=1 S5_TEST_ROOT="$TRAVERSAL_TARGET/.." sh "$SRC" status
assert_eq "test root containing parent traversal exits 2" 2 "$T_STATUS"
assert_contains "names the unsafe traversal root" "S5_TEST_ROOT" "$T_OUT"
rm -rf "$TRAVERSAL_TARGET"

# --- a well-formed test root passes the guard ---
t_mktestroot
t_run sh "$SRC" status
assert_ne "valid test root passes the guard" 2 "$T_STATUS"
assert_not_contains "no guard complaint" "test-mode variable" "$T_OUT"

# --- path overrides cannot escape a sentinel-verified test root ---
for v in S5_PREFIX S5_SYSCONFDIR S5_STATEDIR S5_UNITDIR S5_INITDIR S5_BUILD_DIR; do
    outside=$(mktemp -d "${TMPDIR:-/tmp}/s5outside.XXXXXX")
    t_run env S5_TEST_MODE=1 S5_TEST_ROOT="$S5_TEST_ROOT" "$v=$outside" \
        sh "$SRC" status
    assert_eq "test mode rejects $v outside S5_TEST_ROOT" 2 "$T_STATUS"
    rm -rf "$outside"
done

# --- write-path overrides cannot escape either ---
# S5_LOGSINK and S5_TMPMODE_LOG are files the script WRITES. An unconfined
# value means a misconfigured test could log redacted diagnostics -- or worse,
# mode observations -- anywhere on the host filesystem. Verified behaviourally:
# with an outside sink, even an invalid subcommand's diagnostic must reach
# neither the file nor stderr un-contained.
for v in S5_LOGSINK S5_TMPMODE_LOG; do
    outside_dir=$(mktemp -d "${TMPDIR:-/tmp}/s5outside.XXXXXX")
    outside="$outside_dir/sink"
    t_run env S5_TEST_MODE=1 S5_TEST_ROOT="$S5_TEST_ROOT" "$v=$outside" \
        sh "$SRC" definitely-not-a-subcommand
    assert_eq "test mode rejects $v outside S5_TEST_ROOT" 2 "$T_STATUS"
    assert_eq "and writes nothing to the outside sink" "" \
        "$(cat "$outside" 2>/dev/null || printf '')"
    rm -rf "$outside_dir"
done

# S5_OSRELEASE and S5_PORT_PROBE are INPUTS the harness itself chooses (repo
# fixtures, a stub under the test root's bin/), not script output: they are
# read/executed but never written. Containment for them is the harness's
# discipline, and forcing them under S5_TEST_ROOT would break the legitimate
# repo-fixture case. The distinction is asserted so it is deliberate:
for v in S5_OSRELEASE S5_PORT_PROBE; do
    if grep -q "s5_test_path_ok.*$v\|$v.*s5_test_path_ok" "$SRC"; then
        t_bad "$v is now path-confined; update this comment if that is deliberate"
    else
        t_ok
    fi
done

# --- library mode lets unit tests call functions directly ---
S5_LIB_ONLY=1
export S5_LIB_ONLY
# shellcheck source=/dev/null
. "$SRC"
assert_eq "constants: project name" "socks5-manager" "$S5_PROJECT"
assert_eq "constants: pinned commit" \
    "da99424eac4092e3722f1a5b1844cfe80478f580" "$S5_PINNED_COMMIT"
assert_eq "constants: self-test URL is fixed" "https://example.com/" "$S5_SELFTEST_URL"
assert_contains "test paths are confined to the test root" "$S5_TEST_ROOT" "$S5_SYSCONFDIR"
assert_contains "prefix confined to the test root" "$S5_TEST_ROOT" "$S5_PREFIX"
assert_contains "state dir confined to the test root" "$S5_TEST_ROOT" "$S5_STATEDIR"

# --- redaction ---
S5_SECRET="Sup3rSecretValue"
assert_eq "redacts the live secret" \
    "pass=***REDACTED*** ok" "$(s5_redact 'pass=Sup3rSecretValue ok')"
# A multi-line message must keep its line structure. The redactor works
# line-by-line, so a missing newline silently glued the lines together and
# produced a message that no longer said what the caller wrote.
ml=$(printf 'first Sup3rSecretValue\nsecond line\nthird Sup3rSecretValue')
assert_eq "a multi-line message keeps its lines" \
    "first ***REDACTED***
second line
third ***REDACTED***" "$(s5_redact "$ml")"
# The redacting and passthrough paths must agree on shape, or a message changes
# depending on whether a secret happens to be set.
S5_SECRET="a-secret-that-does-not-occur"
red=$(s5_redact "$ml")
S5_SECRET=""
assert_eq "redaction with no match matches the passthrough path" "$(s5_redact "$ml")" "$red"
assert_eq "no secret set: passthrough" "plain text" "$(s5_redact 'plain text')"

# --- logging never emits the secret ---
S5_SECRET="LeakMeIfYouCan"
out=$(s5_log "credential is LeakMeIfYouCan" 2>&1)
assert_not_contains "s5_log redacts" "LeakMeIfYouCan" "$out"
out=$(s5_warn "credential is LeakMeIfYouCan" 2>&1)
assert_not_contains "s5_warn redacts" "LeakMeIfYouCan" "$out"
S5_SECRET=""

# --- a command with extra words is a usage error, not a silent ignore ---
# SPEC §10 defines the grammar as one bare command: none of them takes an
# argument or an option. The extras used to be forwarded to the command
# function, which discarded them, so `install --port 1080` ran a plain
# interactive install and the operator had no way to tell that the option had
# meant nothing at all.
#
# The command bodies are replaced by markers, so this exercises the dispatcher
# without letting install, restart or uninstall run on a development machine.
s5_cmd_install() { printf 'RAN:install ARGS:[%s]\n' "$*"; }
s5_cmd_status() { printf 'RAN:status ARGS:[%s]\n' "$*"; }
s5_cmd_show() { printf 'RAN:show ARGS:[%s]\n' "$*"; }
s5_cmd_restart() { printf 'RAN:restart ARGS:[%s]\n' "$*"; }
s5_cmd_uninstall() { printf 'RAN:uninstall ARGS:[%s]\n' "$*"; }
s5_cmd_auto() { printf 'RAN:auto ARGS:[%s]\n' "$*"; }

for c in install status show restart uninstall; do
    t_run s5_main "$c"
    assert_eq "[$c] on its own still runs" 0 "$T_STATUS"
    assert_contains "[$c] is called with no arguments at all" "RAN:$c ARGS:[]" "$T_OUT"
    t_run s5_main "$c" --port 1080
    assert_eq "[$c --port 1080] exits 64" 64 "$T_STATUS"
    assert_contains "[$c] names the extra word as the problem" "takes no arguments" "$T_OUT"
    assert_not_contains "[$c] did not run anyway" "RAN:$c" "$T_OUT"
done
t_run s5_main
assert_contains "no command at all still takes the auto path" "RAN:auto ARGS:[]" "$T_OUT"

t_summary
