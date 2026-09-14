#!/bin/sh
# Public checkout contracts without private maintenance documents.

S5T_NAME=test_xray_public_checkout
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
ROOT=${S5_REPO_ROOT}
t_mktestroot

snapshot="$S5_TEST_ROOT/public"
mkdir "$snapshot" || exit 1
cp -R "$ROOT/tests" "$ROOT/.github" "$ROOT/docs" "$snapshot/" || exit 1
cp "$ROOT/socks5.sh" "$ROOT/README.md" "$ROOT/README.zh-CN.md" \
    "$ROOT/LICENSE" "$ROOT/.gitignore" "$snapshot/" || exit 1
git -C "$snapshot" init -q || exit 1
git -C "$snapshot" add . || exit 1
set -- "$snapshot"/tests/unit/*.sh
expected_files=$(sed -n 's/^EXPECTED_UNIT_FILES=//p' "$snapshot/tests/run.sh")
assert_eq "public unit file count agrees with the runner guard" "$expected_files" "$#"

for doc in CLAUDE.md CONTEXT.md SPEC.md todo.md; do
    assert_file_absent "public checkout has no $doc" "$snapshot/$doc"
    t_run git -C "$snapshot" check-ignore -q -- "$doc"
    assert_eq "$doc stays ignored" 0 "$T_STATUS"
done

# Exercise the real document checks without letting local-only files satisfy them.
SHELL_UNDER_TEST=${S5_TEST_SHELL:-sh}
for contract in docs readme boundary probe_contract memory_contract; do
    # Split multiword shell commands such as busybox sh.
    # shellcheck disable=SC2086
    t_run env S5_REPO_ROOT="$snapshot" S5_SRC="$snapshot/socks5.sh" \
        $SHELL_UNDER_TEST "$snapshot/tests/unit/test_xray_$contract.sh"
    assert_eq "$contract checks pass without local-only files" 0 "$T_STATUS"
    if [ "$T_STATUS" -ne 0 ]; then printf '%s\n' "$T_OUT" >&2; fi
    assert_contains "$contract checks reach their summary" 'TESTS ' "$T_OUT"
    assert_contains "$contract checks do not skip coverage" 'SKIPS 0' "$T_OUT"
done

t_summary
