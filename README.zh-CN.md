# socks5.sh

[English](README.md) | [简体中文](README.zh-CN.md)

一个用于在你拥有或获授权管理的服务器上安装和管理**密码认证 SOCKS5
代理**的单文件 POSIX shell 脚本。

它会安装固定版本的 3proxy 0.9.9.0 二进制文件，按大小和 SHA-256 校验，
创建受限服务账户，启动服务，并验证正确凭据可用、错误凭据被拒绝。目标主机
不会进行本地编译。

> **SOCKS5 不是 VPN。认证信息会在网络上明文传输。** 将代理暴露到公网前，
> 请先阅读[安全说明](#安全说明)。

原始 `develop/socks5.sh` URL 是会移动的开发通道。已发布的版本 tag 按项目的
never-move 发布政策作为稳定安装通道。GitHub 当前没有强制 tag immutable；运行 tag
中的脚本前，请核对文档给出的 SHA-256。

<!-- section: alpine -->
## Alpine Linux 部署

Alpine Linux 放在最前面，是因为其默认 shell 会直接影响一键安装命令的写法。

### 要求与精确验证范围

- 请在 Alpine Linux 3.20 或更新版本的 **root shell** 中运行。
- 支持架构：`x86_64` / `amd64` 和 `aarch64` / `arm64`。
- 版本规则是最低版本门槛：更高版本沿用同一接受路径，但当前精确 CI 证据只覆盖
  Alpine 3.20 和 3.24。
- Alpine 使用 OpenRC。

### 原生 Alpine 一键安装

先安装 Bash，然后明确让 Bash 解析进程替换：

```sh
apk add --no-cache bash wget && bash -c 'bash <(wget -qO- https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/develop/socks5.sh)'
```

原生 Alpine 默认进入 BusyBox `ash`。进程替换支持取决于 BusyBox build 和
`/dev/fd`；本项目刻意不依赖这种 build-specific compatibility。加引号的 `bash -c`
参数会在 Bash 安装后确保由 Bash 解析命令字符串。

不要改成 `wget ... | sh`。安装器需要交互输入，管道会占用向导的 stdin，导致
提示无法正常读取。Bash 只用于一行式进程替换启动；保存到磁盘的安装脚本可直接
用 POSIX `sh` 运行。

### Alpine 会安装什么

启动命令明确安装 `bash` 和 `wget`。它们是启动工具，不属于安装器的运行时依赖集。

默认确认问题通过后，安装器只用 `apk add --no-cache` 安装真正缺失的运行时包：

- 缺少 `curl` 时安装，用于下载已验证 engine 和执行认证自检；
- 没有受支持的 CA bundle 时安装 `ca-certificates`；
- 只有当 `/proc/net/tcp{,6}`、`ss` 和 `netstat` 都无法提供可用监听状态时，
  才安装 `iproute2`。

只有在确认之后，安装器才会安装列出的缺失运行时依赖。
在这一步完成前，不会收集端口、用户名或密码。

目标主机不会获得 Git、Make、GCC、headers、Python 或源码 checkout，也不会编译
3proxy，没有本地构建 fallback。卸载时运行时包会保留，因为脚本无法判断其他软件
是否依赖它们。

### Alpine engine 资产

Alpine 从版本化 release `engine-3proxy-0.9.9.0-r1` 中选择 **musl** 资产；
它们来自固定 commit `da99424eac4092e3722f1a5b1844cfe80478f580`：

| 架构 | 资产族 | 内嵌大小 | 内嵌 SHA-256 |
|---|---|---:|---|
| `amd64` | musl amd64 | 298280 bytes | `ac3fe1a7d52d2b1494d4d00884fc7517acb2340454c2653c95a7346c05d69298` |
| `arm64` | musl arm64 | 277624 bytes | `38f2733dfc5d375a4faaebe79f66bd181c7cc3e7b3eb9443c3ac4476fbfeebeb` |

下载只允许 HTTPS 跳转，并限制总字节数；安装前必须同时匹配内嵌大小和 embedded
SHA-256，安装后再次计算 hash。任何不一致都会 fail closed。

### 完成 Alpine 安装向导

安装器按以下顺序提出五个问题：

1. **语言** — `1 中文 / 2 English`。按 Enter 默认中文；不支持的输入会被拒绝并
   重新询问。每次运行的第一个问题都是语言，选择不会保存。
2. **确认** — 先展示检测到的系统、包管理器、init、缺失运行时包和安全警告。
   全新安装只有一个默认 yes 的 `[Y/n]` 确认。
3. **端口** — Enter 生成 `20000–60000` 范围内的值；自定义值必须在
   `1024–65535` 且未被监听。
4. **用户名** — Enter 自动生成；自定义值只允许 `A-Z a-z 0-9 _ -`，长度
   `3–32`。
5. **密码** — Enter 生成恰好 `32` 个字符；自定义值只允许
   `A-Z a-z 0-9 . _ ~ -`，长度 `12–128`，且只读取一次。自定义密码输入可见；
   仅在旁人、终端录制器或串口控制台 logger 无法看到屏幕时输入。

全部按 Enter 会选择中文并生成安全随机值。脚本自身输出遵循所选语言；原始 `apk`
和 OpenRC 输出保持工具自己的语言。

### 手动放行 Alpine 端口

本脚本完全没有防火墙功能：不检测或修改防火墙，不查询、添加、删除、reload 或
持久化规则。你必须在以下两处放行所选 TCP 端口：

1. Alpine 主机自己的防火墙；
2. 云厂商 security group 或 network ACL。

正确 backend、table/chain 和持久化方式取决于镜像。下方[防火墙责任](#防火墙责任)
中的命令只是 operator examples，安装器绝不会执行它们。

### OpenRC 服务行为

Alpine 会安装 `/etc/init.d/socks5-manager`，加入 default runlevel，并通过
`supervise-daemon` 以 `socks5proxy:socks5proxy` 身份运行代理。

依赖块会在存在 firewall 服务时安排启动顺序，并使用 DNS/logger 服务；这不代表脚本
会配置防火墙，也不会使用 `need net`。stdout/stderr 通过 `logger` 送入主机 syslog。
项目不会创建普通日志文件，因此不定义日志轮转。查看 syslog 的具体命令取决于该主机
安装的 logger/syslog 实现；项目不承诺一个通用读取命令。

### 在 root shell 中管理 Alpine

保存脚本后直接使用 POSIX `sh`，不要假设 Alpine 已安装 `sudo`：

```sh
sh socks5.sh             # 未安装时安装；已健康安装时打开菜单
sh socks5.sh install     # 全新安装或原地更新端口/凭据
sh socks5.sh status      # 服务、监听、用户、engine 和安装来源
sh socks5.sh show        # 显示包含密码的凭据卡；仅 TTY
sh socks5.sh restart     # 重启并等待配置端口恢复监听
sh socks5.sh uninstall   # 默认 no 确认后安全卸载
```

健康安装后重新运行一键命令会打开管理菜单。已安装时，`install` 是事务式更新入口：
先询问默认 no 的 `[y/N]`，复用 binary/account/service definition；候选验证失败时恢复
旧的已验证代理。没有公开 `reload` 或 `reconfigure` 命令。

### Alpine 故障排查

- 安装和更新验证依赖 DNS、HTTPS 出站，以及固定自检目标
  `https://example.com/`。
- 凭据卡另行向 `https://icanhazip.com` 发起一次非致命请求，不发送端口、用户名或
  密码，只接受最多 17-byte 响应。它观察的是 source IP（出站地址），不能证明公网
  入站可达。失败时恰好输出一次本地化警告并使用 `SERVER_IPV4`。
- `status` 区分运行、停止和无法验证，不会把 manager 查询失败误报为已停止。
- Alpine 3.20 可能短暂报告 OpenRC 服务 already starting；安装器会重新查询状态并
  等待端口，而不是把瞬时命令结果当成失败。
- **128 MiB/no-swap** 是 CI 中 OpenRC target-container cgroup 的 lifecycle gate，
  不是安装器对任意主机的最低内存拒绝条件。

<!-- section: general-install -->
## Ubuntu、Debian 与 CentOS Stream 快速安装

使用 root 或 root shell：

```sh
bash <(wget -qO- https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/develop/socks5.sh)
```

Curl 形式：

```sh
bash <(curl -fsSL https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/develop/socks5.sh)
```

运行前检查移动候选脚本：

```sh
wget -qO socks5.sh https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/develop/socks5.sh
less socks5.sh
sudo sh socks5.sh
```

保存后的脚本是纯 POSIX `sh`。

<!-- section: credentials -->
## 凭据卡与连接

成功安装或更新后，仅当 stdout 是真实终端时才显示凭据卡，其中包含 Host、Port、
Username、Password 和恰好一个可复制 URI：

```text
socks5://user:password@host:port
```

| 客户端字段 | 凭据卡值 |
|---|---|
| Proxy type | SOCKS5 |
| Host | `Host` |
| Port | `Port` |
| Username | `Username` |
| Password | `Password` |

Host 来自每张卡对固定 endpoint `https://icanhazip.com` 的一次短请求。endpoint 只能
看到服务器 source IP 和请求时间，不接收端口、用户名或密码。source IP 是出站观察，
不证明入站可达。

异常、私有、多行、过长或失败的响应不会导致安装失败。凭据卡改用 `SERVER_IPV4` 并
恰好输出一次本地化警告。输出被重定向或 pipe 时不显示 secret card；请从真实终端运行
`sudo sh socks5.sh show`。`show` 只在你的终端打印密码。

<!-- section: management -->
## 管理与更新

Alpine root-shell 示例之外，保存脚本后可使用：

```sh
sudo sh socks5.sh
sudo sh socks5.sh install
sudo sh socks5.sh status
sudo sh socks5.sh show
sudo sh socks5.sh restart
sudo sh socks5.sh uninstall
```

每次运行都会重新选择语言。`status` 不显示密码。健康安装上确认的 `install` 会
原地更新配置，并事务式验证新凭据和监听状态。

<!-- section: supported-systems -->
## 支持系统

| 要求 | 支持值 |
|---|---|
| OS 最低版本 | Ubuntu 22.04+, Debian 12+, Alpine Linux 3.20+, CentOS Stream 9+ |
| 架构 | `x86_64` / `amd64`, `aarch64` / `arm64` |
| 权限 | root |
| Init | systemd；Alpine 使用 OpenRC |

识别到的版本达到最低门槛就会接受，但不代表每个未来版本都经过测试。当前精确版本 CI
在两个架构上覆盖 Ubuntu 22.04/24.04、Debian 12/13、Alpine 3.20/3.24、CentOS
Stream 9/10 的资产兼容和协议边界。真实 OpenRC lifecycle cells 在 amd64 runner 上
覆盖 Alpine 3.20/3.24；musl arm64 由 compatibility/protocol cells 分别验证。
RHEL、Rocky Linux、AlmaLinux 会被报告为可能兼容，但不会安装。不支持的 ID、
版本、架构和 init system 会 fail closed，脚本不会猜测安装路径。

<!-- section: protocol -->
## 协议边界

| 能力 | 契约 |
|---|---|
| SOCKS5 | 支持 |
| RFC 1929 用户名/密码 | 强制 |
| CONNECT | 唯一允许的命令 |
| 未认证访问 | 拒绝 |
| BIND | 拒绝 |
| UDP ASSOCIATE | 拒绝 |

生成配置使用 `auth strong`、`socks -u2`、仅 CONNECT 的 allow rule 和末尾
`deny *`。`-4` 表示 **IPv4 destination resolution only**；`-u2` 表示必须提供
用户名/密码。CI rejection probes 会在任何未记录的 legacy-family 路径成功建立代理时
阻断发布。

目标 ACL 会在 CONNECT allow rule 前拒绝 this-network、private、CGNAT、loopback、
link-local（包括 `169.254.169.254`）、multicast 和 reserved IPv4。CI 同时验证 literal
IP 与 hostname 路径。

<!-- section: security -->
## 安全说明

- **认证明文传输。** 能观察网络路径的人可能读取用户名和密码。
- **SOCKS5 不是加密隧道，也不是 VPN。** 需要传输加密时，请组合 SSH、TLS 或 VPN。
- **密码以明文保存**在 `/etc/socks5-manager/users.cfg`，权限为
  `root:socks5proxy 0640`；root 和代理进程可以读取。
- 得到凭据且能访问端口的人都能使用代理，流量看起来来自你的服务器。
- 生产服务监听 `0.0.0.0`，即服务器所有 IPv4 interface；实际可达性只由主机防火墙
  与云网络策略控制。
- 凭据不会进入 argv、环境变量、脚本日志、journal 或 shell history；自检通过 stdin
  向 `curl --config -` 传递。
- 脚本不会更改 SELinux enforcing、sshd 配置、软件仓库或防火墙状态。

只在你拥有或明确获授权管理的基础设施上使用本项目。

<!-- section: firewall -->
## 防火墙责任

脚本完全没有防火墙功能。主机防火墙与 cloud security group/network ACL 必须由你
配置。以下只是已经选定正确 backend 的 operator examples：

| Backend | 示例 | 重启后持久？ |
|---|---|---|
| `ufw` | `ufw allow <port>/tcp` | 是 |
| `firewalld` | `firewall-cmd --zone=<zone> --permanent --add-port=<port>/tcp`，再执行一次不带 `--permanent` | 是 |
| `iptables` | `iptables -I INPUT -p tcp --dport <port> -j ACCEPT` | **否**—规则只在 kernel memory only |
| `nftables` | `nft add rule inet filter input tcp dport <port> accept` | 取决于 ruleset 持久化 |

<!-- section: resources -->
## 安装资源

| 资源 | 路径和权限 |
|---|---|
| Engine | `/usr/local/libexec/socks5-manager/3proxy` — `root:root 0755` |
| 配置目录 | `/etc/socks5-manager/` — `root:socks5proxy 0750` |
| 主配置 | `/etc/socks5-manager/3proxy.cfg` — `root:socks5proxy 0640` |
| 凭据 | `/etc/socks5-manager/users.cfg` — `root:socks5proxy 0640` |
| State | `/var/lib/socks5-manager/state` — `root:root 0600` |
| systemd unit | `/etc/systemd/system/socks5-manager.service` |
| OpenRC service | `/etc/init.d/socks5-manager` |
| 账户 | `socks5proxy` — system account、无 home、`nologin`、无密码 |

全新资源以 no-replace 方式 claim，不能覆盖外部路径。变更操作使用
`/run/socks5-manager.lock`。更新会在
`/var/lib/socks5-manager/reconfigure-transaction/` 准备 root-only recovery bundle；
成功更新会删除它，恢复失败则保留它供检查和后续重试。

<!-- section: dependencies -->
## 运行时依赖与 engine 验证

主机映射为：Ubuntu、Debian、CentOS Stream 使用两种 glibc 标签；Alpine 使用两种
musl 标签。四个精确技术标签是 `glibc amd64`、`glibc arm64`、`musl amd64` 和
`musl arm64`。资产名、精确大小和 embedded SHA-256 固定在 `socks5.sh` 中。安装器在安装前验证下载字节，安装后再次计算 hash，没有 target-side compile 或 fallback。

| 资产族 | 资产 | 大小 | SHA-256 |
|---|---|---:|---|
| glibc amd64 | `3proxy-0.9.9.0-da99424-linux-glibc-amd64` | 263168 | `ce3c604d0133df0028b4e9cd93c326b36790db789c769b2a2c78b400b9967a80` |
| glibc arm64 | `3proxy-0.9.9.0-da99424-linux-glibc-arm64` | 279288 | `344e482272e5c16d1f9c762d7ed240cda43bb050a53be767e5393a616607ccf5` |
| musl amd64 | `3proxy-0.9.9.0-da99424-linux-musl-amd64` | 298280 | `ac3fe1a7d52d2b1494d4d00884fc7517acb2340454c2653c95a7346c05d69298` |
| musl arm64 | `3proxy-0.9.9.0-da99424-linux-musl-arm64` | 277624 | `38f2733dfc5d375a4faaebe79f66bd181c7cc3e7b3eb9443c3ac4476fbfeebeb` |

APT 禁用 recommends；DNF/YUM 禁用 weak dependencies；APK 使用 `--no-cache`。
CentOS Stream 默认带 `curl-minimal`，安装器会复用。卸载后保留运行时包。固定 engine
的更新由 operator 负责。3proxy 把 0.9 branch 称为 `lts`，但没有公开 support window；
不要假设上游安全补丁会自动进入此安装。

<!-- section: uninstall -->
## 卸载与恢复

```sh
sudo sh socks5.sh uninstall
```

卸载会先选择语言并询问默认 no。它停止并验证服务，只删除 state 记录的固定项目资源，
并采用非递归（non-recursive）删除：意外目录条目会被保留而不是清空。它不会删除系统包、防火墙
规则、软件仓库、无关 3proxy 或 state 提供的任意路径。未知目录条目或身份变化会被
保留，以便检查和可操作重试。

<!-- section: releases -->
## 发布版本

### v1.0.0 — 已发布

版本化 annotated tag `v1.0.0` 指向 closure commit `91fd13a`。项目发布政策要求
该 tag 永不移动，但 GitHub 当前没有 immutable-tag ruleset 强制该政策。其当时默认
分支上的 push
[run `33282068288`](https://github.com/91sexboy/One-click-socks5-proxy-setup/actions/runs/33282068288)
在创建 tag 和发布
[GitHub Release](https://github.com/91sexboy/One-click-socks5-proxy-setup/releases/tag/v1.0.0)
前通过 45/45。Tagged script：

`https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/v1.0.0/socks5.sh`

SHA-256：

```text
acbfbfe3e6ba0f37f4e2a24ba8a6d68ec5a36513caae2e22e44a0ed28322e0b1
```

### v1.1.0 — 候选版本

当前候选 `socks5.sh` SHA-256：

```text
be9c46ff675b0a64d87da01ecbf0c2d51fba925ffc95b0a96a5a03b89b091230  socks5.sh
```

implementation checkpoint 已完成：commit
`2003d7b47aa13d71b3e37294df0c32fb15577d23` 在
[run `33460169077`](https://github.com/91sexboy/One-click-socks5-proxy-setup/actions/runs/33460169077)
通过全部 45 个 jobs。该 run 包含 Alpine 3.20/3.24 asset compatibility 和 protocol
cells、Alpine 3.24 ACL resolution，以及真实 Alpine 3.20/3.24 OpenRC lifecycle cells。

本次双语 revision 是预期的 evidence-only checkpoint。它必须先通过自身完整 45-job
push CI 才能获得该资格。实现 commit 已通过 45/45；evidence-only commit 随后也必须
通过 45/45；最后 exact closure commit 必须在 `develop` 上通过 45/45。只有这样才能
创建版本化 `v1.1.0` tag，并遵守项目 never-move 政策。`v1.1.0` 尚未发布。

Tag 存在后，使用以下方式验证：

```sh
wget -qO socks5.sh https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/v1.1.0/socks5.sh
printf '%s  %s\n' 'be9c46ff675b0a64d87da01ecbf0c2d51fba925ffc95b0a96a5a03b89b091230' socks5.sh | sha256sum -c -
sudo sh socks5.sh
```

<!-- section: verification -->
## 验证与开发

当前 workflow 展开为 45 个 blocking jobs：

| Job | Cells | 证据 |
|---|---:|---|
| `lint` | 1 | shellcheck、syntax 与 workflow guards |
| `unit` | 2 | amd64/arm64 上的 sh、dash、BusyBox sh |
| `build-matrix` | 16 | 8 个 OS 版本 × 2 个架构 |
| `protocol` | 16 | 对真实 engine 和 production config 运行七种协议用例 |
| `acl-resolution` | 3 | literal-IP 与 hostname 目标拒绝 |
| `systemd-integration` | 2 | amd64/arm64 原生 Ubuntu lifecycle |
| `openrc-integration` | 2 | Alpine 3.20/3.24 lifecycle 和 OpenRC target-container cgroup |
| `distro-systemd-integration` | 3 | Ubuntu 22.04、Debian 12、CentOS Stream 9 |

systemd memory gate 使用同时包含 operation runner 与 proxy service 的 shared systemd
slice。所有 job 都阻断发布，没有 `continue-on-error`。

本地检查：

```sh
sh tests/run.sh
S5_TEST_SHELL=dash sh tests/run.sh
S5_TEST_SHELL='busybox sh' sh tests/run.sh
sh -n socks5.sh
```

完整契约见 [`SPEC.md`](SPEC.md)。

<!-- section: license -->
## 许可证

MIT — 见 [`LICENSE`](LICENSE)。仓库不捆绑 3proxy 源码；经过验证的 engine 资产在
上游许可证下单独构建。
