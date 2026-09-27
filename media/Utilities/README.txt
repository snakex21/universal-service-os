Universal Service OS - Utilities

Tutaj sam tworzysz folder dla każdego narzędzia, np.:

  Utilities\MemTest86\
  Utilities\GParted\
  Utilities\HWiNFO-UEFI\

W każdym folderze narzędzia utwórz folder Images i umieść tam plik obrazu lub program bootowalny:

  Utilities\MemTest86\Images\memtest86.efi

W tym wydaniu dołączono również obraz BIOS MemTest86+:

  Utilities\MemTest86\Images\memtest86plus-8.10-i586.iso

BIOS: Utilities -> MemTest86 -> wybierz powyzszy ISO -> Enter.
USOS odczytuje program z ISO i uruchamia go bezposrednio w pamieci.
Memtest86+ rozpoczyna test automatycznie; F1 otwiera konfiguracje,
Esc restartuje komputer. Uruchomienie testu RAM nie formatuje dyskow.
Ta sciezka obsluguje oficjalny ISO i586 Memtest86+ z BOOT/FLOPPY.IMG.
Inne typy obrazow i narzedzia moga byc widoczne w katalogu, ale nie maja
jeszcze obslugi uruchamiania BIOS. Obraz EFI wymaga osobnej sciezki UEFI.

Obsługiwane typy katalogowe: ISO, WIM, IMG, VHD, VHDX i EFI.

Opcjonalna ikona narzędzia:

  Utilities\MemTest86\icon.png

icon.png musi być prawidłowym plikiem PNG i mieć maksymalnie 1 MiB.
Po dodaniu, usunięciu lub zmianie narzędzia albo icon.png uruchom Aktualizuj USOS. Aktualizator odświeży mały katalog metadanych na ESP bez kopiowania dużych obrazów.

Powłoka UEFI (EDK2 UEFI Shell) jest wbudowana, tylko w trybie UEFI:
Utilities -> Powłoka UEFI. Własne narzędzia EFI (flashery BIOS/VBIOS,
testery GPU/VRAM typu NVIDIA MATS/MODS, memtest86 w wersji .efi) wrzuć
razem z ich plikami do:

  Utilities\UEFI Shell\Tools\

Powłoka sama znajduje DATA (np. fs2:) i przechodzi do tego folderu;
map -r pokazuje wszystkie dyski, exit wraca do menu. DATA jest w powłoce
tylko do odczytu - kopię ROM zapisuj na USOS_ESP albo pendrive FAT32.
Przy włączonym Secure Boot powłoka startuje, ale nie uruchamia narzędzi
.efi - do flashowania/testów wyłącz Secure Boot.
Szczegóły: Utilities\UEFI Shell\README.txt. Program .efi można też
umieścić w Utilities\<Nazwa>\Images\ (osobna pozycja w menu po
Aktualizuj USOS). USOS nie dołącza żadnego z tych narzędzi.

Partycja robocza jest widoczna jako USOS_WORK. Nie wrzucaj tam żadnych plików — jej zawartość jest usuwana przed każdą instalacją.
