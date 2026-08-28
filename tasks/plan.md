# Implementation Plan: socks5.sh

Spec: `SPEC.md` (frozen). Engine 3proxy 0.9.9.0 @ `da99424eac4092e3722f1a5b1844cfe80478f580`.
Protocol scope frozen: SOCKS5 only, RFC 1929 auth, CONNECT only. SOCKS4/4a/4.5, unauthenticated
SOCKS5, BIND, UDP ASSOCIATE must all be rejected. No engine re-evaluation.

Task list: `tasks/todo.md` (markdown checklist, the default target).

---

# Round 10 plan: delete the unreachable firewall subsystem

## Overview

v1 made the host firewall read-only: `s5_install_steps` calls `s5_firewall_guidance`, which only
prints the command for the detected backend. The mutating half of the subsystem is now unreachable
from every command, but it is still ~250 lines of production code with tests pointing at it. That
is actively misleading — a reader (or a future change) can reasonably conclude the installer still
opens ports. Delete it, and leave behind a guard so it cannot return silently.

## Architecture decisions

- **Keep** `s5_firewall_detect`, `s5_firewall_manual_hint`, `s5_firewall_guidance`. These are the
  read-only path and are exercised by `test_install.sh`.
- **Delete** `s5_maybe_open_firewall`, `s5_firewall_open`, `s5_firewall_close`,
  `s5_firewall_rule_still_there`, `s5_ufw_rule_present`, `s5_iptables_rule_present`,
  `s5_firewalld_zone`, and `S5_FW_ZONE`.
- **Delete the `firewall` and `firewall_zone` state keys.** No released version ever wrote them
  (CI has never run, nothing is published), so there is no migration to preserve. Dropping them
  from `S5_STATE_KEYS_ONCE` means a hand-written state file containing one is rejected as an
  unknown key — the existing fail-closed behaviour, which is correct.
- **Consumer sites become unconditional:** `status`, `show`, `print_summary` and `uninstall` report
  "not modified by this script" with no branching, and `s5_teardown` loses its firewall block.
- **Add a structural guard test** asserting the deleted names appear nowhere in `socks5.sh`. Without
  it, re-adding a mutating helper is invisible to the suite.

## Task list

### Task 1: Remove the state-driven firewall reporting and teardown

**Description:** Take out the consumer side first, so nothing reads a `firewall` state key by the
time the helpers go. Drop both keys from the known-key list and the `firewall)` validation branch;
remove the `s5_teardown` firewall block; collapse the firewall lines in `s5_print_summary`,
`s5_cmd_status`, `s5_cmd_show` and `s5_cmd_uninstall` to a constant statement.

**Acceptance criteria:**
- [ ] `firewall` and `firewall_zone` are not valid state keys; a state file containing either is
      rejected as an unknown key and nothing is deleted.
- [ ] `status`, `show` and the install summary state that the firewall was not modified, with no
      backend query and no `s5_state_get firewall` call.
- [ ] `uninstall` lists no firewall resource and runs no firewall command.

**Verification:** `sh tests/run.sh test_state`, `test_audit2`, `test_lifecycle`, `test_install`.

**Dependencies:** None. **Scope:** M (1 production file + 3 test files).

### Task 2: Delete the mutating helpers themselves

**Description:** Remove the eight now-unreferenced definitions and `S5_FW_ZONE`, and prune the
`test_install.sh` blocks that exercise rule creation, ambiguous-mutation compensation, pre-existing
rule ownership and firewalld zone ordering. Keep the detection and guidance coverage.

**Acceptance criteria:**
- [ ] None of the eight deleted names appears anywhere in `socks5.sh`.
- [ ] `s5_firewall_detect`, `s5_firewall_manual_hint` and `s5_firewall_guidance` remain and stay
      covered.
- [ ] No test references a deleted function.

**Verification:** `sh tests/run.sh test_install`, then the full suite.

**Dependencies:** Task 1. **Scope:** M (1 production file + 1 test file).

### Task 3: Guard, verify, and record

**Description:** Add the structural guard that the mutating names stay gone, run the full matrix,
and update `tasks/todo.md`. Confirm `SPEC.md` §7.1/§12 and the README still match the code.

**Acceptance criteria:**
- [ ] A test fails if any deleted helper is reintroduced into `socks5.sh`.
- [ ] Full suite green under `sh`, `dash`, `busybox sh`, `bash`; zero failures, zero skips.
- [ ] `sh -n` / `dash -n` / `busybox sh -n` clean on every shell file; Python tools compile; CI
      YAML parses with every job holding a timeout.

**Verification:** the four-shell suite, the three-shell syntax sweep, `py_compile`, the PyYAML
structural check, and a mutation proving the new guard can fail.

**Dependencies:** Tasks 1–2. **Scope:** S.

### Checkpoint: after Task 3
- [ ] Suite green on four shells with no reduction in real coverage.
- [ ] No real service, account, firewall rule, package, port or system path touched.
- [ ] No commit, no push.

## Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Deleting a helper that is still reachable | High | Reference count every name first (done: only `detect`, `manual_hint`, `guidance` have live callers) |
| Losing genuine coverage along with the deleted tests | Med | Keep every detection/guidance assertion; add the structural guard; compare assertion counts before and after and account for the delta |
| A state file from an older build becoming unloadable | None | Nothing is published and CI has never run, so no such file exists |

## Open questions — blocked on the user, not startable

1. **Where does this get published?** Needed before CI can run at all (no remote is configured) and
   before the README's download recipe can stop being a template with a placeholder. This gates the
   entire "prove it on a real host" phase.

**Decided 2026-08-27 (recorded, no longer open):**

2. ~~Should automatic firewall opening come back?~~ **No — and the read-only remnant was removed
   too.** Firewall functionality is gone entirely: no detection, no guidance, no queries. The
   operator opens the port themselves; the README documents example commands as operator
   documentation only.
3. ~~Keep `status`, `show`, `restart` and the menu?~~ **Yes, retained** as part of the product.

---

## Dev-machine constraints (probed 2026-08-23, read-only)

Prohibited here: `sudo`, installing/removing packages, creating system accounts, starting or
modifying services, firewall changes, opening listening ports, writing real `/etc`, `/usr/local`,
`/var/lib`, and automatic `git commit`.

Tooling actually present: `dash`, `busybox`, `python3`, `git`, `curl`.
**Absent, and we may not install it:** `shellcheck`, `shfmt`, `bats`, `make`, `gcc`, `docker`,
`podman` (no container runtime is usable).

Three consequences that shape every task below:

1. **No test framework.** Tests are plain POSIX `sh` with a tiny local assert helper — which matches
   SPEC §13 ("shell-based, no framework dependency"). `shellcheck` runs in CI only.
2. **No local compile.** Task 4's real build cannot run here. Locally it is verified with `git`/`make`
   stubs on `PATH`; the genuine compile happens in CI.
3. **No local containers.** The 16-cell matrix and the live protocol suite are **CI-only**. Everything
   else must be verifiable on this machine via fixtures, stubs, and temp dirs.

**Sandboxing contract (applies to every task).** `socks5.sh` must read all filesystem roots and all
privileged executables through overridable variables — `S5_PREFIX`, `S5_SYSCONFDIR`, `S5_STATEDIR`,
`S5_SERVICE_MGR`, `S5_FIREWALL_CMD`, `S5_USERADD` and similar. Defaults are the real paths from
SPEC §4; tests point them at `mktemp -d` and at stub executables that record their argv to a
transcript file. This is the single design decision that makes the whole suite runnable without root,
and it must be established in Task 1 rather than retrofitted.

## Final locked decisions (pre-implementation sync)

These were confirmed immediately before implementation and override anything below that conflicts.
`SPEC.md` is unchanged by this section.

1. **Test overrides only under `S5_TEST_MODE=1`.** Every coverage/override variable is inert unless
   `S5_TEST_MODE` is exactly `1`.
2. **`S5_TEST_ROOT` is mandatory in test mode**, and the script verifies a `.s5-test-root` sentinel
   file inside it before touching anything.
3. **All test paths and stubs live under `S5_TEST_ROOT`.** Nothing is written outside it.
4. **Production mode is fail-closed:** if any coverage/override variable is present while
   `S5_TEST_MODE` is not `1`, the script exits immediately with a non-zero status.
5. **Self-test URL is fixed** to `https://example.com/`. Not configurable.
6. **OpenRC writes no ordinary log files** — output goes to syslog via `logger`.
7. **OpenRC does not use `need net`.**
8. **ARM64 CI uses GitHub's native `ubuntu-24.04-arm` runner.**
9. **QEMU is a fallback only**, used when native ARM64 runners are unavailable.



- **One file, pure-function core.** Validators, generators, and renderers take arguments and write to
  stdout. No global mutation, no I/O. Only the flow functions (Tasks 6–7) touch the filesystem.
- **Detection is fixture-driven.** Every `detect_*` function accepts an `os-release` path and an arch
  string as parameters, never reading `/etc/os-release` directly, so all 12 target and refusal cases
  are unit-testable.
- **Rendering is golden-tested.** Config text is compared byte-for-byte against fixtures, plus a
  denylist assertion over SPEC §6. This is how the protocol boundary is enforced statically; the
  runtime half is Task 8.
- **Two distinct protocol clients, deliberately.** SPEC §11 mandates `curl --config -` for the
  *installer's* runtime self-test and forbids hand-rolling a handshake there. The *CI test suite* is
  separate and needs raw frames for the no-auth-offer, BIND, and UDP ASSOCIATE cases, so it carries a
  `python3` probe. **Test-only tooling never enters `socks5.sh`'s dependency list.**

## Dependency graph and order

```
T1 skeleton + harness + sandboxing contract
 └── T2 detection (OS/arch/init/pkgmgr/deps)
      ├── T3 interactive input + generators + validation
      │    └── T5 rendering (config, creds, unit, initscript)
      │         └── T6 install flow, atomic write, firewall, state, cleanup
      │              └── T7 status / show / restart / uninstall / idempotency
      │                   └── T8 protocol suite + matrix + README + LICENSE
      └── T4 fetch + verify commit + build      (parallel with T3/T5; T6 consumes it)
```

Parallelizable: **T4 alongside T3–T5**. README and LICENSE drafting may start any time after T1.
Strictly sequential: T6 → T7 → T8 (each consumes the previous one's state model).
T4 is scheduled early despite T6 being its only consumer, because commit-pinning and the "never run
upstream installers" guarantee are the highest-risk mechanics in the project — fail fast.

---

## Task 1 — Project skeleton, POSIX constraints, test harness

**Objective.** Create the single-file skeleton, the subcommand dispatcher, the redaction-safe logging
helpers, and the sandboxing contract, plus a dependency-free test runner. No product behaviour.

**Files.** `socks5.sh` · `tests/run.sh` · `tests/lib/assert.sh` · `tests/lib/stub.sh` ·
`tests/unit/test_skeleton.sh`

**Prerequisites.** None.

**Implementation boundaries.** `set -eu` and `umask 077` at entry. Dispatcher accepts exactly
`install|status|show|restart|uninstall` plus no-arg mode; every handler is a stub exiting 3
("not implemented"). Define the `S5_*` override variables with real defaults. `log()` must route
through a redaction filter. No network, no privileged call, no filesystem write outside `mktemp`.

**Acceptance criteria.**
- `dash -n socks5.sh` and `busybox sh -n socks5.sh` both exit 0.
- A banned-construct check finds no `[[`, `==` inside `[`, arrays, `function` keyword, `source`,
  `$'…'`, `echo -e`, or process substitution.
- `tests/run.sh` discovers and runs `tests/unit/*.sh`, reports pass/fail counts, exits non-zero on
  any failure.
- `sh socks5.sh badsubcommand` exits non-zero with usage; no-arg mode is reachable.
- `stub.sh` can place a fake executable on `PATH` and capture its argv to a transcript.

**Testing.** `sh tests/run.sh`; both syntax checks; a deliberately failing assertion proves the
runner reports failure rather than passing silently.

**Excluded.** Detection, prompts, rendering, build, install, uninstall, firewall, README, CI config.

---

## Task 2 — OS, version, arch, init, package manager, privilege and dependency detection

**Objective.** Map `/etc/os-release` + `uname -m` onto the SPEC §3 support matrix, including the
RHEL/Rocky/Alma refusal path, and compute the dependency list without installing anything.

**Files.** `socks5.sh` · `tests/unit/test_detect.sh` · `tests/fixtures/os-release/*` (12+ fixtures)

**Prerequisites.** T1.

**Implementation boundaries.** Pure functions taking a fixture path and an arch string. They return
codes and print machine-readable fields; they never invoke a package manager, never escalate, never
read the real `/etc/os-release` when a path is supplied. Dependency *lists* are produced, not
installed.

**Acceptance criteria.**
- All 8 supported targets resolve to correct pkg manager + init: Ubuntu 22.04/24.04, Debian 12/13,
  Alpine 3.20/3.24, CentOS Stream 9/10.
- `ID=rhel`, `rocky`, `almalinux` exit non-zero with the "likely compatible, not supported" message
  and **never** proceed — `ID_LIKE=rhel` alone never authorizes an install.
- Unknown or too-old OS exits non-zero naming the detected `ID` and `VERSION_ID`.
- Arch maps `x86_64|amd64`→amd64 and `aarch64|arm64`→arm64; anything else is a hard error.
- Dependency list matches SPEC §8 per manager, with `curl` added only when absent.
- Root/non-root is detected and reported without attempting escalation.

**Testing.** Fixture table test over every case, asserting exit code and message. Runs unprivileged.

**Excluded.** Installing dependencies, running any package manager, prompting, building.

---

## Task 3 — Interactive input, port checking, generation, validation

**Objective.** Implement the SPEC §5 prompt sequence with validators and CSPRNG generators, all
testable without a TTY and without binding a port.

**Files.** `socks5.sh` · `tests/unit/test_input.sh` · `tests/unit/test_generate.sh`

**Prerequisites.** T1, T2.

**Implementation boundaries.** Validators are pure. The port-availability probe sits behind one
injectable function so tests stub it — **no test may bind a port**. Password reading takes an fd so
tests feed a pipe; `stty -echo` is applied only when stdin is a TTY. Generators draw from
`/dev/urandom` and **must reject modulo bias** (reject-and-resample, not `% 65`).

**Acceptance criteria.**
- Port: empty → random in 20000–60000; explicit → accepted only in 1024–65535; occupied → rejected
  via the stubbed probe.
- Username: empty → generated; charset `[A-Za-z0-9_-]`, length 3–32 enforced.
- Password: empty → generated **exactly 32** chars; charset `[A-Za-z0-9._~-]`; length 12–128;
  entered twice with mismatch rejected.
- Every rejection names the failing rule and **never echoes the candidate secret**.
- 10 000 generated passwords: all are 32 chars, use only the allowed charset, cover every character
  in it, and show no modulo-bias skew.
- No generated or entered secret appears in `argv` of any invoked command.

**Testing.** Piped stdin cases; stubbed port probe; a bias/coverage statistical test; a transcript
assertion that no stub ever received a secret in argv.

**Excluded.** Writing config or credential files, real port binding, service or firewall interaction.

---

## Task 4 — Pinned-commit fetch, verification, and source build

**Objective.** Clone the pinned commit, prove `HEAD` matches exactly, build via
`make -f Makefile.Linux`, and install only `bin/3proxy` — never running any upstream installer.

**Files.** `socks5.sh` · `tests/unit/test_build_guards.sh` · `tests/stubs/git` · `tests/stubs/make`

**Prerequisites.** T1, T2.

**Implementation boundaries.** Clone into `mktemp -d`. Verify with `git rev-parse HEAD` string-equal
to the pinned SHA. Build from the repo root. Copy **only** `bin/3proxy` to `$S5_PREFIX`. `make
install`, `scripts/postinstall.sh`, and any upstream service installer are never invoked. Temp tree
removed on every exit path. Real compilation is CI-only — this machine has no `make`/`gcc`.

**Acceptance criteria.**
- Commit mismatch → non-zero exit, temp dir removed, **nothing** written to `$S5_PREFIX`.
- Success path → `$S5_PREFIX/3proxy` exists, mode 0755, and only that one file was copied.
- Transcript proves `make` was called only as `-f Makefile.Linux`, and that `make install` and
  `postinstall.sh` were never called.
- Abort at any stage leaves no temp directory behind.
- Works for amd64 and arm64 without arch-specific build flags (CI-verified).

**Testing.** Locally: `git`/`make` stubs simulating match, mismatch, clone failure, and build
failure, with `$S5_PREFIX` in a temp dir. In CI: one real build per architecture.

**Excluded.** Local compilation; writing to real `/usr/local`; service creation; config rendering.

---

## Task 5 — Config, credentials, service account and unit/init-script rendering

**Objective.** Render every artifact as text on stdout: `3proxy.cfg`, `users.cfg`, the systemd unit,
the OpenRC script, and the service-account creation commands.

**Files.** `socks5.sh` · `tests/unit/test_render.sh` · `tests/golden/3proxy.cfg` ·
`tests/golden/users.cfg` · `tests/golden/socks5-manager.service` · `tests/golden/openrc-init`

**Prerequisites.** T1, T3.

**Implementation boundaries.** Pure text generation — no file writes, no `chown`, no user creation.
Account creation is *rendered as commands* for Task 6 to execute. Renderers must refuse to emit a
password containing an out-of-charset byte.

**Acceptance criteria.**
- `3proxy.cfg` matches golden exactly, including `socks -4 -u2 -p<port> -i0.0.0.0`.
- `users.cfg` is exactly one line, `<username>:CL:<password>`, and contains **no `users` directive**.
- The SPEC §6 denylist matches nothing in any rendered artifact.
- systemd unit carries `User`/`Group=socks5proxy`, `Restart=on-failure`, `NoNewPrivileges=yes`,
  `ProtectSystem=strict`, `ProtectHome=yes`, `PrivateTmp=yes`, and no `CAP_NET_BIND_SERVICE`.
- OpenRC script carries `command_user="socks5proxy:socks5proxy"`, `supervisor=supervise-daemon`,
  `depend() { need net; after firewall; }`, and `output_log`/`error_log`.
- Rendered account commands specify no home, `nologin`, and no password.
- No rendered artifact contains `setuid`, `setgid`, or `chroot`.

**Testing.** Byte-exact golden diffs; denylist grep; a negative case where a bad password is refused.

**Excluded.** Writing to `/etc`, creating the account, enabling or starting services, firewall.

---

## Task 6 — Install flow, atomic writes, firewall, state file, failure cleanup

**Objective.** Wire SPEC §11 end to end: static check → atomic write → start → verify → destroy this
run's resources on any failure. Plus additive firewall handling and the state file.

**Files.** `socks5.sh` · `tests/unit/test_install_flow.sh` · `tests/unit/test_rollback.sh` ·
`tests/stubs/{systemctl,rc-service,ufw,firewall-cmd,nft,useradd,adduser}`

**Prerequisites.** T2, T3, T4, T5.

**Implementation boundaries.** All roots come from `S5_*` overrides; all privileged commands go
through stubs in tests. Atomic write = temp file in the same directory → `chown`/`chmod` → `mv`.
Firewall handling is detect-only-if-active and additive; it never flushes, disables, or reorders, and
never auto-opens without consent. Ownership assertions are skipped when not root; **mode assertions
always run**. The collision rule from SPEC §4 aborts whenever state cannot confirm ownership.

**Acceptance criteria.**
- Static check rejects a config missing a required directive or containing a denylisted one.
- Atomic write yields SPEC §4 modes: dir 0750, both configs 0640, state 0600; no partial file is ever
  left in place.
- The state file records every created resource: binary, dirs, config files, account, service,
  firewall rule, and installed dependency packages.
- Injected failure at each of steps 3–4 stops the service and removes exactly this run's resources;
  a pre-planted foreign file in the config dir survives.
- Collision with an unattributable existing resource aborts before any write.
- No firewall rule is added without explicit consent, and stub transcripts show no flush/disable/
  reset verb ever issued.
- The runtime credential self-test invokes `curl --config -` with the password on **stdin only** —
  transcripts confirm it never appears in argv.

**Testing.** Temp-dir sandbox with the full stub set; transcript assertions; fault injection per step.

**Excluded.** Real service start, real account creation, real firewall mutation, real `/etc` writes,
the live protocol matrix.

---

## Task 7 — status, show, restart, uninstall, idempotency

**Objective.** Implement the four lifecycle subcommands over Task 6's state model, with a
state-driven uninstall that removes only what this script created.

**Files.** `socks5.sh` · `tests/unit/test_lifecycle.sh` · `tests/unit/test_idempotency.sh`

**Prerequisites.** T6.

**Implementation boundaries.** Same sandbox and stubs. `show` prints the password to stdout only and
must not reach any log sink. `restart` maps to the detected manager. No `reload` and no `reconfigure`
subcommand may exist.

**Acceptance criteria.**
- `status` reports service state, listening port, install origin, and 3proxy version without secrets.
- `show` output contains the password; the log file and journal sink do **not**.
- `restart` issues exactly the correct manager verb; `reload` and `reconfigure` are rejected as
  unknown subcommands.
- `uninstall` removes only state-recorded resources; planted foreign firewall rules, a foreign
  system 3proxy, a foreign proxy user, and unrelated `/etc` files all survive.
- `uninstall` removes **no** system package.
- A second `install` is a no-op plus status: one service, one account, one credential line.
- Uninstall then reinstall succeeds cleanly, since reconfigure is intentionally absent.

**Testing.** Sandbox transcripts, planted-foreign-resource fixtures, grep assertions over log sinks.

**Excluded.** Live protocol verification, CI matrix, README, LICENSE.

---

## Task 8 — Protocol acceptance suite, system matrix, README, LICENSE

**Objective.** Prove the SPEC §1.1 protocol boundary against a running proxy on every matrix cell,
wire the hard release gate, and ship the docs.

**Files.** `tests/protocol/run_protocol.sh` · `tests/protocol/socks_probe.py` ·
`.github/workflows/ci.yml` · `README.md` · `LICENSE`

**Prerequisites.** T6, T7.

**Implementation boundaries.** The live suite is **CI-only** — no container runtime exists locally.
`curl` covers the cases it can express; a `python3` raw-socket probe covers the rest. Probe tooling is
**test-only** and must never appear in `socks5.sh`'s dependency list.

| Case | Client | Expected |
|---|---|---|
| SOCKS5 + correct credentials + CONNECT | `curl --socks5-hostname` | **success** |
| SOCKS5 + wrong password | `curl --socks5-hostname` | **fail** |
| SOCKS5 offering no auth method | `socks_probe.py` | **fail** |
| SOCKS4 CONNECT | `curl --socks4` | **reject** |
| SOCKS4a CONNECT | `curl --socks4a` | **reject** |
| SOCKS5 BIND | `socks_probe.py` | **reject** |
| SOCKS5 UDP ASSOCIATE | `socks_probe.py` | **reject** |

**Acceptance criteria.**
- All seven cases assert on every matrix cell. SOCKS4/4a are **rejection** tests — a pass requires
  refusal; a working SOCKS4 proxy is a failure, never a pass.
- **Release gate:** any SOCKS4/4a success fails the job and blocks release. No warn-and-continue, no
  skip flag, no env override. The gate is non-experimental on **every** cell, Alpine included.
- Matrix runs 8 OS versions × 2 arches = 16 cells; **all 16 block the release, Alpine included**
  (frozen `SPEC.md` §13: "There is no experimental tier"). No cell carries `continue-on-error`.
- `shellcheck` runs in CI (it cannot be installed locally) and is clean.
- README satisfies SPEC §17: `mktemp`-based one-liner (never a fixed `/tmp/socks5.sh`), SOCKS5-only
  naming, only `socks5://user:password@host:port`, no SOCKS4 example anywhere, plaintext-credential
  and no-encryption disclosures, the build-dependency list with the note that they are left in place,
  and the "operator owns updates" statement.
- `LICENSE` present and referenced from README.
- A doc lint asserts no user-facing string in the repo mentions SOCKS4, SOCKS4a, or SOCKS4.5 outside
  rejection-test context.

**Testing.** CI matrix; the seven-case suite per cell; the gate proven by a deliberately inverted
assertion in a scratch branch before merge.

**Excluded.** Running the matrix locally; installing a container runtime; any change to `SPEC.md`.

---

## Checkpoints

- **After T1–T3** — both syntax checks clean; all unit tests green; detection covers 8 supported plus
  3 refusals; generator bias test passes. Human review before proceeding.
- **After T4–T5** — commit-mismatch abort proven; goldens byte-exact; denylist clean; CI has produced
  one real amd64 and one real arm64 binary.
- **After T6–T7** — full install/uninstall cycle green in the sandbox; rollback and idempotency
  proven; foreign resources demonstrably survive uninstall.
- **After T8** — 16 cells reported, all seven protocol cases pass on each, release gate proven to
  fail on inverted input, README and LICENSE complete. Ready for review.

## Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| SOCKS4/4a might actually succeed against the pinned build | **High** — invalidates the protocol boundary | T4 lands early and CI runs the gate from T8; response is engine re-evaluation or a minimal restriction patch, never relaxing the test |
| No local container runtime, so system behaviour is stubbed until CI | High | Sandboxing contract in T1 makes stubs faithful; T6/T7 assert on command transcripts, not just outcomes |
| Alpine/musl build may fail | Medium | No experimental tier (SPEC §13): an Alpine build failure blocks the release like any other cell. Response is a musl fix, never a `continue-on-error` |
| Stubs drift from real tool behaviour | Medium | Transcript assertions check exact argv; CI runs the real tools on 16 cells |
| Modulo bias in password generation | Medium | Reject-and-resample, with a statistical coverage test in T3 |
| `local` is not in POSIX although dash/busybox/bash all accept it | Low | Permitted deliberately; the banned-construct list covers the real hazards |

## Open questions

All previously open questions are now closed by the locked decisions above:
self-test URL = `https://example.com/`; OpenRC logs to syslog via `logger` and does not use
`need net`; ARM64 CI uses the native `ubuntu-24.04-arm` runner with QEMU as fallback only.

