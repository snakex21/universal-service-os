# NT3/NT4: ponowne podłączenie klawiatury i myszy USB

Baza `f28a3fd8155b82dd1be22608f6ef17e82437ad1d`, gałąź `fix/nt3-usb`.
Nie zmieniono `tools/nt4/usosusb`; sterownik i jego obsługa hubów są czytane z bazy.

Nowy `tools/tests/usosusb_hub/run_hid_events.py` kompiluje rzeczywisty sterownik w istniejącym jądrze testowym osobno dla `nt31` i `nt4`. Zamiast odpytywania pliku/procesu oczekuje biernie na linie COM1 i odpowiedzi/zdarzenia QMP. Wirtualny i8042 jest wyłączony, żeby wejście PS/2 nie zastępowało USB. Testuje wpisanie i zwolnienie klawisza, ruch myszy i obie krawędzie przycisku, dwa odpięcia/podpięcia na portach głównych oraz podpięcie przez hub. Stary rekord sprzed działania nie spełnia nowego oczekiwania.

To regresja sterownika w QEMU z atrapami funkcji jądra i callbackami klas. Nie zastępuje świeżej instalacji Windows, logowania na pulpicie, testu pendrive'a ani sieci. Osobna kolejka instalacji NT3 i diagnoza NT4 pozostają wymagane. Każdy wynik zapisuje hash źródła i dokładny zakres dowodu. Brak PASS przed wykonaniem.

Trzy testy hostowe sprawdzają powiadomienia COM1, granicę starego/nowego rekordu, zamknięcie kanału oraz wymaganie ruchu i obu zdarzeń przycisku. Nie uruchamiają Windows ani QEMU.
