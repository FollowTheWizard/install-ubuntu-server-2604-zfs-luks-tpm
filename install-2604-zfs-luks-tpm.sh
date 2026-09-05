#!/usr/bin/env bash
# =============================================================================
#  Ubuntu Server 26.04 LTS (resolute) — interactive installer  (rev. 8.1)
#  2-disk ZFS mirror · LUKS2 FDE · unlock by passphrase OR TPM2 · dracut · GRUB/UEFI
#  SPDX-License-Identifier: MIT — NO WARRANTY. DESTROYS DATA on the disks you select.
#
#  Boot the Ubuntu 26.04(.1) live ISO (Desktop "Try Ubuntu" or Server shell) → network up →
#     sudo -i ; bash install-2604-zfs-luks-tpm.sh
#  Safe to re-run at any point: releases target disks from mounts/pools/holders itself.
# =============================================================================
set -eu
# pipefail is deliberately NOT set: helpers pipe commands that legitimately return
# non-zero ("nothing found") into tr/head; pipefail + set -e kills the script silently.

SUITE=resolute
MIRROR=http://archive.ubuntu.com/ubuntu
EFI_MB=1024; BPOOL_MB=2048
SWAP_MB=4096          # encrypted per disk, random key each boot — 0 to disable
RPOOL=rpool; BPOOL=bpool          # bpool name is mandatory for GRUB/ZFS
T=/mnt

die()  { echo "ERROR: $*" >&2; exit 1; }
hr()   { printf '%*s\n' 78 '' | tr ' ' '-'; }
ask()  { local r; read -rp "$1 [$2]: " r; echo "${r:-$2}"; }
ask_secret() {
  local a b; while :; do
    read -rsp "$1: " a; echo; read -rsp "Repeat: " b; echo
    [[ $a == "$b" ]] || { echo "  mismatch, try again"; continue; }
    (( ${#a} >= $2 )) || { echo "  too short (min $2 chars)"; continue; }
    REPLY=$a; return; done; }

[[ $EUID -eq 0 ]] || die "run as root (sudo -i)"
[[ -d /sys/firmware/efi ]] || die "not booted in UEFI mode — enable UEFI and Secure Boot in firmware"
HAVE_TPM=no; [[ -c /dev/tpmrm0 ]] && HAVE_TPM=yes

# ═════════════════════════ 1. DISK SELECTION ═════════════════════════
by_id() {
  local real l; real=$(readlink -f "$1")
  for l in /dev/disk/by-id/*; do
    [[ $l == *-part* || $l == */wwn-* || $l == */nvme-eui.* ]] && continue
    [[ $(readlink -f "$l") == "$real" ]] && { echo "$l"; return; }
  done; echo "$1"; }

LIVE_DEV=""
for m in /cdrom /run/live/medium /media/cdrom; do
  src=$(findmnt -no SOURCE "$m" 2>/dev/null) || continue
  [[ -n $src ]] || continue
  pk=$(lsblk -no PKNAME "$src" 2>/dev/null | head -1) || true
  LIVE_DEV=${pk:+/dev/$pk}; LIVE_DEV=${LIVE_DEV:-$src}
  break
done

mapfile -t CAND < <(lsblk -dpno NAME,TYPE | awk '$2=="disk"{print $1}' | grep -vE '/dev/(loop|sr|zram|fd|ram)')
DISKS=()
for d in "${CAND[@]}"; do
  [[ -n $LIVE_DEV && $(readlink -f "$d") == $(readlink -f "$LIVE_DEV") ]] || DISKS+=("$d")
done
(( ${#DISKS[@]} >= 2 )) || die "need at least two disks, found ${#DISKS[@]}"

hr; echo " Available disks (live medium ${LIVE_DEV:-?} excluded):"; hr
for i in "${!DISKS[@]}"; do
  d=${DISKS[$i]}
  printf ' %2d) %-14s %8s  %-28s %s\n' \
    "$((i+1))" "$d" "$(lsblk -dno SIZE "$d")" \
    "$(lsblk -dno MODEL "$d" | tr -s ' ')" "$(by_id "$d")"
done; hr

pick() { local n; while :; do read -rp "$1: " n
  [[ $n =~ ^[0-9]+$ && n -ge 1 && n -le ${#DISKS[@]} ]] && { echo "${DISKS[$((n-1))]}"; return; }
  echo "  enter 1-${#DISKS[@]}"; done; }
D1=$(pick "Number of FIRST disk ")
while :; do D2=$(pick "Number of SECOND disk"); [[ $D2 != "$D1" ]] && break
  echo "  must differ from first disk"; done
DISK1=$(by_id "$D1"); DISK2=$(by_id "$D2")

mib() { echo $(( $(blockdev --getsize64 "$1") / 1048576 )); }
S1=$(mib "$DISK1"); S2=$(mib "$DISK2")
SMALL=$(( S1 < S2 ? S1 : S2 )); BIG=$(( S1 > S2 ? S1 : S2 ))
BIG_DISK=$DISK1; (( S2 > S1 )) && BIG_DISK=$DISK2
EXTRA_MB=$(( BIG - SMALL ))

# ═════════════════════════ 2. SYSTEM SETTINGS ═════════════════════════
hr; echo " System settings (Enter accepts the [default])"; hr
NEW_HOSTNAME=$(ask "Hostname" ubuntu-server)
while :; do NEW_USER=$(ask "Admin username" admin)
  [[ $NEW_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && break; echo "  invalid username"; done
echo " (this password is also the SSH login — choose a strong one)"
ask_secret "Password for $NEW_USER" 10; USER_PASS=$REPLY
while :; do TIMEZONE=$(ask "Timezone" "Etc/UTC")
  [[ -f /usr/share/zoneinfo/$TIMEZONE ]] && break
  echo "  unknown timezone (e.g. Europe/Berlin)"; done
while :; do LOCALE=$(ask "Locale" en_US.UTF-8)
  grep -q "^${LOCALE} " /usr/share/i18n/SUPPORTED 2>/dev/null && break
  echo "  unknown locale (see /usr/share/i18n/SUPPORTED, e.g. de_DE.UTF-8)"; done

EXTRA_SPACE=none; EXTRA_POOL=xpool; EXTRA_MNT=/data
if (( EXTRA_MB >= 1024 )); then
  hr; echo " Storage"; hr
  echo " The disks differ: $BIG_DISK has $EXTRA_MB MiB more than the other."
  echo " A mirror can only be as large as the smaller disk. The remainder can become"
  echo " its own LUKS+TPM container with a separate UNMIRRORED pool (lost if that disk dies)."
  while :; do EXTRA_SPACE=$(ask "Leftover space: pool | none" pool)
    [[ $EXTRA_SPACE =~ ^(pool|none)$ ]] && break; done
  if [[ $EXTRA_SPACE == pool ]]; then
    EXTRA_POOL=$(ask "  name of that pool" xpool)
    EXTRA_MNT=$(ask  "  mountpoint" /data)
  fi
fi

hr; echo " TPM2 unlock (passphrase always remains as fallback)"; hr
echo " TPM2 present in live system: $HAVE_TPM"
echo " PCR 7   = Secure Boot policy/certs → survives firmware updates  (recommended)"
echo " PCR 0,7 = also firmware code       → passphrase needed after every firmware update"
while :; do TPM_PCRS=$(ask "PCRs to seal against" 7)
  [[ $TPM_PCRS =~ ^[0-9]+(,[0-9]+)*$ ]] && break; done
TPM_ENROLL=later
if [[ $HAVE_TPM == yes ]]; then
  while :; do TPM_ENROLL=$(ask "Enroll TPM2 now (live) or later (after first boot)? now|later" now)
    [[ $TPM_ENROLL =~ ^(now|later)$ ]] && break; done
else
  echo " No /dev/tpmrm0 — enrollment deferred to first boot (sudo enroll-tpm2)."
fi

ROOT_MB=$(( SMALL - 1 - EFI_MB - BPOOL_MB - SWAP_MB - 8 ))
(( ROOT_MB > 8192 )) || die "disks too small for this layout"

# ═════════════════════════ 3. SUMMARY / CONFIRM ═════════════════════════
clear; hr
cat <<EOF
 Ubuntu 26.04 LTS ($SUITE) — ZFS mirror on LUKS2, passphrase + TPM2
   DISK1        : $DISK1  (${S1} MiB)
   DISK2        : $DISK2  (${S2} MiB)
   layout/disk  : ${EFI_MB} MiB ESP | ${BPOOL_MB} MiB bpool | ${SWAP_MB} MiB swap | ${ROOT_MB} MiB LUKS→rpool
   leftover     : ${EXTRA_MB} MiB on $BIG_DISK → $(
     [[ $EXTRA_SPACE == pool ]] \
       && echo "LUKS → pool '$EXTRA_POOL' at $EXTRA_MNT (NO redundancy)" \
       || echo "unused" )
   TPM2         : present=$HAVE_TPM  enroll=$TPM_ENROLL  PCRs=$TPM_PCRS
   host / user  : $NEW_HOSTNAME / $NEW_USER   tz=$TIMEZONE  locale=$LOCALE
   SSH          : enabled, password login, root login disabled

 !!! ALL DATA ON $DISK1 AND $DISK2 WILL BE DESTROYED !!!
EOF
hr
read -rp "Type YES to continue: " ok; [[ $ok == YES ]] || { echo aborted; exit 0; }
ask_secret "LUKS passphrase (the one you will type at boot)" 8; LUKS_PASS=$REPLY

# ═════════════════════════ 4. LIVE-ENV TOOLS ═════════════════════════
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  debootstrap gdisk zfsutils-linux cryptsetup systemd-cryptsetup \
  tpm2-tools dosfstools efibootmgr rsync util-linux
modprobe zfs
zgenhostid -f

# ─── helpers ───
holders_of() {
  local b; b=$(basename "$(readlink -f "$1")") || true
  ls /sys/class/block/"$b"/holders/ 2>/dev/null | tr '\n' ' ' || true
  findmnt -rno TARGET -S "$(readlink -f "$1")" 2>/dev/null | tr '\n' ' ' || true
  return 0; }
assert_free() {
  local p h; for p in "$@"; do h=$(holders_of "$p")
    [[ -z ${h// } ]] || die "$p is in use by: $h"; done; }

# ─── release_disks: works on a messy system, safe to re-run at any time ───
release_disks() {
  echo "→ releasing $DISK1 and $DISK2 from anything holding them"
  local d real p mp vg md h m name pool

  # 1. services that grab disks on the Server live ISO
  if systemctl is-active -q multipathd 2>/dev/null \
  || systemctl is-active -q multipathd.socket 2>/dev/null; then
    echo "  stopping multipathd"
    systemctl stop multipathd.socket multipathd 2>/dev/null || true
    multipath -F 2>/dev/null || true
  fi
  swapoff -a 2>/dev/null || true

  # 2. unmount target tree from every mount namespace (live services have private namespaces)
  for p in $(grep -rl "$T" /proc/[0-9]*/mountinfo 2>/dev/null | cut -d/ -f3 | sort -u); do
    [[ -d /proc/$p ]] || continue
    if [[ $(readlink /proc/$p/ns/mnt 2>/dev/null) != $(readlink /proc/self/ns/mnt) ]]; then
      nsenter -t "$p" -m -- sh -c "umount -Rl '$T' 2>/dev/null; true" 2>/dev/null || true
    fi
  done
  if mountpoint -q "$T" 2>/dev/null \
  || findmnt -rno TARGET 2>/dev/null | grep -q "^$T"; then
    echo "  unmounting $T"
    umount -R "$T" 2>/dev/null || umount -Rl "$T" 2>/dev/null || true
  fi

  # 3. every imported ZFS pool, whatever its name
  zfs unmount -a 2>/dev/null || true
  for pool in $(zpool list -H -o name 2>/dev/null); do
    echo "  exporting pool $pool"
    zpool export "$pool" 2>/dev/null || zpool export -f "$pool" 2>/dev/null || true
  done

  for d in "$DISK1" "$DISK2"; do
    real=$(readlink -f "$d")

    # 4. mounts of any partition of the disk
    for mp in $(lsblk -nrpo MOUNTPOINTS "$real" 2>/dev/null \
                | tr ' ' '\n' | grep '^/' | sort -ur); do
      echo "  unmounting $mp"; umount -l "$mp" 2>/dev/null || true
    done

    # 5. LVM VGs and md arrays
    for vg in $(pvs --noheadings -o vg_name "$real" "$real"?* 2>/dev/null | sort -u); do
      echo "  deactivating VG $vg"; vgchange -an "$vg" 2>/dev/null || true
    done
    for md in $(lsblk -nrpo NAME,TYPE "$real" 2>/dev/null \
                | awk '$2 ~ /^raid/ {print $1}' | sort -u); do
      echo "  stopping $md"; mdadm --stop "$md" 2>/dev/null || true
    done

    # 6. dm/md holders of ANY name — three passes so stacks unwind bottom-up
    local pass hh
    for pass in 1 2 3; do
      for p in "$real" "$real"?*; do [[ -b $p ]] || continue
        for h in /sys/class/block/"$(basename "$p")"/holders/*; do [[ -e $h ]] || continue
          m=$(basename "$h")
          for hh in /sys/class/block/"$m"/holders/*; do [[ -e $hh ]] || continue
            dmsetup remove -f "/dev/$(basename "$hh")" 2>/dev/null || true
          done
          if [[ $m == md* ]]; then
            echo "  stopping /dev/$m"; mdadm --stop "/dev/$m" 2>/dev/null || true
          else
            name=$(dmsetup info -c --noheadings -o name "/dev/$m" 2>/dev/null || echo "$m")
            echo "  closing $name"
            cryptsetup close "$name" 2>/dev/null \
              || dmsetup remove -f "/dev/$m" 2>/dev/null || true
          fi
        done
      done
      udevadm settle || true
    done

    # 7. stale signatures inside old partitions
    for p in "$real"?*; do [[ -b $p ]] || continue
      zpool labelclear -f "$p" 2>/dev/null || true
      wipefs -af "$p" >/dev/null 2>&1 || true
    done
  done
  udevadm settle || true
}
release_disks
assert_free "$DISK1" "$DISK2"

# ═════════════════════════ 5. PARTITIONING ═════════════════════════
part() {
  local d=$1 n=$2
  if   [[ $d == /dev/disk/by-* ]]; then echo "${d}-part${n}"
  elif [[ $d =~ [0-9]$ ]];        then echo "${d}p${n}"
  else                                 echo "${d}${n}"; fi; }

scrub_new_partitions() {
  local d=$1 n p h
  for n in 1 2 3 4 5; do p=$(part "$d" $n); [[ -b $p ]] || continue
    for h in /sys/class/block/"$(basename "$(readlink -f "$p")")"/holders/*; do
      [[ -e $h ]] && dmsetup remove -f "/dev/$(basename "$h")" 2>/dev/null || true; done
    zpool labelclear -f "$p" 2>/dev/null || true
    wipefs -af "$p" >/dev/null 2>&1 || true
    dd if=/dev/zero of="$p" bs=1M count=4 conv=fsync status=none 2>/dev/null || true
  done; }

partition_disk() {
  local d=$1
  echo "→ partitioning $d"
  wipefs -af "$d" >/dev/null
  blkdiscard -f "$d" 2>/dev/null || true
  sgdisk --zap-all "$d" >/dev/null
  sgdisk -n1:1M:+${EFI_MB}M   -t1:EF00 -c1:EFI        "$d" >/dev/null
  sgdisk -n2:0:+${BPOOL_MB}M  -t2:BE00 -c2:bpool      "$d" >/dev/null
  sgdisk -n3:0:+${SWAP_MB}M   -t3:8200 -c3:swap       "$d" >/dev/null
  sgdisk -n4:0:+${ROOT_MB}M   -t4:8309 -c4:luks-root  "$d" >/dev/null
  if [[ $EXTRA_SPACE == pool && $d == "$BIG_DISK" ]]; then
    sgdisk -n5:0:0 -t5:8309 -c5:luks-extra "$d" >/dev/null
  fi
  partprobe "$d"; udevadm settle || true; sleep 1
  scrub_new_partitions "$d"; udevadm settle || true; }

partition_disk "$DISK1"; partition_disk "$DISK2"
udevadm settle || true; sleep 2

ESP1=$(part "$DISK1" 1); ESP2=$(part "$DISK2" 1)
BP1=$(part  "$DISK1" 2); BP2=$(part  "$DISK2" 2)
SW1=$(part  "$DISK1" 3); SW2=$(part  "$DISK2" 3)
RP1=$(part  "$DISK1" 4); RP2=$(part  "$DISK2" 4)
XP=""; [[ $EXTRA_SPACE == pool ]] && XP=$(part "$BIG_DISK" 5)

for p in "$ESP1" "$ESP2" "$BP1" "$BP2" "$SW1" "$SW2" "$RP1" "$RP2" ${XP:+"$XP"}; do
  [[ -b $p ]] || die "partition $p did not appear after partprobe"; done
assert_free "$ESP1" "$ESP2" "$BP1" "$BP2" "$SW1" "$SW2" "$RP1" "$RP2" ${XP:+"$XP"}

mkfs.vfat -F32 -n EFI  "$ESP1" >/dev/null
mkfs.vfat -F32 -n EFI2 "$ESP2" >/dev/null

# ═════════════════════════ 6. LUKS2 + TPM2 ═════════════════════════
luks_format() {
  printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --batch-mode --type luks2 \
    --cipher aes-xts-plain64 --key-size 512 --pbkdf argon2id --key-file=- "$1"; }
luks_open() {
  printf '%s' "$LUKS_PASS" | cryptsetup open \
    --key-file=- --allow-discards --persistent "$1" "$2"; }
tpm_enroll() {
  PASSWORD="$LUKS_PASS" systemd-cryptenroll \
    --tpm2-device=auto --tpm2-pcrs="$TPM_PCRS" "$1"; }

echo "→ LUKS format"
luks_format "$RP1"; luks_format "$RP2"; [[ -n $XP ]] && luks_format "$XP"
luks_open "$RP1" luks-root1
luks_open "$RP2" luks-root2
[[ -n $XP ]] && luks_open "$XP" luks-extra

if [[ $TPM_ENROLL == now ]]; then
  echo "→ enrolling TPM2 (PCRs $TPM_PCRS)"
  tpm_enroll "$RP1"; tpm_enroll "$RP2"; [[ -n $XP ]] && tpm_enroll "$XP"
fi
udevadm settle || true

# ═════════════════════════ 7. ZFS POOLS & DATASETS ═════════════════════════
assert_free "$BP1" "$BP2"
echo "→ creating $BPOOL"
zpool create -f \
  -o ashift=12 -o autotrim=on -o compatibility=grub2 -o cachefile=/etc/zfs/zpool.cache \
  -O devices=off -O acltype=posixacl -O xattr=sa -O compression=lz4 \
  -O normalization=formD -O relatime=on -O canmount=off -O mountpoint=/boot \
  -R $T $BPOOL mirror "$BP1" "$BP2"

assert_free /dev/mapper/luks-root1 /dev/mapper/luks-root2
echo "→ creating $RPOOL"
zpool create -f \
  -o ashift=12 -o autotrim=on -o cachefile=/etc/zfs/zpool.cache \
  -O acltype=posixacl -O xattr=sa -O dnodesize=auto -O compression=zstd \
  -O normalization=formD -O relatime=on -O canmount=off -O mountpoint=/ \
  -R $T $RPOOL mirror /dev/mapper/luks-root1 /dev/mapper/luks-root2

zfs create -o canmount=off  -o mountpoint=none  $RPOOL/ROOT
zfs create -o canmount=noauto -o mountpoint=/   $RPOOL/ROOT/ubuntu
zfs mount $RPOOL/ROOT/ubuntu
zfs create -o canmount=off  -o mountpoint=none  $BPOOL/BOOT
zfs create -o mountpoint=/boot                  $BPOOL/BOOT/ubuntu

zfs create                                $RPOOL/home
zfs create -o mountpoint=/root            $RPOOL/home/root;  chmod 700 $T/root
zfs create -o canmount=off                $RPOOL/var
zfs create -o canmount=off                $RPOOL/var/lib
zfs create                                $RPOOL/var/log
zfs create                                $RPOOL/var/spool
zfs create -o com.sun:auto-snapshot=false $RPOOL/var/cache
zfs create -o com.sun:auto-snapshot=false $RPOOL/var/tmp;   chmod 1777 $T/var/tmp
zfs create                                $RPOOL/srv
zfs create -o com.sun:auto-snapshot=false $RPOOL/tmp;       chmod 1777 $T/tmp

if [[ -n $XP ]]; then
  assert_free /dev/mapper/luks-extra
  echo "→ creating $EXTRA_POOL (single disk, no redundancy)"
  zpool create -f \
    -o ashift=12 -o autotrim=on -o cachefile=/etc/zfs/zpool.cache \
    -O acltype=posixacl -O xattr=sa -O compression=zstd -O relatime=on \
    -O mountpoint="$EXTRA_MNT" -R $T "$EXTRA_POOL" /dev/mapper/luks-extra
fi

# ═════════════════════════ 8. DEBOOTSTRAP ═════════════════════════
echo "→ debootstrap $SUITE"
[[ -e /usr/share/debootstrap/scripts/$SUITE ]] \
  || ln -s gutsy /usr/share/debootstrap/scripts/$SUITE
debootstrap --arch=amd64 "$SUITE" $T "$MIRROR"

mkdir -p $T/etc/zfs
# Leave target cachefile EMPTY:
#   rpool → imported by dracut from kernel cmdline (root=ZFS=…), not the cachefile
#   bpool → imported by zfs-import-bpool.service, not zfs-import-cache
# An empty cachefile means zfs-import-cache harmlessly does nothing.
: > $T/etc/zfs/zpool.cache
cp /etc/hostid $T/etc/hostid

# ═════════════════════════ 9. fstab / crypttab ═════════════════════════
U_RP1=$(cryptsetup luksUUID "$RP1"); U_RP2=$(cryptsetup luksUUID "$RP2")
PU_ESP1=$(blkid -s PARTUUID -o value "$ESP1")
PU_ESP2=$(blkid -s PARTUUID -o value "$ESP2")
PU_SW1=$(blkid -s PARTUUID -o value "$SW1")
PU_SW2=$(blkid -s PARTUUID -o value "$SW2")

# Switch to legacy mountpoint so systemd can order /boot/efi after /boot.
# `zfs umount` removes an empty inherited mountpoint dir → recreate it first.
for ds_mp in \
    "$BPOOL/BOOT/ubuntu:/boot" \
    "$RPOOL/var/log:/var/log" \
    "$RPOOL/var/spool:/var/spool"; do
  ds=${ds_mp%%:*}; mp=${ds_mp##*:}
  zfs umount "$ds" 2>/dev/null || true
  zfs set mountpoint=legacy "$ds"
  mkdir -p "$T$mp"
  mount -t zfs "$ds" "$T$mp"
done

cat > $T/etc/fstab <<EOF
$BPOOL/BOOT/ubuntu  /boot       zfs   nodev,relatime,x-systemd.requires=zfs-import-bpool.service  0 0
$RPOOL/var/log      /var/log    zfs   nodev,relatime  0 0
$RPOOL/var/spool    /var/spool  zfs   nodev,relatime  0 0
PARTUUID=$PU_ESP1   /boot/efi   vfat  umask=0077,x-systemd.requires-mounts-for=/boot  0 1
PARTUUID=$PU_ESP2   /boot/efi2  vfat  umask=0077,nofail,x-systemd.requires-mounts-for=/boot  0 1
/dev/mapper/swap1   none        swap  sw,nofail  0 0
/dev/mapper/swap2   none        swap  sw,nofail  0 0
EOF

cat > $T/etc/crypttab <<EOF
luks-root1  UUID=$U_RP1       none          luks,discard,tpm2-device=auto
luks-root2  UUID=$U_RP2       none          luks,discard,tpm2-device=auto
swap1       PARTUUID=$PU_SW1  /dev/urandom  plain,swap,cipher=aes-xts-plain64,size=512,discard,nofail
swap2       PARTUUID=$PU_SW2  /dev/urandom  plain,swap,cipher=aes-xts-plain64,size=512,discard,nofail
EOF
[[ -n $XP ]] && echo \
  "luks-extra  UUID=$(cryptsetup luksUUID "$XP")  none  luks,discard,tpm2-device=auto,nofail" \
  >> $T/etc/crypttab

RD_LUKS="rd.luks.name=$U_RP1=luks-root1 rd.luks.name=$U_RP2=luks-root2 rd.luks.options=discard,tpm2-device=auto"

# ═════════════════════════ 10. CHROOT ═════════════════════════
for fs in dev proc sys; do mount --rbind /$fs $T/$fs; mount --make-rslave $T/$fs; done
mount -t tmpfs tmpfs $T/run; mkdir -p $T/run/lock
mkdir -p $T/boot/efi $T/boot/efi2
mount "$ESP1" $T/boot/efi
mount "$ESP2" $T/boot/efi2
# Give the chroot a working resolver (systemd-resolved stub is dead inside a chroot).
rm -f $T/etc/resolv.conf; cp -L /etc/resolv.conf $T/etc/resolv.conf

cat > $T/root/chroot-setup.sh <<'CHROOT'
#!/usr/bin/env bash
set -eu
export DEBIAN_FRONTEND=noninteractive

echo "$NEW_HOSTNAME" > /etc/hostname
printf '127.0.0.1 localhost\n127.0.1.1 %s\n::1 localhost ip6-localhost ip6-loopback\n' \
  "$NEW_HOSTNAME" > /etc/hosts
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime; echo "$TIMEZONE" > /etc/timezone

rm -f /etc/apt/sources.list
cat > /etc/apt/sources.list.d/ubuntu.sources <<EOS
Types: deb
URIs: $MIRROR
Suites: $SUITE $SUITE-updates $SUITE-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://security.ubuntu.com/ubuntu
Suites: $SUITE-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOS
apt-get update
apt-get install -y --no-install-recommends locales
locale-gen "$LOCALE"; update-locale LANG="$LOCALE"

# dracut config BEFORE the kernel so the first initrd is already correct
mkdir -p /etc/dracut.conf.d
cat > /etc/dracut.conf.d/90-zfs-luks-tpm.conf <<'EOS'
hostonly="no"
hostonly_cmdline="no"
add_dracutmodules+=" zfs crypt tpm2-tss "
compress="zstd"
EOS

# dracut + zfs-dracut BEFORE linux-image so no initramfs-tools initrd is built
apt-get install -y --no-install-recommends dracut zfs-dracut

apt-get install -y --no-install-recommends \
  linux-image-generic zfsutils-linux zfs-zed \
  cryptsetup systemd-cryptsetup tpm2-tools \
  grub-efi-amd64 grub-efi-amd64-signed shim-signed efibootmgr dosfstools \
  ubuntu-minimal openssh-server sudo-rs netplan.io systemd-resolved \
  rsync curl less vim-tiny bash-completion zstd

# GRUB
sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"root=ZFS=$RPOOL/ROOT/ubuntu $RD_LUKS\"|" \
  /etc/default/grub
sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=""|' /etc/default/grub
sed -i 's|^GRUB_TIMEOUT_STYLE=.*|GRUB_TIMEOUT_STYLE=menu|' /etc/default/grub
sed -i 's|^GRUB_TIMEOUT=.*|GRUB_TIMEOUT=3|' /etc/default/grub
grep -q '^GRUB_TERMINAL' /etc/default/grub || echo 'GRUB_TERMINAL=console' >> /etc/default/grub

# bpool import service (rev. 8.1):
#   - idempotent: if bpool already imported (e.g. by zfs-import-scan), exit 0
#   - otherwise wait up to 20 s for slow devices (USB enclosures) then force-import
#   - -f handles an unclean pool (power cut). Safe on a dedicated boot pool.
cat > /etc/systemd/system/zfs-import-bpool.service <<'EOS'
[Unit]
Description=Import ZFS boot pool (bpool)
DefaultDependencies=no
Before=zfs-import-scan.service
Before=zfs-import-cache.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '\
  zpool list bpool >/dev/null 2>&1 && exit 0; \
  for i in $(seq 1 20); do \
    zpool import -f -N -o cachefile=none bpool 2>/dev/null && exit 0; \
    sleep 1; \
  done; \
  zpool import -f -N -o cachefile=none bpool'

[Install]
WantedBy=zfs-import.target
EOS

systemctl enable \
  zfs-import-bpool.service zfs-import-cache zfs-mount zfs-zed zfs.target \
  ssh systemd-networkd systemd-resolved

# SSH: password login on, root login off
cat > /etc/ssh/sshd_config.d/10-password-login.conf <<'EOS'
PasswordAuthentication yes
KbdInteractiveAuthentication yes
PermitRootLogin no
EOS

# initrd
dracut -f --regenerate-all

# GRUB install
export ZPOOL_VDEV_NAME_PATH=YES
[[ $(grub-probe /boot) == zfs ]] || { echo "grub-probe /boot != zfs"; exit 1; }
update-grub
grub-install \
  --target=x86_64-efi --efi-directory=/boot/efi \
  --bootloader-id=ubuntu --recheck --no-floppy

# Mirror EFI to second disk
rsync -a --delete /boot/efi/ /boot/efi2/

cat > /usr/local/sbin/sync-efi <<'EOS'
#!/bin/sh
# Keep second EFI partition identical to the first.
# Run after shim-signed / grub-efi-amd64-signed updates.
mountpoint -q /boot/efi2 && rsync -a --delete /boot/efi/ /boot/efi2/
EOS
chmod +x /usr/local/sbin/sync-efi

# User
useradd -m -s /bin/bash -G sudo,adm "$NEW_USER"
echo "$NEW_USER:$USER_PASS" | chpasswd
passwd -l root

# Network (DHCP on all en* interfaces)
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
CHROOT

chroot $T /usr/bin/env \
  NEW_HOSTNAME="$NEW_HOSTNAME" \
  NEW_USER="$NEW_USER"         \
  USER_PASS="$USER_PASS"       \
  TIMEZONE="$TIMEZONE"         \
  LOCALE="$LOCALE"             \
  SUITE="$SUITE"               \
  MIRROR="$MIRROR"             \
  RPOOL="$RPOOL"               \
  RD_LUKS="$RD_LUKS"          \
  bash /root/chroot-setup.sh

rm -f $T/root/chroot-setup.sh

# Restore systemd-resolved stub resolver symlink for the installed system
ln -sf ../run/systemd/resolve/stub-resolv.conf $T/etc/resolv.conf

# NVRAM entry for second disk
efibootmgr -c -g -d "$(readlink -f "$DISK2")" -p 1 \
  -L "ubuntu (disk 2)" -l '\EFI\ubuntu\shimx64.efi' >/dev/null \
  || echo "!! could not add NVRAM entry for DISK2 — add manually in firmware if needed"

# ═════════════════════════ 11. enroll-tpm2 helper in target ═════════════════════════
cat > $T/usr/local/sbin/enroll-tpm2 <<'EOS'
#!/usr/bin/env bash
# (Re-)enroll TPM2 auto-unlock for every LUKS device in /etc/crypttab.
# Passphrase slot is never touched.
# Usage: sudo enroll-tpm2 [PCRS]   (default 7)
# Run after: first boot, firmware update, Secure Boot change, TPM clear, disk replacement.
set -eu
PCRS="${1:-7}"
[[ -c /dev/tpmrm0 ]] || { echo "ERROR: no TPM2 device (/dev/tpmrm0)"; exit 1; }
read -rsp "Current LUKS passphrase: " PASSWORD; echo; export PASSWORD
awk '$3=="none" && $4 ~ /luks/ {print $2}' /etc/crypttab | while read -r src; do
  dev=$(blkid -U "${src#UUID=}"); echo "→ $dev"
  systemd-cryptenroll --wipe-slot=tpm2 "$dev" 2>/dev/null || true
  systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs="$PCRS" "$dev"
done
echo "Done — TPM2 unlock active from next boot, passphrase remains as fallback."
EOS
chmod +x $T/usr/local/sbin/enroll-tpm2

# ═════════════════════════ 12. TEARDOWN (never fatal) ═════════════════════════
echo "→ unmounting / exporting"

# Kill any processes still rooted in the target (stray postinst daemons etc.)
for p in /proc/[0-9]*; do
  pid=${p#/proc/}; [[ $pid == "$$" || ! -d /proc/$pid ]] && continue
  root=$(readlink /proc/$pid/root 2>/dev/null)
  cwd=$(readlink  /proc/$pid/cwd  2>/dev/null)
  if [[ $root == "$T"* || $cwd == "$T"* ]]; then
    echo "  killing $(cat /proc/$pid/comm 2>/dev/null) ($pid) still rooted in $T"
    kill -9 "$pid" 2>/dev/null || true
  fi
done
sync

# Unmount from every mount namespace that still sees the target
for p in $(grep -rl "$T" /proc/[0-9]*/mountinfo 2>/dev/null | cut -d/ -f3 | sort -u); do
  [[ -d /proc/$p ]] || continue
  if [[ $(readlink /proc/$p/ns/mnt 2>/dev/null) != $(readlink /proc/self/ns/mnt) ]]; then
    nsenter -t "$p" -m -- sh -c "umount -Rl '$T' 2>/dev/null; true" 2>/dev/null || true
  fi
done

for try in 1 2 3; do umount -R "$T" 2>/dev/null && break; sleep 2; done
mountpoint -q "$T" 2>/dev/null && umount -Rl "$T" 2>/dev/null || true

zfs unmount -a 2>/dev/null || true
EXPORT_OK=yes
for try in 1 2 3 4 5; do
  zpool export -a 2>/dev/null && break
  sleep 3
  if (( try == 5 )); then
    zpool export -af 2>/dev/null || EXPORT_OK=no
  fi
done
[[ $EXPORT_OK == no ]] && {
  echo "  !! could not export: $(zpool list -H -o name 2>/dev/null | tr '\n' ' ')"
  echo "     NOT fatal — hostid was copied; pools import cleanly at first boot."; }

for m in luks-root1 luks-root2 ${XP:+luks-extra}; do
  cryptsetup close "$m" 2>/dev/null || true
done

hr
cat <<EOF
 DONE. Remove the install medium and reboot.

 First boot : $(
   [[ $TPM_ENROLL == now ]] \
     && echo "should unlock via TPM2 — if passphrase prompt appears: type it, then  sudo enroll-tpm2 $TPM_PCRS" \
     || echo "type the LUKS passphrase, log in, then run:  sudo enroll-tpm2 $TPM_PCRS" )
 Login      : ssh $NEW_USER@<ip>   (password)
              IP is shown on the console, or check your DHCP server / router.
 Verify TPM : sudo cryptsetup luksDump $RP1 | grep -A3 tpm2
 Re-enroll  : sudo enroll-tpm2 [PCRS]   — after firmware/Secure Boot changes or disk swap
 EFI sync   : sudo sync-efi            — after shim-signed/grub package updates
 Scrub      : sudo zpool scrub $RPOOL $BPOOL
 Pools      : $BPOOL (mirror, /boot)   $RPOOL (mirror on LUKS, /)$(
   [[ -n $XP ]] && echo "   $EXTRA_POOL (SINGLE disk — no redundancy — $EXTRA_MNT)" )

 KEEP THE PASSPHRASE OFFLINE.
 It is the only way in if the TPM refuses to unseal.
EOF
hr
