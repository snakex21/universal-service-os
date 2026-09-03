# Testowanie

## Lokalny toolchain

Projekt korzysta z `tools/zig/zig.exe`. Nie wymaga Ziga w PATH.

## Testy automatyczne

Wszystkie techniczne testy mają jedno wejście: `tools/tests/run.ps1`.

- `-Suite all` - testy jednostkowe, selftest oraz QEMU x86_64 i ARM64,
- `-Suite unit` - tylko testy jednostkowe,
- `-Suite selftest` - krytyczne kontrole startowe,
- `-Suite x86_64` - automatyczny boot UEFI x86_64 w QEMU,
- `-Suite aarch64` - automatyczny boot UEFI ARM64 w QEMU.

Przykład pełnej macierzy: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/tests/run.ps1 -Suite all`.

`build.bat` pozostaje osobnym wejściem do pełnego builda ReleaseFast programu USB i instalatora. Zawsze przebudowuje payload, uruchamia testy Go i kończy się kontrolą spójności SHA-256.

## QEMU x86_64

Preferowana lokalizacja: `tools/qemu/`.

Do ręcznego testu pełnej instalacji używaj `TEST-USOS.cmd`. Skrypt uruchamia aktualny USOS w QEMU, automatycznie przebudowuje bazę tylko wtedy, gdy zmienił się kod lub zawartość `media/`, tworzy świeży stan sesji i osobny wirtualny dysk docelowy Windows. Można przejść cały przepływ od menu USOS, przez ekran `Loading Windows ISO`, mikro-Linux i Windows Setup aż do instalacji systemu na tym wirtualnym dysku. Launcher najpierw próbuje WHPX; jeżeli Windows nie udostępnia akceleratora, automatycznie wraca do wielowątkowego TCG. UEFI pokazuje nazwę bieżącej operacji handoffu bez zmyślonego procentu, mikro-Linux pokazuje kolejne etapy przygotowania, a rzeczywisty procent, liczbę bajtów, prędkość i ETA pokazujemy dopiero podczas mierzalnego kopiowania plików Windows.

Po zakończonym teście `RESET-USOS-TEST.cmd` usuwa wyłącznie wirtualny dysk z zainstalowanym Windowsem oraz stan sesji USOS. Baza z prawdziwym ISO pozostaje, dzięki czemu kolejna próba nie wymaga ponownego kopiowania obrazu 7,8 GB. Fizyczne dyski hosta nie są przekazywane do tego testu.

## Szybki test na fizycznym pendrivie

Po zmianach uruchom `build.bat`, a następnie `installer\USOS Installer.exe` i wybierz `Aktualizuj USOS`. Ten tryb ponownie identyfikuje istniejący nośnik USOS, wymusza ukrycie WORK (`NoDefaultDriveLetter` i brak litery dysku), wgrywa aktualny statyczny payload ESP oraz bieżący instalator na DATA, a następnie odbudowuje katalog menu ESP z faktycznej zawartości DATA. Nazwy obrazów są synchronizowane jako wpisy zerowej długości, unattended i `icon.png` jako małe metadane; duże ISO/WIM/IMG/VHD/VHDX pozostają wyłącznie na DATA. Nie formatuje partycji ani nie usuwa danych użytkownika. Końcowa weryfikacja porównuje katalog ESP z DATA oraz SHA-256 plików, które muszą być identyczne.

Automatyczny wariant x86_64 uruchamia `tools/tests/run.ps1 -Suite x86_64`: buduje specjalny obraz testowy, startuje UEFI w QEMU, przekazuje log przez port szeregowy i używa `isa-debug-exit`, więc emulator kończy się jednoznacznym PASS/FAIL. Lokalny `tools/qemu/` ma pierwszeństwo; dla x86_64 runner potrafi też użyć `C:\Program Files\qemu`.

## QEMU NTFS Windows handoff

`zig build fetch-ntfs-driver` pobiera EfiFs 1.12 `ntfs_x64.efi` i sprawdza jego rozmiar oraz SHA-256. `zig build prepare-ntfs-handoff-image` używa tymczasowego file-backed VHD wyłącznie do przygotowania systemów plików, po czym zapisuje bazę `tools/tests/artifacts/qemu/usos-handoff-base.qcow2` i usuwa staging VHD. `zig build prepare-ntfs-handoff-overlay` tworzy świeżą warstwę różnicową `tools/tests/artifacts/qemu/usos-handoff.qcow2`. QEMU uruchamia overlay, a nie pełną kopię obrazu. Test nie może wskazywać fizycznego dysku.

`zig build run-ntfs-handoff-qemu` uruchamia obraz z modelem CPU `max`, wymaganym przez testowane Windows 11 25H2. Domyślny model QEMU `qemu64` nie ma kompletu wymaganych cech procesora i prowadzi do triple fault około 15 sekund po `StartImage`, co nie jest błędem EfiFs ani chainloadera.

Wszystkie trwałe obrazy testowe QEMU są trzymane w `tools/tests/artifacts/qemu/`; nie tworzymy nowych raw `usos.img` w katalogu głównym. Pełne bazy są współdzielone, a kolejne próby używają warstw różnicowych.

`zig build prepare-e2e-base` przygotowuje docelowy nośnik pełnego przepływu: ESP FAT32 z USOS i EfiFs, DATA NTFS z prawdziwym ISO Windows 11 i opcjonalnym unattended oraz pusty WORK NTFS/Microsoft Basic Data z `.usos-work` i zgodnym nonce. `zig build prepare-e2e-overlay` tworzy świeży `tools/tests/artifacts/qemu/usos-e2e.qcow2` z backing file `usos-e2e-base.qcow2`. Ten overlay jest przeznaczony do testu `USOS → prepare-requested → mikro-Linux → prepared → reboot → handoff → Windows Setup`.

`zig build micro-linux` buduje rzeczywisty kernel i initramfs mikro-Linuksa oraz loader EFI. Artefakty Alpine są przypięte wersją i SHA-256 w `tools/micro_linux.lock.json`. Initramfs zawiera tylko narzędzia potrzebne do identyfikacji partycji, kontroli guarda, NTFS, kopiowania i publikacji stanu. Hostowy PowerShell służy wyłącznie do utworzenia plikowych obrazów qcow2; przygotowanie WORK wykonuje mikro-Linux uruchomiony wewnątrz QEMU.

Test negatywny można zbudować parametrem `-GuardTestBadPartuuid` skryptu `tools/prepare_e2e_base.ps1`. Parametr trafia wyłącznie do testowej linii poleceń kernela: mikro-Linux przekazuje błędny identyfikator do prawdziwego `device_guard.sh`, wymaga jego niezerowego wyniku i zatrzymuje się przed `mkfs.ntfs`. Każda próba korzysta ze świeżego differential overlayu, a nie z fizycznego urządzenia.

Potwierdzony pełny przebieg używa `-cpu max` i wykonuje w jednej VM: menu USOS, `prepare-requested`, backup `BootOrder`, `BootNext`, mikro-Linux, guard, format i marker WORK, ekstrakcję z weryfikacją, `prepared`, reboot, EfiFs oraz Windows Setup. Sukces wizualny oznacza ekran wyboru lokalizacji instalacji z widocznymi `USOS_DATA` i `USOS_WORK`; test kończy się przed rozpoczęciem instalacji.

Regresja UI/backend musi potwierdzić, że dla Windows 11 + ISO lista metod zawiera wyłącznie rzeczywiście działające opcje: `Automatic (ISO)` oraz `ISO`. `Automatic` rozwiązuje się do tego samego zweryfikowanego backendu `direct_iso`. Metody niezgodne z typem obrazu albo bez zaimplementowanego backendu nie są pokazywane jako martwe placeholdery. Test jednostkowy kontraktu nadal wymaga jawnego błędu `UnsupportedMethod` dla przykładowego `VHDBoot`; backend nie może ignorować metody wybranej przez UI.

Artefakty, testy i logi wcześniejszego przebiegu pozostają zachowane co najmniej do czasu przejścia przez nowy build całej tej samej macierzy. Dowody sprzed scalenia oraz manifest SHA-256 znajdują się w `docs/evidence/pre-merge/`.

Runner zachowuje:

- `serial.log` z etapami USOS i zweryfikowaną ścieżką `LoadedImage`,
- serię `screen-*.ppm` (gęstą w pierwszych sekundach, rzadszą później),
- `qmp-events.log`, który odróżnia reset gościa, shutdown i zatrzymanie przez runner,
- `qemu-debug.log` z resetami CPU i triple fault,
- `qemu.stderr.log`.

Samo `WINDOWS STARTIMAGE BEGIN` nie jest wynikiem końcowym. Screenshot musi potwierdzić GUI Setup, a osobny dowód po przejściu początkowych ekranów musi potwierdzić, że Setup widzi `sources/install.wim`.

## QEMU / WinPE — instalator Windows host backend

`tools/run_installer_gpt_qemu.ps1` uruchamia Windows Setup/WinPE w QEMU i podłącza osobny plik `tools/tests/artifacts/qemu/usos-installer-gpt-target.qcow2` jako `usb-storage` z `removable=on` oraz testowym serialem `USOS-GPT-TEST`. Kod testowy odmawia działania, jeżeli nie znajdzie dokładnie jednego urządzenia z tym serialem i oczekiwaną pojemnością. Fizyczne dyski hosta nie są przekazywane do QEMU i nie mogą być celem testu.

Potwierdzony destrukcyjny przebieg wykonuje na tym obrazie: blokadę i rewalidację otwartego `PhysicalDrive`, `IOCTL_DISK_DELETE_DRIVE_LAYOUT`, `IOCTL_DISK_CREATE_DISK`, `IOCTL_DISK_SET_DRIVE_LAYOUT_EX` oraz ścisły read-back przez `IOCTL_DISK_GET_DRIVE_LAYOUT_EX`. Rewalidacja porównuje model, serial i pojemność z zatwierdzoną tożsamością urządzenia. Read-back porównuje disk GUID, PARTUUID-y, typy GPT, offsety i rozmiary; każda niezgodność zatrzymuje test bez próby naprawy.

Test wykrył również niedyskowy wolumin WinPE, dla którego `IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS` zwraca `ERROR_INVALID_FUNCTION`. Guard klasyfikuje taki przypadek dodatkowo przez `IOCTL_STORAGE_GET_DEVICE_NUMBER`: wolumin niedyskowy może zostać pominięty, natomiast wolumin należący do celu lub niemożliwy do jednoznacznej klasyfikacji nadal powoduje FAIL przed pierwszą operacją niszczącą.

Potwierdzony wynik testu dla obrazu 40 GiB: ESP 1 GiB, DATA do granicy WORK oraz WORK 12 GiB, trzy unikalne PARTUUID-y i poprawny `qemu-img check` po zakończeniu. Wszystkie kolejne testy formatowania, payloadu i tożsamości instalatora mają rozszerzać ten sam scenariusz QEMU/WinPE, nigdy fizyczny pendrive.

## Obrazy UEFI

Po pełnym buildzie:

- `zig-out/usb/EFI/BOOT/BOOTX64.EFI` - x86_64,
- `zig-out/usb/EFI/BOOT/BOOTAA64.EFI` - ARM64.

Oba pliki mogą znajdować się na tej samej partycji EFI/FAT.

`BOOTX64.EFI` dla `zig-out/usb` i `zig-out/manual-usb` powstaje z jednego obiektu kompilacji, więc wersja testowa i wersja zapisywana na pendrive nie mają osobnych implementacji. `tools/verify_release_consistency.ps1` porównuje ich SHA-256 i sprawdza, że ZIP wbudowany w instalator zawiera wyłącznie aktualne statyczne pliki ESP (`EFI` i `UI`). `Systems`, `Utilities`, `Programs`, obrazy i unattended nie są już statycznie dublowane w EXE; katalog menu ESP jest generowany z DATA przez instalator/updater.
