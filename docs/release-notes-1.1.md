# USOS 1.1 release notes (draft)

> Status of this document: a draft collected while 1.1 is integrated into
> `master` (2026-09-29/30). There is no 1.1 tag or release yet; the version
> number, build ID and asset list are filled in when the release is cut.

## Highlights

- **Legacy BIOS mode through CSMWrap.** UEFI menu -> Tools -> "Legacy BIOS
  mode (CSMWrap)" starts the USOS BIOS menu on PCs without a firmware CSM
  (greyed out with an explanation while Secure Boot is on). The BIOS menu
  reads a USB keyboard through INT 16h under SeaBIOS.
- **MS-DOS, FreeDOS and Windows 3.x without CSM.** Installed DOS / Windows
  3.x disks get their own 64 MiB CSMWrap ESP at the end of the disk. USB
  mouse through VBADOS 0.67, USB keyboard in Windows 3.x (standard and 386
  enhanced mode, DOS windows included) through the new USOS driver USOSKEY,
  and Windows 3.x Setup runs in batch mode (`SETUP /H:USOS.SHH`) so it needs
  nothing but a USB keyboard. Tested in QEMU; real hardware (X470) pending.
- **One CSMWrap build: 3.1.2-usos3** (usos1 plus the SeaBIOS boot-priority
  patch 0004: the drive CSMWrap was started from boots first, a USB stick
  included). XP and Vista without CSM use the same build.
- **Windows XP x64 SP2 and Server 2003 R2 SP2 x86 without CSM** install to
  the desktop on the X470 (CSMWrap): USB keyboard and mouse on every rear
  port through xhci98 1.1.1.0-usos2 (MODIFIED, GPL-2.0; corresponding source
  in the sources zip), GenAHCI with `genahci.inf` staged for GUI-mode Setup
  (no more STOP 0x7B loop).
- **XP x64 gets the community x64 ACPI automatically**: `acpi.sys`
  5.2.3790.7777.4 (amd64) in text-mode Setup, in the source's `SP2.CAB`
  and in `TXTSETUP.SIF [FileFlags]`, like the XP x86 community ACPI. Without
  it XP x64 stops with 0xA5 on modern AMD boards. A temporary bridge until
  USOS has its own implementation.
- **Micro-Linux screens keep the menu theme** (the theme travels on the
  kernel command line), and the answer-profile editor formats product keys
  with dashes as you type and scrolls across form sections with the wheel.

## Known limitations

- XP x64: USB flash drives not yet confirmed (recheck with xhci98 usos2);
  Server 2003: USB storage untested. Both: window redraw trails while
  dragging under CSMWrap (generic VGA/VESA driver).
- The XP x64 ACPI's `SP2.CAB` is built per source ISO; an XP x64 source the
  package was not built from keeps the stock ACPI (logged as SKIP).
- BIOS mode through CSMWrap needs a graphics card with a classic video BIOS
  and reserves one CPU thread; keyboard LEDs are not driven.

## Third-party and Microsoft files

As in 1.0, the release carries Microsoft files and community-modified
Microsoft drivers by the maintainer's deliberate decision. New in 1.1: the
**community x64 ACPI 2.0 driver** for XP x64 (MSFN/WinCert community ACPI 2.0
project, 7777.4 build set) and the XP x64 source ISO's `SP2.CAB` holding it.
It is community-built and derived from Microsoft code, redistributed at the
maintainer's own decision and risk (user decision of 2026-09-30), not covered
by any USOS licence, and removed on request of the rights holder. Also new:
xhci98 1.1.1.0-usos2 (GPL-2.0-only) and VBADOS 0.67 (GPL-2.0-or-later) with
their sources. Details: [LICENSES-AUDIT.md](LICENSES-AUDIT.md).
