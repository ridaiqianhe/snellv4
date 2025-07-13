#!/bin/bash

# 全局变量
OLD_VERSION=""
LATEST_VERSION=""

# 提示用户需要 root 权限运行脚本
if [ "$(id -u)" != "0" ]; then
    echo "请以 root 权限运行此脚本."
    exit 1
fi

country_to_flag() {
  local country_code=$1
  local first_letter=${country_code:0:1}
  local second_letter=${country_code:1:1}
  local first_code=$(( $(printf "%d" "'$first_letter") - 65 + 0x1F1E6 ))
  local second_code=$(( $(printf "%d" "'$second_letter") - 65 + 0x1F1E6 ))
  printf -v flag "\\U%08X\\U%08X" $first_code $second_code
  echo -e "$flag"
}

get_host_ip() {
    HOST_IP=$(curl -s http://checkip.amazonaws.com)
}

get_latest_version() {
    # 只有在第一次调用时才获取版本信息
    if [ -z "$OLD_VERSION" ] || [ -z "$LATEST_VERSION" ]; then
        # 从官方文档获取版本信息
        local html_content=$(curl -s "https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell")
        
        if [ -z "$html_content" ]; then
            echo -e "\e[33m警告: 无法获取最新版本信息，使用默认版本\e[0m"
            OLD_VERSION="v4.1.1"
            LATEST_VERSION="v5.0.0"
            return
        fi
        
        # 提取老版本 (v4.x.x)
        OLD_VERSION=$(echo "$html_content" | grep -o 'snell-server-v4\.[0-9]\+\.[0-9]\+' | head -1 | sed 's/snell-server-//')
        
        # 提取最新版本 (v5.x.x)
        LATEST_VERSION=$(echo "$html_content" | grep -o 'snell-server-v5\.[0-9]\+\.[0-9]\+[a-z]*[0-9]*' | head -1 | sed 's/snell-server-//')
        
        # 如果无法提取版本，使用默认值
        if [ -z "$OLD_VERSION" ]; then
            OLD_VERSION="v4.1.1"
        fi
        
        if [ -z "$LATEST_VERSION" ]; then
            LATEST_VERSION="v5.0.0"
        fi
    fi
}

get_snell_port() {
    SNELL_PORT=$(awk -F '[: ]+' '/listen/ {print $4}' /etc/snell/snell-server.conf)
    if [ -z "$SNELL_PORT" ]; then
        read -p "请输入 Snell 代理协议端口: " SNELL_PORT
    else
        echo -e "\e[31m获取到的 Snell 端口: $SNELL_PORT\e[0m"
        read -p "确认端口 (默认为确认) [Y/n]: " confirm
        confirm=${confirm:-Y}
        if [[ ! $confirm =~ ^[Yy]$ ]]; then
            read -p "请输入 Snell 代理协议端口: " SNELL_PORT
        fi
    fi
}

get_latest_version_with_prompt() {
    if [ -z "$OLD_VERSION" ] || [ -z "$LATEST_VERSION" ]; then
        echo "正在获取最新版本信息..."
    fi
    get_latest_version
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
            echo -e "\e[32m选择了最新版: $SNELL_VERSION\e[0m"
            ;;
        2)
            SNELL_VERSION="$OLD_VERSION"
            echo -e "\e[33m选择了老版本: $SNELL_VERSION\e[0m"
            ;;
        *)
            echo -e "\e[33m无效选择，使用最新版: $LATEST_VERSION\e[0m"
            SNELL_VERSION="$LATEST_VERSION"
            ;;
    esac
}

get_current_version() {
    if [ -f "/usr/local/bin/snell-server" ]; then
        # 尝试多种方式获取版本
        CURRENT_VERSION=$(/usr/local/bin/snell-server --version 2>/dev/null | grep -o 'v[0-9]\+\.[0-9]\+\.[0-9]\+[a-z]*[0-9]*' | head -1)
        if [ -z "$CURRENT_VERSION" ]; then
            CURRENT_VERSION=$(/usr/local/bin/snell-server -v 2>/dev/null | grep -o 'v[0-9]\+\.[0-9]\+\.[0-9]\+[a-z]*[0-9]*' | head -1)
        fi
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
    apt-get update
    apt-get install -y unzip wget curl

    choose_version

    ARCH=$(arch)
    SNELL_URL=""
    INSTALL_DIR="/usr/local/bin"
    SYSTEMD_SERVICE_FILE="/lib/systemd/system/snell.service"
    CONF_DIR="/etc/snell"
    CONF_FILE="$CONF_DIR/snell-server.conf"

    # 根据架构选择下载链接
    case $ARCH in
        "aarch64")
            SNELL_URL="https://dl.nssurge.com/snell/snell-server-$SNELL_VERSION-linux-aarch64.zip"
            ;;
        "armv7l")
            SNELL_URL="https://dl.nssurge.com/snell/snell-server-$SNELL_VERSION-linux-armv7l.zip"
            ;;
        "i386"|"i686")
            SNELL_URL="https://dl.nssurge.com/snell/snell-server-$SNELL_VERSION-linux-i386.zip"
            ;;
        "x86_64")
            SNELL_URL="https://dl.nssurge.com/snell/snell-server-$SNELL_VERSION-linux-amd64.zip"
            ;;
        *)
            # 默认使用 amd64
            SNELL_URL="https://dl.nssurge.com/snell/snell-server-$SNELL_VERSION-linux-amd64.zip"
            echo "未识别的架构 $ARCH，使用默认的 amd64 版本"
            ;;
    esac

    echo "下载 Snell $SNELL_VERSION for $ARCH..."
    wget $SNELL_URL -O snell-server.zip
    if [ $? -ne 0 ]; then
        echo "下载 Snell 失败."
        exit 1
    fi

    unzip -o snell-server.zip -d $INSTALL_DIR
    if [ $? -ne 0 ]; then
        echo "解压缩 Snell 失败."
        exit 1
    fi

    rm snell-server.zip
    chmod +x $INSTALL_DIR/snell-server

    # 生成随机端口和PSK
    RANDOM_PORT=$(shuf -i 30000-65000 -n 1)
    RANDOM_PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)
    
    # 如果配置文件已存在，提供选择
    if [ -f "$CONF_FILE" ]; then
        echo -e "\e[33m检测到现有配置文件\e[0m"
        EXISTING_PORT=$(awk -F '[: ]+' '/listen/ {print $4}' $CONF_FILE)
        EXISTING_PSK=$(awk -F ' = ' '/psk/ {print $2}' $CONF_FILE)
        
        echo -e "\e[32m随机生成的端口: $RANDOM_PORT\e[0m"
        echo -e "\e[34m已存在的端口: $EXISTING_PORT\e[0m"
        read -p "是否使用已存在的端口？(Y/n): " use_existing_port
        use_existing_port=${use_existing_port:-Y}
        
        if [[ $use_existing_port =~ ^[Yy]$ ]]; then
            RANDOM_PORT=$EXISTING_PORT
            echo -e "\e[32m使用已存在的端口: $RANDOM_PORT\e[0m"
        else
            read -p "是否使用随机生成的端口？(Y/n): " use_random_port
            use_random_port=${use_random_port:-Y}
            
            if [[ ! $use_random_port =~ ^[Yy]$ ]]; then
                while true; do
                    read -p "请输入自定义端口 (1-65535): " CUSTOM_PORT
                    if [[ "$CUSTOM_PORT" -ge 1 && "$CUSTOM_PORT" -le 65535 ]]; then
                        RANDOM_PORT=$CUSTOM_PORT
                        break
                    else
                        echo -e "\e[31m端口范围无效，请输入1-65535之间的数字\e[0m"
                    fi
                done
            fi
            echo -e "\e[32m使用端口: $RANDOM_PORT\e[0m"
        fi
        
        # 密码设置
        echo -e "\e[32m随机生成的密码: $RANDOM_PSK\e[0m"
        echo -e "\e[34m已存在的密码: $EXISTING_PSK\e[0m"
        read -p "是否使用已存在的密码？(Y/n): " use_existing_psk
        use_existing_psk=${use_existing_psk:-Y}
        
        if [[ $use_existing_psk =~ ^[Yy]$ ]]; then
            RANDOM_PSK=$EXISTING_PSK
            echo -e "\e[32m使用已存在的密码: $RANDOM_PSK\e[0m"
        else
            read -p "请输入自定义密码 (留空使用随机密码): " CUSTOM_PSK
            if [ -n "$CUSTOM_PSK" ]; then
                RANDOM_PSK="$CUSTOM_PSK"
                echo -e "\e[32m使用自定义密码: $RANDOM_PSK\e[0m"
            else
                echo -e "\e[33m使用随机密码: $RANDOM_PSK\e[0m"
            fi
        fi
    else
        # 新安装情况下的端口设置
        echo -e "\e[32m随机生成的端口: $RANDOM_PORT\e[0m"
        read -p "是否使用此端口？(Y/n): " use_random_port
        use_random_port=${use_random_port:-Y}
        
        if [[ ! $use_random_port =~ ^[Yy]$ ]]; then
            while true; do
                read -p "请输入自定义端口 (1-65535): " CUSTOM_PORT
                if [[ "$CUSTOM_PORT" -ge 1 && "$CUSTOM_PORT" -le 65535 ]]; then
                    RANDOM_PORT=$CUSTOM_PORT
                    break
                else
                    echo -e "\e[31m端口范围无效，请输入1-65535之间的数字\e[0m"
                fi
            done
        fi
        echo -e "\e[32m使用端口: $RANDOM_PORT\e[0m"
        
        # 密码设置
        echo -e "\e[32m随机生成的密码: $RANDOM_PSK\e[0m"
        read -p "请输入自定义密码 (留空使用随机密码): " CUSTOM_PSK
        if [ -n "$CUSTOM_PSK" ]; then
            RANDOM_PSK="$CUSTOM_PSK"
            echo -e "\e[32m使用自定义密码: $RANDOM_PSK\e[0m"
        else
            echo -e "\e[33m使用随机密码: $RANDOM_PSK\e[0m"
        fi
    fi
    
    mkdir -p $CONF_DIR

    cat > $CONF_FILE << EOF
[snell-server]
listen = ::0:$RANDOM_PORT
psk = $RANDOM_PSK
ipv6 = true
EOF

    cat > $SYSTEMD_SERVICE_FILE << EOF
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

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable snell
    systemctl restart snell

    if [ $? -ne 0 ]; then
        echo "启动 Snell 服务失败."
        exit 1
    fi

    get_host_ip

    IP_COUNTRY=$(curl -s http://ipinfo.io/$HOST_IP/country)
    FLAG=$(country_to_flag $IP_COUNTRY)
    
    # 根据版本输出不同的配置
    if [[ $SNELL_VERSION == v5* ]]; then
        echo -e "\e[34mSnell $SNELL_VERSION 安装成功.\e[0m"
        echo -e "\e[34m$FLAG $IP_COUNTRY = snell, $HOST_IP, $RANDOM_PORT, psk = $RANDOM_PSK, version = 5, reuse = true, tfo = true\e[0m"
    else
        echo -e "\e[34mSnell $SNELL_VERSION 安装成功.\e[0m"
        echo -e "\e[34m$FLAG $IP_COUNTRY = snell, $HOST_IP, $RANDOM_PORT, psk = $RANDOM_PSK, version = 4, reuse = true, tfo = true\e[0m"
    fi
    
    # 更新当前版本信息
    CURRENT_VERSION="$SNELL_VERSION"
}

update_snell() {
    get_current_version
    
    if [ "$CURRENT_VERSION" = "not installed" ]; then
        echo -e "\e[31mSnell 未安装，请先安装 Snell\e[0m"
        return
    fi
    
    echo -e "\e[32m当前版本: $CURRENT_VERSION\e[0m"
    
    if [ -z "$OLD_VERSION" ] || [ -z "$LATEST_VERSION" ]; then
        echo "正在获取最新版本信息..."
    fi
    get_latest_version  # 确保版本信息已获取
    
    echo ""
    echo "可用版本:"
    echo "1. 最新版 ($LATEST_VERSION)"
    echo "2. 老版本 ($OLD_VERSION)"
    echo "3. 取消更新"
    
    read -p "选择要更新到的版本 [1-3]: " update_choice
    
    case $update_choice in
        1)
            TARGET_VERSION="$LATEST_VERSION"
            ;;
        2)
            TARGET_VERSION="$OLD_VERSION"
            ;;
        3)
            echo "取消更新"
            return
            ;;
        *)
            echo "无效选择"
            return
            ;;
    esac
    
    if [ "$CURRENT_VERSION" = "$TARGET_VERSION" ]; then
        echo -e "\e[33m当前版本已是最新版本 $TARGET_VERSION\e[0m"
        return
    fi
    
    echo -e "\e[33m准备从 $CURRENT_VERSION 更新到 $TARGET_VERSION\e[0m"
    read -p "确认更新? [Y/n]: " confirm
    confirm=${confirm:-Y}
    
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        echo "取消更新"
        return
    fi
    
    # 停止服务
    systemctl stop snell
    
    # 备份当前版本
    cp /usr/local/bin/snell-server /usr/local/bin/snell-server.backup
    
    SNELL_VERSION="$TARGET_VERSION"
    ARCH=$(arch)
    SNELL_URL=""
    INSTALL_DIR="/usr/local/bin"
    
    # 根据架构选择下载链接
    case $ARCH in
        "aarch64")
            SNELL_URL="https://dl.nssurge.com/snell/snell-server-$SNELL_VERSION-linux-aarch64.zip"
            ;;
        "armv7l")
            SNELL_URL="https://dl.nssurge.com/snell/snell-server-$SNELL_VERSION-linux-armv7l.zip"
            ;;
        "i386"|"i686")
            SNELL_URL="https://dl.nssurge.com/snell/snell-server-$SNELL_VERSION-linux-i386.zip"
            ;;
        "x86_64")
            SNELL_URL="https://dl.nssurge.com/snell/snell-server-$SNELL_VERSION-linux-amd64.zip"
            ;;
        *)
            SNELL_URL="https://dl.nssurge.com/snell/snell-server-$SNELL_VERSION-linux-amd64.zip"
            echo "未识别的架构 $ARCH，使用默认的 amd64 版本"
            ;;
    esac

    echo "下载 Snell $SNELL_VERSION for $ARCH..."
    wget $SNELL_URL -O snell-server-update.zip
    if [ $? -ne 0 ]; then
        echo "下载 Snell 失败，恢复原版本"
        systemctl start snell
        exit 1
    fi

    unzip -o snell-server-update.zip -d $INSTALL_DIR
    if [ $? -ne 0 ]; then
        echo "解压缩 Snell 失败，恢复原版本"
        cp /usr/local/bin/snell-server.backup /usr/local/bin/snell-server
        systemctl start snell
        exit 1
    fi

    rm snell-server-update.zip
    chmod +x $INSTALL_DIR/snell-server

    # 重新启动服务
    systemctl start snell

    if [ $? -ne 0 ]; then
        echo "启动 Snell 服务失败，恢复原版本"
        cp /usr/local/bin/snell-server.backup /usr/local/bin/snell-server
        systemctl start snell
        exit 1
    fi

    # 清理备份文件
    rm -f /usr/local/bin/snell-server.backup
    
    echo -e "\e[32mSnell 已成功更新到版本 $TARGET_VERSION\e[0m"
    
    # 显示配置信息
    generate_config
}

uninstall_snell() {
    if systemctl list-units --type=service | grep -q "snell.service"; then
        systemctl stop snell
        systemctl disable snell
        rm /lib/systemd/system/snell.service
        rm /usr/local/bin/snell-server
        rm -f /usr/local/bin/snell-server.backup
        rm -rf /etc/snell
        systemctl daemon-reload
        echo "Snell 卸载成功."
    else
        echo -e "\e[31mSnell 服务未安装.\e[0m"
    fi
}

show_snell_config() {
    CONF_FILE="/etc/snell/snell-server.conf"
    if [ -f "$CONF_FILE" ]; then
        echo "Snell 配置文件内容:"
        cat $CONF_FILE
    else
        echo -e "\e[31m配置文件不存在.\e[0m"
    fi
}

install_shadow_tls() {
    cd /usr/bin
    wget https://github.com/ihciah/shadow-tls/releases/download/v0.2.25/shadow-tls-x86_64-unknown-linux-musl
    if [ $? -ne 0 ]; then
        echo "下载 Shadow-TLS 失败."
        exit 1
    fi

    chmod +x shadow-tls-x86_64-unknown-linux-musl

    get_snell_port

    RANDOM_PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)
    PSK=$(awk -F ' = ' '/psk/ {print $2}' /etc/snell/snell-server.conf)

    # 生成随机端口
    SHADOW_TLS_PORT=$(shuf -i 30000-65000 -n 1)
    echo -e "\e[32m随机生成的 Shadow-TLS 端口: $SHADOW_TLS_PORT\e[0m"
    read -p "是否使用此端口？(Y/n): " use_random_port
    use_random_port=${use_random_port:-Y}
    
    if [[ ! $use_random_port =~ ^[Yy]$ ]]; then
        while true; do
            read -p "请输入自定义端口 (1-65535): " CUSTOM_PORT
            if [[ "$CUSTOM_PORT" -ge 1 && "$CUSTOM_PORT" -le 65535 ]]; then
                SHADOW_TLS_PORT=$CUSTOM_PORT
                break
            else
                echo -e "\e[31m端口范围无效，请输入1-65535之间的数字\e[0m"
            fi
        done
    fi
    
    # Shadow-TLS 密码设置
    echo -e "\e[32m随机生成的 Shadow-TLS 密码: $RANDOM_PASSWORD\e[0m"
    read -p "请输入自定义 Shadow-TLS 密码 (留空使用随机密码): " CUSTOM_SHADOWTLS_PASSWORD
    if [ -n "$CUSTOM_SHADOWTLS_PASSWORD" ]; then
        RANDOM_PASSWORD="$CUSTOM_SHADOWTLS_PASSWORD"
        echo -e "\e[32m使用自定义 Shadow-TLS 密码: $RANDOM_PASSWORD\e[0m"
    else
        echo -e "\e[33m使用随机 Shadow-TLS 密码: $RANDOM_PASSWORD\e[0m"
    fi

    echo "请选择一个 --tls 参数 (默认选择1): "
    OPTIONS=("gateway.icloud.com" "mp.weixin.qq.com" "coding.net" "upyun.com" "sns-video-hw.xhscdn.com" "sns-img-qc.xhscdn.com" "sns-video-qn.xhscdn.com" "p9-dy.byteimg.com" "p6-dy.byteimg.com" "feishu.cn" "douyin.com" "toutiao.com" "v6-dy-y.ixigua.com" "hls3-akm.douyucdn.cn" "publicassets.cdn-apple.com" "weather-data.apple.com")
    
    # 显示选项
    for i in "${!OPTIONS[@]}"; do
        echo "$((i+1)). ${OPTIONS[$i]}"
    done
    
    read -p "输入选项 (1-${#OPTIONS[@]}) [默认: 1]: " tls_choice
    tls_choice=${tls_choice:-1}
    
    # 验证选择
    if [[ "$tls_choice" -ge 1 && "$tls_choice" -le "${#OPTIONS[@]}" ]]; then
        tls_option="${OPTIONS[$((tls_choice-1))]}"
        echo -e "\e[32m选择了: $tls_option\e[0m"
    else
        echo -e "\e[33m无效选择，使用默认选项: ${OPTIONS[0]}\e[0m"
        tls_option="${OPTIONS[0]}"
    fi

    cat > /etc/systemd/system/shadow-tls.service << EOF
[Unit]
Description=Shadow-TLS Server Service
Documentation=man:sstls-server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=MONOIO_FORCE_LEGACY_DRIVER=1
ExecStart=/usr/bin/shadow-tls-x86_64-unknown-linux-musl --v3 server --server 0.0.0.0:$SNELL_PORT --password $RANDOM_PASSWORD --listen ::0:$SHADOW_TLS_PORT --tls $tls_option
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=shadow-tls

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable shadow-tls.service
    systemctl start shadow-tls.service

    if [ $? -ne 0 ]; then
        echo "启动 Shadow-TLS 服务失败."
        exit 1
    fi

    iptables -t nat -A PREROUTING -p udp --dport $SHADOW_TLS_PORT -j REDIRECT --to-port $SNELL_PORT
    iptables -t nat -A OUTPUT -p udp --dport $SHADOW_TLS_PORT -j REDIRECT --to-port $SNELL_PORT
    
    if [ -x "$(command -v iptables-save)" ]; then
        if [ ! -d /etc/iptables ]; then
            mkdir -p /etc/iptables
        fi
        if [ ! -f /etc/iptables/rules.v4 ]; then
            touch /etc/iptables/rules.v4
        fi
        iptables-save > /etc/iptables/rules.v4
    fi

    get_host_ip

    IP_COUNTRY=$(curl -s http://ipinfo.io/$HOST_IP/country)
    FLAG=$(country_to_flag $IP_COUNTRY)

    echo -e "\e[34mShadow-TLS 安装成功.\e[0m"
    
    # 检查Snell版本来决定配置格式
    if [ -f "/usr/local/bin/snell-server" ]; then
        SNELL_VER=$(/usr/local/bin/snell-server --version 2>/dev/null | grep -o 'v[0-9]\+\.[0-9]\+\.[0-9]\+[a-z]*[0-9]*' | head -1)
        if [ -z "$SNELL_VER" ]; then
            SNELL_VER=$(/usr/local/bin/snell-server -v 2>/dev/null | grep -o 'v[0-9]\+\.[0-9]\+\.[0-9]\+[a-z]*[0-9]*' | head -1)
        fi
        if [[ $SNELL_VER == v5* ]]; then
            VERSION_NUM="5"
        elif [[ $SNELL_VER == v4* ]]; then
            VERSION_NUM="4"
        else
            VERSION_NUM="5"
        fi
    else
        VERSION_NUM="5"
    fi
    
    echo -e "\e[34m$FLAG $IP_COUNTRY = snell, $HOST_IP, $SHADOW_TLS_PORT, psk=$PSK, version=$VERSION_NUM, reuse=true, shadow-tls-password=$RANDOM_PASSWORD, shadow-tls-sni=${tls_option}, shadow-tls-version=3\e[0m"
}

uninstall_shadow_tls() {
    if systemctl list-units --type=service | grep -q "shadow-tls.service"; then
        systemctl stop shadow-tls
        systemctl disable shadow-tls
        rm /etc/systemd/system/shadow-tls.service
        rm /usr/bin/shadow-tls-x86_64-unknown-linux-musl
        systemctl daemon-reload
        echo "Shadow-TLS 卸载成功."
    else
        echo -e "\e[31mShadow-TLS 服务未安装.\e[0m"
    fi
}

show_version_info() {
    echo -e "\e[36m========== 版本信息 ==========\e[0m"
    
    get_current_version
    echo -e "\e[32m当前安装版本: $CURRENT_VERSION\e[0m"
    
    if [ -z "$OLD_VERSION" ] || [ -z "$LATEST_VERSION" ]; then
        echo "正在获取最新版本信息..."
    fi
    get_latest_version  # 确保版本信息已获取
    echo -e "\e[32mv5最新版本: $LATEST_VERSION\e[0m"
    echo -e "\e[32mv4老版本: $OLD_VERSION\e[0m"
    
    echo -e "\e[36m============================\e[0m"
}

show_install_status() {
    echo -e "\e[36m========== 当前安装状态 ==========\e[0m"
    
    # 检查Snell状态
    if systemctl list-units --type=service | grep -q "snell.service"; then
        if systemctl is-active --quiet snell; then
            echo -e "\e[32m✓ Snell 服务: 已安装并运行中\e[0m"
            if [ -f "/etc/snell/snell-server.conf" ]; then
                SNELL_PORT=$(awk -F '[: ]+' '/listen/ {print $4}' /etc/snell/snell-server.conf)
                PSK=$(awk -F ' = ' '/psk/ {print $2}' /etc/snell/snell-server.conf)
                echo -e "\e[34m  端口: $SNELL_PORT\e[0m"
                echo -e "\e[34m  密码: $PSK\e[0m"
            fi
        else
            echo -e "\e[33m⚠ Snell 服务: 已安装但未运行\e[0m"
        fi
    else
        echo -e "\e[31m✗ Snell 服务: 未安装\e[0m"
    fi
    
    # 检查Shadow-TLS状态
    if systemctl list-units --type=service | grep -q "shadow-tls.service"; then
        if systemctl is-active --quiet shadow-tls; then
            echo -e "\e[32m✓ Shadow-TLS 服务: 已安装并运行中\e[0m"
            if [ -f "/etc/systemd/system/shadow-tls.service" ]; then
                SHADOW_TLS_PORT=$(grep 'ExecStart=' /etc/systemd/system/shadow-tls.service | sed -n 's/.*--listen ::0:\([0-9]*\).*/\1/p')
                SHADOW_TLS_PASSWORD=$(grep 'ExecStart=' /etc/systemd/system/shadow-tls.service | sed -n 's/.*--password \([^ ]*\).*/\1/p')
                SHADOW_TLS_SNI=$(grep 'ExecStart=' /etc/systemd/system/shadow-tls.service | sed -n 's/.*--tls \([^ ]*\).*/\1/p')
                echo -e "\e[34m  端口: $SHADOW_TLS_PORT\e[0m"
                echo -e "\e[34m  密码: $SHADOW_TLS_PASSWORD\e[0m"
                echo -e "\e[34m  SNI: $SHADOW_TLS_SNI\e[0m"
            fi
        else
            echo -e "\e[33m⚠ Shadow-TLS 服务: 已安装但未运行\e[0m"
        fi
    else
        echo -e "\e[31m✗ Shadow-TLS 服务: 未安装\e[0m"
    fi
    
    echo -e "\e[36m================================\e[0m"
    echo ""
}

generate_config() {
    get_host_ip
    IP_COUNTRY=$(curl -s http://ipinfo.io/$HOST_IP/country)
    FLAG=$(country_to_flag $IP_COUNTRY)
    
    if systemctl list-units --type=service | grep -q "snell.service"; then
        CONF_FILE="/etc/snell/snell-server.conf"
        if [ -f "$CONF_FILE" ];then
            SNELL_PORT=$(awk -F '[: ]+' '/listen/ {print $4}' $CONF_FILE)
            PSK=$(awk -F ' = ' '/psk/ {print $2}' $CONF_FILE)
            
            # 检查版本来决定配置格式
            if [ -f "/usr/local/bin/snell-server" ]; then
                SNELL_VER=$(/usr/local/bin/snell-server --version 2>/dev/null | grep -o 'v[0-9]\+\.[0-9]\+\.[0-9]\+[a-z]*[0-9]*' | head -1)
                if [ -z "$SNELL_VER" ]; then
                    SNELL_VER=$(/usr/local/bin/snell-server -v 2>/dev/null | grep -o 'v[0-9]\+\.[0-9]\+\.[0-9]\+[a-z]*[0-9]*' | head -1)
                fi
                if [[ $SNELL_VER == v5* ]]; then
                    VERSION_NUM="5"
                elif [[ $SNELL_VER == v4* ]]; then
                    VERSION_NUM="4"
                else
                    # 通过安装的版本来推测
                    VERSION_NUM="5"
                fi
            else
                VERSION_NUM="5"
            fi
            
            echo -e "\e[34m$FLAG $IP_COUNTRY = snell, $HOST_IP, $SNELL_PORT, psk = $PSK, version = $VERSION_NUM, reuse = true, tfo = true\e[0m"
        else
            echo -e "\e[31mSnell 配置文件不存在.\e[0m"
        fi
    else
        echo -e "\e[31mSnell 服务未安装.\e[0m"
    fi

    if systemctl list-units --type=service | grep -q "shadow-tls.service"; then
        SHADOW_TLS_CONF="/etc/systemd/system/shadow-tls.service"
        if [ -f "$SHADOW_TLS_CONF" ]; then
            SHADOW_TLS_PORT=$(grep 'ExecStart=' $SHADOW_TLS_CONF | sed -n 's/.*--listen ::0:\([0-9]*\).*/\1/p')
            SHADOW_TLS_PASSWORD=$(grep 'ExecStart=' $SHADOW_TLS_CONF | sed -n 's/.*--password \([^ ]*\).*/\1/p')
            SHADOW_TLS_SNI=$(grep 'ExecStart=' $SHADOW_TLS_CONF | sed -n 's/.*--tls \([^ ]*\).*/\1/p')
            PSK=$(awk -F ' = ' '/psk/ {print $2}' /etc/snell/snell-server.conf)
            
            # 检查版本来决定配置格式
            if [ -f "/usr/local/bin/snell-server" ]; then
                SNELL_VER=$(/usr/local/bin/snell-server --version 2>/dev/null | grep -o 'v[0-9]\+\.[0-9]\+\.[0-9]\+[a-z]*[0-9]*' | head -1)
                if [ -z "$SNELL_VER" ]; then
                    SNELL_VER=$(/usr/local/bin/snell-server -v 2>/dev/null | grep -o 'v[0-9]\+\.[0-9]\+\.[0-9]\+[a-z]*[0-9]*' | head -1)
                fi
                if [[ $SNELL_VER == v5* ]]; then
                    VERSION_NUM="5"
                elif [[ $SNELL_VER == v4* ]]; then
                    VERSION_NUM="4"
                else
                    VERSION_NUM="5"
                fi
            else
                VERSION_NUM="5"
            fi
            
            echo -e "\e[34m$FLAG $IP_COUNTRY = snell, $HOST_IP, $SHADOW_TLS_PORT, psk=$PSK, version=$VERSION_NUM, reuse=true, shadow-tls-password=$SHADOW_TLS_PASSWORD, shadow-tls-sni=$SHADOW_TLS_SNI, shadow-tls-version=3\e[0m"
        else
            echo -e "\e[31mShadow-TLS v3 配置文件不存在.\e[0m"
        fi
    else
        echo -e "\e[31mShadow-TLS v3 服务未安装.\e[0m"
    fi
}

# 主菜单
echo "Snell 管理脚本"
echo "=============="

get_current_version
echo -e "\e[32m当前安装版本: $CURRENT_VERSION\e[0m"

if [ -z "$OLD_VERSION" ] || [ -z "$LATEST_VERSION" ]; then
    echo "正在获取最新版本信息..."
fi
get_latest_version
echo -e "\e[32mv4老版本: $OLD_VERSION\e[0m"
echo -e "\e[32mv5最新版本: $LATEST_VERSION\e[0m"

echo ""

# 显示当前安装状态
show_install_status

echo "选择操作:"
echo "1. 安装 Snell"
echo "2. 卸载 Snell"
echo "3. 更新 Snell"
echo "4. 安装 Shadow-TLS v3"
echo "5. 卸载 Shadow-TLS v3"
echo "6. 查看 Snell 和 Shadow-TLS v3 的配置"
echo "7. 查看 Snell 配置文件"
echo "8. 检查版本信息"
read -p "输入选项: " choice

case $choice in
    1) install_snell ;;
    2) uninstall_snell ;;
    3) update_snell ;;
    4) install_shadow_tls ;;
    5) uninstall_shadow_tls ;;
    6) generate_config ;;
    7) show_snell_config ;;
    8) show_version_info ;;
    *) echo "无效的选项" ;;
esac
