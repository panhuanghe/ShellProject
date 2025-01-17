#!/usr/bin/env bash
#===============================================================================
#
#          FILE: chatGPT-WEB_build.sh
# 
#         USAGE: ./chatGPT-WEB_build.sh
#
#   DESCRIPTION: chatGPT-WEB项目一键构建、部署脚本
# 
#  ORGANIZATION: DingQz dqzboy.com
#===============================================================================

SETCOLOR_SKYBLUE="echo -en \\E[1;36m"
SETCOLOR_SUCCESS="echo -en \\E[0;32m"
SETCOLOR_NORMAL="echo  -en \\E[0;39m"
SETCOLOR_RED="echo  -en \\E[0;31m"

# 定义项目仓库地址
GITGPT="https://github.com/Chanzhaoyu/chatgpt-web"
# 定义需要拷贝的文件目录
CHATDIR="chatgpt-web"
SERDIR="service"
FONTDIR="dist"
ORIGINAL=${PWD}


function SUCCESS_ON() {
${SETCOLOR_SUCCESS} && echo "-------------------------------------<提 示>-------------------------------------" && ${SETCOLOR_NORMAL}
}

function SUCCESS_END() {
${SETCOLOR_SUCCESS} && echo "-------------------------------------< END >-------------------------------------" && ${SETCOLOR_NORMAL}
echo
}


function CHECKFIRE() {
SUCCESS_ON
# Check if firewall is enabled
firewall_status=$(systemctl is-active firewalld)
if [[ $firewall_status == 'active' ]]; then
    # If firewall is enabled, disable it
    systemctl stop firewalld
    systemctl disable firewalld
    echo "Firewall has been disabled."
else
    echo "Firewall is already disabled."
fi

# Check if SELinux is enforcing
if sestatus | grep "SELinux status" | grep -q "enabled"; then
    echo "SELinux is enabled. Disabling SELinux..."
    setenforce 0
    sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
    echo "SELinux is already disabled."
else
    echo "SELinux is already disabled."
fi
SUCCESS_END
}


function INSTALL_NGINX() {
SUCCESS_ON
# 检查是否已安装Nginx
if which nginx >/dev/null; then
  echo "Nginx is already installed."
else
  echo "Installing Nginx..."
  # 下载并安装RPM包
  rpm -ivh http://nginx.org/packages/centos/7/noarch/RPMS/nginx-release-centos-7-0.el7.ngx.noarch.rpm
  yum install -y nginx
  echo "Nginx installed."
fi


# 检查Nginx是否正在运行
if systemctl status nginx &> /dev/null; then
  echo "Nginx is already running."
else
  echo "Starting Nginx..."
  systemctl start nginx
  systemctl enable nginx
  echo "Nginx started."
fi
SUCCESS_END
}

function GITCLONE() {
${SETCOLOR_SUCCESS} && echo "-------------------------------------<项目克隆>-------------------------------------" && ${SETCOLOR_NORMAL}
${SETCOLOR_RED} && echo "                           注: 国内服务器请选择参数 2 "
SUCCESS_END
${SETCOLOR_NORMAL}

read -e -p "请选择你的服务器网络环境[国外1/国内2]： " NETWORK
if [ ${NETWORK} == 1 ];then
    cd ${ORIGINAL} && git clone ${GITGPT}
elif [ ${NETWORK} == 2 ];then
    cd ${ORIGINAL} && git clone https://ghproxy.com/${GITGPT}
fi
SUCCESS_END
}

function NODEJS() {
SUCCESS_ON
# 检查是否安装了Node.js
if ! command -v node &> /dev/null
then
    echo "Node.js 未安装，正在进行安装..."
    # 安装 Node.js
    yum -y install libstdc++.so.glibc glibc lsof
    curl -fsSL https://rpm.nodesource.com/setup_16.x | bash -
    yum install -y nodejs
else
    echo "Node.js 已安装..."
fi

# 检查是否安装了 pnpm
if ! command -v pnpm &> /dev/null
then
    echo "pnpm 未安装，正在进行安装..."
    # 安装 pnpm
    npm install -g pnpm
else
    echo "pnpm 已安装..." 
fi
SUCCESS_END
}

function INFO() {
SUCCESS_ON
echo "                           构建之前请先指定Nginx根路径!"
SUCCESS_END
${SETCOLOR_NORMAL}

# 交互输入Nginx根目录(提前进行创建好)
if [ -f .input ]; then
  last_input=$(cat .input)
  read -e -p "WEB存储绝对路径(回车默认Nginx路径)[上次执行：${last_input}]：" WEBDIR
  if [ -z "${WEBDIR}" ];then
      WEBDIR="/usr/share/nginx/html"
      ${SETCOLOR_SKYBLUE} && echo "chatGPT-WEB存储路径：${WEBDIR}" && ${SETCOLOR_NORMAL}
  else
      ${SETCOLOR_SUCCESS} && echo "chatGPT-WEB存储路径：${WEBDIR}" && ${SETCOLOR_NORMAL}
  fi
else
  read -e -p "WEB存储绝对路径(回车默认Nginx路径)：" WEBDIR
  if [ -z "${WEBDIR}" ];then
      WEBDIR="/usr/local/openresty/nginx/chatgpt-web"
      ${SETCOLOR_SKYBLUE} && echo "chatGPT-WEB存储路径：${WEBDIR}" && ${SETCOLOR_NORMAL}
  else
      ${SETCOLOR_SUCCESS} && echo "chatGPT-WEB存储路径：${WEBDIR}" && ${SETCOLOR_NORMAL}
  fi
fi

echo "${WEBDIR}" > .input

echo "------------------------------------------------------------------------------------------------"
read -e -p "修改用户默认名称/描述/头像信息,请用空格分隔[留空则保持默认!]：" USERINFO
if [ -z "${USERINFO}" ];then
    ${SETCOLOR_SKYBLUE} && echo "没有输入,保持默认" && ${SETCOLOR_NORMAL}
else
    USER=$(echo "${USERINFO}" | cut -d' ' -f1)
    INFO=$(echo "${USERINFO}" | cut -d' ' -f2)
    AVATAR=$(echo "${USERINFO}" | cut -d' ' -f3)
    ${SETCOLOR_SUCCESS} && echo "当前用户默认名称为：${USER}" && ${SETCOLOR_NORMAL}
    ${SETCOLOR_SUCCESS} && echo "当前描述信息默认为：${INFO}" && ${SETCOLOR_NORMAL}
    # 修改个人信息
    sed -i "s/ChenZhaoYu/${USER}/g" ${ORIGINAL}/${CHATDIR}/src/store/modules/user/helper.ts
    sed -i "s#Star on <a href=\"https://github.com/Chanzhaoyu/chatgpt-bot\" class=\"text-blue-500\" target=\"_blank\" >Github</a>#${INFO}#g" ${ORIGINAL}/${CHATDIR}/src/store/modules/user/helper.ts
    sed -i "s#https://raw.githubusercontent.com/Chanzhaoyu/chatgpt-web/main/src/assets/avatar.jpg#${AVATAR}#g" ${ORIGINAL}/${CHATDIR}/src/store/modules/user/helper.ts
    # 删除配置里面的GitHub相关信息内容(可选，建议保留，尊重项目作者成果)
    #sed -i '/<div class="p-2 space-y-2 rounded-md bg-neutral-100 dark:bg-neutral-700">/,/<\/div>/d' ${ORIGINAL}/${CHATDIR}/src/components/common/Setting/About.vue
fi


}


function BUILDWEB() {
# 安装依赖
pnpm bootstrap
# 打包
pnpm build
}

function BUILDSEV() {
# 安装依赖
pnpm install
# 打包
pnpm build
}


function BUILD() {
SUCCESS_ON
echo "                           开始进行构建.构建快慢取决于你的环境"
SUCCESS_END
${SETCOLOR_NORMAL}
# 拷贝.env配置替换
cp ${ORIGINAL}/env.example ${ORIGINAL}/${CHATDIR}/${SERDIR}/.env
echo
${SETCOLOR_SUCCESS} && echo "-----------------------------------<前端构建>-----------------------------------" && ${SETCOLOR_NORMAL}
# 前端
cd ${ORIGINAL}/${CHATDIR} && BUILDWEB
${SETCOLOR_SUCCESS} && echo "-------------------------------------< END >-------------------------------------" && ${SETCOLOR_NORMAL}
echo
echo
${SETCOLOR_SUCCESS} && echo "------------------------------------<后端构建>-----------------------------------" && ${SETCOLOR_NORMAL}
# 后端
cd ${SERDIR} && BUILDSEV
${SETCOLOR_SUCCESS} && echo "-------------------------------------< END >-------------------------------------" && ${SETCOLOR_NORMAL}
}

# 拷贝构建成品到Nginx网站根目录
function NGINX() {
# 拷贝后端并启动
echo
${SETCOLOR_SUCCESS} && echo "-----------------------------------<后端部署>-----------------------------------" && ${SETCOLOR_NORMAL}
echo ${PWD}
\cp -fr ${ORIGINAL}/${CHATDIR}/${SERDIR} ${WEBDIR}
# 检查名为 node后端 的进程是否正在运行
pid=$(lsof -t -i:3002)
if [ -z "$pid" ]; then
    echo "后端程序未运行,启动中..."
else
    echo "后端程序正在运行,现在停止程序并更新..."
    kill -9 $pid
fi
\cp -fr ${ORIGINAL}/${CHATDIR}/${FONTDIR}/* ${WEBDIR}
cd ${WEBDIR}/${SERDIR}  && nohup pnpm run start > app.log 2>&1 &
# 拷贝前端刷新Nginx服务
${SETCOLOR_SUCCESS} && echo "-----------------------------------<前端部署>-----------------------------------" && ${SETCOLOR_NORMAL}
if ! nginx -t ; then
    echo "Nginx 配置文件存在错误，请检查配置"
    exit 4
else
    nginx -s reload
fi
}

# 删除源码包文件
function DELSOURCE() {
  rm -rf ${ORIGINAL}/${CHATDIR}
  ${SETCOLOR_SUCCESS} && echo "-----------------------------------<部署完成>-----------------------------------" && ${SETCOLOR_NORMAL}
}

function main() {
   CHECKFIRE
   INSTALL_NGINX
   NODEJS
   GITCLONE
   INFO
   BUILD
   NGINX
   DELSOURCE
}
main
