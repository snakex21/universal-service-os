<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# MiniOS on real hardware (experimental)

Opt-in per answer profile: `prep_env=minios` (default `setup`). The profile
must name an edition found on the ISO (`edition=`), because MiniOS applies one
install.wim image and has no edition list. Two routes read it:

| Route | Systems | Replaces |
| --- | --- | --- |
| `gpt_uefi` | Windows 10 / 11 x64, native UEFI | the ISO's WinPE + Windows Setup |
| `mbr_csmwrap` | 32-bit Windows 10, no CSM (`win-x86-uefi-csmwrap`) | Alpine micro-Linux step 610 + the ISO's x86 WinPE + Setup |

8.1 / Embedded 8.1 x86 and the 7 / Vista / 2008 x86 PE10-donor route stay on
Alpine. MiniOS always runs as `usosprep-x64.efi` (the menu is x64 on the
X470; an x64 MiniOS writes a 32-bit Windows disk).

## Flow (both routes)

1. UEFI menu, Start (src/platform/uefi/minios_start.zig): writes
   `\USOSPREP.CFG` (`USOSPREP_HW_V1`; `mode=gpt`, or `mode=mbr` +
   `csmwrap=on`) and the rendered profile answer `\USOSPREP.XML` (x86
   components on the CSMWrap route) to the USOS ESP, then starts
   `\EFI\USOS\minios\usosprep-x64.efi` (MOK-signed like the other helpers).
2. CSMWrap route only, before the disk question: `EFI\USOS\csmwrap\csmwrapx64.efi`
   must match the pinned 3.1.2-usos18 SHA-256 and its licence files must be
   there (same check as tools/xp_csmwrap_esp.sh); otherwise nothing is
   written.
3. The flow's one disk question is in the USOS menu
   (src/platform/uefi/minios_disk.zig: the menu's form style and language;
   the texts are the translated micro-Linux disk-picker strings): internal
   non-USB disks of at least 16 GiB with 512-byte sectors, the USOS stick
   excluded; CSMWrap route: at most 2 TiB (MBR), NVMe only when the usosnvme
   modern package is on the stick (`EFI\USOS\minios\nvme\`, step 6a). Then
   the erase confirmation. Cancel returns to the menu (no Alpine start, no
   second question). The disk goes to MiniOS by identity in USOSPREP.CFG
   (`disk_path=` hex device-path body, `disk_sectors=`, `ui=quiet`); MiniOS
   (takeMenuTarget) finds exactly that whole disk, repeats every check and
   asks nothing. A refusal writes nothing and fails the run; the menu logs
   it (minios-start.txt, MiniOS log) and starts its default path. With
   ui=quiet MiniOS prints nothing on the text console: the menu's page
   (heading "Windows 10 - MiniOS", stage "Preparing the disk") stays until
   the restart; after a fallback the heading reads "Windows 10 - Alpine",
   also on the micro-Linux pages. Without disk_path (a direct start) MiniOS
   keeps its own text question. The run's token goes to sector 0 of the
   chosen disk only; the strict size + token match follows.
4. The disk is wrapped in `hw_target.VirtualBlank` (chunks never written read
   as zeros, partial first writes zero the chunk, metadata regions are
   zero-filled), so the unchanged fresh-image writer runs without a
   full-disk wipe.
5. Layout and boot:
   - `gpt_uefi`: GPT (ESP 300 MiB + MSR + Windows), image applied and
     SHA-1 verified, boot files + BCD on the new ESP (`provisionUefi`), a
     `Windows Boot Manager` Boot#### first in BootOrder.
   - `mbr_csmwrap`: the install pipeline sees the disk only up to the
     CSMWrap ESP, so MBR slot 1 = 100 MiB NTFS system (active), slot 2 =
     NTFS Windows, both ending before it. Image applied and verified; then
     `provisionBios`: own MBR + NTFS PBR (tools/minios/bootcode, no
     Microsoft bytes; the PBR loads one verified contiguous BOOTMGR run,
     up to 960 sectors), `bootmgr` + `Boot\` from `Windows\Boot\PCAT`,
     fonts, and an offline BIOS BCD (REGF writer; MBR signature + partition
     offsets). The PBR does not load the NTFS file itself: a hash-checked
     copy of `\bootmgr` is pinned in the MBR gap (LBA 1024, at most 960
     sectors, before the 1 MiB system partition, outside every file system)
     and the PBR loads that copy, so Windows moving or updating `\bootmgr`
     later (servicing, defrag/optimise, chkdsk) cannot break the boot.
     BOOTMGR finds BCD through the BPB at 0x7c00 (system partition) with its
     own NTFS driver. Then the CSMWrap ESP at the end (64 MiB, the Alpine
     placement, FAT32 with 512-byte clusters): `EFI\BOOT\BOOTX64.EFI`
     (pinned hash checked again while copying), `EFI\BOOT\csmwrap.ini`
     (quiet unless `EFI\USOS\csmwrap-verbose.flag`), `CSMWRAP\` licences,
     source archive, patches. Its MBR slot 3 (type 0xEF) is published last
     and read back; a `Windows (USOS CSMWrap)` Boot#### for that ESP goes
     first in BootOrder (the Alpine route relies on the firmware's
     removable-path scan instead; on refusal that scan remains).
6a. CSMWrap route, NVMe target (src/prep/hw_nvme.zig): the same end state
   as the Alpine route's tools/windows_nvme_modern.cmd. Microsoft's inbox
   stornvme loses the disk under CSMWrap on the X470
   (docs/nvme-nt6-2026-10-12.md sections 13-20), so the stornvme service is
   pointed at the polled usosnvme (signed modern package of
   tools/build_windows_native_support.py). Offline, right after the image
   apply and before anything else: the package from the stick ESP into
   `\USOS\nvme-modern\` + `usosnvme.sys` into `System32\drivers`, and a
   same-length in-place edit of `ControlSet00N\Services\stornvme\ImagePath`
   in the SYSTEM hive (`System32\drivers\stornvme.sys` ->
   `...\usosnvme.sys`; clean base block required, no cell allocation, read
   back). The first boot therefore runs on usosnvme. Online, in specialize:
   one RunSynchronous command added to the answer runs
   `\USOS\nvme-modern\usos-nvme-online.cmd` (certificate into LocalMachine
   Root + TrustedPublisher, `pnputil /add-driver /install`, then ImagePath,
   Start 0, StartOverride 0, Parameters\PnpInterface 5 as the Alpine helper),
   log `\USOS\nvme-modern\online.log`; a PnP install of stornvme.inf during
   specialize therefore cannot leave the next boot on stornvme. Any refusal
   fails the run before the boot files, and the menu starts the Alpine route
   (which has its own NVMe path). Microsoft's stornvme.sys file is not
   changed. WinRE does not get the driver on this route.
6. `Windows\Panther\unattend.xml` from the profile is staged before the
   Windows volume is marked clean (specialize + oobeSystem; the windowsPE
   pass is not used). CSMWrap route: `\USOS\NT6\USOSRES.EXE` +
   `DISPLAY.TXT` (request from the answer's `<!-- USOS-DISPLAY= -->`, auto
   otherwise, `native=` from `EFI\USOS\display-native.txt`), registered by
   the USOS answer's specialize command as on the Alpine route; display=keep
   stages nothing. Optional: a failure keeps Windows' own mode.
7. Success: the menu restarts into the new Windows (specialize, OOBE).
   Cancel or any failure: the menu records the cause and starts the default
   path (Windows Setup, or the Alpine preparation on the CSMWrap route).

Logs: `EFI\USOS\Logs\minios-start.txt` (menu), `EFI\USOS\Logs\MINIOS-<build>.LOG`
and `\USOSPREP.LOG` (+ `.1`..`.3` older runs) on the USOS ESP. The new
Windows volume gets `\USOS\MINIOS-PREP.LOG` (the same log up to the end of
the image apply) and, on NVMe, `\USOS\nvme-modern\online.log` from
specialize. The DATA partition is not written from the UEFI side (the only
NTFS writer there is MiniOS's fresh-format writer, not meant for a live
user volume), so stick logs stay on the ESP.

## Not staged compared with the default paths

Both routes:

- DATA\Drivers INF packages (Setup path: drvload + offlineServicing
  DriverPaths). Inbox drivers only.
- `usos-run-hidden` wrapper for the profile's commands (they run, but
  console windows can be visible).
- ISO `sources\$OEM$` folders, the previous-install log check, a DATA
  Unattended XML file (only a USOS profile answer is staged).
- The windowsPE pass of the answer (disk, edition, key) is not used:
  MiniOS picks the disk and the image; a windowsPE product key is not
  applied (Windows OOBE may ask for it; it can be skipped).
- install.esd / split .swm media are refused (unsplit install.wim only).
- logon.ini is not copied to DATA (usos_logon_save; no NTFS writer for DATA
  on the UEFI side).

CSMWrap route, compared with Alpine step 610 + usos-x86-csmwrap.cmd:

- NVMe: no WinRE driver, no truncatememory (the installed client system
  does not need it); no PCI ID gate (the exact-ID INF binds only the Micron
  3400 and QEMU; other NVMe controllers keep the stornvme.inf binding with
  ImagePath on usosnvme).
- `hideesp` (no drive letter for the CSMWrap ESP in MountedDevices) is not
  done: the ESP and the 100 MiB system partition may get drive letters.
- DATA `display-keep.txt` is not read (profile display=keep is honoured).
- A user answer without the USOS display command gets USOSRES staged but
  not registered (Alpine registers it offline in the Default hive).
- Fast Startup: only the USOS answer's own setting (HiberbootEnabled in the
  answer); `fast-startup-on.txt` is honoured by the menu's render as before.
- usosmpart / usbreenum / USB3 KMDF / NT 6.0 steps do not apply to
  Windows 10 22H2 (also skipped on the Alpine route).
- BOOTMGR is the pinned MBR-gap copy of the ISO's version: a later
  `\bootmgr` update on the system partition is not picked up by the PBR
  (the old BOOTMGR keeps starting the updated winload); a disk tool that
  rewrites the MBR gap would break the boot.

## Provenance

Hardware mode by Claude on top of the Codex MiniOS import
(docs/minios-import-provenance.md); the BIOS boot provisioning, own boot
code and BCD writer are the imported Codex code (the BOOTMGR limit raised
to 960 sectors here).
2026-10-31 (Claude): the MBR-gap BOOTMGR pin and the NVMe staging
(src/prep/hw_nvme.zig: offline SYSTEM-hive ImagePath edit read from the
public REGF format, specialize script) reproduce the end state of the
existing USOS Alpine-route helper (tools/windows_nvme_modern.cmd /
windows_nvme_modern.c); no Microsoft code. Host-tested only (synthetic hives
plus one real Windows 10 22H2 x86 SYSTEM hive read locally, not stored);
X470 is the acceptance gate. No Microsoft code or binaries in the repository; the
BIOS boot files are copied at run time from the applied Windows image.

## Stick switch and MiniOS-only test deploys (2026-10-31)

- `EFI\USOS\win9x\minios.flag` on the USOS ESP (next to nt3-native /
  nt4-native / phase1-native): Windows 10 x86 without CSM goes through
  MiniOS by default, without a profile. No profile edition: the menu asks
  for the edition (USOS list "Edition", from the ISO's images; one image is
  taken without asking), then the one disk question. Without the flag and
  without `prep_env=minios`, nothing changes (Alpine).
- With the flag or `prep_env=minios`, a MiniOS failure never starts Alpine:
  MiniOS writes `EFI\USOS\Logs\minios-result.txt` (`stage=`, `reason=`;
  stages: CSMWrap check, target disk, ISO on DATA, image apply, NVMe
  driver, boot files, CSMWrap partition), the menu shows the translated
  error page "MiniOS nie zakończył pracy" (stage, reason, log
  `EFI\USOS\Logs\MINIOS-<build>.LOG`) and returns to the menu.
- A MiniOS-only deploy (deploy script `-MiniOsOnly`) removes
  `EFI\USOS\micro-linux\vmlinuz-virt`, `initramfs-usos` and `qemu9x.cpio`
  from the stick ESP and records it in `EFI\USOS\minios-only.txt`; every
  micro-Linux start then shows "This USB drive has no micro-Linux
  preparation environment" (boot.lx.minios_no_alpine) instead. The next normal
  deploy writes the full payload again (the updater rewrites every payload
  file) and removes the marker.
- First X470 run (B261031-144307): MiniOS refused the DATA volume
  (`UnsupportedVolumeState`): its `$Volume` flags were 0x0080, which
  Windows 10 leaves on a volume removed without a dismount (`fsutil dirty`:
  not dirty). The read-only NTFS reader now accepts 0x0080.

## 2026-10-31: RTC local time -> UTC file times (rtc_shift)

X470 B261031-200222: files MiniOS wrote were one hour ahead. The RTC holds
local time (Windows' convention); `usosprep` took `GetTime()` as UTC for every
NTFS timestamp (`src/prep/uefi_main.zig` `Output.checkedClock`).

- The USOS menu now computes local minus UTC for "now" from the flow's time
  zone (`src/flow/rtc_zone.zig`): the profile's `timezone`, else the media
  language's default zone (`tables.timeZoneForLanguage`), standard offset from
  the zone label, DST by rule (EU: last Sunday of March / October 01:00 UTC;
  US / Canada: second Sunday of March 02:00 local to first Sunday of November
  02:00 daylight; other zones: standard offset only). Without a zone (a user
  answer file and no profile): `EFI_TIME.TimeZone` when not 2047 (UEFI 2.7+
  Localtime = UTC + TimeZone, +1 h with EFI_TIME_IN_DAYLIGHT); else 0 (as
  before). The menu logs one `clock:` line in `minios-start.txt`.
- It hands it to MiniOS as `rtc_shift=<seconds>` (`minios_plan.appendClock`,
  both routes); `usosprep` subtracts it (`HW ... rtc_shift=` in the MiniOS
  log).
- Tests: zig tests in `src/flow/rtc_zone.zig` (labels, Warsaw winter /
  summer and both change days, US change days, Tokyo, Moscow no DST, EFI
  fallback, civil-day math) and `minios_plan.appendClock`.
- Alpine: by code reading it has the same offset. The micro-Linux sets no
  time zone and runs no `hwclock --localtime`; the kernel reads the RTC as UTC,
  so ntfs-3g stamps local time as UTC there too. Not changed (Alpine is the
  fallback being replaced).

## 2026-10-31: disk picker and erase confirmation = Alpine content

**Why no `identity=` line in B261031-185528:** the identity code did run
(`collect` -> `readIdentity` in `src/platform/uefi/minios_disk.zig`), but
every line of the disk question went only to `serial.writeAscii`
(`src/platform/uefi/serial.zig`: the EFI_SERIAL_IO UART, nothing else). The X470
has no serial capture, and `minios-start.txt` keeps one replaced line
(`minios_start.zig` `record`). `MINIOS-<build>.LOG` is MiniOS's own log
(usosprep), written after the menu. So the lines never reached any file.
Now each line also goes to `EFI\USOS\Logs\minios-disks.txt` (written after
the scan, after the inspection and after the confirmation), one line per
probe attempt: `identity disk=N probe=nvme_passthru|ata_passthru|usb_io|disk_info
protocol=yes|no status=<EFI status or reason> interface=... model="..."
serial_known=true|false`, then `identity disk=N source=...`. The serial
number is never logged.

Probe fixes at the same time: the ATA pass-thru sector count was written to
ACB byte 14 (reserved), now byte 12 (`AtaSectorCount`); ACB/ASB are 64-byte
aligned static blocks (IoAlign); IDENTIFY strings must be printable text, so
the EDK2-style NVMe `EFI_DISK_INFO.Identify` (it returns Identify *Namespace*
data) no longer turns binary NSZE/NCAP bytes into a model name. NVMe goes
through `LocateDevicePath(EFI_NVM_EXPRESS_PASS_THRU)`, which walks the
namespace path up to the controller handle (PciRoot/Pci) that carries the
protocol. The remaining node must be the NVMe namespace node. AHCI without
EFI_ATA_PASS_THRU falls back to `EFI_DISK_INFO` (AHCI/IDE interface, IDENTIFY).

Parity (Alpine: `tools/xp_menu_ui.sh` usos_xp_choose_disk,
`tools/target_disk_identity.sh`, `tools/xp_disk_overview.sh`,
`tools/xp_detect_system.sh`, `tools/vista_csmwrap_prepare.sh`; MiniOS:
`minios_disk.zig`, `src/flow/minios_disk_identity.zig`,
`src/flow/minios_fs_probe.zig`):

| Alpine field | Alpine source | MiniOS field / source | Status |
|---|---|---|---|
| Picker title `<model> (<n> GiB)` | lsblk MODEL / sysfs model | NVMe Identify Controller MN, ATA IDENTIFY words 27-46, USB INQUIRY product / iProduct, DISK_INFO | same; on hardware depends on which protocols AMI installs (see log) |
| Picker detail `S/N: ...` | lsblk SERIAL / vpd_pg80 / USB serial | NVMe SN, ATA words 10-19, USB iSerialNumber | same |
| Bus chip (nvme/sata/usb/...) | TRAN / host driver | device path node, else DISK_INFO interface | same (no virtio/emmc/sd split) |
| Media chip ssd/hdd | NVMe = ssd; smartctl word 217, else rotational | NVMe = ssd; IDENTIFY word 217 | no rotational fallback (no SSHD from word 78) |
| `Disk:` / `Type:` / `S/N:` / `Size: N GiB` | as above | as above | same |
| `Status: not currently in use.` | findmnt / swaps / holders | fixed text (the USOS stick and refused disks are not offered) | same text |
| `Partitions: n; unallocated: approx. M MiB` | lsblk parts, merged extents | GPT entries / MBR + EBR chain; extended = 2 sectors as sysfs | same (sum, not merged) |
| `Readable file systems: k; used U MiB, free F MiB` / `...unknown.` | df of the ro mounts | sums of the probes below | same |
| `<node>: <fstype> <label> (<MiB> MiB)` (first 4) | lsblk FSTYPE / LABEL | `Partition <n>:` (Linux number), boot sector / superblock type, label filtered like `tr -cd`, 18 chars | node name differs (no Linux name); no double space for an empty label |
| fs types | blkid | ntfs, vfat (FAT12/16/32), exfat, ext2/3/4, swap, xfs, btrfs, BitLocker, else unknown | others (e.g. hfsplus, iso9660) show `unknown` |
| `Used: X MiB, free: Y MiB` | df on ntfs3 / vfat / ext4 | NTFS $Bitmap set bits (<= 64 MiB bitmap); FAT FSInfo, else FAT entries counted (<= 32 MiB FAT); ext superblock blocks/free/reserved | ext: metadata overhead not subtracted (df bsddf), small difference |
| `Used/free: unknown` | not mountable | exfat, swap, xfs, btrfs, BitLocker, read failures | same |
| System: `Windows (system files)` / `XP installation files` / `Windows boot files` / `No system detected` | marker files on the mount | NTFS via `usos.storage.ntfs`, FAT12/16/32 via own directory walk (<= 512 clusters per directory) | same markers |
| System: `Linux: <PRETTY_NAME>` | /etc/os-release | not read (no ext reader in the menu): `System unknown` | missing |
| `(Other partitions: n)` | count > 4 | same | same |
| `File detection does not verify whether a system works.` | fixed | same | same |
| `New layout (MBR): ...` | vista_csmwrap_prepare.sh arithmetic | `csmwrapFreeGib` (same arithmetic) | same |

The inspection runs once per disk when it is chosen (Alpine: "Inspecting
disk", after the picker), read only, with a 96 MiB read budget per disk.
Host tests: `tools/zig/zig.exe test src/flow/minios_disk_identity.zig`
(includes `minios_fs_probe.zig`). Only the X470 can show which identity
protocols AMI installs for the AMD AHCI, the Micron 3400 and USB disks, and
the real used/free values: read `minios-disks.txt` after the next run.
