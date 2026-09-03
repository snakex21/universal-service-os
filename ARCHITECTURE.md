# Architektura

## Warstwy

1. `src/core` - typy i logika całkowicie niezależna od platformy.
2. `src/kernel` - sekwencja startu i polityka działania kernela.
3. `src/selftest` - mały framework autotestów używany przy starcie i w testach developerskich.
4. `src/arch/x86` - kod zależny od x86/x86_64.
5. `src/arch/aarch64` - kod zależny od ARM64.
6. `src/platform` - firmware i platforma startowa, np. BIOS/UEFI.
7. `src/catalog` - wyłącznie dane katalogu: kategorie, profile, formaty obrazów i dozwolone metody startu.
8. `src/gui` - mały renderer framebufferu oraz parser używanego podzbioru HTML/CSS.
9. `src/tools` - narzędzia developerskie korzystające z tego samego kodu co system.

Loader obrazu będzie osobną warstwą z małymi modułami per technika (`ISO`, `WIMBoot`, `VHDBoot`, `EFI`, `Memdisk`, chainload) dopiero wtedy, gdy implementujemy daną technikę. Katalog i GUI nie mogą zawierać kodu konkretnego loadera.

## Rozpoznawanie obrazów optycznych

Sygnatura `CD001` potwierdza wyłącznie obecność ISO9660 i nigdy nie oznacza, że obraz zawiera Windows. Klasyfikacja systemu następuje dopiero po odczycie katalogu obrazu i znalezieniu charakterystycznych plików instalatora. Nierozpoznany obraz pozostaje `unknown`.

Dla obrazów optycznych parser najpierw używa UDF. ISO9660 jest ścieżką zapasową dla starszych obrazów bez UDF. Rozmiary plików UDF są przechowywane jako 64-bitowe, dzięki czemu pliki takie jak `sources/install.wim` większe niż 4 GB nie są obcinane do limitu ISO9660.

## Katalog użytkownika

Najwyższy poziom GUI i nośnika rozdziela Windows, Linux, Beta builds, DOS i Utilities. `Programs` pozostaje osobno, ponieważ służy do instalacji aplikacji po wdrożeniu systemu, a nie do bootowania narzędzi.

## Zasada kompatybilności

Kod wspólny nie może zakładać obecności UEFI, BIOS, x86 ani ARM64. Funkcje zależne od platformy są wystawiane przez mały interfejs platformowy.

## x86

Docelowo:
- Legacy BIOS,
- UEFI IA32/x64,
- stary x86 bez obowiązkowego SSE2 jako ścieżka zgodności,
- x86_64 dla nowego sprzętu,
- warstwa zgodności z programami DOS.

## ARM64

Docelowo:
- UEFI ARM64 jako pierwszy sposób startu,
- natywne narzędzia ARM64,
- uruchamianie instalatorów i obrazów przeznaczonych dla ARM64,
- brak emulowania DOS jako podstawowej funkcji.

## Start i testowanie

- krytyczny autotest jest częścią normalnego startu i nie używa alokatora,
- ciężkie testy sprzętu nie blokują pokazania interfejsu i są uruchamiane osobno,
- QEMU: codzienny boot i automatyczne testy,
- log szeregowy jako główne źródło diagnostyki,
- osobne profile x86, x86_64 i ARM64,
- finalna zgodność jest sprawdzana również na prawdziwym sprzęcie BIOS/UEFI.

## Sterownik NTFS podczas handoffu Windows

Podstawowym sterownikiem NTFS UEFI testowanym w QEMU jest EfiFs 1.12 (`ntfs_x64.efi`). USOS ładuje sterownik z ESP, odnajduje WORK przez `EFI_SIMPLE_FILE_SYSTEM_PROTOCOL`, rozwiązuje rzeczywisty casing każdego komponentu ścieżki i uruchamia Windows Boot Manager przez `LoadImage` z device path partycji WORK. Nie ładujemy boot managera z bufora, ponieważ Windows potrzebuje poprawnego urządzenia źródłowego w `EFI_LOADED_IMAGE_PROTOCOL`.

Alternatywą pozostaje sterownik NTFS używany przez Rufusa / UEFI:NTFS. Można go wymienić bez zmiany głównej architektury: ESP nadal dostarcza driver, a boot manager nadal startuje z WORK przez device path. Ta alternatywa nie została jeszcze przetestowana w USOS.

Test z Windows 11 25H2 potwierdził end-to-end ścieżkę EfiFs → WORK NTFS → Windows Boot Manager → WinPE → Windows Setup. Niestandardowy typ GPT WORK `5FFAC520-C2EB-4987-AF65-43962AD8A589` został odrzucony: natywny stos dyskowy WinPE nie montował takiej partycji jako nośnika danych i Setup zgłaszał brak wymaganego sterownika nośnika. Po zmianie WORK na Microsoft Basic Data `EBD0A0A2-B9E5-4433-87C0-68B6B72699C7` Setup poprawnie odnajduje rozpakowane źródło instalacji i przechodzi dalej. FAT32 + dzielone `install.swm` nie jest potrzebne jako główna ścieżka.

Ponieważ Microsoft Basic Data nie identyfikuje WORK jednoznacznie, `device_guard` opiera decyzję przede wszystkim na zapisanym PARTUUID i zgodnym dysku nadrzędnym, a następnie wymaga dodatkowej tożsamości: etykiety `USOS_WORK` oraz pliku `.usos-work` z nonce zgodnym z `EFI/USOS/usos-device.ini`. Przed formatowaniem istniejącego WORK nonce i etykieta muszą się zgadzać. Przy pierwszym użyciu świeżej partycji, gdy znacznika jeszcze nie ma, guard wymaga jawnego potwierdzenia PARTUUID, rozmiaru i aktualnej etykiety oraz planowanej etykiety `USOS_WORK`. Po formatowaniu `.usos-work` jest odtwarzany jako pierwszy plik, zanim zacznie się kopiowanie instalatora.

## Szybkość startu

Do pierwszego użytecznego ekranu inicjalizujemy wyłącznie elementy konieczne do bootu, wejścia i renderowania. Sieć, rozbudowana diagnostyka, skanowanie obrazów i pozostałe usługi mają być uruchamiane dopiero wtedy, gdy są potrzebne.
