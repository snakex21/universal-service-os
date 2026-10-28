# Plan cleanup zakończonych VM NT3 — bez wykonania

Nic nie usunięto. Nie uruchomiono nowych VM, nie pytano o procesy ani agentów.
To plan dokładnych własnych ścieżek na G, nie polecenie wykonania usuwania.
Dodano pięć zamkniętych root NT35-client wyłącznie na jawne zlecenie root.

Jednorazowo potwierdzono closure26 przypadków i odczytano metadane46 QCOW2:
bez błędów, dirty=false. Bez odczytu aktywnych obrazów ani logów combo01.
Przeszukano45 statycznych preparation JSON, nie logi/procesy. Wszystkie26
katalogów istnieją, bez reparse. Całość ma 4150128436B unikalnych plików;
suma rozmiarów nazw4648202036B liczy dwa hardlinki świeżego sticka osobno.
Nie jest to obietnica dokładnie odzyskanej przestrzeni NTFS.

Komplet literalnych katalogów, whole-disk plików, pozostałych plików,
bezpośrednich backing paths, file IDs, rozmiarów oraz closure path/hash:
`docs/nt3-closed-vm-cleanup-plan.json`. Oryginalny snapshot i jego hash
zachowano w `artifacts/nt3-cleanup-plan/closed-vm-inventory.json`.

## Pierwsza możliwa partia po zachowaniu dowodów

Te sześć zamkniętych liści nie ma znanego potomka w odczytanym grafie.
Ich literalne pliki są w `planned_file_paths` JSON; każdy ma target.qcow2,
stick.qcow2, vars.fd i fixture.json. Usunięcie któregoś liścia nie usuwa jego
backingu. Łącznie 805024195B rozmiaru unikalnych plików (około767.73MiB).
To kandydaci, bez globalnego dowodu braku wszystkich przyszłych potomków.

| Dokładny katalog | Dlaczego kandydat |
|---|---|
| `G:\USOS-Kolekcja\_vm\r18c-nt351-cold-i8042-off` | Kontrola i8042 OFF/NTDETECT, osobne zakończenie; backing r18b zachowany |
| `G:\USOS-Kolekcja\_vm\r24b-nt31-image-entry` | STOP błędnego RegisterMac, rodzeństwo dobrego r24c; brak dzieci |
| `G:\USOS-Kolekcja\_vm\nt351-client-apply01` | HARNESS_FAIL/NUL, helper0, writer terminated+exclusive-open proof; apply02 używa świeżego parenta |
| `G:\USOS-Kolekcja\_vm\nt35-client-apply01` | Root apply01/EOF, zamknięty; niezależne rodzeństwo apply03 |
| `G:\USOS-Kolekcja\_vm\nt35-client-apply02` | Root apply02/STOP przed helperem, zamknięty; nie parent cold01 |
| `G:\USOS-Kolekcja\_vm\nt35-client-baseline01` | Root baseline01 kontrolny liść, nie parent apply03/cold01 |

`G:\USOS-Kolekcja\_vm\r20-stopped-analysis` jest pusty: najwyżej sam pusty
katalog, bez zakładania nowych plików. Niczego nie usunięto w tej analizie.

## Zachować reprezentatywne wyniki i całe ich backing ancestry

Przodek nie jest disposable, dopóki pozostaje choć jeden potomek. Strzałka
poniżej prowadzi od dziecka do rodzica, a nie oznacza kolejności usuwania.

- NT351 target: `r18f-nt351-usb-port-isolation` → `r18e-nt351-stubfix-e9`
  → `r18d-nt351-debug-e9` → `r18c-nt351-cold-i8042-on`
  → `r18b-nt351-preserved` (standalone). Zewnętrzny R26 ma base=R18f;
  całą tę linię trzeba zachować. R18c OFF jest osobnym rodzeństwem ON.
- NT35 target/stick: `r20b-nt35-usb-isolation` → `r20-nt35-preserved`
  (standalone). Zewnętrzne `nt35-irq-fixed01` → R20b, potem `nt35-irq-usb01`
  → fixed01. Root client apply01/02/baseline01/apply03 są rodzeństwem opartym
  na usb01; `nt35-client-cold01` → `nt35-client-apply03` → usb01.
  Zachować cold01/apply03 oraz cały zewnętrzny USB/IRQ/R20 ancestry.
- NT31 target/stick: `r24f-nt31-client-coldboot` → `r24e-nt31-client-policy`
  → `r24d-nt31-usb-fullmac` → `r24c-nt31-registermac-order`
  → `r24-nt31-intel-fullmac` → root `r19c-nt31-usb-isolation`.
  Zachować finalny R24f i całą linię. R24b jest osobnym rodzeństwem R24c.
- NT351 client target/stick: `nt351-client-cold01` → `nt351-client-apply02`
  → zewnętrzny `nt351-irq-fresh01` target-retained/stick-retained.
  Zachować cold01/apply02 i świeży parent. apply01 nie jest ich przodkiem.
- `nt35-irq-fresh01` target/stick są standalone: zachować aktualny dobry
  świeży d94 baseline. `stick-final-retained.qcow2` i `stick-retained.qcow2`
  to ten sam file ID. Samo odlinkowanie jednej nazwy daje0B oszczędności;
  nie jest zalecane jako cel sprzątania. Zachować target/vars i co najmniej
  kanoniczną nazwę sticka potrzebną metadanym oraz przyszłym testom.

R18-family powyżej ma COW tylko dla target; małe sticki są standalone.
R20b, R24 i client-family mają osobne target oraz stick backing chains.
vars.fd to niezależne kopie, nie COW parents. Pełne ścieżki wszystkich46
obrazów są w JSON, łącznie z zewnętrznymi protected backing references.

`r18b-nt351-network-hid` i `r20-nt35-network-hid` nie zawierają już obrazów;
pozostają11 plików transportu/metadanych w każdym. G-only serial/result/
command/fixture zachować lub osobno utrwalić do własnych artefaktów przed
usuwaniem tych katalogów; ten plan ich nie zalicza do pierwszej partii.
Podobnie nie usuwać transportu collectorów we fresh d94 podczas zachowania
samego targetu. Nie kopiować surowych MS modules/hives poza RAM/whole G.

## Warunki ewentualnego wykonania później

Zachować komplet C: sources/scripts/commits, build pins, preparation,
result/completed, readbacks, PNG oraz własne logi. Zachować historyczne
FAIL i ich dowody, bez przepisywania ich na PASS. Nie usuwać C artifacts.
Przed wykonaniem sprawdzić ponownie dokładne absolutne ścieżki/file IDs,
closure i nowe zależności. Gdy przybył potomek albo stan się zmienił,
zatrzymać odpowiednią pozycję. Bez obchodzenia locków i bez interpretowania
starego pid.txt jako informacji o żywym procesie. Ten plan niczego nie
komituje/rebase/flatten w obrazach i nie zawiera komend usuwania.

Wykluczone: wszystkie parent/shared NT35 USB/IRQ/fresh, root R19/R19c,
R15/R17 bez nowego zamkniętego audytu, cała kolekcja _assets/_audit/_inputs,
wszystkie NT4/95 oraz wszystkie macOS. **macOS02–04 pozostają wykluczone
z uwagi na wcześniejsze odrzucenie automatycznej kontroli**; ten plan nie
próbuje tego obejść ani ponowić. Root raporty/macierze nie były edytowane.
