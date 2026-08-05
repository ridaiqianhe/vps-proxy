#!/bin/bash

# ===================================================================
# AnyTLS 一键安装/管理脚本 (基于官方 sing-box)
# 普通 TLS 模式可供 Surge、mihomo、Shadowrocket 等 AnyTLS 客户端使用。
# AnyTLS + Reality 请从主菜单末尾的 sing-box 专属选项安装。
# 仓库: https://github.com/ridaiqianhe/vps-proxy
# 上游: https://github.com/SagerNet/sing-box
# ===================================================================

# 这是交互式脚本，不使用 set -e；每个关键步骤显式检查并返回错误。

RED='\e[31m'
GREEN='\e[92m'
YELLOW='\e[93m'
BLUE='\e[94m'
CYAN='\e[96m'
PURPLE='\e[38;5;135m'
GRAY='\e[90m'
NC='\e[0m'

SINGBOX_MIN_VERSION="1.12.12"
SINGBOX_RELEASE_API="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
SINGBOX_INSTALLER_URL="https://sing-box.app/install.sh"
SINGBOX_BIN=""
SINGBOX_VERSION=""
PKG_MANAGER=""
PREVIOUS_SERVICE_PRESENT=0
PREVIOUS_SERVICE_ACTIVE=0
PREVIOUS_SERVICE_ENABLED=0
REMOVE_LEGACY_ANYTLS=0
LEGACY_SERVICE_ACTIVE=0
LEGACY_SERVICE_STOPPED=0
LEGACY_PORT=""
LEGACY_PASSWORD=""

CONF_DIR="/etc/sing-box-anytls"
CONF_FILE="$CONF_DIR/config.json"
META_FILE="$CONF_DIR/metadata"
CERT_FILE="$CONF_DIR/server.crt"
KEY_FILE="$CONF_DIR/server.key"
SERVICE_NAME="sing-box-anytls"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
DATA_DIR="/var/lib/$SERVICE_NAME"
TEMP_DIR="$(mktemp -d /tmp/singbox_anytls_install.XXXXXX)" || {
    echo "[ERROR] 无法创建临时目录" >&2
    exit 1
}
LEGACY_META_FILE="$CONF_DIR/meta.env"

umask 077
trap 'rm -rf "$TEMP_DIR"' EXIT

log_info()  { echo -e "${GREEN}[INFO] $1${NC}" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN] $1${NC}" >&2; }
log_error() { echo -e "${RED}[ERROR] $1${NC}" >&2; }

if [ "$(id -u)" != "0" ]; then
    log_error "请以 root 权限运行此脚本"
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    log_error "当前系统未找到 systemctl，本脚本需要 systemd"
    exit 1
fi

detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
    else
        log_error "未找到受支持的包管理器 (apt/dnf/yum)"
        return 1
    fi
}

install_packages() {
    case "$PKG_MANAGER" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
            ;;
        dnf) dnf install -y "$@" ;;
        yum) yum install -y "$@" ;;
        *) log_error "包管理器尚未检测"; return 1 ;;
    esac
}

ensure_dependencies() {
    detect_pkg_manager || return 1
    local packages=()
    command -v curl >/dev/null 2>&1 || packages+=(curl)
    command -v jq >/dev/null 2>&1 || packages+=(jq)
    command -v openssl >/dev/null 2>&1 || packages+=(openssl)
    command -v shuf >/dev/null 2>&1 || packages+=(coreutils)
    command -v ss >/dev/null 2>&1 || {
        if [ "$PKG_MANAGER" = "apt" ]; then packages+=(iproute2); else packages+=(iproute); fi
    }
    if [ "${#packages[@]}" -gt 0 ]; then
        log_info "安装依赖: ${packages[*]}"
        install_packages "${packages[@]}" >/dev/null 2>&1 || {
            log_error "依赖安装失败: ${packages[*]}"
            return 1
        }
    fi
    command -v curl >/dev/null 2>&1 || { log_error "缺少 curl"; return 1; }
    command -v jq >/dev/null 2>&1 || { log_error "缺少 jq，无法安全生成 JSON 配置"; return 1; }
    command -v openssl >/dev/null 2>&1 || { log_error "缺少 openssl"; return 1; }
    command -v shuf >/dev/null 2>&1 || { log_error "缺少 shuf"; return 1; }
    command -v ss >/dev/null 2>&1 || { log_error "缺少 ss"; return 1; }
}

strip_version_suffix() {
    local value="${1#v}"
    value="${value%%-*}"
    echo "$value" | sed 's/[^0-9.].*$//'
}

version_at_least() {
    local have need have_raw need_raw have_suffix need_suffix i h n
    local -a have_parts need_parts
    have_raw="${1#v}"
    need_raw="${2#v}"
    have="$(strip_version_suffix "$have_raw")"
    need="$(strip_version_suffix "$need_raw")"
    IFS=. read -r -a have_parts <<< "$have"
    IFS=. read -r -a need_parts <<< "$need"
    for i in 0 1 2; do
        h="${have_parts[$i]:-0}"
        n="${need_parts[$i]:-0}"
        [[ "$h" =~ ^[0-9]+$ ]] || h=0
        [[ "$n" =~ ^[0-9]+$ ]] || n=0
        if [ "$h" -gt "$n" ]; then return 0; fi
        if [ "$h" -lt "$n" ]; then return 1; fi
    done
    have_suffix="${have_raw#"$have"}"
    need_suffix="${need_raw#"$need"}"
    [ -z "$have_suffix" ] || [ -n "$need_suffix" ]
}

read_binary_version() {
    "$1" version 2>/dev/null | awk '
        NR == 1 {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^[0-9]+\./) { print $i; exit }
            }
        }
    '
}

select_singbox_binary() {
    local candidate version best_bin="" best_version=""
    local -a candidates
    candidates=("$(type -P sing-box 2>/dev/null || true)" "/usr/bin/sing-box" "/usr/local/bin/sing-box")
    for candidate in "${candidates[@]}"; do
        [ -x "$candidate" ] || continue
        version="$(read_binary_version "$candidate")"
        [ -n "$version" ] || continue
        if [ -z "$best_version" ] || ! version_at_least "$best_version" "$version"; then
            best_bin="$candidate"
            best_version="$version"
        fi
    done
    SINGBOX_BIN="$best_bin"
    SINGBOX_VERSION="$best_version"
    [ -n "$SINGBOX_BIN" ]
}

get_latest_singbox_version() {
    local response version
    local -a curl_args
    curl_args=(-fsSL --retry 2 --connect-timeout 15 --max-time 30)
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl_args+=(-H "Authorization: Bearer $GITHUB_TOKEN")
    fi
    response="$(curl "${curl_args[@]}" "$SINGBOX_RELEASE_API" 2>/dev/null)" || return 1
    version="$(printf '%s' "$response" | jq -er \
        'select(.draft == false and .prerelease == false) | .tag_name' 2>/dev/null)" || return 1
    version="${version#v}"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    version_at_least "$version" "$SINGBOX_MIN_VERSION" || return 1
    printf '%s\n' "$version"
}

run_singbox_installer() {
    local target_version="$1"
    local installer="$TEMP_DIR/sing-box-install.sh"
    if ! curl -fsSL --retry 2 --connect-timeout 15 --max-time 120 \
        "$SINGBOX_INSTALLER_URL" -o "$installer"; then
        log_error "下载 sing-box 官方安装器失败"
        return 1
    fi
    if [ ! -s "$installer" ] || ! grep -q "SagerNet/sing-box" "$installer"; then
        log_error "下载的 sing-box 安装器校验失败"
        return 1
    fi
    if [ -n "$target_version" ]; then
        (cd "$TEMP_DIR" && sh "$installer" --version "$target_version")
    else
        (cd "$TEMP_DIR" && sh "$installer")
    fi
}

ensure_singbox() {
    local installed=0 latest_version="" needs_install=0 previous_version=""
    SINGBOX_BIN=""
    SINGBOX_VERSION=""
    if select_singbox_binary; then
        installed=1
        previous_version="$SINGBOX_VERSION"
        log_info "检测到 sing-box v$SINGBOX_VERSION ($SINGBOX_BIN)"
    fi

    if latest_version="$(get_latest_singbox_version)"; then
        log_info "官方最新稳定版: sing-box v$latest_version"
    else
        log_warn "无法获取 sing-box 最新稳定版，不能完成在线更新检查"
    fi

    if [ "$installed" = 0 ]; then
        needs_install=1
        log_info "未检测到 sing-box，准备安装官方稳定版"
    elif ! version_at_least "$SINGBOX_VERSION" "$SINGBOX_MIN_VERSION"; then
        needs_install=1
        log_warn "当前 sing-box v$SINGBOX_VERSION 低于最低兼容版本 v$SINGBOX_MIN_VERSION"
    elif [ -n "$latest_version" ] && ! version_at_least "$SINGBOX_VERSION" "$latest_version"; then
        needs_install=1
        log_info "准备升级 sing-box: v$SINGBOX_VERSION -> v$latest_version"
    elif [ -n "$latest_version" ]; then
        if [ "$SINGBOX_VERSION" = "$latest_version" ]; then
            log_info "sing-box 已是最新稳定版"
        else
            log_info "当前 sing-box v$SINGBOX_VERSION 不低于稳定版 v${latest_version}，保留现有版本"
        fi
    elif version_at_least "$SINGBOX_VERSION" "$SINGBOX_MIN_VERSION"; then
        log_warn "继续使用兼容版本 v${SINGBOX_VERSION}；本次未确认是否存在更新"
    fi

    [ "$needs_install" = 1 ] || return 0
    if ! run_singbox_installer "$latest_version"; then
        log_error "sing-box 安装失败"
        return 1
    fi
    hash -r 2>/dev/null || true
    SINGBOX_BIN=""
    SINGBOX_VERSION=""
    if ! select_singbox_binary; then
        log_error "安装后仍未找到 sing-box"
        return 1
    fi
    if ! version_at_least "$SINGBOX_VERSION" "$SINGBOX_MIN_VERSION"; then
        log_error "安装后的 sing-box v$SINGBOX_VERSION 仍低于最低版本 v$SINGBOX_MIN_VERSION"
        return 1
    fi
    if [ -n "$latest_version" ] && ! version_at_least "$SINGBOX_VERSION" "$latest_version"; then
        log_error "升级后检测到 v${SINGBOX_VERSION}，未达到目标稳定版 v$latest_version"
        return 1
    fi
    if [ -n "$previous_version" ]; then
        log_info "sing-box 已从 v$previous_version 升级到 v$SINGBOX_VERSION"
    else
        log_info "sing-box v$SINGBOX_VERSION 安装完成"
    fi
}

ensure_service_user() {
    local nologin
    nologin="$(command -v nologin 2>/dev/null || echo /usr/sbin/nologin)"
    if ! getent group sing-box >/dev/null 2>&1; then
        groupadd --system sing-box >/dev/null 2>&1 || { log_error "无法创建 sing-box 系统组"; return 1; }
    fi
    if id sing-box >/dev/null 2>&1; then return 0; fi
    useradd --system --gid sing-box --no-create-home --shell "$nologin" sing-box >/dev/null 2>&1 || {
        log_error "无法创建 sing-box 系统用户"
        return 1
    }
}

is_port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(:|\])${port}$"
    else
        return 1
    fi
}

get_random_free_port() {
    local port
    for _ in $(seq 1 30); do
        port="$(shuf -i 20000-65000 -n 1)"
        if ! is_port_in_use "$port"; then echo "$port"; return 0; fi
    done
    return 1
}

get_meta_value() {
    local key="$1"
    if [ -f "$META_FILE" ]; then
        jq -r --arg key "$key" '{
            FORMAT: .format,
            PORT: .port,
            PASSWORD: .password,
            SNI: .sni,
            CERT_SHA256: .cert_sha256,
            SINGBOX_BIN: .singbox_bin,
            SINGBOX_VERSION: .singbox_version
        }[$key] // empty' "$META_FILE" 2>/dev/null
    elif [ -f "$LEGACY_META_FILE" ]; then
        awk -v key="$key" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' "$LEGACY_META_FILE"
    fi
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_domain() {
    [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]
}

choose_port() {
    local default_port="$1" allowed_port="${2:-}" value random_port
    valid_port "$default_port" || default_port=443
    while true; do
        value=""
        read -r -p "$(echo -e "${CYAN}◆ 对外端口 ${GRAY}(回车用 ${GREEN}$default_port${GRAY})${CYAN}: ${NC}")" value
        value="${value:-$default_port}"
        if ! valid_port "$value"; then
            log_warn "端口必须是 1-65535 的数字"
            continue
        fi
        if is_port_in_use "$value" && [ "$value" != "$allowed_port" ]; then
            random_port="$(get_random_free_port || true)"
            log_warn "端口 $value 已被占用${random_port:+，下次默认使用 $random_port}"
            [ -n "$random_port" ] && default_port="$random_port"
            continue
        fi
        printf '%s\n' "$value"
        return 0
    done
}

random_password() { openssl rand -hex 16 2>/dev/null || LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32; }

choose_password() {
    local default_password="$1" value
    [ -n "$default_password" ] || default_password="$(random_password)"
    while true; do
        value=""
        read -r -p "$(echo -e "${CYAN}◆ AnyTLS 密码 ${GRAY}(回车用 ${GREEN}$default_password${GRAY})${CYAN}: ${NC}")" value
        value="${value:-$default_password}"
        if ! [[ "$value" =~ ^[A-Za-z0-9._~@+-]{8,128}$ ]]; then
            log_warn "为兼容各类客户端，密码需为 8-128 位字母、数字或 . _ ~ @ + -"
            continue
        fi
        printf '%s\n' "$value"
        return 0
    done
}

choose_sni() {
    local old_sni="$1" default_choice=1 choice custom i
    local -a options=("www.microsoft.com" "www.apple.com" "aws.amazon.com" "www.cloudflare.com" "dl.google.com")
    for i in "${!options[@]}"; do
        if [ "${options[$i]}" = "$old_sni" ]; then default_choice=$((i + 1)); break; fi
    done
    if [ -n "$old_sni" ] && [ "$default_choice" = 1 ] && [ "$old_sni" != "${options[0]}" ]; then default_choice=6; fi
    echo "请选择 TLS SNI（普通 TLS 模式，不是 Reality） (默认 $default_choice):" >&2
    for i in "${!options[@]}"; do echo "$((i + 1)). ${options[$i]}" >&2; done
    echo "6. 手动输入域名" >&2
    while true; do
        choice=""
        read -r -p "$(echo -e "${CYAN}输入选项 [默认 $default_choice]: ${NC}")" choice
        choice="${choice:-$default_choice}"
        if [[ "$choice" =~ ^[1-5]$ ]]; then printf '%s\n' "${options[$((choice - 1))]}"; return 0; fi
        if [ "$choice" = 6 ]; then
            custom=""
            read -r -p "$(echo -e "${CYAN}输入 TLS SNI 域名 (默认 ${old_sni:-example.com}): ${NC}")" custom
            custom="${custom:-${old_sni:-example.com}}"
            if valid_domain "$custom"; then printf '%s\n' "$custom"; return 0; fi
            log_warn "域名格式无效"
        else
            log_warn "无效选项，请输入 1-6"
        fi
    done
}

looks_like_ip() {
    local value="$1"
    [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0
    [[ "$value" == *:* && "$value" =~ ^[0-9A-Fa-f:.]+$ ]]
}

get_host_ip() {
    local ip
    ip="$(curl -4 -fsS --connect-timeout 8 --max-time 12 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')"
    looks_like_ip "$ip" || ip=""
    if [ -z "$ip" ]; then
        ip="$(curl -6 -fsS --connect-timeout 8 --max-time 12 https://ifconfig.co 2>/dev/null | tr -d '[:space:]')"
        looks_like_ip "$ip" || ip=""
    fi
    if [ -z "$ip" ]; then
        ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
        looks_like_ip "$ip" || ip=""
    fi
    echo "$ip"
}

generate_certificate() {
    local sni="$1" cert="$TEMP_DIR/server.crt" key="$TEMP_DIR/server.key"
    log_info "生成自签名 TLS 证书（客户端需开启 skip-cert-verify）"
    if ! openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -subj "/CN=$sni" -addext "subjectAltName=DNS:$sni" \
        -keyout "$key" -out "$cert" >/dev/null 2>&1; then
        # OpenSSL 旧版本没有 -addext，回退到只有 CN 的证书；skip-cert-verify 仍可用。
        rm -f "$cert" "$key"
        if ! openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -subj "/CN=$sni" -keyout "$key" -out "$cert" >/dev/null 2>&1; then
            log_error "自签名证书生成失败"
            return 1
        fi
    fi
    install -d -m 0750 -o root -g sing-box "$CONF_DIR" || return 1
    install -m 0644 -o root -g sing-box "$cert" "$CERT_FILE" || return 1
    install -m 0640 -o root -g sing-box "$key" "$KEY_FILE" || return 1
}

write_config() {
    local port="$1" password="$2" sni="$3" generated="$TEMP_DIR/config.json"
    if ! jq -n --arg sni "$sni" --arg password "$password" \
        --arg cert "$CERT_FILE" --arg key "$KEY_FILE" --argjson port "$port" \
        '{
            "$schema": "https://sing-box.sagernet.org/schema.json",
            "log": {"level": "warn", "timestamp": true},
            "inbounds": [{
                "type": "anytls",
                "tag": "anytls-in",
                "listen": "::",
                "listen_port": $port,
                "users": [{"name": "default", "password": $password}],
                "tls": {
                    "enabled": true,
                    "server_name": $sni,
                    "certificate_path": $cert,
                    "key_path": $key
                }
            }],
            "outbounds": [{"type": "direct", "tag": "direct"}],
            "route": {"final": "direct"}
        }' > "$generated"; then
        log_error "生成 sing-box JSON 配置失败"
        return 1
    fi
    install -d -m 0750 -o root -g sing-box "$CONF_DIR" || return 1
    install -m 0640 -o root -g sing-box "$generated" "$CONF_FILE" || return 1
}

write_metadata() {
    local port="$1" password="$2" sni="$3" fingerprint="$4" generated="$TEMP_DIR/meta.json"
    jq -n \
        --arg format "anytls-singbox-v1" \
        --arg password "$password" \
        --arg sni "$sni" \
        --arg cert_sha256 "$fingerprint" \
        --arg singbox_bin "$SINGBOX_BIN" \
        --arg singbox_version "$SINGBOX_VERSION" \
        --argjson port "$port" \
        '{format:$format,port:$port,password:$password,sni:$sni,cert_sha256:$cert_sha256,singbox_bin:$singbox_bin,singbox_version:$singbox_version}' \
        > "$generated" || return 1
    install -m 0600 -o root -g root "$generated" "$META_FILE" || return 1
}

write_service() {
    cat > "$TEMP_DIR/service" << EOF
[Unit]
Description=AnyTLS (sing-box)
Documentation=https://sing-box.sagernet.org/configuration/inbound/anytls/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=sing-box
Group=sing-box
StateDirectory=$SERVICE_NAME
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=$SINGBOX_BIN -D $DATA_DIR -C $CONF_DIR run
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    install -m 0644 -o root -g root "$TEMP_DIR/service" "$SERVICE_FILE" || return 1
    install -d -m 0750 -o sing-box -g sing-box "$DATA_DIR" || return 1
}

backup_current_files() {
    rm -f "$TEMP_DIR/config.previous" "$TEMP_DIR/meta.previous" \
        "$TEMP_DIR/cert.previous" "$TEMP_DIR/key.previous" "$TEMP_DIR/service.previous" \
        "$TEMP_DIR/legacy-meta.previous"
    PREVIOUS_SERVICE_PRESENT=0
    PREVIOUS_SERVICE_ACTIVE=0
    PREVIOUS_SERVICE_ENABLED=0
    [ -f "$SERVICE_FILE" ] && PREVIOUS_SERVICE_PRESENT=1
    systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null && PREVIOUS_SERVICE_ACTIVE=1
    systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null && PREVIOUS_SERVICE_ENABLED=1
    if [ -f "$CONF_FILE" ]; then cp -p "$CONF_FILE" "$TEMP_DIR/config.previous" || return 1; fi
    if [ -f "$META_FILE" ]; then cp -p "$META_FILE" "$TEMP_DIR/meta.previous" || return 1; fi
    if [ -f "$CERT_FILE" ]; then cp -p "$CERT_FILE" "$TEMP_DIR/cert.previous" || return 1; fi
    if [ -f "$KEY_FILE" ]; then cp -p "$KEY_FILE" "$TEMP_DIR/key.previous" || return 1; fi
    if [ -f "$SERVICE_FILE" ]; then cp -p "$SERVICE_FILE" "$TEMP_DIR/service.previous" || return 1; fi
    if [ -f "$LEGACY_META_FILE" ]; then cp -p "$LEGACY_META_FILE" "$TEMP_DIR/legacy-meta.previous" || return 1; fi
    return 0
}

restore_current_files() {
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    if [ "$PREVIOUS_SERVICE_PRESENT" = 0 ]; then
        systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    fi
    local item previous target mode owner
    for item in config meta cert key; do
        previous="$TEMP_DIR/$item.previous"
        case "$item" in
            config) target="$CONF_FILE"; mode=0640; owner="root:sing-box" ;;
            meta) target="$META_FILE"; mode=0600; owner="root:root" ;;
            cert) target="$CERT_FILE"; mode=0644; owner="root:sing-box" ;;
            key) target="$KEY_FILE"; mode=0640; owner="root:sing-box" ;;
        esac
        if [ -f "$previous" ]; then install -m "$mode" -o "${owner%:*}" -g "${owner#*:}" "$previous" "$target" || true; else rm -f "$target"; fi
    done
    if [ -f "$TEMP_DIR/service.previous" ]; then
        install -m 0644 -o root -g root "$TEMP_DIR/service.previous" "$SERVICE_FILE" || true
    else
        rm -f "$SERVICE_FILE"
    fi
    if [ -f "$TEMP_DIR/legacy-meta.previous" ]; then
        install -m 0600 -o root -g root "$TEMP_DIR/legacy-meta.previous" "$LEGACY_META_FILE" || true
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    if [ "$PREVIOUS_SERVICE_PRESENT" = 1 ]; then
        if [ "$PREVIOUS_SERVICE_ENABLED" = 1 ]; then
            systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
        else
            systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
        fi
        if [ "$PREVIOUS_SERVICE_ACTIVE" = 1 ]; then
            systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || \
                log_warn "原 AnyTLS 配置已恢复，但服务重启失败"
        fi
    fi
    restore_legacy_anytls
}

get_legacy_value() {
    local key="$1" file="/etc/anytls/config.env"
    [ -f "$file" ] || return 0
    awk -v key="$key" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' "$file"
}

prepare_legacy_anytls_migration() {
    REMOVE_LEGACY_ANYTLS=0
    LEGACY_SERVICE_ACTIVE=0
    LEGACY_SERVICE_STOPPED=0
    LEGACY_PORT=""
    LEGACY_PASSWORD=""
    if [ ! -f /etc/systemd/system/anytls.service ] && [ ! -d /etc/anytls ]; then return 0; fi
    echo -e "${YELLOW}[WARN] 检测到旧版原生 AnyTLS 安装。新服务不会读取它的配置。${NC}" >&2
    read -r -p "新服务安装成功后删除旧版 AnyTLS 服务及文件？[Y/n]: " answer
    answer="${answer:-Y}"
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        REMOVE_LEGACY_ANYTLS=1
        LEGACY_PORT="$(get_legacy_value ANYTLS_PORT)"
        LEGACY_PASSWORD="$(get_legacy_value ANYTLS_PASSWORD)"
        valid_port "$LEGACY_PORT" || LEGACY_PORT=""
        if ! [[ "$LEGACY_PASSWORD" =~ ^[A-Za-z0-9._~@+-]{8,128}$ ]]; then LEGACY_PASSWORD=""; fi
        systemctl is-active --quiet anytls 2>/dev/null && LEGACY_SERVICE_ACTIVE=1
    else
        log_warn "已保留旧版 AnyTLS 文件；请确认它没有占用新端口"
    fi
}

stop_legacy_anytls_for_migration() {
    [ "$REMOVE_LEGACY_ANYTLS" = 1 ] || return 0
    [ "$LEGACY_SERVICE_ACTIVE" = 1 ] || return 0
    if ! systemctl stop anytls >/dev/null 2>&1 || systemctl is-active --quiet anytls 2>/dev/null; then
        log_error "无法停止旧版 AnyTLS 服务，新服务尚未启动"
        return 1
    fi
    LEGACY_SERVICE_STOPPED=1
}

restore_legacy_anytls() {
    [ "$LEGACY_SERVICE_STOPPED" = 1 ] || return 0
    systemctl start anytls >/dev/null 2>&1 || log_warn "旧版 AnyTLS 服务恢复启动失败"
    LEGACY_SERVICE_STOPPED=0
}

remove_legacy_anytls() {
    [ "$REMOVE_LEGACY_ANYTLS" = 1 ] || return 0
    systemctl stop anytls >/dev/null 2>&1 || true
    systemctl disable anytls >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/anytls.service /usr/local/bin/anytls-server
    rm -rf /etc/anytls
    systemctl daemon-reload >/dev/null 2>&1 || true
    LEGACY_SERVICE_STOPPED=0
    log_info "旧版 AnyTLS 已清理"
}

install_anytls() {
    echo -e "${CYAN}[INFO] 当前使用 sing-box 原生 AnyTLS，兼容普通 AnyTLS 客户端。${NC}" >&2
    echo -e "${GRAY}需要 Reality 请返回主菜单选择末尾的“AnyTLS + Reality（sing-box 专属）”。${NC}" >&2
    ensure_dependencies || return 1
    ensure_singbox || return 1
    ensure_service_user || return 1
    prepare_legacy_anytls_migration

    local old_port old_password old_sni
    old_port="$(get_meta_value PORT)"
    old_password="$(get_meta_value PASSWORD)"
    old_sni="$(get_meta_value SNI)"
    if [ "$REMOVE_LEGACY_ANYTLS" = 1 ]; then
        [ -n "$old_port" ] || old_port="$LEGACY_PORT"
        [ -n "$old_password" ] || old_password="$LEGACY_PASSWORD"
    fi

    if ! backup_current_files; then
        log_error "备份现有 AnyTLS 配置失败，未进行更新"
        return 1
    fi
    local port password sni fingerprint allowed_port=""
    [ "$PREVIOUS_SERVICE_ACTIVE" = 1 ] && allowed_port="$old_port"
    if [ "$REMOVE_LEGACY_ANYTLS" = 1 ] && [ "$LEGACY_SERVICE_ACTIVE" = 1 ] && [ "$old_port" = "$LEGACY_PORT" ]; then
        allowed_port="$LEGACY_PORT"
    fi
    port="$(choose_port "${old_port:-443}" "$allowed_port")" || return 1
    password="$(choose_password "$old_password")" || return 1
    sni="$(choose_sni "$old_sni")" || return 1

    if [ "$PREVIOUS_SERVICE_ACTIVE" = 1 ]; then
        if ! systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
            log_error "无法停止现有 AnyTLS 服务，未写入新配置"
            return 1
        fi
    fi
    if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ] || [ "$sni" != "$old_sni" ]; then
        generate_certificate "$sni" || { restore_current_files; return 1; }
    fi
    if ! write_config "$port" "$password" "$sni"; then
        log_error "写入配置失败"; restore_current_files; return 1
    fi
    fingerprint="$(openssl x509 -in "$CERT_FILE" -outform DER 2>/dev/null \
        | openssl dgst -sha256 -hex 2>/dev/null | sed 's/^.*= *//' | tr '[:upper:]' '[:lower:]')"
    if ! [[ "$fingerprint" =~ ^[0-9a-f]{64}$ ]]; then
        log_error "无法计算 TLS 证书 SHA-256 指纹"
        restore_current_files
        return 1
    fi
    write_metadata "$port" "$password" "$sni" "$fingerprint" || { log_error "写入元数据失败"; restore_current_files; return 1; }
    write_service || { log_error "写入 systemd 服务失败"; restore_current_files; return 1; }

    if ! "$SINGBOX_BIN" check -c "$CONF_FILE" -D "$CONF_DIR" >/dev/null 2>&1; then
        log_error "sing-box 配置校验失败，已恢复原配置"
        "$SINGBOX_BIN" check -c "$CONF_FILE" -D "$CONF_DIR" 2>&1 | tail -20 >&2 || true
        restore_current_files
        return 1
    fi
    systemctl daemon-reload || { log_error "systemd 配置重载失败"; restore_current_files; return 1; }
    if ! stop_legacy_anytls_for_migration; then
        restore_current_files
        return 1
    fi
    if ! systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || ! systemctl restart "$SERVICE_NAME"; then
        log_error "AnyTLS 服务启动失败"
        journalctl -u "$SERVICE_NAME" -n 30 --no-pager --output cat >&2 || true
        restore_current_files
        return 1
    fi
    sleep 1
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        log_error "AnyTLS 服务未运行"
        journalctl -u "$SERVICE_NAME" -n 30 --no-pager --output cat >&2 || true
        restore_current_files
        return 1
    fi
    rm -f "$LEGACY_META_FILE"
    remove_legacy_anytls
    log_info "AnyTLS 安装成功（sing-box v${SINGBOX_VERSION}）"
    show_config
}

uninstall_anytls() {
    if [ ! -f "$SERVICE_FILE" ] && [ ! -f "$META_FILE" ] && [ ! -f "$LEGACY_META_FILE" ]; then log_error "AnyTLS 未安装"; return 0; fi
    read -r -p "确认卸载 sing-box AnyTLS？不会删除其他 sing-box 配置 [输入 yes 确认]: " answer
    [ "$answer" = "yes" ] || { log_info "已取消"; return 0; }
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE"
    rm -rf "$CONF_DIR" "$DATA_DIR"
    systemctl daemon-reload >/dev/null 2>&1 || true
    log_info "sing-box AnyTLS 已卸载；sing-box 二进制保留"
}

show_config() {
    [ -f "$META_FILE" ] || [ -f "$LEGACY_META_FILE" ] || { log_error "未找到配置，请先安装"; return 1; }
    local PORT PASSWORD SNI CERT_SHA256 HOST SURGE_HOST uri_host password_uri sni_uri
    PORT="$(get_meta_value PORT)"; PASSWORD="$(get_meta_value PASSWORD)"; SNI="$(get_meta_value SNI)"
    if ! valid_port "$PORT" || [ -z "$PASSWORD" ] || ! valid_domain "$SNI"; then
        log_error "AnyTLS 元数据不完整或已损坏，请重新执行安装/更新"
        return 1
    fi
    CERT_SHA256="$(get_meta_value CERT_SHA256)"; HOST="$(get_host_ip)"; [ -n "$HOST" ] || HOST="YOUR_SERVER_IP"
    [[ "$CERT_SHA256" =~ ^[0-9A-Fa-f]{64}$ ]] || CERT_SHA256=""
    SURGE_HOST="$HOST"
    [[ "$SURGE_HOST" == *:* ]] && SURGE_HOST="[$SURGE_HOST]"

    echo ""
    echo -e "${CYAN}================ sing-box AnyTLS 配置信息 ================${NC}"
    echo -e "${BLUE}地址(server): $HOST${NC}"
    echo -e "${BLUE}端口(port):   $PORT${NC}"
    echo -e "${BLUE}密码(password): $PASSWORD${NC}"
    echo -e "${BLUE}SNI: $SNI${NC}"
    [ -n "$CERT_SHA256" ] && echo -e "${BLUE}证书 SHA-256 指纹: $CERT_SHA256${NC}"
    echo ""
    echo -e "${YELLOW}--- Surge 配置行（需 skip-cert-verify=true）---${NC}"
    echo "AnyTLS = anytls, $SURGE_HOST, $PORT, password=$PASSWORD, sni=$SNI, skip-cert-verify=true"
    if [ -n "$CERT_SHA256" ]; then
        echo -e "${YELLOW}--- Surge 配置行（证书固定，优先使用）---${NC}"
        echo "AnyTLS-Pinned = anytls, $SURGE_HOST, $PORT, password=$PASSWORD, sni=$SNI, server-cert-fingerprint-sha256=$CERT_SHA256"
    fi
    echo ""
    echo -e "${YELLOW}--- mihomo(clash-meta) 配置片段 ---${NC}"
    cat << EOF
  - name: anytls
    type: anytls
    server: "$HOST"
    port: $PORT
    password: "$PASSWORD"
    sni: "$SNI"
    client-fingerprint: chrome
    skip-cert-verify: true
    udp: true
EOF
    echo -e "${YELLOW}--- sing-box 客户端 outbound ---${NC}"
    jq -n --arg host "$HOST" --arg sni "$SNI" --arg password "$PASSWORD" --argjson port "$PORT" \
        '{"type":"anytls","tag":"anytls","server":$host,"server_port":$port,"password":$password,"tls":{"enabled":true,"server_name":$sni,"insecure":true}}'
    uri_host="$HOST"
    [[ "$uri_host" == *:* ]] && uri_host="[$uri_host]"
    password_uri="$(jq -nr --arg value "$PASSWORD" '$value | @uri')"
    sni_uri="$(jq -nr --arg value "$SNI" '$value | @uri')"
    echo -e "${YELLOW}--- AnyTLS 标准导入链接 ---${NC}"
    echo "anytls://${password_uri}@${uri_host}:${PORT}/?sni=${sni_uri}&insecure=1#AnyTLS"
    echo ""
    echo -e "${GRAY}本模式是普通 TLS，不含 Reality；需要 Reality 请使用主菜单末尾的 sing-box 专属模式。${NC}"
    echo -e "${CYAN}===========================================================${NC}"
    echo ""
}

show_logs() {
    [ -f "$SERVICE_FILE" ] || { log_error "AnyTLS 未安装"; return 1; }
    echo -e "${YELLOW}--- $SERVICE_NAME 最近日志 ---${NC}"
    journalctl -u "$SERVICE_NAME" -n 100 --no-pager --output cat
}

show_status() {
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo -e "${GREEN}✓ sing-box AnyTLS 服务: 运行中${NC}"
    elif [ -f "$SERVICE_FILE" ]; then
        echo -e "${YELLOW}⚠ sing-box AnyTLS 服务: 已安装但未运行${NC}"
    else
        echo -e "${RED}✗ sing-box AnyTLS: 未安装${NC}"
    fi
}

main() {
    while true; do
        clear 2>/dev/null || true
        echo ""
        echo -e "${PURPLE}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "     ${CYAN}🎀 sing-box AnyTLS 管理 🎀${NC}"
        echo -e "     ${GRAY}普通 TLS · 兼容 AnyTLS 客户端${NC}"
        echo -e "${PURPLE}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -n "  "; show_status
        echo ""
        echo -e "  ${GREEN}1.${NC} 🎀 安装/更新 AnyTLS"
        echo -e "  ${GREEN}2.${NC} 🗑️  卸载 AnyTLS"
        echo -e "  ${GREEN}3.${NC} 📋 查看配置"
        echo -e "  ${GREEN}4.${NC} 📜 查看日志"
        echo -e "  ${YELLOW}0.${NC} 👋 退出"
        echo ""
        read -r -p "$(echo -e "  ${CYAN}请输入选项 [0-4]: ${NC}")" choice
        case "$choice" in
            1) install_anytls ;;
            2) uninstall_anytls ;;
            3) show_config ;;
            4) show_logs ;;
            0) echo -e "  ${PURPLE}バイバイ~ (｡･ω･)ﾉﾞ${NC}"; exit 0 ;;
            *) echo -e "  ${YELLOW}(・_・?) 没有「${choice}」这个选项~${NC}"; sleep 1; continue ;;
        esac
        echo ""
        read -r -p "$(echo -e "  ${GRAY}按回车返回菜单...${NC}")" _
    done
}

main
