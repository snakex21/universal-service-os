USOS - FreeDOS tools
===================

On your USB drive put DOS programs in Utilities\FreeDOS\Programs.
Each program can have its own folder. Keep its EXE/COM/BAT, DOS extender,
configuration and data files together. Use DOS 8.3 names: up to eight
characters, then an optional extension of up to three characters.

The programs are copied into C:\PROGRAMS before FreeDOS starts.
C: is a 64 MiB RAM disk. Configuration, temporary files and all results
created in this session disappear after restart or power-off.
The session does not mount the USB's NTFS partition from DOS.

Doszip Commander controls:
  Arrows and Enter: open a folder or run EXE, COM or BAT.
  Ctrl+Enter: insert the selected filename into the command line.
  Add the arguments required by the program, then press Enter.
  F3: view a file. F4: edit. F10: close to the DOS command prompt.
  Type TOOLS: reopen the file manager. Type REBOOT: return to USOS.

FreeDOS starts without HIMEM, EMM386 or SMARTDrive. It can run compatible
16-bit and 32-bit DOS programs. Windows EXE programs require Windows.
32-bit DOS programs may require their own extender or DPMI host.
The USOS loader requires a BIOS PC and at least 128 MiB RAM for this mode.

Flashers must match the actual hardware and firmware file. Nothing is
flashed automatically. Use the utility vendor's instructions; some tools
require Microsoft DOS, a physical boot disk or a different memory setup.
MEMDISK supplies the RAM disk. BIOS disk services expose only that disk;
programs that access hardware directly can still access the real hardware.
A firmware backup saved only on C: will be lost on restart.

FreeDOS kernel 2043, FreeCOM 0.86a and Doszip Commander 2.68 are included
under GPLv2. Their complete upstream packages and source archives are
included in EFI\USOS\dos-native\freedos on the USB drive.
