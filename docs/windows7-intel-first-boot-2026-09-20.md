# Windows 7: pierwszy rozruch z Intela, 20 września 2026

Odczyt po fizycznej próbie użytkownika, bez VM i bez zmian systemu docelowego.
Aktualne litery: Windows na M:, J: jest ESP Kingstona. Intel SSD 120 GB
`INTEL SS DSC2BW120A4`, GUID `8e281c54-58d1-4ad0-8afd-ad76d2e48148`,
podłączony przez USB; nie jest dyskiem bieżącego systemu.
ESP: `266ef7fa-2486-4050-892f-20c3bc889930` (100 MiB), Windows:
`73dbde99-8026-4759-a19a-fd943e891d09`. Kopie diagnostyczne są w
`zig-out/win7-universal-work/intel-failure-20260920-173338`.

## Potwierdzone

- Setup kończy fazę WinPE o 17:30:31. Log USOS: `setup-returned exit-code=0`,
  `Windows 7 target loader prepared and verified`, `reboot-after-success`.
- BCD wskazuje Windows na partycji Intela i `Windows/system32/winload.efi`.
- Obie ścieżki startowe mają wrapper USOS, SHA-256
  `44A0E6C8984B7F05BDFA0AEB47A69333F90D7B201B3CC49CE31DCB017C0B953F`.
  Zachowany oryginalny loader ma wersję 6.1.7601.24518.
- Są manifesty/katalogi KB4474419, KB2990941, KB3087873 oraz pliki sterowników
  stornvme, storport, amdxhci i usbxhci. Samo ich istnienie nie potwierdza
  uruchomienia sterowników podczas pierwszego startu Windows.
- Wrapper znalazł GOP. Log UefiSeven 1.30 odnotowuje brak Int10h (`0000:0000`),
  niepowodzenie odblokowania C0000 przez MTRR i przerwanie przygotowania VGA.
  Następnie mimo tego uruchamia `win7.original.efi`.

To jest pierwsza potwierdzona awaria ścieżki rozruchu i mocny kandydat na
przyczynę zatrzymania na Starting Windows. Nie ma dowodu, że jest jedyna.
Nie należy zastępować diagnozy ponownym kopiowaniem sterowników NVMe ani
włączeniem `skiperrors`: pominięcie komunikatu nie instaluje obsługi Int10h.

## Granice diagnozy

UefiSeven wypisuje `FrameBufferBase = 0`. W kodzie upstream format tego pola
to `%x`, a adres VESA jest zawężany do UINT32. Taki zapis nie rozstrzyga,
czy firmware podało zero, czy adres powyżej 4 GiB został ucięty. Brak pełnego
adresu w logu. Zapytano użytkownika o CSM, GPU, Above 4G Decoding i Re-Size BAR;
nie założono ich wartości i nie wykonano arbitralnych zapisów do rejestrów
chipsetu ani zmian firmware.

Źródła mechanizmu:
- https://github.com/manatails/uefiseven/blob/master/UefiSevenPkg/Platform/UefiSeven/UefiSeven.c
- https://github.com/manatails/uefiseven/blob/master/UefiSevenPkg/Platform/UefiSeven/Display.c

ESP Intela otrzymała wyłącznie tymczasową literę do odczytu, usuniętą po
zebraniu kopii. Pliki Windows, BCD i loadery na dysku nie zostały zmienione.

Użytkownik potwierdził: CSM wyłączony, Above 4G Decoding i Re-Size BAR
włączone. Następna proponowana próba: oba ustawienia adresowania GPU
wyłączyć, zachować CSM/Secure Boot wyłączone i uruchomić istniejącą
instalację z Intela. Ma to sprawdzić hipotezę adresu framebuffer powyżej
4 GiB; nie jest potwierdzoną naprawą osobnego błędu odblokowania C0000.

## Powtórka z Above 4G/Re-Size BAR wyłączonymi

Użytkownik potwierdził identyczne zatrzymanie i podał kartę RX 560.
Nowa kopia: `zig-out/win7-universal-work/intel-failure-20260920-174214`.
W świeżym UefiSeven.log `FrameBufferBase` zmienił się z `0` na `D0000000`,
natomiast sekwencja błędów odblokowania C0000 pozostała taka sama.
Zmiana ustawień adresowania GPU nie usunęła tej awarii.

Sprawdzono kod upstream EnsureMemoryLock: próbuje LegacyRegion,
LegacyRegion2 i zmiany typu pamięci przez MTRR. Świeży log zawiera tylko
nieudaną próbę MTRR. Nie ma potwierdzonej lokalnej poprawki dla tej płyty.
Fork uefiseven_am5 dodaje zmiany GOP, ale nie wykazano, że rozwiązuje
odblokowanie C0000; nie został pobrany ani wdrożony.

Kolejny krok: analiza i przygotowanie zmiany obsługi legacy memory
w module rozruchowym. Używany lokalnie pakiet tools/vendor/uefiseven/1.30
zawiera EFI, licencję i manifest, bez źródeł. Zapytano o zgodę na pobranie
źródeł i zależności kompilacji zgodnie z ograniczeniem użytkownika.
Nie wykonywano zapisów MSR/chipsetu, podmian loaderów, VM ani E2E.

## Wersja diagnostyczna po zgodzie na pobieranie

Użytkownik odwołał ograniczenia z przekazanego raportu innego AI, w tym
zakaz pobierania. Nadal zabronione są VM i długie E2E. Potwierdzony sprzęt:
Ryzen 7 5700X, X470, RX 560, CSM wyłączony.

Pobrano 23 pliki źródeł UefiSeven z tagu 1.30, commit
`b8f0baba63e60e74d4ed3e86b15b76319d316b83`, z manifestem SHA-256
w `zig-out/win7-universal-work/uefiseven-source-1.30`. Pobieranie źródeł
zakończyło się; późniejsze wypisywanie komentarzy GitHub miało błąd
kodowania konsoli cp1250. Komentarze również zapisano w plikach JSON.
Nie przebudowano ani nie zastąpiono binarki UefiSeven.

Nie znaleziono potwierdzonej poprawki odblokowania dla tej płyty.
Własny wrapper otrzymał jednorazowy odczyt CPUID, MTRR, AMD SYS_CFG,
protokołów LegacyRegion i LegacyRegion2, deskryptora pamięci C0000,
pierwszych 16 bajtów C0000, wektora Int10h i pełnego adresu GOP.
Wynik zapisuje przed UefiSeven do `usos-memory.log` obok loadera.
Odczyty MSR są ograniczone przez CPUID; SYS_CFG tylko dla fizycznych
AMD family 17h/19h. Nie wykonuje WRMSR, czyszczenia legacy memory,
zmiany CSM ani wyłączania zabezpieczeń Windows.

RdDram/WrDram mogą być maskowane przy MtrrFixDramModEn=0, więc ich brak
w odczycie nie dowodzi ich rzeczywistej wartości. Kolejna próba sprzętowa
jest potrzebna do zebrania tego stanu; ta zmiana nie jest naprawą C0000.

Build `B260920-155506-38CC7035`: 216 testów Zig + 1 test bramki CPUID,
2 self-testy i 54 krótkie testy pomocników OK. Bez uruchamiania VM/E2E.
Log: `zig-out/win7-universal-work/build-memory-diagnostics.log`.
Nowy wrapper SHA-256:
`7E2A02043DFEDE1A0A660EFE36DB75C44E91A25B430D2678B2F519733A68BE14`.

Wgrano oba wrappery na Intel; zweryfikowano GUID dysku i ESP, dotychczasowe
sumy, kopię zapasową oraz sumy po zapisie. BCD i układ partycji niezmienione.
Kopia: `zig-out/win7-universal-work/intel-before-memory-probe-20260920-175625`.
Zaktualizowano również paczkę Windows/EFI na Kingston, z kopią poprzednich
plików `kingston-before-sept20-20260920-175527` i kontrolą SHA-256.
Log aktualizacji: `zig-out/win7-universal-work/update-memory-diagnostics-usb.log`.
