
🧱 virtjoin — Virtual Disk Joiner for Proxmox VE

🧩 virtjoin 是一个交互式自动化工具，用于在 PVE / Proxmox 环境中，把物理磁盘的 分区表 + 分区 + 尾部空间 拼接成一块“虚拟整盘”，从而：
	•	虚拟机能看到完整磁盘（含分区表）；
	•	宿主仍能使用其它分区（比如 sda2）；
	•	支持一键安装、开机自恢复、完全卸载。

⸻

✨ 功能特点

✅ 一键安装
✅ 交互式选择磁盘与分区
✅ 自动拼接 header/tail + 分区 → 虚拟整盘 /dev/mapper/virtjoin
✅ 开机自动重建映射（systemd 服务）
✅ 安全：宿主与虚拟机分区隔离
✅ 一键卸载：清除映射 + loop + 服务 + 自身

⸻

🧩 适用场景
	•	你想让 虚拟机看到完整磁盘（含 GPT 表），但又不想把整盘直通；
	•	例如：
	•	/dev/sda 有分区：
	•	sda1 给 VM；
	•	sda2 给 PVE；
	•	你希望 VM 看到完整 /dev/sda，同时宿主还在用 sda2。

⸻

🚀 一键安装与使用

bash <(curl -fsSL https://raw.githubusercontent.com/LJAYi/VirtJoin/main/virtjoin.sh)

启动后会进入交互式菜单 👇：

===============================
  virtjoin 控制中心
===============================
1) 查看当前状态
2) 创建或重新拼接虚拟整盘
3) 手动移除映射
4) 注册 systemd 自动恢复
5) 完全卸载 virtjoin
0) 退出
-------------------------------


⸻

⚙️ 安装示例流程

示例：宿主 /dev/sda 有两个分区：
sda1 给虚拟机，sda2 给 PVE。

在菜单中选择：

2) 创建或重新拼接虚拟整盘

然后交互输入：

请输入目标磁盘 (例如 /dev/sda): /dev/sda
请选择要直通的分区 (例如 sda1): sda1

virtjoin 将自动：
	•	提取 /dev/sda 的分区表头；
	•	拼接 /dev/sda1；
	•	添加尾部占位；
	•	创建 /dev/mapper/virtjoin。

虚拟机看到的磁盘将包含原分区表结构：

/dev/sdb
 ├─sdb1  (直通的 sda1)
 └─sdb2  (尾部虚拟区)


⸻

🧰 常用命令

命令	功能
virtjoin.sh --status	查看当前虚拟整盘状态
virtjoin.sh --create	手动重建映射
virtjoin.sh --remove	移除映射与 loop
virtjoin.sh --uninstall	完全卸载（移除映射 + loop + systemd + 自身）


⸻

🔁 开机自动恢复

virtjoin 自动注册 systemd 服务：

/etc/systemd/system/virtjoin.service

系统每次启动时会自动执行：

ExecStart=/usr/local/bin/virtjoin.sh --create

从而重建 /dev/mapper/virtjoin。

⸻

💡 配置后在 PVE 里添加磁盘

配置完成后，执行：

qm set 101 -scsi1 /dev/mapper/virtjoin

启动虚拟机后：
	•	你会看到完整的磁盘（含分区表）；
	•	但实际数据只映射到 /dev/sda1；
	•	/dev/sda2 仍由宿主机自由使用。

⸻

🧹 完全卸载

在菜单中选择：

5) 完全卸载 virtjoin

或者命令行执行：

sudo virtjoin.sh --uninstall

它将自动：
	•	停止并删除 /dev/mapper/virtjoin
	•	卸载 loop
	•	删除 /var/lib/virtjoin
	•	移除 systemd 服务
	•	删除 /usr/local/bin/virtjoin.sh

⸻

⚠️ 注意事项

说明	细节
宿主与 VM 双写风险	⚠️ 宿主不能同时挂载 /dev/sda1 与虚拟机访问同一分区。
GPT 修改	VM 修改分区表只影响 header 镜像，不改动宿主实际 GPT。
性能	通过 dmsetup 映射，性能损耗可忽略（<3%）。
分区调整	如果宿主修改物理分区布局，请先卸载再重新运行 virtjoin。


⸻

🧠 工作原理概述

virtjoin 将磁盘拼接为：

| GPT头 (header.img) | sda1 实区 | GPT尾 (tail.img) |

并通过 device-mapper 创建虚拟设备：

/dev/mapper/virtjoin

虚拟机看到的磁盘 = 完整 /dev/sda
宿主看到的分区依旧独立。

⸻

🪄 高级用户

你也可以直接执行命令行：

virtjoin.sh --create   # 手动重建映射
virtjoin.sh --status   # 查看状态
virtjoin.sh --remove   # 移除映射
virtjoin.sh --uninstall # 完全清理


⸻

🧱 许可证

MIT License © 2025 [LJAYi]


可以直接附在仓库中。
