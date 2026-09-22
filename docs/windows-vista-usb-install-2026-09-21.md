# Vista SP2 x64 installation from USOS USB — hardware trial v6

## v6: service KMDF through Setup before the first reboot

The user confirms no manual restart during Pkgmgr: USB installation restarted
automatically, Intel started, then the prerequisite/USB sequence failed. The
reason the first Pkgmgr invocation has no exit log remains unknown. Do not
attribute it to the user. Existing target logs prove the missing prerequisite,
not the cause of the interruption.

The v5 Panther log explicitly skipped offline servicing because no answer file
was supplied. V6 gives original Vista Setup an explicit `/unattend` containing
only `<servicing>` for Microsoft KB2864202. Package identity is taken from the
actual CAB update.mum: Package_for_KB2864202, version **6.0.1.0**, amd64,
neutral, token 31bf3856ad364e35 (the KMDF file version is 1.11, not the package
identity version). The hash-checked frozen CAB is available in WinPE RAM for
the complete Setup process. No disk, edition, account or product-key settings
are inserted; the existing manual disk-selection UI remains intended.

After Setup exits successfully, the helper requires both target Wdf01000.sys
and WdfLdr.sys to report 1.11 before copying/arming the USB hook or requesting
restart. If servicing fails or files remain old, it stops in PE with working
input and exports the generated XML, Panther and target CBS log to USB.
This avoids declaring the target USB-ready when it still has KMDF 1.7.
The hardware-confirmed firstboot v11 payload is byte-for-byte unchanged.

This uses the documented answer-file servicing mechanism, rather than adding
the failed host-side offline Pkgmgr command to production. Source references:
https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/offlineservicing
https://learn.microsoft.com/en-us/iis/install/installing-iis-7/using-unattended-setup-to-install-iis
Servicing with original Vista Setup under this PE10 donor remains a hardware
trial, not a confirmed success.

Validation: native helper builds exit 0, 29 ESP cases pass, production XML
matches the Microsoft MUM and handles escaping/buffer limits, production KMDF
gate accepts both real 1.11 files and rejects missing/invalid files using only
project-local fixtures. Frozen payload/profile/CPIO checks pass. No VM/E2E.

Deployed to Kingston with hash readback PASS, unchanged partition layout:
`artifacts/vista/usb-install-update-20260921-175843`.
Vista archive SHA256 `a895a81cfc2b1990b28a11eff20bae831083ac59507293218eecdc8de2356c36`.
Common archive SHA256 `3c7208e587b354833f5e60be14a31fc84e281d7ecca7461e63bf66596d67a2a7`.
No additional changes to Intel this turn. The existing Intel still lacks KMDF;
booting it again would retain the old stop. Next check is a fresh installation
from the updated USB, CSM enabled / Secure Boot disabled / USB UEFI entry.

## Latest hardware result: firstboot KMDF blocked, not BCD

Run `WinSetup-2026-9-21-16-35-31-1760` records v5, Vista Setup exit 0,
verified exported system BCD, successful test-signing and completed USB hook.
Both target Setup error logs are empty. The Intel still has the same five
partition GUIDs, so this run does not prove full partition recreation.

On Intel, the first KMDF attempt logs waiting for Pkgmgr but no process exit.
A later bootstrap run stops on the existing attempt marker with error 21.
WDF remains 1.7; no KB2864202 CBS package is registered. The pending transaction
is the original 2009 image transaction, not a KB2864202 transaction. The cause
of the interrupted Pkgmgr attempt is not established; user clarification about
the observed screen and any manual restart is pending.

Evidence preserved in `artifacts/vista/kmdf-failure-20260921-174454` before
repairing dirty NTFS. CHKDSK exited 1, repaired indexes/security metadata, found
zero bad sectors, and the volume then reported NOT Dirty. Recovered KMDF logs
are complete enough to identify the gate above.

An explicit offline Vista Pkgmgr attempt failed to initialize the offline store
with 0x80070057, without installing the package. Evidence:
`artifacts/vista/offline-kmdf-20260921-174803/pkgmgr.log.txt`.
SYSTEM/SOFTWARE/COMPONENTS hashes match the pre-attempt backups exactly.
Do not add this failed offline command to the production USB workflow or delete
the attempt marker/pending.xml blindly. No new helper fix has been deployed
for this failure yet. No VM/E2E was run.

## v5: deletion and recreation of all target partitions

The user deletes all Intel partitions in the Windows Setup disk screen.
V3/v4 incorrectly required the old ESP GUID, and preflight expected a BCD
already present. That requirement is removed: the trial remains bound to the
Intel GPT disk GUID and size, but accepts a unique replacement ESP on that
disk. A disk with no ESP is allowed into Setup. Setup owns partition creation
and formatting; the helper does not erase or partition any disk.

Partition notifications invalidate the removed ESP alias and reselect the new
FAT32 ESP with both BCDEdit tools. A new ESP need not contain a BCD before
Setup creates it. The finalizer still exports and verifies bootmgr's ESP and
the default loader's target OS partition before arming USB firstboot. One final
inventory runs on Setup process completion to handle queued notifications.
There is no timer polling. Multiple replacement ESPs, duplicated target disks,
or a changed disk GUID/size are refused. A leftover ESP from an initially
ambiguous layout is not silently substituted for the deleted original.

**Current clean-install instructions supersede the historical v3/v4 advice:**
boot the Kingston UEFI entry with CSM enabled and Secure Boot disabled. In
Vista Setup, delete all partitions on the Intel and select its unallocated
space. Keep other disks, especially the Kingston, untouched. This supports
partition deletion in Setup; external `diskpart clean`/disk GUID replacement
is not part of this profile. The current Intel installation is not modified
while building/deploying this update.

Short verification: Zig C compilation and 29 in-memory production selector
cases (empty disk, all partitions deleted, replacement ESP, another disk,
changed size, stale/duplicate/ambiguous ESPs), plus exact CPIO/v11 payload hash
checks. Physical clean-install confirmation remains pending. No VM/E2E.

The first build exposed a no-CRT stack-probe linker error in the finalizer;
its single-threaded path buffers now use static storage. Subsequent builds
and selector tests passed.

V5 deployed to the identity-checked Kingston with readback PASS and unchanged
partition layout. Backup: `artifacts/vista/usb-install-update-20260921-141814`.
`vista-support.cpio` SHA256:
`3ce7a9b00a7f930500fbbc3568fa6911a3b74c3696e3a10a13fda7268c730a18`.
Both generic and Intel-profile helper builds exited 0. Deployment also checked
the exact frozen v11 payload and profile assets. No Intel write was performed.

## v3 hardware success in Setup, v4 finalizer correction

Run `WinSetup-2026-9-21-12-41-40-1760` proves the v3 EFI selection worked:
both BCDEdit calls and the system-store export returned 0, the exported store
matched Intel ESP partition 1, and **Vista Setup returned 0**. Its target
`target-D-bt-setuperr.log` is empty. The wrapper then stopped at BCD preparation
with error 32, before arming the firstboot USB hook. This was a different failure
behind the same generic launcher dialog, not another GLE 15250 failure.

The finalizer called `CopyFileW` on the live BCD hive held open by the registry.
`check_vista_bcd_sharing.py` reproduced exactly error 32 using a project-local
BCD loaded through RegLoadAppKey; copying succeeded after closing the hive.
V4 instead rebinds the selected ESP and exports the coherent system BCD through
BCDEdit to RAM, then inspects that export. It keeps the target identity/default
OS-device checks and the known USB payload unchanged.

The current Intel OS partition is now
`8dca99dc-9f12-46c9-9c0d-5230748ee536`. Its native Setup state was fresh:
SystemSetupInProgress=1, SetupPhase=4, ChildCompletion/setup.exe=0,
CmdLine=oobe\\windeploy.exe. SystemRoot/ProgramFiles are C: and MountedDevices
maps C: to this partition. All 13 v11 payload files were already copied exactly.

The interrupted finalizer was completed offline on this guarded Intel only.
A consistent local BCD copy contained the new Vista loader
`{9c49fcee-b5ba-11f1-a7ed-f1c3e21787f6}`; it was selected as default/displayorder,
bound to the current OS partition, and enabled for test signing. The raw SYSTEM
edit sets CmdLine to `C:\USOS\usb.exe`; all registry values were compared, with
only the intended CmdLine/SetupType values allowed to differ. Original Vista
bootmgfw.efi is the fallback loader. The three written files passed hash readback;
partition geometry stayed unchanged. Backups and deployment evidence:
`artifacts/vista/finish-successful-setup-20260921-135542`.

**Next hardware action: boot the Intel with CSM enabled. Do not reinstall from
the USB for this check.** The existing image should continue through the known
USB bootstrap and Windows Setup; only the user can confirm that next boot.

Validation: Zig compilation, exact CPIO/profile/v11 hashes, the short live-hive
sharing reproduction, and local registry/BCD preparation checks. No VM/E2E.

## Historical Intel trial: v3

The next v2 hardware run also returned 31 / GLE 15250. Its log shows three
initial internal ESPs and no executed `/sysstore`. Earlier logs show
`0xc0000451` before the extra ESPs were created: duplicate Intel ESPs cannot be
treated as the established original cause. The Kingston ESP remains a possible
contributor, not a proven one. Its GPT type has not been changed.

V3 uses an explicitly enabled hardware profile for this disposable Intel:
disk GUID `8e281c54-58d1-4ad0-8afd-ad76d2e48148`, size 120034123776, original ESP
GUID `266ef7fa-2486-4050-892f-20c3bc889930`. Disk/partition numbers and drive
letters may change. Missing, duplicated or mismatched identities stop before
Setup. This profile is enabled with `build_windows_vista_support.py
--intel-profile`; ordinary release builds do not silently pin this Intel.

`prepare_vista_intel_boot_profile.ps1` reads guarded Intel identities, saves a
local BCD copy, and copies the original Vista 6.0.6001 BCDEdit/MUI to the project.
It writes nothing to Intel. All profile/BCD tool assets are manifest-checked at
build and SHA256-checked again in WinPE. The working firstboot v11 files remain
identical to the hardware-success snapshot.

Before launching Setup, v3 selects that ESP through WinPE BCDEdit and original
Vista BCDEdit `/sysstore`. It then starts a separate Vista BCDEdit process to
`/export` the system store WITHOUT `/store`, into WinPE RAM, and checks that
bootmgr's device contains the pinned ESP GUID. A nonzero tool result, failed
export, or mismatched store blocks Setup before image copying. This verifies
the Vista command-line tool's view; it does not prove Setup itself will honor
the selection, which still needs the hardware run.

Additional USB log files: `vista-bcd-sysstore.txt`, `vista-bcd-export.txt`,
`vista-bcd-system.bin`. `vista-install.log` records firmware type, profile,
each command result and the chosen disk/partition. No host system BCD command
was used to test this: the original tool was exercised only with `/store`
pointing to a project-local copy, and successfully read it.

**Historical v3 retry instructions (superseded by v5):** keep all EFI/MSR partitions;
format only the large Windows partition on the Intel in Setup. Do not delete
the pinned ESP. Keep CSM enabled, Secure Boot disabled, and boot the Kingston
UEFI entry. The profile is for this Intel trial, not arbitrary target disks.
If preflight fails, collect the USB logs instead of repeating installation.

Short checks: Zig compilation, 16 production selector scenarios (including
wrong disk/size/GUID, duplicate identity, changed disk numbers), local-copy
Vista BCDEdit read, and CPIO/profile/v11 hash verification. No VM/E2E.

## Hardware result and v2 correction

V1 reached original Vista Setup with working mouse and keyboard in PE10. It
applied the image but failed at `Callback_MoveBootFiles` with GLE 15250 /
`0xc0000451` (ambiguous system device). Setup exited 31 and invoked rollback;
the firstboot finalizer correctly did not run. The later `0xc0000034` screen
does not establish a completed installation. The complete error was in target
`$WINDOWS.~BT/Sources/Panther`, not the stale X: Panther copy. Evidence:
`artifacts/vista/failed-usb-setup-20260921-004708`.

Intel now has three ESPs and a new OS partition identity. Old scripts pinned to
OS GUID `73dbde99-8026-4759-a19a-fd943e891d09` must not be used for this disk.
No Intel partition/file was changed by the v2 preparation.

V2 inventories internal ESPs before Setup and responds to device/WinPE Panther
filesystem notifications while blocking on Setup completion (no timer polling).
It selects only a unique new ESP or the sole internal ESP, uses `/sysstore`,
and keeps its DOS alias alive for the process lifetime. A reformat changing
the volume serial causes reselection. The finalizer uses the selected ESP GUID
on the verified target disk. Multiple new ESPs are not guessed by disk order.
Final log export now includes target BT/Windows Panther logs on the source USB.

V2 compiled with Zig; 10 in-memory production ESP-selection scenarios passed,
including recreated partitions and refusal of ambiguous layouts. The packaged
13-file firstboot v11 payload passed exact SHA256 comparison. No VM/E2E was run.
The fix needs a hardware retry; compilation does not prove Setup completion.

Reference: Microsoft's [BCDEdit options](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/bcdedit-command-line-options)
describe `/sysstore` as temporary EFI system-store selection for ambiguous
devices, valid until reboot.

## Scope and status

The working v11 firstboot sequence was confirmed by the user on Ryzen 5700X,
ASRock X470, RX 560 and the Intel SSD, with CSM enabled. This change connects
that exact payload to a USB-originated installation. V1 failed on physical
hardware as recorded above. V2 needs a retry. No VM or E2E was used.

For this trial, boot the **UEFI entry of the Kingston**, keep CSM enabled and
Secure Boot disabled, select Windows Vista and the original Polish SP2 x64 ISO,
choose Automatic/direct ISO, and leave Unattended at None. The summary should
name `PE10_x64_19041_USOS.iso` as the boot source. PE10 provides input/storage
drivers before the Vista installer opens. Windows Setup still controls edition,
license acceptance and destination selection; the helper never formats a disk.

For current clean installation, use the v5 instructions above. The old v3
requirement to preserve Intel EFI/MSR partitions no longer applies. Keep
all Kingston USB partitions intact.
After the installation phase, boot the Intel rather than restarting the ISO.
The KMDF prerequisite may request an additional restart before v11 installs USB.

## Connected production path

`manual_summary.zig` -> `windows_native_iso.zig` -> Vista install-WIM validation
in `windows7_iso.zig`/`wim_setup.zig` -> unique validated PE10 donor -> wimboot ->
`windows_iso_startup.cmd` -> `windows_vista_modern_startup.cmd` ->
`usos-vista-install.exe` -> original Vista `sources/setup.exe /noreboot` ->
target package / BCD / pre-Setup hook -> restart -> known `USOS/usb.exe` and v11.

The selected Vista ISO supplies Setup and install.wim. The donor supplies only
the boot environment. All install editions must be x64 version 6.0 build 6002;
the existing strict PE10 donor selection is reused. BIOS native-ISO behavior is
unchanged; this new path requires the UEFI USB entry even though CSM stays on
for the installed Vista system. User answer files are rejected in this trial.

Before launching Setup, the helper validates SHA256 of all 13 payload files,
requires PE10 in UEFI mode, checks the original Vista Setup version, and records
existing internal GPT Vista SYSTEM hashes. It waits for Setup to exit. Only one
new/changed Vista target is accepted after a successful Setup exit. USB/removable
destinations are excluded. The source USB is not selected as a target ESP.

The finalizer copies the exact v11 helpers, v10-signed CAT/unchanged drivers and
KB2864202 CAB. It checks the BCD default OS-device identity against the target
GPT partition before enabling test signing for that loader. It publishes the
Vista fallback EFI file on the same target disk, preserving the prior file.
Original Vista SP2 legitimately carries a 6001 EFI loader, which is accepted.

The Vista SOFTWARE/SYSTEM hives cannot be assumed readable through the host's
RegLoadAppKey API: read-only-copy checks returned 1009 for both original and
installed Vista SOFTWARE, while BCD opened normally. The new bounded reader
therefore reads existing hive cells directly and refuses dirty/bad-checksum
hives. It checks SystemRoot/ProgramFiles drive consistency, the GPT MountedDevices
mapping, and fresh Setup state. Only existing Setup/CmdLine and SetupType values
are edited, without relocating/allocating cells. It saves the original SYSTEM,
advances clean sequence numbers/checksum, flushes a temporary file, replaces the
target hive, and reads it back byte for byte. It does not mark setup passes
complete or modify SOFTWARE/COMPONENTS. A failed check blocks automatic reboot.

## Verification and artifacts

- `zig build usos-x86_64 -Doptimize=ReleaseFast`: exit 0.
- `zig build test -Doptimize=ReleaseFast`: exit 0 (host unit/framebuffer tests).
- Native WinPE helpers and Vista installer helper compile successfully.
- `check_vista_usb_support.py`: CPIO names/size constraints, live dispatcher,
  exact hardware-success payload hashes, no private signing keys: PASS.
- `check_vista_hive_patch.py`: compares the entire parsed registry before/after
  an in-memory patch of the original SYSTEM; only the two intended values may
  differ. Dirty, truncated, malformed and oversized cases reject unchanged.
  Reading the original SOFTWARE through the same parser: PASS.
- Original ISO WIM metadata: four x64 6.0.6002 editions. Original Setup is
  6.0.6002.18005; original bootmgfw.efi is 6.0.6001.18000.

No target helper was run on the technician Windows and no Intel files were
changed by this turn. Tests used local copies/in-memory buffers. Installation
will begin only when the user boots the USB and proceeds through Windows Setup.

The verified v11 payload comes from
`artifacts/vista/hardware-success-v11-20260920-235629`, manifest-checked by
`tools/build_windows_vista_support.py`. Its private keys are not included.
The builder emits `zig-out/windows-native/vista-support.cpio`. Native-support
build and Go payload packaging include it for subsequent releases. The current
trial updates the stick directly; an old installer EXE has not been rebuilt.

`tools/deploy_vista_usb_install.ps1` checks the Kingston disk GUID/size/USB bus,
ESP and DATA partitions; backs up existing files; copies only BOOTX64.EFI,
support.cpio and vista-support.cpio; flushes and verifies hashes and unchanged
partition geometry. Backup and deployment manifest are in
`artifacts/vista/usb-install-update-<timestamp>`.

Diagnostics: source USB `EFI/USOS/Logs/vista-install.log` (within the logger's
run directory), WinPE-side `usos-vista-install.log` beside the helper, and after
successful finalization target `USOS/Vista/installation-from-usb.log`.
Subsequent firstboot logs remain under target `USOS/Vista` and `USOS`.

## Remaining limits

Native Vista Setup running in this PE10 donor, the new automatic finalizer,
and the entire clean-install sequence need physical confirmation. The tested
target USB profile covers AMD 149C/43D0; it is not universal hardware support.
Other target layouts/editions/hardware are not established by this trial.
OOBE performance assessment and the pending CBS transaction from the older
installation are separate issues; this change does not claim to solve them.
