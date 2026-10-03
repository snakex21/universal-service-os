# Windows 2000 SP4 on modern boards (X470): AHCI, ACPI, USB (2026-09-30)

Status: **experimental; QEMU PASS to the first-boot logon, X470 run 1 failed (writes lost, no restart; section 6)**,
branch `feature/win2000-modern`. The X470 run is next (section 6). Earlier
state: [windows-2000-uefi-2026-09-27.md](windows-2000-uefi-2026-09-27.md)
(the paths, the CMA repacks), [research/win2000-ahci.md](research/win2000-ahci.md)
(storage options).

The UEFI profile `w2k-x86-sp4-uefi-csm` (UEFI + firmware CSM, and UEFI
without CSM through CSMWrap) stages these on the target after the
local-source copy (`prepare_xp_ntfs_target.sh`):

| Piece | Solution | Licence | Script |
|---|---|---|---|
| AHCI (X470 `1022:43C8`, no IDE mode) | **AHCINT 1.3.0.0-usos1**: i386 ScsiPort miniport, MODIFIED by USOS (real FLUSH CACHE, FUA, caching mode page), **legacy (non-PnP) mode** | GPL-3.0, bundled; upstream and patched source in `tools/vendor/ahcint/` | `tools/w2k_stage.sh` |
| ACPI (2000's `ACPI.SYS` 5.0.2195, ACPI 1.0b era) | **kept** (Microsoft's rule, ACPI HAL). Fallback for a STOP 0xA5: `acpi-off.txt` in `Systems\Windows\Windows 2000\Unattended` on DATA -> `ACPIEnable = 0` (MPS HAL) | nothing to bundle | `tools/w2k_stage.sh`, `legacy_xp_staging.sh` |
| USB (xHCI only: CPU `1022:149C`, chipset `43D0`) | **xhci98 1.1.1.0-usos2** x86 (the NT 5.2 build), GUI-mode PnP install, forced USB/HID stack incl. `usbhub20.sys`; skipped on media without `usbport.sys` (2000 RTM) | GPL-2.0-only, bundled (already in the 1.1 package) | `tools/nt52_usb_stage.sh` (2000 mode) |
| Display | VGA/VESA (inbox) | | |
| Answer file | the existing `w2k_selected_partition_uefi_csm.sif` (`\WINNT`, `ProductID`) | | unchanged |
| Sources | Professional SP4, and Server / Advanced Server at any service pack (`CDROM_IS.5` / `CDROM_IA.5`) | | `probe_nt5_source.sh` |

The BIOS path (`nt5-staging`) is unchanged: the BIOS micro-Linux carries no
driver package, and the old boards it was tested on (MS-7100) have IDE and a
working ACPI. On the X470 use the UEFI entries (with or without CSM).

## 1. AHCI: AHCINT

**Since 2026-10-03** the package carries **1.3.0.0-usos1**
(`tools/vendor/ahcint/1.3.0.0-usos1`, MODIFIED.txt): SYNCHRONIZE CACHE,
SRB_FUNCTION_FLUSH and SHUTDOWN send FLUSH CACHE (EXT) to the drive, FUA
writes are followed by a flush, MODE SENSE returns the caching page. Built
with WDK 7.1 (`build.cmd`, x86 WXP target); its 12 imports (ntoskrnl incl.
`memset`, scsiport) all resolve on the 2000 SP4 kernel and scsiport. AHCINT
runs in **legacy mode**: staging comments out ahcint.inf's `PnpInterface`
row and does not write it (the `usosw2k.inf` bullet below describes the
2026-09-30 PnP variant, still available as `USOS_W2K_AHCINT_MODE=pnp`).

Candidates (details in [research/win2000-ahci.md](research/win2000-ahci.md)):

| Driver | Licence | 2000 | AMD 43C8/7901 | Interrupts | Verdict |
|---|---|---|---|---|---|
| **AHCINT 1.3.0.0** (ages2001, 2026-09-29) | GPL-3.0 (repository LICENSE; no per-file notices) | yes, explicit (`bin\2KXP`) | yes, by class `01-06-01` and by ID in RAID class (`AhciPciConfigIsAhci`) | **none**: "Fast Polling" (`PxIE` = 0), so no IRQ routing is needed, which matters with ACPI off | **bundled** |
| UniATA 0.47b (Alter, 2021-10-16 build) | GPLv2 (source headers; BSD parts from FreeBSD) | yes | generic AHCI for unlisted IDs | interrupt driven | fallback, not bundled |
| GenAHCI on StorPort | GPL-3.0 | no: 2000 has no StorPort, the Win7 StorPort needs ~24 kernel functions 2000 lacks | | | no |
| AMD/Intel vendor, BWC Extended Kernel | proprietary / modified Microsoft files | | | | no (policy) |

Import check (forwarders followed, `tools/tests/check_nt52_driver_imports.py`
method) against the W2KPLCMA4.811 SP4 kernel (`ntkrnlmp.exe`,
`ntoskrnl.exe`), HALs (`halmps.dll`, `halmacpi.dll`, `hal.dll`) and
`scsiport.sys`: `ahcint.sys` 11 imports, `uniata.sys` 76, `xhci98.sys`
(usos2 x86) 25: **0 missing** on every kernel/HAL pair.

Integration (`tools/w2k_stage.sh usos_w2k_apply`), the NT 5.2 GenAHCI
pattern with the 2000 differences:

- `ahcint.sys` in `$WIN_NT$.~BT` (SETUPLDR loads it) and `~LS\I386`, a
  second copy in `~LS\I386\AHCINT` (text mode *moves* the first one);
- `ahcint.inf` with `[SourceDisksNames]` and `[SourceDisksNames.x86]` row 1
  = `\i386\ahcint`, and TXTSETUP puts it in `%windir%\inf` (dirid 20):
  GUI-mode PnP keeps AHCINT on the boot controller (the XP x64 lesson: no
  INF, NULL driver, silent STOP 0x7B after Setup);
- TXTSETUP.SIF (all three copies): `[SourceDisksFiles]`, `[SCSI.Load]`,
  `[SCSI]`, `[HardwareIdsDatabase]` for `PCI\CC_010601` **and**
  `PCI\VEN_1022&DEV_7901/43C8/43EB` (text mode writes the
  CriticalDeviceDatabase entries of the boot controller from these);
- `usosw2k.inf` (ASCII, generated), added to TXTSETUP `[HiveInfs.Fresh]`
  and `[SourceDisksFiles]`: text mode writes `Services\ahcint\Parameters\
  PnpInterface "5" = 1` (the INF's value) and the CriticalDeviceDatabase
  rows into the new system. Without PnpInterface the first boots ran AHCINT
  as a legacy miniport and GUI-mode PnP then started a second instance on
  the same HBA. `HIVESYS.INF` itself is UTF-16 on 2000 and stays as is;
- DOSNET.INF lists the three files.

## 2. ACPI: kept, MPS HAL as the 0xA5 fallback

- 2000's `ACPI.SYS` is from the ACPI 1.0b era, older than the 5.1/5.2
  drivers that stop with STOP 0xA5 (0x11, 0x8, ...) on the X470's iASL
  2012 tables. There is **no ACPI 2.0 driver for NT 5.0**: the MSFN attempts
  (BlackWingCat's modded 2000 ACPI, XP drivers on 2000) did not work
  (msfn.org topic 184174, 2022-2023).
- The XP community ACPI builds in the vendored integrator tree (5048, 6666,
  7777.8, the default one) all miss the same kernel functions on 2000:
  `InterlockedPopEntrySList`, `InterlockedPushEntrySList`,
  `HeadlessDispatch`, `ExfInterlockedCompareExchange64` (plus the WMILIB
  pair where 2000's `wmilib.sys` was not checked). A shim for these four is
  small, but it would mean redirecting the import table of a
  Microsoft-derived binary, and the XP ACPI driver's private interface with
  the 2000 HAL is unknown. Not done (policy: own implementation or
  maintainer decision).
- **What USOS does (since 2026-10-03):** `ACPIEnable` stays Microsoft's
  value (2, the 1999 BIOS-date rule), so Setup picks an ACPI HAL. In QEMU
  that is the only setting with which GUI Setup completes (section 5).
- **Fallback for the X470 if 2000 stops with 0xA5:** put an empty file
  `acpi-off.txt` into `Systems\Windows\Windows 2000\Unattended` on DATA and
  prepare again. `legacy_xp_staging.sh` then sets `USOS_W2K_ACPI=off` and
  `w2k_stage.sh` writes `ACPIEnable = 0`: SETUPLDR never picks an ACPI HAL;
  NTDETECT finds the MP table and Setup installs "MPS Multiprocessor PC"
  (`halmps.dll`, I/O APIC, 2 CPUs on Professional), without MP table
  "Standard PC" (PIC, one CPU). In QEMU this variant failed in GUI Setup
  (section 5), so it is untested ground on hardware.
- **Where the MP table comes from on the X470:** without CSM, **CSMWrap
  builds one** from the ACPI MADT and the `_PRT` of every PCI root bridge
  and bridge with its own `_PRT` (`csmwrap/src/mptable.c`, uACPI), and a
  `$PIR` table (`pir.c`). With the firmware CSM it depends on AMI's CSM
  (unknown; the X470 run shows it).
- Costs: no ACPI power-off ("It is now safe to turn off your computer"), no
  power button, no sleep. AHCINT needs no interrupt at all; xhci98 needs its
  INTx pin routed through the MP table (section 6).

## 3. USB: xhci98 on 2000

- Upstream xhci98 lists Windows 2000 SP4 as supported (VM-tested only,
  including SMP and Driver Verifier), with the Win2000 DDK; the usos2
  patches (AMD CPU xHCI start, 16 protocol groups) do not change imports.
- 2000 SP4 has `usbport.sys`, `usbd.sys`, `usbhub.sys` and `usbhub20.sys`
  (the USB 2.0 root hub, which xhci98's `USB\ROOT_HUB20` needs), all with
  the "do not copy" text-mode disposition. `nt52_usb_stage.sh` forces them
  (`,4,0,0`) as for NT 5.2, plus `usbhub20.sys`.
- **No text-mode load on 2000** (differs from NT 5.2): 2000's text mode runs
  the old `openhci`/`uhcd` stack, its boot folder has no `usbport.sys`, and
  text mode needs no keys. So no `[HardwareIdsDatabase]`,
  `[InputDevicesSupport(.Load)]` or `[files.xhci98]` rows; GUI-mode PnP
  installs the controller from `%windir%\inf\xhci98.inf` (file from
  `~LS\I386\XHCI98`) in "Installing devices", before the pages that take
  input.

## 4. What else was checked

- The NT 5.2 and XP outputs of the shared scripts are unchanged
  (`test_nt52_staging.py`; the 2000 mode is a parameter of
  `usos_nt52_usb_sif`).
- Host tests: `tools/tests/test_w2k_staging.py` (rows, ACPI switch, INF
  path, DOSNET, apply with ACPI off/on, refusals, pinned package files,
  2000 USB mode).

## 5. QEMU (2026-09-30 .. 2026-10-03)

### Final configuration (2026-10-03): PASS to the first-boot logon

AHCINT 1.3.0.0-usos1 in legacy mode, ACPI kept, xhci98, target on
`ich9-ahci`, `qemu-xhci` + `usb-kbd`/`usb-tablet` only, disk cache
writethrough (`USOS_QEMU_DISK_CACHE`).

| Run | Result |
|---|---|
| Pro SP4, SeaBIOS (firmware-CSM stand-in), 2 CPUs | **PASS**: text mode, GUI Setup (device install, components, final tasks), automatic restart, **first boot to the logon screen**. The repack asks for no key. Keys typed only through the USB keyboard reach the logon password field (xhci98 -> usbport -> usbhub20 -> HID). Offline: HAL `halmacpi.dll`, `PCI\VEN_8086&DEV_2922` bound to `AHCINT` (SCSIAdapter), CriticalDeviceDatabase `pci#cc_010601` / AMD IDs -> ahcint, `setuperr.log` empty, no `edb*.log` flood, `xhci98.log` with two driver loads (GUI Setup and first boot) |
| Pro SP4, mid-GUI reboot (copy of the disk during "Final tasks", booted alone on AHCI) | **PASS**: boots from AHCINT, no 0x7B, GUI Setup resumes (network, components) |
| Pro SP4, OVMF without CSM -> CSMWrap | **PASS**: the same, to the logon screen with USB typing; HAL `halaacpi.dll` (one CPU: CSMWrap keeps a helper core), AHCINT bound, no log flood |
| Server 2000 RTM, SeaBIOS (xhci98 skipped: RTM has no `usbport.sys`) | **PASS** to the licensing page (needs keys; no USB on RTM). Mid-GUI reboot: GUI Setup resumes, read-only chkdsk of the disk finds no problems (the earlier `$MFT` damage came from killing a VM whose driver never flushed, before writethrough and usos1) |
| Pro SP4, IDE (atapi), ACPI kept | **PASS** to the logon screen, HAL `halmacpi.dll` |

What decided it (A/B runs on the same prepared source):

- **ACPI off (MPS HAL) is what broke GUI Setup in QEMU.** Every ACPI-off
  run failed: on AHCI with AHCINT 1.3.0.0 and usos1, PnP and legacy mode,
  with and without xhci98, the GUI-mode device install hit
  `ERROR_NO_SYSTEM_RESOURCES` (1450) and the security configuration engine
  then wrote more than 10,000 ESENT logs (`%windir%\security\edb*.log`)
  until the disk was full ("initializing the security subsystem failed");
  on IDE it restarted and hung. The same sources with ACPI kept pass on IDE
  and on AHCI. ESENT's flood is a consequence (SCE `error 1208` after the
  resource errors), not a storage request AHCINT fails: no SRB/IOCTL error
  was involved, and AHCINT answers MODE SENSE, READ CAPACITY and the
  read/write/flush commands disk.sys sends.
- **AHCINT in PnP mode** (ahcint.inf's `PnpInterface`) hung at the first GUI
  boot with ACPI kept (1.3.0.0); legacy mode passes. Staging therefore
  comments the row out by default (`USOS_W2K_AHCINT_MODE=pnp` restores it).
- **usos1's flushes** were not the cause of the flood, but they are kept:
  1.3.0.0 never flushed the drive's write cache, which loses data on a
  power-off after shutdown and left killed QEMU images corrupt.
- **UniATA 0.47b** as a drop-in under the AHCINT service name stops with
  0x7B at the first boot (it is a legacy miniport with its own INF and
  registry layout); a proper integration was not needed and was not done.
  It stays the documented alternative.
- VirtualBox 7.2 does not run the 2000 MPS HAL here (hangs in phase 1).

### First round (2026-09-30)

TCG, SeaBIOS (the firmware-CSM stand-in) and OVMF without CSM -> CSMWrap,
target on `ich9-ahci`, `qemu-xhci` + `usb-kbd`/`usb-tablet` only (`--ahci
--usb-only`), usos-xp.ini with a user and no key. Sources: W2KPLCMA4.811
(Pro SP4 repack) and Windows 2000 Server PL Standard (RTM 5.00.2195.1).

| Run | Text mode | GUI Setup | Result |
|---|---|---|---|
| Pro, SeaBIOS, AHCI, ACPI off | PASS (AHCINT loads, copy, restart) | device install: AHCINT on `PCI\VEN_8086&DEV_2922`, xhci98 + USB 2.0 root hub + HID keyboard/mouse "finished successfully" (setupapi.log); HAL `halapic.dll` (MPS, 1 CPU) | **FAIL** late in "Installing devices": "Critical error: initializing the security subsystem failed" |
| Pro, CSMWrap, AHCI, ACPI off | PASS (CSMWrap, second boot) | as above | **FAIL**, same error |
| Pro, SeaBIOS, AHCI, ACPI off, without xhci98 staging | PASS | as above, without USB | **FAIL**: the same disk-full state (below) |
| Pro, SeaBIOS, IDE (AHCINT staged, not bound), ACPI off | PASS | device install to about 75 %, then a restart; clean volume, no log flood | FAIL (GUI restarts, then hangs at the splash) |
| Pro, SeaBIOS, AHCI, ACPI on (`ACPIEnable = 2`) | PASS | hangs at the first GUI boot splash | FAIL |
| Server RTM, SeaBIOS, AHCI, ACPI off (xhci98 skipped: no usbport) | PASS | **PASS** to the licensing page | a hard reset and reboot mid-GUI returns to GUI Setup (no 0x7B: AHCINT stays bound), but reports a damaged `$MFT` |
| VirtualBox 7.2, AHCI or PIIX, ACPI off (MPS HAL + IOAPIC) | PASS | hangs in kernel phase 1 | VirtualBox does not run the MPS HAL here |

These runs used AHCINT 1.3.0.0, PnP mode and ACPI off; the cause and the
fix are above.

The ACPI-on and VirtualBox rows also show that QEMU/VirtualBox are weak
witnesses for the 2000 HAL question; the X470 decides that.

Harness additions: `USOS_QEMU_DISK_CACHE=writethrough` (a killed VM leaves a
consistent qcow2 even when the guest driver never flushes), `--smp`,
`USOS_QEMU_EXTRA`.

**XP Media Center Edition 2005 SP3** (one combined disc; markers WIN51,
WIN51IP, WIN51IP.SP3; `cmpnents\mediactr`, `cmpnents\netfx`): accepted by
the XP source probe. BIOS path in QEMU needed two fixes in
`prepare_xp_local_source.sh`: storage drivers from TXTSETUP `[SCSI.Load]`
that DOSNET.INF does not list are staged to `~BT` (`iaStor.sys`: "The file
iaStor.sys could not be found"), and quoted DOSNET destinations are unquoted
(nLite-style `"system32\smss.exe"`: STOP 0x6B C000003A). Then text-mode copy
and GUI Setup (welcome page). The XP x86 SP3 target digest is unchanged.

## 6. X470 run 1 (2026-10-03, B261003-180320, CSM off) and the usos2 diagnostics

**What the user saw:** USOS prepared the BIOSTAR S100 (chipset SATA
connector 3 = AHCI port 2 of `1022:43C8`; the DVD drive sits on port 0),
restart, Windows 2000 text-mode Setup copied files, then a black screen with
a blinking cursor; no visible restart, nothing for 15 minutes.

**What the disks show (read-only on the dev PC):**

- BIOSTAR: exactly as prepared. USOS MBR and NT52 boot sector unchanged,
  `$WIN_NT$.~LS\I386` complete (5,455 files), no `WINNT`, no `BOOT.INI`, no
  file newer than the preparation, NTFS not dirty. **No write of text-mode
  Setup reached the disk**, not even NTFS's own journal.
- Kingston (USOS stick): no Windows files, only USOS's own logs. Not
  touched by Setup.

**Two separate problems:**

1. **Writes disappear.** Text mode read the local source through AHCINT
   (it copied), but nothing it wrote is on the disk, and AHCINT reported
   success. Cause unknown; QEMU's AHCI never shows it.
2. **The restart at the end of text mode does nothing.** Linux on the same
   boot reports `i8042: PNP: No PS/2 controller found`: with CSM off the
   firmware exposes no keyboard controller. Windows 2000's HAL restarts the
   machine through the keyboard controller (port 64h, FEh) only, so the
   machine sits at a black screen. XP and Server 2003 restarted fine on this
   board via CSMWrap; their HALs presumably also use the FADT reset register
   (unconfirmed). With CSM on, AMI's CSM emulates the controller.

**usos2 diagnostics and options (this branch):**

- AHCINT **1.3.0.0-usos2**: link and command-engine checks before every
  command (fail instead of issuing into a stopped engine); counters
  (reads, writes, sectors, errors, PRD byte-count mismatches, engine
  restarts, flushes); and the **USOS gap**: USOS writes a marker at LBA 2046
  of the prepared disk (`USOSW2KTRACE`, disk signature). At every start the
  driver writes and reads back a test sector at LBA 2045 (**a mismatch hides
  the disk: Setup says it found no hard disk instead of copying into
  nothing**), increments the boot counter in the marker, and writes an ASCII
  trace (counters, every port's SSTS/CMD/SIG/TFD and model) to LBA
  2040-2043, again every 2048 writes and on every flush. Other disks are
  only read at LBA 2046. QEMU: verify PASS, boot counter and records as
  expected, install unchanged.
- Read it on the dev PC, read-only: `python tools\w2k_gap_trace.py \\.\PhysicalDriveN`
  (or a `.qcow2`). Boot counter still 0 = the driver's writes never reached
  the disk; records with growing `wr` = writes arrive.
- `storage-uniata.txt` in `Systems\Windows\Windows 2000\Unattended` on DATA:
  UniATA 0.47b instead of AHCINT (USOS-written `uniata.inf`, service
  `uniata`, PciIde/atapi off). **In QEMU it stops with 0x7B at the first GUI
  boot** (text mode passes); not ready, kept for diagnosis only.
- AMD's own XP AHCI driver (`amd_sata.sys` 1.2.001.0337 in the XP integrator
  tree) is a StorPort miniport, and 2000 has no StorPort: not an option. XP
  x86 used GenAHCI on the StorPort backport, which also does not load on
  2000 (section 1).
- `csmwrap-verbose.flag` (empty file in `EFI\USOS` on the stick, existing
  mechanism) puts CSMWrap's and SeaBIOS's messages on screen for the next
  prepared target: shows whether a restart reaches CSMWrap and which disk
  SeaBIOS boots.

**Next X470 run (after deploying a build with usos2):**

1. Prepare the BIOSTAR again (CSM off; DVD drive unplugged if possible).
2. If text mode says it found no hard disk: the write test failed, which is
   the answer to problem 1. Bring the disk to the dev PC for the trace.
3. If it copies and then shows the black screen: wait about 1 minute
   (periodic traces), then **press the reset button** (2000 cannot restart
   the board itself without CSM). GUI Setup should start if the writes
   arrived; either way bring the disk for the trace.
4. Then the same with CSM on (the firmware's keyboard controller makes the
   2000 restart work).

## 7. X470 test plan (first plan, 2026-10-03)


Windows 2000 SP4 Professional, target on the chipset SATA (`1022:43C8`),
first UEFI without CSM (CSMWrap), then with CSM. Expect: text mode (AHCINT),
GUI Setup with USB keyboard and mouse on the chipset (`43D0`) and CPU
(`149C`) rear ports, no 0x7B after Setup, `%windir%\xhci98.log`.

- **If text mode or the first GUI boot stops with STOP 0xA5** (2000's ACPI
  driver and the X470 tables): put an empty `acpi-off.txt` into
  `Systems\Windows\Windows 2000\Unattended` on DATA and prepare again (MPS
  HAL, section 2). Then also note the CPU count and whether power-off
  works (it will not without ACPI).
- Note the HAL (`%windir%\system32\hal.dll` version info or the Device
  Manager "Computer" entry), which rear ports work, and the result of a
  normal shutdown.

Windows 2000 Server: the probe now accepts Server/Advanced Server
(`CDROM_IS.5`/`CDROM_IA.5`, ProductType 1) at any service pack; SP4 stays
required for Professional. RTM media have no `usbport.sys`, so xhci98 is
skipped there (no USB input on xHCI-only boards).

## Sources

- AHCINT: <https://github.com/ages2001/AHCINT> (tag `v1.3.0.0`, README
  "Fast Polling", `src/ahcimain.c`)
- UniATA: <http://alter.org.ua/soft/win/uni_ata/> (0.47b, `BusMaster_v47b.rar`
  and `_src.rar`, 2021-10-16)
- xhci98: <https://github.com/yeokm1/xhci98> (README: supported systems,
  Windows 2000 SP4)
- MSFN: "Who can patch acpi.sys for windows 2000 binary to run the ACPI
  v2.0 driver?" (topic 184174)
- CSMWrap 3.1.2 source (`tools/vendor/csmwrap/3.1.2-src`): `src/mptable.c`,
  `src/pir.c`
