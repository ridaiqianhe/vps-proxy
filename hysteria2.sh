#!/bin/bash

# ===================================================================
# Hysteria2 一键安装/管理脚本
# 仓库: https://github.com/ridaiqianhe/vps-proxy
# ===================================================================

PURPLE='\e[38;5;135m'; CYAN='\e[96m'; GREEN='\e[92m'; YELLOW='\e[93m'; BLUE='\e[94m'; GRAY='\e[90m'; RED='\e[31m'; NC='\e[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${PURPLE}(>_<) 需要 root 权限哦，请用 sudo -i 切换后再运行~${NC}"
    exit 1
fi

# 判断系统及依赖安装方式
DISTRO=$(grep '^ID=' /etc/os-release | awk -F '=' '{print $2}' | tr -d '"')
case $DISTRO in
    debian|ubuntu) PACKAGE_INSTALL="apt-get install -y" ;;
    centos|fedora|rhel) PACKAGE_INSTALL="yum -y install" ;;
    *) PACKAGE_INSTALL="apt-get install -y" ;;
esac

print_config() {
    local host country port psk
    host=$(curl -s --connect-timeout 10 http://checkip.amazonaws.com)
    country=$(curl -s --connect-timeout 5 "http://ipinfo.io/$host/country" | tr -d '\n')
    port=$(grep 'listen:' /etc/hysteria/config.yaml | awk '{print $2}' | cut -d':' -f2)
    psk=$(grep 'password:' /etc/hysteria/config.yaml | awk '{print $2}' | tr -d '"')
    [ -z "$country" ] && country="XX"

    echo ""
    echo -e "${CYAN}============= Hysteria2 配置信息 =============${NC}"
    echo -e "${YELLOW}--- Surge 配置行 ---${NC}"
    echo "$country = hysteria2, $host, $port, password=$psk, skip-cert-verify=true, sni=www.bing.com"
    echo ""
    echo -e "${YELLOW}--- mihomo(clash-meta) 出站片段 ---${NC}"
    cat << EOF
  - name: $country-hy2
    type: hysteria2
    server: $host
    port: $port
    password: "$psk"
    alpn:
      - h3
    sni: www.bing.com
    skip-cert-verify: true
    fast-open: true
EOF
    echo -e "${CYAN}=============================================${NC}"
    echo ""
}

install_hy2() {
    $PACKAGE_INSTALL unzip wget curl openssl
    bash <(curl -fsSL https://get.hy2.sh/)

    # 自签证书
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt \
        -subj "/CN=bing.com" -days 36500
    chown hysteria /etc/hysteria/server.key /etc/hysteria/server.crt 2>/dev/null || true

    # 端口与密码: 回车即随机
    local port psk custom
    port=$(shuf -i 2000-65000 -n 1)
    read -p "$(echo -e "${CYAN}◆ 端口 ${GRAY}(回车用随机 ${GREEN}$port${GRAY})${CYAN}: ${NC}")" custom
    [ -n "$custom" ] && port=$custom
    psk=$(openssl rand -base64 12)
    read -p "$(echo -e "${CYAN}◆ 密码 ${GRAY}(回车用随机 ${GREEN}$psk${GRAY})${CYAN}: ${NC}")" custom
    [ -n "$custom" ] && psk=$custom

    cat > /etc/hysteria/config.yaml << EOF
listen: :$port

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: "$psk"

masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true
EOF

    systemctl start hysteria-server.service
    systemctl enable hysteria-server.service
    echo -e "${GREEN}✓ Hysteria2 已安装并启动！${NC}"
    print_config
}

uninstall_hy2() {
    read -p "$(echo -e "${YELLOW}确认卸载 Hysteria2？[输入 yes 确认]: ${NC}")" a
    [ "$a" != "yes" ] && { echo "已取消"; return 0; }
    systemctl stop hysteria-server.service 2>/dev/null || true
    systemctl disable hysteria-server.service 2>/dev/null || true
    rm -f /etc/systemd/system/hysteria-server.service
    rm -rf /etc/hysteria
    bash <(curl -fsSL https://get.hy2.sh/) --remove
    echo -e "${GREEN}✓ Hysteria2 已卸载${NC}"
}

view_hy2() {
    if [ -f /etc/hysteria/config.yaml ]; then
        print_config
    else
        echo -e "${YELLOW}(・_・) 配置文件不存在，请先安装 Hysteria2~${NC}"
    fi
}

show_status() {
    if systemctl is-active --quiet hysteria-server 2>/dev/null; then
        echo -e "${GREEN}✓ Hysteria2 服务: 运行中${NC}"
    elif [ -f /etc/hysteria/config.yaml ]; then
        echo -e "${YELLOW}⚠ Hysteria2 服务: 已安装但未运行${NC}"
    else
        echo -e "${RED}✗ Hysteria2 服务: 未安装${NC}"
    fi
}

while true; do
    clear 2>/dev/null || true
    echo ""
    echo -e "${PURPLE}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "     ${CYAN}🚀 Hysteria2 管理脚本 🚀${NC}   ${YELLOW}(๑•̀ㅂ•́)و${NC}"
    echo -e "     ${GRAY}嗖的一下就上网~${NC}"
    echo -e "${PURPLE}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -n "  "; show_status
    echo ""
    echo -e "  ${GREEN}1.${NC} 🚀 安装 Hysteria2"
    echo -e "  ${GREEN}2.${NC} 🗑️  卸载 Hysteria2"
    echo -e "  ${GREEN}3.${NC} 📋 查看配置"
    echo -e "  ${YELLOW}0.${NC} 👋 退出"
    echo ""
    read -p "$(echo -e "  ${CYAN}请输入选项 [0-3]: ${NC}")" OPTION

    case $OPTION in
        1) install_hy2 ;;
        2) uninstall_hy2 ;;
        3) view_hy2 ;;
        0) echo -e "  ${PURPLE}バイバイ~ (｡･ω･)ﾉﾞ${NC}"; exit 0 ;;
        *) echo -e "  ${YELLOW}(・_・?) 没有「$OPTION」这个选项~${NC}"; sleep 1; continue ;;
    esac

    echo ""
    read -p "$(echo -e "  ${GRAY}按回车返回菜单...${NC}")" _
done
