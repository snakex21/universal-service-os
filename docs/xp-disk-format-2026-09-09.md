# Formatowanie dysku w przygotowaniu Windows XP

Pierwsze wydanie formatowania: `B260909-163124-9D784BED`. Aktualizacja interfejsu opisana poniżej usuwa wpisywanie potwierdzeń.

Po wybraniu XP, obrazu ISO, braku własnego Unattended i dysku docelowego USOS pokazuje graficzne pozycje menu:

- Zachowaj partycje i użyj wolnego miejsca — domyślnie zaznaczone;
- Formatuj cały dysk i przygotuj nową instalację XP;
- Wróć do wyboru dysku.

Aktualny interfejs wszystkich trzech ekranów obsługuje strzałki i mysz, bez wpisywania numerów. Zmianę oraz testy opisuje [graficzny wybór dysku](xp-graphical-disk-menu-2026-09-09.md). Poniższe starsze wyniki testów zachowano jako historię implementacji.

Opcja 2 pokazuje model, serial, pojemność i informację o usunięciu wszystkich partycji, systemów i plików. Potwierdzenie to `POTWIERDZ / ANULUJ`, wybierane strzałkami lub TAB i ENTER; ESC anuluje. Domyślnie zaznaczone jest anulowanie. Nie trzeba wpisywać tekstu ani potwierdzać ponownie po usunięciu układu. Tryb zachowania partycji również używa tego samego wyboru zamiast wpisywania `TAK`.

Podgląd przed wyborem trybu i formatowaniem pokazuje stan użycia urządzenia, liczbę partycji, miejsce poza partycjami oraz zajęte/wolne miejsce w odczytanych systemach plików. Szczegóły obejmują pierwsze cztery partycje. FAT/NTFS i dostępne ext2/3/4 są otwierane przez pętlę blokową tylko do odczytu; ext dodatkowo z `noload`. Używane partycje nie są dodatkowo montowane. Brak odczytu jest opisany jako nieznany, nie jako pusty dysk. Windows jest rozpoznawany po jądrze i rejestrze SYSTEM, Linux po os-release; same pliki bootloadera lub źródła XP są opisane osobno. Rozpoznanie nie potwierdza sprawności ani dokładnej wersji Windows. Pliki z dysku nie są wykonywane.

To szybkie formatowanie pod instalację, nie bezpieczne wymazywanie wszystkich sektorów ani samodzielne narzędzie formatowania dowolnego systemu plików. Obsługiwany cel: cały dysk 11 GiB–poniżej 2 TiB, sektory logiczne 512 B. Własny SIF wymaga dotychczasowego trybu zachowania partycji.

## Kontrakt zapisu

`xp_disk_reset_ui.sh` odpowiada za wybór trybu i potwierdzenie. `xp_disk_reset.sh snapshot/apply` odpowiada za zapis:

1. ISO jest montowane tylko do odczytu, a `probe_xp_source.sh` sprawdza je przed oferowaniem formatowania.
2. Reset wyklucza USOS, pojedyncze partycje, nośniki removable/read-only, zamontowane urządzenia, aktywny swap i aktywnych użytkowników urządzeń blokowych (`holders`). Wymaga modelu i serialu.
3. Snapshot zapisuje tożsamość (model/serial/WWN/pojemność/sektor) oraz pierwsze i ostatnie 1 MiB w RAM. To kontrola niezmienności, nie pełna kopia danych.
4. Apply porównuje tożsamość i oba obszary, wymaga dokładnie jednego pasującego dysku oraz potwierdzenia zawierającego serial. Ponownie sprawdza urządzenie bezpośrednio przed zapisem.
5. Zeruje początek i koniec dysku, usuwając MBR/GPT i obie kopie GPT, zapisuje pusty MBR ze stabilnym niezerowym ID i porównuje odczyt z oczekiwanymi bajtami. Odświeża tablicę partycji w kernelu.
6. Normalny guard i backend XP tworzą nowy układ: XPSETUP od LBA 2048, następnie NTFS Windows. Źródło lokalne znajduje się na NTFS; pierwszy etap XP wybiera ją automatycznie.

Testowe pliki autoselekcji nie włączają formatowania. Istniejące fixture'y zachowują wcześniejszy tryb; test formatowania przechodzi przez prawdziwe pytania i emulowaną klawiaturę tty1.

## Weryfikacja

- `zig-out/xp-reset-guards-20260909`: osiem odmów PASS (USOS, pojedyncza partycja, read-only, zamontowana partycja, złe potwierdzenie, inna tożsamość, zmieniony początek i koniec dysku), metadane po odmowach niezmienione; poprawnie potwierdzony reset daje pusty MBR akceptowany przez normalny guard.
- `zig-out/xp-format-cancel-20260909`: anulowanie z klawiatury zachowało MBR i istniejące dane kontrolne.
- `zig-out/xp-format-install-20260909`: formatowanie starego MBR, nowe partycje i pełny staging PASS. VirtualBox 1024/240/63 bez ISO/USOS: automatyczny Text Mode, restart, GUI Setup (`gui-check.png`). Test nie obejmuje zakończenia OOBE/pulpitu.
- `zig-out/xp-format-gpt2-20260909`: istniejący GPT z partycją zajmującą prawie cały dysk został zastąpiony nowym MBR; pełny staging PASS. Pierwotny nagłówek/tablica GPT i kopia końcowa są zerowe po stagingu. Wcześniejsza asercja sprawdzała cały ostatni MiB, lecz nowy NTFS może legalnie zajmować jego część; test poprawiono na faktyczny obszar kopii GPT.
- `zig-out/xp-reset-preserve-regression-20260909`: wybór 1 nadal zachowuje wcześniejszą partycję i dane kontrolne, staging PASS.
- Pełny build, testy Go, unit/startup USOS, QEMU UEFI x86_64/ARM64 i 13 testów planera PASS.

Główne polecenia testowe: `test_xp_automatic_install.py --existing --reset-tests`, `--existing --interactive --cancel-format`, `--existing --interactive --format-disk`, `--existing --interactive --format-disk --gpt`, `--existing --interactive`. Każde wymaga osobnego, nowego `--output`; fixture ISO/USOS jest opisany w harnessie. Wszystkie operacje formatowania wykonywano wyłącznie na obrazach testowych. Fizyczny Intel nie był formatowany.

Payload initramfs: SHA-256 `C9BFC90D26D9BB150ACA3889C26DE1C83B206C763F781757DCEB3F4033693226`. Log aktualizacji Kingstona: `zig-out/xp-format-kingston-update.log`.

## Aktualizacja potwierdzenia i podglądu

Wydanie `B260909-165551-A8545054`, initramfs SHA-256 `C0905B35EC8791D1EB39E4CBFB7175BA6FEDC6E499E180D7CA4F65F3CA058EC7`.

- `zig-out/xp-confirm-overview`: rzeczywiste FAT i NTFS, odczyt przestrzeni, wykrycie plików Windows, Linux i źródła XP, odmowa dodatkowego montowania używanej partycji. SHA-256 całej partycji przed i po inspekcji identyczny.
- `zig-out/xp-confirm-cancel`: ENTER na domyślnym anulowaniu zachował MBR i dane kontrolne; `zig-out/xp-confirm-escape`: ESC również zachował dane na końcowej implementacji.
- `zig-out/xp-confirm-format3`: strzałka i ENTER, formatowanie oraz pełne przygotowanie XP PASS, bez drugiego pytania. Wcześniejsze próby wykryły utratę końcówki sekwencji strzałki między otwarciami tty; poprawka utrzymuje deskryptor otwarty przez cały ekran.
- `zig-out/xp-confirm-preserve`: TAB i ENTER, pełne przygotowanie XP, wcześniejsza partycja i dane zachowane.
- Pełny build, Go, unit/startup USOS, QEMU UEFI x86_64/ARM64 i 13 testów planera PASS. Ta aktualizacja nie powtarza testu GUI XP; zmienia podgląd i potwierdzenie, a wcześniejszy test przejścia do GUI pozostaje opisany wyżej.

Log aktualizacji Kingstona dla tego wydania: `zig-out/xp-confirm-kingston-update.log`. Nie formatowano fizycznego Intela.
