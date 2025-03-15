#!/bin/bash

# 子菜单函数：部署 RustDesk 服务和中继
rustdesk_menu() {
    echo "部署 RustDesk 服务和中继"
    echo "请选择一个功能："
    echo "1. 开放端口 (21115-21116/tcp, 21116/udp, 8000/tcp)"
    echo "2. 安装 RustDesk 服务和中继"
    echo "0. 返回主菜单"
    read -p "请输入选项 (0-2): " subchoice

    case $subchoice in
        1)
            echo "正在检查并安装 firewalld..."
            if ! command -v firewall-cmd &> /dev/null; then
                # 修复 yum 源，确保安装成功
                sudo sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*
                sudo sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*
                yum install -y firewalld
                if [ $? -ne 0 ]; then
                    echo "安装 firewalld 失败，请检查网络或 yum 配置！"
                    return
                fi
            fi
            echo "正在开放指定端口..."
            systemctl start firewalld
            systemctl enable firewalld
            firewall-cmd --permanent --add-port=21115-21116/tcp
            firewall-cmd --permanent --add-port=21116/udp
            firewall-cmd --permanent --add-port=8000/tcp
            firewall-cmd --reload
            echo "端口已开放：21115-21116/tcp, 21116/udp, 8000/tcp"
            ;;
        2)
            echo "正在安装 RustDesk 服务和中继..."
            wget https://raw.githubusercontent.com/techahold/rustdeskinstall/master/install.sh
            chmod +x install.sh
            # 自动输入 1（选择 IP），1（下载配置和 HTTP 服务器），回车结束
            (echo "1"; echo "1"; echo "") | ./install.sh 2>&1 | tee rustdesk_install.log
            echo "安装完成！"
            echo "提取并显示关键信息..."
            # 获取 IP
            IP=$(grep -i "Your IP/DNS Address is" rustdesk_install.log | awk '{print $4}')
            if [ -n "$IP" ]; then
                echo "你的 IP 地址是：$IP"
            else
                echo "未找到 IP 地址，请检查安装日志。"
            fi
            # 获取 Key
            KEY=$(grep -i "Your public key is" rustdesk_install.log | awk -F'= ' '{print $2}')
            if [ -n "$KEY" ]; then
                echo "你的 RustDesk 公钥是：$KEY"
            else
                echo "未找到公钥，请检查安装日志。"
                cat rustdesk_install.log
            fi
            # 清理临时文件
            rm -f install.sh rustdesk_install.log
            ;;
        0)
            echo "返回主菜单..."
            return
            ;;
        *)
            echo "无效选项，请输入 0-2 之间的数字！"
            ;;
    esac
}

# 主菜单
echo "欢迎使用 Ket520 的 CentOS 指令库！"
echo "请选择一个功能："
echo "1. 安装节点面板 (x-ui)"
echo "2. 安装 BBR 加速"
echo "3. 关闭防火墙"
echo "4. 修复无法下载 GitHub 文件"
echo "5. 部署 RustDesk 服务和中继"
echo "0. 退出"
read -p "请输入选项 (0-5): " choice

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
    5)
        rustdesk_menu
        ;;
    0)
        echo "退出脚本，谢谢使用！"
        exit 0
        ;;
    *)
        echo "无效选项，请输入 0-5 之间的数字！"
        exit 1
        ;;
esac
