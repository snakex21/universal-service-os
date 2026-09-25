# Easy2Boot (E2B) a USOS — porównanie (2026-09-24)

Źródło: pendrive SanDisk z E2B, przejrzany **wyłącznie w trybie odczytu**
(Get-Disk/Get-Partition/Get-Volume, listowanie katalogów, odczyt plików
tekstowych, `fsutil file queryextents`). Nic nie zostało zapisane na nośniku,
żaden program z nośnika nie był uruchamiany. Dodatkowo dokumentacja
easy2boot.xyz (strona o instalacji Windows XP).

## 1. Nośnik

| Cecha | Wartość |
|---|---|
| Model | USB SanDisk 3.2Gen1, dysk 9, 123,0 GB (114,6 GiB) |
| Styl partycji | **MBR** |
| Partycja 1 | NTFS, etykieta `E2B`, 122,3 GB (51,3 GB wolne), aktywna, litera M: |
| Partycja 2 | FAT32 (typ 0x0C), etykieta `E2B_PTN2`, 707 MB, litera N: |
| Wersja E2B | **v2.21** (`\_ISO\e2b\grub\E2B.cfg`: `set VER=v2.21`), grub4dos 0.4.6 (`grldr`, 28.11.2022) |
| agFM | `agFM_version.txt` = **1.A3** (grub2 filemanager a1ive) |
| Ventoy (wewnątrz agFM) | **1.0.97** (`N:\grub\grub.cfg`) |
| Pliki | P1: **7545** plików / 66,1 GB; P2: **1559** plików; razem **9104** |

Foldery najwyższego poziomu P1: `_ISO` (7489 plików, 63,2 GB), `Windowsy
późniejsza konfiguracja` (34 pliki, 4,4 GB, prywatne dodatki użytkownika:
Delta City XP ISO, OneCoreAPI, sterowniki AMD dla Win7), `ventoy` (7 plików,
29,7 MB), `System Volume Information`. W katalogu głównym: `grldr`,
`menu.lst`, `autounattend.xml`/`unattend.xml`, `E2B Launcher.exe`,
skrypty `MAKE_E2B_USB_DRIVE`, `MAKE_THIS_DRIVE_CONTIGUOUS`, `QEMU_MENU_TEST`.

`_ISO`: `WINDOWS` (5100 plików, 63 GB — WIN7 4852, bo zawiera rozpakowany
"Windows 7 Image Updater"), `e2b` (1665 — silnik grub4dos, 25 folderów
językowych, DPMS 1428 plików), `docs` (687), `MAINMENU`, `UTILITIES`,
`UTILITIES_MEMTEST`, `DOS`; foldery `LINUX`, `WINPE`, `ANTIVIRUS`, `BACKUP`,
`AUTO`, `WIN` są puste. `MyE2B.cfg`: `LANG=POLISH`, `KBD_QWERTZ`, `NOHELPER=1`.

Największe pliki: Vista AIO NiKKA 11,1 GB, Win11 25H2 PL 8,0 GB, Windows7.iso
6,5 GB, Win11 23H2 6,3 GB, Win11 24H2 5,4 GB, Win8.1 NiKKA 4,9 GB,
Win10 Pro 4,5 GB, DELTA-CITY-XP 4,1 GB, tiny10 3,8 GB. XP w
`_ISO\WINDOWS\XP`: NiKKA SP3 SATA-v2 (833 MB), SP2 PL (592 MB), XP x64 SP2 EN
(475 MB) + przykładowe `EeePC.sif`/`.AUTO`, `XP_Blank_Unattend.txt`,
`WINPE_INST.TAG` (włączony wariant "XP przez WinPE").

Wszystkie sprawdzone ISO Windows (XP, 10, 11) mają **1 extent** — są
ciągłe, więc fragmentacja (klasyczna przyczyna błędów E2B) tu nie występuje.

### Komponenty rozruchu

- **BIOS/MBR:** MBR E2B → `grldr` (grub4dos 0.4.6) → `menu.lst` →
  `\_ISO\e2b\grub\menu.lst` (menu generowane skryptami `.g4b`, cache
  `FASTLOAD.MNU`). `menu.lst` odwołuje się do `menuefi.lst` dla grub4dos-UEFI,
  ale tego pliku **nie ma** — gałąź grub4dos-UEFI nie jest zainstalowana.
- **UEFI:** wyłącznie partycja 2 (FAT32). `\EFI\BOOT\BOOTX64.EFI` ma ten sam
  rozmiar co `BOOTX64.KAS` (1 198 512 B) → aktywny jest **shim podpisany
  przez Kaspersky** (menu `DisableKasperskyShim.mnu` przełącza go na
  `grubfmx64.efi`). Dalej agFM (`grubfmx64.efi`, `EFI\GRUBFM\bootx64.efi`),
  z którego startuje Ventoy (`ventoyx64.efi`, `ventoyia32.efi`), a także
  rEFInd, Clover, MemTest86, `SWITCH_x64.efi` i BOOTAA64/BOOTIA32/BOOTMIPS.
- **.imgPTN:** tylko dwa — `Passmark Memtest86 (MBR+UEFI).imgPTN23` i
  `e2b\grub\bsd.imgptn`. Żadnego Windows/XP jako .imgPTN.

## 2. Jak E2B obsługuje instalacje

### (a) Windows 10/11

- **BIOS:** grub4dos mapuje ISO (`isoboot.g4b`, `QRUN.g4b`), ładuje boot.wim
  i wstrzykuje `startupe2b.bat`/`winpeshl.ini` + ImDisk z
  `\_ISO\e2b\firadisk`. W WinPE skrypt `LOADISO.CMD` montuje ISO przez
  ImDisk, a Setup widzi je jak DVD. Plik `.xml` obok ISO (w WIN10/WIN11
  jest ~30 próbek: "skip TPM", "Allow Local Account", "ZZDANGER_Auto_WipeDisk0",
  "win10-11 best-ustawienia.xml") wybiera się z menu i E2B podaje go Setupowi
  jako `unattend`. `.key` = tylko klucz produktu.
- **WinHelper:** osobny mały pendrive z plikiem `\WinHelper` dla starszego
  Setupu, który nie widzi ISO na dysku "wymiennym". Tu wyłączony
  (`NOHELPER=1`), bo SanDisk jest typu Removable, a nowe E2B i tak używa ImDisk.
- **UEFI:** grub4dos nie działa, więc: shim → agFM → **Ventoy** (partycja 2),
  który montuje ISO z NTFS przez własny `ventoy_x64.efi` + `vtoyjump64.exe`
  w WinPE. Unattend w UEFI działa tylko przez `\ventoy\ventoy.json`
  (plugin `auto_install`) albo przez konwersję ISO do `.imgPTN` (FAT32,
  natywny rozruch UEFI po "przełączeniu" partycji) — czyli **inaczej niż w
  BIOS-owym menu E2B**. `.xml` z folderów WIN10/WIN11 nie są automatycznie
  używane przez Ventoy.

### (b) Windows XP

Metody w menu (`MenuWinInstall.lst`, polskie `STRINGS.txt`):

1. **Alt+1 "Instalacja XP - Krok 1"** — `XPStep1.g4b`: wybór ISO, opcjonalnie
   `.AUTO`→`WINNT.SIF`, budowa dwóch wirtualnych dyskietek F6
   (FiraDisk + WinVBlock, opcjonalnie sterownik AHCI z DPMS), mapowanie ISO
   przez grub4dos i start `SETUPLDR` — faza tekstowa kopiuje pliki na HDD.
2. **Alt+2 / Alt+3 "Krok 2"** — ponowny rozruch **z pendrive'a do E2B**, ISO
   ładowane do RAM (>512 MB) albo mapowane bezpośrednio dla WinVBlock (mało
   RAM), faza GUI instalacji z dostępem do ISO przez sterownik FiraDisk/WinVBlock.
3. **X "Instalacja XP z użyciem WinPE"** (włączona przez `WINPE_INST.TAG`) —
   WinNTSetup z WinPE; potrzebny dodatkowy ISO WinPE lub Vista+.
4. **DPMS2** (`\_ISO\e2b\grub\DPMS`, pakiet DriverPacks MassStorage 12.09
   z 2012 r., 1399 plików w `D\M`) — `chkpci` + `DriverPack.ini` wybiera
   sterownik z listy PCI ID i wkłada go na dyskietkę F6.
5. **L** — lista PCI ID kontrolera do ręcznego porównania z `TXTSETUP.OEM`.

Dokumentacja E2B wprost: XP instaluje się tylko w trybie Legacy/MBR (CSM),
UEFI nie jest obsługiwane dla XP.

**Dlaczego XP nie działał — przyczyny oparte na zawartości nośnika:**

- **UEFI:** całe menu XP jest w grub4dos (`XPStep1.g4b`, `XPStep2.g4b`,
  `XPWINNT.g4b`), który startuje tylko z MBR. W UEFI użytkownik trafia do
  agFM/Ventoy, a Ventoy nie ma ścieżki instalacji XP (SETUPLDR potrzebuje
  INT 13h/BIOS). grub4dos-UEFI (`menuefi.lst`) na nośniku nie istnieje.
  Bez włączonego CSM XP z E2B nie ma jak wystartować.
- **Dwa rozruchy z pendrive'a (Krok 1 + Krok 2):** faza GUI wymaga ponownego
  wyboru E2B i Kroku 2. Jeśli po fazie tekstowej firmware uruchomi HDD albo
  użytkownik wybierze zły krok, Setup nie znajdzie źródła
  (FiraDisk/WinVBlock) i kończy się błędem kopiowania plików.
- **Sterowniki pamięci masowej:** DPMS pochodzi z 2012 r. — brak w nim AMD
  AHCI z chipsetów 400/500 (X470/B550, PCI 1022:7901) i NVMe. NiKKA SATA-v2
  ma integrację SATA, ale też sprzed Ryzena. Bez pasującego sterownika F6
  Setup nie widzi dysku lub daje BSOD 0x7B. E2B sam ostrzega w komunikacie
  Kroku 1: "Pamiętaj aby wybrać sterownik AHCI... (używając F6)".
- **Nowoczesna platforma:** XP x86 na Ryzenie wymaga zmodyfikowanego
  `ACPI.sys` (inaczej STOP 0xA5), a do wirtualnego dysku FiraDisk/WinVBlock w
  fazie GUI trzeba dostępu do USB — na płytach bez EHCI (tylko xHCI) XP nie
  ma sterownika USB 3, więc ISO na pendrive "znika" po przejściu na
  sterowniki NT. E2B nie integruje ani ACPI, ani USB3 (tylko F6).
- **Kolejność dysków:** `XPStep1.g4b` zakłada, że docelowy dysk to `(hd1)`,
  i ostrzega, że pliki rozruchowe mogą trafić na USB. Przy wielu dyskach
  (dev PC ma ich 8) boot.ini/NTLDR lądują na złym dysku.

### (c) Co E2B ma, a USOS jeszcze nie

- **Szerokość payloadów:** każdy ISO/IMG/VHD/WIM/EFI przez Ventoy/agFM
  (Linux live, Android, BSD, WinPE, DOS, Memtest), nawet bez znanej
  konfiguracji; `.imgPTN` dla nośników wymagających natywnego FAT32.
- **Persistence dla Linuksa** (`docs\Linux Persistence Files`,
  `ventoy\blank_persistent_image.dat_files.zip`).
- **Pliki-towarzysze obok ISO:** `.xml` (unattend), `.key` (klucz),
  `.AUTO` (WINNT.SIF dla XP), `.mnu` (własny wpis menu), `.txt` (opis
  wpisu w menu, `TXT_Maker.exe`). Użytkownik konfiguruje, dokładając plik.
- **Motywy menu:** `MyE2B.cfg` (tło, kolory, pozycje, animacja GIF,
  `STAMP`, zegar), `docs\MyThemes`, `GFXBoot`, `Tunes` (melodie startowe),
  Fonts; `E2B_Editor.exe` do edycji wyglądu.
- **Języki i klawiatury:** 25 folderów językowych (STRINGS.txt + F1.cfg),
  20 map klawiatury (`KBD_*.g4b`), wsparcie RTL; własny język = kopia `ENG`.
- **Narzędzia serwisowe w menu:** info o CPU, lista dysków i PCI,
  test prędkości dostępu do plików, F7 "uruchom z pierwszego HDD",
  hasło/blokada menu (`getpass.g4b`, `PassPass`), ostrzeżenie o baterii CMOS.
- **Test w QEMU z Windows** (`QEMU_MENU_TEST (run as admin).cmd`).
- **Automatyzacja po instalacji:** `WINDOWS\installs` (APPS, DRIVERS,
  SNAPPY = Snappy Driver Installer, INSTALLCHOCO, wsusoffline) wywoływane
  z plików XML "with SDI_CHOCO".
- **Wiele architektur UEFI:** IA32/x64/AA64/MIPS, rEFInd i Clover jako
  alternatywne menedżery.

## 3. Tabela porównawcza

| Obszar | E2B v2.21 (+agFM 1.A3, Ventoy 1.0.97) | USOS |
|---|---|---|
| Tryby rozruchu | BIOS: grub4dos; UEFI: shim Kaspersky → agFM → Ventoy/rEFInd/Clover; dwa zupełnie różne menu | Jedno menu (te same ekrany) w UEFI x64 i Legacy BIOS; ARM64 w toku |
| XP na UEFI | Nie (dokumentacja: tylko Legacy/CSM); w UEFI brak menu XP | UEFI: przygotowanie dysku z mikro-Linuksa, potem rozruch XP przez CSM + PAE (eksperymentalne; potwierdzone na X470, 31,9 GB) |
| XP na BIOS | 2 fazy z ponownym bootem z USB, FiraDisk/WinVBlock, F6 z DPMS 2012 | Jeden przebieg: staging lokalnego źródła na NTFS docelowego dysku, jawny wybór dysku, bez powrotu na USB |
| Win10/11 | BIOS: ImDisk + wybór `.xml`; UEFI: Ventoy, unattend tylko przez ventoy.json | UEFI i BIOS, unattend potwierdzony przez użytkownika |
| Secure Boot | Shim podpisany przez Kaspersky (przełączany z menu); Ventoy dalej wymaga wpisania klucza MOK | shim 16.1 (Microsoft CA 2011+2023) + MokManager, klucz USOS wpisywany raz na komputer |
| UI | Tekstowe/graficzne menu grub4dos z tłem; w UEFI inne menu (agFM/Ventoy) | Własne GUI (Roboto, skalowanie 1x–3x), ta sama grafika w BIOS i UEFI |
| Dotyk i pad | Brak (w agFM/Ventoy tylko klawiatura) | Mysz, touchpad, ekran dotykowy (Absolute Pointer, obrót), pady USB (XInput, Xbox One, HID) |
| Wstrzykiwanie sterowników | XP: dyskietka F6 z DPMS (2012); Win: ręcznie przez `.cmd`/SDI po instalacji | XP: ACPI, GenAHCI, USB3, KMDF, StorPort w kopii źródła; Win7: USB 3 + NVMe; foldery `DATA\Drivers\<system>\Storage/USB/Other`; sterowniki UEFI z dopasowaniem SMBIOS/PCI |
| Języki | 25 języków menu, 20 map klawiatury, RTL | 27 plików locale (447 kluczy `boot.*`), tłumaczenia maszynowe poza EN/PL |
| Pliki i złożoność | 9104 pliki na 2 partycjach; ręczna kopia ISO do właściwego folderu, `MAKE_THIS_DRIVE_CONTIGUOUS`, aktualizacje agFM/Ventoy osobnymi skryptami | ESP + DATA + WORK tworzone przez `USOS Installer.exe` (jeden spakowany payload), ISO wykrywane bezpośrednio z NTFS, bez wymogu ciągłości |
| Wymóg ciągłości ISO | Tak (grub4dos map) | Nie |
| Szerokość payloadów | Bardzo szeroka (dowolne ISO przez Ventoy) | Zweryfikowane ścieżki: Windows 3.1–11, DOS, FreeDOS, SliTaz, Memtest, SMART |

## 4. Pomysły warte przejęcia

1. **Pliki-towarzysze obok obrazu** — `Win11.iso` + `Win11.xml` / `.key` /
   `.txt` (opis w menu) / `.sif` dla XP. USOS może je wykrywać przy skanie
   DATA i pokazywać jako wybór unattend lub opis wpisu, zamiast osobnego
   katalogu konfiguracji. Najtańszy sposób na personalizację bez edytora.
2. **Ogólny rozruch "nieznanego" ISO/IMG/EFI** — fallback w menu
   (np. `Utilities → Inne obrazy`) dla Linux live, WinPE i narzędzi
   z własnym EFI: chainload `\EFI\BOOT\BOOTX64.EFI` z ISO (UEFI) lub
   mapowanie jako dysk (BIOS). Wyraźnie oznaczone jako niezweryfikowane,
   zgodnie z regułą "tylko zweryfikowane ścieżki" dla instalatorów.
3. **Persistence dla Linux live** — plik `.dat`/`.img` obok ISO wskazywany
   parametrem jądra (casper-rw, persistence), zarządzany z instalatora.
4. **Motywy menu** — prosty `theme.ini` na DATA: tło, kolory akcentu,
   logo, opcjonalny dźwięk. Bez zmiany rdzenia.
5. **Mapy klawiatury i RTL** — tabele układów (QWERTZ, AZERTY, …) dla pól
   tekstowych (nazwa komputera, użytkownik, parametry DOS).
6. **Narzędzia w menu:** "uruchom z pierwszego dysku" (bez wyjmowania
   pendrive'a), lista PCI ID kontrolerów z informacją, czy USOS ma dla nich
   sterownik XP/Win7, ostrzeżenie o baterii CMOS (zły rok), opcjonalna
   blokada menu hasłem.
7. **Automatyzacja po instalacji** — opcjonalny folder `DATA\PostInstall`
   (APPS, sterowniki, skrypty) wywoływany z `FirstLogonCommands`/`GuiRunOnce`,
   tak jak `installs` + SDI/Chocolatey w E2B.
8. **Test menu w QEMU jednym kliknięciem** z instalatora (E2B ma
   `QEMU_MENU_TEST`), na kopii tylko do odczytu.

Nie przejmować: dwufazowej instalacji XP z powrotem na USB, zależności od
ciągłości plików, pakietu DPMS z 2012 r. i dwóch odmiennych menu BIOS/UEFI —
to główne źródła zawodności E2B opisane w sekcji 2(b).
