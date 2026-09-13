# Xray-only mixed proxy

**English** | [简体中文](README.zh-CN.md)

[![CI — xray-only](https://github.com/91sexboy/One-click-socks5-proxy-setup/actions/workflows/ci.yml/badge.svg?branch=xray-only)](https://github.com/91sexboy/One-click-socks5-proxy-setup)

A single-file POSIX shell installer for an authenticated **SOCKS5 + HTTP proxy** on a Linux server you own or are authorised to administer.

**One Xray process. One TCP port. One account.** No web panel, database, subscription service, or source build.

> **Authentication is not encryption.** The client–proxy connection carries credentials without transport encryption. Use a trusted network or a separately configured encrypted tunnel; this installer does not set one up.

[Install](#quick-install) · [Commands](#commands) · [Supported systems](#supported-targets) · [Troubleshooting](#troubleshooting)

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
