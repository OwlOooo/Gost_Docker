#!/bin/bash

# Colors
COLOR_ERROR="\e[38;5;198m"
COLOR_NONE="\e[0m"
COLOR_SUCC="\e[92m"

# 检测系统类型和版本
check_sys() {
    # 判断是什么系统
    if grep -Eqi "CentOS" /etc/issue || grep -Eq "CentOS" /etc/*-release; then
        DISTRO='CentOS'
    elif grep -Eqi "Debian" /etc/issue || grep -Eq "Debian" /etc/*-release; then
        DISTRO='Debian'
    elif grep -Eqi "Ubuntu" /etc/issue || grep -Eq "Ubuntu" /etc/*-release; then
        DISTRO='Ubuntu'
    else
        DISTRO='unknow'
    fi
}

# 获取包管理器
get_package_manager() {
    if [[ $DISTRO == "CentOS" ]]; then
        PM="yum"
    else
        PM="apt"
    fi
}

# 安装基础依赖
install_base_packages() {
    if [[ $PM == "yum" ]]; then
        $PM install -y epel-release
        $PM update -y
        $PM install -y curl wget git lsof
    else
        $PM update
        $PM install -y curl wget git lsof
    fi
}

update_core() {
    echo -e "${COLOR_ERROR}当前系统内核版本太低 <$VERSION_CURR>, 需要更新系统内核。${COLOR_NONE}"
    
    if [[ $DISTRO == "CentOS" ]]; then
        # CentOS 7 升级内核
        rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org
        rpm -Uvh https://www.elrepo.org/elrepo-release-7.0-4.el7.elrepo.noarch.rpm
        yum --enablerepo=elrepo-kernel install -y kernel-ml
        grub2-set-default 0
    else
        # Debian/Ubuntu 升级内核
        $PM install -y --install-recommends linux-image-amd64 linux-headers-amd64
        $PM autoremove -y
    fi

    echo -e "${COLOR_SUCC}内核更新完成, 重新启动机器...${COLOR_NONE}"
    reboot
}

install_docker() {
    if command -v docker >/dev/null 2>&1; then
        echo -e "${COLOR_SUCC}Docker 已经安装${COLOR_NONE}"
        return
    fi

    if [[ $DISTRO == "CentOS" ]]; then
        # 安装 Docker - CentOS
        $PM remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine
        $PM install -y yum-utils
        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        $PM install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    else
        # 安装 Docker - Debian/Ubuntu
        $PM remove -y docker docker-engine docker.io containerd runc
        $PM update
        $PM install -y \
            apt-transport-https \
            ca-certificates \
            curl \
            gnupg \
            lsb-release

        # 添加 Docker 的官方 GPG 密钥
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/$DISTRO/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

        # 设置稳定版仓库
        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$DISTRO \
            $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list

        $PM update
        $PM install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    fi

    # 启动 Docker
    systemctl enable docker
    systemctl start docker

    echo -e "${COLOR_SUCC}Docker 安装成功${COLOR_NONE}"
}

check_bbr() {
    has_bbr=$(lsmod | grep bbr)
    if [ -n "$has_bbr" ] ; then
        echo -e "${COLOR_SUCC}TCP BBR 拥塞控制算法已经启动${COLOR_NONE}"
        return 0
    else
        start_bbr
        return 1
    fi
}

version_ge() {
    test "$(echo "$@" | tr " " "\n" | sort -rV | head -n 1)" == "$1"
}

install_bbr() {
    VERSION_CURR=$(uname -r | awk -F '-' '{print $1}')
    VERSION_MIN="4.9.0"

    if version_ge $VERSION_CURR $VERSION_MIN; then
        check_bbr
    else
        update_core
    fi
}

start_bbr() {
    echo "启动 TCP BBR 拥塞控制算法"
    
    # 确保目录存在
    mkdir -p /etc/modules-load.d
    
    # 加载并配置 BBR
    modprobe tcp_bbr
    echo "tcp_bbr" >> /etc/modules-load.d/modules.conf
    
    # 应用 sysctl 设置
    cat >> /etc/sysctl.conf << EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    
    sysctl -p
    
    # 验证 BBR 是否启用
    if sysctl net.ipv4.tcp_congestion_control | grep -q bbr && lsmod | grep -q tcp_bbr; then
        echo -e "${COLOR_SUCC}BBR 已成功启用${COLOR_NONE}"
    else
        echo -e "${COLOR_ERROR}BBR 启用失败，请检查系统配置${COLOR_NONE}"
    fi
}

install_certbot() {
    if ! [ -x "$(command -v certbot)" ]; then
        echo "开始安装 certbot 命令行工具"
        if [[ $DISTRO == "CentOS" ]]; then
            $PM install -y certbot
        else
            $PM install -y certbot
        fi
    fi
}

create_cert() {
    if ! [ -x "$(command -v certbot)" ]; then
        install_certbot
    fi

    echo "开始生成 SSL 证书"
    echo -e "${COLOR_ERROR}注意：生成证书前,需要将域名指向一个有效的 IP,否则无法创建证书.${COLOR_NONE}"
    

    read -r -p "请输入你要使用的域名:" domain
    certbot certonly --standalone -d "${domain}"
}

create_cron_job() {
    # 确保目录存在
    mkdir -p /var/spool/cron/crontabs/
    
    if ! crontab -l 2>/dev/null | grep -q "certbot renew --force-renewal"; then
        (crontab -l 2>/dev/null; echo "0 0 1 * * /usr/bin/certbot renew --force-renewal") | crontab -
        echo -e "${COLOR_SUCC}成功安装证书renew定时作业！${COLOR_NONE}"
    fi

    if ! crontab -l 2>/dev/null | grep -q "docker restart gost"; then
        (crontab -l 2>/dev/null; echo "5 0 1 * * /usr/bin/docker restart gost") | crontab -
        echo -e "${COLOR_SUCC}成功安装gost更新证书定时作业！${COLOR_NONE}"
    fi
}

install_https_proxy() {
    if ! [ -x "$(command -v docker)" ]; then
        echo -e "${COLOR_ERROR}未发现Docker，请先安装 Docker!${COLOR_NONE}"
        return
    fi

    # 检查证书目录
    echo "检查SSL证书..."
    read -r -p "请输入域名：" DOMAIN
    
    CERT_DIR=/etc/letsencrypt
    CERT=${CERT_DIR}/live/${DOMAIN}/fullchain.pem
    KEY=${CERT_DIR}/live/${DOMAIN}/privkey.pem
    
    # 检查证书是否存在
    if [ ! -f "$CERT" ] || [ ! -f "$KEY" ]; then
        echo -e "${COLOR_ERROR}未找到域名 ${DOMAIN} 的SSL证书，请先创建证书！${COLOR_NONE}"
        return
    fi

    # 生成随机端口（1024-65535之间）
    PORT=$(shuf -i 1024-65535 -n 1)
    
    # 固定的配置
    BIND_IP=0.0.0.0
    USER=admin
    PASS=admin123

    # 检查端口是否被占用
    while lsof -i :"$PORT" >/dev/null 2>&1; do
        echo "端口 $PORT 已被占用，重新生成..."
        PORT=$(shuf -i 1024-65535 -n 1)
    done

    # 检查是否已存在同名容器
    if docker ps -a --format '{{.Names}}' | grep -q "^${PORT}$"; then
        echo -e "${COLOR_ERROR}已存在相同名称的容器，正在删除...${COLOR_NONE}"
        docker rm -f "${PORT}" >/dev/null 2>&1
    fi

    echo "开始创建HTTPS代理..."
    echo "使用以下配置："
    echo "域名: ${DOMAIN}"
    echo "端口: ${PORT}"
    echo "用户名: ${USER}"
    echo "密码: ${PASS}"

    # 运行容器
    docker run -d --restart=always --name "${PORT}" \
        -v ${CERT_DIR}:${CERT_DIR}:ro \
        --net=host ginuerzh/gost \
        -L "http2://${USER}:${PASS}@${BIND_IP}:${PORT}?cert=${CERT}&key=${KEY}"

    if [ $? -eq 0 ]; then
        echo -e "${COLOR_SUCC}HTTPS代理创建成功！${COLOR_NONE}"
        echo "代理信息："
        echo "地址: ${DOMAIN}:${PORT}"
        echo "用户名: ${USER}"
        echo "密码: ${PASS}"
        # 保存配置到文件
        echo "${DOMAIN}:${PORT} ${USER}:${PASS}" >> /root/proxy_info.txt
        echo "配置已保存到 /root/proxy_info.txt"
    else
        echo -e "${COLOR_ERROR}HTTPS代理创建失败！${COLOR_NONE}"
    fi
}

install_http_proxy() {
    if ! [ -x "$(command -v docker)" ]; then
        echo -e "${COLOR_ERROR}未发现Docker，请先安装 Docker!${COLOR_NONE}"
        return
    fi

    # 生成随机端口（1024-65535之间）
    PORT=$(shuf -i 1024-65535 -n 1)
    BIND_IP=0.0.0.0
    
    # 检查端口是否被占用
    while lsof -i :"$PORT" >/dev/null 2>&1; do
        echo "端口 $PORT 已被占用，重新生成..."
        PORT=$(shuf -i 1024-65535 -n 1)
    done

    # 检查是否已存在同名容器
    if docker ps -a --format '{{.Names}}' | grep -q "^${PORT}$"; then
        echo -e "${COLOR_ERROR}已存在相同名称的容器，正在删除...${COLOR_NONE}"
        docker rm -f "${PORT}" >/dev/null 2>&1
    fi

    echo "开始创建HTTP代理..."
    echo "使用以下配置："
    echo "IP: ${BIND_IP}"
    echo "端口: ${PORT}"

    # 运行容器
    docker run -d --restart=always --name "${PORT}" \
        --net=host ginuerzh/gost \
        -L "http://${BIND_IP}:${PORT}"

    if [ $? -eq 0 ]; then
        echo -e "${COLOR_SUCC}HTTP代理创建成功！${COLOR_NONE}"
        echo "代理信息："
        echo "地址: ${BIND_IP}:${PORT}"
        # 保存配置到文件
        echo "HTTP ${BIND_IP}:${PORT}" >> /root/proxy_info.txt
        echo "配置已保存到 /root/proxy_info.txt"
    else
        echo -e "${COLOR_ERROR}HTTP代理创建失败！${COLOR_NONE}"
    fi
}

# 添加缺失的函数声明
install_gost() {
    echo "安装 Gost HTTP/2 代理服务"
    install_docker
    install_https_proxy
}

init(){
    # 检测系统类型
    check_sys
    if [[ $DISTRO == "unknow" ]]; then
        echo -e "${COLOR_ERROR}不支持的系统类型${COLOR_NONE}"
        exit 1
    fi
    echo -e "${COLOR_SUCC}当前系统为: $DISTRO${COLOR_NONE}"
    
    # 获取包管理器
    get_package_manager
    echo -e "${COLOR_SUCC}使用包管理器: $PM${COLOR_NONE}"
    
    # 安装基础依赖
    install_base_packages

    COLUMNS=50
    echo -e "\n菜单选项\n"

    while true
    do
        PS3="请选择一个选项："
        re='^[0-9]+$'
        select opt in "安装 TCP BBR 拥塞控制算法" \
                     "安装 Docker 服务程序" \
                     "创建 SSL 证书" \
                     "创建 HTTPS 代理" \
                     "创建 HTTP 代理" \
                     "创建证书更新 CronJob" \
                     "退出" ; do

            if ! [[ $REPLY =~ $re ]] ; then
                echo -e "${COLOR_ERROR}无效的选项，请输入数字。${COLOR_NONE}"
                break
            elif (( REPLY == 1 )) ; then
                install_bbr
                break
            elif (( REPLY == 2 )) ; then
                install_docker
                break
            elif (( REPLY == 3 )) ; then
                create_cert
                break
           elif (( REPLY == 4 )) ; then
                install_https_proxy
                break
           elif (( REPLY == 5 )) ; then
                install_http_proxy
                break
           elif (( REPLY == 6 )) ; then
                create_cron_job
                break
            elif (( REPLY == 7 )) ; then
                exit
            else
                echo -e "${COLOR_ERROR}无效的选项，请重试。${COLOR_NONE}"
            fi
        done
    done
}

init
