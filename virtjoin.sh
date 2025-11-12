#!/bin/bash
# ============================================================
#  virtjoin v2.5 — Virtual Disk Joiner for Proxmox VE
#  Author: LJAYi
# ============================================================

set -euo pipefail
[ "${EUID:-$(id -u)}" -eq 0 ] || { echo "[virtjoin] ERROR: 请用 root 运行"; exit 1; }
umask 0077

LOG_TAG="[virtjoin]"
INSTALL_DIR="/var/lib/virtjoin"
CONFIG_FILE="$INSTALL_DIR/config"
HEADER_IMG="$INSTALL_DIR/header.img"
TAIL_IMG="$INSTALL_DIR/tail.img"
DM_TABLE="$INSTALL_DIR/table.txt"
DM_NAME="virtjoin"
SYSTEMD_UNIT="/etc/systemd/system/virtjoin.service"
SELF_PATH="/usr/local/bin/virtjoin.sh"

green="\e[32m"; yellow="\e[33m"; red="\e[31m"; dim="\e[2m"; reset="\e[0m"
log()  { echo -e "${green}${LOG_TAG}${reset} $*"; }
warn() { echo -e "${yellow}${LOG_TAG}${reset} ⚠️ $*"; }
die()  { echo -e "${red}${LOG_TAG} ERROR:${reset} $*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }
for c in blockdev losetup dmsetup dd truncate awk grep sed stat systemctl lsblk curl; do need_cmd "$c"; done
mkdir -p "$INSTALL_DIR"

# ---- 自安装检测（完美兼容版） ----
self_install_check() {
  local cur
  # 检测脚本是否来自管道或虚拟fd
  if [ ! -f "$0" ] || [[ "$0" =~ ^/proc/ ]] || [[ "$0" =~ ^/dev/fd/ ]] || [[ "$0" == "bash" ]] || [[ "$0" == -* ]]; then
    echo "[virtjoin] 检测到脚本来自管道输入，自动安装到 $SELF_PATH ..."
    mkdir -p "$(dirname "$SELF_PATH")"
    curl -fsSL "https://raw.githubusercontent.com/LJAYi/VirtJoin/main/virtjoin.sh" -o "$SELF_PATH"
    chmod +x "$SELF_PATH"
    echo "[virtjoin] 已安装到 $SELF_PATH"
    exec "$SELF_PATH" "$@"
  fi

  # 正常文件执行，自安装
  if command -v realpath >/dev/null 2>&1; then cur="$(realpath "$0")"; else cur="$(readlink -f "$0")"; fi
  if [ "$cur" != "$SELF_PATH" ]; then
    echo "[virtjoin] 安装脚本到 $SELF_PATH ..."
    mkdir -p "$(dirname "$SELF_PATH")"
    cp "$cur" "$SELF_PATH"
    chmod +x "$SELF_PATH"
    echo "[virtjoin] 已安装到 $SELF_PATH"
    exec "$SELF_PATH" "$@"
  fi
}
self_install_check "$@"

# ---- 工具函数 ----
loop_of() { losetup -j "$1" | awk -F: '{print $1}'; }

show_status() {
  echo -e "\n====== virtjoin 状态 ======"
  if dmsetup info "$DM_NAME" >/dev/null 2>&1; then
    echo "设备: /dev/mapper/$DM_NAME"
    dmsetup status "$DM_NAME" || true
  else
    echo "未检测到 /dev/mapper/$DM_NAME"
  fi
  echo
  lsblk | grep -E "NAME|${DM_NAME}" || true
  [ -f "$CONFIG_FILE" ] && { echo; echo "配置文件: $CONFIG_FILE"; cat "$CONFIG_FILE"; }
  echo -e "===========================\n"
}

remove_mapping() {
  echo -e "${yellow}🧹 正在移除 virtjoin ...${reset}"
  dmsetup remove "$DM_NAME" 2>/dev/null || true
  for f in "$HEADER_IMG" "$TAIL_IMG"; do
    lp="$(loop_of "$f" || true)"
    if [ -n "$lp" ]; then
      while read -r one; do [ -n "$one" ] && losetup -d "$one" 2>/dev/null || true; done <<< "$lp"
      log "已卸载 loop: $lp"
    fi
  done
  sleep 0.2
}

# ---- 核心构建 ----
_do_build() {
  [ -n "${DISK:-}" ] && [ -n "${PART:-}" ] || die "DISK/PART 为空"
  [ -b "$DISK" ] || die "磁盘不存在: $DISK"
  [ -b "$PART" ] || die "分区不存在: $PART"

  # 校验配对
  pbase="$(basename "$PART")"; dbase="$(basename "$DISK")"
  disk_of_part="$(basename "$(realpath "/sys/class/block/$pbase/..")")"
  [ "$disk_of_part" = "$dbase" ] || die "选择错误：$PART 不属于 $DISK"

  SS=$(blockdev --getss "$DISK")
  START=$(cat /sys/block/$(basename "$DISK")/$(basename "$PART")/start)
  PART_SECTORS=$(blockdev --getsz "$PART")
  DISK_SECTORS=$(blockdev --getsz "$DISK")
  TAIL_SECTORS=$((DISK_SECTORS - START - PART_SECTORS))
  [ "$TAIL_SECTORS" -ge 33 ] || die "尾部空间不足（$TAIL_SECTORS 扇区）"

  echo "[INFO] Start: $START"
  echo "[INFO] Partition sectors: $PART_SECTORS"
  echo "[INFO] Tail sectors: $TAIL_SECTORS"

  if [ ! -f "$HEADER_IMG" ]; then
    dd if="$DISK" of="$HEADER_IMG" bs="$SS" count="$START" status=none
    log "已创建 header.img"
  else
    log "保留现有 header.img"
  fi
  truncate -s $((TAIL_SECTORS * SS)) "$TAIL_IMG"
  log "tail.img 已创建或更新"

  local LOOP_HEADER LOOP_TAIL
  LOOP_HEADER=$(losetup -fP --show "$HEADER_IMG")
  LOOP_TAIL=$(losetup -fP --show "$TAIL_IMG")
  cleanup_loops() { losetup -d "$LOOP_HEADER" 2>/dev/null || true; losetup -d "$LOOP_TAIL" 2>/dev/null || true; }
  trap cleanup_loops ERR INT

  cat >"$DM_TABLE" <<EOF
0 ${START} linear ${LOOP_HEADER} 0
${START} ${PART_SECTORS} linear ${PART} 0
$((START + PART_SECTORS)) ${TAIL_SECTORS} linear ${LOOP_TAIL} 0
EOF

  dmsetup create "$DM_NAME" "$DM_TABLE"
  trap - ERR INT
  echo -e "${green}✅ 已创建 /dev/mapper/$DM_NAME${reset}"
}

# ---- 交互配置 ----
create_mapping_interactive() {
  echo -e "${green}✨ 创建/重建 virtjoin（交互配置）...${reset}"
  lsblk -dpno NAME,SIZE,MODEL | grep -E "/dev/sd|/dev/nvme" || true
  read -rp "请输入目标磁盘 (例如 /dev/sda): " DISK
  [ -b "$DISK" ] || die "$DISK 不是块设备。"
  lsblk -no NAME,SIZE,FSTYPE,MOUNTPOINT "$DISK"
  read -rp "请选择要直通的分区 (例如 sda1 或 /dev/sda1): " PART
  [[ "$PART" != /dev/* ]] && PART="/dev/$PART"
  [ -b "$PART" ] || die "$PART 不存在。"

  pbase="$(basename "$PART")"; dbase="$(basename "$DISK")"
  disk_of_part="$(basename "$(realpath "/sys/class/block/$pbase/..")")"
  [ "$disk_of_part" = "$dbase" ] || die "选择错误：$PART 不属于 $DISK"

  echo "DISK=\"$DISK\"" > "$CONFIG_FILE"
  echo "PART=\"$PART\"" >> "$CONFIG_FILE"
  log "配置已保存到 $CONFIG_FILE"
  rm -f "$HEADER_IMG" && log "已清除旧 header.img，将按新配置重建"

  remove_mapping
  _do_build
}

create_mapping_from_config() {
  log "从配置加载并创建映射（非交互）..."
  [ -f "$CONFIG_FILE" ] || die "未找到 $CONFIG_FILE，请先交互配置。"
  source "$CONFIG_FILE"
  remove_mapping
  _do_build
}

setup_service() {
  cat >"$SYSTEMD_UNIT" <<EOF
[Unit]
Description=virtjoin auto-rebuild (non-interactive)
After=local-fs.target systemd-udev-settle.service
Wants=systemd-udev-settle.service
ConditionPathExists=$CONFIG_FILE

[Service]
Type=oneshot
ExecStart=$SELF_PATH --create-from-config
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable virtjoin.service
  log "✅ 已注册 systemd 自动恢复"
}

full_uninstall() {
  echo -e "${yellow}⚠️ 确定要完全卸载 virtjoin 吗？(映射/loop/systemd/脚本){y/N}${reset}"
  read -r yn
  [[ "$yn" =~ ^[Yy]$ ]] || { echo "已取消"; return; }
  systemctl disable virtjoin.service 2>/dev/null || true
  rm -f "$SYSTEMD_UNIT"
  remove_mapping
  rm -rf "$INSTALL_DIR"
  rm -f "$SELF_PATH"
  systemctl daemon-reload
  echo -e "${green}🗑️ 已完全卸载 virtjoin${reset}"
  exit 0
}

# ---- CLI ----
if [[ "${1:-}" =~ ^-- ]]; then
  case "$1" in
    --status) show_status ;;
    --remove) remove_mapping ;;
    --create) create_mapping_interactive ;;
    --create-from-config) create_mapping_from_config ;;
    --install-service) setup_service ;;
    --uninstall) full_uninstall ;;
    *) echo "用法: virtjoin.sh [--status|--create|--create-from-config|--remove|--install-service|--uninstall]" ;;
  esac
  exit 0
fi

# ---- 菜单 ----
while true; do
  clear
  echo -e "${green}===============================${reset}"
  echo -e "${green} virtjoin 控制中心${reset}"
  echo -e "${green}===============================${reset}"
  if dmsetup info "$DM_NAME" >/dev/null 2>&1; then
    size="$(blockdev --getsize64 /dev/mapper/$DM_NAME 2>/dev/null || echo 0)"
    echo "当前：/dev/mapper/$DM_NAME 存在 (大小 ${size} bytes)"
  else
    echo "当前：/dev/mapper/$DM_NAME 不存在"
  fi
  [ -f "$CONFIG_FILE" ] && echo "配置文件：$CONFIG_FILE" || echo "配置文件：<未生成>"
  echo
  echo "1) 查看当前状态"
  echo "2) 创建或重新拼接虚拟整盘 (交互配置)"
  echo "3) 从配置非交互重建 (验证 systemd)"
  echo "4) 注册 systemd 自动恢复"
  echo "5) 手动移除映射"
  echo "6) 完全卸载 virtjoin"
  echo "0) 退出"
  read -rp "请选择操作 [0-6]: " opt; echo
  case "$opt" in
    1) show_status ;;
    2) create_mapping_interactive ;;
    3) create_mapping_from_config ;;
    4) setup_service ;;
    5) remove_mapping ;;
    6) full_uninstall ;;
    0) echo "再见 👋"; exit 0 ;;
    *) warn "无效选项，请重试" ;;
  esac
  echo; read -rp "按 Enter 返回菜单..." _
done
