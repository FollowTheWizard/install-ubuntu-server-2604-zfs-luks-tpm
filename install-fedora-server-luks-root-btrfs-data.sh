#!/usr/bin/env bash
# Fedora Server: Btrfs RAID1 /boot, encrypted Btrfs RAID1 root and data.
# Secure Boot is preferred, but the user may choose to continue without it.
# This installer destroys both selected disks. Hardware validation is required.
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail
trap 'rc=$?; printf "Installer failed at line %s (status %s).\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR

TARGET=/mnt/fedora-install
EFI_MB=1024
BOOT_MB=2048
DEFAULT_ROOT_GIB=100
SMALL_DISK_ROOT_GIB=64
MIN_ROOT_GIB=40
MIN_DATA_MB=8192
DATA_MOUNT=/data
KEYFILE=""
MOUNTS=()
OPENED_ROOT1=0
OPENED_ROOT2=0
OPENED_DATA1=0
OPENED_DATA2=0

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
disk_has_active_swap() {
  local disk=$1 child swap child_real swap_real
  while IFS= read -r swap; do
    [[ -b $swap ]] || continue
    swap_real=$(readlink -f "$swap")
    while IFS= read -r child; do
      child_real=$(readlink -f "$child")
      [[ $child_real == "$swap_real" ]] && return 0
    done < <(lsblk -nrpo NAME "$disk")
  done < <(swapon --show=NAME --noheadings --raw)
  return 1
}
mount_target() {
  mount "$1" "$2"
  MOUNTS+=("$2")
}
mount_bind() {
  mount --rbind "$1" "$TARGET$1"
  mount --make-rslave "$TARGET$1"
  MOUNTS+=("$TARGET$1")
}
cleanup() {
  local i
  if [[ -n ${KEYFILE:-} && -f $KEYFILE ]]; then
    shred -u "$KEYFILE" 2>/dev/null || rm -f "$KEYFILE"
  fi
  for ((i=${#MOUNTS[@]}-1; i>=0; i--)); do
    if mountpoint -q "${MOUNTS[$i]}"; then
      umount -R "${MOUNTS[$i]}" || printf 'WARNING: could not unmount %s\n' "${MOUNTS[$i]}" >&2
    fi
  done
  (( OPENED_DATA2 == 0 )) || cryptsetup close fedora-data2 || true
  (( OPENED_DATA1 == 0 )) || cryptsetup close fedora-data1 || true
  (( OPENED_ROOT2 == 0 )) || cryptsetup close fedora-root2 || true
  (( OPENED_ROOT1 == 0 )) || cryptsetup close fedora-root1 || true
}
trap cleanup EXIT

[[ $EUID -eq 0 ]] || die "Run as root from a Fedora live environment."
[[ -f /etc/fedora-release ]] || die "This installer must run from Fedora live media."
[[ $(uname -m) == x86_64 ]] || die "Only x86_64 is supported."
[[ -d /sys/firmware/efi ]] || die "Boot the Fedora live media in UEFI mode."
[[ -c /dev/tpmrm0 ]] || die "TPM2 resource-manager device /dev/tpmrm0 is required."
if [[ -e $TARGET || -L $TARGET ]]; then
  [[ -d $TARGET && ! -L $TARGET ]] || die "$TARGET exists but is not a real directory."
  mountpoint -q "$TARGET" && die "$TARGET is already a mountpoint."
  [[ -z $(find "$TARGET" -mindepth 1 -maxdepth 1 -print -quit) ]] \
    || die "$TARGET is not empty; refusing to use it as the installation mountpoint."
fi

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
  echo "Secure Boot is enabled."
else
  rc=$?
  if (( rc == 1 )); then
    echo "WARNING: Secure Boot is disabled."
  else
    echo "WARNING: Cannot determine Secure Boot state from UEFI variables."
  fi
  cat <<'EOF'
The installed system uses Fedora-signed boot files, but continuing does not
enable or enforce Secure Boot. TPM2 enrollment uses PCR 7; changes to the boot
or Secure Boot configuration can prevent TPM unlock. The LUKS passphrase remains
available for recovery.
EOF
  read -r -p "Continue without verified Secure Boot? [y/N]: " continue_without_secure_boot
  case ${continue_without_secure_boot,,} in
    y|yes) ;;
    *) die "Stopped because Secure Boot is disabled or could not be verified." ;;
  esac
fi

FEDORA_VERSION=$(rpm -E '%fedora')
[[ $FEDORA_VERSION =~ ^[0-9]+$ ]] || die "Cannot determine the Fedora release from the live environment."
command -v dnf5 >/dev/null 2>&1 || die "Fedora live media must provide dnf5."

hr
echo "Install disk tools in the live environment."
dnf5 -y install gdisk cryptsetup btrfs-progs \
  dosfstools efibootmgr rsync util-linux

mapfile -t DISKS < <(lsblk -dpno NAME,TYPE | awk '$2 == "disk" {print $1}' \
  | grep -vE '/dev/(loop|sr|zram|fd|ram)')
(( ${#DISKS[@]} >= 2 )) || die "At least two disks are required."

hr
echo "Disks detected (disks with mounted filesystems are not eligible):"
ELIGIBLE=()
for disk in "${DISKS[@]}"; do
  if lsblk -nrpo MOUNTPOINT "$disk" | grep -qE '^/' || disk_has_active_swap "$disk"; then
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

DISK1=$(stable_id "$(pick_disk 'First OS/data disk number')")
while :; do
  DISK2=$(stable_id "$(pick_disk 'Second OS/data disk number')")
  [[ $(readlink -f "$DISK1") != "$(readlink -f "$DISK2")" ]] && break
  echo "Choose a different second disk."
done
SIZE1=$(disk_size_mib "$DISK1")
SIZE2=$(disk_size_mib "$DISK2")
SMALL_SIZE=$SIZE1
(( SIZE2 < SMALL_SIZE )) && SMALL_SIZE=$SIZE2
MAX_ROOT_GIB=$(( (SMALL_SIZE - EFI_MB - BOOT_MB - MIN_DATA_MB - 16) / 1024 ))
(( MAX_ROOT_GIB >= MIN_ROOT_GIB )) \
  || die "Each disk must be at least $((EFI_MB + BOOT_MB + MIN_ROOT_GIB * 1024 + MIN_DATA_MB + 16)) MiB (~51 GiB) for 1 GiB EFI, 2 GiB /boot, 40 GiB OS, and 8 GiB data."
ROOT_DEFAULT_GIB=$DEFAULT_ROOT_GIB
if (( ROOT_DEFAULT_GIB > MAX_ROOT_GIB )); then
  ROOT_DEFAULT_GIB=$SMALL_DISK_ROOT_GIB
  (( ROOT_DEFAULT_GIB <= MAX_ROOT_GIB )) || ROOT_DEFAULT_GIB=$MAX_ROOT_GIB
fi
while :; do
  ROOT_GIB=$(ask "OS size per disk in GiB ($MIN_ROOT_GIB-$MAX_ROOT_GIB; data uses the rest)" "$ROOT_DEFAULT_GIB")
  [[ $ROOT_GIB =~ ^[0-9]{1,6}$ ]] \
    && (( 10#$ROOT_GIB >= MIN_ROOT_GIB && 10#$ROOT_GIB <= MAX_ROOT_GIB )) && break
  echo "Enter a whole number of GiB from $MIN_ROOT_GIB to $MAX_ROOT_GIB."
done
ROOT_GIB=$(( 10#$ROOT_GIB ))
ROOT_MB=$(( ROOT_GIB * 1024 ))
DATA1_MB=$(( SIZE1 - EFI_MB - BOOT_MB - ROOT_MB - 16 ))
DATA2_MB=$(( SIZE2 - EFI_MB - BOOT_MB - ROOT_MB - 16 ))
(( DATA1_MB >= MIN_DATA_MB && DATA2_MB >= MIN_DATA_MB )) \
  || die "Each disk must fit 1 GiB EFI, 2 GiB /boot, ${ROOT_GIB} GiB OS, and at least 8 GiB data."

NEW_HOSTNAME=$(ask "Hostname" fedora-server)
[[ $NEW_HOSTNAME =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,62}$ ]] || die "Invalid hostname."
while :; do
  NEW_USER=$(ask "Administrator username" admin)
  [[ $NEW_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && break
  echo "Invalid username."
done
ask_secret "Password for $NEW_USER" 10
USER_PASSWORD=$REPLY
ask_secret "LUKS2 passphrase for OS and Btrfs data (kept as recovery fallback)" 12
LUKS_PASSWORD=$REPLY

hr
cat <<EOF
Fedora Server $FEDORA_VERSION — Secure Boot state is user-selected
  Disk 1: $DISK1 ($SIZE1 MiB)
  Disk 2: $DISK2 ($SIZE2 MiB)
  Per disk: ${EFI_MB} MiB EFI | ${BOOT_MB} MiB Btrfs /boot RAID1 | ${ROOT_GIB} GiB LUKS2+Btrfs OS RAID1 | remaining LUKS2+Btrfs data
  OS: separate ${ROOT_GIB} GiB-per-disk encrypted Btrfs RAID1 mounted at /
  Data: encrypted Btrfs RAID1 mounted at $DATA_MOUNT
  TPM2: enrollment is deferred until the installed system boots; LUKS passphrase remains available
  Data partitions: ${DATA1_MB} MiB on disk 1, ${DATA2_MB} MiB on disk 2
  Different-sized disks: usable data capacity is limited by the smaller data partition

ALL DATA ON BOTH DISKS WILL BE DESTROYED.
EOF
hr
read -r -p "Type YES to erase both disks and install: " confirmation
[[ $confirmation == YES ]] || { echo "Aborted."; exit 0; }

for disk in "$DISK1" "$DISK2"; do
  [[ -b $disk && $(lsblk -dnro TYPE "$disk") == disk ]] \
    || die "Target is no longer a whole-disk block device: $disk"
  if lsblk -nrpo MOUNTPOINT "$disk" | grep -qE '^/'; then
    die "$disk or one of its partitions became mounted; refusing to erase it."
  fi
  disk_has_active_swap "$disk" && die "$disk contains active swap; refusing to erase it."
  mapfile -t CHILDREN < <(lsblk -nrpo NAME "$disk")
  for child in "${CHILDREN[@]}"; do
    holders=(/sys/class/block/"$(basename "$(readlink -f "$child")")"/holders/*)
    [[ ! -e ${holders[0]:-} ]] || die "$child has active holders; refusing to erase it."
  done
done

hr
echo "Prepare the target disks."
for disk in "$DISK1" "$DISK2"; do
  wipefs -af "$disk"
  sgdisk --zap-all "$disk"
  sgdisk -n1:1M:+${EFI_MB}M  -t1:EF00 -c1:EFI "$disk"
  sgdisk -n2:0:+${BOOT_MB}M -t2:8300 -c2:boot-btrfs "$disk"
  sgdisk -n3:0:+${ROOT_MB}M -t3:8309 -c3:root-luks "$disk"
  sgdisk -n4:0:0            -t4:8309 -c4:data-luks "$disk"
  partprobe "$disk"
done
udevadm settle
sleep 2

ESP1=$(part "$DISK1" 1); ESP2=$(part "$DISK2" 1)
BOOT1=$(part "$DISK1" 2); BOOT2=$(part "$DISK2" 2)
ROOT1=$(part "$DISK1" 3); ROOT2=$(part "$DISK2" 3)
DATA1=$(part "$DISK1" 4); DATA2=$(part "$DISK2" 4)
for device in "$ESP1" "$ESP2" "$BOOT1" "$BOOT2" "$ROOT1" "$ROOT2" "$DATA1" "$DATA2"; do
  [[ -b $device ]] || die "Partition did not appear: $device"
done

mkfs.vfat -F32 -n EFI1 "$ESP1"
mkfs.vfat -F32 -n EFI2 "$ESP2"
mkfs.btrfs -f -L fedora-boot -d raid1 -m raid1 "$BOOT1" "$BOOT2"

KEYFILE=$(mktemp /run/fedora-luks.XXXXXX)
chmod 600 "$KEYFILE"
printf '%s' "$LUKS_PASSWORD" > "$KEYFILE"
unset LUKS_PASSWORD
for device in "$ROOT1" "$ROOT2"; do
  cryptsetup luksFormat --batch-mode --type luks2 --cipher aes-xts-plain64 \
    --key-size 512 --pbkdf argon2id --key-file "$KEYFILE" "$device"
done
cryptsetup open --key-file "$KEYFILE" "$ROOT1" fedora-root1
OPENED_ROOT1=1
cryptsetup open --key-file "$KEYFILE" "$ROOT2" fedora-root2
OPENED_ROOT2=1

cryptsetup luksFormat --batch-mode --type luks2 --cipher aes-xts-plain64 \
  --key-size 512 --pbkdf argon2id --key-file "$KEYFILE" "$DATA1"
cryptsetup luksFormat --batch-mode --type luks2 --cipher aes-xts-plain64 \
  --key-size 512 --pbkdf argon2id --key-file "$KEYFILE" "$DATA2"
cryptsetup open --key-file "$KEYFILE" "$DATA1" fedora-data1
OPENED_DATA1=1
cryptsetup open --key-file "$KEYFILE" "$DATA2" fedora-data2
OPENED_DATA2=1

ROOT_LUKS_UUID1=$(cryptsetup luksUUID "$ROOT1")
ROOT_LUKS_UUID2=$(cryptsetup luksUUID "$ROOT2")
DATA_LUKS_UUID1=$(cryptsetup luksUUID "$DATA1")
DATA_LUKS_UUID2=$(cryptsetup luksUUID "$DATA2")
mkfs.btrfs -f -L fedora-root -d raid1 -m raid1 \
  /dev/mapper/fedora-root1 /dev/mapper/fedora-root2
mkfs.btrfs -f -L data -d raid1 -m raid1 /dev/mapper/fedora-data1 /dev/mapper/fedora-data2
ROOT_FS_UUID=$(blkid -s UUID -o value /dev/mapper/fedora-root1)
BOOT_FS_UUID=$(blkid -s UUID -o value "$BOOT1")
DATA_FS_UUID=$(blkid -s UUID -o value /dev/mapper/fedora-data1)
ESP_UUID1=$(blkid -s UUID -o value "$ESP1")
ESP_UUID2=$(blkid -s UUID -o value "$ESP2")
[[ -n $ROOT_FS_UUID && -n $BOOT_FS_UUID && -n $DATA_FS_UUID ]] \
  || die "Could not read new Btrfs filesystem UUIDs."

mkdir -p "$TARGET"
mount -o subvolid=5 /dev/mapper/fedora-root1 "$TARGET"
MOUNTS+=("$TARGET")
btrfs subvolume create "$TARGET/@"
umount "$TARGET"
mount -o subvol=@ /dev/mapper/fedora-root1 "$TARGET"
MOUNTS+=("$TARGET")
mkdir -p "$TARGET/boot" "$TARGET$DATA_MOUNT"
mount_target "$BOOT1" "$TARGET/boot"
mkdir -p "$TARGET/boot/efi" "$TARGET/boot/efi2"
mount_target "$ESP1" "$TARGET/boot/efi"
mount_target "$ESP2" "$TARGET/boot/efi2"
mkdir -p "$TARGET/boot/loader/entries"
mount_target /dev/mapper/fedora-data1 "$TARGET$DATA_MOUNT"
mkdir -p "$TARGET/dev" "$TARGET/proc" "$TARGET/sys" "$TARGET/run/lock"
mount -t tmpfs tmpfs "$TARGET/run"
MOUNTS+=("$TARGET/run")
for filesystem in dev proc sys; do mount_bind "/$filesystem"; done

hr
echo "Install Fedora Server $FEDORA_VERSION into $TARGET."
DNF_INSTALLROOT=(dnf5 -y --use-host-config "--installroot=$TARGET" "--releasever=$FEDORA_VERSION" \
  --setopt=install_weak_deps=False)
"${DNF_INSTALLROOT[@]}" group install core
"${DNF_INSTALLROOT[@]}" install \
  fedora-release-server kernel dracut grubby grub2-efi-x64 grub2-efi-x64-modules \
  grub2-tools grub2-tools-extra shim-x64 efibootmgr cryptsetup \
  btrfs-progs tpm2-tools mokutil dosfstools NetworkManager sudo openssh-server \
  firewalld policycoreutils rsync less vim-enhanced cracklib-dicts

mkdir -p "$TARGET/etc" "$TARGET/etc/dracut.conf.d" \
  "$TARGET/etc/kernel" "$TARGET/etc/ssh/sshd_config.d" \
  "$TARGET/etc/NetworkManager/system-connections"
cat > "$TARGET/etc/hostname" <<EOF
$NEW_HOSTNAME
EOF
cat > "$TARGET/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 $NEW_HOSTNAME
::1 localhost localhost.localdomain
EOF
cat > "$TARGET/etc/crypttab" <<EOF
fedora-root1 UUID=$ROOT_LUKS_UUID1 none luks,x-initrd.attach,tpm2-device=auto
fedora-root2 UUID=$ROOT_LUKS_UUID2 none luks,x-initrd.attach,tpm2-device=auto
fedora-data1 UUID=$DATA_LUKS_UUID1 none luks,discard,nofail,tpm2-device=auto
fedora-data2 UUID=$DATA_LUKS_UUID2 none luks,discard,nofail,tpm2-device=auto
EOF
cat > "$TARGET/etc/fstab" <<EOF
UUID=$ROOT_FS_UUID / btrfs subvol=@,compress=zstd:1,degraded 0 0
UUID=$BOOT_FS_UUID /boot btrfs compress=zstd:1,degraded 0 0
UUID=$ESP_UUID1 /boot/efi vfat umask=0077 0 1
UUID=$ESP_UUID2 /boot/efi2 vfat umask=0077,nofail,x-systemd.device-timeout=15s 0 1
UUID=$DATA_FS_UUID $DATA_MOUNT btrfs compress=zstd:1,nofail,x-systemd.requires=systemd-cryptsetup@fedora-data1.service,x-systemd.requires=systemd-cryptsetup@fedora-data2.service 0 0
EOF
cat > "$TARGET/etc/dracut.conf.d/90-root-luks-btrfs.conf" <<'EOF'
hostonly="no"
hostonly_cmdline="no"
add_dracutmodules+=" crypt btrfs tpm2-tss "
install_items+=" /etc/crypttab "
compress="zstd"
EOF
cat > "$TARGET/etc/kernel/cmdline" <<EOF
root=UUID=$ROOT_FS_UUID rootflags=subvol=@,degraded,compress=zstd:1 rd.luks.uuid=luks-$ROOT_LUKS_UUID1 rd.luks.uuid=luks-$ROOT_LUKS_UUID2
EOF
cat > "$TARGET/etc/NetworkManager/system-connections/auto-dhcp.nmconnection" <<'EOF'
[connection]
id=auto-dhcp
type=ethernet
interface-name=*
autoconnect=true

[ipv4]
method=auto

[ipv6]
method=auto
EOF
chmod 600 "$TARGET/etc/NetworkManager/system-connections/auto-dhcp.nmconnection"
cat > "$TARGET/etc/ssh/sshd_config.d/10-install-settings.conf" <<'EOF'
PermitRootLogin no
PasswordAuthentication yes
EOF

mkdir -p "$TARGET/usr/local/sbin"
cat > "$TARGET/usr/local/sbin/enroll-tpm2" <<'EOF'
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
mapfile -t UUIDS < <(awk '$1 ~ /^(fedora-root1|fedora-root2|fedora-data1|fedora-data2)$/ {sub(/^UUID=/, "", $2); print $2}' /etc/crypttab)
((${#UUIDS[@]} > 0)) || { echo "ERROR: no expected LUKS devices found in /etc/crypttab." >&2; exit 1; }
for uuid in "${UUIDS[@]}"; do
  device=$(blkid -U "$uuid") || { echo "ERROR: cannot locate LUKS UUID $uuid." >&2; exit 1; }
  echo "Enrolling TPM2 unlock for $device (PCRs $PCRS)"
  systemd-cryptenroll --unlock-key-file="$KEYFILE" --wipe-slot=tpm2 \
    --tpm2-device=auto --tpm2-pcrs="$PCRS" "$device"
done
dracut --force --regenerate-all
echo "TPM2 enrollment complete. Keep the LUKS passphrase as your recovery method."
EOF
chmod 755 "$TARGET/usr/local/sbin/enroll-tpm2"

mkdir -p "$TARGET/usr/local/sbin" "$TARGET/etc/systemd/system"
cat > "$TARGET/usr/local/sbin/sync-efi" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
mountpoint -q /boot/efi || { echo "Primary ESP is not mounted; refusing to sync." >&2; exit 1; }
mountpoint -q /boot/efi2 || { echo "Secondary ESP is not mounted; refusing to sync." >&2; exit 1; }
rsync -a --delete /boot/efi/ /boot/efi2/
EOF
chmod 755 "$TARGET/usr/local/sbin/sync-efi"
cat > "$TARGET/etc/systemd/system/sync-efi.service" <<'EOF'
[Unit]
Description=Synchronize Fedora boot files to the secondary EFI partition
After=local-fs.target
ConditionPathIsMountPoint=/boot/efi2

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/sync-efi
EOF
cat > "$TARGET/etc/systemd/system/sync-efi.timer" <<'EOF'
[Unit]
Description=Periodically synchronize Fedora EFI partitions

[Timer]
OnBootSec=5min
OnUnitActiveSec=1d
Persistent=true

[Install]
WantedBy=timers.target
EOF

mkdir -p "$TARGET/etc/systemd/system/btrfs-scrub@.service.d"
cat > "$TARGET/etc/systemd/system/btrfs-scrub@.service" <<'EOF'
[Unit]
Description=Btrfs scrub on %f
ConditionPathIsMountPoint=%f

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
ExecStart=/usr/bin/btrfs scrub start -B %f
EOF
cat > "$TARGET/etc/systemd/system/btrfs-scrub@.timer" <<'EOF'
[Unit]
Description=Monthly Btrfs scrub on %f

[Timer]
OnCalendar=monthly
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

printf '%s\n' "$USER_PASSWORD" > "$TARGET/run/installer-user-password"
chmod 600 "$TARGET/run/installer-user-password"
unset USER_PASSWORD

chroot "$TARGET" /usr/bin/bash -Eeuo pipefail -c '
  useradd -m -s /bin/bash -G wheel "$1"
  chpasswd < <(printf "%s:%s\n" "$1" "$(cat /run/installer-user-password)")
  passwd -l root
  rm -f /run/installer-user-password
  grubby --update-kernel=ALL --args="root=UUID=$2 rootflags=subvol=@,degraded,compress=zstd:1 rd.luks.uuid=luks-$3 rd.luks.uuid=luks-$4"
  dracut --force --regenerate-all
  grub2-mkconfig -o /boot/grub2/grub.cfg
  touch /.autorelabel
' _ "$NEW_USER" "$ROOT_FS_UUID" "$ROOT_LUKS_UUID1" "$ROOT_LUKS_UUID2"

systemctl --root="$TARGET" enable NetworkManager.service sshd.service firewalld.service \
  sync-efi.timer 'btrfs-scrub@-.timer' 'btrfs-scrub@boot.timer' 'btrfs-scrub@data.timer'

[[ -s "$TARGET/boot/efi/EFI/fedora/shimx64.efi" ]] \
  || die "Fedora shim was not installed on the primary ESP; refusing to report success."
[[ -s "$TARGET/boot/efi/EFI/fedora/grubx64.efi" ]] \
  || die "Fedora GRUB EFI binary was not installed on the primary ESP."
rsync -a --delete "$TARGET/boot/efi/EFI/fedora/" "$TARGET/boot/efi2/EFI/fedora/"

for disk in "$DISK1" "$DISK2"; do
  disk_real=$(readlink -f "$disk")
  efibootmgr -c -g -d "$disk_real" -p 1 \
    -L "Fedora ($(basename "$disk"))" -l '\EFI\fedora\shimx64.efi' \
    || echo "WARNING: failed to create a UEFI boot entry for $disk; add it in firmware setup."
done

sync

cat <<EOF
Fedora installation files are ready. Remove the live media and boot using the
same Secure Boot configuration accepted during installation.
Enter the LUKS passphrase for the first boot; TPM enrollment is intentionally deferred.

After login, verify all Btrfs filesystems:
  sudo btrfs filesystem show /
  sudo btrfs filesystem show /boot
  sudo btrfs filesystem show /data
  sudo btrfs filesystem usage /
  findmnt /data

Then enroll TPM2 for both OS and both data LUKS devices:
  sudo enroll-tpm2 7

Verify TPM unlock on the next reboot. Keep the LUKS passphrase offline.
After kernel or bootloader updates, verify EFI synchronization with:
  sudo systemctl status sync-efi.timer
  sudo /usr/local/sbin/sync-efi

This installer has not been hardware-validated. Test both disks, each disk missing
in turn, kernel updates, passphrase fallback, and TPM recovery on disposable drives.
EOF
