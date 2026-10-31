<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# MiniOS 1c6 — wynik końcowy: STOP UnsupportedMftAttributeList

2026-10-26, kod e309eeeb, gałąź codex/minios-etap1. Po dodatkowym poleceniu użytkownika pominięto zewnętrzne porównanie BCD i wykonano rzeczywistą bramkę MiniOS kopiującą pliki rozruchowe. **Zatrzymał ją czytnik NTFS: UnsupportedMftAttributeList. Windows nie został uruchomiony.** Poniżej aktualny wynik; starszy raport zachowano dalej wyłącznie jako historię.

## Kontynuacja po zmianie bramki BCD

Wprowadzono jawny schemat `minios-bcd-reference-deferred-1c6-v1`: `bcdboot_passed=false`, `external_comparison_skipped=true`, `firstboot_required=true`. Nie podszywa się pod PASS bcdboot. Własny BCD odczytano niezależnym parserem REGF i sprawdzono GUID rzeczywistych partycji, ścieżki loadera i locale. Oba receipt, natywne bramki oraz cały backing chain pozostają przypięte SHA. Kod i dwa nowe testy: e309eeeb. BCD/BIOS/boot:64 testy PASS, czysty HEAD.

Wykorzystano istniejący ukończony cel Win11 z1c5, bez reinstalacji. MiniOS w UEFI x64 QEMU prawidłowo rozpoznał pełną tożsamość GPT/NTFS i oba receipt. Po38,006s zakończył się kodem35:

```
BOOT TARGET ... full_GPT_and_NTFS_identity=matched
USOSBOOT UEFI FAIL UnsupportedMftAttributeList
USOSPREP TERMINAL FAIL UnsupportedMftAttributeList
```

Potwierdzona przyczyna: `src/prep/boot_files.zig:150` wywołuje `nt.mount`; wspólny czytnik `src/storage/ntfs.zig:208` odmawia po znalezieniu $ATTRIBUTE_LIST w rekordzie0 pliku $MFT. Niezależny odczyt zaakceptowanego VHD potwierdził atrybut0x20: nonresident, id1, lowest_vcn0. MFT_LCN4, rekord1024B, klaster4096B. Obsługa list atrybutów zwykłych plików nie rozwiązuje bootstrappingu własnych rekordów rozszerzeń $MFT.

To luka kompatybilności czytnika z dużym NTFS wytworzonym przez nasz writer. Nie obala wcześniejszego native chkdsk0 i nie jest dowodem uszkodzenia woluminu. Brak BOOT_PREFLIGHT/copy, skopiowano0 plików. Zakończone `qemu-img compare` zwróciło0: `Images are identical.` Nakładka po odmowie jest logicznie identyczna z celem1c5; przypięte źródła i bazy bez zmian.

Dowody: `1c23/qemu-x64/boot-win11-1c6-01/{result.json,debug.log,serial.log,boot-files.json}`, `1c6/stop-diagnosis-boot.json`, `1c6/logs/closed-boot-evidence02.log`. Pole called_from w pomocniczym JSON omyłkowo wskazuje134; poprawna linia wywołania nt.mount to150, a źródło odmowy208. Pierwszy checker diagnozy nie obsługiwał context managera DynamicVhd; poprawiono wyłącznie operator i wykonano pełną kontrolę, oba logi zachowane.

|Brama|Wynik końcowy|
|---|---|
|Runner: bieżący budżet2GiB/EOF/10800s/całość z logami|PASS testów komponentów i rzeczywistego QEMU.|
|Niezależny REGF naszego BCD i rzeczywista trasa GPT|PASS; zewnętrzne porównanie pominięte za jawną zgodą.|
|Win11: MiniOS bootfiles na nakładce celu1c5|FAIL UnsupportedMftAttributeList, cel logicznie bez zmian.|
|Win11: pierwszy start TCG, specialize/OOBE, Panther/F5|NIEWYKONANE. Zrzut fixture runnera nie jest ekranem Windows.|
|Win10 IA32 / Win7 BIOS / Win11 64MiB / Pentium|NIEWYKONANE po pierwszej rzeczywistej odmowie MiniOS.|

Zachowano21 nowych obrazów/NVRAM:7702305280B≈7,17GiB, zero dodatkowych usunięć. Dokładna lista ścieżka/rozmiar/SHA: `1c6/retained-images02.json`. Obrazy pozostają do akceptacji. Punkt pomiaru2026-10-26T15:34:18UTC: pula z pełnymi rezerwami141401067972B≈131,69/150GiB, wolne136512106496B≈127,14GiB. Preflight przed każdą grupą; oryginalne Win11 QCOW i native VHD1c5 zachowane. Artefakty bootEFI/BCD i operatory również zachowane.

Pełny Python na9af1e9c9:351/351, zero skip,103,028s. Po tej kontynuacji: pełny Python na końcowym HEAD po commicie raportu w `1c6/logs/python-final-continued-head.log`; wynik zostanie dopisany do raportu zewnętrznego bez kolejnej zmiany HEAD. Kod Zig nie zmieniony; wcześniejszy build BCD i obu boot UEFI z audytem i486 PASS. Nie powtarzano862 Zig z1c5.

Dalsza naprawa wymaga resolvera $MFT/$ATTRIBUTE_LIST w ścieżce odczytu boot-source i ponowienia samej bramki na nowej nakładce tego samego celu1c5. Nie reinstalować zaliczonego Windows. W tym podejściu nie zmieniano wspólnego src/storage ani nie obchodzono odmowy. Bez .sys/.cer/G:/fizycznych nośników/merge/push/deploy. Dowodowe operacje BelowNormal, dwa hostCPU, build-j2, bez progress polling. Własne QEMU zakończone. **STOP na pierwszej rzeczywistej bramce MiniOS, bez automatycznej kontynuacji.**

---

## Historia przed dodatkowym poleceniem użytkownika — zastąpiona wynikiem powyżej

2026-10-26, gałąź `codex/minios-etap1`, baza `112af328`, kod końcowy `4412f4a8`. Wyłącznie QEMU i pliki wirtualne. Nie uruchomiono Windows. Zgodnie z poleceniem pierwsza niezaliczona bramka zatrzymała dalszą kolejność.

## Wynik bramek

|Brama|Wynik i dowód|
|---|---|
|Naprawa runnera przed firstboot|PASS testów komponentów i rzeczywistego QEMU; szczegóły niżej.|
|Win11 przygotowanie/natywne bramki1c5|Wykorzystano istniejący, zaakceptowany cel. Bez reinstalacji i zmiany bazy.|
|Nasz BCD dla rzeczywistego GPT|Własny zapis12288B, niezależny odczyt python-registry i poprawna trasa do rzeczywistych GUID partycji PASS. To jeszcze nie porównanie z bcdboot.|
|Prawdziwy bcdboot na nakładce VHD|FAIL: exit183, NTSTATUS0xC0000035 przy ładowaniu klucza BCD00000000. STOP.|
|Niezależne porównanie obu BCD|NIEWYKONANE: wyrocznia nie utworzyła poprawnego magazynu.|
|MiniOS boot files / Windows TCG / specialize / OOBE / Panther / F5|NIEWYKONANE. Pliki kopiowane przez bcdboot do jego własnego referencyjnego dziecka nie zaliczają osobnej bramki MiniOS.|
|Win10 IA32, Win7 BIOS, Win11/64MiB, opcjonalny Pentium|NIEWYKONANE zgodnie z kolejnością i STOP.|

## Diagnoza pierwszej niezaliczonej bramki

Próba `1c6/logs/bcd-win11-02.log`, czysty HEAD12c81f2b. Rzeczywiste polecenie: `bcdboot X:\Windows /s Y: /f UEFI /l pl-PL /v`. X i Y były wyłącznie tymczasowymi aliasami partycji zweryfikowanego dziecka VHD, nie dysków fizycznych. Hostowe bcdboot ma wersję10.0.19041.1; źródłowy log podaje wersję OS a000065f40001. Narzędzie przeszło kopiowanie plików EFI/fontów/zasobów, następnie odmówiło przy tworzeniu nowego magazynu:

```
Failed load key BCD00000000 ... Status: c0000035
Failed to create a new system store. Status = [c0000035]
```

0xC0000035 oznacza `STATUS_OBJECT_NAME_COLLISION` według [MS-ERREF](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-erref/596a1078-e883-4972-9bbc-49e60bebca55). Odczyt `hivelist` potwierdził już załadowany hostowy BCD00000000. To trop kolizji w środowisku wyroczni, **nie niezależnie udowodniona przyczyna**. Nie jest to wynik porównania z naszym BCD ani dowód uszkodzenia NTFS. Nie odładowywano hostowego hive, nie naprawiano hostowego rozruchu i nie ponawiano bramki po błędzie.

Guard po błędzie usunął oba aliasy i odłączył wirtualne dziecko; `dismounted=true`, `aliases_removed=true`. SHA bazy przed/po identyczne: `7ff67181a910ee9461211ea5fe9b2e34958be41a30c102cd9356a40560848907`. Dziecko zachowane:79990784B, SHA`560d18a37e6325f4b322769e5bc546811affb56cb58c2d53b9ebb7c79b994da0`. Opcja `/s` zapobiega tworzeniu wpisu NVRAM zgodnie z [dokumentacją BCDBoot](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/bcdboot-command-line-options-techref-di?view=windows-11).

Dalszy kierunek dopiero w nowym zleceniu: wyrocznia w izolowanym WinPE z dopasowanym narzędziem, bez ingerencji w hive hosta. Obecne zadanie kończy się na tym błędzie, bez obejścia bramki.

## Runner — limit podczas zapisu i zakończenia

- QCOW2 na stałej warstwie raw1879048192B(1792MiB), wcześniej utworzona migawka `firstboot-base`, plik rozszerzony jako sparse. Brak rozszerzania kontenera przez QEMU; backing tylko do odczytu, odmowa zewnętrznych plików DATA. `werror=stop,rerror=stop`, każdy BLOCK_IO_ERROR terminalny, bez CONT.
- Wszystkie utrwalane pliki pomocnicze mają rozłączne limity sprawdzane PRZED zapisem. Suma limitów wraz z nakładką i Panther=2028994560B ≤2147483648B. Obejmuje nagłówkiF3, NVRAM, obaPIPE, mapęQCOW, zrzut, cztery Panther i JSON-y błędów/wyniku. Brak nieograniczonego pliku serial; stdout stanowi serial+stdout. NVRAM przez raw o stałym rozmiarze540672B.
- Zrzut PPM trafia przez prywatny Windows named pipe do ograniczonego odbiornika32MiB. QEMU nie zapisuje zrzutu bezpośrednio na dysk. Oczekiwania natywne są zdarzeniowe, CancelIoEx przerywa operację po błędzie. TEMP wskazuje nieistniejący katalog; narzędziom nie udostępnia się nieograniczonego ujścia tymczasowego.
- Limit endpointu1..10800s; CLI dla rzeczywistych prób60..10800s. Cały proces z potomkami jest objęty prywatnym Windows Job i pojedynczym watchdogiem maks.10800s, obejmującym preflight, przygotowanie, gościa, zrzut, mapowanie, Panther i sumy. Dla logów/zakończenia rezerwowane300s, więc endpoint gościa może być krótszy od żądanych10800s. Nie testowano trzygodzinnego upływu czasu; przetestowano ten sam mechanizm wygaśnięcia na krótkim fixture i walidację10800s.
- QMP EOF i błądJSON budzą oczekiwanie; błędy dysku sprawdzane także po stop/zrzucie/quit i doczytaniu końcaQMP. Wyjątek Windows reset64/10054 tylko po potwierdzonym własnym quit, exit0 oraz zdarzeniu host-qmp-quit; wcześniejszy reset pozostaje błędem.
- QEMU na Windows odmawia `dump-guest-core=off`; opcja używana tylko poza Windows. Nie zmieniano systemowych ustawień WER. Deklarowany budżet dotyczy kontrolowanych plików runnera; nie jest limitem systemowych raportów awarii hosta.

Rzeczywisty fixture04, HEAD4412f4a8: poprawny zapis1MiB PASS, nadmiar31MiB na pojemniku8MiB odrzucony ENOSPC, rozmiar stały i baza niezmieniona. QEMU zatrzymany `-S` (żadna instrukcja gościa, brak Windows): ograniczone QCOW/pflash/stdio i PPM921615B PASS, exit0; razem1880510935B kontrolowanych plików. Watchdog własnego procesu i jego śpiącego potomka zakończony kodem124 PASS. Próba trwała2,55s. Bez odpytywania postępu.

Testy obejmują: odmowy sfałszowanych bramek, limity każdego odbiornika, równoczesne zalanie stdout/stderr, EOF na endpoint10800s bez czekania3h, błędyJSON i dysku oraz późny błąd po stop/zrzucie/quit. Pomocniczy agent przejrzał kod wyłącznie odczytowo; wskazaną lukę późnego BLOCK_IO_ERROR zamknięto osobnym commitem.

## Historia weryfikacji i uczciwe ograniczenia

Pełny Python02:347/347, zero skip, czysty12c81f2b; MINIOS_ZIG włącza natywny audyt ABI. Końcowe rozszerzenia dodają4 testy. Pełna kontrola Python na końcowym HEAD po commicie tego raportu ma osobny log `1c6/logs/python-final-head.log`; ostateczny wynik zostanie dopisany do raportu zewnętrznego bez kolejnej zmiany HEAD. Nie powtarzano testów Zig862 z1c5, bo src/prep i build.zig nie zmieniono. Ponownie zbudowano usosprep-bcd oraz obie binarki boot UEFI i audyt i486, build PASS na5d6d1129.

Zachowano błędne próby, nie zastąpiono ich wynikami PASS: runner01 odrzucony przez nieobsługiwaną opcję Windows; Python01 jedna awaria wyścigu krótkiego producenta pipe i jeden skipABI; operator BCD01 podał GUID bez wymaganych nawiasów i odmówił przed API; runner03 ujawnił normalny TCP reset po własnym quit. Poprawki i nowe testy są w osobnych commitach. Runner04 to końcowy rzeczywisty PASS. Bramka bcdboot02 to jedyna rzeczywista próba referencyjna Windows w tym podejściu i końcowy STOP.

## Pojemność, sprzątanie i zachowanie dowodów

Użytkownik w zleceniu2026-10-26 jawnie zatwierdził dokładnie14 celów `1c5/capacity-cleanup-proposal.json`. Wszystkie14 rozmiarów/SHA sprawdzono PRZED pierwszym usunięciem, następnie usunięto dokładnie te14 plików:37646828032B logicznie. Zgoda i zakończenie zapisane w KOTWICA, `1c6/accepted-cleanup-14.json` i `docs/minios-cleanup-1c6.json`; SHApropozycji468d0ae88b61f1d980e8618aeaff9f8c275b78b26c6985c378ba070e5653f90b. Pełna lista ścieżka/rozmiar/SHA jest w obu receipt. Logi, manifesty i receipt pozostały. Żadnych dodatkowych usunięć.

Nowe17 obrazów/NVRAM zachowane, 7632689152B≈7.11GiB. Lista każdego pliku i nowo obliczonySHA: `1c6/retained-images.json`, kopia w `docs/minios-evidence-1c6.json`. Nie usuwać przed akceptacją. Punkt pomiaru2026-10-26T15:14:01.756746+00:00: konserwatywna pula z pełnymi rezerwami131.69/150GiB; rzeczywiste wolneK=127.43GiB≥100GiB. Preflight przed każdą grupą obrazów, wszystkie zachowane cele mieszczą się w rezerwacjach.

## Commity

|Commit|Zakres|
|---|---|
|ead7cfe5|Dokładna zgoda i zakończenie cleanup14.|
|6ea6cd4a|Stały QCOW, ograniczone ujścia/PPM/pflash, EOF i Job watchdog, testy.|
|5d6d1129|Zgodność opcji guest-core z Windows.|
|12c81f2b|Wyścig krótkiego producenta named pipe.|
|7378ca92|Późne błędy dysku po zakończeniu.|
|4412f4a8|Ścisłe rozpoznanie potwierdzonego normalnego resetu QMP na Windows.|

Zmiany tylko w dozwolonych narzędziach/testach MiniOS i docs/minios*. Zero zmian .sys/.cer, kodu Microsoftu w gicie, G:, nośników fizycznych, merge/push/deploy. Wszystkie uruchomienia przez BelowNormal i affinity12 (dwa hostCPU), build-j2, QEMU-smp2; bez progress polling. Nie ma własnych uruchomionych gości. **STOP bez automatycznej kontynuacji.**
