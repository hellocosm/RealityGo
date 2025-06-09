#!/bin/bash

SING_BOX_PATH="/etc/sing-box/"
SERVICE_FILE_PATH='/etc/systemd/system/sing-box.service'
SHARE_LINKS=""
# 设置 sing-box 的监听端口。
PORT=12121
SNI="www.google.com" # 你可以根据需要更改SNI

# 全局变量存储IP信息, 国家/地区, 运营商, 服务器配置
IPV4=""
IPV6=""
COUNTRY4_NAME="未知"
COUNTRY6_NAME="未知"
ORG4="未知"
ORG6="未知"
HAS_IPV4=0
HAS_IPV6=0
SERVER_SPECS="未知配置"

# 检查 sing-box 是否在运行，若运行则停止
stop_singbox_if_running() {
    if pgrep -x "sing-box" > /dev/null; then
        echo "检测到 sing-box 正在运行，正在停止服务..."
        if systemctl stop sing-box; then
            echo "sing-box 服务已通过 systemctl 停止。"
        elif service sing-box stop; then
             echo "sing-box 服务已通过 service 停止。"
        else
            echo "尝试停止 sing-box 服务失败，可能需要手动干预。"
        fi
        sleep 2
    fi
}

# 获取本机公网IP地址
get_ip_addresses() {
    echo "正在获取本机公网IP地址..."
    IPV4=$(curl -s4m8 ip.sb || curl -s4m8 ifconfig.me || curl -s4m8 api.ip.fi)
    IPV6=$(curl -s6m8 ip.sb || curl -s6m8 ifconfig.me || curl -s6m8 api.ip.fi)

    [[ -n "$IPV4" && ! "$IPV4" =~ "error" && ! "$IPV4" =~ "limit" ]] && HAS_IPV4=1
    [[ -n "$IPV6" && ! "$IPV6" =~ "error" && ! "$IPV6" =~ "limit" ]] && HAS_IPV6=1

    if [[ $HAS_IPV4 -eq 1 ]]; then echo "  检测到 IPv4 地址: $IPV4"; fi
    if [[ $HAS_IPV6 -eq 1 ]]; then echo "  检测到 IPv6 地址: $IPV6"; fi
    if [[ $HAS_IPV4 -eq 0 && $HAS_IPV6 -eq 0 ]]; then
        echo "错误：未能获取到任何有效的公网IP地址。"
    fi
}

# 新增：本地翻译国家/地区名称到中文
translate_country_name_to_chinese() {
    local english_name="$1"
    local chinese_name="$english_name" # 默认为原始名称

    case "$english_name" in
        "United States") chinese_name="美国" ;;
        "Japan") chinese_name="日本" ;;
        "Hong Kong") chinese_name="香港" ;;
        "Singapore") chinese_name="新加坡" ;;
        "Germany") chinese_name="德国" ;;
        "United Kingdom") chinese_name="英国" ;;
        "South Korea") chinese_name="韩国" ;;
        "Canada") chinese_name="加拿大" ;;
        "Australia") chinese_name="澳大利亚" ;;
        "France") chinese_name="法国" ;;
        "Netherlands") chinese_name="荷兰" ;;
        "Taiwan") chinese_name="台湾" ;; # 根据实际需要和地区政策考虑是否添加
        # 在这里添加更多你需要的翻译，格式为："英文名") chinese_name="中文名" ;;
        *) chinese_name="$english_name" ;; # 如果没有匹配，则返回原始英文名
    esac
    echo "$chinese_name"
}

# 获取指定IP的详细信息 (国家/地区, 运营商)
fetch_ip_details() {
    local ip_address="$1"
    local ip_type="$2" # "v4" or "v6"
    local response_ipapi=""
    local response_ip_api_com=""
    local country_name_temp="未知"
    local org_temp="未知"

    if [ -z "$ip_address" ]; then return; fi

    echo "DEBUG: Fetching details for IP ($ip_address, type $ip_type)"

    # Try ipapi.co first
    echo "DEBUG: Querying ipapi.co for $ip_address (lang=zh)..."
    if [[ "$ip_type" == "v4" ]]; then
        response_ipapi=$(curl -sL4m8 "https://ipapi.co/${ip_address}/json/?lang=zh")
    else
        response_ipapi=$(curl -sL6m8 "https://ipapi.co/${ip_address}/json/?lang=zh")
    fi
    echo "DEBUG: Raw response from ipapi.co for $ip_address: $response_ipapi"

    if [ -n "$response_ipapi" ] && command -v jq > /dev/null; then
        country_name_temp=$(echo "$response_ipapi" | jq -r '.country_name // ""')
        org_temp=$(echo "$response_ipapi" | jq -r '.org // ""')
        echo "DEBUG: Parsed from ipapi.co: country_name='${country_name_temp}', org='${org_temp}'"
    fi

    if [[ -z "$response_ipapi" || -z "$country_name_temp" || "$country_name_temp" == "未知" || "$country_name_temp" == '""' ]]; then
        echo "DEBUG: ipapi.co failed or no valid country name. Querying ip-api.com for $ip_address (lang=zh-CN)..."
        if [[ "$ip_type" == "v4" ]]; then
            response_ip_api_com=$(curl -sL4m8 "http://ip-api.com/json/${ip_address}?lang=zh-CN&fields=status,message,country,org")
        else
            response_ip_api_com=$(curl -sL6m8 "http://ip-api.com/json/${ip_address}?lang=zh-CN&fields=status,message,country,org")
        fi
        echo "DEBUG: Raw response from ip-api.com for $ip_address: $response_ip_api_com"

        if [ -n "$response_ip_api_com" ] && command -v jq > /dev/null; then
            local status_ip_api_com=$(echo "$response_ip_api_com" | jq -r '.status // ""')
            if [[ "$status_ip_api_com" == "success" ]]; then
                local country_from_ip_api_com=$(echo "$response_ip_api_com" | jq -r '.country // ""')
                local org_from_ip_api_com=$(echo "$response_ip_api_com" | jq -r '.org // ""')
                
                if [[ -n "$country_from_ip_api_com" ]]; then
                     country_name_temp="$country_from_ip_api_com"
                fi
                if [[ (-z "$org_temp" || "$org_temp" == "未知" || "$org_temp" == '""') && -n "$org_from_ip_api_com" ]]; then
                    org_temp="$org_from_ip_api_com"
                fi
                echo "DEBUG: Parsed from ip-api.com: country_name='${country_name_temp}', org='${org_temp}'"
            else
                echo "DEBUG: ip-api.com query for $ip_address was not successful: $(echo "$response_ip_api_com" | jq -r '.message // ""')"
            fi
        fi
    fi
    
    [ -z "$country_name_temp" ] && country_name_temp="未知"
    [ -z "$org_temp" ] && org_temp="未知"

    # 调用本地翻译函数
    local translated_country_name=$(translate_country_name_to_chinese "$country_name_temp")
    echo "DEBUG: Original country name: '$country_name_temp', Translated country name: '$translated_country_name'"


    if [[ "$ip_type" == "v4" ]]; then
        COUNTRY4_NAME="$translated_country_name"
        ORG4="$org_temp"
    else
        COUNTRY6_NAME="$translated_country_name"
        ORG6="$org_temp"
    fi
    echo "  IP ($ip_address) FINAL Details: 国家/地区='$translated_country_name', 运营商='$org_temp'"
}

# 获取服务器配置 (CPU核心数, 内存GB)
get_server_specs() {
    echo "正在获取服务器硬件配置..."
    local cores=""
    local ram_gb=""

    if command -v nproc > /dev/null; then cores=$(nproc); else cores=$(grep -c '^processor' /proc/cpuinfo); fi
    [ -z "$cores" ] && cores="?"

    if command -v free > /dev/null && free -m &>/dev/null; then
        local mem_total_mb=$(free -m | awk '/^Mem:/{print $2}')
        if [ -n "$mem_total_mb" ] && [ "$mem_total_mb" -gt 0 ]; then
            if command -v bc > /dev/null; then
                 ram_gb=$(printf "%.0f" $(echo "scale=0; $mem_total_mb / 1024" | bc)) 
            else 
                 ram_gb=$((mem_total_mb / 1024)); [ "$ram_gb" -eq 0 ] && [ "$mem_total_mb" -gt 0 ] && ram_gb=1
            fi
        fi
    fi
    [ -z "$ram_gb" ] && ram_gb="?"
    
    SERVER_SPECS="${cores}H${ram_gb}G"
    echo "  服务器配置: $SERVER_SPECS"
}

# 根据运营商名称获取厂商代码
get_vendor_code() {
    local org_name="$1"
    local vendor_code="misc" 

    if [[ -z "$org_name" || "$org_name" == "未知" ]]; then
        echo "$vendor_code"
        return
    fi

    local lower_org_name=$(echo "$org_name" | tr '[:upper:]' '[:lower:]')

    if [[ "$lower_org_name" == "as-colocrossing" || "$lower_org_name" == "colocrossing" ]]; then
        vendor_code="colocrossing" 
        echo "$vendor_code"
        return
    fi
    
    if [[ "$lower_org_name" == *"alibaba"* || "$lower_org_name" == *"aliyun"* ]]; then vendor_code="ali"
    elif [[ "$lower_org_name" == *"google"* && ("$lower_org_name" == *"cloud"* || "$lower_org_name" == *"llc"*) ]]; then vendor_code="gcp"
    elif [[ "$lower_org_name" == *"amazon"* && ("$lower_org_name" == *"aws"* || "$lower_org_name" == *"data services"*) ]]; then vendor_code="aws"
    elif [[ "$lower_org_name" == *"oracle"* && "$lower_org_name" == *"cloud"* ]]; then vendor_code="oci"
    elif [[ "$lower_org_name" == *"microsoft"* && "$lower_org_name" == *"azure"* ]]; then vendor_code="azure"
    elif [[ "$lower_org_name" == *"tencent"* ]]; then vendor_code="tencent"
    elif [[ "$lower_org_name" == *"digitalocean"* ]]; then vendor_code="do"
    elif [[ "$lower_org_name" == *"vultr"* || "$lower_org_name" == *"choopa"* ]]; then vendor_code="vultr"
    elif [[ "$lower_org_name" == *"linode"* ]]; then vendor_code="linode"
    elif [[ "$lower_org_name" == *"ovh"* ]]; then vendor_code="ovh"
    elif [[ "$lower_org_name" == *"hetzner"* ]]; then vendor_code="hetzner"
    elif [[ "$lower_org_name" == *"contabo"* ]]; then vendor_code="contabo"
    elif [[ "$lower_org_name" == *"m247"* ]]; then vendor_code="m247"
    elif [[ "$lower_org_name" == *"cogent"* ]]; then vendor_code="cogent"
    elif [[ "$lower_org_name" == *"cloudflare"* ]]; then vendor_code="cf"
    else 
        if [[ "$lower_org_name" =~ ^as[0-9]+[[:space:]]*(.*) ]]; then 
            local potential_code=$(echo "${BASH_REMATCH[1]}" | sed 's/[^a-z0-9]//g' | cut -c1-12) 
            if [[ -n "$potential_code" ]]; then vendor_code="$potential_code"; else
                vendor_code=$(echo "$lower_org_name" | sed -n 's/^\(as[0-9]\+\).*/\1/p' | sed 's/[^a-z0-9]//g' | cut -c1-10)
                [ -z "$vendor_code" ] && vendor_code="misc"
            fi
        else
            vendor_code=$(echo "$lower_org_name" | sed 's/[^a-z0-9]//g' | cut -c1-10) 
            [ -z "$vendor_code" ] && vendor_code="misc"
        fi
    fi
    
    echo "$vendor_code"
}

# 系统检测
os_check() {
    if [[ -f /etc/redhat-release ]]; then OS_RELEASE="alpine"
    elif grep -Eqi "debian" /etc/issue /proc/version 2>/dev/null; then OS_RELEASE="alpine"
    elif grep -Eqi "ubuntu" /etc/issue /proc/version 2>/dev/null; then OS_RELEASE="alpine"
    elif grep -Eqi "alpine" /etc/issue 2>/dev/null; then OS_RELEASE="alpine"
    else echo "不支持的系统" && exit 1; fi
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

# 安装依赖 (已加入 jq 和 bc)
install_base() {
    echo "正在安装依赖 (wget, tar, jq, openssl, curl, bc)..."
    local packages="wget tar jq openssl curl bc"
    case $OS_RELEASE in
        debian|ubuntu)
            apt-get update -qq >/dev/null
            apt-get install -y $packages -qq >/dev/null
            ;;
        centos)
            yum install -y epel-release -q >/dev/null 
            yum install -y $packages -q >/dev/null
            ;;
        alpine)
            apk update >/dev/null
            apk add $packages >/dev/null
            ;;
    esac
    if ! command -v jq > /dev/null; then
        echo "警告: jq 工具未能成功安装，运营商和国家/地区信息可能无法准确获取。"
    fi
    echo "依赖安装完成。"
}

# 下载 sing-box
download_sing_box() {
    local latest_version=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep 'tag_name' | head -1 | awk -F '"' '{print $4}')
    [ -z "$latest_version" ] && latest_version="v1.9.0" 
    local version_num=${latest_version#v}
    local url="https://github.com/SagerNet/sing-box/releases/download/${latest_version}/sing-box-${version_num}-linux-${OS_ARCH}.tar.gz"

    mkdir -p ${SING_BOX_PATH} && cd ${SING_BOX_PATH} || { echo "无法创建或进入 ${SING_BOX_PATH}"; exit 1; }
    echo "正在下载 sing-box ${latest_version} for ${OS_ARCH}..."
    wget -q --no-check-certificate -O sing-box.tar.gz "$url"
    if [ $? -ne 0 ]; then echo "下载 sing-box 失败，请检查网络或URL: $url" && exit 1; fi
    tar -xzf sing-box.tar.gz
    rm -f sing-box.tar.gz
    mv sing-box-${version_num}-linux-${OS_ARCH}/* .
    rm -rf sing-box-${version_num}-linux-${OS_ARCH}
    chmod +x sing-box
    echo "sing-box 下载并解压完成。"
}

# 生成 Reality 节点配置
generate_reality_config() {
    local listen_port="$1" 
    local uuid="$2"
    local prikey="$3"
    local shortid="$4"
    local sni="$5"

    cat > "${SING_BOX_PATH}/config.json" <<EOF
{
  "log": {
    "level": "info", 
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
    local uuid="$1"; local ip="$2"; local port="$3"; local pbk="$4"; local sni="$5"; local shortid="$6"; local node_name="$7"
    local encoded_node_name=""
    if command -v jq > /dev/null; then
        encoded_node_name=$(jq -nr --arg s "$node_name" '$s|@uri')
    else 
        encoded_node_name=$(echo "$node_name" | sed 's| |%20|g; s|#|%23|g; s|&|%26|g; s|?|%3F|g; s|+|%2B|g; s|/|%2F|g; s|%|%25|g')
    fi
    echo "vless://${uuid}@${ip}:${port}?security=reality&encryption=none&pbk=${pbk}&headerType=none&fp=chrome&type=tcp&sni=${sni}&sid=${shortid}&flow=xtls-rprx-vision#${encoded_node_name}"
}

# 安装 systemd 服务
install_systemd_service() {
    echo "正在安装/更新 systemd 服务..."
    if [[ "$OS_RELEASE" == "alpine" ]]; then 
        SERVICE_FILE_PATH="/etc/init.d/sing-box"
        if [[ -f "$SERVICE_FILE_PATH" ]]; then rm -f "$SERVICE_FILE_PATH"; fi
        cat > "$SERVICE_FILE_PATH" <<EOF
#!/sbin/openrc-run
name="sing-box"
description="Sing-Box Service"
supervisor="supervise-daemon"
command="${SING_BOX_PATH}sing-box"
command_args="run -c ${SING_BOX_PATH}config.json" 
command_user="root:root"
pidfile="/run/\${RC_SVCNAME}.pid" 

depend() { 
  after net dns
  use net
}
EOF
        chmod +x "$SERVICE_FILE_PATH"
        rc-update add sing-box default
    else 
        if [[ -f "$SERVICE_FILE_PATH" ]]; then rm -f "$SERVICE_FILE_PATH"; fi
        cat > "$SERVICE_FILE_PATH" <<EOF
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
        chmod +x "$SERVICE_FILE_PATH"
        
        mkdir -p /etc/systemd/system/sing-box.service.d
        echo -e "[Service]\nCPUSchedulingPolicy=rr\nCPUSchedulingPriority=99" > /etc/systemd/system/sing-box.service.d/priority.conf
        
        systemctl daemon-reload
        systemctl enable sing-box
    fi
    echo "systemd 服务安装/更新完成。"
}

# --- 主流程 ---
main() {
    echo "开始执行 sing-box Reality 节点安装脚本 (版本包含厂商和配置)..."
    stop_singbox_if_running
    os_check
    arch_check
    install_base 
    
    get_ip_addresses 
    if [[ $HAS_IPV4 -eq 1 ]]; then fetch_ip_details "$IPV4" "v4"; fi
    if [[ $HAS_IPV6 -eq 1 ]]; then fetch_ip_details "$IPV6" "v6"; fi
    get_server_specs 

    download_sing_box 
    
    cd "${SING_BOX_PATH}" || { echo "错误: 无法进入 ${SING_BOX_PATH}"; exit 1; }
    echo "正在生成 Reality 相关密钥和ID..."
    if [[ ! -x "sing-box" ]]; then echo "错误: ${SING_BOX_PATH}sing-box 不存在或不可执行。" && exit 1; fi
    
    KEYS=$(./sing-box generate reality-keypair)
    if [ $? -ne 0 ] || [ -z "$KEYS" ]; then echo "错误：生成 Reality 密钥对失败。" && exit 1; fi
    PRIKEY=$(echo "$KEYS" | grep 'PrivateKey:' | awk '{print $2}') 
    PBK=$(echo "$KEYS" | grep 'PublicKey:' | awk '{print $2}')    
    if [ -z "$PRIKEY" ] || [ -z "$PBK" ]; then echo "错误：从输出中提取密钥失败。KEYS: $KEYS" && exit 1; fi
    
    UUID=$(./sing-box generate uuid)
    SHORTID=$(openssl rand -hex 8)
    echo "密钥和ID生成完毕。"

    SHARE_LINKS=""
    local node_name_v4=""
    local node_name_v6=""
    local vendor_code_final="unknown" 

    if [[ $HAS_IPV4 -eq 1 && "$ORG4" != "未知" ]]; then
        vendor_code_final=$(get_vendor_code "$ORG4")
    elif [[ $HAS_IPV6 -eq 1 && "$ORG6" != "未知" ]]; then
        vendor_code_final=$(get_vendor_code "$ORG6")
    elif [[ $HAS_IPV4 -eq 1 ]]; then 
        vendor_code_final=$(get_vendor_code "$ORG4") 
    elif [[ $HAS_IPV6 -eq 1 ]]; then
        vendor_code_final=$(get_vendor_code "$ORG6")
    fi

    echo "正在配置节点信息 (使用厂商代码: $vendor_code_final)..."
    generate_reality_config "$PORT" "$UUID" "$PRIKEY" "$SHORTID" "$SNI"

    if [[ $HAS_IPV4 -eq 1 ]]; then
        node_name_v4="${COUNTRY4_NAME}-${SERVER_SPECS}-Reality-v4-${vendor_code_final}"
        SHARE_LINKS+="$(gen_share_link "$UUID" "$IPV4" "$PORT" "$PBK" "$SNI" "$SHORTID" "$node_name_v4")\n"
    fi
    if [[ $HAS_IPV6 -eq 1 ]]; then
        node_name_v6="${COUNTRY6_NAME}-${SERVER_SPECS}-Reality-v6-${vendor_code_final}" 
        SHARE_LINKS+="$(gen_share_link "$UUID" "[$IPV6]" "$PORT" "$PBK" "$SNI" "$SHORTID" "$node_name_v6")\n"
    fi
    SHARE_LINKS=$(echo -e "$SHARE_LINKS" | sed '/^$/d') 

    echo "节点信息配置完成。"
    install_systemd_service

    echo "正在启动 sing-box 服务..."
    if [[ "$OS_RELEASE" == "alpine" ]]; then 
        if service sing-box restart; then echo "sing-box 服务 (Alpine) 已尝试重启。"; else echo "错误：尝试重启 sing-box 服务 (Alpine) 失败。"; fi
    else 
        if systemctl restart sing-box; then echo "sing-box 服务 (systemd) 已尝试重启。"; else echo "错误：尝试重启 sing-box 服务 (systemd) 失败。"; fi
    fi
    
    sleep 3 
    echo "检查 sing-box 服务状态..."
    if [[ "$OS_RELEASE" != "alpine" ]]; then
        if systemctl is-active --quiet sing-box; then echo "sing-box 服务正在运行。"
        else echo -e "\n警告：sing-box 服务未能成功启动。请检查日志："; systemctl status sing-box --no-pager -l; journalctl -u sing-box -n 50 --no-pager; fi
    else
        if pgrep -x "sing-box" > /dev/null; then echo "sing-box 服务正在运行 (Alpine - pgrep check)."
        else echo -e "\n警告：sing-box 服务未能成功启动 (Alpine)。请检查相关日志，通常在 /var/log/"; service sing-box status; fi
    fi

    echo -e "\n配置完成，节点分享链接如下：\n${SHARE_LINKS}\n"
    echo -e "${SHARE_LINKS}" > "${SING_BOX_PATH}/share.txt"

    if sysctl -w net.ipv4.tcp_fastopen=3 > /dev/null 2>&1; then echo "TCP Fast Open 已尝试启用。"
    else echo "提示：无法设置 TCP Fast Open (可能是权限或内核不支持)。"; fi

    echo -e "\n如需卸载只需要执行以下命令停止并禁用服务，然后删除 ${SING_BOX_PATH} 文件夹:"
    if [[ "$OS_RELEASE" != "alpine" ]]; then echo "sudo systemctl stop sing-box; sudo systemctl disable sing-box"
    else echo "sudo service sing-box stop; sudo rc-update delete sing-box default"; fi
    echo "sudo rm -rf ${SING_BOX_PATH}"
    echo -e "\n当前 sing-box 服务正在监听端口: ${PORT}"
    echo -e "Reality SNI 设置为: ${SNI}"
    echo -e "Reality Handshake 将连接 ${SNI} 的 443 端口。\n"
}

# ---- 执行主函数 ----
main
