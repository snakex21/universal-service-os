# Audyt gałęzi i worktree USOS — 2026-10-22

Dokument analityczny (bez zmian w kodzie). Zakres: wszystkie gałęzie lokalne + wszystkie
worktree. Każde zdanie poniżej opiera się na wyniku konkretnej komendy git — kluczowe
fragmenty wklejono w sekcji 6.

## 0. Metodyka i snapshot

- Repo/worktree bazowy: `C:\Users\ASRock\Desktop\usos-x470-98se` (gałąź `test/x470-98se-qemu`).
- Audyt prowadzony **wyłącznie** z worktree `C:\Users\ASRock\usos-work\ds-branch-audit`
  (gałąź `ds/branch-audit`, HEAD `43976323`), komendy przez `git -C` / cwd worktree.
- Snapshot danych: **`test/x470-98se-qemu` = `79292a62` (2026-10-22 19:20:51 +0200)**.
- **Ważne: baza przesuwała się w trakcie audytu.** Reflog:
  `fff21d18 → 43976323 → b8471402 → 79292a62`. Równolegle (poza tym zadaniem) scalano
  `fix/w7x86-res` (`43976323`), `ds/posready-res` (`b2604f3b`), `ds/win8-rtm-x86` (`79292a62`).
  Commit bazowy podany w zadaniu (`43976323`) to stan z początku audytu.
- Stan liczbowy (snapshot): **107 gałęzi lokalnych**, z tego **93 w bazie** (w tym sama baza),
  **14 niescalonych**, **17 worktree**, 0 stashy. Remote: `origin` =
  `https://github.com/snakex21/universal-service-os.git`.

Użyte komendy:

```
git for-each-ref --sort=-committerdate --format='%(committerdate:short) %(refname:short) %(objectname:short)' refs/heads
git worktree list --porcelain
git branch --merged test/x470-98se-qemu
git branch --no-merged test/x470-98se-qemu
git log -1 --format='%h %ad %s' --date=short <branch>
git log --oneline -5 <branch>
git diff --shortstat test/x470-98se-qemu...<branch>
git rev-list --count test/x470-98se-qemu..<branch>
git rev-list --count --cherry-pick --right-only test/x470-98se-qemu...<branch>   # = liczba "+" w git cherry
git cherry -v test/x470-98se-qemu <branch>
```

Legenda kolumny `cherry`: `+` = brak odpowiednika w bazie, `−` = odpowiednik (patch-id) już
w bazie. Liczby `+N/−M` pochodzą z `git cherry -v` (commity nie-merge).

## 1. Gałęzie niescalone z `test/x470-98se-qemu` (14)

| Gałąź | Czego dotyczy (z `git log`) | Ostatni commit | `diff --shortstat` vs baza | `git cherry` | Rekomendacja + powód |
|---|---|---|---|---|---|
| `codex/macos-archive` | macOS: archiwum lokalne + opcjonalny start OpenCore z read-only DATA, DLC, harness VM | `f48e0f88` 2026-10-18 | 43 pliki, +4344/−6 | **+5/−0** | **DO DECYZJI** — 5 commitów nieobecnych w bazie, temat macOS jest w roadmapie odłożony; nic nie jest zepsute, więc nie ma powodu kasować przed decyzją o macOS |
| `codex/macos-dlc` | generator przenośnego macOS DLC + izolowany harness VM | `8a49a742` 2026-10-18 | 28 plików, +2055/−2 | **+4/−0** | **USUNĄĆ po `macos-archive`** — to podzbiór: jego 4 commity (`060b4300`, `edf487e5`, `fe8ab685`, `8a49a742`) są w `codex/macos-archive`, która ma dodatkowo `f48e0f88` |
| `codex/testmode-watermark` | eksperymentalna prezentacja pulpitu Vista w trybie testowym + harness `usoswm_vm` (RDP) | `5f0d0c7c` 2026-10-18 | 37 plików, +2271/−45 | **+0/−4** | **USUNĄĆ** — wszystkie 4 commity mają odpowiedniki w bazie (`git cherry -v` = same `−`), a `tools/tests/usoswm_vm/*` istnieje w bazie w identycznym zestawie plików (sprawdzone `git ls-tree`); resztka diffu to stan sprzed późniejszych poprawek w `feat/vista-x64-nvme` |
| `feat/nt4-usb-sticks` | NT 4.0 na stickach USB przez `usosusb 1.1-nt4` (xHCI owner), litery FAT12/16/NTFS, opt-out flow, docs, hash Legacy Core — praca Codexa | `ed1e1459` 2026-10-20 | 10 plików, +902/−19 | **+3/−0** | **DO DECYZJI** — realna, niescalona funkcja (m.in. +394 linii w `tools/nt4/usosusb/src/usosusb.c`), żaden commit nie jest w bazie; brak potwierdzenia na sprzęcie (merge `f1e6ba12`: „NT4 untested”). Nie scalać bez testu X470, nie kasać przed decyzją |
| `feat/vista-x64-testmode-text` | Vista x64: wygaszanie „Test Mode” u źródła (USER32 string 738, potem 722/723), patch WinSxS, `--report`, testy | `ec77e929` 2026-10-21 | 12 plików, +996/−77 | **+3/−0** | **USUNĄĆ** — eksperyment **nie zadziałał** (decyzja: zostaje `usoswm`); w bazie jest już jego zapis w dokumentacji (`966b067a`: „test-mode MUI string approach recorded as tried, ineffective on X470, not used”), więc kod nie jest potrzebny do historii |
| `feature/legacy-compat-pack` | pack kompatybilności 95/98/Me/NT4: USOSADD, manifest, presety, staging, WinSPatcher, testy | `d5c498d2` 2026-10-03 | 61 plików, +7625/−12 | **+2/−8** | **ZOSTAWIĆ** — 8 z 10 commitów ma odpowiedniki w bazie, ale 2 brakują (`a5930279` inventory/manifest/USOSADD runner, `934bd3c3` WinSPatcher), a worktree `usos-legacy-pack` ma **12 niezacommitowanych plików** = aktywna praca |
| `fix/bios-ps2-keyloss` | BIOS Core: maskowanie IRQ1/IRQ12 podczas wywołań BIOS (gubione klawisze PS/2) + Recipe init (3 KiB) | `1de999ea` 2026-10-03 | 4 pliki, +211/−1 | **+1/−1** | **DO DECYZJI (blisko USUNĄĆ)** — `1de999ea` ma odpowiednik w bazie (`4de14311`, ten sam temat), ale `b8432dcf` („field-by-field Recipe init frees 3 KiB”) nie ma; przed usunięciem sprawdzić, czy headroom nie jest dziś realizowany inaczej (`92a73093` „43 KiB headroom”, `ea30c6d4` „4 KiB headroom”) |
| `fix/w7x64-two-mode-polish` | wyłącznie notatka docs (18 linii): status w7x64 native-res „X470 PASS z flagą, polish zatrzymany” | `b290f2e8` 2026-10-21 | 1 plik, +18 | **+1/−0** | **ZOSTAWIĆ** — decyzja użytkownika: gałęzie Win7 x64 zostają; to jedyny nieobecny w bazie commit (szczegóły w 2.2) |
| `fix/w7x86-usb-fallback` | portable mode instalatora (settings/MOK markery/journal AutoPlay/TEMP przy EXE) | `02a4162a` 2026-10-21 | 16 plików, +378/−25 | **+1/−0** | **DO DECYZJI** — commit świadomie **pominięty** przy scalaniu (`f78e30ba`: „portable installer commit 02a4162a left out”); albo wraca osobno, albo gałąź do kosza |
| `master` | stary pień: 1.1 (BIOS via CSMWrap, XP x64/2003 bez CSM), `fix/bios-ps2-keyloss`, ROADMAP Custom OS | `275696db` 2026-10-03 | 5 plików, +238/−1 | **+3/−1** | **ZOSTAWIĆ** — to gałąź wydania publicznego (master na origin), nie „resztka” rozwojowa |
| `private/xp64-acpi` | „PRIVATE local-only”: XP x64 community ACPI pod `USOS_PRIVATE_XP64_ACPI` + golden | `68d685c9` 2026-09-30 | 2 pliki, +107 | **+8/−0** | **ZOSTAWIĆ** — commity jawnie oznaczone jako lokalne/prywatne (nie do bazy), 8 commitów to głównie merge'e z pnia; usunięcie = utrata prywatnego wariantu |
| `test/x470-98se-usb` | stary wątek testowy 98 SE USB: pakowanie xhci98 do `EFI\USOS\dos-native\win9x` | `94e0cce2` 2026-10-05 | 89 plików, +16510/−57 | **+1/−1** (jedyny własny commit = `−`) | **USUNĄĆ** — temat przejęty przez `int/9x-final` i `fix/w7x86-usb-sticks` (oba w bazie); duży diff to spakowane binaria payloadu, nie kod |
| `test/x470-w2k-98se` | stary wątek testowy W2k + 98 SE (merge `feature/win9x-modern`, `feature/win2000-modern`) | `baec8cdb` 2026-10-03 | 93 pliki, +3392/−230 | **0 commitów treści** (same merge'e, `git cherry -v` pusty) | **USUNĄĆ** — brak własnych commitów; obie gałęzie źródłowe są już w bazie, diff jest tylko skutkiem późniejszych zmian w bazie |
| `test/x470-w2k-diag` | diagnostyka W2k: ACPI z DATA, `usosrst` 1.3 clock/HPET, **commity „test branch only … (do not merge)”** | `2b011a31` 2026-10-04 | 104 pliki, +3948/−297 | **+13/−0** | **USUNĄĆ** — gałąź sama deklaruje „do not merge” (goldeny i `Legacy Core minimum headroom 3072` tylko pod test), diagnostyka zakończona, wnioski trafiły do `feature/w2k-*` w bazie |

## 2. Szczególne przypadki (wymagane osobno)

### 2.1 `feat/w7x64-native-res` — **ZOSTAJE** (decyzja użytkownika: opcja Win7 x64 świadomie WYŁĄCZONA)

- Ostatni commit: `ea6ebbca` 2026-10-21 („win7 x64 native-res: DATA flag → target ESP, USOSRES staging, one EDID helper”).
- **Stan: gałąź jest już w bazie.** `git rev-list --count test/x470-98se-qemu..feat/w7x64-native-res` = **0**;
  `git diff --shortstat ...feat/w7x64-native-res` = pusty; `git cherry` = 0 linii.
  Wynika to z merge'a `42b63ee9` („merge: feat/w7x64-native-res — Win7 x64 UefiSeven
  native-resolution experiment, **default off** … QEMU: Setup reached with native GOP, Setup itself
  stays 1024x768; X470 pending”), potem `21dd871b` i `144e7f4e`/`d1035466`.
- W bazie jest więc kod eksperymentu za flagą (`DATA\Unattended\native-res-on.txt`), a opcja pozostaje
  domyślnie wyłączona — zgodnie z decyzją. **Nie proponuję usunięcia**; technicznie gałąź jest
  redundantna (0 unikalnych commitów), ale zostaje jako punkt odniesienia.

### 2.2 `fix/w7x64-two-mode-polish` — **ZOSTAJE** (ta sama decyzja)

- Ostatni commit: `b290f2e8` 2026-10-21, **1 commit, 1 plik, +18 linii** — to wyłącznie notatka
  dokumentacyjna „w7x64 native-res status note (X470 PASS with flag, polish round stopped)”.
- **Stan: NIE jest w bazie** (`git cherry` = `+1`). To jedyny niecommitowany w bazie fragment
  wiedzy o zakończonym polishu Win7 x64; jeśli kiedyś ma zniknąć, to najpierw przez scalenie samej
  notatki, nie przez usunięcie gałęzi.

### 2.3 `feat/vista-x64-testmode-text` — niescalona, **nie zadziałała** → **USUNĄĆ**

- 3 commity, `ec77e929` 2026-10-21, 12 plików, +996/−77 (`tools/vista_testmode_text.h` +204,
  `tools/windows_vista_install.c` +108, `tools/tests/test_vista_testmode_text.py` +347,
  `docs/vista-x64-testmode-text-2026-10-21.md` +168).
- Żaden z 3 commitów nie ma odpowiednika w bazie (`git cherry` = `+3`).
- Powód usunięcia: podejście (patch stringów USER32 738/722/723 + WinSxS) **nie zadziałało** na X470,
  decyzja projektowa to pozostanie przy `usoswm`. W bazie jest już zapis próby i wniosku w commicie
  `966b067a` (w historii `feat/w7x64-native-res`, dziś w bazie): „test-mode MUI string approach
  recorded as tried, ineffective on X470, not used (usoswm stays)”. Historia próby jest zatem
  zabezpieczona, a kod nie jest rozwijany.

### 2.4 `feat/nt4-usb-sticks` — praca Codexa → **DO DECYZJI**

- 3 commity: `adfa2036` (nt4: USB sticks przez `usosusb 1.1-nt4`, litery FAT12/16/NTFS, opt-out flow),
  `f4230043` (docs), `ed1e1459` (hash Legacy Core), ostatni 2026-10-20.
- `git cherry` = `+3` — **nic z tego nie ma w bazie**; diff: 10 plików, +902/−19, w tym binarny
  `tools/nt4/usosusb/bin/i386/usosusb.sys` 22400 → 43648 B, +394 linie w `usosusb.c`, nowy test
  `tools/tests/test_nt4_usosusb_storage.py` (+259) i `tools/tests/nt4usb/vol_host.c`.
- Uzasadnienie decyzji: to jedyna niescalona, kompletna funkcja z testami jednostkowymi; brakuje
  **testu na sprzęcie** (przy pokrewnym scaleniu `f1e6ba12` zapisano „NT4 untested”). Nie usuwać,
  nie scalać bez wyniku X470.

### 2.5 Wszystkie `ds/*`

| Gałąź | Własne commity | Stan względem bazy (snapshot `79292a62`) | Wniosek |
|---|---|---|---|
| `ds/fast-startup-off` | 2: `96e9b7b2` (HiberbootEnabled=0 dla 8/8.1/10), `268f2f59` (review: native opt-out, flush log, unload retry) | **w bazie** przez `11d022f6` (merge „merge: ds/fast-startup-off — … (reviewed: native opt-out fix, flush logging, unload retry)”) | **zbędna — USUNĄĆ** (gałąź; worktree nie ma) |
| `ds/xp-sp-variants` | 1: `a91d873d` (XP RTM/SP1/SP2/SP3 z markerów WIN51IP.SPn) | **w bazie** przez `7380b1db` | **zbędna — USUNĄĆ** |
| `ds/posready-res` | 2: `21d694ce` (USOSRES+DISPLAY.TXT w `\USOS\POSR`, rejestracja `USOSDisplay`), `9cc36b19` (log Run tylko gdy USOSRES staged) | **w bazie** przez `b2604f3b` (scalone w trakcie audytu) | **zbędna — USUNĄĆ** (worktree `ds-posready-res` czysty) |
| `ds/win8-rtm-x86` | 2: `b960b995` (Win8 RTM 6.2.9200 x86 na `win-x86-uefi-csmwrap`), `21902d43` (review: gate na media 32-bit) | **w bazie** przez `79292a62` (scalone w trakcie audytu) | **zbędna — USUNĄĆ** (worktree `ds-win8-rtm-x86` czysty) |
| `ds/test-robustness` | 0 — tip `43976323` jest już w bazie | **w bazie**; worktree ma 1 plik nieśledzony (`baseline.txt`) | **zbędna — USUNĄĆ worktree** po skasowaniu `baseline.txt`, potem gałąź |
| `ds/branch-audit` | 1 (ten raport) | poza bazą do czasu scalenia raportu | **ZOSTAWIĆ** do merge'a raportu; potem usunąć |
| `ds/fast-startup-off`, `ds/xp-sp-variants` | — | brak worktree (tylko ref) | jak wyżej |

Podsumowanie `ds/*`: **wszystkie czekają już tylko na sprzątanie** — `fast-startup-off`, `xp-sp-variants`,
`posready-res`, `win8-rtm-x86` są w bazie; `test-robustness` nie ma własnych commitów; jedyną gałęzią
`ds/*` z treścią poza bazą jest `ds/branch-audit` (raport).

## 3. Gałęzie scalone — „scalone, można usunąć” (92 + sama baza = 93)

Wszystkie poniższe mają tip będący przodkiem `test/x470-98se-qemu` (`git branch --merged`),
czyli `git branch -d` jest bezpieczne (git odmówi, gdyby jednak coś nie było scalone).
Data = ostatni commit gałęzi.

| Grupa | Gałęzie (data ostatniego commita) |
|---|---|
| `codex/*` (5) | bety-warianty 10-19, pakiet-zgodnosci 10-19, rozdzielczosc-z-profilu 10-19, siec-9x-instalator 10-19, win7-x86-usb 10-20 |
| `diag/*` (1) | w2k-usosvid-heartbeat 10-14 |
| `docs/*` (1) | xp-tablet-e2e 10-09 |
| `ds/*` (6) | branch-audit 10-22, fast-startup-off 10-22, posready-res 10-22, test-robustness 10-22, win8-rtm-x86 10-22, xp-sp-variants 10-22 |
| `feat/*` (7) | nt6-display 10-21, pe10-x86-donor 10-20, usosusb-hubs 10-21, vista-x64-mpart 10-21, vista-x64-nvme 10-21, w7x64-native-res 10-21, x86-modern-display 10-22 |
| `feature/*` (55) | acpi-raw-dump 10-13, bios-via-csmwrap 09-29, csmwrap-acpi10 10-13, custom-os 10-11, dos-mouse 10-18, menu-probe-cache 10-11, nt31 10-10, nt351 10-08, nt351-pci 10-09, nt351-x470 10-08, nt3-nvme 10-13, nt3-polish 10-14, nt3-vesa 10-14, nt4 10-07, nt4-server 10-07, nt4-server-2 10-07, nt4-tse 10-10, nt52-xhci98 09-29, nt60-usosusb 10-11, nt6-no-disk-page 10-11, nt6-x86-nocsm 10-10, nt6-x86-usb3 10-11, nvme-9x 10-14, nvme-nt 10-11, nvme-nt6 10-12, nvme-nt6-x64 10-14, nvme-pe-lowmem 10-13, profile-options 10-12, profile-options-2 10-14, srv2012r2 10-10, srv-modern 10-08, srv-modern2 10-10, usb-multipart 10-14, usosusb-msc 10-12, w2k-acpi-csmen 10-14, w2k-acpi-diag 10-13, w2k-acpi-qword 10-13, w2ks-usosbug 10-09, w2k-watcher 10-15, win1-mouse 10-15, win2000-modern 10-05, win2000-server 10-08, win203-diag 10-09, win203-diag2 10-09, win203-diag3 10-09, win9x-modern 10-05, win9x-qemu-phase1 10-07, win9x-usb-mouse 10-06, win-early 10-07, win-early-2 10-08, win-early-mouse 10-09, x470-followups-1012 10-12, xp-mce 10-08, xp-tablet 10-09, xp-tablet-integrated 10-09 |
| `fix/*` (15) | esp-ro-during-vm 10-11, fb-ui-theme 09-29, hide-csmwrap-partition 10-22, nt4-sp6-old-sfx 10-12, profile-editor-ux 09-29, res-noanswer-win10 10-22, test-triage 10-12, usosnvme-flush 10-22, usosnvme-nt6-poll 10-14, vista-x86-winsat-stick-dirty 10-11, w7x86-res 10-22, w7x86-usb-sticks 10-21, x86-answer-arch-key 10-11, x86-modern-stage2 10-22, x86-modern-stage3 10-22 |
| `int/*` (2) | 9x-final 10-20, siec-fix 10-19 |

Uwaga: `feat/w7x64-native-res` i `ds/*` są w tej tabeli, bo są już w bazie — to nie koliduje z sekcją 2:
decyzja użytkownika każe **zostawić** gałęzie Win7 x64 mimo technicznej redundantności.

## 4. Worktree (17)

`git status --porcelain` w każdym worktree sprawdzony. „Stale” = tip gałęzi jest już przodkiem bazy
i/lub commit jest wyraźnie stary.

| Ścieżka | Trzymana gałąź | HEAD (data) | Brud (`git status`) | Stale? | Czy bezpiecznie `git worktree remove`? |
|---|---|---|---|---|---|
| `C:/Users/ASRock/Desktop/universal-service-os` | `master` | `275696db` 2026-10-03 | 4 (`M CONTRIBUTING.md`, `M docs/ROADMAP.md`, `M installer/internal/payload/legacy_boot_generated.go`, `?? CLAUDE.local.md`) | nie (pień wydania) | **NIE** — główny checkout, lokalne modyfikacje dokumentacji |
| `C:/Users/ASRock/Desktop/usos-legacy-pack` | `feature/legacy-compat-pack` | `d5c498d2` 2026-10-03 | 12 (USOSADD `cmd.c/main.c/ua.h`, `stage_legacy_pack.py`, testy, `?? usoschk.c`, `nettest.*`) | nie — aktywna praca | **NIE** — niezacommitowana praca |
| `C:/Users/ASRock/Desktop/usos-x470-98se` | `test/x470-98se-qemu` | `79292a62` 2026-10-22 | 3 (`M CONTRIBUTING.md`, `M docs/ROADMAP.md`, `?? CLAUDE.local.md`) | nie — baza | **NIE** — worktree bazowy |
| `C:/Users/ASRock/Documents/Codex/2026-10-20/cze/work/usos-win7-usb` | `codex/win7-x86-usb` | `97f40f01` 2026-10-20 | **65** (instalator: `autoplay/*`, `i18n/locales/*`, docs, `journal_*`) | gałąź w bazie, ale worktree brudny | **NIE** — 65 plików; najpierw ustalić, czy to źródło `02a4162a` (portable mode), potem commit/archiwizacja |
| `C:/Users/ASRock/usos-work/ds-branch-audit` | `ds/branch-audit` | `43976323` 2026-10-22 | 0 | nie — ten raport | **NIE** do czasu scalenia raportu |
| `C:/Users/ASRock/usos-work/ds-posready-res` | `ds/posready-res` | `9cc36b19` 2026-10-22 | 0 | tak (merge `b2604f3b`) | **TAK** (po ewentualnym `git branch -d ds/posready-res`) |
| `C:/Users/ASRock/usos-work/ds-test-robustness` | `ds/test-robustness` | `43976323` 2026-10-22 | 1 (`?? baseline.txt`) | tak (0 własnych commitów) | **TAK** po skasowaniu `baseline.txt` (albo `--force` świadomie) |
| `C:/Users/ASRock/usos-work/ds-win8-rtm-x86` | `ds/win8-rtm-x86` | `21902d43` 2026-10-22 | 0 | tak (merge `79292a62`) | **TAK** |
| `C:/Users/ASRock/usos-work/int-9x-final` | `int/9x-final` | `71d0d47e` 2026-10-20 | 0 | tak (w bazie przez `97f40f01`) | **TAK** |
| `C:/Users/ASRock/usos-work/macos-archive` | `codex/macos-archive` | `f48e0f88` 2026-10-18 | 0 | nie — 5 commitów poza bazą | **NIE** (czeka na decyzję o macOS) |
| `C:/Users/ASRock/usos-work/macos-dlc` | `codex/macos-dlc` | `8a49a742` 2026-10-18 | 0 | częściowo (podzbiór `macos-archive`) | **TAK** razem z decyzją o `codex/macos-dlc` |
| `C:/Users/ASRock/usos-work/nt4-usb` | `feat/nt4-usb-sticks` | `ed1e1459` 2026-10-20 | 0 | nie — 3 commity poza bazą | **NIE** (czeka na test/merge) |
| `C:/Users/ASRock/usos-work/nvme-x64` | `feature/nvme-nt6-x64` | `a15c6f50` 2026-10-14 | 5 (`usosnvme.c/.h`, `build.cmd`, `build_usosnvme_nt6_signed.py`, `?? bin/2KXP/amd64/`) | gałąź w bazie, ale brudny | **NIE** bez decyzji o tych 5 plikach (build artefakty vs poprawki) |
| `C:/Users/ASRock/usos-work/pe10-x86` | `feat/pe10-x86-donor` | `02300878` 2026-10-20 | 1 (`M installer/internal/payload/legacy_boot_generated.go`) | tak (w bazie przez `2d5b6278`) | **TAK** po cofnięciu artefaktu builda |
| `C:/Users/ASRock/usos-work/testmode-watermark` | `codex/testmode-watermark` | `5f0d0c7c` 2026-10-18 | 0 | tak (4/4 commity = odpowiedniki w bazie) | **TAK** — pierwszy kandydat |
| `C:/Users/ASRock/usos-work/w7x86-usb` | `fix/w7x86-usb-fallback` | `02a4162a` 2026-10-21 | 2 (`legacy_boot_generated.go`, `tools/tests/golden/staged_payloads.tsv` — artefakty) | nie — commit poza bazą | **NIE** dla gałęzi; worktree tak po cofnięciu artefaktów |
| `C:/Users/ASRock/usos-work/x86-answer-key` | `fix/x86-answer-arch-key` | `a255f559` 2026-10-11 | 0 | tak (w bazie) | **TAK** |

Brak worktree (tylko ref) dla: `ds/fast-startup-off`, `ds/xp-sp-variants` oraz ~85 pozostałych gałęzi scalonych.

## 5. Wnioski — co realnie sprzątać w pierwszej kolejności

1. **Worktree + gałęzie bez pracy i bez brudu (najbezpieczniejsze, ~5 min).**
   `git worktree remove` dla: `testmode-watermark`, `int-9x-final`, `x86-answer-key`,
   `ds-win8-rtm-x86`, `ds-posready-res`, `ds-test-robustness` (po `baseline.txt`), `pe10-x86`
   (po `git checkout -- installer/internal/payload/legacy_boot_generated.go`), potem `git branch -d`
   dla: `codex/testmode-watermark`, `int/9x-final`, `fix/x86-answer-arch-key`, `ds/fast-startup-off`,
   `ds/xp-sp-variants`, `ds/posready-res`, `ds/win8-rtm-x86`, `ds/test-robustness`.
2. **Gałęzie-redundanty bez worktree (drugi rzut).**
   `test/x470-98se-usb`, `test/x470-w2k-98se`, `test/x470-w2k-diag` (same merge'e / „do not merge”),
   `feat/vista-x64-testmode-text` (nie zadziałało), `codex/macos-dlc` (podzbiór `macos-archive`),
   `fix/bios-ps2-keyloss` (po sprawdzeniu `b8432dcf`).
3. **Masowe czyszczenie 92 gałęzi scalonych** — najlepiej `git branch -d` na liście z
   `git branch --merged test/x470-98se-qemu` (bez `-D`), żeby git sam zablokował pomyłkę.
   To realnie 80 % „porządku” w `git branch`.
4. **Brudne worktree — najpierw decyzja, potem sprzątanie.**
   `usos-win7-usb` (65 plików!), `nvme-x64` (5), `usos-legacy-pack` (12) — tam jest
   niezacommitowana praca; usuwanie worktree bez commita = utrata zmian.
5. **Nie ruszać w tym sprzątaniu:** `master` (pień wydania), `private/xp64-acpi` (świadomie
   prywatne), `feature/legacy-compat-pack` (aktywna praca), `feat/nt4-usb-sticks` (czeka na test),
   `fix/w7x86-usb-fallback` (commit pominięty świadomie), `codex/macos-archive` (odłożony temat),
   `feat/w7x64-native-res` + `fix/w7x64-two-mode-polish` (decyzja użytkownika: zostają),
   `ds/branch-audit` (do scalenia raportu).
6. **Przed każdym usunięciem powtórzyć `git cherry`** — baza przesunęła się w trakcie tego audytu
   (`43976323 → 79292a62`), więc część „niescalonych” może być już w bazie.

## 6. Kluczowe fragmenty komend (dowody)

```
$ git rev-parse ds/posready-res ds/win8-rtm-x86 test/x470-98se-qemu
9cc36b19... 21902d43... 79292a62...

$ git reflog show test/x470-98se-qemu -4
79292a62 test/x470-98se-qemu@{0}: commit: build B261022-171004-34CE3CB4: ...
43976323 test/x470-98se-qemu@{1}: commit (merge): merge: fix/w7x86-res - USOSRES NT 6.x ...
b8471402 ... ; fff21d18 ...

$ git log --oneline -6 --grep='^merge:' test/x470-98se-qemu
79292a62 merge: ds/win8-rtm-x86 - Windows 8 RTM (6.2.9200) 32-bit media on win-x86-uefi-csmwrap ...
b2604f3b merge: ds/posready-res - POSReady 2009 stages USOSRES + DISPLAY.TXT in \USOS\POSR ...
43976323 merge: fix/w7x86-res - USOSRES NT 6.x waits for the input desktop ...
7380b1db merge: ds/xp-sp-variants - XP service level from WIN51IP.SPn markers ...
11d022f6 merge: ds/fast-startup-off - HiberbootEnabled=0 in USOS Windows 8/8.1/10 installs ...
42b63ee9 merge: feat/w7x64-native-res - Win7 x64 UefiSeven native-resolution experiment, default off ...

$ git cherry -v test/x470-98se-qemu feat/vista-x64-testmode-text
+ c62965db vista x64: blank the desktop "Test Mode" text at its source (USER32 string 738)
+ 2713a22c vista x64: also blank the version line (USER32 722/723); retire usoswm from the path
+ ec77e929 vista x64: test-mode strings -> single space (not empty); patch WinSxS; add --report

$ git cherry -v test/x470-98se-qemu codex/testmode-watermark
- 171339f9 wip: add experimental Vista test-mode desktop presentation and scoped staging
- 7ff49e6b fix: render Vista JPEG backgrounds and handle desktop session shutdown
- 55e8a737 fix: cover the Vista setup desktop and hide bootstrap consoles
- 5f0d0c7c test: measure Vista setup lifecycle and real RDP session desktops

$ git cherry -v test/x470-98se-qemu feat/nt4-usb-sticks
+ adfa2036 nt4: USB sticks through usosusb 1.1-nt4 (the xHCI owner), FAT12/16/NTFS letters, flow opt-out
+ f4230043 docs: NT 4.0 USB sticks (usosusb 1.1-nt4) in the NT4 notes
+ ed1e1459 installer: Legacy Core hash for build B261020-200536-968CCBE8

$ git cherry -v test/x470-98se-qemu feature/legacy-compat-pack
+ a5930279 legacy pack: compatibility/post-install pack for Windows 95/98/Me/NT4 (...)
- 9015c99f legacy pack: presets, fault-tolerant summary (...)
... (8 x "−")
+ 934bd3c3 legacy pack: WinSPatcher 98/NT hotfix groups, downloaded packages, innoextract in the build kit

$ git cherry -v test/x470-98se-qemu fix/bios-ps2-keyloss
+ b8432dcf bios core: field-by-field Recipe init frees 3 KiB Core headroom
- 1de999ea bios core: mask IRQ1/IRQ12 during BIOS calls so PS/2 menu keys are not lost
$ git log --oneline -4 --grep=IRQ1 test/x470-98se-qemu
4de14311 bios core: mask IRQ1/IRQ12 during BIOS calls so PS/2 menu keys are not lost   # odpowiednik w bazie

$ git rev-list --count test/x470-98se-qemu..feat/w7x64-native-res
0
$ git diff --shortstat test/x470-98se-qemu...feat/w7x64-native-res
(empty)
$ git cherry test/x470-98se-qemu feat/w7x64-native-res
(empty)

$ git ls-tree -r --name-only test/x470-98se-qemu -- tools/tests/usoswm_vm     # 13 plików, ten sam zestaw co w codex/testmode-watermark
$ git log --oneline -1 966b067a
966b067a docs: X470 PASS Vista SP2 PL x64 (...), test-mode MUI string approach recorded as tried, ineffective on X470, not used (usoswm stays)

$ git worktree list --porcelain   # 17 worktree, wypisane w sekcji 4
$ git status --porcelain          # per worktree, liczby brudu w sekcji 4
```

Uwaga końcowa: ten audyt **nie zmienił** żadnego pliku kodu, nie usunął żadnej gałęzi ani worktree,
nie wykonał merge'a i nie dotknął dysków. Jedynym artefaktem jest ten dokument.
