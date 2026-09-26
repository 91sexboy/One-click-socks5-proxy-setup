# Linux 一键搭建 SOCKS5 + HTTP 代理（Xray）

[English](README.md) | **简体中文**

[![CI — xray-only](https://github.com/91sexboy/One-click-socks5-proxy-setup/actions/workflows/ci.yml/badge.svg?branch=xray-only)](https://github.com/91sexboy/One-click-socks5-proxy-setup)

使用一个 POSIX shell 脚本，在 Ubuntu、Debian、CentOS Stream 或 Alpine Linux 服务器上一键部署带用户名密码认证的 **SOCKS5 与 HTTP CONNECT 代理**。适用于你拥有或获授权管理的 Linux 服务器。

**一个 Xray 进程、一个 TCP 端口、一组账户。** 不安装 Web 面板、数据库或订阅服务，也不进行源码编译。

- SOCKS5 与 HTTP 代理共用一个 TCP 端口
- 用户名／密码认证（SOCKS5 RFC 1929 与 HTTP Basic）
- Ubuntu、Debian、CentOS Stream 和 Alpine Linux
- amd64 与 arm64
- systemd 与 OpenRC
- `install`、`status`、`show`、`restart`、`uninstall` 管理命令
- CI 验证的安装与服务生命周期管理
- 固定版本的 Xray 发布包，使用 SHA-256 校验

> **身份认证不等于加密。** 客户端与代理之间的连接没有传输层加密，认证信息会在这条连接上传输。请使用可信网络或另外配置的加密隧道；本安装器不会替你建立加密隧道。

[安装](#快速安装) · [管理命令](#管理命令) · [支持系统](#支持范围) · [常见问题](#常见问题) · [故障排查](#故障排查)

## 快速安装

### 1. 准备服务器

- 使用 **root shell**，并确保[支持范围](#支持范围)表中的系统原生服务管理器正常工作。
- 服务器需要能访问 GitHub，以下载安装器和固定版本的 Xray 发布包。
- systemd 系统需要预先准备运行工具：位于 `/usr/bin/curl` 的 `curl`、CA 证书、提供 `/usr/bin/unzip` 且支持 `-Z` 的发行版 Info-ZIP 软件包、位于 `/usr/bin/file` 的 `file`、位于 `/usr/bin/sha256sum` 的 `sha256sum`（coreutils，通常已安装）、Python 3、`ss` 及常规账户管理工具。这四个传输／校验工具按绝对路径调用，安装在其他位置的副本会被视为缺失。缺少命令时，安装器会提示名称。
- Alpine 的运行依赖由安装器通过 `apk` 安装，发生在预检查阶段，**早于安装确认**。下载脚本本身仍需要 `curl`；缺少时可先执行 `apk add --no-cache curl ca-certificates`。
- 在 `/var/tmp`（或 `/tmp`）与 `/usr/local` 所在文件系统上预留约 **90 MiB** 可用空间：固定版本压缩包、从中解出的可执行文件，以及最终发布的副本会同时存在。安装器在下载前先测量空间，并报告所需与剩余字节，因此有磁盘配额的容器会被明确告知需求，而不是中途失败。
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

Xray `v26.3.27` 从[本仓库的 Release 镜像](https://github.com/91sexboy/One-click-socks5-proxy-setup/releases/tag/xray-v26.3.27)下载，原样保留官方 ZIP：**amd64 约 21.14 MB，arm64 约 19.72 MB**。压缩包和程序各自的大小与 SHA-256 都会校验，不会回退到其他下载源。

安装并验证成功后，会删除本次下载的 ZIP 和临时解压副本；正式程序保留在 `/usr/local/libexec/xray-socks5/xray`（amd64 约 36.58 MB，arm64 约 34.21 MB）。不会批量清理历史临时目录或恢复备份；强制终止、掉电仍可能留下临时文件。

### 3. 选择语言和账户信息

首次运行且没有已保存的语言时，输入 `1` 或直接回车选择中文，输入 `2` 选择英文。确认安装后，依次输入端口、账户名和密码。

| 输入项 | 直接回车 | 手动输入 |
| --- | --- | --- |
| 端口 | 随机选择 `20000–60000` | 十进制 `1024–65535`，不能有前导零 |
| 账户名 | 生成 12 个随机字符 | 3–32 个英文字母、数字、`_`、`-` |
| 密码 | 生成 32 个随机字符 | 12–128 个英文字母、数字、`.`、`_`、`~`、`-` |

**密码输入时可见，不会隐藏回显。** 表格描述的是新安装。更新时端口留空，仅在确认当前监听器属于本次安装后保留原端口；显式输入端口仍执行正常的空闲或归属检查。账户名或密码留空会生成新值。

安装并验证成功后，真实终端会自动显示两种代理的连接链接。输出被重定向时会隐藏凭据，之后可在终端运行 `show` 查看。

## 支持范围

| 系统 | 接受的版本 | 架构 | 服务管理器 |
| --- | --- | --- | --- |
| Ubuntu | 20.04 | amd64 | systemd |
| Ubuntu | 22.04+ | amd64、arm64 | systemd |
| Debian | 12+ | amd64、arm64 | systemd |
| CentOS Stream | 9+ | amd64、arm64 | systemd |
| Alpine Linux | 3.20+ | amd64、arm64 | OpenRC |

`x86_64` 对应 `amd64`，`aarch64` 对应 `arm64`。其他发行版标识和架构会被拒绝，不会直接假定兼容。

**安装器接受，不等于完整生命周期已验证。** CI 在 **Ubuntu 24.04 amd64** 和 **Alpine 3.20 / 3.22 / 3.24 amd64** 上验证安装、配置更新、重启、崩溃恢复、协议检查和卸载。Arm64 有发布包、可执行文件验证和 Ubuntu 24.04 内存对比，没有完整服务生命周期 job；其他被接受的系统也尚无完整生命周期验证。

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

旧版受支持脚本创建的安装，在当前脚本更新发布版本 pin 后仍可执行 `status`、`show`、`restart`、配置更新和卸载。`status` 报告的是已安装版本，而不是当前下载候选版本。state 中的历史元数据只校验已安装程序；更新下载仍独立校验当前 pin。

重复运行 `install` 会更新受管配置；如果已安装程序较旧，还会替换为当前脚本独立校验并固定版本的 Xray，但绝不会跟随未固定的“最新版”通道。更新时端口直接回车会保留已经验证归属的当前端口；账户名或密码直接回车会生成新值。新安装的确认默认同意；更新和卸载的确认默认拒绝。

语言偏好保存在 `/etc/xray-socks5.lang`，卸载代理后仍保留。保存失败时，脚本会提示本次选择只对当前调用有效；`language` 命令会在保存失败时返回失败。

`status` 可以正常执行并报告服务已停止或监听状态无法验证。请阅读输出内容，不能仅凭退出码为零就认定代理可用。

## `mixed` 是什么

Xray-core 的 `protocol: mixed` 入站在同一个监听端口接受两种客户端协议：

| 客户端协议 | 认证方式 | 用途 |
| --- | --- | --- |
| SOCKS5 | RFC 1929 用户名／密码 | TCP CONNECT |
| HTTP 代理 | Basic 用户名／密码 | HTTP CONNECT |

客户端自行选择使用哪种协议。这**不是纯 SOCKS5 监听器**：同一个地址和端口也接受经过认证的 HTTP 代理客户端。UDP 关闭（`udp: false`）。

安装器在所选端口监听 IPv4 `0.0.0.0`，并以专用、不可登录的 `xray-socks5` 账户运行 Xray。配置包含一个直连出站和一个用于目标边界的黑洞出站。

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

## 内存实测

历史证据：Xray `v26.3.27`、Ubuntu 24.04、内核 `6.17.0-1022-azure`，使用[提交 `9271644`](https://github.com/91sexboy/One-click-socks5-proxy-setup/commit/9271644340d2332725d0c83e818711481486668f)中的安装器默认配置：需要认证、仅 TCP 的 `mixed` 代理。[CI run `34800667931`](https://github.com/91sexboy/One-click-socks5-proxy-setup/actions/runs/34800667931)提供了 [amd64 测量](https://github.com/91sexboy/One-click-socks5-proxy-setup/actions/runs/34800667931/job/103842545297)和 [arm64 测量](https://github.com/91sexboy/One-click-socks5-proxy-setup/actions/runs/34800667931/job/103842545245)。

以下是向本地测试目标建立已认证隧道后的**瞬时 RSS 快照**，0 表示空闲。阶段 cgroup 峰值覆盖从重置到采样的区间，包含连接建立过程。这**不是持续 60 秒的负载测试**：60 秒只是保持连接程序的超时上限，不是测量窗口。

| 架构 | 保持连接数 | RSS (KiB) | 阶段 cgroup 峰值 (bytes) |
| --- | ---: | ---: | ---: |
| amd64 | 0 | 35896 | 11710464 |
| amd64 | 1 | 35912 | 11972608 |
| amd64 | 32 | 36424 | 13283328 |
| amd64 | 128 | 40876 | 19304448 |
| arm64 | 0 | 29460 | 6348800 |
| arm64 | 1 | 29520 | 6348800 |
| arm64 | 32 | 30928 | 8183808 |
| arm64 | 128 | 35324 | 14200832 |

采样器在**安装完成后**启动，因此这些值**不是独立启动 RSS 峰值**。日志中的 `xray_startup_usec=0` 是 systemd 状态转换时间戳之差，不代表零启动耗时或监听就绪耗时。随后记录的 systemd `MemoryPeak` 是生命周期 cgroup 峰值，不是独立启动测量。RSS 与 cgroup 的计费口径不同，共享页／文件映射页可能使 cgroup 用量小于 RSS；不能将两者相加。目标程序和负载驱动**位于 Xray cgroup 之外**。两种架构在这段测量中的服务重启次数和 cgroup OOM 事件均为零。

同一组 job 还单独进行了三轮配对实验，对比默认配置与 4-KiB 缓冲候选配置：每次试验先预热五秒，再对各阶段以一秒间隔采样 30 秒，包含 32 连接双向传输及慢读取负载。这些时间窗口**不适用于**上表快照。`memory-comparison-amd64` 和 `memory-comparison-arm64` 制品保留详细结果 **14 天**，过期后链接可能无法下载制品。候选配置在两种架构上均未达到采用门槛：amd64 为 `no-demonstrated-benefit`，arm64 为 `regression`。CI 成功不代表候选配置适合生产；默认配置保持不变。

这些数据**不是最低内存保证**，不能直接套用到整台服务器或其他负载。本项目不据此设置硬 `MemoryMax`，也不承诺通用的 128/256-MiB 部署预算；还需为操作系统、其他服务、不同流量模式及未单独测量的启动峰值留出空间。

## 常见问题

### 如何在 Ubuntu 24.04 一键搭建 SOCKS5 代理？

按[快速安装](#快速安装)操作：在 root shell 中下载 `socks5.sh` 并运行。Ubuntu 24.04 amd64 是完整生命周期已验证的目标之一，使用 systemd。

### 如何在 Debian 12 搭建带用户名密码的 SOCKS5 服务器？

同一条命令在 Debian 12+ 上同样适用。安装器会提示输入端口、账户名和密码（直接回车则随机生成），因此每次安装默认都带 SOCKS5 用户名／密码认证。

### SOCKS5 和 HTTP 代理能否共用一个端口？

可以。Xray 的 `mixed` 入站在安装器打开的同一个 TCP 端口上同时接受 SOCKS5 和 HTTP CONNECT 客户端，由客户端自行选择协议。详见 [`mixed` 是什么](#mixed-是什么)。

### SOCKS5 代理是否会加密流量？

不会。身份认证不等于加密，客户端到代理这一跳没有传输层加密。请在可信网络中使用，或通过另外配置的加密隧道使用。

### 代理是否支持 UDP？

不支持。UDP 已关闭（`udp: false`），入站只处理 TCP CONNECT。

### 如何卸载 Xray SOCKS5 代理？

以 root 运行 `sh socks5.sh uninstall` 并确认。它会移除受管安装、服务单元和专用账户；保存在 `/etc/xray-socks5.lang` 的语言偏好会保留。

## 故障排查

| 现象 | 检查方向 |
| --- | --- |
| 提示缺少必要命令 | 安装提示中的运行工具；发布包检查需要支持 `unzip -Z` 的 Info-ZIP。 |
| 提示空间不足，或文件未能写完 | 在提示指出的文件系统上释放空间，或提高容器磁盘配额。安装器会报告所需与可用字节，大小不符时也会报告实际观测到的字节，因此磁盘写满不会被当成发布包本身有问题。 |
| 本地安装成功，远端客户端连接失败 | 检查显示地址、所选 TCP 端口、主机／云防火墙，以及 NAT 或端口转发。 |
| 凭据卡显示 `SERVER_IPV4` | 显式指定可达的 IPv4，或在客户端配置中替换占位符。 |
| `show` 拒绝显示 | 以 root 在真实终端中运行，不要使用管道或重定向输出。 |
| 提示状态／配置完整性异常或待恢复目录 | 检查提示中的文件并保留恢复副本，不要为了绕过校验而直接删除状态或备份。 |

服务诊断可使用 systemd 的 `systemctl status xray-socks5.service`，或 OpenRC 的 `rc-service xray-socks5 status`。分享诊断输出前，请先移除敏感信息。

**开发者说明：** 代码和测试注释中的 `SPEC N` 指维护者的私有验收规格；公开契约以本 README 和[架构决策](docs/adr/)为准。

## 许可证

安装器和测试采用 [MIT](LICENSE)；镜像的 Xray-core 程序保留上游 MPL-2.0 许可证，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
