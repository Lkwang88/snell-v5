#!/bin/sh
# Snell v5/v6 manager. Official server binaries; no containers. MIT.
set -eu
SCRIPT_VERSION=2.0.1
VERSION=
MAJOR=
ASSET_ARCH=
OFFICIAL_SHA256=
select_arch() {
    case "$1" in
        x86_64|amd64) ASSET_ARCH=amd64;;
        aarch64|arm64) ASSET_ARCH=aarch64;;
        *) die "不支持的 CPU 架构：$1；支持 amd64/x86_64 和 arm64/aarch64。";;
    esac
}
select_release() {
    case "$1" in
        5|v5) MAJOR=5; VERSION=5.0.1;;
        6|v6) MAJOR=6; VERSION=6.0.0;;
        *) die '版本只能选择 v5 或 v6。';;
    esac
    case "$MAJOR/$ASSET_ARCH" in
        5/amd64) OFFICIAL_SHA256=5b2e221f2c6e29b1db8e47053e1221be29d5627da807cb932b089f514a3609f0;;
        5/aarch64) OFFICIAL_SHA256=c9e1cc1f1a86e7d2958f2bc41ff9dc668edf479455a651ea05c6db2c18cd2e4e;;
        6/amd64) OFFICIAL_SHA256=27d8bead8dd7a33f2207b58c7bb6b4c274f67f537b621dcbee7112ffd22e23e6;;
        6/aarch64) OFFICIAL_SHA256=316c924cb2f7bea75278303265cf004c66379244e101c64ab672a1c987bf8041;;
        *) die '未配置该架构的官方文件校验值。';;
    esac
}
installed_major() {
    output=$(timeout 5 "$BASE/snell-server" --version 2>&1) || return 1
    case "$output" in
        *'snell-server v5.'*) printf '5\n';;
        *'snell-server v6.'*) printf '6\n';;
        *) return 1;;
    esac
}
BASE=/usr/local/lib/snell-v5
CONF=/etc/snell-v5/server.conf
META=/etc/snell-v5/client.conf
SERVICE=snell-v5
LOG=/var/log/snell-v5.log
BACKUPS=/var/backups/snell-v5
LOCK=/run/snell-v5.lock
WORK=
# Mutating commands run under flock --close; daemons never inherit the lock.
MANAGER=

say() { printf '%s\n' "$*"; }
die() { say "错误：$*" >&2; exit 1; }
root_only() { [ "$(id -u)" = 0 ] || die '请用 root 执行。'; }
cleanup() {
    [ -z "$WORK" ] || rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
platform() {
    select_arch "$(uname -m)"
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
    [ "${LOCK_CONTEXT:-0}" = 1 ] || die '内部错误：写操作未受内核锁保护。'
}
with_lock() {
    if ! command -v flock >/dev/null 2>&1 || ! flock --help 2>&1 | grep -q -- '--close'; then
        die '需要 util-linux flock（支持 --close）；Alpine: apk add flock；Debian/Ubuntu: apt-get install util-linux。'
    fi
    # Linux flock accepts the legacy directory as well as a regular file.
    # Never unlink a lock inode: two processes could otherwise lock different files.
    # The supervisor holds the lock, but --close keeps it out of daemon children.
    if flock -n -E 75 -o "$LOCK" sh "$0" __locked "$@"; then
        return 0
    else
        result=$?
        if [ "$result" = 75 ]; then die '另一个管理操作确实正在运行，请稍后重试；不要删除锁。'; fi
        return "$result"
    fi
}
deps() {
    if [ "$MANAGER" = openrc ]; then
        missing=
        for pkg in curl ca-certificates unzip gcompat libstdc++ libgcc iproute2; do
            apk info -e "$pkg" >/dev/null 2>&1 || missing="$missing $pkg"
        done
        if [ "$MAJOR" = 5 ]; then
            apk info -e upx >/dev/null 2>&1 || missing="$missing upx"
        fi
        if [ -n "$missing" ]; then
            # Package names above are fixed, not user input.
            # shellcheck disable=SC2086
            apk add --no-cache $missing
        fi
    else
        command -v apt-get >/dev/null 2>&1 || die 'systemd 路径仅支持 Debian/Ubuntu。'
        if ! command -v curl >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1 || ! command -v ss >/dev/null 2>&1 || [ ! -s /etc/ssl/certs/ca-certificates.crt ]; then
            apt-get update
            apt-get install -y curl ca-certificates unzip iproute2
        fi
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
valid_ipv4() {
    case "$1" in ''|*[!0-9.]*|.*|*.) return 1;; esac
    printf '%s\n' "$1" | awk -F. 'NF != 4 {exit 1} {for(i=1;i<=4;i++) if(length($i)>3 || $i=="" || $i>255) exit 1}'
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
    url="https://dl.nssurge.com/snell/snell-server-v$VERSION-linux-$ASSET_ARCH.zip"
    curl --fail --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 120 --retry 2 "$url" -o "$WORK/server.zip"
    unzip -q "$WORK/server.zip" snell-server -d "$WORK"
    actual=$(sha256sum "$WORK/snell-server"); actual=${actual%% *}
    [ "$actual" = "$OFFICIAL_SHA256" ] || die '官方文件与固定 SHA-256 不符；停止安装，不自动信任新文件。'
    chmod 755 "$WORK/snell-server"
    if [ "$MANAGER" = openrc ] && [ "$MAJOR" = 5 ]; then
        # Only the pinned v5 builds are UPX-packed; v6 must not be unpacked.
        upx -t "$WORK/snell-server" > "$WORK/upx.log" 2>&1 || die 'UPX 完整性检查失败。'
        upx -d "$WORK/snell-server" >> "$WORK/upx.log" 2>&1 || die 'UPX 解壳失败。'
    fi
    timeout 5 "$WORK/snell-server" --version > "$WORK/version.log" 2>&1 || {
        cat "$WORK/version.log" >&2
        die '二进制试运行失败，未替换现有服务。'
    }
    grep -Fq "snell-server v$VERSION " "$WORK/version.log" || die "运行版本与 v$VERSION 不符。"
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
    choice=${SNELL_VERSION:-${1:-}}
    if [ -z "$choice" ]; then
        printf '安装版本 5 / 6 [5]: '
        read -r choice || choice=
        choice=${choice:-5}
    fi
    select_release "$choice"
    port=${SNELL_PORT:-}
    if [ -z "$port" ]; then
        printf '外网端口（监听同端口，映射由你设置）: '
        read -r port || die '缺少端口；无人值守请设置 SNELL_PORT。'
    fi
    valid_port "$port" || die '端口应为 1024–65535，不使用前导零。'
    if [ -n "${SNELL_PUBLIC_PORT:-}" ] && [ "$SNELL_PUBLIC_PORT" != "$port" ]; then
        die '新版采用内外相同端口，请将商家映射设为相同端口。'
    fi
    deps
    host=${SNELL_HOST:-}
    if [ -z "$host" ]; then
        host=$(curl -4fsS --connect-timeout 3 --max-time 5 https://api.ipify.org 2>/dev/null) || host=
        valid_ipv4 "$host" || host=
    fi
    if [ -z "$host" ]; then
        printf '自动获取公网 IPv4 失败，请填写公网 IP/域名: '
        read -r host || die '缺少公网地址；可设置 SNELL_HOST。'
    fi
    valid_host "$host" || die '公网地址格式不正确。'
    port_busy "$port" && die '该端口的 TCP 或 UDP 已占用；不会停止其他服务。'
    prepare_binary
    umask 077
    mkdir -p "$BASE" /etc/snell-v5
    psk=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')
    [ "${#psk}" = 48 ] || die '随机密钥生成失败。'
    {
        printf '[snell-server]\nlisten = 0.0.0.0:%s\npsk = %s\nipv6 = false\ntfo = false\n' "$port" "$psk"
        if [ "$MAJOR" = 6 ]; then printf 'mode = default\n'; else printf 'obfs = off\n'; fi
    } > "$CONF"
    printf 'host = %s\nport = %s\n' "$host" "$port" > "$META"
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
# Preserve ordinary settings, remove incompatible version-specific fields.
convert_config() {
    if [ "$MAJOR" = 6 ] && [ "$(get obfs "$CONF")" != off ] && [ -n "$(get obfs "$CONF")" ]; then
        die 'v6 不支持旧 obfs；请先关闭混淆并同步客户端。'
    fi
    awk -v major="$MAJOR" '
        /^[[:space:]]*(mode|obfs|obfs-host|version|dns-ip-preference|ipv-preference)[[:space:]]*=/ {next}
        {print}
        END {if(major==6) print "mode = default"; else print "obfs = off"}
    ' "$CONF" > "$WORK/server.conf"
    chmod 600 "$WORK/server.conf"
}
restore_transaction() {
    # Never overwrite a running replacement process if it cannot be stopped.
    if ! action stop; then say "回滚停止失败，手动恢复备份：$BACKUP" >&2; return 1; fi
    [ -z "$(owned_pids)" ] || return 1
    cp -p "$BACKUP/snell-server" "$BASE/snell-server.new" &&
        mv "$BASE/snell-server.new" "$BASE/snell-server" || return 1
    cp -p "$BACKUP/server.conf" "$CONF.new" && mv "$CONF.new" "$CONF" || return 1
    if [ "$running" = 1 ]; then
        action start && wait_healthy || return 1
    fi
    say '已恢复原服务和配置。'
}
transaction_exit() {
    code=$?
    trap - EXIT
    trap '' HUP INT TERM
    if [ "$TRANSACTION" = 1 ]; then
        if ! restore_transaction; then
            say "自动回滚未完成，备份保留在 $BACKUP" >&2
        fi
        code=1
    fi
    cleanup
    exit "$code"
}
change_release() {
    lock
    if [ ! -x "$BASE/snell-server" ] || [ ! -f "$CONF" ] || ! unit_exists; then
        die '没有完整部署，请先安装或检查残留。'
    fi
    current=$(installed_major) || die '无法确定已安装版本，停止替换。'
    if [ "$1" = update ]; then
        select_release "$current"
    else
        select_release "$2"
        if [ "$current" = "$MAJOR" ]; then say "已经是 v$MAJOR，请使用 update。"; return; fi
        say "将切换 v$current → v$MAJOR，保留端口/PSK。客户端需同步 version 和 mode；v6 不再提供 QUIC Proxy。"
        if [ "${SNELL_YES:-0}" != 1 ]; then
            printf '输入 YES 确认切换: '
            read -r answer || return 1
            [ "$answer" = YES ] || die '已取消。'
        fi
    fi
    deps
    prepare_binary
    if [ "$current" = "$MAJOR" ]; then cp -p "$CONF" "$WORK/server.conf";
    else convert_config; fi
    backup
    running=0
    if action status >/dev/null 2>&1 || [ -n "$(owned_pids)" ]; then running=1; fi
    TRANSACTION=0
    trap transaction_exit EXIT
    # Activate rollback BEFORE stopping anything; all subsequent failures restore.
    TRANSACTION=1
    action stop || die '停止失败，启动回滚。'
    [ -z "$(owned_pids)" ] || die '仍有服务进程，启动回滚。'
    cp "$WORK/snell-server" "$BASE/snell-server.new"
    chmod 755 "$BASE/snell-server.new"
    mv "$BASE/snell-server.new" "$BASE/snell-server"
    cp -p "$WORK/server.conf" "$CONF.new"
    mv "$CONF.new" "$CONF"
    if [ "$running" = 1 ]; then
        action start
        wait_healthy || die '新版本启动检查失败，启动回滚。'
    fi
    TRANSACTION=0
    say "已安装 v$VERSION，保留原启停状态。备份可用于恢复；公网代理请另测。"
    install_self
    if [ "$current" != "$MAJOR" ]; then export_cmd; fi
}
update_cmd() { change_release update; }
switch_cmd() {
    target=${1:-}
    if [ -z "$target" ]; then
        printf '切换目标 5 / 6: '
        read -r target || die '缺少目标版本。'
    fi
    case "$target" in 5|v5|6|v6) ;; *) die '版本只能选择 v5 或 v6。';; esac
    change_release switch "$target"
}
export_cmd() {
    root_only
    if [ ! -r "$CONF" ] || [ ! -r "$META" ]; then die '缺少配置。'; fi
    host=$(get host "$META"); public_port=$(get port "$META"); psk=$(get psk "$CONF")
    case "$host" in *:*) host="[$host]";; esac
    major=$(installed_major) || die '无法确认二进制版本，不导出错误节点。'
    say '下行含密钥，请勿公开分享：'
    printf 'My-Snell-v%s = snell, %s, %s, psk=%s, version=%s, reuse=true, tfo=false' "$major" "$host" "$public_port" "$psk" "$major"
    if [ "$major" = 6 ]; then
        mode=$(get mode "$CONF"); mode=${mode:-default}
        case "$mode" in default|unshaped|unsafe-raw) ;; *) die '无效的 v6 mode。';; esac
        printf ', mode=%s' "$mode"
    fi
    printf '\n'
    say '切换后重新导入节点；客户端须支持对应版本，v6 的 mode 须一致。'
}
status_cmd() {
    root_only
    say "管理器版本：$SCRIPT_VERSION"
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
Snell v5/v6 管理器（amd64 / arm64，旧入口 snell-v5 保持兼容）
用法：sh snell-v5.sh [install [5|6]|switch [5|6]|start|stop|restart|status|logs|export|update|uninstall|help]
无参数打开菜单；安装后可直接运行 snell-v5。
安装只填一个端口，监听和外网同端口，商家映射由你设置；公网地址自动获取。
无人值守：SNELL_VERSION=5 SNELL_PORT=端口 [SNELL_HOST=公网地址]。
update 保持当前大版本；switch 需确认（无人值守可设 SNELL_YES=1）。
当前支持固定官方 v5.0.1/v6.0.0；不自动追逐上游版本，不创建容器、不改防火墙/SSH/sysctl。
HELP
}
menu() {
    while :; do
        printf '\nSnell v5/v6 管理器 %s\n' "$SCRIPT_VERSION"
        say '1 安装  2 启动  3 停止  4 重启  5 状态  6 日志  7 导出  8 更新当前大版本  9 卸载  10 切换v5/v6  0 退出'
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
            10) sh "$0" switch || say '操作未完成。';;
            0) return 0;; *) say '无效选项。';;
        esac
    done
}
main() {
    cmd=${1:-menu}
    case "$cmd" in help|-h|--help) help_cmd; return;; esac
    root_only
    platform
    LOCK_CONTEXT=0
    if [ "$cmd" = __locked ]; then
        shift
        cmd=${1:-}
        LOCK_CONTEXT=1
    else
        case "$cmd" in
            install|switch|update|uninstall|start|stop|restart) with_lock "$@"; return $?;;
        esac
    fi
    case "$cmd" in
        install) install_cmd "${2:-}";; switch) switch_cmd "${2:-}";;
        update) update_cmd;; export) export_cmd;;
        status) status_cmd;; logs) logs_cmd;; uninstall) uninstall_cmd;;
        start|stop|restart) control_cmd "$cmd";; menu) menu;;
        *) help_cmd; return 1;;
    esac
}
main "$@"
