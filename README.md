# 自用 Linux 脚本合集 (cbmsh)

一组在 Debian 12 / VPS 上自用的运维脚本：系统全面检测、整盘备份恢复。

> 适用环境：Debian 12（部分脚本依赖 `systemd`、`dd`、`gzip`、`sha256sum` 等，运行前请确认目标机已具备）。
> 仓库地址：`git@ssh.github.com:443/ShenDoyle/cbmsh.git`

---

## 脚本一览

| 脚本 | 用途 | 是否交互 | 需要 root |
|------|------|----------|-----------|
| `server_check.sh` | 系统全面检测（信息收集+安全审计+诊断建议） | 否（可选 `--deep`） | 建议 |
| `backup.sh` | 系统盘镜像备份/恢复 | 是（菜单） | 是 |

> 两个脚本均支持直接下载执行，具体命令见下方说明。

---

## 1. server_check.sh — 系统全面检测脚本

**功能**
一键对 Debian 12 服务器进行多维度体检，输出结构化中文报告并自动保存到文件。覆盖范围：

- 系统负载、CPU、内存、磁盘、网络、服务、进程、定时任务
- 安全审计：SSH 配置、登录失败、SUID 文件、可疑进程、关键文件权限等
- 日志异常：系统错误、认证日志、OOM、sudo 记录、服务崩溃
- Docker 状态：容器/镜像/网络/卷、安全配置（特权容器、敏感挂载）
- 数据库连接统计（MySQL/MariaDB、PostgreSQL、Redis、MongoDB）
- 综合诊断建议：磁盘使用率、内存、负载、失败服务、端口审查、swappiness 等
- 可选深度扫描：`--deep` 参数启用 rkhunter、chkrootkit、ClamAV（需提前安装）

**直接执行命令**

> 自行下载脚本到服务器执行

```bash
# 基础检测（报告默认保存到 system_check_时间戳.txt）
sudo ./server_check.sh

# 指定输出文件
sudo ./server_check.sh /root/my_report.txt

# 启用深度扫描（需要安装 rkhunter、chkrootkit、clamav）
sudo ./server_check.sh --deep /root/my_report.txt
```

> 直接下载仓库脚本并执行

```bash
# 方式 A：GitHub 原始地址 + 静态加速代理（国内推荐）
curl -sL https://ghproxy.net/https://raw.githubusercontent.com/ShenDoyle/cbmsh/main/server_check.sh -o server_check.sh && chmod +x server_check.sh && sudo ./server_check.sh
```

```bash
# 方式 B：jsDelivr 静态加速（CDN）
curl -sL https://cdn.jsdelivr.net/gh/ShenDoyle/cbmsh@main/server_check.sh -o server_check.sh && chmod +x server_check.sh && sudo ./server_check.sh
```

```bash
# 方式 C：GitHub 原始地址
curl -sL https://raw.githubusercontent.com/ShenDoyle/cbmsh/main/server_check.sh -o server_check.sh && chmod +x server_check.sh && sudo ./server_check.sh
```

**注意事项**
- 脚本会自动将终端输出同时保存到文件（可通过参数指定路径，默认 `system_check_时间戳.txt`）。
- 建议以 root 运行，否则部分信息（如 `journalctl`、`ss -p` 进程名）可能不完整。
- 使用 `--deep` 前请先安装相关工具：`apt install rkhunter chkrootkit clamav clamav-daemon`。
- 深度扫描会消耗额外 CPU/内存/磁盘 I/O，建议在低峰期执行。

---

## 2. backup.sh — 系统盘镜像备份与恢复

**功能**
一键把整块系统盘做成 `.img.gz` 压缩镜像，或将镜像写回系统盘完成恢复。包含环境检查、数据一致性保护、SHA256 校验等特性：

- 自动检测系统盘设备（避免误写其他盘），并要求二次确认
- 备份前暂停 MySQL/PostgreSQL/Docker 等关键服务，并用 `fsfreeze` 冻结文件系统
- 备份完成后生成 SHA256 校验文件，恢复前强制校验完整性
- 恢复操作禁止在线执行（必须从 Live CD / 救援模式启动）
- 备份前检查磁盘空间、负载、内存，发现异常会提示建议

**直接执行命令**

> 自行下载脚本到服务器执行

```bash
sudo ./backup.sh
```
运行后交互选择：
- `[1]` 备份系统 → 整盘写入 `/root/system_backups/debian12_backup_<时间>.img.gz`
- `[2]` 恢复系统 → 输入 `.img.gz` 完整路径写回系统盘（⚠ 必须在救援模式或其他系统环境下执行）

> 直接下载仓库脚本并执行

```bash
# 方式 A：GitHub 原始地址 + 静态加速代理（国内推荐）
curl -sL https://ghproxy.net/https://raw.githubusercontent.com/ShenDoyle/cbmsh/main/backup.sh -o backup.sh && chmod +x backup.sh && sudo ./backup.sh
```

```bash
# 方式 B：jsDelivr 静态加速（CDN）
curl -sL https://cdn.jsdelivr.net/gh/ShenDoyle/cbmsh@main/backup.sh -o backup.sh && chmod +x backup.sh && sudo ./backup.sh
```

```bash
# 方式 C：GitHub 原始地址
curl -sL https://raw.githubusercontent.com/ShenDoyle/cbmsh/main/backup.sh -o backup.sh && chmod +x backup.sh && sudo ./backup.sh
```

**注意事项**
- 备份文件会经过 gzip 压缩，体积通常小于系统盘已用空间。
- 建议定期将 `/root/system_backups` 中的文件下载到本地或远程存储。
- 恢复时目标磁盘容量必须 ≥ 备份时的磁盘容量。
- 备份前会自动暂停部分服务（可在脚本顶部 `PAUSE_SERVICES` 变量中调整），请确保业务允许短暂中断。
- 恢复操作会覆盖目标磁盘全部数据，请谨慎操作并提前确认备份文件完整。
