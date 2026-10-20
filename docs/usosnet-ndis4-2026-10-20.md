# usosnet4: NDIS 4.0 build for Windows 95 OSR2 and NT 4.0, 2026-10-20

Branch `feat/usosnet-95-nt4` (based on `test/x470-98se-qemu` 1197eb49).
Status: builds, host tests pass. **Not run on QEMU or hardware yet.**

## What each system accepts (checked on the user's media, read-only)

| | Windows 95 OSR2.1 PL | Windows NT 4.0 SP6a PL |
|---|---|---|
| NDIS | `NDIS.VXD` "Version 4.0" (1996-11-12) | `NDIS.SYS` 4.00 |
| Miniport format | PE `.SYS`, loaded by NDIS.VXD's own PE loader (inbox `E100.SYS`, `NE2000.SYS`, `DC21X4.SYS`) | PE `.SYS` |
| `NdisMRegisterMiniport` | MajorNdisVersion 3 or 4, minor 0; 4 needs >= 0x48 bytes; **5 refused** | 4.0 (5 refused) |
| PnP resources | `NdisMQueryAdapterResources` (devnode) | returns `NDIS_STATUS_NOT_SUPPORTED` (0xC00000BB) |
| `NdisReadPciSlotInformation` | slot number ignored (devnode config space) | `HalGetBusDataByOffset(PCIConfiguration, Miniport->BusNumber, SlotNumber, ...)`: slot used as given |
| `NdisOverrideBusNumber` | exported | sets the bus of the wrapper context and the miniport block |

NDIS.VXD of 95 resolves PE imports from three name tables: 220 NDIS.SYS
names, 13 HAL.DLL and 23 NTOSKRNL.EXE names
(`tools/tests/data/w95osr2_ndis_exports.txt`); NT4 SP6a NDIS.SYS has 279
exports (`tools/tests/data/nt4sp6a_ndis_exports.txt`). Every one of the
32 imports of usosnet 0.5 exists in both. What blocks the 0.5 binary is
not an import:

1. MajorNdisVersion 5 (both refuse it);
2. `NdisMEthIndicateReceive(Complete)` are WDK macros that call
   `EthRxIndicateHandler` / `EthRxCompleteHandler` at miniport block +0x164 /
   +0x170, NDIS 5 fields. The NDIS 3 form passes the filter (`EthDB`) to the
   exported `EthFilterDprIndicateReceive(Complete)`. `EthDB` is at +0xD8 in
   WDK 7.1 and in the calls of the inbox 95 OSR2 `NE2000.SYS` and NT4 SP6a
   `E100B.SYS` (disassembled: `push dword [reg+0D8h]` before the import call);
3. NT4 has no PnP: no resource list, real PCI slot numbers.

## Design (one source, `#if USOSNET_NDIS4`)

`usosnet4.sys` = `src/usosnet.c` + `src/usosnet_igb.c` built from `src4/`
with `USOSNET_NDIS4=1` (WDK 7.1 still needs `NDIS50_MINIPORT` for its
headers). One binary for 95 and NT4; the path is chosen at run time:

* registration: `MajorNdisVersion 4`, size = offset of `CoCreateVcHandler`
  (0x48, `C_ASSERT`); `OID_GEN_DRIVER_VERSION` 0x0400; no `OID_PNP_*` in
  the supported list;
* receive: `EthFilterDprIndicateReceive(EthDB, ...)` /
  `...Complete(EthDB)` (`UsIndicateRxComplete`, also used by the igb
  backend), `C_ASSERT(FIELD_OFFSET(NDIS_MINIPORT_BLOCK, EthDB) == 0xD8)`;
* resources: `NdisMQueryAdapterResources` first (95). On failure (NT4):
  `LegacyFind` scans buses 0-255, devices 0-31, functions (multi-function
  header bit) with `NdisOverrideBusNumber` + `NdisReadPciSlotInformation`
  for the first chip of the table, then `NdisMPciAssignResources` for that
  slot (HAL-assigned memory range and interrupt). Without an assignment
  BAR0 and the interrupt line come from config space (the 0.5 fallback);
* every PCI config access uses `A->PciSlot` (0 on PnP systems, which
  ignore it);
* `NdisMRegisterInterrupt` failure: PollMode 2 (the 20 ms timer, as on the
  X470 98 / Me) instead of a failed start. The NDIS 5 build keeps failing;
* unchanged: the 20 ms polling in every mode, the IRQ watchdog, the error
  log budget (`LogBudget`: quiet 30 s, 4 entries per 31 s window; 95's
  NDIS.VXD is the same family), the live statistics page;
* new diagnostics: `UsosnetNdis`, `UsosnetPciLocation`, `UsosnetAssign`,
  `UsosnetIrqStatus`.

`bin/i386/usosnet.sys` (NDIS 5, X470 PASS on Me / 98 SE / 98 FE) is **not**
replaced: the shared source still builds it (same imports, same NDIS 5
calls; checked), but the committed 0.5 binary stays the tested one.

## Flows

### Windows 95 OSR2

`tools/network_setup.sh`: for `system=95` the package is `usosnet95.inf` +
`usosnet4.sys`, staged as `USOS9X\NET\USOSNET.INF` / `USOSNET.SYS` only for
a PCI card the INF lists. The existing 9x DOS flow (dos_startup.cmd) then
puts both beside Setup and copies `USOSNET.SYS` to `C:\WINDOWS\SYSTEM`
before the first Windows start (the 98 mechanism). New: with the package
staged, 95 Setup gets `/P I` (as the NVMe opt-in): without it SeaBIOS's PnP
BIOS lists no PCI bus and 95 never enumerates the card. Log:
`C:\USOS9X\LOGS\NETSETUP.TXT` (staging), the driver's values in
`Class\Net\00nn`, `C:\WINDOWS\NDISLOG.TXT`.

Independent of `fix/w95-round1` (REG95): the adapter comes from PnP + INF,
not from MSBATCH AddReg. Which protocols 95 binds to the new adapter
(TCP/IP from Setup or 95's own defaults) is not known yet.

### Windows NT 4.0

NT4 has no INF installer for a PCI miniport. The unattended answer already
installs the MS Loopback Adapter with TCP/IP (`network_defaults.zig`:
`LOOP` + `TC`); OEMNADLB.INF names its driver service `NDISLoop` and the
adapter `NDISLoop1`, and Setup computes every binding (TCP/IP, NetBT,
Workstation). `usos_net_nt4_reg` writes `C:\USOS\NT4\USOSNET.REG`, which
takes that adapter over:

* `Services\NDISLoop` `ImagePath` = `\SystemRoot\System32\drivers\usosnet4.sys`
  (NDIS starts our miniport for `\Device\NDISLoop1`);
* `Services\NDISLoop1\Parameters`: `BusType` 5 (PCI), `BusNumber` 0 (the
  driver finds the real bus and slot), `PollMode` 0;
* `NDISLoop1\Parameters\Tcpip`: DHCP (and `Services\DHCP` Start 2), or the
  profile's static address / mask / gateway, DNS in `Tcpip\Parameters
  NameServer`.

`POST.CMD` (first logon, in the install VM, before SP6a): only when
`C:\USOS\Drivers\USOSNET\USOSNET4.SYS`, `USOSNET.REG` and the
`NDISLoop1` key exist: copy the driver, import the REG, read back
(`regedit /e` + `findstr usosnet4.sys`), lines in
`C:\USOS\NT4\NETSETUP.TXT`. Without a matching card nothing changes (the
loopback stays). The Network applet still shows the loopback's name and
properties dialog; removing that adapter there removes ours.

In the install VM (`-nic none`) the driver finds no card: NT4 may report a
failed service there; on the PC it starts.

## Tests (host)

`tools/tests/test_usosnet.py` (`Ndis4`): imports vs both export tables,
PE 4.00 native, `push 48h` + `mov byte [ebp-n], 4` before the single
`NdisMRegisterMiniport` call, `push [reg+0D8h]` and no `call [reg+164h /
170h]`, the NT4 path order, no slot-0 PCI access left, the 95 INF, POST.CMD
and dos_startup wiring. `tools/tests/test_network_defaults.py`: 95 / NT4
never get the NDIS 5 file, 95 stages usosnet4 as `USOSNET.SYS`, NT4 stages
`USOSNET4.SYS` + `USOSNET.REG` (DHCP and static), no card = no REG.

Not done: QEMU (no 95 / NT4 image exists; a full install is Codex work:
`-device igb` exercises the 82576 path) and hardware.

## X470 test plan

1. **95 in place** (the current 95 on the Micron, NVMe install, PCI bus
   already detected): kit copies `usosnet4.sys` as
   `C:\WINDOWS\SYSTEM\USOSNET.SYS` and `usosnet95.inf` as
   `C:\WINDOWS\INF\OTHER\USOSUSOSNET.INF` (or `C:\WIN95\USOSNET.INF` if
   that is the source path); next start: New Hardware for the I211. Read
   back `Class\Net\00nn` (UsosnetStage 0xC, UsosnetNdis 0x400), NDISLOG.TXT,
   USOSLOG NET section (binding, DHCP, DNS). Expected risk points: 95's PE
   loader on a WDK 7.1 image (`.rdata`, 0x80 alignment), protocol binding.
2. **NT4**: needs an install (USOS NT4 flow with the I211 matched, so
   USOSNET.REG is staged). Then NETSETUP.TXT, the `NDISLoop1\Parameters`
   values (UsosnetPciLocation = the I211's bus/slot, UsosnetAssign 0,
   UsosnetIrqStatus), `ipconfig /all` evidence through the existing NT4
   logging, System event log entries of NDISLoop.

## Materials

Own code. Facts were taken from the user's 95 OSR2.1 PL and NT4 SP6a PL
media (export name tables, the version checks and slot handling of
NDIS.VXD / NDIS.SYS by disassembly, the EthDB offset from the inbox
NE2000.SYS / E100B.SYS calls, OEMNADLB.INF's service names) and the public
WDK 7.1 headers. The NT5 NDIS sources in `Desktop\doors` were looked at for
`NdisOverrideBusNumber` but describe NT5, not NT4; nothing from them is in
this change. No Microsoft file or text is committed (names only).
