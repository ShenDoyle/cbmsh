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

> 每个脚本都用各自的一条命令直接执行（不再用 `&&` 把多个脚本串在一起）；`backup.sh` 与 `nezha.sh` 为交互式，需人工在菜单里选择。

---

## 1. system_info.sh — 系统信息收集与诊断

**功能**
全面采集系统状态并生成一份诊断报告，覆盖 15 个维度：
系统基本信息、CPU、内存、磁盘与文件系统、网络（IP/路由/端口/防火墙）、
软件包、进程、systemd 服务、日志（journalctl/dmesg）、用户与登录、cron 定时任务、
SSH/安全、内核参数与 ulimit，以及 **Docker 容器/镜像/网络/卷** 和 **常见数据库端口连接数**
（MySQL/MariaDB、PostgreSQL、Redis、MongoDB）。报告末尾还会给出磁盘/内存/负载/端口/容器的
优化建议（如磁盘使用率 >85%、连接数 >100 会给出警告）。

**直接执行命令**
```bash
# 不指定路径：报告默认保存到 system_info_YYYYMMDD_HHMMSS.txt
sudo ./system_info.sh

# 或指定报告输出路径
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

**直接执行命令**
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

**直接执行命令（仓库内脚本）**
```bash
sudo ./nezha.sh                  # 显示交互菜单（安装方式、语言、站点标题等在此选择）
```
常用子命令（适合脚本化/自动化，直接用一行执行）：
```bash
sudo ./nezha.sh install            # 安装面板端
sudo ./nezha.sh modify_config      # 修改面板配置
sudo ./nezha.sh restart_and_update # 重启并更新面板
sudo ./nezha.sh show_log           # 查看面板日志
sudo ./nezha.sh uninstall          # 卸载管理面板
sudo ./nezha.sh update_script      # 更新本管理脚本
```
- 首次运行菜单会提示选择安装方式（Docker / 独立）及是否使用中国镜像。
- 安装后默认访问地址为 `域名:站点访问端口`（端口默认 8008，安装时可改）。

### 静态加速代理外链一键安装（仓库不存安装文件）
哪吒官方安装脚本通过**静态加速代理**拉取，运行时从代理下载到本地执行；仓库只保留 `nezha.sh` 管理脚本本身，**不附带任何下载得到的安装/配置文件**（脚本内部改配置、更新时也会自动从 `raw.githubusercontent.com` / `gitee.com` / `jsdelivr` 等外链拉取）。

```bash
# 方式 A：GitHub 原始地址 + 静态加速代理（国内推荐）
curl -sL https://ghproxy.net/https://raw.githubusercontent.com/nezhahq/scripts/main/install.sh -o nezha.sh && chmod +x nezha.sh && sudo ./nezha.sh

# 方式 B：jsDelivr 静态加速（CDN）
curl -sL https://cdn.jsdelivr.net/gh/nezhahq/scripts@main/install.sh -o nezha.sh && chmod +x nezha.sh && sudo ./nezha.sh
```
> 说明：以上命令在运行时从静态加速代理下载 `install.sh` 到当前目录并执行，整个过程不向本仓库写入任何外部文件。
