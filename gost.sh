#!/bin/bash

# Colors
COLOR_ERROR="\e[38;5;198m"
COLOR_NONE="\e[1m"
COLOR_SUCC="\e[92m"
COLOR_INFO="\e[94m"
COLOR_WARN="\e[93m"

# GOST configuration directory
GOST_DIR="/gost"
DOMAIN_LIST="${GOST_DIR}/domain_list.txt"
PROXY_INFO="${GOST_DIR}/proxy_info.txt"

# 输出带颜色的信息
print_info() {
    echo -e "${COLOR_INFO}[INFO] $1${COLOR_NONE}"
}

print_success() {
    echo -e "${COLOR_SUCC}[SUCCESS] $1${COLOR_NONE}"
}

print_error() {
    echo -e "${COLOR_ERROR}[ERROR] $1${COLOR_NONE}"
}

print_warn() {
    echo -e "${COLOR_WARN}[WARN] $1${COLOR_NONE}"
}

print_divider() {
    echo -e "${COLOR_INFO}----------------------------------------${COLOR_NONE}"
}

# 检测系统类型和版本
check_sys() {
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
    print_info "安装基础依赖包..."
    if [[ $PM == "yum" ]]; then
        $PM install -y epel-release
        $PM update -y
        $PM install -y curl wget git lsof crontabs
    else
        $PM update
        $PM install -y curl wget git lsof cron
    fi
    print_success "基础依赖包安装完成"
}

# 初始化GOST目录
init_gost_dir() {
    print_info "初始化GOST目录..."
    mkdir -p "${GOST_DIR}"
    touch "${DOMAIN_LIST}"
    touch "${PROXY_INFO}"
    print_success "GOST目录初始化完成"
}

update_core() {
    print_error "当前系统内核版本太低 <$VERSION_CURR>, 需要更新系统内核"
    
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

    print_success "内核更新完成, 重新启动机器..."
    reboot
}

install_docker() {
    if command -v docker >/dev/null 2>&1; then
        print_success "Docker 已经安装"
        return
    fi

    print_info "开始安装 Docker..."

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

    print_success "Docker 安装成功"
}

check_bbr() {
    has_bbr=$(lsmod | grep bbr)
    if [ -n "$has_bbr" ] ; then
        print_success "TCP BBR 拥塞控制算法已经启动"
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
    print_info "启动 TCP BBR 拥塞控制算法"
    
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
        print_success "BBR 已成功启用"
    else
        print_error "BBR 启用失败，请检查系统配置"
    fi
}

install_certbot() {
    if ! [ -x "$(command -v certbot)" ]; then
        print_info "开始安装 certbot 命令行工具"
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

    print_info "开始生成 SSL 证书"
    print_warn "注意：生成证书前,需要将域名指向一个有效的 IP,否则无法创建证书"
    
    read -r -p "$(echo -e ${COLOR_INFO}请输入你要使用的域名: ${COLOR_NONE})" domain
    
    # 创建证书
    if certbot certonly --standalone -d "${domain}"; then
        print_success "SSL证书创建成功"
        # 将域名添加到域名列表
        if ! grep -q "^${domain}$" "${DOMAIN_LIST}"; then
            echo "${domain}" >> "${DOMAIN_LIST}"
            print_success "域名已添加到列表: ${DOMAIN_LIST}"
        fi
    else
        print_error "SSL证书创建失败"
    fi
}

create_cron_job() {
    print_info "配置证书自动更新定时任务..."

    # 确保cron服务已安装并运行
    if [[ $DISTRO == "CentOS" ]]; then
        yum install -y cronie
        systemctl enable crond
        systemctl start crond
    else
        apt install -y cron
        systemctl enable cron
        systemctl start cron
    fi

    # 创建更新脚本
    cat > "${GOST_DIR}/renew_cert.sh" << 'EOF'
#!/bin/bash
/usr/bin/certbot renew --force-renewal
/usr/bin/docker restart gost
EOF

    chmod +x "${GOST_DIR}/renew_cert.sh"

    # 添加定时任务
    (crontab -l 2>/dev/null | grep -v "renew_cert.sh"; echo "0 0 1 * * ${GOST_DIR}/renew_cert.sh") | sort - | uniq - | crontab -

    print_success "证书自动更新定时任务配置完成"
}

select_domain() {
    if [ ! -s "${DOMAIN_LIST}" ]; then
        print_error "域名列表为空，请先创建SSL证书"
        return 1
    }

    print_info "可用的域名列表："
    mapfile -t domains < "${DOMAIN_LIST}"
    select domain in "${domains[@]}"; do
        if [ -n "$domain" ]; then
            return 0
        else
            print_error "无效的选择，请重试"
        fi
    done
}

install_https_proxy() {
    if ! [ -x "$(command -v docker)" ]; then
        print_error "未发现Docker，请先安装 Docker!"
        return
    fi

    # 选择域名
    print_info "请选择要使用的域名："
    if ! select_domain; then
        return
    fi

    # 检查证书目录
    CERT_DIR=/etc/letsencrypt
    CERT=${CERT_DIR}/live/${domain}/fullchain.pem
    KEY=${CERT_DIR}/live/${domain}/privkey.pem
    
    # 检查证书是否存在
    if [ ! -f "$CERT" ] || [ ! -f "$KEY" ]; then
        print_error "未找到域名 ${domain} 的SSL证书，请先创建证书！"
        return
    fi

    # 获取用户输入
    read -r -p "$(echo -e ${COLOR_INFO}请输入代理用户名: ${COLOR_NONE})" USER
    read -r -s -p "$(echo -e ${COLOR_INFO}请输入代理密码: ${COLOR_NONE})" PASS
    echo

    # 生成随机端口（1024-65535之间）
    PORT=$(shuf -i 1024-65535 -n 1)
    BIND_IP=0.0.0.0
    
    # 检查端口是否被占用
    while lsof -i :"$PORT" >/dev/null 2>&1; do
        print_warn "端口 $PORT 已被占用，重新生成..."
        PORT=$(shuf -i 1024-65535 -n 1)
    done

    # 检查是否已存在同名容器
    if docker ps -a --format '{{.Names}}' | grep -q "^${PORT}$"; then
        print_warn "已存在相同名称的容器，正在删除..."
        docker rm -f "${PORT}" >/dev/null 2>&1
    fi

    print_info "开始创建HTTPS代理..."
    print_divider
    print_info "使用以下配置："
    print_info "域名: ${domain}"
    print_info "端口: ${PORT}"
    print_info "用户名: ${USER}"
    print_divider

    # 运行容器
    docker run -d --restart=always --name "${PORT}" \
        -v ${CERT_DIR}:${CERT_DIR}:ro \
        --net=host ginuerzh/gost \
        -L "http2://${USER}:${PASS}@${BIND_IP}:${PORT}?cert=${CERT}&key=${KEY}"

    if [ $? -eq 0 ]; then
        print_success "HTTPS代理创建成功！"
        print_divider
        print_info "代理信息："
        print_info "地址: ${domain}:${PORT}"
        print_info "用户名: ${USER}"
        print_info "密码: ${PASS}"
        print_divider
        # 保存配置到文件
        echo "HTTPS ${domain}:${PORT} ${USER}:${PASS}" >> "${PROXY_INFO}"
        print_success "配置已保存到: ${PROXY_INFO}"
    else
        print_error "HTTPS代理创建失败！"
    fi
}

install_http_proxy() {
    if ! [ -x "$(command -v docker)" ]; then
        print_error "未发现Docker，请先安装 Docker!"
        return
    fi

    # 生成随机端口（1024-65535之间）
    PORT=$(shuf -i 1024-65535 -n 1)
    BIND_IP=0.0.0.0
    
    # 检查端口是否被占用
    while lsof -i :"$PORT" >/dev/null 2>&1; do
        print_warn "端口 $PORT 已被占用，重新生成..."
        PORT=$(shuf -i 1024-65535 -n 1)
    done

    # 检查是否已存在同名容器
    if docker ps -a --format '{{.Names}}' | grep -q "^${PORT}$"; then
        print_warn "已存在相同名称的容器，正在删除..."
        docker rm -f "${PORT}" >/dev/null 2>&1
    fi

    print_info "开始创建HTTP代理..."
    print_divider
    print_info "使用以下配置："
    print_info "IP: ${BIND_IP}"
    print_info "端口: ${PORT}"
    print_divider

    # 运行容器
    docker run -d --restart=always --name "${PORT}" \
        --net=host ginuerzh/gost \
        -L "http://${BIND_IP}:${PORT}"

    if [ $? -eq 0 ]; then
        print_success "HTTP代理创建成功！"
        print_divider
        print_info "代理信息："
        print_info "地址: ${BIND_IP}:${PORT}"
        print_divider
        # 保存配置到文件
        echo "HTTP ${BIND_IP}:${PORT}" >> "${PROXY_INFO}"
        print_success "配置已保存到: ${PROXY_INFO}"
    else
        print_error "HTTP代理创建失败！"
    fi
}

delete_proxy() {
    if [ ! -f "${PROXY_INFO}" ] || [ ! -s "${PROXY_INFO}" ]; then
        print_warn "暂无代理配置信息"
        return
    fi

    print_info "当前配置的代理列表："
    print_divider
    
    # 读取并显示所有代理
    mapfile -t proxies < "${PROXY_INFO}"
    for i in "${!proxies[@]}"; do
        echo -e "${COLOR_INFO}$((i+1)). ${proxies[$i]}${COLOR_NONE}"
    done
    print_divider

    read -r -p "$(echo -e ${COLOR_INFO}请选择要删除的代理序号: ${COLOR_NONE})" choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#proxies[@]}" ]; then
        print_error "无效的选择"
        return
    fi

    # 获取选中的代理信息
    selected_proxy="${proxies[$((choice-1))]}"
    
    # 提取端口号
    port=$(echo "$selected_proxy" | grep -o ':[0-9]\+' | cut -d':' -f2)
    
    # 停止并删除Docker容器
    if docker stop "$port" && docker rm "$port"; then
        # 从配置文件中删除对应行
        sed -i "${choice}d" "${PROXY_INFO}"
        print_success "代理已成功删除"
    else
        print_error "删除代理失败"
    fi
}

install_gost() {
    print_info "安装 Gost HTTP/2 代理服务"
    install_docker
    install_https_proxy
}

init(){
    # 检测系统类型
    check_sys
    if [[ $DISTRO == "unknow" ]]; then
        print_error "不支持的系统类型"
        exit 1
    fi
    print_success "当前系统为: $DISTRO"
    
    # 获取包管理器
    get_package_manager
    print_success "使用包管理器: $PM"
    
    # 初始化GOST目录
    init_gost_dir
    
    # 安装基础依赖
    install_base_packages

    print_info "===== GOST 代理服务器安装脚本 ====="
    COLUMNS=50
    echo -e "\n${COLOR_INFO}菜单选项${COLOR_NONE}\n"

    while true
    do
        print_divider
        PS3="$(echo -e ${COLOR_INFO}请选择一个选项: ${COLOR_NONE})"
        re='^[0-9]+$'
        select opt in "安装 TCP BBR 拥塞控制算法" \
                     "安装 Docker 服务程序" \
                     "创建 SSL 证书" \
                     "创建 HTTPS 代理" \
                     "创建 HTTP 代理" \
                     "创建证书更新定时任务" \
                     "查看已配置的代理信息" \
                     "删除代理节点" \
                     "退出" ; do

            if ! [[ $REPLY =~ $re ]] ; then
                print_error "无效的选项，请输入数字"
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
                if [ -f "${PROXY_INFO}" ]; then
                    print_info "已配置的代理信息："
                    print_divider
                    while IFS= read -r line; do
                        echo -e "${COLOR_INFO}${line}${COLOR_NONE}"
                    done < "${PROXY_INFO}"
                    print_divider
                else
                    print_warn "暂无代理配置信息"
                fi
                break
            elif (( REPLY == 8 )) ; then
                delete_proxy
                break
            elif (( REPLY == 9 )) ; then
                print_success "感谢使用，再见！"
                exit
            else
                print_error "无效的选项，请重试"
            fi
        done
    done
}

# 确保脚本以root权限运行
if [ "$EUID" -ne 0 ]; then
    print_error "请以root权限运行此脚本"
    exit 1
fi

# 启动主程序
init
