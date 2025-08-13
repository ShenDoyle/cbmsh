#!/bin/bash
# 一键系统镜像备份 + 恢复脚本
# 适用于 Debian 12 / VPS 无快照

BACKUP_DIR="/root/system_backups"
DATE=$(date +"%Y-%m-%d_%H-%M-%S")
SYSTEM_DISK=$(lsblk -d -n -o NAME,TYPE | grep disk | head -n1 | awk '{print "/dev/"$1}')
BACKUP_FILE="$BACKUP_DIR/debian12_backup_$DATE.img.gz"

mkdir -p "$BACKUP_DIR"

echo "=== 系统盘检测结果：$SYSTEM_DISK ==="
echo "=== 备份目录：$BACKUP_DIR ==="
echo

read -p "请选择操作: [1]备份系统  [2]恢复系统  输入数字: " MODE

if [[ "$MODE" == "1" ]]; then
    echo "开始备份系统盘 ($SYSTEM_DISK) ..."
    dd if="$SYSTEM_DISK" bs=1M status=progress | gzip > "$BACKUP_FILE"
    echo "备份完成: $BACKUP_FILE"

elif [[ "$MODE" == "2" ]]; then
    echo "可用备份文件："
    ls -1 "$BACKUP_DIR"/*.img.gz
    echo
    read -p "请输入要恢复的备份文件完整路径: " RESTORE_FILE
    if [[ ! -f "$RESTORE_FILE" ]]; then
        echo "错误: 文件不存在"
        exit 1
    fi
    echo "⚠ 警告：恢复会覆盖 $SYSTEM_DISK 上的全部数据！"
    read -p "确认继续？(yes/no): " CONFIRM
    if [[ "$CONFIRM" == "yes" ]]; then
        gunzip -c "$RESTORE_FILE" | dd of="$SYSTEM_DISK" bs=1M status=progress
        echo "恢复完成，请重启系统。"
    else
        echo "已取消恢复操作。"
    fi

else
    echo "无效选项"
    exit 1
fi
