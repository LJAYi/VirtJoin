
🧱 virtjoin — Virtual Disk Joiner for Proxmox VE

🧩 virtjoin is an interactive automation tool for Proxmox VE / Debian / Ubuntu,
that creates a virtual full disk by joining:
	•	the partition table header,
	•	one physical partition,
	•	and a virtual tail section.

It allows you to pass only one partition (like /dev/sda1) to a VM
while keeping /dev/sda2 for the host,
and the VM still sees the entire disk (/dev/sda).

⸻

✨ Features

✅ Interactive setup (choose disk and partition)
✅ Auto-join header + partition + tail into /dev/mapper/virtjoin
✅ Persistent rebuild via systemd service
✅ Safe isolation between host and VM
✅ Full uninstall support (cleanup + service removal + self-delete)

⸻

🧩 Use Case

Example:

Device	Role	Owner
/dev/sda1	Data partition	Virtual Machine
/dev/sda2	Backup partition	PVE Host

With virtjoin, your VM sees a full disk (like /dev/sda),
but only /dev/sda1 is real — the rest is a fake tail.

The host can still use /dev/sda2 safely.

⸻

🚀 Quick Install

sudo curl -fsSL https://raw.githubusercontent.com/yourname/virtjoin/main/virtjoin.sh -o /usr/local/bin/virtjoin.sh
sudo chmod +x /usr/local/bin/virtjoin.sh
sudo virtjoin.sh

This launches an interactive menu 👇

===============================
  virtjoin Control Center
===============================
1) Show current status
2) Create or rebuild virtual disk
3) Remove mapping
4) Register systemd auto-rebuild
5) Uninstall virtjoin completely
0) Exit
-------------------------------


⸻

⚙️ Example Setup

If your host has /dev/sda with two partitions:

/dev/sda1 → for VM
/dev/sda2 → for PVE

Then select option 2 and input:

Enter target disk (e.g. /dev/sda): /dev/sda
Select partition to passthrough (e.g. sda1): sda1

virtjoin will automatically:
	•	extract GPT header from /dev/sda
	•	attach /dev/sda1
	•	create a fake tail
	•	assemble them into /dev/mapper/virtjoin

Your VM will now see:

Disk /dev/sdb:
 ├─sdb1 → /dev/sda1 (real)
 └─sdb2 → virtual tail (fake)


⸻

🧰 Common Commands

Command	Description
virtjoin.sh --status	Show current virtual disk status
virtjoin.sh --create	Rebuild mapping manually
virtjoin.sh --remove	Remove mapping and loops
virtjoin.sh --uninstall	Full uninstall (cleanup + remove + self-delete)


⸻

🔁 Auto-Rebuild on Boot

virtjoin installs a systemd service:

/etc/systemd/system/virtjoin.service

On every boot:

ExecStart=/usr/local/bin/virtjoin.sh --create

So /dev/mapper/virtjoin is automatically re-created.

⸻

💡 Adding to VM in PVE

Once /dev/mapper/virtjoin is ready, add it to your VM:

qm set 101 -scsi1 /dev/mapper/virtjoin

The VM will see it as a full disk with a partition table.

⸻

🧹 Full Uninstall

In menu, choose:

5) Uninstall virtjoin completely

or run directly:

sudo virtjoin.sh --uninstall

This will:
	•	remove /dev/mapper/virtjoin
	•	detach loop devices
	•	delete /var/lib/virtjoin
	•	remove systemd service
	•	delete /usr/local/bin/virtjoin.sh

⸻

⚠️ Important Notes

Item	Description
⚠️ Dual write warning	Never mount /dev/sda1 on host while VM is running.
GPT changes	VM’s GPT modifications only affect header.img, not host disk.
Performance	Overhead <3% (pure device-mapper passthrough).
Partition change	If you re-partition your host disk, remove and re-run virtjoin.


⸻

🧠 How It Works

virtjoin builds a composite disk like this:

[ header.img | /dev/sda1 | tail.img ]

Then uses device-mapper to expose it as:

/dev/mapper/virtjoin

So the VM sees a “full disk” while only one partition is real.

⸻

🪄 Advanced Usage

virtjoin.sh --create   # manually rebuild
virtjoin.sh --status   # view status
virtjoin.sh --remove   # remove mapping
virtjoin.sh --uninstall # clean up everything


⸻

🧱 License

MIT License © 2025 [LJAYi]

⸻

🌟 Contributing

Pull requests and ideas are welcome!
Future improvements may include:
	•	multi-disk support
	•	read-only mode for safer testing
	•	NVMe/ZFS integration

