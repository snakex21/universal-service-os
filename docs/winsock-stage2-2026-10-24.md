# Winsock Win16 — etap 2

QEMU only, Windows 3.1 PL STANDARD, Intel 82576 (`igb`), 64 MiB.
Mosaic 1.0 wyświetlił rzeczywistą stronę przez `http://www.68k.news/`.
Dosłowny `http://68k.news/` jest zablokowany przez parser adresów samej
przeglądarki: nazwy zaczynające się cyfrą trafiają do niepoprawnej gałęzi
liczbowego IPv4. [Diagnoza oryginalnych NE](winsock16-mosaic-numeric-host.md)
obejmuje również ostatni potwierdzony Win16 alpha2. Nie zmieniono aplikacji
ani nie dodano wyjątku dla domeny w DLL.

## Zakres implementacji

- Ukryte okno i timer napędzają `WSAAsyncSelect` dla READ/WRITE/CONNECT/CLOSE/
  ACCEPT. Powiadomienia mają oddzielne maski rearming dla każdego gniazda.
- Asynchroniczne A/PTR, cztery ograniczone zadania DNS, własne identyfikatory,
  anulowanie przed completion, prawdziwe wskaźniki FAR we wskazanym buforze.
  DNS i IPv4 biorą parametry z DOS-owego DHCP w MTCP.CFG.
- `select`, `FIONBIO`, `FIONREAD`, MSG_PEEK, bind/listen/accept, UDP sendto/
  recvfrom i shutdown. AsyncSelect narzuca nonblock zgodnie z interfejsem.
- SO_TYPE, SO_ERROR, rozmiary buforów oraz ograniczony zestaw opcji i lokalne
  tablice usług/protokołów. SO_KEEPALIVE/REUSEADDR włączone, aktywny linger i
  wyłączenie TCP_NODELAY zwracają jawny błąd; nie udają nieistniejącej funkcji.
- 16 gniazd, RX/TX po 4096 B, okno wielu segmentów, bitmapa segmentów poza
  kolejnością, częściowe ACK, ponowienia 1/2/4/8/16 s, próby zerowego okna,
  przejścia sekwencji przez 32-bitowy wrap, nasłuch i half-close.
- Ograniczenia: stałe początkowe RTO, bez SRTT/RTTVAR/fast retransmit,
  IPv4/MTU bez fragmentacji IP. Pozostałe async bazy protokołów/usług i
  niestandardowe blocking hooks pozostają niezaimplementowane. Nie jest to
  deklaracja pełnej zgodności Winsock 1.1.

## Dowody i uruchamianie

`python tools/build_win16_winsock.py --strict --stage2-tests` buduje provider
NE i własne kontrolery. Open Watcom wskazuje zmienna `USOS_WATCOM`.
`run_win16_winsock_flow_qemu.py` wykonuje jedną instalację przez rzeczywisty
profil USOS; snapshot `base` chroni ją przed kolejnymi poprawkami.
`run_win16_mosaic_qemu.py` używa wyłącznie nakładek tej bazy. Aplikację należy
wskazać z biblioteki poza repo. Domyślny URL testu nadal jest dokładnie
`http://68k.news/`; parametr `--url http://www.68k.news/` jawnie wybiera obejście.

ASYNCTEST potwierdził rzeczywiste GetWinFlags=1049 (0x419), STANDARD, 16
gniazd, anulowanie, DNS/FAR oraz FD_CONNECT/WRITE/READ/CLOSE, select/ioctl i
HTTP 200. Zachowany plik 100861 B jest identyczny z TCP z PCAP; Content-Length
zgadza się z treścią. Hostowy peer sprawdza również listener/accept,
retransmisje, out-of-order, okno i nieblokujący czas powrotu.

Mosaic jest interaktywny i nie kończy procesu po wyświetleniu strony.
Końcowy test wykonuje pojedynczy zrzut po ograniczonym przebiegu, bez
odpytywania postępu. Sukces wymaga ręcznego obejrzenia zrzutu ORAZ analizy
zamkniętego PCAP. Sam exit skryptu lub upływ czasu nie daje PASS.
`validate_stage2_pcap.py` niezależnie składa TCP, sprawdza DHCP/DNS, HTTP 200,
Content-Length albo poprawną granicę FIN przy `Connection: close`.

Dowody są w ignorowanym `zig-out/win16/stage2/evidence`; zewnętrzny raport
końcowy wymienia commity, wyniki oraz dokładne sprzątanie. Raport powstaje
przed usunięciem obrazów; PCAP, logi, zrzuty i manifesty pozostają zachowane.
Końcowy bilans: 129 różnych testów hostowych PASS. Po zapisaniu raportu
usunięto 19 własnych qcow2/initrd (639515452 B), z porównaniem SHA i
usunięciem przez te same wyłączne uchwyty. Kopia raportu sprzed usunięcia,
wersja końcowa i dokładny wykaz są zachowane w evidence. Pozostało 567
plików dowodowych; żadnego logu, PCAP ani zrzutu nie usuwano.

Domyślny USOSPKT.COM jest identyczny: 8157 B,
`98cfdf5ad6c8d7c805927d7f7247ef326ca36414c3622189a0a238c16ae933eb`.
Referencyjna rezydencja 43264 B. Profil OFF zachowuje pliki instalacji.
Zero kodu/plików Trumpeta; oryginalne aplikacje testowe wyłącznie w osobnej
bibliotece użytkownika, poza repo. Bez merge, push i wdrożenia.

X470/I211, rzeczywista sieć i jej utrata pakietów, WfW/enhanced oraz IRC są
**niesprawdzone**. Wynik QEMU nie zmienia ich statusu.

Specyfikacje: [WSAAsyncSelect](https://learn.microsoft.com/en-us/windows/win32/api/winsock/nf-winsock-wsaasyncselect),
[async DNS](https://learn.microsoft.com/en-us/windows/win32/api/winsock/nf-winsock-wsaasyncgethostbyname),
[DNS RFC1035](https://www.rfc-editor.org/rfc/rfc1035.html).
