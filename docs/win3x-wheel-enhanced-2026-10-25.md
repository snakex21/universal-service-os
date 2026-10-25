# Windows 3.1 wheel in 386 enhanced mode (design, 2026-10-25)

X470, Windows 3.1 PL under CSMWrap (B261024-210648): the mouse wheel scrolls
in standard mode (`WIN /S /B`) and does nothing in 386 enhanced mode
(`WIN /3 /B`). Pointer and buttons work in both. Diagnosis from the code
only; nothing below has run yet.

## How the wheel gets to Windows 3.1 today

Windows 3.x under CSMWrap uses VBADOS 0.67 unmodified (tools/vendor/vbados):
`VBMOUSE.EXE` (DOS TSR, AUTOEXEC) and `VBMOUSE.DRV` (`[boot] mouse.drv`,
W3INI.BAS). USOS adds no wheel translation for 3.x; our own USOSMOUS.DRV
wheel paths are for 95/98/Me only.

1. CSMWrap patch 0016: SeaBIOS reads a USB wheel mouse in the HID report
   protocol and emulates a PS/2 IntelliMouse for INT 15h C2xxh. The knock
   (C202h sample rates 200, 100, 80) sets device ID 3, which C204h returns;
   C201h/C205h reset it to 0. Package size 1/2 (byte stream): a 4th byte after
   the knock. Package size 4..7: the 4th byte. Patch 0020: package size 3
   always passes the wheel in the handler's Z word (4th stack word), also
   without the knock.
2. VBMOUSE.EXE switches the mouse to IntelliMouse mode itself.
   `reset_mouse_hardware()` (mousetsr.c, at load and on every INT 33h
   AX=0000h): C205h with package size 1 ("streaming"), then
   `ps2m_detect_wheel()` = the knock + C204h; ID 3 means 4-byte packets, wheel
   events in the INT 33h wheel API (CuteMouse API: AX=0011h, BH = wheel delta,
   event bit 7).
3. VBMOUSE.DRV `Enable` resets the INT 33h driver, asks AX=0011h, and turns
   wheel events into WM_VSCROLL/WM_HSCROLL to the scroll bar under the pointer
   (mousew16.c `send_wheel_movement`).

## Why enhanced mode loses it

mousetsr.c `reset_mouse_hardware()`:

```
if (data.haswin386) {               /* set by INT 2Fh AX=1605h */
    err = ps2m_get_device_id(&device_id);
    if (err || device_id != PS2M_DEVICE_ID_IMPS2)
        data.bios_packet_size = PS2M_PACKET_SIZE_PLAIN;   /* 3 bytes */
}
...
if (usewheel && bios_packet_size == PS2M_PACKET_SIZE_STREAMING && ps2m_detect_wheel())
    haswheel = true;  else  haswheel = false;
```

and `ps2_mouse_handler()` in plain mode drops the 4th word
(`(void) word3;`). VBADOS does this deliberately: Windows' VKD.386 virtualises
the 8042, does not forward the knock and splits 4-byte packets
(VBADOS README, "Scroll wheel support under Windows 386 enhanced mode"; its
upstream fix is a patched VKD.386 that reports ID 3, the "wheelvkd" check
above). So when VBMOUSE.DRV's `Enable` resets the driver inside the running
enhanced-mode Windows, VBMOUSE uses 3-byte packets and `haswheel` = false,
unless C204h still says 3 at that moment. VBMOUSE's own resets leave ID 3
behind, so presumably another INT 15h client resets the emulated ID to 0
between the DOS-time reset and `Enable` (C201h/C205h without the knock; the
same was seen on Windows Me, patch 0020 notes; not confirmed for 3.1). One
such reset is enough: from then on every VBMOUSE reset takes the plain path
and never knocks again. The C2xxh ring of patch
0020 (USOSMWHL record +312) would name that caller; no Win 3.x reader for it
exists yet. In standard mode `haswin386` is false, the check is skipped, the
knock succeeds again and the wheel works, which matches the X470 report.

Under CSMWrap the 8042 and VKD are not on the mouse path at all: SeaBIOS
far-calls the C207h handler from its USB poll with the whole packet. The
"plain" fallback is therefore unnecessary here, and SeaBIOS already passes the
wheel in the Z word of those 3-byte packets (patch 0020), but VBMOUSE throws
it away.

SeaBIOS side (read only, 3.1.2-usos18 patches 0016/0020): yes, it delivers
4-byte IntelliMouse packets (package size 1/2 after the knock, 4..7 always),
and with package size 3 the wheel in the Z word. Nobody in the BIOS switches
the mouse to IntelliMouse mode by itself; the client does (VBMOUSE's knock,
or USOSMOUS.DRV's on 98/Me).

## Fix options (none implemented)

No new VxD is needed. The fix sits either in the vendored VBADOS driver or
in our USOSKEY pair.

A. VBMOUSE.EXE patch (VBADOS is GPL-2.0-or-later; about 10 lines in
   mousetsr.c). In plain mode keep `word3` as `ps2_packet[3]`, and detect the
   wheel with the knock also with package size 3 (`haswheel` from C204h == 3
   after the knock, `packet_size` stays 3). With a real 8042 behind VKD the
   knock is not answered with ID 3, so nothing changes there. Costs: rebuild
   VBMOUSE.EXE with OpenWatcom (wmake, `vbmouse.lnk`, nls), ship the modified
   source and patch next to it (SOURCES.txt, manifest hashes), and retest the
   DOS and Windows 1.x-3.x mouse on the X470, because the X470-proven
   upstream binary is replaced. Cleanest result: the wheel goes through the
   INT 33h wheel API to VBMOUSE.DRV, as in standard mode.
B. Our components only: USOSKEY.COM + USOSKEY.DRV (both already loaded in
   Windows 3.1). USOSKEY.COM's INT 15h hook (usoskey.S `int15`, today only
   AH=4Fh) also takes AX=C207h: it remembers the caller's handler (VBMOUSE's),
   registers its own trampoline with SeaBIOS, and the trampoline adds the Z
   word to a notch counter in the shared block (version 5) before it
   far-calls the saved handler with the same four words. USOSKEY.DRV, only
   when `GetWinFlags() & WF_ENHANCED` (in standard mode VBMOUSE scrolls
   itself, so there would be two scrolls), reads the counter from its timer
   and sends WM_VSCROLL through the existing Windows 95 path of
   usoskey_wheel.h (`wheel_decide95`, WS_VSCROLL window under the pointer,
   [usosmous] WheelScroll=0 off). C207h with 0:0 passes through and clears
   the saved handler. Costs: assembly in a TSR every DOS/Windows 3.x install
   loads, one more far call per packet, and an X470 test of DOS + 3.1
   standard and enhanced mode.

Recommendation: A, if replacing the vendored binary is acceptable; it fixes
the cause, and DOS programs under enhanced Windows get the wheel too. B, if
the vendored VBADOS must stay as it is.

Cheap X470 check before either one (yes/no, no rebuild): none from the
user's side. The confirming log would be the patch 0020 C2xxh ring read under
Windows 3.1 enhanced mode, which needs a small DOS reader for the USOSMWHL
record; one could be added to the next diagnostic kit.
