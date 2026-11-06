# Fedora Server — mirrored encrypted root and Btrfs data

This installer creates a Fedora Server system from Fedora live media and keeps
Secure Boot enabled:

- Two EFI System Partitions, one on each disk.
- Mirrored, unencrypted ext4 `/boot` on mdraid RAID1.
- Mirrored root mdraid RAID1 underneath one LUKS2 container, then LVM and ext4.
- A separate LUKS2 container on each disk, combined as a Btrfs RAID1 filesystem
  mounted at `/data`.
- A post-install helper enrolls the root and data LUKS devices in TPM2. The same
  LUKS passphrase remains available as recovery.

Fedora's third-party OpenZFS kernel module is not used. Fedora does not ship a
Secure-Boot-signed OpenZFS module, so this Fedora variant uses native Btrfs for
data and does not need a local kernel-module signing key or MOK enrollment.

> **Experimental and destructive:** the installer erases both selected disks.
> It has only been syntax/static checked, not boot-tested on hardware or in a VM.
> Test on disposable disks before storing important data.

## Requirements

- Fedora Workstation Live media, booted in UEFI mode with Secure Boot enabled.
  The installer uses the live release's Fedora repositories to install Fedora
  Server packages into the target.
- Two unmounted x86_64 disks. Each must fit a 1 GiB EFI partition, 2 GiB `/boot`,
  64 GiB root mirror, and at least 8 GiB for Btrfs data.
- Network access and TPM 2.0 exposed as `/dev/tpmrm0`.
- Console access for the first passphrase boot and recovery testing.

## Install

Boot Fedora Workstation Live with Secure Boot enabled, connect to the network,
open a terminal, and download and inspect the script:

```bash
sudo dnf5 install -y curl
curl --fail --show-error --location \
  --output install-fedora-luks-root-btrfs-data.sh \
  https://raw.githubusercontent.com/FollowTheWizard/install-ubuntu-server-2604-zfs-luks-tpm/main/install-fedora-luks-root-btrfs-data.sh

less install-fedora-luks-root-btrfs-data.sh
bash -n install-fedora-luks-root-btrfs-data.sh
sudo bash install-fedora-luks-root-btrfs-data.sh
```

The script selects two disks interactively. Confirm model, capacity, and stable
device path carefully: typing `YES` destroys both disks. It asks for an
administrator password and one LUKS passphrase used by the root and both data
devices.

The script detects the Fedora release from the live media and installs the
matching Fedora Server package set into a fresh target. It does not use Anaconda
or copy the live system.

On the first installed-system boot, enter the LUKS passphrase. After logging in,
enroll TPM2 PCR 7 for the root and both data devices:

```bash
sudo enroll-tpm2 7
```

Reboot and verify TPM unlock. The LUKS passphrase remains a recovery method;
keep it offline. Secure Boot must remain enabled. The installed Fedora shim
and GRUB packages are the Fedora-signed packages.

## Verify before relying on it

Use disposable drives and test every item before storing important data:

1. Confirm `mokutil --sb-state` reports Secure Boot enabled and that `/` is
   ext4 on LVM over LUKS/mdraid.
2. Verify `cat /proc/mdstat` and `sudo mdadm --detail /dev/md0` and `/dev/md1`
   show healthy mirrors.
3. Verify `sudo btrfs filesystem show /data` reports both data devices as a
   RAID1 filesystem.
4. Verify a normal TPM-unlocked boot, then test passphrase fallback.
5. Install a kernel update, reboot, confirm `/data` mounts, and synchronize both
   EFI partitions with `sudo /usr/local/sbin/sync-efi`.
6. Shut down, disconnect one disk, and verify firmware can boot from the other
   disk and the root mirror starts degraded. Reconnect and verify recovery.
7. Test firmware/Secure Boot changes and verify passphrase recovery if TPM PCR
   measurements change.

Do not hot-unplug disks. A UEFI boot entry for each ESP does not guarantee every
firmware will automatically select the surviving disk; verify this on the
actual machine.

## Layout and limitations

The root is one LUKS2 container on a two-disk mdraid1 device. It contains the
`fedora` volume group, a 4 GiB swap LV, and an approximately 60 GiB ext4 root
LV. `/boot` is a separate ext4 mdraid1 array. Each disk has its own EFI System
Partition; the installer copies Fedora's EFI files to both and registers a boot
entry for each.

The `/data` filesystem is Btrfs RAID1 over two separately LUKS-encrypted
partitions. Its usable capacity is limited by the smaller disk. The root and
data devices share the same LUKS passphrase and are enrolled in TPM2 together.
If TPM unlock is unavailable, the passphrase remains the recovery method.

The installer and degraded-boot, kernel-update, and device-replacement behavior
have not been hardware-tested. Verify those scenarios on disposable drives
before relying on the system.
