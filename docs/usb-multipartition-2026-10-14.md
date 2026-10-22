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
| Windows 2000 SP4 (UEFI/CSMWrap) | xhci98 usos3 + Microsoft usbhub20 / usbstor | first partition only | usosmpart (x86, NT 5 staging), MBR sticks; GPT sticks via an MBR view (host tests only) |
| XP SP3 / MCE / Tablet (XP CSMWrap) | Win8 usbxhci backport bundle + XP usbstor | first partition only | usosmpart (x86, NT 5 staging), MBR sticks; GPT sticks via an MBR view (host tests only) |
| POSReady 2009 | the same XP bundle (FIRST.CMD) | first partition only | usosmpart (x86, FIRST.CMD) - not run in QEMU |
| Server 2003 x86 / XP x64 / 2003 x64 | xhci98 usos2 + Microsoft usbstor | first partition only | usosmpart (x86 / amd64, NT 5 staging), MBR + GPT - not run in QEMU |
| Vista / Server 2008 SP2 x86 | own usosusb 1.1-nt6 (xHCI, own mass storage) | **already every partition** (one volume device per MBR primary / GPT entry, max 4, ESP/MSR skipped) | unchanged |
| Windows 7 / 8.x / 10 < 1703 x86 (CSMWrap x86) | Microsoft usbxhci (7: user's backport) + usbstor | first partition only | usosmpart (x86, `:mpart` WinPE step) |
| Windows 10 1703+ / 11 | Microsoft | every partition | unchanged (step skips build >= 15063) |
| Vista / 2008 x64 (test mode) | community USB3 backport + usbstor | first partition only | usosmpart `nt6x64` build, test-signed per build, CSMWrap path only (`docs/vista-x64-usb-multipartition-2026-10-21.md`) - host-tested, not run in QEMU / on the X470 |
| Windows 7 / 2008 R2 / 8.x x64 (native UEFI / UefiSeven) | Microsoft | first partition only | **blocked**: x64 kernel-mode code signing; a boot-start filter signed by a USOS per-build certificate loads only with test signing on, which these flows do not use. **Win7 x64: not supported, decided to leave** (user decision 2026-10-22); workaround: a fixed-disk enclosure / SSD shows every partition |
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
`python tools/tests/test_usosmpart_gpt.py` (host-only, needs gcc / cc /
clang / zig cc): the GPT-to-MBR builder `src/mpgpt.h` on synthetic images.

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
| GPT stick | unchanged on XP x86 (then: removable, one raw volume; since 2026-10-22 MBR view with lettered partitions, see below) |

One "Windows - Delayed Write Failed" balloon (`\...\DP(1)0-0+15`) appeared
earlier in the XP series after a run of quick device_del/device_add swaps
(mbr3 / mbr1 / GPT, Explorer windows open from AutoPlay); the files written
to the flipped stick before that were complete on the host, and the
dedicated copy-and-yank test above did not show it. Not attributed; worth a
look on hardware.

### GPT stick on 2000 / XP x86: hidden and write-blocked (2026-10-22, superseded by the MBR view below; still the fallback)

X470, XP SP3 (USOS install): with the Kingston USOS stick plugged in,
Explorer showed a removable disk with "0 bytes" and offered to format it.
Cause: not a partition the filter exposed. 2000 / XP x86 cannot use GPT data
disks: XP's disk.sys (`DiskDisableGpt` on x86) falls back to the MBR view, so
the protective MBR's single 0xEE entry is the disk's one partition, and on a
removable disk that partition gets a letter and mounts RAW. usosmpart left
GPT sticks alone there (the row above). A format would write over LBA 1 on:
the GPT and the ESP, then DATA.

The Kingston stick (read-only check from the dev PC, raw LBA 0-7): MBR =
one 0xEE entry (start 1, length 0xFFFFFFFF), the other three empty; GPT
ESP (C12A7328, FAT32 USOS_ESP), DATA (EBD0A0A2, NTFS USOS_DATA), WORK
(EBD0A0A2, NTFS USOS_WORK), all GPT attributes 0. The installer creates DATA
and WORK with "no drive letter" (bit 63) and clears it when the medium is
exposed (`installer/internal/winhost/gpt_buffer_windows.go`,
`gpt_postformat_verify_windows.go`), so an attribute rule cannot tell an
installed USOS stick's partitions apart. NT 5.2+ (2003, XP x64) and NT 6
read GPT and every partition of the stick is NTFS or FAT32, so they need no
change.

Fix (`MpHide`): on NT 5.0 / 5.1, a stick whose MBR holds nothing but the
0xEE entry is started as a fixed disk (like a multi-partition stick). On a
fixed disk the volume manager keeps a partition of an unrecognised type
hidden (no letter: the same view XP gives any GPT USB hard disk, "GPT
Protective Partition" in Disk Management). And the filter fails every SCSI
write command to that disk (WRITE 6/10/12/16, WRITE AND VERIFY, WRITE SAME)
with CHECK CONDITION, sense 07/27/00 (write protected), so Disk Management
or a format tool cannot change the protective MBR or the GPT. A hybrid MBR
(0xEE next to other entries) keeps the old path. MBR sticks are unchanged.

Other USOS USB paths: NT 3.x / NT 4 / Vista x86 `usosusb` builds one volume
per GPT partition and skips the 0xEE entry, MSR, ESP and entries with
attribute bit 63 / 62, so the stick's DATA and WORK appear (NTFS) and
nothing RAW. Windows 9x `USOSUSB.MPD` is a SCSI miniport; the 9x disk
layer reads the MBR itself, and what it shows for a GPT stick (an
unrecognised 0xEE entry on a removable SCSI disk) was not checked (the
miniport has not run in a 9x VM or on the X470 yet).

Status: built (WDK 7.1, x86 / amd64 / nt6x64, no warnings) and host tests
only; not run in an XP VM or on the X470, nothing deployed.

### GPT stick on 2000 / XP x86: MBR view, every partition lettered (2026-10-22, later)

Wanted instead of the hidden stick: DATA and WORK as normal drives on 2000 /
XP x86, as on every other USOS system. Change (`MpMap`, same branch,
replaces `MpHide` whenever the GPT can be mapped):

- At the descriptor query (before disk.sys reads the partition table) the
  filter reads the GPT through the PDO and builds an MBR from it
  (`tools/nt/usosmpart/src/mpgpt.h`, plain C shared with the host test):
  basic data + NTFS / exFAT boot sector = 0x07, FAT32 = 0x0C, FAT12/16 =
  0x0E, ESP = 0xEF (no letter on 2000 / XP, keeps it away from Explorer),
  MSR / other GPT types / attribute 63, 62, 60 / unknown file system left
  out, at most 4 entries, sorted. Disk signature = the protective MBR's, or
  the XOR of the GPT disk GUID's dwords (stable letters per stick).
- The disk starts as a fixed disk (as a multi-partition MBR stick); every
  SCSI READ (6/10/12/16) starting at LBA 0 is completed with bytes 440..511
  replaced by that MBR (completion routine, MDL mapped with
  `MmGetSystemAddressForMdlSafe`). Volumes, mount manager and file systems
  see an ordinary MBR disk.
- Writes: let through only when the whole range lies in one lettered
  partition (copying files to DATA / WORK, chkdsk, a format of the
  partition). LBA 0, the GPT header and entries, the backup GPT, the ESP and
  gaps fail as "write protected"; FORMAT UNIT / UNMAP / WRITE BUFFER /
  32-byte CDBs always fail, SCSI pass-through IOCTLs are refused (access
  denied) on such a disk.
- Fallback to `MpHide` (fixed, 0xEE hidden, no writes): header or entry
  CRC mismatch, entries outside the usable area or overlapping, any LBA
  beyond 32 bits / READ CAPACITY(10) saturated (> 2 TiB), or no partition
  that would get a letter. Hybrid MBR, MBR sticks and NT 5.2+ unchanged.

Expected on the USOS stick (Kingston / SanDisk layout above): ESP as an
unlettered 0xEF partition, USOS_DATA and USOS_WORK as NTFS drives.
Disk Management cannot change the stick's partitions (LBA 0 protected);
formatting a partition with a different file system may report an error
when Windows tries to update the partition type (the type is recomputed at
the next plug-in from the boot sector).

Host tests (`test_usosmpart_gpt.py`, gcc): USOS 3-partition layout
(entries, CHS FE FF FF, signature from the disk GUID, write rule at every
boundary incl. the backup GPT), MBR signature kept, attributes 63 / 62 / 60
(omitted, not writable; both hidden -> fallback), MSR / Linux / ext4 /
exFAT / FAT16, more than four partitions, > 2 TiB fallback (capacity,
entry, header), CRC damage, hybrid MBR, overlap, GPT larger than the
medium, 4 KiB sectors, CDB decoder. Rebuilt x86 / amd64 / nt6x64 (WDK
7.1, no compiler warnings); new imports `MmMapLockedPagesSpecifyCache`,
`MmSystemRangeStart` (Windows 2000 and later per the DDK documentation,
not rechecked against the 2000 SP4 binary in this round).

Status: host tests only; not run in an XP VM or on the X470, nothing
deployed. To check on XP: letters for DATA / WORK, file copy both ways,
Disk Management view, a write to `\\.\PhysicalDriveN` LBA 0 refused,
surprise removal.

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
| the real `:usbfix` block (run in the ISO's WinPE on the target after the Setup pass), then specialize / OOBE with the stick attached | PASS: `SetupComplete.cmd` written, Setup ran the helper as SYSTEM before the first logon (about 1 min, both PnP waits returned at once), log in `C:\USOS\Logs`, USBSTOR node restarted, stick lettered at the desktop |

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
