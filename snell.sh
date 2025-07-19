#!/bin/bash

# 优化后的 Snell 管理脚本
# 版本: 2.0
# 功能: 安装、更新、卸载 Snell 和 Shadow-TLS

# set -euo pipefail  # 严格模式 - 暂时禁用以便调试
set -e  # 只在命令失败时退出，但允许未定义变量

# 全局变量
OLD_VERSION=""
LATEST_VERSION=""
VERSION_CACHE_FILE="/tmp/snell_version_cache"
VERSION_CACHE_TIMEOUT=3600  # 1小时缓存
TEMP_DIR="/tmp/snell_install_$$"
LOG_FILE="/var/log/snell_install.log"
MAX_RETRIES=3
RETRY_DELAY=2

# 创建临时目录
mkdir -p "$TEMP_DIR"
trap 'cleanup_temp_files' EXIT

# 颜色定义
RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
BLUE='\e[34m'
CYAN='\e[36m'
NC='\e[0m'  # No Color

# 清理临时文件
cleanup_temp_files() {
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}

# 日志记录函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# 错误日志记录
log_error() {
    echo -e "${RED}[ERROR] $1${NC}" | tee -a "$LOG_FILE"
}

# 警告日志记录
log_warn() {
    echo -e "${YELLOW}[WARN] $1${NC}" | tee -a "$LOG_FILE"
}

# 信息日志记录
log_info() {
    echo -e "${GREEN}[INFO] $1${NC}" | tee -a "$LOG_FILE"
}

# 进度显示函数
show_progress() {
    local current=$1
    local total=$2
    local task=$3
    local percent=$((current * 100 / total))
    local bar_length=30
    local filled_length=$((percent * bar_length / 100))
    
    # 清除当前行
    printf "\r\033[K"
    
    # 显示进度条
    printf "${CYAN}[%3d%%]${NC} [" "$percent"
    for ((i=0; i<filled_length; i++)); do printf "="; done
    for ((i=filled_length; i<bar_length; i++)); do printf " "; done
    printf "] %s\n" "$task"
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
    
    return 0
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
        *)
            # 默认使用 amd64
            url="https://dl.nssurge.com/snell/snell-server-${version}-linux-amd64.zip"
            log_warn "未识别的架构 $arch，使用默认的 amd64 版本"
            ;;
    esac
    
    echo "$url"
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
    cat > "$VERSION_CACHE_FILE" << EOF
OLD_VERSION="$OLD_VERSION"
LATEST_VERSION="$LATEST_VERSION"
EOF
}

load_version_cache() {
    if is_cache_valid; then
        source "$VERSION_CACHE_FILE"
        log_info "从缓存加载版本信息: v4=$OLD_VERSION, v5=$LATEST_VERSION"
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
    if [ -z "$OLD_VERSION" ] || [ -z "$LATEST_VERSION" ]; then
        show_progress 1 4 "正在获取版本信息..."
        
        # 从官方文档获取版本信息
        local html_content
        if ! html_content=$(retry_command "curl -s --connect-timeout 10 --max-time 30 'https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell'"); then
            log_warn "无法获取最新版本信息，使用默认版本"
            OLD_VERSION="v4.1.1"
            LATEST_VERSION="v5.0.0"
            save_version_cache
            return
        fi
        
        show_progress 2 4 "解析版本信息..."
        
        # 提取老版本 (v4.x.x)
        OLD_VERSION=$(echo "$html_content" | grep -o 'snell-server-v4\.[0-9]\+\.[0-9]\+' | head -1 | sed 's/snell-server-//')
        
        show_progress 3 4 "解析最新版本..."
        
        # 提取最新版本 (v5.x.x)
        LATEST_VERSION=$(echo "$html_content" | grep -o 'snell-server-v5\.[0-9]\+\.[0-9]\+[a-z]*[0-9]*' | head -1 | sed 's/snell-server-//')
        
        # 如果无法提取版本，使用默认值
        if [ -z "$OLD_VERSION" ]; then
            OLD_VERSION="v4.1.1"
        fi
        
        if [ -z "$LATEST_VERSION" ]; then
            LATEST_VERSION="v5.0.0"
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
    if [ ${#password} -ge 8 ]; then
        return 0
    else
        log_warn "密码长度小于8位，建议使用更长的密码"
        return 0  # 仍然允许，但给出警告
    fi
}

# 统一的密码输入函数
get_password_input() {
    local prompt="$1"
    local default_password="$2"
    local password=""
    
    if [ -n "$default_password" ]; then
        read -p "$prompt (留空使用默认): " password
        password=${password:-$default_password}
    else
        read -p "$prompt: " password
    fi
    
    validate_password "$password"
    echo "$password"
}

get_snell_port() {
    SNELL_PORT=$(awk -F '[: ]+' '/listen/ {print $4}' /etc/snell/snell-server.conf 2>/dev/null)
    if [ -z "$SNELL_PORT" ]; then
        SNELL_PORT=$(get_port_input "请输入 Snell 代理协议端口")
    else
        log_info "获取到的 Snell 端口: $SNELL_PORT"
        read -p "确认端口 (默认为确认) [Y/n]: " confirm
        confirm=${confirm:-Y}
        if [[ ! $confirm =~ ^[Yy]$ ]]; then
            SNELL_PORT=$(get_port_input "请输入 Snell 代理协议端口")
        fi
    fi
}

get_latest_version_with_prompt() {
    if [ -z "$OLD_VERSION" ] || [ -z "$LATEST_VERSION" ]; then
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

choose_version() {
    if [ -z "$OLD_VERSION" ] || [ -z "$LATEST_VERSION" ]; then
        echo "正在获取最新版本信息..."
    fi
    get_latest_version  # 确保版本信息已获取
    
    echo ""
    echo "请选择要安装的版本:"
    echo "1. 最新版 ($LATEST_VERSION) - 推荐，包含最新特性"
    echo "2. 老版本 ($OLD_VERSION) - 兼容性考虑"
    
    read -p "输入选项 [1-2]: " version_choice
    
    case $version_choice in
        1)
            SNELL_VERSION="$LATEST_VERSION"
            log_info "选择了最新版: $SNELL_VERSION"
            ;;
        2)
            SNELL_VERSION="$OLD_VERSION"
            log_warn "选择了老版本: $SNELL_VERSION"
            ;;
        *)
            log_warn "无效选择，使用最新版: $LATEST_VERSION"
            SNELL_VERSION="$LATEST_VERSION"
            ;;
    esac
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

get_current_version() {
    if [ -f "/usr/local/bin/snell-server" ]; then
        CURRENT_VERSION=$(get_snell_version_from_binary "/usr/local/bin/snell-server")
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
    if ! retry_command "apt-get update -qq"; then
        log_error "系统包更新失败"
        exit 1
    fi
    
    if ! retry_command "apt-get install -y unzip wget curl"; then
        log_error "依赖包安装失败"
        exit 1
    fi

    show_progress 2 10 "选择版本..."
    choose_version

    ARCH=$(arch)
    INSTALL_DIR="/usr/local/bin"
    SYSTEMD_SERVICE_FILE="/lib/systemd/system/snell.service"
    CONF_DIR="/etc/snell"
    CONF_FILE="$CONF_DIR/snell-server.conf"
    
    # 备份现有配置
    local backup_file=""
    if [ -f "$CONF_FILE" ]; then
        backup_file=$(backup_config "$CONF_FILE")
    fi

    show_progress 3 10 "获取下载链接..."
    SNELL_URL=$(get_download_url "$SNELL_VERSION" "$ARCH")
    
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
        exit 1
    fi

    chmod +x "$INSTALL_DIR/snell-server"

    show_progress 7 10 "配置端口和密码..."
    # 生成随机端口和PSK
    RANDOM_PORT=$(shuf -i 30000-65000 -n 1)
    RANDOM_PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)  # 增加密码长度
    
    # 配置端口和密码
    if [ -f "$CONF_FILE" ]; then
        log_warn "检测到现有配置文件"
        EXISTING_PORT=$(awk -F '[: ]+' '/listen/ {print $4}' "$CONF_FILE" 2>/dev/null)
        EXISTING_PSK=$(awk -F ' = ' '/psk/ {print $2}' "$CONF_FILE" 2>/dev/null)
        
        echo -e "${GREEN}随机生成的端口: $RANDOM_PORT${NC}"
        echo -e "${BLUE}已存在的端口: $EXISTING_PORT${NC}"
        read -p "是否使用已存在的端口？(Y/n): " use_existing_port
        use_existing_port=${use_existing_port:-Y}
        
        if [[ $use_existing_port =~ ^[Yy]$ ]]; then
            RANDOM_PORT=$EXISTING_PORT
            log_info "使用已存在的端口: $RANDOM_PORT"
        else
            read -p "是否使用随机生成的端口？(Y/n): " use_random_port
            use_random_port=${use_random_port:-Y}
            
            if [[ ! $use_random_port =~ ^[Yy]$ ]]; then
                RANDOM_PORT=$(get_port_input "请输入自定义端口")
            fi
            log_info "使用端口: $RANDOM_PORT"
        fi
        
        # 密码设置
        echo -e "${GREEN}随机生成的密码: $RANDOM_PSK${NC}"
        echo -e "${BLUE}已存在的密码: $EXISTING_PSK${NC}"
        read -p "是否使用已存在的密码？(Y/n): " use_existing_psk
        use_existing_psk=${use_existing_psk:-Y}
        
        if [[ $use_existing_psk =~ ^[Yy]$ ]]; then
            RANDOM_PSK=$EXISTING_PSK
            log_info "使用已存在的密码"
        else
            RANDOM_PSK=$(get_password_input "请输入自定义密码" "$RANDOM_PSK")
            log_info "使用自定义密码"
        fi
    else
        # 新安装情况下的端口设置
        echo -e "${GREEN}随机生成的端口: $RANDOM_PORT${NC}"
        read -p "是否使用此端口？(Y/n): " use_random_port
        use_random_port=${use_random_port:-Y}
        
        if [[ ! $use_random_port =~ ^[Yy]$ ]]; then
            RANDOM_PORT=$(get_port_input "请输入自定义端口")
        fi
        log_info "使用端口: $RANDOM_PORT"
        
        # 密码设置
        echo -e "${GREEN}随机生成的密码: $RANDOM_PSK${NC}"
        read -p "是否使用此密码？(Y/n): " use_random_password
        use_random_password=${use_random_password:-Y}
        
        if [[ ! $use_random_password =~ ^[Yy]$ ]]; then
            RANDOM_PSK=$(get_password_input "请输入自定义密码" "$RANDOM_PSK")
        fi
        log_info "使用密码配置完成"
    fi
    
    show_progress 8 10 "创建配置文件..."
    mkdir -p "$CONF_DIR"

    cat > "$CONF_FILE" << EOF
[snell-server]
listen = ::0:$RANDOM_PORT
psk = $RANDOM_PSK
ipv6 = true
EOF

    show_progress 9 10 "创建系统服务..."
    cat > "$SYSTEMD_SERVICE_FILE" << EOF
[Unit]
Description=Snell Proxy Service
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
LimitNOFILE=32768
ExecStart=/usr/local/bin/snell-server -c $CONF_FILE
AmbientCapabilities=CAP_NET_BIND_SERVICE
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=snell-server
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    if ! systemctl daemon-reload; then
        log_error "systemd 配置重载失败"
        if [ -n "$backup_file" ]; then
            restore_config "$backup_file" "$CONF_FILE"
        fi
        exit 1
    fi
    
    if ! systemctl enable snell; then
        log_error "启用 Snell 服务失败"
        exit 1
    fi
    
    show_progress 10 10 "启动服务..."
    if ! systemctl restart snell; then
        log_error "启动 Snell 服务失败"
        
        # 尝试恢复配置
        if [ -n "$backup_file" ]; then
            log_info "尝试恢复原有配置"
            restore_config "$backup_file" "$CONF_FILE"
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
    if [[ $SNELL_VERSION == v5* ]]; then
        version_num="5"
    else
        version_num="4"
    fi
    
    echo ""
    echo -e "${GREEN}✅ Snell $SNELL_VERSION 安装成功！${NC}"
    echo ""
    echo -e "${CYAN}==================== 配置信息 ====================${NC}"
    echo -e "${BLUE}$flag $ip_country = snell, $HOST_IP, $RANDOM_PORT, psk = $RANDOM_PSK, version = $version_num, reuse = true, tfo = true${NC}"
    echo -e "${CYAN}===============================================${NC}"
    
    # 更新当前版本信息
    CURRENT_VERSION="$SNELL_VERSION"
    
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
    echo "1. 最新版 ($LATEST_VERSION)"
    echo "2. 老版本 ($OLD_VERSION)"
    echo "3. 取消更新"
    
    read -p "选择要更新到的版本 [1-3]: " update_choice
    
    local target_version
    case $update_choice in
        1) target_version="$LATEST_VERSION" ;;
        2) target_version="$OLD_VERSION" ;;
        3) log_info "取消更新"; return 0 ;;
        *) log_error "无效选择"; return 1 ;;
    esac
    
    if [ "$CURRENT_VERSION" = "$target_version" ]; then
        log_warn "当前版本已是目标版本 $target_version"
        return 0
    fi
    
    log_warn "准备从 $CURRENT_VERSION 更新到 $target_version"
    read -p "确认更新? [Y/n]: " confirm
    confirm=${confirm:-Y}
    
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        log_info "取消更新"
        return 0
    fi
    
    show_progress 2 8 "停止服务..."
    if ! systemctl stop snell; then
        log_error "停止 Snell 服务失败"
        return 1
    fi
    
    show_progress 3 8 "备份当前版本..."
    if ! cp "/usr/local/bin/snell-server" "/usr/local/bin/snell-server.backup"; then
        log_error "备份当前版本失败"
        systemctl start snell
        return 1
    fi
    
    local arch install_dir temp_zip
    arch=$(arch)
    install_dir="/usr/local/bin"
    temp_zip="$TEMP_DIR/snell-server-update.zip"
    
    show_progress 4 8 "获取下载链接..."
    local snell_url
    snell_url=$(get_download_url "$target_version" "$arch")

    show_progress 5 8 "下载 Snell $target_version for $arch..."
    if ! retry_command "wget --progress=dot:giga '$snell_url' -O '$temp_zip'"; then
        log_error "下载 Snell 失败，恢复原版本"
        systemctl start snell
        return 1
    fi
    
    show_progress 6 8 "验证下载文件..."
    if ! verify_file_integrity "$temp_zip" 1000; then
        log_error "下载文件损坏"
        systemctl start snell
        return 1
    fi

    show_progress 7 8 "安装新版本..."
    if ! unzip -o "$temp_zip" -d "$install_dir"; then
        log_error "解压缩 Snell 失败，恢复原版本"
        cp "/usr/local/bin/snell-server.backup" "/usr/local/bin/snell-server"
        systemctl start snell
        return 1
    fi

    chmod +x "$install_dir/snell-server"

    show_progress 8 8 "重新启动服务..."
    if ! systemctl start snell; then
        log_error "启动 Snell 服务失败，恢复原版本"
        cp "/usr/local/bin/snell-server.backup" "/usr/local/bin/snell-server"
        systemctl start snell
        return 1
    fi

    # 清理备份文件
    rm -f "/usr/local/bin/snell-server.backup"
    
    log_info "Snell 已成功更新到版本 $target_version"
    
    # 显示配置信息
    generate_config
}

uninstall_snell() {
    log_info "开始卸载 Snell 服务器"
    
    if systemctl list-units --type=service | grep -q "snell.service"; then
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


install_shadow_tls() {
    log_info "开始安装 Shadow-TLS v3"
    
    # 检查 Snell 是否已安装
    if [ ! -f "/etc/snell/snell-server.conf" ]; then
        log_error "Snell 服务器未安装，请先安装 Snell"
        return 1
    fi
    
    show_progress 1 8 "下载 Shadow-TLS..."
    local shadow_tls_binary="/usr/bin/shadow-tls-x86_64-unknown-linux-musl"
    local temp_binary="$TEMP_DIR/shadow-tls-x86_64-unknown-linux-musl"
    
    if ! retry_command "wget --progress=dot:giga 'https://github.com/ihciah/shadow-tls/releases/download/v0.2.25/shadow-tls-x86_64-unknown-linux-musl' -O '$temp_binary'"; then
        log_error "下载 Shadow-TLS 失败"
        return 1
    fi
    
    show_progress 2 8 "验证下载文件..."
    if ! verify_file_integrity "$temp_binary" 1000000; then  # 1MB 最小大小
        log_error "Shadow-TLS 二进制文件损坏"
        return 1
    fi
    
    # 移动到目标位置并设置权限
    mv "$temp_binary" "$shadow_tls_binary"
    chmod +x "$shadow_tls_binary"

    show_progress 3 8 "获取 Snell 配置..."
    get_snell_port

    show_progress 4 8 "配置 Shadow-TLS 参数..."
    local random_password shadow_tls_port psk
    random_password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)  # 增加密码长度
    psk=$(awk -F ' = ' '/psk/ {print $2}' /etc/snell/snell-server.conf 2>/dev/null)
    
    if [ -z "$psk" ]; then
        log_error "无法从 Snell 配置文件获取 PSK"
        return 1
    fi

    # 生成随机端口
    shadow_tls_port=$(shuf -i 30000-65000 -n 1)
    echo -e "${GREEN}随机生成的 Shadow-TLS 端口: $shadow_tls_port${NC}"
    read -p "是否使用此端口？(Y/n): " use_random_port
    use_random_port=${use_random_port:-Y}
    
    if [[ ! $use_random_port =~ ^[Yy]$ ]]; then
        shadow_tls_port=$(get_port_input "请输入自定义 Shadow-TLS 端口")
    fi
    
    # Shadow-TLS 密码设置
    echo -e "${GREEN}随机生成的 Shadow-TLS 密码: $random_password${NC}"
    random_password=$(get_password_input "请输入自定义 Shadow-TLS 密码" "$random_password")

    show_progress 5 8 "选择 TLS SNI..."
    echo "请选择一个 --tls 参数 (默认选择1): "
    local options=("gateway.icloud.com" "mp.weixin.qq.com" "coding.net" "upyun.com" "sns-video-hw.xhscdn.com" "sns-img-qc.xhscdn.com" "sns-video-qn.xhscdn.com" "p9-dy.byteimg.com" "p6-dy.byteimg.com" "feishu.cn" "douyin.com" "toutiao.com" "v6-dy-y.ixigua.com" "hls3-akm.douyucdn.cn" "publicassets.cdn-apple.com" "weather-data.apple.com")
    
    # 显示选项
    for i in "${!options[@]}"; do
        echo "$((i+1)). ${options[$i]}"
    done
    
    local tls_choice tls_option
    read -p "输入选项 (1-${#options[@]}) [默认: 1]: " tls_choice
    tls_choice=${tls_choice:-1}
    
    # 验证选择
    if [[ "$tls_choice" -ge 1 && "$tls_choice" -le "${#options[@]}" ]]; then
        tls_option="${options[$((tls_choice-1))]}"
        log_info "选择了: $tls_option"
    else
        log_warn "无效选择，使用默认选项: ${options[0]}"
        tls_option="${options[0]}"
    fi

    show_progress 6 8 "创建系统服务..."
    cat > /etc/systemd/system/shadow-tls.service << EOF
[Unit]
Description=Shadow-TLS Server Service
Documentation=man:sstls-server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=MONOIO_FORCE_LEGACY_DRIVER=1
ExecStart=/usr/bin/shadow-tls-x86_64-unknown-linux-musl --v3 server --server 0.0.0.0:$SNELL_PORT --password $random_password --listen ::0:$shadow_tls_port --tls $tls_option
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=shadow-tls
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    if ! systemctl daemon-reload; then
        log_error "systemd 配置重载失败"
        return 1
    fi
    
    if ! systemctl enable shadow-tls.service; then
        log_error "启用 Shadow-TLS 服务失败"
        return 1
    fi
    
    show_progress 7 8 "启动服务..."
    if ! systemctl start shadow-tls.service; then
        log_error "启动 Shadow-TLS 服务失败"
        return 1
    fi

    # 配置 iptables 规则
    log_info "配置防火墙规则..."
    if command -v iptables >/dev/null 2>&1; then
        iptables -t nat -A PREROUTING -p udp --dport "$shadow_tls_port" -j REDIRECT --to-port "$SNELL_PORT" 2>/dev/null || true
        iptables -t nat -A OUTPUT -p udp --dport "$shadow_tls_port" -j REDIRECT --to-port "$SNELL_PORT" 2>/dev/null || true
        
        # 保存 iptables 规则
        if command -v iptables-save >/dev/null 2>&1; then
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi
    fi

    show_progress 8 8 "获取服务器信息..."
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

    # 检查Snell版本来决定配置格式
    local snell_ver version_num
    if [ -f "/usr/local/bin/snell-server" ]; then
        snell_ver=$(get_snell_version_from_binary "/usr/local/bin/snell-server")
        if [[ $snell_ver == v5* ]]; then
            version_num="5"
        elif [[ $snell_ver == v4* ]]; then
            version_num="4"
        else
            version_num="5"
        fi
    else
        version_num="5"
    fi
    
    echo ""
    echo -e "${GREEN}✅ Shadow-TLS v3 安装成功！${NC}"
    echo ""
    echo -e "${CYAN}==================== 配置信息 ====================${NC}"
    echo -e "${BLUE}$flag $ip_country = snell, $HOST_IP, $shadow_tls_port, psk=$psk, version=$version_num, reuse=true, shadow-tls-password=$random_password, shadow-tls-sni=${tls_option}, shadow-tls-version=3${NC}"
    echo -e "${CYAN}===============================================${NC}"
}

uninstall_shadow_tls() {
    log_info "开始卸载 Shadow-TLS v3"
    
    if systemctl list-units --type=service | grep -q "shadow-tls.service"; then
        echo "确认要卸载 Shadow-TLS v3 服务吗？"
        read -p "输入 'yes' 确认卸载: " confirm
        
        if [ "$confirm" != "yes" ]; then
            log_info "取消卸载操作"
            return 0
        fi
        
        show_progress 1 5 "停止服务..."
        systemctl stop shadow-tls 2>/dev/null || true
        
        show_progress 2 5 "禁用服务..."
        systemctl disable shadow-tls 2>/dev/null || true
        
        show_progress 3 5 "删除服务文件..."
        rm -f /etc/systemd/system/shadow-tls.service
        
        show_progress 4 5 "删除程序文件..."
        rm -f /usr/bin/shadow-tls-x86_64-unknown-linux-musl
        
        show_progress 5 5 "重载系统配置..."
        systemctl daemon-reload
        
        log_info "Shadow-TLS v3 服务卸载成功"
    else
        log_error "Shadow-TLS 服务未安装"
    fi
}


show_install_status() {
    echo -e "${CYAN}========== 当前安装状态 ==========${NC}"
    
    # 检查Snell状态
    if systemctl list-units --type=service | grep -q "snell.service"; then
        if systemctl is-active --quiet snell; then
            echo -e "${GREEN}✓ Snell 服务: 已安装并运行中${NC}"
            if [ -f "/etc/snell/snell-server.conf" ]; then
                local snell_port psk
                snell_port=$(awk -F '[: ]+' '/listen/ {print $4}' /etc/snell/snell-server.conf 2>/dev/null)
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
    
    # 检查Shadow-TLS状态
    if systemctl list-units --type=service | grep -q "shadow-tls.service"; then
        if systemctl is-active --quiet shadow-tls; then
            echo -e "${GREEN}✓ Shadow-TLS 服务: 已安装并运行中${NC}"
            if [ -f "/etc/systemd/system/shadow-tls.service" ]; then
                local shadow_tls_port shadow_tls_password shadow_tls_sni
                shadow_tls_port=$(grep 'ExecStart=' /etc/systemd/system/shadow-tls.service | sed -n 's/.*--listen ::0:\([0-9]*\).*/\1/p')
                shadow_tls_password=$(grep 'ExecStart=' /etc/systemd/system/shadow-tls.service | sed -n 's/.*--password \([^ ]*\).*/\1/p')
                shadow_tls_sni=$(grep 'ExecStart=' /etc/systemd/system/shadow-tls.service | sed -n 's/.*--tls \([^ ]*\).*/\1/p')
                echo -e "${BLUE}  端口: $shadow_tls_port${NC}"
                echo -e "${BLUE}  密码: $shadow_tls_password${NC}"
                echo -e "${BLUE}  SNI: $shadow_tls_sni${NC}"
            fi
        else
            echo -e "${YELLOW}⚠ Shadow-TLS 服务: 已安装但未运行${NC}"
        fi
    else
        echo -e "${RED}✗ Shadow-TLS 服务: 未安装${NC}"
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
    if systemctl list-units --type=service | grep -q "snell.service"; then
        local conf_file="/etc/snell/snell-server.conf"
        if [ -f "$conf_file" ]; then
            local snell_port psk version_num
            snell_port=$(awk -F '[: ]+' '/listen/ {print $4}' "$conf_file" 2>/dev/null)
            psk=$(awk -F ' = ' '/psk/ {print $2}' "$conf_file" 2>/dev/null)
            
            # 检查版本来决定配置格式
            local snell_ver
            snell_ver=$(get_snell_version_from_binary "/usr/local/bin/snell-server")
            if [[ $snell_ver == v5* ]]; then
                version_num="5"
            elif [[ $snell_ver == v4* ]]; then
                version_num="4"
            else
                version_num="5"
            fi
            
            echo -e "${BLUE}$flag $ip_country = snell, $HOST_IP, $snell_port, psk = $psk, version = $version_num, reuse = true, tfo = true${NC}"
        else
            log_error "Snell 配置文件不存在"
        fi
    else
        log_error "Snell 服务未安装"
    fi

    # 检查 Shadow-TLS 服务
    if systemctl list-units --type=service | grep -q "shadow-tls.service"; then
        local shadow_tls_conf="/etc/systemd/system/shadow-tls.service"
        if [ -f "$shadow_tls_conf" ]; then
            local shadow_tls_port shadow_tls_password shadow_tls_sni psk version_num
            shadow_tls_port=$(grep 'ExecStart=' "$shadow_tls_conf" | sed -n 's/.*--listen ::0:\([0-9]*\).*/\1/p')
            shadow_tls_password=$(grep 'ExecStart=' "$shadow_tls_conf" | sed -n 's/.*--password \([^ ]*\).*/\1/p')
            shadow_tls_sni=$(grep 'ExecStart=' "$shadow_tls_conf" | sed -n 's/.*--tls \([^ ]*\).*/\1/p')
            psk=$(awk -F ' = ' '/psk/ {print $2}' /etc/snell/snell-server.conf 2>/dev/null)
            
            # 检查版本来决定配置格式
            local snell_ver
            snell_ver=$(get_snell_version_from_binary "/usr/local/bin/snell-server")
            if [[ $snell_ver == v5* ]]; then
                version_num="5"
            elif [[ $snell_ver == v4* ]]; then
                version_num="4"
            else
                version_num="5"
            fi
            
            echo -e "${BLUE}$flag $ip_country = snell, $HOST_IP, $shadow_tls_port, psk=$psk, version=$version_num, reuse=true, shadow-tls-password=$shadow_tls_password, shadow-tls-sni=$shadow_tls_sni, shadow-tls-version=3${NC}"
        else
            log_error "Shadow-TLS v3 配置文件不存在"
        fi
    else
        log_error "Shadow-TLS v3 服务未安装"
    fi
    
    echo -e "${CYAN}===============================================${NC}"
    echo ""
}

# 主程序
main() {
    log_info "Snell 管理脚本 v2.0 启动"
    echo -e "${CYAN}===============================${NC}"
    echo -e "${CYAN}    Snell 管理脚本 v2.0    ${NC}"
    echo -e "${CYAN}===============================${NC}"
    echo ""

    get_current_version
    log_info "当前安装版本: $CURRENT_VERSION"

    if [ -z "$OLD_VERSION" ] || [ -z "$LATEST_VERSION" ]; then
        echo "正在获取最新版本信息..."
    fi
    get_latest_version
    log_info "v4老版本: $OLD_VERSION"
    log_info "v5最新版本: $LATEST_VERSION"

    echo ""

    # 显示当前安装状态
    show_install_status

    echo -e "${CYAN}选择操作:${NC}"
    echo "1. 安装 Snell"
    echo "2. 卸载 Snell"
    echo "3. 更新 Snell"
    echo "4. 安装 Shadow-TLS v3"
    echo "5. 卸载 Shadow-TLS v3"
    echo "6. 查看 Snell 和 Shadow-TLS v3 的配置"
    echo ""
    
    local choice
    read -p "输入选项 [1-6]: " choice

    case $choice in
        1) install_snell ;;
        2) uninstall_snell ;;
        3) update_snell ;;
        4) install_shadow_tls ;;
        5) uninstall_shadow_tls ;;
        6) generate_config ;;
        *) log_error "无效的选项: $choice" ;;
    esac
    
    # 显示操作完成提示
    echo ""
    echo -e "${GREEN}操作完成！${NC}"
    read -p "按任意键继续..." -n 1 -r
    echo ""
    
    # 递归调用主菜单
    main
}

# 启动主程序
main
