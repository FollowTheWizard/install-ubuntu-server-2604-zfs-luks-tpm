# Debian 13 — ZFS Mirror + LUKS2 FDE + TPM2 Unlock

This is the Debian 13 (Trixie) counterpart to the Ubuntu installer. It creates a
two-disk ZFS mirror with LUKS2 encryption, passphrase unlock, optional TPM2 unlock,
redundant EFI partitions, and Debian's dracut-based boot setup.

> **Warning:** This installer destroys all data on both selected disks. It is not
> yet hardware-tested. Review the script and verify the selected disks before
> confirming the destructive operation.

## Requirements

- Debian 13 live media, booted in UEFI mode with Secure Boot temporarily disabled.
  Re-enable Secure Boot in firmware before the installed system's first boot.
- Two amd64 disks, each large enough for the 64 GiB OS pool plus the data pool.
- Working network access and root privileges.
- TPM 2.0 is optional; without one, enter the LUKS passphrase at each boot.

ZFS packages are in Debian's `contrib` archive area. The installer enables
`contrib` and `non-free-firmware`, installs matching kernel headers and the
`zfs-dkms` module, and uses `zfs-dracut`. See the
[Debian ZFS guide](https://wiki.debian.org/ZFS) for Debian's package guidance. The
guide also recommends backports for newer ZFS updates; this installer stays on
Trixie's stable repositories to avoid mixing release suites during installation.

## Install

1. Temporarily disable Secure Boot in firmware, then boot the Debian 13 GNOME Live
   ISO in UEFI mode and connect to the network. The live installer must load its
   locally built ZFS DKMS module to create and mount the pools.
2. Download the installer from this repository and run it as root:

   ```bash
   curl -fLO https://raw.githubusercontent.com/FollowTheWizard/install-ubuntu-server-2604-zfs-luks-tpm/main/install-debian-13-zfs-luks-tpm.sh
   sudo bash install-debian-13-zfs-luks-tpm.sh
   ```

3. Select the two install disks, configure the user and system, review the summary,
   and type `YES` only after verifying the disk identities.
4. During the final stage, set a temporary password when `mokutil` requests it.
   Before rebooting, re-enable Secure Boot in firmware. At the next boot, choose
   **Enroll MOK** in MokManager and enter that password. Debian builds its ZFS
   kernel module with DKMS; the installed system's signing key must be enrolled
   before Secure Boot will allow the kernel to load ZFS and mount the root pool.
5. Enter the LUKS passphrase at first boot, then enroll TPM2 after logging in:

   ```bash
   sudo enroll-tpm2 7
   ```

   The TPM enrollment is deferred until after MOK enrollment so the system can
   first boot using the signed DKMS module. The LUKS passphrase remains available
   as a fallback. If a disk is missing, the helper enrolls the available LUKS
   devices and reports skipped members; rerun it after the missing disk returns
   or is replaced.

## Layout and maintenance

- `bpool`: mirrored, unencrypted ZFS `/boot` pool.
- `rpool`: mirrored LUKS2-backed 64 GiB OS pool.
- `dpool`: mirrored LUKS2-backed data pool for `/home` and `/data`.
- Each disk also has an EFI system partition and a randomly encrypted swap area.
- A larger disk's leftover space can optionally be used for a single-disk,
  non-redundant encrypted pool.

After installation:

```bash
zpool status
swapon --show
systemctl --failed
sudo sync-efi
sudo zpool scrub rpool bpool dpool
```

`sync-efi` copies bootloader updates to the second EFI partition. Keep the LUKS
passphrase offline; TPM unlock is not a replacement for a recovery passphrase.

## Secure Boot sequence

The installer requires UEFI, but intentionally requires Secure Boot to be off in
the live session. It aborts if Secure Boot is on because the live session's ZFS
DKMS module is signed with a key not yet trusted by firmware, so the module cannot
load. The script checks this before touching the target disks.

The installed system has its own DKMS signing key. The installer queues that
key for MOK enrollment before exiting. Re-enable Secure Boot in firmware before
booting from the installed disks, then confirm **Enroll MOK** in MokManager using
the temporary password you set during installation. This enables Secure Boot for
the installed system without requiring the live session's key to be trusted.
