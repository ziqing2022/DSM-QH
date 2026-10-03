#!/usr/bin/env bash
set -euo pipefail

# -----------------------
# 彩色输出函数
info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

# -----------------------
# 检测系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-}"
        OS_ID_LIKE="${ID_LIKE:-}"
    else
        OS_ID=""
        OS_ID_LIKE=""
    fi

    if echo "$OS_ID $OS_ID_LIKE" | grep -qi "alpine"; then
        OS="alpine"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "debian|ubuntu" >/dev/null; then
        OS="debian"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "centos|rhel|fedora" >/dev/null; then
        OS="redhat"
    else
        OS="unknown"
    fi
}

detect_os
info "检测到系统: $OS (${OS_ID:-unknown})"

# -----------------------
# 检查 root 权限
check_root() {
    if [ "$(id -u)" != "0" ]; then
        err "此脚本需要 root 权限"
        exit 1
    fi
}

check_root

# -----------------------
# 安装依赖
install_deps() {
    info "安装系统依赖..."
    case "$OS" in
        alpine) apk add --no-cache bash curl wget tar ca-certificates openssl jq >/dev/null 2>&1 || true ;;
        debian) apt-get update -y >/dev/null 2>&1 && apt-get install -y curl wget tar ca-certificates openssl jq >/dev/null 2>&1 || true ;;
        redhat) yum install -y curl wget tar ca-certificates openssl jq >/dev/null 2>&1 || true ;;
        *) warn "未知系统，尝试跳过包管理器依赖安装..." ;;
    esac
}
install_deps

# -----------------------
# 工具函数
rand_port() { shuf -i 10000-60000 -n 1 2>/dev/null || echo $((RANDOM % 50001 + 10000)); }
rand_pass() { openssl rand -base64 16 2>/dev/null | tr -d '\n\r' || head -c 16 /dev/urandom | base64 2>/dev/null | tr -d '\n\r'; }
rand_uuid() { 
    if command -v uuidgen >/dev/null 2>&1; then uuidgen; 
    elif [ -f /proc/sys/kernel/random/uuid ]; then cat /proc/sys/kernel/random/uuid;
    else openssl rand -hex 16 | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2\3\4-\5\6-\7\8-\9\10-\11\12\13\14\15\16/'; fi
}

# -----------------------
echo "请输入节点名称(留空则默认):"
read -r user_name
suffix=${user_name:+"-${user_name}"}

info "=== 选择要部署的协议 ==="
echo "1) Shadowsocks (SS)"
echo "2) Hysteria2 (HY2)"
echo "3) TUIC"
echo "4) VLESS Reality"
echo "5) AnyTLS Reality"
echo "请输入要部署的协议编号(多个用空格分隔,如: 1 2 4):"
read -r protocol_input

ENABLE_SS=false; ENABLE_HY2=false; ENABLE_TUIC=false; ENABLE_REALITY=false; ENABLE_ANYTLS=false
for num in $protocol_input; do
    case "$num" in
        1) ENABLE_SS=true ;; 2) ENABLE_HY2=true ;; 3) ENABLE_TUIC=true ;; 4) ENABLE_REALITY=true ;; 5) ENABLE_ANYTLS=true ;;
    esac
done

! $ENABLE_SS && ! $ENABLE_HY2 && ! $ENABLE_TUIC && ! $ENABLE_REALITY && ! $ENABLE_ANYTLS && err "未选择协议" && exit 1

if $ENABLE_SS; then SS_METHOD="2022-blake3-aes-128-gcm"; fi

echo "请输入节点连接 IP 或 DDNS域名(留空默认出口IP):"
read -r CUSTOM_IP
CUSTOM_IP="$(echo "$CUSTOM_IP" | tr -d '[:space:]')"

REALITY_SNI="addons.mozilla.org"
if $ENABLE_REALITY || $ENABLE_ANYTLS; then
    echo "请输入 Reality 的 SNI(留空默认 addons.mozilla.org):"
    read -r user_sni
    [ -n "$user_sni" ] && REALITY_SNI="$(echo "$user_sni" | tr -d '[:space:]')"
fi

# -----------------------
# 配置端口和密码
if $ENABLE_SS; then PORT_SS="$(rand_port)"; PSK_SS="$(rand_pass)"; fi
if $ENABLE_HY2; then PORT_HY2="$(rand_port)"; PSK_HY2="$(rand_pass)"; fi
if $ENABLE_TUIC; then PORT_TUIC="$(rand_port)"; PSK_TUIC="$(rand_pass)"; UUID_TUIC="$(rand_uuid)"; fi
if $ENABLE_REALITY; then PORT_REALITY="$(rand_port)"; UUID="$(rand_uuid)"; fi
if $ENABLE_ANYTLS; then PORT_ANYTLS="$(rand_port)"; ANYTLS_USER=$(openssl rand -hex 4 2>/dev/null || echo "user1"); ANYTLS_PSK=$(rand_pass); fi

# -----------------------
# 核心：兼容群晖的二进制下载安装
install_singbox() {
    info "开始安装 sing-box 核心..."
    
    if command -v sing-box >/dev/null 2>&1; then
        info "检测到已安装 sing-box，跳过下载。"
        return 0
    fi

    if [ "$OS" = "unknown" ]; then
        info "识别为群晖或定制路由系统，执行通用架构下载..."
        ARCH_RAW=$(uname -m)
        case "${ARCH_RAW}" in
            x86_64|amd64) ARCH="amd64" ;;
            aarch64|arm64) ARCH="arm64" ;;
            i386|i686) ARCH="386" ;;
            armv7*) ARCH="armv7" ;;
            *) err "不支持的架构: ${ARCH_RAW}"; exit 1 ;;
        esac
        
        VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep tag_name | cut -d '"' -f4)
        [ -z "$VERSION" ] && VERSION="v1.10.1"
        FILE="sing-box-${VERSION#v}-linux-${ARCH}.tar.gz"
        URL="https://github.com/SagerNet/sing-box/releases/download/${VERSION}/${FILE}"
        
        info "正在下载: $FILE"
        rm -rf /tmp/sb* && cd /tmp
        wget -q -O /tmp/sb.tar.gz "${URL}" || curl -sL -o /tmp/sb.tar.gz "${URL}"
        tar -xzf /tmp/sb.tar.gz -C /tmp
        
        BIN=$(find /tmp -type f -name sing-box | head -n 1)
        if [ ! -f "${BIN}" ]; then err "核心下载解压失败"; exit 1; fi
        
        cp -f "${BIN}" /usr/bin/sing-box
        chmod +x /usr/bin/sing-box
        info "核心安装成功: ${VERSION}"
    else
        # 传统 Linux 走官方脚本
        bash <(curl -fsSL https://sing-box.app/install.sh) >/dev/null 2>&1 || err "安装失败"
    fi
}
install_singbox

# -----------------------
# 生成密钥与证书
mkdir -p /etc/sing-box
if $ENABLE_REALITY || $ENABLE_ANYTLS; then
    info "生成 Reality 密钥对..."
    REALITY_KEYS=$(sing-box generate reality-keypair 2>&1)
    REALITY_PK=$(echo "$REALITY_KEYS" | grep "PrivateKey" | awk '{print $NF}' | tr -d '\r')
    REALITY_PUB=$(echo "$REALITY_KEYS" | grep "PublicKey" | awk '{print $NF}' | tr -d '\r')
    REALITY_SID=$(sing-box generate rand 8 --hex 2>&1)
fi

# -----------------------
# 组装配置
CONFIG_PATH="/etc/sing-box/config.json"
TEMP_INBOUNDS="/tmp/singbox_inbounds_$$.json"
> "$TEMP_INBOUNDS"
need_comma=false

if $ENABLE_ANYTLS; then
    cat >> "$TEMP_INBOUNDS" <<INBOUND_ANYTLS
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": $PORT_ANYTLS,
      "users": [{ "name": "$ANYTLS_USER", "password": "$ANYTLS_PSK" }],
      "tls": {
        "enabled": true,
        "server_name": "$REALITY_SNI",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$REALITY_SNI", "server_port": 443 },
          "private_key": "$REALITY_PK",
          "short_id": ["$REALITY_SID"]
        }
      }
    }
INBOUND_ANYTLS
    need_comma=true
fi

if $ENABLE_REALITY; then
    $need_comma && echo "," >> "$TEMP_INBOUNDS"
    cat >> "$TEMP_INBOUNDS" <<INBOUND_REALITY
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": $PORT_REALITY,
      "users": [{ "uuid": "$UUID", "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true,
        "server_name": "$REALITY_SNI",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$REALITY_SNI", "server_port": 443 },
          "private_key": "$REALITY_PK",
          "short_id": ["$REALITY_SID"]
        }
      }
    }
INBOUND_REALITY
fi

cat > "$CONFIG_PATH" <<CONFIG_HEAD
{
  "log": { "level": "info" },
  "inbounds": [
CONFIG_HEAD
cat "$TEMP_INBOUNDS" >> "$CONFIG_PATH"
cat >> "$CONFIG_PATH" <<CONFIG_TAIL
  ],
  "outbounds": [{ "type": "direct", "tag": "direct-out" }]
}
CONFIG_TAIL

rm -f "$TEMP_INBOUNDS"

# -----------------------
# 设置服务 (支持群晖的 nohup 静默运行兜底)
setup_service() {
    info "配置系统运行状态..."
    pkill -9 sing-box 2>/dev/null || true
    
    if command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
        cat > /etc/systemd/system/sing-box.service <<'SYSTEMD'
[Unit]
Description=Sing-box
After=network.target
[Service]
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
Restart=always
[Install]
WantedBy=multi-user.target
SYSTEMD
        systemctl daemon-reload
        systemctl enable sing-box >/dev/null 2>&1
        systemctl restart sing-box || true
        info "已使用 Systemd 接管服务"
    else
        nohup /usr/bin/sing-box run -c /etc/sing-box/config.json >/dev/null 2>&1 &
        info "已使用 Nohup 后台静默运行 (群晖/通用环境兼容)"
    fi
}
setup_service

# -----------------------
# 输出节点信息
PUB_IP=${CUSTOM_IP:-$(curl -s https://api.ipify.org 2>/dev/null || echo "YOUR_IP")}
info "🎉 Sing-box 部署完成!"

if $ENABLE_ANYTLS; then
    echo "=== AnyTLS 节点信息 ==="
    anytls_pass_encoded=$(printf "%s" "$ANYTLS_PSK" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
    echo "anytls://${anytls_pass_encoded}@${PUB_IP}:${PORT_ANYTLS}/?security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#AnyTLS${suffix}"
fi

if $ENABLE_REALITY; then
    echo "=== VLESS Reality 节点信息 ==="
    echo "vless://${UUID}@${PUB_IP}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#Reality${suffix}"
fi
