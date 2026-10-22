# NT5: start przygotowanego dysku w teście QEMU

Próba `r11-w2k-sp4-cma6-usability` przygotowała i odczytała ponownie 5600 plików na celu NTFS 32 GiB. Zapisany końcowy log pokazuje jednak oczekiwanie na stronie `REMOVE USOS USB, THEN PRESS ENTER TO POWER OFF.` przez pozostałą część limitu 5400 s. Adapter obsługiwał poprzedni komunikat informacyjny, ale nie tę stronę. Windows nie został uruchomiony; nie jest to wynik sterownika ACPI, USB ani sieci.

Adapter reaguje teraz na dokładny komunikat produktu dopiero po `PREPARED SYNC PASS`. Odpina wyłącznie własne wirtualne urządzenie instalacyjne, opcjonalnie podłącza własny testowy FAT16 i naciska Enter. QEMU uruchomione z `-no-shutdown` pozostaje zatrzymane po wyłączeniu gościa. Adapter czeka na rzeczywiste zdarzenie QMP `SHUTDOWN` z `guest=true`, następnie wykonuje `system_reset` i `cont`, rozpoczynając start celu przez jego OVMF/CSMWrap. Nie odpytuje statusu ani ekranu. Błąd, brak bezpiecznego odmontowania lub inna przyczyna wyłączenia zatrzymują tę sekwencję.

Przygotowanie plików i rozpoczęcie startu nie uprawniają do zapisywania obrazu ekranu prywatnego instalatora. Nadal wymagane jest dokładne powiadomienie pierwszego logowania przed przechwytywaniem i ręcznymi testami NT5. Nowy wynik `nt5_target_started` jest osobny od `first_logon_observed` i PASS.

Weryfikacja hostowa: testy kolejności odłączenie → powiadomienie → wyłączenie → reset/start, wariantu bez pendrive'a testowego, odrzucenia wyłączenia pochodzącego z hosta, zdarzenia przychodzącego przed odpowiedzią na polecenie oraz istniejące ograniczenia prywatnych ekranów. To nie jest jeszcze dowód uruchomienia Windows ani działania USB/LAN. Wcześniej uruchomione procesy adaptera zachowują poprzedni kod; nowe próby korzystają z poprawki.
