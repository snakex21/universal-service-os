# Universal Service OS (USOS) 1.0.0

> Tai vertimas. Privaloma yra [README versija anglų kalba](../../README.md).

**Kalbos:** [English](../../README.md) ·
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
Lietuvių ·
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

## Turinys

1. [Kas yra USOS](#what-usos-is)
2. [Galimybės](#features)
3. [Palaikomos sistemos ir programinės aparatinės įrangos režimai](#supported-systems)
4. [Greita pradžia](#quick-start)
5. [DATA aplankų struktūra](#data-layout)
6. [Secure Boot](#secure-boot)
7. [Atsakymų profiliai](#answer-profiles)
8. [Žinomos problemos](#known-issues)
9. [Kompiliavimas iš išeitinio kodo](#building)
10. [Licencija](#licence)
11. [Pagalba](#support)
12. [Dokumentacija](#documentation)

<a id="what-usos-is"></a>
## 1. Kas yra USOS

USOS – tai viena USB atmintinė operacinėms sistemoms diegti ir paleisti,
nuo MS-DOS iki Windows 11 ir Linux, BIOS ir UEFI kompiuteriuose, įskaitant
UEFI su Secure Boot. Savo ISO atvaizdus kopijuojate į atmintinę kaip
įprastus failus; USOS suteikia vieną meniu, aiškų ir apsaugotą tikslinio
disko pasirinkimą bei tvarkykles ir pataisas, kurių senoms sistemoms reikia
naujoje aparatinėje įrangoje. Atmintinė paruošiama sistemoje Windows su
`USOS-Installer-1.0.0.exe`. USOS neturi jokių Windows atvaizdų, produkto
raktų ir jokio aktyvinimo apėjimo.

![USOS UEFI meniu, pradžios ekranas](../images/menu-home.png)

<a id="features"></a>
## 2. Galimybės

- **Vienas meniu, BIOS ir UEFI.** Ta pati atmintinė paleidžiama ir Legacy
  BIOS, ir UEFI (x64) režimu su tuo pačiu katalogu. UEFI meniu veikia su
  klaviatūra, pele, jutikliniu ekranu ir USB žaidimų pultais.
- **Atvaizdai lieka failais.** ISO, WIM, IMG, VHD, VHDX ir EFI atvaizdai
  skaitomi tiesiai iš NTFS DATA skaidinio; niekas neišskleidžiama ir po
  kopijavimo nieko nereikia paleisti.
- **Apsaugotas tikslinis diskas.** Diską visada pasirenkate ir patvirtinate
  patys; pati USOS atmintinė niekada nesiūloma.
- **Secure Boot** per shim 16.1 (pasirašytas Microsoft) ir USOS raktą
  (MOK), kuris kiekviename kompiuteryje įregistruojamas vieną kartą.
- **Senas Windows naujoje aparatinėje įrangoje.** Windows XP su tvarkyklių
  paketu ir PAE UEFI režimu su CSM; XP ir Vista UEFI režimu be CSM per
  CSMWrap (eksperimentinis); Windows 7 x64 be CSM per UefiSeven ir VGA
  nukreipimo dispečerį; USB 3 ir NVMe integracija Windows 7.
- **Atsakymų profiliai** automatiniam Windows ir Linux diegimui,
  redaguojami UEFI meniu ekranine klaviatūra.
- **Linux ISO iš DATA** (Ubuntu, Mint, Fedora, Debian, SystemRescue,
  GParted, Clonezilla ir kiti) UEFI režimu su Secure Boot ir be jo bei
  BIOS režimu.
- **Įrankiai:** integruotas FreeDOS su failų tvarkytuve ir Hardware & SMART
  skydeliu (BIOS), EDK2 UEFI Shell (UEFI), jūsų pačių paleidžiami įrankiai
  aplanke `Utilities`, jūsų pačių UEFI tvarkyklės ir Windows INF tvarkyklių
  aplankai.
- **Diegimo programa su keturiais režimais:** Diegimas, Vietinis
  atnaujinimas (**Atnaujinti USOS**, išsaugo atvaizdus ir jūsų failus),
  Taisymas (**Taisyti ESP**), Šalinimas.
- **27 kalbos** (etalonas yra anglų kalba; kitos kalbos, išskyrus lenkų,
  pažymėtos kaip iš dalies ar visiškai išverstos mašininiu būdu), temos su
  redaktoriumi meniu, jutiklinio ekrano ir žaidimų pulto palaikymas ROG
  Ally.

| | |
|---|---|
| ![Windows sistemų sąrašas su būsenos ženkleliais](../images/windows-list.png) | ![Linux distribucijų sąrašas](../images/linux-list.png) |
| Windows sistemos su būsenos ženkleliais | Linux ISO iš DATA |
| ![Legacy BIOS meniu](../images/bios-menu.png) | ![Integruotos ir naudotojo temos](../images/themes-grid.png) |
| Legacy BIOS meniu | Temos: Dark, Light, Retro, Sunset |

<a id="supported-systems"></a>
## 3. Palaikomos sistemos ir programinės aparatinės įrangos režimai

**HW** = išbandyta tikroje aparatinėje įrangoje, **VM** = išbandyta tik
QEMU/VirtualBox, **eksp.** = eksperimentinis (taip pažymėta meniu),
**neišbandyta** = kelias yra, bet neužregistruotas nė vienas paleidimas,
**—** = nepalaikoma (meniu nurodo priežastį). Bandomieji kompiuteriai:
**X470** (ASRock X470, Ryzen 7 5700X, Radeon RX 560, UEFI), **MS-7100**
(MSI, Socket 939, Athlon 64 X2, BIOS), **Ally** (ASUS ROG Ally RC71L, UEFI
su Secure Boot).

| Sistema | BIOS (Legacy) | UEFI + CSM | UEFI be CSM (CSMWrap) | Secure Boot įjungtas |
|---|---|---|---|---|
| Pats USOS meniu | HW | HW | HW | HW (X470, Ally) |
| MS-DOS 6.22, Windows 3.1/3.11 | HW (Windows 3.1 standartiniu režimu, MS-7100) | — | — | — |
| Windows 98 SE | VM; HW iš dalies (MS-7100: Setup iki pirmojo paleidimo paruošimo, darbalaukis nepatvirtintas) | — | — | — |
| Windows 2000 SP4 | HW (MS-7100) | eksp., VM (iki failų kopijavimo) | eksp., VM (CSMWrap) | — |
| Windows XP x86 SP3 | VM (be tvarkyklių paketo, be PAE) | HW (X470: tvarkyklių paketas, PAE, 31,9 GB) | eksp., HW (X470, CSMWrap) | — |
| Windows XP x64 SP2 | neišbandyta | eksp., VM (iki GUI Setup); X470: STOP 0xA5 | eksp., VM (CSMWrap) | — |
| Windows Server 2003 R2 SP2 x86 | neišbandyta | eksp., VM (iki GUI Setup); X470 su 1.0 neišbandyta | eksp., VM (CSMWrap) | — |
| Windows Vista SP2 x64 | HW (MS-7100) | HW (X470) | eksp., HW (X470, CSMWrap, legacy MBR) | — |
| Windows 7 SP1 x64 | HW (MS-7100) | VM (pilnas diegimas) | HW (X470, UefiSeven + dispečeris) | — |
| Windows 8 / 8.1 | neišbandyta | neišbandyta | neišbandyta | neišbandyta |
| Windows 10 | HW (x86, MS-7100) | HW (x64, X470) | savasis UEFI, tas pats kelias kaip su CSM | VM (iki Windows įkėliklio) |
| Windows 11 | neišbandyta | HW (naudotojo pranešimas) | savasis UEFI, tas pats kelias kaip su CSM | VM (iki Windows įkėliklio) |
| Windows Server 2008 - 2025 | eksp., niekada nepaleista | eksp., niekada nepaleista | eksp., niekada nepaleista | 2008/2008 R2: —; 2012+: neišbandyta |
| Linux ISO (Ubuntu, Mint, Fedora, Debian, GParted, Clonezilla) | VM; HW Mint live (MS-7100) | HW (X470: Mint, Fedora, Debian netinst, Clonezilla, GParted) | taip pat kaip su CSM | HW Fedora, Mint (X470); kiti VM |
| SystemRescue | VM | HW (X470) | taip pat kaip su CSM | — (nėra pasirašyto įkėliklio) |
| FreeDOS, Hardware & SMART (integruoti) | VM (FreeDOS); HW (Hardware & SMART) | — | — | — |
| MemTest86+ (i586 ISO, pateikiate patys) | HW | `.efi` versija iš `Utilities` (neišbandyta) | kaip su CSM | tik pasirašytas `.efi` |
| UEFI Shell (integruotas) | — | VM | VM | VM (paleidžiamas, bet negali paleisti įrankių) |

Ar UEFI veikia su CSM, ar be jo, svarbu tik legacy keliams (2000, XP, 2003,
Vista, 7); visi kiti UEFI įrašai abiem režimais vykdo tą patį kodą. Windows
XP, Vista ir 7 bei visiems CSMWrap keliams reikia išjungto Secure Boot.
Visa lentelė su pastabomis ir kiekvieno buildo aparatinės įrangos
rezultatais pateikta
[naudotojo vadovo 5 skyriuje](../USER-GUIDE.en.md#5-what-works-in-which-firmware-mode)
ir [laidos pastabose](../release-notes-1.0.md#supported-systems) (anglų
kalba).

<a id="quick-start"></a>
## 4. Greita pradžia

Laidos failai:

| Failas | Paskirtis |
|---|---|
| `USOS-Installer-1.0.0.exe` | **Pilna diegimo programa**: visas USOS kartu su WinPE donoru ir abiem XP paketais; veikia be interneto |
| `USOS-Installer-1.0.0-online.exe` | **Internetinė diegimo programa**: mažas atsisiuntimas; prireikus atsisiunčia WinPE donorą ir XP paketus iš šio leidimo ir juos patikrina |
| `USOS-1.0.0-WinPE-PE10-donor.zip` | PE10 donoras, reikalingas Vista ir originaliems Windows 7 ISO UEFI režimu |
| `USOS-1.0.0-XP-package-PL.zip`, `USOS-1.0.0-XP-package-EN.zip` | Windows XP x86 SP3 UEFI paketas, kiekvienas tiksliai vienam originaliam ISO (`pl_..._x14-80476.iso` / `en_..._x14-80428.iso`), diegiamas pridėtu `install-xp-package.ps1` |
| `USOS-1.0.0-sources.zip` + `SOURCE-OFFER.txt` | trečiųjų šalių komponentų išeitinis kodas ir rašytinis išeitinio kodo pasiūlymas |
| `USOS-1.0.0-buildkit.zip` | užfiksuotos įrankių grandinės ir kompiliavimo įvestys perkompiliavimui neprisijungus |
| `LICENSES/`, `THIRD-PARTY-NOTICES.txt` | licencijų tekstai ir pranešimai |
| `SHA256SUMS` | kiekvieno failo SHA-256 |

Atsisiųstą failą patikrinkite komanda
`certutil -hashfile USOS-Installer-1.0.0.exe SHA256` (arba `Get-FileHash`
PowerShell aplinkoje) ir palyginkite su `SHA256SUMS`.

![USOS diegimo programa: operacijos pasirinkimas](../images/installer-mode.png)

1. Pasirūpinkite USB atmintine, kurios talpa **ne mažesnė kaip 32 GiB**
   (praktiškai 64 GB; atmintinė, parduodama kaip „32 GB“, paprastai būna per
   maža). **Visi joje esantys duomenys bus ištrinti.**
2. Windows kompiuteryje paleiskite `USOS-Installer-1.0.0.exe` (ji prašo
   administratoriaus teisių), pasirinkite **Diegimas**, pažymėkite
   atmintinę, įveskite patvirtinimo tekstą ir spustelėkite **IŠTRINTI IR
   ĮDIEGTI**.
3. Nukopijuokite savo ISO atvaizdus į DATA skaidinį, į kiekvienos sistemos
   aplanką `Images`, pvz., `Systems\Windows\Windows 11\Images\`.
4. Pasirinktinai: Vista arba originaliam Windows 7 UEFI režimu nukopijuokite
   aplanką `Programs` iš PE10 donoro zip archyvo į DATA šaknį ir paleiskite
   **Atnaujinti USOS**; XP UEFI režimu paleiskite kaip administratorius
   `install-xp-package.ps1` iš XP paketo, atitinkančio jūsų ISO (vienu metu
   tik vienas paketas).
5. Paleiskite tikslinį kompiuterį iš atmintinės (BIOS arba UEFI). Jei
   Secure Boot įjungtas, vieną kartą įregistruokite USOS raktą
   ([Secure Boot](#secure-boot)). Pasirinkite sistemą ir atvaizdą,
   pasirinktinai atsakymų profilį, patvirtinkite tikslinį diską ir
   vadovaukitės sistemos diegimo programa.

Nuoseklios instrukcijos kiekvienam ekranui pateiktos naudotojo vadove:
[English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md).

<a id="data-layout"></a>
## 5. DATA aplankų struktūra

Diegimo programa sukuria atmintinę su trimis skaidiniais: `USOS_ESP`
(FAT32, 1 GiB: paleidimo failai, raktas, nustatymai, žurnalai, profiliai),
`USOS_DATA` (NTFS: jūsų failai) ir `USOS_WORK` (NTFS, darbo vieta kai
kurioms Windows diegimo programoms). Visi DATA aplankai sukuriami
automatiškai:

```
USOS_DATA\
├─ Systems\
│  ├─ Windows\<versija>\    Images\  Unattended\   (nuo Windows 3.1 iki 11, Server 2003-2025)
│  ├─ Linux\<distribucija>\ Images\  Unattended\   (Other Linux\ nežinomiems ISO)
│  ├─ Betas\
│  └─ DOS\<atmaina>\        Images\
├─ Utilities\
│  ├─ FreeDOS\Programs\     DOS programos integruotam FreeDOS
│  ├─ UEFI Shell\Tools\     EFI įrankiai UEFI Shell
│  └─ <jūsų įrankis>\Images\   pvz., MemTest86\Images\memtest86.efi
├─ Drivers\
│  ├─ UEFI\<pavadinimas>\   .efi tvarkyklės, kurias įkelia USOS meniu
│  └─ <Windows versija>\    Storage\  USB\  Other\  (INF paketai)
├─ Themes\<pavadinimas>\theme.ini  jūsų temos (UEFI meniu)
└─ Programs\
   └─ USOS\                 tvarko USOS (PE10 donoras), neliesti
```

Pridėję `icon.png` arba naują įrankio aplanką, paleiskite **Atnaujinti
USOS**. Visas medis:
[naudotojo vadovas, 4 skyrius](../USER-GUIDE.en.md#4-folder-layout-on-data).

<a id="secure-boot"></a>
## 6. Secure Boot

Kai Secure Boot įjungtas, USOS paleidžiamas per **shim 16.1** (Fedora
buildas, pasirašytas Microsoft UEFI CA) ir MokManager. Pats USOS ir jo
komponentai pasirašyti **USOS raktu**, kuris įregistruojamas **vieną kartą
kiekviename kompiuteryje**:

- **Paprasčiausia:** išjunkite Secure Boot, paleiskite atmintinę, pradžios
  ekrane pasirinkite **Pridėti** ir patvirtinkite **Taip, įrašyti raktą**,
  tada vėl įjunkite Secure Boot. Tai veikia ir Setup Mode režimu
  (patvirtinta X470).
- **Neišjungiant Secure Boot:** ties „Verification failed“ naudokite
  MokManager -> **Enroll key from disk** -> `USOS_ESP` -> `USOS-KEY.cer`
  (patvirtinta ROG Ally). Diegimo programos kortelė **Paruošti
  (vienkartinai)** priverčia MokManager laukti, o ne skaičiuoti laiką
  atgal.

NVRAM atstatymas pašalina raktą; įregistruokite jį iš naujo. XP, Vista, 7,
visiems CSMWrap keliams, SystemRescue ir iš UEFI Shell paleistiems
įrankiams reikia išjungto Secure Boot. Branduolys dar neužrakintas (plano
punktas N6), todėl įregistravę USOS raktą pasitikite viskuo, kas juo
pasirašyta. Išsamiau:
[naudotojo vadovas, 6 skyrius](../USER-GUIDE.en.md#6-secure-boot-and-the-usos-key-mok),
[secure-boot-usos.md](../secure-boot-usos.md).

<a id="answer-profiles"></a>
## 7. Atsakymų profiliai

Vienas nedidelis profilis (paskyros, kompiuterio pavadinimas, kalba, laiko
juosta, pasirenkami patobulinimai) paleidimo metu paverčiamas `WINNT.SIF`
(2000/XP/2003), `autounattend.xml` (nuo Vista iki 11, Server) arba Ubuntu
autoinstall, Debian preseed ar Fedora kickstart. Profiliai kuriami UEFI
meniu (**Automatinis diegimas** -> **+ Pridėti naują profilį**) ir
saugomi ESP.

![Atsakymų profilio redaktorius su skiltimi Išvaizda ir priedai](../images/profile-editor-appearance.png)

- Tikslinis diskas **visada pasirenkamas rankiniu būdu**; profilis niekada
  nepasirenka ir netrina disko.
- Produkto raktas išsaugomas tik tada, jei pažymite „Įsiminti raktą šioje
  atmintinėje“; kitaip jis laikomas tik iki paleidimo iš naujo. **USOS neturi
  jokių raktų** ir neapeina nei aktyvinimo, nei produkto rakto puslapio.
- Slaptažodžiai ir įsiminti raktai atmintinėje saugomi kaip paprastas
  tekstas (sąrašuose ir žurnaluose jie niekada nerodomi). Linux profiliai
  veikia tik UEFI režimu.

Išsamiau: [naudotojo vadovas, 7 skyrius](../USER-GUIDE.en.md#7-answer-profiles-and-tweaks),
[answer-profiles.md](../answer-profiles.md).

<a id="known-issues"></a>
## 8. Žinomos problemos

- **Vista plokštėse tik su USB 3 (X470):** įdiegtoje sistemoje USB
  atmintinės nematomos, o Vista lieka bandomajame režime (bandomuoju parašu
  pasirašytas USB 3 backport). Renesas uPD72020x PCIe plokštė išsprendžia
  abi problemas.
- **CSMWrap keliai:** reikia vaizdo plokštės su legacy VBIOS (kitaip juodas
  ekranas), užima vieną procesoriaus giją, reikia MBR tikslinio disko (jis
  ištrinamas) ir išjungto Secure Boot.
- **Server 2003 x86 / XP x64:** STOP 0xA5 (ACPI) X470 kompiuteryje ir
  neveikia USB įvestis plokštėse tik su xHCI.
- **Windows 2000** neveikia plokštėse tik su AHCI (nėra NT 5.0 AHCI
  tvarkyklės); **XP** nepalaiko NVMe ir BIOS režimu negauna nei tvarkyklių
  paketo, nei PAE.
- **Secure Boot:** SystemRescue užblokuotas (nėra pasirašyto įkėliklio); UEFI
  Shell negali paleisti įrankių; po BlackLotus DBX atnaujinimo senesnės
  Windows laikmenos nepasileidžia.
- **Linux:** Ubuntu Server diegimo programa iš anksto pasirenka didžiausią
  diską, kuris gali būti USOS atmintinė; visada patikrinkite tikslinį diską.
- **AMI programinė aparatinė įranga** kiekvieną atmintinės skaidinį rodo
  kaip atskirą paleidimo įrašą.
- Pagalbiniam mikro-Linux reikia x86-64 procesoriaus ir bent 256 MiB RAM.

Visas sąrašas su problemų apėjimo būdais ir sąžiningas sąrašas to, kas
aparatinėje įrangoje **dar neišbandyta** (pvz., Windows Server 2008-2025,
Windows 8/8.1, Windows 10/11 su Secure Boot aparatinėje įrangoje,
originalus Windows 7 SP1 ISO per PE10 donorą), pateikti
[laidos pastabose](../release-notes-1.0.md#known-issues) (anglų kalba) ir
[naudotojo vadovo 9 ir 10 skyriuose](../USER-GUIDE.en.md#9-known-issues-and-workarounds).

<a id="building"></a>
## 9. Kompiliavimas iš išeitinio kodo

Kompiliuojama sistemoje Windows. Išsamios instrukcijos:
[BUILDING.md](../BUILDING.md) (anglų kalba).

- `build.bat` sukompiliuoja visą laidą (EFI programą, mikro-Linux, BIOS
  branduolį, payload ir `installer\USOS Installer.exe`) su vienu buildo
  identifikatoriumi (`BYYMMDD-HHMMSS-XXXXXXXX`). Naudojamas nešiojamasis Zig
  iš `tools/zig`; Go ir Python turi būti `PATH`.
- `tools/tests/run.ps1` paleidžia automatinius testus, pvz.,
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/tests/run.ps1 -Suite all`.
- `powershell -ExecutionPolicy Bypass -File tools\release\make_release.ps1`
  sukuria laidos failus aplanke `zig-out\release-1.0\`.
- **Kompiliavimas neprisijungus:** išskleiskite `USOS-1.0.0-buildkit.zip`,
  nustatykite `USOS_BUILDKIT` į išskleistą aplanką `USOS-1.0.0-buildkit` ir
  paleiskite `build.bat`; rinkinys tikrinamas pagal jo manifestą, o
  atsisiuntimai išjungti.
- **Pasirašymo raktas:** Secure Boot (MOK) raktas laikomas **už saugyklos
  ribų**, aplanke `%APPDATA%\USOS\signing\` (`USOS_SIGNING_DIR` jį
  pakeičia). Be jo buildas yra **nepasirašytas** ir paleidžiamas tik
  išjungus Secure Boot. Niekada nedėkite rakto į commit ir juo nesidalykite.

Windows ISO, tvarkyklės ir kitos trečiųjų šalių laikmenos niekada nėra
saugyklos dalis.

<a id="licence"></a>
## 10. Licencija

- Paties USOS kodas licencijuojamas pagal **GNU General Public License
  3 ar vėlesnę versiją** (GPL-3.0-or-later): žr. [LICENSE](../../LICENSE) ir
  [NOTICE](../../NOTICE). Copyright (C) 2026 Maksymilian and the USOS Authors.
- Trečiųjų šalių komponentai išlaiko savo licencijas. Tai atskiros
  programos, sujungtos atmintinėje; žr. laidoje esančius
  `THIRD-PARTY-NOTICES.txt` ir `LICENSES/` bei
  [LICENSES-AUDIT.md](../LICENSES-AUDIT.md).
- Laidoje esantys Microsoft failai (atnaujinimų ir tvarkyklių failai, XP
  paketų failai, WinPE donoras) saugomi išsaugojimo tikslais, platinami
  prižiūrėtojo paties rizika, jiems netaikoma jokia USOS licencija, ir jie
  bus pašalinti teisių turėtojo prašymu.
- Indėliai priimami pagal [CONTRIBUTING.md](../../CONTRIBUTING.md)
  (paprastas licencijos suteikimas iš indėlio autoriaus).

Windows, MS-DOS ir susiję pavadinimai yra Microsoft prekių ženklai. USOS
nėra susijęs su Microsoft.

<a id="support"></a>
## 11. Pagalba

- Klausimai ir pranešimai apie klaidas: GitHub issues. Pridėkite
  [naudotojo vadovo 11 skyriuje](../USER-GUIDE.en.md#11-troubleshooting-and-logs)
  aprašytus žurnalus ir patikrinkite, ar juose nėra slaptažodžių ar raktų.
- Mokama diegimo pagalba įmonėms teikiama pagal pageidavimą; kol kas
  susisiekite per GitHub issues.
- Rėmimas: per `.github/FUNDING.yml`, kai jis bus užpildytas.

<a id="documentation"></a>
## 12. Dokumentacija

- Naudotojo vadovas: [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md)
- [Laidos 1.0 pastabos](../release-notes-1.0.md) (anglų kalba)
- [Kaip veikia USOS](../HOW-IT-WORKS.md)
- [Kompiliavimas](../BUILDING.md)
- [Licencijų auditas](../LICENSES-AUDIT.md)
- [Laidos 1.0 bandymų planas](../RELEASE-TEST-1.0.md)
- [Veiksmų planas](../ROADMAP.md) (lenkų kalba) ir [testų rezultatai](../../TESTING.md) (lenkų kalba)
