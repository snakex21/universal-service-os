# Windows 3.x redraw problem on the X470 (2026-10-23)

X470 (RX 560, CSM off, CSMWrap/SeaBIOS, build B261023-145441-F9D0EF82):
Windows 3.0a and Windows 3.1 PL leave broken, partly repainted areas when
windows are moved or dragged (not pointer trails). Windows 1.01, 1.04, 2.03,
2.11/286 and 2.11/386 on the same machine are clean.

## Display configuration in USOS

* 3.0a: Setup detects the display (W30.KEY accepts "No Changes"), so
  `display.drv = vga.drv` (3.0a VGA.DRV, 640x480x16, BIOS mode 12h; the
  "ct441" entry would also give vga.drv), 286 grabber vgacolor.gr2, VGA fonts.
  Started as `WIN /R` (real mode) by W1AUTO.BAT; menu item 2 = `WIN /S`.
  The mouse goes through VBMOUSE: 3.0 MOUSE.DRV uses INT 33h when a driver
  answers INT 33h 24h with version >= 6 (calls 24h/0/14h/0Bh at 0x0640-0x11ad
  of the expanded file).
* 3.1 / 3.11 / WfW 3.11: also the standard VGA.DRV (3.1 version), standard
  or 386 enhanced mode (W3AUTO.BAT), VBMOUSE.DRV; no SVGA/VESA driver.
* CSMWrap POSTs the RX 560's own legacy VBIOS (docs/research/csmwrap.md step
  4); VGA register I/O and A0000 go to the card's own VGA core, not to an
  emulation on the GOP framebuffer. A0000-BFFFF is set UC by CSMWrap's AMD
  unlock (`MTRRfix16K_A0000 = 0`).

## What differs between the 2.x and 3.x drivers

Static reading of the expanded drivers (scratch NE disassembly):

| Driver | VGA register reads (`in` from 3C5h/3CFh) |
| --- | --- |
| 2.03 IBMPS250.DRV (VGA) | none |
| 3.0a EGA.DRV | none |
| 3.0a VGA.DRV | seg 1 0x13CE-0x140F: SEQ data 3C5h with the index left at 2 (map mask), GC1, GC3, GC8 |
| 3.1 VGA.DRV, 3.1 SUPERVGA.DRV | seg 1 0x317E-0x31D2: GC5, SEQ 3C5h (index left at 2), GC4, GC1, GC3, GC8 |

These routines save the drawing state when the pointer is drawn at
interrupt time (also while another drawing call runs): read the registers,
store the latches with a write mode 1 write into off-screen memory (3.0:
A000:BFFF, with per-plane helper bytes at BFF9-BFFE; 3.1: A000:9B0F), draw,
write the read values back, reload the latches. A register that does not
read back what was written restores the wrong state in the middle of a blit,
which damages exactly the drawing that runs while the mouse moves.
Latch save into off-screen VRAM is common to 2.x (IBMPS250.DRV also stores
at A000:BFFF) and 3.x, so the latch/off-screen part is already exercised by
the working 2.x systems; register readback is the 3.x-only part.

QEMU (SeaBIOS, std VGA, TCG, fresh 3.0a install from the current helpers,
WIN /R): Program Manager dragged several times with a USB mouse, no damage.
QEMU's std VGA reads registers back correctly, so this neither proves nor
excludes the hypothesis for the RX 560.

## Probe: USOSVGAR.COM

`src/platform/bios/win9x/usosvgar.S` (GPL-3.0-or-later). Sets mode 12h,
writes 13 test values into SEQ2 and GC0-5/7/8, reads them back (also with
the index left in place, as VGA.DRV does), checks per-plane off-screen
memory at 9600/9B0C/A000/BFF8/FFF8 and the latch save/restore at 9B0F and
BFFF, sets the previous mode again and prints a report ending in
`RESULT OK`, `RESULT READBACK-BAD`, `RESULT MEMORY-OR-LATCH-BAD` or
`RESULT NO-MODE12`.

W1AUTO.BAT (1.x-3.0) and W3AUTO.BAT (3.1/WfW) run it once per install
before WIN into `C:\USOS\DIAG\VGAREG.TXT`; INSTALL.BAT copies it to C:\DOS.
Tests: tools/tests/legacy_bios/test_usosvgar.py (Unicorn, planar VGA model:
faithful, broken GC8 read, broken SEQ2 read, broken off-screen latches).
QEMU std VGA (MS-DOS 6.22 floppy): `RESULT OK`, 0075h tests, 0 mismatches.

An existing install can be checked without reinstalling by copying
USOSVGAR.COM to C:\DOS on the target disk (the batch files of existing
installs do not call it; run `C:\DOS\USOSVGAR.COM>C:\USOS\DIAG\VGAREG.TXT`
from the DOS menu item, or patch the start batch).

## Next steps

1. X470: read VGAREG.TXT. Cheap cross-check on the same install: set
   `display.drv=ega.drv` in C:\WINDOWS\SYSTEM.INI of the 3.0a install
   (EGA.DRV is on the 3.0a media and reads no VGA register; 640x350):
   no damage with EGA.DRV + READBACK-BAD in the log = cause confirmed.
2. If confirmed, the fix depends on the pattern in the log (all FFh, index
   echoed, value one access late, ...):
   * a card-level workaround if the readback can be made to work (for
     example an access-order/timing issue);
   * 386 enhanced mode (3.1/WfW): a VxD that keeps shadow copies of
     3C4h/3C5h/3CEh/3CFh for the system VM and answers the reads from them;
   * for every mode and 3.0 too: a display driver that does not read VGA
     registers (EGA.DRV as an interim 640x350 option, or the parked own
     VBE linear-framebuffer driver, ROADMAP "3.x VESA").
3. If the log says `RESULT OK`, readback is not the cause; next suspects are
   the interrupt context of the pointer (VBMOUSE event delivery from
   SeaBIOS's timer path) and the per-plane helper bytes of 3.0.
