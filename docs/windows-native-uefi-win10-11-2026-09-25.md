# Windows 10/11 from UEFI without a WORK copy, image checks and the PE10 donor (2026-09-25)

## Diagnosis of the X470 run (build B260924-202302-7ED55EB2)

Evidence: `artifacts/win10-esp-test/run1/` (raw-read ESP logs and
`install-state.ini`, WORK marker, and the read-only compare against
`baseline-20260924-230819`).

* `install-state.ini`: `selected_iso=Systems/Windows/Windows 10/Images/pl-pl_windows_10_22h2_19045.6396_multi_editions_updated_september_2025_x86_c20a40ff.iso`,
  `selected_method=chainload`, `selected_unattend=none`, `selected_system=windows-10`.
* The ISO is **32-bit**: its `efi/boot` holds only `bootia32.efi`. After the
  4.4 GB copy, relocation moved it to `EFI\USOS-WORK\bootia32.efi`, and the
  final check for `BOOTX64.EFI` failed. Relocation matched the lowercase
  `efi/boot` directory correctly: this was **not** a case-sensitivity bug.
  The real faults were that the menu offered a 32-bit ISO on 64-bit UEFI, and
  that nothing checked the architecture before copying.
* The answer-file screen was skipped because **every `DATA\Systems\*\Unattended`
  folder on the stick is empty**. There is no `*.xml` anywhere on DATA outside
  `Drivers`. The menus already read answer files directly from DATA with the NTFS
  reader, and match the extension in any case; the screen is simply not shown
  when there is nothing to choose.
* The "WinPE" ISO in the Windows 10 list is `PE10_x64_19041_USOS.iso` (460 MB),
  the PE10 donor that the Vista and original-Windows 7 UEFI paths look for.
  It sat in `Systems\Windows\Windows 10\Images`, so the menu listed it as an
  installer. It was not the selected ISO.
* Compare: GPT, volumes and DATA were unchanged. On the ESP, only
  `EFI\USOS\install-state.ini` and four files in `EFI\USOS\logs` changed.
  WORK held the copied ISO.

## Fixes

### Image checks in the UEFI list (`image_probe/windows_media.zig`, `platform/uefi/windows_media_probe.zig`)

For the ISOs of Windows 7, Vista, 8, 8.1, 10 and 11, a few UDF/ISO9660 lookups
(any case) classify each one as:

* **Setup media**: `sources/boot.wim`, `sources/setup.exe` and
  `install.wim/esd/swm`.
* **WinPE / rescue media**: `boot.wim` without an install image (for example the PE10 donor).
* **Not Windows boot media**.

The architecture comes from `efi/boot/boot{x64,ia32,aa64}.efi`, or from the
`<ARCH>` of the declared boot.wim image when the media has no EFI loader. The
list shows the architecture as a badge and the content as the detail line.
Results are cached per menu session.

On x64 UEFI, an x86 or ARM64 image, or x64 BIOS-only media, is listed but
**blocked**. Selecting it shows the reason, for example "Obraz 32-bitowy -
wymaga 32-bitowego UEFI lub trybu BIOS (CSM)". On BIOS/CSM, x86 media is
allowed where a BIOS path exists.

The gate is checked again:

* in the summary and at start;
* in `e2e_flow.requestPreparation`, before `install-state.ini` is written;
* in micro-Linux, before anything is copied:
  `work_boot_relocate.sh source-check /mnt/source <x64|ia32|aa64>` is run from
  `micro_linux_init.sh` for chainload and iso preparations on UEFI.

A WinPE ISO is never prepared as an installer. It offers only "Start WinPE",
which boots its own boot.wim through wimboot with no USOS helper.

### Case-insensitive EFI boot entry lookup

Already case-insensitive everywhere (`work_boot_relocate.sh` `child_ci`/`entries_in`,
`case_path.zig`, Go `workboot` `strings.EqualFold`). New regression tests cover a
lowercase `efi/boot/bootx64.efi` source and x86-only / ARM64-only / loader-less
media (`tools/tests/test_work_boot_relocate.py`).

### Answer files

The UEFI and BIOS menus list `DATA\Systems\<OS>\Unattended\*.xml` (`*.sif` for
2000/XP) directly from DATA, in any case. A file dropped there shows up on the
next boot, with no installer run. The ESP mirror is only a fallback cache; it
now takes `.sif` as well as `.xml`. When the folder is empty, the summary says
where to put an answer file. Every Windows path passes the file on: WORK
(`Autounattend.xml`), the Windows 7 and 10/11 native paths (`usos-unattend.xml`,
merged with the driver paths), and BIOS native.

## Windows 10/11 native UEFI path (no ISO copy)

`Automatic` and `ISO` for Windows 10 and 11 on UEFI now start the **ISO's own
WinPE through wimboot**, straight from DATA. This is the same infrastructure as
Windows 7/Vista (`platform/uefi/windows_native_iso.zig` `startModern`). The RAM
file system holds:

* `support.cpio`: usos-launch, usos-source (read-only ImDisk mount of the ISO
  from DATA), `usos-start.cmd`;
* `modern-support.cpio`: `usos-modern-uefi.cmd`, `usos-modern-finalize.exe`,
  `usos-drivers.exe`, `usos-unattend-drivers.exe`;
* the ISO's `BCD`, `boot.sdi` and `boot.wim` (PE 10, so no donor is needed);
* the user's `DATA\Drivers\Windows 10|11` INF packages (`usos-drivers.bin`);
* the selected answer file.

`Chainload` (the whole ISO copied to WORK) stays selectable as a fallback.

`tools/windows_modern_uefi_startup.cmd`:

1. User drivers: `drvload` in WinPE (Storage and USB first), and
   offlineServicing `DriverPaths` for the installed system. This is the
   `$WinPEDriver$` equivalent.
2. The user's answer file goes through `usos-unattend-drivers.exe`, which
   refuses a `DiskID` that points at the USOS stick.
3. `usos-modern-finalize before <USOS disk>`.
4. `setup.exe /noreboot /installfrom:<install.wim|esd|swm> [/unattend:...]`,
   run by `usos-modern-finalize run-from`.
5. `usos-modern-finalize after <USOS disk>`, then `wpeutil reboot`.

### ESP protection (`tools/windows_modern_uefi_finalize.c`)

* **During Setup:** WinPE booted by wimboot has no firmware system device Setup
  can resolve. In QEMU, Setup first took the USOS stick as the "system disk",
  then failed with "GetSystemDiskNTPath: Unable to get required buffer size for
  system disk from BCD APIs; status = 0xc0000451" and "Couldn't find any system
  volumes on this EFI-based computer", and crashed with `0xC0000005` in
  WinSetup.dll. The guard now polls the ESPs of all disks except the stick,
  every 100 ms. When there is exactly one, or exactly one new one, it points
  the volatile `bcdedit /sysstore` hint at it (the Windows 7 finalizer's
  technique). Setup then logs "Found system disk at [\Device\Harddisk0\DR0]"
  and "Compliance checks found a boot disk 0 that contains a system volume",
  and puts its boot files on the **target** disk.
* **before:** it records an inventory of the stick's ESP (path, size and
  timestamp of every entry; `EFI\USOS\Logs` is recorded but not entered),
  copies `EFI\BOOT\*` to WinPE RAM, and notes the start time and the existing
  ESPs of the other disks.
* **after:**
  1. It finds the single Windows this Setup installed: off the stick,
     `winload.efi`, and a SYSTEM hive or Panther log written after `before`.
  2. The target ESP must hold a fresh `EFI\Microsoft\Boot\BCD` and
     `bootmgfw.efi`; otherwise it runs `bcdboot <T>:\Windows /s <ESP> /f UEFI`.
     If the target disk has no ESP, it creates a 260 MB one only in
     unallocated space (via diskpart; it never shrinks a partition). If there
     is no space, it stops and reports.
  3. Only then does it clean the stick. It deletes what Setup added (anything
     not in the inventory, except `EFI\USOS\Logs`) and restores changed
     `EFI\BOOT` files from RAM. Any other change is reported. It then verifies
     that the ESP equals the inventory.
  4. Firmware entries: it removes `Boot####` entries that start `bootmgfw.efi`
     from the stick's ESP, and checks that one starts it from the target ESP.
     `bcdboot` puts that entry first.
  5. Any failure stops before the reboot, and the launcher shows its dialog.
     Nothing is deleted from the stick unless the target's boot files are in place.

### Evidence (QEMU/OVMF, TCG, Win11 25H2 Polish x64, stick as removable USB on xHCI, 64 GB NVMe target)

`tools/tests/windows_native/` (`new_native_stick.ps1`, `qemu_native.py`,
`refresh_stick.ps1`, `usos-native-manual-disk.xml`: manual disk choice like the
user's file); screens and logs are in `artifacts/win10-esp-test/qemu-native-20260925/`.

* Menu: the ISO is listed with an `x64` badge and "Windows Setup". Methods are
  Automatic (ISO), ISO and Chainload, with the native help text. The answer-file
  screen lists `usos-native-manual-disk.xml`. The summary shows "Windows Setup
  straight from the ISO (no copy to WORK)" and PE 10.0.26100 x64, WIM index 2.
* Setup started from the ISO. The answer file was applied (language, key,
  edition and EULA pages were skipped). The disk page showed "Dysk 0 -
  Nieprzydzielone miejsce 64.0 GB". After "Dalej", Setup created its ESP on
  disk 0, finished "Kopiowanie plików systemu Windows", and was applying the
  image when the run was stopped as agreed. The full install was not run.
* The first run (before `/sysstore`) reproduced the crash described above.
* Stick compare (`compare_esp_snapshot.ps1 -AllowVirtualDisk` against a fresh
  baseline): GPT, volumes, WORK and DATA unchanged. The ESP differed only by
  the new `EFI\USOS\Logs\...` files and the `EFI` / `EFI\USOS` directory
  timestamps. No `EFI\Microsoft` was on the stick, and WORK was untouched: no copy.
* The finalizer's `after` step (step 2 onward) is covered by
  `tools/tests/windows_native/test_modern_finalize.py`: a WinPE-less
  simulation on temporary directories covering restore, verification, the
  target choice and `EFI_LOAD_OPTION` parsing. Its real-hardware check is the
  next Windows 10 x64 test.

### Limitations

* **WORK / chainload** (and Windows 8/8.1 on UEFI): the ISO's own boot manager
  starts Setup from WORK on the stick, so the stick is the firmware boot disk.
  USOS has no hook inside Setup's WinPE phase there, and Setup may choose the
  stick's ESP for its boot files. Prefer Automatic for Windows 10/11. After a
  WORK install, check Disk Management and the stick compare.
* x86 Windows 10 on 64-bit UEFI cannot boot at all (blocked); use BIOS/CSM.
* The BIOS menu does not show architecture badges yet (BIOS allows x86 anyway).
* BIOS Windows 10 was already native (`platform/bios/windows_native_iso.zig`, INT13
  disk-order hook so Setup's system disk is internal); unchanged.

## PE10 donor: `DATA\Programs\USOS\WinPE`

* The Vista/Windows 7 UEFI donor lookup reads `Programs/USOS/WinPE` first and
  falls back to `Systems/Windows/Windows 10/Images` for one release
  (`windows7_iso.zig` `donor_directories`, tests in the same file).
* Install/update/repair (`installer/internal/winhost/winpe_donor_windows.go`):
  * move `PE10_*_USOS.iso` from the legacy folder by rename (same NTFS
    volume), with SHA-256 checked before and after;
  * record `name/size/sha256` in `ESP\EFI\USOS\winpe-donor.ini`;
  * set Hidden+System on the folder and Hidden+System+Read-only on the ISO
    (no ACL deny rules);
  * write `Programs\USOS\README.txt` (pl + en);
  * verify step: the file matches the record.

  A corrupt donor is reported and its record kept, never overwritten.
* UEFI menu: Vista/7 summaries check the donor's name and size against the
  record, and the start hashes the whole donor. Missing or damaged shows
  "Brak obrazu pomocniczego WinPE (potrzebny dla Visty/Windows 7). Uruchom
  Naprawę w instalatorze USOS." and blocks the start.
* **How the donor was built / Repair:** no build script exists in the repo. The
  file (2026-09-15) is a Windows 10 2004 (19041) Setup ISO without an install
  image. The lookup accepts any Windows 10 x64 PE/Setup ISO with build
  10240..21999, boot index, `setup.exe`, BCD and SDI. Repair cannot recreate
  it, because USOS has no UDF ISO writer. Instead:
  * restore the original file into `Programs\USOS\WinPE`; or
  * put **one** Windows 10 x64 ISO (1507..21H2, e.g. 22H2 = 19045) into
    `Systems\Windows\Windows 10\Images`, which the legacy fallback accepts;

  then run Repair to record it.
