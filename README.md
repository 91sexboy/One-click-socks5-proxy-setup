# socks5.sh

A single-file POSIX shell script that installs, verifies and manages a
**password-authenticated SOCKS5 proxy** on a server you own or are authorised to
manage. The proxy engine is [3proxy](https://github.com/3proxy/3proxy) 0.9.9.0,
built once by this project's CI from one pinned upstream commit; the target
server downloads and verifies the matching native binary and does not compile
anything.

> **SOCKS5 is not a VPN.** Read [Security](#security) before you use this.

## Protocol support

| Capability | Supported |
|---|---|
| SOCKS5 | **yes** |
| RFC 1929 username/password authentication | **yes, mandatory** |
| CONNECT | **yes, the only command** |
| Unauthenticated connections | no |
| BIND | no |
| UDP ASSOCIATE | no |
| SOCKS4 / SOCKS4a / SOCKS4.5 | **not supported** — rejected |

Only SOCKS5 with a username and password can establish a connection. The
generated configuration enforces this with `auth strong`, the `socks -u2`
service flag, and an ACL that grants `CONNECT` and nothing else, ending in an
explicit `deny *`.

Two flags in the generated config are commonly misread, so to be explicit:

- `-4` means **IPv4 destination resolution only**. It does *not* enable SOCKS4.
- `-u2` means **require username/password among the offered authentication
  methods**. `-u` on its own would mean "never ask for a username/password", so
  the `2` is load-bearing.

3proxy's `socks` gateway parses SOCKS4, 4.5 and 5 on the wire and has no option
to disable SOCKS4 parsing. SOCKS4 carries only a user-ID field and has no RFC
1929 password phase, so it cannot satisfy `auth strong` and is refused. That is
an assertion the test suite proves per platform rather than an assumption: CI
runs SOCKS4 and SOCKS4a rejection tests on every matrix cell, and a SOCKS4-family
success is a hard release blocker.

## Requirements

| | |
|---|---|
| OS | Ubuntu 22.04+, Debian 12+, Alpine Linux 3.20+, CentOS Stream 9+ |
| Architecture | `x86_64`/`amd64`, `aarch64`/`arm64` |
| Privileges | root |
| Init system | systemd, or OpenRC on Alpine |

RHEL, Rocky Linux and AlmaLinux are detected and reported as *likely
compatible*, but the script will not install on them. Anything else exits with
the detected `ID` and `VERSION_ID` named — it never guesses.

## Install

One command, as root, on a supported system — Ubuntu, Debian and CentOS
Stream, or Alpine once you are already inside a Bash shell:

```sh
bash <(wget -qO- https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/main/socks5.sh)
```

Stock Alpine needs its own form, because the outer shell parses the command
line before running any part of it. Alpine's default shell is BusyBox `ash`,
and `<(...)` is a syntax error to `ash` at parse time — an `apk add bash`
written into the same command line can never rescue it. The stock-Alpine form
hides the substitution inside single quotes, so the outer shell sees only a
quoted string and the `<(wget ...)` inside it is parsed by the newly installed
Bash:

```sh
apk add --no-cache bash wget && bash -c 'bash <(wget -qO- https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/main/socks5.sh)'
```

or, with curl (wrap it the same way on stock Alpine):

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/main/socks5.sh)
```

The URL always fetches the current version on `main`. Re-running the same
command later opens the management menu, where you can inspect, restart,
remove, or update the existing proxy in place.

You are running a remote script as root. To read it before running it instead:

```sh
wget -qO socks5.sh https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/main/socks5.sh
less socks5.sh
sudo sh socks5.sh
```

On stock Alpine this read-it-first form works as-is: the script itself is
plain POSIX `sh` — only the `<(...)` download form needs Bash.

### Immutable tagged releases

`main` is convenient but moves, so every reviewed revision is published as an immutable tag.

**`v1.0.0` — published.** Created at closure commit `91fd13a` after its own reachable-main run
[`33282068288`](https://github.com/91sexboy/One-click-socks5-proxy-setup/actions/runs/33282068288)
passed all 45 jobs. It is fetchable at
`https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/v1.0.0/socks5.sh` and its
bytes have SHA-256 `acbfbfe3e6ba0f37f4e2a24ba8a6d68ec5a36513caae2e22e44a0ed28322e0b1`.

**`v1.1.0` — candidate.** This revision adds transactional in-place updates for
an existing installation, visible single-entry custom passwords, strict public-IPv4-only
connection cards, and additional safety checks. Its exact candidate bytes have this SHA-256:

```text
a9fe345f9bff4d801b3f962b4fa5c02edb9ccf8c1225553ab4e75f2aa26ccde1  socks5.sh
```

Download and verify the tagged artifact after `v1.1.0` is published:

```sh
wget -qO socks5.sh https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/v1.1.0/socks5.sh
printf '%s  %s\n' 'a9fe345f9bff4d801b3f962b4fa5c02edb9ccf8c1225553ab4e75f2aa26ccde1' socks5.sh | sha256sum -c -
sudo sh socks5.sh
```

Tag `v1.1.0` will be created only after its own complete CI run succeeds, and is never moved.
A tag's existence is therefore the final proof that its implementation, verification and reachable
release tree all passed.

## The interactive flow

The installer is **interactive**. An install run asks five questions in
order; the first picks the language the other four are printed in:

1. **Language** — `1 中文 / 2 English`. Enter alone selects 中文; any other
   answer is re-asked. This is the first question on every run of the script,
   and the choice is never saved.
2. **Confirmation** — the detected system, the exact list of packages it will
   install, and the security warning, then a single `[Y/n]` question. This is
   the only yes/no question in the flow.
3. **Port** — press Enter for a random port in 20000–60000, or supply one in
   1024–65535. An occupied port is rejected.
4. **Username** — press Enter for a random one. `A-Z a-z 0-9 _ -`, 3–32 chars.
5. **Password** — press Enter for a generated 32-character password, or type
   your own: `A-Z a-z 0-9 . _ ~ -`, 12–128 chars. Custom input is visible and
   is read once, so enter it only in a private terminal; the final card lets you
   verify what was accepted.

Pressing Enter at the language question and at all three value prompts is
supported: it selects 中文 and accepts the generated values, giving you a
secure, randomly generated port, username and password.

On an existing healthy installation, the `install` action first shows the
current non-secret status and asks a default-no `[y/N]` confirmation. If you
confirm, it asks for a new port, username and password with the same random
Enter defaults, then updates the configuration in place without rebuilding
3proxy, recreating the service account, or replacing the service definition.
The old configuration is restored automatically if activation or verification
of the new one fails.

Both character sets are RFC 3986 unreserved, so the `socks5://` URI on the
credential card needs no escaping.

## Language coverage

Every message the script itself prints follows the selected language — the
install prompts and the pre-install warning, the post-install result and its
credential card, the management menu, `status`, `show`, `restart`,
`uninstall`, and error messages. The choice is not saved between runs: every
run starts with the language question again. Subcommand names stay English in
both languages, and output that comes from other programs — package-manager or
service-manager messages — is passed through exactly as those programs print
it, untranslated.

## The credential card

A successful install or update ends by printing a credential card **only when
stdout is a real terminal**. If output is redirected or piped, the operation
still completes but the password and URI are not written there; re-run the
script in a terminal and choose `show`. The labels — Host, Port, Username,
Password — are localized to the selected language; the values are the real
ones. The connection line stands on its own line, unindented, so it copies
cleanly:

```
socks5://user:password@host:port
```

The address on the card is either:

1. **A strictly validated public IPv4, observed from outside.** The script
   makes one short HTTPS request to a fixed endpoint and uses the source IP
   that request came from — but only after strict validation that it is a
   public IPv4; anything malformed or non-public is discarded. The
   response is capped at 17 bytes. What the endpoint sees is the source IP and
   the time of that one request, nothing else. The request does not carry the
   port, username or password.
2. **The literal placeholder `SERVER_IPV4`** when the lookup fails, with an
   adjacent warning to replace it with the server's public IPv4 before using
   the connection line. Local RFC1918/CGNAT addresses are never substituted
   into a supposedly public connection URI.

A failed lookup never fails the install or update: the proxy is already running
and verified; only the address printed on the card changes.

The card closes with the standing reminders, in the selected language: this
script has no firewall functionality at all, so the port is yours to open in
your local firewall and in your cloud provider's security group, and the
proxy is not an encrypted tunnel.

## Commands

With the one-line installer, re-running the command is all you need: it opens
the management menu (status / show / restart / uninstall). With the script
saved as a file, the subcommands are:

```sh
sudo sh socks5.sh            # install if absent, otherwise a management menu
sudo sh socks5.sh install   # install, or offer an in-place update if present
sudo sh socks5.sh status     # service, port, version, install origin
sudo sh socks5.sh show       # re-display the full details, including the password
sudo sh socks5.sh restart
sudo sh socks5.sh uninstall
```

`show` requires root and prints the password to your terminal only — never to a
log or the journal.

There is no separate `reload` or `reconfigure` subcommand. To change the port,
username or password, re-run `install` or choose `update` from the management
menu. The script shows the current non-secret status, asks for confirmation,
then performs a recoverable in-place update while reusing the installed binary,
service account and service definition. Candidate files and backups remain
root-only; the old configuration is restored and re-verified if the new one
cannot start or pass authentication checks.

## What gets installed

| Resource | Path |
|---|---|
| Binary | `/usr/local/libexec/socks5-manager/3proxy` |
| Configuration | `/etc/socks5-manager/3proxy.cfg` (`root:socks5proxy`, `0640`) |
| Credentials | `/etc/socks5-manager/users.cfg` (`root:socks5proxy`, `0640`) |
| State | `/var/lib/socks5-manager/state` (`root:root`, `0600`) |
| systemd unit | `/etc/systemd/system/socks5-manager.service` |
| OpenRC service | `/etc/init.d/socks5-manager` |
| Service account | `socks5proxy` — system account, no home, `nologin`, no password |

Mutating operations temporarily use `/run/socks5-manager.lock` and, during an
in-place update, `/var/lib/socks5-manager/reconfigure-transaction/`. Both are
removed after success; a failed recovery deliberately keeps the root-only
transaction directory so the next mutating run can safely retry it. All
management operations share the same lock so status/show cannot observe a
half-applied update and concurrent mutations cannot overwrite one another.

A dedicated namespace is used throughout, so an existing system 3proxy is never
touched. If any of these already exists and the state file cannot confirm this
script created it, the installer **stops** rather than overwriting it.

The proxy runs as the unprivileged `socks5proxy` account; privilege dropping is
the init system's job, so the configuration contains no `setuid`/`setgid`. Ports
are restricted to 1024 and above, so no capability to bind privileged ports is
ever granted.

On Alpine, OpenRC sends the engine's output to syslog through `logger`; no
ordinary log file is created.

## Runtime dependencies and verified engine assets

The target server **does not compile 3proxy** and does not need Git, Make, GCC,
C headers or a source checkout. This project publishes four native dynamic
binaries from pinned commit `da99424eac4092e3722f1a5b1844cfe80478f580` in the
immutable engine release `engine-3proxy-0.9.9.0-r1`:

| Target | Release asset |
|---|---|
| Ubuntu / Debian / CentOS Stream, amd64 | `3proxy-0.9.9.0-da99424-linux-glibc-amd64` |
| Ubuntu / Debian / CentOS Stream, arm64 | `3proxy-0.9.9.0-da99424-linux-glibc-arm64` |
| Alpine, amd64 | `3proxy-0.9.9.0-da99424-linux-musl-amd64` |
| Alpine, arm64 | `3proxy-0.9.9.0-da99424-linux-musl-arm64` |

The asset name, exact byte length and SHA-256 are embedded in `socks5.sh`.
The installer follows HTTPS redirects only, caps the response, verifies the
exact size and embedded SHA-256 before installation, and verifies the final
installed file again. A mismatch fails closed; it never falls back to local
source compilation.

Only genuinely missing runtime packages are installed:

- `curl`, used for the engine download and post-install self-test;
- `ca-certificates`, when no supported CA bundle exists;
- an `ss` provider only when `/proc/net/tcp{,6}`, `ss` and `netstat` are all
  unavailable or unusable (`iproute2` on Debian/Ubuntu/Alpine, `iproute` on
  CentOS Stream).

APT uses `--no-install-recommends`, DNF/YUM disable weak dependencies, and APK
uses `--no-cache`. These runtime packages are intentionally left in place:
`uninstall` never removes system packages because it cannot know what else on
the server depends on them.

The low-memory lifecycle gate runs clean Debian 12, Alpine 3.20 and CentOS
Stream 9 targets with a **128 MiB memory limit and no swap**. That limit covers
the target-side install, service start, authentication checks, in-place update
and uninstall; CI compilation happens separately and is not charged to the VPS.

## Updates are your responsibility

This release pins one upstream commit:

```
3proxy 0.9.9.0 @ da99424eac4092e3722f1a5b1844cfe80478f580
```

The installed binary comes from that commit and is **not** managed by your
distribution's package manager, so it receives no automatic security updates.
3proxy's `lts` channel is defined upstream only as "the 0.9 branch", with no
published support window, so do not assume upstream security backports reach
this installation. Watch the upstream repository and reinstall when you need a
newer version.

## Firewall: entirely yours

**This script has no firewall functionality.** It does not even detect which
firewall you run — it never queries, adds, deletes, flushes, enables, disables,
resets or reloads anything. Nothing firewall-related is recorded in the state
file, so `uninstall` has nothing firewall-shaped to remove either.

You must allow inbound TCP on your chosen port yourself, twice: in your local
firewall *and* in your cloud provider's security group or network ACL. The
second one is outside this server and this script cannot see it.

If you manage the local firewall yourself, the command depends on the backend
(this is operator documentation only — the script never runs any of it):

| Backend | Example command | Persistent across reboot? |
|---|---|---|
| `ufw` | `ufw allow <port>/tcp` | **Yes** — ufw stores its own rules. |
| `firewalld` | `firewall-cmd --zone=<zone> --permanent --add-port=<port>/tcp`, then the same without `--permanent` | **Yes**, once added permanently. |
| `iptables` | `iptables -I INPUT -p tcp --dport <port> ... -j ACCEPT` | **No.** A rule added with `iptables -I` lives in kernel memory only. |
| `nftables` | `nft add rule inet filter input tcp dport <port> accept` | Depends on how you persist your ruleset. |

**The iptables case is the one to watch.** A rule you add with `iptables -I` is
gone after a reboot and the proxy becomes unreachable even though it is still
running. To make it survive, use `iptables-persistent` / `netfilter-persistent`
(Debian, Ubuntu) or `iptables-services` (CentOS Stream), or use firewalld or ufw
instead. This script does not install a persistence package.

## Uninstall

```sh
sudo sh socks5.sh uninstall
```

Removes only the **fixed project resources** whose creation the state file
recorded. The state file stores *flags*, never paths, so every path removed is a
constant compiled into the script — a corrupted state file cannot turn uninstall
into an arbitrary delete.

Nothing is removed recursively. If a project directory still contains a file this
script did not create, the directory is **kept**, the stray file is named, the
state file is **retained** so you can retry, and the command exits non-zero
without claiming success. Account removal is verified by re-checking existence
afterwards; if the account or group survives, that is reported and the uninstall
fails rather than reporting completion.

It never removes a pre-existing system 3proxy, your own proxy users, any firewall
rule, package repositories, unrelated configuration, or any system package.

## Security

Read this section before exposing the proxy.

- **Authentication is cleartext on the wire.** SOCKS5 username/password
  authentication (RFC 1929) sends your credentials unencrypted. Anyone able to
  observe the network path can read them.
- **There is no transport encryption or integrity protection. SOCKS5 is not a
  VPN.** For anything sensitive, run it inside SSH, TLS or a real VPN — for
  example an SSH local forward to `127.0.0.1` instead of exposing the port.
- **The password is stored in plaintext** in `/etc/socks5-manager/users.cfg`.
  The file is `root:socks5proxy 0640`, so `root` and the proxy process can read
  it. v1 uses 3proxy's `CL:` credential format; this is a deliberate, documented
  trade-off.
- **Anyone who learns the credentials and can reach the port can use the
  proxy**, and their traffic will appear to originate from your server.
- **The default listen address is `0.0.0.0`.** You are responsible for your own
  local firewall *and* your cloud provider's security group. This script has no
  firewall functionality at all: it does not even detect which firewall you run,
  and it never opens a port, flushes, disables, resets or reorders anything.
- The generated ACL refuses destinations in loopback, RFC 1918 private ranges,
  CGNAT space, link-local (which covers the `169.254.169.254` cloud metadata
  endpoint), and multicast/reserved space. This limits the proxy's usefulness for
  pivoting into your private network or stealing instance credentials.
- The credential never appears in a command line, an environment variable, a
  script log, journal, or shell history. The install-time self-test passes it to
  `curl -q --config -` on stdin, so ambient curl configuration is ignored.
- SELinux and sshd configuration are never modified.

Only use this on infrastructure you own or are explicitly authorised to
administer.

## Development

```sh
sh tests/run.sh                          # POSIX sh unit suite
S5_TEST_SHELL=dash sh tests/run.sh       # under dash
S5_TEST_SHELL='busybox sh' sh tests/run.sh
sh -n socks5.sh                          # syntax check
```

The unit suite touches nothing real: every privileged command is a recording
stub and all paths live inside a temporary root. Test overrides are inert unless
`S5_TEST_MODE=1`, which additionally requires `S5_TEST_ROOT` with a verified
`.s5-test-root` sentinel. If any test variable is set outside test mode, the
script refuses to run at all.

The suite includes a pseudo-terminal test that sends a real `SIGINT` during
visible password entry and asserts no state, transaction, lock or build residue
is left behind, plus regression tests for hostile state files, inherited
`umask 0000`/`0022`, and `sh -x` credential leakage. Python is used by test
tooling only; `socks5.sh` itself depends on POSIX `sh`, `curl`, `sha256sum` and
standard base utilities.

The four engine assets are compiled in the separate release workflow. The
OS/architecture compatibility matrix, seven protocol acceptance cases,
destination-ACL hostname test, `shellcheck`, and real service lifecycles are
**CI only** — see `.github/workflows/ci.yml`. A green local suite does not imply
those passed.

The published v1.0.0 baseline is green on GitHub-hosted runners. In run
[`33174398814`](https://github.com/91sexboy/One-click-socks5-proxy-setup/actions/runs/33174398814)
at commit `df6885c`, **45 of 45 jobs passed**:

- the full unit suite under `sh`, `dash` and `busybox sh`, on amd64 and arm64;
- all 16 build cells (8 supported OS versions × 2 architectures);
- all 16 protocol cells against the real pinned engine and rendered config,
  including every required rejection gate;
- all 3 destination-ACL cells, proving hostname resolution cannot bypass the
  private/link-local/metadata destination denies;
- 2 native systemd lifecycles on Ubuntu 24.04 (amd64 and arm64);
- 3 systemd-as-PID-1 container lifecycles on Ubuntu 22.04, Debian 13 and
  CentOS Stream 10; and
- 2 real OpenRC lifecycles on Alpine 3.20 and 3.24, with the installer itself
  bootstrapping the build and runtime dependencies from the clean images.

> **Evidence.** Round 17 implementation commit `3b58e19` passed run
> [`33281392984`](https://github.com/91sexboy/One-click-socks5-proxy-setup/actions/runs/33281392984)
> with **45 of 45 jobs**. Evidence-only commit `a8ed825` then passed run
> [`33281724740`](https://github.com/91sexboy/One-click-socks5-proxy-setup/actions/runs/33281724740),
> also 45/45. Closure commit `91fd13a` then passed run
> [`33282068288`](https://github.com/91sexboy/One-click-socks5-proxy-setup/actions/runs/33282068288),
> also 45/45, and tag `v1.0.0` was created there. The `v1.1.0` candidate must
> earn its own final reachable-main 45/45 run before release. Runs `33245460710` / `33246222640` remain
> historical evidence for the previous bilingual state.

The published v1.0.0 evidence covers the earlier source-build lifecycle for
every supported OS family. Run `33308776407` proves the transactional update
work on that source-build implementation. The release-asset implementation
must earn a new complete CI run; the older runs remain historical evidence and
are not presented as low-memory proof. Every OS version/architecture named in
the CI matrix still receives real asset compatibility and protocol coverage.
Versions newer than the listed matrix are accepted by the documented
minimum-version rule, but that does not claim CI has verified a future release.
What each CI job actually proves is deliberately distinct:

| Job | Cells | What it proves |
|---|---|---|
| `lint` | 1 | `shellcheck`, Python syntax, and the workflow's own structural guards |
| `unit` | 2 | this suite under `sh`, `dash` and `busybox sh`, on amd64 and arm64 |
| `build-matrix` | 16 | the matching release asset loads on every OS/arch combination without a target-side toolchain |
| `protocol` | 16 | the seven protocol cases against a **real engine running the rendered config** — not a service install |
| `acl-resolution` | 3 | the destination denies hold for **domain** targets, in an isolated container with a fake metadata endpoint |
| `systemd-integration` | 2 | a **real** install → update → verify → uninstall lifecycle under systemd, on the runner itself |
| `openrc-integration` | 2 | the same under **real** OpenRC on Alpine, installing only runtime dependencies in the clean image |
| `distro-systemd-integration` | 3 | the same on Ubuntu 22.04, Debian and CentOS Stream, with systemd booted as PID 1 in a privileged container |

Together the last three give one real install-and-update lifecycle per supported
OS family. A compile-only cell and a direct-engine protocol cell do not
substitute for that: neither installs a service.

No job uses `continue-on-error`, so every cell is configured to block the release,
Alpine included. A SOCKS4-family success, or a bypassed destination deny, fails the job outright.
Note that "blocks the release" describes how the gate is configured — which cells
have actually run and passed is listed above.

CI passwords are generated at runtime and handed to the protocol scripts as the
*path* to a `0600` file (`PASSFILE=...`), never as an environment variable and
never as a command-line argument, so they cannot reach a job log, `ps`, or a
child process's environment.

See `SPEC.md` for the complete behavior and verification contract.

## License

MIT — see [LICENSE](LICENSE). 3proxy source is not bundled; the verified engine
assets are built separately from the pinned upstream commit under its own
license.
