# Universal Service OS — nośnik

Ten nośnik zawiera bootmanager Universal Service OS (USOS) oraz miejsce na obrazy systemów, sterowniki i narzędzia. USOS nie jest systemem operacyjnym. Uruchamia środowisko potrzebne do przygotowania i startu instalatora wybranego systemu.

## Układ partycji

- **ESP** — partycja startowa FAT32. Zawiera bootmanager USOS, sterownik NTFS UEFI i pliki środowiska startowego.
- **DATA** — zwykła partycja NTFS widoczna dla użytkownika. Tutaj znajdują się obrazy ISO, sterowniki, narzędzia i kopia instalatora USOS.
- **WORK** — ukryta partycja robocza NTFS. Jest używana podczas instalacji systemu i może być czyszczona przed kolejną instalacją. Nie należy przechowywać na niej własnych plików.

## Dodawanie obrazu ISO

Skopiuj plik ISO do katalogu:

`DATA:\ISO`

Nie zapisuj obrazów ani własnych plików na partycji WORK.

## Instalator USOS

Kopia instalatora znajduje się w:

`DATA:\TOOLS\USOS Installer.exe`

Nie uruchamiaj instalatora bezpośrednio z pendrive'a. Najpierw skopiuj `USOS Installer.exe` na dysk komputera, a następnie uruchom go jako administrator.

Instalator ma trzy tryby:

- **Instalacja** — przygotowuje nośnik USOS od początku. Formatuje cały wybrany nośnik i usuwa wszystkie znajdujące się na nim dane.
- **Naprawa** — odtwarza pliki startowe na ESP poprawnie rozpoznanego nośnika USOS. Nie formatuje DATA ani WORK.
- **Deinstalacja** — usuwa układ USOS i przywraca nośnik do jednej zwykłej partycji exFAT. Dane z katalogów `ISO`, `TOOLS` i `DRIVERS` zostają usunięte.

## Log

Instalator zapisuje log operacji jako:

`USOS Installer.log`

Plik logu znajduje się obok uruchomionego `USOS Installer.exe`.
