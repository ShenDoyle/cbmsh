#!/bin/bash
#====================================================================
# Debian 12 系统盘镜像备份/恢复脚本（完整方案）
# 功能：在线备份（含一致性保护） + 离线恢复（含完整性校验）
# 用法：sudo ./system_backup_restore.sh
#====================================================================

set -o pipefail
export LANG=C.UTF-8

#--------------------- 配置区 ---------------------#
BACKUP_DIR="/root/system_backups"              # 备份存放目录
SYSTEM_DISK=""                                 # 系统盘设备（留空自动检测）
REQUIRED_FREE_GB=20                            # 备份目录所在分区最小剩余空间（GB）
PAUSE_SERVICES=("mysql" "postgresql" "docker") # 备份前暂停的服务
MAX_LOAD=4                                     # 建议负载阈值
MIN_AVAIL_MEM_MB=2048                          # 建议最小可用内存（MB）

#--------------------- 颜色定义 ---------------------#
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_info()  { echo -e "${BLUE}[信息]${NC} $1"; }
print_ok()    { echo -e "${GREEN}[成功]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[警告]${NC} $1"; }
print_error() { echo -e "${RED}[错误]${NC} $1"; }

#--------------------- 检查 root ---------------------#
if [[ $EUID -ne 0 ]]; then
    print_error "请使用 root 或 sudo 运行此脚本。"
    exit 1
fi

#--------------------- 工具检查与安装 ---------------------#
REQUIRED_CMDS=("dd" "gzip" "sha256sum" "lsblk" "findmnt" "blockdev" "fsfreeze")
MISSING_CMDS=()

check_required_tools() {
    print_info "检查必需工具..."
    for cmd in "${REQUIRED_CMDS[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            MISSING_CMDS+=("$cmd")
        fi
    done

    if [[ ${#MISSING_CMDS[@]} -gt 0 ]]; then
        print_warn "以下工具未安装：${MISSING_CMDS[*]}"
        read -p "是否现在安装？(yes/no): " INSTALL_ANS
        if [[ "$INSTALL_ANS" == "yes" ]]; then
            # 根据缺失命令安装对应包（Debian/Ubuntu 包名映射）
            PACKAGES_TO_INSTALL=()
            for cmd in "${MISSING_CMDS[@]}"; do
                case "$cmd" in
                    fsfreeze)   PACKAGES_TO_INSTALL+=("util-linux");;  # fsfreeze 在 util-linux 中
                    blockdev)   PACKAGES_TO_INSTALL+=("util-linux");;
                    # 其他命令通常由 coreutils、gzip 等提供，若无则安装 coreutils/gzip
                    *)          PACKAGES_TO_INSTALL+=("coreutils");;
                esac
            done
            # 去重
            PACKAGES_TO_INSTALL=($(echo "${PACKAGES_TO_INSTALL[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))
            print_info "将安装以下软件包：${PACKAGES_TO_INSTALL[*]}"
            apt update && apt install -y "${PACKAGES_TO_INSTALL[@]}"
            if [[ $? -ne 0 ]]; then
                print_error "安装失败，请手动安装后重试。"
                exit 1
            fi
            print_ok "工具安装完成。"
        else
            print_error "缺少必要工具，无法继续。请手动安装：${MISSING_CMDS[*]}"
            exit 1
        fi
    else
        print_ok "所有必需工具已就绪。"
    fi
}

#--------------------- 检测系统盘 ---------------------#
detect_system_disk() {
    if [[ -n "$SYSTEM_DISK" ]]; then
        if [[ ! -b "$SYSTEM_DISK" ]]; then
            print_error "指定的系统盘 $SYSTEM_DISK 不存在。"
            exit 1
        fi
    else
        # 自动检测：根分区所在的整块磁盘
        ROOT_DEV=$(findmnt -n -o SOURCE / | sed 's/[0-9]*$//')
        if [[ -b "$ROOT_DEV" ]]; then
            SYSTEM_DISK="$ROOT_DEV"
        else
            print_error "无法自动检测系统盘，请手动设置脚本顶部的 SYSTEM_DISK 变量。"
            exit 1
        fi
    fi
    print_info "系统盘确定为：$SYSTEM_DISK"
    read -p "确认备份/恢复的目标磁盘是 $SYSTEM_DISK 吗？(yes/no): " CONFIRM_DISK
    if [[ "$CONFIRM_DISK" != "yes" ]]; then
        print_warn "已取消操作。"
        exit 0
    fi
}

#--------------------- 备份环境检查 ---------------------#
check_backup_environment() {
    print_info "正在进行备份环境检查..."

    # 1. 备份目录空间
    mkdir -p "$BACKUP_DIR"
    local avail_gb=$(df -BG "$BACKUP_DIR" | awk 'NR==2 {gsub("G","",$4); print $4}')
    if [[ $avail_gb -lt $REQUIRED_FREE_GB ]]; then
        print_error "备份目录所在分区可用空间不足 ${REQUIRED_FREE_GB}G（当前 ${avail_gb}G）。"
        print_error "建议：清理空间、更改备份目录或缩小备份范围。"
        exit 1
    fi
    print_ok "备份目录空间充足（${avail_gb}G）。"

    # 2. 系统负载
    local load1=$(cat /proc/loadavg | awk '{print $1}')
    if awk "BEGIN {exit !($load1 > $MAX_LOAD)}"; then
        print_warn "当前系统负载较高（1分钟平均负载：$load1，阈值：$MAX_LOAD）。"
        print_warn "建议在低峰期执行备份，或等待负载降低。"
        read -p "是否仍要继续备份？(yes/no): " ANS
        [[ "$ANS" != "yes" ]] && exit 0
    else
        print_ok "系统负载正常（$load1）。"
    fi

    # 3. 可用内存
    local avail_mem=$(free -m | awk '/Mem:/ {print $7}')
    if [[ $avail_mem -lt $MIN_AVAIL_MEM_MB ]]; then
        print_warn "可用内存较低（${avail_mem}MB，建议至少 ${MIN_AVAIL_MEM_MB}MB）。"
        print_warn "备份过程中 dd+gzip 可能消耗额外内存，可能导致系统变慢或 OOM。"
        read -p "是否仍要继续备份？(yes/no): " ANS
        [[ "$ANS" != "yes" ]] && exit 0
    else
        print_ok "可用内存充足（${avail_mem}MB）。"
    fi

    # 4. 文件系统冻结支持
    if command -v fsfreeze &>/dev/null; then
        if fsfreeze -f / 2>/dev/null; then
            fsfreeze -u / 2>/dev/null
            print_ok "根文件系统支持 fsfreeze，备份时将冻结。"
        else
            print_warn "根文件系统不支持 fsfreeze（可能非 ext4/xfs 或挂载选项限制）。"
            print_warn "建议手动停止写入服务，确保数据一致性。"
        fi
    else
        print_warn "fsfreeze 不可用，将跳过文件系统冻结。"
    fi

    # 5. I/O 活跃进程提示
    if command -v iotop &>/dev/null; then
        local top_io=$(iotop -b -n1 -o -q 2>/dev/null | head -5)
        if [[ -n "$top_io" ]]; then
            print_info "当前 I/O 最活跃的进程："
            echo "$top_io"
            print_warn "备份期间这些进程可能产生写入，建议暂停或等待其完成。"
        fi
    else
        print_info "iotop 未安装，跳过 I/O 活跃进程检查（可选安装：apt install iotop）"
    fi
}

#--------------------- 暂停服务与冻结 ---------------------#
pause_services_and_freeze() {
    print_info "备份前将暂停以下服务：${PAUSE_SERVICES[*]}"
    for svc in "${PAUSE_SERVICES[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            systemctl stop "$svc"
            print_warn "已停止服务：$svc"
        else
            print_info "服务 $svc 未运行，跳过。"
        fi
    done
    sleep 3
    if command -v fsfreeze &>/dev/null; then
        if fsfreeze -f / 2>/dev/null; then
            print_info "根文件系统已冻结。"
            FSFREEZE_ACTIVE=1
        else
            print_warn "尝试冻结根文件系统失败，备份可能产生轻微不一致。"
        fi
    fi
}

#--------------------- 恢复服务与解冻 ---------------------#
resume_services_and_thaw() {
    if [[ "${FSFREEZE_ACTIVE:-0}" -eq 1 ]]; then
        fsfreeze -u / 2>/dev/null
        print_info "已解冻文件系统。"
    fi
    for svc in "${PAUSE_SERVICES[@]}"; do
        if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            systemctl start "$svc"
            print_info "已启动服务：$svc"
        fi
    done
}

#--------------------- 备份主流程 ---------------------#
do_backup() {
    check_required_tools
    check_backup_environment
    local date_str=$(date +"%Y-%m-%d_%H-%M-%S")
    local backup_file="$BACKUP_DIR/debian12_backup_${date_str}.img.gz"
    print_info "开始备份 $SYSTEM_DISK 到 $backup_file ..."

    pause_services_and_freeze

    dd if="$SYSTEM_DISK" bs=1M status=progress | gzip > "$backup_file"
    local dd_exit=${PIPESTATUS[0]}   # dd 的退出码
    if [[ $dd_exit -eq 0 ]]; then
        print_ok "备份完成：$backup_file"
        print_info "正在计算 SHA256 校验值..."
        sha256sum "$backup_file" > "${backup_file}.sha256"
        print_ok "校验文件已生成：${backup_file}.sha256"
    else
        print_error "备份过程中 dd 出错，备份文件可能不完整。"
    fi

    resume_services_and_thaw
}

#--------------------- 恢复环境检查 ---------------------#
check_restore_environment() {
    print_info "正在进行恢复环境检查..."

    # 1. 禁止在线恢复
    local current_root=$(findmnt -n -o SOURCE /)
    if [[ "$current_root" == "$SYSTEM_DISK"* ]]; then
        print_error "当前系统正运行在 $SYSTEM_DISK 上，禁止在线恢复！"
        print_error "请使用 Live CD / 救援模式启动系统，挂载备份文件所在介质后，再运行本脚本。"
        exit 1
    fi
    print_ok "当前系统未运行在目标磁盘上，可以安全恢复。"

    # 2. 备份文件存在性
    if [[ ! -f "$RESTORE_FILE" ]]; then
        print_error "备份文件不存在：$RESTORE_FILE"
        exit 1
    fi
    print_ok "备份文件存在。"

    # 3. SHA256 校验
    if [[ -f "${RESTORE_FILE}.sha256" ]]; then
        print_info "发现校验文件，开始验证备份完整性..."
        if ! (cd "$(dirname "$RESTORE_FILE")" && sha256sum -c "$(basename "${RESTORE_FILE}.sha256")" >/dev/null 2>&1); then
            print_error "校验失败，备份文件可能已损坏或被篡改！"
            exit 1
        fi
        print_ok "SHA256 校验通过。"
    else
        print_warn "未找到校验文件（${RESTORE_FILE}.sha256），跳过完整性检查。"
    fi

    # 4. 目标盘容量检查
    local backup_uncompressed_size=$(gzip -l "$RESTORE_FILE" 2>/dev/null | awk 'END {print $2}')
    if [[ -z "$backup_uncompressed_size" || "$backup_uncompressed_size" -eq 0 ]]; then
        print_warn "无法获取解压后大小，跳过容量检查。"
    else
        local disk_size=$(blockdev --getsize64 "$SYSTEM_DISK" 2>/dev/null)
        if [[ -z "$disk_size" ]]; then
            print_warn "无法获取目标磁盘容量，跳过容量检查。"
        elif [[ $backup_uncompressed_size -gt $disk_size ]]; then
            print_error "目标磁盘容量小于备份镜像大小，无法恢复。"
            print_error "备份镜像解压后大小：$backup_uncompressed_size 字节，目标磁盘容量：$disk_size 字节。"
            exit 1
        else
            print_ok "目标磁盘容量足够。"
        fi
    fi

    # 5. 目标盘挂载检查
    local mounted=$(lsblk -no MOUNTPOINT "$SYSTEM_DISK" 2>/dev/null | grep -v '^$')
    if [[ -n "$mounted" ]]; then
        print_warn "目标磁盘 $SYSTEM_DISK 当前有分区被挂载："
        echo "$mounted"
        print_warn "恢复前必须卸载所有目标盘上的分区，否则会破坏数据。"
        print_warn "建议：使用 umount 卸载相关分区，或重启到救援模式。"
        read -p "是否已手动卸载？继续？(yes/no): " ANS
        [[ "$ANS" != "yes" ]] && exit 0
    else
        print_ok "目标磁盘当前未被挂载。"
    fi
}

#--------------------- 恢复主流程 ---------------------#
do_restore() {
    check_required_tools
    echo "可用备份文件："
    ls -1 "$BACKUP_DIR"/*.img.gz 2>/dev/null || { print_error "备份目录中没有找到 .img.gz 文件。"; exit 1; }
    echo
    read -p "请输入要恢复的备份文件完整路径: " RESTORE_FILE
    check_restore_environment
    print_warn "警告：恢复操作将覆盖 $SYSTEM_DISK 上的所有数据！此操作不可逆。"
    read -p "请再次输入 'yes' 确认继续，其他输入取消: " CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
        print_warn "已取消恢复操作。"
        exit 0
    fi
    print_info "开始恢复 $SYSTEM_DISK 从 $RESTORE_FILE ..."
    gunzip -c "$RESTORE_FILE" | dd of="$SYSTEM_DISK" bs=1M status=progress
    if [[ $? -eq 0 ]]; then
        print_ok "恢复完成。"
        print_info "建议运行文件系统检查：fsck -f $SYSTEM_DISK"
        print_info "然后重启系统。"
    else
        print_error "恢复过程中出现错误。"
    fi
}

#--------------------- 主菜单 ---------------------#
main() {
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${GREEN}   Debian 12 系统镜像备份/恢复工具（完整版）${NC}"
    echo -e "${GREEN}=============================================${NC}"
    detect_system_disk
    echo
    echo "请选择操作："
    echo "  [1] 备份系统"
    echo "  [2] 恢复系统"
    read -p "输入数字: " MODE

    case "$MODE" in
        1)
            do_backup
            ;;
        2)
            do_restore
            ;;
        *)
            print_error "无效选项"
            exit 1
            ;;
    esac
}

main
