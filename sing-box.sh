#!/bin/bash

SING_BOX_PATH="/etc/sing-box/"
SERVICE_FILE_PATH='/etc/systemd/system/sing-box.service'
SHARE_LINKS=""
NODE_NAME=""
# 设置 sing-box 的监听端口。注意：如果设置为 443，请确保服务器上没有其他服务占用此端口。
PORT=8443
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
    [ -z "$latest_version" ] && latest_version="v1.9.0" # 请根据实际情况更新默认版本
    local version_num=${latest_version#v}
    local url="https://github.com/SagerNet/sing-box/releases/download/${latest_version}/sing-box-${version_num}-linux-${OS_ARCH}.tar.gz"

    mkdir -p ${SING_BOX_PATH}
    cd ${SING_BOX_PATH}
    echo "正在下载 sing-box ${latest_version} for ${OS_ARCH}..."
    wget -q --no-check-certificate -O sing-box.tar.gz $url
    if [ $? -ne 0 ]; then
        echo "下载 sing-box 失败，请检查网络或URL。"
        exit 1
    fi
    tar -xzf sing-box.tar.gz
    rm -f sing-box.tar.gz
    mv sing-box-${version_num}-linux-${OS_ARCH}/* .
    rm -rf sing-box-${version_num}-linux-${OS_ARCH}
    echo "sing-box 下载并解压完成。"
}

# 生成 Reality 节点配置
generate_reality_config() {
    local listen_ip="$1" # 此参数在当前配置中未直接使用，listen硬编码为"::"
    local listen_port="$2"
    local uuid="$3"
    local prikey="$4"
    local shortid="$5"
    local sni="$6"
    local node_name="$7" # 此参数也未在config.json内部使用

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
            "server_port": 443 # Reality握手连接SNI目标服务器的443端口
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
    # URL编码节点名称中的特殊字符，特别是'#'。 '#'本身不应该被编码，因为它分隔URI和片段。
    # 但节点名称本身可能包含需要编码的字符。更安全的做法是确保节点名称不含特殊URI字符或对其进行编码。
    # Bash中进行完全的URL编码比较复杂，这里假设节点名主要为字母数字和'-'。
    local encoded_node_name=$(echo "$node_name" | sed 's| |%20|g' | sed 's|#|%23|g') # 简单处理空格和#
    echo "vless://${uuid}@${ip}:${port}?security=reality&encryption=none&pbk=${pbk}&headerType=none&fp=chrome&type=tcp&sni=${sni}&sid=${shortid}&flow=xtls-rprx-vision#${encoded_node_name}"
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
        rc-update add sing-box default
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
        # Alpine 不使用 systemd.service.d
        if [[ "$OS_RELEASE" != "alpine" ]]; then
            mkdir -p /etc/systemd/system/sing-box.service.d
            echo -e "[Service]\nCPUSchedulingPolicy=rr\nCPUSchedulingPriority=99" > /etc/systemd/system/sing-box.service.d/priority.conf
        fi
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
    # 生成 Reality 密钥对
    echo "正在生成 Reality 密钥对..."
    KEYS=$(./sing-box generate reality-keypair)
    if [ $? -ne 0 ] || [ -z "$KEYS" ]; then
        echo "生成 Reality 密钥对失败。请确保 sing-box 可执行且工作正常。"
        exit 1
    fi
    PRIKEY=$(echo "$KEYS" | grep 'PrivateKey' | awk '{print $2}') # 调整grep以精确匹配
    PBK=$(echo "$KEYS" | grep 'PublicKey' | awk '{print $2}')    # 调整grep以精确匹配
    
    if [ -z "$PRIKEY" ] || [ -z "$PBK" ]; then
        echo "从输出中提取密钥失败。KEYS: $KEYS"
        exit 1
    fi

    UUID=$(./sing-box generate uuid)
    SHORTID=$(openssl rand -hex 8)

    SHARE_LINKS=""
    local node_name_v4=""
    local node_name_v6=""

    # 生成节点名和节点
    if [[ $HAS_IPV4 -eq 1 && $HAS_IPV6 -eq 1 ]]; then
        # 双栈
        node_name_v4="${COUNTRY4}-Reality-v4"
        node_name_v6="${COUNTRY6}-Reality-v6"
        generate_reality_config "::" $PORT $UUID $PRIKEY $SHORTID $SNI # 配置使用同一个，监听::
        SHARE_LINKS="$(gen_share_link $UUID $IPV4 $PORT $PBK $SNI $SHORTID "$node_name_v4")"
        SHARE_LINKS="${SHARE_LINKS}\n$(gen_share_link $UUID "[$IPV6]" $PORT $PBK $SNI $SHORTID "$node_name_v6")"
    elif [[ $HAS_IPV4 -eq 1 ]]; then
        node_name_v4="${COUNTRY4}-Reality-v4"
        generate_reality_config "::" $PORT $UUID $PRIKEY $SHORTID $SNI
        SHARE_LINKS="$(gen_share_link $UUID $IPV4 $PORT $PBK $SNI $SHORTID "$node_name_v4")"
    elif [[ $HAS_IPV6 -eq 1 ]]; then
        node_name_v6="${COUNTRY6}-Reality-v6"
        generate_reality_config "::" $PORT $UUID $PRIKEY $SHORTID $SNI
        SHARE_LINKS="$(gen_share_link $UUID "[$IPV6]" $PORT $PBK $SNI $SHORTID "$node_name_v6")"
    else
        echo "未检测到有效公网IP，退出。"
        exit 1
    fi

    install_systemd_service

    # 启动服务
    echo "正在启动 sing-box 服务..."
    if [[ "$OS_RELEASE" == "alpine" ]]; then
        service sing-box restart
    else
        systemctl restart sing-box
    fi
    
    # 检查服务状态，可选
    sleep 3 # 等待服务启动
    if [[ "$OS_RELEASE" != "alpine" ]]; then
        systemctl status sing-box --no-pager -l
    else
        service sing-box status
    fi


    echo -e "\n配置完成，节点分享链接如下：\n${SHARE_LINKS}\n"
    echo -e "${SHARE_LINKS}" > ${SING_BOX_PATH}/share.txt

    # 优化TCP
    if sysctl -w net.ipv4.tcp_fastopen=3 > /dev/null 2>&1; then
      echo "TCP Fast Open 已尝试启用。"
    else
      echo "警告：无法设置 TCP Fast Open。"
    fi


    echo -e "如需卸载只需要执行删除sing-box服务和 ${SING_BOX_PATH} 文件夹\n"
    echo -e "sing-box 服务正在监听端口: ${PORT}"
    echo -e "Reality SNI 设置为: ${SNI}"
    echo -e "Reality Handshake 将连接 ${SNI} 的 443 端口。"
}

main
