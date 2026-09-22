# Universal Service OS

Lekki, bootowalny system serwisowo-instalacyjny uruchamiany bezpośrednio z USB.

Aktualna [lista pozostałych prac](ROADMAP.md) rozdziela planowane funkcje
od [wyników wykonanych testów](TESTING.md).

## Cel

- start na starym i nowym sprzęcie,
- BIOS i UEFI,
- x86 oraz x86_64,
- ARM64 jako równorzędna architektura,
- własne lekkie GUI,
- uruchamianie instalatorów systemów,
- uruchamianie narzędzi diagnostycznych,
- zgodność z programami DOS tam, gdzie ma to sens,
- możliwość przekazywania startu do zewnętrznych programów i obrazów,
- brak zależności od Windows podczas działania z pendrive'a.

## Założenia techniczne

Szczegółowe reguły pracy są zapisane w `PROJECT_RULES.md`.

- główny język: Zig,
- rdzeń systemu niezależny od architektury,
- architektury w osobnych modułach,
- DOS jako warstwa zgodności x86,
- GUI lekkie; bez Chromium i ciężkiego runtime'u,
- krytyczne autotesty są częścią startu systemu,
- testy automatyczne w emulatorze oraz później na prawdziwym sprzęcie,
- szybki pierwszy ekran: cięższe moduły inicjalizowane dopiero na żądanie,
- żadnych atrap, stubów ani funkcji udających działanie.

## Programy DOS z pendrive'a

`Utilities -> FreeDOS` uruchamia wbudowany FreeDOS z menedżerem plików Doszip.
Własne programy DOS należy skopiować do `Utilities/FreeDOS/Programs/` na DATA,
używając nazw 8.3 bez polskich znaków. Strzałki i Enter otwierają foldery
i uruchamiają programy; Ctrl+Enter pozwala dopisać parametry. Nie potrzeba ISO.
Ta ścieżka BIOS działa na CPU 32-bitowym; sprawdzono Pentium III i 128 MiB RAM
w QEMU. Sesja działa na dysku RAM: wyniki nie przetrwają restartu.
[Obsługa i ograniczenia](docs/freedos-tools-bios-2026-09-13.md).

## Windows 7 UEFI i USB 3

Obrazy Windows 7 z nowszym WinPE x64 uruchamiają własny instalator przez
WIMBoot UEFI bez rozpakowywania ISO na WORK. Obsługiwane są źródła WIM i ESD.
[Bezpośredni start ISO — zakres i test zmodyfikowanego obrazu](docs/windows7-direct-iso.md).

Windows 7 SP1 x64 ma przygotowanie UEFI oryginalnego ISO z poprawką rozruchu
i integracją własnych sterowników USB 3. Pełna instalacja ręczna i unattended
oraz start bez pendrive'a są potwierdzone w QEMU. Rozpakowane sterowniki danego kontrolera
należy dodać do `Systems/Windows/Windows 7/Drivers/x64` na DATA.
[Przebieg, wyniki i ograniczenia Windows 7 UEFI](docs/windows7-uefi.md).

Integracja Microsoft NVMe dla Windows 7 SP1 x64 jest dodana do pakietu.
Pełna regresja SATA jest zaliczona; pełna instalacja do pulpitu na NVMe
pozostaje niepotwierdzona. [Zakres i wyniki NVMe](docs/windows7-nvme.md).

## Aktualne ograniczenie Legacy BIOS / mikro-Linux

Legacy Core działa jako i386/PM32 i samo menu nie wymaga x86_64, ale **obecny mikro-Linux przygotowujący WORK jest x86_64** (`Alpine 6.18.35-0-virt`). Oznacza to, że ścieżka Legacy `USOS -> mikro-Linux -> przygotowanie instalatora Windows/XP` wymaga procesora z long mode: praktycznie Athlon 64 i nowsze AMD oraz Pentium 4 z EM64T i nowsze Intel. Pentium III i 32-bitowy Athlon XP mogą uruchomić Legacy menu USOS, ale obecny mikro-Linux nie wystartuje na tych CPU, więc instalacja XP przez tę ścieżkę nie zadziała.

Bieżące **wspierane minimum RAM dla pełnego startu mikro-Linuksa to 256 MiB**. Loader potrafi rozmieścić kernel i initramfs już przy 128 MiB, ale przy 128/132 MiB obecny 45,7 MiB initramfs nie rozpakowuje się w całości; SeaBIOS przechodzi pełny boot od 136 MiB. 256 MiB jest więc celowo przyjętym minimum sprzętowym z marginesem dla różnic firmware i przyszłych zmian initramfs.

Plan późniejszy, **nie będący częścią bieżącego kamienia**: osobny 32-bitowy mikro-kernel dla starszego x86 bez long mode. Initramfs i logika przygotowania mają pozostać wspólne; nie tworzymy teraz drugiego backendu.

## Lokalny toolchain

Projekt używa przenośnego Ziga z `tools/zig/zig.exe` i nie wymaga dodawania Ziga do PATH.

- `build.bat` - buduje kompletną wersję `ReleaseFast`: wspólny program EFI dla pendrive'a i testu, payload oraz gotowy `installer\USOS Installer.exe`; na końcu sprawdza zgodność SHA-256. Świeży instalator ma tryb `Aktualizuj USOS`, którym można lokalnie wgrać bieżący build na już przygotowany pendrive bez ponownego formatowania i bez usuwania obrazów systemów,
- `TEST-USOS.cmd` - uruchamia pełny, widoczny test USOS w QEMU z prawdziwym ISO Windows,
- `RESET-USOS-TEST.cmd` - czyści wyłącznie stan i wirtualny dysk pełnego testu QEMU,
- `installer\USOS Installer.exe` - instalacja, lokalna aktualizacja istniejącego pendrive'a, naprawa i deinstalacja; obrazy są wykrywane bezpośrednio z `USOS_DATA` przez read-only NTFS, więc po skopiowaniu ISO/WIM/IMG/VHD/VHDX nie trzeba uruchamiać synchronizacji katalogu menu,
- `tools/tests/run.ps1` - jedno wejście do automatycznych testów deweloperskich (`all`, `unit`, `selftest`, `x86_64`, `aarch64`).

## Pierwszy kamień milowy

Minimalny bootowalny obraz x86, który:

1. startuje w emulatorze,
2. inicjalizuje podstawową konsolę diagnostyczną,
3. wykrywa architekturę,
4. wypisuje stan startu,
5. kończy test jednoznacznym PASS/FAIL.

Dopiero po działającym fundamencie dokładamy grafikę, wejście, system plików, loader programów i zgodność DOS.
