# USOSLOG - silent logger for Windows 9x test installs

`src/platform/bios/win9x/usoslog.c` (GPL-3.0-or-later). Build:
`python tools/build_win9x_support.py --usoslog` (OpenWatcom wcc386 / wlink,
PE 4.00 GUI, no C runtime, no relocations) into `zig-out/win9x-usoslog`
together with USOSDBG.EXE 1.6. Tests: `tools/tests/test_usoslog.py`.
Not staged by the installer: it is copied by hand / by an in-place kit
into `C:\USOS9X` and the Startup folder.

Started from the Startup folder (single instance): a start record at once,
a full snapshot after 3 minutes and then every 5 minutes, appended to
`C:\USOS9X\LOGS\USOSLOG.TXT` (rotated to `USOSLOG.OLD` at 256 KiB). The
sections and the options are listed in the source header.

## Watcher (PROC)

The main thread polls every 250 ms: one Toolhelp32 process snapshot,
diffed by PID; `EnumWindows` (visible top-level windows) on every tick for
2 s after the process set changed, otherwise once a second (without
Toolhelp32, NT 4.0: windows only, every 500 ms). Each event line carries
the wall time with milliseconds and `t+s.ms` since the logger started:

    01:25:34.503 t+1.547 +proc 000043D4 cmd.exe  parent 00006270 python.exe
    01:25:34.503 t+1.547 +window 01020766 class "ConsoleWindowClass" title "..." pid 000043D4 cmd.exe  <- console / DOS box
    01:25:35.748 t+2.781 -proc 000032CC PING.EXE  parent 000043D4 cmd.exe  ran 1250 ms
    01:25:35.748 t+2.781 -window 01020766 class "ConsoleWindowClass" pid 000043D4 cmd.exe  shown 1250 ms  <- console / DOS box

On 9x a console or DOS box is a WinOldAp `tty` window (a Win32 console
program also starts CONAGENT.EXE). A process or window shorter than one
tick can still be missed. At most 1000 event lines per session, then a
counter line in the next PROC section.

## USOSDBG 1.6 additions (in the copied /L output)

- `NIC` / `IRQ` / `PIR` (every run, not only with /F): every network
  controller (class 02h) and the I211 8086:1539: command (bit 10 INTx
  disable), status (bit 3 interrupt status), line / pin, MSI / MSI-X enable,
  the bridges above it; ELCR 4D0h/4D1h and the 8259 masks (`in 21h / A1h`:
  VPICD's virtual view for the system VM, not necessarily the hardware;
  IRR / ISR are not read, OCW3 would need a port write); the `$PIR` table in
  F0000-FFFFF with the NIC's and its bridges' entries marked (`none` when
  the firmware / SeaBIOS has no table). Only reads.
- `WHEEL  C2 ...`: with CSMWrap 3.1.2-usos15 (patch 0020) the USOSMWHL
  record has the last 16 INT 15h AH=C2h calls at +312 (magic `C2RG`,
  count, head, 12-byte entries: AX, BX, ES, caller CS:IP, device ID after
  the call, result), printed oldest first, e.g.
  `C202 rate 200 bx=0600 es=0000 @2000:0100 id0 ok`, then a summary of the
  calls after the last knock (C202 rate 200, 100, 80): resets C201h /
  inits C205h and the caller of the first one. Older CSMWrap:
  `C2 ring: none (CSMWrap before usos15)`. The older WHEEL lines are
  unchanged.

## Compatibility

Static imports: the Windows 95 subset of KERNEL32 / USER32 / ADVAPI32 only
(checked by the build against `USOSLOG_IMPORTS`). Loaded at run time, each
part skipped with a log line when missing: WSOCK32.DLL (Winsock 1.1),
IPHLPAPI.DLL, Toolhelp32.

| part | 95 (OSR2+) | 98 / 98 SE | Me | NT 4.0 | 2000 / XP |
|---|---|---|---|---|---|
| log file, rotation, single instance, start record | yes | yes | yes | yes | yes |
| process list / watcher (Toolhelp32) | yes | yes | yes | windows only | yes |
| mouse metrics, journal hook (`WM_MOUSEWHEEL`) | yes (wheel from 98) | yes | yes | yes | yes |
| USOSDBG /L (USOSKEY / USOSMOUS / SeaBIOS USOSMWHL / PCI) | yes | yes | yes | skipped (Win16 DPMI) | skipped |
| usosnet 0.4 statistics page | n/a (NDIS 5.0 needs 98) | VA, else PA via USOSDBG | as 98 | no | no |
| DNS / TCP / HTTP tests (Winsock 1.1) | with TCP/IP installed | yes | yes | yes | yes |
| IPHLPAPI resolver view and counters | no (registry only) | yes | yes | SP4+ partly | yes |
| network registry | VxD\MSTCP, NetTrans, DHCP | same | same | Tcpip\Parameters | Tcpip\Parameters |

Tested on the Windows 10 dev PC only (NT path, network tests, decoding of
a USOSDBG dump of the usosnet page, the watcher seeing a console window).
Not yet run on 95 / 98 / Me / NT 4.0.
