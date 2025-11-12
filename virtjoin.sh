#!/bin/bash
# ============================================================
#  virtjoin v2.6 — Multi-mapping Manager for Proxmox VE
#  Author: LJAYi
#  Highlights:
#   • 多映射：每个分区独立名 / 独立目录 / 独立 systemd 实例
#   • 交互数字选择 + 可取消
#   • 创建后可选择是否注册自动恢复
#   • 指定映射手动移除（可选联动取消自动恢复）
#   • 指定映射注册/取消自动恢复
#   • 一行安装：自动识别 /proc 与 /dev/fd 输入
#   • 4K 扇区、GPT 尾部校验、分区归属校验、loop 清理
# ============================================================

set -euo pipefail
[ "${EUID:-$(id -u)}" -eq 0 ] || { echo "[virtjoin] ERROR: 请用 root 运行"; exit 1; }
umask 0077

LOG_TAG="[virtjoin]"
BASE_DIR="/var/lib/virtjoin"
SYSTEMD_TMPL="/etc/systemd/system/virtjoin@.service"
SELF_PATH="/usr/local/bin/virtjoin.sh"
REPO_URL="https://raw.githubusercontent.com/LJAYi/VirtJoin/main/virtjoin.sh"

green="\e[32m"; yellow="\e[33m"; red="\e[31m"; dim="\e[2m"; reset="\e[0m"
log()  { echo -e "${green}${LOG_TAG}${reset} $*"; }
warn() { echo -e "${yellow}${LOG_TAG}${reset} ⚠️ $*"; }
die()  { echo -e "${red}${LOG_TAG} ERROR:${reset} $*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }
for c in blockdev losetup dmsetup dd truncate awk grep sed stat systemctl lsblk curl readlink; do need_cmd "$c"; done
mkdir -p "$BASE_DIR"

# ---- 自安装检查（支持一行安装） ----
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

# ---- 基础工具 ----
loop_of() { losetup -j "$1" | awk -F: '{print $1}'; }

pb_from_part() { basename "$1"; }   # sda1 / nvme0n1p1
dir_of_pb()    { echo "$BASE_DIR/$1"; }
dmname_of_pb() { echo "virtjoin-$1"; }
cfg_of_dir()   { echo "$1/config"; }
header_of_dir(){ echo "$1/header.img"; }
tail_of_dir()  { echo "$1/tail.img"; }
table_of_dir() { echo "$1/table.txt"; }

ensure_tmpl_unit() {
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

# ---- 列出现有映射（按目录） ----
list_pbs() {
  # 输出所有已配置的 pb（目录存在且有 config）
  find "$BASE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while read -r d; do
    [ -f "$(cfg_of_dir "$d")" ] && basename "$d"
  done
}

# ---- 状态 ----
show_status() {
  echo -e "\n====== virtjoin 状态 ======"
  local any=0
  while read -r pb; do
    [ -z "$pb" ] && continue
    any=1
    local dm dm_path cfg
    dm="$(dmname_of_pb "$pb")"
    dm_path="/dev/mapper/$dm"
    cfg="$(cfg_of_dir "$(dir_of_pb "$pb")")"
    if dmsetup info "$dm" >/dev/null 2>&1; then
      size="$(blockdev --getsize64 "$dm_path" 2>/dev/null || echo 0)"
      echo "• $dm  (PB=$pb)  存在  size=${size} bytes"
    else
      echo "• $dm  (PB=$pb)  不存在"
    fi
    if [ -f "$cfg" ]; then
      echo "  配置: $(sed -n '1,2p' "$cfg" | tr '\n' ' ' )"
    fi
  done < <(list_pbs)
  if [ "$any" -eq 0 ]; then
    echo "暂无任何 virtjoin 映射。"
  fi
  echo -e "===========================\n"
}

# ---- 安全移除（某个 pb） ----
remove_pb() {
  local pb="$1"
  local d="$(dir_of_pb "$pb")"
  local dm="$(dmname_of_pb "$pb")"
  local dm_path="/dev/mapper/$dm"
  local hdr="$(header_of_dir "$d")"
  local tl="$(tail_of_dir "$d")"

  echo -e "${yellow}🧹 正在移除 $dm ...${reset}"
  dmsetup remove "$dm" 2>/dev/null || true
  for f in "$hdr" "$tl"; do
    lp="$(loop_of "$f" || true)"
    if [ -n "$lp" ]; then
      while read -r one; do [ -n "$one" ] && losetup -d "$one" 2>/dev/null || true; done <<< "$lp"
      log "已卸载 loop: $lp"
    fi
  done
  sleep 0.1
}

# ---- 构建核心（基于 config） ----
_do_build_from_cfg() {
  local cfg="$1"
  [ -f "$cfg" ] || die "缺少配置: $cfg"
  # shellcheck disable=SC1090
  source "$cfg"
  [ -n "${DISK:-}" ] && [ -n "${PART:-}" ] && [ -n "${PB:-}" ] || die "配置不完整: $cfg"

  local d dm hdr tl tbl dm_path
  d="$(dir_of_pb "$PB")"; dm="$(dmname_of_pb "$PB")"
  hdr="$(header_of_dir "$d")"; tl="$(tail_of_dir "$d")"; tbl="$(table_of_dir "$d")"
  dm_path="/dev/mapper/$dm"

  [ -b "$DISK" ] || die "磁盘不存在: $DISK"
  [ -b "$PART" ] || die "分区不存在: $PART"

  # 校验分区归属
  local pbase dbase got
  pbase="$(basename "$PART")"; dbase="$(basename "$DISK")"
  got="$(basename "$(realpath "/sys/class/block/$pbase/..")")"
  [ "$got" = "$dbase" ] || die "选择错误：$PART 不属于 $DISK"

  local SS START PART_SECTORS DISK_SECTORS TAIL_SECTORS
  SS=$(blockdev --getss "$DISK")
  START=$(cat /sys/block/"$dbase"/"$pbase"/start)
  PART_SECTORS=$(blockdev --getsz "$PART")
  DISK_SECTORS=$(blockdev --getsz "$DISK")
  TAIL_SECTORS=$((DISK_SECTORS - START - PART_SECTORS))
  [ "$TAIL_SECTORS" -ge 33 ] || die "尾部空间不足（$TAIL_SECTORS 扇区）"

  echo "[INFO][$dm] Start=$START  PartSectors=$PART_SECTORS  Tail=$TAIL_SECTORS  SS=$SS"

  mkdir -p "$d"
  if [ ! -f "$hdr" ]; then
    dd if="$DISK" of="$hdr" bs="$SS" count="$START" status=none
    log "[$dm] header.img 已创建"
  else
    log "[$dm] 保留 header.img"
  fi
  truncate -s $((TAIL_SECTORS * SS)) "$tl"
  log "[$dm] tail.img 已创建/更新"

  local LOOP_HEADER LOOP_TAIL
  LOOP_HEADER=$(losetup -fP --show "$hdr")
  LOOP_TAIL=$(losetup -fP --show "$tl")
  cleanup_loops() { losetup -d "$LOOP_HEADER" 2>/dev/null || true; losetup -d "$LOOP_TAIL" 2>/dev/null || true; }
  trap cleanup_loops ERR INT

  cat >"$tbl" <<EOF
0 ${START} linear ${LOOP_HEADER} 0
${START} ${PART_SECTORS} linear ${PART} 0
$((START + PART_SECTORS)) ${TAIL_SECTORS} linear ${LOOP_TAIL} 0
EOF

  dmsetup create "$dm" "$tbl"
  trap - ERR INT
  echo -e "${green}✅ 已创建 $dm ($dm_path)${reset}"
}

# ---- 交互数字选择：磁盘 -> 分区 ----
pick_disk() {
  mapfile -t DISKS < <(lsblk -dpno NAME,SIZE,MODEL | grep -E "/dev/sd|/dev/nvme" || true)
  [ "${#DISKS[@]}" -gt 0 ] || die "未发现可用磁盘"
  echo "请选择目标磁盘："
  local i=1
  for row in "${DISKS[@]}"; do echo "[$i] $row"; i=$((i+1)); done
  echo "[0] 取消"
  read -rp "编号: " idx
  [[ "$idx" =~ ^[0-9]+$ ]] || die "输入无效"
  [ "$idx" -eq 0 ] && return 1
  [ "$idx" -ge 1 ] && [ "$idx" -le "${#DISKS[@]}" ] || die "编号越界"
  # 取第一列 NAME
  local line="${DISKS[$((idx-1))]}"
  echo "$line" | awk '{print $1}'
}

pick_part() {
  local disk="$1"
  mapfile -t PARTS < <(lsblk -no NAME,SIZE,FSTYPE -p "$disk" | tail -n +2 || true)
  [ "${#PARTS[@]}" -gt 0 ] || die "该磁盘无分区"
  echo "请选择要直通的分区："
  local i=1
  for row in "${PARTS[@]}"; do echo "[$i] $row"; i=$((i+1)); done
  echo "[0] 取消"
  read -rp "编号: " idx
  [[ "$idx" =~ ^[0-9]+$ ]] || die "输入无效"
  [ "$idx" -eq 0 ] && return 1
  [ "$idx" -ge 1 ] && [ "$idx" -le "${#PARTS[@]}" ] || die "编号越界"
  echo "${PARTS[$((idx-1))]}" | awk '{print $1}'
}

# ---- 交互创建/重建：写入独立目录 + 独立 dm 名 ----
create_interactive() {
  echo -e "${green}✨ 创建/重建 virtjoin（交互配置）...${reset}"
  local DISK PART PB D CFG
  DISK="$(pick_disk)" || { echo "已取消"; return; }
  [ -b "$DISK" ] || die "$DISK 不是块设备。"
  PART="$(pick_part "$DISK")" || { echo "已取消"; return; }
  [ -b "$PART" ] || die "$PART 不存在。"

  PB="$(pb_from_part "$PART")"
  D="$(dir_of_pb "$PB")"
  mkdir -p "$D"
  CFG="$(cfg_of_dir "$D")"

  # 校验分区归属
  local pbase dbase got
  pbase="$(basename "$PART")"; dbase="$(basename "$DISK")"
  got="$(basename "$(realpath "/sys/class/block/$pbase/..")")"
  [ "$got" = "$dbase" ] || die "选择错误：$PART 不属于 $DISK"

  # 写配置
  cat >"$CFG" <<EOF
DISK="$DISK"
PART="$PART"
PB="$PB"
EOF
  log "配置已保存到 $CFG"

  # 强制 header 重建
  rm -f "$(header_of_dir "$D")" && log "已清除旧 header.img，将按新配置重建"

  # 移除旧映射并重建
  remove_pb "$PB" || true
  _do_build_from_cfg "$CFG"

  # 询问是否注册自动恢复
  read -rp "是否为 [$PB] 注册 systemd 自动恢复？(y/N): " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    ensure_tmpl_unit
    systemctl enable "virtjoin@${PB}.service"
    systemctl daemon-reload
    log "已启用自动恢复：virtjoin@${PB}.service"
  else
    echo "已跳过自动恢复注册。"
  fi

  echo
  echo "提示：将映射添加到 VM（示例 VMID=101）"
  echo "  qm set 101 -virtio0 /dev/mapper/$(dmname_of_pb "$PB")"
}

# ---- 从配置重建（非交互；接受路径或自动判定） ----
create_from_config_cli() {
  local cfg="${1:-}"
  if [ -z "$cfg" ]; then
    # 若只有一个配置，则自动使用
    mapfile -t ALL < <(find "$BASE_DIR" -mindepth 2 -maxdepth 2 -type f -name config 2>/dev/null)
    [ "${#ALL[@]}" -eq 1 ] || die "存在多个或没有配置，请明确指定 config 路径。"
    cfg="${ALL[0]}"
  fi
  _do_build_from_cfg "$cfg"
}

# ---- 选择某个映射（pb） ----
pick_pb() {
  mapfile -t PBS < <(list_pbs)
  [ "${#PBS[@]}" -gt 0 ] || { echo "暂无配置"; return 1; }
  echo "请选择目标映射："
  local i=1
  for pb in "${PBS[@]}"; do
    local dm cfg
    dm="$(dmname_of_pb "$pb")"; cfg="$(cfg_of_dir "$(dir_of_pb "$pb")")"
    local mark="未加载"
    if dmsetup info "$dm" >/dev/null 2>&1; then mark="已加载"; fi
    echo "[$i] $pb  ($dm, $mark)"
    i=$((i+1))
  done
  echo "[0] 取消"
  read -rp "编号: " idx
  [[ "$idx" =~ ^[0-9]+$ ]] || { echo "输入无效"; return 1; }
  [ "$idx" -eq 0 ] && return 1
  [ "$idx" -ge 1 ] && [ "$idx" -le "${#PBS[@]}" ] || { echo "编号越界"; return 1; }
  echo "${PBS[$((idx-1))]}"
}

# ---- 注册/取消 自动恢复（选择映射）----
toggle_autorecover() {
  local pb; pb="$(pick_pb)" || { echo "已取消"; return; }
  ensure_tmpl_unit
  local unit="virtjoin@${pb}.service"
  if systemctl is-enabled "$unit" >/dev/null 2>&1; then
    read -rp "$unit 已启用，是否取消？(y/N): " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
      systemctl disable "$unit" || true
      systemctl daemon-reload
      echo "已取消启用：$unit"
    else
      echo "保持启用。"
    fi
  else
    systemctl enable "$unit"
    systemctl daemon-reload
    echo "已启用：$unit"
  fi
}

# ---- 手动移除映射（选择映射，并可选移除自动恢复） ----
remove_interactive() {
  local pb; pb="$(pick_pb)" || { echo "已取消"; return; }
  remove_pb "$pb"
  local unit="virtjoin@${pb}.service"
  if [ -f "$SYSTEMD_TMPL" ] && systemctl list-unit-files | grep -q "^$unit"; then
    read -rp "是否同时取消自动恢复 $unit ? (y/N): " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
      systemctl disable "$unit" || true
      systemctl daemon-reload
      echo "已取消启用：$unit"
    fi
  fi
  echo "如需彻底删除该配置，手动删除目录：rm -rf $(dir_of_pb "$pb")"
}

# ---- 完全卸载工具（不保留任何配置/服务） ----
full_uninstall() {
  echo -e "${yellow}⚠️ 确定要完全卸载 virtjoin 吗？(映射/loop/systemd/脚本){y/N}${reset}"
  read -r yn; [[ "$yn" =~ ^[Yy]$ ]] || { echo "已取消"; return; }
  # 移除所有映射
  while read -r pb; do
    [ -n "$pb" ] && remove_pb "$pb"
  done < <(list_pbs || true)
  # 取消所有实例服务
  if [ -f "$SYSTEMD_TMPL" ]; then
    systemctl list-unit-files 'virtjoin@*.service' --no-legend 2>/dev/null | awk '{print $1}' | while read -r u; do
      [ -n "$u" ] && systemctl disable "$u" 2>/dev/null || true
    done
  fi
  rm -f "$SYSTEMD_TMPL"
  systemctl daemon-reload
  rm -rf "$BASE_DIR"
  rm -f "$SELF_PATH"
  echo -e "${green}🗑️ 已完全卸载 virtjoin${reset}"
  exit 0
}

# ---- CLI ----
if [[ "${1:-}" =~ ^-- ]]; then
  case "$1" in
    --status)              show_status ;;
    --create)              create_interactive ;;
    --create-from-config)  create_from_config_cli "${2:-}" ;;
    --toggle-autorecover)  toggle_autorecover ;;
    --remove)              remove_interactive ;;
    --uninstall)           full_uninstall ;;
    *) echo "用法: virtjoin.sh [--status|--create|--create-from-config <cfg>|--toggle-autorecover|--remove|--uninstall]";;
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
  echo "2) 创建或重新拼接虚拟整盘 (交互配置，生成 virtjoin-<分区>)"
  echo "3) 注册/取消 某个映射的 systemd 自动恢复"
  echo "4) 手动移除某个映射（可选同时取消自动恢复）"
  echo "5) 完全卸载 virtjoin（清理所有映射/服务/脚本）"
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
