# Linux 系统管理与升级脚本

`upgrade-system.sh` 面向 Ubuntu、Debian 和 Rocky Linux，提供中文分级菜单，用于查看系统信息、管理内核、升级发行版、调整常用系统设置以及选择安装常用工具。

脚本不会把内核升级和发行版升级放在一次操作中连续执行，也不会自动删除旧内核或自动重启。

## 首页菜单

```text
========================================
 Linux 系统管理与升级工具
========================================
  1) 查看当前系统详细信息
  2) 内核管理
  3) 系统发行版升级
  4) 系统常用设置
  5) 常用工具选择安装
  0) 退出
```

不带参数运行即可进入菜单：

```bash
chmod +x upgrade-system.sh
sudo ./upgrade-system.sh
```

## 内核管理

内核子菜单提供：

```text
1) 升级到仓库中的最新内核
2) 安装指定内核版本
3) 检查内核升级目标（不修改系统）
4) 列出可用内核版本（不修改系统）
0) 返回首页
```

也可以使用命令行直接执行：

```bash
sudo ./upgrade-system.sh kernel --check
sudo ./upgrade-system.sh kernel --kernel latest
sudo ./upgrade-system.sh kernel --kernel 6.8.0-85-generic
sudo ./upgrade-system.sh kernel --list
```

Ubuntu 使用官方内核元包或对应 HWE 元包，并尽量保留当前的 `generic`、`aws`、`azure`、`gcp`、`virtual` 等内核类型。Debian 使用官方 `linux-image-*` 元包。Rocky Linux 使用 DNF 安装内核，并在可用时通过 `grubby` 设置目标启动项。

## 系统发行版升级

发行版子菜单提供：

```text
1) 升级到下一个受支持的系统发行版
2) 升级到指定的相邻发行版
3) 检查发行版升级目标（不修改系统）
0) 返回首页
```

命令行示例：

```bash
sudo ./upgrade-system.sh release --check
sudo ./upgrade-system.sh release
sudo ./upgrade-system.sh release --release 24.04
```

支持范围：

| 系统 | 行为 |
| --- | --- |
| Ubuntu | 使用官方 `do-release-upgrade`，每次只升级到一个相邻受支持版本 |
| Debian | 支持 Debian 11 → 12、Debian 12 → 13 的相邻升级 |
| Rocky Linux | 只升级当前大版本中的小版本，不执行 8 → 9、9 → 10 |

Rocky Linux 跨大版本建议新装目标系统后迁移业务和数据。

## 系统常用设置

系统设置子菜单提供：

```text
1) 查看当前时间、时区和同步状态
2) 设置系统时区
3) 启用自动时间同步（NTP）
4) 设置系统主机名
0) 返回首页
```

预置时区包括：

- `Asia/Shanghai`
- `Asia/Hong_Kong`
- `UTC`
- `America/Los_Angeles`
- `America/New_York`
- `Europe/London`
- 自定义 `/usr/share/zoneinfo` 中存在的时区

命令行示例：

```bash
./upgrade-system.sh settings --show-time
sudo ./upgrade-system.sh settings --timezone Asia/Shanghai
sudo ./upgrade-system.sh settings --enable-ntp
sudo ./upgrade-system.sh settings --hostname server-01
```

查看时间状态不需要 root。修改时区、时间同步或主机名需要 root，并在执行前要求 `y/n` 确认。修改前会将相关配置保存到：

```text
/var/backups/system-settings-时间戳/
```

## 常用工具选择安装

工具安装子菜单按用途分组：

| 工具组 | 典型工具 |
| --- | --- |
| 基础工具 | `curl`、`wget`、`git`、`vim`、`nano`、`jq`、`zip`、`rsync`、`tree`、`lsof` |
| 网络诊断 | `dig`、`net-tools`、`traceroute`、`tcpdump`、`socat`、`nmap`、`iperf3`、`mtr` |
| 终端会话 | `screen`、`tmux` |
| 系统监控 | `htop`、`iotop`、`iftop`、`sysstat`、`ncdu` |
| 编译开发 | Ubuntu/Debian 的 `build-essential`，Rocky 的 GCC、G++ 和 Make |

脚本会根据发行版转换不同的软件包名称，例如 Ubuntu/Debian 使用 `dnsutils`，Rocky 使用 `bind-utils`。仓库中不存在的软件包会显示警告并跳过。

命令行示例：

```bash
sudo ./upgrade-system.sh tools --tool-group basic
sudo ./upgrade-system.sh tools --tool-group network
sudo ./upgrade-system.sh tools --tool-group all
sudo ./upgrade-system.sh tools --packages "curl jq screen"
```

安装前会显示完整计划清单并要求 `y/n` 确认。使用 `-y` 或 `--yes` 可以跳过脚本自身的确认。

## 系统信息清单

```bash
./upgrade-system.sh info
```

信息清单包括系统版本、主机名、虚拟化环境、内核、CPU、内存、磁盘、网络、软件包状态、已安装内核、发行版升级进程、软件包锁、SSH 状态、失败服务和重启状态。该模式不会刷新仓库或修改系统。

## 安全保护

- 发现正在运行的 Ubuntu 发行版升级进程时，拒绝重复启动升级或安装任务。
- 等待正常的软件包管理器释放锁，不删除锁文件、不杀 APT、DPKG、DNF 或发行版升级进程。
- 修改系统前要求 `y/n` 确认，除非显式使用 `--yes`。
- 内核和发行版升级前保存软件包、软件源与引导配置快照。
- 不自动删除旧内核，不自动重启。
- SSH 操作时提示准备云控制台或其他恢复入口。

Ubuntu 的 `do-release-upgrade` 可能自动创建 `screen` 会话。如果 SSH 中断，可以先查看：

```bash
screen -ls
screen -D -r 会话名称
```

## 日志与备份

日志文件：

```text
/var/log/system-kernel-upgrade-时间戳.log
/var/log/system-release-upgrade-时间戳.log
/var/log/system-settings-upgrade-时间戳.log
/var/log/system-tools-upgrade-时间戳.log
```

内核和发行版升级快照：

```text
/var/backups/system-kernel-upgrade-时间戳/
/var/backups/system-release-upgrade-时间戳/
```
