# Vista on the disposable Intel SSD — 2026-09-20

**Current result:** the user confirmed working USB mouse/keyboard and access to
the Vista desktop after the v11 direct-device-installation helper, with CSM
enabled. OOBE performance assessment required interruption and a second-user
attempt, so uninterrupted installation is not yet verified. The original raw
deployment script below remains disabled and is not the successful final recipe.
See [the current USB method and full history](windows-vista-community-usb-2026-09-20.md).

Goal: reach a working Vista installation on the user's Ryzen 7 5700X / ASRock
X470 Master SLI/ac / RX 560, with CSM enabled. Pure UEFI is deferred. No VM,
emulator, or automated end-to-end test was run. The user's first physical boot
reached graphical setup but stopped on an image drive-letter mismatch; see the
repair below. The next physical boot is pending.

## Source and scope

- User supplied `pl_windows_vista_with_sp2_x64_dvd_x15-36359.iso`, 3,702,233,088
  bytes, in the Kingston DATA Vista Images directory.
- Original WIM index 4: Polish Vista Ultimate SP2 x64, kernel 6.0.6002.18005.
- This is a direct offline deployment onto the authorized disposable Intel,
  **not a completed Vista installation feature in the USOS ISO menu**.
- Intel disk GUID `8e281c54-58d1-4ad0-8afd-ad76d2e48148`, model
  `INTEL SS DSC2BW120A4`, size 120,034,123,776. Its Windows partition is replaced;
  the GPT partition layout is retained. The Kingston library is not formatted.
- The deploy script backs up the Intel ESP and Win7 SYSTEM/SOFTWARE hives under
  `zig-out/vista/deploy-<timestamp>/intel-before-vista`. This is diagnostic and
  boot-configuration backup, **not a full Win7 restore image**.

## USB candidate and first boot

The previous working Win7 SYSTEM hive identifies chipset controller
`PCI\VEN_1022&DEV_43D0` and CPU controller `PCI\VEN_1022&DEV_149C`.

Only the chipset controller is covered by the initial Vista candidate:
unmodified AMD USB31_PT host/hub 1.0.5.3 (2018-01-22), copied from the existing
Win7 library. Its original INF contains an undecorated `ntamd64` manufacturer
entry and the exact 43D0 hardware ID. CAT and SYS signatures validate on the
technician host. Every imported kernel/HAL/WMILIB function in both x64 drivers
exists in the original Vista image. These checks **do not establish runtime
compatibility or signature acceptance by Vista**.

The generic Win7 USB stack was rejected for this attempt: it imports functions
absent from Vista. CPU 149C is not supported by the chosen AMD package. The user
may need to move keyboard/mouse to a chipset-connected port.

Host DISM 10 rejects Vista servicing (exit 50). Portable DISM 6.1 recognizes
Vista SP2 but does not expose Add-Driver (exit 50). Apply-Unattend reaches Vista
PkgMgr, which fails opening the offline store (exit 87). RegLoadAppKey against
the original staged SYSTEM also returns 1009 on this host. No successful
offline driver injection is claimed.

Instead, `Windows\Panther\unattend.xml` invokes
`%SystemDrive%\USOS\Vista\usos-vista-firstboot.exe` during specialize, before
OOBE. It is compiled for Vista, refuses other OS versions, stages both original
driver packages through SetupCopyOEMInf, installs the specific chipset devices
through UpdateDriverForPlugAndPlayDevices, and rescans PnP. No forced unsigned
installation or signature-policy change is made. A requested reboot is returned
through WillReboot=OnRequest. Failed installs are logged and OOBE is allowed to
continue, rather than making all setup fail on this experimental candidate.

Persistent diagnostics are beside the helper:
`<Vista drive>:\USOS\Vista\firstboot-usb.log` and `deployment.txt`.
Windows also keeps its own `Windows\inf\setupapi.dev.log`, Panther setup logs,
and `Windows\ntbtlog.txt`. There is no ProductKey setting in the answer file.

Boot uses original Vista bootmgfw.efi / winload.efi, a dedicated BCD with no menu
delay, `bootlog=Yes`, `sos=No`, `nocrashautoreboot=Yes`. CSM must remain enabled
for this first attempt. The USB stick is not needed to start this deployed OS.

## Tools and checks

- `tools/build_windows_vista_firstboot.py`: builds the small native helper with
  the project's Zig; no target execution on the host.
- `tools/deploy_windows_vista_intel.ps1`: prepares without writes by default;
  `-ReplaceIntel` performs the explicitly authorized destructive deployment.
  Disk GUID, model, size, non-system status, partition GUIDs and geometry are
  checked before formatting the Windows partition. Only the identified ESP is
  used for boot files; host firmware entries are not edited.
- wimlib-imagex 1.14.5 from the official wimlib.net download; archive SHA256
  `2f446d6fa3866582175f1a22a7be198eeee0aec7aba5b4e04ad25c99eae2d265`.
- WIM stage apply completed with exit 0. Helper build completed with exit 0.
  Static import checks passed for helper, amdxhc31.sys and amdhub31.sys.
- Deployment results and final BCD are kept in `zig-out/vista/deploy-*`.

Completed deployment: `zig-out/vista/deploy-20260920-200612`, process exit 0,
`VISTA_DEPLOYED_AND_READBACK_VERIFIED`. Original Vista EFI files and BCD were
read back successfully; the original GPT geometry was unchanged. Final checks
returned exit 0, kernel `6.0.6002.18005`, all six driver files matched their
source hashes, and the specialize hook was present. The Intel write cache was
flushed and `fsutil dirty query M:` returned `Volume - M: is NOT Dirty`.
The Win7 Windows partition has now been replaced. No physical Vista boot has
yet been observed.

## Research and its limits

- [Reddit: Vista and AMD USB on Ryzen 5700X](https://www.reddit.com/r/WindowsVista/comments/1uoxdac/windows_vista_amd_usb_driver/):
  firsthand report of Vista running on the same CPU but a different motherboard,
  with substantial USB driver problems. Not proof that this board or these
  original SP2 binaries work.
- [MSFN: Ryzen without USB2 or PS/2](https://msfn.org/board/topic/182681-is-there-any-way-to-install-vista-on-ryzen-pc-with-no-usb2-support-or-ps2-port/):
  discussion of applying the image from a newer environment and preparing USB
  before first use.
- [GitHub XHCI Vista/Win7 description](https://github.com/marie-systems/win7-sp2/blob/main/patches/drivers/XHCI_UASP_VISTA_WIN7_MUI/README.md):
  the inspected repository supplied a README but no usable driver binaries;
  no driver from this repository was deployed.
- [Microsoft: preinstalling driver packages](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/preinstalling-driver-packages)
  and [updating drivers](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/updating-driver-files)
  document the native setup APIs used by the first-boot helper.

Do not mark Vista hardware support as working until the user reaches OOBE/the
desktop and confirms keyboard and mouse work. If boot fails before specialize,
the USB helper will not yet have run; a missing firstboot log is itself useful.

## First hardware result and drive-letter repair

The user reached Vista graphical setup with CSM, but setup reported invalid
registry file paths / mismatched drive letters and USB input was unavailable.
Readback of the connected Intel confirmed the original image was built on D:
(ProgramFilesDir/CommonFilesDir, PathName and thousands of component paths),
while the first boot assigned the Intel Windows partition C: and the DVD D:.
The firstboot USB log was absent. UnattendGC shows windeploy starting setup.exe;
the driver helper had not been reached. This was a deployment error, not proof
that the candidate USB driver had failed.

`tools/repair_vista_drive_mapping.py` prepared copies of SYSTEM and SOFTWARE.
The repair preserves the image's original D: layout: the exact Intel partition
GUID now maps to D:, the DVD to E:, and WorkingDirectory/SystemRoot (native and
Wow6432Node)/BootDir/Userinit are consistent with D:. The duplicated Userinit
path from the failed boot was reduced to one correct D: path. No registry cells
were added or moved, both clean sequence numbers and header checksums were
updated, and the full parsed key/value inventories were compared before and
after to allow only these seven deliberate edits. Original hives and their
companion logs were backed up.

`tools/apply_vista_drive_mapping_repair.ps1` applied the prepared copies only
after validating disk and partition identity and checking the original hashes.
SHA256 readback and clean-header/path/mapping checks passed. Backup:
`zig-out/vista/drive-mapping-repair-v2/backup-20260920-202402`.

The interrupted physical boot left NTFS dirty. A guarded chkdsk /f /x completed
with exit 0 in 3.69 seconds, no bad sectors, and subsequent query returned
`Volume - M: is NOT Dirty`. M: is the technician host's letter; Vista itself is
now configured to use D:. Its helper log will be
`D:\USOS\Vista\firstboot-usb.log` if specialize reaches the helper.

The old raw deployment script now refuses `-ReplaceIntel` to prevent repeating
the known broken first-boot preparation. This repair does not establish working
USB or a completed installation; the next hardware attempt must confirm those.

## Second hardware result: interrupted setup child

The corrected photograph shows "computer restarted unexpectedly", not the
previous path error. UnattendGC at 20:30:15 confirms windeploy launched
`D:\Windows\system32\oobe\setup.exe`; preserving D: therefore took effect.
SYSTEM and SOFTWARE remained byte-identical to the prior repair, while boot and
UnattendGC logs advanced. Unchanged hive hashes alone must not be interpreted as
absence of a new physical boot.

`Setup\Status\ChildCompletion\setup.exe` was 1 (left from the first failed
setup); the original WIM has 0. Specialize and every other UnattendPasses value
remain 0, and no USB helper log exists. `prepare_vista_setup_retry.py` therefore
restores only that DWORD to 0 so setup can start the unexecuted phase again. It
does **not** set 3 or claim the phase completed. Full parsed registry comparison
permits only this one value change, plus clean header sequence/checksum updates.
The guarded `apply_vista_setup_retry.ps1` applied it and verified the target hash.
Backup: `zig-out/vista/setup-retry/backup-20260920-203306`.

The volume was dirty after the interrupted boot; chkdsk completed with exit 0
in 1.24 seconds and fsutil reports NOT Dirty. The next hardware boot, actual
specialize execution, and USB functionality remain pending.

## Third hardware result: BCD specialization and early USB entry

At 20:39:04 setup reached specialize but failed in
`spbcd.dll,Sysprep_Specialize_Bcd`, status `0xC0000098`, Win32 error 1006. The
generic "cannot configure Windows for this hardware" dialog therefore has a
specific BCD error behind it. The USB helper still had not run.

The initial hand-created store had only bootmgr and an OS loader, and lacked
Description/System plus the standard inherited settings/resume objects. The
complete store deployed now is adapted from the Intel's previously functioning
system BCD backup, keeping only ten standard objects whose types also occur in
Vista's own template. Old Win7 recovery/experimental entries were removed,
paths point to Vista's original EFI applications, all partition devices point
to the identified Intel, and Description/System remains 1. BCDEdit removes the
runtime TreatAsSystem marker while editing an offline copy. A host BCDBoot
attempt failed (183, named-hive collision) and was not claimed successful; the
guarded deploy used the prepared complete store instead.

USB no longer depends exclusively on specialize completing. The temporary
SYSTEM/Setup/CmdLine now runs `D:\USOS\usb.exe`. This Vista-only bootstrap
restores the normal `oobe\windeploy.exe` entry, calls the existing USB driver
helper, logs its result, then starts the original windeploy. It does not bypass
driver signatures or claim a USB installation succeeded. Native firstboot logs:
`D:\USOS\usb-bootstrap.log` and `D:\USOS\Vista\firstboot-usb.log`.

`prepare_vista_early_usb.py` changed only three existing SYSTEM values: CmdLine,
setup.exe child state back to 0, and SetupShutdownRequired back to 0. Full parsed
registry comparison verified no other value changes. The guarded deployment
checked hashes of BCD, SYSTEM and both executables after writing. Backup:
`zig-out/vista/early-usb/backup-20260920-204822`.

Both helpers compiled with Zig (exit 0), and their imports resolve in the
original Vista SP2 image. The complete BCD reference graph and early startup
hook were checked. After the interrupted hardware boot, chkdsk completed with
exit 0 in 1.35 seconds; the Intel volume is NOT Dirty. Actual early USB execution
and completion of setup still require the next physical boot.

## Fourth report: still no USB; corrected startup and diagnostics

Readback after the user's report finds both 43D0 and 149C enumerated, but neither
has a Service value and neither AMD USB service exists. SYSTEM was written at
20:53:17; the newer boot changed registry values even though Panther and the USB
logs did not advance. Absence of new Panther timestamps is not proof of no boot.
CmdLine reverted to windeploy, SetupType remained 0, and no USB helper logs exist.
Initial inspection could not tell whether the helper ran. The filesystem repair
below subsequently recovered both logs: the bootstrap restored CmdLine and
started the USB helper; that helper logged its Vista build, then no further
line. Thus the previous helper DID run, and the last recorded point precedes
completion of SetupCopyOEMInf for the hub. A blocked API or UI is possible, but
these recovered logs do not prove the exact reason.

The previous hook omitted SetupType. This was initially suspected as the cause,
but recovery of the logs disproved the claim that the hook never executed.
Microsoft KB939857 documents that changing
CmdLine also requires updating SetupType ([archived Microsoft article](https://www.betaarchive.com/wiki/index.php?title=Microsoft_KB_Archive/939857)).
The retry now sets SetupType=2 along with CmdLine; the bootstrap restores both
normal settings before running the driver helper and windeploy. No setup pass
is marked completed. Only these two SYSTEM values were changed; a full parsed
registry comparison verified the patch. This is startup-state hardening, not a
proven fix for the previous stall.

The native helper now takes the full 43D0 hardware ID from actual enumeration,
rather than passing the short ID found only in this device's CompatibleIDs.
It reports device status/problem codes, API errors and a real failure exit code.
Both helpers print their diagnostics to the console; the bootstrap keeps the
result visible for 15 seconds before continuing Setup. Logging handles now use
GENERIC_WRITE as required by [FlushFileBuffers](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-flushfilebuffers),
check writes/flushes, and append to files precreated at deployment. It also calls
SetupSetNonInteractiveMode(TRUE) before SetupCopyOEMInf (previously only the
later UpdateDriver call disabled UI), and logs before each staging/install call.
An operation requiring interaction should report a failure rather than wait for
unusable USB input. This does not bypass driver-signature verification.
Host-created
markers explicitly say target execution is pending; they are not runtime logs.

Deployment: `tools/deploy_vista_usb_retry.ps1`; backup:
`zig-out/vista/early-usb-v2/backup-20260920-210040`. Both Zig builds exited 0 and
static import checks against Vista SP2 passed. The interrupted boot left NTFS
dirty; chkdsk /f /x exited 1, recovered pagefile.sys and both orphaned USB log
files, and corrected volume/MFT bitmaps; then the volume reported NOT Dirty.
SYSTEM and both executable SHA256 readbacks passed. BCD and driver package
binaries were not changed by this retry. Hardware USB functionality remains
unverified; the candidate still covers chipset 43D0 only, not CPU 149C.

## Fifth report: wrong-OS driver signatures and missing installation queue

Hardware logs at 21:07 prove the bootstrap/helper ran. Both SetupCopyOEMInf
calls return `0xe0000244` (AUTHENTICODE_WRONG_OS); both controllers still have
problem 28. The original AMD catalogs are signed for another Windows release.
After handoff, Setup reports missing `MainQueueOnline` in its saved blackboard,
then WdsExecuteWorkQueue fails. This is distinct from the earlier BCD error.

`prepare_vista_usb_test_package.py` creates a separate local test package using
the installed SDK MakeCat/SignTool and portable OpenSSL. A dedicated SHA-1/RSA
code-signing certificate is kept in the project. Driver signatures and catalogs
are replaced only in the generated copy; executable payload bytes are compared
excluding the certificate table, its directory entry and checksum. Original
vendor packages remain intact. OpenSSL verifies the signed catalogs against the
explicit local test certificate. SignTool verifies catalog membership, reporting
only the expected untrusted local root on the host; the host trust store is not
modified. SHA-1 is intentional for this original Vista SP2 experiment.

The Vista-only helper embeds that exact public certificate and adds it to the
target machine's Root/TrustedPublisher stores before staging. The Intel Vista
loader alone has TESTSIGNING enabled. This is an experimental local signature,
not Microsoft certification or proof of Vista runtime compatibility. The
private key/PFX are not copied onto the Intel. Public certificate and runtime
logs live beside the helper under USOS/Vista.

`deploy_vista_usb_test_package.ps1` first backs up SYSTEM, repairs the dirty
filesystem, then backs up recovered Panther, USB payload and BCD. The first
attempt stopped before deployment because an indexed setup-state file could
not be read. The second completed after chkdsk exit 1; volume is now NOT Dirty.
It archives `setupinfo` and `setupinfo.4d53424c4b425244.spl` so Setup can rebuild
the incomplete queue, without marking any setup phase completed. This queue
recovery still needs confirmation on the physical boot.

Deployment backup: `zig-out/vista/early-usb-v3/backup-20260920-211353`.
Zig helper build and Vista import checks passed; hash readback of SYSTEM, both
driver packages, helper and BCD passed. No VM/E2E tests. Next physical boot must
confirm package acceptance, 43D0/hub startup and successful Setup continuation.
