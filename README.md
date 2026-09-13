# Xray-only mixed proxy

**English** | [简体中文](README.zh-CN.md)

[![CI — xray-only](https://github.com/91sexboy/One-click-socks5-proxy-setup/actions/workflows/ci.yml/badge.svg?branch=xray-only)](https://github.com/91sexboy/One-click-socks5-proxy-setup/actions/workflows/ci.yml)

A single-file POSIX shell installer for an authenticated **SOCKS5 + HTTP proxy** on a Linux server you own or are authorised to administer.

**One Xray process. One TCP port. One account.** No web panel, database, subscription service, or source build.

> **Authentication is not encryption.** The client–proxy connection carries credentials without transport encryption. Use a trusted network or a separately configured encrypted tunnel; this installer does not set one up.

[Install](#quick-install) · [Commands](#commands) · [Supported systems](#supported-targets) · [Security](#security-boundaries) · [Troubleshooting](#troubleshooting)

## What `mixed` means

Xray-core's `protocol: mixed` inbound accepts two client protocols on the same listening port:

| Client protocol | Authentication | Use |
| --- | --- | --- |
| SOCKS5 | RFC 1929 username/password | TCP CONNECT |
| HTTP proxy | Basic username/password | HTTP CONNECT |

The client chooses which protocol to speak. This is **not a pure SOCKS5 listener**: the same endpoint also accepts authenticated HTTP proxy clients. UDP is disabled (`udp: false`).

The installer binds IPv4 `0.0.0.0` on the selected port and runs Xray under the dedicated, non-login `xray-socks5` account. There is one direct outbound and one blackhole outbound for the destination boundary.

## Supported targets

| System | Accepted versions | Architecture | Service manager |
| --- | --- | --- | --- |
| Ubuntu | 20.04 | amd64 | systemd |
| Ubuntu | 22.04+ | amd64, arm64 | systemd |
| Debian | 12+ | amd64, arm64 | systemd |
| CentOS Stream | 9+ | amd64, arm64 | systemd |
| Alpine Linux | 3.20+ | amd64, arm64 | OpenRC |

`x86_64` maps to `amd64`; `aarch64` maps to `arm64`. Other distribution IDs and architectures are rejected rather than assumed compatible.

**Accepted does not mean lifecycle-tested.** CI exercises installation, configuration update, restart, crash recovery, protocol checks, and uninstall on **Ubuntu 24.04 amd64** and **Alpine 3.20 / 3.24 amd64**. Arm64 has asset and executable verification, not a full service-lifecycle job. Other accepted systems remain lifecycle-unverified.

## Quick install

### 1. Prepare the server

- Use a **root shell** and a working native service manager from the table above.
- Ensure the server can reach GitHub to download the installer and the pinned Xray release.
- On systemd-based systems, prepare the runtime tools first: `curl`, CA certificates, Info-ZIP `unzip` with `-Z` support, `file`, Python 3, `ss`, and the standard account-management tools. Missing commands are reported by the installer.
- On Alpine, the installer provisions its runtime packages through `apk` during precheck, **before installation confirmation**. You still need `curl` to download the script; if missing, bootstrap it with `apk add --no-cache curl ca-certificates`.
- Allow the chosen **TCP port** in your host firewall and cloud security group as appropriate. The script does not configure either, or set up NAT/port forwarding.

### 2. Download and run

Review `socks5.sh` before execution if you need to audit its root-level operations. Run the following from the directory where you want to keep the management script:

```sh
curl -fsSL \
  https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/xray-only/socks5.sh \
  -o socks5.sh &&
sh socks5.sh
```

Without an argument, the script runs `install`.

### 3. Choose language and credentials

On the first invocation without a saved language, choose `1` or Enter for Chinese, or `2` for English. Confirm installation, then enter the port, username, and password.

| Input | Press Enter | Manual value |
| --- | --- | --- |
| Port | Random `20000–60000` | Decimal `1024–65535`, without leading zeros |
| Username | 12 random characters | 3–32 ASCII letters, digits, `_`, `-` |
| Password | 32 random characters | 12–128 ASCII letters, digits, `.`, `_`, `~`, `-` |

**The password is visible while you type it.** A new installation refuses an occupied port. During an update, reusing the existing port is allowed only when its listener belongs to this installation.

After successful installation and verification, a real terminal displays both connection links automatically. Redirected output hides credentials; use `show` later from a terminal.

## Commands

Run these from the directory containing the downloaded script. Installation and management require root.

| Command | Purpose |
| --- | --- |
| `sh socks5.sh install` | Install, or update the existing configuration |
| `sh socks5.sh status` | Show service/listener state, port, username, and version; no password |
| `sh socks5.sh show` | Display connection links; root and a real terminal are required |
| `sh socks5.sh restart` | Restart and repeat listener/authentication checks |
| `sh socks5.sh uninstall` | Remove the managed installation after confirmation |
| `sh socks5.sh language` | Choose and save a different interface language |
| `sh socks5.sh help` | Show command usage |

Re-running `install` is a **configuration update**, not an upgrade to the latest Xray release. Pressing Enter generates new input values; it does not keep the previous credentials or port. New-install confirmation defaults to yes; update and uninstall default to no.

The language preference is saved in `/etc/xray-socks5.lang` and survives uninstall. If it cannot be saved, the script warns that the choice applies only to the current invocation. The `language` command reports failure if saving fails.

`status` can report a stopped or unverified listener without failing as a command. Read its output; a zero exit status alone does not prove proxy availability.

## Connection links and server address

The credential card uses these formats; the values below are placeholders:

```text
socks5://USERNAME:PASSWORD@SERVER_IPV4:PORT
http://USERNAME:PASSWORD@SERVER_IPV4:PORT
```

`http://` here selects an HTTP proxy; it does not enable encrypted proxy transport. `show` refuses to expose credentials through a pipe or redirected stdout.

Each card resolves its displayed address in this order:

1. A valid canonical IPv4 in `S5_SERVER_IPV4`, if provided. This explicit override can be a private address for a private network and skips automatic lookup.
2. One bounded HTTPS request to `icanhazip.com`. Only a strictly validated public IPv4 response is accepted. The request ignores proxy environment variables and does not follow redirects.
3. `SERVER_IPV4` with a warning, if no usable address is available. Replace it with the address your clients can reach.

For an explicit address on one invocation:

```sh
S5_SERVER_IPV4=203.0.113.10 sh socks5.sh show
```

Replace the example address with your own. This changes **only the displayed links**, not the listen address or firewall. An invalid override falls back to automatic lookup. Detecting a public address does not prove that the port is reachable from the Internet.

## Security boundaries

- **Protect the client–proxy connection separately.** SOCKS5 password authentication and HTTP Basic authentication do not encrypt it. HTTPS traffic through the proxy does not encrypt the preceding proxy-authentication exchange.
- Keep access limited to intended clients. Anyone with the credentials and network access to the port can use the proxy; their traffic exits through your server.
- The configuration blocks [twelve literal destination ranges](tests/fixtures/denied-destinations.txt), covering loopback, the listed private/CGNAT ranges, link-local addresses such as cloud metadata at `169.254.169.254`, and other listed special ranges. `IPIfNonMatch` applies this boundary to resolved hostname destinations too. It is not a blanket ban on every non-public address.
- Automatic card-address validation and proxy destination blocking are different policies. Neither replaces a host firewall or cloud network policy.
- Passwords are plaintext in the protected configuration and recovery copies. Do not publish connection cards, configuration files, or backup contents. The state file records the username and integrity metadata, not the password.
- The generated setup contains no panel, API, subscription service, GeoIP/GeoSite database, TLS, REALITY, WebSocket, gRPC, or XHTTP transport. It is not a VPN or UDP relay.

## Lifecycle

Before publication, a candidate configuration must pass:

```sh
xray run -test -c /path/to/candidate.json
```

That command validates configuration without binding a port. The installer then publishes the configuration atomically, starts Xray, verifies listener ownership, checks both authentication protocols, and checks destination refusal against a live local control. Successful proxied payload transport is tested in CI, not by the on-server installer.

- **Updates restart the service.** Existing connections close. A rejected candidate does not replace the live configuration or stop a healthy service.
- **Recovery preserves evidence.** Failures after publication attempt to restore the previous config and state before restarting. If restoration fails, recovery copies remain under `/var/lib/xray-socks5/transaction/`. A later update refuses to overwrite that pending directory, and a failed retry does not remove the earlier backups.
- **Management checks ownership and integrity.** Recorded file hashes and account identity must still match. Hand-editing the managed configuration can make normal management commands refuse it; use the supported update flow instead.
- **Uninstall is conservative.** Unknown or unsafe directory entries are rejected before the service is stopped or managed files/accounts are removed. Runtime packages, firewall settings, and the language preference are retained.
- **Supervision uses the native manager.** systemd uses `Restart=on-failure` and `RestartPreventExitStatus=23`. OpenRC uses `supervise-daemon` with bounded respawns; it does not use systemd's exit-code-specific mechanism.

Management operations use an operation lock. These safeguards do not promise recovery from every storage failure or arbitrary external filesystem modification.

## Files and permissions

| Resource | Path | Owner and mode |
| --- | --- | --- |
| Xray executable | `/usr/local/libexec/xray-socks5/xray` | `root:root 0755` |
| Configuration directory | `/etc/xray-socks5/` | `root:xray-socks5 0750` |
| Configuration | `/etc/xray-socks5/config.json` | `root:xray-socks5 0640` |
| State | `/var/lib/xray-socks5/state` | `root:root 0600` |
| systemd service | `/etc/systemd/system/xray-socks5.service` | `root:root 0644` |
| OpenRC service | `/etc/init.d/xray-socks5` | `root:root 0755` |
| Language preference | `/etc/xray-socks5.lang` | `root:root 0644` |
| Recovery directory | `/var/lib/xray-socks5/transaction/` | `root:root 0700`; backup files `0600` |

Only the selected backend's service definition is installed. The transient lock is `/run/xray-socks5.lock`. Xray runs as the dedicated `xray-socks5` user/group, not root.

This installation does not adopt or remove the old 3proxy route's `socks5-manager` paths or `socks5proxy` account.

## Pinned Xray release and assets

The installer uses the official Xray-core [v26.3.27 release](https://github.com/XTLS/Xray-core/releases/tag/v26.3.27), not `latest`, a development build, or this repository's Releases page.

Upstream tag commit: `d2758a023cd7f4174a5a5fa4ff66e487d4342ba0`.

| Architecture | Official archive | Archive bytes | Extracted binary bytes |
| --- | --- | ---: | ---: |
| amd64 | `Xray-linux-64.zip` | 21136402 | 36577406 |
| arm64 | `Xray-linux-arm64-v8a.zip` | 19716427 | 34209918 |

<details>
<summary>SHA-256 checksums</summary>

```text
amd64 archive
23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae
amd64 binary
8255dd939c34cf966cc91517b6324dd3c8d0bcf49ffac8beca049a38c46845ed

arm64 archive
4d30283ae614e3057f730f67cd088a42be6fdf91f8639d82cb69e48cde80413c
arm64 binary
c2d20a7045250497083afea0d79db0672f6c89a25aaaf37c92de034d6b764b04
```

</details>

The installer verifies archive size/hash, member names and types, and the extracted executable's size/hash/ELF architecture. The archive must contain exactly `xray`, `geoip.dat`, `geosite.dat`, `LICENSE`, and `README.md`. **Only `xray` is installed.** No Go compiler or other source-build toolchain is needed.

## Testing and memory

The [GitHub Actions workflow](.github/workflows/ci.yml) runs the complete suite. Local checks are limited to syntax checks and targeted tests, not the full slow suite.

- Unit tests run under `sh`, `dash`, `bash`, and BusyBox `sh`; documentation is also checked in a public checkout without local-only working documents.
- Asset jobs check amd64 and arm64 artifacts. Lifecycle jobs exercise the specific systems listed under [Supported targets](#supported-targets).
- Protocol tests cover authenticated SOCKS5/HTTP, rejected unsupported requests, destination boundaries, IPv4/hostname/available IPv6 targets, long-lived traffic, and idle/resume. IPv6 destination coverage does not imply an IPv6 server listener.
- The 1/32/128-concurrency gate synchronizes connections and uses the independent target's observations during traffic, not just submitted task counts. Unsolicited server frames are checked for payload, sequence, and ongoing progress.
- The systemd memory job records RSS snapshots, cgroup usage and separate stage peaks, OOM counters, and restart count. A persistent `memory.peak` descriptor and a high-then-low workload validate the reset semantics on the actual kernel.

**No memory budget or throughput guarantee is published.** Memory evidence must be read with its version, platform, configuration, connection count, duration, and CI run. systemd state-transition timing is not listener-readiness timing; archive size is not RSS.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| A required command is missing | Install the named runtime tool; for archive inspection, use Info-ZIP with `unzip -Z` support. |
| The local install succeeds but remote clients cannot connect | Check the advertised address, chosen TCP port, host/cloud firewall, and any NAT or forwarding. |
| `SERVER_IPV4` appears in the card | Use a reachable IPv4 explicitly or replace the placeholder in the client configuration. |
| `show` refuses to print | Run as root with stdout attached to a real terminal, not a pipe or redirected file. |
| State/config integrity or pending recovery is reported | Review the reported files and preserve recovery copies; do not delete state or backups merely to bypass validation. |

For service diagnostics, use `systemctl status xray-socks5.service` on systemd, or `rc-service xray-socks5 status` on OpenRC. Redact sensitive data before sharing diagnostic output.

## License

[MIT](LICENSE).
