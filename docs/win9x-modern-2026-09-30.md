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
| 95 (non-bootable CD) | `Systems\Windows\Windows 95\Boot\BOOTDISK.IMG`: any 1.44 MB DOS 7.x startup disk (the user's 95 OSR2 boot disk, or the 98 SE CD's floppy). **Temporary bridge, "do zastąpienia własną implementacją"**: the CD's own CABs hold everything (`PRECOPY1.CAB`: `winboot.sys` = IO.SYS, `command.com`; `WIN95_02.CAB`: `sys.com`, `himem.sys`, `attrib.exe`, `fdisk.exe`); an own implementation needs MSZIP in the Core (no room: 4 KB headroom) or the micro-Linux preparation, plus a clean-room DOS 7 FAT boot sector | the image is user-supplied |
| Answer file | `MSBATCH.INF`: (1) the file chosen from DATA `Unattended\*.inf`, copied 1:1; (2) `\EFI\USOS\answer\<98SE,98,ME,95>.INF` rendered by the UEFI menu from a profile (BIOS mode page: one row per profile offered for 95/98/Me, `stageWin9x`; removed at the next UEFI start); (3) the USOS default `src/platform/bios/win9x/msbatch.inf` (typical, no startup disk, no network components, `NoPrompt2Boot`, `DevicePath=1`, Welcome/Regwiz off). Renderer: `src/flow/answer/msbatch.zig` (owner, org, computer, 9x time zone key, `ProductKey` for 98/Me; 95 uses `ProductID`, not rendered). Profile group `windows-9x`; `windows` now includes 9x | USOS |
| RAM | Patcher9x 0.9.91 `-select all` on the Setup folder (TLB for Zen, CPU speed for 95/98 FE, R. Loew memory patch, dirty CR registers, 4G resource), plus **U9FIX.COM** (own, 1 KB, `src/platform/bios/win9x/u9fix.S`) run from `AUTOEXEC.BAT` before every start: adds `[386Enh] MaxPhysPage=40000` (1 GiB) and `[vcache] MaxFileCache=262144` when missing, keeps user values | Patcher9x MIT (memory part: Loew, status as in the feasibility study); U9FIX GPL-3.0-or-later |
| Fast CPU (95, 98 FE) | Patcher9x's own `speed` patch (NTKERN, IOS, ESDI_506, SCSIPORT, NDIS: 80x loop + divide-by-zero guard) on the install media. FIX95CPU is **not** needed (and contains patched Microsoft VxDs, not bundleable) | MIT |
| Storage | No 9x AHCI driver is bundleable (R. Loew AHCI.PDR: no licence stated by the heirs; SweetLow patches are patched binaries). 9x uses **MS-DOS compatibility mode** (INT 13h) on AHCI: under plain SeaBIOS and under CSMWrap it installs and runs (QEMU), slower than native. Own clean-room IOS port driver (.PDR) = future work | - |
| Display | **vmdisp9x 1.2025.0.119** (JHRobotics, MIT) VESA driver (`vesamini.drv/.vxd` + VMHal9x) in `C:\<folder>` with USOS's `USOSVESA.INF` (VESA model only); `U9FIX /VGA` adds the PCI IDs of this PC's display controllers (hardware ID outranks Standard VGA's `PCI\CC_0300`). VBEMP 9x is **not** bundleable (non-commercial, "not bundled without permission") | MIT (vendored, `tools/vendor/vmdisp9x`) |
| USB input under CSMWrap | Win9x GUI sees no USB keyboard/mouse (no 8042 emulation in CSMWrap/SeaBIOS). The Windows 3.x bridge works unchanged in 98: `USOSKEY.COM` + `USOSKEY.DRV` (`drivers=`) and VBADOS `VBMOUSE.EXE` + `VBMOUSE.DRV` (`mouse.drv=`); `U9FIX /CSM` adds both to `[boot]`, `AUTOEXEC.BAT` copies the drivers after Setup's first restart. Only with CSMWrap (real BIOS: SMM emulation / PS/2) | USOS GPL-3.0; VBADOS GPL-2.0+ |
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
| Me PL OEM (4.90.3000) | phase 1 -> phase 2 (logo off by the test helper) -> key page | not run |
| 95 OSR2.1 PL + 95 OSR2 boot disk (bridge) | Setup -> licence -> key page (COA; Setup stops, no key given) | not run |
| 95 OSR2.1 PL + the 98 SE floppy | same, key page | not run |
| 98 FE PL | install -> phase 2 -> key page (the CD's `WIN98\CHANNELS` subfolder is skipped) | not run |

No product keys were given for Me, 95 or 98 FE, so those runs end at the
key page (as agreed). USB keyboard in the USOS BIOS menu and in DOS worked in
all CSMWrap runs (SeaBIOS INT 16h). VESA driver: prepared (INF + IDs,
unit-tested), not yet seen on a desktop (the desktop run predates it).

## 4. X470 test plan (CSM off, Secure Boot off, spare SATA disk, PS/2 keyboard at hand)

1. 98 SE via BIOS mode with a profile holding the user's key (`systems=windows-9x`,
   `remember_key=yes` or typed): install, remove the stick at the first restart,
   the disk boots through its ESP; check USB keyboard/mouse in Setup's wizard and
   on the desktop, `C:\WINDOWS\SYSTEM.INI` (MaxPhysPage, usoskey.drv, vbmouse.drv),
   System Properties RAM (1 GB), display (vmdisp9x VESA modes on the RX 560),
   Device Manager (disks in compatibility mode).
2. If PnP detection hangs: repeat with `/P I` added to the SETUP line of
   `EFI\USOS\dos-native\ram-patch\INSTALL.BAT` on the stick ESP (no ACPI).
3. Me the same way; 95 OSR2.1 with `Boot\BOOTDISK.IMG`.
4. Regression: MS-DOS / Windows 3.1 install under CSMWrap still boots.

## 5. Open points

* Own Windows 95 boot environment from the CD's CABs (bridge today).
* Own 9x AHCI port driver; xhci98 for 98/Me needs a legitimate MSVC 6 / 2000 DDK toolchain.
* Windows 95 `ProductID` from profiles (format differs from the 5x5 key).
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
the target's CSMWrap ESP with USB keyboard and mouse; the Me, 95 and 98 FE key pages).
