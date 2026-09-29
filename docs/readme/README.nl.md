# Universal Service OS (USOS) 1.0.0

> Dit is een vertaling. De [Engelse README](../../README.md) is leidend.

**Talen:** [English](../../README.md) ·
[Български](README.bg.md) ·
[Čeština](README.cs.md) ·
[Dansk](README.da.md) ·
[Deutsch](README.de.md) ·
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
Nederlands ·
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

## Inhoud

1. [Wat USOS is](#what-usos-is)
2. [Functies](#features)
3. [Ondersteunde systemen en firmwaremodi](#supported-systems)
4. [Snel aan de slag](#quick-start)
5. [Mapindeling op DATA](#data-layout)
6. [Secure Boot](#secure-boot)
7. [Antwoordprofielen](#answer-profiles)
8. [Bekende problemen](#known-issues)
9. [Bouwen vanuit de broncode](#building)
10. [Licentie](#licence)
11. [Ondersteuning](#support)
12. [Documentatie](#documentation)

<a id="what-usos-is"></a>
## 1. Wat USOS is

USOS is één USB-stick waarmee je besturingssystemen installeert en start, van
MS-DOS tot Windows 11 en Linux, op computers met BIOS en UEFI, ook UEFI met
Secure Boot. Je eigen ISO-images kopieer je als gewone bestanden naar de
stick; USOS geeft je één menu, een expliciete en beveiligde keuze van de
doelschijf, en de stuurprogramma's en aanpassingen die oude systemen op nieuwe
hardware nodig hebben. De stick wordt onder Windows voorbereid met
`USOS-Installer-1.0.0.exe`. USOS levert geen Windows-images, geen
productsleutels en niets om activering te omzeilen.

![USOS UEFI-menu, startscherm](../images/menu-home.png)

<a id="features"></a>
## 2. Functies

- **Eén menu voor BIOS en UEFI.** Dezelfde stick start in Legacy BIOS en in
  UEFI (x64), met dezelfde catalogus. Het UEFI-menu werkt met toetsenbord,
  muis, aanraakscherm en USB-gamepads.
- **Images blijven bestanden.** ISO-, WIM-, IMG-, VHD-, VHDX- en EFI-images
  worden rechtstreeks van de NTFS-partitie DATA gelezen; er wordt niets
  uitgepakt en na het kopiëren hoeft er niets te draaien.
- **Beveiligde doelschijf.** Je kiest en bevestigt de schijf altijd zelf; de
  USOS-stick zelf wordt nooit aangeboden.
- **Secure Boot** via shim 16.1 (ondertekend door Microsoft) en de
  USOS-sleutel (MOK), die één keer per computer wordt ingeschreven.
- **Oude Windows op nieuwe hardware.** Windows XP met een
  stuurprogrammapakket en PAE op UEFI met CSM; XP en Vista op UEFI zonder CSM
  via CSMWrap (experimenteel); Windows 7 x64 zonder CSM via UefiSeven en een
  dispatcher die VGA naar de grafische kaart leidt; integratie van USB 3 en
  NVMe voor Windows 7.
- **Antwoordprofielen** voor onbeheerde installaties van Windows en Linux,
  te bewerken in het UEFI-menu met een schermtoetsenbord.
- **Linux-ISO's vanaf DATA** (Ubuntu, Mint, Fedora, Debian, SystemRescue,
  GParted, Clonezilla en andere), op UEFI met en zonder Secure Boot en op
  BIOS.
- **Hulpmiddelen:** ingebouwde FreeDOS met een bestandsbeheerder en een
  paneel Hardware & SMART (BIOS), de EDK2 UEFI-shell (UEFI), je eigen
  opstartbare hulpmiddelen in `Utilities`, je eigen UEFI-stuurprogramma's en
  mappen met INF-stuurprogramma's voor Windows.
- **Installatieprogramma met vier modi:** Installatie, Lokaal bijwerken
  (**USOS bijwerken**, behoudt images en je bestanden), Herstellen (**ESP
  herstellen**), Verwijderen.
- **27 talen** (Engels is de referentie; de overige talen, behalve Pools,
  zijn gemarkeerd als geheel of gedeeltelijk machinaal vertaald), thema's met
  een editor in het menu, ondersteuning voor aanraking en pad op de ROG Ally.

| | |
|---|---|
| ![Lijst met Windows-systemen en statuslabels](../images/windows-list.png) | ![Lijst met Linux-distributies](../images/linux-list.png) |
| Windows-systemen met statuslabels | Linux-ISO's vanaf DATA |
| ![Legacy BIOS-menu](../images/bios-menu.png) | ![Ingebouwde en eigen thema's](../images/themes-grid.png) |
| Het Legacy BIOS-menu | Thema's: Dark, Light, Retro, Sunset |

<a id="supported-systems"></a>
## 3. Ondersteunde systemen en firmwaremodi

**HW** = getest op echte hardware, **VM** = alleen getest in QEMU/VirtualBox,
**exp.** = experimenteel (zo gemarkeerd in het menu), **niet getest** = de
route bestaat, maar er is geen run vastgelegd, **—** = niet ondersteund (het
menu toont de reden). Testmachines: **X470** (ASRock X470, Ryzen 7 5700X,
Radeon RX 560, UEFI), **MS-7100** (MSI, Socket 939, Athlon 64 X2, BIOS),
**Ally** (ASUS ROG Ally RC71L, UEFI met Secure Boot).

| Systeem | BIOS (Legacy) | UEFI + CSM | UEFI zonder CSM (CSMWrap) | Secure Boot aan |
|---|---|---|---|---|
| Het USOS-menu zelf | HW | HW | HW | HW (X470, Ally) |
| MS-DOS 6.22, Windows 3.1/3.11 | HW (Windows 3.1 in standaardmodus, MS-7100) | — | — | — |
| Windows 98 SE | VM; HW gedeeltelijk (MS-7100: Setup tot de voorbereiding van de eerste start, bureaublad niet bevestigd) | — | — | — |
| Windows 2000 SP4 | HW (MS-7100) | exp., VM (tot het kopiëren van bestanden) | exp., VM (CSMWrap) | — |
| Windows XP x86 SP3 | VM (geen stuurprogrammapakket, geen PAE) | HW (X470: stuurprogrammapakket, PAE, 31,9 GB) | exp., HW (X470, CSMWrap) | — |
| Windows XP x64 SP2 | niet getest | exp., VM (tot GUI Setup); X470: STOP 0xA5 | exp., VM (CSMWrap) | — |
| Windows Server 2003 R2 SP2 x86 | niet getest | exp., VM (tot GUI Setup); X470 niet getest met 1.0 | exp., VM (CSMWrap) | — |
| Windows Vista SP2 x64 | HW (MS-7100) | HW (X470) | exp., HW (X470, CSMWrap, legacy MBR) | — |
| Windows 7 SP1 x64 | HW (MS-7100) | VM (volledige installatie) | HW (X470, UefiSeven + dispatcher) | — |
| Windows 8 / 8.1 | niet getest | niet getest | niet getest | niet getest |
| Windows 10 | HW (x86, MS-7100) | HW (x64, X470) | native UEFI, zelfde route als met CSM | VM (tot aan de Windows-loader) |
| Windows 11 | niet getest | HW (melding van gebruiker) | native UEFI, zelfde route als met CSM | VM (tot aan de Windows-loader) |
| Windows Server 2008 - 2025 | exp., nooit gestart | exp., nooit gestart | exp., nooit gestart | 2008/2008 R2: —; 2012+: niet getest |
| Linux-ISO's (Ubuntu, Mint, Fedora, Debian, GParted, Clonezilla) | VM; HW Mint live (MS-7100) | HW (X470: Mint, Fedora, Debian netinst, Clonezilla, GParted) | zelfde als met CSM | HW Fedora, Mint (X470); VM de rest |
| SystemRescue | VM | HW (X470) | zelfde als met CSM | — (geen ondertekende bootloader) |
| FreeDOS, Hardware & SMART (ingebouwd) | VM (FreeDOS); HW (Hardware & SMART) | — | — | — |
| MemTest86+ (i586-ISO, lever je zelf) | HW | `.efi`-build uit `Utilities` (niet getest) | als met CSM | alleen ondertekende `.efi` |
| UEFI-shell (ingebouwd) | — | VM | VM | VM (start, kan geen hulpmiddelen starten) |

UEFI met of zonder CSM maakt alleen uit voor de legacy-routes (2000, XP,
2003, Vista, 7); elke andere UEFI-optie draait in beide modi dezelfde code.
Windows XP, Vista en 7 en elke CSMWrap-route vereisen dat Secure Boot uit
staat. De volledige tabel met opmerkingen en de hardwareresultaten per build
staan in de
[gebruikershandleiding, hoofdstuk 5](../USER-GUIDE.en.md#5-what-works-in-which-firmware-mode)
en de [release notes](../release-notes-1.0.md#supported-systems) (in het
Engels).

<a id="quick-start"></a>
## 4. Snel aan de slag

Releasebestanden:

**Twijfel je? Download het volledige installatieprogramma.**

| Bestand | Doel |
|---|---|
| `USOS-Installer-1.0.0.exe` | **Volledig installatieprogramma**: heel USOS plus de WinPE-donor en beide XP-pakketten; werkt offline |
| `USOS-Installer-1.0.0-online.exe` | **Online installatieprogramma**: kleine download; haalt de WinPE-donor en XP-pakketten zo nodig uit deze release en controleert ze |
| `USOS-1.0.0-WinPE-PE10-donor.zip` | PE10-donor, nodig voor Vista en originele Windows 7-ISO's op UEFI |
| `USOS-1.0.0-XP-package-PL.zip`, `USOS-1.0.0-XP-package-EN.zip` | UEFI-pakket voor Windows XP x86 SP3, elk voor precies één originele ISO (`pl_..._x14-80476.iso` / `en_..._x14-80428.iso`), te installeren met het meegeleverde `install-xp-package.ps1` |
| `USOS-1.0.0-sources.zip` + `SOURCE-OFFER.txt` | broncode van de componenten van derden en het schriftelijke aanbod voor de broncode |
| `USOS-1.0.0-buildkit.zip` | vastgepinde toolchains en build-invoer voor een offline herbouw |
| `LICENSES/`, `THIRD-PARTY-NOTICES.txt` | licentieteksten en vermeldingen |
| `SHA256SUMS` | SHA-256 van elk bestand |

Controleer een download met `certutil -hashfile USOS-Installer-1.0.0.exe SHA256`
(of `Get-FileHash` in PowerShell) tegen `SHA256SUMS`.

![USOS-installatieprogramma: een bewerking kiezen](../images/installer-mode.png)

1. Neem een USB-stick van **minstens 32 GiB** (in de praktijk 64 GB; een
   stick die als “32 GB” wordt verkocht, is meestal te klein). **Alles wat
   erop staat, wordt gewist.**
2. Start op een Windows-pc `USOS-Installer-1.0.0.exe` (het vraagt om
   beheerdersrechten), kies **Installatie**, selecteer de stick, typ de
   bevestigingstekst en klik op **WISSEN EN INSTALLEREN**.
3. Kopieer je ISO-images naar de DATA-partitie, in de map `Images` van het
   betreffende systeem, bijv. `Systems\Windows\Windows 11\Images\`.
4. Optioneel: voor Vista of de originele Windows 7 op UEFI kopieer je de map
   `Programs` uit de zip van de PE10-donor naar de hoofdmap van DATA en start
   je **USOS bijwerken**; voor XP op UEFI voer je als beheerder
   `install-xp-package.ps1` uit vanuit het XP-pakket dat bij je ISO past
   (één pakket tegelijk).
5. Start de doel-pc vanaf de stick (BIOS of UEFI). Met Secure Boot aan
   schrijf je de USOS-sleutel één keer in ([Secure Boot](#secure-boot)).
   Kies het systeem en de image, eventueel een antwoordprofiel, bevestig de
   doelschijf en volg het installatieprogramma van het systeem.

Stapsgewijze instructies voor elk scherm staan in de
gebruikershandleiding: [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md).

<a id="data-layout"></a>
## 5. Mapindeling op DATA

Het installatieprogramma maakt de stick aan met drie partities: `USOS_ESP`
(FAT32, 1 GiB: opstartbestanden, sleutel, instellingen, logs, profielen),
`USOS_DATA` (NTFS: je bestanden) en `USOS_WORK` (NTFS, werkruimte voor
sommige Windows-installatieprogramma's). Alle mappen op DATA worden voor je
aangemaakt:

```
USOS_DATA\
├─ Systems\
│  ├─ Windows\<versie>\     Images\  Unattended\   (Windows 3.1 tot 11, Server 2003-2025)
│  ├─ Linux\<distributie>\  Images\  Unattended\   (Other Linux\ voor onbekende ISO's)
│  ├─ Betas\
│  └─ DOS\<variant>\        Images\
├─ Utilities\
│  ├─ FreeDOS\Programs\     DOS-programma's voor de ingebouwde FreeDOS
│  ├─ UEFI Shell\Tools\     EFI-hulpmiddelen voor de UEFI-shell
│  └─ <je hulpmiddel>\Images\   bijv. MemTest86\Images\memtest86.efi
├─ Drivers\
│  ├─ UEFI\<naam>\          .efi-stuurprogramma's die het USOS-menu laadt
│  └─ <Windows-versie>\     Storage\  USB\  Other\  (INF-pakketten)
├─ Themes\<naam>\theme.ini  je eigen thema's (UEFI-menu)
└─ Programs\
   └─ USOS\                 beheerd door USOS (PE10-donor), niet aanraken
```

Start na het toevoegen van een `icon.png` of een nieuwe map met een
hulpmiddel **USOS bijwerken**. De volledige boom staat in
[de gebruikershandleiding, hoofdstuk 4](../USER-GUIDE.en.md#4-folder-layout-on-data).

<a id="secure-boot"></a>
## 6. Secure Boot

Met Secure Boot aan start USOS via **shim 16.1** (build van Fedora,
ondertekend door de Microsoft UEFI CA) en MokManager. USOS zelf en zijn
componenten zijn ondertekend met de **USOS-sleutel**, die **één keer per
computer** wordt ingeschreven:

- **Het eenvoudigst:** zet Secure Boot uit, start vanaf de stick, kies
  **Toevoegen** op het startscherm en bevestig met **Ja, sleutel opslaan**;
  zet daarna Secure Boot weer aan. Dit werkt ook in Setup Mode (bevestigd op
  de X470).
- **Met Secure Boot aan:** kies bij “Verification failed” in MokManager
  **Enroll key from disk** -> `USOS_ESP` -> `USOS-KEY.cer` (bevestigd op de
  ROG Ally). De kaart **Voorbereiden (eenmalig)** in het
  installatieprogramma laat MokManager wachten in plaats van af te tellen.

Een NVRAM-reset verwijdert de sleutel; schrijf hem dan opnieuw in. XP,
Vista, 7, elke CSMWrap-route, SystemRescue en hulpmiddelen die vanuit de
UEFI-shell worden gestart, vereisen dat Secure Boot uit staat. De kernel is
nog niet vergrendeld (roadmappunt N6), dus wie de USOS-sleutel inschrijft,
vertrouwt alles wat ermee is ondertekend. Details:
[gebruikershandleiding, hoofdstuk 6](../USER-GUIDE.en.md#6-secure-boot-and-the-usos-key-mok),
[secure-boot-usos.md](../secure-boot-usos.md).

<a id="answer-profiles"></a>
## 7. Antwoordprofielen

Eén klein profiel (accounts, computernaam, taal, tijdzone, optionele
aanpassingen) wordt bij de start omgezet in `WINNT.SIF` (2000/XP/2003),
`autounattend.xml` (Vista tot 11, Server) of Ubuntu autoinstall, Debian
preseed of Fedora kickstart. Profielen worden aangemaakt in het UEFI-menu
(**Onbeheerde installatie** -> **+ Nieuw profiel toevoegen**) en op de ESP
opgeslagen.

![Editor voor antwoordprofielen met de sectie Uiterlijk en extra's](../images/profile-editor-appearance.png)

- De doelschijf wordt **altijd met de hand gekozen**; een profiel selecteert
  of wist nooit een schijf.
- Een productsleutel wordt alleen opgeslagen als je “Sleutel op deze stick
  onthouden” aanvinkt; anders blijft hij alleen tot de herstart bewaard.
  **USOS levert geen sleutels** en omzeilt de activering of de pagina voor
  de productsleutel niet.
- Wachtwoorden en onthouden sleutels staan als platte tekst op de stick (ze
  worden nooit getoond in lijsten of logs). Linux-profielen werken alleen op
  UEFI.

Details: [gebruikershandleiding, hoofdstuk 7](../USER-GUIDE.en.md#7-answer-profiles-and-tweaks),
[answer-profiles.md](../answer-profiles.md).

<a id="known-issues"></a>
## 8. Bekende problemen

- **Vista op moederborden met alleen USB 3 (X470):** USB-sticks zijn niet
  zichtbaar in het geïnstalleerde systeem, en Vista blijft in testmodus
  (testondertekende USB 3-backport). Een PCIe-kaart met Renesas uPD72020x
  voorkomt beide.
- **CSMWrap-routes:** vereisen een grafische kaart met een legacy-VBIOS
  (anders een zwart scherm), gebruiken één CPU-thread, hebben een
  MBR-doelschijf nodig (die wordt gewist) en Secure Boot uit.
- **Server 2003 x86 / XP x64:** STOP 0xA5 (ACPI) op de X470 en geen
  USB-invoer op moederborden met alleen xHCI.
- **Windows 2000** werkt niet op moederborden met alleen AHCI (geen
  AHCI-stuurprogramma voor NT 5.0); **XP** heeft geen NVMe-ondersteuning en
  krijgt in BIOS-modus geen stuurprogrammapakket of PAE.
- **Secure Boot:** SystemRescue wordt geblokkeerd (geen ondertekende
  loader); de UEFI-shell kan geen hulpmiddelen starten; na de DBX-update
  tegen BlackLotus starten oudere Windows-media niet.
- **Linux:** het installatieprogramma van Ubuntu Server selecteert vooraf de
  grootste schijf, en dat kan de USOS-stick zijn; controleer altijd het doel.
- **AMI-firmware** toont elke partitie van de stick als een eigen
  opstartoptie.
- De micro-Linux-helper heeft een x86-64-CPU en minstens 256 MiB RAM nodig.

De volledige lijst met omwegen, en de eerlijke lijst van wat nog **niet
getest** is op hardware (bijv. Windows Server 2008-2025, Windows 8/8.1,
Windows 10/11 met Secure Boot op hardware, de originele Windows 7 SP1-ISO
via de PE10-donor), staan in de
[release notes](../release-notes-1.0.md#known-issues) (in het Engels) en de
[gebruikershandleiding, hoofdstukken 9 en 10](../USER-GUIDE.en.md#9-known-issues-and-workarounds).

<a id="building"></a>
## 9. Bouwen vanuit de broncode

De build draait onder Windows. Volledige instructies: [BUILDING.md](../BUILDING.md)
(in het Engels).

- `build.bat` bouwt de volledige release (EFI-programma, micro-Linux,
  BIOS-kern, payload en `installer\USOS Installer.exe`) met één build-id
  (`BYYMMDD-HHMMSS-XXXXXXXX`). De draagbare Zig in `tools/zig` wordt
  gebruikt; Go en Python moeten in `PATH` staan.
- `tools/tests/run.ps1` voert de geautomatiseerde tests uit, bijv.
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/tests/run.ps1 -Suite all`.
- `powershell -ExecutionPolicy Bypass -File tools\release\make_release.ps1`
  maakt de releasebestanden in `zig-out\release-1.0\`.
- **Offline build:** pak `USOS-1.0.0-buildkit.zip` uit, zet `USOS_BUILDKIT`
  op de uitgepakte map `USOS-1.0.0-buildkit` en start `build.bat`; de kit
  wordt tegen zijn manifest gecontroleerd en downloads zijn uitgeschakeld.
- **Ondertekeningssleutel:** de Secure Boot-sleutel (MOK) staat **buiten de
  repository**, in `%APPDATA%\USOS\signing\` (`USOS_SIGNING_DIR` overschrijft
  dit). Zonder de sleutel is de build **niet ondertekend** en start hij
  alleen met Secure Boot uit. Commit of deel de sleutel nooit.

Windows-ISO's, stuurprogramma's en andere media van derden maken nooit deel
uit van de repository.

<a id="licence"></a>
## 10. Licentie

- De eigen code van USOS valt onder de **GNU General Public License,
  versie 3 of later** (GPL-3.0-or-later): zie [LICENSE](../../LICENSE) en
  [NOTICE](../../NOTICE). Copyright (C) 2026 Maksymilian and the USOS Authors.
- Componenten van derden behouden hun eigen licenties. Het zijn aparte
  programma's die samen op de stick staan; zie `THIRD-PARTY-NOTICES.txt` en
  `LICENSES/` in de release en [LICENSES-AUDIT.md](../LICENSES-AUDIT.md).
- Microsoft-bestanden in de release (update- en stuurprogrammabestanden, de
  bestanden in de XP-pakketten, de WinPE-donor) worden bewaard met het oog
  op behoud, op eigen risico van de beheerder verspreid, vallen niet onder
  een USOS-licentie en worden op verzoek van de rechthebbende verwijderd.
- Bijdragen worden aanvaard volgens [CONTRIBUTING.md](../../CONTRIBUTING.md)
  (een eenvoudige licentieverlening door de bijdrager).

Windows, MS-DOS en verwante namen zijn handelsmerken van Microsoft. USOS is
niet gelieerd aan Microsoft.

<a id="support"></a>
## 11. Ondersteuning

- Vragen en foutmeldingen: GitHub Issues. Voeg de logs toe die beschreven
  staan in [de gebruikershandleiding, hoofdstuk 11](../USER-GUIDE.en.md#11-troubleshooting-and-logs)
  en controleer of er geen wachtwoorden of sleutels in staan.
- Betaalde hulp bij de inrichting voor bedrijven is op aanvraag
  beschikbaar; neem voorlopig contact op via GitHub Issues.
- Sponsoring: via `.github/FUNDING.yml` zodra dat is ingevuld.

<a id="documentation"></a>
## 12. Documentatie

- Gebruikershandleiding: [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md)
- [Release notes 1.0](../release-notes-1.0.md) (in het Engels)
- [Hoe USOS werkt](../HOW-IT-WORKS.md)
- [Bouwen](../BUILDING.md)
- [Licentieaudit](../LICENSES-AUDIT.md)
- [Testplan voor release 1.0](../RELEASE-TEST-1.0.md)
- [Roadmap](../ROADMAP.md) (in het Pools) en [testresultaten](../../TESTING.md) (in het Pools)
