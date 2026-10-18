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
| `PollMode` | 0 | 1 = no interrupt, poll RX every 20 ms (diagnostic / fallback) |
| `SkipPhy` | 0 | 1 = leave the PHY as firmware left it |
| `DebugPort` | 0 | decimal I/O port for `USOSNET ...` text lines (233 = 0xE9, QEMU isa-debugcon) |
| `NetworkAddress` | - | 12 hex digits, overrides the MAC |

## Diagnostics written by the driver

At the end of every start (success or failure) into the adapter's key
(9x: `HKLM\System\CurrentControlSet\Services\Class\Net\00nn`):

| value | meaning |
|---|---|
| `UsosnetVersion` | driver version (0x00000001 = 0.1) |
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

A start that hangs or crashes the machine writes nothing (9x keeps the
registry in memory until it flushes): then `PollMode=1` / `SkipPhy=1` narrow
it down, and `DebugPort` in QEMU shows the last step.
