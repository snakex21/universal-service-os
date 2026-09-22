# SliTaz Live z ISO w BIOS

Pierwszy profil Linux Live uruchamia oryginalny 32-bitowy obraz SliTaz Cooking.
Ścieżka w menu: **Linux → Other Linux → slitaz-cooking.iso → Automatic**.
Obraz znajduje się w `Systems/Linux/Other Linux/Images` na partycji DATA.
Inne dystrybucje nie zostały włączone przez tę zmianę. Ten backend wymaga BIOS-u.

## Obraz i sposób startu

Oficjalne źródło: [SliTaz Downloads](https://www.slitaz.org/en/get/).
ISO pobrano 13 września 2026 z oficjalnego mirroru; menu obrazu identyfikuje
wydanie jako `5.0-RC4 20260525`, a jądro jako `3.16.55-slitaz`.
Rozmiar: 61 849 600 bajtów. MD5 producenta zweryfikowane:
`fbd81b8d800f314976e9a25a57c33ee6`. Lokalna SHA-256:
`492b4d846a86443f22a2c58d50e213af9778a979bad2130d614a4efac30df7ee`.
Metadane pobrania są obok lokalnego ISO w `test-images/linux`.

Core odczytuje ISO9660 bezpośrednio z NTFS DATA. Ładuje `boot/bzImage` oraz
cztery warstwy RAM w kolejności `rootfs4.gz`, `rootfs3.gz`, `rootfs2.gz`,
`rootfs1.gz`. Sprawdza granice plików, nagłówek jądra i dostępność pamięci E820.
Przekazuje sprzęt przez protokół startowy Linuksa i uruchamia jego wejście
32-bitowe. Nie uruchamia pośredniego micro-Linux ani dodatkowego bootloadera.
Nie zmienia źródłowego ISO i nie przygotowuje partycji docelowej.

Parametry startu: `root=/dev/null rw lang=en_US kmap=us autologin noswap`.
Pulpit i jego dane pracują w RAM. `noswap` wyłącza automatyczne użycie dyskowych
partycji swap; zram wewnątrz dystrybucji nadal może używać pamięci RAM.
Postęp ładowania odpowiada pięciu odczytanym plikom: jądru i czterem warstwom.
Oryginalny obraz dobiera pełny pulpit od 384 MiB; test USOS używa 2 GiB RAM.

## Instalator

Oryginalny instalator jest w **Applications → System → SliTaz Installer**.
Jako źródło wybiera się ISO i ten sam plik na USOS_DATA. Nowy dysk można
przygotować w dołączonym GParted. Partycjonowanie i właściwą instalację
wykonuje użytkownik w narzędziach SliTaza.

Wykryte ograniczenie tazinst 115: przy instalacji MBR z `bootloader=auto`
wybiera GRUB Legacy i zapisuje bieżące `(hdN,M)` oraz `/dev/sdXN`.
Test z dwoma dyskami IDE (USOS jako pierwszy, cel jako drugi) zakończył się
instalacją, ale po usunięciu pierwszego dysku wystąpił GRUB Error 21.
Nie należy traktować samego kodu zakończenia instalatora jako dowodu startu
po odłączeniu nośnika. W teście odpowiadającym użyciu pendrive’a USOS był
urządzeniem USB, a docelowy dysk IDE był `/dev/sda`. Oryginalny tazinst 115
z `bootloader=auto` zakończył instalację kodem 0. Po wyłączeniu VM i usunięciu
urządzenia USB system uruchomił się z dysku, a logowanie doprowadziło do
pełnego pulpitu. Instalator i wygenerowany bootloader nie były poprawiane.

## Walidacja

- Build, kontrola rozmiaru Core i pełny zestaw automatycznych testów: PASS.
- Parametry Live i rozdzielenie od komend micro-Linux: test jednostkowy.
- Ograniczenie backendu do Other Linux / ISO / BIOS: test jednostkowy.
- Start pulpitu z menu USOS w QEMU, CPU Athlon, 2 GiB RAM: PASS.
- Otwarcie oryginalnego graficznego instalatora: PASS.
- Instalacja z USB na pustym wirtualnym dysku IDE 2 GiB: PASS, kod 0.
- Start z tego dysku bez podłączonego USOS i logowanie do pulpitu: PASS.
- Fizyczny Kingston: aktualizacja bez formatowania, weryfikacja 78 plików
  ESP i zapis obrazu ISO z kontrolą SHA-256: PASS.
- Start Live na fizycznym sprzęcie: użytkownik potwierdził 13 września 2026
  uruchomienie pulpitu SliTaz z motywem pająka. Instalacja na fizycznym dysku
  nie była częścią tego potwierdzenia.

Build: `B260913-123045-0F2F0066`. Dowody lokalne: `zig-out/linux-live-work`
(log operacji Kingston, konfiguracja VM bez USB, zapis instalacji) oraz
`zig-out/win3-work/slitaz-usb-desktop-ready.png` i
`zig-out/win3-work/slitaz-installed-desktop.png`.

Core ma stały slot 256 KiB. Aby zmieścić nowy loader, kodowanie ikon pomija
zbędny bajt alfa w ciągach nieprzezroczystych pikseli. Zdekodowane piksele są
identyczne z poprzednimi: wszystkie 22 obrazy sprawdzone bajt po bajcie,
łącznie z kanałem alfa. Rozdzielczość i wygląd ikon pozostają takie same.
