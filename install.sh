#!/bin/bash

set -e

FRP_INSTALL_DIR="/opt/frp"
SYSTEMD_DIR="/etc/systemd/system"
FRPS_SERVICE="${SYSTEMD_DIR}/frps.service"
FRPC_SERVICE="${SYSTEMD_DIR}/frpc.service"
ROLE_FILE="$FRP_INSTALL_DIR/.frp_role"

get_arch() {
    case "$(uname -m)" in
        x86_64) echo "amd64";;
        aarch64) echo "arm64";;
        armv7*|armv6*) echo "arm";;
        *) echo "amd64";;
    esac
}

get_latest_ver() {
    curl -sL https://api.github.com/repos/fatedier/frp/releases/latest | grep tag_name | cut -d '"' -f 4 | sed 's/v//'
}

# 角色选择和记忆
select_role() {
    clear
    mkdir -p $FRP_INSTALL_DIR
    echo "请选择本机角色："
    echo "1) 安装/管理 FRPS（服务端, 推荐在 VPS/公网服务器运行）"
    echo "2) 安装/管理 FRPC（客户端, 用于需要被穿透的内网设备）"
    read -p "输入 1 或 2 并回车: " role
    case $role in
        1) echo "server" > $ROLE_FILE ;;
        2) echo "client" > $ROLE_FILE ;;
        *) echo "输入无效，请重新运行脚本！"; exit 1 ;;
    esac
}

# 安装、卸载通用
install_frp() {
    echo "正在安装 FRP..."
    mkdir -p $FRP_INSTALL_DIR
    cd $FRP_INSTALL_DIR
    FRP_VER=$(get_latest_ver)
    ARCH=$(get_arch)
    FRP_NAME="frp_${FRP_VER}_linux_${ARCH}"
    wget -O "${FRP_NAME}.tar.gz" "https://github.com/fatedier/frp/releases/download/v${FRP_VER}/${FRP_NAME}.tar.gz"
    tar -xzvf "${FRP_NAME}.tar.gz"
    cp -f ${FRP_NAME}/frps /usr/local/bin/
    cp -f ${FRP_NAME}/frpc /usr/local/bin/
    chmod +x /usr/local/bin/frps /usr/local/bin/frpc
    echo "FRP 安装完成。"
}

uninstall_frp() {
    echo "卸载 FRP..."
    systemctl stop frps frpc || true
    systemctl disable frps frpc || true
    rm -rf /usr/local/bin/frps /usr/local/bin/frpc
    rm -rf $FRP_INSTALL_DIR
    rm -f $FRPS_SERVICE $FRPC_SERVICE
    systemctl daemon-reload
    echo "FRP 已卸载完成。"
    rm -f $ROLE_FILE
}

# 仅服务端相关
generate_frps_config() {
    cat > $FRP_INSTALL_DIR/frps.ini <<EOF
[common]
bind_port = 7000
dashboard_port = 7500
dashboard_user = admin
dashboard_pwd = admin123
EOF
    echo "已生成/覆盖 frps 配置: $FRP_INSTALL_DIR/frps.ini"
}

write_frps_service() {
    cat > $FRPS_SERVICE <<EOF
[Unit]
Description=frps
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frps -c $FRP_INSTALL_DIR/frps.ini
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    echo "frps systemd 启动项已写入: $FRPS_SERVICE"
    systemctl daemon-reload
}

show_frps_status() {
    systemctl status frps --no-pager || echo "frps 未安装/未运行"
}

show_frps_log() {
    journalctl -u frps -n 50 --no-pager
}

edit_frps_config() {
    vi $FRP_INSTALL_DIR/frps.ini
}

# 仅客户端相关
generate_frpc_config() {
    read -p "请输入 frps 服务器IP: " SERVER_IP
    read -p "请输入 frps 端口（默认7000）: " SERVER_PORT
    SERVER_PORT=${SERVER_PORT:-7000}
    cat > $FRP_INSTALL_DIR/frpc.ini <<EOF
[common]
server_addr = $SERVER_IP
server_port = $SERVER_PORT

[ssh]
type = tcp
local_ip = 127.0.0.1
local_port = 22
remote_port = 6000

[web]
type = tcp
local_ip = 127.0.0.1
local_port = 80
remote_port = 8000
EOF
    echo "已生成/覆盖 frpc 配置: $FRP_INSTALL_DIR/frpc.ini"
}

write_frpc_service() {
    cat > $FRPC_SERVICE <<EOF
[Unit]
Description=frpc
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frpc -c $FRP_INSTALL_DIR/frpc.ini
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    echo "frpc systemd 启动项已写入: $FRPC_SERVICE"
    systemctl daemon-reload
}

show_frpc_status() {
    systemctl status frpc --no-pager || echo "frpc 未安装/未运行"
}

show_frpc_log() {
    journalctl -u frpc -n 50 --no-pager
}

edit_frpc_config() {
    vi $FRP_INSTALL_DIR/frpc.ini
}

# 通用 start/stop/restart
start_frps() { systemctl start frps && echo "frps 已启动"; }
stop_frps() { systemctl stop frps && echo "frps 已停止"; }
restart_frps() { systemctl restart frps && echo "frps 已重启"; }

start_frpc() { systemctl start frpc && echo "frpc 已启动"; }
stop_frpc() { systemctl stop frpc && echo "frpc 已停止"; }
restart_frpc() { systemctl restart frpc && echo "frpc 已重启"; }

upgrade_frp() {
    echo "正在升级 FRP..."
    install_frp
    [[ -f $FRPS_SERVICE ]] && systemctl restart frps
    [[ -f $FRPC_SERVICE ]] && systemctl restart frpc
    echo "升级完成。"
}

switch_role() {
    rm -f $ROLE_FILE
    echo "已重置角色，脚本将重新选择。"
    exit 0
}

# 服务端菜单
server_menu() {
    while true; do
        clear
        echo -e "\e[32m==== NuroHia · FRP 服务端管理（当前: 服务端） ====\e[0m"
        echo "1) 一键安装/升级 FRPS"
        echo "2) 卸载 FRPS"
        echo "3) 生成/编辑 frps 配置"
        echo "4) 写入 frps systemd 启动项"
        echo "5) 启动 FRPS"
        echo "6) 停止 FRPS"
        echo "7) 重启 FRPS"
        echo "8) 查看 FRPS 状态"
        echo "9) 查看 FRPS 日志"
        echo "10) 切换为客户端菜单"
        echo "0) 退出"
        echo "-----------------------------"
        read -p "请选择 [0-10]: " choice
        case $choice in
            1) install_frp ;;
            2) uninstall_frp ;;
            3) generate_frps_config && edit_frps_config ;;
            4) write_frps_service ;;
            5) start_frps ;;
            6) stop_frps ;;
            7) restart_frps ;;
            8) show_frps_status ;;
            9) show_frps_log ;;
            10) switch_role ;;
            0) exit 0 ;;
            *) echo "无效选择，重新输入！" && sleep 1 ;;
        esac
        echo
        read -p "按回车返回菜单..."
    done
}

# 客户端菜单
client_menu() {
    while true; do
        clear
        echo -e "\e[36m==== NuroHia · FRP 客户端管理（当前: 客户端） ====\e[0m"
        echo "1) 一键安装/升级 FRPC"
        echo "2) 卸载 FRPC"
        echo "3) 生成/编辑 frpc 配置"
        echo "4) 写入 frpc systemd 启动项"
        echo "5) 启动 FRPC"
        echo "6) 停止 FRPC"
        echo "7) 重启 FRPC"
        echo "8) 查看 FRPC 状态"
        echo "9) 查看 FRPC 日志"
        echo "10) 切换为服务端菜单"
        echo "0) 退出"
        echo "-----------------------------"
        read -p "请选择 [0-10]: " choice
        case $choice in
            1) install_frp ;;
            2) uninstall_frp ;;
            3) generate_frpc_config && edit_frpc_config ;;
            4) write_frpc_service ;;
            5) start_frpc ;;
            6) stop_frpc ;;
            7) restart_frpc ;;
            8) show_frpc_status ;;
            9) show_frpc_log ;;
            10) switch_role ;;
            0) exit 0 ;;
            *) echo "无效选择，重新输入！" && sleep 1 ;;
        esac
        echo
        read -p "按回车返回菜单..."
    done
}

# 启动入口
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
