# FreeDOS: programy DOS z USB, 13 września 2026

Wydanie `B260913-104732-91EA3521` dodaje wbudowane `Utilities -> FreeDOS`
w Legacy BIOS. Start nie korzysta z mikro-Linuksa ani osobnego ISO.
FreeDOS jest środowiskiem zgodności dla programów DOS na komputerach x86,
w tym starszych procesorach 32-bitowych. Panel Hardware & SMART nadal
korzysta z własnej ścieżki x86-64.

## Obsługa

1. Skopiuj komplet plików narzędzia do `Utilities/FreeDOS/Programs/` na DATA.
   Możesz utworzyć własny podfolder, np. `FLASH`. Nazwy plików i folderów
   muszą być zgodne z DOS 8.3, bez spacji i polskich znaków.
2. Uruchom pendrive w BIOS i wybierz `Utilities -> FreeDOS`.
3. Po instrukcji naciśnij dowolny klawisz. Doszip otwiera `C:\PROGRAMS`.
   Strzałki i Enter otwierają foldery oraz uruchamiają `.COM`, `.EXE` i `.BAT`.
4. Ctrl+Enter wpisuje nazwę zaznaczonego programu do wiersza poleceń.
   Dopisz wymagane parametry i naciśnij Enter. F3 pokazuje zawartość pliku.
5. F10 i potwierdzenie zamykają menedżer do wiersza DOS. `TOOLS` otwiera
   go ponownie, a `REBOOT` restartuje komputer do USOS.

## Implementacja i ograniczenia

Loader buduje w RAM dysk FAT16 o pojemności 64 MiB i kopiuje programy
z DATA. Wspierane minimum dla tej ścieżki to 128 MiB RAM. Pojedynczy plik
może mieć najwyżej 32 MiB; wszystkie pliki wraz z systemem muszą zmieścić
się na dysku RAM. Pod `Programs` dopuszczalne są 4 poziomy podfolderów.
Nieprawidłowe nazwy i przekroczone limity powodują błąd przed startem DOS.

Konfiguracja menedżera, pliki tymczasowe i wyniki znajdują się wyłącznie
na dysku RAM. Znikają po restarcie. Sesja nie montuje NTFS pendrive'a
i nie zapisuje zmian z powrotem do DATA. Dotyczy to także kopii firmware
utworzonych przez narzędzie na `C:`.

FreeDOS startuje bez HIMEM, EMM386 i SMARTDrive. Programy 32-bitowe DOS
mogą wymagać własnego extendera lub hosta DPMI; programy Windows wymagają
Windows. Obsługę konkretnego flashera trzeba ustalić według jego producenta:
niektóre wymagają MS-DOS lub innej konfiguracji pamięci. Nie dołączono
flasherów ani firmware i nie wykonano flashowania.

MEMDISK udostępnia przez BIOS usługi dyskowe tylko dla dysku RAM.
To nie jest izolacja sprzętu: narzędzia używające portów lub własnych
sterowników mogą komunikować się z rzeczywistymi urządzeniami.
Obsługa klawiaturą została przetestowana; pakiet nie dodaje sterownika myszy DOS.

## Pochodzenie

Pakiet zawiera FreeDOS kernel 2043, FreeCOM 0.86a i Doszip Commander 2.68
na GPLv2. Pliki startowe pochodzą z oficjalnego FreeDOS 1.4 LiteUSB.
SHA-256 dystrybucji: `857dcd2ebf9d3d094320154db5fb5b830acba6fb98f981a95a0ca7ab3350338b`.
Kompletne pakiety upstream wraz z archiwami źródeł i licencjami są dołączone
do `EFI/USOS/dos-native/freedos` na ESP. Manifest przypina sumy kontrolne;
budowanie sprawdza pliki i zgodność binariów z pakietami źródłowymi.

Źródła: [FreeDOS 1.4](https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files/distributions/1.4/),
[repozytorium FreeDOS](https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files/repositories/1.4/).

## Weryfikacja

- Pełny `build.bat`, testy Go, spójność wydania i `tools/tests/run.ps1 -Suite all`: PASS.
- Test FAT16 64 MiB i test dopisania FreeDOS bez powielania istniejącej pozycji: PASS.
- Produkcyjny start BIOS w QEMU `pentium3`, 128 MiB RAM, USB tylko do odczytu: PASS.
- Nawigacja po folderach Doszip, uruchomienie testowych `.COM` i `.EXE`: PASS.
- Ctrl+Enter i `.BAT` otrzymujący argumenty `BIOS123` oraz `/TEST`: PASS.
- Wiersz poleceń, zapis i odczyt wyniku w RAM, F10, `REBOOT` do USOS: PASS.
- Dodatkowy dysk qcow2 po zakończeniu VM zachował identyczne SHA-256: PASS.
- Aktualizacja zweryfikowanego Kingstona oraz odczyt wszystkich 78 plików ESP
  z porównaniem bajtów i identyfikatora wydania: PASS.

Dowody lokalne są w `zig-out/utilities32-work/`: `build.log`, `tests.log`,
`vm.json`, `update-usb.log`, `verify-usb.log`, `kingston-payload-readback.json`.
Zrzuty w `zig-out/win3-work/`: `freedos-panels-final.png`,
`freedos-com-menu-run.png`, `freedos-exe-menu-run.png`,
`freedos-args-executed-final.png`, `freedos-return-final.png`.
Fizyczny start FreeDOS na płycie użytkownika i działanie konkretnych
narzędzi sprzętowych pozostają do sprawdzenia.

## Program do pierwszej próby

Na prośbę użytkownika pobrano MySysInf 1.2 z oficjalnego repozytorium FreeDOS
i skopiowano na zweryfikowany Kingston do `Utilities/FreeDOS/Programs/SYSINFO`.
`START.BAT` uruchamia program i zatrzymuje wynik na ekranie do naciśnięcia
klawisza. Folder zawiera także oryginalną dokumentację oraz kompletny pakiet
ze źródłami w `SOURCE.ZIP`. SHA-1 paczki jest zgodne z repozytorium;
SHA-256 wynosi `966f019e17c001dd4052c5189feb52988aab191f05a38718e23e75546707f8f8`.

Start z menedżera plików i zatrzymanie wyniku na ekranie przeszły
w produkcyjnej sesji FreeDOS, QEMU Pentium III ze 128 MiB RAM. Program pokazał CPU,
kernel 2043, wersję DOS oraz pamięć i dysk dostępne w tej sesji.
Raportowana pamięć uwzględnia rezerwację RAM przez MEMDISK i nie musi
odpowiadać całej pamięci zainstalowanej w komputerze. Zrzut wyniku:
`zig-out/win3-work/mysysinf-result.png`. Odczyt zwrotny wszystkich pięciu
plików z DATA Kingstona potwierdził ich sumy SHA-256.
