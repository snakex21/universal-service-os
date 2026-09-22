# Windows 7 BIOS: porównanie metod rozruchu

Użytkownik ponownie zgłosił zatrzymanie na `Entering bootmgr.exe`, już bez pauzy. Widoczny tekst oznacza osiągnięcie końcowego odcinka wimboot; nie potwierdza jeszcze wykonania kodu bootmgr ani dokładnej funkcji firmware, która blokuje rozruch. Korekta VGA poprawiła czytelność, usunięcie pauzy nie rozwiązało awarii. Wyników VM nie wolno przedstawiać jako potwierdzenia działania MS-7100.

## Źródła pierwotne sprawdzone 2026-09-10

- [iPXE: wimboot](https://ipxe.org/wimboot): udokumentowany start z programu rozruchowego iPXE, odczyt WIM i przekazanie sterowania Windows. `pause` jest wyłącznie opcją diagnostyczną, `linear` wyłącza przenoszenie przez paging. Dokument nie daje gwarancji poprawnego powrotu z uruchomionego Linuksa przez kexec.
- [iPXE: architektura wimboot](https://ipxe.org/appnote/wimboot_architecture): wimboot buduje wirtualny system plików i uruchamia bootmgr.exe; następnie bootmgr czyta BCD, tworzy ramdisk i uruchamia winload.exe. Samo `Entering bootmgr.exe` nie oznacza ukończenia tych operacji.
- [Easy2Boot: Windows ISO](https://easy2boot.xyz/create-your-website-with-blocks/add-payload-files/windows-install-isos/): start z menu E2B/agFM; WIMBOOT dla standardowych obrazów Vista+ i ponad 1,3 GB RAM. 2 GB użytkownika nie wyklucza tej metody, ale nie jest gwarancją zgodności całego sprzętu.
- [Easy2Boot: WIMBOOT i WinPE](https://easy2boot.xyz/troubleshooting-e2b/wimboot-and-the-winpe-boot-process/): rozróżnia start WIM i późniejszy launcher instalatora; opisuje alternatywną ścieżkę NoWimboot. Nie należy mylić uruchomienia setup.exe wewnątrz WinPE z uruchomieniem WinPE z BIOS-u.
- [Rufus: format.c](https://github.com/pbatard/rufus/blob/master/src/format.c): dla obrazów BOOTMGR zapisuje odpowiedni sektor FAT32 PE albo NTFS. Przygotowuje nośnik do rozruchu; nie wymaga startowania Linux/kexec przed Windows.

## Porównanie z USOS

Obecna domyślna ścieżka: menu BIOS -> mikro-Linux -> przygotowanie źródła i CPIO -> kexec -> zmodyfikowany wimboot -> bootmgr. Problem po kexec pozostaje hipotezą wymagającą próby porównawczej na sprzęcie. Dodawanie kolejnych wyjątków INT13 bez takiej kontroli nie daje wystarczającego dowodu.

Istnieje już druga ścieżka: `core_main.zig` wywołuje `windows_work_chainload.runIfReady` przed menu/mikro-Linuksem. Odczytuje 512-bajtowy znacznik z GUID-em WORK, przygotowuje oryginalny wimboot i archiwum, konsumuje znacznik z odczytem kontrolnym, a następnie przechodzi do real mode. Nie uruchamia Linuksa ani kexec. Korzysta z przygotowanych wcześniej danych, dlatego kontrola nie wymaga ponownego rozpakowania ISO ani dodatkowego restartu po przygotowaniu.

Skrypt `zig-out/win7-arm-direct.ps1` sprawdza tożsamość fizycznego Kingstona i partycji, hash oryginalnego wimboot, rozmiar archiwum oraz log przygotowania właściwego ISO. Zmienia wyłącznie znacznik jednorazowego startu. To kontrola diagnostyczna istniejącej ścieżki, nie ukończona integracja automatycznego startu dowolnego ISO.

Znacznik został zapisany i odczytany kontrolnie na Kingstonie (`cursor-report/direct-arm-result.txt`, PASS). Wersja Core/instalatora pozostaje B260910-162845-7DBC83DC. Hash oryginalnego wimboot: `5f067ccdc4d084d5bf77b6c853bd0f8402dfc2b4cd1b103d358993ae97fae8e3`; hash fizycznego przygotowanego CPIO: `6e86f1939671dbc737a4eee9656cb4599d4fe1bdd4070bf0850283a1b44d3a49`. Najbliższy start Kingstona ma automatycznie uruchomić tę kontrolę przed menu, bez uruchomienia mikro-Linuksa. Znacznik jest konsumowany przed przejściem do wimboot, dzięki czemu nie tworzy automatycznej pętli kolejnych instalacji. Nadal wymagany jest wynik na fizycznym MS-7100.

Docelowy kierunek, jeśli kontrola fizyczna się powiedzie: przygotowywanie potrzebnych plików podczas dodawania ISO na USB oraz start wybranej paczki bezpośrednio z menu BIOS. Wymaga to powiązania paczki z konkretnym źródłem, walidacji jej aktualności i obsługi braku gotowej paczki. Nie należy automatycznie dodawać nieuzgodnionego restartu do zwykłego przepływu instalacji.

Kontrola w VM: Syslinux 6.03 z oficjalnego archiwum kernel.org, moduł linux.c32 (program rozruchowy, nie kernel Linux), oryginalny wimboot 2.9.0 i te same pliki startowe przekazane osobno przez `initrdfile=...@name`. Wynik `stock-bcd/vendor-direct.png`: okno wyboru języka Windows 7 bez kexec i bez klawiszy. To kontrola standardowej metody w VM, nie test pełnego przejścia przez USOS Core ani wynik fizyczny. Wstępne błędy konfiguracji testowego Syslinux (argument initrd, wielkość liter rozszerzenia modułu oraz zagnieżdżony CPIO) poprawiono wyłącznie w obrazie testowym; nie dotyczyły Kingstona. VM została wyłączona, źródło VHD odłączono.
