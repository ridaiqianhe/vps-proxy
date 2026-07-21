#!/bin/bash

# Snell 管理脚本
# 功能: 安装、更新、卸载 Snell (Shadow-TLS 加壳请用 shadow-tls.sh)

# 不用 set -e: 这是交互式菜单脚本,单次操作失败应回到菜单而不是整体退出;
# 真正致命的错误各步骤内已用 "if ! ...; then ...; exit 1" 显式处理

# 全局变量
LATEST_VERSION=""   # v5 稳定版(兼容选项)
V6_VERSION=""       # v6 主版本，自动跟随 Beta/RC/正式版
VERSION_CACHE_FILE="/etc/snell/version_cache"  # 放在 root 专属目录，避免 /tmp 下被其他用户预植入
INSTALLED_VERSION_FILE="/etc/snell/installed_version"
VERSION_CACHE_TIMEOUT=3600  # 1小时缓存
VERSION_CACHE_SCHEMA=2
TEMP_DIR="$(mktemp -d /tmp/snell_install.XXXXXX)"
LOG_FILE="/var/log/snell_install.log"
MAX_RETRIES=3
RETRY_DELAY=2

trap 'cleanup_temp_files' EXIT

# 颜色定义(二次元紫彩)
RED='\e[31m'
GREEN='\e[92m'
YELLOW='\e[93m'
BLUE='\e[94m'
CYAN='\e[96m'
PURPLE='\e[38;5;135m'
GRAY='\e[90m'
NC='\e[0m'  # No Color

# 清理临时文件
cleanup_temp_files() {
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}

# 日志记录函数
# 注意: 全部输出到 stderr —— 本脚本大量使用 $(func) 捕获返回值,
# 日志若走 stdout 会被一并捕获混入端口/密码等变量
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE" >&2
}

# 错误日志记录
log_error() {
    echo -e "${RED}[ERROR] $1${NC}" | tee -a "$LOG_FILE" >&2
}

# 警告日志记录
log_warn() {
    echo -e "${YELLOW}[WARN] $1${NC}" | tee -a "$LOG_FILE" >&2
}

# 信息日志记录
log_info() {
    echo -e "${GREEN}[INFO] $1${NC}" | tee -a "$LOG_FILE" >&2
}

# 步骤进度显示
show_progress() {
    local current=$1
    local total=$2
    local task=$3
    printf "${CYAN}[%d/%d]${NC} %s\n" "$current" "$total" "$task" >&2
}

# 网络请求重试函数
retry_command() {
    local cmd="$1"
    local retries=0
    
    while [ $retries -lt $MAX_RETRIES ]; do
        if eval "$cmd"; then
            return 0
        fi
        retries=$((retries + 1))
        if [ $retries -lt $MAX_RETRIES ]; then
            log_warn "命令执行失败，${RETRY_DELAY}秒后重试 ($retries/$MAX_RETRIES)"
            sleep $RETRY_DELAY
        fi
    done
    
    log_error "命令执行失败，已达到最大重试次数: $cmd"
    return 1
}

# 文件完整性校验
verify_file_integrity() {
    local file_path="$1"
    local expected_size="$2"
    
    if [ ! -f "$file_path" ]; then
        log_error "文件不存在: $file_path"
        return 1
    fi
    
    local actual_size=$(stat -c%s "$file_path" 2>/dev/null || stat -f%z "$file_path" 2>/dev/null)
    if [ "$actual_size" -lt "$expected_size" ]; then
        log_error "文件大小异常: $file_path (实际: $actual_size, 期望: > $expected_size)"
        return 1
    fi

    # zip 文件额外做完整性测试，大小检查发现不了损坏的压缩包
    if [[ "$file_path" == *.zip ]] && ! unzip -tq "$file_path" >/dev/null 2>&1; then
        log_error "压缩包完整性校验失败: $file_path"
        return 1
    fi

    return 0
}

# 检测包管理器 (支持 apt/dnf/yum)
detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_UPDATE="apt-get update -qq"
        PKG_INSTALL="apt-get install -y"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_UPDATE="dnf makecache -q"
        PKG_INSTALL="dnf install -y"
    elif command -v yum >/dev/null 2>&1; then
        PKG_UPDATE="yum makecache -q"
        PKG_INSTALL="yum install -y"
    else
        log_error "未找到受支持的包管理器 (apt/dnf/yum)，请手动安装依赖: unzip wget curl"
        exit 1
    fi
}

# 生成未被占用的随机端口
get_random_free_port() {
    local port=""
    for _ in $(seq 1 20); do
        port=$(shuf -i 30000-65000 -n 1)
        if ! ss -tuln 2>/dev/null | grep -q ":$port "; then
            echo "$port"
            return 0
        fi
    done
    log_warn "多次尝试均未找到空闲端口，使用最后一次结果: $port"
    echo "$port"
}

# 提示用户需要 root 权限运行脚本
if [ "$(id -u)" != "0" ]; then
    log_error "请以 root 权限运行此脚本."
    exit 1
fi

country_to_flag() {
    local country_code=$1
    
    # 如果国家代码为空或无效，返回默认标志
    if [ -z "$country_code" ] || [ ${#country_code} -ne 2 ]; then
        echo "🌍"
        return
    fi
    
    # 转换为大写
    country_code=$(echo "$country_code" | tr '[:lower:]' '[:upper:]')
    
    # 使用预定义的常见国家标志映射
    case "$country_code" in
        "US") echo "🇺🇸" ;;
        "CN") echo "🇨🇳" ;;
        "JP") echo "🇯🇵" ;;
        "KR") echo "🇰🇷" ;;
        "HK") echo "🇭🇰" ;;
        "TW") echo "🇹🇼" ;;
        "SG") echo "🇸🇬" ;;
        "DE") echo "🇩🇪" ;;
        "GB") echo "🇬🇧" ;;
        "FR") echo "🇫🇷" ;;
        "CA") echo "🇨🇦" ;;
        "AU") echo "🇦🇺" ;;
        "RU") echo "🇷🇺" ;;
        "IN") echo "🇮🇳" ;;
        "BR") echo "🇧🇷" ;;
        "NL") echo "🇳🇱" ;;
        "SE") echo "🇸🇪" ;;
        "CH") echo "🇨🇭" ;;
        "IT") echo "🇮🇹" ;;
        "ES") echo "🇪🇸" ;;
        *) echo "🌍" ;;  # 默认地球标志
    esac
}

get_host_ip() {
    if HOST_IP=$(retry_command "curl -s --connect-timeout 10 --max-time 30 http://checkip.amazonaws.com"); then
        if [[ $HOST_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            return 0
        fi
    fi
    
    # 备用方法
    if HOST_IP=$(retry_command "curl -s --connect-timeout 5 ipinfo.io/ip"); then
        if [[ $HOST_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            return 0
        fi
    fi
    
    log_error "无法获取公网IP地址"
    return 1
}

# 架构检测和下载链接构建
get_download_url() {
    local version="$1"
    local arch="$2"
    local url=""
    
    case "$arch" in
        "aarch64")
            url="https://dl.nssurge.com/snell/snell-server-${version}-linux-aarch64.zip"
            ;;
        "armv7l")
            url="https://dl.nssurge.com/snell/snell-server-${version}-linux-armv7l.zip"
            ;;
        "i386"|"i686")
            url="https://dl.nssurge.com/snell/snell-server-${version}-linux-i386.zip"
            ;;
        "x86_64")
            url="https://dl.nssurge.com/snell/snell-server-${version}-linux-amd64.zip"
            ;;
        *) log_error "不支持的系统架构: $arch"; return 1 ;;
    esac
    
    echo "$url"
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "x86_64" ;;
        i386|i486|i586|i686) echo "i386" ;;
        aarch64|arm64) echo "aarch64" ;;
        armv7|armv7l) echo "armv7l" ;;
        *) log_error "不支持的系统架构: $(uname -m)"; return 1 ;;
    esac
}

# v6 官方不再提供 armv7l 构建。
is_version_supported_on_arch() {
    local version="$1"
    local arch="$2"

    if [[ "$version" == v6* ]] && [ "$arch" = "armv7l" ]; then
        return 1
    fi
    return 0
}

# 兼容旧单地址格式与 v6 的逗号分隔多地址格式。
get_snell_port_from_config() {
    local config_file="$1"
    local listen_value endpoint port

    listen_value=$(awk -F '=' '/^[[:space:]]*listen[[:space:]]*=/ {print substr($0, index($0, "=") + 1); exit}' "$config_file" 2>/dev/null)
    endpoint=${listen_value%%,*}
    port=${endpoint##*:}
    port=$(printf '%s' "$port" | tr -d '[:space:]')
    validate_port "$port" && printf '%s\n' "$port"
}

normalize_listen_config() {
    local config_file="$1"
    local version="$2"
    local port listen_value

    port=$(get_snell_port_from_config "$config_file") || return 1
    if [[ "$version" == v6* ]]; then
        listen_value="0.0.0.0:$port,[::]:$port"
    else
        listen_value="0.0.0.0:$port"
    fi
    sed -i "s|^[[:space:]]*listen[[:space:]]*=.*$|listen = $listen_value|" "$config_file"
}

detect_service_identity() {
    local user
    for user in nobody daemon; do
        if id "$user" >/dev/null 2>&1; then
            SERVICE_USER="$user"
            SERVICE_GROUP=$(id -gn "$user")
            return 0
        fi
    done
    log_error "未找到可用于运行 Snell 的低权限系统账户 (nobody/daemon)"
    return 1
}

is_snell_installed() {
    systemctl cat snell.service >/dev/null 2>&1
}

# 版本信息缓存管理
is_cache_valid() {
    if [ -f "$VERSION_CACHE_FILE" ]; then
        local cache_time=$(stat -c %Y "$VERSION_CACHE_FILE" 2>/dev/null || stat -f %m "$VERSION_CACHE_FILE" 2>/dev/null)
        local current_time=$(date +%s)
        local age=$((current_time - cache_time))
        
        if [ "$age" -lt "$VERSION_CACHE_TIMEOUT" ]; then
            return 0
        fi
    fi
    return 1
}

save_version_cache() {
    mkdir -p "$(dirname "$VERSION_CACHE_FILE")"
    cat > "$VERSION_CACHE_FILE" << EOF
CACHE_SCHEMA="$VERSION_CACHE_SCHEMA"
LATEST_VERSION="$LATEST_VERSION"
V6_VERSION="$V6_VERSION"
EOF
}

load_version_cache() {
    # 逐行解析而不是 source，避免缓存文件内容被当作代码执行
    if is_cache_valid; then
        local cache_schema
        cache_schema=$(grep '^CACHE_SCHEMA=' "$VERSION_CACHE_FILE" | cut -d'"' -f2)
        [ "$cache_schema" = "$VERSION_CACHE_SCHEMA" ] || return 1
        LATEST_VERSION=$(grep '^LATEST_VERSION=' "$VERSION_CACHE_FILE" | cut -d'"' -f2)
        V6_VERSION=$(grep '^V6_VERSION=' "$VERSION_CACHE_FILE" | cut -d'"' -f2)
        if [ -z "$LATEST_VERSION" ] || [ -z "$V6_VERSION" ]; then
            return 1
        fi
        log_info "从缓存加载版本信息: v5=$LATEST_VERSION, v6=$V6_VERSION"
        return 0
    fi
    return 1
}

get_latest_version() {
    # 尝试从缓存加载
    if load_version_cache; then
        return 0
    fi

    # 只有在第一次调用时才获取版本信息
    if [ -z "$LATEST_VERSION" ] || [ -z "$V6_VERSION" ]; then
        show_progress 1 4 "正在获取版本信息..."

        # 从官方文档的 Markdown 端点获取版本信息（GitBook 页面是动态渲染的，需要使用 .md 端点）
        # 用英文端点获取 v5/v6 下载链接。
        local md_content
        if ! md_content=$(retry_command "curl -fsSL --connect-timeout 10 --max-time 30 'https://kb.nssurge.com/surge-knowledge-base/release-notes/snell.md'"); then
            log_warn "无法获取最新版本信息，使用默认版本"
            LATEST_VERSION="v5.0.1"
            V6_VERSION="v6.0.0rc"
            save_version_cache
            return
        fi

        show_progress 2 4 "解析版本信息..."

        show_progress 3 4 "解析最新版本..."

        # 从下载链接中提取 v5 稳定版 (v5.x.x)
        LATEST_VERSION=$(echo "$md_content" | grep -oE 'snell-server-v5\.[0-9]+\.[0-9]+([[:alpha:]][[:alnum:]]*)?-linux-(amd64|i386|aarch64|armv7l)\.zip' | head -1 | sed -E 's/snell-server-(v[^-]+)-linux-.*/\1/')

        # 从实际下载链接提取版本，兼容 b4、rc、rc2 及正式版等后缀。
        V6_VERSION=$(echo "$md_content" | grep -oE 'snell-server-v6\.[0-9]+\.[0-9]+([[:alpha:]][[:alnum:]]*)?-linux-(amd64|i386|aarch64)\.zip' | head -1 | sed -E 's/snell-server-(v[^-]+)-linux-.*/\1/')

        # 如果无法提取版本，使用默认值
        if [ -z "$LATEST_VERSION" ]; then
            LATEST_VERSION="v5.0.1"
        fi
        if [ -z "$V6_VERSION" ]; then
            V6_VERSION="v6.0.0rc"
        fi

        show_progress 4 4 "版本信息获取完成"
        save_version_cache
    fi
}

# 端口验证函数
validate_port() {
    local port="$1"
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    else
        return 1
    fi
}

# 统一的端口输入函数
get_port_input() {
    local prompt="$1"
    local default_port="$2"
    local port=""
    
    while true; do
        if [ -n "$default_port" ]; then
            read -p "$prompt (默认: $default_port): " port
            port=${port:-$default_port}
        else
            read -p "$prompt: " port
        fi
        
        if validate_port "$port"; then
            echo "$port"
            return 0
        else
            log_error "端口无效，请输入1-65535之间的数字"
        fi
    done
}

# 密码验证函数
validate_password() {
    local password="$1"
    if [[ "$password" =~ ^[A-Za-z0-9._~@%+=:-]{12,128}$ ]]; then
        return 0
    fi
    log_error "PSK 必须为 12-128 位，仅可包含字母、数字及 ._~@%+=:-"
    return 1
}

# 统一的密码输入函数
get_password_input() {
    local prompt="$1"
    local default_password="$2"
    local password=""
    
    while true; do
        if [ -n "$default_password" ]; then
            read -p "$prompt (留空使用默认): " password
            password=${password:-$default_password}
        else
            read -p "$prompt: " password
        fi
        if validate_password "$password"; then
            echo "$password"
            return 0
        fi
    done
}

get_latest_version_with_prompt() {
    if [ -z "$LATEST_VERSION" ] || [ -z "$V6_VERSION" ]; then
        echo "正在获取最新版本信息..."
    fi
    get_latest_version
}

# 配置文件备份函数
backup_config() {
    local config_file="$1"
    local backup_dir="/etc/snell/backup"
    
    if [ -f "$config_file" ]; then
        mkdir -p "$backup_dir"
        local timestamp=$(date +"%Y%m%d_%H%M%S")
        local backup_file="$backup_dir/snell-server.conf.$timestamp"
        
        if cp "$config_file" "$backup_file"; then
            log_info "配置文件已备份到: $backup_file"
            echo "$backup_file"
        else
            log_error "配置文件备份失败"
            return 1
        fi
    fi
}

# 恢复配置文件
restore_config() {
    local backup_file="$1"
    local config_file="$2"
    
    if [ -f "$backup_file" ]; then
        if cp "$backup_file" "$config_file"; then
            log_info "配置文件已恢复"
            return 0
        else
            log_error "配置文件恢复失败"
            return 1
        fi
    else
        log_error "备份文件不存在: $backup_file"
        return 1
    fi
}

restore_install_state() {
    local binary_backup="$1"
    local config_backup="$2"
    local service_backup="$3"
    local config_file="$4"
    local service_file="$5"

    if [ -n "$binary_backup" ] && [ -f "$binary_backup" ]; then
        cp "$binary_backup" /usr/local/bin/snell-server
    else
        rm -f /usr/local/bin/snell-server
    fi
    if [ -n "$config_backup" ] && [ -f "$config_backup" ]; then
        restore_config "$config_backup" "$config_file"
    else
        rm -f "$config_file"
    fi
    if [ -n "$service_backup" ] && [ -f "$service_backup" ]; then
        cp "$service_backup" "$service_file"
    else
        systemctl disable snell 2>/dev/null || true
        rm -f "$service_file"
    fi
    systemctl daemon-reload 2>/dev/null || true
}

choose_version() {
    if [ -z "$LATEST_VERSION" ] || [ -z "$V6_VERSION" ]; then
        echo "正在获取最新版本信息..."
    fi
    get_latest_version  # 确保版本信息已获取

    local current_arch default_choice
    current_arch=$(detect_arch) || return 1
    default_choice=1
    is_version_supported_on_arch "$V6_VERSION" "$current_arch" || default_choice=2

    while true; do
        echo ""
        echo "请选择要安装的版本:"
        if [ "$default_choice" = 1 ]; then
            echo "1. v6 最新版 ($V6_VERSION) - 推荐(默认),部署级协议多样性"
        else
            echo "1. v6 最新版 ($V6_VERSION) - 当前架构 $current_arch 无官方构建"
        fi
        echo "2. v5 稳定版 ($LATEST_VERSION) - 兼容选项$([ "$default_choice" = 2 ] && echo '(默认)')"

        if ! read -p "输入选项 [回车默认 $default_choice]: " version_choice; then
            version_choice="$default_choice"
        fi
        version_choice=${version_choice:-$default_choice}

        case $version_choice in
            1)
                if ! is_version_supported_on_arch "$V6_VERSION" "$current_arch"; then
                    log_error "Snell v6 不支持架构 $current_arch，请选择 v5"
                    continue
                fi
                SNELL_VERSION="$V6_VERSION"
                log_info "选择了 v6 主版本: $SNELL_VERSION"
                ;;
            2)
                SNELL_VERSION="$LATEST_VERSION"
                log_warn "选择了 v5 兼容版本: $SNELL_VERSION"
                ;;
            *)
                log_warn "无效选择，使用默认选项"
                if [ "$default_choice" = 1 ]; then SNELL_VERSION="$V6_VERSION"; else SNELL_VERSION="$LATEST_VERSION"; fi
                ;;
        esac
        break
    done
}

# 统一的版本检测函数
get_snell_version_from_binary() {
    local binary_path="$1"
    local version=""
    
    if [ -f "$binary_path" ]; then
        # 尝试多种方式获取版本
        version=$("$binary_path" --version 2>/dev/null | grep -o 'v[0-9]\+\.[0-9]\+\.[0-9]\+[a-z]*[0-9]*' | head -1)
        if [ -z "$version" ]; then
            version=$("$binary_path" -v 2>/dev/null | grep -o 'v[0-9]\+\.[0-9]\+\.[0-9]\+[a-z]*[0-9]*' | head -1)
        fi
    fi
    
    echo "$version"
}

record_installed_version() {
    local version="$1"
    if [[ ! "$version" =~ ^v(5|6)\.[0-9]+\.[0-9]+[[:alnum:]]*$ ]]; then
        log_error "拒绝记录无效的 Snell 版本: $version"
        return 1
    fi
    mkdir -p "$(dirname "$INSTALLED_VERSION_FILE")" && printf '%s\n' "$version" > "$INSTALLED_VERSION_FILE"
}

get_recorded_snell_version() {
    local version=""
    [ -f "$INSTALLED_VERSION_FILE" ] && read -r version < "$INSTALLED_VERSION_FILE"
    if [[ "$version" =~ ^v(5|6)\.[0-9]+\.[0-9]+[[:alnum:]]*$ ]]; then
        printf '%s\n' "$version"
    else
        return 1
    fi
}

# 获取已安装 Snell 的大版本号，用于输出 Surge 配置行。
get_installed_major_version() {
    local ver
    ver=$(get_snell_version_from_binary "/usr/local/bin/snell-server")
    [ -n "$ver" ] || ver=$(get_recorded_snell_version 2>/dev/null)
    case "$ver" in
        v6*) echo "6" ;;
        v5*) echo "5" ;;
        *) log_error "无法识别已安装的 Snell 版本: ${ver:-无版本信息}"; return 1 ;;
    esac
}

get_current_version() {
    if [ -f "/usr/local/bin/snell-server" ]; then
        CURRENT_VERSION=$(get_snell_version_from_binary "/usr/local/bin/snell-server")
        [ -n "$CURRENT_VERSION" ] || CURRENT_VERSION=$(get_recorded_snell_version 2>/dev/null)
        if [ -z "$CURRENT_VERSION" ]; then
            # 如果无法获取版本，通过文件时间和配置推测
            if [ -f "/etc/snell/snell-server.conf" ]; then
                CURRENT_VERSION="已安装"
            else
                CURRENT_VERSION="unknown"
            fi
        fi
    else
        CURRENT_VERSION="not installed"
    fi
}

install_snell() {
    log_info "开始安装 Snell 服务器"
    
    # 更新系统包并安装依赖
    show_progress 1 10 "安装系统依赖..."
    detect_pkg_manager
    if ! retry_command "$PKG_UPDATE"; then
        log_error "系统包更新失败"
        exit 1
    fi

    if ! retry_command "$PKG_INSTALL unzip wget curl"; then
        log_error "依赖包安装失败"
        exit 1
    fi

    show_progress 2 10 "选择版本..."
    choose_version || exit 1

    ARCH=$(detect_arch) || exit 1
    INSTALL_DIR="/usr/local/bin"
    SYSTEMD_SERVICE_FILE="/lib/systemd/system/snell.service"
    CONF_DIR="/etc/snell"
    CONF_FILE="$CONF_DIR/snell-server.conf"
    detect_service_identity || exit 1

    local binary_backup="" service_backup=""
    if [ -f /usr/local/bin/snell-server ]; then
        binary_backup="$TEMP_DIR/snell-server.previous"
        cp /usr/local/bin/snell-server "$binary_backup" || exit 1
    fi
    if [ -f "$SYSTEMD_SERVICE_FILE" ]; then
        service_backup="$TEMP_DIR/snell.service.previous"
        cp "$SYSTEMD_SERVICE_FILE" "$service_backup" || exit 1
    fi
    
    # 备份现有配置
    local backup_file=""
    if [ -f "$CONF_FILE" ]; then
        backup_file=$(backup_config "$CONF_FILE") || exit 1
    fi

    show_progress 3 10 "获取下载链接..."
    if ! is_version_supported_on_arch "$SNELL_VERSION" "$ARCH"; then
        log_error "Snell $SNELL_VERSION 没有 $ARCH 官方构建"
        exit 1
    fi
    SNELL_URL=$(get_download_url "$SNELL_VERSION" "$ARCH") || exit 1
    
    local temp_zip="$TEMP_DIR/snell-server.zip"
    
    show_progress 4 10 "下载 Snell $SNELL_VERSION for $ARCH..."
    if ! retry_command "wget --progress=dot:giga '$SNELL_URL' -O '$temp_zip'"; then
        log_error "下载 Snell 失败"
        exit 1
    fi
    
    show_progress 5 10 "验证下载文件..."
    if ! verify_file_integrity "$temp_zip" 1000; then
        log_error "下载文件损坏"
        exit 1
    fi

    show_progress 6 10 "解压安装文件..."
    if ! unzip -o "$temp_zip" -d "$INSTALL_DIR"; then
        log_error "解压缩 Snell 失败"
        restore_install_state "$binary_backup" "$backup_file" "$service_backup" "$CONF_FILE" "$SYSTEMD_SERVICE_FILE"
        exit 1
    fi

    if ! chmod +x "$INSTALL_DIR/snell-server"; then
        log_error "设置 Snell 可执行权限失败"
        restore_install_state "$binary_backup" "$backup_file" "$service_backup" "$CONF_FILE" "$SYSTEMD_SERVICE_FILE"
        exit 1
    fi

    show_progress 7 10 "配置端口和密码..."
    # 生成随机端口(检查占用)和PSK
    RANDOM_PORT=$(get_random_free_port)
    RANDOM_PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)  # 增加密码长度
    
    # 配置端口和密码: 直接回车 = 用默认值(已有配置则沿用原值,否则用随机)
    local default_port default_psk listen_value
    default_port="$RANDOM_PORT"
    default_psk="$RANDOM_PSK"
    if [ -f "$CONF_FILE" ]; then
        EXISTING_PORT=$(get_snell_port_from_config "$CONF_FILE")
        EXISTING_PSK=$(awk -F ' = ' '/psk/ {print $2}' "$CONF_FILE" 2>/dev/null)
        [ -n "$EXISTING_PORT" ] && default_port=$EXISTING_PORT
        [ -n "$EXISTING_PSK" ] && default_psk=$EXISTING_PSK
        log_warn "检测到现有配置,回车即沿用原端口/密码"
    fi

    RANDOM_PORT=$(get_port_input "◆ 端口" "$default_port")
    RANDOM_PSK=$(get_password_input "◆ PSK" "$default_psk")
    
    show_progress 8 10 "创建配置文件..."
    if ! mkdir -p "$CONF_DIR"; then
        log_error "创建配置目录失败"
        restore_install_state "$binary_backup" "$backup_file" "$service_backup" "$CONF_FILE" "$SYSTEMD_SERVICE_FILE"
        exit 1
    fi

    if [[ "$SNELL_VERSION" == v6* ]]; then
        listen_value="0.0.0.0:$RANDOM_PORT,[::]:$RANDOM_PORT"
    else
        listen_value="0.0.0.0:$RANDOM_PORT"
    fi

    if ! cat > "$CONF_FILE" << EOF
[snell-server]
listen = $listen_value
psk = $RANDOM_PSK
ipv6 = true
EOF
    then
        log_error "创建 Snell 配置文件失败"
        restore_install_state "$binary_backup" "$backup_file" "$service_backup" "$CONF_FILE" "$SYSTEMD_SERVICE_FILE"
        exit 1
    fi

    show_progress 9 10 "创建系统服务..."
    if ! cat > "$SYSTEMD_SERVICE_FILE" << EOF
[Unit]
Description=Snell Proxy Service
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_GROUP
LimitNOFILE=32768
ExecStart=/usr/local/bin/snell-server -c $CONF_FILE
AmbientCapabilities=CAP_NET_BIND_SERVICE
StandardOutput=journal
StandardError=journal
SyslogIdentifier=snell-server
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    then
        log_error "创建 systemd 服务文件失败"
        restore_install_state "$binary_backup" "$backup_file" "$service_backup" "$CONF_FILE" "$SYSTEMD_SERVICE_FILE"
        exit 1
    fi

    if ! systemctl daemon-reload; then
        log_error "systemd 配置重载失败"
        restore_install_state "$binary_backup" "$backup_file" "$service_backup" "$CONF_FILE" "$SYSTEMD_SERVICE_FILE"
        exit 1
    fi
    
    if ! systemctl enable snell; then
        log_error "启用 Snell 服务失败"
        restore_install_state "$binary_backup" "$backup_file" "$service_backup" "$CONF_FILE" "$SYSTEMD_SERVICE_FILE"
        exit 1
    fi
    
    show_progress 10 10 "启动服务..."
    if ! systemctl restart snell; then
        log_error "启动 Snell 服务失败"
        
        restore_install_state "$binary_backup" "$backup_file" "$service_backup" "$CONF_FILE" "$SYSTEMD_SERVICE_FILE"
        if [ -n "$binary_backup" ]; then
            systemctl restart snell
        fi
        exit 1
    fi

    # 获取公网IP和国家信息
    if ! get_host_ip; then
        log_warn "无法获取公网IP地址"
        HOST_IP="YOUR_SERVER_IP"
    fi

    local ip_country flag
    if ip_country=$(retry_command "curl -s --connect-timeout 5 http://ipinfo.io/$HOST_IP/country"); then
        flag=$(country_to_flag "$ip_country")
    else
        ip_country="XX"
        flag="🏳️"
    fi
    
    # 根据版本输出不同的配置
    local version_num
    case "$SNELL_VERSION" in
        v6*) version_num="6" ;;
        v5*) version_num="5" ;;
        *) log_error "不支持的 Snell 版本: $SNELL_VERSION"; return 1 ;;
    esac
    
    echo ""
    echo -e "${GREEN}✅ Snell $SNELL_VERSION 安装成功！${NC}"
    echo ""
    echo -e "${CYAN}==================== 配置信息 ====================${NC}"
    echo -e "${BLUE}$flag $ip_country = snell, $HOST_IP, $RANDOM_PORT, psk = $RANDOM_PSK, version = $version_num, reuse = true, tfo = true${NC}"
    echo -e "${CYAN}===============================================${NC}"
    
    # 更新当前版本信息
    CURRENT_VERSION="$SNELL_VERSION"
    if ! record_installed_version "$SNELL_VERSION"; then
        log_warn "Snell 已安装，但无法写入版本记录文件"
    fi
    
    # 清理老的备份文件
    find /etc/snell/backup -name "*.conf.*" -mtime +7 -delete 2>/dev/null || true
}

update_snell() {
    log_info "开始更新 Snell 服务器"
    
    get_current_version
    
    if [ "$CURRENT_VERSION" = "not installed" ]; then
        log_error "Snell 未安装，请先安装 Snell"
        return 1
    fi
    
    log_info "当前版本: $CURRENT_VERSION"
    
    show_progress 1 8 "获取版本信息..."
    get_latest_version
    
    echo ""
    echo "可用版本:"
    echo "1. v6 最新版 ($V6_VERSION) - 推荐"
    echo "2. v5 稳定版 ($LATEST_VERSION) - 兼容选项"
    echo "0. 取消更新"

    read -p "选择要更新到的版本 [回车默认 1，0-2]: " update_choice
    update_choice=${update_choice:-1}

    local target_version
    case $update_choice in
        1) target_version="$V6_VERSION" ;;
        2) target_version="$LATEST_VERSION" ;;
        0) log_info "取消更新"; return 0 ;;
        *) log_error "无效选择"; return 1 ;;
    esac

    local arch install_dir temp_zip
    arch=$(detect_arch) || return 1
    install_dir="/usr/local/bin"
    temp_zip="$TEMP_DIR/snell-server-update.zip"

    if ! is_version_supported_on_arch "$target_version" "$arch"; then
        log_error "Snell $target_version 没有 $arch 官方构建"
        return 1
    fi
    
    if [ "$CURRENT_VERSION" = "$target_version" ]; then
        if [ -f /etc/snell/snell-server.conf ]; then
            local same_version_backup
            same_version_backup=$(backup_config /etc/snell/snell-server.conf) || return 1
            if normalize_listen_config /etc/snell/snell-server.conf "$target_version" && systemctl restart snell; then
                log_info "当前已是 $target_version，配置格式已校正"
            else
                restore_config "$same_version_backup" /etc/snell/snell-server.conf
                systemctl restart snell 2>/dev/null || true
                log_error "配置校正或服务重启失败，已恢复更新前配置"
                return 1
            fi
        else
            log_warn "当前版本已是目标版本 $target_version"
        fi
        return 0
    fi
    
    log_warn "准备从 $CURRENT_VERSION 更新到 $target_version"
    read -p "确认更新? [Y/n]: " confirm
    confirm=${confirm:-Y}
    
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        log_info "取消更新"
        return 0
    fi
    
    show_progress 2 8 "获取并验证下载链接..."
    local snell_url
    snell_url=$(get_download_url "$target_version" "$arch") || return 1
    if ! curl -fsIL --connect-timeout 10 --max-time 30 "$snell_url" >/dev/null; then
        log_error "官方安装包不存在或暂时无法访问: $snell_url"
        log_warn "服务尚未停止，请稍后重试或检查官方发布说明"
        return 1
    fi

    show_progress 3 8 "下载 Snell $target_version for $arch..."
    if ! retry_command "wget --progress=dot:giga '$snell_url' -O '$temp_zip'"; then
        log_error "下载 Snell 失败，服务未受影响"
        return 1
    fi

    show_progress 4 8 "验证下载文件..."
    if ! verify_file_integrity "$temp_zip" 1000; then
        log_error "下载文件损坏，服务未受影响"
        return 1
    fi

    show_progress 5 8 "停止服务..."
    if ! systemctl stop snell; then
        log_error "停止 Snell 服务失败"
        return 1
    fi
    
    show_progress 6 8 "备份当前版本..."
    if ! cp "/usr/local/bin/snell-server" "/usr/local/bin/snell-server.backup"; then
        log_error "备份当前版本失败"
        systemctl start snell
        return 1
    fi

    local update_config_backup=""
    if [ -f /etc/snell/snell-server.conf ]; then
        update_config_backup=$(backup_config /etc/snell/snell-server.conf) || {
            systemctl start snell
            return 1
        }
    fi
    
    show_progress 7 8 "安装新版本..."
    if ! unzip -o "$temp_zip" -d "$install_dir"; then
        log_error "解压缩 Snell 失败，恢复原版本"
        cp "/usr/local/bin/snell-server.backup" "/usr/local/bin/snell-server"
        systemctl start snell
        return 1
    fi

    if ! chmod +x "$install_dir/snell-server"; then
        log_error "设置 Snell 可执行权限失败，恢复原版本"
        cp "/usr/local/bin/snell-server.backup" "/usr/local/bin/snell-server"
        systemctl start snell
        return 1
    fi

    if [ -f /etc/snell/snell-server.conf ]; then
        if ! normalize_listen_config /etc/snell/snell-server.conf "$target_version"; then
            log_error "无法转换 listen 配置，恢复原版本"
            cp "/usr/local/bin/snell-server.backup" "/usr/local/bin/snell-server"
            restore_config "$update_config_backup" /etc/snell/snell-server.conf
            systemctl start snell
            return 1
        fi
    fi

    show_progress 8 8 "重新启动服务..."
    if ! systemctl start snell; then
        log_error "启动 Snell 服务失败，恢复原版本"
        cp "/usr/local/bin/snell-server.backup" "/usr/local/bin/snell-server"
        [ -n "$update_config_backup" ] && restore_config "$update_config_backup" /etc/snell/snell-server.conf
        systemctl start snell
        return 1
    fi

    # 清理备份文件
    rm -f "/usr/local/bin/snell-server.backup"

    CURRENT_VERSION="$target_version"
    if ! record_installed_version "$target_version"; then
        log_warn "Snell 已更新，但无法写入版本记录文件"
    fi
    
    log_info "Snell 已成功更新到版本 $target_version"
    
    # 显示配置信息
    generate_config
}

uninstall_snell() {
    log_info "开始卸载 Snell 服务器"
    
    if is_snell_installed; then
        echo "确认要卸载 Snell 服务器吗？这将删除所有相关文件。"
        read -p "输入 'yes' 确认卸载: " confirm
        
        if [ "$confirm" != "yes" ]; then
            log_info "取消卸载操作"
            return 0
        fi
        
        show_progress 1 6 "停止服务..."
        systemctl stop snell 2>/dev/null || true
        
        show_progress 2 6 "禁用服务..."
        systemctl disable snell 2>/dev/null || true
        
        show_progress 3 6 "删除服务文件..."
        rm -f /lib/systemd/system/snell.service
        
        show_progress 4 6 "删除程序文件..."
        rm -f /usr/local/bin/snell-server
        rm -f /usr/local/bin/snell-server.backup
        
        show_progress 5 6 "删除配置目录..."
        rm -rf /etc/snell
        
        show_progress 6 6 "重载系统配置..."
        systemctl daemon-reload
        
        log_info "Snell 服务器卸载成功"
    else
        log_error "Snell 服务未安装"
    fi
}

show_install_status() {
    echo -e "${CYAN}========== 当前安装状态 ==========${NC}"
    
    # 检查Snell状态
    if is_snell_installed; then
        if systemctl is-active --quiet snell; then
            echo -e "${GREEN}✓ Snell 服务: 已安装并运行中${NC}"
            if [ -f "/etc/snell/snell-server.conf" ]; then
                local snell_port psk
                snell_port=$(get_snell_port_from_config /etc/snell/snell-server.conf)
                psk=$(awk -F ' = ' '/psk/ {print $2}' /etc/snell/snell-server.conf 2>/dev/null)
                echo -e "${BLUE}  端口: $snell_port${NC}"
                echo -e "${BLUE}  密码: $psk${NC}"
            fi
        else
            echo -e "${YELLOW}⚠ Snell 服务: 已安装但未运行${NC}"
        fi
    else
        echo -e "${RED}✗ Snell 服务: 未安装${NC}"
    fi

    echo -e "${CYAN}================================${NC}"
    echo ""
}

generate_config() {
    echo ""
    echo -e "${CYAN}==================== 当前配置信息 ====================${NC}"
    
    # 获取服务器信息
    if ! get_host_ip; then
        log_warn "无法获取公网IP地址"
        HOST_IP="YOUR_SERVER_IP"
    fi
    
    local ip_country flag
    if ip_country=$(retry_command "curl -s --connect-timeout 5 http://ipinfo.io/$HOST_IP/country"); then
        flag=$(country_to_flag "$ip_country")
    else
        ip_country="XX"
        flag="🌍"
    fi
    
    # 检查 Snell 服务
    if is_snell_installed; then
        local conf_file="/etc/snell/snell-server.conf"
        if [ -f "$conf_file" ]; then
            local snell_port psk version_num
            snell_port=$(get_snell_port_from_config "$conf_file")
            psk=$(awk -F ' = ' '/psk/ {print $2}' "$conf_file" 2>/dev/null)
            if ! version_num=$(get_installed_major_version); then
                return 1
            fi

            echo -e "${BLUE}$flag $ip_country = snell, $HOST_IP, $snell_port, psk = $psk, version = $version_num, reuse = true, tfo = true${NC}"
        else
            log_error "Snell 配置文件不存在"
        fi
    else
        log_error "Snell 服务未安装"
    fi

    echo -e "${CYAN}===============================================${NC}"
    echo ""
}

show_logs() {
    local lines follow

    echo -e "${CYAN}==================== Snell 日志 ====================${NC}"
    if command -v journalctl >/dev/null 2>&1 && is_snell_installed; then
        read -p "显示最近多少条日志 [默认 100]: " lines
        lines=${lines:-100}
        if ! [[ "$lines" =~ ^[0-9]+$ ]] || [ "$lines" -lt 1 ]; then
            log_warn "条数无效，使用默认值 100"
            lines=100
        fi

        journalctl -u snell.service -n "$lines" --no-pager -o short-iso
        echo ""
        read -p "是否实时跟踪日志? [y/N]: " follow
        if [[ "$follow" =~ ^[Yy]$ ]]; then
            echo -e "${GRAY}正在实时跟踪，按 Ctrl-C 返回菜单。${NC}"
            journalctl -u snell.service -f -o short-iso
        fi
    elif [ -f "$LOG_FILE" ]; then
        log_warn "未找到 Snell systemd 日志，显示安装日志: $LOG_FILE"
        tail -n 100 "$LOG_FILE"
    else
        log_error "未找到 Snell 日志"
        return 1
    fi
    echo -e "${CYAN}===================================================${NC}"
}

# 主程序
main() {
    # 版本信息只在启动时联网获取一次
    echo -e "${GRAY}正在获取版本信息...${NC}"
    get_current_version
    get_latest_version

    # 循环显示菜单(不用递归，避免调用栈无限加深)
    local choice
    while true; do
        clear 2>/dev/null || true
        echo ""
        echo -e "${PURPLE}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "     ${CYAN}🍥 Snell 管理脚本 🍥${NC}   ${YELLOW}(｡･ω･｡)ﾉ${NC}"
        echo -e "     ${GRAY}v5:${GREEN}$LATEST_VERSION${GRAY} v6:${GREEN}$V6_VERSION${NC}"
        echo -e "${PURPLE}  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        show_install_status
        echo ""
        echo -e "  ${GREEN}1.${NC} 🍥 安装 Snell"
        echo -e "  ${GREEN}2.${NC} 🗑️  卸载 Snell"
        echo -e "  ${GREEN}3.${NC} ⬆️  更新 Snell"
        echo -e "  ${GREEN}4.${NC} 📋 查看配置"
        echo -e "  ${GREEN}5.${NC} 📜 查看日志"
        echo -e "  ${YELLOW}0.${NC} 👋 退出"
        echo ""
        echo -e "  ${GRAY}(需要 Shadow-TLS 加壳请单独运行 shadow-tls.sh)${NC}"
        echo ""

        read -p "$(echo -e "  ${CYAN}请输入选项 [0-5]: ${NC}")" choice

        case $choice in
            1) install_snell ;;
            2) uninstall_snell ;;
            3) update_snell ;;
            4) generate_config ;;
            5) show_logs ;;
            0) echo -e "  ${PURPLE}バイバイ~ (｡･ω･)ﾉﾞ${NC}"; exit 0 ;;
            *) echo -e "  ${YELLOW}(・_・?) 没有「$choice」这个选项~${NC}"; sleep 1; continue ;;
        esac

        echo ""
        echo -e "  ${GREEN}✓ 操作完成！${NC}"
        read -p "$(echo -e "  ${GRAY}按回车返回菜单...${NC}")" _
    done
}

# 启动主程序
main
