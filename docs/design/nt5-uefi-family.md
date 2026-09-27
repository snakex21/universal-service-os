# Rodzina NT5 na UEFI: Windows 2000, Server 2003, XP x64 (projekt, 2026-09-24)

Stan: **projekt**, bez kodu. Punkt wyjścia to działająca ścieżka
**XP SP3 x86: przygotowanie z UEFI → rozruch dysku przez CSM firmware
+ PAE**, potwierdzona na X470/5700X (31,9 GB, czysta instalacja z
pendrive'a, 2026-09-23). Opis tej ścieżki:
[windows-xp-uefi-csm-pae-2026-09-21.md](../windows-xp-uefi-csm-pae-2026-09-21.md).
Plan wspólnego pipeline'u, w który ta rodzina się wpina:
[refactor-os-pipeline.md](refactor-os-pipeline.md). Kolejność:
[ROADMAP.md](../ROADMAP.md).

## 1. Co dziś istnieje, a czego nie ma

| Element | XP SP3 x86 UEFI-CSM | XP/2000 BIOS | 2000 UEFI | 2003 | XP x64 |
|---|---|---|---|---|---|
| Wpis katalogu | `windows-xp` (`.any`) | `windows-xp`, `windows-2000` (`.bios`) | brak trasy | **brak wpisu** | brak wpisu; `probe_xp_source.sh:11-15` odrzuca AMD64 bez I386 |
| Backend | `xp_uefi_staging` | `xp_staging` | – | – | – |
| Pakiet | `EFI/USOS-XP/initramfs-xp` (łatany z bazowego) | bazowy `initramfs-usos` | – | – | – |
| Sterowniki text-mode | GenAHCI (`PCI\CC_010601`), xHCI (backport), KMDF 1.11, community ACPI, StorPort (backport Win7) + `ntoskrn8` | **brak** (stock) | – | – | – |
| NVMe | **brak** | brak | – | – | – |
| PAE | `pae.exe` v4 (tylko 5.1.2600), `UserExecute` + `GuiRunOnce` | brak | – | – | – |
| Utwardzenie | `CrashDumpEnabled=0`, `xp_verify_target.sh` (zero-file) | brak | – | – | – |
| Geometria | kanoniczna 255/63 | zmierzona INT13 AH08 | – | – | – |
| Własny SIF | zablokowany | dozwolony (ścieżka XPSETUP FAT32 + CONTINUE XP) | – | – | – |

Źródła: `src/flow/preparation_capability.zig`, `tools/build_xp_uefi_csm_trial.py`,
`tools/xp_driver_overlay.py`, `tools/xp_driver_stage.sh`,
`tools/nt5_profile.sh`, `tools/probe_nt5_source.sh`, `tools/windows_xp_pae.c`.

Najważniejsze wnioski dla rozszerzenia rodziny:

1. Ścieżka UEFI-CSM **nie jest osobnym kodem**, tylko wariantem skryptów
   BIOS, wytwarzanym przez podmiany tekstu (`replace_once`) w
   `build_xp_uefi_csm_trial.py`. Dodanie 2000/2003/x64 w tym modelu
   oznaczałoby kolejne kotwice i kolejne pakiety. Dlatego rodzina NT5
   wchodzi **po** kroku M4 migracji z `refactor-os-pipeline.md` (profile
   NT5 zamiast podmian), a nie przed nim.
2. Pakiet XP buduje się z bazy wziętej ze **stick'a** (`J:`) i nie jest
   dostarczany przez instalator. Dla rodziny NT5 pakiety muszą budować się
   z `zig-out/micro-linux` i trafiać do `payload.zip` (lub osobnego,
   podpisanego archiwum na ESP), inaczej każda wersja będzie wymagała
   ręcznego wdrożenia.
3. Wszystko, co specyficzne dla wersji (sterowniki, PAE, SIF), musi być
   parametrem profilu, a nie literałem (`C:\USOS\XP\pae.exe`,
   `\I386`, `WIN51IP.SP3`).

## 2. Model: jeden backend `nt5_staging`, wiele profili

Docelowo `xp_staging` i `xp_uefi_staging` stają się jednym backendem
`nt5_staging` z parametrem firmware, a system wybiera **profil NT5**
(dane, nie `if`):

```zig
pub const Nt5Profile = struct {
    id: []const u8,               // "xp-x86-sp3", "2000-sp4", "2003-x86-sp2", "2003-x64-sp2", "xp-x64-sp2"
    kernel: enum { nt50, nt51, nt52 },
    arch: enum { x86, amd64 },
    source_dirs: []const []const u8,   // {"I386"} albo {"AMD64", "I386"} (WOW64)
    markers: []const Marker,      // CDROM_NT.5 / WIN51IP.SP3 / WIN52? (do ustalenia z ISO)
    product_types: []const u8,    // TXTSETUP [SetupData] ProductType: 0 = workstation, 1+ = serwer
    install_dir: []const u8,      // "WINNT" (2000), "WINDOWS"
    max_part_lba48: bool,         // 2000 SP4: wymaga EnableBigLba dla > 128 GiB
    driver_bundle: ?[]const u8,   // id pakietu sterowników (text mode + PnP)
    pae: PaeMode,                 // .none, .native_switch, .patch_x86_client
    sif_dialect: SifDialect,      // różnice w answer file (sekcja 6)
    firmware: FirmwareMask,       // .bios, .uefi_csm, .uefi_csmwrap
    verified: Verification,       // .hardware, .vm, .experimental (etykieta w menu)
};
```

Katalog dostaje wpisy `windows-server-2003` (x86/x64 wybierane po
nośniku) i `windows-xp-x64` (albo XP x64 jako drugi profil wpisu
`windows-xp`, wybierany przez sondę nośnika: jeden folder `Images`,
jak dziś XP SP2/SP3). Zalecenie: **XP x64 jako profil wpisu
`windows-xp`** (użytkownik szuka „Windows XP”), 2003 jako osobny wpis.

Sonda (`probe_nt5_source.sh` → docelowo `detect` w pipeline) rozpoznaje
profil po plikach, nie po nazwie ISO (dziś `is_sp3` w buildzie patrzy na
nazwę pliku: do usunięcia): katalogi `I386`/`AMD64`, `TXTSETUP.SIF`
`[SetupData] MajorVersion/MinorVersion/ProductType`, znaczniki
`CDROM_*`/`WIN51*`, `SP*.CAB` i wersja `NTOSKRNL.EX_`.

## 3. Wymagania ponad ścieżkę XP x86

### 3.1 Windows 2000 (SP4, Professional / Server / Advanced Server)

- **ACPI:** stock `ACPI.SYS` 5.0 jest starszy niż w XP i na AGESA/AM4
  oczekiwany jest STOP 0xA5. Community ACPI z pakietu XP jest budowany
  pod jądro 5.1 i **nie jest** drop-in dla 5.0. Opcje: (a) tryb bez ACPI
  (`F7` w SETUPLDR, HAL `halmps.dll`/`halapic`), który na Ryzenie
  zwykle kończy się brakiem przerwań dla urządzeń PCIe i jednym CPU,
  (b) sterownik ACPI dostarczony przez użytkownika w
  `Drivers\Windows 2000\Storage`-podobnym folderze `Platform\`
  (patrz 3.5). USOS nie redystrybuuje zmodyfikowanych binariów
  Microsoft (np. „Extended Kernel” dla 2000), bo zawierają kod Microsoft.
- **Dysk:** 2000 SP4 obsługuje 48-bit LBA dopiero po
  `HKLM\SYSTEM\CurrentControlSet\Services\Atapi\Parameters EnableBigLba=1`
  (dla atapi). Dla AHCI przez GenAHCI (jeśli zadziała na jądrze 5.0,
  do weryfikacji: import `ntoskrnl` 5.0 może nie mieć wymaganych
  eksportów) limit zależy od sterownika. Zachować limit położenia
  partycji 128 GiB z obecnego planu (`xp_windows_partition_plan.awk`).
- **CPU:** 2000 liczy **logiczne** procesory: Professional 2, Server 4,
  Advanced Server 8. Na 5700X (16 wątków) system wystartuje, ale użyje
  tylko tylu. To nie błąd; komunikat w podsumowaniu.
- **PAE:** Advanced Server i Datacenter obsługują PAE natywnie
  (`/PAE` w `boot.ini`, do 8 GB / 32 GB). Professional i Server mają
  licencyjny limit 4 GB w jądrze; USOS **nie łata** jądra 5.0
  (`pae.exe` odmawia wersji innej niż 5.1.2600 i tak zostaje).
  Profil 2000 AS: `pae = .native_switch` (tylko dopisanie `/PAE` do
  wpisu, bez kopii jądra).
- **USB:** brak xHCI; backport USB3 z pakietu XP zależy od KMDF 1.11 i
  `ntoskrn8`, niesprawdzony na 5.0. Bez niego instalacja wymaga PS/2
  albo emulacji USB legacy przez SMM w CSM (działa w text mode i do
  czasu załadowania stosu USB NT).
- **Stan dziś:** BIOS potwierdzony (MS-7100, VirtualBox). Na X470
  (UEFI-CSM) **niesprawdzone**; oczekiwane ryzyko wysokie (ACPI).

### 3.2 Windows Server 2003 x86 (SP2)

- Jądro 5.2 jest bliższe XP x64 niż XP x86. Community ACPI z pakietu XP
  (5.1) nie pasuje 1:1; potrzebny wariant 5.2 (użytkownika).
- **StorPort jest natywny** (5.2), więc sterowniki NVMe typu OFA/
  community StorPort i nowsze AHCI StorPort mają naturalny cel.
  To czyni 2003 najbardziej obiecującym systemem NT5 dla NVMe.
- **PAE natywne:** Enterprise i Datacenter (`/PAE`, do 32/64 GB, 64 GB
  od SP1); Standard i Web: limit 4 GB. DEP/NX (`/noexecute`) od SP1.
  Profil `2003-x86-ent`: `pae = .native_switch`. Łatanie Standard jest
  poza zakresem (dopiero po osobnej analizie wzorców i licencji).
- **Answer file:** wymaga `[LicenseFilePrintData] AutoMode=` (inaczej
  zatrzymanie w GUI), opcjonalnie `[Components]`, `[TerminalServices]`,
  ekran „Manage Your Server” (sekcja 6).
- **Aktywacja** jak XP (Setup zapyta albo klucz VLK).
- **CPU:** Standard 4 sockety, Enterprise 8: licencja po socketach od
  SP1, więc 5700X jest w pełni używany.

### 3.3 Windows Server 2003 x64 i XP Professional x64 (SP2, 5.2.3790)

- Ten sam kod bazowy (XP x64 = 2003 x64 SP2 w wydaniu klienckim).
- **Źródło ma dwa katalogi:** `AMD64` (system) i `I386` (WOW64, pliki
  32-bit). `DOSNET.INF` ma osobne sekcje dla obu. Lokalne źródło
  (`$WIN_NT$.~LS`) musi zawierać oba, a `prepare_xp_local_source.sh`,
  `xp_dosnet_aliases.awk` i `prepare_xp_source_aliases.sh` dziś
  zakładają tylko `I386`. To główna praca w skryptach
  (parametr `source_dirs`).
- **Loader:** SETUPLDR/NTLDR dla x64 przełącza CPU w long mode; lokalizacja
  `SETUPLDR.BIN` i `NTDETECT.COM` w `~BT` (katalog `AMD64` vs `I386`)
  do ustalenia z oryginalnego ISO przy implementacji (nie zgadywać;
  sonda musi to odczytać z `TXTSETUP.SIF`/`DOSNET.INF`).
- **HAL:** x64 ma jeden HAL ACPI (`hal.dll`) dla APIC; znika wybór HAL i
  problem PAE (64-bit, do 128 GB dla XP x64 / 2003 x64 Standard 32 GB,
  Enterprise 1 TB).
- **Sterowniki muszą być x64:** GenAHCI x64, xHCI i KMDF x64, ACPI 5.2 x64.
  Obecny pakiet jest wyłącznie x86. `inf_package.zig` już rozróżnia
  `NTamd64`, więc sprawdzanie architektury jest gotowe.
- **Podpisy:** x64 5.2 **nie wymusza** podpisu sterowników (to wymóg od
  Vista x64), więc `DriverSigningPolicy=Ignore` działa jak w XP.
- **PAE:** `pae = .none`.

### 3.4 Wspólne dla AM4/Ryzen (X470, B550)

Na podstawie XP x86 (potwierdzone) i badań Win98/CSMWrap:

| Problem | Objaw | Obecne rozwiązanie XP | Dla 2000/2003/x64 |
|---|---|---|---|
| ACPI 2.0+ tabele AGESA | STOP 0xA5 w text mode | community `acpi.sys` w `ACPI.SY_` i w `SP3.CAB` | wariant per jądro (5.0 / 5.2 x86 / 5.2 x64), user-supplied poza XP |
| Brak IDE, tylko AHCI | STOP 0x7B | GenAHCI w `[SCSI.Load]` | x64 GenAHCI; 2000 do weryfikacji |
| NVMe | brak dysku w Setup | **brak** | 2003/x64: StorPort natywny, najłatwiej; XP: StorPort backport już jest w pakiecie, brakuje miniportu NVMe |
| Brak EHCI (tylko xHCI) | USB znika po starcie NT | backport USB3 + KMDF 1.11 | x64: odpowiednik x64; 2000: niesprawdzone |
| Zrzut pamięci po BSOD + twarde wyłączenie | zera w WinSxS | `CrashDumpEnabled=0` (HIVESYS i `pae.exe`) | ten sam krok w każdym profilu (etap `fixups`) |
| x2APIC / IOMMU / Above 4G | zawieszenia, brak przerwań | lista kontrolna BIOS | ta sama lista w podsumowaniu |
| GPU bez sterownika NT5 (RX 5xx+, RDNA) | 640x480 VGA | brak | VBEMP (VBE miniport, user-supplied) w `Other\`; wymaga legacy VBIOS/OpROM |
| Brak PS/2 | klawiatura w GUI Setup | USB3 backport | jak wyżej; text mode nie wymaga klawiszy (zmierzone) |

Ścieżka text mode jest w pełni bezobsługowa (zmierzone w QEMU/SeaBIOS:
po wyborze dysku w USOS jedyne aktywne klawisze to F6/F2/F5/F7/F10
SETUPLDR przez ~10 s), co ogranicza znaczenie braku klawiatury do fazy
GUI. Generator odpowiedzi ([answer-file-generator.md](answer-file-generator.md))
może dodatkowo wypełnić pytania GUI.

### 3.5 Sterowniki: wbudowane + użytkownika

- Pakiety wbudowane (dziś tylko XP x86, przypięte hashami w
  `media/.../Drivers/x86/manifest.json`) stają się **pakietami per
  profil** (`xp-x86`, później `x64-52` jeśli licencje pozwalają).
- Sterowniki użytkownika: `Drivers\Windows XP\{Storage,USB,Other}`,
  `Drivers\Windows 2000\...`, nowe `Drivers\Windows Server 2003\...`
  i `Drivers\Windows XP x64\...` (albo architektura rozpoznawana
  z INF w jednym folderze XP; zalecenie: jeden folder na wpis katalogu,
  filtr architektury z `inf_package.zig`). Projekt integracji text mode
  (`TXTSETUP.SIF` `[SCSI.Load]`/`[HardwareIdsDatabase]`, `DOSNET.INF`,
  `HIVESYS.INF` `CriticalDeviceDatabase`) oraz PnP przez
  `OemPnPDriversPath` jest już opisany w
  [drivers.md](../drivers.md) („Windows XP – design for the XP refactor”)
  i dotyczy całej rodziny bez zmian, z parametrem `source_dirs`
  (x64: `AMD64`).
- Nowa klasa **`Platform\`** dla komponentów zastępujących pliki systemu
  (ACPI, HAL): nie są zwykłym INF, tylko zamianą pliku w źródle
  (`replace-names.txt` w dzisiejszym pakiecie). Zasady: tylko gdy plik
  ma rozpoznaną wersję PE i architekturę pasującą do profilu; zawsze
  zastępowane w obu miejscach (plik skompresowany i kabinet SP), tak jak
  `acpi.sys` dziś; log z hashami; przełącznik w podsumowaniu
  („Użyj zamiennika ACPI z Drivers\...\Platform”).

## 4. HAL i ACPI: decyzje

- USOS **nie wybiera HAL** (tak jak dziś): detekcja Setup wybiera
  ACPI Multiprocessor. F5/F7 w SETUPLDR pozostają dostępne dla
  zaawansowanych; podsumowanie o tym informuje.
- Tryb „bez ACPI” (F7) nie jest domyślny dla żadnego profilu; może być
  opcją diagnostyczną w profilu 2000, jeśli test pokaże, że ACPI 5.0 nie
  ma rozwiązania.
- PAE nigdy nie zastępuje oryginalnego wpisu `boot.ini` (zasada z XP:
  oryginał pozostaje, PAE jest domyślnym wpisem pierwszym, `timeout=0`,
  kopia `boot-original.ini`). Dla profili `.native_switch` dopisywany
  jest wpis z `/PAE` bez `/kernel=`/`/hal=`.

## 5. PAE per profil

| Profil | PAE | Mechanizm |
|---|---|---|
| XP x86 SP2/SP3 | patch klienta (4 GB → pełna pamięć) | `pae.exe` (dziś tylko 5.1.2600 SP3; SP2 do dodania dopiero po testach wzorców PatchPAE3 na plikach SP2) |
| 2000 Pro / Server | brak (limit licencyjny 4 GB) | – |
| 2000 Advanced Server / Datacenter | natywne | wpis `/PAE` |
| 2003 x86 Standard / Web | brak (4 GB) | – |
| 2003 x86 Enterprise / Datacenter | natywne | wpis `/PAE` |
| XP x64, 2003 x64 | nie dotyczy | – |

`pae.exe` dostaje tryb `/switch-only` (dopisanie `/PAE` do kopii wpisu)
zamiast osobnego programu, żeby logika `boot.ini` (atrybuty R/H/S,
atomowa zamiana, kopia) była jedna. Zmiana `pae.exe` oznacza nowy hash;
profil XP x86 zostaje przy **dzisiejszym, niezmienionym** `pae.exe` v4
do czasu osobnego testu sprzętowego (patrz „zachowanie bajtów” w
`refactor-os-pipeline.md`).

## 6. Różnice w pliku odpowiedzi

Baza wspólna: `[Data]` (msdosinitiated, floppyless, `OriSrc`),
`[Unattended] UnattendMode=ProvideDefault`, `OemSkipEula=Yes`,
`Repartition=No`, `FileSystem=LeaveAlone`, **bez `AutoPartition`**,
`TargetPath=\<install_dir>`, oraz `MIGRATE.INF` z mapowaniem C: po
podpisie MBR (`xp_drive_letters.awk`).

| Klucz | 2000 | XP x86 | XP x64 / 2003 x64 | 2003 x86 |
|---|---|---|---|---|
| `TargetPath` / `InstallDir` | `\WINNT` | `\WINDOWS` | `\WINDOWS` | `\WINDOWS` |
| klucz produktu | `[UserData] ProductID` | `ProductKey` | `ProductKey` | `ProductKey` |
| `[LicenseFilePrintData] AutoMode` | Server/AS: wymagane | – | 2003: wymagane | wymagane |
| `[SetupParams] UserExecute` (PAE) | – / AS: `/switch-only` | `pae.exe` | – | Ent/DC: `/switch-only` |
| `DriverSigningPolicy=Ignore` | tak | tak | tak (x64 5.2 nie wymusza) | tak |
| `[GuiUnattended] TimeZone` | indeks NT5 | indeks | indeks | indeks |
| „Manage Your Server” | – | – | 2003: `[GuiRunOnce]`/rejestr do wyłączenia | tak |

Ścieżka `UserExecute` nie może być literałem `C:\USOS\XP\pae.exe`:
generator wstawia `%SystemDrive%`-niezależną ścieżkę zgodną z
dzisiejszym założeniem „USOS zawsze instaluje na C:” (to założenie jest
prawdziwe, bo `MIGRATE.INF` przypisuje C:), ale jako parametr profilu.

## 7. Wariant bez CSM: CSMWrap

> 2026-09-27: aktualny projekt i wynik prototypu QEMU (OVMF bez CSM →
> CSMWrap z ESP na dysku docelowym → XP text mode) są w
> [csmwrap-integration.md](csmwrap-integration.md), fakty o CSMWrap w
> [../research/csmwrap.md](../research/csmwrap.md). Tam, gdzie się różnią,
> obowiązują tamte dokumenty.

Cel: płyty bez CSM (Intel 12. gen+, część AM5, laptopy) i X470
z wyłączonym CSM. **Zawsze eksperymentalny**, osobny wybór firmware
w profilu (`.uefi_csmwrap`).

### 7.1 Przebieg

1. Przygotowanie jak dziś (menu UEFI → mikro-Linux → dysk MBR/NTFS),
   plus kopia CSMWrap (LGPL-2.1, SeaBIOS LGPLv3, z licencją i źródłem) na
   **ESP dysku docelowego** albo na ESP pendrive'a USOS.
2. Pierwszy rozruch: UEFI → `csmwrapx64.efi` → SeaBIOS jako CSM →
   rozruch BIOS dysku 0x80 (MBR Strategy B z USOS) → SETUPLDR → text mode.
3. Każdy kolejny rozruch XP też musi przejść przez CSMWrap. Dlatego
   dysk docelowy dostaje **mały ESP** (np. 100 MiB FAT32 przed partycją
   NTFS, MBR typ 0xEF) z `\EFI\BOOT\BOOTX64.EFI` = CSMWrap i
   `csmwrap.ini`, a MBR zostaje tym, który startuje SeaBIOS. Zmienia to
   plan partycji (dziś jedna partycja NTFS); profil `.uefi_csmwrap`
   dostaje osobny plan i osobny test.
4. Secure Boot: **wyłączony**. USOS **nie podpisuje** CSMWrap kluczem
   MOK: uruchomienie dowolnego kodu BIOS spod podpisanego łańcucha
   podważałoby model zaufania z `secure-boot-usos.md`.

### 7.2 Problemy i ich obsługa

| Obszar | Ryzyko | Plan |
|---|---|---|
| Wideo | SeaVGABIOS na GOP daje VBE, ale nie prawdziwe VGA: `bootvid.dll`/text mode piszą bezpośrednio do rejestrów VGA i bufora `B8000` → czarny ekran w text mode i przy logo | Preferować kartę z legacy OpROM (CSMWrap używa go najpierw → prawdziwe VGA). Bez OpROM: text mode jest bezobsługowy, więc czarny ekran jest akceptowalny, jeśli podsumowanie to zapowie; w GUI i systemie **VBEMP** (VBE miniport, user-supplied) zamiast `vga.sys`. Do weryfikacji w QEMU (OVMF + CSMWrap + `-vga none -device bochs-display`) |
| VBEMP na x86 | `VideoPortInt10` używa trybu V86 → w CSMWrap obsługiwane przez „BIOS proxy” na zarezerwowanym logicznym CPU | System widzi o jeden CPU mniej: komunikat w podsumowaniu; x64 emuluje int10 w HAL (bez V86) |
| Dysk | int13 z własnych sterowników SeaBIOS (AHCI, NVMe, USB) → NTLDR/SETUPLDR działają nawet z NVMe | Po starcie jądra i tak potrzebny sterownik NT (GenAHCI / miniport NVMe): ta sama macierz co w 3.4 |
| NVMe dla XP | SeaBIOS widzi NVMe, XP nie | miniport NVMe dla StorPort (backport StorPort jest w pakiecie XP), user-supplied do czasu weryfikacji licencji; dla 2003/x64 StorPort natywny |
| ACPI | tabele z trybu UEFI (ACPI 6.x, x2APIC w MADT, jeśli firmware włączy x2APIC) | x2APIC off w BIOS (lista kontrolna), community ACPI jak w CSM; CSMWrap domyślnie wyłącza IOMMU i buduje MP table/`$PIR` |
| Mapa pamięci | E820 budowana przez CSMWrap z mapy UEFI; regiony runtime | PAE/`pae.exe` bez zmian; test `pae-install.log` + widoczna RAM |
| Klawiatura USB | brak emulacji 8042 (SMM) → w DOS/SETUPLDR tylko int16, po starcie NT tylko ze sterownikiem USB | text mode bez klawiszy (zmierzone); GUI: backport USB3 albo PS/2; generator odpowiedzi ogranicza pytania GUI |
| Stabilność CSMWrap | próba 2026-09-20 zatrzymała się po SeaBIOS `Booting drive` (Win7, Intel) | najpierw QEMU, potem X470 z CSM off, dopiero potem inne płyty |

### 7.3 Kolejność dla CSM-less

1. QEMU/OVMF bez CSM: CSMWrap → text mode XP z pakietu USOS (istniejący
   harness `run_seabios_xp_uefi_csm_textmode.py` przeniesiony na OVMF).
2. X470 z CSM wyłączonym i kartą z legacy OpROM (to samo, co działa z CSM).
3. X470 z kartą tylko-GOP (VBEMP).
4. Maszyna bez CSM (B550 dev PC ma CSM; potrzebna inna, np. AM5/Intel 12+).

## 8. Weryfikacja

- Sonda i profile: testy jednostkowe na drzewach katalogów z plików
  testowych (bez binariów Microsoft w repo), po jednym na profil.
- Skrypty przygotowania: istniejące testy przygotowania w katalogach
  roboczych (jak `check_xp_menu_overlay.py`) z profilami x64 (`AMD64`
  + `I386`) i 2000 (`d1=\`).
- QEMU/SeaBIOS text mode → GUI dla każdego profilu (ISO użytkownika,
  poza repo), `compare_xp_packages.py` dla profilu XP x86 (**0 zmian**
  w pakiecie XP x86 po każdym kroku refaktoru).
- Sprzęt: X470 z CSM, osobny dysk testowy (nie Intel z działającym XP).
  Kolejność: 2003 x86 Enterprise (PAE natywne, StorPort) → XP x64 →
  2003 x64 → 2000.
- W menu każdy profil ma etykietę `verified` z tabeli; niesprawdzone
  są widoczne jako „eksperymentalne”, z powodem.
