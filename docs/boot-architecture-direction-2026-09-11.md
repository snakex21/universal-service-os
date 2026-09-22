# Prostsza architektura pendrive'a USOS

## Cel

Użytkownik wybiera system i obraz, a USOS uruchamia właściwy instalator możliwie
krótką drogą. Priorytety: zgodność, prostota obsługi i szybkość. Obecność systemu
w katalogu nie oznacza, że jego instalacja została sprawdzona.

Warto przebudować warstwę uruchamiania. Zachować można katalog obrazów,
interfejs i zabezpieczenia instalatora pendrive'a. Przepisywanie całego projektu
naraz utrudniłoby porównanie działania ze znanymi wynikami.

## Podział odpowiedzialności

1. **Instalator nośnika** przygotowuje i aktualizuje pendrive. Rozpoznaje go po
   tożsamości, zachowuje obrazy użytkownika i weryfikuje zapis.
2. **Menu** pokazuje dostępne obrazy i dobiera jeden domyślny sposób startu.
   Nazwy typu kexec/WIMBOOT/chainload należą do opcji zaawansowanych.
3. **Moduł startowy danej rodziny** otrzymuje jednoznacznie wskazany obraz i
   opcjonalny plik odpowiedzi. Uruchamia sprawdzony loader bez przechodzenia
   przez niepotrzebny system pośredni.
4. **Oryginalny instalator systemu** obsługuje docelowy dysk i instalację.
   Sam wybór obrazu w menu nie formatuje dysku docelowego.

Cała trwała konfiguracja, obrazy i narzędzia pozostają na nośniku. Dodatkowe
pliki uruchomionego Windows PE są obok helpera w jego dysku RAM. Źródłowe ISO
i partycja DATA są udostępniane Windows PE tylko do odczytu.

## Rodziny zamiast wyjątków dla każdego wydania

| Rodzina | Kierunek | Osobne ograniczenia |
| --- | --- | --- |
| Windows Vista i nowsze | oryginalny Windows PE z wybranego ISO, następnie źródło ISO dostępne w PE | BIOS/UEFI, architektura, sterowniki i wymagania konkretnego wydania |
| Windows NT/2000/XP | wydzielony moduł instalacji wieloetapowej, oparty na sprawdzonych rozwiązaniach dla tej generacji | BIOS, sterowniki dysku, kolejność etapów i kontynuacja instalacji |
| DOS i Windows 9x | start właściwego obrazu dyskietki/dysku lub oryginalnego loadera | BIOS, geometria, FAT i ograniczenia danego instalatora |
| Linux i narzędzia | natywny loader obrazu lub sprawdzony silnik multiboot | sposób odnalezienia ISO przez uruchomiony system |

Nie ma jednego mechanizmu, który zmieni system wymagający BIOS-u w system UEFI
albo doda brakujące instrukcje procesora. Zgodność trzeba opisywać dla pary
obraz + sprzęt/tryb startu. Restart wykonywany przez sam instalator jest czymś
innym niż zbędny restart między wyborem obrazu a uruchomieniem instalatora.

## Co wykorzystać z gotowych projektów

- **Ventoy** jest kandydatem do szerokiej obsługi współczesnych obrazów i
  Linuksa. Producent opisuje start ISO/WIM/IMG/VHD/EFI oraz kilka architektur
  BIOS/UEFI. Włączenie go do USOS wymaga najpierw sprawdzenia sposobu integracji,
  układu nośnika i docelowej listy starszych systemów; nie należy utożsamiać
  szerokiej listy obrazów z obsługą każdego Windows.
  [Dokumentacja Ventoy](https://www.ventoy.net/en/index.html).
- **Easy2Boot** jest dobrym punktem odniesienia dla starszych Windows. Jego
  dokumentacja rozdziela XP (DPMS, Legacy/MBR, etapy) oraz standardowe obrazy
  Vista+ uruchamiane przez wimboot. To wspiera podział na rodziny zamiast
  wymuszania jednej ścieżki dla wszystkich.
  [Instalacyjne ISO Windows w Easy2Boot](https://easy2boot.xyz/create-your-website-with-blocks/add-payload-files/windows-install-isos/).
- **GRUB** może przekazać sterowanie właściwemu loaderowi, ale samo otwarcie ISO
  w menu nie gwarantuje, że uruchomiony Windows zobaczy źródło instalacji.
  Dokumentacja opisuje też ograniczenie mapowania kolejności dysków do fazy,
  w której system używa usług BIOS-u.
  [GRUB: chain-loading](https://www.gnu.org/software/grub/manual/grub/html_node/Chain_002dloading.html),
  [GRUB: DOS/Windows](https://www.gnu.org/software/grub/manual/grub/html_node/DOS_002fWindows.html).
- **wimboot** już jest używany w projekcie. Potrafi wystartować Windows PE
  i wstrzyknąć pliki startowe do dysku RAM. Powinien otrzymywać sterowanie
  bezpośrednio z loadera działającego jeszcze w środowisku firmware.
  [iPXE: wimboot](https://ipxe.org/wimboot).

Wniosek projektowy: preferować istniejące, utrzymywane silniki tam, gdzie
rzeczywiście redukują kod USOS. Decyzję o zamianie całego loadera na GRUB/Ventoy
poprzedzić testem integracji na starej maszynie. Sama wymiana nazw programów
bez usunięcia zbędnych etapów nie rozwiązuje problemu.

## Pierwsza migracja: Vista BIOS

Dotychczas: menu → Linux → przygotowanie WORK i kopia płyty → próba powrotu
do BIOS-u przez kexec → wimboot → Windows PE → Setup.

Nowa ścieżka w implementacji: menu → odczyt plików startowych z ISO → wimboot
→ oryginalny Windows PE → podłączenie tego samego ISO tylko do odczytu → Setup.

Nie wymaga cache przypisanego do nazwy obrazu, rozpakowanego źródła na WORK
ani Linuksa. Pełny obraz instalacyjny pozostaje na DATA; do RAM są czytane
pliki potrzebne do uruchomienia PE. To ogranicza I/O przed startem instalatora.
Moduł ten jest na razie włączany dla Visty; inne systemy wymagają osobnej
walidacji przed zmianą ich ścieżek domyślnych.

## Kolejność dalszej pracy

1. Potwierdzić nową ścieżkę Visty w pełnej instalacji w VM i na MS-7100.
2. Porównać gotowy silnik multiboot na wirtualnym nośniku z tym samym zestawem
   ISO. Sprawdzić również pusty dysk, ponowny start instalatora, kilka ISO i
   zewnętrzny nośnik oznaczony jako removable.
3. Wybrać jeden domyślny backend dla każdej rodziny. Przenosić po jednej rodzinie,
   usuwając zastąpione ścieżki i diagnostyczne obejścia po potwierdzeniu wyników.
4. Uprościć zwykłe menu do wyboru obrazu i startu. Pliki odpowiedzi i ręczne
   metody pozostawić jako opcjonalne ustawienia.
5. Rozszerzać listę zgodności na podstawie pełnej instalacji i późniejszego
   startu systemu z dysku docelowego. VM oraz fizyczny sprzęt raportować osobno.

To jest kierunek przebudowy i kryteria odbioru, nie deklaracja ukończonej
obsługi wszystkich wymienionych rodzin.
