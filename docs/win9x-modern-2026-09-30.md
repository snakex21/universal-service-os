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

## 5. Open points

* Own Windows 95 boot environment from the CD's CABs (bridge today).
* Own 9x AHCI port driver; xhci98 for 98/Me needs a legitimate MSVC 6 / 2000 DDK toolchain.
* Windows 95: the COA page is not filled from MSBATCH.INF (`ProductID`), the key is typed.
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
