VirtJoin（虚拟整盘拼接）

版本：v3.0.4（多映射 + 手动输入）

把宿主机上的某个分区作为“整盘”的中间段，前后用伪造的 Header/Tail 填充，拼接成一块看起来像整盘的块设备（/dev/mapper/virtjoin-xxx），再把它直通给虚拟机。这样虚机能看到原磁盘的分区表 + sda1 分区内容，而宿主机仍可保留其他分区给自身使用。
适用于 Proxmox VE（PVE）等 KVM/QEMU 环境。

⸻

✨ 特性一览
	•	多映射：每个分区独立目录、独立 dm 名、独立 systemd 实例（virtjoin@<分区>.service）。
	•	安全校验：校验“分区属于磁盘”、检查 GPT 备份分区表空间（尾部 ≥ 33 扇区）。
	•	稳健运行：失败自动清理 loop（trap），避免遗留 /dev/loop*。
	•	性能友好：header.img 仅首次创建，开机自动恢复不反复重建。
	•	一行安装：自动将脚本安装到 /usr/local/bin/virtjoin.sh 并自重启。
	•	PVE 友好：结果设备可直接用 qm set 挂载到 VM（virtio/scsi 等）。

⸻

🛠 适用场景
	•	你只想把物理磁盘的一块分区直通给 VM，但希望 VM 看到完整磁盘结构（含分区表 + 该分区）。
	•	宿主机继续使用同一磁盘上的其他分区（例如备份、宿主系统、数据盘等）。

⸻

⚙️ 安装

bash <(curl -fsSL https://raw.githubusercontent.com/LJAYi/VirtJoin/main/virtjoin.sh)

安装完成后会在：

/usr/local/bin/virtjoin.sh


⸻

🚀 快速使用
	1.	运行控制台

virtjoin.sh

进入菜单：

1) 查看当前状态
2) 创建/重建 virtjoin（手动输入磁盘/分区）
3) 注册/取消 systemd 自动恢复
4) 手动移除某个映射（同时取消自动恢复）
5) 卸载 virtjoin（清理所有映射/服务/脚本）
0) 退出

	2.	创建/重建（手动输入）

	•	先展示 TYPE=disk 的整盘列表（仅供参考）。
	•	手动输入目标磁盘与分区，例如：

请输入目标磁盘: /dev/sda
请选择要直通的分区: sda1   # 或 /dev/sda1


	•	成功后会生成 /dev/mapper/virtjoin-sda1。

	3.	连接到 VM（以 VMID=101 为例）

# 推荐 virtio
qm set 101 -virtio0 /dev/mapper/virtjoin-sda1

# 或 SCSI
# qm set 101 -scsi0 /dev/mapper/virtjoin-sda1

	4.	开机自动恢复（可选）

# 菜单 3 → 选择某个映射（如 sda1）→ 启用/取消
# 会生成/启用：virtjoin@sda1.service

	5.	移除映射 / 卸载

	•	菜单 4：移除单个映射（可选同时取消自动恢复）
	•	菜单 5：完全卸载（清理所有映射、服务与脚本）

⸻

📂 目录结构

/var/lib/virtjoin/
 ├─ sda1/                 # 每个分区一个目录
 │   ├─ config            # DISK=/dev/sda, PART=/dev/sda1, PB=sda1
 │   ├─ header.img        # 真实磁盘头部镜像（仅首次创建）
 │   ├─ tail.img          # 尾部占位镜像（动态调整）
 │   └─ table.txt         # dmsetup 表（设备映射规则）
 └─ nvme0n1p1/
     └─ ...


⸻

🔒 安全与一致性
	•	分区归属检查：确保 PART 确实属于 DISK，避免把 /dev/sdb1 错指向 /dev/sda。
	•	GPT 备份表空间：尾部空间至少 33 扇区，避免覆盖备份 GPT（若不足则拒绝创建）。
	•	只读/只首创 header：减少无谓 I/O，避免开机时重复 dd 读盘。
	•	异常清理：构建过程中失败会自动 losetup -d，避免资源泄漏。

⸻

🧪 示例

# 交互创建 -> virtjoin-sda1
virtjoin.sh

# 查看状态
virtjoin.sh --status

# 非交互重建（单配置）
virtjoin.sh --create-from-config /var/lib/virtjoin/sda1/config

# 启用/取消自动恢复
virtjoin.sh --toggle-autorecover

# 移除映射（菜单 4 或 CLI）
virtjoin.sh --remove

# 完全卸载
virtjoin.sh --uninstall


⸻

⚠️ 已知问题（当前版本行为说明）

由于今天未继续排查并修复，以下行为在部分环境中可能出现。请留意。

	1.	磁盘列表不能自动选择（“没法2没法自动”）
	•	菜单第 2 项（创建/重建） 中的“整盘列表”为只读展示，不提供数字选择；需要你手动输入 /dev/sdX / /dev/nvmeXnY / /dev/vdX 等设备名。
	•	这么做的原因是不同发行版 lsblk 输出差异较大，自动编号选择在少数系统上会不稳定。当前版本以手动输入为准，确保在所有设备命名方案下都可用。
	2.	菜单第 3、4 项（注册/取消自动恢复、手动移除映射）可能出现“空白、编号没用”的情况
	•	触发条件通常是：尚未成功创建任何映射（即 /var/lib/virtjoin/<PB>/config 不存在）。
	•	表现为进入 3 或 4 后没有列表，或提示编号但没有条目。
	•	当前逻辑：当没有任何配置时，这两项会提示“暂无配置”并返回菜单；如果你看到“编号: ”却没有条目，请先通过菜单 2 完成至少一次映射创建。
	•	后续版本会持续增强兼容性与可见性（例如在空列表时显式显示提示并立即返回，不再出现“编号空白”体验）。
	3.	自动恢复仅针对已存在的配置生效
	•	必须先通过“创建/重建（手动输入）”生成 config，virtjoin@<PB>.service 才能正常启用并在开机重建。

若你遇到与上述不同的异常（例如系统已有配置但 3/4 仍空白），建议先执行：

find /var/lib/virtjoin -mindepth 2 -maxdepth 2 -type f -name config -print -exec sed -n '1,2p' {} \;

贴出结果以便定位。

⸻

🧰 故障排查速查表
	•	检查是否已创建配置：

find /var/lib/virtjoin -name config -print


	•	检查映射是否存在：

dmsetup info | grep virtjoin
ls -l /dev/mapper/ | grep virtjoin


	•	检查 loop 残留（可安全移除）：

losetup -a



⸻

🧹 卸载

virtjoin.sh --uninstall
# 或在菜单选择 5

将清理：所有映射、所有 systemd 实例、全部配置目录与脚本自身。

⸻

📄 许可证

MIT（除非仓库另有声明）。

⸻

💬 反馈

欢迎在 GitHub Issue 中提交：
	•	你的发行版、内核版本
	•	lsblk -dpno NAME,TYPE,SIZE,MODEL 输出
	•	出现问题时的终端截图/日志

我们会在后续版本继续改进菜单可见性与自动枚举体验。
