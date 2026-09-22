USOS — Windows 7 x64: Updates (kolejka SHA-2)
============================================

Wloz tu SAM plik KB4474419*.msu (SHA-2 support dla Win7 SP1 x64).
Kolejka stagingu: SHA-2 Add-Package PRZED Add-Driver (kolejnosc sztywna).

Zachowanie: jesli plik istnieje, startup.cmd loguje i (gdy DISM dostepny
w PE) stosuje Add-Package offline do targetu przed Add-Driver. Jesli pliku
brak — tylko warning, nie fail. Bez unattenda: nie zmienia wyborow
instalacji, tylko DriverPaths/offlineServicing (via usos-unattend-drivers.exe).

Pusty folder = no-op.
