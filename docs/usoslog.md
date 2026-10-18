# USOSLOG - silent logger for Windows 9x test installs

`src/platform/bios/win9x/usoslog.c` (GPL-3.0-or-later). Build:
`python tools/build_win9x_support.py --usoslog` (OpenWatcom wcc386 / wlink,
PE 4.00 GUI, no C runtime, no relocations) into `zig-out/win9x-usoslog`
together with USOSDBG.EXE 1.5. Tests: `tools/tests/test_usoslog.py`.
Not staged by the installer: it is copied by hand / by an in-place kit
into `C:\USOS9X` and the Startup folder.

Started from the Startup folder (single instance): a start record at once,
a full snapshot after 3 minutes and then every 5 minutes, appended to
`C:\USOS9X\LOGS\USOSLOG.TXT` (rotated to `USOSLOG.OLD` at 256 KiB). The
sections and the options are listed in the source header.

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
