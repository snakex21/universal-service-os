# Zasady projektu Universal Service OS

1. Jeden plik = jedna odpowiedzialność. Pliki mają być małe i łatwe do wymiany.
2. Moduły nie mogą znać szczegółów innych warstw bez potrzeby. Zależności idą przez małe interfejsy.
3. Każda funkcja i moduł dostają testy jednostkowe; integracyjne są dodawane tam, gdzie łączą się warstwy.
4. System ma własny lekki autotest startowy. Ten sam kod testowy ma być używany również podczas rozwoju, kiedy to możliwe.
5. Po każdej zmianie projekt musi przechodzić pełny build i testy. Nie uznajemy zmiany za gotową bez sprawdzenia.
6. Bez TODO, pustych metod, stubów i atrap udających działającą implementację.
7. Najpierw implementacja i testy, potem komentarze i dokumentacja stanu faktycznego.
8. Priorytety techniczne: prostota > wydajność > przenośność.
9. Czas startu jest krytyczny: bez ciężkiego runtime, bez niepotrzebnych alokacji i bez inicjalizacji modułów, które nie są potrzebne do pokazania pierwszego ekranu.
10. GUI ma być lekkie, czytelne i możliwe do obsługi klawiaturą oraz myszą. Efekty wizualne nie mogą opóźniać startu ani komplikować kodu.
11. Kod wspólny nie może zależeć od x86, ARM64, BIOS ani UEFI.
12. Kompatybilność DOS jest warstwą x86, a nie fundamentem całego systemu.
