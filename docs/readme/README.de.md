# Universal Service OS (USOS) 1.0.0

> Dies ist eine Übersetzung. Maßgeblich ist die [englische Fassung des README](../../README.md).

**Sprachen:** [English](../../README.md) ·
[Български](README.bg.md) ·
[Čeština](README.cs.md) ·
[Dansk](README.da.md) ·
Deutsch ·
[Ελληνικά](README.el.md) ·
[Español](README.es.md) ·
[Eesti](README.et.md) ·
[Suomi](README.fi.md) ·
[Français](README.fr.md) ·
[Hrvatski](README.hr.md) ·
[Magyar](README.hu.md) ·
[Italiano](README.it.md) ·
[Lietuvių](README.lt.md) ·
[Latviešu](README.lv.md) ·
[Norsk bokmål](README.nb.md) ·
[Nederlands](README.nl.md) ·
[Polski](README.pl.md) ·
[Português (Brasil)](README.pt-BR.md) ·
[Română](README.ro.md) ·
[Русский](README.ru.md) ·
[Slovenčina](README.sk.md) ·
[Slovenščina](README.sl.md) ·
[Srpski (latinica)](README.sr-Latn.md) ·
[Svenska](README.sv.md) ·
[Türkçe](README.tr.md) ·
[Українська](README.uk.md)

## Inhalt

1. [Was USOS ist](#what-usos-is)
2. [Funktionen](#features)
3. [Unterstützte Systeme und Firmware-Modi](#supported-systems)
4. [Schnellstart](#quick-start)
5. [Ordnerstruktur auf DATA](#data-layout)
6. [Secure Boot](#secure-boot)
7. [Antwortprofile](#answer-profiles)
8. [Bekannte Probleme](#known-issues)
9. [Aus dem Quellcode bauen](#building)
10. [Lizenz](#licence)
11. [Support](#support)
12. [Dokumentation](#documentation)

<a id="what-usos-is"></a>
## 1. Was USOS ist

USOS ist ein einziger USB-Stick, mit dem Sie Betriebssysteme von MS-DOS bis
Windows 11 und Linux installieren und starten, auf Rechnern mit BIOS und mit
UEFI, auch mit UEFI und Secure Boot. Ihre eigenen ISO-Abbilder kopieren Sie
wie gewöhnliche Dateien auf den Stick; USOS bietet ein einziges Menü, eine
ausdrückliche und abgesicherte Wahl des Zieldatenträgers sowie die Treiber
und Korrekturen, die alte Systeme auf neuer Hardware brauchen. Der Stick wird
unter Windows mit `USOS-Installer-1.0.0.exe` vorbereitet. USOS enthält keine
Windows-Abbilder, keine Produktschlüssel und keine Umgehung der Aktivierung.

![USOS-UEFI-Menü, Startbildschirm](../images/menu-home.png)

<a id="features"></a>
## 2. Funktionen

- **Ein Menü für BIOS und UEFI.** Derselbe Stick startet im Legacy-BIOS und
  in UEFI (x64) mit demselben Katalog. Das UEFI-Menü lässt sich mit Tastatur,
  Maus, Touchscreen und USB-Gamepads bedienen.
- **Abbilder bleiben Dateien.** ISO-, WIM-, IMG-, VHD-, VHDX- und EFI-Abbilder
  werden direkt von der NTFS-Partition DATA gelesen; nichts wird entpackt,
  und nach dem Kopieren muss nichts ausgeführt werden.
- **Abgesicherter Zieldatenträger.** Den Datenträger wählen und bestätigen
  Sie immer selbst; der USOS-Stick selbst wird nie angeboten.
- **Secure Boot** über shim 16.1 (von Microsoft signiert) und den
  USOS-Schlüssel (MOK), der einmal pro Rechner eingetragen wird.
- **Altes Windows auf neuer Hardware.** Windows XP mit Treiberpaket und PAE
  unter UEFI mit CSM; XP und Vista unter UEFI ohne CSM über CSMWrap
  (experimentell); Windows 7 x64 ohne CSM über UefiSeven und einen
  Dispatcher für das VGA-Routing; Integration von USB 3 und NVMe für
  Windows 7.
- **Antwortprofile** für unbeaufsichtigte Installationen von Windows und
  Linux, bearbeitet im UEFI-Menü mit einer Bildschirmtastatur.
- **Linux-ISOs von DATA** (Ubuntu, Mint, Fedora, Debian, SystemRescue,
  GParted, Clonezilla und weitere), unter UEFI mit und ohne Secure Boot
  sowie im BIOS.
- **Werkzeuge:** eingebautes FreeDOS mit Dateimanager und ein Panel
  Hardware & SMART (BIOS), die EDK2 UEFI Shell (UEFI), eigene bootfähige
  Werkzeuge in `Utilities`, eigene UEFI-Treiber und Ordner mit
  Windows-INF-Treibern.
- **Installer mit vier Modi:** Installation, Lokales Update (**USOS
  aktualisieren**, behält Abbilder und Ihre Dateien), Reparatur (**ESP
  reparieren**), Deinstallation.
- **27 Sprachen** (Englisch ist die Referenz; die übrigen Sprachen außer
  Polnisch sind als teilweise oder vollständig maschinell übersetzt
  gekennzeichnet), Designs mit einem Editor im Menü, Touch- und
  Gamepad-Unterstützung auf dem ROG Ally.

| | |
|---|---|
| ![Liste der Windows-Systeme mit Statusabzeichen](../images/windows-list.png) | ![Liste der Linux-Distributionen](../images/linux-list.png) |
| Windows-Systeme mit Statusabzeichen | Linux-ISOs von DATA |
| ![Legacy-BIOS-Menü](../images/bios-menu.png) | ![Eingebaute und eigene Designs](../images/themes-grid.png) |
| Das Legacy-BIOS-Menü | Designs: Dark, Light, Retro, Sunset |

<a id="supported-systems"></a>
## 3. Unterstützte Systeme und Firmware-Modi

**HW** = auf echter Hardware getestet, **VM** = nur in QEMU/VirtualBox
getestet, **exp.** = experimentell (im Menü so gekennzeichnet),
**ungetestet** = der Weg existiert, aber es ist kein Durchlauf erfasst,
**—** = nicht unterstützt (das Menü nennt den Grund). Testrechner: **X470**
(ASRock X470, Ryzen 7 5700X, Radeon RX 560, UEFI), **MS-7100** (MSI,
Socket 939, Athlon 64 X2, BIOS), **Ally** (ASUS ROG Ally RC71L, UEFI mit
Secure Boot).

| System | BIOS (Legacy) | UEFI + CSM | UEFI ohne CSM (CSMWrap) | Secure Boot aktiv |
|---|---|---|---|---|
| Das USOS-Menü selbst | HW | HW | HW | HW (X470, Ally) |
| MS-DOS 6.22, Windows 3.1/3.11 | HW (Windows 3.1 im Standardmodus, MS-7100) | — | — | — |
| Windows 98 SE | VM; HW teilweise (MS-7100: Setup bis zur Vorbereitung des ersten Starts, Desktop nicht bestätigt) | — | — | — |
| Windows 2000 SP4 | HW (MS-7100) | exp., VM (bis zum Kopieren der Dateien) | exp., VM (CSMWrap) | — |
| Windows XP x86 SP3 | VM (ohne Treiberpaket, ohne PAE) | HW (X470: Treiberpaket, PAE, 31,9 GB) | exp., HW (X470, CSMWrap) | — |
| Windows XP x64 SP2 | ungetestet | exp., VM (bis zum GUI-Setup); X470: STOP 0xA5 | exp., VM (CSMWrap) | — |
| Windows Server 2003 R2 SP2 x86 | ungetestet | exp., VM (bis zum GUI-Setup); X470 mit 1.0 ungetestet | exp., VM (CSMWrap) | — |
| Windows Vista SP2 x64 | HW (MS-7100) | HW (X470) | exp., HW (X470, CSMWrap, Legacy-MBR) | — |
| Windows 7 SP1 x64 | HW (MS-7100) | VM (vollständige Installation) | HW (X470, UefiSeven + Dispatcher) | — |
| Windows 8 / 8.1 | ungetestet | ungetestet | ungetestet | ungetestet |
| Windows 10 | HW (x86, MS-7100) | HW (x64, X470) | natives UEFI, derselbe Weg wie mit CSM | VM (bis zum Windows-Loader) |
| Windows 11 | ungetestet | HW (Nutzerbericht) | natives UEFI, derselbe Weg wie mit CSM | VM (bis zum Windows-Loader) |
| Windows Server 2008 - 2025 | exp., nie gestartet | exp., nie gestartet | exp., nie gestartet | 2008/2008 R2: —; 2012+: ungetestet |
| Linux-ISOs (Ubuntu, Mint, Fedora, Debian, GParted, Clonezilla) | VM; HW Mint live (MS-7100) | HW (X470: Mint, Fedora, Debian netinst, Clonezilla, GParted) | wie mit CSM | HW Fedora, Mint (X470); der Rest VM |
| SystemRescue | VM | HW (X470) | wie mit CSM | — (kein signierter Bootloader) |
| FreeDOS, Hardware & SMART (eingebaut) | VM (FreeDOS); HW (Hardware & SMART) | — | — | — |
| MemTest86+ (i586-ISO, bringen Sie selbst mit) | HW | `.efi`-Build aus `Utilities` (ungetestet) | wie mit CSM | nur signierte `.efi` |
| UEFI Shell (eingebaut) | — | VM | VM | VM (startet, kann keine Werkzeuge starten) |

UEFI mit oder ohne CSM spielt nur für die Legacy-Wege eine Rolle (2000, XP,
2003, Vista, 7); alle anderen UEFI-Einträge führen in beiden Modi denselben
Code aus. Windows XP, Vista und 7 sowie jeder CSMWrap-Weg erfordern
ausgeschaltetes Secure Boot. Die vollständige Tabelle mit Anmerkungen und den
Hardware-Ergebnissen pro Build steht im
[Benutzerhandbuch, Abschnitt 5](../USER-GUIDE.en.md#5-what-works-in-which-firmware-mode)
und in den [Versionshinweisen](../release-notes-1.0.md#supported-systems)
(auf Englisch).

<a id="quick-start"></a>
## 4. Schnellstart

Dateien des Release:

| Datei | Zweck |
|---|---|
| `USOS-Installer-1.0.0.exe` | der Installer; enthält das gesamte USOS |
| `USOS-1.0.0-WinPE-PE10-donor.zip` | PE10-Spender, nötig für Vista und originale Windows-7-ISOs unter UEFI |
| `USOS-1.0.0-XP-package-PL.zip`, `USOS-1.0.0-XP-package-EN.zip` | UEFI-Paket für Windows XP x86 SP3, jeweils für genau ein originales ISO (`pl_..._x14-80476.iso` / `en_..._x14-80428.iso`), installiert mit dem beiliegenden `install-xp-package.ps1` |
| `USOS-1.0.0-sources.zip` + `SOURCE-OFFER.txt` | Quellen der Fremdkomponenten und das schriftliche Quellcode-Angebot |
| `USOS-1.0.0-buildkit.zip` | festgelegte Toolchains und Build-Eingaben für einen Offline-Neubau |
| `LICENSES/`, `THIRD-PARTY-NOTICES.txt` | Lizenztexte und Hinweise |
| `SHA256SUMS` | SHA-256 jeder Datei |

Prüfen Sie einen Download mit `certutil -hashfile USOS-Installer-1.0.0.exe SHA256`
(oder `Get-FileHash` in PowerShell) gegen `SHA256SUMS`.

![USOS-Installer: Vorgang auswählen](../images/installer-mode.png)

1. Besorgen Sie einen USB-Stick mit **mindestens 32 GiB** (in der Praxis
   64 GB; ein als „32 GB“ verkaufter Stick ist meist zu klein). **Alles
   darauf wird gelöscht.**
2. Starten Sie auf einem Windows-PC `USOS-Installer-1.0.0.exe` (er fragt
   nach Administratorrechten), wählen Sie **Installation**, wählen Sie den
   Stick, tippen Sie den Bestätigungstext ein und klicken Sie auf **LÖSCHEN
   UND INSTALLIEREN**.
3. Kopieren Sie Ihre ISO-Abbilder auf die Partition DATA, in den Ordner
   `Images` des jeweiligen Systems, z. B. `Systems\Windows\Windows 11\Images\`.
4. Optional: Für Vista oder das originale Windows 7 unter UEFI kopieren Sie
   den Ordner `Programs` aus dem ZIP des PE10-Spenders in das
   Stammverzeichnis von DATA und führen **USOS aktualisieren** aus; für XP
   unter UEFI führen Sie als Administrator `install-xp-package.ps1` aus dem
   XP-Paket aus, das zu Ihrem ISO passt (immer nur ein Paket).
5. Starten Sie den Zielrechner vom Stick (BIOS oder UEFI). Bei aktivem
   Secure Boot tragen Sie den USOS-Schlüssel einmal ein
   ([Secure Boot](#secure-boot)). Wählen Sie das System und das Abbild,
   optional ein Antwortprofil, bestätigen Sie den Zieldatenträger und folgen
   Sie dem Installer des Systems.

Schritt-für-Schritt-Anleitungen zu jedem Bildschirm stehen im
Benutzerhandbuch: [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md).

<a id="data-layout"></a>
## 5. Ordnerstruktur auf DATA

Der Installer legt auf dem Stick drei Partitionen an: `USOS_ESP` (FAT32,
1 GiB: Startdateien, Schlüssel, Einstellungen, Logs, Profile), `USOS_DATA`
(NTFS: Ihre Dateien) und `USOS_WORK` (NTFS, Arbeitsbereich für einige
Windows-Installer). Alle Ordner auf DATA werden für Sie angelegt:

```
USOS_DATA\
├─ Systems\
│  ├─ Windows\<Version>\   Images\  Unattended\   (Windows 3.1 bis 11, Server 2003-2025)
│  ├─ Linux\<Distribution>\ Images\  Unattended\   (Other Linux\ für unbekannte ISOs)
│  ├─ Betas\
│  └─ DOS\<Variante>\       Images\
├─ Utilities\
│  ├─ FreeDOS\Programs\     DOS-Programme für das eingebaute FreeDOS
│  ├─ UEFI Shell\Tools\     EFI-Werkzeuge für die UEFI Shell
│  └─ <Ihr Werkzeug>\Images\   z. B. MemTest86\Images\memtest86.efi
├─ Drivers\
│  ├─ UEFI\<Name>\          .efi-Treiber, die das USOS-Menü lädt
│  └─ <Windows-Version>\    Storage\  USB\  Other\  (INF-Pakete)
├─ Themes\<Name>\theme.ini  eigene Designs (UEFI-Menü)
└─ Programs\
   └─ USOS\                 von USOS verwaltet (PE10-Spender), nicht anfassen
```

Nach dem Hinzufügen einer `icon.png` oder eines neuen Werkzeugordners führen
Sie **USOS aktualisieren** aus. Der vollständige Baum steht im
[Benutzerhandbuch, Abschnitt 4](../USER-GUIDE.en.md#4-folder-layout-on-data).

<a id="secure-boot"></a>
## 6. Secure Boot

Bei aktivem Secure Boot startet USOS über **shim 16.1** (Fedora-Build,
signiert von der Microsoft UEFI CA) und MokManager. USOS selbst und seine
Komponenten sind mit dem **USOS-Schlüssel** signiert, der **einmal pro
Rechner** eingetragen wird:

- **Am einfachsten:** Secure Boot ausschalten, vom Stick starten, auf dem
  Startbildschirm **Hinzufügen** wählen und mit **Ja, Schlüssel speichern**
  bestätigen, dann Secure Boot wieder einschalten. Das funktioniert auch im
  Setup Mode (auf dem X470 bestätigt).
- **Mit eingeschaltetem Secure Boot:** bei „Verification failed“ in
  MokManager **Enroll key from disk** -> `USOS_ESP` -> `USOS-KEY.cer` wählen
  (auf dem ROG Ally bestätigt). Die Karte **Vorbereiten (einmalig)** im
  Installer sorgt dafür, dass MokManager wartet, statt herunterzuzählen.

Ein NVRAM-Reset entfernt den Schlüssel; tragen Sie ihn dann erneut ein. XP,
Vista, 7, jeder CSMWrap-Weg, SystemRescue und aus der UEFI Shell gestartete
Werkzeuge erfordern ausgeschaltetes Secure Boot. Der Kernel ist noch nicht
abgeriegelt (Roadmap-Punkt N6), daher vertraut man mit dem Eintragen des
USOS-Schlüssels allem, was damit signiert ist. Details:
[Benutzerhandbuch, Abschnitt 6](../USER-GUIDE.en.md#6-secure-boot-and-the-usos-key-mok),
[secure-boot-usos.md](../secure-boot-usos.md).

<a id="answer-profiles"></a>
## 7. Antwortprofile

Ein kleines Profil (Konten, Computername, Sprache, Zeitzone, optionale
Anpassungen) wird beim Start in `WINNT.SIF` (2000/XP/2003),
`autounattend.xml` (Vista bis 11, Server) oder in Ubuntu autoinstall, Debian
preseed oder Fedora kickstart umgewandelt. Profile werden im UEFI-Menü
angelegt (**Unbeaufsichtigte Installation** -> **+ Neues Profil
hinzufügen**) und auf der ESP gespeichert.

![Editor für Antwortprofile mit dem Abschnitt Aussehen und Extras](../images/profile-editor-appearance.png)

- Der Zieldatenträger wird **immer von Hand gewählt**; ein Profil wählt oder
  löscht nie einen Datenträger.
- Ein Produktschlüssel wird nur gespeichert, wenn Sie „Schlüssel auf diesem
  Stick merken“ ankreuzen; sonst bleibt er nur bis zum Neustart erhalten.
  **USOS enthält keine Schlüssel** und umgeht weder die Aktivierung noch die
  Seite für den Produktschlüssel.
- Passwörter und gemerkte Schlüssel werden auf dem Stick als Klartext
  gespeichert (nie in Listen oder Logs angezeigt). Linux-Profile
  funktionieren nur unter UEFI.

Details: [Benutzerhandbuch, Abschnitt 7](../USER-GUIDE.en.md#7-answer-profiles-and-tweaks),
[answer-profiles.md](../answer-profiles.md).

<a id="known-issues"></a>
## 8. Bekannte Probleme

- **Vista auf Boards nur mit USB 3 (X470):** USB-Sticks sind im
  installierten System nicht sichtbar, und Vista bleibt im Testmodus
  (testsignierter USB-3-Backport). Eine PCIe-Karte mit Renesas uPD72020x
  vermeidet beides.
- **CSMWrap-Wege:** brauchen eine Grafikkarte mit Legacy-VBIOS (sonst
  schwarzer Bildschirm), belegen einen CPU-Thread, brauchen einen
  MBR-Zieldatenträger (wird gelöscht) und ausgeschaltetes Secure Boot.
- **Server 2003 x86 / XP x64:** STOP 0xA5 (ACPI) auf dem X470 und keine
  USB-Eingabe auf Boards nur mit xHCI.
- **Windows 2000** funktioniert nicht auf Boards nur mit AHCI (kein
  AHCI-Treiber für NT 5.0); **XP** unterstützt kein NVMe und erhält im
  BIOS-Modus weder Treiberpaket noch PAE.
- **Secure Boot:** SystemRescue wird blockiert (kein signierter Loader); die
  UEFI Shell kann keine Werkzeuge starten; nach dem DBX-Update gegen
  BlackLotus starten ältere Windows-Medien nicht.
- **Linux:** Der Installer von Ubuntu Server wählt den größten Datenträger
  vor, und das kann der USOS-Stick sein; prüfen Sie immer das Ziel.
- **AMI-Firmware** listet jede Partition des Sticks als eigenen
  Starteintrag.
- Das Mikro-Linux-Hilfssystem braucht eine x86-64-CPU und mindestens
  256 MiB RAM.

Die vollständige Liste mit Umgehungen und die ehrliche Liste dessen, was auf
Hardware **noch nicht getestet** wurde (z. B. Windows Server 2008-2025,
Windows 8/8.1, Windows 10/11 mit Secure Boot auf Hardware, das originale
Windows-7-SP1-ISO über den PE10-Spender), stehen in den
[Versionshinweisen](../release-notes-1.0.md#known-issues) (auf Englisch) und
im [Benutzerhandbuch, Abschnitte 9 und 10](../USER-GUIDE.en.md#9-known-issues-and-workarounds).

<a id="building"></a>
## 9. Aus dem Quellcode bauen

Der Build läuft unter Windows. Vollständige Anleitung:
[BUILDING.md](../BUILDING.md) (auf Englisch).

- `build.bat` baut das komplette Release (EFI-Programm, Mikro-Linux,
  BIOS-Kern, Payload und `installer\USOS Installer.exe`) mit einer einzigen
  Build-ID (`BYYMMDD-HHMMSS-XXXXXXXX`). Verwendet wird das portable Zig in
  `tools/zig`; Go und Python müssen im `PATH` liegen.
- `tools/tests/run.ps1` führt die automatischen Tests aus, z. B.
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/tests/run.ps1 -Suite all`.
- `powershell -ExecutionPolicy Bypass -File tools\release\make_release.ps1`
  erzeugt die Release-Dateien in `zig-out\release-1.0\`.
- **Offline-Build:** `USOS-1.0.0-buildkit.zip` entpacken, `USOS_BUILDKIT`
  auf den entpackten Ordner `USOS-1.0.0-buildkit` setzen und `build.bat`
  ausführen; das Kit wird gegen sein Manifest geprüft, und Downloads sind
  deaktiviert.
- **Signaturschlüssel:** Der Secure-Boot-Schlüssel (MOK) liegt **außerhalb
  des Repositorys**, in `%APPDATA%\USOS\signing\` (`USOS_SIGNING_DIR`
  überschreibt das). Ohne ihn ist der Build **unsigniert** und startet nur
  mit ausgeschaltetem Secure Boot. Den Schlüssel nie committen oder
  weitergeben.

Windows-ISOs, Treiber und andere Medien Dritter sind nie Teil des
Repositorys.

<a id="licence"></a>
## 10. Lizenz

- Der eigene Code von USOS steht unter der **GNU General Public License,
  Version 3 oder später** (GPL-3.0-or-later): siehe [LICENSE](../../LICENSE)
  und [NOTICE](../../NOTICE). Copyright (C) 2026 The USOS Authors.
- Fremdkomponenten behalten ihre eigenen Lizenzen. Es sind eigenständige
  Programme, die auf dem Stick zusammengestellt werden; siehe
  `THIRD-PARTY-NOTICES.txt` und `LICENSES/` im Release sowie
  [LICENSES-AUDIT.md](../LICENSES-AUDIT.md).
- Microsoft-Dateien im Release (Update- und Treiberdateien, die Dateien in
  den XP-Paketen, der WinPE-Spender) werden zur Bewahrung aufbewahrt, auf
  eigenes Risiko des Maintainers weiterverbreitet, sind von keiner
  USOS-Lizenz erfasst und werden auf Verlangen des Rechteinhabers entfernt.
- Beiträge werden gemäß [CONTRIBUTING.md](../../CONTRIBUTING.md) angenommen
  (eine schlanke Lizenzeinräumung durch die Beitragenden).

Windows, MS-DOS und verwandte Namen sind Marken von Microsoft. USOS steht in
keiner Verbindung zu Microsoft.

<a id="support"></a>
## 11. Support

- Fragen und Fehlerberichte: GitHub Issues. Bitte hängen Sie die im
  [Benutzerhandbuch, Abschnitt 11](../USER-GUIDE.en.md#11-troubleshooting-and-logs)
  beschriebenen Logs an und prüfen Sie, dass sie keine Passwörter oder
  Schlüssel enthalten.
- Bezahlte Einrichtungshilfe für Unternehmen gibt es auf Anfrage; nehmen Sie
  vorerst über GitHub Issues Kontakt auf.
- Sponsoring: über `.github/FUNDING.yml`, sobald sie ausgefüllt ist.

<a id="documentation"></a>
## 12. Dokumentation

- Benutzerhandbuch: [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md)
- [Versionshinweise 1.0](../release-notes-1.0.md) (auf Englisch)
- [Wie USOS funktioniert](../HOW-IT-WORKS.md)
- [Bauen](../BUILDING.md)
- [Lizenzprüfung](../LICENSES-AUDIT.md)
- [Release-Testplan 1.0](../RELEASE-TEST-1.0.md)
- [Roadmap](../ROADMAP.md) (auf Polnisch) und [Testergebnisse](../../TESTING.md) (auf Polnisch)
