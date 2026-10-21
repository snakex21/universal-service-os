# Ukończona diagnoza R17: Date/Time

R17 r17-nt351-wks-diag był starym wariantem keyless NT3.51 przed naprawą UTC. NormalnyUSOS zakończył przygotowanie błędem start2/15min, zdarzenie2348.03s; elapsed2350.68s, QMPquit/rc0, brak first-logon. Końcowy zewnętrzny endpoint pokazuje Preparation stopped. Rc0 jest wyłącznie stanem narzędzia, nie WindowsPASS. Nie wykonywano HID na stronie błędu.

Stary listener po przejściu kontekstu był już niedostępny. Przywrócony pasywny ReadDirectoryChangesW odebrał istniejące endpoint.png i cleanup.json; dopiero potem odczytano wynik i zakończone logi. Obrazy target/stick/vars zostały już poprawnie usunięte przez wcześniejszy cleanup.

Automatyczny failurecollector historycznie zakończył się Unexpected evidence transport line. Zachowano ten wynik. Ukończony serial read-logs-mtools/1024-qemu64-evidence maSHA25664104d524077568695a340d0a98218888fadcf212f93d9a27ba5e48cae7c0597. Narzędzie tools/tests/recover_nt3_r17_transport.py akceptuje wyłącznie ten całyhash, stałe granice i11konkretnych fragmentów echa na dokładnych liniach. Zachowuje wszystkie76znaków pełnej linii payloadu. Nie używa validate=False, arbitralnego filtrowania ani obcinania końca archiwum.

Pełne57362B tgz maSHA2565e6ba4f5932be7a6473669d89da903f8a8b6de013098cbbc3c3be6b7196c3252. Kanonicznybase64, pojedynczygzip/EOF/CRC i dwa zerowe bloki końca tar oraz wyłącznie zerowe dopełnienie przeszły weryfikację. Wykorzystana ścisła evidence_archive.py maSHA25647bd62d57e316604b0942454f45a70d3f7fd022e4f35ddc127c3e2cf32d92728. Nie uruchomiono kolejnejVM ani nie zmieniono aktualnego dekodera.

Odzyskano13wygenerowanych plików do artifacts/coverage/r17-historical-recovery. Run-2/screen.png pokazuje rzeczywistą stronę Setup Date/Time, strefę `(GMT) Greenwich Mean Time; Dublin, Edinburgh, London` i przyciskOK. Jest to konkretny dowód czekającego modala w drugim starcie. Potwierdza wcześniejszą diagnozę staregoUTCwariantu; nie dowodzi kernel/HID/LAN ani pulpitu. Późniejsze R18f ma odrębny dowód funkcjonalny i nie zastępuje tego błędu historycznego.

Regresje obejmują rzeczywisty kształt fragmentów, pełne zachowanie payloadu, odmowę dodatkowych/brakujących znaków, obowiązek całegohasha i odzysk dokładnego zakończonego transportu. Nie rozszerzają polityki dekoderów dla przyszłych prób. AktywnyR20 pozostaje niezmieniony.
