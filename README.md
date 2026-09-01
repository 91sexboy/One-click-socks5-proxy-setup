# socks5.sh

A single-file POSIX shell installer and manager for a **password-authenticated
SOCKS5 proxy** on a server you own or are authorised to administer.

It installs a pinned 3proxy 0.9.9.0 binary, verifies it by size and SHA-256,
creates a locked-down service account, starts the service, and checks that
correct credentials work while incorrect credentials are refused. The target
server does not compile anything.

> **SOCKS5 is not a VPN. Authentication is cleartext on the wire.** Read
> [Security](#security) before exposing the proxy to the internet.

## Quick start

The raw `develop/socks5.sh` URL is the moving development channel and serves
current candidate code. For immutable, reviewed bytes, use a published
immutable semantic-version tag and verify its documented SHA-256.

### Ubuntu, Debian, or CentOS Stream

Run as root, or from a root shell:

```sh
bash <(wget -qO- https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/develop/socks5.sh)
```

Curl alternative:

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/develop/socks5.sh)
```

### Stock Alpine Linux

Alpine's default `ash` shell cannot parse `<(...)`. Install Bash first and hide
the process substitution inside the string Bash will parse:

```sh
apk add --no-cache bash wget && bash -c 'bash <(wget -qO- https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/develop/socks5.sh)'
```

Do not replace these commands with `wget ... | sh`: the installer is
interactive, so piping the script into `sh` would consume the wizard's stdin.

### Read the script before running it

```sh
wget -qO socks5.sh https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/develop/socks5.sh
less socks5.sh
sudo sh socks5.sh
```

The saved script is plain POSIX `sh`. Bash is needed only by the one-line
process-substitution form.

## First installation

The installer is interactive and asks five questions in this order:

1. **Language** — `1 中文 / 2 English`. Enter alone selects 中文. Unsupported
   input is rejected and the answer is re-asked. This is the first question on
   every run, and the choice is never saved.
2. **Confirmation** — the script displays the detected system, the exact list
   of missing packages it would install, and the security warning. A single
   `[Y/n]` question controls the fresh installation.

Only after that confirmation, the displayed missing runtime prerequisites are installed.
That step finishes before the following value prompts; it is not a sixth question.
No port, username, or password is collected before that step finishes.

3. **Port** — Enter generates a random port in `20000–60000`. A custom port must
   be in `1024–65535` and must not already be listening.
4. **Username** — Enter generates one. A custom username may contain
   `A-Z a-z 0-9 _ -` and must be 3–32 characters.
5. **Password** — Enter generates a 32-character password. Custom input is visible,
   read once, limited to `A-Z a-z 0-9 . _ ~ -`, and must be 12–128 characters.
   Enter it only where another person, terminal recorder, or serial-console logger
   cannot observe the screen.

Entering only blank answers selects Chinese and securely generated values.
Package-manager and service-manager output remains in the language those tools
use; all text owned by this script follows the selected language.

## Connect to the proxy

A successful install or update prints a credential card only when stdout is a real terminal.
It contains Host, Port, Username, Password, and one copyable URI:

```text
socks5://user:password@host:port
```

Use those values in any client that supports SOCKS5 username/password
authentication:

| Client field | Credential-card value |
|---|---|
| Proxy type | SOCKS5 |
| Host | `Host` |
| Port | `Port` |
| Username | `Username` |
| Password | `Password` |

The Host is a strictly validated public IPv4 derived from exactly one short HTTPS
request per card to the fixed endpoint `https://icanhazip.com`. The endpoint sees
only the server's source IP and request time; no port, username, or password is
sent. A source IP is an egress observation, not proof that inbound traffic can
reach the server.

If lookup fails or returns anything other than one public IPv4, the card uses
`SERVER_IPV4` and prints exactly one localized warning telling you to replace it
with your server's public IPv4. The lookup response is capped at 17 bytes, and
lookup failure does not fail the installation.

If output was redirected or piped, installation still completes but the secret
card is withheld. Run `sudo sh socks5.sh show` from a real terminal to display
it later; `show` prints the password to your terminal only.

### Open the port yourself

This script has no firewall functionality at all. You must allow inbound TCP
on the selected port in both places that apply:

1. the server's local firewall; and
2. the cloud provider's security group or network ACL.

Examples below are operator commands only—the installer never detects or runs
them:

| Backend | Example | Persistent across reboot? |
|---|---|---|
| `ufw` | `ufw allow <port>/tcp` | Yes |
| `firewalld` | `firewall-cmd --zone=<zone> --permanent --add-port=<port>/tcp`, then repeat without `--permanent` | Yes |
| `iptables` | `iptables -I INPUT -p tcp --dport <port> ... -j ACCEPT` | **No**—the rule exists in kernel memory only |
| `nftables` | `nft add rule inet filter input tcp dport <port> accept` | Depends on your ruleset persistence |

## Manage an installation

Re-running the one-line installer opens the management menu when a healthy
installation already exists. If you saved the script, use these commands:

```sh
sudo sh socks5.sh             # install if absent; otherwise open the menu
sudo sh socks5.sh install     # fresh install or in-place credential/port update
sudo sh socks5.sh status      # service, listener, user, engine and install origin
sudo sh socks5.sh show        # credential card, including the password; TTY only
sudo sh socks5.sh restart     # restart and verify that the configured port listens
sudo sh socks5.sh uninstall   # default-no confirmation, then safe removal
```

Every invocation starts with language selection again.

### Change the port, username, or password

Run:

```sh
sudo sh socks5.sh install
```

On an existing healthy installation, `install` first shows non-secret status
and asks a default-no `[y/N]` confirmation. If confirmed, it collects a new
port, username, and password, then updates the configuration in place.

The update reuses the installed binary, service account, and service definition.
It activates and verifies the new configuration transactionally. If activation
or authentication checks fail, the old configuration is restored and
re-verified automatically.

There is no public `reload` or `reconfigure` command.

## Supported systems

| Requirement | Supported values |
|---|---|
| OS | Ubuntu 22.04+, Debian 12+, Alpine Linux 3.20+, CentOS Stream 9+ |
| Architecture | `x86_64` / `amd64`, `aarch64` / `arm64` |
| Privileges | root |
| Init system | systemd; OpenRC on Alpine |

Recognised distro versions at or above the minimum are accepted. A newer
version being accepted does not mean that exact release was tested in CI.
RHEL, Rocky Linux, and AlmaLinux are reported as likely compatible but are not
installed on. Unsupported IDs, versions, architectures, or init systems fail
closed instead of being guessed.

## Protocol boundary

| Capability | Support |
|---|---|
| SOCKS5 | Yes |
| RFC 1929 username/password authentication | Mandatory |
| CONNECT | The only permitted command |
| Unauthenticated connections | Rejected |
| BIND | Rejected |
| UDP ASSOCIATE | Rejected |

The generated config uses `auth strong`, `socks -u2`, a CONNECT-only allow rule,
and a terminal `deny *`. The `-4` flag means **IPv4 destination resolution only**;
`-u2` means **require username/password** among the offered authentication
methods. CI rejection probes enforce that only the documented SOCKS5 surface can
succeed; any legacy-family success fails the job and blocks release.

Destination ACLs deny this-network, private, CGNAT, loopback, link-local
(including `169.254.169.254`), multicast, and reserved IPv4 ranges before the
CONNECT allow rule. CI also proves these denies apply when the client supplies
a hostname rather than a literal IP.

## Security

Read these constraints before using the proxy:

- **Authentication is cleartext.** Anyone who can observe the network path may
  read the username and password.
- **SOCKS5 is not an encrypted tunnel and not a VPN.** For sensitive use, put it
  inside SSH, TLS, or a real VPN.
- **The password is stored in plaintext** as 3proxy `CL:` credentials in
  `/etc/socks5-manager/users.cfg`. The file is `root:socks5proxy 0640`, so root
  and the proxy process can read it.
- Anyone who knows the credentials and can reach the port can use the proxy,
  and their traffic will appear to originate from your server.
- The service listens on `0.0.0.0`; local and cloud firewall policy is your
  responsibility.
- The credential is not passed in command-line arguments, environment
  variables, script logs, the journal, or shell history. Self-tests feed it to
  `curl -q --config -` on stdin.
- The script never changes SELinux enforcement, sshd configuration, package
  repositories, or firewall state.

Only use this project on infrastructure you own or are explicitly authorised
to administer.

## What is installed

| Resource | Path and permissions |
|---|---|
| Engine binary | `/usr/local/libexec/socks5-manager/3proxy` — `root:root 0755` |
| Config directory | `/etc/socks5-manager/` — `root:socks5proxy 0750` |
| Main config | `/etc/socks5-manager/3proxy.cfg` — `root:socks5proxy 0640` |
| Credentials | `/etc/socks5-manager/users.cfg` — `root:socks5proxy 0640` |
| State | `/var/lib/socks5-manager/state` — `root:root 0600` |
| systemd unit | `/etc/systemd/system/socks5-manager.service` |
| OpenRC service | `/etc/init.d/socks5-manager` |
| Service account | `socks5proxy` — system account, no home, `nologin`, no password |

The proxy runs as the unprivileged `socks5proxy` account. A dedicated namespace
prevents an unrelated system 3proxy installation from being adopted or
modified. If a fixed project path already exists but state cannot prove this
script owns it, installation stops rather than overwriting it.

Mutating operations use `/run/socks5-manager.lock`. An update temporarily uses
`/var/lib/socks5-manager/reconfigure-transaction/`; successful updates remove
it, while failed recovery keeps the root-only transaction data so the next
mutating command can retry safely.

On Alpine, service output goes to syslog through `logger`; no ordinary project
log file is created.

## Runtime dependencies and engine verification

The target host receives no Git, Make, GCC, headers, or source checkout. Only
genuinely missing runtime packages may be installed:

- `curl` for the engine download and authentication self-test;
- `ca-certificates` if no supported CA bundle exists;
- `iproute2` on Ubuntu, Debian, or Alpine—or `iproute` on CentOS Stream—only if
  `/proc/net/tcp{,6}`, `ss`, and `netstat` are all unavailable or unusable.

APT disables recommends, DNF/YUM disable weak dependencies, and APK uses
`--no-cache`. CentOS Stream starts with `curl-minimal` and reuses it; other
supported targets install curl only when it is genuinely absent. Runtime
packages are intentionally left in place after uninstall because the script
cannot know what else depends on them. Keeping the pinned engine updated is
also your responsibility; it is not managed by the distro package manager.
3proxy calls the 0.9 branch `lts` but documents no published support window for
it. This project pins one commit, so do not assume upstream security backports automatically reach this installation; monitor upstream and move to a newly
reviewed release when needed.

The immutable engine release `engine-3proxy-0.9.9.0-r1` contains four binaries
built from pinned commit `da99424eac4092e3722f1a5b1844cfe80478f580`:

| Host | Asset family |
|---|---|
| Ubuntu / Debian / CentOS Stream amd64 | glibc amd64 |
| Ubuntu / Debian / CentOS Stream arm64 | glibc arm64 |
| Alpine amd64 | musl amd64 |
| Alpine arm64 | musl arm64 |

Asset names, exact sizes, and embedded SHA-256 values are fixed in `socks5.sh`.
The download follows HTTPS-only redirects, applies time and byte limits,
requires an exact size and embedded SHA-256 before installation, then verifies
the installed binary again. Any mismatch fails closed; there is no local-build
fallback.

## Uninstall behavior

```sh
sudo sh socks5.sh uninstall
```

Uninstall asks for language and a default-no confirmation. It removes only
fixed project resources recorded as created in the state file. State stores
flags, not arbitrary paths, and nothing is removed recursively.

If a project directory contains an unknown file, the directory and state file
are kept, the unexpected entry is reported, and uninstall exits non-zero so you
can inspect and retry. Account and group removal are verified before success is
reported.

Uninstall never removes system packages, firewall rules, package repositories,
an unrelated 3proxy installation, or files outside the project namespace.

## Releases

### v1.0.0 — published

The immutable `v1.0.0` tag points to closure commit `91fd13a`. Its push run on
the then-current `main`, [run `33282068288`](https://github.com/91sexboy/One-click-socks5-proxy-setup/actions/runs/33282068288),
passed 45/45. The tagged script is available at
`https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/v1.0.0/socks5.sh`
and has SHA-256:

```text
acbfbfe3e6ba0f37f4e2a24ba8a6d68ec5a36513caae2e22e44a0ed28322e0b1
```

### v1.1.0 — candidate

The candidate adds transactional updates, bilingual lifecycle management,
hardened credential cards, verified prebuilt engine assets, bounded downloads,
128 MiB lifecycle gates, and fail-closed resource claiming. Current candidate
`socks5.sh` SHA-256:

```text
be9c46ff675b0a64d87da01ecbf0c2d51fba925ffc95b0a96a5a03b89b091230  socks5.sh
```

Before the current safety repair, implementation commit
`f508666e0b31512b32502a3bb1a85b9742671b52` passed
[CI run 33355799664](https://github.com/91sexboy/One-click-socks5-proxy-setup/actions/runs/33355799664)
and evidence commit `a7fbaeb2e9a6507fe45a502c65324c828d132fc8` passed
[CI run 33376645854](https://github.com/91sexboy/One-click-socks5-proxy-setup/actions/runs/33376645854), both 45/45. Those runs are superseded by the current safety repair
because `socks5.sh` changed again; they are historical evidence, not proof of the
current candidate.

The release chain must restart: the repaired implementation commit must pass 45/45; an evidence-only commit must then pass 45/45 after recording that full
SHA and run; the exact closure commit must pass 45/45 on `develop`. Only then is
Only then is the immutable `v1.1.0` tag created at that exact closure commit,
and it is never moved.

After the tag exists, download and verify it with:

```sh
wget -qO socks5.sh https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/v1.1.0/socks5.sh
printf '%s  %s\n' 'be9c46ff675b0a64d87da01ecbf0c2d51fba925ffc95b0a96a5a03b89b091230' socks5.sh | sha256sum -c -
sudo sh socks5.sh
```

Until then, `/develop/socks5.sh` remains the moving development channel and
serves the current v1.1 candidate. Use `/v1.0.0/socks5.sh` for immutable released
v1.0 bytes; after publication, `/v1.1.0/socks5.sh` will identify immutable v1.1
bytes.

## Verification and development

Local unit tests use recording stubs and a temporary root; they do not alter
real accounts, services, firewalls, or system paths:

```sh
sh tests/run.sh
S5_TEST_SHELL=dash sh tests/run.sh
S5_TEST_SHELL='busybox sh' sh tests/run.sh
sh -n socks5.sh
```

The superseded pre-safety implementation run `33355799664` demonstrates the
45-job workflow structure the repaired candidate must pass again:

| Job | Cells | Evidence |
|---|---:|---|
| `lint` | 1 | shellcheck, Python syntax, workflow guards |
| `unit` | 2 | sh, dash, and BusyBox sh on amd64 and arm64 |
| `build-matrix` | 16 | matching engine asset loads across 8 OS versions × 2 architectures |
| `protocol` | 16 | seven protocol cases against a real engine running the rendered config |
| `acl-resolution` | 3 | hostname and literal-IP destination denies |
| `systemd-integration` | 2 | native Ubuntu 24.04 lifecycle on amd64 and arm64 |
| `openrc-integration` | 2 | Alpine 3.20 and 3.24 install/update/restart/uninstall |
| `distro-systemd-integration` | 3 | Ubuntu 22.04, Debian 12, and CentOS Stream 9 lifecycle |

All jobs are blocking; none uses `continue-on-error`. Compatibility and protocol
matrices also cover Ubuntu 24.04, Debian 13, Alpine 3.24, and CentOS Stream 10.
The 128 MiB/no-swap gate uses a shared systemd slice containing both the
operation runner and proxy service, or one OpenRC target-container cgroup.

See [`SPEC.md`](SPEC.md) for the complete behavior and verification contract.

## License

MIT — see [`LICENSE`](LICENSE). 3proxy source is not bundled; verified engine
assets are built separately under the upstream project's license.
