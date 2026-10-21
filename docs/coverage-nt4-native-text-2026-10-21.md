# Diagnoza natywnego instalatora NT4

Zakończone `r7-nt4-keyless-setup-diagnostic` nie dotarło do Windows: profil bez klucza zatrzymał się po 11 s na formularzu klucza w USOS, po czym adapter czekał do limitu 10800 s. Cel pozostał pusty. To błąd przygotowania diagnozy, nie wynik NT4 ani sterownika. Stare R6 z kluczem dotarło dalej, do drugiego startu wewnętrznego instalatora; jego przyczyna nadal wymaga dowodu.

Nowy adapter przerywa automatyczną próbę od razu na nieobsłużonym formularzu USOS. W kolejnej diagnozie należy użyć dostarczonego pliku klucza. Opcja `collect_nt4_text` czyta po zatrzymaniu emulatora wyłącznie `WINNT/SETUPLOG.TXT`, `WINNT/SETUPERR.LOG`, `WINNT/SETUPACT.LOG` i `USOS/NT4/POST.LOG` z FAT16 własnego celu. Nie zapisuje natywnych zrzutów ekranu prywatnego Setupu. Nie zmienia plików instalatora ani klucza.

Przed transmisją do hosta tekst przechodzi w gościu projekcję ASCII, usunięcie wzorców kluczy oraz wszystkich serii co najmniej trzech cyfr. Host ponownie sprawdza ograniczenie, nazwy i rozmiary. Skutek uboczny jest jawny: tracimy polskie znaki i numeryczne kody błędów; pozostają nazwy składników, operacji i komunikaty. Nie jest to wierna kopia oryginalnego dziennika. Brak plików również zapisuje się jako taki, bez PASS.

Testy hostowe: szybkie zakończenie formularza, rzeczywisty filtr powłoki na syntetycznych kluczach, odmowa surowego tekstu/obrazu/odpowiedzi/traversal. Cały zestaw coverage: 57 PASS. Nowy kolektor wymaga jeszcze wykonania w VM; brak zaliczenia sieci lub USB.
# Completed R16 transport recovery

R16 completed before any recovery attempt. The unchanged sanitized serial
contained a complete 238-byte archive, but the strict base64 reader saw a
BusyBox cursor-query/command echo and a truncated END echo as payload.
The revised decoder accepts exactly one complete frame and only those
two observed echo forms, with canonical base64 validation. It rejects
unknown prompts, MOTD text, duplicate frames and a second encoded archive
after padding. It never decodes permissively or truncates on padding.

The recovered R16 archive SHA256 is
`fd5490dc185d03b14fdacdb78480ed4be72149277e1e8bc8f4325e76169c1119`.
It reports `setuplog.txt=empty` and the other three logs unavailable;
`actual_native_logs` is empty. Thus transport recovery does not establish
the native Setup page or the cause of its stop. Original sanitized serial
and raw result remain unchanged. All 75 coverage host tests pass after
integration, including three new transport regressions.
