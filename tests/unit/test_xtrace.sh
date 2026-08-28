#!/bin/sh
# tests/unit/test_xtrace.sh - LOW-1 regression: an inherited `sh -x` must not
# echo the credential, because socks5.sh disables xtrace at startup.

S5T_NAME=test_xtrace
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
. "${S5_REPO_ROOT}/tests/lib/stub.sh"
. "${S5_REPO_ROOT}/tests/lib/env.sh"

s5env_setup
s5env_load

SECRET='XtraceLeak_9876~x'
printf '%s:%s' xtuser "$SECRET" >"$S5_TEST_ROOT/expected_creds"

# `set +x` must appear before anything that could touch a secret.
setplusx=$(grep -n '^set +x$' "${S5_SRC}" | head -n 1 | cut -d: -f1)
if [ -n "$setplusx" ] && [ "$setplusx" -lt 40 ]; then
    t_ok
else
    t_bad "set +x must appear near the very top of socks5.sh (found at line ${setplusx:-none})"
fi

mkdir -p "$S5_UNITDIR"
s5env_answers "y
31080
xtuser
$SECRET
$SECRET
y
y
"

# Run the real script with xtrace forced on by the caller.
out=$(env -u S5_LIB_ONLY sh -x "${S5_SRC}" install <"$S5_TEST_ROOT/answers" 2>&1)
rc=$?
assert_eq "install still succeeds under sh -x" 0 "$rc"
# The success summary prints the password on purpose; a TRACE line must not.
traced=$(printf '%s\n' "$out" | grep '^+' || true)
assert_not_contains "the password never appears in any xtrace line" "$SECRET" "$traced"
assert_not_contains "no xtrace line mentions the credential file content" "CL:" "$traced"

# The trace itself must have been suppressed: no xtrace prefix for our functions.
if printf '%s\n' "$out" | grep -q '^+ s5_'; then
    t_bad "xtrace output is still being produced"
else
    t_ok
fi

# ...and the credential file is nevertheless correct.
assert_eq "credentials were written correctly" \
    "xtuser:CL:$SECRET" "$(cat "$S5_USERSCFG")"

# `show` is the one intended path that does print it. Run it through a PTY so
# the terminal-only disclosure guard is tested without capturing a secret in a
# pipe. The helper independently separates xtrace lines from terminal output.
t_run python3 "${S5_REPO_ROOT}/tests/pty/show_xtrace.py" \
    "$S5_TEST_ROOT" "$S5_TEST_ROOT/bin"
assert_eq "show succeeds under sh -x on a terminal" 0 "$T_STATUS"
assert_contains "show helper confirms the terminal disclosure" \
    "terminal show succeeds" "$T_OUT"

t_summary
