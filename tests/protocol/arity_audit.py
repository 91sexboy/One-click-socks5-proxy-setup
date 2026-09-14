#!/usr/bin/env python3
"""Statically check resolvable calls in protocol probes and CI Python helpers."""

import ast
import inspect
from pathlib import Path
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]


def signature(node, bound=False):
    spec = node.args
    positional = spec.posonlyargs + spec.args
    defaults = [inspect.Parameter.empty] * (len(positional) - len(spec.defaults)) + [None] * len(spec.defaults)
    parameters = []
    for index, (argument, default) in enumerate(zip(positional, defaults)):
        kind = inspect.Parameter.POSITIONAL_ONLY if index < len(spec.posonlyargs) else inspect.Parameter.POSITIONAL_OR_KEYWORD
        parameters.append(inspect.Parameter(argument.arg, kind, default=default))
    if bound:
        parameters = parameters[1:]
    if spec.vararg:
        parameters.append(inspect.Parameter(spec.vararg.arg, inspect.Parameter.VAR_POSITIONAL))
    for argument, default in zip(spec.kwonlyargs, spec.kw_defaults):
        parameters.append(inspect.Parameter(argument.arg, inspect.Parameter.KEYWORD_ONLY,
                                            default=inspect.Parameter.empty if default is None else None))
    if spec.kwarg:
        parameters.append(inspect.Parameter(spec.kwarg.arg, inspect.Parameter.VAR_KEYWORD))
    return inspect.Signature(parameters)


def signatures(tree, module):
    found = {}
    for node in tree.body:
        function = node
        bound = False
        if isinstance(node, ast.ClassDef):
            function = next((child for child in node.body
                             if isinstance(child, ast.FunctionDef) and child.name == "__init__"), None)
            bound = True
        if isinstance(function, (ast.FunctionDef, ast.AsyncFunctionDef)):
            found[node.name] = [(module.stem + "." + node.name, signature(function, bound))]
    return found


class Calls(ast.NodeVisitor):
    def __init__(self, path, tables):
        self.path = path
        self.tables = tables
        self.names = {**tables[path], "__file__": path, "str": "str"}
        self.import_paths = [path.parent, ROOT / "tests/protocol", ROOT / ".github/scripts"]
        self.checked = 0
        self.expanded = 0
        self.problems = []

    def imported(self, name):
        for directory in self.import_paths:
            path = directory / (name + ".py")
            if path in self.tables:
                return self.tables[path]
        return name

    def resolve(self, node):
        if isinstance(node, ast.Name):
            return self.names.get(node.id)
        if isinstance(node, ast.Constant) and isinstance(node.value, (str, int)):
            return node.value
        if isinstance(node, ast.IfExp):
            left, right = self.resolve(node.body), self.resolve(node.orelse)
            if isinstance(left, list) and isinstance(right, list):
                return left + right
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Div):
            left, right = self.resolve(node.left), self.resolve(node.right)
            if isinstance(left, Path) and isinstance(right, str):
                return left / right
        if isinstance(node, ast.Subscript):
            value, index = self.resolve(node.value), self.resolve(node.slice)
            if isinstance(value, tuple) and isinstance(index, int) and 0 <= index < len(value):
                return value[index]
        if isinstance(node, ast.Attribute):
            value = self.resolve(node.value)
            if isinstance(value, dict):
                return value.get(node.attr)
            if isinstance(value, Path):
                if node.attr == "parent":
                    return value.parent
                if node.attr == "parents":
                    return tuple(value.parents)
            if isinstance(value, str):
                return value + "." + node.attr
        if isinstance(node, ast.Call):
            target = self.resolve(node.func)
            arguments = [self.resolve(argument) for argument in node.args]
            if target == "pathlib.Path" and len(arguments) == 1 and isinstance(arguments[0], (str, Path)):
                return Path(arguments[0])
            if target == "str" and len(arguments) == 1 and isinstance(arguments[0], Path):
                return str(arguments[0])
            if target == "importlib.util.spec_from_file_location" and len(arguments) >= 2:
                path = arguments[1]
                if isinstance(path, (str, Path)):
                    return self.tables.get(Path(path))
            if target == "importlib.util.module_from_spec" and len(arguments) == 1:
                return arguments[0]
            if isinstance(node.func, ast.Attribute):
                value = self.resolve(node.func.value)
                if isinstance(value, Path):
                    if node.func.attr == "resolve" and not arguments:
                        return value.resolve()
                    if node.func.attr == "with_name" and len(arguments) == 1 and isinstance(arguments[0], str):
                        return value.with_name(arguments[0])
        return None

    def visit_Import(self, node):
        for alias in node.names:
            self.names[alias.asname or alias.name.split(".")[0]] = self.imported(alias.name if alias.asname else alias.name.split(".")[0])

    def visit_ImportFrom(self, node):
        module = self.imported(node.module or "")
        for alias in node.names:
            self.names[alias.asname or alias.name] = module.get(alias.name) if isinstance(module, dict) else module + "." + alias.name

    def visit_Assign(self, node):
        self.visit(node.value)
        value = self.resolve(node.value)
        for target in node.targets:
            if isinstance(target, ast.Name):
                self.names[target.id] = value
            else:
                for name in ast.walk(target):
                    if isinstance(name, ast.Name) and isinstance(name.ctx, ast.Store):
                        self.names.pop(name.id, None)

    def visit_FunctionDef(self, node):
        self.names[node.name] = [(self.path.stem + "." + node.name, signature(node))]
        outer = self.names
        self.names = outer.copy()
        for argument in node.args.posonlyargs + node.args.args + node.args.kwonlyargs:
            self.names.pop(argument.arg, None)
        for argument in (node.args.vararg, node.args.kwarg):
            if argument:
                self.names.pop(argument.arg, None)
        for statement in node.body:
            self.visit(statement)
        self.names = outer

    visit_AsyncFunctionDef = visit_FunctionDef

    def visit_ClassDef(self, node):
        outer = self.names
        self.names = outer.copy()
        for statement in node.body:
            self.visit(statement)
        self.names = outer

    def visit_Call(self, node):
        candidates = self.resolve(node.func)
        if candidates == "sys.path.insert" and len(node.args) == 2:
            index, directory = (self.resolve(argument) for argument in node.args)
            if isinstance(index, int) and isinstance(directory, (str, Path)):
                self.import_paths.insert(index, Path(directory))
        if isinstance(candidates, list):
            if any(isinstance(argument, ast.Starred) for argument in node.args) or any(keyword.arg is None for keyword in node.keywords):
                self.expanded += 1
            else:
                self.checked += 1
                for label, contract in candidates:
                    try:
                        contract.bind(*[None for argument in node.args],
                                      **{keyword.arg: None for keyword in node.keywords})
                    except TypeError as error:
                        self.problems.append(f"{self.path.relative_to(ROOT)}:{node.lineno}: {label}: {error}")
        self.generic_visit(node)


def main():
    sources = sorted(path for directory in (ROOT / "tests/protocol", ROOT / ".github/scripts")
                     for path in directory.glob("*.py") if path != Path(__file__).resolve())
    trees = {path: ast.parse(path.read_text(encoding="utf-8"), filename=str(path)) for path in sources}
    tables = {path: signatures(tree, path) for path, tree in trees.items()}
    checked = expanded = 0
    problems = []
    for path, tree in trees.items():
        calls = Calls(path, tables)
        calls.visit(tree)
        checked += calls.checked
        expanded += calls.expanded
        problems.extend(calls.problems)
    print(f"arity: {checked} call sites checked across {len(sources)} modules; {expanded} calls with unpacking not statically checked")
    for problem in problems:
        print(problem, file=sys.stderr)
    return int(bool(problems))


if __name__ == "__main__":
    sys.exit(main())
