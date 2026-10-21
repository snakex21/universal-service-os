# NT 3.x, NT4 i macOS: zakres testów

Prace rozdzielono na trzy osobne worktree: `fix/nt3-usb`, `fix/nt4-net`
i `fix/macos-usb`. Koordynator zachowuje globalny limit trzech silników
QEMU. Normalna instalacja NT w USOS zajmuje dwa z tych miejsc, ponieważ
uruchamia również wewnętrzny QEMU. Test macOS zajmuje pozostałe miejsce.
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
wystarczy zatem do oznaczenia USB PASS. Osobny zimny start z
`q35,i8042=off` i dowód odbioru wejścia są nadal potrzebne.

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
