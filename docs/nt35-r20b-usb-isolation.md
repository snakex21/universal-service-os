# R20b: izolacja wejścia USB w zainstalowanym NT 3.5

R20 zakończył świeżą instalację przez normalne USOS i osiągnął Program Manager
Version 3.5. Ręczne działania dały DHCP, dopasowany ICMP oraz UDP/TCP DNS.
Pierwszy stock ping z timeoutem 5000 ms dał 2/3 odpowiedzi (2003/2003 ms),
osobno oznaczony warm ping 3/3 (2614/2003/2003 ms). Nie jest to dowód niskiej
latencji ani działania USB bez zastępczej ścieżki PS/2.

R20 operator-16.png pokazuje native safe-to-power-off, potem QMP quit/rc0 i
cleanup.json. Pięć własnych plików kolektora jest kompletne. Zainstalowany SYS
ma dokładnie e1aa69a3ec8e3da802013131abbb6fefc9f466da6f4eeb66fe15ec47e60421c5.
Transport sprawdzono ponownie bez VM przez ścisłe single-gzip/tar-end;
`r20-strict-transport-revalidation/validation.json` przypina serial i archiwum.
Startowy matrix to c0c5ab26; późniejszy evidence_archive.py ma SHA256
47bd62d57e316604b0942454f45a70d3f7fd022e4f35ddc127c3e2cf32d92728.
Nie przypisujemy całej operacji jednego niezmiennego commita narzędzi.

Zatrzymany target jest zachowany przez wcześniej utworzony hardlink
`G:\USOS-Kolekcja\_vm\r20-nt35-preserved\target.qcow2`, SHA256
b945955ba47344d292e443206e497164208c9a73ae13d45246c28934823b99ac.
SYSTEM ma rzeczywiście REGF 1.2, Current/Default=1, czyste sekwencje/checksum.
Klasy i USB mają Start1, klasy nie mają DependOnService/DependOnGroup;
obie mają ConnectMultiplePorts1 i MaximumPortsServiced3.

Nowy `r20b-nt35-usb-isolation` ma wyłącznie zmianę istniejącego DWORD
ControlSet001\Services\i8042prt\Start z 1 na 4 przy offset93292. Pełne porównanie
treści i bajtów hiva, readback plików i qemu-img compare przeszły. Bazowy obraz
pozostał identyczny. Zamrożony USB nadal ma SHA256
2d4557439d7c60f7e0d5cc53d36467cbc36ae24596eb614e078059ddc718cfe1.
Surowy scratch usunięto; Microsoft hiva ani binariów nie eksportowano.

Rozruch używa tego samego q35 z sprzętowo obecnym i8042, EPYC-Rome/2 CPU,
2048 MiB, firmware, AHCI, jedynego igb/MAC oraz wirtualnego USB kbd/mouse.
NVRAM jest kopią zatrzymanego R20, stick jest nowym overlay zachowanego
prawdziwego sticka. Target jest osobnym overlay; backing jest tylko czytany.
Jednorazowy standardowy RAM guard poprzedza uruchomienie. Capture ma limit8MiB.
Jeden endpoint po300s i ręczne akcje z osobnymi PNG zastępują polling.

Plan oceny: logowanie i Run przez USB; odpięta klawiatura nie otwiera Run,
ponownie podpięta otwiera; po odpięciu myszy klawiatura nadal obsługuje pulpit
i Run, po podpięciu ruch oraz osobny klik myszy działają. Nie wyciągamy wniosku
z samego koloru ekranu. Następnie native shutdown, QMP quit/rc0, kolektor oraz
stopped readback potwierdzający Start4 i niezmienione SYS. Overlay/vars/stick
pozostają do oceny. Automatyczne result flags nie stają się PASS od statusu.


## Wynik R20b

R20b zakończony rc0 po native safe-shutdown (operator21), elapsed992.75s.
01/02: USB CtrlAltDel i Enter dają logowanie oraz Program Manager Version3.5.
03/04: odpięta klawiatura i próba AltF/R nie dają Run. 05/06: po podpięciu
AltF/R otwiera Run. 07–09: przy odpiętej myszy pozostała USBklawiatura otwiera
Run, potem go zamyka i otwiera File na widocznym pulpicie. Jednolity teal po
remove nie jest dowodem awarii. 10–13: ponowne podpięcie myszy, dwa faktyczne
ruchy oraz osobny klik na Browse otwierają dialog Browse.

14 zachowuje nieudany wpis zaraz po zamknięciu Browse: zabrakło początkowego c
w cmd /k. Nie przypisano przyczyny; 15 po jawnym zaznaczeniu otwiera CMD.
Nie usuwamy tej obserwacji z oceny używalności. Ręczne próby potwierdzają
ścieżkę USB po replug; nie obejmują MSC, huba, fizycznego sprzętu ani Server.

W tym samym rozruchu TESTNET wykonał się przez USBklawiaturę. Logger ICMP1s
ma rzeczywisty FAIL11010, zachowany osobno od native ping5000ms3/3 z RTT
1322/2003/2003ms. UDP DNS ma dns_match1/IDE22A iE2F6, TCP DNS ID582D;
HTTP68k.news200. Gość potwierdza DHCP10.0.2.15/24, router/server10.0.2.2,
DNS10.0.2.3/MAC52:54:00:55:53:01. Capture181ramek/31714B ma SHA256
05b253bad400113b0b51069bf2c749b5249c6200cd7d3a2539b25aac3ea4ad4e;
REQUEST/ACK1/2 mają ten sam XID692178252 i spójne parametry dzierżawy86400s.
To renew-only, strictDORA=false pozostaje. Około2s opóźnienia jest jawną usterką.

Pierwszy kolektor odmówił przed spawnem, bo wynik wskazywał mój worktree,
a importowany kolektor dopuszcza wyłącznie artifacts/coverage matrix.
Historyczny result.collection_error zachowano. Jedyny kolejny odczyt readonly
Linux/QEMU zebrał5/5 tekstów oraz zgodny hash SYS pod
matrix/artifacts/coverage/nt35-stopped-r20b/own-evidence. Nie uruchamiano
ponownie Windows. Odtwarzalny runner poprawiono dla przyszłego użycia;
nie przypisujemy tej poprawki zakończonej próbie6d2a2002.

Stopped readback potwierdził REGF1.2/CurrentDefault1/i8042prtStart4 oraz
niezmienione USB i LAN; original backingb945...b99ac pozostał identyczny.
Overlay SHA256e8edf8907be529bfa84454661bffea50b1ec20a51231572a3bd47a43046cb446.
Własna ocena artifacts/nt35-network/r20b-usb-evaluation.json zawiera hashe
konkretnych klatek, pełne granice dowodu i historyczny błąd kolektora.
Automatyczne installed_runtime_pass/usb_path_pass pozostają niezmienione.
