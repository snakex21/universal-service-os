# MiniOS WIM final07 — firmware i minimum RAM (QEMU)

Wszystkie 11 końcowych prób firmware przeszły zastosowanie WIM oraz niezależną kontrolę Windows: dane/strumienie, metadane, surowe deskryptory zabezpieczeń i `chkdsk` tylko do odczytu z kodem 0. Źródłowe obrazy bazowe pozostały identyczne.

| Próba | Format | RAM VM | CPU | Aplikacja / Windows |
|---|---|---:|---|---|
| fw07-large-x64-xpress-64 | GPT | 64 MiB | max | PASS / PASS |
| fw07-large-ia32-xpress-64 | GPT | 64 MiB | max | PASS / PASS |
| fw07-large-x64-lzx-64 | MBR | 64 MiB | max | PASS / PASS |
| fw07-large-x64-lzms-64 | GPT | 64 MiB | max | PASS / PASS |
| fw07-large-ia32-lzx-64 | MBR | 64 MiB | max | PASS / PASS |
| fw07-large-ia32-lzms-64 | GPT | 64 MiB | max | PASS / PASS |
| fw07-bios-xpress-64 | GPT | 64 MiB | 486 | PASS / PASS |
| fw07-bios-lzx-64 | MBR | 64 MiB | 486 | PASS / PASS |
| fw07-bios-lzms-64 | GPT | 64 MiB | 486 | PASS / PASS |
| fw07-bios-486-xpress-32 | GPT | 32 MiB | 486 | PASS / PASS |
| fw07-bios-pentium-xpress-32 | GPT | 32 MiB | pentium | PASS / PASS |

Sześć prób UEFI zawierało 1208 plików i 20 katalogów, w tym pojedynczy plik 134 217 851 B. Pięć prób BIOS użyło mniejszego własnego zestawu. Wszystkie wejścia i pliki firmware są przypięte SHA256 w sąsiednim JSON.

## Granica RAM dla dużego LZMS non-solid

| UEFI | Najniższy PASS | Następny niższy FAIL | Windows na zwycięskim obrazie |
|---|---:|---:|---|
| x64 | 49 MiB | 48 MiB | PASS, chkdsk 0 |
| ia32 | 48 MiB | 47 MiB | PASS, chkdsk 0 |

Bisekcja użyła 12 świeżych nakładek QCOW2 na niezmienionych bazach. Dolne sąsiednie próby zgłosiły `USOSPREP TERMINAL FAIL stack-allocation` i zakończyły się kodem 35 przed zastosowaniem WIM. Minimum dotyczy tego konkretnego firmware EDK2, QEMU i zestawu LZMS; obejmuje pamięć firmware. Własny budżet programu jest odrębnie zapisany w JSON.

Zamknięty zakres RAM zajmuje 1 606 849 921 B z limitu 2 684 354 560 B. Po bisekcji wyeksportowano wyłącznie dwa zwycięskie obrazy do osobnego zakresu i sprawdzono je w Windows bez ponownego uruchamiania zastosowania WIM. COW, bazy i deskryptory pozostały identyczne przed i po kontroli.

Dowody mają ścieżki względne wobec katalogu tego przebiegu oraz SHA256. Zachowano także nieudaną pierwszą próbę launchera Windows (błędna ścieżka PowerShell; proces nie wystartował). Wszystkie obrazy i logi pozostają zachowane. Brak cleanup, merge, push, deploy i operacji na fizycznych nośnikach.
