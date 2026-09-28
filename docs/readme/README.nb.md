# Universal Service OS (USOS) 1.0.0

> Dette er en oversettelse. Den [engelske README-filen](../../README.md) er den gjeldende versjonen.

**Språk:** [English](../../README.md) ·
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
Norsk bokmål ·
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

## Innhold

1. [Hva USOS er](#what-usos-is)
2. [Funksjoner](#features)
3. [Støttede systemer og fastvaremoduser](#supported-systems)
4. [Kom raskt i gang](#quick-start)
5. [Mappestruktur på DATA](#data-layout)
6. [Secure Boot](#secure-boot)
7. [Svarprofiler](#answer-profiles)
8. [Kjente problemer](#known-issues)
9. [Bygge fra kildekode](#building)
10. [Lisens](#licence)
11. [Støtte](#support)
12. [Dokumentasjon](#documentation)

<a id="what-usos-is"></a>
## 1. Hva USOS er

USOS er én minnepenn for å installere og starte operativsystemer, fra
MS-DOS til Windows 11 og Linux, på datamaskiner med BIOS og UEFI, også UEFI
med Secure Boot. Du kopierer dine egne ISO-bilder til minnepennen som
vanlige filer; USOS gir deg én meny, et eksplisitt og beskyttet valg av
måldisk og de driverne og rettelsene som gamle systemer trenger på ny
maskinvare. Minnepennen klargjøres i Windows med
`USOS-Installer-1.0.0.exe`. USOS inneholder ingen Windows-bilder, ingen
produktnøkler og ingenting som omgår aktivering.

![USOS' UEFI-meny, startskjerm](../images/menu-home.png)

<a id="features"></a>
## 2. Funksjoner

- **Én meny for BIOS og UEFI.** Den samme minnepennen starter i Legacy BIOS
  og i UEFI (x64) med den samme katalogen. UEFI-menyen fungerer med
  tastatur, mus, berøringsskjerm og USB-spillkontrollere.
- **Bilder forblir filer.** ISO-, WIM-, IMG-, VHD-, VHDX- og EFI-bilder
  leses direkte fra NTFS-partisjonen DATA; ingenting pakkes ut, og ingenting
  må kjøres etter kopieringen.
- **Beskyttet måldisk.** Du velger og bekrefter alltid disken selv; selve
  USOS-minnepennen blir aldri tilbudt.
- **Secure Boot** via shim 16.1 (signert av Microsoft) og USOS-nøkkelen
  (MOK), som registreres én gang per datamaskin.
- **Gamle Windows på ny maskinvare.** Windows XP med en driverpakke og PAE
  på UEFI med CSM; XP og Vista på UEFI uten CSM via CSMWrap
  (eksperimentelt); Windows 7 x64 uten CSM via UefiSeven og en dispatcher
  som dirigerer VGA til skjermkortet; integrering av USB 3 og NVMe for
  Windows 7.
- **Svarprofiler** for automatiske installasjoner av Windows og Linux,
  redigert i UEFI-menyen med et skjermtastatur.
- **Linux-ISO-er fra DATA** (Ubuntu, Mint, Fedora, Debian, SystemRescue,
  GParted, Clonezilla og andre), på UEFI med og uten Secure Boot og på BIOS.
- **Verktøy:** innebygd FreeDOS med filbehandler og et panel Hardware &
  SMART (BIOS), EDK2 UEFI-skall (UEFI), dine egne oppstartbare verktøy i
  `Utilities`, dine egne UEFI-drivere og mapper med INF-drivere for Windows.
- **Installasjonsprogram med fire moduser:** Installasjon, Lokal
  oppdatering (**Oppdater USOS**, beholder bilder og filene dine),
  Reparasjon (**Reparer ESP**), Avinstallering.
- **27 språk** (engelsk er referansen; de øvrige språkene, unntatt polsk, er
  merket som helt eller delvis maskinoversatt), temaer med en redigerer i
  menyen, støtte for berøring og spillkontroll på ROG Ally.

| | |
|---|---|
| ![Liste over Windows-systemer med statusmerker](../images/windows-list.png) | ![Liste over Linux-distribusjoner](../images/linux-list.png) |
| Windows-systemer med statusmerker | Linux-ISO-er fra DATA |
| ![Legacy BIOS-meny](../images/bios-menu.png) | ![Innebygde og egne temaer](../images/themes-grid.png) |
| Legacy BIOS-menyen | Temaer: Dark, Light, Retro, Sunset |

<a id="supported-systems"></a>
## 3. Støttede systemer og fastvaremoduser

**HW** = testet på ekte maskinvare, **VM** = bare testet i QEMU/VirtualBox,
**eksp.** = eksperimentelt (merket slik i menyen), **ikke testet** = veien
finnes, men ingen kjøring er registrert, **—** = ikke støttet (menyen viser
årsaken). Testmaskiner: **X470** (ASRock X470, Ryzen 7 5700X, Radeon RX 560,
UEFI), **MS-7100** (MSI, Socket 939, Athlon 64 X2, BIOS), **Ally** (ASUS ROG
Ally RC71L, UEFI med Secure Boot).

| System | BIOS (Legacy) | UEFI + CSM | UEFI uten CSM (CSMWrap) | Secure Boot på |
|---|---|---|---|---|
| Selve USOS-menyen | HW | HW | HW | HW (X470, Ally) |
| MS-DOS 6.22, Windows 3.1/3.11 | HW (Windows 3.1 i standardmodus, MS-7100) | — | — | — |
| Windows 98 SE | VM; HW delvis (MS-7100: Setup frem til klargjøringen av første oppstart, skrivebordet ikke bekreftet) | — | — | — |
| Windows 2000 SP4 | HW (MS-7100) | eksp., VM (til filkopieringen) | eksp., VM (CSMWrap) | — |
| Windows XP x86 SP3 | VM (ingen driverpakke, ingen PAE) | HW (X470: driverpakke, PAE, 31,9 GB) | eksp., HW (X470, CSMWrap) | — |
| Windows XP x64 SP2 | ikke testet | eksp., VM (til GUI Setup); X470: STOP 0xA5 | eksp., VM (CSMWrap) | — |
| Windows Server 2003 R2 SP2 x86 | ikke testet | eksp., VM (til GUI Setup); X470 ikke testet med 1.0 | eksp., VM (CSMWrap) | — |
| Windows Vista SP2 x64 | HW (MS-7100) | HW (X470) | eksp., HW (X470, CSMWrap, legacy MBR) | — |
| Windows 7 SP1 x64 | HW (MS-7100) | VM (full installasjon) | HW (X470, UefiSeven + dispatcher) | — |
| Windows 8 / 8.1 | ikke testet | ikke testet | ikke testet | ikke testet |
| Windows 10 | HW (x86, MS-7100) | HW (x64, X470) | innebygd UEFI, samme vei som med CSM | VM (frem til Windows-lasteren) |
| Windows 11 | ikke testet | HW (brukerrapport) | innebygd UEFI, samme vei som med CSM | VM (frem til Windows-lasteren) |
| Windows Server 2008 - 2025 | eksp., aldri startet | eksp., aldri startet | eksp., aldri startet | 2008/2008 R2: —; 2012+: ikke testet |
| Linux-ISO-er (Ubuntu, Mint, Fedora, Debian, GParted, Clonezilla) | VM; HW Mint live (MS-7100) | HW (X470: Mint, Fedora, Debian netinst, Clonezilla, GParted) | som med CSM | HW Fedora, Mint (X470); VM resten |
| SystemRescue | VM | HW (X470) | som med CSM | — (ingen signert oppstartslaster) |
| FreeDOS, Hardware & SMART (innebygd) | VM (FreeDOS); HW (Hardware & SMART) | — | — | — |
| MemTest86+ (i586-ISO, du skaffer den selv) | HW | `.efi`-bygg fra `Utilities` (ikke testet) | som med CSM | bare signert `.efi` |
| UEFI-skall (innebygd) | — | VM | VM | VM (starter, kan ikke starte verktøy) |

UEFI med eller uten CSM har bare betydning for legacy-veiene (2000, XP,
2003, Vista, 7); alle andre UEFI-oppføringer kjører den samme koden i begge
modusene. Windows XP, Vista og 7 og alle CSMWrap-veier krever at Secure Boot
er slått av. Den fullstendige tabellen med merknader og
maskinvareresultatene per bygg finnes i
[brukerveiledningen, avsnitt 5](../USER-GUIDE.en.md#5-what-works-in-which-firmware-mode)
og i [versjonsmerknadene](../release-notes-1.0.md#supported-systems) (på
engelsk).

<a id="quick-start"></a>
## 4. Kom raskt i gang

Filer i utgivelsen:

| Fil | Formål |
|---|---|
| `USOS-Installer-1.0.0.exe` | installasjonsprogrammet; inneholder hele USOS |
| `USOS-1.0.0-WinPE-PE10-donor.zip` | PE10-donor, nødvendig for Vista og originale Windows 7-ISO-er på UEFI |
| `USOS-1.0.0-XP-package-PL.zip`, `USOS-1.0.0-XP-package-EN.zip` | UEFI-pakke for Windows XP x86 SP3, hver for nøyaktig én original ISO (`pl_..._x14-80476.iso` / `en_..._x14-80428.iso`), installeres med det medfølgende `install-xp-package.ps1` |
| `USOS-1.0.0-sources.zip` + `SOURCE-OFFER.txt` | kildekode for tredjepartskomponentene og det skriftlige tilbudet om kildekode |
| `USOS-1.0.0-buildkit.zip` | fastlåste verktøykjeder og bygg-inndata for en ny bygging uten nett |
| `LICENSES/`, `THIRD-PARTY-NOTICES.txt` | lisenstekster og merknader |
| `SHA256SUMS` | SHA-256 for hver fil |

Kontroller en nedlasting med `certutil -hashfile USOS-Installer-1.0.0.exe SHA256`
(eller `Get-FileHash` i PowerShell) mot `SHA256SUMS`.

![USOS-installasjonsprogrammet: velg en operasjon](../images/installer-mode.png)

1. Skaff en minnepenn på **minst 32 GiB** (i praksis 64 GB; en minnepenn
   som selges som «32 GB», er som regel for liten). **Alt på den blir
   slettet.**
2. Kjør `USOS-Installer-1.0.0.exe` på en Windows-PC (den ber om
   administratorrettigheter), velg **Installasjon**, velg minnepennen, skriv
   inn bekreftelsesteksten og klikk på **SLETT OG INSTALLER**.
3. Kopier ISO-bildene dine til DATA-partisjonen, i mappen `Images` for det
   aktuelle systemet, f.eks. `Systems\Windows\Windows 11\Images\`.
4. Valgfritt: for Vista eller original Windows 7 på UEFI kopierer du mappen
   `Programs` fra PE10-donorens zip-fil til roten av DATA og kjører
   **Oppdater USOS**; for XP på UEFI kjører du `install-xp-package.ps1` som
   administrator fra XP-pakken som passer til ISO-en din (én pakke om
   gangen).
5. Start målmaskinen fra minnepennen (BIOS eller UEFI). Med Secure Boot på
   registrerer du USOS-nøkkelen én gang ([Secure Boot](#secure-boot)). Velg
   system og bilde, eventuelt en svarprofil, bekreft måldisken og følg
   systemets installasjonsprogram.

Trinnvise instruksjoner for hver skjerm finnes i
brukerveiledningen: [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md).

<a id="data-layout"></a>
## 5. Mappestruktur på DATA

Installasjonsprogrammet oppretter minnepennen med tre partisjoner:
`USOS_ESP` (FAT32, 1 GiB: oppstartsfiler, nøkkel, innstillinger, logger,
profiler), `USOS_DATA` (NTFS: filene dine) og `USOS_WORK` (NTFS,
arbeidsområde for enkelte Windows-installasjonsprogrammer). Alle mapper på
DATA opprettes for deg:

```
USOS_DATA\
├─ Systems\
│  ├─ Windows\<versjon>\    Images\  Unattended\   (Windows 3.1 til 11, Server 2003-2025)
│  ├─ Linux\<distribusjon>\ Images\  Unattended\   (Other Linux\ for ukjente ISO-er)
│  ├─ Betas\
│  └─ DOS\<variant>\        Images\
├─ Utilities\
│  ├─ FreeDOS\Programs\     DOS-programmer for den innebygde FreeDOS
│  ├─ UEFI Shell\Tools\     EFI-verktøy for UEFI-skallet
│  └─ <ditt verktøy>\Images\   f.eks. MemTest86\Images\memtest86.efi
├─ Drivers\
│  ├─ UEFI\<navn>\          .efi-drivere som USOS-menyen laster inn
│  └─ <Windows-versjon>\    Storage\  USB\  Other\  (INF-pakker)
├─ Themes\<navn>\theme.ini  dine egne temaer (UEFI-menyen)
└─ Programs\
   └─ USOS\                 styres av USOS (PE10-donor), ikke rør
```

Kjør **Oppdater USOS** etter at du har lagt til en `icon.png` eller en ny
verktøymappe. Hele treet finnes i
[brukerveiledningen, avsnitt 4](../USER-GUIDE.en.md#4-folder-layout-on-data).

<a id="secure-boot"></a>
## 6. Secure Boot

Med Secure Boot på starter USOS via **shim 16.1** (Fedora-bygg, signert av
Microsoft UEFI CA) og MokManager. Selve USOS og komponentene er signert med
**USOS-nøkkelen**, som registreres **én gang per datamaskin**:

- **Enklest:** slå av Secure Boot, start fra minnepennen, velg **Legg til**
  på startskjermen og bekreft med **Ja, lagre nøkkelen**, og slå deretter på
  Secure Boot igjen. Dette fungerer også i Setup Mode (bekreftet på X470).
- **Med Secure Boot på:** ved «Verification failed» velger du i MokManager
  **Enroll key from disk** -> `USOS_ESP` -> `USOS-KEY.cer` (bekreftet på
  ROG Ally). Kortet **Forbered (én gang)** i installasjonsprogrammet får
  MokManager til å vente i stedet for å telle ned.

En NVRAM-tilbakestilling fjerner nøkkelen; registrer den da på nytt. XP,
Vista, 7, alle CSMWrap-veier, SystemRescue og verktøy som startes fra
UEFI-skallet, krever at Secure Boot er slått av. Kjernen er ennå ikke låst
(punkt N6 i veikartet), så den som registrerer USOS-nøkkelen, stoler på alt
som er signert med den. Detaljer:
[brukerveiledningen, avsnitt 6](../USER-GUIDE.en.md#6-secure-boot-and-the-usos-key-mok),
[secure-boot-usos.md](../secure-boot-usos.md).

<a id="answer-profiles"></a>
## 7. Svarprofiler

Én liten profil (kontoer, datamaskinnavn, språk, tidssone, valgfrie
justeringer) gjøres ved oppstart om til `WINNT.SIF` (2000/XP/2003),
`autounattend.xml` (Vista til 11, Server) eller Ubuntu autoinstall, Debian
preseed eller Fedora kickstart. Profiler opprettes i UEFI-menyen
(**Automatisk installasjon** -> **+ Legg til en ny profil**) og lagres på
ESP-en.

![Redigerer for svarprofiler med delen Utseende og ekstra](../images/profile-editor-appearance.png)

- Måldisken **velges alltid manuelt**; en profil velger eller sletter aldri
  en disk.
- En produktnøkkel lagres bare hvis du krysser av for «Husk nøkkelen på
  denne minnepennen»; ellers huskes den bare til omstart. **USOS inneholder
  ingen nøkler** og omgår verken aktiveringen eller siden for
  produktnøkkelen.
- Passord og lagrede nøkler lagres på minnepennen som ren tekst (de vises
  aldri i lister eller logger). Linux-profiler fungerer bare på UEFI.

Detaljer: [brukerveiledningen, avsnitt 7](../USER-GUIDE.en.md#7-answer-profiles-and-tweaks),
[answer-profiles.md](../answer-profiles.md).

<a id="known-issues"></a>
## 8. Kjente problemer

- **Vista på hovedkort med bare USB 3 (X470):** minnepenner er ikke synlige
  i det installerte systemet, og Vista blir værende i testmodus
  (testsignert USB 3-backport). Et PCIe-kort med Renesas uPD72020x unngår
  begge deler.
- **CSMWrap-veier:** krever et skjermkort med legacy-VBIOS (ellers svart
  skjerm), bruker én CPU-tråd, trenger en MBR-måldisk (som slettes) og
  Secure Boot slått av.
- **Server 2003 x86 / XP x64:** STOP 0xA5 (ACPI) på X470 og ingen
  USB-inndata på hovedkort med bare xHCI.
- **Windows 2000** fungerer ikke på hovedkort med bare AHCI (ingen
  AHCI-driver for NT 5.0); **XP** har ikke støtte for NVMe og får ingen
  driverpakke eller PAE i BIOS-modus.
- **Secure Boot:** SystemRescue blokkeres (ingen signert laster);
  UEFI-skallet kan ikke starte verktøy; etter DBX-oppdateringen mot
  BlackLotus starter ikke eldre Windows-medier.
- **Linux:** installasjonsprogrammet for Ubuntu Server forhåndsvelger den
  største disken, som kan være USOS-minnepennen; kontroller alltid målet.
- **AMI-fastvare** viser hver partisjon på minnepennen som en egen
  oppstartsoppføring.
- Micro-Linux-hjelperen krever en x86-64-prosessor og minst 256 MiB RAM.

Den fullstendige listen med løsninger, og den ærlige listen over hva som
**ennå ikke er testet** på maskinvare (f.eks. Windows Server 2008-2025,
Windows 8/8.1, Windows 10/11 med Secure Boot på maskinvare, den originale
Windows 7 SP1-ISO-en via PE10-donoren), finnes i
[versjonsmerknadene](../release-notes-1.0.md#known-issues) (på engelsk) og i
[brukerveiledningen, avsnitt 9 og 10](../USER-GUIDE.en.md#9-known-issues-and-workarounds).

<a id="building"></a>
## 9. Bygge fra kildekode

Byggingen kjører på Windows. Fullstendige instruksjoner: [BUILDING.md](../BUILDING.md)
(på engelsk).

- `build.bat` bygger hele utgivelsen (EFI-program, micro-Linux,
  BIOS-kjerne, payload og `installer\USOS Installer.exe`) med én bygg-ID
  (`BYYMMDD-HHMMSS-XXXXXXXX`). Den portable Zig i `tools/zig` brukes; Go og
  Python må ligge i `PATH`.
- `tools/tests/run.ps1` kjører de automatiske testene, f.eks.
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/tests/run.ps1 -Suite all`.
- `powershell -ExecutionPolicy Bypass -File tools\release\make_release.ps1`
  lager utgivelsesfilene i `zig-out\release-1.0\`.
- **Bygging uten nett:** pakk ut `USOS-1.0.0-buildkit.zip`, sett
  `USOS_BUILDKIT` til den utpakkede mappen `USOS-1.0.0-buildkit` og kjør
  `build.bat`; settet kontrolleres mot manifestet sitt, og nedlastinger er
  slått av.
- **Signeringsnøkkel:** Secure Boot-nøkkelen (MOK) ligger **utenfor
  repositoriet**, i `%APPDATA%\USOS\signing\` (`USOS_SIGNING_DIR`
  overstyrer dette). Uten den er bygget **usignert** og starter bare med
  Secure Boot slått av. Aldri commit eller del nøkkelen.

Windows-ISO-er, drivere og andre tredjepartsmedier er aldri en del av
repositoriet.

<a id="licence"></a>
## 10. Lisens

- USOS' egen kode er lisensiert under **GNU General Public License,
  versjon 3 eller nyere** (GPL-3.0-or-later): se [LICENSE](../../LICENSE) og
  [NOTICE](../../NOTICE). Copyright (C) 2026 Maksymilian and the USOS Authors.
- Tredjepartskomponenter beholder sine egne lisenser. De er separate
  programmer samlet på minnepennen; se `THIRD-PARTY-NOTICES.txt` og
  `LICENSES/` i utgivelsen og [LICENSES-AUDIT.md](../LICENSES-AUDIT.md).
- Microsoft-filer i utgivelsen (oppdaterings- og driverfiler, filene i
  XP-pakkene, WinPE-donoren) beholdes for bevaringsformål, videredistribueres
  på vedlikeholderens egen risiko, er ikke dekket av noen USOS-lisens og
  fjernes på anmodning fra rettighetshaveren.
- Bidrag tas imot i henhold til [CONTRIBUTING.md](../../CONTRIBUTING.md) (en
  enkel lisensbevilgning fra bidragsyteren).

Windows, MS-DOS og tilknyttede navn er varemerker som tilhører Microsoft.
USOS er ikke tilknyttet Microsoft.

<a id="support"></a>
## 11. Støtte

- Spørsmål og feilrapporter: GitHub Issues. Legg ved loggene som er
  beskrevet i [brukerveiledningen, avsnitt 11](../USER-GUIDE.en.md#11-troubleshooting-and-logs),
  og kontroller at de ikke inneholder passord eller nøkler.
- Betalt hjelp med oppsett for bedrifter er tilgjengelig på forespørsel;
  inntil videre tar du kontakt via GitHub Issues.
- Sponsing: via `.github/FUNDING.yml` når den er fylt ut.

<a id="documentation"></a>
## 12. Dokumentasjon

- Brukerveiledning: [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md)
- [Versjonsmerknader 1.0](../release-notes-1.0.md) (på engelsk)
- [Hvordan USOS fungerer](../HOW-IT-WORKS.md)
- [Bygging](../BUILDING.md)
- [Lisensgjennomgang](../LICENSES-AUDIT.md)
- [Testplan for utgivelse 1.0](../RELEASE-TEST-1.0.md)
- [Veikart](../ROADMAP.md) (på polsk) og [testresultater](../../TESTING.md) (på polsk)
