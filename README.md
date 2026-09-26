# One-click Xray SOCKS5 + HTTP Proxy Installer for Linux

**English** | [简体中文](README.zh-CN.md)

[![CI — xray-only](https://github.com/91sexboy/One-click-socks5-proxy-setup/actions/workflows/ci.yml/badge.svg?branch=xray-only)](https://github.com/91sexboy/One-click-socks5-proxy-setup)

Deploy an authenticated **SOCKS5 + HTTP CONNECT proxy** on Ubuntu, Debian, CentOS Stream, or Alpine Linux with one POSIX shell command. A single-file installer for a Linux server you own or are authorised to administer.

**One Xray process. One TCP port. One account.** No web panel, database, subscription service, or source build.

- SOCKS5 and HTTP proxy on a single TCP port
- Username/password authentication (SOCKS5 RFC 1929 and HTTP Basic)
- Ubuntu, Debian, CentOS Stream, and Alpine Linux
- amd64 and arm64
- systemd and OpenRC
- `install`, `status`, `show`, `restart`, and `uninstall` commands
- CI-tested installation and service-lifecycle management
- Pinned Xray release assets verified with SHA-256

> **Authentication is not encryption.** The client–proxy connection carries credentials without transport encryption. Use a trusted network or a separately configured encrypted tunnel; this installer does not set one up.

[Install](#quick-install) · [Commands](#commands) · [Supported systems](#supported-targets) · [FAQ](#frequently-asked-questions) · [Troubleshooting](#troubleshooting)

## Quick install

### 1. Prepare the server

- Use a **root shell** and a working native service manager from the [supported systems](#supported-targets) table.
- Ensure the server can reach GitHub to download the installer and the pinned Xray release.
- On systemd-based systems, prepare the runtime tools first: `curl` at `/usr/bin/curl`, CA certificates, the distribution Info-ZIP package providing `/usr/bin/unzip` with `-Z` support, `file` at `/usr/bin/file`, `sha256sum` at `/usr/bin/sha256sum` (coreutils, normally already present), Python 3, `ss`, and the standard account-management tools. Those four transport/verification tools are invoked by absolute path, so a copy installed elsewhere is reported as missing. Missing commands are reported by the installer.
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

Xray `v26.3.27` is downloaded from [this repository's Release mirror](https://github.com/91sexboy/One-click-socks5-proxy-setup/releases/tag/xray-v26.3.27): unchanged official ZIPs, about **21.14 MB on amd64** or **19.72 MB on arm64**. Both archive and executable sizes and SHA-256 values are verified; there is no fallback to another download source.

After installation and verification succeed, the installer removes its own downloaded ZIP and temporary extracted copy. The installed executable remains at `/usr/local/libexec/xray-socks5/xray` (about 36.58 MB on amd64 or 34.21 MB on arm64). It does not sweep old temporary directories or recovery backups; forced termination or power loss can leave temporary files.

### 3. Choose language and credentials

On the first invocation without a saved language, choose `1` or Enter for Chinese, or `2` for English. Confirm installation, then enter the port, username, and password.

| Input | Press Enter | Manual value |
| --- | --- | --- |
| Port | Random `20000–60000` | Decimal `1024–65535`, without leading zeros |
| Username | 12 random characters | 3–32 ASCII letters, digits, `_`, `-` |
| Password | 32 random characters | 12–128 ASCII letters, digits, `.`, `_`, `~`, `-` |

**The password is visible while you type it.** The table describes a fresh install. During an update, a blank port keeps the current port only after its listener is verified as belonging to this installation; an explicit port uses the normal free-or-owned checks. Blank username and password answers generate new values.

After successful installation and verification, a real terminal displays both connection links automatically. Redirected output hides credentials; use `show` later from a terminal.

## Supported targets

| System | Accepted versions | Architecture | Service manager |
| --- | --- | --- | --- |
| Ubuntu | 20.04 | amd64 | systemd |
| Ubuntu | 22.04+ | amd64, arm64 | systemd |
| Debian | 12+ | amd64, arm64 | systemd |
| CentOS Stream | 9+ | amd64, arm64 | systemd |
| Alpine Linux | 3.20+ | amd64, arm64 | OpenRC |

`x86_64` maps to `amd64`; `aarch64` maps to `arm64`. Other distribution IDs and architectures are rejected rather than assumed compatible.

**Accepted does not mean lifecycle-tested.** CI exercises installation, configuration update, restart, crash recovery, protocol checks, and uninstall on **Ubuntu 24.04 amd64** and **Alpine 3.20 / 3.22 / 3.24 amd64**. Arm64 has asset and executable verification plus Ubuntu 24.04 memory comparisons, not a full service-lifecycle job. Other accepted systems remain lifecycle-unverified.

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

An installation made by an older supported script release remains available to `status`, `show`, `restart`, update, and uninstall after this script's release pins change. `status` reports the installed release, not the current download candidate. Recorded metadata verifies the installed binary; an update independently verifies the current pinned download.

Re-running `install` updates the managed configuration and, when the installed artifact is older, replaces it with this script's independently verified pinned Xray release. It never follows an unpinned “latest” channel. On update, pressing Enter for the port keeps the verified currently owned port; pressing Enter for the username or password generates a new value. New-install confirmation defaults to yes; update and uninstall default to no.

The language preference is saved in `/etc/xray-socks5.lang` and survives uninstall. If it cannot be saved, the script warns that the choice applies only to the current invocation. The `language` command reports failure if saving fails.

`status` can report a stopped or unverified listener without failing as a command. Read its output; a zero exit status alone does not prove proxy availability.

## What `mixed` means

Xray-core's `protocol: mixed` inbound accepts two client protocols on the same listening port:

| Client protocol | Authentication | Use |
| --- | --- | --- |
| SOCKS5 | RFC 1929 username/password | TCP CONNECT |
| HTTP proxy | Basic username/password | HTTP CONNECT |

The client chooses which protocol to speak. This is **not a pure SOCKS5 listener**: the same endpoint also accepts authenticated HTTP proxy clients. UDP is disabled (`udp: false`).

The installer binds IPv4 `0.0.0.0` on the selected port and runs Xray under the dedicated, non-login `xray-socks5` account. There is one direct outbound and one blackhole outbound for the destination boundary.

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

## Measured memory

Historical evidence: Xray `v26.3.27`, Ubuntu 24.04, kernel `6.17.0-1022-azure`, and the installer's default authenticated TCP-only `mixed` configuration at [commit `9271644`](https://github.com/91sexboy/One-click-socks5-proxy-setup/commit/9271644340d2332725d0c83e818711481486668f). [CI run `34800667931`](https://github.com/91sexboy/One-click-socks5-proxy-setup/actions/runs/34800667931) produced the [amd64 measurements](https://github.com/91sexboy/One-click-socks5-proxy-setup/actions/runs/34800667931/job/103842545297) and [arm64 measurements](https://github.com/91sexboy/One-click-socks5-proxy-setup/actions/runs/34800667931/job/103842545245).

These are **instantaneous RSS snapshots** after establishing authenticated tunnels to a local test target; 0 means idle. The phase cgroup peak covers reset-to-sample, including connection establishment. This is **not a 60-second load test**: 60 seconds is the connection holder's timeout, not a measurement window.

| Architecture | Held connections | RSS (KiB) | Phase cgroup peak (bytes) |
| --- | ---: | ---: | ---: |
| amd64 | 0 | 35896 | 11710464 |
| amd64 | 1 | 35912 | 11972608 |
| amd64 | 32 | 36424 | 13283328 |
| amd64 | 128 | 40876 | 19304448 |
| arm64 | 0 | 29460 | 6348800 |
| arm64 | 1 | 29520 | 6348800 |
| arm64 | 32 | 30928 | 8183808 |
| arm64 | 128 | 35324 | 14200832 |

The sampler starts **after installation**; these are **not isolated startup RSS peaks**. `xray_startup_usec=0` in these logs is a systemd state-transition timestamp delta, not zero startup time or listener-readiness time. The later systemd `MemoryPeak` is a lifetime cgroup peak, not an isolated startup measurement. RSS and cgroup accounting differ: shared/file-backed pages can make cgroup usage smaller than RSS; do not add the two metrics. The target and load driver stay **outside the Xray cgroup**. Both jobs recorded zero service restarts and zero cgroup OOM events during this measurement.

A separate experiment in the same jobs compares three pairs of the default profile and a 4-KiB buffer candidate: each trial has a five-second warmup, then 30-second stage windows sampled at one-second intervals, including 32-connection duplex and slow-reader workloads. Those windows do **not** describe the snapshots above. Artifacts `memory-comparison-amd64` and `memory-comparison-arm64` retain the detailed results for **14 days**; links may stop serving artifacts after expiry. The candidate was ineligible on both architectures (`no-demonstrated-benefit` on amd64; `regression` on arm64). Successful CI does not mean the candidate qualified for production; the default configuration remains unchanged.

These observations are **not a minimum-memory guarantee** for a whole server or other workloads. No hard `MemoryMax` or universal 128/256-MiB deployment budget is inferred from them; allow for the OS, other services, traffic patterns, and unmeasured startup peaks.

## Frequently asked questions

### How do I install a SOCKS5 proxy on Ubuntu 24.04?

Follow [Quick install](#quick-install): from a root shell, download `socks5.sh` and run it. Ubuntu 24.04 amd64 is one of the lifecycle-tested targets, and it uses systemd.

### How do I set up an authenticated SOCKS5 server on Debian 12?

The same one command works on Debian 12+. The installer prompts for a port, username, and password (or generates them on Enter), so every install has SOCKS5 username/password authentication by default.

### Can SOCKS5 and HTTP proxy clients share the same port?

Yes. Xray's `mixed` inbound accepts both SOCKS5 and HTTP CONNECT clients on the one TCP port the installer opens. Each client chooses which protocol to speak. See [What `mixed` means](#what-mixed-means).

### Does this SOCKS5 proxy encrypt traffic?

No. Authentication is not encryption. The client–proxy hop carries credentials without transport encryption. Use it on a trusted network or through a separately configured encrypted tunnel.

### Does the proxy support UDP?

No. UDP is disabled (`udp: false`); the inbound handles TCP CONNECT only.

### How do I uninstall the Xray SOCKS5 proxy?

Run `sh socks5.sh uninstall` as root and confirm. It removes the managed installation, the service unit, and the dedicated account. The saved language preference in `/etc/xray-socks5.lang` is kept.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| A required command is missing | Install the named runtime tool; for archive inspection, use Info-ZIP with `unzip -Z` support. |
| The local install succeeds but remote clients cannot connect | Check the advertised address, chosen TCP port, host/cloud firewall, and any NAT or forwarding. |
| `SERVER_IPV4` appears in the card | Use a reachable IPv4 explicitly or replace the placeholder in the client configuration. |
| `show` refuses to print | Run as root with stdout attached to a real terminal, not a pipe or redirected file. |
| State/config integrity or pending recovery is reported | Review the reported files and preserve recovery copies; do not delete state or backups merely to bypass validation. |

For service diagnostics, use `systemctl status xray-socks5.service` on systemd, or `rc-service xray-socks5 status` on OpenRC. Redact sensitive data before sharing diagnostic output.

**For contributors:** `SPEC N` in code and test comments refers to the maintainer's private acceptance specification; the public contract is this README and the [architecture decisions](docs/adr/).

## License

Installer and tests: [MIT](LICENSE). Mirrored Xray-core binaries stay under their upstream MPL-2.0 license — see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
