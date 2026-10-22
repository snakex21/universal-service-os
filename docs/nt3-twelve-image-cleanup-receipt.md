# Wykonane sprzątanie 12 zamkniętych obrazów NT3

Po odrębnej autoryzacji użytkownika przekazanej przez root wykonano jedną
operację 2026-10-22, 16:58:59–16:59:02 UTC. Usunięto dokładnie pliki
`target.qcow2` i `stick.qcow2` w sześciu literalnych katalogach poniżej.
Łączny rozmiar usuniętych plików: **801771008 B**. Faktycznie odzyskanej
przestrzeni alokowanej NTFS nie mierzono.

| Zachowany katalog | Usunięty target.qcow2 (B) | Usunięty stick.qcow2 (B) |
|---|---:|---:|
| `G:\USOS-Kolekcja\_vm\r18c-nt351-cold-i8042-off` | 197120 | 197120 |
| `G:\USOS-Kolekcja\_vm\r24b-nt31-image-entry` | 112525312 | 197120 |
| `G:\USOS-Kolekcja\_vm\nt351-client-apply01` | 203358208 | 197120 |
| `G:\USOS-Kolekcja\_vm\nt35-client-apply01` | 240648192 | 197120 |
| `G:\USOS-Kolekcja\_vm\nt35-client-apply02` | 240648192 | 197120 |
| `G:\USOS-Kolekcja\_vm\nt35-client-baseline01` | 3211264 | 197120 |

Kompletny [receipt JSON](nt3-twelve-image-cleanup-receipt.json) podaje
każdą usuniętą absolutną ścieżkę, dokładny dwuczęściowy file ID zapisany
jako dziesiętne stringi, rozmiar, liczbę hardlinków, czas i metodę oraz
pełne 24 ścieżki zachowanych rodziców z ich identyfikatorami i rozmiarami.
SHA256 receipt: `29b1acdec2c9a8a76a18adde2a71a414b7784dd36d62e9a9cfd0f82910bd942f`.
Oryginał i dziennik zdarzeń pozostają w
`artifacts/nt3-cleanup-execution/receipt.json` i `events.jsonl`.

Przed pierwszym usunięciem ponownie sprawdzono absolutne ścieżki i brak
reparse, file IDs/rozmiary/link count, 57 przypiętych kontroli closure
w 26 znanych zamkniętych przypadkach oraz 46 zgodnych nagłówków/backing
w tym zamkniętym grafie. Przejrzano 24 statyczne preparation JSON pod
`nt3*` worktree artifacts: brak nowego odwołania do kandydatów. Nie jest
to twierdzenie o wszystkich ukrytych obrazach na wszystkich dyskach.

Dokładnie jeden safety snapshot commandline QEMU wykazał brak procesu
QEMU i brak użycia kandydatów. Nie zapisywano commandline. Wszystkie 12
plików uzyskało uchwyty wyłączne przed pierwszym usunięciem; identyfikatory
ponownie porównano przez te uchwyty. Usunięcie użyło wyłącznie
`FileDispositionInfo` na przypiętym uchwycie i `CloseHandle`, bez rekursji,
force, obchodzenia locków ani ponowień. Każda ścieżka była nieobecna po
zamknięciu jej uchwytu. Brak odmów i częściowych błędów.

Metadane 136 pozostałych plików zgadzają się przed/po operacji. Zachowano
katalogi, wszystkie vars/fixture/logs/artefakty i pełne linie parentów:
R18 ON→d→e→f/R26, R20→USB/IRQ i świeży NT35 d94, R19c→R24→c→d→e→f,
NT35 apply03→cold01 oraz NT351 fresh→apply02→cold01. Nie otwierano bajtów
zewnętrznych parentów; sprawdzenie ich zachowania obejmowało metadane.
Wszystkie NT4, macOS (także wykluczone02–04), shared assets i media
pozostały poza zakresem. Nie czytano aktywnego tuple09 ani combo01.

Odtwarzalny [helper](../tools/tests/cleanup_nt3_twelve_closed_images.py)
ma literalny allowlist i przypięty SHA planu. Istniejący receipt blokuje
powtórne wykonanie. Jego cztery testy sprawdzają pin/zakres12, zgodność
file ID Win32 z Pythonem, odmowę drugiego uchwytu oraz odmowę błędnego ID
i zwolnienie uchwytu. Testy używają tylko własnego pliku źródłowego na C,
bez usuwania, odczytu obrazów czy zapytania o procesy.

Historyczny plan4c309e57 pozostał niezmieniony: jego `nothing_deleted`
i `deletion_authorized:false` opisują wcześniejszy etap planowania.
Wykonanie i nowa autoryzacja są odrębnie zapisane w tym receipt. Nie
zmieniano wyników runtime, root raportów, macierzy ani źródeł sterowników.
