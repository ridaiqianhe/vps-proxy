#!/bin/bash

# ===================================================================
# SOCKS5 / HTTP 代理一键安装管理脚本（基于官方 sing-box）
# - Mixed: 同一端口提供 SOCKS5 与 HTTP，明文传输，仅建议可信网络使用。
# - HTTPS: HTTP CONNECT over TLS，适合公网使用，不支持 UDP。
# 仓库: https://github.com/ridaiqianhe/vps-proxy
# 上游: https://github.com/SagerNet/sing-box
# ===================================================================

RED='\e[31m'; GREEN='\e[92m'; YELLOW='\e[93m'; BLUE='\e[94m'; CYAN='\e[96m'; PURPLE='\e[38;5;135m'; GRAY='\e[90m'; NC='\e[0m'

SINGBOX_MIN_VERSION="1.12.0"
SINGBOX_RELEASE_API="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
SINGBOX_INSTALLER_URL="https://sing-box.app/install.sh"
SINGBOX_BIN=""
SINGBOX_VERSION=""
PKG_MANAGER=""

CONF_DIR="/etc/sing-box-socks-http"
CONF_FILE="$CONF_DIR/config.json"
META_FILE="$CONF_DIR/metadata.json"
CERT_FILE="$CONF_DIR/server.crt"
KEY_FILE="$CONF_DIR/server.key"
BACKUP_DIR="$CONF_DIR/backup"
SERVICE_NAME="sing-box-socks-http"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
DATA_DIR="/var/lib/$SERVICE_NAME"
TEMP_DIR="$(mktemp -d /tmp/socks_http_install.XXXXXX)" || {
    echo "[ERROR] 无法创建临时目录" >&2
    exit 1
}

PREVIOUS_SERVICE_PRESENT=0
PREVIOUS_SERVICE_ACTIVE=0
PREVIOUS_SERVICE_ENABLED=0

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
        *) return 1 ;;
    esac
}

ensure_dependencies() {
    local -a packages=()
    local command_name
    detect_pkg_manager || return 1
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
    for command_name in curl jq openssl shuf ss; do
        command -v "$command_name" >/dev/null 2>&1 || {
            log_error "缺少依赖: $command_name"
            return 1
        }
    done
}

strip_version_suffix() {
    local value="${1#v}"
    value="${value%%-*}"
    printf '%s\n' "$value" | sed 's/[^0-9.].*$//'
}

version_at_least() {
    local have need i h n
    local -a have_parts need_parts
    have="$(strip_version_suffix "$1")"
    need="$(strip_version_suffix "$2")"
    IFS=. read -r -a have_parts <<< "$have"
    IFS=. read -r -a need_parts <<< "$need"
    for i in 0 1 2; do
        h="${have_parts[$i]:-0}"; n="${need_parts[$i]:-0}"
        [[ "$h" =~ ^[0-9]+$ ]] || h=0
        [[ "$n" =~ ^[0-9]+$ ]] || n=0
        [ "$h" -gt "$n" ] && return 0
        [ "$h" -lt "$n" ] && return 1
    done
    return 0
}

read_binary_version() {
    "$1" version 2>/dev/null | awk 'NR == 1 { for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+\./) { print $i; exit } }'
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
            best_bin="$candidate"; best_version="$version"
        fi
    done
    SINGBOX_BIN="$best_bin"; SINGBOX_VERSION="$best_version"
    [ -n "$SINGBOX_BIN" ]
}

get_latest_singbox_version() {
    local response version
    local -a curl_args=(-fsSL --retry 2 --connect-timeout 15 --max-time 30)
    [ -n "${GITHUB_TOKEN:-}" ] && curl_args+=(-H "Authorization: Bearer $GITHUB_TOKEN")
    response="$(curl "${curl_args[@]}" "$SINGBOX_RELEASE_API" 2>/dev/null)" || return 1
    version="$(printf '%s' "$response" | jq -er 'select(.draft == false and .prerelease == false) | .tag_name' 2>/dev/null)" || return 1
    version="${version#v}"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    version_at_least "$version" "$SINGBOX_MIN_VERSION" || return 1
    printf '%s\n' "$version"
}

run_singbox_installer() {
    local target_version="$1" installer="$TEMP_DIR/sing-box-install.sh"
    curl -fsSL --retry 2 --connect-timeout 15 --max-time 120 \
        "$SINGBOX_INSTALLER_URL" -o "$installer" || {
        log_error "下载 sing-box 官方安装器失败"
        return 1
    }
    [ -s "$installer" ] && grep -q 'SagerNet/sing-box' "$installer" || {
        log_error "下载的 sing-box 安装器校验失败"
        return 1
    }
    if [ -n "$target_version" ]; then
        (cd "$TEMP_DIR" && sh "$installer" --version "$target_version")
    else
        (cd "$TEMP_DIR" && sh "$installer")
    fi
}

ensure_singbox() {
    local installed=0 latest_version="" needs_install=0 previous_version=""
    if select_singbox_binary; then
        installed=1; previous_version="$SINGBOX_VERSION"
        log_info "检测到 sing-box v$SINGBOX_VERSION ($SINGBOX_BIN)"
    fi
    if latest_version="$(get_latest_singbox_version)"; then
        log_info "官方最新稳定版: sing-box v$latest_version"
    else
        log_warn "无法获取 sing-box 最新稳定版"
    fi
    if [ "$installed" = 0 ]; then
        needs_install=1
    elif ! version_at_least "$SINGBOX_VERSION" "$SINGBOX_MIN_VERSION"; then
        needs_install=1
    elif [ -n "$latest_version" ] && ! version_at_least "$SINGBOX_VERSION" "$latest_version"; then
        needs_install=1
    fi
    if [ "$needs_install" = 1 ]; then
        run_singbox_installer "$latest_version" || return 1
        hash -r 2>/dev/null || true
        select_singbox_binary || { log_error "安装后仍未找到 sing-box"; return 1; }
        version_at_least "$SINGBOX_VERSION" "$SINGBOX_MIN_VERSION" || {
            log_error "sing-box v$SINGBOX_VERSION 低于最低版本 v$SINGBOX_MIN_VERSION"
            return 1
        }
        if [ -n "$previous_version" ]; then
            log_info "sing-box 已从 v$previous_version 更新到 v$SINGBOX_VERSION"
        else
            log_info "sing-box v$SINGBOX_VERSION 安装完成"
        fi
    elif [ -n "$latest_version" ]; then
        log_info "sing-box 已满足最新稳定版要求"
    else
        log_warn "继续使用兼容版本 v$SINGBOX_VERSION，本次未确认是否有更新"
    fi
}

ensure_service_user() {
    local nologin
    nologin="$(command -v nologin 2>/dev/null || echo /usr/sbin/nologin)"
    getent group sing-box >/dev/null 2>&1 || groupadd --system sing-box >/dev/null 2>&1 || return 1
    if ! id sing-box >/dev/null 2>&1; then
        useradd --system --gid sing-box --no-create-home --shell "$nologin" sing-box >/dev/null 2>&1 || return 1
    fi
}

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
valid_credential() { [[ "$1" =~ ^[A-Za-z0-9._~@+-]{4,128}$ ]]; }
valid_domain() {
    [ "${#1}" -le 253 ] && [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]
}

is_port_in_use() {
    local port="$1"
    ss -H -ltn 2>/dev/null | awk -v port="$port" '$4 ~ (":" port "$") { found=1 } END { exit(found ? 0 : 1) }'
}

random_port() {
    local port
    for _ in $(seq 1 40); do
        port="$(shuf -i 20000-65000 -n 1)"
        if ! is_port_in_use "$port"; then printf '%s\n' "$port"; return 0; fi
    done
    return 1
}

random_username() { printf 'proxy%s\n' "$(openssl rand -hex 4 2>/dev/null)"; }
random_password() { openssl rand -hex 16 2>/dev/null; }

choose_port() {
    local default_port="$1" allowed_port="${2:-}" value replacement
    valid_port "$default_port" || default_port="$(random_port)" || return 1
    while true; do
        read -r -p "$(echo -e "${CYAN}◆ 对外端口 ${GRAY}(回车用 ${GREEN}$default_port${GRAY})${CYAN}: ${NC}")" value
        value="${value:-$default_port}"
        if ! valid_port "$value"; then log_warn "端口必须是 1-65535 的数字"; continue; fi
        if is_port_in_use "$value" && [ "$value" != "$allowed_port" ]; then
            replacement="$(random_port || true)"
            log_warn "端口 $value 已被占用${replacement:+，下次默认使用 $replacement}"
            [ -n "$replacement" ] && default_port="$replacement"
            continue
        fi
        printf '%s\n' "$value"; return 0
    done
}

choose_credential() {
    local label="$1" default_value="$2" value
    while true; do
        read -r -p "$(echo -e "${CYAN}◆ $label ${GRAY}(回车用 ${GREEN}$default_value${GRAY})${CYAN}: ${NC}")" value
        value="${value:-$default_value}"
        if valid_credential "$value"; then printf '%s\n' "$value"; return 0; fi
        log_warn "$label 需为 4-128 位字母、数字或 . _ ~ @ + -"
    done
}

choose_sni() {
    local default_sni="${1:-www.microsoft.com}" value
    while true; do
        read -r -p "$(echo -e "${CYAN}◆ HTTPS 证书域名/SNI ${GRAY}(回车用 ${GREEN}$default_sni${GRAY})${CYAN}: ${NC}")" value
        value="${value:-$default_sni}"
        if valid_domain "$value"; then printf '%s\n' "$value"; return 0; fi
        log_warn "域名格式无效"
    done
}

get_meta_value() {
    local key="$1"
    [ -f "$META_FILE" ] || return 1
    jq -r --arg key "$key" '{MODE:.mode,PORT:.port,USERNAME:.username,PASSWORD:.password,SNI:.sni,CERT_SHA256:.cert_sha256,SINGBOX_VERSION:.singbox_version}[$key] // empty' "$META_FILE" 2>/dev/null
}

get_host_ip() {
    local ip
    ip="$(curl -4 -fsSL --connect-timeout 8 --max-time 12 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || ip=""
    if [ -z "$ip" ]; then
        ip="$(curl -6 -fsSL --connect-timeout 8 --max-time 12 https://ifconfig.co 2>/dev/null | tr -d '[:space:]')"
        [[ "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:.]+$ ]] || ip=""
    fi
    [ -n "$ip" ] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    printf '%s\n' "$ip"
}

generate_certificate() {
    local sni="$1" openssl_conf="$TEMP_DIR/openssl.cnf"
    cat > "$openssl_conf" << EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $sni
[ext]
subjectAltName = DNS:$sni
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
EOF
    openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
        -config "$openssl_conf" -keyout "$TEMP_DIR/server.key" -out "$TEMP_DIR/server.crt" >/dev/null 2>&1 || {
        log_error "生成 HTTPS 自签名证书失败"
        return 1
    }
    openssl x509 -in "$TEMP_DIR/server.crt" -noout >/dev/null 2>&1
}

write_config() {
    local mode="$1" port="$2" username="$3" password="$4" sni="$5"
    local generated="$TEMP_DIR/config.json"
    if [ "$mode" = "mixed" ]; then
        jq -n --arg username "$username" --arg password "$password" --argjson port "$port" '{
            "$schema":"https://sing-box.sagernet.org/schema.json",
            "log":{"level":"warn","timestamp":true},
            "inbounds":[{"type":"mixed","tag":"mixed-in","listen":"::","listen_port":$port,"users":[{"username":$username,"password":$password}],"set_system_proxy":false}],
            "outbounds":[{"type":"direct","tag":"direct"}],
            "route":{"final":"direct"}
        }' > "$generated"
    else
        jq -n --arg username "$username" --arg password "$password" --arg sni "$sni" \
            --arg cert "$CERT_FILE" --arg key "$KEY_FILE" --argjson port "$port" '{
            "$schema":"https://sing-box.sagernet.org/schema.json",
            "log":{"level":"warn","timestamp":true},
            "inbounds":[{"type":"http","tag":"https-in","listen":"::","listen_port":$port,"users":[{"username":$username,"password":$password}],"tls":{"enabled":true,"server_name":$sni,"certificate_path":$cert,"key_path":$key},"set_system_proxy":false}],
            "outbounds":[{"type":"direct","tag":"direct"}],
            "route":{"final":"direct"}
        }' > "$generated"
    fi
    [ -s "$generated" ] || { log_error "生成 sing-box 配置失败"; return 1; }
}

write_metadata() {
    local mode="$1" port="$2" username="$3" password="$4" sni="$5" fingerprint="$6"
    jq -n --arg format "socks-http-singbox-v1" --arg mode "$mode" --arg username "$username" \
        --arg password "$password" --arg sni "$sni" --arg cert_sha256 "$fingerprint" \
        --arg singbox_version "$SINGBOX_VERSION" --argjson port "$port" \
        '{format:$format,mode:$mode,port:$port,username:$username,password:$password,sni:$sni,cert_sha256:$cert_sha256,singbox_version:$singbox_version}' \
        > "$TEMP_DIR/metadata.json"
}

write_service() {
    cat > "$TEMP_DIR/service" << EOF
[Unit]
Description=SOCKS5 / HTTP Proxy (sing-box)
Documentation=https://sing-box.sagernet.org/configuration/inbound/mixed/
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
ExecStart=$SINGBOX_BIN -D $DATA_DIR -c $CONF_FILE run
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
}

backup_current_files() {
    local item source
    PREVIOUS_SERVICE_PRESENT=0; PREVIOUS_SERVICE_ACTIVE=0; PREVIOUS_SERVICE_ENABLED=0
    [ -f "$SERVICE_FILE" ] && PREVIOUS_SERVICE_PRESENT=1
    systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null && PREVIOUS_SERVICE_ACTIVE=1
    systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null && PREVIOUS_SERVICE_ENABLED=1
    for item in config metadata cert key service; do
        case "$item" in
            config) source="$CONF_FILE" ;;
            metadata) source="$META_FILE" ;;
            cert) source="$CERT_FILE" ;;
            key) source="$KEY_FILE" ;;
            service) source="$SERVICE_FILE" ;;
        esac
        if [ -f "$source" ] && ! cp -p "$source" "$TEMP_DIR/$item.previous"; then
            log_error "备份当前文件失败: $source"
            return 1
        fi
    done
}

create_persistent_backup() {
    local timestamp path item source suffix=0
    [ -d "$CONF_DIR" ] || return 0
    timestamp="$(date '+%Y%m%d_%H%M%S')"; path="$BACKUP_DIR/$timestamp"
    while [ -e "$path" ]; do suffix=$((suffix + 1)); path="$BACKUP_DIR/${timestamp}_$suffix"; done
    install -d -m 0700 -o root -g root "$path" || return 1
    for item in config metadata cert key service; do
        case "$item" in
            config) source="$CONF_FILE" ;;
            metadata) source="$META_FILE" ;;
            cert) source="$CERT_FILE" ;;
            key) source="$KEY_FILE" ;;
            service) source="$SERVICE_FILE" ;;
        esac
        if [ -f "$source" ] && ! cp -p "$source" "$path/$item"; then return 1; fi
    done
    log_info "旧配置已备份到: $path"
}

restore_current_files() {
    local item previous target mode owner group
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    for item in config metadata cert key service; do
        previous="$TEMP_DIR/$item.previous"
        case "$item" in
            config) target="$CONF_FILE"; mode=0640; owner=root; group=sing-box ;;
            metadata) target="$META_FILE"; mode=0600; owner=root; group=root ;;
            cert) target="$CERT_FILE"; mode=0644; owner=root; group=sing-box ;;
            key) target="$KEY_FILE"; mode=0640; owner=root; group=sing-box ;;
            service) target="$SERVICE_FILE"; mode=0644; owner=root; group=root ;;
        esac
        if [ -f "$previous" ]; then
            install -d -m 0750 -o root -g sing-box "$CONF_DIR" >/dev/null 2>&1 || true
            install -m "$mode" -o "$owner" -g "$group" "$previous" "$target" >/dev/null 2>&1 || true
        else
            rm -f "$target"
        fi
    done
    systemctl daemon-reload >/dev/null 2>&1 || true
    if [ "$PREVIOUS_SERVICE_PRESENT" = 1 ]; then
        if [ "$PREVIOUS_SERVICE_ENABLED" = 1 ]; then systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true; else systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true; fi
        [ "$PREVIOUS_SERVICE_ACTIVE" = 1 ] && systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true
    else
        systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    fi
}

install_mode() {
    local mode="$1" old_mode old_port old_username old_password old_sni allowed_port=""
    local port username password sni="" fingerprint=""
    ensure_dependencies || return 1
    ensure_singbox || return 1
    ensure_service_user || { log_error "无法创建 sing-box 系统用户"; return 1; }
    old_mode="$(get_meta_value MODE 2>/dev/null || true)"
    old_port="$(get_meta_value PORT 2>/dev/null || true)"
    old_username="$(get_meta_value USERNAME 2>/dev/null || true)"
    old_password="$(get_meta_value PASSWORD 2>/dev/null || true)"
    old_sni="$(get_meta_value SNI 2>/dev/null || true)"
    valid_port "$old_port" || old_port=""
    valid_credential "$old_username" || old_username=""
    valid_credential "$old_password" || old_password=""
    backup_current_files || { log_error "无法准备回滚文件"; return 1; }
    [ "$PREVIOUS_SERVICE_ACTIVE" = 1 ] && allowed_port="$old_port"
    port="$(choose_port "${old_port:-$(random_port)}" "$allowed_port")" || return 1
    username="$(choose_credential "用户名" "${old_username:-$(random_username)}")" || return 1
    password="$(choose_credential "密码" "${old_password:-$(random_password)}")" || return 1
    if [ "$mode" = "https" ]; then sni="$(choose_sni "$old_sni")" || return 1; fi
    create_persistent_backup || { log_error "持久化备份失败"; return 1; }
    if [ "$PREVIOUS_SERVICE_ACTIVE" = 1 ]; then
        systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || { log_error "无法停止原服务"; return 1; }
    fi
    if [ "$mode" = "https" ]; then
        if [ "$old_mode" = "https" ] && [ "$old_sni" = "$sni" ] && [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
            cp -p "$CERT_FILE" "$TEMP_DIR/server.crt" || { restore_current_files; return 1; }
            cp -p "$KEY_FILE" "$TEMP_DIR/server.key" || { restore_current_files; return 1; }
        else
            generate_certificate "$sni" || { restore_current_files; return 1; }
        fi
        fingerprint="$(openssl x509 -in "$TEMP_DIR/server.crt" -outform DER 2>/dev/null | openssl dgst -sha256 -hex 2>/dev/null | sed 's/^.*= *//' | tr '[:upper:]' '[:lower:]')"
        [[ "$fingerprint" =~ ^[0-9a-f]{64}$ ]] || { log_error "无法计算证书指纹"; restore_current_files; return 1; }
    fi
    write_config "$mode" "$port" "$username" "$password" "$sni" || { restore_current_files; return 1; }
    write_metadata "$mode" "$port" "$username" "$password" "$sni" "$fingerprint" || { restore_current_files; return 1; }
    write_service || { restore_current_files; return 1; }
    install -d -m 0750 -o root -g sing-box "$CONF_DIR" || { restore_current_files; return 1; }
    install -d -m 0750 -o sing-box -g sing-box "$DATA_DIR" || { restore_current_files; return 1; }
    install -m 0640 -o root -g sing-box "$TEMP_DIR/config.json" "$CONF_FILE" || { restore_current_files; return 1; }
    install -m 0600 -o root -g root "$TEMP_DIR/metadata.json" "$META_FILE" || { restore_current_files; return 1; }
    install -m 0644 -o root -g root "$TEMP_DIR/service" "$SERVICE_FILE" || { restore_current_files; return 1; }
    if [ "$mode" = "https" ]; then
        install -m 0644 -o root -g sing-box "$TEMP_DIR/server.crt" "$CERT_FILE" || { restore_current_files; return 1; }
        install -m 0640 -o root -g sing-box "$TEMP_DIR/server.key" "$KEY_FILE" || { restore_current_files; return 1; }
    else
        rm -f "$CERT_FILE" "$KEY_FILE"
    fi
    if ! "$SINGBOX_BIN" check -c "$CONF_FILE" -D "$CONF_DIR" >/dev/null 2>&1; then
        log_error "sing-box 配置校验失败"
        "$SINGBOX_BIN" check -c "$CONF_FILE" -D "$CONF_DIR" 2>&1 | tail -20 >&2 || true
        restore_current_files; return 1
    fi
    systemctl daemon-reload || { restore_current_files; return 1; }
    if ! systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || ! systemctl restart "$SERVICE_NAME"; then
        log_error "代理服务启动失败"
        journalctl -u "$SERVICE_NAME" -n 30 --no-pager --output cat >&2 || true
        restore_current_files; return 1
    fi
    sleep 1
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        log_error "代理服务未运行"
        restore_current_files; return 1
    fi
    if [ "$mode" = "mixed" ]; then
        log_info "Mixed 代理安装成功（sing-box v$SINGBOX_VERSION）"
    else
        log_info "HTTPS 代理安装成功（sing-box v$SINGBOX_VERSION）"
    fi
    show_config
}

update_singbox() {
    ensure_dependencies || return 1
    ensure_singbox || return 1
    [ -f "$CONF_FILE" ] || { log_info "sing-box 已更新；代理尚未安装"; return 0; }
    "$SINGBOX_BIN" check -c "$CONF_FILE" -D "$CONF_DIR" || return 1
    systemctl restart "$SERVICE_NAME" || return 1
    systemctl is-active --quiet "$SERVICE_NAME" || return 1
    log_info "sing-box v$SINGBOX_VERSION 更新检查完成，代理服务已重启"
}

uninstall_proxy() {
    if [ ! -f "$SERVICE_FILE" ] && [ ! -d "$CONF_DIR" ]; then log_error "SOCKS5/HTTP 代理未安装"; return 0; fi
    read -r -p "确认卸载 SOCKS5/HTTP 代理？不会删除共享的 sing-box 二进制 [输入 yes 确认]: " answer
    [ "$answer" = "yes" ] || { log_info "已取消"; return 0; }
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE"
    rm -rf "$CONF_DIR" "$DATA_DIR"
    systemctl daemon-reload >/dev/null 2>&1 || true
    log_info "SOCKS5/HTTP 代理已卸载；sing-box 二进制保留"
}

show_config() {
    [ -f "$META_FILE" ] || { log_error "未找到配置，请先安装"; return 1; }
    local MODE PORT USERNAME PASSWORD SNI CERT_SHA256 HOST SURGE_HOST URI_HOST user_uri pass_uri
    MODE="$(get_meta_value MODE)"; PORT="$(get_meta_value PORT)"; USERNAME="$(get_meta_value USERNAME)"; PASSWORD="$(get_meta_value PASSWORD)"
    SNI="$(get_meta_value SNI)"; CERT_SHA256="$(get_meta_value CERT_SHA256)"
    [[ "$MODE" =~ ^(mixed|https)$ ]] && valid_port "$PORT" && valid_credential "$USERNAME" && valid_credential "$PASSWORD" || {
        log_error "元数据不完整或损坏"; return 1
    }
    HOST="$(get_host_ip)"; [ -n "$HOST" ] || HOST="YOUR_SERVER_IP"
    SURGE_HOST="$HOST"; [[ "$SURGE_HOST" == *:* ]] && SURGE_HOST="[$SURGE_HOST]"
    URI_HOST="$HOST"; [[ "$URI_HOST" == *:* ]] && URI_HOST="[$URI_HOST]"
    user_uri="$(jq -nr --arg v "$USERNAME" '$v|@uri')"
    pass_uri="$(jq -nr --arg v "$PASSWORD" '$v|@uri')"
    echo ""
    echo -e "${CYAN}============= SOCKS5 / HTTP 配置信息 =============${NC}"
    echo -e "${BLUE}模式: $MODE   地址: $HOST   端口: $PORT${NC}"
    echo -e "${BLUE}用户名: $USERNAME   密码: $PASSWORD${NC}"
    if [ "$MODE" = "mixed" ]; then
        echo -e "${YELLOW}警告: Mixed 模式为明文传输，仅建议可信网络或内网使用。${NC}"
        echo ""
        echo -e "${YELLOW}--- Surge SOCKS5（支持 UDP）---${NC}"
        echo "SOCKS5 = socks5, $SURGE_HOST, $PORT, $USERNAME, $PASSWORD, udp-relay=true"
        echo -e "${YELLOW}--- Surge HTTP（仅 TCP）---${NC}"
        echo "HTTP = http, $SURGE_HOST, $PORT, $USERNAME, $PASSWORD"
        echo -e "${YELLOW}--- sing-box SOCKS5 outbound ---${NC}"
        jq -n --arg host "$HOST" --arg username "$USERNAME" --arg password "$PASSWORD" --argjson port "$PORT" '{type:"socks",tag:"socks5",server:$host,server_port:$port,version:"5",username:$username,password:$password}'
        echo -e "${YELLOW}--- SOCKS5 导入链接 ---${NC}"
        echo "socks5://${user_uri}:${pass_uri}@${URI_HOST}:${PORT}#SOCKS5"
        echo -e "${YELLOW}--- Linux/macOS 环境变量 ---${NC}"
        echo "export ALL_PROXY='socks5h://${user_uri}:${pass_uri}@${URI_HOST}:${PORT}'"
        echo "export HTTP_PROXY='http://${user_uri}:${pass_uri}@${URI_HOST}:${PORT}'"
        echo "export HTTPS_PROXY=\"\$HTTP_PROXY\""
    else
        echo -e "${BLUE}SNI: $SNI${NC}"
        [[ "$CERT_SHA256" =~ ^[0-9A-Fa-f]{64}$ ]] && echo -e "${BLUE}证书 SHA-256: $CERT_SHA256${NC}"
        echo ""
        echo -e "${YELLOW}--- Surge HTTPS（证书固定，推荐）---${NC}"
        echo "HTTPS = https, $SURGE_HOST, $PORT, $USERNAME, $PASSWORD, sni=$SNI, server-cert-fingerprint-sha256=$CERT_SHA256"
        echo -e "${YELLOW}--- Surge HTTPS（跳过校验）---${NC}"
        echo "HTTPS-Insecure = https, $SURGE_HOST, $PORT, $USERNAME, $PASSWORD, sni=$SNI, skip-cert-verify=true"
        echo -e "${YELLOW}--- curl 测试（自签名证书）---${NC}"
        echo "curl --proxy 'https://${user_uri}:${pass_uri}@${URI_HOST}:${PORT}' --proxy-insecure https://cp.cloudflare.com/generate_204"
        echo -e "${GRAY}HTTPS Proxy 仅支持 TCP，不支持 UDP；证书固定比 skip-cert-verify 更安全。${NC}"
    fi
    echo -e "${CYAN}====================================================${NC}"
    echo ""
}

show_logs() {
    [ -f "$SERVICE_FILE" ] || { log_error "代理未安装"; return 1; }
    command -v journalctl >/dev/null 2>&1 || { log_error "未找到 journalctl"; return 1; }
    journalctl -u "$SERVICE_NAME" -n 100 --no-pager --output cat
}

show_status() {
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo -e "${GREEN}✓ SOCKS5/HTTP 服务: 运行中 ($(get_meta_value MODE 2>/dev/null))${NC}"
    elif [ -f "$SERVICE_FILE" ]; then
        echo -e "${YELLOW}⚠ SOCKS5/HTTP 服务: 已安装但未运行${NC}"
    else
        echo -e "${RED}✗ SOCKS5/HTTP 服务: 未安装${NC}"
    fi
}

main() {
    while true; do
        clear 2>/dev/null || true
        echo ""
        echo -e "${PURPLE}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "     ${CYAN}🧦 SOCKS5 / HTTP 代理管理${NC}"
        echo -e "     ${GRAY}sing-box · 用户认证 · 安全更新${NC}"
        echo -e "${PURPLE}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""; echo -n "  "; show_status; echo ""
        echo -e "  ${GREEN}1.${NC} 安装/切换 Mixed ${GRAY}(SOCKS5 + HTTP，明文/内网)${NC}"
        echo -e "  ${GREEN}2.${NC} 安装/切换 HTTPS Proxy ${GRAY}(公网推荐)${NC}"
        echo -e "  ${GREEN}3.${NC} 更新 sing-box"
        echo -e "  ${GREEN}4.${NC} 查看配置"
        echo -e "  ${GREEN}5.${NC} 查看日志"
        echo -e "  ${GREEN}6.${NC} 卸载"
        echo -e "  ${YELLOW}0.${NC} 退出"
        echo ""
        read -r -p "$(echo -e "  ${CYAN}请输入选项 [0-6]: ${NC}")" choice
        case "$choice" in
            1) log_warn "Mixed 模式不会加密传输内容和认证信息"; install_mode mixed ;;
            2) install_mode https ;;
            3) update_singbox ;;
            4) show_config ;;
            5) show_logs ;;
            6) uninstall_proxy ;;
            0) exit 0 ;;
            *) log_warn "无效选项"; sleep 1; continue ;;
        esac
        echo ""; read -r -p "$(echo -e "  ${GRAY}按回车返回菜单...${NC}")" _
    done
}

main
