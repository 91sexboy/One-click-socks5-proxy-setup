# Xray-only 双协议代理

[English](README.md) | **简体中文**

[![CI — xray-only](https://github.com/91sexboy/One-click-socks5-proxy-setup/actions/workflows/ci.yml/badge.svg?branch=xray-only)](https://github.com/91sexboy/One-click-socks5-proxy-setup/actions/workflows/ci.yml)

一个单文件 POSIX shell 安装器，用于在你拥有或获授权管理的 Linux 服务器上部署需要身份认证的 **SOCKS5 + HTTP 代理**。

**一个 Xray 进程、一个 TCP 端口、一组账户。** 不安装 Web 面板、数据库或订阅服务，也不进行源码编译。

> **身份认证不等于加密。** 客户端与代理之间的连接没有传输层加密，认证信息会在这条连接上传输。请使用可信网络或另外配置的加密隧道；本安装器不会替你建立加密隧道。

[安装](#快速安装) · [管理命令](#管理命令) · [支持系统](#支持范围) · [安全边界](#安全边界) · [常见问题](#常见问题)

## `mixed` 是什么

Xray-core 的 `protocol: mixed` 入站在同一个监听端口接受两种客户端协议：

| 客户端协议 | 认证方式 | 用途 |
| --- | --- | --- |
| SOCKS5 | RFC 1929 用户名／密码 | TCP CONNECT |
| HTTP 代理 | Basic 用户名／密码 | HTTP CONNECT |

客户端自行选择使用哪种协议。这**不是纯 SOCKS5 监听器**：同一个地址和端口也接受经过认证的 HTTP 代理客户端。UDP 关闭（`udp: false`）。

安装器在所选端口监听 IPv4 `0.0.0.0`，并以专用、不可登录的 `xray-socks5` 账户运行 Xray。配置包含一个直连出站和一个用于目标边界的黑洞出站。

## 支持范围

| 系统 | 接受的版本 | 架构 | 服务管理器 |
| --- | --- | --- | --- |
| Ubuntu | 20.04 | amd64 | systemd |
| Ubuntu | 22.04+ | amd64、arm64 | systemd |
| Debian | 12+ | amd64、arm64 | systemd |
| CentOS Stream | 9+ | amd64、arm64 | systemd |
| Alpine Linux | 3.20+ | amd64、arm64 | OpenRC |

`x86_64` 对应 `amd64`，`aarch64` 对应 `arm64`。其他发行版标识和架构会被拒绝，不会直接假定兼容。

**安装器接受，不等于完整生命周期已验证。** CI 在 **Ubuntu 24.04 amd64** 和 **Alpine 3.20 / 3.24 amd64** 上验证安装、配置更新、重启、崩溃恢复、协议检查和卸载。Arm64 有发布包和可执行文件验证，没有完整服务生命周期 job；其他被接受的系统也尚无完整生命周期验证。

## 快速安装

### 1. 准备服务器

- 使用 **root shell**，并确保上表中的系统原生服务管理器正常工作。
- 服务器需要能访问 GitHub，以下载安装器和固定版本的 Xray 发布包。
- systemd 系统需要预先准备运行工具：`curl`、CA 证书、支持 `-Z` 的 Info-ZIP `unzip`、`file`、Python 3、`ss` 及常规账户管理工具。缺少命令时，安装器会提示名称。
- Alpine 的运行依赖由安装器通过 `apk` 安装，发生在预检查阶段，**早于安装确认**。下载脚本本身仍需要 `curl`；缺少时可先执行 `apk add --no-cache curl ca-certificates`。
- 根据需要在主机防火墙和云安全组中放行所选 **TCP 端口**。脚本不会配置这些规则，也不会设置 NAT 或端口转发。

### 2. 下载并运行

如需审计 root 权限操作，请先阅读 `socks5.sh`。在你准备保留管理脚本的目录中执行：

```sh
curl -fsSL \
  https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/xray-only/socks5.sh \
  -o socks5.sh &&
sh socks5.sh
```

不带参数时，脚本执行 `install`。

### 3. 选择语言和账户信息

首次运行且没有已保存的语言时，输入 `1` 或直接回车选择中文，输入 `2` 选择英文。确认安装后，依次输入端口、账户名和密码。

| 输入项 | 直接回车 | 手动输入 |
| --- | --- | --- |
| 端口 | 随机选择 `20000–60000` | 十进制 `1024–65535`，不能有前导零 |
| 账户名 | 生成 12 个随机字符 | 3–32 个英文字母、数字、`_`、`-` |
| 密码 | 生成 32 个随机字符 | 12–128 个英文字母、数字、`.`、`_`、`~`、`-` |

**密码输入时可见，不会隐藏回显。** 新安装会拒绝已被占用的端口；更新时只有确认监听器属于本次安装，才允许继续使用原端口。

安装并验证成功后，真实终端会自动显示两种代理的连接链接。输出被重定向时会隐藏凭据，之后可在终端运行 `show` 查看。

## 管理命令

在已下载脚本所在目录运行以下命令。安装和管理操作需要 root。

| 命令 | 用途 |
| --- | --- |
| `sh socks5.sh install` | 安装，或更新已有配置 |
| `sh socks5.sh status` | 查看服务／监听状态、端口、账户名和版本；不显示密码 |
| `sh socks5.sh show` | 显示连接链接；需要 root 和真实终端 |
| `sh socks5.sh restart` | 重启，并重新检查监听和认证行为 |
| `sh socks5.sh uninstall` | 确认后卸载受管安装 |
| `sh socks5.sh language` | 重新选择并保存界面语言 |
| `sh socks5.sh help` | 查看命令用法 |

重复运行 `install` 是**配置更新**，不是升级到最新版 Xray。输入时直接回车会生成新值，不会保留原账户信息或端口。新安装的确认默认同意；更新和卸载的确认默认拒绝。

语言偏好保存在 `/etc/xray-socks5.lang`，卸载代理后仍保留。保存失败时，脚本会提示本次选择只对当前调用有效；`language` 命令会在保存失败时返回失败。

`status` 可以正常执行并报告服务已停止或监听状态无法验证。请阅读输出内容，不能仅凭退出码为零就认定代理可用。

## 连接链接与服务器地址

凭据卡采用以下格式，其中的值均为占位符：

```text
socks5://USERNAME:PASSWORD@SERVER_IPV4:PORT
http://USERNAME:PASSWORD@SERVER_IPV4:PORT
```

这里的 `http://` 表示使用 HTTP 代理，不代表代理连接已经加密。`show` 会拒绝通过管道或重定向后的标准输出显示凭据。

每次生成凭据卡时，按以下顺序确定显示地址：

1. 如果设置了有效、规范的 IPv4 地址 `S5_SERVER_IPV4`，直接使用并跳过自动查询。显式指定的地址可以是供内网使用的私有地址。
2. 向 `icanhazip.com` 发出一次有时限的 HTTPS 请求，只接受经过严格校验的公网 IPv4 响应。该请求忽略代理环境变量，不跟随重定向。
3. 没有可用地址时，显示 `SERVER_IPV4` 并给出警告。请将其替换为客户端能够访问的地址。

为单次调用指定地址：

```sh
S5_SERVER_IPV4=203.0.113.10 sh socks5.sh show
```

请将示例地址替换为自己的地址。这**只改变链接中显示的地址**，不会修改监听地址或防火墙。无效的覆盖值会回退到自动查询。查询到公网地址，也不代表该端口一定能从互联网访问。

## 安全边界

- **客户端到代理的连接需要另行保护。** SOCKS5 密码认证和 HTTP Basic 认证都不加密这条连接。通过代理访问 HTTPS 网站，也不会加密之前的代理认证过程。
- 请将访问范围限制在预期客户端。知道凭据且能连接该端口的人都可以使用代理，出口流量来自你的服务器。
- 配置阻断[十二个明确的目标网段](tests/fixtures/denied-destinations.txt)，包括回环、列表中的私网／CGNAT 网段、链路本地地址（例如云元数据地址 `169.254.169.254`）以及其他列出的特殊网段。`IPIfNonMatch` 也会对域名解析后的目标地址应用边界；这不等于阻断所有非公网地址。
- 自动查询所得地址的校验，与代理目标网段阻断是两种不同策略。它们都不能替代主机防火墙或云网络策略。
- 密码以明文保存在受保护的配置和恢复副本中。不要公开凭据卡、配置文件或备份内容。状态文件记录账户名和完整性元数据，不保存密码。
- 生成的配置没有面板、API、订阅服务、GeoIP／GeoSite 数据库、TLS、REALITY、WebSocket、gRPC 或 XHTTP 传输。本项目不是 VPN，也不是 UDP 中继。

## 生命周期

候选配置必须先通过以下检查，才能发布：

```sh
xray run -test -c /path/to/candidate.json
```

该命令只验证配置，不绑定端口。之后安装器才原子发布配置、启动 Xray、确认监听器归属、检查两种协议的认证行为，并使用一个活跃的本地对照目标检查访问拒绝。成功的代理数据传输由 CI 验证，不由服务器上的安装器验证。

- **更新会重启服务。** 已有连接会断开。未通过配置测试的候选不会替换正式配置，也不会停止健康服务。
- **恢复失败时保留证据。** 发布后失败会尝试恢复旧配置和状态，再重启服务。如果恢复失败，副本保留在 `/var/lib/xray-socks5/transaction/`。后续更新会拒绝覆盖这个待恢复目录，失败重试也不会删除上次的备份。
- **管理操作检查归属和完整性。** 文件摘要和账户身份必须与记录一致。手动修改受管配置可能导致正常管理命令拒绝继续，请使用支持的配置更新流程。
- **卸载采用保守策略。** 在停止服务、删除受管文件和账户前，先拒绝未知或不安全的目录条目。运行依赖包、防火墙设置及语言偏好会保留。
- **使用系统原生服务管理器。** systemd 使用 `Restart=on-failure` 和 `RestartPreventExitStatus=23`；OpenRC 使用限制重启次数的 `supervise-daemon`，不是 systemd 按退出码控制重启的机制。

管理操作使用操作锁。这些保护不承诺可以恢复所有存储故障或任意外部文件系统修改。

## 文件和权限

| 资源 | 路径 | 所有者和权限 |
| --- | --- | --- |
| Xray 可执行文件 | `/usr/local/libexec/xray-socks5/xray` | `root:root 0755` |
| 配置目录 | `/etc/xray-socks5/` | `root:xray-socks5 0750` |
| 配置文件 | `/etc/xray-socks5/config.json` | `root:xray-socks5 0640` |
| 状态文件 | `/var/lib/xray-socks5/state` | `root:root 0600` |
| systemd 服务 | `/etc/systemd/system/xray-socks5.service` | `root:root 0644` |
| OpenRC 服务 | `/etc/init.d/xray-socks5` | `root:root 0755` |
| 语言偏好 | `/etc/xray-socks5.lang` | `root:root 0644` |
| 恢复目录 | `/var/lib/xray-socks5/transaction/` | `root:root 0700`；备份文件为 `0600` |

只安装当前后端对应的服务定义文件。临时操作锁位于 `/run/xray-socks5.lock`。Xray 使用专用的 `xray-socks5` 用户和组运行，不以 root 运行。

本安装不会采用或删除旧 3proxy 路线中的 `socks5-manager` 路径或 `socks5proxy` 账户。

## 固定 Xray 版本和发布包

安装器使用官方 Xray-core [v26.3.27 发布版本](https://github.com/XTLS/Xray-core/releases/tag/v26.3.27)，不是 `latest`、开发构建，也不是从本仓库的 Releases 页面下载引擎。

上游 tag 对应提交：`d2758a023cd7f4174a5a5fa4ff66e487d4342ba0`。

| 架构 | 官方发布包 | 发布包字节数 | 提取后二进制字节数 |
| --- | --- | ---: | ---: |
| amd64 | `Xray-linux-64.zip` | 21136402 | 36577406 |
| arm64 | `Xray-linux-arm64-v8a.zip` | 19716427 | 34209918 |

<details>
<summary>SHA-256 校验值</summary>

```text
amd64 发布包
23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae
amd64 二进制
8255dd939c34cf966cc91517b6324dd3c8d0bcf49ffac8beca049a38c46845ed

arm64 发布包
4d30283ae614e3057f730f67cd088a42be6fdf91f8639d82cb69e48cde80413c
arm64 二进制
c2d20a7045250497083afea0d79db0672f6c89a25aaaf37c92de034d6b764b04
```

</details>

安装器校验发布包的大小、摘要、成员名称和类型，以及提取后二进制的大小、摘要和 ELF 架构。包内必须恰好包含 `xray`、`geoip.dat`、`geosite.dat`、`LICENSE` 和 `README.md`，但**只安装 `xray`**，不需要 Go 编译器或其他源码构建工具。

## 测试和内存

[GitHub Actions 工作流](.github/workflows/ci.yml) 运行完整测试。本地只进行语法检查和针对性测试，不运行完整慢速套件。

- 单元测试覆盖 `sh`、`dash`、`bash` 和 BusyBox `sh`；文档还会在不含本地专用工作文档的公开检出副本中检查。
- 发布包验证覆盖 amd64 和 arm64，生命周期测试覆盖[支持范围](#支持范围)中明确列出的测试环境。
- 协议测试覆盖 SOCKS5／HTTP 认证、不支持请求的拒绝、目标边界、IPv4／域名／可用 IPv6 目标、长连接和空闲后恢复。验证 IPv6 目标，不代表提供 IPv6 服务端监听。
- 1/32/128 并发门禁会同步连接，并使用独立目标在传输期间的观察结果，不仅仅统计提交的任务数。服务端主动帧会检查载荷、序号和持续进展。
- systemd 内存 job 记录 RSS 快照、cgroup 用量和各阶段峰值、OOM 计数及重启次数。常驻的 `memory.peak` 文件描述符与先高后低负载实验，用于验证实际内核的重置语义。

**不公布未经支持的内存预算或吞吐量保证。** 内存证据需要结合版本、平台、配置、连接数、持续时间和 CI run 解读。systemd 状态切换耗时不是监听就绪耗时，发布包大小也不是 RSS。

## 常见问题

| 现象 | 检查方向 |
| --- | --- |
| 提示缺少必要命令 | 安装提示中的运行工具；发布包检查需要支持 `unzip -Z` 的 Info-ZIP。 |
| 本地安装成功，远端客户端连接失败 | 检查显示地址、所选 TCP 端口、主机／云防火墙，以及 NAT 或端口转发。 |
| 凭据卡显示 `SERVER_IPV4` | 显式指定可达的 IPv4，或在客户端配置中替换占位符。 |
| `show` 拒绝显示 | 以 root 在真实终端中运行，不要使用管道或重定向输出。 |
| 提示状态／配置完整性异常或待恢复目录 | 检查提示中的文件并保留恢复副本，不要为了绕过校验而直接删除状态或备份。 |

服务诊断可使用 systemd 的 `systemctl status xray-socks5.service`，或 OpenRC 的 `rc-service xray-socks5 status`。分享诊断输出前，请先移除敏感信息。

## 许可证

[MIT](LICENSE)。
