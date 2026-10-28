# Ubuntu Server 26.04 LTS – ZFS-Mirror + LUKS2 + TPM2-Unlock (rev. 9.0-p1)

Interaktives Ein-Datei-Installationsscript: Ubuntu Server 26.04 LTS („resolute“) auf **zwei Platten** als **ZFS-Mirror**, darunter **LUKS2-Vollverschlüsselung**. Entsperrt wird beim Boot **automatisch per TPM 2.0** oder per **Passphrase** als Fallback.

Dies ist eine **gepatchte Kopie** von
`FollowTheWizard/install-ubuntu-server-2604-zfs-luks-tpm` (rev. 9.0). Siehe [Änderungen](#änderungen-gegenüber-rev-90).

> ⚠️ **Nicht auf Hardware getestet.** Der Upstream-Test (HP ProDesk 400 G6, 256-GB-NVMe + USB-NVMe) bezog sich auf das ältere Layout rev. 8.2. Das hier verwendete Layout (rev. 9.0) und meine Patches sind ungetestet. Das Script **löscht beide gewählten Platten komplett**. Daten vorher sichern, Script lesen, Wiederherstellung testen, bevor wichtige Daten darauf liegen.

---

## Voraussetzungen

| Punkt | Anforderung |
|---|---|
| Firmware | UEFI, **Secure Boot aktiv** (das Script bricht sonst ab; PCR 7 ist ohne Secure Boot wertlos) |
| TPM | TPM 2.0, in der Firmware aktiviert (`/dev/tpmrm0`). Ohne TPM läuft die Installation, du tippst dann bei jedem Boot die Passphrase und rufst später `sudo enroll-tpm2` auf |
| Platten | Zwei Stück, je ca. **80 GiB+**, Größen dürfen abweichen. **Beide werden komplett gelöscht** |
| Netz | Pflicht (debootstrap lädt ca. 500 MB) |
| Medium | Ubuntu **26.04.1** Live-ISO (Desktop „Try Ubuntu“ oder Server-Shell), im UEFI-Modus gebootet |

---

## Schnellstart

```bash
# 1. Live-ISO im UEFI-Modus mit Secure Boot booten, Netzwerk verbinden
mokutil --sb-state          # muss "SecureBoot enabled" zeigen
ls /dev/tpmrm0              # existiert, wenn das TPM nutzbar ist

# 2. Script auf das Live-System bringen (USB-Stick, scp, nano) und als root starten
sudo -i
bash install-2604-zfs-luks-tpm.sh

# 3. Fragen beantworten, bei der Zusammenfassung YES tippen, LUKS-Passphrase setzen.
#    Dauer ca. 10–20 Minuten. Medium entfernen, neu starten.
```

Das Script ist wiederholbar: Es löst die Zielplatten selbst von Mounts, Pools und Holdern, bevor es partitioniert.

---

## Was das Script fragt

| Frage | Standard | Hinweis |
|---|---|---|
| Erste / zweite Platte | – | nummerierte Liste mit Größe, Modell und by-id-Name; das Live-Medium wird ausgeblendet |
| Hostname | `ubuntu-server` | |
| Admin-Benutzer | `admin` | bekommt `sudo` und `adm` |
| Admin-Passwort | – | mind. 10 Zeichen, **zugleich SSH-Login-Passwort** |
| Zeitzone / Locale | `Etc/UTC` / `en_US.UTF-8` | z. B. `Europe/Berlin`, `de_DE.UTF-8` |
| Restplatz | `pool` | nur wenn die Platten ≥ 1 GiB abweichen: `pool` = unmirrored LUKS-Pool auf der größeren Platte, `none` = ungenutzt |
| PCRs fürs TPM | `7` | `7` = Secure-Boot-Zustand; `0,7` = zusätzlich Firmware-Code (nach jedem Firmware-Update Passphrase nötig) |
| TPM jetzt enrollen? | `now` | nur wenn `/dev/tpmrm0` vorhanden ist |
| **`YES` tippen** | – | bis hierhin wurde nichts geschrieben |
| LUKS-Passphrase | – | mind. 8 Zeichen, gilt für alle LUKS-Container. **Nimm eine lange Passphrase** und bewahre sie offline auf |

---

## Layout

Beide Platten werden identisch partitioniert (Größen richten sich nach der kleineren Platte):

| Part. | Typ | Größe | Inhalt |
|---|---|---|---|
| 1 | EFI | 1 GiB | FAT32; Platte 1 → `/boot/efi`, Platte 2 → `/boot/efi2` |
| 2 | ZFS | 2 GiB | `bpool` (Mirror, `compatibility=grub2`), enthält `/boot` |
| 3 | Swap | 4 GiB | dm-crypt plain, neuer Zufallsschlüssel bei jedem Boot |
| 4 | LUKS2 | **64 GiB fest** | `luks-root1/2` → `rpool` (Mirror), das Betriebssystem |
| 5 | LUKS2 | Rest der kleineren Platte | `luks-data1/2` → `dpool` (Mirror), `/home` und `/data` |
| 6 | LUKS2 | Rest der größeren Platte | nur bei `pool`: `luks-extra` → eigener Pool, **keine Redundanz**, Mountpoint `/data/extra` |

**Datasets:**

| Pool | Dataset | Mountpoint |
|---|---|---|
| bpool | `BOOT/ubuntu` | `/boot` (legacy) |
| rpool | `ROOT/ubuntu` | `/` |
| rpool | `var/log`, `var/spool` | legacy-Mounts per fstab |
| rpool | `var/cache`, `var/tmp`, `tmp`, `srv`, `root` | `/var/cache`, `/var/tmp`, `/tmp`, `/srv`, `/root` |
| dpool | `home` | `/home` |
| dpool | `data` | `/data` |

Verschlüsselt wird mit AES-256-XTS, Schlüsselableitung argon2id. Auf jedem LUKS-Container liegen zwei Schlüssel-Slots: deine Passphrase und der TPM2-Schlüssel.

---

## Bootkette

```
UEFI (Secure Boot) → shimx64 → grubx64 (signiert) → liest bpool → Kernel + dracut-initrd
  ├─ luks-root1/2 öffnen (TPM2, sonst Passphrase) → rpool importieren → Root mounten
  └─ nach switch-root: luks-data1/2 öffnen → dpool importieren (zfs-import-dpool / zfs-import-scan)
```

---

## Nach dem ersten Boot

```bash
zpool status                          # bpool, rpool, dpool ONLINE
swapon --show                         # zwei Swap-Geräte
df -h /boot /boot/efi /data           # eingehängt
sudo ufw status                       # Firewall aktiv? (wird erst beim ersten Boot geladen)
sudo cryptsetup luksDump /dev/disk/by-id/<platte>-part4 | grep -A3 tpm2
systemctl --failed                    # sollte leer sein
```

Fragt der Boot trotz TPM-Enrollment nach der Passphrase (PCR 7 des Live-Mediums und des installierten Systems können sich unterscheiden): Passphrase tippen, booten, dann `sudo enroll-tpm2`.

Für eine umfassende Prüfung liegt `verify-install.sh` bei (UEFI/NVRAM, Partitionen, ESPs, LUKS/TPM, Pools, Datasets, crypttab/fstab/GRUB, initrd, Dienste, Firewall, Pakete):

```bash
sudo bash verify-install.sh      # Exit-Code 1 bei mindestens einem FAIL
```

| Befehl | Wann |
|---|---|
| `sudo enroll-tpm2 [PCRS]` | nach dem ersten Boot (falls zurückgestellt), nach Firmware-Update (bei PCR 0,7), Secure-Boot-Änderung, TPM-Reset oder Plattentausch. Löscht alte TPM-Slots, enrollt neu, die Passphrase bleibt |
| `sudo sync-efi` | nach Updates von `shim-signed` oder `grub-efi-amd64-signed`, damit Platte 2 unabhängig bootfähig bleibt |
| `sudo zpool scrub rpool bpool dpool` | monatlich |

---

## Empfehlung für NAS, VMs und Docker (nicht Teil des Scripts)

Der OS-Pool ist nur 64 GiB groß, und `/var/lib` liegt darauf. Docker-Images, VM-Platten und Container würden ihn füllen. Lege solche Daten auf eigene Datasets im `dpool`:

```bash
sudo zfs create dpool/data/docker
sudo zfs create dpool/data/vm
sudo zfs create dpool/data/media     # je Samba-Share ein eigenes Dataset
```

Danach Docker auf `data-root: /data/docker` stellen (`/etc/docker/daemon.json`) und den Docker-Dienst per systemd-Drop-in mit `RequiresMountsFor=/data/docker` hinter den Mount ordnen. Auch für VM-Images (z. B. libvirt) einen Pfad unter `/data/vm` wählen. Docker-Speichertreiber (overlay2 oder zfs) vor dem Einsatz prüfen.

---

## Änderungen gegenüber rev. 9.0

1. **Firewall (UFW):** Im Chroot werden die Regeln nur geschrieben (`default deny incoming`, `allow 22/tcp`), `ufw enable` läuft dort nicht mehr. Der Aufruf hätte den Live-Kernel angesprochen und unter `set -e` das Chroot-Script vor dracut/GRUB abbrechen können. Aktiviert wird per `ENABLED=yes` und `ufw.service` beim ersten Boot. Lässt sich die SSH-Regel nicht schreiben, bleibt die Firewall aus (mit Warnung), statt deny-all ohne SSH zu aktivieren.
2. **`zfs-import-dpool.service`:** `After=systemd-cryptsetup.target` zeigte auf ein Target, das es nicht gibt. Jetzt `After=cryptsetup.target`, außerdem abgesichert gegen ein Wettrennen mit `zfs-import-scan.service`.
3. **NVRAM-Eintrag für Platte 2:** Alte „ubuntu (disk 2)“-Einträge früherer Läufe werden entfernt. Ein Fehler beim Anlegen ist nicht mehr fatal (vorher brach das Script ab, bevor `enroll-tpm2` geschrieben und aufgeräumt wurde). Stattdessen erscheint am Ende eine Warnung mit dem manuellen Befehl.

**Nicht geändert:** festes 64-GiB-Layout, SSH-Passwort-Login, manueller `sync-efi`, PCR-7-only-Bindung ohne PIN, Mindestlänge 8 der LUKS-Passphrase, der Secure-Boot-MOK-Hinweis am Ende (für Standardsysteme meist irrelevant), doppelte NVRAM-Einträge „ubuntu“ bei Wiederholungsläufen (ggf. mit `efibootmgr -B` entfernen).

---

## Prüfscript `verify-install.sh` (rev. 5)

Läuft **nach dem ersten Boot** als root, prüft rund 20 Abschnitte und gibt PASS/WARN/FAIL aus. Gegenüber der Upstream-rev. 4 behoben:

1. **Passt zum gepatchten Installer:** rev. 4 verlangte `After=systemd-cryptsetup.target` (existiert nicht) und hätte auf jeder p1-Installation einen FAIL gemeldet.
2. **Falsch-negative initrd-Prüfung:** `echo "$GROSS" | grep -q` liefert unter `pipefail` bei großer Eingabe Exit 141 (SIGPIPE). Jetzt Here-Strings.
3. **bpool-Fallback** konnte nie greifen (Einrückung, by-id-Namen); parst jetzt `zpool status -LP`.
4. **NVRAM-Eintrag für Platte 2** wird geprüft, weil ihn der Installer p1 nicht mehr erzwingt.
5. **Ausgabe:** `\EFI\ubuntu\...` aus `efibootmgr` wurde durch `echo -e` zu Steuerzeichen, jetzt `printf %s`.
6. Kleinere Punkte: `dpkg-query` statt `dpkg -s`, `/boot/efi` nicht gemountet = FAIL, ESP-Inhalte werden verglichen, Extra-Pool- und TPM-Slot-Prüfung für `luks-extra`, genauer Port-22-Test, ausgerichtete Box.

Getestet habe ich nur Syntax und Einzelfälle mit Stub-Programmen, nicht auf einem echten System mit ZFS und TPM. ShellCheck stand in meiner Umgebung nicht zur Verfügung.

---

## Sicherheitsmodell

**Schützt gegen:**
- Ausgebaute Platten (alles außer ESP und `bpool` ist verschlüsselt; Kernel und initrd liegen unverschlüsselt, wie bei jedem LUKS+GRUB-Setup).
- Manipulation der Bootkette: Ändert sich der Secure-Boot-Zustand (PCR 7), gibt das TPM den Schlüssel nicht frei, und es wird die Passphrase verlangt.

**Schützt nicht gegen:**
- Jemanden, der den Rechner einfach einschaltet: Das TPM entsperrt, deine Verteidigung sind dann Benutzerpasswort und SSH-Härtung.
- Angriffe auf das laufende System und TPM-Bus-Sniffing (`--tpm2-with-pin` ist nicht aktiv, weil es unbeaufsichtigten Boot verhindert).
- Verlust der Passphrase: Verweigert das TPM die Freigabe und du hast keine Passphrase, sind die Daten unwiederbringlich weg.

Weitere Hinweise: SSH-Passwort-Login nach der Installation auf Schlüssel umstellen. `discard`/`autotrim` laufen durch LUKS und verraten, welche Blöcke frei sind (Kompromiss zugunsten der SSD-Lebensdauer).

---

## Wartung und Fehlerbehebung

**Platte ersetzen:** Das Upstream-README beschreibt den Ablauf nur für das alte Layout. Hier kommt zusätzlich Partition 5 (`luks-data`) und der Pool `dpool` dazu: Partitionstabelle replizieren, `bpool`, `rpool` **und** `dpool` jeweils mit `zpool replace` ersetzen, crypttab und die `rd.luks.name`-UUIDs in `/etc/default/grub` aktualisieren, `enroll-tpm2`, `dracut -f --regenerate-all`, `update-grub`, ESP neu anlegen und `sync-efi`. Vorher an einer Testmaschine durchspielen.

**Boot-Eintrag für Platte 2 fehlt** (Warnung des Installers oder von `verify-install.sh`): Der Mirror bootet dann nur über Platte 1. Eintrag nachlegen (Platte 2 per by-id-Pfad angeben):
```bash
sudo efibootmgr -c -g -d /dev/disk/by-id/<platte2> -p 1 -L 'ubuntu (disk 2)' -l '\EFI\ubuntu\shimx64.efi'
```
Doppelte alte Einträge entfernst du mit `sudo efibootmgr -B -b <Nummer>`.

**Notfall-Shell beim Boot (dracut):**
```bash
ls /dev/mapper/                  # sind luks-root1 und luks-root2 da?
zpool import                     # welche Pools sind sichtbar?
zpool import -f -N rpool; exit   # manuell importieren, dann weiter booten
```

**`zfs-import-bpool.service` fehlgeschlagen:**
```bash
zpool import -f -N bpool
systemctl reset-failed zfs-import-bpool.service
```

**`/home` oder `/data` fehlen nach dem Boot:** Wahrscheinlich wurden `luks-data1/2` nicht entsperrt (TPM-Freigabe fehlgeschlagen, `nofail` lässt den Boot trotzdem weiterlaufen). Mit `sudo enroll-tpm2` neu binden oder die Container manuell öffnen, dann `sudo zpool import dpool`.

**Rettung vom Live-ISO** (aus dem Upstream-README an das Layout angepasst, ungetestet):
```bash
sudo -i
cryptsetup open /dev/disk/by-id/DISK1-part4 luks-root1
cryptsetup open /dev/disk/by-id/DISK2-part4 luks-root2
cryptsetup open /dev/disk/by-id/DISK1-part5 luks-data1
cryptsetup open /dev/disk/by-id/DISK2-part5 luks-data2
zpool import -N -R /mnt rpool
zpool import -N -R /mnt dpool
zfs mount rpool/ROOT/ubuntu && zfs mount -a
zpool import -N -R /mnt bpool
mount -t zfs bpool/BOOT/ubuntu /mnt/boot
mount /dev/disk/by-id/DISK1-part1 /mnt/boot/efi
for f in dev proc sys run; do mount --rbind /$f /mnt/$f; mount --make-rslave /mnt/$f; done
chroot /mnt
# nach der Reparatur: exit, umount -R /mnt, zpool export -a, cryptsetup close <name>
```

---

## Bekannte Einschränkungen

- Nur amd64, nur `linux-image-generic`.
- USB-Platten als Mirror-Mitglieder sind unzuverlässig (Bus-Resets lassen ZFS das Vdev als UNAVAIL markieren). Für einen 24/7-Server interne Platten verwenden.
- Ein Admin-Benutzer, kein cloud-init; Netzwerk per DHCP auf allen `en*`-Schnittstellen (`/etc/netplan/01-netcfg.yaml` anpassen).
- Der Mirror ist so schnell wie die langsamere Platte (relevant bei NVMe + SATA-SSD).
- Das Script ist weder von mir noch von einer größeren Community geprüft: ein Autor, wenige Commits, ein Testgerät.

---

## Herkunft und Lizenz

Basiert auf `FollowTheWizard/install-ubuntu-server-2604-zfs-luks-tpm` (rev. 9.0).

**Lizenz dieser Kopie: Apache License 2.0** (Datei `LICENSE`, Wortlaut unverändert).

Das Original ist uneinheitlich: Seine `LICENSE`-Datei ist Apache-2.0 (ohne eingetragenen Urheber, nur die leere Vorlage), sein Script-Header und sein README nannten dagegen MIT. Beide Hinweise sind in der Datei `NOTICE` festgehalten. Beide Lizenzen sind permissiv; ich habe die `LICENSE`-Datei als maßgeblich genommen. Das ist keine Rechtsberatung. Am sauberesten wäre eine Klarstellung durch den Original-Autor.

Beim Weitergeben liegen diese Dateien zusammen:

```
install-2604-zfs-luks-tpm.sh   # Script mit Lizenz- und Änderungshinweis im Header
verify-install.sh              # Prüfscript (rev. 5), gleicher Lizenz- und Änderungshinweis
README.md
LICENSE                        # Apache-2.0, unverändert
NOTICE                         # Herkunft, beide Original-Hinweise, Änderungen, dein Name
```

Vor dem Weitergeben in `NOTICE` bei „Copyright [YEAR] [YOUR NAME]“ Jahr und Namen eintragen. **Keine Gewährleistung.**
