# Jak działa USOS: stare systemy na nowym firmware

Wersja angielska: [HOW-IT-WORKS.md](HOW-IT-WORKS.md).

USOS (Universal Service OS) 1.0.0 instaluje i uruchamia systemy od MS-DOS
do Windows 11 oraz Linuksa z jednego pendrive'a, w Legacy BIOS i w UEFI,
także z włączonym Secure Boot. Najtrudniejsze nie jest samo menu, tylko
uruchomienie systemów z lat 2001-2009 na firmware, które nigdy nie było dla
nich projektowane. Ta strona wyjaśnia, dlaczego Windows XP, Vista i 7 mają
kłopot z nowoczesnymi komputerami UEFI i co USOS z tym robi.

Każde stwierdzenie pochodzi z notatek projektowych i raportów z testów,
do których prowadzą linki w poszczególnych sekcjach. Jeśli jakiś szczegół
nie jest tam opisany, ta strona o tym mówi. „X470” oznacza główny komputer
testowy: płytę ASRock X470 z Ryzenem 7 5700X, Radeonem RX 560 i firmware AMI
Aptio ([informacje o wydaniu](release-notes-1.0.md#hardware-tested-configurations)).

Spis treści:

1. [BIOS, UEFI i CSM](#1-bios-uefi-i-csm)
2. [Int 10h, BIOS karty graficznej i dlaczego Windows 7 i Vista potrzebują starego VGA](#2-int-10h-bios-karty-graficznej-i-dlaczego-windows-7-i-vista-potrzebują-starego-vga)
3. [UefiSeven i dyspozytor Int10 USOS (Windows 7 bez CSM)](#3-uefiseven-i-dyspozytor-int10-usos-windows-7-bez-csm)
4. [CSMWrap i SeaBIOS: XP i Vista bez CSM w firmware](#4-csmwrap-i-seabios-xp-i-vista-bez-csm-w-firmware)
5. [XP i pamięć: PAE](#5-xp-i-pamięć-pae)
6. [STOP 0xA5 w NT 5.x i sterownik ACPI społeczności](#6-stop-0xa5-w-nt-5x-i-sterownik-acpi-społeczności)
7. [Backporty USB 3 (xHCI) dla XP i Visty oraz tryb testowy Visty](#7-backporty-usb-3-xhci-dla-xp-i-visty-oraz-tryb-testowy-visty)
8. [Instalator Visty w środowisku Windows 10 PE](#8-instalator-visty-w-środowisku-windows-10-pe)
9. [Obrazy ISO Linuksa: urządzenie blokowe na fragmentach NTFS i przekaźnik shim](#9-obrazy-iso-linuksa-urządzenie-blokowe-na-fragmentach-ntfs-i-przekaźnik-shim)
10. [Secure Boot dla samego USOS: shim i MOK](#10-secure-boot-dla-samego-usos-shim-i-mok)
11. [Dalsza lektura](#11-dalsza-lektura)

---

## 1. BIOS, UEFI i CSM

Firmware komputera ma przed startem systemu dwa zadania: uruchamia sprzęt
i udostępnia usługi, z których może korzystać program rozruchowy (a czasem
sam system). Obie rodziny firmware oferują zupełnie inne usługi.

| | Legacy BIOS | UEFI | UEFI z CSM |
|---|---|---|---|
| Co jest uruchamiane | pierwszy sektor (MBR) dysku startowego | aplikacja EFI z partycji FAT, np. `\EFI\BOOT\BOOTX64.EFI` | jedno albo drugie |
| Usługi | przerwania trybu rzeczywistego: Int 10h (obraz), Int 13h (dysk), Int 16h (klawiatura), mapa pamięci E820 | usługi rozruchowe (boot services) i usługi czasu działania (runtime services); GOP do grafiki | oba zestawy |
| Grafika | BIOS karty graficznej (option ROM VBIOS), tryb tekstowy VGA i pamięć VGA | GOP: liniowy bufor obrazu przygotowany przez sterownik UEFI karty | GOP albo VBIOS, jeśli CSM go załaduje |

**CSM (Compatibility Support Module)** to część firmware UEFI, która dla
starszych systemów udaje BIOS. Badania nad CSMWrap opisują go jako moduł
EDK2 `LegacyBiosDxe` plus 16-bitowy program „CSM16”: CSM ładuje stary VBIOS
karty graficznej, wypełnia tablicę przerwań trybu rzeczywistego, buduje
tablice BIOS i uruchamia dysk MBR ([research/csmwrap.md](research/csmwrap.md),
sekcja 2). Na płytach AMI CSM emuluje też przez SMM porty klawiatury PS/2
dla klawiatur USB ([research/win98-feasibility.md](research/win98-feasibility.md)).

```
Legacy BIOS:   zasilanie -> POST BIOS (uruchamia się VBIOS) -> MBR dysku 0x80 -> loader systemu
UEFI:          zasilanie -> UEFI (GOP) -> \EFI\BOOT\BOOTX64.EFI -> loader systemu (EFI)
UEFI + CSM:    zasilanie -> UEFI (GOP) -> CSM (POST VBIOS, ustawione Int 10h/13h)
                                       -> MBR -> loader systemu (BIOS)
```

Komputer bez żadnego CSM notatki projektowe nazywają „Class 3”. Źródła
wymieniają jako takie ROG Ally, Intel od 12. generacji i część płyt AM5,
a także X470 z wyłączonym CSM
([design/csmwrap-integration.md](design/csmwrap-integration.md), sekcja 1).
Istnieje też stan pośredni: w firmware AMI „CSM włączony” razem z
„Video OpROM: UEFI only” daje CSM bez BIOS-u VGA, więc dla grafiki działa
to tak, jakby CSM nie było ([design/win7-vista-no-csm.md](design/win7-vista-no-csm.md),
sekcja 5).

Repozytorium nie opisuje, dlaczego producenci płyt usuwają CSM. Odnotowuje
za to jedną praktyczną konsekwencję: na wielu płytach Secure Boot wymaga
wyłączenia CSM i strona Secure Boot w USOS mówi o tym użytkownikowi
([secure-boot-usos.md](secure-boot-usos.md)).

Czego potrzebują kolejne generacje Windows:

| System | Sposób rozruchu | Czego potrzebuje od firmware |
|---|---|---|
| Windows XP, 2000, Server 2003, XP x64 (NT 5.x) | tylko BIOS | pełnego BIOS-u: VGA, Int 13h, E820 |
| Windows Vista SP1+ x64, Windows 7 x64 | możliwy UEFI | UEFI do startu **oraz** starego BIOS-u karty dla podstawowego sterownika ekranu |
| Windows 8 i nowsze | UEFI | niczego ze starego świata |

---

## 2. Int 10h, BIOS karty graficznej i dlaczego Windows 7 i Vista potrzebują starego VGA

Windows Vista SP1+ x64 i Windows 7 x64 potrafią wystartować z UEFI, a ich
menedżer rozruchu i loader rysują przez GOP. Podstawowa ścieżka wyświetlania
w jądrze nadal jednak wywołuje BIOS karty graficznej. Żądania `Int10`
z VideoPort wykonuje emulator trybu rzeczywistego x86 w HAL, a emulator
uruchamia to, na co wskazuje wektor przerwania 0x10 trybu rzeczywistego
(adres fizyczny 0x40). Zwykle jest to option ROM VGA karty, skopiowany pod
`0xC0000`. Z CSM firmware ładuje ten ROM i ustawia wektor. Na komputerze
Class 3 wektor ma wartość 0 albo śmieci, a Windows zatrzymuje się na
ekranie „Uruchamianie systemu Windows” (Starting Windows) lub kończy błędem
0xc000000d. Windows 8 i nowsze tego nie potrzebują
([design/win7-vista-no-csm.md](design/win7-vista-no-csm.md), sekcja 1).

```
Jądro Windows 7, podstawowy sterownik ekranu (vga / vgapnp.sys, VgaSave)
   |
   |  Int 10h  ->  emulator x86 w HAL  ->  IVT[0x10]  ->  C000:xxxx  (VBIOS)
   |                                                     z CSM: VBIOS karty
   |                                                     bez:   nic -> zawieszenie
   |
   +- bezpośredni dostęp do portów I/O VGA i okna pamięci VGA pod A0000
```

Sama podmiana Int 10h nie zawsze wystarcza. Windows 7 sięga także
bezpośrednio do portów I/O VGA i okna `0xA0000` (artykuł PrimeExpert
o FlashBoot, cytowany w [windows7-uefi-reference-analysis.md](windows7-uefi-reference-analysis.md)).
Te odwołania docierają do karty tylko wtedy, gdy mostek PCI nad nią ma
ustawione „VGA Enable”, a karta dekoduje stare I/O. Przy wyłączonym CSM
firmware X470 zostawiało obie te rzeczy zamknięte.

**Czarny ekran Windows 7 na X470.** Przy wyłączonym CSM UefiSeven,
odblokowanie AMD i sprawdzenie Int 10h przechodziły poprawnie, Windows
kończył fazę specialize, ale sterownik `vga`/`vgapnp.sys` padał z kodem 10
w ciągu 47 ms. Z włączonym CSM to samo urządzenie startowało jako „AMD
ATOMBIOS” ([design/win7-vista-no-csm.md](design/win7-vista-no-csm.md),
sekcja 6). Przyczyną okazało się kierowanie ruchu VGA: sonda rejestrów VGA
odczytywała `FF` na każdym porcie, zanim USOS otworzył ścieżkę, a po jej
otwarciu przechodziła (tam, sekcja 10).

**Czarny ekran Visty na X470.** Vista zachowuje się inaczej. Nawet
z włączonym CSM `vgapnp` Visty pada z kodem 10 na RX 560 i Windows przechodzi
na **VgaSave**. VgaSave potrzebuje starej pamięci VGA pod `A0000`. Przy
wyłączonym CSM ta pamięć odczytuje się jako `FF`, bo stary VBIOS karty nigdy
nie wykonał swojego POST. `vgapnp` Windows 7 startuje na danych VBE od
UefiSeven, więc `A0000=FF` mu nie przeszkadza. `vgapnp` Visty tak nie potrafi
([design/win7-vista-no-csm.md](design/win7-vista-no-csm.md), sekcja 10).
Sam GOP nic tu nie pomoże: daje liniowy bufor obrazu, a nie planarne okno
pamięci VGA, do którego pisze VgaSave.

**Dlaczego `0xC0000` musi być zapisywalne.** Zastępczy handler Int 10h musi
znajdować się w obszarze `0xC0000`. Na AMD Zen zakres `C0000-CFFFF` jest
kierowany do MMIO, dopóki bity RdMem/WrMem stałych MTRR nie wskażą DRAM,
więc zapisy trafiają donikąd. Na X470 pierwsze 16 bajtów pod `C0000`
odczytywało się jako `FF` i nie było protokołu Legacy Region
([windows7-amd-shadow-2026-09-20.md](windows7-amd-shadow-2026-09-20.md)).
Krok `amd_shadow` w USOS ustawia te bity, ale tylko na CPUID `00a20f12`
(Vermeer: 5700X/5800X3D). Inne procesory AMD, np. Phoenix w ROG Ally,
oraz płyty Intela bez protokołu Legacy Region nie są obsługiwane
([design/win7-vista-no-csm.md](design/win7-vista-no-csm.md), sekcja 6).

---

## 3. UefiSeven i dyspozytor Int10 USOS (Windows 7 bez CSM)

**UefiSeven** 1.30 (BSD-2-Clause, następca VgaShim) to aplikacja UEFI,
która udaje brakujący BIOS karty graficznej. Przejmuje stronę z tablicą
przerwań, przełącza GOP na 1024x768, odblokowuje zapis do `0xC0000`
(protokoły Legacy Region, potem stałe MTRR), kopiuje tam mały handler trybu
rzeczywistego i dwie tablice VBE (bufor GOP służy jako liniowy bufor VBE),
ustawia wektor 0x10 na `C000:0200`, sprawdza handler i dopiero wtedy
uruchamia oryginalny menedżer rozruchu Windows. Jeśli wektor już wskazuje
wiarygodny handler firmware, zostawia go w spokoju
([design/win7-vista-no-csm.md](design/win7-vista-no-csm.md), sekcja 2).

USOS umieszcza przed UefiSeven własny **dyspozytor** na ESP zainstalowanego
systemu. Pod koniec instalacji (Setup działa w środowisku Windows PE 6.2
lub nowszym, obsługującym GOP: we własnym PE hybrydowego ISO albo w PE10
dawcy, więc sam Setup nigdy nie potrzebuje shima) finalizator zapisuje:

| Plik na ESP dysku docelowego (w `\EFI\Microsoft\Boot\` i w `\EFI\Boot\`) | Zawartość |
|---|---|
| `bootmgfw.efi` / `bootx64.efi` | dyspozytor USOS (`win7-wrapper.efi`) |
| `win7.efi` | UefiSeven |
| `win7.original.efi` | menedżer rozruchu Microsoftu zapisany przez Setup (wersja sprawdzana) |
| `UefiSeven.ini`, `uefiseven-LICENSE.txt` | konfiguracja (`logfile=1`) i licencja |

Dyspozytor decyduje przy **każdym starcie**, a nie w chwili instalacji,
bo dysk żyje dłużej niż ustawienia firmware, z którymi go zainstalowano
(użytkownicy przełączają CSM, przenoszą dyski, aktualizują firmware).
Sprawdzana jest tablica przerwań, a nie pytanie „czy jest CSM”:

```
start dyspozytora
  |- IVT[0x10] wskazuje w C0000-EFFFF, a pierwszy opcode to nie 00/FF?
  |     tak -> CSM dostarczył VBIOS -> od razu win7.original.efi
  |     nie:
  |- jest GOP? (do 3 przebiegów ConnectController, potem do 2 zimnych restartów)
  |- AMD Vermeer: C0000-CFFFF jako DRAM (bity RdMem/WrMem stałych MTRR)
  |- kierowanie starego VGA do karty z GOP:
  |     sonda rejestrów VGA -> urządzenie PCI z GOP i jego mostki
  |     -> PciIo.Attributes(Enable, pamięć VGA + I/O VGA) -> ręczne ustawienie w razie potrzeby
  |     -> ponowna sonda: passed_before | passed_after | failed (komunikat na 5 s)
  '- win7.efi (UefiSeven) -> win7.original.efi (menedżer rozruchu Windows)
```

To właśnie krok **kierowania VGA** naprawił X470. Dyspozytor znajduje
urządzenie PCI stojące za GOP, prosi sterownik PCI firmware o włączenie na
nim starej pamięci i I/O VGA (sterownik magistrali PCI w stylu EDK2 ustawia
wtedy VGA Enable na mostkach powyżej) i dopiero gdy to nie wystarczy, sam
ustawia bity mostka i rejestru poleceń, z zasadami bezpieczeństwa: nie
włącza dekodowania I/O na mostku, którego okno I/O jest otwarte poniżej
0x1000, i nie ustawia VGA Enable, gdy VGA należy już do innego mostka
([design/win7-vista-no-csm.md](design/win7-vista-no-csm.md), sekcja 8.3).

Wynik sprzętowy z 2026-09-26, build B260926-134756: **Windows 7 x64
zainstalował się i doszedł do pulpitu na X470 z wyłączonym CSM i wyłączonym
Secure Boot.** Log pokazał `VGA probe before: FAIL` (każdy port `FF`),
`GPU Attributes(Enable, 318) = success`, a potem `VGA probe after: PASS`.
Rejestr sterujący mostka portu głównego zmienił się z `0010` na `0018`
(VGA Enable włączone), a rejestr poleceń karty z `0006` na `0007`
(dekodowanie I/O włączone). Klucz rejestru urządzenia ekranu zapisał
`ChipType = "UefiSeven"`: `vgapnp.sys` wystartował na danych VBE od
UefiSeven. `A0000` nadal odczytywało `FF` po kierowaniu, co Windows 7
toleruje (tam, sekcja 10).

Każdy start trafia do logu cyklicznego na ESP (`usos-boot-uefiseven.log`
albo `usos-boot-csm.log`, po 8 startów), więc start z CSM nigdy nie zamazuje
śladów startu bez CSM.

Znane ograniczenia ([design/win7-vista-no-csm.md](design/win7-vista-no-csm.md),
sekcja 6):

- Secure Boot musi być wyłączony. UefiSeven i dyspozytor nie są podpisane,
  a ta ścieżka przepisuje tablicę przerwań i starą pamięć.
- Rozdzielczość to 1024x768, dopóki nie zostanie zainstalowany sterownik
  producenta karty.
- Słabym punktem jest zapisywalne `0xC0000`: procesory i płyty spoza
  obsługiwanych przypadków zapiszą w logu nieudany test handlera.
- Aktualizacja Windows albo `bcdboot`, które przepiszą `bootmgfw.efi`,
  usuwają dyspozytor z głównego wpisu. Naprawa: ponowne zapisanie
  dyspozytora albo włączenie CSM.

Ten sam dyspozytor jest instalowany dla Visty na UEFI, gdzie przy obecnym
CSM tylko przepuszcza start dalej. Bez CSM Viście nie pomaga (problem
VgaSave z sekcji 2), dlatego Vista bez CSM idzie drogą CSMWrap.

---

## 4. CSMWrap i SeaBIOS: XP i Vista bez CSM w firmware

XP i pozostałe systemy NT 5.x w ogóle nie potrafią startować z UEFI.
Potrzebują prawdziwego BIOS-u przez cały czas działania. Gdy płyta nie ma
CSM, USOS przynosi własny: **CSMWrap**, aplikację EFI, która robi to samo
co CSM w firmware, tylko spoza firmware, a jako BIOS-u używa forka
**SeaBIOS**. CSMWrap ma licencję LGPL-2.1, jego fork SeaBIOS LGPLv3
([research/csmwrap.md](research/csmwrap.md)).

Co po kolei robi CSMWrap 3.1.2 ([research/csmwrap.md](research/csmwrap.md),
sekcja 2):

1. Czyta `csmwrap.ini` leżący obok niego.
2. Odblokowuje stary obszar `0xC0000-0xFFFFF` (protokół Legacy Region 2,
   rejestry PAM Intela albo na AMD stałe MTRR, czyli ten sam mechanizm co
   odblokowanie AMD w USOS) i sprawdza go.
3. Buduje tablice, których oczekuje system BIOS-owy: łata tablicę ACPI MADT,
   żeby ukryć jeden procesor, tworzy SMBIOS 2.x, tablicę MP, tablicę `$PIR`
   i mapę E820 z mapy pamięci UEFI.
4. Znajduje kartę z GOP i wyjmuje **obraz PC-AT (stary VBIOS)** z kopii
   option ROM karty (`EFI_PCI_IO_PROTOCOL.RomImage`). Jeśli go nie ma,
   używa SeaVGABIOS rysującego na buforze GOP.
5. Tam, gdzie się da, przenosi BAR-y PCI poniżej 4 GiB.
6. Wywołuje `ExitBootServices`: od tej chwili UEFI znika do końca tego
   cyklu zasilania. Nie ma drogi powrotu.
7. Kopiuje na miejsce SeaBIOS i VBIOS, uruchamia **BIOS proxy** na
   zarezerwowanym procesorze i wykonuje prawdziwy POST VBIOS-u karty.
8. Ustawia dysk, z którego został wczytany, jako pierwszy w kolejności
   rozruchu, czyta jego sektor 0 i skacze do niego z `DL=0x80`.

**Dlaczego rezerwowany jest jeden wątek procesora.** Wywołania BIOS-u
z trybu V86 muszą gdzieś się wykonać. CSM w firmware używa do tego SMM;
poza firmware SMM nie ma, więc CSMWrap trzyma jeden procesor w trybie
chronionym jako „BIOS proxy”, który wykonuje 32-bitowy kod SeaBIOS dla tych
wywołań. Ten procesor jest ukryty przed systemem w MADT i tablicy MP.
Informacje o wydaniu ujmują to tak: CSMWrap rezerwuje jeden wątek procesora
dla swojego BIOS proxy, więc zainstalowany system widzi o jeden procesor
logiczny mniej. Dlatego CSMWrap potrzebuje co najmniej dwóch procesorów
logicznych ([research/csmwrap.md](research/csmwrap.md), sekcje 2-3,
[release-notes-1.0.md](release-notes-1.0.md#csmwrap-paths-xp-vista-2000-2003-xp-x64-without-a-firmware-csm)).

**Dlaczego potrzebny jest stary VBIOS.** Z własnym VBIOS-em karty tekstowy
etap instalatora XP, ekran startowy, `vga.sys`/VgaSave i VBE działają tak
jak pod CSM w firmware. Z samym SeaVGABIOS jest tylko VBE na buforze GOP:
bezpośrednie zapisy do bufora tekstowego pod `B8000` i do `A0000` są
niewidoczne. W QEMU z kartą tylko z GOP ekran był czarny od SeaBIOS
i tekstowy etap instalatora XP nie ruszył dalej. RX 560 ma w ROM-ie oba
obrazy. Zintegrowana grafika ROG Ally niemal na pewno nie ma obrazu PC-AT
([design/csmwrap-integration.md](design/csmwrap-integration.md), sekcje 3
i 7, [research/csmwrap.md](research/csmwrap.md), sekcja 3).

**Gdzie mieszka CSMWrap: ESP na końcu dysku docelowego.** Zainstalowany XP
musi startować bez pendrive'a, a każdy start wymaga CSMWrap. Dlatego
przygotowanie XP (które i tak działa z UEFI, w mikro-Linuksie) zostawia
wolne ostatnie 65 MiB dysku i tworzy tam partycję FAT16 o rozmiarze 64 MiB
(typ MBR `0xEF`) z CSMWrap jako `\EFI\BOOT\BOOTX64.EFI`, jego `csmwrap.ini`
oraz licencjami i kodem źródłowym. Nie jest zapisywany żaden wpis rozruchowy
w firmware: dysk uruchamia wpis firmware dla ścieżki nośnika wymiennego.
Ponieważ CSMWrap jako pierwszy uruchamia dysk, z którego sam pochodzi,
trafia na MBR dysku docelowego bez żadnej konfiguracji
([design/csmwrap-integration.md](design/csmwrap-integration.md), sekcje 2 i 8).

```
dysk docelowy (MBR, <= 2 TiB, wymazany)
  wpis 1  NTFS, aktywna, LBA 2048   Windows XP
  wpis 2  FAT16, typ 0xEF, 64 MiB na końcu   \EFI\BOOT\BOOTX64.EFI = CSMWrap
                                             \EFI\BOOT\csmwrap.ini, \CSMWRAP\ (licencje, źródła)

każdy start: firmware -> wpis UEFI dysku -> CSMWrap -> SeaBIOS (POST VBIOS karty)
             -> MBR (DL=80h) -> kod startowy NTFS -> NTLDR/SETUPLDR -> XP
```

ESP jest **ostatnia**, a nie pierwsza, celowo: partycja Windows zostaje
wpisem 1 w MBR od LBA 2048, więc ścieżki ARC w `WINNT.SIF`, `boot.ini`
i w pomocniku PAE są dokładnie takie jak w sprawdzonym układzie z CSM
([design/csmwrap-integration.md](design/csmwrap-integration.md), sekcja 8).
USOS wybiera tę ścieżkę tylko wtedy, gdy menu UEFI nie znajdzie CSM
w firmware. Z CSM nic się nie zmienia.

**Vista przez CSMWrap.** Menedżer rozruchu UEFI Visty potrzebuje usług
rozruchowych i usług czasu działania UEFI, więc nie może działać po CSMWrap,
który już zakończył usługi rozruchowe. Dlatego Vista bez CSM jest
instalowana jako **stary system MBR** i uruchamiana przez taką samą ESP na
dysku docelowym (sekcja 8 poniżej).

**Cichy build 3.1.2-usos1.** Nawet z `verbose = false` oryginalny 3.1.2
zawsze wypisywał logo, baner SeaBIOS i zachętę „Press ESC for boot menu”
z odczekaniem 2,5 s. USOS dostarcza własny build ze źródeł, **CSMWrap
3.1.2-usos1**, z trzema małymi łatkami: logo tylko przy `verbose = true`;
nowa flaga „quiet” przekazywana z CSMWrap do SeaBIOS, która wycisza baner
i wiersze „Booting from ...” (komunikaty o błędach zostają); oraz brak menu
rozruchowego przy cichym starcie. `verbose = true` przywraca wszystkie
oryginalne ekrany, a pusty plik `EFI\USOS\csmwrap-verbose.flag` na
pendrivie włącza to ustawienie. Build powstaje w jednorazowej maszynie
wirtualnej z Alpine z przypiętymi wersjami pakietów i dwa kolejne buildy
dają te same bajty. Archiwum źródeł i łatki trafiają na każdą ESP z CSMWrap,
tak jak wymaga LGPL ([research/csmwrap.md](research/csmwrap.md), sekcje 6-7).

**Co zostało.** Migający kursor tekstowy (podkreślenie w lewym górnym rogu)
widać od przełączenia SeaBIOS w tryb tekstowy do chwili, gdy loader Windows
zmieni tryb obrazu. Ukrycie go wymaga kolejnej łatki SeaBIOS
([research/csmwrap.md](research/csmwrap.md), sekcja 7).

Pozostałe ograniczenia: CSMWrap nigdy nie jest podpisywany, więc Secure
Boot musi być wyłączony (podpisanie pozwoliłoby każdemu uruchamiać
niezweryfikowany kod BIOS-u w łańcuchu zaufania USOS); SeaBIOS obsługuje
klawiaturę USB tylko przez Int 16h, bez emulacji 8042, więc do obsługi
wejścia w XP potrzebny jest własny sterownik USB systemu; dysk docelowy
musi być MBR i zostaje wymazany ([research/csmwrap.md](research/csmwrap.md),
sekcje 4-5).

Wyniki sprzętowe na X470 z wyłączonym CSM i wyłączonym Secure Boot:
**XP SP3 (polski) zainstalowany bezobsługowo przez CSMWrap** (2026-09-27,
build B260927-153019) oraz **Vista SP2 x64 zainstalowana i uruchamiana
z własnego dysku przez CSMWrap** (2026-09-28, build B260927-205829). Sam
cichy build usos1 przeszedł testy w QEMU, ale na X470 nie jest jeszcze
potwierdzony ([design/csmwrap-integration.md](design/csmwrap-integration.md),
sekcje 9 i 10.5, [release-notes-1.0.md](release-notes-1.0.md#not-tested-yet)).

---

## 5. XP i pamięć: PAE

32-bitowy Windows XP normalnie korzysta z najwyżej 4 GB RAM. Projekt
rodziny NT5 wymienia XP x86 jako system kliencki, którego limit 4 GB USOS
znosi łatką („4 GB → pełna pamięć”), a taki sam limit 4 GB w Windows 2000
Professional/Server i Server 2003 Standard opisuje jako licencyjny limit
w jądrze ([design/nt5-uefi-family.md](design/nt5-uefi-family.md), sekcja 5).
PAE (Physical Address Extension) to tryb procesora, w którym 32-bitowe
jądro adresuje pamięć powyżej 4 GB.

Pomocnik USOS `pae.exe` działa tak
([windows-xp-uefi-csm-pae-2026-09-21.md](windows-xp-uefi-csm-pae-2026-09-21.md)):

1. Przyjmuje wyłącznie Windows XP 5.1.2600. Sprawdza wersje plików jądra
   i HAL oraz szuka w ich sekcjach wykonywalnych jednoznacznych wzorców
   łatki. Nieznane wersje i wzorce są odrzucane.
2. Zapisuje **załatane kopie** pod nowymi nazwami, `usospae.exe`
   i `usoshal.dll`, i poprawia ich sumy kontrolne PE. Oryginalne jądro
   i HAL nigdy nie są nadpisywane.
3. Robi kopię `boot.ini` w `C:\USOS\XP\boot-original.ini` i dodaje wpis PAE
   korzystający z załatanych plików. Ten wpis jest pierwszy, więc domyślny,
   a `timeout=0` ukrywa menu. Oryginalny wpis zostaje: F8 przy starcie,
   potem „Powrót do menu wyboru systemu operacyjnego”.
4. Uruchamia się pod koniec graficznej części instalacji
   (`[SetupParams] UserExecute`), więc restart kończący instalację startuje
   już z PAE. Zapasowo działa przy pierwszym logowaniu, jeśli to się nie
   udało.

Wzorce łatki pochodzą z **PatchPAE3** (evgen-b, CC-BY-4.0, przypięty
commit). Oryginalny skrypt, który sam podnosi uprawnienia, nie jest ani
uruchamiany, ani dostarczany.

Wynik: czysta instalacja XP SP3 na X470 pokazuje z wpisem PAE **31,9 GB
RAM** ([release-notes-1.0.md](release-notes-1.0.md#hardware-tested-configurations)).
Dla XP przez CSMWrap, gdzie mapę pamięci E820 buduje CSMWrap, użytkownik
nie podał jeszcze ilości widocznej pamięci.

Powiązane utwardzenie: pakiety sterowników ustawiają `CrashDumpEnabled=0`.
W jednej instalacji testowej błąd krytyczny w ścieżce zrzutu pamięci,
a po nim wymuszone wyłączenie zasilania, zostawiły w WinSxS pliki wypełnione
zerami. Przygotowanie sprawdza teraz także dysk docelowy po zapisie (tylko
do odczytu) i odrzuca go, jeśli jakiś niepusty plik odczytuje się jako same
zera ([windows-xp-uefi-csm-pae-2026-09-21.md](windows-xp-uefi-csm-pae-2026-09-21.md)).

Pozostałe systemy NT 5.x ([design/nt5-uefi-family.md](design/nt5-uefi-family.md),
[nt52-2003-xp64-2026-09-27.md](nt52-2003-xp64-2026-09-27.md)):

| System | PAE |
|---|---|
| XP x86 SP3 | łatka (`pae.exe`) |
| Windows 2000 Pro / Server | brak (limit 4 GB, jądro 5.0 nie jest łatane) |
| Server 2003 x86 Enterprise | natywne: USOS dopisuje `/PAE` pod koniec instalacji |
| XP x64, Server 2003 x64 | niepotrzebne (64 bity) |

XP w trybie Legacy BIOS nie dostaje ani pakietu sterowników, ani PAE; mają
je tylko warianty UEFI ([release-notes-1.0.md](release-notes-1.0.md#nt-5x-on-modern-boards)).

---

## 6. STOP 0xA5 w NT 5.x i sterownik ACPI społeczności

Tablice ACPI opisują płytę systemowi operacyjnemu. Nowoczesne firmware
buduje je nowoczesnymi narzędziami, a sterowniki ACPI dostarczane z NT 5.x
nie zawsze potrafią je odczytać.

Na X470 (CSM włączony, build B260927-201324) Server 2003 x86 i XP x64
zatrzymywały się na początku tekstowego etapu instalacji z **STOP 0xA5
(0x11, 0x8, &lt;tabela&gt;, 0x20120913)**: ACPI_BIOS_ERROR, „nie można wejść
w tryb ACPI”, na tablicach firmware zbudowanych iASL 20120913. Standardowy
`ACPI.SYS` z NT 5.2, z epoki ACPI 1.0b, nie potrafi ich przetworzyć.
Tablice QEMU są proste, więc w QEMU problem nigdy się nie pojawił
([nt52-usb3-2026-09-27.md](nt52-usb3-2026-09-27.md), sekcja 5).

XP x86 działa na tej płycie, bo jego pakiet **zastępuje `ACPI.SYS`
sterownikiem ACPI 2.0 społeczności**. Zamiennik trafia w oba miejsca,
z których Setup może wziąć plik: do skompresowanego `ACPI.SY_` i do pamięci
podręcznej `SP3.CAB`, więc późniejszy krok instalacji nie pobierze starej
kopii ([windows-xp-driver-integration-2026-09-21.md](windows-xp-driver-integration-2026-09-21.md)).

| System | ACPI w wersji 1.0 |
|---|---|
| XP x86 SP3 | ACPI 2.0 społeczności (x86) w pakiecie: działa na X470 |
| Server 2003 x86 | ten sam sterownik x86 działa jako pakiet (0 brakujących importów, QEMU do graficznego instalatora), ale pakiety wydania 1.0 go nie zawierają |
| XP x64 | istnieją buildy x64, ale są skompilowane z wykradzionego kodu Microsoftu, więc USOS nigdy ich nie dołącza; użytkownik musiałby dostarczyć sterownik sam, a USOS nie ma jeszcze kroku, który podmieniłby ACPI |
| Windows 2000 | standardowy ACPI 5.0 jest jeszcze starszy; sterownik społeczności z XP jest zbudowany pod jądro 5.1 i nie da się go po prostu podmienić |

Zapasowe „F7” (HAL bez ACPI) nie jest wyjściem na tych płytach. XP x64
i Server 2003 x64 w ogóle nie mają HAL bez ACPI. Server 2003 x86 z F7
działałby na jednym procesorze ze starym kontrolerem PIC i potrzebowałby
BIOS-owego kierowania przerwań dla każdego urządzenia PCIe, które na AM4
jest w najlepszym razie częściowe ([nt52-usb3-2026-09-27.md](nt52-usb3-2026-09-27.md),
sekcja 5, [release-notes-1.0.md](release-notes-1.0.md#nt-5x-on-modern-boards)).

---

## 7. Backporty USB 3 (xHCI) dla XP i Visty oraz tryb testowy Visty

X470 ma wyłącznie kontrolery xHCI (USB 3), bez EHCI. XP, Server 2003, XP x64
i Vista nie mają własnego sterownika xHCI. Zanim wystartuje jądro,
klawiaturę obsługuje firmware (albo SeaBIOS). Gdy sprzęt przejmie Windows,
potrzebny jest jego własny sterownik, inaczej wejście USB znika
([research/csmwrap.md](research/csmwrap.md), sekcja 4).

**XP x86.** Pakiet XP zawiera backport USB 3, KMDF 1.11 i rozszerzenie jądra
(`ntoskrn8`), a dla dysku GenAHCI i backport StorPort. Tekstowy etap
instalacji nie wymaga klawiszy: po wyborze dysku w USOS jest w pełni
bezobsługowy (zmierzone w QEMU: naciskanie klawiszy podczas sprawdzania
dysku i kopiowania niczego nie zmieniało). Brak klawiatury ma więc
znaczenie dopiero od etapu graficznego, gdy backport jest już załadowany
([windows-xp-uefi-csm-pae-2026-09-21.md](windows-xp-uefi-csm-pae-2026-09-21.md),
[design/nt5-uefi-family.md](design/nt5-uefi-family.md), sekcja 3.4).

**Server 2003 x86 i XP x64.** W wersji 1.0 brak wejścia USB na płytach
tylko z xHCI. Importy backportu z XP rozwiązują się na Server 2003, ale
tekstowy etap instalacji kończył się w QEMU błędem STOP 0xDEADBEEF, więc
ta praca jest odłożona. Dla XP x64 realną opcją jest karta PCIe z układem
Renesas uPD720201/720202 i jej oficjalnym sterownikiem
([nt52-usb3-2026-09-27.md](nt52-usb3-2026-09-27.md)).

**Vista x64.** Ścieżka Visty korzysta z metody społeczności: najpierw
KMDF 1.11 (KB2864202 Microsoftu), potem backport stosu USB 3 z Windows 8
([windows-vista-community-usb-2026-09-20.md](windows-vista-community-usb-2026-09-20.md)).
Zanim Vista przyjęła ten sterownik, potrzebnych było kilka podejść:

- Pakiet społeczności jest podpisany przez firmę trzecią (Riolin). Vista
  nadal go odrzucała w `SetupCopyOEMInf` (`0xe0000242`), mimo że certyfikat
  wydawcy był w magazynie TrustedPublisher komputera. Dokładnej przyczyny
  nie ustalono; wygaśnięcie certyfikatu nie jest podawane jako powód.
- Katalogi USB 3 samego AMD zostały odrzucone z kodem `0xe0000244`,
  AUTHENTICODE_WRONG_OS ([windows-vista-intel-2026-09-20.md](windows-vista-intel-2026-09-20.md)).
  Katalog AMD dla X470 jest oznaczony tylko dla Windows 7 (OSAttr 6.1)
  i korzysta z łańcucha SHA-256 ([ROADMAP.md](ROADMAP.md), sekcja 3).
- Dlatego USOS **podpisuje kopię katalogu na nowo** lokalnym certyfikatem
  testowym. Pliki INF i SYS oraz zawartość katalogu pozostają identyczne
  bajt w bajt; wymieniany jest tylko podpis katalogu. Łańcuch testowy to
  osobny certyfikat główny i certyfikat wydawcy (pierwsza próba używała do
  podpisu certyfikatu CA i została odrzucona), a notatki mówią, że SHA-1
  wybrano celowo dla tego pakietu Visty SP2. Certyfikat publiczny jest
  dodawany do magazynów Root i TrustedPublisher systemu docelowego.

Vista x64 ładuje tak podpisane sterowniki jądra **tylko z włączonym
podpisywaniem testowym (TESTSIGNING)**. Bez niego `usbxhci` się nie ładuje,
a na X470 nie byłoby klawiatury ani myszy. Dlatego zainstalowana Vista
działa w **trybie testowym** (napis „Tryb testowy” na pulpicie). Nie istnieje
legalnie podpisany sterownik xHCI dla X470 pod Vistę x64. Jedyny sposób na
wyjście z trybu testowego to **karta PCIe USB 3 z układem Renesas
uPD72020x**, której sterownik producenta obsługuje Vistę
([windows-vista-existing-esp-2026-09-26.md](windows-vista-existing-esp-2026-09-26.md),
[design/csmwrap-integration.md](design/csmwrap-integration.md), sekcja 10.5).

**Znane ograniczenie: brak pendrive'ów w zainstalowanej Viście.** Ze stosem
z backportu działają klawiatura i mysz, ale pendrive'y i inne pamięci
masowe USB nie pojawiają się w Eksploratorze ani w Zarządzaniu dyskami.
Przyczyna jest nadal badana. Obejścia: sieć, drugi wewnętrzny dysk SATA,
napęd optyczny albo karta Renesas z własnym sterownikiem
([release-notes-1.0.md](release-notes-1.0.md#windows-vista-usb-flash-drives-are-not-visible-in-the-installed-system)).

---

## 8. Instalator Visty w środowisku Windows 10 PE

Własnego środowiska instalacyjnego Visty (jej WinPE) nie da się użyć na X470:

- nie ma **sterownika xHCI**, więc w instalatorze nie działa klawiatura
  ani mysz;
- na UEFI jego menedżer rozruchu potrzebuje BIOS-u karty graficznej
  (sekcja 2), a menedżer rozruchu, loader i jądro Windows PE 10 obsługują
  GOP natywnie ([design/win7-vista-no-csm.md](design/win7-vista-no-csm.md),
  sekcja 4, [design/csmwrap-integration.md](design/csmwrap-integration.md),
  sekcja 10.1).

Dlatego USOS uruchamia **PE10 dawcy** (`PE10_x64_19041_USOS.iso`: Windows
PE 10 x64 z Setup, bez obrazu instalacyjnego; osobny plik wydania, którego
SHA-256 zapisuje się w `EFI\USOS\winpe-donor.ini`) i wewnątrz niego
**własny `setup.exe` Visty z jej ISO**. PE10 ma własne sterowniki USB 3,
AHCI i NVMe. `boot.wim` Visty służy wyłącznie jako źródło plików.
Przyjmowane są tylko nośniki instalacyjne SP2
([design/win7-vista-no-csm.md](design/win7-vista-no-csm.md), sekcja 7).
Tego samego dawcy USOS używa dla oryginalnych ISO Windows 7 na UEFI
([windows7-pe10-handoff-2026-09-20.md](windows7-pe10-handoff-2026-09-20.md)).

Wokół instalatora pomocniki USOS robią trzy rzeczy
([windows-vista-usb-install-2026-09-21.md](windows-vista-usb-install-2026-09-21.md)):

1. **KMDF przez mechanizm serwisowania samego Setup.** Setup dostaje plik
   odpowiedzi z blokiem `<servicing>` dla KB2864202, więc KMDF 1.11 do
   nowego systemu instaluje sam Setup. Potem pomocnik wymaga, żeby
   `Wdf01000.sys` i `WdfLdr.sys` w systemie docelowym miały wersję 1.11,
   zanim cokolwiek uzbroi; jeśli nie mają, zatrzymuje się w PE, gdzie
   wejście nadal działa.
2. **Bramka USB przy pierwszym starcie.** Pomocnik USOS uruchamia się przy
   pierwszym starcie zainstalowanej Visty przed resztą instalacji, instaluje
   backport USB 3 i wstrzymuje Setup, dopóki kontroler, klawiatura i mysz
   nie zgłoszą uruchomienia.
3. **Konfiguracja rozruchu.** Finalizator włącza podpisywanie testowe
   w BCD nowego systemu.

Są dwa sposoby uruchomienia, zależnie od firmware:

```
UEFI z CSM:
  menu USOS -> wimboot -> PE10 (RAM) -> setup.exe Visty z ISO -> instalacja GPT
  zainstalowana Vista: dyspozytor na ESP dysku (przepuszcza, VBIOS daje CSM)

UEFI bez CSM:
  menu USOS -> mikro-Linux przygotowuje dysk docelowy (MBR):
      slot 1  NTFS „USOS-VISTA”, 1 GiB, aktywna: kod startowy NT60, bootmgr,
              obraz Setup z PE10 z pomocnikami USOS
      slot 2  ESP z CSMWrap, 64 MiB
  restart -> CSMWrap -> SeaBIOS (VBIOS karty) -> MBR -> bootmgr -> PE10 w trybie BIOS
          -> setup.exe Visty z ISO na pendrivie -> stara instalacja MBR
  każdy kolejny start: firmware -> wpis UEFI dysku -> CSMWrap -> Vista
```

W wariancie bez CSM sam Setup tworzy prawdziwą starą instalację, więc potem
niczego nie trzeba konwertować. Partycja przygotowawcza jest przed
instalacją ukrywana i dezaktywowana, a po niej usuwana
([design/csmwrap-integration.md](design/csmwrap-integration.md), sekcja 10).
Między przygotowaniem dysku a instalatorem potrzebny jest jeden restart.

---

## 9. Obrazy ISO Linuksa: urządzenie blokowe na fragmentach NTFS i przekaźnik shim

Uruchomienie jądra z ISO Linuksa to łatwiejsza połowa. Trudniejsza
zaczyna się potem: initramfs dystrybucji musi znaleźć główny system plików
wersji live albo pakiety instalatora **na nośniku**. Na płycie DVD nośnik
to urządzenie blokowe z ISO9660. Na pendrivie USOS to plik na partycji NTFS
`USOS_DATA`, a większość initrd wersji live nie potrafi zamontować NTFS.
USOS nie może też dołożyć modułu `ntfs3` z zewnątrz: musi on pasować do
dokładnie tego builda jądra, a pod Secure Boot mieć podpis modułów
dystrybucji ([design/linux-iso-boot.md](design/linux-iso-boot.md), sekcja 1).

Rozwiązanie USOS polega na **zamianie pliku ISO w urządzenie blokowe,
zanim ruszy init dystrybucji**:

```
menu USOS (UEFI) / BIOS Core
  1. otwarcie ISO na DATA własnym czytnikiem NTFS USOS
  2. odczyt grub.cfg z ISO -> rodzina, jądro, initrd, wiersz poleceń
  3. przeliczenie fragmentów (runs) pliku w NTFS na bezwzględne sektory dysku (maks. 64)
  4. initrd = initrd dystrybucji + usos-linux.cpio + wygenerowane cpio (/usos/iso.map)
  5. start jądra z rdinit=/usos/init
Linux
  6. /usos/init (statyczny, bez libc): znajduje dysk USB po CRC deskryptora
     woluminu ISO, potem
        1 fragment  -> urządzenie loop z przesunięciem (tylko do odczytu)
        n fragmentów -> device-mapper „usos-iso”, n celów linear (tylko do odczytu)
     tworzy /dev/usos-iso i uruchamia /init dystrybucji
  7. dystrybucja widzi zwykłe urządzenie ISO9660 i startuje jak z DVD
```

Dystrybucja nie potrzebuje obsługi NTFS: wystarczy jej surowy dostęp do
dysku USB i `loop` (ma go każdy initrd wersji live) albo `dm-mod`. W RAM
jest tylko initrd, a nie całe ISO. Jedno lub dwa słowa w wierszu poleceń
mówią każdej rodzinie, gdzie jest nośnik (np. `live-media=/dev/usos-iso`
dla casper i live-boot). Initrd instalatora sieciowego Debiana nie ma ani
`loop`, ani `dm-mod`, więc dla niego `/usos/init` dodaje w jądrze partycję
obejmującą ciągłe ISO (`BLKPG_ADD_PARTITION`, tylko w tablicy jądra; na
dysk nic nie jest zapisywane). Plik z więcej niż 64 fragmentami jest
odrzucany z komunikatem „skopiuj ISO ponownie”
([design/linux-iso-boot.md](design/linux-iso-boot.md), sekcje 3 i 11).

**Secure Boot: przekazanie do własnego shima dystrybucji.** Jądro
dystrybucji jest podpisane przez dystrybucję (Canonical, Debian, Fedora),
a nie przez USOS. Shim USOS pochodzi z Fedory, więc przechodzą przez niego
tylko jądra Fedory. Dla pozostałych USOS uruchamia **podpisany przez
Microsoft shim z samego ISO** (`\EFI\BOOT\BOOTX64.EFI`). Ten shim instaluje
swój weryfikator (z CA dystrybucji) i uruchamia swój „drugi etap”,
`grubx64.efi` z tego samego katalogu, którym na ESP USOS jest **sam USOS**
(podpisany MOK, akceptowany przez każdy shim dzięki MokList). Ta druga
instancja USOS odczytuje jednorazowy plan przekazania, pyta kolejne
zainstalowane weryfikatory shim (`SHIM_LOCK->Verify`), aż któryś przyjmie
jądro dystrybucji, po czym je ładuje i uruchamia. Nic nie jest łatane,
a każdy uruchamiany obraz sprawdza jakiś shim. Blokadę jądra (lockdown)
egzekwuje potem samo jądro dystrybucji
([design/linux-iso-boot.md](design/linux-iso-boot.md), sekcja 5).

```
firmware -> shim USOS -> USOS (menu) -> shim dystrybucji (podpis MS)
         -> „grubx64.efi” = USOS (przekaźnik) -> SHIM_LOCK->Verify(jądro dystrybucji) -> jądro
```

Przetestowano w QEMU dziesięć obrazów ISO, a na X470 Minta, Fedorę,
instalator sieciowy Debiana, SystemRescue, Clonezillę i GParted (Secure
Boot wyłączony) oraz Fedorę i Minta (Secure Boot włączony). SystemRescue
nie ma podpisanego programu rozruchowego, więc wymaga wyłączenia Secure
Boot ([design/linux-iso-boot.md](design/linux-iso-boot.md), sekcje 11-12,
[release-notes-1.0.md](release-notes-1.0.md#supported-systems)).

---

## 10. Secure Boot dla samego USOS: shim i MOK

Z włączonym Secure Boot firmware uruchamia tylko obrazy podpisane kluczem
z bazy `db`, czyli w praktyce przez UEFI CA Microsoftu. USOS korzysta z tego
samego modelu co większość dystrybucji Linuksa: podpisanego przez Microsoft
**shima**, który ufa drugiej liście kluczy, liście **MOK** (Machine Owner
Key) ([secure-boot-usos.md](secure-boot-usos.md)).

| Ścieżka na ESP | Zawartość | Kto jej ufa |
|---|---|---|
| `\EFI\BOOT\BOOTX64.EFI` | shim 16.1 (build Fedory) | `db` firmware: Microsoft UEFI CA 2011 **i** 2023 |
| `\EFI\BOOT\mmx64.efi` | MokManager | CA Fedory wbudowane w ten shim |
| `\EFI\BOOT\grubx64.efi` | USOS (menu UEFI) z sekcją `.sbat` | klucz USOS dodany do MokList |
| `\USOS-KEY.cer` | publiczny certyfikat USOS | - |

Kluczem USOS podpisane są też jądro mikro-Linuksa, systemd-boot, sterownik
NTFS, UEFI Shell i sterownik dotyku. wimboot zachowuje własny podpis
Microsoftu. Wszystko, co USOS uruchamia ze swojej ESP, sprawdza weryfikator
shima. W przeciwieństwie do Ventoya USOS nie łata shima, żeby pominąć
weryfikację. Klucz prywatny nigdy nie trafia do repozytorium.

**Dodanie klucza, raz na komputer.** Trzy sposoby, od najprostszego:

1. **USOS sam zapisuje klucz**, gdy Secure Boot jest wyłączony albo płyta
   jest w trybie Setup Mode. Ekran główny USOS to proponuje, prosi
   o potwierdzenie, zapisuje certyfikat w `MokList` i odczytuje go z powrotem.
2. **MokManager** przy włączonym Secure Boot: shim pokazuje „Verification
   failed”, potem „Enroll key from disk” -> `USOS_ESP` -> `USOS-KEY.cer`.
   Bez hasła.
3. Żądanie MokNew z hasłem, z wiersza poleceń instalatora (dla
   zaawansowanych).

**Dlaczego bezpośredni zapis jest uczciwy.** `MokList` to zwykła zmienna
nieulotna pod GUID shima, a nie zmienna uwierzytelniana. Shim ufa jej tylko
wtedy, gdy ma dostęp z usług rozruchowych i **nie** ma dostępu w czasie
działania systemu, a taką zmienną można utworzyć wyłącznie przed startem
systemu, czyli z ustawień firmware, z programu uruchamianego przed systemem
albo z MokManagera. Sam MokManager dodaje klucz tym samym wywołaniem
`SetVariable`. USOS robi to tylko wtedy, gdy uruchomił go shim, a Secure
Boot **nie** jest egzekwowany; nigdy przy `SecureBoot = 1`. Przy wyłączonym
Secure Boot każdy, kto ma dostęp do klawiatury, i tak może uruchomić
dowolny kod, więc nie powstaje nowa ścieżka zaufania. Po zapisie USOS
ponownie czyta zmienną i sprawdza atrybuty oraz obecność certyfikatu
([secure-boot-usos.md](secure-boot-usos.md), sekcja „Saving the key without
MokManager”).

X470 pokazał, dlaczego Setup Mode ma znaczenie: płyta nie miała klucza
platformy (PK), a pierwsza wersja warunku odmawiała w tym stanie propozycji
zapisu. Po poprawce klucz trafił prosto do MokList z trybu Setup Mode,
a shim uruchomił potem USOS bez MokManagera (potwierdzone 2026-09-24,
build B260924-202302).

**Czego jeszcze nie zabezpieczono** ([secure-boot-usos.md](secure-boot-usos.md),
[release-notes-1.0.md](release-notes-1.0.md#secure-boot)):

- Łańcuch zaufania kończy się na jądrze mikro-Linuksa. Initramfs i wiersz
  poleceń jądra nie są weryfikowane, a jądro działa bez lockdown. Osoba
  z fizycznym dostępem może więc użyć jądra podpisanego przez USOS do
  uruchomienia dowolnego kodu na komputerze, który ufa kluczowi USOS.
  Zamknięcie tej luki wymaga jądra z wymuszonym lockdown w podpisanym
  zunifikowanym obrazie jądra (planowane, ROADMAP N6).
- Ścieżki, które muszą uruchamiać niezweryfikowany stary kod, celowo nie są
  podpisane i wymagają wyłączenia Secure Boot: UefiSeven i dyspozytor Int10
  (Windows 7, Vista), CSMWrap oraz pakiet XP.
- UEFI Shell startuje pod Secure Boot, ale nie potrafi uruchamiać narzędzi
  `.efi`.
- Reset NVRAM usuwa dodany klucz.
- Jak każdy współczesny shim dystrybucji, shim przy pierwszym starcie
  z Secure Boot zapisuje zmienną `SbatLevel`, co na tym komputerze unieważnia
  bardzo stare buildy GRUB.

---

## 11. Dalsza lektura

Notatki projektowe:

- [design/win7-vista-no-csm.md](design/win7-vista-no-csm.md): shim Int10h,
  dyspozytor, kierowanie VGA i wyniki X470 dla Windows 7 i Visty (po
  angielsku)
- [design/csmwrap-integration.md](design/csmwrap-integration.md): CSMWrap
  dla XP i Visty, ESP na dysku docelowym, Vista w trybie BIOS (po angielsku)
- [design/linux-iso-boot.md](design/linux-iso-boot.md): ISO Linuksa z NTFS
  i przekaźnik Secure Boot (po angielsku)
- [design/nt5-uefi-family.md](design/nt5-uefi-family.md): Windows 2000,
  Server 2003 i XP x64 na UEFI
- [design/refactor-os-pipeline.md](design/refactor-os-pipeline.md)
  i [design/answer-file-generator.md](design/answer-file-generator.md):
  pipeline dla poszczególnych systemów i profile odpowiedzi

Badania i raporty:

- [research/csmwrap.md](research/csmwrap.md): jak działa CSMWrap, licencja
  i cichy build (po angielsku)
- [research/win98-feasibility.md](research/win98-feasibility.md): Windows 9x
  na nowoczesnym sprzęcie
- [secure-boot-usos.md](secure-boot-usos.md): łańcuch shim i MOK,
  przechowywanie klucza, dodawanie klucza (po angielsku)
- [windows-xp-uefi-csm-pae-2026-09-21.md](windows-xp-uefi-csm-pae-2026-09-21.md)
  i [windows-xp-driver-integration-2026-09-21.md](windows-xp-driver-integration-2026-09-21.md):
  pakiet XP, sterowniki i PAE (po angielsku)
- [nt52-2003-xp64-2026-09-27.md](nt52-2003-xp64-2026-09-27.md)
  i [nt52-usb3-2026-09-27.md](nt52-usb3-2026-09-27.md): NT 5.2, STOP 0xA5,
  USB (po angielsku)
- [windows-vista-community-usb-2026-09-20.md](windows-vista-community-usb-2026-09-20.md),
  [windows-vista-usb-install-2026-09-21.md](windows-vista-usb-install-2026-09-21.md)
  i [windows-vista-existing-esp-2026-09-26.md](windows-vista-existing-esp-2026-09-26.md):
  ścieżka USB 3 Visty i tryb testowy (po angielsku)
- [windows7-uefi.md](windows7-uefi.md),
  [windows7-x470-starting-windows.md](windows7-x470-starting-windows.md)
  i [windows7-int10-return-2026-09-20.md](windows7-int10-return-2026-09-20.md):
  historia zawieszenia Windows 7 na „Uruchamianie systemu Windows”
- [release-notes-1.0.md](release-notes-1.0.md) i [ROADMAP.md](ROADMAP.md):
  co przetestowano, znane problemy i dalsze plany
- [../ARCHITECTURE.md](../ARCHITECTURE.md), [../BOOT_FLOW.md](../BOOT_FLOW.md)
  i [../MEDIA_LAYOUT.md](../MEDIA_LAYOUT.md): ogólna budowa projektu
