# Debian 13 — Btrfs RAID1 + LUKS2 + TPM2

The Debian 13 (Trixie) Btrfs installer creates mirrored Btrfs `/boot`, root,
and data filesystems. Root and data are encrypted with LUKS2. It installs
Debian-signed shim, GRUB, and kernel packages, so the installed system does not
need an out-of-tree DKMS module or MOK enrollment.

> **Warning:** This installer destroys all data on both selected disks. It is
> not yet hardware-tested. Review the script and verify the selected disks
> before confirming the destructive operation.

## Requirements

- Debian 13 amd64 live media, booted in UEFI mode, with network access.
- Two disks large enough for a 64 GiB OS filesystem plus data.
- Root privileges.
- TPM 2.0 is optional; without one, enter the LUKS passphrase at each boot.

Secure Boot may remain enabled if the live media boots successfully with it.
The installed system uses Debian's signed boot components; no DKMS-generated
module or MOK key is needed.

## Install

1. Boot the Debian 13 live ISO in UEFI mode, connect to the network, and open a
   root shell.
2. Download and syntax-check the Btrfs installer:

   ```bash
   curl -fLO https://raw.githubusercontent.com/FollowTheWizard/install-ubuntu-server-2604-zfs-luks-tpm/main/install-debian-13-btrfs-luks-tpm.sh
   bash -n install-debian-13-btrfs-luks-tpm.sh
   sudo bash install-debian-13-btrfs-luks-tpm.sh
   ```

3. Select the two install disks, configure the user and system, and type `YES`
   only after verifying the disk identities. All data on both disks will be
   erased.
4. On first boot, enter the LUKS passphrase. After logging in, enroll TPM2:

   ```bash
   sudo enroll-tpm2 7
   ```

   The passphrase remains available as a fallback. If a disk is missing, the
   helper enrolls the available LUKS devices and reports skipped members; rerun
   it after the missing disk returns or is replaced.

## Layout and maintenance

- Mirrored, unencrypted Btrfs `/boot` across both disks.
- Mirrored, LUKS2-backed Btrfs root filesystem with separate subvolumes for
  `/`, `/var`, `/var/log`, `/var/spool`, `/var/cache`, `/var/tmp`, `/srv`,
  `/tmp`, and `/root`.
- Mirrored, LUKS2-backed Btrfs data filesystem for `/home` and `/data`.
- Each disk also has an EFI system partition and a randomly encrypted swap area.
- A larger disk's leftover space can optionally be used for a single-disk,
  non-redundant LUKS2-backed Btrfs filesystem mounted below `/data`.

After installation:

```bash
findmnt
swapon --show
systemctl --failed
sudo sync-efi
sudo btrfs scrub start /
sudo btrfs scrub start /boot
```

`sync-efi` copies EFI bootloader updates to the second EFI partition. Keep the
LUKS passphrase offline; TPM unlock is not a replacement for a recovery
passphrase.

## ZFS installer

The repository also retains [the original Debian ZFS installer](./install-debian-13-zfs-luks-tpm.sh).
That separate design uses ZFS DKMS and therefore requires a MOK enrollment to
use Secure Boot with its installed ZFS module. Use the Btrfs installer above
when avoiding MOK enrollment is a requirement.
