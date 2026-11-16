# Snell v5 — 自用原生安装管理脚本

固定使用 **Surge 官方 Snell v5.0.1**，不安装 Docker，不升级 v6。
主要面向 **Alpine/OpenRC 的 amd64 / arm64 LXC 小机**，内置经真机验证的 UPX 解壳兼容处理。

## 快速开始

root 下先下载，再执行；**不要管道到 `sh`**，交互输入需要终端：

```sh
# Alpine 若缺少下载工具
apk add --no-cache curl ca-certificates

curl -fL https://raw.githubusercontent.com/Lkwang88/snell-v5/main/snell-v5.sh -o snell-v5.sh
sh snell-v5.sh
```

菜单选择 `1 安装`，填写：

1. **内部监听端口**：小机内绑定的端口，必须空闲。
2. **公网 IP / 域名**：客户端实际使用的地址，不带端口；IPv6 不带方括号。
3. **公网端口**：商家映射后的端口，默认与内部相同。**脚本不会猜测或创建 NAT 映射。**

安装后：

```sh
snell-v5          # 菜单
snell-v5 status
snell-v5 logs
snell-v5 export   # 显示密钥，勿公开
snell-v5 restart
```

无人值守示例（文档示例地址，不是实际节点）：

```sh
SNELL_PORT=30005 SNELL_HOST=192.0.2.10 SNELL_PUBLIC_PORT=20005 sh snell-v5.sh install
```

每次全新安装生成新的随机 PSK。客户端使用 `version=5`、混淆关闭，直接复制导出的条目。首次排错先用普通 TCP，QUIC/UDP 单独验证。

## 取舍和安全边界

- 支持 **amd64/x86_64 和 arm64/aarch64**，自动选择官方下载包、分别校验固定 SHA-256；不支持 armv7/i386 等其他架构。
- **Alpine 3.21/OpenRC 已真机安装和代理转发验证**；Debian/Ubuntu systemd 路径已实现，但尚未真机端到端验证。
- 官方压缩包经 HTTPS 下载，解压后的原始二进制与脚本固定 SHA-256 比对，再在 Alpine 上执行 `upx -t` / `upx -d`。不是第三方重编译内核。
- 固定哈希是维护者对官方 HTTPS 文件的实测记录，**不是 Surge 官方签名或官方公布的校验值**。上游文件若变化，脚本拒绝安装，不自动信任新哈希。
- 仅创建独立 `snell-v5` 服务，不接管旧 Snell，不会自动停止占用端口的其他程序。
- 不修改防火墙、SSH、sysctl，不安装容器、不替换全局 glibc、不添加计划任务。
- 服务当前以 **root** 运行以保持极简部署；不将其宣传为完成安全加固的生产发行版。
- 不自动升级，不自动更新脚本。`update` 只重新安装固定 v5.0.1，替换前备份，启动验证失败时恢复旧二进制。
- 安装成功只代表**真实进程存在且拥有配置端口的 TCP 监听**，不代表公网可达或用户客户端兼容。公网代理请求必须另测。
- 默认 IPv4 监听 `0.0.0.0`，TFO/混淆关闭，DNS 使用内核默认行为。公网 IPv6 入站尚未实现。

## 命令与文件

| 命令 | 作用 |
|---|---|
| `install` | 新装；已有本脚本部署时拒绝覆盖 |
| `start / stop / restart` | 管理本脚本服务 |
| `status` | 检查版本、实际进程与端口归属；不显示 PSK |
| `logs` | 最近 60 行日志 |
| `export` | 导出 Surge 格式节点，**包含 PSK** |
| `update` | 备份后重新安装固定版本，保留原启停状态 |
| `uninstall` | 输入 `YES` 后备份卸载；保留管理命令、日志、依赖和备份 |

| 文件 | 位置 |
|---|---|
| 服务端二进制 | `/usr/local/lib/snell-v5/snell-server` |
| 服务端配置 | `/etc/snell-v5/server.conf` |
| 公网地址/端口 | `/etc/snell-v5/client.conf` |
| 管理命令 | `/usr/local/bin/snell-v5` |
| Alpine 服务 | `/etc/init.d/snell-v5` |
| systemd 服务 | `/etc/systemd/system/snell-v5.service` |
| Alpine 日志 | `/var/log/snell-v5.log` |
| 备份 | `/var/backups/snell-v5/`（**含密钥，不要上传**） |

需改监听端口或密钥时，以 root 编辑服务端配置后 `snell-v5 restart`；改公网入口时编辑 `client.conf`，然后重新 `export`。本版不提供自动迁移旧脚本或自动修改配置菜单。

Alpine 日志仅在服务启动时超过 5 MiB 后保留一个轮转文件，不是持续大小限额。频繁出错时注意磁盘占用。

## 验证

```sh
sh -n snell-v5.sh
python3 test_script.py
shellcheck -s sh snell-v5.sh
```

已完成：8 项离线回归（架构映射、输入校验、TCP/UDP 端口冲突、端口 PID 归属、哈希失败中止、更新失败回滚等）；两台 Alpine 3.21 amd64 和一台 arm64 LXC 全新部署、重启、开机自启注册；外部 Snell v5 客户端经 SOCKS 发起 HTTPS 请求返回 200，错误 PSK 负面对照失败。

另在临时实例上测试启停、同版本更新和备份卸载。未重启 VPS 验证系统启动流程；未验证 UDP/QUIC、所有客户端软件与用户本地线路。临时测试客户端为 [winmin/snell-client](https://github.com/winmin/snell-client)，其为第三方逆向实现，测试成功不等于官方客户端认证。

## 协议与来源

Snell 是 Surge 团队的协议；本仓库仅提供独立编写的安装管理脚本，不分发官方二进制、不代表官方。

- [Snell 官方发布说明](https://kb.nssurge.com/surge-knowledge-base/release-notes/snell)
- [官方 v5.0.1 amd64 下载](https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-amd64.zip)
- [官方 v5.0.1 arm64 下载](https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-aarch64.zip)
- [UPX](https://github.com/upx/upx)

MIT 许可证仅适用于本仓库代码；Snell 和 UPX 分别遵守其自身许可。
