# Windows 95/98 Setup's mini-Windows on the X470 (2026-10-26)

Symptom (X470, RX 560, CSMWrap, phase 1 natively, no VM): Setup's graphical
pages draw broken areas, and only PS/2 keyboard/mouse work there; USB
keyboard and mouse are dead.

## What Setup runs

`SETUP.EXE` -> `DOSSETUP.BIN` unpacks `MINI.CAB` into `C:\WININST0.400` and
starts `DOSX.EXE` (Windows **standard mode**, KRNL386, no VMM/VxD) with the
cabinet's own `SYSTEM.INI` (`shell=winsetup.bin`, 98: `w98setup.bin`):

| file in MINI.CAB | 95 RTM PL, 95 OSR2.1 PL, 98 PL, 98 SE PL |
| --- | --- |
| `VGA.DRV` | sha256 `53312ed0...a820a` = the Windows 3.1 VGA.DRV (all four) |
| `KEYBOARD.DRV`, `MSMOUS31.DRV` / `LMOUSE31.DRV` / `NOMOUSE.DRV` | i8042 / PS/2 drivers |
| `SYSTEM.INI` [boot] | `mouse.drv=msmous31.drv`, `keyboard.drv=keyboard.drv`, `display.drv=vga.drv`, no `drivers=` |

DOSSETUP picks the mouse by copying NOMOUSE/LMOUSE31 over `MSMOUS31.DRV`;
it does not write `mouse.drv=`. 95 RTM PL and OSR2.1 PL ship the same
MINI.CAB (header: set 52994, next cabinet PRECOPY1.CAB); 98/98 SE the same
one (33 files, no chain).

1. **Drawing**: the same driver as Windows 3.1, so the same latch fault
   (locked `xchg es:[di],reg8` loads the latches from byte |3,
   docs/win3x-vga-redraw-2026-10-23.md). The existing 3.1 plan in
   `src/compat/win3x/display_table.zig` (94 sites) gives `9685c4f8...`, the
   VGA.DRV already confirmed on the X470 in Windows 3.1.
2. **Input**: standard mode with stock i8042 drivers, which CSMWrap does not
   feed. The Windows 3.1 standard-mode flow (X470 PASS) solves exactly this
   with USOSKEY.COM + `drivers=usoskey.drv` (keybd_event path, no VKD) and
   VBMOUSE.EXE + `mouse.drv=vbmouse.drv`. Every import of USOSKEY.DRV and
   VBMOUSE.DRV resolves against the mini KRNL386.EXE / USER.EXE (test), and
   the mini USER reads `[boot] drivers=`.

## Fix

* `src/compat/win3x/cab.zig` (own, GPL-3.0-or-later): MSCF reader with own
  inflate (MSZIP window across blocks) and writer (original header bytes,
  one MSZIP folder of stored deflate blocks, CFDATA checksums).
* `src/compat/win3x/w9x_mini.zig`: `usos-fb-ui --w9x-setup-mini SETUPDIR
  HELPERDIR` (host: `usos-win3x-display w9x-mini`). Patches VGA.DRV by plan
  (unknown driver -> left alone), adds USOSKEY.DRV + VBMOUSE.DRV from
  HELPERDIR, `[boot] drivers=usoskey.drv`, `mouse.drv=vbmouse.drv`; replaces
  MINI.CAB only after it reads back to the intended files; idempotent; log
  `C:\USOS9X\USOSMINI.TXT`, last line `bridge=on|off`.
* `tools/w9x_csmwrap_target.sh`: runs it after U9ENV.BAT exists when
  `W9X_VM_PHASE1=0` (the VM phase 1 keeps MINI.CAB as is); off with
  `EFI\USOS\win9x\setup-mini-off.flag`; `bridge=on` + USOSKEY.COM +
  VBMOUSE.EXE in C:\USOS9X -> `SET U9MINI=1`.
* `INSTALL.BAT` (`src/platform/bios/dos_startup.cmd`), `U9MINI=1`: loads
  `VBMOUSE.EXE` (CTTY NUL as W3AUTO.CSM) and `USOSKEY.COM` before SETUP, and
  the same lines in RESUME.BAT (both refuse a second copy). Setup's restart
  ends them; the installed system keeps its own bridge (U9FIX /CSM).

## Tests

* Zig: `zig test src/compat/win3x/root.zig` (inflate vectors incl. a match
  into the previous block, cabinet round trip + checksums, SYSTEM.INI edit,
  rebuild/idempotence).
* `tools/tests/legacy_bios/test_w9x_setup_mini.py`: wiring, the target-script
  block under Git sh with a fake usos-fb-ui, and with the media: all four
  MINI.CABs rewritten, read back by an own reader (checksums) and by
  Windows `expand.exe`, VGA.DRV = tools/win3x_vga_patch.py byte for byte,
  header kept, second run unchanged, imports resolve.

Not run: QEMU, a payload build, the X470. Open risks for the hardware run:
DOSSETUP's FDI with stored MSZIP blocks (standard deflate; Windows'
expand.exe reads them), Patcher9x touching MINI.CAB (it patches VxD
cabinets), VBMOUSE.EXE resident during the DOS part of Setup.
