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

### D5 with USOSWHERE 1.2 (2026-10-09): where the CPU is, and USOSWHERE 1.3

Two photos about 10 s apart over the logo: `124A:0FAD t:00D9 p:124A WIN..u.`
then `t:014E` (timer alive, every tick at 124A:0FAD, current PSP = WIN.COM);
`10:0006 13:0201 15:8800 21:4B00 2F:1123`; CS history `124A 1351`;
`k:1351:00B1 n:0001`.

Reading (static, installed WIN.COM read raw from the target = WIN.CNF +
CGA.LGO + MSLOGO.LGD byte for byte):

- WIN.CNF is loaded at CS:0100-106F, the logo CGA.LGO at CS:1070 = segment
  CS+107h = **1351h** (the second CS in the history). At 0361h WIN.COM sets
  `mov sp,1070h`: its stack is the 256 zero bytes at CS:0F70-106F at the end
  of WIN.CNF. **IP 0FADh lies inside that stack** (0C3h below its top);
  there is no code there in the file. The CPU executes stack residue: a far
  return/IRET went to a stale address. It is not a polling loop of WIN.COM.
- k: 1351:00B1 is CGA.LGO right after INT 10h AX=1000h (palette): one IRQ1
  that was pending through the mode set. n stays 1 because D5 has no
  USOSKBC /R: SeaBIOS (CSMWrap) polls the USB keyboard from IRQ0 and puts
  keys into the BDA buffer without raising IRQ1; Ctrl+Alt+Del is handled in
  that poll. The keyboard is not dead.
- `15:8800` comes from MEM.EXE ("Memory accessible using Int 15h", run just
  before WIN in D5). WIN.COM, CGA.LGO and WIN200.BIN contain no INT 15h at
  all, so an oversized INT 15h AH=88h result is **not** the cause.
- Order in WIN.COM: logo (CGA.LGO entry 4), INT 21h 4Ah shrink to 107h+
  logo paragraphs, 48h FFFFh check against 49C0h paragraphs, then EXEC
  `4B00h` of WIN200.BIN at 06FAh-070Eh (SS:SP saved in CS:0107h/0109h,
  124A:1004h). WIN200.BIN is an MZ (KERNSTUB, entry 0000:0000, SS:SP
  000B:0080) with min = max alloc = 0, i.e. **loaded high** (219 KB at the
  top of conventional memory, about 6915h-9FC0h with 639 KB).
- After the EXEC: no further INT 21h (the kernel would call DOS at once), the
  current PSP is still WIN.COM (DOS switches it only when it enters the
  child), and no INT 10h AX=0003h (WIN.COM restores the text mode through
  CGA.LGO entry 7 when the EXEC fails). So the hang starts inside the EXEC
  (loading the image) or in the first instructions of KERNSTUB, and ends with
  the CPU in WIN.COM's stack.

Windows 1.04 (works on the X470) is also loaded high but its image is
smaller; a candidate cause is something in the lower part of that range
(conventional memory used by firmware/CSM code without being reserved);
not proven.

USOSWHERE 1.3 adds two rows to decide it from one photo:
`c:<8 code bytes at CS:IP> s:<interrupted SS:SP> d:<crit-error, InDOS>` and
`w:<top 3 stack words> b:<ES:BX of the last INT 13h> i:<INT 13h count>`.
d: ...01 = still inside DOS (EXEC); i: growing = disk reads go on, frozen =
stopped; b: = the load address reached; c: shows what really runs at 0FADh.
Handler paths unit-run with unicorn (text mode, mode 6, INT 13h keeps
registers and flags), no VM.

### D5 with USOSWHERE 1.3 (2026-10-09): an invalid-opcode loop, and USOSWHERE 1.4

Two photos, same values except t (00A1, 013B: timer alive):
`1263:0FAD p:1263 WIN`, `10:0006 13:0201 15:8800 21:4B00 2F:1123`,
CS history `1263 136A 94C6`, `k:136A:00AA n:0001`,
`c:0F00000000000000 s:1263:106F d:0000`,
`w:4C03 474F E94F b:0C3F:257C i:0053`.

- `0F 00 00` at 0FADh is SLDT [BX+SI]: invalid in real mode (#UD, INT 06h on
  286 and later). The INT 06h vector of SeaBIOS/CSMWrap is a bare IRET, so
  the CPU faults on the same instruction forever; IF is restored by that
  IRET, every timer tick lands on 0FADh, and no other CS shows up (the INT
  06h handler runs with IF=0). Bytes 0F70h-0FACh are zeros (`00 00` = ADD
  [BX+SI],AL): the CPU entered the stack area of WIN.COM somewhere below
  0FADh and slid up to the first non-zero byte.
- The "stack words" are not saved registers: SS:SP 1263:106F is one byte
  below the top of the empty stack. 106Fh = 03 (high byte of the return
  address 03CAh of WIN.COM's `call 052Fh`, the EXEC routine), 1070h-1073h
  = `LOGO` (the CGA.LGO signature), 1074h = `E9` (its JMP).
- d:0000 (not in DOS), current PSP still WIN.COM, last INT 21h = 4B00h, and
  no INT 10h AH=00h after it (WIN.COM restores the text mode through
  CGA.LGO entry 0007h right after any EXEC return, also a failed one).
- WIN200.BIN: KERNSTUB checks `NE` at image 200h and far-returns into the
  KERNEL entry (segment 1, IP 7E3Ah); KERNEL reads WIN.COM's handshake data
  through PSP:16h, checks EMMXXXX0 and calls INT 21h AH=30h within about 50
  instructions. KERNEL segment 1 contains no 0Fh opcode at all (no LOADALL,
  SMSW, SLDT). With p: still WIN.COM and no INT 21h after 4B00h, the child
  most likely never ran: the CPU left the DOS EXEC call by a path that is
  neither the child entry nor the normal return to 0710h.
- b:0C3F:257C lies in the DOS buffers (IO system data 0B8Ah-1025h): the last
  disk read went through a DOS buffer (FAT/directory/header or the last
  partial sector), not straight into the image; i: frozen at 53h.

Not provable from the binaries alone, so USOSWHERE 1.4 records the path:
an INT 06h handler that dumps one text screen on the first #UD (CS:IP,
FLAGS, registers, 8 code bytes, 8 stack words and the last 176 traced
instruction addresses, then halts with interrupts on), and an instruction
trace (INT 01h, trap flag) armed when a program named WIN* calls INT 21h
AX=4B00h; TF is set for DOS and in the caller's saved FLAGS, BIOS/ROM code
(CS >= C000h) runs untraced (the caller's IRET restores TF), consecutive
repeats are stored once, and the first INT 21h afterwards ends the trace
(f: = its AX and caller CS:IP). No DOS call and no #UD within 10 s: the
timer dumps the same screen (reason T). Corner row 3 adds x: (steps) and
f:. Unicorn unit run (emulated real-mode INT/trap/#UD delivery): fake DOS
with a ROM far call and a LOOP, failed EXEC, zero slide to `0F 00 00` -> the
ring ends `... 1263:0F99 ... 1263:0FAD`, ROM not recorded; the trace end
by INT 21h and the 10 s dump path covered. 1.3's `call dword ptr` would
assemble with a 66h prefix; 1.4 uses an explicit FF /3 far call (CALLFAR).

### D5 with USOSWHERE 1.4 (2026-10-09): the video BIOS overruns WIN.COM's stack; USOSV10

Dump screen: `U at 12E4:0FAD x:0000 u:0001`, `ax:0FA2 bx:0007 cx:0023
dx:18BF si:0002 di:007E bp:091C ds:13EB es:B800`, `s:12E4:106F`. x:0000:
the trace never armed, so WIN.COM never issued its EXEC (the 21:4B00 seen
before was COMMAND.COM starting WIN.COM). DS = 13EBh = CS+107h is the
segment of CGA.LGO, ES = B800h its drawing target, BX = 0007h is only set
by its text routine (CGA.LGO 001Ah: AH=02h/0Eh), BP = 091Ch is WIN.COM's
own BP (DOS start value) restored by the logo's `pop bp`: the hang starts
in or right after the logo, not in the EXEC.

Cause (static + Unicorn with the real WIN.COM, local copy only): WIN.COM
sets SP = 1070h; its stack is the 256 bytes behind its own code
(CS:0F70-106F), and the logo is entered from CS:0F39-0F6C, returning to
0F6Dh (`pop ds; ret`). Every INT 10h of CGA.LGO (AH=0Fh, AX=0006h,
AX=1000h/1001h, then AH=02h/0Eh per character) runs with SP = 103Ch-1040h,
i.e. about 200 bytes above that code. A 1987 BIOS used a few dozen bytes; a
video BIOS that needs more than ~190 bytes of the caller's stack overwrites
WIN.COM's code at 0F39-0F6E, and the logo's final RETF to 0F6Dh executes
stack residue and slides into the empty stack area. QEMU's SeaVGABIOS
switches to its own stack (extra stack), so QEMU never showed it; the RX 560
option ROM on the X470 runs on the caller's stack.

Unicorn run (scratch w203/repro203.py, WIN.COM from the BIOSTAR, video BIOS
stub that uses N bytes of stack): N <= 128 reaches WIN.COM's first INT 21h
(AH=4Ah at 0904h) with code intact; N = 192/200 ends in the stack area of
12E4 with DS=13EB ES=B800 BX=0007 CX=0023 BP=091C (the X470 dump registers),
N >= 208 runs away. With USOSV10 resident every N up to 400 reaches 0904h
with 0F39-0F6E intact. Register clobbering by the BIOS (BX..ES) cannot
over-pop: the logo unwinds by SP and restores BP itself.

Fix: **USOSV10.COM** (src/platform/bios/win9x/usosv10.S, GPL): TSR, INT 10h
on a private 2 KiB stack (outermost call only; nested calls chain on that
stack), and for the functions that return nothing but AX (AH=00h-0Eh except
03h/04h, AX=1000h-1003h/1010h/1012h) BX, CX, DX, SI, DI, BP, DS, ES restored
as a CGA/EGA BIOS kept them; arithmetic flags from the BIOS, IF/TF from the
caller. The stack is pre-filled with 5Ah; `USOSV10` run again prints the
deepest use and the call count (at install it measures a no-clear mode set
of the current text mode). W1AUTO.BAT loads it first in every item except
D5 (control) and writes the report into Dn.TXT before WIN and after "WIN
returned". New menu item D6V10 = D5 + USOSV10. Build: build_win9x_support
(build_usosv10), staged msdos/USOSV10.COM -> C:\DOS by INSTALL.BAT, payload
list. Tests: tools/tests/legacy_bios/test_usosv10.py (tiny stack below code
breaks without, runs with; registers/flags; outputs pass through; nesting;
install + report), test_win_early_flow.py.

### X470 PASS (2026-10-09): Windows 2.03 via D6; USOSV10 in the default start

D6 (D5 + USOSV10, no USOSKBC) reached the MS-DOS Executive on the X470 /
RX 560 (PS/2 keyboard only, as expected without USOSKBC): the cause above is
confirmed. The default items (Windows, WIN /S, MS-DOS) load USOSV10 first,
then VBMOUSE and USOSKBC /R (USB keyboard); USOSWHER stays in the diagnostic
submenu (now "Diagnostyka (D1-D6, tylko do testow)"). INSTALL.BAT copies
USOSV10 also without CSMWrap (the video BIOS stack depth does not depend on
it). Windows 2.11, /286 and /386 use the same WIN.COM logo path and likely
benefit too. Windows 3.1/WfW and 9x DOS phases do not load USOSV10 (no
known need; their own stacks are larger).

## USB mouse for Windows 2.x and 3.0: USOSKBC /M (2026-10-09)

Static reading of the shipped MOUSE.DRV (2.03 = 2.11/286 = 2.11/386 byte
for byte; 3.0a after EXPAND): one driver for bus, serial and PS/2 mice that
finds the port itself. The PS/2 path asks the BIOS: INT 15h C0h (model byte
FAh/FCh/F8h; SeaBIOS: FCh -> IRQ 12, vector 74h), INT 11h bit 2 (SeaBIOS
sets it), then C205h/C201h/C203h/C207h/C200h/C206h/C202h (all served by
SeaBIOS's USB mouse emulation). Its C207h callback only stores the 3 bytes
and sets a flag; the event goes to Windows from the driver's own INT 74h
handler, which first chains the previous INT 74h (the BIOS IRQ 12 code,
which calls the callback on a real PS/2 mouse). Under CSMWrap SeaBIOS polls
the USB mouse from INT 08h and calls the callback there; IRQ 12 never
fires, so the flag is set and nothing reaches Windows - the pointer stands.

`USOSKBC /M` (src/platform/bios/msdos/usoskbc.S, own GPL code):
* hooks INT 74h at install with a stub that, during its own software
  INT 74h, returns at once (no BIOS IRQ 12 code, no EOI); otherwise chains
  to the BIOS. MOUSE.DRV hooks INT 74h later and chains to this stub.
* INT 15h AX=C207h: remembers the caller's handler and registers a
  trampoline with the BIOS (caller keeps ES:BX, gets the BIOS's CF/AH; 0:0
  goes straight through). The trampoline calls the caller's handler with
  the same status/X/Y/Z words and marks an INT 74h as due.
* INT 08h (after the BIOS, i.e. after the USB poll): when due and someone
  hooked INT 74h above the stub, issues INT 74h -> the driver dispatches
  the packet exactly as after a hardware IRQ 12.
* No 8042 needed (the D3h aux-buffer idea is not needed: the drivers never
  read port 60h on their PS/2 path). Shared block version 2: mcb, mpackets,
  mkicks, old74, mpend, msoft after old2f.

Start menu (W1AUTO): `USOSKBC /R /M`; Setup (W1SETUP.BAT): `/R /M` too
(Windows part of 3.0 Setup). W203.KEY picks "Microsoft Mouse (Bus or
Serial)" again (= MOUSE.DRV, first list entry; the 2.03 logo hang was the
video BIOS stack, USOSV10). 2.11 (/286, /386) and 3.0 Setup keep their
detected mouse: the 2.11 machine default is the Microsoft Mouse; 3.0 Setup
asks INT 33h AX=24h (VBMOUSE is loaded by the install AUTOEXEC) -> PS/2 ->
MOUSE.DRV.

Per version:
* 2.03, 2.11/286, 3.0 real mode (WIN /R, default): expected to work.
* 2.11/386 (V86, WIN386) and 3.0 standard mode (WIN /S, DOSX): untested;
  the software INT 74h is issued in real/V86 mode from the timer hook.
* 1.01/1.04: no PS/2 mouse driver exists (MOUSE.DRV bus/serial only,
  MSMOUSE1/2 serial, LMOUSE Logitech serial/bus) and no driver uses the BIOS
  or INT 33h; a USB mouse would need either our own 1.x mouse driver
  (bound into WIN100.BIN by Setup) or a serial/bus mouse hardware emulation
  (not possible in real mode without I/O trapping). Not done.

The mouse driver is bound into WIN200.BIN / chosen in SYSTEM.INI by Setup:
an existing 2.03 install with "No mouse" needs a fresh install (or a second
Setup) to get MOUSE.DRV. Unit test: tools/tests/legacy_bios/test_usoskbc_mouse.py
(Unicorn: install, C207h trampoline incl. error and remove, packet from the
timer -> driver's INT 74h -> event, no kick without a hook, real IRQ 12 to
the BIOS). Hardware test pending (no QEMU proof: QEMU has a real PS/2 mouse).

## USB mouse for Windows 1.0x: USOSMS1.DRV (2026-10-15)

Windows 1.01/1.04 now get their own mouse driver, `USOSMS1.DRV`
(src/platform/win1/usosms1.S, GPL-3.0-or-later), which uses the BIOS
pointing device (INT 15h AX=C2xxh) - under CSMWrap the only form in which
the USB mouse exists.

Interface (read from the NE headers and code of the 1.01/1.04 mouse drivers
on the user's media; no Microsoft code used): module name `MOUSE`, exports
INQUIRE (1), ENABLE (2), DISABLE (3); MOUSEINFO is 14 bytes (exists,
relative, buttons, rate, X/Y threshold, X/Y resolution; no COM port field as
in 3.x); the event procedure from Enable is far-called after the EOI with
interrupts on: AX flags (1 move, 2/4 left down/up, 8/10h right down/up),
BX/CX relative movement (Y down positive), DX number of buttons. Setup offers
NOMOUSE, MOUSE (Microsoft bus/InPort or serial), MSMOUSE1/2 (Mouse Systems
COM1/2), LMOUSE (Logitech serial), JOYMOUSE (1.04 also ATTMOUSE); none of them
calls the BIOS. Setup's Build step re-links the chosen driver into WIN100.BIN
(it rewrites the NE headers, alignment 512 -> 16), so the driver must be an
NE file Setup accepts: USOSMS1.DRV copies the shape of NOMOUSE.DRV (linker
version 4.0, flags 8004h, one fixed preloaded segment with code and data, no
relocations, no imports, no entry point); tools/build_win3_usb_keyboard.py
assembles the segment (zig cc, linked at 0) and writes the NE file itself.

Driver: Inquire initializes the BIOS device (C205h, 3-byte packets; failure
= no mouse, Windows runs like NOMOUSE). Enable registers its C207h handler
(stores packets in a 32-entry ring), enables the device (C200h) and hooks
INT 74h and INT 08h; both chain the previous handler first and then hand the
queued packets to USER (one dispatcher at a time). INT 74h covers a real PS/2
IRQ 12 and the software INT 74h of `USOSKBC /M`; INT 08h covers a start
without USOSKBC. Movement is divided by 2 (word after the `USM1` signature,
remainder carried): a USB mouse reports far more counts than a 1985 bus
mouse, and USER doubles deltas above the thresholds (2, as the shipped
drivers). Disable: C200h off, C207h 0:0, vectors back when still ours.

Flow: dos_csmwrap_target.sh keeps USOSMS1.DRV in USOSDOS only for
windows-1-01/1-04; INSTALL.BAT (EARLY.TAG + CSMWRAP.TAG branch) copies it
over C:\WINSETUP\MOUSE.DRV, so the existing W101/W104.KEY answer "2"
(Microsoft Mouse) binds it. No user step. Existing 1.x installs need a fresh
install (the driver lives inside WIN100.BIN).

Tests: tools/tests/legacy_bios/test_usosms1.py (Unicorn: NE shape, Inquire
with and without a BIOS mouse, Enable/Disable calls and vectors, packets from
the BIOS timer -> events incl. sign bits, overflow, button transitions,
software INT 74h, divisor with carried remainder, foreign hook kept);
test_win_early_flow.py (Win1Mouse). QEMU (scratch harness: SeaBIOS =
CSMWrap's BIOS, `-machine pc,smm=off`, qemu-xhci usb-kbd + usb-mouse,
i8042 present but SeaBIOS routes the BIOS mouse to the USB mouse when one is
attached): fresh unattended installs of 1.04 and 1.01 bound the driver
(`USM1` inside WIN100.BIN); pointer moves, 40 packets -> 40 events, clicks
select files, double-click starts CALC.EXE (1.04) and PAINT.EXE (1.01), a
pencil drag draws in Paint, a dialog closes with a click. QEMU is not
hardware evidence; the X470 test is pending (fresh 1.0x install).

## DOS network in the start menu (2026-10-23)

W1AUTO.BAT (all default items, not D1-D6) and W3AUTO.BAT call
`C:\NET\NETSTART.BAT` (own packet driver USOSPKT + mTCP DHCP) before WIN;
INSTALL.BAT stages `C:\NET` for every Windows 1.x-3.x install. QEMU only:
1.01, 2.03, 3.0a, 3.1 start with the driver resident, HTGET works after
leaving Windows. Details: `docs/win3-net-2026-10-23.md`.

## WIN at the prompt, product names, regional settings (2026-10-24)

- **WIN typed at the DOS prompt** = the menu's mode. W3AUTO.BAT and
  W1AUTO.BAT (Windows 3.0 only: `SYSTEM\DOSX.EXE`, no WIN386) load
  `DOSKEY win=C:\USOSW3\WINRUN.BAT $*` at `:end`, i.e. after Windows
  returned or after the DOS item, so Windows started from the menu runs
  without DOSKEY. A macro is expanded before COMMAND.COM looks into the
  current directory; a `WIN.BAT` in the PATH would lose to `WIN.COM` in
  `C:\WINDOWS`, where the prompt is after leaving Windows. `WINRUN.BAT`
  without arguments: 3.1 / 3.11 `/S /B`, WfW 3.11 `/3 /B` (enhanced only),
  3.0 `/R` since 2026-10-24 (was `/S`: 3.0 standard mode resets the X470,
  see "Windows 3.0a fixes" below; 386 enhanced mode under CSMWrap: keyboard
  late, no mouse); with arguments unchanged (`win /3` = 386 enhanced,
  `win progman`). Windows 1.0x / 2.x / Windows/386 keep their own WIN /
  WIN386 and get no DOSKEY. The 3.0 menu default stays `WIN /R`; the
  `WIN /S` item is only in the Diagnostics submenu now.
- **Product names** (`tools/dos_win3_menu.sh` `dos_menu_names`, called by
  `dos_csmwrap_target.sh` with `DOS_WIN_SYSTEM`): "Windows 3.1 - tryb
  standardowy (domyslny)", "Windows 3.0a (domyslny)", "Windows/386 2.11
  (domyslny)", "Windows for Workgroups 3.11 - tryb rozszerzony 386
  (domyslny)"; the revision letter comes from the image or folder name
  (`Windows 3.0a EN.iso`). Item "WIN /S" only for 3.0 (Diagnostics
  submenu since 2026-10-24). The BIOS Core path
  keeps the generic labels.
- **Regional settings** from the answer profile: `docs/answer-profiles.md`
  (`dos_regional`, `dos_keyb`, renderer `dos.zig`).

QEMU only (2026-10-24, SeaBIOS without CSMWrap, fresh MS-DOS 6.22 +
Windows install from a disk staged like dos_csmwrap_target.sh; X470 not
tested):
- 3.1 PL with a Polish DOS.INI (USB keyboard, i8042 off): menu shows
  "Windows 3.1 - tryb standardowy (domyslny)"; after leaving Windows at
  `C:\WINDOWS>` `doskey /macros` = `WIN=C:\USOSW3\WINRUN.BAT $*`, `mode con`
  = active code page 852, `date` = `2026.10.24` / `(yy-mm-dd)`; typed `win`
  = "Tryb standardowy". Typing works with KEYB PL loaded; AltGr letters do
  not (USB keys never reach KEYB's INT 09h). Same disk with a PS/2
  keyboard: AltGr+A gives "ą" (KEYB works there). Conventional memory:
  DOSKEY 4 144 B, DISPLAY.SYS 8 304 B, KEYB 6 944 B; 587 KiB free.
- 3.0a (menu "Windows 3.0a (domyslny)", item 2 "Windows 3.0a - tryb
  standardowy"): typed `win` = Standard Mode (16 MiB VM; with 64 MiB 3.0
  falls back to Real Mode for `WIN /S` as well, QEMU only), `win /3` = 386
  Enhanced Mode (PS/2 keyboard; with the USB keyboard enhanced mode hangs in
  QEMU, the known BIOS-USB-in-V86 problem).

## Windows 3.0a fixes after the X470 round (2026-10-24, B261024-183643)

**A. Standard mode resets the X470.** After File > Exit Windows a typed
`win` ran `WINRUN.BAT` -> `WIN.COM /S` (3.0 standard mode, DOSX) and the PC
restarted. The user confirmed the cause on the X470: the boot menu item
"Windows 3.0a - tryb standardowy" (`WIN /S`, no USOS batch involved after
it) restarts the PC as well. Static candidates (not proven): DOSX's 286
exit path (CMOS shutdown code 09h + triple fault, which a UEFI reset vector
does not honour) or its 24-bit descriptors with more than 16 MiB of XMS
(HIMEM reports 64512K). Change:
- `WINRUN.BAT` (`windows_run.cmd`): Windows 3.0 (`C:\USOSW3\EARLY.TAG`)
  without arguments runs `WIN.COM /R`, the menu default and the only 3.0
  mode that passed on the X470. Explicit `win /s` is passed through as
  typed.
- `W1CONFIG.SYS` (`windows_early_config.sys`): the `WINREAL` item (`WIN /S`)
  left the main menu. It is the last-but-one entry of the Diagnostics
  submenu, labelled "Windows 3.0a - standard mode (WIN /S, restarts new
  PCs)" (`dos.menu.early_standard`, all 27 catalogs). The main menu now has
  only "Windows 3.0a (default)" and "MS-DOS"; the default stays `WIN /R`.
- Windows 3.1 / 3.11 standard mode (`WIN /S /B`, menu default and typed
  `win`) is unchanged: it passed on the X470.

**B. Windows mouse dead after the DOS Prompt (3.0a real mode).** The user
confirmed the cause on the X470 with D4 (no VBMOUSE): DOS Prompt, EXIT,
the mouse still moves. Mechanism (static: expanded 3.0a WINOLDAP.MOD,
VBADOS 0.67 source `mousetsr.c`): real-mode WINOLDAP calls INT 33h AX=0
around a DOS program; VBMOUSE's reset re-registers its own INT 15h C207h
callback, which USOSKBC /M now hands its packets to, and 3.0a MOUSE.DRV
never registers again. Change (Windows 3.0 only, i.e. `SYSTEM\DOSX.EXE`):
- `W1AUTO.BAT`: no VBMOUSE before WIN (all items that loaded it: default,
  WINREAL, D1, D2). It is loaded after Windows returned, or after the DOS
  item, at `:macro_ok`, i.e. after DOSKEY, so it is the last INT 33h /
  INT 2Fh hook (D4/D5/D6 stay without it).
- `WINRUN.BAT` (typed `win`, also with arguments): `VBMOUSE uninstall`
  (VBADOS 0.67 action; it refuses when another TSR hooked INT 33h/2Fh
  after it) before `WIN.COM`, `VBMOUSE` again afterwards only when the
  uninstall succeeded.
- Not changed: Windows 1.0x/2.x and Windows/386 (VBMOUSE before WIN as
  before). Their WINOLDAP.MOD (1.01, 1.04, 2.03, 2.11) also contains
  `xor ax,ax; int 33h`, so the same reset happens there; whether their mouse
  driver recovers was never tested on the X470 (2.03/2.11 mouse PASS did
  not include a DOS program). Windows 3.1/3.11/WfW use VBMOUSE.DRV, which
  needs VBMOUSE, and passed on the X470.

**D. Quiet VBMOUSE.** VBMOUSE 0.67 has no quiet switch, and its probe
lines "Cannot find VirtualBox PCI device, err=..." / "Could not detect
VMware, err=..." go to stderr (`mousmain.c`), which `>nul` does not catch
and MS-DOS 6.22 COMMAND.COM cannot redirect. Every load in this flow is
now `ctty nul` / `VBMOUSE.EXE` / `ctty con`, then on errorlevel 1 (for
example "Cannot init PS/2 mouse BIOS") one line "USOS: the DOS mouse driver
(VBMOUSE) did not load." (`dos.mouse.vbmouse_failed`, menu language in
W1AUTO / W3AUTO.CSM / WINRUN; English in the install-stage AUTOEXEC that
INSTALL.BAT writes). Places: W1AUTO.BAT, WINRUN.BAT, the install AUTOEXEC
(`install.cmd`, also the final AUTOEXEC of an MS-DOS-only install) and
W3AUTO.CSM (`tools/build_dos_native_support.py`). LIVE.BAT (RAM session)
keeps its plain call: it clears the screen right after.

**C. WIN typed inside Windows.** W3AUTO.BAT / W3AUTO.CSM / W1AUTO.BAT set
`USOSWIN=1` before WIN.COM (WIN386.EXE for Windows/386) and clear it at
`:end`; WINRUN.BAT sets it around its own WIN.COM call. A DOS window of the
running Windows inherits that environment, so `win` typed there (the
DOSKEY macro is resident once Windows was started by a typed `win`) only
prints "Windows is already running - type EXIT to return."
(`dos.run.already_running`, all catalogs; PL "Windows już działa - wpisz
EXIT, aby wrócić."). Real-mode 3.0 answers no INT 2Fh 1600h/4680h query
reliably, hence the environment flag. 10 bytes of the 2048-byte
environment (`SHELL=... /E:2048`).

**E. Program Manager icons for staged programs (Windows 3.0 / 3.1 / 3.11 /
WfW 3.11).** `tools/dos_win3_menu.sh` `dos_program_icons`, called by
`dos_csmwrap_target.sh` right after `DATA\Systems\DOS\MS-DOS\Programs` was
copied to `C:\USOSDOS\PROGRAMS` (INSTALL.BAT then copies it to
`C:\PROGRAMS`). Each `PROGRAMS\<FOLDER>\USOSICON.TXT` (any case) may hold
lines `"Name",C:\PROGRAMS\<FOLDER>\FILE.EXE`; blank lines and `;` comments
are ignored. A line is used when the name is 1-40 printable ASCII
characters without `" , ( ) [ ]` (Setup passes it in a Program Manager DDE
command), the folder and every path part are 8.3 names, the path stays
inside its own folder (at most 64 characters), the file ends in
`.EXE/.COM/.PIF/.BAT`, it was staged, and SETUP.INF does not list it yet;
at most 30 icons. Every skipped line gets one prep-log line ("Program icons:
<FOLDER>\USOSICON.TXT line N skipped: <reason>"). Good lines are appended
to the end of the Main group section in Setup's own shape (`"Name",
C:\...\FILE.EXE`, the same shape as `"File Manager", WINFILE.EXE` and the
QEMU-proven Winsock icon): Windows 3.0 lists the group as `Main,1` ->
section `[Main]`; 3.1 / 3.11 / WfW 3.11 as `group3=<name>,1` -> `[group3]`
(`dos_main_group`, shared with `dos_winsock_apply`; checked against the
3.0a EN, 3.1 PL, 3.11 EN and WfW 3.11 PL INFs). Windows 1.x/2.x have no
Program Manager group: one log line, SETUP.INF unchanged. Test:
`tools/tests/test_win3_program_icons.py` (host shell; the micro-Linux
BusyBox awk is not run by it). Not yet run through a real Setup: 3.0 Setup
with a full path in a `[Main]` entry is unverified (QEMU or X470 check).
