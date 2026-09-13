# Xray-only mixed 代理

一个单文件 POSIX shell 安装器，用于在你拥有或获授权管理的 Linux 服务器上部署经过校验的 Xray-core `mixed` 代理。

本项目不安装 3x-ui，也不安装 Web 面板、数据库、订阅服务或其他协议组件。它只运行一个 Xray 进程，并在同一个 TCP 端口提供：

- SOCKS5 + RFC 1929 用户名/密码认证；
- HTTP proxy + Basic 用户名/密码认证。

## 快速安装

请在 root shell 中执行：

```sh
curl -fsSL https://raw.githubusercontent.com/91sexboy/One-click-socks5-proxy-setup/xray-only/socks5.sh -o socks5.sh
sh socks5.sh
```

首次运行时选择语言，之后的安装和管理命令会记住这次选择：

```text
1) 中文
2) English
```

接着输入端口、账户名和密码。输入值时直接回车会生成随机值：

- 端口：`20000–60000`；手动端口必须在 `1024–65535` 且未被监听；
- 账户名：随机生成或手动输入 `3–32` 个字母、数字、下划线或短横线；
- 密码：随机生成 32 个字符或手动输入 `12–128` 个安全字符。

安装并验证成功后，终端会立即显示 SOCKS5 和 HTTP 代理连接链接，无需再执行命令查看。
如果输出被重定向到文件或管道，则隐藏凭据并提示如何稍后查看。

后续管理命令会沿用已保存的语言：

```sh
sh socks5.sh install      # 安装或更新
sh socks5.sh status       # 查看状态，不显示密码
sh socks5.sh show         # 稍后再次查看凭据，需要 root + 真实 TTY
sh socks5.sh restart      # 重启并验证端口
sh socks5.sh uninstall    # 默认不删除
sh socks5.sh language     # 主动切换并保存语言
```

语言偏好独立保存在 `/etc/xray-socks5.lang`，卸载代理后仍保留。修改语言需要 root；
如果保存失败，脚本会明确提示本次选择只对当前运行有效。

## `mixed` 是什么意思

Xray 的 `mixed` 入站把 SOCKS 和 HTTP 代理放在同一个监听端口上。客户端选择哪种协议，由客户端发送的数据决定：

```text
SOCKS5：socks5://user:password@host:port
HTTP：  http://user:password@host:port
```

使用 `socks5://` 时，客户端仍然执行标准 SOCKS5 greeting、RFC 1929 用户名/密码认证和 CONNECT。`mixed` 只是额外允许 HTTP proxy 客户端连接同一个端口；它不是纯 SOCKS5 服务端。

首版固定：

```text
协议 protocol：mixed（SOCKS5 + HTTP）
认证 auth：password
账户 accounts：一组
UDP：关闭
```

因此不承诺 UDP ASSOCIATE。BIND、未认证访问、错误凭据和不支持的旧 SOCKS 请求都会在 CI 中验证为拒绝或明确失败。

## 运行方式

```text
脚本
  → 检查 root、系统、架构、依赖和监听探测器
  → 下载固定版本 Xray ZIP
  → 校验 archive 大小和 SHA-256
  → 安全提取并校验 xray ELF
  → 生成一个 mixed JSON 配置
  → 运行 xray run -test -c candidate
  → 原子替换配置
  → 以非 root 账户运行 Xray
  → 等待服务和精确端口就绪
  → 验证 SOCKS5 与 HTTP 认证，并验证目标边界会拒绝一个活着的本地目标
```

配置不包含 Xray API、stats、metrics、GeoIP、GeoSite、TLS、REALITY、WebSocket、gRPC、XHTTP 或第二个公开监听器；除「安全边界」一节描述的目标边界之外没有任何路由规则。

脚本不会修改主机防火墙、云安全组、NAT 或端口转发。请由管理员自行放行选定的 TCP 端口。

## 固定 Xray 版本和资产

默认使用官方稳定版 Xray-core `v26.3.27`，不使用 `latest`、`main`、`dev-latest` 或 prerelease。

| 架构 | 官方 archive | archive 大小 | archive SHA-256 |
|---|---|---:|---|
| `amd64` / `x86_64` | `Xray-linux-64.zip` | 21136402 | `23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae` |
| `arm64` / `aarch64` | `Xray-linux-arm64-v8a.zip` | 19716427 | `4d30283ae614e3057f730f67cd088a42be6fdf91f8639d82cb69e48cde80413c` |

发布 tag commit：

```text
d2758a023cd7f4174a5a5fa4ff66e487d4342ba0
```

archive 中预期包含根目录下的 `xray`、`geoip.dat`、`geosite.dat`、`LICENSE` 和 `README.md`。安装器只安装 `xray`，不会安装地理数据文件。

安装器检查 archive 大小、SHA-256、成员名称、成员数量、提取出的 ELF 类型、目标架构和二进制 SHA-256。官方 Linux 二进制是静态链接的，目标主机不需要 Go、Git、GCC、Make 或源码编译。

## 文件和权限

| 资源 | 路径 | 预期权限 |
|---|---|---|
| Xray 二进制 | `/usr/local/libexec/xray-socks5/xray` | `root:root 0755` |
| 配置目录 | `/etc/xray-socks5/` | root-owned，私有 |
| Xray 配置 | `/etc/xray-socks5/config.json` | `root:xray-socks5 0640` |
| 语言偏好 | `/etc/xray-socks5.lang` | `root:root 0644`，卸载时保留 |
| state | `/var/lib/xray-socks5/state` | `root:root 0600` |
| systemd unit | `/etc/systemd/system/xray-socks5.service` | `root:root 0644` |
| 操作锁 | `/run/xray-socks5.lock` | root-owned |
| 服务账户 | `xray-socks5` | system account、无 home、`nologin`、无密码 |

密码只保存在受保护的 Xray JSON 配置中；state 只保存账户名、版本、资产和配置 hash，不保存密码。密码不会放进服务 `ExecStart`、环境变量、shell history 或日志。

新安装使用独立的 `xray-socks5` 命名空间，不会采用、覆盖或删除旧 3proxy 项目使用的 `socks5-manager` 路径或 `socks5proxy` 账户。

## 安全边界

- SOCKS5 用户名和密码在网络上传输时没有加密；需要保密时请使用 SSH、TLS 或 VPN；
- 得到凭据并能访问端口的人可以使用代理，流量看起来来自服务器；
- 生成的配置会把十二个目标网段送入 blackhole，已认证的客户端无法借这条隧道访问服务器
  自身的回环地址、其背后的私网与 CGNAT 网段，以及承载云实例元数据
  （`169.254.169.254`）的链路本地网段。域名目标按解析出的地址匹配。其余目标仍然直连，
  脚本也依旧不修改任何防火墙规则——这是代理层的边界，不能替代主机层的边界；
- `mixed` 同时接受 SOCKS5 和 HTTP，这是本项目明确的兼容性选择；
- UDP 默认关闭，不应将本项目当作 UDP 或 VPN；
- Xray 配置中的密码是磁盘明文，文件权限限制为 root 和代理服务账户可读；
- 脚本不自动配置防火墙或云网络策略；
- 安装或更新后的自动凭据卡与 `show` 都只有真实 TTY 才显示密码；安装输出被重定向时
  隐藏凭据，`show` 的重定向和 pipe 则会拒绝显示；
- 每次显示凭据卡会用一次受限的 HTTPS 请求向 `icanhazip.com` 查询本机公网 IPv4，让凭据卡
  给出可直接使用的 URI。只接受严格校验过的公网地址，私网、CGNAT 和回环地址一律
  拒绝；也可以设置 `S5_SERVER_IPV4` 自己指定地址并跳过该请求。两者都没有时，卡片
  会打印 `SERVER_IPV4` 并提示替换；
- 安装、更新、重启和卸载都使用操作锁；配置替换和失败恢复采用原子文件流程；
- 配置测试失败发生在停止健康服务之前，失败候选不会替换旧配置。

## 生命周期

安装或更新会先生成候选 JSON，并执行：

```sh
xray run -test -c /path/to/candidate
```

该命令只验证配置，不监听端口。通过后，脚本才原子替换正式配置并启动：

```sh
xray run -c /etc/xray-socks5/config.json
```

更新采用完整重启，不实现 Xray gRPC 热更新。已有连接会因服务重启而断开；重启完成后脚本会等待服务和精确监听端口恢复。Xray 配置错误使用退出状态 23，并由 systemd `RestartPreventExitStatus=23` 防止配置错误被无限重启。

发布新配置后更新失败时，脚本先恢复旧配置和状态，再重启服务。如果恢复本身失败，会报告
事务备份目录并保留恢复副本，而不是删除它们。后续更新会拒绝覆盖待处理的恢复目录，失败
重试也不会清理上一次调用留下的恢复副本。卸载会在停止服务、删除受管文件和账户前，
检查私有目录中的未知或不安全条目；这些条目保持原样，确认并移走后可以重试卸载。

## 支持范围

`socks5.sh` 的平台检查接受：

- Ubuntu 22.04+ amd64/arm64；
- Ubuntu 20.04 amd64；
- Debian 12+ amd64/arm64；
- CentOS Stream 9+ amd64/arm64；
- Alpine Linux 3.20+ amd64/arm64。

接受不等于有证据。完整服务生命周期（安装、status、restart、崩溃恢复、配置错误遏制、
命名空间审计、协议、卸载）由 CI 在 **Ubuntu 24.04 amd64** 和 **Alpine 3.20 / 3.24 amd64**
上分别通过各自的 init 后端验证。Alpine job 只预装 OpenRC，因此安装器必须自行 provision
运行时工具。arm64 只有 archive 与二进制校验，没有生命周期 job。Ubuntu 22.04、
Ubuntu 20.04、Debian 12 和 CentOS Stream 都没有生命周期 job，属于被接受但未验证。

不能仅凭 Xray archive 下载成功就声称某个发行版的服务生命周期已验证。

对已有安装重新执行 `install` 就是原地更新，两个生命周期 job 都会实际跑一次：轮换凭据、要求新身份同时出现在配置和 state 中、不允许残留任何事务证据，并使用轮换后的 passfile 重跑命名空间审计。

服务契约使用系统原生 init：Ubuntu、Debian 和 CentOS 使用 systemd，Alpine 3.20+ 使用
OpenRC。对于不支持的 init 系统，`socks5.sh` 会拒绝安装。

## 测试和内存

完整测试在 GitHub Actions 运行，不在本地运行完整慢速 suite。单元测试覆盖 `sh`、`dash`、
`bash` 和 BusyBox `sh`，文档检查还会在不含本地专用文档的公开检出测试副本中运行。CI 验证：

- asset 下载、大小、hash、架构和安全提取；
- JSON shape 和 Xray `run -test`；
- 同一端口的 SOCKS5 和 HTTP 正确/错误认证；
- 未认证、SOCKS4/4a、BIND 和 `udp=false` 的 UDP ASSOCIATE；
- IPv4、域名和可用 IPv6 目标；
- 长时间双向分帧传输、idle/resume、1/32/128 并发；
- systemd restart、`SIGKILL` 后的崩溃恢复，以及 `RestartPreventExitStatus=23` 对配置错误重启循环的阻断；
- Xray 进程 `VmRSS`、服务的 systemd `MemoryCurrent` 与 `MemoryPeak`，以及 restart count。

并发门禁会在传输前和关闭连接前同步同组隧道。独立目标必须在每个客户端帧到达时观察到
该组全部 1/32/128 条隧道在线，且每条隧道接收五帧；无关的后台长连接不计入本组。
服务端主动帧会校验载荷和连续序号，整个交换过程（包括末尾窗口）不允许超过两秒没有进展。
CI 启动器只有通过监听检查后才发布就绪标记。

尚未公布内存预算。内存 job 记录 Xray 进程 `VmRSS` 快照、cgroup 当前用量及
idle/1/32/128 连接各自的阶段峰值。常驻采样器在重置、建立连接和取样期间保持同一个
可读写的 `memory.peak` 文件描述符，并用先高负载、释放后再低负载的实验核对实际 runner
内核的重置语义，同时记录内核版本。systemd `MemoryCurrent` 与整个运行期的 `MemoryPeak`
单独输出，另记录 OOM 计数并要求 restart count 为零。systemd 单调状态时间戳之差
**不是监听就绪耗时**。不设置未经测量的 `MemoryMax`，内存证据仍仅在 systemd 上采集。

公布任何数字都必须同时给出 Xray 版本、平台、配置、连接数、持续时间和产生该数字的 CI run；不能从 archive 大小推断 RSS，也不能把面板部署的内存当成 Xray-only 内存。

## 许可证

MIT，见 [`LICENSE`](LICENSE)。
