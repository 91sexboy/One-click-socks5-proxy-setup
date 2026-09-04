# Xray-only mixed proxy

A single-file POSIX shell installer that deploys a verified Xray-core `mixed`
proxy on a Linux server you own or are authorised to administer.

This project installs no 3x-ui, no web panel, no database, no subscription
service and no second proxy engine. It runs one Xray process and serves both of
the following on the same TCP port:

- SOCKS5 with RFC 1929 username/password authentication;
- HTTP proxy with Basic username/password authentication.

## Quick install

Run this in a root shell:

```sh
curl -fsSL https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/xray-only/socks5.sh -o socks5.sh
sh socks5.sh
```

The script asks for a language first:

```text
1) 中文
2) English
```

It then asks for a port, a username and a password. Pressing Enter at any of
those prompts generates a value:

- port: `20000–60000`; a manual port must be within `1024–65535` and must not
  already be listening;
- username: generated, or 3–32 letters, digits, underscores or hyphens;
- password: 32 generated characters, or 12–128 safe characters entered by hand.

After installation:

```sh
sh socks5.sh install      # install or update
sh socks5.sh status       # state, without the password
sh socks5.sh show         # credentials, root on a real TTY only
sh socks5.sh restart      # restart and re-verify the port
sh socks5.sh uninstall    # declines by default
```

## What `mixed` means

Xray's `mixed` inbound puts the SOCKS and HTTP proxies on one listening port.
Which of the two a client speaks is decided by the bytes the client sends:

```text
SOCKS5: socks5://user:password@host:port
HTTP:   http://user:password@host:port
```

With `socks5://` the client still performs the standard SOCKS5 greeting, RFC
1929 username/password authentication and CONNECT. `mixed` only additionally
lets an HTTP proxy client reach the same port; it is not a pure SOCKS5 server.

The first release pins:

```text
protocol: mixed (SOCKS5 + HTTP)
auth:     password
accounts: one
UDP:      disabled
```

UDP ASSOCIATE is therefore not offered. BIND, unauthenticated access, wrong
credentials and unsupported legacy SOCKS requests are all verified in CI as
rejected or as failing closed.

## How it runs

```text
script
  → check root, distribution, architecture, dependencies and a listen probe
  → download the pinned Xray ZIP
  → verify the archive size and SHA-256
  → extract and verify the xray ELF safely
  → render one mixed JSON configuration
  → run xray run -test -c candidate
  → replace the configuration atomically
  → run Xray as a non-root account
  → wait for the service and the exact port to become ready
  → verify SOCKS5, HTTP and sustained bidirectional transport locally
```

The configuration contains no Xray API, stats, metrics, routing, GeoIP,
GeoSite, TLS, REALITY, WebSocket, gRPC, XHTTP or second public listener.

The script does not modify host firewalls, cloud security groups, NAT or port
forwarding. Opening the chosen TCP port is left to the administrator.

## Pinned Xray release and assets

The default is the official stable Xray-core `v26.3.27`. `latest`, `main`,
`dev-latest` and prereleases are not used.

| Architecture | Official archive | Archive size | Archive SHA-256 |
|---|---|---:|---|
| `amd64` / `x86_64` | `Xray-linux-64.zip` | 21136402 | `23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae` |
| `arm64` / `aarch64` | `Xray-linux-arm64-v8a.zip` | 19716427 | `4d30283ae614e3057f730f67cd088a42be6fdf91f8639d82cb69e48cde80413c` |

Release tag commit:

```text
d2758a023cd7f4174a5a5fa4ff66e487d4342ba0
```

The archive is expected to hold `xray`, `geoip.dat`, `geosite.dat`, `LICENSE`
and `README.md` at its root. The installer installs only `xray`; the geo data
files are not installed.

The installer checks the archive size, SHA-256, member names, member count, the
extracted ELF type, the target architecture and the binary SHA-256. The official
Linux binaries are statically linked, so the target host needs no Go, Git, GCC,
Make or source compilation.

## Files and permissions

| Resource | Path | Expected ownership and mode |
|---|---|---|
| Xray binary | `/usr/local/libexec/xray-socks5/xray` | `root:root 0755` |
| Configuration directory | `/etc/xray-socks5/` | root-owned, private |
| Xray configuration | `/etc/xray-socks5/config.json` | `root:xray-socks5 0640` |
| State | `/var/lib/xray-socks5/state` | `root:root 0600` |
| systemd unit | `/etc/systemd/system/xray-socks5.service` | `root:root 0644` |
| Operation lock | `/run/xray-socks5.lock` | root-owned |
| Service account | `xray-socks5` | system account, no home, `nologin`, no password |

The password is stored only in the protected Xray JSON configuration. State
holds the username, release, asset metadata and configuration hash, never the
password. The password does not enter the service `ExecStart`, the environment,
shell history or logs.

A new installation uses the independent `xray-socks5` namespace and never
adopts, overwrites or removes the `socks5-manager` paths or the `socks5proxy`
account used by the former 3proxy project.

## Security boundaries

- SOCKS5 usernames and passwords travel unencrypted on the wire; use SSH, TLS or
  a VPN when confidentiality is required;
- anyone holding the credentials who can reach the port can use the proxy, and
  the traffic appears to originate from the server;
- accepting both SOCKS5 and HTTP on one port is a deliberate compatibility
  choice of this project;
- UDP is disabled, so this is not a UDP relay and not a VPN;
- the password is cleartext on disk inside the Xray configuration, readable only
  by root and the proxy service account;
- the script configures no firewall and no cloud network policy;
- `show` prints the password only on a real TTY; redirection and pipes are
  refused;
- install, update, restart and uninstall take an operation lock, and
  configuration replacement and failure recovery use atomic file flows;
- a failed configuration test happens before a healthy service is stopped, and a
  rejected candidate never replaces the live configuration.

## Lifecycle

An install or update renders a candidate JSON first and runs:

```sh
xray run -test -c /path/to/candidate
```

That command validates the configuration only and binds no port. Only after it
passes does the script replace the live configuration atomically and start:

```sh
xray run -c /etc/xray-socks5/config.json
```

Updates use a complete restart; Xray gRPC hot update is not implemented.
Existing connections close when the service restarts, and afterwards the script
waits for the service and the exact listening port to come back. An Xray
configuration error uses exit status 23, and systemd
`RestartPreventExitStatus=23` keeps a configuration error out of an endless
restart loop.

## Supported targets

The platform check in `socks5.sh` accepts:

- Ubuntu 22.04+ on amd64 and arm64;
- Ubuntu 20.04 on amd64;
- Debian 12+ on amd64 and arm64;
- CentOS Stream 9+ on amd64 and arm64.

Acceptance is not evidence. The full service lifecycle — install, status,
restart, crash recovery, protocol, uninstall — is exercised in CI on **Ubuntu
24.04 amd64 only**. arm64 has archive and binary verification but no lifecycle
job. Ubuntu 22.04, Ubuntu 20.04, Debian 12 and CentOS Stream have no lifecycle
job, so they are accepted but unverified.

A successful Xray archive download is not evidence that a distribution's service
lifecycle has been verified.

Non-systemd init systems are outside the contract: the service contract requires
systemd, and `socks5.sh` refuses to install without it.

## Testing and memory

The complete suite runs in GitHub Actions; the full slow suite is not run
locally. CI verifies:

- asset download, size, hash, architecture and safe extraction;
- JSON shape and Xray `run -test`;
- correct and incorrect authentication for both SOCKS5 and HTTP on one port;
- unauthenticated access, SOCKS4/4a, BIND, and UDP ASSOCIATE under `udp=false`;
- IPv4 literal, hostname and available IPv6 target paths, recorded separately;
- long-lived framed bidirectional transport, idle then resume, and 1/32/128
  concurrent tunnels;
- systemd restart, crash recovery after `SIGKILL`, and the
  `RestartPreventExitStatus=23` guard that keeps a configuration error out of a
  restart loop.

No memory budget is published. The memory job records raw evidence only: the
Xray process `VmRSS`, the service's systemd `MemoryCurrent` and `MemoryPeak`,
and a restart count of zero. OOM counters, startup time and separate
idle/1/32/128-connection peaks are not recorded yet, and no `MemoryMax` is set.

A figure will appear here only together with the Xray version, platform,
configuration, connection count, duration and the CI run that produced it. RSS
must not be inferred from the archive size, and a panel deployment's memory
figures do not describe an Xray-only one.

## License

MIT, see [`LICENSE`](LICENSE).
