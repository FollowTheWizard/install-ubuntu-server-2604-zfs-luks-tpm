#!/usr/bin/env bash
# Ubuntu 26.04 Server: mirrored mdraid /boot and LUKS2+LVM+ext4 root,
# plus a LUKS2-backed ZFS mirror for data. Secure Boot must stay enabled.
# This installer destroys both selected disks. Hardware validation is required.
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
trap 'rc=$?; printf "Installer failed at line %s (status %s).\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR

SUITE=resolute
MIRROR=https://archive.ubuntu.com/ubuntu
SECURITY_MIRROR=http://security.ubuntu.com/ubuntu
TARGET=/mnt
EFI_MB=1024
BOOT_MB=2048
ROOT_MB=65536
MIN_DATA_MB=8192
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

hr
echo "Install tools and confirm the signed ZFS module can load with Secure Boot enabled."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  debootstrap gdisk mdadm lvm2 cryptsetup zfsutils-linux \
  "linux-modules-zfs-$(uname -r)" linux-modules-zfs-generic \
  dosfstools efibootmgr rsync util-linux
modprobe zfs || die "The Ubuntu-signed ZFS module could not load with Secure Boot enabled; no target disks have been changed."

mapfile -t DISKS < <(lsblk -dpno NAME,TYPE | awk '$2 == "disk" {print $1}' \
  | grep -vE '/dev/(loop|sr|zram|fd|ram)')
(( ${#DISKS[@]} >= 2 )) || die "At least two disks are required."

hr
echo "Disks detected (mounted disks are not eligible):"
ELIGIBLE=()
for disk in "${DISKS[@]}"; do
  if lsblk -nrpo MOUNTPOINT "$disk" | grep -qE '^/'; then
    continue
  fi
  ELIGIBLE+=("$disk")
done
(( ${#ELIGIBLE[@]} >= 2 )) || die "Need two unmounted target disks; check that the live medium is not selected."
for index in "${!ELIGIBLE[@]}"; do
  disk=${ELIGIBLE[$index]}
  printf ' %2d) %-14s %8s  %-24s %s\n' "$((index+1))" "$disk" \
    "$(lsblk -dno SIZE "$disk")" "$(lsblk -dno MODEL "$disk" | tr -s ' ')" \
    "$(stable_id "$disk")"
done

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
  Root: 64 GiB mdraid1 → LUKS2 → LVM → approximately 60 GiB ext4 root + 4 GiB encrypted swap
  Data: two LUKS2 devices → mirrored ZFS pool $POOL (usable size limited by smaller disk)
  TPM2: enrollment is deferred until the installed system boots; root and data passphrase slots remain
  Disk size difference: unused ZFS-member capacity on the larger disk is not allocated elsewhere

ALL DATA ON BOTH DISKS WILL BE DESTROYED.
EOF
hr
read -r -p "Type YES to erase both disks and install: " confirmation
[[ $confirmation == YES ]] || { echo "Aborted."; exit 0; }

for disk in "$DISK1" "$DISK2"; do
  [[ -b $disk ]] || die "Target is no longer a block device: $disk"
  if lsblk -nrpo MOUNTPOINT "$disk" | grep -qE '^/'; then
    die "$disk or one of its partitions became mounted; refusing to erase it."
  fi
  mapfile -t CHILDREN < <(lsblk -nrpo NAME "$disk")
  for child in "${CHILDREN[@]}"; do
    holders=(/sys/class/block/"$(basename "$(readlink -f "$child")")"/holders/*)
    [[ ! -e ${holders[0]:-} ]] || die "$child has active holders; refusing to erase it."
  done
done

hr
echo "Prepare the live environment."
for disk in "$DISK1" "$DISK2"; do
  wipefs -af "$disk"
  sgdisk --zap-all "$disk"
  sgdisk -n1:1M:+${EFI_MB}M  -t1:EF00 -c1:EFI "$disk"
  sgdisk -n2:0:+${BOOT_MB}M -t2:FD00 -c2:boot-raid "$disk"
  sgdisk -n3:0:+${ROOT_MB}M -t3:FD00 -c3:root-raid "$disk"
  sgdisk -n4:0:0            -t4:8309 -c4:zfs-luks "$disk"
  partprobe "$disk"
done
udevadm settle
sleep 2

ESP1=$(part "$DISK1" 1); ESP2=$(part "$DISK2" 1)
BOOT1=$(part "$DISK1" 2); BOOT2=$(part "$DISK2" 2)
ROOT1=$(part "$DISK1" 3); ROOT2=$(part "$DISK2" 3)
ZFS1=$(part "$DISK1" 4); ZFS2=$(part "$DISK2" 4)
for device in "$ESP1" "$ESP2" "$BOOT1" "$BOOT2" "$ROOT1" "$ROOT2" "$ZFS1" "$ZFS2"; do
  [[ -b $device ]] || die "Partition did not appear: $device"
done

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
mkdir -p "$TARGET/boot" "$TARGET/boot/efi" "$TARGET/boot/efi2" "$TARGET/data"
mount /dev/md0 "$TARGET/boot"
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
luks-zfs1 UUID=$ZFS_LUKS_UUID1 none luks,tpm2-device=auto,nofail
luks-zfs2 UUID=$ZFS_LUKS_UUID2 none luks,tpm2-device=auto,nofail
EOF
ROOT_UUID=$(blkid -s UUID -o value /dev/vgubuntu/root)
SWAP_UUID=$(blkid -s UUID -o value /dev/vgubuntu/swap)
ESP_UUID1=$(blkid -s UUID -o value "$ESP1")
ESP_UUID2=$(blkid -s UUID -o value "$ESP2")
cat > "$TARGET/etc/fstab" <<EOF
UUID=$ROOT_UUID / ext4 errors=remount-ro 0 1
UUID=$MD_BOOT_UUID /boot ext4 defaults 0 2
UUID=$ESP_UUID1 /boot/efi vfat umask=0077 0 1
UUID=$ESP_UUID2 /boot/efi2 vfat umask=0077,nofail,x-systemd.device-timeout=15s 0 1
UUID=$SWAP_UUID none swap sw 0 0
EOF

zpool create -f -R "$TARGET" -o ashift=12 -o autotrim=on \
  -o cachefile="$TARGET/etc/zfs/zpool.cache" \
  -O acltype=posixacl -O xattr=sa -O compression=zstd \
  -O atime=off -O mountpoint=none "$POOL" mirror \
  /dev/mapper/luks-zfs1 /dev/mapper/luks-zfs2
zfs create -o mountpoint=/data "$POOL/data"
zpool export "$POOL"

for filesystem in dev proc sys; do
  mount --rbind "/$filesystem" "$TARGET/$filesystem"
  mount --make-rslave "$TARGET/$filesystem"
done
mount -t tmpfs tmpfs "$TARGET/run"
mkdir -p "$TARGET/run/lock"
rm -f "$TARGET/etc/resolv.conf"
cp -L /etc/resolv.conf "$TARGET/etc/resolv.conf"
printf '%s\n' "$USER_PASSWORD" > "$TARGET/run/installer-user-password"
chmod 600 "$TARGET/run/installer-user-password"

cat > "$TARGET/root/target-setup.sh" <<'CHROOT'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "$NEW_HOSTNAME" > /etc/hostname
printf '127.0.0.1 localhost\n127.0.1.1 %s\n::1 localhost ip6-localhost ip6-loopback\n' \
  "$NEW_HOSTNAME" > /etc/hosts
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
add_dracutmodules+=" mdraid crypt lvm tpm2-tss "
install_items+=" /etc/crypttab /etc/mdadm/mdadm.conf "
compress="zstd"
EOS

apt-get install -y --no-install-recommends dracut
apt-get install -y --no-install-recommends \
  linux-generic linux-headers-generic \
  mdadm lvm2 cryptsetup systemd-cryptsetup systemd-sysv tpm2-tools \
  grub-efi-amd64 grub-efi-amd64-signed shim-signed efibootmgr dosfstools \
  zfsutils-linux linux-modules-zfs-generic zfs-zed \
  ubuntu-minimal openssh-server sudo netplan.io systemd-resolved \
  rsync curl less vim-tiny bash-completion ufw

sed -i 's|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX="root=/dev/mapper/vgubuntu-root rd.md=1 rd.md.uuid='"$MD_BOOT_ID"' rd.md.uuid='"$MD_ROOT_ID"' rd.luks.uuid=luks-'"$ROOT_LUKS_UUID"'"|' /etc/default/grub
sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=""|' /etc/default/grub
sed -i 's|^GRUB_TIMEOUT_STYLE=.*|GRUB_TIMEOUT_STYLE=menu|' /etc/default/grub
sed -i 's|^GRUB_TIMEOUT=.*|GRUB_TIMEOUT=3|' /etc/default/grub

cat > /etc/systemd/system/zfs-import-dpool.service <<'EOS'
[Unit]
Description=Import encrypted ZFS data pool
DefaultDependencies=no
After=systemd-udev-settle.service cryptsetup.target
After=systemd-cryptsetup@luks\x2dzfs1.service
After=systemd-cryptsetup@luks\x2dzfs2.service
Before=zfs-mount.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/sbin/modprobe zfs
ExecStart=/usr/sbin/zpool import -N dpool

[Install]
WantedBy=zfs-import.target
EOS
systemctl disable zfs-import-cache.service zfs-import-scan.service
systemctl enable zfs-import-dpool.service zfs-mount.service zfs-zed.service

cat > /usr/local/sbin/sync-efi <<'EOS'
#!/bin/sh
set -eu
mountpoint -q /boot/efi2 || { echo "WARNING: secondary ESP is not mounted; skipping sync." >&2; exit 0; }
rsync -a --delete /boot/efi/ /boot/efi2/
EOS
chmod 755 /usr/local/sbin/sync-efi
mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/99-sync-efi <<'EOS'
DPkg::Post-Invoke { "if mountpoint -q /boot/efi2; then /usr/local/sbin/sync-efi; fi"; };
EOS

dracut --force --regenerate-all
update-grub
grub-install --target=x86_64-efi --efi-directory=/boot/efi \
  --bootloader-id=ubuntu --no-nvram --recheck --uefi-secure-boot
grub-install --target=x86_64-efi --efi-directory=/boot/efi2 \
  --bootloader-id=ubuntu --no-nvram --recheck --uefi-secure-boot
rsync -a --delete /boot/efi/ /boot/efi2/

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
      match: { name: "en*" }
      dhcp4: true
      dhcp6: true
EOS
chmod 600 /etc/netplan/01-netcfg.yaml

cat > /usr/local/sbin/enroll-tpm2 <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
PCRS="${1:-7}"
[[ $PCRS =~ ^[0-9]+(,[0-9]+)*$ ]] || { echo "Usage: enroll-tpm2 [PCRS, default 7]" >&2; exit 2; }
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
cryptsetup close luks-zfs1
cryptsetup close luks-zfs2
vgchange -an vgubuntu
cryptsetup close cryptroot
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
