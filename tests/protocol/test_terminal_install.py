#!/usr/bin/env python3
"""Exercise the terminal probe through its CLI with isolated external commands."""

import os
from pathlib import Path
import secrets
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class TerminalProbeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="s5-terminal-test-")
        self.addCleanup(self.directory.cleanup)
        self.work = Path(self.directory.name)
        self.password = secrets.token_hex(16)
        (self.work / "answers").write_text("")
        (self.work / "pass").write_text("fixture\n" + self.password + "\n")
        scripts = self.work / ".github" / "scripts"
        scripts.mkdir(parents=True)
        shutil.copyfile(ROOT / ".github/scripts/run-socks5.sh", scripts / "run-socks5.sh")
        tools = self.work / "bin"
        tools.mkdir()
        for name in ("systemctl", "journalctl", "ss"):
            tool = tools / name
            tool.write_text("#!/bin/sh\nprintf 'diagnostic-from-" + name + "\\n'\nsed -n '2p' pass\n")
            tool.chmod(0o755)
        self.environment = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"])

    def run_probe(self, body):
        (self.work / "socks5.sh").write_text(
            "#!/bin/sh\nprintf 'invoked\\n' >> invocations\n" + body
        )
        return subprocess.run(
            ["python3", str(ROOT / "tests/protocol/terminal_install.py"),
             "answers", "pass", "23456", "1"],
            cwd=self.work, env=self.environment, capture_output=True, text=True, timeout=15,
        )

    def assert_private(self, result):
        output = result.stdout + result.stderr
        self.assertTrue(self.password not in output, "a credential reached probe output")
        self.assertTrue("socks5://" not in output, "a SOCKS5 URI reached probe output")
        self.assertTrue("http://" not in output, "an HTTP URI reached probe output")
        self.assertEqual((self.work / "invocations").read_text(), "invoked\n")

    def test_success_prints_only_a_safe_summary(self):
        result = self.run_probe(
            "printf 'Choose language\\nXray mixed proxy installation completed.\\n'\n"
            "password=$(sed -n '2p' pass)\n"
            "printf 'socks5://fixture:%s@192.0.2.1:23456\\n' \"$password\"\n"
            "printf 'http://fixture:%s@192.0.2.1:23456\\n' \"$password\"\n"
        )
        self.assertEqual(result.returncode, 0)
        self.assertTrue("credential_card=ok" in result.stdout)
        self.assert_private(result)

    def test_failed_install_keeps_redacted_evidence_without_rerunning(self):
        result = self.run_probe(
            "printf 'unique-service-start-failure\\n' >&2\n"
            "sed -n '2p' pass\nexit 1\n"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue("unique-service-start-failure" in result.stderr)
        self.assertTrue("diagnostic-from-systemctl" in result.stderr)
        self.assertTrue("diagnostic-from-journalctl" in result.stderr)
        self.assertTrue("diagnostic-from-ss" in result.stderr)
        self.assert_private(result)

    def test_wrong_card_is_not_published_in_failure_evidence(self):
        result = self.run_probe(
            "printf 'Choose language\\nunique-wrong-card-diagnostic\\n'\n"
            "printf 'socks5://unexpected:other-password@192.0.2.1:23456\\n'\n"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue("unique-wrong-card-diagnostic" in result.stderr)
        self.assertTrue("other-password" not in result.stderr)
        self.assert_private(result)


if __name__ == "__main__":
    unittest.main()
