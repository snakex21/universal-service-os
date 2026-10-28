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

## Result of USOSVGAR 1/2 on the X470 and root cause

Register readback, plane memory, the 9B0F/BFFF latch save and every write
mode 1 latch copy (REP MOVSB and byte loops, forward/backward, overlaps)
are fine, and A0000-BFFFF is UC (fixed MTRR 259h = 0). Only the tests
that write with `xchg es:[di],al` (write modes 2/3 and the ALU functions)
fail: the latches are loaded from byte `offset | 3` instead of the
addressed byte (e.g. WM2 bit mask 3C at 9200: expected FE, got 3D = data
3C combined with the latch of 9203). The Unicorn VGA model with this fault
(`Vga(locked3=True)`: latches of a locked read from offset|3, CPU value
correct) reproduces all 24 bulk lines of the X470 log byte for byte.
XCHG with memory is implicitly locked; the locked read apparently goes out
as an aligned dword read that the card's VGA core processes byte by byte,
leaving the latches at the last byte. VGA.DRV 3.1 uses `xchg es:[di],reg8`
(86 sites) and `xchg [di],reg8` with DS = A000 (8 sites) as "load latches
and write" in text, line, pixel and bitmap output, so those draws combine
with the wrong latch byte.

## USOSVGAR 3: RMW instruction tests

Version 3 runs, after the bulk tests, every RMW form one instruction per
byte at offsets ending in 0, 1, 2 and 3 separately: `xchg`, `lock or`,
`mov ah,[di]` + `mov [di],al`, `or/and/xor/add`, `not`, `inc`, `test` +
`mov` (read-only), and the word forms `xchg/lock or/or/mov ...,ax`.
WM1 lines show where the latches came from per alignment (`=` addressed
byte, `3` byte |3, `+`/`-` neighbour, `?` other, plus stray changes);
WM0/3C lines (byte forms) compare data + latches with the same instruction
run on RAM (`=`, `3`, `R` = data and latches from |3, `?`) and count CPU
result differences. Verdict per line (OK / ADDR3 / OTHER, word forms INFO),
`RMW summary` and `RMW RESULT OK | LOCKED-ONLY | UNLOCKED-BAD-TOO`.
Unicorn: faithful VGA -> OK, `locked3` -> LOCKED-ONLY (only `xchg` and
`lock or` ADDR3), `rmw3` (every RMW) -> UNLOCKED-BAD-TOO.

## Fix: tools/win3x_vga_patch.py (own tool, GPL-3.0-or-later)

Input a Windows 3.x display driver (NE), output the patched file. The code
segments are walked with capstone (16-bit) by recursive descent from the
entry table and internal relocation targets, plus near code pointers found
in reached code (MOV/PUSH imm16, LEA reg,[routine], CS: and LEA word tables;
each accepted only if its walk decodes cleanly and agrees with the code
already reached). Every reached `xchg mem,reg` with an ES override or with
DS by default and a base/index register is replaced by `call stub` (+NOPs);
the stub, appended to the same segment, is `push T / mov T,mem / mov mem,R
/ mov R,T / pop T / ret` (no flag changes). Two-byte sites take the next
(or previous) movable instruction into the window/stub (no control
transfer, no stack/SP use, no fixup, no branch target inside). DS absolute
variables (`xchg [1FEh],cl` busy flags), SS/BP stack variables, sites only
found by a byte scan outside the reached code (templates?) and anything
overlapping a fixup are left alone and listed. Grown segments (+ their
relocation records) are written at the end of the file, the segment table
is updated and the fast-load area is switched off. `--unlocked-rmw`
(default off) also replaces unlocked RMW with video memory, only needed if
a probe ever shows UNLOCKED-BAD-TOO. Patched Microsoft files stay local.

VGA.DRV 3.1 (sha256 53312ed0...a820a): 94 sites replaced (86 ES + 8
DS-register), 19 left alone (17 DS/SS variables incl. the busy flag, 0
unreached ES sites); 3.0a VGA.DRV 42 and EGA.DRV 3.0 44 replaced but about
46 ES sites each are only found by the byte scan (regular code blocks in
segments 2/3, probably BitBlt/text templates), so 3.0 needs a closer look
before use; EGA.DRV 3.1: 75 replaced.

Tests (tools/tests/legacy_bios/test_win3x_vga_patch.py): a synthetic NE
driver (entry, relocated far call, ES and DS-register sites, a 4-byte site,
a DS busy flag, an unreached template) checks site selection, the file
layout and, under Unicorn with the VGA model in four write modes, that the
patched routines give the same registers, flags, RAM, stack and planes as
the original on a faithful VGA and also on the `locked3` model, where the
original is wrong. With `USOS_WIN3X_DRV=<VGA.DRV>` every replaced window
of the real driver is executed alone (random registers/planes, 4 modes):
VGA.DRV 3.1: 94 windows x 4 modes identical on both models; the original
is wrong on the fault model in 275 of the 376 runs.

Limits: the patch keeps the instruction effect but not its interrupt
atomicity (not needed for video memory; the busy flags are not touched);
code only reachable through pointers the walk does not find stays
unpatched (none known in 3.1 VGA.DRV); not yet tried on hardware.

## X470 result and the fix in every Windows 3.x install

X470 (2026-10-23): Windows 3.1 PL with the patched VGA.DRV (94 sites) has
no redraw damage, the logo is clean with the patched VGALOGO.LGO / WIN.COM;
USOSVGAR 3 says `RMW RESULT LOCKED-ONLY`. USOSVGAR stays an on-demand
diagnostic (INSTALL.BAT copies it to C:\DOS; no start batch runs it):
`C:\DOS\USOSVGAR.COM>C:\USOS\DIAG\VGAREG.TXT`.

### Where the files are patched

`tools/dos_csmwrap_target.sh` (micro-Linux, the CSMWrap DOS path the X470
uses) copies the Windows 3.x ISO root to `C:\USOSDOS\WINSETUP`; right after
that, for Windows 3.0a / 3.1 / 3.11 / WfW 3.11 only (`DOS_WIN_EARLY` empty
or `windows-3-0`; 1.x/2.x unchanged), it runs
`usos-fb-ui --win3x-display "$U/WINSETUP"`. The tool patches, in place:

| file | 3.0a | 3.1 PL | 3.11 OEM EN | WfW 3.11 PL |
| --- | --- | --- | --- | --- |
| VGA.DRV | SZDD under the plain name, 87 sites | VGA.DR_ SZDD, 94 | VGA.DR_ KWAJ, 94 (same driver as 3.1) | VGA.DR_ KWAJ, 94 (own build) |
| EGA.DRV | SZDD, 89 | EGA.DR_ SZDD, 75 | EGA.DR_ KWAJ, 75 (= 3.1) | not on the media |
| VGALOGO.LGO | SZDD, logo patch | VGALOGO.LG_ SZDD | VGALOGO.LG_ KWAJ (= 3.1) | VGALOGO.LG_ KWAJ (= 3.1) |

Each patched file is stored again in the container the media uses (the
original header kept, the length updated), so Setup reads it through the
decompressor it uses for every other file: SZDD with literal-only flag bytes,
KWAJ method 3 with fixed-length tables (type 0; Microsoft's own compressor
uses all four table types on the WfW media, type 0 included) and literal
runs of 32 bytes. Setup then installs the patched driver and builds WIN.COM
from WIN.CNF + the patched VGALOGO.LGO + VGALOGO.RLE. Before a file is
replaced the stored result is expanded again and compared. The decisions are
logged to the prepare log and `WINSETUP\USOSDISP.TXT` (copied with WINSETUP
to `C:\WINSETUP`). Known drivers only (input sha256); an unknown driver or an
already patched file is left as it is, so the step is idempotent and an
unknown edition installs unpatched, as before.

Setup picks VGA.DRV on the X470 and in QEMU for every 3.x version (3.0a by
detection, 3.1/3.11/WfW by the batch answers); EGA.DRV is patched as the
640x350 fallback where the media has it.

### Implementation

* `src/compat/win3x/` (Zig, own code, GPL-3.0-or-later): `lz.zig` (SZDD and
  KWAJ method 3 decoder, literal-only encoders), `display_patch.zig` (the
  stub/NE layout of tools/win3x_vga_patch.py and the logo pattern patch of
  tools/win3x_logo_patch.py), `display_table.zig` (generated plans),
  `display_run.zig` (the folder step). In the micro-Linux it is a mode of
  usos-fb-ui; on the host `zig build win3x-display-tool` builds
  `usos-win3x-display patch-dir DIR | expand IN OUT` for the tests.
* The capstone walk stays on the host: `tools/win3x_patch_table.py` writes
  `display_table.zig` from the drivers (input sha256, the windows = segment,
  start, instruction lengths and which one is the XCHG, output sha256). The
  table holds offsets, lengths and hashes only; the stubs are rebuilt from the
  user's own file and used only when the result has the recorded sha256.
  Another edition of a driver is added by running the generator on it.

### Windows 3.0a: the byte-scan sites

The 46 ES sites per 3.0a driver that the walk did not reach are in place
code, not templates (disassembly review): segment 2 holds the 386 text
output, segment 3 the 286 one. They are unrolled loop bodies entered by
computed jumps (`mov bl,cs:[bx+T] / add bx,B / mov [bp-5Ch],bx / jmp
[bp-5Ch]`, seg2 1B4A/1BD6, seg3 17A6/1826) and helper routines reached
through near pointer tables the walk does not recognise (seg2 1E1C.., 1DDC,
1E94..: 20D8, 2A69, 2A96, 2ADC, 2B43, 2B98, 2BB9, 2BE9, 2C2A, 2C7C); they end
in RET and use direct near calls, so they run where they are. Each does
`out dx,al` (GC8 bit mask) + `xchg es:[di],al`, the faulting pattern.
`REVIEWED_STARTS` in tools/win3x_vga_patch.py adds these routine starts for
the two 3.0a drivers (by sha256); the walk still checks every start. Result:
VGA.DRV 87 and EGA.DRV 89 sites replaced, no ES site left; the remaining 35
are SS/DS variables and BP stack slots (busy flags, never video memory).
Unicorn: every replaced 3.0a VGA.DRV window x 4 write modes is identical to
the original on a faithful VGA and correct on the fault model (original
wrong in 238 of 348 runs). Not yet tried on the X470.

### Tests

* `tools/tests/legacy_bios/test_win3x_display_tool.py`: with the media,
  the Zig tool output equals the Python patchers byte for byte for every
  version (expanded with own reference decoders), the container is kept, a
  second run changes nothing, an unknown driver stays untouched, and the
  committed table equals the generator output; script/subcommand wiring.
* Zig unit tests (`src/compat/win3x`): containers round trip, stub bytes,
  logo patch.
* QEMU only (build B261023-194647-7926C19A, tools/tests/run_w9x_micro_linux_qemu.py
  w3 --boot: the real micro-Linux runs dos_csmwrap_target.sh, then CSMWrap
  path boot, Setup by itself; QEMU's VGA does not show the fault, so the
  check is by hash on the installed disk):
  * Windows 3.1 PL (SZDD): `[WIN3X_DISPLAY]` lines in the prepare log;
    installed `C:\WINDOWS\SYSTEM\VGA.DRV` = 9685c4f8... (patched),
    `VGALOGO.LGO` = 8da538eb... (patched), `WIN.COM` = ba873ece... (= WIN.CNF
    + patched VGALOGO.LGO + VGALOGO.RLE), `display.drv=vga.drv`; Program
    Manager on screen.
  * Windows for Workgroups 3.11 PL (KWAJ): VGA.DRV = 59d1faf8...,
    VGALOGO.LGO = 8da538eb..., WIN.COM = 72754064... (patched), desktop up.
  So Setup takes the literal-only SZDD and KWAJ files. 3.0a (same SZDD path
  as 3.1, own Setup) and 3.11 OEM (same KWAJ path as WfW) were not
  installed in QEMU; hardware: only the 3.1 driver/logo were tried on the
  X470 so far.
* Not covered: the BIOS-native DOS path (`src/platform/bios/dos6_native_iso.zig`,
  firmware CSM PCs, RAM disk built by the UEFI Core) has no micro-Linux step
  and still installs the original files.
