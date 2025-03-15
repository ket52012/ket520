#!/bin/bash

# 显示菜单
echo "欢迎使用 Ket520 的 CentOS 指令库！"
echo "请选择一个功能："
echo "1. 安装节点面板 (x-ui)"
echo "2. 安装 BBR 加速"
echo "3. 关闭防火墙"
echo "4. 修复无法下载 GitHub 文件"
echo "0. 退出"
read -p "请输入选项 (0-4): " choice

# 根据选择执行对应功能
case $choice in
    1)
        echo "正在安装节点面板 (x-ui)..."
        bash <(curl -Ls https://raw.githubusercontent.com/vaxilu/x-ui/master/install.sh)
        echo "节点面板安装完成！"
        ;;
    2)
        echo "正在安装 BBR 加速..."
        wget -N --no-check-certificate "https://raw.githubusercontent.com/chiakge/Linux-NetSpeed/master/tcp.sh" && chmod +x tcp.sh && ./tcp.sh
        echo "BBR 加速安装完成！"
        ;;
    3)
        echo "正在关闭防火墙..."
        systemctl stop firewalld
        systemctl stop firewalld.service
        systemctl disable firewalld.service
        echo "防火墙已关闭！"
        ;;
    4)
        echo "正在修复 GitHub 文件下载问题..."
        sudo sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*
        sudo sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*
        echo "修复完成，请尝试再次下载！"
        ;;
    0)
        echo "退出脚本，谢谢使用！"
        exit 0
        ;;
    *)
        echo "无效选项，请输入 0-4 之间的数字！"
        exit 1
        ;;
esac
