# Fedora Server — encrypted Btrfs RAID1 for OS and data

This installer creates a Fedora Server system from Fedora live media. Secure
Boot is preferred but not mandatory; if it is disabled or its state cannot be
read, the installer asks whether to continue:

- Two EFI System Partitions, one on each disk.
- Unencrypted Btrfs RAID1 `/boot` on one partition per disk.
- A separate LUKS2+Btrfs RAID1 filesystem for the OS root (`/`).
- A separate LUKS2+Btrfs RAID1 filesystem for data (`/data`).
- The installer asks for the OS partition size per disk (100 GiB default, or
  64 GiB on smaller disks, reduced only if needed to fit);
  `/data` uses the remaining capacity on each disk.
- A post-install helper enrolls all four OS and data LUKS devices in TPM2. The
  same LUKS passphrase remains available as recovery.

Fedora's third-party OpenZFS kernel module is not used. Fedora does not ship a
Secure-Boot-signed OpenZFS module, so this Fedora variant uses native Btrfs for
`/boot`, the OS, and data and does not need a local kernel-module signing key or
MOK enrollment.

> **Experimental and destructive:** the installer erases both selected disks.
> It has only been syntax/static checked, not boot-tested on hardware or in a VM.
> Test on disposable disks before storing important data.

## Requirements

- Fedora Workstation Live media, booted in UEFI mode. The installer uses the
  live release's Fedora repositories to install Fedora Server packages into
  the target. Secure Boot is optional, which is useful in VMs where it may not
  be available.
- Two unmounted x86_64 disks. Each must be about 51 GiB or larger to fit a
  1 GiB EFI partition, 2 GiB `/boot`, at least 40 GiB for the OS, and 8 GiB for
  Btrfs data. The installer proposes 100 GiB for the OS, or a smaller size if
  required by disk capacity.
- Network access and TPM 2.0 exposed as `/dev/tpmrm0`.
- Console access for the first passphrase boot and recovery testing.

## Install

Boot Fedora Workstation Live in UEFI mode, connect to the network, open a
terminal, and download and inspect the script:

```bash
sudo dnf5 install -y curl
curl --fail --show-error --location \
  --output install-fedora-server-luks-root-btrfs-data.sh \
  https://raw.githubusercontent.com/FollowTheWizard/install-ubuntu-server-2604-zfs-luks-tpm/main/install-fedora-server-luks-root-btrfs-data.sh

less install-fedora-server-luks-root-btrfs-data.sh
bash -n install-fedora-server-luks-root-btrfs-data.sh
sudo bash install-fedora-server-luks-root-btrfs-data.sh
```

The script selects two disks interactively and asks for the OS partition size
in GiB. The proposed default is 100 GiB per disk for the mirrored OS, or
64 GiB on smaller disks; it is reduced further only if needed to fit the
minimum 8 GiB data allocation. `/data` uses the remaining space. EFI defaults
to 1 GiB and Btrfs `/boot` to 2 GiB on each disk. Confirm model, capacity,
stable device path, and the displayed layout carefully: typing `YES` destroys
both disks. It asks for an administrator password and one LUKS passphrase used
by all four encrypted OS and data devices. If Secure Boot is disabled or its
state cannot be determined, the installer warns that TPM2 PCR 7 enrollment may
be affected by boot or Secure Boot configuration changes and asks whether to
continue. Answer `y` to proceed, or press Enter to stop. It does not turn
Secure Boot on or enforce it.

The script detects the Fedora release from the live media and installs the
matching Fedora Server package set into a fresh target. It does not use Anaconda
or copy the live system. If a previous attempt left the default mount directory
`/mnt/fedora-install` behind, the installer reuses it only when it is an empty,
unmounted directory.

On the first installed-system boot, enter the LUKS passphrase for the OS
members if prompted. After logging in, enroll TPM2 PCR 7 for all OS and data
devices:

```bash
sudo enroll-tpm2 7
```

Reboot and verify TPM unlock. Keep the LUKS passphrase offline as a recovery
method. The installed Fedora shim and GRUB packages are Fedora-signed. Keep
the Secure Boot configuration consistent with the one used for TPM enrollment;
if TPM unlock fails after a configuration change, use the LUKS passphrase.

## Verify before relying on it

Use disposable drives and test every item before storing important data:

1. Check `mokutil --sb-state` to record the Secure Boot state, and confirm `/`,
   `/boot`, and `/data` are Btrfs filesystems.
2. Verify `sudo btrfs filesystem show /`, `/boot`, and `/data` report the
   expected two devices, and `sudo btrfs filesystem usage /` reports RAID1
   data and metadata profiles for the OS.
3. Verify `/data` mounts and the root filesystem remains separate from it.
4. Verify a normal TPM-unlocked boot, then test passphrase fallback.
5. Install a kernel update, reboot, confirm `/data` mounts, and synchronize both
   EFI partitions with `sudo /usr/local/sbin/sync-efi`.
6. Shut down, disconnect one disk, and test whether the firmware can boot from
   the other disk and Btrfs mounts degraded. Reconnect and verify recovery.
7. Test firmware/Secure Boot changes and verify passphrase recovery if TPM PCR
   measurements change.

Do not hot-unplug disks. A UEFI boot entry for each ESP does not guarantee every
firmware will automatically select the surviving disk; verify this on the
actual machine.

## Layout and limitations

Each disk has its own EFI System Partition and an unencrypted Btrfs `/boot`
partition; `/boot` is one Btrfs RAID1 filesystem. The OS uses a separate LUKS2
partition on each disk combined into an encrypted Btrfs RAID1 root filesystem.
The chosen OS size is allocated equally on both disks. `/data` is a different
encrypted Btrfs RAID1 filesystem using the remaining space. Its usable capacity
is limited by the smaller data partition. The installer copies Fedora's EFI
files to both ESPs and registers a boot entry for each.

The OS and data devices share the same LUKS passphrase and can be enrolled in
TPM2 together after first boot. If TPM unlock is unavailable, the passphrase
remains the recovery method. No mdraid, LVM, ext4, or swap partition is used.
Btrfs swapfiles have significant limitations on multi-device filesystems, so
this RAID1 layout does not configure swap.

The installer and degraded-boot, kernel-update, and device-replacement behavior
have not been hardware-tested. Verify those scenarios on disposable drives
before relying on the system.
