#!/usr/bin/env bashSTREAMING_CHUNK:初始化基础设置与输出函数...强制忽略 locale 警告export LC_ALL=C
set -euo pipefail-----------------------彩色输出函数info() { echo -e "\033[1;34m[INFO]\033[0m $"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }-----------------------STREAMING_CHUNK:检测操作系统环境...检测系统类型detect_os() {
if [ -f /etc/os-release ]; then
. /etc/os-release
OS_ID="${ID:-}"
OS_ID_LIKE="${ID_LIKE:-}"
else
OS_ID=""
OS_ID_LIKE=""
fiif echo "$OS_ID $OS_ID_LIKE" | grep -qi "alpine"; then
    OS="alpine"
elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "debian|ubuntu" >/dev/null; then
    OS="debian"
elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "centos|rhel|fedora" >/dev/null; then
    OS="redhat"
else
    OS="unknown"
fi
}detect_os
info "检测到系统: $OS (${OS_ID:-unknown})"-----------------------STREAMING_CHUNK:权限校验与依赖安装...检查 root 权限check_root() {
if [ "$(id -u)" != "0" ]; then
err "此脚本需要 root 权限"
err "请切换到 root 用户再执行"
exit 1
fi
}check_root安装依赖install_deps() {
info "安装系统依赖..."case "$OS" in
    alpine)
        apk update || { err "apk update 失败"; exit 1; }
        apk add --no-cache bash curl ca-certificates openssl openrc jq || {
            err "依赖安装失败"
            exit 1
        }
        ;;
    debian)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y || { err "apt update 失败"; exit 1; }
        apt-get install -y curl ca-certificates openssl jq || {
            err "依赖安装失败"
            exit 1
        }
        ;;
    redhat)
        yum install -y curl ca-certificates openssl jq || {
            err "依赖安装失败"
            exit 1
        }
        ;;
    *)
        warn "未识别的系统类型,尝试继续..."
        ;;
esac

info "依赖安装完成"
}install_deps-----------------------STREAMING_CHUNK:定义核心工具函数...工具函数rand_port() {
local port
port=$(shuf -i 10000-60000 -n 1 2>/dev/null) || port=$((RANDOM % 50001 + 10000))
echo "$port"
}rand_pass() {
local pass
pass=$(openssl rand -base64 16 2>/dev/null | tr -d '\n\r') || pass=$(head -c 16 /dev/urandom | base64 2>/dev/null | tr -d '\n\r')
echo "$pass"
}rand_uuid() {
local uuid
if [ -f /proc/sys/kernel/random/uuid ]; then
uuid=$(cat /proc/sys/kernel/random/uuid)
else
uuid=$(openssl rand -hex 16 | sed 's/$..$$..$$..$$..$$..$$..$$..$$..$$..$$..$$..$$..$$..$$..$$..$$..$/\1\2\3\4-\5\6-\7\8-\9\10-\11\12\13\14\15\16/')
fi
echo "$uuid"
}-----------------------STREAMING_CHUNK:用户交互：配置节点基础信息...配置节点名称后缀echo "请输入节点名称(留空则默认无后缀):"
read -r user_name
if [[ -n "$user_name" ]]; then
suffix="-${user_name}"
echo "$suffix" > /root/node_names.txt
else
suffix=""
> /root/node_names.txt
fi-----------------------STREAMING_CHUNK:用户交互：选择代理协议...选择要部署的协议select_protocols() {
info "=== 选择要部署的协议 ==="
echo "1) Shadowsocks (SS)"
echo "2) Hysteria2 (HY2)"
echo "3) TUIC"
echo "4) VLESS Reality"
echo "5) AnyTLS Reality"
echo ""
echo "请输入要部署的协议编号(多个用空格分隔,如: 1 2 4):"
read -r protocol_inputENABLE_SS=false
ENABLE_HY2=false
ENABLE_TUIC=false
ENABLE_REALITY=false
ENABLE_ANYTLS=false

for num in $protocol_input; do
    case "$num" in
        1) ENABLE_SS=true ;;
        2) ENABLE_HY2=true ;;
        3) ENABLE_TUIC=true ;;
        4) ENABLE_REALITY=true ;;
        5) ENABLE_ANYTLS=true ;;
        *) warn "无效选项: $num" ;;
    esac
done

if ! $ENABLE_SS && ! $ENABLE_HY2 && ! $ENABLE_TUIC && ! $ENABLE_REALITY && ! $ENABLE_ANYTLS; then
    err "未选择任何协议,退出安装"
    exit 1
fi

mkdir -p /etc/sing-box
cat > /etc/sing-box/.protocols <<EOF
ENABLE_SS=$ENABLE_SS
ENABLE_HY2=$ENABLE_HY2
ENABLE_TUIC=$ENABLE_TUIC
ENABLE_REALITY=$ENABLE_REALITY
ENABLE_ANYTLS=$ENABLE_ANYTLS
EOFinfo "已选择协议:"
$ENABLE_SS && echo "  - Shadowsocks"
$ENABLE_HY2 && echo "  - Hysteria2"
$ENABLE_TUIC && echo "  - TUIC"
$ENABLE_REALITY && echo "  - VLESS Reality"
$ENABLE_ANYTLS && echo "  - AnyTLS Reality"

export ENABLE_SS ENABLE_HY2 ENABLE_TUIC ENABLE_REALITY ENABLE_ANYTLS
}mkdir -p /etc/sing-box
select_protocols-----------------------STREAMING_CHUNK:用户交互：配置 SS 加密与网络连接...select_ss_method() {
if ! $ENABLE_SS; then
SS_METHOD="2022-blake3-aes-128-gcm"
return 0
fiinfo "=== 选择 Shadowsocks 加密方式 ==="
echo "1) 2022-blake3-aes-128-gcm (推荐)"
echo "2) aes-128-gcm"
echo ""
echo "请输入选择(默认为 1):"
read -r ss_method_choice

case "${ss_method_choice:-1}" in
    1) SS_METHOD="2022-blake3-aes-128-gcm" ;;
    2) SS_METHOD="aes-128-gcm" ;;
    *) SS_METHOD="2022-blake3-aes-128-gcm" ;;
esac

info "已选择加密方式: $SS_METHOD"
export SS_METHOD
}select_ss_methodecho ""
echo "请输入节点连接 IP 或 DDNS域名(留空默认自动检测出口IP):"
read -r CUSTOM_IP
CUSTOM_IP="$(echo "$CUSTOM_IP" | tr -d '[:space:]')"REALITY_SNI=""
if $ENABLE_REALITY || $ENABLE_ANYTLS; then
echo ""
echo "请输入 Reality 的 SNI(留空默认 icloud.com):"
read -r REALITY_SNI
REALITY_SNI="$(echo "${REALITY_SNI:-icloud.com}" | tr -d '[:space:]')"
else
REALITY_SNI="icloud.com"
fi写入缓存预留echo "CUSTOM_IP=$CUSTOM_IP" > /etc/sing-box/.config_cache.tmp || true
echo "REALITY_SNI=$REALITY_SNI" >> /etc/sing-box/.config_cache.tmp || true
mv /etc/sing-box/.config_cache.tmp /etc/sing-box/.config_cache || true-----------------------STREAMING_CHUNK:生成各协议所需的端口和密码...get_config() {
info "开始配置端口和密码..."if $ENABLE_SS; then
    read -p "请输入 SS 端口(留空则随机 10000-60000): " USER_PORT_SS
    PORT_SS="${USER_PORT_SS:-$(rand_port)}"
    PSK_SS=$(rand_pass)
    info "SS 端口: $PORT_SS, 密码已自动生成"
fi

if $ENABLE_HY2; then
    read -p "请输入 HY2 端口(留空则随机 10000-60000): " USER_PORT_HY2
    PORT_HY2="${USER_PORT_HY2:-$(rand_port)}"
    PSK_HY2=$(rand_pass)
    info "HY2 端口: $PORT_HY2, 密码已自动生成"
fi

if $ENABLE_TUIC; then
    read -p "请输入 TUIC 端口(留空则随机 10000-60000): " USER_PORT_TUIC
    PORT_TUIC="${USER_PORT_TUIC:-$(rand_port)}"
    PSK_TUIC=$(rand_pass)
    UUID_TUIC=$(rand_uuid)
    info "TUIC 端口: $PORT_TUIC, UUID 和密码已自动生成"
fi

if $ENABLE_REALITY; then
    read -p "请输入 VLESS Reality 端口(留空则随机 10000-60000): " USER_PORT_REALITY
    PORT_REALITY="${USER_PORT_REALITY:-$(rand_port)}"
    UUID=$(rand_uuid)
    info "VLESS Reality 端口: $PORT_REALITY, UUID 已自动生成"
fi

if $ENABLE_ANYTLS; then
    read -p "请输入 AnyTLS Reality 端口(留空则随机 10000-60000): " USER_PORT_ANYTLS
    PORT_ANYTLS="${USER_PORT_ANYTLS:-$(rand_port)}"
    ANYTLS_USER=$(openssl rand -hex 4)
    ANYTLS_PSK=$(openssl rand -base64 16)
    info "AnyTLS Reality 端口: $PORT_ANYTLS, 用户名: $ANYTLS_USER"
fi
}get_config-----------------------STREAMING_CHUNK:安装 sing-box 核心程序...install_singbox() {
info "开始安装 sing-box..."if command -v sing-box >/dev/null 2>&1; then
    CURRENT_VERSION=$(sing-box version 2>/dev/null | head -1 || echo "unknown")
    warn "检测到已安装 sing-box: $CURRENT_VERSION"
    read -p "是否重新安装?(y/N): " REINSTALL
    if [[ ! "$REINSTALL" =~ ^[Yy]$ ]]; then
        info "跳过 sing-box 安装"
        return 0
    fi
fi

case "$OS" in
    alpine)
        info "使用 Edge 仓库安装 sing-box"
        apk update || { err "apk update 失败"; exit 1; }
        apk add --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community sing-box || {
            err "sing-box 安装失败"
            exit 1
        }
        ;;
    debian|redhat)
        bash <(curl -fsSL https://sing-box.app/install.sh) || {
            err "sing-box 安装失败"
            exit 1
        }
        ;;
    *)
        err "未支持的系统,无法安装 sing-box"
        exit 1
        ;;
esac

if ! command -v sing-box >/dev/null 2>&1; then
    err "sing-box 安装后未找到可执行文件"
    exit 1
fi

INSTALLED_VERSION=$(sing-box version 2>/dev/null | head -1 || echo "unknown")
info "sing-box 安装成功: $INSTALLED_VERSION"
}install_singbox-----------------------STREAMING_CHUNK:生成安全证书与密钥对...generate_reality_keys() {
if ! $ENABLE_REALITY && !$ENABLE_ANYTLS; then
return 0
fiinfo "生成 Reality 密钥对..."
REALITY_KEYS=$(sing-box generate reality-keypair 2>&1) || { err "生成 Reality 密钥失败"; exit 1; }
REALITY_PK=$(echo "$REALITY_KEYS" \vert{} grep "PrivateKey" \vert{} awk '{print $NF}' | tr -d '\r')
REALITY_PUB=$(echo "$REALITY_KEYS" \vert{} grep "PublicKey" \vert{} awk '{print $NF}' | tr -d '\r')
REALITY_SID=$(sing-box generate rand 8 --hex 2>&1) || { err "生成 Reality ShortID 失败"; exit 1; }

echo -n "$REALITY_PUB" > /etc/sing-box/.reality_pub
echo -n "$REALITY_SID" > /etc/sing-box/.reality_sid
info "Reality 密钥已生成"
}generate_cert() {
if ! $ENABLE_HY2 && !$ENABLE_TUIC; then
return 0
fi
info "生成 HY2/TUIC 自签证书..."
mkdir -p /etc/sing-box/certs
if [ ! -f /etc/sing-box/certs/fullchain.pem ] || [ ! -f /etc/sing-box/certs/privkey.pem ]; then
openssl req -x509 -newkey rsa:2048 -nodes -keyout /etc/sing-box/certs/privkey.pem -out /etc/sing-box/certs/fullchain.pem -days 3650 -subj "/CN=www.bing.com" || { err "证书生成失败"; exit 1; }
info "证书已生成"
fi
}generate_reality_keys
generate_cert-----------------------STREAMING_CHUNK:构建 sing-box JSON 配置文件...CONFIG_PATH="/etc/sing-box/config.json"create_config() {
info "生成配置文件: $CONFIG_PATH"
mkdir -p "$(dirname "$CONFIG_PATH")"     local TEMP_INBOUNDS="/tmp/singbox_inbounds_$$.json"
> "$TEMP_INBOUNDS"
local need_comma=falseif $ENABLE_SS; then
    cat >> "$TEMP_INBOUNDS" <<'INBOUND_SS'
{
  "type": "shadowsocks",
  "listen": "::",
  "listen_port": PORT_SS_PLACEHOLDER,
  "method": "METHOD_SS_PLACEHOLDER",
  "password": "PSK_SS_PLACEHOLDER",
  "tag": "ss-in"
}
INBOUND_SS
sed -i "s|PORT_SS_PLACEHOLDER|$PORT_SS\vert{}g; s\vert{}METHOD_SS_PLACEHOLDER\vert{}$SS_METHOD|g; s|PSK_SS_PLACEHOLDER|$PSK_SS\vert{}g" "$TEMP_INBOUNDS"
need_comma=true
fiif $ENABLE_HY2; then
    $need_comma && echo "," >> "$TEMP_INBOUNDS"
    cat >> "$TEMP_INBOUNDS" <<'INBOUND_HY2'
{
  "type": "hysteria2",
  "tag": "hy2-in",
  "listen": "::",
  "listen_port": PORT_HY2_PLACEHOLDER,
  "users": [{"password": "PSK_HY2_PLACEHOLDER"}],
  "tls": {
    "enabled": true, "alpn": ["h3"],
    "certificate_path": "/etc/sing-box/certs/fullchain.pem",
    "key_path": "/etc/sing-box/certs/privkey.pem"
  }
}
INBOUND_HY2
sed -i "s|PORT_HY2_PLACEHOLDER|$PORT_HY2|g; s|PSK_HY2_PLACEHOLDER|$PSK_HY2\vert{}g" "$TEMP_INBOUNDS"
need_comma=true
fiif $ENABLE_TUIC; then
    $need_comma && echo "," >> "$TEMP_INBOUNDS"
    cat >> "$TEMP_INBOUNDS" <<'INBOUND_TUIC'
{
  "type": "tuic",
  "tag": "tuic-in",
  "listen": "::",
  "listen_port": PORT_TUIC_PLACEHOLDER,
  "users": [{"uuid": "UUID_TUIC_PLACEHOLDER", "password": "PSK_TUIC_PLACEHOLDER"}],
  "congestion_control": "bbr",
  "tls": {
    "enabled": true, "alpn": ["h3"],
    "certificate_path": "/etc/sing-box/certs/fullchain.pem",
    "key_path": "/etc/sing-box/certs/privkey.pem"
  }
}
INBOUND_TUIC
sed -i "s|PORT_TUIC_PLACEHOLDER|$PORT_TUIC\vert{}g; s\vert{}UUID_TUIC_PLACEHOLDER\vert{}$UUID_TUIC|g; s|PSK_TUIC_PLACEHOLDER|$PSK_TUIC\vert{}g" "$TEMP_INBOUNDS"
need_comma=true
fiif $ENABLE_REALITY; then
    $need_comma && echo "," >> "$TEMP_INBOUNDS"
    cat >> "$TEMP_INBOUNDS" <<'INBOUND_REALITY'
{
  "type": "vless",
  "tag": "vless-in",
  "listen": "::",
  "listen_port": PORT_REALITY_PLACEHOLDER,
  "users": [{"uuid": "UUID_REALITY_PLACEHOLDER", "flow": "xtls-rprx-vision"}],
  "tls": {
    "enabled": true, "server_name": "REALITY_SNI_PLACEHOLDER",
    "reality": {
      "enabled": true, "handshake": {"server": "REALITY_SNI_PLACEHOLDER", "server_port": 443},
      "private_key": "REALITY_PK_PLACEHOLDER", "short_id": ["REALITY_SID_PLACEHOLDER"]
    }
  }
}
INBOUND_REALITY
sed -i "s|PORT_REALITY_PLACEHOLDER|$PORT_REALITY\vert{}g; s\vert{}UUID_REALITY_PLACEHOLDER\vert{}$UUID|g; s|REALITY_PK_PLACEHOLDER|$REALITY_PK\vert{}g; s\vert{}REALITY_SID_PLACEHOLDER\vert{}$REALITY_SID|g; s|REALITY_SNI_PLACEHOLDER|$REALITY_SNI\vert{}g" "$TEMP_INBOUNDS"
need_comma=true
fiif $ENABLE_ANYTLS; then
    $need_comma && echo "," >> "$TEMP_INBOUNDS"
    cat >> "$TEMP_INBOUNDS" <<'INBOUND_ANYTLS'
{
  "type": "anytls",
  "tag": "anytls-in",
  "listen": "::",
  "listen_port": PORT_ANYTLS_PLACEHOLDER,
  "users": [{"name": "ANYTLS_USER_PLACEHOLDER", "password": "ANYTLS_PSK_PLACEHOLDER"}],
  "tls": {
    "enabled": true, "server_name": "REALITY_SNI_PLACEHOLDER",
    "reality": {
      "enabled": true, "handshake": {"server": "REALITY_SNI_PLACEHOLDER", "server_port": 443},
      "private_key": "REALITY_PK_PLACEHOLDER", "short_id": ["REALITY_SID_PLACEHOLDER"]
    }
  }
}
INBOUND_ANYTLS
sed -i "s|PORT_ANYTLS_PLACEHOLDER|$PORT_ANYTLS|g; s|ANYTLS_USER_PLACEHOLDER|$ANYTLS_USER\vert{}g; s\vert{}ANYTLS_PSK_PLACEHOLDER\vert{}$ANYTLS_PSK|g; s|REALITY_PK_PLACEHOLDER|$REALITY_PK\vert{}g; s\vert{}REALITY_SID_PLACEHOLDER\vert{}$REALITY_SID|g; s|REALITY_SNI_PLACEHOLDER|$REALITY_SNI\vert{}g" "$TEMP_INBOUNDS"
ficat > "$CONFIG_PATH" <<'CONFIG_HEAD'
{
"log": {"level": "info"},
"inbounds": [
CONFIG_HEAD
cat "$TEMP_INBOUNDS" >> "$CONFIG_PATH"
cat >> "$CONFIG_PATH" <<'CONFIG_TAIL'
],
"outbounds": [{"type": "direct", "tag": "direct-out"}]
}
CONFIG_TAILrm -f "$TEMP_INBOUNDS"
sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1 && info "配置校验通过" || warn "配置校验失败"

# 保存缓存
cat > /etc/sing-box/.config_cache <<CACHEEOF
ENABLE_SS=$ENABLE_SS
ENABLE_HY2=$ENABLE_HY2
ENABLE_TUIC=$ENABLE_TUIC
ENABLE_REALITY=$ENABLE_REALITY
ENABLE_ANYTLS=$ENABLE_ANYTLS
CUSTOM_IP=$CUSTOM_IP
CACHEEOF
$ENABLE_SS && echo -e "SS_PORT=$PORT_SS\nSS_PSK=$PSK_SS\nSS_METHOD=$SS_METHOD" >> /etc/sing-box/.config_cache
$ENABLE_HY2 && echo -e "HY2_PORT=$PORT_HY2\nHY2_PSK=$PSK_HY2" >> /etc/sing-box/.config_cache
$ENABLE_TUIC && echo -e "TUIC_PORT=$PORT_TUIC\nTUIC_UUID=$UUID_TUIC\nTUIC_PSK=$PSK_TUIC" >> /etc/sing-box/.config_cache
$ENABLE_REALITY && echo -e "REALITY_PORT=$PORT_REALITY\nREALITY_UUID=$UUID\nREALITY_PK=$REALITY_PK\nREALITY_SID=$REALITY_SID\nREALITY_PUB=$REALITY_PUB\nREALITY_SNI=$REALITY_SNI" >> /etc/sing-box/.config_cache
$ENABLE_ANYTLS && echo -e "ANYTLS_PORT=$PORT_ANYTLS\nANYTLS_USER=$ANYTLS_USER\nANYTLS_PSK=$ANYTLS_PSK" >> /etc/sing-box/.config_cache
}create_config-----------------------STREAMING_CHUNK:配置系统守护进程并启动服务...setup_service() {
info "配置系统服务..."
if [ "$OS" = "alpine" ]; then
SERVICE_PATH="/etc/init.d/sing-box"
cat > "$SERVICE_PATH" <<'OPENRC'
#!/sbin/openrc-run
name="sing-box"
command="/usr/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
pidfile="/run/sing-box.pid"
command_background="yes"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.err"
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"
depend() { need net; after firewall; }
OPENRC
chmod +x "$SERVICE_PATH"
rc-update add sing-box default >/dev/null 2>&1 || true
rc-service sing-box restart || { err "服务启动失败"; exit 1; }
else
SERVICE_PATH="/etc/systemd/system/sing-box.service"
cat > "$SERVICE_PATH" <<'SYSTEMD'
[Unit]
Description=Sing-box Proxy Server
After=network.target
[Service]
Type=simple
User=root
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
SYSTEMD
systemctl daemon-reload
systemctl enable sing-box >/dev/null 2>&1
systemctl restart sing-box || { err "服务启动失败"; exit 1; }
fi
info "服务配置完成"
}setup_service-----------------------STREAMING_CHUNK:获取公网 IP 并生成代理 URI 链接...get_public_ip() {
local ip=""
for url in "https://api.ipify.org" "https://ipinfo.io/ip" "https://ifconfig.me"; do
ip=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
echo "$ip" && return 0
fi
done
return 1
}if [ -n "${CUSTOM_IP:-}" ]; then
PUB_IP="$CUSTOM_IP"
else
PUB_IP=$(get_public_ip || echo "YOUR_SERVER_IP")
figenerate_uris() {
local host="$PUB_IP"
if $ENABLE_SS; then
local ss_userinfo="${SS_METHOD}:${PSK_SS}"
ss_b64=$(printf "%s" "$ss_userinfo" \vert{} base64 -w0 2>/dev/null \vert{}\vert{} printf "\%s" "$ss_userinfo" | base64 | tr -d '\n')
echo "=== Shadowsocks (SS) ==="
echo "ss://${ss_b64}@${host}:${PORT_SS}#ss${suffix}"
echo ""
fi
if $ENABLE_HY2; then
hy2_encoded=$(printf "%s" "$PSK_HY2" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
echo "=== Hysteria2 (HY2) ==="
echo "hy2://${hy2_encoded}@${host}:${PORT_HY2}/?sni=www.bing.com&alpn=h3&insecure=1#hy2${suffix}"
echo ""
fi
if $ENABLE_TUIC; then
tuic_encoded=$(printf "%s" "$PSK_TUIC" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
echo "=== TUIC ==="
echo "tuic://${UUID_TUIC}:${tuic_encoded}@${host}:${PORT_TUIC}/?congestion_control=bbr&alpn=h3&sni=www.bing.com&insecure=1#tuic${suffix}"
echo ""
fi
if $ENABLE_REALITY; then
echo "=== VLESS Reality ==="
echo "vless://${UUID}@${host}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#reality${suffix}"
echo ""
fi
if $ENABLE_ANYTLS; then
anytls_pass_encoded=$(printf "%s" "$ANYTLS_PSK" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
echo "=== AnyTLS Reality ==="
echo "anytls://${anytls_pass_encoded}@${host}:${PORT_ANYTLS}/?security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#anytls${suffix}"
echo ""
fi
}echo ""
info "🎉 Sing-box 部署完成!"
generate_uris | while IFS= read -r line; do echo "   $line"; done
echo ""-----------------------STREAMING_CHUNK:创建独立的 sb 终端管理命令...SB_PATH="/usr/local/bin/sb"
cat > "$SB_PATH" <<'SB_SCRIPT'
#!/usr/bin/env bash
export LC_ALL=C
set -euo pipefail
info() { echo -e "\033[1;34m[INFO]\033[0m $"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }CONFIG_PATH="/etc/sing-box/config.json"
CACHE_FILE="/etc/sing-box/.config_cache"
SERVICE_NAME="sing-box"detect_os() {
[ -f /etc/os-release ] && . /etc/os-release || true
if echo "${ID:-}${ID_LIKE:-}" | grep -qi "alpine"; then OS="alpine"
elif echo "${ID:-}${ID_LIKE:-}" | grep -Ei "debian|ubuntu" >/dev/null; then OS="debian"
else OS="linux"
fi
}
detect_osservice_start() { [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" start || systemctl start "$SERVICE_NAME"; }
service_stop() { [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" stop || systemctl stop "$SERVICE_NAME"; }
service_restart() { [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" restart || systemctl restart "$SERVICE_NAME"; }
service_status() { [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" status || systemctl status "$SERVICE_NAME" --no-pager; }url_encode() { printf "%s" "$1" | sed -e 's/%/%25/g' -e 's/:/%3A/g' -e 's/+/%2B/g' -e 's///%2F/g' -e 's/=/%3D/g'; }read_config() {
[ ! -f "$CONFIG_PATH" ] && return 1
[ -f /etc/sing-box/.protocols ] && . /etc/sing-box/.protocols
[ -f "$CACHE_FILE" ] && . "$CACHE_FILE"if [ "${ENABLE_SS:-false}" = "true" ]; then
    SS_PORT=$(jq -r '.inbounds[] \vert{} select(.type=="shadowsocks") \vert{} .listen_port // empty' "$CONFIG_PATH" | head -n1)
    SS_PSK=$(jq -r '.inbounds[] \vert{} select(.type=="shadowsocks") \vert{} .password // empty' "$CONFIG_PATH" | head -n1)
    SS_METHOD=$(jq -r '.inbounds[] \vert{} select(.type=="shadowsocks") \vert{} .method // empty' "$CONFIG_PATH" | head -n1)
fi
if [ "${ENABLE_REALITY:-false}" = "true" ] \vert{}\vert{} [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
    REALITY_SID=$(jq -r '.inbounds[] \vert{} select(.tls.reality.enabled == true) \vert{} .tls.reality.short_id[0] // empty' "$CONFIG_PATH" | head -n1)
    [ -f /etc/sing-box/.reality_pub ] && REALITY_PUB=$(cat /etc/sing-box/.reality_pub)
fi
if [ "${ENABLE_REALITY:-false}" = "true" ]; then
    REALITY_PORT=$(jq -r '.inbounds[] \vert{} select(.type=="vless") \vert{} .listen_port // empty' "$CONFIG_PATH" | head -n1)
    REALITY_UUID=$(jq -r '.inbounds[] \vert{} select(.type=="vless") \vert{} .users[0].uuid // empty' "$CONFIG_PATH" | head -n1)
fi
if [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
    ANYTLS_PORT=$(jq -r '.inbounds[] \vert{} select(.type=="anytls") \vert{} .listen_port // empty' "$CONFIG_PATH" | head -n1)
    ANYTLS_PSK=$(jq -r '.inbounds[] \vert{} select(.type=="anytls") \vert{} .users[0].password // empty' "$CONFIG_PATH" | head -n1)
fi
}generate_uris() {
read_config || return 1
PUBLIC_IP="${CUSTOM_IP:-$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "YOUR_SERVER_IP")}"
node_suffix=$(cat /root/node_names.txt 2>/dev/null || echo "")
echo "" > /etc/sing-box/uris.txtif [ "${ENABLE_SS:-false}" = "true" ]; then
    ss_userinfo="${SS_METHOD}:${SS_PSK}"
    ss_b64=$(printf "%s" "$ss_userinfo" \vert{} base64 -w0 2>/dev/null \vert{}\vert{} printf "\%s" "$ss_userinfo" | base64 | tr -d '\n')
    echo "=== Shadowsocks (SS) ===" >> /etc/sing-box/uris.txt
    echo "ss://${ss_b64}@${PUBLIC_IP}:${SS_PORT}#ss${node_suffix}" >> /etc/sing-box/uris.txt
    echo "" >> /etc/sing-box/uris.txt
fi
if [ "${ENABLE_REALITY:-false}" = "true" ]; then
    echo "=== VLESS Reality ===" >> /etc/sing-box/uris.txt
    echo "vless://${REALITY_UUID}@${PUBLIC_IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI:-icloud.com}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#reality${node_suffix}" >> /etc/sing-box/uris.txt
    echo "" >> /etc/sing-box/uris.txt
fi
if [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
    anytls_pass_encoded=$(url_encode "$ANYTLS_PSK")
    echo "=== AnyTLS Reality ===" >> /etc/sing-box/uris.txt
    echo "anytls://${anytls_pass_encoded}@${PUBLIC_IP}:${ANYTLS_PORT}/?security=reality&sni=${REALITY_SNI:-icloud.com}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#anytls${node_suffix}" >> /etc/sing-box/uris.txt
fi
}action_view_uri() { generate_uris && echo "" && cat /etc/sing-box/uris.txt; }show_menu() {
cat <<'MENU'==========================
Sing-box 管理面板 (sb)查看协议链接查看配置文件路径编辑配置文件启动服务停止服务重启服务查看服务状态更新 sing-box卸载 sing-box退出
==========================
MENU
}while true; do
show_menu
read -p "请输入选项: " opt
case "$opt" in
0) exit 0 ;;
1) action_view_uri ;;
2) echo "$CONFIG_PATH" ;;
3) ${EDITOR:-vi} "$CONFIG_PATH" && sing-box check -c "$CONFIG_PATH" && service_restart ;;
4) service_start && info "已启动" ;;
5) service_stop && info "已停止" ;;
6) service_restart && info "已重启" ;;
7) service_status ;;
8) bash <(curl -fsSL https://sing-box.app/install.sh) && service_restart ;;
9) service_stop; rm -rf /etc/sing-box /usr/local/bin/sb /usr/bin/sb; info "卸载完成"; exit 0 ;;
*) warn "无效选项" ;;
esac
done
SB_SCRIPTchmod +x "$SB_PATH"
ln -sf /usr/local/bin/sb /usr/bin/sb
info "✅ 管理面板已创建, 可随时输入 'sb' 打开管理面板"
