#!/bin/sh
# Account identity and stale-lock ownership regressions.
#
# s5_account_identity must confirm the service group name still maps to the
# recorded GID on every backend, not only Alpine. account_identity gates
# account_remove, which deletes the group by name (groupdel/delgroup), so a
# same-named group that drifted to a different GID would otherwise be deleted --
# SPEC 7 removes only the resources this installation recorded.

S5T_NAME=test_xray_hardening
# shellcheck source=/dev/null
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
ROOT=${S5_REPO_ROOT}
t_mktestroot
t_source_production ''
S5_LANG=en

# id reports the recorded identity for the user; the group's GID is whatever the
# scenario file holds. Shell functions shadow the applets under BusyBox too, where
# applet names resolve before PATH.
S5_ACCOUNT_UID=900
S5_ACCOUNT_GID=900
id() { case "${1:-}" in -u) printf 900 ;; -g) printf 900 ;; *) return 1 ;; esac; }
getent() {
    [ "${1:-}" = group ] || return 0
    printf '%s:x:%s:\n' "$2" "$(cat "$S5_TEST_ROOT/groupgid" 2>/dev/null)"
}

for _fam in debian el alpine; do
    S5_OS_FAMILY=$_fam
    printf '900\n' >"$S5_TEST_ROOT/groupgid"
    s5_account_identity
    assert_eq "$_fam: a group mapping to the recorded GID passes identity" 0 "$?"
    printf '777\n' >"$S5_TEST_ROOT/groupgid"
    s5_account_identity
    assert_ne "$_fam: a same-named group at a different GID fails identity" 0 "$?"
done

unset -f id getent

t_run python3 "$ROOT/tests/lib/lock_reclaim.py" "$ROOT/socks5.sh" "${S5_TEST_SHELL:-sh}"
assert_eq "a paused stale-lock reclaimer cannot remove a new live lock" 0 "$T_STATUS"
assert_contains "the interleaving reaches the lock ownership assertions" \
    'stale-lock interleaving preserves mutual exclusion' "$T_OUT"

# Every locked command enters through one shared opening, so the precheck, lock
# and trap order cannot drift between them; uninstall used to repeat it by hand.
# Install takes the rollback traps instead and is the one other lock taker.
_lock_takers=$(awk '
    /^s5_[a-z0-9_]*\(\) [{(]/ { fn = $1; sub(/\(\)$/, "", fn); next }
    /^[})]$/ { fn = ""; next }
    /^[[:space:]]*#/ { next }
    fn != "" && /s5_lock_acquire([ ;]|$)/ { print fn }
' "$ROOT/socks5.sh" | sort -u | tr '\n' ' ')
assert_eq "only the shared opening and install acquire the lock" \
    's5_cmd_install s5_enter_locked ' "$_lock_takers"

# Shell variables are global, so a function that shares a variable prefix with
# anything it calls, directly or further down, can have its values replaced
# mid-flight. Each function's locals carry its own "_<abbrev>" prefix; along
# every call path no prefix may equal or extend another.
t_run python3 - "$ROOT/socks5.sh" <<'PY'
import re
import sys
from pathlib import Path


def functions(source):
    found, name, body = {}, None, []
    for line in source.split('\n'):
        match = re.match(r'^(s5_[a-z0-9_]+)\(\) [{(]\s*(.*)$', line)
        if name is None and match:
            name, body = match.group(1), [match.group(2)]
            if line.rstrip().endswith('}') and line.count('{') == line.count('}'):
                found[name], name = '\n'.join(body), None
        elif name is not None:
            if line in ('}', ')'):
                found[name], name = '\n'.join(body), None
            else:
                body.append(line)
    return found


def prefixes(body):
    names = set(re.findall(r'(?<![\w$])(_[a-z][a-z0-9_]*)=', body))
    names |= set(re.findall(r'\bfor (_[a-z][a-z0-9_]*) ', body))
    for group in re.findall(r'\bread (?:-r )?((?:_[a-z][a-z0-9_]* ?)+)', body):
        names |= set(group.split())
    return {name.split('_')[1] for name in names if name.split('_')[1]}


def overlaps(source):
    found = functions(source)
    calls = {f: {g for g in found if g != f and re.search(r'(?<![\w-])' + g + r'(?!\w)', body)}
             for f, body in found.items()}
    own = {f: prefixes(body) for f, body in found.items()}
    problems = []
    for f in found:
        seen, stack = set(), list(calls[f])
        while stack:
            g = stack.pop()
            if g in seen or g == f:
                continue
            seen.add(g)
            stack.extend(calls[g])
            for a in own[f]:
                for b in own[g]:
                    if a == b or a.startswith(b) or b.startswith(a):
                        problems.append('%s (_%s) reaches %s (_%s)' % (f, a, g, b))
    return len(found), problems


source = Path(sys.argv[1]).read_text()
count, problems = overlaps(source)
if count < 100:
    raise SystemExit('the audit found only %d functions' % count)
if problems:
    raise SystemExit('\n'.join(problems))
# Control: s5_cmd_install calls s5_confirm, so giving s5_confirm the caller's
# prefix must be caught.
mutated = source.replace('_sconf_answer', '_sci_answer')
if not any('s5_cmd_install (_sci) reaches s5_confirm (_sci)' in line for line in overlaps(mutated)[1]):
    raise SystemExit('the audit missed a prefix shared along a call path')
PY
assert_eq "no function shares a variable prefix with anything it calls" 0 "$T_STATUS"
if [ "$T_STATUS" -ne 0 ]; then printf '%s\n' "$T_OUT" >&2; fi

t_summary
