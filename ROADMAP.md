# Pozostałe prace USOS

Aktualizacja: 13 września 2026. Lista obejmuje ustalenia z użytkownikiem;
otwarte pozycje nie są deklaracją działającej obsługi. Szczegóły wykonanych
testów pozostają w [TESTING.md](TESTING.md) i raportach w `docs`.

## Potwierdzone przez użytkownika

- Windows 10 i Windows 11 działają w UEFI; użytkownik potwierdził także
  unattended. Zachować te przebiegi przy kolejnych zmianach.
- SliTaz Live uruchamia pulpit na fizycznym sprzęcie.
- Wcześniejsze potwierdzenia BIOS, DOS i narzędzi opisuje TESTING.md.

To potwierdzenia konkretnych prób, a nie wszystkich obrazów, wydań,
architektur, metod startu i konfiguracji sprzętowych.

## 1. Windows 7 — UEFI i USB 3

Status: implementacja UEFI x64 i integracja własnych sterowników USB 3
ukończone; 13 września 2026 pełna instalacja ręczna i unattended do pulpitu
bez USB — PASS w QEMU/OVMF bez CSM. Kingston zaktualizowany do
`B260913-183930-83CD1F61`, także z integracją poprawek NVMe opisaną poniżej.
[Zakres testów UEFI/USB 3](docs/windows7-uefi.md).
Fizyczny sprzęt, CSM, AMD USB 3 i NVMe pozostają do osobnego sprawdzenia.
Cel fizycznego testu podany przez użytkownika: ASRock X470 Master SLI/ac,
Ryzen 7 5700X, 32 GB RAM, dysk SATA, wymienna karta graficzna. Zestaw służy
wyłącznie do testów instalacji.

- Sprawdzić oryginalny obraz Windows 7 x64 w UEFI, osobno konfiguracje
  z CSM i bez CSM, oraz zapisać rzeczywisty zakres zgodności.
- Przygotować obsługę poprawki / integracji sterowników USB 3 (xHCI):
  klawiatura, mysz i dostęp do źródła instalacji mają działać zarówno
  w instalatorze, jak i po instalacji. Dobór sterownika do kontrolera.
- Ustalić, które pliki przygotowanego instalatora i systemu wymagają
  sterowników. Oryginalne ISO zachować bez zmian; modyfikować kopię roboczą.
- Sprawdzić ewentualne wymagania NVMe i rozruchu UEFI oddzielnie od USB 3.
  Automatyczna integracja KB2990941 + KB3087873 jest zaimplementowana.
  Ochrona nowszych składników, 14 testów pomocników, 6 scenariuszy WIM
  i pełna instalacja SATA do pulpitu są zaliczone. Pełną próbę NVMe
  bez źródłowego pendrive'a zakończono bez potwierdzenia pulpitu z powodu
  bardzo powolnej konfiguracji w QEMU. Integracja jest dostępna, a pełna
  zgodność NVMe pozostaje do sprawdzenia. [Raport](docs/windows7-nvme.md).
- Zaliczenie: wybór ISO → instalator → instalacja → restart → start
  z dysku bez pendrive’a, także po użyciu unattended.

## 2. Windows Vista — UEFI

Status: do sprawdzenia, bez przenoszenia wyniku BIOS na UEFI.

- Ustalić obsługiwane wydanie, service pack i architekturę na konkretnym ISO.
- Sprawdzić start instalatora, wymagania firmware, sterowniki i rozruch
  z docelowego dysku po odłączeniu USB.
- Oddzielnie zapisać wynik UEFI z CSM i bez CSM oraz ograniczenia.

## 3. Windows XP i starsze — zakres firmware

Status: analiza możliwości oraz uzupełnienie macierzy zgodności.

- Obecny backend XP / Windows 2000 (`xp_staging`) wymaga BIOS-u;
  również obecne ścieżki DOS, Windows 3.x i Windows 98 SE są BIOS-owe.
- Sprawdzić osobno możliwości konkretnego wydania w czystym UEFI,
  uruchamianie przez CSM oraz rozwiązania eksperymentalne. Nie przedstawiać
  CSM ani emulacji jako natywnej obsługi UEFI przez docelowy system.
- W menu udostępniać tylko zweryfikowane ścieżki; przy niezgodności podać
  czytelną przyczynę i wymagany tryb firmware.
- Test obejmuje cały przebieg instalacji i samodzielny rozruch docelowego
  systemu, nie tylko wyświetlenie pierwszego ekranu Setup.

## 4. Wybór języka w instalatorze Go i w USOS

Status: do implementacji.

- Dodać wybór języka w instalatorze Go. Wybrany język ma obowiązywać
  również w menu USOS, komunikatach, błędach i ekranach przygotowania
  w BIOS, UEFI oraz środowisku pomocniczym.
- Ustalić początkowy zestaw tłumaczeń; proponowany pierwszy zakres: PL i EN.
- Zapisywać konfigurację instalatora obok jego pliku wykonywalnego,
  a konfigurację gotowego USOS na jego pendrivie. Przeniesienie folderu
  aplikacji lub nośnika ma zachowywać wybór języka.
- Aktualizacja i naprawa mają zachować język. Bez zapisu ustawień w profilu
  użytkownika, AppData ani rejestrze Windows.
- Język interfejsu USOS i język instalowanego systemu są osobnymi
  ustawieniami; nie zmieniać drugiego bez wyboru użytkownika.
- Zweryfikować znaki narodowe, szerokość tekstów i komunikaty dynamiczne.

## 5. Generator unattended

Status: do implementacji; używanie gotowych plików zostało potwierdzone,
co nie oznacza istnienia generatora.

- Formularz tworzenia, podgląd, walidacja, zapis oraz edycja własnego pliku
  odpowiedzi w katalogu `Unattended` właściwego profilu na DATA.
- Pierwszy etap: Windows 10/11. Kolejne rodziny mają własny format
  i zestaw obsługiwanych opcji; dodawać je po testach.
- Uwzględnić język i klawiaturę, konto użytkownika, nazwę komputera oraz
  obsługiwane ustawienia instalacji. Ustawienia kasowania / partycjonowania
  dysku wymagają świadomego wyboru; nie dopisywać ich automatycznie.
- Chronić wartości wrażliwe przed trafieniem do logów. Wszystkie pliki
  generatora, jego konfiguracja i kopie mają być przenośne.
- Zaliczenie: plik wygenerowany w aplikacji przechodzi rzeczywistą
  instalację testową, bez ręcznych poprawek pliku.

## 6. Zegar na ekranach postępu

Status: błąd zgłoszony przez użytkownika, do odtworzenia i naprawy.

- Na ekranach rozpakowywania i podobnych operacji wyświetlany czas
  przestaje się aktualizować. Sprawdzić zegar nagłówka, a tam, gdzie
  występuje, również licznik czasu operacji.
- Przejrzeć ekrany kopiowania, rozpakowywania, weryfikacji, ładowania
  i przygotowania WORK w BIOS, UEFI oraz środowisku pomocniczym.
- Odświeżać czas niezależnie od zmian procentu postępu i wejścia użytkownika,
  bez migotania ekranu i bez spowalniania odczytu / zapisu.
- Zaliczenie: podczas długiej operacji, także przy niezmienionym procencie,
  czas aktualizuje się bez ruchu myszy i naciskania klawiszy.

## 7. Rozwojowe wydania Windows

Status: profile katalogu istnieją; instalacje wymagają osobnej pracy.

- Zakres: Windows Longhorn, Whistler, Neptune, Chicago, Memphis i Nashville.
- Wybierać i testować konkretne buildy. Rozpoznawać strukturę obrazu,
  rodzinę instalatora i architekturę; nie zakładać zgodności wszystkich
  buildów tylko na podstawie nazwy projektu.
- Dobierać istniejący backend, jeśli faktycznie pasuje, lub dodać potrzebną
  obsługę. Zapisywać wymagania RAM, dysku, firmware i ewentualnej daty.
- Wymagania historycznych wersji dotyczące daty obsługiwać w testowej VM;
  nie zmieniać samodzielnie zegara komputera użytkownika.
- Dla każdego zaliczonego buildu: instalacja, restart, pulpit i start bez
  pendrive’a; wyraźnie oznaczyć przetestowane wersje oraz ograniczenia.

## Pozostałe wcześniejsze ustalenia

- Konsolidacja nośników: USOS i obrazy na SanDisku 128 GB zamiast E2B,
  następnie zwolnienie Kingstona. Wykonano tylko inwentaryzację; nie ma
  jeszcze kopii zapasowej, migracji ani formatowania. Zachować obrazy,
  unattended, sterowniki i narzędzia; zweryfikować kopię i nowy nośnik.
  Użytkownik pozostawił wybór terminu agentowi; migrację odłożono do
  zakończenia etapu Windows 7 UEFI / USB 3. E2B pozostaje do porównań.
- Osobne środowisko przygotowania dla CPU x86 bez long mode pozostaje
  wcześniejszym planem opisanym w README. Działanie menu BIOS i DOS
  na 32-bitowym CPU nie oznacza działania obecnego mikro-Linuksa na nim.
- Rozszerzanie Linux Live poza pierwszy sprawdzony SliTaz oraz walidacja
  narzędzi w UEFI pozostają osobnymi etapami wcześniejszej kolejki.

## Proponowana kolejność

Windows 7 UEFI / USB 3 → Vista UEFI → macierz XP i starszych → języki →
generator unattended → zegar na ekranach postępu → konkretne buildy beta.
Migracja SanDiska jest oddzielną operacją i nie wymaga ukończenia całej listy.
Priorytety mogą zostać zmienione przez użytkownika.
