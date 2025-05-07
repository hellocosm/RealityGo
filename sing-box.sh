#!/bin/bash

SING_BOX_PATH="/etc/sing-box/"
SERVICE_FILE_PATH='/etc/systemd/system/sing-box.service'
SHARE_LINKS=""
NODE_NAME=""
PORT=443
SNI="global.fujifilm.com"

# 检查 sing-box 是否在运行，若运行则停止
stop_singbox_if_running() {
    if pgrep -x "sing-box" > /dev/null; then
        echo "检测到 sing-box 正在运行，正在停止服务..."
        systemctl stop sing-box || service sing-box stop
        sleep 2
    fi
}

# 查询本机IP及国家
get_ip_info() {
    IPV4=$(curl -s4 ip.sb)
    IPV6=$(curl -s6 ip.sb)
    # 查询国家
    COUNTRY4=$(curl -s4 https://ipapi.co/country_name 2>/dev/null)
    COUNTRY6=$(curl -s6 https://ipapi.co/country_name 2>/dev/null)
    # 默认国家名
    [ -z "$COUNTRY4" ] && COUNTRY4="未知"
    [ -z "$COUNTRY6" ] && COUNTRY6="未知"
}

# 检查双栈
check_stack() {
    get_ip_info
    HAS_IPV4=0
    HAS_IPV6=0
    [[ -n "$IPV4" && ! "$IPV4" =~ "error" ]] && HAS_IPV4=1
    [[ -n "$IPV6" && ! "$IPV6" =~ "error" ]] && HAS_IPV6=1
}

# 系统检测
os_check() {
    if [[ -f /etc/redhat-release ]]; then
        OS_RELEASE="centos"
    elif grep -Eqi "debian" /etc/issue /proc/version 2>/dev/null; then
        OS_RELEASE="debian"
    elif grep -Eqi "ubuntu" /etc/issue /proc/version 2>/dev/null; then
        OS_RELEASE="ubuntu"
    elif grep -Eqi "alpine" /etc/issue 2>/dev/null; then
        OS_RELEASE="alpine"
    else
        echo "不支持的系统" && exit 1
    fi
}

# 架构检测
arch_check() {
    OS_ARCH=$(arch)
    case $OS_ARCH in
        x86_64|x64|amd64) OS_ARCH="amd64" ;;
        aarch64|arm64) OS_ARCH="arm64" ;;
        *) OS_ARCH="amd64" ;;
    esac
}

# 安装依赖
install_base() {
    case $OS_RELEASE in
        debian|ubuntu)
            apt update
            apt install -y wget tar jq openssl curl
            ;;
        centos)
            yum install -y wget tar jq openssl curl
            ;;
        alpine)
            apk update
            apk add wget tar jq openssl curl
            ;;
    esac
}

# 下载 sing-box
download_sing_box() {
    local latest_version=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep 'tag_name' | head -1 | awk -F '"' '{print $4}')
    [ -z "$latest_version" ] && latest_version="v1.8.0"
    local version_num=${latest_version#v}
    local url="https://github.com/SagerNet/sing-box/releases/download/${latest_version}/sing-box-${version_num}-linux-${OS_ARCH}.tar.gz"

    mkdir -p ${SING_BOX_PATH}
    cd ${SING_BOX_PATH}
    wget -q --no-check-certificate -O sing-box.tar.gz $url
    tar -xzf sing-box.tar.gz
    rm -f sing-box.tar.gz
    mv sing-box-${version_num}-linux-${OS_ARCH}/* .
    rm -rf sing-box-${version_num}-linux-${OS_ARCH}
}

# 生成 Reality 节点配置
generate_reality_config() {
    local listen_ip="$1"
    local listen_port="$2"
    local uuid="$3"
    local prikey="$4"
    local shortid="$5"
    local sni="$6"
    local node_name="$7"

    cat > ${SING_BOX_PATH}/config.json <<EOF
{
  "log": {
    "level": "debug",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "::",
      "listen_port": ${listen_port},
      "multiplex": {
        "enabled": true,
        "padding": true,
        "brutal": {
          "enabled": true,
          "up_mbps": 1000,
          "down_mbps": 1000
        }
      },
      "tcp_multi_path": true,
      "users": [
        {
          "uuid": "${uuid}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${sni}",
        "alpn": ["h2","http/1.1"],
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${sni}",
            "server_port": ${listen_port}
          },
          "private_key": "${prikey}",
          "short_id": ["${shortid}"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct",
      "domain_strategy": "prefer_ipv4"
    }
  ]
}
EOF
}

# 生成 Reality 分享链接
gen_share_link() {
    local uuid="$1"
    local ip="$2"
    local port="$3"
    local pbk="$4"
    local sni="$5"
    local shortid="$6"
    local node_name="$7"
    echo "vless://${uuid}@${ip}:${port}?security=reality&encryption=none&pbk=${pbk}&headerType=none&fp=chrome&type=tcp&sni=${sni}&sid=${shortid}&flow=xtls-rprx-vision#${node_name}"
}

# 安装 systemd 服务
install_systemd_service() {
    if [[ "$OS_RELEASE" == "alpine" ]]; then
        SERVICE_FILE_PATH="/etc/init.d/sing-box"
    fi

    if [[ -f "$SERVICE_FILE_PATH" ]]; then
        rm -f "$SERVICE_FILE_PATH"
    fi

    if [[ "$OS_RELEASE" == "alpine" ]]; then
        cat > $SERVICE_FILE_PATH <<EOF
#!/sbin/openrc-run

name="sing-box"
description="Sing-Box Service"
supervisor="supervise-daemon"
command="${SING_BOX_PATH}sing-box run"
command_args="-c ${SING_BOX_PATH}config.json"
command_user="root:root"

depend() {
  after net dns
  use net
}
EOF
        chmod +x $SERVICE_FILE_PATH
        rc-update add sing-box
    else
        cat > $SERVICE_FILE_PATH <<EOF
[Unit]
Description=sing-box Service
Documentation=https://sing-box.sagernet.org/
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
ExecStart=${SING_BOX_PATH}sing-box run -c ${SING_BOX_PATH}config.json
Restart=on-failure
RestartSec=30s
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
        chmod +x $SERVICE_FILE_PATH
        mkdir -p /etc/systemd/system/sing-box.service.d
        echo -e "[Service]\nCPUSchedulingPolicy=rr\nCPUSchedulingPriority=99" > /etc/systemd/system/sing-box.service.d/priority.conf
        systemctl daemon-reload
        systemctl enable sing-box
    fi
}

# 主流程
main() {
    stop_singbox_if_running
    os_check
    arch_check
    install_base
    download_sing_box
    check_stack

    cd ${SING_BOX_PATH}
    # 生成 Reality 密钥对（修复换行问题）
    KEYS=$(./sing-box generate reality-keypair)
    PRIKEY=$(echo "$KEYS" | grep PrivateKey | awk '{print $2}')
    PBK=$(echo "$KEYS" | grep PublicKey | awk '{print $2}')
    UUID=$(./sing-box generate uuid)
    SHORTID=$(openssl rand -hex 8)

    SHARE_LINKS=""

    # 生成节点名和节点
    if [[ $HAS_IPV4 -eq 1 && $HAS_IPV6 -eq 1 ]]; then
        # 双栈
        NODE_NAME4="${COUNTRY4}-Reality"
        NODE_NAME6="${COUNTRY6}-Reality-v6"
        generate_reality_config "::" $PORT $UUID $PRIKEY $SHORTID $SNI "$NODE_NAME4"
        SHARE_LINKS="$(gen_share_link $UUID $IPV4 $PORT $PBK $SNI $SHORTID "$NODE_NAME4")"
        # 生成IPv6节点配置文件和分享链接（如需单独配置文件可复制config.json）
        SHARE_LINKS="${SHARE_LINKS}\n$(gen_share_link $UUID "[$IPV6]" $PORT $PBK $SNI $SHORTID "$NODE_NAME6")"
    elif [[ $HAS_IPV4 -eq 1 ]]; then
        NODE_NAME4="${COUNTRY4}-Reality"
        generate_reality_config "::" $PORT $UUID $PRIKEY $SHORTID $SNI "$NODE_NAME4"
        SHARE_LINKS="$(gen_share_link $UUID $IPV4 $PORT $PBK $SNI $SHORTID "$NODE_NAME4")"
    elif [[ $HAS_IPV6 -eq 1 ]]; then
        NODE_NAME6="${COUNTRY6}-Reality-v6"
        generate_reality_config "::" $PORT $UUID $PRIKEY $SHORTID $SNI "$NODE_NAME6"
        SHARE_LINKS="$(gen_share_link $UUID "[$IPV6]" $PORT $PBK $SNI $SHORTID "$NODE_NAME6")"
    else
        echo "未检测到有效公网IP，退出。"
        exit 1
    fi

    install_systemd_service

    # 启动服务
    if [[ "$OS_RELEASE" == "alpine" ]]; then
        service sing-box restart
    else
        systemctl restart sing-box
    fi

    echo -e "\n配置完成，节点分享链接如下：\n${SHARE_LINKS}\n"
    echo -e "${SHARE_LINKS}" > ${SING_BOX_PATH}/share.txt

    # 优化TCP
    sysctl -w net.ipv4.tcp_fastopen=3

    echo -e "如需卸载只需要执行删除sing-box服务和 ${SING_BOX_PATH} 文件夹\n"
}

main
