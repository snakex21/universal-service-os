# Windows 7: bezpośredni start ISO w UEFI

> **Próba fizyczna po włączeniu CSM — 14 września 2026:** użytkownik
> potwierdził uruchomienie WinPE 7, ale bez działającej myszy i klawiatury USB.
> Obsługa USB w tej konfiguracji pozostaje niesprawna. Odczyt Kingstona
> potwierdził obecność ośmiu INF AMD/NEC; nie potwierdza ich załadowania
> w tej sesji PE. Brakuje jej raportu urządzeń i logu instalacji sterowników.
> Tryb uruchomienia pendrive'a (UEFI lub Legacy przy aktywnym CSM) wymaga
> ustalenia. Zachowane logi ESP nie zawierają nowego śladu tej próby.

> **Aktualny wynik fizyczny — 14 września 2026:** użytkownik zgłosił,
> że na X470 instalacja rusza wyłącznie z ISO 6-w-1, a po restarcie
> zatrzymuje się na ekranie „Starting Windows”. Problem nie jest rozwiązany.
> Poniższe wyniki QEMU potwierdzają wyłącznie konfigurację wirtualną.
> Dalsze ustalenia i źródła: [diagnoza X470](windows7-x470-starting-windows.md).

Automatyczny wybór sprawdza rzeczywistą wersję, architekturę i indeks
rozruchowy obrazu Setup w `sources/boot.wim`. Zarówno WinPE 7 x64 6.1,
jak i WinPE x64 6.2 lub nowszy uruchamiają się przez WIMBoot 2.9.0
bez mikro-Linuksa, restartu przygotowawczego i rozpakowania na WORK.
Opcja Chainload jest niedostępna dla Windows 7; Automatic nie przełącza
się na nią po błędzie.

Podsumowanie wyboru pokazuje wersję instalatora i informację o natywnym
stosie USB. Pokazuje również liczbę zewnętrznych plików INF
albo brak pakietów w `Drivers/x64`. Sama wersja PE ani obecność INF nie
potwierdzają obsługi konkretnego komputera. Działanie kontrolerów jest
sprawdzane po uruchomieniu Windows PE.

Core czyta ISO na NTFS przez własny odczyt GPT/NTFS/UDF. Do RAM ładuje tylko
BCD, boot.sdi, boot.wim i mały pakiet pomocników. Udostępnia je WIMBoot jako
system plików UEFI tylko do odczytu. WIMBoot pobiera oryginalny menedżer
Microsoft z wybranego WIM. Po starcie WinPE pomocnik otwiera dokładnie to
samo ISO, sprawdzając GUID partycji DATA, nazwę i rozmiar pliku. Instalator
korzysta z zamontowanego ISO. Plik ISO pozostaje niezmieniony.

Oba warianty otrzymują pomocniki wyboru partycji EFI i finalizacji rozruchu.
Oba warianty otrzymują dodatkowo rozpakowane pakiety
z `Systems/Windows/Windows 7/Drivers/x64` na DATA. Wszystko jest przenoszone
do RAM, zanim kontrolę nad USB przejmie Windows. Podkatalogi są zachowywane;
należy dostarczyć komplet INF/SYS/CAT i zależności. Limity transportu to
512 plików, 128 katalogów, 64 MiB łącznie i 180 znaków względnej ścieżki.
Nazwy muszą być ASCII; dowiązania i ścieżki wychodzące poza katalog są odrzucane.

Nie ma listy płyt głównych ani reguł specjalnych dla X470. Windows dopasowuje
pakiety do identyfikatorów sprzętu i sprawdza ich podpisy. Raport WinPE
wyświetla identyfikator PCI, usługę sterownika, stan READY/NOT STARTED oraz
kod problemu. Nie interpretuje samego sukcesu DrvLoad jako działającego USB.
Raport dotyczy instalatora, a nie zawartości `install.wim`/`install.esd`.

Ścieżka WinPE 7 obsługuje `install.wim`; połączenie starego PE z samym
`install.esd` jest odrzucane przed rozruchem. Nowszy PE obsługuje oba formaty.
Nie ładujemy sterowników Windows 7 do nowszego PE. Dodatkowe pakiety są
natomiast przekazywane do instalowanego Windows 7 w obu wariantach.

## Sterowniki systemu docelowego i rozruch UEFI

Pomocnik XML dodaje katalog pakietów do
`offlineServicing/Microsoft-Windows-PnpCustomizationsNonWinPE/DriverPaths`.
Oryginalny plik odpowiedzi pozostaje niezmieniony; zachowywane są jego inne
ustawienia. Bez pliku użytkownika generowany jest wyłącznie wpis sterowników,
bez automatycznego wyboru lub partycjonowania dysku. Plik wskazujący dysk
źródłowy jako cel jest odrzucany. Sam DrvLoad nie wystarcza do przekazania
sterownika do systemu docelowego, co opisuje
[dokumentacja Microsoft](https://learn.microsoft.com/en-us/troubleshoot/windows-client/setup-upgrade-and-drivers/limitations-dollar-sign-winpedriver-dollar-sign).

Jeżeli firmware nie udostępnia zgodnej obsługi Int10, Core uruchamia
UefiSeven i sprawdza wynik przed WIMBoot. Po zakończeniu Setup finalizator
przygotowuje rozruch z wewnętrznego dysku: wymaga dokładnie jednego nowego
lub zmienionego magazynu BCD oraz zgodności bootmgfw.efi z wybranym obrazem.
W przypadku WinPE 10 program rozruchowy w PE nie jest plikiem Windows 7.
Finalizator wymaga wtedy jednoznacznie zmienionego BCD i wersji 6.1 nowo
zapisanego programu rozruchowego. Zachowuje dokładną kopię tego pliku,
dołącza UefiSeven i sprawdza zapis.
Nie wybiera partycji na USB ani nie rozstrzyga niejednoznaczności kolejnością dysków.

Podczas pracy Setup pomocnik aktualizuje tymczasową wskazówkę magazynu
systemowego przez `bcdedit /sysstore`. Wybiera jedyną wewnętrzną ESP lub
jedyną nową ESP względem inwentaryzacji sprzed Setup. Nie zmienia partycji
ani pliku BCD. Wskazówka znika po restarcie. Usuwa to niejednoznaczność
między ESP nośnika USOS i ESP instalowanego systemu.

Ścieżka dodaje KB2990941-v3 i KB3087873-v2 do servicing systemu docelowego,
jeżeli metadane wszystkich obrazów instalacyjnych potwierdzają Windows 7 SP1
x64. Pakiety mają przypięte sumy SHA-256; osobny plik odpowiedzi zachowuje
ustawienia użytkownika. WinPE 10 ma własny sterownik NVMe instalatora;
oryginalny WinPE 7 nadal wymaga zgodnego wsparcia kontrolera w boot.wim.
Pełna instalacja na NVMe w tej ścieżce nie jest jeszcze potwierdzona.

Build `B260914-131030-E58763A4` przygotowuje oba wejścia docelowego EFI:
`EFI/Microsoft/Boot/bootmgfw.efi` i `EFI/Boot/bootx64.efi`, zachowując oryginał
Microsoftu w obu katalogach. Nie nadpisuje obcego istniejącego loadera fallback.
Sprawdza również pierwszy opcode handlera Int10h i zapisuje diagnostykę obok
loadera. Pełny build i zestaw testów przeszły; start kopii Windows 7 na SATA
przez fallback w czystym OVMF doszedł do pulpitu. Zaktualizowano Kingstona
i naprawiono EFI testowego Intela 120 GB. Fizyczny start na płycie pozostaje
do potwierdzenia — szczegóły w `windows7-x470-starting-windows.md`.

## Sprawdzone obrazy

- `WIN7X64.6in1.pl-PL.JULY2019.ISO`: boot.wim zawiera WinPE x64
  10.0.17763.107, sterowniki `stornvme.sys` i `USBXHCI.SYS`; źródło to
  `install.esd`. SHA-256 boot.wim:
  `32b7ac47020095ed951f523920a5623117cb1bcec6ea849a8bb8f59df0bcd482`.
- `pl_windows_7_ultimate_with_sp1_x64_dvd_u_677341.iso`: boot.wim zawiera
  WinPE x64 6.1.7601.17514. SHA-256 boot.wim:
  `f53d14ee6c951244aeda6e4b486bd837674cd657e7454c96fa7c27a29fa99d69`.

W zmodyfikowanym obrazie 7-Zip odrzuca UDF, a warstwa ISO9660 pokazuje
tylko README. Odczyt plików przez UDF działa. Nie należy utożsamiać takiego
wyniku 7-Zip z brakiem plików Windows w ISO.

## Wcześniejszy test zmodyfikowanego ISO, 13 września 2026

Test integracyjny ręcznie przygotowanego nośnika plikowego QEMU przeszedł
rzeczywistą nawigację w menu USOS, wybór zmodyfikowanego ISO, Automatic,
brak pliku odpowiedzi, WIMBoot UEFI, start oryginalnego Setup z ISO i ekran
wyboru docelowego dysku SATA 32 GiB. WORK był pusty; mikro-Linux nie brał
udziału w tym rozruchu. Źródło było dołączone tylko do odczytu przez NEC xHCI.

To wcześniejszy test startu instalatora, **nie pełnej instalacji tej edycji
do pulpitu** ani działania na fizycznym X470. Obecna ścieżka dodaje obsługę
partycji EFI i finalizator także dla tego obrazu, zachowując jego własny
program Setup i sterowniki.

Dowody: `zig-out/win7-direct-work/iso-inspection.json`, `direct-serial.log`,
`summary.png`, `stage.png`, `disks.png`. Stare dyski testowe usunięto na
życzenie użytkownika; logi i zrzuty zostały zachowane.

Kontrakt EFI WIMBoot:
[kod odczytu plików](https://github.com/ipxe/wimboot/blob/v2.9.0/src/efifile.c),
[nagłówek WIM](https://github.com/ipxe/wimboot/blob/v2.9.0/src/wim.h).

## Pełne instalacje, 14 września 2026

Oryginalny Ultimate SP1 x64 przeszedł pełną instalację w QEMU TCG:
firmware EDK2 UEFI bez CSM, dysk SATA 32 GiB, źródło USOS tylko do odczytu,
klawiatura i tablet na kontrolerze NEC xHCI. Setup uruchomiono bezpośrednio
z menu USOS, bez przygotowania WORK. Pakiety NEC zostały przekazane do RAM,
załadowane w WinPE 7 i dodane do systemu docelowego przez plik odpowiedzi.
Wybór dysku wykonano ręcznie w Setup.

Po automatycznej finalizacji rozruchu usunięto źródłowy nośnik z konfiguracji
maszyny. System z dysku SATA przeszedł konfigurację pierwszego uruchomienia
do pulpitu. Klawiatura USB działała, a `sc query nusb3xhc` potwierdziło
stan RUNNING. Dowód: `zig-out/win7-universal-work/fixed-target-usb.png`.

Obraz 6-w-1 (Ultimate STD) również zakończył instalację i uruchomił pulpit
z dysku SATA, po usunięciu źródłowego USB z konfiguracji QEMU. Tymczasowy
wybór ESP oraz finalizator działały automatycznie. Klawiatura USB działała
w konfiguracji konta i na pulpicie; `nusb3xhc` miał stan RUNNING. Dowód:
`zig-out/win7-universal-work/modern-final-desktop-usb.png`.
Ta próba poprzedza rozszerzenie przekazywania zewnętrznych pakietów również
na instalację prowadzoną przez nowszy PE.

Zmodyfikowany instalator dodaje elementy także podczas późniejszej
konfiguracji. Brak sterownika w samym katalogu `System32/drivers` lub
`DriverStore` odczytanym z ESD nie dowodzi jego braku w gotowym systemie.

Test potwierdza tę konfigurację QEMU i pakiet NEC. Nie zastępuje próby na
fizycznej płycie X470 ani nie gwarantuje obsługi każdego kontrolera USB.
Mechanizm dopasowania pakietów jest ogólny; pokrycie sprzętu zależy od
dostarczonych zgodnych sterowników.

Menu UEFI wyłącza początkowy licznik watchdog firmware. Inaczej dłuższe
przebywanie w menu lub odczyt ISO może zakończyć się resetem po pięciu
minutach; opis zachowania znajduje się w
[specyfikacji UEFI](https://uefi.org/specs/UEFI/2.10_A/07_Services_Boot_Services.html).

## Ograniczony stos firmware, 14 września 2026

Próba QEMU z 4 GiB RAM i czterema procesorami ujawniła dwa przepełnienia
stosu: w podsumowaniu ISO i przy rozpoczęciu ładowania. Ślad procesora
potwierdził zapis na chronioną stronę stosu, podwójny wyjątek i reset.
Nie był to reset wywołany przez watchdog.

Stan katalogu menu oraz duże struktury ładowania ISO są teraz alokowane
przez UEFI poza stosem. Ograniczono także rozwijanie funkcji inspekcji
i startu w miejscu wywołania. Rezerwacja stosu `manual_app.run` spadła
z 69 560 do 16 152 bajtów, a `manual_summary.start` z 81 848 do 6 616 bajtów;
oddzielne `windows_native_iso.start` rezerwuje 20 664 bajty.

Po poprawce ta sama konfiguracja przeszła podsumowanie, odczyt pakietów,
załadowanie WIMBoot i uruchomienie Windows Setup z ISO 6-w-1. Poprzedzająca
próbę ładowania kontrola menu potwierdziła także ponad pięć minut bez resetu.
Dowody: `zig-out/win7-universal-work/stack2-summary.png`,
`stack2-start.png`, `stack2-disks.png` i `stack-idle-over-five-minutes.png`.

Pełny `build.bat` i `tools/tests/run.ps1 -Suite all` zakończyły się sukcesem.
Wersję `B260914-111114-CCC44003` zapisano na Kingston DataTraveler 3.0;
aktualizator potwierdził sumy SHA-256 po zapisie oraz zachowanie GUID-ów,
offsetów i rozmiarów partycji. Log:
`zig-out/win7-universal-work/kingston-win7-universal-operation.log`.

## Zewnętrzne sterowniki przy instalacji z WinPE 10

Ponowiona próba na najnowszym Core, 4 GiB RAM i czterech procesorach
potwierdziła pełny etap instalacji z WinPE 10 dla Ultimate STD z ISO 6-w-1.
Setup użył wygenerowanego wpisu `DriverPaths`, zachowując ręczny wybór
pustego dysku. DISM dodał do docelowego Windows 7 wszystkie cztery INF:
`nusb3hub.inf`, `nusb3xhc.inf`, `rusb3hub.inf` i `rusb3xhc.inf`.
Każdy pakiet otrzymał `HRESULT = 0x0`; `InstallDriversOffline` zwrócił 0.

Setup zakończył fazę instalacji 14 września o 11:29:22 UTC. Finalizator
automatycznie zainstalował pomocniki UEFI. Następnie system uruchomił się
z samego dysku SATA, bez źródłowego USB, i przeszedł do końcowej konfiguracji.
Logi zachowano w `zig-out/win7-universal-work/stack-target-inspection`;
raport WinPE to `stack2-usb-efi-report.png`, a pierwszy rozruch z dysku
to `stack2-target-config.png`.

Próba zakończyła się utworzeniem konta i uruchomieniem pulpitu Windows 7
Ultimate. Klawiatura USB działała podczas konfiguracji konta; usługa
`nusb3xhc` miała stan `RUNNING` i oba kody wyjścia równe 0. Dowody:
`zig-out/win7-universal-work/stack2-target-usb.png`, `stack2-input.png`
i `stack2-desktop.png`. Jest to pełna instalacja po rozszerzeniu przekazywania
zewnętrznych pakietów na nowszy PE i po obu poprawkach stosu Core.
