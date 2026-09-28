# Universal Service OS (USOS) 1.0.0

> Aceasta este o traducere. Versiunea de referință este [README-ul în engleză](../../README.md).

**Limbi:** [English](../../README.md) ·
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
Română ·
[Русский](README.ru.md) ·
[Slovenčina](README.sk.md) ·
[Slovenščina](README.sl.md) ·
[Srpski (latinica)](README.sr-Latn.md) ·
[Svenska](README.sv.md) ·
[Türkçe](README.tr.md) ·
[Українська](README.uk.md)

## Cuprins

1. [Ce este USOS](#what-usos-is)
2. [Funcționalități](#features)
3. [Sisteme acceptate și moduri de firmware](#supported-systems)
4. [Pornire rapidă](#quick-start)
5. [Structura folderelor pe DATA](#data-layout)
6. [Secure Boot](#secure-boot)
7. [Profiluri de răspuns](#answer-profiles)
8. [Probleme cunoscute](#known-issues)
9. [Compilarea din surse](#building)
10. [Licență](#licence)
11. [Asistență](#support)
12. [Documentație](#documentation)

<a id="what-usos-is"></a>
## 1. Ce este USOS

USOS este un singur stick USB pentru instalarea și pornirea sistemelor de
operare, de la MS-DOS la Windows 11 și Linux, pe calculatoare cu BIOS și
UEFI, inclusiv UEFI cu Secure Boot. Vă copiați propriile imagini ISO pe
stick ca pe niște fișiere obișnuite; USOS vă oferă un singur meniu, o
alegere explicită și protejată a discului țintă, precum și driverele și
corecțiile de care sistemele vechi au nevoie pe hardware nou. Stickul se
pregătește în Windows cu `USOS-Installer-1.0.0.exe`. USOS nu include
imagini Windows, chei de produs și nici vreo ocolire a activării.

![Meniul UEFI USOS, ecranul principal](../images/menu-home.png)

<a id="features"></a>
## 2. Funcționalități

- **Un singur meniu, BIOS și UEFI.** Același stick pornește în Legacy BIOS
  și în UEFI (x64), cu același catalog. Meniul UEFI funcționează cu
  tastatura, mouse-ul, ecranul tactil și gamepad-uri USB.
- **Imaginile rămân fișiere.** Imaginile ISO, WIM, IMG, VHD, VHDX și EFI
  sunt citite direct de pe partiția NTFS DATA; nimic nu se extrage și nimic
  nu trebuie rulat după copiere.
- **Disc țintă protejat.** Alegeți și confirmați întotdeauna discul;
  stickul USOS însuși nu este oferit niciodată.
- **Secure Boot** prin shim 16.1 (semnat de Microsoft) și cheia USOS (MOK),
  înregistrată o singură dată pe fiecare calculator.
- **Windows vechi pe hardware nou.** Windows XP cu pachet de drivere și PAE
  pe UEFI cu CSM; XP și Vista pe UEFI fără CSM prin CSMWrap
  (experimental); Windows 7 x64 fără CSM prin UefiSeven și un dispecer de
  rutare VGA; integrare USB 3 și NVMe pentru Windows 7.
- **Profiluri de răspuns** pentru instalări nesupravegheate de Windows și
  Linux, editate în meniul UEFI cu o tastatură pe ecran.
- **ISO-uri Linux de pe DATA** (Ubuntu, Mint, Fedora, Debian,
  SystemRescue, GParted, Clonezilla și altele), pe UEFI cu și fără Secure
  Boot și pe BIOS.
- **Instrumente:** FreeDOS integrat cu manager de fișiere și un panou
  Hardware & SMART (BIOS), EDK2 UEFI Shell (UEFI), propriile instrumente
  bootabile în `Utilities`, propriile drivere UEFI și foldere cu drivere INF
  pentru Windows.
- **Program de instalare cu patru moduri:** Instalare, Actualizare locală
  (**Actualizează USOS**, păstrează imaginile și fișierele dvs.), Reparare
  (**Repară ESP**), Dezinstalare.
- **27 de limbi** (engleza este referința; celelalte limbi, cu excepția
  polonei, sunt marcate ca traduse automat parțial sau integral), teme cu
  editor în meniu, suport pentru ecran tactil și gamepad pe ROG Ally.

| | |
|---|---|
| ![Lista sistemelor Windows cu insigne de stare](../images/windows-list.png) | ![Lista distribuțiilor Linux](../images/linux-list.png) |
| Sisteme Windows cu insigne de stare | ISO-uri Linux de pe DATA |
| ![Meniul Legacy BIOS](../images/bios-menu.png) | ![Teme integrate și ale utilizatorului](../images/themes-grid.png) |
| Meniul Legacy BIOS | Teme: Dark, Light, Retro, Sunset |

<a id="supported-systems"></a>
## 3. Sisteme acceptate și moduri de firmware

**HW** = testat pe hardware real, **VM** = testat doar în QEMU/VirtualBox,
**exp.** = experimental (marcat astfel în meniu), **netestat** = ruta
există, dar nu este înregistrată nicio rulare, **—** = neacceptat (meniul
afișează motivul). Calculatoare de test: **X470** (ASRock X470, Ryzen 7
5700X, Radeon RX 560, UEFI), **MS-7100** (MSI, Socket 939, Athlon 64 X2,
BIOS), **Ally** (ASUS ROG Ally RC71L, UEFI cu Secure Boot).

| Sistem | BIOS (Legacy) | UEFI + CSM | UEFI fără CSM (CSMWrap) | Secure Boot activat |
|---|---|---|---|---|
| Meniul USOS însuși | HW | HW | HW | HW (X470, Ally) |
| MS-DOS 6.22, Windows 3.1/3.11 | HW (Windows 3.1 în modul standard, MS-7100) | — | — | — |
| Windows 98 SE | VM; HW parțial (MS-7100: Setup până la pregătirea primei porniri, desktop neconfirmat) | — | — | — |
| Windows 2000 SP4 | HW (MS-7100) | exp., VM (până la copierea fișierelor) | exp., VM (CSMWrap) | — |
| Windows XP x86 SP3 | VM (fără pachet de drivere, fără PAE) | HW (X470: pachet de drivere, PAE, 31,9 GB) | exp., HW (X470, CSMWrap) | — |
| Windows XP x64 SP2 | netestat | exp., VM (până la GUI Setup); X470: STOP 0xA5 | exp., VM (CSMWrap) | — |
| Windows Server 2003 R2 SP2 x86 | netestat | exp., VM (până la GUI Setup); X470 netestat cu 1.0 | exp., VM (CSMWrap) | — |
| Windows Vista SP2 x64 | HW (MS-7100) | HW (X470) | exp., HW (X470, CSMWrap, legacy MBR) | — |
| Windows 7 SP1 x64 | HW (MS-7100) | VM (instalare completă) | HW (X470, UefiSeven + dispecer) | — |
| Windows 8 / 8.1 | netestat | netestat | netestat | netestat |
| Windows 10 | HW (x86, MS-7100) | HW (x64, X470) | UEFI nativ, aceeași rută ca cu CSM | VM (până la încărcătorul Windows) |
| Windows 11 | netestat | HW (raport de la utilizator) | UEFI nativ, aceeași rută ca cu CSM | VM (până la încărcătorul Windows) |
| Windows Server 2008 - 2025 | exp., nepornit niciodată | exp., nepornit niciodată | exp., nepornit niciodată | 2008/2008 R2: —; 2012+: netestat |
| ISO-uri Linux (Ubuntu, Mint, Fedora, Debian, GParted, Clonezilla) | VM; HW Mint live (MS-7100) | HW (X470: Mint, Fedora, Debian netinst, Clonezilla, GParted) | la fel ca cu CSM | HW Fedora, Mint (X470); VM restul |
| SystemRescue | VM | HW (X470) | la fel ca cu CSM | — (fără încărcător de boot semnat) |
| FreeDOS, Hardware & SMART (integrate) | VM (FreeDOS); HW (Hardware & SMART) | — | — | — |
| MemTest86+ (ISO i586, îl furnizați dvs.) | HW | varianta `.efi` din `Utilities` (netestat) | ca cu CSM | doar `.efi` semnat |
| UEFI Shell (integrat) | — | VM | VM | VM (pornește, dar nu poate lansa instrumente) |

UEFI cu sau fără CSM contează doar pentru rutele legacy (2000, XP, 2003,
Vista, 7); orice altă intrare UEFI rulează același cod în ambele moduri.
Windows XP, Vista și 7 și fiecare rută CSMWrap necesită Secure Boot
dezactivat. Matricea completă cu note și rezultatele pe hardware pentru
fiecare build se află în
[ghidul utilizatorului, secțiunea 5](../USER-GUIDE.en.md#5-what-works-in-which-firmware-mode)
și în [notele de lansare](../release-notes-1.0.md#supported-systems) (în
engleză).

<a id="quick-start"></a>
## 4. Pornire rapidă

Fișierele lansării:

| Fișier | Scop |
|---|---|
| `USOS-Installer-1.0.0.exe` | programul de instalare; conține tot USOS |
| `USOS-1.0.0-WinPE-PE10-donor.zip` | donorul PE10, necesar pentru Vista și ISO-urile originale Windows 7 pe UEFI |
| `USOS-1.0.0-XP-package-PL.zip`, `USOS-1.0.0-XP-package-EN.zip` | pachet UEFI pentru Windows XP x86 SP3, fiecare pentru exact un ISO original (`pl_..._x14-80476.iso` / `en_..._x14-80428.iso`), instalat cu scriptul inclus `install-xp-package.ps1` |
| `USOS-1.0.0-sources.zip` + `SOURCE-OFFER.txt` | sursele componentelor terțe și oferta scrisă privind sursele |
| `USOS-1.0.0-buildkit.zip` | lanțuri de instrumente și intrări de build fixate, pentru o recompilare offline |
| `LICENSES/`, `THIRD-PARTY-NOTICES.txt` | textele licențelor și notificările |
| `SHA256SUMS` | SHA-256 pentru fiecare fișier |

Verificați un fișier descărcat cu
`certutil -hashfile USOS-Installer-1.0.0.exe SHA256` (sau cu `Get-FileHash`
în PowerShell), comparând rezultatul cu `SHA256SUMS`.

![Programul de instalare USOS: alegerea operației](../images/installer-mode.png)

1. Procurați un stick USB de **cel puțin 32 GiB** (în practică 64 GB; un
   stick vândut ca „32 GB” este de obicei prea mic). **Tot conținutul lui
   va fi șters.**
2. Pe un PC cu Windows rulați `USOS-Installer-1.0.0.exe` (cere drepturi de
   administrator), alegeți **Instalare**, selectați stickul, tastați textul
   de confirmare și faceți clic pe **ȘTERGE ȘI INSTALEAZĂ**.
3. Copiați imaginile ISO pe partiția DATA, în folderul `Images` al fiecărui
   sistem, de ex. `Systems\Windows\Windows 11\Images\`.
4. Opțional: pentru Vista sau Windows 7 original pe UEFI, copiați folderul
   `Programs` din arhiva zip a donorului PE10 în rădăcina DATA și rulați
   **Actualizează USOS**; pentru XP pe UEFI, rulați ca administrator
   `install-xp-package.ps1` din pachetul XP care corespunde ISO-ului dvs.
   (câte un singur pachet o dată).
5. Porniți PC-ul țintă de pe stick (BIOS sau UEFI). Cu Secure Boot activat,
   înregistrați o singură dată cheia USOS ([Secure Boot](#secure-boot)).
   Alegeți sistemul și imaginea, opțional un profil de răspuns, confirmați
   discul țintă și urmați programul de instalare al sistemului.

Instrucțiuni pas cu pas pentru fiecare ecran găsiți în ghidul
utilizatorului: [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md).

<a id="data-layout"></a>
## 5. Structura folderelor pe DATA

Programul de instalare creează stickul cu trei partiții: `USOS_ESP` (FAT32,
1 GiB: fișiere de boot, cheie, setări, jurnale, profiluri), `USOS_DATA`
(NTFS: fișierele dvs.) și `USOS_WORK` (NTFS, spațiu de lucru pentru unele
programe de instalare Windows). Toate folderele de pe DATA sunt create
automat:

```
USOS_DATA\
├─ Systems\
│  ├─ Windows\<versiune>\   Images\  Unattended\   (de la Windows 3.1 la 11, Server 2003-2025)
│  ├─ Linux\<distribuție>\  Images\  Unattended\   (Other Linux\ pentru ISO-uri necunoscute)
│  ├─ Betas\
│  └─ DOS\<variantă>\       Images\
├─ Utilities\
│  ├─ FreeDOS\Programs\     programe DOS pentru FreeDOS integrat
│  ├─ UEFI Shell\Tools\     instrumente EFI pentru UEFI Shell
│  └─ <instrumentul dvs.>\Images\   de ex. MemTest86\Images\memtest86.efi
├─ Drivers\
│  ├─ UEFI\<nume>\          drivere .efi încărcate de meniul USOS
│  └─ <versiune Windows>\   Storage\  USB\  Other\  (pachete INF)
├─ Themes\<nume>\theme.ini  temele dvs. (meniul UEFI)
└─ Programs\
   └─ USOS\                 gestionat de USOS (donor PE10), nu modificați
```

După ce adăugați un `icon.png` sau un folder nou pentru un instrument,
rulați **Actualizează USOS**. Arborele complet se află în
[ghidul utilizatorului, secțiunea 4](../USER-GUIDE.en.md#4-folder-layout-on-data).

<a id="secure-boot"></a>
## 6. Secure Boot

Cu Secure Boot activat, USOS pornește prin **shim 16.1** (build Fedora,
semnat de Microsoft UEFI CA) și MokManager. USOS însuși și componentele sale
sunt semnate cu **cheia USOS**, care se înregistrează **o singură dată pe
fiecare calculator**:

- **Cel mai simplu:** dezactivați Secure Boot, porniți de pe stick, alegeți
  **Adăugați** pe ecranul principal și confirmați cu **Da, salvați cheia**,
  apoi reactivați Secure Boot. Funcționează și în Setup Mode (confirmat pe
  X470).
- **Cu Secure Boot lăsat activat:** la „Verification failed” folosiți
  MokManager -> **Enroll key from disk** -> `USOS_ESP` -> `USOS-KEY.cer`
  (confirmat pe ROG Ally). Cardul **Pregătire (o singură dată)** din
  programul de instalare face ca MokManager să aștepte în loc să numere
  invers.

O resetare NVRAM elimină cheia; înregistrați-o din nou. XP, Vista, 7,
fiecare rută CSMWrap, SystemRescue și instrumentele pornite din UEFI Shell
necesită Secure Boot dezactivat. Kernelul nu este încă blocat (punctul N6
din foaia de parcurs), așa că înregistrarea cheii USOS înseamnă încredere în
tot ce este semnat cu ea. Detalii:
[ghidul utilizatorului, secțiunea 6](../USER-GUIDE.en.md#6-secure-boot-and-the-usos-key-mok),
[secure-boot-usos.md](../secure-boot-usos.md).

<a id="answer-profiles"></a>
## 7. Profiluri de răspuns

Un singur profil mic (conturi, numele calculatorului, limbă, fus orar,
ajustări opționale) este transformat la pornire în `WINNT.SIF`
(2000/XP/2003), `autounattend.xml` (de la Vista la 11, Server) sau în
autoinstall Ubuntu, preseed Debian ori kickstart Fedora. Profilurile se
creează în meniul UEFI (**Instalare nesupravegheată** -> **+ Adăugare
profil nou**) și se păstrează pe ESP.

![Editorul de profiluri de răspuns cu secțiunea Aspect și extra](../images/profile-editor-appearance.png)

- Discul țintă este **întotdeauna ales manual**; un profil nu selectează și
  nu șterge niciodată un disc.
- O cheie de produs este salvată doar dacă bifați „Reține cheia pe acest
  stick”; altfel este păstrată doar până la repornire. **USOS nu include
  chei** și nu ocolește activarea sau pagina pentru cheia de produs.
- Parolele și cheile reținute sunt stocate pe stick ca text simplu (nu sunt
  afișate niciodată în liste sau jurnale). Profilurile Linux funcționează
  doar pe UEFI.

Detalii: [ghidul utilizatorului, secțiunea 7](../USER-GUIDE.en.md#7-answer-profiles-and-tweaks),
[answer-profiles.md](../answer-profiles.md).

<a id="known-issues"></a>
## 8. Probleme cunoscute

- **Vista pe plăci doar cu USB 3 (X470):** stickurile USB nu sunt vizibile
  în sistemul instalat, iar Vista rămâne în modul de testare (backport USB 3
  semnat pentru test). O placă PCIe Renesas uPD72020x evită ambele
  probleme.
- **Rutele CSMWrap:** necesită o placă video cu VBIOS legacy (altfel ecranul
  rămâne negru), ocupă un fir de execuție al procesorului, necesită un disc
  țintă MBR (este șters) și Secure Boot dezactivat.
- **Server 2003 x86 / XP x64:** STOP 0xA5 (ACPI) pe X470 și fără intrare
  USB pe plăcile doar cu xHCI.
- **Windows 2000** nu funcționează pe plăcile doar cu AHCI (nu există driver
  AHCI pentru NT 5.0); **XP** nu acceptă NVMe și nu primește pachet de
  drivere și nici PAE în modul BIOS.
- **Secure Boot:** SystemRescue este blocat (fără încărcător semnat); UEFI
  Shell nu poate lansa instrumente; după actualizarea DBX pentru BlackLotus,
  suporturile Windows mai vechi nu pornesc.
- **Linux:** programul de instalare Ubuntu Server preselectează cel mai mare
  disc, care poate fi stickul USOS; verificați întotdeauna ținta.
- **Firmware-ul AMI** afișează fiecare partiție a stickului ca intrare de
  boot separată.
- Micro-Linuxul auxiliar necesită un procesor x86-64 și cel puțin 256 MiB
  RAM.

Lista completă cu soluții alternative și lista onestă a ceea ce **nu a fost
încă testat** pe hardware (de ex. Windows Server 2008-2025, Windows 8/8.1,
Windows 10/11 cu Secure Boot pe hardware, ISO-ul original Windows 7 SP1 prin
donorul PE10) se află în
[notele de lansare](../release-notes-1.0.md#known-issues) (în engleză) și în
[ghidul utilizatorului, secțiunile 9 și 10](../USER-GUIDE.en.md#9-known-issues-and-workarounds).

<a id="building"></a>
## 9. Compilarea din surse

Compilarea rulează pe Windows. Instrucțiuni complete:
[BUILDING.md](../BUILDING.md) (în engleză).

- `build.bat` compilează lansarea completă (programul EFI, micro-Linux,
  nucleul BIOS, payload-ul și `installer\USOS Installer.exe`) cu un singur
  identificator de build (`BYYMMDD-HHMMSS-XXXXXXXX`). Se folosește Zig-ul
  portabil din `tools/zig`; Go și Python trebuie să fie în `PATH`.
- `tools/tests/run.ps1` rulează testele automate, de ex.
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/tests/run.ps1 -Suite all`.
- `powershell -ExecutionPolicy Bypass -File tools\release\make_release.ps1`
  produce fișierele lansării în `zig-out\release-1.0\`.
- **Compilare offline:** extrageți `USOS-1.0.0-buildkit.zip`, setați
  `USOS_BUILDKIT` la folderul extras `USOS-1.0.0-buildkit` și rulați
  `build.bat`; kitul este verificat după manifestul său, iar descărcările
  sunt dezactivate.
- **Cheia de semnare:** cheia Secure Boot (MOK) se află **în afara
  depozitului**, în `%APPDATA%\USOS\signing\` (`USOS_SIGNING_DIR` o
  suprascrie). Fără ea, build-ul este **nesemnat** și pornește doar cu Secure
  Boot dezactivat. Nu faceți niciodată commit cu cheia și nu o partajați.

ISO-urile Windows, driverele și alte suporturi terțe nu fac niciodată parte
din depozit.

<a id="licence"></a>
## 10. Licență

- Codul propriu al USOS este licențiat sub **GNU General Public License,
  versiunea 3 sau ulterioară** (GPL-3.0-or-later): vedeți
  [LICENSE](../../LICENSE) și [NOTICE](../../NOTICE). Copyright (C) 2026 The
  USOS Authors.
- Componentele terțe își păstrează propriile licențe. Ele sunt programe
  separate, agregate pe stick; vedeți `THIRD-PARTY-NOTICES.txt` și
  `LICENSES/` din lansare și [LICENSES-AUDIT.md](../LICENSES-AUDIT.md).
- Fișierele Microsoft din lansare (fișiere de actualizare și de drivere,
  fișierele din pachetele XP, donorul WinPE) sunt păstrate în scop de
  conservare, redistribuite pe riscul propriu al întreținătorului, nu sunt
  acoperite de nicio licență USOS și vor fi eliminate la cererea
  deținătorului drepturilor.
- Contribuțiile sunt acceptate în condițiile din
  [CONTRIBUTING.md](../../CONTRIBUTING.md) (o acordare simplă de licență din
  partea contributorului).

Windows, MS-DOS și denumirile asociate sunt mărci comerciale ale Microsoft.
USOS nu este afiliat cu Microsoft.

<a id="support"></a>
## 11. Asistență

- Întrebări și raportări de erori: GitHub issues. Atașați jurnalele descrise
  în [ghidul utilizatorului, secțiunea 11](../USER-GUIDE.en.md#11-troubleshooting-and-logs)
  și verificați că nu conțin parole sau chei.
- Asistență plătită la configurare pentru firme este disponibilă la cerere;
  deocamdată, contactați-ne prin GitHub issues.
- Sponsorizare: prin `.github/FUNDING.yml`, după ce va fi completat.

<a id="documentation"></a>
## 12. Documentație

- Ghidul utilizatorului: [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md)
- [Note de lansare 1.0](../release-notes-1.0.md) (în engleză)
- [Cum funcționează USOS](../HOW-IT-WORKS.md)
- [Compilare](../BUILDING.md)
- [Auditul licențelor](../LICENSES-AUDIT.md)
- [Planul de testare a lansării 1.0](../RELEASE-TEST-1.0.md)
- [Foaia de parcurs](../ROADMAP.md) (în poloneză) și [rezultatele testelor](../../TESTING.md) (în poloneză)
