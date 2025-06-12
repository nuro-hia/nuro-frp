#!/bin/bash
set -e

FRP_INSTALL_DIR="/opt/frp"
ROLE_FILE="$FRP_INSTALL_DIR/.frp_role"
FRPS_BIN="/usr/local/bin/frps"
FRPC_BIN="/usr/local/bin/frpc"
IS_OPENWRT=0

# --------- 平台识别 ---------
is_openwrt() {
    [ -f /etc/openwrt_release ] && IS_OPENWRT=1 || IS_OPENWRT=0
}
is_openwrt

# --------- 架构/版本获取 ---------
get_arch() {
    case "$(uname -m)" in
        x86_64) echo "amd64";;
        aarch64) echo "arm64";;
        armv7*|armv6*) echo "arm";;
        mipsel) echo "mipsle";;
        mips) echo "mips";;
        *) echo "amd64";;
    esac
}

get_latest_ver() {
    curl -sL https://api.github.com/repos/fatedier/frp/releases/latest | grep tag_name | cut -d '"' -f 4 | sed 's/v//'
}

# --------- 角色选择 ---------
select_role() {
    clear
    mkdir -p $FRP_INSTALL_DIR
    echo "请选择本机角色："
    echo "1) FRPS 服务端 (用于公网VPS)"
    echo "2) FRPC 客户端 (用于内网/被穿透设备)"
    read -p "输入 1 或 2 并回车: " role
    case $role in
        1) echo "server" > $ROLE_FILE ;;
        2) echo "client" > $ROLE_FILE ;;
        *) echo "输入无效，重新运行脚本"; exit 1 ;;
    esac
}

# --------- 安装FRP ---------
install_frp() {
    echo "正在安装 FRP..."
    mkdir -p $FRP_INSTALL_DIR
    cd $FRP_INSTALL_DIR
    FRP_VER=$(get_latest_ver)
    ARCH=$(get_arch)
    FRP_NAME="frp_${FRP_VER}_linux_${ARCH}"
    wget -O "${FRP_NAME}.tar.gz" "https://github.com/fatedier/frp/releases/download/v${FRP_VER}/${FRP_NAME}.tar.gz"
    tar -xzvf "${FRP_NAME}.tar.gz"
    cp -f ${FRP_NAME}/frps $FRPS_BIN
    cp -f ${FRP_NAME}/frpc $FRPC_BIN
    chmod +x $FRPS_BIN $FRPC_BIN
    echo "FRP 安装完成。"
}

# --------- OpenWrt守护脚本 ---------
write_initd_frps() {
cat > /etc/init.d/frps <<'EOF'
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1
PROG=/usr/local/bin/frps
CFG=/opt/frp/frps.ini

start_service() {
    procd_open_instance
    procd_set_param command $PROG -c $CFG
    procd_set_param respawn
    procd_close_instance
}
EOF
chmod +x /etc/init.d/frps
/etc/init.d/frps enable
}

write_initd_frpc() {
cat > /etc/init.d/frpc <<'EOF'
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1
PROG=/usr/local/bin/frpc
CFG=/opt/frp/frpc.ini

start_service() {
    procd_open_instance
    procd_set_param command $PROG -c $CFG
    procd_set_param respawn
    procd_close_instance
}
EOF
chmod +x /etc/init.d/frpc
/etc/init.d/frpc enable
}

# --------- Systemd 守护脚本 ---------
write_systemd_frps() {
cat > /etc/systemd/system/frps.service <<EOF
[Unit]
Description=frps
After=network.target

[Service]
Type=simple
ExecStart=$FRPS_BIN -c $FRP_INSTALL_DIR/frps.ini
Restart=always

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
}

write_systemd_frpc() {
cat > /etc/systemd/system/frpc.service <<EOF
[Unit]
Description=frpc
After=network.target

[Service]
Type=simple
ExecStart=$FRPC_BIN -c $FRP_INSTALL_DIR/frpc.ini
Restart=always

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
}

# --------- 卸载 ---------
uninstall_frp() {
    echo "卸载 FRP..."
    if [ "$IS_OPENWRT" = "1" ]; then
        /etc/init.d/frps stop 2>/dev/null || true
        /etc/init.d/frpc stop 2>/dev/null || true
        rm -f /etc/init.d/frps /etc/init.d/frpc
    else
        systemctl stop frps frpc || true
        systemctl disable frps frpc || true
        rm -f /etc/systemd/system/frps.service /etc/systemd/system/frpc.service
        systemctl daemon-reload
    fi
    rm -rf $FRP_INSTALL_DIR $FRPS_BIN $FRPC_BIN
    echo "FRP 已卸载完成。"
    rm -f $ROLE_FILE
}

# --------- 生成配置并自动启动 ---------
generate_and_run_frps() {
    echo "=== 请输入 FRPS 服务端配置参数（直接回车为默认）==="
    read -p "监听端口 [默认7000]: " BIND_PORT
    BIND_PORT=${BIND_PORT:-7000}
    read -p "面板端口 [默认7500]: " DASH_PORT
    DASH_PORT=${DASH_PORT:-7500}
    read -p "面板用户名 [默认admin]: " DASH_USER
    DASH_USER=${DASH_USER:-admin}
    read -p "面板密码 [默认admin123]: " DASH_PWD
    DASH_PWD=${DASH_PWD:-admin123}
    read -p "Token（可选，建议自定义加强安全）: " FRP_TOKEN

    cat > $FRP_INSTALL_DIR/frps.ini <<EOF
[common]
bind_port = $BIND_PORT
dashboard_port = $DASH_PORT
dashboard_user = $DASH_USER
dashboard_pwd = $DASH_PWD
EOF
    [[ -n "$FRP_TOKEN" ]] && echo "token = $FRP_TOKEN" >> $FRP_INSTALL_DIR/frps.ini

    # 写守护脚本
    if [ "$IS_OPENWRT" = "1" ]; then
        write_initd_frps
        /etc/init.d/frps restart
    else
        write_systemd_frps
        systemctl enable --now frps
    fi

    sleep 1
    clear
    echo -e "\n\033[32m[FRPS] 启动完成，当前配置如下：\033[0m"
    cat $FRP_INSTALL_DIR/frps.ini
    echo
    echo "服务状态："
    status_frps
    echo -e "\n管理面板: http://$(hostname -I | awk '{print $1}'):$DASH_PORT"
    echo "用户名: $DASH_USER  密码: $DASH_PWD"
    [ -n "$FRP_TOKEN" ] && echo "Token: $FRP_TOKEN"
    echo -e "\n【重要】请在防火墙/安全组开放 $BIND_PORT 和 $DASH_PORT 端口"
    read -p "按回车返回菜单..."
}

generate_and_run_frpc() {
    echo "=== 请输入 FRPC 客户端配置参数 ==="
    read -p "frps 服务器IP: " SERVER_IP
    while [[ -z "$SERVER_IP" ]]; do
        read -p "frps 服务器IP不能为空，请重新输入: " SERVER_IP
    done
    read -p "frps 端口 [默认7000]: " SERVER_PORT
    SERVER_PORT=${SERVER_PORT:-7000}
    read -p "Token（如服务端设置了token则需填写）: " FRP_TOKEN

    echo "现在配置要穿透的服务（可多选，至少选一个）："
    local sections=""
    read -p "穿透SSH服务？(y/n) [y]: " ADD_SSH
    ADD_SSH=${ADD_SSH:-y}
    if [[ "$ADD_SSH" == "y" || "$ADD_SSH" == "Y" ]]; then
        read -p "本地SSH端口 [默认22]: " LOCAL_SSH
        LOCAL_SSH=${LOCAL_SSH:-22}
        read -p "frps映射端口 [默认6000]: " REMOTE_SSH
        REMOTE_SSH=${REMOTE_SSH:-6000}
        sections+="
[ssh]
type = tcp
local_ip = 127.0.0.1
local_port = $LOCAL_SSH
remote_port = $REMOTE_SSH
"
    fi

    read -p "穿透Web服务？(y/n) [y]: " ADD_WEB
    ADD_WEB=${ADD_WEB:-y}
    if [[ "$ADD_WEB" == "y" || "$ADD_WEB" == "Y" ]]; then
        read -p "本地Web端口 [默认80]: " LOCAL_WEB
        LOCAL_WEB=${LOCAL_WEB:-80}
        read -p "frps映射端口 [默认8000]: " REMOTE_WEB
        REMOTE_WEB=${REMOTE_WEB:-8000}
        sections+="
[web]
type = tcp
local_ip = 127.0.0.1
local_port = $LOCAL_WEB
remote_port = $REMOTE_WEB
"
    fi

    cat > $FRP_INSTALL_DIR/frpc.ini <<EOF
[common]
server_addr = $SERVER_IP
server_port = $SERVER_PORT
EOF
    [[ -n "$FRP_TOKEN" ]] && echo "token = $FRP_TOKEN" >> $FRP_INSTALL_DIR/frpc.ini
    echo "$sections" >> $FRP_INSTALL_DIR/frpc.ini

    if [ "$IS_OPENWRT" = "1" ]; then
        write_initd_frpc
        /etc/init.d/frpc restart
    else
        write_systemd_frpc
        systemctl enable --now frpc
    fi

    sleep 1
    clear
    echo -e "\n\033[36m[FRPC] 启动完成，当前配置如下：\033[0m"
    cat $FRP_INSTALL_DIR/frpc.ini
    echo
    echo "服务状态："
    status_frpc
    echo -e "\n【用法举例】"
    [[ "$ADD_SSH" == "y" || "$ADD_SSH" == "Y" ]] && echo "外网可用 ssh 用户名@<VPS_IP> -p $REMOTE_SSH 访问内网SSH"
    [[ "$ADD_WEB" == "y" || "$ADD_WEB" == "Y" ]] && echo "外网可用 http://<VPS_IP>:$REMOTE_WEB 访问内网Web服务"
    read -p "按回车返回菜单..."
}

# --------- 状态&日志 ---------
status_frps() {
    if [ "$IS_OPENWRT" = "1" ]; then
        ps | grep [f]rps || echo "frps 进程未启动"
    else
        systemctl status frps --no-pager | head -20
    fi
    echo -e "\n\033[32m[当前配置]\033[0m"
    cat $FRP_INSTALL_DIR/frps.ini 2>/dev/null || echo "未找到配置文件"
    grep '^bind_port' $FRP_INSTALL_DIR/frps.ini 2>/dev/null | awk -F '=' '{print "监听端口: " $2}'
    grep '^dashboard_port' $FRP_INSTALL_DIR/frps.ini 2>/dev/null | awk -F '=' '{print "管理面板端口: " $2}'
    echo
}

status_frpc() {
    if [ "$IS_OPENWRT" = "1" ]; then
        ps | grep [f]rpc || echo "frpc 进程未启动"
    else
        systemctl status frpc --no-pager | head -20
    fi
    echo -e "\n\033[36m[当前配置]\033[0m"
    cat $FRP_INSTALL_DIR/frpc.ini 2>/dev/null || echo "未找到配置文件"
    echo
}

log_frps() {
    if [ "$IS_OPENWRT" = "1" ]; then
        logread | grep frps | tail -n 30 || echo "OpenWrt 无日志"
    else
        journalctl -u frps -n 50 --no-pager
    fi
    read -p "按回车返回菜单..."
}

log_frpc() {
    if [ "$IS_OPENWRT" = "1" ]; then
        logread | grep frpc | tail -n 30 || echo "OpenWrt 无日志"
    else
        journalctl -u frpc -n 50 --no-pager
    fi
    read -p "按回车返回菜单..."
}

stop_frps() {
    [ "$IS_OPENWRT" = "1" ] && /etc/init.d/frps stop || systemctl stop frps
    echo "frps 已停止"
    sleep 1
}
restart_frps() {
    [ "$IS_OPENWRT" = "1" ] && /etc/init.d/frps restart || systemctl restart frps
    echo "frps 已重启"
    sleep 1
}
stop_frpc() {
    [ "$IS_OPENWRT" = "1" ] && /etc/init.d/frpc stop || systemctl stop frpc
    echo "frpc 已停止"
    sleep 1
}
restart_frpc() {
    [ "$IS_OPENWRT" = "1" ] && /etc/init.d/frpc restart || systemctl restart frpc
    echo "frpc 已重启"
    sleep 1
}

# ------------------- 菜单 -------------------
server_menu() {
    while true; do
        clear
        echo -e "\e[32m==== NuroHia · FRP 服务端菜单（自动适配 OpenWrt/Linux） ====\e[0m"
        echo "1) 一键安装/升级 FRPS"
        echo "2) 配置并启动 FRPS"
        echo "3) 停止 FRPS"
        echo "4) 重启 FRPS"
        echo "5) 查看 FRPS 状态"
        echo "6) 查看 FRPS 日志"
        echo "7) 卸载 FRPS"
        echo "8) 切换为客户端菜单"
        echo "0) 退出"
        echo "-----------------------------"
        read -p "请选择 [0-8]: " choice
        case $choice in
            1) install_frp ;;
            2) generate_and_run_frps ;;
            3) stop_frps ;;
            4) restart_frps ;;
            5) status_frps; read -p "按回车返回菜单..." ;;
            6) log_frps ;;
            7) uninstall_frp ;;
            8) rm -f $ROLE_FILE; exec "$0" ;;
            0) exit 0 ;;
            *) echo "无效选择，重新输入！" && sleep 1 ;;
        esac
    done
}

client_menu() {
    while true; do
        clear
        echo -e "\e[36m==== NuroHia · FRP 客户端菜单（自动适配 OpenWrt/Linux） ====\e[0m"
        echo "1) 一键安装/升级 FRPC"
        echo "2) 配置并启动 FRPC"
        echo "3) 停止 FRPC"
        echo "4) 重启 FRPC"
        echo "5) 查看 FRPC 状态"
        echo "6) 查看 FRPC 日志"
        echo "7) 卸载 FRPC"
        echo "8) 切换为服务端菜单"
        echo "0) 退出"
        echo "-----------------------------"
        read -p "请选择 [0-8]: " choice
        case $choice in
            1) install_frp ;;
            2) generate_and_run_frpc ;;
            3) stop_frpc ;;
            4) restart_frpc ;;
            5) status_frpc; read -p "按回车返回菜单..." ;;
            6) log_frpc ;;
            7) uninstall_frp ;;
            8) rm -f $ROLE_FILE; exec "$0" ;;
            0) exit 0 ;;
            *) echo "无效选择，重新输入！" && sleep 1 ;;
        esac
    done
}

if [ ! -f $ROLE_FILE ]; then
    select_role
fi
ROLE=$(cat $ROLE_FILE 2>/dev/null)
if [[ "$ROLE" == "server" ]]; then
    server_menu
elif [[ "$ROLE" == "client" ]]; then
    client_menu
else
    select_role
fi
