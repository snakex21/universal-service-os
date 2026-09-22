# XP first GUI boot: LSASS message and restart

Physical target: Intel SS DSC2BW120A4, 120034123776 bytes, MBR signature
2225656991, partition offset 1048576. Host letter M:, XP letter C:.
User confirms text-mode copying completed; after restart XP shows an LSASS
write-after-dismount dialog and reboots before the GUI setup screen appears.

Snapshot: `artifacts/xp-pae/lsass-20260922-010952`.
- Read-only `chkdsk M:` exit 0, no filesystem errors; volume not dirty.
- Setup log already entered GUI mode, enumerated Intel through AMD 43C8 AHCI,
  and completed ASMS. SetupAPI ends during CryptoDlls registration, with no
  recorded error. This is the last recorded operation, not proof of its cause.
- Fifteen checked user-mode system/Setup binaries match the NiKKA ISO exactly.
  Kernel/HAL match the selected original source variants. The >4GB PAE helper
  has not run. Ordinary DEP-related PAE is present and is not the USOS patch.
- SYSTEM maps C: to the actual MBR signature/offset. AutoReboot was already 0.
- The screenshot alone does not establish a failing SATA driver or damaged SAM.

One-shot diagnostic deployed to Intel only, not the USB release:
`C:\USOS\x.exe`, armed through SYSTEM\Setup\CmdLine. It restores
`setup -newsetup` before launching Microsoft's Setup, waits for debugger/process
events without polling, records exceptions/exit/shutdown notifications, and
copies logs on start, exception, exit, or shutdown. Logs live beside the helper.
It does not change drivers, PAE, account databases, or completion flags. A forced
reset or failure before this helper starts can still prevent diagnostics.

Runtime SetupAPI level 0x4800ffff enables timestamps, chronological verbose
logging and retains per-entry flushing. Reference:
https://learn.microsoft.com/en-us/windows-hardware/drivers/install/setting-setupapi-logging-levels
The setting is diagnostic and should be restored to default after diagnosis.

Build and private-hive verification passed: every registry value compared,
only CmdLine changed, repeat patch refused, XP hive format preserved.
Deployment exited 0 and readback matched. Backup:
`artifacts/xp-pae/setup-trace-v3/backup-20260922-013221`.
No VM/E2E was run. Cause and physical success remain unverified. Next: boot the
Intel once with CSM, then inspect `USOS/setup-supervisor.log` and snapshots.

## Follow-up: single logical processor trial

After the physical retry, snapshot `lsass-20260922-150548` contained no supervisor
log. Setup logs were byte-identical to the earlier snapshot; CmdLine was again
`setup -newsetup`. This does not establish whether the supervisor ran or Setup
restored its registry state. Original PAE/MP kernel hash was checked again.

On 2026-09-22, applied `/NUMPROC=1 /BOOTLOG /SOS` to the existing Intel boot entry.
No kernel, driver, RAM-limit, DEP/PAE, USB, firmware or USB-stick changes.
Backup: `artifacts/xp-pae/single-cpu-20260922-155012/boot.ini.original`.
Guarded script exit 0: byte readback and original file attributes verified.
Initial CREATE_ALWAYS write was rejected for hidden/system boot.ini; retry uses
OPEN_EXISTING, preserving attributes. No installation was executed by the agent.

The external analysis suggests a concurrency/interrupt issue in the backported
storage stack. That remains a hypothesis: timestamps and differing last log
entries do not prove root cause, and success with one CPU would not isolate one
driver. Do not replace storport merely to match version numbers or disable USB
before this controlled trial. `/SOS` lists loaded drivers; its last line does
not identify a culprit and it does not control bugcheck restart policy.
Switch reference: https://learn.microsoft.com/en-us/troubleshoot/windows-server/performance/switch-options-for-boot-files

## Single-CPU retry failed; memory-limit trial prepared

User reports the same rapid restart, too fast for a photograph. Snapshot
`lsass-20260922-155619` contains a new ntbtlog with five starts at 15:55:37,
15:55:55, 15:56:12, 15:56:33 and 15:56:50 (guest log timestamps). The log lists
ntkrnlpa, genahci, storport, Ntfs, USBXHCI, USBHUB3 and eventually both mouhid
and kbdhid as loaded. Earlier HID not-loaded entries are followed by successful
loads. This is not proof of correct device operation. Setup logs remain byte
identical to the initial snapshot; no supervisor log was produced.

Replaced NUMPROC=1 with MAXMEM=2048, retaining BOOTLOG/SOS and original
NOEXECUTE=OPTIN/FASTDETECT. All processors are again available; DEP/PAE, drivers
and hives untouched. Deployment exit 0, readback and attributes verified.
Backup: `artifacts/xp-pae/boot-Memory2GB-20260922-155801/boot.ini.original`.
This is a physical diagnostic trial, not a confirmed repair or a permanent
memory limit. Once diagnosed, remove the temporary boot restrictions.

## Memory-limit retry failed; restriction removed

Latest snapshot: `artifacts/xp-pae/lsass-20260922-161720`.
The boot log grew to 55490 bytes and records three more starts at 16:16:55,
16:17:15 and 16:17:34. Setup logs still have no new content and the supervisor
log is absent. Neither NUMPROC=1 nor MAXMEM=2048 resolved the physical failure.
The evidence does not identify the underlying error or prove a specific driver
is responsible. Ordinary DEP PAE remains enabled; the optional >4GB patch has
never executed.

Removed MAXMEM=2048, preserving BOOTLOG/SOS and the original switches. Guarded
deployment and byte/attribute readback passed (exit 0). Backup:
`artifacts/xp-pae/boot-RemoveMemoryLimit-20260922-162335/boot.ini.original`.
No production payload or driver was replaced.

Read-only binary inspection confirms ksecd8.sys is 6.0.5456.5 (Longhorn), not
an unmodified Windows 8 security driver. Native ksecdd.sys remains 5.1.2600.5834.
Both contain KsecDD/LSA names, but that alone does not establish a conflict.
The author's recipe explicitly uses Longhorn KsecDD and a Windows 7 Storport
with a later AHCI port. Do not replace these solely to equalize versions:
https://github.com/MovAX0xDEAD/NTOSKRNL_Emu/blob/master/README.md

A firsthand report of a similar LSASS message after text-mode installation
exists for nLite-customized XP, but it does not diagnose this machine:
https://msfn.org/board/topic/126985-a-write-operation-was-attempted-to-a-volume-after-it-was-dismounted/
A clean XP SP3 source with only required modern drivers would be a controlled
comparison against NiKKA customizations, not a proven fix. Do not erase/reinstall
the current target merely to repeat the unchanged failing path.

## User-provided SP3 source prepared and deployed

User supplied `pl_windows_xp_professional_with_service_pack_3_x86_cd_x14-80476.iso`
in the repository root and requested one controlled fresh-source trial.
SHA-256: `bd3234250a6e2f68fbacf0a46cf42a7d711811e428210c0d60649a054f28ff0b`.
The source contains the required XP Professional SP3 marker and setup files;
the filename/hash alone is not independent authentication of Microsoft media.

The source's TXTSETUP.SIF has two SourceDisksFiles.x86 blocks. Fixed the overlay
editor to preserve both blocks and unrelated declarations, remove superseded
driver declarations across all blocks, and add one replacement per selected
driver. Added a short regression check for this case.

`build_xp_uefi_csm_trial.py --add-source` adds a source-bound driver bundle to
the existing experimental initramfs. It verifies the previous package hashes,
roundtrips the archive, and checks that every unrelated entry is unchanged.
New bundle: `79b93ec0843a12c88abc68728fc9ae8f1e756f5807448d85be5eef46951389aa`.
Prior source support, UI, kernel, and PAE helper are retained.

Checks exited 0:
- `check_xp_driver_integration.py --added-source`: archive, private setup hive,
  CAB/ACPI, source staging into workspace directories, wrong-source refusal.
- `check_xp_driver_imports.py --source-iso <new ISO>`: named driver imports
  resolve against this source's actual kernel/HAL/WMILIB and bundled modules.

Deployment exited 0 with hash readback, production BIOS/Vista payload and
partition layout checks. Copied the ISO to DATA/Systems/Windows/Windows XP/Images
and updated only EFI/USOS-XP/initramfs-xp and manifest.json on the ESP.
Backup: `artifacts/xp-pae/deploy-20260922-165147`.
Intel was not changed during preparation. No VM/E2E and no new Zig build:
UEFI binaries were unchanged. Physical installation outcome remains unknown.
Next user trial: UEFI USB entry, existing Windows XP menu, this new ISO, Intel
as the deliberately chosen installation target; firmware CSM remains enabled.

## Clean-source physical result: GUI welcome reached, USB input absent

User photograph confirms the XP GUI welcome screen (39 minutes), beyond the
prior LSASS/reboot failure. User reports both mouse and keyboard unresponsive.
This is progress with a different source, not proof of completed installation.
Snapshot `lsass-20260922-171225` contains new Setup logs and event logs. USB
controllers, hubs, Logitech G502 and Dell keyboard are enumerated in SYSTEM.
Installed drivers usbport.sys, usbd.sys, hidclass.sys and hidparse.sys are absent.
hidusb/mouhid/kbdhid and the added xHCI drivers are present. The source's HID
declarations use conditional copy flags (1,3); listing dependencies for text-mode
loading did not ensure persistence under WINDOWS/system32/drivers for GUI setup.

The overlay now stages these four original dependencies explicitly with copy
flags 0,0 and FileFlags=16. Files come from this same ISO's SP3.CAB, falling back
to DRIVER.CAB for unchanged files absent from SP3.CAB (usbd.sys). Manifest records
their hashes. Source ISO remains unchanged. Short integration checks verify the
new CAB files, unambiguous copy declarations, and staged payload; import checks
now also resolve the four native drivers' imports. Both exited 0.

Applied the four absent files directly to the identified Intel, using the
installed source manifest to guard against mixing systems; no registry, kernel,
account, setup-state, or partition changes. All four hashes read back correctly.
Record: `artifacts/xp-pae/native-usb-repair-20260922-171900`.
Updated Kingston experimental initramfs/manifest with guarded deployment and
hash readback; BIOS/Vista files and partition layout unchanged.
Backup: `artifacts/xp-pae/deploy-20260922-171903`.
Next physical check: boot Intel directly with CSM and resume existing GUI Setup;
do not rerun disk staging or format it. Runtime USB success remains unverified.

## Next physical result: dump_ntoskrn8 STOP 0x50

Photograph: STOP 0x00000050 (0x80566000,0,0xF5B85143,0), module
dump_ntoskrn8.sys base F5B83000, timestamp 634022e2. Installed ntoskrn8.sys
timestamp matches; SHA256 1f603da5938fc8a80efde4e98293b4bd20dd6a4140f825a682611e6a490325b9.
Fault RVA 0x2143 is a byte comparison inside a pattern-search loop. This does
not establish whether the dump-module failure is primary or secondary.
Snapshot `lsass-20260922-173758`: Setup logs unchanged from 171225, no dump
files, first 64 bytes of pagefile zero. CrashDumpEnabled=3, AutoReboot=0.
No evidence that the optional USOS >4GB PAE patch ran.

Applied a target-only reversible diagnostic workaround: CrashDumpEnabled 3->0
in the current/default control set, leaving AutoReboot=0. This disables crash
dump generation; it does not remove the normal ntoskrn8 dependency needed by
the backported drivers. Every registry value was compared before deployment;
only this DWORD changed, plus the hive header sequence/checksum. Target disk
identity and installed source bundle guarded; backup and full hash readback
verified, write flushed. No USB production payload change for this hypothesis.
Backup: `artifacts/xp-pae/dump-workaround-20260922-174735/SYSTEM.original`.
Tools: `prepare_xp_dump_workaround.py`, `deploy_xp_dump_workaround.ps1`.
Next: resume Intel CSM boot without reinstalling; observe whether Setup resumes
with USB or a different STOP is exposed. No runtime success claimed, no VM/E2E.

## Follow-up after outside analysis, 18:36

Read the user's supplied analysis. It identifies the dump-copy initialization
scan as the primary failure; this is plausible but not yet physically verified.
Locally inspected upstream MemHexSearch confirms an ImageSize-bounded scan
without a validity check before each read. Do not treat every claim in the
outside analysis as established (in particular, no runtime stack is available).

Current Intel SYSTEM has CrashDumpEnabled=3 and sequences 9/9; its SHA256 is
09a426f4433fa95bfe6de23055144e29107b388506414c31a8f14299f0ecce7f.
The previous prepared/deployed hive still verifies as CrashDumpEnabled=0,
sequences 20/20, SHA256 95d16ced07e0c340b9d8e3edcdd0ccc2d7ed7dbff75c40ebfcce4528215466d7.
SYSTEM.SAV also differs from the previous backup; staged HIVESYS.INF declares
CrashDumpEnabled=3. Thus the current value cannot establish that the previous
write never happened; subsequent replacement/reset of the hive is unresolved.
Asked whether the user resumed Intel or repeated USB installation.

Reapplied ONLY CrashDumpEnabled 3->0 to the current clean SYSTEM, with existing
model/size/MBR/source guards, all-value comparison, backup, flush and hash
readback. AutoReboot stays 0. Backup `dump-workaround-20260922-183610`.
Do not reinstall for the next diagnostic boot; boot Intel directly with CSM.
USB/source defaults are unchanged until the hypothesis is tested on hardware.

## Rapid error/restart follow-up, 18:45

User reports an error too brief to photograph, followed by automatic restart.
Snapshot `lsass-20260922-184242`: SYSTEM again has CrashDumpEnabled=3,
AutoReboot=0, clean sequences 3/3, SetupType=1. SYSTEM.SAV still declares 3,
as does the staged `$WIN_NT$.~LS/I386/hivesys.inf`. This supports investigating
Setup restoring settings; it does not prove which component replaced SYSTEM
or that the latest error was the same STOP (no photo). No new dump identified.

Prepared and deployed consistent CrashDumpEnabled=0 in current SYSTEM,
SYSTEM.SAV and the single staged HIVESYS.INF declaration. Both hives were
edited raw, comparing every value; only that DWORD plus header revision and
checksum changed. INF has one byte changed (UTF-16LE 3->0). All three writes
guarded to the Intel/source bundle, backed up, flushed and hash-read verified.
Backup: `artifacts/xp-pae/setup-dump-workaround-20260922-184459`.
Initial preparation refused INF encoding mismatch; initial deployment refused
the PowerShell JSON array shape. Both were corrected before target writes.
No driver/kernel/PAE/partition or USB-release changes. Physical result pending.
Next: Intel CSM boot without restaging; record a video if the error restarts
too quickly, since AutoReboot=0 does not guarantee every failure stays visible.

## User-authorized continuation of the other agent's CMD diagnostic, 19:41

User explicitly requested finishing the other agent's proposed change. All
three worker backups under `setup-diag-20260922-193538` matched the current
Intel SYSTEM, SYSTEM.SAV and SYSTEM.LOG byte-for-byte. Prepared private copies
of both hives with only Setup/CmdLine changed from `setup -newsetup` to
`cmd /c C:\d.cmd`: both strings are 15 characters, 32 bytes including the UTF-16
terminator. No cells allocated; entire registry inventories compared. Header
sequence/checksum updated. Initial length assertion incorrectly expected 30
bytes and stopped preparation; corrected to 32 before any target writes.

Deployed M:\d.cmd first, then SYSTEM.SAV and SYSTEM, with disk/source identity
guards, full backups, flush and SHA256 readback. SYSTEM.LOG unchanged. Backup:
`artifacts/xp-pae/setup-cmd-diag-20260922-194130`.
Script appends environment, file presence, pre-Setup marker and return code
to C:\usos-diag.txt. Uses `start "" /wait` so the return marker follows process
completion rather than merely starting the GUI executable. Existing log is
never truncated. No drivers, PAE or Setup completion flags changed.

Absence of the exit marker does NOT prove that Setup initiated a restart:
system crash/reset, script failure or lost buffered writes can also explain it.
Next user step: one Intel CSM boot; reconnect after shutting down at firmware
if it loops, then inspect M:\usos-diag.txt. No VM/E2E executed.
