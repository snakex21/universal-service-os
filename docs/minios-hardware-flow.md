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
3. MiniOS asks the one disk question (text console): internal disks of at
   least 16 GiB with 512-byte sectors, the USOS stick excluded; CSMWrap
   route: also no NVMe disk (Alpine gates 32-bit Windows 10 on NVMe behind
   its usosnvme-modern package) and at most 2 TiB (MBR). 3 s delay, then
   Space confirms, Esc cancels with nothing written. The run's token goes to
   sector 0 of the chosen disk only; the strict size + token match follows.
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
     offsets). Then the CSMWrap ESP at the end (64 MiB, the Alpine
     placement, FAT32 with 512-byte clusters): `EFI\BOOT\BOOTX64.EFI`
     (pinned hash checked again while copying), `EFI\BOOT\csmwrap.ini`
     (quiet unless `EFI\USOS\csmwrap-verbose.flag`), `CSMWRAP\` licences,
     source archive, patches. Its MBR slot 3 (type 0xEF) is published last
     and read back; a `Windows (USOS CSMWrap)` Boot#### for that ESP goes
     first in BootOrder (the Alpine route relies on the firmware's
     removable-path scan instead; on refusal that scan remains).
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
and `\USOSPREP.LOG` (+ `.1`..`.3` older runs) on the USOS ESP. The DATA
partition is NTFS and has no UEFI-side writer, so logs stay on the ESP.

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

- No NVMe targets (usosnvme-modern, truncatememory): such disks are not
  offered; the menu then falls back to Alpine.
- `hideesp` (no drive letter for the CSMWrap ESP in MountedDevices) is not
  done: the ESP and the 100 MiB system partition may get drive letters.
- DATA `display-keep.txt` is not read (profile display=keep is honoured).
- A user answer without the USOS display command gets USOSRES staged but
  not registered (Alpine registers it offline in the Default hive).
- Fast Startup: only the USOS answer's own setting (HiberbootEnabled in the
  answer); `fast-startup-on.txt` is honoured by the menu's render as before.
- usosmpart / usbreenum / USB3 KMDF / NT 6.0 steps do not apply to
  Windows 10 22H2 (also skipped on the Alpine route).
- The BOOTMGR binding is a fixed physical run: a Windows update that
  rewrites `\bootmgr` on the system partition to another place makes the
  own PBR load a stale run (needs reprovisioning; the Microsoft PBR walks
  NTFS instead).

## Provenance

Hardware mode by Claude on top of the Codex MiniOS import
(docs/minios-import-provenance.md); the BIOS boot provisioning, own boot
code and BCD writer are the imported Codex code (the BOOTMGR limit raised
to 960 sectors here). No Microsoft code or binaries in the repository; the
BIOS boot files are copied at run time from the applied Windows image.
