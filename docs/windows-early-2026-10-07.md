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

Open: no unattended answers for 1.0x-3.0 (a BIOS keystroke feeder would do it);
inside Windows 1.0x-3.0 the keyboard is KEYBOARD.DRV on the 8042 (PS/2
keyboard on the X470; USOSKEY.DRV needs Windows 3.1); USB mouse in 2.x / 3.0
through their PS/2 driver under CSMWrap is untested; 1.04, 2.11 (286/386)
start from the menu and 3.0 standard mode not yet verified.
