# Memtest86+ z Utilities — BIOS, 13 września 2026

## Uruchomienie

W menu BIOS wybierz `Utilities`, następnie `MemTest86`, plik
`memtest86plus-8.10-i586.iso` i naciśnij Enter. Program uruchamia test
automatycznie. F1 otwiera ustawienia, F10 zamyka ich menu, Esc restartuje
komputer. Powrót do USOS odbywa się przez ponowny rozruch z pendrive’a.

Plik znajduje się na DATA w `Utilities\MemTest86\Images`. Jego nazwa może
się zmienić; USOS odczytuje wybrany plik, a program rozpoznaje po nagłówku
wewnątrz ISO. Obsługiwana jest wersja i586 Memtest86+ z `BOOT/FLOPPY.IMG`.
Wersja x86_64 z GRUB, programy EFI oraz pozostałe narzędzia widoczne
w Utilities wymagają osobnych ścieżek uruchamiania.

## Implementacja

- Natywny odczyt GPT, NTFS oraz ISO9660 z nośnika USOS.
- Kontrola sygnatury Linux boot protocol, wersji programu, architektury,
  adresu wejścia, zadeklarowanych rozmiarów i granic pliku.
- Kontrola dostępności pamięci przez E820. Do RAM trafia wyłącznie
  zadeklarowana część programu, bez wypełnienia obrazu dyskietki.
- Bezpośrednie przekazanie sterowania w trybie chronionym x86 z mapą
  pamięci i opisem ekranu. Brak initrd i parametrów instalacyjnych USOS.
- Czytnik tej ścieżki nie udostępnia operacji zapisu na dysku.

Format i punkt wejścia odpowiadają kodowi wydania 8.10:
[header.S](https://github.com/memtest86plus/memtest86plus/blob/v8.10/boot/x86/header.S),
[startup32.S](https://github.com/memtest86plus/memtest86plus/blob/v8.10/boot/x86/startup32.S).

## Obraz źródłowy

Rozmiar ISO: 6 207 488 bajtów.

SHA-256:
`fa0d8a5c01d6c235393c05150dd572e3069b2f4456a26afaeae48ee3fba2e4bd`

Ten sam hash potwierdzono odczytem pliku z DATA Kingstona. Obraz pozostaje
zewnętrznym plikiem użytkownika; nie jest częścią payloadu ESP instalatora.

## Kontrole

Pełny `build.bat` i `tools/tests/run.ps1 -Suite all` zakończyły się PASS
dla wydania `B260913-084102-08ED8D73`. Nowe testy obejmują prawidłowy obraz
i586, odrzucenie innego programu, obciętego obrazu, wersji x86_64 i błędnego
rozmiaru pamięci. Testy parametrów rozruchu obejmują samodzielny program
oraz dotychczasowe ścieżki Windows/micro-Linux.

Uruchomienie z rzeczywistego menu BIOS, automatyczny początek testowania
i obsługę F1/F10 potwierdzono w QEMU TCG, CPU `athlon`, 128 MiB RAM.
Pełny domyślny przebieg, łącznie z testem zaniku bitów, zakończył się
wynikiem `Pass: 1`, `Errors: 0` po około czterech minutach.
Esc spowodował ponowny start do menu USOS. SHA-256 dodatkowego dysku
przed i po tym przebiegu jest identyczne:
`68b2538c0be9b17a4a5250ac3704811c943a17e3f9315bd2c750b1833be3986d`.
Źródłowy nośnik USB w VM jest otwarty tylko do odczytu, a dodatkowy dysk
jest osobnym pustym obrazem testowym. Żaden fizyczny dysk hosta nie jest
przekazywany maszynie wirtualnej.

Końcowy pakiet sprawdzono także przez wybór ISO z celowo zmienioną
tożsamością programu. USOS pokazał `Memtest86PlusImageRequired`, pozwolił
wrócić do listy i wybrać prawidłowy plik. Test nie uruchomił obcego obrazu.
Po powrocie z błędu prawidłowy ISO wystartował w VM z CPU `qemu64` i 2 GiB
RAM; Memtest86+ rozpoznał 1,99 GiB i rozpoczął testy w trybie LM.
Jest to kontrola startu przy większej pamięci, nie drugi pełny przebieg.
Esc również wrócił do USOS, a dodatkowy dysk zachował identyczne SHA-256.

Dowody znajdują się w `zig-out/win3-work`: `memtest-tests.log`,
`memtest-athlon-serial.log`, `memtest-running.png`,
`memtest-config-after-key.png`, `memtest-pass-1.png`,
`memtest-returned-usos.png`, `memtest-negative-result.png`,
`memtest-final-2gb.png`, `memtest-final-usos-return.png`,
oba pliki `*-disk-check.json` oraz `memtest-kingston-media-check.json`.

Kingston DataTraveler 3.0 zaktualizowano do `B260913-084102-08ED8D73`.
Wszystkie pięć etapów zakończyło się PASS: odczyt zwrotny kodu BIOS,
plików payloadu i instalatora oraz kontrola niezmienionej geometrii GPT.
Log: `kingston-memtest-operation.log`. Końcowe hashe i rozmiary pakietu
są zapisane w `memtest-release.json`. ISO na DATA po aktualizacji zachowało
powyższe SHA-256.

Po aktualizacji użytkownik potwierdził działanie Memtest86+ na sprzęcie.
Nie podał liczby pełnych przebiegów ani wyniku diagnostyki RAM.
