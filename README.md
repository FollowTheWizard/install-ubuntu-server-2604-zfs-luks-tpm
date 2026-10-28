# Ubuntu Server 26.04 LTS — ZFS mirror, LUKS2 and TPM2 unlock

Interactive installer for Ubuntu Server 26.04 LTS (`resolute`) on two disks: mirrored ZFS boot, root and data pools, LUKS2 encryption for root and data, and TPM2 unlock with a passphrase fallback. Boot uses UEFI, shim/GRUB and a dracut initramfs.

Based on [FollowTheWizard/install-ubuntu-server-2604-zfs-luks-tpm](https://github.com/FollowTheWizard/install-ubuntu-server-2604-zfs-luks-tpm), revision 9.0, with the changes described below.

> **Destructive and not hardware-validated:** the installer erases both selected disks, including on repeat runs. Back up your data first. The current boot changes have had Bash syntax checks, not a complete installation or boot test. Do not treat a successful installer run as proof of single-disk bootability.

## Requirements

- An amd64 Ubuntu 26.04 live environment, booted in UEFI mode with Secure Boot enabled.
- Two target disks, approximately 80 GiB or larger each. Different capacities are supported.
- Internet access for package downloads; the live environment must support debootstrap for `resolute`.
- Optional TPM 2.0, enabled in firmware and exposed as `/dev/tpmrm0`. Without it, use the LUKS passphrase.

Prefer internal disks for a server. USB bridges can reset or enumerate slowly and cause a mirror member to become unavailable.

## Download and run the installer

In the Ubuntu live environment, open a terminal and run:

```bash
sudo apt-get update
sudo apt-get install -y curl ca-certificates

curl --fail --show-error --location \
  --output install-2604-zfs-luks-tpm.sh \
  https://raw.githubusercontent.com/FollowTheWizard/install-ubuntu-server-2604-zfs-luks-tpm/main/install-2604-zfs-luks-tpm.sh

# Read the downloaded script before executing it as root.
less install-2604-zfs-luks-tpm.sh
bash -n install-2604-zfs-luks-tpm.sh
sudo bash install-2604-zfs-luks-tpm.sh
```

This downloads the **published `main` branch**, not uncommitted changes in your local checkout. Commit and push local changes before downloading them on another machine. For a reproducible installation, replace `main` in the URL with a reviewed commit hash. HTTPS protects the transfer; it does not establish that the script itself is safe. Do not pipe the download directly into a root shell.

Select the two disks carefully, review the summary, and enter `YES` only when ready to erase them. The installer then asks for the LUKS passphrase. Remove the installation medium and reboot after completion.

**Never rerun this installer as a repair or update tool. Repeat runs erase the target disks again.**

## Installation prompts

| Setting | Default | Notes |
|---|---|---|
| First and second disk | Interactive selection | The detected live medium is excluded; verify disk identities yourself |
| Hostname | `ubuntu-server` | |
| Administrator | `admin` | Member of `sudo` and `adm` |
| Administrator password | No default | At least 10 characters; also used for SSH login |
| Timezone / locale | `Etc/UTC` / `en_US.UTF-8` | Other installed definitions can be selected |
| Extra space | `pool` | When capacities differ sufficiently: optional unmirrored pool on the larger disk, or `none` |
| TPM PCRs | `7` | `0,7` also binds to firmware measurements |
| Enroll TPM now | `now`, when available | Passphrase remains a fallback |
| LUKS passphrase | No default | At least 8 characters; use a long, unique passphrase and keep it offline |

## SSH login and a simpler password

SSH password login is enabled for the administrator created during installation. Root SSH login is disabled. The SSH password is the **Linux account password**, not the LUKS disk-unlock passphrase.

Find the server address at its console:

```bash
hostname -I
```

From another computer, replace `SERVER_IP` with that address (and `admin` if you chose another username):

```bash
ssh admin@SERVER_IP
```

To change your own login/SSH password after logging in:

```bash
passwd
```

Choose an easier-to-type but still strong password, such as a unique multiword passphrase. The installed system's password policy may reject weak passwords. Changing this password does **not** change any LUKS passphrase or TPM enrollment.

For an isolated test installation only, you can lower the installer's account-password length check **before running it**. Find this line in `install-2604-zfs-luks-tpm.sh`:

```bash
ask_secret "Password for $NEW_USER" 10; USER_PASS=$REPLY
```

The `10` is the minimum length. Changing it to `8` allows an eight-character account password at the installer prompt; it does not change the separate LUKS prompt or disable the installed system's password policy. This is a weaker choice, not a recommended production configuration. No password requirements have been reduced by default.

For convenient access without repeatedly typing a password, prefer SSH keys. On a client with OpenSSH tools:

```bash
ssh-keygen -t ed25519
ssh-copy-id admin@SERVER_IP
ssh admin@SERVER_IP
```

Protect the private key with a passphrase and use an SSH agent. Verify key-based access in a second session before disabling password authentication. Do not expose weak password authentication to the Internet.

## Disk layout

Partition sizes are based on the smaller disk.

| Partition | Size | Purpose |
|---|---|---|
| 1 | 1 GiB | FAT32 EFI System Partition; `/boot/efi` or `/boot/efi2` |
| 2 | 2 GiB | Mirrored `bpool`, GRUB-compatible, containing `/boot` |
| 3 | 4 GiB | Encrypted swap with a new random key each boot |
| 4 | 64 GiB | LUKS2 → `luks-root1/2` → mirrored `rpool` |
| 5 | Remaining shared capacity | LUKS2 → `luks-data1/2` → mirrored `dpool` |
| 6 | Optional excess capacity | LUKS2 → extra single-disk pool; **no redundancy** |

Key datasets:

- `rpool/ROOT/ubuntu`: `/`, also recorded as the pool's `bootfs`.
- `bpool/BOOT/ubuntu`: `/boot`, mounted through `fstab` using a legacy mountpoint.
- `rpool/var/log` and `rpool/var/spool`: legacy mounts through `fstab`.
- Other OS datasets: `/var/cache`, `/var/tmp`, `/tmp`, `/srv` and `/root`.
- `dpool/home`: `/home`; `dpool/data`: `/data`.

Root and data use LUKS2 with AES-XTS and Argon2id passphrase derivation. A TPM enrollment is added only when selected and available. EFI partitions and `bpool`, including the kernel and initramfs, are not encrypted.

## Boot ordering and missing-disk behavior

```text
UEFI → shim → signed GRUB → kernel + dracut initramfs from bpool
  → attempt LUKS root unlock (TPM2 or passphrase)
  → import rpool → mount /sysroot → switch to the installed system
  → attempt data unlock → import dpool → mount data datasets
```

The installer now:

- Explicitly orders ZFS scan import after the root LUKS unlock services. `After=cryptsetup.target` alone does not wait for crypttab entries marked `nofail`.
- Orders data-pool import after the data unlock services and accepts either data mirror member.
- Uses `cachefile=none` for pool creation, keeps the target cache empty, and adds scan/cache service drop-ins to avoid using a stale import cache.
- Includes the host ID, crypttab and import drop-ins in dracut, requests early ZFS driver loading, and checks generated images for the host ID and scan override.
- Sets 20-second missing-device timeouts for optional encrypted devices, EFI partitions and swap. Slow hardware may require longer timeouts. These are device-discovery timeouts, not password-entry deadlines.
- Enables forced ZFS import with `zfs_force=1` and fallback import commands. **Do not attach these pools to another active host:** forced import can bypass the protection against importing a pool in use elsewhere.

These changes are intended to permit degraded boot with either disk missing; they are not a hardware-tested guarantee. A missing disk may leave failed cryptsetup units even when boot succeeds. Data has no redundancy until the mirror is restored. The optional extra pool cannot survive loss of its disk.

Before relying on redundancy, install on disposable test disks and test all of these cases:

1. Both disks present, with TPM unlock and with passphrase fallback.
2. Shut down fully, disconnect disk 1, and boot from disk 2.
3. Shut down fully, reconnect disk 1, restore/check mirror health, then test with disk 2 disconnected.
4. Reconnect both disks and confirm all mirrors have finished resilvering and are healthy.

Check the UEFI boot entry for each disk. An EFI copy alone does not guarantee firmware will select the surviving disk. Do not hot-unplug disks for this test.

## After installation

```bash
sudo zpool status
swapon --show
df -h /boot /boot/efi /data
sudo ufw status
systemctl --failed
```

Download the actual verification script, named **`verify.sh`**:

```bash
curl --fail --show-error --location \
  --output verify.sh \
  https://raw.githubusercontent.com/FollowTheWizard/install-ubuntu-server-2604-zfs-luks-tpm/main/verify.sh
less verify.sh
sudo bash verify.sh
```

Use the same reviewed commit as the installer when pinning downloads. The checker runs after boot and reports PASS/WARN/FAIL for partitioning, EFI, pools, LUKS/TPM, configuration, initramfs and services. Some checks expect both disks and report failures for an intentionally degraded mirror; it is not an automated degraded-boot test.

| Command | Use |
|---|---|
| `sudo enroll-tpm2 [PCRS]` | Enroll/re-enroll after first boot or firmware, Secure Boot, TPM or disk changes; the passphrase remains |
| `sudo sync-efi` | Copy the primary ESP to the mounted secondary ESP after shim/GRUB updates; both ESPs must be available |
| `sudo zpool scrub rpool bpool dpool` | Periodically scrub all mirrored pools |

TPM enrollment from the live environment may not match the installed system's PCR measurements. If asked, enter the passphrase at boot, then re-enroll from the installed system.

## Changes from revision 9.0

- UFW rules are written inside the chroot without running `ufw enable` against the live kernel. UFW is enabled for first boot only if writing the SSH allow rule succeeds.
- Root and data pool import ordering now accounts for `nofail` LUKS devices, with bounded device waits and explicit initramfs configuration.
- Pools use scan-based import rather than a persistent cache; the root dataset has a `bootfs` property.
- GRUB is installed on both ESPs. Stale disk-2 NVRAM entries are removed; creation failure produces a warning rather than aborting teardown.
- `verify.sh` checks explicit root/data unlock ordering, EFI content and boot entries, and includes fixes for pipeline/SIGPIPE false negatives and device detection.

**Remaining limitations:** current installation and boot changes have not been validated in a full VM or hardware boot cycle. The installer still treats some teardown/export failures as warnings. Its completion message is not a guarantee of a clean export or successful boot. The initramfs checks cover selected artifacts, not every driver, dependency or boot path.

## Storage and security notes

- The OS pool is fixed at 64 GiB. Put large Docker, VM and media datasets on `dpool`, not `/var/lib` on `rpool`. Configure each application to wait for its data mount.
- Mirroring is not a backup. Keep independent backups and an offline copy of the LUKS passphrase.
- TPM auto-unlock without a PIN permits unattended boot; it does not stop someone from powering on the complete machine. Account authentication and OS security remain essential.
- PCR 7 binding is not a guarantee that every boot artifact is authenticated. The unencrypted boot pool and actual Secure Boot/initramfs verification policy need separate consideration.
- Discards pass through LUKS and can reveal which blocks are unused.
- Networking uses DHCP on `en*` interfaces; adapt `/etc/netplan/01-netcfg.yaml` for other interface names.
- Disk replacement requires replacing members of **bpool, rpool and dpool**, updating LUKS UUIDs in crypttab and GRUB, rebuilding initramfs/GRUB, restoring the ESP and TPM enrollment. Test a replacement procedure before production use; do not rerun this destructive installer.

## License and attribution

The repository includes the **Apache License 2.0** in [LICENSE](LICENSE). The installer retains its original **MIT** per-file license notice; the MIT terms are included in [LICENSE-MIT](LICENSE-MIT). `verify.sh` and `samba-user.sh` identify Apache-2.0 in their headers.

[NOTICE](NOTICE) records the source, modifications and the historical difference between the repository license and the installer's notice. Preserve the applicable license texts and attribution when redistributing. This does not assert that every file is dual-licensed or remove the original author's rights. The placeholder in the Apache license appendix is part of the standard license template, not a missing project copyright declaration.

Provided **without warranty**; see the applicable license terms.
