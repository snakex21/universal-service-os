# NT 3.51 Workstation — świeży R22, QEMU only

R22 `r22-nt351-fresh-network-ps2` przeszedł normalny przepływ USOS od
oryginalnego nośnika do rzeczywistego pulpitu Program Manager. Gość zgłasza
Windows NT Workstation 3.51 build1057. Początkowy `endpoint.png` pozostaje
niezmieniony; `operator-15.png` pokazuje natywne „safe to turn off”.
QMPquit i launcher zakończyły się kodem0. Surowy wynik harnessu
`ASSESS_ENDPOINT` zachowano; osobna ręczna ocena nadaje desktop PASS.

Dokładne wejście to archiwum SHA256
`24adda13744589cacebf6a75e21bf8999465b5637235ce55b0cf3a7578aa7975`,
wewnętrzny ISO `b9d0e8417c1f502d1de22c249401b593be2a7fe59524b27a624dfa8dedaa099c`.
Startup tester był w ec60b10c; użyto zamrożonego net3, nie przebudowy
obecnego drzewa. Piny skutecznych plików potwierdzają manifesty R21 cache
w `nt351-net`, a plan R22 ma SHA256
`39a87f8eaa43a4744a7f8d42ccbdfcfccaf1dd608f409b35a449c6fa7f9b3538`.
Dziedziczony `nt351-inputs.json` cache opisuje starszy net2; nie jest dowodem
rzeczywistych wejść R22. Odczyt zatrzymanego targetu potwierdził własny SYS
`f39d58fd923632dacbc577562045015123a9bdfc98c56237090bfcd53c70612a`.

W świeżym gościu wykonano native `ipconfig /release`, `/renew`, `/all`,
`ping -n 3 -w 5000 10.0.2.2` oraz własny USOSLOG /once. Dowody zebrano
dopiero po wyjściu QEMU, z dysku dołączonego tylko do odczytu:

- DHCP: native release/renew, 10.0.2.15/24, router10.0.2.2, DNS10.0.2.3,
  lease86400s. Mirror jedynego MAC52:54:00:55:53:01 zawiera dwie spójne
  pary Discover/Offer i Request/Ack (pierwszy start oraz odnowienie).
  XID tych dwóch faz jest różny; ścisłe `dora_observed=false` pozostaje
  bez zmiany. To nie przeczy natywnemu uzyskaniu dzierżawy.
- Native ping3/3: 2353/2003/2003ms. Własny logger: ICMP status0,
  echo_match1, RTT1562ms. Mirror potwierdza wszystkie cztery pary echo
  z poprawnymi checksum, adresem, identyfikatorem, sekwencją i payloadem.
- Ścisłe dopasowanie odpowiedzi DNS: UDP1.1.1.1, UDP8.8.8.8 i TCP1.1.1.1.
  Winsock rozwiązał też nazwy przez konfigurację systemu.
- HTTP68k.news: `HTTP/1.1 200 OK`. Frogfind HTTP timeout oraz brak usług
  DNS53/TCP80 na bramie zachowano jako oddzielne wyniki, nie ukryto.

Sieć jest funkcjonalna, ale opóźnienie około2s pozostaje otwartą wadą
obsługi RX/checkera. R22 nie dowodzi prawidłowego IRQ ani pollingu20ms.
PS/2 jest w tym teście dozwolone. USB out/in w R18f pozostaje osobnym
dowodem; R22 nie kwalifikuje USB-only ani pamięci USB. Nie nadajemy PASS
NT3.5, NT3.1, Serverowi ani X470 na podstawie tego wyniku.

W `artifacts/coverage/nt351-runtime-r22/` są ocena, analiza PCAP,
plan i manifesty retencji; własne logi w katalogu ukończonego przypadku.
PCAP SHA256 `83e63e7de8db6ae3cfaa6900be7ef927bffcc14bbd988e9c15e46fa8f0bbca05`,
223rekordy/44639B. Kolektor wyeksportował tylko pięć własnych plików i hash
własnego sterownika. Moduły i hive Microsoftu pozostały w całym obrazie.

Do wyników macierzy dopisano jeden rekord dla identycznego archiwum:
65→66, poprzednie65 zachowane identycznie. Starszych nieukończonych prób
nie przepisano. Obrazy target/vars/stick zachowano zdarzeniowo, bez
czytania aktywnych plików. Nie zmieniono hubów, nośników fizycznych ani
instalacyjnego pakietu produkcyjnego.
