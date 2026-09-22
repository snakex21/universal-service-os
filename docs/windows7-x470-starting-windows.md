# Windows 7 / X470 — stan do kontynuacji

Data: 14 września 2026.

## Odczyt podłączonego Intela i poprawka inicjalizacji GOP

Po ponownym podłączeniu potwierdzono N: na Intel 120 GB, PhysicalDrive10,
partycja Windows `ad9a4f0d-d57b-44ef-9bee-06a5942a2527`, ESP
`af9bc61e-8a15-433d-8689-3c268bfcfd4d`. Kopie diagnostyczne znajdują się
w `zig-out/win7-universal-work/intel-failure-20260914-161703`.

Logi tej instalacji pokazują:

- Panther: pierwszy etap rozruchu instalatora zakończony poprawnie o 15:53:36.
- UnattendGC: `setup.exe` zakończył się kodem 0, zażądano restartu;
  rejestr zapisano, `windeploy.exe` zakończył się kodem 0 o 15:53:37.
- `EFI/Microsoft/Boot/usos-boot.log`, zapis 15:53:52: start UefiSeven.
- `UefiSeven.log`, zapis 15:53:52: brak GOP i UGA, brak adapterów obrazu,
  następnie oczekiwanie na Enter do próby wymuszenia trybu. Brak dalszego wpisu.

To wskazuje zatrzymanie rozruchu na etapie EFI po żądanym restarcie,
przed kolejnym uruchomieniem Windows. Nie jest to diagnoza brakującego
sterownika AMD w Windows. Nie ustalono jeszcze, dlaczego firmware nie
udostępnił GOP podczas tego startu.

Dodano `tools/windows7_uefi_graphics.zig`: gdy nie ma ani GOP, ani UGA,
dispatcher wykonuje jeden przebieg `ConnectController` po istniejących
uchwytach firmware. To mechanizm ze
[specyfikacji UEFI 7.3.12](https://uefi.org/specs/UEFI/2.10_A/07_Services_Boot_Services.html#efi-boot-services-connectcontroller).
Jeśli GOP był dostępny, pozostawia go bez zmian. Zachowuje również obsługę
UGA i dotychczasową ścieżkę poprawnego firmware Int10. Nie rozłącza urządzeń,
nie wymusza parametrów framebuffer i nie zmienia VBIOS karty.
Log odróżnia GOP obecny od początku, odzyskany przez ConnectController oraz
brak GOP/UGA mimo podłączenia sterowników. Przy ostatnim wyniku dispatcher
zwraca błąd zamiast uruchamiać UefiSeven bez interfejsu obrazu.

Test `test_uefi_graphics_connect.py` odłącza rzeczywisty sterownik obrazu
w OVMF, sprawdza zniknięcie GOP, przywrócenie go kodem produkcyjnym oraz
poprawny QueryMode. PASS. Pełny build i `run.ps1 -Suite all`: PASS,
wersja `B260914-142108-7B9F9D48`. Nie potwierdza to skuteczności na X470.

Na Intelu zaktualizowano wyłącznie dwa dispatchery `bootmgfw.efi` i
`bootx64.efi`; ich kontrolny SHA-256:
`44A0E6C8984B7F05BDFA0AEB47A69333F90D7B201B3CC49CE31DCB017C0B953F`.
Zachowano BCD i oryginalne loadery. Pełna kopia EFI sprzed zmiany:
`zig-out/win7-universal-work/intel-before-gop-20260914-162347`.
Wynik zapisu: `intel-gop-repair-result.json`, PASS.
Kingston również zaktualizowano do `B260914-142108-7B9F9D48`;
`zig-out/win7-universal-work/gop-connect-usb-update.log`: `RESULT=PASS`.

Następna próba: uruchomić istniejącą instalację z Intela na X470.
Nie reinstalować systemu przed sprawdzeniem tej próby. Jeśli nadal nie
startuje, odczytać nowy `usos-boot.log` i `UefiSeven.log`; rozstrzygną,
czy kontroler udostępnił GOP i jaki etap nastąpił potem.

Poniżej zachowano historię wcześniejszej diagnozy i poprawek.

## Ponowne zgłoszenie po poprawce EFI — problem nadal nierozwiązany na sprzęcie

Użytkownik potwierdził, że po poprzedniej poprawce system nie wystartował
i potrzebna była ponowna instalacja. Przy 6in1 po komunikacie „Instalator
aktualizuje ustawienia rejestru” nastąpił czarny ekran. Ultimate pokazuje
uszkodzony obraz z poziomymi fragmentami tekstu. Karta: Radeon RX 560.
Intel nie był podłączony do stanowiska podczas nowej diagnostyki, więc logi
ostatniej instalacji nie zostały jeszcze odczytane. Nie zakładać przyczyny
na podstawie braku sterownika producenta: Windows ma podstawowy sterownik
wyświetlania, a sam czarny ekran nie dowodzi jego awarii ani zawieszenia systemu.

W kodzie USOS znaleziono niezależny, konkretny błąd: po wywołaniu UefiSeven
`windows_native_iso.start` rysował kolejny komunikat przez bufor interfejsu
utworzony dla poprzedniego trybu GOP. UefiSeven może zmienić rozdzielczość.
Gdy BLT odrzucał stary rozmiar obrazu, renderer kopiował piksele bezpośrednio
według starych parametrów framebuffer. To błąd integracji USOS, a nie dowód
brakującego patcha Windows lub sterownika RX 560.

Poprawka przenosi ostatnie rysowanie przed UefiSeven. Jeśli start EFI wróci
z błędem, interfejs odrzuca stare bufory i ponownie pobiera parametry GOP
przed wyświetleniem błędu. Test `test_uefi_graphics_refresh.py` uruchamia
rzeczywisty GOP w QEMU: 1280×1024 → 1024×768, a następnie sprawdza wywołania
renderera względem nowych wymiarów. Test przeszedł. Nie odtwarza to jeszcze
awarii 6in1 po aktualizacji rejestru ani nie potwierdza naprawy fizycznego Ultimate.

Włączono także log UefiSeven ścieżki instalacyjnej, zapisywany na ESP USB
w `EFI/USOS/windows-native/UefiSeven.log`. Przygotowano kolektor
`zig-out/win7-universal-work/collect-intel-failure.ps1`: wybiera jednoznacznie
testowy model Intel 120 GB, kopiuje logi EFI, Panther, SetupAPI, CBS i SYSTEM
do folderu projektu oraz zapisuje wersje plików. Nie naprawia ani nie instaluje
niczego na tym dysku. Po ponownej instalacji nie używa dawnych GUID partycji.

Build poprawki obrazu: `B260914-140426-885D990C`. Pełna kompilacja i
`tools/tests/run.ps1 -Suite all` zakończyły się PASS, w tym test rzeczywistej
zmiany GOP oraz starty UEFI x64 i ARM64. Kingston został zaktualizowany;
aktualizator zakończył kontrolny odczyt wynikiem `RESULT=PASS`.
Log aktualizacji: `zig-out/win7-universal-work/graphics-usb-update.log`.
Intel pozostaje niepodłączony; nie wykonano na nim kolejnej naprawy.

Źródła sprawdzone przy analizie: [UefiSeven](https://github.com/manatails/uefiseven),
[WIMBoot](https://ipxe.org/wimboot) oraz dołączony kod WIMBoot 2.9.0.

Poniższe informacje opisują wcześniejsze działania, których skuteczności
na fizycznym X470 nie potwierdzono.

## Zgłoszenie użytkownika

Na fizycznym komputerze X470 instalacja działa tylko z
`WIN7X64.6in1.pl-PL.JULY2019.ISO`. Po restarcie pojawia się
„Starting Windows” i rozruch nie postępuje. Dokładny objaw dla oryginalnego
ISO SP1 nie został podany. Nie oznaczać tego sprzętu jako działającego.
Użytkownik chce wykorzystać sprawdzone metody Easy2Boot/Ventoy i zachować
stan pracy ze względu na niewielki pozostały limit użycia.

Poprzedni build na Kingstonie: `B260914-131030-E58763A4`.
Użytkownik potwierdził: Intel 120 GB SATA, widoczny na stanowisku jako N:,
oraz czyste UEFI z wyłączonym CSM. Późniejszy odczyt przez stację USB nie
zmienia tego, że właściwy komputer używa tego SSD jako SATA.

Na fizycznym ESP wykryto konkretny błąd: `EFI/Microsoft/Boot/bootmgfw.efi`
był dispatcherem USOS, natomiast `EFI/Boot/bootx64.efi` pozostawał oryginalnym
loaderem Microsoftu. Start przez ścieżkę zapasową mógł więc ominąć UefiSeven.
Nie ustalono, czy właśnie tę ścieżkę wybierała płyta przy zgłoszonym zawieszeniu.

Poprawiono finalizator obu wejść EFI oraz już istniejącą instalację na Intelu.
Przed zapisem wykonano świeżą kopię całego EFI, zweryfikowaną bajtowo;
oryginały są w `zig-out/win7-universal-work/intel-pre-repair-esp`.
Oba wejścia i pliki pomocnicze zweryfikowano SHA-256 po zapisie. BCD pozostał
bez zmian. Wynik: `zig-out/win7-universal-work/intel-repair-result.json`.

## Co faktycznie zalecają autorzy narzędzi

1. [Easy2Boot: Windows 7 UEFI64 Install](https://easy2boot.xyz/create-your-website-with-blocks/add-payload-files/windows-install-isos/windows-7-uefi64-install/)
   opisuje uruchomienie nowszego WinPE, zamontowanie ISO Windows 7 i
   wykonanie jego Setup albo użycie WinNTSetup. Wskazuje również, że CSM
   może być potrzebny nawet przy rozruchu Windows 7 x64 w UEFI. Przekształcenie
   ISO do imgPTN samo nie dodaje brakujących sterowników USB.
2. [Ventoy: WIMBOOT](https://www.ventoy.net/en/doc_wimboot.html)
   opisuje domyślną emulację CD-ROM i alternatywny WIMBOOT dla problemów
   uruchamiania oficjalnych ISO Windows. WIMBOOT nie jest opisany jako
   naprawa rozruchu z docelowego dysku po instalacji.
3. [Ventoy: FAQ](https://www.ventoy.net/en/faq.html)
   zaznacza, że firmware wybiera tryb Legacy/UEFI. Brak nośnika instalacyjnego
   w Windows 7 wiąże z brakującym sterownikiem USB 3.
4. [UefiSeven: dokumentacja autora](https://github.com/manatails/uefiseven)
   opisuje zawieszenie na „Starting Windows” przy braku właściwej obsługi
   Int10h. Podaje instalację pomocnika zarówno na USB, jak i na ESP dysku
   docelowego. To możliwa przyczyna zgłoszenia, nie ustalona diagnoza.
   [Konfiguracja](https://raw.githubusercontent.com/manatails/uefiseven/master/UefiSeven.ini)
   udostępnia `verbose`, `logfile` i `force_fakevesa`.

## Porównanie z USOS

Ścieżka 6-w-1 już uruchamia nowsze WinPE i oryginalny Setup z zamontowanego
ISO. USOS przekazuje pakiety do offlineServicing systemu docelowego.
Samo ponowne wdrożenie WIMBOOT nie wyjaśnia zawieszenia po restarcie.

Na docelowym ESP finalizator instaluje własny dispatcher oraz UefiSeven
i zachowuje loader Microsoft. Dispatcher korzysta teraz ze wspólnego
sprawdzenia adresu Int10h i pierwszego opcode, tak jak upstream UefiSeven.
Kod 00/FF nie jest już uznawany za poprawny handler tylko na podstawie adresu.
Poprawny handler firmware (np. CSM) pozostaje używany; brakujący lub odrzucony
powoduje uruchomienie UefiSeven.
Nie wymuszać `force_fakevesa` bez próby i możliwości przywrócenia loadera.

Dispatcher zapisuje ostatni etap w `usos-boot.log` obok uruchomionego pliku EFI.
UefiSeven ma włączone `logfile=1`, bez interaktywnego trybu verbose;
szczegóły trafiają do `UefiSeven.log` w tym samym katalogu.

Ścieżka bezpośrednia przenosi teraz pełne, przypięte sumami kontrolnymi
pakiety KB2990941-v3 i KB3087873-v2 do servicing systemu docelowego.
Włącza je tylko wtedy, gdy metadane wszystkich obrazów instalacyjnych
potwierdzają Windows 7 SP1 x64 (6.1.7601). RTM i obrazy mieszane nie dostają
tych pakietów automatycznie. Pakiety są dodawane do osobnego pliku odpowiedzi;
ustawienia użytkownika i zabezpieczenie dysku źródłowego pozostają zachowane.

Nowoczesny WinPE zapewnia własny sterownik NVMe instalatora. Oryginalny WinPE 7
nadal wymaga odpowiedniego wsparcia kontrolera przed wyborem dysku; dodanie
pakietów do systemu docelowego nie modernizuje automatycznie jego boot.wim.
Pełna instalacja na NVMe w tej nowej ścieżce nie jest jeszcze potwierdzona.

## Sprawdzenia i następna próba sprzętowa

- Pełny `build.bat`: PASS, build `B260914-131030-E58763A4`.
- `tools/tests/run.ps1 -Suite all`: PASS, w tym testy NVMe/XML, rzeczywisty
  zapis obu wejść EFI na plikach tymczasowych oraz starty UEFI x64/ARM64.
- Kopia zainstalowanego Windows 7: czyste OVMF bez zapisanej konfiguracji
  NVRAM, SATA i start zapasowy EFI — pulpit osiągnięty. Zrzut:
  `zig-out/win7-universal-work/compat-desktop.png`.
- Kingston: aktualizacja i kontrolny odczyt PASS.
- Intel: naprawa EFI i kontrolny odczyt PASS; nie formatowano partycji.

Następny krok to uruchomienie istniejącego Windows 7 z Intela na właściwej
płycie, początkowo z dotychczasowym czystym UEFI. Ponowna instalacja nie jest
potrzebna do sprawdzenia naprawy rozruchu. W razie dalszego zatrzymania odczytać
oba logi z faktycznie użytego katalogu EFI i dopiero wtedy zmieniać wariant grafiki.

Nie deklarować naprawy na podstawie samego QEMU lub obecności plików INF.
