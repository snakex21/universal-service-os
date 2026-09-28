# Universal Service OS (USOS) 1.0.0

> Ovo je prijevod. Mjerodavna je [engleska verzija README-a](../../README.md).

**Jezici:** [English](../../README.md) ·
[Български](README.bg.md) ·
[Čeština](README.cs.md) ·
[Dansk](README.da.md) ·
[Deutsch](README.de.md) ·
[Ελληνικά](README.el.md) ·
[Español](README.es.md) ·
[Eesti](README.et.md) ·
[Suomi](README.fi.md) ·
[Français](README.fr.md) ·
Hrvatski ·
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

## Sadržaj

1. [Što je USOS](#what-usos-is)
2. [Mogućnosti](#features)
3. [Podržani sustavi i načini rada firmvera](#supported-systems)
4. [Brzi početak](#quick-start)
5. [Raspored mapa na DATA](#data-layout)
6. [Secure Boot](#secure-boot)
7. [Profili odgovora](#answer-profiles)
8. [Poznati problemi](#known-issues)
9. [Izgradnja iz izvornog koda](#building)
10. [Licenca](#licence)
11. [Podrška](#support)
12. [Dokumentacija](#documentation)

<a id="what-usos-is"></a>
## 1. Što je USOS

USOS je jedna USB memorija za instalaciju i pokretanje operacijskih sustava
od MS-DOS-a do Windowsa 11 i Linuxa na računalima s BIOS-om i s UEFI-jem,
uključujući UEFI s uključenim Secure Bootom. Vlastite ISO slike kopirate na
memoriju kao obične datoteke; USOS vam daje jedan izbornik, izričit
i zaštićen odabir ciljnog diska te upravljačke programe i popravke koje stari
sustavi trebaju na novom hardveru. Memorija se priprema u Windowsima
programom `USOS-Installer-1.0.0.exe`. USOS ne sadrži slike Windowsa, ključeve
proizvoda ni išta što zaobilazi aktivaciju.

![USOS UEFI izbornik, početni zaslon](../images/menu-home.png)

<a id="features"></a>
## 2. Mogućnosti

- **Jedan izbornik za BIOS i UEFI.** Ista memorija pokreće se u načinu
  Legacy BIOS i u UEFI-ju (x64) s istim katalogom. UEFI izbornik radi
  s tipkovnicom, mišem, zaslonom osjetljivim na dodir i USB gamepadima.
- **Slike ostaju datoteke.** ISO, WIM, IMG, VHD, VHDX i EFI slike čitaju se
  izravno s NTFS particije DATA; ništa se ne raspakirava i nakon kopiranja
  ne treba ništa pokretati.
- **Zaštićen ciljni disk.** Disk uvijek sami odabirete i potvrđujete; sama
  USOS memorija nikad se ne nudi.
- **Secure Boot** putem shima 16.1 (potpisao ga je Microsoft) i USOS ključa
  (MOK), koji se na svakom računalu upisuje jednom.
- **Stari Windowsi na novom hardveru.** Windows XP s paketom upravljačkih
  programa i PAE-om u UEFI-ju s CSM-om; XP i Vista u UEFI-ju bez CSM-a putem
  CSMWrapa (eksperimentalno); Windows 7 x64 bez CSM-a putem UefiSevena
  i dispečera za usmjeravanje VGA-a; integracija USB 3 i NVMe za Windows 7.
- **Profili odgovora** za automatske instalacije Windowsa i Linuxa, koji se
  uređuju u UEFI izborniku zaslonskom tipkovnicom.
- **Linux ISO slike s DATA** (Ubuntu, Mint, Fedora, Debian, SystemRescue,
  GParted, Clonezilla i drugi) u UEFI-ju sa Secure Bootom i bez njega te
  u BIOS-u.
- **Alati:** ugrađeni FreeDOS s upraviteljem datoteka i pločom Hardware &
  SMART (BIOS), UEFI ljuska iz EDK2 (UEFI), vlastiti alati za pokretanje
  u `Utilities`, vlastiti UEFI upravljački programi i mape s INF
  upravljačkim programima za Windows.
- **Instalacijski program s četiri načina rada:** Instalacija, Lokalno
  ažuriranje (**Ažuriraj USOS**, zadržava slike i vaše datoteke), Popravak
  (**Popravi ESP**), Deinstalacija.
- **27 jezika** (referentni je engleski; ostali jezici osim poljskog označeni
  su kao djelomično ili u potpunosti strojno prevedeni), teme s uređivačem
  u izborniku, podrška za dodir i gamepad na ROG Allyju.

| | |
|---|---|
| ![Popis sustava Windows s oznakama statusa](../images/windows-list.png) | ![Popis Linux distribucija](../images/linux-list.png) |
| Sustavi Windows s oznakama statusa | Linux ISO slike s DATA |
| ![Izbornik Legacy BIOS](../images/bios-menu.png) | ![Ugrađene i korisničke teme](../images/themes-grid.png) |
| Izbornik Legacy BIOS | Teme: Dark, Light, Retro, Sunset |

<a id="supported-systems"></a>
## 3. Podržani sustavi i načini rada firmvera

**HW** = testirano na stvarnom hardveru, **VM** = testirano samo
u QEMU-u/VirtualBoxu, **eksp.** = eksperimentalno (tako označeno
u izborniku), **netestirano** = put postoji, ali nije zabilježeno nijedno
pokretanje, **—** = nije podržano (izbornik navodi razlog). Testna računala:
**X470** (ASRock X470, Ryzen 7 5700X, Radeon RX 560, UEFI), **MS-7100**
(MSI, Socket 939, Athlon 64 X2, BIOS), **Ally** (ASUS ROG Ally RC71L, UEFI
sa Secure Bootom).

| Sustav | BIOS (Legacy) | UEFI + CSM | UEFI bez CSM-a (CSMWrap) | Secure Boot uključen |
|---|---|---|---|---|
| Sam USOS izbornik | HW | HW | HW | HW (X470, Ally) |
| MS-DOS 6.22, Windows 3.1/3.11 | HW (Windows 3.1 u standardnom načinu, MS-7100) | — | — | — |
| Windows 98 SE | VM; HW djelomično (MS-7100: Setup do pripreme prvog pokretanja, radna površina nije potvrđena) | — | — | — |
| Windows 2000 SP4 | HW (MS-7100) | eksp., VM (do kopiranja datoteka) | eksp., VM (CSMWrap) | — |
| Windows XP x86 SP3 | VM (bez paketa upravljačkih programa, bez PAE-a) | HW (X470: paket upravljačkih programa, PAE, 31,9 GB) | eksp., HW (X470, CSMWrap) | — |
| Windows XP x64 SP2 | netestirano | eksp., VM (do GUI Setupa); X470: STOP 0xA5 | eksp., VM (CSMWrap) | — |
| Windows Server 2003 R2 SP2 x86 | netestirano | eksp., VM (do GUI Setupa); X470 s 1.0 netestirano | eksp., VM (CSMWrap) | — |
| Windows Vista SP2 x64 | HW (MS-7100) | HW (X470) | eksp., HW (X470, CSMWrap, legacy MBR) | — |
| Windows 7 SP1 x64 | HW (MS-7100) | VM (potpuna instalacija) | HW (X470, UefiSeven + dispečer) | — |
| Windows 8 / 8.1 | netestirano | netestirano | netestirano | netestirano |
| Windows 10 | HW (x86, MS-7100) | HW (x64, X470) | izvorni UEFI, isti put kao s CSM-om | VM (do učitavača Windowsa) |
| Windows 11 | netestirano | HW (izvješće korisnika) | izvorni UEFI, isti put kao s CSM-om | VM (do učitavača Windowsa) |
| Windows Server 2008 - 2025 | eksp., nikad pokrenuto | eksp., nikad pokrenuto | eksp., nikad pokrenuto | 2008/2008 R2: —; 2012+: netestirano |
| Linux ISO slike (Ubuntu, Mint, Fedora, Debian, GParted, Clonezilla) | VM; HW Mint live (MS-7100) | HW (X470: Mint, Fedora, Debian netinst, Clonezilla, GParted) | isto kao s CSM-om | HW Fedora, Mint (X470); ostalo VM |
| SystemRescue | VM | HW (X470) | isto kao s CSM-om | — (nema potpisanog učitavača) |
| FreeDOS, Hardware & SMART (ugrađeno) | VM (FreeDOS); HW (Hardware & SMART) | — | — | — |
| MemTest86+ (ISO i586, osiguravate ga sami) | HW | inačica `.efi` iz `Utilities` (netestirano) | kao s CSM-om | samo potpisan `.efi` |
| UEFI ljuska (ugrađena) | — | VM | VM | VM (pokreće se, ali ne može pokretati alate) |

UEFI s CSM-om ili bez njega važan je samo za starije (legacy) putove (2000,
XP, 2003, Vista, 7); svi ostali UEFI unosi u oba načina izvode isti kod.
Windows XP, Vista i 7 te svaki put preko CSMWrapa zahtijevaju isključen
Secure Boot. Potpuna tablica s napomenama i rezultatima na hardveru za
pojedine izgradnje nalazi se u
[korisničkom priručniku, poglavlje 5](../USER-GUIDE.en.md#5-what-works-in-which-firmware-mode)
i u [bilješkama o izdanju](../release-notes-1.0.md#supported-systems)
(na engleskom).

<a id="quick-start"></a>
## 4. Brzi početak

Datoteke izdanja:

| Datoteka | Namjena |
|---|---|
| `USOS-Installer-1.0.0.exe` | instalacijski program; sadrži cijeli USOS |
| `USOS-1.0.0-WinPE-PE10-donor.zip` | PE10 donor, potreban za Vistu i izvorne ISO slike Windowsa 7 u UEFI-ju |
| `USOS-1.0.0-XP-package-PL.zip`, `USOS-1.0.0-XP-package-EN.zip` | UEFI paket za Windows XP x86 SP3, svaki za točno jednu izvornu ISO sliku (`pl_..._x14-80476.iso` / `en_..._x14-80428.iso`), instalira se priloženom skriptom `install-xp-package.ps1` |
| `USOS-1.0.0-sources.zip` + `SOURCE-OFFER.txt` | izvorni kod komponenti trećih strana i pisana ponuda izvornog koda |
| `USOS-1.0.0-buildkit.zip` | fiksirani alati i ulazi izgradnje za izgradnju bez mreže |
| `LICENSES/`, `THIRD-PARTY-NOTICES.txt` | tekstovi licenci i obavijesti |
| `SHA256SUMS` | SHA-256 svake datoteke |

Preuzetu datoteku provjerite naredbom
`certutil -hashfile USOS-Installer-1.0.0.exe SHA256` (ili `Get-FileHash`
u PowerShellu) u odnosu na `SHA256SUMS`.

![USOS instalacijski program: odabir operacije](../images/installer-mode.png)

1. Nabavite USB memoriju kapaciteta **najmanje 32 GiB** (u praksi 64 GB;
   memorija koja se prodaje kao „32 GB“ obično je premala). **Sve na njoj
   bit će izbrisano.**
2. Na računalu sa sustavom Windows pokrenite `USOS-Installer-1.0.0.exe`
   (traži administratorska prava), odaberite **Instalacija**, odaberite
   memoriju, upišite tekst potvrde i kliknite **IZBRIŠI I INSTALIRAJ**.
3. Kopirajte svoje ISO slike na particiju DATA, u mapu `Images` odgovarajućeg
   sustava, npr. `Systems\Windows\Windows 11\Images\`.
4. Po želji: za Vistu ili izvorni Windows 7 u UEFI-ju kopirajte mapu
   `Programs` iz arhive PE10 donora u korijen DATA i pokrenite **Ažuriraj
   USOS**; za XP u UEFI-ju kao administrator pokrenite
   `install-xp-package.ps1` iz XP paketa koji odgovara vašoj ISO slici (uvijek
   samo jedan paket).
5. Pokrenite ciljno računalo s memorije (BIOS ili UEFI). Uz uključen Secure
   Boot jednom upišite USOS ključ ([Secure Boot](#secure-boot)). Odaberite
   sustav i sliku, po želji profil odgovora, potvrdite ciljni disk i slijedite
   instalacijski program sustava.

Upute korak po korak za svaki zaslon nalaze se u korisničkom priručniku:
[English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md).

<a id="data-layout"></a>
## 5. Raspored mapa na DATA

Instalacijski program na memoriji stvara tri particije: `USOS_ESP` (FAT32,
1 GiB: datoteke za pokretanje, ključ, postavke, zapisnici, profili),
`USOS_DATA` (NTFS: vaše datoteke) i `USOS_WORK` (NTFS, radni prostor za neke
instalacijske programe Windowsa). Sve mape na DATA stvaraju se automatski:

```
USOS_DATA\
├─ Systems\
│  ├─ Windows\<verzija>\    Images\  Unattended\   (Windows 3.1 do 11, Server 2003-2025)
│  ├─ Linux\<distribucija>\ Images\  Unattended\   (Other Linux\ za nepoznate ISO slike)
│  ├─ Betas\
│  └─ DOS\<inačica>\        Images\
├─ Utilities\
│  ├─ FreeDOS\Programs\     DOS programi za ugrađeni FreeDOS
│  ├─ UEFI Shell\Tools\     EFI alati za UEFI ljusku
│  └─ <vaš alat>\Images\    npr. MemTest86\Images\memtest86.efi
├─ Drivers\
│  ├─ UEFI\<naziv>\         .efi upravljački programi koje učitava USOS izbornik
│  └─ <verzija Windowsa>\   Storage\  USB\  Other\  (INF paketi)
├─ Themes\<naziv>\theme.ini vlastite teme (UEFI izbornik)
└─ Programs\
   └─ USOS\                 njime upravlja USOS (PE10 donor), ne dirati
```

Nakon dodavanja datoteke `icon.png` ili nove mape s alatom pokrenite
**Ažuriraj USOS**. Potpuno stablo nalazi se u
[korisničkom priručniku, poglavlje 4](../USER-GUIDE.en.md#4-folder-layout-on-data).

<a id="secure-boot"></a>
## 6. Secure Boot

Uz uključen Secure Boot USOS se pokreće putem **shima 16.1** (Fedorina
izgradnja, potpisana s Microsoft UEFI CA) i MokManagera. Sam USOS i njegove
komponente potpisani su **USOS ključem**, koji se upisuje **jednom na svakom
računalu**:

- **Najjednostavnije:** isključite Secure Boot, pokrenite memoriju, na
  početnom zaslonu odaberite **Dodaj** i potvrdite s **Da, spremi ključ**,
  zatim ponovno uključite Secure Boot. To radi i u načinu Setup Mode
  (potvrđeno na X470).
- **Uz Secure Boot koji ostaje uključen:** na zaslonu „Verification failed“
  u MokManageru upotrijebite **Enroll key from disk** -> `USOS_ESP` ->
  `USOS-KEY.cer` (potvrđeno na ROG Allyju). Opcija **Pripremi
  (jednokratno)** na kartici Secure Boot u instalacijskom programu čini da
  MokManager čeka umjesto da odbrojava.

Resetiranje NVRAM-a uklanja ključ; tada ga ponovno upišite. XP, Vista, 7,
svaki put preko CSMWrapa, SystemRescue i alati pokrenuti iz UEFI ljuske
zahtijevaju isključen Secure Boot. Jezgra još nije zaključana (stavka N6
plana razvoja), pa upisom USOS ključa vjerujete svemu što je njime
potpisano. Pojedinosti:
[korisnički priručnik, poglavlje 6](../USER-GUIDE.en.md#6-secure-boot-and-the-usos-key-mok),
[secure-boot-usos.md](../secure-boot-usos.md).

<a id="answer-profiles"></a>
## 7. Profili odgovora

Jedan mali profil (računi, naziv računala, jezik, vremenska zona, izborne
prilagodbe) pri pokretanju se pretvara u `WINNT.SIF` (2000/XP/2003),
`autounattend.xml` (Vista do 11, Server) ili u Ubuntu autoinstall, Debian
preseed odnosno Fedora kickstart. Profili se stvaraju u UEFI izborniku
(**Automatska instalacija** -> **+ Dodaj novi profil**) i spremaju na ESP.

![Uređivač profila odgovora s odjeljkom za izgled i dodatke](../images/profile-editor-appearance.png)

- Ciljni disk **uvijek se odabire ručno**; profil nikad ne odabire ni ne
  briše disk.
- Ključ proizvoda sprema se samo ako označite „Zapamti ključ na ovoj USB
  memoriji“; inače vrijedi samo do ponovnog pokretanja. **USOS ne sadrži
  ključeve** i ne zaobilazi aktivaciju ni stranicu s ključem proizvoda.
- Lozinke i zapamćeni ključevi spremaju se na memoriju kao običan tekst
  (nikad se ne prikazuju u popisima ni u zapisnicima). Profili za Linux rade
  samo u UEFI-ju.

Pojedinosti: [korisnički priručnik, poglavlje 7](../USER-GUIDE.en.md#7-answer-profiles-and-tweaks),
[answer-profiles.md](../answer-profiles.md).

<a id="known-issues"></a>
## 8. Poznati problemi

- **Vista na pločama samo s USB 3 (X470):** USB memorije nisu vidljive
  u instaliranom sustavu, a Vista ostaje u testnom načinu (testno potpisan
  backport USB 3). Oba problema izbjegavaju se PCIe karticom Renesas
  uPD72020x.
- **Putovi preko CSMWrapa:** trebaju grafičku karticu sa starijim (legacy)
  VBIOS-om (inače crni zaslon), zauzimaju jednu dretvu CPU-a, trebaju ciljni
  disk MBR (briše se) i isključen Secure Boot.
- **Server 2003 x86 / XP x64:** STOP 0xA5 (ACPI) na X470 i nema USB unosa na
  pločama samo s xHCI-jem.
- **Windows 2000** ne radi na pločama samo s AHCI-jem (nema AHCI
  upravljačkog programa za NT 5.0); **XP** ne podržava NVMe, a u načinu BIOS
  ne dobiva paket upravljačkih programa ni PAE.
- **Secure Boot:** SystemRescue je blokiran (nema potpisanog učitavača); UEFI
  ljuska ne može pokretati alate; nakon DBX ažuriranja zbog BlackLotusa
  stariji mediji Windowsa se ne pokreću.
- **Linux:** instalacijski program Ubuntu Servera unaprijed odabire najveći
  disk, a to može biti USOS memorija; uvijek provjerite ciljni disk.
- **AMI firmver** prikazuje svaku particiju memorije kao zaseban unos za
  pokretanje.
- Pomoćni mikro-Linux treba procesor x86-64 i najmanje 256 MiB RAM-a.

Potpun popis sa zaobilaznim rješenjima i iskren popis onoga što na hardveru
još **nije testirano** (npr. Windows Server 2008-2025, Windows 8/8.1,
Windows 10/11 sa Secure Bootom na hardveru, izvorna ISO slika Windowsa 7 SP1
preko PE10 donora) nalaze se u
[bilješkama o izdanju](../release-notes-1.0.md#known-issues) (na engleskom)
i u [korisničkom priručniku, poglavlja 9 i 10](../USER-GUIDE.en.md#9-known-issues-and-workarounds).

<a id="building"></a>
## 9. Izgradnja iz izvornog koda

Izgradnja se izvodi u Windowsima. Potpune upute:
[BUILDING.md](../BUILDING.md) (na engleskom).

- `build.bat` gradi cijelo izdanje (EFI program, mikro-Linux, BIOS jezgru,
  payload i `installer\USOS Installer.exe`) s jednim identifikatorom
  izgradnje (`BYYMMDD-HHMMSS-XXXXXXXX`). Koristi se prijenosni Zig
  iz `tools/zig`; Go i Python moraju biti u `PATH`-u.
- `tools/tests/run.ps1` pokreće automatske testove, npr.
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/tests/run.ps1 -Suite all`.
- `powershell -ExecutionPolicy Bypass -File tools\release\make_release.ps1`
  stvara datoteke izdanja u `zig-out\release-1.0\`.
- **Izgradnja bez mreže:** raspakirajte `USOS-1.0.0-buildkit.zip`, postavite
  `USOS_BUILDKIT` na raspakiranu mapu `USOS-1.0.0-buildkit` i pokrenite
  `build.bat`; komplet se provjerava prema svojem manifestu, a preuzimanja su
  onemogućena.
- **Ključ za potpisivanje:** ključ za Secure Boot (MOK) nalazi se **izvan
  repozitorija**, u `%APPDATA%\USOS\signing\` (varijabla `USOS_SIGNING_DIR`
  to nadjačava). Bez njega izgradnja je **nepotpisana** i pokreće se samo uz
  isključen Secure Boot. Nikad ne commitajte i ne dijelite ključ.

ISO slike Windowsa, upravljački programi i drugi mediji trećih strana nikad
nisu dio repozitorija.

<a id="licence"></a>
## 10. Licenca

- Vlastiti kod USOS-a licenciran je pod **GNU General Public License,
  verzija 3 ili novija** (GPL-3.0-or-later): pogledajte [LICENSE](../../LICENSE)
  i [NOTICE](../../NOTICE). Copyright (C) 2026 The USOS Authors.
- Komponente trećih strana zadržavaju vlastite licence. To su zasebni
  programi skupljeni na memoriji; pogledajte `THIRD-PARTY-NOTICES.txt`
  i `LICENSES/` u izdanju te [LICENSES-AUDIT.md](../LICENSES-AUDIT.md).
- Microsoftove datoteke u izdanju (datoteke ažuriranja i upravljačkih
  programa, datoteke u XP paketima, WinPE donor) čuvaju se radi očuvanja,
  distribuiraju se na vlastiti rizik održavatelja, ne pokriva ih nijedna
  USOS licenca i bit će uklonjene na zahtjev nositelja prava.
- Doprinosi se primaju prema [CONTRIBUTING.md](../../CONTRIBUTING.md)
  (jednostavno davanje licence od strane autora doprinosa).

Windows, MS-DOS i povezani nazivi zaštitni su znakovi tvrtke Microsoft. USOS
nije povezan s tvrtkom Microsoft.

<a id="support"></a>
## 11. Podrška

- Pitanja i prijave pogrešaka: GitHub Issues. Priložite zapisnike opisane
  u [korisničkom priručniku, poglavlje 11](../USER-GUIDE.en.md#11-troubleshooting-and-logs)
  i provjerite da ne sadrže lozinke ni ključeve.
- Plaćena pomoć pri uvođenju za tvrtke dostupna je na zahtjev; zasad se
  javite putem GitHub Issues.
- Sponzoriranje: putem `.github/FUNDING.yml` kad bude popunjen.

<a id="documentation"></a>
## 12. Dokumentacija

- Korisnički priručnik: [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md)
- [Bilješke o izdanju 1.0](../release-notes-1.0.md) (na engleskom)
- [Kako USOS radi](../HOW-IT-WORKS.md)
- [Izgradnja](../BUILDING.md)
- [Revizija licenci](../LICENSES-AUDIT.md)
- [Plan testiranja izdanja 1.0](../RELEASE-TEST-1.0.md)
- [Plan razvoja](../ROADMAP.md) (na poljskom) i [rezultati testova](../../TESTING.md) (na poljskom)
