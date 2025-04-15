#!/bin/bash

# 设计思路:
# 1. 脚本负责从 Ubuntu 系统上部署 PHA 服务环境
#   - 脚本负责搭建 PHA 服务环境
#   - 脚本负责辅助客户填写自己的服务信息
#   - 脚本负责调起 PHA 服务程序，进行波卡同步
# 2. 脚本针对不同功能做 lock 处理:
#   - 同步之前的功能为免费功能，同步功能需要解锁使用
#   - 当脚本运行时，从机器网卡中选举一张网卡，提取其 MAC 地址做加密，产生机器码、并弹出客服二维码
#   - 客户添加客户二维码，将机器码发给客服，获取解锁码，将解锁码填入程序解锁同步功能

# ==================================================================================

# 函数变量列表
# 输出函数 
# 1. log_suss 输出不需要用户暂停查看的成功结果
# 2. log_suss_pause 输出需要用户暂停查看的成功结果
# 3. log_err_pause 输出失败结果，默认暂停
# 4. get_char 等待操作函数，实现暂停功能

# 系统修改 
# 1. set_sudoers 为 sudo 用户添加免密码选项
# 2. add_sudo 安装脚本、做快捷方式
# 3. cha_dns 设置 nameserver 为 114
# 4. cha_mirr 换源函数，系统源换为 ali 源、并添加 docker 仓库
# 5. ins_soft 依赖安装函数，安装 pha 必备依赖、并设置 git 代理
# 6. ins_src docker-compose、nodejs、yq 等源码安装函数
# 7. is_update 脚本更新函数，每次脚本启动访问 README 提取版本号对比，有更新则覆盖脚本
# 8. env_init 环境初始化函数，调用以上几个函数，单独列出函数防止第一次安装失败

# PHA 部署
# 1. down_pha 下载 pha 源码，并提取 sgx_enable 做系统 SGX 支持测试
# 2. sgx_check 通过 sgx_enable 检查系统 SGX 支持情况，防止驱动下载失败
# 3. sgx_fix  sgx 驱动修复

# 加解密
# 1. get_mac 选举网卡，获取网卡的 MAC 地址
# 2. gen_code 生成机器码函数
# 3. detect_status 激活状态检查函数
# 4. is_status 判断激活状态函数

# 菜单函数 menu


# ==================================================================================

# 基本输出函数
# 用于结果输出，有红绿两种颜色，针对正确/错误两种结果
function log_suss(){
    local len=`echo $@ | wc -L`
    echo -e "\033[32m$@\033[0m"
    echo "" | sed ":a; s/^/=/; /=\{$len\}/b; ta"
    echo ""
}

# 暂停输出函数
# 添加了等待操作函数，在结果输出函数的基础上，添加按任意键继续的功能，以用来方便结果查看
function get_char()
{
SAVEDSTTY=`stty -g`
stty -echo
stty cbreak
dd if=/dev/tty bs=1 count=1 2> /dev/null
stty -raw
stty echo
stty $SAVEDSTTY
}

function log_suss_pause(){
    local len=`echo $@ | wc -L`
    echo -e "\033[32m$@\033[0m"
    echo "" | sed ":a; s/^/=/; /=\{$len\}/b; ta"
    echo ""
    echo -e "\033[32m按任意键继续\033[0m"
    get_char
}

function log_err_pause(){
    local len=`echo $@ | wc -L`
    echo -e "\033[31m$@\033[0m"
    echo "" | sed ":a; s/^/=/; /=\{$len\}/b; ta"
    echo ""
    echo -e "\033[31m按任意键继续\033[0m"
    get_char
}

# ==================================================================================
# 特定功能函数
# 实现特定的功能，原则上一类功能封装成一个函数

# 系统修改部分

# set_sudoers 将 sudo 用户添加免密码选项
function set_sudoers(){
    local target="/etc/sudoers"
    sudo grep "%sudo" $target | grep "NOPASSWD: ALL" || echo -e "%sudo\x20ALL=(ALL:ALL)\x20NOPASSWD:\x20ALL" | sudo tee -a $target && log_suss "sudoers 添加成功"
}

# add_sudo 将脚本移动到 /usr/bin/pha，并在 bashrc 中添加 alias，此处技术生效需要菜单函数开启新终端
function add_sudo(){
    if [ ! -f /usr/bin/pha ];then
        sudo mv $0 /usr/bin/pha
        sudo chmod +x /usr/bin/pha
        echo "alias pha='/usr/bin/pha'" >> ~/.bashrc
        log_suss "脚本安装成功！\n以后您可以在终端中输入 \"pha\" 直接打开脚本"
    fi
}

# change_dns 修改 dns 为 114
function cha_dns(){
    sudo sed -i "s/#DNS=/DNS=114.114.114.114/" /etc/systemd/resolved.conf
    sudo systemctl restart systemd-resolved
    sudo rm -rf /etc/resolv.conf
    sudo ln  -s /run/systemd/resolve/resolv.conf /etc/ && log_suss "dns 修改成功"
}

# add_hosts 添加必要的 hosts 解析
function add_hosts(){
    local target="/etc/hosts"
    local action="sudo tee -a $target"
    declare -A hosts_dic
    hosts_dic=(["download.01.org"]="184.31.180.104" ["download.docker.com"]="18.65.100.61" ["registry-1.docker.io"]="54.236.165.68" ["download.fastgit.org"]="88.198.10.254" ["gh.api.99988866.xyz"]="172.67.194.217")

    for i in ${!hosts_dic[*]}
    do
        # 过滤方法
        local gr_key=`grep $i $target`
        local gr_val=`grep ${hosts_dic["$i"]} $target`

        # 当过滤不到 key、value (没有解析记录时)
        if [[ ! -n $gr_key ]] && [[ ! -n $gr_val ]];then
            echo -e "${hosts_dic["$i"]}\t$i" | $action
        # 当能过滤到 key、过滤不到 value (该域名 IP 变化时)
        elif [[ -n $gr_key ]] && [[ ! -n $gr_val ]];then
            local num=`grep -n "$i" $target | awk -F ':' '{print $1}'`
            sudo sed -i "$num"d $target
            echo -e "${hosts_dic["$i"]}\t$i" | $action
        fi
    done
}

# cha_mirr 换源函数，系统源换为 ali 源
function cha_mirr(){
    local target="/etc/apt/sources.list"
    sudo cp $target $target.bak
    sudo sed -i 's/http:\/\/.*archive.ubuntu/http:\/\/mirrors.aliyun/g' $target
    sudo sed -i "s/security.ubuntu/mirrors.aliyun/g" $target
    log_suss "换源成功"
    sudo apt update
}

function ins_src(){
    if [ ! -f /usr/local/bin/docker-compose ];then
        sudo wget https://get.daocloud.io/docker/compose/releases/download/1.29.2/docker-compose-`uname -s`-`uname -m` -O /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
        sudo ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose && log_suss "docker-compose 安装成功!" || log_err_pause "docker-compose 安装失败!"
    fi
    if [ ! -f /usr/bin/node ];then
        curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
        sudo apt install -yf nodejs && log_suss "nodejs 安装成功!" || log_err_pause "nodejs 安装失败!"
    fi
    if [ ! -f /usr/bin/yq ];then
        sudo wget https://hub.fastgit.org/mikefarah/yq/releases/download/v4.11.2/yq_linux_amd64.tar.gz -O /tmp/yq_linux_amd64.tar.gz
        sudo tar -xvf /tmp/yq_linux_amd64.tar.gz -C /tmp
        sudo mv /tmp/yq_linux_amd64 /usr/bin/yq
        sudo rm /tmp/yq_linux_amd64.tar.gz && log_suss "yq 安装成功!" || log_err_pause "yq 安装失败!"
    fi
}

# ins_soft 依赖安装函数，安装 pha 必备依赖、并设置 git 代理
function ins_soft(){
    sudo apt install -y curl && log_suss "curl 安装成功" || log_err_pause "curl 安装失败!"
    curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg | sudo apt-key add -  && log_suss "docker 源公钥添加成功" || log_err_pause "docker 源公钥添加失败!"
    sudo add-apt-repository "deb [arch=amd64] https://mirrors.aliyun.com/docker-ce/linux/ubuntu $(lsb_release -cs) stable" && log_suss "docker 源添加成功" || log_err_pause "docker 源添加失败!"
    sudo apt update
    local ins_list=("qrencode" "vim" "git" "wget" "jq" "unzip" "zip" "bc" "docker-ce" "docker-ce-cli" "containerd.io" "dkms")
    for i in ${ins_list[*]}
    do
        sudo apt install -qqyf $i && log_suss "$i 安装成功!" || log_err_pause "$i 安装失败!\n请重选功能尝试重新安装！\n如果重试依然失败，请联系客服解决!"
    done
    git config --global url."https://hub.fastgit.org/".insteadOf "https://github.com/"
    sudo usermod -aG docker $USER
    
}

function cat_status(){
    local ipaddr=127.0.0.1
    local block_json=$(curl -sH "Content-Type: application/json" -d '{"id":1  "jsonrpc":"2.0", "method": "system_syncState", "params":[]}' http://$ipaddr:9933)
    local node_block=$(echo $block_json | jq -r '.result.currentBlock')
    local hightest_block=$(echo $block_json | jq -r '.result.highestBlock')
    local rate=`awk 'BEGIN{printf "%.1f%%\n" ('$node_block'/'$hightest_block')*100}'`
    log_suss "当前同步进度为: $rate"
    declare -A dic
    dic=(["pherry"]="`sudo docker inspect phala-pherry --format '{{.State.Running}}'`" ["node"]="`sudo docker inspect phala-node --format '{{.State.Running}}'`" ["pruntime"]="`sudo docker inspect phala-pruntime --format '{{.State.Running}}'`")
    for i in ${!dic[*]}
    do
        echo -e "节点名称: "$i" 是否运行: ${dic["$i"]}" | column -t
    done
}

# env_init 环境初始化函数，调用以上几个函数，单独列出函数防止第一次安装失败
function env_init(){
    set_sudoers
    add_sudo
    add_hosts
    cha_dns
    cha_mirr
    ins_soft
    ins_src
    is_update
}

# ==================================================================================

# pha 部署

# down_pha 下载 pha 源码，并提取 sgx_enable 做系统 SGX 支持测试
function down_pha(){
    if [ -d /opt/bak ];then
        cd /opt/bak && git pull
    else
        sudo git clone https://hub.fastgit.org/Phala-Network/solo-mining-scripts /opt/bak -b para
        sudo cp -rf /opt/bak/sgx_enable /usr/bin/
        sudo chmod 777 /usr/bin/sgx_enable
    fi
        sgx_check
        sudo rm -rf /opt/phala
        sudo /opt/bak/install.sh $lang
        curl https://github.com -s -I | grep "HTTP/2 200"
        if [ $? -ne 0 ];then
            curl https://gh.api.99988866.xyz -s -I | grep "HTTP/2 200"
            if [ $? -eq 0 ];then
                sudo sed -i 's/https:\/\/github.com/https:\/\/gh.api.99988866.xyz\/&/g' /opt/phala/scripts/*
            fi
        fi
        sudo phala install && log_suss_pause "PHA 服务程序部署成功!" || log_err_pause "PHA 服务程序部署失败!\n请联系客服解决" 
}

# sgx_check 通过 sgx_enable 检查系统 SGX 支持情况，防止驱动下载失败
function sgx_check(){
    local sgx=`/usr/bin/sgx_enable`
    if [ "$sgx" == "This CPU does not support Intel SGX" ];then
        log_err_pause "CPU 不支持，请检查主板是否关闭了 SGX 启动项\n如果主板没有 SGX 功能，代表不支持"
        exit 1;
    elif [ "$sgx" == "Intel SGX is already enabled on this system" ];then
        log_suss "已经成功地启动了 SGX 功能，进行下一步"
    elif [ "$sgx" == "Software enable has been set. Please reboot your system to finish" ];then
        log_err_pause "SGX 设定值为 \"软件定义\" 重启才能启用 SGX"
        log_suss "三秒之后重启系统，请在重启后终端执行命令 \"pha\" 再次执行脚本";sleep 3;sudo reboot
    fi
}

# sgx_fix
function sgx_fix(){
    if [ ! -L /dev/sgx/enclave ]&&[ ! -L /dev/sgx/provision ]&&[ ! -c /dev/sgx_enclave ]&&[ ! -c /dev/sgx_provision ]&&[ ! -c /dev/isgx ]; then
        log_suss "检测到 SGX 驱动不存在，正在下载..."
        sudo phala install dhcp || sudo phala install isgx
        if [ $? -ne 0 ];then
            cd /tmp
            if [ ! -f sgx_linux_x64_driver_1.36.2.bin ];then
                wget https://download.01.org/intel-sgx/sgx-dcap/1.9/linux/distro/ubuntu20.04-server/sgx_linux_x64_driver_1.36.2.bin
            fi

            if [ ! -f sgx_linux_x64_driver_1.36.bin ];then
                wget https://download.01.org/intel-sgx/sgx-dcap/1.8/linux/distro/ubuntu18.04-server/sgx_linux_x64_driver_1.36.bin
            fi
            sudo chmod 755 /tmp/sgx*.bin
            log_suss "SGX 驱动下载完成，正在安装..."
            sudo ./sgx_linux_x64_driver_1.36.bin
            sudo ./sgx_linux_x64_driver_1.36.2.bin 
            if [ $? -eq 0 ];then
                log_suss "SGX 驱动下载成功，正在修复依赖关系..."
                for i in /var/lib/dkms/*/[^k]*/source
                do
                    if [ ! -e "$i" ];then
                        echo -e "找到无效依赖 $i\n正在修复..."
                        sudo rm -rf $i && sudo mkdir -p $i
                        dir=`echo $i | awk -F "source" '{print $1}'`
                        build=`echo "$dir"build`
                        sudo ln -sf $build/dkms.conf $i/dkms.conf
                    fi
                done
                sudo apt install -f
                sudo apt autoremove -y --purge
            else
                log_err_pause "SGX 驱动安装失败"
            fi
        fi
    fi
}

# ==================================================================================

# 加密解密部分
# get_mac 选举网卡，获取网卡的 MAC 地址
function get_mac(){
    # 提取网卡
    local E=`ls -r /sys/class/net/ | grep "^e"`
    local W=`ls -r /sys/class/net/ | grep "^w"`

    # 过滤存在的网卡，第一个选到的为主网卡
    if [ -n "$E" ];then
        local NIC=`echo $E | awk '{ print $1 }'`
    elif [ -n "$W" ];then
        local NIC=`echo $W | awk '{ print $1 }'`
    else
        log_err_pause "网卡检测失败!"
    fi

    # 根据网卡提取 MAC
    mac=`cat /sys/class/net/$NIC/address`
}

# gen_code 生成机器码函数
function gen_code(){
    local enc_code=`echo $mac | openssl aes-128-cbc -k etherlinks -base64 -pbkdf2 -iter 100`
    log_suss "\n您的机器码为: $enc_code"
}

# detect_status 激活状态检查函数，探测密钥是否存在，存在则提取密钥解密判断是否是 MAC 地址
function detect_status(){
    if [ ! -f /opt/etherlinks ];then
        status=`echo -e "\033[31m未激活\033[0m"`
    else
        local enc_code=`sudo cat /opt/etherlinks`
        local dec_code=`echo $enc_code | openssl des3 -d -k "etherlinks" -base64 -pbkdf2 -iter 100`
        if [ $dec_code == $mac ];then
            status=`echo -e "\033[32m已激活\033[0m"`
        else 
            status=`echo -e "\033[31m未激活\033[0m"`
            log_err_pause "激活失败!\n请检查激活码!"
        fi
    fi
}

function is_status(){
    if [ $status != `echo -e "\033[32m已激活\033[0m"` ];then
        log_err_pause "脚本未激活!\n请激活使用此功能"
        menu
    fi
}

# ==================================================================================

# is_update 脚本每次运行访问 README，过滤版本号，对比本地版本，有更新则下载新的覆盖脚本
function is_update(){
    version_local="3.0"
    local version_remote=`curl -s https://gitee.com/kimjungwha/pha_onekey/raw/master/README_cn.md | grep "当前版本" | awk '{ print $2 }'`

    if [ `echo "$version_local < $version_remote" | bc` -eq 1 ];then
        log_suss "检测到脚本更新"
        sudo curl -o /usr/bin/pha  https://gitee.com/kimjungwha/pha_onekey/raw/master/pha && log_suss_pause "脚本升级成功，请重新运行脚本!" || log_err_pause "脚本升级失败!\n请检查网络重试!"
        exit 0
    fi
 
}


function kf_menu(){
    clear
    local kf_list=("https://u.wechat.com/EH5b89Ku5eLhTimrxY1JL_8" "https://u.wechat.com/MOei4d-vHDVAzqiFuuD76Pw")
    for j in ${kf_list[*]}
    do
        echo $j | qrencode  -o  - -t ANSIUTF8
    done
    gen_code
    log_suss "请扫码添加任意客服微信获取激活码!\n按任意键继续"
    get_char
    menu
    
}

function unlock_menu(){
    clear
    gen_code
    if [ $status == `echo -e "\033[32m已激活\033[0m"` ];then
        log_suss_pause "脚本已激活!"
    else
        read -p "请输入您的激活码: " num3
        echo $num3 | sudo tee -a /opt/etherlinks
        detect_status
        log_suss_pause "$status"
    fi
    menu

}

function menu(){
clear
cat << EOF
===========================================================
当前版本: `echo -e "\033[32m$version_local\033[0m"`                              激活状态: `echo $status`

.----------------. .----------------. .----------------. 
| .--------------. | .--------------. | .--------------. |
| |   ______     | | |  ____  ____  | | |      __      | |
| |  |_   __ \   | | | |_   ||   _| | | |     /  \     | |
| |    | |__) |  | | |   | |__| |   | | |    / /\ \    | |
| |    |  ___/   | | |   |  __  |   | | |   / ____ \   | |
| |   _| |_      | | |  _| |  | |_  | | | _/ /    \ \_ | |
| |  |_____|     | | | |____||____| | | ||____|  |____|| |
| |              | | |              | | |              | |
| '--------------' | '--------------' | '--------------' |
'----------------' '----------------' '----------------' 

                    影响力 PHA 一键部署脚本
                    优质矿机供应: 影响力
                   https://www.yxlidc.com
        PHA 新手，请先选择 (12) 添加客服，加群获取教程！！！
`echo -e "\033[31m请注意: Para-1 测试网大幅度依赖网络，如功能启动慢等问题实属正常\033[0m"`
===========================================================
(1) 部署 PHA 服务程序(填写信息)
(2) 修改服务信息
(3) 查看服务信息
(4) SGX 等级测试
(5) 性能测试(后续淘汰，改为网站查询)
(6) 开始 PHA 服务同步
(7) 停止 PHA 服务同步
(8) 查看节点运行状态
(9) SGX 驱动修复(实验性质)
(10) 操作帮助(命令行)
(11) 添加客服微信
(12) 激活脚本
(13) 一键安装向日葵
(14) 一键安装 todesk
(15) 退出脚本

EOF
    read -p "请输入选项序号:" num1
    case $num1 in
    1)
        env_init
        read -p "请输入您要下载的 PHA 版本(中文版 cn/英文版 en): " lang
        down_pha
        ;;
    2)
        sudo phala config set
        log_suss_pause "服务信息填写完成"
        ;;
    3)
        is_status
        sudo phala config show
        log_suss_pause "服务信息提取成功"
        ;;
    4)
        is_status
        sudo phala sgx-test && log_suss_pause "SGX 等级测试成功" || log_err_pause "SGX 等级测试失败!\n请添加客服微信，联系客服解决"
        ;;
    5)
        is_status
    	read -p "请输入用于服务的核心数: " core
    	sudo phala score-test core
        ;;
    6)
        is_status
        sudo phala start
        cat_status
        ;;
    7)
        is_status
        sudo phala stop
        log_suss_pause "pha 服务程序停止"
        ;;
    8)
        is_status
    	log_suss_pause "按 CTRL+ C 键终止查看\n`cat_status`"
        sudo phala status
        ;;
    9)
        is_status
        log_err_pause "SGX 驱动修复为实验性质!\n这意味着不保证能够修复，造成 SGX 驱动安装失败的原因是 Ubuntu 系统更新，而 Intel 没有发布相应版本的 SGX 驱动。如果多次修复均失败建议重装系统!"
        sgx_fix
        ;;
    10)
        is_status
        sudo phala
        log_suss_pause "pha 命令行操作如:\n sudo phala status"
        ;;
    11)
        kf_menu        
        ;;
    12)
        unlock_menu
        ;;
    13)
        wget https://dl-cdn.oray.com/sunlogin/linux/sunloginclient-11.0.0.36662-amd64.deb
        sudo dpkg -i sunloginclient*.deb && sudo rm -rf sunloginclient*.deb
        log_suss_pause "向日葵安装成功!"
        ;;
    14)
        wget https://dl.todesk.com/linux/todesk_2.0.2_amd64.deb
        sudo dpkg -i todesk*.deb  && sudo rm -rf todesk*.deb
        log_suss_pause "todesk 安装成功!"
        ;;
    15)
        exec /bin/bash
        ;;  
    esac
}

if [ ! -f /usr/bin/pha ];then
    env_init
fi

is_update
get_mac
detect_status

while true
do
    menu
done
