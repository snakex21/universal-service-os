# Windows 7 UEFI — dokumentacja i granice obecnej diagnozy

Sprawdzone 14 września 2026. Ta analiza nie oznacza naprawienia rozruchu X470.

## Co wynika z dokumentacji autorów

1. [Microsoft: Firmware WEG FAQ](https://learn.microsoft.com/en-us/windows-hardware/drivers/bringup/frequently-asked-questions)
   opisuje dla niezmodyfikowanego Windows 7 rozruch UEFI z włączoną obsługą
   Int10 przez CSM. Włączenie CSM nie oznacza automatycznie instalacji Legacy/MBR;
   instalator nadal należy uruchomić przez wejście UEFI.

2. [Easy2Boot: Windows 7 UEFI64 Install](https://easy2boot.xyz/create-your-website-with-blocks/add-payload-files/windows-install-isos/windows-7-uefi64-install/)
   opisuje instalację z nowszego WinPE: zamontowanie ISO Windows 7 i uruchomienie
   jego Setup. Oddzielnie zaznacza zależności od CSM i sterowników. Uruchomienie
   Setup z WinPE 10 nie jest gwarancją rozruchu systemu docelowego bez CSM.

3. [UefiSeven: README autora](https://github.com/manatails/uefiseven)
   opisuje emulację Int10 i wdrożenie pomocnika zarówno na nośniku instalacyjnym,
   jak i przed loaderem systemu docelowego. To rzeczywista warstwa zgodności,
   a nie ogólna naprawa wszystkich problemów startu Windows 7.
   [Kod inicjalizacji obrazu](https://github.com/manatails/uefiseven/blob/master/UefiSevenPkg/Platform/UefiSeven/Display.c)
   szuka GOP, potem UGA. Brak obu uniemożliwia zbudowanie informacji VESA.

4. [PrimeExpert: Windows 7 UEFI Install Without CSM](https://www.prime-expert.com/articles/a21/windows-7-uefi-install-without-csm/)
   opisuje dodatkową zależność Windows 7 od bezpośrednich operacji na portach
   VGA. Według autora samo zastąpienie Int10 może nie wystarczyć; FlashBoot
   obsługuje także te operacje przez poprawki wykonywane w pamięci podczas
   startu. To wyjaśnia granice prostego shima, ale nie dowodzi przyczyny awarii
   badanego komputera. FlashBoot nie został pobrany ani wdrożony w USOS.

5. [iPXE: WIMBoot](https://ipxe.org/wimboot)
   dokumentuje uruchamianie WinPE, wybór indeksu WIM i domyślne wymuszanie
   tekstowych komunikatów boot managera. Opcja `gui` wyłącza to zachowanie.
   Nie jest to udokumentowana naprawa restartu systemu z docelowego SSD.

6. [UEFI: ConnectController](https://uefi.org/specs/UEFI/2.10_A/07_Services_Boot_Services.html#efi-boot-services-connectcontroller)
   jest standardową usługą podłączenia dostępnych sterowników firmware.
   Nie dostarcza brakującego sterownika GOP i nie zastępuje zgodności Windows
   z VGA/Int10. Obecna próba użycia tej usługi w USOS nie jest potwierdzoną
   naprawą zgłoszonego sprzętu.

7. [CSMWrap](https://github.com/CSMWrap/CSMWrap)
   zapewnia środowisko rozruchu Legacy BIOS oparte na SeaBIOS. Jest inną
   architekturą startu; nie należy podmieniać nim bez analizy loadera istniejącej
   instalacji GPT/UEFI Windows 7. Nie został wdrożony.

## Co wiadomo z badanego dysku

Kopia `zig-out/win7-universal-work/intel-failure-20260914-161703`:
instalator zakończył fazę poprawnie i zażądał restartu o 15:53:37.
Zapis EFI z 15:53:52 kończy się w UefiSeven brakiem GOP/UGA i oczekiwaniem
na Enter. Nie wiadomo, dlaczego interfejs obrazu nie był wtedy dostępny.
Nie wolno utożsamiać tego z brakiem sterownika AMD ani z problemem jądra
opisanym przez PrimeExpert: log zatrzymał się przed uruchomieniem loadera Windows.

## Porównanie sprawdzające zakres testów

Wcześniejsze próby z `-device VGA,romfile=` nie używały CSM, ale nadal
udostępniały sprzętowe porty VGA. [Dokumentacja QEMU](https://www.qemu.org/docs/master/specs/standard-vga.html)
rozróżnia urządzenie VGA od wariantu bez klasycznego interfejsu VGA.

Na dwóch niezależnych kopiach tego samego systemu wykonano nowe próby:

| Wariant | Wynik |
| --- | --- |
| OVMF + VGA bez ROM | UefiSeven znalazło GOP; Windows uruchomił sesję użytkownika i wykonał shutdown z Autostartu, 31,79 s |
| OVMF + bochs-display, bez urządzenia VGA | UefiSeven znalazło GOP; Windows uruchomił sesję użytkownika i wykonał shutdown z Autostartu, 31,41 s |

Wyniki procesu: `zig-out/win7-universal-work/gop-ab/results.json`.
Kopie logów EFI są w tym samym folderze. Dodatkowo sprawdzono w obu
obrazach zdarzenia Windows 1074 i 6006 z czasu próby, wskazujące
`shutdown.exe` uruchomione przez użytkownika `usos`. Plik znacznika w C:\
nie powstał; sam jego brak nie został uznany za nieudany rozruch ani za PASS.
Próba potwierdza dojście do sesji i kontrolowane zamknięcie, nie wygląd pulpitu.

Te wyniki nie odtworzyły awarii sprzętowej i nie uzasadniają zastąpienia
UefiSeven kolejnym loaderem bez dalszych danych. Podczas próby odczytu
w tej sesji Intel nie był już podłączony; wynik rozruchu po ostatniej zmianie
nie został odczytany.

## Wniosek dla implementacji

Trzeba badać osobno dostępność GOP przed shimem i po wejściu do niego,
poprawność emulacji Int10 oraz rozruch Windows. Obecne dane ustalają miejsce
zatrzymania, lecz nie jego przyczynę. Nie dodano kolejnej poprawki produkcyjnej
na podstawie samej dokumentacji; ostatnia wersja pozostaje
`B260914-142108-7B9F9D48`, a jej skuteczność na X470 nie jest potwierdzona.
