# Testowanie

## Lokalny toolchain

Projekt korzysta z `tools/zig/zig.exe`. Nie wymaga Ziga w PATH.

## Testy hosta

- `test.bat` - wszystkie testy jednostkowe.
- `selftest.bat` - te same krytyczne kontrole, które wykonuje system podczas startu.
- `build.bat` - pełny build ReleaseFast programu USB i instalatora. Zawsze przebudowuje payload, uruchamia testy Go i kończy się kontrolą spójności SHA-256.

## QEMU x86_64

Preferowana lokalizacja: `tools/qemu/`.

`qemu-test-x86_64.bat`:
1. buduje specjalny obraz testowy,
2. uruchamia go jako UEFI x86_64,
3. przekazuje log przez port szeregowy,
4. używa `isa-debug-exit`, więc system sam kończy emulator,
5. zwraca kod 0 tylko po prawidłowym zakończeniu autotestu.

Skrypt potrafi też użyć `C:\Program Files\qemu`, ale lokalny katalog projektu ma pierwszeństwo.

## QEMU NTFS Windows handoff

`zig build fetch-ntfs-driver` pobiera EfiFs 1.12 `ntfs_x64.efi` i sprawdza jego rozmiar oraz SHA-256. `zig build prepare-ntfs-handoff-image` używa tymczasowego file-backed VHD wyłącznie do przygotowania systemów plików, po czym zapisuje bazę `test-images/usos-handoff-base.qcow2` i usuwa staging VHD. `zig build prepare-ntfs-handoff-overlay` tworzy świeżą warstwę różnicową `test-images/usos-handoff.qcow2`. QEMU uruchamia overlay, a nie pełną kopię obrazu. Test nie może wskazywać fizycznego dysku.

`zig build run-ntfs-handoff-qemu` uruchamia obraz z modelem CPU `max`, wymaganym przez testowane Windows 11 25H2. Domyślny model QEMU `qemu64` nie ma kompletu wymaganych cech procesora i prowadzi do triple fault około 15 sekund po `StartImage`, co nie jest błędem EfiFs ani chainloadera.

Wszystkie trwałe obrazy testowe QEMU mają być qcow2 w `test-images/`; nie tworzymy nowych raw `usos.img` w `zig-out`. Pełne bazy są współdzielone, a kolejne próby używają warstw różnicowych.

`zig build prepare-e2e-base` przygotowuje docelowy nośnik pełnego przepływu: ESP FAT32 z USOS i EfiFs, DATA NTFS z prawdziwym ISO Windows 11 i opcjonalnym unattended oraz pusty WORK NTFS/Microsoft Basic Data z `.usos-work` i zgodnym nonce. `zig build prepare-e2e-overlay` tworzy świeży `test-images/usos-e2e.qcow2` z backing file `usos-e2e-base.qcow2`. Ten overlay jest przeznaczony do testu `USOS → prepare-requested → mikro-Linux → prepared → reboot → handoff → Windows Setup`.

`zig build micro-linux` buduje rzeczywisty kernel i initramfs mikro-Linuksa oraz loader EFI. Artefakty Alpine są przypięte wersją i SHA-256 w `tools/micro_linux.lock.json`. Initramfs zawiera tylko narzędzia potrzebne do identyfikacji partycji, kontroli guarda, NTFS, kopiowania i publikacji stanu. Hostowy PowerShell służy wyłącznie do utworzenia plikowych obrazów qcow2; przygotowanie WORK wykonuje mikro-Linux uruchomiony wewnątrz QEMU.

Test negatywny można zbudować parametrem `-GuardTestBadPartuuid` skryptu `tools/prepare_e2e_base.ps1`. Parametr trafia wyłącznie do testowej linii poleceń kernela: mikro-Linux przekazuje błędny identyfikator do prawdziwego `device_guard.sh`, wymaga jego niezerowego wyniku i zatrzymuje się przed `mkfs.ntfs`. Każda próba korzysta ze świeżego differential overlayu, a nie z fizycznego urządzenia.

Potwierdzony pełny przebieg używa `-cpu max` i wykonuje w jednej VM: menu USOS, `prepare-requested`, backup `BootOrder`, `BootNext`, mikro-Linux, guard, format i marker WORK, ekstrakcję z weryfikacją, `prepared`, reboot, EfiFs oraz Windows Setup. Sukces wizualny oznacza ekran wyboru lokalizacji instalacji z widocznymi `USOS_DATA` i `USOS_WORK`; test kończy się przed rozpoczęciem instalacji.

Regresja UI/backend musi dodatkowo potwierdzić, że tylko Windows 11 + ISO + metoda `ISO` jest aktywna. Pozostałe systemy i metody mają pozostać widoczne, lecz niewybieralne z komunikatem o aktualnym ograniczeniu backendu. Test jednostkowy kontraktu wymaga również jawnego błędu `UnsupportedMethod` dla przykładowego `VHDBoot`; backend nie może ignorować metody wybranej przez UI.

Artefakty, testy i logi wcześniejszego przebiegu pozostają zachowane co najmniej do czasu przejścia przez nowy build całej tej samej macierzy. Dowody sprzed scalenia oraz manifest SHA-256 znajdują się w `docs/evidence/pre-merge/`.

Runner zachowuje:

- `serial.log` z etapami USOS i zweryfikowaną ścieżką `LoadedImage`,
- serię `screen-*.ppm` (gęstą w pierwszych sekundach, rzadszą później),
- `qmp-events.log`, który odróżnia reset gościa, shutdown i zatrzymanie przez runner,
- `qemu-debug.log` z resetami CPU i triple fault,
- `qemu.stderr.log`.

Samo `WINDOWS STARTIMAGE BEGIN` nie jest wynikiem końcowym. Screenshot musi potwierdzić GUI Setup, a osobny dowód po przejściu początkowych ekranów musi potwierdzić, że Setup widzi `sources/install.wim`.

## QEMU / WinPE — instalator Windows host backend

`tools/run_installer_gpt_qemu.ps1` uruchamia Windows Setup/WinPE w QEMU i podłącza osobny plik `test-images/usos-installer-gpt-target.qcow2` jako `usb-storage` z `removable=on` oraz testowym serialem `USOS-GPT-TEST`. Kod testowy odmawia działania, jeżeli nie znajdzie dokładnie jednego urządzenia z tym serialem i oczekiwaną pojemnością. Fizyczne dyski hosta nie są przekazywane do QEMU i nie mogą być celem testu.

Potwierdzony destrukcyjny przebieg wykonuje na tym obrazie: blokadę i rewalidację otwartego `PhysicalDrive`, `IOCTL_DISK_DELETE_DRIVE_LAYOUT`, `IOCTL_DISK_CREATE_DISK`, `IOCTL_DISK_SET_DRIVE_LAYOUT_EX` oraz ścisły read-back przez `IOCTL_DISK_GET_DRIVE_LAYOUT_EX`. Rewalidacja porównuje model, serial i pojemność z zatwierdzoną tożsamością urządzenia. Read-back porównuje disk GUID, PARTUUID-y, typy GPT, offsety i rozmiary; każda niezgodność zatrzymuje test bez próby naprawy.

Test wykrył również niedyskowy wolumin WinPE, dla którego `IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS` zwraca `ERROR_INVALID_FUNCTION`. Guard klasyfikuje taki przypadek dodatkowo przez `IOCTL_STORAGE_GET_DEVICE_NUMBER`: wolumin niedyskowy może zostać pominięty, natomiast wolumin należący do celu lub niemożliwy do jednoznacznej klasyfikacji nadal powoduje FAIL przed pierwszą operacją niszczącą.

Potwierdzony wynik testu dla obrazu 40 GiB: ESP 1 GiB, DATA do granicy WORK oraz WORK 12 GiB, trzy unikalne PARTUUID-y i poprawny `qemu-img check` po zakończeniu. Wszystkie kolejne testy formatowania, payloadu i tożsamości instalatora mają rozszerzać ten sam scenariusz QEMU/WinPE, nigdy fizyczny pendrive.

## Obrazy UEFI

Po pełnym buildzie:

- `zig-out/usb/EFI/BOOT/BOOTX64.EFI` - x86_64,
- `zig-out/usb/EFI/BOOT/BOOTAA64.EFI` - ARM64.

Oba pliki mogą znajdować się na tej samej partycji EFI/FAT.

`BOOTX64.EFI` dla `zig-out/usb` i `zig-out/manual-usb` powstaje z jednego obiektu kompilacji, więc wersja testowa i wersja zapisywana na pendrive nie mają osobnych implementacji. `tools/verify_release_consistency.ps1` dodatkowo porównuje ich SHA-256 i sprawdza każdy plik `zig-out/usb` z zawartością ZIP-a wbudowanego w instalator. Brak UI, ikon, systemów, pliku `win10-11 best-ustawienia.xml` albo jakakolwiek niezgodność przerywa `build.bat`.
