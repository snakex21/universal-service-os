# usosmpart - USOS USB multi-partition disk filter (Windows 2000 to 10 1607)

Own GPL-3.0-or-later code (Copyright (C) 2026 Maksymilian and the USOS
Authors). Source: `src/usosmpart.c`; status and test results:
`docs/usb-multipartition-2026-10-14.md`.

## Problem

Windows before 10 1703 shows only the first partition of a disk that reports
removable media. Most USB sticks report removable media (SCSI INQUIRY RMB = 1),
so a multi-partition stick (the USOS stick: ESP + DATA + WORK) shows a single
volume in 2000, XP, Server 2003, Vista, 7, 8.x and 10 up to 1607. USB hard
disks (RMB = 0) already get every partition.

## What the driver does

A WDM lower filter of the disk class (`{4D36E967-E325-11CE-BFC1-08002BE10318}`
`LowerFilters`), so it sits between `disk.sys` and the PDO of the USB
mass-storage port driver:

1. `AddDevice` attaches only when the PDO's enumerator is `USBSTOR`. Every
   other disk (SATA / NVMe / IDE / SCSI, the boot disk) builds its stack
   without the filter.
2. When `disk.sys` asks for the device descriptor
   (`IOCTL_STORAGE_QUERY_PROPERTY`, `StorageDeviceProperty`) and the answer is
   `BusType = BusTypeUsb` with `RemovableMedia = TRUE`, the filter reads the
   media itself through the PDO (READ CAPACITY(10), READ(10) of the MBR, and
   of the GPT header + entries on NT 5.2 and later) and counts the
   partitions.
3. More than one partition: `RemovableMedia` is cleared in the answer, so the
   disk starts like a USB hard disk and every partition gets a device and a
   drive letter. One partition, a superfloppy, no media or an unreadable
   table: the answer is passed on unchanged (today's behaviour).

## What does not change

- **Hot plug and safe removal.** "Safely Remove Hardware" lists the USB
  device because of its PnP capabilities (Removable / SurpriseRemovalOK),
  which come from the USB hub driver; surprise removal removes the whole disk
  stack, every partition device, every volume and every letter. The filter
  takes part in PnP like any filter (remove lock, `IRP_MN_REMOVE_DEVICE`
  detaches and deletes).
- **Write caching / quick removal.** The class driver turns the device write
  cache off and the file systems use deferred / write-through flushing when
  the device's *removal policy* is "expect surprise removal" (the hot-plug
  info `DeviceHotplug`); the PnP manager derives that policy from the USB
  device node, not from `RemovableMedia`. A flipped stick therefore keeps the
  "Optimize for quick removal" policy that USB hard disks get today
  (`IOCTL_STORAGE_GET_HOTPLUG_INFO` reports `DeviceHotplug = 1` in the QEMU
  test). Only `MediaRemovable` becomes 0.
- **Single-partition sticks, card readers with an empty slot, superfloppies**
  stay removable.

## Limits

- A card reader whose card held more than one partition when the reader was
  plugged in becomes a fixed disk: a card swap is not seen until the reader is
  unplugged (the filter decides once per device start).
- GPT media count only on NT 5.2 and later; Windows 2000 / XP x86 cannot
  use GPT data disks, so a GPT stick (the USOS stick) stays as it is there.
- Windows Vista / 7 / 8.x **x64** enforce kernel-mode code signing for a
  boot-start filter: the x64 build loads only on XP x64 / Server 2003 x64 and
  on x64 NT 6 systems running with test signing (USOS Vista x64). Windows 7 /
  8.x x64 without test mode do not get it (see the status doc).
- Opt-out: `HKLM\SYSTEM\CurrentControlSet\Services\usosmpart\Parameters`
  `Disabled` (REG_DWORD) = 1, then reboot.

## Builds

| Build | Folder | Target | For |
|---|---|---|---|
| `x86`   | `bin/i386`  | WDK 7.1 "x86 WXP" | Windows 2000 / XP / Server 2003 / 7 / 8.x / 10 (before 1703) x86 |
| `amd64` | `bin/amd64` | WDK 7.1 "x64 WNET" | XP x64 / Server 2003 x64 |
| `nt6x64` | `bin/NT6/amd64` | WDK 7.1 "x64 WLH" | Vista / Server 2008 SP2 x64 in test mode (signed per build, see below) |

Build: `tools\nt\usosmpart\build.cmd all` (`WDKROOT` if `tools\WinDDK71` is
elsewhere). The x86 imports resolve on the Windows 2000 SP4 kernel (checked
against the 2000 SP4 `ntoskrnl.exe`).

## Where USOS installs it

- NT 5 (2000, XP, XP x64, Server 2003 x86/x64, MCE, Tablet; BIOS and UEFI
  flows): `tools/nt5_usosmpart_stage.sh`, called by
  `tools/prepare_xp_ntfs_target.sh` - the file in the local source, an own
  hive INF (`usosmpt.inf`) through TXTSETUP.SIF `[HiveInfs.Fresh]`.
- Windows 7 / 8.x / 10 before 1703 x86 (CSMWrap x86 path):
  `tools/windows_x86_csmwrap.cmd` step `:mpart` (offline registry from WinPE,
  appended to the existing disk class `LowerFilters`).
- Vista / Server 2008 SP2 x64 (CSMWrap path, test mode): the `nt6x64` build,
  embedded-signed with the per-build usosnvme amd64 certificate
  (`tools/build_usosnvme_nt6_signed.py`), registered offline by
  `usos-vista-install.exe` after the target BCD got testsigning
  (`tools/windows_vista_mpart.h`, docs/vista-x64-usb-multipartition-2026-10-21.md).
- Vista / Server 2008 x86 do not need it: their USB stack is USOS's own
  `usosusb` (one volume device per partition).

## Provenance

Written from the public WDK documentation (WDM filter drivers, remove locks,
`IOCTL_STORAGE_QUERY_PROPERTY`, `SCSI_REQUEST_BLOCK`) and the MBR / UEFI GPT
on-disk formats. To confirm which descriptor field selects the removable
path in the disk class driver, that USB mass storage sets no removable
device characteristic of its own, and that the quick-removal policy follows
the removal policy rather than `RemovableMedia`, the user-supplied NT 5
sources (disk, classpnp, usbstor, fastfat, PnP manager) were read for local
diagnosis under the project's source-analysis policy. No code from them is
in this driver; it is not described as a clean-room implementation.
