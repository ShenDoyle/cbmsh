#!/bin/bash
#===============================================================================
# Debian 12 服务器全能检测脚本（信息收集 + 安全审计 + 诊断建议）
# 功能：系统状态、性能、网络、服务、日志、安全、Docker、数据库、深度扫描
# 用法：sudo ./full_server_check.sh [--deep] [输出文件路径]
#        --deep          启用耗时扫描（rkhunter、chkrootkit、clamav）
#        输出文件路径    可选，默认自动生成 system_check_时间戳.txt
#===============================================================================

set -o pipefail
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

#--------------------- 颜色定义（自动判断终端）---------------------#
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; NC=''
fi

#--------------------- 参数解析 ---------------------#
DEEP_SCAN=0
OUTPUT_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --deep)
            DEEP_SCAN=1
            shift
            ;;
        *)
            OUTPUT_FILE="$1"
            shift
            ;;
    esac
done

if [[ -z "$OUTPUT_FILE" ]]; then
    OUTPUT_FILE="system_check_$(date +%Y%m%d_%H%M%S).txt"
fi

# 重定向所有输出到文件和终端
exec > >(tee -a "$OUTPUT_FILE") 2>&1

#--------------------- 辅助函数 ---------------------#
print_section() {
    echo -e "\n${BLUE}============================================================${NC}"
    echo -e "${CYAN}【$1】${NC}"
    echo -e "${BLUE}============================================================${NC}"
}
print_ok()   { echo -e "${GREEN}[正常]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[警告]${NC} $1"; }
print_error(){ echo -e "${RED}[异常]${NC} $1"; }
add_issue()  { SUMMARY_ISSUES+=("$1"); }

# 安全执行命令
safe_cmd() {
    local cmd="$*"
    set +e
    eval "$cmd" 2>/dev/null
    local status=$?
    set -e
    if [[ $status -ne 0 ]]; then
        echo "  (无法获取此信息，可能权限不足或命令不可用)"
    fi
}

#--------------------- 全局变量 ---------------------#
SUMMARY_ISSUES=()
CORES=$(nproc 2>/dev/null || echo 1)
LOAD1=$(cat /proc/loadavg | awk '{print $1}')
LOAD5=$(cat /proc/loadavg | awk '{print $2}')
LOAD15=$(cat /proc/loadavg | awk '{print $3}')
MEM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
MEM_AVAIL=$(free -m | awk '/^Mem:/{print $7}')
MEM_USED_PERCENT=$(( (MEM_TOTAL - MEM_AVAIL) * 100 / MEM_TOTAL ))
ROOT_USE=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
FAILED_SVCS=$(systemctl list-units --state=failed --no-pager | grep -c "failed")
ZOMBIE_COUNT=$(ps aux | awk '$8=="Z"' | wc -l)

#--------------------- 检测开始 ---------------------#
echo -e "${GREEN}================ Debian 12 服务器全能检测报告 ================${NC}"
echo -e "生成时间：$(date '+%Y-%m-%d %H:%M:%S')"
echo -e "主机名：$(hostname)"
echo -e "内核版本：$(uname -r)"
echo -e "系统版本：$(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
[[ $EUID -ne 0 ]] && print_warn "当前非 root 用户，部分检测可能不完整，建议使用 sudo 运行。"

#==================== 1. 系统负载与运行时间 ====================#
print_section "1. 系统负载与运行时间"
echo "运行时间：$(uptime -p)"
echo "平均负载（1/5/15分钟）：$LOAD1, $LOAD5, $LOAD15  (CPU核心数: $CORES)"
if awk "BEGIN {exit !($LOAD1 > $CORES)}"; then
    print_warn "1分钟平均负载超过 CPU 核心数，可能存在性能瓶颈。"
    add_issue "系统负载过高（$LOAD1 > $CORES）"
fi
echo "当前在线用户数：$(who | wc -l)"
echo "最近登录记录："
last -a 2>/dev/null | head -5

#==================== 2. CPU 与内存 ====================#
print_section "2. CPU 与内存"
echo "CPU 型号：$(lscpu | grep 'Model name' | cut -d':' -f2 | xargs)"
echo "内存使用情况："
free -h
if [[ $MEM_USED_PERCENT -gt 90 ]]; then
    print_error "内存使用率已达 $MEM_USED_PERCENT%，请检查。"
    add_issue "内存使用率过高 ($MEM_USED_PERCENT%)"
fi
echo "占用 CPU 最高的进程："
ps aux --sort=-%cpu | head -6 | awk '{printf "  %-8s CPU:%-5s%% MEM:%-5s%% %s\n", $1, $3, $4, $11}'
echo "占用内存最高的进程："
ps aux --sort=-%mem | head -6 | awk '{printf "  %-8s CPU:%-5s%% MEM:%-5s%% %s\n", $1, $3, $4, $11}'

#==================== 3. 磁盘与文件系统 ====================#
print_section "3. 磁盘与文件系统"
echo "磁盘分区与使用率："
df -hT | grep -vE 'tmpfs|udev|overlay'
if [[ $ROOT_USE -gt 90 ]]; then
    print_error "根分区使用率已达 ${ROOT_USE}%，请立即清理。"
    add_issue "根分区磁盘空间不足 (使用率 ${ROOT_USE}%)"
fi
echo "inode 使用率："
df -i | grep -vE 'tmpfs|udev|overlay'
echo "磁盘 I/O 统计（1秒采样）："
if command -v iostat &>/dev/null; then
    iostat -x 1 1 | tail -n +3
else
    print_warn "iostat 未安装，跳过 I/O 统计（可安装 sysstat）"
fi
echo "磁盘 SMART 健康状态："
if command -v smartctl &>/dev/null; then
    for disk in $(lsblk -d -o NAME | grep -v NAME); do
        smartctl -H /dev/$disk 2>/dev/null | grep -iE "SMART overall-health|SMART Health Status" | sed "s/^/  \/dev\/$disk: /"
    done
else
    print_warn "smartctl 未安装，跳过 SMART 检测"
fi
echo "根目录下占用空间最大的目录："
du -x -h / 2>/dev/null | sort -rh | head -6

#==================== 4. 网络状态 ====================#
print_section "4. 网络状态"
echo "网络接口与 IP 地址："
ip -brief address
echo "网络接口统计（错误/丢包）："
ip -s link
echo "路由表："
ip route show
echo "监听端口与服务："
ss -tulnp | grep LISTEN
echo "已建立的连接（按状态统计）："
ss -tupn | awk 'NR>1 {print $1}' | sort | uniq -c
echo "防火墙规则（nftables 或 iptables）："
if command -v nft &>/dev/null; then
    nft list ruleset | head -50
else
    print_warn "nftables 未安装，尝试 iptables："
    iptables -L -n -v --line-numbers 2>/dev/null | head -30
fi
echo "DNS 配置："
cat /etc/resolv.conf | grep -v '^#'
echo "异常外联连接（非本地、非标准端口）："
ss -ntp | awk '{print $5, $6, $7}' | grep -vE '127.0.0.1|::1' | sort -u | head -20

#==================== 5. 服务与进程 ====================#
print_section "5. 服务与进程"
echo "失败的 systemd 单元："
systemctl list-units --state=failed --no-pager
if [[ $FAILED_SVCS -gt 0 ]]; then
    print_warn "检测到 $FAILED_SVCS 个失败的 systemd 服务。"
    add_issue "存在 $FAILED_SVCS 个失败的 systemd 服务"
fi
echo "开机自启服务数量：$(systemctl list-unit-files --type=service | grep enabled | wc -l)"
echo "关键服务运行状态："
for svc in sshd docker nginx mysql postgresql redis-server cron rsyslog; do
    if systemctl list-unit-files --type=service | grep -q "^${svc}"; then
        status=$(systemctl is-active $svc 2>/dev/null)
        if [[ "$status" == "active" ]]; then
            echo -e "  $svc: ${GREEN}$status${NC}"
        else
            echo -e "  $svc: ${RED}$status${NC}"
            add_issue "关键服务 $svc 未运行 ($status)"
        fi
    fi
done
echo "僵尸进程检查："
ps aux | awk '$8=="Z"' || echo "无僵尸进程"
if [[ $ZOMBIE_COUNT -gt 0 ]]; then
    print_warn "发现 $ZOMBIE_COUNT 个僵尸进程。"
    add_issue "存在 $ZOMBIE_COUNT 个僵尸进程"
fi
echo "进程树（前30行）："
ps auxf --forest | head -30
echo "systemd 启动耗时分析（前10）："
systemd-analyze blame 2>/dev/null | head -10
echo "定时任务（所有用户）："
for user in $(cut -f1 -d: /etc/passwd); do
    crontab -l -u $user 2>/dev/null | grep -v '^#' | grep -v '^$' | sed "s/^/  [$user] /"
done
echo "系统 timer："
systemctl list-timers --no-pager | head -10

#==================== 6. 安全检查 ====================#
print_section "6. 安全检查"
echo "UID=0 的用户："
awk -F: '$3==0 {print $1}' /etc/passwd
echo "可登录用户："
grep -vE '/nologin|/false' /etc/passwd | cut -d: -f1
echo "SSH 配置关键项："
sshd -T 2>/dev/null | grep -E "permitrootlogin|passwordauthentication|pubkeyauthentication|port " || print_warn "sshd 未运行或无法读取配置"
echo "登录失败记录（最近 10 条）："
lastb -a 2>/dev/null | head -10 || echo "无失败记录"
echo "SUID 文件（前 20 个）："
find / -perm /4000 -type f 2>/dev/null | head -20
echo "全局可写目录（前 10 个）："
find / -xdev -type d -perm -0002 -not -path "/proc/*" -not -path "/sys/*" -not -path "/dev/*" 2>/dev/null | head -10
echo "可疑进程（挖矿、恶意软件常见名称）："
SUSPICIOUS_PROC=$(ps aux | grep -iE "miner|xmrig|kworkerds|kinsing|masscan|randsome" | grep -v grep)
if [[ -n "$SUSPICIOUS_PROC" ]]; then
    echo "$SUSPICIOUS_PROC"
    print_error "发现可疑进程！"
    add_issue "检测到可疑进程"
else
    echo "未发现可疑进程"
fi
echo "可升级的安全更新："
SECURITY_UPDATES=$(apt list --upgradable 2>/dev/null | grep -i security)
if [[ -n "$SECURITY_UPDATES" ]]; then
    echo "$SECURITY_UPDATES"
    print_warn "存在安全更新，建议及时更新。"
    add_issue "存在未安装的安全更新"
else
    echo "无安全更新（建议先运行 apt update）"
fi
echo "关键文件权限："
stat -c '%a %n' /etc/passwd /etc/shadow /etc/group /etc/gshadow 2>/dev/null
echo "内核安全参数："
sysctl kernel.randomize_va_space net.ipv4.tcp_syncookies net.ipv4.ip_forward 2>/dev/null

#==================== 7. 日志检查 ====================#
print_section "7. 日志异常"
echo "系统错误日志（最近 20 条）："
journalctl -p err -b --no-pager 2>/dev/null | tail -20
echo "认证日志（最近 10 条）："
tail -n 10 /var/log/auth.log 2>/dev/null || echo "无法读取 auth.log"
echo "内核 OOM/硬件错误记录："
dmesg 2>/dev/null | grep -iE "out of memory|hardware error|segfault" | tail -10
echo "sudo 使用记录（最近 10 条）："
grep "sudo" /var/log/auth.log 2>/dev/null | tail -10
echo "服务崩溃/重启记录（systemd）："
journalctl -b --no-pager 2>/dev/null | grep -iE "failed|segfault|core dumped" | tail -20

#==================== 8. 软件包状态 ====================#
print_section "8. 软件包状态"
echo "已安装软件包总数：$(dpkg -l | grep '^ii' | wc -l)"
echo "可升级软件包数量：$(apt list --upgradable 2>/dev/null | wc -l)"
echo "自动更新服务状态："
if systemctl is-active --quiet unattended-upgrades 2>/dev/null; then
    print_ok "unattended-upgrades 运行中"
else
    print_warn "unattended-upgrades 未运行"
fi
echo "最近安装的20个软件包："
grep ' install ' /var/log/dpkg.log 2>/dev/null | tail -20 || echo "无法读取 dpkg 日志"
echo "软件源列表："
grep -rhE '^deb ' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | grep -v '^#' | head -20

#==================== 9. Docker 检查（如果安装） ====================#
if command -v docker &>/dev/null; then
    print_section "9. Docker 状态"
    echo "Docker 版本：$(docker --version)"
    echo "Docker 守护进程状态："
    systemctl status docker --no-pager | head -5
    echo "容器列表："
    docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}"
    echo "容器资源使用："
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}"
    echo "Docker 磁盘占用："
    docker system df
    echo "Docker 网络列表："
    docker network ls
    echo "Docker 卷列表："
    docker volume ls
    # 统计容器数量
    total_containers=$(docker ps -a -q 2>/dev/null | wc -l)
    running_containers=$(docker ps -q 2>/dev/null | wc -l)
    stopped_containers=$((total_containers - running_containers))
    echo "容器总数: $total_containers (运行中: $running_containers, 已停止: $stopped_containers)"
    if [[ $stopped_containers -gt 20 ]]; then
        print_warn "有 $stopped_containers 个已停止的容器，建议定期清理（docker container prune）"
        add_issue "存在 $stopped_containers 个已停止的 Docker 容器"
    fi
    echo "Docker 安全配置检查："
    echo "  Docker API 暴露：$(ss -tuln | grep -E ':2375|:2376' || echo '未暴露')"
    echo "  特权容器："
    PRIVILEGED=$(docker ps --quiet --filter 'status=running' | xargs docker inspect --format '{{.Name}} Privileged={{.HostConfig.Privileged}}' 2>/dev/null | grep 'Privileged=true')
    if [[ -n "$PRIVILEGED" ]]; then
        echo "$PRIVILEGED"
        add_issue "存在特权容器"
    else
        echo "  无特权容器"
    fi
    echo "  Docker socket 权限：$(stat -c '%a %U:%G' /var/run/docker.sock 2>/dev/null)"
    echo "  容器挂载敏感目录检查："
    SENSITIVE_MOUNT=$(docker ps -q | xargs docker inspect --format '{{.Name}}: {{range .Mounts}}{{.Source}} -> {{.Destination}} {{end}}' 2>/dev/null | grep -E '/var/run/docker.sock|/etc|/root')
    if [[ -n "$SENSITIVE_MOUNT" ]]; then
        echo "$SENSITIVE_MOUNT"
        add_issue "容器挂载敏感目录"
    else
        echo "  无敏感挂载"
    fi
else
    print_section "9. Docker 检查"
    print_warn "Docker 未安装"
fi

#==================== 10. 数据库连接统计（可选） ====================#
print_section "10. 数据库连接统计"
declare -A db_ports=(
    [3306]="MySQL/MariaDB"
    [5432]="PostgreSQL"
    [6379]="Redis"
    [27017]="MongoDB"
)
for port in "${!db_ports[@]}"; do
    if ss -tuln | grep -q ":${port}\b"; then
        service_name="${db_ports[$port]}"
        conn_count=$(ss -tunp state established 2>/dev/null | awk -v p="$port" '$5 ~ /:'"$port"'$/ {count++} END{print count+0}')
        proc_name=$(ss -tulnp 2>/dev/null | awk -v p="$port" '$5 ~ /:'"$port"'$/ {print $7}' | head -1 | cut -d',' -f2 | tr -d '()')
        echo "端口 $port ($service_name): $conn_count 个 ESTABLISHED 连接 (进程: ${proc_name:-未知})"
        if [[ -n "$conn_count" ]] && (( conn_count > 100 )); then
            print_warn "  $service_name 连接数达到 $conn_count，建议检查连接池或调整 max_connections"
            add_issue "数据库 $service_name 连接数过高 ($conn_count)"
        fi
    else
        echo "端口 $port (${db_ports[$port]}) 未监听（服务可能未运行）"
    fi
done

#==================== 11. 深度扫描（可选） ====================#
print_section "11. 深度扫描（木马/Rootkit/病毒）"
if [[ $DEEP_SCAN -eq 1 ]]; then
    if command -v rkhunter &>/dev/null; then
        echo "运行 rkhunter（可能需要几分钟）..."
        rkhunter --check --skip-keypress --report-warnings-only 2>/dev/null | tail -20
    else
        print_warn "rkhunter 未安装，跳过（可 apt install rkhunter）"
    fi
    if command -v chkrootkit &>/dev/null; then
        echo "运行 chkrootkit..."
        chkrootkit 2>/dev/null | grep -E "INFECTED|Suspicious|Vulnerable" || echo "未发现异常"
    else
        print_warn "chkrootkit 未安装，跳过（可 apt install chkrootkit）"
    fi
    if command -v clamscan &>/dev/null; then
        echo "运行 ClamAV 扫描 /tmp /dev/shm /var/tmp（可能较慢）..."
        clamscan -r --max-filesize=100M --max-scansize=100M /tmp /dev/shm /var/tmp 2>/dev/null | tail -20
    else
        print_warn "ClamAV 未安装，跳过（可 apt install clamav && freshclam）"
    fi
else
    echo "未启用深度扫描（使用 --deep 参数启用）。"
    echo "快速手动检查："
    echo "可疑进程："
    ps aux | grep -iE "miner|xmrig|kworkerds|kinsing|masscan" | grep -v grep || echo "无"
    echo "可疑 crontab："
    for user in $(cut -f1 -d: /etc/passwd); do
        crontab -l -u $user 2>/dev/null | grep -v '^#' | grep -v '^$' | grep -iE "wget|curl|base64|/tmp|/dev/shm" && echo "  [用户: $user]"
    done
    echo "/tmp、/dev/shm 中的可执行文件："
    find /tmp /dev/shm -type f -executable 2>/dev/null | head -20
    echo "异常内核模块："
    lsmod | awk '{print $1}' | while read mod; do
        if ! grep -q "$mod" /lib/modules/$(uname -r)/modules.builtin 2>/dev/null && ! grep -q "$mod" /lib/modules/$(uname -r)/modules.order 2>/dev/null; then
            echo "可疑模块：$mod"
        fi
    done
fi

#==================== 12. 综合诊断与建议 ====================#
print_section "12. 综合诊断与建议"
# 磁盘使用率
echo "--- 磁盘使用率检查 ---"
df -hT | awk 'NR>1 {print $6,$7}' | while read -r use mount; do
    use_num=${use%\%}
    if [[ -n "$use_num" && "$use_num" -gt 85 ]]; then
        print_warn "分区 $mount 使用率已达 ${use_num}%，建议清理日志或扩展空间"
        add_issue "分区 $mount 空间不足 (${use_num}%)"
    elif [[ -n "$use_num" && "$use_num" -gt 75 ]]; then
        echo "  分区 $mount 使用率 ${use_num}%，接近建议阈值（75%）"
    fi
done
# 内存
if [[ $MEM_USED_PERCENT -gt 90 ]]; then
    print_warn "内存使用率高达 ${MEM_USED_PERCENT}%，建议增加物理内存或调整 swap"
elif [[ $MEM_USED_PERCENT -gt 75 ]]; then
    echo "  内存使用率 ${MEM_USED_PERCENT}%，可以考虑优化应用内存占用"
fi
# 负载
load_threshold=$(echo "$CORES * 0.7" | bc -l 2>/dev/null || echo "$CORES")
if awk "BEGIN {exit !($LOAD1 > $load_threshold)}"; then
    print_warn "平均负载 $LOAD1 高于建议值（核心数 $CORES，建议保持 < $load_threshold）"
    add_issue "系统负载长期过高"
fi
# 失败服务
if [[ $FAILED_SVCS -gt 0 ]]; then
    print_warn "存在失败的服务，请检查服务列表并修复"
    add_issue "存在失败的服务"
fi
# 可升级包数量
upgradable=$(apt list --upgradable 2>/dev/null | wc -l)
if [[ $upgradable -gt 0 ]]; then
    echo "  有 $upgradable 个软件包可升级（在生产环境中请谨慎更新）"
fi
# 监听端口审查
echo "--- 监听端口审查 ---"
ss -tulpn | awk 'NR>1 {print $5}' | cut -d: -f2 | sort -u | while read -r port; do
    if [[ -n "$port" && "$port" -gt 1024 && "$port" -ne 8080 && "$port" -ne 8443 ]]; then
        echo "  注意：非特权端口 $port 正在被监听，请确认是否必要"
    fi
done
# swappiness
swappiness=$(sysctl -n vm.swappiness 2>/dev/null || echo 60)
if [[ "$swappiness" -gt 60 ]]; then
    echo "  建议将 vm.swappiness 从 $swappiness 降低至 10-20（如果使用SSD）以改善性能"
fi

#==================== 13. 总结报告 ====================#
print_section "13. 检测总结报告"
echo -e "${CYAN}生成时间：$(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "主机：$(hostname) ($(uname -r))"
echo -e "总体评估："
if [[ ${#SUMMARY_ISSUES[@]} -eq 0 ]]; then
    echo -e "${GREEN}  未发现明显异常，系统运行状态良好。${NC}"
else
    echo -e "${YELLOW}  发现 ${#SUMMARY_ISSUES[@]} 个潜在问题，建议关注。${NC}"
    echo "问题列表："
    for issue in "${SUMMARY_ISSUES[@]}"; do
        echo -e "  ${RED}• $issue${NC}"
    done
fi
echo -e "\n资源摘要："
echo "  CPU 核心数：$CORES"
echo "  内存使用率：$MEM_USED_PERCENT%"
echo "  根分区使用率：$ROOT_USE%"
echo "  系统负载：$LOAD1 / $LOAD5 / $LOAD15"
echo "  失败服务数：$FAILED_SVCS"
echo "  僵尸进程数：$ZOMBIE_COUNT"
if command -v docker &>/dev/null; then
    echo "  Docker 容器总数：$total_containers (运行: $running_containers, 停止: $stopped_containers)"
fi

echo -e "\n${GREEN}================ 检测完成，报告已保存至: $OUTPUT_FILE ================${NC}"
