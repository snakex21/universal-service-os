# Trwałe logi Windows Setup na źródłowym nośniku USOS

Po inicjalizacji WinPE pomocnik źródła znajduje dysk przez GUID partycji
z `usos-source.ini`, sprawdza obie kopie GPT oraz zakres partycji źródłowej.
Następnie wymaga jednej ESP na tym dysku i sprawdza jej rzeczywisty GUID,
typ, offset i rozmiar przez Windows IOCTL. Nie wybiera nośnika po literze,
numerze dysku ani samej etykiecie. Nie formatuje ani nie zmienia partycji.

Każdy start tworzy osobny katalog:

`EFI/USOS/Logs/WinSetup-<czas UTC>-<PID>`

Zawartość, jeżeli dane pliki istnieją w aktywnym WinPE:

- `usos-startup.log`: etapy, wersja PE, raport USB, ścieżki źródła i Setup,
  wynik pomocników i kod zakończenia skryptu/Setup;
- `build.txt`: identyfikator paczki;
- `source-identity.bin`, `source-mount.log`, `source-disk.txt`;
- `*-panther-setupact.log`, `*-panther-setuperr.log` z trzech lokalizacji PE;
- `setupapi.dev.log`, `dism.log`;
- `generated-answer.xml` wyłącznie, gdy nie dostarczono pliku odpowiedzi
  użytkownika. Własne pliki odpowiedzi mogą zawierać hasła/klucze i nie są
  automatycznie kopiowane przez ten mechanizm.

Osobny proces czeka blokująco na `ReadDirectoryChangesW` i zakończenie
launchera. Zmiany logów wywołują zapis na ESP również podczas wyświetlania
okna błędu. Nie ma timera odpytywania postępu. Każdy zapis kończy się
`FlushFileBuffers`; plik większy od 16 MiB zapisuje ostatnie 16 MiB z sufiksem
`.tail`. Dodatkowe kopie powstają przed i po Setup, przed restartem oraz po
zakończeniu skryptu. Mutex rozdziela równoczesne kopie.

Gdy Windows nie może odczytać źródłowego USB albo zapisać jego ESP,
log pozostaje w `X:\Windows\System32\usos-startup.log`; skrypt odnotowuje
brak trwałego zapisu. Mechanizm dotyczy działającego Windows PE — nie
przechwytuje awarii firmware, rozruchu przed WinPE ani logów starego systemu
na innych dyskach.

Zdjęcie użytkownika z 20 września pokazuje błąd odczytu `ProductKey` z pliku
odpowiedzi, zarówno z CSM, jak i bez CSM. Dodanie logowania nie jest
potwierdzeniem usunięcia tego błędu. Należy odtworzyć go, zamknąć okno błędu
przyciskiem OK (aby zapisał się także kod zakończenia), a następnie odczytać
nowy katalog sesji z pendrive'a.

Wdrożenie: `B260920-151010-95750AEB`. Kompilacja oraz 216 testów Zig,
52 testy pomocników i 3 testy kopiowania otwartego/pustego/dużego logu
zakończone powodzeniem; bez VM/E2E. Standardowy aktualizator odmówił
blokady woluminu na etapie Legacy. Zastosowano aktualizację dziesięciu
plików EFI i wsparcia WinPE, z kontrolą tożsamości nośnika, kopią poprzednich
plików, sprawdzeniem SHA-256 po zapisie oraz zachowania układu partycji.
Logi kompilacji i aktualizacji znajdują się w
`zig-out/win7-universal-work/build-usb-logging-final.log` oraz
`zig-out/win7-universal-work/update-logging-files.log`.
