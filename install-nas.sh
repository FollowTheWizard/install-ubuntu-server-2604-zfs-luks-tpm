#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# Ubuntu NAS Server
# Ubuntu 26.04 LTS
#
# Installs:
#   - Cockpit
#   - Docker Engine + Compose
#   - Dockge
#   - Samba
#   - SMART / NVMe monitoring tools
#   - Useful administration tools
#
# Optional:
#   - Create ZFS datasets on an existing xpool
#
# SAFETY:
#   - Does NOT partition disks
#   - Does NOT format disks
#   - Does NOT create/destroy/import/export ZFS pools
#   - Does NOT modify LUKS
#   - Does NOT modify existing ZFS datasets
#   - Only creates explicitly requested NEW datasets
###############################################################################

readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FILE="/var/log/ubuntu-nas-setup.log"

# Expected environment from the current server
readonly EXPECTED_OS="Ubuntu"
readonly EXPECTED_VERSION_ID="26.04"

# Existing pools
readonly ROOT_POOL="rpool"
readonly BOOT_POOL="bpool"
readonly DATA_POOL="xpool"

# Docker locations
readonly DOCKER_ROOT="/srv/docker"
readonly STACKS_DIR="${DOCKER_ROOT}/stacks"
readonly DOCKER_DATA="${DOCKER_ROOT}/data"
readonly DOCKER_CONFIG="${DOCKER_ROOT}/config"

###############################################################################
# Logging
###############################################################################

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1

log() {
    echo
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
    echo
    echo "ERROR: $*" >&2
    echo
    exit 1
}

trap 'echo; echo "ERROR: Installation failed at line $LINENO."; echo "See $LOG_FILE"; exit 1' ERR

###############################################################################
# Root check
###############################################################################

[[ $EUID -eq 0 ]] || die "Run this script with sudo/root."

###############################################################################
# Header
###############################################################################

clear || true

cat <<'EOF'

============================================================
 Ubuntu NAS Server
 Ubuntu 26.04 LTS
============================================================

This installer adds a NAS/server management layer to Ubuntu.

Components:
  - Cockpit
  - Docker Engine
  - Docker Compose
  - Dockge
  - Samba
  - SMART / NVMe tools
  - ZFS administration tools

Storage:
  - Existing ZFS pools are NEVER recreated.
  - Existing ZFS datasets are NEVER modified.
  - Optional NEW datasets may be created on xpool.

============================================================

EOF

###############################################################################
# OS check
###############################################################################

log "Checking operating system..."

source /etc/os-release

[[ "${ID:-}" == "ubuntu" ]] ||
    die "This script requires Ubuntu."

[[ "${VERSION_ID:-}" == "$EXPECTED_VERSION_ID" ]] ||
    die "This script expects Ubuntu 26.04. Detected ${VERSION_ID:-unknown}."

[[ "$(uname -m)" == "x86_64" ]] ||
    die "This script currently expects x86_64."

echo "OS:       ${PRETTY_NAME}"
echo "Kernel:   $(uname -r)"
echo "Hostname: $(hostname)"

###############################################################################
# Hardware audit
###############################################################################

log "Hardware"

echo
echo "CPU:"
lscpu | grep -E 'Model name|Socket|Core|Thread|CPU\(s\):' || true

echo
echo "Memory:"
free -h

echo
echo "Network:"
ip -br addr

echo
echo "Default route:"
ip route | grep '^default' || true

###############################################################################
# Storage audit
###############################################################################

log "Block devices"

lsblk -e7 -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,UUID

echo
echo "Mounted filesystems:"
df -hT

echo
echo "ZFS pools:"
zpool list || true

echo
echo "ZFS pool status:"
zpool status -P || true

echo
echo "ZFS datasets:"
zfs list -o name,used,avail,refer,mountpoint,compression || true

echo
echo "LUKS devices:"
lsblk -o NAME,TYPE,FSTYPE,SIZE,MOUNTPOINTS |
    grep -iE 'crypt|luks' || true

echo
echo "mdadm:"
mdadm --detail --scan 2>/dev/null || true

###############################################################################
# Safety check
###############################################################################

log "Checking expected ZFS pools"

for pool in "$BOOT_POOL" "$ROOT_POOL" "$DATA_POOL"; do
    if ! zpool list -H -o name "$pool" >/dev/null 2>&1; then
        die "Expected ZFS pool '$pool' was not found. Refusing to continue."
    fi

    state="$(zpool get -H -o value health "$pool")"

    echo "Pool $pool: $state"

    [[ "$state" == "ONLINE" ]] ||
        die "Pool '$pool' is not ONLINE. Refusing to continue."
done

echo
echo "All expected pools are ONLINE."

###############################################################################
# Existing dataset detection
###############################################################################

log "Checking xpool"

if zfs list -H -o name "${DATA_POOL}/data" >/dev/null 2>&1; then
    echo "Dataset ${DATA_POOL}/data already exists."
else
    echo "Dataset ${DATA_POOL}/data does not currently exist."
fi

###############################################################################
# Dataset proposal
###############################################################################

echo
echo "============================================================"
echo " Proposed ZFS datasets"
echo "============================================================"
echo
echo "The installer can create the following NEW datasets:"
echo
echo "  ${DATA_POOL}/data"
echo "  ${DATA_POOL}/data/photos"
echo "  ${DATA_POOL}/data/documents"
echo "  ${DATA_POOL}/data/media"
echo "  ${DATA_POOL}/data/backups"
echo "  ${DATA_POOL}/docker"
echo
echo "These are DATASETS, not new disks or pools."
echo
echo "Nothing will be deleted or reformatted."
echo

read -r -p "Create these ZFS datasets? [y/N]: " CREATE_DATASETS

###############################################################################
# Main installation confirmation
###############################################################################

echo
echo "============================================================"
echo " Installation"
echo "============================================================"
echo
echo "The following software will be installed:"
echo
echo "  Cockpit"
echo "  Docker Engine"
echo "  Docker Compose"
echo "  Dockge"
echo "  Samba"
echo "  smartmontools"
echo "  nvme-cli"
echo "  administration utilities"
echo
echo "No storage pool or partition changes will be performed."
echo

read -r -p "Continue with NAS software installation? [y/N]: " CONFIRM

[[ "$CONFIRM" =~ ^[Yy]$ ]] ||
    die "Installation cancelled."

###############################################################################
# Package installation
###############################################################################

log "Updating package lists"

apt-get update

log "Installing base packages"

apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    apt-transport-https \
    software-properties-common \
    smartmontools \
    nvme-cli \
    zfsutils-linux \
    samba \
    samba-common-bin \
    cifs-utils \
    unzip \
    jq \
    git \
    htop \
    ncdu \
    iotop \
    lm-sensors \
    ethtool \
    pciutils \
    usbutils \
    tree \
    acl \
    attr

###############################################################################
# Cockpit
###############################################################################

log "Installing Cockpit"

if apt-cache policy cockpit | grep -q backports; then
    apt-get install -y -t "$(lsb_release -sc)-backports" cockpit
else
    apt-get install -y cockpit
fi

apt-get install -y \
    cockpit-pcp \
    cockpit-storaged \
    cockpit-networkmanager \
    cockpit-packagekit \
    cockpit-machines \
    cockpit-podman \
    pcp \
    libvirt-daemon-system \
    libvirt-clients

systemctl enable --now cockpit.socket

###############################################################################
# Docker repository
###############################################################################

log "Configuring official Docker repository"

install -m 0755 -d /etc/apt/keyrings

curl -fsSL \
    https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc

chmod a+r /etc/apt/keyrings/docker.asc

cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt-get update

###############################################################################
# Docker
###############################################################################

log "Installing Docker"

apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

systemctl enable --now docker

###############################################################################
# Docker configuration
###############################################################################

log "Configuring Docker"

mkdir -p /etc/docker

cat > /etc/docker/daemon.json <<'EOF'
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    }
}
EOF

systemctl restart docker

###############################################################################
# Docker directories
###############################################################################

log "Creating Docker directories"

install -d -m 0755 \
    "$DOCKER_ROOT" \
    "$STACKS_DIR" \
    "$DOCKER_DATA" \
    "$DOCKER_CONFIG"

###############################################################################
# Add admin to docker group
###############################################################################

if id admin >/dev/null 2>&1; then
    log "Adding admin to docker group"
    usermod -aG docker admin
else
    echo "WARNING: User 'admin' does not exist."
    echo "Docker group membership was not configured."
fi

###############################################################################
# Dockge
###############################################################################

log "Installing Dockge"

mkdir -p "${STACKS_DIR}/dockge"

cat > "${STACKS_DIR}/dockge/compose.yaml" <<'EOF'
services:
  dockge:
    image: louislam/dockge:1
    container_name: dockge
    restart: unless-stopped

    ports:
      - "5001:5001"

    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /srv/docker/stacks:/opt/stacks

    environment:
      - DOCKGE_STACKS_DIR=/opt/stacks
EOF

docker compose \
    -f "${STACKS_DIR}/dockge/compose.yaml" \
    up -d

###############################################################################
# ZFS datasets
###############################################################################

if [[ "$CREATE_DATASETS" =~ ^[Yy]$ ]]; then

    log "Creating requested ZFS datasets"

    DATASETS=(
        "${DATA_POOL}/data"
        "${DATA_POOL}/data/photos"
        "${DATA_POOL}/data/documents"
        "${DATA_POOL}/data/media"
        "${DATA_POOL}/data/backups"
        "${DATA_POOL}/docker"
    )

    for dataset in "${DATASETS[@]}"; do

        if zfs list -H -o name "$dataset" >/dev/null 2>&1; then
            echo "EXISTS: $dataset"
            continue
        fi

        echo "CREATE: $dataset"

        zfs create \
            -o compression=lz4 \
            "$dataset"
    done

    echo
    echo "Created/verified datasets:"
    zfs list -r "$DATA_POOL"

else
    log "ZFS dataset creation skipped"
fi

###############################################################################
# Samba
###############################################################################

log "Configuring Samba"

SAMBA_CONFIG="/etc/samba/smb.conf"
SAMBA_BACKUP="/etc/samba/smb.conf.backup.$(date '+%Y%m%d-%H%M%S')"

if [[ -f "$SAMBA_CONFIG" ]]; then
    cp -a "$SAMBA_CONFIG" "$SAMBA_BACKUP"
    echo "Existing Samba configuration backed up to:"
    echo "  $SAMBA_BACKUP"
fi

cat > "$SAMBA_CONFIG" <<'EOF'
[global]
   workgroup = WORKGROUP
   server string = Ubuntu NAS
   server role = standalone server

   security = user
   map to guest = never

   min protocol = SMB2
   max protocol = SMB3

   ea support = yes
   store dos attributes = yes

   vfs objects = acl_xattr
   map acl inherit = yes
   inherit acls = yes

   load printers = no
   printing = bsd
   printcap name = /dev/null
   disable spoolss = yes

   log file = /var/log/samba/log.%m
   max log size = 1000

[Data]
   comment = NAS Data
   path = /data

   browseable = yes
   read only = no

   valid users = @sambashare
   force group = sambashare

   create mask = 0660
   directory mask = 0770

   inherit permissions = yes
EOF

###############################################################################
# Samba group
###############################################################################

if ! getent group sambashare >/dev/null; then
    groupadd sambashare
fi

###############################################################################
# Data directory
###############################################################################

# The existing /data mount is left untouched.
# We only ensure the group exists and permissions allow Samba access.

if [[ -d /data ]]; then
    chgrp sambashare /data || true
    chmod 2770 /data || true
else
    echo "WARNING: /data does not exist."
    echo "Samba share will exist in configuration but cannot currently be used."
fi

###############################################################################
# Samba validation
###############################################################################

log "Validating Samba configuration"

testparm -s

systemctl enable --now smbd
systemctl enable --now nmbd || true

systemctl restart smbd

###############################################################################
# SMART monitoring
###############################################################################

log "Enabling smartd"

systemctl enable --now smartd

###############################################################################
# Final checks
###############################################################################

log "Final system checks"

echo
echo "Docker:"
docker --version

echo
echo "Compose:"
docker compose version

echo
echo "Docker containers:"
docker ps

echo
echo "Cockpit:"
systemctl is-active cockpit.socket

echo
echo "Samba:"
systemctl is-active smbd

echo
echo "SMART:"
systemctl is-active smartd

echo
echo "ZFS:"
zpool status

echo
echo "Datasets:"
zfs list

###############################################################################
# Final output
###############################################################################

SERVER_IP="$(hostname -I | awk '{print $1}')"

cat <<EOF

============================================================
 Installation complete
============================================================

Cockpit:
  https://${SERVER_IP}:9090

Dockge:
  http://${SERVER_IP}:5001

Samba:
  \\\\${SERVER_IP}\\Data

Docker:
  docker ps

ZFS:
  zpool status
  zfs list

Installation log:
  ${LOG_FILE}

IMPORTANT:
  The 'admin' user was added to the docker group.

  Log out and back in before using Docker without sudo.

Samba users are NOT automatically created.

Use:

  sudo ./scripts/samba-user.sh add USERNAME

============================================================

EOF
