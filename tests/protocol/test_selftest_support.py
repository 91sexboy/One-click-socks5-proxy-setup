#!/usr/bin/env python3
"""Regression tests for self-test assertions and owned process resources."""

import ast
import os
from pathlib import Path
import signal
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
from selftest_support import PtySession, kill_process_group


class SelftestSupportTests(unittest.TestCase):
    def test_selftests_do_not_use_optimized_away_assertions(self):
        protocol = Path(__file__).parent
        library = protocol.parent / "lib"
        paths = (list(protocol.glob("*selftest.py")) + list(protocol.glob("test_*.py")) +
                 list(library.glob("*_regression.py")) + [library / "lock_reclaim.py"])
        for path in paths:
            with self.subTest(path=path.name):
                tree = ast.parse(path.read_text())
                self.assertFalse(any(isinstance(node, ast.Assert) for node in ast.walk(tree)),
                                 "self-test assertions must remain active under python -O")

    def test_false_check_fails_with_optimization(self):
        script = '''from selftest_support import TapTestCase, run_tests
import unittest
class Broken(TapTestCase):
    def test_failure(self):
        self.check("controlled false condition", False)
raise SystemExit(run_tests(unittest.defaultTestLoader.loadTestsFromTestCase(Broken)))
'''
        result = subprocess.run([sys.executable, "-O", "-c", script],
                                cwd=Path(__file__).parent, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("not ok - controlled false condition", result.stdout)
        self.assertIn("TESTS 0 1", result.stdout)
        self.assertNotIn("ImportError", result.stderr)

    def test_session_does_not_close_a_reused_slave_descriptor(self):
        replacement = None
        with PtySession() as terminal:
            master, slave = terminal.master, terminal.slave
            terminal.close_slave()
            replacement = os.open(os.devnull, os.O_RDONLY)
            self.assertEqual(replacement, slave)
        try:
            os.fstat(replacement)
            with self.assertRaises(OSError):
                os.fstat(master)
        finally:
            os.close(replacement)

    def test_session_closes_both_descriptors_on_failure(self):
        with self.assertRaisesRegex(RuntimeError, "controlled failure"):
            with PtySession() as terminal:
                descriptors = terminal.master, terminal.slave
                raise RuntimeError("controlled failure")
        for descriptor in descriptors:
            with self.assertRaises(OSError):
                os.fstat(descriptor)

    def test_process_group_is_killed_and_reaped(self):
        process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"],
                                   start_new_session=True)
        try:
            kill_process_group(process)
            self.assertEqual(process.returncode, -signal.SIGKILL)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()

    def test_exited_parent_does_not_skip_group_cleanup(self):
        with patch("selftest_support.os.killpg") as kill:
            process = unittest.mock.Mock(pid=1234, returncode=0)
            kill_process_group(process)
            kill.assert_called_once_with(1234, signal.SIGKILL)
            process.wait.assert_called_once_with(timeout=2)


if __name__ == "__main__":
    unittest.main()
