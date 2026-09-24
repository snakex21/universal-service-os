# Driver folders (DATA\Drivers)

USOS keeps user-supplied drivers on the `USOS_DATA` partition, next to
`Systems\`, `Utilities\` and `Programs\`:

```
Drivers\
  README.txt            short guide (Polish + English), rewritten by install/update
  UEFI\                 boot-time drivers for the USOS menu (touch, input, storage, filesystems)
    <Name>\<driver>.efi
    <Name>\driver.ini   optional manifest
  Windows 11\  Windows 10\  Windows 8.1\  Windows 8\  Windows 7\
  Windows Vista\  Windows XP\  Windows 2000\          <- NT setup systems:
      Storage\  USB\  Other\                             boot-critical / USB 3 / everything else
  Windows NT 4.0\  Windows Me\  Windows 98 SE\  Windows 98\  Windows 95\
  Windows 3.11\  Windows 3.1\                          <- folder only (manual use)
```

The folder names come from the installer's system catalog
(`installer/internal/winhost/data_layout.go`, `windowsProfiles`), so they are
the names the menu shows. Install and **Update USOS** create missing folders
with `MkdirAll` only and rewrite `Drivers\README.txt`; nothing under
`Drivers\` is ever deleted by install, update or repair (repair copies only
the ESP payload). Uninstall removes the partition like any other user data.
The installer's final screen has **Open drivers folder**
(`installer/internal/ui/drivers_folder*.go`).

All USOS-bundled drivers (the NTFS driver, the vendored touch driver, the XP
driver bundles, the Windows 7 USB 3/NVMe library, the Vista USB stack) stay
exactly as they are and remain the default. User folders are purely
additive.

## 1. Drivers\UEFI - drivers for the USOS menu

Each driver lives in its own folder with one `.efi` (if a folder holds
several, the first by name is used and drivers.txt says so) and an optional
`driver.ini`:

```ini
[driver]
name=Goodix touch          ; shown on Tools -> Drivers (default: the folder name)
type=input                 ; input | storage | filesystem | other (default other)
load=auto                  ; auto | off (default auto)

[match]                    ; optional; every key present in one section must match
smbios_manufacturer=ASUSTeK   ; SMBIOS type 1 manufacturer, prefix, case-insensitive
smbios_product=ROG Ally       ; SMBIOS type 1 product name, prefix, case-insensitive
smbios_baseboard=RC71L        ; SMBIOS type 2 product, prefix, case-insensitive
pci=1022:15E0                 ; a PCI function with this vendor:device exists
acpi_hid=PNP0C50              ; this ID appears as _HID/_CID in the DSDT or an SSDT

[match]                    ; several [match] sections: any one may match (OR)
pci=8086:9A0B
```

* **No `[match]` section = the driver loads on every computer.** Tools ->
  Drivers shows that explicitly ("Loads on every computer (no [match])").
* `acpi_hid` is a byte-pattern scan of the AML (the same tables the ACPI dump
  writes): the ID as an AML string (`0x0D "NVTK0603" 0x00`) or, for 7-character
  EISA IDs, the compressed `EisaId()` DWORD (`0x0C 41 D0 0C 50` for
  PNP0C50). It does not distinguish `_HID` from `_CID`.
* Unknown keys/sections and malformed lines are counted (`ignored_lines=` in
  drivers.txt) and ignored; a broken `driver.ini` never stops the menu. More
  than 8 `[match]` sections: the extra ones are ignored.
* Rules and tests: `src/flow/driver_manifest.zig`.

### What is loaded, and when

`src/platform/uefi/uefi_drivers.zig`, called from `manual_view.init` right
after the built-in touch driver and **before** the pointer layer enumerates
and before the DATA catalog is opened, so new pointers/keyboards/disks/file
systems are picked up like firmware ones. DATA is read with USOS's own
read-only NTFS reader over Block I/O (the same one the catalog uses), so the
EfiFs NTFS driver is not needed at this point (it is still loaded only for
the Windows Setup handoff from WORK).

For each folder (sorted by name, at most 16):

1. **Image check** (`inspectImage`): PE32+, machine x64 (0x8664), subsystem
   EFI boot-service driver (11) or runtime driver (12). EFI applications
   (subsystem 10), ia32/aarch64 images and non-PE files are refused before
   anything is loaded ("Not an x64 EFI driver"; put boot tools into
   `Utilities\<Name>\Images`).
2. **Gates**: the Tools -> Drivers toggle (`driver.<folder>=on|off` in
   `EFI\USOS\usos-settings.ini`, overrides `load=`), `load=off`, the hang
   guard (`driver.<folder>=blocked`), then the `[match]` sections.
3. **Duplicates**: a driver with the same SHA-256 as one already started
   (another folder, or the built-in TouchI2cDxe) is skipped.
4. **Secure Boot** (see below), then load and start through
   `verified_image.zig` (the shim-verified loader used for the NTFS and touch
   drivers).
5. **Connect**: if the driver installed Driver Binding protocols,
   `ConnectController(every handle, [those drivers], recursive)` binds it to
   existing controllers; drivers that publish their protocols at entry (like
   TouchI2cDxe) need nothing more.

### Secure Boot

| Secure Boot | Signed image (db or enrolled MOK, e.g. the USOS key) | Unsigned image |
| --- | --- | --- |
| **on** (shim) | verified with `SHIM_LOCK->Verify` (db, dbx, MOK, SBAT), then started by USOS's PE loader (shim 16) or LoadImage with the one-buffer override (shim 15) | **skipped, not even tried**: "Requires Secure Boot off or a signature" |
| **on**, signed by an untrusted key | rejected by shim -> the same message | - |
| off / setup mode | plain `LoadImage` | plain `LoadImage` |

USOS never bypasses Secure Boot: the only trust roots are the firmware db and
shim's MOK list. To use your own driver with Secure Boot on, sign it with a
key that is enrolled (the USOS key can sign it: `go run ./cmd/usos-efisign
sign -in x.efi -out x.efi` on the build PC). Runtime drivers cannot be
started through the shim 16 loader (USOS allocates boot-services memory);
they are skipped with a clear reason under Secure Boot and load normally
with it off.

### Never crash the menu: watchdog and hang guard

UEFI has no preemption, so a driver that never returns from its entry point
cannot be interrupted. USOS therefore:

* writes `EFI\USOS\drivers-guard.txt` with the folder name before starting a
  driver and deletes it after the driver returned;
* arms the firmware watchdog for **45 s** around the start (and its connect
  pass), so a hang ends in a firmware reset instead of a frozen screen;
* on the next start, finds the guard file, writes
  `driver.<folder>=blocked` and skips that driver ("Blocked: the menu stopped
  while it started"). Switching it on again on Tools -> Drivers retries it.

A driver that crashes the firmware (CPU exception) ends the same way (reset
-> blocked on the next start).

### Tools -> Drivers (Narzędzia -> Sterowniki)

`src/platform/uefi/manual_drivers.zig`, second row of Tools (after Secure
Boot). Rows:

* **NTFS** (built-in): loaded for the Windows Setup handoff from WORK; not a
  toggle.
* **TouchI2cDxe** (built-in): its built-in manifest (below), the match and
  load result; the toggle writes `touch_driver=auto|off`.
* every user driver: name, match result, Secure Boot line, load result and
  the on/off badge (Enter/A toggles; "Blocked" in red after a hang). The help
  panel shows the file, type, match, Secure Boot and result/error.

The menu reads DATA read-only, so toggles are stored in
`usos-settings.ini` on the ESP (`driver.<folder>=on|off`), not in
`driver.ini`; they apply at the next start. Folder names longer than 96
bytes or containing `= [ ] ;` cannot be toggled (the page says so); rename
the folder. All settings writes go through `settings_store.zig`, the menu's
single copy of `usos-settings.ini`; the installer's language merge keeps these
keys.

### Built-in manifest of the touch driver

`src/flow/touch_driver_policy.zig` gates the vendored TouchI2cDxe with the
same parser and matcher:

```ini
[driver]
name=TouchI2cDxe
type=input
[match]
smbios_baseboard=RC71L
[match]
smbios_baseboard=RC72LA
[match]
smbios_baseboard=RC73XA
[match]
smbios_baseboard=RC73YA
[match]
smbios_product=Galileo
[match]
smbios_product=Jupiter
```

(Prefixes are case-insensitive now; the driver's own profile check stays
case-sensitive and fails closed.)

### Logs

* `EFI\USOS\Logs\drivers.txt` (every start, after the first frame; also on
  the serial port between `[DRIVERS_REPORT BEGIN]`/`END`): Secure Boot state,
  the scan result, ignored files/folders, the guard, and per driver: folder,
  name, type, file, size, `driver.ini` summary, image check, signed yes/no,
  match (section number), setting, decision, Secure Boot line, result/error,
  bindings, connected controllers and start time.
* `EFI\USOS\Logs\input-devices.txt` contains the same section.

### Try it

1. Copy e.g. an EfiFs file system driver to
   `L:\Drivers\UEFI\exFAT\exfat_x64.efi` (no `driver.ini` needed).
2. Start USOS. With Secure Boot off it loads; with Secure Boot on it loads
   only if it is signed by a db/MOK key, otherwise Tools -> Drivers says
   "Requires Secure Boot off or a signature".
3. Look at Tools -> Drivers and `J:\EFI\USOS\Logs\drivers.txt`.
4. To restrict it to one machine add a `driver.ini` with a `[match]` section
   (the SMBIOS strings of a machine are in `input-devices.txt`, its ACPI IDs in
   `EFI\USOS\Logs\acpi\<UUID>\`).

## 2. Drivers\<Windows version> - drivers for the installed system

Extracted INF driver packages (INF + SYS + CAT; keep each package in its own
folder). Class folders:

| Folder | Meaning | Windows Setup | Installed system |
| --- | --- | --- | --- |
| `Storage\` | boot-critical disk controllers: SATA/AHCI, RAID, Intel VMD/RST, NVMe | loaded (Setup sees the disk) | injected (first boot finds its disk) |
| `USB\` | USB 3 controllers | loaded | injected |
| `Other\` (and files directly in `Drivers\<OS>\`) | network, GPU, chipset, ... | not loaded where USOS can avoid it (see Windows 10/11) | injected |

### Package checks (all paths)

`src/flow/inf_package.zig`, shared by the UEFI Windows 7 path and the
micro-Linux stager:

* **One package per folder that holds an `.inf`**; its sub-folders without
  an `.inf` belong to it (e.g. `amd64\`). Ownership never passes through
  `Drivers\<OS>` or a class folder, so a loose INF there does not swallow
  unrelated folders.
* **Architecture**: `[Manufacturer]` decorations; `NTamd64[.x.y]` = x64,
  `NTx86` = 32-bit; undecorated or `NT.x.y` without an architecture = x86 only
  (64-bit Windows requires decorated models). The target comes from the
  install image's WIM XML (`<ARCH>9</ARCH>` = amd64, `0` = x86; dual-arch
  media or unreadable XML = both). Mismatches are skipped with a log line.
* **Signing**: the INF's catalog (`CatalogFile.NTamd64` / `.NTx86` / `.NT` /
  `CatalogFile`) must be present next to it. 64-bit Vista/7/8/10/11 load only
  signed drivers, so an unsigned package is **skipped for x64 targets** ("64-bit
  Windows loads only signed drivers"), never force-installed; for x86 it is
  used and flagged.
* **Completeness**: every `[SourceDisksFiles]` (and `.amd64`/`.x86` for the
  target) entry must exist in the package tree; otherwise the INF is skipped
  and the missing file named.
* **Form**: a `[Version]` section with a `Signature`, and `[Manufacturer]`
  entries (not an INF-only class installer). UTF-16LE INFs (with or without
  BOM) and UTF-8 BOMs are handled.
* **Duplicates**: identical INF bytes are used once.
* **Tolerance**: a broken, oversized (> 1 MiB INF), unreadable or reparse-point
  entry is skipped and logged; **one bad package never aborts the preparation
  or the installation**. Long paths and non-ASCII folder names are fine
  (the Windows 7 archive renames folders to `NN`/`dNN`; the WORK copy keeps
  names but skips paths longer than Windows Setup's limit).
* **Order and conflicts**: the bundled drivers are applied first, user
  packages after them, in the order Storage, USB, Other. If the same hardware
  ID is in both, nothing is deleted: Windows' own driver ranking (signature,
  date, version) picks.
* **Size**: see each path below.

### Windows 10 / 11 / 8.1 / 8 / 7 from WORK (micro-Linux preparation) - wired

`tools/extract.sh`, after the copy has been verified and before the flush,
for **every method that leaves Windows Setup media on WORK**
(`sources/setup.exe` plus `sources/install.wim`, `install.esd` or a split
`install.swm`): method ISO (Windows 11 on UEFI, Windows 7/Vista through the
BIOS path) and method chainload (Windows 8, 8.1 and 10 on UEFI resolve to
chainload: USOS starts `EFI\USOS-WORK\BOOTX64.EFI`, i.e. the same Setup from
WORK). The folder comes from the catalog system id the boot menu records in
`install-state.ini` (`selected_system=windows-10` -> `Drivers\Windows 10`;
UEFI `persistent_state_file.zig`, BIOS `legacy_windows_request.sh`), not from
the image path; a request without it falls back to the image's folder
(`tools/windows_setup_media.sh`). When `Drivers\<OS>\` holds at least one `.inf`,
`usos-fb-ui --stage-drivers <DATA\Drivers\OS> <WORK>\$WinPEDriver$
<install.wim|esd> <WORK>\usos-drivers.log` (`src/platform/linux/driver_stage.zig`)
copies the accepted packages to `$WinPEDriver$\<Class>-NN\` on WORK.
Windows Setup (7 and later) searches `$WinPEDriver$` at the root of every
drive, loads those drivers in the windowsPE pass (so Setup sees e.g. a VMD or
NVMe disk) and adds them to the installed image before the first boot. This
works with and without an answer file and does not touch the user's
`Autounattend.xml`. Limits and notes:

* Setup's `$WinPEDriver$` cannot be told "installed system only", so on this
  path `Other\` packages are also loaded in Setup (harmless for most drivers;
  keep large GPU packs out if Setup misbehaves).
* A package that does not fit into the free space of WORK (a 64 MiB reserve
  is kept) is skipped; order Storage, USB, Other.
* An empty or missing folder changes nothing on WORK.
* The decisions are in `usos-drivers.log` on WORK and on the serial console.
* Tests: `python tools/tests/test_windows_setup_media.py` (media detection,
  folder mapping, wiring) and `python tools/tests/run_extract_drivers_qemu.py`
  (the real `extract.sh` in micro-Linux: chainload + install.esd for Windows
  10, ISO + install.swm for Windows 11, nothing staged without `setup.exe`).

### Windows 7 x64 through the USOS UEFI path (wimboot, PE7 or PE10) - wired

`src/platform/uefi/windows_driver_files.zig` + `windows_user_drivers.zig`:
the user's `Drivers\Windows 7` packages (x64 targets) go into the same RAM
archive (`usos-drivers.bin`) as the bundled `Systems\Windows\Windows 7\
Drivers\x64` library, after it, as `user\<Class>\NN\...`, plus
`user\usos-user-drivers.log`. The 64 MiB archive limit applies to both
together; user packages only use what the bundled library leaves, and a
package that does not fit is skipped. `usos-drivers.exe`
(`tools/windows_driver_archive.c`) writes the bundled files first and the
user files only while the WinPE RAM disk keeps a 16 MiB reserve; a user file
that cannot be written is skipped, never fatal.

* **Installed system**: the existing `usos-unattend-drivers.exe` merge adds
  `usos-win7-drivers` (recursive) as an `offlineServicing`
  `Microsoft-Windows-PnpCustomizationsNonWinPE` `DriverPaths` entry, so every
  accepted user package (Storage, USB, Other) is injected into the target.
  The merge keeps a user's answer file intact (it only adds that one
  `PathAndCredentials`, and refuses an answer file that targets the USOS
  disk).
* **Windows Setup (stock PE7, `windows7_native_startup.cmd`)**: the bundled
  library is `drvload`ed first, then `user\Storage` and `user\USB`;
  `user\Other` is not loaded in WinPE. On this path the DriverPaths merge
  runs only when an answer file is used anyway (a user answer file or the
  NVMe packages): forcing `/unattend` on a manual stock-PE7 install makes
  Setup ask for a product key, so USOS does not do that for user drivers.
  Without an answer file, once Setup has applied the image (`/noreboot`),
  `windows7_native_startup.cmd` copies `user\` (Storage, USB, Other) to
  `<target>\USOS\Drivers` and writes `<target>\Windows\Setup\Scripts\
  SetupComplete.cmd` (`tools/windows7_setupcomplete.cmd`): Windows 7 runs it
  as SYSTEM before the first logon and it adds every package with
  `pnputil -i -a` (log: `\USOS\Drivers\usos-pnputil.log`). No answer file, no
  DISM, no product-key prompt. The target is the one Windows installation
  that did not exist before Setup (`Windows\Panther\setupact.log` +
  `System32\config\SOFTWARE`); with none or several, or when the image already
  has its own `SetupComplete.cmd`, nothing is written and a warning is shown.
  `\USOS\Drivers` stays on the installed system (delete it when done).
  Not yet tried on real hardware.
* **Windows Setup (PE10 donor, `windows7_modern_startup.cmd`)**: PE10 keeps
  its own storage/USB drivers (Windows 7 drivers are not loaded into a
  Windows 10 kernel; `tools/tests/test_windows7_pe10_selection.py` asserts
  this). User packages reach the target through the DriverPaths entry above.
  If Setup cannot see the disk under PE10 (e.g. Intel VMD on), turn VMD off.
* `PnpCustomizationsWinPE`: loading drivers into the running WinPE is what
  `drvload` does before Setup starts; USOS does that step itself instead of
  adding a windowsPE-pass component to the answer file, because the stock
  Win7 Setup demands a product key as soon as an answer file is forced on the
  manual path.
* The summary page shows "Your drivers: Drivers\Windows 7: N INF used, M
  skipped".

### Windows Vista - folder only (deferred)

The Vista SP2 x64 USB flow (`tools/windows_vista_install.c`) generates its
own servicing answer and verifies its payload by hash; changing it is not
additive. Planned: pass `Drivers\Windows Vista` through the same archive and
add a `DriverPaths` entry to the generated servicing answer.

### Windows XP - folder only; design for the XP refactor

The proven XP package (driver bundles, hives, `TXTSETUP.SIF` overlay) is not
changed. Design for the refactor:

* **Boot-critical storage (`Drivers\Windows XP\Storage`)** is integrated into
  **text mode** automatically, like `tools/xp_driver_overlay.py` already does
  for the bundled drivers: for each package with a `txtsetup.oem` (or an INF
  that names a `Service` for a `SCSIAdapter`/`HDC` class device) the builder
  adds `[SourceDisksFiles]` rows (`driver.sys = 1,,,,,,4_,4,1,,,1,4` style),
  `[HardwareIdsDatabase]` (`PCI\VEN_xxxx&DEV_yyyy = "service"`),
  `[SCSI.Load]` (`service = driver.sys,4`) and `[SCSI]` entries to
  `TXTSETUP.SIF`, the file to `DOSNET.INF [Files]` (`d1,driver.sys`), and the
  service's `Start=0`/`Group`/`Tag` plus `CriticalDeviceDatabase` keys to
  `HIVESYS.INF`, then compresses `driver.sy_` into the local source. The
  same checks as above apply (x86 decorations or undecorated INF, files
  present); XP has no driver-signing requirement for text mode, but the
  answer file already sets `DriverSigningPolicy=Ignore`.
* **PnP drivers (`USB\`, `Other\`, and the INFs of `Storage\`)** are copied
  to the target as `C:\USOS\Drivers\User\<Class>-NN\` by the XP preparer
  (`prepare_xp_ntfs_target.sh`), and the answer file gets
  `[Unattended] OemPnPDriversPath="USOS\Drivers\User\Storage-01;..."` (paths
  relative to `%SystemDrive%`, `;`-separated, at most ~4 KiB). With an empty
  folder the key is left out, so the answer file stays byte-identical to
  today's. `OemPreinstall` stays `No` (OemPnPDriversPath works without it
  since XP; the `$OEM$` tree is not needed).
* Validation: the existing `check_xp_*` scripts plus a QEMU text-mode run
  with a user AHCI/RAID package, and `compare_xp_packages.py` showing only
  the expected overlay changes.

Until then USOS does not use `Drivers\Windows XP`; the README says so.

### Windows 98 / Me / 95 / 2000 / NT 4 - folder only

For manual use after installation (`Drivers\Windows 98` = INF drivers).
Windows 2000 has the class folders for the XP-style refactor.

## 3. Tests

* `zig build test`: `driver_manifest.zig` (parsing, OR/AND matching, SMBIOS
  prefixes, PCI, ACPI string/EisaId scan, image checks, settings toggle,
  hang guard decision, Secure Boot gating), `inf_package.zig` (architecture,
  catalog, missing files, UTF-16, ownership boundaries),
  `touch_driver_policy.zig` (the built-in manifest agrees with the labels).
* `go test ./...` (installer): the Drivers tree is created from the catalog
  and a second run keeps user files; nothing in the install/update path
  removes anything under `Drivers`; README is bilingual CRLF.
* `python tools/tests/secure_boot/run_qemu_secure_boot.py --only drivers`:
  GPT test disk (`tools/tests/uefi_drivers/new_test_disk.ps1`, elevated) with
  MOK-signed and unsigned test drivers (`zig build uefi-driver-fixtures`):
  with and without `[match]` (SMBIOS, PCI + ACPI OR), `load=off`, duplicate,
  ia32, EFI application, loose file, non-ASCII and long folder names, a
  Driver Binding driver; Secure Boot on (MokList seeded) and off; the hang
  guard (watchdog reset, blocked on the next start) and the settings toggle.
* `--only matrix`: the same disk behind AHCI, IDE (i440fx), NVMe,
  virtio-blk, virtio-scsi, USB xHCI and USB EHCI.
* `--only touch`: TouchI2cDxe still loads only on RC71L SMBIOS.
* `python tools/tests/uefi_drivers/run_stage_drivers_qemu.py`: the
  micro-Linux stager on real ntfs3 DATA/WORK (amd64, x86, low space).
* `python tools/tests/test_windows_driver_support.py`: the WinPE helper
  accepts an archive with bundled and user entries.

**Manual step (not automated, no driver pack in the repository):** the full
"Setup sees the disk and the installed OS boots with the injected driver"
proof needs a storage controller without an inbox driver. With virtio-win
(`viostor`/`vioscsi` `w10\amd64`) copied to `Drivers\Windows 10\Storage\`,
prepare Windows 10 from WORK in QEMU with the target disk on
`virtio-blk-pci` (and the USOS disk on AHCI/xHCI): Setup must list the
virtio disk without "Load driver", and the installed system must boot from
it. USOS does not download virtio-win.
