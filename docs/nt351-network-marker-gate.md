# NT351: brak markera kończy konfigurację

read_text zwraca-1, gdy NET351.ON nie istnieje, oraz0 dla pustego pliku lub błędu odczytu. Stare !read_text odrzucało tylko0. Warunek <=0 teraz kończy nt351_network przed GetVersion i jakąkolwiek konfiguracją, jeśli brak dodatniej długości markera.

Regresja kompiluje rzeczywiste read_text i początek nt351_network do granicy GetProcAddress. Mocki Win32 działają wyłącznie w RAM: missing, empty, valid i read-error. Tylko valid dochodzi do rozpoznania wersji. Ten sam program ze starym guardem kończy się błędem30 już dla missing. Test nie zawiera ścieżki konfiguracji rejestru i nie wykonuje helpera Windows na hoście.

Pełny build WDK do własnego artifacts/nt351-network/marker-gate-post-01 przeszedł, PE3.10,22016B, SHA256d2c1115180d8daeb02421d23920584a95dd8aa082a42c566dec1e9ff836e1096.50importów identycznych z dotychczasowym helperem. To kandydat nieuruchomiony wWindows; śledzona binarka i cache pozostały niezmienione. R18f PASS dotyczy wcześniejszego faktycznego gościa, nie tego builda. Aktywny NT35 R20 i jego cache nie zostały zmienione.
