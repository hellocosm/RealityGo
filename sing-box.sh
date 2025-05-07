#!/bin/bash

SING_BOX_PATH="/etc/sing-box/"
SERVICE_FILE_PATH='/etc/systemd/system/sing-box.service'
IP=$(curl -s ip.sb)
[ -z "$(echo ${IP} | grep ':')" ] || IP="[$IP]"

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
            apt install -y wget tar jq openssl
            ;;
        centos)
            yum install -y wget tar jq openssl
            ;;
        alpine)
            apk update
            apk add wget tar jq openssl
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

# 生成配置文件
generate_config() {
    cd ${SING_BOX_PATH}
    # 生成UUID
    UUID=$(./sing-box generate uuid)
    # 生成Reality密钥对（修复换行问题）
    KEYS=$(./sing-box generate reality-keypair)
    PRIKEY=$(echo "$KEYS" | grep PrivateKey | awk '{print $2}')
    PBK=$(echo "$KEYS" | grep PublicKey | awk '{print $2}')
    # 生成ShortID
    SHORTID=$(openssl rand -hex 8)
    # 默认端口和SNI
    PORT=8443
    SNI="global.fujifilm.com"

    cat > config.json <<EOF
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
      "listen_port": ${PORT},
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
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "alpn": ["h2","http/1.1"],
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${SNI}",
            "server_port": 8443
          },
          "private_key": "${PRIKEY}",
          "short_id": ["${SHORTID}"]
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

    # 生成分享链接
    SHARE_LINK="Reality: vless://${UUID}@${IP}:${PORT}?security=reality&encryption=none&pbk=${PBK}&headerType=none&fp=chrome&type=tcp&sni=${SNI}&sid=${SHORTID}&flow=xtls-rprx-vision#Reality"
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
        service sing-box start
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
        systemctl start sing-box
    fi
}

# 主流程
main() {
    os_check
    arch_check
    install_base
    download_sing_box
    generate_config
    install_systemd_service

    echo -e "\n配置完成，分享链接如下：\n${SHARE_LINK}\n"
    echo -e "${SHARE_LINK}" > ${SING_BOX_PATH}/share.txt

    # 优化TCP
    sysctl -w net.ipv4.tcp_fastopen=3
}

main
