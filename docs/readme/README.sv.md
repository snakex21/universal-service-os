# Universal Service OS (USOS) 1.0.0

> Detta är en översättning. Den [engelska README-filen](../../README.md) är den gällande versionen.

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
[Norsk bokmål](README.nb.md) ·
[Nederlands](README.nl.md) ·
[Polski](README.pl.md) ·
[Português (Brasil)](README.pt-BR.md) ·
[Română](README.ro.md) ·
[Русский](README.ru.md) ·
[Slovenčina](README.sk.md) ·
[Slovenščina](README.sl.md) ·
[Srpski (latinica)](README.sr-Latn.md) ·
Svenska ·
[Türkçe](README.tr.md) ·
[Українська](README.uk.md)

## Innehåll

1. [Vad USOS är](#what-usos-is)
2. [Funktioner](#features)
3. [System och firmwarelägen som stöds](#supported-systems)
4. [Snabbstart](#quick-start)
5. [Mappstruktur på DATA](#data-layout)
6. [Secure Boot](#secure-boot)
7. [Svarsprofiler](#answer-profiles)
8. [Kända problem](#known-issues)
9. [Bygga från källkod](#building)
10. [Licens](#licence)
11. [Support](#support)
12. [Dokumentation](#documentation)

<a id="what-usos-is"></a>
## 1. Vad USOS är

USOS är ett enda USB-minne för att installera och starta operativsystem,
från MS-DOS till Windows 11 och Linux, på datorer med BIOS och UEFI, även
UEFI med Secure Boot. Du kopierar dina egna ISO-avbilder till minnet som
vanliga filer; USOS ger dig en meny, ett uttryckligt och skyddat val av
måldisk samt de drivrutiner och korrigeringar som gamla system behöver på ny
hårdvara. Minnet förbereds i Windows med `USOS-Installer-1.0.0.exe`. USOS
innehåller inga Windows-avbilder, inga produktnycklar och inget som kringgår
aktiveringen.

![USOS UEFI-meny, startskärm](../images/menu-home.png)

<a id="features"></a>
## 2. Funktioner

- **En meny för BIOS och UEFI.** Samma minne startar i Legacy BIOS och i
  UEFI (x64) med samma katalog. UEFI-menyn fungerar med tangentbord, mus,
  pekskärm och USB-handkontroller.
- **Avbilder förblir filer.** ISO-, WIM-, IMG-, VHD-, VHDX- och
  EFI-avbilder läses direkt från NTFS-partitionen DATA; ingenting packas upp
  och ingenting behöver köras efter kopieringen.
- **Skyddad måldisk.** Du väljer och bekräftar alltid disken själv; själva
  USOS-minnet erbjuds aldrig.
- **Secure Boot** via shim 16.1 (signerad av Microsoft) och USOS-nyckeln
  (MOK), som registreras en gång per dator.
- **Gamla Windows på ny hårdvara.** Windows XP med ett drivrutinspaket och
  PAE på UEFI med CSM; XP och Vista på UEFI utan CSM via CSMWrap
  (experimentellt); Windows 7 x64 utan CSM via UefiSeven och en dispatcher
  som dirigerar VGA till grafikkortet; integrering av USB 3 och NVMe för
  Windows 7.
- **Svarsprofiler** för obevakade installationer av Windows och Linux,
  redigerade i UEFI-menyn med ett skärmtangentbord.
- **Linux-ISO:er från DATA** (Ubuntu, Mint, Fedora, Debian, SystemRescue,
  GParted, Clonezilla med flera), på UEFI med och utan Secure Boot och på
  BIOS.
- **Verktyg:** inbyggd FreeDOS med filhanterare och en panel Hardware &
  SMART (BIOS), EDK2 UEFI-skal (UEFI), dina egna startbara verktyg i
  `Utilities`, dina egna UEFI-drivrutiner och mappar med INF-drivrutiner för
  Windows.
- **Installationsprogram med fyra lägen:** Installation, Lokal uppdatering
  (**Uppdatera USOS**, behåller avbilder och dina filer), Reparation
  (**Reparera ESP**), Avinstallation.
- **27 språk** (engelska är referensen; övriga språk utom polska är märkta
  som helt eller delvis maskinöversatta), teman med en redigerare i menyn,
  stöd för pekskärm och handkontroll på ROG Ally.

| | |
|---|---|
| ![Lista över Windows-system med statusmärken](../images/windows-list.png) | ![Lista över Linux-distributioner](../images/linux-list.png) |
| Windows-system med statusmärken | Linux-ISO:er från DATA |
| ![Legacy BIOS-meny](../images/bios-menu.png) | ![Inbyggda och egna teman](../images/themes-grid.png) |
| Legacy BIOS-menyn | Teman: Dark, Light, Retro, Sunset |

<a id="supported-systems"></a>
## 3. System och firmwarelägen som stöds

**HW** = testat på riktig hårdvara, **VM** = endast testat i
QEMU/VirtualBox, **exp.** = experimentellt (märkt så i menyn), **ej
testat** = vägen finns, men ingen körning har registrerats, **—** = stöds
inte (menyn visar orsaken). Testdatorer: **X470** (ASRock X470, Ryzen 7
5700X, Radeon RX 560, UEFI), **MS-7100** (MSI, Socket 939, Athlon 64 X2,
BIOS), **Ally** (ASUS ROG Ally RC71L, UEFI med Secure Boot).

| System | BIOS (Legacy) | UEFI + CSM | UEFI utan CSM (CSMWrap) | Secure Boot på |
|---|---|---|---|---|
| Själva USOS-menyn | HW | HW | HW | HW (X470, Ally) |
| MS-DOS 6.22, Windows 3.1/3.11 | HW (Windows 3.1 i standardläge, MS-7100) | — | — | — |
| Windows 98 SE | VM; HW delvis (MS-7100: Setup fram till förberedelsen av första starten, skrivbordet inte bekräftat) | — | — | — |
| Windows 2000 SP4 | HW (MS-7100) | exp., VM (till filkopieringen) | exp., VM (CSMWrap) | — |
| Windows XP x86 SP3 | VM (inget drivrutinspaket, ingen PAE) | HW (X470: drivrutinspaket, PAE, 31,9 GB) | exp., HW (X470, CSMWrap) | — |
| Windows XP x64 SP2 | ej testat | exp., VM (till GUI Setup); X470: STOP 0xA5 | exp., VM (CSMWrap) | — |
| Windows Server 2003 R2 SP2 x86 | ej testat | exp., VM (till GUI Setup); X470 ej testat med 1.0 | exp., VM (CSMWrap) | — |
| Windows Vista SP2 x64 | HW (MS-7100) | HW (X470) | exp., HW (X470, CSMWrap, legacy MBR) | — |
| Windows 7 SP1 x64 | HW (MS-7100) | VM (fullständig installation) | HW (X470, UefiSeven + dispatcher) | — |
| Windows 8 / 8.1 | ej testat | ej testat | ej testat | ej testat |
| Windows 10 | HW (x86, MS-7100) | HW (x64, X470) | inbyggd UEFI, samma väg som med CSM | VM (fram till Windows-laddaren) |
| Windows 11 | ej testat | HW (användarrapport) | inbyggd UEFI, samma väg som med CSM | VM (fram till Windows-laddaren) |
| Windows Server 2008 - 2025 | exp., aldrig startat | exp., aldrig startat | exp., aldrig startat | 2008/2008 R2: —; 2012+: ej testat |
| Linux-ISO:er (Ubuntu, Mint, Fedora, Debian, GParted, Clonezilla) | VM; HW Mint live (MS-7100) | HW (X470: Mint, Fedora, Debian netinst, Clonezilla, GParted) | som med CSM | HW Fedora, Mint (X470); VM resten |
| SystemRescue | VM | HW (X470) | som med CSM | — (ingen signerad starthanterare) |
| FreeDOS, Hardware & SMART (inbyggda) | VM (FreeDOS); HW (Hardware & SMART) | — | — | — |
| MemTest86+ (i586-ISO, du tillhandahåller den själv) | HW | `.efi`-bygge från `Utilities` (ej testat) | som med CSM | endast signerad `.efi` |
| UEFI-skal (inbyggt) | — | VM | VM | VM (startar, kan inte starta verktyg) |

UEFI med eller utan CSM spelar bara roll för legacy-vägarna (2000, XP,
2003, Vista, 7); alla andra UEFI-poster kör samma kod i båda lägena.
Windows XP, Vista och 7 och alla CSMWrap-vägar kräver att Secure Boot är
avstängt. Den fullständiga tabellen med kommentarer och hårdvaruresultaten
per bygge finns i
[användarhandboken, avsnitt 5](../USER-GUIDE.en.md#5-what-works-in-which-firmware-mode)
och i [versionsinformationen](../release-notes-1.0.md#supported-systems)
(på engelska).

<a id="quick-start"></a>
## 4. Snabbstart

Filer i utgåvan:

| Fil | Syfte |
|---|---|
| `USOS-Installer-1.0.0.exe` | installationsprogrammet; innehåller hela USOS |
| `USOS-1.0.0-WinPE-PE10-donor.zip` | PE10-donator, behövs för Vista och original-ISO:er av Windows 7 på UEFI |
| `USOS-1.0.0-XP-package-PL.zip`, `USOS-1.0.0-XP-package-EN.zip` | UEFI-paket för Windows XP x86 SP3, vart och ett för exakt en original-ISO (`pl_..._x14-80476.iso` / `en_..._x14-80428.iso`), installeras med medföljande `install-xp-package.ps1` |
| `USOS-1.0.0-sources.zip` + `SOURCE-OFFER.txt` | källkod för tredjepartskomponenterna och det skriftliga erbjudandet om källkod |
| `USOS-1.0.0-buildkit.zip` | fastlåsta verktygskedjor och bygg-indata för ett bygge offline |
| `LICENSES/`, `THIRD-PARTY-NOTICES.txt` | licenstexter och meddelanden |
| `SHA256SUMS` | SHA-256 för varje fil |

Kontrollera en nedladdning med `certutil -hashfile USOS-Installer-1.0.0.exe SHA256`
(eller `Get-FileHash` i PowerShell) mot `SHA256SUMS`.

![USOS-installationsprogrammet: välj en åtgärd](../images/installer-mode.png)

1. Skaffa ett USB-minne på **minst 32 GiB** (i praktiken 64 GB; ett minne
   som säljs som ”32 GB” är oftast för litet). **Allt på det raderas.**
2. Kör `USOS-Installer-1.0.0.exe` på en Windows-dator (programmet ber om
   administratörsbehörighet), välj **Installation**, välj minnet, skriv
   bekräftelsetexten och klicka på **RADERA OCH INSTALLERA**.
3. Kopiera dina ISO-avbilder till DATA-partitionen, till mappen `Images`
   för respektive system, t.ex. `Systems\Windows\Windows 11\Images\`.
4. Valfritt: för Vista eller original-Windows 7 på UEFI kopierar du mappen
   `Programs` från PE10-donatorns zip-fil till roten av DATA och kör
   **Uppdatera USOS**; för XP på UEFI kör du `install-xp-package.ps1` som
   administratör från det XP-paket som matchar din ISO (ett paket i taget).
5. Starta måldatorn från minnet (BIOS eller UEFI). Med Secure Boot på
   registrerar du USOS-nyckeln en gång ([Secure Boot](#secure-boot)). Välj
   system och avbild, eventuellt en svarsprofil, bekräfta måldisken och följ
   systemets installationsprogram.

Steg-för-steg-instruktioner för varje skärm finns i
användarhandboken: [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md).

<a id="data-layout"></a>
## 5. Mappstruktur på DATA

Installationsprogrammet skapar minnet med tre partitioner: `USOS_ESP`
(FAT32, 1 GiB: startfiler, nyckel, inställningar, loggar, profiler),
`USOS_DATA` (NTFS: dina filer) och `USOS_WORK` (NTFS, arbetsyta för vissa
Windows-installationsprogram). Alla mappar på DATA skapas åt dig:

```
USOS_DATA\
├─ Systems\
│  ├─ Windows\<version>\    Images\  Unattended\   (Windows 3.1 till 11, Server 2003-2025)
│  ├─ Linux\<distribution>\ Images\  Unattended\   (Other Linux\ för okända ISO:er)
│  ├─ Betas\
│  └─ DOS\<variant>\        Images\
├─ Utilities\
│  ├─ FreeDOS\Programs\     DOS-program för den inbyggda FreeDOS
│  ├─ UEFI Shell\Tools\     EFI-verktyg för UEFI-skalet
│  └─ <ditt verktyg>\Images\   t.ex. MemTest86\Images\memtest86.efi
├─ Drivers\
│  ├─ UEFI\<namn>\          .efi-drivrutiner som USOS-menyn läser in
│  └─ <Windows-version>\    Storage\  USB\  Other\  (INF-paket)
├─ Themes\<namn>\theme.ini  dina egna teman (UEFI-menyn)
└─ Programs\
   └─ USOS\                 hanteras av USOS (PE10-donator), rör inte
```

Kör **Uppdatera USOS** efter att du har lagt till en `icon.png` eller en ny
verktygsmapp. Hela trädet finns i
[användarhandboken, avsnitt 4](../USER-GUIDE.en.md#4-folder-layout-on-data).

<a id="secure-boot"></a>
## 6. Secure Boot

Med Secure Boot på startar USOS via **shim 16.1** (Fedora-bygge, signerat
av Microsoft UEFI CA) och MokManager. USOS själv och dess komponenter är
signerade med **USOS-nyckeln**, som registreras **en gång per dator**:

- **Enklast:** stäng av Secure Boot, starta från minnet, välj **Lägg till**
  på startskärmen och bekräfta med **Ja, spara nyckeln**, och slå sedan på
  Secure Boot igen. Detta fungerar även i Setup Mode (bekräftat på X470).
- **Med Secure Boot på:** vid ”Verification failed” väljer du i MokManager
  **Enroll key from disk** -> `USOS_ESP` -> `USOS-KEY.cer` (bekräftat på
  ROG Ally). Kortet **Förbered (en gång)** i installationsprogrammet får
  MokManager att vänta i stället för att räkna ned.

En NVRAM-återställning tar bort nyckeln; registrera den då igen. XP, Vista,
7, alla CSMWrap-vägar, SystemRescue och verktyg som startas från
UEFI-skalet kräver att Secure Boot är avstängt. Kärnan är ännu inte låst
(punkt N6 i färdplanen), så den som registrerar USOS-nyckeln litar på allt
som är signerat med den. Detaljer:
[användarhandboken, avsnitt 6](../USER-GUIDE.en.md#6-secure-boot-and-the-usos-key-mok),
[secure-boot-usos.md](../secure-boot-usos.md).

<a id="answer-profiles"></a>
## 7. Svarsprofiler

En liten profil (konton, datornamn, språk, tidszon, valfria justeringar)
omvandlas vid start till `WINNT.SIF` (2000/XP/2003), `autounattend.xml`
(Vista till 11, Server) eller Ubuntu autoinstall, Debian preseed eller
Fedora kickstart. Profiler skapas i UEFI-menyn (**Obevakad installation**
-> **+ Lägg till en ny profil**) och lagras på ESP.

![Redigerare för svarsprofiler med avsnittet Utseende och extra](../images/profile-editor-appearance.png)

- Måldisken **väljs alltid för hand**; en profil väljer eller raderar aldrig
  en disk.
- En produktnyckel sparas bara om du kryssar i ”Kom ihåg nyckeln på det här
  minnet”; annars finns den bara kvar till omstarten. **USOS innehåller
  inga nycklar** och kringgår varken aktiveringen eller sidan för
  produktnyckeln.
- Lösenord och sparade nycklar lagras på minnet som klartext (de visas
  aldrig i listor eller loggar). Linux-profiler fungerar endast på UEFI.

Detaljer: [användarhandboken, avsnitt 7](../USER-GUIDE.en.md#7-answer-profiles-and-tweaks),
[answer-profiles.md](../answer-profiles.md).

<a id="known-issues"></a>
## 8. Kända problem

- **Vista på moderkort med endast USB 3 (X470):** USB-minnen syns inte i
  det installerade systemet, och Vista stannar i testläge (testsignerad
  USB 3-backport). Ett PCIe-kort med Renesas uPD72020x undviker båda.
- **CSMWrap-vägar:** kräver ett grafikkort med legacy-VBIOS (annars svart
  skärm), tar upp en CPU-tråd, behöver en MBR-måldisk (som raderas) och
  Secure Boot avstängt.
- **Server 2003 x86 / XP x64:** STOP 0xA5 (ACPI) på X470 och ingen
  USB-inmatning på moderkort med endast xHCI.
- **Windows 2000** fungerar inte på moderkort med endast AHCI (ingen
  AHCI-drivrutin för NT 5.0); **XP** saknar stöd för NVMe och får inget
  drivrutinspaket eller PAE i BIOS-läge.
- **Secure Boot:** SystemRescue blockeras (ingen signerad laddare);
  UEFI-skalet kan inte starta verktyg; efter DBX-uppdateringen mot
  BlackLotus startar inte äldre Windows-media.
- **Linux:** installationsprogrammet för Ubuntu Server förväljer den största
  disken, vilket kan vara USOS-minnet; kontrollera alltid målet.
- **AMI-firmware** visar varje partition på minnet som en egen startpost.
- Micro-Linux-hjälpen kräver en x86-64-processor och minst 256 MiB RAM.

Den fullständiga listan med lösningar, och den ärliga listan över vad som
**ännu inte har testats** på hårdvara (t.ex. Windows Server 2008-2025,
Windows 8/8.1, Windows 10/11 med Secure Boot på hårdvara, original-ISO:n av
Windows 7 SP1 via PE10-donatorn), finns i
[versionsinformationen](../release-notes-1.0.md#known-issues) (på engelska)
och i [användarhandboken, avsnitt 9 och 10](../USER-GUIDE.en.md#9-known-issues-and-workarounds).

<a id="building"></a>
## 9. Bygga från källkod

Bygget körs på Windows. Fullständiga instruktioner: [BUILDING.md](../BUILDING.md)
(på engelska).

- `build.bat` bygger hela utgåvan (EFI-program, micro-Linux, BIOS-kärna,
  payload och `installer\USOS Installer.exe`) med ett och samma bygg-id
  (`BYYMMDD-HHMMSS-XXXXXXXX`). Den portabla Zig i `tools/zig` används; Go
  och Python måste finnas i `PATH`.
- `tools/tests/run.ps1` kör de automatiska testerna, t.ex.
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/tests/run.ps1 -Suite all`.
- `powershell -ExecutionPolicy Bypass -File tools\release\make_release.ps1`
  skapar utgåvans filer i `zig-out\release-1.0\`.
- **Bygge offline:** packa upp `USOS-1.0.0-buildkit.zip`, sätt
  `USOS_BUILDKIT` till den uppackade mappen `USOS-1.0.0-buildkit` och kör
  `build.bat`; kitet kontrolleras mot sitt manifest och nedladdningar är
  avstängda.
- **Signeringsnyckel:** Secure Boot-nyckeln (MOK) ligger **utanför
  repositoriet**, i `%APPDATA%\USOS\signing\` (`USOS_SIGNING_DIR`
  åsidosätter det). Utan den är bygget **osignerat** och startar bara med
  Secure Boot avstängt. Committa eller dela aldrig nyckeln.

Windows-ISO:er, drivrutiner och andra tredjepartsmedia ingår aldrig i
repositoriet.

<a id="licence"></a>
## 10. Licens

- USOS egen kod är licensierad under **GNU General Public License,
  version 3 eller senare** (GPL-3.0-or-later): se [LICENSE](../../LICENSE)
  och [NOTICE](../../NOTICE). Copyright (C) 2026 Maksymilian and the USOS Authors.
- Tredjepartskomponenter behåller sina egna licenser. De är separata
  program som samlats på minnet; se `THIRD-PARTY-NOTICES.txt` och
  `LICENSES/` i utgåvan samt [LICENSES-AUDIT.md](../LICENSES-AUDIT.md).
- Microsoft-filer i utgåvan (uppdaterings- och drivrutinsfiler, filerna i
  XP-paketen, WinPE-donatorn) behålls i bevarandesyfte, distribueras på
  underhållarens egen risk, omfattas inte av någon USOS-licens och tas bort
  på begäran av rättighetsinnehavaren.
- Bidrag tas emot enligt [CONTRIBUTING.md](../../CONTRIBUTING.md) (en enkel
  licensupplåtelse från bidragsgivaren).

Windows, MS-DOS och relaterade namn är varumärken som tillhör Microsoft.
USOS är inte knutet till Microsoft.

<a id="support"></a>
## 11. Support

- Frågor och felrapporter: GitHub Issues. Bifoga de loggar som beskrivs i
  [användarhandboken, avsnitt 11](../USER-GUIDE.en.md#11-troubleshooting-and-logs)
  och kontrollera att de inte innehåller lösenord eller nycklar.
- Betald hjälp med driftsättning för företag finns på begäran; tills vidare
  når du oss via GitHub Issues.
- Sponsring: via `.github/FUNDING.yml` när den har fyllts i.

<a id="documentation"></a>
## 12. Dokumentation

- Användarhandbok: [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md)
- [Versionsinformation 1.0](../release-notes-1.0.md) (på engelska)
- [Hur USOS fungerar](../HOW-IT-WORKS.md)
- [Bygga](../BUILDING.md)
- [Licensgranskning](../LICENSES-AUDIT.md)
- [Testplan för utgåva 1.0](../RELEASE-TEST-1.0.md)
- [Färdplan](../ROADMAP.md) (på polska) och [testresultat](../../TESTING.md) (på polska)
