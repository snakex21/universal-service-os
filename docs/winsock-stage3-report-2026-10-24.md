# Winsock etap 3 — raport końcowy / STOP

2026-10-24. Start 15:01UTC, zakończenie 17:49UTC, w limicie 12 h.
Gałąź `codex/winsock-etap3`, baza `34bae7a6`, worktree
`C:\Users\ASRock\usos-work\winsock-etap2`.

**Wynik: QEMU PASS dla www.68k.news, dwóch aplikacji, API i lokalnego IRC;
frogfind.com BLOCKED — brak odpowiedzi również poza gościem.** Nie jest to
pełny PASS całej listy stron ani wynik X470. Etap zamknięty z tą blokadą.

## Macierz wykonania

| Warunek | Windows3.1PL WIN /3 | WfW3.11PL WIN /3 |
|---|---|---|
| Normalna instalacja profilu USOS + snapshot base | PASS 8/8 | PASS 8/8 |
| Rzeczywisty GetWinFlags | 3113 / ENHANCED | 3113 / ENHANCED |
| Mosaic1.0 → www.68k.news, widoczna strona | PASS | PASS |
| Netscape3.04 Win16 → www.68k.news | PASS, synchroniczny DNS | PASS, synchroniczny DNS |
| Opera3.62 Win16 → www.68k.news | PASS, zwykły tryb próbny | PASS, zwykły tryb próbny |
| Mosaic + Netscape jednocześnie: dwa różne taski i dwa pełne HTTP 200 | PASS | PASS |
| APIA/APIB, blocking/reentry/cancel, żywy DNS/TCP po wyjściu A | PASS | PASS |
| mIRC5.91 Win16 → JOIN #usos-test | nie wykonywano | PASS, kontrolowany lokalny endpoint |
| Netscape i Opera → frogfind.com | BLOCKED, wykonana próba obu | nie powtarzano blokady zewnętrznej |

QEMU: TCG, CPU pentium3, 64 MiB, karta igb; świeży DOS DHCP w innej niż
standardowa podsieci:172.31.8.15/25, brama172.31.8.2, DNS172.31.8.3.
To nie jest pomiar minimalnego CPU/RAM. Dowody są w
`K:\USOS-VM\winsock-etap3-20261024`.

## Co zmieniono i dlaczego

- Osobny kontekst każdego taska: błąd, liczniki startup/cleanup, hook,
  cancellation, wyniki baz host/service/protocol, okno/timer i async jobs.
  Do 8 aktywnych aplikacji,16 wspólnych gniazd z kontrolą właściciela;
  prywatne gniazda DNS też zużywają tę pulę. Cleanup A nie zamyka gniazd B.
- Rzeczywiste blokowanie: WSAEINPROGRESS dla ponownego wejścia tego samego
  taska; WSAIsBlocking/hook/cancel i przywracanie stanu. Oddzielne aplikacje
  mogą współpracować. Cancel mapowany do WSAEINTR.
- TCP fast retransmit po 3 duplicateACK oraz naprawa dalszych luk po partial
  ACK; retransmisja wielu segmentów bez cofania SND_NXT, zachowany RTO.
- Rzeczywisty błąd DPMI ujawniony dopiero w VM: wspólny GlobalDosAlloc
  należał do A i tracił ważność po jego wyjściu. Teraz każdy INT31/0300 ma
  własne 50 B na chronionym stosie i FAR ES:DI; zerowe SS:SP wybiera stos
  hosta DPMI. Jawne `-zu`, bo stos wywołującego DLL nie jest jej DGROUP.
  Natywny B wykonuje świeży DNS i TCP/HTTP 200 po całkowitym wyjściu A.
- Callbacki testowego EXE mają poprawny eksportowany FAR PASCAL prolog DS.
  Okno DLL używa własnego DS bez thunka należącego do pierwszej aplikacji.
- Netscape/Opera naprawdę żądają SO_LINGER={1,0}. Dodano abortive close
  z próbą RST i zwolnieniem slotu; brak miejsca TX daje WSAENOBUFS, bez
  czekania i bez naruszania drugiej aplikacji. Dodatni linger pozostaje
  jawnie nieobsługiwany. RST jest best effort; nie cofamy już wysłanych ramek.
- Netscape rejestruje także FD_OOB. Akceptujemy ten bit razem z normalnymi
  zdarzeniami; obsługa TCP URG i powiadomień OOB NIE powstała.

Dokumentacja w repo: `docs/winsock16-tasks-stage3.md`,
`docs/winsock16-dpmi-task-lifetime.md`,
`docs/winsock-stage3-browser-interop.md`,
`docs/winsock-stage3-fixtures-2026-10-24.md`.

## Dowody aplikacyjne

`validation/final-closed-browser-evidence14.json` zawiera SHA PCAP, wersję
DLL, liczbę kompletnych odpowiedzi i przegląd zamkniętych przypadków.
Każdy PASS strony wymagał faktycznego zrzutu + pełnej odpowiedzi w PCAP,
ze sprawdzaniem braków/sprzecznych retransmisji, DNS i DHCP.

- Mosaic: `apps/mosaic-win31-www-01` i `mosaic-wfw-www-01` — obrazy faktycznie
  przedstawiają stronę. Końcowe dual-win31/www12 i dual-wfw/www12 z provider09
  potwierdzają dodatkowo dwie kompletne odpowiedzi: Mosaic 92046 B i Netscape
  91497 B treści. W końcowym zrzucie dual na pierwszym planie jest Netscape;
  nie przypisujemy tego zrzutu do renderingu Mosaica. Próba zwykłego Alt+Tab
  w wariantach13 nie zmieniła pierwszego planu; nie jest to nowy błąd DLL.
- Netscape: `apps/netscape-win31-sync11`, `netscape-wfw-sync10` — widoczna
  strona, Document:Done, pełne HTTP 200/91497 B. `Use Async DNS=no` pochodzi
  z zalecenia w oryginalnym INI. Async DNS w samym Netscape pozostaje
  nierozwiązanym problemem interoperacyjności; natywne async API ma osobny PASS.
- Opera: `apps/opera-win31-eval11`, `opera-wfw-eval12` — widoczna strona,
  pełne HTTP 200/91497 B. Oryginalny Evaluate kliknięty normalnie; aplikacja
  nadal pokazuje unregistered. Nie ma patcha aplikacji ani danych rejestracji.
  Część ikon paska jest niekompletna; nie wpływa to na wymagany HTTP/render.
- Dwie aplikacje: oba przypadki dual-www12 mają odrębne taski Mosaic/Netscape,
  obie odpowiedzi kompletne i żywe okna. `api-win31-06` i `api-wfw311-06`
  dodatkowo dowodzą przeżycia transportu po wyjściu A: oba logi FINAL PASS,
  po wyjściu A świeży DNS+connect/send/recv HTTP 200, ostatni cleanup PASS.
  Receipt: `validation/api06-completed-evidence.json`. API używa provider06;
  finalny provider09 zawiera ten sam poprawiony transport DPMI + linger.
- IRC: `apps/irc-join07`; oryginalny mIRC5.91 Win16, WfW enhanced, widoczny
  kanał #usos-test, @USOS16 i Now talking. PCAP zawiera NICK/USER/JOIN/MODE
  oraz odpowiadające001..376, JOIN echo,332,353,366,324, bez luk TCP.
  `validation/irc-final-closed-review02.json`; PCAP SHA256
  `4898294d437662763963898b952b79d2adc1e2950e71ee29927ef91f2c4f2e0e`.
  Endpoint jest lokalny, kontrolowany,127.0.0.1:16667. mIRC wysyła bare LF,
  więc test jawnie wybiera zgodność LF dla klienta; serwer domyślnie nadal
  wymaga CRLF i odpowiada CRLF. To NIE jest PASS publicznego serwera IRC.
- Frogfind: `apps/dual-win31-frog12`, oba oryginalne programy; DNS zwrócił
  64.227.13.248, nie ma HTTP 200, Opera pokazuje Could not connect to remote
  server. Niezależny `validation/host-http-direct02.json` potwierdza timeout
  hosta przy równoczesnym HTTP 200 z www.68k.news. Nie podmieniano DNS,
  serwera, treści ani nie używano proxy. Nie diagnozujemy tej blokady dalej.

## Testy hosta i build

- 135/135 końcowych testów `tools/tests/win16` PASS,10.54 s:
 `validation/host-final01.log`. Obejmuje realny wrapper z symulowanymi
 taskami, NewReno/wiele luk/RTO, cancel, abortive close i kontrolę IRC/PCAP.
- 6/6 testów planu aplikacji PASS:
 `validation/app-fixture-final01.log`.
- Osobno 1/1 ponownie zbudowany domyślny USOSPKT PASS:
 `validation/default-identity-final02.log`;8157 B, SHA256
 `98cfdf5ad6c8d7c805927d7f7247ef326ca36414c3622189a0a238c16ae933eb`.
 Pierwsza próba była SKIP z powodu braku jawnego USOS_ZIG; log01 zachowany.
- OpenWatcom: końcowy build diagnostyczny i zwykły PASS.
 `validation/final-build-metadata14.json`: prawdziwe NE,48 nazwanych
 eksportów DLL z prawidłowymi ordinalami, bez LIBMAIN; stałe opisy modułów
 bez ścieżek budowania. TESTLOAD/GETHTTP bez publicznych callbacków.
- Host shim nie emuluje segmentów, DPMI ani planisty Win16; dlatego jego
 wyniki uzupełniają wykonane rzeczywiste testy Windows w QEMU.

Końcowy provider09 / final-diag14: 195188 B, SHA256
`0dbb6c504c55cc539bb35c4d8028cfadea1dc4f66599d470aa6e09c0d7709486`.
Ponowna kompilacja końcowego źródła dała IDENTYCZNY SHA.
Zwykły build final-release14: 193374 B, SHA256
`7c62eadd660adef5d321e983af088fa87f6051078916affd83260d9154adcf4a`.
Zwykły build ma kontrolę kompilacji/NE; opisane VM używały diagnostycznego.
Artefakty są w `zig-out/win16/`, poza śledzonym payloadem.

## Warunki, zachowanie materiałów i granice

Jedna instalacja na system, każda ma snapshot base; dalsze poprawki tylko
na nakładkach. Uzasadnienie nowych instalacji zapisano PRZED instalacjami
(obrazy etapu2 były już usunięte po jego raporcie). Oryginalny mIRC instalowano
raz na osobnej nakładce aplikacji, bez reinstalacji OS.

OFF/default invariance: pięć plików źródłowych/menu identycznych z bazą,
`validation/off-default-invariance14.json`. Nie zmieniano instalatora OFF
ani domyślnego USOSPKT; nie deklarujemy nowej osobnej instalacji OFF.
USOSPKTQ.COM pozostaje opt-in, domyślny USOSPKT.COM ma powyższy SHA.

Aplikacje i instalatory wyłącznie w
`G:\USOS-Kolekcja\Programy\Win16\`; do VM kopiowano oryginalne bajty.
W repo nie dodano tych binariów, żadnego kodu/plików Trumpeta ani innych
implementacji Winsock. Publiczne kontrakty API/DPMI wskazano w docs.
Nie wykonano merge/push/deploy/force/junctionów ani dostępu do dysków fizycznych.
Wszystkie QEMU/endpointy tego zadania zakończone; brak automatyzacji.

**Lista usuniętych obrazów/dowodów tego etapu: pusta.** Wszystkie qcow2,
PCAP, PNG, logi i historyczne FAIL pozostają do przeglądu. Dotyczy to też
niewersjonowanego `runtime/abort-index/`; nie jest częścią commitu/payloadu.
Manifest końcowy rozdziela hashowane dowody i zachowane obrazy. Sprzątania
nie wykonano przed raportem ani po nim w tym etapie.

## Commity zamkniętych kawałków

```text
2b26a042 Recover bounded TCP flights with fast retransmit and partial ACK repair
d1cb6cc3 Cancel blocking engine waits and isolate concurrent DNS resolver sockets
ba89308e test(win16): prepare isolated stage3 Win31 and WfW bases
e778457f test(win16): add enhanced application COW fixture and mode log
0108d3ee Add controlled local IRC dialogue and completed-PCAP verification
ebd64e21 test(win16): launch app fixture from WfW enhanced branch too
fd354a83 feat(win16): isolate Winsock tasks and enforce blocking-call contracts
9d311248 test(win16): enforce stage3 scratch pool and free space budgets
90302829 docs(win16): record stage3 bases and original application provenance
83f026a9 test(win16): fix native callback DS and build stage3 clients
7dc28346 fix(win16): keep shared event procedure alive across task exit
2f9615b6 test(win16): drive finite first-run dialogs and retain packet diagnostics
f6169cbc fix(win16): keep DPMI register structures local to each call
92ab6b28 test(win16): add original mIRC evaluation fixture and explicit LF endpoint mode
ca43a56b feat(winsock): provide bounded abortive TCP close for zero linger
29ce401f test(win16): preserve bounded mIRC registration proof and JOIN fixture blocker
3ac348a4 test(win16): verify original mIRC JOIN through enabled normal UI action
6d74ede1 fix(win16): support browser abortive linger and event masks
7c1db846 test(win16): bound original browser dialog and keyboard actions
```

Ostatni commit implementacyjny: 7c1db846. Kopia tego raportu w docs otrzymuje
osobny commit dokumentacyjny. Raport końcowy → STOP; bez X470/wdrożenia,
bez otwierania innych zamkniętych systemów i bez przechodzenia do etapu4.
