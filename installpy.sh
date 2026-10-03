#!/usr/bin/env bash
set -euo pipefail-----------------------彩色输出函数info() { echo -e "\033[1;34m[INFO]\033[0m $"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }-----------------------检测系统类型detect_os() {
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
info "检测到系统: $OS (${OS_ID:-unknown})"-----------------------检查 root 权限check_root() {
if [ "$(id -u)" != "0" ]; then
err "此脚本需要 root 权限"
err "请使用: sudo bash -c "$(curl -fsSL ...)" 或切换到 root 用户"
exit 1
fi
}check_root-----------------------安装依赖install_deps() {
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
}install_deps-----------------------配置节点名称后缀echo "请输入节点名称(留空则默认无后缀):"
read -r user_name
if [[ -n "$user_name" ]]; then
suffix="-${user_name}"
echo "$suffix" > /root/node_names.txt
else
suffix=""
> /root/node_names.txt
fi-----------------------选择要部署的协议select_protocols() {
info "=== 选择要部署的协议 ==="
echo "1) Shadowsocks (SS)"
echo "2) Hysteria2 (HY2)"
echo "3) TUIC"
echo "4) VLESS Reality"
echo "5) AnyTLS Reality"
echo ""
echo "请输入要部署的协议编号(多个用空格分隔,如: 1 2 4):"
read -r protocol_input# 使用全局变量
ENABLE_SS=false
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

# 保存协议选择到文件（确保持久化）
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

# 导出为全局变量（确保后续脚本可以访问）
export ENABLE_SS ENABLE_HY2 ENABLE_TUIC ENABLE_REALITY ENABLE_ANYTLS
}创建配置目录mkdir -p /etc/sing-box
select_protocols-----------------------选择SS加密方式select_ss_method() {
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
    *) 
        warn "无效选择，使用默认方式: 2022-blake3-aes-128-gcm"
        SS_METHOD="2022-blake3-aes-128-gcm"
        ;;
esac

info "已选择加密方式: $SS_METHOD"
export SS_METHOD
}select_ss_method-----------------------IP和SNI配置echo ""
echo "请输入节点连接 IP 或 DDNS域名(留空默认出口IP):"
read -r CUSTOM_IP
CUSTOM_IP="$(echo "$CUSTOM_IP" | tr -d '[:space:]')"REALITY_SNI=""
if $ENABLE_REALITY || $ENABLE_ANYTLS; then
echo ""
echo "请输入 Reality 的 SNI(留空默认 addons.mozilla.org):"
read -r REALITY_SNI
REALITY_SNI="$(echo "${REALITY_SNI:-addons.mozilla.org}" | tr -d '[:space:]')"
else
REALITY_SNI="addons.mozilla.org"
fi写入缓存echo "CUSTOM_IP=$CUSTOM_IP" > /etc/sing-box/.config_cache.tmp || true
echo "REALITY_SNI=$REALITY_SNI" >> /etc/sing-box/.config_cache.tmp || true
if [ -f /etc/sing-box/.config_cache ]; then
awk 'FNR==NR{a[$1]=1;next} {split($0,k,"="); if(!(k[1] in a)) print $0}' /etc/sing-box/.config_cache.tmp /etc/sing-box/.config_cache >> /etc/sing-box/.config_cache.tmp2 || true
mv /etc/sing-box/.config_cache.tmp2 /etc/sing-box/.config_cache.tmp || true
fi
mv /etc/sing-box/.config_cache.tmp /etc/sing-box/.config_cache || true-----------------------工具函数rand_port() { shuf -i 10000-60000 -n 1 2>/dev/null || echo $((RANDOM % 50001 + 10000)); }
rand_pass() { openssl rand -base64 16 | tr -d '\n\r' || head -c 16 /dev/urandom | base64 | tr -d '\n\r'; }
rand_uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed 's/$..$$..$$..$$..$$..$$..$$..$$..$$..$$..$$..$$..$$..$$..$$..$$..$/\1\2\3\4-\5\6-\7\8-\9\10-\11\12\13\14\15\16/'; }-----------------------配置端口和密码get_config() {
info "开始配置端口和密码..."if $ENABLE_SS; then
    info "=== 配置 Shadowsocks (SS) ==="
    read -p "请输入 SS 端口(留空则随机 10000-60000): " USER_PORT_SS
    PORT_SS="${USER_PORT_SS:-$(rand_port)}"
    PSK_SS=$(rand_pass)
    info "SS 端口: $PORT_SS"
fi

if $ENABLE_HY2; then
    info "=== 配置 Hysteria2 (HY2) ==="
    read -p "请输入 HY2 端口(留空则随机 10000-60000): " USER_PORT_HY2
    PORT_HY2="${USER_PORT_HY2:-$(rand_port)}"
    PSK_HY2=$(rand_pass)
    info "HY2 端口: $PORT_HY2"
fi

if $ENABLE_TUIC; then
    info "=== 配置 TUIC ==="
    read -p "请输入 TUIC 端口(留空则随机 10000-60000): " USER_PORT_TUIC
    PORT_TUIC="${USER_PORT_TUIC:-$(rand_port)}"
    PSK_TUIC=$(rand_pass)
    UUID_TUIC=$(rand_uuid)
    info "TUIC 端口: $PORT_TUIC"
fi

if $ENABLE_REALITY; then
    info "=== 配置 VLESS Reality ==="
    read -p "请输入 VLESS Reality 端口(留空则随机 10000-60000): " USER_PORT_REALITY
    PORT_REALITY="${USER_PORT_REALITY:-$(rand_port)}"
    UUID=$(rand_uuid)
    info "VLESS Reality 端口: $PORT_REALITY"
fi

if $ENABLE_ANYTLS; then
    info "=== 配置 AnyTLS Reality ==="
    read -p "请输入 AnyTLS Reality 端口(留空则随机 10000-60000): " USER_PORT_ANYTLS
    PORT_ANYTLS="${USER_PORT_ANYTLS:-$(rand_port)}"
    ANYTLS_USER=$(openssl rand -hex 4)
    ANYTLS_PSK=$(openssl rand -base64 16)
    info "AnyTLS Reality 端口: $PORT_ANYTLS"
    info "AnyTLS Reality 用户名: $ANYTLS_USER"
fi

info "配置完成，继续安装..."
}get_config-----------------------安装 sing-boxinstall_singbox() {
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
}install_singbox-----------------------生成 Reality 密钥对generate_reality_keys() {
if ! $ENABLE_REALITY && ! $ENABLE_ANYTLS; then
info "跳过 Reality 密钥生成（未选择 Reality 协议）"
return 0
fiinfo "生成 Reality 密钥对..."
REALITY_KEYS=$(sing-box generate reality-keypair 2>&1) || { err "生成 Reality 密钥失败"; exit 1; }
REALITY_PK=$(echo "$REALITY_KEYS" | grep "PrivateKey" | awk '{print $NF}' | tr -d '\r')
REALITY_PUB=$(echo "$REALITY_KEYS" | grep "PublicKey" | awk '{print $NF}' | tr -d '\r')
REALITY_SID=$(sing-box generate rand 8 --hex 2>&1) || { err "生成 Reality ShortID 失败"; exit 1; }

echo -n "$REALITY_PUB" > /etc/sing-box/.reality_pub
echo -n "$REALITY_SID" > /etc/sing-box/.reality_sid

info "Reality 密钥已生成"
}generate_reality_keys-----------------------生成 HY2/TUIC 自签证书generate_cert() {
if ! $ENABLE_HY2 && !$ENABLE_TUIC; then
return 0
fiinfo "生成 HY2/TUIC 自签证书..."
mkdir -p /etc/sing-box/certs

if [ ! -f /etc/sing-box/certs/fullchain.pem ] || [ ! -f /etc/sing-box/certs/privkey.pem ]; then
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout /etc/sing-box/certs/privkey.pem \
      -out /etc/sing-box/certs/fullchain.pem \
      -days 3650 \
      -subj "/CN=www.bing.com" || { err "证书生成失败"; exit 1; }
    info "证书已生成"
else
    info "证书已存在"
fi
}generate_cert-----------------------生成配置文件CONFIG_PATH="/etc/sing-box/config.json"create_config() {
info "生成配置文件: $CONFIG_PATH"
mkdir -p "$(dirname "$CONFIG_PATH")"      local TEMP_INBOUNDS="/tmp/singbox_inbounds_$$.json"
> "$TEMP_INBOUNDS"local need_comma=false

if $ENABLE_SS; then
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
sed -i "s|PORT_SS_PLACEHOLDER|$PORT_SS\vert{}g" "$TEMP_INBOUNDS"
sed -i "s|METHOD_SS_PLACEHOLDER|$SS_METHOD\vert{}g" "$TEMP_INBOUNDS"
sed -i "s|PSK_SS_PLACEHOLDER|$PSK_SS\vert{}g" "$TEMP_INBOUNDS"
need_comma=true
fiif $ENABLE_HY2; then
    $need_comma && echo "," >> "$TEMP_INBOUNDS"
    cat >> "$TEMP_INBOUNDS" <<'INBOUND_HY2'
{
  "type": "hysteria2",
  "tag": "hy2-in",
  "listen": "::",
  "listen_port": PORT_HY2_PLACEHOLDER,
  "users": [{ "password": "PSK_HY2_PLACEHOLDER" }],
  "tls": {
    "enabled": true,
    "alpn": ["h3"],
    "certificate_path": "/etc/sing-box/certs/fullchain.pem",
    "key_path": "/etc/sing-box/certs/privkey.pem"
  }
}
INBOUND_HY2
sed -i "s|PORT_HY2_PLACEHOLDER|$PORT_HY2\vert{}g" "$TEMP_INBOUNDS"
sed -i "s|PSK_HY2_PLACEHOLDER|$PSK_HY2\vert{}g" "$TEMP_INBOUNDS"
need_comma=true
fiif $ENABLE_TUIC; then
    $need_comma && echo "," >> "$TEMP_INBOUNDS"
    cat >> "$TEMP_INBOUNDS" <<'INBOUND_TUIC'
{
  "type": "tuic",
  "tag": "tuic-in",
  "listen": "::",
  "listen_port": PORT_TUIC_PLACEHOLDER,
  "users": [{ "uuid": "UUID_TUIC_PLACEHOLDER", "password": "PSK_TUIC_PLACEHOLDER" }],
  "congestion_control": "bbr",
  "tls": {
    "enabled": true,
    "alpn": ["h3"],
    "certificate_path": "/etc/sing-box/certs/fullchain.pem",
    "key_path": "/etc/sing-box/certs/privkey.pem"
  }
}
INBOUND_TUIC
sed -i "s|PORT_TUIC_PLACEHOLDER|$PORT_TUIC\vert{}g" "$TEMP_INBOUNDS"
sed -i "s|UUID_TUIC_PLACEHOLDER|$UUID_TUIC\vert{}g" "$TEMP_INBOUNDS"
sed -i "s|PSK_TUIC_PLACEHOLDER|$PSK_TUIC\vert{}g" "$TEMP_INBOUNDS"
need_comma=true
fiif $ENABLE_REALITY; then
    $need_comma && echo "," >> "$TEMP_INBOUNDS"
    cat >> "$TEMP_INBOUNDS" <<'INBOUND_REALITY'
{
  "type": "vless",
  "tag": "vless-in",
  "listen": "::",
  "listen_port": PORT_REALITY_PLACEHOLDER,
  "users": [{ "uuid": "UUID_REALITY_PLACEHOLDER", "flow": "xtls-rprx-vision" }],
  "tls": {
    "enabled": true,
    "server_name": "REALITY_SNI_PLACEHOLDER",
    "reality": {
      "enabled": true,
      "handshake": { "server": "REALITY_SNI_PLACEHOLDER", "server_port": 443 },
      "private_key": "REALITY_PK_PLACEHOLDER",
      "short_id": ["REALITY_SID_PLACEHOLDER"]
    }
  }
}
INBOUND_REALITY
sed -i "s|PORT_REALITY_PLACEHOLDER|$PORT_REALITY\vert{}g" "$TEMP_INBOUNDS"
sed -i "s|UUID_REALITY_PLACEHOLDER|$UUID\vert{}g" "$TEMP_INBOUNDS"
sed -i "s|REALITY_PK_PLACEHOLDER|$REALITY_PK\vert{}g" "$TEMP_INBOUNDS"
sed -i "s|REALITY_SID_PLACEHOLDER|$REALITY_SID\vert{}g" "$TEMP_INBOUNDS"
sed -i "s|REALITY_SNI_PLACEHOLDER|$REALITY_SNI\vert{}g" "$TEMP_INBOUNDS"
need_comma=true
fiif $ENABLE_ANYTLS; then
    $need_comma && echo "," >> "$TEMP_INBOUNDS"
    cat >> "$TEMP_INBOUNDS" <<'INBOUND_ANYTLS'
{
  "type": "anytls",
  "tag": "anytls-in",
  "listen": "::",
  "listen_port": PORT_ANYTLS_PLACEHOLDER,
  "users": [{ "name": "ANYTLS_USER_PLACEHOLDER", "password": "ANYTLS_PSK_PLACEHOLDER" }],
  "padding_scheme": [],
  "tls": {
    "enabled": true,
    "server_name": "REALITY_SNI_PLACEHOLDER",
    "reality": {
      "enabled": true,
      "handshake": { "server": "REALITY_SNI_PLACEHOLDER", "server_port": 443 },
      "private_key": "REALITY_PK_PLACEHOLDER",
      "short_id": ["REALITY_SID_PLACEHOLDER"]
    }
  }
}
INBOUND_ANYTLS
sed -i "s|PORT_ANYTLS_PLACEHOLDER|$PORT_ANYTLS\vert{}g" "$TEMP_INBOUNDS"
sed -i "s|ANYTLS_USER_PLACEHOLDER|$ANYTLS_USER\vert{}g" "$TEMP_INBOUNDS"
sed -i "s|ANYTLS_PSK_PLACEHOLDER|$ANYTLS_PSK\vert{}g" "$TEMP_INBOUNDS"
sed -i "s|REALITY_PK_PLACEHOLDER|$REALITY_PK\vert{}g" "$TEMP_INBOUNDS"
sed -i "s|REALITY_SID_PLACEHOLDER|$REALITY_SID\vert{}g" "$TEMP_INBOUNDS"
sed -i "s|REALITY_SNI_PLACEHOLDER|$REALITY_SNI\vert{}g" "$TEMP_INBOUNDS"
ficat > "$CONFIG_PATH" <<'CONFIG_HEAD'
{
"log": { "level": "info", "timestamp": true },
"ntp": { "enabled": true, "server": "time.apple.com", "server_port": 123, "interval": "30m" },
"inbounds": [
CONFIG_HEADcat "$TEMP_INBOUNDS" >> "$CONFIG_PATH"

cat >> "$CONFIG_PATH" <<'CONFIG_TAIL'
],
"outbounds": [
{ "type": "direct", "tag": "direct-out" }
]
}
CONFIG_TAILrm -f "$TEMP_INBOUNDS"

sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1 \
   && info "配置文件验证通过" \
   || warn "配置文件验证失败,但继续执行"

# 保存配置缓存
cat > /etc/sing-box/.config_cache <<CACHEEOF
ENABLE_SS=$ENABLE_SS
ENABLE_HY2=$ENABLE_HY2
ENABLE_TUIC=$ENABLE_TUIC
ENABLE_REALITY=$ENABLE_REALITY
ENABLE_ANYTLS=$ENABLE_ANYTLS
CUSTOM_IP=$CUSTOM_IP
CACHEEOF$ENABLE_SS && cat >> /etc/sing-box/.config_cache <<CACHEEOF
SS_PORT=$PORT_SS
SS_PSK=$PSK_SS
SS_METHOD=$SS_METHOD
CACHEEOF$ENABLE_HY2 && cat >> /etc/sing-box/.config_cache <<CACHEEOF
HY2_PORT=$PORT_HY2
HY2_PSK=$PSK_HY2
CACHEEOF$ENABLE_TUIC && cat >> /etc/sing-box/.config_cache <<CACHEEOF
TUIC_PORT=$PORT_TUIC
TUIC_UUID=$UUID_TUIC
TUIC_PSK=$PSK_TUIC
CACHEEOF$ENABLE_REALITY && cat >> /etc/sing-box/.config_cache <<CACHEEOF
REALITY_PORT=$PORT_REALITY
REALITY_UUID=$UUID
REALITY_PK=$REALITY_PK
REALITY_SID=$REALITY_SID
REALITY_PUB=$REALITY_PUB
REALITY_SNI=$REALITY_SNI
CACHEEOF$ENABLE_ANYTLS && cat >> /etc/sing-box/.config_cache <<CACHEEOF
ANYTLS_PORT=$PORT_ANYTLS
ANYTLS_USER=$ANYTLS_USER
ANYTLS_PSK=$ANYTLS_PSK
CACHEEOFinfo "配置缓存已保存"
}create_config-----------------------设置服务setup_service() {
info "配置系统服务..."if [ "$OS" = "alpine" ]; then
    SERVICE_PATH="/etc/init.d/sing-box"
    cat > "$SERVICE_PATH" <<'OPENRC'
#!/sbin/openrc-run
name="sing-box"
description="Sing-box Proxy Server"
command="/usr/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
pidfile="/run/${RC_SVCNAME}.pid"
command_background="yes"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.err"
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"depend() { need net; after firewall; }
start_pre() { checkpath --directory --mode 0755 /var/log; checkpath --directory --mode 0755 /run; }
OPENRC
chmod +x "$SERVICE_PATH"
rc-update add sing-box default >/dev/null 2>&1
rc-service sing-box restart
else
SERVICE_PATH="/etc/systemd/system/sing-box.service"
cat > "$SERVICE_PATH" <<'SYSTEMD'
[Unit]
Description=Sing-box Proxy Server
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target
Wants=network.target[Service]
Type=simple
User=root
WorkingDirectory=/etc/sing-box
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=1048576[Install]
WantedBy=multi-user.target
SYSTEMD
systemctl daemon-reload
systemctl enable sing-box >/dev/null 2>&1
systemctl restart sing-box
fi
info "服务配置完成"
}setup_service-----------------------获取公网 IPget_public_ip() {
local ip=""
for url in "https://api.ipify.org" "https://ipinfo.io/ip" "https://ifconfig.me"; do
ip=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "$ip"; return 0; fi
done
return 1
}if [ -n "${CUSTOM_IP:-}" ]; then
PUB_IP="$CUSTOM_IP"
else
PUB_IP=$(get_public_ip || echo "YOUR_SERVER_IP")
fi-----------------------生成链接generate_uris() {
local host="$PUB_IP"if $ENABLE_SS; then
    local ss_userinfo="${SS_METHOD}:${PSK_SS}"
    ss_b64=$(printf "%s" "$ss_userinfo" \vert{} base64 -w0 2>/dev/null \vert{}\vert{} printf "\%s" "$ss_userinfo" | base64 | tr -d '\n')
    echo "=== Shadowsocks (SS) ==="
    echo "ss://${ss_b64}@${host}:${PORT_SS}#ss${suffix}"
    echo ""
fi

if $ENABLE_HY2; then
    hy2_encoded=$(printf "\%s" "$PSK_HY2" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
    echo "=== Hysteria2 (HY2) ==="
    echo "hy2://${hy2_encoded}@${host}:${PORT_HY2}/?sni=www.bing.com&alpn=h3&insecure=1#hy2${suffix}"
    echo ""
fi

if $ENABLE_TUIC; then
    tuic_encoded=$(printf "\%s" "$PSK_TUIC" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
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
    anytls_pass_encoded=$(printf "\%s" "$ANYTLS_PSK" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
    echo "=== AnyTLS Reality ==="
    echo "anytls://${anytls_pass_encoded}@${host}:${PORT_ANYTLS}/?security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#anytls${suffix}"
    echo ""
fi
}echo ""
info "🎉 Sing-box 部署完成!"
generate_uris | while IFS= read -r line; do echo "   $line"; done
echo ""-----------------------创建 sb 管理脚本SB_PATH="/usr/local/bin/sb"
info "正在创建 sb 管理面板: $SB_PATH"cat > "$SB_PATH" <<'SB_SCRIPT'
#!/usr/bin/env bash
set -euo pipefailinfo() { echo -e "\033[1;34m[INFO]\033[0m $"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }CONFIG_PATH="/etc/sing-box/config.json"
CACHE_FILE="/etc/sing-box/.config_cache"
SERVICE_NAME="sing-box"detect_os() {
. /etc/os-release 2>/dev/null || true
if echo "${ID:-}${ID_LIKE:-}" | grep -qi "alpine"; then OS="alpine"
else OS="linux"
fi
}
detect_osservice_start() { [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" start || systemctl start "$SERVICE_NAME"; }
service_stop() { [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" stop || systemctl stop "$SERVICE_NAME"; }
service_restart() { [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" restart || systemctl restart "$SERVICE_NAME"; }
service_status() { [ "$OS" = "alpine" ] && rc-service "$SERVICE_NAME" status || systemctl status "$SERVICE_NAME" --no-pager; }url_encode() { printf "%s" "$1" | sed -e 's/%/%25/g' -e 's/:/%3A/g' -e 's/+/%2B/g' -e 's///%2F/g' -e 's/=/%3D/g'; }read_config() {
[ ! -f "$CONFIG_PATH" ] && err "未找到配置文件" && return 1
[ -f "/etc/sing-box/.protocols" ] && . "/etc/sing-box/.protocols"
[ -f "$CACHE_FILE" ] && . "$CACHE_FILE"REALITY_SNI="${REALITY_SNI:-addons.mozilla.org}"

if [ "${ENABLE_SS:-false}" = "true" ]; then
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
}get_public_ip() {
local ip=""
for url in "https://api.ipify.org" "https://ipinfo.io/ip" "https://ifconfig.me"; do
ip=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
[ -n "$ip" ] && echo "$ip" && return 0
done
}generate_uris() {
read_config || return 1
PUBLIC_IP="${CUSTOM_IP:-$(get_public_ip)}"
node_suffix=$(cat /root/node_names.txt 2>/dev/null || echo "")
URI_FILE="/etc/sing-box/uris.txt"
> "$URI_FILE"if [ "${ENABLE_SS:-false}" = "true" ]; then
    ss_userinfo="${SS_METHOD}:${SS_PSK}"
    ss_b64=$(printf "%s" "$ss_userinfo" \vert{} base64 -w0 2>/dev/null \vert{}\vert{} printf "\%s" "$ss_userinfo" | base64 | tr -d '\n')
    echo "=== Shadowsocks (SS) ===" >> "$URI_FILE"
    echo "ss://${ss_b64}@${PUBLIC_IP}:${SS_PORT}#ss${node_suffix}" >> "$URI_FILE"
    echo "" >> "$URI_FILE"
fi

if [ "${ENABLE_REALITY:-false}" = "true" ]; then
    echo "=== VLESS Reality ===" >> "$URI_FILE"
    echo "vless://${REALITY_UUID}@${PUBLIC_IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#reality${node_suffix}" >> "$URI_FILE"
    echo "" >> "$URI_FILE"
fi

if [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
    anytls_pass_encoded=$(url_encode "$ANYTLS_PSK")
    echo "=== AnyTLS Reality ===" >> "$URI_FILE"
    echo "anytls://${anytls_pass_encoded}@${PUBLIC_IP}:${ANYTLS_PORT}/?security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#anytls${node_suffix}" >> "$URI_FILE"
    echo "" >> "$URI_FILE"
fi
}action_view_uri() { generate_uris && echo "" && cat /etc/sing-box/uris.txt; }show_menu() {
read_config 2>/dev/null || true
cat <<'MENU'Sing-box 管理面板 (快速指令sb)查看协议链接查看配置文件路径编辑配置文件启动服务停止服务重启服务查看状态更新 sing-box卸载 sing-box退出
==========================
MENU
}while true; do
show_menu
read -p "请输入选项: " opt
case "$opt" in
0) exit 0 ;;
1) action_view_uri ;;
2) echo "$CONFIG_PATH" ;;
3) ${EDITOR:-nano} "$CONFIG_PATH" && sing-box check -c "$CONFIG_PATH" && service_restart ;;
4) service_start && info "已启动" ;;
5) service_stop && info "已停止" ;;
6) service_restart && info "已重启" ;;
7) service_status ;;
8) bash <(curl -fsSL https://sing-box.app/install.sh) && service_restart ;;
9) service_stop; rm -rf /etc/sing-box /usr/local/bin/sb; info "卸载完成"; exit 0 ;;
*) warn "无效选项" ;;
esac
echo ""
done
SB_SCRIPTchmod +x "$SB_PATH"
ln -sf /usr/local/bin/sb /usr/bin/sb
info "✅ 管理面板已创建,可随时在终端输入 'sb' 打开管理面板"
