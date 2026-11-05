#!/usr/bin/env bash
# ==============================================================================
# Fedora Server: Btrfs-Mirror + LUKS2 + TPM2 (v5, überarbeitet)
# Menügeführt, alles Ermittelbare wird automatisch erkannt, du entscheidest nur.
# ==============================================================================
set -euo pipefail

STATE_DIR=/var/lib/fedora-mirror-setup
SYS_MAPPED="" SYS_PART="" DISK_S="" DISK_B=""
B1="" B2="" B3="" B4="" U3="" U4=""
KEYFILE=""

die()  { echo "[FEHLER] $*" >&2; return 1; }
info() { echo "[INFO] $*"; }

cleanup() {
    if [[ -n "${KEYFILE:-}" && -f "$KEYFILE" ]]; then
        shred -u "$KEYFILE" 2>/dev/null || rm -f "$KEYFILE"
    fi
}
trap cleanup EXIT

# ---------- Hilfsfunktionen ---------------------------------------------------

get_part_path() {            # $1 Disk, $2 Nummer -> nvme0n1p3 / sda3
    if [[ "$1" =~ [0-9]$ ]]; then echo "${1}p${2}"; else echo "${1}${2}"; fi
}

confirm() {                  # y/N
    local resp
    read -rp "$1 [y/N]: " resp
    [[ "$resp" =~ ^([yY]|[yY][eE][sS]|[jJ]|[jJ][aA])$ ]]
}

# Befehl -> Paket; fehlende Pakete werden installiert
ensure_cmds() {
    local pair cmd pkg missing=()
    for pair in "$@"; do
        cmd=${pair%%:*}; pkg=${pair##*:}
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$pkg")
    done
    if ((${#missing[@]})); then
        info "Installiere fehlende Pakete: ${missing[*]}"
        dnf install -y "${missing[@]}" || die "Paketinstallation fehlgeschlagen: ${missing[*]}"
    fi
}

check_tpm() {
    [[ -e /dev/tpmrm0 ]] || die "Kein TPM2 (/dev/tpmrm0) gefunden. In der Firmware aktivieren (fTPM/PTT)."
}

# PCR 7 bildet den Secure-Boot-Zustand ab. Ohne Secure Boot ist die Bindung nahezu wertlos.
check_secureboot() {
    local f val
    f=$(ls /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | head -n1 || true)
    if [[ -z "$f" ]]; then
        echo "[WARNUNG] Kein UEFI/SecureBoot-Eintrag gefunden (Legacy-Boot?). PCR 7 ist so nicht sinnvoll."
        confirm "Trotzdem fortfahren?" || return 1
        return 0
    fi
    val=$(od -An -t u1 -j4 -N1 "$f" | tr -d ' ')
    if [[ "$val" != "1" ]]; then
        echo "[WARNUNG] Secure Boot ist AUS. Die PCR-7-Bindung schützt dann kaum."
        confirm "Trotzdem fortfahren?" || return 1
    fi
}

mk_keyfile() {               # liest Passphrase, legt KEYFILE in /run (tmpfs) an
    KEYFILE=$(mktemp /run/luks_pass.XXXXXX)
    chmod 600 "$KEYFILE"
    printf '%s' "$1" > "$KEYFILE"
}

require_note_recovery() {
    local a=""
    echo ""
    echo "Die Recovery-Keys stehen oben. JETZT außerhalb dieses Rechners sichern"
    echo "(Passwortmanager, Ausdruck). Ohne sie bist du bei TPM-Defekt/Firmware-Update ausgesperrt."
    while [[ "$a" != "notiert" ]]; do
        read -rp "Zum Fortfahren 'notiert' eingeben: " a
    done
}

# Slots eines LUKS-Geräts prüfen: Typ recovery/tpm2 schon vorhanden?
has_slot() {                 # $1 Gerät, $2 recovery|tpm2
    systemd-cryptenroll "$1" 2>/dev/null | awk -v t="$2" '$2==t {f=1} END{exit !f}'
}

enroll_dev() {               # $1 Gerät, Keyfile mit Passphrase in $KEYFILE
    local dev=$1
    if has_slot "$dev" recovery; then
        info "$dev: Recovery-Key existiert bereits, übersprungen."
    else
        systemd-cryptenroll --unlock-key-file="$KEYFILE" --recovery-key "$dev"
    fi
    # --wipe-slot=tpm2 ersetzt einen evtl. vorhandenen TPM-Slot, damit erneutes Ausführen funktioniert
    systemd-cryptenroll --unlock-key-file="$KEYFILE" --tpm2-device=auto --tpm2-pcrs=7 \
        --wipe-slot=tpm2 "$dev"
}

# Option an die crypttab-Zeile eines bestimmten Mappernamens anhängen (idempotent)
crypttab_add_opt() {         # $1 Name, $2 Option, $3 optional: crypttab-Datei
    local name=$1 opt=$2 file=${3:-/etc/crypttab} tmp
    tmp=$(mktemp)
    awk -v name="$name" -v opt="$opt" '
        /^[[:space:]]*#/ || NF==0 { print; next }
        $1==name {
            if (NF<3) $3="none"
            if (NF<4) { $4=opt }
            else if (index(","$4",", ","opt",")==0 && index($4, opt)==0) { $4=$4","opt }
            print; next
        }
        { print }' "$file" > "$tmp"
    cat "$tmp" > "$file"     # cat statt mv: Rechte/SELinux-Kontext bleiben
    rm -f "$tmp"
}

crypttab_has() { grep -qE "^[[:space:]]*$1[[:space:]]" /etc/crypttab 2>/dev/null; }

# Kernel-Argument dauerhaft setzen: BLS-Einträge (grubby) UND /etc/kernel/cmdline,
# sonst fehlt es nach einem Kernel-Update vor dem nächsten Reboot.
add_karg() {
    local arg
    for arg in "$@"; do
        grubby --update-kernel=ALL --args="$arg"
        if [[ -f /etc/kernel/cmdline ]] && ! grep -qwF -- "$arg" /etc/kernel/cmdline; then
            printf '%s\n' "$(tr -d '\n' < /etc/kernel/cmdline) $arg" > /etc/kernel/cmdline
        fi
    done
}

rebuild_initrd() { dracut -f --regenerate-all; }

part_bytes() { blockdev --getsize64 "$1"; }

mount_part() {               # Partition hinter einem Mountpoint, nur wenn echte Partition
    local src
    src=$(findmnt -n -o SOURCE "$1" 2>/dev/null | head -n1 | cut -d'[' -f1 || true)
    [[ -n "$src" && -b "$src" ]] || return 0
    [[ "$(lsblk -no TYPE "$src" 2>/dev/null | head -n1)" == "part" ]] && echo "$src"
    return 0
}

prefix_to_mask() {           # 24 -> 255.255.255.0
    local p=$1 m="" i o
    for i in 1 2 3 4; do
        if   ((p>=8)); then o=255; p=$((p-8))
        elif ((p>0));  then o=$((256-(1<<(8-p)))); p=0
        else o=0; fi
        m+="${m:+.}$o"
    done
    echo "$m"
}

# ---------- Erkennung ---------------------------------------------------------

discover_system() {
    [[ -n "$SYS_PART" ]] && return 0
    local raw real ancestors dev type
    raw=$(findmnt -n -o SOURCE / | head -n1 | cut -d'[' -f1)
    [[ -b "$raw" ]] || { die "Root-Gerät nicht ermittelbar ($raw)"; return 1; }
    SYS_MAPPED=$raw
    real=$(readlink -f "$raw")
    ancestors=$(lsblk --inverse --noheadings --paths --raw --output NAME,TYPE "$real") \
        || { die "Gerätehierarchie für $real konnte nicht ermittelt werden."; return 1; }
    while read -r dev type; do
        if [[ "$type" == "part" ]] && cryptsetup isLuks "$dev" >/dev/null 2>&1; then
            SYS_PART=$dev
            break
        fi
    done <<< "$ancestors"
    [[ -n "$SYS_PART" ]] || { die "Root liegt nicht auf einer LUKS-verschlüsselten Partition."; return 1; }

    ancestors=$(lsblk --inverse --noheadings --paths --raw --output NAME,TYPE "$SYS_PART") \
        || { die "Gerätehierarchie für $SYS_PART konnte nicht ermittelt werden."; return 1; }
    while read -r dev type; do
        if [[ "$type" == "disk" ]]; then
            DISK_S=$dev
            break
        fi
    done <<< "$ancestors"
    [[ -n "$DISK_S" ]] || { die "Systemlaufwerk für $SYS_PART konnte nicht ermittelt werden."; return 1; }
}

target_candidates() {
    local sname; sname=$(basename "$DISK_S")
    lsblk -dn -o NAME,TYPE | awk -v s="$sname" \
        '$2=="disk" && $1!=s && $1!~/^(zram|loop|sr|fd|ram)/ {print "/dev/"$1}'
}

# Ziel-SSD: zuerst über Partitionslabel (schon vorbereitet), sonst Auswahl. Nur einmal pro Lauf.
discover_target() {
    [[ -n "$DISK_B" ]] && return 0
    discover_system || return 1
    local prefer_existing=${1:-yes} lab pk
    lab=$(readlink -f /dev/disk/by-partlabel/luks-mirror 2>/dev/null || true)
    if [[ "$prefer_existing" == yes && -n "$lab" && -b "$lab" ]]; then
        pk=$(lsblk -no PKNAME "$lab" | head -n1)
        [[ -n "$pk" ]] || { die "Laufwerk für $lab konnte nicht ermittelt werden."; return 1; }
        DISK_B="/dev/$pk"
    else
        local cands=() opt
        mapfile -t cands < <(target_candidates)
        ((${#cands[@]})) || { die "Keine zweite Festplatte gefunden."; return 1; }
        echo ""
        info "Mögliche Ziellaufwerke (System liegt auf $DISK_S):"
        lsblk -d -o NAME,SIZE,MODEL,SERIAL,TRAN,RM "${cands[@]}"
        if ((${#cands[@]}==1)); then
            DISK_B=${cands[0]}
            info "Einziger Kandidat: $DISK_B"
        else
            PS3="Nummer wählen: "
            select opt in "${cands[@]}"; do
                [[ -n "$opt" ]] && { DISK_B=$opt; break; }
            done
        fi
    fi
    [[ "$DISK_B" != "$DISK_S" ]] || { die "Ziel ist das Systemlaufwerk!"; return 1; }
    B1=$(get_part_path "$DISK_B" 1); B2=$(get_part_path "$DISK_B" 2)
    B3=$(get_part_path "$DISK_B" 3); B4=$(get_part_path "$DISK_B" 4)
}

discover_uuids() {
    discover_target || return 1
    if [[ ! -b "$B3" || ! -b "$B4" ]]; then
        info "Partitionen auf $DISK_B fehlen im Geräteknoten-Cache; aktualisiere die Partitionstabelle."
        partprobe "$DISK_B" || { die "Partitionstabelle auf $DISK_B konnte nicht neu eingelesen werden."; return 1; }
        udevadm settle || { die "Auflösung der Partitionen auf $DISK_B ist fehlgeschlagen."; return 1; }
    fi
    if [[ -b "$B3" && -b "$B4" ]]; then
        U3=$(cryptsetup luksUUID "$B3" 2>/dev/null || true)
        U4=$(cryptsetup luksUUID "$B4" 2>/dev/null || true)
    fi
    [[ -n "$U3" && -n "$U4" ]] || {
        die "LUKS-Partitionen auf $DISK_B fehlen oder sind nicht lesbar (erwartet: $B3 und $B4). Prüfe 'lsblk -f $DISK_B'; Phase 2 nur erneut ausführen, wenn die Ziel-SSD wirklich neu eingerichtet werden soll."
        return 1
    }
}

ensure_open() {              # $1 Part, $2 UUID -> /dev/mapper/luks-UUID offen
    [[ -b "/dev/mapper/luks-$2" ]] && return 0
    info "Entsperre $1 per TPM/Passphrase ..."
    systemctl start "systemd-cryptsetup@luks-$2.service" 2>/dev/null \
        || cryptsetup open "$1" "luks-$2" \
        || die "Konnte $1 nicht entsperren."
}

show_status_summary() {
    echo ""
    echo "=================================================================="
    echo " STATUS"
    echo "=================================================================="
    findmnt / >/dev/null 2>&1 && {
        echo -e "\n[+] / (Btrfs):"
        btrfs filesystem show / 2>/dev/null || true
        btrfs filesystem usage / 2>/dev/null | grep -E 'Data,|Metadata,|System,|Free \(estimated\)' || true
    }
    findmnt /srv/data >/dev/null 2>&1 && {
        echo -e "\n[+] /srv/data:"
        btrfs filesystem usage /srv/data 2>/dev/null | grep -E 'Data,|Metadata,|Free \(estimated\)' || true
    }
    echo "=================================================================="
}

# ---------- Phasen ------------------------------------------------------------

phase1_system_luks() {
    check_tpm || return 1
    ensure_cmds systemd-cryptenroll:systemd-udev cryptsetup:cryptsetup dracut:dracut
    discover_system || return 1
    check_secureboot || return 1
    local su name pass
    su=$(cryptsetup luksUUID "$SYS_PART")
    name="luks-$su"
    confirm "Recovery-Key und TPM2-Bindung (PCR 7) für $SYS_PART einrichten?" || return 0
    read -rsp "Bestehende System-LUKS-Passphrase: " pass; echo
    mk_keyfile "$pass"; unset pass
    enroll_dev "$SYS_PART"
    cleanup; KEYFILE=""
    require_note_recovery

    if ! crypttab_has "$name"; then
        die "Kein crypttab-Eintrag '$name' gefunden, bitte /etc/crypttab prüfen."; return 1
    fi
    crypttab_add_opt "$name" "tpm2-device=auto"
    printf 'add_dracutmodules+=" tpm2-tss "\n' > /etc/dracut.conf.d/tpm2.conf
    rebuild_initrd
    echo "[OK] Phase 1 abgeschlossen. Reboot-Test: Bootet er ohne Passphrase-Abfrage?"
}

phase2_setup_ssdb() {
    check_tpm || return 1
    ensure_cmds sgdisk:gdisk partprobe:parted wipefs:util-linux cryptsetup:cryptsetup \
                systemd-cryptenroll:systemd-udev grubby:grubby dracut:dracut
    # Alte Partitionslabels sind kein Beweis, dass das Laufwerk zur aktuellen Installation gehört.
    discover_target no || return 1

    # Sicherheitschecks am Ziel
    if lsblk -nr -o MOUNTPOINTS "$DISK_B" | grep -q '[^[:space:]]'; then
        die "Auf $DISK_B ist etwas eingehängt. Abbruch."; return 1
    fi
    echo ""
    lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,LABEL "$DISK_B"
    local typed
    echo "ACHTUNG: ALLE Daten auf $DISK_B werden unwiderruflich gelöscht."
    read -rp "Zur Bestätigung den Gerätenamen eintippen ($DISK_B): " typed
    [[ "$typed" == "$DISK_B" ]] || { echo "Abgebrochen."; return 1; }

    # Größen aus dem laufenden System ableiten
    local S1 S2 s1_mib=0 s2_mib=0 s3_bytes s3_mib p3_mib disk_mib need_mib data_mib
    S1=$(mount_part /boot/efi); S2=$(mount_part /boot)
    [[ -n "$S1" ]] && s1_mib=$(( $(part_bytes "$S1") / 1048576 ))
    [[ -n "$S2" ]] && s2_mib=$(( $(part_bytes "$S2") / 1048576 ))
    s3_bytes=$(part_bytes "$SYS_PART")
    s3_mib=$(( (s3_bytes + 1048575) / 1048576 ))
    p3_mib=$(( s3_mib + 8 ))      # etwas größer als die System-Partition (Btrfs nimmt das kleinere Gerät)
    disk_mib=$(( $(part_bytes "$DISK_B") / 1048576 ))
    need_mib=$(( 1 + s1_mib + s2_mib + p3_mib ))
    data_mib=$(( disk_mib - need_mib - 1 ))
    ((data_mib >= 1024)) || { die "$DISK_B ist zu klein (Rest für Daten nur ${data_mib} MiB)."; return 1; }
    info "Layout: ESP-Reserve ${s1_mib} MiB, Boot-Reserve ${s2_mib} MiB, Mirror ${p3_mib} MiB, Daten ~${data_mib} MiB"

    local pass1 pass2
    read -rsp "NEUE LUKS-Passphrase für SSD-B: " pass1; echo
    read -rsp "Wiederholen: " pass2; echo
    [[ "$pass1" == "$pass2" && -n "$pass1" ]] || { die "Passphrasen leer oder verschieden."; return 1; }
    mk_keyfile "$pass1"; unset pass1 pass2

    wipefs -a "$DISK_B" >/dev/null
    sgdisk --zap-all "$DISK_B" >/dev/null
    ((s1_mib > 1)) && sgdisk -n1:0:+$((s1_mib-1))M -t1:ef00 -c1:esp2  "$DISK_B"
    ((s2_mib > 1)) && sgdisk -n2:0:+$((s2_mib-1))M -t2:fd00 -c2:boot2 "$DISK_B"
    sgdisk -n3:0:+${p3_mib}M -t3:8309 -c3:luks-mirror "$DISK_B"
    sgdisk -n4:0:0           -t4:8309 -c4:luks-data   "$DISK_B"
    partprobe "$DISK_B"; udevadm settle

    cryptsetup luksFormat --type luks2 --batch-mode --key-file "$KEYFILE" "$B3"
    cryptsetup luksFormat --type luks2 --batch-mode --key-file "$KEYFILE" "$B4"
    U3=$(cryptsetup luksUUID "$B3"); U4=$(cryptsetup luksUUID "$B4")
    cryptsetup open --key-file "$KEYFILE" "$B3" "luks-$U3"
    cryptsetup open --key-file "$KEYFILE" "$B4" "luks-$U4"

    local dev
    for dev in "$B3" "$B4"; do enroll_dev "$dev"; done
    cleanup; KEYFILE=""
    require_note_recovery

    # Mirror-Partition: im initrd nötig (x-initrd.attach). Daten-LUKS: erst im laufenden System.
    # nofail bei beiden: ein fehlendes Gerät darf nicht den Start blockieren.
    crypttab_has "luks-$U3" || echo "luks-$U3 UUID=$U3 none discard,x-initrd.attach,nofail,tpm2-device=auto" >> /etc/crypttab
    crypttab_has "luks-$U4" || echo "luks-$U4 UUID=$U4 none discard,nofail,tpm2-device=auto" >> /etc/crypttab
    add_karg "rd.luks.uuid=$U3"
    rebuild_initrd
    echo "[OK] Phase 2 abgeschlossen."
}

phase3_enable_mirror() {
    ensure_cmds btrfs:btrfs-progs dracut:dracut partprobe:parted
    discover_uuids || return 1
    ensure_open "$B3" "$U3" || return 1
    local m="/dev/mapper/luks-$U3" sys_sz mir_sz
    sys_sz=$(part_bytes "$SYS_MAPPED"); mir_sz=$(part_bytes "$m")
    ((mir_sz >= sys_sz)) || { die "Mirror-Gerät ist kleiner als das System-Gerät."; return 1; }
    if btrfs filesystem show / | grep -q "$m"; then
        info "$m ist bereits Teil des Dateisystems."
    else
        confirm "Mirror starten (Gerät hinzufügen + Balance auf RAID1)?" || return 0
        btrfs device add "$m" /
    fi
    # soft: bereits konvertierte Chunks überspringen (wiederholbar nach Abbruch)
    btrfs balance start -dconvert=raid1,soft -mconvert=raid1,soft /
    rebuild_initrd
    echo "[OK] Phase 3 abgeschlossen."
    show_status_summary
}

phase4_setup_data() {
    ensure_cmds mkfs.btrfs:btrfs-progs
    discover_uuids || return 1
    ensure_open "$B4" "$U4" || return 1
    local m="/dev/mapper/luks-$U4" fs_uuid
    if blkid -o value -s TYPE "$m" >/dev/null 2>&1; then
        echo "[WARNUNG] $m enthält bereits ein Dateisystem ($(blkid -o value -s TYPE "$m"))."
        confirm "Trotzdem NEU formatieren (Daten gehen verloren)?" || return 0
    else
        confirm "Daten-Dateisystem auf $m anlegen und nach /srv/data einhängen?" || return 0
    fi
    mkfs.btrfs -f -L data -m dup "$m"
    mkdir -p /srv/data
    fs_uuid=$(blkid -s UUID -o value "$m")
    grep -q '[[:space:]]/srv/data[[:space:]]' /etc/fstab || \
        echo "UUID=$fs_uuid /srv/data btrfs defaults,compress=zstd:1,nofail 0 0" >> /etc/fstab
    systemctl daemon-reload
    mount /srv/data
    echo "[OK] Phase 4 abgeschlossen."
    show_status_summary
}

phase5_setup_scrub() {
    cat > /etc/systemd/system/btrfs-scrub@.service <<'EOF'
[Unit]
Description=Btrfs scrub on %f
ConditionPathIsMountPoint=%f

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
ExecStart=/usr/bin/btrfs scrub start -B %f
EOF
    cat > /etc/systemd/system/btrfs-scrub@.timer <<'EOF'
[Unit]
Description=Monthly Btrfs scrub on %f

[Timer]
OnCalendar=monthly
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now 'btrfs-scrub@-.timer'
    if findmnt /srv/data >/dev/null 2>&1; then
        systemctl enable --now "btrfs-scrub@$(systemd-escape -p /srv/data).timer"
    fi
    echo "[OK] Scrub-Timer aktiv."
}

install_dracut_sshd() {
    rpm -q dracut-sshd >/dev/null 2>&1 && return 0
    dnf install -y dracut-network || return 1
    # 1) Fedora-Repos
    dnf install -y dracut-sshd 2>/dev/null && return 0
    # 2) COPR des Projektautors; Chroot-Name aus der laufenden Version
    dnf install -y dnf5-plugins || true
    if dnf copr enable -y gsauthof/dracut-sshd 2>/dev/null \
       || dnf copr enable -y gsauthof/dracut-sshd "fedora-$(rpm -E %fedora)-$(uname -m)" 2>/dev/null; then
        dnf install -y dracut-sshd && return 0
    fi
    # 3) Direkt von GitHub (Modul ins dracut-Verzeichnis kopieren)
    local d; d=$(mktemp -d)
    if curl -fsSL https://github.com/gsauthof/dracut-sshd/archive/refs/heads/master.tar.gz \
         | tar -xz -C "$d" --strip-components=1 && [[ -d "$d/46sshd" ]]; then
        cp -a "$d/46sshd" /usr/lib/dracut/modules.d/
        rm -rf "$d"; return 0
    fi
    rm -rf "$d"
    return 1
}

phase6_setup_dracut_ssh() {
    ensure_cmds grubby:grubby dracut:dracut
    install_dracut_sshd || { die "dracut-sshd ließ sich nicht installieren (Repo, COPR, GitHub)."; return 1; }

    # Ohne authorized_keys wäre das Remote-Entsperren unbenutzbar
    mkdir -p /root/.ssh; chmod 700 /root/.ssh
    if [[ ! -s /root/.ssh/authorized_keys ]]; then
        echo "Keine /root/.ssh/authorized_keys vorhanden. Öffentlichen SSH-Schlüssel einfügen (ssh-ed25519 ...):"
        local key; read -r key
        [[ "$key" =~ ^(ssh-|ecdsa-|sk-) ]] || { die "Kein gültiger öffentlicher Schlüssel."; return 1; }
        printf '%s\n' "$key" >> /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
    fi

    # Netzwerk automatisch ermitteln
    local iface gw cidr ip pfx mask choice host
    iface=$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    gw=$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')
    cidr=$(ip -4 -o addr show dev "${iface:-none}" scope global 2>/dev/null | awk '{print $4; exit}')
    ip=${cidr%/*}; pfx=${cidr#*/}
    host=$(hostname -s)
    echo "Erkannt: Interface=${iface:-?} IP=${ip:-?}/${pfx:-?} Gateway=${gw:-?}"
    echo "1) DHCP   2) Statisch (erkannte Werte als Vorschlag)"
    read -rp "Auswahl [1]: " choice; choice=${choice:-1}
    if [[ "$choice" == 2 ]]; then
        local in
        read -rp "IP [$ip]: " in;        ip=${in:-$ip}
        read -rp "Gateway [$gw]: " in;   gw=${in:-$gw}
        read -rp "Präfixlänge [$pfx]: " in; pfx=${in:-$pfx}
        read -rp "Interface [$iface]: " in; iface=${in:-$iface}
        [[ -n "$ip" && -n "$gw" && -n "$pfx" && -n "$iface" ]] || { die "Angaben unvollständig."; return 1; }
        mask=$(prefix_to_mask "$pfx")
        add_karg "rd.neednet=1" "ip=${ip}::${gw}:${mask}:${host}:${iface}:none"
    else
        add_karg "rd.neednet=1" "ip=dhcp"
    fi
    rebuild_initrd
    echo "[OK] Phase 6 abgeschlossen. Test nach Reboot: ssh root@${ip:-<IP>} im initrd,"
    echo "     dann: systemd-tty-ask-password-agent --query"
}

phase7_setup_autoupdates() {
    dnf install -y dnf5-plugin-automatic || { die "dnf5-plugin-automatic nicht installierbar."; return 1; }
    # dnf5 liest Overrides aus /etc/dnf/dnf5-plugins/automatic.conf (nicht /etc/dnf/automatic.conf)
    mkdir -p /etc/dnf/dnf5-plugins
    cat > /etc/dnf/dnf5-plugins/automatic.conf <<'EOF'
[commands]
apply_updates = yes
EOF
    systemctl enable --now dnf5-automatic.timer
    echo "[OK] Automatische Updates aktiv. Neustart-Bedarf prüfen mit: dnf needs-restarting -r"
}

# Optional, bewusst nicht Teil des Standardablaufs
phase8_degraded_boot() {
    cat <<'EOF'
Setzt rootflags=degraded. WICHTIG:
 - Ohne diese Option bootet ein Btrfs-RAID1-Root bei fehlender SSD NICHT.
 - Mit der Option wird auch gemountet, wenn die zweite SSD nur verspätet erscheint;
   es wird dann auf EINEM Gerät geschrieben, danach ist ein Scrub nötig.
 - Ob der Start headless wirklich durchläuft, hängt von systemd/udev ab
   (bekanntes Problem, Fedora-Bug 2114677). Vorher durch Abziehen der SSD testen.
EOF
    confirm "rootflags=degraded setzen?" || return 0
    add_karg "rootflags=degraded"
    rebuild_initrd
    echo "[OK] gesetzt."
}

run_phase() { bash "${BASH_SOURCE[0]}" --phase "$1" || echo "[FEHLER] $1 abgebrochen (Exit $?)."; }

main() {
    if [[ $EUID -ne 0 ]]; then die "Bitte als root ausführen."; exit 1; fi
    mkdir -p "$STATE_DIR"
    if [[ "${1:-}" == "--phase" ]]; then "$2"; exit $?; fi
    while true; do
        cat <<'EOF'
==================================================================
 Fedora Server: Btrfs-Mirror & LUKS & TPM2 (v5)
==================================================================
 1) System-LUKS: Recovery-Key, TPM2, dracut
 2) Ziel-SSD partitionieren und LUKS einrichten
 3) Btrfs-RAID1-Mirror aktivieren (Balance)
 4) Daten-Btrfs auf Ziel-SSD (/srv/data)
 5) Scrub-Timer
 6) Remote-Entsperren per SSH (dracut-sshd)
 7) Automatische Updates
 8) Optional: Degraded-Boot erlauben
 9) Status
 Q) Beenden
==================================================================
EOF
        local choice
        read -rp "Auswahl: " choice
        # Jede Phase läuft in einem eigenen Prozess: set -e bleibt dort voll aktiv
        # (in einer Subshell mit "|| true" würde es stillschweigend abgeschaltet),
        # und ein Fehler beendet nur die Phase, nicht das Menü.
        case "$choice" in
            1) run_phase phase1_system_luks ;;
            2) run_phase phase2_setup_ssdb ;;
            3) run_phase phase3_enable_mirror ;;
            4) run_phase phase4_setup_data ;;
            5) run_phase phase5_setup_scrub ;;
            6) run_phase phase6_setup_dracut_ssh ;;
            7) run_phase phase7_setup_autoupdates ;;
            8) run_phase phase8_degraded_boot ;;
            9) show_status_summary ;;
            [qQ]) exit 0 ;;
            *) echo "Ungültige Auswahl." ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
