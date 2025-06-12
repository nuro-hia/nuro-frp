#!/bin/bash
set -e

FRP_INSTALL_DIR="/opt/frp"
FRPS_BIN="/usr/local/bin/frps"
FRPC_BIN="/usr/local/bin/frpc"
ROLE_FILE="$FRP_INSTALL_DIR/.frp_role"
INIT_FLAG="$FRP_INSTALL_DIR/.frp_inited"
IS_OPENWRT=0

is_openwrt() { [ -f /etc/openwrt_release ] && IS_OPENWRT=1 || IS_OPENWRT=0; }
is_openwrt

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

# 仅依赖标记文件判定角色
detect_role() {
    [ -f "$ROLE_FILE" ] && cat "$ROLE_FILE" || echo "unknown"
}
# 检查是否已初始化
is_inited() { [ -f "$INIT_FLAG" ]; }

select_role() {
    clear
    echo -e "\e[33m[自动检测] 当前本机未检测到已初始化的 FRP 服务端或客户端。\e[0m"
    echo "请选择本机角色："
    echo "1) FRPS 服务端 (用于公网VPS)"
    echo "2) FRPC 客户端 (用于内网/被穿透设备)"
    read -p "输入 1 或 2 并回车: " role
    mkdir -p "$FRP_INSTALL_DIR"
    case $role in
        1) echo "server" > $ROLE_FILE ;;
        2) echo "client" > $ROLE_FILE ;;
        *) echo "输入无效，重新运行脚本"; exit 1 ;;
    esac
}

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
    echo -e "\e[33m请务必‘初始化配置并启动’，否则菜单其他功能不可用。\e[0m"
}

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
    rm -f "$ROLE_FILE" "$INIT_FLAG"
}

# -------- 服务端配置+启动 --------
init_frps_and_start() {
    echo "=== 初始化 FRPS 配置并启动 ==="
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

    if [ "$IS_OPENWRT" = "1" ]; then
        write_initd_frps
        /etc/init.d/frps restart
    else
        write_systemd_frps
        systemctl restart frps
        systemctl enable frps
    fi
    echo "server" > "$ROLE_FILE"
    touch "$INIT_FLAG"

    echo -e "\n\033[32m[FRPS 配置&启动完成！]\033[0m"
    cat $FRP_INSTALL_DIR/frps.ini
    echo -e "\n管理面板: http://$(hostname -I | awk '{print $1}'):$DASH_PORT"
    echo "用户名: $DASH_USER  密码: $DASH_PWD"
    [ -n "$FRP_TOKEN" ] && echo "Token: $FRP_TOKEN"
    echo -e "\n【重要】请在防火墙/安全组开放 $BIND_PORT 和 $DASH_PORT 端口"
    read -p "按回车返回菜单..."
}

# -------- 客户端配置+启动 --------
init_frpc_and_start() {
    echo "=== 初始化 FRPC 公共参数 ==="
    read -p "frps 服务器IP: " SERVER_IP
    while [[ -z "$SERVER_IP" ]]; do
        read -p "frps 服务器IP不能为空，请重新输入: " SERVER_IP
    done
    read -p "frps 端口 [默认7000]: " SERVER_PORT
    SERVER_PORT=${SERVER_PORT:-7000}
    read -p "Token（如服务端设置了token则需填写）: " FRP_TOKEN

    cat > $FRP_INSTALL_DIR/frpc.ini <<EOF
[common]
server_addr = $SERVER_IP
server_port = $SERVER_PORT
EOF
    [[ -n "$FRP_TOKEN" ]] && echo "token = $FRP_TOKEN" >> $FRP_INSTALL_DIR/frpc.ini

    if [ "$IS_OPENWRT" = "1" ]; then
        write_initd_frpc
        /etc/init.d/frpc restart
    else
        write_systemd_frpc
        systemctl restart frpc
        systemctl enable frpc
    fi
    echo "client" > "$ROLE_FILE"
    touch "$INIT_FLAG"
    echo -e "\n已初始化 FRPC 公共参数，可以通过菜单添加端口规则！"
    read -p "按回车返回菜单..."
}

add_frpc_rule() {
    is_inited || { echo -e "\e[31m请先初始化配置并启动 FRPC！\e[0m"; sleep 2; return; }
    echo "=== 添加 FRPC 端口规则 ==="
    while true; do
        read -p "规则名称（如 nas、ssh1、web80 等）: " RULE_NAME
        read -p "类型 (tcp/udp) [tcp]: " TYPE
        TYPE=${TYPE:-tcp}
        read -p "本地IP [127.0.0.1]: " LOCAL_IP
        LOCAL_IP=${LOCAL_IP:-127.0.0.1}
        read -p "本地端口: " LOCAL_PORT
        read -p "VPS端口: " REMOTE_PORT

        cat >> $FRP_INSTALL_DIR/frpc.ini <<EOF

[$RULE_NAME]
type = $TYPE
local_ip = $LOCAL_IP
local_port = $LOCAL_PORT
remote_port = $REMOTE_PORT
EOF

        echo -e "\033[32m已添加 [$RULE_NAME] 规则。\033[0m"
        read -p "是否继续添加规则？(y/n) [n]: " MORE
        [[ "$MORE" == "y" || "$MORE" == "Y" ]] || break
    done
    restart_frpc
}

view_frpc_rules() {
    is_inited || { echo -e "\e[31m请先初始化配置并启动 FRPC！\e[0m"; sleep 2; return; }
    echo -e "\n\033[36m[当前 FRPC 规则]\033[0m"
    awk '/^\[.*\]/{print "\n" $0} !/^\[.*\]/{print $0}' $FRP_INSTALL_DIR/frpc.ini
    echo
    read -p "按回车返回菜单..."
}

delete_frpc_rule() {
    is_inited || { echo -e "\e[31m请先初始化配置并启动 FRPC！\e[0m"; sleep 2; return; }
    view_frpc_rules
    read -p "输入要删除的规则名称（如web、nas）: " RULE
    sed -i "/^\[$RULE\]/,/^\[/ { /^\[/!d }" $FRP_INSTALL_DIR/frpc.ini
    sed -i "/^\[$RULE\]/d" $FRP_INSTALL_DIR/frpc.ini
    echo "已删除规则 [$RULE]"
    restart_frpc
    sleep 1
}

# -------- 服务操作 --------
start_frps() { is_inited || { echo -e "\e[31m请先初始化配置并启动 FRPS！\e[0m"; sleep 2; return; }
    [ "$IS_OPENWRT" = "1" ] && /etc/init.d/frps start || systemctl start frps; echo "frps 已启动"; sleep 1; }
stop_frps()  { is_inited || { echo -e "\e[31m请先初始化配置并启动 FRPS！\e[0m"; sleep 2; return; }
    [ "$IS_OPENWRT" = "1" ] && /etc/init.d/frps stop  || systemctl stop frps;  echo "frps 已停止"; sleep 1; }
restart_frps() { is_inited || { echo -e "\e[31m请先初始化配置并启动 FRPS！\e[0m"; sleep 2; return; }
    [ "$IS_OPENWRT" = "1" ] && /etc/init.d/frps restart || systemctl restart frps; echo "frps 已重启"; sleep 1; }
status_frps() {
    is_inited || { echo -e "\e[31m请先初始化配置并启动 FRPS！\e[0m"; sleep 2; return; }
    if [ "$IS_OPENWRT" = "1" ]; then
        ps | grep [f]rps || echo "frps 进程未启动"
    else
        systemctl status frps --no-pager | head -20
    fi
    echo -e "\n\033[32m[当前配置]\033[0m"
    cat $FRP_INSTALL_DIR/frps.ini 2>/dev/null || echo "未找到配置文件"
    echo
}

log_frps() {
    is_inited || { echo -e "\e[31m请先初始化配置并启动 FRPS！\e[0m"; sleep 2; return; }
    if [ "$IS_OPENWRT" = "1" ]; then
        logread | grep frps | tail -n 30 || echo "OpenWrt 无日志"
    else
        journalctl -u frps -n 50 --no-pager
    fi
    read -p "按回车返回菜单..."
}

start_frpc() { is_inited || { echo -e "\e[31m请先初始化配置并启动 FRPC！\e[0m"; sleep 2; return; }
    [ "$IS_OPENWRT" = "1" ] && /etc/init.d/frpc start || systemctl start frpc; echo "frpc 已启动"; sleep 1; }
stop_frpc()  { is_inited || { echo -e "\e[31m请先初始化配置并启动 FRPC！\e[0m"; sleep 2; return; }
    [ "$IS_OPENWRT" = "1" ] && /etc/init.d/frpc stop  || systemctl stop frpc;  echo "frpc 已停止"; sleep 1; }
restart_frpc() { is_inited || { echo -e "\e[31m请先初始化配置并启动 FRPC！\e[0m"; sleep 2; return; }
    [ "$IS_OPENWRT" = "1" ] && /etc/init.d/frpc restart || systemctl restart frpc; echo "frpc 已重启"; sleep 1; }
status_frpc() {
    is_inited || { echo -e "\e[31m请先初始化配置并启动 FRPC！\e[0m"; sleep 2; return; }
    if [ "$IS_OPENWRT" = "1" ]; then
        ps | grep [f]rpc || echo "frpc 进程未启动"
    else
        systemctl status frpc --no-pager | head -20
    fi
    echo -e "\n\033[36m[当前配置]\033[0m"
    cat $FRP_INSTALL_DIR/frpc.ini 2>/dev/null || echo "未找到配置文件"
    echo
}

show_frps_dashboard_info() {
    is_inited || { echo -e "\e[31m请先初始化配置并启动 FRPS！\e[0m"; sleep 2; return; }
    echo -e "\n\033[32m[FRPS 面板信息/当前配置]\033[0m"
    if [ -f $FRP_INSTALL_DIR/frps.ini ]; then
        local DASH_PORT DASH_USER DASH_PWD FRP_TOKEN
        DASH_PORT=$(awk -F'=' '/dashboard_port/{gsub(/ /,"",$2);print $2}' $FRP_INSTALL_DIR/frps.ini)
        DASH_USER=$(awk -F'=' '/dashboard_user/{gsub(/ /,"",$2);print $2}' $FRP_INSTALL_DIR/frps.ini)
        DASH_PWD=$(awk -F'=' '/dashboard_pwd/{gsub(/ /,"",$2);print $2}' $FRP_INSTALL_DIR/frps.ini)
        FRP_TOKEN=$(awk -F'=' '/token/{gsub(/ /,"",$2);print $2}' $FRP_INSTALL_DIR/frps.ini)
        [ -z "$DASH_PORT" ] && DASH_PORT="7500"
        [ -z "$DASH_USER" ] && DASH_USER="admin"
        [ -z "$DASH_PWD" ] && DASH_PWD="admin123"
        local DASH_IP
        DASH_IP=$(hostname -I | awk '{print $1}')
        echo -e "面板访问地址：\033[36mhttp://$DASH_IP:$DASH_PORT\033[0m"
        echo -e "用户名：\033[33m$DASH_USER\033[0m"
        echo -e "密码：\033[33m$DASH_PWD\033[0m"
        [ -n "$FRP_TOKEN" ] && echo -e "Token：\033[33m$FRP_TOKEN\033[0m"
        echo
        echo "完整配置："
        cat $FRP_INSTALL_DIR/frps.ini
    else
        echo "未找到配置文件 $FRP_INSTALL_DIR/frps.ini"
    fi
    echo
    read -p "按回车返回菜单..."
}

log_frpc() {
    is_inited || { echo -e "\e[31m请先初始化配置并启动 FRPC！\e[0m"; sleep 2; return; }
    if [ "$IS_OPENWRT" = "1" ]; then
        logread | grep frpc | tail -n 30 || echo "OpenWrt 无日志"
    else
        journalctl -u frpc -n 50 --no-pager
    fi
    read -p "按回车返回菜单..."
}

# ------------------- 服务端菜单 -------------------
server_menu() {
    while true; do
        clear
        echo -e "\e[32m==== NuroHia · FRP 服务端菜单（自动适配 OpenWrt/Linux）====\e[0m"
        echo "1) 一键安装/升级 FRPS"
        echo "2) 初始化配置并启动"
        echo "3) 停止 FRPS"
        echo "4) 重启 FRPS"
        echo "5) 查看 FRPS 状态"
        echo "6) 查看 面板信息/配置"
        echo "7) 查看 FRPS 日志"
        echo "8) 卸载 FRPS"
        echo "0) 退出"
        echo "-----------------------------"
        read -p "请选择 [0-8]: " choice
        case $choice in
            1) install_frp ;;
            2) init_frps_and_start ;;
            3) stop_frps ;;
            4) restart_frps ;;
            5) status_frps; read -p "按回车返回菜单..." ;;
            6) show_frps_dashboard_info ;;
            7) log_frps ;;
            8) uninstall_frp ;;
            0) exit 0 ;;
            *) echo "无效选择，重新输入！" && sleep 1 ;;
        esac
    done
}

# ------------------- 客户端菜单 -------------------
client_menu() {
    while true; do
        clear
        echo -e "\e[36m==== NuroHia · FRP 客户端菜单（多规则+自动适配 OpenWrt/Linux） ====\e[0m"
        echo "1) 一键安装/升级 FRPC"
        echo "2) 初始化配置并启动"
        echo "3) 新增端口转发规则"
        echo "4) 删除端口转发规则"
        echo "5) 查看所有端口规则"
        echo "6) 停止 FRPC"
        echo "7) 重启 FRPC"
        echo "8) 查看 FRPC 状态"
        echo "9) 查看 FRPC 日志"
        echo "10) 卸载 FRPC"
        echo "0) 退出"
        echo "-----------------------------"
        read -p "请选择 [0-10]: " choice
        case $choice in
            1) install_frp ;;
            2) init_frpc_and_start ;;
            3) add_frpc_rule ;;
            4) delete_frpc_rule ;;
            5) view_frpc_rules ;;
            6) stop_frpc ;;
            7) restart_frpc ;;
            8) status_frpc; read -p "按回车返回菜单..." ;;
            9) log_frpc ;;
            10) uninstall_frp ;;
            0) exit 0 ;;
            *) echo "无效选择，重新输入！" && sleep 1 ;;
        esac
    done
}

# ---------- 启动入口，自动检测角色 ----------
role="$(detect_role)"
case "$role" in
    server) server_menu ;;
    client) client_menu ;;
    *)
        select_role
        role2="$(detect_role)"
        [ "$role2" = "server" ] && server_menu
        [ "$role2" = "client" ] && client_menu
        ;;
esac
