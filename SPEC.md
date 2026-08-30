# Spec: socks5.sh — one-click SOCKS5 proxy installer

> **Status: FROZEN RELEASE CONTRACT / IMPLEMENTATION AND EVIDENCE CI GREEN.** Round 17
> implementation commit `3b58e194887bf91a06b789353c06033b70c49c59` passed run `33281392984`
> with 45/45 jobs. Evidence-only commit `a8ed8255fba6c9bf9b8247582d6b77ebf65d8374` passed run
> `33281724740`, also 45/45. Closure commit `91fd13a` passed run `33282068288`, also 45/45, and
> immutable tag `v1.0.0` was created there. Round 18 is the `v1.0.1` candidate: it removes dead
> catalog keys, corrects comments that contradicted the code, and folds duplicated checks, leaving
> operator behaviour unchanged. Its own reachable-main run must pass 45/45 before tag `v1.0.1`.
> Tag existence is therefore the final release proof. The protocol/auth/ACL/firewall boundaries
> remain frozen.

## 1. Objective
A single-file POSIX shell script (`socks5.sh`) that interactively installs, verifies, and manages a
password-authenticated SOCKS5 proxy on a remote server the operator owns or is authorized to manage.
Engine: **3proxy 0.9.9.0**, built from a pinned upstream commit. Engine selection is closed.

**One-click means one command plus an interactive wizard**, not an unattended install: every
invocation first selects `1 中文 / 2 English` (Enter defaults to Chinese; invalid input retries),
then an install shows one default-yes confirmation and asks for port, username and password, each
of which accepts Enter for a securely generated value. Direct lifecycle commands and the
no-argument management menu select language again; locale is process-only and never persisted.
There is no non-interactive mode in v1.

### 1.1 Protocol support scope
Supported: **SOCKS5 only**, with **RFC 1929 username/password authentication**, and **CONNECT as the
only command**. Not supported, never advertised, never exampled: **SOCKS4, SOCKS4a, SOCKS4.5**,
**BIND**, **UDP ASSOCIATE**, and **unauthenticated connections**. This project deploys SOCKS5 nodes
only — it never offers or documents a SOCKS4-family service.

## 2. Tech stack (verified 2026-08-23)
- 3proxy tag `0.9.9.0`, pinned commit `da99424eac4092e3722f1a5b1844cfe80478f580` — confirmed via the
  GitHub API to be that tag, dated 2026-08-22. Source: `https://github.com/3proxy/3proxy` over HTTPS.
- Build: `make -f Makefile.Linux` from the repository root; artifact `bin/3proxy`.
- `auth strong` — man page at pinned ref: "username/password authentication required".
- `socks -u2` — same ref: "(for socks) require username/password in authentication methods". `-u`
  alone means "Never ask for username/password", so `-u2` is required, not `-u`.
- `socks -4` — same ref: "Only resolve IPv4 addresses". A resolver option alongside `-6`/`-46`/`-64`;
  it has **nothing to do with SOCKS4**.
- POSIX `sh`; must run under dash, busybox ash, and bash. `curl` is required for the self-test and
  is already present on any host that used the documented download command.
- The self-test target is fixed at `https://example.com/` and is **not** operator-overridable.

## 3. Supported targets
| OS | `/etc/os-release` | Pkg mgr | Init | Minimum version |
|---|---|---|---|---|
| Ubuntu | `ID=ubuntu` | apt | systemd | 22.04 or newer |
| Debian | `ID=debian` | apt | systemd | 12 or newer |
| Alpine | `ID=alpine` | apk | OpenRC | 3.20 or newer |
| CentOS Stream | `ID=centos` | dnf, yum fallback | systemd | 9 or newer |

**Version acceptance is a floor, not an enumeration.** A recognized `ID` at or above its minimum
version installs. The CI matrix proves Ubuntu 22.04/24.04, Debian 12/13, Alpine 3.20/3.24 and
CentOS Stream 9/10 on both architectures; a release **newer** than those installs on the same code
path with **no CI evidence behind it**. That is deliberate — refusing every future distro release
until a new version ships would turn each release into an outage for new users, which is the worse
failure — but it is untested surface, and the user-facing message advertises the floor form
("Ubuntu 22.04+, Debian 12+, Alpine 3.20+, CentOS Stream 9+") so nobody is told a newer release was
verified. Below the floor → hard error.

Arch: `x86_64`/`amd64` and `aarch64`/`arm64` only. Anything else → hard error, never guess.
**CentOS detection is exact.** Only `ID=centos` (Stream 9 or newer) installs. RHEL, Rocky, and
AlmaLinux are recognized via `ID_LIKE=rhel` and told they are *likely compatible*, but v1 **does not
install on
them**. `ID_LIKE` alone never authorizes an install. Any other OS, or a version below the floor →
hard error naming the
detected `ID` and `VERSION_ID`. **EPEL is not required** — `gcc`/`make`/`git` are in base repos.

## 4. Namespace and permissions
| Resource | Path | Owner | Mode |
|---|---|---|---|
| Binary | `/usr/local/libexec/socks5-manager/3proxy` | `root:root` | `0755` |
| Config dir | `/etc/socks5-manager/` | `root:socks5proxy` | `0750` |
| Main config | `/etc/socks5-manager/3proxy.cfg` | `root:socks5proxy` | `0640` |
| Credentials | `/etc/socks5-manager/users.cfg` | `root:socks5proxy` | `0640` |
| State | `/var/lib/socks5-manager/state` | `root:root` | `0600` |

Service name `socks5-manager.service` (systemd) / `socks5-manager` (OpenRC). Account `socks5proxy`:
system account, no home, `nologin` shell, no valid password, read-only on config. All writes happen
under `umask 077`, which **socks5.sh sets itself at startup and never inherits**, followed by
explicit `chown`/`chmod`. Every temporary file is created with `mktemp`, verified to be a regular
file and not a symlink, and confirmed to be `0600` *before* a secret is written into it. A
directory is clamped to `0700` the instant it exists and only then widened, so it is never briefly
group- or world-accessible regardless of the ambient umask.

**Collision rule:** if any resource above already exists, consult the state file to confirm this
script created it. If that cannot be confirmed, **stop with an error**. Never overwrite or adopt.

## 5. Interactive install flow — implemented
v1 is **interactive only** — there is no non-interactive or unattended mode.

**Bootstrap boundary.** `s5_guard_environment` remains the first executed security boundary. If it
refuses an unsafe inherited/test environment, it emits a fixed Chinese+English diagnostic because
no locale can safely exist yet. All later script-owned text follows the selected locale. Raw output
from external tools remains external and is not translated.

**Step 0 — language.** Every invocation asks:

```text
请选择语言 / Please select language:
1. 中文
2. English
请选择 [1-2，默认 1]:
```

Blank or `1` selects Chinese; `2` selects English; unsupported input re-prompts; EOF fails without
dispatching a command. Language is neither inherited nor exported, and is never stored in state,
config, or a file. `status`, `show`, `restart`, `uninstall`, `help`, invalid commands and the
no-argument menu all select again in each new process.

**Every interactive prompt in the script — the selector, the install confirmation, and the three
value prompts — re-prompts on invalid input at most 5 times, then gives up non-zero.** An unbounded
retry loop on a stdin that can never satisfy the prompt would hang the install rather than fail it.

**Step 1 — one install confirmation.** After non-mutating prechecks, the selected language shows
the detected OS/package-manager/init, exact §8 package list and §7 security warning. The sole
install question ends in `[Y/n]`: Enter/y/Y/yes continues, n/N/no exits, invalid input re-prompts,
and EOF fails. The destructive uninstall question remains separate and default-no `[y/N]`.

**Step 2 — prerequisites.** The §8 packages are installed immediately after confirmation and
**before** the port prompt. The port prompt cannot answer anything without a listen-state probe, so
whichever package provides `ss` (`iproute2` on Debian/Ubuntu/Alpine, `iproute` on CentOS Stream) is
installed when neither `ss` nor `netstat` is present. No secret is collected before this step.

**Step 3 — the three values.** Each accepts Enter for a generated value:

1. **Port** — Enter → random `20000–60000`. Custom must be `1024–65535`. Reject if already
   listening, observed with `ss`, falling back to `netstat`. If neither observer exists the port is
   **refused fail-closed** rather than assumed free: "cannot determine whether the port is in use" is
   not the same as "the port is free". There is deliberately **no bind probe** — binding a port to
   test it is the one thing this script must never do outside its own install step.
2. **Username** — Enter → random. Validation charset `[A-Za-z0-9_-]`, 3–32 chars; anything else
   rejected. *Generated* usernames deliberately use the narrower `[a-z0-9]` with an alphabetic first
   character and a fixed length of 12: generation stays inside the safest subset of what validation
   accepts, avoiding case-collision and quoting surprises, while a user may still supply any valid
   name.
3. **Password** — Enter → generated, **exactly 32 characters**. Typed input is not echoed
   (`stty -echo`) and is read **once**; it is not asked a second time for confirmation. Charset for
   generated and user-supplied passwords alike is **`[A-Za-z0-9._~-]`**, length **12–128**.
   Rejection names the failing rule and never echoes the input.

Both charsets are RFC 3986 unreserved, so the `socks5://user:password@host:port` URI needs no
escaping. The password never enters `argv`, environment, logs, or history — only `users.cfg`.

**Localization completeness.** Every script-owned prompt, warning, error, status, usage, menu,
uninstall and result after Step 0 has reviewed Chinese and English forms with identical dynamic
technical values. Command names (`install`, `status`, `show`, `restart`, `uninstall`), paths,
package names, protocol tokens and external-tool output are not translated.

**There is no firewall functionality.** See §7.1.

## 6. Generated configuration
`/etc/socks5-manager/3proxy.cfg` — this is the complete file, 16 lines:
```
log
users $/etc/socks5-manager/users.cfg
auth strong
flush
deny * * 0.0.0.0/8
deny * * 10.0.0.0/8
deny * * 100.64.0.0/10
deny * * 127.0.0.0/8
deny * * 169.254.0.0/16
deny * * 172.16.0.0/12
deny * * 192.168.0.0/16
deny * * 224.0.0.0/4
deny * * 240.0.0.0/4
allow <username> * * * CONNECT
deny *
socks -4 -u2 -p<port> -i0.0.0.0
```
**All nine destination deny rules are retained**, in exactly that order, and
**every one of them must precede the `allow` rule** — 3proxy evaluates rules in
file order and the first match wins, so a deny placed after the allow would
never be reached. The terminal `deny *` follows the allow; the `socks` service
line is last. The static check enforces the count, the presence of each CIDR,
the deny-before-allow ordering, and that `flush` precedes the first deny — an ACL appended after a
later `flush` would be silently discarded by the engine.

The nine ranges are this-network, RFC 1918 private space (three blocks), CGNAT,
loopback, link-local (which covers the `169.254.169.254` cloud-metadata
endpoint), multicast, and reserved space.

**These denies apply to domain targets, not only to literal IPs.** At the pinned
commit, `src/socks.c:134` resolves an `ATYP=3` domain into `param->req` via
`getip46()`; `src/socks.c:196` then calls `authfunc`, which runs `checkACL`; and
`src/acl.c:53-55` matches `acentry->dst` (our CIDR list) against `param->req` —
the resolved numeric address. The outbound connect at `src/socks.c:186` reuses
that same `param->req`, so there is no second resolution and no TOCTOU window. A
client therefore cannot reach a denied range by sending a hostname. This is
verified at runtime by `tests/protocol/acl_resolution.sh` in an isolated
container; a bypass is a release blocker.

`users.cfg` contains exactly one line and **no `users` directive** — the
directive lives in the main config; this file supplies only its argument:
```
<username>:CL:<password>
```

**Startup-line flags — neither enables SOCKS4:**
- `-4` means **IPv4 destination resolution only**. It is a resolver option in
  the same family as `-6`/`-46`/`-64` and has nothing to do with protocol
  version.
- `-u2` **requires username/password among the offered authentication methods**.
  `-u` alone means "never ask for username/password", so the `2` is load-bearing.

Both are verified against the man page at the pinned ref (§2).

**Only SOCKS5 with RFC 1929 username/password authentication and the CONNECT
command can succeed.** These must all fail: SOCKS4, SOCKS4a, SOCKS4.5,
unauthenticated SOCKS5, BIND, and UDP ASSOCIATE.

System DNS, 3proxy default timeouts, and default stdout logging are used;
`nserver`, `nscache`, custom `timeouts`, and custom `logformat` are deliberately
absent. `-e` is **not** set — the OS picks the outbound source address from the
routing table. Multi-NIC and custom outbound address are v2.

The listen address is `0.0.0.0` in production. A `S5_LISTEN` override exists so
CI can confine the engine to loopback; like every coverage variable it is
honoured only under `S5_TEST_MODE=1` and causes an immediate refusal otherwise.

**Denylist — must not appear, asserted by test:** `proxy`, `admin`, `ftppr`, `smtpp`, `pop3p`,
`imapp`, `tlspr`, `tcppm`, `udppm`, `dnspr`, `writable`, `system`, `plugin`, `parent`, `authcache`,
`chroot`, `setuid`, `setgid`, `BIND`, `UDPASSOC`, `auth none`, `auth iponly`.

### 6.1 How SOCKS4 is excluded
3proxy's `socks` gateway is documented at the pinned ref as a "SOCKS 4/4.5/5 proxy", so it parses all
three inbound. **No option to disable inbound SOCKS4 parsing exists in that ref's man page** — every
`socks4*` keyword there names a *parent* (upstream chaining) proxy type, not an inbound toggle.

Exclusion is therefore enforced by `auth strong` + `-u2` + the §6 ACL. SOCKS4 carries only a User ID
field and has no RFC 1929 password-authentication phase, so it cannot satisfy strong auth and must
fail. This is **"only SOCKS5 can succeed"** — not removal of the SOCKS4 parser from the source. The
claim is therefore a test obligation, not an assumption: see the §13 rejection tests and release gate.

## 7. Listening address and pre-install warning
v1 listens on `0.0.0.0` by default, because the target is a remote server proxy. Before install the
script displays and requires acknowledgement of:
- SOCKS5 username/password auth (RFC 1929) is **cleartext on the wire**; SOCKS5 provides **no
  transport encryption or integrity**.
- The operator must confirm their own local firewall and cloud security-group rules.
- **Anyone who learns the credentials and can reach the port can use the proxy.**

### 7.1 The script has no firewall functionality
v1 neither detects nor modifies the host firewall. There is no backend detection, no guidance
engine, no rule creation and no firewall query of any kind; nothing firewall-related is recorded in
the state file, so `uninstall` has nothing firewall-shaped to remove. The operator opens the chosen
TCP port themselves, in their own firewall and in their cloud provider's security group (which this
script cannot see). Status and the install summary still state, as a constant string, that the
firewall was not modified by this script.

Rationale: opening a port is a host-wide, security-relevant change with an ownership and rollback
problem that is disproportionate to a v1 whose job is to install one proxy. An earlier revision kept
read-only detection to print backend-specific advice; the owner removed even that by decision —
detection is functionality too.

## 8. Build procedure
1. Determine required packages and display them as part of the single §5 confirmation. apt:
   `git build-essential ca-certificates` · apk: `git build-base musl-dev linux-headers` · dnf:
   `git gcc make`. The apt list carries `ca-certificates` because a minimal Debian/Ubuntu image can
   lack a CA bundle, which would fail the HTTPS clone with a certificate error rather than a
   diagnosable one. Add
   `curl` where absent, and the `ss` provider (`iproute2`, or `iproute` on CentOS Stream) where
   neither `ss` nor `netstat` exists. Installation happens before the port prompt (§5).
2. `git clone` into `mktemp -d`, then `git checkout <commit>`.
3. Assert `git rev-parse HEAD` equals the pinned commit exactly. Mismatch → abort and clean up.
4. From the repository root, run `make -f Makefile.Linux`.
5. Copy **only** `bin/3proxy` to `/usr/local/libexec/socks5-manager/3proxy`. **Never** run
   `make install`, `scripts/postinstall.sh`, or any upstream service-install script; never install
   or enable upstream's `3proxy.service`.
6. Remove the temporary clone directory.

Build dependencies, `curl` and the `ss` provider are **not** removed — not after install, not during
uninstall. The script never uninstalls a system package; the README lists what may have been
installed.

## 9. Service integration
- **systemd:** `User=socks5proxy`, `Group=socks5proxy`,
  `ExecStart=<binary> /etc/socks5-manager/3proxy.cfg`, `Restart=on-failure`, `RestartSec=5s`, plus
  `NoNewPrivileges=yes`, `ProtectSystem=strict`, `ProtectHome=yes`, `PrivateTmp=yes` and the further
  hardening set `PrivateDevices=yes`, `ProtectKernelTunables=yes`, `ProtectKernelModules=yes`,
  `ProtectControlGroups=yes`, `LockPersonality=yes`, `SystemCallArchitectures=native`, and an empty
  `CapabilityBoundingSet=`/`AmbientCapabilities=`. Ports are
  ≥1024, so no `CAP_NET_BIND_SERVICE` — the empty capability sets make that structural rather than
  incidental. The unit also carries `Documentation=`, `After=`/`Wants=network-online.target` and
  `Type=simple`. The rendered unit is pinned byte-for-byte by
  `tests/golden/socks5-manager.service`, which is the authoritative list. Logs go to the journal.
- **OpenRC:** `command_user="socks5proxy:socks5proxy"`, `supervisor=supervise-daemon`,
  `depend() { after firewall; use dns logger; }` — `need net` is deliberately **not** used.
  Output goes to syslog through `logger` (`output_logger`/`error_logger`); **no ordinary log
  file is created**, so nothing can grow unbounded and log rotation stays a non-goal.

Privilege drop is the init system's job — no `setuid`/`setgid` in the 3proxy config.

## 10. Commands
The primary Ubuntu/Debian/CentOS command (and the same command after entering Bash on Alpine) is:

```sh
bash <(wget -qO- https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/main/socks5.sh)
```

Stock Alpine's default ash parses `<(...)` before Bash can run, so its one-line bootstrap is:

```sh
apk add --no-cache bash wget && bash -c 'bash <(wget -qO- https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/main/socks5.sh)'
```

A `curl` form of the primary command is documented as an equivalent alternative for hosts that ship
`curl` but not `wget`:

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/main/socks5.sh)
```

Under process substitution `$0` is a transient `/dev/fd/*` descriptor: operator-facing messages
must never print it. When invoked this way, re-running the command opens the management menu after
installation. Every invocation selects language before command validation/dispatch; command tokens
remain English.

```text
socks5.sh            # not installed -> interactive install; installed -> menu
socks5.sh install | status | show | restart | uninstall
```
- No `reload` in v1 — use `restart`. No `reconfigure` — to change port, user, or password,
  uninstall then reinstall.
- `show` reprints full connection details **including the password** for root, to the terminal only.
  It must never write the password to a log, file, journal, redirect, argv, environment or xtrace.
- Install and `show` use one localized credential-card renderer. It prefers one strictly validated
  IPv4 observed from the fixed HTTPS endpoint `https://icanhazip.com`; this is presentation-only,
  nonfatal and reports outbound egress, not guaranteed inbound reachability. On lookup failure, one
  validated local IPv4 is shown with exactly one localized warning; if none exists, `SERVER_IPV4`
  is shown with an actionable replacement warning. The address is resolved once per card and is
  never persisted.
- The card displays localized Host/Port/Username/Password labels, followed by exactly one
  unindented, language-independent line:

  ```text
  socks5://user:password@host:port
  ```

- The card retains the firewall/cloud-security-group and no-encryption warnings. The only URI
  scheme ever emitted is `socks5://`; no legacy-protocol scheme/example is produced.

## 11. Install and verification procedure
3proxy 0.9 has **no documented config dry-run mode**, so the config cannot be fully validated without
starting the process; this spec makes no such claim. Sequence:

1. **Static check:** required directives present, §6 denylist absent, port and listen address
   well-formed, referenced `users.cfg` exists with the correct mode.
2. **Atomic write:** write to a temp file in the same directory, `chown`/`chmod`, then `mv`.
3. **Start the service.**
4. **Verify**, each check reported independently: service active
   (`systemctl is-active` / `rc-service status`); the chosen port listening on the configured
   address; correct credentials proxy a request;
   **wrong credentials explicitly rejected** — a pass requires that failure.
   That the engine opens **no proxy port other than the chosen one** is enforced *before* the start,
   not observed after it: the §6 denylist rejects every additional listener directive and the static
   check runs before any service is started, so a config able to open a second port cannot reach the
   engine. There is no runtime socket enumeration, which would depend on `ss`/`netstat` being present
   and would turn a missing observer into a failed install.
   Every service-state observation is three-valued: active, definitely inactive, or unobservable.
   A failed manager query is never reported as an observed inactive service. Both non-active
   outcomes fail the install; they are simply named correctly.
5. **On any failure:** stop the service, delete the project resources created in this run, report.
   Never leave a half-configured service running. If the service cannot be *proved* stopped, the
   resources and the state file are **kept** and the operator is told to retry — deleting files out
   from under a possibly-live proxy is worse than an incomplete rollback.

Credential checks use `curl --config -`, feeding `socks5-hostname`, `proxy-user`, and `url` on
**stdin** via `printf`, so the password never appears in `argv`. This needs server egress; when the
service is up and the port listening but the request fails, the report must distinguish: proxy auth
failure; no outbound network; DNS failure; external test service unavailable.

## 12. Uninstall and idempotency
Uninstall removes only state-recorded resources: service unit or init script, the `socks5proxy`
account and group, `/etc/socks5-manager/`, `/var/lib/socks5-manager/`, and the installed binary.
**No firewall rule is ever removed, because none is ever created (§7.1).** It never touches a
pre-existing system 3proxy, the operator's own proxy users, any firewall rule, package repositories,
pre-existing config, or any system package. Re-running `install` on an existing project install is a
no-op plus a status report.

## 13. Testing
`tests/` — shell-based, no framework dependency.
- **Unit:** port/username/password validators, os-release parsing (including the RHEL/Rocky/Alma
  refusal path), arch mapping, config renderer, prerequisite selection and ordering, and the
  absence of firewall functionality.
- **Bilingual UI contract:** catalog key uniqueness, zh/en parity,
  declared arity, literal call-site keys, argument/format safety, no new untranslated script-owned
  literals, selector blank/1/2/invalid/EOF behavior, per-invocation locale, `[Y/n]`, password-once,
  exact zh/en card/URI, localized lifecycle/error output, and fixed bilingual pre-language guard.
- **IPv4/card contract:** canonical/public/local range validation,
  hardened fixed-endpoint curl boundary, malformed/private/multiline/oversized response rejection,
  nonfatal local/placeholder fallback, one lookup and warning per card, exact Host/URI consistency,
  and no credentials in lookup argv/stdin/env/logs.
- **Golden:** rendered `3proxy.cfg` and `users.cfg` match fixtures; §6 denylist asserted; asserted
  that `users.cfg` contains no `users` directive.
- **Protocol acceptance** (runs on every matrix cell): SOCKS5 + correct credentials + CONNECT →
  **success**; SOCKS5 + wrong password → **fail**; SOCKS5 offering no auth method → **fail**;
  SOCKS4 CONNECT → **fail**; SOCKS4a CONNECT → **fail**; SOCKS5 BIND → **fail**; SOCKS5 UDP ASSOCIATE
  → **fail**. The SOCKS4/4a cases are **rejection** tests: a pass requires refusal, never a working
  proxy.
- **Real service-install lifecycle — one per promised OS family, all four blocking:**
  Ubuntu (systemd on the runner), Debian (systemd as PID 1 in a privileged container), Alpine
  (OpenRC), CentOS Stream (systemd as PID 1 in a privileged container). Each runs
  install → status → active → listening → restart → uninstall → cleanliness. A compile-only cell and
  a direct-engine protocol cell do **not** satisfy this: neither installs a service. The Debian and
  CentOS images deliberately ship without `git`, a compiler, `curl` or an `ss` provider, so these
  jobs also prove the installer bootstraps its own prerequisites on a clean host.
- **Build matrix:** the pinned commit must compile on 8 OS versions × 2 architectures.
- **Idempotency:** install twice, assert a single service, account, and credential entry.
- **Cleanliness:** after uninstall no project file or account remains, no system package was removed,
  and no firewall rule was ever created.

systemd targets need systemd-capable containers or VMs (`systemctl` in a plain container lies).
**No tier is exempt: every cell is blocking, Alpine included.** The full 45-job workflow passed in
run `33174398814` at commit `df6885c`: all build/protocol/ACL cells and all seven real service
lifecycles (§18).

The 16 protocol cells build the pinned commit, render the production config and run the engine
**directly** — they prove the protocol boundary, not a service install. Real init-system
installation is covered separately, once per promised OS family (§13).

**Release gate (hard).** If integration testing of the pinned version shows SOCKS4 or SOCKS4a
successfully establishing a proxy connection, the test **fails** and release **must not proceed**.
Printing a warning and continuing is not permitted, and the gate has no skip flag. The only allowed
responses are to re-evaluate the engine or to carry a minimal protocol-restriction patch — never to
relax the test. This gate is not experimental on any cell, Alpine included.

## 14. Boundaries
**Always:** default-deny ACL; `umask 077` before secret writes; record every created resource in
state; verify the pinned commit; show the pre-install warning; install prerequisites before the port
prompt. The state file also records provenance and completion — `origin` (always `source-build` in
v1) and `status` — alongside the created-resource records, because `status` must be able to report
what was installed without re-deriving it.
**Ask first (one confirmation):** installing the §8 packages and proceeding with the install.
Writing anything outside the project namespace is never done at all.
**Never:** password in argv/env/logs/history; **any firewall functionality at all** — no detect, query, add, delete,
flush, enable, disable, reset or reload; touch SELinux enforcing mode or sshd config; run
`make install` or upstream post-install/service scripts; remove a system package; delete a resource
not recorded in state; implement SOCKS5 or a password hash ourselves; name, advertise, display, or
example any SOCKS4-family protocol.

## 15. Success criteria
1. One interactive run on a clean supported host yields a working authenticated SOCKS5 proxy, with
   Enter accepted at all three prompts.
2. All §11 step-4 checks pass on every cell; none is allowed to fail.
3. A `HEAD` mismatch against the pinned commit exits non-zero with no partial install.
4. Any §11 failure leaves no running service and no project resource from that run — or, when the
   service cannot be proved stopped, retains them with an actionable retry message.
5. Uninstall leaves no project artifact; no pre-existing resource, firewall rule, or system package
   is removed.
6. A second `install` run creates no duplicate service, account, or credential entry.
7. The rendered config contains no directive from the §6 denylist.
8. Grepping the journal, `/var/log`, and shell history for the generated password finds nothing.
9. `ID=rhel`/`rocky`/`almalinux` exits non-zero with "likely compatible, not supported"; any other
   unsupported OS or arch exits non-zero naming the detected values.
10. Every §13 protocol-acceptance case passes on every matrix cell, including the SOCKS4 and SOCKS4a
    rejection cases, BIND, and UDP ASSOCIATE. Any SOCKS4-family success blocks release outright.
11. No user-facing string, example, or emitted URI mentions SOCKS4, SOCKS4a, or SOCKS4.5.
12. A real install → verify → uninstall lifecycle passes on Ubuntu, Debian, Alpine and CentOS Stream.
    The listed matrix versions carry that evidence. Newer releases admitted by the §3 version floors
    use the same code path but are explicitly **accepted without a claim that CI has verified that
    exact release**; no document may blur that distinction.
13. The documented install commands are runnable as written, including the separate stock-Alpine
    bootstrap whose inner string is parsed by Bash rather than ash.
14. Every invocation selects Chinese/English before dispatch; blank defaults Chinese, invalid input
    retries, and every later script-owned message follows the selection. Locale is never persisted.
15. Install asks exactly one default-yes confirmation; a custom password is hidden and read once;
    Enter-generated port/username/password continue using the existing secure generators.
16. Install and `show` render one exact URI using one resolved IPv4. Public lookup failure is
    nonfatal and yields exactly one localized local/placeholder warning; lookup receives no secret.
17. Round 17 implementation commit `3b58e194887bf91a06b789353c06033b70c49c59` passed run
    `33281392984` with 45/45 jobs. Evidence-only commit
    `a8ed8255fba6c9bf9b8247582d6b77ebf65d8374` passed run `33281724740`, also 45/45. This closure
    commit pins both IDs; its reachable-main run must pass 45/45 before tag `v1.0.0` is created.

## 16. Non-goals (v1)
Non-interactive install; `reload`; `reconfigure`; BIND; UDP ASSOCIATE; SOCKS4/4a/4.5 (permanently out
of scope, not "deferred"); multiple users; source CIDR allowlist; custom outbound address / multi-NIC
(`-e`); HTTP proxy; admin interface; TLS transport; Web UI; Docker; multi-node management; distro
packaging; automatic upgrades; 3proxy 1.x; `CR:`/BLAKE2b credentials; SELinux port relabeling;
IPv6-only listeners; log rotation; RHEL/Rocky/Alma.

## 17. README requirements
- Use the name **SOCKS5** exclusively, and show only `socks5://user:password@host:port`. Never
  advertise, display, or provide a usage example for SOCKS4, SOCKS4a, or SOCKS4.5. State that
  CONNECT is the only supported command and that BIND and UDP ASSOCIATE are unsupported.
- The primary Ubuntu/Debian/CentOS install form is the exact published
  `bash <(wget -qO- …/main/socks5.sh)` command. Because stock Alpine ash parses `<(...)` before
  Bash executes, document its exact `apk add --no-cache bash wget && bash -c 'bash <(wget …)'`
  one-liner separately. Never use `wget … | sh` (it feeds source into prompt stdin) or a fixed
  `/tmp/socks5.sh` path.
- Keep the convenient `main` commands but also document an immutable semantic-version tag and the
  exact SHA-256 of its `socks5.sh`. The README must call it a candidate until two fresh 45/45 runs
  pass and the tag exists; the tag is created only after the evidence-only run and is never moved.
- Document the exact `1 中文 / 2 English` selector, Enter=Chinese, invalid retry, per-invocation
  locale, one `[Y/n]` install confirmation, dependencies before values, and one hidden custom
  password read. State that status/show/restart/uninstall/menu and all script-owned output follow
  the selected language.
- Document the TTY-only credential card, standalone exact URI, fixed public-egress IPv4 lookup,
  privacy boundary, strict validation, nonfatal local/`SERVER_IPV4` fallback and one warning. Never
  claim the observed egress address proves inbound reachability.
- State that the script has no firewall functionality — it neither detects nor modifies any
  firewall — and that the operator must allow the chosen TCP port themselves, locally and in the
  cloud security group. The README may document example commands per backend as operator
  documentation; the script itself never detects or runs them.
- State plainly: the password is plaintext in a permission-protected file readable by root and the
  proxy process; SOCKS5 auth is **cleartext on the wire**; SOCKS5 is **not** an encrypted VPN;
  sensitive use should be combined with SSH, TLS, or a VPN.
- List build dependencies that may have been installed, noting they are intentionally left in place.
- State that v1 pins one upstream commit, so **the operator owns updates**. 3proxy's `lts` channel is
  defined upstream only as "the 0.9 branch" with no published support window — do not imply upstream
  security backports reach this install automatically.

## 18. Residual risks and settled decisions

**Verification status (2026-08-29).** Round 17 implementation commit
`3b58e194887bf91a06b789353c06033b70c49c59` passed run `33281392984` with **45/45 green**.
Evidence-only commit `a8ed8255fba6c9bf9b8247582d6b77ebf65d8374` passed run `33281724740`,
also 45/45:

- all 16 build and 16 protocol cells passed on amd64/arm64;
- all 3 ACL-resolution cells passed;
- all 7 real systemd/OpenRC lifecycle cells passed, including the new owner/mode, account,
  secret-sink, exact-address, logger-path and install-twice assertions;
- lint, two unit cells, structural release gates and all Python syntax checks passed.

This closure commit records both fresh runs. It is tagged `v1.0.0` only after its own reachable-main
run is 45/45; the tag's existence is the final gate (§15.17). Runs `33245460710` / `33246222640`
remain historical evidence for the previous bilingual state. Environmental risks remain: package
repositories, DNS and the fixed HTTPS self-test require egress; cloud images may differ from the
tested base images; and the pinned 3proxy 0.9 branch has no published maintenance window, so the
operator still owns updates (§17).

**Decided:**
- Publishing target: `github.com/91sexboy/One-click-socks5-proxy-setup`; the README raw URL is
  runnable and the one-line invocation was exercised against it.
- Firewall: no functionality at all (§7.1). The operator opens the port themselves.
- `status`, `show`, `restart` and the no-argument menu are retained as product surface.

Settled, not open: the self-test target is fixed at `https://example.com/` (§2), and OpenRC logs to
syslog via `logger` rather than to any file (§9), so log rotation stays a non-goal.
