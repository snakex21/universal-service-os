# FreeDOS 1.4: keyboard and mouse in EDIT (2026-10-23)

X470 report (B261023-130119-3FA9A5CF, FreeDOS 1.4 FullUSB image-to-disk on
the Micron NVMe, UEFI -> CSMWrap -> SeaBIOS, CSM off): the USB keyboard
works at the FreeDOS prompt; in FreeDOS EDIT neither the keyboard nor the
USB mouse works; Ctrl+Alt+Del works. MS-DOS 6.22 on the same machine and
build: keyboard and mouse fully work.

Status: mouse fixed, **QEMU only**; the keyboard failure is **not
reproduced** in QEMU (details below). Not run on the X470 yet.

## Evidence

FullUSB image (`FreeDOS 1.4 FullUSB.img`, FAT32 at LBA 63), read on the host:

- `FDCONFIG.SYS`: COUNTRY, LASTDRIVE, BUFFERS, FILES, `DOS=HIGH`, `DOS=UMB`,
  `DOSDATA=UMB`, `DEVICE=\FREEDOS\BIN\HIMEMX.EXE`, `SHELLHIGH=COMMAND.COM
  /P=\FDAUTO.BAT`. No KEYB, no JEMM/EMM386, no boot menu.
- `FDAUTO.BAT`: UHDD (absent), `CDROM.BAT` (UDVD2 etc.), FDNET/FDASSIST
  (absent), then the installer check. **No mouse driver**: CTMOUSE, KEYB,
  MKEYB, XKEYB exist only as packages in `PACKAGES\BASE`, not in
  `FREEDOS\BIN`. Nothing touches the 8042 or INT 09h.
- MS-DOS flow under CSMWrap (`src/platform/bios/msdos/install.cmd` 48-67):
  `C:\DOS\VBMOUSE.EXE` and `C:\DOS\USOSKEY.COM` in AUTOEXEC.BAT. VBMOUSE
  (VBADOS 0.67, GPL-2.0+) is the INT 33h driver on INT 15h C2xxh, which
  CSMWrap's SeaBIOS serves from the USB mouse (docs/dos-mouse-2026-10-18.md).
  USOSKEY.COM only captures keys while a Windows 3.x/9x driver polls it;
  in plain DOS it passes everything through, so it is not part of the
  FreeDOS change.
- FreeDOS EDIT 0.9a (D-Flat+, UPX-packed; inspected unpacked in the QEMU
  guest's memory while it ran, PSP 055Dh): its only input calls are three
  `int86(0x16)` sites (AH = 00/01/02 or 10/11/12 by the 101-key bit at
  0040:0096) and one `int86(0x33)` site; no `in al,60h`, no INT 09h/08h/15h
  hook (IVT while EDIT runs: 08h/09h = kernel stack wrappers 0070:000F/
  0070:0016, 16h = F000:E82E SeaBIOS). **INT 33h = 00D9:1285, the kernel's
  default IRET stub**: no mouse driver, so EDIT has no mouse (and draws no
  scroll bars; with VBMOUSE it does).
- CSMWrap SeaBIOS 3.1.2 (`seabios/src/clock.c` clock_update ->
  usb_check_event; `kbd.c` handle_16): USB keys reach the BDA buffer from
  IRQ0, INT 16h AH=10h/11h/12h read it. That is the same path as the prompt.

## Fix

`tools/image_disk_target.sh`:

- `freedos_mouse` (called from `freedos_fix` before `freedos_net`): copies
  `VBMOUSE.EXE` + `VBADOS.TXT` from the stick's
  `EFI\USOS\dos-native\msdos` (the files the MS-DOS flow installs; source
  `VBADOS.TGZ` stays there) to `C:\USOS`, read back by sha256, and adds
  `rem USOS mouse: ...` + `if exist C:\USOS\VBMOUSE.EXE C:\USOS\VBMOUSE.EXE`
  to FDAUTO.BAT before the installer check (before the network line). A
  missing file or mtools tool: one log line, no change.
- `freedos_auto_add`: the guarded FDAUTO.BAT insertion (CRLF, once,
  read-back) shared by `freedos_mouse` and `freedos_net`.

No FreeDOS component is disabled: nothing in the image conflicts (no KEYB,
no CTMOUSE, no EMM).

## Tests

Host: `python tools/tests/test_freedos_net.py` 10 OK (3 new: staging + line
order + idempotency, missing file, wiring like the MS-DOS flow);
`test_image_disk_pmbr`, `test_image_disk_elcr` OK.

QEMU only (`run_custom_os_micro_linux_qemu.py --system freedos`, real
micro-Linux prepare, then q35 OVMF -> CSMWrap -> SeaBIOS, qemu-xhci usb-kbd
+ usb-mouse, `i8042=off`; images deleted afterwards):

- before: prompt and EDIT keyboard work (`edit t.txt`, typed `Hello`), also
  with an i8042 present; EDIT has no mouse (INT 33h = IRET stub, no scroll
  bars).
- after: prepare logs `FreeDOS mouse: C:\USOS\VBMOUSE.EXE staged, FDAUTO.BAT
  loads it, read-back PASS`; boot shows `VBMouse 0.67 ... Wheel mouse found
  and enabled ... Driver installed` before the network line; in EDIT a USB
  mouse click on the top-left opens the window's system menu, Esc, typed
  ` World` -> `Hello World`, Col 12.

## Open: keyboard in EDIT on the X470

Not reproduced: in QEMU EDIT reads the USB keyboard through INT 16h exactly
like the prompt, with and without an i8042. Nothing in the FreeDOS image
hooks the keyboard. The X470 check after this build: does the keyboard work
in EDIT now that VBMOUSE is loaded (as in the MS-DOS flow)? If not, the
next step is a silent INT 16h/INT 08h counter log on the target disk while
EDIT runs (hardware-only diagnostics), not a guess.
