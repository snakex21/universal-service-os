# usosusb9x: USOSUSB.MPD, USB flash drives for Windows 95 OSR2 / 98 / 98 SE / Me

A SCSIPORT.PDR miniport (`usosusb.mpd`) that gives Windows 9x USB flash drives on
xHCI-only PCs without a 9x USB stack. SeaBIOS inside CSMWrap stays the only xHCI owner;
its helper core serves the USOS USB disk service (UDS) on channel 1, and this miniport
forwards SCSI commands to it. Design: `docs/usb9x-hotswap-design-2026-10-19.md`
(section 1 (A), stage 1). ABI: `src/platform/bios/win9x/usosuds.h`.

Status: stage 1 (cold-plugged stick, read/write), **built and host-simulated only**. It has
not run in a 9x VM or on the X470. Needs CSMWrap 3.1.2-usos16 or later (UDS channel 1).

Folder name: `tools/nt4/usosusb` is an unrelated NT6 HID driver, so this one is `usosusb9x`.

## Files

| file | what |
|---|---|
| `src/usosusb.c`, `src/usosusb.h` | the miniport |
| `src/usosusb.rc` | version resource |
| `src/W9X/sources`, `src/W9X/makefile` | WDK 7.1 build (like usosnvme's W9X variant) |
| `build.cmd` | `build.cmd w9x [workdir]` -> `bin\W9X\usosusb.mpd` (PE 4.00) |
| `bin/W9X/usosusb.mpd` | the committed build output |
| `usosusb.inf` | 9x INF (`$CHICAGO$`, Class SCSIAdapter, DevLoader `*IOS`, PortDriver `usosusb.mpd`, hardware ID `USOSUSB`) |
| `usosusb.reg` | REGEDIT4 fragment for a root devnode (below) |

The flow stages them as `USOSUSB.MPD`, `USOSUSB.INF`, `USOSUSB.REG`.

## Build

```
set WDKROOT=C:\path\to\WinDDK71
cmd /d /c "cd /d <repo> && tools\nt\usosusb9x\build.cmd w9x"
```

`build.cmd` copies `src\` and, from `src\platform\bios\win9x`, `usosuds_slot.c` and
`usosuds.h` into a work directory, builds there (`build -cZ`, fre x86 WXP), sets the PE
version to 4.00 with `tools\nt4\pe_nt4_version.py` and copies the image to
`bin\W9X\usosusb.mpd`. Imports: SCSIPORT.SYS only (resolved by SCSIPORT.PDR).

Test: `python -I tools/tests/usb9x/test_usosusb9x.py` (source rules, PE image, INF/REG,
and a zig cc host simulation of the whole SRB path against a fake helper).

## How it works

- **DriverEntry**: Isa, no access ranges, no HwInterrupt, HwAdapterState (SCSIPORT.PDR
  reports "Init Failure" without it), MapBuffers, NeedPhysicalAddresses, AutoRequestSense,
  one request per LU. The NT 4.0-sized `HW_INITIALIZATION_DATA`, as usosnvme's W9X build.
- **FindAdapter**: maps F0000h-FFFFFh with VMM `_MapPhysToLinear` (INT 20h, VMM 006Ch),
  scans 8-byte aligned for `CSMPPrxy`, takes `struct uds_channel` at +48 and requires magic
  `UDS1`. Otherwise `SP_RETURN_NOT_FOUND` (firmware CSM, CSMWrap before 3.1.2-usos16) with a
  debug line. One adapter only. No PCI access at all.
- **Uncached extension** (one block, page aligned): the `struct uds_req` at +0, the
  `struct uds_mp_status` page at +128 (`UDS_MP_STATUS_OFFSET`, so USOSDBG finds it through
  `channel.req_phys`), the ENUM table at +256, and the 64 KiB bounce buffer at +4096. Every
  page is checked with `ScsiPortGetPhysicalAddress`: below 4 GiB, and the bounce pages
  physically contiguous. If SCSIPORT.PDR hands out a split block, the bounce buffer (and
  `MaximumTransferLength`) shrinks to the contiguous run instead of failing.
  `channel.req_phys` is written once.
- **Config**: one bus, `MaximumNumberOfTargets` = slots, initiator ID 7, no scatter/gather
  (bounce), `MaximumTransferLength` 64 KiB, `CachesData` FALSE, bus master, 32-bit DMA.
- **Slots**: default 1. If SCSIPORT.PDR passes an argument string containing `SLOTS=n`
  (n = 1..4) that is used; whether and from where 9x passes one is unverified, so in
  practice the driver runs with one slot. Targets 0..slots-1 are the slots; other targets
  and LUN > 0 get `SRB_STATUS_SELECTION_TIMEOUT`.
- **Slot mapping**: after each ENUM, slot i serves the i-th device table entry (in table
  order) that is `UDS_DEV_PRESENT`, has `bios_drive == 0` and a non-zero generation. A slot
  with no such entry is fed `NULL` (empty). Sticks with a BIOS number stay with INT 13h.
- **ENUM**: at HwInitialize (waits up to 3 s; an unanswered ENUM is then left stale, so no
  SRB waits for a helper core that does not answer: the slot is empty, NOT READY / 3Ah, until
  the helper catches up and a TEST UNIT READY enumerates again), after a request ended `NODEV`/`GONE`/`OWNED`, after an eject, a watchdog or a bus
  reset, and at most once per second on TEST UNIT READY (TSC clock; without a TSC every
  8th TEST UNIT READY).
- **Requests**: fill the request, `seq = ++n`, locked-instruction fence, `doorbell = n`;
  done when `channel.done == n`. HwStartIo spins up to 2 ms (`ScsiPortStallExecution(50)`
  steps, interrupts never disabled by the driver), then returns and polls from
  `ScsiPortNotification(RequestTimerCall, ..., 1000 us)`. One SRB at a time; `NextRequest`
  only after it completed.
- **Timer fail-safe**: no 9x DDK text states that SCSIPORT.PDR calls a miniport timer back.
  The first SRB arms the timer as a probe; until `UsbTimer` has run once, HwStartIo waits
  for the whole request (bounded by the watchdog), which is what usosnvme's W9X build does
  for every request (proven on 98 SE in QEMU and on the X470). After the first callback the
  2 ms spin + timer path is used. A timer that fires while HwStartIo is running is re-armed
  and does nothing. On the X470 a `polled` counter above 0 in the USOSDBG DISK snapshot
  shows that the timer works.
- **Watchdog**: 15 s per posted request (TSC calibrated against `ScsiPortStallExecution`
  at HwInitialize; without a TSC the time spent spinning and in timer ticks is counted).
  On expiry the SRB completes with `SRB_STATUS_TIMEOUT`, the block stays the helper's
  (stale) until `done` reaches that sequence number: meanwhile commands that need the
  channel fail with NOT READY / 04h (INQUIRY / REQUEST SENSE still answer locally). After
  that the slot gets a UDS RESET before its next command.
- **Per SRB** (EXECUTE_SCSI) through `usosuds_slot.c`: `uds_slot_before()` decides.
  INQUIRY (fixed identity `USOS` / `USB disk slot n`, RMB = 1; EVPD refused) and REQUEST
  SENSE are answered locally; PREVENT/ALLOW and START STOP without LoEj are GOOD; an empty
  slot gives NOT READY / 3Ah; a new stick one UNIT ATTENTION / 28h; START STOP with LoEj
  posts UDS EJECT; the rest is sent (write data copied into the bounce buffer first, read
  data copied out after) and `uds_slot_after()` maps the result. CHECK CONDITION carries
  autosense (fixed format, 18 bytes) when IOS gave a sense buffer and did not set
  `SRB_FLAGS_DISABLE_AUTOSENSE`. `DataTransferLength = data_len - residue`; a short
  READ/WRITE is `SRB_STATUS_DATA_OVERRUN`, short INQUIRY/MODE SENSE data is a success.
  TIMEOUT/PHASE from the helper: CHECK ABORTED COMMAND, then one UDS RESET.
- **SRB flush / shutdown**: SYNCHRONIZE CACHE(10) to every present slot (not to one with a
  pending UNIT ATTENTION: IOS never wrote to that stick); a stick that refuses it is GOOD.
- **SRB reset bus / device**, **HwResetBus**: UDS RESET for present slots (HwResetBus
  marks them and resets before the next command, completing outstanding SRBs with
  `SRB_STATUS_BUS_RESET`).
- **HwAdapterState**: TRUE, nothing to save (the helper core owns the hardware); writes the
  counters to the debug port.
- **Status page** (`struct uds_mp_status`, version 1, 1.0): SRBs, posted, polled (found by
  the timer), errors, ENUMs, last UDS status, and per slot dev / present / UNIT ATTENTION
  pending / last CDB / SRB status / sense / generation / SRBs.
- Debug text goes to port E9h only when a debug console answers there (QEMU
  `-debugcon`), as in usosnvme.

## 1.1 (hot-swap, CSMWrap 3.1.2-usos17)

- Any command to an empty slot (not only TEST UNIT READY) asks the helper for the device table,
  at most once a second. A stick plugged in later (the usos17 port watch brings it up with a new
  generation) then gives one UNIT ATTENTION 06/28 on the same letter, and its data. With a usos16
  BOOTX64.EFI nothing changes: no runtime enumeration there.
- NOT READY / 3Ah answers of an empty slot are counted in `notready` (status page +100), not in
  `errors`.
- Request ring at `req_phys + 1024` (`struct uds_mp_ring`, 32 entries: CDB[0], slot, SRB / UDS
  status, LBA, bytes, CRC-32 of the data); status page version 2. USOSDBG 1.8 decodes both.

## Registry (`usosusb.reg`)

Registers a root devnode `HKLM\Enum\Root\SCSIAdapter\@CLASSIDX@` (Class SCSIAdapter,
HardwareID `USOSUSB`) and its driver key `HKLM\System\CurrentControlSet\Services\Class\SCSIAdapter\@CLASSIDX@`
(DevLoader `*IOS`, PortDriver `usosusb.mpd`). `@CLASSIDX@` is a placeholder: the flow
substitutes a 4-digit number (`0090`, `USOSUSB_CLASSIDX` in `w9x_csmwrap_target.sh`) in all
three places before the real-mode `REGEDIT /L:SYSTEM.DAT /R:USER.DAT` import (the REGBIND pattern of
`tools/tests/run_w9x_nvme_qemu.py`). The MPD itself goes to `C:\WINDOWS\SYSTEM\IOSUBSYS`.
The root instance is numeric, the form CONFIGMG itself writes and the one the usosnvme
`--regbind` QEMU run proved (`Root\SCSIAdapter\0000`); a high number keeps clear of
instances Windows created. (Until 2026-10-20 it was the unproven non-numeric `USOSUSB`.)

Write-behind cache: no documented 9x registry value for *removable* drives only was
identified, so the fragment sets none. The documented `DriveWriteBehind` value
(`HKLM\System\CurrentControlSet\Control\FileSystem`, `00 00 00 00` = the "Disable
write-behind caching for all drives" troubleshooting box) affects every drive including
C:, so it is not used. 98/Me show a separate "removable disk" write-behind checkbox in
System Properties > Performance > File System; check its state in the first VM run.

## Open points (to verify in QEMU / on hardware)

- SCSIPORT.PDR's support for `RequestTimerCall`. No longer a hang risk (timer fail-safe
  above); without it every request is synchronous, as in usosnvme.
- Whether IOS treats target 0 as a removable drive letter after the fixed disks, as with
  ZIP / card-reader slots, and keys the `Enum\SCSI` devnode on the fixed INQUIRY strings.
- That SCSIPORT.PDR's uncached extension is physically contiguous (usosnvme's 3-page block
  was; 18 pages here, with the shrinking fallback above).
- Whether HwStartIo runs with interrupts disabled under SCSIPORT.PDR (the 2 ms spin bound
  then matters for keyboard/mouse latency).

## Provenance and licence

Own implementation, GPL-3.0-or-later, "Copyright (C) 2026 Maksymilian and the USOS
Authors". Written from the public SCSI SPC / SBC command and sense definitions, the public
DDK documentation of the SCSI port / miniport interface (`miniport.h` / `srb.h` of WDK
7.1 as the interface definition), the USOS UDS ABI and the 9x-specific mechanics already
in usosnvme's W9X build (VMM `_MapPhysToLinear`, HwAdapterState, PE 4.00,
`/MERGE:INIT=.text`). No Microsoft source code was used for this driver.
