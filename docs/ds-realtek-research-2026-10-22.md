# Raport zadania: sterowniki NIC — Realtek RTL8111/8168 i pozostałe (2026-10-22)

Gałąź: `ds/realtek-research` (baza `test/x470-98se-qemu`, `be1f36aa`).
Charakter: **analityczny — zero zmian w kodzie**. Commit zawiera wyłącznie
pliki `.md`.

Wynik merytoryczny: [`docs/ds-nic-vendors-2026-10-22.md`](ds-nic-vendors-2026-10-22.md)
(tabele „system × karta”, cytaty licencji, rekomendacja).

## 1. Co ustalono (skrót)

* **RTL8111/8168:** producent wydał sterowniki dla **98, 98 SE, ME, 2000,
  XP x86, XP x64, 2003 x86, Vista x86/x64, 7 x86/x64**. Dla 9x/2000 są to
  wydania **wycofane** z bieżącej strony (potwierdzone tylko archiwum
  2008-12-04, wersja 5.708); dla XP/2003 bieżący pakiet to 5.836 (2021-07-27),
  dla Visty 106.35 (2021-09-08), dla 7 — 7.154 (2024-04-09).
* **95 i NT4: producent nie wydał nic** dla tej rodziny — i to jest
  uzasadnione wprost w raporcie końcowym (jedyne wpisy „Windows 95”/„NT 4.0”
  na realtek.com dotyczą kodeków audio, katalog `cate_id=594`).
* **2003 x64: „nieznana/niepotwierdzone”** — ani archiwum, ani strona bieżąca
  nie wymieniają x64 dla 2003; nie zgadywano.
* **Licencje:** Realtek **nie publikuje** tekstu licencji na stronie
  pobierania (tylko „© 2026 Realtek Semiconductor Corp. All rights reserved”)
  → „nieznana” = brak zgody na redystrybucję. Aquantia/Marvell: blok „legal
  terms” jest dynamiczny, brak tekstu → „nieznana”. **Intel** ma odczytany
  tekst: „Intel OBL Distribution (Commercial Use) License Agreement
  [v2025.02.12]”, §2.1(c) pozwala na dystrybucję wyłącznie jako
  „Redistributables” z `redist.txt`, „in Your Product” → „tylko użytkownik”.
* **Rekomendacja:** **nie pisać** własnego sterownika Realteka teraz — warunek
  „brak redystrybuowalnego sterownika producenta” nie jest spełniony, a ścieżka
  użytkownika (pobranie od producenta + istniejący `stage_driver`) już działa.
  Jedyny realny przypadek własnego kodu: **NT4/95 z RTL8111**, i wtedy jako
  back-end `rtl8168` w istniejącym `usosnet4` (NDIS 4.0), całą rodziną, a nie
  jednym modelem.

## 2. Metoda i źródła

Odczyt był wyłącznie HTML/tekst (curl/urllib), bez pobierania plików
sterowników. Wszystkie wiersze mają URL i datę sprawdzenia **2026-10-22**;
pełna tabela źródeł z kodami HTTP jest w rozdziale 7 dokumentu wynikowego.

Sprawdzone bezpośrednio (HTTP 200):

* `realtek.com/Download/List?cate_id=584` — bieżący katalog rodzinny PCIe
  (8111/8168/8125/8126/8127), tabele Windows/UEFI/Linux/DOS/Novell;
* `realtek.com/Download/List?cate_id=587` (10/100 PCI, RTL8139) i
  `?cate_id=594` (kodeki audio — tu są wpisy 95/NT4) — żeby **wykluczyć**
  pomylenie rodziny;
* `realtek.com/Download/ToDownload?downloadid=…` — sprawdzenie, czy strona
  pośrednia zawiera EULA (nie zawiera).

Przez archive.org (dozwolone w zadaniu; producent usunął stare wersje):

* zapis `realtek.com/downloads/downloadsView.aspx…PNid=13&PFid=5` z
  **2008-12-04** — dowód na 98SE/ME, 2000, XP x64 i Vista dla 8111B/8168B;
* zapis `intel.com/…/download/15084/…` z **2026-10-17** — pakiet 31.3
  i pełny tekst umowy licencyjnej Intela;
* zapisy `aquantia.com/support/` i `…/support/driver-download/` z 2019 —
  wykaz systemów (Win 7/8/8.1/10, 32/64-bit).

Blokady odnotowane, nie obchodzone: `intel.com` ARK i `marvell.com` zwracają
**403** (bez przeglądarki); `marvell.com/support/downloads.html` w zapisie
archiwalnym nie zawiera pozycji AQtion. Dlatego I225/I226 na 7 i cała AQC113
są „nieznana/niepotwierdzone”.

## 3. Dowody z repo (bez zmian w kodzie)

* `docs/usosnet-design-2026-10-18.md` — `rtl8168` istnieje tylko jako plan
  („later”); rundа 1 = `igb`, rundа 2 = `e1000e`; tabela układów wskazuje
  B450/990FX/P67 → RTL8111/8168, `10EC:8168`.
* `tools/nt/usosnet/` — grep `rtl8168|rtl81` w `*.c`: **brak trafień**, czyli
  USOS nie ma dziś żadnego kodu Realteka.
* `docs/network-defaults-2026-10-20.md` — USOS stawia tylko **parę SYS/INF od
  użytkownika** i tylko przy zgodnym PCI ID; na NT4 pozostaje loopback
  `198.51.100.1/24` (jawnie nie LAN).
* `docs/usosnet-ndis4-2026-10-20.md` — `usosnet4.sys` (95/NT4) obsługuje
  wyłącznie `igb`.
* `docs/research/win98-feasibility.md` §8 — 9x NDIS5 tylko dla wczesnych
  rewizji (8111B, INF sugeruje 8111D); 8111E/F/G/H i 8125 pod 98 SE mają
  tylko NDIS2 `RTGND.DOS`, a ME nie ma NDIS2.
* `docs/windows-modern-servers-2026-10-10.md` — płyta testowa X470 ma Intel
  I211-AT (`8086:1539`), nie Realteka.

## 4. Zgodność z ograniczeniami zadania

* **Zero zmian w kodzie** — commit zawiera wyłącznie dwa pliki `.md`
  (ten raport + dokument wynikowy).
* **Nie pobrano żadnego pliku producenta** (`.exe/.zip/.inf/.sys/.pdf`).
  Wszystkie odpowiedzi to HTML; strona `ToDownload` została pobrana jako
  **strona HTML 86 687 B** (nie archiwum) i tylko w celu sprawdzenia, czy
  zawiera EULA. Pliki tymczasowe (HTML) leżą w `%TEMP%\nicres`, poza repo.
* **Nie zmieniano** `CONTRIBUTING.md`, `docs/ROADMAP.md`, dysków, brak
  merge'a i wdrożenia.
* Rzeczy niepotwierdzone oznaczone jako **„nieznana/niepotwierdzone”**
  z podaniem przyczyny (403, formularz dynamiczny, brak INF).

## 5. Otwarte pytania (do ewentualnego osobnego zadania)

1. Czy 5.708 była **ostatnią** wersją 9x/2000 dla 8111/8168 (potrzebny szerszy
   przegląd snapshotów 2009–2012).
2. Czy pakiet XP 5.836 i Vista 106.35 zawierają katalogi x64 (wymagałoby
   przejrzenia INF — **nie wykonano**, bo to plik producenta).
3. Pisemna zgoda Realteka i Aquantii na redystrybucję — bez niej pakiety
   pozostają „tylko użytkownik”.
