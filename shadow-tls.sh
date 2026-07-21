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
    if [ -f /etc/snell/snell-server.conf ]; then
        local p; p=$(get_snell_port_from_config /etc/snell/snell-server.conf)
        [ -n "$p" ] && BACKENDS+=("snell:$p")
    fi
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
    local backend_type backend_port
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
        if [ "$sel" = "$i" ]; then
            read -p "请输入后端本地端口: " backend_port
            backend_type="custom"
        else
            local chosen="${BACKENDS[$((sel-1))]}"
            backend_type="${chosen%%:*}"
            backend_port="${chosen##*:}"
        fi
    fi
    [ -z "$backend_port" ] && { log_error "未指定后端端口"; return 1; }

    command -v wget >/dev/null 2>&1 || { apt-get install -y wget 2>/dev/null || yum install -y wget 2>/dev/null; }
    download_stls || return 1

    local stls_port stls_password custom
    stls_port=$(get_random_free_port)
    read -p "$(echo -e "${CYAN}◆ 对外端口 ${GRAY}(回车用随机 ${GREEN}$stls_port${GRAY})${CYAN}: ${NC}")" custom
    [ -n "$custom" ] && stls_port=$custom

    stls_password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
    read -p "$(echo -e "${CYAN}◆ 密码 ${GRAY}(回车用随机 ${GREEN}$stls_password${GRAY})${CYAN}: ${NC}")" custom
    [ -n "$custom" ] && stls_password=$custom

    # 选 SNI 握手域名(均支持 TLS 1.3)
    local options=("gateway.icloud.com" "s0.awsstatic.com" "www.microsoft.com" "publicassets.cdn-apple.com" "swscan.apple.com")
    echo "请选择 TLS 握手域名 (默认 1):"
    for i in "${!options[@]}"; do echo "$((i+1)). ${options[$i]}"; done
    read -p "输入选项 [默认 1]: " tc; tc=${tc:-1}
    local sni="${options[0]}"
    [[ "$tc" -ge 1 && "$tc" -le "${#options[@]}" ]] && sni="${options[$((tc-1))]}"

    cat > "$SERVICE_FILE" << EOF
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

    # journald 全局磁盘上限
    if [ -f /etc/systemd/journald.conf ] && ! grep -q '^SystemMaxUse=' /etc/systemd/journald.conf; then
        echo "SystemMaxUse=200M" >> /etc/systemd/journald.conf
        systemctl restart systemd-journald 2>/dev/null || true
    fi

    # UDP 走 iptables 直接转发到后端(shadow-tls 只处理 TCP)
    if command -v iptables >/dev/null 2>&1; then
        iptables -t nat -A PREROUTING -p udp --dport "$stls_port" -j REDIRECT --to-port "$backend_port" 2>/dev/null || true
        if command -v iptables-save >/dev/null 2>&1; then
            mkdir -p /etc/iptables && iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi
    fi

    mkdir -p "$META_DIR"
    cat > "$META_FILE" << EOF
STLS_PORT=$stls_port
STLS_PASSWORD=$stls_password
SNI=$sni
BACKEND_TYPE=$backend_type
BACKEND_PORT=$backend_port
EOF
    chmod 600 "$META_FILE"

    systemctl daemon-reload
    systemctl enable shadow-tls >/dev/null 2>&1
    if ! systemctl restart shadow-tls; then
        log_error "Shadow-TLS 启动失败，请执行 journalctl -u shadow-tls 查看"; return 1
    fi
    log_info "Shadow-TLS v3 安装成功！后端: $backend_type (端口 $backend_port)"
    show_config
}

uninstall_stls() {
    if [ ! -f "$SERVICE_FILE" ]; then log_error "Shadow-TLS 未安装"; return 0; fi
    read -p "确认卸载 Shadow-TLS？[输入 yes 确认]: " a
    [ "$a" != "yes" ] && { log_info "已取消"; return 0; }

    local stls_port backend_port
    [ -f "$META_FILE" ] && { stls_port=$(grep '^STLS_PORT=' "$META_FILE" | cut -d= -f2); backend_port=$(grep '^BACKEND_PORT=' "$META_FILE" | cut -d= -f2); }

    systemctl stop shadow-tls 2>/dev/null || true
    systemctl disable shadow-tls 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$STLS_BIN"

    if [ -n "$stls_port" ] && [ -n "$backend_port" ] && command -v iptables >/dev/null 2>&1; then
        iptables -t nat -D PREROUTING -p udp --dport "$stls_port" -j REDIRECT --to-port "$backend_port" 2>/dev/null || true
        command -v iptables-save >/dev/null 2>&1 && [ -d /etc/iptables ] && iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
    rm -rf "$META_DIR"
    systemctl daemon-reload
    log_info "Shadow-TLS 已卸载(后端 SS/Snell 未受影响)"
}

show_config() {
    [ ! -f "$META_FILE" ] && { log_error "未找到配置，请先安装"; return 1; }
    local STLS_PORT STLS_PASSWORD SNI BACKEND_TYPE BACKEND_PORT host country
    STLS_PORT=$(grep '^STLS_PORT=' "$META_FILE" | cut -d= -f2)
    STLS_PASSWORD=$(grep '^STLS_PASSWORD=' "$META_FILE" | cut -d= -f2)
    SNI=$(grep '^SNI=' "$META_FILE" | cut -d= -f2)
    BACKEND_TYPE=$(grep '^BACKEND_TYPE=' "$META_FILE" | cut -d= -f2)
    BACKEND_PORT=$(grep '^BACKEND_PORT=' "$META_FILE" | cut -d= -f2)
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
        local psk ver binary_version
        psk=$(awk -F ' = ' '/psk/ {print $2}' /etc/snell/snell-server.conf 2>/dev/null)
        binary_version=$(/usr/local/bin/snell-server --version 2>/dev/null)
        case "$binary_version" in
            *v6*) ver=6 ;;
            *v5*) ver=5 ;;
            *) log_error "不支持或无法识别的 Snell 版本: ${binary_version:-无版本信息}"; return 1 ;;
        esac
        echo -e "${YELLOW}--- Surge 配置行 (Snell + Shadow-TLS) ---${NC}"
        echo "$country-snell-stls = snell, $host, $STLS_PORT, psk=$psk, version=$ver, reuse=true, shadow-tls-password=$STLS_PASSWORD, shadow-tls-sni=$SNI, shadow-tls-version=3"
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
