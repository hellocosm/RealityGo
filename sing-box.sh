#!/bin/bash

SING_BOX_PATH="/etc/sing-box/"
SERVICE_FILE_PATH='/etc/systemd/system/sing-box.service'
SHARE_LINKS=""
NODE_NAME=""
# 设置 sing-box 的监听端口。注意：如果设置为 443，请确保服务器上没有其他服务占用此端口。
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
    # 查询国家 (请求中文名称)
    echo "正在获取 IPv4 对应的中文国家/地区名称..."
    COUNTRY4=$(curl -s4 https://ipapi.co/country_name?lang=zh 2>/dev/null)
    echo "正在获取 IPv6 对应的中文国家/地区名称..."
    COUNTRY6=$(curl -s6 https://ipapi.co/country_name?lang=zh 2>/dev/null)

    # 清理可能存在的引号
    COUNTRY4=$(echo "$COUNTRY4" | tr -d '"')
    COUNTRY6=$(echo "$COUNTRY6" | tr -d '"')

    # 默认国家名
    [ -z "$COUNTRY4" ] && COUNTRY4="未知"
    [ -z "$COUNTRY6" ] && COUNTRY6="未知"
    echo "IPv4 国家/地区: $COUNTRY4, IPv6 国家/地区: $COUNTRY6"
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
    echo "正在安装依赖..."
    case $OS_RELEASE in
        debian|ubuntu)
            apt update -qq >/dev/null
            apt install -y wget tar jq openssl curl -qq >/dev/null
            ;;
        centos)
            yum install -y wget tar jq openssl curl -q >/dev/null
            ;;
        alpine)
            apk update >/dev/null
            apk add wget tar jq openssl curl >/dev/null
            ;;
    esac
    echo "依赖安装完成。"
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
    chmod +x sing-box
    echo "sing-box 下载并解压完成。"
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
            "server_port": 443
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
    
    # 对节点名称进行URL编码以确保链接的有效性
    local encoded_node_name=""
    if command -v jq > /dev/null; then
        encoded_node_name=$(jq -nr --arg s "$node_name" '$s|@uri')
    else
        # 简易的URL编码，可能不完美处理所有特殊字符
        encoded_node_name=$(echo "$node_name" | sed 's| |%20|g; s|#|%23|g; s|&|%26|g; s|?|%3F|g; s|+|%2B|g; s|/|%2F|g; s|%|%25|g')
    fi
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
    echo "开始执行 sing-box Reality 节点安装脚本..."
    stop_singbox_if_running
    os_check
    arch_check
    install_base
    download_sing_box
    check_stack

    cd ${SING_BOX_PATH}
    echo "正在生成 Reality 相关密钥和ID..."
    KEYS=$(./sing-box generate reality-keypair)
    if [ $? -ne 0 ] || [ -z "$KEYS" ]; then
        echo "错误：生成 Reality 密钥对失败。请确保 sing-box 可执行且工作正常。"
        exit 1
    fi
    PRIKEY=$(echo "$KEYS" | grep 'PrivateKey' | awk '{print $2}')
    PBK=$(echo "$KEYS" | grep 'PublicKey' | awk '{print $2}')    
    
    if [ -z "$PRIKEY" ] || [ -z "$PBK" ]; then
        echo "错误：从输出中提取密钥失败。KEYS: $KEYS"
        exit 1
    fi

    UUID=$(./sing-box generate uuid)
    SHORTID=$(openssl rand -hex 8)
    echo "密钥和ID生成完毕。"

    SHARE_LINKS=""
    local node_name_v4=""
    local node_name_v6=""

    echo "正在配置节点信息..."
    if [[ $HAS_IPV4 -eq 1 && $HAS_IPV6 -eq 1 ]]; then
        node_name_v4="${COUNTRY4}-Reality-v4"
        node_name_v6="${COUNTRY6}-Reality-v6"
        generate_reality_config "::" $PORT $UUID $PRIKEY $SHORTID $SNI
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
        echo "错误：未检测到有效公网IP，退出。"
        exit 1
    fi
    echo "节点信息配置完成。"

    install_systemd_service

    echo "正在启动 sing-box 服务..."
    if [[ "$OS_RELEASE" == "alpine" ]]; then
        service sing-box restart
    else
        systemctl restart sing-box
    fi
    
    sleep 3 
    echo "检查 sing-box 服务状态..."
    if [[ "$OS_RELEASE" != "alpine" ]]; then
        if systemctl is-active --quiet sing-box; then
            echo "sing-box 服务正在运行。"
        else
            echo "警告：sing-box 服务未能成功启动。请检查日志："
            journalctl -u sing-box -n 50 --no-pager
        fi
    else
        if service sing-box status --quiet; then
            echo "sing-box 服务正在运行 (Alpine)。"
        else
            echo "警告：sing-box 服务未能成功启动 (Alpine)。请检查相关日志。"
        fi
    fi

    echo -e "\n配置完成，节点分享链接如下：\n${SHARE_LINKS}\n"
    echo -e "${SHARE_LINKS}" > ${SING_BOX_PATH}/share.txt

    if sysctl -w net.ipv4.tcp_fastopen=3 > /dev/null 2>&1; then
      echo "TCP Fast Open 已尝试启用。"
    else
      echo "提示：无法设置 TCP Fast Open (可能是权限或内核不支持)。"
    fi

    echo -e "\n如需卸载只需要执行以下命令停止并禁用服务，然后删除 ${SING_BOX_PATH} 文件夹:"
    if [[ "$OS_RELEASE" != "alpine" ]]; then
      echo "sudo systemctl stop sing-box"
      echo "sudo systemctl disable sing-box"
    else
      echo "sudo service sing-box stop"
      echo "sudo rc-update delete sing-box default"
    fi
    echo "sudo rm -rf ${SING_BOX_PATH}"
    echo -e "\n当前 sing-box 服务正在监听端口: ${PORT}"
    echo -e "Reality SNI 设置为: ${SNI}"
    echo -e "Reality Handshake 将连接 ${SNI} 的 443 端口。\n"
}

main
