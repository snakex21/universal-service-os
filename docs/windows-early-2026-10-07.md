# Windows 1.0x-3.0 and Windows for Workgroups 3.11 (2026-10-07, experimental)

UEFI menu only (profile w9x-uefi-csmwrap, DOS recipe): micro-Linux writes the
MS-DOS 6.22 target disk with a CSMWrap ESP (tools/dos_csmwrap_target.sh), the
disk installs MS-DOS, then the original Windows Setup runs from C:\WINSETUP.
The BIOS Core does not list these systems (size budget).

## DATA media

Every system needs `Systems\DOS\MS-DOS\Images\MS-DOS 6.22.iso` and one ISO
made from its diskette images (the images themselves stay with the user):

    python tools/prepare_windows3_media.py --source <folder or ZIP with *.IMG> --output <name>.iso

The converter reads 360 KiB / 720 KiB / 1.2 MiB / 1.44 MiB FAT12 images, keeps
every file unchanged and one directory level (Windows 1.0x: `PIF`).

| Menu entry | DATA folder (`Systems\Windows\...\Images`) |
| --- | --- |
| Windows for Workgroups 3.11 | `Windows for Workgroups 3.11` |
| Windows 3.0 | `Windows 3.0` |
| Windows 2.11 (386) | `Windows 2.11 (386)` |
| Windows 2.11 (286) | `Windows 2.11 (286)` |
| Windows 2.03 | `Windows 2.03` |
| Windows 1.04 | `Windows 1.04` |
| Windows 1.01 | `Windows 1.01` |

## Flow

* WfW 3.11: the Windows 3.1 flow (`SETUP /H:USOS.SHH`). The Polish edition
  still shows two text pages (keyboard layout, code page 852): Enter twice.
  The start menu starts WfW in 386 enhanced mode (it has no standard mode).
  W3START.BAT names no SUBST: WfW Setup scans the AUTOEXEC.BAT batch files and
  stops at SUBST.EXE.
* Windows 1.0x-3.0 (`EARLY.TAG`): their Setup reads drive A: only (label
  files such as SETUP.LBL). W1SETUP.BAT runs `SUBST A: C:\WINSETUP`, so every
  "insert disk" prompt is already satisfied, and starts SETUP.EXE. Setup is
  interactive (no batch mode before 3.1); its DOS pages read the keyboard
  through the BIOS, so a USB keyboard works there under CSMWrap.
  Start menu W1CONFIG.SYS / W1AUTO.BAT: no DOS=HIGH (Windows 2.x needs the
  HMA: "Error: High memory area in use"), SETVER (2.x WIN.COM: "Incorrect DOS
  version"), WIN386.EXE for Windows/386 (default folder C:\WIN386), WIN /R as
  the Windows 3.0 fallback.

Answers used in QEMU (SeaBIOS, PS/2 keyboard):

* 1.01: C, Enter (C:\WINDOWS), C, mouse 2 or 1, display 6 (EGA > 64K), C (Build),
  C (Utilities), N (printer), C (Desktop Applications), C (Write).
* 2.03 / 2.11 (286): Enter, Enter (C:\WINDOWS), computer "IBM PC, XT, AT",
  display VGA (detected on 2.11), US keyboard, mouse "IBM Personal System/2
  Mouse" or "Microsoft Mouse connected to PS/2 Mouse Port", No Change, C (no
  printer), country Enter, F (finish).
* 2.11 (386): as 2.11 (286) plus computer list, N (AUTOEXEC PATH), any key,
  C (no Memset).
* 3.0: Enter, Enter, No Changes; graphical part: Alt+P, Alt+A, Alt+D, Enter,
  Enter, OK, "Return to DOS".

## QEMU results (SeaBIOS, -cpu pentium3, 64 MiB; scratch harness)

| System | Installs | Display | Notes |
| --- | --- | --- | --- |
| 1.01 | yes | EGA 640x350 | MS-DOS Executive; keyboard OK; Win 1.01 has no PS/2 mouse driver |
| 2.03 | yes, full USOS flow to the start menu | VGA 640x480 | MS-DOS Executive from the menu |
| 2.11 (286) | Setup complete | VGA | not started after the DOS=HIGH fix |
| 2.11 (386) | Setup complete | VGA | WIN386 needs the HMA free (fixed by W1CONFIG) |
| 3.0a | yes | VGA | real mode (WIN /R) OK with mouse; standard mode restarted the VM |
| WfW 3.11 PL | yes (batch Setup) | VGA | 386 enhanced; VBMOUSE + USOSKEY |

(First round; superseded by the section below.)

## Unattended Setup and USB keyboard: USOSKBC (second round, 2026-10-07)

`USOSKBC.COM` (src/platform/bios/msdos/usoskbc.S, own GPL code, built by
tools/build_win3_usb_keyboard.py) does two things:

* `/R` relay: SeaBIOS (CSMWrap) serves the USB keyboard from its timer
  interrupt and hands each set-1 byte to INT 15h AH=4Fh. KEYBOARD.DRV of
  Windows 1.0x-3.0 reads port 60h in its own INT 09h handler and never sees
  those bytes. USOSKBC takes the bytes that did not come through INT 09h,
  drops them for SeaBIOS and writes them back through the 8042 with command
  D2h, so IRQ 1 fires and whoever owns INT 09h reads them as PS/2 bytes. It
  needs an 8042 (port 64h not FFh; the X470 has one); /R also sets the
  keyboard interrupt bit in the controller command byte. One byte per tick.
* Key script: `USOSKBC /R C:\USOSW3\SETUP.KEY` (W1SETUP.BAT) or
  `USOSKBC C:\USOSW3\SETUP.KEY` (W3START.BAT, 3.1 / WfW batch Setup). Scripts:
  src/platform/bios/msdos/keys/*.txt, compiled by tools/usos_keyscript.py to
  W101/W104/W203/W211/W386/W30/W3PL.KEY; dos_csmwrap_target.sh copies the
  matching one to SETUP.KEY (W3PL for 3.1 / WfW: the Polish keyboard-layout
  and code page 852 pages). A step waits for a text on the text screen (page
  start from the CRT controller: Windows 1.0x Setup flips pages without the
  BIOS) and then types its keys; Windows 3.0's graphical part gets timed keys
  through the 8042. A text that never shows stops the script; the keyboard
  stays usable for a person.

Start menu (W1AUTO.CSM): VBMOUSE and `USOSKBC /R` instead of USOSKEY.
Windows 3.0 starts in real mode (WIN /R) by default; the second menu entry is
WIN /S.

QEMU (SeaBIOS = CSMWrap's BIOS, `-machine pc,smm=off`, usb-kbd and usb-mouse
on qemu-xhci, i8042 present; the harness sent no keys):

| System | Unattended Setup | USB keyboard in Windows | Mouse | Display |
| --- | --- | --- | --- | --- |
| 1.01 | yes, to the desktop | yes (relay) | no (no pointer) | EGA 640x350 |
| 1.04 | yes (after the CRT-controller page fix) | yes (relay) | no | EGA |
| 2.03 | yes, to the desktop | yes (relay) | no (PS/2 port driver, pointer stays) | VGA |
| 2.11 (286) | yes, to the desktop | yes (relay) | no (MS Mouse Bus/Serial) | VGA |
| 2.11 (386) | yes, to the desktop | no: WIN386 virtualises the 8042 | no | VGA |
| 3.0a | yes, DOS and Windows part; Program Manager with groups | yes, real mode | no | VGA |
| WfW 3.11 PL | yes, both Polish pages answered | USOSKEY.DRV (3.1 path) | VBMOUSE.DRV | VGA |

Windows 3.0: 386 enhanced mode hangs in the BIOS (V86, F000) and also wants
WINA20.386 in C:\ (not copied); standard mode stopped at the logo in QEMU.
QEMU's SMM must be off: with SMM on, Windows 1.0x-3.0 hang in SeaBIOS's SMM
handler (QEMU only; CSMWrap has no SeaBIOS SMM).

Open (parked): USB mouse in 1.0x-3.0 (their drivers probe the hardware or the
PS/2 aux port; a D3h "write aux output buffer" relay of the SeaBIOS mouse
packets is the analogous next step); keyboard in Windows/386 2.11 and 3.0
enhanced mode (WIN386 / VKD virtualise the 8042).

## X470 results and fixes (2026-10-08)

Hardware run of build B261007-213309-DCFD9C2F (X470, no CSM):

| System | Result |
| --- | --- |
| WfW 3.11 PL | installs and works; VGA only (no VESA yet) |
| 3.0a | works, USB keyboard OK, no mouse (expected); one restart too many |
| 2.03 | install completes, then hangs at the blue logo on every start |
| 1.0x (photo: 1.04) | works, but "Incorrect DOS version" and screens of garbage after the logo |

Fixes (branch feature/win-early-2):

* **"Incorrect DOS version" + garbage (1.0x).** The message comes from the
  Windows 1.0x kernel (bound into WIN100.BIN), not from WIN.COM. Its DOS check
  walks DOS internals with version-specific offsets; on 6.22 it fails, prints
  the message and then prints memory from a stale pointer up to the next `$`
  (the garbage). MS-DOS 6.22's SETVER table lists WIN200.BIN 3.40 but not
  WIN100.BIN. INSTALL.BAT now runs `SETVER C:\DOS WIN100.BIN 3.40` for the
  early systems (the start menu already loads SETVER.EXE). QEMU: console output
  traced through INT 29h (gdbstub): before, "Incorrect DOS version" plus about
  3 KB of code bytes; after, nothing between USOSKBC and the MS-DOS Executive.
* **2.03 hang at the logo (X470 only).** Not reproducible in QEMU (64 MiB and
  2 GiB, without serial port, without i8042: 2.03 reaches the MS-DOS
  Executive). The logo is drawn by WIN.COM; the hang is in KERNEL/USER start,
  before the display driver. Suspect: MOUSE.DRV (Setup's "Microsoft Mouse on
  the PS/2 port"), which on the X470 (no PS/2 mouse) takes its PS/2 path:
  INT 15h C205/C201/... with up to 20 retries per call on error 04h, and
  SeaBIOS (CSMWrap) answers each failed PS/2 command with 04h after its
  timeout. The mouse cannot work under CSMWrap anyway, so W203.KEY now picks
  "No mouse or other pointing device". Needs an X470 retest.
* **"Windows 9x" on the preparation page.** micro_linux_ui.sh fell back to
  "Windows 9x" until request.ini was read. The UEFI menu now adds
  `usos.heading=<name>` (spaces as `_`) to the micro-Linux command line
  (vista_preparation.headingOption) and the first frame shows the chosen
  system (Windows 3.0, Windows for Workgroups 3.11, MS-DOS, ...); without the
  token the fallback is "Windows".
* **Windows 3.0 restarts.** The last key of W30.KEY pressed Enter in Setup's
  exit dialog, whose default button is Reboot; after that reboot USOS writes
  the start menu and restarts again. W30.KEY now answers Alt+D ("Return to
  DOS"): W3START.BAT continues with WINMENU.BAT in the same session, so the
  flow has two restarts (after MS-DOS, after the start menu) instead of three.

Parked polish items: VESA for 3.x (WfW 3.11 / 3.0 / 3.1), USB mouse for
1.0x-3.0 (D3h aux relay), keyboard in Windows/386 2.11 and 3.0 386 enhanced
mode, PS/2 mouse driver back for 2.03 once the aux relay exists.

## X470 diagnostic start items (2026-10-09)

Windows 2.03 still hangs at its logo on the X470 after the no-mouse fix
(SanDisk, B261008-233752). The early-Windows start menu (W1CONFIG.SYS, all of
1.0x-3.0) has a submenu "Diagnostyka zawieszenia Windows (D1-D5)"; each item
changes one thing against the default (HIMEM /M:2 + SETVER, VBMOUSE,
USOSKBC /R):

| Item | Block | Change |
| --- | --- | --- |
| D1 | D1WHERE | default + USOSWHER /G (CS:IP corner display) |
| D2 | D2NOKBC | default without USOSKBC (PS/2 keyboard only) |
| D4 | D4CLEAN | no HIMEM, no VBMOUSE; SETVER + USOSKBC only |
| D5 | D5MIN | SETVER + USOSWHER /G only (no HIMEM, VBMOUSE, USOSKBC) |

D3 (EGA instead of VGA) is not offered: Windows 2.x Setup binds the display
driver into WIN200.BIN, so another display needs a second Setup run.

Each item appends to `C:\USOS\DIAG\Dn.TXT` before WIN starts: a start line,
VER, `MEM /D` (WIN.COM loads at the first free block listed) and `MEM /C`,
then "WIN started"; "WIN returned" follows only when Windows exits. A log
without "WIN returned" = hang (or reset).

USOSWHER.COM (src/platform/bios/win9x/usoswhere.S, 8.3 name of
USOSWHERE.COM, now staged in dos-native/msdos and copied to C:\DOS) has a new
`/G` switch: it also draws its three rows in the planar EGA/VGA modes 0Eh,
10h, 11h and 12h (8x8 BIOS font, white on black, top right), so the corner
stays visible over the graphical 2.x logo. It saves and restores the VGA
sequencer map mask, graphics controller registers 1/3/5/8 and both index
registers around each draw. Row 0: interrupted CS:IP, tick counter, current
PSP and its MCB name; row 1: AX of the last INT 13h/15h/21h/2Fh; row 2: last
8 distinct CS values. Ticks still counting = interrupts on (CS:IP is the
loop); ticks frozen = interrupts off or dead.

Hardware only (no VM run for this round, by decision).

### X470 result of the diagnostic items (2026-10-09, SanDisk B261009-120423)

Video of four fresh starts after a fresh 2.03 install: D1, D2, D4 and D5 all
stop at the blue 2.03 logo (WIN.COM's logo screen) and never return
(C:\USOS\DIAG\D1/D2/D4/D5.TXT end with "WIN started", no "WIN returned").
The short flash before the logo is only the TSR banners (VBMouse 0.67
"Cannot find VirtualBox PCI device ... Driver installed", USOSKBC, USOSWHERE),
the text-mode corner rows were visible for one frame
(`13:0201 15:8801 21:3FC6 2F:1123`, COMMAND transient at 94C6h). Result:
HIMEM, VBMOUSE and USOSKBC are not the cause (D5 = SETVER + USOSWHER only).
USOSWHER /G drew nothing over the logo in D1 and D5: either the timer
interrupt stops after the logo (CLI loop / IRQ0 masked) or the 1.0 mode
check missed the graphics mode (it trusted the BDA mode byte and the INT 10h
1130h font pointer).

USOSWHERE 1.1 (feature/win203-diag2) removes the second possibility: planar
graphics is also detected from the VGA graphics controller (GC 6 bit 0,
GC 5 bit 6 and SEQ 4 bit 3 clear), the font falls back to F000:FA6Eh and the
install line prints the font pointer, and row 1 starts with `10:` = AX of the
last INT 10h AH=00h (mode set). Next X470 run: D5 only. Rows over the logo =
read CS:IP and whether t counts; still no rows = the timer interrupt is dead
after the logo (then: disassemble WIN.COM's loader after the logo).

### D5 with USOSWHERE 1.1 (2026-10-09) and USOSWHERE 1.2

Video VID_20261009_163727: the text-mode corner is visible for one frame
after the install lines (`USOSWHERE /G font C000:5C98`; corner
`94C6:3A9E t:0001 p:1029 COMMAND.`, `10:0000 13:0201 15:0000 21:4E00
2F:1123`), then one black frame (mode set), then the 2.03 logo for the rest
of the video with no corner rows. Ctrl+Alt+Del during the hang resets the PC
(keyboard IRQ and BIOS INT 09h still run, interrupts are on).

Static analysis (installed WIN.COM = WIN.CNF + CGA.LGO + MSLOGO.LGD, 3952 +
468 + 2570 = 6990 bytes, the size on the target): the logo code CGA.LGO sets
**mode 06h** (CGA 640x200 two colours; INT 10h AX=0006h, then AX=1000h/1001h
make colour 0 blue). USOSWHERE 1.1 only drew in modes 0Eh/10h-12h, so the
missing corner says nothing about the timer. WIN200.BIN has no port-61h
refresh-bit or CMOS update-in-progress loops: port 61h is only the keyboard
ACK toggle (KEYBOARD) and the beep (PIT channel 2 with fixed LOOP delays);
no `in al,40h` timing loops.

USOSWHERE 1.2 (feature/win203-diag3): `/G` also draws in mode 06h (B800h,
interlaced banks, 1 bit per pixel); a fourth row `k:cccc:iiii n:nnnn` holds
the CS:IP interrupted by the last keyboard IRQ and the number of keyboard
IRQs, and INT 09h (chained unchanged) also redraws the corner. During a hang:
t counting = timer alive, CS:IP row 0 is the loop; t frozen + k changing on
each Shift press = IRQ0 masked or INT 08h taken over, k is the loop. Handler
paths unit-run with unicorn (text mode and mode 6 layout), no VM.
