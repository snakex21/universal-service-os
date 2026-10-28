# Sterowniki kart sieciowych — producent, wersje, licencje (2026-10-22)

> Status: DeepSeek research, unverified by Claude/Codex; versions and licence notes as of 2026-10-22 — check sources before relying on them.

Zakres: karty Realtek RTL8111/8168 (1 Gb, `PCI\VEN_10EC&DEV_8168` i pokrewne)
oraz krótko RTL8125 (2,5 Gb), Intel I225/I226 i Marvell/Aquantia AQC107/AQC113.
Pytanie: **dla każdego systemu — czy producent wydał oficjalny sterownik, jaka
jest ostatnia wersja, gdzie się go pobiera i czy licencja pozwala na
redystrybucję** (dołączenie do USOS).

Wszystkie wersje i statusy: **data sprawdzenia 2026-10-22**. Badanie wyłącznie
analityczne — nie pobrano i nie dołączono żadnego pliku sterownika
(`.exe/.zip/.inf/.sys/.pdf`); czytano tylko HTML/tekst stron producentów i
archive.org.

## 1. Legenda i zasady odczytu

| Wartość | Znaczenie |
|---|---|
| **tak** | producent publikuje sterownik dla tego systemu; wersja odczytana ze strony producenta |
| **tak (wycofany)** | sterownik istniał i jest potwierdzony w archiwum, ale producent usunął wpis z bieżącej strony |
| **nie** | brak jakiegokolwiek wpisu producenta dla tego systemu (sprawdzona bieżąca strona **i** archiwum) |
| **nieznana/niepotwierdzone** | źródła nie udało się odczytać (403/strona dynamiczna) albo tytuł pakietu nie rozstrzyga o obsłudze układu — **nie zgadujemy** |

Licencja: **wolno dołączyć** (jest zgoda na redystrybucję) / **tylko użytkownik**
(brak zgody na redystrybucję) / **nieznana**. Cytaty i URL tekstów licencji —
sekcja 4. Tam, gdzie producent nie publikuje tekstu licencji, wpisano
**nieznana** i wyjaśniono, co dokładnie znaleziono — brak tekstu nie jest
traktowany jako domniemana zgoda.

## 2. Realtek RTL8111/8168 (główna tabela)

Rodzina objęta jednym katalogiem oprogramowania Realteka: `RTL8111B/C/D/E/F/G/H(S)`,
`RTL8118A`, `RTL8119`, `RTL8111L/K`, `RTL8116AF`, `RTL8111DP/EP/FP`,
`RTL8168B/E/G/H` — źródło [R1].

| System | Sterownik producenta | Ostatnia wersja (2026-10-22) | URL strony pobierania | Licencja (redystrybucja) |
|---|---|---|---|---|
| 95 | **nie** | — | [R1], [R2], [R6] | n/d (brak sterownika) |
| 98 | **tak (wycofany)** | 5.708 (2008-11-24) | [R2] | **nieznana** — [L1] |
| 98 SE | **tak (wycofany)** | 5.708 (2008-11-24) | [R2] | **nieznana** — [L1] |
| ME | **tak (wycofany)** | 5.708 (2008-11-24) | [R2] | **nieznana** — [L1] |
| NT 4.0 | **nie** | — | [R1], [R2], [R7] | n/d (brak sterownika) |
| 2000 | **tak (wycofany)** | 5.708 (2008-11-24) | [R2] | **nieznana** — [L1] |
| XP x86 | **tak** | 5.836 (2021-07-27) | [R1] | **nieznana** — [L1] |
| XP x64 | **tak (wycofany dla x64)** | 5.708 — pakiet jawnie „Support WinXP64” (2008-11-24); bieżący 5.836 nie wymienia x64 | [R2], [R1] | **nieznana** — [L1] |
| 2003 x86 | **tak** | 5.836 (2021-07-27) | [R1] | **nieznana** — [L1] |
| 2003 x64 | **nieznana/niepotwierdzone** | — (brak wpisu x64 w [R1] i [R2]) | [R1], [R2] | **nieznana** — [L1] |
| Vista x86 | **tak** | 106.35 (2021-09-08) | [R1] | **nieznana** — [L1] |
| Vista x64 | **tak** | 106.35 (2021-09-08) | [R1] | **nieznana** — [L1] |
| 7 x86 | **tak** | 7.154 (2024-04-09) | [R1] | **nieznana** — [L1] |
| 7 x64 | **tak** | 7.154 (2024-04-09) | [R1] | **nieznana** — [L1] |

Uwagi do wierszy:

* **95 — „nie” z uzasadnieniem.** Rodzina RTL8111/8168 nie ma wpisu dla
  Windows 95 ani na bieżącej stronie [R1], ani na stronie archiwalnej z
  2008-12-04 [R2] (tam najstarszy wpis to „Win98ME Driver 5.708”). Jedyne
  wpisy „Windows 95 for Driver only” i „Windows NT 4.0 for Driver only” na
  realtek.com (v A4.06) należą do **kodeków audio** (rodzina AC'97/ALC —
  katalog [R6] zawiera m.in. „Realtek Media Player (RtlRack)” i wymóg
  DirectX 8 dla 98 SE), **nie do kart sieciowych**. Nie ma więc podstaw, by
  twierdzić, że Realtek kiedykolwiek wydał sterownik 95/NT4 dla 8111/8168.
* **98/98SE/ME/2000 — „wycofany”.** Wersja 5.708 jest udokumentowana w
  archiwum [R2] („Win98ME Driver”, „Auto installation program (Support
  Win98SE/WinME)”, „Auto installation program (Support WinXP64/WinXP/Win2K)”).
  Na stronie bieżącej [R1] tych pozycji już nie ma — Realtek usunął 9x/2000.
  Czy 5.708 była **ostateczną** wersją dla 9x — **niepotwierdzone**: nie
  sprawdzono późniejszych snapshotów.
* **XP x64.** Obsługa x64 jest poświadczona tytułem pakietu z [R2]
  („Support WinXP64”). Bieżący pakiet [R1] nosi tytuł „WinXP and Server 2003
  Auto Installation Program for FE/GBE” i **nie** wymienia x64 — czy zawiera
  katalog x64, da się stwierdzić tylko z INF, którego nie pobierano
  (**niepotwierdzone**).
* **2003 x64.** Archiwum [R2] wymienia wyłącznie „WinXP (WinServer 2003)
  Driver 5.708” bez oznaczenia x64; bieżący tytuł [R1] także. Dlatego
  **nieznana/niepotwierdzone**, a nie „nie”.
* **Vista.** 106.35 jest jednym pakietem „Vista and WinServer 2008”; że
  zawiera oba katalogi (x86 i x64) — **niepotwierdzone** bez INF.
* **7.** 7.154 „Win7 and Server 2008 R2” (2024-04-09) jest ostatnim wydaniem
  dla tej gałęzi; nowsze numery (10.80.x, 11.031.x) dotyczą tylko 10/11.

## 3. Tabele pomocnicze

### 3.1 Realtek RTL8125 (2,5 Gb)

Ten sam katalog rodzinny [R1] (strona wymienia `RTL8125`, `RTL8125B(G)`,
`RTL8125BP/CP/D/K`, obok 8111/8168 i 8126/8127). Układ trafił na rynek w 2019,
więc systemy 9x/NT/2000/XP są z definicji poza zakresem, a przynależność
8125 do konkretnego pakietu Windows można potwierdzić tylko z INF.

| System | Sterownik producenta | Ostatnia wersja (2026-10-22) | URL | Licencja |
|---|---|---|---|---|
| 95, 98/98SE, ME, NT4, 2000 | **nie** (układ z 2019; brak wpisu w [R1]/[R2]) | — | [R1] | n/d |
| XP x86, XP x64, 2003 x86/x64 | **nieznana/niepotwierdzone** (pakiet XP 5.836 z 2021 nie wymienia 8125) | 5.836 (2021-07-27) — przynależność 8125 niepotwierdzona | [R1] | **nieznana** — [L1] |
| Vista x86/x64 | **nieznana/niepotwierdzone** (pakiet 106.35 z 2021 nie wymienia 8125) | 106.35 (2021-09-08) | [R1] | **nieznana** — [L1] |
| 7 x86/x64 | **tak** (pakiet rodzinny dla 7) | 7.154 (2024-04-09) — obsługa 8125 niepotwierdzona bez INF | [R1] | **nieznana** — [L1] |
| 10/11 (poza zakresem, dla porządku) | **tak** | 10.80.50 (2026-10-05) / NetAdapterCx 11.031.50 | [R1] | **nieznana** — [L1] |

Dodatkowo [R1] publikuje osobne pozycje dla 2,5G: „2.5G Ethernet LINUX driver
r8125” 9.018.00 (2026-07-03) i „2.5G NDIS2 driver” 1.56 (2021-03-23) — to
materiał DOS/real-mode, nie sterownik Windows.

### 3.2 Intel I225 / I226

| System | Sterownik producenta | Ostatnia wersja (2026-10-22) | URL | Licencja |
|---|---|---|---|---|
| 95, 98/98SE, ME, NT4, 2000, XP, 2003, Vista | **nie** (pakiety Intela dla tych systemów kończą się na rodzinach 8257x/I21x; I225 to 2019, I226 to 2022 — brak jakiegokolwiek pakietu) | — | [R3] | n/d |
| 7 x86/x64 | **nieznana/niepotwierdzone** (strona pakietu [R3] nie wylicza systemów; ARK zwraca 403) | 31.3 — pakiet zbiorczy | [R3] | **tylko użytkownik** — [L2] |
| 10/11 x86/x64 | **tak** | 31.3 („Latest”, snapshot 2026-10-17) | [R3] | **tylko użytkownik** — [L2] |

Uwaga metodyczna: `intel.com` (ARK i Download Center) odpowiada **403** na
pobranie bez przeglądarki; dane odczytano z zapisu archiwalnego [R3]
(2026-10-17). Strona pakietu podaje „all files for version 31.3 … for all
supported OS versions” i listę „OS Independent, FreeBSD, Microsoft Windows,
Linux, VMware”, ale **nie wylicza wersji Windows** — dlatego wiersz 7 x64 jest
„nieznana/niepotwierdzone”, a nie zgadywany.

### 3.3 Marvell / Aquantia AQC107 / AQC113

| System | Sterownik producenta | Ostatnia wersja (2026-10-22) | URL | Licencja |
|---|---|---|---|---|
| AQC107: 7 x86/x64 | **tak** | wersja **nieznana** (formularz na [R5] ładuje wersję dynamicznie) | [R4], [R5] | **nieznana** — [L3] |
| AQC107: 8, 8.1, 10 x86/x64 | **tak** | wersja **nieznana** (jak wyżej) | [R4], [R5] | **nieznana** — [L3] |
| AQC107: 95, 98/98SE, ME, NT4, 2000, XP, 2003, Vista | **nie** (poza wykazem systemów Aquantii [R4]) | — | [R4] | n/d |
| AQC113: wszystkie systemy z zakresu | **nieznana/niepotwierdzone** | — | [R5], [R8] | **nieznana** — [L3] |

AQC113 nie występuje w wykazie części [R5] (tam `AQN-108`, `AQC108`,
`AQN-107`, `AQC107`, `AQC107S`, `AQN-100`, `AQC100/100S`, `AQC111C/112C`,
`AQC111U/112U`) — to układ już z okresu Marvell. Strona Marvella [R8] przy
sprawdzeniu zwracała **403**, a zapis archiwalny nie zawiera pozycji AQtion,
więc **żadnej** wersji AQC113 nie potwierdzono źródłem.

## 4. Cytaty licencji (pełne URL)

**[L1] Realtek — brak tekstu licencji; tylko nota copyright.**
Strona pobierania [R1] (2026-10-22) **nie zawiera** umowy licencyjnej ani
zgody na redystrybucję; jedynym zapisem prawnym w serwisie jest stopka:

> „© 2026 Realtek Semiconductor Corp. All rights reserved”

Sprawdzono też stronę pośrednią pobierania (`/Download/ToDownload?downloadid=…`,
HTTP 200, HTML 86 687 B) — zwraca wyłącznie ogólne zastrzeżenie o sterownikach
audio i stopkę, bez EULA dla NIC. Wniosek: **nieznana**; do czasu uzyskania
pisemnej zgody Realteka pakietów nie wolno dołączać do USOS.

**[L2] Intel — Intel OBL Distribution (Commercial Use) License Agreement
[v2025.02.12]**, publikowana na stronie pakietu [R3]:

> „2.1 License. Subject to the terms of this Agreement, Intel grants to you,
> for the Term, a personal, limited, non-transferable, nonexclusive,
> worldwide, revocable, fully paid-up license under Intel’s intellectual
> property rights in the Material, without the right to sublicense, to: …
> c) distribute Redistributables in the format specified in redist.txt, or only
> as object code (or its equivalent) if no format is specified, in Your
> Product, provided your distribution is subject to terms and conditions
> consistent with your rights and obligations under this Agreement.”

> „2.3 Restrictions. Except as authorized above, you will not: (a) use or
> modify Material in any other way, (b) reverse engineer, decompile, or
> disassemble Material provided as object code …, (c) distribute Your Product
> or use Your Product in a production environment, or (d) use Material to
> violate or aid in the violation of any internatio[nal law]…”

Znaczenie dla USOS: redystrybucja **tylko** jako „Redistributables” wymienione
w `redist.txt`, wyłącznie „in Your Product” i bez prawa sublicencji →
klasyfikacja **tylko użytkownik** (użytkownik pobiera sam; USOS nie dołącza).

**[L3] Aquantia/Marvell — tekst niedostępny.** Strona pobierania [R5] zawiera
wyłącznie pole „I have read and accept the above legal terms”; sam blok
„above legal terms” jest wstawiany skryptem i **nie występuje w HTML**
(2026-10-22). Nie ma więc czego zacytować → **nieznana**. Strona Marvella [R8]
przy sprawdzeniu: HTTP 403.

## 5. Co robi USOS dziś (stan repo, bez zmian w kodzie)

* **Własnego sterownika Realteka nie ma.** `usosnet` ma back-endy `igb`
  (rundа 1), `e1000e` (rundа 2), `igc` i `rtl8168` — ten ostatni wyłącznie
  jako plan „(later)”: `docs/usosnet-design-2026-10-18.md` (diagram
  architektury i tabela układów: „B450 / 990FX / P67 | RTL8111/8168 | 10EC:8168
  | rtl8168”). W `tools/nt/usosnet/` nie ma **żadnego** pliku źródłowego
  Realteka (grep `rtl8168|rtl81` w `*.c` — brak trafień).
* **9x/2000/XP:** USOS stawia tylko **parę SYS/INF dostarczoną przez
  użytkownika**, i tylko gdy PCI faktycznie pasuje —
  `docs/network-defaults-2026-10-20.md` („Existing usosnet NDIS 5, only with
  matching Ethernet PCI ID and SYS/INF pair”, `stage_driver` /
  `network_setup.sh`). Czyli dla Realteka USOS **nic nie wnosi** — działa
  wyłącznie to, co użytkownik sam wgra.
* **95/NT4:** `usosnet4.sys` (NDIS 4.0) obsługuje **tylko `igb`**
  (`docs/usosnet-ndis4-2026-10-20.md`); na NT4 zostaje loopback
  `198.51.100.1/24`, jawnie **nie** LAN (`docs/network-defaults-2026-10-20.md`).
* **9x — realna luka na nowszych rewizjach:** `docs/research/win98-feasibility.md`
  §8: oficjalne NDIS5 9x istnieje dla wczesnych rewizji (8111B; INF sugeruje
  8111D, paczka „ndis5x-pcie (654)”), natomiast dla 8111E/F/G/H i 8125 pod
  98 SE pozostaje **tylko NDIS2** `RTGND.DOS` (real-mode, wyjście do DOS
  nieodwracalne), a ME nie ma NDIS2.
* **Płyta testowa X470 ma Intel I211-AT** (`8086:1539`), nie Realteka —
  `docs/windows-modern-servers-2026-10-10.md`; Realtek dotyczy B450/990FX/P67.

## 6. Rekomendacja (zgodnie z zasadą projektu)

Zasada: **własny sterownik tylko wtedy, gdy (a) nie ma redystrybuowalnego
sterownika producenta, (b) jest potrzebny do używalnego systemu i (c) obejmuje
całą rodzinę układów, a nie jeden model.**

1. **Realtek RTL8111/8168 — NIE pisać własnego sterownika teraz.**
   Warunek (a) nie jest spełniony: producent wydał sterowniki dla 98 SE, ME,
   2000, XP x86/x64, 2003 x86, Vista x86/x64 i 7 x86/x64 (sekcja 2), a dla
   10/11 wydaje je nadal. Brakuje tylko 95 i NT4 — i to są dokładnie dwa
   systemy, w których USOS ma już własny `usosnet4` (ndis4) dla `igb`.
   Zamiast nowego sterownika: **ścieżka użytkownika** — pobranie od Realteka
   (URL-e w tabeli) i staging istniejącym `stage_driver`/`network_setup.sh`,
   który już wymaga zgodnego PCI ID. To nie wymaga zmian w kodzie.
   **Zastrzeżenie licencyjne:** [L1] nie daje zgody na redystrybucję, więc
   pakietów Realteka **nie wolno** wrzucać do repo ani do payloadu; może je
   pobrać wyłącznie użytkownik.
2. **Jedyny realny przypadek na własny back-end: NT4/95 z RTL8111 na płycie
   użytkownika.** Tu (a) jest spełnione (producent nic nie wydał), (b) bywa
   spełnione (NT4 bez LAN = loopback), a (c) da się spełnić, bo `usosnet`
   jest zaprojektowany rodzinnie. Jeśli to wejdzie do zakresu, to **jako
   back-end `rtl8168` w istniejącym `usosnet4` (NDIS 4.0)** — jedna gałąź
   kodu dla 8111B–H/8168B–H, nie sterownik na jeden model. Kolejność:
   po `igb` (rundа 1) i `e1000e` (rundа 2), zgodnie z `usosnet-design`.
3. **RTL8125, Intel I225/I226, AQC107/AQC113 — NIE.** To układy współczesne;
   dla systemów z zakresu USOS producent nie ma sterownika (albo nie potwierdza
   go źródłem), ale też **nie są one potrzebne do używalnego systemu** —
   warunek (b) nie jest spełniony, a na 7/10/11 system ma sterownik wbudowany
   lub producenta. Ich obsługa to temat na przyszłość, nie na teraz.
4. **Zanim cokolwiek dołączymy:** dla Realteka i Aquantii trzeba uzyskać
   pisemną zgodę producenta ([L1], [L3] = „nieznana”). Jedyny producent
   z odczytanym tekstem licencji to Intel ([L2]) — i on pozwala tylko na
   redystrybucję „Redistributables” w „Your Product”, co i tak wyklucza
   dołączenie do USOS bez analizy `redist.txt`.

## 7. Źródła (wszystkie sprawdzone 2026-10-22)

| ID | URL | HTTP | Co z tego odczytano |
|---|---|---|---|
| R1 | <https://www.realtek.com/Download/List?cate_id=584> | 200 | bieżący katalog rodzinny PCIe (8111/8168/8125/8126/8127): wersje 5.836, 106.35, 7.154, 8.100, 10.80.50, 11.031.50, UEFI 2.081, Linux r8168/r8125 |
| R2 | <http://web.archive.org/web/20081204063354/http://www.realtek.com/downloads/downloadsView.aspx?Langid=1&PNid=13&PFid=5&Level=5&Conn=4&DownTypeID=3&GetDown=false> | 200 | archiwum 2008-12-04 dla 8111B/8168B: „Win98ME Driver 5.708”, „Auto installation program (Support Win98SE/WinME) 5.708”, „Auto installation program (Support WinXP64/WinXP/Win2K) 5.708”, „WinXP (WinServer 2003) Driver 5.708”, Vista 6.213 |
| R3 | <https://web.archive.org/web/20261017150114/https://www.intel.com/content/www/us/en/download/15084/intel-ethernet-adapter-complete-driver-pack.html> | 200 (direct 403) | Intel Ethernet Complete Driver Pack 31.3 + pełny „Intel OBL Distribution (Commercial Use) License Agreement [v2025.02.12]” |
| R4 | <https://web.archive.org/web/20190918030013/https://www.aquantia.com/support/> | 200 | FAQ Aquantii: „Microsoft Windows 10, 8.1, 8, 7 (32/64 bit), Linux 3.2, 3.10, 3.12, 4.2, and 4.4.” |
| R5 | <https://web.archive.org/web/20190910023841/https://www.aquantia.com/support/driver-download/> | 200 | formularz „Part Number / Platform / Language” (lista AQC107, AQN-107…); wersje i tekst „legal terms” ładowane dynamicznie |
| R6 | <https://www.realtek.com/Download/List?cate_id=594> | 200 | wpisy „Windows 95 for Driver only” i „Windows NT 4.0 for Driver only” v A4.06 — kodeki audio, nie NIC |
| R7 | <https://www.realtek.com/Download/List?cate_id=587> | 200 | katalog 10/100 PCI (RTL8139) z „Win98ME Driver” i „WinXP 32/64 and Win2K” — inna rodzina, nie 8111/8168 |
| R8 | <https://www.marvell.com/support/downloads.html> | 403 (zapis archiwalny 200) | brak pozycji AQtion/AQC113 w odczytanym zapisie |

Ograniczenia badania (jawne, nie zgadywane):
`intel.com` ARK i `marvell.com` blokują bezpośredni odczyt (403), więc
obsługa **I225/I226 na 7** oraz **cała AQC113** pozostają
„nieznana/niepotwierdzone”; wersji Aquantii nie da się odczytać z formularza
dynamicznego [R5]; przynależność RTL8125 do konkretnych pakietów Windows
wymagałaby INF, którego zgodnie z zadaniem nie pobierano.
