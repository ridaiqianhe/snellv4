#!/bin/bash

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
    apt-get update
    apt-get install -y unzip wget curl

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

    RANDOM_PORT=$(shuf -i 30000-65000 -n 1)
    RANDOM_PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)

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
    systemctl start snell

    if [ $? -ne 0 ]; then
        echo "启动 Snell 服务失败."
        exit 1
    fi

    get_host_ip

    IP_COUNTRY=$(curl -s http://ipinfo.io/$HOST_IP/country)
    FLAG=$(country_to_flag $IP_COUNTRY)
    echo -e "\e[34mSnell 安装成功.\e[0m"
    echo -e "\e[34m$FLAG $IP_COUNTRY = snell, $HOST_IP, $RANDOM_PORT, psk = $RANDOM_PSK, version = 4, reuse = true, tfo = true\e[0m"
}

uninstall_snell() {
    if systemctl list-units --type=service | grep -q "snell.service"; then
        systemctl stop snell
        systemctl disable snell
        rm /lib/systemd/system/snell.service
        rm /usr/local/bin/snell-server
        rm -rf /etc/snell
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

    read -p "请输入 Shadow-TLS 监听端口 (1-65535): " SHADOW_TLS_PORT
    if [[ "$SHADOW_TLS_PORT" -ge 1 && "$SHADOW_TLS_PORT" -le 65535 ]]; then
        echo "使用用户输入的端口: $SHADOW_TLS_PORT"
    else
        SHADOW_TLS_PORT=$((RANDOM % 55536 + 10000))
        echo "输入无效，随机生成的端口: $SHADOW_TLS_PORT"
    fi

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

    echo -e "\e[34mShadow-TLS 安装成功.\e[0m"
    echo -e "\e[34mHK = snell, $HOST_IP, $SHADOW_TLS_PORT, psk=$PSK, version=4, reuse=true, shadow-tls-password=$RANDOM_PASSWORD, shadow-tls-sni=${tls_option}, shadow-tls-version=3\e[0m"
}

uninstall_shadow_tls() {
    if systemctl list-units --type=service | grep -q "shadow-tls.service"; then
        systemctl stop shadow-tls
        systemctl disable shadow-tls
        rm /etc/systemd/system/shadow-tls.service
        rm /usr/bin/shadow-tls-x86_64-unknown-linux-musl
        echo "Shadow-TLS 卸载成功."
    else
        echo -e "\e[31mShadow-TLS 服务未安装.\e[0m"
    fi
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
            echo -e "\e[34m$FLAG $IP_COUNTRY = snell, $HOST_IP, $SNELL_PORT, psk = $PSK, version = 4, reuse = true, tfo = true\e[0m"
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
            echo -e "\e[34m$FLAG $IP_COUNTRY = snell, $HOST_IP, $SHADOW_TLS_PORT, psk=$PSK, version=4, reuse=true, shadow-tls-password=$SHADOW_TLS_PASSWORD, shadow-tls-sni=$SHADOW_TLS_SNI, shadow-tls-version=3\e[0m"
        else
            echo -e "\e[31mShadow-TLS v3 配置文件不存在.\e[0m"
        fi
    else
        echo -e "\e[31mShadow-TLS v3 服务未安装.\e[0m"
    fi
}

echo "选择操作:"
echo "1. 安装 Snell v4"
echo "2. 卸载 Snell v4"
echo "3. 安装 Shadow-TLS v3"
echo "4. 卸载 Shadow-TLS v3"
echo "5. 查看 Snell 和 Shadow-TLS v3 的配置"
read -p "输入选项: " choice

case $choice in
    1) install_snell ;;
    2) uninstall_snell ;;
    3) install_shadow_tls ;;
    4) uninstall_shadow_tls ;;
    5) generate_config ;;
    *) echo "无效的选项" ;;
esac
