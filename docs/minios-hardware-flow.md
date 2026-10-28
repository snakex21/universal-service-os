<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# MiniOS on real hardware (Windows 10/11 x64, experimental)

Opt-in per answer profile: `prep_env=minios` (default `setup`: the ISO's own
WinPE and Windows Setup, unchanged). Only Windows 10 and 11 x64 on UEFI read
it. The profile must name an edition found on the ISO (`edition=`), because
MiniOS applies one install.wim image and has no edition list.

## Flow

1. UEFI menu, Windows 10/11 ISO, Start (src/platform/uefi/minios_start.zig):
   writes `\USOSPREP.CFG` (`USOSPREP_HW_V1`) and the rendered profile answer
   `\USOSPREP.XML` to the USOS ESP, then starts
   `\EFI\USOS\minios\usosprep-x64.efi` (MOK-signed like the other helpers).
2. MiniOS asks the one disk question (text console): internal disks of at
   least 16 GiB with 512-byte sectors, the USOS stick excluded; 3 s delay,
   then Space confirms, Esc cancels with nothing written. The run's token is
   written to sector 0 of the chosen disk only; the existing strict
   size + token match then selects it.
3. The disk is wrapped in `hw_target.VirtualBlank` (chunks never written read
   as zeros, partial first writes zero the chunk, GPT head/ESP/MSR and the
   Windows volume up to the NTFS allocation high-water are zero-filled), so
   the unchanged fresh-image writer runs without a full-disk wipe.
4. GPT (ESP 300 MiB + MSR + Windows), install.wim image applied and SHA-1
   verified, `Windows\Panther\unattend.xml` from the profile, boot files and
   BCD on the new ESP (same `provisionUefi`, gate `hardware_flow`), a
   `Windows Boot Manager` Boot#### first in BootOrder.
5. Success: the menu restarts into the new Windows (specialize, OOBE).
   Cancel or any failure: the menu records the cause and starts Windows
   Setup from the same ISO instead.

Logs: `EFI\USOS\Logs\minios-start.txt` (menu), `EFI\USOS\Logs\MINIOS-<build>.LOG`
and `\USOSPREP.LOG` (+ `.1`..`.3` older runs) on the USOS ESP. The DATA
partition is NTFS and has no UEFI-side writer, so logs stay on the ESP.

## Not staged compared with the Setup path

- DATA\Drivers\<Windows 10|11> INF packages (Setup path: drvload +
  offlineServicing DriverPaths). Inbox drivers only.
- `usos-run-hidden` wrapper for the profile's commands (they run, but
  console windows can be visible).
- ISO `sources\$OEM$` folders, the previous-install log check, a DATA
  Unattended XML file (only a USOS profile answer is staged).
- The windowsPE pass of the answer (disk, edition, key) is not used:
  MiniOS picks the disk and the image; a windowsPE product key is not
  applied (Windows OOBE may ask for it; it can be skipped).
- install.esd / split .swm media are refused (unsplit install.wim only).

## Provenance

Hardware mode by Claude on top of the Codex MiniOS import
(docs/minios-import-provenance.md); no Microsoft code or binaries.
