# USOSPKT - own DOS packet driver for Intel igb NICs (2026-10-23)

Goal: internet in MS-DOS on the X470 Master (Intel I211-AT, PCI 8086:1539,
no firmware CSM; DOS runs through CSMWrap / SeaBIOS). USOS has no DOS
driver for the I211 (Intel never shipped one), so USOS brings its own:
`USOSPKT.COM`, a packet driver (FTP Software Packet Driver Specification
1.11, class 1 DIX Ethernet), plus mTCP 2026-10-10 (GPL-3.0) for DHCP and
the tools.

Status: **QEMU only (82576 `-device igb`, not I211)**: DHCP, PING and HTGET
of http://68k.news PASS in every supported mode (table below). **Not run on
the X470 yet.**

## Files

| file | what |
|---|---|
| `src/platform/bios/msdos/usospkt.S` | the driver (GPL-3.0-or-later, zig cc `.code16`, linked at 0100h with `com.ld` like USOSKBC) |
| `src/platform/bios/msdos/network_start.cmd` | `C:\NET\NETSTART.BAT`: load the driver, DHCP, one status line |
| `tools/build_dos_network.py` | builds USOSPKT.COM, stages mTCP + NETSTART.BAT + MTCP.DEF + MTCP.TXT + MTCPSRC.ZIP into `zig-out/dos-native/msdos` (called by `build_dos_native_support.py`) |
| `tools/vendor/mtcp/2026-10-10/` | pinned unmodified mTCP binaries (DHCP PING HTGET FTP TELNET SNTP NC DNSTEST PKTTOOL), COPYING.TXT, README.TXT, SOURCES.txt, manifest.json (sha256); the source zip `mTCP-src_2026-10-10.zip` is pinned there too but **not tracked** (`tools/vendor/**/*.zip` is ignored, like HimemX's source zip) - the build stops with the URL and hash when it is missing |
| `src/platform/bios/msdos/install.cmd` | INSTALL.BAT: MS-DOS-only install copies everything into `C:\NET`, `MTCP.DEF` -> `MTCP.CFG`, appends `call C:\NET\NETSTART.BAT` to AUTOEXEC.BAT |
| `installer/cmd/usos-payload-pack/main.go` | the 14 files under `EFI/USOS/dos-native/msdos/` |
| `tools/tests/legacy_bios/test_usospkt.py` | Unicorn: the resident packet-driver API against a fake register window (11 tests) |
| `tools/tests/test_dos_network.py` | staging, AUTOEXEC hook, payload list, 8.3 names, mTCP pins / licence (6 tests) |

## Design decisions (with evidence)

**NIC programming** = the usosnet NDIS driver's igb backend
(`tools/nt/usosnet/src/usosnet_igb.c`, our own GPL code from the public Intel
datasheets, already working on the X470 under Windows Me / 95): reset with
GIO master disable, I210/I211 iNVM MAC and PLL erratum (PHY PLL check,
EEARBC word 0x0A, D3hot/D0 - here the BARs and command are always restored
afterwards because the I/O decode bit matters), PHY autonegotiation
10/100/1000 without PAUSE and CTRL.RFCE/TFCE cleared, advanced one-buffer RX
descriptors (2 KiB, SRRCTL DROP_EN), advanced TX data descriptors, legacy
INTx causes only (GPIE/IAM/EIAC/EIAM 0, IVAR0 0). Ported to 16-bit
assembler, not copied code from anywhere else.

**Register access: I/O BAR first, MMIO second.**
- The igb parts have a 32-byte I/O BAR with the indirect window IOADDR (+0,
  register offset) / IODATA (+4, the dword). Port I/O works in real mode,
  under HIMEM.SYS and under EMM386 (V86), so it is preferred. QEMU's igb
  implements it (`I/O BAR port C000 (IOADDR/IODATA)`, every network test
  ran through it). The I211's own I/O BAR is optional (firmware may leave it
  unassigned); X470 evidence so far: the bridge above the I211
  (02:01.0, 1022:43C7) has I/O decode on (`cmd:0007`, USOSDBG log of the 98 SE
  install) and the same firmware assigns I/O BARs to other devices (GPU
  I/O BAR E000, docs/design/win7-vista-no-csm.md). Whether the I211 BAR is
  assigned under DOS is printed by the driver (`PCI status/command ...
  BAR0 ... I/O BAR ... pin/line ...`).
- Without an I/O BAR (or when it reads all ones) BAR0 MMIO is used: every
  access does a short protected-mode switch with interrupts off, loads FS
  with a flat 4 GiB descriptor, returns to real mode, saves/restores GDTR and
  turns A20 on through port 92h for the access (HIMEM.SYS leaves A20 off and
  the QEMU BAR FEBA0000 has bit 20 set: without that the MMIO path read
  nothing - found and fixed in the first QEMU round). Works with and without
  HIMEM.SYS. Refused in V86 mode (EMM386): the driver then exits with
  errorlevel 3 and loads nothing. BAR0 above 4 GiB is refused too.
- INT 15h AH=87h was rejected for MMIO: BIOS block moves copy 16-bit words
  (`rep movsw`), the igb registers need 32-bit accesses.

**DMA.** One block (RX ring 16 x 16 B, TX ring 8 x 16 B, one 1.5 KiB TX
buffer, 16 x 2 KiB RX buffers, 34 KiB) right behind the image, 128-byte
aligned physically. Physical address = VDS lock (INT 4Bh AX=8103h, DX=000Ch:
no buffer, no remap -> contiguous or fail) when 0040:007B bit 5 says VDS is
there (EMM386), else segment*16+offset. `send_pkt` copies into the TX buffer
and waits for the descriptor's DD (about 20 ms limit, then CANT_SEND), so
the caller's buffer is free on return and no TX buffer pool is needed.

**Interrupts.** The PCI interrupt line (config 3Ch, BIOS-assigned; PCI
BIOS INT 1Ah B101h/B102h finds the device, a config-mechanism-1 scan is the
fallback, `/S` forces it). IRQ 3..15 with pin != 0 -> hooked unless `/P`.
The handler claims the interrupt only when ICR.INT_ASSERTED is set (shared
lines chain to the old vector), masks the NIC (IMC), sends EOI, polls the RX
ring, unmasks (IMS) - so an edge-programmed 8259 input (the X470 98 SE log
shows IRQ 5 EDGE in ELCR) still gets a new edge for causes that arrived in
between. The timer (INT 08h, after the BIOS handler) polls the RX ring in
every mode: the polled fallback (`/P`) and a safety net for lost edges.
Receiver upcalls (AX=0 buffer request, copy, AX=1) run on a private 1 KiB
stack under a busy flag (no nesting).

**TSR.** Resident: code/data/stack 0BACh bytes + the install code (not
reclaimed: the DMA block must not overlap code that runs while the NIC is
being started) + the DMA block = 0A8Eh-0A94h paragraphs (about 42 KiB, depends on the 128-byte alignment). The
environment is freed and handles 0-4 closed (a redirected log is complete).
Second load on any vector 0x60-0x80 is refused (`PKT DRVR` + `USOSPKT`
marker at the entry), another packet driver on the requested vector too.

Errorlevels: 0 installed, 1 no supported NIC (nothing resident), 2 vector
in use / already resident, 3 no usable register access, 4 reset failed,
5 bad command line, 6 no DMA region.

Packet driver functions: 1 driver_info (class 1, type 5553h, "USOSPKT igb",
basic), 2 access_type (class 1, type FFFFh or ours, number 0/FFh, type
length 0-8, 4 handles), 3 release_type, 4 send_pkt (14..1514 bytes), 5
terminate (releases the handle, CANT_TERMINATE), 6 get_address, 7
reset_interface (no-op), 20/21 set/get_rcv_mode (1 off .. 6 promiscuous),
24 get_statistics, 25 set_address. Others: BAD_COMMAND.

## Flow integration

INSTALL.BAT (MS-DOS only, i.e. no WINSETUP): `C:\NET` gets USOSPKT.COM,
NETSTART.BAT, the nine mTCP tools, MTCP.DEF/MTCP.CFG (`PACKETINT 0x60`,
`HOSTNAME USOSDOS`), MTCP.TXT (sources note + mTCP README + GPL-3.0 text)
and MTCPSRC.ZIP (complete mTCP source, unmodified); AUTOEXEC.BAT ends with
`call C:\NET\NETSTART.BAT`. NETSTART.BAT: `MTCPCFG=C:\NET\MTCP.CFG`, PATH +
C:\NET, `USOSPKT 0x60 >C:\NET\USOSPKT.LOG`; errorlevel != 0 -> one line
"brak obslugiwanej karty sieciowej", nothing else runs; else `DHCP -retries
2 -timeout 6 >C:\NET\DHCP.LOG` (at most ~12 s without a DHCP answer, Esc
skips) and one status line. The link wait inside USOSPKT is at most 5 s.

Only the CSMWrap DOS path stages the files (dos_csmwrap_target.sh copies the
whole helper folder); the BIOS-Core RAM-disk path (dos6_native_iso.zig) has
an explicit helper list without them - not changed in this round. Windows
1.x-3.x start menus replace AUTOEXEC.BAT and are not wired (the resident
DMA driver under Windows 3.x is untested).

## QEMU results (QEMU only, 82576 `-device igb`, not I211)

QEMU 11.1.0 (bety-instalacja tools, read-only), `-machine pc,smm=off`,
SeaBIOS, TCG, 64 MiB, user networking, MS-DOS 6.22 boot floppy (scratch
images, deleted). Every network case: driver loads, mTCP DHCP gets
10.0.2.15 on the first attempt, PING 10.0.2.2 4/4, HTGET http://68k.news/
99 598 bytes of the real page.

| case | registers | interrupt | DMA | result |
|---|---|---|---|---|
| plain DOS | I/O BAR C000 | IRQ 11 + timer | seg*16 | PASS |
| plain DOS, `/M` | MMIO FEBA0000 (flat FS) | IRQ 11 + timer | seg*16 | PASS |
| HIMEM.SYS, `/M` | MMIO (A20 via 92h) | IRQ 11 + timer | seg*16 | PASS (failed before the A20 fix: MAC/PHY read 0) |
| HIMEM + EMM386 NOEMS | I/O BAR | IRQ 11 + timer | VDS | PASS |
| HIMEM + EMM386, `/M` | - | - | - | errorlevel 3, clean message, nothing resident |
| plain DOS, `/P` vector 0x61 | I/O BAR | timer only | seg*16 | PASS (ping 11-51 ms = tick polling) |
| no NIC (`-nic none`) | - | - | - | errorlevel 1, nothing resident, boot continues |
| e1000 only | - | - | - | errorlevel 1 (not an igb part) |
| second load 0x61 / 0x60 | - | - | - | errorlevel 2 both |
| flow shape: C:\NET + NETSTART.BAT, HIMEM | I/O BAR | IRQ 11 | seg*16 | PASS (DHCP, PING, HTGET through PATH) |
| flow shape, no NIC | - | - | - | one line, DHCP not started, AUTOEXEC continues |

Not covered by QEMU: the I211 iNVM MAC and PLL path (82576 has an EEPROM
and no PLL erratum; QEMU's RAL/RAH are valid, MAC source 1), an
edge-triggered IRQ, a missing I/O BAR on real hardware, the config-scan path
(`/S`, the PCI BIOS was always present).

## What remains for the X470

1. Fresh MS-DOS install from a build with this branch (CSMWrap path), or a
   quick check: copy `C:\NET` + the AUTOEXEC line onto an existing DOS
   target disk. Then read `C:\NET\USOSPKT.LOG` and `C:\NET\DHCP.LOG`
   (logged silently; no photos needed).
2. In USOSPKT.LOG: the `PCI status/command / BAR0 / I/O BAR / pin/line`
   line (is the I211 I/O BAR assigned under CSMWrap? is BAR0 non-zero - the
   98 SE log showed 0 after Windows' own PCI pass), `Registers:` (I/O or
   MMIO), `MAC ... source 1` and `PLL nn` (01 = PLL fine first time), PHY
   01410C00, link speed.
3. If DHCP times out with "reported an error for every packet": TX does not
   complete -> look at the PHY / link line first; if RX only is missing, try
   `/P` (IRQ routing) by editing NETSTART.BAT.
4. Then HTGET http://68k.news/ and PING to a public host.
