#!/bin/bash

# ===================================================================
# TUIC v5 一键安装/管理脚本
# 基于持续维护的 Itsusinn/tuic 服务端，使用自签名 TLS 证书。
# 仓库: https://github.com/ridaiqianhe/vps-proxy
# 上游: https://github.com/Itsusinn/tuic
# ===================================================================

# 这是交互式脚本，不使用 set -e；每个关键步骤显式检查并回滚。

RED='\e[31m'; GREEN='\e[92m'; YELLOW='\e[93m'; BLUE='\e[94m'; CYAN='\e[96m'; PURPLE='\e[38;5;135m'; GRAY='\e[90m'; NC='\e[0m'

BIN_PATH="/usr/local/bin/tuic-server"
CONF_DIR="/etc/tuic"
CONF_FILE="$CONF_DIR/config.toml"
CERT_FILE="$CONF_DIR/server.crt"
KEY_FILE="$CONF_DIR/server.key"
META_FILE="$CONF_DIR/meta.env"
BACKUP_DIR="$CONF_DIR/backup"
SERVICE_FILE="/etc/systemd/system/tuic.service"
SERVICE_NAME="tuic"
SERVICE_USER="tuic"
SERVICE_GROUP="tuic"

GH_REPO="Itsusinn/tuic"
RELEASE_API="https://api.github.com/repos/$GH_REPO/releases?per_page=30"
DEFAULT_VERSION="v1.8.11"
DEFAULT_SNI="www.bing.com"

TEMP_DIR="$(mktemp -d /tmp/tuic_install.XXXXXX)" || {
    echo "[ERROR] 无法创建临时目录" >&2
    exit 1
}
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
        *) log_error "尚未检测包管理器"; return 1 ;;
    esac
}

ensure_dependencies() {
    detect_pkg_manager || return 1
    local -a packages=()
    command -v curl >/dev/null 2>&1 || packages+=(curl)
    command -v jq >/dev/null 2>&1 || packages+=(jq)
    command -v openssl >/dev/null 2>&1 || packages+=(openssl)
    command -v shuf >/dev/null 2>&1 || packages+=(coreutils)
    command -v ss >/dev/null 2>&1 || {
        if [ "$PKG_MANAGER" = "apt" ]; then packages+=(iproute2); else packages+=(iproute); fi
    }
    command -v sha256sum >/dev/null 2>&1 || packages+=(coreutils)
    command -v timeout >/dev/null 2>&1 || packages+=(coreutils)
    if [ "${#packages[@]}" -gt 0 ]; then
        log_info "安装依赖: ${packages[*]}"
        install_packages "${packages[@]}" >/dev/null 2>&1 || {
            log_error "依赖安装失败: ${packages[*]}"
            return 1
        }
    fi
    local command_name
    for command_name in curl jq openssl shuf ss sha256sum timeout; do
        command -v "$command_name" >/dev/null 2>&1 || {
            log_error "缺少依赖: $command_name"
            return 1
        }
    done
}

get_arch_asset() {
    case "$(uname -m)" in
        x86_64)  echo "tuic-server-x86_64-linux-musl" ;;
        aarch64) echo "tuic-server-aarch64-linux-musl" ;;
        armv7l)  echo "tuic-server-armv7-linux-muslhf" ;;
        *)
            log_error "TUIC 官方二进制不支持当前架构: $(uname -m)"
            return 1
            ;;
    esac
}

valid_version() {
    [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

strip_version_suffix() {
    local value="${1#v}"
    value="${value%%-*}"
    printf '%s\n' "$value" | sed 's/[^0-9.].*$//'
}

lowercase() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

version_at_least() {
    local have need i h n
    local -a have_parts need_parts
    have="$(strip_version_suffix "$1")"
    need="$(strip_version_suffix "$2")"
    IFS=. read -r -a have_parts <<< "$have"
    IFS=. read -r -a need_parts <<< "$need"
    for i in 0 1 2; do
        h="${have_parts[$i]:-0}"
        n="${need_parts[$i]:-0}"
        [[ "$h" =~ ^[0-9]+$ ]] || h=0
        [[ "$n" =~ ^[0-9]+$ ]] || n=0
        [ "$h" -gt "$n" ] && return 0
        [ "$h" -lt "$n" ] && return 1
    done
    return 0
}

get_default_digest() {
    local asset="$1"
    case "$asset" in
        tuic-server-x86_64-linux-musl)  echo "31ca6856b9b0ea947cf511a6811ea8b8b589879943cbc392eb4f7640168e7a22" ;;
        tuic-server-aarch64-linux-musl) echo "a1ce85b3c6a41a52ff3f36f518a6451219417f8701122e72a65c3a37f39d4860" ;;
        tuic-server-armv7-linux-muslhf) echo "28d16e7035d1a591cff62c5167a7058b08afaf7f59a5844e1e0dcc0ad1719702" ;;
        *) return 1 ;;
    esac
}

# 填充 RELEASE_TAG、RELEASE_ASSET、RELEASE_DIGEST、RELEASE_URL。
get_release_info() {
    local allow_fallback="${1:-0}" asset response release tag digest
    asset="$(get_arch_asset)" || return 1
    RELEASE_ASSET="$asset"

    response="$(curl -fsSL --retry 3 --connect-timeout 15 --max-time 45 \
        "$RELEASE_API" 2>/dev/null)"
    if [ -n "$response" ]; then
        release="$(printf '%s' "$response" | jq -er --arg asset "$asset" \
            '[.[]
             | select(.draft == false and .prerelease == false)
             | select(.tag_name | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))
             | . as $release
             | $release.assets[]?
             | select(.name == $asset)
             | select((.digest | type) == "string")
             | {tag_name: $release.tag_name, digest: .digest}
            ][0]' 2>/dev/null)"
        tag="$(printf '%s' "$release" | jq -er '.tag_name' 2>/dev/null)"
        digest="$(printf '%s' "$release" | jq -er '.digest' 2>/dev/null)"
        digest="${digest#sha256:}"
        if valid_version "$tag" && [[ "$digest" =~ ^[0-9a-fA-F]{64}$ ]]; then
            RELEASE_TAG="$tag"
            RELEASE_DIGEST="$(lowercase "$digest")"
            RELEASE_URL="https://github.com/$GH_REPO/releases/download/$tag/$asset"
            return 0
        fi
    fi

    if [ "$allow_fallback" = "1" ]; then
        RELEASE_TAG="$DEFAULT_VERSION"
        RELEASE_DIGEST="$(get_default_digest "$asset")" || {
            log_error "没有可用的 TUIC $asset 校验值"
            return 1
        }
        RELEASE_URL="https://github.com/$GH_REPO/releases/download/$RELEASE_TAG/$asset"
        log_warn "无法读取 GitHub 最新稳定版，首次安装使用已固定校验值的 $RELEASE_TAG"
        return 0
    fi

    log_error "无法获取带 SHA-256 校验值的 TUIC 最新稳定版，已停止更新"
    return 1
}

download_server() {
    local destination="$TEMP_DIR/tuic-server" actual expected
    log_info "下载 TUIC $RELEASE_TAG ($RELEASE_ASSET)..."
    if ! curl -fL --retry 3 --connect-timeout 15 --max-time 180 \
        "$RELEASE_URL" -o "$destination"; then
        log_error "下载 TUIC 失败: $RELEASE_URL"
        return 1
    fi
    chmod 755 "$destination"
    actual="$(sha256sum "$destination" | awk '{print tolower($1)}')"
    expected="$(lowercase "$RELEASE_DIGEST")"
    if [ "$actual" != "$expected" ]; then
        log_error "TUIC 二进制 SHA-256 校验失败"
        log_error "期望: $expected，实际: $actual"
        return 1
    fi
    if [ ! -x "$destination" ]; then
        log_error "下载的 TUIC 文件不可执行"
        return 1
    fi
    log_info "二进制校验通过: $actual"
}

is_port_in_use() {
    local port="$1"
    ss -H -ltnu 2>/dev/null | awk -v port="$port" '
        $5 ~ (":" port "$") { found = 1 }
        END { exit(found ? 0 : 1) }
    '
}

get_random_free_port() {
    local port
    for _ in $(seq 1 40); do
        port="$(shuf -i 20000-65000 -n 1)"
        if ! is_port_in_use "$port"; then
            printf '%s\n' "$port"
            return 0
        fi
    done
    return 1
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_domain() {
    local value="$1"
    [ "${#value}" -le 253 ] || return 1
    [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]
}

valid_password() {
    [[ "$1" =~ ^[A-Za-z0-9._~@+-]{8,128}$ ]]
}

valid_uuid() {
    [[ "$1" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]
}

gen_uuid() {
    local uuid
    if [ -r /proc/sys/kernel/random/uuid ]; then
        IFS= read -r uuid < /proc/sys/kernel/random/uuid
    else
        uuid="$(openssl rand -hex 16 2>/dev/null | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/')"
    fi
    valid_uuid "$uuid" && printf '%s\n' "$uuid"
}

random_password() {
    openssl rand -hex 16 2>/dev/null || LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32
}

choose_port() {
    local default_port="$1" allowed_port="${2:-}" value random_port
    valid_port "$default_port" || default_port="$(get_random_free_port)" || return 1
    while true; do
        value=""
        read -r -p "$(echo -e "${CYAN}◆ 对外 UDP 端口 ${GRAY}(回车用 ${GREEN}$default_port${GRAY})${CYAN}: ${NC}")" value
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

choose_password() {
    local default_password="$1" value
    [ -n "$default_password" ] || default_password="$(random_password)"
    while true; do
        value=""
        read -r -p "$(echo -e "${CYAN}◆ TUIC 密码 ${GRAY}(回车用 ${GREEN}$default_password${GRAY})${CYAN}: ${NC}")" value
        value="${value:-$default_password}"
        if ! valid_password "$value"; then
            log_warn "密码需为 8-128 位字母、数字或 . _ ~ @ + -"
            continue
        fi
        printf '%s\n' "$value"
        return 0
    done
}

choose_sni() {
    local old_sni="$1" default_choice=1 choice custom i
    local -a options=("www.bing.com" "www.microsoft.com" "www.apple.com" "s0.awsstatic.com" "swscan.apple.com")
    for i in "${!options[@]}"; do
        if [ "${options[$i]}" = "$old_sni" ]; then default_choice=$((i + 1)); break; fi
    done
    if [ -n "$old_sni" ] && [ "$default_choice" = 1 ] && [ "$old_sni" != "${options[0]}" ]; then default_choice=6; fi
    echo "请选择 TLS SNI 伪装域名（自签证书） (默认 $default_choice):" >&2
    for i in "${!options[@]}"; do echo "$((i + 1)). ${options[$i]}" >&2; done
    echo "6. 手动输入域名" >&2
    while true; do
        choice=""
        read -r -p "$(echo -e "${CYAN}输入选项 [默认 $default_choice]: ${NC}")" choice
        choice="${choice:-$default_choice}"
        if [[ "$choice" =~ ^[1-5]$ ]]; then
            printf '%s\n' "${options[$((choice - 1))]}"
            return 0
        fi
        if [ "$choice" = "6" ]; then
            custom=""
            read -r -p "$(echo -e "${CYAN}输入 TLS SNI 域名 (默认 ${old_sni:-${options[0]}}): ${NC}")" custom
            custom="${custom:-${old_sni:-${options[0]}}}"
            if valid_domain "$custom"; then
                printf '%s\n' "$custom"
                return 0
            fi
            log_warn "域名格式无效"
        else
            log_warn "无效选项，请输入 1-6"
        fi
    done
}

get_meta_value() {
    local key="$1"
    [ -f "$META_FILE" ] || return 1
    awk -v key="$key" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' "$META_FILE"
}

extract_existing_credentials() {
    local uuid password
    [ -f "$CONF_FILE" ] || return 1
    uuid="$(awk '
        /^\[users\][[:space:]]*$/ { in_users = 1; next }
        /^\[/ { in_users = 0 }
        in_users && /^[[:space:]]*"?[0-9A-Fa-f-]{36}"?[[:space:]]*=/ {
            line = $0
            sub(/^[[:space:]]*"?/, "", line)
            sub(/"?[[:space:]]*=.*/, "", line)
            print line
            exit
        }
    ' "$CONF_FILE" 2>/dev/null)"
    password="$(awk -v wanted="$uuid" '
        /^\[users\][[:space:]]*$/ { in_users = 1; next }
        /^\[/ { in_users = 0 }
        in_users && index($0, wanted) > 0 && index($0, "=") > 0 {
            value = substr($0, index($0, "=") + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            gsub(/^"|"$/, "", value)
            print value
            exit
        }
    ' "$CONF_FILE" 2>/dev/null)"
    valid_uuid "$uuid" || return 1
    valid_password "$password" || return 1
    EXISTING_UUID="$uuid"
    EXISTING_PASSWORD="$password"
}

get_host_ip() {
    local ip
    ip="$(curl -4 -fsSL --connect-timeout 8 --max-time 12 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || ip=""
    if [ -z "$ip" ]; then
        ip="$(curl -6 -fsSL --connect-timeout 8 --max-time 12 https://ifconfig.co 2>/dev/null | tr -d '[:space:]')"
        [[ "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:.]+$ ]] || ip=""
    fi
    if [ -z "$ip" ]; then
        ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi
    printf '%s\n' "$ip"
}

ensure_service_user() {
    local nologin
    nologin="$(command -v nologin 2>/dev/null || echo /usr/sbin/nologin)"
    if ! getent group "$SERVICE_GROUP" >/dev/null 2>&1; then
        groupadd --system "$SERVICE_GROUP" >/dev/null 2>&1 || {
            log_error "无法创建 TUIC 系统组"
            return 1
        }
    fi
    if id "$SERVICE_USER" >/dev/null 2>&1; then return 0; fi
    useradd --system --gid "$SERVICE_GROUP" --no-create-home --shell "$nologin" "$SERVICE_USER" >/dev/null 2>&1 || {
        log_error "无法创建 TUIC 系统用户"
        return 1
    }
}

generate_certificate() {
    local sni="$1" cert="$TEMP_DIR/server.crt" key="$TEMP_DIR/server.key" openssl_conf="$TEMP_DIR/openssl.cnf"
    cat > "$openssl_conf" << EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = $sni

[v3_req]
subjectAltName = DNS:$sni
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
EOF
    log_info "生成自签名 TLS 证书（客户端需开启 skip-cert-verify）"
    if ! openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
        -config "$openssl_conf" -keyout "$key" -out "$cert" >/dev/null 2>&1; then
        log_error "自签名证书生成失败"
        return 1
    fi
    [ -s "$cert" ] && [ -s "$key" ] || {
        log_error "自签名证书文件为空"
        return 1
    }
    openssl x509 -in "$cert" -noout >/dev/null 2>&1 || {
        log_error "生成的证书校验失败"
        return 1
    }
}

write_config() {
    local port="$1" uuid="$2" password="$3" sni="$4" generated="$TEMP_DIR/config.toml"
    cat > "$generated" << EOF
# TUIC v5 server configuration
log_level = "warn"
server = "[::]:$port"
udp_relay_ipv6 = true
zero_rtt_handshake = false
dual_stack = true
max_external_packet_size = 1500

[tls]
self_sign = false
certificate = "$CERT_FILE"
private_key = "$KEY_FILE"
alpn = ["h3"]
hostname = "$sni"
auto_ssl = false

[quic]
initial_mtu = 1200
min_mtu = 1200
gso = true
pmtu = true

[quic.congestion_control]
controller = "bbr"

[users]
"$uuid" = "$password"
EOF
    [ -s "$generated" ] || {
        log_error "生成 TUIC 配置失败"
        return 1
    }
}

write_metadata() {
    local port="$1" uuid="$2" password="$3" sni="$4" version="$5" generated="$TEMP_DIR/meta.env"
    cat > "$generated" << EOF
FORMAT=tuic-v5-v2
PORT=$port
UUID=$uuid
PASSWORD=$password
SNI=$sni
VERSION=$version
ASSET=$RELEASE_ASSET
EOF
    [ -s "$generated" ] || {
        log_error "生成 TUIC 元数据失败"
        return 1
    }
}

write_service() {
    cat > "$TEMP_DIR/tuic.service" << EOF
[Unit]
Description=TUIC v5 Server (Itsusinn)
Documentation=https://github.com/Itsusinn/tuic
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_GROUP
WorkingDirectory=$CONF_DIR
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=$BIN_PATH --config $CONF_FILE
StandardOutput=journal
StandardError=journal
SyslogIdentifier=tuic
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

install_file() {
    local source="$1" target="$2" mode="$3" owner="$4" group="$5"
    install -m "$mode" -o "$owner" -g "$group" "$source" "$target"
}

backup_current_files() {
    local timestamp backup_path item source suffix
    if [ ! -e "$BIN_PATH" ] && [ ! -e "$CONF_FILE" ] && [ ! -e "$CERT_FILE" ] && \
        [ ! -e "$KEY_FILE" ] && [ ! -e "$META_FILE" ] && [ ! -e "$SERVICE_FILE" ]; then
        return 0
    fi
    timestamp="$(date '+%Y%m%d_%H%M%S')"
    backup_path="$BACKUP_DIR/$timestamp"
    suffix=0
    while [ -e "$backup_path" ]; do
        suffix=$((suffix + 1))
        backup_path="$BACKUP_DIR/${timestamp}_$suffix"
    done
    install -d -m 0700 -o root -g root "$backup_path" || return 1
    for item in binary config cert key meta service; do
        case "$item" in
            binary) source="$BIN_PATH" ;;
            config) source="$CONF_FILE" ;;
            cert) source="$CERT_FILE" ;;
            key) source="$KEY_FILE" ;;
            meta) source="$META_FILE" ;;
            service) source="$SERVICE_FILE" ;;
        esac
        if [ -f "$source" ] && ! cp -p "$source" "$backup_path/$item"; then
            log_error "无法备份现有文件: $source"
            return 1
        fi
    done
    log_info "现有 TUIC 文件已备份到: $backup_path"
}

backup_to_temp() {
    local item source
    PREVIOUS_SERVICE_PRESENT=0
    PREVIOUS_SERVICE_ACTIVE=0
    PREVIOUS_SERVICE_ENABLED=0
    [ -f "$SERVICE_FILE" ] && PREVIOUS_SERVICE_PRESENT=1
    systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null && PREVIOUS_SERVICE_ACTIVE=1
    systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null && PREVIOUS_SERVICE_ENABLED=1
    for item in binary config cert key meta service; do
        case "$item" in
            binary) source="$BIN_PATH" ;;
            config) source="$CONF_FILE" ;;
            cert) source="$CERT_FILE" ;;
            key) source="$KEY_FILE" ;;
            meta) source="$META_FILE" ;;
            service) source="$SERVICE_FILE" ;;
        esac
        if [ -f "$source" ] && ! cp -p "$source" "$TEMP_DIR/$item.previous"; then
            log_error "无法读取现有 TUIC 文件进行回滚: $source"
            return 1
        fi
    done
}

restore_previous_files() {
    log_warn "安装失败，恢复安装前状态"
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    local item previous target mode owner group
    for item in binary config cert key meta service; do
        previous="$TEMP_DIR/$item.previous"
        case "$item" in
            binary) target="$BIN_PATH"; mode=0755; owner=root; group=root ;;
            config) target="$CONF_FILE"; mode=0640; owner=root; group="$SERVICE_GROUP" ;;
            cert) target="$CERT_FILE"; mode=0640; owner=root; group="$SERVICE_GROUP" ;;
            key) target="$KEY_FILE"; mode=0640; owner=root; group="$SERVICE_GROUP" ;;
            meta) target="$META_FILE"; mode=0600; owner=root; group=root ;;
            service) target="$SERVICE_FILE"; mode=0644; owner=root; group=root ;;
        esac
        if [ -f "$previous" ]; then
            install -d -m 0750 -o root -g "$SERVICE_GROUP" "$CONF_DIR" >/dev/null 2>&1 || true
            install_file "$previous" "$target" "$mode" "$owner" "$group" >/dev/null 2>&1 || true
        else
            rm -f "$target"
        fi
    done
    systemctl daemon-reload >/dev/null 2>&1 || true
    if [ "$PREVIOUS_SERVICE_PRESENT" = 1 ]; then
        if [ "$PREVIOUS_SERVICE_ENABLED" = 1 ]; then
            systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
        else
            systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
        fi
        if [ "$PREVIOUS_SERVICE_ACTIVE" = 1 ]; then
            systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || log_error "原 TUIC 服务恢复启动失败"
        fi
    else
        systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    fi
}

validate_generated_config() {
    local output="$TEMP_DIR/tuic-validate.log" status
    # v1.8.x 没有单独的 check 子命令，短暂启动可同时校验 TOML、证书、用户和监听端口。
    if timeout --signal=TERM --kill-after=2s 3 "$BIN_PATH" \
        --config "$CONF_FILE" >"$output" 2>&1; then
        status=0
    else
        status=$?
    fi
    if [ "$status" -eq 124 ] || [ "$status" -eq 137 ] || [ "$status" -eq 143 ]; then
        return 0
    fi
    log_error "TUIC 配置/启动预检失败"
    tail -n 30 "$output" >&2 || true
    return 1
}

get_binary_version() {
    local output version
    [ -x "$1" ] || return 1
    output="$("$1" --version 2>/dev/null || "$1" -v 2>/dev/null)"
    version="$(printf '%s\n' "$output" | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)"
    [ -n "$version" ] && { [[ "$version" == v* ]] || version="v$version"; printf '%s\n' "$version"; }
}

deploy_tuic() {
    local mode="$1" old_port old_uuid old_password old_sni
    local port uuid password sni current_version

    if [ "$mode" = "update" ]; then
        old_port="$(get_meta_value PORT 2>/dev/null)"
        old_uuid="$(get_meta_value UUID 2>/dev/null)"
        old_password="$(get_meta_value PASSWORD 2>/dev/null)"
        old_sni="$(get_meta_value SNI 2>/dev/null)"
        if ! valid_port "$old_port" || ! valid_uuid "$old_uuid" || \
            ! valid_password "$old_password" || ! valid_domain "$old_sni"; then
            EXISTING_UUID=""; EXISTING_PASSWORD=""
            extract_existing_credentials || {
                log_error "无法安全读取现有 TUIC 凭据，未执行更新"
                return 1
            }
            old_uuid="$EXISTING_UUID"
            old_password="$EXISTING_PASSWORD"
            valid_domain "$old_sni" || old_sni="$DEFAULT_SNI"
            valid_port "$old_port" || {
                log_error "无法读取现有 TUIC 端口，未执行更新"
                return 1
            }
        fi
        port="$old_port"
        uuid="$old_uuid"
        password="$old_password"
        sni="$old_sni"
    else
        port="$(get_random_free_port)" || {
            log_error "无法找到空闲端口"
            return 1
        }
        uuid="$(gen_uuid)" || {
            log_error "无法生成 UUID"
            return 1
        }
        password="$(random_password)"
        sni="$DEFAULT_SNI"
        port="$(choose_port "$port")" || return 1
        password="$(choose_password "$password")" || return 1
        sni="$(choose_sni "$sni")" || return 1
    fi

    current_version="$(get_binary_version "$BIN_PATH" 2>/dev/null || true)"
    if [ "$mode" = "update" ] && [ -n "$current_version" ] && version_at_least "$current_version" "$RELEASE_TAG"; then
        log_info "当前 TUIC $current_version 不低于目标 $RELEASE_TAG，仍将校验并重新部署"
    fi

    if ! backup_to_temp; then
        log_error "无法准备回滚副本，未进行更新"
        return 1
    fi
    backup_current_files || {
        log_error "备份现有 TUIC 文件失败，未进行更新"
        return 1
    }

    if [ "$PREVIOUS_SERVICE_ACTIVE" = 1 ]; then
        if ! systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
            log_error "无法停止现有 TUIC 服务，未写入新配置"
            return 1
        fi
    fi

    if [ "$mode" = "update" ] && [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        cp -p "$CERT_FILE" "$TEMP_DIR/server.crt"
        cp -p "$KEY_FILE" "$TEMP_DIR/server.key"
    else
        generate_certificate "$sni" || { restore_previous_files; return 1; }
    fi
    write_config "$port" "$uuid" "$password" "$sni" || { restore_previous_files; return 1; }
    write_metadata "$port" "$uuid" "$password" "$sni" "$RELEASE_TAG" || { restore_previous_files; return 1; }
    write_service || { restore_previous_files; return 1; }

    install -d -m 0750 -o root -g "$SERVICE_GROUP" "$CONF_DIR" || { restore_previous_files; return 1; }
    install_file "$TEMP_DIR/tuic-server" "$BIN_PATH" 0755 root root || { restore_previous_files; return 1; }
    install_file "$TEMP_DIR/server.crt" "$CERT_FILE" 0640 root "$SERVICE_GROUP" || { restore_previous_files; return 1; }
    install_file "$TEMP_DIR/server.key" "$KEY_FILE" 0640 root "$SERVICE_GROUP" || { restore_previous_files; return 1; }
    install_file "$TEMP_DIR/config.toml" "$CONF_FILE" 0640 root "$SERVICE_GROUP" || { restore_previous_files; return 1; }
    install_file "$TEMP_DIR/meta.env" "$META_FILE" 0600 root root || { restore_previous_files; return 1; }
    install_file "$TEMP_DIR/tuic.service" "$SERVICE_FILE" 0644 root root || { restore_previous_files; return 1; }

    if ! validate_generated_config; then
        restore_previous_files
        return 1
    fi
    if ! systemctl daemon-reload; then
        log_error "systemd 配置重载失败"
        restore_previous_files
        return 1
    fi
    if ! systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || ! systemctl restart "$SERVICE_NAME"; then
        log_error "TUIC 服务启动失败"
        journalctl -u "$SERVICE_NAME" -n 30 --no-pager --output cat >&2 || true
        restore_previous_files
        return 1
    fi
    sleep 1
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        log_error "TUIC 服务未运行"
        journalctl -u "$SERVICE_NAME" -n 30 --no-pager --output cat >&2 || true
        restore_previous_files
        return 1
    fi
    if [ "$mode" = "update" ]; then
        log_info "TUIC 已更新到 $RELEASE_TAG，端口和客户端凭据保持不变"
    else
        log_info "TUIC $RELEASE_TAG 安装成功"
    fi
    show_config
}

install_tuic() {
    ensure_dependencies || return 1
    ensure_service_user || return 1
    if [ -f "$SERVICE_FILE" ] || [ -f "$META_FILE" ] || [ -f "$CONF_FILE" ] || \
        [ -f "$CERT_FILE" ] || [ -f "$KEY_FILE" ]; then
        log_warn "检测到已有 TUIC 安装；安装操作将转为安全更新并保留现有凭据"
        update_tuic
        return $?
    fi
    get_release_info 1 || return 1
    download_server || return 1
    deploy_tuic install
}

update_tuic() {
    local current_version
    ensure_dependencies || return 1
    ensure_service_user || return 1
    if [ ! -f "$SERVICE_FILE" ] && [ ! -f "$META_FILE" ] && [ ! -f "$CONF_FILE" ] && \
        [ ! -f "$CERT_FILE" ] && [ ! -f "$KEY_FILE" ]; then
        log_error "未找到 TUIC 安装，请先执行安装"
        return 1
    fi
    get_release_info 0 || return 1
    current_version="$(get_binary_version "$BIN_PATH" 2>/dev/null || true)"
    if [ -n "$current_version" ] && version_at_least "$current_version" "$RELEASE_TAG"; then
        if [ "$current_version" != "$RELEASE_TAG" ]; then
            log_warn "当前 TUIC $current_version 高于稳定版 $RELEASE_TAG，跳过降级"
            return 0
        fi
        log_info "当前 TUIC 已是稳定版 $RELEASE_TAG，将重新校验并重写配置"
    fi
    download_server || return 1
    deploy_tuic update
}

uninstall_tuic() {
    if [ ! -f "$SERVICE_FILE" ] && [ ! -f "$META_FILE" ] && \
        [ ! -f "$BIN_PATH" ] && [ ! -f "$CONF_FILE" ] && \
        [ ! -f "$CERT_FILE" ] && [ ! -f "$KEY_FILE" ]; then
        log_error "TUIC 未安装"
        return 0
    fi
    read -r -p "$(echo -e "${YELLOW}确认卸载 TUIC？将删除配置、证书和备份 [输入 yes 确认]: ${NC}")" answer
    [ "$answer" = "yes" ] || { log_info "已取消"; return 0; }
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE" "$BIN_PATH"
    rm -rf "$CONF_DIR"
    systemctl daemon-reload >/dev/null 2>&1 || true
    log_info "TUIC 已卸载"
}

show_config() {
    [ -f "$META_FILE" ] || { log_error "未找到配置，请先安装"; return 1; }
    local PORT UUID PASSWORD SNI VERSION HOST COUNTRY DISPLAY_HOST
    PORT="$(get_meta_value PORT)"
    UUID="$(get_meta_value UUID)"
    PASSWORD="$(get_meta_value PASSWORD)"
    SNI="$(get_meta_value SNI)"
    VERSION="$(get_meta_value VERSION)"
    [ -n "$VERSION" ] || VERSION="$(get_binary_version "$BIN_PATH" 2>/dev/null || true)"
    [ -n "$VERSION" ] || VERSION="unknown"
    if ! valid_port "$PORT" || ! valid_uuid "$UUID" || ! valid_password "$PASSWORD" || ! valid_domain "$SNI"; then
        log_error "TUIC 元数据不完整或已损坏，请执行更新"
        return 1
    fi
    HOST="$(get_host_ip)"
    [ -n "$HOST" ] || HOST="YOUR_SERVER_IP"
    COUNTRY="$(curl -fsSL --connect-timeout 5 --max-time 8 "https://ipinfo.io/$HOST/country" 2>/dev/null | tr -d '[:space:]')"
    [[ "$COUNTRY" =~ ^[A-Za-z]{2}$ ]] || COUNTRY="XX"
    DISPLAY_HOST="$HOST"
    [[ "$DISPLAY_HOST" == *:* ]] && DISPLAY_HOST="[$DISPLAY_HOST]"

    echo ""
    echo -e "${CYAN}============= TUIC v5 配置信息 =============${NC}"
    echo -e "${BLUE}版本: $VERSION${NC}"
    echo -e "${BLUE}地址: $HOST   UDP 端口: $PORT${NC}"
    echo -e "${BLUE}UUID: $UUID${NC}"
    echo -e "${BLUE}密码: $PASSWORD   SNI: $SNI (自签证书)${NC}"
    echo ""
    echo -e "${YELLOW}--- Surge 配置行（TUIC v5）---${NC}"
    echo "$COUNTRY-tuic = tuic-v5, $DISPLAY_HOST, $PORT, uuid=$UUID, password=$PASSWORD, sni=$SNI, alpn=h3, skip-cert-verify=true"
    echo ""
    echo -e "${YELLOW}--- mihomo 配置片段（TUIC v5）---${NC}"
    cat << EOF
  - name: $COUNTRY-tuic
    type: tuic
    server: "$HOST"
    port: $PORT
    uuid: $UUID
    password: "$PASSWORD"
    alpn: [h3]
    congestion-controller: bbr
    udp-relay-mode: native
    sni: $SNI
    skip-cert-verify: true
    udp: true
EOF
    echo ""
    echo -e "${YELLOW}--- sing-box 客户端 outbound ---${NC}"
    cat << EOF
{
  "type": "tuic",
  "tag": "tuic",
  "server": "$HOST",
  "server_port": $PORT,
  "uuid": "$UUID",
  "password": "$PASSWORD",
  "congestion_control": "bbr",
  "udp_relay_mode": "native",
  "tls": {
    "enabled": true,
    "server_name": "$SNI",
    "alpn": ["h3"],
    "insecure": true
  }
}
EOF
    echo -e "${GRAY}客户端使用自签名证书时需要开启 skip-cert-verify/insecure；生产环境建议换用受信任证书。${NC}"
    echo -e "${CYAN}=============================================${NC}"
    echo ""
}

show_logs() {
    [ -f "$SERVICE_FILE" ] || { log_error "TUIC 未安装"; return 1; }
    command -v journalctl >/dev/null 2>&1 || { log_error "当前系统未找到 journalctl"; return 1; }
    echo -e "${YELLOW}--- TUIC 最近日志 ---${NC}"
    journalctl -u "$SERVICE_NAME" -n 100 --no-pager --output cat
}

show_status() {
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
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
        echo -e "     ${GRAY}QUIC 加速 · 自签证书 · Itsusinn/tuic${NC}"
        echo -e "${PURPLE}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -n "  "; show_status
        echo ""
        echo -e "  ${GREEN}1.${NC} ⚡ 安装 TUIC"
        echo -e "  ${GREEN}2.${NC} 🗑️  卸载 TUIC"
        echo -e "  ${GREEN}3.${NC} 📋 查看配置"
        echo -e "  ${GREEN}4.${NC} ⬆️  更新 TUIC"
        echo -e "  ${GREEN}5.${NC} 📜 查看日志"
        echo -e "  ${YELLOW}0.${NC} 👋 退出"
        echo ""
        read -r -p "$(echo -e "  ${CYAN}请输入选项 [0-5]: ${NC}")" choice
        case "$choice" in
            1) install_tuic ;;
            2) uninstall_tuic ;;
            3) show_config ;;
            4) update_tuic ;;
            5) show_logs ;;
            0) echo -e "  ${PURPLE}バイバイ~ (｡･ω･)ﾉﾞ${NC}"; exit 0 ;;
            *) echo -e "  ${YELLOW}(・_・?) 没有「$choice」这个选项~${NC}"; sleep 1; continue ;;
        esac
        echo ""
        read -r -p "$(echo -e "  ${GRAY}按回车返回菜单...${NC}")" _
    done
}

main
