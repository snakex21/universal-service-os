<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# RAPORT-MINIOS-1C2-1C3 — STOP na bramce 1c-2

Data: 2026-10-25 UTC. Gałąź `codex/minios-etap1`, worktree `<WT>/minios-etap1`.
Kod: `63a8cc45cc3f1a45ddb31b35740a4fb94150767b`; rzeczywiste firmware Windows wykonano z czystym runnerem `310cf37611e2d64122d95ac5a858cf84b896dcea`.
`<RUNTIME>` oznacza zatwierdzony lokalny folder testów MiniOS; wszystkie ścieżki dowodów poniżej są względem jego `1c23/`, jeśli nie podano innego prefiksu. `<UEFI_VALIDATION>`, `<BIOS_VALIDATION>` i `<BOOT_VALIDATION>` to oddzielne czyste snapshoty repozytorium, bez zmiany głównej gałęzi podczas testów.

## Wynik

**Cała ścieżka 1c-2/1c-3 NIE jest zaliczona.** Obie rzeczywiste próby przygotowania Windows w MiniOS przekroczyły limit3600s po zakończonym odczycie metadanych, we wspólnym `Archive.verifyAll`. Zgodnie z warunkiem pierwszej nieprzechodzącej bramki i KOTWICA dalsze etapy zatrzymano. Wszystkie rozpoczęte VM zakończone; nie pozostawiono kolejnej próby w tle.

| Bramka | Wynik |
| --- | --- |
| Własne małe dane: rzeczywisty UEFI ISO-na-NTFS → WIM → GPT/FAT32/NTFS | PASS:391 plików/20 katalogów,251,43s, exit33 |
| Win11 x64 UEFI, index2,128MiB, cel32GiB | FAIL:timeout3600s; czas całej operacji3631,64s |
| Win10 x86 UEFI IA32, index2,128MiB, cel16GiB | FAIL:timeout3600s; czas całej operacji3612,40s |
| Win7 x86 BIOS/MBR, index1 | NIE URUCHOMIONO po pierwszej blokadzie; kod i źródło gotowe |
| Native read-only chkdsk + pełne drzewo/SD/SHA dla nowych rzeczywistych celów | NIE URUCHOMIONO; poprzednia bramka nie przeszła |
| REGF/BCD: niezależny odczyt własnych małych hive | PASS host, osobno opisany niżej |
| Prawdziwy bcdboot na tym samym przygotowanym układzie + porównanie | NIE URUCHOMIONO; nie ma zaakceptowanego nowego celu |
| Rzeczywisty zapis bootfiles do przygotowanego Windows | NIE URUCHOMIONO; implementacja i zabezpieczone runnery gotowe |
| Pierwszy Windows: specialize → OOBE/pulpit | NIE URUCHOMIONO |
| F5: pominięcie typu4 metadanych Win11 nie psuje startu | NIEPOTWIERDZONE; Windows nie wystartował |

Nie ma nowych zrzutów OOBE, setupact.log ani setuperr.log. Nie zastępujemy ich zrzutem firmware czy wynikami hostowymi. Windows w obu próbach nie zaczął się uruchamiać.

## Diagnoza zamkniętych prób

Win11: poprawnie wybrano wskazany cel i źródło NTFS, odczytano UDF/`sources/install.wim`7 437 390 947B, wybrano index2, zakończono WIM_PREFLIGHT:136696 plików,32055 katalogów,41264 aliasy hardlinków,82533 nazwy8.3. W lookup jest95862 zasobów. Log potwierdza pominięcie86217 wpisów metadanych typu4, ale nie ich zgodność przy starcie Windows.

Win10 IA32: odczytano właściwe źródło i index2, zakończono WIM_PREFLIGHT:77426 plików/21794 katalogów. Zatrzymanie nastąpiło przed tym samym końcowym potwierdzeniem zasobów.

W `src/prep/wim_app.zig` bezpośrednio po komunikacie WIM_PREFLIGHT wywoływane jest `archive.verifyAll()`, dopiero po jego powrocie następuje `WIM_SHA1 ALL_BLOBS PASS` oraz callback partycjonowania. W obu logach brak tych późniejszych komunikatów i brak błędu SHA1/TERMINAL FAIL. Oba cele zachowały dokładny początkowy marker, a plik nakładki ma197120B; źródła i bazy mają niezmienione SHA256. Diagnozę wykonano dopiero po zakończeniu procesów, z odczytem sektora0 wyłącznie read-only.

**Udowodniona blokada: brak zakończenia wspólnej archiwalnej weryfikacji LZX/SHA1 w3600s.** Dotychczasowy log ma tylko końcowe zbiorcze potwierdzenie; nie pozwala odróżnić bardzo wolnego wykonania w TCG od utknięcia wewnątrz dekodera/odczytu. Nie stwierdzamy korupcji WIM, problemu Windows ani konkretnej nieskończonej pętli bez dowodu. Pętla zewnętrzna jest ograniczona liczbą zasobów, ale nie ma zapisu numeru ostatniego ukończonego zasobu ani profilu zatrzymanego gościa.

Mały udany smoke używał XPRESS. Nie potwierdza szybkości ani poprawności pełnego rzeczywistego LZX w firmware. Jednoczesne wystąpienie problemu w x64 i IA32 zawęża dalszą analizę do wspólnej ścieżki weryfikacji; nie jest dowodem wyłączającym wszystkie błędy platformy. Ostrzeżenie GLib o AppxManifest zachowano w stderr, bez osobnego dochodzenia.

Dalsza praca wymaga osobnego wznowienia po tym raporcie: najpierw mały rzeczywisty LZX oraz znaczniki zasób/początek/koniec i zliczanie odczytów/czasu w samym gościu, następnie diagnoza dekodera i I/O na podstawie zakończonego pomiaru. Nie pomijamy SHA1, nie przechodzimy do partycjonowania na podstawie asercji PASS i nie wydłużamy automatycznie kolejnych prób.

## Dowody rzeczywistych prób

- **Win11:** `qemu-x64/win11-prep03/result.json`, SHA256 `583569a6fb835c4e5d505ae3094c12611e1c401b633c08a930a6529fa9d50153`; diagnoza `qemu-x64/win11-prep03/diagnosis.json`, SHA256 `dbeab70d2b311da799e7e1dafd55f145ebbff7c835ce30033f7d80b6ec0070e5`. Źródło `ff5c405bef7ea35e390ec15c26884995f06a590ff94d6ef20bfb8c97781e94a4`, program `7c549710bb6cb6e1f87a8e2e2461fa9849e80fe14ea2ae5b4333e7e6da9cb862`, cel `f9fee8a2d4ada7f707b6204d57450467147830889c164d5a3ef7f779b4953956`. `passed=false`, `timed_out=true`, source/base unchanged.
- **Win10 IA32:** `qemu-ia32/win10-prep01/result.json`, SHA256 `b5aadefd23d8cb19a52fa61ff2e01fa613741b2b5f6b83cf2c88e15b293aba2d`; diagnoza `qemu-ia32/win10-prep01/closed-diagnosis.json`, SHA256 `caba87f2f3aca3ba25c3db74b8f921b06381a36702259dc12c5743a2f61f9f62`. Źródło `338277a79b0905f6bb15786ce29dbd0e11bbdd28d4e0e2a34120237520a5a7b5`, program `0f698ca561fae724b5359b87f2d9189a06a5edfde4d68395bbf80b4c921ddf1d`, cel `4ec8f84614fc837df48fd7db090d4729fa0e25ce9993a3a9fa39239836ae6861`. `passed=false`, `timed_out=true`, source/base unchanged.

Log runnera Win11: `<UEFI_VALIDATION>/runtime/1c23-qemu-win11-prep03.log`; końcowa diagnostyka `<UEFI_VALIDATION>/runtime/1c23-win11-closed-diagnosis01.log`. Logi IA32 i receipty mają ten sam czysty HEAD310cf376. F3 capture dodaje provenance do plików serial/debug po zakończeniu procesu, zachowując wszystkie pierwotne bajty; stdout/stderr otrzymują HEAD przed startem.

## Pamięć, CPU i sektory

Własny smoke: program ze stosem1786194B, stack high-water353816B z1048576B, canaryOK, końcowe alloc_current0. UEFI dostał128MiB RAM, CPUqemu64. To pomiar małego XPRESS, bez pamięci firmware; nie jest pomiarem szczytu pełnego Win11/Win10 ani minimumRAM. W pełnych timeoutach program nie wrócił, więc nie podał końcowego szczytu/stosu — tych liczb nie znamy.

IA32 i BIOS są jawnie budowane dla i486, z audytem bez SSE/CMOV. UEFI IA32 badano na CPUqemu32/128MiB, nie na sprzętowym486. Własny test MBR/PBR przeszedł na486 iPentium/32MiB; pełny nowy klient BIOS nie dostał rzeczywistej próby Windows w tym podejściu. Nie deklarujemy jego minimalnego RAM na podstawie samego linkowania. BIOS instalator mieści payload226660B w limicie245760B; cały slot z bootstrapem ma262144B, obraz1MiB. Osobny BIOS BOOT: payload162672B, obraz4MiB. Asercje układu pamięci i istniejący packer nie zostały poluzowane.

Źródłowe adaptery obsługują512/4096B wobec optycznych2048B. FAT32 ma niezależne testy512/4096B; Windows chkdsk FAT32 wykonano tylko512B. **Zapis docelowego NTFS nadal wymaga512B;4Kn jest jawnie odrzucany przed tablicą partycji.** Nie deklarujemy pełnego zapisu Windows na4Kn.

## Zachowanie danych i zasady

Nie było merge/push/deploy/--force/junctionów ani pracy na fizycznych nośnikach; nic na G:. Nie wykonano nowych pełnych eksportów realnych celów do VHD, ponieważ nie przeszło przygotowanie. Własne formatery/czytniki i BCD nie zawierają Microsoft payload; pliki bootowania mają być pobierane z rozpakowanego Windows dopiero za zaakceptowanymi bramkami.

Nowych obrazów nie usunięto. Usunięte wcześniej cztery kopie VHD1c-1 miały odrębną zgodę F-i; pełna lista z bajtami i SHA znajduje się niżej. Pozostałe zaakceptowane stare raw i wszystkie nowe dowody zachowano. Stare SYS/CER pozostają zagadnieniem integracji — żadnego acpi.sys nie przywrócono do master.

## Zamknięte bramki formatu i odczytu

- **FAT32** — `fat32-small/final01/result.json`, HEAD `a3cff3450cdf39b3aa61e47ce55fa85ea2990e18`, dirty0. Własne obrazy512 i4096B/sektor; każdy108 plików/6 katalogów, niezależne BPB, backup/FSInfo, obie FAT, alokacja, ścieżki i strumieniowe SHA zgodne. Dla512B Windows read-only `chkdsk X:` bez przełączników: exit0, VHD SHA przed/po `64e6596048d7e354f5ab9be44d3984d747d871db3fe0a559ccb42e86552c0ade`, guard rozmiaru316669952B i partycji314572800B od1MiB. Native4Kn: jawnie **nie wykonano**, zwykły VHD przedstawia512B/sektor.
- **Normalizacja VHD** — `fat32-small/normalization01/result.json`, HEAD `4402496fc1d69185897d8a08f4c24d4f44ec490d`, dirty0. Świeży własny dynamiczny VHD, wyłącznie FSCTL_SET_SPARSE(FALSE) pod wyłącznym sprawdzonym uchwytem; SHA kontenera przed/po identyczny, `qemu-img compare` exit0. Niezależny odczyt wszystkich33554432B: SHA `500081ac0da18fb9b5faa7f06d9cdaeefe09d76d0c2f8f4e9e38f8df1a250a67`. Bez montowania, bez usuwania.
- **ISO na NTFS pofragmentowanym przez Windows** — `ntfs-fragmented/final01/result.json`, HEAD `a3cff3450cdf39b3aa61e47ce55fa85ea2990e18`, dirty0. ISO2097152B,512 fizycznych runów, `$ATTRIBUTE_LIST`,3 rekordy rozszerzeń. Niezależny parser: SHA `a06a6a170a91021a2db85531f7850eb3dbf44dd11e5120a3da04d7a60528b71d`, własny optyczny manifest3 wierszy zgodny z7-Zip, native read-only chkdsk exit0. Zero zapisów do źródła. Obrazy wskazane w receipt zachowane; nie otwierano ich w czasie sporządzania fragmentu.
- **REGF/BCD host** — `hive-bcd/final01/result.json`, HEAD `b687ed01844b22c4209a30795d7ae17370aadc69`, dirty0 przed/po. Własny zapis hive odzera/edycja, wszystkie typy, bigdata; niezależny python-registry1.3.1 na oryginałach deny-write, natywne RegLoadAppKey/BCDEdit wyłącznie na kopiach. GPT iMBR qualified device zaakceptowane. EXE SHA `864527bbd67fc8fc77aa08800dc34281e0d1a9ca512305bf697aac0d5ee9c248`. To **nie** jest jeszcze prawdziwa bramka bcdboot na przygotowanym Windows; receipt ma `PENDING_REAL_LAYOUT`. BCDEdit może zmienić własną kopię (Description/TreatAsSystem), oryginał zachowany.

## Zamknięte własne fixture firmware

- **Mały pełny przepływ UEFI** — `fixtures/install-smoke01/smoke-final.json`, HEAD `d9262ed5fe9be84e61cb0e0763e0ec6a79c943ec`, dirty0, PASS. Wyłącznie własne wygenerowane dane: ISO-na-NTFS → pełny blankscan16GiB celu → GPT/ESP/MSR/NTFS → dane. QEMU exit33 w `251.425s`. Cel w nakładce; źródło jako niemodyfikowany RAW, przygotowany snapshot zachowany. Dane nie są Windowsem. Zakończone dwie próby poprzedzające zachowane: readonly IDE odrzucone przed gościem; skan AHCI przekroczył300s przed zapisami. Końcowy transport przygotowania virtio-blk; dla Windows docelowy AHCI.
- **Pamięć własnego smoke** — stack zarezerwowany1048576B, high-water353816B, canaryOK; szczyt alokatora ze stosem1786194B. Są to pomiary programu, bez pamięci firmware. QEMU miał128MiB; to nie jest wyznaczenie minimumRAM dla prawdziwego Windows/WIM.
- **Własne MBR/PBR i protokół handoff** — `fixtures/bootcode01/result.json`, HEAD `81f70fe1df70c005b606d2a5df1f38a806371b7f`, dirty0. CPU486 iPentium,32MiB, oba exit33/PASS; własny32MiB obraz i własny stub, bez Microsoft payload i bez próby Windows. Obie nakładki zgodne z zapisanymi SHA, baza `2bdf7268a59982f8d0787b57f948e4317a0e62e64b2141e53f871e7a705a43d8`. Własne MBR/PBR512B z publicznie opisanym GNU ntldr handoff; źródła/atrybucja w repo.
- **Rzeczywisty readback zamkniętej mapy QCOW** — `hive-bcd/firstboot-map-readback-final01/result.json`, HEAD `63a8cc45cc3f1a45ddb31b35740a4fb94150767b`, dirty0/PASS. `qemu-img map` + ograniczony niezależny adapter odczytał33554432 logiczne bajty własnej powyższej fixture: SHA `2bdf7268a59982f8d0787b57f948e4317a0e62e64b2141e53f871e7a705a43d8` zgodne z raw. Wszystkie SHA bazy/nakładki bez zmian, zero VM i nowych obrazów/eksportów.

## Buildy i małe testy — oddzielne wyniki, bez sumowania

Każdy poniższy log ma HEAD i dirty0 przed/po oraz exit0. Zestawienia nie oznaczają, że wszystkie komendy wykonano na jednym HEAD; ich dokładna proweniencja jest jawna. Wspólne testy importowane przez kilka korzeni nie są dodawane do jednej liczby.

### root UEFI install + prep test

- Wynik: **154/154 (142+12),11/11 kroków; IA32 audit bez SIMD/CMOV/post-i486**; HEAD `d9262ed5fe9be84e61cb0e0763e0ec6a79c943ec`.
- Log: `<UEFI_VALIDATION>/runtime/1c23-uefi-final06.log`; SHA256 `748e0d68ccfef9003cda28e446356bd06e61891736b010bb76b3aa5b934fdc68`.
- Komenda: `<ZIG> build usosprep-install-app usosprep-test -j2 --summary all`.

### BIOS konfiguracja instalatora

- Wynik: **1/1**; HEAD `ec41d1eac177054d525bfba8d5c9a89c31aa4741`.
- Log: `<BIOS_VALIDATION>/runtime/1c23-bios-config-final01.log`; SHA256 `eaf5f7f1c559b0b650c411587fcaa79806237b62d0bd6317d37420f5dae45ab4`.
- Komenda: `<ZIG> test src/prep/bios_install_config.zig`.

### BIOS install i486 build

- Wynik: **PASS; payload226660B, użyte243044B slotu262144B; finalny obraz1048576B**; HEAD `ec41d1eac177054d525bfba8d5c9a89c31aa4741`.
- Log: `<BIOS_VALIDATION>/runtime/1c23-bios-final01.log`; SHA256 `3644b43864e44d121e1dad68f4ca75ed203e40cd71f4a40ea4d8efd951bf8f59`.
- Komenda: `<PYTHON> tools/minios/build_bios_install.py --zig <ZIG> --output <BIOS_VALIDATION>/zig-out/test-assets/usosprep-install-bios.img --work-dir <BIOS_VALIDATION>/zig-out/minios-install-bios`.

### BIOS BOOT konfiguracja

- Wynik: **21/21**; HEAD `698409d26e44f9634903dcf1c2bde77384ee7ab5`.
- Log: `<BIOS_VALIDATION>/runtime/1c23-bios-boot-config-final01.log`; SHA256 `9038afaeccb8f57872eb9a682e6e6849be6d045d1b6ef03d53709d2f9b9856ed`.
- Komenda: `<ZIG> test src/prep/bios_boot_config.zig`.

### BIOS BOOT i486 build

- Wynik: **PASS; payload162672B, użyte179056B slotu; finalny obraz4194304B, bez modułu WIM**; HEAD `698409d26e44f9634903dcf1c2bde77384ee7ab5`.
- Log: `<BIOS_VALIDATION>/runtime/1c23-bios-boot-final01.log`; SHA256 `dd430972421b2252477e1cd4cd7f06cd6df1d9eda75d10d7cb6a490d9ad30549`.
- Komenda: `<PYTHON> tools/minios/build_bios_boot.py --zig <ZIG> --output <BIOS_VALIDATION>/zig-out/test-assets/usosboot-bios.img --work-dir <BIOS_VALIDATION>/zig-out/minios-boot-bios`.

### BIOS/optical host harness

- Wynik: **19/19**; HEAD `698409d26e44f9634903dcf1c2bde77384ee7ab5`.
- Log: `<BIOS_VALIDATION>/runtime/1c23-bios-case-final01.log`; SHA256 `9b637fc5d87c1a9d001a7f1f529f40b77f0fdc38922416e2919b9c5187b2d1e2`.
- Komenda: `<PYTHON> -m unittest tools.tests.test_minios_bios_install_case tools.tests.test_minios_bios_boot tools.tests.test_minios_bios_install tools.tests.test_minios_optical_e2e`.

### BIOS boot-provision host gate

- Wynik: **28/28, bez gościa**; HEAD `ae0ecb9bffea97e985ae350c2f9e8422680be5d5`.
- Log: `<BIOS_VALIDATION>/runtime/1c23-bios-provision-host-final01.log`; SHA256 `def7a82731ec7253765b53b1dfb55e968172992403071e24218bbd6ea4b46fcd`.
- Komenda: `<PYTHON> -m unittest tools.tests.test_minios_bios_boot_provision tools.tests.test_minios_bios_install_case tools.tests.test_minios_bios_boot tools.tests.test_minios_install_firmware -v`.

### BIOS build/optical harness

- Wynik: **14/14**; HEAD `ec41d1eac177054d525bfba8d5c9a89c31aa4741`.
- Log: `<BIOS_VALIDATION>/runtime/1c23-bios-python-final01.log`; SHA256 `8eb5f9d510eb7a490e87234ef5b7d9b39f695e0b6ed4282e24e3fe161868d40c`.
- Komenda: `<PYTHON> -m unittest tools.tests.test_minios_bios_install tools.tests.test_minios_optical_e2e`.

### shared optical/prep build

- Wynik: **exit0; brak osobnego licznika w logu**; HEAD `ec41d1eac177054d525bfba8d5c9a89c31aa4741`.
- Log: `<BIOS_VALIDATION>/runtime/1c23-optical-final02.log`; SHA256 `420c654ec3050f78484119553aeab617a120d6b6df43e155b04d888d1e7368dc`.
- Komenda: `<ZIG> build usosprep-test usosprep-optical -j2`.

### REGF/BCD Zig

- Wynik: **9/9**; HEAD `b687ed01844b22c4209a30795d7ae17370aadc69`.
- Log: `<RUNTIME>/1c23/hive-bcd/zig-tests-final01.log`; SHA256 `1207261df7499143079f67c4239e72d779f6735c1d3da8c67e811e201e01dde5`.
- Komenda: `<ZIG> test src/prep/bcd_tests.zig -O ReleaseSafe --cache-dir runtime/regf-cache`.

### REGF/BCD host EXE build

- Wynik: **exit0**; HEAD `b687ed01844b22c4209a30795d7ae17370aadc69`.
- Log: `<RUNTIME>/1c23/hive-bcd/zig-host-build-final01.log`; SHA256 `de3535b4f0edb0f96bea69d9e2b62cb85b1f6d737df5a9130d9d020fdf3f3a65`.
- Komenda: `<ZIG> build-exe src/prep/bcd_main.zig -O ReleaseSmall --cache-dir runtime/regf-cache -femit-bin=runtime/usosprep-bcd-final.exe`.

### REGF/BCD niezależne/natywne kopie

- Wynik: **PASS, rzeczywisty bcdboot nadalPENDING**; HEAD `b687ed01844b22c4209a30795d7ae17370aadc69`.
- Log: `<RUNTIME>/1c23/hive-bcd/native-final01.log`; SHA256 `71dea50566f513ffcb570905816f02ee7c7f290822266e380b240a9ca60ffd5b`.
- Komenda: `<PYTHON> -I -B tools/minios/bcd_oracle.py --require-clean --exe <WT>/runtime/usosprep-bcd-final.exe --out <RUNTIME>/1c23/hive-bcd/final01 --pwsh <PWSH> --template <SYSTEMROOT>/System32/Config/BCD-Template`.

### UEFI boot write guard/entropy

- Wynik: **19/19**; HEAD `29e9afb135e958a9974d3c9a06e7ac7afb039a5a`.
- Log: `<RUNTIME>/1c23/hive-bcd/boot-guard-final01.log`; SHA256 `a9936416d4c23d39895abc2e98bedfd85dcd391a1460320e589d55c0fb53dc3b`.
- Komenda: `<ZIG> test -O ReleaseSafe --cache-dir runtime/boot-guard-cache src/prep/boot_target_tests.zig`.

### UEFI boot runner/capacity

- Wynik: **21/21**; HEAD `29e9afb135e958a9974d3c9a06e7ac7afb039a5a`.
- Log: `<RUNTIME>/1c23/hive-bcd/boot-runner-python-final01.log`; SHA256 `27c33d1994ee5f253fe7100ee3fa0dd083b92af3ad08964e157b02f84bc273fa`.
- Komenda: `<PYTHON> -B -m unittest tools.tests.test_minios_boot_provision tools.tests.test_minios_boot_capacity tools.tests.test_minios_wim_pool -v`.

### osobny UEFI x64 BOOT build

- Wynik: **exit0;167424B**; HEAD `29e9afb135e958a9974d3c9a06e7ac7afb039a5a`.
- Log: `<RUNTIME>/1c23/hive-bcd/uefi-boot-x64-final01.log`; SHA256 `20255c22b03a887780e563c0b9dbcbe4adfd71415993918568bb0bb92f48ecb6`.
- Komenda: `<ZIG> build-exe -O ReleaseSmall -target x86_64-uefi --cache-dir runtime/boot-build-cache -femit-bin=runtime/usosboot-x64-final.efi --dep ntfs_ro -Mroot=src/prep/uefi_boot_main.zig -O ReleaseSmall -target x86_64-uefi -Mntfs_ro=src/storage/ntfs.zig`.

### osobny UEFI IA32 i486 BOOT build

- Wynik: **exit0;167936B**; HEAD `29e9afb135e958a9974d3c9a06e7ac7afb039a5a`.
- Log: `<RUNTIME>/1c23/hive-bcd/uefi-boot-ia32-final01.log`; SHA256 `afa96f3afd1f2c0706e3a3630ab1ee4e0f5c97ae03e1c79b3e4062a8fffc27c4`.
- Komenda: `<ZIG> build-exe -O ReleaseSmall -target x86-uefi -mcpu i486 --cache-dir runtime/boot-build-cache -femit-bin=runtime/usosboot-ia32-final.efi --dep ntfs_ro -Mroot=src/prep/uefi_boot_main.zig -O ReleaseSmall -target x86-uefi -mcpu i486 -Mntfs_ro=src/storage/ntfs.zig`.

### firstboot/QMP/map/NTFS/capacity

- Wynik: **18/18; udawany lokalny peerQMP, bez VM**; HEAD `63a8cc45cc3f1a45ddb31b35740a4fb94150767b`.
- Log: `<RUNTIME>/1c23/hive-bcd/firstboot-python-final01.log`; SHA256 `87d4755c3119fa762f1ee5bbcd717ca2644e245d9de94090d14d86a32e679916`.
- Komenda: `<PYTHON> -m unittest tools.tests.test_minios_firstboot_map tools.tests.test_minios_firstboot tools.tests.test_minios_boot_capacity -v`.

### readback realnego qemu-img map

- Wynik: **PASS, własne dane32MiB, bez VM**; HEAD `63a8cc45cc3f1a45ddb31b35740a4fb94150767b`.
- Log: `<RUNTIME>/1c23/hive-bcd/firstboot-map-readback-final01.log`; SHA256 `ffaf1a373f1ccf2b28e065243f3af8f37aab99db47ebd1c94fb7b9f7134eadef`.
- Komenda: `<PYTHON> tools/minios/firstboot_map_fixture.py --fixture-result <RUNTIME>/1c23/fixtures/bootcode01/result.json --fixture-sha256 d8cc78449c29426f7b9be574d2af75a663b0347d80536acee65bfe8e335fe52f --qemu-img <QEMU>/qemu-img.exe --out <RUNTIME>/1c23/hive-bcd/firstboot-map-readback-final01`.

## Granice wsparcia i przyjęcie rzeczywistych prób

- **4Kn cel:** ścieżka instalacji Windows wymaga512B/sektor i jawnie odmawia celu4Kn. Oddzielne wsparcie odczytu/hostformatter FAT4096 nie stanowi wyniku instalacji Windows na4Kn. Native4Kn na zwykłym VHD nie był wykonywany.
- **BIOS boot eksperymentalny:** własny PBR wiąże dokładnie zweryfikowany, pojedynczy ciągły run BOOTMGR, maks768 sektorów393216B. W razie fragmentacji, nadmiernego rozmiaru lub niewystarczającej pamięci ma nastąpić odmowa. Późniejsza aktualizacja Windows przenosząca BOOTMGR wymaga ponownego provision. Nie jest to gotowy produkcyjny zamiennik bcdboot/bootsect.
- **Firstboot harness:** ma osobne, domyślnie zamknięte bramki rzeczywistych native/bcdboot/BCD/boot-provision receiptów. Domyślny endpoint600s czeka zdarzeniowo i robi pojedynczy zrzut. Wynik PENDING_REVIEW nigdy automatycznie nie oznacza OOBE. Cztery logi Panther, do32MiB, są odczytywane tylko po zakończeniu QEMU, bez pełnego eksportu/mount. Obecny przyrost2GiB jest ograniczeniem przyjęcia harnessu; przed rzeczywistą próbą prowadzący ma uwzględnić pagefile/hiberfile w rezerwacji, bez przekraczania150GiB puli i100GiB wolnego. Nie uznajemy ewentualnego zbyt małego budżetu za błąd Windows.
- **Pamięć hosta:** MaxRSS89M/19M z rootfinal06 dotyczy procesów testowych na hoście. Nie zastępuje pomiaru alokatora/stosu gościa ani minimumRAM firmware.

## Obrazy i dowody zachowane

- Wszystkie nowe FAT32, normalizacjaVHD, wskazane obrazyfragmented, ownBIOS fixture i smoke (także nieudane poprzednie nakładki/vars/logi) pozostają. REGF/BCD oryginały, natywne kopie, manifesty, finalne EFI, logi i receipty również pozostają. Nie wykonywano sprzątania podczas tego fragmentu.
- Smoke ma w swoim receipt369204765B zachowanych artefaktów przy budżecie419430400B. Jest to historyczny zamknięty pomiar; nie przeliczano i nie sondowano aktywnych zakresów.

## Wcześniej zatwierdzone sprzątanie czterech starych VHD

Jedyna opisywana tu wykonana operacja usuwania pochodzi z osobnej zgody użytkownika `user-2026-10-25-F-i`: `docs/minios-cleanup-accepted-1c1-vhds.json`, statecomplete. Nie jest nową zgodą na dalsze sprzątanie. Dwa źródła raw oraz małe dowody pozostały. Lista exact z receipt:

| Usunięty plik względem runtime | Bajty | SHA256 |
|---|---:|---|
| `1c1/e2e-win11-01/native/converted-fixed.vhd` | 17179869696 | `2d021d863c239f8c77731ae2048e8021049c458d2ba859dd170f14212f52ee4e` |
| `1c1/e2e-win11-01/native/readonly-copy.vhd` | 17179869696 | `2d021d863c239f8c77731ae2048e8021049c458d2ba859dd170f14212f52ee4e` |
| `1c1/e2e-win7-01/native/converted-fixed.vhd` | 6442451456 | `170d49174333d6f562d6777b016e92bb75b54b73cee4cd3fb7fd746a8e460894` |
| `1c1/e2e-win7-01/native/readonly-copy.vhd` | 6442451456 | `170d49174333d6f562d6777b016e92bb75b54b73cee4cd3fb7fd746a8e460894` |

Razem dokładnie47244642304B. Dowody/logi/manifesty/receipt nie były usuwane; ten fragment nie weryfikował ponownie dużych obrazów.

## SYS/CER — warunek integracji nadal otwarty

Audyt `docs/minios-sys-cer-audit-1c23.json`: rzeczywisty master`0ba50f6e`, gałąź w chwili audytu`97378ead55277dafee13852ce80e2ac79f823489`. Master34, branch74, różnica40 legacy branch-only; szczegółowe ścieżki/bloby są w JSON. To audyt historycznie śledzonych rozszerzeń, nie twierdzenie, że wszystkie są własnością Microsoftu. Integracja nie może przywrócić starych branch-only plików, szczególnie `acpi.sys`; SYS/CER mają pozostać poza gitem zgodnie z master. Nie wykonano merge/push/deploy ani czyszczenia historii w ramach tego fragmentu.

## Commity po zaakceptowanym 1c-1

Historia `2669a0bc..63a8cc45cc3f1a45ddb31b35740a4fb94150767b`, od najstarszego do najnowszego; lista informacyjna, nie dodatkowy wynik testów.

- `1f4f9fb1` fix(minios): accept UDF System ICB attribute
- `2563a25c` fix(minios): try redundant UDF anchors after invalid primary
- `dfd176ff` chore(minios): guard the accepted four-copy VHD cleanup
- `d0c42c4d` fix(minios): skip and count unsupported optical entries
- `ce74df14` feat(minios): add offline REGF hive writer with segmented values
- `37236c64` feat(minios): enforce optical tree budget in shared walker
- `4e760b39` fix(minios): retain original optical stream error in diagnostics
- `c12cab4a` feat(minios): diagnose ESD and split WIM optical sources
- `97378ead` feat(minios): format FAT32 and stream ESP files with bounded buffers
- `d6cf0429` chore(minios): record approved VHD cleanup and actual master payload audit
- `a6e43865` refactor(minios): bound optical stack copies and test disk sector sizes
- `7fb928c1` test(minios): add independent FAT32 and guarded read-only Windows gates
- `0fc6c243` feat(minios): resolve fragmented NTFS ISO streams through attribute lists
- `ff4c29f8` perf(minios): retain aligned FAT32 stream batches for firmware IO
- `66937660` test(minios): create Windows-fragmented ISO on guarded virtual NTFS
- `5a43fe1c` test(minios): verify Windows-fragmented NTFS ISO with independent parser
- `bde15be8` fix(minios): allocate full final REGF big-data segment for Windows
- `3ebddf1d` fix(minios): sign every sector of the complete FAT32 boot record
- `12b6afb4` test(minios): validate fragmented source geometry and AL bounds
- `7e0c9176` fix(minios): skip optional ISO associated streams during traversal
- `746f9223` fix(minios): bound registry lists before IA32 byte arithmetic
- `f5dad097` feat(minios): build qualified GPT and MBR BCD stores offline
- `17bc47b4` fix(minios): create ordinary nonsparse VHD for native NTFS fixture
- `3a5f05ac` perf(minios): validate bounded blank VHD in native byte loop
- `549f87ca` feat(minios): authorize blank disks and plan Windows GPT and MBR layouts
- `627f2880` fix(minios): validate hive offsets before 32-bit additions
- `004c0799` test(minios): compare required BCD route against native bcdboot
- `9efff0c1` test(minios): recheck retained fragmented VHD read-only on clean build
- `189f4f3a` feat(minios): resume validated ESP allocation across preparation gates
- `5f753d01` fix(minios): fall back when primary UDF anchor is unreadable
- `67993576` fix(minios): cap fragmented NTFS run allocation precisely
- `57a05caa` feat(minios): prepare Windows partitions after complete WIM preflight
- `8712f52b` refactor(minios): use shared bounded optical walker in host manifests
- `24493e30` docs(minios): document optical follow-ups and bounded NTFS source reads
- `b687ed01` test(minios): bind BCD oracle to clean final state and executable
- `a3cff345` fix(minios): normalize sparse VHD copies before the FAT32 Windows gate
- `f7427b6d` feat(minios): apply ISO through guarded Windows disk preparation
- `24b1c2b8` feat(minios): guard fresh VHD normalization and independently read dynamic disks
- `4402496f` feat(minios): prepare Windows disks from ISO on NTFS in UEFI
- `b3333ed6` refactor(minios): keep optical error unions small on firmware
- `d3232b66` refactor(minios): open firmware ISO source in tracked heap
- `e9ce2af7` perf(minios): mount installer ISO directly into tracked heap
- `ca52647c` feat(minios): provision UEFI boot files from applied Windows NTFS
- `e993fac0` feat(minios): verify multipartition installs through one dynamic VHD
- `6c892464` refactor(minios): avoid large NTFS constructor error constants
- `2c5d1586` feat(minios): add isolated gated UEFI boot provisioning client
- `03341198` refactor(minios): derive disk identities with shared SHA256 expansion
- `ffd29db4` build(minios): add separately gated UEFI boot provisioning clients
- `9170d183` feat(minios): guard real bcdboot on an isolated virtual child
- `61769800` refactor(minios): keep WIM metadata validation errors small
- `09e3f524` perf(minios): use bounded heap sort for unique metadata keys
- `fa8a180a` feat(minios): build an isolated i486 BIOS install client
- `ec41d1ea` test(minios): allow a bounded three GiB optical source pack
- `e4821fc9` fix(minios): bind FAT fixtures to the approved image pool
- `17b48687` refactor(minios): share bounded read-only boot source inventory
- `f3d59d8a` feat(minios): provision experimental BIOS boot files with run binding
- `a92ca8ca` fix(minios): write target marker without qemu-io path quoting
- `38735827` feat(minios): add own BIOS chain-loader templates and handoff fixture
- `ea63f333` test(minios): smoke firmware installation with small own data
- `a9d9c492` fix(minios): expose readonly install source through virtio block
- `81f70fe1` fix(minios): retain IDE overlays for BIOS handoff fixture
- `1455b901` feat(minios): add separate guarded BIOS boot provisioning client
- `edbf36e9` fix(minios): restrict UEFI boot writes to ESP and use short control names
- `0c409741` fix(minios): charge bounded growth within closed VM reservations
- `29e9afb1` feat(minios): gate UEFI boot provisioning on pinned native receipts
- `d9262ed5` perf(minios): use virtio during verified target preparation
- `698409d2` test(minios): add explicit BIOS preparation firmware harness
- `310cf376` test(minios): pin completed guest captures to the clean build
- `b4c7115d` test(minios): pin BIOS preparation entropy and capture provenance
- `ae0ecb9b` test(minios): gate BIOS boot provisioning on actual native and BCD proofs
- `241618fc` test(minios): budget bounded first Windows boot overlays
- `63a8cc45` feat(minios): gate first Windows boot with one QMP endpoint

## Końcowa pula i lista do decyzji o usunięciu

Po zamknięciu wszystkich gości: **68.89/150GiB** (zamknięte pliki plus konserwatywne768MiB rezerwy starych nietykanych zakresów), wolne K: **159.98GiB**. Minimum100GiB zachowane. Nowy etap: 409 plików przed samym inwentarzem, 12793324398B; **51 obrazów, 12576913408B**.

Pełny inwentarz `final-logs/closed-images.json`, SHA256 `d2616c3153f982895eae99cf0db3dd65fb0532d557e81f01cb6b5600ebefce13`; końcowa kontrola `final-logs/closed-capacity.json`, SHA256 `09fde74e08614ba924a9cd9158a77ae34d102c994d4c7f166d9df377e60eb5b2`. Żaden wiersz poniżej nie jest zgodą na usunięcie. Wszystkie pozycje: **zachować do wyraźnej akceptacji użytkownika**; małe logi/manifesty/receipt pozostają dowodem także po ewentualnym późniejszym cleanup. Źródła do ponownych prób najlepiej pozostawić do rozstrzygnięcia blokady.

| Kandydat do usunięcia dopiero po zgodzie (względem1c23) | Bajty | SHA256 | Dowód zachować |
| --- | ---: | --- | --- |
| `fat32-small/final01/fat32-4096.raw` | 316669952 | `491b627ad3c59c95d938a8e6cd2fd475e38501be7e5931777d5b0b012b6d2dcb` | `fat32-small/final01/result.json` |
| `fat32-small/final01/fat32-512-qemu.vhd` | 6296064 | `64e6596048d7e354f5ab9be44d3984d747d871db3fe0a559ccb42e86552c0ade` | `fat32-small/final01/result.json` |
| `fat32-small/final01/fat32-512.raw` | 316669952 | `ce03c8c973b4892ec76c43c6d2bd34d19dcf73f791f051b07c6422d707c2e601` | `fat32-small/final01/result.json` |
| `fat32-small/final01/fat32-512.vhd` | 6296064 | `64e6596048d7e354f5ab9be44d3984d747d871db3fe0a559ccb42e86552c0ade` | `fat32-small/final01/result.json` |
| `fat32-small/normalization01/fresh-export.vhd` | 6295552 | `29b413cebdbe23e69cb0dbe943c304bb0dfe6b9284343c64ebc3c5736c0d4c78` | `fat32-small/normalization01/result.json` |
| `fat32-small/normalization01/known.raw` | 33554432 | `500081ac0da18fb9b5faa7f06d9cdaeefe09d76d0c2f8f4e9e38f8df1a250a67` | `fat32-small/normalization01/result.json` |
| `fixtures/bootcode01/486.qcow2` | 197120 | `f1d6a8aafa4bd04d8c1f9edc144baade25b20c823ffe384fd559a86ba8282cd6` | `fixtures/bootcode01/result.json` |
| `fixtures/bootcode01/own-abi.raw` | 33554432 | `2bdf7268a59982f8d0787b57f948e4317a0e62e64b2141e53f871e7a705a43d8` | `fixtures/bootcode01/result.json` |
| `fixtures/bootcode01/pentium.qcow2` | 197120 | `f1d6a8aafa4bd04d8c1f9edc144baade25b20c823ffe384fd559a86ba8282cd6` | `fixtures/bootcode01/result.json` |
| `fixtures/install-smoke01/own-install.iso` | 3659776 | `a9cede41aafaf7cf6fa0b8220bf146e4b69f81ef0d9c07be2b355e4821e16a97` | `fixtures/install-smoke01/smoke-final.json`; `fixtures/install-smoke01/result.json` |
| `fixtures/install-smoke01/firmware/boot-base.raw` | 68157440 | `630c9835416e7bd1984147f2db586f291e2273f7cde0adedde8020f50e44f1b7` | `fixtures/install-smoke01/firmware/result.json`; `fixtures/install-smoke01/firmware/marker-write.log` |
| `fixtures/install-smoke01/firmware/boot.qcow2` | 197120 | `a69f8898dae99e13d387665da6a231cca31a8c612f3c1e9c24a547a6608375f7` | `fixtures/install-smoke01/firmware/result.json`; `fixtures/install-smoke01/firmware/marker-write.log` |
| `fixtures/install-smoke01/firmware/target-base.qcow2` | 459264 | `7dec783cd061cec174ce131195a575ce5f2fb6f788b1d0555be1bae7dded90f7` | `fixtures/install-smoke01/firmware/result.json`; `fixtures/install-smoke01/firmware/marker-write.log` |
| `fixtures/install-smoke01/firmware/target.qcow2` | 197120 | `2bac759c5d8d60f36ad4fdaee13a13e39f4ac5afbf3eb88b04ed08289c08a1ef` | `fixtures/install-smoke01/firmware/result.json`; `fixtures/install-smoke01/firmware/marker-write.log` |
| `fixtures/install-smoke01/firmware/vars.fd` | 540672 | `5d2ac383371b408398accee7ec27c8c09ea5b74a0de0ceea6513388b15be5d1e` | `fixtures/install-smoke01/firmware/result.json`; `fixtures/install-smoke01/firmware/marker-write.log` |
| `fixtures/install-smoke01/firmware-retry01/boot-base.raw` | 68157440 | `8e7854f64e61aaa7d495d27412dd8330849cb1f8dc26d5815ab46e3d5683b1a3` | `fixtures/install-smoke01/firmware-retry01/result.json`; `fixtures/install-smoke01/firmware-retry01/marker-write.log` |
| `fixtures/install-smoke01/firmware-retry01/boot.qcow2` | 720896 | `c0cf19096968425ae91f3024ef6454567f6b9e06be9f20bd96990470431441b3` | `fixtures/install-smoke01/firmware-retry01/result.json`; `fixtures/install-smoke01/firmware-retry01/marker-write.log` |
| `fixtures/install-smoke01/firmware-retry01/target-base.qcow2` | 459264 | `4ebf1565f45dda00ddb7e8a9df94ec8008fbff9cf8bb80c7b5445c9205d859ce` | `fixtures/install-smoke01/firmware-retry01/result.json`; `fixtures/install-smoke01/firmware-retry01/marker-write.log` |
| `fixtures/install-smoke01/firmware-retry01/target.qcow2` | 197120 | `792a2aa0344830ca9af06b7168b73ec53335fd99d6e7fa569ff8b3d75fbf0a60` | `fixtures/install-smoke01/firmware-retry01/result.json`; `fixtures/install-smoke01/firmware-retry01/marker-write.log` |
| `fixtures/install-smoke01/firmware-retry01/vars.fd` | 540672 | `5dda032ab3fd6b9f109cb105768baa52caa163f81e206d921f4f25e3610a1071` | `fixtures/install-smoke01/firmware-retry01/result.json`; `fixtures/install-smoke01/firmware-retry01/marker-write.log` |
| `fixtures/install-smoke01/firmware-retry02/boot-base.raw` | 68157440 | `8626e5601f0dbc3ba9204f2f31f670ec86f2a4f758815ed06ff16ab90714721a` | `fixtures/install-smoke01/firmware-retry02/result.json`; `fixtures/install-smoke01/firmware-retry02/marker-write.log` |
| `fixtures/install-smoke01/firmware-retry02/boot.qcow2` | 720896 | `885a40c533c5d7472d7359587427551982f0abc96b7f8a0aa7d12d7e970f2edb` | `fixtures/install-smoke01/firmware-retry02/result.json`; `fixtures/install-smoke01/firmware-retry02/marker-write.log` |
| `fixtures/install-smoke01/firmware-retry02/target-base.qcow2` | 459264 | `036c7f35478589cba49610415a07508a6ccea3a1d5a1e4ead61c0b97d143c7b2` | `fixtures/install-smoke01/firmware-retry02/result.json`; `fixtures/install-smoke01/firmware-retry02/marker-write.log` |
| `fixtures/install-smoke01/firmware-retry02/target.qcow2` | 21234176 | `8357a067626d5f74ac3d43ec7bd278b89799d78a6eba759c6591941ec1f0798c` | `fixtures/install-smoke01/firmware-retry02/result.json`; `fixtures/install-smoke01/firmware-retry02/marker-write.log` |
| `fixtures/install-smoke01/firmware-retry02/vars.fd` | 540672 | `b0bcd83a209785521235492decc423f5cd4dc451e7ab309eabf46379f7fcf062` | `fixtures/install-smoke01/firmware-retry02/result.json`; `fixtures/install-smoke01/firmware-retry02/marker-write.log` |
| `fixtures/install-smoke01/pack/blank-base.qcow2` | 328192 | `8ad05f3422ce43ff793bc4bc9e876313c6672482e2150238af3784b43bdde114` | `fixtures/install-smoke01/pack/result.json` |
| `fixtures/install-smoke01/pack/target.raw` | 134217728 | `5e29c6d133adb175960fac8de9cc8bbc38414e3a72c40816b927bd4b31f51fa8` | `fixtures/install-smoke01/pack/result.json` |
| `fixtures/install-smoke01/pack/test-cow.qcow2` | 197120 | `d1c8afb49ef6e7548906ffcb46e6080103105767378ebf99a04002b85932dd9a` | `fixtures/install-smoke01/pack/result.json` |
| `ntfs-fragmented/dev01/own.iso` | 2097152 | `a06a6a170a91021a2db85531f7850eb3dbf44dd11e5120a3da04d7a60528b71d` | `final-logs/closed-evidence-fragment.md` |
| `ntfs-fragmented/dev01/native/windows-fragmented.vhd` | 536871424 | `32218735d4a3a4b9215d4f470c6822970022b81ed944130b69078a655c71197a` | `ntfs-fragmented/dev01/native/receipt.json` |
| `ntfs-fragmented/dev02/own.iso` | 2097152 | `a06a6a170a91021a2db85531f7850eb3dbf44dd11e5120a3da04d7a60528b71d` | `ntfs-fragmented/dev02/result.json` |
| `ntfs-fragmented/dev02/source.raw` | 536870912 | `e5230c2e170f0007dd04da4312ecb1d216b750769da889c2395b27ee1c1bdf60` | `ntfs-fragmented/dev02/result.json` |
| `ntfs-fragmented/dev02/native/windows-fragmented.vhd` | 536871424 | `bc462cff704e5ac7279933e30e7f8782415a247291cd5e3d55ad6dae0deec3cd` | `ntfs-fragmented/dev02/native/receipt.json` |
| `qemu-bios/source-win7-01/blank-base.qcow2` | 328192 | `293066d2ef9caef74bc11fe6b4425285e1d65d9311f89e1a0362e3080ee50b5a` | `qemu-bios/source-win7-01/result.json` |
| `qemu-bios/source-win7-01/target.raw` | 3221225472 | `d13ede2478937cf60039c10e253f1131394524445a544539349225b23536e138` | `qemu-bios/source-win7-01/result.json` |
| `qemu-bios/source-win7-01/test-cow.qcow2` | 197120 | `9aecf9a5f60d4daf98fb45bedb62993510bb711f2c4c5c1f20103c14e6fd5296` | `qemu-bios/source-win7-01/result.json` |
| `qemu-ia32/win10-prep01/boot-base.raw` | 68157440 | `a7a69e9b033762f0b07b440315263d7aff4657eb8e5e9cf4a02de9eb8f73bd94` | `qemu-ia32/win10-prep01/closed-diagnosis.json`; `qemu-ia32/win10-prep01/result.json`; `qemu-ia32/win10-prep01/marker-write.log` |
| `qemu-ia32/win10-prep01/boot.qcow2` | 720896 | `b99bf124a2b108a846787238594f0893b2bc42f9426b870f5e5e5dbf8b68e42b` | `qemu-ia32/win10-prep01/closed-diagnosis.json`; `qemu-ia32/win10-prep01/result.json`; `qemu-ia32/win10-prep01/marker-write.log` |
| `qemu-ia32/win10-prep01/target-base.qcow2` | 459264 | `097987c91a9083b0b3edf7675e5fe4f0b48c84b9337e8495abc6322fa46d0b60` | `qemu-ia32/win10-prep01/closed-diagnosis.json`; `qemu-ia32/win10-prep01/result.json`; `qemu-ia32/win10-prep01/marker-write.log` |
| `qemu-ia32/win10-prep01/target.qcow2` | 197120 | `4ec8f84614fc837df48fd7db090d4729fa0e25ce9993a3a9fa39239836ae6861` | `qemu-ia32/win10-prep01/closed-diagnosis.json`; `qemu-ia32/win10-prep01/result.json`; `qemu-ia32/win10-prep01/marker-write.log` |
| `qemu-ia32/win10-prep01/vars.fd` | 540672 | `d26f0d90cc4b2b210da46eb7e7b446d7ac58c62cd9feae24b3dbabad33102568` | `qemu-ia32/win10-prep01/closed-diagnosis.json`; `qemu-ia32/win10-prep01/result.json`; `qemu-ia32/win10-prep01/marker-write.log` |
| `qemu-x64/win11-prep02/boot-base.raw` | 68157440 | `3da1882818549dd47ac00d1c2cc83664c8bac3791de7b2870d99ade9556219c5` | `qemu-x64/win11-prep02/marker-write.log` |
| `qemu-x64/win11-prep02/target-base.qcow2` | 197120 | `d540e67a60a1b940ac9dda21e516b9570e8db916d2fb1a12766d3d67453cc573` | `qemu-x64/win11-prep02/marker-write.log` |
| `qemu-x64/win11-prep03/boot-base.raw` | 68157440 | `12d83030a79aed6d5aed38ad635ceaa1d8a514928edcbc62132bf1cb6c9b98df` | `qemu-x64/win11-prep03/diagnosis.json`; `qemu-x64/win11-prep03/result.json`; `qemu-x64/win11-prep03/marker-write.log` |
| `qemu-x64/win11-prep03/boot.qcow2` | 720896 | `8257b6621e1fb2e545efdff8b4a2990c48a564ab746e55ef552a83914d548fd0` | `qemu-x64/win11-prep03/diagnosis.json`; `qemu-x64/win11-prep03/result.json`; `qemu-x64/win11-prep03/marker-write.log` |
| `qemu-x64/win11-prep03/target-base.qcow2` | 459264 | `c5542cb2f9064f1d3633c3e4a6cf13d5493bfddfb0b0f8ea5813c4eabc60e233` | `qemu-x64/win11-prep03/diagnosis.json`; `qemu-x64/win11-prep03/result.json`; `qemu-x64/win11-prep03/marker-write.log` |
| `qemu-x64/win11-prep03/target.qcow2` | 197120 | `f9fee8a2d4ada7f707b6204d57450467147830889c164d5a3ef7f779b4953956` | `qemu-x64/win11-prep03/diagnosis.json`; `qemu-x64/win11-prep03/result.json`; `qemu-x64/win11-prep03/marker-write.log` |
| `qemu-x64/win11-prep03/vars.fd` | 540672 | `b0bcd83a209785521235492decc423f5cd4dc451e7ab309eabf46379f7fcf062` | `qemu-x64/win11-prep03/diagnosis.json`; `qemu-x64/win11-prep03/result.json`; `qemu-x64/win11-prep03/marker-write.log` |
| `source-ntfs/win10-01/blank-base.qcow2` | 328192 | `f7f8bf234e583441bfa5d11b4ec4be3047f0ad409bada1f04d8400cae81ca50d` | `source-ntfs/win10-01/result.json` |
| `source-ntfs/win10-01/target.raw` | 6442450944 | `338277a79b0905f6bb15786ce29dbd0e11bbdd28d4e0e2a34120237520a5a7b5` | `source-ntfs/win10-01/result.json` |
| `source-ntfs/win10-01/test-cow.qcow2` | 197120 | `5b4c4ed9fd5192d66865a210ed05c6f3aefa93c9708bfa020d1c89a4af62fb9f` | `source-ntfs/win10-01/result.json` |

## STOP

Pierwsza rzeczywista bramka nie przeszła. Nie kontynuować do native, bcdboot, bootfiles ani Windows firstboot bez kolejnego zlecenia. 1c-2/1c-3 pozostaje niezaakceptowane; ten raport zamyka bieżące podejście z diagnozą i zachowanymi dowodami.
