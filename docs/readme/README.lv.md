# Universal Service OS (USOS) 1.0.0

> Šis ir tulkojums. Noteicošā ir [README versija angļu valodā](../../README.md).

**Valodas:** [English](../../README.md) ·
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
Latviešu ·
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

## Saturs

1. [Kas ir USOS](#what-usos-is)
2. [Iespējas](#features)
3. [Atbalstītās sistēmas un aparātprogrammatūras režīmi](#supported-systems)
4. [Ātrā sākšana](#quick-start)
5. [DATA mapju struktūra](#data-layout)
6. [Secure Boot](#secure-boot)
7. [Atbilžu profili](#answer-profiles)
8. [Zināmās problēmas](#known-issues)
9. [Būvēšana no pirmkoda](#building)
10. [Licence](#licence)
11. [Atbalsts](#support)
12. [Dokumentācija](#documentation)

<a id="what-usos-is"></a>
## 1. Kas ir USOS

USOS ir viena USB zibatmiņa operētājsistēmu instalēšanai un palaišanai, no
MS-DOS līdz Windows 11 un Linux, datoros ar BIOS un UEFI, ieskaitot UEFI ar
Secure Boot. Savus ISO attēlus jūs kopējat uz zibatmiņas kā parastus failus;
USOS dod vienu izvēlni, skaidru un aizsargātu mērķa diska izvēli, kā arī
draiverus un labojumus, kas vecām sistēmām nepieciešami jaunā aparatūrā.
Zibatmiņu sagatavo sistēmā Windows ar `USOS-Installer-1.0.0.exe`. USOS
neietver Windows attēlus, produktu atslēgas un nekādu aktivizācijas
apiešanu.

![USOS UEFI izvēlne, sākuma ekrāns](../images/menu-home.png)

<a id="features"></a>
## 2. Iespējas

- **Viena izvēlne, BIOS un UEFI.** Tā pati zibatmiņa startē gan Legacy
  BIOS, gan UEFI (x64) režīmā ar to pašu katalogu. UEFI izvēlne darbojas ar
  tastatūru, peli, skārienekrānu un USB spēļu kontrolieriem.
- **Attēli paliek faili.** ISO, WIM, IMG, VHD, VHDX un EFI attēli tiek lasīti
  tieši no NTFS DATA nodalījuma; nekas netiek izpakots, un pēc kopēšanas
  nekas nav jāpalaiž.
- **Aizsargāts mērķa disks.** Disku vienmēr izvēlaties un apstiprināt jūs
  paši; pati USOS zibatmiņa nekad netiek piedāvāta.
- **Secure Boot** ar shim 16.1 (Microsoft parakstīts) un USOS atslēgu
  (MOK), kas katrā datorā jāreģistrē vienu reizi.
- **Vecs Windows jaunā aparatūrā.** Windows XP ar draiveru pakotni un PAE
  UEFI ar CSM; XP un Vista UEFI bez CSM ar CSMWrap (eksperimentāli);
  Windows 7 x64 bez CSM ar UefiSeven un VGA maršrutēšanas dispečeru;
  USB 3 un NVMe integrācija operētājsistēmai Windows 7.
- **Atbilžu profili** Windows un Linux automātiskai instalēšanai, rediģējami
  UEFI izvēlnē ar ekrāna tastatūru.
- **Linux ISO no DATA** (Ubuntu, Mint, Fedora, Debian, SystemRescue,
  GParted, Clonezilla un citi) UEFI ar Secure Boot un bez tā, kā arī BIOS.
- **Rīki:** iebūvēts FreeDOS ar failu pārvaldnieku un Hardware & SMART
  paneli (BIOS), EDK2 UEFI Shell (UEFI), jūsu pašu sāknējamie rīki mapē
  `Utilities`, jūsu pašu UEFI draiveri un Windows INF draiveru mapes.
- **Instalētājs ar četriem režīmiem:** Instalēšana, Lokāla atjaunināšana
  (**Atjaunināt USOS**, saglabā attēlus un jūsu failus), Labošana
  (**Salabot ESP**), Atinstalēšana.
- **27 valodas** (atsauces valoda ir angļu; pārējās valodas, izņemot poļu,
  ir atzīmētas kā daļēji vai pilnībā mašīntulkotas), motīvi ar redaktoru
  izvēlnē, skārienekrāna un spēļu kontroliera atbalsts ROG Ally.

| | |
|---|---|
| ![Windows sistēmu saraksts ar statusa emblēmām](../images/windows-list.png) | ![Linux distributīvu saraksts](../images/linux-list.png) |
| Windows sistēmas ar statusa emblēmām | Linux ISO no DATA |
| ![Legacy BIOS izvēlne](../images/bios-menu.png) | ![Iebūvētie un lietotāja motīvi](../images/themes-grid.png) |
| Legacy BIOS izvēlne | Motīvi: Dark, Light, Retro, Sunset |

<a id="supported-systems"></a>
## 3. Atbalstītās sistēmas un aparātprogrammatūras režīmi

**HW** = pārbaudīts uz reālas aparatūras, **VM** = pārbaudīts tikai
QEMU/VirtualBox, **eksp.** = eksperimentāls (izvēlnē tā atzīmēts),
**nav pārbaudīts** = ceļš pastāv, bet neviena palaišana nav reģistrēta,
**—** = netiek atbalstīts (izvēlne parāda iemeslu). Testa datori: **X470**
(ASRock X470, Ryzen 7 5700X, Radeon RX 560, UEFI), **MS-7100** (MSI,
Socket 939, Athlon 64 X2, BIOS), **Ally** (ASUS ROG Ally RC71L, UEFI ar
Secure Boot).

| Sistēma | BIOS (Legacy) | UEFI + CSM | UEFI bez CSM (CSMWrap) | Secure Boot ieslēgts |
|---|---|---|---|---|
| Pati USOS izvēlne | HW | HW | HW | HW (X470, Ally) |
| MS-DOS 6.22, Windows 3.1/3.11 | HW (Windows 3.1 standarta režīmā, MS-7100) | — | — | — |
| Windows 98 SE | VM; HW daļēji (MS-7100: Setup līdz pirmās palaišanas sagatavošanai, darbvirsma nav apstiprināta) | — | — | — |
| Windows 2000 SP4 | HW (MS-7100) | eksp., VM (līdz failu kopēšanai) | eksp., VM (CSMWrap) | — |
| Windows XP x86 SP3 | VM (bez draiveru pakotnes, bez PAE) | HW (X470: draiveru pakotne, PAE, 31,9 GB) | eksp., HW (X470, CSMWrap) | — |
| Windows XP x64 SP2 | nav pārbaudīts | eksp., VM (līdz GUI Setup); X470: STOP 0xA5 | eksp., VM (CSMWrap) | — |
| Windows Server 2003 R2 SP2 x86 | nav pārbaudīts | eksp., VM (līdz GUI Setup); X470 ar 1.0 nav pārbaudīts | eksp., VM (CSMWrap) | — |
| Windows Vista SP2 x64 | HW (MS-7100) | HW (X470) | eksp., HW (X470, CSMWrap, legacy MBR) | — |
| Windows 7 SP1 x64 | HW (MS-7100) | VM (pilna instalēšana) | HW (X470, UefiSeven + dispečers) | — |
| Windows 8 / 8.1 | nav pārbaudīts | nav pārbaudīts | nav pārbaudīts | nav pārbaudīts |
| Windows 10 | HW (x86, MS-7100) | HW (x64, X470) | vietējais UEFI, tas pats ceļš kā ar CSM | VM (līdz Windows ielādētājam) |
| Windows 11 | nav pārbaudīts | HW (lietotāja ziņojums) | vietējais UEFI, tas pats ceļš kā ar CSM | VM (līdz Windows ielādētājam) |
| Windows Server 2008 - 2025 | eksp., nekad nav palaists | eksp., nekad nav palaists | eksp., nekad nav palaists | 2008/2008 R2: —; 2012+: nav pārbaudīts |
| Linux ISO (Ubuntu, Mint, Fedora, Debian, GParted, Clonezilla) | VM; HW Mint live (MS-7100) | HW (X470: Mint, Fedora, Debian netinst, Clonezilla, GParted) | tāpat kā ar CSM | HW Fedora, Mint (X470); pārējie VM |
| SystemRescue | VM | HW (X470) | tāpat kā ar CSM | — (nav parakstīta sāknēšanas ielādētāja) |
| FreeDOS, Hardware & SMART (iebūvēti) | VM (FreeDOS); HW (Hardware & SMART) | — | — | — |
| MemTest86+ (i586 ISO, nodrošināt pašiem) | HW | `.efi` versija no `Utilities` (nav pārbaudīts) | kā ar CSM | tikai parakstīts `.efi` |
| UEFI Shell (iebūvēts) | — | VM | VM | VM (startē, bet nevar palaist rīkus) |

Tas, vai UEFI darbojas ar CSM vai bez tā, ir svarīgi tikai legacy ceļiem
(2000, XP, 2003, Vista, 7); visi pārējie UEFI ieraksti abos režīmos izpilda
to pašu kodu. Windows XP, Vista un 7, kā arī visiem CSMWrap ceļiem Secure
Boot jābūt izslēgtam. Pilna tabula ar piezīmēm un katra builda aparatūras
rezultātiem ir
[lietotāja rokasgrāmatas 5. sadaļā](../USER-GUIDE.en.md#5-what-works-in-which-firmware-mode)
un [laidiena piezīmēs](../release-notes-1.0.md#supported-systems) (angļu
valodā).

<a id="quick-start"></a>
## 4. Ātrā sākšana

Laidiena faili:

**Nezināt, kuru? Lejupielādējiet pilno instalētāju.**

| Fails | Nolūks |
|---|---|
| `USOS-Installer-1.0.0.exe` | **Pilnais instalētājs**: viss USOS kopā ar WinPE donoru un abām XP pakotnēm; darbojas bezsaistē |
| `USOS-Installer-1.0.0-online.exe` | **Tiešsaistes instalētājs**: neliela lejupielāde; pēc vajadzības lejupielādē WinPE donoru un XP pakotnes no šī laidiena un tās pārbauda |
| `USOS-1.0.0-WinPE-PE10-donor.zip` | PE10 donors, nepieciešams Vista un oriģinālajiem Windows 7 ISO UEFI režīmā |
| `USOS-1.0.0-XP-package-PL.zip`, `USOS-1.0.0-XP-package-EN.zip` | Windows XP x86 SP3 UEFI pakotne, katra tieši vienam oriģinālajam ISO (`pl_..._x14-80476.iso` / `en_..._x14-80428.iso`), instalē ar pievienoto `install-xp-package.ps1` |
| `USOS-1.0.0-sources.zip` + `SOURCE-OFFER.txt` | trešo pušu komponentu pirmkods un rakstisks pirmkoda piedāvājums |
| `USOS-1.0.0-buildkit.zip` | fiksētas rīkķēdes un būvēšanas ievaddati bezsaistes pārbūvēšanai |
| `LICENSES/`, `THIRD-PARTY-NOTICES.txt` | licenču teksti un paziņojumi |
| `SHA256SUMS` | katra faila SHA-256 |

Lejupielādēto failu pārbaudiet ar
`certutil -hashfile USOS-Installer-1.0.0.exe SHA256` (vai PowerShell
komandu `Get-FileHash`), salīdzinot ar `SHA256SUMS`.

![USOS instalētājs: darbības izvēle](../images/installer-mode.png)

1. Sagādājiet USB zibatmiņu ar ietilpību **vismaz 32 GiB** (praksē 64 GB;
   zibatmiņa, ko pārdod kā „32 GB”, parasti ir par mazu). **Viss, kas uz tās
   ir, tiks izdzēsts.**
2. Windows datorā palaidiet `USOS-Installer-1.0.0.exe` (tas prasa
   administratora tiesības), izvēlieties **Instalēšana**, atlasiet
   zibatmiņu, ierakstiet apstiprinājuma tekstu un noklikšķiniet uz **DZĒST
   UN INSTALĒT**.
3. Nokopējiet savus ISO attēlus DATA nodalījumā, katras sistēmas mapē
   `Images`, piem., `Systems\Windows\Windows 11\Images\`.
4. Pēc izvēles: Vista vai oriģinālajai Windows 7 UEFI režīmā nokopējiet mapi
   `Programs` no PE10 donora zip arhīva DATA saknē un palaidiet
   **Atjaunināt USOS**; XP UEFI režīmā palaidiet kā administrators
   `install-xp-package.ps1` no XP pakotnes, kas atbilst jūsu ISO (vienlaikus
   tikai viena pakotne).
5. Palaidiet mērķa datoru no zibatmiņas (BIOS vai UEFI). Ja Secure Boot ir
   ieslēgts, vienu reizi reģistrējiet USOS atslēgu
   ([Secure Boot](#secure-boot)). Izvēlieties sistēmu un attēlu, pēc izvēles
   atbilžu profilu, apstipriniet mērķa disku un sekojiet sistēmas
   instalētājam.

Soli pa solim norādījumi katram ekrānam ir lietotāja rokasgrāmatā:
[English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md).

<a id="data-layout"></a>
## 5. DATA mapju struktūra

Instalētājs izveido zibatmiņu ar trim nodalījumiem: `USOS_ESP` (FAT32,
1 GiB: sāknēšanas faili, atslēga, iestatījumi, žurnāli, profili),
`USOS_DATA` (NTFS: jūsu faili) un `USOS_WORK` (NTFS, darba vieta dažiem
Windows instalētājiem). Visas DATA mapes tiek izveidotas automātiski:

```
USOS_DATA\
├─ Systems\
│  ├─ Windows\<versija>\    Images\  Unattended\   (no Windows 3.1 līdz 11, Server 2003-2025)
│  ├─ Linux\<distributīvs>\ Images\  Unattended\   (Other Linux\ nezināmiem ISO)
│  ├─ Betas\
│  └─ DOS\<variants>\       Images\
├─ Utilities\
│  ├─ FreeDOS\Programs\     DOS programmas iebūvētajam FreeDOS
│  ├─ UEFI Shell\Tools\     EFI rīki UEFI Shell
│  └─ <jūsu rīks>\Images\   piem., MemTest86\Images\memtest86.efi
├─ Drivers\
│  ├─ UEFI\<nosaukums>\     .efi draiveri, ko ielādē USOS izvēlne
│  └─ <Windows versija>\    Storage\  USB\  Other\  (INF pakotnes)
├─ Themes\<nosaukums>\theme.ini  jūsu motīvi (UEFI izvēlne)
└─ Programs\
   └─ USOS\                 pārvalda USOS (PE10 donors), neaiztikt
```

Pēc `icon.png` vai jaunas rīka mapes pievienošanas palaidiet **Atjaunināt
USOS**. Pilns koks:
[lietotāja rokasgrāmata, 4. sadaļa](../USER-GUIDE.en.md#4-folder-layout-on-data).

<a id="secure-boot"></a>
## 6. Secure Boot

Ja Secure Boot ir ieslēgts, USOS startē caur **shim 16.1** (Fedora builds,
parakstījis Microsoft UEFI CA) un MokManager. Pats USOS un tā komponenti ir
parakstīti ar **USOS atslēgu**, kas jāreģistrē **vienu reizi katrā
datorā**:

- **Visvienkāršāk:** izslēdziet Secure Boot, palaidiet zibatmiņu, sākuma
  ekrānā izvēlieties **Pievienot** un apstipriniet ar **Jā, saglabāt
  atslēgu**, tad atkal ieslēdziet Secure Boot. Tas darbojas arī Setup Mode
  (apstiprināts uz X470).
- **Neizslēdzot Secure Boot:** pie „Verification failed” izmantojiet
  MokManager -> **Enroll key from disk** -> `USOS_ESP` -> `USOS-KEY.cer`
  (apstiprināts uz ROG Ally). Instalētāja kartīte **Sagatavot (vienreiz)**
  liek MokManager gaidīt, nevis skaitīt laiku atpakaļ.

NVRAM atiestatīšana noņem atslēgu; reģistrējiet to vēlreiz. XP, Vista, 7,
visiem CSMWrap ceļiem, SystemRescue un rīkiem, kas palaisti no UEFI Shell,
Secure Boot jābūt izslēgtam. Kodols vēl nav bloķēts (ceļveža punkts N6),
tāpēc, reģistrējot USOS atslēgu, jūs uzticaties visam, kas ar to parakstīts.
Sīkāk:
[lietotāja rokasgrāmata, 6. sadaļa](../USER-GUIDE.en.md#6-secure-boot-and-the-usos-key-mok),
[secure-boot-usos.md](../secure-boot-usos.md).

<a id="answer-profiles"></a>
## 7. Atbilžu profili

Viens neliels profils (konti, datora nosaukums, valoda, laika josla,
izvēles pielāgojumi) startēšanas brīdī tiek pārvērsts par `WINNT.SIF`
(2000/XP/2003), `autounattend.xml` (no Vista līdz 11, Server) vai Ubuntu
autoinstall, Debian preseed vai Fedora kickstart. Profilus izveido UEFI
izvēlnē (**Automātiskā instalēšana** -> **+ Pievienot jaunu profilu**), un
tie tiek glabāti ESP.

![Atbilžu profila redaktors ar sadaļu Izskats un papildinājumi](../images/profile-editor-appearance.png)

- Mērķa disks **vienmēr tiek izvēlēts manuāli**; profils nekad neizvēlas un
  neizdzēš disku.
- Produkta atslēga tiek saglabāta tikai tad, ja atzīmējat „Atcerēties
  atslēgu šajā zibatmiņā”; citādi tā tiek glabāta tikai līdz restartēšanai.
  **USOS neietver atslēgas** un neapiet ne aktivizāciju, ne produkta
  atslēgas lapu.
- Paroles un atcerētās atslēgas zibatmiņā tiek glabātas kā vienkāršs
  teksts (sarakstos un žurnālos tās nekad netiek rādītas). Linux profili
  darbojas tikai UEFI režīmā.

Sīkāk: [lietotāja rokasgrāmata, 7. sadaļa](../USER-GUIDE.en.md#7-answer-profiles-and-tweaks),
[answer-profiles.md](../answer-profiles.md).

<a id="known-issues"></a>
## 8. Zināmās problēmas

- **Vista uz platēm tikai ar USB 3 (X470):** USB zibatmiņas instalētajā
  sistēmā nav redzamas, un Vista paliek testa režīmā (testa parakstīts
  USB 3 backport). Renesas uPD72020x PCIe karte novērš abas problēmas.
- **CSMWrap ceļi:** nepieciešama grafiskā karte ar legacy VBIOS (citādi
  melns ekrāns), aizņem vienu CPU pavedienu, nepieciešams MBR mērķa disks
  (tiek izdzēsts) un izslēgts Secure Boot.
- **Server 2003 x86 / XP x64:** STOP 0xA5 (ACPI) uz X470 un nav USB ievades
  uz platēm tikai ar xHCI.
- **Windows 2000** nedarbojas uz platēm tikai ar AHCI (nav NT 5.0 AHCI
  draivera); **XP** neatbalsta NVMe un BIOS režīmā nesaņem ne draiveru
  pakotni, ne PAE.
- **Secure Boot:** SystemRescue ir bloķēts (nav parakstīta ielādētāja); UEFI
  Shell nevar palaist rīkus; pēc BlackLotus DBX atjauninājuma vecāki
  Windows datu nesēji nestartē.
- **Linux:** Ubuntu Server instalētājs iepriekš atlasa lielāko disku, kas
  var būt USOS zibatmiņa; vienmēr pārbaudiet mērķi.
- **AMI aparātprogrammatūra** katru zibatmiņas nodalījumu rāda kā atsevišķu
  sāknēšanas ierakstu.
- Palīgsistēmai mikro-Linux nepieciešams x86-64 procesors un vismaz
  256 MiB RAM.

Pilns saraksts ar apiešanas risinājumiem un godīgs saraksts ar to, kas
**vēl nav pārbaudīts** uz aparatūras (piem., Windows Server 2008-2025,
Windows 8/8.1, Windows 10/11 ar Secure Boot uz aparatūras, oriģinālais
Windows 7 SP1 ISO caur PE10 donoru), ir
[laidiena piezīmēs](../release-notes-1.0.md#known-issues) (angļu valodā) un
[lietotāja rokasgrāmatas 9. un 10. sadaļā](../USER-GUIDE.en.md#9-known-issues-and-workarounds).

<a id="building"></a>
## 9. Būvēšana no pirmkoda

Būvēšana notiek sistēmā Windows. Pilni norādījumi:
[BUILDING.md](../BUILDING.md) (angļu valodā).

- `build.bat` uzbūvē pilnu laidienu (EFI programmu, mikro-Linux, BIOS
  kodolu, payload un `installer\USOS Installer.exe`) ar vienu builda
  identifikatoru (`BYYMMDD-HHMMSS-XXXXXXXX`). Tiek izmantots pārnēsājamais
  Zig no `tools/zig`; Go un Python jābūt `PATH`.
- `tools/tests/run.ps1` palaiž automātiskos testus, piem.,
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/tests/run.ps1 -Suite all`.
- `powershell -ExecutionPolicy Bypass -File tools\release\make_release.ps1`
  izveido laidiena failus mapē `zig-out\release-1.0\`.
- **Bezsaistes būvēšana:** izpakojiet `USOS-1.0.0-buildkit.zip`, iestatiet
  `USOS_BUILDKIT` uz izpakoto mapi `USOS-1.0.0-buildkit` un palaidiet
  `build.bat`; komplekts tiek pārbaudīts pret tā manifestu, un lejupielādes
  ir atspējotas.
- **Parakstīšanas atslēga:** Secure Boot (MOK) atslēga atrodas **ārpus
  repozitorija**, mapē `%APPDATA%\USOS\signing\` (`USOS_SIGNING_DIR` to
  pārraksta). Bez tās būvējums ir **neparakstīts** un startē tikai ar
  izslēgtu Secure Boot. Nekad neiekļaujiet atslēgu commit un nedalieties
  ar to.

Windows ISO, draiveri un citi trešo pušu datu nesēji nekad nav repozitorija
daļa.

<a id="licence"></a>
## 10. Licence

- USOS paša kods ir licencēts saskaņā ar **GNU General Public License
  3. vai jaunāku versiju** (GPL-3.0-or-later): skatiet
  [LICENSE](../../LICENSE) un [NOTICE](../../NOTICE). Copyright (C) 2026 The
  USOS Authors.
- Trešo pušu komponenti saglabā savas licences. Tās ir atsevišķas
  programmas, apkopotas zibatmiņā; skatiet `THIRD-PARTY-NOTICES.txt` un
  `LICENSES/` laidienā un [LICENSES-AUDIT.md](../LICENSES-AUDIT.md).
- Microsoft faili laidienā (atjauninājumu un draiveru faili, XP pakotņu
  faili, WinPE donors) tiek saglabāti saglabāšanas nolūkā, izplatīti tālāk
  uz uzturētāja paša risku, uz tiem neattiecas neviena USOS licence, un pēc
  tiesību īpašnieka pieprasījuma tie tiks noņemti.
- Ieguldījumi tiek pieņemti saskaņā ar [CONTRIBUTING.md](../../CONTRIBUTING.md)
  (vienkārša licences piešķiršana no ieguldītāja puses).

Windows, MS-DOS un saistītie nosaukumi ir Microsoft preču zīmes. USOS nav
saistīts ar Microsoft.

<a id="support"></a>
## 11. Atbalsts

- Jautājumi un kļūdu ziņojumi: GitHub issues. Lūdzu, pievienojiet
  [lietotāja rokasgrāmatas 11. sadaļā](../USER-GUIDE.en.md#11-troubleshooting-and-logs)
  aprakstītos žurnālus un pārbaudiet, vai tajos nav paroļu vai atslēgu.
- Maksas palīdzība uzstādīšanā uzņēmumiem pieejama pēc pieprasījuma; pagaidām
  sazinieties, izmantojot GitHub issues.
- Sponsorēšana: caur `.github/FUNDING.yml`, kad tas būs aizpildīts.

<a id="documentation"></a>
## 12. Dokumentācija

- Lietotāja rokasgrāmata: [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md)
- [Laidiena piezīmes 1.0](../release-notes-1.0.md) (angļu valodā)
- [Kā darbojas USOS](../HOW-IT-WORKS.md)
- [Būvēšana](../BUILDING.md)
- [Licenču audits](../LICENSES-AUDIT.md)
- [Laidiena 1.0 testa plāns](../RELEASE-TEST-1.0.md)
- [Ceļvedis](../ROADMAP.md) (poļu valodā) un [testu rezultāti](../../TESTING.md) (poļu valodā)
