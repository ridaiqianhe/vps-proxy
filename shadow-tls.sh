#!/bin/bash

# ===================================================================
# Shadow-TLS v3 前置脚本(可为已安装的 Shadowsocks 2022 或 Snell 加壳)
# 仓库: https://github.com/ridaiqianhe/vps-proxy
# 上游: https://github.com/ihciah/shadow-tls
# ===================================================================

# 不用 set -e: 交互菜单脚本,单次操作失败应回菜单,不整体退出

RED='\e[31m'; GREEN='\e[92m'; YELLOW='\e[93m'; BLUE='\e[94m'; CYAN='\e[96m'; PURPLE='\e[38;5;135m'; GRAY='\e[90m'; NC='\e[0m'

STLS_BIN="/usr/bin/shadow-tls"
META_DIR="/etc/shadow-tls"
META_FILE="$META_DIR/meta.env"
SERVICE_FILE="/etc/systemd/system/shadow-tls.service"
SNELL_BIN="/usr/local/bin/snell-server"
SNELL_CONF="/etc/snell/snell-server.conf"
SNELL_VERSION_FILE="/etc/snell/installed_version"
GH_REPO="ihciah/shadow-tls"
TEMP_DIR="$(mktemp -d /tmp/stls_install.XXXXXX)"
trap 'rm -rf "$TEMP_DIR"' EXIT

log_info()  { echo -e "${GREEN}[INFO] $1${NC}" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN] $1${NC}" >&2; }
log_error() { echo -e "${RED}[ERROR] $1${NC}" >&2; }

[ "$(id -u)" != "0" ] && { log_error "请以 root 权限运行此脚本"; exit 1; }

get_random_free_port() {
    local port=""
    for _ in $(seq 1 20); do
        port=$(shuf -i 30000-65000 -n 1)
        ss -tuln 2>/dev/null | grep -q ":$port " || { echo "$port"; return 0; }
    done
    echo "$port"
}

get_host_ip() {
    local ip
    ip=$(curl -s --connect-timeout 10 http://checkip.amazonaws.com 2>/dev/null)
    [ -z "$ip" ] && ip=$(curl -s --connect-timeout 5 https://ipinfo.io/ip 2>/dev/null)
    echo "$ip"
}

is_valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

is_tcp_port_listening() {
    local port="$1"
    ss -H -ltn "sport = :$port" 2>/dev/null | grep -q .
}

get_meta_value() {
    local key="$1"
    [ -f "$META_FILE" ] || return 1
    awk -v key="$key" 'index($0, key "=") == 1 {print substr($0, length(key) + 2); exit}' "$META_FILE"
}

get_snell_config_value() {
    local key="$1"
    local config_file="${2:-$SNELL_CONF}"

    awk -v key="$key" '
        /^[[:space:]]*#/ {next}
        {
            if (index($0, "=") == 0) next
            name = $0
            sub(/=.*/, "", name)
            gsub(/[[:space:]]/, "", name)
            if (name == key) {
                value = substr($0, index($0, "=") + 1)
                sub(/^[[:space:]]+/, "", value)
                sub(/[[:space:]]+$/, "", value)
                print value
                exit
            }
        }
    ' "$config_file" 2>/dev/null
}

get_snell_version_from_binary() {
    local flag output version
    [ -x "$SNELL_BIN" ] || return 1

    for flag in --version -v; do
        if command -v timeout >/dev/null 2>&1; then
            output=$(timeout 2 "$SNELL_BIN" "$flag" </dev/null 2>&1)
        else
            output=$("$SNELL_BIN" "$flag" </dev/null 2>&1)
        fi
        version=$(printf '%s\n' "$output" | grep -oE 'v?(5|6)\.[0-9]+\.[0-9]+[[:alnum:]]*' | head -n 1)
        if [ -n "$version" ]; then
            [[ "$version" == v* ]] || version="v$version"
            printf '%s\n' "$version"
            return 0
        fi
    done
    return 1
}

get_recorded_snell_version() {
    local version=""
    [ -f "$SNELL_VERSION_FILE" ] || return 1
    IFS= read -r version < "$SNELL_VERSION_FILE"
    version=${version%$'\r'}
    [[ "$version" =~ ^v(5|6)\.[0-9]+\.[0-9]+[[:alnum:]]*$ ]] || return 1
    printf '%s\n' "$version"
}

get_snell_major_version() {
    local version listen_value
    version=$(get_recorded_snell_version 2>/dev/null) || version=$(get_snell_version_from_binary 2>/dev/null)
    case "$version" in
        v6*) printf '6\n'; return 0 ;;
        v5*) printf '5\n'; return 0 ;;
    esac

    # 本项目会把 v6 标准化为双监听地址；旧安装无版本记录时可据此迁移。
    listen_value=$(get_snell_config_value listen "$SNELL_CONF")
    if [[ "$listen_value" == *,* ]] && [[ "$listen_value" == *"[::"* ]]; then
        printf '6\n'
        return 0
    fi
    return 1
}

resolve_snell_major_version() {
    local major
    major=$(get_snell_major_version 2>/dev/null) && { printf '%s\n' "$major"; return 0; }
    major=$(get_meta_value SNELL_MAJOR_VERSION 2>/dev/null)
    [[ "$major" =~ ^(5|6)$ ]] || return 1
    printf '%s\n' "$major"
}

set_snell_listen_value() {
    local listen_value="$1"
    [ -f "$SNELL_CONF" ] || return 1
    grep -q '^[[:space:]]*listen[[:space:]]*=' "$SNELL_CONF" || return 1
    sed -i "s|^[[:space:]]*listen[[:space:]]*=.*$|listen = $listen_value|" "$SNELL_CONF"
}

get_snell_loopback_listen() {
    local major="$1"
    local port="$2"
    if [ "$major" = "6" ]; then
        printf '127.0.0.1:%s,[::1]:%s\n' "$port" "$port"
    else
        printf '127.0.0.1:%s\n' "$port"
    fi
}

get_snell_public_listen() {
    local major="$1"
    local port="$2"
    if [ "$major" = "6" ]; then
        printf '0.0.0.0:%s,[::]:%s\n' "$port" "$port"
    else
        printf '0.0.0.0:%s\n' "$port"
    fi
}

infer_snell_original_listen() {
    local major="$1"
    local port="$2"
    local current_listen="$3"
    local loopback_listen

    loopback_listen=$(get_snell_loopback_listen "$major" "$port")
    if [ -z "$current_listen" ] || [ "$current_listen" = "$loopback_listen" ]; then
        get_snell_public_listen "$major" "$port"
    else
        printf '%s\n' "$current_listen"
    fi
}

restart_snell_service() {
    systemctl restart snell 2>/dev/null || return 1
    sleep 1
    systemctl is-active --quiet snell 2>/dev/null
}

protect_snell_backend() {
    local major="$1"
    local port="$2"
    local previous_listen="$3"
    local loopback_listen

    loopback_listen=$(get_snell_loopback_listen "$major" "$port")
    [ "$previous_listen" = "$loopback_listen" ] && return 0
    if ! set_snell_listen_value "$loopback_listen" || ! restart_snell_service || ! is_tcp_port_listening "$port"; then
        set_snell_listen_value "$previous_listen" 2>/dev/null || true
        systemctl restart snell 2>/dev/null || true
        log_error "无法将 Snell 后端切换为本机监听，已恢复原配置"
        return 1
    fi
    log_info "Snell 后端已限制为本机监听，公网只能通过 Shadow-TLS 访问"
}

restore_snell_backend() {
    local major="$1"
    local port="$2"
    local original_listen="$3"
    local current_listen loopback_listen

    [ -n "$original_listen" ] || return 0
    [ "$major" = "5" ] && original_listen=${original_listen%%,*}
    current_listen=$(get_snell_config_value listen "$SNELL_CONF")
    loopback_listen=$(get_snell_loopback_listen "$major" "$port")
    if [ "$current_listen" != "$loopback_listen" ]; then
        log_warn "Snell listen 已被手动修改，未自动覆盖当前配置"
        return 0
    fi
    if ! set_snell_listen_value "$original_listen" || ! restart_snell_service; then
        set_snell_listen_value "$current_listen" 2>/dev/null || true
        systemctl restart snell 2>/dev/null || true
        log_error "恢复 Snell 原监听地址失败，请检查 $SNELL_CONF"
        return 1
    fi
    log_info "已恢复 Snell 原监听地址: $original_listen"
}

get_snell_port_from_config() {
    local config_file="$1"
    local listen_value endpoint port

    listen_value=$(awk -F '=' '/^[[:space:]]*listen[[:space:]]*=/ {print substr($0, index($0, "=") + 1); exit}' "$config_file" 2>/dev/null)
    endpoint=${listen_value%%,*}
    port=${endpoint##*:}
    port=$(printf '%s' "$port" | tr -d '[:space:]')
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] && printf '%s\n' "$port"
}

# 探测已安装的后端: 输出 "类型:端口"，未找到则空
detect_backends() {
    BACKENDS=()
    if [ -f /etc/ss-rust/config.json ] && command -v jq >/dev/null 2>&1; then
        local p; p=$(jq -r '.server_port' /etc/ss-rust/config.json 2>/dev/null)
        [ -n "$p" ] && [ "$p" != "null" ] && BACKENDS+=("ss:$p")
    fi
    if [ -f "$SNELL_CONF" ]; then
        local p; p=$(get_snell_port_from_config "$SNELL_CONF")
        [ -n "$p" ] && BACKENDS+=("snell:$p")
    fi
}

persist_iptables_rules() {
    if command -v iptables-save >/dev/null 2>&1; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
}

remove_udp_redirect() {
    local stls_port="$1"
    local backend_port="$2"
    is_valid_port "$stls_port" && is_valid_port "$backend_port" || return 0
    command -v iptables >/dev/null 2>&1 || return 0

    while iptables -t nat -C PREROUTING -p udp --dport "$stls_port" -j REDIRECT --to-port "$backend_port" 2>/dev/null; do
        iptables -t nat -D PREROUTING -p udp --dport "$stls_port" -j REDIRECT --to-port "$backend_port" 2>/dev/null || break
    done
    persist_iptables_rules
}

add_ss_udp_redirect() {
    local stls_port="$1"
    local backend_port="$2"
    command -v iptables >/dev/null 2>&1 || return 0

    if ! iptables -t nat -C PREROUTING -p udp --dport "$stls_port" -j REDIRECT --to-port "$backend_port" 2>/dev/null; then
        iptables -t nat -A PREROUTING -p udp --dport "$stls_port" -j REDIRECT --to-port "$backend_port" 2>/dev/null || true
    fi
    persist_iptables_rules
}

rollback_stls_install() {
    local previous_snell_listen="$1"
    local had_binary="$2"
    local had_service="$3"
    local had_meta="$4"
    local was_active="$5"
    local was_enabled="$6"
    local current_listen

    if [ -n "$previous_snell_listen" ]; then
        current_listen=$(get_snell_config_value listen "$SNELL_CONF")
        if [ "$current_listen" != "$previous_snell_listen" ]; then
            set_snell_listen_value "$previous_snell_listen" 2>/dev/null || true
            systemctl restart snell 2>/dev/null || true
        fi
    fi

    if [ "$had_binary" = "1" ]; then
        cp -p "$TEMP_DIR/shadow-tls.previous" "$STLS_BIN" 2>/dev/null || true
    else
        rm -f "$STLS_BIN"
    fi
    if [ "$had_service" = "1" ]; then
        cp -p "$TEMP_DIR/shadow-tls.service.previous" "$SERVICE_FILE" 2>/dev/null || true
    else
        rm -f "$SERVICE_FILE"
    fi
    if [ "$had_meta" = "1" ]; then
        mkdir -p "$META_DIR"
        cp -p "$TEMP_DIR/meta.env.previous" "$META_FILE" 2>/dev/null || true
    else
        rm -f "$META_FILE"
    fi

    systemctl daemon-reload 2>/dev/null || true
    if [ "$was_enabled" = "1" ]; then
        systemctl enable shadow-tls >/dev/null 2>&1 || true
    else
        systemctl disable shadow-tls >/dev/null 2>&1 || true
    fi
    if [ "$was_active" = "1" ]; then
        systemctl restart shadow-tls 2>/dev/null || true
    else
        systemctl stop shadow-tls 2>/dev/null || true
    fi
    log_warn "Shadow-TLS 安装失败，已恢复安装前状态"
}

download_stls() {
    local asset version
    case "$(uname -m)" in
        x86_64)  asset="shadow-tls-x86_64-unknown-linux-musl" ;;
        aarch64) asset="shadow-tls-aarch64-unknown-linux-musl" ;;
        armv7l)  asset="shadow-tls-armv7-unknown-linux-musleabihf" ;;
        *) log_error "Shadow-TLS 不支持当前架构: $(uname -m)"; return 1 ;;
    esac
    version=$(curl -s --connect-timeout 10 --max-time 30 "https://api.github.com/repos/$GH_REPO/releases/latest" | grep -o '"tag_name": *"[^"]*"' | cut -d'"' -f4)
    [ -z "$version" ] && { version="v0.2.25"; log_warn "无法获取最新版本，使用 $version"; }
    log_info "下载 Shadow-TLS $version ($asset)..."
    if ! wget -q "https://github.com/$GH_REPO/releases/download/$version/$asset" -O "$TEMP_DIR/stls"; then
        log_error "下载失败"; return 1
    fi
    install -m 755 "$TEMP_DIR/stls" "$STLS_BIN"
}

install_stls() {
    detect_backends
    local backend_type backend_port sel b
    local old_stls_port old_stls_password old_sni old_backend_port old_backend_type old_snell_original_listen
    local snell_major_version="" snell_previous_listen="" snell_original_listen=""
    local had_binary=0 had_service=0 had_meta=0 was_active=0 was_enabled=0
    old_stls_port=$(get_meta_value STLS_PORT 2>/dev/null)
    old_stls_password=$(get_meta_value STLS_PASSWORD 2>/dev/null)
    old_sni=$(get_meta_value SNI 2>/dev/null)
    old_backend_port=$(get_meta_value BACKEND_PORT 2>/dev/null)
    old_backend_type=$(get_meta_value BACKEND_TYPE 2>/dev/null)
    old_snell_original_listen=$(get_meta_value SNELL_ORIGINAL_LISTEN 2>/dev/null)
    if [ ${#BACKENDS[@]} -eq 0 ]; then
        log_warn "未自动检测到已安装的 SS/Snell"
        read -p "请手动输入要保护的后端本地端口: " backend_port
        backend_type="custom"
    else
        echo "检测到以下可保护的后端:"
        local i=1
        for b in "${BACKENDS[@]}"; do
            echo "$i. ${b%%:*}  (端口 ${b##*:})"
            i=$((i+1))
        done
        echo "$i. 手动输入端口"
        read -p "选择要保护的后端 [1-$i]: " sel
        if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "$i" ]; then
            log_error "无效选项: ${sel:-空}"; return 1
        elif [ "$sel" = "$i" ]; then
            read -p "请输入后端本地端口: " backend_port
            backend_type="custom"
        else
            local chosen="${BACKENDS[$((sel-1))]}"
            backend_type="${chosen%%:*}"
            backend_port="${chosen##*:}"
        fi
    fi
    is_valid_port "$backend_port" || { log_error "后端端口无效: ${backend_port:-空}"; return 1; }
    if [ -n "$old_backend_type" ] && { [ "$old_backend_type" != "$backend_type" ] || [ "$old_backend_port" != "$backend_port" ]; }; then
        log_error "当前 Shadow-TLS 已绑定 $old_backend_type:$old_backend_port；切换后端前请先卸载"
        return 1
    fi

    if [ "$backend_type" = "snell" ]; then
        if ! systemctl is-active --quiet snell 2>/dev/null; then
            log_error "Snell 服务未运行，请先修复 Snell 服务"
            return 1
        fi
        if ! is_tcp_port_listening "$backend_port"; then
            log_error "Snell 未监听 TCP 端口 $backend_port，请检查 Snell 配置和日志"
            return 1
        fi
        if ! snell_major_version=$(resolve_snell_major_version); then
            log_error "无法识别 Snell 主版本。请先用最新版 snell.sh 更新或重装 Snell，再安装 Shadow-TLS"
            return 1
        fi
        log_info "已识别 Snell v$snell_major_version，生成对应的 Surge 配置"
        snell_previous_listen=$(get_snell_config_value listen "$SNELL_CONF")
        [ -n "$snell_previous_listen" ] || { log_error "无法读取 Snell listen 配置"; return 1; }
        if [ "$old_backend_type" = "snell" ] && [ "$old_backend_port" = "$backend_port" ] && [ -n "$old_snell_original_listen" ]; then
            snell_original_listen="$old_snell_original_listen"
        else
            snell_original_listen=$(infer_snell_original_listen "$snell_major_version" "$backend_port" "$snell_previous_listen")
        fi
    fi

    local stls_port stls_password custom
    stls_port=${old_stls_port:-$(get_random_free_port)}
    read -p "$(echo -e "${CYAN}◆ 对外端口 ${GRAY}(回车使用 ${GREEN}$stls_port${GRAY})${CYAN}: ${NC}")" custom
    [ -n "$custom" ] && stls_port=$custom
    is_valid_port "$stls_port" || { log_error "对外端口无效: ${stls_port:-空}"; return 1; }
    [ "$stls_port" != "$backend_port" ] || { log_error "对外端口不能与后端端口相同"; return 1; }

    stls_password=${old_stls_password:-$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)}
    read -p "$(echo -e "${CYAN}◆ 密码 ${GRAY}(回车使用 ${GREEN}$stls_password${GRAY})${CYAN}: ${NC}")" custom
    [ -n "$custom" ] && stls_password=$custom
    if ! [[ "$stls_password" =~ ^[A-Za-z0-9._~-]{8,128}$ ]]; then
        log_error "密码仅支持 8-128 位字母、数字及 . _ ~ -"
        return 1
    fi

    # 选 SNI 握手域名(均支持 TLS 1.3)
    local options=("gateway.icloud.com" "s0.awsstatic.com" "www.microsoft.com" "publicassets.cdn-apple.com" "swscan.apple.com")
    local default_sni_choice=1
    for i in "${!options[@]}"; do
        [ "${options[$i]}" = "$old_sni" ] && default_sni_choice=$((i+1))
    done
    echo "请选择 TLS 握手域名 (默认 $default_sni_choice):"
    for i in "${!options[@]}"; do echo "$((i+1)). ${options[$i]}"; done
    read -p "输入选项 [默认 $default_sni_choice]: " tc; tc=${tc:-$default_sni_choice}
    local sni="${options[0]}"
    if [[ "$tc" =~ ^[0-9]+$ ]] && [ "$tc" -ge 1 ] && [ "$tc" -le "${#options[@]}" ]; then
        sni="${options[$((tc-1))]}"
    else
        log_warn "SNI 选项无效，使用默认域名 ${options[0]}"
    fi

    [ -f "$STLS_BIN" ] && { cp -p "$STLS_BIN" "$TEMP_DIR/shadow-tls.previous" || return 1; had_binary=1; }
    [ -f "$SERVICE_FILE" ] && { cp -p "$SERVICE_FILE" "$TEMP_DIR/shadow-tls.service.previous" || return 1; had_service=1; }
    [ -f "$META_FILE" ] && { cp -p "$META_FILE" "$TEMP_DIR/meta.env.previous" || return 1; had_meta=1; }
    systemctl is-active --quiet shadow-tls 2>/dev/null && was_active=1
    systemctl is-enabled --quiet shadow-tls 2>/dev/null && was_enabled=1

    command -v wget >/dev/null 2>&1 || { apt-get install -y wget 2>/dev/null || yum install -y wget 2>/dev/null; }
    if ! download_stls; then
        rollback_stls_install "$snell_previous_listen" "$had_binary" "$had_service" "$had_meta" "$was_active" "$was_enabled"
        return 1
    fi

    if ! cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Shadow-TLS v3 Server Service
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
Environment=MONOIO_FORCE_LEGACY_DRIVER=1
Environment=RUST_LOG=error
ExecStart=$STLS_BIN --v3 --strict --fastopen server --listen ::0:$stls_port --server 127.0.0.1:$backend_port --password $stls_password --tls $sni --wildcard-sni authed
StandardOutput=journal
StandardError=journal
SyslogIdentifier=shadow-tls
LogRateLimitIntervalSec=30
LogRateLimitBurst=200
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    then
        log_error "写入 Shadow-TLS 服务文件失败"
        rollback_stls_install "$snell_previous_listen" "$had_binary" "$had_service" "$had_meta" "$was_active" "$was_enabled"
        return 1
    fi

    # journald 全局磁盘上限
    if [ -f /etc/systemd/journald.conf ] && ! grep -q '^SystemMaxUse=' /etc/systemd/journald.conf; then
        echo "SystemMaxUse=200M" >> /etc/systemd/journald.conf
        systemctl restart systemd-journald 2>/dev/null || true
    fi

    if ! mkdir -p "$META_DIR" || ! cat > "$META_FILE" << EOF
STLS_PORT=$stls_port
STLS_PASSWORD=$stls_password
SNI=$sni
BACKEND_TYPE=$backend_type
BACKEND_PORT=$backend_port
SNELL_MAJOR_VERSION=$snell_major_version
SNELL_ORIGINAL_LISTEN=$snell_original_listen
EOF
    then
        log_error "写入 Shadow-TLS 元数据失败"
        rollback_stls_install "$snell_previous_listen" "$had_binary" "$had_service" "$had_meta" "$was_active" "$was_enabled"
        return 1
    fi
    if ! chmod 600 "$META_FILE"; then
        log_error "设置 Shadow-TLS 元数据权限失败"
        rollback_stls_install "$snell_previous_listen" "$had_binary" "$had_service" "$had_meta" "$was_active" "$was_enabled"
        return 1
    fi

    if ! systemctl daemon-reload || ! systemctl enable shadow-tls >/dev/null 2>&1; then
        log_error "加载或启用 Shadow-TLS 服务失败"
        rollback_stls_install "$snell_previous_listen" "$had_binary" "$had_service" "$had_meta" "$was_active" "$was_enabled"
        return 1
    fi
    if [ "$backend_type" = "snell" ] && ! protect_snell_backend "$snell_major_version" "$backend_port" "$snell_previous_listen"; then
        rollback_stls_install "$snell_previous_listen" "$had_binary" "$had_service" "$had_meta" "$was_active" "$was_enabled"
        return 1
    fi
    if ! systemctl restart shadow-tls; then
        log_error "Shadow-TLS 启动失败，请执行 journalctl -u shadow-tls 查看"
        rollback_stls_install "$snell_previous_listen" "$had_binary" "$had_service" "$had_meta" "$was_active" "$was_enabled"
        return 1
    fi
    sleep 1
    if ! systemctl is-active --quiet shadow-tls; then
        log_error "Shadow-TLS 启动后立即退出，请执行 journalctl -u shadow-tls -n 100 查看"
        rollback_stls_install "$snell_previous_listen" "$had_binary" "$had_service" "$had_meta" "$was_active" "$was_enabled"
        return 1
    fi

    # 清理旧脚本遗留的规则。Snell UDP relay 走 Snell 的 TCP 隧道；仅 SS 需要原生 UDP 重定向。
    remove_udp_redirect "$old_stls_port" "$old_backend_port"
    [ "$backend_type" = "ss" ] && add_ss_udp_redirect "$stls_port" "$backend_port"

    log_info "Shadow-TLS v3 安装成功！后端: $backend_type (端口 $backend_port)"
    show_config
}

uninstall_stls() {
    if [ ! -f "$SERVICE_FILE" ]; then log_error "Shadow-TLS 未安装"; return 0; fi
    read -p "确认卸载 Shadow-TLS？[输入 yes 确认]: " a
    [ "$a" != "yes" ] && { log_info "已取消"; return 0; }

    local stls_port backend_port backend_type snell_major_version snell_original_listen
    stls_port=$(get_meta_value STLS_PORT 2>/dev/null)
    backend_port=$(get_meta_value BACKEND_PORT 2>/dev/null)
    backend_type=$(get_meta_value BACKEND_TYPE 2>/dev/null)
    snell_major_version=$(get_snell_major_version 2>/dev/null) || snell_major_version=$(get_meta_value SNELL_MAJOR_VERSION 2>/dev/null)
    snell_original_listen=$(get_meta_value SNELL_ORIGINAL_LISTEN 2>/dev/null)
    if [ "$backend_type" = "snell" ] && [[ "$snell_major_version" =~ ^(5|6)$ ]] && [ -z "$snell_original_listen" ]; then
        snell_original_listen=$(infer_snell_original_listen "$snell_major_version" "$backend_port" "$(get_snell_config_value listen "$SNELL_CONF")")
    fi

    systemctl stop shadow-tls 2>/dev/null || true
    if [ "$backend_type" = "snell" ] && [[ "$snell_major_version" =~ ^(5|6)$ ]]; then
        if ! restore_snell_backend "$snell_major_version" "$backend_port" "$snell_original_listen"; then
            systemctl start shadow-tls 2>/dev/null || true
            return 1
        fi
    fi

    systemctl disable shadow-tls 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$STLS_BIN"
    remove_udp_redirect "$stls_port" "$backend_port"
    rm -rf "$META_DIR"
    systemctl daemon-reload
    log_info "Shadow-TLS 已卸载(后端 SS/Snell 未受影响)"
}

show_config() {
    [ ! -f "$META_FILE" ] && { log_error "未找到配置，请先安装"; return 1; }
    local STLS_PORT STLS_PASSWORD SNI BACKEND_TYPE BACKEND_PORT SNELL_MAJOR_VERSION host country
    STLS_PORT=$(get_meta_value STLS_PORT)
    STLS_PASSWORD=$(get_meta_value STLS_PASSWORD)
    SNI=$(get_meta_value SNI)
    BACKEND_TYPE=$(get_meta_value BACKEND_TYPE)
    BACKEND_PORT=$(get_meta_value BACKEND_PORT)
    SNELL_MAJOR_VERSION=$(get_meta_value SNELL_MAJOR_VERSION 2>/dev/null)
    host=$(get_host_ip); [ -z "$host" ] && host="YOUR_SERVER_IP"
    country=$(curl -s --connect-timeout 5 "http://ipinfo.io/$host/country" 2>/dev/null | tr -d '\n'); [ -z "$country" ] && country="XX"

    echo ""
    echo -e "${CYAN}============= Shadow-TLS v3 配置信息 =============${NC}"
    echo -e "${BLUE}后端: $BACKEND_TYPE (本地端口 $BACKEND_PORT)${NC}"
    echo -e "${BLUE}对外端口: $STLS_PORT   SNI: $SNI${NC}"
    echo -e "${BLUE}Shadow-TLS 密码: $STLS_PASSWORD${NC}"
    echo ""

    if [ "$BACKEND_TYPE" = "ss" ]; then
        local ss_pw ss_method
        ss_pw=$(jq -r '.password' /etc/ss-rust/config.json 2>/dev/null)
        ss_method=$(jq -r '.method' /etc/ss-rust/config.json 2>/dev/null)
        echo -e "${YELLOW}--- Surge 配置行 (SS + Shadow-TLS) ---${NC}"
        echo "$country-ss-stls = ss, $host, $STLS_PORT, encrypt-method=$ss_method, password=$ss_pw, shadow-tls-password=$STLS_PASSWORD, shadow-tls-sni=$SNI, shadow-tls-version=3, udp-relay=true"
        echo ""
        echo -e "${YELLOW}--- mihomo(clash-meta) 出站片段 ---${NC}"
        cat << EOF
  - name: $country-ss-stls
    type: ss
    server: $host
    port: $STLS_PORT
    cipher: $ss_method
    password: "$ss_pw"
    plugin: shadow-tls
    plugin-opts:
      host: "$SNI"
      password: "$STLS_PASSWORD"
      version: 3
    udp: true
EOF
    elif [ "$BACKEND_TYPE" = "snell" ]; then
        local psk ver listen_value
        psk=$(get_snell_config_value psk "$SNELL_CONF")
        [ -n "$psk" ] || { log_error "无法从 $SNELL_CONF 读取 Snell PSK"; return 1; }
        ver=$(get_snell_major_version 2>/dev/null) || ver="$SNELL_MAJOR_VERSION"
        [[ "$ver" =~ ^(5|6)$ ]] || { log_error "不支持或无法识别的 Snell 版本，请先运行最新版 snell.sh 更新 Snell"; return 1; }
        listen_value=$(get_snell_config_value listen "$SNELL_CONF")
        if [[ "$listen_value" == 0.0.0.0:* ]] || [[ "$listen_value" == *"[::]:"* ]]; then
            log_warn "Snell 后端仍监听公网地址；重新执行安装可限制为本机监听"
        fi
        echo -e "${YELLOW}--- Surge 配置行 (Snell + Shadow-TLS) ---${NC}"
        echo "$country-snell-stls = snell, $host, $STLS_PORT, psk=$psk, version=$ver, shadow-tls-password=$STLS_PASSWORD, shadow-tls-sni=$SNI, shadow-tls-version=3"
    else
        echo -e "${YELLOW}后端为自定义端口 $BACKEND_PORT，请按你的协议自行拼装客户端配置。${NC}"
        echo "对外连接: $host:$STLS_PORT，shadow-tls-password=$STLS_PASSWORD，sni=$SNI，version=3"
    fi
    echo -e "${CYAN}=================================================${NC}"
    echo ""
}

show_status() {
    if systemctl is-active --quiet shadow-tls 2>/dev/null; then
        echo -e "${GREEN}✓ Shadow-TLS 服务: 运行中${NC}"
    elif [ -f "$SERVICE_FILE" ]; then
        echo -e "${YELLOW}⚠ Shadow-TLS 服务: 已安装但未运行${NC}"
    else
        echo -e "${RED}✗ Shadow-TLS 服务: 未安装${NC}"
    fi
}

main() {
    while true; do
        clear 2>/dev/null || true
        echo ""
        echo -e "${PURPLE}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "     ${CYAN}🛡️  Shadow-TLS v3 前置${NC}   ${YELLOW}(｀・ω・´)${NC}"
        echo -e "     ${GRAY}给你的小代理套层马甲~${NC}"
        echo -e "${PURPLE}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -n "  "; show_status
        echo ""
        echo -e "  ${GREEN}1.${NC} 🛡️  安装 ${GRAY}(为 SS / Snell 加壳)${NC}"
        echo -e "  ${GREEN}2.${NC} 🗑️  卸载"
        echo -e "  ${GREEN}3.${NC} 📋 查看配置"
        echo -e "  ${YELLOW}0.${NC} 👋 退出"
        echo ""
        read -p "$(echo -e "  ${CYAN}请输入选项 [0-3]: ${NC}")" choice
        case $choice in
            1) install_stls ;;
            2) uninstall_stls ;;
            3) show_config ;;
            0) echo -e "  ${PURPLE}バイバイ~ (｡･ω･)ﾉﾞ${NC}"; exit 0 ;;
            *) echo -e "  ${YELLOW}(・_・?) 没有「$choice」这个选项~${NC}"; sleep 1; continue ;;
        esac
        echo ""
        read -p "$(echo -e "  ${GRAY}按回车返回菜单...${NC}")" _
    done
}

main
