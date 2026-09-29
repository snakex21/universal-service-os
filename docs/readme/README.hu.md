# Universal Service OS (USOS) 1.0.0

> Ez egy fordítás. A mérvadó az [angol nyelvű README](../../README.md).

**Nyelvek:** [English](../../README.md) ·
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
Magyar ·
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

## Tartalom

1. [Mi az USOS](#what-usos-is)
2. [Funkciók](#features)
3. [Támogatott rendszerek és firmware-módok](#supported-systems)
4. [Gyors kezdés](#quick-start)
5. [A DATA mappaszerkezete](#data-layout)
6. [Secure Boot](#secure-boot)
7. [Válaszprofilok](#answer-profiles)
8. [Ismert problémák](#known-issues)
9. [Összeállítás forráskódból](#building)
10. [Licenc](#licence)
11. [Támogatás](#support)
12. [Dokumentáció](#documentation)

<a id="what-usos-is"></a>
## 1. Mi az USOS

Az USOS egyetlen pendrive operációs rendszerek telepítéséhez és
indításához, az MS-DOS-tól a Windows 11-ig és a Linuxig, BIOS-os és UEFI-s
számítógépeken, beleértve a Secure Boottal működő UEFI-t is. A saját
ISO-képfájljaidat közönséges fájlként másolod a pendrive-ra; az USOS
egyetlen menüt ad, a céllemez kifejezett és védett kiválasztását, valamint
azokat az illesztőprogramokat és javításokat, amelyekre a régi rendszereknek
új hardveren szükségük van. A pendrive-ot Windows alatt a
`USOS-Installer-1.0.0.exe` programmal kell előkészíteni. Az USOS nem
tartalmaz Windows-képfájlokat, termékkulcsokat és aktiválás-megkerülést sem.

![Az USOS UEFI-menüje, kezdőképernyő](../images/menu-home.png)

<a id="features"></a>
## 2. Funkciók

- **Egy menü BIOS-hoz és UEFI-hez.** Ugyanaz a pendrive Legacy BIOS-ban és
  UEFI-ben (x64) is elindul, ugyanazzal a katalógussal. Az UEFI-menü
  billentyűzettel, egérrel, érintéssel és USB-s játékvezérlőkkel is
  használható.
- **A képfájlok fájlok maradnak.** Az ISO, WIM, IMG, VHD, VHDX és EFI
  képfájlokat közvetlenül az NTFS DATA partícióról olvassa; semmit sem kell
  kicsomagolni, és másolás után semmit sem kell futtatni.
- **Védett céllemez.** A lemezt mindig te választod ki és hagyod jóvá;
  magát az USOS pendrive-ot soha nem ajánlja fel.
- **Secure Boot** a shim 16.1 (a Microsoft által aláírva) és az USOS-kulcs
  (MOK) segítségével, amelyet számítógépenként egyszer kell regisztrálni.
- **Régi Windows új hardveren.** Windows XP illesztőprogram-csomaggal és
  PAE-vel UEFI-n, CSM-mel; XP és Vista UEFI-n CSM nélkül a CSMWrap
  segítségével (kísérleti); Windows 7 x64 CSM nélkül az UefiSeven és egy
  VGA-irányító diszpécser segítségével; USB 3 és NVMe integráció
  Windows 7-hez.
- **Válaszprofilok** felügyelet nélküli Windows- és Linux-telepítésekhez,
  az UEFI-menüben szerkeszthetők, képernyő-billentyűzettel is.
- **Linux ISO-k a DATA partícióról** (Ubuntu, Mint, Fedora, Debian,
  SystemRescue, GParted, Clonezilla és mások) UEFI-n Secure Boottal és
  anélkül, valamint BIOS-on.
- **Eszközök:** beépített FreeDOS fájlkezelővel és Hardware & SMART
  panellel (BIOS), az EDK2 UEFI Shell (UEFI), saját indítható eszközeid a
  `Utilities` mappában, saját UEFI-illesztőprogramjaid és Windows
  INF-illesztőprogram-mappáid.
- **Telepítő négy móddal:** Telepítés, Helyi frissítés (**USOS frissítése**,
  megtartja a képfájlokat és a fájljaidat), Javítás (**ESP javítása**),
  Eltávolítás.
- **27 nyelv** (a referencia az angol; a többi nyelv a lengyel kivételével
  részben vagy teljesen gépi fordításként van jelölve), témák menün belüli
  szerkesztővel, érintés- és játékvezérlő-támogatás a ROG Allyn.

| | |
|---|---|
| ![Windows-rendszerek listája állapotjelzőkkel](../images/windows-list.png) | ![Linux-disztribúciók listája](../images/linux-list.png) |
| Windows-rendszerek állapotjelzőkkel | Linux ISO-k a DATA partícióról |
| ![Legacy BIOS menü](../images/bios-menu.png) | ![Beépített és saját témák](../images/themes-grid.png) |
| A Legacy BIOS menü | Témák: Dark, Light, Retro, Sunset |

<a id="supported-systems"></a>
## 3. Támogatott rendszerek és firmware-módok

**HW** = valódi hardveren tesztelve, **VM** = csak QEMU/VirtualBox alatt
tesztelve, **kísérl.** = kísérleti (a menüben is így jelölve), **nem
tesztelt** = az útvonal létezik, de nincs rögzített futtatás, **—** = nem
támogatott (a menü kiírja az okát). Tesztgépek: **X470** (ASRock X470,
Ryzen 7 5700X, Radeon RX 560, UEFI), **MS-7100** (MSI, Socket 939,
Athlon 64 X2, BIOS), **Ally** (ASUS ROG Ally RC71L, UEFI Secure Boottal).

| Rendszer | BIOS (Legacy) | UEFI + CSM | UEFI CSM nélkül (CSMWrap) | Secure Boot bekapcsolva |
|---|---|---|---|---|
| Maga az USOS menü | HW | HW | HW | HW (X470, Ally) |
| MS-DOS 6.22, Windows 3.1/3.11 | HW (Windows 3.1 standard módban, MS-7100) | — | — | — |
| Windows 98 SE | VM; HW részben (MS-7100: Setup az első indítás előkészítéséig, az asztal nincs megerősítve) | — | — | — |
| Windows 2000 SP4 | HW (MS-7100) | kísérl., VM (a fájlmásolásig) | kísérl., VM (CSMWrap) | — |
| Windows XP x86 SP3 | VM (illesztőprogram-csomag és PAE nélkül) | HW (X470: illesztőprogram-csomag, PAE, 31,9 GB) | kísérl., HW (X470, CSMWrap) | — |
| Windows XP x64 SP2 | nem tesztelt | kísérl., VM (a GUI Setupig); X470: STOP 0xA5 | kísérl., VM (CSMWrap) | — |
| Windows Server 2003 R2 SP2 x86 | nem tesztelt | kísérl., VM (a GUI Setupig); X470 az 1.0-val nem tesztelt | kísérl., VM (CSMWrap) | — |
| Windows Vista SP2 x64 | HW (MS-7100) | HW (X470) | kísérl., HW (X470, CSMWrap, legacy MBR) | — |
| Windows 7 SP1 x64 | HW (MS-7100) | VM (teljes telepítés) | HW (X470, UefiSeven + diszpécser) | — |
| Windows 8 / 8.1 | nem tesztelt | nem tesztelt | nem tesztelt | nem tesztelt |
| Windows 10 | HW (x86, MS-7100) | HW (x64, X470) | natív UEFI, ugyanaz az útvonal, mint CSM-mel | VM (a Windows betöltőig) |
| Windows 11 | nem tesztelt | HW (felhasználói jelentés) | natív UEFI, ugyanaz az útvonal, mint CSM-mel | VM (a Windows betöltőig) |
| Windows Server 2008 - 2025 | kísérl., soha nem indult el | kísérl., soha nem indult el | kísérl., soha nem indult el | 2008/2008 R2: —; 2012+: nem tesztelt |
| Linux ISO-k (Ubuntu, Mint, Fedora, Debian, GParted, Clonezilla) | VM; HW Mint live (MS-7100) | HW (X470: Mint, Fedora, Debian netinst, Clonezilla, GParted) | ugyanaz, mint CSM-mel | HW Fedora, Mint (X470); a többi VM |
| SystemRescue | VM | HW (X470) | ugyanaz, mint CSM-mel | — (nincs aláírt rendszerbetöltő) |
| FreeDOS, Hardware & SMART (beépített) | VM (FreeDOS); HW (Hardware & SMART) | — | — | — |
| MemTest86+ (i586 ISO, te biztosítod) | HW | `.efi` változat a `Utilities` mappából (nem tesztelt) | mint CSM-mel | csak aláírt `.efi` |
| UEFI Shell (beépített) | — | VM | VM | VM (elindul, de eszközöket nem tud indítani) |

Az, hogy az UEFI CSM-mel vagy anélkül fut, csak a legacy útvonalaknál
számít (2000, XP, 2003, Vista, 7); minden más UEFI-bejegyzés mindkét módban
ugyanazt a kódot futtatja. A Windows XP, Vista és 7, valamint minden
CSMWrap-útvonal kikapcsolt Secure Bootot igényel. A teljes táblázat
megjegyzésekkel és buildenkénti hardvereredményekkel:
[felhasználói útmutató, 5. szakasz](../USER-GUIDE.en.md#5-what-works-in-which-firmware-mode)
és [kiadási megjegyzések](../release-notes-1.0.md#supported-systems)
(angolul).

<a id="quick-start"></a>
## 4. Gyors kezdés

Kiadási fájlok:

**Nem tudja, melyiket? Töltse le a teljes telepítőt.**

| Fájl | Rendeltetés |
|---|---|
| `USOS-Installer-1.0.0.exe` | **Teljes telepítő**: a teljes USOS a WinPE donorral és mindkét XP csomaggal; internet nélkül is működik |
| `USOS-Installer-1.0.0-online.exe` | **Online telepítő**: kis letöltés; szükség esetén letölti a WinPE donort és az XP csomagokat ebből a kiadásból, és ellenőrzi őket |
| `USOS-1.0.0-WinPE-PE10-donor.zip` | PE10-donor, a Vistához és az eredeti Windows 7 ISO-khoz szükséges UEFI-n |
| `USOS-1.0.0-XP-package-PL.zip`, `USOS-1.0.0-XP-package-EN.zip` | Windows XP x86 SP3 UEFI-csomag, mindegyik pontosan egy eredeti ISO-hoz (`pl_..._x14-80476.iso` / `en_..._x14-80428.iso`), a mellékelt `install-xp-package.ps1` szkripttel telepíthető |
| `USOS-1.0.0-sources.zip` + `SOURCE-OFFER.txt` | a külső komponensek forráskódja és az írásos forráskód-ajánlat |
| `USOS-1.0.0-buildkit.zip` | rögzített eszközláncok és build-bemenetek offline újraépítéshez |
| `LICENSES/`, `THIRD-PARTY-NOTICES.txt` | licencszövegek és közlemények |
| `SHA256SUMS` | minden fájl SHA-256 értéke |

A letöltött fájlt a `certutil -hashfile USOS-Installer-1.0.0.exe SHA256`
paranccsal (vagy PowerShellben a `Get-FileHash` paranccsal) ellenőrizheted
a `SHA256SUMS` alapján.

![USOS telepítő: művelet kiválasztása](../images/installer-mode.png)

1. Szerezz be egy **legalább 32 GiB-os** pendrive-ot (a gyakorlatban
   64 GB-osat; a „32 GB”-osként árult pendrive általában túl kicsi).
   **Minden adat törlődik róla.**
2. Egy windowsos gépen futtasd a `USOS-Installer-1.0.0.exe` programot
   (rendszergazdai jogokat kér), válaszd a **Telepítés** módot, jelöld ki a
   pendrive-ot, írd be a megerősítő szöveget, és kattints a **TÖRLÉS ÉS
   TELEPÍTÉS** gombra.
3. Másold az ISO-képfájljaidat a DATA partícióra, az adott rendszer
   `Images` mappájába, pl. `Systems\Windows\Windows 11\Images\`.
4. Opcionális: a Vistához vagy az eredeti Windows 7-hez UEFI-n másold a
   PE10-donor zip `Programs` mappáját a DATA gyökerébe, és futtasd az
   **USOS frissítése** műveletet; XP-hez UEFI-n futtasd rendszergazdaként az
   ISO-dhoz illő XP-csomag `install-xp-package.ps1` szkriptjét (egyszerre
   csak egy csomag).
5. Indítsd a célgépet a pendrive-ról (BIOS vagy UEFI). Bekapcsolt Secure
   Boot esetén egyszer regisztráld az USOS-kulcsot
   ([Secure Boot](#secure-boot)). Válaszd ki a rendszert és a képfájlt,
   opcionálisan egy válaszprofilt, hagyd jóvá a céllemezt, és kövesd a
   rendszer telepítőjét.

Lépésről lépésre haladó útmutatás minden képernyőhöz a felhasználói
útmutatóban: [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md).

<a id="data-layout"></a>
## 5. A DATA mappaszerkezete

A telepítő három partícióval hozza létre a pendrive-ot: `USOS_ESP` (FAT32,
1 GiB: rendszerindító fájlok, kulcs, beállítások, naplók, profilok),
`USOS_DATA` (NTFS: a fájljaid) és `USOS_WORK` (NTFS, munkaterület egyes
Windows-telepítők számára). A DATA összes mappáját a telepítő hozza létre:

```
USOS_DATA\
├─ Systems\
│  ├─ Windows\<verzió>\     Images\  Unattended\   (Windows 3.1-től 11-ig, Server 2003-2025)
│  ├─ Linux\<disztribúció>\ Images\  Unattended\   (Other Linux\ az ismeretlen ISO-khoz)
│  ├─ Betas\
│  └─ DOS\<változat>\       Images\
├─ Utilities\
│  ├─ FreeDOS\Programs\     DOS-programok a beépített FreeDOS-hoz
│  ├─ UEFI Shell\Tools\     EFI-eszközök az UEFI Shellhez
│  └─ <saját eszköz>\Images\   pl. MemTest86\Images\memtest86.efi
├─ Drivers\
│  ├─ UEFI\<név>\           az USOS menü által betöltött .efi illesztőprogramok
│  └─ <Windows-verzió>\     Storage\  USB\  Other\  (INF-csomagok)
├─ Themes\<név>\theme.ini   saját témák (UEFI-menü)
└─ Programs\
   └─ USOS\                 az USOS kezeli (PE10-donor), ne módosítsd
```

Egy `icon.png` vagy egy új eszközmappa hozzáadása után futtasd az **USOS
frissítése** műveletet. A teljes fa:
[felhasználói útmutató, 4. szakasz](../USER-GUIDE.en.md#4-folder-layout-on-data).

<a id="secure-boot"></a>
## 6. Secure Boot

Bekapcsolt Secure Boot mellett az USOS a **shim 16.1** (Fedora-build, a
Microsoft UEFI CA által aláírva) és a MokManager segítségével indul. Magát
az USOS-t és komponenseit az **USOS-kulcs** írja alá, amelyet
**számítógépenként egyszer** kell regisztrálni:

- **Legegyszerűbb:** kapcsold ki a Secure Bootot, indítsd el a pendrive-ot,
  a kezdőképernyőn válaszd a **Hozzáadás** lehetőséget, erősítsd meg az
  **Igen, mentse a kulcsot** gombbal, majd kapcsold vissza a Secure Bootot.
  Ez Setup Mode-ban is működik (az X470-en megerősítve).
- **Bekapcsolva hagyott Secure Boottal:** a „Verification failed”
  képernyőn használd a MokManager -> **Enroll key from disk** -> `USOS_ESP`
  -> `USOS-KEY.cer` utat (a ROG Allyn megerősítve). A telepítő
  **Előkészítés (egyszeri)** kártyája eléri, hogy a MokManager
  visszaszámlálás helyett várjon.

Az NVRAM visszaállítása eltávolítja a kulcsot; ilyenkor újra regisztrálni
kell. Az XP, a Vista, a 7, minden CSMWrap-útvonal, a SystemRescue és az
UEFI Shellből indított eszközök kikapcsolt Secure Bootot igényelnek. A
kernel még nincs zárolva (N6-os ütemtervpont), így az USOS-kulcs
regisztrálásával mindenben megbízol, amit vele aláírtak. Részletek:
[felhasználói útmutató, 6. szakasz](../USER-GUIDE.en.md#6-secure-boot-and-the-usos-key-mok),
[secure-boot-usos.md](../secure-boot-usos.md).

<a id="answer-profiles"></a>
## 7. Válaszprofilok

Egyetlen kis profil (fiókok, számítógépnév, nyelv, időzóna, opcionális
finomhangolások) indításkor `WINNT.SIF` (2000/XP/2003), `autounattend.xml`
(Vistától 11-ig, Server) vagy Ubuntu autoinstall, Debian preseed, illetve
Fedora kickstart formává alakul. A profilok az UEFI-menüben hozhatók létre
(**Felügyelet nélküli telepítés** -> **+ Új profil hozzáadása**), és az
ESP-n tárolódnak.

![Válaszprofil-szerkesztő a Megjelenés és extrák szakasszal](../images/profile-editor-appearance.png)

- A céllemezt **mindig kézzel kell kiválasztani**; a profil soha nem
  választ ki és nem töröl lemezt.
- A termékkulcs csak akkor tárolódik, ha bejelölöd a „Kulcs megjegyzése
  ezen a pendrive-on” lehetőséget; egyébként csak az újraindításig marad
  meg. **Az USOS nem tartalmaz kulcsokat**, és nem kerüli meg sem az
  aktiválást, sem a termékkulcs-oldalt.
- A jelszavak és a megjegyzett kulcsok egyszerű szövegként vannak a
  pendrive-on (listákban és naplókban soha nem jelennek meg). A
  Linux-profilok csak UEFI-n működnek.

Részletek: [felhasználói útmutató, 7. szakasz](../USER-GUIDE.en.md#7-answer-profiles-and-tweaks),
[answer-profiles.md](../answer-profiles.md).

<a id="known-issues"></a>
## 8. Ismert problémák

- **Vista csak USB 3-as alaplapokon (X470):** az USB-s pendrive-ok nem
  láthatók a telepített rendszerben, és a Vista tesztmódban marad
  (tesztaláírású USB 3 backport). Egy Renesas uPD72020x PCIe-kártya
  mindkettőt elkerüli.
- **CSMWrap-útvonalak:** legacy VBIOS-szal rendelkező videokártyát
  igényelnek (különben fekete a képernyő), egy CPU-szálat elfoglalnak, MBR-es
  céllemezt (törlődik) és kikapcsolt Secure Bootot igényelnek.
- **Server 2003 x86 / XP x64:** STOP 0xA5 (ACPI) az X470-en, és nincs
  USB-bevitel a csak xHCI-s alaplapokon.
- A **Windows 2000** nem működik a csak AHCI-s alaplapokon (nincs NT 5.0-s
  AHCI-illesztőprogram); az **XP** nem támogatja az NVMe-t, és BIOS módban
  nem kap illesztőprogram-csomagot és PAE-t.
- **Secure Boot:** a SystemRescue blokkolva van (nincs aláírt betöltő); az
  UEFI Shell nem tud eszközöket indítani; a BlackLotus DBX-frissítés után a
  régebbi Windows-telepítőmédiák nem indulnak el.
- **Linux:** az Ubuntu Server telepítője előre kijelöli a legnagyobb
  lemezt, ami az USOS pendrive is lehet; mindig ellenőrizd a céllemezt.
- Az **AMI firmware** a pendrive minden partícióját külön rendszerindító
  bejegyzésként listázza.
- A mikro-Linux segédrendszerhez x86-64-es CPU és legalább 256 MiB RAM
  szükséges.

A teljes lista a megkerülő megoldásokkal, valamint az őszinte lista arról,
mit **nem teszteltek még** hardveren (pl. Windows Server 2008-2025,
Windows 8/8.1, Windows 10/11 Secure Boottal hardveren, az eredeti Windows 7
SP1 ISO a PE10-donoron keresztül), a
[kiadási megjegyzésekben](../release-notes-1.0.md#known-issues) (angolul) és a
[felhasználói útmutató 9. és 10. szakaszában](../USER-GUIDE.en.md#9-known-issues-and-workarounds)
található.

<a id="building"></a>
## 9. Összeállítás forráskódból

A build Windows alatt fut. Teljes útmutató: [BUILDING.md](../BUILDING.md)
(angolul).

- A `build.bat` egyetlen build-azonosítóval (`BYYMMDD-HHMMSS-XXXXXXXX`)
  készíti el a teljes kiadást (EFI-program, mikro-Linux, BIOS-mag, payload
  és `installer\USOS Installer.exe`). A `tools/zig` hordozható Zigjét
  használja; a Go-nak és a Pythonnak a `PATH`-ban kell lennie.
- A `tools/tests/run.ps1` futtatja az automatikus teszteket, pl.
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/tests/run.ps1 -Suite all`.
- A `powershell -ExecutionPolicy Bypass -File tools\release\make_release.ps1`
  a `zig-out\release-1.0\` mappában állítja elő a kiadási fájlokat.
- **Offline build:** csomagold ki a `USOS-1.0.0-buildkit.zip` fájlt, állítsd
  a `USOS_BUILDKIT` változót a kicsomagolt `USOS-1.0.0-buildkit` mappára, és
  futtasd a `build.bat` fájlt; a készletet a manifesztje alapján ellenőrzi,
  a letöltések le vannak tiltva.
- **Aláírókulcs:** a Secure Boot (MOK) kulcs **a tárolón kívül** található,
  a `%APPDATA%\USOS\signing\` mappában (a `USOS_SIGNING_DIR` felülírja).
  Nélküle a build **aláíratlan**, és csak kikapcsolt Secure Boottal indul.
  Soha ne commitold és ne oszd meg a kulcsot.

Windows ISO-k, illesztőprogramok és más külső médiák soha nem részei a
tárolónak.

<a id="licence"></a>
## 10. Licenc

- Az USOS saját kódja a **GNU General Public License 3-as vagy későbbi
  verziója** (GPL-3.0-or-later) alatt érhető el: lásd [LICENSE](../../LICENSE)
  és [NOTICE](../../NOTICE). Copyright (C) 2026 Maksymilian and the USOS Authors.
- A külső komponensek megtartják saját licencüket. Ezek a pendrive-on
  összegyűjtött, különálló programok; lásd a kiadásban a
  `THIRD-PARTY-NOTICES.txt` fájlt és a `LICENSES/` mappát, valamint a
  [LICENSES-AUDIT.md](../LICENSES-AUDIT.md) dokumentumot.
- A kiadásban lévő Microsoft-fájlokat (frissítési és illesztőprogram-fájlok,
  az XP-csomagok fájljai, a WinPE-donor) megőrzési céllal tartjuk meg, a
  karbantartó saját kockázatára terjesztjük tovább, egyetlen USOS-licenc sem
  vonatkozik rájuk, és a jogtulajdonos kérésére eltávolítjuk őket.
- A hozzájárulásokat a [CONTRIBUTING.md](../../CONTRIBUTING.md) szerint
  fogadjuk el (egyszerű licencengedély a hozzájáruló részéről).

A Windows, az MS-DOS és a kapcsolódó nevek a Microsoft védjegyei. Az USOS
nem áll kapcsolatban a Microsofttal.

<a id="support"></a>
## 11. Támogatás

- Kérdések és hibajelentések: GitHub issues. Csatold a
  [felhasználói útmutató 11. szakaszában](../USER-GUIDE.en.md#11-troubleshooting-and-logs)
  leírt naplókat, és ellenőrizd, hogy nincsenek bennük jelszavak vagy
  kulcsok.
- Fizetős telepítési segítség cégeknek kérésre elérhető; egyelőre a GitHub
  issues felületén lehet kapcsolatba lépni.
- Szponzorálás: a `.github/FUNDING.yml` révén, amint ki lesz töltve.

<a id="documentation"></a>
## 12. Dokumentáció

- Felhasználói útmutató: [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md)
- [Kiadási megjegyzések 1.0](../release-notes-1.0.md) (angolul)
- [Hogyan működik az USOS](../HOW-IT-WORKS.md)
- [Összeállítás](../BUILDING.md)
- [Licencaudit](../LICENSES-AUDIT.md)
- [Az 1.0 kiadás tesztterve](../RELEASE-TEST-1.0.md)
- [Ütemterv](../ROADMAP.md) (lengyelül) és [teszteredmények](../../TESTING.md) (lengyelül)
