#!/bin/sh
# Public checkout contracts without private maintenance documents.

S5T_NAME=test_xray_public_checkout
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
ROOT=${S5_REPO_ROOT}
t_mktestroot

# t_public_snapshot <root> <dest>: copy the tracked public paths only. A recursive
# copy of the directories also carried untracked files -- bytecode caches,
# scratch notes -- into the checkout that is supposed to prove nothing local is
# needed. Working-tree contents are copied, so uncommitted edits are tested.
# The copy is Python because BusyBox's cp has no --parents under every shell.
t_public_snapshot() {
    python3 - "$1" "$2" <<'PY_SNAPSHOT'
import shutil
import subprocess
import sys
from pathlib import Path

source, target = (Path(path) for path in sys.argv[1:])
listed = subprocess.run(
    ['git', '-C', str(source), 'ls-files', '-z', '--', 'tests', '.github', 'docs',
     'socks5.sh', 'README.md', 'README.zh-CN.md', 'LICENSE',
     'THIRD_PARTY_NOTICES.md', '.gitignore'],
    check=True, stdout=subprocess.PIPE).stdout.split(b'\0')
paths = [name.decode() for name in listed if name]
if not paths:
    raise SystemExit('no tracked public files')
target.mkdir()
for name in paths:
    (target / name).parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source / name, target / name)
PY_SNAPSHOT
}

# The snapshot itself must exclude an untracked file planted beside tracked ones.
_psrepo=$S5_TEST_ROOT/planted
mkdir -p "$_psrepo/tests/unit" || exit 1
git -C "$_psrepo" init -q || exit 1
printf 'tracked\n' >"$_psrepo/tests/unit/tracked.sh"
printf 'planted\n' >"$_psrepo/tests/unit/untracked.sh"
git -C "$_psrepo" add tests/unit/tracked.sh || exit 1
t_run t_public_snapshot "$_psrepo" "$S5_TEST_ROOT/planted-public"
assert_eq "a snapshot of tracked files succeeds" 0 "$T_STATUS"
assert_file_exists "the snapshot keeps a tracked file" "$S5_TEST_ROOT/planted-public/tests/unit/tracked.sh"
assert_file_absent "the snapshot drops an untracked file" "$S5_TEST_ROOT/planted-public/tests/unit/untracked.sh"

snapshot="$S5_TEST_ROOT/public"
t_public_snapshot "$ROOT" "$snapshot" || exit 1
git -C "$snapshot" init -q || exit 1
git -C "$snapshot" add . || exit 1
set -- "$snapshot"/tests/unit/*.sh
expected_files=$(sed -n 's/^EXPECTED_UNIT_FILES=//p' "$snapshot/tests/run.sh")
assert_eq "public unit file count agrees with the runner guard" "$expected_files" "$#"

for doc in CLAUDE.md CONTEXT.md SPEC.md todo.md TODO.md; do
    assert_file_absent "public checkout has no $doc" "$snapshot/$doc"
    t_run git -C "$snapshot" check-ignore -q -- "$doc"
    assert_eq "$doc stays ignored" 0 "$T_STATUS"
done

# Exercise the real document checks without letting local-only files satisfy them.
SHELL_UNDER_TEST=${S5_TEST_SHELL:-sh}
for contract in workflow readme boundary probe_contract memory_report; do
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
