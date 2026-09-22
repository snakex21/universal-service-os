# Windows 7: próba usunięcia nieskończonych pętli INT10

## Wynik próby fizycznej i dalsza diagnostyka

Użytkownik zgłosił kolejny zastój na ekranie uruchamiania Windows.
Poprawka INT10 NIE rozwiązała obserwowanego problemu.
Zebrano `intel-failure-20260920-185304`; potwierdzono oba hashe poprawionego
EFI i świeże logi wrappera/UefiSeven z 2026-09-20 16:53:02 UTC. Log przechodzi
przez instalację INT10 do oryginalnego bootmanagera Windows.
Nie znaleziono `Windows/ntbtlog.txt`, `Windows/MEMORY.DMP` ani katalogu
`Windows/Minidump`. Brak tych plików nie identyfikuje wadliwego sterownika
ani nie dowodzi, że jądro w ogóle nie wystartowało.

Włączono wyłącznie dodatkową opcję BCD `sos Yes` we wpisie tego Win7,
aby pokazać nazwy ładowanych sterowników. Dotychczasowe `bootlog Yes`
i `nocrashautoreboot Yes` zachowano. Nie zmieniano kolejnych loaderów,
sterowników ani partycji. Wdrożenie i odczyt zwrotny: exit 0.
Kopia BCD: `zig-out/win7-universal-work/intel-before-sos-20260920-185500/`.
Skrypt: `tools/enable_windows7_boot_diagnostics.ps1`.
Ostatnia nazwa pokazana przez SOS nie musi oznaczać sprawcy zawieszenia.

Źródło opcji diagnostycznych:
https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/bcdedit--set

## Co wiadomo

Użytkownik zgłosił, że CSMWrap dochodzi do SeaBIOS i `Booting drive`, dalej
bez obrazu. Nie ustalono, który dysk SeaBIOS próbował uruchomić. Intel nadal
ma GPT/EFI, więc ten wynik nie dowodzi błędu samego SeaBIOS. Przywrócono
oryginalny `BOOTX64.EFI` USOS na Kingstona, SHA256
`3008d265b13343fc694bd6fff3985b1d67884a79c684472be39a767f8f2a5b5d`.
Pliki eksperymentu CSMWrap pozostają nieaktywne.

Zrzut Intela `zig-out/win7-universal-work/intel-failure-20260920-184130`
pokazuje, że wcześniejsza poprawka AMD odblokowała C0000, a UefiSeven
zainstalował INT10 i przeszedł swój test handlera. Brak blokady C0000
nie wystarczył do uruchomienia Windows. Ostatni wpis wrappera z włączonym
CSM potwierdza użycie oryginalnego bootmanagera z firmware INT10.

UefiSeven 1.30 i przejrzany VgaShim v0.98.1 mają w handlerze `Hang: jmp Hang`:
nieznana funkcja, nieznany tryb VBE lub nieobsługiwany tryb Legacy powodują
nieskończoną pętlę. UefiSeven odrzuca też BX=C0F1, choć bit 15 VBE SetMode
oznacza zachowanie zawartości bufora obrazu. To konkretne wady kodu,
ale NIE ma jeszcze dowodu, że powodują zwis na badanym X470/RX 560.

## Zmiana i zakres

`tools/windows7_int10.S` implementuje ten sam układ dwóch tabel VBE (512 B)
i wejście C0200. Obsługiwane wcześniej funkcje zachowują swoje wyniki.
Nieobsługiwane żądania zwracają AX=014F zamiast zapętlenia; SetMode
przyjmuje 40F1 i C0F1. Jest to eksperymentalna modyfikacja USOS.

`tools/build_windows7_int10_patch.py` kompiluje asembler narzędziami Zig,
sprawdza hash oryginalnego UefiSeven i jego tablicy INT10, wymaga jednego
dokładnego wystąpienia tej tablicy w pliku EFI. Podmienia wyłącznie ten
obszar (nowy handler 615 B mieści się w oryginalnych 655 B, reszta to NOP).
Pozostałe bajty i długość pliku EFI pozostają identyczne. Oryginał dostawcy
jest zachowany. Własna poprawka nie zmienia numeru bazowej wersji w logu
UefiSeven: identyfikację modyfikacji zapewnia SHA256 i manifest.

Źródło oryginalnej tablicy przypięto do commitu
`b8f0baba63e60e74d4ed3e86b15b76319d316b83`; nagłówek i manifest znajdują się
w `tools/vendor/uefiseven/1.30/` wraz z istniejącą licencją BSD.

Na Intelu zmieniono tylko `win7.efi` w obu katalogach EFI oraz dwie opcje
we wpisie BCD Windows 7: `bootlog Yes`, `nocrashautoreboot Yes`.
SHA256 poprawionego EFI:
`7c545b00d705ffdfde21f051dd96b8036be00e063e27e74479845170c62b2fa4`.
Wrapper AMD, oryginalne bootloadery Microsoftu, partycje i pliki Windows
pozostają niezmienione. To próba dla już zainstalowanego systemu;
standardowy payload instalatora nadal zawiera wersję bez tej poprawki.

## Weryfikacja

- Kompilacja przez Zig: exit 0.
- Cztery testy regresji kodu INT10: exit 0, 0,013 s. Sprawdzają powrót
  z przerwania, SP, zachowanie rejestrów/FLAGS, kopie obu tabel,
  prawidłowe tryby i odtworzenie zapętlenia na oryginalnym kodzie.
  To ograniczone testy instrukcji w Unicorn, bez startu VM, firmware ani OS.
- Wdrożenie: exit 0, zgodne hashe obu kopii EFI i BCD po zapisie;
  zgodny układ partycji i hashe nienaruszanych bootloaderów.
- NIE wykonano testu fizycznego nowej poprawki ani VM/E2E.

Backup:
`zig-out/win7-universal-work/intel-before-int10-return-20260920-184730/`.
Zawiera dwa oryginalne `win7.efi`, oryginalne BCD, zmienione BCD,
odczyt opcji oraz manifest poprawki. Cofnięcie polega na odtworzeniu tych
trzech plików na rozpoznanej ESP Intela; nie wolno kierować go na ESP hosta.

## Próba użytkownika

Intel podłączony jak wcześniej do komputera testowego, CSM Disabled,
Secure Boot Disabled. Wybrać Windows Boot Manager Intela; pendrive nie
jest potrzebny. Bez reinstalacji. Jeśli start nadal stanie, zdjęcie ekranu
i ponowne podłączenie Intela pozwolą sprawdzić logi EFI oraz ewentualny
`Windows/ntbtlog.txt` (powstanie tylko, jeśli Windows dojdzie do zapisu logu).
Problem braku klawiatury USB przy sprawdzaniu dysku pozostaje oddzielny.

## Źródła

- https://github.com/manatails/uefiseven/blob/1.30/UefiSevenPkg/Platform/UefiSeven/Int10hHandler.asm
- https://github.com/driver1998/VgaShim/blob/v0.98.1/MdeModulePkg/Application/VgaShim/Int10hHandler.asm
