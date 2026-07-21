#!/bin/bash

# ===================================================================
# vps-proxy — 常用代理协议一键脚本合集入口
# 仓库: https://github.com/ridaiqianhe/vps-proxy
#
# 用法:
#   bash <(wget -qO- https://raw.githubusercontent.com/ridaiqianhe/vps-proxy/refs/heads/main/vps-proxy.sh)
# ===================================================================

REPO_RAW="https://raw.githubusercontent.com/ridaiqianhe/vps-proxy/refs/heads/main"

# --- 配色(二次元紫彩) ---
PURPLE='\e[38;5;135m'; CYAN='\e[96m'; GREEN='\e[92m'; YELLOW='\e[93m'; BLUE='\e[94m'; GRAY='\e[90m'; NC='\e[0m'

if [ "$(id -u)" != "0" ]; then
    echo -e "${PURPLE}(>_<) 需要 root 权限哦，请用 sudo -i 切换到 root 再运行~${NC}" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

fetch() {
    if command -v curl >/dev/null 2>&1; then curl -fsSL "$1"; else wget -qO- "$1"; fi
}

run_script() {
    local name="$1"
    if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/$name" ]; then
        bash "$SCRIPT_DIR/$name"
    else
        local content
        content=$(fetch "$REPO_RAW/$name")
        if [ -z "$content" ]; then
            echo -e "${PURPLE}(；´Д｀) 下载 $name 失败，检查下网络？${NC}" >&2
            return 1
        fi
        bash <(echo "$content")
    fi
}

banner() {
    clear 2>/dev/null || true
    echo ""
    echo -e "${PURPLE}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "     ${CYAN}✨ VPS-Proxy 一键脚本合集 ✨${NC}   ${YELLOW}(｡･ω･｡)ﾉ${NC}"
    echo -e "     ${GRAY}Snell · Hysteria2 · SS2022 · AnyTLS${NC}"
    echo -e "${PURPLE}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

while true; do
    banner
    echo -e "  ${GREEN}1.${NC} 🍥 Snell"
    echo -e "  ${GREEN}2.${NC} 🚀 Hysteria2"
    echo -e "  ${GREEN}3.${NC} 🧦 Shadowsocks 2022 (ss-rust)"
    echo -e "  ${GREEN}4.${NC} 🎀 AnyTLS"
    echo -e "  ${GREEN}5.${NC} ⚡ TUIC v5"
    echo -e "  ${GREEN}6.${NC} 🐴 Trojan"
    echo -e "  ${GREEN}7.${NC} 💎 VLESS+Reality"
    echo -e "  ${GREEN}8.${NC} 🛡️  Shadow-TLS v3 ${GRAY}(为已装 SS/Snell 加壳)${NC}"
    echo -e "  ${GREEN}9.${NC} ⚙️  TCP 调优 ${GRAY}(BBR + BDP 缓冲)${NC}"
    echo -e "  ${YELLOW}0.${NC} 👋 退出"
    echo ""
    read -p "$(echo -e "  ${CYAN}请输入选项 [0-9]: ${NC}")" choice

    case $choice in
        1) run_script "snell.sh" ;;
        2) run_script "hysteria2.sh" ;;
        3) run_script "ss-2022.sh" ;;
        4) run_script "anytls.sh" ;;
        5) run_script "tuic.sh" ;;
        6) run_script "trojan.sh" ;;
        7) run_script "reality.sh" ;;
        8) run_script "shadow-tls.sh" ;;
        9) run_script "tcp-tune.sh" ;;
        0) echo -e "  ${PURPLE}バイバイ~ (｡･ω･)ﾉﾞ${NC}"; exit 0 ;;
        *)
            echo -e "  ${YELLOW}(・_・?) 没有「$choice」这个选项，再选一次吧~${NC}"
            sleep 1
            continue
            ;;
    esac

    echo ""
    read -p "$(echo -e "  ${GRAY}按回车返回主菜单...${NC}")" _
done
