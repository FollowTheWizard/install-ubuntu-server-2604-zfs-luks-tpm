#!/usr/bin/env bash
# =============================================================================
# Debian 13 (trixie) interactive installer
# Btrfs RAID1 /boot, root and data; LUKS2; passphrase or TPM2; Secure Boot
# Uses Debian-signed kernel/GRUB/shim packages and does not require DKMS or MOK.
# DESTROYS DATA on the disks you select.
# SPDX-License-Identifier: Apache-2.0
# =============================================================================
set -eu
# Helpers intentionally tolerate expected "not found" results in pipelines.

SUITE=trixie
MIRROR=https://deb.debian.org/debian
SECURITY_MIRROR=https://deb.debian.org/debian-security
EFI_MB=1024
BPOOL_MB=2048
SWAP_MB=4096
MIN_ROOT_GIB=32
DEFAULT_ROOT_GIB=64
ROOT_MB=$(( DEFAULT_ROOT_GIB * 1024 ))
T=/mnt

die() { echo "ERROR: $*" >&2; exit 1; }
hr() { printf '%*s\n' 78 '' | tr ' ' '-'; }
ask() { local r; read -rp "$1 [$2]: " r; echo "${r:-$2}"; }
ask_secret() {
  local a b
  while :; do
    read -rsp "$1: " a; echo
    read -rsp "Repeat: " b; echo
    [[ $a == "$b" ]] || { echo "  mismatch, try again"; continue; }
    (( ${#a} >= $2 )) || { echo "  too short (min $2 chars)"; continue; }
    REPLY=$a
    return
  done
}

[[ $EUID -eq 0 ]] || die "run as root (sudo -i)"
[[ -d /sys/firmware/efi ]] || die "not booted in UEFI mode"

HAVE_TPM=no
[[ -c /dev/tpmrm0 ]] && HAVE_TPM=yes

# ═════════════════════════ 1. DISK SELECTION ═════════════════════════
by_id() {
  local real l
  real=$(readlink -f "$1")
  for l in /dev/disk/by-id/*; do
    [[ $l == *-part* || $l == */wwn-* || $l == */nvme-eui.* ]] && continue
    [[ $(readlink -f "$l") == "$real" ]] && { echo "$l"; return; }
  done
  echo "$1"
}

LIVE_DEV=""
for m in /cdrom /run/live/medium /media/cdrom; do
  src=$(findmnt -no SOURCE "$m" 2>/dev/null) || continue
  [[ -n $src ]] || continue
  pk=$(lsblk -no PKNAME "$src" 2>/dev/null | head -1) || true
  LIVE_DEV=${pk:+/dev/$pk}
  LIVE_DEV=${LIVE_DEV:-$src}
  break
done

mapfile -t CAND < <(lsblk -dpno NAME,TYPE | awk '$2=="disk"{print $1}' \
  | grep -vE '/dev/(loop|sr|zram|fd|ram)')
DISKS=()
for d in "${CAND[@]}"; do
  [[ -n $LIVE_DEV && $(readlink -f "$d") == $(readlink -f "$LIVE_DEV") ]] \
    || DISKS+=("$d")
done
((${#DISKS[@]} >= 2)) || die "need at least two disks, found ${#DISKS[@]}"

hr
echo " Available disks (live medium ${LIVE_DEV:-?} excluded):"
hr
for i in "${!DISKS[@]}"; do
  d=${DISKS[$i]}
  printf ' %2d) %-14s %8s  %-28s %s\n' \
    "$((i+1))" "$d" "$(lsblk -dno SIZE "$d")" \
    "$(lsblk -dno MODEL "$d" | tr -s ' ')" "$(by_id "$d")"
done
hr

pick() {
  local n
  while :; do
    read -rp "$1: " n
    [[ $n =~ ^[0-9]+$ && n -ge 1 && n -le ${#DISKS[@]} ]] \
      && { echo "${DISKS[$((n-1))]}"; return; }
    echo "  enter 1-${#DISKS[@]}"
  done
}
D1=$(pick "Number of FIRST disk ")
while :; do
  D2=$(pick "Number of SECOND disk")
  [[ $D2 != "$D1" ]] && break
  echo "  must differ from first disk"
done
DISK1=$(by_id "$D1")
DISK2=$(by_id "$D2")

mib() { echo $(( $(blockdev --getsize64 "$1") / 1048576 )); }
S1=$(mib "$DISK1")
S2=$(mib "$DISK2")
SMALL=$(( S1 < S2 ? S1 : S2 ))
BIG=$(( S1 > S2 ? S1 : S2 ))
BIG_DISK=$DISK1
(( S2 > S1 )) && BIG_DISK=$DISK2
EXTRA_MB=$(( BIG - SMALL ))
MAX_ROOT_GIB=$(( (SMALL - 1 - EFI_MB - BPOOL_MB - SWAP_MB - 8 - 1025) / 1024 ))
(( MAX_ROOT_GIB >= MIN_ROOT_GIB )) \
  || die "disks too small for a ${MIN_ROOT_GIB} GiB OS plus at least 1 GiB data (smallest disk: ${SMALL} MiB)"

# ═════════════════════════ 2. SYSTEM SETTINGS ═════════════════════════
hr
echo " System settings (Enter accepts the [default])"
hr
while :; do
  ROOT_GIB=$(ask "OS/root size in GiB (minimum ${MIN_ROOT_GIB}, maximum ${MAX_ROOT_GIB})" "$DEFAULT_ROOT_GIB")
  [[ $ROOT_GIB =~ ^[0-9]+$ \
    && $ROOT_GIB -ge $MIN_ROOT_GIB && $ROOT_GIB -le $MAX_ROOT_GIB ]] && break
  echo "  enter a whole number from $MIN_ROOT_GIB to $MAX_ROOT_GIB"
done
ROOT_MB=$(( ROOT_GIB * 1024 ))
DATA_MB=$(( SMALL - 1 - EFI_MB - BPOOL_MB - SWAP_MB - ROOT_MB - 8 ))
NEW_HOSTNAME=$(ask "Hostname" debian-server)
while :; do
  NEW_USER=$(ask "Admin username" admin)
  [[ $NEW_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && break
  echo "  invalid username"
done
echo " (this password is also the SSH login — choose a strong one)"
ask_secret "Password for $NEW_USER" 10
USER_PASS=$REPLY
while :; do
  TIMEZONE=$(ask "Timezone" "Etc/UTC")
  [[ -f /usr/share/zoneinfo/$TIMEZONE ]] && break
  echo "  unknown timezone (e.g. Europe/Berlin)"
done
while :; do
  LOCALE=$(ask "Locale" de_DE.UTF-8)
  grep -q "^${LOCALE} " /usr/share/i18n/SUPPORTED 2>/dev/null && break
  echo "  unknown locale (see /usr/share/i18n/SUPPORTED, e.g. de_DE.UTF-8)"
done

EXTRA_SPACE=none
EXTRA_MNT=/data/extra
if (( EXTRA_MB >= 1024 )); then
  hr
  echo " Storage — mismatched disks"
  echo " The disks differ: $BIG_DISK has $EXTRA_MB MiB more than the other."
  echo " The mirrored Btrfs filesystems use the smaller disk's remaining space."
  echo " The leftover on the big disk can be used as an UNMIRRORED filesystem."
  while :; do
    EXTRA_SPACE=$(ask "Leftover space: btrfs | none" btrfs)
    [[ $EXTRA_SPACE =~ ^(btrfs|none)$ ]] && break
  done
  if [[ $EXTRA_SPACE == btrfs ]]; then
    while :; do
      EXTRA_MNT=$(ask "  mountpoint" /data/extra)
      [[ $EXTRA_MNT == /data/* && $EXTRA_MNT =~ ^/[A-Za-z0-9._/-]+$ \
        && $EXTRA_MNT != *'/../'* && $EXTRA_MNT != */.. \
        && $EXTRA_MNT != *'/./'* && $EXTRA_MNT != */. ]] && break
      echo "  enter a mountpoint below /data without whitespace or dot segments"
    done
  fi
fi

hr
echo " TPM2 unlock (passphrase always remains as fallback)"
hr
echo " TPM2 present in live system: $HAVE_TPM"
echo " TPM enrollment is performed after the first boot; no MOK enrollment is needed."
while :; do
  TPM_PCRS=$(ask "PCRs to seal against" 7)
  [[ $TPM_PCRS =~ ^[0-9]+(,[0-9]+)*$ ]] && break
done
TPM_ENROLL=later

# ═════════════════════════ 3. SUMMARY / CONFIRM ═════════════════════════
clear
hr
cat <<EOF
 Debian 13 ($SUITE) — Btrfs RAID1 on LUKS2, passphrase + TPM2
   DISK1        : $DISK1  (${S1} MiB)
   DISK2        : $DISK2  (${S2} MiB)
   layout/disk  : ${EFI_MB}M ESP | ${BPOOL_MB}M /boot | ${SWAP_MB}M swap | ${ROOT_MB}M root | ${DATA_MB}M data
   /boot        : ${BPOOL_MB}M unencrypted Btrfs RAID1
   /            : ${ROOT_GIB} GiB Btrfs RAID1 on LUKS2
   /home,/data  : ${DATA_MB} MiB Btrfs RAID1 on LUKS2
   leftover     : ${EXTRA_MB} MiB on $BIG_DISK → $(
     [[ $EXTRA_SPACE == btrfs ]] \
       && echo "LUKS → Btrfs at $EXTRA_MNT (NO redundancy)" || echo "unused")
   TPM2         : present=$HAVE_TPM  enroll=$TPM_ENROLL  PCRs=$TPM_PCRS
   host / user  : $NEW_HOSTNAME / $NEW_USER   tz=$TIMEZONE  locale=$LOCALE

 Secure Boot uses Debian-signed shim, GRUB and kernel packages; no DKMS/MOK.
 ALL DATA ON $DISK1 AND $DISK2 WILL BE DESTROYED.
EOF
hr
read -rp "Type YES to continue: " ok
[[ $ok == YES ]] || { echo aborted; exit 0; }
ask_secret "LUKS passphrase (the one you will type at boot)" 8
LUKS_PASS=$REPLY

# ═════════════════════════ 4. LIVE-ENV TOOLS ═════════════════════════
cat > /etc/apt/sources.list.d/debian-btrfs-installer.list <<EOF
deb $MIRROR $SUITE main contrib non-free-firmware
deb $MIRROR $SUITE-updates main contrib non-free-firmware
deb $SECURITY_MIRROR $SUITE-security main contrib non-free-firmware
EOF
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  debootstrap gdisk btrfs-progs cryptsetup systemd-cryptsetup \
  tpm2-tools dosfstools efibootmgr rsync util-linux lvm2 mdadm

holders_of() {
  local b
  b=$(basename "$(readlink -f "$1")") || true
  ls /sys/class/block/"$b"/holders/ 2>/dev/null | tr '\n' ' ' || true
  findmnt -rno TARGET -S "$(readlink -f "$1")" 2>/dev/null | tr '\n' ' ' || true
  return 0
}
assert_free() {
  local p h
  for p in "$@"; do
    h=$(holders_of "$p")
    [[ -z ${h// } ]] || die "$p is in use by: $h"
  done
}

part() {
  local d=$1 n=$2
  if [[ $d == /dev/disk/by-* ]]; then
    echo "${d}-part${n}"
  elif [[ $d =~ [0-9]$ ]]; then
    echo "${d}p${n}"
  else
    echo "${d}${n}"
  fi
}

release_disks() {
  echo "→ releasing $DISK1 and $DISK2 from mounts and mappings"
  local d real p mp active parent pool vdev uses_target
  while IFS= read -r active; do
    [[ -b $active ]] || continue
    while IFS= read -r parent; do
      for d in "$DISK1" "$DISK2"; do
        [[ $(readlink -f "$parent") == $(readlink -f "$d") ]] \
          && { swapoff "$active" 2>/dev/null || true; break 2; }
      done
    done < <(lsblk -s -nrpo NAME "$active" 2>/dev/null)
  done < <(swapon --show=NAME --noheadings --raw 2>/dev/null)
  if mountpoint -q "$T" 2>/dev/null; then
    umount -R "$T" 2>/dev/null || umount -Rl "$T" 2>/dev/null || true
  fi
  for mp in $(findmnt -rno TARGET 2>/dev/null | grep "^$T/" | sort -r); do
    umount -l "$mp" 2>/dev/null || true
  done
  if command -v zpool >/dev/null 2>&1; then
    for pool in $(zpool list -H -o name 2>/dev/null); do
      uses_target=no
      while IFS= read -r vdev; do
        [[ -b $vdev ]] || continue
        while IFS= read -r parent; do
          for d in "$DISK1" "$DISK2"; do
            [[ $(readlink -f "$parent") == $(readlink -f "$d") ]] \
              && { uses_target=yes; break 3; }
          done
        done < <(lsblk -s -nrpo NAME "$vdev" 2>/dev/null)
      done < <(zpool status -P "$pool" 2>/dev/null \
        | awk '$1 ~ /^\/dev\// {print $1}')
      if [[ $uses_target == yes ]]; then
        zpool export "$pool" 2>/dev/null || zpool export -f "$pool" 2>/dev/null || true
      fi
    done
  fi
  for m in luks-root1 luks-root2 luks-data1 luks-data2 luks-extra; do
    cryptsetup close "$m" 2>/dev/null || true
  done
  for d in "$DISK1" "$DISK2"; do
    real=$(readlink -f "$d")
    for mp in $(lsblk -nrpo MOUNTPOINTS "$real" 2>/dev/null \
      | tr ' ' '\n' | grep '^/' | sort -ur); do
      umount -l "$mp" 2>/dev/null || true
    done
    for p in "$real" "$real"?*; do
      [[ -b $p ]] || continue
      btrfs device scan --forget "$p" 2>/dev/null || true
      if command -v zpool >/dev/null 2>&1; then
        zpool labelclear -f "$p" 2>/dev/null || true
      fi
      wipefs -af "$p" >/dev/null 2>&1 || true
    done
  done
  udevadm settle || true
}

release_disks
assert_free "$DISK1" "$DISK2"

# ═════════════════════════ 5. PARTITIONING ═════════════════════════
scrub_new_partitions() {
  local d=$1 n p
  for n in 1 2 3 4 5 6; do
    p=$(part "$d" "$n")
    [[ -b $p ]] || continue
    btrfs device scan --forget "$p" 2>/dev/null || true
    wipefs -af "$p" >/dev/null 2>&1 || true
    dd if=/dev/zero of="$p" bs=1M count=4 conv=fsync status=none 2>/dev/null || true
  done
}

partition_disk() {
  local d=$1
  echo "→ partitioning $d"
  wipefs -af "$d" >/dev/null
  blkdiscard -f "$d" 2>/dev/null || true
  sgdisk --zap-all "$d" >/dev/null
  sgdisk -n1:1M:+${EFI_MB}M  -t1:EF00 -c1:EFI "$d" >/dev/null
  sgdisk -n2:0:+${BPOOL_MB}M -t2:8300 -c2:boot "$d" >/dev/null
  sgdisk -n3:0:+${SWAP_MB}M  -t3:8200 -c3:swap "$d" >/dev/null
  sgdisk -n4:0:+${ROOT_MB}M  -t4:8309 -c4:luks-root "$d" >/dev/null
  sgdisk -n5:0:+${DATA_MB}M  -t5:8309 -c5:luks-data "$d" >/dev/null
  if [[ $EXTRA_SPACE == btrfs && $d == "$BIG_DISK" ]]; then
    sgdisk -n6:0:0 -t6:8309 -c6:luks-extra "$d" >/dev/null
  fi
  partprobe "$d"
  udevadm settle || true
  sleep 1
  scrub_new_partitions "$d"
  udevadm settle || true
}

partition_disk "$DISK1"
partition_disk "$DISK2"
udevadm settle || true
sleep 2

ESP1=$(part "$DISK1" 1); ESP2=$(part "$DISK2" 1)
BP1=$(part "$DISK1" 2); BP2=$(part "$DISK2" 2)
SW1=$(part "$DISK1" 3); SW2=$(part "$DISK2" 3)
RP1=$(part "$DISK1" 4); RP2=$(part "$DISK2" 4)
DP1=$(part "$DISK1" 5); DP2=$(part "$DISK2" 5)
XP=""
[[ $EXTRA_SPACE == btrfs ]] && XP=$(part "$BIG_DISK" 6)

for p in "$ESP1" "$ESP2" "$BP1" "$BP2" "$SW1" "$SW2" \
  "$RP1" "$RP2" "$DP1" "$DP2" ${XP:+"$XP"}; do
  [[ -b $p ]] || die "partition $p did not appear after partprobe"
done
assert_free "$ESP1" "$ESP2" "$BP1" "$BP2" "$SW1" "$SW2" \
  "$RP1" "$RP2" "$DP1" "$DP2" ${XP:+"$XP"}
mkfs.vfat -F32 -n EFI "$ESP1" >/dev/null
mkfs.vfat -F32 -n EFI2 "$ESP2" >/dev/null

# ═════════════════════════ 6. LUKS2 AND BTRFS FILESYSTEMS ═════════════════
luks_format() {
  printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --batch-mode --type luks2 \
    --cipher aes-xts-plain64 --key-size 512 --pbkdf argon2id --key-file=- "$1"
}
luks_open() {
  printf '%s' "$LUKS_PASS" | cryptsetup open \
    --key-file=- --allow-discards "$1" "$2"
}
echo "→ formatting encrypted root and data devices"
for p in "$RP1" "$RP2" "$DP1" "$DP2"; do luks_format "$p"; done
[[ -n $XP ]] && luks_format "$XP"
luks_open "$RP1" luks-root1
luks_open "$RP2" luks-root2
luks_open "$DP1" luks-data1
luks_open "$DP2" luks-data2
[[ -n $XP ]] && luks_open "$XP" luks-extra

echo "→ creating mirrored Btrfs filesystems"
mkfs.btrfs -f -m raid1 -d raid1 -L debian-boot "$BP1" "$BP2" >/dev/null
mkfs.btrfs -f -m raid1 -d raid1 -L debian-root \
  /dev/mapper/luks-root1 /dev/mapper/luks-root2 >/dev/null
mkfs.btrfs -f -m raid1 -d raid1 -L debian-data \
  /dev/mapper/luks-data1 /dev/mapper/luks-data2 >/dev/null
if [[ -n $XP ]]; then
  mkfs.btrfs -f -m dup -d single -L debian-extra /dev/mapper/luks-extra >/dev/null
fi

create_subvolumes() {
  local device=$1 dir=$2
  shift 2
  mkdir -p "$dir"
  mount -o subvolid=5 "$device" "$dir"
  for subvol in "$@"; do btrfs subvolume create "$dir/$subvol" >/dev/null; done
  umount "$dir"
  rmdir "$dir"
}
create_subvolumes "$BP1" "$T/.boot-top" @boot
create_subvolumes /dev/mapper/luks-root1 "$T/.root-top" \
  @ @var @var-log @var-spool @var-cache @var-tmp @srv @tmp @root
create_subvolumes /dev/mapper/luks-data1 "$T/.data-top" @home @data
if [[ -n $XP ]]; then
  create_subvolumes /dev/mapper/luks-extra "$T/.extra-top" @extra
fi

mount -o subvol=@,compress=zstd:3,noatime,degraded \
  /dev/mapper/luks-root1 "$T"
mkdir -p "$T/boot" "$T/home" "$T/data" "$T/var/log" "$T/var/spool" \
  "$T/var/cache" "$T/var/tmp" "$T/srv" "$T/tmp" "$T/root"
mount -o subvol=@boot,noatime "$BP1" "$T/boot"
mount -o subvol=@home,compress=zstd:3,noatime,degraded \
  /dev/mapper/luks-data1 "$T/home"
mount -o subvol=@data,compress=zstd:3,noatime,degraded \
  /dev/mapper/luks-data1 "$T/data"
mount -o subvol=@var,compress=zstd:3,noatime,degraded \
  /dev/mapper/luks-root1 "$T/var"
mkdir -p "$T/var/log" "$T/var/spool" "$T/var/cache" "$T/var/tmp"
mount -o subvol=@var-log,compress=zstd:3,noatime,degraded \
  /dev/mapper/luks-root1 "$T/var/log"
mount -o subvol=@var-spool,compress=zstd:3,noatime,degraded \
  /dev/mapper/luks-root1 "$T/var/spool"
mount -o subvol=@var-cache,compress=zstd:3,noatime,degraded \
  /dev/mapper/luks-root1 "$T/var/cache"
mount -o subvol=@var-tmp,compress=zstd:3,noatime,degraded \
  /dev/mapper/luks-root1 "$T/var/tmp"
mount -o subvol=@srv,compress=zstd:3,noatime,degraded \
  /dev/mapper/luks-root1 "$T/srv"
mount -o subvol=@tmp,compress=zstd:3,noatime,degraded \
  /dev/mapper/luks-root1 "$T/tmp"
mount -o subvol=@root,compress=zstd:3,noatime,degraded \
  /dev/mapper/luks-root1 "$T/root"
chmod 1777 "$T/tmp" "$T/var/tmp"
chmod 700 "$T/root"
if [[ -n $XP ]]; then
  mkdir -p "$T$EXTRA_MNT"
  mount -o subvol=@extra,noatime /dev/mapper/luks-extra "$T$EXTRA_MNT"
fi

# ═════════════════════════ 7. DEBOOTSTRAP ═════════════════════════
echo "→ debootstrap $SUITE"
[[ -e /usr/share/debootstrap/scripts/$SUITE ]] \
  || die "debootstrap suite '$SUITE' not supported by this live environment"
debootstrap --include=ca-certificates --arch=amd64 "$SUITE" "$T" "$MIRROR"

# ═════════════════════════ 8. FSTAB / CRYPTTAB ═══════════════════════
U_RP1=$(cryptsetup luksUUID "$RP1")
U_RP2=$(cryptsetup luksUUID "$RP2")
U_DP1=$(cryptsetup luksUUID "$DP1")
U_DP2=$(cryptsetup luksUUID "$DP2")
PU_ESP1=$(blkid -s PARTUUID -o value "$ESP1")
PU_ESP2=$(blkid -s PARTUUID -o value "$ESP2")
PU_SW1=$(blkid -s PARTUUID -o value "$SW1")
PU_SW2=$(blkid -s PARTUUID -o value "$SW2")
BOOT_UUID=$(blkid -s UUID -o value "$BP1")
ROOT_UUID=$(blkid -s UUID -o value /dev/mapper/luks-root1)
DATA_UUID=$(blkid -s UUID -o value /dev/mapper/luks-data1)
EXTRA_UUID=""
[[ -n $XP ]] && EXTRA_UUID=$(cryptsetup luksUUID "$XP")

cat > "$T/etc/fstab" <<EOF
UUID=$ROOT_UUID      /          btrfs  subvol=@,compress=zstd:3,noatime,degraded  0 0
UUID=$BOOT_UUID      /boot      btrfs  subvol=@boot,noatime  0 0
UUID=$ROOT_UUID      /var       btrfs  subvol=@var,compress=zstd:3,noatime,degraded  0 0
UUID=$ROOT_UUID      /var/log   btrfs  subvol=@var-log,compress=zstd:3,noatime,degraded  0 0
UUID=$ROOT_UUID      /var/spool btrfs  subvol=@var-spool,compress=zstd:3,noatime,degraded  0 0
UUID=$ROOT_UUID      /var/cache btrfs  subvol=@var-cache,compress=zstd:3,noatime,degraded  0 0
UUID=$ROOT_UUID      /var/tmp   btrfs  subvol=@var-tmp,compress=zstd:3,noatime,degraded  0 0
UUID=$ROOT_UUID      /srv       btrfs  subvol=@srv,compress=zstd:3,noatime,degraded  0 0
UUID=$ROOT_UUID      /tmp       btrfs  subvol=@tmp,compress=zstd:3,noatime,degraded  0 0
UUID=$ROOT_UUID      /root      btrfs  subvol=@root,compress=zstd:3,noatime,degraded  0 0
UUID=$DATA_UUID      /home      btrfs  subvol=@home,compress=zstd:3,noatime,degraded  0 0
UUID=$DATA_UUID      /data      btrfs  subvol=@data,compress=zstd:3,noatime,degraded  0 0
PARTUUID=$PU_ESP1    /boot/efi  vfat   umask=0077  0 1
PARTUUID=$PU_ESP2    /boot/efi2 vfat   umask=0077,nofail  0 1
/dev/mapper/swap1    none       swap   sw,nofail  0 0
/dev/mapper/swap2    none       swap   sw,nofail  0 0
EOF
if [[ -n $XP ]]; then
  printf 'UUID=%s  %s  btrfs  subvol=@extra,noatime,nofail  0 0\n' \
    "$(blkid -s UUID -o value /dev/mapper/luks-extra)" "$EXTRA_MNT" >> "$T/etc/fstab"
fi

cat > "$T/etc/crypttab" <<EOF
luks-root1  UUID=$U_RP1       none          luks,discard,tpm2-device=auto,x-initrd.attach,nofail
luks-root2  UUID=$U_RP2       none          luks,discard,tpm2-device=auto,x-initrd.attach,nofail
luks-data1  UUID=$U_DP1       none          luks,discard,tpm2-device=auto,nofail
luks-data2  UUID=$U_DP2       none          luks,discard,tpm2-device=auto,nofail
swap1       PARTUUID=$PU_SW1  /dev/urandom  plain,swap,cipher=aes-xts-plain64,size=512,discard,nofail
swap2       PARTUUID=$PU_SW2  /dev/urandom  plain,swap,cipher=aes-xts-plain64,size=512,discard,nofail
EOF
[[ -n $XP ]] && printf 'luks-extra  UUID=%s  none  luks,discard,tpm2-device=auto,nofail\n' \
  "$EXTRA_UUID" >> "$T/etc/crypttab"

RD_LUKS="rd.luks.name=$U_RP1=luks-root1 rd.luks.name=$U_RP2=luks-root2"
RD_LUKS+=" rd.luks.options=discard,tpm2-device=auto,nofail"
ROOT_CMDLINE="root=UUID=$ROOT_UUID rootflags=subvol=@,degraded $RD_LUKS"

# ═════════════════════════ 9. CHROOT ════════════════════════════════
for fs in dev proc sys; do
  mount --rbind "/$fs" "$T/$fs"
  mount --make-rslave "$T/$fs"
done
mount -t tmpfs tmpfs "$T/run"
mkdir -p "$T/run/lock" "$T/boot/efi" "$T/boot/efi2"
mount "$ESP1" "$T/boot/efi"
mount "$ESP2" "$T/boot/efi2"
rm -f "$T/etc/resolv.conf"
cp -L /etc/resolv.conf "$T/etc/resolv.conf"

cat > "$T/root/chroot-setup.sh" <<'CHROOT'
#!/usr/bin/env bash
set -eu
export DEBIAN_FRONTEND=noninteractive

echo "$NEW_HOSTNAME" > /etc/hostname
printf '127.0.0.1 localhost\n127.0.1.1 %s\n::1 localhost ip6-localhost ip6-loopback\n' \
  "$NEW_HOSTNAME" > /etc/hosts
rm -f /etc/apt/sources.list
cat > /etc/apt/sources.list.d/debian.sources <<EOS
Types: deb
URIs: $MIRROR
Suites: $SUITE $SUITE-updates
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: $SECURITY_MIRROR
Suites: $SUITE-security
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOS
apt-get update
apt-get install -y --no-install-recommends locales tzdata
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
echo "$TIMEZONE" > /etc/timezone
for locale in "$LOCALE" en_US.UTF-8 de_DE.UTF-8; do
  grep -qxF "$locale UTF-8" /etc/locale.gen \
    || printf '%s UTF-8\n' "$locale" >> /etc/locale.gen
done
locale-gen
update-locale LANG="$LOCALE"

mkdir -p /etc/dracut.conf.d
cat > /etc/dracut.conf.d/90-btrfs-luks-tpm.conf <<'EOS'
hostonly="no"
hostonly_cmdline="no"
add_dracutmodules+=" btrfs crypt tpm2-tss "
compress="zstd"
EOS

apt-get install -y --no-install-recommends dracut
apt-get install -y --no-install-recommends \
  linux-image-amd64 btrfs-progs \
  cryptsetup systemd-cryptsetup tpm2-tools \
  grub-efi-amd64 grub-efi-amd64-signed shim-signed efibootmgr \
  dosfstools sbsigntool \
  openssh-server sudo systemd systemd-resolved \
  rsync curl less vim-tiny bash-completion zstd ufw locales tzdata

KVER=$(ls -1 /lib/modules | sort -V | tail -n 1)
[[ -n $KVER ]] || { echo "ERROR: no installed kernel modules"; exit 1; }
KERNEL=/boot/vmlinuz-$KVER
[[ -s $KERNEL ]] || { echo "ERROR: installed kernel image is missing"; exit 1; }
sbverify --list "$KERNEL" >/dev/null \
  || { echo "ERROR: Debian kernel image is not signed for Secure Boot"; exit 1; }

sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$ROOT_CMDLINE\"|" \
  /etc/default/grub
sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=""|' /etc/default/grub
sed -i 's|^GRUB_TIMEOUT_STYLE=.*|GRUB_TIMEOUT_STYLE=menu|' /etc/default/grub
sed -i 's|^GRUB_TIMEOUT=.*|GRUB_TIMEOUT=3|' /etc/default/grub
grep -q '^GRUB_TERMINAL' /etc/default/grub \
  || echo 'GRUB_TERMINAL=console' >> /etc/default/grub

systemctl enable ssh systemd-networkd systemd-resolved
cat > /etc/ssh/sshd_config.d/10-password-login.conf <<'EOS'
PasswordAuthentication yes
KbdInteractiveAuthentication yes
PermitRootLogin no
EOS

ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw --force enable

dracut -f --regenerate-all
[[ $(grub-probe /boot) == btrfs ]] || { echo "ERROR: /boot is not Btrfs"; exit 1; }
update-grub
grub-install --target=x86_64-efi --efi-directory=/boot/efi \
  --bootloader-id=debian --uefi-secure-boot --recheck --no-floppy
grub-install --target=x86_64-efi --efi-directory=/boot/efi2 \
  --bootloader-id=debian --uefi-secure-boot --recheck --no-floppy --no-nvram
rsync -a --delete /boot/efi/ /boot/efi2/

cat > /usr/local/sbin/sync-efi <<'EOS'
#!/bin/sh
mountpoint -q /boot/efi2 && rsync -a --delete /boot/efi/ /boot/efi2/
EOS
chmod +x /usr/local/sbin/sync-efi

useradd -m -s /bin/bash -G sudo,adm "$NEW_USER"
echo "$NEW_USER:$USER_PASS" | chpasswd
passwd -l root

mkdir -p /etc/systemd/network
cat > /etc/systemd/network/20-wired.network <<'EOS'
[Match]
Name=en*

[Network]
DHCP=yes
EOS
CHROOT

chroot "$T" /usr/bin/env -i \
  PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
  NEW_HOSTNAME="$NEW_HOSTNAME" NEW_USER="$NEW_USER" USER_PASS="$USER_PASS" \
  TIMEZONE="$TIMEZONE" LOCALE="$LOCALE" SUITE="$SUITE" MIRROR="$MIRROR" \
  SECURITY_MIRROR="$SECURITY_MIRROR" ROOT_CMDLINE="$ROOT_CMDLINE" \
  bash /root/chroot-setup.sh
rm -f "$T/root/chroot-setup.sh"

ln -sf ../run/systemd/resolve/stub-resolv.conf "$T/etc/resolv.conf"
efibootmgr -c -g -d "$(readlink -f "$DISK2")" -p 1 \
  -L "Debian (disk 2)" -l '\EFI\debian\shimx64.efi' >/dev/null \
  || die "could not add NVRAM entry for DISK2; redundant boot is not configured"

# ═════════════════════════ 10. TPM ENROLLMENT HELPER ═════════════════
cat > "$T/usr/local/sbin/enroll-tpm2" <<'EOS'
#!/usr/bin/env bash
set -eu
PCRS="${1:-7}"
[[ -c /dev/tpmrm0 ]] || { echo "ERROR: no TPM2 device (/dev/tpmrm0)"; exit 1; }
umask 077
PASSWORD_FILE=$(mktemp /run/enroll-tpm2.XXXXXX)
trap 'rm -f "$PASSWORD_FILE"' EXIT
read -rsp "Current LUKS passphrase: " PASSWORD; echo
printf '%s' "$PASSWORD" > "$PASSWORD_FILE"
unset PASSWORD
ENROLLED=0
SKIPPED=0
while read -r name src; do
  dev=$(blkid -U "${src#UUID=}" 2>/dev/null || true)
  if [[ -z $dev || ! -b $dev ]]; then
    echo "WARNING: $name ($src) is unavailable; skipping it." >&2
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  echo "→ $dev"
  systemd-cryptenroll --unlock-key-file="$PASSWORD_FILE" --wipe-slot=tpm2 "$dev"
  systemd-cryptenroll --unlock-key-file="$PASSWORD_FILE" \
    --tpm2-device=auto --tpm2-pcrs="$PCRS" "$dev"
  ENROLLED=$((ENROLLED + 1))
done < <(awk '$3=="none" && $4 ~ /luks/ {print $1, $2}' /etc/crypttab)
(( ENROLLED > 0 )) || { echo "ERROR: no available LUKS devices were enrolled." >&2; exit 1; }
echo "Done — TPM2 unlock enrolled on $ENROLLED available device(s); the passphrase remains as fallback."
(( SKIPPED == 0 )) || echo "WARNING: $SKIPPED unavailable LUKS device(s) were skipped; rerun after they return."
EOS
chmod +x "$T/usr/local/sbin/enroll-tpm2"

# ═════════════════════════ 11. TEARDOWN ════════════════════════════
echo "→ unmounting installation filesystems"
sync
for try in 1 2 3; do
  umount -R "$T" 2>/dev/null && break
  sleep 2
done
mountpoint -q "$T" 2>/dev/null && umount -Rl "$T" 2>/dev/null || true
for m in luks-root1 luks-root2 luks-data1 luks-data2 ${XP:+luks-extra}; do
  cryptsetup close "$m" 2>/dev/null || true
done

hr
cat <<EOF
 DONE. Remove the install medium and reboot.

 First boot : enter the LUKS passphrase; no MOK enrollment is required.
              After login: sudo enroll-tpm2 $TPM_PCRS
 Login      : ssh $NEW_USER@<ip> (password)
 Verify TPM : sudo cryptsetup luksDump $RP1 | grep -A3 tpm2
 EFI sync   : sudo sync-efi (after shim-signed/grub package updates)
 Scrub      : sudo btrfs scrub start /
 Filesystems: Btrfs RAID1 /boot, / (LUKS), /home and /data (LUKS)
$([[ -n $XP ]] && echo " Extra      : $EXTRA_MNT (single disk, no redundancy)")

 KEEP THE PASSPHRASE OFFLINE. It is the recovery path if TPM unlock fails.
EOF
hr
