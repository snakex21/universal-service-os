# R21: świeży normalny przepływ NT 3.51

R18f potwierdził USB i funkcjonalny LAN w zainstalowanym Windows na kolejnych
zachowanych overlay. R21 ma osobno sprawdzić świeżą normalną instalację USOS,
Program Manager i rzeczywiste DHCP/ping/DNS z aktualnym SYS. PS/2 jest jawnie
dozwolone; i8042 sprzętowo obecne. R21 sam nie nadaje USB-only PASS.

Zamrożony cache net2 ma już finalny Greenwich→Monrovia/Casablanca oraz strict
DNS logger ff258. Odtwarzalny build_nt351_r21_cache.py dodaje dokładnie trzy
efektywne wpisy: SYS f39d58fd, jego plik SHA256 oraz helper markera d2c11151
z poprawką87f599b1. Żaden skrypt z cache nie jest podmieniany. Wszystkie832
efektywne wpisy sprawdzono po odczycie wszystkich warstw; inne pliki cache,
EFI i skompresowany bazowy prefiks są identyczne. Nowa warstwa ma pełny trailer.

Cache: `G:\USOS-Kolekcja\_assets\B261020-200536-968CCBE8-nt351-net3`.
Manifesty w `artifacts/nt351-network/r21-cache-manifest.json` i
`r21-plan-manifest.json`. Dokładne piny:

- initrd: f958da5146114f210d5a738a55f8711d56b204c0adcaf0957ebf03e810cb772c
- SYS: f39d58fd923632dacbc577562045015123a9bdfc98c56237090bfcd53c70612a
- helper: d2c1115180d8daeb02421d23920584a95dd8aa082a42c566dec1e9ff836e1096
- logger: ff2585043a882065f9598628ac31afdaba356a3d91f3e55d93a36e313e3983b7
- EFI: 3dd8b4d2b8e42fd22859c82383aa3ecfaa5c5a91779591b89c4b32e7ea3ae90f

Builder source commit998a0bc5; helper source SHAe8e825c48f1392a08e55d498b76c8f3c9b1e36f490b2943d85c45cd8f6f5b678.
PE helpera3.10/i386,50importów identycznych z poprzednim zgodnym cached
helperem. Dwa testy warstw, jeden test realnego read_text/gate z czterema
przypadkami i mutacją oraz10testów render/staging/UTC przeszły. Actual matrix
ec60b10c preflight sprawdził system/capacity/input i rzeczywisty pin kolektora
f39/17024B. To host preflight, nie wynik Windows.

Plan `artifacts/coverage/nt351-fresh-network-plan-r21.json` ma jeden tag
`r21-nt351-fresh-network-ps2`,4GiB target,ps2_input=true,usb_only_input=false,
igb oraz ograniczony capture, success/failure collector i interaktywny endpoint.
Plan SHA5cc8c614c9b1c1b8bb4122e18b784f014cd38e50611a999789888641814fde11.
Media archive24adda13744589cacebf6a75e21bf8999465b5637235ce55b0cf3a7578aa7975,
ISO b9d0e8417c1f502d1de22c249401b593be2a7fe59524b27a624dfa8dedaa099c.
Root przejmuje start po zwykłym RAM guardzie, retencję i pasywne endpointy;
ten worktree nie uruchamia drugiej kopii. NT35/R20/R18f i ich binaria/wyniki
pozostają bez zmian. Ulepszenia IRQ/timera są poza tą zamrożoną próbą.
