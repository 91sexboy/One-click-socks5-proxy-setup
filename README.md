# socks5.sh

A single-file POSIX shell script that installs, verifies and manages a
**password-authenticated SOCKS5 proxy** on a server you own or are authorised to
manage. The proxy engine is [3proxy](https://github.com/3proxy/3proxy) 0.9.9.0,
compiled from one pinned upstream commit.

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

The installer is one self-contained file. Copy it to the server, read it, and run
it as root:

```sh
sudo sh socks5.sh
```

If you publish this script, substitute your own release URL for `<RAW_URL>` in
the recipe below **before** telling anyone to use it — as written it is a
template, not a working command. Download into a private temporary directory,
verify the checksum you published, read the file, then run it. Never pipe an
installer straight into a shell, and never use a fixed path in `/tmp`:

```sh
d=$(mktemp -d) &&
  curl -fsSL -o "$d/socks5.sh" <RAW_URL> &&
  printf '%s  %s\n' "<PUBLISHED_SHA256>" "$d/socks5.sh" | sha256sum -c &&
  less "$d/socks5.sh" &&
  sudo sh "$d/socks5.sh"
```

The installer is **interactive**. It shows the detected system, the exact list of
packages it will install, and the security warning, and asks once whether to
continue. It then asks for three values:

1. **Port** — press Enter for a random port in 20000–60000, or supply one in
   1024–65535. An occupied port is rejected.
2. **Username** — press Enter for a random one. `A-Z a-z 0-9 _ -`, 3–32 chars.
3. **Password** — press Enter for a generated 32-character password. Typed input
   is not echoed and is confirmed twice. `A-Z a-z 0-9 . _ ~ -`, 12–128 chars.

Pressing Enter at all three prompts is supported and gives you a secure,
randomly generated port, username and password.

Both character sets are RFC 3986 unreserved, so the `socks5://` URI it prints
needs no escaping.

## Commands

```sh
sudo sh socks5.sh            # install if absent, otherwise a management menu
sudo sh socks5.sh install
sudo sh socks5.sh status     # service, port, version, install origin
sudo sh socks5.sh show       # re-display the full details, including the password
sudo sh socks5.sh restart
sudo sh socks5.sh uninstall
```

`show` requires root and prints the password to your terminal only — never to a
log or the journal.

There is no `reload` (use `restart`) and no `reconfigure`: to change the port,
username or password, uninstall and install again.

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

A dedicated namespace is used throughout, so an existing system 3proxy is never
touched. If any of these already exists and the state file cannot confirm this
script created it, the installer **stops** rather than overwriting it.

The proxy runs as the unprivileged `socks5proxy` account; privilege dropping is
the init system's job, so the configuration contains no `setuid`/`setgid`. Ports
are restricted to 1024 and above, so no capability to bind privileged ports is
ever granted.

On Alpine, OpenRC sends the engine's output to syslog through `logger`; no
ordinary log file is created.

## Build dependencies

The script compiles 3proxy from a pinned commit, so a toolchain is installed
first. The exact list is displayed as part of the single pre-install confirmation,
before anything is installed:

| Package manager | Packages |
|---|---|
| `apt` | `git build-essential` |
| `apk` | `git build-base musl-dev linux-headers` |
| `dnf` / `yum` | `git gcc make` |

Two runtime tools are added only when they are genuinely missing:

- `curl`, used by the post-install self-test.
- whichever package provides `ss` — `iproute2` on Debian, Ubuntu and Alpine,
  `iproute` on CentOS Stream. The port prompt has to be able to see which ports
  are already listening, so this is installed *before* you are asked for a port.
  On a host that already has `ss` or `netstat`, nothing extra is installed.

**These packages are intentionally left in place.** Neither the end of the
install nor `uninstall` removes them — the script never removes a system
package, because it cannot know what else on your server depends on one. Remove
them yourself if you want to.

## Updates are your responsibility

This release pins one upstream commit:

```
3proxy 0.9.9.0 @ da99424eac4092e3722f1a5b1844cfe80478f580
```

The binary is built from that commit and is **not** managed by your
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
  log, or shell history. The install-time self-test passes it to `curl` through
  `--config -` on stdin.
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
password entry and asserts the terminal's `ECHO` flag is restored, plus
regression tests for hostile state files, inherited `umask 0000`/`0022`, and
`sh -x` credential leakage. Python is used by test tooling only; `socks5.sh`
itself depends on POSIX `sh`, `git`, `make`, a C compiler and `curl`.

The real compilation, the OS/architecture build matrix, the seven protocol
acceptance cases, the destination-ACL hostname test, `shellcheck`, and the four
real service-install lifecycles are **CI only** — see
`.github/workflows/ci.yml`. A green local suite does not imply those passed, and
at the time of writing **CI has not been run**. Nothing in this project has yet
been executed on a real host, so treat the Requirements table above as the set of
targets this script is *written* for, not a list of platforms it is known to work
on.

What each CI job actually proves is deliberately distinct:

| Job | Cells | What it proves |
|---|---|---|
| `lint` | 1 | `shellcheck`, Python syntax, and the workflow's own structural guards |
| `unit` | 2 | this suite under `sh`, `dash` and `busybox sh`, on amd64 and arm64 |
| `build-matrix` | 16 | the pinned commit compiles on every OS/arch |
| `protocol` | 16 | the seven protocol cases against a **real engine running the rendered config** — not a service install |
| `acl-resolution` | 3 | the destination denies hold for **domain** targets, in an isolated container with a fake metadata endpoint |
| `systemd-integration` | 2 | a **real** install → verify → uninstall lifecycle under systemd, on the runner itself |
| `openrc-integration` | 2 | the same under **real** OpenRC on Alpine, bootstrapping its own toolchain from a clean image |
| `distro-systemd-integration` | 3 | the same on Ubuntu 22.04, Debian and CentOS Stream, with systemd booted as PID 1 in a privileged container |

Together the last three give one real service-install lifecycle per supported OS
family. A compile-only cell and a direct-engine protocol cell do not substitute
for that: neither installs a service.

No job uses `continue-on-error`, so every cell is configured to block the release,
Alpine included. A SOCKS4-family success, or a bypassed destination deny, fails the job outright.
Note that "blocks the release" describes how the gate is configured — not a
result, since none of it has run yet.

CI passwords are generated at runtime and handed to the protocol scripts as the
*path* to a `0600` file (`PASSFILE=...`), never as an environment variable and
never as a command-line argument, so they cannot reach a job log, `ps`, or a
child process's environment.

See `SPEC.md` for the specification and `tasks/` for the implementation plan.

## License

MIT — see [LICENSE](LICENSE). 3proxy is not bundled; it is fetched and compiled
at install time under its own separate license.
