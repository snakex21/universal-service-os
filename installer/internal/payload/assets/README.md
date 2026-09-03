# Universal Service OS — nośnik

Ten nośnik zawiera bootmanager Universal Service OS (USOS) oraz miejsce na obrazy systemów i narzędzia. USOS nie jest systemem operacyjnym. Uruchamia środowisko potrzebne do przygotowania i startu instalatora wybranego systemu.

## Układ partycji

- **ESP** — partycja startowa FAT32. Zawiera bootmanager USOS, sterownik NTFS UEFI, UI i pliki środowiska startowego.
- **DATA** — zwykła partycja NTFS widoczna dla użytkownika. Tutaj znajdują się obrazy systemów, unattended, narzędzia i kopia instalatora USOS.
- **WORK** — ukryta partycja robocza NTFS. Jest używana podczas instalacji systemu i może być czyszczona przed kolejną instalacją. Nie należy przechowywać na niej własnych plików.

## Dodawanie systemów i narzędzi

DATA zawiera gotowe profile Windows, Linux, beta/prototypów Windows i DOS. Obraz kopiuj do katalogu `Images` odpowiedniego profilu, np.:

`DATA:\Systems\Windows\Windows 11\Images`

Pliki odpowiedzi instalatora przechowuj w `Unattended`, np.:

`DATA:\Systems\Windows\Windows 11\Unattended`

`Utilities` jest dynamiczne. Sam tworzysz folder narzędzia i katalog `Images`, np.:

`DATA:\Utilities\MemTest86\Images\memtest86.efi`

Opcjonalna ikona systemu lub narzędzia to `icon.png` umieszczone obok katalogu `Images`. Po dodaniu/usunięciu obrazu, unattended, narzędzia lub ikony uruchom **Aktualizuj USOS**. Aktualizator synchronizuje mały katalog menu na ESP; duże obrazy pozostają tylko na DATA.

Nie zapisuj obrazów ani własnych plików na partycji WORK.

## Instalator USOS

Kopia instalatora znajduje się w:

`DATA:\Programs\USOS\USOS Installer.exe`

Nie uruchamiaj instalatora bezpośrednio z pendrive'a. Najpierw skopiuj `USOS Installer.exe` na dysk komputera, a następnie uruchom go jako administrator.

Instalator ma cztery tryby:

- **Instalacja** — przygotowuje nośnik USOS od początku. Formatuje cały wybrany nośnik i usuwa wszystkie znajdujące się na nim dane.
- **Aktualizacja lokalna** — wgrywa aktualny build USOS na istniejący nośnik, synchronizuje katalog menu ESP z DATA i nie usuwa obrazów ani własnych danych.
- **Naprawa** — odtwarza pliki startowe na ESP poprawnie rozpoznanego nośnika USOS. Nie formatuje DATA ani WORK.
- **Deinstalacja** — usuwa układ USOS i przywraca nośnik do jednej zwykłej partycji exFAT. Zawartość DATA, w tym `Systems`, `Utilities` i `Programs`, zostaje usunięta.

## Log

Instalator zapisuje log operacji jako:

`USOS Installer.log`

Plik logu znajduje się obok uruchomionego `USOS Installer.exe`.
