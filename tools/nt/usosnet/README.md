# usosnet - USOS own Ethernet driver (NDIS 5.0 miniport)

Copyright (C) 2026 Maksymilian and the USOS Authors, GPL-3.0-or-later.
Design: `docs/usosnet-design-2026-10-18.md`.

One `usosnet.sys` for Windows 98 / 98 SE / Me (NDIS.VXD) and
Windows 2000 / XP / Server 2003 x86. Round 1 backend: Intel igb family
(I211 8086:1539, I210 8086:1533/157B, 82576 8086:10C9 = QEMU `-device igb`).

Status 2026-10-18: builds, imports checked against the 98 SE / Me NDIS.VXD
export names; **not run yet** on QEMU or hardware.

## Files

* `src/usosnet.c` - NDIS core (init, OIDs, send / receive, ISR / DPC,
  diagnostics), `src/usosnet_igb.c` - igb backend, `src/usosnet.h`.
* `inf/usosnet9x.inf` - Windows 98 / 98 SE / Me (copy as `USOSNET.INF`, 8.3).
* `inf/usosnet.inf` - Windows 2000 / XP / 2003 x86.
* `bin/i386/usosnet.sys` - committed build (our own code only).

## Build

    set WDKROOT=...\tools\WinDDK71
    tools\nt\usosnet\build.cmd [workdir]

WDK 7.1, `fre x86 WXP`, `TARGETTYPE=MINIPORT` linked against `ndis.lib`
only; `tools\nt4\pe_nt4_version.py` sets PE 4.00. `tools/tests/test_usosnet.py`
checks the binary and the INFs.

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
| `UsosnetVersion` | driver version (0x00000003 = 0.3) |
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
3, 10, 30, 60 s and every 5 min, on a link change, on the IRQ watchdog
switch and on a TX stall (descriptors pending 3 s); at most 40 rounds.
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
