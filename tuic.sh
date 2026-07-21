#!/bin/bash

# ===================================================================
# TUIC v5 一键安装/管理脚本 (基于官方 EAimTY/tuic-server, 自签证书)
# 仓库: https://github.com/ridaiqianhe/vps-proxy
# 上游: https://github.com/EAimTY/tuic
# ===================================================================

# 不用 set -e: 交互菜单脚本,单次操作失败应回菜单

RED='\e[31m'; GREEN='\e[92m'; YELLOW='\e[93m'; BLUE='\e[94m'; CYAN='\e[96m'; PURPLE='\e[38;5;135m'; GRAY='\e[90m'; NC='\e[0m'

BIN_PATH="/usr/local/bin/tuic-server"
CONF_DIR="/etc/tuic"
CONF_FILE="$CONF_DIR/config.toml"
CERT_FILE="$CONF_DIR/server.crt"
KEY_FILE="$CONF_DIR/server.key"
META_FILE="$CONF_DIR/meta.env"
SERVICE_FILE="/etc/systemd/system/tuic.service"
GH_REPO="EAimTY/tuic"
DEFAULT_SNI="www.bing.com"
TEMP_DIR="$(mktemp -d /tmp/tuic_install.XXXXXX)"
trap 'rm -rf "$TEMP_DIR"' EXIT

log_info()  { echo -e "${GREEN}[INFO] $1${NC}" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN] $1${NC}" >&2; }
log_error() { echo -e "${RED}[ERROR] $1${NC}" >&2; }

[ "$(id -u)" != "0" ] && { log_error "请以 root 权限运行此脚本"; exit 1; }

detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then PKG_INSTALL="apt-get install -y"
    elif command -v dnf >/dev/null 2>&1; then PKG_INSTALL="dnf install -y"
    elif command -v yum >/dev/null 2>&1; then PKG_INSTALL="yum install -y"
    else log_error "未找到受支持的包管理器"; return 1; fi
}

# 架构 -> 官方二进制后缀(musl 静态链接,兼容性最好)
get_arch_suffix() {
    case "$(uname -m)" in
        x86_64)  echo "x86_64-unknown-linux-musl" ;;
        aarch64) echo "aarch64-unknown-linux-musl" ;;
        armv7l)  echo "armv7-unknown-linux-musleabihf" ;;
        *) log_error "TUIC 官方二进制不支持当前架构: $(uname -m)"; return 1 ;;
    esac
}

# 取最新的 tuic-server 发布 tag(形如 tuic-server-1.0.0)
get_server_tag() {
    local tag
    tag=$(curl -s --connect-timeout 10 "https://api.github.com/repos/$GH_REPO/releases?per_page=30" \
        | grep -o '"tag_name": *"tuic-server-[^"]*"' | head -1 | cut -d'"' -f4)
    [ -z "$tag" ] && tag="tuic-server-1.0.0"
    echo "$tag"
}

get_random_free_port() {
    local port=""
    for _ in $(seq 1 20); do
        port=$(shuf -i 20000-60000 -n 1)
        ss -tuln 2>/dev/null | grep -q ":$port " || { echo "$port"; return 0; }
    done
    echo "$port"
}

gen_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then cat /proc/sys/kernel/random/uuid
    else openssl rand -hex 16 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/'; fi
}

get_host_ip() {
    local ip
    ip=$(curl -s --connect-timeout 10 http://checkip.amazonaws.com 2>/dev/null)
    [ -z "$ip" ] && ip=$(curl -s --connect-timeout 5 https://ipinfo.io/ip 2>/dev/null)
    echo "$ip"
}

install_tuic() {
    detect_pkg_manager || return 1
    $PKG_INSTALL wget curl openssl >/dev/null 2>&1

    local suffix tag url
    suffix=$(get_arch_suffix) || return 1
    tag=$(get_server_tag)
    url="https://github.com/$GH_REPO/releases/download/$tag/${tag}-${suffix}"

    log_info "下载 $tag ($suffix)..."
    if ! wget -q "$url" -O "$TEMP_DIR/tuic-server"; then log_error "下载失败: $url"; return 1; fi
    install -m 755 "$TEMP_DIR/tuic-server" "$BIN_PATH"

    mkdir -p "$CONF_DIR"

    local port uuid password sni custom
    port=$(get_random_free_port)
    read -p "$(echo -e "${CYAN}◆ 端口 ${GRAY}(回车用随机 ${GREEN}$port${GRAY})${CYAN}: ${NC}")" custom
    [ -n "$custom" ] && port=$custom

    uuid=$(gen_uuid)
    password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)
    read -p "$(echo -e "${CYAN}◆ 密码 ${GRAY}(回车用随机 ${GREEN}$password${GRAY})${CYAN}: ${NC}")" custom
    [ -n "$custom" ] && password=$custom

    sni=$DEFAULT_SNI
    read -p "$(echo -e "${CYAN}◆ SNI 伪装域名 ${GRAY}(回车用 ${GREEN}$sni${GRAY})${CYAN}: ${NC}")" custom
    [ -n "$custom" ] && sni=$custom

    log_info "生成自签证书 (CN=$sni)..."
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=$sni" -days 36500 2>/dev/null
    chmod 600 "$KEY_FILE"

    cat > "$CONF_FILE" << EOF
server = "[::]:$port"

[users]
$uuid = "$password"

certificate = "$CERT_FILE"
private_key = "$KEY_FILE"

congestion_control = "bbr"
alpn = ["h3"]
zero_rtt_handshake = false
log_level = "warn"
EOF
    chmod 600 "$CONF_FILE"

    cat > "$META_FILE" << EOF
PORT=$port
UUID=$uuid
PASSWORD=$password
SNI=$sni
EOF
    chmod 600 "$META_FILE"

    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=TUIC v5 Server Service
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
ExecStart=$BIN_PATH -c $CONF_FILE
StandardOutput=journal
StandardError=journal
SyslogIdentifier=tuic
LogRateLimitIntervalSec=30
LogRateLimitBurst=200
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    if [ -f /etc/systemd/journald.conf ] && ! grep -q '^SystemMaxUse=' /etc/systemd/journald.conf; then
        echo "SystemMaxUse=200M" >> /etc/systemd/journald.conf
        systemctl restart systemd-journald 2>/dev/null || true
    fi

    systemctl daemon-reload
    systemctl enable tuic >/dev/null 2>&1
    if ! systemctl restart tuic; then
        log_error "TUIC 启动失败，请执行 journalctl -u tuic 查看"; return 1
    fi
    log_info "TUIC v5 安装成功！"
    show_config
}

uninstall_tuic() {
    if [ ! -f "$SERVICE_FILE" ]; then log_error "TUIC 未安装"; return 0; fi
    read -p "$(echo -e "${YELLOW}确认卸载 TUIC？[输入 yes 确认]: ${NC}")" a
    [ "$a" != "yes" ] && { log_info "已取消"; return 0; }
    systemctl stop tuic 2>/dev/null || true
    systemctl disable tuic 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$BIN_PATH"
    rm -rf "$CONF_DIR"
    systemctl daemon-reload
    log_info "TUIC 已卸载"
}

show_config() {
    [ ! -f "$META_FILE" ] && { log_error "未找到配置,请先安装"; return 1; }
    local PORT UUID PASSWORD SNI host country
    PORT=$(grep '^PORT=' "$META_FILE" | cut -d= -f2)
    UUID=$(grep '^UUID=' "$META_FILE" | cut -d= -f2)
    PASSWORD=$(grep '^PASSWORD=' "$META_FILE" | cut -d= -f2)
    SNI=$(grep '^SNI=' "$META_FILE" | cut -d= -f2)
    host=$(get_host_ip); [ -z "$host" ] && host="YOUR_SERVER_IP"
    country=$(curl -s --connect-timeout 5 "http://ipinfo.io/$host/country" 2>/dev/null | tr -d '\n'); [ -z "$country" ] && country="XX"

    echo ""
    echo -e "${CYAN}=============== TUIC v5 配置信息 ===============${NC}"
    echo -e "${BLUE}地址: $host   端口: $PORT${NC}"
    echo -e "${BLUE}UUID: $UUID${NC}"
    echo -e "${BLUE}密码: $PASSWORD   SNI: $SNI (自签证书,需允许不安全)${NC}"
    echo ""
    echo -e "${YELLOW}--- Surge 配置行 (TUIC v5) ---${NC}"
    echo "$country-tuic = tuic, $host, $PORT, uuid=$UUID, password=$PASSWORD, sni=$SNI, alpn=h3, skip-cert-verify=true"
    echo ""
    echo -e "${YELLOW}--- mihomo(clash-meta) 出站片段 ---${NC}"
    cat << EOF
  - name: $country-tuic
    type: tuic
    server: $host
    port: $PORT
    uuid: $UUID
    password: "$PASSWORD"
    alpn: [h3]
    congestion-controller: bbr
    sni: $SNI
    skip-cert-verify: true
    udp-relay-mode: native
EOF
    echo -e "${CYAN}===============================================${NC}"
    echo ""
}

show_status() {
    if systemctl is-active --quiet tuic 2>/dev/null; then
        echo -e "${GREEN}✓ TUIC 服务: 运行中${NC}"
    elif [ -f "$SERVICE_FILE" ]; then
        echo -e "${YELLOW}⚠ TUIC 服务: 已安装但未运行${NC}"
    else
        echo -e "${RED}✗ TUIC 服务: 未安装${NC}"
    fi
}

main() {
    while true; do
        clear 2>/dev/null || true
        echo ""
        echo -e "${PURPLE}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "     ${CYAN}⚡ TUIC v5 管理脚本 ⚡${NC}   ${YELLOW}(๑•̀ㅂ•́)و${NC}"
        echo -e "     ${GRAY}QUIC 加速 · 自签证书${NC}"
        echo -e "${PURPLE}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -n "  "; show_status
        echo ""
        echo -e "  ${GREEN}1.${NC} ⚡ 安装 TUIC"
        echo -e "  ${GREEN}2.${NC} 🗑️  卸载 TUIC"
        echo -e "  ${GREEN}3.${NC} 📋 查看配置"
        echo -e "  ${YELLOW}0.${NC} 👋 退出"
        echo ""
        read -p "$(echo -e "  ${CYAN}请输入选项 [0-3]: ${NC}")" choice
        case $choice in
            1) install_tuic ;;
            2) uninstall_tuic ;;
            3) show_config ;;
            0) echo -e "  ${PURPLE}バイバイ~ (｡･ω･)ﾉﾞ${NC}"; exit 0 ;;
            *) echo -e "  ${YELLOW}(・_・?) 没有「$choice」这个选项~${NC}"; sleep 1; continue ;;
        esac
        echo ""
        read -p "$(echo -e "  ${GRAY}按回车返回菜单...${NC}")" _
    done
}

main
