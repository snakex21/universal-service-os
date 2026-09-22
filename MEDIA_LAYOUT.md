# Układ danych na nośniku

## Główne kategorie

Nośnik jest czytelny również bez uruchamiania Universal Service OS:

- `Systems/Windows/` - stabilne wydania Windows,
- `Systems/Linux/` - dystrybucje Linux,
- `Systems/Betas/` - rozwojowe i beta buildy Windows,
- `Systems/DOS/` - systemy DOS,
- `Utilities/` - diagnostyka, recovery, firmware, sieć i narzędzia bootujące,
- `Programs/` - programy przeznaczone do instalacji po instalacji systemu,
- `UI/` - HTML i CSS interfejsu.

## Partycje techniczne

- ESP: FAT32, pliki startowe USOS i sterownik NTFS UEFI.
- DATA: NTFS, Microsoft Basic Data GPT.
- WORK: NTFS, Microsoft Basic Data GPT `EBD0A0A2-B9E5-4433-87C0-68B6B72699C7`, etykieta `USOS_WORK`.

WORK nie używa własnego typu GPT, ponieważ WinPE nie montuje niestandardowego typu jako zwykłej partycji danych. Tożsamość WORK jest chroniona przez PARTUUID i dysk nadrzędny oraz dodatkowo przez `.usos-work`; plik zawiera nonce zgodny z `EFI/USOS/usos-device.ini`. Po formatowaniu `.usos-work` jest pierwszym zwykłym plikiem zapisywanym na WORK, przed rozpakowaniem instalatora.

## Obrazy

Każdy profil ma własny katalog `Images`. Obsługiwane w katalogu są obecnie formaty rozpoznawane jako:

- ISO,
- WIM,
- IMG,
- VHD,
- VHDX,
- EFI.

Nazwa pliku jest dowolna. Format i metoda startu są rozdzielone: po wybraniu obrazu GUI pokazuje tylko metody zgodne z profilem i typem pliku.

## Ikony profili

Profil systemu albo narzędzia może mieć opcjonalne `icon.png` obok katalogu `Images`, np. `Systems/Windows/Windows 11/icon.png` albo `Utilities/MemTest86/icon.png`. PNG jest jedynym formatem ikon profili; bootmanager ma własny lekki dekoder PNG i nie ładuje kodeków JPEG. Maksymalny rozmiar ikony to 1 MiB.

Na gotowym nośniku plik `icon.png` znajduje się na DATA. `Aktualizuj USOS` synchronizuje go do małego katalogu metadanych na ESP. Brak własnej ikony oznacza użycie ikony wbudowanej, jeśli taka istnieje.

## Windows

Przykład:

`Systems/Windows/Windows 11/Images/`
`Systems/Windows/Windows 11/Unattended/`

Wbudowane profile obejmują Windows 11, 10, 8.1, 8, 7, Vista, XP, 2000, NT 4.0, Me, 98 SE, 98, 95 i 3.11.

### Windows 7 x64 — biblioteka driverów i kolejka SHA-2

`Systems/Windows/Windows 7/Drivers/x64/{USB_AMD,USB_Intel,USB_Generic,NVMe}/`
`Systems/Windows/Windows 7/Updates/` (plik `KB4474419*.msu` dokłada użytkownik)

Puste foldery = no-op. DISM `/Add-Driver /Recurse /ForceUnsigned` dobiera
paczki po HWID sprzętu; PnP ignoruje resztę, nie trzeba ręcznie wybierać.
Kolejność sztywna: SHA-2 `Add-Package` PRZED `Add-Driver`; brak MSU to tylko
warning. Ostrzeżenia: Intel 11–14gen VMD On = brak dysku (wyłącz VMD/RST),
Xe/UHD 730/770 i RDNA2 (AM5) = brak driverów pod 7 (wymagane dGPU, inaczej
800x600 VGA). SATA omija NVMe, CSM omija UefiSeven.

Stan repo (2026-09-20): `USB_Generic/` jest zapełniony kompletem x64
Microsoft generic xHCI + UAS (`usbxhci.inf/.cat/.sys`, `usbhub3.sys`,
`ucx01000.sys`, `usbd8.sys`, DriverVer 11/12/2023 6.2.9200.24610, oraz
`uaspstor.inf/.cat/.sys`, DriverVer 06/21/2006 10.0.19041.1) ze źródła
`./driwer/x64`. Ta jedna paczka jest wieloproducentowa — `Generic.NTamd64.6.1`
pokrywa `PCI\CC_0C0330` plus HWID AMD, Intel, ASMedia, Renesas/NEC, VIA,
Etron, Fresco Logic i TI — dlatego `USB_AMD/`, `USB_Intel/` i `NVMe/`
zostają puste (no-op) i nie ma sensu duplikować w nich tego samego INF.
`NVMe/` pozostaje pusty także dlatego, że użytkownik nie dostarczył żadnego
sterownika NVMe; same hotfixy KB2990941 + KB3087873 nie zastąpią INF dla
kontrolera spoza listy Microsoftu. Szczegóły w README_PL.txt biblioteki.

#### Offline injekcja do `boot.wim` i `install.wim` nośnika

`installer/internal/install/win7inject.go` wstrzykuje **tę samą** bibliotekę
(bez drugiego, równoległego pipeline'u) również do WIM-ów na samym nośniku
instalacyjnym Windows 7:

| Obraz | Indeksy | Co wchodzi |
| --- | --- | --- |
| `sources/boot.wim` | 1 (Windows PE) i 2 (Windows Setup) | tylko `/Add-Driver` — WinPE musi widzieć klawiaturę, mysz i dysk NVMe |
| `sources/install.wim` | obraz docelowy (domyślnie 1) | `/Add-Package` (kolejka MSU), dopiero potem `/Add-Driver` |

Kolejność pakietów jest sztywna i **KB4474419 jest zawsze pierwszy** —
bez obsługi SHA-2 pozostałe pakiety i sterowniki są offline odrzucane:

1. `KB4474419` — obsługa podpisów SHA-2 (warunek wstępny),
2. `KB2990941` — obsługa NVMe w Windows 7 SP1 x64,
3. `KB3087873` — poprawka do obsługi NVMe (następca KB2990941).

Oczekiwany układ artefaktów (repo **nie** dostarcza binariów sterowników
ani plików MSU i nic nie pobiera):

```
Systems/Windows/Windows 7/Drivers/x64/USB_AMD/*.inf|*.sys|*.cat
Systems/Windows/Windows 7/Drivers/x64/USB_Intel/*.inf|*.sys|*.cat
Systems/Windows/Windows 7/Drivers/x64/USB_Generic/*.inf|*.sys|*.cat
Systems/Windows/Windows 7/Drivers/x64/NVMe/*.inf|*.sys|*.cat
Systems/Windows/Windows 7/Updates/*kb4474419*.msu
Systems/Windows/Windows 7/Updates/*kb2990941*.msu
Systems/Windows/Windows 7/Updates/*kb3087873*.msu
```

Dopasowanie MSU ignoruje wielkość liter i wersję w nazwie
(`windows6.1-kb4474419-v3-x64_<sha1>.msu` pasuje do `KB4474419`).
Podkatalog sterowników bez żadnego `*.inf` jest pomijany jako no-op, ale
brak **wszystkich** czterech albo brak któregokolwiek z trzech MSU kończy
się typowanym błędem `install.MissingArtifactsError`
(`errors.Is(err, install.ErrMissingArtifacts)`), który nazywa każdy brak
z osobna wraz ze ścieżką, w której był oczekiwany. Błąd pada **przed**
jakimkolwiek `dism /Mount-Wim`, więc odmowa nigdy nie zostawia
zamontowanego obrazu. Błąd w trakcie zamontowanego obrazu kończy się
`dism /Unmount-Wim /Discard`, nigdy `/Commit`.

#### Klasyfikacja nośnika a klasyfikacja celu

Pojęcia są rozdzielone i każde ma dokładnie jedną implementację:

- **nośnik** (co to za ISO/USB): `installer/internal/winmedia.ClassifyMedia`
  — `WIN7_PE7` / `WIN7_PE10` / `WIN10` / `UNKNOWN` plus `<ARCH>` z WIM;
- **cel** (firmware maszyny, na którą instalujemy):
  `installer/internal/install.ClassifyWin7Target` — `Win7BIOSVanilla`
  albo `Win7UEFIX64Modern`.

`install.ClassifyWin7TargetForMedia(media, firmware)` spina obie: klasa
i architektura pochodzą z wykrytego nośnika zamiast z ręcznie podawanych
stringów, a nośnik inny niż Windows 7 jest odrzucany typowanym błędem
`install.ErrMediaNotWindows7`.

### Klasyfikacja nośnika instalacyjnego Windows i patch czystego UEFI

Pakiet `installer/internal/winmedia` rozpoznaje generację nośnika bez
montowania obrazów: czyta wyłącznie nieskompresowany zasób `XML_DATA`
z nagłówka WIM (`sources/install.wim`, akceptowane także `install.esd`
i `install.swm`, oraz `sources/boot.wim`; wyszukiwanie ignoruje wielkość
liter). Decyzja zależy tylko od wersji z `<WINDOWS><VERSION>`:

| `install.wim` | `boot.wim` | Klasyfikacja | Znaczenie |
| --- | --- | --- | --- |
| 6.1.760x | 6.1.760x | `WIN7_PE7` | Windows 7 z oryginalnym WinPE 3.x |
| 6.1.760x | 10.0.x | `WIN7_PE10` | Windows 7 z przeszczepionym WinPE 10 |
| 10.0.x | 10.0.x | `WIN10` | nośnik Windows 10/11 |
| dowolne inne | dowolne inne | `UNKNOWN` | obserwowane wersje zostają w wyniku do logu |

##### Jedna tabela reguł dla dwóch implementacji

Ta sama reguła musi działać w dwóch światach, które nie mogą dzielić kodu:
w firmware (Zig, `src/image_probe/wim_setup.zig` — decyduje, **jak
wystartować** wybrane ISO: `Win7Mode` = `original` / `hybrid`) i na hoście
Windows (Go, `installer/internal/winmedia/classify.go` — decyduje, **jak
przygotować/załatać** nośnik: `Class`). Źródłem prawdy dla obu jest jeden
plik: **`src/image_probe/windows7_pe_rules.tsv`**. Zmiana reguły to zmiana
wiersza w tej tabeli i następnie obu implementacji.

Oba języki mają test, który czyta dokładnie ten plik i sprawdza swoją
kolumnę, więc implementacje mogą się rozjechać wyłącznie przez świadomą
zmianę tabeli:

- `src/image_probe/windows7_pe_rules_test.zig` (kolumna `zig_mode`),
- `installer/internal/winmedia/pe_rules_agreement_test.go` (kolumna
  `go_class`).

Tabela dokumentuje też dwie **rozmyślne** różnice między odpowiedziami:
`boot.wim` 6.3.x (WinPE 8.1) jest dla Go `UNKNOWN`, a dla Zig `hybrid`
(liczy się tylko „PE nowoczesne ≥ 6.2”, bo takie ma stos USB 3 i własny
Setup); nośnik x86 Go nadal klasyfikuje generacyjnie (odmowa UEFI jest
osobną decyzją `UEFICapable`/`ErrArchNotUEFICapable`), a Zig nie ma ścieżki
x86 w ogóle (`detectX64Setup` odrzuca `ARCH != 9`).

Sygnały pomocnicze (tylko do logu i do decyzji patchera, nigdy do samej
klasyfikacji): obecność `efi/`, `efi/boot/bootx64.efi`,
`efi/microsoft/boot/bootmgfw.efi`, `efi/microsoft/boot/bcd`,
`boot/efisys.bin`, `boot/etfsboot.com` oraz `<ARCH>` z `install.wim`
(0 = x86, 9 = x64).

#### Wymagania czystego UEFI (CSM wyłączony)

- **FAT32 jest obowiązkowy**: firmware UEFI czyta tylko FAT32, więc żaden
  plik na nośniku nie może przekraczać 4 GiB − 1 B. Patcher skanuje układ
  przed jakimkolwiek zapisem i przy większym pliku odmawia, nazywając plik
  i sugerując podział WIM (`dism /Split-Image /FileSize:3800` albo
  `wimlib-imagex split`).
- **Secure Boot musi być wyłączony**: bootloader Windows 7 nie jest
  podpisany kluczem akceptowanym przez współczesne firmware z SB On.
- **x86 nie jest obsługiwany**: nośnik x86 jest oznaczany jako
  UEFI-niezdolny, a patch kończy się odmową (`ErrArchNotUEFICapable`).
- **Oryginalne ISO Windows 7 x64 z założenia nie ma
  `efi/boot/bootx64.efi`**: w wersji optycznej startuje na UEFI wyłącznie
  przez El Torito `boot/efisys.bin`. Skopiowany na pendrive nie wstanie,
  dopóki nie doda się ścieżki removable media.

#### Co robi patch

Patcher (`winmedia.PatchUEFI`) wypakowuje `\Windows\Boot\EFI\bootmgfw.efi`
i zapisuje go jako `efi/boot/bootx64.efi`. Źródło zależy od klasyfikacji:
dla `WIN7_PE10` (i `WIN10`) `boot.wim` — bootloader Windows 10 podpisany
przez Microsoft; dla `WIN7_PE7` `install.wim` (dowolny obraz x64).
`efi/microsoft/boot/bcd` musi już istnieć — oryginalne ISO Windows 7 x64
zawiera kompletny plik, a patcher **nie fabrykuje BCD** i przy jego braku
zwraca błąd. Powtórne uruchomienie jest no-opem.

Wypakowanie pliku z WIM wymaga narzędzia zewnętrznego. Domyślna
implementacja (`winmedia.DismExtractor`) używa DISM: `dism /Mount-Wim`
z `/ReadOnly`, kopia pliku, `dism /Unmount-Wim /Discard` (źródłowy WIM
nigdy nie jest modyfikowany; `dism /Export-Image` nie potrafi wyjąć
pojedynczego pliku). Wymaga Windows i uprawnień administratora; brak
DISM jest zgłaszany jako czytelny błąd, nigdy po cichu. Interfejs
`winmedia.WIMExtractor` pozwala podstawić inną implementację
(np. `wimlib-imagex`) i testować patcher bez DISM.

Klasyfikacja i patch działają na katalogu: wywołujący montuje ISO albo
wskazuje rozpakowany nośnik. Zapis na fizyczny pendrive to osobny,
jawnie potwierdzany krok.

## Linux

`Systems/Linux/`

Wbudowane profile: Ubuntu, Debian, Fedora, Linux Mint, Arch Linux, openSUSE, Manjaro, Kali Linux i Other Linux. Każdy ma `Images` i `Unattended`.

## Beta builds

`Systems/Betas/`

Whistler, Longhorn, Neptune, Chicago, Memphis i Nashville są oddzielone od normalnych Windowsów. Każdy profil ma `Images` i `Unattended`.

## DOS

`Systems/DOS/`

FreeDOS, MS-DOS, PC DOS, DR-DOS, OpenDOS i Other DOS. Każdy ma `Images`; obrazy IMG mogą później korzystać także z trybów floppy/disk/memdisk.

## Utilities

`Utilities/FreeDOS/Programs/` jest folderem programów DOS dla wbudowanej
pozycji BIOS `Utilities -> FreeDOS`. Każde narzędzie może mieć swój podfolder
z programem i wymaganymi plikami, np. `Programs/FLASH/FLASH.EXE`.
Wymagane są nazwy 8.3 ASCII. Zawartość trafia przy starcie do `C:\PROGRAMS`
na dysku RAM 64 MiB; pojedynczy plik może mieć najwyżej 32 MiB, a całość
musi zmieścić się razem z FreeDOS. Pod `Programs` można zagnieździć
najwyżej 4 poziomy podfolderów.
Zmiany z sesji DOS nie są zapisywane na DATA. Folder nie wymaga `Images`
ani osobnego ISO. Instalator tworzy obok plik `README.txt` z instrukcją.

`Utilities/` jest dynamiczne. Każdy podkatalog jest jednym narzędziem widocznym w menu, np.:

`Utilities/MemTest86/Images/memtest86.efi`
`Utilities/GParted/Images/gparted.iso`

Nazwa folderu jest nazwą narzędzia w GUI. W katalogu narzędzia można dodać `icon.png`; po lokalnej aktualizacji USOS ikona jest synchronizowana do katalogu metadanych na ESP i wyświetlana w menu. PNG może mieć maksymalnie 1 MiB.

Obrazy ISO/WIM/IMG/VHD/VHDX pozostają wyłącznie na DATA i są odkrywane bezpośrednio z NTFS przy każdym wejściu do menu. Legacy Core czyta `USOS_DATA` przez wspólny read-only parser NTFS, a UEFI używa tego samego parsera przez `BlockIo`; nie istnieją już zerobajtowe znaczniki obrazów na ESP. ESP przechowuje tylko pliki potrzebne do bootu oraz małe artefakty wymagające wykonania z FAT32, np. kopie aplikacji `.efi`, ikony profili i zgodnościowe metadane unattended. `ntfs_x64.efi` pozostaje osobnym sterownikiem wyłącznie dla handoffu Windows Setup, gdy firmware musi dostać `SimpleFileSystem` dla przygotowanego woluminu NTFS.

Utilities są osobną kategorią GUI, a nie systemem operacyjnym.

## Programs

`Programs/` jest przeznaczone na programy używane już po uruchomieniu docelowego systemu operacyjnego. Każdy program może mieć własny folder i opcjonalne `icon.png` jako metadane. Zwykłe pliki Windows EXE nie są uruchamiane bez Windows; narzędzia bootowalne należy umieszczać w `Utilities`.
