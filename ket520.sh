 1  #!/bin/bash
 2
 3  # 显示菜单
 4  echo "欢迎使用 Ket520 的 CentOS 指令库！"
 5  echo "请选择一个功能："
 6  echo "1. 安装节点面板 (x-ui)"
 7  echo "2. 安装 BBR 加速"
 8  echo "3. 关闭防火墙"
 9  echo "4. 修复无法下载 GitHub 文件"
10  echo "0. 退出"
11  read -p "请输入选项 (0-4): " choice
12
13  # 根据选择执行对应功能
14  case $choice in
15      1)
16          echo "正在安装节点面板 (x-ui)..."
17          bash <(curl -Ls https://raw.githubusercontent.com/vaxilu/x-ui/master/install.sh)
18          echo "节点面板安装完成！"
19          ;;
20      2)
21          echo "正在安装 BBR 加速..."
22          wget -N --no-check-certificate "https://raw.githubusercontent.com/chiakge/Linux-NetSpeed/master/tcp.sh" && chmod +x tcp.sh && ./tcp.sh
23          echo "BBR 加速安装完成！"
24          ;;
25      3)
26          echo "正在关闭防火墙..."
27          systemctl stop firewalld
28          systemctl stop firewalld.service
29          systemctl disable firewalld.service
30          echo "防火墙已关闭！"
31          ;;
32      4)
33          echo "正在修复 GitHub 文件下载问题..."
34          sudo sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*
35          sudo sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*
36          echo "修复完成，请尝试再次下载！"
37          ;;
38      0)
39          echo "退出脚本，谢谢使用！"
40          exit 0
41          ;;
42      *)
43          echo "无效选项，请输入 0-4 之间的数字！"
44          exit 1
45          ;;
46  esac
