# Dalsze pokrycie systemów i narzędzi — 12 września 2026

Użytkownik potwierdził działanie Windows 2000 oraz Windows 10 x86 na Socket 939. Priorytetem jest
teraz pokrycie pozostałych rodzin. Pauza podczas startu Windows 2000 oraz
wcześniejszy problem automatycznego restartu Visty pozostają zapisane do
późniejszego pomiaru i diagnostyki. Nie ustalono przyczyn tych zachowań.

## Zakres do wykonania i sprawdzenia

| Obszar | Zakres | Stan / warunek |
| --- | --- | --- |
| Windows 10 x86, BIOS | natywny start ISO i pełna instalacja | build i VM PASS; użytkownik potwierdził działanie Windows 10 z przygotowanego Kingstona na Socket 939; [raport](windows10-x86-bios-2026-09-12.md) |
| Windows 3.1 / 3.11 | MS-DOS 6.22, instalator, tryb rozszerzony 386 i zapis plików | pełne instalacje Windows 3.1 PL i 3.11 OEM EN oraz zimne starty bez USB: VM PASS; próba na sprzęcie pozostaje otwarta; [raport](dos-windows3-bios-2026-09-12.md) |
| Windows 98 | domknięcie testu na docelowym zestawie retro | poprzedniego problemu na Socket 939 nie uznawać za rozwiązany przez sukces Windows 2000 |
| UEFI x64 | pełne przebiegi wybranych Windows 10/11; osobno Windows 7 x64 i Vista x64 SP1/SP2 | rozróżniać start menu USOS, start instalatora i pełną instalację; Secure Boot to oddzielna próba |
| Windows XP | pozostaje ścieżką BIOS / CSM | brak standardowej natywnej obsługi UEFI; zewnętrzne modyfikacje stanowią osobny eksperyment |
| MS-DOS i programy z USB | start z USB w RAM oraz instalacja DOS-u na dysku | DOS 6.22, program z plikiem pomocniczym i zapis w folderze programu: VM PASS; sesja z USB jest nietrwała, instalacja na dysku zachowuje pliki; FreeDOS pozostaje osobnym zakresem |
| Memtest86+ | bezpośrednia pozycja w Utilities, odpowiedni wariant BIOS / UEFI | samodzielny tester pamięci; nie wymaga FreeDOS-u |
| Linux Live ISO | start pulpitu/narzędzi z USB oraz instalacja z tego środowiska na wybrany dysk | profil uruchomienia dla konkretnego obrazu; przetestować ponowne odnalezienie ISO po starcie kernela i zgodność CPU |

Windows 3.x jest środowiskiem graficznym uruchamianym nad DOS-em. Baza DOS
i obsługiwany tryb pracy są częścią testu. FreeDOS 1.4 opisuje ograniczenia
dla Windows for Workgroups w trybie rozszerzonym w swoich
[uwagach do wydania](https://freedos.org/download/announce.html).

## Granice UEFI

- Windows 7: standardowy cel UEFI to x64; na typowej ścieżce wymaga CSM dla
  usług starszego firmware, w tym obrazu. UEFI z CSM i czyste UEFI bez CSM
  nie są jednym przypadkiem testowym.
- Vista: cel UEFI to x64 z SP1/SP2. XP x86/x64 nie ma standardowej ścieżki UEFI.
- Windows 10 x86 nie jest zamiennikiem Windows 10 x64 na firmware UEFI x64.
  Dla standardowego startu Windows architektura firmware i systemu musi pasować;
  UEFI IA32 stanowi osobny zakres, którego obecny zestaw loaderów USOS nie pokrywa.

Źródła: [Microsoft — firmware i Windows](https://learn.microsoft.com/en-us/troubleshoot/windows-server/backup-and-storage/support-for-hard-disks-exceeding-2-tb),
[Microsoft — Windows 7, CSM i architektura UEFI](https://learn.microsoft.com/en-us/windows-hardware/drivers/bringup/frequently-asked-questions),
[UEFI Forum — Vista SP1 x64](https://uefi.org/press-release/UEFI_Industry_Adoption_Takes_Major_Step_Forward_with_Availability_of_Microsoft_Windows_Vista_SP1_and_Windows_Server_2008_February_19_2008),
[Memtest86+ — tryby rozruchu](https://memtest.org/readme).

## Proponowana kolejność

Windows 10 x86 BIOS jest zakończony dla sprawdzonego obrazu i zestawu Socket 939.

1. Próba DOS-u i Windows 3.x na fizycznym sprzęcie po zakończonych testach VM.
2. Memtest86+ jako niezależne narzędzie.
3. Wybrane obrazy Linux Live: start i instalacja na dysk.
4. Domknięcie macierzy UEFI dla Windows i narzędzi.
5. Powrót do otwartego testu Windows 98 oraz odłożonych problemów z czasem startu i restartami.

Ta kolejność jest propozycją na podstawie rozmowy, nie deklaracją wykonania
tych prac. Live ISO jest preferowanym kierunkiem dla Linuksa: USOS uruchamia
oryginalne środowisko, a dystrybucja prowadzi własną instalację. Nie zakładamy,
że każdy plik ISO ma identyczny sposób startu lub obsługuje każdy stary CPU.
