# Graficzny wybór dysku i trybu instalacji XP

Zgłoszenie: ekran dysku wymagał numeru, strzałki trafiały do konsoli jako sekwencje `^[[A` i zasłaniały grafikę. Poprzednia zmiana usunęła wpisywanie frazy tylko w potwierdzeniu, pozostawiając niespójny wybór dysku i trybu.

Nowy przebieg korzysta z `usos-fb-ui --menu` i wspólnego `menu_canvas` używanego przez wcześniejsze ekrany USOS. Lista dysków, zachowanie/formatowanie i potwierdzenie mają zaznaczenie oraz obsługę strzałek, TAB, ENTER i myszy. ESC wraca do wyboru dysku. Powrót z pierwszej listy restartuje do głównego USOS; podpis informuje o restarcie. Anulowanie nie uruchamia awaryjnej powłoki. Szczegóły dysku można przewijać PgUp/PgDn lub kółkiem, gdy nie mieszczą się na ekranie.

`fb_menu_model.zig` parsuje stan i kontroluje wybór, `fb_menu_render.zig` odpowiada za wygląd i trafianie w wiersze, `fb_menu_input.zig` odczytuje evdev, `fb_menu.zig` łączy je z framebufferem i konsolą. Wejście obejmuje względną mysz PS/2/USB i współrzędne absolutne tabletów; sprawdzono mysz PS/2. Powtórzenia przytrzymanego ENTER nie zatwierdzają następnego ekranu. Wykrywanie nowych urządzeń wejścia działa również podczas oczekiwania. Echo VT jest wyłączone, a ekran graficzny przejmuje VT.

`xp_menu_ui.sh` łączy stan menu ze stagingiem. Pełne formatowanie pozostaje za oddzielnym potwierdzeniem z domyślnym Anuluj i widocznym ostrzeżeniem o wszystkich danych. Wewnętrzne kontrole tożsamości dysku pozostają w backendzie. Każda ponowna próba formatowania otrzymuje nowy snapshot w RAM. ISO jest montowane tylko raz, więc powrót i ponowny wybór nie powodują konfliktu montowania. Kopiowanie źródła XP zaczyna się po zatwierdzeniu; wcześniejszy start środowiska opisano jako przygotowanie wyboru.

Weryfikacja na obrazach QEMU:

- `xp-gui-console-cancel`: klawiatura i anulowanie w wariancie bez framebuffera, MBR i dane kontrolne zachowane.
- `xp-gui-cancel2`: wybór strzałkami i anulowanie, framebuffer wykryty, dane zachowane.
- `xp-gui-mouse`: kliknięcia dysku/trybu/anulowania, ESC z trybu i ponowny wybór dysku, dane zachowane.
- `xp-gui-display`: faktyczne zrzuty ekranu po uruchomieniu konsoli graficznej, wybór myszą i anulowanie PASS. Wstępny test UEFI miał tylko konsolę szeregową, więc odkładana aktywacja fbcon pozostawiała na monitorze obraz firmware mimo działającego wejścia; test graficzny włącza tty0 i fbcon. Menu również aktywuje VT przed przejściem do grafiki.
- `xp-gui-format`: strzałki, jedno potwierdzenie, reset układu, pełne przygotowanie XPSETUP + Windows NTFS PASS. Nie powtarzano GUI/OOBE XP; kod kopiowania i rozruchu XP nie jest zmieniony w tej aktualizacji.

Zrzuty w `zig-out/xp-gui-display`: `disk-menu.png`, `disk-mode.png`, `confirmation.png`. Testy modułów obejmują bezpieczny domyślny wybór, granice przewijania, trafianie myszą, przytrzymany ENTER, skalowanie osi oraz układ potwierdzenia przy 640×480.

Końcowa kontrola: `zig-out/xp-gui-final` — klikanie, powrót ESC, ponowny wybór i anulowanie PASS, aktualne zrzuty PNG w tym katalogu. `zig-out/xp-gui-preserve` — nowy interfejs potwierdzenia i pełny staging z zachowaniem wcześniejszej partycji oraz danych kontrolnych PASS. Pełny build, Go, unit/startup, QEMU UEFI x86_64/ARM64 i 13 przypadków planera PASS.

Wydanie: `B260909-173239-D5666B9F`. Initramfs SHA-256: `449B77F3731D8692BA7469EA50A093AB371953A54D4B4DB7D496B9BDA92CD023`. Log aktualizacji Kingstona: `zig-out/xp-gui-kingston-update.log`. Fizycznego Intela nie formatowano.
