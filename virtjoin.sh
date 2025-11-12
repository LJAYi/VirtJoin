#!/bin/bash
# ============================================================
#  virtjoin v3.0.3-manual — Secure Multi-Mapping (Manual Disk/Part Input)
#  Author: LJAYi
#  Highlights:
#   • 多映射：每个分区独立目录/独立 dm 名/独立 systemd 实例
#   • 手动输入磁盘与分区（展示可用整盘列表，确保任何设备类型都可用）
#   • 安全校验：分区归属检查 + GPT 尾部扇区检查（≥33）
#   • 仅首次创建 header.img，避免系统启动时重复重建
#   • 失败自动清理 loop（trap）
#   • 一行安装：自动复制至 /usr/local/bin/virtjoin.sh 并重启自身
# ============================================================

set -euo pipefail
[ "${EUID:-$(id -u)}" -eq 0 ] || { echo "[virtjoin] ERROR: 请用 root 运行"; exit 1; }
umask 0077

LOG_TAG="[virtjoin]"
BASE_DIR="/var/lib/virtjoin"
SYSTEMD_TMPL="/etc/systemd/system/virtjoin@.service"
SELF_PATH="/usr/local/bin/virtjoin.sh"
REPO_URL="https://raw.githubusercontent.com/LJAYi/VirtJoin/main/virtjoin.sh"
VERSION="v3.0.3-manual"

green="\e[32m"; yellow="\e[33m"; red="\e[31m"; reset="\e[0m"
log(){ echo -e "${green}${LOG_TAG}${reset} $*"; }
warn(){ echo -e "${yellow}${LOG_TAG}${reset} ⚠️ $*"; }
die(){ echo -e "${red}${LOG_TAG} ERROR:${reset} $*" >&2; exit 1; }

need_cmd(){ command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }
for c in blockdev losetup dmsetup dd truncate awk grep sed stat systemctl lsblk curl readlink realpath; do need_cmd "$c"; done
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

# ---- 工具与路径（多映射） ----
loop_of(){ losetup -j "$1" | awk -F: '{print $1}'; }
pb_from_part(){ basename "$1"; }                 # sda1 / nvme0n1p1 / vda1
dir_of_pb(){ echo "$BASE_DIR/$1"; }               # /var/lib/virtjoin/sda1
dmname_of_pb(){ echo "virtjoin-$1"; }             # virtjoin-sda1
cfg_of_dir(){ echo "$1/config"; }
header_of_dir(){ echo "$1/header.img"; }
tail_of_dir(){ echo "$1/tail.img"; }
table_of_dir(){ echo "$1/table.txt"; }

# ---- systemd 模板（实例化） ----
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

# ---- 罗列已配置的映射（目录存在且带 config） ----
list_pbs(){
  find "$BASE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while read -r d; do
    [ -f "$(cfg_of_dir "$d")" ] && basename "$d"
  done
}

# ---- 状态显示（多映射） ----
show_status(){
  echo -e "\n====== virtjoin 状态 ======"
  local any=0
  while read -r pb; do
    [ -z "$pb" ] && continue
    any=1
    local dm="/dev/mapper/$(dmname_of_pb "$pb")"
    local cfg="$(cfg_of_dir "$(dir_of_pb "$pb")")"
    if dmsetup info "$(dmname_of_pb "$pb")" &>/dev/null; then
      echo "• $(dmname_of_pb "$pb") 存在 ($dm)"
    else
      echo "• $(dmname_of_pb "$pb") 不存在"
    fi
    [ -f "$cfg" ] && echo "  ↳ $(sed -n '1,2p' "$cfg" | tr '\n' ' ')"
  done < <(list_pbs)
  [ "$any" -eq 0 ] && echo "暂无任何 virtjoin 映射。"
  echo -e "===========================\n"
}

# ---- 移除单个映射（安全清理 loop） ----
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

# ---- 核心构建（从 config 非交互） ----
_do_build_from_cfg(){
  local cfg="$1"
  [ -f "$cfg" ] || die "缺少配置: $cfg"
  # shellcheck disable=SC1090
  source "$cfg"
  [ -n "${DISK:-}" ] && [ -n "${PART:-}" ] && [ -n "${PB:-}" ] || die "配置不完整: $cfg"

  local d dm hdr tl tbl
  d="$(dir_of_pb "$PB")"; dm="$(dmname_of_pb "$PB")"
  hdr="$(header_of_dir "$d")"; tl="$(tail_of_dir "$d")"; tbl="$(table_of_dir "$d")"
  [ -b "$DISK" ] || die "磁盘不存在: $DISK"
  [ -b "$PART" ] || die "分区不存在: $PART"

  # 分区归属校验
  local pbase dbase got
  pbase="$(basename "$PART")"; dbase="$(basename "$DISK")"
  got="$(basename "$(realpath "/sys/class/block/$pbase/..")")"
  [ "$got" = "$dbase" ] || die "选择错误：$PART 不属于 $DISK"

  # 扇区信息
  local SS START PART_SECTORS DISK_SECTORS TAIL_SECTORS
  SS=$(blockdev --getss "$DISK")
  START=$(cat /sys/block/"$dbase"/"$pbase"/start)
  PART_SECTORS=$(blockdev --getsz "$PART")
  DISK_SECTORS=$(blockdev --getsz "$DISK")
  TAIL_SECTORS=$((DISK_SECTORS - START - PART_SECTORS))
  [ "$TAIL_SECTORS" -ge 33 ] || die "尾部空间不足（$TAIL_SECTORS 扇区）"

  # 仅首次创建 header，tail 每次按需调整
  mkdir -p "$d"
  if [ ! -f "$hdr" ]; then
    dd if="$DISK" of="$hdr" bs="$SS" count="$START" status=none
    log "[$dm] header.img 已创建"
  else
    log "[$dm] 保留 header.img"
  fi
  truncate -s $((TAIL_SECTORS * SS)) "$tl"

  # 绑定 loop，失败自动清理
  local LOOP_HEADER LOOP_TAIL
  LOOP_HEADER=$(losetup -fP --show "$hdr")
  LOOP_TAIL=$(losetup -fP --show "$tl")
  cleanup_loops(){ losetup -d "$LOOP_HEADER" 2>/dev/null || true; losetup -d "$LOOP_TAIL" 2>/dev/null || true; }
  trap cleanup_loops ERR INT

  # 生成 dm-table 并创建映射
  cat >"$tbl" <<EOF
0 ${START} linear ${LOOP_HEADER} 0
${START} ${PART_SECTORS} linear ${PART} 0
$((START + PART_SECTORS)) ${TAIL_SECTORS} linear ${LOOP_TAIL} 0
EOF
  dmsetup create "$dm" "$tbl"
  trap - ERR INT
  echo -e "${green}✅ 已创建 $dm (/dev/mapper/$dm)${reset}"
}

# ---- 手动交互创建（回退到 v2.5 风格，但保存为多映射） ----
create_interactive(){
  echo -e "${green}✨ 创建/重建 virtjoin（手动输入磁盘/分区）...${reset}"

  # 展示“整盘”列表（TYPE=disk），仅供参考；真正的输入允许任意合法块设备名
  echo "可用整盘 (TYPE=disk)："
  lsblk -dpno NAME,TYPE,SIZE,MODEL | awk '$2=="disk"{print "  -",$1,$3,$4}' || true
  echo

  # 手动输入磁盘
  local DISK PART PB D CFG
  read -rp "请输入目标磁盘 (例如 /dev/sda 或 /dev/nvme0n1 或 /dev/vda): " DISK
  [ -b "$DISK" ] || die "$DISK 不是块设备。"

  echo
  echo "该磁盘的分区："
  lsblk -no NAME,SIZE,FSTYPE,MOUNTPOINT -p "$DISK" | sed '1!b; s/^/  /' || true
  echo
  read -rp "请选择要直通的分区 (例如 sda1 或 /dev/sda1): " PART
  [[ "$PART" != /dev/* ]] && PART="/dev/$PART"
  [ -b "$PART" ] || die "$PART 不存在。"

  # 校验分区归属
  local pbase dbase got
  pbase="$(basename "$PART")"; dbase="$(basename "$DISK")"
  got="$(basename "$(realpath "/sys/class/block/$pbase/..")")"
  [ "$got" = "$dbase" ] || die "选择错误：$PART 不属于 $DISK"

  # 为该分区构建独立配置与目录
  PB="$(pb_from_part "$PART")"
  D="$(dir_of_pb "$PB")"; mkdir -p "$D"
  CFG="$(cfg_of_dir "$D")"
  cat >"$CFG" <<EOF
DISK="$DISK"
PART="$PART"
PB="$PB"
EOF
  log "配置已保存到 $CFG"

  # 旧映射清理并重建（强制重建 header）
  rm -f "$(header_of_dir "$D")"
  remove_pb "$PB" || true
  _do_build_from_cfg "$CFG"

  # 询问是否注册/启用 systemd 自动恢复
  read -rp "是否注册 systemd 自动恢复 [$PB]？(y/N): " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    ensure_tmpl_unit
    systemctl enable "virtjoin@${PB}.service"
    log "已启用：virtjoin@${PB}.service"
  fi
}

# ---- 选择某个已配置映射 ----
pick_pb(){
  mapfile -t PBS < <(list_pbs)
  [ "${#PBS[@]}" -gt 0 ] || { echo "暂无配置"; return 1; }
  echo "请选择目标映射："
  local i=1; for pb in "${PBS[@]}"; do echo "[$i] $pb"; i=$((i+1)); done; echo "[0] 取消"
  read -rp "编号: " idx; [[ "$idx" =~ ^[0-9]+$ ]] || { echo "输入无效"; return 1; }
  [ "$idx" -eq 0 ] && return 1
  echo "${PBS[$((idx-1))]}"
}

# ---- 切换自动恢复（针对单一映射实例） ----
toggle_autorecover(){
  local pb; pb="$(pick_pb)" || { echo "已取消"; return; }
  ensure_tmpl_unit
  local unit="virtjoin@${pb}.service"
  if systemctl is-enabled "$unit" &>/dev/null; then
    read -rp "$unit 已启用，是否取消？(y/N): " yn
    [[ "$yn" =~ ^[Yy]$ ]] && systemctl disable "$unit" && echo "已取消 $unit"
  else
    systemctl enable "$unit" && echo "已启用 $unit"
  fi
}

# ---- 移除某个映射（可选同时取消自动恢复） ----
remove_interactive(){
  local pb; pb="$(pick_pb)" || { echo "已取消"; return; }
  remove_pb "$pb"
  local unit="virtjoin@${pb}.service"
  if systemctl list-unit-files | grep -q "^$unit"; then
    read -rp "是否同时取消自动恢复 $unit ? (y/N): " yn
    [[ "$yn" =~ ^[Yy]$ ]] && systemctl disable "$unit"
  fi
}

# ---- 完全卸载（清理所有映射/服务/脚本） ----
full_uninstall(){
  echo -e "${yellow}⚠️ 确定要完全卸载 virtjoin 吗？(y/N)${reset}"
  read -r yn; [[ "$yn" =~ ^[Yy]$ ]] || { echo "已取消"; return; }
  # 移除所有映射
  while read -r pb; do [ -n "$pb" ] && remove_pb "$pb"; done < <(list_pbs || true)
  # 禁用所有实例服务
  if [ -f "$SYSTEMD_TMPL" ]; then
    systemctl list-unit-files 'virtjoin@*.service' --no-legend 2>/dev/null | awk '{print $1}' | while read -r u; do
      [ -n "$u" ] && systemctl disable "$u" 2>/dev/null || true
    done
  fi
  rm -f "$SYSTEMD_TMPL"
  systemctl daemon-reload
  rm -rf "$BASE_DIR" "$SELF_PATH"
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

# ---- 主菜单 ----
while true; do
  clear
  echo -e "${green}===============================${reset}"
  echo -e "${green} virtjoin 控制中心（多映射） ${VERSION}${reset}"
  echo -e "${green}===============================${reset}"
  show_status
  echo "1) 查看当前状态"
  echo "2) 创建/重建 virtjoin（手动输入磁盘/分区）"
  echo "3) 注册/取消 systemd 自动恢复"
  echo "4) 手动移除某个映射（同时取消自动恢复）"
  echo "5) 卸载 virtjoin（清理所有映射/服务/脚本）"
  echo "0) 退出"
  read -rp "请选择操作 [0-5]: " opt; echo
  case "$opt" in
    1) show_status ;;
    2) create_interactive ;;
    3) toggle_autorecover || true ;;
    4) remove_interactive || true ;;
    5) full_uninstall ;;
    0) echo "再见 👋"; exit 0 ;;
    *) warn "无效选项，请重试" ;;
  esac
  echo; read -rp "按 Enter 返回菜单..." _
done
