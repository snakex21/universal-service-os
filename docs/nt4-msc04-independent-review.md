# Niezależny read-only review NT4 MSC04

Reviewuje zamknięty commit62073133 i `artifacts/nt4-msc/evaluation.json`
SHA256 `dad5a4945a94f7331a35851eab8d4108a05135d928e7e1dbaca869f9785bf542`
w `nt4-usb-hid`. Bez zmian tego WT, aktywnych obrazów ani logów combo01.

Wniosek: brak blokera dla osobnego installed MSC/FAT16 PASS. Sprawdzono
wszystkie16 hashy wyników/PNG, źródła boot/fixture zgodne z preflight i
sam frozen43648B SYS `3139522926f054946b280c14c962593062817a0ca71170a5aeeb8551a6fab2a1`.
Taką samą sumę ma actual stopped readback. Nie przebudowano sterownika/hubów.

Kod obserwatora tworzy ROUNDTRIP przez CREATE_NEW, WriteFile (pełna długość),
FlushFileBuffers, udane CloseHandle i nowe ReadFile/exact compare. Faza
REPLUG niczego nie zapisuje: ponownie odczytuje HOTPLUG i ROUNDTRIP. Trzy
jednorazowo uzbrojone futures/COM1 stages STARTUP/HOT/REPLUG mają status0.
Polecenie używa trwałego named backendu usabilityhot; device_del/add zmienia
jedynie USB device, z tym samym backend/serial/port. Obrazy Notepad05/09/10/15
pokazują rzeczywisty START/HOTPLUG/ROUNDTRIP. Notepad jest zamknięty w11;
nowy Explorer12 ma tylko D:, nowy14 ponownie D:+E:. Stopped FAT readback
potwierdza ROUNDTRIP SHA256
`003fd2202119eff8ac1e0e241942c8a9ce4ad2465f57339143e3557eb84efe15`.
To silniejszy dowód niż sam obecny plik/status lub QMP device_add.

Native safe-off17, QMP0/errornull, parent cf04 unchanged, actual target
`a6807a432891b47ea20a4eb1650fc981ae8b7fdade6cec138d9ef03818b1de5c`.
SYSTEM identyczny dotyczy stagingu; normalne zmiany runtime są jawnie
odnotowane. MSC03/timeout bez nativeShutdown pozostaje ujemnym wynikiem.

Granice są uczciwe: BIOS installed COW, PS/2/i8042prtStart1, dwa64MiB
FAT16 i mały plik. Istniejący Explorer nie odświeża listy automatycznie;
owe okno potrzebne, auto-refresh niePASS. Nie testowano Winver w MSC04,
nowego HID na313952, LAN, freshAUTO ani fizycznego X470. Zapis wykonała
własna aplikacja Win32, natywny Notepad potwierdza odczyt; kopiowanie plików
przez Explorer, inne filesystemy/duże pliki/power-loss nie są kwalifikowane.
Nie ma podstaw do łączenia osobnego HID2d455 oraz MSC313952 w jeden PASS.
