#!/bin/bash

# ===================================================================
# AnyTLS 一键安装/管理脚本 (基于官方 anytls/anytls-go 发布二进制)
# 仓库: https://github.com/ridaiqianhe/vps-proxy
# 协议源: https://github.com/anytls/anytls-go
# ===================================================================

# 不用 set -e: 这是交互式菜单脚本,某个操作失败应回到菜单而不是整体退出
# 真正致命的错误在各函数里用 return/显式判断处理

RED='\e[31m'
GREEN='\e[92m'
YELLOW='\e[93m'
BLUE='\e[94m'
CYAN='\e[96m'
PURPLE='\e[38;5;135m'
GRAY='\e[90m'
NC='\e[0m'

INSTALL_DIR="/usr/local/bin"
BIN_PATH="$INSTALL_DIR/anytls-server"
CONF_DIR="/etc/anytls"
CONF_FILE="$CONF_DIR/config.env"
SERVICE_FILE="/etc/systemd/system/anytls.service"
GH_REPO="anytls/anytls-go"
TEMP_DIR="$(mktemp -d /tmp/anytls_install.XXXXXX)"

trap 'rm -rf "$TEMP_DIR"' EXIT

log_info()  { echo -e "${GREEN}[INFO] $1${NC}" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN] $1${NC}" >&2; }
log_error() { echo -e "${RED}[ERROR] $1${NC}" >&2; }

if [ "$(id -u)" != "0" ]; then
    log_error "请以 root 权限运行此脚本"
    exit 1
fi

# 检测包管理器
detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_INSTALL="apt-get install -y"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_INSTALL="dnf install -y"
    elif command -v yum >/dev/null 2>&1; then
        PKG_INSTALL="yum install -y"
    else
        log_error "未找到受支持的包管理器 (apt/dnf/yum)"
        exit 1
    fi
}

# 架构 -> 官方发布产物后缀
get_arch_tag() {
    case "$(uname -m)" in
        x86_64)  echo "linux_amd64" ;;
        aarch64) echo "linux_arm64" ;;
        *)
            log_error "AnyTLS 官方二进制暂不支持当前架构: $(uname -m)"
            exit 1
            ;;
    esac
}

# 获取最新版本号 (去掉前导 v)
get_latest_version() {
    local tag
    tag=$(curl -s --connect-timeout 10 --max-time 30 \
        "https://api.github.com/repos/$GH_REPO/releases/latest" \
        | grep -o '"tag_name": *"[^"]*"' | cut -d'"' -f4)
    echo "${tag#v}"
}

# 生成未被占用的随机端口
get_random_free_port() {
    local port=""
    for _ in $(seq 1 20); do
        port=$(shuf -i 30000-65000 -n 1)
        if ! ss -tuln 2>/dev/null | grep -q ":$port "; then
            echo "$port"; return 0
        fi
    done
    echo "$port"
}

get_host_ip() {
    local ip
    ip=$(curl -s --connect-timeout 10 http://checkip.amazonaws.com 2>/dev/null)
    [ -z "$ip" ] && ip=$(curl -s --connect-timeout 5 https://ipinfo.io/ip 2>/dev/null)
    echo "$ip"
}

install_anytls() {
    log_info "开始安装 AnyTLS 服务器"
    detect_pkg_manager
    $PKG_INSTALL unzip wget curl >/dev/null 2>&1 || { log_error "依赖安装失败"; return 1; }

    local version arch_tag url zip
    version=$(get_latest_version)
    if [ -z "$version" ]; then
        version="0.0.13"
        log_warn "无法获取最新版本，使用默认 $version"
    fi
    arch_tag=$(get_arch_tag)
    url="https://github.com/$GH_REPO/releases/download/v${version}/anytls_${version}_${arch_tag}.zip"
    zip="$TEMP_DIR/anytls.zip"

    log_info "下载 AnyTLS v$version ($arch_tag)..."
    if ! wget -q "$url" -O "$zip"; then
        log_error "下载失败: $url"
        return 1
    fi
    if ! unzip -tq "$zip" >/dev/null 2>&1; then
        log_error "下载的压缩包损坏"
        return 1
    fi

    unzip -oq "$zip" -d "$TEMP_DIR"
    if [ ! -f "$TEMP_DIR/anytls-server" ]; then
        log_error "压缩包中未找到 anytls-server"
        return 1
    fi
    install -m 755 "$TEMP_DIR/anytls-server" "$BIN_PATH"

    # 端口与密码: 直接回车 = 用随机值，想改就输入
    local port password custom
    port=$(get_random_free_port)
    read -p "$(echo -e "${CYAN}◆ 端口 ${GRAY}(回车用随机 ${GREEN}$port${GRAY})${CYAN}: ${NC}")" custom
    [ -n "$custom" ] && port=$custom

    password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 24)
    read -p "$(echo -e "${CYAN}◆ 密码 ${GRAY}(回车用随机 ${GREEN}$password${GRAY})${CYAN}: ${NC}")" custom
    [ -n "$custom" ] && password=$custom

    mkdir -p "$CONF_DIR"
    cat > "$CONF_FILE" << EOF
ANYTLS_PORT=$port
ANYTLS_PASSWORD=$password
EOF
    chmod 600 "$CONF_FILE"

    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=AnyTLS Server Service
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
EnvironmentFile=$CONF_FILE
ExecStart=$BIN_PATH -l 0.0.0.0:\${ANYTLS_PORT} -p \${ANYTLS_PASSWORD}
StandardOutput=journal
StandardError=journal
SyslogIdentifier=anytls
LogRateLimitIntervalSec=30
LogRateLimitBurst=200
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    # journald 全局磁盘上限，防止日志写爆磁盘
    if [ -f /etc/systemd/journald.conf ] && ! grep -q '^SystemMaxUse=' /etc/systemd/journald.conf; then
        echo "SystemMaxUse=200M" >> /etc/systemd/journald.conf
        systemctl restart systemd-journald 2>/dev/null || true
    fi

    systemctl daemon-reload
    systemctl enable anytls >/dev/null 2>&1
    if ! systemctl restart anytls; then
        log_error "AnyTLS 服务启动失败，请执行 journalctl -u anytls 查看"
        return 1
    fi

    log_info "AnyTLS v$version 安装成功！"
    show_config
}

uninstall_anytls() {
    if ! systemctl list-units --type=service --all | grep -q "anytls.service"; then
        log_error "AnyTLS 未安装"
        return 0
    fi
    read -p "确认卸载 AnyTLS？将删除全部相关文件 [输入 yes 确认]: " ans
    [ "$ans" != "yes" ] && { log_info "已取消"; return 0; }

    systemctl stop anytls 2>/dev/null || true
    systemctl disable anytls 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$BIN_PATH"
    rm -rf "$CONF_DIR"
    systemctl daemon-reload
    log_info "AnyTLS 已卸载"
}

show_config() {
    if [ ! -f "$CONF_FILE" ]; then
        log_error "未找到配置文件，请先安装"
        return 1
    fi
    # shellcheck disable=SC1090
    local ANYTLS_PORT ANYTLS_PASSWORD host country
    ANYTLS_PORT=$(grep '^ANYTLS_PORT=' "$CONF_FILE" | cut -d= -f2)
    ANYTLS_PASSWORD=$(grep '^ANYTLS_PASSWORD=' "$CONF_FILE" | cut -d= -f2)
    host=$(get_host_ip)
    [ -z "$host" ] && host="YOUR_SERVER_IP"
    country=$(curl -s --connect-timeout 5 "http://ipinfo.io/$host/country" 2>/dev/null | tr -d '\n')
    [ -z "$country" ] && country="XX"

    echo ""
    echo -e "${CYAN}==================== AnyTLS 配置信息 ====================${NC}"
    echo -e "${BLUE}地址(server): $host${NC}"
    echo -e "${BLUE}端口(port):   $ANYTLS_PORT${NC}"
    echo -e "${BLUE}密码(psk):    $ANYTLS_PASSWORD${NC}"
    echo ""
    echo -e "${YELLOW}--- Surge 配置行 ---${NC}"
    echo "$country-anytls = anytls, $host, $ANYTLS_PORT, password=$ANYTLS_PASSWORD, skip-cert-verify=true"
    echo ""
    echo -e "${YELLOW}--- sing-box / mihomo(clash-meta) 出站片段 ---${NC}"
    cat << EOF
  - name: $country-anytls
    type: anytls
    server: $host
    port: $ANYTLS_PORT
    password: "$ANYTLS_PASSWORD"
    skip-cert-verify: true
    udp: true
EOF
    echo -e "${YELLOW}--- anytls URI ---${NC}"
    echo "anytls://${ANYTLS_PASSWORD}@${host}:${ANYTLS_PORT}/?insecure=1#${country}-anytls"
    echo -e "${CYAN}=======================================================${NC}"
    echo ""
}

show_status() {
    if systemctl is-active --quiet anytls 2>/dev/null; then
        echo -e "${GREEN}✓ AnyTLS 服务: 运行中${NC}"
    elif [ -f "$SERVICE_FILE" ]; then
        echo -e "${YELLOW}⚠ AnyTLS 服务: 已安装但未运行${NC}"
    else
        echo -e "${RED}✗ AnyTLS 服务: 未安装${NC}"
    fi
}

main() {
    while true; do
        clear 2>/dev/null || true
        echo ""
        echo -e "${PURPLE}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "     ${CYAN}🎀 AnyTLS 管理脚本 🎀${NC}   ${YELLOW}(๑•̀ㅂ•́)و✧${NC}"
        echo -e "${PURPLE}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -n "  "; show_status
        echo ""
        echo -e "  ${GREEN}1.${NC} 🎀 安装 AnyTLS"
        echo -e "  ${GREEN}2.${NC} 🗑️  卸载 AnyTLS"
        echo -e "  ${GREEN}3.${NC} 📋 查看配置"
        echo -e "  ${YELLOW}0.${NC} 👋 退出"
        echo ""
        read -p "$(echo -e "  ${CYAN}请输入选项 [0-3]: ${NC}")" choice
        case $choice in
            1) install_anytls ;;
            2) uninstall_anytls ;;
            3) show_config ;;
            0) echo -e "  ${PURPLE}バイバイ~ (｡･ω･)ﾉﾞ${NC}"; exit 0 ;;
            *) echo -e "  ${YELLOW}(・_・?) 没有「$choice」这个选项~${NC}"; sleep 1; continue ;;
        esac
        echo ""
        read -p "$(echo -e "  ${GRAY}按回车返回菜单...${NC}")" _
    done
}

main
