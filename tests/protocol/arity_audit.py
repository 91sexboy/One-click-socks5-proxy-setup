#!/usr/bin/env python3
"""Check every call in tests/protocol against the callee's signature.

`python3 -m py_compile` accepts a call with the wrong number of arguments, so a
signature change that misses one caller stays green until the job that runs it
gets there. The memory gate pays for that late: `hold_connections.py` is reached
only after an apt-get, a 21 MB download and a real root install, so a stale call
there costs a whole run to discover.

Calls are matched two ways: bare `f(...)` against the same file, and
`module.f(...)` against the module imported under that name from this directory.
"""

import ast
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def signatures(tree):
    """Map each top-level function name to (min_args, max_args, takes_varargs)."""
    found = {}
    for node in tree.body:
        if not isinstance(node, ast.FunctionDef):
            continue
        spec = node.args
        names = [arg.arg for arg in getattr(spec, "posonlyargs", []) + spec.args]
        required = len(names) - len(spec.defaults)
        found[node.name] = (required, len(names), spec.vararg is not None)
    return found


def module_aliases(tree, known):
    """Map the local name of each sibling module import to its module name."""
    aliases = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name in known:
                    aliases[alias.asname or alias.name] = alias.name
    return aliases


def callee(node, own, aliases, tables):
    """Resolve a Call node to (label, signature) or None when out of scope."""
    if isinstance(node.func, ast.Name) and node.func.id in own:
        return node.func.id, own[node.func.id]
    if isinstance(node.func, ast.Attribute) and isinstance(node.func.value, ast.Name):
        module = aliases.get(node.func.value.id)
        if module and node.func.attr in tables[module]:
            label = "%s.%s" % (module, node.func.attr)
            return label, tables[module][node.func.attr]
    return None


def main():
    sources = sorted(
        name[:-3] for name in os.listdir(HERE)
        if name.endswith(".py") and name != os.path.basename(__file__)
    )
    trees = {}
    tables = {}
    for module in sources:
        with open(os.path.join(HERE, module + ".py"), encoding="utf-8") as handle:
            trees[module] = ast.parse(handle.read())
        tables[module] = signatures(trees[module])

    problems = []
    checked = 0
    for module in sources:
        tree = trees[module]
        aliases = module_aliases(tree, set(sources))
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call):
                continue
            resolved = callee(node, tables[module], aliases, tables)
            if resolved is None:
                continue
            label, (low, high, varargs) = resolved
            checked += 1
            supplied = len(node.args) + len(node.keywords)
            if varargs and supplied >= low:
                continue
            if low <= supplied <= high:
                continue
            problems.append(
                "%s.py:%d: %s takes %d-%d arguments but %d were given"
                % (module, node.lineno, label, low, high, supplied)
            )

    print("arity: %d call sites checked across %d modules" % (checked, len(sources)))
    if problems:
        for problem in problems:
            print(problem, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
