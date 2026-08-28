# TODO: socks5.sh — status after the thirteenth round (one-click invocation)

Plan: `tasks/plan.md` · Spec: `SPEC.md` (re-frozen; owner decisions recorded in-place).
Engine 3proxy 0.9.9.0 @ `da99424eac4092e3722f1a5b1844cfe80478f580`.

**Local suite: 20 files, 1705 assertions, 0 failures, 0 skips — green under `sh`, `dash`,
`busybox sh` and `bash`.** All 33 shell files parse under `sh -n`, `dash -n` and `busybox sh -n`;
all four Python tools compile; the CI workflow parses with PyYAML (8 jobs, every one with a
timeout, no `continue-on-error`).

---

## Round 13: the one-click one-liner

The owner wants the install experience to be `bash <(wget -qO- <RAW_URL>)`, in the style of
the sing-box one-click scripts. Two halves:

- **The script side.** Under process substitution `$0` is a transient `/dev/fd/*` descriptor
  that will not exist after the run. Five operator-facing messages printed it (usage, the
  collision advice, the rollback retry, the summary's re-display line, the uninstall retry).
  A new `S5_SELF` normalizes it: a real path is kept, a transient descriptor (or `bash`/`sh`
  from `bash -c "$(…)"` invocations) yields piped-mode phrasing — "re-run the install command
  and choose 'X' from the menu" — which is honest, because re-running the one-liner opens the
  management menu when the proxy is installed. Verified end to end by actually invoking the
  real script through `bash <(cat …) --help` in test_skeleton (with the test-mode environment
  stripped, so the library-mode guard does not silently skip dispatch — the first version of
  that test was vacuously green for exactly that reason, and the fix is documented at the
  test).
- **The documentation side.** The README's primary install form is now the one-liner against
  the published raw URL, in wget and curl variants, with a read-it-first alternative and an
  Alpine note: Alpine ships without bash and busybox ash cannot parse `<(...)` (both verified
  directly — dash cannot either, which is why the one-liner says `bash` and not `sh`), so
  Alpine users get `apk add bash` first or the save-and-run form. SPEC §10/§17 record the
  invocation rule: messages never print the transient `$0`, and `wget … | sh` is forbidden —
  a pipe feeds the script to the prompts' stdin and breaks the interactive flow.

Assertion accounting (1691 → 1705): +5 process-substitution/usage assertions, +6 hint
assertions (piped and file modes), +4 README one-liner assertions, −1 retired mktemp
assertion.

**CI status:** the repository went live during this round (main pushed to
github.com/91sexboy/One-click-socks5-proxy-setup as a single clean commit, no develop
history). The first CI run ever completed: 31 of 45 jobs passed — including every unit cell,
14/16 build cells and 14/16 protocol cells. The 14 failures (CentOS Stream 9 build/protocol,
the real systemd installs, all ACL-resolution cells, shellcheck, alpine:3.20 OpenRC) are
undagnosed: GitHub requires admin authentication to read job logs. Fixing them needs the log
tails pasted in or a token.

---

---

## Round 12: the owner decisions

Three long-open product questions were answered by the owner on 2026-08-27:

- **Firewall functionality is gone entirely.** Round 10 deleted the mutating half and kept
  read-only detection/guidance; this round removes that remnant too — no `s5_firewall_detect`,
  no guidance, no backend query of any kind. Install invokes no firewall command (asserted
  against the transcript, not just structurally), and a guard fails if any firewall function
  name reappears in `socks5.sh`. Mutation-proofed: appending a two-line `s5_firewall_detect`
  fails the suite. The README still documents example commands per backend, explicitly as
  operator documentation the script never runs; `status`/`show` keep their constant
  "not modified by this script" line.
- **`status`, `show`, `restart` and the no-argument menu are retained** as product surface.
  No code change; recorded in SPEC §18 as decided so the question is not re-raised.
- The publishing-target question remains the only open one.

Assertion accounting (1709 → 1691, net −18): the deleted detection/guidance behavioural
assertions (18) went with the feature; the absence guard grew by 3 checks (the three removed
function names plus the install-step reference scan). The transcript-level "no firewall
command at all" assertion replaces the weaker "no rule inserted" one, so the removal is proven
behaviourally, not only by name absence.

---

**CI PENDING — never executed.** Real compilation, the build/protocol matrices, the seven protocol
cases, the destination-ACL hostname test, `shellcheck` (not installed locally), and all
real service-install lifecycles (Ubuntu 24.04 + 22.04, Debian, Alpine, CentOS Stream). No support
claim should be published for any target until its lifecycle job has actually run green.

**Blocked on a decision, not startable:** publishing target (no remote is configured, so CI
cannot run at all and the README download recipe stays a template); whether to restore
automatic firewall opening; whether to keep `status`/`show`/`restart`/the menu. See
`tasks/plan.md` → Open questions.

---

## Round 11: fix the verified audit findings

A full adversarial review of the `develop` branch (commit 7f26a55) confirmed 21 findings; the
eleven verified-defect ones were fixed here, one slice per commit, every slice RED first. The
review itself also refuted the BIND/UDP false-pass claim (a complete nonzero REP *is* a proven
rejection of that request under RFC 1928 §6) — recorded here so the same claim is not re-raised.

- **Protocol-gate false positives (477bf57).** Three gates could pass while the property they
  guarded was broken: an accepted no-auth method (RFC 1928 §3 — the selection *is* the failure)
  followed by any nonzero reply scored as correct rejection; every SOCKS5 request used ATYP=0x03,
  so the four "by literal IP" ACL cases never exercised the IPv4 path; the SOCKS4 release gate
  sent user id `probe` instead of the configured one, so an allow-SOCKS4-for-ciuser regression
  read as unknown-user. Plus two oracle alignments: curl now targets TARGET:TARGET_PORT like the
  raw probes, and the ACL sanity curls use `--noproxy '*'` so an ambient http_proxy cannot
  satisfy the direct-reachability gate. Mutation-proofed: reverting the no-auth fix fails 3
  assertions.
- **Port and commit syntax (ba811c3).** Leading zeros are octal to shell arithmetic but literals
  to the engine and to `ss` — `01080` passed both validators and then matched no listener; a
  1000-digit decimal made both POSIX range comparisons diagnose-and-return-false, which
  `if a || b` treated as acceptance; the commit pattern was 8 hex + unbounded `*`, so
  `deadbeefg` was a valid "hex object name". All rejected lexically now, before arithmetic.
- **State completeness (cfdd6fd).** A mode-0600 file containing only `status complete` loaded as
  an installed system — `install` became a no-op reporting "already installed" and lifecycle
  commands ran on empty fields. The loader now requires every singleton key when status claims
  completeness, and still accepts partial (no-status) records because rollback and the
  uninstall-retry path depend on them.
- **Account ownership (0956f1a).** Two sides of the same hole. The collision check runs long
  before `s5_install_steps`; identities that *appeared* in that window were silently adopted,
  handing the plaintext credentials to a foreign group and recording no ownership. Separately,
  `created_account=1` matched on the name alone, so uninstall deleted whatever currently held
  the name — including an unrelated workload's replacement. Install now records the numeric
  uid/gid it created; removal verifies the names still answer to those numbers before deleting.
  Mutation-proofed both directions.
- **Rollback deadlock (a81d176).** `created_unit` is recorded before the unit file is written;
  managers refuse stop/disable for units they never loaded (verified directly on this host), so
  a failed write stranded every resource behind an unsatisfiable stop, forever, on retry too.
  The systemctl stub used to report those refusals as success, which is why no test saw it; the
  stub now models the manager, which flipped the existing flagged-but-absent test RED against
  the old code and green against the fix. Also: `s5_state_begin` now removes its directory when
  the first records cannot be written, instead of leaving a collision-guard trap.
- **Clean-host bootstrap (22f92c3).** A probe had to exist, not work — a broken `ss` suppressed
  the iproute2 repair and masked a working `netstat`. "Cannot determine" was reported as
  "already in use" in both the prompt and random selection. apt could install git without
  ca-certificates (Debian only recommends it), leaving the HTTPS clone to fail TLS verification.
- **Sandbox containment (4ca8661).** `S5_LOGSINK` and `S5_TMPMODE_LOG` are *write* paths and
  were never confined; a test-mode run could log anywhere on the host (reproduced). Both now go
  through `s5_test_path_ok`. `S5_OSRELEASE`/`S5_PORT_PROBE` stay unconfined by design — they are
  harness-chosen *inputs* — and the test now asserts that distinction is deliberate.
- **CI coverage gaps (fd5969e).** The OpenRC job never exercised the advertised `restart`
  command and preinstalled the whole toolchain (so it tested nothing about Alpine bootstrap);
  ubuntu:22.04 had no real lifecycle cell; cleanup `test ! -e` passes dangling symlinks; the
  no-firewall oracle matched this project's comment rather than the port. All fixed
  structurally — still CI-pending, honestly.

**Assertion accounting (1624 → 1709, net +85).** New coverage: no-auth/ATYP/SOCKS4 oracles
(+18), port/commit syntax (+13), completeness (+5), ownership (+18), deadlock (+8),
bootstrap (+10), containment (+5), plus fixture upgrades throughout. Nothing was deleted.

**Not fixed, by review verdict:** the BIND/UDP reply-code claim (refuted), the SOCKS4
user-id concern in *curl* cases (curl cannot send a SOCKS4 user id at all; the probe is
authoritative), and the three open product decisions.

---

## Round 10: delete the unreachable mutating firewall subsystem

Round 9 made the firewall read-only but left the mutating half in place, unreachable from every
command. That is worse than either extreme: a reader, or a future change, can reasonably conclude
the installer still opens ports. It is now deleted, with a guard so it cannot return unnoticed.

- **Deleted from `socks5.sh` (328 lines):** `s5_maybe_open_firewall`, `s5_firewall_open`,
  `s5_firewall_close`, `s5_firewall_rule_still_there`, `s5_ufw_rule_present`,
  `s5_iptables_rule_present`, `s5_firewalld_zone`, and `S5_FW_ZONE`. Production is now 3283 lines,
  down from 3611.
- **Kept:** `s5_firewall_detect`, `s5_firewall_manual_hint`, `s5_firewall_guidance` — the read-only
  path install actually uses. The section header comment, which still promised "additive,
  single-port, consented to, and recorded" changes, was corrected to state the read-only contract.
- **State keys `firewall` and `firewall_zone` removed** from `S5_STATE_KEYS_ONCE`, along with the
  `firewall)` validation branch. Nothing is published and CI has never run, so no state file
  containing them exists and there is no migration to preserve. A hand-written file naming either is
  now refused as an unknown key — the existing fail-closed behaviour, asserted by two new
  `reject_case` entries in `test_state.sh`.
- **Consumer sites collapsed to a constant.** `s5_teardown` lost its firewall block; `status`,
  `show`, `print_summary` and `uninstall` now state "not modified by this script" with no branching
  and no backend query. `uninstall` says plainly that no firewall rule is removed because none was
  created.
- **New structural guard (`test_install.sh`).** Eight deleted names must appear nowhere in
  `socks5.sh`, neither firewall state key may reappear, and the three read-only functions must still
  be defined — so the guard cannot be satisfied by deleting the whole feature.
  **Non-vacuity proven by mutation:** appending a two-line `s5_firewall_open` to a scratch copy
  fails the suite naming that function. The two pre-existing structural assertions could not have
  caught it, because install would still have been calling the guidance.

**Assertion accounting (1660 → 1624, net −36).** Entirely `test_install.sh`, 203 → 167: −49 from
deleting the rule-creation, ambiguous-mutation-compensation, pre-existing-rule-ownership and
firewalld-zone-ordering blocks, +13 from the new guard. `test_state.sh` 83 → 85 (+2, the retired
keys), `test_lifecycle.sh` 85 → 83 (−2, the planted-ownership tri-state case), `test_audit2.sh`
unchanged at 100 (its three-way rule-presence cases replaced by "never queries a backend"). The
drop is code deleted, not coverage abandoned: every removed assertion tested a function that no
longer exists.

**Deliberately not done in this round:** reducing build/protocol matrix breadth — trimming coverage
before CI has ever been observed passing is optimising something unmeasured.

---

## Round 9: narrow v1 to the stated product goal

The product goal is a one-command interactive installer for Ubuntu, Debian, Alpine and CentOS
Stream with a custom-or-generated port, username and password. This round fixed the two defects
that blocked that goal, removed the two prompts and the one subsystem that were not part of it,
and closed the lifecycle-coverage gap. Every change is test-first with a focused RED regression.

- **Clean-host prerequisites (release blocker).** `s5_prompt_port` needs `ss` or `netstat`, but
  dependency installation ran *after* the port prompt and never installed a probe, so a minimal
  supported host aborted before it could ask for a port. `s5_runtime_deps` now adds `iproute2`
  (apt/apk) or `iproute` (dnf/yum) when no probe exists, and `s5_cmd_install` installs
  prerequisites *before* prompting. Fail-closed port observation is unchanged.
  RED → `test_detect.sh` (4 package-selection cases), `test_precheck.sh` (ordering, observed via an
  on-disk marker rather than by reading the source).
- **One confirmation, then three values.** The dependency prompt was a second `[y/N]` that consumed
  an answer after the credential prompts. The package list, detected target and security warning
  are now shown together in the single pre-install confirmation (`s5_required_packages`,
  `s5_preinstall_warning`), and `s5_install_dependencies` performs the approved action without
  asking again. Package-failure handling is unchanged.
- **The firewall is now read-only (§7.1).** `s5_install_steps` calls the new `s5_firewall_guidance`,
  which detects the backend only to print the exact command, and never adds, deletes, flushes,
  enables or reloads a rule. Nothing firewall-related is recorded in state, so `uninstall` cannot
  remove a rule either. `s5_maybe_open_firewall` and the `s5_firewall_open`/`_close` helpers are
  retained but no longer reachable from install; deleting them is deferred cleanup.
  *Trade-off, stated plainly:* on a host with an active firewall the operator must run one command
  before the proxy is reachable. Chosen because opening a port is a host-wide change with an
  ownership and rollback problem disproportionate to v1, and because the cloud security group —
  which usually matters more — cannot be automated from inside the host anyway.
- **Truthful post-start diagnostic.** Install reported *any* non-zero `s5_service_active` as "the
  service is not active after start", including a failed manager query. It now dispatches on the
  three-valued status and says "could not verify" for the unobservable case. Both still fail closed.
  The same RED test also documented the correct fail-closed rollback: when the service cannot be
  *proved* stopped, resources and state are **kept** with a retry message rather than deleted from
  under a possibly-live proxy.
- **Four real lifecycles, one per promised family.** Debian and CentOS Stream had no
  service-install job at all — the build and protocol matrices only compile and run the engine
  directly. New `distro-systemd-integration` boots systemd as PID 1 in a privileged container for
  `debian:13` and `centos:stream10` and runs install → status → active → listening → restart →
  uninstall → cleanliness. Its images deliberately omit `git`, a compiler, `curl` and any `ss`
  provider, so the job also proves the installer bootstraps its own prerequisites.
- **Two latent CI breaks fixed.** Both integration jobs piped `sudo sh socks5.sh show` into `grep`,
  but `show` refuses to disclose unless stdout is a terminal, so that step would have failed on
  first run; it now runs under `script -qec` with output kept in a 0600 file that is never printed.
  The OpenRC job's redaction line used `printf 's|'` inside a single-quoted `sh -c '...'`, which
  terminated the quote and left `|***REDACTED***|` as an unquoted pipe; it is now escaped as
  `'"'"'`. Neither could have been caught locally because CI has never run.
- **CI-lint scope vacuity fixed.** The OpenRC redaction and cleanup assertions searched the whole
  workflow, so the systemd job's text satisfied them. `ci_job_block` now extracts one job's code
  (comments stripped) and each lifecycle job asserts its own redaction and its own cleanup, plus
  the four-family coverage. **Non-vacuity proven by mutation:** removing OpenRC's `redact.sed`
  line → 2 failures; deleting the whole `distro-systemd-integration` job → 10 failures. Both were
  green under the previous whole-file assertions.
- **Documentation matches the artifact.** README's install recipe no longer presents `<RAW_URL>` as
  a working command: the copyable path is `sudo sh socks5.sh`, and the download recipe is labelled
  a publish-time template with a checksum-verification step. The firewall section, prompt list,
  dependency list and uninstall claims were rewritten to match the code. SPEC §1/§5/§7.1/§8/§11/
  §12/§13/§14/§15/§17 updated and re-frozen.

**Still open, deliberately deferred (not release blockers):** deleting the now-unreachable firewall
subsystem and the `firewall`/`firewall_zone` state keys; reducing build/protocol matrix breadth;
trimming the management surface (`show`, `restart`, the menu) if it turns out not to be wanted;
publishing the real release URL and checksum, which requires a repository that does not exist yet.

---

## Round 8: fixes from the fresh full-project bug audit

The audit identified defects that the round-7 detector pass did not reach. Each fix below has a
focused local regression and the full shell matrix remains green. No real service, firewall,
account, system path, or listening port was touched locally.

- **Protocol wrong-password oracle:** pinned 3proxy sends RFC 1929 success before running
  `strongauth`; `socks5-badauth` now continues to CONNECT and treats only the complete request reply
  as authoritative. REP 0x02 is rejection, REP 0x00 is an alarming grant, and all generic/transport
  failures are inconclusive. Destination-policy mode likewise accepts only RFC 1928 REP 0x02, not
  generic REP 0x01. FakeSock replays the pinned engine sequence.
- **Credential and input safety:** a pre-existing `socks5proxy` group is now a hard namespace
  collision; `stty -echo` failure aborts before reading and restores terminal state; oversized digit
  strings are rejected before shell arithmetic; all protocol PASSFILE inputs must be regular,
  non-symlink, mode 0600 files.
- **Sandbox/filesystem safety:** every test-mode filesystem override is constrained beneath the
  sentinel root; prefix parents are created component-by-component at traversable 0755; broken
  symlinks count as present in both production teardown and `assert_file_absent`; state files must be
  regular, readable, and mode 0600; extra state-directory content retains state and blocks success.
- **Config/firewall boundaries:** the static check requires one exact configured-user CONNECT allow
  and one exact startup line; pre-existing UFW/firewalld/iptables rules are not adopted or recorded;
  firewall query/mutation/undo failures are hard failures; default-DROP iptables is detected;
  firewalld partial rollback tells the operator exactly what remains.
- **Lifecycle truthfulness:** failed `ss`/`netstat` is unobservable rather than free; teardown derives
  init/family from state, verifies the service stopped, propagates stop/disable failure, and keeps
  resources/state for retry; package metadata update failure is no longer silently ignored.
- **CI secrecy/completeness:** OpenRC now captures install output to a 0600 log and emits it only
  through a 0600 redaction script on failure; cleanup checks state, prefix, account, and group.
  Server-address fallback emits IPv4 only, matching the IPv4-only listener.

---

## Round 7: are the detectors and security invariants actually effective?

This round asked a different question from rounds 1–6. Those looked for defects in the product and
then wrote assertions. This one assumed the assertions were the suspect: **which of them would still
pass if the thing they guard were broken?** The method was mutation testing throughout — copy the
repo to a `mktemp -d`, apply one semantic mutation, re-run, and treat a green result as a defect in
the test rather than as evidence of correctness. 19 mutations were run (M56–M74); every one is
recorded with its observed outcome.

Findings are ordered by leverage, not by discovery order.

### F28 — HIGH: the SOCKS4 doc-lint allowlist exempted the advertisements it existed to catch
- **Was:** the guard in `.github/workflows/ci.yml` and `test_docs.sh` reported any README line
  mentioning SOCKS4 *unless* the line matched an allowlist of 13 tokens. Five of those tokens were
  bare negations — `never`, `does not`, `cannot`, `refus`, `fails` — which exempt a line for
  negating **anything at all**. `SOCKS4 is fully supported; the password is never logged` passed.
  Worse, the token `enable SOCKS4` exempted the literal sentence
  `We enable SOCKS4 for legacy clients`. Six of the 13 tokens covered no README line whatsoever, so
  they were pure holes with no purpose.
- **Now:** six tokens, each specific enough that it cannot occur inside an advertisement, and each
  the sole cover for exactly one real README line. Plus a **count pin**: the number of
  SOCKS4-mentioning lines is asserted to be 6. An allowlist alone cannot catch a *new* offer that
  happens to contain a token intended for a different line; the pin forces any added line to be read
  by a human before the count is changed.
- **Test:** `test_docs.sh` (per-token load-bearing loop + the pin) and `test_ci_lint.sh` (five
  adversarial advertisement samples, the token/pin cross-checks). The tokens and the pin are both
  *read out of `ci.yml`*, so the test cannot pass by checking a pattern or a number the pipeline
  does not use.
- **Non-vacuity:** M56 added `We enable SOCKS4 for legacy clients.` to the README → `test_docs`
  **101 passed / 2 failed**, and the real CI step, extracted from the YAML and run verbatim, exits
  **1** naming the line. M57 (allowlist widened with `does not`) → **44 / 2**. M58 (the two
  allowlists drift apart) → **45 / 1**. M59 (count pin set to 0) → **45 / 1**.

### F29 — HIGH: `s5_atomic_write`'s failure path had no oracle, only its success path
- **Was:** the existing cases proved the temp file is 0600 throughout and the installed file ends at
  0640. **Neither can fail** if `s5_apply_owner_mode` were moved to *after* the rename: the
  transient mode at the target path would be the tighter 0600 either way, so the final state is
  identical. Nothing tested the security-relevant half — that a **failed** `chmod` or `chown`
  installs nothing. Without it, a credential file could land in place carrying whatever mode and
  owner it happened to have.
- **Now:** both failures are driven with a real non-zero exit status, and the assertions are that the
  write fails, that it says which property it could not set, that the file is **absent** from its
  target path, and that no `.s5tmp.*` survives. A positive control runs first and again afterwards,
  so a failure is attributable to the injected fault rather than to a broken fixture.
- **Method note — two hazards, both real:** a PATH-shadowing stub **cannot** work here, because the
  shell hashes command lookups and `chmod` is already resolved to `/usr/bin/chmod` before the stub
  is written; only a shell **function** shadows both PATH and the hash table. And the function must
  invoke the real binary by **absolute path**: busybox's `command -v chmod` returns the bare applet
  name `chmod`, which re-enters the shadow and recurses until the stack dies — observed as
  `Segmentation fault (core dumped)` in place of the expected message, under `busybox sh` only.
  `resolve_real` now returns an absolute path or fails loudly.
- **Non-vacuity:** M65 (`s5_apply_owner_mode` moved after the `mv`) → **55 / 3**, and critically two
  of the three failures are *behavioural*, not merely the structural line-order check. M66 (a failed
  chmod/chown made non-fatal) → **54 / 4**. M67 (`rm -f` dropped from the failure path) → **56 / 2**.
  M68 (the resolver forced back to a bare applet name) → the guard fires **first** and names the
  cause, instead of leaving only an unexplained segfault.

### F30 — HIGH: the wrong-password case scored every failure as a pass
- **Was:** protocol case 2 ran `curl` with a wrong password and its `else` branch called `ok` for
  **any** non-zero exit. A proxy that was down, a DNS failure, or a `curl` built without SOCKS5
  support all read as "the wrong password was refused". The single case that proves authentication is
  enforced was the easiest in the file to pass accidentally, and it had no on-the-wire oracle at all.
- **Now:** a new probe mode `socks5-badauth` asks the question directly in the RFC 1929 exchange. It
  is the mirror of `mode_socks5`: an authentication **failure** is the expected PASS, and success is
  the alarming outcome. It sends no request afterwards — the credential check has already answered,
  and a request would open a real connection for no added signal. `curl` is reclassified the way
  cases 4a/5a already were (only `CURLE_PROXY` is attributable to the proxy) and probe 2b is
  authoritative, failing on its own inconclusive result. The deliberately-wrong password is
  **compared against the configured one** and the run aborts with exit 2 if they collide — otherwise
  case 2 would be silently exercising the *correct* password.
- **Test:** `test_probe_tooling.sh`, six FakeSock cases (rejected / accepted / no-method / EOF at
  negotiation / EOF at auth / unexpected method), a distinguishability check, and 10 structural
  guards anchored on **code** lines.
- **Non-vacuity:** M60 (an accepted wrong password reported as REFUSED) → **113 / 1**. M61 (the
  probe call deleted) → **113 / 1**. M62 (case 2 reverted to "any non-zero is a pass") → **112 / 2**.
  M63 (collision guard removed) → **112 / 2**. M64 drove the guard for real: with
  `PASSFILE` equal to the wrong password the runner exits **2** printing *"the configured password
  equals the deliberately-wrong one; case 2 cannot test anything"*, and with a distinct password it
  proceeds past the guard.

### F31 — MED: an inconclusive result was still counted as a pass in the summary
- **Was:** after F30, cases 4a and 5a still called `ok` in their `else` branch — the branch reached
  when curl failed for a reason **not** attributable to the proxy. The line was labelled "indicative
  only", but it printed `ok` and incremented the pass counter, so the summary claimed more than the
  run had proved. This is a false positive in the report even though the run's verdict was safe.
- **Now:** a third outcome, `note()`, counts separately and prints `note`, and the summary reads
  `N passed, N failed, N inconclusive (not counted as passes)`. The verdict is deliberately
  unchanged: the matching probe case is authoritative and fails on its own inconclusive result, so a
  genuinely broken environment still fails — there, where the evidence is.
- **Test:** the invariant is **computed, not spelled out** — no line admitting it is only indicative
  may be reported as a pass — so it also catches a *new* case written with the old shape.
- **Non-vacuity:** M69 (case 5a reverted to `ok`) → **118 / 2**. M70 (a brand-new indicative case
  added with the old shape) → **119 / 1**, which a fixed-string check on 2a/4a/5a would have missed.

### F32 — MED: the port oracle could not tell one port from another
- **Was:** the harness `portprobe` short-circuited on the existence of `$S5_TEST_ROOT/svc_active`
  **before ever reading `$1`**. While the stubbed service ran, every port on the machine answered
  "occupied", so a caller that probed a hardcoded port, the wrong variable, or no port at all passed
  every listen-state assertion. Production greps real `ss -ltn` output for the specific port, so the
  stub was strictly **less** discriminating than the code it was guarding.
- **Now:** the systemd stub records *which* port came up, read out of the configuration it was just
  handed, and `portprobe` compares it against `$1`. A wrong-port case is now writable, and written.
- **Also — a coverage gap the same mutation exposed:** because test mode delegates to
  `$S5_PORT_PROBE`, production's own matching pattern `[:.]$1[[:space:]]` had **no local oracle at
  all**. Emptying `S5_PORT_PROBE` drops `s5_port_free` through to the real branch, and `ss` is
  shadowed with canned output — so the shipped pattern is now tested without opening any port or
  assuming anything about this host. The substring cases are the point: `1080` is a suffix of
  `31080`, `310` is a prefix, and `4096` appears in the Send-Q column of a listening row. All three
  must read as free.
- **Non-vacuity:** M72 (the stub reverted to "service up ⇒ every port occupied") → **32 / 2**. On the
  production pattern, M73 in three variants: `grep -q "LISTEN"` → **37 / 5**; `grep -q "$1"`
  (unanchored) → **39 / 3**; `grep -q "[:.]$1"` (trailing boundary dropped) → **41 / 1**, caught
  only by the prefix collision. M71 is recorded as a **negative** result and is why the extra
  coverage was added: mutating the production pattern while the stub was in play left the file
  entirely green.

### F33 — MED: nothing pinned CI's three-shell coverage
- **Was:** the suite is written to be portable across `sh`, `dash` and `busybox sh`, and several
  defects in this project — the busybox applet-resolution class most recently, F29 above — were
  visible in exactly one of them. Nothing asserted that CI still runs all three. Deleting the `dash`
  and `busybox` run steps would have left CI green while dropping two thirds of that coverage.
- **Now:** each of the three suite runs and the three `-n` syntax checks is asserted individually,
  the total is pinned at 3 so an added shell must be acknowledged, and `tests/run.sh` is checked to
  actually honour `S5_TEST_SHELL` — a pinned step the runner ignored would be theatre.
- **Non-vacuity:** M74 in three variants — deleting the busybox suite run → **110 / 2**; the dash run
  → **109 / 3**; the busybox syntax check → **111 / 1**.

### F34 — LOW (documentation): a verification claim in this file was factually wrong
- **Was:** the F17 entry claimed its `grep -E` fix was "verified against both grep implementations
  available here (ugrep 7.8.4 and busybox 1.30.1)", and the round-5 waiver claimed `\|` survived in
  "seven test-file grep patterns".
- **The facts, established by direct measurement:** `sh -c` and `dash -c` both resolve `grep` to
  `/usr/bin/grep`, **GNU grep 3.7**. `busybox sh` resolves `grep` to its own applet, **busybox
  1.30.1**. ugrep 7.8.4 *is* installed, but only as a function in the interactive zsh, which no test
  run ever goes through — **no result in this file was produced by ugrep.** And the surviving `\|`
  count is **three**, not seven: an `-E` pattern matching the literal shell operator `||`, the ban's
  own pattern, and one retired pattern kept deliberately as F27's counter-example. No live *absence
  assertion* depends on BRE alternation any more.
- **Also worth stating plainly:** neither grep reachable here is POSIX-strict, so the fail-open F17
  prevents **cannot be reproduced on this machine at all**. It is proven by substituting `grep -qF`,
  which is exactly what a conforming grep does with a BRE `\|`.
- Both passages are corrected in place, each carrying an explicit note of what the earlier draft
  claimed, so the record shows the correction rather than hiding it.

### Round 7: what remains deliberate
- **`note()` does not fail the run.** An unattributable curl failure is not evidence of anything, in
  either direction; making it fatal would turn a flaky network into a release blocker while adding
  no security signal. The authoritative probe case beside it already fails on inconclusive, which is
  where a genuinely broken environment gets caught.
- **An empty `svc_active` still means "every port occupied".** Two lifecycle tests mark the service
  up without going through the systemd stub. Rather than rewrite them, `portprobe` keeps the old
  catch-all meaning for the portless case only, and the new port-specific path is exercised through
  the stub that does record a port.
- **The three surviving `\|` occurrences** are left as described in F34: none is a live absence
  assertion, and one is deliberately kept as a counter-example that must never match.

---


## Round 6: the test tooling and the test harness, neither of which had ever been reviewed

Rounds 1–5 reviewed `socks5.sh` and the assertions. This round turned the same reading on the
machinery those assertions run through: the two Python tools the CI protocol jobs depend on, the
two protocol drivers, and `tests/lib/stub.sh`. Every finding has the same shape — **a failure that
presented as a pass** — and none of them could have been caught by the suite as it stood, because
in each case the thing that was broken was the detector itself.

**Process deviation, stated plainly:** F21–F26 were each *fixed before* their regression test was
written, contrary to the project's test-first rule (the same deviation disclosed for F16). The
tests were then written and proven non-vacuous by reverting only the fix in a `mktemp -d` copy, so
the evidence below is real; but the order was wrong, and the discipline the rule protects — writing
the test while still ignorant of the fix — was not applied.

### F21 — HIGH: a short random draw was accepted, silently shortening every secret
- **Was:** `s5_random_string` returned whatever `tr -dc … </dev/urandom | head -c N` produced
  without checking its length. Anything that truncated the pipeline — an unreadable
  `/dev/urandom`, a `tr` that rejects the character class, a partial read — yielded a shorter
  string, and every caller used it as if it were full length. The password prompt printed
  "generated a random 32-character password" over a four-character password, and
  `s5_random_port` collapsed to the constant `S5_RANDPORT_MIN`.
- **Now:** the length is compared against the request and a shortfall is an error naming the count
  actually obtained. Every caller propagates it (`|| return 1`); the two prompts additionally clear
  `S5_PASSWORD` and leave `S5_SECRET` unarmed rather than keeping a partial secret.
- **Test:** `tests/unit/test_input.sh`, 24 new assertions. `tr` is shadowed by a **shell function**
  rather than a PATH stub, because busybox resolves `tr` to a built-in applet and ignores PATH.
- **Non-vacuity:** against the unfixed source, **19 of the 24 fail** — including
  `s5_random_port` returning exactly `20000` and the prompt claiming 32 characters while
  `S5_PASSWORD` held `abcd`.

### F22 — HIGH: the probe's own crash was scored as "the proxy refused"
- **Was:** `socks_probe.py` exits 1 for REFUSED, and Python also exits 1 on an uncaught traceback.
  A malformed argument therefore crashed into exit 1, which `run_protocol.sh` reads as a correct
  refusal for five rejection cases — including the SOCKS4 release gate — and `acl_resolution.sh`
  for all six destination-deny checks. One mistyped port in CI would have turned the entire
  rejection half of the protocol suite green with no bytes sent.
- **Now:** arguments are validated by `port_arg()`, the `except` tuple covers what `struct.pack`
  and the socket layer actually raise, and `__main__` has an `except BaseException` last resort that
  exits 2. A refusal is now only ever something the probe observed on the wire.
- **Test / non-vacuity:** `tests/unit/test_probe_tooling.sh` (new file). Pre-fix,
  `--port notanumber` exits **1** with a bare traceback. The last-resort handler is proven by
  injecting a `TypeError` into a throwaway copy of the probe — the only honest way to test a handler
  whose purpose is catching something nobody foresaw.

### F23 — HIGH: an authentication failure was reported as a refused operation
- **Was:** `mode_socks5` returned REFUSED when the RFC 1929 sub-negotiation failed. But every
  caller of that mode supplies credentials it asserts are valid and is asking about the *operation*
  (BIND, UDP ASSOCIATE) or the destination ACL. If the handshake stops at authentication the
  operation was never reached, so a mistyped `PASSFILE` scored those rejections as passes.
- **Now:** an auth failure, and an EOF during authentication (which had no handler at all), both
  `die()` into ERROR. A refusal after successful authentication stays REFUSED.
- **Test:** the probe module is imported and its `connect()` replaced with a fake socket whose
  `recv` slices its buffer the way a real one does, producing seven verdicts across the handshake.
  No port is opened. **Non-vacuity:** pre-fix `authfail` returns 1, and `autheof` is unhandled.

### F24 — MEDIUM: a timeout that could not fire
- **Was:** `interrupt.py`'s `read_until` checked its deadline only *between* blocking `os.read`
  calls, so the timeout was unenforceable in the one situation it exists for — a prompt that never
  appears, leaving child and parent blocked on each other. The deadlock consumed the whole CI job
  timeout instead of reporting which prompt was missing. The reaping side had the same shape: a
  bare `waitpid` on a child that ignores SIGINT, which is the regression the file exists to catch.
- **Now:** the wait is bounded by `select.select`, and reaping uses `os.WNOHANG` with escalation to
  SIGKILL.
- **Test / non-vacuity:** a pipe whose write end is held open — never readable, never EOF — under
  `signal.alarm(8)`. Pre-fix the run exits **142** (SIGALRM): it hung. The alarm is the vacuity
  guard, since a regression here would otherwise hang the suite instead of failing it.

### F25 — HIGH: the harness could not observe the prohibited commands it asserted about
- **Was:** `t_assert_never_called` greps a transcript that only *stubbed* commands write to. An
  unstubbed command leaves no trace, so the assertion passes whether or not the command ran —
  and `passwd`, `chpasswd` and `sudo` were stubbed **nowhere** in the harness, while
  `/usr/bin/passwd`, `/usr/sbin/chpasswd` and `/usr/bin/sudo` all exist on this machine. Six
  assertions guarding the project's own prohibitions — "no password is ever set on the service
  account" (`test_install.sh:305`, `test_render.sh:158`, `:159`, `:168`) and "no sudo"
  (`test_detect.sh:130`, `test_install.sh:307`) — therefore could not fail, and a regression would
  have executed the real binary on the machine running the suite. Instrumenting the helper showed
  **24 of 49 absence assertions running against an empty transcript**. `systemctl` was likewise
  unstubbed in `test_build.sh`, so "no systemctl during build" was in the same position.
- **Now:** `T_FORBIDDEN_CMDS='passwd chpasswd sudo doas su'`, stubbed by `t_stub_init` for every
  test file. That location is deliberate: it is the one function every file calls, so no file can
  build a narrower stub set and quietly lose the detector. `test_build.sh` stubs `systemctl`
  itself, since systemctl is not forbidden in general — install and uninstall use it.
- **Non-vacuity:** with the stubs removed in a `mktemp -d` copy, **17 of 68 assertions fail** and
  the failures print the real resolutions (`/usr/bin/passwd`, `/usr/sbin/chpasswd`,
  `/usr/bin/sudo`, `/usr/bin/su`). The point of the finding is the second half of that run:
  `test_install.sh`, `test_render.sh` and `test_detect.sh` still report **0 failures** with the
  detector removed. They could not see it.

### F26 — HIGH: …and on the busybox CI cell the F25 fix was bypassed for the three names that matter
- **Was:** found by running the F25 fix under all three shells. busybox implements `passwd`,
  `chpasswd` and `su` as **built-in applets** and resolves those names to the applet regardless of
  `PATH`, so under `busybox sh` the new stubs were ignored: `passwd --probe` reached the real applet
  (`passwd: must be suid to work properly`). On that CI cell the three most security-relevant names
  stayed exactly as unobservable as before, and `sudo`/`doas` — which busybox does *not* implement —
  were the only two the fix actually covered.
- **Now:** each forbidden name is intercepted by a **shell function**, which takes precedence over
  builtins and applets in `sh`, `dash` and `busybox ash` alike; the PATH stubs remain for child
  processes. `t_stub_init` then calls `t_forbidden_check`, which invokes each name with a sentinel
  argument and **aborts the whole test file** if the invocation is not recorded. The harness now
  proves it can see a forbidden command before any test depends on not seeing one.
- **Test:** the interception is asserted behaviourally (invocation is recorded and returns
  non-zero) rather than via `command -v`, whose answer differs per shell — a path, a bare applet
  name, or a function name — while the property under test does not. Names busybox reports in its
  own `--list` get an extra explicit case, so the check tracks the build in use. The abort path is
  proven in a child shell by adding a name with no shadow and no stub, rather than by removing a
  real shadow, so the failure path is exercised without ever invoking a real `passwd` or `su`.
- **Non-vacuity:** with only the function shadows reverted (the state the F25 fix left behind),
  `busybox sh` fails **6 of 69** — precisely `passwd`, `chpasswd`, `su` — while the identical tree
  passes **69/0** under `dash`. That asymmetry *is* the bug: it was invisible to two of the three
  shells, and only the CI cell nobody reads closely was affected.
- **Residual limitation, not fixed:** a `busybox ash` **child process** would still prefer its
  applet over the PATH stub. No test asserts absence across such a child (the suite sources
  `socks5.sh` into the current shell), and `t_forbidden_check` fails loudly rather than quietly if
  this shell's interception ever stops working. Recorded here rather than papered over.

### Round 6 hygiene (no behaviour change)
- `tests/lib/assert.sh`'s `t_mode_of` comment promised an `ls` fallback that does not exist. A
  reader trusting it would have believed a mode comparison was more robust than it is. The comment
  now says what the code does: `stat -c` or the literal string `unknown`, which makes `assert_mode`
  fail loudly instead of comparing against a guess.
- `tests/protocol/acl_resolution.sh` did not reject an empty `PASSFILE`. `run_protocol.sh` always
  had that guard, and for a reason that applies identically here: an empty password is rejected by
  the proxy for a reason unrelated to the destination ACL, so all six deny checks would have been
  recorded as "the deny held" with no password ever sent. It now exits 2 (inconclusive) before any
  scoring. Covered by a line-order assertion as well as an exit-code one, because the isolation
  guard in the same file also exits 2 and the exit code alone cannot say which one fired.

### Round 6: what remains deliberate
- **`\|` still appears in the test files' own grep patterns.** The round-5 waiver stands, and F25/F26
  are unrelated to it: those patterns were never the problem — the transcript they searched was
  empty. The ban enforced by `test_skeleton.sh` covers the shipped artifact, which is where the
  fail-open risk lives.
- **`t_assert_never_called` does not fail on an empty transcript.** It would be tempting to make it
  do so, but `test_precheck.sh` legitimately expects an empty transcript ("the gate failed, so
  nothing ran"). The defect was stub coverage, not the helper; F26's `t_forbidden_check` puts the
  fail-closed check where it belongs — at initialisation, once per file.

---

## Round 5: every finding from round 4 fixed, including the ones round 4 had waived

Round 4 closed with four findings marked "deliberately not changed". Re-examined one at a time,
three of them were real defects and one was genuinely deliberate. Two further defects were found
while writing their tests. Each fix below was reproduced against the unfixed source first, or —
where the reproduction needed an environment this machine does not have — proven non-vacuous by
reverting only the fix in a `mktemp -d` copy and watching the new tests fail.

### F17 — HIGH: the config security check could fail OPEN on a POSIX-conforming grep
- **Was:** three of the checks in `s5_static_check_cfg` used `\|` alternation inside a **basic**
  regular expression — `grep -q 'auth none\|auth iponly'`, `grep -q 'BIND\|UDPASSOC'`, and
  `grep -q "^$_scd\([[:space:]]\|\$\)"` for all 20 forbidden directives. POSIX does not define `\|`
  in a BRE; it is a GNU extension that busybox and ugrep also implement. A `grep` that follows
  POSIX to the letter matches such a pattern **literally**, so nothing ever matches and the check
  passes a configuration it was written to reject. These were also the only three checks in the
  function with no test coverage at all, so the gap was invisible.
- **Now:** all three are `grep -E`, which POSIX does define. Verified against the two grep
  implementations the **suite actually runs on**: GNU grep 3.7 (what `sh` and `dash` resolve `grep`
  to on this machine) and busybox grep 1.30.1 (busybox `sh` resolves `grep` to its own applet, not
  to `/usr/bin/grep`). Includes checking that the trailing `([[:space:]]|$)` group still keeps
  `systemctlish` from being read as the forbidden `system`.
  *Correction to an earlier draft of this entry, which claimed verification against "ugrep 7.8.4
  and busybox 1.30.1". ugrep 7.8.4 is installed here, but only as a shell function in the
  interactive zsh; every test run goes through `sh`, `dash` or `busybox sh`, none of which sees it.
  No test result in this file was ever produced by ugrep.*
  **Neither of the two greps used here is POSIX-strict, so the fail-open this fix prevents cannot
  be reproduced locally at all** — it is proven by substituting `grep -qF`, which is precisely what
  a conforming grep does with a BRE `\|`. See the non-vacuity note below.
- **Test:** `tests/unit/test_static_check.sh` — 46 new assertions: `auth none` and `auth iponly`
  substituted for `auth strong` the way a mistaken operator would; `CONNECT,BIND` and
  `CONNECT,UDPASSOC` granted the way 3proxy actually spells it; **all 20** forbidden directives one
  at a time with an argument; one bare directive with nothing after it (the other half of the
  alternation); and a negative case proving a longer word that merely *starts* with a forbidden
  directive is not flagged.
- **Non-vacuity:** in a `mktemp -d` copy the three patterns were changed to `grep -qF` of the same
  text, which is exactly what a strict POSIX grep does with them — **36 passed / 42 failed**. The
  failures name the fail-open precisely: `forbidden directive [plugin] is rejected: value should
  not be [0]`. A config carrying `plugin` — arbitrary code loaded into the proxy — passed the
  security check with status 0.
- **Regression guard:** `tests/unit/test_skeleton.sh` now bans `\|` in `socks5.sh` outright,
  alongside the existing bashism and `eval` bans, so the construct cannot come back unnoticed.

### F18 — LOW: the port paths reported a state they had never observed
- **Was:** `s5_port_free` is fail-closed and answers "not free" when it cannot look at all, which is
  correct for a check but wrong to repeat verbatim. `s5_random_port` looped 50 times over that
  answer, emitting **50 identical** "cannot determine whether port N is free" warnings, then failed
  with `no free port found in 20000-60000 after 50 attempts` — blaming a port range it had never
  managed to observe. `s5_prompt_port` reported the operator's own port as **"already in use"** on
  the same evidence, which is the F14 conflation of "cannot observe" with an affirmative state,
  surviving in the diagnosis instead of in the logic.
- **Now:** both check `s5_port_probe_available` once, up front, and stop with one shared diagnosis
  (`s5_err_no_probe`) that names the missing tool and how to install it. `s5_prompt_port` says so
  *before* asking a question whose answer it cannot verify. The outcome is unchanged — both paths
  already failed, fail-closed, in this situation — so this is a diagnosis fix, not a behaviour
  change, which is why it is LOW.
- **Also:** `s5_port_probe_available` moved from the service section up beside `s5_port_free`, whose
  gate conditions its own comment says it must mirror, and now precedes all three callers.
- **Test:** `tests/unit/test_input.sh` — 9 new assertions, including a bound on the *number* of
  warnings, an assertion that the port range is no longer blamed, and an assertion that a port that
  was never observed is not called "already in use". The prompt case runs in the current shell with
  a `SENTINEL-NOT-A-PORT` pre-seed rather than through `t_run`, because `t_run`'s command
  substitution would hide whether `S5_PORT` was assigned.
- **Non-vacuity:** written first; against the unfixed source **102 passed / 3 failed**, with the
  transcript showing `the missing probe is reported 50 times, not once`.

### F19 — LOW: every command silently accepted arguments it then discarded
- **Was:** `s5_main` forwarded `"$@"` to each command function, and none of them looks at it. So
  `socks5.sh install --port 1080` ran a plain interactive install, exit 0, with nothing to tell the
  operator the option had meant nothing — the worst outcome of the three (accept, reject, or honour).
  SPEC §10 defines the grammar as a single bare command; nothing in it takes an argument or option.
- **Now:** leftover words on any of the five commands are a usage error — `s5_err "<cmd> takes no
  arguments: <words>"`, usage to stderr, exit 64, the same mechanism an unknown subcommand already
  used. `--help`/`help` still print usage and exit 0, and the no-argument auto path is untouched.
  The dispatch arms no longer pass `"$@"` at all.
- **Test:** `tests/unit/test_skeleton.sh` — 26 new assertions. The five `s5_cmd_*` bodies are
  replaced by markers, so the dispatcher is exercised in full **without letting `install`,
  `restart` or `uninstall` run on a development machine**: each command is checked to still run on
  its own, to receive an empty argument list, to exit 64 with an extra word, and not to have run
  anyway.
- **Non-vacuity:** written first; against the unfixed source **52 passed / 15 failed**, every
  failure of the form `[install --port 1080] exits 64: expected [64] got [0]` with
  `RAN:install ARGS:[--port 1080]` in the transcript.

### F20 — LOW: `s5_redact` glued multi-line messages into one line
- **Was:** the awk program ended each line with `printf "%s%s", out, line` — no newline. A message
  containing embedded newlines came back as `first ***REDACTED***second linethird ***REDACTED***`.
  Round 4 waived this because no caller passes newlines today; that makes it latent, not absent, and
  the redactor is the one function every log line passes through.
- **Now:** `printf "%s%s\n", out, line`. The redacting and passthrough paths now produce identical
  shape, which is asserted directly.
- **Test / non-vacuity:** `tests/unit/test_skeleton.sh` — 2 new assertions, written first, failing
  against the unfixed source (`TESTS 38 2`) with the glued line quoted in the failure message.

### Round 5: three defects in the test suite itself
- **A vacuous assertion.** `tests/unit/test_input.sh`'s `assert_eq "mismatch leaves the password
  unset" "" "$S5_PASSWORD"` ran the prompt through `t_run`, which captures output in a command
  substitution — the callee is a subshell, so no global it sets is visible afterwards. The
  assertion passed no matter what `s5_prompt_password` did. It now runs in the current shell with
  `S5_PASSWORD='SENTINEL-NOT-A-REAL-PASSWORD'` pre-seeded and asserts seven real post-conditions.
  **Proof it is no longer vacuous:** injecting `S5_PASSWORD=$_pw1; S5_SECRET=$S5_PASSWORD` before
  the confirmation prompt produces **3 failures**; the old form caught none.
- **A dead guard.** `tests/unit/test_state.sh`'s `rm -rf` check piped `grep -n` output through
  `grep -qv '^\s*#'`, a condition that can never match because every line of that input starts with
  a digit; the outer and inner conditions also disagreed about which occurrence was allowed. It is
  now an exact count plus an ownership check on `s5_rm_workdir`. **Proof:** injecting an unguarded
  `rm -rf "$1"` into a second function is caught by the new check and was **missed** by the old one.
- **A password in an argv.** `tests/unit/test_secure_files.sh` built its symlink-refusal case as
  `sh -c "... S5_PASSWORD='$PASS_OK' ..."`, putting a password in a child process's argv where `ps`
  shows it to every user on the machine — the exact thing `socks5.sh` is forbidden to do and that
  `t_assert_no_secret_in_argv` exists to catch elsewhere. The pipeline is now wrapped in a shell
  function instead, so no child process is spawned at all. Same assertions, still non-vacuous:
  neutering the atomic-write symlink refusal in a scratch copy yields **41 passed / 2 failed**. It
  was the only `sh -c` in the suite.

### Round 5 hygiene (no behaviour change)
- `tests/protocol/start_engine.sh` printed the rendered config under the heading *"paths and
  credentials elided"*. The rendered config contains no credentials at all — only
  `users $<confdir>/users.cfg` — so the heading claimed a redaction that was neither happening nor
  needed, which is exactly the kind of line that makes a reader trust a CI log they should be
  reading closely. It now says no credentials appear in it. **CI-only file: not executed locally**
  (`sh -n`, `dash -n` and `busybox sh -n` clean).

### Round 5: what remains deliberate
- **`s5_maybe_open_firewall` still records the rule *after* opening it**, inverting F3's order.
  Recording first would make `s5_firewall_close` run `ufw delete allow` against a rule that was
  never added, which exits 1 and turns a no-op into a false uninstall failure. F16 closes the
  window instead of reversing the order. This is the one round-4 waiver that survived re-examination.
- **`\|` remains in three test-file grep patterns.** Counted, not estimated: excluding comment lines,
  the construct survives in `test_account.sh:25` (an `-E` pattern matching the shell operator `||`
  in the source, where `\|` is a correctly-escaped literal, not alternation),
  `test_skeleton.sh:51` (the ban's own pattern), and `test_probe_tooling.sh:658` (the retired
  trailing-space pattern, kept deliberately as the counter-example that F27 must NOT match).
  Every genuine *absence assertion* that once depended on BRE alternation is gone — F27 replaced
  them with `t_assert_cmd_never_called` and added a structural guard so they cannot come back.
  *Correction to an earlier draft, which said "seven test-file grep patterns" and cited
  `t_assert_never_called '^passwd \|^chpasswd '` as a live example. That pattern is no longer a
  live guard, and the count was an over-estimate that included comment lines describing the bug.*
  The remaining three are safe under GNU grep 3.7 and busybox grep 1.30.1, the only two the suite
  runs on; the ban added in F17 covers the shipped artifact, which is where the fail-open risk lives.

---

## Round 4: full line-by-line review of every file

Coverage was checked against a complete `find` inventory, not a sample: `socks5.sh`, all 19 unit
tests, `tests/run.sh`, `tests/lib/{assert,env,stub}.sh`, the stubs, all 16 os-release fixtures,
both goldens, both Python tools, the three protocol scripts, `.github/workflows/ci.yml`,
`SPEC.md`, `README.md`, `LICENSE`, `tasks/plan.md`, `tasks/todo.md`.

Three real defects were found — two in `socks5.sh`'s failure handling and one in its pre-flight
gate. Each was reproduced against the unfixed source before being fixed, and each fix was then
proven non-vacuous by reverting it in a scratch copy and watching the new test fail.

### F14 — MEDIUM: `status` reported a listener it could not observe
- **Was:** `s5_port_free` is deliberately fail-closed — with neither `ss` nor `netstat` present it
  warns and answers "not free". `s5_port_listening` was defined as the negation of that answer, so
  the fail-closed "not free" became an affirmative **"listening"**. Against the unfixed source the
  new test captured `status` printing, two lines apart:

  ```
  [!] cannot determine whether port 31080 is free (neither ss nor netstat found)
      service   : not running (systemd)
      port      : listening on 0.0.0.0:31080
  ```

  It simultaneously warned it could not tell, said the service was **not running**, and claimed a
  listener. That is the exact mirror image of F4 (a non-root `status` claiming a firewall rule had
  vanished when it merely could not check). The same inversion made the install-time verification
  fail **open**: `if ! s5_port_listening` accepted "cannot observe" as a passed check.
- **Now:** a three-valued `s5_port_listening` — `0` listening, `1` not listening, `2` cannot
  observe — plus a new `s5_port_probe_available` that gates on *exactly* the same conditions as
  `s5_port_free` so the two can never disagree. Both call sites capture the status before testing
  it (the pattern `s5_cmd_install` already used) instead of negating it. `status` now prints
  `31080 (listen state not verified: neither ss nor netstat found)` and no longer emits the
  contradictory port-free warning.
- **Test:** `tests/unit/test_port_state.sh` — 29 assertions. Observable-listening and
  observable-free paths, the tri-state contract directly, structural assertions that neither caller
  negates the function (comments stripped first, since the fix quotes the old bug), a drift guard
  tying `s5_port_probe_available`'s conditions to `s5_port_free`'s, and the no-probe regression.
- **Non-vacuity:** reverting only `s5_port_listening` to the two-state form in a `mktemp -d` copy,
  leaving the callers fixed, yields **19 passed / 10 failed**.
- **Reachability, stated honestly:** only the `status` half is reachable today. `s5_prompt_port` and
  `s5_random_port` both call the same fail-closed `s5_port_free` and abort the install long before
  the verification step, so the install-side fail-open could not be reached — it is fixed and proven
  structurally rather than with a functional case that cannot be constructed.

### F15 — LOW: `S5_BASE_COMMANDS` did not cover every hard-failure call site
- **Was:** `s5_precheck`'s stated job is "every gate that must pass BEFORE the first prompt", but
  the base-command list omitted four utilities the script invokes at sites that hard-fail: `chown`
  (credential-file ownership; failure aborts and rolls back), `uname` (read on the very next line
  of `s5_precheck` itself), `tail` (destination-deny ordering check) and `rmdir` (uninstall refuses
  to continue when it cannot remove a directory). A machine missing one would fail mid-install with
  an obscure error instead of being told by name up front.
- **Now:** the four are required. `stty` is deliberately **still** excluded — every `stty` call site
  already tolerates its absence (`2>/dev/null || true`), so requiring it would abort installs that
  would otherwise succeed. The comment records that reasoning.
- **Test:** `tests/unit/test_precheck.sh` — the four are asserted present, `stty` is asserted
  absent, and the existing "the toolchain we install later must not be listed" assertions (`gcc`,
  `make`, `git`) still hold.
- **Non-vacuity:** the assertions were written first and failed 4/4 against the unfixed list
  (`TESTS 87 4`), then passed after the one-line change (`TESTS 91 0`).
- **Severity is LOW, not higher:** `tail`'s absence already failed *closed* — an empty
  `_sclastdeny` makes `s5_static_check_cfg` report "no destination deny rules found" and abort. No
  path fails open; the defect is diagnosis quality, not safety.

### F16 — MEDIUM: a firewall rule opened but not recorded was left behind
- **Was:** `s5_maybe_open_firewall` opens the rule and *then* records it, which is the reverse of
  F3's record-before-create order — and necessarily so, because over-recording a ufw rule that was
  never added makes `ufw delete allow` exit 1 and uninstall report a false failure. But nothing
  handled the window between the two: if `s5_state_add firewall` failed, the function returned 1
  while printing *"aborting to avoid orphaned resources"* — and the resource **was** orphaned. The
  rule existed on the system, was absent from the state file, and was therefore invisible to both
  rollback and `uninstall`. `s5_install_steps` also discarded the status, so the install continued
  and only aborted later by coincidence, when `s5_state_add status complete` hit the same
  unwritable state file.
- **Now:** when the record cannot be written, the rule is closed again with the same precise
  `s5_firewall_close` that uninstall uses, and the operator is told it was withdrawn and why. If the
  undo *also* fails, the message names the backend and port and says to remove it by hand. Either
  way the function returns 1, and `s5_install_steps` now propagates that instead of ignoring it —
  correctness no longer depends on a downstream write happening to fail too. For firewalld the zone
  is now recorded *before* the backend, because a stray `firewall_zone` with no `firewall` is inert
  whereas a `firewall` with no zone makes `s5_firewall_close` refuse to guess and report a rollback
  failure for a rule that had already been removed.
- **Test:** `tests/unit/test_install.sh` — 14 new assertions. The state directory is made
  unwritable (`chmod 0500`) at exactly that moment, so the failure is real rather than mocked; the
  transcript is checked to prove the rule was genuinely opened *and then* deleted; a `t_stub_script`
  ufw that succeeds on `allow` and fails on `delete` covers the undo-also-failed branch; a firewalld
  case covers the zone path; and structural assertions forbid the bare, status-discarding call and
  pin the zone-before-backend order.
- **Non-vacuity:** reverting the undo and the caller guard in a `mktemp -d` copy yields **130 passed
  / 7 failed**, with the transcript showing `ufw status; ufw allow 31080/tcp` and no delete — the
  orphan, captured. Swapping only the two `s5_state_add` lines back fails the ordering assertion
  alone (**136 / 1**).
- **Order note:** unlike F14 and F15 the test was written after the fix, so non-vacuity was
  established by running it against a reverted copy of the source rather than against the original
  file. The evidence is the same; the sequence was not.

### Round 4 hygiene (no behaviour change)
- `tasks/plan.md` Task 8 still claimed "the 4 Alpine cells are non-blocking for build and install
  failures", citing SPEC §13 — which actually says the opposite (`SPEC.md:260`: *"There is no
  experimental tier: all 16 cells block the release, Alpine included."*). The shipped CI has zero
  `continue-on-error` keys and README no longer calls Alpine experimental, so plan.md was the only
  stale copy. Both the acceptance criterion and the risk-table mitigation now match the spec.
- Dead code removed: `tests/pty/interrupt.py`'s `os.close(slave_dup := -1) if False else None`
  (a no-op; the parent must genuinely keep `slave` open so `echo_enabled(slave)` works after the
  child exits — that is now a comment instead) and the discarded `grep -c '' >/dev/null` in
  `tests/unit/test_render.sh:42`.
- Added `.gitignore` for `__pycache__/` and `*.pyc` — the only generated files in the tree, left by
  the `py_compile` syntax checks. Every test scratch tree is already created with `mktemp -d`.

### Round 4 findings deliberately NOT changed — three of the four were fixed in round 5
- **`s5_maybe_open_firewall` still records the rule *after* opening it**, inverting F3's order. That
  direction is deliberate and is now documented in the code: recording first would make
  `s5_firewall_close` run `ufw delete allow` against a rule that was never added, which exits 1 and
  turns a no-op into a false uninstall failure. F16 closes the window instead of reversing the order.
  **This is the only one of the four that survived round 5's re-examination.**
- ~~`s5_redact` joins multi-line input without newlines. No caller passes embedded newlines today.~~
  **Overturned — fixed as F20.** "No caller does this today" made it latent, not absent, in the one
  function every log line passes through.
- ~~Subcommands ignore extra `argv`. Harmless and outside the frozen SPEC's CLI contract.~~
  **Overturned — fixed as F19.** SPEC §10 *is* the CLI contract, and it defines a single bare
  command; silently discarding an option the operator typed is the worst of the three possible
  behaviours.
- ~~`s5_random_port` can emit up to 50 fail-closed warnings; the noise is bounded and points at the
  real cause.~~ **Overturned — fixed as F18.** The noise was bounded, but the final message blamed
  the port range rather than the missing probe, and the same evidence made `s5_prompt_port` call a
  never-observed port "already in use".

---

## Round 2: findings from the independent re-audit, with fixes

Every item was reproduced by a new regression test FIRST, then fixed minimally, then
re-run. Each test was additionally proven **non-vacuous** by re-introducing the bug in a
scratch copy and observing the test fail.

### F1 — BLOCKER: the nine-deny check could fail OPEN
- **Was:** `s5_static_check_cfg` wrote its findings to `"$cfg.denycheck.$$"` with the
  redirect wrapped in `2>/dev/null || true`. When that write failed — read-only config
  directory, full disk, or a hostile pre-created path — the result file was empty, the
  `[ -s ]` test was false, and a configuration **missing destination deny rules passed
  the security check**. It also created a predictable scratch file next to the config.
- **Now:** counted entirely in the shell with no scratch file and no `|| true`. The
  expected count is derived from `$S5_DENY_CIDRS` rather than hard-coded to 9.
- **Test:** `tests/unit/test_static_check.sh` — 26 assertions. Rejects a config with
  denies removed *while the config directory is read-only*, rejects each of the nine
  CIDRs individually, rejects a deny moved after the allow, and rejects a duplicate
  standing in for a missing CIDR. Asserts the check writes nothing into the config dir.
- **Non-vacuity:** re-introducing the scratch-file version produces **3 failures**.

### F2 — HIGH: CI put the proxy credential into an environment variable
- **Was:** `PROXY_PASS=$(cat "$SECRETS/pass")` in four CI jobs. The credential entered
  the environment of the test process and every child, readable via `/proc/<pid>/environ`
  and liable to appear in a crash dump or a debug trace.
- **Now:** the protocol scripts take `PASSFILE=<path to a 0600 file>` and read it into a
  shell variable that is never exported. `PROXY_PASS` occurrences in CI: **0**.
- **Test:** `tests/unit/test_audit2.sh` asserts CI contains no `PROXY_PASS`, no
  `PASS=$(cat ...)` env assignment, and that both protocol scripts take a `PASSFILE`.
- **Non-vacuity:** restoring the env-var form produces **3 failures**.

### F3 — MEDIUM: resources were recorded AFTER being created
- **Was:** `s5_install_steps` created a resource and *then* recorded the flag, so a state
  write that failed at that moment left the resource orphaned — invisible to rollback and
  to uninstall.
- **Now:** every flag is recorded *before* the creating call, in `s5_install_steps` and in
  `s5_service_install`. The teardown helpers already treat a flagged-but-absent resource
  as gone, so the safe direction is to over-record.
- **Test:** structural assertions on the order of every mark/create pair, plus functional
  proof that teardown tolerates flagged-but-absent resources and that a failure
  immediately after a flag still rolls back cleanly.
- **Non-vacuity:** reverting one pair produces the expected failure.

### F4 — MEDIUM: `status` claimed a firewall rule had vanished when it merely could not check
- **Was:** querying ufw/firewalld/iptables needs root; a non-root `status` therefore
  reported `rule RECORDED BUT NO LONGER PRESENT`, which is a false alarm.
- **Now:** a non-root reader is told `rule recorded (not verified: checking it requires
  root)`. Absence is only claimed when the check actually ran.
- **Test:** asserts the non-root path never says `NO LONGER PRESENT`, and that the root
  path still distinguishes present from vanished.
- **Non-vacuity:** removing the branch produces **2 failures**.

### F5 — MEDIUM: the test runner reported an assertion-free file as `ok`
- **Was:** a unit file that exited before `t_summary` emitted no `TESTS` line, and
  `tests/run.sh` printed `ok` for it. A test file broken by an early `exit` would have
  been silently counted as passing.
- **Now:** a missing `TESTS` line, or zero assertions with zero skips, is a **FAIL**.
- **Non-vacuity:** a scratch no-op test file is now reported
  `FAIL zz_noop.sh (no TESTS line: the file asserted nothing)`.

### F6 — LOW: broken scaffolding in the ACL test
- `acl_resolution.sh` launched `python3 -` twice against a heredoc that had not been
  written yet, then killed the strays and wrote the listener into the repo directory.
  Replaced with a single listener written into a `mktemp -d` and cleaned up by the trap.

### F7 — LOW: dead code
- `S5_INSTALL_ACTIVE` (assigned, never read) removed. The unused `CHECKOUT_SHA` workflow
  env entry removed; the pin lives on each `uses:` line where it actually applies.

### F8 — HIGH: the CI doc-lint would have failed the whole workflow on first push
- **Was:** the SOCKS4 allowlist in `.github/workflows/ci.yml` had drifted out of step
  with the identical guard in `tests/unit/test_docs.sh`, which additionally allows
  `fails`. README's own sentence "A SOCKS4-family success ... **fails** the job
  outright" therefore matched nothing in the CI list, so the lint job would have
  emitted that line and `exit 1`. The local suite was green only because the two
  allowlists differed — a latent, guaranteed CI failure.
- **Now:** the two patterns are byte-identical, and a test asserts they stay so.
- **Test:** `tests/unit/test_ci_lint.sh` runs **both** pipelines against the real README
  and requires identical results, and proves the allowlist is not a catch-all by
  appending a genuine `socks4://` advertisement to a scratch copy and checking it is
  still caught.
- **Non-vacuity:** reverting the allowlist produces **3 failures**.

### F9 — MEDIUM: the CI log-redaction put the password in `sed`'s argv
- **Was:** `sed -e "s/$(cat "$SECRETS/pass")/***/g"` in the systemd-integration job.
  The redaction worked, but the plaintext password appeared in sed's own argv, visible
  to `ps` — contradicting the invariant claimed two lines above it.
- **Now:** the substitution is written into a `0600` `redact.sed` script file and applied
  with `sed -f`. The password never enters an argument list.
- **Test:** asserts no CI command interpolates `$(cat …/pass)` into an argument, and
  that redaction uses a script file.
- **Non-vacuity:** restoring the argv form produces **3 failures**.

### F10 — LOW: `curl --socks4` failing for an unrelated reason read as "rejected"
- **Was:** any non-zero curl status counted as a SOCKS4 rejection, so a curl build
  without SOCKS4 support, or a DNS failure, would have been recorded as evidence.
- **Now:** the status is classified — `0` is a gate violation, `97` (CURLE_PROXY) is a
  genuine proxy refusal, anything else is reported as indicative only, with the probe
  case named as authoritative. The probe cases still treat ERROR as a failure.
- **Non-vacuity:** reverting produces a failure.

### F11 — LOW: a truncated SOCKS5 GRANT reply read as a refusal
- **Was:** `socks5_request` read the 4-byte reply head, then the address tail; an EOF
  during the tail propagated to the caller's `except EOFError` and returned REFUSED. A
  truncated **grant** would therefore have passed the gate.
- **Now:** a distinct `TruncatedReply` exception is raised once the head has arrived, and
  every SOCKS5 mode maps it to ERROR (exit 2), which the runner treats as a failure. The
  three outcomes are documented accordingly.
- **Non-vacuity:** mapping it back to REFUSED produces a failure.
- **Behavioural proof:** a fake proxy that sends a GRANT head followed by a truncated
  address tail now yields probe exit **2** (ERROR). A complete GRANT still yields **0**
  and a `0x02` refusal still yields **1**, so the fix is precise rather than blanket.

### F12 — MEDIUM: SPEC contradicted the shipped artifact on OpenRC logging
- **Was:** SPEC §9 still described `depend() { need net; ... }` with an ordinary
  `output_log`/`error_log` file, and §18 still listed the self-test URL and the OpenRC log
  path as open questions. All four had been decided and changed: the artifact uses
  `after firewall; use dns logger`, logs to syslog via `logger`, and fixes the self-test
  URL. The golden fixture and `test_render.sh` asserted the new behaviour, so SPEC was the
  only stale copy — a frozen spec disagreeing with the code it governs.
- **Now:** §2 records the fixed self-test URL, §9 describes the real `depend()` block and
  syslog logging, §18 states no open questions remain.
- **Test:** `tests/unit/test_docs.sh` derives the expectation from
  `tests/golden/openrc-init` itself, so SPEC and artifact can no longer drift apart. The
  assertion distinguishes an affirmative claim from an explicit negation, so documenting
  "`need net` is deliberately not used" is correct rather than flagged.
- **Non-vacuity:** restoring the old SPEC wording produces the expected failure.

### F13 — LOW: the lint job's self-checks were not themselves tested
- **Was:** the lint job greps its own workflow file. Nothing verified that its patterns
  do not match their own text — precisely how F8 arose. My first pass at this test was
  itself vacuous: it hardcoded a *correct* pattern instead of the one the CI uses, so
  breaking the CI did not trip it.
- **Now:** the test extracts the job-count and timeout-count patterns from `ci.yml` and
  runs them, so it fails if the CI's own patterns are wrong, and additionally requires the
  timeout pattern to be line-anchored.
- **Non-vacuity:** replacing the CI's anchored pattern with an unanchored one produces
  **2 failures** (`expected [7] got [8]`, plus the anchoring assertion).
- **Note:** the workflow itself was correct — 7 jobs, 7 timeouts, confirmed by both the
  anchored grep and a PyYAML parse. An unanchored ad-hoc grep of mine was the loose one.

---

## Round 1 findings — re-verified in round 2

| ID | Round-1 finding | Round-2 status |
|---|---|---|
| B1 | `umask 077` never set | **Holds.** `socks5.sh:13`, before `set -u`. 43 assertions in `test_secure_files.sh` observe real modes under inherited umask 0022/0000/0077. |
| B2 | `rm -rf` on untrusted state paths | **Holds.** Exactly one `rm -rf` remains (the whitelisted build-dir helper). State stores flags only; 20 hostile state files each prove an external sentinel survives. |
| B3 | No traps; echo lost on Ctrl-C | **Holds.** `stty -g` save/restore; EXIT/HUP/INT/TERM; the PTY test sends a real `SIGINT` and asserts `ECHO` is restored. |
| H1 | CIDR denies bypassable by hostname | **Holds refuted.** Source order re-read at the pinned commit: `src/socks.c:134` resolves, `:196` runs the ACL, `src/acl.c:53-55` matches the resolved address, `:186` reuses it. Runtime gate in `acl-resolution`. |
| H2 | Alpine `continue-on-error` dead wiring | **Holds.** PyYAML parse confirms `continue-on-error` is absent as a key from all 7 jobs. |
| H3 | Committed CI password / 0.0.0.0 proxy | **Holds, improved by F2.** Runtime-generated, now file-passed, loopback-confined. |
| H4 | Account removal swallowed failures | **Holds.** Stateful stubs prove failure ⇒ non-zero + retained state + named survivors. |
| H5 | Pre-check helpers never called | **Holds.** `s5_precheck` gates before the first prompt; dead symbols absent. |
| M1 | SPEC vs implementation divergence | **Holds.** SPEC §6 == renderer == golden, byte-identical (verified again this round). |
| M2 | `s5_load_credentials` unvalidated | **Holds.** Re-validates; `show` refuses a malformed file. |
| M3 | Bad-credential test passed on any curl failure | **Holds.** Only curl `97` counts. |
| M4 | Probe scored EOF as a tool error | **Holds.** EOF ⇒ REFUSED in every mode; three outcomes distinct. |
| M5 | `firewall-cmd --reload` | **Holds.** Zero occurrences; zone recorded and reused. |
| M6 | iptables non-persistence undocumented | **Holds.** README table + `status` warning. |
| M7 | `USER` collided with the ambient variable | **Holds.** `PROXY_USER`; and the password is now a file, not `PROXY_PASS`. |
| M8/M9 | Mutable action tag; no timeouts | **Holds.** SHA re-verified live against the official repo this round; 7 jobs / 7 timeouts. |
| M10/M11/M12 | Unchecked state writes; `S5_STATEDIR` collision; CI scope | **Holds**, and F3 strengthens M10. |
| LOW-1/2/3 | xtrace; `iptables -C`; sed-regex redaction | **Holds.** `set +x` at `socks5.sh:16`; `iptables -C` pre-check; awk literal replacement. |

---

## Local evidence, actually run this round

```
33 shell files x {sh -n, dash -n, busybox sh -n}   99 checks, 0 failures
py_compile socks_probe.py                  EXIT=0
py_compile interrupt.py (PTY)              EXIT=0
sh tests/run.sh                            EXIT=0   20 files, 1298 passed, 0 failed
S5_TEST_SHELL=dash sh tests/run.sh         EXIT=0   20 files, 1298 passed, 0 failed
S5_TEST_SHELL='busybox sh' sh tests/run.sh EXIT=0   20 files, 1298 passed, 0 failed

test_account       EXIT=0   37 assertions   (service account, never a password)
test_audit2        EXIT=0   90 assertions   (guard completeness, CI secrets)
test_build         EXIT=0   48 assertions   (pinned commit, verified HEAD, F25 systemctl stub)
test_ci_lint       EXIT=0   28 assertions   (CI drift, argv leak, gate, lint self-check)
test_cleanup       EXIT=0   31 assertions   (trap / rollback)
test_detect        EXIT=0   84 assertions   (16 os-release fixtures, init detection)
test_docs          EXIT=0   96 assertions   (doc rules + SPEC-vs-artifact drift)
test_input         EXIT=0  129 assertions   (validation, prompts, F21 short-draw refusal)
test_install       EXIT=0  137 assertions   (firewall, self-test, F16 undo-on-unrecorded)
test_interrupt     EXIT=0    4 assertions   (real SIGINT under a pty)
test_lifecycle     EXIT=0   72 assertions   (install/status/show/restart/uninstall)
test_port_state    EXIT=0   29 assertions   (F14 tri-state listen report)
test_precheck      EXIT=0   91 assertions   (gate order + F15 base-command completeness)
test_probe_tooling EXIT=0   69 assertions   (F22-F26: the tooling and the harness itself)
test_render        EXIT=0   85 assertions   (config/unit/init goldens)
test_secure_files  EXIT=0   43 assertions   (umask 0022/0000/0077, symlinks, no argv secret)
test_skeleton      EXIT=0   67 assertions   (POSIX bans, F17 BRE ban, F19 argv, F20 redaction)
test_state         EXIT=0   71 assertions   (hostile state + deletion sentinel)
test_static_check  EXIT=0   78 assertions   (nine-deny fail-open + F17 denylist coverage)
test_xtrace        EXIT=0    9 assertions   (sh -x password leakage)
```

Round-6 non-vacuity proofs, each run against a `mktemp -d` copy with only the fix reverted:

```
F21  s5_random_string accepts a short draw   ->  110 passed, 19 failed
     (with s5_random_port collapsing to the constant 20000)
F22  probe argument validation removed       ->  --port notanumber exits 1, bare traceback
F23  auth failure mapped to REFUSED again    ->  authfail=1; autheof unhandled
F24  read_until deadline between reads only  ->  exit 142 (SIGALRM): it hung
F25  forbidden PATH stubs removed            ->   51 passed, 17 failed
     and, the point of the finding:
     test_install / test_render / test_detect ->  137 / 85 / 84 passed, 0 failed
     i.e. the six absence assertions could not see their own detector missing
F26  function shadows reverted, busybox sh   ->   63 passed,  6 failed (passwd, chpasswd, su)
     same tree, same test, under dash        ->   69 passed,  0 failed
```

Round-5 non-vacuity proofs, each run against a `mktemp -d` copy with only the fix reverted:

```
F17  three BREs matched literally (POSIX)   ->  36 passed, 42 failed
F18  no-probe guards removed                -> 102 passed,  3 failed
F19  s5_main forwards "$@" again             ->  52 passed, 15 failed
F20  redact printf without the newline       ->  38 passed,  2 failed
T1   password adopted before confirmation    -> mismatch case fails 3 (old form: 0)
T2   unguarded rm -rf in a second function   -> caught by the new check, missed by the old
T3   atomic-write symlink refusal neutered   ->  41 passed,  2 failed
```

Round-4 non-vacuity proofs, same method:

```
F14  s5_port_listening two-state again   ->  19 passed, 10 failed
F15  S5_BASE_COMMANDS unextended         ->  87 passed,  4 failed
F16  firewall undo + caller guard gone   -> 130 passed,  7 failed
F16  zone/backend record order swapped   -> 136 passed,  1 failed
```

SPEC §6 == renderer == `tests/golden/3proxy.cfg`: **byte-identical**. Rendered order:
9 CIDR denies on lines 5–13, `allow ... CONNECT` line 14, terminal `deny *` line 15,
`socks -4 -u2 -p<port> -i<addr>` line 16. The OpenRC renderer also matches
`tests/golden/openrc-init` byte-for-byte.

CI static confirmation (PyYAML parse): build-matrix **16 cells**, protocol **16 cells**,
`permissions: {contents: read}`, 7 jobs / 7 timeouts, no `continue-on-error` key, no
self-hosted runner, engine confined to `127.0.0.1` via the test-mode-only `S5_LISTEN`,
`PROXY_PASS` occurrences in CI: 0, `PASSFILE`: 6. `actions/checkout@11d5960a…677262`
re-verified live against `api.github.com/repos/actions/checkout/git/refs/tags/v4`.

## Remaining BLOCKER / HIGH: none

Residual, documented, non-blocking:
1. Alpine/musl build unproven until CI runs (Alpine blocks the release; the build is
   simply not yet demonstrated).
2. systemd hardening not yet exercised against a live 3proxy.
3. OpenRC `logger` availability unverified.
4. `shellcheck` has never run. It cannot be installed on this machine, and the CI `lint` job runs
   `shellcheck -s sh` at **default severity** over the whole tree, so a clean exit cannot be
   established locally — this is the same failure class as F8 (a guard that only fails in CI) and is
   the one CI-pending item that could fail on first push for a reason nobody has seen yet. It is
   stated as an unverified risk, not as a passing check.

## Standing constraints — self-checked
- [x] No `sudo`, no package install/removal, no account/service/firewall changes, no port
- [x] No writes to real `/etc` `/usr/local` `/var/lib` `/run` — all five verified absent
- [x] No `git init`, no commit, no push (still not a git repository)
- [x] Every guarded override refused in production (exit 2), each verified individually
      with all other overrides cleared
- [x] 3proxy not replaced; no features added beyond the frozen SPEC
