# NT 3.x, NT4 i macOS: zakres testów

Aktualizacja22października: użytkownik zniósł sztywny limit trzech
silników QEMU. Koordynator dobiera równoległość do dostępnych zasobów;
przed uruchomieniem obowiązuje kontrola pamięci z rezerwą8GiB oraz
wolnego miejsca. Normalna instalacja NT w USOS uruchamia także wewnętrzny
QEMU, więc jej koszty trzeba uwzględnić obok zewnętrznej VM. Rozróżnienie
jedno-/dwusilnikowej ścieżki w run_plan nie ustanawia globalnego limitu.
Prace NT3, NT4 i macOS pozostają w oddzielnych worktree i gałęziach.
Oczekiwanie na wynik jest pasywne, bez odczytywania postępu.

Zakończone testy sterownika NT31 1.2 i NT4 1.3 w pomocniczym środowisku
QEMU mają po 22 udane przypadki. Przy `i8042=off`, po odłączeniu urządzeń
za hubem, potwierdzono naciśnięcie i zwolnienie klawisza oraz ruch,
wciśnięcie i zwolnienie przycisku myszy po dwóch ponownych podłączeniach
do portów głównych. To rzeczywisty sterownik z pomocniczym kernelem
i sterownikami klas, a nie wynik zainstalowanego Windows. Końcowe próby
wejścia za hubem pozostawiały konkurencyjne urządzenia główne, więc
dowodzą enumeracji i odbioru USB, bez przypisania callbacku do portu.
Gałąź NT3 zawiera już izolację tej fazy do przyszłej powtórki.

Normalne próby instalacji pozostawiają domyślne PS/2 w QEMU. Reakcja
pulpitu na polecenie `sendkey` po ponownym podłączeniu urządzenia nie
wystarczy zatem do oznaczenia USB PASS. Zakończone R19c NT31 i R18f
NT351 izolują USB w osobnym zimnym starcie: sprzętowy i8042 pozostaje
obecny dla NTDETECT, a systemowa usługa i8042prt ma Start4. Samo sprzętowe
i8042=off zatrzymywało NT351 na NTDETECT. Odbiór klawiszy, ruchu i klików
po replug oraz odpowiedź klawiatury przy nieobecnej myszy potwierdzono
na rzeczywistych pulpitach i przez końcowy odczyt konfiguracji.
Nie jest to jeszcze kwalifikacja świeżego instalatora z tą izolacją.
Szczegóły: `docs/coverage-regf11-readback.md` oraz aktualny raport
`C:\Users\ASRock\Documents\Codex\zadania\2026-10-22-nt3-nt4-macos-RAPORT.md`.

Próba `r7-nt4-keyless-setup-diagnostic` nie uruchomiła instalatora NT4:
czekała na klucz w formularzu USOS. Próba `r11-xp-sp3-en-usability`
działała na poprzednim adapterze przejścia do docelowego dysku i nie
potwierdziła startu Windows. Obie mają klasyfikację `RUNNER_ERROR`.
Ich surowe wyniki zachowano, a normalizację zapisano w lokalnej macierzy.
Żadna nie jest wynikiem działania sterownika lub dowodem awarii Windows.

Źródła lokalne: `artifacts/coverage/priority-nt34-macos/single-engine-complete.json`,
`nt3-usb-tests/artifacts/hid-events/priority-nt31/result.json`,
`nt3-usb-tests/artifacts/hid-events/priority-nt4/result.json`
oraz wyniki obu wymienionych prób w `artifacts/coverage/vm`.
Obrazy pomocniczego kernela usunięto po teście. Brak zapisów na fizyczne
pendrive'y lub dyski. Zmiany pozostają do przeglądu, bez scalania.
