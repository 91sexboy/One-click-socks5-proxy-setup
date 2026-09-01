# Spec: socks5.sh — one-click SOCKS5 proxy installer

> **Status: v1.0.0 RELEASED / v1.1.0 CANDIDATE.** The released Round 17 chain remains:
> implementation `3b58e194887bf91a06b789353c06033b70c49c59` / run `33281392984`,
> evidence-only `a8ed8255fba6c9bf9b8247582d6b77ebf65d8374` / run `33281724740`, and
> closure `91fd13a` / run `33282068288`, all 45/45 before versioned `v1.0.0` was created
> under the project's never-move release policy.
> For v1.1, bilingual checkpoint `27ed6d9` / run `33473381427` passed the former 45-job workflow;
> r2 engine prerelease is published, and the focal consumer implementation is the new prospective
> implementation checkpoint. It, a later evidence-only commit, and exact closure must each pass the
> expanded 48-job workflow before versioned `v1.1.0` may be created under the never-move policy.
> Protocol, authentication, ACL and firewall boundaries remain unchanged.

## 1. Objective
A single-file POSIX shell script (`socks5.sh`) that interactively installs, verifies, and manages a
password-authenticated SOCKS5 proxy on a remote server the operator owns or is authorized to manage.
Engine: **3proxy 0.9.9.0**, built from a pinned upstream commit. Engine selection is closed.

**One-click means one command plus an interactive wizard**, not an unattended install: every
invocation first selects `1 中文 / 2 English` (Enter defaults to Chinese; invalid input retries),
then an install shows one default-yes confirmation and asks for port, username and password, each
of which accepts Enter for a securely generated value. Direct lifecycle commands and the
no-argument management menu select language again; locale is process-only and never persisted.
An installed `install` action offers a default-no in-place port/credential update and reuses the
binary, account and service definition. There is no non-interactive mode in v1.1.

### 1.1 Protocol support scope
Supported: **SOCKS5 only**, with **RFC 1929 username/password authentication**, and **CONNECT as the
only command**. Not supported, never advertised, never exampled: **SOCKS4, SOCKS4a, SOCKS4.5**,
**BIND**, **UDP ASSOCIATE**, and **unauthenticated connections**. This project deploys SOCKS5 nodes
only — it never offers or documents a SOCKS4-family service.

## 2. Tech stack (verified 2026-08-23)
- 3proxy tag `0.9.9.0`, pinned commit `da99424eac4092e3722f1a5b1844cfe80478f580` — confirmed via the
  GitHub API to be that tag, dated 2026-08-22. Source: `https://github.com/3proxy/3proxy` over HTTPS.
- Engine assets: release `engine-3proxy-0.9.9.0-r2`, built once by this project's CI as four dynamic
  glibc/musl × amd64/arm64 binaries. Target hosts select one fixed asset and verify its embedded size
  and SHA-256 before and after atomic installation; they never compile or automatically fall back.
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
| Ubuntu | `ID=ubuntu` | apt | systemd | 20.04 on amd64 only; 22.04 or newer on amd64/arm64 |
| Debian | `ID=debian` | apt | systemd | 12 or newer |
| Alpine | `ID=alpine` | apk | OpenRC | 3.20 or newer |
| CentOS Stream | `ID=centos` | dnf, yum fallback | systemd | 9 or newer |

**Version acceptance is normally a floor, with one exact architecture-specific exception:** Ubuntu
20.04 is accepted only on amd64; Ubuntu 22.04+ accepts amd64/arm64. Debian, Alpine and CentOS Stream
retain their listed floors. The expanded CI matrix includes Ubuntu 20.04 amd64 compatibility,
protocol and real systemd lifecycle cells, while prior evidence covers Ubuntu 22.04/24.04, Debian
12/13, Alpine 3.20/3.24 and CentOS Stream 9/10 on both architectures where promised. A release newer
than the exact matrix versions may install through the floor path without exact-version evidence.
Ubuntu 20.04 is outside standard security maintenance; compatibility support does not replace an
operator's Ubuntu Pro/ESM or other patch-management policy. Below-floor or unsupported tuples hard
fail. Both normalized architectures remain globally recognized, but Ubuntu 20.04 arm64 is an explicit
unsupported tuple.
**CentOS detection is exact.** Only `ID=centos` (Stream 9 or newer) installs. RHEL, Rocky, and
AlmaLinux are recognized via `ID_LIKE=rhel` and told they are *likely compatible*, but v1 **does not
install on
them**. `ID_LIKE` alone never authorizes an install. Any other OS, or a version below the floor →
hard error naming the
detected `ID` and `VERSION_ID`. **EPEL and a target-side toolchain are not required.**

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
Fresh installation enforces this again at each final use: project-owned directories are claimed by an
exclusive final-path `mkdir`, and complete same-directory temporary files are published with a
no-replace hard link. An object that appears after preflight is a collision, not permission to replace
or remove it. Ownership enters state only after exclusive claim; if persisting that claim fails, local
compensation removes only the still-matching inode. Account and group names are likewise never
adopted: creation captures numeric UID/GID, revalidates name-to-ID and primary-group mappings before
credentials are owned or services start, and deletion acts only on matching recorded identities.

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
3. **Password** — Enter → generated, **exactly 32 characters**. Typed input is visible and is read
   **once**; it is not asked a second time for confirmation. The prompt explicitly says it is visible,
   and the documentation warns against entering it where another person, terminal recorder or serial
   console logger can observe it. Charset for generated and user-supplied passwords alike is
   **`[A-Za-z0-9._~-]`**, length **12–128**. Rejection names the failing rule and never repeats the
   input.

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

## 8. Verified engine-asset installation
1. Normalize architecture before authorizing the OS/version/architecture tuple. Authorize exact
   Ubuntu 20.04 amd64, or Ubuntu 22.04+ on amd64/arm64; reject focal arm64. Then map
   Debian/Ubuntu/CentOS Stream to glibc and Alpine to musl and select the fixed asset from release
   `engine-3proxy-0.9.9.0-r2`.
2. Show only genuinely missing runtime packages in the confirmation: curl, ca-certificates and an
   `ss` provider only when `/proc/net/tcp{,6}`, ss and netstat are all unusable. APT disables
   recommends, DNF/YUM disable weak deps, APK uses `--no-cache`.
3. Download to a private temporary directory over HTTPS with HTTPS-only redirects and a time limit.
   A bounded reader retains at most the exact expected length plus one oversize sentinel byte, so
   unknown-length/chunked responses are byte-capped even on curl versions whose `--max-filesize`
   checks only known response lengths. Validate regular/non-symlink type, exact embedded byte length
   and embedded SHA-256.
4. Atomically copy only the verified binary to `/usr/local/libexec/socks5-manager/3proxy`, set
   `root:root 0755`, and verify the installed file's SHA-256 again. Any mismatch fails closed and
   triggers normal rollback; there is no source-build or distro-package fallback.
5. New state records `origin=release-asset`, the exact asset name and SHA-256. Legacy complete states
   with `origin=source-build` remain valid for status, update, restart and uninstall; an in-place
   credential/port update never changes their existing binary.
6. Remove the download directory. Runtime packages are not removed during uninstall.

The r2 glibc-amd64 asset is built on Ubuntu 20.04 and must require no symbol newer than GLIBC_2.31;
its published binary currently tops out at GLIBC_2.25. The other three r2 assets are carried
byte-for-byte from r1 by exact size/SHA and retain their original provenance. All four derive from
pinned commit `da99424eac4092e3722f1a5b1844cfe80478f580`; the newly built asset uses serial
`-O2 -fno-lto`, disables optional SSL/PCRE/PAM/plugins, and is stripped before attestation.

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
bash <(wget -qO- https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/develop/socks5.sh)
```

The project-standard stock-Alpine bootstrap explicitly installs Bash and passes the command through a
quoted `bash -c` string, so Bash parses process substitution without depending on a BusyBox build's
optional Bash-compatibility behavior:

```sh
apk add --no-cache bash wget && bash -c 'bash <(wget -qO- https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/develop/socks5.sh)'
```

A `curl` form of the primary command is documented as an equivalent alternative for hosts that ship
`curl` but not `wget`:

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/develop/socks5.sh)
```

Under process substitution `$0` is a transient `/dev/fd/*` descriptor: operator-facing messages
must never print it. When invoked this way, re-running the command opens the management menu after
installation. Every invocation selects language before command validation/dispatch; command tokens
remain English.

```text
socks5.sh            # not installed -> interactive install; installed -> menu
socks5.sh install | status | show | restart | uninstall
```
- No `reload` or public `reconfigure` subcommand — use `restart` for a plain restart. Re-running
  `install`, or choosing `update` from the no-argument menu, shows the current non-secret status and
  asks a default-no confirmation before collecting a new port, username and visible password. Empty
  value input generates a fresh random value. The update reuses the binary, account and service
  definition, then atomically replaces the fixed config/state files under a recoverable transaction.
- `show` reprints full connection details **including the password** for root, to the terminal only.
  It must never write the password to a log, file, journal, redirect, argv, environment or xtrace.
- Install, update and `show` use one localized credential-card renderer. It prefers one strictly
  validated IPv4 observed from the fixed HTTPS endpoint `https://icanhazip.com`; this is
  presentation-only, nonfatal and reports outbound egress, not guaranteed inbound reachability. The
  response is capped at 17 bytes before parsing. On lookup failure, `SERVER_IPV4` is shown with an
  actionable replacement warning; a private/local address is never substituted into the public URI.
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
2. **Fresh publication:** fully prepare a same-directory temporary file, set ownership/mode, then
   publish it with a no-replace hard link. A late path collision fails without replacing either a
   file, directory or symlink. Atomic `mv` replacement is reserved for files already proven owned
   during state rewrites and reconfiguration transactions.
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

Credential checks use `curl -q --config -`, feeding `socks5-hostname`, `proxy-user`, and `url` on
**stdin** so ambient curlrc files cannot alter the request and the password never appears in `argv`.
The rejection probe uses the configured username with a guaranteed-different valid password, not an
unknown user. This needs server egress; when the service is up and the port listening but the request
fails, the report must distinguish: proxy auth failure; no outbound network; DNS failure; external
test service unavailable.

## 12. Uninstall, updates and concurrency
Uninstall removes only state-recorded resources: service unit or init script, the `socks5proxy`
account and group, `/etc/socks5-manager/`, `/var/lib/socks5-manager/`, and the installed binary.
**No firewall rule is ever removed, because none is ever created (§7.1).** It never touches a
pre-existing system 3proxy, the operator's own proxy users, any firewall rule, package repositories,
pre-existing config, or any system package.

Re-running `install` on a complete, healthy project install offers a default-no in-place update.
Candidate files and byte-for-byte backups are prepared before stopping the old proxy. The script
then proves the service stopped, atomically replaces `users.cfg`, `3proxy.cfg` and state, restarts,
and runs the complete authentication/listener verification. Any failure restores and verifies the
old files; interrupted transactions are recovered before the next mutating command. A fixed
`mkdir`-based lock serializes all management operations so status/show cannot observe a mixed
snapshot and concurrent mutations cannot overwrite one another. The lock uses PID, Linux boot ID
and process start time to distinguish a live owner from a stale lock without a time-based lease.

## 13. Testing
`tests/` — shell-based, no framework dependency.
- **Unit:** port/username/password validators, os-release parsing (including the RHEL/Rocky/Alma
  refusal path), arch mapping, config renderer, prerequisite selection and ordering, absence of
  firewall functionality, and the fixed-file reconfiguration transaction/lock/recovery paths.
- **Bilingual UI contract:** catalog key uniqueness, zh/en parity,
  declared arity, literal call-site keys, argument/format safety, no new untranslated script-owned
  literals, selector blank/1/2/invalid/EOF behavior, per-invocation locale, `[Y/n]`, password-once,
  exact zh/en card/URI, localized lifecycle/error output, and fixed bilingual pre-language guard.
- **IPv4/card contract:** canonical/public/local range validation,
  hardened fixed-endpoint curl boundary, malformed/private/multiline/oversized response rejection,
  nonfatal explicit-placeholder fallback, one lookup and warning per card, exact Host/URI consistency,
  and no credentials in lookup argv/stdin/env/logs.
- **Golden:** rendered `3proxy.cfg` and `users.cfg` match fixtures; §6 denylist asserted; asserted
  that `users.cfg` contains no `users` directive.
- **Protocol acceptance** (runs on every matrix cell): SOCKS5 + correct credentials + CONNECT →
  **success**; SOCKS5 + wrong password → **fail**; SOCKS5 offering no auth method → **fail**;
  SOCKS4 CONNECT → **fail**; SOCKS4a CONNECT → **fail**; SOCKS5 BIND → **fail**; SOCKS5 UDP ASSOCIATE
  → **fail**. The SOCKS4/4a cases are **rejection** tests: a pass requires refusal, never a working
  proxy.
- **Real service lifecycle — one per promised OS family plus exact focal amd64 evidence, all blocking:**
  Ubuntu 24.04 on native amd64/arm64 runners; Ubuntu 20.04 and 22.04, Debian 12 and CentOS Stream 9
  as privileged systemd PID-1 containers; and Alpine 3.20/3.24 under OpenRC. Each v1.1.0 candidate
  cell runs install → update → status → active → listening → restart → uninstall → cleanliness.
  Compatibility-only and direct-engine protocol cells do **not** satisfy lifecycle evidence. Ubuntu,
  Debian and Alpine start without curl and prove missing-runtime dependency installation. CentOS
  starts with `curl-minimal`, which CI verifies and reuses. No lifecycle target gains Git, Make, GCC
  or cc.
- **Low-memory boundary:** containerized systemd creates one CI-only shared systemd slice containing
  every operation runner and `socks5-manager.service`, enforces aggregate 128 MiB/no swap, validates
  both cgroup ancestries, reads the shared peak and requires zero OOM kills. The OpenRC target-container cgroup
  is limited to 128 MiB/no swap and supplies its whole-container peak.
- **Asset compatibility matrix:** 17 supported tuples: the existing 8 OS versions × 2 architectures,
  plus Ubuntu 20.04 amd64; focal arm64 is explicitly excluded. No target gains a build toolchain.
- **Update safety:** a confirmed update reuses one service/account/binary, rotates one credential,
  verifies the new proxy, and restores the old verified proxy on failure.
- **Cleanliness:** after uninstall no project file or account remains, no system package was removed,
  and no firewall rule was ever created.

systemd targets need systemd-capable containers or VMs (`systemctl` in a plain container lies).
**No tier is exempt.** Historical 45-job workflow run `33174398814` at `df6885c` passed its then-current
matrix. The Ubuntu 20.04 implementation expands the current workflow to 48 blocking jobs and must
earn new evidence; no historical run proves the focal tuple.

The 17 protocol cells download the pinned release asset for their libc/architecture, render the
production config and run the engine **directly** — they prove the protocol boundary, not a service
install. Real init-system installation is covered separately, once per promised OS family (§13).

**Release gate (hard).** If integration testing of the pinned version shows SOCKS4 or SOCKS4a
successfully establishing a proxy connection, the test **fails** and release **must not proceed**.
Printing a warning and continuing is not permitted, and the gate has no skip flag. The only allowed
responses are to re-evaluate the engine or to carry a minimal protocol-restriction patch — never to
relax the test. This gate is not experimental on any cell, Alpine included.

## 14. Boundaries
**Always:** default-deny ACL; `umask 077` before secret writes; record every created resource in
state; verify the selected release asset by embedded size/SHA-256; show the pre-install warning;
install runtime prerequisites before the port prompt. State records provenance and completion: new
installs use `origin=release-asset` plus validated `asset`/`sha256`; legacy
`origin=source-build` states remain supported.
**Ask first:** one default-yes confirmation before a fresh install, and one default-no confirmation before
an in-place update. Writing anything outside the project namespace is never done at all.
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
6. A confirmed second `install` updates one credential entry in place without duplicating or
   replacing the binary, account, or service definition; default-no leaves all files unchanged.
7. The rendered config contains no directive from the §6 denylist.
8. Grepping the journal, `/var/log`, and shell history for the generated password finds nothing.
9. `ID=rhel`/`rocky`/`almalinux` exits non-zero with "likely compatible, not supported"; any other
   unsupported OS or arch exits non-zero naming the detected values.
10. Every §13 protocol-acceptance case passes on every matrix cell, including the SOCKS4 and SOCKS4a
    rejection cases, BIND, and UDP ASSOCIATE. Any SOCKS4-family success blocks release outright.
11. No user-facing string, example, or emitted URI mentions SOCKS4, SOCKS4a, or SOCKS4.5.
12. A real install → verify → in-place update → verify → uninstall lifecycle passes on Ubuntu,
    Debian, Alpine and CentOS Stream. The listed matrix versions carry that evidence only after the
    v1.1.0 candidate CI succeeds. Newer releases admitted by the §3 version floors use the same code
    path but are explicitly **accepted without a claim that CI has verified that exact release**;
    no document may blur that distinction.
13. The documented install commands are runnable as written, including the separate stock-Alpine
    bootstrap whose inner string is parsed by Bash rather than ash.
14. Every invocation selects Chinese/English before dispatch; blank defaults Chinese, invalid input
    retries, and every later script-owned message follows the selection. Locale is never persisted.
15. Fresh install asks exactly one default-yes confirmation; an existing install asks a separate
    default-no update confirmation; a custom password is visible and read once; Enter-generated
    port/username/password continue using the existing secure generators.
16. Install, update and `show` render one exact URI using one resolved IPv4. Public lookup failure is
    nonfatal and yields exactly one localized `SERVER_IPV4` replacement warning; lookup receives no
    secret and accepts at most 17 response bytes.
17. Round 17 implementation commit `3b58e194887bf91a06b789353c06033b70c49c59` passed run
    `33281392984`; evidence-only commit `a8ed8255fba6c9bf9b8247582d6b77ebf65d8374` passed run
    `33281724740`; closure commit `91fd13a` passed run `33282068288`; versioned tag `v1.0.0`
    exists there. Run `33245460710` / `33246222640` remains historical evidence for the previous
    bilingual state. The latest completed bilingual checkpoint `27ed6d9` / run `33473381427` passed
    the former 45-job workflow but predates r2 and focal support. The Ubuntu 20.04 implementation must
    pass the expanded 48-job workflow; an evidence-only commit and exact `develop` closure must each
    then pass all 48 jobs before the versioned v1.1 tag may exist. Earlier candidate runs remain
    historical evidence.

## 16. Non-goals (v1.1)
Non-interactive install; a separate public `reload` or `reconfigure` subcommand; BIND; UDP ASSOCIATE;
SOCKS4/4a/4.5 (permanently out of scope, not "deferred"); multiple users; source CIDR allowlist;
custom outbound address / multi-NIC (`-e`); HTTP proxy; admin interface; TLS transport; Web UI;
Docker; multi-node management; distro packaging; automatic upgrades; 3proxy 1.x;
`CR:`/BLAKE2b credentials; SELinux port relabeling; IPv6-only listeners; log rotation;
RHEL/Rocky/Alma.

## 17. README requirements
- `README.md` is the complete English operator document and `README.zh-CN.md` is the complete
  Simplified Chinese document. Both carry `[English](README.md) | [简体中文](README.zh-CN.md)` near
  the top and use the same section order. Commands, paths, hashes, run IDs, URLs, protocol tokens,
  numeric limits, release status and security facts are identical; a load-bearing fact changes in
  both files in the same commit. Both must state the exact Ubuntu exception: 20.04 amd64 only,
  22.04+ amd64/arm64, plus the 20.04 upstream-maintenance caveat.
- Both documents lead with a complete Alpine Linux deployment tutorial before the general distro
  quick start: explain that process-substitution support is BusyBox-build-dependent and that quoted
  `bash -c` deliberately guarantees Bash parsing; retain the exact bootstrap, separate bootstrap packages from runtime dependencies, document musl
  assets, OpenRC/default-runlevel/syslog behavior, root-shell management without assuming `sudo`,
  the operator-owned firewall/cloud port, and the 128 MiB whole-container CI gate. State that the
  floor is Alpine 3.20+ while exact current evidence covers 3.20/3.24; do not promise a universal
  syslog-reading command or arm64 OpenRC lifecycle evidence.
- Use the name **SOCKS5** exclusively, and show only `socks5://user:password@host:port`. Never
  advertise, display, or provide a usage example for SOCKS4, SOCKS4a, or SOCKS4.5. State that
  CONNECT is the only supported command and that BIND and UDP ASSOCIATE are unsupported.
- The primary Ubuntu/Debian/CentOS install form is the exact published
  `bash <(wget -qO- …/develop/socks5.sh)` command. The stock-Alpine form must explicitly install Bash
  and use a quoted `bash -c` string so the project does not depend on optional BusyBox compatibility;
  document its exact `apk add --no-cache bash wget && bash -c 'bash <(wget …)'`
  one-liner separately. Never use `wget … | sh` (it feeds source into prompt stdin) or a fixed
  `/tmp/socks5.sh` path.
- Keep the convenient moving `develop` commands but also document versioned semantic tags, the
  project never-move policy, the lack of GitHub-enforced tag immutability, and
  the exact SHA-256 of each tagged `socks5.sh`. The README must call v1.1 a candidate until the current
  implementation commit passes 48/48, an evidence-only commit records that proof and passes 48/48,
  and the exact closure commit passes 48/48 on `develop`; only then is the tag created at that closure
  commit and it is never moved.
- Document the exact `1 中文 / 2 English` selector, Enter=Chinese, invalid retry, per-invocation
  locale, the default-yes fresh-install confirmation, the default-no installed-update confirmation,
  dependencies before initial values, and one visible custom password read. State that
  status/show/restart/uninstall/menu and all script-owned output follow the selected language.
- Document the TTY-only credential card, standalone exact URI, fixed public-egress IPv4 lookup,
  privacy boundary, strict 17-byte response limit, nonfatal `SERVER_IPV4` fallback and one warning.
  Never claim the observed egress address proves inbound reachability.
- State that the script has no firewall functionality — it neither detects nor modifies any
  firewall — and that the operator must allow the chosen TCP port themselves, locally and in the
  cloud security group. The README may document example commands per backend as operator
  documentation; the script itself never detects or runs them.
- State plainly: the password is plaintext in a permission-protected file readable by root and the
  proxy process; SOCKS5 auth is **cleartext on the wire**; SOCKS5 is **not** an encrypted VPN;
  sensitive use should be combined with SSH, TLS, or a VPN.
- Document the versioned engine release, four libc/architecture assets, embedded size/SHA checks,
  target-side no-compile policy, 128 MiB gate, and only the runtime dependencies that may be left in
  place.
- State that v1 pins one upstream commit, so **the operator owns updates**. 3proxy's `lts` channel is
  defined upstream only as "the 0.9 branch" with no published support window — do not imply upstream
  security backports reach this install automatically.

## 18. Residual risks and settled decisions

**Verification status (2026-08-30).** The released v1.0.0 evidence chain remains Round 17:
implementation `3b58e194887bf91a06b789353c06033b70c49c59` / run `33281392984`, evidence-only
`a8ed8255fba6c9bf9b8247582d6b77ebf65d8374` / run `33281724740`, and closure `91fd13a` /
run `33282068288`, all 45/45 before the versioned tag was created under the never-move policy.

The bilingual checkpoint `27ed6d97048f9d3aadd306461f82bb026146e83e` passed the former
45-job workflow in run `33473381427`. The r2 engine prerelease is published at tag
`engine-3proxy-0.9.9.0-r2`, with generic glibc-amd64 bytes built on Ubuntu 20.04 and requiring at
most GLIBC_2.25. The focal consumer/detection implementation changes the candidate again and must
earn a new 48-job implementation run; evidence-only and exact `develop` closure evidence remain
pending under §15.17. Earlier candidate runs remain historical evidence. Environmental risks remain:
package repositories, DNS and the fixed HTTPS self-test require egress; Ubuntu 20.04 standard
maintenance has ended; cloud images may differ from tested bases; and the pinned 3proxy branch has
no published maintenance window, so the operator owns update policy (§17).

**Decided:**
- Publishing target: `github.com/91sexboy/One-click-socks5-proxy-setup`; the README raw URL is
  runnable and the one-line invocation was exercised against it.
- Firewall: no functionality at all (§7.1). The operator opens the port themselves.
- `status`, `show`, `restart` and the no-argument menu are retained as product surface.

Settled, not open: the self-test target is fixed at `https://example.com/` (§2), and OpenRC logs to
syslog via `logger` rather than to any file (§9), so log rotation stays a non-goal.
