# socks5.sh

[English](README.md) | [简体中文](README.zh-CN.md)

A single-file POSIX shell installer and manager for a **password-authenticated
SOCKS5 proxy** on a server you own or are authorised to administer.

It installs a pinned 3proxy 0.9.9.0 binary, verifies it by size and SHA-256,
creates a locked-down service account, starts the service, and proves that valid
credentials work while invalid credentials are refused. The target host does
not compile anything.

> **SOCKS5 is not a VPN. Authentication is cleartext on the wire.** Read
> [Security](#security) before exposing the proxy to the internet.

The raw `develop/socks5.sh` URL is the moving development channel. Published
versioned tags are the stable installation channel under this project's
never-move release policy. GitHub does not currently enforce tag immutability,
so verify the documented SHA-256 before running tagged bytes.

<!-- section: alpine -->
## Alpine Linux deployment

Alpine Linux is documented first because its stock shell changes how the
one-line bootstrap must be written.

### Requirements and exact evidence

- Run from a **root shell** on Alpine Linux 3.20 or newer.
- Supported architectures: `x86_64` / `amd64` and `aarch64` / `arm64`.
- The version rule is a floor: newer Alpine releases use the same accepted code
  path, but exact current CI evidence is for Alpine 3.20 and 3.24 only.
- OpenRC is the supported Alpine init system.

### One-line install on stock Alpine

Install Bash first, then explicitly make Bash parse the process substitution:

```sh
apk add --no-cache bash wget && bash -c 'bash <(wget -qO- https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/develop/socks5.sh)'
```

Stock Alpine starts in BusyBox `ash`. Process-substitution support depends on
the BusyBox build and `/dev/fd`; this project deliberately does not rely on that
build-specific compatibility. The quoted `bash -c` argument ensures the command
string is parsed by Bash after Bash is installed.

Do not replace the command with `wget ... | sh`. The installer is interactive;
a pipe would occupy the wizard's stdin and break its prompts. Bash is needed
only for the one-line process-substitution bootstrap. A saved copy of the
installer runs as POSIX `sh`.

### What Alpine installs

The bootstrap explicitly adds `bash` and `wget`. They are bootstrap tools, not
the installer's runtime dependency set.

After the default-yes confirmation, the installer adds only genuinely missing
runtime packages with `apk add --no-cache`:

- `curl`, for the verified engine download and authentication self-test;
- `ca-certificates`, only when no supported CA bundle is available;
- `iproute2`, only when `/proc/net/tcp{,6}`, `ss`, and `netstat` cannot provide a
  usable listener check.

Only after that confirmation, the displayed missing runtime prerequisites are installed.
No port, username, or password is collected before that step finishes.

The target receives no Git, Make, GCC, headers, Python, or source checkout. It
does not compile 3proxy and has no local-build fallback. Runtime packages are
left in place after uninstall because the script cannot know what else depends
on them.

### Alpine engine assets

Alpine selects the versioned **musl** asset from release
`engine-3proxy-0.9.9.0-r2`, built from pinned commit
`da99424eac4092e3722f1a5b1844cfe80478f580`:

| Architecture | Asset family | Embedded size | Embedded SHA-256 |
|---|---|---:|---|
| `amd64` | musl amd64 | 298280 bytes | `ac3fe1a7d52d2b1494d4d00884fc7517acb2340454c2653c95a7346c05d69298` |
| `arm64` | musl arm64 | 277624 bytes | `38f2733dfc5d375a4faaebe79f66bd181c7cc3e7b3eb9443c3ac4476fbfeebeb` |

The download follows HTTPS-only redirects, is byte-bounded, and must match the
embedded size and embedded SHA-256 before installation. The installed file is
hashed again. Any mismatch fails closed.

### Complete the Alpine wizard

The installer asks five questions in this order:

1. **Language** — `1 中文 / 2 English`. Enter alone selects 中文. Unsupported
   input is rejected and the answer is re-asked. This is the first question on
   every invocation, and the choice is never saved.
2. **Confirmation** — detected OS, package manager, init system, missing runtime
   packages, and the security warning are shown first. A single `[Y/n]` question controls the fresh installation.
3. **Port** — Enter generates a value in `20000–60000`. A custom value must be
   in `1024–65535` and not already listening.
4. **Username** — Enter generates one. Custom input uses `A-Z a-z 0-9 _ -` and
   must be `3–32` characters.
5. **Password** — Enter generates exactly `32` characters. Custom input uses
   `A-Z a-z 0-9 . _ ~ -`, must be `12–128` characters, and is read once.
   Custom input is visible; enter it only where another person, terminal recorder, or serial-console logger cannot observe the screen.

Entering only blank answers selects Chinese and securely generated values.
Script-owned output follows the selected language; raw `apk` and OpenRC output
remains in the language used by those tools.

### Open the Alpine port yourself

This script has no firewall functionality at all. It does not detect, query,
add, remove, reload, or persist firewall rules. You must allow inbound TCP on the
selected port in both applicable places:

1. the Alpine host's own firewall; and
2. the cloud provider's security group or network ACL.

The correct firewall backend, table/chain, and persistence mechanism depend on
your image. The examples in [Firewall responsibility](#firewall-responsibility)
are operator examples only; the installer never runs them.

### OpenRC service behavior

Alpine installs `/etc/init.d/socks5-manager`, adds it to the default runlevel,
and runs the proxy through `supervise-daemon` as
`socks5proxy:socks5proxy`.

Its dependency block orders the service after a firewall service when one
exists and uses DNS/logger services; it does not configure a firewall and does
not require `need net`. Stdout and stderr are sent through `logger` to the host's
syslog. No ordinary project log file is created, so this project defines no log
rotation policy. The command used to read syslog depends on the logger/syslog
stack installed on that Alpine host; this project does not promise one universal
log-reading command.

### Manage Alpine from the root shell

If you saved the script, use POSIX `sh`; do not assume `sudo` is installed:

```sh
sh socks5.sh             # install if absent; otherwise open the menu
sh socks5.sh install     # fresh install or in-place credential/port update
sh socks5.sh status      # service, listener, user, engine and install origin
sh socks5.sh show        # credential card, including the password; TTY only
sh socks5.sh restart     # restart and wait for the configured port
sh socks5.sh uninstall   # default-no confirmation, then safe removal
```

Re-running the one-line bootstrap opens the management menu when the installation
is healthy. On an existing installation, `install` is the transactional update
path. It asks a default-no `[y/N]` confirmation, reuses the binary/account/service
definition, and restores the old verified proxy if the candidate fails. There is
no public `reload` or `reconfigure` command.

### Alpine troubleshooting

- Install and update verification require DNS, outbound HTTPS, and access to the
  fixed self-test target `https://example.com/`.
- The credential card separately makes one nonfatal request to
  `https://icanhazip.com`. It receives no port, username, or password, accepts at
  most a 17-byte response, and reports a source IP—an egress observation, not
  proof of inbound reachability. Failure prints exactly one localized warning
  and uses `SERVER_IPV4`.
- `status` distinguishes running, stopped, and unverified states; it does not
  turn a failed manager query into a false "stopped" claim.
- Alpine 3.20 can briefly report that an OpenRC service is already starting.
  The installer rechecks manager state and waits for the listener instead of
  treating that transient command result as service failure.
- The **128 MiB/no-swap** statement is a CI OpenRC target-container cgroup gate.
  It is not an installer-side minimum-memory rejection for arbitrary hosts.

<!-- section: general-install -->
## Ubuntu, Debian, and CentOS Stream quick start

Run as root or from a root shell:

```sh
bash <(wget -qO- https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/develop/socks5.sh)
```

Curl alternative:

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/develop/socks5.sh)
```

To inspect the moving candidate before running it:

```sh
wget -qO socks5.sh https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/develop/socks5.sh
less socks5.sh
sudo sh socks5.sh
```

The saved script is plain POSIX `sh`.

<!-- section: credentials -->
## Credential card and connection

A successful install or update prints a credential card only when stdout is a real terminal.
It contains Host, Port, Username, Password, and exactly one copyable URI:

```text
socks5://user:password@host:port
```

| Client field | Credential-card value |
|---|---|
| Proxy type | SOCKS5 |
| Host | `Host` |
| Port | `Port` |
| Username | `Username` |
| Password | `Password` |

The Host comes from exactly one short request per card to the fixed endpoint
`https://icanhazip.com`. The endpoint sees only the server's source IP and
request time; no port, username, or password is sent. A source IP is an egress
observation, not proof that inbound traffic can reach the server.

Malformed, private, multiline, oversized, or failed responses are rejected
without failing installation. The card uses `SERVER_IPV4` and prints exactly one localized warning. If output is redirected or piped, the secret card is withheld;
run `sudo sh socks5.sh show` from a real terminal. `show` prints the password to your terminal only.

<!-- section: management -->
## Management and updates

For saved-script installations outside the Alpine root-shell example:

```sh
sudo sh socks5.sh
sudo sh socks5.sh install
sudo sh socks5.sh status
sudo sh socks5.sh show
sudo sh socks5.sh restart
sudo sh socks5.sh uninstall
```

Every invocation starts with language selection again. `status` never prints the
password. A confirmed `install` on a healthy existing installation updates the configuration in place and verifies the new credentials/listener transactionally.

<!-- section: supported-systems -->
## Supported systems

| Requirement | Supported values |
|---|---|
| Ubuntu support | Ubuntu 20.04: `amd64` only; Ubuntu 22.04+: `amd64` / `arm64` |
| Other OS floors | Debian 12+, Alpine Linux 3.20+, CentOS Stream 9+ |
| Architecture | `x86_64` / `amd64`, `aarch64` / `arm64` |
| Privileges | root |
| Init | systemd; OpenRC on Alpine |

Ubuntu 20.04 is an exact amd64-only exception; Ubuntu 22.04 and newer retain
both architectures. Ubuntu 20.04 is outside standard security maintenance, so
compatibility support does not replace an operator's Ubuntu Pro/ESM or other
patch-management policy. A recognised version at or above the other floors is accepted. Acceptance does not
claim that every future release was tested. The expanded workflow includes Ubuntu 20.04 amd64 compatibility, protocol and
real systemd lifecycle cells. Existing exact-version evidence covers Ubuntu
22.04/24.04, Debian 12/13, Alpine 3.20/3.24, and CentOS Stream 9/10 for
asset compatibility and protocol boundaries on both architectures. The real
OpenRC lifecycle cells cover Alpine 3.20 and 3.24 on the amd64 runner; musl arm64
is separately proved by compatibility and protocol cells. RHEL, Rocky Linux,
and AlmaLinux are reported as likely compatible but are not installed on.
Unsupported IDs, versions, architectures, and init systems fail closed instead
of being guessed.

<!-- section: protocol -->
## Protocol boundary

| Capability | Contract |
|---|---|
| SOCKS5 | Supported |
| RFC 1929 username/password | Mandatory |
| CONNECT | The only permitted command |
| Unauthenticated access | Rejected |
| BIND | Rejected |
| UDP ASSOCIATE | Rejected |

The generated configuration uses `auth strong`, `socks -u2`, a CONNECT-only
allow rule, and a terminal `deny *`. The `-4` flag means **IPv4 destination resolution only**; `-u2` means **require username/password** among offered methods.
CI rejection probes block a release if any undocumented legacy-family path can
establish a proxy connection.

Destination ACLs deny this-network, private, CGNAT, loopback, link-local
(including `169.254.169.254`), multicast, and reserved IPv4 ranges before the
CONNECT allow rule. CI verifies the same boundary for literal IPs and hostnames.

<!-- section: security -->
## Security

- **Authentication is cleartext.** Anyone who can observe the network path may
  read the username and password.
- **SOCKS5 is not an encrypted tunnel and not a VPN.** Use SSH, TLS, or a VPN
  when transport encryption is required.
- **The password is stored in plaintext** in
  `/etc/socks5-manager/users.cfg` with `root:socks5proxy 0640`; root and the
  proxy process can read it.
- Anyone who learns the credentials and can reach the port can use the proxy,
  and traffic appears to originate from your server.
- Production listens on `0.0.0.0`, every server IPv4 interface; reachability is
  controlled only by the host firewall and cloud network policy.
- Credentials do not enter command-line arguments, environment variables,
  script logs, the journal, or shell history. Self-tests use `curl --config -`
  on stdin.
- The script never changes SELinux enforcement, sshd configuration, package
  repositories, or firewall state.

Only use this project on infrastructure you own or are explicitly authorised to
administer.

<!-- section: firewall -->
## Firewall responsibility

The script has no firewall functionality at all. You must configure the host
firewall and cloud security group/network ACL yourself. These are examples for
an operator who has already chosen the correct backend:

| Backend | Example | Persistent across reboot? |
|---|---|---|
| `ufw` | `ufw allow <port>/tcp` | Yes |
| `firewalld` | `firewall-cmd --zone=<zone> --permanent --add-port=<port>/tcp`, then repeat without `--permanent` | Yes |
| `iptables` | `iptables -I INPUT -p tcp --dport <port> -j ACCEPT` | **No**—the rule exists in kernel memory only |
| `nftables` | `nft add rule inet filter input tcp dport <port> accept` | Depends on ruleset persistence |

<!-- section: resources -->
## Installed resources

| Resource | Path and permissions |
|---|---|
| Engine | `/usr/local/libexec/socks5-manager/3proxy` — `root:root 0755` |
| Config directory | `/etc/socks5-manager/` — `root:socks5proxy 0750` |
| Main config | `/etc/socks5-manager/3proxy.cfg` — `root:socks5proxy 0640` |
| Credentials | `/etc/socks5-manager/users.cfg` — `root:socks5proxy 0640` |
| State | `/var/lib/socks5-manager/state` — `root:root 0600` |
| systemd unit | `/etc/systemd/system/socks5-manager.service` |
| OpenRC service | `/etc/init.d/socks5-manager` |
| Account | `socks5proxy` — system account, no home, `nologin`, no password |

Fresh resources are claimed without replacing foreign paths. Mutating operations
use `/run/socks5-manager.lock`. Updates stage a root-only recovery bundle at
`/var/lib/socks5-manager/reconfigure-transaction/`; successful updates remove
it, while failed recovery retains it for inspection and a later retry.

<!-- section: dependencies -->
## Runtime dependencies and engine verification

The host mapping is Ubuntu, Debian, and CentOS Stream to the two glibc labels;
Alpine maps to the two musl labels. The four exact technical labels are
`glibc amd64`, `glibc arm64`, `musl amd64`, and `musl arm64`. Asset names,
exact sizes, and embedded SHA-256 values are fixed in `socks5.sh`. The installer
verifies downloaded bytes before installation and hashes the installed file
again. The r2 generic glibc amd64 binary is built on Ubuntu 20.04 and gated at
`max_required_glibc=2.31` (the published binary currently requires at most
`GLIBC_2.25`). It has no target-side compile or fallback path.

| Family | Asset | Size | SHA-256 |
|---|---|---:|---|
| glibc amd64 | `3proxy-0.9.9.0-da99424-linux-glibc-amd64` | 294552 | `9c2892b46121439f3c5a05fc19ec07fe68d2ce3498110cac29c165749efaafcf` |
| glibc arm64 | `3proxy-0.9.9.0-da99424-linux-glibc-arm64` | 279288 | `344e482272e5c16d1f9c762d7ed240cda43bb050a53be767e5393a616607ccf5` |
| musl amd64 | `3proxy-0.9.9.0-da99424-linux-musl-amd64` | 298280 | `ac3fe1a7d52d2b1494d4d00884fc7517acb2340454c2653c95a7346c05d69298` |
| musl arm64 | `3proxy-0.9.9.0-da99424-linux-musl-arm64` | 277624 | `38f2733dfc5d375a4faaebe79f66bd181c7cc3e7b3eb9443c3ac4476fbfeebeb` |

APT disables recommends; DNF/YUM disable weak dependencies; APK uses
`--no-cache`. CentOS Stream starts with `curl-minimal` and reuses it. Runtime
packages remain installed after uninstall. Keeping the pinned engine updated is
the operator's responsibility. 3proxy calls the 0.9 branch `lts`, but documents
no published support window; do not assume upstream security backports automatically reach this installation.

<!-- section: uninstall -->
## Uninstall and recovery

```sh
sudo sh socks5.sh uninstall
```

Uninstall asks for language and a default-no confirmation. It stops and verifies
the service, removes only state-recorded fixed project resources, and uses
non-recursive deletion: unexpected directory entries are preserved rather than
erased. It never removes packages, firewall rules, repositories, unrelated
3proxy installations, or arbitrary state-provided paths. Unknown directory
entries or changed identities are retained for inspection and an actionable
retry.

<!-- section: releases -->
## Releases

### v1.0.0 — published

The versioned annotated `v1.0.0` tag points to closure commit `91fd13a`. Project
release policy says the tag is never moved; GitHub does not currently enforce
that policy with an immutable-tag ruleset. Its push run on
the then-current default branch,
[run `33282068288`](https://github.com/91sexboy/One-click-socks5-proxy-setup/actions/runs/33282068288),
passed 45/45 before the tag and
[GitHub Release](https://github.com/91sexboy/One-click-socks5-proxy-setup/releases/tag/v1.0.0)
were published. Tagged script:

`https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/v1.0.0/socks5.sh`

SHA-256:

```text
acbfbfe3e6ba0f37f4e2a24ba8a6d68ec5a36513caae2e22e44a0ed28322e0b1
```

### v1.1.0 — candidate

Current candidate `socks5.sh` SHA-256:

```text
a148b921004dd0253faf845f10c31bcfd49439103db8a7e44b54d6c80e3609b8  socks5.sh
```

The previous bilingual checkpoint, commit
`27ed6d97048f9d3aadd306461f82bb026146e83e`, passed the former 45-job workflow in
[run `33473381427`](https://github.com/91sexboy/One-click-socks5-proxy-setup/actions/runs/33473381427).
It predates the r2 consumer and Ubuntu 20.04 support and is historical evidence,
not proof of the current candidate.

This Ubuntu 20.04 implementation is the prospective implementation checkpoint.
It must pass the expanded 48-job workflow before an evidence-only commit can
record that result. The evidence-only commit and exact closure commit must each
then pass all 48 jobs on `develop`. Only then is the versioned `v1.1.0` tag
created under the project's never-move policy. `v1.1.0` is not published yet.

After the tag exists, verify it with:

```sh
wget -qO socks5.sh https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/v1.1.0/socks5.sh
printf '%s  %s\n' 'a148b921004dd0253faf845f10c31bcfd49439103db8a7e44b54d6c80e3609b8' socks5.sh | sha256sum -c -
sudo sh socks5.sh
```

<!-- section: verification -->
## Verification and development

The current workflow expands to 48 blocking jobs:

| Job | Cells | Evidence |
|---|---:|---|
| `lint` | 1 | shellcheck, syntax and workflow guards |
| `unit` | 2 | sh, dash and BusyBox sh on amd64/arm64 |
| `build-matrix` | 17 | 16 existing OS/architecture tuples plus Ubuntu 20.04 amd64 |
| `protocol` | 17 | seven protocol cases, including Ubuntu 20.04 amd64 |
| `acl-resolution` | 3 | literal-IP and hostname destination denies |
| `systemd-integration` | 2 | native Ubuntu lifecycle on amd64/arm64 |
| `openrc-integration` | 2 | Alpine 3.20/3.24 lifecycle and OpenRC target-container cgroup |
| `distro-systemd-integration` | 4 | Ubuntu 20.04/22.04, Debian 12, CentOS Stream 9 |

The systemd memory gate uses a shared systemd slice containing both the operation runner and proxy service. All jobs block release; none uses
`continue-on-error`.

Local checks:

```sh
sh tests/run.sh
S5_TEST_SHELL=dash sh tests/run.sh
S5_TEST_SHELL='busybox sh' sh tests/run.sh
sh -n socks5.sh
```

See [`SPEC.md`](SPEC.md) for the complete contract.

<!-- section: license -->
## License

MIT — see [`LICENSE`](LICENSE). 3proxy source is not bundled; verified engine
assets are built separately under the upstream project's license.
