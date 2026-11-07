# Encrypted, mirrored Linux installations

This repository contains three separate, destructive installers. Pick the
guide matching the operating system you intend to install; the scripts are not
interchangeable and should not be combined into one installation.

## Installation paths

| Operating system | Disk layout (in brief) | Boot-media Secure Boot | TPM2 | Installer and guide |
|---|---|---|---|---|
| Ubuntu Server 26.04 | ext4 root on mdraid/LUKS2/LVM; separate LUKS2-backed ZFS mirror at `/data` | Enabled | Enroll after first boot | [Installer](./install-ubuntu-26.04-luks-root-zfs-data.sh) · [Guide](./README-ubuntu-26.04-luks-root.md) |
| Fedora Server | ext4 root on mdraid/LUKS2/LVM; separate LUKS2-backed Btrfs RAID1 at `/data` | Enabled | Enroll after first boot | [Installer](./install-fedora-server-luks-root-btrfs-data.sh) · [Guide](./README-fedora-luks-root-btrfs-data.md) |
| Debian 13 | ZFS `bpool`, LUKS2-backed mirrored `rpool` and `dpool` | Disabled for installation; re-enable and enroll MOK before first installed boot | Optional; enroll after first boot | [Installer](./install-debian-13-zfs-luks-tpm.sh) · [Guide](./README-debian-13.md) |

These are different designs, not interchangeable editions of one installer:
Ubuntu and Fedora keep ZFS out of the root boot path, while Debian uses ZFS
for `/boot` and root. Fedora uses native Btrfs for data because this path does
not rely on an OpenZFS kernel module.

The Ubuntu and Fedora installers are experimental and have not been
boot-tested; the Debian installer is also not hardware-tested. Every installer
erases the two disks you select. Treat all of them as untrusted until you have
completed the relevant guide's tests on disposable disks.

## General installation workflow

1. Read the selected operating-system guide completely. Confirm its release,
   architecture, firmware, network, TPM, and disk requirements first.
2. Boot that operating system's specified live media. Secure Boot requirements
   differ: keep it enabled for Ubuntu and Fedora; Debian requires it disabled in
   the live session, then re-enabled for the installed system's MOK enrollment.
3. Download the matching installer using the command in its guide. Inspect the
   script and run `bash -n` before execution; a syntax check does not establish
   that the installer is safe for a particular machine.
4. Run it from the required live environment with root privileges. Verify both
   disk identities, sizes, and models before accepting the destructive
   confirmation. Keep console or out-of-band access available.
5. Follow the guide for first boot, Secure Boot/MOK steps, and TPM enrollment.
   Keep the LUKS passphrase offline as the recovery method; TPM unlock is not a
   substitute for a recovery key.
6. Complete the guide's degraded-disk, update, and recovery tests on disposable
   drives before storing important data.

Use the guides for their exact download commands and recovery steps. The URLs
in them point to the published `main` branch, not uncommitted changes in this
checkout. For reproducible installs, substitute a reviewed commit hash.

## Other scripts (not installation paths)

- [`configure-fedora-btrfs-root-mirror.sh`](./configure-fedora-btrfs-root-mirror.sh)
  is a menu-driven post-install tool for a separate Fedora Btrfs-root design.
  It is not the Fedora installer above and is not compatible with that
  installer's ext4-root layout. Its disk-setup phase erases the selected
  secondary disk; inspect its phases and confirm the existing system layout
  before using it.
- [`verify-legacy-ubuntu-zfs-root.sh`](./verify-legacy-ubuntu-zfs-root.sh)
  checks existing Ubuntu systems built with the retired ZFS-root boot layout.
  It does not validate the current Ubuntu, Fedora, or Debian installers.
- [`manage-samba-users.sh`](./manage-samba-users.sh) manages Samba accounts
  (`add`, `remove`, `passwd`, `disable`, `enable`, and `list`) on a system
  where Samba is already installed. It is unrelated to OS installation.

The former Ubuntu ZFS-root installer is retired from this branch. Existing
systems using its `bpool`/`rpool` design are unaffected.

## License and attribution

This repository's original files are licensed under the **Apache License 2.0**;
see [LICENSE](LICENSE). Third-party software and dependencies remain subject to
their own licenses.

Provided **without warranty**; see the applicable license terms.
