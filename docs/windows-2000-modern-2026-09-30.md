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
| USB (xHCI only: CPU `1022:149C`, chipset `43D0`) | **xhci98 1.1.1.0-usos3** x86 (the NT 5.2 build; polls under the MPS HAL), GUI-mode PnP install, forced USB/HID stack incl. `usbhub20.sys`; skipped on media without `usbport.sys` (2000 RTM) | GPL-2.0-only, bundled (already in the 1.1 package) | `tools/nt52_usb_stage.sh` (2000 mode) |
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
  2040-2043, again every 2048 writes and at shutdown. Other disks are
  only read at LBA 2046. QEMU (2026-10-04, SeaBIOS, AHCI, 2 CPUs): verify
  PASS, three boots counted, records with growing counters, **install to the
  logon screen unchanged**.
- **Open QEMU issue:** the same run with **one CPU** (ACPI uniprocessor HAL)
  stalls in "Installing devices" while the disk fills (25 million sectors
  written in the GUI boot, the ESENT log flood of section 5). The usos1
  CSMWrap run with one CPU passed, so this is not deterministic; it needs
  its own investigation. The X470 runs 2000 with 2 CPUs (ACPI or MPS HAL).
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

## 7. X470 run 2 (2026-10-03, B261003-232921) and the usos3 diagnostic build

**Run 2 (usos2, CSM off):** text mode showed "Instalator kopiuje pliki…" with
its progress bar, then went **straight to a black screen with a blinking
cursor**, with no "Saving configuration" step and no 15-second restart
countdown. The user waited about 15 minutes before switching off. The
BIOSTAR, read read-only on the dev PC, had no `WINNT`, no `BOOT.INI` and an
unchanged VBR. The usos2 marker still had **boot counter 0**, and there was
no test sector and no trace.

Reading of the evidence:
- **AHCINT is the only driver that can serve that disk in text mode.** It
  is one instance: one `ScsiPortInitialize` call, and a global claimed-device
  table, so the same function is never claimed twice. Legacy mode has no
  `PnpInterface` row, so there is no legacy+PnP double. atapi/pciide only
  drive IDE class 0101, not an AHCI controller with ABAR only. INT13 through
  CSMWrap/SeaBIOS is used only by SETUPLDR, the loader screen before the
  kernel; USB storage does not exist in 2000 text mode.
- The usos2 probe **returned silently** when the marker read failed or did
  not match, so it may never have run its write test. A boot counter of 0
  does not show what happened.
- Text mode **did not reach its end screens**, and a black text screen with
  a cursor is what a 2000 STOP leaves on this board. The bootvid STOP screen
  does not appear without CSM. So the most likely event is **a STOP during
  or right after the copy, never shown**. A 15-minute wait also rules out
  lost write-cache data.
- Text-mode Setup restarts through `HalReturnToFirmware` directly (setupdd
  imports it, not `NtShutdownSystem`), so shutdown notifications never run
  there.

**AHCINT 1.3.0.0-usos3** (diagnostic build, `MODIFIED.txt`, patch 0003):
- A **status line in the VGA text buffer**, row 0 (a second HBA uses row 1):

  `AHCINT3 1022:43C8 p2 MK:OK T:OK R:0001A2F3 W:00003F10 E:0000 LW:00A1B2C3 S:0F`

  | Field | Meaning |
  |---|---|
  | `1022:43C8` | the HBA's PCI ID |
  | `p2` | the USOS disk's port |
  | `MK` | marker: `OK`; `NO` = read, but no marker; `RE` = read error; `--` = no disk |
  | `T` | write/read-back test at 2045: `OK`, `XX`, or `--` (not run) |
  | `R` / `W` | completed reads / writes |
  | `E` | errors |
  | `LW` | last written LBA |
  | `S` | stages: `01` = LBA 0 written, `02` = LBA 2048 written, `04` = first flush, `08` = shutdown, `10` = read-back mismatch, `20` / `40` = write / read error, `80` = STOP |

  Blue means normal; red means errors, a failed test or a STOP. **R rising
  during the copy shows that AHCINT serves the disk.**
- **Sampled read-back** on the USOS disk: the first sector of the first 256
  writes, then of every 32nd, is read back and compared.
- **Fail loudly** with STOP `0x55534F53` ("USOS") instead of carrying on:

  | P1 | Cause | P4 |
  |---|---|---|
  | 1 | marker read failed after 3 tries | TFD |
  | 2 | write test failed | TFD |
  | 3 | read-back mismatch | LBA |

  P2 is the PCI ID and P3 the port.
- A **bugcheck callback** puts any STOP code on the line and writes it to
  the trace.

**usosrst.sys** (own driver, GPL-3.0-or-later, `tools/w2k/usosrst`):
- It is loaded from `[BootBusExtenders.Load]` in text mode and as a boot
  driver of the first group afterwards. The loader uses ErrorControl 0, so a
  failed start never stops the boot.
- **Load line, row 2.** Example:
  `usosrst 1.0-diag rsdp-rev=02 reset=io:0CF9=06+cf9+8042 setup=0 handler=off` (rsdp-rev FF = no RSDP found).
  It shows the FADT reset register found through the RSDP.
- **STOP screen, rows 3-5.** It shows the STOP code, its parameters, and
  the module plus offset each parameter points into, found by walking the
  loaded-module list from its own entry.
- **Restart.** When `SystemSetupInProgress` = 1 (GUI-mode Setup), a
  last-chance shutdown handler resets through the FADT reset register, then
  CF9h (02h, 06h, then 0Eh), then the 8042. After Setup the handler is not
  registered, so a shutdown stays a power-off. The text-mode restart is not
  covered (see above). Covering it would need a change to Microsoft's HAL,
  which is not done without explicit approval. On the X470 without CSM, the
  end of text mode still needs the reset button.
- Imports: AHCINT 16 (ntoskrnl, scsiport) and usosrst 17 (ntoskrnl, hal).
  All of them resolve on the 2000 SP4 ntoskrnl/ntkrnlmp and on every 2000
  HAL.

**Next X470 run (usos3 build, CSM off):** photograph the top rows during the
copy, and again at the black screen.
- No AHCINT line at all: AHCINT never started, or the screen is not in
  text mode.
- `MK:RE` / `MK:NO` / `T:XX`, or a STOP `0x55534F53`: the cause is on that
  line.
- A STOP line from usosrst: that names the failing driver.
- Then press reset and bring the disk for the trace (`tools\w2k_gap_trace.py`).

**X470 run 3 (2026-10-04, UniATA via `storage-uniata.txt`, CSM off):**
the same result: the copy bar, then a black "_". Read-only checks on the dev
PC:
- UniATA was staged in `~BT` and `~LS`, with no AHCINT; the prepare log says
  `APPLIED PASS UniATA 0.47b`.
- Nothing from Setup is on the disk: no WINNT, and all 5555 `~LS` files are
  still there (text mode moves them).
- The CSMWrap ESP and the Kingston hold only USOS's own files.

So the cause does not depend on the miniport.

**Memory-map check in QEMU (2026-10-04):** text mode completes with
AHCINT usos3, no errors and the VBR written, in all three setups:
- SeaBIOS with 8 GB;
- SeaBIOS with 32 GB;
- CSMWrap on OVMF with 32 GB, using `USOS_QEMU_EXTRA="-m 32G"` (the
  harnesses accept it).

So memory above 4 GB in the E820 alone does not reproduce the X470
failure. No CSMWrap E820 change was made.

## 7a. X470 run 5 (2026-10-04, acpi-off.txt) and the unattended fixes

**X470 (CSM off, CSMWrap, `acpi-off.txt`):** with the ACPI HAL the kernel
hung right after SETUPLDR (black "_"). With ACPI off (MPS HAL) and also
with F5 "Standard PC", text-mode Setup starts: AHCINT usos3 works
(`AHCINT3 1022:43C8 p2 MK:OK T:OK R:000007A8 W:0000000E E:0000`), usosrst
loads (`reset=io:00B2=BE+cf9+8042`). Setup then stops on the "computer
type" confirmation screen: "Klawiatura: Nieznane" (USB-only board, no PS/2
keyboard, so NTDETECT reports none) and the USB keyboard does not work in
text mode.

**Fixes (this branch):**
- WINNT.SIF (`usos_w2k_answer_sif`, written by
  `prepare_xp_windows_partition.sh`): `[KeyboardDrivers]` with the
  source's own `[Keyboard] STANDARD` description = "Retail", and with ACPI
  off `ComputerType` = the source's `mps_mp` description (default) or
  `e_isa_up` ("Standard PC", `hal-standard.txt` on DATA), "Retail".
  Text-mode Setup only honours these in preinstall mode, so
  `OemPreinstall=Yes` is set (no `$OEM$` files are needed for "Retail").
- usosrst 1.1: in text mode it redirects setupdd.sys's
  `HalReturnToFirmware` import (in memory only) to its own reset (FADT
  reset register, CF9h, 8042), so the end-of-text-mode restart works
  without an 8042. Load line: `txt=on`.

**QEMU (OVMF -> CSMWrap, AHCI, USB-only input, ACPI off, 2026-10-04):**
the X470 screen was reproduced by removing the STANDARD rows of
`[Map.Keyboard]` (test only). With `OemPreinstall=No` the screen stayed;
with the fix it is skipped for both MPS and Standard PC, text mode copies,
restarts (`txt=on`) and GUI Setup starts. **GUI Setup still fails with ACPI
off on both HALs**, as in section 5: from the third device on, every
device install fails with 1450 (`ERROR_NO_SYSTEM_RESOURCES`), then
"RegisteredProcessors" cannot be written, ~11,000 `edb*.log` files, "Critical
error: initializing the security subsystem failed". The hives stay small
(SYSTEM 421 KB, 62 device instances), so the registry quota / paged pool
was the suspect.

**Run D (MPS, ACPI off):** usosw2k.inf now writes (ACPI off only)
`Memory Management\PagedPoolSize = 0xFFFFFFFF` (largest the system allows)
and `Control\RegistrySizeLimit = 0x08000000` (clamped by the kernel). Result:
no 1450 at all, `setuperr.log` empty, device install and the security setup
passed, GUI Setup reached "Wykonywanie zadań końcowych" (registering
components). The run was stopped there after ~20 minutes on that step
(TCG); `%windir%\security` held ~10,700 `edb*.log` files, so an ESENT log
flood still happens in QEMU with ACPI off and is the open risk for the
X470. `isapnp` Start = 4 was also tried: text mode overwrites it (Start 0),
and leaving isapnp out of text mode makes text mode stop with "no keyboard",
so it is not used.

## 7b. X470 run 6 (B261004-154947) and the stall diagnostics (usos4, usosrst 1.2)

**Run 6 (CSM off, `acpi-off.txt`, MPS HAL, unattended answers):** text
mode started and the real file copy ran, then stopped at 4 %
("Kopiowanie: c_1252.nls") with no STOP screen. Row 0 stayed at
`AHCINT3 1022:43C8 p2 MK:OK T:OK R:00000D5A W:000000F6 E:0000 LW:06FBA408 S:04`
and did not change afterwards. usos3 refreshed that line only every 64
commands, so the photo could not tell an I/O stall from a whole-machine
hang.

**Working mode from here on:** no speculative fixes; every hardware run
must say what is wrong. This build only adds diagnostics.

**AHCINT 1.3.0.0-usos4** (patch 0004, `MODIFIED.txt`):
- Row 0 is rewritten after every command and by a 250 ms miniport timer.
- A command still polled after 2 s puts the port registers on rows 3-4;
  when it ends or times out (3 s) the same snapshot goes into the trace.
- The trace also gets a record on every ScsiPort bus reset (`busreset`) and
  once after 20 s without a new request (`idle20s`).

**usosrst 1.2** (text-mode Setup only, so a graphics desktop never gets
text-buffer writes):
- A 250 ms kernel timer rewrites row 1 (heartbeat).
- One DPC per CPU, sent with high importance; each CPU's digit moves only
  when that CPU runs DPCs.
- usosrst finds the AHCI HBAs itself through PCI config space and only
  reads their registers and command list. So the watchdog does not depend
  on AHCINT, and it works with UniATA too.
- A slot that stays set with the same command for 2 s goes on rows 3-4.

**Screen rows:**

| Row | Writer | Example |
|---|---|---|
| 0 | AHCINT | `A4 43C8p2 OK/OK R:000D5A W:0000F6 E:00 B:0 LW:06FBA408 S:04 I:000 TM:3A1 ID:00` |
| 1 | usosrst | `HB 0000013A t:000123s S:0 a2 CI:00000000 L:35 06FBA408+0080 age:0037s cpu:3A` |
| 2 | usosrst | `usosrst 1.2 rsdp=02 reset=io:00B2=BE+cf9+8042 setup=0 handler=off txt=on hb1/06` |
| 3-4 | AHCINT (`A4 STALL`) or usosrst (`RS STALL`) | PxCI, PxSACT, PxIS, PxSERR, PxTFD / PxCMD, HBA IS, poll or irq, op, LBA, count, slot |
| 5-7 | usosrst | STOP code, parameters, modules |
| 8 | AHCINT | a second HBA |

**Row 0 fields:**
- `OK/OK`: the marker / the write test.
- `B`: ScsiPort bus resets.
- `I`: HwInterrupt calls. AHCINT polls, so 0 is normal.
- `TM`: miniport timer ticks. ScsiPort cannot run the timer while HwStartIo
  polls.
- `ID`: seconds without a new request.

**Row 1 fields:**
- `HB`: ticks, 4 per second.
- `t`: seconds since boot, from the clock interrupt.
- `S`: stalls seen.
- `a2`: HBA letter and port.
- `CI`: live PxCI.
- `L`: the last command in the command list: opcode, LBA and count.
- `age`: seconds since that command changed.
- `cpu`: one digit per CPU.

**How to read the next photo:**

| Row 1 (HB) | Row 0 (TM / ID) | Rows 3-4 | Meaning |
|---|---|---|---|
| frozen | any | - | The machine (clock, timer DPC, or a CPU at high IRQL) is hung. Not a disk problem. |
| moves, one `cpu` digit frozen | - | - | That CPU no longer runs DPCs: it is stuck at DISPATCH_LEVEL or above. |
| moves, `CI` 0, `age` rising | TM moves, ID rising | empty | The disk is idle and nobody sends I/O: Setup or the I/O stack is waiting on something else. The trace gets `idle20s`. |
| moves | TM frozen | `A4 STALL` | AHCINT is stuck polling a command. The registers show why: TFD BSY = the drive is busy, an IS/SERR error = a link or HBA fault. |
| moves, `CI` non-zero | - | `RS STALL` | A command slot is set for over 2 s, seen from outside the driver. |
| moves | `B` > 0 | - | ScsiPort timed out a request and reset the bus. The trace gets `busreset`. |

`python tools\w2k_gap_trace.py \\.\PhysicalDriveN` decodes the usos4
records: why, counters, the snapshot and the ports.

**QEMU (one short run, before the user's decision of 2026-10-04 to run no
more VMs for Windows 2000):** SeaBIOS, AHCI, 2 vCPUs, WHPX, ACPI off. Rows
0 and 1 rendered and both moved; the text-mode Setup kernel showed one CPU
digit. The file copy completed (W:00313C, TM and HB in step with `t`), and
text mode reached its end screen. CSMWrap on OVMF did not start under WHPX.
From now on, only the X470 tests these builds.

## 7c. X470 run 7 (B261004-165547): text mode done, GUI Setup stuck at "Czekaj..."

**Run 7 (usos4, usosrst 1.2, MPS HAL):**
- Text mode completed and the restart worked.
- GUI Setup started, then sat at "Instalator systemu Windows 2000 — Czekaj..."
  for a long time.
- USB input did not work, which is expected before device install.

**BIOSTAR, read offline (read-only):** the disk was imaged and NTFS's log
replayed on the copy only.
- GUI Setup got only as far as lsass creating `SAM` and `SECURITY`.
  - There is no `setuplog.txt`, no `setupapi.log`, no `*.evt` and no `edb*.log`.
  - So the event log service never started: Setup was stuck early in
    user-mode init, not in device install.
- **The system clock is broken:**
  - Every NT timestamp reads as about the year 14773, so the RTC time is
    mis-read.
  - The whole text-mode copy (minutes in reality) spans about 10 s of system
    time.
  - AHCINT's 250 ms timer ticked only 59 times over 23,352 requests.
  - The GUI boot never wrote the `idle20s` trace record.
- **Conclusion:** under the MPS HAL, clock interrupts almost never arrive.
  - Text mode is mostly synchronous and survives.
  - GUI Setup waits with timeouts and `Sleep`, so it does not progress.
- **Suspect:** the firmware left the HPET in LegacyReplacement mode. Then the
  HPET, not the PIT/RTC, drives IRQ 0/8, and a pre-ACPI HAL never programs
  it.
  - CSMWrap's MP table copies the MADT overrides correctly (`src/mptable.c`),
    so the IRQ 0 routing in the MP table is the lesser suspect.

**usosrst 1.3 (diagnostics):**

Row 1 now also shows `w:`: seconds from the TSC since load, next to the
clock-interrupt seconds `t:`. If `t` lags `w`, clock interrupts are lost.

Rows 9-10, written once at load in text mode:

    CLK tsc:3600MHz hpet:FED00000 cfg:00000003 t0:00008030 run leg:1 io:FEC00000
    CLK pit:36+ rte:10000 0093D 0093E 0A0B1 lvt:100FD 00700 00400 lt0 rtc:26 02 2026

**Row 9:**
- The HPET general configuration (bit 0 enable, bit 1 LegacyReplacement =
  `leg`), timer 0 configuration, and whether the HPET counter runs.

**Row 10:**
- `pit`: the 8254 channel 0 read-back status, then `+` if its count moves (`=` if it does not).
- `rte`: the I/O APIC redirection entries of pins 0, 2, 8 and 9.
  - Bits 0-7 are the vector, bit 16 the mask, bit 15 level trigger, bit 13
    active low.
- `lvt`: the local APIC timer, LINT0 and LINT1 entries; `lt+` means the APIC
  timer is armed.
- `rtc`: CMOS registers A and B (B bit 2 = binary, bit 1 = 24 h), then the
  century and year bytes.

**Opt-in experiment (off by default):** `hpet-legacy-off.txt` in DATA
`Systems\Windows\Windows 2000\Unattended\`.
- Staging appends `/USOSHPETLEGOFF` to the text-mode `OsLoadOptions` in all
  three TXTSETUP.SIF copies.
- It also adds `usosrst\Parameters\HpetLegacyOff = 1` to `usosw2k.inf` for
  later boots.
- usosrst then clears HPET LegacyReplacement at load if it is set. The PIT
  and RTC drive IRQ 0/8 again; row 9 shows `leg:1>0`.
- This is in usosrst instead of CSMWrap, so no CSMWrap rebuild is needed.

**Reading the next photo:**
- `leg:1` with `t` far below `w`: the HPET legacy routing is the cause.
  - Retry with the flag file.
  - If that run passes, make the fix default (in usosrst or CSMWrap).
- `leg:0` and `t` ≈ `w`: the clock is healthy. Look elsewhere (rows 0-1
  during "Czekaj...").
- `leg:0` and `t` ≪ `w`: check `rte` pin 2 (masked, or the wrong vector or
  trigger) and the `pit` status (mode 2/3, counting).

## 7d. User ACPI package (opt-in, 2026-10-04)

DATA `Systems\Windows\Windows 2000\Unattended\acpi\`: the user's own ACPI
files, a temporary bridge until USOS has its own implementation. Staging
(`w2k_stage.sh` section 5):
- ACPI stays on (`ACPIEnable = 2`). Combined with `acpi-off.txt` the
  preparation stops before writing anything.
- Every `.sys`/`.dll` in that folder or one level below is used exactly as
  provided. Nothing else in the folder (sources, READMEs) is read.
  - A name the source already has (for example `acpi.sys` or `halacpi.dll`)
    replaces that file in `$WIN_NT$.~BT` and `~LS\I386`. The compressed
    copy is removed.
  - A new `.sys` becomes an extra boot driver set up like usosrst. It gets
    TXTSETUP `[BootBusExtenders(.Load)]` rows after usosrst, its own
    `[files.<name>]` section, DOSNET rows, and a boot-start service with
    ErrorControl 0 in `usosw2k.inf`.
- A new `.dll`, a duplicate name, or a folder with no binaries is refused.
- AHCINT usos4, usosrst 1.3 and the unattended keyboard answers are
  unchanged.

**First package, `acpi_w2k_x470` Stage0 (user's GPL source, 2026-10-04):**
- It is a separate WDM driver, `acpi_w2k.sys`. It does not replace the
  stock `acpi.sys`; the user's README asks for exactly that in Stage0.
- USOS built it with WDK 7.1 (x86 WXP environment). The C sources are
  unchanged; only the build glue was adapted:
  - `_WIN32_WINNT`/`WINVER 0x0500` conflict with that environment and were
    dropped.
  - `DRIVERTYPE=WDM` was dropped. With it, WDK 7.1 silently discarded the
    `HalGetInterruptVector` import, and the call became `call [ImageBase]`.
- All 18 imports resolve on the 2000 SP4 ntoskrnl/ntkrnlmp and on all six
  HALs.
- It is not bound to any device, so only its DriverEntry runs. That code
  reads the RSDP, RSDT/XSDT, FADT, DSDT header and MADT, sends ACPI_ENABLE
  if SCI_EN is clear, and writes its markers to:
  - VGA text rows 0-4, top left, two yellow-on-blue hex digits per row;
  - port 80h;
  - COM1.
- Markers: `A0`-`AB` mean DriverEntry got through. `EE` followed by a code
  is a table failure. AddDevice and START never run (no device binds the
  driver), so `AC`-`AE` are not expected.
- In text mode it starts after the stock `acpi.sys` (SETUPLDR loads ACPI
  first), the same as usosrst. So if the stock `acpi.sys` hangs, these
  markers will not appear either.

## 7e. X470 runs 8-11 (2026-10-04/05): the clock was the hang, then USB input

**What the BIOSTAR showed (read offline, read-only):**

| Run | Change | Result |
|---|---|---|
| 8 | `/USOSHPETLEGOFF` (usosrst 1.3) | System time now advances (+37 s instead of 0.28 s). GUI Setup reaches syssetup. The last setupact line is `loading dll...` for `rsabase.dll`. |
| 9 | `rsabase` commented out in `[CryptoDlls]` | `dssbase.dll` loads, then hangs in `registering...`. |
| 10 | all `[CryptoDlls]` commented out | Hangs after `Enter RegisterOleControls`, before `back from OleInitialize`. |
| 11 | usosrst 1.4 `/USOSRTCFIX`, `[CryptoDlls]` restored | All crypto DLLs register in 0.15 s. Setup gets past "Czekaj..." to the optional-component init, and NTFS timestamps are sane (2026). |

**Cause:**
- `RtcDiag` from run 11 shows the CMOS clock reads `47 25 01 01 05 10 26`: BCD, 24-hour, register B = 42h, century byte 20h at 32h.
  - The MPS HAL's `HalQueryRealTimeClock` returned Year = 26, without the century.
  - So the kernel's system time was garbage: about the year 14773 in text mode, and negative (sign bit set) in GUI mode.
- Every wait with an absolute deadline turned into an endless one: rsabase, dssbase and OleInitialize/RPC.
- Relative timers kept working, which is why NTFS checkpoints went on.

**usosrst 1.4 (`USOSRTCFIX`, Parameters `RtcFix`):**
- Decodes the CMOS clock by register B and takes the century from the FADT CENTURY byte.
- Redirects ntoskrnl's `HalQueryRealTimeClock` import to that decode, and `HalSetRealTimeClock` to a no-op, so the CMOS clock is never written.
- Sets the system time with `ZwSetSystemTime`.
- Writes `Parameters\RtcDiag`.

**Defaults since run 11 (`w2k_stage.sh` 6., `legacy_xp_staging.sh`):**
- `/USOSHPETLEGOFF /USOSRTCFIX` go into the text-mode OsLoadOptions.
- `HpetLegacyOff` and `RtcFix` go into `usosw2k.inf`.
- The opt-outs are DATA `hpet-keep.txt` and `rtc-keep.txt`. `hpet-legacy-off.txt` is no longer needed.

**USB input (run 11):**
- GUI Setup had not reached "Installing devices": `setupapi.log` holds class installs only, and no `xhci98.log` exists.
- The Welcome page (UnattendMode ProvideDefault) waits for a click, and xHCI-only boards have no PS/2 port.

**Changes in `w2k_stage.sh` 7.:**
- `usosw2k.inf` now writes the xhci98, usbhub20, HidUsb and kbdhid services (demand start).
- It also writes CriticalDeviceDatabase rows for `PCI\CC_0C0330`, `USB\ROOT_HUB20`, `USB\HubClass`, `USB\Class_03` and `HID_DEVICE_SYSTEM_KEYBOARD`.
- The answer file gets `[GuiUnattended] OemSkipWelcome=1`.
- `mouhid.sys` and `mouclass.sys` exist only in DRIVER.CAB/SP4.CAB, so the mouse comes later from GUI-mode PnP.

**The BIOSTAR itself was patched offline:**
- The same rows plus the mouse (`mouhid` and `mouclass` from SP4.CAB) went into `system` and `SYSTEM.ALT`.
  - Win10 cannot load these hives (RegLoadAppKey fails with 1009 or 5), so a small regf 1.3 editor in the session scratchpad wrote them.
- `$winnt$.inf` got `OemSkipWelcome = 1` and `OEMSkipRegional = 1`.

**Side effect of the readback:**
- Every Windows 10 mount of the BIOSTAR discards Windows 2000's NTFS log.
- chkdsk then removes index entries that were never committed (SAM, SECURITY, `*.LOG`) or recovers orphans.

**Run 12 (2026-10-05):** GUI Setup passed "Installing devices", but both xHCI controllers (149C, 43D0) ended with Code 10, and there was no USB input and no `xhci98.log`.
- Their requirement lists (LogConf `BasicConfigVector`) hold memory only and no interrupt: under the MPS HAL, the CSMWrap MP table has no PCI INTx entries.
- usbport refuses a start without an interrupt when the miniport declares `USB_MINIPORT_FLAGS_INTERRUPT`.

**xhci98 1.1.1.0-usos3** (patch 0003, `MODIFIED.txt` section 7):
- `Services\xhci98\Parameters` `PollMode = 1` registers without that flag, and a 4 ms periodic timer requests usbport soft interrupts.
- If usbport does not answer them, the timer runs InterruptDpc directly.
- Interrupt mode keeps the same timer as a rescue for a routed but dead line.
- `usosw2k.inf` writes `PollMode = 1` with ACPI off.
- The BIOSTAR got usos3 and PollMode by an offline hive edit.

**Run 13 (2026-10-05):** USB input worked until "Installing devices" restarted both xHCI controllers.
- GUI Setup restores SYSTEM from `system.sav` on every restart, so `PollMode` was gone.
- The restarted controllers then failed with Code 10.
- Since `f746754`, usos3 polls by default (`PollMode = 0` turns it off).

**Run 14 (2026-10-05): HARDWARE PASS.** The Windows 2000 SP4 installation completed on the X470, and the USB keyboard and mouse work.
- Platform: CSM off (CSMWrap), MPS HAL.
- Drivers: AHCINT usos4, usosrst 1.4 (RTC and HPET fixes), xhci98 1.1.1.0-usos3 polling.

**Open items:**
- Turn the diagnostics off for release: the AHCINT watchdog/trace, the usosrst rows and RtcDiag.
- The `xhci98.log` writer never creates its file under 2000 Setup.
- ACPI through KB979683.
- Retest NT 5.2 on usos3; until then it stays on usos2.

## 8. X470 test plan (first plan, 2026-10-03)


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

## 9. Windows 2000 Server menu entry (2026-10-08)

The servers section of the UEFI menu has **Windows 2000 Server**
(`windows-2000-server`, UEFI only; the BIOS Core leaves it out). It is the
Windows 2000 path above, unchanged: `route_as = windows-2000` (traits,
profile `w2k-x86-sp4-uefi-csm`, icon), the same micro-Linux action
(`windows2000-staging`) and driver set (AHCINT usos4, usosrst 1.4 with the
RTC/HPET fixes, xhci98 usos3 polling when the CD has `usbport.sys`).

| Piece | Where |
|---|---|
| Catalog entry, DATA folders `Systems\Windows\Windows 2000 Server\Images` / `Unattended` | `src/catalog/windows_server.zig`, installer `winhost/data_layout.go` |
| Routing as Windows 2000 | `src/catalog/os_profiles.zig` (traits row, gated out of the BIOS Core) |
| Answer family 2000, own key field `key.windows-2000-server` (2000 `ProductID`) | `src/flow/answer/target.zig` |
| Kernel argument `usos.w2k_edition=server` | `src/platform/uefi/xp_preparation.zig` (`Nt5System.windows_2000_server`) |
| DATA folder / title from that argument | `tools/nt5_profile.sh` (`USOS_W2K_EDITION=server`) |
| Server entry refuses a Professional CD | `tools/probe_nt5_source.sh` |
| Server answers | `tools/w2k_stage.sh` `usos_w2k_server_sif`, called by `prepare_xp_windows_partition.sh` when the copied `TXTSETUP.SIF` has ProductType 1 |
| `C:\USOS\W2K\srvwiz.reg` | `tools/prepare_xp_ntfs_target.sh` |
| Summary note | `boot.summary.w2k_server_limits` (all 27 languages) |

Server answers (keys the answer file already sets are kept, so a `.sif`
chosen in the menu wins):
- `[LicenseFilePrintData] AutoMode=PerServer`, `AutoUsers=5`: the licensing
  page.
- `[Components]`: IIS (`iis_common`, `iis_inetmgr`, `iis_www`, `iis_ftp`,
  `iis_smtp`, `iis_nntp`, `iis_doc`, `iis_htmla`, `iis_pwmgr`, the two
  virtual directories) and `fp_extensions` off. 2000 Server installs IIS by
  default; the other Server components are off by default anyway.
- `[GuiUnattended] AutoLogon=Yes`, `AutoLogonCount=1` when the answer sets
  the Administrator password (usos-xp.ini / profile), as on Server 2003.
- `[GuiRunOnce] "regedit /s C:\USOS\W2K\srvwiz.reg"`: HKCU
  `...\Setup\Welcome` `srvwiz = 0`, so "Configure Your Server" stays closed
  for that first logon's user. 2000 has no `reg.exe`, so the Default User
  hive is not edited; later new users still see the wizard once.
- Workgroup and the default network components come from the usual
  usos-xp.ini merge (`JoinWorkgroup=WORKGROUP`,
  `InstallDefaultComponents=Yes`); no domain controller promotion.

The decision follows the CD (ProductType), not the menu entry: a Server CD
in the Professional folder gets the same answers. The Server folder needs
its own DATA flags (`acpi-off.txt` for the X470 MPS HAL path, as in
section 7a).

**The user's media:** `Windows 2000 Server PL.iso` (434 096 128 bytes,
SHA-256 `4F0BA26C...E5A8ED`): `CDROM_IS.5` (Server Standard),
`TXTSETUP.SIF` ProductType 1, 5.00.2195 RTM (no service pack),
`SETUPP.INI` Pid `52820000` (retail channel 000: **a product key is
needed**). RTM has no `usbport.sys`, so xhci98 is skipped and **an
xHCI-only board has no USB keyboard/mouse in Setup or afterwards**; on the
X470 that means a PS/2 keyboard, or a Server CD with SP4 integrated
(SP4 slipstream support is not part of this entry).

**QEMU e2e (2026-10-08, OVMF without CSM -> CSMWrap, AHCI, `qemu-xhci` +
USB keyboard/tablet only, ACPI kept, usos-xp.ini without a key; harness
`run_csmwrap_xp_prepared.py --profile w2k-x86-sp4-uefi-csm` with
`USOS_TEST_PROBE_EXPORTS=USOS_W2K_EDITION=server`): PASS to the desktop.**
- Preparation: `[XP_WINDOWS] Windows 2000 Server answers: ...` and
  `srvwiz.reg staged`; the probe took the Server CD (xhci98 skipped: RTM).
- Text mode (AHCINT, usosrst 1.4) copied and restarted through CSMWrap;
  GUI Setup titled "Instalator systemu Windows 2000 Server".
- The first VM process ended by itself about 2 minutes into "Installing
  devices" (no STOP on screen, cause not found); booting the same disk again
  resumed GUI Setup, which then ran through: the licensing page came up
  already set to "Na serwer", 5 connections, and went on by itself; no
  product key page appeared with this CD; final tasks, restart, automatic
  Administrator logon to the desktop, no "Configure Your Server" window.
- Not shown by QEMU: USB input (the VM keeps an 8042; RTM has no xhci98),
  hardware display modes. On the X470 this CD has no USB keyboard/mouse.

## 10. Open (Windows 2000 Server)

- SP4 for the Server CD (USB on xHCI-only boards): a ServicePack drop on
  DATA with slipstream in the micro-Linux, as NT4 has for SP6a.
- The "VM ended by itself" event of the first e2e boot.
- X470 hardware test with `acpi-off.txt` in the Server Unattended folder.

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
