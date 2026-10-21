# NT3/NT4: ponowne podłączenie klawiatury i myszy USB

Baza `f28a3fd8155b82dd1be22608f6ef17e82437ad1d`, gałąź `fix/nt3-usb`.
Nie zmieniono `tools/nt4/usosusb`; sterownik i jego obsługa hubów są czytane z bazy.

Nowy `tools/tests/usosusb_hub/run_hid_events.py` kompiluje rzeczywisty sterownik w istniejącym jądrze testowym osobno dla `nt31` i `nt4`. Zamiast odpytywania pliku/procesu oczekuje biernie na linie COM1 i odpowiedzi/zdarzenia QMP. Wirtualny i8042 jest wyłączony, żeby wejście PS/2 nie zastępowało USB. Testuje wpisanie i zwolnienie klawisza, ruch myszy i obie krawędzie przycisku, dwa odpięcia/podpięcia na portach głównych oraz podpięcie przez hub. Stary rekord sprzed działania nie spełnia nowego oczekiwania.

To regresja sterownika w QEMU z atrapami funkcji jądra i callbackami klas. Nie zastępuje świeżej instalacji Windows, logowania na pulpicie, testu pendrive'a ani sieci. Osobna kolejka instalacji NT3 i diagnoza NT4 pozostają wymagane. Każdy wynik zapisuje hash źródła i dokładny zakres dowodu. Brak PASS przed wykonaniem.

Trzy testy hostowe sprawdzają powiadomienia COM1, granicę starego/nowego rekordu, zamknięcie kanału oraz wymaganie ruchu i obu zdarzeń przycisku. Nie uruchamiają Windows ani QEMU.

Wykonany scenariusz `artifacts/hid-events/priority-nt31` i `priority-nt4` zakończył po 22 przypadki PASS. Oba wyłączały i8042. Dwa cykle odpięcia/podpięcia głównej klawiatury i myszy odbyły się po odłączeniu HID huba, co wyklucza inną klawiaturę lub mysz w tych callbackach. Końcowa faza huba pozostawiała jednak HID główne: potwierdzała ponowną enumerację portu i działanie wejścia USB, ale nie przypisuje callbacków konkretnie do huba. Żaden z tych wyników nie jest PASS instalacji Windows, pamięci masowej ani sieci.

Runner został następnie zawężony: przed testem wejścia przez hub odłącza także obydwa HID główne, a wynik zapisuje hash harnessu i stan izolacji. Ta wersja ma 24 przypadki. Jej runtime pozostaje niewykonany; starych wyników 22 przypadków nie przenosi się na nową wersję ani na zwykły Windows. Początkowy test wejścia przy starcie nadal obejmuje USB bez rozróżnienia portu głównego i huba.

R15 NT3.51 Workstation zakończył się na stronie błędu USOS po braku zapisu przez 903 s na drugim starcie wewnętrznego Setup. `ASSESS_ENDPOINT` nie jest PASS. Ostatni natywny ekran i logi zapisują się na ESP pod `EFI/USOS/win9x/nt4/run-N`, lecz cleanup pierwszej próby usunął oba qcow2 bez eksportu. Nie można już zebrać tego ekranu przez tańszy read-only boot: wymagałby usuniętego stick.qcow2.

Wąska osłona kolekcji dopuszcza teraz dokładne foldery sześciu NT3 Workstation/Server z planu R15 oraz dotychczasowy `Windows NT 4.0`. Wymaga jawnego `private_profile is False` i własnego zamrożonego cache pod `_assets`. Nie dopuszcza kluczy, brakującej flagi, aliasów nazw ani innych systemów. Zmiana dotyczy warunku istniejącego kolektora po zatrzymaniu obu VM; nie uruchamia instalacji i nie rozszerza eksportu danych. Do tego worktree bez wcześniejszego modułu coverage skopiowano dwa pliki z `macierz-windows` jako bazę zmiany; integracja powinna użyć dostarczonego wąskiego diffu, bez podmiany pozostałych modułów aktywnej kolejki. Następna próba powinna obejmować jeden NT3.51 z eksportem diagnostycznym przed cleanup.
