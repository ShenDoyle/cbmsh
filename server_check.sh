#!/bin/bash
#====================================================================
# Debian 12 服务器全面检测脚本（整合版）
# 功能：系统状态、性能、安全、日志、服务、Docker、木马检测等
# 用法：sudo ./full_server_check.sh [--deep]
#        --deep  执行耗时检测（rkhunter、chkrootkit、clamscan 等）
# 作者：自动生成
#====================================================================

set -o pipefail
export LANG=C
export LC_ALL=C

#--------------------- 颜色定义 ---------------------#
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

#--------------------- 全局变量 ---------------------#
DEEP_SCAN=0
if [[ "$1" == "--deep" ]]; then
    DEEP_SCAN=1
fi

#--------------------- 辅助函数 ---------------------#
print_section() {
    echo -e "\n${BLUE}============================================================${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${BLUE}============================================================${NC}"
}

print_ok() {
    echo -e "${GREEN}[OK]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_warn "当前非 root 用户，某些检测可能不完整。建议使用 sudo 运行。"
    fi
}

#--------------------- 主检测开始 ---------------------#
echo -e "${GREEN}================ Debian 12 服务器全面检测报告 ================${NC}"
echo -e "生成时间：$(date '+%Y-%m-%d %H:%M:%S')"
echo -e "主机名：$(hostname)"
echo -e "内核版本：$(uname -r)"
echo -e "系统版本：$(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
check_root

#==================== 1. 系统负载与运行时间 ====================#
print_section "1. 系统负载与运行时间"
echo "运行时间：$(uptime -p)"
echo "平均负载（1/5/15分钟）：$(cat /proc/loadavg | awk '{print $1, $2, $3}')"
echo "当前在线用户数：$(who | wc -l)"
echo "最近登录记录（最后5条）："
last -a 2>/dev/null | head -5

#==================== 2. CPU 与内存 ====================#
print_section "2. CPU 与内存"
echo "CPU 型号：$(lscpu | grep 'Model name' | cut -d':' -f2 | xargs)"
echo "CPU 核心数：$(nproc)"
echo "内存使用："
free -h
echo -e "\n占用 CPU 最高的 5 个进程："
ps aux --sort=-%cpu | head -6 | awk '{printf "%-8s %-5s %-5s %s\n", $1, $3, $4, $11}'
echo -e "\n占用内存最高的 5 个进程："
ps aux --sort=-%mem | head -6 | awk '{printf "%-8s %-5s %-5s %s\n", $1, $3, $4, $11}'
echo -e "\n内存详细信息（/proc/meminfo 关键字段）："
grep -E "MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree|Dirty|Slab" /proc/meminfo

#==================== 3. 磁盘与文件系统 ====================#
print_section "3. 磁盘与文件系统"
echo "磁盘分区与使用率："
df -hT | grep -vE 'tmpfs|udev|overlay'
echo -e "\ninode 使用率："
df -i | grep -vE 'tmpfs|udev|overlay'
echo -e "\n磁盘 I/O 统计（1秒采样）："
if command -v iostat &>/dev/null; then
    iostat -x 1 1 | tail -n +3
else
    print_warn "iostat 未安装，跳过 I/O 统计（可安装 sysstat）"
fi
echo -e "\n磁盘 SMART 健康状态（如果支持）："
if command -v smartctl &>/dev/null; then
    for disk in $(lsblk -d -o NAME | grep -v NAME); do
        smartctl -H /dev/$disk 2>/dev/null | grep -iE "SMART overall-health|SMART Health Status" | sed "s/^/  \/dev\/$disk: /"
    done
else
    print_warn "smartctl 未安装，跳过 SMART 检测（可安装 smartmontools）"
fi
echo -e "\n根目录下占用空间最大的 5 个目录："
du -x -h / 2>/dev/null | sort -rh | head -6

#==================== 4. 网络状态 ====================#
print_section "4. 网络状态"
echo "网络接口与 IP 地址："
ip -brief address
echo -e "\n监听端口与服务："
ss -tulnp | grep LISTEN
echo -e "\n防火墙规则（nftables 或 iptables）："
if command -v nft &>/dev/null; then
    nft list ruleset | head -50
else
    print_warn "nftables 未安装，尝试 iptables："
    iptables -L -n -v --line-numbers 2>/dev/null | head -30
fi
echo -e "\n网络连接统计："
ss -s
echo -e "\nDNS 配置："
cat /etc/resolv.conf | grep -v '^#'
echo -e "\n异常外联连接（非本地、非标准端口）："
ss -ntp | awk '{print $5, $6, $7}' | grep -vE '127.0.0.1|::1' | sort -u | head -20

#==================== 5. 服务与进程 ====================#
print_section "5. 服务与进程"
echo "失败的 systemd 单元："
systemctl list-units --state=failed --no-pager
echo -e "\n开机自启服务数量：$(systemctl list-unit-files --type=service | grep enabled | wc -l)"
echo "关键服务运行状态："
for svc in sshd docker nginx mysql postgresql redis-server cron rsyslog; do
    if systemctl list-unit-files --type=service | grep -q "^${svc}"; then
        status=$(systemctl is-active $svc 2>/dev/null)
        if [[ "$status" == "active" ]]; then
            echo -e "  $svc: ${GREEN}$status${NC}"
        else
            echo -e "  $svc: ${RED}$status${NC}"
        fi
    fi
done
echo -e "\n僵尸进程检查："
ps aux | awk '$8=="Z" {print}' || echo "无僵尸进程"
echo -e "\n定时任务（所有用户）："
for user in $(cut -f1 -d: /etc/passwd); do
    crontab -l -u $user 2>/dev/null | grep -v '^#' | grep -v '^$' | sed "s/^/  [$user] /"
done
echo -e "\n系统 timer："
systemctl list-timers --no-pager | head -10

#==================== 6. 安全检查 ====================#
print_section "6. 安全检查"
echo "UID=0 的用户："
awk -F: '$3==0 {print $1}' /etc/passwd
echo -e "\n可登录用户（有 shell）："
grep -vE '/nologin|/false' /etc/passwd | cut -d: -f1
echo -e "\nSSH 配置关键项："
sshd -T 2>/dev/null | grep -E "permitrootlogin|passwordauthentication|pubkeyauthentication|port " || print_warn "sshd 未运行或无法读取配置"
echo -e "\n登录失败记录（最近 10 条）："
lastb -a 2>/dev/null | head -10 || echo "无失败记录"
echo -e "\nSUID 文件（前 20 个，可能风险）："
find / -perm /4000 -type f 2>/dev/null | head -20
echo -e "\n全局可写目录（/tmp 等，前 10 个）："
find / -xdev -type d -perm -0002 -not -path "/proc/*" -not -path "/sys/*" -not -path "/dev/*" 2>/dev/null | head -10
echo -e "\n可疑进程（挖矿、恶意软件常见名称）："
ps aux | grep -iE "miner|xmrig|kworkerds|kinsing|masscan|randsome" | grep -v grep || echo "未发现可疑进程"
echo -e "\n可升级的安全更新："
apt list --upgradable 2>/dev/null | grep -i security || echo "无安全更新（建议先运行 apt update）"
echo -e "\n关键文件权限："
stat -c '%a %n' /etc/passwd /etc/shadow /etc/group /etc/gshadow 2>/dev/null
echo -e "\n内核安全参数："
sysctl kernel.randomize_va_space net.ipv4.tcp_syncookies net.ipv4.ip_forward 2>/dev/null

#==================== 7. 日志检查 ====================#
print_section "7. 日志异常"
echo "系统错误日志（journalctl -p err，最近 20 条）："
journalctl -p err -b --no-pager 2>/dev/null | tail -20
echo -e "\n认证日志（/var/log/auth.log，最近 10 条）："
tail -n 10 /var/log/auth.log 2>/dev/null || echo "无法读取 auth.log"
echo -e "\n内核 OOM/硬件错误记录："
dmesg 2>/dev/null | grep -iE "out of memory|hardware error|segfault" | tail -10
echo -e "\nsudo 使用记录（最近 10 条）："
grep "sudo" /var/log/auth.log 2>/dev/null | tail -10
echo -e "\n服务崩溃/重启记录（systemd）："
journalctl -b --no-pager 2>/dev/null | grep -iE "failed|segfault|core dumped" | tail -20

#==================== 8. 软件包与更新 ====================#
print_section "8. 软件包状态"
echo "已安装软件包总数：$(dpkg -l | grep '^ii' | wc -l)"
echo "可升级软件包数量：$(apt list --upgradable 2>/dev/null | wc -l)"
echo "自动更新服务状态："
if systemctl is-active --quiet unattended-upgrades 2>/dev/null; then
    print_ok "unattended-upgrades 运行中"
else
    print_warn "unattended-upgrades 未运行"
fi
echo "软件源列表："
grep -rhE '^deb ' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | grep -v '^#' | head -20

#==================== 9. Docker 检查（如果安装） ====================#
if command -v docker &>/dev/null; then
    print_section "9. Docker 状态"
    echo "Docker 版本：$(docker --version)"
    echo "Docker 守护进程状态："
    systemctl status docker --no-pager | head -5
    echo -e "\n容器列表："
    docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}"
    echo -e "\n容器资源使用："
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}"
    echo -e "\nDocker 磁盘占用："
    docker system df
    echo -e "\nDocker 安全配置检查："
    echo "  Docker API 暴露：$(ss -tuln | grep -E ':2375|:2376' || echo '未暴露')"
    echo "  特权容器："
    docker ps --quiet --filter 'status=running' | xargs docker inspect --format '{{.Name}} Privileged={{.HostConfig.Privileged}}' 2>/dev/null | grep 'Privileged=true' || echo "  无特权容器"
    echo "  Docker socket 权限：$(stat -c '%a %U:%G' /var/run/docker.sock 2>/dev/null)"
    echo "  容器挂载敏感目录检查："
    docker ps -q | xargs docker inspect --format '{{.Name}}: {{range .Mounts}}{{.Source}} -> {{.Destination}} {{end}}' 2>/dev/null | grep -E '/var/run/docker.sock|/etc|/root' || echo "  无敏感挂载"
else
    print_section "9. Docker 检查"
    print_warn "Docker 未安装"
fi

#==================== 10. 异常日志/服务/木马深度检测 ====================#
print_section "10. 异常日志/服务/木马深度检测"

# 10.1 异常日志深度
echo "认证失败统计（按 IP）："
lastb -a 2>/dev/null | awk '{print $NF}' | sort | uniq -c | sort -nr | head -10
echo -e "\n成功登录 IP 统计："
last -a 2>/dev/null | awk '{print $NF}' | sort | uniq -c | sort -nr | head -10

# 10.2 异常服务深度
echo -e "\n服务重启次数（24小时内）："
for svc in sshd docker nginx mysql postgresql redis-server; do
    if systemctl list-unit-files --type=service | grep -q "^${svc}"; then
        count=$(journalctl -u $svc --since "24 hours ago" --no-pager 2>/dev/null | grep -cE "Started|Stopped|Failed")
        echo "  $svc: $count 次状态变化"
    fi
done

# 10.3 木马/rootkit 检测
echo -e "\n--- 木马/Rootkit 检测 ---"
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
    echo "未启用深度扫描（--deep），仅进行快速手动检查："
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

#==================== 11. 综合建议 ====================#
print_section "11. 综合建议"
# 磁盘使用率 > 90%
if [[ $(df / | awk 'NR==2 {print $5}' | tr -d '%') -gt 90 ]]; then
    print_error "根分区使用率超过 90%，请清理磁盘。"
fi
# 内存使用率 > 90%
mem_used=$(free | awk '/Mem:/ {printf "%.0f", $3/$2*100}')
if [[ $mem_used -gt 90 ]]; then
    print_error "内存使用率 $mem_used%，超过 90%。"
fi
# 负载 > 核心数
load=$(cat /proc/loadavg | cut -d' ' -f1)
cores=$(nproc)
if awk "BEGIN {exit !($load > $cores)}"; then
    print_error "系统负载 $load 高于 CPU 核心数 $cores，可能存在性能瓶颈。"
fi
# 僵尸进程
zombie=$(ps aux | awk '$8=="Z"' | wc -l)
if [[ $zombie -gt 0 ]]; then
    print_warn "发现 $zombie 个僵尸进程。"
fi
# 失败的 systemd 服务
failed_svcs=$(systemctl list-units --state=failed --no-pager | grep -c "failed")
if [[ $failed_svcs -gt 0 ]]; then
    print_warn "有 $failed_svcs 个失败的 systemd 服务。"
fi
# Docker 未运行
if command -v docker &>/dev/null && ! systemctl is-active --quiet docker; then
    print_warn "Docker 已安装但未运行。"
fi
echo -e "\n${GREEN}================ 检测完成 ================${NC}"