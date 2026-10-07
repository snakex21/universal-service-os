# usosvbe

VESA (VBE 2.0+) display driver for Windows NT 4.0 (i386): a video miniport
(`usosvbe.sys`) and a frame buffer display driver (`usosvbe.dll`). Without a
vendor driver NT 4.0 runs at 640x480 with 16 colors (`vga.sys` + `vga.dll`).
usosvbe gives every card with a VBE 2.0 video BIOS a desktop at the BIOS's
direct-color modes, by default 1024x768 with 16 bpp. The X470 run without CSM
through CSMWrap works because the card's legacy video BIOS is still loaded
there.

**In the NT4 flow: the miniport only, with NT 4.0's own `framebuf.dll`**
(2026-10-07). Text-mode Setup installs framebuf.dll from the user's CD
(`[files.vga]`); POST.CMD falls back to expanding the CD's
`I386\FRAMEBUF.DL_`, and without it skips VESA (VGA stays). USOS never ships
framebuf.dll. `usosvbe.dll` is WIP and not shipped (see the blocker below).
Wiring: `tools/nt4_csmwrap_target.sh` (VESA.REG, POST.CMD),
`docs/nt4-2026-10-07.md`.

## How it works

* `usosvbe.sys` claims no hardware. Everything goes through NT 4.0's
  `VideoPortInt10`, which runs the video BIOS in V86 mode inside CSRSS.
  * VBE 4F00h (controller info) and 4F01h (mode info) list the modes. A mode is
    kept when it is supported, color, graphics, has a linear frame buffer
    (`PhysBasePtr`), is direct color with 15, 16, 24 or 32 bpp, is at least
    640x480 and fits in the video memory. The list is sorted by depth, width
    and height, and each width/height/depth appears once.
  * NT 4.0's BIOS arguments have no ES register: the kernel picks it. The
    buffers sit at ES:7000h and ES:7200h of CSRSS's V86 address space, and the
    first 4F00h call finds ES by looking for the new "VESA" signature. The
    queries run once, at the first open (from CSRSS), and are cached.
  * 4F02h sets a mode with the linear frame buffer bit. `IOCTL_VIDEO_RESET_DEVICE`
    goes back to text mode 03h, for example before a full-screen console.
  * `IOCTL_VIDEO_MAP_VIDEO_MEMORY` maps only the visible frame buffer (pitch x
    height) with `VideoPortMapMemory`.
  * `Services\usosvbe\Device0\UsosVbeDiag` (REG_SZ) holds one status line, such as
    `usosvbe 1.0-nt4 try=2 es=0000 vbe=0300 mem=16384k list=93 modes=61 set=1024x768x16/117 ok`.
* `usosvbe.dll` gives GDI the frame buffer as a plain top-down DIB
  (`EngCreateBitmap` with the mapped bits, `EngAssociateSurface` without hooks),
  so GDI draws everything, including a software mouse pointer. The mode comes
  from the DEVMODE GDI passes (`DefaultSettings.*` or the Display applet). If
  no listed mode matches, it uses 1024x768x16, then 800x600x16, then the first
  mode. DrvGetModes lists every mode the BIOS reports.

The DLL imports only the 8 `Eng*` routines that NT 4.0's own `framebuf.dll`
uses. The miniport imports 6 `VideoPort*` routines, `MmIsAddressValid` and
`PsGetCurrentProcessId` (trace).

## Status of usosvbe.dll (2026-10-07): WIP, not in the NT4 flow

QEMU (OVMF + CSMWrap, std VGA, EPYC-Milan, NT 4.0 WS PL SP6a): the miniport
works. `UsosVbeDiag` = `usosvbe 1.0-nt4 try=2 es=0000 vbe=0300 mem=16384k
list=93 modes=61 set=1024x768x16/117 ok`: ES is 0 in NT 4.0's V86 call, the
first try (HwInitialize) gets an error from VideoPortInt10, the second (first
query IOCTL, from CSRSS) works. The screen switches to 1024x768x16 and the
boot logo and the mouse pointer draw correctly.

**Blocker:** with usosvbe.dll the logon dialog never appears. The CPU is idle,
Ctrl+Alt+Del does nothing, and every boot logs Service Control Manager 7022
"Protected Storage hung on starting". The same miniport with NT 4.0's own
framebuf.dll (dev A/B test only; that file is on the user's CD and is never
shipped) reaches the logon dialog at 1024x768. Matched with framebuf without a
fix: the DDI entry list (DitherColor, SetPalette, SetPointerShape declining,
MovePointer), the GDIINFO and DEVINFO values (both DLLs' DrvEnablePDEV,
DrvEnableSurface and DrvGetModes were run in an emulator with stub Eng*
routines and their outputs compared), the DEVMODE layout, no hatch patterns,
and the surface (BMF_16BPP, top-down, no hooks). The trace (`UsosVbeTrace`,
IOCTL 0x8F0 from the DLL) shows only EnablePDEV, CompletePDEV, EnableSurface,
SET_CURRENT_MODE, MAP and three declined SetPointerShape calls, then nothing.
Next: compare the PE image layout (WDK GDI_DRIVER build: image base 0x10000,
sections, writable data) with framebuf.dll, then a kernel debugger on the hang.

The flow uses the same registry with `InstalledDisplayDrivers` = `framebuf`
(VESA.REG). To try usosvbe.dll instead: copy it to `system32` and set
`hex(7):75,73,6f,73,76,62,65,00,00` ("usosvbe"; NT 4.0 regedit widens each
hex(7) byte to UTF-16).

## Build

WDK 7.1 in `tools\WinDDK71` or `%WDKROOT%`:

    tools\nt4\usosvbe\build.cmd [workdir]

This writes `bin\i386\usosvbe.sys` and `bin\i386\usosvbe.dll`, both marked as PE
4.00 by `tools\nt4\pe_nt4_version.py`. `tools/tests/test_nt4_usosvbe.py` checks
the imports against the NT 4.0 RTM and SP6a export lists (`videoprt.sys` and
`win32k.sys` included).

Licence: GPL-3.0-or-later. Copyright (C) 2026 Maksymilian and the USOS Authors.
Own code, written from the public VBE 3.0 specification and the documented NT
video miniport and display driver interfaces.
