# Snell v5/v6 原生管理器

官方 **v5.0.1 / v6.0.0**，支持 amd64 与 arm64；Alpine/OpenRC 无需容器。
仓库名、文件名和命令 `snell-v5` 保持不变，兼容已安装的旧版。

## 安装

root 执行，先下载再运行，**不要直接管道给 sh**：

```sh
# Alpine 缺下载工具时
apk add --no-cache curl ca-certificates
curl -fL https://raw.githubusercontent.com/Lkwang88/snell-v5/main/snell-v5.sh -o snell-v5.sh
sh snell-v5.sh
```

选「1 安装」→ 选择 v5/v6 → **只填一次端口**。
服务端监听和客户端导出使用同一端口，商家 NAT 映射由你设为同端口。公网 IPv4 自动探测，失败才要求手填；可用 `SNELL_HOST` 覆盖出口 IP（多出口/NAT 请自行确认探测是否正确）。

无人值守示例（示例地址）：

```sh
SNELL_PORT=20005 SNELL_HOST=192.0.2.10 sh snell-v5.sh install 5
# 或 install 6；SNELL_VERSION=5/6 也可指定安装版本
```

每次全新安装产生随机 PSK，配置仅 root 可读。IPv4 监听、TFO 关闭，v5 混淆关闭，v6 固定默认模式 `default`。

## 已安装用户升级管理器

不用重装内核、不用重启现有节点：

```sh
curl -fL https://raw.githubusercontent.com/Lkwang88/snell-v5/main/snell-v5.sh -o snell-v5.sh
sh -n snell-v5.sh && install -m 755 snell-v5.sh /usr/local/bin/snell-v5
snell-v5
```

以上仅更新管理程序，不更改端口、密钥、服务配置或二进制。首次更新可先自行备份旧管理脚本。

## 常用操作

```sh
snell-v5                  # 菜单
snell-v5 status           # 真实二进制版本/进程/端口归属，不显示密钥
snell-v5 logs
snell-v5 export           # 含 PSK，切勿公开
snell-v5 update           # 保持当前大版本，安装本脚本支持的固定版本
snell-v5 switch 6         # 确认后 v5 → v6
snell-v5 switch 5         # 确认后 v6 → v5
snell-v5 start
snell-v5 stop
snell-v5 restart
snell-v5 uninstall        # 输入 YES，备份后卸载
```

跨版本切换会短暂中断此节点，保留地址、端口、PSK 与原启停状态；转换版本专用字段。确认时输入 `YES`，无人值守可设 `SNELL_YES=1`。

**客户端必须支持目标版本并重新导入导出的节点。** v6 输出 `version=6, mode=default`，客户端 mode 必须一致；v6 已移除 v5 的 QUIC Proxy。只支持 v5 的客户端请勿切到 v6。带旧版 obfs 的配置会拒绝转到 v6，不静默破坏旧混淆。

`update` 不会自动跨大版本，也不会自动追逐官网新包：本版明确支持 v5.0.1 与 v6.0.0。版本升级由维护者核验官方文件、更新固定哈希与测试后发布管理脚本。

## 可靠性与边界

- 原始 ELF 按 **版本＋架构** 分别核对固定 SHA-256。该值是维护者从官方 HTTPS 下载的实测值，**不是官方签名**；不匹配直接停止。
- Alpine 的 v5 官方文件带 UPX 壳，经 `upx -t/-d` 处理后试运行；v6 官方文件未压缩，不错误地执行解壳。
- 只安装缺少的运行依赖；无需容器、编译或全局 glibc 替换。不改 SSH、防火墙、sysctl，不加计划任务。
- 切换/更新先暂存校验，再备份，最后停止服务替换二进制和配置；中途失败或 HUP/INT/TERM 会尝试整组回滚。SIGKILL/断电无法执行 trap，保留私有备份供人工恢复。停止失败不会强杀未知进程。
- 安装、切换和重启检查真实进程与其 TCP socket，不凭守护器 `started` 宣称成功。**本机健康不等于公网代理可用。**
- 服务当前 root 运行；定位为自用管理脚本，不宣称已完成生产安全加固。
- 默认仅 IPv4 入站。自动探测请求 `api.ipify.org`；结果应与商家公网入口核对。
- 修改配置后重启；公网地址位于 client.conf。新装只接受内外同端口，旧部署的不同端口 metadata 在更新/切换时原样保留，不擅自改动。
- 保留旧 `snell-v5` 路径和服务名，即使运行 v6 也不改名。仅管理自身部署，不接管其他脚本的 Snell。
- Alpine 日志在服务启动时超过 5 MiB 才保留一个轮转文件，不是持续大小上限。

## 路径与备份

| 内容 | 路径 |
|---|---|
| 管理程序 | `/usr/local/bin/snell-v5` |
| 二进制 | `/usr/local/lib/snell-v5/snell-server` |
| 服务配置 | `/etc/snell-v5/server.conf` |
| 公网地址/导出端口 | `/etc/snell-v5/client.conf` |
| Alpine 服务 | `/etc/init.d/snell-v5` |
| systemd 服务 | `/etc/systemd/system/snell-v5.service` |
| Alpine 日志 | `/var/log/snell-v5.log` |
| 更新/切换备份 | `/var/backups/snell-v5/` |

备份含二进制及 server.conf/client.conf，**含 PSK，不要上传**。人工恢复需先停止服务，恢复匹配的二进制与 server.conf，再启动；必要时同时恢复 client.conf。卸载保留管理命令、日志、依赖和备份。

## 验证

```sh
sh -n snell-v5.sh
python3 test_script.py
shellcheck -s sh snell-v5.sh
```

- 20 项离线回归：双版本双架构哈希、单端口安装、导出版本、配置往返、错误哈希、启动失败/信号回滚、取消及停止状态保留等；ShellCheck 通过。
- 原 v5 已在 Alpine 3.21 amd64/arm64 LXC 真机安装和 HTTPS 代理测试通过。
- 新版在一台 122 MiB 内存的 Alpine 3.21 amd64 LXC 上，以独立服务/端口测试 v5 → v6 → v5、v6 同版本 update、停止状态切换、受控验收失败自动回滚。v5/v6 均通过独立工作机强制 SOCKS HTTPS 200，错误 PSK 对照失败。正式节点配置和二进制校验保持不变。
- 新版 v6 ARM64 仅核验官方文件/哈希和离线选择逻辑，尚未 ARM64 实机转发验证。Debian/Ubuntu systemd 路径未真机端到端验证，未验证 UDP/QUIC或整机重启。
- 协议测试使用第三方逆向客户端 [opensnell-rust](https://github.com/missuo/opensnell-rust)，成功不代表所有官方/第三方客户端或用户线路必然可用。

## 来源与许可

[官方发布说明](https://kb.nssurge.com/surge-knowledge-base/release-notes/snell) · [UPX](https://github.com/upx/upx)

Snell 属于 Surge 团队；本仓库仅提供独立编写的安装管理脚本，不分发官方二进制，不代表官方。MIT 仅适用于本仓库代码，Snell/UPX 遵循各自许可。
