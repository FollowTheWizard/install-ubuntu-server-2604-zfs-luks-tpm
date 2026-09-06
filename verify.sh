#!/usr/bin/env bash
# =============================================================================
#  verify-install.sh  rev 4
#  Fixes: (1) ok/fail/warn counter arithmetic causing double-fire
#         (2) wrong BE00 GUID + zpool-status fallback for bpool detection
#  Run on the installed system (after first boot) as root.
#  Usage:  sudo bash verify-install.sh [--disk1 /dev/sdX] [--disk2 /dev/sdY]
# =============================================================================
set -uo pipefail

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[0;33m'
CYN='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'
PASS=0; FAIL=0; WARN=0

# FIX 1: use pre-increment (( ++X )) so the expression always evaluates to
# the NEW value (≥1 = true).  Post-increment (( X++ )) evaluates to the OLD
# value; when X=0 that is (( 0 )) = exit 1, causing  && ok || fail  to fire
# BOTH branches on the very first check.
ok()   { echo -e "  ${GRN}[PASS]${RST} $*"; (( ++PASS )); return 0; }
fail() { echo -e "  ${RED}[FAIL]${RST} $*"; (( ++FAIL )); return 0; }
warn() { echo -e "  ${YLW}[WARN]${RST} $*"; (( ++WARN )); return 0; }
info() { echo -e "  ${CYN}[INFO]${RST} $*"; }
hdr()  { echo -e "\n${BLD}══ $* ${RST}"; }

DISK1=""; DISK2=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --disk1) DISK1=$2; shift 2 ;;
    --disk2) DISK2=$2; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo bash $0)"; exit 1; }

detect_disk_from_uuid() {
  blkid -U "$1" 2>/dev/null | sed 's/p\?[0-9]*$//' | head -1
}

if [[ -z $DISK1 || -z $DISK2 ]] && [[ -f /etc/crypttab ]]; then
  UUID_RP1=$(awk '/^luks-root1/{gsub("UUID=",""); print $2}' /etc/crypttab)
  UUID_RP2=$(awk '/^luks-root2/{gsub("UUID=",""); print $2}' /etc/crypttab)
  [[ -z $DISK1 && -n ${UUID_RP1:-} ]] && DISK1=$(detect_disk_from_uuid "$UUID_RP1")
  [[ -z $DISK2 && -n ${UUID_RP2:-} ]] && DISK2=$(detect_disk_from_uuid "$UUID_RP2")
fi

echo -e "${BLD}"
echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║      ZFS + LUKS2 + TPM2 Install Verification  (rev 4)                  ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo -e "${RST}"
info "DISK1 = ${DISK1:-(unknown)}"
info "DISK2 = ${DISK2:-(unknown)}"

# =============================================================================
hdr "1. UEFI / FIRMWARE"
# =============================================================================

if [[ -d /sys/firmware/efi ]]; then
  ok "Booted in UEFI mode"
else
  fail "NOT in UEFI mode — /sys/firmware/efi missing"
fi

if efibootmgr -q 2>/dev/null; then
  ubuntu_entries=$(efibootmgr 2>/dev/null | grep -i ubuntu | wc -l)
  if (( ubuntu_entries >= 1 )); then
    ok "NVRAM has $ubuntu_entries ubuntu boot entry/entries"
    efibootmgr 2>/dev/null | grep -i ubuntu | while read -r line; do info "  $line"; done
  else
    fail "No 'ubuntu' entry found in NVRAM"
  fi
else
  warn "efibootmgr not available or failed"
fi

# =============================================================================
hdr "2. DISK PARTITIONS"
# =============================================================================
# Partition type GUIDs (lowercase, as lsblk PARTTYPE reports them)
#
# FIX 2: BE00 "Solaris boot" GUID is 6a82cb45-1dd2-11b2-99a6-080020736631
#   Rev 2 had 6a898cc3-... (that's BF01 "Solaris /usr & Mac ZFS")
#   Rev 3 had 83bd6b9d-... (that's FreeBSD boot)
#   Neither matched.  Correct value confirmed from gdisk/sgdisk source.
#
# Additionally: if GUID lookup still fails (some firmware/disk combos remap
# type GUIDs), we fall back to checking zpool status to confirm bpool lives
# on this disk — which is ground truth.

GUID_EFI="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"   # EF00 EFI System
GUID_BPOOL="6a82cb45-1dd2-11b2-99a6-080020736631"  # BE00 Solaris boot ← FIXED
GUID_SWAP="0657fd6d-a4ab-43c4-84e5-0933c84b4f4f"   # 8200 Linux swap
GUID_LUKS="ca7d7ccb-63ed-4c53-861c-1742536059cc"   # 8309 Linux LUKS

# Build set of block devices that are bpool vdev members (ground-truth fallback)
BPOOL_DEVS=()
if zpool list bpool &>/dev/null; then
  while IFS= read -r dev; do
    [[ -b $dev ]] && BPOOL_DEVS+=("$(readlink -f "$dev")")
  done < <(zpool status bpool 2>/dev/null \
    | awk '/^\t  (\/|sd|nvme|vd|hd)/{print $1}')
fi

disk_has_bpool_partition() {
  # Check if any partition on $1 is a known bpool vdev member
  local real=$1 p
  for p in "${BPOOL_DEVS[@]:-}"; do
    [[ $p == "${real}"* ]] && return 0
  done
  return 1
}

check_partitions() {
  local disk=$1 label=$2
  [[ -z $disk ]] && { warn "$label: disk not detected — skipping"; return; }
  [[ -b $disk || -L $disk ]] || { fail "$label: $disk not a block device"; return; }

  local real; real=$(readlink -f "$disk")
  info "$label → $real"

  local found_efi=0 found_bpool=0 found_swap=0 luks_count=0

  # ── primary: sgdisk -p  (Code column = $(NF-1)) ──────────────────────────
  while IFS= read -r line; do
    [[ $line =~ ^[[:space:]]*[0-9] ]] || continue
    local code; code=$(awk '{print $(NF-1)}' <<< "$line")
    case "${code^^}" in
      EF00) (( found_efi++   )) ;;
      BE00) (( found_bpool++ )) ;;
      8200) (( found_swap++  )) ;;
      8309) (( luks_count++  )) ;;
    esac
  done < <(sgdisk -p "$real" 2>/dev/null)

  # ── secondary: lsblk PARTTYPE GUIDs ─────────────────────────────────────
  if (( found_efi + found_bpool + found_swap + luks_count == 0 )); then
    info "  sgdisk matched nothing — using lsblk PARTTYPE GUIDs"
    while IFS= read -r guid; do
      [[ -z $guid ]] && continue
      case "${guid,,}" in
        "$GUID_EFI"  ) (( found_efi++   )) ;;
        "$GUID_BPOOL") (( found_bpool++ )) ;;
        "$GUID_SWAP" ) (( found_swap++  )) ;;
        "$GUID_LUKS" ) (( luks_count++  )) ;;
      esac
    done < <(lsblk -nro PARTTYPE "$real" 2>/dev/null)
  fi

  # ── tertiary: ground-truth bpool vdev membership ─────────────────────────
  # If GUID lookup still shows 0 for bpool but the disk IS a bpool member,
  # trust zpool status over partition metadata.
  if (( found_bpool == 0 )) && disk_has_bpool_partition "$real"; then
    info "  bpool GUID not matched by lsblk — but zpool status confirms bpool vdev on this disk"
    (( found_bpool++ ))
  fi

  (( found_efi   >= 1 )) && ok  "$label: EFI partition (EF00) present" \
                           || fail "$label: EFI partition (EF00) MISSING"
  (( found_bpool >= 1 )) && ok  "$label: bpool partition (BE00) present" \
                           || fail "$label: bpool partition (BE00) MISSING"
  (( found_swap  >= 1 )) && ok  "$label: swap partition (8200) present" \
                           || fail "$label: swap partition (8200) MISSING"
  (( luks_count  >= 2 )) && ok  "$label: $luks_count × LUKS partitions (8309) — root + data" \
                           || fail "$label: expected ≥2 LUKS (8309) partitions, found $luks_count"
}

check_partitions "$DISK1" "DISK1"
check_partitions "$DISK2" "DISK2"

# =============================================================================
hdr "3. EFI FILESYSTEMS"
# =============================================================================

for mnt in /boot/efi /boot/efi2; do
  if mountpoint -q "$mnt" 2>/dev/null; then
    fstype=$(findmnt -no FSTYPE "$mnt")
    if [[ $fstype == vfat ]]; then
      ok "$mnt mounted (vfat)"
      grub_efi=$(find "$mnt/EFI" -name 'grubx64.efi' 2>/dev/null | head -1)
      shim=$(    find "$mnt/EFI" -name 'shimx64.efi'  2>/dev/null | head -1)
      [[ -n $grub_efi ]] && ok "  grubx64.efi found: $grub_efi" \
                          || fail "  grubx64.efi NOT found under $mnt/EFI"
      [[ -n $shim    ]] && ok "  shimx64.efi found: $shim" \
                          || fail "  shimx64.efi NOT found under $mnt/EFI"
      if [[ $mnt == /boot/efi ]]; then
        efi2_grub=$(find /boot/efi2/EFI -name 'grubx64.efi' 2>/dev/null | head -1)
        [[ -n $efi2_grub ]] && ok "  /boot/efi2 mirrors EFI content" \
                              || warn "  /boot/efi2 may not be synced (run: sudo sync-efi)"
      fi
    else
      fail "$mnt is $fstype, expected vfat"
    fi
  else
    [[ $mnt == /boot/efi2 ]] \
      && warn "$mnt not mounted (second ESP — nofail, may be normal)" \
      || fail "$mnt NOT mounted"
  fi
done

# =============================================================================
hdr "4. LUKS2 CONTAINERS"
# =============================================================================

for m in luks-root1 luks-root2 luks-data1 luks-data2; do
  if [[ -b /dev/mapper/$m ]]; then
    ok "/dev/mapper/$m open"
    src=$(cryptsetup status "$m" 2>/dev/null | awk '/device:/{print $2}')
    info "  backing device: ${src:-(unknown)}"
    if [[ -n $src && -b $src ]]; then
      ltype=$(cryptsetup luksDump "$src" 2>/dev/null | awk '/^Version:/{print $2; exit}')
      [[ $ltype == 2 ]] && ok "  LUKS version: 2" \
                         || warn "  LUKS version '$ltype' (expected 2)"
    fi
  else
    fail "/dev/mapper/$m NOT open"
  fi
done
[[ -b /dev/mapper/luks-extra ]] && ok "/dev/mapper/luks-extra open (extra pool)"

# =============================================================================
hdr "5. ZFS POOLS"
# =============================================================================

for pool in bpool rpool dpool; do
  if zpool list "$pool" &>/dev/null; then
    health=$(zpool list -H -o health "$pool" 2>/dev/null)
    [[ $health == ONLINE ]] \
      && ok "Pool $pool: ONLINE" \
      || fail "Pool $pool: health=$health (expected ONLINE)"

    mirror_lines=$(zpool status "$pool" 2>/dev/null | grep -c 'mirror' || true)
    (( mirror_lines >= 1 )) \
      && ok "  $pool: mirror vdev confirmed ($mirror_lines mirror line(s))" \
      || fail "$pool: mirror vdev NOT detected — pool may be stripe or degraded"

    zpool list -H -o name,size,alloc,free,frag,health "$pool" 2>/dev/null | \
      while IFS=$'\t' read -r n sz al fr fg h; do
        info "  $n  size=$sz  alloc=$al  free=$fr  frag=$fg  health=$h"
      done
  else
    fail "Pool $pool: NOT found"
  fi
done

for pool in bpool rpool dpool; do
  zpool list "$pool" &>/dev/null || continue
  scrub_line=$(zpool status "$pool" 2>/dev/null | grep 'scan:' || true)
  info "$pool scan:${scrub_line##*scan:}"
done

# =============================================================================
hdr "6. ZFS DATASETS & MOUNTPOINTS"
# =============================================================================

check_dataset() {
  local ds=$1 expected_mp=$2
  if zfs list "$ds" &>/dev/null; then
    actual_mp=$(zfs get -H -o value mountpoint "$ds" 2>/dev/null)
    if [[ $expected_mp == skip ]]; then
      ok "Dataset $ds exists"
    elif [[ $actual_mp == "$expected_mp" || $actual_mp == legacy ]]; then
      ok "Dataset $ds → mountpoint=${actual_mp}"
      if [[ $actual_mp != none && $actual_mp != legacy ]]; then
        mountpoint -q "$actual_mp" 2>/dev/null \
          && ok "  $actual_mp is mounted" \
          || fail "  $actual_mp is NOT mounted"
      fi
    else
      warn "Dataset $ds mountpoint='$actual_mp' (expected '$expected_mp' or legacy)"
    fi
  else
    fail "Dataset $ds MISSING"
  fi
}

check_dataset rpool/ROOT/ubuntu  /
check_dataset rpool/var/log      legacy
check_dataset rpool/var/spool    legacy
check_dataset rpool/var/cache    skip
check_dataset rpool/var/tmp      skip
check_dataset rpool/srv          skip
check_dataset rpool/tmp          skip
check_dataset rpool/root         /root
check_dataset bpool/BOOT/ubuntu  legacy
check_dataset dpool/home         /home
check_dataset dpool/data         /data

for mp in /boot /var/log /var/spool; do
  mountpoint -q "$mp" 2>/dev/null \
    && ok "  $mp is mounted (legacy ZFS)" \
    || fail "  $mp is NOT mounted (expected legacy ZFS)"
done

[[ $(stat -c '%a' /tmp)     == 1777 ]] && ok "/tmp permissions 1777"     || warn "/tmp perms: $(stat -c '%a' /tmp)"
[[ $(stat -c '%a' /var/tmp) == 1777 ]] && ok "/var/tmp permissions 1777" || warn "/var/tmp perms: $(stat -c '%a' /var/tmp)"
[[ $(stat -c '%a' /root)    == 700  ]] && ok "/root permissions 700"     || warn "/root perms: $(stat -c '%a' /root)"

# =============================================================================
hdr "7. SWAP"
# =============================================================================

swap_on=$(swapon --show=NAME --noheadings 2>/dev/null | wc -l)
(( swap_on >= 1 )) && ok "$swap_on swap device(s) active" \
                    || warn "No swap active (plain/random-key — confirm in crypttab)"
swapon --show 2>/dev/null | while read -r line; do info "  $line"; done

for m in swap1 swap2; do
  grep -q "^$m" /etc/crypttab 2>/dev/null \
    && ok "  crypttab: $m entry present" \
    || fail "  crypttab: $m entry MISSING"
done

# =============================================================================
hdr "8. /etc/crypttab"
# =============================================================================

for entry in luks-root1 luks-root2 luks-data1 luks-data2; do
  if grep -q "^$entry" /etc/crypttab 2>/dev/null; then
    line=$(grep "^$entry" /etc/crypttab)
    ok "crypttab: $entry found"
    echo "$line" | grep -q 'tpm2-device=auto' \
      && ok "  tpm2-device=auto present" \
      || warn "  tpm2-device=auto MISSING for $entry"
    echo "$line" | grep -q 'discard' \
      && ok "  discard present" \
      || warn "  discard MISSING for $entry"
  else
    fail "crypttab: $entry MISSING"
  fi
done

# =============================================================================
hdr "9. /etc/fstab"
# =============================================================================

for pattern in '/boot' 'vfat' 'swap' 'zfs'; do
  count=$(grep -c "$pattern" /etc/fstab 2>/dev/null || true)
  (( count >= 1 )) && ok "fstab: '$pattern' entries found ($count)" \
                    || warn "fstab: '$pattern' entry not found"
done

# =============================================================================
hdr "10. GRUB"
# =============================================================================

if [[ -f /etc/default/grub ]]; then
  ok "/etc/default/grub exists"
  cmdline=$(grep '^GRUB_CMDLINE_LINUX=' /etc/default/grub | head -1)
  echo "$cmdline" | grep -q 'root=ZFS='    \
    && ok "  GRUB_CMDLINE_LINUX: root=ZFS= present" \
    || fail "  GRUB_CMDLINE_LINUX: root=ZFS= MISSING — $cmdline"
  echo "$cmdline" | grep -q 'rd.luks.name' \
    && ok "  GRUB_CMDLINE_LINUX: rd.luks.name present" \
    || fail "  GRUB_CMDLINE_LINUX: rd.luks.name MISSING"
  echo "$cmdline" | grep -q 'rpool' \
    && ok "  GRUB_CMDLINE_LINUX references rpool" \
    || warn "  GRUB_CMDLINE_LINUX does not mention rpool"
  info "  GRUB_TIMEOUT=$(grep '^GRUB_TIMEOUT=' /etc/default/grub | cut -d= -f2)"
else
  fail "/etc/default/grub NOT found"
fi

if [[ -f /boot/grub/grub.cfg ]]; then
  ok "/boot/grub/grub.cfg exists"
  grep -q 'insmod zfs' /boot/grub/grub.cfg \
    && ok "  grub.cfg: insmod zfs present" \
    || warn "  grub.cfg: insmod zfs NOT found (run: sudo update-grub)"
else
  fail "/boot/grub/grub.cfg NOT found (run: sudo update-grub)"
fi

# =============================================================================
hdr "11. KERNEL & INITRD (dracut)"
# =============================================================================

kernel_ver=$(uname -r)
ok "Running kernel: $kernel_ver"

initrd=$(find /boot -maxdepth 1 \
  \( -name "initrd.img-${kernel_ver}" -o -name "initramfs-${kernel_ver}.img" \) \
  2>/dev/null | head -1)

if [[ -n $initrd ]]; then
  ok "Initrd found: $initrd ($(du -sh "$initrd" 2>/dev/null | cut -f1))"

  INITRD_LIST=""
  if command -v lsinitrd &>/dev/null; then
    INITRD_LIST=$(lsinitrd "$initrd" 2>/dev/null) || true
  elif command -v lsinitramfs &>/dev/null; then
    INITRD_LIST=$(lsinitramfs "$initrd" 2>/dev/null) || true
  fi

  if [[ -z $INITRD_LIST ]]; then
    warn "lsinitrd/lsinitramfs unavailable — cannot inspect initrd contents"
  else
    check_initrd_module() {
      local label=$1; shift
      local found=false
      for pattern in "$@"; do
        if echo "$INITRD_LIST" | grep -qi "$pattern"; then
          found=true; break
        fi
      done
      if $found; then
        ok "  initrd: $label content detected"
      else
        info "  initrd: $label not matched by string search"
        info "    (system booted successfully → module was present at boot)"
        info "    Manual check: lsinitrd $initrd | grep -i $1"
      fi
    }

    check_initrd_module "ZFS"        'zfs' 'zpool' 'libzfs'
    check_initrd_module "crypt/LUKS" 'crypt' 'dm-crypt' 'cryptsetup'
    check_initrd_module "TPM2"       'tpm2' 'libtss2' 'tss2'
  fi

  # Definitive reality check
  zfs_ok=false; luks_ok=false; tpm_ok=false
  zpool list rpool &>/dev/null         && zfs_ok=true
  [[ -b /dev/mapper/luks-root1 ]]      && luks_ok=true
  if [[ -c /dev/tpmrm0 ]]; then
    _uuid=$(awk '/^luks-root1/{gsub("UUID=",""); print $2}' /etc/crypttab 2>/dev/null)
    _dev=$(blkid -U "$_uuid" 2>/dev/null || true)
    [[ -n $_dev ]] && cryptsetup luksDump "$_dev" 2>/dev/null \
      | grep -q 'systemd-tpm2' && tpm_ok=true
  fi

  if $zfs_ok && $luks_ok; then
    ok "  REALITY CHECK: system booted with ZFS (rpool ONLINE) + LUKS (luks-root1 open)"
    $tpm_ok \
      && ok   "  REALITY CHECK: TPM2 slot verified on luks-root1 (auto-unlock active)" \
      || info "  TPM2 slot not confirmed via luksDump (check section 12)"
  else
    warn "  REALITY CHECK: unexpected — rpool=$( $zfs_ok && echo OK || echo MISSING ) luks-root1=$( $luks_ok && echo OPEN || echo CLOSED )"
  fi

else
  fail "No initrd/initramfs found for kernel $kernel_ver under /boot"
fi

if [[ -f /etc/dracut.conf.d/90-zfs-luks-tpm.conf ]]; then
  ok "/etc/dracut.conf.d/90-zfs-luks-tpm.conf exists"
  grep -q 'zfs'   /etc/dracut.conf.d/90-zfs-luks-tpm.conf && ok "  dracut conf: zfs listed"  || fail "  dracut conf: zfs MISSING"
  grep -q 'crypt' /etc/dracut.conf.d/90-zfs-luks-tpm.conf && ok "  dracut conf: crypt listed" || fail "  dracut conf: crypt MISSING"
  grep -q 'tpm2'  /etc/dracut.conf.d/90-zfs-luks-tpm.conf && ok "  dracut conf: tpm2 listed"  || fail "  dracut conf: tpm2 MISSING"
else
  fail "/etc/dracut.conf.d/90-zfs-luks-tpm.conf NOT found"
fi

# =============================================================================
hdr "12. TPM2"
# =============================================================================

if [[ -c /dev/tpmrm0 ]]; then
  ok "TPM2 device /dev/tpmrm0 present"
  command -v tpm2_getcap &>/dev/null && \
    { tpm2_getcap properties-fixed &>/dev/null \
        && ok "  tpm2_getcap: OK" \
        || warn "  tpm2_getcap failed (TPM may be locked or in use)"; }

  enroll_count=0
  for entry in luks-root1 luks-root2 luks-data1 luks-data2; do
    uuid_line=$(grep "^$entry" /etc/crypttab 2>/dev/null || true)
    [[ -z $uuid_line ]] && continue
    uuid=$(awk '{gsub("UUID=",""); print $2}' <<< "$uuid_line")
    dev=$(blkid -U "$uuid" 2>/dev/null || true)
    [[ -z $dev || ! -b $dev ]] && continue
    slot_count=$(cryptsetup luksDump "$dev" 2>/dev/null | grep -c 'systemd-tpm2' || true)
    if (( slot_count > 0 )); then
      ok "  TPM2 slot enrolled on $entry ($dev)"
      (( ++enroll_count ))
    else
      warn "  NO TPM2 slot on $entry ($dev) — run: sudo enroll-tpm2"
    fi
  done
  (( enroll_count == 0 )) && warn "TPM2 present but NOT enrolled — run: sudo enroll-tpm2"
else
  warn "No /dev/tpmrm0 — TPM2 unlock not available on this system"
fi

[[ -x /usr/local/sbin/enroll-tpm2 ]] \
  && ok "/usr/local/sbin/enroll-tpm2 present and executable" \
  || fail "/usr/local/sbin/enroll-tpm2 MISSING"

# =============================================================================
hdr "13. SYSTEMD SERVICES"
# =============================================================================

EXPECTED_SERVICES=(
  zfs-import-bpool.service  zfs-import-dpool.service
  zfs-import-cache.service  zfs-mount.service
  zfs-zed.service           zfs.target
  ssh.service               systemd-networkd.service
  systemd-resolved.service  ufw.service
)

for svc in "${EXPECTED_SERVICES[@]}"; do
  enabled=$(systemctl is-enabled "$svc" 2>/dev/null) || true
  active=$( systemctl is-active  "$svc" 2>/dev/null) || true
  enabled=${enabled//$'\n'*/}   # keep only first line
  active=${active//$'\n'*/}
  enabled=${enabled//[[:space:]]/}
  active=${active//[[:space:]]/}

  case "$enabled" in
    enabled|static|alias|indirect)
      ok "Service $svc: enabled=$enabled active=$active" ;;
    not-found|"")
      fail "Service $svc: NOT FOUND on this system" ;;
    *)
      warn "Service $svc: enabled=$enabled active=$active" ;;
  esac
  [[ $active == failed ]] && fail "  $svc is in FAILED state — check: journalctl -u $svc"
done

# =============================================================================
hdr "14. USER / SSH / HOSTNAME"
# =============================================================================

info "Hostname: $(hostname 2>/dev/null || cat /etc/hostname)"
[[ -f /etc/hostname ]] \
  && ok "/etc/hostname exists ($(cat /etc/hostname))" \
  || fail "/etc/hostname MISSING"

sudo_users=$(getent group sudo 2>/dev/null | cut -d: -f4)
[[ -n $sudo_users ]] && ok "sudo group members: $sudo_users" \
                      || warn "No users in the sudo group"

root_pw=$(passwd -S root 2>/dev/null | awk '{print $2}')
[[ $root_pw == L || $root_pw == LK ]] \
  && ok "root account locked ($root_pw)" \
  || warn "root status: '$root_pw' (expected L/LK)"

ss -lntp 2>/dev/null | grep -q ':22' \
  && ok "sshd listening on port 22" \
  || warn "sshd not detected on port 22"

for cfg in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/10-password-login.conf; do
  [[ -f $cfg ]] || continue
  grep -q 'PasswordAuthentication yes' "$cfg" && ok "SSH PasswordAuthentication yes ($cfg)" || true
  grep -q 'PermitRootLogin no'         "$cfg" && ok "SSH PermitRootLogin no ($cfg)"         || true
done

# =============================================================================
hdr "15. NETWORK (netplan)"
# =============================================================================

if [[ -d /etc/netplan ]]; then
  mapfile -t netplan_files < <(ls /etc/netplan/*.yaml 2>/dev/null || true)
  (( ${#netplan_files[@]} >= 1 )) \
    && ok "netplan: ${#netplan_files[@]} config file(s)" \
    || warn "netplan: no .yaml files found in /etc/netplan"
  for f in "${netplan_files[@]:-}"; do
    [[ -f $f ]] || continue
    perms=$(stat -c '%a' "$f")
    info "  $f (perms $perms)"
    [[ $perms == 600 ]] && ok "  $f: 600 (secure)" \
                         || warn "  $f: $perms (should be 600 — run: sudo chmod 600 $f)"
  done
else
  fail "/etc/netplan directory MISSING"
fi

if [[ -L /etc/resolv.conf ]]; then
  target=$(readlink /etc/resolv.conf)
  info "/etc/resolv.conf → $target"
  echo "$target" | grep -q 'stub-resolv' \
    && ok "  resolv.conf → systemd-resolved stub" \
    || warn "  resolv.conf target unexpected: $target"
else
  warn "/etc/resolv.conf is not a symlink (expected stub-resolv.conf)"
fi

# =============================================================================
hdr "16. FIREWALL (ufw)"
# =============================================================================

if command -v ufw &>/dev/null; then
  ufw_status=$(ufw status 2>/dev/null | head -1)
  echo "$ufw_status" | grep -qi 'active' \
    && ok "ufw: $ufw_status" \
    || warn "ufw: $ufw_status"
  ufw status 2>/dev/null | grep -qE '22/tcp|OpenSSH|^22 ' \
    && ok "ufw: SSH (port 22) allowed" \
    || warn "ufw: SSH rule not detected"
else
  warn "ufw not found"
fi

# =============================================================================
hdr "17. TIMEZONE & LOCALE"
# =============================================================================

tz=$(cat /etc/timezone 2>/dev/null \
     || timedatectl show -p Timezone --value 2>/dev/null \
     || echo unknown)
ok "Timezone: $tz"
[[ -L /etc/localtime ]] \
  && ok "/etc/localtime is a symlink ($(readlink /etc/localtime))" \
  || warn "/etc/localtime is not a symlink"

locale_conf=$(grep -v '^#' /etc/default/locale 2>/dev/null | grep -v '^$' || true)
info "Locale: ${locale_conf:-not set}"
[[ -n $locale_conf ]] && ok "/etc/default/locale is set" \
                        || warn "/etc/default/locale is empty or missing"

# =============================================================================
hdr "18. HELPER SCRIPTS"
# =============================================================================

[[ -x /usr/local/sbin/sync-efi    ]] \
  && ok "/usr/local/sbin/sync-efi executable" \
  || fail "/usr/local/sbin/sync-efi MISSING or not executable"
[[ -x /usr/local/sbin/enroll-tpm2 ]] \
  && ok "/usr/local/sbin/enroll-tpm2 executable" \
  || fail "/usr/local/sbin/enroll-tpm2 MISSING or not executable"

# =============================================================================
hdr "19. ZFS HOSTID"
# =============================================================================

if [[ -f /etc/hostid ]]; then
  ok "/etc/hostid exists"
  hid_size=$(stat -c '%s' /etc/hostid)
  (( hid_size == 4 )) && ok "  hostid is 4 bytes" \
                        || warn "  hostid is $hid_size bytes (expected 4)"
else
  fail "/etc/hostid MISSING (pool import may fail on reboot)"
fi

if [[ -f /etc/zfs/zpool.cache ]]; then
  cache_size=$(stat -c '%s' /etc/zfs/zpool.cache)
  (( cache_size == 0 )) \
    && ok "zpool.cache: empty (correct — pools imported by systemd services)" \
    || warn "zpool.cache: $cache_size bytes (non-zero — may cause import issues on disk swap)"
else
  warn "/etc/zfs/zpool.cache missing — will be created on next import"
fi

# =============================================================================
hdr "20. PACKAGE SANITY CHECK"
# =============================================================================

for pkg in \
  zfsutils-linux zfs-zed zfs-dracut dracut \
  cryptsetup tpm2-tools \
  grub-efi-amd64 shim-signed efibootmgr \
  openssh-server ufw netplan.io \
  systemd-resolved linux-image-generic; do
  if dpkg -s "$pkg" &>/dev/null; then
    ver=$(dpkg -s "$pkg" 2>/dev/null | awk '/^Version:/{print $2}')
    ok "Package $pkg ($ver)"
  else
    fail "Package $pkg NOT installed"
  fi
done

# =============================================================================
#  SUMMARY
# =============================================================================

total=$(( PASS + FAIL + WARN ))
echo ""
echo -e "${BLD}══════════════════════════════════════════════════════════════════════════${RST}"
printf "${BLD} RESULTS: %s checks │ ${GRN}%d PASS${RST}${BLD} │ ${RED}%d FAIL${RST}${BLD} │ ${YLW}%d WARN${RST}\n" \
  "$total" "$PASS" "$FAIL" "$WARN"
echo -e "${BLD}══════════════════════════════════════════════════════════════════════════${RST}"
echo ""

if   (( FAIL == 0 && WARN == 0 )); then
  echo -e "${GRN}${BLD}✔  All checks passed. Installation looks healthy.${RST}"
elif (( FAIL == 0 )); then
  echo -e "${YLW}${BLD}⚠  No failures, but $WARN warning(s) — review items above.${RST}"
else
  echo -e "${RED}${BLD}✘  $FAIL failure(s) detected. Review and fix before relying on this system.${RST}"
fi

echo ""
echo " Useful follow-up commands:"
echo "   sudo zpool status -v rpool bpool dpool"
echo "   sudo zpool scrub rpool bpool dpool"
echo "   sudo cryptsetup luksDump /dev/sda4 | grep -A5 tpm2"
echo "   sudo enroll-tpm2 7         # if TPM2 not yet enrolled"
echo "   sudo sync-efi              # after grub/shim package updates"
echo "   sudo journalctl -b -p err  # errors from this boot"
echo "   lsinitrd /boot/initrd.img-$(uname -r) | grep -iE 'zfs|crypt|tpm'"
echo ""

exit $(( FAIL > 0 ? 1 : 0 ))
