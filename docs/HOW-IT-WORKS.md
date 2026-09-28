# How USOS works: old systems on new firmware

Polish version: [HOW-IT-WORKS.pl.md](HOW-IT-WORKS.pl.md).

USOS (Universal Service OS) 1.0.0 installs and boots systems from MS-DOS to
Windows 11 and Linux from one USB stick, in Legacy BIOS and in UEFI, with
Secure Boot on as well. The hard part is not the menu. It is making
operating systems from 2001-2009 run on firmware that was never designed for
them. This page explains why Windows XP, Vista and 7 have trouble on modern
UEFI machines, and what USOS does about it.

Every statement here comes from the project's design notes and test
reports, which are linked in each section. When a detail is not documented
there, this page says so. "The X470" means the main hardware test machine:
an ASRock X470 board with a Ryzen 7 5700X, a Radeon RX 560 and AMI Aptio
firmware ([release notes](release-notes-1.0.md#hardware-tested-configurations)).

Contents:

1. [BIOS, UEFI and the CSM](#1-bios-uefi-and-the-csm)
2. [Int 10h, the video BIOS, and why Windows 7 and Vista need legacy VGA](#2-int-10h-the-video-bios-and-why-windows-7-and-vista-need-legacy-vga)
3. [UefiSeven and the USOS Int10 dispatcher (Windows 7 without CSM)](#3-uefiseven-and-the-usos-int10-dispatcher-windows-7-without-csm)
4. [CSMWrap and SeaBIOS: XP and Vista without a firmware CSM](#4-csmwrap-and-seabios-xp-and-vista-without-a-firmware-csm)
5. [XP and memory: PAE](#5-xp-and-memory-pae)
6. [STOP 0xA5 on NT 5.x and the community ACPI driver](#6-stop-0xa5-on-nt-5x-and-the-community-acpi-driver)
7. [USB 3 (xHCI) backports for XP and Vista, and Vista's test mode](#7-usb-3-xhci-backports-for-xp-and-vista-and-vistas-test-mode)
8. [Vista Setup inside a Windows 10 PE](#8-vista-setup-inside-a-windows-10-pe)
9. [Linux ISOs: block device over NTFS extents and the shim relay](#9-linux-isos-block-device-over-ntfs-extents-and-the-shim-relay)
10. [Secure Boot for USOS itself: shim and MOK](#10-secure-boot-for-usos-itself-shim-and-mok)
11. [Further reading](#11-further-reading)

---

## 1. BIOS, UEFI and the CSM

A PC's firmware does two jobs before the operating system runs: it starts
the hardware, and it offers services that a boot loader (and sometimes the
OS itself) can call. The two firmware families offer very different
services.

| | Legacy BIOS | UEFI | UEFI with a CSM |
|---|---|---|---|
| What starts | the first sector (MBR) of the boot disk | an EFI application from a FAT partition, e.g. `\EFI\BOOT\BOOTX64.EFI` | either of the two |
| Services | real-mode interrupts: Int 10h (video), Int 13h (disk), Int 16h (keyboard), an E820 memory map | boot services and runtime services; GOP for graphics | both sets |
| Graphics | the card's video BIOS (VBIOS option ROM), VGA text mode and VGA memory | GOP: a linear framebuffer set up by the card's UEFI driver | GOP, or the VBIOS if the CSM loads it |

The **CSM (Compatibility Support Module)** is the part of UEFI firmware that
plays a BIOS for older systems. The CSMWrap research describes it as EDK2's
`LegacyBiosDxe` plus a 16-bit "CSM16" binary: the CSM loads the graphics
card's legacy VBIOS, fills the real-mode interrupt table, builds the BIOS
tables and boots an MBR disk ([research/csmwrap.md](research/csmwrap.md)
section 2). On AMI boards the CSM also emulates the PS/2 keyboard ports for
USB keyboards through SMM ([research/win98-feasibility.md](research/win98-feasibility.md)).

```
Legacy BIOS:   power on -> BIOS POST (VBIOS runs) -> MBR of disk 0x80 -> OS loader
UEFI:          power on -> UEFI (GOP) -> \EFI\BOOT\BOOTX64.EFI -> OS loader (EFI)
UEFI + CSM:    power on -> UEFI (GOP) -> CSM (VBIOS POSTed, Int 10h/13h set)
                                      -> MBR -> OS loader (BIOS)
```

A machine without any CSM is called "Class 3" in the design notes. The
sources name the ROG Ally, Intel 12th generation and newer, and some AM5
boards as machines without one, and the X470 when its CSM is switched off
([design/csmwrap-integration.md](design/csmwrap-integration.md) section 1).
There is also a middle state: on AMI firmware, "CSM enabled" together with
"Video OpROM: UEFI only" gives a CSM without a VGA BIOS, so for video it
behaves like no CSM ([design/win7-vista-no-csm.md](design/win7-vista-no-csm.md)
section 5).

The repository does not document why board vendors remove the CSM. One
practical consequence it does record: on many boards Secure Boot needs the
CSM turned off, and USOS's Secure Boot page tells the user so
([secure-boot-usos.md](secure-boot-usos.md)).

What each Windows generation needs:

| System | Boot style | Needs from the firmware |
|---|---|---|
| Windows XP, 2000, Server 2003, XP x64 (NT 5.x) | BIOS only | a full BIOS: VGA, Int 13h, E820 |
| Windows Vista SP1+ x64, Windows 7 x64 | UEFI possible | UEFI to boot, **plus** a legacy video BIOS for the basic display driver |
| Windows 8 and later | UEFI | nothing legacy |

---

## 2. Int 10h, the video BIOS, and why Windows 7 and Vista need legacy VGA

Windows Vista SP1+ x64 and Windows 7 x64 can boot from UEFI, and their boot
manager and loader draw with GOP. The kernel's basic display path, however,
still calls the video BIOS. VideoPort `Int10` requests run in the HAL's
x86 real-mode emulator, and the emulator executes whatever the real-mode
interrupt vector 0x10 (physical address 0x40) points at. Normally that is
the card's VGA option ROM, shadowed at `0xC0000`. With a CSM, the firmware
loads that ROM and sets the vector. On a Class 3 machine the vector is 0 or
garbage, and Windows stops at the "Starting Windows" screen or fails with
0xc000000d. Windows 8 and later do not need this
([design/win7-vista-no-csm.md](design/win7-vista-no-csm.md) section 1).

```
Windows 7 kernel, basic display driver (vga / vgapnp.sys, VgaSave)
   |
   |  Int 10h  ->  HAL x86 emulator  ->  IVT[0x10]  ->  C000:xxxx  (VBIOS)
   |                                                    with CSM: the card's VBIOS
   |                                                    without:  nothing -> hang
   |
   +- direct access to the VGA I/O ports and the VGA memory window at A0000
```

Replacing Int 10h alone is not always enough. Windows 7 also touches the
VGA I/O ports and the `0xA0000` window directly (PrimeExpert's FlashBoot
article, cited in [windows7-uefi-reference-analysis.md](windows7-uefi-reference-analysis.md)).
Those accesses only reach the graphics card if the PCI bridge above it has
"VGA Enable" set and the card decodes legacy I/O. With the CSM off, the
X470's firmware left both closed.

**The X470 Windows 7 black screen.** With the CSM off, UefiSeven, the AMD
unlock and the Int 10h check all passed, and Windows finished the specialize
phase, but the `vga`/`vgapnp.sys` driver failed with Code 10 within 47 ms.
With the CSM on, the same device started as "AMD ATOMBIOS"
([design/win7-vista-no-csm.md](design/win7-vista-no-csm.md) section 6). The
cause turned out to be routing: the VGA register probe read `FF` on every
port before USOS opened the path, and passed afterwards (section 10 there).

**The Vista black screen on the X470.** Vista behaves differently. Even with
the CSM on, Vista's `vgapnp` fails with Code 10 on the RX 560, and Windows
falls back to **VgaSave**. VgaSave needs the legacy VGA memory at `A0000`.
With the CSM off, that memory reads `FF`, because the card's legacy VBIOS
never ran its POST. Windows 7's `vgapnp` starts from UefiSeven's VBE data,
so it survives `A0000=FF`. Vista's does not
([design/win7-vista-no-csm.md](design/win7-vista-no-csm.md) section 10). GOP
alone cannot help here: GOP gives a linear framebuffer, not the planar VGA
memory window that VgaSave writes to.

**Why `0xC0000` must be writable.** A replacement Int 10h handler has to live
in the `0xC0000` area. On AMD Zen, `C0000-CFFFF` is routed to MMIO unless the
fixed-MTRR RdMem/WrMem bits say DRAM, so writes go nowhere. On the X470 the
first 16 bytes at `C0000` read `FF` and there was no Legacy Region protocol
([windows7-amd-shadow-2026-09-20.md](windows7-amd-shadow-2026-09-20.md)).
USOS's `amd_shadow` step sets those bits, but only on CPUID `00a20f12`
(Vermeer: 5700X/5800X3D). Other AMD CPUs, such as the ROG Ally's Phoenix,
and Intel boards without a Legacy Region protocol are not handled
([design/win7-vista-no-csm.md](design/win7-vista-no-csm.md) section 6).

---

## 3. UefiSeven and the USOS Int10 dispatcher (Windows 7 without CSM)

**UefiSeven** 1.30 (BSD-2-Clause, successor of VgaShim) is a UEFI application
that fakes the missing video BIOS. It claims the interrupt table page,
switches GOP to 1024x768, makes `0xC0000` writable (Legacy Region protocols,
then fixed MTRRs), copies a small real-mode handler and two VBE tables there
(the GOP framebuffer is the VBE linear framebuffer), points vector 0x10 at
`C000:0200`, checks the handler, and then starts the original Windows boot
manager. If the vector already points at a plausible firmware handler, it
leaves it alone ([design/win7-vista-no-csm.md](design/win7-vista-no-csm.md)
section 2).

USOS puts its own **dispatcher** in front of UefiSeven on the installed
system's ESP. At the end of Setup (which runs in a GOP-native Windows PE 6.2 or
newer, either the hybrid ISO's own PE or the PE10 donor, so Setup itself
never needs the shim), the finalizer writes:

| File on the target ESP (both `\EFI\Microsoft\Boot\` and `\EFI\Boot\`) | Content |
|---|---|
| `bootmgfw.efi` / `bootx64.efi` | the USOS dispatcher (`win7-wrapper.efi`) |
| `win7.efi` | UefiSeven |
| `win7.original.efi` | the Microsoft boot manager Setup wrote (version checked) |
| `UefiSeven.ini`, `uefiseven-LICENSE.txt` | configuration (`logfile=1`) and licence |

The dispatcher decides on **every boot**, not at install time, because the
disk outlives the firmware settings (users toggle the CSM, move disks,
update firmware). The test is the interrupt table, not "is there a CSM":

```
dispatcher boot
  |- IVT[0x10] points into C0000-EFFFF, first opcode not 00/FF?
  |     yes -> a CSM supplied a VBIOS -> start win7.original.efi directly
  |     no:
  |- GOP present? (up to 3 ConnectController passes, then up to 2 cold resets)
  |- AMD Vermeer: open C0000-CFFFF as DRAM (fixed MTRR RdMem/WrMem)
  |- route legacy VGA to the GOP card:
  |     probe VGA registers -> find the GOP's PCI device and its bridges
  |     -> PciIo.Attributes(Enable, VGA memory + VGA I/O) -> raw fallback
  |     -> probe again: passed_before | passed_after | failed (5 s note)
  '- start win7.efi (UefiSeven) -> win7.original.efi (Windows boot manager)
```

The **VGA routing** step is what fixed the X470. It finds the PCI device
behind the GOP, asks the firmware's PCI driver to enable legacy VGA memory
and I/O on it (an EDK2-style PCI bus driver then sets VGA Enable on the
bridges above), and falls back to setting the bridge and command bits itself
under safety rules: no I/O decode on a bridge whose I/O window is open below
0x1000, no VGA Enable when another bridge already owns VGA
([design/win7-vista-no-csm.md](design/win7-vista-no-csm.md) section 8.3).

Hardware result, 2026-09-26, build B260926-134756: **Windows 7 x64 installed
and reached the desktop on the X470 with the CSM off and Secure Boot off.**
The log showed `VGA probe before: FAIL` (every port `FF`),
`GPU Attributes(Enable, 318) = success`, then `VGA probe after: PASS`. The
root port's bridge control went from `0010` to `0018` (VGA Enable on), and
the GPU's command register from `0006` to `0007` (I/O decode on). The
display device's registry key recorded `ChipType = "UefiSeven"`: `vgapnp.sys`
started on UefiSeven's VBE data. `A0000` still read `FF` after routing,
which Windows 7 tolerates (section 10 there).

Each boot is logged in a ring log on the ESP (`usos-boot-uefiseven.log` or
`usos-boot-csm.log`, 8 boots each), so a CSM boot never erases the evidence
of a no-CSM boot.

Known limits ([design/win7-vista-no-csm.md](design/win7-vista-no-csm.md)
section 6):

- Secure Boot must be off. UefiSeven and the dispatcher are not signed, and
  the path rewrites the interrupt table and legacy memory.
- The resolution is 1024x768 until a vendor display driver is installed.
- A writable `0xC0000` is the weak point: CPUs and boards outside the
  handled cases log a failed sanity check.
- A Windows update or `bcdboot` that rewrites `bootmgfw.efi` removes the
  dispatcher from the main entry. The fix is to re-publish it or to enable
  the CSM.

The same dispatcher is installed for Vista on UEFI, where it passes through
when a CSM is present. Without a CSM it does not help Vista (the VgaSave
problem in section 2), so Vista without a CSM goes the CSMWrap way instead.

---

## 4. CSMWrap and SeaBIOS: XP and Vista without a firmware CSM

XP and the other NT 5.x systems cannot boot from UEFI at all. They need a
real BIOS for their whole life. When the board has no CSM, USOS brings one:
**CSMWrap**, an EFI application that does what a firmware CSM does, from
outside the firmware, with a **SeaBIOS** fork as the BIOS. CSMWrap is
LGPL-2.1 and its SeaBIOS fork is LGPLv3 ([research/csmwrap.md](research/csmwrap.md)).

What CSMWrap 3.1.2 does, in order ([research/csmwrap.md](research/csmwrap.md)
section 2):

1. Reads `csmwrap.ini` next to itself.
2. Unlocks the legacy region `0xC0000-0xFFFFF` (the Legacy Region 2
   protocol, Intel PAM registers, or on AMD the fixed MTRRs, the same
   mechanism as USOS's AMD shadow unlock), then tests it.
3. Builds the tables a BIOS OS expects: patches the ACPI MADT to hide one
   CPU, synthesizes SMBIOS 2.x, an MP table, a `$PIR` table, and an E820 map
   from the UEFI memory map.
4. Finds the GOP card and takes the **legacy PC-AT image** out of the card's
   option ROM copy (`EFI_PCI_IO_PROTOCOL.RomImage`). Without one, it falls
   back to SeaVGABIOS drawn on the GOP framebuffer.
5. Relocates PCI BARs below 4 GiB where it can.
6. Calls `ExitBootServices`: from here on UEFI is gone for this power
   cycle. There is no way back.
7. Copies SeaBIOS and the VBIOS into place, starts the **BIOS proxy** on the
   reserved CPU, and runs the card's real VBIOS POST.
8. Puts the drive it was loaded from first in the boot order, reads its
   sector 0 and jumps to it with `DL=0x80`.

**Why one CPU thread is reserved.** BIOS calls made from V86 mode need
somewhere to run. A firmware CSM uses SMM for that; outside the firmware
there is no SMM, so CSMWrap keeps one CPU in protected mode as a "BIOS
proxy" that executes SeaBIOS's 32-bit code for those calls. That CPU is
hidden from the OS in the MADT and the MP table. The release notes put it
this way: CSMWrap reserves one CPU thread for its BIOS proxy, so the
installed system sees one logical CPU fewer. CSMWrap therefore needs at
least two logical CPUs ([research/csmwrap.md](research/csmwrap.md) sections
2-3, [release-notes-1.0.md](release-notes-1.0.md#csmwrap-paths-xp-vista-2000-2003-xp-x64-without-a-firmware-csm)).

**Why a legacy VBIOS is needed.** With the card's own VBIOS, XP's text-mode
Setup, the boot screen, `vga.sys`/VgaSave and VBE all behave as under a
firmware CSM. With only SeaVGABIOS, there is VBE on the GOP framebuffer and
nothing else: direct writes to the text buffer at `B8000` and to `A0000` are
invisible. In QEMU with a GOP-only card, the screen was black from SeaBIOS
on and XP text-mode Setup did not proceed. The RX 560 has both images in its
ROM. The ROG Ally's iGPU almost certainly has no PC-AT image
([design/csmwrap-integration.md](design/csmwrap-integration.md) sections 3
and 7, [research/csmwrap.md](research/csmwrap.md) section 3).

**Where CSMWrap lives: an ESP at the end of the target disk.** The installed
XP must boot without the stick, and every boot needs CSMWrap. So the XP
preparation (which already runs from UEFI, in the micro-Linux) leaves the
last 65 MiB of the disk free and creates a 64 MiB FAT16 partition there
(MBR type `0xEF`) with CSMWrap as `\EFI\BOOT\BOOTX64.EFI`, its `csmwrap.ini`,
and its licences and source code. No firmware boot entry is written: the
firmware's removable-path entry for that disk starts it. Because CSMWrap
boots the drive it came from first, it lands on the target's MBR with no
configuration ([design/csmwrap-integration.md](design/csmwrap-integration.md)
sections 2 and 8).

```
target disk (MBR, <= 2 TiB, wiped)
  entry 1  NTFS, active, LBA 2048   Windows XP
  entry 2  FAT16, type 0xEF, 64 MiB at the end   \EFI\BOOT\BOOTX64.EFI = CSMWrap
                                                 \EFI\BOOT\csmwrap.ini, \CSMWRAP\ (licences, source)

every boot: firmware -> disk's UEFI entry -> CSMWrap -> SeaBIOS (card VBIOS POSTed)
            -> MBR (DL=80h) -> NTFS boot code -> NTLDR/SETUPLDR -> XP
```

The ESP is **last** rather than first on purpose: the Windows partition
stays MBR entry 1 at LBA 2048, so the ARC paths in `WINNT.SIF`, `boot.ini`
and the PAE helper stay exactly as in the proven layout with a CSM
([design/csmwrap-integration.md](design/csmwrap-integration.md) section 8).
USOS takes this path only when its UEFI menu finds no firmware CSM. With a
CSM, nothing changes.

**Vista through CSMWrap.** Vista's UEFI boot manager needs UEFI boot and
runtime services, so it cannot run after CSMWrap, which has already exited
boot services. Vista without a CSM is therefore installed as a **legacy MBR
system** and booted through the same kind of target ESP (section 8 below).

**The quiet build 3.1.2-usos1.** Even with `verbose = false`, upstream 3.1.2
always printed its logo, the SeaBIOS banner and a "Press ESC for boot menu"
prompt with a 2.5 s wait. USOS ships a patched source build, **CSMWrap
3.1.2-usos1**, with three small patches: the logo only with `verbose = true`;
a new "quiet" flag passed from CSMWrap to SeaBIOS that suppresses the banner
and the "Booting from ..." lines (error messages stay); and no boot menu on
a quiet boot. `verbose = true` restores every upstream screen, and an empty
`EFI\USOS\csmwrap-verbose.flag` on the stick sets it. The build runs in a
throwaway Alpine VM with pinned package versions and is reproducible when
built twice. The source archive and the patches go onto every CSMWrap ESP,
as the LGPL requires ([research/csmwrap.md](research/csmwrap.md) sections
6-7).

**What is left.** A blinking text cursor (an underline in the top-left
corner) stays on screen from SeaBIOS's switch to text mode until the Windows
loader changes the video mode. Hiding it needs another SeaBIOS patch
([research/csmwrap.md](research/csmwrap.md) section 7).

Other limits: CSMWrap is never signed, so Secure Boot must be off (signing
it would let anyone run unverified BIOS code under the USOS trust chain);
SeaBIOS handles a USB keyboard only through Int 16h, with no 8042 emulation,
so input in XP needs XP's own USB driver; and the target must be MBR and is
wiped ([research/csmwrap.md](research/csmwrap.md) sections 4-5).

Hardware results on the X470 with the CSM off and Secure Boot off:
**XP SP3 (Polish) installed unattended through CSMWrap** (2026-09-27, build
B260927-153019), and **Vista SP2 x64 installed and booted from its own disk
through CSMWrap** (2026-09-28, build B260927-205829). The quiet usos1 build
itself has passed in QEMU but is not yet confirmed on the X470
([design/csmwrap-integration.md](design/csmwrap-integration.md) sections 9
and 10.5, [release-notes-1.0.md](release-notes-1.0.md#not-tested-yet)).

---

## 5. XP and memory: PAE

32-bit Windows XP normally uses at most 4 GB of RAM. The NT5 design lists
XP x86 as a client system whose 4 GB limit USOS lifts with a patch ("4 GB
to full memory"), and describes the same 4 GB cap on Windows 2000
Professional/Server and Server 2003 Standard as a licensing limit in the
kernel ([design/nt5-uefi-family.md](design/nt5-uefi-family.md) section 5).
PAE (Physical Address Extension) is the CPU mode a 32-bit kernel uses to
address memory above 4 GB.

USOS's helper `pae.exe` works like this
([windows-xp-uefi-csm-pae-2026-09-21.md](windows-xp-uefi-csm-pae-2026-09-21.md)):

1. It accepts only Windows XP 5.1.2600. It checks the kernel and HAL file
   versions and looks for unique patch patterns in their executable
   sections. Unknown versions or patterns are refused.
2. It writes **patched copies** under new names, `usospae.exe` and
   `usoshal.dll`, and fixes their PE checksums. The original kernel and HAL
   are never overwritten.
3. It backs up `boot.ini` to `C:\USOS\XP\boot-original.ini` and adds a PAE
   entry that uses the patched files. That entry is first, so it is the
   default, and `timeout=0` hides the menu. The original entry stays: F8 at
   boot, then "Return to OS Choices Menu".
4. It runs at the end of GUI Setup (`[SetupParams] UserExecute`), so the
   restart that ends Setup already boots with PAE. A first-logon run is the
   fallback if that did not happen.

The patch patterns are adapted from **PatchPAE3** (evgen-b, CC-BY-4.0,
pinned commit). The upstream auto-elevating script is not run or shipped.

Result: a clean XP SP3 install on the X470 shows **31.9 GB of RAM** with the
PAE entry ([release-notes-1.0.md](release-notes-1.0.md#hardware-tested-configurations)).
For XP through CSMWrap, where CSMWrap builds the E820 memory map, the user
has not reported the RAM figure yet.

A related hardening step: the driver bundles set `CrashDumpEnabled=0`. On
one test install, a bugcheck in the crash-dump path followed by a forced
power-off left zero-filled files in WinSxS. The preparer now also checks
the target read-only after writing and refuses it if any non-empty file
reads back as all zeros
([windows-xp-uefi-csm-pae-2026-09-21.md](windows-xp-uefi-csm-pae-2026-09-21.md)).

Other NT 5.x systems ([design/nt5-uefi-family.md](design/nt5-uefi-family.md),
[nt52-2003-xp64-2026-09-27.md](nt52-2003-xp64-2026-09-27.md)):

| System | PAE |
|---|---|
| XP x86 SP3 | patch (`pae.exe`) |
| Windows 2000 Pro / Server | none (4 GB limit, the 5.0 kernel is not patched) |
| Server 2003 x86 Enterprise | native: USOS adds `/PAE` at the end of Setup |
| XP x64, Server 2003 x64 | not needed (64-bit) |

XP in Legacy BIOS mode gets neither the driver package nor PAE; only the
UEFI variants have them ([release-notes-1.0.md](release-notes-1.0.md#nt-5x-on-modern-boards)).

---

## 6. STOP 0xA5 on NT 5.x and the community ACPI driver

ACPI tables describe the board to the OS. Modern firmware builds them with
modern tools, and the ACPI drivers that shipped with NT 5.x cannot always
parse them.

On the X470 (CSM on, build B260927-201324), Server 2003 x86 and XP x64 both
stopped at the start of text-mode Setup with **STOP 0xA5 (0x11, 0x8,
&lt;table&gt;, 0x20120913)**: ACPI_BIOS_ERROR, "cannot enter ACPI mode", on
firmware tables built with iASL 20120913. The stock NT 5.2 `ACPI.SYS`, from
the ACPI 1.0b era, cannot parse them. QEMU's tables are simple, so QEMU never
showed the problem ([nt52-usb3-2026-09-27.md](nt52-usb3-2026-09-27.md)
section 5).

XP x86 works on this board because its package **replaces `ACPI.SYS` with
the community ACPI 2.0 driver**. The replacement goes into both places Setup
can take it from, the compressed `ACPI.SY_` and the `SP3.CAB` cache, so a
later Setup step cannot pick up the old copy
([windows-xp-driver-integration-2026-09-21.md](windows-xp-driver-integration-2026-09-21.md)).

| System | ACPI situation in 1.0 |
|---|---|
| XP x86 SP3 | community ACPI 2.0 (x86) in the package: works on the X470 |
| Server 2003 x86 | the same x86 community ACPI works as a bundle (0 missing imports, QEMU to GUI Setup), but the 1.0 release packages do not include it |
| XP x64 | x64 builds exist, but they are compiled from leaked Microsoft source, so USOS never bundles them; the user would have to supply one, and USOS has no step yet to stage an ACPI replacement |
| Windows 2000 | stock ACPI 5.0 is older still; the XP community driver is built for the 5.1 kernel and is not a drop-in replacement |

The fallback "F7" (a non-ACPI HAL) is not a way out on these boards. XP x64
and Server 2003 x64 have no non-ACPI HAL at all. Server 2003 x86 with F7
would run on one CPU with the old PIC and would need BIOS interrupt routing
for every PCIe device, which on AM4 is at best partial
([nt52-usb3-2026-09-27.md](nt52-usb3-2026-09-27.md) section 5,
[release-notes-1.0.md](release-notes-1.0.md#nt-5x-on-modern-boards)).

---

## 7. USB 3 (xHCI) backports for XP and Vista, and Vista's test mode

The X470 has only xHCI (USB 3) controllers, with no EHCI. XP, Server 2003,
XP x64 and Vista have no xHCI driver of their own. Before the kernel starts,
the firmware (or SeaBIOS) handles the keyboard. Once Windows owns the
hardware, it needs its own driver, or USB input is gone
([research/csmwrap.md](research/csmwrap.md) section 4).

**XP x86.** The XP package carries a USB 3 backport, KMDF 1.11 and a kernel
extender (`ntoskrn8`), plus GenAHCI and a StorPort backport for the disk.
Text-mode Setup needs no keys: it is fully unattended after the disk choice
in USOS (measured in QEMU: key presses during the disk check and copying
changed nothing). So a missing keyboard matters only from the GUI phase on,
where the backport is already loaded
([windows-xp-uefi-csm-pae-2026-09-21.md](windows-xp-uefi-csm-pae-2026-09-21.md),
[design/nt5-uefi-family.md](design/nt5-uefi-family.md) section 3.4).

**Server 2003 x86 and XP x64.** No USB input on xHCI-only boards in 1.0.
The XP backport imports resolve on Server 2003, but text-mode Setup stopped
with STOP 0xDEADBEEF in QEMU, so that work is parked. For XP x64 the
realistic option is a Renesas uPD720201/720202 PCIe card with its official
driver ([nt52-usb3-2026-09-27.md](nt52-usb3-2026-09-27.md)).

**Vista x64.** The Vista path uses the community method: first KMDF 1.11
(Microsoft's KB2864202), then a backport of the Windows 8 USB 3 stack
([windows-vista-community-usb-2026-09-20.md](windows-vista-community-usb-2026-09-20.md)).
Getting Vista to accept that driver took several rounds:

- The community package is signed by a third party (Riolin). On Vista,
  `SetupCopyOEMInf` still refused it (`0xe0000242`) after the publisher
  certificate was placed in the machine's TrustedPublisher store. The exact
  reason was not established; expiry is not claimed as the cause.
- AMD's own USB 3 catalogs were rejected with `0xe0000244`,
  AUTHENTICODE_WRONG_OS ([windows-vista-intel-2026-09-20.md](windows-vista-intel-2026-09-20.md)).
  The AMD catalog for the X470 is marked for Windows 7 only (OSAttr 6.1)
  and uses a SHA-256 chain ([ROADMAP.md](ROADMAP.md) section 3).
- USOS therefore **re-signs a copy of the catalog** with a local test
  certificate. The INF and SYS files and the catalog content stay
  byte-identical; only the catalog signature is replaced. The test chain is
  a separate root and an end-entity publisher (the first attempt used a CA
  certificate as the signer and was rejected), and the notes say SHA-1 was
  chosen on purpose for this Vista SP2 package. The public certificate is
  added to the target's Root and TrustedPublisher stores.

x64 Vista loads kernel drivers signed like this **only with test signing
on**. With it off, `usbxhci` does not load, and on the X470 there would be no
keyboard or mouse. So the installed Vista runs in **test mode** ("Test
Mode" on the desktop). There is no legitimately signed xHCI driver for the
X470 on Vista x64. The only way to leave test mode is a **Renesas uPD72020x
PCIe USB 3 card**, whose vendor driver supports Vista
([windows-vista-existing-esp-2026-09-26.md](windows-vista-existing-esp-2026-09-26.md),
[design/csmwrap-integration.md](design/csmwrap-integration.md) section 10.5).

**Known limitation: no USB flash drives in the installed Vista.** With the
backport stack, keyboard and mouse work, but USB flash drives and other USB
mass-storage devices do not appear in Explorer or Disk Management. The cause
is still being investigated. Workarounds: the network, a second internal
SATA disk, an optical drive, or the Renesas card with its own driver
([release-notes-1.0.md](release-notes-1.0.md#windows-vista-usb-flash-drives-are-not-visible-in-the-installed-system)).

---

## 8. Vista Setup inside a Windows 10 PE

Vista's own installer environment (its WinPE) cannot be used on the X470:

- it has **no xHCI driver**, so there is no keyboard or mouse in Setup;
- on UEFI, its boot manager needs a video BIOS (section 2), while the boot
  manager, loader and kernel of Windows PE 10 are GOP-native
  ([design/win7-vista-no-csm.md](design/win7-vista-no-csm.md) section 4,
  [design/csmwrap-integration.md](design/csmwrap-integration.md) section 10.1).

So USOS boots a **PE10 donor** (`PE10_x64_19041_USOS.iso`: Windows PE 10
x64 with Setup, no install image; a separate release asset whose SHA-256 is
recorded in `EFI\USOS\winpe-donor.ini`) and runs **Vista's own `setup.exe`
from the Vista ISO** inside it. PE10 brings its own USB 3, AHCI and NVMe
drivers. Vista's `boot.wim` is used only as a file source. Only SP2 install
media are accepted ([design/win7-vista-no-csm.md](design/win7-vista-no-csm.md)
section 7). The same donor is used for original Windows 7 ISOs on UEFI
([windows7-pe10-handoff-2026-09-20.md](windows7-pe10-handoff-2026-09-20.md)).

Around Setup, the USOS helpers do three things
([windows-vista-usb-install-2026-09-21.md](windows-vista-usb-install-2026-09-21.md)):

1. **KMDF through Setup's own servicing.** Setup gets an answer file with a
   `<servicing>` block for KB2864202, so KMDF 1.11 is installed into the new
   system by Setup itself. Afterwards the helper requires `Wdf01000.sys` and
   `WdfLdr.sys` on the target to report 1.11 before it arms anything; if
   not, it stops in PE, where input still works.
2. **The USB first-boot gate.** A USOS helper runs on the first start of
   the installed Vista before the rest of Setup, installs the USB 3
   backport, and holds Setup until the controller, keyboard and mouse
   report started.
3. **Boot configuration.** The finalizer turns test signing on in the new
   system's BCD.

Two ways to boot it, depending on the firmware:

```
UEFI with CSM:
  USOS menu -> wimboot -> PE10 (RAM) -> Vista setup.exe from the ISO -> GPT install
  installed Vista: target ESP dispatcher (passes through, CSM gives the VBIOS)

UEFI without CSM:
  USOS menu -> micro-Linux prepares the target (MBR):
      slot 1  NTFS "USOS-VISTA", 1 GiB, active: NT60 boot code, bootmgr,
              the PE10 Setup image with the USOS helpers
      slot 2  CSMWrap ESP, 64 MiB
  restart -> CSMWrap -> SeaBIOS (card VBIOS) -> MBR -> bootmgr -> PE10 in BIOS mode
          -> Vista setup.exe from the ISO on the stick -> legacy MBR install
  every later boot: firmware -> disk's UEFI entry -> CSMWrap -> Vista
```

In the no-CSM variant Setup itself makes a real legacy install, so nothing
has to be converted afterwards. The staging partition is hidden and made
inactive before Setup and removed afterwards
([design/csmwrap-integration.md](design/csmwrap-integration.md) section 10).
One restart is needed between the disk preparation and Setup.

---

## 9. Linux ISOs: block device over NTFS extents and the shim relay

Booting a Linux ISO's kernel is the easy half. The hard half is what comes
next: the distro's initramfs has to find its live root or installer packages
**on the medium**. On a DVD that medium is a block device with ISO9660. On
the USOS stick it is a file inside the NTFS `USOS_DATA` partition, and most
live initrds cannot mount NTFS. USOS cannot add the `ntfs3` module from
outside either: it must match the exact kernel build and, under Secure Boot,
carry the distro's module signature ([design/linux-iso-boot.md](design/linux-iso-boot.md)
section 1).

USOS's answer is to **turn the ISO file into a block device before the
distro's init runs**:

```
USOS menu (UEFI) / BIOS Core
  1. open the ISO on DATA with USOS's own NTFS reader
  2. read the ISO's grub.cfg -> family, kernel, initrd, command line
  3. map the file's NTFS runs to absolute disk sectors (max. 64 extents)
  4. initrd = distro initrd + usos-linux.cpio + generated cpio (/usos/iso.map)
  5. start the kernel with rdinit=/usos/init
Linux
  6. /usos/init (static, no libc): find the USB disk by a CRC of the ISO's
     volume descriptor, then
        1 extent  -> loop device with offset (read-only)
        n extents -> device-mapper "usos-iso", n linear targets (read-only)
     link /dev/usos-iso, then exec the distro's /init
  7. the distro finds an ordinary ISO9660 device and boots as from a DVD
```

The distro needs no NTFS support: it only needs raw access to the USB disk
and `loop` (every live initrd has it) or `dm-mod`. Only the initrd is held in
RAM, not the ISO. One or two command-line words tell each family where the
medium is (for example `live-media=/dev/usos-iso` for casper and
live-boot). Debian's netinst initrd has neither `loop` nor `dm-mod`, so for
it `/usos/init` adds an in-kernel partition over the contiguous ISO
(`BLKPG_ADD_PARTITION`, in the kernel's table only; nothing is written to the
disk). A file with more than 64 extents is refused with a "copy the ISO
again" message ([design/linux-iso-boot.md](design/linux-iso-boot.md)
sections 3 and 11).

**Secure Boot: relaying the distro's own shim.** The distro kernel is
signed by the distro (Canonical, Debian, Fedora), not by USOS. USOS's shim
is Fedora's, so only Fedora kernels verify under it. For the others USOS
starts the ISO's own **Microsoft-signed shim** from `\EFI\BOOT\BOOTX64.EFI`.
That shim installs its verifier (with the distro's CA) and starts its
"second stage", `grubx64.efi` from the same directory, which on the USOS ESP
is **USOS itself** (MOK-signed, accepted by any shim through MokList).
This second USOS instance picks up a one-shot relay plan, asks each
installed shim verifier (`SHIM_LOCK->Verify`) until one accepts the distro
kernel, loads it and starts it. Nothing is patched, and every executed image
is verified by a shim. Kernel lockdown is then enforced by the distro kernel
itself ([design/linux-iso-boot.md](design/linux-iso-boot.md) section 5).

```
firmware -> USOS shim -> USOS (menu) -> distro shim (MS-signed)
         -> "grubx64.efi" = USOS (relay) -> SHIM_LOCK->Verify(distro kernel) -> kernel
```

Tested in QEMU with ten ISOs, and on the X470 with Mint, Fedora, Debian
netinst, SystemRescue, Clonezilla and GParted (Secure Boot off) and Fedora
and Mint (Secure Boot on). SystemRescue has no signed boot loader, so it
needs Secure Boot off ([design/linux-iso-boot.md](design/linux-iso-boot.md)
sections 11-12, [release-notes-1.0.md](release-notes-1.0.md#supported-systems)).

---

## 10. Secure Boot for USOS itself: shim and MOK

With Secure Boot on, firmware starts only images signed by a key in its `db`,
which in practice means Microsoft's UEFI CA. USOS uses the same model as
most Linux distributions: a Microsoft-signed **shim** that trusts a second
key list, the **MOK** (Machine Owner Key) list
([secure-boot-usos.md](secure-boot-usos.md)).

| ESP path | Content | Trusted by |
|---|---|---|
| `\EFI\BOOT\BOOTX64.EFI` | shim 16.1 (Fedora build) | firmware `db`: Microsoft UEFI CA 2011 **and** 2023 |
| `\EFI\BOOT\mmx64.efi` | MokManager | the Fedora CA built into that shim |
| `\EFI\BOOT\grubx64.efi` | USOS (the UEFI menu) with an `.sbat` section | the USOS key, enrolled in MokList |
| `\USOS-KEY.cer` | the USOS public certificate | - |

The USOS key also signs the micro-Linux kernel, systemd-boot, the NTFS
driver, the UEFI Shell and the touch driver. wimboot keeps its own Microsoft
signature. USOS uses shim's verifier for everything it starts from its ESP.
Unlike Ventoy, USOS does not patch shim to skip verification. The private
key never enters the repository.

**Enrolling the key, once per computer.** Three ways, easiest first:

1. **USOS saves the key itself** while Secure Boot is off or the board is in
   Setup Mode. The USOS home screen offers it, asks for confirmation, writes
   the certificate into `MokList` and reads it back.
2. **MokManager** with Secure Boot on: shim shows "Verification failed",
   then "Enroll key from disk" -> `USOS_ESP` -> `USOS-KEY.cer`. No password.
3. A MokNew request with a password, from the installer's command line
   (advanced).

**Why the direct save is legitimate.** `MokList` is a plain non-volatile
variable under shim's GUID, not an authenticated one. shim trusts it only
if it has boot-services access and **no** runtime access, and such a variable
can only be created before the OS starts, i.e. by the firmware setup, a
pre-OS program or MokManager. MokManager itself enrolls with the same
`SetVariable` call. USOS does it only when it was started by shim and
Secure Boot is **not** enforcing; never while `SecureBoot = 1`. With Secure
Boot off, anyone at the keyboard can run any code anyway, so this adds no
new trust path. After writing, USOS re-reads the variable and checks the
attributes and the certificate ([secure-boot-usos.md](secure-boot-usos.md),
section "Saving the key without MokManager").

The X470 showed why Setup Mode matters: it had no platform key, and the
early gate refused to offer the save in that state. After the fix, the key
was saved straight into MokList from Setup Mode, and shim then booted USOS
with no MokManager step (confirmed 2026-09-24, build B260924-202302).

**What is not locked down yet** ([secure-boot-usos.md](secure-boot-usos.md),
[release-notes-1.0.md](release-notes-1.0.md#secure-boot)):

- The chain of trust ends at the micro-Linux kernel. The initramfs and the
  kernel command line are not verified, and the kernel runs without
  lockdown. Someone with physical access can therefore use the USOS-signed
  kernel to run arbitrary code on a machine that trusts the USOS key.
  Closing this needs a force-locked-down kernel in a signed unified kernel
  image (planned, ROADMAP N6).
- Paths that must run unverified legacy code are unsigned on purpose and
  need Secure Boot off: UefiSeven and the Int10 dispatcher (Windows 7,
  Vista), CSMWrap, and the XP package.
- The UEFI Shell starts under Secure Boot but cannot launch `.efi` tools.
- An NVRAM reset removes the enrolled key.
- Like every current distro shim, shim writes the `SbatLevel` variable on
  its first Secure Boot start, which revokes very old GRUB builds on that
  computer.

---

## 11. Further reading

Design notes:

- [design/win7-vista-no-csm.md](design/win7-vista-no-csm.md): the Int10h
  shim, the dispatcher, VGA routing, and the X470 results for Windows 7 and
  Vista
- [design/csmwrap-integration.md](design/csmwrap-integration.md): CSMWrap
  for XP and Vista, the target ESP, Vista in BIOS mode
- [design/linux-iso-boot.md](design/linux-iso-boot.md): Linux ISOs from
  NTFS and the Secure Boot relay
- [design/nt5-uefi-family.md](design/nt5-uefi-family.md): Windows 2000,
  Server 2003 and XP x64 on UEFI (Polish)
- [design/refactor-os-pipeline.md](design/refactor-os-pipeline.md) and
  [design/answer-file-generator.md](design/answer-file-generator.md): the
  per-OS pipeline and the answer profiles (Polish)

Research and reports:

- [research/csmwrap.md](research/csmwrap.md): how CSMWrap works, its
  licence and the quiet build
- [research/win98-feasibility.md](research/win98-feasibility.md): Windows 9x
  on modern hardware (Polish)
- [secure-boot-usos.md](secure-boot-usos.md): the shim and MOK chain, key
  custody, enrollment
- [windows-xp-uefi-csm-pae-2026-09-21.md](windows-xp-uefi-csm-pae-2026-09-21.md)
  and [windows-xp-driver-integration-2026-09-21.md](windows-xp-driver-integration-2026-09-21.md):
  the XP package, drivers and PAE
- [nt52-2003-xp64-2026-09-27.md](nt52-2003-xp64-2026-09-27.md) and
  [nt52-usb3-2026-09-27.md](nt52-usb3-2026-09-27.md): NT 5.2, STOP 0xA5, USB
- [windows-vista-community-usb-2026-09-20.md](windows-vista-community-usb-2026-09-20.md),
  [windows-vista-usb-install-2026-09-21.md](windows-vista-usb-install-2026-09-21.md)
  and [windows-vista-existing-esp-2026-09-26.md](windows-vista-existing-esp-2026-09-26.md):
  Vista's USB 3 path and test mode
- [windows7-uefi.md](windows7-uefi.md),
  [windows7-x470-starting-windows.md](windows7-x470-starting-windows.md) and
  [windows7-int10-return-2026-09-20.md](windows7-int10-return-2026-09-20.md):
  the history of the Windows 7 "Starting Windows" hang (Polish)
- [release-notes-1.0.md](release-notes-1.0.md) and [ROADMAP.md](ROADMAP.md):
  what is tested, known issues and what comes next
- [../ARCHITECTURE.md](../ARCHITECTURE.md), [../BOOT_FLOW.md](../BOOT_FLOW.md)
  and [../MEDIA_LAYOUT.md](../MEDIA_LAYOUT.md): the overall structure
  (Polish)
