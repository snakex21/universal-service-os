# Przepływ uruchamiania obrazu

Interfejs prowadzi użytkownika kolejno:

1. wybór kategorii: Windows / Linux / Beta builds / DOS / Utilities,
2. wybór systemu, dystrybucji albo grupy narzędzi,
3. wybór obrazu z katalogu `Images`,
4. wybór metody uruchomienia zgodnej z profilem i typem obrazu,
5. opcjonalny wybór pliku z `Unattended`,
6. potwierdzenie i start.

## Format obrazu a metoda startu

Format pliku i metoda uruchomienia są rozdzielone.

- ISO: Automatic, ISO, WIMBoot, Chainload lub Memdisk zależnie od profilu.
- WIM: Automatic lub WIMBoot.
- IMG: Automatic, Disk image, Floppy image, Chainload lub Memdisk.
- VHD/VHDX: Automatic lub VHDBoot.
- EFI: Automatic, EFI lub Chainload.

Dzięki temu jeden format nie jest przypisany na stałe do jednej techniki startu.

## Przygotowanie instalatora Windows

Trwały stan przygotowania używa wartości `phase=pending`, `phase=prepare-requested`, `phase=prepared` i `phase=handoff`.

Docelowa kolejność dla instalatora Windows jest następująca:

1. USOS zapisuje `phase=prepare-requested` wraz z wybranym obrazem i opcjonalnym plikiem unattended.
2. Przed przekazaniem sterowania do mikro-Linuxa USOS odczytuje aktualny `BootOrder`, zapisuje jego dokładną kopię jako `USOSBootOrderBackup` i dopiero po udanym backupie ustawia `BootNext` na aktualny wpis `BootCurrent` USOS. `BootOrder` nie jest modyfikowany.
3. Mikro-Linux akceptuje wykonanie tylko przy `phase=prepare-requested`.
4. `device_guard.sh pre-format` musi przejść przed pierwszą operacją zapisującą na WORK.
5. Dopiero wtedy wykonywany jest `mkfs.ntfs`; następnie `device_guard.sh restore-marker` zapisuje `.usos-work` jako pierwszy zwykły plik i weryfikuje nonce oraz etykietę `USOS_WORK`.
6. `extract.sh` kopiuje instalator z raportowaniem postępu, porównuje liczbę plików i sumę bajtów ze źródłem, kopiuje wskazany `unattend.xml`, wykonuje `sync` i dopiero potem publikuje `phase=prepared`.
7. Restart mikro-Linuxa zużywa `BootNext` i wraca jednorazowo do USOS.
8. USOS widząc `prepared` przechodzi do handoffu Windows Boot Managera z WORK NTFS.
9. Po udanym `StartImage` stan one-shot wraca do `pending`; po błędzie `StartImage` wraca do `prepared`, aby umożliwić retry bez ponownego rozpakowania.

`tools/prepare_work.sh` jest jedynym przewidzianym entrypointem destrukcyjnej części mikro-Linuxa i wymusza kolejność guard → format → marker → mount → extract/verify/sync → prepared.

Kontrakt możliwości backendu jest wspólnym źródłem prawdy dla UI i `requestPreparation()`. Obecnie jedyną aktywną kombinacją jest Windows 11, obraz ISO i metoda `direct_iso` (`ISO`). Pozostałe systemy i metody pozostają widoczne jako planowane, ale UI nie pozwala ich uruchomić i pokazuje powód. Niezależnie od kontroli UI `requestPreparation()` ponownie waliduje system, typ obrazu oraz metodę i jawnie odrzuca nieobsługiwane wartości.

## Architektura katalogu

Profile są danymi. GUI nie posiada osobnych `if` dla Windows 11, Ubuntu, Longhorna czy MemTesta. Profil określa kategorię, rodzinę, katalog obrazów, opcjonalny katalog unattended i listę metod bootowania. Loader jest osobną warstwą i implementuje konkretne techniki startu.
