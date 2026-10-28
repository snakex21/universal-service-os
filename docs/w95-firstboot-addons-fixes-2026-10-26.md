# W95RTM-FIRSTBOOT — integracja poprawek X470, 2026-10-26

**Użytkownik potwierdził pełny PASS RTM na X470 po swoich hotpatchach: pulpit, Full HD, sieć, jedna karta, czas i mysz. Trzy poprawki są teraz w produkcie; build i testy PASS. STOP.**

- **NDIS po W95WS2:** na końcu USOSADD, przed restartem (także przed oddaniem restartu koordynatorowi), ponawiana jest poprawka18B z Patcher9x0.9.91/d7e2ed7, MIT. Pochodzenie zapisano w `ndis_patch.h`. Wzorzec wyszukiwany po bajtach; obsługiwane oba równoważne kodowania SUB, bez stałego offsetu. Jeśli WININIT.INI kolejkuje NDIS, naprawiana jest przyszła kopia, inaczej zainstalowany NDIS.VXD. Backup obok USOSADD, zapis/flush/readback, idempotencja; nieznany/niejednoznaczny wzorzec lub błąd I/O blokuje restart. Kolejka WININIT nie jest przepisywana.
- **W95WS2:** `[pkg:ws2-95] answer1=Winsock2 Setup|1` korzysta z dotychczasowego mechanizmu odpowiedzi; reguła dotyczy tylko tego pakietu.
- **DXSETUP:** tylko jego exit1 jest normalizowany do3010 i oznacza sukces wymagający restartu; exit1 innych EXE pozostaje błędem. Zachowany jeden końcowy restart w przepływie RTM.

**Testy:** 27 testów hostowych PASS (dwa testy renderera ponowiono po dobudowaniu brakującego answer-tool), test C i1404 zgodne plany C/Python, target USOSADD i386 GUI/noCRT PASS.13 procesów naprawy NDIS sprawdza pozycje wzorca, WININIT, idempotencję, read-only, obce/zdublowane wzorce, backup i rollback po częściowym zapisie. Na oryginalnym NDIS1111 z WS2 zamiana w pamięci daje dokładnie cały plik z udanego hotpatcha X470; źródła tylko odczytane, nowych kopii MS nie zapisano.

**Build09 `B261026-153029-D4C616F2`:** exit0,104/104,632/632, testyGo i **verify_release_consistency PASS**. Cmd/build.bat, BelowNormal/2CPU/-j2, oczekiwanie na natywne zdarzenie exit bez odpytywania postępu. Nowy USOSADD i manifesty PL/EN porównano bajt w bajt z initramfs — PASS. Log `artifacts/firstboot/full-build09.log`; receipt `full-build09.result.json`; szczegóły/SHA `docs/w95-firstboot-addons-fixes-evidence-2026-10-26.json`.

Gotowy produkt: `C:\Users\ASRock\usos-work\codex-w95-firstboot\zig-out\usb` oraz `installer\USOS Installer.exe`. Świeżą instalację na Kingstonie/X470 wykonuje Claude; ta sesja nie uruchamiała QEMU ani sprzętu.

Gałąź `codex/w95-firstboot`; kod `dffbcc1f`, payload `ffd3f311`. Poprzedni build08 i instalator zachowane w `K:\USOS-VM\W95RTM-FIRSTBOOT-20261025\build-output-08-retained-for-addons-fixes`. Zachowano121 obrazów/nośników/vars, usunięto0; pula9.984/150GiB, wolneK126.906GiB (minimum100GiB). Pełna lista `artifacts/firstboot/addons-fixes-retained-images.json`. Bez MiniOS/w95-vesbind/merge/push/deploy. **STOP.**
