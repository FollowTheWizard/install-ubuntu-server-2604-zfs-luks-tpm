#!/usr/bin/env bash
# Ubuntu Server 26.04: mirrored mdraid /boot and LUKS2+LVM+ext4 root,
# plus a LUKS2-backed ZFS mirror for data. Secure Boot must stay enabled.
# This installer destroys both selected disks. Hardware validation is required.
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
trap 'rc=$?; printf "Installer failed at line %s (status %s).\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR

SUITE=resolute
MIRROR=https://archive.ubuntu.com/ubuntu
SECURITY_MIRROR=https://security.ubuntu.com/ubuntu
TARGET=/mnt
EFI_MB=1024
BOOT_MB=2048
ROOT_MB=65536
MIN_DATA_MB=8192
MIN_DISK_MB=$(( EFI_MB + BOOT_MB + ROOT_MB + MIN_DATA_MB + 16 ))
POOL=dpool

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
hr() { printf '%*s\n' 78 '' | tr ' ' '-'; }
ask() {
  local answer
  read -r -p "$1 [$2]: " answer
  printf '%s' "${answer:-$2}"
}
ask_secret() {
  local answer repeat
  while :; do
    read -r -s -p "$1: " answer; printf '\n'
    read -r -s -p "Repeat: " repeat; printf '\n'
    [[ $answer == "$repeat" ]] || { echo "Passwords did not match."; continue; }
    (( ${#answer} >= $2 )) || { echo "Use at least $2 characters."; continue; }
    [[ $answer != *$'\n'* && $answer != *:* ]] || { echo "Newlines and ':' are not supported."; continue; }
    REPLY=$answer
    return
  done
}

[[ $EUID -eq 0 ]] || die "Run as root."
[[ -d /sys/firmware/efi ]] || die "Boot the Ubuntu Server live installer in UEFI mode."
[[ $(dpkg --print-architecture) == amd64 ]] || die "This installer currently supports amd64 only."

secure_boot_state() {
  local efivar value
  for efivar in /sys/firmware/efi/efivars/SecureBoot-*; do
    [[ -e $efivar ]] || continue
    value=$(od -An -t u1 -j4 -N1 "$efivar" 2>/dev/null | tr -d '[:space:]') || return 2
    [[ $value == 1 ]] && return 0
    [[ $value == 0 ]] && return 1
  done
  return 2
}
if secure_boot_state; then
  :
else
  rc=$?
  (( rc == 1 )) && die "Secure Boot is disabled. Enable it and reboot the live installer before continuing."
  die "Cannot determine Secure Boot state from UEFI variables; refusing to continue."
fi

part() {
  local disk=$1 number=$2
  if [[ $disk == /dev/disk/by-id/* ]]; then
    printf '%s-part%s' "$disk" "$number"
  elif [[ $disk =~ [0-9]$ ]]; then
    printf '%sp%s' "$disk" "$number"
  else
    printf '%s%s' "$disk" "$number"
  fi
}
stable_id() {
  local device real link
  device=$1
  real=$(readlink -f "$device")
  for link in /dev/disk/by-id/*; do
    [[ $link == *-part* ]] && continue
    [[ -e $link && $(readlink -f "$link") == "$real" ]] && { printf '%s' "$link"; return; }
  done
  printf '%s' "$device"
}
disk_size_mib() { echo $(( $(blockdev --getsize64 "$1") / 1048576 )); }

collect_holders() {
  local dev_path=$1
  local real_dev base holder
  real_dev=$(readlink -f "$dev_path" 2>/dev/null) || return 0
  base=$(basename "$real_dev")
  for holder in /sys/class/block/"$base"/holders/*; do
    [[ -e $holder ]] || continue
    printf '%s\n' "$(basename "$holder")"
    collect_holders "/dev/$(basename "$holder")"
  done
}

release_holders() {
  local dev_path=$1
  local real_dev base holder holder_base holder_dev dm_name vg_name
  real_dev=$(readlink -f "$dev_path" 2>/dev/null) || return 0
  base=$(basename "$real_dev")
  for holder in /sys/class/block/"$base"/holders/*; do
    [[ -e $holder ]] || continue
    holder_base=$(basename "$holder")
    holder_dev="/dev/$holder_base"
    release_holders "$holder_dev"
    swapoff "$holder_dev" 2>/dev/null || true
    if [[ $holder_base == dm-* ]]; then
      dm_name=$(dmsetup info -c --noheadings -o name "$holder_dev" 2>/dev/null || true)
      vg_name=$(lvs --noheadings -o vg_name "$holder_dev" 2>/dev/null | tr -d '[:space:]' || true)
      if [[ -n $vg_name ]]; then
        vgchange -an "$vg_name" 2>/dev/null || true
      fi
      if [[ -n $dm_name ]]; then
        cryptsetup close "$dm_name" 2>/dev/null || dmsetup remove --force "$dm_name" 2>/dev/null || true
      fi
    elif [[ $holder_base == md* ]]; then
      mdadm --stop "$holder_dev" 2>/dev/null || true
    fi
  done
}

teardown_selected_disks() {
  local disk dev
  if mountpoint -q "$TARGET" || findmnt -rn -o TARGET | grep -qE "^${TARGET}(/|$)"; then
    umount -R "$TARGET" 2>/dev/null || umount -l "$TARGET" 2>/dev/null || true
  fi
  for disk in "$@"; do
    while IFS= read -r dev; do
      [[ -n $dev ]] || continue
      swapoff "$dev" 2>/dev/null || true
    done < <(lsblk -nrpo NAME "$disk")
  done
  if command -v zpool >/dev/null 2>&1; then
    while IFS= read -r pool; do
      [[ -n $pool ]] || continue
      zpool export -f "$pool" 2>/dev/null || true
    done < <(zpool list -H -o name 2>/dev/null || true)
  fi
  for disk in "$@"; do
    while IFS= read -r dev; do
      [[ -n $dev ]] || continue
      release_holders "$dev"
    done < <(lsblk -nrpo NAME "$disk")
  done
  udevadm settle
}

print_eligible_disks() {
  local index disk size_str model_str
  for index in "${!ELIGIBLE[@]}"; do
    disk=${ELIGIBLE[$index]}
    size_str=$(lsblk -dno SIZE "$disk" 2>/dev/null | tr -d '[:space:]' || echo "?")
    model_str=$(lsblk -dno MODEL "$disk" 2>/dev/null | tr -s ' ' | sed 's/^ //;s/ $//' || true)
    [[ -n $model_str ]] || model_str="Unknown model"
    printf '  [%2d]   %-14s %8s  %-24s %s\n' \
      "$((index+1))" "$disk" "$size_str" "$model_str" "$(stable_id "$disk")"
  done
}

hr
echo "Scanning block devices (minimum required size per disk: ${MIN_DISK_MB} MiB)..."
mapfile -t DISKS < <(lsblk -dpno NAME,TYPE | awk '$2 == "disk" {print $1}' \
  | grep -vE '/dev/(loop|sr|zram|fd|ram)' || true)

ELIGIBLE=()
SKIPPED_COUNT=0
for disk in "${DISKS[@]}"; do
  size_str=$(lsblk -dno SIZE "$disk" 2>/dev/null | tr -d '[:space:]' || echo "?")
  model_str=$(lsblk -dno MODEL "$disk" 2>/dev/null | tr -s ' ' | sed 's/^ //;s/ $//' || true)
  [[ -n $model_str ]] || model_str="Unknown model"

  system_mounts=$(lsblk -nrpo MOUNTPOINT "$disk" | grep -E '^/' | grep -vE "^${TARGET}(/|$)" | paste -sd ', ' - || true)
  if [[ -n $system_mounts ]]; then
    printf '  [SKIP] %-14s %8s  %-24s (in use: %s)\n' "$disk" "$size_str" "$model_str" "$system_mounts"
    SKIPPED_COUNT=$(( SKIPPED_COUNT + 1 ))
    continue
  fi

  size_mib=$(disk_size_mib "$disk")
  if (( size_mib < MIN_DISK_MB )); then
    printf '  [SKIP] %-14s %8s  %-24s (too small: %s MiB < %s MiB)\n' \
      "$disk" "$size_str" "$model_str" "$size_mib" "$MIN_DISK_MB"
    SKIPPED_COUNT=$(( SKIPPED_COUNT + 1 ))
    continue
  fi

  notes=()
  target_mounts=$(lsblk -nrpo MOUNTPOINT "$disk" | grep -E "^${TARGET}(/|$)" | paste -sd ',' - || true)
  [[ -n $target_mounts ]] && notes+=("mounted:$target_mounts")
  lsblk -nrpo MOUNTPOINT "$disk" | grep -Fxq '[SWAP]' && notes+=("swap")
  mapfile -t existing_holders < <(
    while IFS= read -r child; do
      [[ -n $child ]] || continue
      collect_holders "$child"
    done < <(lsblk -nrpo NAME "$disk") | sort -u
  )
  (( ${#existing_holders[@]} > 0 )) && notes+=("holders:${existing_holders[*]}")

  note_str=""
  (( ${#notes[@]} > 0 )) && note_str=" [existing: ${notes[*]}]"

  ELIGIBLE+=("$disk")
  printf '  [%2d]   %-14s %8s  %-24s %s%s\n' \
    "${#ELIGIBLE[@]}" "$disk" "$size_str" "$model_str" "$(stable_id "$disk")" "$note_str"
done

if (( ${#ELIGIBLE[@]} < 2 )); then
  cat >&2 <<EOF

ERROR: Found ${#ELIGIBLE[@]} eligible target disk(s) (2 required; ${SKIPPED_COUNT} skipped).
Possible causes:
  - Only one physical drive is connected or enabled in UEFI/BIOS (check SATA/M.2 cables and AHCI mode).
  - One of the drives is smaller than the minimum ${MIN_DISK_MB} MiB layout requirement.
EOF
  exit 1
fi

hr
echo "Install tools and confirm the signed ZFS module can load with Secure Boot enabled."
apt-get update
DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get install -y --no-install-recommends \
  debootstrap gdisk mdadm lvm2 cryptsetup zfsutils-linux \
  dosfstools efibootmgr rsync util-linux
modprobe zfs || die "The Ubuntu-signed ZFS module could not load with Secure Boot enabled; no target disks have been changed."

hr
echo "Eligible target disks:"
print_eligible_disks

pick_disk() {
  local number
  while :; do
    read -r -p "$1: " number
    if [[ $number =~ ^[0-9]+$ ]] && (( number >= 1 && number <= ${#ELIGIBLE[@]} )); then
      printf '%s' "${ELIGIBLE[$((number-1))]}"
      return
    fi
    echo "Enter a number from 1 to ${#ELIGIBLE[@]}."
  done
}

DISK1=$(stable_id "$(pick_disk 'First OS/ZFS disk number')")
while :; do
  DISK2=$(stable_id "$(pick_disk 'Second OS/ZFS disk number')")
  [[ $(readlink -f "$DISK1") != "$(readlink -f "$DISK2")" ]] && break
  echo "Choose a different second disk."
done
SIZE1=$(disk_size_mib "$DISK1")
SIZE2=$(disk_size_mib "$DISK2")
DATA1_MB=$(( SIZE1 - EFI_MB - BOOT_MB - ROOT_MB - 16 ))
DATA2_MB=$(( SIZE2 - EFI_MB - BOOT_MB - ROOT_MB - 16 ))
(( DATA1_MB >= MIN_DATA_MB && DATA2_MB >= MIN_DATA_MB )) \
  || die "Each disk must be large enough for EFI, /boot, a 64 GiB root mirror, and at least 8 GiB of ZFS data."

NEW_HOSTNAME=$(ask "Hostname" ubuntu-server)
[[ $NEW_HOSTNAME =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,62}$ ]] || die "Invalid hostname."
while :; do
  NEW_USER=$(ask "Administrator username" admin)
  [[ $NEW_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && break
  echo "Invalid username."
done
ask_secret "Password for $NEW_USER" 10
USER_PASSWORD=$REPLY
ask_secret "LUKS2 passphrase for root and the ZFS mirror (kept as recovery fallback)" 12
LUKS_PASSWORD=$REPLY

hr
cat <<EOF
Ubuntu 26.04 ($SUITE) — Secure Boot remains enabled
  Disk 1: $DISK1 ($SIZE1 MiB)
  Disk 2: $DISK2 ($SIZE2 MiB)
  Per disk: ${EFI_MB} MiB EFI | ${BOOT_MB} MiB /boot RAID1 | ${ROOT_MB} MiB root RAID1 | remaining LUKS2 ZFS member
  Root: 64 GiB mdraid1 -> LUKS2 -> LVM -> approximately 60 GiB ext4 root + 4 GiB encrypted swap
  Data: two LUKS2 devices -> mirrored ZFS pool $POOL (usable size limited by smaller disk)
  TPM2: enrollment is deferred until the installed system boots; root and data passphrase slots remain
  Disk size difference: unused ZFS-member capacity on the larger disk is not allocated elsewhere

ALL DATA AND EXISTING ARRAYS/VOLUMES ON BOTH DISKS WILL BE DESTROYED.
EOF
hr
read -r -p "Type YES to erase both disks and install: " confirmation
[[ $confirmation == YES ]] || { echo "Aborted."; exit 0; }

for disk in "$DISK1" "$DISK2"; do
  [[ -b $disk ]] || die "Target is no longer a block device: $disk"
  if lsblk -nrpo MOUNTPOINT "$disk" | grep -E '^/' | grep -vqE "^${TARGET}(/|$)"; then
    die "$disk or one of its partitions has an active system mount; refusing to erase it."
  fi
done

echo "Deactivating any existing arrays, volumes, or mounts on selected disks..."
teardown_selected_disks "$DISK1" "$DISK2"

for disk in "$DISK1" "$DISK2"; do
  if lsblk -nrpo MOUNTPOINT "$disk" | grep -qE '^(/|\[SWAP\])'; then
    die "$disk or one of its partitions could not be unmounted; refusing to erase it."
  fi
  mapfile -t CHILDREN < <(lsblk -nrpo NAME "$disk")
  for child in "${CHILDREN[@]}"; do
    holders=(/sys/class/block/"$(basename "$(readlink -f "$child")")"/holders/*)
    [[ ! -e ${holders[0]:-} ]] || die "$child still has active holders; refusing to erase it."
  done
done

hr
echo "Partition and format target disks."
for disk in "$DISK1" "$DISK2"; do
  while IFS= read -r dev; do
    [[ -n $dev && $(readlink -f "$dev") != "$(readlink -f "$disk")" ]] || continue
    wipefs -af "$dev" 2>/dev/null || true
  done < <(lsblk -nrpo NAME "$disk")
  partx -d "$disk" 2>/dev/null || true
  wipefs -af "$disk"
  sgdisk --zap-all "$disk"
  partprobe "$disk" 2>/dev/null || true
  udevadm settle

  sgdisk -n1:1M:+${EFI_MB}M  -t1:EF00 -c1:EFI "$disk"
  sgdisk -n2:0:+${BOOT_MB}M -t2:FD00 -c2:boot-raid "$disk"
  sgdisk -n3:0:+${ROOT_MB}M -t3:FD00 -c3:root-raid "$disk"
  sgdisk -n4:0:0            -t4:8309 -c4:zfs-luks "$disk"
  partprobe "$disk"
done
udevadm settle

ESP1=$(part "$DISK1" 1); ESP2=$(part "$DISK2" 1)
BOOT1=$(part "$DISK1" 2); BOOT2=$(part "$DISK2" 2)
ROOT1=$(part "$DISK1" 3); ROOT2=$(part "$DISK2" 3)
ZFS1=$(part "$DISK1" 4); ZFS2=$(part "$DISK2" 4)
for device in "$ESP1" "$ESP2" "$BOOT1" "$BOOT2" "$ROOT1" "$ROOT2" "$ZFS1" "$ZFS2"; do
  [[ -b $device ]] || die "Partition did not appear: $device"
done

# Stop any mdraid arrays udev auto-assembled upon partition creation before wiping signatures
teardown_selected_disks "$DISK1" "$DISK2"
wipefs -af "$ESP1" "$ESP2" "$BOOT1" "$BOOT2" "$ROOT1" "$ROOT2" "$ZFS1" "$ZFS2"
udevadm settle

mkfs.vfat -F32 -n EFI1 "$ESP1"
mkfs.vfat -F32 -n EFI2 "$ESP2"
mdadm --create /dev/md0 --run --metadata=1.0 --level=1 --raid-devices=2 "$BOOT1" "$BOOT2"
mdadm --create /dev/md1 --run --metadata=1.2 --level=1 --raid-devices=2 "$ROOT1" "$ROOT2"
udevadm settle
mkfs.ext4 -F -L ubuntu-boot /dev/md0

printf '%s' "$LUKS_PASSWORD" | cryptsetup luksFormat --batch-mode --type luks2 \
  --cipher aes-xts-plain64 --key-size 512 --pbkdf argon2id --key-file=- /dev/md1
printf '%s' "$LUKS_PASSWORD" | cryptsetup open --key-file=- /dev/md1 cryptroot
pvcreate /dev/mapper/cryptroot
vgcreate vgubuntu /dev/mapper/cryptroot
lvcreate -L 4G -n swap vgubuntu
lvcreate -l 100%FREE -n root vgubuntu
mkfs.ext4 -F -L ubuntu-root /dev/vgubuntu/root
mkswap -L ubuntu-swap /dev/vgubuntu/swap

luks_format_data() {
  printf '%s' "$LUKS_PASSWORD" | cryptsetup luksFormat --batch-mode --type luks2 \
    --cipher aes-xts-plain64 --key-size 512 --pbkdf argon2id --key-file=- "$1"
}
luks_format_data "$ZFS1"
luks_format_data "$ZFS2"
printf '%s' "$LUKS_PASSWORD" | cryptsetup open --key-file=- "$ZFS1" luks-zfs1
printf '%s' "$LUKS_PASSWORD" | cryptsetup open --key-file=- "$ZFS2" luks-zfs2

ROOT_LUKS_UUID=$(cryptsetup luksUUID /dev/md1)
ZFS_LUKS_UUID1=$(cryptsetup luksUUID "$ZFS1")
ZFS_LUKS_UUID2=$(cryptsetup luksUUID "$ZFS2")
MD_BOOT_UUID=$(blkid -s UUID -o value /dev/md0)
MD_BOOT_ID=$(mdadm --detail --export /dev/md0 | sed -n 's/^MD_UUID=//p')
MD_ROOT_ID=$(mdadm --detail --export /dev/md1 | sed -n 's/^MD_UUID=//p')
[[ -n $MD_BOOT_ID && -n $MD_ROOT_ID ]] || die "Could not read the new RAID UUIDs."

mkdir -p "$TARGET"
mount /dev/vgubuntu/root "$TARGET"
mkdir -p "$TARGET/boot" "$TARGET/data"
mount /dev/md0 "$TARGET/boot"
mkdir -p "$TARGET/boot/efi" "$TARGET/boot/efi2"
mount "$ESP1" "$TARGET/boot/efi"
mount "$ESP2" "$TARGET/boot/efi2"
debootstrap --arch=amd64 "$SUITE" "$TARGET" "$MIRROR"

mkdir -p "$TARGET/etc/mdadm" "$TARGET/etc/zfs"
cat > "$TARGET/etc/mdadm/mdadm.conf" <<EOF
HOMEHOST <system>
ARRAY /dev/md0 UUID=$MD_BOOT_ID
ARRAY /dev/md1 UUID=$MD_ROOT_ID
EOF
cat > "$TARGET/etc/crypttab" <<EOF
cryptroot UUID=$ROOT_LUKS_UUID none luks,tpm2-device=auto,x-initrd.attach
luks-zfs1 UUID=$ZFS_LUKS_UUID1 none luks,tpm2-device=auto,nofail,x-systemd.device-timeout=15s
luks-zfs2 UUID=$ZFS_LUKS_UUID2 none luks,tpm2-device=auto,nofail,x-systemd.device-timeout=15s
EOF
ROOT_UUID=$(blkid -s UUID -o value /dev/vgubuntu/root)
SWAP_UUID=$(blkid -s UUID -o value /dev/vgubuntu/swap)
ESP_UUID1=$(blkid -s UUID -o value "$ESP1")
ESP_UUID2=$(blkid -s UUID -o value "$ESP2")
cat > "$TARGET/etc/fstab" <<EOF
UUID=$ROOT_UUID / ext4 errors=remount-ro 0 1
UUID=$MD_BOOT_UUID /boot ext4 defaults 0 2
UUID=$ESP_UUID1 /boot/efi vfat umask=0077,nofail,x-systemd.device-timeout=15s 0 1
UUID=$ESP_UUID2 /boot/efi2 vfat umask=0077,nofail,x-systemd.device-timeout=15s 0 1
UUID=$SWAP_UUID none swap sw 0 0
EOF

zpool create -f -R "$TARGET" -o ashift=12 -o autotrim=on \
  -o cachefile=none \
  -O acltype=posixacl -O xattr=sa -O compression=zstd \
  -O atime=off -O mountpoint=none "$POOL" mirror \
  /dev/mapper/luks-zfs1 /dev/mapper/luks-zfs2
zfs create -o mountpoint=/data "$POOL/data"
zpool status "$POOL"
zpool export "$POOL"

for filesystem in dev proc sys; do
  mount --rbind "/$filesystem" "$TARGET/$filesystem"
  mount --make-rslave "$TARGET/$filesystem"
done
mount -t tmpfs tmpfs "$TARGET/run"
mkdir -p "$TARGET/run/lock"
rm -f "$TARGET/etc/resolv.conf"
if [[ -r /run/systemd/resolve/resolv.conf ]]; then
  cp /run/systemd/resolve/resolv.conf "$TARGET/etc/resolv.conf"
else
  cp -L /etc/resolv.conf "$TARGET/etc/resolv.conf"
fi
printf '%s\n' "$USER_PASSWORD" > "$TARGET/run/installer-user-password"
chmod 600 "$TARGET/run/installer-user-password"

cat > "$TARGET/root/target-setup.sh" <<'CHROOT'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=l

echo "$NEW_HOSTNAME" > /etc/hostname
printf '127.0.0.1 localhost\n127.0.1.1 %s\n::1 localhost ip6-localhost ip6-loopback\n' \
  "$NEW_HOSTNAME" > /etc/hosts
rm -f /etc/apt/sources.list.d/ubuntu.sources
cat > /etc/apt/sources.list <<EOS
deb $MIRROR $SUITE main restricted universe multiverse
deb $MIRROR $SUITE-updates main restricted universe multiverse
deb $SECURITY_MIRROR $SUITE-security main restricted universe multiverse
EOS
apt-get update
apt-get install -y --no-install-recommends locales
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8

mkdir -p /etc/dracut.conf.d
cat > /etc/dracut.conf.d/90-root-luks-mdraid.conf <<'EOS'
hostonly="no"
hostonly_cmdline="no"
add_dracutmodules+=" systemd systemd-initrd mdraid crypt lvm tpm2-tss "
install_items+=" /etc/crypttab /etc/mdadm/mdadm.conf "
compress="zstd"
EOS

apt-get install -y --no-install-recommends dracut
apt-get install -y --no-install-recommends \
  linux-generic linux-headers-generic \
  mdadm lvm2 cryptsetup systemd-cryptsetup systemd-sysv tpm2-tools \
  grub-efi-amd64 grub-efi-amd64-signed shim-signed efibootmgr dosfstools \
  zfsutils-linux zfs-zed \
  ubuntu-minimal openssh-server sudo netplan.io systemd-resolved \
  rsync curl less vim-tiny bash-completion ufw

find /lib/modules -name 'zfs.ko*' | grep -q . || {
  echo "ERROR: signed ZFS kernel module not found under /lib/modules." >&2
  exit 1
}

systemctl enable systemd-resolved.service
rm -f /etc/resolv.conf
ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

sed -i 's|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX="root=/dev/mapper/vgubuntu-root rd.md=1 rd.md.uuid='"$MD_BOOT_ID"' rd.md.uuid='"$MD_ROOT_ID"' rd.luks.uuid='"$ROOT_LUKS_UUID"'"|' /etc/default/grub
sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=""|' /etc/default/grub
sed -i 's|^GRUB_TIMEOUT_STYLE=.*|GRUB_TIMEOUT_STYLE=menu|' /etc/default/grub
sed -i 's|^GRUB_TIMEOUT=.*|GRUB_TIMEOUT=3|' /etc/default/grub

cat > /etc/systemd/system/zfs-import-dpool.service <<'EOS'
[Unit]
Description=Import encrypted ZFS data pool
DefaultDependencies=no
Wants=cryptsetup.target
After=systemd-udev-settle.service cryptsetup.target
After=systemd-cryptsetup@luks\x2dzfs1.service
After=systemd-cryptsetup@luks\x2dzfs2.service
Before=zfs-import.target zfs-mount.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/sbin/modprobe zfs
ExecStart=/usr/sbin/zpool import -N -d /dev/mapper dpool

[Install]
WantedBy=zfs-import.target
EOS
systemctl disable zfs-import-cache.service zfs-import-scan.service 2>/dev/null || true
systemctl enable zfs-import-dpool.service zfs-mount.service zfs-zed.service

cat > /usr/local/sbin/sync-efi <<'EOS'
#!/bin/sh
set -eu
mountpoint -q /boot/efi || { echo "WARNING: primary ESP is not mounted; skipping sync." >&2; exit 0; }
if [ -s /boot/efi/EFI/ubuntu/shimx64.efi ] && [ -s /boot/efi/EFI/ubuntu/grubx64.efi ]; then
  mkdir -p /boot/efi/EFI/BOOT
  cp -f /boot/efi/EFI/ubuntu/shimx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI
  cp -f /boot/efi/EFI/ubuntu/grubx64.efi /boot/efi/EFI/BOOT/grubx64.efi
  [ -s /boot/efi/EFI/ubuntu/mmx64.efi ] && cp -f /boot/efi/EFI/ubuntu/mmx64.efi /boot/efi/EFI/BOOT/mmx64.efi
  [ -s /boot/efi/EFI/ubuntu/grub.cfg ] && cp -f /boot/efi/EFI/ubuntu/grub.cfg /boot/efi/EFI/BOOT/grub.cfg
fi
mountpoint -q /boot/efi2 || { echo "WARNING: secondary ESP is not mounted; skipping sync." >&2; exit 0; }
[ -s /boot/efi/EFI/ubuntu/grubx64.efi ] || { echo "ERROR: primary ESP missing grubx64.efi; aborting sync." >&2; exit 1; }
rsync -a --delete /boot/efi/ /boot/efi2/
EOS
chmod 755 /usr/local/sbin/sync-efi
mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/99-sync-efi <<'EOS'
DPkg::Post-Invoke { "if mountpoint -q /boot/efi && mountpoint -q /boot/efi2; then /usr/local/sbin/sync-efi; fi"; };
EOS

dracut --force --regenerate-all
mapfile -t installed_kernels < <(find /lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
((${#installed_kernels[@]} > 0)) || { echo "ERROR: no installed kernel modules found." >&2; exit 1; }
for kernel in "${installed_kernels[@]}"; do
  initrd="/boot/initrd.img-$kernel"
  [[ -s $initrd ]] || { echo "ERROR: dracut did not create $initrd." >&2; exit 1; }
  dracut_modules=$(lsinitrd -m "$initrd")
  for required_module in systemd systemd-initrd mdraid crypt lvm tpm2-tss; do
    grep -Fxq "$required_module" <<<"$dracut_modules" || {
      echo "ERROR: initramfs for $kernel is missing dracut module $required_module." >&2
      exit 1
    }
  done
done

update-grub
grub-install --target=x86_64-efi --efi-directory=/boot/efi \
  --bootloader-id=ubuntu --no-nvram --recheck --uefi-secure-boot
/usr/local/sbin/sync-efi
grub-script-check /boot/grub/grub.cfg
for esp in /boot/efi /boot/efi2; do
  for efi_file in EFI/ubuntu/shimx64.efi EFI/ubuntu/grubx64.efi EFI/BOOT/BOOTX64.EFI EFI/BOOT/grubx64.efi; do
    [[ -s "$esp/$efi_file" ]] || {
      echo "ERROR: missing Secure Boot loader $esp/$efi_file." >&2
      exit 1
    }
  done
done

useradd -m -s /bin/bash -G sudo,adm "$NEW_USER"
chpasswd < <(printf '%s:%s\n' "$NEW_USER" "$(cat /run/installer-user-password)")
passwd -l root
rm -f /run/installer-user-password
cat > /etc/ssh/sshd_config.d/10-password-login.conf <<'EOS'
PasswordAuthentication yes
KbdInteractiveAuthentication yes
PermitRootLogin no
EOS
cat > /etc/netplan/01-netcfg.yaml <<'EOS'
network:
  version: 2
  renderer: networkd
  ethernets:
    all-en:
      match:
        name: ["en*", "eth*"]
      dhcp4: true
      dhcp6: true
EOS
chmod 600 /etc/netplan/01-netcfg.yaml

cat > /usr/local/sbin/enroll-tpm2 <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
PCRS="${1:-7}"
[[ $PCRS =~ ^[0-9]+(\+[0-9]+)*$ ]] || { echo "Usage: enroll-tpm2 [PCRS, default 7; use + between PCRs]" >&2; exit 2; }
[[ -c /dev/tpmrm0 ]] || { echo "ERROR: no TPM2 resource-manager device (/dev/tpmrm0)." >&2; exit 1; }
read -r -s -p "Current LUKS passphrase: " PASSWORD; printf '\n'
KEYFILE=$(mktemp /run/enroll-tpm2.XXXXXX)
trap 'rm -f "$KEYFILE"; unset PASSWORD' EXIT
chmod 600 "$KEYFILE"
printf '%s' "$PASSWORD" > "$KEYFILE"
unset PASSWORD
mapfile -t UUIDS < <(awk '$3 == "none" && $4 ~ /(^|,)luks(,|$)/ {sub(/^UUID=/, "", $2); print $2}' /etc/crypttab)
((${#UUIDS[@]} > 0)) || { echo "ERROR: no LUKS devices found in /etc/crypttab." >&2; exit 1; }
for uuid in "${UUIDS[@]}"; do
  device=$(blkid -U "$uuid") || { echo "ERROR: cannot locate LUKS UUID $uuid." >&2; exit 1; }
  echo "Enrolling TPM2 unlock for $device (PCRs $PCRS)"
  systemd-cryptenroll --unlock-key-file="$KEYFILE" --wipe-slot=tpm2 \
    --tpm2-device=auto --tpm2-pcrs="$PCRS" "$device"
done
echo "TPM2 enrollment complete. The LUKS passphrase remains available as fallback."
EOS
chmod 755 /usr/local/sbin/enroll-tpm2
CHROOT
chmod 700 "$TARGET/root/target-setup.sh"

chroot "$TARGET" /usr/bin/env \
  NEW_HOSTNAME="$NEW_HOSTNAME" NEW_USER="$NEW_USER" \
  MIRROR="$MIRROR" SECURITY_MIRROR="$SECURITY_MIRROR" \
  SUITE="$SUITE" ROOT_LUKS_UUID="$ROOT_LUKS_UUID" \
  MD_BOOT_ID="$MD_BOOT_ID" MD_ROOT_ID="$MD_ROOT_ID" \
  bash /root/target-setup.sh
rm -f "$TARGET/root/target-setup.sh"

for disk in "$DISK1" "$DISK2"; do
  disk_real=$(readlink -f "$disk")
  partition_number=1
  efibootmgr -c -g -d "$disk_real" -p "$partition_number" \
    -L "ubuntu ($(basename "$disk"))" -l '\EFI\ubuntu\shimx64.efi' \
    || echo "WARNING: failed to create a UEFI boot entry for $disk; add it in firmware setup."
done

sync
echo
echo "Waiting for initial mdraid resync before reporting completion."
mdadm --wait /dev/md0
mdadm --wait /dev/md1
echo "Initial mirror synchronization complete."

for filesystem in dev proc sys; do umount -R "$TARGET/$filesystem"; done
umount "$TARGET/run"
umount "$TARGET/boot/efi2"
umount "$TARGET/boot/efi"
umount "$TARGET/boot"
umount "$TARGET"
udevadm settle
cryptsetup close luks-zfs1
cryptsetup close luks-zfs2
vgchange -an vgubuntu
cryptsetup close cryptroot
udevadm settle
mdadm --stop /dev/md0
mdadm --stop /dev/md1

cat <<EOF
Installation files are in place. Remove the live media and boot the installed system
with Secure Boot still enabled. Enter the LUKS passphrase for the first boot.

After login, verify the OS mirror and test the passphrase fallback:
  cat /proc/mdstat
  sudo mdadm --detail /dev/md0
  sudo mdadm --detail /dev/md1

Then enroll TPM2 for the root and ZFS LUKS devices:
  sudo enroll-tpm2 7

After the next reboot, verify TPM unlock. Keep the LUKS passphrase offline.
The ZFS data pool is $POOL and mounts at /data. Check it with:
  sudo zpool status
  findmnt /data

This installer has not been hardware-validated. Before using it with important data,
test both disks, each disk missing in turn, a kernel update, EFI synchronization,
passphrase fallback, and TPM recovery on disposable drives.
EOF
