#!/usr/bin/env python3
"""Exercise the arity audit through temporary repository copies."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]


class ArityAuditTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="s5-arity-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        for directory in ("tests/protocol", ".github/scripts"):
            destination = self.root / directory
            destination.mkdir(parents=True)
            for source in (ROOT / directory).glob("*.py"):
                shutil.copy2(source, destination / source.name)

    def audit(self):
        return subprocess.run(
            [sys.executable, str(self.root / "tests/protocol/arity_audit.py")],
            text=True, capture_output=True, timeout=15,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        )

    def replace(self, relative, old, new):
        path = self.root / relative
        source = path.read_text()
        self.assertEqual(source.count(old), 1)
        path.write_text(source.replace(old, new))

    def assert_rejected(self, relative, name):
        result = self.audit()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertRegex(result.stderr, relative.replace(".", r"\.") + r":\d+:")
        self.assertIn(name, result.stderr)

    def test_repository_passes_without_importing_targets(self):
        path = self.root / "tests/protocol/xray_mixed.py"
        path.write_text("raise RuntimeError('audit imported a target')\n" + path.read_text())
        result = self.audit()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_memory_gate_missing_argument(self):
        self.replace(".github/scripts/memory-compare.py",
                     'xray_mixed.validate_server_frame(frame, session["cid"], session["nonce"], session["server_seq"])',
                     'xray_mixed.validate_server_frame(frame, session["cid"], session["nonce"])')
        self.assert_rejected(".github/scripts/memory-compare.py", "validate_server_frame")

    def test_memory_gate_unknown_keyword(self):
        self.replace(".github/scripts/memory-compare.py",
                     'xray_mixed.read_frame(session["socket"], deadline)',
                     'xray_mixed.read_frame(session["socket"], timeout=deadline)')
        self.assert_rejected(".github/scripts/memory-compare.py", "read_frame")

    def test_duplicate_argument_binding(self):
        self.replace(".github/scripts/memory-compare.py",
                     'xray_mixed.read_frame(session["socket"], deadline)',
                     'xray_mixed.read_frame(session["socket"], sock=deadline)')
        self.assert_rejected(".github/scripts/memory-compare.py", "read_frame")

    def test_required_keyword_only_parameter(self):
        self.replace("tests/protocol/xray_mixed.py",
                     "def read_frame(sock, deadline):", "def read_frame(sock, deadline, *, boundary):")
        self.assert_rejected(".github/scripts/memory-compare.py", "boundary")
    def test_conditional_function_alias_checks_both_choices(self):
        self.replace(".github/scripts/memory-compare.py",
                     "sock = connect(self.proxy, self.target, self.credentials)",
                     "sock = connect(self.proxy, self.target)")
        result = self.audit()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("xray_mixed.socks5_connect", result.stderr)
        self.assertIn("xray_mixed.http_connect", result.stderr)

    def test_dynamic_import_with_sibling_path(self):
        self.replace(".github/scripts/memory-compare.py",
                     "sampler.SnapshotReader(service.pid, service.cgroup)",
                     "sampler.SnapshotReader(service.pid)")
        self.assert_rejected(".github/scripts/memory-compare.py", "SnapshotReader")

    def test_dynamic_import_with_repository_path(self):
        (self.root / "tests/protocol/audit_client.py").write_text(
            "from pathlib import Path\nfrom importlib.util import spec_from_file_location, module_from_spec\n"
            "ROOT = Path(__file__).resolve().parents[2]\n"
            "spec = spec_from_file_location('comparison', ROOT / '.github/scripts/memory-compare.py')\n"
            "comparison = module_from_spec(spec)\n"
            "spec.loader.exec_module(comparison)\ncomparison.profile_config({})\n")
        self.assert_rejected("tests/protocol/audit_client.py", "profile_config")

    def test_imported_alias_supports_all_parameter_kinds(self):
        (self.root / "tests/protocol/audit_contract.py").write_text(
            "def check(first, /, second=2, *values, required, optional=3, **extras):\n    pass\n")
        client = self.root / ".github/scripts/audit_client.py"
        client.write_text("from audit_contract import check as validate\n"
                          "validate(1, 2, 3, required=True, extra=4)\n")
        result = self.audit()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        client.write_text("from audit_contract import check as validate\n"
                          "validate(first=1, required=True)\n")
        self.assert_rejected(".github/scripts/audit_client.py", "check")

    def test_same_named_modules_keep_separate_signatures(self):
        (self.root / "tests/protocol/audit_contract.py").write_text("def check(one): pass\n")
        (self.root / ".github/scripts/audit_contract.py").write_text("def check(one, two): pass\n")
        (self.root / "tests/protocol/audit_client.py").write_text("import audit_contract\naudit_contract.check(1)\n")
        (self.root / ".github/scripts/audit_client.py").write_text("import audit_contract\naudit_contract.check(1)\n")
        self.assert_rejected(".github/scripts/audit_client.py", "check")
        self.assertNotIn("tests/protocol/audit_client.py:", self.audit().stderr)

    def test_explicit_import_path_precedes_sibling_module(self):
        (self.root / "tests/protocol/audit_contract.py").write_text("def check(one, two): pass\n")
        (self.root / ".github/scripts/audit_contract.py").write_text("def check(one): pass\n")
        (self.root / ".github/scripts/audit_client.py").write_text(
            "import sys\nfrom pathlib import Path\n"
            "sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'tests/protocol'))\n"
            "import audit_contract\naudit_contract.check(1)\n")
        self.assert_rejected(".github/scripts/audit_client.py", "check")

    def test_unknown_argument_expansion_is_not_counted_as_checked(self):
        (self.root / ".github/scripts/audit_client.py").write_text(
            "from xray_mixed import read_frame\nread_frame(*args, **kwargs)\n")
        result = self.audit()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("1 calls with unpacking not statically checked", result.stdout)

    def test_function_parameter_shadowing_does_not_use_import_signature(self):
        (self.root / ".github/scripts/audit_client.py").write_text(
            "from xray_mixed import read_frame\n"
            "def invoke(read_frame):\n    read_frame()\n")
        result = self.audit()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
