# usosnet - USOS own Ethernet driver (NDIS 5.0 / 4.0 miniport)

Experimental NT3.51 has a separate usosnet351.sys build and source flag.
It uses proven original NDIS3.0/0x3C registration, IRQ plus a slow NDIS-owned
CheckForHang fallback, and has no installed-Windows network PASS yet.
See [exact evidence and NT351 staging](../../../docs/nt351-network-port-audit-2026-10-21.md).

Copyright (C) 2026 Maksymilian and the USOS Authors, GPL-3.0-or-later.
Design: `docs/usosnet-design-2026-10-18.md`.

One `usosnet.sys` for Windows 98 / 98 SE / Me (NDIS.VXD) and
Windows 2000 / XP / Server 2003 x86, and `usosnet4.sys`, the NDIS 4.0 build
of the same source, for Windows 95 OSR2 and Windows NT 4.0 SP6a (design:
`docs/usosnet-ndis4-2026-10-20.md`). Round 1 backend: Intel igb family
(I211 8086:1539, I210 8086:1533/157B, 82576 8086:10C9 = QEMU `-device igb`).

Status 2026-10-22: the XP x86 / Server 2003 x86 install flows stage
`usosnet.sys` + `usosnet.inf` like 2000 (`tools/network_setup.sh`,
`tools/tests/test_network_nt5.py`). Intel never shipped an NT5 driver for
the I210/I211 (its e1r driver is NDIS 6, Windows 7 and later); the X470 XP SP3
install had no driver for 8086:1539 (setupapi.log 0xe0000228). Every
`usosnet.sys` import resolves against XP SP3 NDIS.SYS. **Not run yet** on
NT5 in QEMU or on hardware.

Status 2026-10-20: `usosnet4.sys` 0.5 builds and passes the host tests
(imports against the 95 OSR2 and NT4 SP6a NDIS export tables, NDIS 4.0
registration); **not run yet** on QEMU or hardware.

Status 2026-10-18: 0.3 runs on the X470 under Windows Me (DHCP lease,
ping to the gateway and the internet answer; DNS fails, see 0.4). 0.4
(live per-protocol statistics) builds and passes the host tests; **not run
yet** on QEMU or hardware.

## Files

* `src/usosnet.c` - NDIS core (init, OIDs, send / receive, ISR / DPC,
  diagnostics), `src/usosnet_igb.c` - igb backend, `src/usosnet.h`.
* `inf/usosnet9x.inf` - Windows 98 / 98 SE / Me (copy as `USOSNET.INF`, 8.3).
* `inf/usosnet.inf` - Windows 2000 / XP / 2003 x86 (NT4: its IDs only).
* `inf/usosnet95.inf` - Windows 95 OSR2, with `usosnet4.sys` staged as
  `USOSNET.SYS` (copy as `USOSNET.INF`).
* `src4/` - `sources` + `usosnet4.rc` of the NDIS 4.0 build (`USOSNET_NDIS4=1`);
  `build.cmd` copies the `src` files next to them.
* `bin/i386/usosnet.sys`, `bin/i386/usosnet4.sys` - committed builds (our own
  code only).

## Build

    set WDKROOT=...\tools\WinDDK71
    tools\nt\usosnet\build.cmd [workdir]

WDK 7.1, `fre x86 WXP`, `TARGETTYPE=MINIPORT` linked against `ndis.lib`
only; `tools\nt4\pe_nt4_version.py` sets PE 4.00. `tools/tests/test_usosnet.py`
checks the binaries and the INFs. `USOSNET_ONLY=4` / `=5` builds one of them.

NDIS 4.0 build differences (all `#if USOSNET_NDIS4` in `src/usosnet.c`):
MajorNdisVersion 4 with the 0x48-byte characteristics, receive indication
through the exported `EthFilterDprIndicateReceive(Complete)` with the filter
at miniport block + 0xD8, NT4 bus scan (`NdisOverrideBusNumber`) +
`NdisMPciAssignResources` when `NdisMQueryAdapterResources` is not
supported, polling (PollMode 2) when `NdisMRegisterInterrupt` fails. Extra
diagnostics in the adapter key: `UsosnetNdis` (0x400 / 0x500),
`UsosnetPciLocation` (0x80000000 | bus << 8 | slot, NT4 scan),
`UsosnetAssign`, `UsosnetIrqStatus`. NT4 keeps them in
`HKLM\SYSTEM\CurrentControlSet\Services\NDISLoop1\Parameters`, its
error log entries go to the System event log (source NDISLoop).

## Registry parameters (Advanced tab)

| name | default | meaning |
|---|---|---|
| `PollMode` | 0 | 1 = never use the interrupt (RX / TX are polled every 20 ms in every mode since 0.3; the IRQ watchdog switches to the same state itself, value 2, when no interrupt arrives) |
| `SkipPhy` | 0 | 1 = leave the PHY as firmware left it |
| `DebugPort` | 0 | decimal I/O port for `USOSNET ...` text lines (233 = 0xE9, QEMU isa-debugcon) |
| `NetworkAddress` | - | 12 hex digits, overrides the MAC |

## Diagnostics written by the driver

At the end of every start (success or failure) into the adapter's key
(9x: `HKLM\System\CurrentControlSet\Services\Class\Net\00nn`):

| value | meaning |
|---|---|
| `UsosnetVersion` | driver version (0x00000004 = 0.4) |
| `UsosnetStage` | last stage reached: 1 entry, 2 config, 3 PCI, 4 resources, 5 MMIO mapped, 6 reset, 7 MAC, 8 DMA memory, 9 rings, 10 IRQ, 11 PHY, 12 started (0xC) |
| `UsosnetError` | NDIS status of a failed start (0 = none) |
| `UsosnetDevice` | vendor << 16 \| device (0x80861539 = I211) |
| `UsosnetMmio` | BAR0 physical address |
| `UsosnetIrq` | IRQ level << 16 \| vector as Windows assigned it |
| `UsosnetMacHi` / `UsosnetMacLo` | MAC bytes 0-2 / 3-5 |
| `UsosnetMacSource` | 1 RAL/RAH autoload, 2 EERD, 3 iNVM, 5 RAL/RAH w/o AV, 6 fallback, +0x10 registry override |
| `UsosnetStatusReg` | STATUS after PHY setup (bit 1 = link up, bits 7:6 speed) |
| `UsosnetCtrlReg` | CTRL after reset |
| `UsosnetPhyBmsr` | PHY BMCR << 16 \| BMSR |
| `UsosnetPhyId` | PHY ID1 << 16 \| ID2 (0 = MDIC failed) |
| `UsosnetBar0High` | BAR0 high dword (non-zero: above 4 GiB, start refused - turn off "Above 4G decoding") |
| `UsosnetPllTries` | I210/I211 iNVM PLL check: 0 not needed, n = checks until OK, 0x100+n = PLL never configured |
| `UsosnetStatsVa` / `UsosnetStatsPa` | 0.4: linear / physical address of the live statistics page (0 = not allocated) |

| `UsosnetLast*` | only after Device Manager disable + enable (driver kept loaded): counters of the previous run - `IsrCalls`, `Isr` (claimed), `Rx`, `RxTimer`, `Tx`, `TxDone`, `HwRx` (GPRC), `HwTx` (GPTC), `Flags` (as USN1 flags, TX stalls << 4) |

## Runtime log (0.3)

Every 20 ms the timer polls the RX ring and reclaims TX descriptors, in
every mode: with a working interrupt the ISR is first and the timer finds
nothing; with a lost or misrouted INTx (X470 + Me round 1: winipcfg
169.254.x.x, `netstat -e` 28 received = the 28 sent broadcasts looped
back by NDIS, 14 bytes each less, so no frame from the wire) the card
still works at 20 ms latency. IRQ watchdog: no claimed interrupt for 5 s
although the link is up or the timer found frames -> the chip is masked
(INTx released) and `PollMode` becomes 2 (`UsosnetIrqBroken`,
`usosnet_irq.h`).

`NdisWriteErrorLogEntry` (code `NDIS_ERROR_CODE_DRIVER_FAILURE`; Windows
9x: `C:\WINDOWS\NDISLOG.TXT`, Windows 2000 / XP: System event log) at
30 and 65 s and every 5 min, on a link change, on the IRQ watchdog
switch and on a TX stall (descriptors pending 3 s); at most 40 rounds.

0.5 budget (X470 98 SE fresh install, 2026-10-20): NDIS.VXD of 98 SE and
Me counts an adapter's error log entries for 30 s from the first one;
before VxD Init_Complete the first entry shows a "device not working
properly" notice and the fifth removes the adapter's devnode (CONFIGMG
Call_At_Appy_Time -> Remove_SubTree): no network. 0.4 wrote USN1..USN5
at 3 s. The driver now writes nothing in the first 30 s and at most 4
entries per 31 s window (`LogBudget`, `LOG_*` in `usosnet.h`); entries
over the budget are skipped (the first round's USN5, then whole
rounds inside one window), never queued.

Each round, 10 dwords per entry:

| tag | values after the tag |
|---|---|
| `USN1` 0x55534E31 | seconds, flags (bits 1:0 PollMode, 2 link, 3 full duplex, 15:8 event 0 periodic / 1 IRQ watchdog / 2 TX stall / 3 link, 31:16 Mb/s), ISR calls, ISR claimed, DPCs, RX indicated, RX found by the timer, TX queued, TX completed (DD) |
| `USN2` 0x55534E32 | seconds, TX errors, TX ring full, RX errors, chip TPR, GPRC, GPTC, MPC, RNBC (summed clear-on-read counters) |
| `USN3` 0x55534E33 | seconds, STATUS, IMS, RDH, RDT, TDH, TDT, PCI command/status dword (bit 19 = INTx pending), RCTL |
| `USN4` 0x55534E34 (first round) | IRQ level << 16 \| vector, RX ring PA, TX ring PA, CTRL, TCTL, RXDCTL, TXDCTL, CRCERRS, version |

Reading: TPR / GPRC > 0 but RX indicated = 0 -> RX DMA / filter problem;
GPRC > 0, RX found by the timer > 0, ISR claimed 0 -> interrupt not
delivered (INTx routing); TX queued > TX completed and TDH stuck -> TX DMA;
GPTC = 0 with TX completed > 0 -> frames dropped in the MAC / PHY.

A start that hangs or crashes the machine writes nothing (9x keeps the
registry in memory until it flushes): then `PollMode=1` / `SkipPhy=1` narrow
it down, and `DebugPort` in QEMU shows the last step.

## Live statistics (0.4)

One 4 KiB shared-memory page, layout `USNS_BLOCK` in `src/usosnet_proto.h`
(magic `USNS`, version 1, cleared at halt before the page is freed).
USOSLOG (`src/platform/bios/win9x/usoslog.c`, branch `test/x470-98se-qemu`)
reads it through `UsosnetStatsVa` (Windows 9x system arena) or, through
USOSDBG's DPMI mapping, `UsosnetStatsPa`.

* `Rx[]` / `Tx[]`: frames per class bit (`USNS_C_*`: broadcast, multicast,
  ARP, IPv4, ICMP, UDP, TCP, DNS = port 53 either side, DHCP, HTTP = TCP 80,
  fragment, IPv6, other, short, IP options, NetBIOS 137/138);
* `Drop[]`: RX drops by reason (not EOP, CE, SE, SEQ, CXE, RXE, bad length,
  no packet filter yet) and notes on indicated frames (L4E, IPE, L4E on UDP,
  L4E on DNS, IPCS / L4CS / UDPCS checked, looped back);
* `Td[]`: MiniportTransferData calls, calls outside an indication, short
  copies, bytes, largest offset / length, calls for UDP / DNS frames;
* `Core[]`: the adapter counters and STATUS / RCTL / RXCSUM / ring
  pointers, once a second;
* `Hist[32]`: the last frames (direction, classes, ports, length, RX status,
  peer IPv4), `LastDnsRx` / `LastDnsTx`: first 128 bytes of the last DNS frame.

RX drop rule (0.4 review of the DNS failure on the X470): only frame errors
(CE SE SEQ CXE RXE, mask 0x97000000, the same as the Linux igb driver) drop
a frame. The IPv4 / L4 checksum error bits (IPE 0x40000000, L4E 0x20000000)
were never in that mask and are now only counted: Windows 9x verifies the
checksums itself. So the driver did not drop UDP replies for a checksum
verdict; the statistics show where they go.

A UDP broadcast to port 21843 (0x5553, `USNS_LOG_PORT`) sent by USOSLOG
asks for one extra `NdisWriteErrorLogEntry` round in the next second (at
most 100 per start, besides the 40 scheduled ones). Every round now also
has `USN5` 0x55534E35: seconds, RX UDP, RX DNS, RX TCP, RX ICMP, TX UDP,
TX DNS, UDP frames with L4E, TransferData calls outside an indication.
