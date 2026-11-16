#!/bin/sh
# Snell v5 manager. Official server binary; no containers. MIT.
set -eu
VERSION=5.0.1
OFFICIAL_SHA256=5b2e221f2c6e29b1db8e47053e1221be29d5627da807cb932b089f514a3609f0
BASE=/usr/local/lib/snell-v5
CONF=/etc/snell-v5/server.conf
META=/etc/snell-v5/client.conf
SERVICE=snell-v5
LOG=/var/log/snell-v5.log
BACKUPS=/var/backups/snell-v5
LOCK=/run/snell-v5.lock
WORK=
LOCKED=0
MANAGER=

say() { printf '%s\n' "$*"; }
die() { say "错误：$*" >&2; exit 1; }
root_only() { [ "$(id -u)" = 0 ] || die '请用 root 执行。'; }
cleanup() {
    [ -z "$WORK" ] || rm -rf "$WORK"
    [ "$LOCKED" = 0 ] || rmdir "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
platform() {
    [ "$(uname -m)" = x86_64 ] || die '当前版本仅验证并支持 x86_64/amd64。'
    if [ -f /etc/alpine-release ] && command -v rc-service >/dev/null 2>&1; then
        MANAGER=openrc
    elif command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        MANAGER=systemd
    else
        die '需要 Alpine/OpenRC 或正在运行 systemd 的 Debian/Ubuntu。'
    fi
}
lock() {
    root_only
    mkdir "$LOCK" 2>/dev/null || die "另一个操作进行中；确认没有操作后可手动清理 $LOCK。"
    LOCKED=1
}
deps() {
    if [ "$MANAGER" = openrc ]; then
        apk add --no-cache curl ca-certificates unzip gcompat libstdc++ libgcc upx iproute2
    else
        command -v apt-get >/dev/null 2>&1 || die 'systemd 路径仅支持 Debian/Ubuntu。'
        apt-get update
        apt-get install -y curl ca-certificates unzip iproute2
    fi
}
get() { sed -n "s/^$1[[:space:]]*=[[:space:]]*//p" "$2" | head -n 1; }
valid_port() {
    case "$1" in ''|*[!0-9]*|0*) return 1;; esac
    [ "${#1}" -le 5 ] && [ "$1" -ge 1024 ] && [ "$1" -le 65535 ]
}
valid_host() {
    case "$1" in ''|*[!a-zA-Z0-9.:_-]*) return 1;; esac
    [ "${#1}" -le 253 ]
}
port_busy() {
    sockets=$(ss -H -lnt "sport = :$1") || return 0
    [ -n "$sockets" ] && return 0
    sockets=$(ss -H -lnu "sport = :$1") || return 0
    [ -n "$sockets" ]
}
action() {
    if [ "$MANAGER" = openrc ]; then
        rc-service "$SERVICE" "$1"
    else
        systemctl "$1" "$SERVICE"
    fi
}
unit_exists() {
    if [ "$MANAGER" = openrc ]; then [ -f "/etc/init.d/$SERVICE" ];
    else [ -f "/etc/systemd/system/$SERVICE.service" ]; fi
}
# gcompat exposes the loader as /proc/PID/exe; inspect NUL-separated argv.
owned_pids() {
    for p in /proc/[0-9]*/cmdline; do
        [ -r "$p" ] || continue
        args=$(tr '\000' '\n' < "$p" 2>/dev/null) || continue
        printf '%s\n' "$args" | grep -Fxq "$BASE/snell-server" || continue
        printf '%s\n' "$args" | grep -Fxq "$CONF" || continue
        printf '%s\n' "$args" | grep -q 'supervise-daemon' && continue
        pid=${p#/proc/}; pid=${pid%/cmdline}
        printf '%s\n' "$pid"
    done
}
healthy() {
    [ -r "$CONF" ] || return 1
    port=$(get listen "$CONF"); port=${port##*:}
    pids=$(owned_pids)
    [ -n "$pids" ] || return 1
    sockets=$(ss -H -lntp "sport = :$port") || return 1
    for pid in $pids; do
        case "$sockets" in *"pid=$pid,"*) return 0;; esac
    done
    return 1
}
wait_healthy() {
    n=0
    while [ "$n" -lt 10 ]; do
        healthy && return 0
        n=$((n + 1)); sleep 1
    done
    return 1
}
prepare_binary() {
    WORK=$(mktemp -d /var/tmp/snell-v5.XXXXXXXX)
    chmod 700 "$WORK"
    url="https://dl.nssurge.com/snell/snell-server-v$VERSION-linux-amd64.zip"
    curl --fail --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 120 --retry 2 "$url" -o "$WORK/server.zip"
    unzip -q "$WORK/server.zip" snell-server -d "$WORK"
    actual=$(sha256sum "$WORK/snell-server"); actual=${actual%% *}
    [ "$actual" = "$OFFICIAL_SHA256" ] || die '官方文件与固定 SHA-256 不符；停止安装，不自动信任新文件。'
    chmod 755 "$WORK/snell-server"
    if [ "$MANAGER" = openrc ]; then
        # Decompress the verified official UPX file, not a third-party rebuild.
        upx -t "$WORK/snell-server" > "$WORK/upx.log" 2>&1 || die 'UPX 完整性检查失败。'
        upx -d "$WORK/snell-server" >> "$WORK/upx.log" 2>&1 || die 'UPX 解壳失败。'
    fi
    timeout 5 "$WORK/snell-server" --version > "$WORK/version.log" 2>&1 || {
        cat "$WORK/version.log" >&2
        die '二进制试运行失败，未替换现有服务。'
    }
    grep -Fq "snell-server v$VERSION " "$WORK/version.log" || die '运行版本与 v5.0.1 不符。'
    say "已验证官方 Snell v$VERSION；运行测试通过。"
}
write_unit() {
    if [ "$MANAGER" = openrc ]; then
        cat > "/etc/init.d/$SERVICE" <<'UNIT'
#!/sbin/openrc-run
name="Snell v5"
description="Official Snell v5 server"
command="/usr/local/lib/snell-v5/snell-server"
command_args="-l info -c /etc/snell-v5/server.conf"
supervisor="supervise-daemon"
respawn_delay=3
respawn_max=5
respawn_period=60
output_log="/var/log/snell-v5.log"
error_log="/var/log/snell-v5.log"
rc_ulimit="-n 32767"
depend() { need net; }
start_pre() {
    if [ -f /var/log/snell-v5.log ]; then
        size=$(wc -c < /var/log/snell-v5.log)
        if [ "$size" -gt 5242880 ]; then
            mv /var/log/snell-v5.log /var/log/snell-v5.log.1
        fi
    fi
    touch /var/log/snell-v5.log
    chmod 600 /var/log/snell-v5.log
}
UNIT
        chmod 755 "/etc/init.d/$SERVICE"
    else
        cat > "/etc/systemd/system/$SERVICE.service" <<'UNIT'
[Unit]
Description=Official Snell v5 server
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5
[Service]
Type=simple
ExecStart=/usr/local/lib/snell-v5/snell-server -l info -c /etc/snell-v5/server.conf
Restart=on-failure
RestartSec=3
LimitNOFILE=32767
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload
    fi
}
install_cmd() {
    lock
    if [ -e "$BASE" ] || [ -e /etc/snell-v5 ] || unit_exists; then
        die '已存在本脚本的部署或残留；不会覆盖，请先 status 或检查路径。'
    fi
    port=${SNELL_PORT:-}
    host=${SNELL_HOST:-}
    public_port=${SNELL_PUBLIC_PORT:-}
    if [ -z "$port" ]; then
        printf '内部监听端口（商家分配的内部端口）: '
        read -r port || die '缺少端口；无人值守请设置 SNELL_PORT。'
    fi
    valid_port "$port" || die '监听端口应为 1024–65535，不使用前导零。'
    if [ -z "$host" ]; then
        printf '客户端使用的公网 IP 或域名（不带端口）: '
        read -r host || die '缺少公网地址；无人值守请设置 SNELL_HOST。'
    fi
    valid_host "$host" || die '公网地址只能包含域名/IP 字符，不要带空格、逗号或 IPv6 方括号。'
    if [ -z "$public_port" ]; then
        printf '客户端公网端口 [%s]（NAT 不一致时填写映射端口）: ' "$port"
        read -r public_port || public_port=
        public_port=${public_port:-$port}
    fi
    valid_port "$public_port" || die '公网端口应为 1024–65535。'
    deps
    port_busy "$port" && die '该内部端口的 TCP 或 UDP 已占用；不会停止其他服务。'
    prepare_binary
    umask 077
    mkdir -p "$BASE" /etc/snell-v5
    psk=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')
    [ "${#psk}" = 48 ] || die '随机密钥生成失败。'
    cat > "$CONF" <<CONFEOF
[snell-server]
listen = 0.0.0.0:$port
psk = $psk
ipv6 = false
obfs = off
tfo = false
CONFEOF
    printf 'host = %s\nport = %s\n' "$host" "$public_port" > "$META"
    cp "$WORK/snell-server" "$BASE/snell-server"
    chmod 755 "$BASE/snell-server"
    write_unit
    if action start && wait_healthy; then
        if [ "$MANAGER" = openrc ]; then rc-update add "$SERVICE" default;
        else systemctl enable "$SERVICE"; fi
        install_self
        say '服务启动、进程归属与 TCP 监听检查通过。尚未验证公网代理请求！'
        export_cmd
    else
        action stop || true
        die '启动检查失败，已尝试停止；保留文件供排查，运行 logs。未宣称安装成功。'
    fi
}
install_self() {
    case "$0" in /*) self=$0;; *) self=$(pwd)/$0;; esac
    if [ -f "$self" ] && [ "$self" != /usr/local/bin/snell-v5 ]; then
        cp "$self" /usr/local/bin/snell-v5.new
        chmod 755 /usr/local/bin/snell-v5.new
        mv /usr/local/bin/snell-v5.new /usr/local/bin/snell-v5
    fi
}
backup() {
    umask 077
    mkdir -p "$BACKUPS"
    BACKUP=$(mktemp -d "$BACKUPS/$(date +%Y%m%d-%H%M%S).XXXXXX")
    cp -p "$BASE/snell-server" "$BACKUP/snell-server"
    cp -p "$CONF" "$BACKUP/server.conf"
    [ ! -f "$META" ] || cp -p "$META" "$BACKUP/client.conf"
    say "备份：$BACKUP（含密钥，勿公开）"
}
update_cmd() {
    lock
    if [ ! -x "$BASE/snell-server" ] || [ ! -f "$CONF" ] || ! unit_exists; then
        die '没有完整部署，请先安装或检查残留。'
    fi
    deps
    prepare_binary
    backup
    running=0
    [ -z "$(owned_pids)" ] || running=1
    action stop || die '停止失败，未替换。'
    cp "$WORK/snell-server" "$BASE/snell-server.new"
    chmod 755 "$BASE/snell-server.new"
    mv "$BASE/snell-server.new" "$BASE/snell-server"
    if [ "$running" = 1 ]; then
        if action start && wait_healthy; then
            say '同版本重新安装成功（始终锁定 v5.0.1）。'
        else
            say '新二进制启动失败，恢复原文件。'
            action stop || true
            cp -p "$BACKUP/snell-server" "$BASE/snell-server.new"
            mv "$BASE/snell-server.new" "$BASE/snell-server"
            action start || true
            wait_healthy || die "回滚后仍异常，请查看日志及 $BACKUP。"
            die '新二进制未通过验收，已恢复原服务。'
        fi
    else
        say '同版本文件已替换；保留原来的停止状态。'
    fi
}
export_cmd() {
    root_only
    if [ ! -r "$CONF" ] || [ ! -r "$META" ]; then die '缺少配置。'; fi
    host=$(get host "$META"); public_port=$(get port "$META"); psk=$(get psk "$CONF")
    case "$host" in *:*) host="[$host]";; esac
    say '下行含密钥，请勿公开分享：'
    printf 'My-Snell-v5 = snell, %s, %s, psk=%s, version=5, reuse=true, tfo=false\n' "$host" "$public_port" "$psk"
    say '客户端混淆关闭。首次排错先使用普通 TCP；QUIC/UDP 另行验证。'
}
status_cmd() {
    root_only
    if [ ! -f "$CONF" ]; then say '未安装。'; return 1; fi
    "$BASE/snell-server" --version 2>&1 || true
    say "内部监听：$(get listen "$CONF")"
    if [ -f "$META" ]; then say "客户端入口：$(get host "$META"):$(get port "$META")"; fi
    action status || true
    if healthy; then say '本机进程及 TCP 端口归属：正常（不代表公网代理可用）。';
    else say '本机健康检查：异常。'; return 1; fi
}
logs_cmd() {
    root_only
    if [ "$MANAGER" = openrc ]; then
        [ -f "$LOG" ] || die '暂无日志。'
        tail -n 60 "$LOG"
    else journalctl -u "$SERVICE" -n 60 --no-pager; fi
}
control_cmd() {
    lock
    unit_exists || die '尚未安装服务。'
    if [ "$1" = stop ]; then
        action stop
        [ -z "$(owned_pids)" ] || die '仍有本服务进程，请检查。'
    else
        if [ "$MANAGER" = systemd ]; then systemctl reset-failed "$SERVICE" || true; fi
        action "$1"
        wait_healthy || die '启动后未通过健康检查，运行 logs 排查。'
    fi
}
uninstall_cmd() {
    lock
    if [ ! -x "$BASE/snell-server" ] || [ ! -f "$CONF" ]; then
        die '部署不完整；为避免误删，请手动检查路径。'
    fi
    say '将停止并移除本脚本部署；先备份二进制和配置。其他 Snell/Xray 不动。'
    printf '输入 YES 确认卸载: '
    read -r answer || return 1
    [ "$answer" = YES ] || die '已取消。'
    backup
    action stop
    [ -z "$(owned_pids)" ] || die '仍有进程，不删除文件。'
    if [ "$MANAGER" = openrc ]; then
        rc-update del "$SERVICE" default || true
        cp -p "/etc/init.d/$SERVICE" "$BACKUP/service"
        rm -f "/etc/init.d/$SERVICE"
    else
        systemctl disable "$SERVICE"
        cp -p "/etc/systemd/system/$SERVICE.service" "$BACKUP/service"
        rm -f "/etc/systemd/system/$SERVICE.service"
        systemctl daemon-reload
    fi
    rm -rf "$BASE" /etc/snell-v5
    say "已卸载；管理命令、日志、依赖和备份保留：$BACKUP"
}
help_cmd() {
    cat <<'HELP'
Snell v5 专用管理器（amd64）
用法：sh snell-v5.sh [install|start|stop|restart|status|logs|export|update|uninstall|help]
无参数打开菜单；安装后可直接运行 snell-v5。
install 支持 SNELL_PORT=内部端口 SNELL_HOST=公网地址 SNELL_PUBLIC_PORT=公网端口。
update 只重新安装固定的官方 v5.0.1，不升级 v6，不自动更新管理脚本。
不创建容器、不改防火墙/SSH/sysctl、不接管已有服务、不猜 NAT 映射。
HELP
}
menu() {
    while :; do
        say '\nSnell v5：1 安装  2 启动  3 停止  4 重启  5 状态  6 日志  7 导出  8 更新  9 卸载  0 退出'
        printf '> '; read -r choice || return 0
        case "$choice" in
            1) sh "$0" install || say '操作未完成。';;
            2) sh "$0" start || say '操作未完成。';;
            3) sh "$0" stop || say '操作未完成。';;
            4) sh "$0" restart || say '操作未完成。';;
            5) sh "$0" status || true;;
            6) sh "$0" logs || true;;
            7) sh "$0" export || true;;
            8) sh "$0" update || say '操作未完成。';;
            9) sh "$0" uninstall || say '操作未完成。';;
            0) return 0;; *) say '无效选项。';;
        esac
    done
}
main() {
    cmd=${1:-menu}
    case "$cmd" in help|-h|--help) help_cmd; return;; esac
    root_only
    platform
    case "$cmd" in
        install) install_cmd;; update) update_cmd;; export) export_cmd;;
        status) status_cmd;; logs) logs_cmd;; uninstall) uninstall_cmd;;
        start|stop|restart) control_cmd "$cmd";; menu) menu;;
        *) help_cmd; return 1;;
    esac
}
main "$@"
