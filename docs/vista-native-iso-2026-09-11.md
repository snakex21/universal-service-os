# Vista BIOS: bez przygotowania WORK i bez restartu przed Setup

Nowa ścieżka jest włączona dla `windows-vista` w BIOS. Core czyta wybrane ISO
z NTFS na DATA i pobiera z UDF oryginalne `bootmgr`, BCD, `boot.sdi` i
`sources/boot.wim`. Przekazuje je w RAM do przypiętego wimboot 2.9.0. Helper
w oryginalnym Windows PE identyfikuje DATA po GUID, sprawdza obie kopie GPT,
otwiera tę samą ścieżkę ISO i weryfikuje jego rozmiar. ImDisk udostępnia DATA
i ISO tylko do odczytu. Następnie startuje oryginalny `sources/setup.exe`.

Nie ma tu uruchamiania Linuksa, wypakowania całej płyty, gotowego cache dla
konkretnego ISO ani restartu przygotowawczego. Restart po skopiowaniu Windows
pozostaje normalną częścią oryginalnego instalatora.

## Zmiany i wykryte przyczyny błędów

- Czytnik NTFS otwiera plik raz i obsługuje odczyt zakresów przez jego runlistę.
  UDF udostępnia analogiczny odczyt plików bez wczytywania całego ISO.
- Bufor transferowy BIOS został przeniesiony z `0x80000` do `0x10000`.
  Duże odczyty nachodziły wcześniej na stos aktywnego Core. Nowy zakres
  wykorzystuje zakończony bootstrap poniżej kodu Core.
- Usunięto diagnostyczne nakładki na INT 10h/15h/16h/1Ah ze ścieżki natywnej.
  Nakładka INT 16h gubiła flagę ZF i blokowała wimboot. Pozostała tylko obsługa
  kolejności dysków INT 13h; test wykonuje rzeczywiste instrukcje w emulatorze.
- Pakiet `EFI/USOS/windows-native` zawiera stałe narzędzia. Pliki Windows
  pochodzą zawsze z obrazu wybranego w menu. Plik odpowiedzi jest opcjonalny.
- Konfiguracja, logi i pliki pomocnicze PE są lokalne, obok helpera na dysku RAM.
  Rejestracja sterownika jest tymczasowa w PE i usuwana po uruchomieniu usługi.

## Potwierdzone wyniki

- 12 września 2026 użytkownik potwierdził zakończoną instalację Visty na
  fizycznym MS-7100. Status: **zainstalowana na sprzęcie**. Automatyczne restarty
  podczas etapów instalacji nie zawsze prowadzą do dalszego startu; konieczny
  był ręczny RESET. Przyczyna nie została ustalona. Na prośbę użytkownika
  diagnostykę tego problemu odłożono, aby przejść do kolejnych Windowsów.
- Po tej instalacji użytkownik zgłosił, że Kingston przestał być widoczny
  w BIOS-ie jako nośnik rozruchowy. To osobny, otwarty problem nośnika/startu;
  sam związek czasowy nie potwierdza, że instalator Visty zmienił pendrive.

- Pełny `build.bat`: PASS, wersja `B260911-215613-B7E30104`.
- `tools/tests/run.ps1 -Suite all`: PASS, w tym Zig, testy helperów x86/x64,
  emulacja INT 13h i startowe autotesty UEFI x86_64 oraz ARM64 w QEMU.
- Odczyt GPT → NTFS → UDF porównany z niezależnym rozpakowaniem przez 7-Zip:
  wszystkie sześć plików zgodne co do rozmiaru i SHA-256, włącznie z
  `install.wim` o rozmiarze 3 350 651 798 bajtów.
- Ten sam czytnik odczytał wszystkie sześć plików także z fizycznego Kingstona;
  SHA-256 są zgodne z oryginalnym ISO. Odczyt hosta jest wyrównany do sektorów,
  czego wymaga dostęp do urządzenia blokowego w Windows.
- Pełna instalacja oryginalnego polskiego Vista SP2 x64, edycja Business,
  w VirtualBox BIOS: menu USOS → Windows PE → Setup → zapis na pusty dysk
  32 GB → restart instalatora → odłączenie źródła → kontynuacja wyłącznie
  z dysku docelowego → OOBE → pulpit użytkownika `USOS-Test`.
- Fixture miał pusty WORK, nie miał cache Windows ani znacznika gotowości,
  a katalog mikro-Linuksa był niedostępny pod oczekiwaną nazwą. Przed Setup
  nie wystąpił restart. Źródło w pełnej instalacji było podłączone jako IDE.
- Dodatkowy test helpera w oryginalnym Vista PE z DVD i nośnikiem źródłowym
  podłączonym przez emulowany kontroler USB 2.0: druga partycja DATA została
  odnaleziona po GUID i podłączona jako S:, a wskazany ISO jako CD T:.
  Widoczny był właściwy `install.wim`, a skopiowany przez PE z tego ISO
  `bootmgr` ma SHA-256 identyczny z oryginałem. Firmware VirtualBox nie wystartował
  bezpośrednio z tego wirtualnego USB, dlatego ten test dotyczy dostępu do
  źródła w PE, a nie całego startu menu przez USB.
  Pełnego odczytu `install.wim` w tym dodatkowym wariancie PE/USB nie oznaczono
  jako PASS: kopiowanie do urządzenia NUL zakończyło się błędem zapisu,
  a próbę `type` przerwano. Pełna instalacja była sprawdzona w wariancie IDE;
  pełny odczyt fizycznego Kingstona i porównanie SHA-256 wykonano z hosta.
- Core, `support.cpio` i wimboot z wydania są identyczne bajt w bajt z plikami
  użytymi w tej instalacji. Core ma 227 248 bajtów payloadu.
- Fizyczny Kingston DataTraveler 3.0 o GPT
  `31c644bf-74dd-4807-9cb2-46745adeadd4` zaktualizowano standardowym silnikiem
  aktualizacji. Readback kodu startowego, plików i tożsamości GPT: PASS.
  Pozostały plik diagnostyczny `windows-bios-debug.ini` usunięto po zapisaniu
  i sprawdzeniu kopii w katalogu testu.

Dowody lokalne: `zig-out/native-vista-work/serial.log`,
`installed-desktop.png`, `target-continuation.png`, `io-verification.json`,
`tests-final.log`, `release-build-final2.log`, `kingston-update-final.log`,
`physical-read.log`.
Test źródła USB: `usb-mapper-result.png`, konfiguracja VM
`vm/USOS-Vista-Native-USB/USOS-Vista-Native-USB.vbox` w tym samym katalogu.

## Granice wyniku

Instalacja na MS-7100 jest potwierdzona przez użytkownika, z powyższym
zastrzeżeniem dotyczącym restartów. Sprawdzony obraz to
`pl_windows_vista_with_sp2_x64_dvd_x15-36359.iso`. Inne wydania i architektury
wymagają osobnej walidacji. Aktualnie ścieżka wymaga UDF, `install.wim`, zwykłego
pliku ISO na NTFS i nazwy pliku ASCII; nie obsługuje podzielonego WIM/ESD,
szyfrowania, kompresji NTFS ani plików sparse. Brak wymaganego pliku lub błędna
tożsamość źródła kończą start komunikatem, bez przechodzenia do przygotowania
WORK. Na komputerze po pierwszym restarcie samej Visty trzeba uruchomić dysk
docelowy, np. przez wyjęcie USOS; nie należy ponownie rozpoczynać instalacji.

Powtarzalny test zawartości:

```text
tools/zig/zig.exe build windows-native-io-probe -Doptimize=ReleaseFast
python tools/tests/test_windows_native_iso_io.py <raw-disk> <oryginalne-ISO>
```

Kierunek dalszej przebudowy całego pendrive'a:
[architektura według rodzin systemów](boot-architecture-direction-2026-09-11.md).
