# Universal Service OS (USOS) 1.0.0

> Ovo je prevod. Merodavna je [engleska verzija README-a](../../README.md).

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
Srpski (latinica) ·
[Svenska](README.sv.md) ·
[Türkçe](README.tr.md) ·
[Українська](README.uk.md)

## Sadržaj

1. [Šta je USOS](#what-usos-is)
2. [Mogućnosti](#features)
3. [Podržani sistemi i režimi firmvera](#supported-systems)
4. [Brzi početak](#quick-start)
5. [Raspored fascikli na DATA](#data-layout)
6. [Secure Boot](#secure-boot)
7. [Profili odgovora](#answer-profiles)
8. [Poznati problemi](#known-issues)
9. [Pravljenje iz izvornog koda](#building)
10. [Licenca](#licence)
11. [Podrška](#support)
12. [Dokumentacija](#documentation)

<a id="what-usos-is"></a>
## 1. Šta je USOS

USOS je jedan USB fleš za instalaciju i pokretanje operativnih sistema od
MS-DOS-a do Windowsa 11 i Linuxa na računarima sa BIOS-om i sa UEFI-jem,
uključujući UEFI sa uključenim Secure Bootom. Sopstvene ISO slike kopirate
na fleš kao obične datoteke; USOS vam daje jedan meni, izričit i zaštićen
izbor ciljnog diska i drajvere i ispravke koje stari sistemi traže na novom
hardveru. Fleš se priprema u Windowsu programom `USOS-Installer-1.0.0.exe`.
USOS ne sadrži slike Windowsa, ključeve proizvoda niti bilo šta što zaobilazi
aktivaciju.

![USOS UEFI meni, početni ekran](../images/menu-home.png)

<a id="features"></a>
## 2. Mogućnosti

- **Jedan meni za BIOS i UEFI.** Isti fleš se pokreće u režimu Legacy BIOS
  i u UEFI-ju (x64) sa istim katalogom. UEFI meni radi sa tastaturom, mišem,
  ekranom osetljivim na dodir i USB gejmpedima.
- **Slike ostaju datoteke.** ISO, WIM, IMG, VHD, VHDX i EFI slike čitaju se
  direktno sa NTFS particije DATA; ništa se ne raspakuje i posle kopiranja
  ne treba ništa pokretati.
- **Zaštićen ciljni disk.** Disk uvek sami birate i potvrđujete; sam USOS
  fleš se nikada ne nudi.
- **Secure Boot** preko shima 16.1 (potpisao ga je Microsoft) i USOS ključa
  (MOK), koji se na svakom računaru upisuje jednom.
- **Stari Windows na novom hardveru.** Windows XP sa paketom drajvera i PAE
  u UEFI-ju sa CSM-om; XP i Vista u UEFI-ju bez CSM-a preko CSMWrapa
  (eksperimentalno); Windows 7 x64 bez CSM-a preko UefiSevena i dispečera za
  usmeravanje VGA; integracija USB 3 i NVMe za Windows 7.
- **Profili odgovora** za automatske instalacije Windowsa i Linuxa, koji se
  uređuju u UEFI meniju pomoću tastature na ekranu.
- **Linux ISO slike sa DATA** (Ubuntu, Mint, Fedora, Debian, SystemRescue,
  GParted, Clonezilla i drugi) u UEFI-ju sa Secure Bootom i bez njega, kao
  i u BIOS-u.
- **Alatke:** ugrađeni FreeDOS sa menadžerom datoteka i panelom Hardware &
  SMART (BIOS), UEFI školjka iz EDK2 (UEFI), sopstvene alatke za pokretanje
  u `Utilities`, sopstveni UEFI drajveri i fascikle sa INF drajverima za
  Windows.
- **Instalacioni program sa četiri režima:** Instalacija, Lokalno ažuriranje
  (**Ažuriraj USOS**, zadržava slike i vaše datoteke), Popravka (**Popravi
  ESP**), Deinstalacija.
- **27 jezika** (referentni je engleski; ostali jezici osim poljskog označeni
  su kao delimično ili potpuno mašinski prevedeni), teme sa uređivačem
  u meniju, podrška za dodir i gejmped na ROG Allyju.

| | |
|---|---|
| ![Lista Windows sistema sa oznakama statusa](../images/windows-list.png) | ![Lista Linux distribucija](../images/linux-list.png) |
| Windows sistemi sa oznakama statusa | Linux ISO slike sa DATA |
| ![Legacy BIOS meni](../images/bios-menu.png) | ![Ugrađene i korisničke teme](../images/themes-grid.png) |
| Legacy BIOS meni | Teme: Dark, Light, Retro, Sunset |

<a id="supported-systems"></a>
## 3. Podržani sistemi i režimi firmvera

**HW** = testirano na stvarnom hardveru, **VM** = testirano samo
u QEMU-u/VirtualBoxu, **eksp.** = eksperimentalno (tako označeno u meniju),
**netestirano** = putanja postoji, ali nije zabeleženo nijedno pokretanje,
**—** = nije podržano (meni navodi razlog). Test računari: **X470** (ASRock
X470, Ryzen 7 5700X, Radeon RX 560, UEFI), **MS-7100** (MSI, Socket 939,
Athlon 64 X2, BIOS), **Ally** (ASUS ROG Ally RC71L, UEFI sa Secure Bootom).

| Sistem | BIOS (Legacy) | UEFI + CSM | UEFI bez CSM-a (CSMWrap) | Secure Boot uključen |
|---|---|---|---|---|
| Sam USOS meni | HW | HW | HW | HW (X470, Ally) |
| MS-DOS 6.22, Windows 3.1/3.11 | HW (Windows 3.1 u standardnom režimu, MS-7100) | — | — | — |
| Windows 98 SE | VM; HW delimično (MS-7100: Setup do pripreme prvog pokretanja, radna površina nije potvrđena) | — | — | — |
| Windows 2000 SP4 | HW (MS-7100) | eksp., VM (do kopiranja datoteka) | eksp., VM (CSMWrap) | — |
| Windows XP x86 SP3 | VM (bez paketa drajvera, bez PAE) | HW (X470: paket drajvera, PAE, 31,9 GB) | eksp., HW (X470, CSMWrap) | — |
| Windows XP x64 SP2 | netestirano | eksp., VM (do GUI Setupa); X470: STOP 0xA5 | eksp., VM (CSMWrap) | — |
| Windows Server 2003 R2 SP2 x86 | netestirano | eksp., VM (do GUI Setupa); X470 sa 1.0 netestirano | eksp., VM (CSMWrap) | — |
| Windows Vista SP2 x64 | HW (MS-7100) | HW (X470) | eksp., HW (X470, CSMWrap, legacy MBR) | — |
| Windows 7 SP1 x64 | HW (MS-7100) | VM (potpuna instalacija) | HW (X470, UefiSeven + dispečer) | — |
| Windows 8 / 8.1 | netestirano | netestirano | netestirano | netestirano |
| Windows 10 | HW (x86, MS-7100) | HW (x64, X470) | izvorni UEFI, ista putanja kao sa CSM-om | VM (do učitavača Windowsa) |
| Windows 11 | netestirano | HW (izveštaj korisnika) | izvorni UEFI, ista putanja kao sa CSM-om | VM (do učitavača Windowsa) |
| Windows Server 2008 - 2025 | eksp., nikada pokrenuto | eksp., nikada pokrenuto | eksp., nikada pokrenuto | 2008/2008 R2: —; 2012+: netestirano |
| Linux ISO slike (Ubuntu, Mint, Fedora, Debian, GParted, Clonezilla) | VM; HW Mint live (MS-7100) | HW (X470: Mint, Fedora, Debian netinst, Clonezilla, GParted) | isto kao sa CSM-om | HW Fedora, Mint (X470); ostalo VM |
| SystemRescue | VM | HW (X470) | isto kao sa CSM-om | — (nema potpisanog učitavača) |
| FreeDOS, Hardware & SMART (ugrađeno) | VM (FreeDOS); HW (Hardware & SMART) | — | — | — |
| MemTest86+ (ISO i586, obezbeđujete ga sami) | HW | verzija `.efi` iz `Utilities` (netestirano) | kao sa CSM-om | samo potpisan `.efi` |
| UEFI školjka (ugrađena) | — | VM | VM | VM (pokreće se, ali ne može da pokreće alatke) |

UEFI sa CSM-om ili bez njega važan je samo za starije (legacy) putanje
(2000, XP, 2003, Vista, 7); svi ostali UEFI unosi u oba režima izvršavaju
isti kod. Windows XP, Vista i 7 i svaka putanja preko CSMWrapa zahtevaju
isključen Secure Boot. Potpuna tabela sa napomenama i rezultatima na
hardveru za pojedinačne verzije nalazi se u
[korisničkom vodiču, odeljak 5](../USER-GUIDE.en.md#5-what-works-in-which-firmware-mode)
i u [napomenama uz izdanje](../release-notes-1.0.md#supported-systems)
(na engleskom).

<a id="quick-start"></a>
## 4. Brzi početak

Datoteke izdanja:

| Datoteka | Namena |
|---|---|
| `USOS-Installer-1.0.0.exe` | **Pun instalater**: ceo USOS plus WinPE donor i oba XP paketa; radi bez interneta |
| `USOS-Installer-1.0.0-online.exe` | **Onlajn instalater**: malo preuzimanje; po potrebi preuzima WinPE donor i XP pakete iz ovog izdanja i proverava ih |
| `USOS-1.0.0-WinPE-PE10-donor.zip` | PE10 donor, potreban za Vistu i originalne ISO slike Windowsa 7 u UEFI-ju |
| `USOS-1.0.0-XP-package-PL.zip`, `USOS-1.0.0-XP-package-EN.zip` | UEFI paket za Windows XP x86 SP3, svaki za tačno jednu originalnu ISO sliku (`pl_..._x14-80476.iso` / `en_..._x14-80428.iso`), instalira se priloženom skriptom `install-xp-package.ps1` |
| `USOS-1.0.0-sources.zip` + `SOURCE-OFFER.txt` | izvorni kod komponenti trećih strana i pisana ponuda izvornog koda |
| `USOS-1.0.0-buildkit.zip` | fiksirani alati i ulazi za pravljenje verzije bez mreže |
| `LICENSES/`, `THIRD-PARTY-NOTICES.txt` | tekstovi licenci i obaveštenja |
| `SHA256SUMS` | SHA-256 svake datoteke |

Preuzetu datoteku proverite komandom
`certutil -hashfile USOS-Installer-1.0.0.exe SHA256` (ili `Get-FileHash`
u PowerShellu) u odnosu na `SHA256SUMS`.

![USOS instalacioni program: izbor operacije](../images/installer-mode.png)

1. Nabavite USB fleš kapaciteta **najmanje 32 GiB** (u praksi 64 GB; fleš
   koji se prodaje kao „32 GB” obično je premali). **Sve na njemu biće
   obrisano.**
2. Na računaru sa Windowsom pokrenite `USOS-Installer-1.0.0.exe` (traži
   administratorska prava), izaberite **Instalacija**, izaberite fleš,
   upišite tekst potvrde i kliknite na **IZBRIŠI I INSTALIRAJ**.
3. Kopirajte svoje ISO slike na particiju DATA, u fasciklu `Images`
   odgovarajućeg sistema, npr. `Systems\Windows\Windows 11\Images\`.
4. Opciono: za Vistu ili originalni Windows 7 u UEFI-ju kopirajte fasciklu
   `Programs` iz arhive PE10 donora u koren DATA i pokrenite **Ažuriraj
   USOS**; za XP u UEFI-ju kao administrator pokrenite
   `install-xp-package.ps1` iz XP paketa koji odgovara vašoj ISO slici
   (uvek samo jedan paket).
5. Pokrenite ciljni računar sa fleša (BIOS ili UEFI). Uz uključen Secure
   Boot jednom upišite USOS ključ ([Secure Boot](#secure-boot)). Izaberite
   sistem i sliku, po želji profil odgovora, potvrdite ciljni disk i pratite
   instalacioni program sistema.

Uputstva korak po korak za svaki ekran nalaze se u korisničkom vodiču:
[English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md).

<a id="data-layout"></a>
## 5. Raspored fascikli na DATA

Instalacioni program na flešu pravi tri particije: `USOS_ESP` (FAT32,
1 GiB: datoteke za pokretanje, ključ, podešavanja, evidencije, profili),
`USOS_DATA` (NTFS: vaše datoteke) i `USOS_WORK` (NTFS, radni prostor za neke
instalacione programe Windowsa). Sve fascikle na DATA prave se automatski:

```
USOS_DATA\
├─ Systems\
│  ├─ Windows\<verzija>\    Images\  Unattended\   (Windows 3.1 do 11, Server 2003-2025)
│  ├─ Linux\<distribucija>\ Images\  Unattended\   (Other Linux\ za nepoznate ISO slike)
│  ├─ Betas\
│  └─ DOS\<varijanta>\      Images\
├─ Utilities\
│  ├─ FreeDOS\Programs\     DOS programi za ugrađeni FreeDOS
│  ├─ UEFI Shell\Tools\     EFI alatke za UEFI školjku
│  └─ <vaša alatka>\Images\   npr. MemTest86\Images\memtest86.efi
├─ Drivers\
│  ├─ UEFI\<naziv>\         .efi drajveri koje učitava USOS meni
│  └─ <verzija Windowsa>\   Storage\  USB\  Other\  (INF paketi)
├─ Themes\<naziv>\theme.ini sopstvene teme (UEFI meni)
└─ Programs\
   └─ USOS\                 njime upravlja USOS (PE10 donor), ne dirati
```

Posle dodavanja datoteke `icon.png` ili nove fascikle sa alatkom pokrenite
**Ažuriraj USOS**. Potpuno stablo nalazi se u
[korisničkom vodiču, odeljak 4](../USER-GUIDE.en.md#4-folder-layout-on-data).

<a id="secure-boot"></a>
## 6. Secure Boot

Uz uključen Secure Boot USOS se pokreće preko **shima 16.1** (Fedorina
verzija, potpisana sa Microsoft UEFI CA) i MokManagera. Sam USOS i njegove
komponente potpisani su **USOS ključem**, koji se upisuje **jednom na svakom
računaru**:

- **Najlakše:** isključite Secure Boot, pokrenite fleš, na početnom ekranu
  izaberite **Dodaj** i potvrdite sa **Da, sačuvaj ključ**, zatim ponovo
  uključite Secure Boot. Ovo radi i u režimu Setup Mode (potvrđeno na X470).
- **Uz Secure Boot koji ostaje uključen:** na ekranu „Verification failed”
  u MokManageru upotrebite **Enroll key from disk** -> `USOS_ESP` ->
  `USOS-KEY.cer` (potvrđeno na ROG Allyju). Opcija **Pripremi (jednom)** na
  kartici Secure Boot u instalacionom programu čini da MokManager čeka
  umesto da odbrojava.

Resetovanje NVRAM-a uklanja ključ; tada ga ponovo upišite. XP, Vista, 7,
svaka putanja preko CSMWrapa, SystemRescue i alatke pokrenute iz UEFI
školjke zahtevaju isključen Secure Boot. Kernel još nije zaključan (stavka
N6 plana razvoja), pa upisom USOS ključa verujete svemu što je njime
potpisano. Detalji:
[korisnički vodič, odeljak 6](../USER-GUIDE.en.md#6-secure-boot-and-the-usos-key-mok),
[secure-boot-usos.md](../secure-boot-usos.md).

<a id="answer-profiles"></a>
## 7. Profili odgovora

Jedan mali profil (nalozi, ime računara, jezik, vremenska zona, opciona
podešavanja) pri pokretanju se pretvara u `WINNT.SIF` (2000/XP/2003),
`autounattend.xml` (Vista do 11, Server) ili u Ubuntu autoinstall, Debian
preseed odnosno Fedora kickstart. Profili se prave u UEFI meniju
(**Automatska instalacija** -> **+ Dodaj novi profil**) i čuvaju na ESP-u.

![Uređivač profila odgovora sa odeljkom za izgled i dodatke](../images/profile-editor-appearance.png)

- Ciljni disk se **uvek bira ručno**; profil nikada ne bira niti briše
  disk.
- Ključ proizvoda čuva se samo ako označite „Zapamti ključ na ovom flešu”;
  u suprotnom važi samo do ponovnog pokretanja. **USOS ne sadrži ključeve**
  i ne zaobilazi aktivaciju niti stranicu sa ključem proizvoda.
- Lozinke i zapamćeni ključevi čuvaju se na flešu kao običan tekst (nikada
  se ne prikazuju u listama ni u evidencijama). Profili za Linux rade samo
  u UEFI-ju.

Detalji: [korisnički vodič, odeljak 7](../USER-GUIDE.en.md#7-answer-profiles-and-tweaks),
[answer-profiles.md](../answer-profiles.md).

<a id="known-issues"></a>
## 8. Poznati problemi

- **Vista na pločama samo sa USB 3 (X470):** USB fleševi nisu vidljivi
  u instaliranom sistemu, a Vista ostaje u test režimu (test-potpisan
  backport USB 3). Oba problema izbegavaju se PCIe karticom Renesas
  uPD72020x.
- **Putanje preko CSMWrapa:** zahtevaju grafičku karticu sa starijim
  (legacy) VBIOS-om (inače crn ekran), zauzimaju jednu nit CPU-a, zahtevaju
  ciljni disk MBR (briše se) i isključen Secure Boot.
- **Server 2003 x86 / XP x64:** STOP 0xA5 (ACPI) na X470 i nema USB unosa na
  pločama samo sa xHCI-jem.
- **Windows 2000** ne radi na pločama samo sa AHCI-jem (nema AHCI drajvera
  za NT 5.0); **XP** ne podržava NVMe, a u BIOS režimu ne dobija paket
  drajvera niti PAE.
- **Secure Boot:** SystemRescue je blokiran (nema potpisanog učitavača);
  UEFI školjka ne može da pokreće alatke; posle DBX ažuriranja zbog
  BlackLotusa stariji mediji Windowsa se ne pokreću.
- **Linux:** instalacioni program Ubuntu Servera unapred bira najveći disk,
  a to može biti USOS fleš; uvek proverite ciljni disk.
- **AMI firmver** prikazuje svaku particiju fleša kao zaseban unos za
  pokretanje.
- Pomoćni mikro-Linux zahteva procesor x86-64 i najmanje 256 MiB RAM-a.

Potpuna lista sa zaobilaznim rešenjima i iskrena lista onoga što na hardveru
još **nije testirano** (npr. Windows Server 2008-2025, Windows 8/8.1,
Windows 10/11 sa Secure Bootom na hardveru, originalna ISO slika Windowsa 7
SP1 preko PE10 donora) nalaze se u
[napomenama uz izdanje](../release-notes-1.0.md#known-issues) (na
engleskom) i u [korisničkom vodiču, odeljci 9 i 10](../USER-GUIDE.en.md#9-known-issues-and-workarounds).

<a id="building"></a>
## 9. Pravljenje iz izvornog koda

Pravljenje se izvodi u Windowsu. Potpuna uputstva:
[BUILDING.md](../BUILDING.md) (na engleskom).

- `build.bat` pravi celo izdanje (EFI program, mikro-Linux, BIOS jezgro,
  payload i `installer\USOS Installer.exe`) sa jednim identifikatorom
  verzije (`BYYMMDD-HHMMSS-XXXXXXXX`). Koristi se prenosivi Zig
  iz `tools/zig`; Go i Python moraju biti u `PATH`-u.
- `tools/tests/run.ps1` pokreće automatske testove, npr.
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/tests/run.ps1 -Suite all`.
- `powershell -ExecutionPolicy Bypass -File tools\release\make_release.ps1`
  pravi datoteke izdanja u `zig-out\release-1.0\`.
- **Pravljenje bez mreže:** raspakujte `USOS-1.0.0-buildkit.zip`, podesite
  `USOS_BUILDKIT` na raspakovanu fasciklu `USOS-1.0.0-buildkit` i pokrenite
  `build.bat`; komplet se proverava prema svom manifestu, a preuzimanja su
  onemogućena.
- **Ključ za potpisivanje:** ključ za Secure Boot (MOK) nalazi se **van
  repozitorijuma**, u `%APPDATA%\USOS\signing\` (promenljiva
  `USOS_SIGNING_DIR` to menja). Bez njega verzija je **nepotpisana** i
  pokreće se samo uz isključen Secure Boot. Nikada ne commitujte i ne delite
  ključ.

ISO slike Windowsa, drajveri i drugi mediji trećih strana nikada nisu deo
repozitorijuma.

<a id="licence"></a>
## 10. Licenca

- Sopstveni kod USOS-a licenciran je pod **GNU General Public License,
  verzija 3 ili novija** (GPL-3.0-or-later): pogledajte [LICENSE](../../LICENSE)
  i [NOTICE](../../NOTICE). Copyright (C) 2026 Maksymilian and the USOS Authors.
- Komponente trećih strana zadržavaju sopstvene licence. To su zasebni
  programi objedinjeni na flešu; pogledajte `THIRD-PARTY-NOTICES.txt`
  i `LICENSES/` u izdanju i [LICENSES-AUDIT.md](../LICENSES-AUDIT.md).
- Microsoftove datoteke u izdanju (datoteke ažuriranja i drajvera, datoteke
  u XP paketima, WinPE donor) čuvaju se radi očuvanja, distribuiraju se na
  sopstveni rizik održavaoca, ne pokriva ih nijedna USOS licenca i biće
  uklonjene na zahtev nosioca prava.
- Doprinosi se prihvataju prema [CONTRIBUTING.md](../../CONTRIBUTING.md)
  (jednostavno davanje licence od strane autora doprinosa).

Windows, MS-DOS i srodni nazivi su žigovi kompanije Microsoft. USOS nije
povezan sa kompanijom Microsoft.

<a id="support"></a>
## 11. Podrška

- Pitanja i prijave grešaka: GitHub Issues. Priložite evidencije opisane
  u [korisničkom vodiču, odeljak 11](../USER-GUIDE.en.md#11-troubleshooting-and-logs)
  i proverite da ne sadrže lozinke ni ključeve.
- Plaćena pomoć pri uvođenju za firme dostupna je na zahtev; za sada se
  javite preko GitHub Issues.
- Sponzorstvo: preko `.github/FUNDING.yml` kada bude popunjen.

<a id="documentation"></a>
## 12. Dokumentacija

- Korisnički vodič: [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md)
- [Napomene uz izdanje 1.0](../release-notes-1.0.md) (na engleskom)
- [Kako USOS radi](../HOW-IT-WORKS.md)
- [Pravljenje](../BUILDING.md)
- [Revizija licenci](../LICENSES-AUDIT.md)
- [Plan testiranja izdanja 1.0](../RELEASE-TEST-1.0.md)
- [Plan razvoja](../ROADMAP.md) (na poljskom) i [rezultati testova](../../TESTING.md) (na poljskom)
