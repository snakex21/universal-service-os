# AMD Vermeer: próba naprawy mapowania legacy VGA

Stan: zbudowane i wdrożone, działanie na fizycznej płycie niepotwierdzone.
Build `B260920-160703-CBF2ED7F`.

## Dowód sprzętowy

`zig-out/win7-universal-work/intel-failure-20260920-180057`:
CPUID `00a20f12`, brak LegacyRegion/LegacyRegion2, Int10=0,
pierwsze 16 bajtów C0000=FF, deskryptor reserved, atrybuty 0xF.
MTRRCAP=0x508, MTRR_DEF_TYPE=0xC00, odczyty MSR268/269=0,
SYS_CFG=0x740000. GOP framebuffer=0xD0000000.

SYS_CFG bit18 jest ustawiony, bit19 wyzerowany. Dlatego zero w odczycie
MTRR nie rozstrzyga wartości ukrytych bitów RdMem/WrMem. UefiSeven 1.30
zmienia typ cache na UC, który już jest ustawiony; nie zmienia ukrytego
kierowania odczytów/zapisów AMD. To uzasadnia kontrolowaną próbę w tym
obszarze, ale nie jest dowodem, że naprawa rozwiąże cały rozruch Windows.

## Implementacja

`tools/windows7_amd_shadow.zig`, wywołane przez wrapper przed UefiSeven.
Ograniczenie do fizycznego AuthenticAMD CPUID 00a20f12, bez istniejącego
Int10h i bez obu protokołów LegacyRegion. Wszystkie 16 stron C0000–CFFFF
muszą być reserved i non-runtime, cały zakres musi odczytywać się jako FF.

Wymaga MP Services, pobiera stan każdego aktywnego procesora. Chwilowo
ustawia SYS_CFG bit19, aby odczytać rzeczywiste bity RdMem/WrMem, po czym
przywraca SYS_CFG. Przyjmuje wyłącznie MTRR_DEF_TYPE=0xC00, bit18=1,
bit19=0 oraz rzeczywiste MSR268/269=0. Inny stan zatrzymuje próbę przed
zmianą mapowania i jest zapisany w logu.

Ustawia wyłącznie bity RdMem i WrMem dla C0000–CFFFF (MSR268 i 269,
0x1818181818181818). Typ cache pozostaje UC. Operacje są sekwencyjne na
aktywnych procesorach przez blokujące MP Services. Każdy callback zachowuje
SYS_CFG, MTRR_DEF_TYPE, CR0/CR4 i flagę przerwań, czyści cache i translacje
przy aktualizacji; procesory SMT mogą współdzielić już ustawione rejestry.
Po operacji na wszystkich CPU sprawdza zapis/odczyt/przywrócenie jednego
bajtu w każdej stronie. Dopiero wtedy przekazuje sterowanie UefiSeven.

Przy niepowodzeniu próbuje przywrócić zapisane wartości na wszystkich
aktywnych CPU, raportuje również niepełne cofnięcie i nie uruchamia Windows.
Zmiany dotyczą bieżącej sesji rozruchu, nie flash/NVRAM. Nie zeruje ręcznie
pamięci legacy i nie dodaje `skiperrors` ani `force_fakevesa`.

Log `usos-amd-shadow.log` obok loadera ma wynik PASS/FAIL/STOP/SKIPPED.
UefiSeven pozostaje oryginalną binarką 1.30 i nadal zapisuje własny log.
PASS nowego pomocnika nie oznacza sukcesu uruchomienia Windows.

Podstawa znaczenia bitów:
- AMD64 APM Volume 2, Extended Fixed-Range MTRR Type-Field Encodings, §7.9;
- AMD BKDG, opis MSRC001_0010[MtrrFixDramModEn,MtrrFixDramEn]:
  https://www.amd.com/content/dam/amd/en/documents/archived-tech-docs/programmer-references/42301_15h_Mod_00h-0Fh_BKDG.pdf
- kod coreboot pokazujący odkrywanie/ukrywanie RdMem/WrMem przez SYS_CFG:
  https://github.com/coreboot/coreboot/blob/main/src/cpu/x86/mtrr/mtrr.c
- ABI MP Services:
  https://github.com/tianocore/edk2/blob/master/MdePkg/Include/Protocol/MpService.h

## Weryfikacja i wdrożenie

Kompilacja EFI i aplikacji: exit 0. Testy: 216 Zig, 1 bramki diagnostyki,
4 mechanizmu AMD (w tym cofanie po częściowym błędzie CPU i po błędzie
próby pamięci), 2 self-testy, 54 testy pomocników. Wszystkie OK.
Testy mechanizmu AMD używają atrap; nie wykonują RDMSR/WRMSR na hoście.
Brak VM/E2E. Log: `zig-out/win7-universal-work/build-amd-shadow.log`.

Intel: oba wrappery odczytane po zapisie, SHA-256
`25470C7C20B29C86C9F74C90023412530B1D6D005F806381B1E00B02724B7A1C`.
Kopia: `zig-out/win7-universal-work/intel-before-amd-shadow-20260920-180841`.
BCD, oryginalny loader i partycje zachowane. Kingston: 10 plików EFI/wsparcia
zweryfikowanych po zapisie, `RESULT=PASS`, układ partycji zachowany.
Log: `zig-out/win7-universal-work/update-amd-shadow-usb.log`.
