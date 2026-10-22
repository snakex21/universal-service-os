# Macierz Windows — checkpoint, testy instalacji nieukończone

Data: 2026-10-22. Baza `f28a3fd8155b82dd1be22608f6ef17e82437ad1d`, po rebase z `1197eb49`.

Inwentaryzacja obejmuje 102 plików wejściowych. To także archiwa, dyskietki, nośniki aktualizacji i duplikaty — nie liczba unikatowych instalatorów.

**Ten dokument nie spełnia jeszcze kryterium pełnych testów QEMU.** Wiersze „oczekuje” nie oznaczają ani PASS, ani wykrytego błędu Windows. Status X470 przypisano wyłącznie tam, gdzie dokumentacja wskazuje dokładne źródło.

„API” poniżej oznacza uruchomione biblioteczne parsery USOS. W szczególności `windows_legacy_media` nie jest w tej bazie wywoływany przez ekran UEFI; wpis katalogu i profil nie są automatycznym rozpoznaniem wersji/SP starszego ISO. Dla nowszych nośników odczytano także XML WIM.

| Obraz | Wersja / SP z nośnika | Język / arch | Katalog / profil UEFI | QEMU | Etap | Uwagi / API | X470 |
|---|---|---|---|---|---|---|---|
| Bety: 7 plików | poza zakresem | — | — | poza zakresem | — | bez testów instalacji i sondowania wersji | nie oceniano |
| Citrix WinFrame\Citrix WinFrame 1.8 (ISO + Tools ISO + boot disks).7z | 3.51.1057.6 | en-US / x86 | wymaga przypisania folderu katalogu | nie uruchomiono | brak backendu | brak identyfikacji przez sam parser optyczny; 5 obrazów wewnątrz archiwum; Katalog USOS jawnie blokuje WinFrame: potrzebny osobny Setup i integracja licencji Citrix. Narzędziowy Tools ISO i boot disks nie są osobnymi instalatorami. Źródło: catalog.ndjson, preparation_block. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows 1.01\Windows 1.01 EN (5.25 floppies).7z | nie odczytano wersji binarnej | nie odczytano / unknown | windows-1-01 / w9x-uefi-csmwrap | nie uruchomiono | brak przepływu zestawu dyskietek | brak identyfikacji przez sam parser optyczny; 5 obrazów wewnątrz archiwum; dyskietki/archiwum: parser optyczny nie ma zastosowania; Archiwum zawiera zestaw IMG, bez ISO. Obecny backend DOS/Win16 wymaga ISO9660 i SETUP.EXE w katalogu głównym. Brakuje przepływu podmiany/scalania dyskietek; wynik pokrewnego ISO nie jest przenoszony. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows 1.01\Windows 1.01 EN.iso | nie odczytano wersji binarnej | nie odczytano / unknown | windows-1-01 / w9x-uefi-csmwrap | QEMU PASS | pulpit | brak identyfikacji przez sam parser optyczny; artifacts\coverage\vm\windows-101-menu-5\result.json | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows 1.04\Windows 1.04 EN (5.25 floppies).7z | nie odczytano wersji binarnej | nie odczytano / unknown | windows-1-04 / w9x-uefi-csmwrap | nie uruchomiono | brak przepływu zestawu dyskietek | brak identyfikacji przez sam parser optyczny; 7 obrazów wewnątrz archiwum; dyskietki/archiwum: parser optyczny nie ma zastosowania; Archiwum zawiera zestaw IMG, bez ISO. Obecny backend DOS/Win16 wymaga ISO9660 i SETUP.EXE w katalogu głównym. Brakuje przepływu podmiany/scalania dyskietek; wynik pokrewnego ISO nie jest przenoszony. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows 1.04\Windows 1.04 EN.iso | nie odczytano wersji binarnej | nie odczytano / unknown | windows-1-04 / w9x-uefi-csmwrap | QEMU PASS | pulpit | brak identyfikacji przez sam parser optyczny; artifacts\coverage\vm\windows-104\result.json | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows 10\Windows 10 22H2 19045.6396 PL x86.iso | 10.0.19045 | pl-PL / x86 | windows-10 / win10-11-uefi-native | oczekuje | — | Windows 10 | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows 11\Windows 11 25H2 PL x64.iso | 10.0.26200 | pl-PL / x64 | windows-11 / win10-11-uefi-native | oczekuje | — | Windows 11 | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows 2.03\Windows 2.03 EN (720K floppies).7z | nie odczytano wersji binarnej | nie odczytano / unknown | windows-2-03 / w9x-uefi-csmwrap | nie uruchomiono | brak przepływu zestawu dyskietek | brak identyfikacji przez sam parser optyczny; 5 obrazów wewnątrz archiwum; dyskietki/archiwum: parser optyczny nie ma zastosowania; Archiwum zawiera zestaw IMG, bez ISO. Obecny backend DOS/Win16 wymaga ISO9660 i SETUP.EXE w katalogu głównym. Brakuje przepływu podmiany/scalania dyskietek; wynik pokrewnego ISO nie jest przenoszony. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows 2.03\Windows 2.03 EN.iso | nie odczytano wersji binarnej | nie odczytano / unknown | windows-2-03 / w9x-uefi-csmwrap | QEMU PASS | pulpit | brak identyfikacji przez sam parser optyczny; artifacts\coverage\vm\windows-203\result.json | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows 2.11 (286)\Windows 2.11 286 EN (720K floppies).7z | nie odczytano wersji binarnej | nie odczytano / unknown | windows-2-11-286 / w9x-uefi-csmwrap | nie uruchomiono | brak przepływu zestawu dyskietek | brak identyfikacji przez sam parser optyczny; 7 obrazów wewnątrz archiwum; dyskietki/archiwum: parser optyczny nie ma zastosowania; Archiwum zawiera zestaw IMG, bez ISO. Obecny backend DOS/Win16 wymaga ISO9660 i SETUP.EXE w katalogu głównym. Brakuje przepływu podmiany/scalania dyskietek; wynik pokrewnego ISO nie jest przenoszony. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows 2.11 (286)\Windows 2.11 286 EN.iso | nie odczytano wersji binarnej | nie odczytano / unknown | windows-2-11-286 / w9x-uefi-csmwrap | QEMU PASS | pulpit | brak identyfikacji przez sam parser optyczny; artifacts\coverage\vm\windows-211-286\result.json | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows 2.11 (386)\Windows 2.11 386 EN (3.5 floppies).7z | nie odczytano wersji binarnej | nie odczytano / unknown | windows-2-11-386 / w9x-uefi-csmwrap | nie uruchomiono | brak przepływu zestawu dyskietek | brak identyfikacji przez sam parser optyczny; 7 obrazów wewnątrz archiwum; dyskietki/archiwum: parser optyczny nie ma zastosowania; Archiwum zawiera zestaw IMG, bez ISO. Obecny backend DOS/Win16 wymaga ISO9660 i SETUP.EXE w katalogu głównym. Brakuje przepływu podmiany/scalania dyskietek; wynik pokrewnego ISO nie jest przenoszony. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows 2.11 (386)\Windows 2.11 386 EN.iso | nie odczytano wersji binarnej | nie odczytano / unknown | windows-2-11-386 / w9x-uefi-csmwrap | QEMU PASS | pulpit | brak identyfikacji przez sam parser optyczny; artifacts\coverage\vm\windows-211-386\result.json | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows 2000 Server\Windows 2000 Server PL.iso | 5.0.2195.1 | pl-PL / x86 | windows-2000-server / w2k-x86-sp4-uefi-csm | błąd adaptera testu | planowanie docelowego dysku testowego | windows-2000-server; Dysk VM 8 GiB odrzucony przez rzeczywisty planer NT5 (minimum 10 GiB łącznie). Bez zapisu celu i startu Windows. Nowy domyślny cel: 32 GiB thin qcow2. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows 2000 Server\Windows 2000 Server SP4 PL.iso | 5.0.2195.6717 / SP4 | pl-PL / x86 | windows-2000-server / w2k-x86-sp4-uefi-csm | błąd adaptera testu | planowanie docelowego dysku testowego | windows-2000-server; Dysk VM 8 GiB odrzucony przez rzeczywisty planer NT5 (minimum 10 GiB łącznie). Bez zapisu celu i startu Windows. Nowy domyślny cel: 32 GiB thin qcow2. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows 2000\W2KPLCMA4.811.iso | 5.0.2195.6717 / SP4 | pl-PL / x86 | windows-2000 / w2k-x86-sp4-uefi-csm | oczekuje | — | windows-2000 | X470 PASS: `docs/windows-2000-uefi-2026-09-27.md:106`, `docs/windows-2000-modern-2026-09-30.md:181`, `docs/windows-2000-modern-2026-09-30.md:712`; Historyczny test SP4 MPS; nie dowodzi ACPI ani innych SP/ISO |
| Windows 2000\W2KPLCMA6.7.15.iso | 5.0.2195.6717 / SP4 | pl-PL / x86 | windows-2000 / w2k-x86-sp4-uefi-csm | błąd adaptera testu | wyjęcie USB i ponowny start po przygotowaniu NT5 | windows-2000; USOS zweryfikował 5600 plików na celu NTFS 32 GiB, ale adapter nie odpowiedział na końcową stronę REMOVE USOS USB / POWER OFF. Windows nie został uruchomiony. Poprawka adaptera: 4d7077f6; brak wyniku ACPI, USB i LAN. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows 3.0\Windows 3.0a EN (720K floppies).7z | nie odczytano wersji binarnej | nie odczytano / unknown | windows-3-0 / w9x-uefi-csmwrap | nie uruchomiono | brak przepływu zestawu dyskietek | brak identyfikacji przez sam parser optyczny; 7 obrazów wewnątrz archiwum; dyskietki/archiwum: parser optyczny nie ma zastosowania; Archiwum zawiera zestaw IMG, bez ISO. Obecny backend DOS/Win16 wymaga ISO9660 i SETUP.EXE w katalogu głównym. Brakuje przepływu podmiany/scalania dyskietek; wynik pokrewnego ISO nie jest przenoszony. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows 3.0\Windows 3.0a EN.iso | nie odczytano wersji binarnej | nie odczytano / unknown | windows-3-0 / w9x-uefi-csmwrap | QEMU PASS | pulpit | brak identyfikacji przez sam parser optyczny; File Manager desktop after one manual Enter on the visible CONFIG.SYS/AUTOEXEC.BAT Setup question; operator-01.png | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows 3.11\Windows 3.11 OEM EN (1.44M floppies).zip | nie odczytano wersji binarnej | nie odczytano / unknown | windows-3-11 / w9x-uefi-csmwrap | nie uruchomiono | brak przepływu zestawu dyskietek | brak identyfikacji przez sam parser optyczny; 12 obrazów wewnątrz archiwum; dyskietki/archiwum: parser optyczny nie ma zastosowania; Archiwum zawiera zestaw IMG, bez ISO. Obecny backend DOS/Win16 wymaga ISO9660 i SETUP.EXE w katalogu głównym. Brakuje przepływu podmiany/scalania dyskietek; wynik pokrewnego ISO nie jest przenoszony. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows 3.11\Windows 3.11 OEM EN.iso | 3.11.0.2 | nie odczytano / unknown | windows-3-11 / w9x-uefi-csmwrap | QEMU PASS | pulpit | brak identyfikacji przez sam parser optyczny; artifacts\coverage\vm\windows-311-oem\result.json | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows 3.1\Windows 3.1 PL.iso | 3.10.0.103 | nie odczytano / unknown | windows-3-1 / w9x-uefi-csmwrap | QEMU PASS | pulpit | brak identyfikacji przez sam parser optyczny; Polish Program Manager desktop with Main group, accessories, games and Startup; endpoint.png at 600s | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows 7\Windows 7 Professional SP1 PL x64.iso | 6.1.7601 / SP1 | pl-PL / x64 | windows-7 / win7-uefi-native | oczekuje | — | Windows 7 | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows 7\Windows 7 SP1 6in1 PL x64 (2019-07).iso | 6.1.7601 / SP1 | pl-PL / x64 | windows-7 / win7-uefi-native | oczekuje | — | Windows 7 | X470 PASS: `docs/windows7-bios-2026-09-10.md:23`, `docs/windows7-bios-2026-09-10.md:24`, `docs/design/win7-vista-no-csm.md:561`, `docs/design/win7-vista-no-csm.md:565`; 6in1 PL July 2019, UEFI bez CSM; wynik nie obejmuje oryginalnych SP1 ISO |
| Windows 7\Windows 7 Ultimate SP1 PL x64.iso | 6.1.7601 / SP1 | pl-PL / x64 | windows-7 / win7-uefi-native | oczekuje | — | Windows 7 | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows 7\Windows 7 Ultimate SP1 PL x86.iso | 6.1.7601 / SP1 | pl-PL / x86 | windows-7 / win7-uefi-native | oczekuje | — | Windows 7 | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows 95\Windows 95 OSR2 Boot Disk.img | nie odczytano wersji binarnej | nie odczytano / unknown | windows-95 / w9x-uefi-csmwrap | nie uruchomiono | wejście pomocnicze | brak identyfikacji przez sam parser optyczny; dyskietki/archiwum: parser optyczny nie ma zastosowania; Pomocnicza dyskietka DOS używana w teście ISO Windows 95; sama nie zawiera kompletnej instalacji Windows. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows 95\Windows 95 OSR2.1 PL.iso | 4.0.0.1111 | nie odczytano / unknown | windows-95 / w9x-uefi-csmwrap | QEMU nieukończono | graficzny Setup / strefa czasowa | brak identyfikacji przez sam parser optyczny; artifacts/coverage/vm/r3-windows95-osr21-tcg/result.json; warianty: NVMe 4 GiB / TCG, próba z pauzą: INCOMPLETE (nested Setup); NVMe 4 GiB / WHPX: INCOMPLETE (restart firmware po przygotowaniu); QEMU TCG NVMe, stopped for the night: INCOMPLETE (prepared installation); NVMe 4 GiB / USB xHCI / TCG: INCOMPLETE (graficzny Setup / strefa czasowa) | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows 98 SE\Windows 98 SE PL OEM.iso | 4.10.0.2222 | nie odczytano / unknown | windows-98-se / w9x-uefi-csmwrap | oczekuje | — | brak identyfikacji przez sam parser optyczny | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows 98\Windows 98 PL.iso | 4.10.0.1998 | nie odczytano / unknown | windows-98 / w9x-uefi-csmwrap | oczekuje | — | brak identyfikacji przez sam parser optyczny | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows Embedded 8.1 Industry\Windows Embedded 8.1 Industry Pro (9600.16384) PL x64.iso | 6.3.9600 | pl-PL / x64 | windows-embedded-8-1-industry / win10-11-uefi-native | oczekuje | — | Windows Embedded 8.1 Industry | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows Embedded 8.1 Industry\Windows Embedded 8.1 Industry Pro (9600.16384) PL x86.iso | 6.3.9600 | pl-PL / x86 | windows-embedded-8-1-industry / win10-11-uefi-native | oczekuje | — | Windows Embedded 8.1 Industry | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows Embedded POSReady 2009\Windows Embedded POSReady 2009 (XP SP3) EN.iso | nie odczytano wersji binarnej / SP3 | en-US / x86 | windows-embedded-posready-2009 / posready-x86-qemu-csmwrap | oczekuje | — | windows-embedded-posready-2009 | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows Embedded POSReady 7\Windows Embedded POSReady 7 EVAL EN x64.iso | 6.1.7601 / SP1 | en-US / x64 | windows-embedded-posready-7 / win7-uefi-native | oczekuje | — | Windows Embedded Standard 7 | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows Embedded Standard 7\Windows Embedded Standard 7 SP1 IBW EN x86.iso | 6.1.7601 / SP1 | nie odczytano / x86 | windows-embedded-standard-7 / win7-uefi-native | nie uruchomiono | brak backendu | Windows Embedded Standard 7; backend wyłączony: WES7 requires Image Builder Wizard (IBW) and DS/Packages; installing only Embedded Core is not supported.; WES7 requires Image Builder Wizard (IBW) and DS/Packages; installing only Embedded Core is not supported. Produkcyjny katalog blokuje pełny przepływ; do pulpitu potrzebny osobny backend, poza małymi poprawkami tej macierzy. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows Embedded Standard 7\Windows Embedded Standard 7 SP1 Runtime EN x64.iso | 6.1.7601 / SP1 | nie odczytano / x64 | windows-embedded-standard-7 / win7-uefi-native | nie uruchomiono | brak backendu | Windows Embedded Standard 7; backend wyłączony: WES7 requires Image Builder Wizard (IBW) and DS/Packages; installing only Embedded Core is not supported.; WES7 requires Image Builder Wizard (IBW) and DS/Packages; installing only Embedded Core is not supported. Produkcyjny katalog blokuje pełny przepływ; do pulpitu potrzebny osobny backend, poza małymi poprawkami tej macierzy. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows Fundamentals for Legacy PCs\Windows Fundamentals for Legacy PCs EN.iso | nie odczytano wersji binarnej / SP1 | en-US / x86 | windows-flp / posready-x86-qemu-csmwrap | nie uruchomiono | brak backendu | windows-flp; backend wyłączony: FLP needs its own WinPE and WinFLP.wim installer integration.; FLP needs its own WinPE and WinFLP.wim installer integration. Produkcyjny katalog blokuje pełny przepływ; do pulpitu potrzebny osobny backend, poza małymi poprawkami tej macierzy. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows Home Server 2011\Windows Home Server 2011 (7601.17514) EN x64.iso | 6.1.7601 / SP1 | en-US / x64 | windows-home-server-2011 / win7-uefi-native | oczekuje | — | Windows Home Server 2011 | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows ME\Windows ME PL OEM.iso | 4.90.0.3000 | nie odczytano / unknown | windows-me / w9x-uefi-csmwrap | oczekuje | — | brak identyfikacji przez sam parser optyczny | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows NT 3.1 Advanced Server\Windows NT 3.1 Advanced Server 3.10.511.1 EN (ISO + boot disks).7z | 3.10.5098.1 | nie odczytano / x86 | windows-nt-3-1-server / nt3-x86-qemu-csmwrap | oczekuje | — | brak identyfikacji przez sam parser optyczny; 3 obrazów wewnątrz archiwum | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows NT 3.1\Windows NT 3.1 Workstation 3.10.511.1 EN (ISO).7z | 3.10.5098.1 | nie odczytano / x86 | windows-nt-3-1 / nt3-x86-qemu-csmwrap | QEMU PASS | pulpit | brak identyfikacji przez sam parser optyczny; 1 obrazów wewnątrz archiwum; Świeży normalny USOS: Program Manager Version3.1; PS/2, native safe-shutdown i rc0. USB out/in potwierdzone osobno w diagnostycznym R19c, nie w tej domyślnej konfiguracji; Intel LAN brak. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows NT 3.51 Server\Windows NT 3.51 Server 3.51.1057.1 EN (ISO + boot disks).7z | 3.51.1057 (NtBuildNumber; zasób 3.51.1025.1) | en-US / x86 | windows-nt-3-51-server / nt3-x86-qemu-csmwrap | oczekuje | — | brak identyfikacji przez sam parser optyczny; 4 obrazów wewnątrz archiwum | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows NT 3.51\Windows NT 3.51 SP5 EN.7z | nie odczytano wersji binarnej | nie odczytano / unknown | windows-nt-3-51 / nt3-x86-qemu-csmwrap | nie uruchomiono | archiwum aktualizacji | brak identyfikacji przez sam parser optyczny; 0 obrazów wewnątrz archiwum; dyskietki/archiwum: parser optyczny nie ma zastosowania; Archiwum dodatku/aktualizacji; listing nie zawiera obrazu instalacyjnego. Nie jest samodzielnym systemem do pierwszego pulpitu. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows NT 3.51\Windows NT 3.51 Workstation 3.51.1057.1 EN.7z | 3.51.1057 (NtBuildNumber; zasób 3.51.1025.1) | en-US / x86 | windows-nt-3-51 / nt3-x86-qemu-csmwrap | QEMU PASS | pulpit | brak identyfikacji przez sam parser optyczny; 4 obrazów wewnątrz archiwum; Świeży normalny USOS: pulpit Workstation3.51 build1057; native DHCP renew, ping3/3, ścisłe DNS, HTTP68k200. Latencja około2s pozostaje. PS/2 dozwolone; USB out/in potwierdzone osobno wR18f. Native Shutdown/rc0.; warianty: NVMe 4 GiB thin qcow2: FAIL (Setup w VM USOS, start 2); QEMU TCG AHCI; fresh normal USOS; desktop review2026-10-22: PASS (desktop) | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows NT 3.5\Windows NT 3.5 Workstation 3.50.807 EN (ISO + boot disks).7z | 3.50.800.1 | en-US / x86 | windows-nt-3-5 / nt3-x86-qemu-csmwrap | QEMU PASS | pulpit | brak identyfikacji przez sam parser optyczny; 4 obrazów wewnątrz archiwum; Świeży normalny USOS: rzeczywisty pulpit Workstation3.5 build807. Native DHCP, ping, ścisłe DNS i HTTP200; pierwszy ping2/3, warm3/3, opóźnienia około2s. PS/2 możliwe, USB kwalifikowane osobno w R20b. Osobno fresh nt35-irq-fresh01 z poprawionym SYS d94: normalny USOS/pusty target, native DHCP release/renew i ping3/3<10ms, strict FIXED DNS1.1.1.1/8.8.8.8, native resolver i HTTP200 PASS; configuredDNS10.0.2.3 tylko konfiguracja, strict configuredDNS NOT_TESTED. NativeShutdown/QEMU0 i dwa actualSYSreadback. Fresh Client/noSharing FAIL (Server/Browser RUNNING/Start2); PS/2 baseline, bez nowego HID/MSC/AUTO/X470/Server PASS. [Dokladny dowod fresh d94](nt35-fresh-corrected-driver-evidence.md). | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows NT 4.0 Server\Windows NT 4.0 Enterprise Server EN (CD1).iso | 4.0.1381.1 | en-US / x86 | windows-nt-4-server / nt4-x86-qemu-csmwrap | oczekuje | — | brak identyfikacji przez sam parser optyczny | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows NT 4.0 Server\Windows NT 4.0 Enterprise Server EN (CD1+CD2).7z | 4.0.1381.1 | en-US / x86 | windows-nt-4-server / nt4-x86-qemu-csmwrap | oczekuje | — | brak identyfikacji przez sam parser optyczny; 2 obrazów wewnątrz archiwum | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows NT 4.0 Server\Windows NT 4.0 Service Pack 6a.7z | nie odczytano wersji binarnej | nie odczytano / unknown | windows-nt-4-server / nt4-x86-qemu-csmwrap | nie uruchomiono | wejście aktualizacji | brak identyfikacji przez sam parser optyczny; 0 obrazów wewnątrz archiwum; dyskietki/archiwum: parser optyczny nie ma zastosowania; Archiwum Service Pack, bez ISO i bez kompletnej instalacji systemu; uzupełnienie z przeglądu listingu 7z. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows NT 4.0 Server\Windows NT 4.0 USB Support Patch.7z | nie odczytano wersji binarnej | nie odczytano / unknown | windows-nt-4-server / nt4-x86-qemu-csmwrap | nie uruchomiono | archiwum aktualizacji | brak identyfikacji przez sam parser optyczny; 0 obrazów wewnątrz archiwum; dyskietki/archiwum: parser optyczny nie ma zastosowania; Archiwum dodatku/aktualizacji; listing nie zawiera obrazu instalacyjnego. Nie jest samodzielnym systemem do pierwszego pulpitu. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows NT 4.0 Terminal Server\Windows NT 4.0 Terminal Server Edition EN.7z | 4.0.1381.32772 | en-US / x86 | windows-nt-4-tse / nt4-x86-qemu-csmwrap | oczekuje | — | brak identyfikacji przez sam parser optyczny; 1 obrazów wewnątrz archiwum | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows NT 4.0 Terminal Server\Windows NT 4.0 Terminal Server Edition EN.iso | 4.0.1381.32772 | en-US / x86 | windows-nt-4-tse / nt4-x86-qemu-csmwrap | oczekuje | — | brak identyfikacji przez sam parser optyczny | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows NT 4.0\ServicePacks\Windows NT 4.0 SP3 PL.iso | nie odczytano wersji binarnej | nie odczytano / unknown | wymaga przypisania folderu katalogu | nie uruchomiono | nośnik aktualizacji | brak identyfikacji przez sam parser optyczny; Service-pack CD, nie instalator Windows. Sprawdzono pełny listing 7-Zip: spcdrom.40 i SPSETUP.BAT/SP6I386.EXE; wymaga uprzednio zainstalowanego NT4. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows NT 4.0\ServicePacks\Windows NT 4.0 SP6a EN (40-bit).iso | nie odczytano wersji binarnej | nie odczytano / unknown | wymaga przypisania folderu katalogu | nie uruchomiono | nośnik aktualizacji | brak identyfikacji przez sam parser optyczny; Service-pack CD, nie instalator Windows. Sprawdzono pełny listing 7-Zip: spcdrom.40 i SPSETUP.BAT/SP6I386.EXE; wymaga uprzednio zainstalowanego NT4. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows NT 4.0\ServicePacks\Windows NT 4.0 SP6a PL.iso | 4.0.1381.335 | nie odczytano / x86 | wymaga przypisania folderu katalogu | nie uruchomiono | nośnik aktualizacji | brak identyfikacji przez sam parser optyczny; Service-pack CD, nie instalator Windows. Sprawdzono pełny listing 7-Zip: spcdrom.40 i SPSETUP.BAT/SP6I386.EXE; wymaga uprzednio zainstalowanego NT4. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows NT 4.0\Windows NT 4.0 Workstation PL.iso | 4.0.1381.1 | pl-PL / x86 | windows-nt-4 / nt4-x86-qemu-csmwrap | QEMU PASS | pulpit | Fresh candidate03 completed native Polish desktop; safe shutdown09/QMP0/readback. Earlier failures and separate LAN08b/MSC04/combo01 retained. One installed coexistence09: same USB313952 HID+MSC and NET89b/Start2 basic PASS; post-USB ping4/4, strict DHCP/DNS, nativeSafe36/QMP0/readback. Exact evidence: docs/nt4-candidate03-desktop-evidence.md. No full IRQ route, browser, X470 or combined fresh AUTO claim. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows Server 2003\Windows Server 2003 R2 Enterprise SP2 PL VL (CD1).iso | 5.2.3790.3959 / SP2 | pl-PL / x86 | windows-server-2003 / w2k3-x86-sp2-uefi-csm | QEMU nieukończono | weryfikacja pakietu źródła | brak identyfikacji przez sam parser optyczny; USOS odrzucił pakiet sterowników przygotowany dla innego ISO. Nie poluzowano kontroli; osobny pakiet dokładnego PL źródła gotowy do R12. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows Server 2003\Windows Server 2003 R2 Enterprise SP2 PL VL (CD2).iso | nie odczytano wersji binarnej | nie odczytano / unknown | windows-server-2003 / w2k3-x86-sp2-uefi-csm | nie uruchomiono | wejście dodatkowych składników R2 | brak identyfikacji przez sam parser optyczny; CD2 zawiera R2AUTO.EXE, CMPNENTS i WIN52IA.R2; brak TXTSETUP.SIF i install.wim. To dodatek R2 do już zainstalowanego Servera 2003 z CD1, nie samodzielny instalator do pulpitu. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows Server 2008 R2\Windows Server 2008 R2 SP1 VL (Standard-Enterprise-Datacenter-Web) PL x64.iso | 6.1.7601 / SP1 | pl-PL / x64 | windows-server-2008-r2 / win7-uefi-native | oczekuje | — | Windows Server 2008 R2 | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows Server 2008\Windows Web Server 2008 SP2 (6002.18005) PL x64.iso | 6.0.6002 / SP2 | pl-PL / x64 | windows-server-2008 / vista-uefi-pe10 | oczekuje | — | Windows Server 2008 | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows Server 2008\Windows Web Server 2008 SP2 (6002.18005) PL x86.iso | 6.0.6002 / SP2 | pl-PL / x86 | windows-server-2008 / vista-uefi-pe10 | oczekuje | — | Windows Server 2008 | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows Server 2012 R2\Windows Storage Server 2012 R2 + Server 2012 R2 Foundation with Update (9600.17415) PL x64.iso | 6.3.9600 | pl-PL / x64 | windows-server-2012-r2 / win10-11-uefi-native | oczekuje | — | Windows Server 2012 R2 | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows Vista\Windows Vista SP2 PL x64.iso | 6.0.6002 / SP2 | pl-PL / x64 | windows-vista / vista-uefi-pe10 | oczekuje | — | Windows Vista | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows Vista\Windows Vista SP2 PL x86.iso | 6.0.6002 / SP2 | pl-PL / x86 | windows-vista / vista-uefi-pe10 | oczekuje | — | Windows Vista | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows XP Media Center\Windows XP Media Center Edition 2005 SP3.iso | 5.1.2600.5512 / SP3 | en-US / x86 | wymaga przypisania folderu katalogu | błąd adaptera testu | menu główne USOS | windows-xp-mce; QEMU zakończyło się po pierwszej klatce menu, przed wyborem systemu; brak wyniku instalacji. Kolejne próby zapisują kod wyjścia emulatora. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows XP Tablet PC\Windows XP Tablet PC Edition 2005 SP3 EN (updated).7z | 5.1.2600.5657 / SP3 | en-US / x86 | wymaga przypisania folderu katalogu | oczekuje | — | windows-xp; 1 obrazów wewnątrz archiwum | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows XP Tablet PC\Windows XP Tablet PC Edition 2005 SP3 EN (updated).iso | 5.1.2600.5657 / SP3 | en-US / x86 | wymaga przypisania folderu katalogu | błąd adaptera testu | planowanie docelowego dysku testowego | windows-xp; Dysk VM 8 GiB odrzucony przez rzeczywisty planer NT5 (minimum 10 GiB łącznie). Bez zapisu celu i startu Windows. Nowy domyślny cel: 32 GiB thin qcow2. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows XP x64\Windows XP Professional x64 SP2 EN VL.iso | 5.2.3790.3959 / SP2 | en-US / x64 | windows-xp-x64 / xp-x64-sp2-uefi-csm | błąd adaptera testu | planowanie docelowego dysku testowego | brak identyfikacji przez sam parser optyczny; Dysk VM 8 GiB odrzucony przez rzeczywisty planer NT5 (minimum 10 GiB łącznie). Bez zapisu celu i startu Windows. Nowy domyślny cel: 32 GiB thin qcow2. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows XP\Windows XP Professional SP2 PL.iso | 5.1.2600.2180 / SP2 | pl-PL / x86 | windows-xp / xp-x86-sp3-uefi-csm | QEMU FAIL | przygotowanie: walidacja pakietu | windows-xp; USOS: this driver set requires XP Professional SP3. Odrzucono oryginalny starszy nośnik przed zapisem targetu. To ograniczenie pakietu USOS, nie wynik startu kernela Windows. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows XP\Windows XP Professional SP3 EN.iso | 5.1.2600.5512 / SP3 | en-US / x86 | windows-xp / xp-x86-sp3-uefi-csm | błąd adaptera testu | niepotwierdzone przejście z przygotowania do Windows | windows-xp; Stary adapter osiągnął komunikat Windows XP will now install on its own, lecz nie potwierdził startu celu ani pierwszego logowania. Ochrona prywatnego Setupu prawidłowo odmówiła zapisu niezweryfikowanego ekranu. Ta próba działała na wersji sprzed poprawki 4d7077f6. Nie dowodzi usterki XP ani sterowników USB/LAN. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows XP\Windows XP Professional SP3 PL OEM (NiKKA 2014-04).iso | 5.1.2600.6419 / SP3 | pl-PL / x86 | windows-xp / xp-x86-sp3-uefi-csm | błąd adaptera testu | planowanie docelowego dysku testowego | windows-xp; Dysk VM 8 GiB odrzucony przez rzeczywisty planer NT5 (minimum 10 GiB łącznie). Bez zapisu celu i startu Windows. Nowy domyślny cel: 32 GiB thin qcow2. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows XP\Windows XP Professional SP3 PL.iso | 5.1.2600.5512 / SP3 | pl-PL / x86 | windows-xp / xp-x86-sp3-uefi-csm | oczekuje | — | windows-xp | X470 PASS: `docs/research/xp-package-language-2026-09-25.md:6`, `docs/research/xp-package-language-2026-09-25.md:15`, `docs/research/xp-first-boot-2026-09-25.md:3`; XP Professional SP3 PL, dokładny hash z tabeli źródeł |
| Windows for Workgroups 3.11\Windows for Workgroups 3.11 PL (1.44M floppies).7z | nie odczytano wersji binarnej | nie odczytano / unknown | windows-wfw-3-11 / w9x-uefi-csmwrap | nie uruchomiono | brak przepływu zestawu dyskietek | brak identyfikacji przez sam parser optyczny; 10 obrazów wewnątrz archiwum; dyskietki/archiwum: parser optyczny nie ma zastosowania; Archiwum zawiera zestaw IMG, bez ISO. Obecny backend DOS/Win16 wymaga ISO9660 i SETUP.EXE w katalogu głównym. Brakuje przepływu podmiany/scalania dyskietek; wynik pokrewnego ISO nie jest przenoszony. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows for Workgroups 3.11\Windows for Workgroups 3.11 PL.iso | nie odczytano wersji binarnej | nie odczytano / unknown | windows-wfw-3-11 / w9x-uefi-csmwrap | QEMU PASS | pulpit | brak identyfikacji przez sam parser optyczny; artifacts\coverage\vm\windows-wfw311-extended\result.json | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows\Windows 2000\Windows 2000 Professional SP0 EN x86.7z | 5.0.2195.1 / SP0 | en-US / x86 | windows-2000 / w2k-x86-sp4-uefi-csm | QEMU FAIL | przygotowanie: walidacja nośnika | windows-2000; 1 obrazów wewnątrz archiwum; NT5_SOURCE: Windows 2000 SP4 source is required. SP0–SP3 odrzucone przed zapisem targetu; nie jest to błąd uruchomienia Windows. Braki importów opisane osobno w driver-audit.json. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows\Windows 2000\Windows 2000 Professional SP1 EN x86.7z | 5.0.2195.1620 / SP1 | en-US / x86 | windows-2000 / w2k-x86-sp4-uefi-csm | QEMU FAIL | przygotowanie: walidacja nośnika | windows-2000; 1 obrazów wewnątrz archiwum; NT5_SOURCE: Windows 2000 SP4 source is required. SP0–SP3 odrzucone przed zapisem targetu; nie jest to błąd uruchomienia Windows. Braki importów opisane osobno w driver-audit.json. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows\Windows 2000\Windows 2000 Professional SP2 EN x86.7z | 5.0.2195.2951 / SP2 | en-US / x86 | windows-2000 / w2k-x86-sp4-uefi-csm | QEMU FAIL | przygotowanie: walidacja nośnika | windows-2000; 1 obrazów wewnątrz archiwum; NT5_SOURCE: Windows 2000 SP4 source is required. SP0–SP3 odrzucone przed zapisem targetu; nie jest to błąd uruchomienia Windows. Braki importów opisane osobno w driver-audit.json. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows\Windows 2000\Windows 2000 Professional SP3 EN x86.7z | 5.0.2195.5438 / SP3 | en-US / x86 | windows-2000 / w2k-x86-sp4-uefi-csm | QEMU FAIL | przygotowanie: walidacja nośnika | windows-2000; 1 obrazów wewnątrz archiwum; NT5_SOURCE: Windows 2000 SP4 source is required. SP0–SP3 odrzucone przed zapisem targetu; nie jest to błąd uruchomienia Windows. Braki importów opisane osobno w driver-audit.json. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows\Windows 7\Windows 7 Home Premium RTM PL x64.iso | 6.1.7600 / SP0 | pl-PL / x64 | windows-7 / win7-uefi-native | QEMU nieukończono | WIMBOOT / donor WinPE; dalszy ekran niepotwierdzony | Windows 7; Donor WinPE 10.0.17763 x64 uruchamiany przez normalny USOS. Brak sygnalu pierwszego logowania; target qcow2 tylko 393216 B alokacji. Adapter zakazal niezweryfikowanego przechwycenia ekranu z kluczem. Staly scenariusz klawiszy nie dowodzi stanu UI; nie przypisano bledu Windows ani klucza.; warianty: NVMe 25 GiB thin qcow2: FAIL (wybór dysku Setup); AHCI 25 GiB / PS/2 / TCG: INCOMPLETE (graficzny Setup); AHCI 25 GiB / PS/2 / WHPX: INCOMPLETE (próba przerwana po wykryciu problemu emulatora); QEMU TCG AHCI 8 GiB, PS/2, fixed input: INCOMPLETE (WIMBOOT / donor WinPE; dalszy ekran niepotwierdzony) | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows\Windows 7\Windows 7 Home Premium RTM PL x86.iso | 6.1.7600 / SP0 | pl-PL / x86 | windows-7 / win7-uefi-native | oczekuje | — | Windows 7 | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows\Windows 95\Windows 95 OSR1 EN OEM x86.7z | 4.0.0.950 | nie odczytano / unknown | windows-95 / w9x-uefi-csmwrap | oczekuje | — | brak identyfikacji przez sam parser optyczny; 1 obrazów wewnątrz archiwum | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows\Windows 95\Windows 95 OSR2 EN OEM x86.7z | 4.0.0.1068 | nie odczytano / unknown | windows-95 / w9x-uefi-csmwrap | oczekuje | — | brak identyfikacji przez sam parser optyczny; 1 obrazów wewnątrz archiwum | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows\Windows 95\Windows 95 OSR2.5 EN OEM x86.7z | 4.0.0.1068 | nie odczytano / unknown | windows-95 / w9x-uefi-csmwrap | oczekuje | — | brak identyfikacji przez sam parser optyczny; 1 obrazów wewnątrz archiwum | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows\Windows 95\Windows 95 RTM PL OEM x86.7z | 4.0.0.950 | nie odczytano / unknown | windows-95 / w9x-uefi-csmwrap | oczekuje | — | brak identyfikacji przez sam parser optyczny; 1 obrazów wewnątrz archiwum | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows\Windows 98 SE\Windows 98 FE to SE Update EN x86.7z | 4.10.0.2222 | nie odczytano / unknown | windows-98-se / w9x-uefi-csmwrap | oczekuje | — | brak identyfikacji przez sam parser optyczny; 1 obrazów wewnątrz archiwum | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows\Windows 98 SE\Windows 98 SE EN OEM Full x86.7z | 4.10.0.2222 | nie odczytano / unknown | windows-98-se / w9x-uefi-csmwrap | oczekuje | — | brak identyfikacji przez sam parser optyczny; 1 obrazów wewnątrz archiwum | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows\Windows 98 SE\Windows 98 SE EN Retail Upgrade x86.7z | 4.10.0.2222 | nie odczytano / unknown | windows-98-se / w9x-uefi-csmwrap | oczekuje | — | brak identyfikacji przez sam parser optyczny; 1 obrazów wewnątrz archiwum | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows\Windows 98\Windows 98 FE EN OEM Full x86.7z | 4.10.0.1998 | nie odczytano / unknown | windows-98 / w9x-uefi-csmwrap | oczekuje | — | brak identyfikacji przez sam parser optyczny; 1 obrazów wewnątrz archiwum | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows\Windows NT 3.5 Server\Windows NT 3.5 Server EN x86.7z | 3.50.800.1 | en-US / x86 | windows-nt-3-5-server / nt3-x86-qemu-csmwrap | oczekuje | — | brak identyfikacji przez sam parser optyczny; 1 obrazów wewnątrz archiwum | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows\Windows NT 4.0 Embedded\Windows NT 4.0 Embedded EN x86.7z | nie odczytano wersji binarnej | nie odczytano / unknown | wymaga przypisania folderu katalogu | oczekuje | — | brak identyfikacji przez sam parser optyczny; 1 obrazów wewnątrz archiwum | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows\Windows NT 4.0 Server\Windows NT 4.0 Server EN x86.7z | 4.0.1381.1 | en-US / x86 | windows-nt-4-server / nt4-x86-qemu-csmwrap | oczekuje | — | brak identyfikacji przez sam parser optyczny; 1 obrazów wewnątrz archiwum | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows\Windows Vista\Windows Vista Business SP1 EN x86.iso | 6.0.6001 / SP1 | en-US / x86 | windows-vista / vista-uefi-pe10 | oczekuje | — | Windows Vista | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows\Windows Vista\Windows Vista RTM EN x64.iso | 6.0.6000 / SP0 | en-US / x64 | windows-vista / vista-uefi-pe10 | oczekuje | — | Windows Vista | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows\Windows Vista\Windows Vista RTM EN x86.iso | 6.0.6000 / SP0 | en-US / x86 | windows-vista / vista-uefi-pe10 | oczekuje | — | Windows Vista | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows\Windows XP\Windows XP Home RTM PL x86.iso | 5.1.2600.0 / SP0 | pl-PL / x86 | windows-xp / xp-x86-sp3-uefi-csm | QEMU FAIL | przygotowanie: walidacja pakietu | windows-xp; USOS: this driver set requires XP Professional SP3. Odrzucono oryginalny starszy nośnik przed zapisem targetu. To ograniczenie pakietu USOS, nie wynik startu kernela Windows. | nie przypisano potwierdzenia dla dokładnego obrazu |
| Windows\Windows XP\Windows XP Professional SP1 EN x86.iso | 5.1.2600.1106 / SP1 | en-US / x86 | windows-xp / xp-x86-sp3-uefi-csm | QEMU FAIL | przygotowanie: walidacja pakietu | windows-xp; USOS: this driver set requires XP Professional SP3. Odrzucono oryginalny starszy nośnik przed zapisem targetu. To ograniczenie pakietu USOS, nie wynik startu kernela Windows. | nie przypisano potwierdzenia dla dokładnego obrazu |

## Etapy i zakres dowodu

Etapy: wykrywanie → menu → przygotowanie → micro-Linux → kopiowanie → tekstowy Setup → graficzny Setup → pierwszy start → pulpit. PASS jest zarezerwowany dla pierwszego pulpitu. Zgodność eksportów nie dowodzi ABI ani działania sterownika. QEMU nie zastępuje testu X470.

Wykonano audyt oryginalnych modułów dla 13 źródeł NT5: XP RTM/SP1 mają brakujące eksporty; badany XP SP2 oraz kontrolne SP3 nie mają braków symboli w badanym zestawie, ale nadal obowiązuje kontrakt pakietu przygotowanego pod SP3. Windows 2000 SP0–SP3 nie mają wymaganych dwóch eksportów USBPORT dla xhci98; kontrolne SP4 mają komplet. Dokładne symbole i opcje napraw znajdą się w raporcie końcowym.

Pełne dane wejść i wyników: `artifacts/coverage/inventory-fourth.json`, `artifacts/coverage/media-fourth.json`, `driver-audit.json`. Surowe bajty Microsoftu nie są elementem tej dokumentacji ani zmian Git.

## Reprezentanci do X470

Lista jest uzupełniana po przeglądzie końcowego pulpitu. Pokrewne wersje tej samej rodziny nie uzyskują PASS automatycznie.

- Windows 1.01 EN.iso: Najstarszy Win16, pulpit MS-DOS Executive w QEMU. UEFI → CSMWrap; pusty dysk NVMe lub SATA; sprawdzić start, klawiaturę/mysz i ponowny start. SHA-256 `749c3bdaaf86f46801f262301fe293888b92635034fdded0fda0c3e24553a1a8`.
- Windows 3.11 OEM EN.iso: Win16 w trybie standardowym, Program Manager w QEMU. UEFI → CSMWrap; pusty dysk NVMe lub SATA; sprawdzić start, klawiaturę/mysz i ponowny start. SHA-256 `2aece91081b8c46136c059765954ec1066631a1823c0b3adcf57c2d6d68d5f44`.

## Inwentaryzacja i SHA-256

### `Citrix WinFrame\Citrix WinFrame 1.8 (ISO + Tools ISO + boot disks).7z`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 355049183 B; SHA-256 `d3543da5f1f740abc09bffbeffcaef401b466f4dd3d45af39fa4b222b1a65394`.

Źródła metadanych: `i386/txtsetup.sif`.

- `WinFrame1.8.iso`: 304781312 B; SHA-256 `e8d60ea5e73b6e47fd3cd38b48b5e559f3694ba9ceceda65ef3024ac4fbc9806`.
- `WinFrame1.8_Tools.iso`: 510586880 B; SHA-256 `a58d2d37362cbbb8875c5e1d1589fb6e30447f31c0642a13f0fc944093c6f34b`.
- `BOOT_FLOPPIES\setupbootdisk1.img`: 1474560 B; SHA-256 `53637751e91a3e5fa010c9f80edb18fd57be6245d8fe56c8f6149655feb35096`.
- `BOOT_FLOPPIES\setupbootdisk2.img`: 1474560 B; SHA-256 `6e6d8d6650c54514b6a800380e535ec4e7f3e421256974335481e0f1e3d33c2e`.
- `BOOT_FLOPPIES\setupbootdisk3.img`: 1474560 B; SHA-256 `c056e529de0bd88220c0e6d95448f95859a076534e75c0895ec1cf86e7dfca7f`.

### `Windows 1.01\Windows 1.01 EN (5.25 floppies).7z`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 541382 B; SHA-256 `483b7aa0eb35d9de73c4d9e52385291eb332a16f65b929ee66f55211920ab516`.

Źródła metadanych: brak standardowych małych plików metadanych.

- `Microsoft Windows 1.01 (5.25)\DISK1-SETUP.IMG`: 368640 B; SHA-256 `e359f958bb90a97213e2cb5de63be978deca312c0f69665497c1267056c7b8e6`.
- `Microsoft Windows 1.01 (5.25)\DISK2-BUILD.IMG`: 368640 B; SHA-256 `c27d869a948de6cf903a21e1a1292f09e6c77ce28d754df15de2019135915571`.
- `Microsoft Windows 1.01 (5.25)\DISK3-UTILITY.IMG`: 368640 B; SHA-256 `7aed3a1e53ba7367f010f4c192a6258792190f5462a52c0f1d69370374b1e4ed`.
- `Microsoft Windows 1.01 (5.25)\DISK4-APPS.IMG`: 368640 B; SHA-256 `81f7569dd97095a97af38a58c4941819071670586c89d860bf2509eaad48f7c3`.
- `Microsoft Windows 1.01 (5.25)\DISK5-WRITE.IMG`: 368640 B; SHA-256 `0d3d20248bac6a7ad328dca9af04bea942f5c5357d081cc2ef840f789f8a9559`.

### `Windows 1.01\Windows 1.01 EN.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 1720320 B; SHA-256 `749c3bdaaf86f46801f262301fe293888b92635034fdded0fda0c3e24553a1a8`.

Źródła metadanych: `setup.exe`.

### `Windows 1.04\Windows 1.04 EN (5.25 floppies).7z`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 681371 B; SHA-256 `9758b1c9df887a186c9d7314ea72b5c23415a780f0c1ac385c741d8c81988a9a`.

Źródła metadanych: brak standardowych małych plików metadanych.

- `Microsoft Windows 1.04 (5.25)\D1_Setup.img`: 368640 B; SHA-256 `cb1a306a4d4c4de94fcc44e2d41198e7346df23f756e5025e2f57051695173f6`.
- `Microsoft Windows 1.04 (5.25)\D2_Build.img`: 368640 B; SHA-256 `f1f5f0b81c400b713c96bf8fe5c2bd13ce2cd2d20752a86b2634c483876d1510`.
- `Microsoft Windows 1.04 (5.25)\D3_Utility.img`: 368640 B; SHA-256 `5552ca3420ef2454154e3286e74fd0a826b5635603e2087fefd076cda7f9ebee`.
- `Microsoft Windows 1.04 (5.25)\D4_Font.img`: 368640 B; SHA-256 `b24964fc896fa8cb27dc8be1c0d087886c1ab15ae95624891df2cb21fcf6688d`.
- `Microsoft Windows 1.04 (5.25)\D5_Apps.img`: 368640 B; SHA-256 `f2aca6f6c1526b19a14ef3d592590ffb1123ffe7f453785db66dfbd3bf1184c0`.
- `Microsoft Windows 1.04 (5.25)\D6_Write.img`: 368640 B; SHA-256 `5ff49e2ddc625a8abb444c6cd28f0622ac86a8b20c6886f5f8df60a5ffee4c11`.
- `Microsoft Windows 1.04 (5.25)\D7_Spdisk.img`: 368640 B; SHA-256 `57eeed4f6dd9ea9af1ad257a3f57f1b2c931136980bca4b23e7ffb8e4bfe75e2`.

### `Windows 1.04\Windows 1.04 EN.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 2318336 B; SHA-256 `4fd802923c1bced25ec28d65c6ee4db73ac4f9ba6350e51ddb07034492aff763`.

Źródła metadanych: `setup.exe`.

### `Windows 10\Windows 10 22H2 19045.6396 PL x86.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 4467318784 B; SHA-256 `d45968dae085e7a28e6531b528b28810e2d8423d581b2629edb1e29367823d7a`.

Źródła metadanych: `setup.exe`, `sources/boot.wim`, `sources/idwbinfo.txt`, `sources/install.wim`, `sources/lang.ini`, `sources/setup.exe`.

### `Windows 11\Windows 11 25H2 PL x64.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 8345856000 B; SHA-256 `9453d410298e50c36ce31153326857848256e0980ff8fda501b4d3817540beb9`.

Źródła metadanych: `setup.exe`, `sources/boot.wim`, `sources/idwbinfo.txt`, `sources/install.wim`, `sources/lang.ini`, `sources/setup.exe`.

### `Windows 2.03\Windows 2.03 EN (720K floppies).7z`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 3520453 B; SHA-256 `04a912e6b1f321004160d4898425c5b661d42d780985c0d84093c689b86e6bd5`.

Źródła metadanych: brak standardowych małych plików metadanych.

- `Microsoft Windows 2.03 (3.5-720k)\disk1.img`: 737280 B; SHA-256 `7dcfc9c2933fa808306b34ab6ec6c0de46ec1e485994a767a3ab1b706cc4b692`.
- `Microsoft Windows 2.03 (3.5-720k)\disk2.img`: 737280 B; SHA-256 `f5a0f17c126e5742cd93d9173e52b092ba07eb6347cb4eb1f99f0223b4c755a3`.
- `Microsoft Windows 2.03 (3.5-720k)\disk3.img`: 737280 B; SHA-256 `8da41ec7546921d5ef48c617ab454919f4ed0c74ebefd91278ffe7e95f2bc812`.
- `Microsoft Windows 2.03 (3.5-720k)\disk4.img`: 737280 B; SHA-256 `4f61d16e4f19fec9d2fc47329c16c389feb3c07c63d2af2c234d11c441ecf7a6`.
- `Microsoft Windows 2.03 (3.5-720k)\disk5.img`: 737280 B; SHA-256 `0e45deea26b4c98fccee58220ed955c6e33edb89531c094ac9936eb60debf072`.

### `Windows 2.03\Windows 2.03 EN.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 3256320 B; SHA-256 `b28615b1c6c2498d1c3c1d718fe7bdf1fbdf31368f76ea560571b55bcd600fae`.

Źródła metadanych: `setup.exe`.

### `Windows 2.11 (286)\Windows 2.11 286 EN (720K floppies).7z`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 1183155 B; SHA-256 `b682783faac6daeb468b2c9db07ec24371cfb9eb73836a2f542742b9dbbbc5a0`.

Źródła metadanych: brak standardowych małych plików metadanych.

- `Microsoft Windows 2.11 (286) (3.5-720k)\disk01.img`: 737280 B; SHA-256 `9315d73415749d5d53163856efcbd9bb5b67130c53e4d2efb6d263d97e429947`.
- `Microsoft Windows 2.11 (286) (3.5-720k)\disk02.img`: 737280 B; SHA-256 `2b529ee24c2f69a929da322330bd9ebdd90d811404c1db9e6c73b26189663317`.
- `Microsoft Windows 2.11 (286) (3.5-720k)\disk03.img`: 737280 B; SHA-256 `76f22cd9a0e8f7ed7cf2b5767c0e87f9b3156417ed7f2727ff846604ef29a2b1`.
- `Microsoft Windows 2.11 (286) (3.5-720k)\disk04.img`: 737280 B; SHA-256 `128497fa98e55d9e1bfe3bfef534029c0681856b9d543610a087e9fc9f9fc7a7`.
- `Microsoft Windows 2.11 (286) (3.5-720k)\disk05.img`: 737280 B; SHA-256 `ac31a6ebe75a723efafb6a47fbe741afc1a409165e2d2f0d8985245c7f5e6b20`.
- `Microsoft Windows 2.11 (286) (3.5-720k)\disk06.img`: 737280 B; SHA-256 `d50f7e3cb991d463f5cf08f5ffcbbd1aa27c253bfec78498139e430e74245612`.
- `Microsoft Windows 2.11 (286) (3.5-720k)\disk07.img`: 737280 B; SHA-256 `a450719c19c370d046a64049c98033942710bdf677d31cd0ed9aa2adb24e5dcb`.

### `Windows 2.11 (286)\Windows 2.11 286 EN.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 4968448 B; SHA-256 `77fd50dad9839a220fbd2379501e7d77317992ffbfe60d82d97c885c3d1e7a3b`.

Źródła metadanych: `setup.exe`.

### `Windows 2.11 (386)\Windows 2.11 386 EN (3.5 floppies).7z`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 3442572 B; SHA-256 `ba798a9c4662a189c2df975c2a9fe95291a561c009b55c5b8f9f6a7f7e63ff29`.

Źródła metadanych: brak standardowych małych plików metadanych.

- `Microsoft Windows 2.11 (386) (3.5)\Additional Drivers.img`: 737280 B; SHA-256 `b7ebf9e903923348f2cb8808585a4843d6bbf1ed6e43fd2643ad765ab5a269d4`.
- `Microsoft Windows 2.11 (386) (3.5)\Desktop Applications Write.img`: 737280 B; SHA-256 `5ce9d07edacdb6d2e5baa2a8db21ed3080e42586c3944d3830fc73bf01e44f2e`.
- `Microsoft Windows 2.11 (386) (3.5)\Displays.img`: 737280 B; SHA-256 `b81fb7377a5f33abb305ca27921c1c93c9a7033ab4971cb89aef417d038f7c9f`.
- `Microsoft Windows 2.11 (386) (3.5)\Fonts.img`: 737280 B; SHA-256 `ee14852ecb406eb210fc62b6d18821af8d2008eeea5d82e9b614df4dc43d06d5`.
- `Microsoft Windows 2.11 (386) (3.5)\Setup.img`: 737280 B; SHA-256 `4879b5cb7735fdf4e15828d4cb413276e2517fdf92bf916befd2dd2f80802604`.
- `Microsoft Windows 2.11 (386) (3.5)\Utilities 1.img`: 737280 B; SHA-256 `0f23256122bbcc4e55bb96322655d42f096e64d6f3dcbd86ebbef47592e54332`.
- `Microsoft Windows 2.11 (386) (3.5)\Utilities 2.img`: 737280 B; SHA-256 `5fb519e7e5ef4a45a82d0d85eb56eaeb113d2de5bf8f5289504d4e7bd176a99f`.

### `Windows 2.11 (386)\Windows 2.11 386 EN.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 4943872 B; SHA-256 `6b851bcfe808ea88b03953cdfb8158da6bb92042d8364a4ccf23fbed77316d08`.

Źródła metadanych: `setup.exe`.

### `Windows 2000 Server\Windows 2000 Server PL.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 434096128 B; SHA-256 `4f0ba26c24011c89a7e15fc5477813aaba4a75c8350b79a7f384dc9437e5a8ed`.

Źródła metadanych: `i386/prodspec.ini`, `i386/setupp.ini`, `i386/txtsetup.sif`, `setup.exe`.

### `Windows 2000 Server\Windows 2000 Server SP4 PL.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 445382656 B; SHA-256 `adc6cb80d858fb6cdbfa5dfeebb2d26d74f59d318f36f94f1814fa05b591a941`.

Źródła metadanych: `i386/prodspec.ini`, `i386/setupp.ini`, `i386/txtsetup.sif`, `setup.exe`.

### `Windows 2000\W2KPLCMA4.811.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 734576640 B; SHA-256 `ae0940f2189c496fc527cb58e7fac102eb97619fca84c866249cf7b3315cde76`.

Źródła metadanych: `i386/prodspec.ini`, `i386/setupp.ini`, `i386/txtsetup.sif`, `setup.exe`.

### `Windows 2000\W2KPLCMA6.7.15.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 783843328 B; SHA-256 `0b993077f9bdaa287eafea5e152b62fd3bf896e7cc7ccb04ce905b520d68089d`.

Źródła metadanych: `i386/prodspec.ini`, `i386/setupp.ini`, `i386/txtsetup.sif`, `setup.exe`.

### `Windows 3.0\Windows 3.0a EN (720K floppies).7z`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 3951521 B; SHA-256 `1d5386761a160ff98731cc7dc60e0e6c4aaeedd59043a74d28d2b25ad471ce49`.

Źródła metadanych: brak standardowych małych plików metadanych.

- `Microsoft Windows 3.0a (3.5 720K)\DISK01.IMG`: 737280 B; SHA-256 `742fac3fa592760fadf49af1b724bf24d4c2b4ae3b9d8c902d1421e668de8dae`.
- `Microsoft Windows 3.0a (3.5 720K)\DISK02.IMG`: 737280 B; SHA-256 `b1d3d1c7d634ed1544857044a6e48e7ca3c32f6dc4507fae0b600fd28d6b9bd3`.
- `Microsoft Windows 3.0a (3.5 720K)\DISK03.IMG`: 737280 B; SHA-256 `75061195b75e760e7c03f2209540ac140889eef321ae9ba7c3375c4758c9a34a`.
- `Microsoft Windows 3.0a (3.5 720K)\DISK04.IMG`: 737280 B; SHA-256 `137a9c702769404d6046de7324c728f0bf9713c8e8907e8c2c02ce2b15e0daca`.
- `Microsoft Windows 3.0a (3.5 720K)\DISK05.IMG`: 737280 B; SHA-256 `5b35ef680d268ab666ed9364bfa16d5cc113d87f89617afcb5a2b5bba16b5d7f`.
- `Microsoft Windows 3.0a (3.5 720K)\DISK06.IMG`: 737280 B; SHA-256 `631d8cee52f442ea4ec7317f6613b7eefdd4b3c5b68d0ae4b27792656e510674`.
- `Microsoft Windows 3.0a (3.5 720K)\DISK07.IMG`: 737280 B; SHA-256 `f583dc1ba593eae03adaf57ef90bb497f4684d86f43ce337132ba46d97eaee79`.

### `Windows 3.0\Windows 3.0a EN.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 5306368 B; SHA-256 `6431b5871b14374ba5431c5d325fd90f6398ec1aa8dbda65f107108157cb5a43`.

Źródła metadanych: `setup.exe`.

### `Windows 3.11\Windows 3.11 OEM EN (1.44M floppies).zip`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 7451468 B; SHA-256 `89cff2545dd71e5833c6a5aca8031059d34bd5ad0f03f2c51ac36841dcd0fbec`.

Źródła metadanych: brak standardowych małych plików metadanych.

- `Microsoft Windows 3.11 (OEM) (3.5)\DISK6.IMG`: 1474560 B; SHA-256 `002687e07bd400bee31d56a89d9d67e46b075a3717aa8431cc7aaf4df7e17679`.
- `__MACOSX\Microsoft Windows 3.11 (OEM) (3.5)\._DISK6.IMG`: 187 B; SHA-256 `da02fd02456b473f6aafd9eb5335c14263d65275dad767b7e97159b14c16dd0f`.
- `Microsoft Windows 3.11 (OEM) (3.5)\DISK4.IMG`: 1474560 B; SHA-256 `6856aa255c09cdc063354c0d91e56085e3873b3d1e1f8acac78dace4d37b1e08`.
- `__MACOSX\Microsoft Windows 3.11 (OEM) (3.5)\._DISK4.IMG`: 187 B; SHA-256 `d0ee4379e7b1e50697e6cb7421fa5494f8d50bf85eee5c09c8962e9f4eca77e0`.
- `Microsoft Windows 3.11 (OEM) (3.5)\DISK5.IMG`: 1474560 B; SHA-256 `d2bf5ff1a998aa3256d9daff4f768778b4fe650bbf325dd2a351519d982d9418`.
- `__MACOSX\Microsoft Windows 3.11 (OEM) (3.5)\._DISK5.IMG`: 187 B; SHA-256 `da02fd02456b473f6aafd9eb5335c14263d65275dad767b7e97159b14c16dd0f`.
- `Microsoft Windows 3.11 (OEM) (3.5)\DISK1.IMG`: 1474560 B; SHA-256 `fc95bf607a31b407dd9fed091b5f3a822ef6ab4a2bb3d9dbfa726d435d8a9653`.
- `__MACOSX\Microsoft Windows 3.11 (OEM) (3.5)\._DISK1.IMG`: 187 B; SHA-256 `d0ee4379e7b1e50697e6cb7421fa5494f8d50bf85eee5c09c8962e9f4eca77e0`.
- `Microsoft Windows 3.11 (OEM) (3.5)\DISK2.IMG`: 1474560 B; SHA-256 `cf47a27973dc0004a3120f48e844a42e0b75f1ca14bf037daa792d6aa93ca307`.
- `__MACOSX\Microsoft Windows 3.11 (OEM) (3.5)\._DISK2.IMG`: 187 B; SHA-256 `d0ee4379e7b1e50697e6cb7421fa5494f8d50bf85eee5c09c8962e9f4eca77e0`.
- `Microsoft Windows 3.11 (OEM) (3.5)\DISK3.IMG`: 1474560 B; SHA-256 `b1ee47084145c9755710aff49fe116e6221e77384d42c9ba7dbabba63d4e2a9b`.
- `__MACOSX\Microsoft Windows 3.11 (OEM) (3.5)\._DISK3.IMG`: 187 B; SHA-256 `d0ee4379e7b1e50697e6cb7421fa5494f8d50bf85eee5c09c8962e9f4eca77e0`.

### `Windows 3.11\Windows 3.11 OEM EN.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 8435712 B; SHA-256 `2aece91081b8c46136c059765954ec1066631a1823c0b3adcf57c2d6d68d5f44`.

Źródła metadanych: `setup.exe`.

### `Windows 3.1\Windows 3.1 PL.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 13041664 B; SHA-256 `3b55aae78de23fab4ed530268083050f557b673c6c69af8ea90632eba549ccd6`.

Źródła metadanych: `setup.exe`.

### `Windows 7\Windows 7 Professional SP1 PL x64.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 3199123456 B; SHA-256 `0e6935f530bb13d9cfc6bc53b0ebb97209c9a0693fa864df14cb28982bbf3256`.

Źródła metadanych: `setup.exe`, `sources/boot.wim`, `sources/idwbinfo.txt`, `sources/install.wim`, `sources/lang.ini`, `sources/setup.exe`.

### `Windows 7\Windows 7 SP1 6in1 PL x64 (2019-07).iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 3356327936 B; SHA-256 `54fd3e5429fa85426e00855f764a09b36e7819f44c611f27ec5d2afc9ef4c3e0`.

Źródła metadanych: `setup.exe`, `sources/boot.wim`, `sources/idwbinfo.txt`, `sources/install.esd`, `sources/lang.ini`, `sources/setup.exe`.

### `Windows 7\Windows 7 Ultimate SP1 PL x64.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 3199123456 B; SHA-256 `5aa163dcbbf9889faf96a39cd567da84860f991ddeb0883635bc3e81aebb2aa2`.

Źródła metadanych: `setup.exe`, `sources/boot.wim`, `sources/idwbinfo.txt`, `sources/install.wim`, `sources/lang.ini`, `sources/setup.exe`.

### `Windows 7\Windows 7 Ultimate SP1 PL x86.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 2440128512 B; SHA-256 `709d041ac53f57d44b5451a757491b9e730feac8b807cf0ace625aadde7e4675`.

Źródła metadanych: `setup.exe`, `sources/boot.wim`, `sources/idwbinfo.txt`, `sources/install.wim`, `sources/lang.ini`, `sources/setup.exe`.

### `Windows 95\Windows 95 OSR2 Boot Disk.img`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 1474560 B; SHA-256 `f93f1d1e168850e92d115138c7fda380dd6e80a69c07a8adb903526304ae25c0`.

Źródła metadanych: brak standardowych małych plików metadanych.

### `Windows 95\Windows 95 OSR2.1 PL.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 602447872 B; SHA-256 `0b58c633cebe231705152126ae948608df2f2220df692b47efe4bf39ccd2d2fb`.

Źródła metadanych: `setup.exe`.

### `Windows 98 SE\Windows 98 SE PL OEM.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 588881920 B; SHA-256 `9d3e466c08957d0a13939c69ecdfc17311691318e03749e52558aee4f20d0e8e`.

Źródła metadanych: `setup.exe`.

### `Windows 98\Windows 98 PL.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 573321216 B; SHA-256 `4194dc762d18db238ea0125e239325d94b4784615dd79891ab75d1e3301b8649`.

Źródła metadanych: `setup.exe`.

### `Windows Embedded 8.1 Industry\Windows Embedded 8.1 Industry Pro (9600.16384) PL x64.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 3702468608 B; SHA-256 `e71f2da3ea8f7bcc7d6a2674fdb9662855c5d2c6311b733795fdc0de7a91f1c1`.

Źródła metadanych: `setup.exe`, `sources/boot.wim`, `sources/idwbinfo.txt`, `sources/install.wim`, `sources/lang.ini`, `sources/setup.exe`.

### `Windows Embedded 8.1 Industry\Windows Embedded 8.1 Industry Pro (9600.16384) PL x86.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 2718973952 B; SHA-256 `aab5d3333aec12fe3214b96d0f931b7a98907011c10d6d820c55b883aa705d37`.

Źródła metadanych: `setup.exe`, `sources/boot.wim`, `sources/idwbinfo.txt`, `sources/install.wim`, `sources/lang.ini`, `sources/setup.exe`.

### `Windows Embedded POSReady 2009\Windows Embedded POSReady 2009 (XP SP3) EN.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 678625280 B; SHA-256 `92b3096dc628e0f234b4099b5aa721c6eb20a428fdf84fe604b157f7cb4d82cd`.

Źródła metadanych: `i386/txtsetup.sif`.

### `Windows Embedded POSReady 7\Windows Embedded POSReady 7 EVAL EN x64.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 4361910272 B; SHA-256 `3f3867d32390dad064ab7067c852da4301b85c6731eb9ed2139eb0dd8d883373`.

Źródła metadanych: `setup.exe`, `sources/boot.wim`, `sources/idwbinfo.txt`, `sources/install.wim`, `sources/lang.ini`, `sources/setup.exe`.

### `Windows Embedded Standard 7\Windows Embedded Standard 7 SP1 IBW EN x86.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 2992934912 B; SHA-256 `befb9372bb6b71e0e062c2a3e3c1a12a45b113c0be1b4a6c1c0122e48e4cd1b0`.

Źródła metadanych: `setup.exe`, `sources/boot.wim`, `sources/idwbinfo.txt`, `sources/install.wim`, `sources/lang.ini`, `sources/setup.exe`.

### `Windows Embedded Standard 7\Windows Embedded Standard 7 SP1 Runtime EN x64.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 3625994240 B; SHA-256 `a371d165c6f6e6012ba6f01942abb252e613fad454557fc32e48f0130e0934ec`.

Źródła metadanych: `setup.exe`, `sources/boot.wim`, `sources/idwbinfo.txt`, `sources/install.wim`, `sources/lang.ini`, `sources/setup.exe`.

### `Windows Fundamentals for Legacy PCs\Windows Fundamentals for Legacy PCs EN.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 603553792 B; SHA-256 `18044df2273b8d98c82fafb352f097287eb591c33a103e14927b7efb7fd5d31a`.

Źródła metadanych: `i386/txtsetup.sif`, `setup/wim/winflp.wim`.

### `Windows Home Server 2011\Windows Home Server 2011 (7601.17514) EN x64.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 4305752064 B; SHA-256 `66b1b7b590e53dc3e63dcdd72dce493d26d92c51124662b504967d763683ae7b`.

Źródła metadanych: `setup.exe`, `sources/install.wim`, `sources/boot.wim`, `sources/idwbinfo.txt`, `sources/lang.ini`, `sources/setup.exe`.

### `Windows ME\Windows ME PL OEM.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 383778816 B; SHA-256 `f0a46fef5ca9ba1e8fb2ae14684d7dc84680659a1ae4f05759c24b4fbdbb5bc2`.

Źródła metadanych: `setup.exe`.

### `Windows NT 3.1 Advanced Server\Windows NT 3.1 Advanced Server 3.10.511.1 EN (ISO + boot disks).7z`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 65583004 B; SHA-256 `53f716f3a006d4bce78df4653f875f9aaa64822d20d6798cfdd0db18c9c06721`.

Źródła metadanych: brak standardowych małych plików metadanych.

- `Microsoft Windows NT 3.1 Advanced Server (3.10.511.1) (ISO)\Boot Disks\Bootdisk (3.5).img`: 1474560 B; SHA-256 `3d323262e7b9a98a0c79c5a6a1601edf0202bffceee37d7acecaf549d7c46f08`.
- `Microsoft Windows NT 3.1 Advanced Server (3.10.511.1) (ISO)\Boot Disks\Bootdisk (5.25).img`: 1228800 B; SHA-256 `cd51d17c5c00e42b776e691968a9f6283f9679fc6f233a937a3d538ed4eb11ac`.
- `Microsoft Windows NT 3.1 Advanced Server (3.10.511.1) (ISO)\WinNT 3.10 Server (1079000).iso`: 165509120 B; SHA-256 `940dcefd46e1fbeebf27b2bc1befcbd75867e4cd41cf639e36c116b371684d1b`.

### `Windows NT 3.1\Windows NT 3.1 Workstation 3.10.511.1 EN (ISO).7z`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 50906586 B; SHA-256 `d10f9c35bf656e2cca7351518628ba19179540af1b090d61d322b670930b2894`.

Źródła metadanych: brak standardowych małych plików metadanych.

- `Microsoft Windows NT 3.1 Workstation (3.10.511.1) (ISO)\Disk01.iso`: 158769152 B; SHA-256 `ee2a27153c0942b6b82f9b15145f3b7eaa34b331add1d077cc6f8d69b9223c0b`.

### `Windows NT 3.51 Server\Windows NT 3.51 Server 3.51.1057.1 EN (ISO + boot disks).7z`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 177219952 B; SHA-256 `caa4aea1c97500aaee99dfda7ebb748562d8e612e2bb87ea9fe4879b9ad34f43`.

Źródła metadanych: `i386/txtsetup.sif`.

- `Microsoft Windows NT 3.51 Server (3.51.1057.1) (ISO)\SetupBootDisk.img`: 1474560 B; SHA-256 `9ec3d8052482445efc5959409c3835d94a9e4170cbe8c12274c197d688993c0e`.
- `Microsoft Windows NT 3.51 Server (3.51.1057.1) (ISO)\SetupDisk2.img`: 1474560 B; SHA-256 `570b49582df7d50637c7fb38d86e221f2f24b6a2920e999335d66bc0be9e251f`.
- `Microsoft Windows NT 3.51 Server (3.51.1057.1) (ISO)\SetupDisk3.img`: 1474560 B; SHA-256 `6ef0c21df08b7ac1f94608237289307d7e2c744f474ae71ef88a4e60ebe0d2e7`.
- `Microsoft Windows NT 3.51 Server (3.51.1057.1) (ISO)\CD-ROM.iso`: 351207424 B; SHA-256 `bc9e2d532f3f13c062a412b196eed72118ebd15b09fda6ffbea148d828b044c7`.

### `Windows NT 3.51\Windows NT 3.51 SP5 EN.7z`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 8328165 B; SHA-256 `8a50194511629e965fb446418083802dda0cbe1cfa9d91a2dd25df7a08b3ea23`.

Źródła metadanych: brak standardowych małych plików metadanych.

### `Windows NT 3.51\Windows NT 3.51 Workstation 3.51.1057.1 EN.7z`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 141563885 B; SHA-256 `24adda13744589cacebf6a75e21bf8999465b5637235ce55b0cf3a7578aa7975`.

Źródła metadanych: `i386/txtsetup.sif`.

- `Microsoft Windows NT 3.51 Workstation (3.51.1057.1)\en_winnt_3.51.wks.iso`: 272793600 B; SHA-256 `b9d0e8417c1f502d1de22c249401b593be2a7fe59524b27a624dfa8dedaa099c`.
- `Microsoft Windows NT 3.51 Workstation (3.51.1057.1)\Bootdisks\Disk01.img`: 1474560 B; SHA-256 `eeeeb5b96f2f7e3b36810e3318603a096daa24661215e94883d2b0a51c51a844`.
- `Microsoft Windows NT 3.51 Workstation (3.51.1057.1)\Bootdisks\Disk02.img`: 1474560 B; SHA-256 `71106233162b57e437210fe39e247549d2fbb1820ad01dff28f93480c3ba4eed`.
- `Microsoft Windows NT 3.51 Workstation (3.51.1057.1)\Bootdisks\Disk03.img`: 1474560 B; SHA-256 `779875a30c7080fa4e8e9d6bc6f515cc8e6dd066a46b69b8be6b681f21eb19d7`.

### `Windows NT 3.5\Windows NT 3.5 Workstation 3.50.807 EN (ISO + boot disks).7z`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 109270844 B; SHA-256 `e63ce7b63906cfad0b705200ca8f1318d8620d88370ab26ce5ba6fbe8bdd5236`.

Źródła metadanych: `i386/txtsetup.sif`.

- `Microsoft Windows NT 3.5 Workstation (3.50.807)\Microsoft Windows NT 3.5 Workstation (3.50.807).iso`: 258607104 B; SHA-256 `109d2c28e3d774e01987434b11c622fbf336e01f28eec2eafe40544f166852d1`.
- `Microsoft Windows NT 3.5 Workstation (3.50.807)\Bootdisks\Windows NT 3.5 Workstation Setup Boot Disk.img`: 1474560 B; SHA-256 `b9b288b6c74db0ed8b703573ce8a0decf73787bfc53c24dac73ec798221b1f5b`.
- `Microsoft Windows NT 3.5 Workstation (3.50.807)\Bootdisks\Windows NT 3.5 Workstation Setup Disk 2.img`: 1474560 B; SHA-256 `e8dcf882f187f5c74cc3a6cbd53d5ae6b880057efd64e6f0a269d9b77fd62a3b`.
- `Microsoft Windows NT 3.5 Workstation (3.50.807)\Bootdisks\Windows NT 3.5 Workstation Setup Disk 3.img`: 1474560 B; SHA-256 `5f8e50acd5e5ffb34346519b9e01bf17f442bde15ff3363255548a154d6191e1`.

### `Windows NT 4.0 Server\Windows NT 4.0 Enterprise Server EN (CD1).iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 469604352 B; SHA-256 `36dda09a6d75db468420bdceacf91fabf59d7903f152e52d8abbb2cb7677ee43`.

Źródła metadanych: `i386/prodspec.ini`, `i386/setupp.ini`, `i386/txtsetup.sif`.

### `Windows NT 4.0 Server\Windows NT 4.0 Enterprise Server EN (CD1+CD2).7z`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 504076850 B; SHA-256 `27836a499047d34277f610da94635cea72b144466b68a2e49c761184e1348904`.

Źródła metadanych: `i386/prodspec.ini`, `i386/setupp.ini`, `i386/txtsetup.sif`.

- `Microsoft Windows NT 4.0 Enterprise Server (4.00.1381.1)\winnt40_x86en_entsrv.d1.iso`: 469604352 B; SHA-256 `36dda09a6d75db468420bdceacf91fabf59d7903f152e52d8abbb2cb7677ee43`.
- `Microsoft Windows NT 4.0 Enterprise Server (4.00.1381.1)\winnt40_x86en_entsrv.d2.iso`: 570685440 B; SHA-256 `f268d94141f1c50e62fd60ec97dd0544e72e895fe3834677adffc62f5f72fa4d`.

### `Windows NT 4.0 Server\Windows NT 4.0 Service Pack 6a.7z`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 36060209 B; SHA-256 `6f58f78aee42790bf449e64124fce5f3aa83aa6f9b9bc40cbb555f38b023bca9`.

Źródła metadanych: brak standardowych małych plików metadanych.

### `Windows NT 4.0 Server\Windows NT 4.0 USB Support Patch.7z`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 4940325 B; SHA-256 `e258a39966215abdfa7b5d912473445065d091e815e9ad51b1e54bc81fb4374a`.

Źródła metadanych: brak standardowych małych plików metadanych.

### `Windows NT 4.0 Terminal Server\Windows NT 4.0 Terminal Server Edition EN.7z`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 406701487 B; SHA-256 `caf1e045e5378988fe65647b42cca9924ba411f21d1e5d5be1a88e8141a9cb21`.

Źródła metadanych: `i386/prodspec.ini`, `i386/setupp.ini`, `i386/txtsetup.sif`.

- `Microsoft Windows NT 4.0 Terminal Server (''Hydra'' 4.00.1381.32772.sp3)\WINNT-TSE40.iso`: 598636544 B; SHA-256 `f4599974815b3f656957902c67050c76c45016aa770434efc509fb7e14b4ba7b`.

### `Windows NT 4.0 Terminal Server\Windows NT 4.0 Terminal Server Edition EN.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 598636544 B; SHA-256 `f4599974815b3f656957902c67050c76c45016aa770434efc509fb7e14b4ba7b`.

Źródła metadanych: `i386/prodspec.ini`, `i386/setupp.ini`, `i386/txtsetup.sif`.

### `Windows NT 4.0\ServicePacks\Windows NT 4.0 SP3 PL.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 603746304 B; SHA-256 `30864e1474ba6203701508dba3650537026fc3a98e785f18ed7f138216a156ed`.

Źródła metadanych: brak standardowych małych plików metadanych.

### `Windows NT 4.0\ServicePacks\Windows NT 4.0 SP6a EN (40-bit).iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 633210880 B; SHA-256 `48a13596b6a94622870b5cc76926f5b73a48737cf1b8e468d49ea96746a41154`.

Źródła metadanych: brak standardowych małych plików metadanych.

### `Windows NT 4.0\ServicePacks\Windows NT 4.0 SP6a PL.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 605073408 B; SHA-256 `4bad1d126c62b9f54a1177659740d7227d0d0bbf245fdcef8ab171234e422bb3`.

Źródła metadanych: brak standardowych małych plików metadanych.

### `Windows NT 4.0\Windows NT 4.0 Workstation PL.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 502075392 B; SHA-256 `7aae3d7c36619c4edab58c8dccf9d350c78639f88afa36ae6b21e2e9cee9611b`.

Źródła metadanych: `i386/prodspec.ini`, `i386/setupp.ini`, `i386/txtsetup.sif`.

### `Windows Server 2003\Windows Server 2003 R2 Enterprise SP2 PL VL (CD1).iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 636272640 B; SHA-256 `0c7fa1886f49bf59f02d69545ec666460d035dcaf4ddf28f29cd4f7112ac9f88`.

Źródła metadanych: `i386/prodspec.ini`, `i386/setupp.ini`, `i386/txtsetup.sif`, `setup.exe`.

### `Windows Server 2003\Windows Server 2003 R2 Enterprise SP2 PL VL (CD2).iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 129912832 B; SHA-256 `5e370e469329b73eae1ec19b54e2a570c93c9d96a5ce4b4a5fd67dfa98167f09`.

Źródła metadanych: brak standardowych małych plików metadanych.

### `Windows Server 2008 R2\Windows Server 2008 R2 SP1 VL (Standard-Enterprise-Datacenter-Web) PL x64.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 3189178368 B; SHA-256 `c1c450eaabe47790095778c0567d725b046a475458ecd9ba407dc4facc98d5ed`.

Źródła metadanych: `setup.exe`, `sources/boot.wim`, `sources/idwbinfo.txt`, `sources/install.wim`, `sources/lang.ini`, `sources/setup.exe`.

### `Windows Server 2008\Windows Web Server 2008 SP2 (6002.18005) PL x64.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 2423298048 B; SHA-256 `0e26d93db0eaf4199a015651b1598a4cbf77d1677b17a2bfa84fe8f5b07963f6`.

Źródła metadanych: `setup.exe`, `sources/boot.wim`, `sources/idwbinfo.txt`, `sources/install.wim`, `sources/lang.ini`, `sources/setup.exe`.

### `Windows Server 2008\Windows Web Server 2008 SP2 (6002.18005) PL x86.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 1782497280 B; SHA-256 `106b9e2ea6bed9bc0454724b4ed327c9e9c937fa0619e2c2175f67c192d7aedf`.

Źródła metadanych: `setup.exe`, `sources/boot.wim`, `sources/idwbinfo.txt`, `sources/install.wim`, `sources/lang.ini`, `sources/setup.exe`.

### `Windows Server 2012 R2\Windows Storage Server 2012 R2 + Server 2012 R2 Foundation with Update (9600.17415) PL x64.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 5227554816 B; SHA-256 `5e75d0296a01d21150ef53129d90ebd9fe24a96d385eb6dc85b3a9eaf1cb7d6e`.

Źródła metadanych: `setup.exe`, `sources/boot.wim`, `sources/idwbinfo.txt`, `sources/install.wim`, `sources/lang.ini`, `sources/setup.exe`.

### `Windows Vista\Windows Vista SP2 PL x64.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 3702233088 B; SHA-256 `9b84e486b7979e3880e52cd7ab4c1f3211eee0b38e2bc0a886727ba7a5cb389f`.

Źródła metadanych: `setup.exe`, `sources/boot.wim`, `sources/idwbinfo.txt`, `sources/install.wim`, `sources/lang.ini`, `sources/setup.exe`.

### `Windows Vista\Windows Vista SP2 PL x86.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 3129016320 B; SHA-256 `501e4b2c389d78ced5523eb4a997ac67673d95ec45ce0deddb0a5d85e01cb126`.

Źródła metadanych: `setup.exe`, `sources/boot.wim`, `sources/idwbinfo.txt`, `sources/install.wim`, `sources/lang.ini`, `sources/setup.exe`.

### `Windows XP Media Center\Windows XP Media Center Edition 2005 SP3.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 726138880 B; SHA-256 `0e8d7abd66c9a0f96fe59e15f2076d6db164a260e904db83d28ef0667251074e`.

Źródła metadanych: `i386/prodspec.ini`, `i386/setupp.ini`, `i386/txtsetup.sif`, `setup.exe`.

### `Windows XP Tablet PC\Windows XP Tablet PC Edition 2005 SP3 EN (updated).7z`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 770083464 B; SHA-256 `b54303791d2cf1125b1e321572870a2f28a69f86a3825acbd416427f841c9f50`.

Źródła metadanych: `i386/prodspec.ini`, `i386/setupp.ini`, `i386/txtsetup.sif`, `setup.exe`.

- `Windows XP Tablet PC Edition SP3 (Fully Updated).iso`: 817512448 B; SHA-256 `169009e24b89bea20aa91d232ae1a44b937a5ceab7d80c2a27ba50ef34c185ca`.

### `Windows XP Tablet PC\Windows XP Tablet PC Edition 2005 SP3 EN (updated).iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 817512448 B; SHA-256 `169009e24b89bea20aa91d232ae1a44b937a5ceab7d80c2a27ba50ef34c185ca`.

Źródła metadanych: `i386/prodspec.ini`, `i386/setupp.ini`, `i386/txtsetup.sif`, `setup.exe`.

### `Windows XP x64\Windows XP Professional x64 SP2 EN VL.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 628168704 B; SHA-256 `ace108a116ed33ddbfd6b7e2c5f21bcef9b3ba777ca9a8052730138341a3d67d`.

Źródła metadanych: `amd64/txtsetup.sif`, `setup.exe`.

### `Windows XP\Windows XP Professional SP2 PL.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 621182976 B; SHA-256 `3cddb947741333d7049539f6ff69a5c06071b41761f0e420eed64ad41bddba15`.

Źródła metadanych: `i386/prodspec.ini`, `i386/setupp.ini`, `i386/txtsetup.sif`, `setup.exe`.

### `Windows XP\Windows XP Professional SP3 EN.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 617756672 B; SHA-256 `62b6c91563bad6cd12a352aa018627c314cfc5162d8e9f8af0756a642e602a46`.

Źródła metadanych: `i386/prodspec.ini`, `i386/setupp.ini`, `i386/txtsetup.sif`, `setup.exe`.

### `Windows XP\Windows XP Professional SP3 PL OEM (NiKKA 2014-04).iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 872851456 B; SHA-256 `9fe5a0a744ec299c2fc821101a8b0a2f31133317f841983bf45fe60d45d91985`.

Źródła metadanych: `i386/prodspec.ini`, `i386/setupp.ini`, `i386/txtsetup.sif`, `setup.exe`.

### `Windows XP\Windows XP Professional SP3 PL.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 622090240 B; SHA-256 `bd3234250a6e2f68fbacf0a46cf42a7d711811e428210c0d60649a054f28ff0b`.

Źródła metadanych: `i386/prodspec.ini`, `i386/setupp.ini`, `i386/txtsetup.sif`, `setup.exe`.

### `Windows for Workgroups 3.11\Windows for Workgroups 3.11 PL (1.44M floppies).7z`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 12383345 B; SHA-256 `b52ded69c39065d65049d109a5f24923985dd2ab8dde2733bd9cf9e715435133`.

Źródła metadanych: brak standardowych małych plików metadanych.

- `Microsoft Windows For Workgroups 3.11 [Polish] (3.5-1.44mb)\disk01.img`: 1474560 B; SHA-256 `c8b81174755ed54663b5609f9d9c6ec232e6cc80961ca53264efffc7c023933f`.
- `Microsoft Windows For Workgroups 3.11 [Polish] (3.5-1.44mb)\disk02.img`: 1474560 B; SHA-256 `c8acf148e756defdb5b4e68323e4e0bfe7e4917361433ea5dd1a9b0688971ad9`.
- `Microsoft Windows For Workgroups 3.11 [Polish] (3.5-1.44mb)\disk03.img`: 1474560 B; SHA-256 `961bb11949304f8114b653b4db451ced69bc753d54ac3fb05303b91e9f18592b`.
- `Microsoft Windows For Workgroups 3.11 [Polish] (3.5-1.44mb)\disk04.img`: 1474560 B; SHA-256 `0313b96df51f50daa0260325a089c90b1b4b036c069bbee4c320ba6f3df0cdf4`.
- `Microsoft Windows For Workgroups 3.11 [Polish] (3.5-1.44mb)\disk05.img`: 1474560 B; SHA-256 `d983052d2668d6ce9f158e9183e11151ed067110cbee0fce6d68f16b92e92893`.
- `Microsoft Windows For Workgroups 3.11 [Polish] (3.5-1.44mb)\disk06.img`: 1474560 B; SHA-256 `2ea8f1c7bccd5045899ceb960d334a373d3782618c654a6ea64a959ced1bbd25`.
- `Microsoft Windows For Workgroups 3.11 [Polish] (3.5-1.44mb)\disk07.img`: 1474560 B; SHA-256 `d48e36c7db8aaf00362a0d7ad1d8e350e8aac9b3ab6cddc8292044ff9173624b`.
- `Microsoft Windows For Workgroups 3.11 [Polish] (3.5-1.44mb)\disk08.img`: 1474560 B; SHA-256 `ad442958245494ece772549be492d00a15e13bef1782d4d7c605e765fdb2802d`.
- `Microsoft Windows For Workgroups 3.11 [Polish] (3.5-1.44mb)\disk09.img`: 1474560 B; SHA-256 `bdbb5bbe15adf3e5b78b78ad39cfff6f0483978f190febe747c3de9120e07cd2`.
- `Microsoft Windows For Workgroups 3.11 [Polish] (3.5-1.44mb)\disk10.img`: 1474560 B; SHA-256 `ae95dda75dcc1fcac20eefb52b1a9439c682d4d3d2869dcc05a8e77ae54e4ce0`.

### `Windows for Workgroups 3.11\Windows for Workgroups 3.11 PL.iso`

Magazyn: `C:\Users\ASRock\Desktop\Universal_Service_OS\OS\Windows`; 14168064 B; SHA-256 `0386bb5ec88e23856ff781dd3f970727187460d9bb26efab1dd144831cd556a3`.

Źródła metadanych: `setup.exe`.

### `Windows\Windows 2000\Windows 2000 Professional SP0 EN x86.7z`

Magazyn: `G:\USOS-Kolekcja`; 325875583 B; SHA-256 `57ccab7c828bbb401215115bf33cdef8cdc936197fbe9ca64702496e16feb398`.

Źródła metadanych: `i386/prodspec.ini`, `i386/setupp.ini`, `i386/txtsetup.sif`, `setup.exe`.

- `Microsoft Windows 2000 Professional (5.00.2195)\W2PIS_EN.iso`: 379987968 B; SHA-256 `6513fd56ba8fadd0d63f805826486eee5c65619504445a10cb2920add17f20ee`.

### `Windows\Windows 2000\Windows 2000 Professional SP1 EN x86.7z`

Magazyn: `G:\USOS-Kolekcja`; 341050575 B; SHA-256 `0fbf01781457c5acf2e23e0fc5fbf6856012b347bb7b91300960f5c838cb2263`.

Źródła metadanych: `i386/prodspec.ini`, `i386/setupp.ini`, `i386/txtsetup.sif`, `setup.exe`.

- `Windows 2000 Professional (with SP1) (OEM)\5.00.2195.1620_x86fre_client-professional_oem_en-us-SP1POEM_EN.iso`: 395317248 B; SHA-256 `eb949ee8f03eb23c311a80e59792cba79c2944d1f74fde4dec2c56f7f5fc20ba`.

### `Windows\Windows 2000\Windows 2000 Professional SP2 EN x86.7z`

Magazyn: `G:\USOS-Kolekcja`; 333075030 B; SHA-256 `5041625e591e8358bfa621344040c0ab689150334eb3735b1ab963be168d8915`.

Źródła metadanych: `i386/prodspec.ini`, `i386/setupp.ini`, `i386/txtsetup.sif`, `setup.exe`.

- `Microsoft Windows 2000 Professional (with SP2) (OEM) (ISO)\5.00.2195.2951_x86fre_client-professional_oem_en-us-SP2POEM_EN.iso`: 385757184 B; SHA-256 `de2ac8a6d475912c93bbfd68a4e195ea1738d5874d031183ad141f7a6e4d5232`.

### `Windows\Windows 2000\Windows 2000 Professional SP3 EN x86.7z`

Magazyn: `G:\USOS-Kolekcja`; 336646271 B; SHA-256 `629cfcf40cbe37080f951db64049cf67722923eba742b23213d5a3ad06c6c586`.

Źródła metadanych: `i386/prodspec.ini`, `i386/setupp.ini`, `i386/txtsetup.sif`, `setup.exe`.

- `Microsoft Windows 2000 Professional (with SP3) (OEM) (ISO)\Windows2000ProfessionalSP3.iso`: 390254592 B; SHA-256 `f6d880e6447933d224061897503055f5a6345ca3507f3b9f4c7ba2f6aa6fc2a5`.

### `Windows\Windows 7\Windows 7 Home Premium RTM PL x64.iso`

Magazyn: `G:\USOS-Kolekcja`; 3124578304 B; SHA-256 `1471fb683a445d932deb46d1fb3feca0e170b955bb7f32712891591b561ca7d7`.

Źródła metadanych: `setup.exe`, `sources/boot.wim`, `sources/idwbinfo.txt`, `sources/install.wim`, `sources/lang.ini`, `sources/setup.exe`.

### `Windows\Windows 7\Windows 7 Home Premium RTM PL x86.iso`

Magazyn: `G:\USOS-Kolekcja`; 2395904000 B; SHA-256 `8a52d0559b578c16f510444840f789b1bfcdf469341a208ea03b1d0207c9cecd`.

Źródła metadanych: `setup.exe`, `sources/boot.wim`, `sources/idwbinfo.txt`, `sources/install.wim`, `sources/lang.ini`, `sources/setup.exe`.

### `Windows\Windows 95\Windows 95 OSR1 EN OEM x86.7z`

Magazyn: `G:\USOS-Kolekcja`; 329814993 B; SHA-256 `b39518b1e698555a94060898b41ab8fe6e80749baebe500c4d11cc5e5131ab32`.

Źródła metadanych: `setup.exe`.

- `win95_a_oem.iso`: 605220864 B; SHA-256 `5a2eb601d689f08ecbd733aa6b52ee93ec8f5aa9a145332577a8ba37c9dc89f2`.

### `Windows\Windows 95\Windows 95 OSR2 EN OEM x86.7z`

Magazyn: `G:\USOS-Kolekcja`; 400669836 B; SHA-256 `d02167793b1e66077c19e9342a249cc85421c204be6f960b95f2a9886505680f`.

Źródła metadanych: `setup.exe`.

- `Microsoft Windows 95B (4.00.1111) (OSR2) [English] (CD)\windows95b.iso`: 626272256 B; SHA-256 `b4f39760e99b1f53d8de40bc1485463b91684a17265d89366fc5227cc1d99900`.

### `Windows\Windows 95\Windows 95 OSR2.5 EN OEM x86.7z`

Magazyn: `G:\USOS-Kolekcja`; 384205502 B; SHA-256 `4e01a546f1d96f24467ef1135ef6339238f834de29c406206e18b77056859333`.

Źródła metadanych: `setup.exe`.

- `Microsoft Windows 95C (4.03.1216) (OSR2.5) (1997-11-26) [English]\Win95_OSR25.iso`: 618229760 B; SHA-256 `493212b2a3cd391269e55a8fde5ee0a35e29ddece4b5910ec49df69ab62f5e26`.

### `Windows\Windows 95\Windows 95 RTM PL OEM x86.7z`

Magazyn: `G:\USOS-Kolekcja`; 206006444 B; SHA-256 `bb154a3ba0cf0c5051813875bdd94fc172e1bae83d97aa8c35d88f221f58017c`.

Źródła metadanych: `setup.exe`.

- `Microsoft Windows 95 [Polish] (OEM) (ISO)\disk01.iso`: 260286464 B; SHA-256 `6cb14073c3090c5168c17cf28e845fac4f5c017699edb59a185b8f340454d313`.

### `Windows\Windows 98 SE\Windows 98 FE to SE Update EN x86.7z`

Magazyn: `G:\USOS-Kolekcja`; 542369302 B; SHA-256 `84e40109321c8c57bc1b5f345f7e744d854c015c00a519f6dc6643fc24964e81`.

Źródła metadanych: `setup.exe`.

- `Microsoft Windows 98 Update (FE to SE)\Windows 98 Update (FE to SE).iso`: 652218368 B; SHA-256 `53c18a410b22d903ff5666fd06728dc62414a39ba0eb5bf6fe3c6ab5ee83937e`.

### `Windows\Windows 98 SE\Windows 98 SE EN OEM Full x86.7z`

Magazyn: `G:\USOS-Kolekcja`; 544438892 B; SHA-256 `e79dd47c37ae8bd3488ebe7a2be179c5fd12169f75f053f3b13a024d0ce1600f`.

Źródła metadanych: `setup.exe`.

- `Microsoft Windows 98 Second Edition\Windows 98 Second Edition.iso`: 655591424 B; SHA-256 `2adfb46df8a9c7bbd2f67bff07461cc2f9d9ec8e01f0e112cb044c9e3e62f607`.

### `Windows\Windows 98 SE\Windows 98 SE EN Retail Upgrade x86.7z`

Magazyn: `G:\USOS-Kolekcja`; 545828415 B; SHA-256 `efc76dd2332a0aa67fd9d7c0c17903a4c8fb22cee28ceab2a52ebd357db119fd`.

Źródła metadanych: `setup.exe`.

- `Windows 98 SE (102 - Retail Upgrade).iso`: 652603392 B; SHA-256 `c1e54c013e4b946830ad4e5536936d64dc4c0d099bb3ae1adb6fa07fe47329f4`.

### `Windows\Windows 98\Windows 98 FE EN OEM Full x86.7z`

Magazyn: `G:\USOS-Kolekcja`; 520031423 B; SHA-256 `3eca97f2f5ad03e73a6590b5eea651bc0297f4ea5b35ce3c5423a75d91ff2515`.

Źródła metadanych: `setup.exe`.

- `Windows 98 First Edition.iso`: 654219264 B; SHA-256 `108a40512f0c897697e31b4127dc1335b32a3d86cf637162552ae5e1556868fa`.

### `Windows\Windows NT 3.5 Server\Windows NT 3.5 Server EN x86.7z`

Magazyn: `G:\USOS-Kolekcja`; 148115829 B; SHA-256 `682ee2983d4850766b22e5a0e5c616b2b61adc5bfca9cf598972af29d4491204`.

Źródła metadanych: `i386/txtsetup.sif`.

- `Microsoft Windows NT 3.5 Server (3.50.800.1)\en_winnt_3.5.srv.iso`: 369180672 B; SHA-256 `b414ba25351ee58b78a57f8c093f9b82a5e03ad8485c83e056e7777cfae6f732`.

### `Windows\Windows NT 4.0 Embedded\Windows NT 4.0 Embedded EN x86.7z`

Magazyn: `G:\USOS-Kolekcja`; 236795062 B; SHA-256 `c9f12f95a312a6ecec622e5d97a31016d3d88cfcdb850da55ab2f10f7cfec487`.

Źródła metadanych: brak standardowych małych plików metadanych.

- `winnt40.1381.embedded.x86.iso`: 428709888 B; SHA-256 `96554d400d241db3bb04a74a7b527623afeb88e73aad8e4beb05de8d263c1b11`.

### `Windows\Windows NT 4.0 Server\Windows NT 4.0 Server EN x86.7z`

Magazyn: `G:\USOS-Kolekcja`; 421982892 B; SHA-256 `30500481e316daac4770f3d6d862055a7346022c811ee836b18afd0bb4ff3bc3`.

Źródła metadanych: `i386/prodspec.ini`, `i386/setupp.ini`, `i386/txtsetup.sif`.

- `Microsoft Windows NT 4.0 Server (4.00.1381.1)\en_winnt_4.0_svr.iso`: 640942080 B; SHA-256 `97596eece4d87e02b6775cf8c6a99e1ff518e0d23eb79b2eae8726d2a2c480bb`.

### `Windows\Windows Vista\Windows Vista Business SP1 EN x86.iso`

Magazyn: `G:\USOS-Kolekcja`; 3086147584 B; SHA-256 `35132e5d83766c9370427fc954af596d5b152ea81f251c3b851f7b4d5a152313`.

Źródła metadanych: `setup.exe`, `sources/boot.wim`, `sources/idwbinfo.txt`, `sources/install.wim`, `sources/lang.ini`, `sources/setup.exe`.

### `Windows\Windows Vista\Windows Vista RTM EN x64.iso`

Magazyn: `G:\USOS-Kolekcja`; 3796490240 B; SHA-256 `e13a6e4cc31e1e446bbcc4d28ec98e2539847579a67fa0d3f3ecce9937c55fdc`.

Źródła metadanych: `setup.exe`, `sources/boot.wim`, `sources/idwbinfo.txt`, `sources/install.wim`, `sources/lang.ini`, `sources/setup.exe`.

### `Windows\Windows Vista\Windows Vista RTM EN x86.iso`

Magazyn: `G:\USOS-Kolekcja`; 2678614016 B; SHA-256 `ae60ecc228587b615fbd27b7071138b1b257521c3b0b9491614f575978158a73`.

Źródła metadanych: `setup.exe`, `sources/boot.wim`, `sources/idwbinfo.txt`, `sources/install.wim`, `sources/lang.ini`, `sources/setup.exe`.

### `Windows\Windows XP\Windows XP Home RTM PL x86.iso`

Magazyn: `G:\USOS-Kolekcja`; 505677824 B; SHA-256 `7e1345b89ece3ac03f73be7c0c6eb34f95309dc312a2fed024d659217445fa8f`.

Źródła metadanych: `i386/prodspec.ini`, `i386/setupp.ini`, `i386/txtsetup.sif`, `setup.exe`.

### `Windows\Windows XP\Windows XP Professional SP1 EN x86.iso`

Magazyn: `G:\USOS-Kolekcja`; 565852160 B; SHA-256 `37d031b9d0a917d07b5f374d3bf6bd2770a47468afd6ac4e2e9d1266dcb5944f`.

Źródła metadanych: `i386/prodspec.ini`, `i386/setupp.ini`, `i386/txtsetup.sif`, `setup.exe`.
