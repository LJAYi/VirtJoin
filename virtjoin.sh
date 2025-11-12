#!/bin/bash
# ============================================================
#  virtjoin v2.6.1 — Multi-Mapping Manager for Proxmox VE
#  Author: LJAYi
# ============================================================

set -euo pipefail
[ "${EUID:-$(id -u)}" -eq 0 ] || { echo "[virtjoin] ERROR: 请用 root 运行"; exit 1; }
umask 0077

LOG_TAG="[virtjoin]"
BASE_DIR="/var/lib/virtjoin"
SYSTEMD_TMPL="/etc/systemd/system/virtjoin@.service"
SELF_PATH="/usr/local/bin/virtjoin.sh"
REPO_URL="https://raw.githubusercontent.com/LJAYi/VirtJoin/main/virtjoin.sh"

green="\e[32m"; yellow="\e[33m"; red="\e[31m"; reset="\e[0m"
log(){ echo -e "${green}${LOG_TAG}${reset} $*"; }
warn(){ echo -e "${yellow}${LOG_TAG}${reset} ⚠️ $*"; }
die(){ echo -e "${red}${LOG_TAG} ERROR:${reset} $*" >&2; exit 1; }

need_cmd(){ command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }
for c in blockdev losetup dmsetup dd truncate awk grep sed stat systemctl lsblk curl readlink; do need_cmd "$c"; done
mkdir -p "$BASE_DIR"

# ---- 自安装检测 ----
self_install_check() {
  local cur
  if [ ! -f "$0" ] || [[ "$0" =~ ^/proc/ ]] || [[ "$0" =~ ^/dev/fd/ ]] || [[ "$0" == "bash" ]] || [[ "$0" == -* ]]; then
    echo "[virtjoin] 检测到脚本来自管道输入，自动安装到 $SELF_PATH ..."
    mkdir -p "$(dirname "$SELF_PATH")"
    curl -fsSL "$REPO_URL" -o "$SELF_PATH"
    chmod +x "$SELF_PATH"
    echo "[virtjoin] 已安装到 $SELF_PATH"
    exec "$SELF_PATH" "$@"
  fi
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

loop_of(){ losetup -j "$1" | awk -F: '{print $1}'; }

pb_from_part(){ basename "$1"; }
dir_of_pb(){ echo "$BASE_DIR/$1"; }
dmname_of_pb(){ echo "virtjoin-$1"; }
cfg_of_dir(){ echo "$1/config"; }
header_of_dir(){ echo "$1/header.img"; }
tail_of_dir(){ echo "$1/tail.img"; }
table_of_dir(){ echo "$1/table.txt"; }

ensure_tmpl_unit(){
cat >"$SYSTEMD_TMPL" <<'EOF'
[Unit]
Description=virtjoin auto-rebuild for %i
After=local-fs.target systemd-udev-settle.service
Wants=systemd-udev-settle.service
ConditionPathExists=/var/lib/virtjoin/%i/config
[Service]
Type=oneshot
ExecStart=/usr/local/bin/virtjoin.sh --create-from-config /var/lib/virtjoin/%i/config
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
}

list_pbs(){ find "$BASE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while read -r d; do [ -f "$(cfg_of_dir "$d")" ] && basename "$d"; done; }

show_status(){
  echo -e "\n====== virtjoin 状态 ======"
  local any=0
  while read -r pb; do
    [ -z "$pb" ] && continue
    any=1
    local dm="/dev/mapper/$(dmname_of_pb "$pb")"
    if dmsetup info "$(dmname_of_pb "$pb")" &>/dev/null; then
      echo "• $(dmname_of_pb "$pb") 存在  ($dm)"
    else
      echo "• $(dmname_of_pb "$pb") 不存在"
    fi
  done < <(list_pbs)
  [ "$any" -eq 0 ] && echo "暂无任何 virtjoin 映射。"
  echo -e "===========================\n"
}

remove_pb(){
  local pb="$1" d="$(dir_of_pb "$pb")" dm="$(dmname_of_pb "$pb")"
  local hdr="$(header_of_dir "$d")" tl="$(tail_of_dir "$d")"
  echo -e "${yellow}🧹 正在移除 $dm ...${reset}"
  dmsetup remove "$dm" 2>/dev/null || true
  for f in "$hdr" "$tl"; do
    lp="$(loop_of "$f" || true)"
    [ -n "$lp" ] && for one in $lp; do losetup -d "$one" 2>/dev/null || true; done
  done
}

_do_build_from_cfg(){
  local cfg="$1"; [ -f "$cfg" ] || die "缺少配置 $cfg"
  # shellcheck disable=SC1090
  source "$cfg"
  local d="$(dir_of_pb "$PB")" dm="$(dmname_of_pb "$PB")"
  local hdr="$(header_of_dir "$d")" tl="$(tail_of_dir "$d")" tbl="$(table_of_dir "$d")"
  [ -b "$DISK" ] && [ -b "$PART" ] || die "设备不存在"
  local SS=$(blockdev --getss "$DISK")
  local pbase=$(basename "$PART") dbase=$(basename "$DISK")
  local START=$(cat /sys/block/"$dbase"/"$pbase"/start)
  local PART_SECTORS=$(blockdev --getsz "$PART")
  local DISK_SECTORS=$(blockdev --getsz "$DISK")
  local TAIL_SECTORS=$((DISK_SECTORS - START - PART_SECTORS))
  mkdir -p "$d"
  dd if="$DISK" of="$hdr" bs="$SS" count="$START" status=none
  truncate -s $((TAIL_SECTORS * SS)) "$tl"
  local LOOP_HEADER=$(losetup -fP --show "$hdr") LOOP_TAIL=$(losetup -fP --show "$tl")
  cat >"$tbl" <<EOF
0 ${START} linear ${LOOP_HEADER} 0
${START} ${PART_SECTORS} linear ${PART} 0
$((START + PART_SECTORS)) ${TAIL_SECTORS} linear ${LOOP_TAIL} 0
EOF
  dmsetup create "$dm" "$tbl"
  echo -e "${green}✅ 已创建 $dm${reset}"
}

pick_disk(){
  mapfile -t DISKS < <(lsblk -dpno NAME,SIZE,MODEL | grep -E "/dev/")
  [ "${#DISKS[@]}" -gt 0 ] || die "未发现可用磁盘"
  echo "请选择目标磁盘："
  local i=1; for row in "${DISKS[@]}"; do echo "[$i] $row"; i=$((i+1)); done; echo "[0] 取消"
  read -rp "编号: " idx; [[ "$idx" =~ ^[0-9]+$ ]] || die "输入无效"
  [ "$idx" -eq 0 ] && return 1
  echo "${DISKS[$((idx-1))]}" | awk '{print $1}'
}

pick_part(){
  local disk="$1"
  mapfile -t PARTS < <(lsblk -no NAME,SIZE,FSTYPE -p "$disk" | tail -n +2)
  [ "${#PARTS[@]}" -gt 0 ] || die "该磁盘无分区"
  echo "请选择要直通的分区："
  local i=1; for row in "${PARTS[@]}"; do echo "[$i] $row"; i=$((i+1)); done; echo "[0] 取消"
  read -rp "编号: " idx; [[ "$idx" =~ ^[0-9]+$ ]] || die "输入无效"
  [ "$idx" -eq 0 ] && return 1
  echo "${PARTS[$((idx-1))]}" | awk '{print $1}'
}

create_interactive(){
  echo -e "${green}✨ 创建/重建 virtjoin（交互配置）...${reset}"
  local DISK PART PB D CFG
  DISK="$(pick_disk)" || { echo "已取消"; return; }
  PART="$(pick_part "$DISK")" || { echo "已取消"; return; }
  PB="$(pb_from_part "$PART")"; D="$(dir_of_pb "$PB")"; CFG="$(cfg_of_dir "$D")"
  mkdir -p "$D"
  cat >"$CFG" <<EOF
DISK="$DISK"
PART="$PART"
PB="$PB"
EOF
  remove_pb "$PB" || true
  _do_build_from_cfg "$CFG"
  read -rp "是否注册 systemd 自动恢复 [$PB]？(y/N): " yn
  [[ "$yn" =~ ^[Yy]$ ]] && ensure_tmpl_unit && systemctl enable "virtjoin@${PB}.service" && log "已启用 virtjoin@${PB}.service"
}

pick_pb(){
  mapfile -t PBS < <(list_pbs)
  [ "${#PBS[@]}" -gt 0 ] || { echo "暂无配置"; return 1; }
  echo "请选择目标映射："
  local i=1; for pb in "${PBS[@]}"; do echo "[$i] $pb"; i=$((i+1)); done; echo "[0] 取消"
  read -rp "编号: " idx; [[ "$idx" =~ ^[0-9]+$ ]] || { echo "输入无效"; return 1; }
  [ "$idx" -eq 0 ] && return 1
  echo "${PBS[$((idx-1))]}"
}

toggle_autorecover(){
  local pb; pb="$(pick_pb)" || return
  ensure_tmpl_unit
  local unit="virtjoin@${pb}.service"
  if systemctl is-enabled "$unit" &>/dev/null; then
    read -rp "$unit 已启用，是否取消？(y/N): " yn
    [[ "$yn" =~ ^[Yy]$ ]] && systemctl disable "$unit" && echo "已取消 $unit"
  else
    systemctl enable "$unit" && echo "已启用 $unit"
  fi
}

remove_interactive(){
  local pb; pb="$(pick_pb)" || return
  remove_pb "$pb"
  local unit="virtjoin@${pb}.service"
  if systemctl list-unit-files | grep -q "^$unit"; then
    read -rp "是否同时取消自动恢复 $unit ? (y/N): " yn
    [[ "$yn" =~ ^[Yy]$ ]] && systemctl disable "$unit"
  fi
}

full_uninstall(){
  echo -e "${yellow}⚠️ 确定要完全卸载 virtjoin 吗？(y/N)${reset}"
  read -r yn; [[ "$yn" =~ ^[Yy]$ ]] || { echo "已取消"; return; }
  for pb in $(list_pbs); do remove_pb "$pb"; done
  rm -rf "$BASE_DIR" "$SYSTEMD_TMPL" "$SELF_PATH"
  systemctl daemon-reload
  echo -e "${green}🗑️ 已完全卸载 virtjoin${reset}"
  exit 0
}

# ---- CLI ----
if [[ "${1:-}" =~ ^-- ]]; then
  case "$1" in
    --status) show_status ;;
    --create) create_interactive ;;
    --create-from-config) _do_build_from_cfg "${2:-}" ;;
    --toggle-autorecover) toggle_autorecover ;;
    --remove) remove_interactive ;;
    --uninstall) full_uninstall ;;
    *) echo "用法: virtjoin.sh [--status|--create|--create-from-config <cfg>|--toggle-autorecover|--remove|--uninstall]" ;;
  esac
  exit 0
fi

# ---- 菜单 ----
while true; do
  clear
  echo -e "${green}===============================${reset}"
  echo -e "${green} virtjoin 控制中心（多映射）${reset}"
  echo -e "${green}===============================${reset}"
  show_status
  echo "1) 查看当前状态"
  echo "2) 创建/重新拼接虚拟整盘"
  echo "3) 注册/取消 systemd 自动恢复"
  echo "4) 手动移除某个映射（同时取消自动恢复）"
  echo "5) 卸载 virtjoin（清理所有映射/服务/脚本）"
  echo "0) 退出"
  read -rp "请选择操作 [0-5]: " opt; echo
  case "$opt" in
    1) show_status ;;
    2) create_interactive ;;
    3) toggle_autorecover ;;
    4) remove_interactive ;;
    5) full_uninstall ;;
    0) echo "再见 👋"; exit 0 ;;
    *) warn "无效选项，请重试" ;;
  esac
  echo; read -rp "按 Enter 返回菜单..." _
done
