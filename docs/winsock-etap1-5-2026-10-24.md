<!-- Copyright (C) 2026 Maksymilian and the USOS Authors
SPDX-License-Identifier: GPL-3.0-or-later -->

# Win16 Winsock stage 1.5

This extends the accepted stage1 in the same isolated worktree. No merge,
payload deployment or X470 test is part of this change.

The three linker response files now give explicit constant module names and
descriptions: `USOS Winsock 1.1 Win16`, `USOS TESTLOAD Win16`, and
`USOS GETHTTP Win16`. The binary NE tables are checked, not rewritten after
linking. `LibMain` remains the private DLL initialization function; removing
its `__export` leaves only the Winsock1.1 ABI and WEP in the export table.

GETHTTP calls `GetWinFlags()` and logs all32 bits plus the decoded actual
Windows mode. The supplied `WIN /S` argument alone is not evidence of mode.
It also logs WSAStartup's system-status text identifying the configuration
source, so an emergency fallback cannot masquerade as a DHCP configuration.

## DOS DHCP and addressing

Before queue attachment, the provider reads `C:\NET\MTCP.CFG`, written by
the DOS DHCP client started by NETSTART. It parses IPADDR, NETMASK, GATEWAY,
and the first NAMESERVER, with case-insensitive keys, spaces/tabs, CRLF,
comments and unrelated mTCP fields. A valid complete lease replaces all four
values together. Subnet comparisons use that mask; remote traffic resolves
that gateway rather than a compiled-in router.

Input is bounded to8192 bytes and159 characters per line. Missing, partial,
malformed or duplicate essential fields reject the whole candidate. Masks
must be contiguous, the local address a host address, and a nonzero router
must be on-link. There is no DHCP client in the DLL. The earlier QEMU
10.0.2.15/24, gateway10.0.2.2 and DNS10.0.2.3 remain an explicit emergency
fallback, identified in `szSystemStatus`. The parser is OS-independent C89
and is tested against complete, partial, invalid and nondefault LAN leases.

## Queue opt-in

The default driver and NET_FILES remain unchanged. Build the experimental
binary explicitly with `build_dos_network.build_usospkt_queue`; put its
`USOSPKTQ.COM` beside the normal `USOSPKT.COM` in `C:\NET`. For Win3.1/WfW,
before the existing NETSTART call:

```dos
SET USOSPKT_QUEUE=1
CALL C:\NET\NETSTART.BAT
```

NETSTART chooses `USOSPKTQ.COM /Q 0x60` only for that explicit value. If the
optional file is absent, it logs the missing component and skips DHCP; it
does not silently load a different driver. An unset variable keeps the
existing `USOSPKT.COM 0x60` path, without /Q. No binary is renamed or replaced
to select the experimental driver. The existing Windows3.x/WfW startup
script already calls NETSTART before WIN, so this needs no alternate boot
flow. This change does not package or install the optional driver by default.

## Acceptance and reproduction

The VM harness continues to use the original USOS preparation guest and
installer. Its own serial init wrapper now waits for process completion;
it does not call the historical process-polling install wrapper. A single
Windows3.1 PL installation provides a `base` snapshot. Every application
test uses a new qcow2 overlay and fresh logs/MTCP.CFG. DOS DHCP runs again
before Windows in every networked case. A custom user-network subnet in
the GETHTTP case demonstrates that the QEMU constants are insufficient.

Run the same prepare/install/test modes in
`tools/tests/legacy_bios/run_win16_testload_qemu.py`, supplying scratch
`--out`, read-only dependency `--build-root`, and `--qemu`. Test cases are
queue, nodriver, nodll, legacy (default driver), and gethttp. For the latter,
use `--netdev user,id=net0,net=172.31.8.0/25,host=172.31.8.2,dhcpstart=172.31.8.15,dns=172.31.8.3`.
The verdict requires serial application completion, valid DOS DHCP evidence,
and for HTTP an actual STANDARD mode, configuration-file source, HTTP200 and
the exact advertised response-body length. Preserve logs/verdicts/PCAP and
remove owned images afterwards. The task report records actual results.

The deterministic socket peer separately tests a /23 LAN with DNS across
the /24 boundary, exercising the configured mask as well as the gateway.

Actual final results (2026-10-24, QEMU only): 76/76 host tests; all five VM
cases PASS, each returned from Windows to DOS. The queue and missing-DLL
controls, default-driver control, and HTTP case all obtained fresh DOS DHCP
leases. The driver-absent control correctly skipped network startup.
TESTLOAD returned WSAStartup0 by name and ordinal115 with the queue; the
missing/default driver gave10091; missing DLL gave load2 without a dialog.
GETHTTP logged `GetWinFlags=0x00000419 mode=STANDARD`, file configuration,
DNS/connect success and HTTP/1.1 200. The response is98181 bytes, SHA256
`dfea83d3b074da21e8a1cab544db59729eb09e974e341583889187da456c5e60`.
Its lease was172.31.8.15, mask255.255.255.128, router172.31.8.2,
DNS172.31.8.3. The exact response body matched Content-Length.

The new initial installation was interrupted by an insufficient75-second
experiment limit; restarting Setup against its partial directory encountered
an in-use TIMER.DRV. That partial directory was preserved under another name
on the same disposable disk, and the original USOS Setup completed with a
clean WINDOWS destination and an actual serial completion notification after
menu creation/cache flush. No new disk or reformat was used. All DLL tests
then used the one completed `base` snapshot and independent overlays. No
installation was repeated to test a DLL change.

## References and limits

- [Open Watcom linker guide](https://open-watcom.github.io/open-watcom-v2-wikidocs/lguide.html):
  explicit description/modname and the relationship between `__export` and
  a public DLL entry.
- Public Windows3 API `GetWinFlags`, with constants/signature supplied by
  the pinned Open Watcom Windows headers.
- The pinned mTCP package's public configuration text and actual DOS DHCP
  output; the parser and TCP/IP implementation remain our own code.

QEMU Intel82576/Win3.1 STANDARD acceptance does not establish X470/I211,
WfW386-enhanced mode, arbitrary hardware LANs, async APIs or browser support.

## Opt-in integration (test/x470-98se-qemu, 2026-10-24)

Answer profile option `dos_winsock` ("Winsock (eksperymentalny)", editor
row only for Windows 3.1 / 3.11 / WfW 3.11, default off) writes
`winsock=yes` into DOS.INI. Off writes no line, so DOS.INI, every file in
`EFI\USOS\dos-native\msdos` and everything an install stages stay as
before. The Codex change of `network_start.cmd` was reverted: the default
NETSTART.BAT is again the X470-proven text, and the queue text lives in
`network_start_queue.cmd`. The opt-in files are built into their own ESP
folder `EFI\USOS\dos-native\winsock16` (WINSOCK.DLL, GETHTTP.EXE,
TESTLOAD.EXE, USOSPKTQ.COM, NETSTART.BAT, WINSOCK.TXT) by
`build_win16_winsock.build_payload` (pinned Open Watcom, from
`build_dos_native_support.py`).

With the option on, `dos_csmwrap_target.sh` calls
`dos_winsock_apply` (tools/dos_win3_menu.sh) for 3.1 / 3.11 / WfW only:

- `C:\NET\WIN16`: GETHTTP.EXE, TESTLOAD.EXE, WINSOCK.DLL, WINSOCK.TXT,
  STAGE.LOG; `C:\NET\USOSPKTQ.COM`, written before the first DOS boot.
- `C:\USOSDOS\NETSTART.BAT` = the queue variant (INSTALL.BAT copies it to
  `C:\NET`); `set USOSPKT_QUEUE=1` before the NETSTART call in W3AUTO.
- WINMENU.BAT (after `:ini_done`): WINSOCK.DLL into `C:\WINDOWS` only if
  none is there; the result goes into `C:\NET\WIN16\STAGE.LOG`.
- SETUP.INF: the icon "USOS Winsock test (GETHTTP)" with
  `C:\NET\WIN16\GETHTTP.EXE` in the Main group (the `[progman.groups]`
  entry marked `,1`, group3 in 3.1 / 3.11 / WfW 3.11). A group of its own
  does not work: Setup ignored an added `group9` entry and created only
  its own four groups (QEMU, 3.1 PL). Without a Main group in the INF:
  File > Run `C:\NET\WIN16\GETHTTP.EXE`.

GETHTTP now writes `C:\NET\WIN16\GETHTTP.LOG` and `.RSP`. It leaves
Windows only with `/EXIT` (test harnesses). Started from the icon, it
shows a message box: "OK: HTTP 200" or "FAILED".

Tests: `tools/tests/test_win16_winsock_option.py` checks that off is
byte-identical and that on stages the files above. Flow VM:
`tools/tests/legacy_bios/run_win16_winsock_flow_qemu.py` (prepare /
install / show / test). The test copies no file into the installed system.

QEMU only (2026-10-24; X470 not tested). Fresh MS-DOS 6.22 + Windows 3.1 PL
through dos_csmwrap_target.sh -> INSTALL.BAT -> batch Setup -> WINMENU.BAT,
SeaBIOS without CSMWrap, igb, Polish DOS.INI with `winsock=yes`; the test
copies nothing into the system:
- staging: WINSOCK.DLL in C:\WINDOWS = the built file (sha 05f7d622...),
  STAGE.LOG "copied to C:\WINDOWS", `set USOSPKT_QUEUE=1` in AUTOEXEC.BAT,
  queue NETSTART.BAT, USOSPKTQ.COM, default USOSPKT.COM unchanged (8157 B,
  98cfdf5a...); the icon in Grupa glowna (GRUPAGDD.GRP, screenshot).
- GETHTTP from C:\NET\WIN16 (/EXIT): `mode=STANDARD`, config from
  C:\NET\MTCP.CFG (DOS DHCP lease 172.31.8.15/25 on a non-default QEMU
  subnet), DNS OK, connect OK, `HTTP/1.1 200 OK`, 100860 bytes,
  body = Content-Length. Run twice (installs 1 and 2) with the same result.
- First install: Setup ignored a new `group9` group, so the icon now goes
  into the Main group. BusyBox awk counts the CP852 group name as UTF-8,
  so the Main group is found with index() only.

### Start mode with the Winsock profile (2026-10-25)

With `winsock=yes` on Windows 3.1 and 3.11 (not WfW 3.11, which already
starts every item in 386 enhanced mode; not 3.0, which gets no Winsock),
`dos_winsock_enhanced` (tools/dos_win3_menu.sh) makes 386 enhanced mode
the default:
- W3CONFIG.SYS / .CSM: `menudefault=WIN386`, item WIN386 "<product> - 386
  enhanced mode (default)" (`dos.menu.wfw_enhanced`), item WINSTD
  "<product> - standard mode (alternative)" (`dos.menu.winsock_standard`).
  The [WIN386] block is unchanged (`WIN.COM /3 /B`, SMARTDRV), i.e. the
  item tested on the X470.
- WINRUN.BAT (WIN typed at the DOS prompt, no arguments): `goto enhanced`
  before the WfW line. `WIN /S` still starts standard mode.
Without the profile nothing changes (standard mode stays the default).

Why: X470, Windows 3.1 PL on MS-DOS 6.22, B261024-210648-46901993. In
standard mode GETHTTP gets HTTP 200, but Netscape 3.04 fails with a GPF at
002A:A404 (MFC `CMapWordToPtr::GetAssocAt` on the static HWND handle map,
an invalid selector in m_pHashTable) followed by a hard freeze, and Opera
3.62 with a GPF at 000D:4D50. In 386 enhanced mode Netscape works. The
standard-mode root cause is not known yet (KRNL286/DOSX with the browsers'
32-bit code, or our DLL's async path under DOSX); the diagnostic DLL now
also logs successful recv/send/select/closesocket/ioctlsocket and the
posted FD_* events (USOS_WS_DIAG) so the next standard-mode crash leaves
a trail in WINSOCK.LOG.
