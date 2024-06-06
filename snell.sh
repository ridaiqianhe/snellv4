#!/bin/bash

# 提示用户需要 root 权限运行脚本
if [ "$(id -u)" != "0" ]; then
    echo "请以 root 权限运行此脚本."
    exit 1
fi

get_host_ip() {
    HOST_IP=$(curl -s http://checkip.amazonaws.com)
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

install_snell() {
    # 判断系统及定义系统安装依赖方式
    REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora")
    RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora")
    PACKAGE_UPDATE=("apt-get update" "apt-get update" "yum -y update" "yum -y update" "yum -y update")
    PACKAGE_INSTALL=("apt -y install" "apt -y install" "yum -y install" "yum -y install" "yum -y install")
    PACKAGE_REMOVE=("apt -y remove" "apt -y remove" "yum -y remove" "yum -y remove" "yum -y remove")
    PACKAGE_UNINSTALL=("apt -y autoremove" "apt -y autoremove" "yum -y autoremove" "yum -y autoremove" "yum -y autoremove")

    # 安装必要的软件包
    apt-get install -y unzip wget curl

    # 下载 Snell 服务器文件
    SNELL_VERSION="v4.0.1"
    ARCH=$(arch)
    SNELL_URL=""
    INSTALL_DIR="/usr/local/bin"
    SYSTEMD_SERVICE_FILE="/lib/systemd/system/snell.service"
    CONF_DIR="/etc/snell"
    CONF_FILE="$CONF_DIR/snell-server.conf"

    if [[ $ARCH == "aarch64" ]]; then
        SNELL_URL="https://dl.nssurge.com/snell/snell-server-$SNELL_VERSION-linux-aarch64.zip"
    else
        SNELL_URL="https://dl.nssurge.com/snell/snell-server-$SNELL_VERSION-linux-amd64.zip"
    fi

    # 下载 Snell 服务器文件
    wget $SNELL_URL -O snell-server.zip
    if [ $? -ne 0 ]; then
        echo "下载 Snell 失败."
        exit 1
    fi

    # 解压缩文件到指定目录
    sudo unzip -o snell-server.zip -d $INSTALL_DIR
    if [ $? -ne 0 ]; then
        echo "解压缩 Snell 失败."
        exit 1
    fi

    # 删除下载的 zip 文件
    rm snell-server.zip

    # 赋予执行权限
    chmod +x $INSTALL_DIR/snell-server

    # 生成随机端口和密码
    RANDOM_PORT=$(shuf -i 30000-65000 -n 1)
    RANDOM_PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)

    # 创建配置文件目录
    mkdir -p $CONF_DIR

    # 创建配置文件
    cat > $CONF_FILE << EOF
[snell-server]
listen = ::0:$RANDOM_PORT
psk = $RANDOM_PSK
ipv6 = true
EOF

    # 创建 Systemd 服务文件
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

    # 重载 Systemd 配置
    sudo systemctl daemon-reload
    if [ $? -ne 0 ]; then
        echo "重载 Systemd 配置失败."
        exit 1
    fi

    # 开机自启动 Snell
    sudo systemctl enable snell
    if [ $? -ne 0 ]; then
        echo "开机自启动 Snell 失败."
        exit 1
    fi

    # 启动 Snell 服务
    sudo systemctl start snell
    if [ $? -ne 0 ]; then
        echo "启动 Snell 服务失败."
        exit 1
    fi

    get_host_ip

    # 获取IP所在国家
    IP_COUNTRY=$(curl -s http://ipinfo.io/$HOST_IP/country)

    # 输出所需信息，包含IP所在国家
    echo -e "\e[34mSnell 安装成功.\e[0m"
    echo -e "\e[34m$IP_COUNTRY = snell, $HOST_IP, $RANDOM_PORT, psk = $RANDOM_PSK, version = 4, reuse = true, tfo = true\e[0m"
}

uninstall_snell() {
    # 停止 Snell 服务
    sudo systemctl stop snell
    if [ $? -ne 0 ]; then
        echo "停止 Snell 服务失败."
        exit 1
    fi

    # 禁用开机自启动
    sudo systemctl disable snell
    if [ $? -ne 0 ]; then
        echo "禁用开机自启动失败."
        exit 1
    fi

    # 删除 Systemd 服务文件
    sudo rm /lib/systemd/system/snell.service
    if [ $? -ne 0 ]; then
        echo "删除 Systemd 服务文件失败."
        exit 1
    fi

    # 删除安装的文件和目录
    sudo rm /usr/local/bin/snell-server
    sudo rm -rf /etc/snell

    echo "Snell 卸载成功."
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
    # 下载 Shadow-TLS v3 二进制文件
    cd /usr/bin
    wget https://github.com/ihciah/shadow-tls/releases/download/v0.2.25/shadow-tls-x86_64-unknown-linux-musl
    if [ $? -ne 0 ]; then
        echo "下载 Shadow-TLS 失败."
        exit 1
    fi

    # 增加运行权限
    chmod +x shadow-tls-x86_64-unknown-linux-musl

    # 获取 Snell 端口
    get_snell_port

    # 生成随机密码
    RANDOM_PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)
    PSK=$(awk -F ' = ' '/psk/ {print $2}' /etc/snell/snell-server.conf)

    read -p "请输入 Shadow-TLS 监听端口 (1-65535): " SHADOW_TLS_PORT

    if [[ "$SHADOW_TLS_PORT" -ge 1 && "$SHADOW_TLS_PORT" -le 65535 ]]; then
      echo "使用用户输入的端口: $SHADOW_TLS_PORT"
    else
      SHADOW_TLS_PORT=$((RANDOM % 55536 + 10000))
      echo "输入无效，随机生成的端口: $SHADOW_TLS_PORT"
    fi
    
    # 你可以在这里添加其他配置逻辑


    echo "请选择一个 --tls 参数: "
    OPTIONS=("gateway.icloud.com" "mp.weixin.qq.com" "coding.net" "upyun.com" "sns-video-hw.xhscdn.com" "sns-img-qc.xhscdn.com" "sns-video-qn.xhscdn.com" "p9-dy.byteimg.com" "p6-dy.byteimg.com" "feishu.cn" "douyin.com" "toutiao.com" "v6-dy-y.ixigua.com" "hls3-akm.douyucdn.cn" "publicassets.cdn-apple.com" "weather-data.apple.com")
    select tls_option in "${OPTIONS[@]}"
    do
        if [[ " ${OPTIONS[*]} " == *" $tls_option "* ]]; then
            break
        else
            echo "无效的选项，请重新选择."
        fi
    done

    # 创建 Systemd 服务文件
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

    # 刷新并启动服务
    systemctl daemon-reload
    if [ $? -ne 0 ];then
        echo "重载 Systemd 配置失败."
        exit 1
    fi

    systemctl enable shadow-tls.service
    if [ $? -ne 0 ];then
        echo "开机自启动 Shadow-TLS 失败."
        exit 1
    fi

    systemctl start shadow-tls.service
    if [ $? -ne 0 ];then
        echo "启动 Shadow-TLS 服务失败."
        exit 1
    fi

    # 添加 iptables 规则
    sudo iptables -t nat -A PREROUTING -p udp --dport $SHADOW_TLS_PORT -j REDIRECT --to-port $SNELL_PORT
    sudo iptables -t nat -A OUTPUT -p udp --dport $SHADOW_TLS_PORT -j REDIRECT --to-port $SNELL_PORT
    
    # 保存 iptables 规则，使其在重启后生效
    if [ -x "$(command -v iptables-save)" ]; then
        if [ ! -d /etc/iptables ]; then
            sudo mkdir -p /etc/iptables
        fi
        if [ ! -f /etc/iptables/rules.v4 ]; then
            sudo touch /etc/iptables/rules.v4
        fi
        sudo iptables-save > /etc/iptables/rules.v4
    fi



    get_host_ip

    echo -e "\e[34mShadow-TLS 安装成功.\e[0m"
    echo -e "\e[34mHK = snell, $HOST_IP, $SHADOW_TLS_PORT, psk=$PSK, version=4, reuse=true, shadow-tls-password=$RANDOM_PASSWORD, shadow-tls-sni=${tls_option}, shadow-tls-version=3\e[0m"
}

uninstall_shadow_tls() {
    # 停止 Shadow-TLS 服务
    systemctl stop shadow-tls
    if [ $? -ne 0 ]; then
        echo "停止 Shadow-TLS 服务失败."
        exit 1
    fi

    # 禁用开机自启动
    systemctl disable shadow-tls
    if [ $? -ne 0 ]; then
        echo "禁用开机自启动失败."
        exit 1
    fi

    # 删除 Systemd 服务文件
    rm /etc/systemd/system/shadow-tls.service
    if [ $? -ne 0 ]; then
        echo "删除 Systemd 服务文件失败."
        exit 1
    fi

    # 删除安装的文件
    rm /usr/bin/shadow-tls-x86_64-unknown-linux-musl

    echo "Shadow-TLS 卸载成功."
}

# 显示菜单选项
echo "选择操作:"
echo "1. 安装 Snell v4"
echo "2. 卸载 Snell v4"
echo "3. 显示 Snell v4配置文件"
echo "4. 安装 Shadow-TLS v3"
echo "5. 卸载 Shadow-TLS v3"
read -p "输入选项: " choice

case $choice in
    1) install_snell ;;
    2) uninstall_snell ;;
    3) show_snell_config ;;
    4) install_shadow_tls ;;
    5) uninstall_shadow_tls ;;
    *) echo "无效的选项" ;;
esac
