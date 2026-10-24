<!-- Copyright (C) 2026 Maksymilian and the USOS Authors
SPDX-License-Identifier: GPL-3.0-or-later -->

# Win16 Winsock stage 1 — QEMU only

Windows 3.1 PL, STANDARD (`WIN /S`), QEMU Intel 82576 (`-device igb`):
`GETHTTP.EXE` fetched `http://68k.news/` through our `WINSOCK.DLL` and the
queue variant of USOSPKT. HTTP/1.1 200 OK; saved response 94,532 bytes,
including 94,285 body bytes, exactly the server's Content-Length.
Response SHA256: `f631d977b06f5e90efc5d21d27a57edb58a0fd1050cb68debddeecc88cbc4133`.

This is not an X470/I211 result, a full Winsock conformance result, or an
enhanced-mode result. The stage uses the QEMU user-network configuration:
10.0.2.15/24, gateway 10.0.2.2, DNS 10.0.2.3. DHCP remains in DOS NETSTART,
outside the DLL. There is no installer/menu/payload integration.

## Changes

- The linker emits uppercase NE export names directly; no post-link patch.
  Exported entry points establish the DLL's data segment, and the compiler
  is told that its caller's stack is not its data segment (`-zu`).
- TESTLOAD calls WSAStartup by name and ordinal 115, with cleanup between
  the calls. WSAStartup returns its actual startup error, rather than -1.
  SetErrorMode suppresses the missing-DLL dialog in the negative control.
- GlobalDosAlloc supplies a DOS block and its protected selector in STANDARD
  mode. The real-mode simulation receives that selector as ES, not a real
  segment. Queue metadata is little endian, separate from network headers.
- Queue MAC publication follows NIC reset/MAC discovery. The previous code
  published zeroes, causing ARP responses to target 00:00:00:00:00:00 and be
  rejected by the NIC. PCAP and the shared-header diagnostic exposed this.
- The queue kick can poll RX without a reflected timer/PCI interrupt, while
  honoring the ISR busy exclusion and preserving the saved interrupt frame.
  Each receive attempt polls; an arbitrary idle-loop count is not a timer.
- IPv4 parsing accepts an omitted payload-pointer output. DNS dispatch used
  this form and previously discarded every reply. Socket addresses use the
  Winsock byte order, and remote IP packets resolve the local gateway MAC.
- The blocking receiver stops draining when its socket has unread data and
  preserves payload accompanying FIN. The deterministic peer test checks
  DNS, gateway routing, 5,157 exact data bytes in multiple segments and EOF.

## Default driver invariant

Reference: integration `922d1171744506a82857f9f2b180d1b9a3ce7b13`, excluding
`6974778d`. The latter commit is not an ancestor of this branch.

| Artifact | File bytes | Resident bytes, aligned reference PSP | SHA256 |
|---|---:|---:|---|
| default USOSPKT.COM | 8,157 | 43,264 | `98cfdf5ad6c8d7c805927d7f7247ef326ca36414c3622189a0a238c16ae933eb` |
| experimental USOSPKTQ.COM with /Q | 9,477 | 84,384 | `756cd5a10827ae0b85db7c08436c1b886196c5a2bc09872e88fbce825dd93276` |

The original `usospkt.S` is restored exactly. Queue code resides only in
`usospktq.S`, built explicitly with `build_usospkt_queue`. It is absent from
NET_FILES and the default binary. For the VM overlay only, USOSPKTQ is copied
as C:\NET\USOSPKT.COM and NETSTART invokes `USOSPKT.COM /Q 0x60`.
Experimental resident size without /Q is 44,672 bytes; it is not the default
driver. Actual DOS paragraph alignment can change the resident allocation.

## Verification

One fresh installation through `run_w9x_micro_linux_qemu.install` and the
production `dos_csmwrap_target.sh` → INSTALL.BAT → W3START/W3AUTO flow.
Newer donor INSTALL.BAT was overlaid with the committed integration-base
version, not rewritten. After installation: internal `base` snapshot and
file-backed qcow2 overlays only. No reinstall. No private FAT formatter,
boot sector, replacement CONFIG/AUTOEXEC, WIN.INI edits, or ADD852 deletion.
The overlay keeps the generated start menu and adds only the test application
argument, serial completion marker and queue selection in NETSTART.

All final VM cases use the same non-diagnostic DLL and exit Windows:

| Case | Fresh log evidence | Result |
|---|---|---|
| TESTLOAD + /Q | `name=0 ordinal=0`, 1.1, correct provider description | PASS |
| TESTLOAD without driver | `name=10091 ordinal=10091` | PASS |
| TESTLOAD without DLL | `USOS WINSOCK FAIL err=load:2` | PASS |
| GETHTTP + /Q | DNS, connect, HTTP 200, saved response and exact Content-Length | PASS |

54 host tests pass: default identity/resident size, original packet driver,
queue transport, exact NE names/absolute nonresident-table offsets, portable
TCP/IP and the deterministic blocking peer. The existing no-Trumpet-files
guard remains. The historical DeepSeek reports describe earlier, superseded
experiments; `tools/win16_disk.py` is removed and their private paths redacted.
No Trumpet binary or implementation was copied. Temporary `tr30` was removed.

## Reproduce

Set USOS_ZIG and USOS_WATCOM to local toolchains. Build artifacts stay under
zig-out/win16. Use `tools/build_win16_winsock.py --strict`, then explicitly
build USOSPKTQ with `build_dos_network.build_usospkt_queue`.
`USOS_WS_DIAG=1` optionally enables the transport log; final verification
used `USOS_WS_DIAG=0`. Host tests are the five files listed in the task's
report; compiler caches and pytest basetemp are local to the checkout.

The VM harness is `tools/tests/legacy_bios/run_win16_testload_qemu.py`:
`prepare` requires --dos-iso/--win-iso, then `install`, then `test --case`
queue/nodriver/nodll/gethttp. Supply --build-root (read-only build dependencies),
--qemu and a scratch --out on the VM drive. Repeated cases require a new
--tag. Read the per-case inputs, verdict JSON, exported logs and PCAP.
Delete VM images after preserving evidence. Never point it at physical disks.

## Public interface references

- [DPMI 0300h, selector:offset of the real-mode register structure](https://www.delorie.com/djgpp/doc/dpmi/api/310300.html).
- [DPMI 0002h, returned descriptors and ownership rules](https://www.delorie.com/djgpp/doc/dpmi/api/310002.html).
- [Open Watcom linker guide, Windows DLL/export directives](https://open-watcom.github.io/open-watcom-v2-wikidocs/lguide.html).

Out of scope and untested: X470/I211, arbitrary LAN configuration, DHCP in
the DLL, 386 enhanced mode, select/async APIs, browsers and deployment.
