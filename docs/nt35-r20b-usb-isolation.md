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
