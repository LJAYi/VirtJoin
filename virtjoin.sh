#!/bin/bash
# ============================================================
#  virtjoin — Virtual Disk Joiner for PVE/Proxmox (Interactive Edition)
#  LJAYi
# ============================================================

set -euo pipefail
LOG_TAG="[virtjoin]"
INSTALL_DIR="/var/lib/virtjoin"
HEADER_IMG="$INSTALL_DIR/header.img"
TAIL_IMG="$INSTALL_DIR/tail.img"
DM_TABLE="$INSTALL_DIR/table.txt"
DM_NAME="virtjoin"
SYSTEMD_UNIT="/etc/systemd/system/virtjoin.service"
SELF_PATH="/usr/local/bin/virtjoin.sh"

# ========== 基础工具函数 ==========
log() { echo "${LOG_TAG} $*"; }
die() { echo "${LOG_TAG} ❌ ERROR: $*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }
for c in blockdev losetup dmsetup dd truncate awk grep sed stat systemctl lsblk; do
  need_cmd "$c"
done

mkdir -p "$INSTALL_DIR"

# ========== 获取 loop 设备 ==========
loop_of() { losetup -j "$1" | awk -F: '{print $1}'; }

# ========== 功能区 ==========
show_status() {
  echo "====== virtjoin 状态 ======"
  if dmsetup info "$DM_NAME" >/dev/null 2>&1; then
    echo "设备: /dev/mapper/$DM_NAME"
    dmsetup status "$DM_NAME" || true
  else
    echo "未检测到 /dev/mapper/$DM_NAME"
  fi
  echo
  lsblk | grep -E "NAME|${DM_NAME}" || true
  echo "==========================="
}

remove_mapping() {
  echo "🧹 正在移除 virtjoin ..."
  dmsetup remove "$DM_NAME" 2>/dev/null || true
  for f in "$HEADER_IMG" "$TAIL_IMG"; do
    lp=$(loop_of "$f" || true)
    [ -n "$lp" ] && losetup -d "$lp" 2>/dev/null && log "已卸载 loop: $lp"
  done
}

create_mapping() {
  echo "✨ 创建 virtjoin 映射 ..."
  local DISK PART START PART_SECTORS DISK_SECTORS TAIL_SECTORS
  read -rp "请输入目标磁盘 (例如 /dev/sda): " DISK
  [ -b "$DISK" ] || die "$DISK 不是块设备。"
  lsblk -no NAME,SIZE,FSTYPE,MOUNTPOINT "$DISK"
  read -rp "请选择要直通的分区 (例如 sda1): " PART
  PART="/dev/$PART"
  [ -b "$PART" ] || die "$PART 不存在。"

  START=$(cat /sys/block/$(basename "$DISK")/$(basename "$PART")/start)
  PART_SECTORS=$(blockdev --getsz "$PART")
  DISK_SECTORS=$(blockdev --getsz "$DISK")
  TAIL_SECTORS=$((DISK_SECTORS - START - PART_SECTORS))

  echo "[INFO] Start: $START"
  echo "[INFO] Part sectors: $PART_SECTORS"
  echo "[INFO] Tail sectors: $TAIL_SECTORS"
  echo

  mkdir -p "$INSTALL_DIR"

  if [ ! -f "$HEADER_IMG" ]; then
    dd if="$DISK" of="$HEADER_IMG" bs=512 count="$START" status=none
    log "已创建 header.img"
  else
    log "保留现有 header.img"
  fi
  truncate -s $((TAIL_SECTORS * 512)) "$TAIL_IMG"

  local LOOP_HEADER LOOP_TAIL
  LOOP_HEADER=$(losetup -fP --show "$HEADER_IMG")
  LOOP_TAIL=$(losetup -fP --show "$TAIL_IMG")

  cat >"$DM_TABLE" <<EOF
0 ${START} linear ${LOOP_HEADER} 0
${START} ${PART_SECTORS} linear ${PART} 0
$((START + PART_SECTORS)) ${TAIL_SECTORS} linear ${LOOP_TAIL} 0
EOF

  dmsetup create "$DM_NAME" "$DM_TABLE"
  echo "✅ 已创建 /dev/mapper/$DM_NAME"
}

setup_service() {
  cat >"$SYSTEMD_UNIT" <<EOF
[Unit]
Description=virtjoin auto-rebuild
After=local-fs.target

[Service]
Type=oneshot
ExecStart=$SELF_PATH --create
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable virtjoin.service
  log "✅ 已注册开机自动恢复服务"
}

# ========== 卸载整个程序 ==========
full_uninstall() {
  echo "⚠️  确定要完全卸载 virtjoin 吗？(包括映射、loop、systemd、脚本)"
  read -rp "输入 y 确认: " yn
  [[ "$yn" =~ ^[Yy]$ ]] || { echo "已取消"; return; }

  systemctl disable virtjoin.service 2>/dev/null || true
  rm -f "$SYSTEMD_UNIT"
  remove_mapping
  rm -rf "$INSTALL_DIR"
  rm -f "$SELF_PATH"
  systemctl daemon-reload
  echo "🗑️  已完全卸载 virtjoin。"
}

# ========== 命令行支持 ==========
if [[ "${1:-}" =~ ^-- ]]; then
  case "$1" in
    --status) show_status ;;
    --remove) remove_mapping ;;
    --create) create_mapping ;;
    --uninstall) full_uninstall ;;
    *) echo "用法: virtjoin.sh [--status|--create|--remove|--uninstall]";;
  esac
  exit 0
fi

# ========== 交互界面 ==========
while true; do
  clear
  echo "==============================="
  echo "  virtjoin 控制中心"
  echo "==============================="
  echo "1) 查看当前状态"
  echo "2) 创建或重新拼接虚拟整盘"
  echo "3) 手动移除映射"
  echo "4) 注册 systemd 自动恢复"
  echo "5) 完全卸载 virtjoin"
  echo "0) 退出"
  echo "-------------------------------"
  read -rp "请选择操作 [0-5]: " opt
  echo

  case "$opt" in
    1) show_status ;;
    2) remove_mapping; create_mapping ;;
    3) remove_mapping ;;
    4) setup_service ;;
    5) full_uninstall; exit 0 ;;
    0) echo "再见 👋"; exit 0 ;;
    *) echo "无效选项";;
  esac
  echo; read -rp "按 Enter 返回菜单..." _
done
