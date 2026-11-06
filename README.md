# Ubuntu Server 26.04 LTS — installation options

## Ubuntu Server

There is one maintained Ubuntu installation path: the
[Ubuntu encrypted-root guide](./README-ubuntu-26.04-luks-root.md) and its
[installer](./install-ubuntu-2604-luks-root-zfs-storage.sh).

It uses a mirrored ext4 root on mdraid/LUKS2/LVM and a separate LUKS2-backed
ZFS mirror for data at `/data`. Secure Boot stays enabled; TPM2 enrollment is
completed after the first boot. The installer erases both selected disks and
has not yet been boot-tested on hardware, so use disposable disks and follow
the guide's test checklist.

The former `install-2604-zfs-luks-tpm.sh` used a different design: ZFS-backed
`/boot` and root (`bpool`/`rpool`), plus a ZFS data pool. It has been retired
from the current branch to avoid presenting two competing Ubuntu installers.
Existing systems built with that layout are unaffected. The repository's
`verify.sh` is only for those existing ZFS-root systems; it does not validate
the maintained ext4-root installer.

## Fedora Server

For Fedora with Secure Boot enabled, a mirrored encrypted ext4 root, and
Btrfs RAID1 data storage, see the
[Fedora installation guide](./README-fedora-luks-root-btrfs-data.md) and
[Fedora live-media installer](./install-fedora-luks-root-btrfs-data.sh).

## Debian 13

The Debian 13 ZFS-root installation is separate from the Ubuntu and Fedora
installers. See the [Debian guide](./README-debian-13.md) and
[Debian installer](./install-debian-13-zfs-luks-tpm.sh).

## License and attribution

The repository includes the **Apache License 2.0** in [LICENSE](LICENSE).
Some files retain their original per-file license notices; see
[LICENSE-MIT](LICENSE-MIT) and [NOTICE](NOTICE) for attribution and details.

Provided **without warranty**; see the applicable license terms.
