#!/bin/bash

SING_BOX_PATH="/etc/sing-box/"
SERVICE_FILE_PATH='/etc/systemd/system/sing-box.service'
SHARE_LINKS=""
# 设置 sing-box 的监听端口。
PORT=12121
SNI="global.fujifilm.com" # 你可以根据需要更改SNI

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
        systemctl stop sing-box || service sing-box stop
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
        exit 1
    fi
}

# 获取指定IP的详细信息 (国家/地区, 运营商)
fetch_ip_details() {
    local ip_address="$1"
    local ip_type="$2" # "v4" or "v6"
    local response=""
    local country_name_temp=""
    local org_temp=""

    if [ -z "$ip_address" ]; then return; fi

    echo "正在获取 IP ($ip_address, 类型 $ip_type) 的详细信息 (国家/地区, 运营商)..."
    # 优先使用 https://ipapi.co/IP/json/?lang=zh
    # 增加超时和备用API (简化处理，实际中可能需要更复杂的逻辑)
    if [[ "$ip_type" == "v4" ]]; then
        response=$(curl -sL4m8 "https://ipapi.co/${ip_address}/json/?lang=zh" || curl -sL4m8 "http://ip-api.com/json/${ip_address}?lang=zh-CN&fields=country,org")
    else
        response=$(curl -sL6m8 "https://ipapi.co/${ip_address}/json/?lang=zh" || curl -sL6m8 "http://ip-api.com/json/${ip_address}?lang=zh-CN&fields=country,org")
    fi

    if [ -n "$response" ] && command -v jq > /dev/null; then
        # 尝试解析 ipapi.co 的格式
        country_name_temp=$(echo "$response" | jq -r '.country_name // empty')
        org_temp=$(echo "$response" | jq -r '.org // empty')

        # 如果上面为空，尝试解析 ip-api.com 的格式
        if [ -z "$country_name_temp" ] && [ -z "$org_temp" ]; then
            country_name_temp=$(echo "$response" | jq -r '.country // empty')
            org_temp=$(echo "$response" | jq -r '.org // empty')
        fi
        
        country_name_temp=$(echo "$country_name_temp" | tr -d '"') # 清理引号
        org_temp=$(echo "$org_temp" | tr -d '"')

        if [[ "$ip_type" == "v4" ]]; then
            COUNTRY4_NAME=${country_name_temp:-"未知"}
            ORG4=${org_temp:-"未知"}
        else
            COUNTRY6_NAME=${country_name_temp:-"未知"}
            ORG6=${org_temp:-"未知"}
        fi
        echo "  IP ($ip_address) 信息: 国家/地区='${country_name_temp:-"N/A"}', 运营商='${org_temp:-"N/A"}'"
    else
        echo "  未能获取 IP ($ip_address) 的详细信息或 jq 工具未安装。"
         if [[ "$ip_type" == "v4" ]]; then COUNTRY4_NAME="未知"; ORG4="未知"; else COUNTRY6_NAME="未知"; ORG6="未知"; fi
    fi
}

# 获取服务器配置 (CPU核心数, 内存GB)
get_server_specs() {
    echo "正在获取服务器硬件配置..."
    local cores=""
    local ram_gb=""

    # 获取CPU核心数
    if command -v nproc > /dev/null; then
        cores=$(nproc)
    else
        cores=$(grep -c '^processor' /proc/cpuinfo)
    fi
    [ -z "$cores" ] && cores="?"

    # 获取内存大小 (GB), 四舍五入到整数
    if command -v free > /dev/null && free -m &>/dev/null; then
        local mem_total_mb=$(free -m | awk '/^Mem:/{print $2}')
        if [ -n "$mem_total_mb" ] && [ "$mem_total_mb" -gt 0 ]; then
            if command -v bc > /dev/null; then
                 ram_gb=$(printf "%.0f" $(echo "$mem_total_mb / 1024" | bc -l))
            else # 简易整数除法，向下取整
                 ram_gb=$((mem_total_mb / 1024))
                 [ "$ram_gb" -eq 0 ] && [ "$mem_total_mb" -gt 0 ] && ram_gb=1 # 至少显示1GB如果内存小于1024MB但大于0
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
    local vendor_code=""

    # 将标准化的ORG Name转换为小写以便匹配
    local lower_org_name=$(echo "$org_name" | tr '[:upper:]' '[:lower:]')

    # --- 用户自定义厂商代码映射 ---
    # 请在此处添加您自定义的厂商名称关键字到特定代码的映射
    # 格式: if [[ "$lower_org_name" == *"关键字"* ]]; then vendor_code="您的代码"; echo "$vendor_code"; return; fi
    # 示例 (请根据您的实际运营商名称中的关键字修改):
    # if [[ "$lower_org_name" == *"specific provider name for yxvm"* ]]; then vendor_code="yxvm"; echo "$vendor_code"; return; fi
    # if [[ "$lower_org_name" == *"优选"* && "$lower_org_name" == *"vps"* ]]; then vendor_code="yxvm"; echo "$vendor_code"; return; fi # 示例: 如果运营商包含"优选"和"vps"
    
    # --- 常见云服务商映射 ---
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
    elif [[ "$lower_org_name" == *"m247"* ]]; then vendor_code="m247" # E.g. M247 Ltd
    elif [[ "$lower_org_name" == *"cogent"* ]]; then vendor_code="cogent"
    elif [[ "$lower_org_name" == *"cloudflare"* ]]; then vendor_code="cf"
    # 如果没有匹配到以上任何一个，则尝试从ORG名称生成一个通用代码
    else
        # 移除非字母数字字符，取前4位，如果为空则默认为"misc"
        vendor_code=$(echo "$lower_org_name" | sed 's/[^a-z0-9]//g' | cut -c1-4)
        [ -z "$vendor_code" ] && vendor_code="misc"
    fi
    
    echo "$vendor_code"
}


# 系统检测
os_check() {
    if [[ -f /etc/redhat-release ]]; then OS_RELEASE="centos"
    elif grep -Eqi "debian" /etc/issue /proc/version 2>/dev/null; then OS_RELEASE="debian"
    elif grep -Eqi "ubuntu" /etc/issue /proc/version 2>/dev/null; then OS_RELEASE="ubuntu"
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
            apt update -qq >/dev/null
            apt install -y $packages -qq >/dev/null
            ;;
        centos)
            yum install -y epel-release # bc可能在epel
            yum install -y $packages -q >/dev/null
            ;;
        alpine)
            apk update >/dev/null
            apk add $packages >/dev/null
            ;;
    esac
    if ! command -v jq > /dev/null; then
        echo "警告: jq 工具未能成功安装，运营商信息可能无法获取。"
    fi
    echo "依赖安装完成。"
}

# 下载 sing-box (与之前版本相同)
download_sing_box() {
    local latest_version=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep 'tag_name' | head -1 | awk -F '"' '{print $4}')
    [ -z "$latest_version" ] && latest_version="v1.9.0" # 如果获取失败，使用的默认版本号
    local version_num=${latest_version#v}
    local url="https://github.com/SagerNet/sing-box/releases/download/${latest_version}/sing-box-${version_num}-linux-${OS_ARCH}.tar.gz"

    mkdir -p ${SING_BOX_PATH}
    cd ${SING_BOX_PATH}
    echo "正在下载 sing-box ${latest_version} for ${OS_ARCH}..."
    wget -q --no-check-certificate -O sing-box.tar.gz $url
    if [ $? -ne 0 ]; then
        echo "下载 sing-box 失败，请检查网络或URL: $url"
        exit 1
    fi
    tar -xzf sing-box.tar.gz
    rm -f sing-box.tar.gz
    mv sing-box-${version_num}-linux-${OS_ARCH}/* .
    rm -rf sing-box-${version_num}-linux-${OS_ARCH}
    chmod +x sing-box
    echo "sing-box 下载并解压完成。"
}

# 生成 Reality 节点配置 (与之前版本相同)
generate_reality_config() {
    local listen_port="$1" # listen_ip 参数不再需要，因为 listen: "::"
    local uuid="$2"
    local prikey="$3"
    local shortid="$4"
    local sni="$5"
    # node_name 参数在 config.json 中不使用

    cat > ${SING_BOX_PATH}/config.json <<EOF
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
      "multiplex": {"enabled": true, "padding": true, "brutal": {"enabled": true, "up_mbps": 1000, "down_mbps": 1000}},
      "tcp_multi_path": true,
      "users": [{"uuid": "${uuid}", "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": true, "server_name": "${sni}", "alpn": ["h2","http/1.1"],
        "reality": {
          "enabled": true,
          "handshake": {"server": "${sni}", "server_port": 443},
          "private_key": "${prikey}", "short_id": ["${shortid}"]
        }
      }
    }
  ],
  "outbounds": [{"type": "direct", "tag": "direct", "domain_strategy": "prefer_ipv4"}]
}
EOF
}

# 生成 Reality 分享链接 (与之前版本类似，确保编码)
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

# 安装 systemd 服务 (与之前版本相同)
install_systemd_service() {
    if [[ "$OS_RELEASE" == "alpine" ]]; then SERVICE_FILE_PATH="/etc/init.d/sing-box"; fi
    if [[ -f "$SERVICE_FILE_PATH" ]]; then rm -f "$SERVICE_FILE_PATH"; fi

    if [[ "$OS_RELEASE" == "alpine" ]]; then
        cat > $SERVICE_FILE_PATH <<EOF
#!/sbin/openrc-run
name="sing-box"; description="Sing-Box Service"; supervisor="supervise-daemon"
command="${SING_BOX_PATH}sing-box run"; command_args="-c ${SING_BOX_PATH}config.json"; command_user="root:root"
depend() { after net dns; use net; }
EOF
        chmod +x $SERVICE_FILE_PATH; rc-update add sing-box default
    else
        cat > $SERVICE_FILE_PATH <<EOF
[Unit]
Description=sing-box Service; Documentation=https://sing-box.sagernet.org/; After=network.target nss-lookup.target; Wants=network.target
[Service]
Type=simple; ExecStart=${SING_BOX_PATH}sing-box run -c ${SING_BOX_PATH}config.json
Restart=on-failure; RestartSec=30s; RestartPreventExitStatus=23; LimitNPROC=10000; LimitNOFILE=1000000
[Install]
WantedBy=multi-user.target
EOF
        chmod +x $SERVICE_FILE_PATH
        if [[ "$OS_RELEASE" != "alpine" ]]; then
            mkdir -p /etc/systemd/system/sing-box.service.d
            echo -e "[Service]\nCPUSchedulingPolicy=rr\nCPUSchedulingPriority=99" > /etc/systemd/system/sing-box.service.d/priority.conf
        fi
        systemctl daemon-reload; systemctl enable sing-box
    fi
}

# --- 主流程 ---
main() {
    echo "开始执行 sing-box Reality 节点安装脚本 (版本包含厂商和配置)..."
    stop_singbox_if_running
    os_check
    arch_check
    install_base # 确保 jq, bc 已安装
    
    get_ip_addresses # 获取公网IP
    if [[ $HAS_IPV4 -eq 1 ]]; then fetch_ip_details "$IPV4" "v4"; fi
    if [[ $HAS_IPV6 -eq 1 ]]; then fetch_ip_details "$IPV6" "v6"; fi
    get_server_specs # 获取服务器配置 H G

    download_sing_box # 下载 sing-box
    
    cd ${SING_BOX_PATH}
    echo "正在生成 Reality 相关密钥和ID..."
    if [[ ! -x "${SING_BOX_PATH}sing-box" ]]; then echo "错误: ${SING_BOX_PATH}sing-box 不存在或不可执行。" && exit 1; fi
    KEYS=$(./sing-box generate reality-keypair)
    if [ $? -ne 0 ] || [ -z "$KEYS" ]; then echo "错误：生成 Reality 密钥对失败。" && exit 1; fi
    PRIKEY=$(echo "$KEYS" | grep 'PrivateKey' | awk '{print $2}')
    PBK=$(echo "$KEYS" | grep 'PublicKey' | awk '{print $2}')    
    if [ -z "$PRIKEY" ] || [ -z "$PBK" ]; then echo "错误：从输出中提取密钥失败。KEYS: $KEYS" && exit 1; fi
    UUID=$(./sing-box generate uuid); SHORTID=$(openssl rand -hex 8)
    echo "密钥和ID生成完毕。"

    SHARE_LINKS=""
    local node_name_v4=""
    local node_name_v6=""
    local vendor_code_final="unknown" # 默认厂商代码

    # 确定一个最终的厂商代码 (如果v4和v6的ORG不同，优先使用IPv4的，或更复杂的逻辑)
    if [[ $HAS_IPV4 -eq 1 && -n "$ORG4" && "$ORG4" != "未知" ]]; then
        vendor_code_final=$(get_vendor_code "$ORG4")
    elif [[ $HAS_IPV6 -eq 1 && -n "$ORG6" && "$ORG6" != "未知" ]]; then
        vendor_code_final=$(get_vendor_code "$ORG6")
    fi
    # 如果用户在 get_vendor_code 中为 "yxvm" 等特定代码设置了基于特定 ORG 的判断，这里会得到那个代码

    echo "正在配置节点信息 (使用厂商代码: $vendor_code_final)..."
    # 生成配置文件 (只需要一次，因为它监听所有IP "::")
    generate_reality_config $PORT $UUID $PRIKEY $SHORTID $SNI

    if [[ $HAS_IPV4 -eq 1 ]]; then
        node_name_v4="${COUNTRY4_NAME}-${SERVER_SPECS}-Reality-v4-${vendor_code_final}"
        SHARE_LINKS+="$(gen_share_link $UUID $IPV4 $PORT $PBK $SNI $SHORTID "$node_name_v4")\n"
    fi
    if [[ $HAS_IPV6 -eq 1 ]]; then
        # 如果希望IPv6节点使用其自身的ORG信息得到的vendor_code (可能与v4不同)
        # local vendor_code_for_v6=$(get_vendor_code "$ORG6") 
        # node_name_v6="${COUNTRY6_NAME}-${SERVER_SPECS}-Reality-v6-${vendor_code_for_v6}"
        # 为简化，当前IPv6也使用上面确定的 vendor_code_final
        node_name_v6="${COUNTRY6_NAME}-${SERVER_SPECS}-Reality-v6-${vendor_code_final}"
        SHARE_LINKS+="$(gen_share_link $UUID "[$IPV6]" $PORT $PBK $SNI $SHORTID "$node_name_v6")\n"
    fi
    SHARE_LINKS=$(echo -e "$SHARE_LINKS" | sed '/^$/d') # 移除可能产生的空行

    echo "节点信息配置完成。"

    install_systemd_service

    echo "正在启动 sing-box 服务..."
    if [[ "$OS_RELEASE" == "alpine" ]]; then service sing-box restart
    else systemctl restart sing-box; fi
    
    sleep 3 
    echo "检查 sing-box 服务状态..."
    if [[ "$OS_RELEASE" != "alpine" ]]; then
        if systemctl is-active --quiet sing-box; then echo "sing-box 服务正在运行。"
        else echo "警告：sing-box 服务未能成功启动。请检查日志："; journalctl -u sing-box -n 50 --no-pager; fi
    else
        if pgrep -x "sing-box" > /dev/null; then echo "sing-box 服务正在运行 (Alpine - pgrep check)."
        else echo "警告：sing-box 服务未能成功启动 (Alpine)。请检查相关日志，通常在 /var/log/"; fi
    fi

    echo -e "\n配置完成，节点分享链接如下：\n${SHARE_LINKS}\n"
    echo -e "${SHARE_LINKS}" > ${SING_BOX_PATH}/share.txt

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
