# Universal Service OS (USOS) 1.0.0

> Dette er en oversættelse. Den [engelske README](../../README.md) er den gældende version.

**Sprog:** [English](../../README.md) ·
[Български](README.bg.md) ·
[Čeština](README.cs.md) ·
Dansk ·
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

## Indhold

1. [Hvad USOS er](#what-usos-is)
2. [Funktioner](#features)
3. [Understøttede systemer og firmwaretilstande](#supported-systems)
4. [Kom hurtigt i gang](#quick-start)
5. [Mappestruktur på DATA](#data-layout)
6. [Secure Boot](#secure-boot)
7. [Svarprofiler](#answer-profiles)
8. [Kendte problemer](#known-issues)
9. [Byg fra kildekoden](#building)
10. [Licens](#licence)
11. [Support](#support)
12. [Dokumentation](#documentation)

<a id="what-usos-is"></a>
## 1. Hvad USOS er

USOS er ét USB-stik til at installere og starte styresystemer, fra MS-DOS
til Windows 11 og Linux, på computere med BIOS og UEFI, også UEFI med Secure
Boot. Du kopierer dine egne ISO-aftryk til stikket som almindelige filer;
USOS giver dig én menu, et eksplicit og beskyttet valg af måldisken samt de
drivere og rettelser, som gamle systemer har brug for på ny hardware.
Stikket gøres klar i Windows med `USOS-Installer-1.0.0.exe`. USOS
indeholder ingen Windows-aftryk, ingen produktnøgler og intet, der omgår
aktivering.

![USOS' UEFI-menu, startskærm](../images/menu-home.png)

<a id="features"></a>
## 2. Funktioner

- **Én menu til BIOS og UEFI.** Det samme stik starter i Legacy BIOS og i
  UEFI (x64) med det samme katalog. UEFI-menuen virker med tastatur, mus,
  berøringsskærm og USB-gamepads.
- **Aftryk forbliver filer.** ISO-, WIM-, IMG-, VHD-, VHDX- og EFI-aftryk
  læses direkte fra NTFS-partitionen DATA; intet pakkes ud, og intet skal
  køres efter kopieringen.
- **Beskyttet måldisk.** Du vælger og bekræfter altid selv disken; selve
  USOS-stikket tilbydes aldrig.
- **Secure Boot** via shim 16.1 (signeret af Microsoft) og USOS-nøglen
  (MOK), som tilmeldes én gang pr. computer.
- **Gamle Windows på ny hardware.** Windows XP med en driverpakke og PAE på
  UEFI med CSM; XP og Vista på UEFI uden CSM via CSMWrap (eksperimentelt);
  Windows 7 x64 uden CSM via UefiSeven og en dispatcher, der dirigerer VGA
  til grafikkortet; integration af USB 3 og NVMe til Windows 7.
- **Svarprofiler** til automatiske installationer af Windows og Linux,
  redigeret i UEFI-menuen med et skærmtastatur.
- **Linux-ISO'er fra DATA** (Ubuntu, Mint, Fedora, Debian, SystemRescue,
  GParted, Clonezilla og andre) på UEFI med og uden Secure Boot og på BIOS.
- **Værktøjer:** indbygget FreeDOS med filhåndtering og et panel Hardware &
  SMART (BIOS), EDK2 UEFI-shell (UEFI), dine egne startbare værktøjer i
  `Utilities`, dine egne UEFI-drivere og mapper med INF-drivere til Windows.
- **Installationsprogram med fire tilstande:** Installation, Lokal
  opdatering (**Opdater USOS**, bevarer aftryk og dine filer), Reparation
  (**Reparer ESP**), Afinstallation.
- **27 sprog** (engelsk er referencen; de øvrige sprog, undtagen polsk, er
  markeret som helt eller delvist maskinoversat), temaer med en editor i
  menuen, understøttelse af berøring og gamepad på ROG Ally.

| | |
|---|---|
| ![Liste over Windows-systemer med statusmærker](../images/windows-list.png) | ![Liste over Linux-distributioner](../images/linux-list.png) |
| Windows-systemer med statusmærker | Linux-ISO'er fra DATA |
| ![Legacy BIOS-menu](../images/bios-menu.png) | ![Indbyggede og egne temaer](../images/themes-grid.png) |
| Legacy BIOS-menuen | Temaer: Dark, Light, Retro, Sunset |

<a id="supported-systems"></a>
## 3. Understøttede systemer og firmwaretilstande

**HW** = testet på rigtig hardware, **VM** = kun testet i QEMU/VirtualBox,
**eksp.** = eksperimentelt (markeret sådan i menuen), **ikke testet** =
vejen findes, men der er ikke registreret nogen kørsel, **—** = ikke
understøttet (menuen viser årsagen). Testmaskiner: **X470** (ASRock X470,
Ryzen 7 5700X, Radeon RX 560, UEFI), **MS-7100** (MSI, Socket 939, Athlon 64
X2, BIOS), **Ally** (ASUS ROG Ally RC71L, UEFI med Secure Boot).

| System | BIOS (Legacy) | UEFI + CSM | UEFI uden CSM (CSMWrap) | Secure Boot slået til |
|---|---|---|---|---|
| Selve USOS-menuen | HW | HW | HW | HW (X470, Ally) |
| MS-DOS 6.22, Windows 3.1/3.11 | HW (Windows 3.1 i standardtilstand, MS-7100) | — | — | — |
| Windows 98 SE | VM; HW delvist (MS-7100: Setup frem til forberedelsen af første start, skrivebord ikke bekræftet) | — | — | — |
| Windows 2000 SP4 | HW (MS-7100) | eksp., VM (til filkopiering) | eksp., VM (CSMWrap) | — |
| Windows XP x86 SP3 | VM (ingen driverpakke, ingen PAE) | HW (X470: driverpakke, PAE, 31,9 GB) | eksp., HW (X470, CSMWrap) | — |
| Windows XP x64 SP2 | ikke testet | eksp., VM (til GUI Setup); X470: STOP 0xA5 | eksp., VM (CSMWrap) | — |
| Windows Server 2003 R2 SP2 x86 | ikke testet | eksp., VM (til GUI Setup); X470 ikke testet med 1.0 | eksp., VM (CSMWrap) | — |
| Windows Vista SP2 x64 | HW (MS-7100) | HW (X470) | eksp., HW (X470, CSMWrap, legacy MBR) | — |
| Windows 7 SP1 x64 | HW (MS-7100) | VM (fuld installation) | HW (X470, UefiSeven + dispatcher) | — |
| Windows 8 / 8.1 | ikke testet | ikke testet | ikke testet | ikke testet |
| Windows 10 | HW (x86, MS-7100) | HW (x64, X470) | indbygget UEFI, samme vej som med CSM | VM (frem til Windows-loaderen) |
| Windows 11 | ikke testet | HW (brugerrapport) | indbygget UEFI, samme vej som med CSM | VM (frem til Windows-loaderen) |
| Windows Server 2008 - 2025 | eksp., aldrig startet | eksp., aldrig startet | eksp., aldrig startet | 2008/2008 R2: —; 2012+: ikke testet |
| Linux-ISO'er (Ubuntu, Mint, Fedora, Debian, GParted, Clonezilla) | VM; HW Mint live (MS-7100) | HW (X470: Mint, Fedora, Debian netinst, Clonezilla, GParted) | som med CSM | HW Fedora, Mint (X470); VM resten |
| SystemRescue | VM | HW (X470) | som med CSM | — (ingen signeret bootloader) |
| FreeDOS, Hardware & SMART (indbygget) | VM (FreeDOS); HW (Hardware & SMART) | — | — | — |
| MemTest86+ (i586-ISO, du leverer den selv) | HW | `.efi`-build fra `Utilities` (ikke testet) | som med CSM | kun signeret `.efi` |
| UEFI-shell (indbygget) | — | VM | VM | VM (starter, kan ikke køre værktøjer) |

UEFI med eller uden CSM har kun betydning for legacy-vejene (2000, XP,
2003, Vista, 7); alle andre UEFI-punkter kører den samme kode i begge
tilstande. Windows XP, Vista og 7 og alle CSMWrap-veje kræver, at Secure
Boot er slået fra. Den fulde tabel med bemærkninger og hardwareresultaterne
for hvert build findes i
[brugervejledningen, afsnit 5](../USER-GUIDE.en.md#5-what-works-in-which-firmware-mode)
og i [udgivelsesnoterne](../release-notes-1.0.md#supported-systems) (på
engelsk).

<a id="quick-start"></a>
## 4. Kom hurtigt i gang

Udgivelsesfiler:

| Fil | Formål |
|---|---|
| `USOS-Installer-1.0.0.exe` | installationsprogrammet; indeholder hele USOS |
| `USOS-1.0.0-WinPE-PE10-donor.zip` | PE10-donor, nødvendig til Vista og originale Windows 7-ISO'er på UEFI |
| `USOS-1.0.0-XP-package-PL.zip`, `USOS-1.0.0-XP-package-EN.zip` | UEFI-pakke til Windows XP x86 SP3, hver til præcis én original ISO (`pl_..._x14-80476.iso` / `en_..._x14-80428.iso`), installeres med det medfølgende `install-xp-package.ps1` |
| `USOS-1.0.0-sources.zip` + `SOURCE-OFFER.txt` | kildekode til tredjepartskomponenterne og det skriftlige tilbud om kildekode |
| `USOS-1.0.0-buildkit.zip` | fastlåste værktøjskæder og build-input til en offline genopbygning |
| `LICENSES/`, `THIRD-PARTY-NOTICES.txt` | licenstekster og meddelelser |
| `SHA256SUMS` | SHA-256 for hver fil |

Kontrollér en download med `certutil -hashfile USOS-Installer-1.0.0.exe SHA256`
(eller `Get-FileHash` i PowerShell) mod `SHA256SUMS`.

![USOS-installationsprogrammet: vælg en handling](../images/installer-mode.png)

1. Find et USB-stik på **mindst 32 GiB** (i praksis 64 GB; et stik, der
   sælges som »32 GB«, er som regel for lille). **Alt på det bliver
   slettet.**
2. Kør `USOS-Installer-1.0.0.exe` på en Windows-pc (den beder om
   administratorrettigheder), vælg **Installation**, vælg stikket, skriv
   bekræftelsesteksten og klik på **SLET OG INSTALLER**.
3. Kopiér dine ISO-aftryk til DATA-partitionen, i mappen `Images` for det
   pågældende system, f.eks. `Systems\Windows\Windows 11\Images\`.
4. Valgfrit: til Vista eller original Windows 7 på UEFI kopierer du mappen
   `Programs` fra PE10-donorens zip-fil til roden af DATA og kører
   **Opdater USOS**; til XP på UEFI kører du `install-xp-package.ps1` som
   administrator fra den XP-pakke, der passer til din ISO (én pakke ad
   gangen).
5. Start målcomputeren fra stikket (BIOS eller UEFI). Med Secure Boot slået
   til tilmelder du USOS-nøglen én gang ([Secure Boot](#secure-boot)). Vælg
   systemet og aftrykket, eventuelt en svarprofil, bekræft måldisken og følg
   systemets installationsprogram.

Trinvise instruktioner til hver skærm findes i
brugervejledningen: [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md).

<a id="data-layout"></a>
## 5. Mappestruktur på DATA

Installationsprogrammet opretter stikket med tre partitioner: `USOS_ESP`
(FAT32, 1 GiB: startfiler, nøgle, indstillinger, logfiler, profiler),
`USOS_DATA` (NTFS: dine filer) og `USOS_WORK` (NTFS, arbejdsområde for nogle
Windows-installationsprogrammer). Alle mapper på DATA oprettes for dig:

```
USOS_DATA\
├─ Systems\
│  ├─ Windows\<version>\    Images\  Unattended\   (Windows 3.1 til 11, Server 2003-2025)
│  ├─ Linux\<distribution>\ Images\  Unattended\   (Other Linux\ til ukendte ISO'er)
│  ├─ Betas\
│  └─ DOS\<variant>\        Images\
├─ Utilities\
│  ├─ FreeDOS\Programs\     DOS-programmer til det indbyggede FreeDOS
│  ├─ UEFI Shell\Tools\     EFI-værktøjer til UEFI-shell
│  └─ <dit værktøj>\Images\ f.eks. MemTest86\Images\memtest86.efi
├─ Drivers\
│  ├─ UEFI\<navn>\          .efi-drivere, som USOS-menuen indlæser
│  └─ <Windows-version>\    Storage\  USB\  Other\  (INF-pakker)
├─ Themes\<navn>\theme.ini  dine egne temaer (UEFI-menuen)
└─ Programs\
   └─ USOS\                 styres af USOS (PE10-donor), rør ikke
```

Kør **Opdater USOS**, når du har tilføjet en `icon.png` eller en ny
værktøjsmappe. Hele træet findes i
[brugervejledningen, afsnit 4](../USER-GUIDE.en.md#4-folder-layout-on-data).

<a id="secure-boot"></a>
## 6. Secure Boot

Med Secure Boot slået til starter USOS via **shim 16.1** (Fedora-build,
signeret af Microsoft UEFI CA) og MokManager. Selve USOS og dets
komponenter er signeret med **USOS-nøglen**, som tilmeldes **én gang pr.
computer**:

- **Nemmest:** slå Secure Boot fra, start fra stikket, vælg **Tilføj** på
  startskærmen og bekræft med **Ja, gem nøglen**, og slå derefter Secure
  Boot til igen. Det virker også i Setup Mode (bekræftet på X470).
- **Med Secure Boot slået til:** ved »Verification failed« vælger du i
  MokManager **Enroll key from disk** -> `USOS_ESP` -> `USOS-KEY.cer`
  (bekræftet på ROG Ally). Kortet **Forbered (én gang)** i
  installationsprogrammet får MokManager til at vente i stedet for at tælle
  ned.

En NVRAM-nulstilling fjerner nøglen; tilmeld den så igen. XP, Vista, 7,
alle CSMWrap-veje, SystemRescue og værktøjer startet fra UEFI-shell kræver,
at Secure Boot er slået fra. Kernen er endnu ikke låst (punkt N6 i
køreplanen), så når du tilmelder USOS-nøglen, stoler du på alt, der er
signeret med den. Detaljer:
[brugervejledningen, afsnit 6](../USER-GUIDE.en.md#6-secure-boot-and-the-usos-key-mok),
[secure-boot-usos.md](../secure-boot-usos.md).

<a id="answer-profiles"></a>
## 7. Svarprofiler

Én lille profil (konti, computernavn, sprog, tidszone, valgfrie
justeringer) omdannes ved start til `WINNT.SIF` (2000/XP/2003),
`autounattend.xml` (Vista til 11, Server) eller Ubuntu autoinstall, Debian
preseed eller Fedora kickstart. Profiler oprettes i UEFI-menuen
(**Automatisk installation** -> **+ Tilføj en ny profil**) og gemmes på
ESP'en.

![Editor til svarprofiler med afsnittet Udseende og ekstra](../images/profile-editor-appearance.png)

- Måldisken **vælges altid manuelt**; en profil vælger eller sletter aldrig
  en disk.
- En produktnøgle gemmes kun, hvis du markerer »Husk nøglen på dette
  stik«; ellers huskes den kun indtil genstart. **USOS indeholder ingen
  nøgler** og omgår hverken aktiveringen eller siden med produktnøglen.
- Adgangskoder og huskede nøgler gemmes på stikket som almindelig tekst (de
  vises aldrig i lister eller logfiler). Linux-profiler virker kun på UEFI.

Detaljer: [brugervejledningen, afsnit 7](../USER-GUIDE.en.md#7-answer-profiles-and-tweaks),
[answer-profiles.md](../answer-profiles.md).

<a id="known-issues"></a>
## 8. Kendte problemer

- **Vista på bundkort med kun USB 3 (X470):** USB-stik er ikke synlige i det
  installerede system, og Vista forbliver i testtilstand (testsigneret USB
  3-backport). Et PCIe-kort med Renesas uPD72020x undgår begge dele.
- **CSMWrap-veje:** kræver et grafikkort med et legacy-VBIOS (ellers en
  sort skærm), optager én CPU-tråd, kræver en MBR-måldisk (som slettes) og
  Secure Boot slået fra.
- **Server 2003 x86 / XP x64:** STOP 0xA5 (ACPI) på X470 og ingen USB-input
  på bundkort med kun xHCI.
- **Windows 2000** virker ikke på bundkort med kun AHCI (ingen AHCI-driver
  til NT 5.0); **XP** har ingen NVMe-understøttelse og får ingen driverpakke
  eller PAE i BIOS-tilstand.
- **Secure Boot:** SystemRescue blokeres (ingen signeret loader);
  UEFI-shell kan ikke køre værktøjer; efter DBX-opdateringen mod BlackLotus
  starter ældre Windows-medier ikke.
- **Linux:** installationsprogrammet til Ubuntu Server forudvælger den
  største disk, som kan være USOS-stikket; kontrollér altid målet.
- **AMI-firmware** viser hver partition på stikket som sit eget
  startpunkt.
- Micro-Linux-hjælperen kræver en x86-64-CPU og mindst 256 MiB RAM.

Den fulde liste med løsninger og den ærlige liste over, hvad der **endnu
ikke er testet** på hardware (f.eks. Windows Server 2008-2025, Windows
8/8.1, Windows 10/11 med Secure Boot på hardware, den originale Windows 7
SP1-ISO via PE10-donoren), findes i
[udgivelsesnoterne](../release-notes-1.0.md#known-issues) (på engelsk) og i
[brugervejledningen, afsnit 9 og 10](../USER-GUIDE.en.md#9-known-issues-and-workarounds).

<a id="building"></a>
## 9. Byg fra kildekoden

Bygningen kører på Windows. Fulde instruktioner: [BUILDING.md](../BUILDING.md)
(på engelsk).

- `build.bat` bygger hele udgivelsen (EFI-program, micro-Linux, BIOS-kerne,
  payload og `installer\USOS Installer.exe`) med ét build-id
  (`BYYMMDD-HHMMSS-XXXXXXXX`). Den portable Zig i `tools/zig` bruges; Go og
  Python skal være i `PATH`.
- `tools/tests/run.ps1` kører de automatiske tests, f.eks.
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/tests/run.ps1 -Suite all`.
- `powershell -ExecutionPolicy Bypass -File tools\release\make_release.ps1`
  laver udgivelsesfilerne i `zig-out\release-1.0\`.
- **Offline build:** pak `USOS-1.0.0-buildkit.zip` ud, sæt `USOS_BUILDKIT`
  til den udpakkede mappe `USOS-1.0.0-buildkit` og kør `build.bat`; kittet
  kontrolleres mod sit manifest, og downloads er slået fra.
- **Signeringsnøgle:** Secure Boot-nøglen (MOK) ligger **uden for
  repositoriet**, i `%APPDATA%\USOS\signing\` (`USOS_SIGNING_DIR`
  tilsidesætter det). Uden den er bygningen **usigneret** og starter kun
  med Secure Boot slået fra. Commit eller del aldrig nøglen.

Windows-ISO'er, drivere og andre tredjepartsmedier er aldrig en del af
repositoriet.

<a id="licence"></a>
## 10. Licens

- USOS' egen kode er licenseret under **GNU General Public License,
  version 3 eller senere** (GPL-3.0-or-later): se [LICENSE](../../LICENSE) og
  [NOTICE](../../NOTICE). Copyright (C) 2026 The USOS Authors.
- Tredjepartskomponenter beholder deres egne licenser. De er separate
  programmer samlet på stikket; se `THIRD-PARTY-NOTICES.txt` og `LICENSES/`
  i udgivelsen samt [LICENSES-AUDIT.md](../LICENSES-AUDIT.md).
- Microsoft-filer i udgivelsen (opdaterings- og driverfiler, filerne i
  XP-pakkerne, WinPE-donoren) bevares af hensyn til bevaring, videregives på
  vedligeholderens egen risiko, er ikke omfattet af nogen USOS-licens og
  fjernes efter anmodning fra rettighedshaveren.
- Bidrag modtages i henhold til [CONTRIBUTING.md](../../CONTRIBUTING.md) (en
  enkel licensbevilling fra bidragyderen).

Windows, MS-DOS og relaterede navne er varemærker tilhørende Microsoft. USOS
er ikke tilknyttet Microsoft.

<a id="support"></a>
## 11. Support

- Spørgsmål og fejlrapporter: GitHub Issues. Vedhæft venligst de logfiler,
  der er beskrevet i [brugervejledningen, afsnit 11](../USER-GUIDE.en.md#11-troubleshooting-and-logs),
  og kontrollér, at de ikke indeholder adgangskoder eller nøgler.
- Betalt hjælp til opsætning for virksomheder kan fås efter aftale; indtil
  videre kan du kontakte os via GitHub Issues.
- Sponsorering: via `.github/FUNDING.yml`, når den er udfyldt.

<a id="documentation"></a>
## 12. Dokumentation

- Brugervejledning: [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md)
- [Udgivelsesnoter 1.0](../release-notes-1.0.md) (på engelsk)
- [Sådan virker USOS](../HOW-IT-WORKS.md)
- [Bygning](../BUILDING.md)
- [Licensgennemgang](../LICENSES-AUDIT.md)
- [Testplan for udgivelse 1.0](../RELEASE-TEST-1.0.md)
- [Køreplan](../ROADMAP.md) (på polsk) og [testresultater](../../TESTING.md) (på polsk)
