# Windows 7 x64 — przygotowanie UEFI i sterowników USB 3

Aktualna ścieżka dla obu rodzajów ISO jest opisana w
[bezpośrednim starcie WIMBoot UEFI](windows7-direct-iso.md).
Poniżej zachowano **historyczny opis przygotowania na WORK i jego testów**.
Wyniki pełnej instalacji z tego raportu nie są wynikami nowej ścieżki ISO.
Opcja Chainload została usunięta z menu Windows 7.

Stan prac: 13 września 2026, pełna instalacja ręczna i bezobsługowa zaliczone
w QEMU, do pulpitu po odłączeniu źródłowego USB.
Nie jest to jeszcze potwierdzenie działania na fizycznym komputerze.

Ścieżka korzysta z oryginalnego instalatora Windows 7 x64 (WinPE 6.1).
USOS sprawdza metadane boot.wim przed formatowaniem własnej partycji WORK.
Oryginalny obraz ISO pozostaje bez zmian. Przygotowanie modyfikuje jego kopię
na WORK, montowaną przez ntfs-3g ze względu na zgodność ze starym sterownikiem
NTFS w Windows 7.

## Sterowniki

Sprzęt docelowy podany przez użytkownika 13 września 2026:
**ASRock X470 Master SLI/ac, AMD Ryzen 7 5700X, 32 GB RAM**.
B550 Taichi jest komputerem roboczym, a nie celem tej instalacji.
Komputer służy wyłącznie do prób instalacji; dysk docelowy jest SATA,
karta graficzna jest wymienna. Identyfikatory kontrolerów USB pozostają
do ustalenia. Sterowniki NEC wykorzystane w QEMU nie są pakietem
sterowników dla tego zestawu.

AMD wymienia X470 w historycznej obsłudze Windows 7, ale 5700X nie ma
Windows 7 na oficjalnej liście obsługiwanych systemów. Dlatego zgodność
całego zestawu i poszczególnych kontrolerów wymaga fizycznego testu.
Źródła: [AMD — sterowniki chipsetu 2.04.04.111](https://www.amd.com/en/resources/support-articles/release-notes/amd-ryzen--chipset-driver-release-notes--2-04-04-111-.html),
[AMD — Ryzen 7 5700X](https://www.amd.com/en/support/downloads/drivers.html/processors/ryzen/ryzen-5000-series/amd-ryzen-7-5700x.html),
[ASRock — specyfikacja płyty](https://www.asrock.com/mb/AMD/X470%20Master%20SLIac/index.asp).

Rozpakowane pakiety Windows 7 x64 należy umieścić na DATA w
`Systems/Windows/Windows 7/Drivers/x64`. Podkatalogi są obsługiwane; wymagany
jest komplet plików INF, SYS, CAT i zależności danego pakietu. Instalator EXE
producenta nie zastępuje rozpakowanego pakietu.

Pakiety trafiają do boot.wim, skąd DrvLoad ładuje je przed otwarciem źródła
na USB. Druga kopia w `$WinPEDriver$` jest przekazywana oryginalnemu Setup,
aby sterowniki trafiły również do instalowanego systemu. Nie wyłączamy
sprawdzania podpisów. Dobór pakietu zależy od identyfikatora kontrolera;
jeden sterownik NEC/Renesas nie obsługuje wszystkich kontrolerów USB 3.
Ta integracja dotyczy przygotowanej ścieżki UEFI Windows 7.

Microsoft opisuje różnicę pomiędzy sterownikiem załadowanym w WinPE a
sterownikiem przekazanym instalowanemu systemowi w dokumentacji
[$WinPEDriver$](https://learn.microsoft.com/en-us/troubleshoot/windows-client/setup-upgrade-and-drivers/limitations-dollar-sign-winpedriver-dollar-sign).

## Rozruch

Obsługa NVMe w samym mikro-Linuksie nie oznacza obsługi NVMe w Windows 7.
Nowy pakiet integruje automatycznie poprawki Microsoft KB2990941
i KB3087873 dla oryginalnego Windows 7 SP1 x64. Pełna instalacja na SATA
z tymi pakietami jest zaliczona; próba do pulpitu na wirtualnym NVMe nie
została potwierdzona. Integracja jest dostępna w pakiecie, lecz pełna
zgodność NVMe wymaga dalszej weryfikacji.
Zakres, obsługę nowszych składników i ograniczenia WinRE opisuje
[raport NVMe](windows7-nvme.md).
Aktualny Kingston zawiera pakiet `B260913-183930-83CD1F61`; wszystkie
78 statycznych plików ESP sprawdzono odczytem porównawczym.
Źródło: [Microsoft — natywna obsługa NVMe w Windows 7](https://support.microsoft.com/en-au/topic/update-to-add-native-driver-support-in-nvm-express-in-windows-7-and-windows-server-2008-r2-03cd423b-d42e-66c2-722b-019d16455a6b).

Obrazy przygotowane przez Windows 7 Image Updater od Atak_Snajpera mogą
zawierać już sterowniki NVMe i instalator Windows 10. Automatyczna ścieżka USOS
wykrywa teraz nowszy WinPE i uruchamia go bezpośrednio z ISO. Test startu
konkretnego obrazu opisano w [osobnym raporcie](windows7-direct-iso.md).
Wyniki pełnej instalacji poniżej nadal dotyczą WinPE 6.1. Przy dodawaniu poprawek należy
zachować nowsze składniki obecne w obrazie użytkownika.
Źródło: [opis narzędzia opublikowany przez autora](https://forum.videohelp.com/threads/384921-Windows-7-Image-Updater-SkyLake-KabyLake-CoffeLake-Ryzen-Threadripper).

Oryginalny menedżer EFI jest pobierany z install.wim. Dyspozytor USOS
zachowuje istniejącą usługę Int10 firmware, jeżeli jest obecna; w pozostałych
przypadkach uruchamia [UefiSeven 1.30](https://github.com/manatails/uefiseven/releases/tag/1.30).
Pakiet ma przypięte sumy SHA-256 i dołączoną licencję BSD.
Obejście blokady pamięci VGA jest ograniczone do dwóch emulowanych chipsetów
QEMU i identyfikatora hypervisora TCG.

Setup pracuje z opcją `/noreboot`. Przed jego uruchomieniem zapisywany jest
spis partycji EFI dysków wewnętrznych. Pomocnik obserwuje również partycję
utworzoną przez Setup i wskazuje ją oryginalnym `bcdedit /sysstore` na czas
bieżącej sesji WinPE. Wybiera jedyną wewnętrzną ESP albo jedyną nową ESP;
wielu kandydatów nie rozstrzyga kolejnością dysków. Tymczasowy alias dysku
jest usuwany po poleceniu. To wskazanie nie zapisuje plików rozruchowych.

Finalizator może zmienić wyłącznie
jeden nowy lub zmieniony magazyn rozruchowy, którego plik bootmgfw.efi jest
identyczny z menedżerem z wybranego ISO. Zachowuje oryginalny plik obok
dyspozytora i sprawdza zapisane pliki. Niejednoznaczność zatrzymuje ten etap.
Partycje nośników USB nie są celami finalizatora.

## Dotychczasowe wyniki

- Kompilacja pomocników EFI/WinPE i testy pakietu instalatora `winhost`: PASS.
- Przygotowanie kopii WORK przez produkcyjny skrypt w mikro-Linuksie: PASS.
- Start oryginalnego polskiego Windows 7 Professional SP1 x64 przez UEFI,
  obsługa klawiatury na NEC xHCI i odczyt źródła z WORK: PASS w QEMU.
- Pełna instalacja ręczna, OOBE i pulpit bez źródłowego USB: PASS w QEMU.
- Kontroler i koncentrator NEC USB 3 po instalacji: oba sterowniki RUNNING;
  klawiatura i mysz działają przez xHCI.
- Automatyczny wybór ESP utworzonej przez oryginalny Setup na pustym GPT,
  z domyślnym rozmiarem 100 MB: PASS. Bez ręcznej ingerencji w partycje.
- Pełna instalacja bezobsługowa na pustym dysku 32 GiB: PASS. Bez ręcznych
  poleceń w Setup, automatyczne partycjonowanie, finalizacja EFI, restarty,
  OOBE i pulpit. Źródłowy pendrive odłączono przy pierwszym restarcie.
- Oba sterowniki NEC także po unattended: RUNNING. Kontrola wyłączonego
  dysku testowego, zamontowanego tylko do odczytu: dyspozytor EFI, zachowany
  oryginał Microsoft, UefiSeven, licencja i oba sterowniki identyczne
  z plikami źródłowymi — PASS.

Próby pełnej instalacji używają OVMF bez CSM, TCG, VGA bez ROM-u BIOS,
2 GiB RAM i NEC xHCI (PCI 1033:0194). Oddzielna próba starszego OVMF
potwierdziła start WinPE z zachowaniem jego usługi Int10. Nie jest to test CSM.
Fixture wywołuje produkcyjne przygotowanie Windows 7 w mikro-Linuksie,
następnie testowy moduł przekazania startu NTFS i produkcyjną sekwencję
WinPE → Setup → finalizator. Nie powtarza całej nawigacji w menu USOS.

Pakiet wcześniejszego etapu UEFI/USB 3 `B260913-153109-717C2834` przeszedł `build.bat`, testy Go,
pełny zestaw `tools/tests/run.ps1 -Suite all` (w tym start x86-64 i ARM64)
oraz kontrolę zgodności payloadu. Dziewięć komponentów ścieżki Windows 7
w testowej instalacji i końcowym initramfs jest identycznych bajtowo.
Kingston został zaktualizowany bez formatowania; 78 plików ESP porównano
bajtowo z payloadem. Katalog sterowników i instrukcja na DATA są obecne.

Dowody w `zig-out/win7-uefi-work`: `main-desktop.png`,
`main-usb3-services.png`, `main-second-desktop.png`,
`chain-finalizer-pass.png`, `auto-desktop.png`, `auto-usb3-services.png`,
`auto-installed-sha256.json`, `linux-auto.log`, `tested-runtime-sha256.json`,
`build.log`, `tests.log`, `kingston-win7-uefi-operation.log`, `verify-usb.log`.

Próby korzystają z plików dysków w `zig-out/win7-uefi-work` i nie zapisują
na fizycznych dyskach komputera. Wynik QEMU z podpisanym pakietem NEC
2.1.36.0 nie potwierdza obsługi kontrolerów AMD na docelowym X470 Master SLI/ac,
NVMe, innych obrazów Windows 7 ani trybu Secure Boot.
