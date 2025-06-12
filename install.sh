#!/bin/bash

set -e

# 兼容 debian/ubuntu/centos
FRP_INSTALL_DIR="/opt/frp"
SYSTEMD_DIR="/etc/systemd/system"
FRPS_SERVICE="${SYSTEMD_DIR}/frps.service"
FRPC_SERVICE="${SYSTEMD_DIR}/frpc.service"

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
}

generate_frps_config() {
    cat > $FRP_INSTALL_DIR/frps.ini <<EOF
[common]
bind_port = 7000
dashboard_port = 7500
dashboard_user = admin
dashboard_pwd = admin123
EOF
}

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
}

show_status() {
    echo "------ FRPS 状态 ------"
    systemctl status frps --no-pager || echo "未安装/未运行"
    echo
    echo "------ FRPC 状态 ------"
    systemctl status frpc --no-pager || echo "未安装/未运行"
}

show_config() {
    echo "------ FRPS 配置 ------"
    [ -f $FRP_INSTALL_DIR/frps.ini ] && cat $FRP_INSTALL_DIR/frps.ini || echo "无"
    echo
    echo "------ FRPC 配置 ------"
    [ -f $FRP_INSTALL_DIR/frpc.ini ] && cat $FRP_INSTALL_DIR/frpc.ini || echo "无"
}

edit_config() {
    echo "1) 编辑 frps.ini"
    echo "2) 编辑 frpc.ini"
    read -p "选择要编辑的配置文件（1/2）: " CFG
    if [[ $CFG == 1 ]]; then
        vi $FRP_INSTALL_DIR/frps.ini
    else
        vi $FRP_INSTALL_DIR/frpc.ini
    fi
}

show_log() {
    echo "1) 查看 frps 日志"
    echo "2) 查看 frpc 日志"
    read -p "选择（1/2）: " CHOICE
    if [[ $CHOICE == 1 ]]; then
        journalctl -u frps -n 50 --no-pager
    else
        journalctl -u frpc -n 50 --no-pager
    fi
}

restart_frp() {
    echo "1) 重启 frps"
    echo "2) 重启 frpc"
    read -p "选择（1/2）: " R
    if [[ $R == 1 ]]; then
        systemctl restart frps && echo "frps 已重启"
    else
        systemctl restart frpc && echo "frpc 已重启"
    fi
}

stop_frp() {
    echo "1) 停止 frps"
    echo "2) 停止 frpc"
    read -p "选择（1/2）: " R
    if [[ $R == 1 ]]; then
        systemctl stop frps && echo "frps 已停止"
    else
        systemctl stop frpc && echo "frpc 已停止"
    fi
}

start_frp() {
    echo "1) 启动 frps"
    echo "2) 启动 frpc"
    read -p "选择（1/2）: " R
    if [[ $R == 1 ]]; then
        systemctl start frps && echo "frps 已启动"
    else
        systemctl start frpc && echo "frpc 已启动"
    fi
}

upgrade_frp() {
    echo "正在升级 FRP..."
    install_frp
    systemctl restart frps frpc || true
    echo "升级完成。"
}

main_menu() {
    while true; do
        clear
        echo -e "\e[32m==== NuroHia · FRP 一键管理脚本 ====\e[0m"
        echo "1) 一键安装/升级 FRP"
        echo "2) 卸载 FRP"
        echo "3) 初始化/生成 frps 配置"
        echo "4) 初始化/生成 frpc 配置"
        echo "5) 写入 frps systemd 服务"
        echo "6) 写入 frpc systemd 服务"
        echo "7) 启动 FRP"
        echo "8) 停止 FRP"
        echo "9) 重启 FRP"
        echo "10) 查看状态"
        echo "11) 查看配置"
        echo "12) 编辑配置"
        echo "13) 查看日志"
        echo "0) 退出"
        echo "-----------------------------"
        read -p "请选择 [0-13]: " choice
        case $choice in
            1) install_frp ;;
            2) uninstall_frp ;;
            3) generate_frps_config ;;
            4) generate_frpc_config ;;
            5) write_frps_service && systemctl daemon-reload ;;
            6) write_frpc_service && systemctl daemon-reload ;;
            7) start_frp ;;
            8) stop_frp ;;
            9) restart_frp ;;
            10) show_status ;;
            11) show_config ;;
            12) edit_config ;;
            13) show_log ;;
            0) exit 0 ;;
            *) echo "无效选择，重新输入！" && sleep 1 ;;
        esac
        echo
        read -p "按回车返回菜单..."
    done
}

main_menu
