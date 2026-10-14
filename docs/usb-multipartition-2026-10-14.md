# Every partition of a USB stick in old Windows (2026-10-14)

Status: implemented, QEMU-tested (see "Tests"); X470 Windows 7 SP1 x86
2026-10-14: every partition after a replug, but the stick present during the
installation stayed invisible until that replug -> `:usbfix` (usos-usbreenum,
QEMU only, see "X470: Windows 7 SP1 x86").

## Problem

Windows before 10 1703 shows only the first partition of a disk that reports
removable media (SCSI INQUIRY RMB = 1, nearly every USB stick). The USOS stick
(GPT: ESP + DATA + WORK) shows only one volume in the old Windows that USOS
installs, and so does any multi-partition pendrive.

## Inventory: USB storage stack per family

| Family (USOS flow) | USB storage stack | Multi-partition sticks before this change | Now |
|---|---|---|---|
| Windows 2000 SP4 (UEFI/CSMWrap) | xhci98 usos3 + Microsoft usbhub20 / usbstor | first partition only | usosmpart (x86, NT 5 staging), MBR sticks |
| XP SP3 / MCE / Tablet (XP CSMWrap) | Win8 usbxhci backport bundle + XP usbstor | first partition only | usosmpart (x86, NT 5 staging), MBR sticks |
| POSReady 2009 | the same XP bundle (FIRST.CMD) | first partition only | usosmpart (x86, FIRST.CMD) - not run in QEMU |
| Server 2003 x86 / XP x64 / 2003 x64 | xhci98 usos2 + Microsoft usbstor | first partition only | usosmpart (x86 / amd64, NT 5 staging), MBR + GPT - not run in QEMU |
| Vista / Server 2008 SP2 x86 | own usosusb 1.1-nt6 (xHCI, own mass storage) | **already every partition** (one volume device per MBR primary / GPT entry, max 4, ESP/MSR skipped) | unchanged |
| Windows 7 / 8.x / 10 < 1703 x86 (CSMWrap x86) | Microsoft usbxhci (7: user's backport) + usbstor | first partition only | usosmpart (x86, `:mpart` WinPE step) |
| Windows 10 1703+ / 11 | Microsoft | every partition | unchanged (step skips build >= 15063) |
| Vista / 2008 x64 (test mode) | community USB3 backport + usbstor | first partition only | **open**: amd64 build exists; the Vista x64 path is the frozen hardware-success pipeline, not touched |
| Windows 7 / 2008 R2 / 8.x x64 (native UEFI / UefiSeven) | Microsoft | first partition only | **blocked**: x64 kernel-mode code signing; a boot-start filter signed by a USOS per-build certificate loads only with test signing on, which these flows do not use |
| 95 / 98 / ME | SeaBIOS BIOS disk (stick plugged before power-on); 98 SE opt-in xhci98 + NUSB (user files) | DOS/9x drive letters per BIOS disk partition (MBR only; GPT sticks not readable) | unchanged |
| NT 3.x / NT 4.0 | no USB mass storage (usosusb HID only) | - | unchanged |

## Fix: usosmpart.sys

Own GPL-3.0-or-later WDM disk class lower filter, `tools/nt/usosmpart`
(README there has the design, limits and provenance). In short:

- attaches only to disks whose PDO enumerator is `USBSTOR` (every other disk,
  the boot disk included, builds its stack without it);
- on the disk class driver's `IOCTL_STORAGE_QUERY_PROPERTY`
  (StorageDeviceProperty) with `BusType = USB`, `RemovableMedia = TRUE`, it
  reads the media through the PDO (READ CAPACITY(10), MBR, GPT on NT 5.2+)
  and only when there is more than one partition clears `RemovableMedia` in
  the answer and `FILE_REMOVABLE_MEDIA` on the devices of that stack (Windows
  7's usbstor PDO carries the bit and the PnP manager copies it up the stack
  before the disk starts; XP's does not);
- single-partition sticks, superfloppies and empty card-reader slots are not
  changed;
- hot plug, "Safely Remove Hardware" and the quick-removal write policy depend
  on the USB device node's PnP capabilities and removal policy, not on
  `RemovableMedia`, and are unchanged (`IOCTL_STORAGE_GET_HOTPLUG_INFO`
  `DeviceHotplug = 1` on the flipped stick, as on a USB hard disk).

Installation:

- NT 5 (all flows through `prepare_xp_ntfs_target.sh`):
  `tools/nt5_usosmpart_stage.sh` - file in the local source, own ASCII hive
  INF `usosmpt.inf` via TXTSETUP.SIF `[HiveInfs.Fresh]` (boot-start service,
  group "Filter", disk class `LowerFilters = usosmpart`); HIVESYS.INF (UTF-16
  on localized CDs) is not edited.
- POSReady 2009: `tools/posready_first.cmd` registers it at FBA time (driver
  copied with `DRV\*.sys`).
- 7 / 8.x / 10 < 1703 x86: `tools/windows_x86_csmwrap.cmd` `:mpart`, offline
  registry in WinPE, appended to an existing `LowerFilters` (EhStorClass).

Opt-out on an installed system: `Services\usosmpart\Parameters\Disabled = 1`.

## Tests

`python tools/tests/test_usosmpart.py` (host-only): builds, imports, staging
rows, apply on stand-in targets, wiring.

QEMU (`tools/tests/run_usosmpart_qemu.py`, WHPX, i440FX, EHCI + usb-storage
removable=on, 3 x 64 MiB FAT16 partitions): results below.

### Windows 7 Ultimate SP1 PL x86 (QEMU PASS, 2026-10-14)

Installed from the ISO with an answer file (not through the USOS stick
flow); at the first logon the `:mpart_reg` rows of
`tools/windows_x86_csmwrap.cmd` ran on the live registry (the WinPE `:mpart`
wrapper with `reg load` was not run in QEMU). Disk class `LowerFilters` was
empty before, `usosmpart` after.

| Check | Result |
|---|---|
| boot with the filter (boot disk IDE, not attached) | PASS, every boot |
| 3-partition MBR stick (removable=on), first driver build (descriptor only) | `RemovableMedia` 0 but **one volume** (E:, type removable): Windows 7's usbstor PDO carries `FILE_REMOVABLE_MEDIA` and PnP copies it to the disk FDO |
| same, final build (bit cleared on the stack) | PASS: E:/F:/G: = MP3/MP1/MP2, all type fixed, `parts=3/4` |
| write + read back 1 MiB on each of the 3 volumes | PASS |
| surprise removal (device_del) | PASS: every letter gone |
| re-plug (device_add), read back the earlier files | PASS |
| copy explorer.exe / regedit.exe to two volumes, yank 3 s later without safe removal, check on the host | PASS: both files complete (FAT chain, size, MZ) |
| hot-plug info of the flipped stick | `MediaRemovable 0, DeviceHotplug 1` (quick-removal policy kept) |
| single-partition stick | unchanged: `RemovableMedia 1`, type removable |
| GPT stick (ESP + 2 basic data) | PASS: both data partitions lettered, ESP without letter (normal Windows GPT behaviour) |
| "Safely Remove Hardware" | lists the device and, on Stop, all three volumes; the stop itself ends with "device is not removable" - **the same with the filter disabled** (`Disabled = 1`, single-volume stick) on QEMU's EHCI root port and behind a QEMU usb-hub, so a QEMU usb-storage / Windows 7 limitation, not the filter. Not proven positive in QEMU |

### XP Tablet PC Edition 2005 SP3 EN through the USOS NT 5 chain (QEMU PASS, 2026-10-14)

The XP package's real preparation chain (`run_usosmpart_qemu.py prepare-xp`:
XP package initramfs from the usos-x470-98se zig-out of 2026-10-14 00:58 + this tree's
`prepare_xp_ntfs_target.sh` / `nt5_usosmpart_stage.sh` + the usosmpart
files): log `[NT5_MPART] APPLIED PASS usosmpart.sys (i386)`; text mode,
GUI Setup (key page left empty with Setup's own "No"), OOBE by hand, desktop.
The Pro SP3 PL ISO was prepared too but stopped at the key page (no Pro key
at hand), so the Tablet ISO + bundle was used (same XP flow).

| Check | Result |
|---|---|
| text mode copies the file, `usosmpt.inf` registers service + disk class `LowerFilters` | PASS (filter loaded at every boot from the first GUI boot on) |
| boot with the filter, IDE boot disk | PASS |
| hot-plugged 3-partition MBR stick (EHCI, removable=on), first build | PASS: E:/F:/G: = MP1/MP2/MP3, fixed, `DeviceHotplug 1` |
| final build (copied over, reboot with the stick attached = cold plug) | PASS: E:/F:/G: |
| write + read back 1 MiB on each volume; surprise removal; re-plug; read back | PASS |
| "Safely Remove Hardware" | PASS: lists "USB Mass Storage Device", Stop lists the 3 volumes + disk, device stops and leaves the list, letters gone |
| copy shell32.dll (8.4 MB) + notepad.exe to two volumes, yank 3 s later | PASS: no "Delayed Write Failed", both files complete on the host |
| single-partition stick | unchanged (removable, type removable) |
| GPT stick | unchanged on XP x86 (as designed: removable, one raw volume) |

One "Windows - Delayed Write Failed" balloon (`\...\DP(1)0-0+15`) appeared
earlier in the XP series after a run of quick device_del/device_add swaps
(mbr3 / mbr1 / GPT, Explorer windows open from AutoPlay); the files written
to the flipped stick before that were complete on the host, and the
dedicated copy-and-yank test above did not show it. Not attributed; worth a
look on hardware.

### X470: Windows 7 SP1 x86 (2026-10-14, B261014-195920)

Windows 7 SP1 x86 installed on the Micron NVMe (usosnvme NT 6 no-interrupt
build) through the CSMWrap x86 flow with the USOS SanDisk stick (GPT: ESP,
DATA NTFS, WORK NTFS) plugged in the whole time:

- multi-partition works: after **one unplug / replug** the stick appeared
  with its partitions (usosmpart flipped it), and from then on it came up at
  every boot; a Goodram stick plugged in later was visible at once;
- **but** right after the installation the stick was not visible at all, and
  a restart did not change that.

A boot builds every device stack again; a replug also creates the device
node again and installs it. So the state that survived the restart was in
the device node (install / problem flags), not in a stack or the filter
order. The filter was **not** registered after the node was created: `:mpart`
runs in WinPE after `Setup /noreboot`, before the installed system's first
boot, so specialize already installs the stick with usosmpart in place.

#### QEMU (repro attempt and simulation)

pc + qemu-xhci only (as the X470), Windows 7 Ultimate SP1 PL x86 from the ISO
(answer on a floppy), Setup's WinPE pass stopped at its reboot, then in the
ISO's WinPE exactly what `:usb3` + `:mpart` do offline (KMDF 1.11 + the
user's x86 xHCI backport via DISM, usosmpart + LowerFilters via `reg load`),
then the first boot with a GPT 3-partition usb-storage stick (removable=on)
attached from the start:

| Check | Result |
|---|---|
| X470 symptom reproduced? | **No.** After specialize / OOBE the stick was there: `removable=0 style=1 partitions=3`, two lettered fixed volumes, USBSTOR node started, problem 0 |
| simulated install failure: USBSTOR node `ConfigFlags = 0x40` (FAILEDINSTALL), `Service` / `Driver` removed (as SYSTEM), restart | stick invisible after the restart, node `problem=28 configflags=0x40` = the X470 pattern (a boot does not retry a failed install) |
| `usos-usbreenum.exe` (fix mode, as SYSTEM) on that state | PASS: node removed, tree re-enumerated with retry installation, "device ready" balloon, node `service=disk started=1 problem=0 configflags=0`, disk `removable=0 partitions=3`, volumes back |
| second fix-mode run on the healthy stick | USBSTOR node restart ok, stick stays, volumes unchanged |

So the root cause on the X470 is not proven (QEMU does not show it; the
X470-only parts are real xHCI timing, the SanDisk and the CSMWrap SeaBIOS
that used the stick as the boot disk just before). The fix covers the state
that matches the symptom and logs the real one on the next X470 install.

#### Fix: usos-usbreenum (`:usbfix`)

Own helper `tools/windows_usb_reenum.c` (x86, SetupAPI / CfgMgr32, no
window). `usos-x86-csmwrap.cmd` `:usbfix` (called by `:mpart` after the
offline registration, so on 7 / 8.x / 10 < 1703 x86) copies it to
`Windows\Setup\Scripts` and writes `SetupComplete.cmd` (or puts one call
line before the lines of the image's own, which may end with `exit`), so it
runs once as SYSTEM after Setup, before the first logon:

1. waits for pending PnP installs (`CMP_WaitNoPendingInstallEvents`);
2. logs every present `USB\` / `USBSTOR\` node (service, status, problem,
   ConfigFlags), every USB disk (removable media, partition style and count,
   offline / read-only attribute) and the volumes;
3. a node with an install problem (CM_PROB 1 / 18 / 28 or ConfigFlags
   REINSTALL / FAILEDINSTALL) is removed (`DIF_REMOVE`, like an unplug) and
   the tree is re-enumerated with `CM_REENUMERATE_RETRY_INSTALLATION` (the
   device comes back as new and is installed: a replug);
4. a node with another problem (not "disabled") and every working `USBSTOR\`
   node is restarted (`DIF_PROPERTYCHANGE` / `DICS_PROPCHANGE`);
5. logs the state again.

Log: `C:\USOS\Logs\usos-usbreenum.log`, and a copy in `EFI\USOS\Logs` of the
stick's first partition when that folder exists. `usos-usbreenum.exe report`
= steps 1-2 to stdout only (read-only).

Windows 8.x / 10 ignore `SetupComplete.cmd` when the product key is an OEM
key; the stick then stays as it is today. NT 5 (2000 / XP / 2003, text-mode
registration) and POSReady get no `:usbfix`: their filter is in place from
text mode on and no NT 5 report of this symptom exists; the helper itself
links only XP-era APIs, but the build has the NT 6 subsystem version.

Host test: `python tools/tests/test_windows_usb_reenum.py`.

### Not tested

- X470 hardware for `:usbfix` (nothing deployed; no stick or disk written).
- Windows 2000, Server 2003, XP x64 / 2003 x64 (amd64 build), POSReady,
  Windows 8.x / 10 < 1703 x86; the WinPE `:mpart` wrapper (`reg load`) itself.
- NTFS / exFAT sticks (FAT16 only in QEMU), sticks with logical partitions.

Images deleted after the runs.
