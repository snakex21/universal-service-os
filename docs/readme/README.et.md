# Universal Service OS (USOS) 1.0.0

> See on tõlge. Siduv on [ingliskeelne README](../../README.md).

**Keeled:** [English](../../README.md) ·
[Български](README.bg.md) ·
[Čeština](README.cs.md) ·
[Dansk](README.da.md) ·
[Deutsch](README.de.md) ·
[Ελληνικά](README.el.md) ·
[Español](README.es.md) ·
Eesti ·
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

## Sisukord

1. [Mis on USOS](#what-usos-is)
2. [Võimalused](#features)
3. [Toetatud süsteemid ja püsivara režiimid](#supported-systems)
4. [Kiire algus](#quick-start)
5. [DATA kaustade struktuur](#data-layout)
6. [Secure Boot](#secure-boot)
7. [Vastuseprofiilid](#answer-profiles)
8. [Teadaolevad probleemid](#known-issues)
9. [Lähtekoodist ehitamine](#building)
10. [Litsents](#licence)
11. [Tugi](#support)
12. [Dokumentatsioon](#documentation)

<a id="what-usos-is"></a>
## 1. Mis on USOS

USOS on üks USB-mälupulk operatsioonisüsteemide installimiseks ja
käivitamiseks, alates MS-DOS-ist kuni Windows 11 ja Linuxini, BIOS- ja
UEFI-arvutitel, sealhulgas Secure Bootiga UEFI-l. Oma ISO-tõmmised kopeerid
pulgale nagu tavalised failid; USOS annab sulle ühe menüü, sihtketta selge
ja kaitstud valiku ning draiverid ja parandused, mida vanad süsteemid uuel
riistvaral vajavad. Pulk valmistatakse ette Windowsis programmiga
`USOS-Installer-1.0.0.exe`. USOS ei sisalda Windowsi tõmmiseid,
tootevõtmeid ega aktiveerimise möödahiilimist.

![USOS-i UEFI-menüü, avaekraan](../images/menu-home.png)

<a id="features"></a>
## 2. Võimalused

- **Üks menüü, BIOS ja UEFI.** Sama pulk käivitub nii Legacy BIOS-is kui ka
  UEFI-s (x64) sama kataloogiga. UEFI-menüü töötab klaviatuuri, hiire,
  puuteekraani ja USB-mängupultidega.
- **Tõmmised jäävad failideks.** ISO-, WIM-, IMG-, VHD-, VHDX- ja
  EFI-tõmmiseid loetakse otse NTFS DATA partitsioonilt; midagi ei pakita
  lahti ja pärast kopeerimist ei pea midagi käivitama.
- **Kaitstud sihtketas.** Ketta valid ja kinnitad alati ise; USOS-i pulka
  ennast ei pakuta kunagi.
- **Secure Boot** läbi shim 16.1 (Microsofti allkirjastatud) ja USOS-i
  võtme (MOK), mis registreeritakse igas arvutis üks kord.
- **Vana Windows uuel riistvaral.** Windows XP draiveripaketi ja PAE-ga
  UEFI-l koos CSM-iga; XP ja Vista UEFI-l ilma CSM-ita läbi CSMWrapi
  (eksperimentaalne); Windows 7 x64 ilma CSM-ita läbi UefiSeveni ja
  VGA-suunava dispetšeri; USB 3 ja NVMe integratsioon Windows 7 jaoks.
- **Vastuseprofiilid** Windowsi ja Linuxi järelevalveta installimiseks,
  muudetavad UEFI-menüüs ekraaniklaviatuuriga.
- **Linuxi ISO-d DATA-lt** (Ubuntu, Mint, Fedora, Debian, SystemRescue,
  GParted, Clonezilla ja teised) UEFI-l Secure Bootiga ja ilma ning
  BIOS-il.
- **Tööriistad:** sisseehitatud FreeDOS failihalduri ja Hardware & SMART
  paneeliga (BIOS), EDK2 UEFI Shell (UEFI), sinu enda käivitatavad
  tööriistad kaustas `Utilities`, sinu enda UEFI-draiverid ja Windowsi
  INF-draiverite kaustad.
- **Installer nelja režiimiga:** Installimine, Kohalik värskendus
  (**Värskenda USOS-i**, säilitab tõmmised ja sinu failid), Parandus
  (**Paranda ESP**), Desinstallimine.
- **27 keelt** (etaloniks on inglise keel; ülejäänud keeled peale poola
  keele on märgitud osaliselt või täielikult masintõlgituks), teemad koos
  menüüsisese redaktoriga, puute- ja mängupuldi tugi ROG Allyl.

| | |
|---|---|
| ![Windowsi süsteemide loend olekumärkidega](../images/windows-list.png) | ![Linuxi distributsioonide loend](../images/linux-list.png) |
| Windowsi süsteemid olekumärkidega | Linuxi ISO-d DATA-lt |
| ![Legacy BIOS-i menüü](../images/bios-menu.png) | ![Sisseehitatud ja kasutaja teemad](../images/themes-grid.png) |
| Legacy BIOS-i menüü | Teemad: Dark, Light, Retro, Sunset |

<a id="supported-systems"></a>
## 3. Toetatud süsteemid ja püsivara režiimid

**HW** = testitud päris riistvaral, **VM** = testitud ainult
QEMU/VirtualBoxis, **eksp.** = eksperimentaalne (menüüs nii märgitud),
**testimata** = tee on olemas, kuid ühtegi käivitust pole kirja pandud,
**—** = pole toetatud (menüü näitab põhjust). Testarvutid: **X470** (ASRock
X470, Ryzen 7 5700X, Radeon RX 560, UEFI), **MS-7100** (MSI, Socket 939,
Athlon 64 X2, BIOS), **Ally** (ASUS ROG Ally RC71L, UEFI Secure Bootiga).

| Süsteem | BIOS (Legacy) | UEFI + CSM | UEFI ilma CSM-ita (CSMWrap) | Secure Boot sees |
|---|---|---|---|---|
| USOS-i menüü ise | HW | HW | HW | HW (X470, Ally) |
| MS-DOS 6.22, Windows 3.1/3.11 | HW (Windows 3.1 standardrežiimis, MS-7100) | — | — | — |
| Windows 98 SE | VM; HW osaliselt (MS-7100: Setup kuni esimese käivituse ettevalmistuseni, töölaud kinnitamata) | — | — | — |
| Windows 2000 SP4 | HW (MS-7100) | eksp., VM (kuni failide kopeerimiseni) | eksp., VM (CSMWrap) | — |
| Windows XP x86 SP3 | VM (ilma draiveripaketi ja PAE-ta) | HW (X470: draiveripakett, PAE, 31,9 GB) | eksp., HW (X470, CSMWrap) | — |
| Windows XP x64 SP2 | testimata | eksp., VM (kuni GUI Setupini); X470: STOP 0xA5 | eksp., VM (CSMWrap) | — |
| Windows Server 2003 R2 SP2 x86 | testimata | eksp., VM (kuni GUI Setupini); X470 versiooniga 1.0 testimata | eksp., VM (CSMWrap) | — |
| Windows Vista SP2 x64 | HW (MS-7100) | HW (X470) | eksp., HW (X470, CSMWrap, legacy MBR) | — |
| Windows 7 SP1 x64 | HW (MS-7100) | VM (täielik install) | HW (X470, UefiSeven + dispetšer) | — |
| Windows 8 / 8.1 | testimata | testimata | testimata | testimata |
| Windows 10 | HW (x86, MS-7100) | HW (x64, X470) | natiivne UEFI, sama tee mis CSM-iga | VM (kuni Windowsi laadurini) |
| Windows 11 | testimata | HW (kasutaja teade) | natiivne UEFI, sama tee mis CSM-iga | VM (kuni Windowsi laadurini) |
| Windows Server 2008 - 2025 | eksp., pole kunagi käivitatud | eksp., pole kunagi käivitatud | eksp., pole kunagi käivitatud | 2008/2008 R2: —; 2012+: testimata |
| Linuxi ISO-d (Ubuntu, Mint, Fedora, Debian, GParted, Clonezilla) | VM; HW Mint live (MS-7100) | HW (X470: Mint, Fedora, Debian netinst, Clonezilla, GParted) | sama mis CSM-iga | HW Fedora, Mint (X470); ülejäänud VM |
| SystemRescue | VM | HW (X470) | sama mis CSM-iga | — (allkirjastatud alglaadurit pole) |
| FreeDOS, Hardware & SMART (sisseehitatud) | VM (FreeDOS); HW (Hardware & SMART) | — | — | — |
| MemTest86+ (i586 ISO, annad ise) | HW | `.efi` versioon kaustast `Utilities` (testimata) | nagu CSM-iga | ainult allkirjastatud `.efi` |
| UEFI Shell (sisseehitatud) | — | VM | VM | VM (käivitub, kuid ei saa tööriistu käivitada) |

See, kas UEFI töötab CSM-iga või ilma, on oluline ainult legacy-teede
jaoks (2000, XP, 2003, Vista, 7); kõik muud UEFI-kirjed käitavad mõlemas
režiimis sama koodi. Windows XP, Vista ja 7 ning kõik CSMWrapi teed
vajavad väljalülitatud Secure Booti. Täielik tabel märkuste ja
buildipõhiste riistvaratulemustega on
[kasutusjuhendi 5. jaotises](../USER-GUIDE.en.md#5-what-works-in-which-firmware-mode)
ja [väljalaskemärkmetes](../release-notes-1.0.md#supported-systems)
(inglise keeles).

<a id="quick-start"></a>
## 4. Kiire algus

Väljalaske failid:

| Fail | Otstarve |
|---|---|
| `USOS-Installer-1.0.0.exe` | installer; sisaldab kogu USOS-i |
| `USOS-1.0.0-WinPE-PE10-donor.zip` | PE10 doonor, vajalik Vista ja Windows 7 originaal-ISO-de jaoks UEFI-l |
| `USOS-1.0.0-XP-package-PL.zip`, `USOS-1.0.0-XP-package-EN.zip` | Windows XP x86 SP3 UEFI-pakett, kumbki täpselt ühele originaal-ISO-le (`pl_..._x14-80476.iso` / `en_..._x14-80428.iso`), installitakse kaasasoleva skriptiga `install-xp-package.ps1` |
| `USOS-1.0.0-sources.zip` + `SOURCE-OFFER.txt` | kolmandate osapoolte komponentide lähtekood ja kirjalik lähtekoodi pakkumine |
| `USOS-1.0.0-buildkit.zip` | lukustatud versioonidega tööriistaahelad ja ehitussisendid võrguühenduseta taasehituseks |
| `LICENSES/`, `THIRD-PARTY-NOTICES.txt` | litsentsitekstid ja teatised |
| `SHA256SUMS` | iga faili SHA-256 |

Kontrolli allalaaditud faili käsuga
`certutil -hashfile USOS-Installer-1.0.0.exe SHA256` (või PowerShellis
`Get-FileHash`) ja võrdle tulemust failiga `SHA256SUMS`.

![USOS-i installer: toimingu valimine](../images/installer-mode.png)

1. Hangi USB-pulk mahuga **vähemalt 32 GiB** (praktikas 64 GB; „32 GB“
   pulgana müüdud pulk on tavaliselt liiga väike). **Kõik sellel olev
   kustutatakse.**
2. Käivita Windowsi arvutis `USOS-Installer-1.0.0.exe` (see küsib
   administraatoriõigusi), vali **Installimine**, vali pulk, sisesta
   kinnitustekst ja klõpsa **KUSTUTA JA INSTALLI**.
3. Kopeeri oma ISO-tõmmised DATA partitsioonile vastava süsteemi kausta
   `Images`, nt `Systems\Windows\Windows 11\Images\`.
4. Valikuline: Vista või Windows 7 originaali jaoks UEFI-l kopeeri PE10
   doonori zip-failist kaust `Programs` DATA juurkausta ja käivita
   **Värskenda USOS-i**; XP jaoks UEFI-l käivita administraatorina oma
   ISO-le vastava XP-paketi skript `install-xp-package.ps1` (korraga ainult
   üks pakett).
5. Käivita sihtarvuti pulgalt (BIOS või UEFI). Kui Secure Boot on sees,
   registreeri USOS-i võti üks kord ([Secure Boot](#secure-boot)). Vali
   süsteem ja tõmmis, soovi korral vastuseprofiil, kinnita sihtketas ja
   järgi süsteemi installerit.

Iga ekraani samm-sammulised juhised on kasutusjuhendis:
[English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md).

<a id="data-layout"></a>
## 5. DATA kaustade struktuur

Installer loob pulgale kolm partitsiooni: `USOS_ESP` (FAT32, 1 GiB:
alglaadimisfailid, võti, sätted, logid, profiilid), `USOS_DATA` (NTFS: sinu
failid) ja `USOS_WORK` (NTFS, tööruum mõnele Windowsi installerile). Kõik
DATA kaustad luuakse sinu eest:

```
USOS_DATA\
├─ Systems\
│  ├─ Windows\<versioon>\   Images\  Unattended\   (Windows 3.1 kuni 11, Server 2003-2025)
│  ├─ Linux\<distributsioon>\ Images\  Unattended\   (Other Linux\ tundmatute ISO-de jaoks)
│  ├─ Betas\
│  └─ DOS\<variant>\        Images\
├─ Utilities\
│  ├─ FreeDOS\Programs\     DOS-programmid sisseehitatud FreeDOS-i jaoks
│  ├─ UEFI Shell\Tools\     EFI-tööriistad UEFI Shelli jaoks
│  └─ <sinu tööriist>\Images\   nt MemTest86\Images\memtest86.efi
├─ Drivers\
│  ├─ UEFI\<nimi>\          USOS-i menüü laaditavad .efi-draiverid
│  └─ <Windowsi versioon>\  Storage\  USB\  Other\  (INF-paketid)
├─ Themes\<nimi>\theme.ini  sinu enda teemad (UEFI-menüü)
└─ Programs\
   └─ USOS\                 haldab USOS (PE10 doonor), ära puutu
```

Pärast faili `icon.png` või uue tööriistakausta lisamist käivita
**Värskenda USOS-i**. Täielik puu on
[kasutusjuhendi 4. jaotises](../USER-GUIDE.en.md#4-folder-layout-on-data).

<a id="secure-boot"></a>
## 6. Secure Boot

Kui Secure Boot on sees, käivitub USOS läbi **shim 16.1** (Fedora build,
allkirjastatud Microsoft UEFI CA poolt) ja MokManageri. USOS ise ja selle
komponendid on allkirjastatud **USOS-i võtmega**, mis registreeritakse
**igas arvutis üks kord**:

- **Lihtsaim:** lülita Secure Boot välja, käivita pulk, vali avaekraanil
  **Lisa** ja kinnita nupuga **Jah, salvesta võti**, seejärel lülita Secure
  Boot uuesti sisse. See töötab ka Setup Mode'is (kinnitatud X470-l).
- **Kui Secure Boot jääb sisse:** teate „Verification failed“ korral kasuta
  MokManageris **Enroll key from disk** -> `USOS_ESP` -> `USOS-KEY.cer`
  (kinnitatud ROG Allyl). Installeri kaart **Valmista ette (üks kord)**
  paneb MokManageri ootama, selle asemel et aega maha lugeda.

NVRAM-i lähtestamine eemaldab võtme; registreeri see uuesti. XP, Vista, 7,
kõik CSMWrapi teed, SystemRescue ja UEFI Shellist käivitatud tööriistad
vajavad väljalülitatud Secure Booti. Tuum pole veel lukustatud (tegevuskava
punkt N6), seega USOS-i võtme registreerimine tähendab usaldust kõige
vastu, mis sellega on allkirjastatud. Üksikasjad:
[kasutusjuhend, 6. jaotis](../USER-GUIDE.en.md#6-secure-boot-and-the-usos-key-mok),
[secure-boot-usos.md](../secure-boot-usos.md).

<a id="answer-profiles"></a>
## 7. Vastuseprofiilid

Üks väike profiil (kontod, arvuti nimi, keel, ajavöönd, valikulised
kohandused) muudetakse käivitamisel failiks `WINNT.SIF` (2000/XP/2003),
`autounattend.xml` (Vistast kuni 11-ni, Server) või Ubuntu autoinstalliks,
Debiani preseediks või Fedora kickstartiks. Profiilid luuakse UEFI-menüüs
(**Järelevalveta install** -> **+ Lisa uus profiil**) ja salvestatakse
ESP-le.

![Vastuseprofiili redaktor jaotisega Välimus ja lisad](../images/profile-editor-appearance.png)

- Sihtketas **valitakse alati käsitsi**; profiil ei vali ega kustuta kunagi
  ketast.
- Tootevõti salvestatakse ainult siis, kui märgid valiku „Jäta võti sellele
  pulgale meelde“; muidu säilib see ainult taaskäivituseni. **USOS ei
  sisalda võtmeid** ega hiili mööda aktiveerimisest ega tootevõtme lehest.
- Paroolid ja meelde jäetud võtmed salvestatakse pulgale lihttekstina
  (neid ei näidata kunagi loendites ega logides). Linuxi profiilid töötavad
  ainult UEFI-l.

Üksikasjad: [kasutusjuhend, 7. jaotis](../USER-GUIDE.en.md#7-answer-profiles-and-tweaks),
[answer-profiles.md](../answer-profiles.md).

<a id="known-issues"></a>
## 8. Teadaolevad probleemid

- **Vista ainult USB 3-ga emaplaatidel (X470):** USB-mälupulgad pole
  installitud süsteemis nähtavad ja Vista jääb testrežiimi
  (testallkirjastatud USB 3 tagasiport). Renesas uPD72020x PCIe-kaart
  väldib mõlemat.
- **CSMWrapi teed:** vajavad legacy VBIOS-iga graafikakaarti (muidu jääb
  ekraan mustaks), võtavad ühe protsessorilõime, vajavad MBR-sihtketast
  (kustutatakse) ja väljalülitatud Secure Booti.
- **Server 2003 x86 / XP x64:** STOP 0xA5 (ACPI) X470-l ja USB-sisend puudub
  ainult xHCI-ga emaplaatidel.
- **Windows 2000** ei tööta ainult AHCI-ga emaplaatidel (NT 5.0 jaoks pole
  AHCI-draiverit); **XP** ei toeta NVMe-d ega saa BIOS-režiimis
  draiveripaketti ega PAE-d.
- **Secure Boot:** SystemRescue on blokeeritud (allkirjastatud laadurit
  pole); UEFI Shell ei saa tööriistu käivitada; pärast BlackLotuse
  DBX-värskendust vanemad Windowsi andmekandjad ei käivitu.
- **Linux:** Ubuntu Serveri installer valib eelnevalt suurima ketta, mis
  võib olla USOS-i pulk; kontrolli alati sihtketast.
- **AMI püsivara** näitab pulga iga partitsiooni eraldi alglaadimiskirjena.
- Abistav mikro-Linux vajab x86-64 protsessorit ja vähemalt 256 MiB RAM-i.

Täielik loend koos lahendustega ning aus loend sellest, mida **pole veel
riistvaral testitud** (nt Windows Server 2008-2025, Windows 8/8.1,
Windows 10/11 Secure Bootiga riistvaral, Windows 7 SP1 originaal-ISO läbi
PE10 doonori), on
[väljalaskemärkmetes](../release-notes-1.0.md#known-issues) (inglise keeles)
ja [kasutusjuhendi 9. ja 10. jaotises](../USER-GUIDE.en.md#9-known-issues-and-workarounds).

<a id="building"></a>
## 9. Lähtekoodist ehitamine

Ehitamine toimub Windowsis. Täielikud juhised: [BUILDING.md](../BUILDING.md)
(inglise keeles).

- `build.bat` ehitab kogu väljalaske (EFI-programm, mikro-Linux, BIOS-i
  tuum, payload ja `installer\USOS Installer.exe`) ühe buildi
  identifikaatoriga (`BYYMMDD-HHMMSS-XXXXXXXX`). Kasutatakse kaustas
  `tools/zig` olevat kaasaskantavat Zigi; Go ja Python peavad olema
  `PATH`-is.
- `tools/tests/run.ps1` käivitab automaattestid, nt
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/tests/run.ps1 -Suite all`.
- `powershell -ExecutionPolicy Bypass -File tools\release\make_release.ps1`
  loob väljalaske failid kausta `zig-out\release-1.0\`.
- **Võrguühenduseta ehitamine:** paki lahti `USOS-1.0.0-buildkit.zip`, sea
  `USOS_BUILDKIT` lahtipakitud kaustale `USOS-1.0.0-buildkit` ja käivita
  `build.bat`; komplekti kontrollitakse selle manifesti alusel ja
  allalaadimised on keelatud.
- **Allkirjastamisvõti:** Secure Booti (MOK) võti asub **väljaspool
  hoidlat**, kaustas `%APPDATA%\USOS\signing\` (`USOS_SIGNING_DIR`
  alistab selle). Ilma selleta on build **allkirjastamata** ja käivitub
  ainult väljalülitatud Secure Bootiga. Ära kunagi commiti ega jaga võtit.

Windowsi ISO-d, draiverid ja muud kolmandate osapoolte andmekandjad ei ole
kunagi hoidla osa.

<a id="licence"></a>
## 10. Litsents

- USOS-i enda kood on litsentsitud **GNU General Public License'i versiooni
  3 või uuema** alusel (GPL-3.0-or-later): vt [LICENSE](../../LICENSE) ja
  [NOTICE](../../NOTICE). Copyright (C) 2026 The USOS Authors.
- Kolmandate osapoolte komponendid säilitavad oma litsentsid. Need on
  pulgal koondatud eraldiseisvad programmid; vt väljalaskes
  `THIRD-PARTY-NOTICES.txt` ja `LICENSES/` ning
  [LICENSES-AUDIT.md](../LICENSES-AUDIT.md).
- Väljalaskes olevaid Microsofti faile (värskendus- ja draiverifailid,
  XP-pakettide failid, WinPE doonor) hoitakse säilitamise eesmärgil, neid
  levitatakse edasi hooldaja enda riskil, neile ei kehti ükski USOS-i
  litsents ja need eemaldatakse õiguste omaja taotlusel.
- Panused võetakse vastu [CONTRIBUTING.md](../../CONTRIBUTING.md)
  tingimustel (lihtne litsentsi andmine panustaja poolt).

Windows, MS-DOS ja seotud nimed on Microsofti kaubamärgid. USOS ei ole
Microsoftiga seotud.

<a id="support"></a>
## 11. Tugi

- Küsimused ja veateated: GitHub issues. Lisa
  [kasutusjuhendi 11. jaotises](../USER-GUIDE.en.md#11-troubleshooting-and-logs)
  kirjeldatud logid ja kontrolli, et need ei sisalda paroole ega võtmeid.
- Tasuline seadistusabi ettevõtetele on saadaval nõudmisel; praegu võta
  ühendust GitHub issues'i kaudu.
- Sponsorlus: läbi `.github/FUNDING.yml`, kui see on täidetud.

<a id="documentation"></a>
## 12. Dokumentatsioon

- Kasutusjuhend: [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md)
- [Väljalaskemärkmed 1.0](../release-notes-1.0.md) (inglise keeles)
- [Kuidas USOS töötab](../HOW-IT-WORKS.md)
- [Ehitamine](../BUILDING.md)
- [Litsentside audit](../LICENSES-AUDIT.md)
- [Väljalaske 1.0 testiplaan](../RELEASE-TEST-1.0.md)
- [Tegevuskava](../ROADMAP.md) (poola keeles) ja [testitulemused](../../TESTING.md) (poola keeles)
