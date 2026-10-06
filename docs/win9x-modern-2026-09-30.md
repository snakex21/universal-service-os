# Windows 95 / 98 / 98 SE / Me on modern PCs (BIOS and CSMWrap), 2026-09-30

Status: **branch `feature/win9x-modern`, QEMU-tested, not on hardware.**
Roadmap: L6 (98/Me) and L6b (95). Builds on the BIOS DOS Setup path of
[win98-native](win98-native-2026-09-12.md) / [win98-ram](win98-ram-2026-09-12.md),
the BIOS mode of [design/bios-via-csmwrap.md](design/bios-via-csmwrap.md) and
the research in [research/win98-feasibility.md](research/win98-feasibility.md)
and [research/xhci98.md](research/xhci98.md).

## 1. What the user does

BIOS PC: USOS BIOS menu -> Windows -> Windows 98 SE / 98 / Me / 95 -> ISO ->
Automatic (DOS Setup) -> optional answer file from `Unattended\` ->
*New installation* -> disk -> size (**32 GiB** recommended, 8 or 2 GiB) ->
confirm. UEFI PC without CSM: UEFI menu -> Utilities -> *Legacy BIOS mode
(CSMWrap)* -> *Start BIOS mode* (or a row with an answer profile, below) ->
the same BIOS menu path. Remove the stick when Setup restarts the first time.

## 2. Pieces

| Piece | Solution | Licence |
|---|---|---|
| DOS Setup, all four systems | Legacy Core `dos_native_iso.zig`: the ISO's El Torito floppy + the CD's Setup folder (`WIN98`, `WIN9X` for Me, `WIN95`) in a 256 MiB RAM FAT16 under MEMDISK; `INSTALL.BAT` (`dos_startup.cmd`) formats nothing itself: the Core writes MBR + FAT32 (4/8/16 KiB clusters by size, FAT < 16 MiB for 16-bit ScanDisk), `SYS C:`, copy, patch, `SETUP C:\<folder>\MSBATCH.INF /IS /IE /NM` | USOS GPL-3.0-or-later; Microsoft files from the user's ISO |
| Me | Me's `SYS` refuses a new disk ("only to repair C:"): skipped, Me Setup makes C: bootable; the Me floppy has no `HIMEM.SYS` (its IO.SYS has XMS) | same |
| 95 (non-bootable CD) | `Systems\Windows\Windows 95\Boot\BOOTDISK.IMG`: any 1.44 MB DOS 7.x startup disk (the user's 95 OSR2 boot disk, or the 98 SE CD's floppy). **Temporary bridge, "do zastąpienia własną implementacją"**. Tried on 2026-09-30 without an image: the RAM disk boots the bundled FreeDOS, the CD's own `EXTRACT.EXE` takes `winboot.sys` (IO.SYS) and `command.com` from `PRECOPY1.CAB` and `himem.sys` from `WIN95_02.CAB` (works); the boot sector is the blocker: the vendored FreeDOS SYS 3.6 is built without its OEM boot sectors (`/OEM:W9x` missing, `WITHOEMCOMPATBS` off), and the CD's own `SYS.COM` fails under FreeDOS (DOS extended error 26 on the FAT32 target). Reverted; next step: a FreeDOS SYS build with the OEM boot sectors (GPL, needs the OpenWatcom DOS libraries and NASM in the build kit), or running the Core's preparation from a DOS 7 environment | the image is user-supplied |
| Answer file | `MSBATCH.INF`: (1) the file chosen from DATA `Unattended\*.inf`, copied 1:1; (2) `\EFI\USOS\answer\<98SE,98,ME,95>.INF` rendered by the UEFI menu from a profile (BIOS mode page: one row per profile offered for 95/98/Me, `stageWin9x`; removed at the next UEFI start); (3) the USOS default `src/platform/bios/win9x/msbatch.inf` (typical, no startup disk, no network components, `NoPrompt2Boot`, `DevicePath=1`, Welcome/Regwiz off, memory limits by `UpdateInis`). Renderer: `src/flow/answer/msbatch.zig` (owner, org, computer, 9x time zone key; `ProductKey` for 98/Me (5x5), `ProductID` for 95: profile keys may be 5x5, 95 OEM `ddddd-OEM-ddddddd-ddddd` or 95 retail `ddd-ddddddd`, `profile.keyShape`, auto-formatted by `normalizeKey`; a key of the other kind is left out, NT systems never get a 95 key). Profile group `windows-9x`; `windows` now includes 9x. **Post-install hook** for other work (the legacy-compat pack): the `[Install]` section (`AddReg=USOS.RunOnce`, `UpdateInis=USOS.Memory`) of both the default file and the renderer: add `RunOnce` entries or INF sections there | USOS |
| RAM | Patcher9x 0.9.91 `-select all` on the Setup folder (TLB for Zen, CPU speed for 95/98 FE, R. Loew memory patch, dirty CR registers, 4G resource); `MSBATCH.INF` `UpdateInis` writes `[386Enh] MaxPhysPage=40000` (1 GiB) and `[vcache] MaxFileCache=262144` during Setup (all 9x, Me included); **U9FIX.COM** (own, 1 KB, `src/platform/bios/win9x/u9fix.S`) re-adds them from `AUTOEXEC.BAT` before every start on 95/98 when missing (Me skips real-mode AUTOEXEC programs) and keeps user values | Patcher9x MIT (memory part: Loew, status as in the feasibility study); U9FIX GPL-3.0-or-later |
| Fast CPU (95, 98 FE) | Patcher9x's own `speed` patch (NTKERN, IOS, ESDI_506, SCSIPORT, NDIS: 80x loop + divide-by-zero guard) on the install media. FIX95CPU is **not** needed (and contains patched Microsoft VxDs, not bundleable) | MIT |
| Storage | No 9x AHCI driver is bundleable (R. Loew AHCI.PDR: no licence stated by the heirs; SweetLow patches are patched binaries). 9x uses **MS-DOS compatibility mode** (INT 13h) on AHCI: under plain SeaBIOS and under CSMWrap it installs and runs (QEMU), slower than native. Own clean-room IOS port driver (.PDR) = future work | - |
| Display | **vmdisp9x 1.2025.0.119** (JHRobotics, MIT) VESA driver (`vesamini.drv/.vxd` + VMHal9x) in `C:\<folder>` with USOS's `USOSVESA.INF` (VESA model only); `U9FIX /VGA` adds the PCI IDs of this PC's display controllers (hardware ID outranks Standard VGA's `PCI\CC_0300`). VBEMP 9x is **not** bundleable (non-commercial, "not bundled without permission") | MIT (vendored, `tools/vendor/vmdisp9x`) |
| USB input under CSMWrap | Win9x GUI sees no USB keyboard/mouse (no 8042 emulation in CSMWrap/SeaBIOS). The Windows 3.x bridge works unchanged in **98 / 98 SE** (Setup phase 2 wizard and later): `USOSKEY.COM` + `USOSKEY.DRV` (`drivers=`) and VBADOS `VBMOUSE.EXE` + `VBMOUSE.DRV` (`mouse.drv=`); `U9FIX /CSM` adds both to `[boot]`, `AUTOEXEC.BAT` copies the drivers after Setup's first restart. **Me keyboard** (2026-10-03): Me runs no real-mode program from AUTOEXEC.BAT and no WINSTART.BAT (tested), so `USOSKEY.DRV` now installs the TSR's resident part itself when it finds no TSR: a copy in DOS memory (`GlobalDosAlloc`), INT 09h/15h/1Ch/2Fh hooked in the system VM's real-mode vector table (DPMI 0200h/0201h), restored when the driver is freed; `INSTALL.BAT` puts the driver into `C:\WINDOWS\SYSTEM` before Setup and appends `system.ini,boot,drivers,,usoskey.drv` to MSBATCH.INF `[USOS.Csm]` (UpdateIniFields). QEMU OVMF+CSMWrap: USB keyboard types in Me's first-run wizard (`me-csmwrap-usb-keyboard.png`). **Me mouse: not yet** (Me's VMM32 has no `*VMD`, so VBMOUSE.DRV hangs the start; tried 2026-10-03: the resident part registered as the INT 15h C207h PS/2-BIOS callback (through DPMI 0300h from USOSKEY.DRV) and the driver fed USER's mouse_event; Me stopped with a Windows protection error at the first USB mouse report, also with the mouse_event call disabled, so the callback path itself fails inside Windows (SeaBIOS calls it from its USB poll, which on CSMWrap runs outside the VM); not committed. Next: a VxD-level mouse (own *VMD replacement for VBMOUSE.DRV) is the likely path). **Not in 95 Setup phase 1** (its licence and COA pages run in Setup's own mini-Windows, before the bridge exists). Only with CSMWrap (real BIOS: SMM emulation / PS/2) | USOS GPL-3.0; VBADOS GPL-2.0+ |
| USB (xhci98) | Not wired: on 98/Me it needs `usbport.sys` from NUSB / SweetLow (Microsoft binaries, user-supplied only), and the 98/Me x86 build needs MSVC 6 + the Windows 2000 DDK (archive-only; the usos2 WDK 7.1 build targets WNET, not 98). The usos2 patches (AMD CPU xHCI) would need that toolchain | GPL-2.0-only |
| Windows 95 USB | none (no WDM USB before OSR2.1's add-on); under CSMWrap the USOSKEY/VBADOS bridge covers input |
| ACPI / timer | QEMU: 98 SE installs to the desktop and Me passes its Plug and Play detection with ACPI under SeaBIOS (i440FX); no `/p i` needed there. CSMWrap builds an MP table and `$PIR`; on the X470 `SETUP /P I` (no ACPI) stays the fallback if detection hangs (not wired: a Setup switch, today only by editing `INSTALL.BAT` on the stick ESP) |
| CSMWrap ESP | as for MS-DOS: 64 MiB FAT16 type 0xEF at the disk tail (`dos_csmwrap_esp.zig`), partition end checked against it; HIMEM `/M:2` in the RAM disk and in the target `CONFIG.SYS` (A20 through port 92h) |
| Boot logo | `Logo=0` in MSDOS.SYS for 95/98 (text boot; also shows start messages). The logo hangs QEMU in SeaBIOS SMM (a QEMU test issue: CSMWrap has no SMM); Me writes its own MSDOS.SYS, so the Me QEMU run uses `tools/tests/legacy_bios/win9x_logo_off.py` |

Partition size: FAT32 32 GiB by default (8 and 2 GiB selectable), the rest
unallocated; never above 127 GB (98 without patches) and always inside
the first 137 GB (LBA28 boot).

## 3. QEMU results (QEMU 11.1, i440FX, TCG, 2048 MiB, AHCI 60 GB target)

| System / media | Plain SeaBIOS | OVMF + CSMWrap |
|---|---|---|
| 98 SE PL OEM | **desktop** (one run with the user's own key typed at Setup's key page, never stored; `MaxPhysPage`/`MaxFileCache` applied by U9FIX) | install -> target ESP -> CSMWrap -> Setup phase 2 -> key page; **USB keyboard + USB mouse work in the Windows GUI** (USOSKEY/VBADOS, integrated) |
| Me PL OEM (4.90.3000) | key run (the user's key typed, no screenshot kept): wizard finished, Setup's last restart then stopped with "KRNL386.EXE not found" and an empty C:\WINDOWS directory; that disk had been converted to raw and edited by the test helper (logo off) between the restarts, so the result is not conclusive; `UpdateInis` memory limits confirmed in SYSTEM.INI after phase 1 | with a key (OVMF + CSMWrap, PS/2 keyboard): phase 1 -> target ESP -> phase 2 -> the wizard (user, licence, key, finish) -> **desktop** (`me-csmwrap-desktop.png`); **USB keyboard dead** (bridge not loaded by Me) |
| 95 OSR2.1 PL + 95 OSR2 boot disk (bridge) | Setup -> licence -> Setup wizard -> COA page: with `ProductID` in MSBATCH.INF and `/IS` only, Setup still shows the licence and the wizard and leaves the COA fields empty (not taken from the file), typing the key by hand was not finished (the three-field page); **95 is not unattended yet** | Setup phase 1 -> licence page; **USB keyboard and mouse dead** (Setup's mini-Windows) |
| 95 OSR2.1 PL + the 98 SE floppy | same, key page | not run |
| 98 FE PL | **desktop** with the user\'s key in MSBATCH.INF (`ProductKey` pre-filled the key page; the OEM wizard still showed user, licence and key pages: Enter / "Akceptuję" / Enter); one "Windows protection error" on the first normal boot, the following boots fine with both memory limits | phase 1 -> target ESP -> phase 2 -> key page, **USB keyboard works** (bridge) |

The key runs used the user's own keys for one local run each (kept outside
the repo, never logged; key files and key-bearing VM disks deleted after; no
screenshot of a filled key page kept). The CSMWrap runs without a key end at
the key page. USB keyboard in the USOS BIOS menu and in DOS worked in
all CSMWrap runs (SeaBIOS INT 16h). VESA driver: prepared (INF + IDs,
unit-tested), not yet seen on a desktop (the desktop run predates it).

VESA on the RX 560 (2026-10-06): 640x480x16 works; switching to 1024x768 gives
exception 0D at 0377:3F2F (DIBENG fill). In vmdisp9x 1.2025.0.119 the VXD sizes
VRAM once at boot as VBE TotalMemory*64K (capped by `VRAMLimit` MB) and then
shrinks it to the first read-back mismatch of a full VRAM pattern test unless
`NoMemTest`=1. The 16-bit selector given to DIBENG is built from that size once
and never resized. A mode change does not check that the new surface fits:
without a working 4F07 flip, GDI draws at offset `stride`, so 2*pitch*height
must fit. `HKLM\Software\vmdisp9x\vesa` also reads `MTRR` (no effect in 119),
`DosWindowSetMode` and `HWDoubleBuffer` (0/1/2; 1 and 2 both fall back to a
plain 4F07 test). 119 is the latest release. Upstream master (unreleased,
2026-05 "new vram management", "VESA: real HW fixes") draws into a RAM shadow
buffer instead. USOSDIAG 1.3 logs the VGA BARs and the VBE mode table ("need"
= pitch*height, ">MEM" past TotalMemory) for the diagnosis. BIOSTAR test disk:
one-time `C:\USOS9X\VESAFIX.BAT` sets `NoMemTest`="1" (backup `SYSTEM.VB`/`USER.VB`). Since 2026-10-06 USOSVESA.INF sets it by default (section 4e).

## 4. X470 test plan (CSM off, Secure Boot off, spare SATA disk; USB keyboard and mouse only, no PS/2)

0. Where to start (2026-10-03, after the X470 report "98 SE is locked"): in the UEFI menu
   Windows 95/98/Me (and DOS, Windows 3.x) need BIOS mode; up to B261003-180320 their rows
   showed a "Requires BIOS" lock and the hint to boot the stick in CSM mode, which a PC
   without CSM cannot do; the path was Utilities -> Legacy BIOS mode. Since a5a2474 the rows
   carry a "Legacy BIOS mode" badge and Enter opens the BIOS mode page for that system
   (its profiles, a note to pick it again in the BIOS menu); QEMU OVMF: 98 SE row -> Start
   BIOS mode -> BIOS menu -> 98 SE -> Setup runs (`uefi-98se-via-bios-mode-*.png`).
1. 98 SE via BIOS mode with a profile holding the user's key (`systems=windows-9x`,
   `remember_key=yes` or typed): install, remove the stick at the first restart,
   the disk boots through its ESP; check USB keyboard/mouse in Setup's wizard and
   on the desktop, `C:\WINDOWS\SYSTEM.INI` (MaxPhysPage, usoskey.drv, vbmouse.drv),
   System Properties RAM (1 GB), display (vmdisp9x VESA modes on the RX 560),
   Device Manager (disks in compatibility mode).
2. If PnP detection hangs (no PS/2 fallback on this board): power off, boot the
   stick again, BIOS mode -> the same system -> *New installation* (the disk is
   prepared again, nothing to type), after adding `/P I` (no ACPI) to the SETUP
   line of `EFI\USOS\dos-native\ram-patch\INSTALL.BAT` on the stick ESP from
   another PC. Also useful before the run: in the X470 setup disable unused
   controllers (second SATA/ASMedia, HDA, onboard LAN), Above 4G and ReBAR off.
   What cannot be answered with USB only: Me (no bridge) and 95 (licence/COA in
   Setup phase 1): Me still shows the OEM wizard pages (user, licence, finish) even with its key
   in the profile, so a USB-only Me install stops there until the wizard is
   answered by USOS; 95 is not possible without PS/2 on the X470 today.
3. Me only once the OEM wizard is answered by USOS (or on a PC with PS/2); 95 only on a PC with a PS/2 keyboard or a firmware CSM.
4. Regression: MS-DOS / Windows 3.1 install under CSMWrap still boots.

## 4b. OEM CDs, product keys, editions (2026-09-30 evening)

* **OEM first-run wizard.** On the OEM CDs (98 FE, 98 SE, Me) phase 2 shows the
  user, licence, key and finish pages even with a full MSBATCH.INF
  (`ShowEula=0`, `Display=0`, key given): they are the OEM wizard of Setup
  phase 2, not the batch pages. With a key in the file the key page is
  pre-filled. For the product: a **conscious accept in USOS** (the summary /
  confirmation page states that the Microsoft licence is accepted for the user
  and the wizard is then answered), plus a check of the documented batch
  options for OEM (`[Setup] OEMPreinstall`, `[OptionalComponents]`) and the
  registry key the wizard uses; not done yet, so USB-only (CSMWrap) installs
  of OEM CDs need the bridge for these pages (98 / 98 SE: works; Me: no bridge).
* **Edition detection.** Every CD checked has `SETUPPP.INF [data]
  ProductType=9` (95 OSR2.1, 98, 98 SE, Me; all Polish OEM) and `LOCALE.INF
  Default_Locale = "L0415"`, SubVersionString `" A "` for 98 SE and `" B"` for
  95 OSR2. Both files are inside PRECOPY1/2.CAB **compressed with LZX (98/Me)
  or Quantum (95)**, not MSZIP, so a reader needs an LZX and a Quantum decoder
  (own clean-room code, or libmspack (LGPL) in the micro-Linux). An MSZIP-only
  prototype was dropped for that reason. Until then the release comes from the
  folder (WIN95 / WIN98 / WIN9X) and the menu shows the image name; loose files
  do not separate OEM from retail (OEMSETUP.EXE is on all four CDs).
* **Upgrade CDs** (compliance check): not available to test; Setup on a clean
  disk asks for a qualifying CD or floppy of the previous version.
* **Windows 95 key**: `ProductID` did not fill the COA page of the OSR2.1 OEM
  Setup in QEMU; a 95 install needs the key typed (three fields) today.

## 4c. Install from the UEFI menu without CSM (2026-10-04)

The normal flow, like XP x64 / Server 2003: Windows 95/98/Me, MS-DOS 6.22 and
Windows 3.1/3.11 rows are `firmware=any`; on a UEFI PC the automatic method
is the backend `win9x_uefi` (profile `w9x-uefi-csmwrap`, experimental). No
BIOS mode is offered from system rows (user decision); the Legacy BIOS mode
stays an advanced tool under Utilities. BIOS-only systems without a UEFI
flow (FreeDOS, PC DOS, NT 4.0, betas) show "Unavailable".

* UEFI: summary -> Enter writes `EFI\USOS\win9x\request.ini` (system, name,
  DATA image path, answer, size; a profile is staged as MSBATCH.INF) and
  starts the base micro-Linux with `usos.legacy_action=w9x-csmwrap`.
* micro-Linux step 620 (`tools/w9x_csmwrap_prepare.sh`): the XP/Vista disk
  picker and erase confirmation, then one of two writers (only the chosen
  disk; USOS MBR, CSMWrap ESP at the end via `xp_csmwrap_esp.sh`):
  * `tools/w9x_csmwrap_target.sh` (95/98/Me): FAT32 C: (<= 32 GiB), the CD's
    Setup folder, `C:\USOS9X` (INSTALL.BAT, U9ENV.BAT, MSBATCH.INF, helpers,
    Patcher9x, MEMDISK, BOOT.IMG = the CD's El Torito floppy with our
    AUTOEXEC/CONFIG, without JO.SYS; 95: the BOOTDISK.IMG bridge);
  * `tools/dos_csmwrap_target.sh` (MS-DOS, Windows 3.x): FAT16 06h 256 MiB,
    no volume label, IO.SYS/MSDOS.SYS placed first with mtools (MS-DOS SYS
    needs them at root entry 0 / cluster 2), `C:\USOSDOS` (msdos helpers,
    DOSFILES, WINSETUP, DATA programs, CSMWRAP.TAG), the MS-DOS 6.22 floppy.

  Both start the floppy once through syslinux (Alpine's mtools installer,
  GPL-2.0-or-later) + MEMDISK; INSTALL.BAT runs in disk mode, SYS replaces
  syslinux, the syslinux files are deleted.
* REBOOT.COM resets the platform (CF9h, then 8042) before the old jump to
  FFFF:0: under CSMWrap that jump only re-entered SeaBIOS, which kept MEMDISK
  hooked and booted the RAM floppy again (endless install loop).
* QEMU OVMF: Windows 3.1 to its desktop (MS-DOS installs, Win 3.1 Setup:
  two Enter presses in its DOS part, then batch Setup, USOS start menu);
  98 SE: phase 1, restart through CSMWrap, wizard with the USB keyboard,
  hardware setup, final restart.
* 98 SE finding: VBADOS VBMOUSE.EXE next to the PS/2 mouse VxD that Setup
  installs in its last phase stops the installed system with a protection
  error at KERNEL init (bisected on the disk). The CSMWrap bridge is now
  keyboard-only (U9FIX /CSM adds only usoskey.drv). **A USB mouse in the
  installed Windows 9x under CSMWrap is open** (planned: a VxD-level mouse).
* 98 SE USB mouse, 2026-10-06 (**untested on the X470**): `USOSMOUS.DRV`
  (`[boot] mouse.drv=usosmous.drv`, clean-room Win16 mouse driver, module
  MOUSE) registers USOSKEY.COM's resident callback with INT 15h C205h/C207h/
  C200h through DPMI 0300h on Enable; SeaBIOS far-calls it per packet, the TSR
  queues packets in the shared block (version 4, +396), the driver drains them
  from a 20 ms system timer into USER's event procedure. `[386Enh]` stays
  without `*vmouse`. U9FIX /CSM writes the `mouse.drv=` line only when
  `SYSTEM\USOSMOUS.DRV` exists (98 SE only); USOSDBG 1.2 shows MOUSE lines.
  QEMU, plain SeaBIOS, i8042 PS/2 mouse (same BIOS callback path, IRQ 12
  instead of the USB poll): pointer moves and a click opens the Start menu.
  The USB source itself is not covered in QEMU (plain SeaBIOS hangs in SMM,
  without SMM it cannot poll xHCI from V86; CSMWrap from an extra ESP disk
  returns Unsupported in the OVMF shell). Revert: `mouse.drv=mouse.drv`.
* 98 SE end to end (QEMU OVMF, 2026-10-04): the user's key typed in the wizard, hardware setup, final
  restart, **desktop with the USB keyboard** (`uefi-98se-desktop-usb-keyboard.png`). Second finding: the
  DOS `KEYB` TSR that Setup appends to AUTOEXEC.BAT, loaded after USOSKEY.COM, also stops Windows with a
  protection error at KERNEL init; under CSMWrap our AUTOEXEC block renames `KEYB.COM` to `KEYB.USO`
  before that line runs (Windows keeps its own layout; DOS prompts show one "bad command" line).
  Ctrl+Esc through the USB bridge did not open the Start menu in QEMU (single keys work): open.
* Safe mode under CSMWrap hangs (Windows loads HIMEM without /M:2), so
  MSDOS.SYS gets `BootMenuDefault=1`; after a failed start Windows 98 still
  defaulted to Safe mode in QEMU (the setting does not override that default): open.
* MS-DOS media: an ISO in `Systems\DOS\MS-DOS\Images` (Windows 3.x needs it
  as `MS-DOS 6.22.iso`); a .zip holding the ISO is a planned convenience.
* Native USB keyboard and mouse in 98 SE (2026-10-05, wired, **blocked by CSMWrap**):
  xhci98 `1.1.1.0-usos3-w9x` (`tools/vendor/xhci98/1.1.1.0-usos3-w9x`, GPL-2.0, usos3 polling built for
  98 with WDK 7.1: no file sink, KeSetTimer, no /GS; all imports also used by NUSB's drivers on 98).
  The user puts the NUSB installer EXE into `DATA\Drivers\Windows 98 SE\USB`; the 98 SE target writer
  carves its cabinet to `C:\USOS9X\USB\STACK.CAB`, INSTALL.BAT copies `XHCI98.SYS/.INF` + `STACK.CAB`
  into `C:\WIN98`; `XHCI98.INF` takes `usbport.sys`/`usbhub20.sys` from the cabinet (disk 2, LZX,
  which DOS `EXTRACT` cannot unpack) and binds the USB 2.0 root hub. No stack: nothing changes.
  QEMU (one install run): Setup and the desktop are fine (a WHPX run stopped with a protection error at
  KERNEL init, the same disk under TCG reaches the desktop). **But 98 sees no PCI bus at all**:
  `DETLOG.TXT` `int 1a,AX=b101` -> `PCIBUS=` empty, every devnode is `ROOT\...`, so the xHCI never
  appears and xhci98 cannot bind.
* 2026-10-05 correction: **the PCI BIOS is not missing.** SeaBIOS (upstream and the CSMWrap fork) routes
  AH=B1h before `handle_1a`: `entry_1a_official` in `romlayout.S` jumps to `entry_pcibios16`. On the
  installed 98 SE under CSMWrap 3.1.2-usos3, DOS `DEBUG` gets AX=0001, BX=0210, EDX="PCI ", CF=0. A
  `pci_bios` patch (usos4) was built and tested, made no difference, and was dropped (no CSMWrap change).
  The same QEMU install (pci_bios on) still showed `PCIBUS=` empty and no `PCI\` devnode. Likely cause, to
  check next: 98 finds a `$PnP` header (`*PNP0C00` detected), so the PCI bus has to come from the PnP BIOS
  node list, which SeaBIOS does not provide (only function 60h). ACPI is refused ("ACPI BIOS ... not
  compatible"). Options: force ACPI (`setup /p j`), or a SeaBIOS build without the `$PnP` header so
  detection adds the PCI bus itself. Also seen: boots through the 98 boot menu (normal/logged) sometimes
  stop after `SHELL` / at `Initializing KERNEL` and restart. This happens with or without the patch, while
  `win` from the command-prompt entry reached the desktop.

## 4d. 98 / 98 SE Setup phase 1 in a VM on the target (2026-10-05, milestone 1)

On the X470, SETUP.EXE's DOS stage hangs under CSMWrap. For Windows 98 and 98 SE, step 620 now
runs that stage in QEMU on the same machine and only the rest on the real hardware:

* `qemu9x.cpio` (`EFI\USOS\micro-linux`, built by `tools/build_micro_linux.py` from the `qemu9x`
  section of `tools/micro_linux.lock.json`): Alpine v3.24 `qemu-system-i386` 11.0.3, SeaBIOS
  `bios-256k.bin` and `vgabios-stdvga.bin` 1.17.0, the shared objects QEMU needs that initramfs-usos
  lacks (DT_NEEDED closure), and the `kvm`, `kvm-amd`, `kvm-intel` modules. About 13 MB, loaded
  as a second initrd only on the w9x command line (`vista_preparation.zig`), so other paths and
  `initramfs-usos` are unchanged.
* `tools/w9x_phase1_qemu.sh`: after `w9x_csmwrap_target.sh` wrote the disk (VM mode:
  `U9VM=1` in U9ENV.BAT, so INSTALL.BAT adds `/P I` to Setup; the real PC's display IDs go into
  USOSVESA.INF because U9FIX /VGA in the VM sees QEMU's card only), QEMU boots **the whole target
  disk**: `-machine pc,acpi=off`, `-cpu pentium3`, 512 MiB, IDE, `cache=none` (O_DIRECT), no network,
  `-no-reboot`. Setup's first restart ends the VM. The screen shows "{system} installation - stage 1 in
  the background" with elapsed time and MB written. Then `C:\WINDOWS\WIN.COM`, `SYSTEM`,
  `SYSTEM.INI` and `SETUPLOG.TXT` are checked (after `sync` + `blockdev --flushbufs` and a
  read-only `fsck.fat -n`, repeated after the USOS changes; any error stops, `fsck.txt`), the
  VM's `[386Enh] mouse=` line and a second HIMEM line of CONFIG.SYS are removed (`patch.txt`),
  `C:\USOS9X\PHASE1.OK` is written, and the normal
  "start the prepared disk" restart follows. If the VM fails or times out (90 min), a translated
  stop screen appears and the PC does not restart. Logs go to `EFI\USOS\win9x\phase1\` (command,
  QEMU, SeaBIOS debugcon, monitor, the last screendump, INSTALL.LOG, SETUPLOG/DETLOG).
* The default is TCG. KVM is used only with `EFI\USOS\win9x\phase1-kvm.flag` and a working
  `/dev/kvm`. `EFI\USOS\win9x\phase1-native.flag`, less than about 900 MB RAM, 95 without a key (section 4h) or no
  qemu9x.cpio keep the old path (DOS Setup on the real PC). Me uses the VM since 2026-10-06 (section 4g).
* Licence gap before a release: Alpine's QEMU links `libsasl2` (BSD-4-Clause-Attribution), which
  is not GPL-compatible. Milestone 2 replaces the Alpine binaries with our own minimal static
  build (no VNC/SASL/Xen/slirp).

## 4e. 98 SE on the X470: hardware results folded in (2026-10-06)

X470 (CSMWrap, 98 SE PL OEM, phase 1 in the VM): USB keyboard fully works (USOSKEY v3), USB mouse
works (move, clicks, drag; USOSMOUS.DRV) but was far too fast with a Logitech G502, 1920x1080 16bpp
works once `NoMemTest`="1" is set. Now the default for fresh installs:

* **VESA**: `USOSVESA.INF` adds `HKLM\Software\vmdisp9x\vesa NoMemTest="1"` next to `VRAMLimit`
  (no VESAFIX.BAT any more); `build_win9x_support.py` refuses an INF without it.
* **Mouse speed**: USOSMOUS.DRV scales every movement by `SYSTEM.INI [usosmous] Multiplier=` /
  `Divisor=` (default 1 / 2, limits 1..4 / 1..16) with the remainder carried per axis (dropped when
  the direction turns), `src/platform/win3/usosmous_scale.h`, host-tested. USER then applies the
  Control Panel speed and acceleration as before. Slower: `Divisor=3` or `4`; faster: `Divisor=1`.
* **Date/Time page**: with no answer chosen (`answer=none`) the UEFI menu writes the menu language's
  9x zone key into `request.ini` (`timezone=Central European` for Polish, `msbatch.timeZoneForUi`)
  and `w9x_csmwrap_prepare.sh` puts `TimeZone="..."` into `[Setup]` of the default MSBATCH.INF
  (MSBATCH TimeZone, Windows 98 Resource Kit appendix D; key names from the CD's TIMEZONE.INF).
  Profiles already carry their zone; a user file is copied 1:1. The BIOS-mode path (no UEFI request)
  still uses the default file without a zone.
  Guard (2026-10-06): `prepare.log` always gets a `TIMEZONE <key>` line (`none` when request.ini has
  no `timezone=`), and prepare stops with a clear message when a zone was given but `TimeZone=` is not
  in the copy afterwards. The insert itself was checked under the micro-Linux BusyBox 1.37 (QEMU, the
  stick build's vmlinuz-virt and busybox): it works. The fresh X470 run of B261006-133533 (16:02)
  still had no `TimeZone` in `C:\USOS9X\MSBATCH.INF` although that build contained both halves; its
  `request.done` / `prepare.log` were not read yet, so the cause (no `timezone=` in the request, or
  the insert) stays open until the next run's `TIMEZONE` line.
* **First-boot Date/Time step (TZFIX)**: SETUPC.INF `[NewWin.AddReg]` always adds the
  `RunOnce\Setup` value "Strefa czasowa" / "Time Zone" = `TIMEDATE.CPL,,/f`; whether MSBATCH
  `TimeZone` alone keeps that dialog away is not proven on hardware. So 98 / 98 SE with the default
  answer and a zone known to `tools/w9x_tzfix.sh` (Central European, Eastern so far; TZI from the
  98 SE CD's TIMEZONE.INF) also get `C:\USOS9X\TZFIX.BAT` + `TZFIX.REG` / `TZRO1.REG` / `TZRO2.REG`,
  called from AUTOEXEC.BAT after U9FIX. Once, in real-mode DOS, and only while the TIMEDATE step is
  pending: backup of SYSTEM.DAT / USER.DAT (`SYSTEM.TB` / `USER.TB`), `REGEDIT /L /R` import of
  TimeZoneInformation, the step's value replaced by a harmless command, check by `REGEDIT /E` + FIND,
  restore on failure. Result: `C:\USOS9X\TZFIX.OK` (`ok`, `ok-zone-only`, `not-pending`) or
  `TZFIX.BAD`. The same registry change was proven by hand on the X470 (`ok-deleted`, 2026-10-06).
* **Diagnostics**: `USOSDIAG.COM` and `USOSDBG.EXE` are on the stick and in `C:\USOS9X`, but nothing
  runs them; `EFI\USOS\win9x\diag.flag` (U9DIAG=1) adds `USOSDIAG BOOT` to AUTOEXEC.BAT.
* Unchanged and checked: USOSKEY v4 (.COM + .DRV), `mouse.drv=usosmous.drv` (98 SE), no `*vmouse`,
  xhci98 opt-in only, CREGFIX first in CONFIG.SYS, no second HIMEM line after the VM phase, APM left
  on (APM off was only a keyboard debugging step).
* **KERNEL32 crash on program exit (fixed, ae44717)**: in the final setup phase (RunOnce: TIMEDATE.CPL,
  grpconv, winhlp32, PIFMGR, walign) Win32 processes faulted on exit with exception 0E at
  `0167:BFF8976B` in KERNEL32 (current-thread pointer corrupt), also with USOSMOUS.DRV off. Root cause:
  the 20 ms SYSTEM.DRV timer callback of USOSKEY.DRV runs at interrupt time and can interrupt a Win32
  thread, yet it called USER (GetAsyncKeyState for the keybd_event log, GetActiveWindow / GetClassName
  for the DOS-box test) and did not save all registers. Fix: `poll()` of USOSKEY.DRV and USOSMOUS.DRV
  is a naked entry that saves all 32-bit registers and DS/ES/FS/GS; the DOS-box test is a WH_CBT hook
  (HCBT_ACTIVATE) that only sets a flag; the callback calls nothing but keybd_event, the mouse event
  procedure and VKD (`tools/tests/legacy_bios/test_usoskey_timer_safe.py` walks the call graph).
  Hardware (BIOSTAR, installed 98 SE): opening and closing programs no longer crashes.
* **Known limit**: USB mouse hotplug does not work (SeaBIOS enumerates USB at boot); plug the mouse in
  before the start.

Still manual (needs a click or a key) in a fresh hands-off 98 SE run:

* **OEM first-run pages** (user information, licence, product key, finish): on the OEM CD these are
  SETUPX's first-run screens (`FirstRunScreens` in SETUPX.DLL, driven by `ProductType`=9 from
  SETUPPP.INF; OPK audit files `C:\WINDOWS\OPTIONS\OEMAUDIT.INF` / `EndUser.INF` with
  `[Dialog_Display]`), not MSBATCH pages: `Display=0`/`ShowEula=0` do not hide them, a profile key
  only pre-fills the key page. No documented MSBATCH key removes them; changing `ProductType` was not
  tried (it changes the key validation). The bridge keyboard/mouse answer them.
* **Add New Hardware for the monitor**: vmdisp9x's `DDC`=1 lets 98 enumerate the EDID monitor
  (`Monitor\<PnP id>`); MONITOR.INF matches it only through the compatible id `*PNP09FF`, so 98 asks
  for a better driver. Planned: read the PnP id from the UEFI EDID protocol (EDID Active/Discovered on
  the GOP handle, bytes 8-11), pass it in `request.ini` and add a USOS monitor INF with that hardware
  id next to Setup. `DDC`=0 is no option (Unknown Monitor caps at 640x480).

## 4f. Windows 98 (first edition) through the same UEFI flow (2026-10-06)

Audit of the CSMWrap path for `windows-98` (tag `98`, Setup folder `WIN98`), media: the user's
`Windows_98_PL.iso` (4.10.1998 PL, files dated 1998-05-15) in DATA `Systems\Windows\Windows 98\Images`;
the menu tells 98 from 98 SE by the DATA folder (catalog `windows-98` / `windows-98-se`), not by CD files.

* Already shared with 98 SE: phase 1 in the VM + `/P I` (`w9x_vm_available` takes `98SE|98`), Patcher9x
  `-select all` (includes the 95/98 FE CPU speed patch), CREGFIX, USOSKEY v4, vmdisp9x VESA with
  `NoMemTest`, the default MSBATCH.INF (every key is a 98 FE key too), TZFIX (`98SE|98`).
* New for 98: `USOSMOUS.DRV` is kept (INSTALL.BAT `MOUSEOK` for `98`), so U9FIX `/CSM` writes
  `mouse.drv=usosmous.drv` as on 98 SE; 95 / Me still drop it.
* TZFIX on 98 checked against the CD (PRECOPY1.CAB): `TIMEZONE.INF` has the same TZI for
  Central European and Eastern, `SETUPC.INF` adds the same `RunOnce\Setup` value "Strefa czasowa"
  (`TIMEDATE.CPL,,/f`). The 98 CD lacks one key of the menu's list, `Pacific SA` (added in 98 SE):
  `w9x_release_time_zone` drops it for 98 (Setup asks). A profile with that zone still writes it.
* Startup menu (all 95/98/98 SE): INSTALL.BAT writes `BootMenu=0` next to `Logo=0` /
  `BootMenuDefault=1` in `C:\MSDOS.SYS [Options]` (nothing in the chain sets `BootMenu=1`); Windows
  still shows the menu by itself after an unclean shutdown or a failed start.
* Unchanged: xhci98 stays 98 SE + opt-in only (98 FE has no USB 2.0 stack; NUSB does not apply).
* Risks, not seen on hardware yet: the OEM first-run pages as on 98 SE (bridge keyboard/mouse);
  the phase-1 VM path was proven with 98 SE only (98 FE reached the desktop in QEMU, section 3); IE 4 desktop update.

## 4g. Windows Me through the same UEFI flow (2026-10-06)

Audit of the CSMWrap path for `windows-me` (tag `ME`, Setup folder `WIN9X`), media: the user's
`Microsoft_Windows_ME_(4.90.3000)_[Polish]_(OEM).iso` (old tree root; DATA `Systems\Windows\Windows Me\Images`
on the Kingston is still empty, copy it there before the X470 run).

* **Phase 1 in the VM** (new): `w9x_vm_available` now takes `98SE|98|ME`; 95 alone keeps the native start.
  Me's SETUP.EXE has the same DOS stage as 98 and accepts `/P I` (U9VM=1). Nothing else changed in
  INSTALL.BAT: Me skips `SYS C:` (its Setup writes the MSWIN4.1 boot sector and IO.SYS/MSDOS.SYS in the VM)
  and copies USOSKEY.DRV into `C:\WINDOWS\SYSTEM` before Setup, plus the `[USOS.Csm]` line
  `system.ini,boot,drivers,,usoskey.drv` (profile and default answer; a user file is copied 1:1).
* **Keyboard**: no TSR on Me, USOSKEY.DRV installs its own resident copy; that copy is the whole USOSKEY.COM
  resident part (`tsr_image` up to `resident_end`), so it has the v4 mouse ring and callback (`mcb`) and the
  INT 16h guard (TSR_HOOKS: 08h/09h/15h/16h/1Ch/2Fh).
* **Mouse**: still off on Me (INSTALL.BAT deletes USOSMOUS.DRV for 95/Me, nothing names it). Two open
  problems: the earlier Me callback test ended in a protection error at the first USB mouse report, and Me
  runs nothing at every start that could set `mouse.drv=usosmous.drv` again after Setup's detection (U9FIX
  /CSM only runs from AUTOEXEC.BAT on 95/98).
* **TZFIX: not needed on Me.** The Me CD's SETUPC.INF (PRECOPY1.CAB) defines `SetTimeZone_Desc` but adds no
  `RunOnce\Setup` TIMEDATE step (its `[NewWin.AddReg]` has only wallpaper, RunOnceEx 101 and VPOWERD); Me's
  TIMEZONE.INF has every key of the menu's list (63; Me adds 12 more), so `TimeZone=` from the menu or a
  profile goes into MSBATCH as on 98 SE and `w9x_release_time_zone` drops nothing for Me.
* **Unchanged**: Patcher9x `-select all`, vmdisp9x VESA (`NoMemTest`), MSBATCH `UpdateInis` memory limits
  (MaxPhysPage / MaxFileCache, Me has no U9FIX run), xhci98 stays 98 SE + opt-in.
* **MSDOS.SYS on Me**: INSTALL.BAT cannot write it (Me's Setup writes its own in the VM), so
  `w9x_phase1_patch_c` adds `Logo=0` under `[Options]` after phase 1 when the file has no `Logo=` line
  (in place, the hidden/system/read-only bits stay; checked on the phase-1 disk under micro-Linux:
  `rhs` before and after). Reason: the same text start as 95/98 (start messages visible for hardware
  reports); it did **not** cure the QEMU hang below. `BootMenu=0` / `BootMenuDefault=1` are not written on Me (no DOS-mode menu entry
  to fall into). CREGFIX.SYS stays in CONFIG.SYS, but Me's IO.SYS most likely ignores `DEVICE=` lines (not
  checked on hardware; Patcher9x's CR patch covers VMM).
* **QEMU smoke (one install, 2026-10-06)**: nested micro-Linux (initramfs-usos + qemu9x.cpio, this branch's
  scripts) wrote a 3 GiB target and ran phase 1 in the inner QEMU (TCG, ACPI off, `/P I`): `RUN_RC=0` after
  1031 s, verify PASS ("phase 1 files present"; `SYSTEM.INI: removed mouse=*vmouse, msmouse.vxd`),
  `INSTALL.LOG`: `SETUP start /IS /IE /NM /P I`; SYSTEM.INI `[boot] drivers=mmsystem.dll usoskey.drv`,
  `MaxPhysPage=40000`, `MaxFileCache=262144`; boot sector `MSWIN4.1`. Then OVMF -> the disk's CSMWrap ESP ->
  Me hardware detection -> OEM wizard: user page (pre-filled USOS, typed on the **USB keyboard** through the
  bridge), licence (Alt+A), **product key page empty although MSBATCH had `ProductKey`** (typed), finish ->
  final setup steps (no time zone step in the list).
  **Not reached: the Me desktop.** At Setup's last restart (after "Konfiguracja systemu") the QEMU guest
  stays in VMM (ring 0, EIP c000afd5..c000b6e3, CR2=000B8000 constant) with a garbled text-mode screen,
  with the logo on and again with `Logo=0` (second phase-2 run from the same phase-1 disk). Not analysed
  (time box): QEMU-only (TCG, `-cpu max`, 2 vCPUs, 2 GiB, std VGA; CSMWrap panics "BIOS proxy
  initialization failed" with 1 vCPU) or real is open. The 2026-09-30 Me desktop on CSMWrap came from the
  native phase 1 without vmdisp9x/Patcher9x defaults of today, so suspects to bisect next: vmdisp9x VESA
  on the first normal start, Patcher9x `-select all` on Me, `-cpu max`.
* **Build / deploy**: test/x470-98se-qemu `B261006-202506-0B914CC3`, Kingston updated (usos-physical-update
  with all four partition GUIDs: PASS 5/5, initramfs-usos SHA-256 1367BF96... read back; XP package
  `--data M:/` + `-DriversOnly -Language pl`: HASH_READBACK=PASS, layout unchanged).
* **X470 run** (manual): copy the Me ISO to DATA `Systems\Windows\Windows Me\Images`, UEFI menu -> Windows
  Me -> target disk -> phase 1 in the VM (about 17 min under TCG in the nested test) -> restart into the
  disk's CSMWrap entry -> detection -> OEM wizard on the USB keyboard (user page, licence Alt+A, product key
  typed, finish) -> last restart: report whether the desktop appears or the start stops like in QEMU
  (with `Logo=0` the last text line is visible). No USB mouse on Me yet.

## 4h. Windows 95 OSR2.1 through the same UEFI flow (2026-10-06)

Audit of the CSMWrap path for `windows-95` (tag `95`, Setup folder `WIN95`), media: the user's
`Windows_95_PL_OSR2.1.iso` (4.00.1111, OEM, `ProductType=9`) in DATA `Systems\Windows\Windows 95\Images`
and the 95 OSR2 startup disk as `Systems\Windows\Windows 95\Boot\BOOTDISK.IMG` (bridge, section 2).

* **Phase 1 in the VM** (new): `w9x_vm_available` takes `95`, but `w9x_csmwrap_prepare.sh` keeps the
  native start when the answer has no 95 key (`ProductID`). Reason, from the CD's SUWIN.EXE / SETUPX.DLL:
  * the **licence page** is skipped by Setup's own `/IW` switch (SUWIN looks for `/IW` on its command
    line before it shows LICENSE.TXT; the DOS stage ignores unknown switches). INSTALL.BAT: `SETUP
    MSBATCH.INF /IS /IW` for 95, native and VM (95 has no `ShowEula`, and no ACPI: no `/P I`);
  * the **COA page** (three fields, 5 + 7 + 5 digits, the "-OEM-" part fixed) cannot be answered from
    MSBATCH.INF on an OEM CD: SUWIN reads `[Setup] ProductID` into its PID block, but for ProductType 9
    SETUPX's PID builder (export 600) only copies the CD's UPI, so the page always comes (the 2026-09-30
    finding). The validator (export 601) wants `ddddd-OEM-ddddddd-ddddd` (day 001-366, year 95-99/00-02,
    the 7-digit block starts with 0, its digit sum divisible by 7). Changing `ProductType` would skip the
    page, but that bypasses the key check: not done.
  * So `w9x_phase1_run` types the key: `w9x_vm_key_digits` takes `ProductID` from the answer (OEM: 17
    digits, retail `ddd-ddddddd`: 10 digits, untested); when the guest writes nothing for 60 s, shows a
    graphics screen (640x480; DOS text mode dumps as 720x400) and has written less than 64 MB, the digits
    and Enter go to a **second QEMU monitor** whose output is discarded (the fields move on at 5 / 7
    digits, Enter = Next). At most 5 attempts (the smoke run used 3: the pages before, on and after the COA page); with a key, 30 min without a disk write ends the VM (rc 3).
    The key never reaches a log: `prepare.log` / `command.txt` show only its length and the attempt time,
    no screendump is taken while the typed page may still be on screen.
* **Memory**: Patcher9x 0.9.91 covers 95 (TLB, CPU speed for NTKERN/IOS/ESDI_506/SCSIPORT/NDIS, the memory
  patch "fix missing parts ... for W95", CR registers, 4G resource); `-select all` on `WIN95` as for 98. No
  extra CPU-speed fix needed (FIX95CPU would be patched Microsoft files anyway). U9FIX **`/95`** (AUTOEXEC.BAT
  for 95, native and CSMWrap): `MaxPhysPage=1E000` (480 MiB) when missing and in place of USOS's own `40000`
  (MSBATCH UpdateInis writes 40000 for every 9x); any other value stays. `MaxFileCache=262144` unchanged.
* **USB input**: USOSKEY v4 (95 boots real-mode IO.SYS, so the TSR path applies, as on 98) and now
  `USOSMOUS.DRV` for 95 too (INSTALL.BAT `MOUSEOK`; same Win 4.x 16-bit mouse.drv interface). Untested on 95.
* **TZFIX / time zone**: 95's SETUPC.INF has the same `RunOnce\Setup` "Strefa czasowa" step
  (`TIMEDATE.CPL,,/f`); TIMEZONE.INF has 52 keys, some renamed: `Central European` -> `Warsaw`, `Central
  Europe` -> `Prague Bratislava`, `China` -> `Beijing`, `SE Asia` -> `Bangkok`, `Arab` -> `Saudi Arabia`
  (same TZI); 12 keys of the menu list are missing (Caucasus, E. Africa, Ekaterinburg, FLE, GTB, Korea,
  Pacific SA, Singapore, Sri Lanka, Vladivostok, W. Australia, Yakutsk: Setup asks). `w9x_release_time_zone` (menu default) and
  `msbatch.timeZoneName95` (profiles) map them; TZFIX runs for 95 with `Warsaw` / `Eastern`.
* **Unchanged / shared**: CREGFIX first in CONFIG.SYS, `Logo=0` / `BootMenu=0` / `BootMenuDefault=1` in
  MSDOS.SYS (SYS from the OSR2 boot disk), FAT32 (OSR2 SYS writes the FAT32 boot sector), vmdisp9x VESA
  (its readme lists 95; minimal build target), `w9x_phase1_patch_c` (mouse= line, second HIMEM).
* **QEMU smoke**: see the run below.

## 5. Open points

* Own Windows 95 boot environment from the CD's CABs (bridge today).
* Own 9x AHCI port driver. xhci98 for 98 SE: built with WDK 7.1 (section 4c); Me untested.
* Windows 98 SE under CSMWrap enumerates no PCI bus although the PCI BIOS answers (section 4c).
* Native USB HID on the X470 (2026-10-06): xhci98 loads and the PCI bus is visible with `/P I`, but HID
  does not work, and once xhci98 owns the controller the USOSKEY bridge dies (no keyboard/mouse in Setup's
  final phase). xhci98/NUSB staging is therefore opt-in: only with `EFI\USOS\win9x\xhci98.flag` (default off).
* Windows 95: the COA page is not filled from MSBATCH.INF (`ProductID`) on OEM CDs; the VM phase 1 types
  the key from the answer (section 4h), a native start needs it typed.
* The BIOS mode page renders the profile for all four systems at once; a
  per-system choice would need the system first (UEFI menu entry for 9x).

## 6. Design note: optional post-install pack `DATA\Addons\Win9x` (not implemented)

The user's add-on folder (DCOM95, Winsock 2 / DUN 1.4, DirectX, IE, KernelEx,
MDAC 2.8, MSLU, VB6/VC6 runtimes, Windows Installer 2.0, WMP, Movie Maker,
NUSB 3.3 PL, ASPI 4.71, the Me real-mode DOS patch, DSClient, RDP client,
.NET 2.0 for 98) was not found on this PC (searched the old tree, Desktop,
Downloads, G:), so this note is from the component list only.

* **Layout:** `DATA\Addons\Win9x\<95|98|ME>\<NN-name>\` with the installer and
  a one-line `USOS.CMD` (the silent command). USOS copies the folder to
  `C:\USOS9X\ADDONS` and a RunOnce chain (one entry per item, reboot where the
  item needs it) runs them after the first logon, in `NN` order.
* **Order and fit:** 95: DCOM95 -> Winsock 2 -> IE 5.5/6 -> DirectX (95: 8.0a
  max) -> Windows Installer 2.0 -> MDAC -> runtimes -> DSClient. 98/98 SE:
  (98 FE: IE 5.x first) -> DirectX 9.0c -> Windows Installer 2.0 -> MDAC 2.8
  -> MSLU -> VB6/VC6 runtimes -> WMP 9 -> DSClient -> RDP client -> .NET 2.0
  -> KernelEx last. Me: IE 6 -> DirectX 9.0c -> the rest as 98; the real-mode
  DOS patch only on request (it edits IO.SYS/COMMAND.COM of Me). NUSB and
  ASPI: 98 SE only (NUSB also feeds a future xhci98 path).
* **Silent switches** (usual, to verify per package in a VM): IExpress `/Q`,
  `/Q:A /R:N`; Windows Installer packages `/q`; InstallShield `-s`; DirectX
  redist `/silent`; KernelEx `/S` (NSIS).
* **Redistribution:** only open-source items may ship with USOS (KernelEx:
  GPL-2.0, with its source). Everything from Microsoft (DCOM95, Winsock 2,
  DUN, DirectX, IE, MDAC, MSLU, VB/VC runtimes, MSI 2.0, WMP, Movie Maker,
  DSClient, RDP, .NET), NUSB (Microsoft binaries), Adaptec ASPI and the Me
  DOS patch (patched Microsoft files) stay **user-supplied**: USOS only runs
  what is in `DATA\Addons`.

Screens: [win9x-modern/](win9x-modern/) (98 SE desktop on SeaBIOS; 98 SE through
the target's CSMWrap ESP with USB keyboard and mouse; 98 FE desktop on SeaBIOS; Me desktop on CSMWrap; the Me, 95 and 98 FE key/licence pages).
