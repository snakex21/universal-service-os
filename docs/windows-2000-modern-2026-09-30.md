# Windows 2000 SP4 on modern boards (X470): AHCI, ACPI, USB (2026-09-30)

Status: **experimental, blocked** on AHCI in GUI Setup (section 5), branch `feature/win2000-modern`. QEMU results in
section 5; the X470 run is still to do (section 6). Earlier state:
[windows-2000-uefi-2026-09-27.md](windows-2000-uefi-2026-09-27.md) (the
paths, the CMA repacks), [research/win2000-ahci.md](research/win2000-ahci.md)
(storage options).

The UEFI profile `w2k-x86-sp4-uefi-csm` (UEFI + firmware CSM, and UEFI
without CSM through CSMWrap) now stages three things on the target after the
local-source copy (`prepare_xp_ntfs_target.sh`):

| Piece | Solution | Licence | Script |
|---|---|---|---|
| AHCI (X470 `1022:43C8`, no IDE mode) | **AHCINT 1.3.0.0**, unmodified i386 ScsiPort miniport | GPL-3.0, bundled (source tracked in `tools/vendor/ahcint/1.3.0.0/src`) | `tools/w2k_stage.sh` |
| ACPI (2000's `ACPI.SYS` 5.0.2195 cannot parse modern tables) | **ACPI off**: `TXTSETUP.SIF [ACPIOptions] ACPIEnable = 0`, so Setup installs the **MPS Multiprocessor HAL** (`halmps.dll`) from the MP table | nothing to bundle (Microsoft's own HAL, one INF value on the target copy) | `tools/w2k_stage.sh` |
| USB (xHCI only: CPU `1022:149C`, chipset `43D0`) | **xhci98 1.1.1.0-usos2** x86 (the NT 5.2 build), GUI-mode PnP install, forced USB/HID stack incl. `usbhub20.sys` | GPL-2.0-only, bundled (already in the 1.1 package) | `tools/nt52_usb_stage.sh` (2000 mode) |
| Display | VGA/VESA (inbox) | | |
| Answer file | the existing `w2k_selected_partition_uefi_csm.sif` (`\WINNT`, `ProductID`) | | unchanged |

The BIOS path (`nt5-staging`) is unchanged: the BIOS micro-Linux carries no
driver package, and the old boards it was tested on (MS-7100) have IDE and a
working ACPI. On the X470 use the UEFI entries (with or without CSM).

## 1. AHCI: AHCINT

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

## 2. ACPI: off, MPS HAL

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
- **What USOS does:** `ACPIEnable = 0` (Microsoft's own switch; 2 = the
  1999 BIOS-date rule). SETUPLDR then never picks an ACPI HAL; NTDETECT finds
  the MP table and Setup installs "MPS Multiprocessor PC" (`halmps.dll`,
  I/O APIC, 2 CPUs on Professional). Without an MP table it would be
  "Standard PC" (PIC, one CPU).
- **Where the MP table comes from on the X470:** without CSM, **CSMWrap
  builds one** from the ACPI MADT and the `_PRT` of every PCI root bridge
  and bridge with its own `_PRT` (`csmwrap/src/mptable.c`, uACPI), and a
  `$PIR` table (`pir.c`). With the firmware CSM it depends on AMI's CSM
  (unknown; the X470 run shows it).
- Costs: no ACPI power-off ("It is now safe to turn off your computer"), no
  power button, no sleep. AHCINT needs no interrupt at all; xhci98 needs its
  INTx pin routed through the MP table (section 6).
- `USOS_W2K_ACPI=on` keeps Microsoft's rule (for a later opt-in; nothing
  sets it yet).

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

## 5. QEMU (2026-09-30)

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

**Blocker (2026-09-30):** on every Pro AHCI run the volume fills up with
more than 10,000 ESENT transaction logs of 1 MB each
(`%windir%\security\edb*.log`, the security configuration database) until
the disk is full; the "security subsystem" error follows from that. The
same Setup on IDE writes none, and runs without xhci98 show the same flood,
so xhci98 is not the cause. The prime suspect is AHCINT's cache handling:
SYNCHRONIZE CACHE and SRB_FUNCTION_FLUSH / SHUTDOWN are completed as
success **without sending FLUSH CACHE** (`src/ahcisatl.c`
`AhciProcessAtaSrb`, `src/ahcimain.c` `HwStartIo`). That is also a
data-safety issue on hardware (power-off after shutdown). Next step: a
USOS patch 1.3.0.0-usos1 (FLUSH CACHE / FLUSH CACHE EXT for those requests)
built with the WDK, then a QEMU rerun; UniATA 0.47b as the alternative.
Until then **2000 Pro on AHCI does not finish GUI Setup in QEMU**; the X470
test waits.

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

## 6. X470 test plan

Not yet: first the AHCI blocker in section 5. After the fix: UEFI without
CSM (CSMWrap) and with CSM, Windows 2000 SP4 Pro, target on the chipset SATA
(`1022:43C8`). Expect text mode, GUI Setup with USB keyboard and mouse on
the chipset (`43D0`) and CPU (`149C`) rear ports, the MPS HAL (2 CPUs in
Task Manager), no 0xA5, no 0x7B after Setup, `%windir%\xhci98.log`; then
shut down and power off by hand (no ACPI soft-off).

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
