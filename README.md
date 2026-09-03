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

- `build.bat` - buduje kompletną wersję `ReleaseFast`: wspólny program EFI dla pendrive'a i testu, payload oraz `installer\build\USOS Installer.exe`; na końcu sprawdza zgodność SHA-256,
- `test.bat` - uruchamia pełne testy jednostkowe,
- `selftest.bat` - uruchamia te same krytyczne testy startowe, których użyje system.

## Pierwszy kamień milowy

Minimalny bootowalny obraz x86, który:

1. startuje w emulatorze,
2. inicjalizuje podstawową konsolę diagnostyczną,
3. wykrywa architekturę,
4. wypisuje stan startu,
5. kończy test jednoznacznym PASS/FAIL.

Dopiero po działającym fundamencie dokładamy grafikę, wejście, system plików, loader programów i zgodność DOS.
