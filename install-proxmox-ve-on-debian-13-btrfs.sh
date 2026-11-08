#!/usr/bin/env bash
# Install Proxmox VE on the Debian 13 Btrfs/LUKS baseline in two stages.
# Stage one installs the Proxmox kernel and stops for a reboot; stage two
# completes the PVE installation only after that kernel has booted successfully.
# SPDX-License-Identifier: Apache-2.0
set -Eeuo pipefail

readonly PVE_KEY_URL=https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg
readonly PVE_KEY_SHA256=136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45
readonly PVE_REPO_FILE=/etc/apt/sources.list.d/pve-install-repo.sources
readonly PVE_KEY_FILE=/usr/share/keyrings/proxmox-archive-keyring.gpg
readonly HOSTS_BACKUP=/etc/hosts.pre-proxmox

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

update_package_lists() {
  if ! apt-get update -o APT::Update::Error-Mode=any; then
    die "APT could not refresh every repository. Resolve the reported network, proxy, or certificate error before continuing."
  fi
}

[[ $EUID -eq 0 ]] || die "run as root (sudo -i)"
[[ -r /etc/os-release ]] || die "cannot identify the operating system"
# shellcheck disable=SC1091
. /etc/os-release
[[ ${ID:-} == debian && ${VERSION_ID:-} == 13 ]] \
  || die "this script is for Debian 13 (Trixie)"
[[ $(dpkg --print-architecture) == amd64 ]] \
  || die "Proxmox VE on Debian requires amd64"
[[ -d /sys/firmware/efi ]] || die "boot this system in UEFI mode"
[[ $(findmnt -n -o FSTYPE /) == btrfs ]] \
  || die "the root filesystem is not Btrfs; this add-on targets the Debian Btrfs baseline"
[[ $(grub-probe --target=fs /boot 2>/dev/null) == btrfs ]] \
  || die "GRUB does not identify /boot as Btrfs"
[[ -f /etc/dracut.conf.d/90-btrfs-luks-tpm.conf ]] \
  || die "expected Btrfs/LUKS dracut configuration is missing"
[[ -x /usr/local/sbin/sync-efi ]] \
  || die "the baseline sync-efi helper is missing"
grep -Eq '[[:space:]]/boot/efi2[[:space:]]' /etc/fstab \
  || die "the second EFI partition is not configured in /etc/fstab"
grep -Eq 'root=UUID=[^ "]+' /etc/default/grub \
  && grep -q 'rootflags=subvol=@' /etc/default/grub \
  && grep -q 'rd.luks.name=' /etc/default/grub \
  || die "GRUB is missing the baseline's Btrfs/LUKS root kernel parameters"

for cmd in apt-get awk cp curl dpkg dpkg-query dracut find findmnt getent grep \
  grub-probe hostname install ip lsinitrd mktemp mount mountpoint mv od passwd \
  rm sha256sum sort systemctl tail tr ufw umount update-grub; do
  command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
done

secure_boot_state=
for efivar in /sys/firmware/efi/efivars/SecureBoot-*; do
  [[ -r $efivar ]] || continue
  secure_boot_state=$(od -An -t u1 -j4 -N1 "$efivar" 2>/dev/null | tr -d '[:space:]')
  [[ -n $secure_boot_state ]] && break
done
if [[ -z $secure_boot_state ]] && command -v mokutil >/dev/null 2>&1; then
  if mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
    secure_boot_state=1
  elif mokutil --sb-state 2>/dev/null | grep -qi 'disabled'; then
    secure_boot_state=0
  fi
fi
[[ $secure_boot_state == 0 ]] \
  || die "Secure Boot must be disabled before installing/booting the Proxmox kernel; state is ${secure_boot_state:-unknown}"

NODE_NAME=$(hostname -s)
[[ $NODE_NAME =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] \
  || die "the current short hostname is not a valid single DNS label"

active_global_ips() {
  ip -o address show scope global \
    | awk '{sub(/\/.*/, "", $4); print $4}'
}

setup_hosts_entry() {
  local host_ip tmp_hosts
  local -a candidates
  mapfile -t candidates < <(active_global_ips)
  ((${#candidates[@]} > 0)) \
    || die "no globally scoped IP address is currently assigned"

  printf 'Current global addresses:\n'
  printf '  %s\n' "${candidates[@]}"
  read -rp "Stable/reserved address for $NODE_NAME: " host_ip
  [[ -n $host_ip ]] || die "an address is required"
  printf '%s\n' "${candidates[@]}" | grep -Fxq -- "$host_ip" \
    || die "$host_ip is not currently assigned to this host"

  echo "Reserve this address in DHCP or configure it statically before relying on it."
  read -rp "Confirm $host_ip is stable for this node [y/N]: " confirmed
  [[ $confirmed == [yY] ]] || die "stable address was not confirmed"

  [[ -e $HOSTS_BACKUP ]] || cp -a /etc/hosts "$HOSTS_BACKUP"
  tmp_hosts=$(mktemp /etc/hosts.pve.XXXXXX)
  awk -v node="$NODE_NAME" '
    /^[[:space:]]*#/ { print; next }
    {
      has_node = 0
      for (i = 2; i <= NF; i++) if ($i == node) has_node = 1
      if (!has_node) { print; next }
      line = $1
      aliases = 0
      for (i = 2; i <= NF; i++) {
        if ($i != node) {
          line = line " " $i
          aliases++
        }
      }
      if (aliases > 0) print line
    }
  ' /etc/hosts > "$tmp_hosts"
  printf '%s\t%s\n' "$host_ip" "$NODE_NAME" >> "$tmp_hosts"
  install -o root -g root -m 0644 "$tmp_hosts" /etc/hosts
  rm -f "$tmp_hosts"

  getent ahosts "$NODE_NAME" \
    | awk -v target="$host_ip" '$1 == target { found = 1 } END { exit !found }' \
    || die "$NODE_NAME does not resolve to $host_ip after updating /etc/hosts"
  NODE_IP=$host_ip
  printf 'Hostname mapping: %s -> %s\n' "$NODE_NAME" "$NODE_IP"
}

install_repository() {
  local tmp_key
  install -d -m 0755 /usr/share/keyrings /etc/apt/sources.list.d

  if [[ ! -f $PVE_KEY_FILE ]] \
    || ! printf '%s  %s\n' "$PVE_KEY_SHA256" "$PVE_KEY_FILE" \
      | sha256sum --check --status; then
    tmp_key=$(mktemp)
    if ! curl --fail --location --silent --show-error \
      "$PVE_KEY_URL" --output "$tmp_key"; then
      rm -f "$tmp_key"
      die "could not download the Proxmox archive key"
    fi
    printf '%s  %s\n' "$PVE_KEY_SHA256" "$tmp_key" | sha256sum --check \
      || { rm -f "$tmp_key"; die "Proxmox archive key checksum verification failed"; }
    install -o root -g root -m 0644 "$tmp_key" "$PVE_KEY_FILE"
    rm -f "$tmp_key"
  fi

  if [[ -e $PVE_REPO_FILE ]]; then
    grep -Eq '^URIs: https?://download\.proxmox\.com/debian/pve$' "$PVE_REPO_FILE" \
      && grep -Fq 'Suites: trixie' "$PVE_REPO_FILE" \
      && grep -Fq 'Components: pve-no-subscription' "$PVE_REPO_FILE" \
      && grep -Fq "Signed-By: $PVE_KEY_FILE" "$PVE_REPO_FILE" \
      || die "$PVE_REPO_FILE already exists with different settings; inspect it manually"
    sed -i 's|^URIs: https://download.proxmox.com/debian/pve$|URIs: http://download.proxmox.com/debian/pve|' \
      "$PVE_REPO_FILE"
  else
    cat > "$PVE_REPO_FILE" <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
  fi
}

disable_enterprise_repository() {
  local source
  for source in /etc/apt/sources.list.d/pve-enterprise.list \
    /etc/apt/sources.list.d/pve-enterprise.sources; do
    [[ -f $source ]] || continue
    if grep -Fq 'enterprise.proxmox.com/debian/pve' "$source"; then
      [[ ! -e $source.disabled ]] \
        || die "cannot disable $source because $source.disabled already exists"
      mv -- "$source" "$source.disabled"
      info "disabled the Proxmox enterprise repository (no subscription configured)"
    fi
  done
}

sync_secondary_efi() {
  local mounted_here=no
  if ! mountpoint -q /boot/efi2; then
    mount /boot/efi2 || die "could not mount /boot/efi2"
    mounted_here=yes
  fi
  /usr/local/sbin/sync-efi || die "could not synchronize the second EFI partition"
  [[ $mounted_here == no ]] || umount /boot/efi2
}

verify_pve_initrd() {
  local kver=$1 image module pattern modules
  image="/boot/initrd.img-$kver"
  [[ -s /boot/vmlinuz-"$kver" ]] || die "Proxmox kernel image is missing for $kver"
  dracut --force "$image" "$kver"
  [[ -s $image ]] || die "dracut did not create $image"
  modules=$(lsinitrd -m "$image") \
    || die "could not read the dracut module list from $image"
  for module in btrfs crypt tpm2-tss; do
    case $module in
      btrfs) pattern='^(90)?btrfs$' ;;
      crypt) pattern='^(90)?crypt$' ;;
      tpm2-tss) pattern='^(91)?tpm2-tss$' ;;
    esac
    printf '%s\n' "$modules" | grep -Eq "$pattern" \
      || die "the initrd for $kver is missing the dracut module '$module'"
  done
}

confirm_install() {
  cat <<EOF

This optional add-on installs Proxmox VE on the existing Debian 13 Btrfs/LUKS
system. It does not repartition disks or automatically change network settings.

Secure Boot must be disabled and remain disabled to boot the Proxmox kernel.
A stable/reserved node IP is required. Stage one installs the Proxmox kernel
and stops; reboot and verify that kernel before running this script again to
install the remaining Proxmox packages.

The script will update Debian packages, add the Proxmox no-subscription
repository, enable access to TCP port 8006 in UFW, and remove Debian kernels
after the Proxmox kernel has booted successfully.
EOF
  read -rp $'\nType INSTALL to continue: ' answer
  [[ $answer == INSTALL ]] || { echo "Aborted."; exit 0; }
}

confirm_install
setup_hosts_entry
install_repository
disable_enterprise_repository

info "updating Debian and installing the Proxmox kernel"
update_package_lists
apt-get full-upgrade -y
update_package_lists
apt-get install -y proxmox-default-kernel
PVE_KERNEL=$(find /lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
  | awk '/^[0-9].*-pve$/ { print }' | sort -V | tail -n 1)
[[ -n $PVE_KERNEL ]] || die "proxmox-default-kernel did not install a Proxmox kernel"
verify_pve_initrd "$PVE_KERNEL"
update-grub
grep -Fq "vmlinuz-$PVE_KERNEL" /boot/grub/grub.cfg \
  || die "GRUB configuration does not contain the Proxmox kernel"
sync_secondary_efi

RUNNING_KERNEL=$(uname -r)
if [[ $RUNNING_KERNEL != *-pve || $RUNNING_KERNEL != "$PVE_KERNEL" ]]; then
  printf 'Installed and verified Proxmox kernel: %s\n' "$PVE_KERNEL"
  printf 'Currently running kernel: %s\n' "$RUNNING_KERNEL"
  printf '\nReboot into the installed Proxmox kernel before continuing:\n'
  printf '  systemctl reboot\n'
  printf '  uname -r    # must match the installed Proxmox kernel above\n'
  printf 'Then run this script again to complete the installation.\n'
  exit 0
fi

info "running Proxmox kernel $RUNNING_KERNEL; verifying encrypted Btrfs boot support"
update-grub
grep -Fq "vmlinuz-$PVE_KERNEL" /boot/grub/grub.cfg \
  || die "GRUB configuration does not contain the Proxmox kernel"

info "installing Proxmox VE packages (configure postfix when prompted)"
update_package_lists
apt-get install -y proxmox-ve postfix open-iscsi chrony

PVE_KERNEL=$(find /lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
  | awk '/^[0-9].*-pve$/ { print }' | sort -V | tail -n 1)
[[ -n $PVE_KERNEL ]] || die "no installed Proxmox kernel was found"
verify_pve_initrd "$PVE_KERNEL"
if [[ $RUNNING_KERNEL != "$PVE_KERNEL" ]]; then
  update-grub
  sync_secondary_efi
  printf '\nA newer Proxmox kernel was installed: %s (running: %s).\n' \
    "$PVE_KERNEL" "$RUNNING_KERNEL"
  printf 'Reboot into the new kernel, then run this script again.\n'
  exit 0
fi

# Keep the currently running Proxmox kernel and remove Debian's kernel packages.
mapfile -t DEBIAN_KERNELS < <(
  dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\n' 'linux-image-[0-9]*' 2>/dev/null \
    | awk '$1 == "ii" && $2 !~ /-pve/ { print $2 }'
)
if dpkg-query -W -f='${db:Status-Status}' linux-image-amd64 2>/dev/null \
  | grep -qx installed; then
  DEBIAN_KERNELS+=(linux-image-amd64)
fi
if ((${#DEBIAN_KERNELS[@]} > 0)); then
  info "removing Debian kernel packages: ${DEBIAN_KERNELS[*]}"
  apt-get remove -y "${DEBIAN_KERNELS[@]}"
fi
if dpkg-query -W -f='${db:Status-Status}' os-prober 2>/dev/null \
  | grep -qx installed; then
  apt-get remove -y os-prober
fi

verify_pve_initrd "$RUNNING_KERNEL"
update-grub
sync_secondary_efi

if command -v ufw >/dev/null 2>&1; then
  ufw allow 8006/tcp
fi

root_state=$(passwd -S root | awk '{print $2}')
if [[ $root_state != P ]]; then
  echo "Set a root password for Proxmox's root@pam web login."
  passwd root || die "could not set the root password"
fi

if ! systemctl is-active --quiet pveproxy; then
  systemctl --no-pager --full status pveproxy || true
  die "pveproxy is not active; inspect the service status above"
fi

PVE_URL_HOST=$NODE_IP
[[ $PVE_URL_HOST == *:* ]] && PVE_URL_HOST="[$PVE_URL_HOST]"
cat <<EOF

Proxmox VE installation completed.
  Web interface: https://$PVE_URL_HOST:8006
  Login realm:   PAM (root)

The existing network configuration was left unchanged. Before creating VMs,
configure a Linux bridge named vmbr0 and attach the physical NIC using the
Proxmox network documentation. Keep console/out-of-band access while changing
network settings. The EFI copies were synchronized; after future bootloader
updates, run: sudo sync-efi

The Debian kernel packages were removed as recommended by Proxmox.
EOF
