# RealityGo-Reality一键部署脚本

这是一个用于在 Linux 服务器上自动安装和配置 [Sing-Box](https://sing-box.sagernet.org/) 作为 Reality 代理服务器的 Bash 脚本。脚本会自动检测服务器信息，生成配置文件和分享链接，并设置 systemd (或 Alpine Linux 的 OpenRC) 服务。
## 使用方法


```
bash <(curl -sL 'https://raw.githubusercontent.com/hellocosm/RealityGo/refs/heads/main/RealityGo.sh')
```

## 主要功能

* **环境检测**: 自动检测操作系统 (CentOS, Debian, Ubuntu, Alpine) 和 CPU 架构 (amd64, arm64)。
* **依赖安装**: 自动安装必要的依赖包 (wget, tar, jq, openssl, curl, bc)。
* **IP 信息获取**:
    * 自动获取服务器的公网 IPv4 和 IPv6 地址。
    * 通过 `ipapi.co` 和 `ip-api.com` 查询 IP 地址的地理位置 (国家/地区) 和运营商 (ORG) 信息。
    * 支持将常见的国家/地区英文名称本地翻译为中文。
* **服务器信息获取**: 自动获取服务器的 CPU核心数 和 内存大小 (GB)。
* **Sing-Box 安装**:
    * 从 GitHub 下载最新稳定版的 Sing-Box。
    * 安装到指定路径 (默认为 `/etc/sing-box/`)。
* **Reality 配置**:
    * 自动生成 Reality 所需的 UUID, Private Key, Public Key 和 Short ID。
    * 根据用户设定的端口和 SNI (默认为 `global.fujifilm.com`) 生成 `config.json` 配置文件。
    * 配置文件包含 VLESS Reality inbound, 支持 multiplexing (brutal 可选) 和 TCP MultiPath。
* **分享链接生成**:
    * 为 IPv4 和 IPv6 地址分别生成 VLESS Reality 分享链接。
    * 分享链接的节点名称格式为: `[国家中文名]-[CPU核数]H[内存GB]G-Reality-v[4/6]-[运营商代码]`。
    * 运营商代码会根据常见的云服务商 (如 Ali, GCP, AWS, OCI, Azure, Tencent, Vultr 等) 或 ASN 信息生成一个简短标识。
* **服务管理**:
    * 自动创建和配置 systemd 服务文件 (或 Alpine Linux 的 OpenRC 服务脚本)。
    * 设置服务开机自启并启动 Sing-Box 服务。
    * 为 systemd 服务配置较高的 CPU 调度优先级。
* **TCP Fast Open**: 尝试启用 TCP Fast Open 以优化连接速度。
* **便捷输出**:
    * 在脚本末尾显示生成的分享链接。
    * 将分享链接保存到 `${SING_BOX_PATH}/share.txt`。
    * 提供清晰的卸载指引。

## 可配置变量

在脚本的开头，您可以修改以下变量来自定义安装：

* `SING_BOX_PATH`: Sing-Box 的安装目录和配置文件存放目录。默认为 `/etc/sing-box/`。
* `SERVICE_FILE_PATH`: (非 Alpine 系统) systemd 服务文件的完整路径。默认为 `/etc/systemd/system/sing-box.service`。
* `PORT`: Sing-Box Reality 服务监听的端口。默认为 `12121`。
* `SNI`: Reality TLS 握手时使用的 Server Name Indication。默认为 `global.fujifilm.com`。**请确保此 SNI 对应的域名真实存在且可以从您的服务器访问其 443 端口。**



## 注意事项

* **防火墙**: 请确保在您的服务器防火墙中打开脚本中设置的 `PORT` (默认为 `12121`) 的 TCP 和 UDP 端口。
* **SNI 选择**: `SNI` 必须是一个真实存在的、可以通过公网访问其 443 端口的域名。Reality 协议会伪装成向这个 SNI 的 443 端口发起 TLS 连接。选择一个目标区域用户访问较快的 SNI 可能有助于改善连接体验。
* **jq 工具**: 脚本会尝试安装 `jq` 工具用于解析 API 返回的 JSON 数据。如果 `jq` 安装失败或系统中不存在，国家/地区和运营商信息的获取可能会受影响，导致节点名称中的相关字段为“未知”或不准确。
* **IP 地址获取**: 脚本通过多个外部服务 (ip.sb, ifconfig.me, api.ip.fi) 获取公网 IP。如果服务器网络环境限制了对这些服务的访问，IP 地址可能无法正确获取。
* **运营商识别**: 运营商代码的生成依赖于从 IP 信息服务获取到的 `org` 字段。识别的准确性取决于这些服务提供的信息以及脚本内置的判断逻辑。

## 卸载方法

脚本会在执行结束时提示卸载命令。通常包括：

1.  **停止并禁用服务**:
    * 对于 systemd 系统 (Debian, Ubuntu, CentOS):
        ```bash
        sudo systemctl stop sing-box
        sudo systemctl disable sing-box
        ```
    * 对于 Alpine Linux (OpenRC):
        ```bash
        sudo service sing-box stop
        sudo rc-update delete sing-box default
        ```

2.  **删除文件**:
    ```bash
    sudo rm -rf ${SING_BOX_PATH} # 默认为 /etc/sing-box/
    sudo rm -f ${SERVICE_FILE_PATH} # 默认为 /etc/systemd/system/sing-box.service (非Alpine)
    # 如果是 Alpine，服务文件路径是 /etc/init.d/sing-box
    # sudo rm -f /etc/init.d/sing-box
    sudo rm -f /etc/systemd/system/sing-box.service.d/priority.conf # (非Alpine)
    ```

## 脚本依赖

脚本会自动尝试安装以下依赖包：

* `wget`: 用于下载文件。
* `tar`: 用于解压归档文件。
* `jq`: 用于处理 JSON 数据 (获取 IP 详情)。
* `openssl`: 用于生成 Short ID。
* `curl`: 用于从 API 获取 IP 地址和地理位置信息。
* `bc`: 用于进行浮点数运算 (计算内存大小)。

如果您的系统最小化安装，请确保这些工具可以通过包管理器安装。

## 贡献

欢迎提交 Issue 和 Pull Request 来改进此脚本。

## 免责声明

此脚本按“原样”提供，不作任何明示或暗示的保证。使用此脚本的风险由您自行承担。请确保您的使用符合当地法律法规以及服务提供商的政策。
