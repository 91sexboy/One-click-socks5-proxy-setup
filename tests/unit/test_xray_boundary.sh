#!/bin/sh
# Independent destination fixture checks both production and protocol renderers.

S5T_NAME=test_xray_boundary
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
ROOT=${S5_REPO_ROOT}
t_mktestroot
t_source_production ''

S5_PORT=23456
S5_USERNAME=testuser
S5_PASSWORD='TestPassword_123~x'
s5t_boundary_ranges() {
    sed -n '/"ip": \[/,/\]/p' | sed -n 's/.*"\([0-9a-f:.]*\/[0-9]*\)".*/\1/p' | sort
}
_dcrendered=$(s5_config_render | s5t_boundary_ranges)
_dcfixture="$ROOT/tests/fixtures/denied-destinations.txt"
assert_file_exists "the destination boundary fixture exists" "$_dcfixture"
_dcexpected=$(sort "$_dcfixture")
_dcengine=$(s5t_boundary_ranges <"$ROOT/tests/protocol/start_engine.sh")
assert_eq "the destination boundary has twelve distinct ranges" 12 \
    "$(printf '%s\n' "$_dcexpected" | sort -u | wc -l | tr -d '[:space:]')"
assert_eq "the renderer denies exactly the expected ranges" "$_dcexpected" "$_dcrendered"
assert_eq "the protocol launcher denies exactly the expected ranges" "$_dcexpected" "$_dcengine"
assert_contains "the protocol launcher resolves hostname destinations" \
    '"domainStrategy": "IPIfNonMatch"' "$(cat "$ROOT/tests/protocol/start_engine.sh")"

t_summary
