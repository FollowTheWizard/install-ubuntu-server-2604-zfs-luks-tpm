# Ubuntu 26.04 — mirrored encrypted root with separate ZFS storage

This deployment uses Secure Boot throughout and keeps ZFS out of the root boot
path:

- Two EFI System Partitions, one per disk.
- Mirrored, unencrypted ext4 `/boot` on mdraid RAID1.
- Mirrored root mdraid RAID1 underneath one LUKS2 container, then LVM and ext4.
- A separate LUKS2 container on each disk, combined as a ZFS mirror mounted at
  `/data`.
- A post-install helper enrolls the root and data LUKS devices in TPM2. The same
  LUKS passphrase remains available as recovery.

> **Experimental and destructive:** the installer erases both selected disks.
> It checks that generated initramfs images contain the required dracut modules
> and that both ESPs contain shim and GRUB EFI loaders. Those checks do not
> prove that the system boots. It has not been boot-tested in a VM or on
> hardware. Do not use it with important data until the complete test matrix
> below passes on disposable drives.

## Requirements

- Ubuntu Server 26.04 amd64 live installation media, booted in UEFI mode with
  Secure Boot **enabled**.
- Two unmounted disks. Each must be large enough for the 1 GiB EFI partition,
  2 GiB `/boot`, 64 GiB root mirror, and at least 8 GiB for ZFS storage.
- Network access and TPM 2.0 enabled in firmware for automatic unlock.
- Physical or out-of-band console access for the first passphrase boot and
  recovery testing.

This is not a Proxmox VE installation. Do not install Proxmox on top of it.

## Install

Boot the live shell from the Ubuntu Server 26.04 ISO with Secure Boot left on.
The installer checks Secure Boot and aborts if it is disabled or cannot be
verified. It also checks that Ubuntu's signed ZFS module loads before it offers
to erase disks.

Download and inspect the new installer:

```bash
sudo apt-get update
sudo apt-get install -y curl ca-certificates

curl --fail --show-error --location \
  --output install-ubuntu-26.04-luks-root-zfs-data.sh \
  https://raw.githubusercontent.com/FollowTheWizard/install-ubuntu-server-2604-zfs-luks-tpm/main/install-ubuntu-26.04-luks-root-zfs-data.sh

less install-ubuntu-26.04-luks-root-zfs-data.sh
bash -n install-ubuntu-26.04-luks-root-zfs-data.sh
sudo bash install-ubuntu-26.04-luks-root-zfs-data.sh
```

The URL above downloads the published `main` branch, not uncommitted changes in
this checkout. Push and review the new files before downloading them on another
machine; for reproducible installs, replace `main` with a reviewed commit hash.

The script selects two disks interactively. Confirm model, capacity, and stable
device path carefully: typing `YES` destroys both disks. It asks for an
administrator password and one LUKS passphrase, which is used by the root and
both ZFS LUKS containers.

On the first installed-system boot, enter the LUKS passphrase. If TPM2 is
available, enroll after logging in:

```bash
sudo enroll-tpm2 7
```

This enrolls PCR 7 TPM tokens on the root and both ZFS LUKS devices. Reboot and
verify that TPM unlock works. The LUKS passphrase remains a recovery method;
keep it offline. Secure Boot must remain enabled. No DKMS MOK enrollment is
intended: the installer uses Ubuntu's signed ZFS kernel module package.

## Verify before relying on it

Use disposable drives and test every item before storing important data:

1. With both disks attached, confirm `mokutil --sb-state` reports Secure Boot
   enabled; confirm the root is ext4 on LVM over LUKS/mdraid and `zpool status`
   reports a healthy data mirror.
2. Verify a normal TPM-unlocked boot, then test the passphrase fallback. Keep a
   console or out-of-band access available.
3. Install a kernel update, reboot, verify the signed ZFS module loads and
   `/data` imports, and confirm the secondary EFI partition remains in sync.
4. Shut down, disconnect disk 1, and verify firmware boots from disk 2, the
   root and `/boot` arrays assemble degraded, and ZFS storage is available
   degraded. Reconnect and allow both arrays/pools to recover fully.
5. Repeat with disk 2 disconnected.
6. Test firmware/Secure Boot changes and verify that the passphrase can recover
   the system if TPM PCR measurements no longer match.

Do not hot-unplug disks. A UEFI boot entry for each ESP does not guarantee every
firmware will automatically select the surviving disk; verify this on the
actual machine.

## Layout and limitations

The root is one LUKS2 container on a two-disk mdraid1 device. It contains the
`vgubuntu` volume group, a 4 GiB swap LV, and an approximately 60 GiB ext4 root
LV. `/boot` is a separate ext4 mdraid1 array. Each disk has its own EFI System
Partition; the installer copies the EFI files to both and registers a boot
entry for each.

The data pool is a ZFS mirror over two separately LUKS-encrypted partitions.
Its usable capacity is limited by the smaller disk; any extra capacity on a
larger disk is left unused. The root and data devices share the same LUKS
passphrase and are enrolled in TPM2 together. If TPM unlock is unavailable,
expect passphrase prompts for the encrypted devices.

For chroot package installation, the script prefers the live system's upstream
DNS configuration when available. It then configures the installed system to
use `systemd-resolved` rather than retaining the live environment's resolver.
The ZFS import unit waits for the LUKS devices and scans only their mapper
paths, avoiding an unrelated pool with the same name.

The supplied ZFS reference uses ZFS for root on Ubuntu 23.10, while the
Hetzner guide targets Ubuntu 24.04 and its `installimage` workflow. They are
useful references for the LUKS/ZFS and encrypted-boot building blocks, but
neither validates this Ubuntu 26.04 layout. This installer keeps ZFS out of the
root boot path and uses Ubuntu's signed ZFS kernel modules for the data pool.

The installer has not been tested for degraded boot, kernel updates, or device
replacement. The repository's [legacy verifier](./verify-legacy-ubuntu-zfs-root.sh) is a checker
for systems using the retired ZFS-root boot layout; it does not validate this
installer. Use the test checklist above on disposable disks.

PCR 7 binds unlock to Secure Boot policy and enrolled keys. It is less likely
to require reenrollment on ordinary kernel updates than binding to kernel/initrd
measurements, but it does not by itself attest every boot artifact. Changes to
firmware or Secure Boot keys can require passphrase recovery and TPM
reenrollment.
