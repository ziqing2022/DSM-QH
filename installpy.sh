#!/usr/bin/env bash
set -euo pipefail

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

# ==========================================
# 第一部分：环境检测与准备
# ==========================================
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-}"
        OS_ID_LIKE="${ID_LIKE:-}"
    else
        OS_ID=""
        OS_ID_LIKE=""
    fi

    if echo "$OS_ID $OS_ID_LIKE" | grep -qi "alpine"; then OS="alpine"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "debian|ubuntu" >/dev/null; then OS="debian"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "centos|rhel|fedora" >/dev/null; then OS="redhat"
    else OS="unknown"
    fi
}
detect_os
info "检测到系统: $OS (${OS_ID:-群晖或定制系统})"

if [ "$(id -u)" != "0" ]; then err "此脚本需要 root 权限"; exit 1; fi

# 工具函数
rand_port() { shuf -i 10000-60000 -n 1 2>/dev/null || echo $((RANDOM % 50001 + 10000)); }
rand_pass() { openssl rand -base64 16 2>/dev/null | tr -d '\n\r' || head -c 16 /dev/urandom | base64 2>/dev/null | tr -d '\n\r'; }
rand_uuid() { 
    if command -v uuidgen >/dev/null 2>&1; then uuidgen; 
    elif [ -f /proc/sys/kernel/random/uuid ]; then cat /proc/sys/kernel/random/uuid;
    else openssl rand -hex 16 | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2\3\4-\5\6-\7\8-\9\10-\11\12\13\14\15\16/'; fi
}

# ==========================================
# 第二部分：交互式配置收集
# ==========================================
echo -e "\n请输入节点名称后缀 (留空则默认):"
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

echo "请输入节点连接 IP 或 DDNS域名(留空默认取本机出口IP):"
read -r CUSTOM_IP
CUSTOM_IP="$(echo "$CUSTOM_IP" | tr -d '[:space:]')"

REALITY_SNI="addons.mozilla.org"
if $ENABLE_REALITY || $ENABLE_ANYTLS; then
    echo "请输入 Reality 的 SNI(留空默认 addons.mozilla.org):"
    read -r user_sni
    [ -n "$user_sni" ] && REALITY_SNI="$(echo "$user_sni" | tr -d '[:space:]')"
fi

# 生成端口密码
if $ENABLE_SS; then PORT_SS="$(rand_port)"; PSK_SS="$(rand_pass)"; fi
if $ENABLE_HY2; then PORT_HY2="$(rand_port)"; PSK_HY2="$(rand_pass)"; fi
if $ENABLE_TUIC; then PORT_TUIC="$(rand_port)"; PSK_TUIC="$(rand_pass)"; UUID_TUIC="$(rand_uuid)"; fi
if $ENABLE_REALITY; then PORT_REALITY="$(rand_port)"; UUID="$(rand_uuid)"; fi
if $ENABLE_ANYTLS; then PORT_ANYTLS="$(rand_port)"; ANYTLS_USER=$(openssl rand -hex 4 2>/dev/null || echo "user1"); ANYTLS_PSK=$(rand_pass); fi

# ==========================================
# 第三部分：下载核心与生成配置
# ==========================================
install_singbox() {
    info "开始安装 sing-box 核心..."
    if command -v sing-box >/dev/null 2>&1; then return 0; fi

    if [ "$OS" = "unknown" ] || [ "$OS" = "alpine" ]; then
        ARCH_RAW=$(uname -m)
        case "${ARCH_RAW}" in
            x86_64|amd64) ARCH="amd64" ;; aarch64|arm64) ARCH="arm64" ;;
            i386|i686) ARCH="386" ;; armv7*) ARCH="armv7" ;;
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
        if [ ! -f "${BIN}" ]; then err "下载失败"; exit 1; fi
        cp -f "${BIN}" /usr/bin/sing-box && chmod +x /usr/bin/sing-box
    else
        bash <(curl -fsSL https://sing-box.app/install.sh) >/dev/null 2>&1 || err "安装失败"
    fi
}
install_singbox

mkdir -p /etc/sing-box
if $ENABLE_REALITY || $ENABLE_ANYTLS; then
    info "生成 Reality 密钥对..."
    REALITY_KEYS=$(sing-box generate reality-keypair 2>&1)
    REALITY_PK=$(echo "$REALITY_KEYS" | grep "PrivateKey" | awk '{print $NF}' | tr -d '\r')
    REALITY_PUB=$(echo "$REALITY_KEYS" | grep "PublicKey" | awk '{print $NF}' | tr -d '\r')
    REALITY_SID=$(sing-box generate rand 8 --hex 2>&1)
fi

if $ENABLE_HY2 || $ENABLE_TUIC; then
    info "生成自签证书..."
    mkdir -p /etc/sing-box/certs
    openssl req -x509 -newkey rsa:2048 -nodes -keyout /etc/sing-box/certs/privkey.pem -out /etc/sing-box/certs/fullchain.pem -days 3650 -subj "/CN=www.bing.com" >/dev/null 2>&1 || true
fi

CONFIG_PATH="/etc/sing-box/config.json"
TEMP_INBOUNDS="/tmp/sb_in_$$.json"
> "$TEMP_INBOUNDS"
need_comma=false

if $ENABLE_SS; then
    cat >> "$TEMP_INBOUNDS" <<INBOUND_SS
    {
      "type": "shadowsocks", "tag": "ss-in", "listen": "::", "listen_port": $PORT_SS,
      "method": "$SS_METHOD", "password": "$PSK_SS"
    }
INBOUND_SS
    need_comma=true
fi

if $ENABLE_HY2; then
    $need_comma && echo "," >> "$TEMP_INBOUNDS"
    cat >> "$TEMP_INBOUNDS" <<INBOUND_HY2
    {
      "type": "hysteria2", "tag": "hy2-in", "listen": "::", "listen_port": $PORT_HY2,
      "users": [{ "password": "$PSK_HY2" }],
      "tls": { "enabled": true, "alpn": ["h3"], "certificate_path": "/etc/sing-box/certs/fullchain.pem", "key_path": "/etc/sing-box/certs/privkey.pem" }
    }
INBOUND_HY2
    need_comma=true
fi

if $ENABLE_TUIC; then
    $need_comma && echo "," >> "$TEMP_INBOUNDS"
    cat >> "$TEMP_INBOUNDS" <<INBOUND_TUIC
    {
      "type": "tuic", "tag": "tuic-in", "listen": "::", "listen_port": $PORT_TUIC,
      "users": [{ "uuid": "$UUID_TUIC", "password": "$PSK_TUIC" }],
      "congestion_control": "bbr",
      "tls": { "enabled": true, "alpn": ["h3"], "certificate_path": "/etc/sing-box/certs/fullchain.pem", "key_path": "/etc/sing-box/certs/privkey.pem" }
    }
INBOUND_TUIC
    need_comma=true
fi

if $ENABLE_ANYTLS; then
    $need_comma && echo "," >> "$TEMP_INBOUNDS"
    cat >> "$TEMP_INBOUNDS" <<INBOUND_ANYTLS
    {
      "type": "anytls", "tag": "anytls-in", "listen": "::", "listen_port": $PORT_ANYTLS,
      "users": [{ "name": "$ANYTLS_USER", "password": "$ANYTLS_PSK" }],
      "tls": { "enabled": true, "server_name": "$REALITY_SNI", "reality": {
          "enabled": true, "handshake": { "server": "$REALITY_SNI", "server_port": 443 },
          "private_key": "$REALITY_PK", "short_id": ["$REALITY_SID"] } }
    }
INBOUND_ANYTLS
    need_comma=true
fi

if $ENABLE_REALITY; then
    $need_comma && echo "," >> "$TEMP_INBOUNDS"
    cat >> "$TEMP_INBOUNDS" <<INBOUND_REALITY
    {
      "type": "vless", "tag": "vless-in", "listen": "::", "listen_port": $PORT_REALITY,
      "users": [{ "uuid": "$UUID", "flow": "xtls-rprx-vision" }],
      "tls": { "enabled": true, "server_name": "$REALITY_SNI", "reality": {
          "enabled": true, "handshake": { "server": "$REALITY_SNI", "server_port": 443 },
          "private_key": "$REALITY_PK", "short_id": ["$REALITY_SID"] } }
    }
INBOUND_REALITY
fi

cat > "$CONFIG_PATH" <<CONFIG_HEAD
{ "log": { "level": "info" }, "inbounds": [
CONFIG_HEAD
cat "$TEMP_INBOUNDS" >> "$CONFIG_PATH"
cat >> "$CONFIG_PATH" <<CONFIG_TAIL
  ], "outbounds": [{ "type": "direct", "tag": "direct-out" }] }
CONFIG_TAIL
rm -f "$TEMP_INBOUNDS"

# ==========================================
# 第四部分：生成控制面板并启动服务
# ==========================================
info "正在系统内部署 'sb' 管理面板..."
cat > /usr/bin/sb << 'SB_EOF'
#!/usr/bin/env bash
CONFIG="/etc/sing-box/config.json"

menu() {
    clear
    echo -e "\033[1;36m==================================\033[0m"
    echo -e "\033[1;32m   Sing-box 管理面板 (群晖/通用版)\033[0m"
    echo -e "\033[1;36m==================================\033[0m"
    echo "  1. 启动节点"
    echo "  2. 暂停/停止节点"
    echo "  3. 重启节点"
    echo "  4. 修改节点端口"
    echo "  5. 查看运行状态与当前端口"
    echo -e "\033[1;31m  6. 彻底卸载节点与面板\033[0m"
    echo "  0. 退出面板"
    echo -e "\033[1;36m==================================\033[0m"
    read -p "请输入选项 [0-6]: " opt
    case $opt in
        1) start_sb ;; 2) stop_sb ;; 3) stop_sb "no_menu"; sleep 1; start_sb ;;
        4) change_port ;; 5) show_status ;; 6) uninstall_sb ;; 0) exit 0 ;;
        *) echo "无效选项"; sleep 1; menu ;;
    esac
}

start_sb() {
    pkill -9 sing-box 2>/dev/null || true
    nohup /usr/bin/sing-box run -c $CONFIG >/dev/null 2>&1 &
    echo -e "\033[1;32m[INFO] 节点已启动，正在后台静默运行。\033[0m"
    if [ "${1:-}" != "no_menu" ]; then sleep 2; menu; fi
}

stop_sb() {
    pkill -9 sing-box 2>/dev/null || true
    echo -e "\033[1;33m[INFO] 节点已停止 (处于暂停状态)。\033[0m"
    if [ "${1:-}" != "no_menu" ]; then sleep 2; menu; fi
}

change_port() {
    echo -e "当前配置文件中的端口列表: "
    grep '"listen_port"' $CONFIG | grep -oE '[0-9]+'
    echo ""
    read -p "请输入你要修改的【旧端口号】: " OLD_PORT
    read -p "请输入修改后的【新端口号】 (10000-65535): " NEW_PORT
    if [[ "$NEW_PORT" =~ ^[0-9]+$ ]] && [[ "$OLD_PORT" =~ ^[0-9]+$ ]]; then
        sed -i "s/\"listen_port\":[ \t]*$OLD_PORT/\"listen_port\": $NEW_PORT/g" $CONFIG
        echo -e "\033[1;32m[INFO] 端口已成功修改为: $NEW_PORT\033[0m"
        echo "[INFO] 正在重启节点应用新端口..."
        stop_sb "no_menu"
        start_sb "no_menu"
    else
        echo -e "\033[1;31m[ERR] 端口格式错误，操作取消。\033[0m"
    fi
    read -p "按回车键返回菜单..."
    menu
}

show_status() {
    echo ""
    if pidof sing-box >/dev/null; then echo -e "当前运行状态: \033[1;32m[运行中]\033[0m"
    else echo -e "当前运行状态: \033[1;31m[已停止]\033[0m"; fi
    
    if [ -f "$CONFIG" ]; then
        echo -e "当前监听的所有端口: "
        grep '"listen_port"' $CONFIG | grep -oE '[0-9]+' | while read p; do echo -e "\033[1;36m$p\033[0m"; done
    fi
    echo ""
    read -p "按回车键返回菜单..." 
    menu
}

uninstall_sb() {
    read -p "⚠️ 确定要彻底卸载并清除节点数据吗？(y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        pkill -9 sing-box 2>/dev/null || true
        rm -rf /etc/sing-box /usr/bin/sing-box /usr/bin/sb
        echo -e "\033[1;32m[INFO] 核心与面板均已彻底卸载！\033[0m"
        exit 0
    else
        menu
    fi
}

# 命令行参数解析
if [ "${1:-}" == "start" ]; then start_sb "no_menu"
elif [ "${1:-}" == "stop" ]; then stop_sb "no_menu"
else menu
fi
SB_EOF

chmod +x /usr/bin/sb
info "管理面板部署完毕。正在通过面板启动节点..."
/usr/bin/sb start

# ==========================================
# 打印最终节点信息
# ==========================================
PUB_IP=${CUSTOM_IP:-$(curl -s https://api.ipify.org 2>/dev/null || echo "YOUR_IP")}
echo -e "\n\033[1;32m🎉 Sing-box 部署与管理面板双剑合璧完成！\033[0m\n"

if $ENABLE_SS; then
    echo "=== Shadowsocks (SS) 节点信息 ==="
    ss_userinfo="${SS_METHOD}:${PSK_SS}"
    ss_encoded=$(printf "%s" "$ss_userinfo" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
    echo "ss://${ss_encoded}@${PUB_IP}:${PORT_SS}#SS${suffix}"
    echo ""
fi

if $ENABLE_HY2; then
    echo "=== Hysteria2 (HY2) 节点信息 ==="
    hy2_encoded=$(printf "%s" "$PSK_HY2" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
    echo "hy2://${hy2_encoded}@${PUB_IP}:${PORT_HY2}/?sni=www.bing.com&alpn=h3&insecure=1#HY2${suffix}"
    echo ""
fi

if $ENABLE_TUIC; then
    echo "=== TUIC 节点信息 ==="
    tuic_encoded=$(printf "%s" "$PSK_TUIC" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
    echo "tuic://${UUID_TUIC}:${tuic_encoded}@${PUB_IP}:${PORT_TUIC}/?congestion_control=bbr&alpn=h3&sni=www.bing.com&insecure=1#TUIC${suffix}"
    echo ""
fi

if $ENABLE_ANYTLS; then
    echo "=== AnyTLS 节点链接 ==="
    anytls_pass_encoded=$(printf "%s" "$ANYTLS_PSK" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
    echo "anytls://${anytls_pass_encoded}@${PUB_IP}:${PORT_ANYTLS}/?security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#AnyTLS${suffix}"
    echo ""
fi

if $ENABLE_REALITY; then
    echo "=== VLESS Reality 节点链接 ==="
    echo "vless://${UUID}@${PUB_IP}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#Reality${suffix}"
    echo ""
fi

echo -e "\033[1;33m💡 重要提醒：请务必去路由器或群晖面板放行上述端口！\033[0m"
echo -e "\033[1;36m🚀 以后随时在终端输入 sb 并回车，即可呼出控制面板进行管理！\033[0m\n"
