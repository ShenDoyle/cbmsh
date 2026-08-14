#!/bin/bash
#===============================================================================
# 系统信息收集与诊断脚本 (适用于 Debian 12)
# 功能：收集网络、软件、文件、进程、服务、日志、Docker、数据库连接等全方位信息
# 用法：sudo ./system_info.sh [输出文件路径]
# 注意：建议以 root 权限运行，以获得最完整的信息
#===============================================================================

set -euo pipefail

# ---------- 颜色定义（可选） ----------
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

# ---------- 输出文件 ----------
OUTPUT_FILE="${1:-system_info_$(date +%Y%m%d_%H%M%S).txt}"

# 重定向所有输出到文件，同时在终端显示（使用 tee）
exec > >(tee -a "$OUTPUT_FILE") 2>&1

# ---------- 辅助函数 ----------
print_section() {
    echo -e "\n${BLUE}========== $1 ==========${NC}"
    echo "----------------------------------------"
}

print_warning() {
    echo -e "${YELLOW}[警告] $1${NC}"
}

print_error() {
    echo -e "${RED}[错误] $1${NC}"
}

print_success() {
    echo -e "${GREEN}[OK] $1${NC}"
}

# 安全执行命令，失败时输出提示
safe_cmd() {
    local cmd="$*"
    if ! eval "$cmd" 2>/dev/null; then
        echo "  (无法获取此信息，可能权限不足或命令不可用)"
    fi
}

# ---------- 开始收集 ----------
echo "============================================"
echo "  系统信息收集报告"
echo "  生成时间: $(date)"
echo "  主机名: $(hostname)"
echo "============================================"

# ---------- 1. 系统基本信息 ----------
print_section "1. 系统基本信息"
safe_cmd "uname -a"
safe_cmd "lsb_release -a 2>/dev/null || cat /etc/os-release"
safe_cmd "uptime"
safe_cmd "date"

# ---------- 2. CPU 信息 ----------
print_section "2. CPU 信息"
safe_cmd "lscpu | grep -E '^(架构|CPU\(s\)|型号名称|CPU MHz|L3缓存)'"
echo "当前CPU负载（1/5/15分钟）: $(uptime | awk -F'load average:' '{print $2}')"
safe_cmd "top -bn1 | head -20 | grep -E '^%Cpu|^PID|^ *[0-9]+'"

# ---------- 3. 内存信息 ----------
print_section "3. 内存信息"
safe_cmd "free -h"
safe_cmd "vmstat -s | head -20"

# ---------- 4. 磁盘与文件系统 ----------
print_section "4. 磁盘与文件系统"
safe_cmd "df -hT"
safe_cmd "df -iT"
echo "--- 根目录下各目录占用空间（前10） ---"
safe_cmd "du -sh /* 2>/dev/null | sort -hr | head -10"
echo "--- 查找大于100M的大文件（仅限 /var, /home, /tmp，最多20个） ---"
safe_cmd "find /var /home /tmp -type f -size +100M -exec ls -lh {} \\; 2>/dev/null | head -20"

# ---------- 5. 网络信息 ----------
print_section "5. 网络信息"
echo "--- IPv4 地址 ---"
safe_cmd "ip -4 addr show"
echo "--- IPv6 地址 ---"
safe_cmd "ip -6 addr show"
echo "--- 路由表 ---"
safe_cmd "ip route show"
echo "--- 网络接口统计 ---"
safe_cmd "ip -s link"

echo "--- 监听端口 (TCP/UDP) ---"
safe_cmd "ss -tulpn"
echo "--- 已建立的连接（按状态统计） ---"
safe_cmd "ss -tupn | awk 'NR>1 {print \$1}' | sort | uniq -c"
echo "--- iptables 防火墙规则（IPv4） ---"
if command -v iptables &>/dev/null; then
    safe_cmd "iptables -L -n -v --line-numbers | head -50"
else
    echo "iptables 未安装"
fi
echo "--- nftables 规则（如果存在） ---"
safe_cmd "nft list ruleset 2>/dev/null | head -50"

# ---------- 6. 软件包信息 ----------
print_section "6. 软件包信息"
echo "已安装包总数: $(dpkg -l | wc -l)"
echo "--- 最近安装的20个软件包 ---"
safe_cmd "grep ' install ' /var/log/dpkg.log 2>/dev/null | tail -20 || echo '无法读取dpkg日志'"
echo "--- 可升级的软件包（前20） ---"
safe_cmd "apt list --upgradable 2>/dev/null | head -20 || echo 'apt命令不可用或无需升级'"

# ---------- 7. 进程信息 ----------
print_section "7. 进程信息"
echo "--- 所有进程（树形） ---"
safe_cmd "ps auxf --forest | head -60"
echo "--- CPU 占用前10 ---"
safe_cmd "ps aux --sort=-%cpu | head -11"
echo "--- 内存占用前10 ---"
safe_cmd "ps aux --sort=-%mem | head -11"

# ---------- 8. 系统服务 ----------
print_section "8. 系统服务 (systemd)"
echo "--- 正在运行的服务 ---"
safe_cmd "systemctl list-units --type=service --state=running --no-pager"
echo "--- 失败的服务 ---"
safe_cmd "systemctl list-units --type=service --state=failed --no-pager"
echo "--- 最近启动的服务（按时间倒序） ---"
safe_cmd "systemd-analyze blame | head -20"

# ---------- 9. 日志信息 ----------
print_section "9. 日志信息"
echo "--- 最近的系统日志（最后50行） ---"
safe_cmd "journalctl -xe -n 50 --no-pager 2>/dev/null || tail -50 /var/log/syslog"
echo "--- dmesg 最后20行（硬件/内核信息） ---"
safe_cmd "dmesg | tail -20"

# ---------- 10. 用户与登录 ----------
print_section "10. 用户与登录"
echo "--- 当前登录用户 ---"
safe_cmd "who"
echo "--- 最近登录记录（last 15） ---"
safe_cmd "last -n 15"
echo "--- 普通用户列表（UID>=1000） ---"
safe_cmd "getent passwd | awk -F: '\$3>=1000 {print \$1}'"

# ---------- 11. 定时任务 ----------
print_section "11. 定时任务 (cron)"
echo "--- 系统 crontab ---"
safe_cmd "cat /etc/crontab 2>/dev/null || echo '文件不存在'"
echo "--- 用户 crontab (root) ---"
safe_cmd "crontab -l 2>/dev/null || echo '无root用户的crontab'"

# ---------- 12. 安全相关信息 ----------
print_section "12. 安全相关信息"
echo "--- SSH 配置 (允许root登录? 端口等) ---"
safe_cmd "grep -E '^(PermitRootLogin|Port|PasswordAuthentication)' /etc/ssh/sshd_config 2>/dev/null || echo 'sshd_config 不可读'"
echo "--- 已登录用户的活跃会话 ---"
safe_cmd "loginctl list-sessions"

# ---------- 13. 系统限制与内核参数 ----------
print_section "13. 系统限制与内核参数"
echo "--- 打开文件数限制 ---"
safe_cmd "ulimit -n"
echo "--- 内核参数 (vm/swappiness, net.core.somaxconn等) ---"
safe_cmd "sysctl vm.swappiness net.core.somaxconn net.ipv4.tcp_max_syn_backlog 2>/dev/null"

# ---------- 🆕 14. Docker 容器信息 ----------
print_section "14. Docker 容器信息"
if command -v docker &>/dev/null; then
    docker_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "未知")
    echo "Docker 版本: $docker_version"
    echo "--- 容器列表（含状态、镜像、端口） ---"
    safe_cmd "docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'"
    echo "--- 镜像列表（前20个） ---"
    safe_cmd "docker images --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}' | head -21"
    echo "--- 网络列表 ---"
    safe_cmd "docker network ls"
    echo "--- 卷列表 ---"
    safe_cmd "docker volume ls"
    # 统计容器数量
    total_containers=$(docker ps -a -q 2>/dev/null | wc -l)
    running_containers=$(docker ps -q 2>/dev/null | wc -l)
    stopped_containers=$((total_containers - running_containers))
    echo "容器总数: $total_containers (运行中: $running_containers, 已停止: $stopped_containers)"
else
    echo "Docker 未安装或不在 PATH 中"
fi

# ---------- 🆕 15. 数据库连接数（基于端口统计） ----------
print_section "15. 数据库连接数（当前 ESTABLISHED 连接）"
# 定义常见数据库端口及服务名
declare -A db_ports=(
    [3306]="MySQL/MariaDB"
    [5432]="PostgreSQL"
    [6379]="Redis"
    [27017]="MongoDB"
)

for port in "${!db_ports[@]}"; do
    # 检查该端口是否有监听服务
    if ss -tuln | grep -q ":${port}\b"; then
        service_name="${db_ports[$port]}"
        # 统计 ESTABLISHED 连接数（排除本机到自己？但这样能反映真实活动连接）
        conn_count=$(ss -tunp state established 2>/dev/null | awk -v p="$port" '$5 ~ /:'"$port"'$/ {count++} END{print count+0}')
        # 获取该端口对应的进程名（取第一个）
        proc_name=$(ss -tulnp 2>/dev/null | awk -v p="$port" '$5 ~ /:'"$port"'$/ {print $7}' | head -1 | cut -d',' -f2 | tr -d '()')
        echo "端口 $port ($service_name): $conn_count 个 ESTABLISHED 连接 (进程: ${proc_name:-未知})"
        # 如果连接数大于100，给出提示
        if [[ -n "$conn_count" ]] && (( conn_count > 100 )); then
            print_warning "  $service_name 连接数达到 $conn_count，建议检查连接池或调整 max_connections"
        fi
    else
        echo "端口 $port (${db_ports[$port]}) 未监听（服务可能未运行）"
    fi
done

# 额外检查是否有其他数据库端口（如自定义端口），可扩展
echo "--- 其他可能的高端口数据库监听（非标准端口） ---"
ss -tulnp | awk 'NR>1 {print $5, $7}' | grep -E ':(330[0-9]|543[0-9]|637[0-9]|2701[0-9])' | head -5 || echo "无"

#===============================================================================
# 诊断与优化建议
#===============================================================================
print_section "诊断与优化建议"

# 磁盘使用率
echo "--- 磁盘使用率检查 ---"
df -hT | awk 'NR>1 {print $6,$7}' | while read -r use mount; do
    use_num=${use%\%}
    if [[ -n "$use_num" && "$use_num" -gt 85 ]]; then
        print_warning "分区 $mount 使用率已达 ${use_num}%，建议清理日志或扩展空间"
    elif [[ -n "$use_num" && "$use_num" -gt 75 ]]; then
        echo "  分区 $mount 使用率 ${use_num}%，接近建议阈值（75%）"
    fi
done

# 内存使用
mem_total=$(free -m | awk '/^Mem:/{print $2}')
mem_avail=$(free -m | awk '/^Mem:/{print $7}')
if [[ -n "$mem_total" && -n "$mem_avail" ]]; then
    mem_use=$(( (mem_total - mem_avail) * 100 / mem_total ))
    if [[ $mem_use -gt 90 ]]; then
        print_warning "内存使用率高达 ${mem_use}%，建议增加物理内存或调整 swap"
    elif [[ $mem_use -gt 75 ]]; then
        echo "  内存使用率 ${mem_use}%，可以考虑优化应用内存占用"
    fi
fi

# 负载检查
load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk -F, '{print $1}' | xargs)
cpu_cores=$(nproc 2>/dev/null || echo 1)
if [[ -n "$load_avg" ]]; then
    load_threshold=$(echo "$cpu_cores * 0.7" | bc 2>/dev/null || echo "$cpu_cores")
    if (( $(echo "$load_avg > $load_threshold" | bc -l 2>/dev/null || echo 0) )); then
        print_warning "平均负载 $load_avg 高于建议值（核心数 $cpu_cores，建议保持 < $load_threshold）"
    fi
fi

# 失败的服务
failed_svc=$(systemctl list-units --type=service --state=failed --no-pager | wc -l)
if [[ $failed_svc -gt 0 ]]; then
    print_warning "存在失败的服务，请检查上面的服务列表并修复"
fi

# 可升级包数量
upgradable=$(apt list --upgradable 2>/dev/null | wc -l)
if [[ $upgradable -gt 0 ]]; then
    echo "  有 $upgradable 个软件包可升级（在生产环境中请谨慎更新）"
fi

# 检查是否有大量未授权监听端口（非标准端口）
echo "--- 监听端口审查 ---"
ss -tulpn | awk 'NR>1 {print $5}' | cut -d: -f2 | sort -u | while read -r port; do
    if [[ -n "$port" && "$port" -gt 1024 && "$port" -ne 8080 && "$port" -ne 8443 ]]; then
        echo "  注意：非特权端口 $port 正在被监听，请确认是否必要"
    fi
done

# 内核参数优化建议
swappiness=$(sysctl -n vm.swappiness 2>/dev/null || echo 60)
if [[ "$swappiness" -gt 60 ]]; then
    echo "  建议将 vm.swappiness 从 $swappiness 降低至 10-20（如果使用SSD）以改善性能"
fi

# 🆕 Docker 容器数量异常提醒
if command -v docker &>/dev/null; then
    stopped=$(docker ps -a -q -f status=exited 2>/dev/null | wc -l)
    if [[ "$stopped" -gt 20 ]]; then
        print_warning "有 $stopped 个已停止的容器，建议定期清理（docker container prune）以释放磁盘空间"
    fi
fi

echo -e "\n${GREEN}============================================${NC}"
echo -e "${GREEN}收集完毕！完整报告已保存至: $OUTPUT_FILE${NC}"
echo -e "${GREEN}============================================${NC}"

exit 0