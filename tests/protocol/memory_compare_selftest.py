#!/usr/bin/env python3
"""Nonprivileged checks for comparison profiles, verdicts, sampling and traffic."""

import copy
import importlib.util
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
import unittest
from unittest import mock

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
if __name__ == "__main__" and len(sys.argv) > 1 and not sys.argv[1].startswith("-"):
    ROOT = Path(sys.argv.pop(1)).resolve()
spec = importlib.util.spec_from_file_location("memory_compare", ROOT / ".github/scripts/memory-compare.py")
comparison = importlib.util.module_from_spec(spec)
spec.loader.exec_module(comparison)


class ComparisonTests(unittest.TestCase):
    def test_profiles_change_only_the_port_and_explicit_buffer_policy(self):
        source = {"inbounds": [{"port": 23456, "settings": {"accounts": [{"user": "fixture", "pass": "synthetic"}]}}],
                  "routing": {"domainStrategy": "IPIfNonMatch"}, "outbounds": [{"protocol": "freedom"}]}
        original = copy.deepcopy(source)
        baseline = comparison.profile_config(source, "baseline", 23457)
        candidate = comparison.profile_config(source, "buffer4k", 23457)
        expected = copy.deepcopy(source)
        expected["inbounds"][0]["port"] = 23457
        self.assertEqual(baseline, expected)
        expected["policy"] = {"levels": {"0": {"bufferSize": 4}}}
        self.assertEqual(candidate, expected)
        self.assertEqual(source, original)
        self.assertEqual(comparison.profile_config(candidate, "baseline", 23457), baseline)
        with self.assertRaises(ValueError):
            comparison.profile_config(source, "unknown", 23457)
        source["policy"] = {"levels": {"0": {"bufferSize": 8}}}
        with self.assertRaises(ValueError):
            comparison.profile_config(source, "baseline", 23457)
    def trials(self, baseline=(100, 102, 98), candidate=(75, 76, 74)):
        trials = []
        for pair in range(3):
            for profile, memory in (("baseline", baseline[pair]), ("buffer4k", candidate[pair])):
                stages = {}
                for name in ("idle", "held1", "held32", "held128", "duplex", "slow", "recovery"):
                    stages[name] = {
                        "seconds": 30, "observation_count": 31,
                        "rss_median_kib": memory + 200, "rss_anon_median_kib": memory,
                        "cgroup_peak_bytes": memory * 1024, "cpu_usec": 3000,
                        "verified_bytes": 3000 if name in ("duplex", "slow") else 0,
                        "oom": 0, "oom_kill": 0,
                    }
                trials.append({"pair": pair + 1, "profile": profile, "restarts": 0, "stages": stages})
        return trials

    def test_decision_requires_measured_benefit_beyond_variability(self):
        verdict = comparison.assess(self.trials(), "amd64")
        self.assertEqual(verdict["outcome"], "benefit")
        self.assertTrue(verdict["eligible"])
        noisy = comparison.assess(self.trials((80, 100, 120), (95, 96, 94)), "amd64")
        self.assertEqual(noisy["outcome"], "no-demonstrated-benefit")
        self.assertFalse(noisy["eligible"])
        arm = comparison.assess(self.trials((100, 102, 98), (100, 102, 98)), "arm64")
        self.assertEqual(arm["outcome"], "no-regression")
        self.assertTrue(arm["eligible"])

    def test_performance_regression_is_not_hidden_by_lower_memory(self):
        for field, value in (("verified_bytes", 2000), ("cpu_usec", 4000)):
            with self.subTest(field=field):
                trials = self.trials()
                for trial in trials:
                    if trial["profile"] == "buffer4k":
                        trial["stages"]["duplex"][field] = value
                verdict = comparison.assess(trials, "amd64")
                self.assertEqual(verdict["outcome"], "regression")
                self.assertFalse(verdict["eligible"])

    def test_unstable_pairs_do_not_pass_on_a_favorable_median(self):
        trials = self.trials()
        trials[1]["stages"]["duplex"]["verified_bytes"] = 2000
        verdict = comparison.assess(trials, "amd64")
        self.assertEqual(verdict["outcome"], "inconclusive")
        self.assertFalse(verdict["eligible"])

    def test_missing_or_failed_measurements_cannot_produce_a_verdict(self):
        for fault in ("trial", "stage", "samples", "long-window", "extra-samples", "traffic", "oom", "restart", "nan"):
            with self.subTest(fault=fault):
                trials = self.trials()
                if fault == "trial":
                    trials.pop()
                elif fault == "stage":
                    del trials[0]["stages"]["idle"]
                elif fault == "samples":
                    trials[0]["stages"]["idle"]["observation_count"] = 1
                elif fault == "long-window":
                    trials[0]["stages"]["idle"]["seconds"] = 40
                elif fault == "extra-samples":
                    trials[0]["stages"]["idle"]["observation_count"] = 40
                elif fault == "traffic":
                    trials[0]["stages"]["duplex"]["verified_bytes"] = 0
                elif fault == "oom":
                    trials[0]["stages"]["idle"]["oom"] = 1
                elif fault == "restart":
                    trials[0]["restarts"] = 1
                else:
                    trials[0]["stages"]["duplex"]["cpu_usec"] = float("nan")
                with self.assertRaises(ValueError):
                    comparison.assess(trials, "amd64")
    def test_observation_window_has_regular_samples_and_checks_failures(self):
        class Clock:
            now = 0.0
            def time(self):
                return self.now
            def wait(self, duration):
                self.now += duration
        clock = Clock()
        class Reader:
            def snapshot(self):
                return {"cpu_usec": int(clock.now * 1000), "cgroup_oom": 0, "cgroup_oom_kill": 0}
        checks = []
        values = comparison.observe(Reader(), lambda: checks.append(clock.now), duration=3,
                                    clock=clock.time, wait=clock.wait)
        self.assertEqual([value["elapsed_seconds"] for value in values], [0, 1, 2, 3])
        self.assertEqual([value["cpu_usec"] for value in values], [0, 1000, 2000, 3000])
        self.assertEqual(checks, [0, 1, 2, 3])
        def broken():
            raise RuntimeError("owned service failed")
        with self.assertRaises(RuntimeError):
            comparison.observe(Reader(), broken, duration=3, clock=clock.time, wait=clock.wait)
        def late_wait(duration):
            clock.now += duration + 2
        with self.assertRaises(TimeoutError):
            comparison.observe(Reader(), lambda: None, duration=3, clock=clock.time, wait=late_wait)
        for location in ("check", "snapshot"):
            with self.subTest(delayed=location):
                clock.now = 0
                def delay_last_read():
                    if clock.now >= 3:
                        clock.now += 2
                def slow_check():
                    if location == "check":
                        delay_last_read()
                class SlowReader(Reader):
                    def snapshot(self):
                        if location == "snapshot":
                            delay_last_read()
                        return super().snapshot()
                with self.assertRaises(TimeoutError):
                    comparison.observe(SlowReader(), slow_check, duration=3,
                                       clock=clock.time, wait=clock.wait)

    def run_traffic(self, mode, corrupt=False, fail_connect=False):
        sys.path.insert(0, str(ROOT / "tests/protocol"))
        import duplex_target
        duplex_target.STOP.clear()
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(8)
        listener.settimeout(0.1)
        workers = []
        stop = threading.Event()
        def accept():
            while not stop.is_set():
                try:
                    sock, _ = listener.accept()
                except socket.timeout:
                    continue
                except OSError:
                    return
                worker = threading.Thread(target=duplex_target.serve_connection, args=(sock, None, None))
                workers.append(worker)
                worker.start()
        acceptor = threading.Thread(target=accept)
        acceptor.start()
        connections = 0
        def connect(*_args):
            nonlocal connections
            connections += 1
            if fail_connect and connections == 2:
                raise OSError("injected connect failure")
            return socket.create_connection(listener.getsockname(), timeout=2)
        original_frame = duplex_target.frame
        def frame(kind, cid, seq, nonce, payload):
            if corrupt and kind == ord("E"):
                payload += b"wrong"
            return original_frame(kind, cid, seq, nonce, payload)
        result = None
        try:
            with mock.patch.object(comparison.xray_mixed, "socks5_connect", connect), \
                 mock.patch.object(comparison.xray_mixed, "http_connect", connect), \
                 mock.patch.object(duplex_target, "frame", frame):
                endpoint = comparison.xray_mixed.Endpoint("127.0.0.1", 1)
                creds = comparison.xray_mixed.Credentials("fixture", "synthetic")
                with comparison.TunnelLoad(endpoint, endpoint, creds, 2, mode) as load:
                    load.start()
                    deadline = time.monotonic() + (3 if mode == "slow" else 0.6)
                    while time.monotonic() < deadline:
                        load.check()
                        stop.wait(0.02)
                result = load.stats()
        finally:
            stop.set()
            listener.close()
            acceptor.join(2)
            for worker in workers:
                worker.join(3)
            self.assertFalse(acceptor.is_alive())
            self.assertFalse(any(worker.is_alive() for worker in workers), "traffic left target sockets open")
        return result

    def test_held_and_active_loads_verify_real_frames_and_close_sockets(self):
        for mode in ("held", "duplex", "slow"):
            with self.subTest(mode=mode):
                result = self.run_traffic(mode)
                self.assertEqual(result["connections"], 2)
                self.assertGreater(result["server_frames"], 0)
                if mode != "held":
                    self.assertGreater(result["verified_bytes"], 0)
                    self.assertGreater(result["latency_p95_upper_seconds"], 0)

    def test_bad_frames_and_partial_connection_setup_fail_closed(self):
        with self.assertRaises(RuntimeError):
            self.run_traffic("duplex", corrupt=True)
        with self.assertRaises(OSError):
            self.run_traffic("duplex", fail_connect=True)
    def test_transient_services_only_own_their_private_unit_and_cgroup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            commands = []
            running = False
            collision = False
            wrong_member = False
            def run(command, **_kwargs):
                nonlocal running
                commands.append(command)
                result = ""
                if command[0] == "systemd-run":
                    running = True
                elif command[:2] == ["systemctl", "stop"]:
                    running = False
                elif command[:2] == ["systemctl", "show"]:
                    unit = command[2]
                    group = root / "system.slice" / unit
                    group.mkdir(parents=True, exist_ok=True)
                    members = ("1234\n" if running or collision else "") + ("4321\n" if wrong_member else "")
                    (group / "cgroup.procs").write_text(members)
                    result = (f"LoadState=loaded\nActiveState=active\nMainPID=1234\nNRestarts=0\nControlGroup=/system.slice/{unit}\n"
                              if running or collision else "LoadState=not-found\n")
                elif command[0] == "ss":
                    result = 'LISTEN 0 4096 0.0.0.0:23457 0.0.0.0:* users:(("xray",pid=1234,fd=3))\n'
                return subprocess.CompletedProcess(command, 0, result, "")
            with mock.patch.object(comparison.subprocess, "run", side_effect=run):
                with comparison.TransientService(Path("/verified/xray"), Path("/private/config.json"),
                                                 23457, cgroup_root=root) as service:
                    service.check()
                    wrong_member = True
                    with self.assertRaises(RuntimeError):
                        service.check()
                    wrong_member = False
                self.assertFalse(running)
                starts = [command for command in commands if command[0] == "systemd-run"]
                self.assertEqual(len(starts), 1)
                self.assertIn("--property=User=xray-socks5", starts[0])
                self.assertIn("--property=StandardOutput=null", starts[0])
                self.assertIn("--property=StandardError=null", starts[0])
                stops = [command[2] for command in commands if command[:2] == ["systemctl", "stop"]]
                self.assertEqual(stops, [service.name])
                commands.clear()
                with self.assertRaises(InterruptedError):
                    with comparison.TransientService(Path("/verified/xray"), Path("/private/config.json"),
                                                     23457, cgroup_root=root) as interrupted_service:
                        raise InterruptedError("injected interruption")
                self.assertFalse(running)
                self.assertEqual([command[2] for command in commands if command[:2] == ["systemctl", "stop"]],
                                 [interrupted_service.name])
                commands.clear()
                collision = True
                with self.assertRaises(RuntimeError):
                    with comparison.TransientService(Path("/verified/xray"), Path("/private/config.json"),
                                                     23457, cgroup_root=root):
                        pass
                self.assertFalse(any(command[0] == "systemd-run" or command[:2] == ["systemctl", "stop"]
                                     for command in commands), "collision adopted or stopped another service")
    def test_summary_keeps_cpu_and_memory_accounting_separate(self):
        observations = [{"elapsed_seconds": second, "rss_kib": 100 + second,
                         "rss_anon_kib": 50 + second, "pss_kib": 80 + second,
                         "cgroup_current_bytes": 1000 + second * 10,
                         "cgroup_peak_bytes": 2000 + second * 10,
                         "cpu_usec": 100000 + second * 1000, "cgroup_oom": 0, "cgroup_oom_kill": 0}
                        for second in range(31)]
        result = comparison.summarize(observations, {"traffic_seconds": 30.01, "verified_bytes": 2048}, 100000)
        self.assertEqual(result["rss_median_kib"], 115)
        self.assertEqual(result["rss_anon_median_kib"], 65)
        self.assertEqual(result["pss_median_kib"], 95)
        self.assertEqual(result["cgroup_peak_bytes"], 2300)
        self.assertEqual(result["cpu_usec"], 30000)
        self.assertEqual(result["verified_bytes"], 2048)
        self.assertEqual(result["seconds"], 30.01)
        self.assertEqual(result["observation_count"], 31)

    def test_native_cli_refuses_execution_outside_disposable_ci(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "report.json"
            env = dict(os.environ)
            env.pop("GITHUB_ACTIONS", None)
            result = subprocess.run([sys.executable, str(ROOT / ".github/scripts/memory-compare.py"),
                                     "--binary", "/missing/xray", "--config", "/missing/config.json",
                                     "--target-port", "12345", "--output", str(output)],
                                    env=env, capture_output=True, text=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("disposable GitHub Actions", result.stderr)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
