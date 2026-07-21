#!/bin/bash

# ===================================================================
# VLESS + Vision + REALITY 一键安装/管理脚本 (基于官方 Xray-core)
# 仓库: https://github.com/ridaiqianhe/vps-proxy
# 上游: https://github.com/XTLS/Xray-core  安装器: XTLS/Xray-install
# ===================================================================

# 不用 set -e: 交互菜单脚本,单次操作失败应回菜单

RED='\e[31m'; GREEN='\e[92m'; YELLOW='\e[93m'; BLUE='\e[94m'; CYAN='\e[96m'; PURPLE='\e[38;5;135m'; GRAY='\e[90m'; NC='\e[0m'

XRAY_BIN="/usr/local/bin/xray"
CONF_FILE="/usr/local/etc/xray/config.json"
META_FILE="/usr/local/etc/xray/reality-meta.env"
INSTALLER="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
DEFAULT_SNI="aws.amazon.com"

log_info()  { echo -e "${GREEN}[INFO] $1${NC}" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN] $1${NC}" >&2; }
log_error() { echo -e "${RED}[ERROR] $1${NC}" >&2; }

[ "$(id -u)" != "0" ] && { log_error "请以 root 权限运行此脚本"; exit 1; }

get_host_ip() {
    local ip
    ip=$(curl -s --connect-timeout 10 http://checkip.amazonaws.com 2>/dev/null)
    [ -z "$ip" ] && ip=$(curl -s --connect-timeout 5 https://ipinfo.io/ip 2>/dev/null)
    echo "$ip"
}

install_reality() {
    command -v curl >/dev/null 2>&1 || { apt-get install -y curl 2>/dev/null || yum install -y curl 2>/dev/null; }

    # 1. 安装 Xray 官方二进制(已装则升级)
    log_info "安装/更新 Xray-core (官方脚本)..."
    if ! bash -c "$(curl -L "$INSTALLER")" @ install; then
        log_error "Xray 安装失败"; return 1
    fi
    [ -x "$XRAY_BIN" ] || { log_error "未找到 xray 可执行文件"; return 1; }

    # 2. 端口: 默认 443(Reality 推荐,伪装成 HTTPS)。
    #    无论回车用默认还是手输,都当场检测占用,被占用就重选,直到选到空闲端口。
    local port sni custom
    port=443
    while true; do
        read -p "$(echo -e "${CYAN}◆ 端口 ${GRAY}(回车用 ${GREEN}$port${GRAY}, Reality 推荐 443)${CYAN}: ${NC}")" custom
        [ -n "$custom" ] && port=$custom
        if ss -tuln 2>/dev/null | grep -q ":$port "; then
            log_warn "端口 $port 已被占用,请换一个"
            port=$(shuf -i 20000-60000 -n 1)   # 下一轮默认给个随机空闲端口
            continue
        fi
        log_info "使用端口: $port"
        break
    done

    # 3. 偷握手的目标网站(需支持 TLS1.3 + H2)
    local options=("aws.amazon.com" "www.microsoft.com" "www.apple.com" "dl.google.com" "www.cloudflare.com")
    echo "请选择 Reality 伪装(偷握手)的目标网站 (默认 1):" >&2
    for i in "${!options[@]}"; do echo "$((i+1)). ${options[$i]}" >&2; done
    read -p "$(echo -e "${CYAN}输入选项 [默认 1]: ${NC}")" tc; tc=${tc:-1}
    sni="${options[0]}"
    [[ "$tc" -ge 1 && "$tc" -le "${#options[@]}" ]] && sni="${options[$((tc-1))]}"

    # 4. 生成 UUID / x25519 密钥对 / shortId
    local uuid keypair private public shortid
    uuid=$("$XRAY_BIN" uuid)
    keypair=$("$XRAY_BIN" x25519)
    private=$(echo "$keypair" | grep -iE 'private' | awk -F': ' '{print $2}' | tr -d '[:space:]')
    public=$(echo "$keypair" | grep -iE 'public|password' | awk -F': ' '{print $2}' | tr -d '[:space:]')
    shortid=$(openssl rand -hex 8 2>/dev/null || echo "0123456789abcdef")

    if [ -z "$private" ] || [ -z "$public" ]; then
        log_error "x25519 密钥生成失败"; return 1
    fi

    # 4b. 后量子加固(默认开;客户端需较新版本,连不上可重装时答 n 关掉)
    local use_enc use_mldsa vout mout
    local enc_decryption="none" enc_encryption="" mldsa_seed="" mldsa_verify=""
    read -p "$(echo -e "${CYAN}启用 VLESS Encryption 后量子加密? ${GRAY}[Y/n] 回车开${CYAN}: ${NC}")" use_enc; use_enc=${use_enc:-Y}
    if [[ $use_enc =~ ^[Yy]$ ]]; then
        vout=$("$XRAY_BIN" vlessenc 2>/dev/null)
        # 取"后量子(ML-KEM-768)"那一组: 输出中第二组,用 tail -1
        enc_decryption=$(echo "$vout" | grep '"decryption"' | tail -1 | cut -d'"' -f4)
        enc_encryption=$(echo "$vout" | grep '"encryption"' | tail -1 | cut -d'"' -f4)
        if [ -z "$enc_decryption" ]; then
            log_warn "vlessenc 生成失败,本次不启用 VLESS Encryption"
            enc_decryption="none"; enc_encryption=""
        fi
    fi
    read -p "$(echo -e "${CYAN}启用 ML-DSA-65 后量子 Reality 签名? ${GRAY}[Y/n] 回车开${CYAN}: ${NC}")" use_mldsa; use_mldsa=${use_mldsa:-Y}
    if [[ $use_mldsa =~ ^[Yy]$ ]]; then
        mout=$("$XRAY_BIN" mldsa65 2>/dev/null)
        mldsa_seed=$(echo "$mout" | grep -i 'Seed' | awk '{print $NF}' | tr -d '[:space:]')
        mldsa_verify=$(echo "$mout" | grep -i 'Verify' | awk '{print $NF}' | tr -d '[:space:]')
        [ -z "$mldsa_seed" ] && { log_warn "mldsa65 生成失败,本次不启用"; mldsa_seed=""; mldsa_verify=""; }
    fi

    # 组装可选字段(为空则不写进配置)
    local mldsa_line=""
    [ -n "$mldsa_seed" ] && mldsa_line="\"mldsa65Seed\": \"$mldsa_seed\","

    # 5. 写配置
    cat > "$CONF_FILE" << EOF
{
    "log": { "loglevel": "warning" },
    "inbounds": [
        {
            "listen": "0.0.0.0",
            "port": $port,
            "protocol": "vless",
            "settings": {
                "clients": [
                    { "id": "$uuid", "flow": "xtls-rprx-vision" }
                ],
                "decryption": "$enc_decryption"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "dest": "$sni:443",
                    "serverNames": ["$sni"],
                    $mldsa_line
                    "privateKey": "$private",
                    "shortIds": ["", "$shortid"]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"],
                "routeOnly": true
            }
        }
    ],
    "outbounds": [
        { "protocol": "freedom", "tag": "direct" }
    ]
}
EOF

    cat > "$META_FILE" << EOF
PORT=$port
UUID=$uuid
PUBLIC_KEY=$public
SHORT_ID=$shortid
SNI=$sni
ENCRYPTION=$enc_encryption
MLDSA_VERIFY=$mldsa_verify
EOF
    chmod 600 "$META_FILE"

    systemctl restart xray
    sleep 1
    if ! systemctl is-active --quiet xray; then
        log_error "Xray 启动失败，请执行 journalctl -u xray 查看"; return 1
    fi
    log_info "VLESS+Reality 安装成功！"
    show_config
}

uninstall_reality() {
    read -p "$(echo -e "${YELLOW}确认卸载 Xray(含 Reality)？[输入 yes 确认]: ${NC}")" a
    [ "$a" != "yes" ] && { log_info "已取消"; return 0; }
    bash -c "$(curl -L "$INSTALLER")" @ remove --purge
    rm -f "$META_FILE"
    log_info "Xray 已卸载"
}

show_config() {
    [ ! -f "$META_FILE" ] && { log_error "未找到配置,请先安装"; return 1; }
    local PORT UUID PUBLIC_KEY SHORT_ID SNI ENCRYPTION MLDSA_VERIFY host country
    PORT=$(grep '^PORT=' "$META_FILE" | cut -d= -f2)
    UUID=$(grep '^UUID=' "$META_FILE" | cut -d= -f2)
    PUBLIC_KEY=$(grep '^PUBLIC_KEY=' "$META_FILE" | cut -d= -f2)
    SHORT_ID=$(grep '^SHORT_ID=' "$META_FILE" | cut -d= -f2)
    SNI=$(grep '^SNI=' "$META_FILE" | cut -d= -f2)
    ENCRYPTION=$(grep '^ENCRYPTION=' "$META_FILE" | cut -d= -f2-)
    MLDSA_VERIFY=$(grep '^MLDSA_VERIFY=' "$META_FILE" | cut -d= -f2-)
    host=$(get_host_ip); [ -z "$host" ] && host="YOUR_SERVER_IP"
    country=$(curl -s --connect-timeout 5 "http://ipinfo.io/$host/country" 2>/dev/null | tr -d '\n'); [ -z "$country" ] && country="XX"

    # 分享链接的 encryption 参数: 启用后量子加密则用密文串,否则 none
    local uri_enc="none"
    [ -n "$ENCRYPTION" ] && uri_enc="$ENCRYPTION"

    echo ""
    echo -e "${CYAN}=========== VLESS + Reality 配置信息 ===========${NC}"
    echo -e "${BLUE}地址: $host   端口: $PORT${NC}"
    echo -e "${BLUE}UUID: $UUID${NC}"
    echo -e "${BLUE}公钥(pbk): $PUBLIC_KEY${NC}"
    echo -e "${BLUE}shortId(sid): $SHORT_ID   SNI/dest: $SNI${NC}"
    echo -e "${BLUE}flow: xtls-rprx-vision   fingerprint: chrome${NC}"
    if [ -n "$ENCRYPTION" ]; then
        echo -e "${GREEN}✓ VLESS Encryption 后量子加密: 已启用${NC}"
    fi
    if [ -n "$MLDSA_VERIFY" ]; then
        echo -e "${GREEN}✓ ML-DSA-65 后量子签名: 已启用${NC}"
        echo -e "${GRAY}  客户端 mldsa65Verify: $MLDSA_VERIFY${NC}"
    fi
    echo ""
    echo -e "${YELLOW}--- VLESS Reality 分享链接 ---${NC}"
    echo "vless://${UUID}@${host}:${PORT}?encryption=${uri_enc}&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${country}-reality"
    echo ""
    echo -e "${YELLOW}--- mihomo(clash-meta) 出站片段 ---${NC}"
    cat << EOF
  - name: $country-reality
    type: vless
    server: $host
    port: $PORT
    uuid: $UUID
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: $SNI
    client-fingerprint: chrome
    reality-opts:
      public-key: $PUBLIC_KEY
      short-id: "$SHORT_ID"
EOF
    [ -n "$ENCRYPTION" ] && echo "    encryption: \"$ENCRYPTION\""
    [ -n "$MLDSA_VERIFY" ] && echo "      mldsa65Verify: \"$MLDSA_VERIFY\""
    echo -e "${CYAN}===============================================${NC}"
    echo ""
}

show_status() {
    if systemctl is-active --quiet xray 2>/dev/null; then
        echo -e "${GREEN}✓ Xray/Reality 服务: 运行中${NC}"
    elif [ -x "$XRAY_BIN" ]; then
        echo -e "${YELLOW}⚠ Xray 已安装但未运行${NC}"
    else
        echo -e "${RED}✗ Xray/Reality: 未安装${NC}"
    fi
}

main() {
    while true; do
        clear 2>/dev/null || true
        echo ""
        echo -e "${PURPLE}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "     ${CYAN}💎 VLESS + Reality 管理 💎${NC}   ${YELLOW}(๑•̀ㅂ•́)و✧${NC}"
        echo -e "     ${GRAY}抗封锁天花板 · 无需域名证书${NC}"
        echo -e "${PURPLE}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -n "  "; show_status
        echo ""
        echo -e "  ${GREEN}1.${NC} 💎 安装 VLESS+Reality"
        echo -e "  ${GREEN}2.${NC} 🗑️  卸载 (含 Xray)"
        echo -e "  ${GREEN}3.${NC} 📋 查看配置"
        echo -e "  ${YELLOW}0.${NC} 👋 退出"
        echo ""
        read -p "$(echo -e "  ${CYAN}请输入选项 [0-3]: ${NC}")" choice
        case $choice in
            1) install_reality ;;
            2) uninstall_reality ;;
            3) show_config ;;
            0) echo -e "  ${PURPLE}バイバイ~ (｡･ω･)ﾉﾞ${NC}"; exit 0 ;;
            *) echo -e "  ${YELLOW}(・_・?) 没有「$choice」这个选项~${NC}"; sleep 1; continue ;;
        esac
        echo ""
        read -p "$(echo -e "  ${GRAY}按回车返回菜单...${NC}")" _
    done
}

main
