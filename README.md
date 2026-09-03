# Universal Service OS

Lekki, bootowalny system serwisowo-instalacyjny uruchamiany bezpośrednio z USB.

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

## Lokalny toolchain

Projekt używa przenośnego Ziga z `tools/zig/zig.exe` i nie wymaga dodawania Ziga do PATH.

- `build.bat` - buduje kompletną wersję `ReleaseFast`: wspólny program EFI dla pendrive'a i testu, payload oraz gotowy `installer\USOS Installer.exe`; na końcu sprawdza zgodność SHA-256. Świeży instalator ma tryb `Aktualizuj USOS`, którym można lokalnie wgrać bieżący build na już przygotowany pendrive bez ponownego formatowania i bez usuwania obrazów systemów,
- `TEST-USOS.cmd` - uruchamia pełny, widoczny test USOS w QEMU z prawdziwym ISO Windows,
- `RESET-USOS-TEST.cmd` - czyści wyłącznie stan i wirtualny dysk pełnego testu QEMU,
- `installer\USOS Installer.exe` - instalacja, lokalna aktualizacja istniejącego pendrive'a, naprawa i deinstalacja; aktualizacja synchronizuje katalog menu ESP z zawartością DATA bez kopiowania dużych obrazów,
- `tools/tests/run.ps1` - jedno wejście do automatycznych testów deweloperskich (`all`, `unit`, `selftest`, `x86_64`, `aarch64`).

## Pierwszy kamień milowy

Minimalny bootowalny obraz x86, który:

1. startuje w emulatorze,
2. inicjalizuje podstawową konsolę diagnostyczną,
3. wykrywa architekturę,
4. wypisuje stan startu,
5. kończy test jednoznacznym PASS/FAIL.

Dopiero po działającym fundamencie dokładamy grafikę, wejście, system plików, loader programów i zgodność DOS.
