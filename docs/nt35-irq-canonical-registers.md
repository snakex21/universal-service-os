# NT 3.5: kwalifikacja poprawionych rejestrów igb

W zainstalowanym NT 3.5 Workstation ten sam standardowy ping bramy zmienił
wynik z około 2003 ms na **3/3 odpowiedzi time<10ms**. Logger ICMP z limitem
1 s, wcześniej FAIL 11010 w R20b, teraz ma PASS status=0, replies=1, rtt=0 ms,
echo_match=1. To kwalifikacja własnego sterownika na zachowanym R20b,
bez nowej instalacji, zmiany cache, USB/hubów ani fizycznego sprzętu.

## Wąska zmiana sterownika

`fix/nt35-net-irq` ma bazę `bf7c47749008ca02fbda3e740f3006de83a12f57`
z `fix/nt35-net`. Istniejący worktree `nt35-net` nie był edytowany.
Zmieniono tylko cztery adresy legacy interrupt registers wspólnego backendu:

| Rejestr | Poprzedni offset | Poprawiony offset |
|---|---:|---:|
| ICR | 0x1500 | 0x00C0 |
| IMS | 0x1508 | 0x00D0 |
| IMC | 0x150C | 0x00D8 |
| IAM | 0x1510 | 0x00E0 |

Pierwotne definicje:
[Intel Linux igb/e1000_regs.h](https://github.com/torvalds/linux/blob/master/drivers/net/ethernet/intel/igb/e1000_regs.h)
i [QEMU e1000x_regs.h](https://github.com/qemu/qemu/blob/master/hw/net/e1000x_regs.h).
Extended EIM* i GPIE pozostają w swoich poprzednich miejscach. Nie zmieniono
polityki ISR/shared line, fallback CheckForHang, interwałów, importów ani ABI.
Diagnoza root R25 wykazała brak zapisu canonical IMS w poprzednim wariancie.
NT35 nie otrzymało osobnego śladu MMIO; jego wynik nie jest deklaracją takiego
pomiaru ani fizycznym testem I210/I211.

WDK7.1 `build35.py --out artifacts/nt35-irq-build02` z istniejącego WDK zbudował
`usosnet35.sys`: **16 384 B**, SHA-256
`d94ec3e28014a98b6eacdcb75c5b6bc4324a68af814dc00ec8fb574f99fe4c85`.
PE native i386 3.10, NDIS 3.0/60 B characteristics, EthDB+0xD8, 27 importów
wyłącznie z oryginalnego NDIS35. NT351/NT4/NDIS5 SYS pozostały niezmienione.

`build02/build.json` przypina rzeczywiste źródła kompilacji. Kompilowany plik
C miał LF (SHA-256 854870c97be6304c7d96a436550475720accff99243291824262ea6ebace9eff).
W śledzonym pliku zachowano niezmienione oryginalne CRLF poza małym blokiem
poprawki (SHA-256 886bbefee4a11a16c668291ff9765fde6bcf5029dce4f9d5b895c6326a106044).
Pełne porównanie tekstu po odczycie uniwersalnych zakończeń linii jest identyczne;
`source-byte-review.json` jawnie rozróżnia te dwa hashe. Nie przypisuje się
binarce innego surowego źródła niż zapisane w rzeczywistym build02.
Wybrany `src35/sources` jest zachowany w `build02/src/sources`.
Build summary zgłaszał 10 Warnings, ale szczegółowy buildfre.log nie zawiera
rekordów diagnostyki warning C*/LNK*; compiler/linker /WX zakończyły się rc0.
Nie deklaruje się na tej podstawie osobnego wyniku zero-warning.

Host checks: 8 NT35 + 8 NT351 + 20 istniejących usosnet + 1 nowy test wykonujący
rzeczywiste ciała C IRQ na kanonicznym modelu MMIO — 37 PASS. Dodatkowe 4 testy
fixture chronią niezmienność hardware argv i wykrywanie zapisu poza dokładnymi
zakresami własnego pliku SYS. Nie nadają same runtime PASS.

## Zachowany target i przebieg

Zamknięty R20b: `G:\USOS-Kolekcja\_vm\r20b-nt35-usb-isolation\target.qcow2`,
SHA-256 `e8edf8907be529bfa84454661bffea50b1ec20a51231572a3bd47a43046cb446`.
Nowy overlay `G:\USOS-Kolekcja\_vm\nt35-irq-fixed01\target.qcow2` zmienił
wyłącznie istniejący plik `WINNT/SYSTEM32/DRIVERS/usosnet35.sys` tej samej
długości. Hash wszystkich bajtów dysku poza dokładnymi zakresami własnego
pliku jest identyczny przed/po. SYSTEM i frozen USB nie zmieniły się;
pełny qemu-img compare raw/overlay PASS. Surowy scratch pozostawał wyłącznie
jako whole-disk na G: i został usunięty po sprawdzeniu własnej dokładnej ścieżki.
Żadnych Microsoft hive/binaries nie eksportowano do repo lub outputs.

Po wyniku R26 parent przydzielił jeden test. Tag `nt35-irq-fixed01`, TTY52665,
normalny guard 2048 MiB + 8192 MiB rezerwy. Ten sam q35/EPYC-Rome/2 CPU/TCG,
firmware, i8042 sprzętowo obecny, ale port service Start4, AHCI i jedyny igb
MAC 52:54:00:55:53:01. Nowy stick overlay i kopia zatrzymanego NVRAM.
Zmiany argv to tylko trzy własne ścieżki i dwa porty localhost.

Jeden endpoint po 300 s i każde kolejne działanie mają osobny uprzednio
uzbrojony ReadDirectoryChangesW na dokładną przyszłą PNG. Bez odczytów
aktywnych logów, ekranów, QMP/statusu lub RAM dla postępu. Nie było nowej VM
do kolektora: po quit użyto odczytu FAT zatrzymanego whole-disk.
Po zamknięciu wzmocniono przyszły guard o dokładny SHA-256 źródłowego
command.json i allowlistę firmware/trzech plików obrazów. Odczyt ukończonego
argv potwierdził zgodność z tą samą transformacją; nie uruchamiano kolejnej VM.
Rzeczywista wersja wrappera użyta podczas próby jest zachowana osobno z hashem
z preflightu, bez przypisywania jej późniejszej poprawki guardu.

## Rzeczywiste wyniki

| Test | Wynik |
|---|---|
| Logowanie / Program Manager | NT Workstation Version3.5, USB CtrlAltDel/Enter i Run |
| Native DHCP renew/all | 10.0.2.15/24, DHCP/router 10.0.2.2, DNS 10.0.2.3 |
| Standardowy native ping, bez zmiany timeoutu | 3/3, każda odpowiedź time<10ms |
| Logger ICMP1s | PASS, status0/replies1/rtt0/echo_match1 |
| Strict UDP DNS 1.1.1.1 | ID72B1, frogfind.com/A64.227.13.248, 80 ms, dns_match1 |
| Strict UDP DNS 8.8.8.8 | ID7C08, ta sama nazwa/A, 30 ms, dns_match1 |
| Strict TCP DNS 1.1.1.1 | ID25A3, ta sama nazwa/A, connect20 ms, dns_match1 |
| HTTP 68k.news | 134.209.213.152, 4095 B, HTTP/1.1 200 OK, connect121 ms |
| Native shutdown | operator17: It is now safe to turn off your computer |
| Process exit / stopped readback | QMP quit, rc0, exact installed candidate, frozen USB, i8042prtStart4 |

Nowy pełny snapshot loggera trwał 11 637 ms. USABILITY.TXT zawiera dwa starsze
snapshoty i jeden nowy; ewaluator wybiera ostatni kompletny blok. Historyczne
RTT1122 ms, FAIL11010 oraz około2s DNS/HTTP nie zostały usunięte. Nowy IRQPOST.LOG
zawiera wyłącznie jawne `/renew`, `/all` i standardowy ping tej próby.
Pozostają negatywne kontrole: gateway UDP53 bez odpowiedzi, TCP gateway80
i HTTP frogfind timeout około4s. Nie ma deklaracji sukcesu każdego endpointu.

Klatka120s nie pokazała promptu; samo to nie było dowodem trwania loggera.
Następne polecenie znacznika do istniejącego wirtualnego COM1 pokazało już
gotowy prompt CMD, po czym anulowano wyłącznie znacznik i odczytano ukończony
log. Nie użyto tej obserwacji do diagnozy zawieszenia. Ostateczny tekst
snapshotu, a nie klatka konsoli, ustala czas 11 637 ms.

Capture ma 190 ramek / 40 398 B, bez cap/discard/error, SHA-256
`1a438e35f64577577fe4a22190c1974df642f553fed03260c665c24c2f607003`.
Ścisła maszyna pełnego DORA pozostaje false. Osobne pasujące REQUEST/ACK
przypiętego klienta: records1/2 XID2199082265 oraz jawne renew records91/92
XID2121779269; oba potwierdzają .15, server/router.2, DNS.3, lease86400s.
To wynik renew, bez podnoszenia strictDORA do PASS.

Po native shutdown i process exit0 odczyt FAT potwierdził nowy SYS, frozen
USB `2d4557439d7c60f7e0d5cc53d36467cbc36ae24596eb614e078059ddc718cfe1`,
REGF1.2/CurrentDefault1/i8042prtStart4. R20b backing jest niezmieniony.
Nowy target SHA-256
`10020a0db9f57ab2b0029a9d292b0f6f055bd82747d1f20dd2609163aaa48603`.
Wyeksportowano tylko sześć nazwanych własnych tekstów, bez hive/MS payloadów.
Stare NET35 metadata i USOSNET35.SHA256 nadal opisują źródłowy R20; niezależny
readback zainstalowanego SYS jest nadrzędny dla tej kwalifikacji.

Dowody lokalne: `artifacts/nt35-irq/{preparation,source-byte-review,evaluation}.json`,
`artifacts/nt35-irq/stopped-readback/`, `artifacts/nt35-irq-build02/` oraz
`artifacts/coverage/vm/nt35-irq-fixed01/` z endpoint/operator01–17, preflight,
command/result i completed capture. Ogólne flagi runnera pozostają false;
osobny manual_qualification_pass wiąże natywne wyniki z konkretnym installedSYS.

Zachowano dokładnie:

| Ścieżka w G:\USOS-Kolekcja\_vm\nt35-irq-fixed01 | Rozmiar |
|---|---:|
| target.qcow2 | 240 648 192 B |
| stick.qcow2 | 197 120 B |
| vars.fd | 540 672 B |

Brak własnej aktywnej VM. Nie powtarzano fresh Setup ani nie zmieniano cache,
USB/hubów, fizycznych nośników, istniejącego nt35-net, merge/push/deploy.
Wynik dotyczy zainstalowanego NT3.5 Workstation w tej fixture QEMU. Server,
fizyczny Intel i świeża instalacja z nowym cache wymagają odrębnych prób.

## Regresja USB po poprawce IRQ: nt35-irq-usb01

Drugi mały test użył nowego, efektywnie bajtowo identycznego overlay
zakończonego fixed01. Nie podmieniał pliku gościa ani wpisu rejestru.
Kandydat d94ec3e2…e4c85/16 384 B, frozen USB 2d455743…cfe1 i Start4 są
przypięte zakończonym readbackiem. Parent fixed01 ma SHA-256
`10020a0db9f57ab2b0029a9d292b0f6f055bd82747d1f20dd2609163aaa48603`.
`qemu-img compare` rodzica i nowego targetu przed rozruchem PASS.

Tag `nt35-irq-usb01`, TTY65091, jeden normalny guard 2048 + 8192 MiB rezerwy,
jeden endpoint 300 s. Reużyto tego samego harnessu, hardware i źródłowego argv;
zmieniły się tylko trzy własne ścieżki i dwa porty localhost. Każda jawna
akcja miała wcześniej uzbrojony exact-frame ReadDirectoryChangesW. Brak
odczytów postępu. Small wrapper ma tryby prepare/run/readback; niezależny
readback dodany podczas rozruchu nie zmienił już załadowanej ścieżki run.
Rzeczywiste źródło wrappera zachowano z hashem zgodnym z preflightem.

| Akcja | Obserwacja zakończonej akcji |
|---|---|
| 01/02: USB CtrlAltDel i Enter | Logowanie i Program Manager Version3.5 |
| 03: keyboard remove, potem AltF/R | Brak Run; klatka identyczna pikselowo z pulpitem02 |
| 04/05: keyboard insert, potem AltF/R | Run faktycznie otwarte |
| 06/07: Esc, mouse remove i AltF/R | Żywa USB klawiatura ponownie otwiera Run bez myszy |
| 08/09: Esc i mouse insert | Powrót myszy |
| 10/11: ruch na origin, ruch44/47 i left click | Rzeczywisty kursor, następnie otwarte menu File |
| 12/13: native File/Shutdown i Enter | It is now safe to turn off your computer |

Jednolite teal w 04 i 10 zachowano, bez wniosku o awarii. Następna konkretna
akcja klawiatury lub menu dała widoczny wynik. Nie zaliczano samych ACK QMP.
**Keyboard out/negative control/in/action, mouse out/live keyboard/in/menu
click — PASS przy nowym IRQ SYS i i8042prt Start4.**

Explicit finish/QMP quit, rzeczywisty wrapper exit0. Postquit FAT readback:
installed SYS dokładnie d94ec3e2…e4c85, frozen USB, REGF1.2/CurrentDefault1/Start4,
niezmieniony fixed01 backing. Nowy target SHA-256
`92c2aac3c1f1028fe3caeb44b60a7ff8f49df482c7cc2456cb2c75ddc47c819a`.
Własne wcześniejsze logi sieci są identyczne; nie są nowym pomiarem LAN w usb01.
Wynik sieci pozostaje osobną kwalifikacją fixed01 opisaną wyżej.

Dowody: `artifacts/nt35-irq-usb/preparation.json`, `assessment.json`,
`runtime-wrapper-source.py`, `stopped-readback/`; oraz
`artifacts/coverage/vm/nt35-irq-usb01/` z endpoint/operator01–13, akcjami,
preflight, command i completed result. Ogólnych flag runnera nie zmieniono.
Odczyt eksportuje tylko własne teksty; hive/MS bytes pozostają w RAM lub
whole-disk na G:. 41 hostchecks oraz diff-check PASS.

Zachowany folder `G:\USOS-Kolekcja\_vm\nt35-irq-usb01`:
target.qcow2 3 211 264 B, stick.qcow2 197 120 B, vars.fd 540 672 B.
Brak aktywnej własnej VM. Nie zmieniono drivera, cache, hub code, hardware
ani istniejącego nt35-net; bez fresh Setup, fizycznych zapisów, merge/push.
