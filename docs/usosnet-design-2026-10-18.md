# usosnet: USOS own NIC drivers (design, 2026-10-18)

Status: round 1 (prototype). Part of v1.0 (user decision 2026-10-18).
Code: `tools/nt/usosnet/` (GPL-3.0-or-later, like usosnvme and usosmpart).

## Goal

A "usable OS" (see `usable-system-definition`) needs a network, and the old
Windows releases USOS installs have no driver for the NICs on the user's
boards. usosnet is our own driver family, written from public Intel / Realtek
datasheets and the public NDIS documentation, one code base for every Windows
generation that can host it.

First target: Intel I211-AT (igb family, PCI 8086:1539) on the X470 Master
SLI/ac under Windows 98 SE / Me, the same binary also on 2000 / XP x86.

## Sources and provenance

* Intel Ethernet Controller I210/I211 datasheet; Intel 82576EB GbE Controller
  datasheet (registers, reset, EERD, iNVM, MDIC, advanced descriptors).
* NDIS 5.0 miniport documentation (Windows 2000 DDK / Windows 98 DDK docs) and
  the WDK 7.1 `ndis.h` the build uses.
* References read for hardware sequencing only, no code copied: Linux `igb`
  (GPL-2.0), FreeBSD `e1000`/`igb` (BSD). Where they decided an order of
  steps (iNVM record sizes, RAH pool bit, waiting for the queue ENABLE bits,
  ICR INT_ASSERTED in legacy mode) the source comment says so.
* The Windows 98 SE / Me `NDIS.VXD` export names were checked on the user's
  CDs (names only) to make sure every import resolves on 9x
  (`tools/tests/test_usosnet.py`, `W9X_NDIS_EXPORTS`). No Microsoft file is in
  the repo.

## Architecture

```
            NDIS 5.0 miniport core (usosnet.c)
  DriverEntry / Initialize / Halt / Reset / ISR / DPC / Send /
  TransferData / Query / Set / shutdown, OIDs, registry diagnostics,
  DMA rings + buffers, link timer, poll mode
                    |  USOSNET_CHIP_OPS (usosnet.h)
   +----------------+----------------+-----------------+
   igb              e1000e            igc               rtl8168
   I211/I210/82576  82574, 82579,     I225/I226         RTL8111/8168
   (round 1)        I217/I218/I219    (later)           (later)
                    (round 2)
```

* One PE `.sys` for Windows 98 / 98 SE / Me (NDIS.VXD wraps NDIS 5.0 PE
  miniports, `DevLoader=*ndis`, `DeviceVxDs=usosnet.sys`) and
  Windows 2000 / XP / 2003 x86. PE subsystem version 4.00.
* NT 4.0: the same core built as NDIS 4.0 (`MajorNdisVersion = 4`, no PnP
  resources -> `NdisReadPciSlotInformation` scan + `oemsetup.inf`); later.
* x64 (XP x64 / 2003 x64 / Vista+): later, NDIS 5.1 x64 build of the same core
  (Vista+ have inbox drivers for most of these chips anyway, except NT6 on
  I211/I219 which Intel still covers).
* DOS: a packet driver (PKTDRVR spec) reusing the backend register logic in C
  (OpenWatcom), for Windows 3.x / WfW (via NDIS 2 shim or packet driver
  stacks) and DOS tools. Later.

### Rules that keep one binary loading on 9x and NT

WDK 7.1 forces `BINARY_COMPATIBLE=0`, so several NDIS "functions" are macros
over kernel / HAL calls that do not exist on 9x. The core therefore:

* imports NDIS.SYS only (sources: `TARGETTYPE=MINIPORT`, only `ndis.lib`,
  a stray kernel import is a link error);
* has its own zero / copy / compare helpers, MMIO through volatile pointers,
  a stall built on port-0x80 reads, `__outbyte` for the debug port, compiler
  intrinsics for the two interlocked operations;
* treats `NDIS_BUFFER` as opaque (an MDL on NT, a different structure on 9x):
  only `NdisQueryBuffer` (exported on both) and the common first field `Next`;
* is a serialized miniport without spin locks: TX state is touched only by
  MiniportSend (it also reclaims finished descriptors), RX only by
  MiniportHandleInterrupt (or the poll timer), link state only by the timer.

### Data path

Copy based, the same on every OS and every chip:

* 64 RX + 64 TX descriptors, each with its own 2 KiB DMA buffer (two buffers
  per 4 KiB shared-memory allocation, 32-bit physical addresses);
* TX: copy the packet chain into the descriptor's buffer, pad to 60 bytes,
  ring the tail, return `NDIS_STATUS_SUCCESS` at once;
* RX: `NdisMEthIndicateReceive` with the whole frame as lookahead (the
  `COPY_LOOKAHEAD_DATA` and `TRANSFERS_NOT_PEND` MAC options),
  `MiniportTransferData` copies from the same buffer, then the descriptor goes
  back to the hardware. 9x protocols (VTCP) use this path natively.

Zero-copy (`NdisMIndicateReceivePacket`, scatter-gather TX) is not worth it at
these OS's speeds; maybe later for XP.

## Per-OS matrix (target)

| OS | NDIS | binary | INF | status |
|---|---|---|---|---|
| Windows 95 OSR2 | 4.0 (NDIS.VXD) | NDIS 4 build | 9x | later (check exports) |
| Windows 98 / 98 SE | 5.0 | usosnet.sys | usosnet9x.inf | round 1, untested |
| Windows Me | 5.0 | usosnet.sys | usosnet9x.inf | round 1, X470 test next |
| NT 3.51 | 3.0 | - | - | not planned |
| NT 4.0 | 4.0 | NDIS 4 build | oemsetup.inf | later |
| Windows 2000 / XP / 2003 x86 | 5.0 / 5.1 | usosnet.sys | usosnet.inf | round 1, untested |
| XP x64 / 2003 x64 | 5.1 | x64 build | NT5 x64 INF | later |
| Vista+ | 6.x | inbox / vendor | - | only where needed |
| DOS / Win 3.x | packet driver / NDIS 2 | separate | - | later |

## Chips and the user's boards

| board | NIC | PCI ID | backend |
|---|---|---|---|
| X470 Master SLI/ac (test target) | I211-AT | 8086:1539 | igb (round 1) |
| Z170 | I219-V | 8086:15B8 (and other I219 IDs) | e1000e |
| Z97 / X99 | I218-V / I218-LM | 8086:15A1, 155A, 15A0, 15A2 ... | e1000e |
| P9X79 | 82579V | 8086:1503 | e1000e |
| B450 / 990FX / P67 | RTL8111/8168 (various revs) | 10EC:8168 | rtl8168 |
| QEMU `-device igb` | 82576 | 8086:10C9 | igb (dev) |
| QEMU `-device e1000e` | 82574L | 8086:10D3 | e1000e (dev) |

e1000e notes for round 2: the PCH parts (82579, I217, I218, I219) need the
SW/FW/HW semaphore (EXTCNF_CTRL), the PHY over MDIO with the ULP / LANPHYPC
power-gating exit, K1 workarounds and the NVM in the shared SPI flash (MAC
from RAL/RAH after reset or the flash shadow); legacy / extended descriptors.
RTL8168: many MAC revisions with different PHY init tables; start with the
revision on the B450 board.

## Interrupt model

* Windows 9x has no MSI: legacy INTx, level triggered, shared. NDIS 5.0
  `NdisMRegisterInterrupt(RequestIsr=TRUE, Shared=TRUE, LevelSensitive)`.
* igb in non-MSI-X mode (GPIE = 0, so NSICR = 0: an ICR read clears it
  only while INT_ASSERTED is set): only the legacy `IMS` causes (LSC, RXSEQ,
  RXDMT0, RXO, RXT0) are enabled; IVAR0 = 0 and EIMS stays 0 (no extended /
  EICR path). ISR: while the driver keeps the chip masked (`IrqMasked`, set
  by IrqDisable, cleared by IrqEnable) it returns "not ours" without touching
  ICR; otherwise it reads ICR and claims only when INT_ASSERTED is set
  (all-ones = device gone, not ours); then masks (IMC, flushed with a STATUS
  read) and queues the DPC. DPC: drain RX, indicate, return buffers, unmask.
  TX completion needs no interrupt (reclaimed in Send). The claim rule is
  `usosnet_irq.h`, host-tested by `tools/tests/test_usosnet.py`.
* X470 without CSM: the INTx line of the I211 comes from the ACPI `_PRT` /
  PCI IRQ routing that CSMWrap's SeaBIOS + the 9x PCI bus driver use; Me
  should see an IRQ in the resource list like for every other PCI device.
  Not verified yet for this device (usosnvme on 9x is polled, so it proves
  nothing about INTx); `UsosnetIrq` in the registry shows what Me assigned.
  If the IRQ does not arrive (no ISR count, RX stalls), `PollMode=1` makes the
  driver poll RX every 20 ms from a timer: a diagnostic and a fallback, not
  the normal path.
* NT5: the same INTx path (MSI is NDIS 6 only).

## PHY / link

* After the MAC reset (CTRL.RST, waiting for EECD.AUTO_RD and
  STATUS.PF_RST_DONE): CTRL.SLU on, forced speed / duplex off, PHY (MDIC
  address 1) BMCR power-down bit cleared, ANAR = 0x01E1 (10/100 half+full, no PAUSE / ASM_DIR; CTRL.RFCE / TFCE stay 0, so
  no flow control either way until the FC thresholds are programmed),
  1000BASE-T control = 1000 half+full, autonegotiation restarted. The PHY
  power-down matters on real boards: a previous OS (Windows 10 shutdown,
  Wake-on-LAN off) can leave the PHY powered down.
* Link state from STATUS (LU, SPEED, FD) by a 1 s timer;
  `NDIS_STATUS_MEDIA_CONNECT` / `DISCONNECT` indicated on change,
  `OID_GEN_MEDIA_CONNECT_STATUS` and `OID_GEN_LINK_SPEED` answer from it.
* `SkipPhy=1` leaves the PHY as firmware left it (diagnostic).

## MAC address

1. RAL0/RAH0 after reset (the hardware auto-loads them from the NVM /
   iNVM): used when RAH.AV is set and the address is a valid unicast.
2. I210/I211 without flash (EECD.FLASH_DETECTED clear): iNVM word-autoload
   records for words 0-2 (64 dwords at 0x12120; CSR-autoload and RSA-key
   records skipped by their size).
3. 82576 / I210 with flash: EERD words 0-2 (82576 LAN1: last byte ^ 1).
4. A sane-looking RAL/RAH without AV, else a locally administered fallback
   02:55:53:4F:53:01 (source 6, logged) so the stack still starts.
5. Registry `NetworkAddress` overrides (MacSource | 0x10).

## Diagnostics

* Registry (written at the end of every MiniportInitialize, also on failure)
  into the adapter key (`HKLM\System\CurrentControlSet\Services\Class\Net\00nn`
  on 9x, `...\Control\Class\{4d36e972...}\00nn` on NT): `UsosnetVersion`,
  `UsosnetStage` (1 entry .. 12 started, see `usosnet.h`), `UsosnetError`
  (NDIS status), `UsosnetDevice`, `UsosnetMmio`, `UsosnetIrq`
  (level << 16 | vector), `UsosnetMacHi`/`Lo`, `UsosnetMacSource`,
  `UsosnetStatusReg`, `UsosnetCtrlReg`, `UsosnetPhyBmsr` (BMCR << 16 | BMSR),
  `UsosnetPhyId`, `UsosnetBar0High` (BAR0 high dword; non-zero = above 4 GiB,
  start refused), `UsosnetPllTries` (I210/I211 iNVM PLL erratum check).
* I210 / I211 without flash (every I211): the PLL erratum of the Intel
  I210/I211 specification update. After the reset the driver reads the
  internal PHY's PLL frequency register (page 0xFC, register 14); a low byte
  of 0xFF means the PLL came up unconfigured. Then: PHY reset, iNVM word 0x0A
  (default 0x202F) with bit 0x0010 forced through EEARBC, D3hot -> D0 cycle
  of the function (command + BARs restored if D0 cleared them), real word
  back; up to 5 checks. Sequence taken from the spec update's description
  and cross-checked for step order against FreeBSD e1000 (no code copied).
* `DebugPort` (decimal; 233 = 0xE9 for QEMU `isa-debugcon`): text lines
  `USOSNET ...` at every step, link changes, filter changes.
* Statistics through the standard OIDs (`netstat -e` on 9x / XP).

## Testing plan

1. Build checks (`tools/tests/test_usosnet.py`): imports subset of the 9x
   NDIS.VXD export names, PE 4.00, INF IDs = chip table.
2. QEMU (dev PC): `-device igb` (82576) with `-netdev user` (slirp DHCP
   10.0.2.15, `filter-dump` pcap for DHCP / ARP / ICMP proof), on an already
   installed 98 SE / Me / XP image, `DebugPort=233` + `isa-debugcon`.
   Not done in round 1 (no installed 9x/XP image was available and the user
   asked not to spend time on QEMU installs).
3. X470 (user, Me on the Micron NVMe, in-place install): Device Manager
   install, `winipcfg` lease, ping the router, `netstat -e`, registry
   diagnostics export (package README).
4. Then 98 SE on the X470, 2000 / XP on the X470 (same binary, usosnet.inf).
5. Round 2: e1000e backend (QEMU e1000e, then Z170 I219-V, Z97/X99 I218,
   P9X79 82579V); round 3: rtl8168 (B450 / 990FX / P67), igc (I225/I226).

## Open points after round 1

* Runtime: see "Status 2026-10-20" (X470 ME PASS via polling; IRQ open).
* Multicast via "all multicast" (MPE) instead of the MTA hash.
* 82576 / I210 with manageability firmware: the SW/FW semaphore around
  MDIC / EERD is not taken yet (I211 has no firmware; 82576 in QEMU none).
* No Wake-on-LAN, no power management (`OID_PNP_CAPABILITIES` not
  supported), no checksum offload, no jumbo frames, no VLAN.
* Installer integration (stage the package on DATA\Drivers, MSBATCH network
  section, answer-profile option "network driver") after the X470 PASS.

## Status 2026-10-20

First hardware round, usosnet 0.4, X470 Master SLI/ac, Windows ME, Intel I211:

* DHCP lease obtained; DNS over UDP and TCP works; HTTP works (Internet
  Explorer loads 68k.news); zero RX/TX drops in the statistics page.
* The NIC interrupt never arrives: IRQ 5 is edge-triggered in the ELCR and
  stays masked, `isr_calls=0`. The driver runs entirely on its 20 ms timer
  polling fallback (0.3+). Fixing the IRQ routing is the next open point.
* The earlier "DNS failure" report was frogfind.com being down server-side,
  not a driver fault.
