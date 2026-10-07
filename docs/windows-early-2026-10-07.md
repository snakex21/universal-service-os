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
