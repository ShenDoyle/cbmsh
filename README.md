# 自用 Linux 脚本合集 (cbmsh)

一组在 Debian 12 / VPS 上自用的运维脚本：系统诊断、整盘备份恢复、哪吒监控面板管理。

> 适用环境：Debian 12（部分脚本依赖 `systemd`、`dd`、`docker` 等，运行前请确认目标机已具备）。
> 仓库地址：`git@ssh.github.com:443/ShenDoyle/cbmsh.git`

---

## 脚本一览

| 脚本 | 用途 | 是否交互 | 需要 root |
|------|------|----------|-----------|
| `system_info.sh` | 系统信息收集与诊断 | 否 | 建议 |
| `backup.sh` | 系统盘镜像备份/恢复 | 是（菜单） | 是 |
| `nezha.sh` | 哪吒监控面板管理 | 是（菜单/子命令） | 是 |

---

## 1. system_info.sh — 系统信息收集与诊断

**功能**
全面采集系统状态并生成一份诊断报告，覆盖 15 个维度：
系统基本信息、CPU、内存、磁盘与文件系统、网络（IP/路由/端口/防火墙）、
软件包、进程、systemd 服务、日志（journalctl/dmesg）、用户与登录、cron 定时任务、
SSH/安全、内核参数与 ulimit，以及 **Docker 容器/镜像/网络/卷** 和 **常见数据库端口连接数**
（MySQL/MariaDB、PostgreSQL、Redis、MongoDB）。报告末尾还会给出磁盘/内存/负载/端口/容器的
优化建议（如磁盘使用率 >85%、连接数 >100 会给出警告）。

**使用命令**
```bash
# 不指定路径：报告默认保存到 system_info_YYYYMMDD_HHMMSS.txt
sudo ./system_info.sh

# 指定报告输出路径
sudo ./system_info.sh /root/diag_$(date +%F).txt
```
- 脚本使用 `set -euo pipefail`，失败的单条命令会被安全跳过并提示，不会中断整体收集。
- 建议以 root 运行，否则部分信息（如 `journalctl`、`ss -p` 进程名）可能不完整。
- 适用于 Debian 12；其他发行版的部分命令（如 `lsb_release`、`apt`）需自行替换。

---

## 2. backup.sh — 系统盘镜像备份与恢复

**功能**
一键把整块系统盘做成 `.img.gz` 压缩镜像（方便存放到本地或远程），或把镜像写回系统盘完成恢复。
自动检测系统盘设备名（避免误写其他盘），`dd` 带 `status=progress` 进度条。

**使用命令**
```bash
sudo ./backup.sh
```
运行后交互选择：
- `[1]` 备份系统 → 整盘写入 `/root/system_backups/debian12_backup_<时间>.img.gz`
- `[2]` 恢复系统 → 输入 `.img.gz` 完整路径写回系统盘（⚠ 必须关机进救援模式/其他系统环境执行，不能在当前系统直接写自己）

**注意事项**
- 备份文件大小约等于系统盘容量（压缩后通常小很多）。
- 建议定期把 `/root/system_backups` 里的文件下载到本地保管。
- 恢复时目标磁盘容量必须 ≥ 备份时的磁盘容量。

---

## 3. nezha.sh — 哪吒监控面板管理

**功能**
哪吒监控（Nezha Monitoring）Dashboard 的一键管理脚本（基于官方
[nezhahq](https://github.com/nezhahq/nezha) 脚本封装）。支持 **Docker** 与 **独立安装** 两种方式，
自动识别架构、init 系统（systemd/openrc）与国内外镜像源（含自定义镜像）。

**使用命令**
```bash
# 显示交互菜单（安装方式、语言、站点标题等均可在此选择）
sudo ./nezha.sh

# 直接以子命令方式执行（适合脚本化/自动化）
sudo ./nezha.sh install            # 安装面板端
sudo ./nezha.sh modify_config      # 修改面板配置
sudo ./nezha.sh restart_and_update # 重启并更新面板
sudo ./nezha.sh show_log           # 查看面板日志
sudo ./nezha.sh uninstall          # 卸载管理面板
sudo ./nezha.sh update_script      # 更新本管理脚本
```
- 首次运行菜单会提示选择安装方式（Docker / 独立）及是否使用中国镜像。
- 安装后默认访问地址为 `域名:站点访问端口`（端口默认 8008，安装时可改）。

---

## 一键执行（赋权 + 跑诊断）

把三个脚本都设为可执行，并立即跑一次非交互的系统诊断：

```bash
chmod +x system_info.sh backup.sh nezha.sh && sudo ./system_info.sh diag_$(date +%F).txt && echo "✅ 系统诊断报告已生成" && echo "ℹ️ backup.sh 与 nezha.sh 为交互式脚本，请单独运行（勿直接接在 && 后，以免阻塞等待输入）"
```

> 说明：`backup.sh` 与 `nezha.sh` 都需要人工在菜单中选择操作，无法在无输入的情况下接在 `&&` 链中安全执行；如需备份或装面板，请单独运行上面各自的命令。
