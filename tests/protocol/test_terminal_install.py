#!/usr/bin/env python3
"""Exercise the terminal probe through its CLI with isolated external commands."""

import os
from pathlib import Path
import pty
import secrets
import select
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True
import terminal_install


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


class PromptInputTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="s5-prompt-test-")
        self.addCleanup(self.directory.cleanup)
        self.work = Path(self.directory.name)
        (self.work / ".s5-test-root").touch()
        self.environment = dict(os.environ, S5_TEST_MODE="1", S5_LIB_ONLY="1",
                                S5_TEST_ROOT=str(self.work))
        self.answers = ["y", "23456", "prompt_user", secrets.token_hex(16)]
        self.prompts = {
            "zh": ["确认安装 Xray mixed 代理？[Y/n] ",
                   "端口 [回车 = 随机 20000-60000]：",
                   "账户名 [回车 = 随机]：",
                   "密码（输入时可见）[回车 = 随机]："],
            "en": ["Install the Xray mixed proxy? [Y/n] ",
                   "Port [Enter = random 20000-60000]: ",
                   "Username [Enter = random]: ",
                   "Password (visible while typed) [Enter = random]: "],
        }

    def command(self, language):
        return shlex.split(os.environ.get("S5_TEST_SHELL", "sh")) + ["-c", '''
set -e
. "$1"
S5_LANG=$2
s5_port_free() { return 0; }
s5_confirm_install
s5_prompt_port
s5_prompt_username
s5_prompt_password
printf 'answers-accepted\\n'
''', "prompt-test", str(ROOT / "socks5.sh"), language]

    def read_until(self, descriptor, marker):
        output = b""
        deadline = time.monotonic() + 5
        while marker not in output:
            remaining = deadline - time.monotonic()
            self.assertTrue(remaining > 0, "timed out waiting for prompt or echo")
            ready, _, _ = select.select([descriptor], [], [], remaining)
            self.assertTrue(ready, "terminal did not produce the expected output")
            output += os.read(descriptor, 65536)
        return output

    def test_terminal_waits_for_enter_at_each_prompt(self):
        for language, prompts in self.prompts.items():
            with self.subTest(language=language):
                master, slave = pty.openpty()
                process = None
                try:
                    process = subprocess.Popen(self.command(language), env=self.environment,
                                               stdin=slave, stdout=slave, stderr=slave,
                                               start_new_session=True)
                    os.close(slave)
                    slave = None
                    for index, (prompt, answer) in enumerate(zip(prompts, self.answers)):
                        expected = (("\r\n" if index else "") + prompt).encode()
                        output = self.read_until(master, prompt.encode())
                        self.assertTrue(output == expected, "prompt order or terminal line layout changed")
                        self.assertFalse(select.select([master], [], [], 0.1)[0],
                                         "advanced before receiving an answer")
                        os.write(master, answer.encode())
                        echo = self.read_until(master, answer.encode())
                        self.assertTrue(echo == answer.encode(), "unexpected output while typing")
                        self.assertFalse(select.select([master], [], [], 0.1)[0],
                                         "advanced before Enter")
                        os.write(master, b"\n")
                    self.read_until(master, b"answers-accepted")
                    self.assertEqual(process.wait(timeout=5), 0)
                finally:
                    if process is not None and process.poll() is None:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
                    if slave is not None:
                        os.close(slave)
                    os.close(master)

    def test_redirected_answers_keep_prompts_on_separate_lines(self):
        for language, prompts in self.prompts.items():
            for answers in (self.answers, ["", "", "", ""]):
                with self.subTest(language=language, defaults=not answers[0]):
                    result = subprocess.run(self.command(language), env=self.environment,
                                            input="\n".join(answers) + "\n", capture_output=True,
                                            text=True, timeout=10)
                    self.assertEqual(result.returncode, 0)
                    self.assertTrue(result.stderr == "\n".join(prompts) + "\n",
                                    "redirected prompts ran together or exposed input")
                    self.assertEqual(result.stdout, "answers-accepted\n")

    def test_file_answers_with_terminal_output_keep_separate_lines(self):
        answers = self.work / "answers"
        answers.write_text("\n".join(self.answers) + "\n")
        for language, prompts in self.prompts.items():
            with self.subTest(language=language):
                command = ["env", "S5_TEST_MODE=1", "S5_LIB_ONLY=1",
                           "S5_TEST_ROOT=" + str(self.work)] + self.command(language)
                output = terminal_install.capture_terminal(command, answers, timeout=10)
                expected = "\n".join(prompts) + "\nanswers-accepted\n"
                self.assertTrue(output.replace(b"\r\n", b"\n") == expected.encode(),
                                "file-fed terminal prompts ran together or exposed input")

    def test_terminal_input_with_redirected_prompts_keeps_separate_lines(self):
        master, slave = pty.openpty()
        process = None
        try:
            process = subprocess.Popen(self.command("en"), env=self.environment,
                                       stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       start_new_session=True)
            os.close(slave)
            slave = None
            os.write(master, ("\n".join(self.answers) + "\n").encode())
            output, prompts = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0)
            self.assertEqual(output, b"answers-accepted\n")
            self.assertTrue(prompts == ("\n".join(self.prompts["en"]) + "\n").encode(),
                            "redirected prompts relied on uncaptured input echo")
        finally:
            if process is not None and process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()
            if slave is not None:
                os.close(slave)
            os.close(master)

    def test_invalid_answers_retry_without_exposing_input(self):
        answers = ["y", "bad-port", "23456", "!", "prompt_user", "short", self.answers[-1]]
        result = subprocess.run(self.command("en"), env=self.environment,
                                input="\n".join(answers) + "\n", capture_output=True,
                                text=True, timeout=5)
        self.assertEqual(result.returncode, 0)
        for prompt, count in zip(self.prompts["en"], (1, 2, 2, 2)):
            self.assertEqual(result.stderr.splitlines().count(prompt), count)
        self.assertTrue(self.answers[-1] not in result.stdout + result.stderr,
                        "a password reached redirected output")

    def test_eof_and_cancellation_do_not_advance(self):
        for answer in ("", "n\n"):
            with self.subTest(eof=not answer):
                result = subprocess.run(self.command("en"), env=self.environment, input=answer,
                                        capture_output=True, text=True, timeout=5)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(result.stderr == self.prompts["en"][0] + "\n",
                                "EOF or cancellation advanced to another question")
                self.assertNotIn("answers-accepted", result.stdout)


if __name__ == "__main__":
    unittest.main()
