# Universal Service OS (USOS) 1.0.0

> To je prevod. Zavezujoča je [angleška različica README](../../README.md).

**Jeziki:** [English](../../README.md) ·
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
Slovenščina ·
[Srpski (latinica)](README.sr-Latn.md) ·
[Svenska](README.sv.md) ·
[Türkçe](README.tr.md) ·
[Українська](README.uk.md)

## Vsebina

1. [Kaj je USOS](#what-usos-is)
2. [Zmožnosti](#features)
3. [Podprti sistemi in načini vdelane programske opreme](#supported-systems)
4. [Hiter začetek](#quick-start)
5. [Razporeditev map na DATA](#data-layout)
6. [Secure Boot](#secure-boot)
7. [Profili odgovorov](#answer-profiles)
8. [Znane težave](#known-issues)
9. [Gradnja iz izvorne kode](#building)
10. [Licenca](#licence)
11. [Podpora](#support)
12. [Dokumentacija](#documentation)

<a id="what-usos-is"></a>
## 1. Kaj je USOS

USOS je en sam USB-ključek za namestitev in zagon operacijskih sistemov od
MS-DOS do Windows 11 in Linuxa na računalnikih z BIOS-om in z UEFI, tudi
z UEFI z vklopljenim Secure Boot. Lastne slike ISO na ključek kopirate kot
običajne datoteke; USOS vam da en meni, izrecno in zavarovano izbiro ciljnega
diska ter gonilnike in popravke, ki jih stari sistemi potrebujejo na novi
strojni opremi. Ključek pripravite v sistemu Windows s programom
`USOS-Installer-1.0.0.exe`. USOS ne vsebuje slik Windows, ključev izdelka
niti ničesar, kar bi obšlo aktivacijo.

![Meni UEFI USOS, domači zaslon](../images/menu-home.png)

<a id="features"></a>
## 2. Zmožnosti

- **En meni za BIOS in UEFI.** Isti ključek se zažene v načinu Legacy BIOS
  in v UEFI (x64) z enakim katalogom. Meni UEFI deluje s tipkovnico, miško,
  zaslonom na dotik in igralnimi ploščki USB.
- **Slike ostanejo datoteke.** Slike ISO, WIM, IMG, VHD, VHDX in EFI se
  berejo neposredno z razdelka NTFS DATA; nič se ne razpakira in po
  kopiranju ni treba ničesar zagnati.
- **Zavarovan ciljni disk.** Disk vedno izberete in potrdite sami; sam
  ključek USOS se nikoli ne ponudi.
- **Secure Boot** prek shim 16.1 (podpisal ga je Microsoft) in ključa USOS
  (MOK), ki se na vsakem računalniku vpiše enkrat.
- **Stari Windows na novi strojni opremi.** Windows XP s paketom gonilnikov
  in PAE v UEFI s CSM; XP in Vista v UEFI brez CSM prek CSMWrap
  (eksperimentalno); Windows 7 x64 brez CSM prek UefiSeven in dispečerja za
  usmerjanje VGA; integracija USB 3 in NVMe za Windows 7.
- **Profili odgovorov** za nenadzorovane namestitve Windows in Linuxa, ki jih
  urejate v meniju UEFI z zaslonsko tipkovnico.
- **Slike ISO Linuxa z DATA** (Ubuntu, Mint, Fedora, Debian, SystemRescue,
  GParted, Clonezilla in drugi) v UEFI s Secure Boot in brez njega ter
  v BIOS-u.
- **Orodja:** vgrajeni FreeDOS z upraviteljem datotek in ploščo Hardware &
  SMART (BIOS), lupina UEFI iz EDK2 (UEFI), lastna zagonska orodja
  v `Utilities`, lastni gonilniki UEFI in mape z gonilniki INF za Windows.
- **Namestitveni program s štirimi načini:** Namestitev, Lokalna posodobitev
  (**Posodobi USOS**, ohrani slike in vaše datoteke), Popravilo (**Popravi
  ESP**), Odstranitev.
- **27 jezikov** (referenčna je angleščina; drugi jeziki razen poljščine so
  označeni kot delno ali v celoti strojno prevedeni), teme z urejevalnikom
  v meniju, podpora za dotik in igralni plošček na ROG Ally.

| | |
|---|---|
| ![Seznam sistemov Windows z oznakami stanja](../images/windows-list.png) | ![Seznam distribucij Linuxa](../images/linux-list.png) |
| Sistemi Windows z oznakami stanja | Slike ISO Linuxa z DATA |
| ![Meni Legacy BIOS](../images/bios-menu.png) | ![Vgrajene in uporabniške teme](../images/themes-grid.png) |
| Meni Legacy BIOS | Teme: Dark, Light, Retro, Sunset |

<a id="supported-systems"></a>
## 3. Podprti sistemi in načini vdelane programske opreme

**HW** = preizkušeno na resnični strojni opremi, **VM** = preizkušeno samo
v QEMU/VirtualBox, **eksp.** = eksperimentalno (v meniju tako označeno),
**nepreizkušeno** = pot obstaja, vendar ni zabeleženega zagona, **—** = ni
podprto (meni navede razlog). Preizkusni računalniki: **X470** (ASRock X470,
Ryzen 7 5700X, Radeon RX 560, UEFI), **MS-7100** (MSI, Socket 939, Athlon 64
X2, BIOS), **Ally** (ASUS ROG Ally RC71L, UEFI s Secure Boot).

| Sistem | BIOS (Legacy) | UEFI + CSM | UEFI brez CSM (CSMWrap) | Secure Boot vklopljen |
|---|---|---|---|---|
| Sam meni USOS | HW | HW | HW | HW (X470, Ally) |
| MS-DOS 6.22, Windows 3.1/3.11 | HW (Windows 3.1 v standardnem načinu, MS-7100) | — | — | — |
| Windows 98 SE | VM; HW delno (MS-7100: Setup do priprave prvega zagona, namizje ni potrjeno) | — | — | — |
| Windows 2000 SP4 | HW (MS-7100) | eksp., VM (do kopiranja datotek) | eksp., VM (CSMWrap) | — |
| Windows XP x86 SP3 | VM (brez paketa gonilnikov, brez PAE) | HW (X470: paket gonilnikov, PAE, 31,9 GB) | eksp., HW (X470, CSMWrap) | — |
| Windows XP x64 SP2 | nepreizkušeno | eksp., VM (do GUI Setup); X470: STOP 0xA5 | eksp., VM (CSMWrap) | — |
| Windows Server 2003 R2 SP2 x86 | nepreizkušeno | eksp., VM (do GUI Setup); X470 z 1.0 nepreizkušeno | eksp., VM (CSMWrap) | — |
| Windows Vista SP2 x64 | HW (MS-7100) | HW (X470) | eksp., HW (X470, CSMWrap, legacy MBR) | — |
| Windows 7 SP1 x64 | HW (MS-7100) | VM (celotna namestitev) | HW (X470, UefiSeven + dispečer) | — |
| Windows 8 / 8.1 | nepreizkušeno | nepreizkušeno | nepreizkušeno | nepreizkušeno |
| Windows 10 | HW (x86, MS-7100) | HW (x64, X470) | izvorni UEFI, ista pot kot s CSM | VM (do nalagalnika Windows) |
| Windows 11 | nepreizkušeno | HW (poročilo uporabnika) | izvorni UEFI, ista pot kot s CSM | VM (do nalagalnika Windows) |
| Windows Server 2008 - 2025 | eksp., nikoli zagnano | eksp., nikoli zagnano | eksp., nikoli zagnano | 2008/2008 R2: —; 2012+: nepreizkušeno |
| Slike ISO Linuxa (Ubuntu, Mint, Fedora, Debian, GParted, Clonezilla) | VM; HW Mint live (MS-7100) | HW (X470: Mint, Fedora, Debian netinst, Clonezilla, GParted) | enako kot s CSM | HW Fedora, Mint (X470); ostalo VM |
| SystemRescue | VM | HW (X470) | enako kot s CSM | — (ni podpisanega zagonskega nalagalnika) |
| FreeDOS, Hardware & SMART (vgrajeno) | VM (FreeDOS); HW (Hardware & SMART) | — | — | — |
| MemTest86+ (ISO i586, priskrbite ga sami) | HW | različica `.efi` iz `Utilities` (nepreizkušeno) | kot s CSM | samo podpisan `.efi` |
| Lupina UEFI (vgrajena) | — | VM | VM | VM (se zažene, vendar ne more zagnati orodij) |

UEFI s CSM ali brez njega je pomemben le za starejše (legacy) poti (2000,
XP, 2003, Vista, 7); vsi drugi vnosi UEFI v obeh načinih izvajajo isto kodo.
Windows XP, Vista in 7 ter vse poti prek CSMWrap zahtevajo izklopljen Secure
Boot. Celotna tabela z opombami in rezultati na strojni opremi za
posamezne gradnje je v
[uporabniškem priročniku, poglavje 5](../USER-GUIDE.en.md#5-what-works-in-which-firmware-mode)
in v [opombah ob izdaji](../release-notes-1.0.md#supported-systems)
(v angleščini).

<a id="quick-start"></a>
## 4. Hiter začetek

Datoteke izdaje:

**Ne veste, katerega? Prenesite polni namestitveni program.**

| Datoteka | Namen |
|---|---|
| `USOS-Installer-1.0.0.exe` | **Polni namestitveni program**: celoten USOS z darovalcem WinPE in obema paketoma XP; deluje brez povezave |
| `USOS-Installer-1.0.0-online.exe` | **Spletni namestitveni program**: majhen prenos; po potrebi prenese darovalca WinPE in pakete XP iz te izdaje in jih preveri |
| `USOS-1.0.0-WinPE-PE10-donor.zip` | darovalec PE10, potreben za Visto in izvirne slike ISO Windows 7 v UEFI |
| `USOS-1.0.0-XP-package-PL.zip`, `USOS-1.0.0-XP-package-EN.zip` | paket UEFI za Windows XP x86 SP3, vsak za natanko eno izvirno sliko ISO (`pl_..._x14-80476.iso` / `en_..._x14-80428.iso`), namesti se s priloženim skriptom `install-xp-package.ps1` |
| `USOS-1.0.0-sources.zip` + `SOURCE-OFFER.txt` | izvorna koda komponent tretjih oseb in pisna ponudba izvorne kode |
| `USOS-1.0.0-buildkit.zip` | pripeta orodja in vhodi gradnje za gradnjo brez povezave |
| `LICENSES/`, `THIRD-PARTY-NOTICES.txt` | besedila licenc in obvestila |
| `SHA256SUMS` | SHA-256 vsake datoteke |

Preneseno datoteko preverite z ukazom
`certutil -hashfile USOS-Installer-1.0.0.exe SHA256` (ali `Get-FileHash`
v PowerShellu) glede na `SHA256SUMS`.

![Namestitveni program USOS: izbira operacije](../images/installer-mode.png)

1. Priskrbite si USB-ključek z zmogljivostjo **vsaj 32 GiB** (v praksi
   64 GB; ključek, ki se prodaja kot „32 GB“, je navadno premajhen).
   **Vse na njem bo izbrisano.**
2. Na računalniku z Windows zaženite `USOS-Installer-1.0.0.exe` (zahteva
   skrbniške pravice), izberite **Namestitev**, izberite ključek, vpišite
   potrditveno besedilo in kliknite **IZBRIŠI IN NAMESTI**.
3. Slike ISO kopirajte na razdelek DATA v mapo `Images` ustreznega sistema,
   npr. `Systems\Windows\Windows 11\Images\`.
4. Po želji: za Visto ali izvirni Windows 7 v UEFI kopirajte mapo `Programs`
   iz arhiva darovalca PE10 v korensko mapo DATA in zaženite **Posodobi
   USOS**; za XP v UEFI kot skrbnik zaženite `install-xp-package.ps1`
   iz paketa XP, ki ustreza vaši sliki ISO (vedno samo en paket naenkrat).
5. Ciljni računalnik zaženite s ključka (BIOS ali UEFI). Pri vklopljenem
   Secure Boot enkrat vpišite ključ USOS ([Secure Boot](#secure-boot)).
   Izberite sistem in sliko, po želji profil odgovorov, potrdite ciljni disk
   in sledite namestitvenemu programu sistema.

Navodila po korakih za vsak zaslon so v uporabniškem priročniku:
[English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md).

<a id="data-layout"></a>
## 5. Razporeditev map na DATA

Namestitveni program na ključku ustvari tri razdelke: `USOS_ESP` (FAT32,
1 GiB: zagonske datoteke, ključ, nastavitve, dnevniki, profili), `USOS_DATA`
(NTFS: vaše datoteke) in `USOS_WORK` (NTFS, delovni prostor za nekatere
namestitvene programe Windows). Vse mape na DATA se ustvarijo samodejno:

```
USOS_DATA\
├─ Systems\
│  ├─ Windows\<različica>\  Images\  Unattended\   (Windows 3.1 do 11, Server 2003-2025)
│  ├─ Linux\<distribucija>\ Images\  Unattended\   (Other Linux\ za neznane slike ISO)
│  ├─ Betas\
│  └─ DOS\<izvedba>\        Images\
├─ Utilities\
│  ├─ FreeDOS\Programs\     programi DOS za vgrajeni FreeDOS
│  ├─ UEFI Shell\Tools\     orodja EFI za lupino UEFI
│  └─ <vaše orodje>\Images\   npr. MemTest86\Images\memtest86.efi
├─ Drivers\
│  ├─ UEFI\<ime>\           gonilniki .efi, ki jih naloži meni USOS
│  └─ <različica Windows>\  Storage\  USB\  Other\  (paketi INF)
├─ Themes\<ime>\theme.ini   lastne teme (meni UEFI)
└─ Programs\
   └─ USOS\                 upravlja USOS (darovalec PE10), ne spreminjajte
```

Ko dodate datoteko `icon.png` ali novo mapo z orodjem, zaženite **Posodobi
USOS**. Celotno drevo je v
[uporabniškem priročniku, poglavje 4](../USER-GUIDE.en.md#4-folder-layout-on-data).

<a id="secure-boot"></a>
## 6. Secure Boot

Pri vklopljenem Secure Boot se USOS zažene prek **shim 16.1** (gradnja
Fedore, podpisana z Microsoft UEFI CA) in MokManagerja. Sam USOS in njegove
komponente so podpisani s **ključem USOS**, ki se vpiše **enkrat na vsakem
računalniku**:

- **Najpreprosteje:** izklopite Secure Boot, zaženite ključek, na domačem
  zaslonu izberite **Dodaj** in potrdite z **Da, shrani ključ**, nato Secure
  Boot spet vklopite. To deluje tudi v načinu Setup Mode (potrjeno na X470).
- **Z vklopljenim Secure Boot:** na zaslonu „Verification failed“ v
  MokManagerju uporabite **Enroll key from disk** -> `USOS_ESP` ->
  `USOS-KEY.cer` (potrjeno na ROG Ally). Možnost **Pripravi (enkratno)** na
  kartici Secure Boot v namestitvenem programu poskrbi, da MokManager čaka,
  namesto da odšteva čas.

Ponastavitev NVRAM ključ odstrani; takrat ga vpišite znova. XP, Vista, 7,
vse poti prek CSMWrap, SystemRescue in orodja, zagnana iz lupine UEFI,
zahtevajo izklopljen Secure Boot. Jedro še ni zaklenjeno (točka N6 načrta
razvoja), zato z vpisom ključa USOS zaupate vsemu, kar je z njim podpisano.
Podrobnosti:
[uporabniški priročnik, poglavje 6](../USER-GUIDE.en.md#6-secure-boot-and-the-usos-key-mok),
[secure-boot-usos.md](../secure-boot-usos.md).

<a id="answer-profiles"></a>
## 7. Profili odgovorov

En majhen profil (računi, ime računalnika, jezik, časovni pas, izbirne
prilagoditve) se ob zagonu pretvori v `WINNT.SIF` (2000/XP/2003),
`autounattend.xml` (Vista do 11, Server) ali v Ubuntu autoinstall, Debian
preseed oziroma Fedora kickstart. Profile ustvarite v meniju UEFI
(**Nenadzorovana namestitev** -> **+ Dodaj nov profil**), shranijo pa se na
ESP.

![Urejevalnik profila odgovorov z razdelkom za videz in dodatke](../images/profile-editor-appearance.png)

- Ciljni disk se **vedno izbere ročno**; profil nikoli ne izbere ali izbriše
  diska.
- Ključ izdelka se shrani samo, če označite „Zapomni si ključ na tem
  ključku“; sicer ostane v spominu le do ponovnega zagona. **USOS ne vsebuje
  ključev** in ne obide aktivacije ali strani s ključem izdelka.
- Gesla in zapomnjeni ključi so na ključku shranjeni kot navadno besedilo
  (nikoli niso prikazani v seznamih ali dnevnikih). Profili za Linux delujejo
  samo v UEFI.

Podrobnosti: [uporabniški priročnik, poglavje 7](../USER-GUIDE.en.md#7-answer-profiles-and-tweaks),
[answer-profiles.md](../answer-profiles.md).

<a id="known-issues"></a>
## 8. Znane težave

- **Vista na ploščah samo z USB 3 (X470):** USB-ključki v nameščenem
  sistemu niso vidni, Vista pa ostane v preizkusnem načinu (preizkusno
  podpisan backport USB 3). Obojemu se izognete s kartico PCIe Renesas
  uPD72020x.
- **Poti prek CSMWrap:** potrebujejo grafično kartico s starejšim (legacy)
  VBIOS-om (sicer je zaslon črn), zasedejo eno nit CPE, potrebujejo ciljni
  disk MBR (se izbriše) in izklopljen Secure Boot.
- **Server 2003 x86 / XP x64:** STOP 0xA5 (ACPI) na X470 in ni vnosa prek
  USB na ploščah samo z xHCI.
- **Windows 2000** ne deluje na ploščah samo z AHCI (ni gonilnika AHCI za
  NT 5.0); **XP** ne podpira NVMe in v načinu BIOS ne dobi paketa gonilnikov
  niti PAE.
- **Secure Boot:** SystemRescue je blokiran (ni podpisanega nalagalnika);
  lupina UEFI ne more zagnati orodij; po posodobitvi DBX zaradi BlackLotus se
  starejši nosilci Windows ne zaženejo.
- **Linux:** namestitveni program Ubuntu Server vnaprej izbere največji disk,
  ki je lahko ključek USOS; vedno preverite ciljni disk.
- **Vdelana programska oprema AMI** prikaže vsak razdelek ključka kot
  samostojen zagonski vnos.
- Pomožni mikro-Linux potrebuje procesor x86-64 in vsaj 256 MiB RAM.

Celoten seznam z zaobidnimi rešitvami in pošten seznam tega, kar na strojni
opremi še **ni bilo preizkušeno** (npr. Windows Server 2008-2025, Windows
8/8.1, Windows 10/11 s Secure Boot na strojni opremi, izvirna slika ISO
Windows 7 SP1 prek darovalca PE10), sta v
[opombah ob izdaji](../release-notes-1.0.md#known-issues) (v angleščini) in
v [uporabniškem priročniku, poglavji 9 in 10](../USER-GUIDE.en.md#9-known-issues-and-workarounds).

<a id="building"></a>
## 9. Gradnja iz izvorne kode

Gradnja teče v sistemu Windows. Celotna navodila:
[BUILDING.md](../BUILDING.md) (v angleščini).

- `build.bat` zgradi celotno izdajo (program EFI, mikro-Linux, jedro BIOS,
  payload in `installer\USOS Installer.exe`) z enim identifikatorjem gradnje
  (`BYYMMDD-HHMMSS-XXXXXXXX`). Uporabi se prenosni Zig iz `tools/zig`; Go
  in Python morata biti v `PATH`.
- `tools/tests/run.ps1` zažene samodejne teste, npr.
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/tests/run.ps1 -Suite all`.
- `powershell -ExecutionPolicy Bypass -File tools\release\make_release.ps1`
  ustvari datoteke izdaje v `zig-out\release-1.0\`.
- **Gradnja brez povezave:** razpakirajte `USOS-1.0.0-buildkit.zip`,
  nastavite `USOS_BUILDKIT` na razpakirano mapo `USOS-1.0.0-buildkit` in
  zaženite `build.bat`; komplet se preveri glede na svoj manifest, prenosi pa
  so onemogočeni.
- **Ključ za podpisovanje:** ključ Secure Boot (MOK) je **zunaj
  repozitorija**, v `%APPDATA%\USOS\signing\` (spremenljivka
  `USOS_SIGNING_DIR` to mesto preglasi). Brez njega je gradnja
  **nepodpisana** in se zažene le z izklopljenim Secure Boot. Ključa nikoli
  ne commitajte in ga ne delite.

Slike ISO Windows, gonilniki in drugi nosilci tretjih oseb nikoli niso del
repozitorija.

<a id="licence"></a>
## 10. Licenca

- Lastna koda USOS je licencirana pod **GNU General Public License,
  različica 3 ali novejša** (GPL-3.0-or-later): glejte [LICENSE](../../LICENSE)
  in [NOTICE](../../NOTICE). Copyright (C) 2026 Maksymilian and the USOS Authors.
- Komponente tretjih oseb ohranijo svoje licence. To so ločeni programi,
  zbrani na ključku; glejte `THIRD-PARTY-NOTICES.txt` in `LICENSES/`
  v izdaji ter [LICENSES-AUDIT.md](../LICENSES-AUDIT.md).
- Datoteke Microsofta v izdaji (datoteke posodobitev in gonilnikov, datoteke
  v paketih XP, darovalec WinPE) so ohranjene za arhivske namene, razširjajo
  se na lastno odgovornost vzdrževalca, zanje ne velja nobena licenca USOS in
  bodo na zahtevo imetnika pravic odstranjene.
- Prispevki se sprejemajo pod pogoji iz [CONTRIBUTING.md](../../CONTRIBUTING.md)
  (preprosta podelitev licence s strani avtorja prispevka).

Windows, MS-DOS in sorodna imena so blagovne znamke družbe Microsoft. USOS ni
povezan z družbo Microsoft.

<a id="support"></a>
## 11. Podpora

- Vprašanja in prijave napak: GitHub Issues. Priložite dnevnike, opisane
  v [uporabniškem priročniku, poglavje 11](../USER-GUIDE.en.md#11-troubleshooting-and-logs),
  in preverite, da ne vsebujejo gesel ali ključev.
- Plačljiva pomoč pri uvedbi za podjetja je na voljo na zahtevo; za zdaj se
  obrnite prek GitHub Issues.
- Sponzoriranje: prek `.github/FUNDING.yml`, ko bo izpolnjen.

<a id="documentation"></a>
## 12. Dokumentacija

- Uporabniški priročnik: [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md)
- [Opombe ob izdaji 1.0](../release-notes-1.0.md) (v angleščini)
- [Kako deluje USOS](../HOW-IT-WORKS.md)
- [Gradnja](../BUILDING.md)
- [Revizija licenc](../LICENSES-AUDIT.md)
- [Načrt preizkusa izdaje 1.0](../RELEASE-TEST-1.0.md)
- [Načrt razvoja](../ROADMAP.md) (v poljščini) in [rezultati preizkusov](../../TESTING.md) (v poljščini)
