#!/usr/bin/env python3
"""Compare default and 4 KiB buffers in owned transient Xray services in CI."""

import argparse
import bisect
import copy
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import pwd
import queue
import re
import signal
import socket
import stat
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import uuid

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests/protocol"))
import xray_mixed

_sampler_spec = importlib.util.spec_from_file_location("memory_sampler", Path(__file__).with_name("memory-sampler.py"))
sampler = importlib.util.module_from_spec(_sampler_spec)
_sampler_spec.loader.exec_module(sampler)

POLICY = {"levels": {"0": {"bufferSize": 4}}}
STAGES = {"idle": 0, "held1": 1, "held32": 32, "held128": 128,
          "duplex": 32, "slow": 32, "recovery": 0}
WINDOW_SECONDS = 30


def profile_config(source, profile, port):
    if profile not in ("baseline", "buffer4k"):
        raise ValueError("unknown comparison profile")
    config = copy.deepcopy(source)
    if len(config.get("inbounds", [])) != 1 or config.get("policy") not in (None, POLICY):
        raise ValueError("comparison requires the single-inbound default or 4 KiB configuration")
    config["inbounds"][0]["port"] = port
    config.pop("policy", None)
    if profile == "buffer4k":
        config["policy"] = copy.deepcopy(POLICY)
    return config


class TransientService:
    def __init__(self, binary, config, port, cgroup_root=Path("/sys/fs/cgroup")):
        self.binary, self.config, self.port = binary, config, port
        self.cgroup_root = Path(cgroup_root)
        self.name = "xray-memory-" + uuid.uuid4().hex + ".service"
        self.owned = False
        self.pid = None
        self.cgroup = None

    def properties(self):
        result = subprocess.run(["systemctl", "show", self.name, "--no-pager",
                                 "--property=LoadState,ActiveState,MainPID,NRestarts,ControlGroup,Result,ExecMainStatus"],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=15)
        values = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
        if result.returncode and values.get("LoadState") != "not-found":
            raise RuntimeError("could not observe the owned comparison service")
        return values

    def __enter__(self):
        if self.properties().get("LoadState") != "not-found":
            raise RuntimeError("comparison transient unit name already exists")
        subprocess.run([str(self.binary), "run", "-test", "-c", str(self.config)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=15)
        settings = ["Type=exec", "User=xray-socks5", "Group=xray-socks5", "Restart=no",
                    "MemoryAccounting=yes", "CPUAccounting=yes", "TimeoutStopSec=10s",
                    "KillMode=control-group", "StandardOutput=null", "StandardError=null",
                    "NoNewPrivileges=yes", "ProtectSystem=strict", "ProtectHome=yes", "PrivateTmp=yes",
                    "PrivateDevices=yes", "ProtectKernelTunables=yes", "ProtectKernelModules=yes",
                    "ProtectControlGroups=yes", "LockPersonality=yes", "SystemCallArchitectures=native",
                    "CapabilityBoundingSet=", "AmbientCapabilities=", "WorkingDirectory=/"]
        self.owned = True
        try:
            subprocess.run(["systemd-run", "--quiet", "--collect", "--unit=" + self.name]
                           + ["--property=" + value for value in settings]
                           + [str(self.binary), "run", "-c", str(self.config)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=20)
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                values = self.properties()
                if values.get("LoadState") == "not-found" or values.get("ActiveState") in ("failed", "inactive"):
                    raise RuntimeError("comparison service exited before readiness (result="
                                       + values.get("Result", "unknown") + ", status="
                                       + values.get("ExecMainStatus", "unknown") + ")")
                if values.get("ActiveState") == "active" and int(values.get("MainPID", "0")) > 0:
                    self.pid = int(values["MainPID"])
                    group = Path(values["ControlGroup"])
                    if not group.is_absolute() or ".." in group.parts:
                        raise RuntimeError("comparison service has an invalid cgroup")
                    self.cgroup = self.cgroup_root / str(group).lstrip("/")
                    self.check()
                    listeners = subprocess.run(["ss", "-H", "-ltnp", "sport = :" + str(self.port)],
                                               capture_output=True, text=True, check=True, timeout=5).stdout.splitlines()
                    if len(listeners) == 1 and f"pid={self.pid}," in listeners[0]:
                        return self
                time.sleep(0.1)
            raise TimeoutError("comparison listener did not become ready")
        except BaseException:
            self.close()
            raise

    def check(self):
        values = self.properties()
        if (values.get("ActiveState") != "active" or int(values.get("MainPID", "0")) != self.pid
                or values.get("NRestarts") != "0"):
            raise RuntimeError("comparison service stopped, changed process or restarted")
        members = {int(value) for value in (self.cgroup / "cgroup.procs").read_text().split()}
        if members != {self.pid} or os.getpid() in members:
            raise RuntimeError("comparison cgroup does not contain exactly the Xray process")

    def close(self):
        if not self.owned:
            return
        if self.properties().get("LoadState") != "not-found":
            result = subprocess.run(["systemctl", "stop", self.name], stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL, timeout=20)
            values = self.properties()
            if result.returncode and values.get("LoadState") != "not-found":
                raise RuntimeError("comparison could not stop its owned transient service")
            if values.get("LoadState") != "not-found" and values.get("ActiveState") not in ("inactive", "failed"):
                raise RuntimeError("comparison transient service survived cleanup")
            subprocess.run(["systemctl", "reset-failed", self.name], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=10)
        if self.cgroup is not None:
            try:
                remaining = (self.cgroup / "cgroup.procs").read_text().split()
            except FileNotFoundError:
                remaining = []
            if remaining:
                raise RuntimeError("comparison processes survived transient service cleanup")
        self.owned = False

    def __exit__(self, *_error):
        self.close()


class TunnelLoad:
    latency_bounds = tuple(0.001 * 2 ** index for index in range(16))
    payload = bytes(range(256)) * 256

    def __init__(self, proxy, target, credentials, count, mode):
        if count < 0 or mode not in ("held", "duplex", "slow"):
            raise ValueError("invalid comparison workload")
        self.proxy, self.target, self.credentials = proxy, target, credentials
        self.count, self.mode = count, mode
        self.sessions = []
        self.threads = []
        self.stop = threading.Event()
        self.go = threading.Event()
        self.ready = threading.Barrier(count + 1, timeout=10)
        self.errors = queue.Queue()
        self.started = None
        self.finished = None

    def __enter__(self):
        deadline = time.monotonic() + 30
        try:
            for index in range(self.count):
                if time.monotonic() >= deadline:
                    raise TimeoutError("comparison tunnel setup exceeded its deadline")
                connect = xray_mixed.socks5_connect if index % 2 == 0 else xray_mixed.http_connect
                sock = connect(self.proxy, self.target, self.credentials)
                session = {"socket": sock, "cid": 100000 + index, "nonce": os.urandom(8),
                           "server_seq": 0, "sequence": 1, "frames": 0, "verified_bytes": 0,
                           "latencies": [0] * len(self.latency_bounds)}
                self.sessions.append(session)
                sock.settimeout(5)
                if self.mode == "slow":
                    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 32768)
                sock.sendall(xray_mixed.make_frame(ord("H"), session["cid"], 0, session["nonce"], b"memory"))
                sock.sendall(xray_mixed.make_frame(ord("C"), session["cid"], 0, session["nonce"], b"ready"))
                self._echo(session, 0, b"ready")
            return self
        except BaseException:
            self.close()
            raise

    def start(self):
        if self.started is not None:
            raise ValueError("comparison workload already started")
        for session in self.sessions:
            worker = threading.Thread(target=self._worker, args=(session,), daemon=True)
            self.threads.append(worker)
            worker.start()
        self.ready.wait()
        self.started = time.monotonic()
        self.go.set()

    def _server(self, session, frame):
        xray_mixed.validate_server_frame(frame, session["cid"], session["nonce"], session["server_seq"])
        session["server_seq"] += 1

    def _echo(self, session, sequence, payload):
        deadline = time.monotonic() + 5
        while True:
            frame = xray_mixed.read_frame(session["socket"], deadline)
            kind, ids, nonce, echoed = frame
            if kind == ord("S"):
                self._server(session, frame)
            elif kind == ord("E") and ids == (session["cid"], sequence) and nonce == session["nonce"] and echoed == payload:
                return
            else:
                raise RuntimeError("comparison echo frame failed identity, sequence or payload verification")

    def _worker(self, session):
        try:
            self.ready.wait()
            self.go.wait()
            while not self.stop.is_set():
                if self.mode == "held":
                    self._server(session, xray_mixed.read_frame(session["socket"], time.monotonic() + 5))
                    continue
                sequence = session["sequence"]
                sent = []
                for index in range(8):
                    sent.append(time.monotonic())
                    session["socket"].sendall(xray_mixed.make_frame(
                        ord("C"), session["cid"], sequence + index, session["nonce"], self.payload))
                if self.mode == "slow":
                    self.stop.wait(0.05)
                for index, started in enumerate(sent):
                    self._echo(session, sequence + index, self.payload)
                    latency = time.monotonic() - started
                    bucket = min(bisect.bisect_left(self.latency_bounds, latency), len(self.latency_bounds) - 1)
                    session["latencies"][bucket] += 1
                    session["verified_bytes"] += 2 * len(self.payload)
                    session["frames"] += 1
                session["sequence"] += len(sent)
        except BaseException as error:
            if not self.stop.is_set():
                self.errors.put(type(error).__name__)

    def check(self):
        if not self.errors.empty() or any(not worker.is_alive() for worker in self.threads):
            raise RuntimeError("comparison framed tunnel failed")

    def close(self):
        self.finished = time.monotonic()
        self.stop.set()
        self.go.set()
        self.ready.abort()
        for session in self.sessions:
            try:
                session["socket"].shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            session["socket"].close()
        for worker in self.threads:
            worker.join(6)
        if any(worker.is_alive() for worker in self.threads):
            raise RuntimeError("comparison could not stop its traffic workers")

    def __exit__(self, error_type, *_error):
        self.close()
        if error_type is None and not self.errors.empty():
            raise RuntimeError("comparison framed tunnel failed")

    def stats(self):
        if self.started is None or self.finished is None or not self.errors.empty():
            raise RuntimeError("comparison traffic did not finish successfully")
        if any(session["server_seq"] == 0 or (self.mode != "held" and session["frames"] == 0)
               for session in self.sessions):
            raise RuntimeError("comparison requires bidirectional progress from every tunnel")
        buckets = [sum(session["latencies"][index] for session in self.sessions)
                   for index in range(len(self.latency_bounds))]
        frames = sum(buckets)
        percentile = 0
        total = 0
        for bound, count in zip(self.latency_bounds, buckets):
            total += count
            if frames and total >= math.ceil(frames * 0.95):
                percentile = bound
                break
        return {"connections": len(self.sessions), "mode": self.mode, "completed_frames": frames,
                "verified_bytes": sum(session["verified_bytes"] for session in self.sessions),
                "server_frames": sum(session["server_seq"] for session in self.sessions),
                "latency_p95_upper_seconds": percentile,
                "traffic_seconds": self.finished - self.started}


def observe(reader, check, duration=WINDOW_SECONDS, interval=1, clock=time.monotonic, wait=time.sleep):
    if duration <= 0 or interval <= 0:
        raise ValueError("observation window and interval must be positive")
    start = clock()
    observations = []
    target = start
    while True:
        wait(max(0, target - clock()))
        if clock() - target >= interval:
            raise TimeoutError("comparison missed its sampling cadence")
        check()
        values = reader.snapshot()
        sampled_at = clock()
        if sampled_at - target >= interval:
            raise TimeoutError("comparison observation exceeded its sampling interval")
        values["elapsed_seconds"] = sampled_at - start
        if values["cgroup_oom"] or values["cgroup_oom_kill"]:
            raise RuntimeError("comparison observed an OOM event")
        observations.append(values)
        if target >= start + duration:
            return observations
        target = min(start + duration, target + interval)


def assess(trials, architecture):
    expected = {(pair, profile) for pair in (1, 2, 3) for profile in ("baseline", "buffer4k")}
    if architecture not in ("amd64", "arm64") or len(trials) != 6:
        raise ValueError("comparison requires six trials on a supported architecture")
    if {(trial["pair"], trial["profile"]) for trial in trials} != expected:
        raise ValueError("comparison trial pairs are incomplete")
    for trial in trials:
        if trial["restarts"] != 0 or set(trial["stages"]) != set(STAGES):
            raise ValueError("comparison lost a stage or the service restarted")
        for name, stage in trial["stages"].items():
            for key in ("seconds", "observation_count", "rss_median_kib", "rss_anon_median_kib",
                        "cgroup_peak_bytes", "cpu_usec", "verified_bytes", "oom", "oom_kill"):
                if not math.isfinite(stage[key]) or stage[key] < 0:
                    raise ValueError("comparison metric is missing, negative or non-finite")
            if (not WINDOW_SECONDS <= stage["seconds"] < WINDOW_SECONDS + 1
                    or stage["observation_count"] != WINDOW_SECONDS + 1
                    or stage["oom"] != 0 or stage["oom_kill"] != 0):
                raise ValueError("comparison observation window or OOM evidence failed")
            if name in ("duplex", "slow") and (stage["verified_bytes"] <= 0 or stage["cpu_usec"] <= 0):
                raise ValueError("active comparison needs verified traffic and CPU observations")

    memory = []
    regressions = []
    benefit = False
    for name in STAGES:
        for metric in ("rss_median_kib", "rss_anon_median_kib", "cgroup_peak_bytes"):
            values = {profile: [trial["stages"][name][metric] for trial in trials
                                if trial["profile"] == profile]
                      for profile in ("baseline", "buffer4k")}
            baseline = statistics.median(values["baseline"])
            candidate = statistics.median(values["buffer4k"])
            spread = max(max(series) - min(series) for series in values.values())
            saved = baseline - candidate
            memory.append({"stage": name, "metric": metric, "baseline_median": baseline,
                           "candidate_median": candidate, "repeat_spread": spread, "saved": saved})
            if saved < -spread:
                regressions.append(name + ":" + metric)
            if name in ("held128", "duplex", "slow") and metric != "rss_median_kib" and saved > spread:
                benefit = True

    performance = []
    unstable = []
    for name in ("duplex", "slow"):
        observations = {}
        for profile in ("baseline", "buffer4k"):
            ordered = sorted((trial for trial in trials if trial["profile"] == profile), key=lambda trial: trial["pair"])
            stages = [trial["stages"][name] for trial in ordered]
            rates = [stage["verified_bytes"] / stage["seconds"] for stage in stages]
            costs = [stage["cpu_usec"] / stage["verified_bytes"] for stage in stages]
            observations[profile] = {"throughput": statistics.median(rates),
                                     "cpu_per_byte": statistics.median(costs), "rates": rates, "costs": costs}
        baseline, candidate = observations["baseline"], observations["buffer4k"]
        throughput_ratio = candidate["throughput"] / baseline["throughput"]
        cpu_ratio = candidate["cpu_per_byte"] / baseline["cpu_per_byte"]
        paired_rates = [candidate / baseline for baseline, candidate in zip(baseline["rates"], candidate["rates"])]
        paired_costs = [candidate / baseline for baseline, candidate in zip(baseline["costs"], candidate["costs"])]
        performance.append({"stage": name, "throughput_ratio": throughput_ratio, "cpu_per_byte_ratio": cpu_ratio,
                            "paired_throughput_ratios": paired_rates, "paired_cpu_per_byte_ratios": paired_costs})
        if throughput_ratio < 0.95 or cpu_ratio > 1.10:
            regressions.append(name + ":performance")
        elif min(paired_rates) < 0.95 or max(paired_costs) > 1.10:
            unstable.append(name + ":inconsistent-pairs")
    eligible = not regressions and not unstable and (benefit or architecture == "arm64")
    outcome = ("regression" if regressions else "inconclusive" if unstable else "benefit" if benefit else
               "no-regression" if architecture == "arm64" else "no-demonstrated-benefit")
    return {"outcome": outcome, "eligible": eligible, "memory_benefit": benefit,
            "regressions": regressions, "unstable": unstable, "memory": memory, "performance": performance}


def summarize(observations, traffic, initial_cpu):
    result = dict(traffic, seconds=traffic["traffic_seconds"], observation_count=len(observations),
                  cpu_usec=observations[-1]["cpu_usec"] - initial_cpu,
                  cgroup_peak_bytes=max(row["cgroup_peak_bytes"] for row in observations),
                  oom=max(row["cgroup_oom"] for row in observations),
                  oom_kill=max(row["cgroup_oom_kill"] for row in observations), observations=observations)
    for source, destination in (("rss_kib", "rss_median_kib"), ("rss_anon_kib", "rss_anon_median_kib"),
                                ("pss_kib", "pss_median_kib"), ("cgroup_current_bytes", "cgroup_median_bytes")):
        result[destination] = statistics.median(row[source] for row in observations)
    return result


def run_trial(binary, config, target_port, pair, profile, gid, port):
    with tempfile.TemporaryDirectory(prefix="xray-memory-", dir="/run") as directory:
        work = Path(directory)
        os.chown(work, 0, gid)
        work.chmod(0o750)
        candidate = work / "config.json"
        candidate.write_text(json.dumps(profile_config(config, profile, port)))
        os.chown(candidate, 0, gid)
        candidate.chmod(0o640)
        account = config["inbounds"][0]["settings"]["accounts"][0]
        credentials = xray_mixed.Credentials(account["user"], account["pass"])
        stages = {}
        with TransientService(binary, candidate, port) as service:
            environment = (Path("/proc") / str(service.pid) / "environ").read_bytes().split(b"\0")
            knobs = {b"GOGC", b"GOMEMLIMIT", b"GOMAXPROCS", b"XRAY_RAY_BUFFER_SIZE", b"xray.ray.buffer.size"}
            if any(item.split(b"=", 1)[0] in knobs for item in environment):
                raise RuntimeError("comparison inherited an unexpected runtime tuning variable")
            with sampler.SnapshotReader(service.pid, service.cgroup) as reader:
                time.sleep(5)
                for name, count in STAGES.items():
                    print(f"memory-comparison: pair={pair} profile={profile} stage={name}", flush=True)
                    reader.reset()
                    mode = name if name in ("duplex", "slow") else "held"
                    with TunnelLoad(xray_mixed.Endpoint("127.0.0.1", port),
                                    xray_mixed.Endpoint("192.0.2.1", target_port), credentials, count, mode) as load:
                        initial_cpu = reader.snapshot()["cpu_usec"]
                        load.start()
                        def check():
                            service.check()
                            load.check()
                        observations = observe(reader, check)
                    stages[name] = summarize(observations, load.stats(), initial_cpu)
                service.check()
        return {"pair": pair, "profile": profile, "restarts": 0, "stages": stages}


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def interrupted(signum, _frame):
    for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, signal.SIG_IGN)
    raise InterruptedError(f"comparison interrupted by signal {signum}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--target-port", required=True, type=int)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.geteuid() != 0:
        raise RuntimeError("native comparisons run only as root in disposable GitHub Actions environments")
    os.umask(0o077)
    for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, interrupted)
    architecture = {"x86_64": "amd64", "aarch64": "arm64"}.get(os.uname().machine)
    if architecture is None or not 1 <= args.target_port <= 65535:
        raise ValueError("unsupported architecture or invalid target port")
    if args.output.exists() or args.output.is_symlink():
        raise ValueError("comparison output already exists")
    user = pwd.getpwnam("xray-socks5")
    if user.pw_uid == 0:
        raise ValueError("comparison runtime account must not be root")
    for path, mode in ((args.binary, 0o755), (args.config, 0o640)):
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) != mode:
            raise ValueError("comparison input ownership or mode is unsafe")
    original = args.config.read_bytes()
    config = json.loads(original)
    accounts = config["inbounds"][0]["settings"]["accounts"]
    if len(accounts) != 1 or not re.fullmatch(r"[A-Za-z0-9_-]{3,32}", accounts[0]["user"]) \
            or not re.fullmatch(r"[A-Za-z0-9._~-]{12,128}", accounts[0]["pass"]):
        raise ValueError("comparison requires the installed single-account configuration")
    binary_hash = sha256(args.binary)
    version_output = subprocess.run([str(args.binary), "version"], capture_output=True,
                                    text=True, check=True, timeout=5).stdout
    version = re.match(r"Xray ([0-9.]+)\b", version_output)
    if version is None:
        raise ValueError("could not identify the installed Xray version")
    with socket.socket() as reservation:
        reservation.bind(("0.0.0.0", 0))
        port = reservation.getsockname()[1]
    trials = []
    started = time.monotonic()
    for pair in (1, 2, 3):
        profiles = ("baseline", "buffer4k") if pair % 2 else ("buffer4k", "baseline")
        for profile in profiles:
            if args.config.read_bytes() != original or sha256(args.binary) != binary_hash:
                raise RuntimeError("comparison inputs changed between trials")
            trials.append(run_trial(args.binary, config, args.target_port, pair, profile, user.pw_gid, port))
    if args.config.read_bytes() != original or sha256(args.binary) != binary_hash:
        raise RuntimeError("comparison changed or lost its original inputs")
    decision = assess(trials, architecture)
    report = {"format_version": 1, "architecture": architecture, "kernel": os.uname().release,
              "xray_version": version.group(1), "binary_sha256": binary_hash,
              "elapsed_seconds": time.monotonic() - started, "warmup_seconds": 5,
              "window_seconds": WINDOW_SECONDS, "sampling_interval_seconds": 1,
              "payload_bytes": len(TunnelLoad.payload), "pipeline_frames": 8,
              "slow_read_delay_seconds": 0.05, "slow_receive_buffer_request_bytes": 32768,
              "profiles": {"baseline": "upstream-default", "buffer4k": {"buffer_size_kib": 4}},
              "trials": trials, "decision": decision}
    with args.output.open("x") as output:
        json.dump(report, output, sort_keys=True, allow_nan=False)
        output.write("\n")
    print(f"memory-comparison: architecture={architecture} outcome={decision['outcome']} eligible={str(decision['eligible']).lower()}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        print("memory-comparison: " + str(error), file=sys.stderr)
        sys.exit(1)
