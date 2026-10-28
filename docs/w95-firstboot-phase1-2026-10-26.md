# W95RTM-FIRSTBOOT — faza 1 RTM PASS, 2026-10-26

Build06 pozostaje zaakceptowany: 104/104, 632/632 i verify_release_consistency PASS; bez ponownego buildu. Poprzednia próba z TCG wewnątrz TCG skończyła się na kopiowaniu 3% po limicie zewnętrznym 3600s; żaden kompletny pierwszy pulpit nie został wtedy zaliczony.

Zmiana przyspieszenia zewnętrznej VM fazy1 na WHPX usunęła tę blokadę. Wewnętrzny rzeczywisty Setup RTM PL zakończył się rc0 w307s, pełny przepływ menu→gotowy cel343,91s. Produkt zweryfikował drzewo Windows, PHASE1.OK, wstrzyknięcie NVMe i poprawki950, po czym pokazał własny komunikat gotowego celu. Payload, profil i automatyczny kontroler stron Setup bez zmian. Uzasadnienie powtórzenia wyłącznie etapu przed bazą zapisano przed uruchomieniem w RAPORT-W95RTM-FIRSTBOOT.md.

Zapisano zewnętrzną migawkę: niezmienny `_vm/rtm-nvme-02/target.qcow2` i nakładkę `target-native.qcow2`, a dalszy start tego samego celu odbywa się w nowej `native-01/target.qcow2`. Wszystko pod `K:\USOS-VM\W95RTM-FIRSTBOOT-20261025`; dowody w `phase1-accepted.json`, `prepared-snapshot.json` i `observation/{serial.log,result.json,command.json}`. Pierwszy start na docelowym sprzęcie jest w TCG, na tych samych NVMe/VGA/XHCI/igb za mostkami. Przerwa na bazę zastępuje ciepły restart zimnym startem; nie zalicza sama pełnego firstboot.

Stan na ten commit: faza1 PASS; natywny firstboot w toku; brak jeszcze PASS pulpitu, dodatków i końcowego restartu. OSR1 jeszcze nieuruchomiony. Zachowano wszystkie wcześniejsze obrazy. Bez MiniOS, zmian chronionego worktree, merge, push, deploy i fizycznych nośników.
