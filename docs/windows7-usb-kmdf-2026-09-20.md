# Windows 7 USB dependency repair, 2026-09-20

## Evidence and limits

The Intel installation contains the USBXHCI, USBHUB3, UCX01000 and AMD USB
driver files/services. `setupapi.offline.log` records driver reflection. This
was not a case of all USB files being absent.

The actual generic USB binaries' WDF_BIND_INFO requires KMDF 1.11. The Intel
installation has Wdf01000.sys/WdfLdr.sys 1.9.7600.16385 and no KB2685811 package.
The generic USB package is a third-party backport (Riolin signatures), not an
unmodified Microsoft Windows 7 USB driver package. Its Microsoft version strings
do not establish Microsoft signing or hardware compatibility.

This proves a missing dependency, not that it is the only USB problem or the
cause of the UEFI `Starting Windows` hang. No successful desktop boot or USB
function on the physical target has been established.

## Package and production installation

Microsoft Update Catalog KB2685811 amd64 was downloaded and pinned locally.
The extracted `update.cat` signature was verified as Microsoft Windows.

- MSU SHA256: `c1aa0a453e4a886d7670da2209872737323baa9e36145ea838c9f8ffd7e7d7e7`
- CAB SHA256: `605d9434709367ea390c0051f97b77cb1a9a55b27eb46e57cc44bd9791c703bc`
- Package identity: `Package_for_KB2685811`, amd64, neutral, version `6.1.1.11`.
- Source and Catalog update ID: `tools/vendor/windows7-kmdf/manifest.json`.

`build_windows7_kmdf.py` verifies both hashes, with no download during a build.
`build_windows_native_support.py` transports the CAB and a required flag in
`win7-support.cpio`. The live Win7 SP1 package-answer helper now includes KMDF
alongside SHA-2/NVMe packages, so Windows Setup services the target image before
device installation. Missing required KMDF fails before generating an answer.
The unused host-side Go injection library was not used for this change.

## Existing Intel installation

Host DISM `/Image:M:\ /Add-Package` returned exit 87 before servicing:
`SetWindowsDirectory(hr:0x80070057)`, failed to mount remote registry. KMDF was
**not installed on the Intel disk by that attempt**. RegLoadAppKey also failed;
a pure Python parser read the SYSTEM hive. These observations alone do not
establish hive corruption.

A WinPE-only helper is now included in the USB payload. The explicit 64-byte
`EFI/USOS/win7-kmdf-repair.request` pins these identities:

- Disk GPT: `8e281c54-58d1-4ad0-8afd-ad76d2e48148`, 120034123776 bytes.
- Windows partition GPT: `73dbde99-8026-4759-a19a-fd943e891d09`.
- Offset 240123904, size 119793516544 bytes.

It refuses the host OS, the source USB, ambiguous/changed identities, non-Win7
targets and an unexpected CAB hash. It copies registry/driver diagnostics to
the USB before launching WinPE DISM. These copies are diagnostic backups, not
a complete transactional rollback of Windows servicing.

The request becomes `.running` before DISM and `.done` only on exit 0/3010.
An unfinished `.running` blocks a blind retry. Both repair success and failure
stop the startup script before Windows Setup. No request returns code 10 and
continues the ordinary installation flow. Normal disk/edition choices remain
manual. The repair makes no BCD, partition-table or formatting changes to Intel.

Logs: `EFI/USOS/Logs/WinSetup-*/kmdf-repair.log`, `kmdf-dism.log` and
`before-kmdf/`. DISM displays its own console while running and is waited on
with a blocking process wait. After success a message requests a reboot.

## Deployment and checks

`tools/deploy_windows7_kmdf_repair.ps1` rediscovered and guarded both attached
devices. It updated only the Kingston Win7 support archive and armed the request.
Intel was not written by deployment.

- USB `win7-support.cpio`: 63315912 bytes, below the Core 64 MiB limit.
- SHA256: `be391cf04f50ae4b006aa6d77baf609ab74c4376ddd8a30f10960d2e9d395122`.
- Backup: `zig-out/win7-universal-work/kingston-before-kmdf-20260920-191733`.
- USB bootloader hash unchanged: `3008d265b13343fc694bd6fff3985b1d67884a79c684472be39a767f8f2a5b5d`.
- Partition layout readback unchanged; request readback and payload hash verified.
- Zig build: 22/22 steps succeeded, 216/216 tests passed.
- Package helper tests: 16 passed in 4.818 seconds.
- Setup selection tests: 9 passed; repair/dispatch exit tests: 2 passed.
- Compiled repair helper refused host Windows with exit 1.
- Parsed final CPIO and verified CAB hash, flags, helper bytes and startup script.
- No VM, emulator, end-to-end installation or physical boot test was run.

The GUI installer EXE and full release bundle were not rebuilt in this targeted
USB update. The main build ID on the stick therefore remains the previous ID;
the archive hash above identifies this update.

## Next physical action

Connect the Intel disk to the test machine, boot USOS from Kingston, choose the
same Windows 7 Professional SP1 ISO and START. WinPE should perform the one-shot
repair instead of starting Windows Setup. The normal USOS WORK preparation may
still run before WinPE; the Intel Windows partition is not reinstalled.
After the repair's success message, restart from Intel. If repair fails, return
the USB for log inspection; do not reinstall or delete the `.running` guard.
The installed UEFI wrapper, experimental INT10 handler and boot diagnostics
remain as they were before this USB dependency change.

## Physical result reported after deployment

The user booted the Intel installation and reported the driver-list display
stopping at `disk.sys`. Readback of the attached devices confirmed:

- Request was consumed as `win7-kmdf-repair.request.done`.
- `WinSetup-2026-9-20-18-24-14-1756/kmdf-repair.log`: exact Intel target was D:
  in WinPE; DISM exit 0.
- Both installed Wdf01000.sys and WdfLdr.sys now report 1.11.9200.16384.
- KB2685811 package manifests/catalogs exist on Intel. CBS recorded startup
  processing pending, so final online servicing completion is not established.
- EFI log: AMD shadow write verification passes on 16 CPUs; UefiSeven INT10
  sanity check passes and it launches the original Microsoft boot manager.
- BCD remains normal `winload.efi` with SOS/bootlog/nocrashautoreboot enabled;
  no safeboot option. The visible driver list is consistent with SOS diagnostics.
- Still no ntbtlog.txt, MEMORY.DMP or setupapi.dev.log. This does not identify
  a specific failed driver, nor prove that the kernel never executed.

Boot diagnostic copy: `zig-out/win7-universal-work/intel-failure-20260920-192701`.
The USB dependency package reached the target, but it did not resolve the reported
boot hang. USB input operation has not yet been confirmed by the user. No boot
driver or boot configuration was changed in response to this symptom.

## CSM comparison and startup cleanup

The user subsequently confirmed that this installation boots with CSM enabled.
The fresh EFI wrapper log says `starting original Windows 7 boot manager;
firmware Int10 retained`: this is the EFI path using the firmware's compatibility
support, not evidence of a reinstall to Legacy/MBR. The new ntbtlog contains
loaded UsbHub3.sys, amdhub31.sys, hidusb.sys, kbdhid.sys and mouhid.sys. Driver
loading is now confirmed; the user's separate USB input confirmation is pending.

On the reattached Intel, SOS was set to No using a backed-up BCD copy, published
and verified. Boot logging and no-auto-restart-on-crash remain enabled. Backup:
`zig-out/win7-universal-work/intel-before-sos-20260920-193638`.

Current BootExecute was standard `autocheck autochk *`; no forced every-boot scan
was added. The volume was dirty. Guarded `chkdsk M: /f` finished in 2.28 seconds,
exit 0, found no filesystem problems. Subsequent `fsutil dirty query M:` returned
`is NOT Dirty`. No permanent autochk exclusion was added. Report:
`zig-out/win7-universal-work/intel-chkdsk-20260920-193751.log`.

Pure UEFI with CSM disabled remains unresolved. CSM startup success does not
establish exactly which firmware service or shim behavior causes the difference.
