# Universal Service OS (USOS) 1.0.0

> Toto je preklad. Záväzná je [anglická verzia README](../../README.md).

**Jazyky:** [English](../../README.md) ·
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
Slovenčina ·
[Slovenščina](README.sl.md) ·
[Srpski (latinica)](README.sr-Latn.md) ·
[Svenska](README.sv.md) ·
[Türkçe](README.tr.md) ·
[Українська](README.uk.md)

## Obsah

1. [Čo je USOS](#what-usos-is)
2. [Funkcie](#features)
3. [Podporované systémy a režimy firmvéru](#supported-systems)
4. [Rýchly štart](#quick-start)
5. [Štruktúra priečinkov na DATA](#data-layout)
6. [Secure Boot](#secure-boot)
7. [Profily odpovedí](#answer-profiles)
8. [Známe problémy](#known-issues)
9. [Zostavenie zo zdrojových kódov](#building)
10. [Licencia](#licence)
11. [Podpora](#support)
12. [Dokumentácia](#documentation)

<a id="what-usos-is"></a>
## 1. Čo je USOS

USOS je jeden USB kľúč na inštaláciu a spúšťanie operačných systémov od
MS-DOS po Windows 11 a Linux na počítačoch s BIOSom aj s UEFI, vrátane UEFI
so zapnutým Secure Boot. Vlastné obrazy ISO naň kopírujete ako bežné súbory;
USOS vám dá jedno menu, výslovný a chránený výber cieľového disku a ovládače
a opravy, ktoré staré systémy potrebujú na novom hardvéri. USB kľúč sa
pripravuje vo Windows programom `USOS-Installer-1.0.0.exe`. USOS neobsahuje
žiadne obrazy Windows, žiadne produktové kľúče ani nič, čo by obchádzalo
aktiváciu.

![Menu UEFI USOS, domovská obrazovka](../images/menu-home.png)

<a id="features"></a>
## 2. Funkcie

- **Jedno menu pre BIOS aj UEFI.** Ten istý USB kľúč sa spúšťa v režime
  Legacy BIOS aj v UEFI (x64) s rovnakým katalógom. Menu UEFI funguje
  s klávesnicou, myšou, dotykovou obrazovkou aj USB gamepadmi.
- **Obrazy zostávajú súbormi.** Obrazy ISO, WIM, IMG, VHD, VHDX a EFI sa
  čítajú priamo z oddielu NTFS DATA; nič sa nerozbaľuje a po skopírovaní
  netreba nič spúšťať.
- **Chránený cieľový disk.** Disk vždy vyberáte a potvrdzujete sami; samotný
  USB kľúč USOS sa nikdy neponúka.
- **Secure Boot** cez shim 16.1 (podpísaný spoločnosťou Microsoft) a kľúč
  USOS (MOK), ktorý sa na každom počítači zapíše raz.
- **Staré Windows na novom hardvéri.** Windows XP s balíkom ovládačov a PAE
  v UEFI s CSM; XP a Vista v UEFI bez CSM cez CSMWrap (experimentálne);
  Windows 7 x64 bez CSM cez UefiSeven a dispečer smerovania VGA; integrácia
  USB 3 a NVMe pre Windows 7.
- **Profily odpovedí** pre bezobslužné inštalácie Windows a Linuxu, upravované
  v menu UEFI pomocou klávesnice na obrazovke.
- **ISO Linuxu z DATA** (Ubuntu, Mint, Fedora, Debian, SystemRescue,
  GParted, Clonezilla a ďalšie) v UEFI so Secure Boot aj bez neho a v BIOSe.
- **Nástroje:** vstavaný FreeDOS so správcom súborov a panelom Hardware &
  SMART (BIOS), EDK2 UEFI Shell (UEFI), vlastné spustiteľné nástroje
  v `Utilities`, vlastné ovládače UEFI a priečinky s ovládačmi INF pre
  Windows.
- **Inštalátor so štyrmi režimami:** Inštalácia, Lokálna aktualizácia
  (**Aktualizovať USOS**, zachová obrazy aj vaše súbory), Oprava
  (**Opraviť ESP**), Odinštalovanie.
- **27 jazykov** (referenčná je angličtina; ostatné jazyky okrem poľštiny sú
  označené ako čiastočne alebo úplne strojovo preložené), motívy s editorom
  v menu, podpora dotyku a gamepadu na ROG Ally.

| | |
|---|---|
| ![Zoznam systémov Windows so stavovými štítkami](../images/windows-list.png) | ![Zoznam distribúcií Linuxu](../images/linux-list.png) |
| Systémy Windows so stavovými štítkami | ISO Linuxu z DATA |
| ![Menu Legacy BIOS](../images/bios-menu.png) | ![Vstavané a používateľské motívy](../images/themes-grid.png) |
| Menu Legacy BIOS | Motívy: Dark, Light, Retro, Sunset |

<a id="supported-systems"></a>
## 3. Podporované systémy a režimy firmvéru

**HW** = otestované na skutočnom hardvéri, **VM** = otestované len
v QEMU/VirtualBox, **exp.** = experimentálne (v menu tak označené),
**netestované** = cesta existuje, ale žiadny beh nie je zaznamenaný, **—** =
nepodporované (menu uvedie dôvod). Testovacie počítače: **X470** (ASRock
X470, Ryzen 7 5700X, Radeon RX 560, UEFI), **MS-7100** (MSI, Socket 939,
Athlon 64 X2, BIOS), **Ally** (ASUS ROG Ally RC71L, UEFI so Secure Boot).

| Systém | BIOS (Legacy) | UEFI + CSM | UEFI bez CSM (CSMWrap) | Secure Boot zapnutý |
|---|---|---|---|---|
| Samotné menu USOS | HW | HW | HW | HW (X470, Ally) |
| MS-DOS 6.22, Windows 3.1/3.11 | HW (Windows 3.1 v štandardnom režime, MS-7100) | — | — | — |
| Windows 98 SE | VM; HW čiastočne (MS-7100: Setup po prípravu prvého spustenia, pracovná plocha nepotvrdená) | — | — | — |
| Windows 2000 SP4 | HW (MS-7100) | exp., VM (po kopírovanie súborov) | exp., VM (CSMWrap) | — |
| Windows XP x86 SP3 | VM (bez balíka ovládačov, bez PAE) | HW (X470: balík ovládačov, PAE, 31,9 GB) | exp., HW (X470, CSMWrap) | — |
| Windows XP x64 SP2 | netestované | exp., VM (po GUI Setup); X470: STOP 0xA5 | exp., VM (CSMWrap) | — |
| Windows Server 2003 R2 SP2 x86 | netestované | exp., VM (po GUI Setup); X470 s 1.0 netestované | exp., VM (CSMWrap) | — |
| Windows Vista SP2 x64 | HW (MS-7100) | HW (X470) | exp., HW (X470, CSMWrap, legacy MBR) | — |
| Windows 7 SP1 x64 | HW (MS-7100) | VM (úplná inštalácia) | HW (X470, UefiSeven + dispečer) | — |
| Windows 8 / 8.1 | netestované | netestované | netestované | netestované |
| Windows 10 | HW (x86, MS-7100) | HW (x64, X470) | natívne UEFI, rovnaká cesta ako s CSM | VM (po zavádzač Windows) |
| Windows 11 | netestované | HW (hlásenie používateľa) | natívne UEFI, rovnaká cesta ako s CSM | VM (po zavádzač Windows) |
| Windows Server 2008 - 2025 | exp., nikdy nespustené | exp., nikdy nespustené | exp., nikdy nespustené | 2008/2008 R2: —; 2012+: netestované |
| ISO Linuxu (Ubuntu, Mint, Fedora, Debian, GParted, Clonezilla) | VM; HW Mint live (MS-7100) | HW (X470: Mint, Fedora, Debian netinst, Clonezilla, GParted) | rovnako ako s CSM | HW Fedora, Mint (X470); ostatné VM |
| SystemRescue | VM | HW (X470) | rovnako ako s CSM | — (žiadny podpísaný zavádzač) |
| FreeDOS, Hardware & SMART (vstavané) | VM (FreeDOS); HW (Hardware & SMART) | — | — | — |
| MemTest86+ (ISO i586, dodáte sami) | HW | zostavenie `.efi` z `Utilities` (netestované) | ako s CSM | len podpísaný `.efi` |
| UEFI Shell (vstavaný) | — | VM | VM | VM (spustí sa, ale nedokáže spúšťať nástroje) |

UEFI s CSM alebo bez neho zohráva úlohu len pri starších (legacy) cestách
(2000, XP, 2003, Vista, 7); všetky ostatné položky UEFI bežia v oboch
režimoch rovnakým kódom. Windows XP, Vista a 7 a každá cesta cez CSMWrap
vyžadujú vypnutý Secure Boot. Úplnú tabuľku s poznámkami a výsledkami na
hardvéri pre jednotlivé zostavenia nájdete v
[používateľskej príručke, kapitola 5](../USER-GUIDE.en.md#5-what-works-in-which-firmware-mode)
a v [poznámkach k vydaniu](../release-notes-1.0.md#supported-systems)
(v angličtine).

<a id="quick-start"></a>
## 4. Rýchly štart

Súbory vydania:

| Súbor | Účel |
|---|---|
| `USOS-Installer-1.0.0.exe` | inštalátor; obsahuje celý USOS |
| `USOS-1.0.0-WinPE-PE10-donor.zip` | darca PE10, potrebný pre Vistu a originálne ISO Windows 7 v UEFI |
| `USOS-1.0.0-XP-package-PL.zip`, `USOS-1.0.0-XP-package-EN.zip` | balík UEFI pre Windows XP x86 SP3, každý pre presne jedno originálne ISO (`pl_..._x14-80476.iso` / `en_..._x14-80428.iso`), inštaluje sa priloženým skriptom `install-xp-package.ps1` |
| `USOS-1.0.0-sources.zip` + `SOURCE-OFFER.txt` | zdrojové kódy komponentov tretích strán a písomná ponuka zdrojových kódov |
| `USOS-1.0.0-buildkit.zip` | pripnuté sady nástrojov a vstupy zostavenia na offline zostavenie |
| `LICENSES/`, `THIRD-PARTY-NOTICES.txt` | texty licencií a upozornenia |
| `SHA256SUMS` | SHA-256 každého súboru |

Stiahnutý súbor overíte príkazom
`certutil -hashfile USOS-Installer-1.0.0.exe SHA256` (alebo `Get-FileHash`
v PowerShelli) oproti `SHA256SUMS`.

![Inštalátor USOS: výber operácie](../images/installer-mode.png)

1. Zaobstarajte si USB kľúč s kapacitou **aspoň 32 GiB** (v praxi 64 GB;
   kľúč predávaný ako „32 GB“ je zvyčajne príliš malý). **Všetko, čo je na
   ňom, bude vymazané.**
2. Na počítači s Windows spustite `USOS-Installer-1.0.0.exe` (vyžiada si
   práva správcu), zvoľte **Inštalácia**, vyberte USB kľúč, napíšte
   potvrdzovací text a kliknite na **VYMAZAŤ A INŠTALOVAŤ**.
3. Skopírujte svoje obrazy ISO na oddiel DATA do priečinka `Images`
   príslušného systému, napr. `Systems\Windows\Windows 11\Images\`.
4. Voliteľne: pre Vistu alebo originálne Windows 7 v UEFI skopírujte
   priečinok `Programs` z archívu darcu PE10 do koreňa DATA a spustite
   **Aktualizovať USOS**; pre XP v UEFI spustite ako správca
   `install-xp-package.ps1` z balíka XP, ktorý zodpovedá vášmu ISO (vždy len
   jeden balík).
5. Spustite cieľový počítač z USB kľúča (BIOS alebo UEFI). So zapnutým
   Secure Boot raz zapíšte kľúč USOS ([Secure Boot](#secure-boot)). Vyberte
   systém a obraz, prípadne profil odpovedí, potvrďte cieľový disk
   a postupujte podľa inštalátora systému.

Podrobný postup pre každú obrazovku je v používateľskej príručke:
[English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md).

<a id="data-layout"></a>
## 5. Štruktúra priečinkov na DATA

Inštalátor vytvorí na USB kľúči tri oddiely: `USOS_ESP` (FAT32, 1 GiB:
spúšťacie súbory, kľúč, nastavenia, protokoly, profily), `USOS_DATA` (NTFS:
vaše súbory) a `USOS_WORK` (NTFS, pracovný priestor pre niektoré inštalátory
Windows). Všetky priečinky na DATA sa vytvoria automaticky:

```
USOS_DATA\
├─ Systems\
│  ├─ Windows\<verzia>\     Images\  Unattended\   (Windows 3.1 až 11, Server 2003-2025)
│  ├─ Linux\<distribúcia>\  Images\  Unattended\   (Other Linux\ pre neznáme ISO)
│  ├─ Betas\
│  └─ DOS\<variant>\        Images\
├─ Utilities\
│  ├─ FreeDOS\Programs\     programy DOS pre vstavaný FreeDOS
│  ├─ UEFI Shell\Tools\     nástroje EFI pre UEFI Shell
│  └─ <váš nástroj>\Images\   napr. MemTest86\Images\memtest86.efi
├─ Drivers\
│  ├─ UEFI\<názov>\         ovládače .efi načítané menu USOS
│  └─ <verzia Windows>\     Storage\  USB\  Other\  (balíky INF)
├─ Themes\<názov>\theme.ini vlastné motívy (menu UEFI)
└─ Programs\
   └─ USOS\                 spravuje USOS (darca PE10), nemeniť
```

Po pridaní súboru `icon.png` alebo nového priečinka s nástrojom spustite
**Aktualizovať USOS**. Úplný strom je v
[používateľskej príručke, kapitola 4](../USER-GUIDE.en.md#4-folder-layout-on-data).

<a id="secure-boot"></a>
## 6. Secure Boot

So zapnutým Secure Boot sa USOS spúšťa cez **shim 16.1** (zostavenie Fedory,
podpísané certifikačnou autoritou Microsoft UEFI CA) a MokManager. Samotný
USOS a jeho súčasti sú podpísané **kľúčom USOS**, ktorý sa zapisuje **raz na
každom počítači**:

- **Najjednoduchšie:** vypnite Secure Boot, spustite USB kľúč, na domovskej
  obrazovke zvoľte **Pridať** a potvrďte **Áno, uložiť kľúč**, potom Secure
  Boot znova zapnite. Funguje to aj v režime Setup Mode (overené na X470).
- **So Secure Boot ponechaným zapnutým:** na obrazovke „Verification
  failed“ použite v MokManageri **Enroll key from disk** -> `USOS_ESP` ->
  `USOS-KEY.cer` (overené na ROG Ally). Voľba **Pripraviť (jednorazovo)** na
  karte Secure Boot v inštalátore zabezpečí, že MokManager čaká namiesto
  odpočítavania.

Reset NVRAM kľúč odstráni; potom ho zapíšte znova. XP, Vista, 7, každá cesta
cez CSMWrap, SystemRescue a nástroje spúšťané z UEFI Shell vyžadujú vypnutý
Secure Boot. Jadro zatiaľ nie je uzamknuté (bod roadmapy N6), takže zápisom
kľúča USOS dôverujete všetkému, čo je ním podpísané. Podrobnosti:
[používateľská príručka, kapitola 6](../USER-GUIDE.en.md#6-secure-boot-and-the-usos-key-mok),
[secure-boot-usos.md](../secure-boot-usos.md).

<a id="answer-profiles"></a>
## 7. Profily odpovedí

Jeden malý profil (účty, názov počítača, jazyk, časové pásmo, voliteľné
úpravy) sa pri spustení prevedie na `WINNT.SIF` (2000/XP/2003),
`autounattend.xml` (Vista až 11, Server) alebo na Ubuntu autoinstall, Debian
preseed či Fedora kickstart. Profily sa vytvárajú v menu UEFI
(**Bezobslužná inštalácia** -> **+ Pridať nový profil**) a ukladajú sa na
ESP.

![Editor profilu odpovedí so sekciou vzhľadu a doplnkov](../images/profile-editor-appearance.png)

- Cieľový disk sa **vždy vyberá ručne**; profil nikdy nevyberá ani nemaže
  disk.
- Produktový kľúč sa uloží len vtedy, keď začiarknete „Zapamätať kľúč na
  tomto USB kľúči“; inak vydrží len do reštartu. **USOS neobsahuje žiadne
  kľúče** a neobchádza aktiváciu ani stránku s produktovým kľúčom.
- Heslá a zapamätané kľúče sú na USB kľúči uložené ako obyčajný text (nikdy
  sa nezobrazujú v zoznamoch ani v protokoloch). Profily pre Linux fungujú
  len v UEFI.

Podrobnosti: [používateľská príručka, kapitola 7](../USER-GUIDE.en.md#7-answer-profiles-and-tweaks),
[answer-profiles.md](../answer-profiles.md).

<a id="known-issues"></a>
## 8. Známe problémy

- **Vista na doskách len s USB 3 (X470):** USB kľúče nie sú
  v nainštalovanom systéme viditeľné a Vista zostáva v testovacom režime
  (backport USB 3 je podpísaný testovacím podpisom). Obom problémom sa
  vyhnete s kartou PCIe Renesas uPD72020x.
- **Cesty cez CSMWrap:** vyžadujú grafickú kartu so starším (legacy) VBIOSom
  (inak čierna obrazovka), zaberú jedno vlákno CPU, potrebujú cieľový disk
  MBR (bude vymazaný) a vypnutý Secure Boot.
- **Server 2003 x86 / XP x64:** STOP 0xA5 (ACPI) na X470 a žiadny vstup
  z USB na doskách len s xHCI.
- **Windows 2000** nefunguje na doskách len s AHCI (neexistuje ovládač AHCI
  pre NT 5.0); **XP** nepodporuje NVMe a v režime BIOS nedostane balík
  ovládačov ani PAE.
- **Secure Boot:** SystemRescue je zablokovaný (žiadny podpísaný zavádzač);
  UEFI Shell nedokáže spúšťať nástroje; po aktualizácii DBX kvôli BlackLotus
  sa staršie inštalačné médiá Windows nespustia.
- **Linux:** inštalátor Ubuntu Server vopred vyberie najväčší disk, čo môže
  byť USB kľúč USOS; vždy skontrolujte cieľový disk.
- **Firmvér AMI** zobrazuje každý oddiel USB kľúča ako samostatnú spúšťaciu
  položku.
- Pomocný mikro-Linux potrebuje procesor x86-64 a aspoň 256 MiB RAM.

Úplný zoznam s náhradnými riešeniami a úprimný zoznam toho, čo zatiaľ
**nebolo otestované** na hardvéri (napr. Windows Server 2008-2025, Windows
8/8.1, Windows 10/11 so Secure Boot na hardvéri, originálne ISO Windows 7
SP1 cez darcu PE10), nájdete v
[poznámkach k vydaniu](../release-notes-1.0.md#known-issues) (v angličtine)
a v [používateľskej príručke, kapitoly 9 a 10](../USER-GUIDE.en.md#9-known-issues-and-workarounds).

<a id="building"></a>
## 9. Zostavenie zo zdrojových kódov

Zostavenie beží vo Windows. Úplný návod: [BUILDING.md](../BUILDING.md)
(v angličtine).

- `build.bat` zostaví celé vydanie (program EFI, mikro-Linux, jadro BIOS,
  payload a `installer\USOS Installer.exe`) s jedným identifikátorom
  zostavenia (`BYYMMDD-HHMMSS-XXXXXXXX`). Použije sa prenosný Zig
  z `tools/zig`; Go a Python musia byť v `PATH`.
- `tools/tests/run.ps1` spúšťa automatické testy, napr.
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/tests/run.ps1 -Suite all`.
- `powershell -ExecutionPolicy Bypass -File tools\release\make_release.ps1`
  vytvorí súbory vydania v `zig-out\release-1.0\`.
- **Offline zostavenie:** rozbaľte `USOS-1.0.0-buildkit.zip`, nastavte
  `USOS_BUILDKIT` na rozbalený priečinok `USOS-1.0.0-buildkit` a spustite
  `build.bat`; sada sa overí oproti svojmu manifestu a sťahovanie je
  vypnuté.
- **Podpisový kľúč:** kľúč Secure Boot (MOK) je uložený **mimo
  repozitára**, v `%APPDATA%\USOS\signing\` (umiestnenie možno zmeniť
  premennou `USOS_SIGNING_DIR`). Bez neho je zostavenie **nepodpísané**
  a spustí sa len s vypnutým Secure Boot. Kľúč nikdy necommitujte ani
  nezdieľajte.

ISO Windows, ovládače a ďalšie médiá tretích strán nikdy nie sú súčasťou
repozitára.

<a id="licence"></a>
## 10. Licencia

- Vlastný kód USOS je licencovaný pod **GNU General Public License verzie 3
  alebo novšej** (GPL-3.0-or-later): pozri [LICENSE](../../LICENSE)
  a [NOTICE](../../NOTICE). Copyright (C) 2026 Maksymilian and the USOS Authors.
- Komponenty tretích strán si ponechávajú vlastné licencie. Sú to samostatné
  programy zhromaždené na USB kľúči; pozri `THIRD-PARTY-NOTICES.txt`
  a `LICENSES/` vo vydaní a [LICENSES-AUDIT.md](../LICENSES-AUDIT.md).
- Súbory Microsoftu vo vydaní (súbory aktualizácií a ovládačov, súbory
  v balíkoch XP, darca WinPE) sú zachované na archivačné účely, šíria sa na
  vlastné riziko správcu projektu, nevzťahuje sa na ne žiadna licencia USOS
  a na žiadosť držiteľa práv budú odstránené.
- Príspevky sa prijímajú podľa [CONTRIBUTING.md](../../CONTRIBUTING.md)
  (jednoduché udelenie licencie autorom príspevku).

Windows, MS-DOS a súvisiace názvy sú ochranné známky spoločnosti Microsoft.
USOS nie je so spoločnosťou Microsoft nijako spojený.

<a id="support"></a>
## 11. Podpora

- Otázky a hlásenia chýb: GitHub Issues. Priložte, prosím, protokoly opísané
  v [používateľskej príručke, kapitola 11](../USER-GUIDE.en.md#11-troubleshooting-and-logs)
  a skontrolujte, že neobsahujú heslá ani kľúče.
- Platená pomoc s nasadením pre firmy je k dispozícii na požiadanie; zatiaľ
  sa ozvite cez GitHub Issues.
- Sponzorstvo: cez `.github/FUNDING.yml`, keď bude vyplnený.

<a id="documentation"></a>
## 12. Dokumentácia

- Používateľská príručka: [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md)
- [Poznámky k vydaniu 1.0](../release-notes-1.0.md) (v angličtine)
- [Ako USOS funguje](../HOW-IT-WORKS.md)
- [Zostavenie](../BUILDING.md)
- [Audit licencií](../LICENSES-AUDIT.md)
- [Plán testu vydania 1.0](../RELEASE-TEST-1.0.md)
- [Roadmapa](../ROADMAP.md) (v poľštine) a [výsledky testov](../../TESTING.md) (v poľštine)
