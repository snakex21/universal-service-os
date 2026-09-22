# XP SP3 experimental drivers

The user requested integration into the separate UEFI preparation / firmware CSM XP x86 + PAE path, with no VM/E2E testing. Easy user-supplied driver injection is deferred.

`build_xp_uefi_csm_trial.py` calls `xp_driver_overlay.py` for the SP3 ISO on DATA. The ISO stays unchanged. The overlay contains the selected community ACPI, GenAHCI, USB3 backport, KMDF 1.11 and NTOSKRNL/StorPort dependencies. All are x86; no Vista package is reused. Payload hashes are pinned to the downloaded driver manifest.

The build edits copies of TXTSETUP.SIF, DOSNET.INF, HIVESYS.INF and SETUPREG.HIV. The Setup hive is opened privately using RegLoadAppKeyW, closed/flushed and checked for an XP-compatible, clean format. No host HKLM/HKU settings are written. DWORDs in INF are emitted explicitly in hex. ACPI is updated both as ACPI.SY_ and in the SP3.CAB cache so later setup cannot retrieve the old cached copy. Driver INF files point to I386; driver signing policy Ignore applies only to the experimental target's Setup answer file.

At boot, `xp_driver_stage.sh` checks the SP3 marker, exact source metadata hashes and payload hashes before the target-reset dialog. Unsupported SP2 or changed source fails closed. After ordinary guarded local-source staging to the selected NTFS volume, the overlay is applied to `$WIN_NT$.~BT`, `$WIN_NT$.~LS/I386` and the root TXTSETUP.SIF. Obsolete compressed/uncompressed aliases of only the selected files are removed to avoid old-file precedence. SP3.CAB is copied only to the local source, not the boot set. Each copy is compared; a driver manifest is saved under `USOS/XP` on the selected target. The existing PAE helper still runs after GUI Setup and preserves ordinary XP boot as a fallback.

Short verification:

- Zig compiles the PAE helper and UEFI launchers during the build.
- Driver imports resolve against the real SP3 kernel, HAL, WMILIB and bundled dependencies (symbol presence, not ABI/runtime proof).
- Setup hive values survive close/reopen; corresponding HIVESYS.INF entries agree.
- CAB integrity and patched ACPI cache content are checked.
- The actual staging shell runs against ordinary workspace directories and checks both boot/local copies; a changed source is refused without altering the staged files.
- Archive isolation and strict PAE patch checks use real XP binaries on copies only.

Hardware trial: select **Windows XP - UEFI/CSM + PAE (experimental)**, then **XP-SP3-NiKKA-UEFI-CSM-PAE.efi**. Preparation starts through UEFI; keep firmware CSM enabled for the subsequent Intel boot. Follow the existing target selection/format confirmation. When prompted after successful staging, remove USOS and boot the Intel through its Legacy/CSM entry. USB/SATA/ACPI runtime behavior and PAE above 4 GiB remain unverified until that physical installation.
