# Universal Service OS (USOS) 1.0.0

> Toto je překlad. Závazná je [anglická verze README](../../README.md).

**Jazyky:** [English](../../README.md) ·
[Български](README.bg.md) ·
Čeština ·
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
[Svenska](README.sv.md) ·
[Türkçe](README.tr.md) ·
[Українська](README.uk.md)

## Obsah

1. [Co je USOS](#what-usos-is)
2. [Funkce](#features)
3. [Podporované systémy a režimy firmwaru](#supported-systems)
4. [Rychlý start](#quick-start)
5. [Struktura složek na DATA](#data-layout)
6. [Secure Boot](#secure-boot)
7. [Profily odpovědí](#answer-profiles)
8. [Známé problémy](#known-issues)
9. [Sestavení ze zdrojových kódů](#building)
10. [Licence](#licence)
11. [Podpora](#support)
12. [Dokumentace](#documentation)

<a id="what-usos-is"></a>
## 1. Co je USOS

USOS je jeden USB flash disk pro instalaci a spouštění operačních systémů od
MS-DOS po Windows 11 a Linux na počítačích s BIOSem i s UEFI, včetně UEFI se
zapnutým Secure Boot. Vlastní obrazy ISO na něj kopírujete jako běžné
soubory; USOS vám dá jedno menu, výslovný a chráněný výběr cílového disku
a ovladače a opravy, které staré systémy potřebují na novém hardwaru. Flash
disk se připravuje ve Windows programem `USOS-Installer-1.0.0.exe`. USOS
neobsahuje žádné obrazy Windows, žádné produktové klíče a nic, co by obcházelo
aktivaci.

![Menu UEFI USOS, domovská obrazovka](../images/menu-home.png)

<a id="features"></a>
## 2. Funkce

- **Jedno menu pro BIOS i UEFI.** Tentýž flash disk se spouští v režimu
  Legacy BIOS i v UEFI (x64) se stejným katalogem. Menu UEFI funguje
  s klávesnicí, myší, dotykovým displejem i USB gamepady.
- **Obrazy zůstávají soubory.** Obrazy ISO, WIM, IMG, VHD, VHDX a EFI se čtou
  přímo z oddílu NTFS DATA; nic se nerozbaluje a po zkopírování není třeba
  nic spouštět.
- **Chráněný cílový disk.** Disk vždy vybíráte a potvrzujete sami; samotný
  flash disk USOS se nikdy nenabízí.
- **Secure Boot** přes shim 16.1 (podepsaný společností Microsoft) a klíč USOS
  (MOK), který se na každém počítači zapíše jednou.
- **Staré Windows na novém hardwaru.** Windows XP s balíčkem ovladačů a PAE
  v UEFI s CSM; XP a Vista v UEFI bez CSM přes CSMWrap (experimentálně);
  Windows 7 x64 bez CSM přes UefiSeven a dispečer směrování VGA; integrace
  USB 3 a NVMe pro Windows 7.
- **Profily odpovědí** pro bezobslužné instalace Windows a Linuxu, upravované
  v menu UEFI pomocí klávesnice na obrazovce.
- **ISO Linuxu z DATA** (Ubuntu, Mint, Fedora, Debian, SystemRescue,
  GParted, Clonezilla a další) v UEFI se Secure Boot i bez něj a v BIOSu.
- **Nástroje:** vestavěný FreeDOS se správcem souborů a panelem Hardware &
  SMART (BIOS), EDK2 UEFI Shell (UEFI), vlastní spustitelné nástroje
  v `Utilities`, vlastní ovladače UEFI a složky s ovladači INF pro Windows.
- **Instalátor se čtyřmi režimy:** Instalace, Místní aktualizace
  (**Aktualizovat USOS**, zachová obrazy i vaše soubory), Oprava (**Opravit
  ESP**), Odinstalace.
- **27 jazyků** (referenční je angličtina; ostatní jazyky kromě polštiny jsou
  označeny jako zčásti nebo zcela strojově přeložené), motivy s editorem
  v menu, podpora dotyku a gamepadu na ROG Ally.

| | |
|---|---|
| ![Seznam systémů Windows se stavovými štítky](../images/windows-list.png) | ![Seznam distribucí Linuxu](../images/linux-list.png) |
| Systémy Windows se stavovými štítky | ISO Linuxu z DATA |
| ![Menu Legacy BIOS](../images/bios-menu.png) | ![Vestavěné a uživatelské motivy](../images/themes-grid.png) |
| Menu Legacy BIOS | Motivy: Dark, Light, Retro, Sunset |

<a id="supported-systems"></a>
## 3. Podporované systémy a režimy firmwaru

**HW** = otestováno na skutečném hardwaru, **VM** = otestováno jen
v QEMU/VirtualBox, **exp.** = experimentální (v menu tak označeno),
**netestováno** = cesta existuje, ale žádný běh není zaznamenán, **—** =
nepodporováno (menu uvede důvod). Testovací počítače: **X470** (ASRock X470,
Ryzen 7 5700X, Radeon RX 560, UEFI), **MS-7100** (MSI, Socket 939, Athlon 64
X2, BIOS), **Ally** (ASUS ROG Ally RC71L, UEFI se Secure Boot).

| Systém | BIOS (Legacy) | UEFI + CSM | UEFI bez CSM (CSMWrap) | Secure Boot zapnutý |
|---|---|---|---|---|
| Samotné menu USOS | HW | HW | HW | HW (X470, Ally) |
| MS-DOS 6.22, Windows 3.1/3.11 | HW (Windows 3.1 ve standardním režimu, MS-7100) | — | — | — |
| Windows 98 SE | VM; HW částečně (MS-7100: Setup až po přípravu prvního spuštění, plocha nepotvrzena) | — | — | — |
| Windows 2000 SP4 | HW (MS-7100) | exp., VM (po kopírování souborů) | exp., VM (CSMWrap) | — |
| Windows XP x86 SP3 | VM (bez balíčku ovladačů, bez PAE) | HW (X470: balíček ovladačů, PAE, 31,9 GB) | exp., HW (X470, CSMWrap) | — |
| Windows XP x64 SP2 | netestováno | exp., VM (po GUI Setup); X470: STOP 0xA5 | exp., VM (CSMWrap) | — |
| Windows Server 2003 R2 SP2 x86 | netestováno | exp., VM (po GUI Setup); X470 s 1.0 netestováno | exp., VM (CSMWrap) | — |
| Windows Vista SP2 x64 | HW (MS-7100) | HW (X470) | exp., HW (X470, CSMWrap, legacy MBR) | — |
| Windows 7 SP1 x64 | HW (MS-7100) | VM (úplná instalace) | HW (X470, UefiSeven + dispečer) | — |
| Windows 8 / 8.1 | netestováno | netestováno | netestováno | netestováno |
| Windows 10 | HW (x86, MS-7100) | HW (x64, X470) | nativní UEFI, stejná cesta jako s CSM | VM (po zavaděč Windows) |
| Windows 11 | netestováno | HW (hlášení uživatele) | nativní UEFI, stejná cesta jako s CSM | VM (po zavaděč Windows) |
| Windows Server 2008 - 2025 | exp., nikdy nespuštěno | exp., nikdy nespuštěno | exp., nikdy nespuštěno | 2008/2008 R2: —; 2012+: netestováno |
| ISO Linuxu (Ubuntu, Mint, Fedora, Debian, GParted, Clonezilla) | VM; HW Mint live (MS-7100) | HW (X470: Mint, Fedora, Debian netinst, Clonezilla, GParted) | stejně jako s CSM | HW Fedora, Mint (X470); ostatní VM |
| SystemRescue | VM | HW (X470) | stejně jako s CSM | — (žádný podepsaný zavaděč) |
| FreeDOS, Hardware & SMART (vestavěné) | VM (FreeDOS); HW (Hardware & SMART) | — | — | — |
| MemTest86+ (ISO i586, dodáte sami) | HW | sestavení `.efi` z `Utilities` (netestováno) | jako s CSM | jen podepsaný `.efi` |
| UEFI Shell (vestavěný) | — | VM | VM | VM (spustí se, ale nemůže spouštět nástroje) |

UEFI s CSM nebo bez něj hraje roli jen u starších (legacy) cest (2000, XP,
2003, Vista, 7); všechny ostatní položky UEFI běží v obou režimech stejným
kódem. Windows XP, Vista a 7 a každá cesta přes CSMWrap vyžadují vypnutý
Secure Boot. Úplnou tabulku s poznámkami a výsledky na hardwaru pro
jednotlivá sestavení najdete v
[uživatelské příručce, kapitola 5](../USER-GUIDE.en.md#5-what-works-in-which-firmware-mode)
a v [poznámkách k vydání](../release-notes-1.0.md#supported-systems)
(anglicky).

<a id="quick-start"></a>
## 4. Rychlý start

Soubory vydání:

**Nevíte, který? Stáhněte úplný instalátor.**

| Soubor | Účel |
|---|---|
| `USOS-Installer-1.0.0.exe` | **Úplný instalátor**: celý USOS včetně dárce WinPE a obou balíčků XP; funguje offline |
| `USOS-Installer-1.0.0-online.exe` | **Online instalátor**: malé stažení; dárce WinPE a balíčky XP stáhne z tohoto vydání, až budou potřeba, a ověří je |
| `USOS-1.0.0-WinPE-PE10-donor.zip` | dárce PE10, potřebný pro Vistu a originální ISO Windows 7 v UEFI |
| `USOS-1.0.0-XP-package-PL.zip`, `USOS-1.0.0-XP-package-EN.zip` | balíček UEFI pro Windows XP x86 SP3, každý pro právě jedno originální ISO (`pl_..._x14-80476.iso` / `en_..._x14-80428.iso`), instaluje se přiloženým skriptem `install-xp-package.ps1` |
| `USOS-1.0.0-sources.zip` + `SOURCE-OFFER.txt` | zdrojové kódy komponent třetích stran a písemná nabídka zdrojových kódů |
| `USOS-1.0.0-buildkit.zip` | připnuté sady nástrojů a vstupy sestavení pro offline sestavení |
| `LICENSES/`, `THIRD-PARTY-NOTICES.txt` | texty licencí a upozornění |
| `SHA256SUMS` | SHA-256 každého souboru |

Stažený soubor ověříte příkazem
`certutil -hashfile USOS-Installer-1.0.0.exe SHA256` (nebo `Get-FileHash`
v PowerShellu) proti `SHA256SUMS`.

![Instalátor USOS: volba operace](../images/installer-mode.png)

1. Opatřete si USB flash disk s kapacitou **alespoň 32 GiB** (v praxi 64 GB;
   disk prodávaný jako „32 GB“ bývá obvykle příliš malý). **Vše, co je na
   něm, bude smazáno.**
2. Na počítači s Windows spusťte `USOS-Installer-1.0.0.exe` (vyžádá si práva
   správce), zvolte **Instalace**, vyberte flash disk, napište potvrzovací
   text a klikněte na **SMAZAT A INSTALOVAT**.
3. Zkopírujte své obrazy ISO na oddíl DATA do složky `Images` příslušného
   systému, např. `Systems\Windows\Windows 11\Images\`.
4. Volitelně: pro Vistu nebo originální Windows 7 v UEFI zkopírujte složku
   `Programs` z archivu dárce PE10 do kořene DATA a spusťte **Aktualizovat
   USOS**; pro XP v UEFI spusťte jako správce `install-xp-package.ps1`
   z balíčku XP, který odpovídá vašemu ISO (vždy jen jeden balíček).
5. Spusťte cílový počítač z flash disku (BIOS nebo UEFI). Se zapnutým Secure
   Boot jednou zapište klíč USOS ([Secure Boot](#secure-boot)). Vyberte
   systém a obraz, případně profil odpovědí, potvrďte cílový disk
   a postupujte podle instalátoru systému.

Podrobný postup pro každou obrazovku je v uživatelské příručce:
[English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md).

<a id="data-layout"></a>
## 5. Struktura složek na DATA

Instalátor vytvoří na flash disku tři oddíly: `USOS_ESP` (FAT32, 1 GiB:
spouštěcí soubory, klíč, nastavení, protokoly, profily), `USOS_DATA` (NTFS:
vaše soubory) a `USOS_WORK` (NTFS, pracovní prostor pro některé instalátory
Windows). Všechny složky na DATA se vytvoří automaticky:

```
USOS_DATA\
├─ Systems\
│  ├─ Windows\<verze>\      Images\  Unattended\   (Windows 3.1 až 11, Server 2003-2025)
│  ├─ Linux\<distribuce>\   Images\  Unattended\   (Other Linux\ pro neznámá ISO)
│  ├─ Betas\
│  └─ DOS\<varianta>\       Images\
├─ Utilities\
│  ├─ FreeDOS\Programs\     programy DOS pro vestavěný FreeDOS
│  ├─ UEFI Shell\Tools\     nástroje EFI pro UEFI Shell
│  └─ <váš nástroj>\Images\   např. MemTest86\Images\memtest86.efi
├─ Drivers\
│  ├─ UEFI\<název>\         ovladače .efi načítané menu USOS
│  └─ <verze Windows>\      Storage\  USB\  Other\  (balíčky INF)
├─ Themes\<název>\theme.ini vlastní motivy (menu UEFI)
└─ Programs\
   └─ USOS\                 spravuje USOS (dárce PE10), neměnit
```

Po přidání souboru `icon.png` nebo nové složky s nástrojem spusťte
**Aktualizovat USOS**. Úplný strom je v
[uživatelské příručce, kapitola 4](../USER-GUIDE.en.md#4-folder-layout-on-data).

<a id="secure-boot"></a>
## 6. Secure Boot

Se zapnutým Secure Boot se USOS spouští přes **shim 16.1** (sestavení Fedory,
podepsané certifikační autoritou Microsoft UEFI CA) a MokManager. Samotný
USOS a jeho součásti jsou podepsány **klíčem USOS**, který se zapisuje
**jednou na každém počítači**:

- **Nejjednodušší:** vypněte Secure Boot, spusťte flash disk, na domovské
  obrazovce zvolte **Přidat** a potvrďte **Ano, uložit klíč**, pak Secure
  Boot znovu zapněte. Funguje to i v režimu Setup Mode (ověřeno na X470).
- **Se Secure Boot ponechaným zapnutým:** na obrazovce „Verification failed“
  použijte v MokManageru **Enroll key from disk** -> `USOS_ESP` ->
  `USOS-KEY.cer` (ověřeno na ROG Ally). Volba **Připravit (jednorázově)** na
  kartě Secure Boot v instalátoru zajistí, že MokManager čeká, místo aby
  odpočítával.

Reset NVRAM klíč odstraní; pak ho zapište znovu. XP, Vista, 7, každá cesta
přes CSMWrap, SystemRescue a nástroje spouštěné z UEFI Shell vyžadují vypnutý
Secure Boot. Jádro zatím není uzamčeno (bod roadmapy N6), takže zapsáním
klíče USOS důvěřujete všemu, co je jím podepsáno. Podrobnosti:
[uživatelská příručka, kapitola 6](../USER-GUIDE.en.md#6-secure-boot-and-the-usos-key-mok),
[secure-boot-usos.md](../secure-boot-usos.md).

<a id="answer-profiles"></a>
## 7. Profily odpovědí

Jeden malý profil (účty, název počítače, jazyk, časové pásmo, volitelné
úpravy) se při spuštění převede na `WINNT.SIF` (2000/XP/2003),
`autounattend.xml` (Vista až 11, Server) nebo na Ubuntu autoinstall, Debian
preseed či Fedora kickstart. Profily se vytvářejí v menu UEFI
(**Bezobslužná instalace** -> **+ Přidat nový profil**) a ukládají se na ESP.

![Editor profilu odpovědí s oddílem vzhledu a doplňků](../images/profile-editor-appearance.png)

- Cílový disk se **vždy vybírá ručně**; profil nikdy nevybírá ani nemaže
  disk.
- Produktový klíč se uloží jen tehdy, když zaškrtnete „Zapamatovat klíč na
  tomto flash disku“; jinak vydrží jen do restartu. **USOS neobsahuje žádné
  klíče** a neobchází aktivaci ani stránku s produktovým klíčem.
- Hesla a zapamatované klíče jsou na flash disku uloženy jako prostý text
  (nikdy se nezobrazují v seznamech ani v protokolech). Profily pro Linux
  fungují jen v UEFI.

Podrobnosti: [uživatelská příručka, kapitola 7](../USER-GUIDE.en.md#7-answer-profiles-and-tweaks),
[answer-profiles.md](../answer-profiles.md).

<a id="known-issues"></a>
## 8. Známé problémy

- **Vista na deskách jen s USB 3 (X470):** USB flash disky nejsou
  v nainstalovaném systému vidět a Vista zůstává v testovacím režimu
  (backport USB 3 je podepsán testovacím podpisem). Obojímu se vyhnete
  s kartou PCIe Renesas uPD72020x.
- **Cesty přes CSMWrap:** vyžadují grafickou kartu se starším (legacy)
  VBIOSem (jinak černá obrazovka), zaberou jedno vlákno CPU, potřebují
  cílový disk MBR (bude smazán) a vypnutý Secure Boot.
- **Server 2003 x86 / XP x64:** STOP 0xA5 (ACPI) na X470 a žádný vstup
  z USB na deskách jen s xHCI.
- **Windows 2000** nefunguje na deskách jen s AHCI (neexistuje ovladač AHCI
  pro NT 5.0); **XP** nepodporuje NVMe a v režimu BIOS nedostane balíček
  ovladačů ani PAE.
- **Secure Boot:** SystemRescue je blokován (žádný podepsaný zavaděč); UEFI
  Shell nemůže spouštět nástroje; po aktualizaci DBX kvůli BlackLotus se
  starší instalační média Windows nespustí.
- **Linux:** instalátor Ubuntu Server předem vybere největší disk, což může
  být flash disk USOS; vždy zkontrolujte cílový disk.
- **Firmware AMI** zobrazuje každý oddíl flash disku jako samostatnou
  spouštěcí položku.
- Pomocný mikro-Linux potřebuje procesor x86-64 a alespoň 256 MiB RAM.

Úplný seznam s náhradními řešeními a upřímný seznam toho, co zatím **nebylo
otestováno** na hardwaru (např. Windows Server 2008-2025, Windows 8/8.1,
Windows 10/11 se Secure Boot na hardwaru, originální ISO Windows 7 SP1 přes
dárce PE10), najdete v
[poznámkách k vydání](../release-notes-1.0.md#known-issues) (anglicky) a v
[uživatelské příručce, kapitoly 9 a 10](../USER-GUIDE.en.md#9-known-issues-and-workarounds).

<a id="building"></a>
## 9. Sestavení ze zdrojových kódů

Sestavení běží ve Windows. Úplný návod: [BUILDING.md](../BUILDING.md)
(anglicky).

- `build.bat` sestaví celé vydání (program EFI, mikro-Linux, jádro BIOS,
  payload a `installer\USOS Installer.exe`) s jedním identifikátorem
  sestavení (`BYYMMDD-HHMMSS-XXXXXXXX`). Použije se přenosný Zig
  z `tools/zig`; Go a Python musí být v `PATH`.
- `tools/tests/run.ps1` spouští automatické testy, např.
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/tests/run.ps1 -Suite all`.
- `powershell -ExecutionPolicy Bypass -File tools\release\make_release.ps1`
  vytvoří soubory vydání v `zig-out\release-1.0\`.
- **Offline sestavení:** rozbalte `USOS-1.0.0-buildkit.zip`, nastavte
  `USOS_BUILDKIT` na rozbalenou složku `USOS-1.0.0-buildkit` a spusťte
  `build.bat`; sada se ověří proti svému manifestu a stahování je vypnuto.
- **Podpisový klíč:** klíč Secure Boot (MOK) je uložen **mimo repozitář**,
  v `%APPDATA%\USOS\signing\` (umístění lze změnit proměnnou
  `USOS_SIGNING_DIR`). Bez něj je sestavení **nepodepsané** a spustí se jen
  s vypnutým Secure Boot. Klíč nikdy necommitujte ani nesdílejte.

ISO Windows, ovladače a další média třetích stran nikdy nejsou součástí
repozitáře.

<a id="licence"></a>
## 10. Licence

- Vlastní kód USOS je licencován pod **GNU General Public License verze 3
  nebo novější** (GPL-3.0-or-later): viz [LICENSE](../../LICENSE)
  a [NOTICE](../../NOTICE). Copyright (C) 2026 Maksymilian and the USOS Authors.
- Komponenty třetích stran si ponechávají své vlastní licence. Jsou to
  samostatné programy shromážděné na flash disku; viz
  `THIRD-PARTY-NOTICES.txt` a `LICENSES/` ve vydání
  a [LICENSES-AUDIT.md](../LICENSES-AUDIT.md).
- Soubory Microsoftu ve vydání (soubory aktualizací a ovladačů, soubory
  v balíčcích XP, dárce WinPE) jsou zachovány kvůli archivaci, šíří se na
  vlastní riziko správce projektu, nevztahuje se na ně žádná licence USOS
  a na žádost držitele práv budou odstraněny.
- Příspěvky se přijímají podle [CONTRIBUTING.md](../../CONTRIBUTING.md)
  (jednoduché udělení licence autorem příspěvku).

Windows, MS-DOS a související názvy jsou ochranné známky společnosti
Microsoft. USOS není se společností Microsoft nijak spojen.

<a id="support"></a>
## 11. Podpora

- Dotazy a hlášení chyb: GitHub Issues. Přiložte prosím protokoly popsané
  v [uživatelské příručce, kapitola 11](../USER-GUIDE.en.md#11-troubleshooting-and-logs)
  a zkontrolujte, že neobsahují hesla ani klíče.
- Placená pomoc s nasazením pro firmy je k dispozici na vyžádání; zatím se
  ozvěte přes GitHub Issues.
- Sponzorství: přes `.github/FUNDING.yml`, jakmile bude vyplněn.

<a id="documentation"></a>
## 12. Dokumentace

- Uživatelská příručka: [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md)
- [Poznámky k vydání 1.0](../release-notes-1.0.md) (anglicky)
- [Jak USOS funguje](../HOW-IT-WORKS.md)
- [Sestavení](../BUILDING.md)
- [Audit licencí](../LICENSES-AUDIT.md)
- [Plán testu vydání 1.0](../RELEASE-TEST-1.0.md)
- [Roadmapa](../ROADMAP.md) (polsky) a [výsledky testů](../../TESTING.md) (polsky)
