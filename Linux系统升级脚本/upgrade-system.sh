#!/usr/bin/env bash
#
# Ubuntu / Debian / Rocky Linux 内核与发行版升级工具。
#
# 不带参数时显示交互式中文菜单；也可以通过命令行直接进入指定功能。
# 内核升级与发行版升级不会在同一次执行中连续运行，也不会自动重启。

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME=${0##*/}
MODE="kernel"
KERNEL_TARGET="latest"
RELEASE_TARGET="next"
ASSUME_YES=0
CHECK_ONLY=0
LIST_ONLY=0
INSTALL_HEADERS=1
MIN_ROOT_GB=1
MIN_BOOT_MB=300
MIN_ROOT_GB_SET=0
MIN_BOOT_MB_SET=0
LOCK_TIMEOUT=300
LOG_FILE=""
BACKUP_DIR=""
DISTRO=""
OS_ID=""
OS_NAME=""
OS_VERSION_ID=""
OS_CODENAME=""
RUNNING_KERNEL=""
KERNEL_FLAVOR=""
APT_IMAGE_PACKAGE=""
APT_HEADER_PACKAGE=""
RESOLVED_KERNEL=""
RELEASE_FROM=""
RELEASE_TO=""
DEBIAN_TARGET_CODENAME=""
SYSTEM_ACTION=""
SYSTEM_VALUE=""
TOOL_GROUP=""
CUSTOM_PACKAGE_TEXT=""
RESOLVED_TOOLS=()
RESOLVED_TOOL_COUNT=0
COLOR_ENABLED=0
COLOR_RESET=""
COLOR_DIM=""
COLOR_INFO=""
COLOR_WARN=""
COLOR_ERROR=""
COLOR_TITLE=""
MENU_ARGS=()

init_colors() {
    if [[ -t 1 && -z ${NO_COLOR:-} && ${TERM:-dumb} != "dumb" ]]; then
        COLOR_ENABLED=1
        COLOR_RESET=$'\033[0m'
        COLOR_DIM=$'\033[2m'
        COLOR_INFO=$'\033[32m'
        COLOR_WARN=$'\033[33m'
        COLOR_ERROR=$'\033[31m'
        COLOR_TITLE=$'\033[1;36m'
    fi
}

print_title() {
    printf '%b%s%b\n' "${COLOR_TITLE}" "$*" "${COLOR_RESET}"
}

print_prompt() {
    printf '%b%s%b' "${COLOR_TITLE}" "$*" "${COLOR_RESET}"
}

usage() {
    cat <<EOF
用法：
  sudo ./${SCRIPT_NAME}                       # 显示交互式中文菜单
  sudo ./${SCRIPT_NAME} info                  # 查看当前系统详细信息
  sudo ./${SCRIPT_NAME} kernel [内核选项]
  sudo ./${SCRIPT_NAME} release [发行版选项]
  sudo ./${SCRIPT_NAME} settings [系统设置选项]
  sudo ./${SCRIPT_NAME} tools [工具安装选项]

通用选项：
  info                 显示当前系统详细信息清单，不修改系统
  kernel               内核升级模式
  release              发行版升级模式
  settings             系统常用设置模式
  tools                常用工具安装模式
  --check              只检查升级目标，不修改系统
  -y, --yes            跳过脚本自身的 y/n 确认
  --lock-timeout N     等待正常软件包管理器释放锁，默认 300 秒
  --min-root-gb N      根分区最低可用空间；内核默认 1，发行版默认 5 GiB
  --min-boot-mb N      /boot 最低可用空间；内核默认 300，发行版默认 500 MiB
  -h, --help           显示帮助

内核选项：
  --kernel latest      安装仓库中的最新官方内核（默认）
  --kernel VERSION     安装仓库中的指定内核版本
  --latest             等同于 --kernel latest
  --list               列出仓库缓存中可用的内核版本，不安装
  --no-headers         不安装对应的内核头文件

发行版选项：
  --release next       升级到下一个受支持版本（默认）
  --release latest     与 next 相同；每次只升级一个受支持的大版本
  --release VERSION    指定相邻目标，例如 Ubuntu 24.04、Debian 13

系统设置选项：
  --show-time          查看当前时间、时区和时间同步状态
  --timezone ZONE      设置时区，例如 Asia/Shanghai 或 UTC
  --enable-ntp         启用系统自动时间同步
  --hostname NAME      设置系统主机名

工具安装选项：
  --tool-group GROUP   安装工具组：basic/network/session/monitor/dev/all
  --packages "P..."   安装指定的软件包，多个包使用空格分隔

示例：
  sudo ./${SCRIPT_NAME} kernel --check
  sudo ./${SCRIPT_NAME} kernel --kernel latest
  sudo ./${SCRIPT_NAME} kernel --kernel 6.8.0-85-generic
  sudo ./${SCRIPT_NAME} release --check
  sudo ./${SCRIPT_NAME} release
  sudo ./${SCRIPT_NAME} release --release 24.04
  sudo ./${SCRIPT_NAME} settings --timezone Asia/Shanghai
  sudo ./${SCRIPT_NAME} tools --tool-group basic

说明：
  * 不带参数运行时只显示菜单，不会立即开始升级。
  * 传入 info/kernel/release/settings/tools 参数时可直接执行指定模式。
  * Ubuntu 使用 do-release-upgrade，每次只走一个官方支持的升级路径。
  * Debian 仅支持 11→12、12→13；升级时切换为官方 Debian 软件源，
    原软件源会完整备份，第三方源不会在新版本中自动恢复。
  * Rocky Linux 只在线升级当前大版本的小版本；不执行 8→9、9→10。
  * 发现已有发行版升级、APT/DPKG/DNF 事务时不会杀进程或删除锁。
  * 不自动删除旧内核，不自动重启。
EOF
}

write_log() {
    local level=$1 level_color=$2 output_fd=$3
    shift 3
    printf '%b[%s]%b %b[%s]%b %s\n' \
        "${COLOR_DIM}" "$(date '+%F %T')" "${COLOR_RESET}" \
        "${level_color}" "${level}" "${COLOR_RESET}" "$*" >&"${output_fd}"
}

info() {
    write_log "INFO" "${COLOR_INFO}" 1 "$*"
}

log() {
    info "$*"
}

warn() {
    write_log "WARN" "${COLOR_WARN}" 2 "$*"
}

error() {
    write_log "ERROR" "${COLOR_ERROR}" 2 "$*"
}

die() {
    error "$*"
    exit 1
}

on_error() {
    local exit_code=$?
    local line_no=${BASH_LINENO[0]:-未知}
    error "命令在第 ${line_no} 行失败（退出码 ${exit_code}）"
    [[ -z ${LOG_FILE} ]] || warn "日志：${LOG_FILE}"
    [[ -z ${BACKUP_DIR} ]] || warn "配置快照：${BACKUP_DIR}"
    exit "${exit_code}"
}
trap on_error ERR

kernel_menu() {
    local choice target
    while true; do
        printf '\n'
        print_title "========== 内核管理 =========="
        printf '  1) 升级到仓库中的最新内核\n'
        printf '  2) 安装指定内核版本\n'
        printf '  3) 检查内核升级目标（不修改系统）\n'
        printf '  4) 列出可用内核版本（不修改系统）\n'
        printf '  0) 返回首页\n\n'
        print_prompt "请选择操作 [0-4]："
        read -r choice || die "无法读取内核菜单选项"
        case "${choice}" in
            1) MENU_ARGS=(kernel --kernel latest); return 0 ;;
            2)
                print_prompt "请输入完整内核版本（例如 6.8.0-85-generic）："
                read -r target || die "无法读取内核版本"
                [[ -n ${target} ]] || { warn "内核版本不能为空"; continue; }
                MENU_ARGS=(kernel --kernel "${target}")
                return 0
                ;;
            3) MENU_ARGS=(kernel --check); return 0 ;;
            4) MENU_ARGS=(kernel --list); return 0 ;;
            0) return 1 ;;
            *) warn "无效菜单选项：${choice}" ;;
        esac
    done
}

release_menu() {
    local choice target
    while true; do
        printf '\n'
        print_title "======== 系统发行版升级 ========"
        printf '  1) 升级到下一个受支持的系统发行版\n'
        printf '  2) 升级到指定的相邻发行版\n'
        printf '  3) 检查发行版升级目标（不修改系统）\n'
        printf '  0) 返回首页\n\n'
        print_prompt "请选择操作 [0-3]："
        read -r choice || die "无法读取发行版菜单选项"
        case "${choice}" in
            1) MENU_ARGS=(release --release next); return 0 ;;
            2)
                print_prompt "请输入相邻目标发行版（例如 Ubuntu 24.04 或 Debian 13）："
                read -r target || die "无法读取发行版版本"
                [[ -n ${target} ]] || { warn "发行版版本不能为空"; continue; }
                MENU_ARGS=(release --release "${target}")
                return 0
                ;;
            3) MENU_ARGS=(release --check); return 0 ;;
            0) return 1 ;;
            *) warn "无效菜单选项：${choice}" ;;
        esac
    done
}

timezone_menu() {
    local choice target
    while true; do
        printf '\n'
        print_title "========== 时区设置 =========="
        printf '  1) Asia/Shanghai（中国标准时间）\n'
        printf '  2) Asia/Hong_Kong（香港时间）\n'
        printf '  3) UTC（协调世界时）\n'
        printf '  4) America/Los_Angeles（美国太平洋时间）\n'
        printf '  5) America/New_York（美国东部时间）\n'
        printf '  6) Europe/London（英国时间）\n'
        printf '  7) 自定义时区\n'
        printf '  0) 返回上级菜单\n\n'
        print_prompt "请选择时区 [0-7]："
        read -r choice || die "无法读取时区选项"
        case "${choice}" in
            1) target="Asia/Shanghai" ;;
            2) target="Asia/Hong_Kong" ;;
            3) target="UTC" ;;
            4) target="America/Los_Angeles" ;;
            5) target="America/New_York" ;;
            6) target="Europe/London" ;;
            7)
                print_prompt "请输入时区名称（可用 timedatectl list-timezones 查看）："
                read -r target || die "无法读取时区名称"
                [[ -n ${target} ]] || { warn "时区名称不能为空"; continue; }
                ;;
            0) return 1 ;;
            *) warn "无效菜单选项：${choice}"; continue ;;
        esac
        MENU_ARGS=(settings --timezone "${target}")
        return 0
    done
}

settings_menu() {
    local choice target
    while true; do
        printf '\n'
        print_title "========== 系统常用设置 =========="
        printf '  1) 查看当前时间、时区和同步状态\n'
        printf '  2) 设置系统时区\n'
        printf '  3) 启用自动时间同步（NTP）\n'
        printf '  4) 设置系统主机名\n'
        printf '  0) 返回首页\n\n'
        print_prompt "请选择操作 [0-4]："
        read -r choice || die "无法读取系统设置菜单选项"
        case "${choice}" in
            1) MENU_ARGS=(settings --show-time); return 0 ;;
            2) if timezone_menu; then return 0; fi ;;
            3) MENU_ARGS=(settings --enable-ntp); return 0 ;;
            4)
                print_prompt "请输入新的主机名："
                read -r target || die "无法读取主机名"
                [[ -n ${target} ]] || { warn "主机名不能为空"; continue; }
                MENU_ARGS=(settings --hostname "${target}")
                return 0
                ;;
            0) return 1 ;;
            *) warn "无效菜单选项：${choice}" ;;
        esac
    done
}

tools_menu() {
    local choice target
    while true; do
        printf '\n'
        print_title "========== 常用工具安装 =========="
        printf '  1) 基础工具（curl、wget、git、vim、jq、rsync 等）\n'
        printf '  2) 网络诊断工具（dig、tcpdump、nmap、mtr 等）\n'
        printf '  3) 终端会话工具（screen、tmux）\n'
        printf '  4) 系统监控工具（htop、iotop、iftop、sysstat、ncdu）\n'
        printf '  5) 编译开发工具\n'
        printf '  6) 安装以上全部工具组\n'
        printf '  7) 输入自定义软件包名称\n'
        printf '  0) 返回首页\n\n'
        print_prompt "请选择工具组 [0-7]："
        read -r choice || die "无法读取工具安装菜单选项"
        case "${choice}" in
            1) MENU_ARGS=(tools --tool-group basic); return 0 ;;
            2) MENU_ARGS=(tools --tool-group network); return 0 ;;
            3) MENU_ARGS=(tools --tool-group session); return 0 ;;
            4) MENU_ARGS=(tools --tool-group monitor); return 0 ;;
            5) MENU_ARGS=(tools --tool-group dev); return 0 ;;
            6) MENU_ARGS=(tools --tool-group all); return 0 ;;
            7)
                print_prompt "请输入软件包名称，多个包使用空格分隔："
                IFS= read -r target || die "无法读取软件包名称"
                [[ -n ${target} ]] || { warn "软件包名称不能为空"; continue; }
                MENU_ARGS=(tools --packages "${target}")
                return 0
                ;;
            0) return 1 ;;
            *) warn "无效菜单选项：${choice}" ;;
        esac
    done
}

interactive_menu() {
    local choice

    [[ -t 0 ]] || die "未指定运行模式且当前不是交互终端。请显式指定运行模式"

    while true; do
        printf '\n'
        print_title "========================================"
        print_title " Linux 系统管理与升级工具"
        print_title "========================================"
        printf '  1) 查看当前系统详细信息\n'
        printf '  2) 内核管理\n'
        printf '  3) 系统发行版升级\n'
        printf '  4) 系统常用设置\n'
        printf '  5) 常用工具选择安装\n'
        printf '  0) 退出\n\n'
        print_prompt "请选择功能 [0-5]："
        read -r choice || die "无法读取首页菜单选项"
        case "${choice}" in
            1) MENU_ARGS=(info); return 0 ;;
            2) if kernel_menu; then return 0; fi ;;
            3) if release_menu; then return 0; fi ;;
            4) if settings_menu; then return 0; fi ;;
            5) if tools_menu; then return 0; fi ;;
            0)
                info "用户退出，未执行任何操作"
                exit 0
                ;;
            *) warn "无效菜单选项：${choice}" ;;
        esac
    done
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

print_detail() {
    printf '  %-20s %s\n' "$1" "${2:-未知}"
}

print_section() {
    printf '\n'
    print_title "【$*】"
}

show_system_details() {
    local hostname_value architecture virtualization boot_mode secure_boot
    local uptime_value boot_time cpu_model cpu_cores load_value
    local package_count cached_updates package_status installed_kernels
    local active_upgrade lock_pids failed_services ssh_service reboot_status

    hostname_value=$(hostname -f 2>/dev/null || hostname 2>/dev/null || true)
    architecture=$(uname -m 2>/dev/null || true)
    virtualization=""
    if command_exists systemd-detect-virt; then
        virtualization=$(systemd-detect-virt 2>/dev/null || true)
    fi
    [[ -n ${virtualization} && ${virtualization} != "none" ]] || virtualization="物理机或未检测到"

    if [[ -d /sys/firmware/efi ]]; then
        boot_mode="UEFI"
    else
        boot_mode="传统 BIOS"
    fi

    secure_boot="无法检测"
    if command_exists mokutil; then
        secure_boot=$(mokutil --sb-state 2>/dev/null || true)
        [[ -n ${secure_boot} ]] || secure_boot="无法检测"
    fi

    uptime_value=$(uptime -p 2>/dev/null || true)
    boot_time=$(uptime -s 2>/dev/null || true)
    cpu_model=""
    if command_exists lscpu; then
        cpu_model=$(LC_ALL=C lscpu 2>/dev/null | awk -F: '/^Model name:/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}')
    fi
    cpu_cores=$(command_exists nproc && nproc 2>/dev/null || true)
    load_value=$(awk '{print $1 " / " $2 " / " $3}' /proc/loadavg 2>/dev/null || true)

    print_title "========================================"
    print_title " 当前系统详细信息清单"
    print_title "========================================"

    print_section "系统与主机"
    print_detail "系统名称" "${OS_NAME}"
    print_detail "系统版本" "${OS_VERSION_ID}"
    print_detail "系统代号" "${OS_CODENAME:-无}"
    print_detail "主机名" "${hostname_value}"
    print_detail "硬件架构" "${architecture}"
    print_detail "虚拟化环境" "${virtualization}"
    print_detail "当前时间" "$(date '+%F %T %Z')"
    print_detail "运行时长" "${uptime_value}"
    print_detail "启动时间" "${boot_time}"

    print_section "内核与启动"
    print_detail "当前运行内核" "${RUNNING_KERNEL}"
    print_detail "启动方式" "${boot_mode}"
    print_detail "Secure Boot" "${secure_boot}"
    if command_exists grubby; then
        print_detail "默认启动内核" "$(grubby --default-kernel 2>/dev/null || true)"
    fi

    print_section "处理器与负载"
    print_detail "处理器型号" "${cpu_model}"
    print_detail "逻辑 CPU 数量" "${cpu_cores}"
    print_detail "系统负载 1/5/15 分钟" "${load_value}"

    print_section "内存与交换空间"
    if command_exists free; then
        LC_ALL=C free -h 2>/dev/null | awk 'NR == 1 || /^Mem:/ || /^Swap:/' || true
    else
        warn "找不到 free 命令，无法显示内存信息"
    fi

    print_section "磁盘与文件系统"
    df -hT / /boot 2>/dev/null || df -h / 2>/dev/null || true
    if command_exists lsblk; then
        printf '\n  块设备：\n'
        lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINTS 2>/dev/null || \
            lsblk -o NAME,SIZE,FSTYPE,TYPE,MOUNTPOINT 2>/dev/null || true
    fi

    print_section "网络"
    print_detail "本机 IP 地址" "$(hostname -I 2>/dev/null | xargs 2>/dev/null || true)"
    if command_exists ip; then
        printf '  网络接口：\n'
        ip -brief address show 2>/dev/null || true
        printf '  默认路由：\n'
        ip route show default 2>/dev/null || true
    fi
    if [[ -r /etc/resolv.conf ]]; then
        print_detail "DNS 服务器" "$(awk '/^nameserver/ {printf "%s%s", sep, $2; sep=", "}' /etc/resolv.conf)"
    fi

    print_section "软件包与已安装内核"
    package_count="未知"
    cached_updates="未知"
    package_status="正常"
    installed_kernels=""
    case "${DISTRO}" in
        ubuntu|debian)
            if command_exists dpkg-query; then
                package_count=$(dpkg-query -W -f='${binary:Package}\n' 2>/dev/null | wc -l | tr -d ' ')
                installed_kernels=$(dpkg-query -W -f='${binary:Package}\t${Version}\n' \
                    'linux-image-*' 2>/dev/null | awk '$1 !~ /linux-image-(generic|virtual|aws|azure|gcp|oracle|kvm|lowlatency|cloud-amd64|amd64|arm64)$/ {print "    " $0}' || true)
            fi
            if command_exists apt; then
                cached_updates=$(apt list --upgradable 2>/dev/null | sed '1d' | awk 'NF {count++} END {print count + 0}')
            fi
            if command_exists dpkg && [[ -n $(dpkg --audit 2>/dev/null || true) ]]; then
                package_status="存在未完成配置，请检查 dpkg --audit"
            fi
            ;;
        rocky)
            if command_exists rpm; then
                package_count=$(rpm -qa 2>/dev/null | wc -l | tr -d ' ')
                installed_kernels=$(rpm -q kernel kernel-core 2>/dev/null | sed 's/^/    /' || true)
                rpm --verifydb >/dev/null 2>&1 || package_status="RPM 数据库校验异常"
            fi
            if command_exists dnf; then
                cached_updates=$( { dnf -C -q check-update 2>/dev/null || true; } | \
                    awk 'NF >= 3 && $1 !~ /^(Last|Obsoleting)/ {count++} END {print count + 0}')
            fi
            ;;
    esac
    print_detail "已安装软件包数量" "${package_count}"
    print_detail "缓存中的可升级数量" "${cached_updates}（未刷新仓库索引）"
    print_detail "软件包状态" "${package_status}"
    printf '  已安装内核包：\n'
    if [[ -n ${installed_kernels} ]]; then
        printf '%s\n' "${installed_kernels}"
    else
        printf '    未能读取\n'
    fi

    print_section "服务与升级状态"
    active_upgrade=$(pgrep -af \
        '[d]o-release-upgrade|[D]istUpgrade|[u]buntu-release-upgrader|/tmp/ubuntu-release-upgrader' \
        2>/dev/null || true)
    if [[ -n ${active_upgrade} ]]; then
        print_detail "发行版升级进程" "正在运行"
        printf '%s\n' "${active_upgrade}" | sed 's/^/    /'
    else
        print_detail "发行版升级进程" "未发现"
    fi

    lock_pids=""
    if command_exists fuser; then
        lock_pids=$(package_lock_pids 2>/dev/null || true)
    fi
    if [[ -n ${lock_pids} ]]; then
        print_detail "软件包管理器锁" "被进程 ${lock_pids//$'\n'/, } 占用"
    else
        print_detail "软件包管理器锁" "未发现占用"
    fi

    ssh_service="未知"
    if command_exists systemctl; then
        if systemctl is-active --quiet ssh 2>/dev/null; then
            ssh_service="ssh 服务正在运行"
        elif systemctl is-active --quiet sshd 2>/dev/null; then
            ssh_service="sshd 服务正在运行"
        else
            ssh_service="未检测到运行中的 ssh/sshd 服务"
        fi
    fi
    print_detail "SSH 服务" "${ssh_service}"

    failed_services=""
    if command_exists systemctl; then
        failed_services=$(systemctl --failed --no-legend --plain 2>/dev/null || true)
    fi
    if [[ -n ${failed_services} ]]; then
        print_detail "失败服务" "存在"
        printf '%s\n' "${failed_services}" | sed 's/^/    /'
    else
        print_detail "失败服务" "未发现"
    fi

    reboot_status="当前未检测到重启标记"
    [[ ! -e /var/run/reboot-required ]] || reboot_status="系统要求重启"
    print_detail "重启状态" "${reboot_status}"

    printf '\n'
    info "系统信息读取完成，未执行任何更新或安装操作"
}

confirm_custom_action() {
    local message=$1 answer normalized_answer
    if ((ASSUME_YES == 1)); then
        info "已通过 --yes 自动确认：${message}"
        return 0
    fi

    printf '\n%s\n' "${message}"
    print_prompt "是否继续？[y/N]："
    read -r answer || die "无法读取确认输入；非交互执行请显式使用 --yes"
    normalized_answer=$(printf '%s' "${answer}" | tr '[:upper:]' '[:lower:]')
    case "${normalized_answer}" in
        y|yes) info "用户确认继续" ;;
        *) die "用户取消操作" ;;
    esac
}

create_settings_snapshot() {
    local stamp file
    stamp=$(date '+%Y%m%d-%H%M%S')
    BACKUP_DIR="/var/backups/system-settings-${stamp}"
    install -d -m 0700 "${BACKUP_DIR}"
    for file in /etc/localtime /etc/timezone /etc/hostname; do
        [[ ! -e ${file} && ! -L ${file} ]] || cp -a "${file}" "${BACKUP_DIR}/"
    done
    if command_exists timedatectl; then
        timedatectl status >"${BACKUP_DIR}/timedatectl-before.txt" 2>&1 || true
    fi
    log "已保存系统设置快照：${BACKUP_DIR}"
}

show_time_settings() {
    print_title "========== 当前时间与同步状态 =========="
    print_detail "当前系统时间" "$(date '+%F %T %Z')"
    print_detail "当前 UTC 时间" "$(date -u '+%F %T UTC')"
    print_detail "时区文件" "$(readlink -f /etc/localtime 2>/dev/null || true)"
    if command_exists timedatectl; then
        printf '\n'
        timedatectl status 2>/dev/null || warn "timedatectl 无法读取时间同步状态"
    else
        warn "当前系统没有 timedatectl，仅显示基础时间信息"
    fi
}

run_system_settings() {
    local current_hostname
    case "${SYSTEM_ACTION}" in
        show-time)
            show_time_settings
            return 0
            ;;
        timezone)
            [[ ${SYSTEM_VALUE} =~ ^[A-Za-z0-9_+.-]+(/[A-Za-z0-9_+.-]+)*$ ]] || \
                die "时区名称格式不正确：${SYSTEM_VALUE}"
            [[ ${SYSTEM_VALUE} != *".."* && -e /usr/share/zoneinfo/${SYSTEM_VALUE} ]] || \
                die "系统中找不到时区：${SYSTEM_VALUE}"
            ((EUID == 0)) || die "设置时区需要 root 权限，请使用 sudo 或 root 运行"
            check_no_active_release_upgrade
            confirm_custom_action "即将把系统时区设置为：${SYSTEM_VALUE}"
            setup_logging
            create_settings_snapshot
            if command_exists timedatectl; then
                timedatectl set-timezone "${SYSTEM_VALUE}"
            else
                ln -snf "/usr/share/zoneinfo/${SYSTEM_VALUE}" /etc/localtime
                printf '%s\n' "${SYSTEM_VALUE}" >/etc/timezone
            fi
            log "系统时区已设置为：${SYSTEM_VALUE}"
            show_time_settings
            ;;
        enable-ntp)
            ((EUID == 0)) || die "启用时间同步需要 root 权限，请使用 sudo 或 root 运行"
            check_no_active_release_upgrade
            confirm_custom_action "即将启用系统自动时间同步（NTP）"
            setup_logging
            create_settings_snapshot
            if command_exists timedatectl && timedatectl set-ntp true; then
                log "已通过 timedatectl 启用自动时间同步"
            elif command_exists systemctl && systemctl list-unit-files chronyd.service >/dev/null 2>&1; then
                systemctl enable --now chronyd
                log "已启用 chronyd 时间同步服务"
            elif command_exists systemctl && systemctl list-unit-files systemd-timesyncd.service >/dev/null 2>&1; then
                systemctl enable --now systemd-timesyncd
                log "已启用 systemd-timesyncd 时间同步服务"
            else
                die "未找到可用的时间同步服务，请先安装 chrony 或 systemd-timesyncd"
            fi
            show_time_settings
            ;;
        hostname)
            ((${#SYSTEM_VALUE} <= 253)) || die "主机名长度不能超过 253 个字符"
            [[ ${SYSTEM_VALUE} =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && \
               ${SYSTEM_VALUE} != *".."* ]] || die "主机名格式不正确：${SYSTEM_VALUE}"
            ((EUID == 0)) || die "设置主机名需要 root 权限，请使用 sudo 或 root 运行"
            current_hostname=$(hostname 2>/dev/null || true)
            check_no_active_release_upgrade
            confirm_custom_action "即将把主机名从 ${current_hostname:-未知} 修改为：${SYSTEM_VALUE}"
            setup_logging
            create_settings_snapshot
            if command_exists hostnamectl; then
                hostnamectl set-hostname "${SYSTEM_VALUE}"
            else
                printf '%s\n' "${SYSTEM_VALUE}" >/etc/hostname
                hostname "${SYSTEM_VALUE}"
            fi
            log "系统主机名已设置为：${SYSTEM_VALUE}"
            warn "如业务依赖 /etc/hosts 中的旧主机名，请手动检查并更新对应记录"
            ;;
        *) die "未知系统设置操作：${SYSTEM_ACTION}" ;;
    esac
}

append_unique_tool() {
    local candidate=$1 index
    for ((index = 0; index < RESOLVED_TOOL_COUNT; index++)); do
        [[ ${RESOLVED_TOOLS[index]} != "${candidate}" ]] || return 0
    done
    RESOLVED_TOOLS[RESOLVED_TOOL_COUNT]="${candidate}"
    ((RESOLVED_TOOL_COUNT += 1))
}

append_tool_group() {
    local group=$1 package
    local -a packages=()
    case "${DISTRO}:${group}" in
        ubuntu:basic|debian:basic)
            packages=(curl wget git vim nano jq unzip zip tar rsync tree lsof bash-completion ca-certificates gnupg)
            ;;
        rocky:basic)
            packages=(curl wget git vim-enhanced nano jq unzip zip tar rsync tree lsof bash-completion ca-certificates gnupg2)
            ;;
        ubuntu:network|debian:network)
            packages=(net-tools dnsutils traceroute tcpdump socat nmap iperf3 mtr-tiny)
            ;;
        rocky:network)
            packages=(net-tools bind-utils traceroute tcpdump socat nmap iperf3 mtr)
            ;;
        ubuntu:session|debian:session|rocky:session)
            packages=(screen tmux)
            ;;
        ubuntu:monitor|debian:monitor|rocky:monitor)
            packages=(htop iotop iftop sysstat ncdu)
            ;;
        ubuntu:dev|debian:dev)
            packages=(build-essential pkg-config)
            ;;
        rocky:dev)
            packages=(gcc gcc-c++ make pkgconf-pkg-config)
            ;;
        *) die "无法为 ${DISTRO} 解析工具组：${group}" ;;
    esac
    for package in "${packages[@]}"; do
        append_unique_tool "${package}"
    done
}

build_tool_list() {
    local group package
    local -a custom_packages=()
    RESOLVED_TOOLS=()
    RESOLVED_TOOL_COUNT=0

    if [[ -n ${CUSTOM_PACKAGE_TEXT} ]]; then
        local IFS=' '
        read -r -a custom_packages <<<"${CUSTOM_PACKAGE_TEXT}"
        ((${#custom_packages[@]} > 0)) || die "没有读取到有效的软件包名称"
        for package in "${custom_packages[@]}"; do
            [[ ${package} =~ ^[A-Za-z0-9][A-Za-z0-9.+_:-]*$ ]] || \
                die "软件包名称包含不允许的字符：${package}"
            append_unique_tool "${package}"
        done
        return 0
    fi

    if [[ ${TOOL_GROUP} == "all" ]]; then
        for group in basic network session monitor dev; do
            append_tool_group "${group}"
        done
    else
        append_tool_group "${TOOL_GROUP}"
    fi
}

filter_available_tools() {
    local package index requested_count=${RESOLVED_TOOL_COUNT}
    local -a requested=()
    for ((index = 0; index < requested_count; index++)); do
        requested[index]=${RESOLVED_TOOLS[index]}
    done
    RESOLVED_TOOLS=()
    RESOLVED_TOOL_COUNT=0
    for ((index = 0; index < requested_count; index++)); do
        package=${requested[index]}
        case "${DISTRO}" in
            ubuntu|debian)
                if apt-cache show "${package}" >/dev/null 2>&1; then
                    append_unique_tool "${package}"
                else
                    warn "仓库中找不到软件包，已跳过：${package}"
                fi
                ;;
            rocky)
                if rpm -q "${package}" >/dev/null 2>&1 || \
                   dnf -q list --available "${package}" >/dev/null 2>&1; then
                    append_unique_tool "${package}"
                else
                    warn "当前仓库中找不到软件包，已跳过：${package}"
                fi
                ;;
        esac
    done
}

run_tools_install() {
    local package index
    ((EUID == 0)) || die "安装常用工具需要 root 权限，请使用 sudo 或 root 运行"
    check_no_active_release_upgrade
    build_tool_list

    print_title "========== 计划安装的软件包 =========="
    for ((index = 0; index < RESOLVED_TOOL_COUNT; index++)); do
        package=${RESOLVED_TOOLS[index]}
        printf '  - %s\n' "${package}"
    done
    confirm_custom_action "即将刷新软件仓库索引，并安装以上常用工具。"

    wait_for_package_manager
    check_package_state
    setup_logging
    refresh_metadata
    filter_available_tools
    ((RESOLVED_TOOL_COUNT > 0)) || die "当前仓库中没有可安装的软件包"

    log "实际安装的软件包：${RESOLVED_TOOLS[*]}"
    case "${DISTRO}" in
        ubuntu|debian) apt-get install -y "${RESOLVED_TOOLS[@]}" ;;
        rocky) dnf install -y "${RESOLVED_TOOLS[@]}" ;;
    esac
    log "常用工具安装完成"
    log "日志：${LOG_FILE}"
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            info)
                MODE="info"
                shift
                ;;
            kernel)
                MODE="kernel"
                shift
                ;;
            release)
                MODE="release"
                shift
                ;;
            settings)
                MODE="settings"
                shift
                ;;
            tools)
                MODE="tools"
                shift
                ;;
            --kernel)
                (($# >= 2)) || die "--kernel 缺少版本参数"
                MODE="kernel"
                KERNEL_TARGET=$2
                shift 2
                ;;
            --release)
                MODE="release"
                if (($# >= 2)) && [[ $2 != -* ]]; then
                    RELEASE_TARGET=$2
                    shift 2
                else
                    RELEASE_TARGET="next"
                    shift
                fi
                ;;
            --show-time)
                MODE="settings"
                SYSTEM_ACTION="show-time"
                shift
                ;;
            --timezone)
                (($# >= 2)) || die "--timezone 缺少时区参数"
                MODE="settings"
                SYSTEM_ACTION="timezone"
                SYSTEM_VALUE=$2
                shift 2
                ;;
            --enable-ntp)
                MODE="settings"
                SYSTEM_ACTION="enable-ntp"
                shift
                ;;
            --hostname)
                (($# >= 2)) || die "--hostname 缺少主机名参数"
                MODE="settings"
                SYSTEM_ACTION="hostname"
                SYSTEM_VALUE=$2
                shift 2
                ;;
            --tool-group)
                (($# >= 2)) || die "--tool-group 缺少工具组参数"
                MODE="tools"
                TOOL_GROUP=$2
                shift 2
                ;;
            --packages)
                (($# >= 2)) || die "--packages 缺少软件包名称"
                MODE="tools"
                CUSTOM_PACKAGE_TEXT=$2
                shift 2
                ;;
            --latest)
                if [[ ${MODE} == "release" ]]; then
                    RELEASE_TARGET="next"
                else
                    KERNEL_TARGET="latest"
                fi
                shift
                ;;
            --list)
                LIST_ONLY=1
                shift
                ;;
            --check)
                CHECK_ONLY=1
                shift
                ;;
            --no-headers)
                INSTALL_HEADERS=0
                shift
                ;;
            -y|--yes)
                ASSUME_YES=1
                shift
                ;;
            --min-root-gb)
                (($# >= 2)) || die "--min-root-gb 缺少参数"
                MIN_ROOT_GB=$2
                MIN_ROOT_GB_SET=1
                shift 2
                ;;
            --min-boot-mb)
                (($# >= 2)) || die "--min-boot-mb 缺少参数"
                MIN_BOOT_MB=$2
                MIN_BOOT_MB_SET=1
                shift 2
                ;;
            --lock-timeout)
                (($# >= 2)) || die "--lock-timeout 缺少参数"
                LOCK_TIMEOUT=$2
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "未知参数：$1（使用 --help 查看帮助）"
                ;;
        esac
    done

    [[ ${MIN_ROOT_GB} =~ ^[0-9]+$ ]] || die "--min-root-gb 必须是非负整数"
    [[ ${MIN_BOOT_MB} =~ ^[0-9]+$ ]] || die "--min-boot-mb 必须是非负整数"
    [[ ${LOCK_TIMEOUT} =~ ^[0-9]+$ ]] || die "--lock-timeout 必须是非负整数"
    [[ ${KERNEL_TARGET} == "latest" || ${KERNEL_TARGET} =~ ^[A-Za-z0-9][A-Za-z0-9._+~-]*$ ]] || \
        die "内核版本包含不允许的字符：${KERNEL_TARGET}"
    [[ ${RELEASE_TARGET} == "next" || ${RELEASE_TARGET} == "latest" || \
       ${RELEASE_TARGET} =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
        die "发行版目标包含不允许的字符：${RELEASE_TARGET}"

    if ((LIST_ONLY == 1 && CHECK_ONLY == 1)); then
        die "--list 和 --check 不能同时使用"
    fi

    if [[ ${MODE} == "info" ]]; then
        ((LIST_ONLY == 0 && CHECK_ONLY == 0)) || die "info 模式不支持 --list 或 --check"
        return 0
    fi

    if [[ ${MODE} == "settings" ]]; then
        [[ -n ${SYSTEM_ACTION} ]] || die "settings 模式缺少操作，请使用 --show-time、--timezone、--enable-ntp 或 --hostname"
        ((LIST_ONLY == 0 && CHECK_ONLY == 0)) || die "settings 模式不支持 --list 或 --check"
        return 0
    fi

    if [[ ${MODE} == "tools" ]]; then
        [[ -n ${TOOL_GROUP} || -n ${CUSTOM_PACKAGE_TEXT} ]] || \
            die "tools 模式缺少操作，请使用 --tool-group 或 --packages"
        [[ -z ${TOOL_GROUP} || -z ${CUSTOM_PACKAGE_TEXT} ]] || \
            die "--tool-group 和 --packages 不能同时使用"
        [[ -z ${TOOL_GROUP} || ${TOOL_GROUP} =~ ^(basic|network|session|monitor|dev|all)$ ]] || \
            die "不支持的工具组：${TOOL_GROUP}"
        ((LIST_ONLY == 0 && CHECK_ONLY == 0)) || die "tools 模式不支持 --list 或 --check"
        return 0
    fi

    if [[ ${MODE} == "release" ]]; then
        ((LIST_ONLY == 0)) || die "--list 仅适用于 kernel 模式"
        ((MIN_ROOT_GB_SET == 1)) || MIN_ROOT_GB=5
        ((MIN_BOOT_MB_SET == 1)) || MIN_BOOT_MB=500
    fi
}

load_os_release() {
    [[ -r /etc/os-release ]] || die "找不到 /etc/os-release，无法识别系统"

    # shellcheck disable=SC1091
    source /etc/os-release
    OS_ID=${ID:-}
    OS_ID=$(printf '%s' "${OS_ID}" | tr '[:upper:]' '[:lower:]')
    OS_NAME=${PRETTY_NAME:-${NAME:-未知系统}}
    OS_VERSION_ID=${VERSION_ID:-未知}
    OS_CODENAME=${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}
    RUNNING_KERNEL=$(uname -r)

    case "${OS_ID}" in
        ubuntu)
            DISTRO="ubuntu"
            ;;
        debian)
            DISTRO="debian"
            ;;
        rocky|rockylinux)
            DISTRO="rocky"
            ;;
        *)
            die "不支持的系统：${OS_NAME}（ID=${OS_ID:-空}）"
            ;;
    esac
}

require_root_for_changes() {
    if ((CHECK_ONLY == 0 && LIST_ONLY == 0 && EUID != 0)); then
        die "修改系统需要 root 权限，请使用 sudo 或 root 运行"
    fi
}

detect_kernel_flavor() {
    case "${RUNNING_KERNEL}" in
        *-generic-64k) KERNEL_FLAVOR="generic-64k" ;;
        *-lowlatency)  KERNEL_FLAVOR="lowlatency" ;;
        *-cloud-amd64) KERNEL_FLAVOR="cloud-amd64" ;;
        *-rt-amd64)    KERNEL_FLAVOR="rt-amd64" ;;
        *-amd64)       KERNEL_FLAVOR="amd64" ;;
        *-arm64)       KERNEL_FLAVOR="arm64" ;;
        *-686-pae)     KERNEL_FLAVOR="686-pae" ;;
        *-aws)         KERNEL_FLAVOR="aws" ;;
        *-azure)       KERNEL_FLAVOR="azure" ;;
        *-gcp)         KERNEL_FLAVOR="gcp" ;;
        *-oracle)      KERNEL_FLAVOR="oracle" ;;
        *-kvm)         KERNEL_FLAVOR="kvm" ;;
        *-virtual)     KERNEL_FLAVOR="virtual" ;;
        *-generic)     KERNEL_FLAVOR="generic" ;;
        *)
            KERNEL_FLAVOR=""
            warn "无法从 ${RUNNING_KERNEL} 自动识别内核类型，将使用发行版默认类型"
            ;;
    esac
}

check_not_container() {
    local container_type=""
    if command_exists systemd-detect-virt; then
        container_type=$(systemd-detect-virt --container 2>/dev/null || true)
        if [[ -n ${container_type} && ${container_type} != "none" ]]; then
            die "检测到容器环境（${container_type}）。不支持在容器内执行系统级升级"
        fi
    fi
}

show_active_release_upgrade() {
    local active=""
    active=$(pgrep -af \
        '[d]o-release-upgrade|[D]istUpgrade|[u]buntu-release-upgrader|/tmp/ubuntu-release-upgrader' \
        2>/dev/null || true)
    [[ -z ${active} ]] && return 1

    warn "检测到正在运行的 Ubuntu 发行版升级进程："
    printf '%s\n' "${active}" >&2
    if command_exists screen; then
        screen -ls 2>/dev/null || true
        warn "如会话显示 Detached，可使用：screen -D -r <会话编号或名称>"
    fi
    return 0
}

check_no_active_release_upgrade() {
    if show_active_release_upgrade; then
        die "已有发行版升级正在运行。请先回到该升级会话；不要重复启动、删除锁或杀进程"
    fi
}

package_lock_pids() {
    local lock_file pid
    local -a lock_files=()

    command_exists fuser || return 0
    case "${DISTRO}" in
        ubuntu|debian)
            lock_files=(
                /var/lib/apt/lists/lock
                /var/cache/apt/archives/lock
                /var/lib/dpkg/lock-frontend
                /var/lib/dpkg/lock
            )
            ;;
        rocky)
            lock_files=(/var/run/dnf.pid /var/run/yum.pid)
            ;;
    esac

    for lock_file in "${lock_files[@]}"; do
        [[ -e ${lock_file} ]] || continue
        if [[ ${DISTRO} == "rocky" ]]; then
            pid=$(tr -cd '0-9' <"${lock_file}" 2>/dev/null || true)
            if [[ ${pid} =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
                printf '%s\n' "${pid}"
            fi
        fi
        while IFS= read -r pid; do
            [[ ${pid} =~ ^[0-9]+$ ]] && printf '%s\n' "${pid}"
        done < <(fuser "${lock_file}" 2>/dev/null | tr ' ' '\n')
    done | sort -u
}

wait_for_package_manager() {
    local start now elapsed pids pid
    start=$(date +%s)

    if ! command_exists fuser; then
        warn "系统没有 fuser，无法提前识别软件包锁；包管理器仍会自行阻止并发操作"
        return 0
    fi

    while true; do
        pids=$(package_lock_pids)
        [[ -z ${pids} ]] && return 0

        warn "软件包管理器正被以下进程占用："
        while IFS= read -r pid; do
            ps -o pid,ppid,etime,stat,cmd -p "${pid}" 2>/dev/null || true
        done <<<"${pids}"

        now=$(date +%s)
        elapsed=$((now - start))
        ((elapsed < LOCK_TIMEOUT)) || \
            die "等待软件包锁超过 ${LOCK_TIMEOUT} 秒。未删除锁、未终止进程，请先处理上述占用进程"

        log "等待软件包管理器释放锁（已等待 ${elapsed}/${LOCK_TIMEOUT} 秒）"
        sleep 5
        check_no_active_release_upgrade
    done
}

check_package_state() {
    local audit_output=""
    case "${DISTRO}" in
        ubuntu|debian)
            command_exists apt-get || die "找不到 apt-get"
            command_exists apt-cache || die "找不到 apt-cache"
            command_exists dpkg-query || die "找不到 dpkg-query"
            audit_output=$(dpkg --audit 2>&1 || true)
            if [[ -n ${audit_output} ]]; then
                printf '%s\n' "${audit_output}" >&2
                die "dpkg 状态异常，请先执行：dpkg --configure -a"
            fi
            ;;
        rocky)
            command_exists dnf || die "找不到 dnf"
            command_exists rpm || die "找不到 rpm"
            rpm --verifydb || die "RPM 数据库校验失败，请先修复 RPM 数据库"
            ;;
    esac
}

check_disk_space() {
    local root_free_kb boot_free_kb required_root_kb required_boot_kb boot_path="/boot"
    root_free_kb=$(df -Pk / | awk 'NR == 2 {print $4}')
    [[ ${root_free_kb} =~ ^[0-9]+$ ]] || die "无法读取根分区可用空间"
    required_root_kb=$((MIN_ROOT_GB * 1024 * 1024))
    log "根分区可用：$((root_free_kb / 1024 / 1024)) GiB；要求：${MIN_ROOT_GB} GiB"
    ((root_free_kb >= required_root_kb)) || die "根分区空间不足"

    [[ -d /boot ]] || boot_path="/"
    boot_free_kb=$(df -Pk "${boot_path}" | awk 'NR == 2 {print $4}')
    [[ ${boot_free_kb} =~ ^[0-9]+$ ]] || die "无法读取 /boot 可用空间"
    required_boot_kb=$((MIN_BOOT_MB * 1024))
    log "/boot 所在分区可用：$((boot_free_kb / 1024)) MiB；要求：${MIN_BOOT_MB} MiB"
    ((boot_free_kb >= required_boot_kb)) || \
        die "/boot 空间不足。请先清理不再使用的旧内核，但不要删除当前运行内核"
}

show_environment() {
    log "系统：${OS_NAME}"
    log "当前运行内核：${RUNNING_KERNEL}"
    log "运行模式：${MODE}"
    if [[ ${MODE} == "kernel" ]]; then
        log "检测到的内核类型：${KERNEL_FLAVOR:-发行版默认}"
        log "内核目标：${KERNEL_TARGET}"
    else
        log "发行版目标：${RELEASE_TARGET}"
    fi

    if [[ -n ${SSH_CONNECTION:-} ]]; then
        warn "当前通过 SSH 操作；重启前请确保有云控制台或其他恢复入口"
    fi
    if command_exists mokutil; then
        mokutil --sb-state 2>/dev/null || true
    fi
    if command_exists dkms; then
        local dkms_output
        dkms_output=$(dkms status 2>/dev/null || true)
        [[ -z ${dkms_output} ]] || {
            log "检测到 DKMS 模块："
            printf '%s\n' "${dkms_output}"
        }
    fi
}

apt_package_available() {
    local package_name=$1 candidate
    candidate=$(apt-cache policy "${package_name}" 2>/dev/null \
        | awk '/Candidate:/ {print $2; exit}')
    [[ -n ${candidate} && ${candidate} != "(none)" ]]
}

resolve_ubuntu_latest() {
    local base_meta hwe_meta header_meta

    case "${KERNEL_FLAVOR}" in
        generic|generic-64k|lowlatency|virtual|aws|azure|gcp|oracle|kvm)
            base_meta="linux-${KERNEL_FLAVOR}"
            ;;
        *)
            base_meta="linux-generic"
            ;;
    esac

    hwe_meta="${base_meta}-hwe-${OS_VERSION_ID}"
    if apt_package_available "${hwe_meta}"; then
        APT_IMAGE_PACKAGE=${hwe_meta}
    elif apt_package_available "${base_meta}"; then
        APT_IMAGE_PACKAGE=${base_meta}
    else
        die "找不到适用于 ${OS_NAME} 的内核元包：${hwe_meta} 或 ${base_meta}"
    fi

    header_meta="linux-headers-${APT_IMAGE_PACKAGE#linux-}"
    if ((INSTALL_HEADERS == 1)) && apt_package_available "${header_meta}"; then
        APT_HEADER_PACKAGE=${header_meta}
    fi
}

resolve_debian_latest() {
    local arch default_flavor image_meta header_meta
    arch=$(dpkg --print-architecture)

    case "${KERNEL_FLAVOR}" in
        amd64|cloud-amd64|rt-amd64|arm64|686-pae)
            default_flavor=${KERNEL_FLAVOR}
            ;;
        *)
            case "${arch}" in
                amd64) default_flavor="amd64" ;;
                arm64) default_flavor="arm64" ;;
                i386)  default_flavor="686-pae" ;;
                *)     default_flavor=${arch} ;;
            esac
            ;;
    esac

    image_meta="linux-image-${default_flavor}"
    apt_package_available "${image_meta}" || \
        die "找不到 Debian 内核元包 ${image_meta}，请使用 --list 查看可用版本"
    APT_IMAGE_PACKAGE=${image_meta}

    header_meta="linux-headers-${default_flavor}"
    if ((INSTALL_HEADERS == 1)) && apt_package_available "${header_meta}"; then
        APT_HEADER_PACKAGE=${header_meta}
    fi
}

resolve_apt_specific() {
    local normalized direct_package package_name preferred_suffix=""
    local -a matches=() preferred=()

    normalized=${KERNEL_TARGET#linux-image-}
    direct_package="linux-image-${normalized}"
    if apt_package_available "${direct_package}"; then
        APT_IMAGE_PACKAGE=${direct_package}
    else
        while IFS= read -r package_name; do
            [[ ${package_name} == linux-image-* ]] || continue
            [[ ${package_name} == *dbgsym* || ${package_name} == *unsigned* ]] && continue
            [[ ${package_name} == *"${normalized}"* ]] || continue
            apt_package_available "${package_name}" || continue
            matches+=("${package_name}")
        done < <(apt-cache pkgnames 2>/dev/null | sort -u)

        ((${#matches[@]} > 0)) || \
            die "仓库中找不到匹配 ${KERNEL_TARGET} 的官方内核；请使用 --list 查看可用版本"

        [[ -z ${KERNEL_FLAVOR} ]] || preferred_suffix="-${KERNEL_FLAVOR}"
        if [[ -n ${preferred_suffix} ]]; then
            for package_name in "${matches[@]}"; do
                [[ ${package_name} == *"${preferred_suffix}" ]] && preferred+=("${package_name}")
            done
        fi

        if ((${#preferred[@]} > 0)); then
            APT_IMAGE_PACKAGE=$(printf '%s\n' "${preferred[@]}" | sort -V | tail -n 1)
        elif ((${#matches[@]} == 1)); then
            APT_IMAGE_PACKAGE=${matches[0]}
        else
            warn "匹配到多个内核版本："
            printf '  %s\n' "${matches[@]}" >&2
            die "请使用完整版本名称，例如 --kernel $(printf '%s' "${matches[0]#linux-image-}")"
        fi
    fi

    RESOLVED_KERNEL=${APT_IMAGE_PACKAGE#linux-image-}
    if ((INSTALL_HEADERS == 1)); then
        package_name="linux-headers-${RESOLVED_KERNEL}"
        if apt_package_available "${package_name}"; then
            APT_HEADER_PACKAGE=${package_name}
        else
            warn "仓库中没有找到匹配的头文件 ${package_name}，将只安装内核"
        fi
    fi
}

resolve_apt_target() {
    if [[ ${KERNEL_TARGET} == "latest" ]]; then
        if [[ ${DISTRO} == "ubuntu" ]]; then
            resolve_ubuntu_latest
        else
            resolve_debian_latest
        fi
    else
        resolve_apt_specific
    fi

    log "将安装 APT 内核包：${APT_IMAGE_PACKAGE}"
    [[ -z ${APT_HEADER_PACKAGE} ]] || log "将安装内核头文件：${APT_HEADER_PACKAGE}"
}

list_apt_kernels() {
    local package_name
    local -a packages=()
    while IFS= read -r package_name; do
        [[ ${package_name} == linux-image-[0-9]* ]] || continue
        [[ ${package_name} == *dbgsym* || ${package_name} == *unsigned* ]] && continue
        if [[ -n ${KERNEL_FLAVOR} && ${package_name} != *"-${KERNEL_FLAVOR}" ]]; then
            continue
        fi
        apt_package_available "${package_name}" || continue
        packages+=("${package_name#linux-image-}")
    done < <(apt-cache pkgnames 2>/dev/null | sort -u)

    if ((${#packages[@]} == 0)); then
        warn "本地 APT 缓存中没有匹配的版本。可先执行 apt-get update 后重试"
        return 0
    fi

    log "可用内核版本（最多显示最新 30 个）："
    printf '%s\n' "${packages[@]}" | sort -V | tail -n 30 | sed 's/^/  /'
}

list_rocky_kernels() {
    log "Rocky Linux 仓库中的可用内核："
    dnf --showduplicates list kernel --available || true
}

refresh_metadata() {
    case "${DISTRO}" in
        ubuntu|debian)
            log "刷新 APT 软件包索引"
            apt-get update
            ;;
        rocky)
            log "刷新 DNF 软件包索引"
            dnf makecache --refresh
            ;;
    esac
}

setup_logging() {
    local stamp
    stamp=$(date '+%Y%m%d-%H%M%S')
    LOG_FILE="/var/log/system-${MODE}-upgrade-${stamp}.log"
    touch "${LOG_FILE}"
    chmod 0600 "${LOG_FILE}"
    # 终端保留彩色级别标识，日志文件去掉 ANSI 颜色控制码。
    exec > >(tee >(sed -u $'s/\033\\[[0-9;]*m//g' >>"${LOG_FILE}")) 2>&1
    log "日志：${LOG_FILE}"
}

create_snapshot() {
    local stamp
    stamp=$(date '+%Y%m%d-%H%M%S')
    BACKUP_DIR="/var/backups/system-${MODE}-upgrade-${stamp}"
    install -d -m 0700 "${BACKUP_DIR}"
    uname -a >"${BACKUP_DIR}/uname-before.txt"
    df -h / /boot >"${BACKUP_DIR}/disk-before.txt" 2>&1 || true
    cp -a /etc/os-release "${BACKUP_DIR}/os-release-before" 2>/dev/null || true

    [[ ! -r /etc/default/grub ]] || cp -a /etc/default/grub "${BACKUP_DIR}/grub"
    [[ ! -d /etc/default/grub.d ]] || cp -a /etc/default/grub.d "${BACKUP_DIR}/grub.d"

    case "${DISTRO}" in
        ubuntu|debian)
            dpkg-query -W -f='${binary:Package}\t${Version}\n' \
                >"${BACKUP_DIR}/packages-before.tsv" 2>/dev/null || true
            dpkg --get-selections >"${BACKUP_DIR}/dpkg-selections-before.txt" 2>/dev/null || true
            [[ ! -d /etc/apt ]] || cp -a /etc/apt "${BACKUP_DIR}/apt"
            [[ ! -r /etc/update-manager/release-upgrades ]] || \
                cp -a /etc/update-manager/release-upgrades \
                    "${BACKUP_DIR}/ubuntu-release-upgrades"
            ;;
        rocky)
            rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}.%{ARCH}\n' \
                | sort >"${BACKUP_DIR}/packages-before.tsv"
            dnf repolist --all >"${BACKUP_DIR}/dnf-repolist-before.txt" 2>&1 || true
            [[ ! -d /etc/yum.repos.d ]] || \
                cp -a /etc/yum.repos.d "${BACKUP_DIR}/yum.repos.d"
            if command_exists grubby; then
                grubby --info=ALL >"${BACKUP_DIR}/grubby-before.txt" 2>&1 || true
            fi
            ;;
    esac
    log "已保存软件包、软件源和引导配置快照：${BACKUP_DIR}"
}

confirm_action() {
    local answer normalized_answer
    ((ASSUME_YES == 1)) && return 0

    if [[ ${MODE} == "kernel" ]]; then
        printf '\n即将安装内核，但不会自动重启或删除旧内核。\n'
    else
        printf '\n即将升级系统发行版，过程中服务可能重启或暂时中断。\n'
        printf '请确认已经完成业务、数据和系统配置备份。\n'
    fi
    print_prompt "是否继续？[y/N]："
    if ! read -r answer; then
        die "无法读取确认输入；非交互执行请显式使用 --yes"
    fi
    normalized_answer=$(printf '%s' "${answer}" | tr '[:upper:]' '[:lower:]')
    case "${normalized_answer}" in
        y|yes) log "用户确认继续" ;;
        *) die "用户取消升级" ;;
    esac
}

install_apt_kernel() {
    local yes_args=() package_name
    local -a packages=()
    ((ASSUME_YES == 1)) && yes_args=(-y)

    packages+=("${APT_IMAGE_PACKAGE}")
    [[ -z ${APT_HEADER_PACKAGE} ]] || packages+=("${APT_HEADER_PACKAGE}")

    if [[ -n ${RESOLVED_KERNEL} && ${DISTRO} == "ubuntu" ]]; then
        for package_name in \
            "linux-modules-${RESOLVED_KERNEL}" \
            "linux-modules-extra-${RESOLVED_KERNEL}"; do
            apt_package_available "${package_name}" && packages+=("${package_name}")
        done
    fi

    log "安装内核软件包"
    apt-get "${yes_args[@]}" install --install-recommends -- "${packages[@]}"

    if command_exists update-grub; then
        log "更新 GRUB 菜单"
        update-grub
    fi
}

rocky_target_spec() {
    if [[ ${KERNEL_TARGET} == "latest" ]]; then
        printf '%s\n' "kernel"
    else
        printf 'kernel-%s\n' "${KERNEL_TARGET}"
    fi
}

check_rocky_specific_available() {
    local spec
    spec=$(rocky_target_spec)
    dnf -q --showduplicates list --available "${spec}" 2>/dev/null | grep -q . || \
        die "Rocky Linux 仓库中找不到 ${spec}；请使用 --list 查看可用版本"
}

install_rocky_kernel() {
    local yes_args=() spec devel_spec selected_rpm kernel_path
    ((ASSUME_YES == 1)) && yes_args=(-y)
    spec=$(rocky_target_spec)

    if [[ ${KERNEL_TARGET} == "latest" ]]; then
        log "升级到仓库中的最新 Rocky Linux 内核"
        if rpm -q kernel >/dev/null 2>&1; then
            dnf "${yes_args[@]}" update --refresh -- kernel
        else
            dnf "${yes_args[@]}" install --refresh -- kernel
        fi
        if ((INSTALL_HEADERS == 1)); then
            dnf "${yes_args[@]}" install -- kernel-headers kernel-devel
        fi
    else
        check_rocky_specific_available
        log "安装指定 Rocky Linux 内核：${spec}"
        dnf "${yes_args[@]}" install -- "${spec}"

        if ((INSTALL_HEADERS == 1)); then
            devel_spec="kernel-devel-${KERNEL_TARGET}"
            if dnf -q --showduplicates list --available "${devel_spec}" 2>/dev/null | grep -q .; then
                dnf "${yes_args[@]}" install -- "${devel_spec}"
            else
                warn "仓库中没有匹配的 ${devel_spec}，将只安装内核"
            fi
        fi
    fi

    if [[ ${KERNEL_TARGET} == "latest" ]]; then
        selected_rpm=$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' \
            2>/dev/null | sort -V | tail -n 1)
    else
        selected_rpm=$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' \
            2>/dev/null | grep -F "${KERNEL_TARGET}" | sort -V | tail -n 1 || true)
    fi

    kernel_path="/boot/vmlinuz-${selected_rpm}"
    if [[ -n ${selected_rpm} && -e ${kernel_path} ]] && command_exists grubby; then
        log "将目标内核设为默认启动项：${kernel_path}"
        grubby --set-default "${kernel_path}"
    elif [[ ${KERNEL_TARGET} != "latest" ]]; then
        warn "未能自动定位指定内核的启动文件，请在重启前检查 grubby --info=ALL"
    fi
}

show_installed_kernels() {
    log "已安装的内核："
    case "${DISTRO}" in
        ubuntu|debian)
            dpkg-query -W -f='  ${binary:Package}\t${Version}\n' 'linux-image-*' \
                2>/dev/null | sort -V || true
            ;;
        rocky)
            rpm -q kernel-core --qf '  %{VERSION}-%{RELEASE}.%{ARCH}\n' \
                2>/dev/null | sort -V || true
            ;;
    esac
}

run_check() {
    show_installed_kernels
    case "${DISTRO}" in
        ubuntu|debian)
            resolve_apt_target
            ;;
        rocky)
            if [[ ${KERNEL_TARGET} == "latest" ]]; then
                dnf check-update kernel || {
                    local status=$?
                    [[ ${status} -eq 100 ]] || return "${status}"
                }
            else
                check_rocky_specific_available
                log "仓库中存在指定内核：$(rocky_target_spec)"
            fi
            ;;
    esac
    log "检查完成，未安装任何软件包"
}

finish_message() {
    local newest=""
    show_installed_kernels

    case "${DISTRO}" in
        ubuntu|debian)
            newest=$(find /boot -maxdepth 1 -type f -name 'vmlinuz-*' -printf '%f\n' \
                2>/dev/null | sed 's/^vmlinuz-//' | sort -V | tail -n 1)
            ;;
        rocky)
            newest=$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' \
                2>/dev/null | sort -V | tail -n 1)
            ;;
    esac

    log "内核安装命令执行完成"
    [[ -z ${newest} ]] || log "检测到的最新已安装内核：${newest}"
    warn "当前仍在运行：${RUNNING_KERNEL}"
    warn "请确认引导配置和业务状态后手动重启：reboot"
    warn "重启后使用 uname -r 验证实际运行内核"
    log "日志：${LOG_FILE}"
    log "配置快照：${BACKUP_DIR}"
}

ubuntu_known_next_release() {
    case "${OS_VERSION_ID}" in
        18.04) printf '%s\n' "20.04" ;;
        20.04) printf '%s\n' "22.04" ;;
        22.04) printf '%s\n' "24.04" ;;
        24.04) printf '%s\n' "26.04" ;;
        25.10) printf '%s\n' "26.04" ;;
        *) return 1 ;;
    esac
}

resolve_ubuntu_release_target() {
    local known_next="" requested_base=""
    RELEASE_FROM=${OS_VERSION_ID}
    known_next=$(ubuntu_known_next_release 2>/dev/null || true)

    if [[ ${RELEASE_TARGET} == "next" || ${RELEASE_TARGET} == "latest" ]]; then
        RELEASE_TO=${known_next:-"由 do-release-upgrade 检测的下一个受支持版本"}
    else
        requested_base=$(printf '%s' "${RELEASE_TARGET}" | awk -F. '{print $1 "." $2}')
        [[ -n ${known_next} ]] || \
            die "无法验证 Ubuntu ${OS_VERSION_ID} 的指定升级目标；请改用 --release next"
        [[ ${requested_base} == "${known_next}" ]] || \
            die "Ubuntu ${OS_VERSION_ID} 不能直接升级到 ${RELEASE_TARGET}；下一个支持目标是 ${known_next}"
        RELEASE_TO=${known_next}
    fi

    log "Ubuntu 发行版升级路径：${RELEASE_FROM} → ${RELEASE_TO}"
}

configure_ubuntu_release_prompt() {
    local prompt="normal" config=/etc/update-manager/release-upgrades
    if [[ ${OS_VERSION_ID} =~ ^[0-9]+\.04$ ]] && \
       ((10#${OS_VERSION_ID%%.*} % 2 == 0)); then
        prompt="lts"
    fi

    install -d -m 0755 /etc/update-manager
    [[ -e ${config} ]] || install -m 0644 /dev/null "${config}"
    if grep -qE '^[[:space:]]*Prompt=' "${config}"; then
        sed -i -E "s/^[[:space:]]*Prompt=.*/Prompt=${prompt}/" "${config}"
    else
        printf 'Prompt=%s\n' "${prompt}" >>"${config}"
    fi
    log "Ubuntu 升级通道：Prompt=${prompt}"
}

check_ubuntu_release_available() {
    local output status
    command_exists do-release-upgrade || \
        die "找不到 do-release-upgrade；请先安装 update-manager-core"

    if output=$(LC_ALL=C do-release-upgrade -c 2>&1); then
        status=0
    else
        status=$?
    fi
    printf '%s\n' "${output}"
    ((status == 0)) || die "官方升级器当前没有提供可用的下一版本，或升级检查失败"
}

run_ubuntu_release_upgrade() {
    local -a yes_args=()
    ((ASSUME_YES == 1)) && yes_args=(-y)

    resolve_ubuntu_release_target
    log "先将当前 Ubuntu 版本更新到最新软件包状态"
    apt-get update
    apt-get "${yes_args[@]}" full-upgrade
    apt-get "${yes_args[@]}" install -- update-manager-core

    if [[ -e /var/run/reboot-required ]]; then
        warn "当前版本更新后需要重启，尚未启动发行版升级"
        die "请先执行 reboot，重新登录后再次运行：${SCRIPT_NAME} release --release ${RELEASE_TARGET}"
    fi

    configure_ubuntu_release_prompt
    check_ubuntu_release_available
    log "启动 Ubuntu 官方发行版升级器"
    log "SSH 下升级器可能自动创建 screen 会话；本脚本不要求你预先使用 tmux/screen"
    do-release-upgrade
}

resolve_debian_release_target() {
    local next_version="" next_codename="" requested=""
    RELEASE_FROM="${OS_VERSION_ID}${OS_CODENAME:+ (${OS_CODENAME})}"

    case "${OS_VERSION_ID}:${OS_CODENAME}" in
        11:*|*:bullseye)
            next_version="12"
            next_codename="bookworm"
            ;;
        12:*|*:bookworm)
            next_version="13"
            next_codename="trixie"
            ;;
        *)
            die "脚本仅支持 Debian 11→12 或 12→13 的相邻升级；当前是 ${OS_NAME}"
            ;;
    esac

    if [[ ${RELEASE_TARGET} != "next" && ${RELEASE_TARGET} != "latest" ]]; then
        requested=$(printf '%s' "${RELEASE_TARGET}" | tr '[:upper:]' '[:lower:]')
        [[ ${requested} == "${next_version}" || ${requested} == "${next_codename}" || \
           ${requested} == "${next_version}.0" ]] || \
            die "Debian ${OS_VERSION_ID} 的下一个支持目标是 ${next_version} (${next_codename})，不能直接升级到 ${RELEASE_TARGET}"
    fi

    RELEASE_TO="${next_version} (${next_codename})"
    DEBIAN_TARGET_CODENAME=${next_codename}
}

prepare_debian_official_sources() {
    local target_codename=$1 source_file disabled_dir
    local -a source_files=()
    disabled_dir="${BACKUP_DIR}/apt-sources-disabled"
    install -d -m 0700 "${disabled_dir}"

    if [[ -e /etc/apt/sources.list ]]; then
        mv /etc/apt/sources.list "${disabled_dir}/sources.list"
    fi

    shopt -s nullglob
    source_files=(/etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources)
    shopt -u nullglob
    for source_file in "${source_files[@]}"; do
        mv "${source_file}" "${disabled_dir}/${source_file##*/}"
    done

    install -d -m 0755 /etc/apt/sources.list.d
    install -m 0644 /dev/null /etc/apt/sources.list
    cat >/etc/apt/sources.list.d/debian-release-upgrade.sources <<EOF
Types: deb
URIs: https://deb.debian.org/debian
Suites: ${target_codename} ${target_codename}-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://security.debian.org/debian-security
Suites: ${target_codename}-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
    chmod 0644 /etc/apt/sources.list.d/debian-release-upgrade.sources

    log "已切换到 Debian ${target_codename} 官方软件源"
    warn "原软件源已移至 ${disabled_dir}；第三方源不会自动恢复"
}

run_debian_release_upgrade() {
    local -a yes_args=()
    ((ASSUME_YES == 1)) && yes_args=(-y)

    resolve_debian_release_target
    log "Debian 发行版升级路径：${RELEASE_FROM} → ${RELEASE_TO}"
    log "先将当前 Debian 版本更新到最新软件包状态"
    apt-get update
    apt-get "${yes_args[@]}" full-upgrade

    if [[ -e /var/run/reboot-required ]]; then
        warn "当前版本更新后需要重启，尚未切换 Debian 软件源"
        die "请先执行 reboot，重新登录后再次运行：${SCRIPT_NAME} release --release ${RELEASE_TARGET}"
    fi

    prepare_debian_official_sources "${DEBIAN_TARGET_CODENAME}"
    apt-get update
    log "执行 Debian 最小升级"
    apt-get "${yes_args[@]}" upgrade --without-new-pkgs
    log "执行 Debian 完整发行版升级"
    apt-get "${yes_args[@]}" full-upgrade
}

resolve_rocky_release_target() {
    local current_major requested_major
    current_major=${OS_VERSION_ID%%.*}
    RELEASE_FROM=${OS_VERSION_ID}

    if [[ ${RELEASE_TARGET} == "next" || ${RELEASE_TARGET} == "latest" ]]; then
        RELEASE_TO="Rocky Linux ${current_major} 的仓库最新小版本"
        return 0
    fi

    requested_major=${RELEASE_TARGET%%.*}
    [[ ${requested_major} == "${current_major}" ]] || \
        die "Rocky Linux 官方不支持 ${current_major}→${requested_major} 原地大版本升级；请新装系统后迁移数据"
    RELEASE_TO="Rocky Linux ${RELEASE_TARGET}（以仓库实际提供版本为准）"
}

run_rocky_release_upgrade() {
    local -a yes_args=()
    ((ASSUME_YES == 1)) && yes_args=(-y)
    resolve_rocky_release_target
    log "Rocky Linux 升级目标：${RELEASE_FROM} → ${RELEASE_TO}"
    dnf "${yes_args[@]}" upgrade --refresh
}

run_release_check() {
    case "${DISTRO}" in
        ubuntu)
            resolve_ubuntu_release_target
            check_ubuntu_release_available
            ;;
        debian)
            resolve_debian_release_target
            log "Debian 发行版升级路径：${RELEASE_FROM} → ${RELEASE_TO}"
            ;;
        rocky)
            resolve_rocky_release_target
            log "Rocky Linux 升级目标：${RELEASE_FROM} → ${RELEASE_TO}"
            dnf check-update || {
                local status=$?
                [[ ${status} -eq 100 ]] || return "${status}"
            }
            ;;
    esac
    log "发行版检查完成，未修改系统"
}

run_release_upgrade() {
    case "${DISTRO}" in
        ubuntu) run_ubuntu_release_upgrade ;;
        debian) run_debian_release_upgrade ;;
        rocky) run_rocky_release_upgrade ;;
    esac
}

finish_release_message() {
    log "发行版升级命令执行完成"
    if [[ -r /etc/os-release ]]; then
        log "当前系统标识：$(. /etc/os-release; printf '%s' "${PRETTY_NAME:-${NAME:-未知}}")"
    fi
    warn "请检查 SSH、网络、存储、数据库和业务服务状态"
    warn "确认无误后手动重启：reboot"
    warn "重启后使用 cat /etc/os-release 和 uname -r 验证版本"
    log "日志：${LOG_FILE}"
    log "配置快照：${BACKUP_DIR}"
}

main() {
    init_colors
    if (($# == 0)); then
        interactive_menu
        parse_args "${MENU_ARGS[@]}"
    else
        parse_args "$@"
    fi
    load_os_release

    if [[ ${MODE} == "info" ]]; then
        show_system_details
        return 0
    fi

    if [[ ${MODE} == "settings" ]]; then
        run_system_settings
        return 0
    fi

    if [[ ${MODE} == "tools" ]]; then
        run_tools_install
        return 0
    fi

    require_root_for_changes
    check_not_container
    [[ ${MODE} != "kernel" ]] || detect_kernel_flavor
    show_environment

    if [[ ${MODE} == "release" ]]; then
        check_no_active_release_upgrade

        if ((CHECK_ONLY == 1)); then
            run_release_check
            return 0
        fi

        wait_for_package_manager
        check_package_state
        check_disk_space
        setup_logging
        create_snapshot
        confirm_action
        run_release_upgrade
        finish_release_message
        return 0
    fi

    if ((LIST_ONLY == 1)); then
        case "${DISTRO}" in
            ubuntu|debian) list_apt_kernels ;;
            rocky) list_rocky_kernels ;;
        esac
        return 0
    fi

    if ((CHECK_ONLY == 1)); then
        check_no_active_release_upgrade
        run_check
        return 0
    fi

    check_no_active_release_upgrade
    wait_for_package_manager
    check_package_state
    check_disk_space
    setup_logging
    create_snapshot
    refresh_metadata

    case "${DISTRO}" in
        ubuntu|debian) resolve_apt_target ;;
        rocky)
            if [[ ${KERNEL_TARGET} != "latest" ]]; then
                check_rocky_specific_available
            fi
            log "将安装 Rocky Linux 内核：$(rocky_target_spec)"
            ;;
    esac

    confirm_action

    case "${DISTRO}" in
        ubuntu|debian) install_apt_kernel ;;
        rocky) install_rocky_kernel ;;
    esac

    finish_message
}

main "$@"
