# XP NiKKA: complete installation and English preparation menus

## Reproduced problem and fix

Source: `Windows.XP.Professional.SP3.OEM.PL.IE8.WMP11.DX.NET.FINAL.FULL.SATA-v2.Kwiecien.2014-NiKKA.iso`.
SHA-256: `9FE5A0A744EC299C2FC821101A8B0A2F31133317F841983BF45FE60D45D91985`.

The previous backend copied the complete I386 directory but did not process
explicit destination names in DOSNET.INF's `[Files]` section. This source asks
for additional local names such as `mshta.mui -> mshta.mu_`. Its TXTSETUP.SIF
also has two copy entries for several IE8 language resources. The additional
local names were absent even though the original files existed in the ISO.

The new `xp_dosnet_aliases.awk` and `prepare_xp_source_aliases.sh` prepare these
destinations after the complete I386 copy. Existing ISO destinations, including
uncompressed SYSTEM32 boot files, remain intact. Each destination is read back
and compared byte for byte. Invalid paths, unknown source directories and
conflicting destinations are rejected. No Windows binaries, security policies,
NTFS permissions or original ISO contents are patched.

## Controlled installation comparison

Both tests used disposable 120 GB disk images, the same ISO, identical XP
partition preparation and VirtualBox 7.2.16 with BIOS/PIIX3, 512 MiB RAM, two
CPUs and networking disabled. The supplied product key was entered only in
the test guests; it is not in the USOS payload or this report.

Baseline: `zig-out/xp-nikka-baseline3`, VM `USOS-XP-Nikka-Baseline`.

- Reproduced copy failures for `ie4uinit.mui`, `iedkcs32.mui`, `ieframe.mui`,
  `mshta.mui` and `msrating.mui`. ESC was used only in this comparison run to
  reproduce the user's incomplete installation.
- Reproduced the GUI Setup access error for `D:\WINDOWS\system32\grpconv.exe`
  and the NetFxLP `REG COPY ... Setup\SSIPRS` access error.
- Direct execution of grpconv from the guest diagnostic console returned 0;
  SYSTEM and Administrators had full file access. No permission workaround
  was applied.

Fixed source: `zig-out/xp-nikka-fixed3`, VM `USOS-XP-Nikka-Fixed`.

- Eight explicit DOSNET destinations verified (six added names, two existing
  SYSTEM32 destinations retained).
- Text-mode copying completed without any file-error interaction or ESC.
- Automatic restart entered GUI Setup. Component registration and finalization
  completed without the grpconv or NetFxLP dialogs.
- First startup reached the desktop without the reported security alert or
  persistent "Czekaj..." screen. `winver` launched from the desktop. Its window
  reports build 2600 with the SP3 GFE build string; this customized image/key
  combination displays Media Center Edition branding.
- Evidence: `after-copy.png`, `late-setup.png`, `desktop-check.png` and
  `desktop-winver.png` in the fixed test directory. Both VMs were saved after
  testing. No activation transaction was performed.

The controlled result supports missing DOSNET destinations as the cause of the
reported installation failure sequence. The existing physical Intel installation
was not repaired or erased; this change applies when preparing a fresh install.

## Interface and startup

The XP disk picker, preparation choices, confirmation, disk details and input
help now use English. Mouse, arrows, Enter, Escape and the default Cancel choice
are retained. Once a menu has appeared, read-only checks retain that frame
instead of repeatedly displaying a preparation notice. Actual copying progress
starts after confirmation.

Successful BIOS bootstrap and early Core messages now go to serial only.
Fatal startup messages and the D diagnostics screen remain available. Firmware
messages produced by the computer's own BIOS are outside this change.

## Validation and release

- Full release build and Go tests: PASS.
- Zig unit/startup tests and QEMU UEFI x86-64/ARM64 tests: PASS.
- Four DOSNET parser tests, including unsafe paths and collisions: PASS;
  included in `tools/tests/run.ps1`.
- Thirteen XP partition planner tests: PASS.
- Actual production BIOS Core boot, serial markers, absence of early messages
  in VGA text memory, menu, D diagnostics and return: PASS
  (`zig-out/quiet-production-final`).
- Graphical mouse/back/cancel flow with unchanged target MBR and sentinel:
  PASS (`zig-out/xp-english-menu2`).
- Read-only disk overview and system detection: PASS
  (`zig-out/xp-english-overview`).
- Stock SP2 full preparation through the interactive format flow: PASS
  (`zig-out/xp-stock-alias-regression`).

Release: `B260909-190123-52D1DBE8`.

| Artifact | SHA-256 |
| --- | --- |
| initramfs-usos | `6E4AA46C30659273F3DBAE4BB32DF0F69D5EF3CEAC2538EBA03B7456D28594A8` |
| Core slot | `18552A085CADA06084A92BB983FA5C4FFE1866F153E7B55C62B8D6251E235CA3` |
| Stage 1 | `CC35473164009C30221BCC26FDE48B42E1BCFCDA1ADAA512BF78020D9511C065` |

Kingston update completed with `RESULT=PASS`, guarded by model, size, disk GUID
and all three partition GUIDs. Boot code, payload and installer readbacks matched;
GPT partition identities and extents were unchanged. Update log:
`zig-out/xp-nikka-kingston-update.log`. The physical Intel disk was not written.
