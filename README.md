# Ubuntu Server 26.04 LTS — ZFS Mirror + LUKS2 FDE + TPM2 Unlock

An interactive, single-file installer script that puts **Ubuntu Server 26.04 LTS
(Resolute Raccoon)** on **two disks** as a **ZFS mirror**, with **full-disk encryption
(LUKS2)** underneath ZFS, unlocked at boot **either by passphrase or automatically by
the TPM 2.0 chip**.

> ✅ **Tested on real hardware** — HP ProDesk 400 G6 Desktop Mini PC,
> NVMe (Toshiba KBG30ZMV256G 256 GB) + USB-NVMe (Realtek RTL9210B enclosure),
> Ubuntu 26.04 LTS, kernel 7.0.0-31-generic, fTPM 2.0, Secure Boot.
> 0 failed units, 0 journal errors. All pools, datasets, swap, SSH, TPM
> unlock and dual EFI verified working.

---

## Table of contents

- [Why this script exists](#why-this-script-exists)
- [Features](#features)
- [What you get](#what-you-get)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [What the script asks](#what-the-script-asks)
- [Disk layout](#disk-layout)
- [Boot chain](#boot-chain)
- [Different-sized disks](#different-sized-disks)
- [After the first boot](#after-the-first-boot)
- [Security model](#security-model)
- [Design decisions](#design-decisions)
- [Known limitations](#known-limitations)
- [Maintenance](#maintenance)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)

---

## Why this script exists

The stock Ubuntu installer cannot do this combination:

- The **Server installer** has no ZFS option at all.
- The **Desktop installer**'s ZFS layout is single-disk only.
- Canonical's **TPM-backed FDE** is a snap-based system that does not combine with ZFS
  mirrors, requires the kernel in a snap (breaking some binary drivers), and can only be
  enabled at install time.

The result is a manual `debootstrap`-based install following the OpenZFS Root-on-ZFS
method, adapted for Ubuntu 26.04's dracut initrd and `sudo-rs`.

---

## Features

- **Fully interactive** — no variables to edit. A numbered disk picker, system prompts,
  and a full summary are shown before anything is written to disk.
- **Two-disk ZFS mirror** for `/` (`rpool`) and `/boot` (`bpool`).
- **LUKS2 full-disk encryption** (AES-256-XTS, argon2id KDF) under every ZFS vdev.
- **Two unlock methods** on every LUKS device: your passphrase *and* a TPM2-sealed key
  (`systemd-cryptenroll`). Normal boots are hands-free; the passphrase is the fallback.
- **Different-sized disks handled**: the mirror uses the smaller disk's size; the leftover
  on the larger disk becomes its own LUKS+TPM encrypted, unmirrored pool — or is left
  unused — your choice.
- **Encrypted swap** (4 GiB per disk) with a fresh random key every boot.
- **Redundant EFI**: GRUB/shim installed on both disks, second ESP synced, NVRAM entries
  for both disks.
- **Ubuntu 26.04-native**: dracut initrd, `sudo-rs`, deb822 apt sources,
  `systemd-networkd` / netplan, `systemd-resolved`.
- **Secure Boot compatible** (signed shim + GRUB from Ubuntu's repositories).
- **SSH** enabled with password login on first boot; root login disabled.
- **Safe to re-run**: `release_disks` tears down any mounts, pools, LUKS/dm/md/LVM
  holders and stale signatures before partitioning — works on a previously-used or
  partially-installed system.
- Ships two helper commands in the installed system: `enroll-tpm2` and `sync-efi`.

---

## What you get

```
                    ┌──────────────┐        ┌──────────────┐
                    │    DISK 1    │        │    DISK 2    │
                    ├──────────────┤        ├──────────────┤
  /boot/efi  ◄──────┤ 1  ESP  1G   │  sync  │ 1  ESP  1G   ├──────► /boot/efi2
                    ├──────────────┤        ├──────────────┤
  bpool (mirror) ◄──┤ 2  ZFS  2G   │◄──────►│ 2  ZFS  2G   │        /boot
                    ├──────────────┤        ├──────────────┤
  swap1 (random) ◄──┤ 3  swap 4G   │        │ 3  swap 4G   ├──────► swap2
                    ├──────────────┤        ├──────────────┤
                    │ 4  LUKS2     │        │ 4  LUKS2     │
  rpool (mirror) ◄──┤   luks-root1 │◄──────►│   luks-root2 ├──────► /  /home  /var …
                    │   pass+TPM   │        │   pass+TPM   │
                    ├──────────────┤        └──────────────┘
                    │ 5  LUKS2     │  (only on the larger disk, if disks differ)
  xpool (single) ◄──┤   luks-extra │──────► /data
                    │   pass+TPM   │
                    └──────────────┘
```

**ZFS datasets:**

| Dataset | Mountpoint |
|---|---|
| `bpool/BOOT/ubuntu` | `/boot` (legacy) |
| `rpool/ROOT/ubuntu` | `/` |
| `rpool/home` | `/home` |
| `rpool/home/root` | `/root` |
| `rpool/var/log` | `/var/log` (legacy) |
| `rpool/var/spool` | `/var/spool` (legacy) |
| `rpool/var/cache` | `/var/cache` |
| `rpool/var/tmp` | `/var/tmp` |
| `rpool/tmp` | `/tmp` |
| `rpool/srv` | `/srv` |
| `xpool` | `/data` (optional, single disk) |

---

## Requirements

### Hardware

| Item | Requirement |
|---|---|
| Firmware | UEFI. **Secure Boot must be enabled** (the script refuses BIOS mode; PCR 7 is meaningless without Secure Boot). |
| TPM | TPM 2.0, enabled in firmware (`/dev/tpmrm0` visible). Without it the install still works — you type the passphrase at every boot, then run `sudo enroll-tpm2` when the machine gets a TPM. |
| Disks | Two. Any size ≥ 16 GiB, may differ. SATA, NVMe, SAS or virtio. **Both are completely wiped.** |
| RAM | 2 GiB minimum for the install; the script and swap sizing were tuned for 32 GiB servers. |
| Network | Required during install (`debootstrap` fetches ~500 MB). |

### Software

The **Ubuntu 26.04 live ISO** — Desktop ("Try Ubuntu") or Server shell. The Desktop
session is more comfortable. Use the **26.04.1** point release (released 27 Aug 2026)
for accumulated fixes.

Nothing else — the script installs all tools it needs into the live environment.

---

## Quick start

```bash
# 1. Boot Ubuntu 26.04.1 live ISO in UEFI mode with Secure Boot ON.
#    Connect to the network.

# 2. Verify preconditions (optional but recommended)
mokutil --sb-state          # → "SecureBoot enabled"
ls /dev/tpmrm0              # → exists if TPM 2.0 is usable

# 3. Get the script (USB stick, scp, or paste into nano)
curl -LO https://raw.githubusercontent.com/<you>/<repo>/main/install-2604-zfs-luks-tpm.sh

# 4. Run as root
sudo -i
bash install-2604-zfs-luks-tpm.sh

# 5. Answer the prompts, type YES at the summary, set your passphrase.
#    Takes 10-20 minutes depending on your internet connection.
#    Remove the live medium when done and reboot.
```

---

## What the script asks

| # | Prompt | Default | Notes |
|---|---|---|---|
| 1 | First disk | — | Numbered list with size, model and by-id name. Live USB filtered out. |
| 2 | Second disk | — | Must differ from the first. |
| 3 | Hostname | `ubuntu-server` | |
| 4 | Admin username | `admin` | Gets `sudo` and `adm` groups. |
| 5 | Admin password | — | Min 10 chars, typed twice. **Also the SSH login password.** |
| 6 | Timezone | `Etc/UTC` | Validated against `/usr/share/zoneinfo`. |
| 7 | Locale | `en_US.UTF-8` | Validated against `/usr/share/i18n/SUPPORTED`. |
| 8 | Leftover space | `pool` | Only shown when disks differ by ≥ 1 GiB. `pool` → encrypted LUKS+TPM pool; `none` → unused. |
| 9 | PCRs to seal against | `7` | `7` = Secure Boot state. `0,7` = also firmware code (passphrase needed after firmware updates). |
| 10 | Enroll TPM2 now or later | `now` | Only shown when `/dev/tpmrm0` is present. |
| — | **Type `YES` to confirm** | | Nothing has been written yet. |
| 11 | LUKS passphrase | — | Min 8 chars, typed twice. Same passphrase for all LUKS containers on both disks. |

---

## Disk layout

Both disks are partitioned identically, sized to the **smaller disk**:

| Partition | Type | Size | Content |
|---|---|---|---|
| 1 | `EF00` ESP | 1 GiB | FAT32. Disk 1 → `/boot/efi`, disk 2 → `/boot/efi2`. |
| 2 | `BE00` ZFS | 2 GiB | `bpool` member. `compatibility=grub2`. Holds `/boot`. |
| 3 | `8200` swap | 4 GiB | dm-crypt *plain* mode, random key per boot. |
| 4 | `8309` LUKS | remainder | LUKS2 → `luks-rootN` → `rpool` member. |
| 5 | `8309` LUKS | leftover (larger disk only) | LUKS2 → `luks-extra` → `xpool`. Optional. |

---

## Boot chain

```
UEFI firmware (Secure Boot ON)
  └─ shimx64.efi       (Microsoft-signed, from Ubuntu)           ← disk 1 or 2
      └─ grubx64.efi   (Canonical-signed)
          └─ reads bpool (ZFS, grub2-compatible features)
              └─ kernel + dracut initrd
                  ├─ systemd-cryptsetup opens luks-root1 + luks-root2
                  │     via rd.luks.name=<uuid>=luks-rootN
                  │     TPM unseals if PCR 7 matches, else passphrase prompt
                  ├─ zfs-dracut imports rpool, mounts rpool/ROOT/ubuntu
                  └─ switch-root → systemd
                      ├─ zfs-import-bpool.service  imports bpool (idempotent, -f)
                      ├─ zfs-import-xpool.service  imports xpool after luks-extra opens
                      ├─ zfs-mount.service         mounts all datasets
                      ├─ systemd-cryptsetup@swap{1,2} opens swap (random key)
                      └─ normal boot targets
```

**Kernel command line** (written to `/etc/default/grub`):
```
root=ZFS=rpool/ROOT/ubuntu
rd.luks.name=<UUID1>=luks-root1
rd.luks.name=<UUID2>=luks-root2
rd.luks.options=discard,tpm2-device=auto
```

---

## Different-sized disks

The ZFS mirror is capped to the **smaller disk**. The script:

1. Sizes all partitions from the smaller disk and applies the layout to both.
2. Puts the remainder on the larger disk into partition 5 → LUKS2 (same passphrase,
   TPM-enrolled) → pool `xpool` at `/data`.

`xpool` has **no redundancy**. If the larger disk fails, `/data` is gone. Use it for
re-creatable data (caches, scratch, replicated content) or back it up with `zfs send`.

It is marked `nofail` so its absence never blocks boot.

---

## After the first boot

### TPM unlock

If you enrolled during install (`now`): the machine should boot hands-free. If the
passphrase is requested anyway (PCR 7 changed between the live ISO's shim/GRUB and the
installed ones):

```bash
sudo enroll-tpm2        # re-seals against the installed system's PCR 7
```

If you chose `later`: type the passphrase at first boot, log in, then run the above.

### Verify everything

```bash
zpool status                    # rpool and bpool ONLINE
swapon --show                   # two 4G swap devices
df -h /boot /boot/efi /data     # all mounted
sudo cryptsetup luksDump /dev/disk/by-id/<disk>-part4 | grep -A3 tpm2
systemctl --failed              # should be empty
```

### Helper commands

| Command | When to run |
|---|---|
| `sudo enroll-tpm2 [PCRS]` | After first boot (if deferred), firmware update, Secure Boot change, TPM clear, or disk replacement. Wipes old TPM slots, re-enrolls, keeps passphrase. |
| `sudo sync-efi` | After `shim-signed` or `grub-efi-amd64-signed` package updates, so disk 2 stays bootable independently. |
| `sudo zpool scrub rpool bpool` | Monthly. Catches silent bit rot early. |

---

## Security model

### What this protects

- A disk (or both) removed from the machine is unreadable. All user data, logs, swap and
  the root filesystem are encrypted. Only the ESP (shim, GRUB) and `bpool` (kernel,
  initrd) are plaintext — the same as every LUKS+GRUB setup.
- Boot-chain tampering (Secure Boot disabled, unsigned bootloader, changed SB keys)
  changes PCR 7 → TPM refuses to unseal → passphrase required.
- Booting a foreign live USB: Secure Boot rejects unsigned media; signed media from a
  different vendor changes PCR 7 → no unseal.

### What this does NOT protect

- Someone who simply powers the machine on and lets it boot to the login prompt. The TPM
  unseals; your defense is the **user password and SSH hardening**.
- Network / kernel exploits against the running system.
- TPM bus-sniffing (mitigated on discrete TPMs by `--tpm2-with-pin`; not enabled here
  as it defeats unattended boot on a server).
- Loss of the passphrase. **If the TPM refuses to unseal and you have no passphrase, the
  data is permanently inaccessible.** Store it offline.

### Choosing PCRs

| PCRs | Measures | Survives firmware update | Survives Secure Boot change |
|---|---|---|---|
| `7` | Secure Boot policy & certs | ✅ yes | ❌ passphrase + re-enroll |
| `0,7` | + firmware code | ❌ passphrase + re-enroll | ❌ passphrase + re-enroll |

`7` is recommended for servers that receive regular firmware updates.

---

## Design decisions

- **LUKS under ZFS, not ZFS native encryption.** LUKS encrypts everything including ZFS
  metadata, integrates with `systemd-cryptenroll`/TPM2 out of the box, and lets swap and
  the optional extra pool share one unlock mechanism. ZFS native encryption cannot be
  TPM-unlocked without custom tooling and leaks dataset metadata.
- **Separate `bpool`.** GRUB understands only a subset of ZFS features. `bpool` is
  created with `compatibility=grub2` so `rpool` can use all modern features. The name
  `bpool` is mandatory for Ubuntu's GRUB scripts.
- **Empty `/etc/zfs/zpool.cache` on the installed system.** `rpool` is imported by
  dracut from the kernel cmdline (`root=ZFS=…`), `bpool` by a dedicated systemd service,
  and `xpool` by its own service after LUKS opens. An empty cachefile means
  `zfs-import-cache` harmlessly does nothing and cannot race with these services.
- **`-f` on bpool/xpool import.** Handles an unclean pool from a power cut or the
  live-session teardown race. Safe on a dedicated pool that cannot be simultaneously
  imported on another host.
- **`rd.luks.name=` on the kernel command line.** Fixes `/dev/mapper` names in the
  initrd independent of crypttab, so `zpool` device paths always match.
- **Random-key swap.** No hibernation on a 24/7 server. No TPM slot to manage.
- **`/dev/disk/by-id` everywhere.** Pool members and partition references survive
  controller reordering.
- **`sudo-rs`** is the 26.04 default sudo provider.
- **dracut `hostonly="no"`** for the install. Host-only detection is unreliable in a
  chroot. Switch to `hostonly="yes"` later if you want a smaller initrd.
- **`pipefail` deliberately omitted.** Several helpers pipe commands that return non-zero
  when "nothing found" (findmnt, grep) into `tr`/`head`. Under `pipefail` + `set -e`
  this kills the script silently with no error message.

---

## Known limitations

- **amd64 only.**
- Installs `linux-image-generic` only. HWE or cloud kernels require adjusting the
  package list.
- **USB-attached disks as mirror members** are unreliable: bus resets cause ZFS to mark
  the vdev UNAVAIL. The pool recovers once the device re-appears (`zpool online bpool
  <id>`), but this will happen occasionally. An internal drive is strongly recommended
  for a 24/7 server.
- Single admin user; no cloud-init.
- Networking is DHCP on all `en*` interfaces. Edit `/etc/netplan/01-netcfg.yaml` for
  static IPs, bonds or VLANs.
- No `--tpm2-with-pin` (TPM + PIN). Trivial to add in `enroll-tpm2` if wanted.
- Password SSH is enabled by design. If the host is internet-facing, consider moving to
  key-based auth and disabling passwords, or adding `fail2ban`.
- Adding a third mirror member or converting to RAIDZ is standard ZFS work and is not
  covered here.

---

## Maintenance

### Routine

| Frequency | Task |
|---|---|
| After `shim-signed`/`grub-efi-amd64-signed` updates | `sudo sync-efi` |
| After a firmware update (PCRs `0,7` only) | Boot with passphrase, then `sudo enroll-tpm2 0,7` |
| After Secure Boot key / policy change | Boot with passphrase, then `sudo enroll-tpm2` |
| After clearing the TPM | Boot with passphrase, then `sudo enroll-tpm2` |
| Monthly | `sudo zpool scrub rpool bpool` |

Kernel updates need nothing special: the dracut and GRUB hooks regenerate the initrd and
`grub.cfg` automatically.

### Replacing a failed disk

```bash
# 1. Replicate the partition table from the surviving disk
sudo sgdisk --replicate=/dev/disk/by-id/NEW /dev/disk/by-id/GOOD
sudo sgdisk --randomize-guids /dev/disk/by-id/NEW

# 2. Replace the bpool member
sudo zpool replace bpool <old-guid-from-zpool-status> /dev/disk/by-id/NEW-part2

# 3. LUKS on the new root partition
sudo cryptsetup luksFormat --type luks2 --pbkdf argon2id /dev/disk/by-id/NEW-part4
sudo cryptsetup open --allow-discards --persistent /dev/disk/by-id/NEW-part4 luks-rootN

# 4. Replace the rpool member
sudo zpool replace rpool <old-guid> /dev/mapper/luks-rootN

# 5. Update crypttab + kernel cmdline with the new UUID
NEWUUID=$(sudo cryptsetup luksUUID /dev/disk/by-id/NEW-part4)
sudo sed -i "s|^luks-rootN .*|luks-rootN UUID=$NEWUUID none luks,discard,tpm2-device=auto|" /etc/crypttab
sudo sed -i "s|rd.luks.name=[^ ]*=luks-rootN|rd.luks.name=$NEWUUID=luks-rootN|" /etc/default/grub

# 6. Enroll TPM, rebuild initrd + grub, sync EFI
sudo enroll-tpm2
sudo dracut -f --regenerate-all
sudo update-grub
sudo mkfs.vfat -F32 /dev/disk/by-id/NEW-part1
sudo mount /boot/efi2 && sudo sync-efi
sudo efibootmgr -c -g -d /dev/disk/by-id/NEW -p 1 -L "ubuntu (disk 2)" -l '\EFI\ubuntu\shimx64.efi'

# 7. Wait for resilver
watch zpool status
```

### Changing the LUKS passphrase

```bash
for p in \
  /dev/disk/by-id/DISK1-part4 \
  /dev/disk/by-id/DISK2-part4 \
  /dev/disk/by-id/BIGDISK-part5; do   # omit part5 if no xpool
  sudo cryptsetup luksChangeKey "$p"
done
# TPM slots are unaffected; enroll-tpm2 will ask for the new passphrase next run
```

---

## Troubleshooting

### Emergency mode at first boot

```bash
systemctl --failed --no-pager    # find the failed unit
journalctl -b -p err --no-pager | tail -30
```

**`zfs-import-bpool.service` failed** — most common first-boot failure:
```bash
zpool import -f -N bpool         # manual import
systemctl reset-failed zfs-import-bpool.service
exit                             # resume normal boot
```

**Passphrase prompt when TPM was enrolled** — PCR 7 changed between live ISO and
installed shim/GRUB. Type the passphrase, boot normally, then:
```bash
sudo enroll-tpm2
```

**Dracut emergency shell: rpool not found**
```bash
# inside the dracut shell
ls /dev/mapper/                  # are luks-root1 and luks-root2 present?
zpool import                     # what pools are visible?
zpool import -f -N rpool ; exit  # manual import, then continue
```

### Pool shows DEGRADED after boot

USB-attached vdev was not ready when ZFS scanned. Recovers automatically once the device
appears:
```bash
zpool online bpool <id>          # id from `zpool status`
zpool status                     # confirm ONLINE and resilvering
```

### Rescue from the live ISO

```bash
sudo -i
cryptsetup open /dev/disk/by-id/DISK1-part4 luks-root1
cryptsetup open /dev/disk/by-id/DISK2-part4 luks-root2
zpool import -N -R /mnt rpool
zfs mount rpool/ROOT/ubuntu && zfs mount -a
zpool import -N -R /mnt bpool
mount -t zfs bpool/BOOT/ubuntu /mnt/boot
mount /dev/disk/by-id/DISK1-part1 /mnt/boot/efi
for f in dev proc sys run; do mount --rbind /$f /mnt/$f; mount --make-rslave /mnt/$f; done
chroot /mnt
# fix things, then:
exit
umount -R /mnt
zpool export -a
cryptsetup close luks-root1; cryptsetup close luks-root2
```

---

## Contributing

Bug reports are most useful with:
- Last ~30 lines of script output
- `systemctl --failed` and relevant `journalctl -b` excerpt
- Hardware (VM or bare metal, TPM type, disk types and sizes)
- Whether Secure Boot was on

PRs welcome. Keep the script single-file, `set -eu`-clean and interactive-first.

---

## Changelog

### [0.8.2] — 2026-09-05 ✅ First fully verified run
- **Tested on HP ProDesk 400 G6** (NVMe + USB-NVMe, fTPM 2.0, Secure Boot, kernel 7.0.0-31-generic)
- 0 failed units, 0 journal errors on first clean boot
- All pools, datasets, swap, SSH, TPM unlock, dual ESP verified

**Fixed:**
- `xpool` (extra pool on larger disk) was not imported at boot — added dedicated
  `zfs-import-xpool.service` that waits for `luks-extra` to open, then imports with
  `-f` and a 20 s retry loop (rev. 8.2)

### [0.8.1] — 2026-09-05
- `zfs-import-bpool.service` made idempotent (exit 0 if already imported by zfs-import-scan)
- Added 20 s retry loop for slow USB device enumeration

### [0.8.0] — 2026-09-05
- Empty `/etc/zfs/zpool.cache` on installed system prevents import-cache racing with import-bpool
- `-f` added to bpool import; cachefile-shuffle `mv` lines removed
- `zstd` added to target packages (dracut compression)
- Teardown never fatal: kills stray processes, sweeps all mount namespaces, retries export

### [0.7.3] — 2026-09-05
- Teardown and `release_disks` both sweep private mount namespaces via `nsenter`

### [0.7.2] — 2026-09-05
- `mkdir -p` before legacy ZFS remount (`zfs umount` removes empty inherited dirs)
- Working DNS in chroot (copy live resolv.conf in, restore stub symlink after)
- `tmpfs` on `/run` inside chroot for package postinsts

### [0.7.1] — 2026-09-05
- `release_disks` holder removal fixed (sysfs kernel names → mapper names)
- Exports all pools, not only script-owned ones

### [0.6.0] — 2026-09-05
- Dropped `pipefail` — `findmnt`'s "not mounted" exit code was killing the script silently

### [0.5.0] — 2026-09-05
- `multipathd` stopped before partitioning (Ubuntu Server live ISO)
- Stale partition signatures wiped; `assert_free` names the holder on failure

---

## License

MIT — see [LICENSE](LICENSE).

**No warranty. This script destroys all data on the disks you select. Read it before you run it.**
