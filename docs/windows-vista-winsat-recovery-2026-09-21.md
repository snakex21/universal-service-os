# Vista OOBE WinSAT stall — hardware trial, 21 September 2026

## Evidence

USB installer v6 reached target OOBE on Ryzen 5700X/X470/RX560, CSM enabled.
The target logs confirm KMDF 1.11, trust preparation, USB firstboot and windeploy
returned success. OOBE created user `test`, saved computer name `test-PC`, and
logged `Exiting mandatory tasks... [0x0]` at 18:20:03.
The current WinSAT session completed graphics/media/CPU assessments; its final
record is `Running Assessment: mem ''`. This localizes the observed stall but
does not establish why the memory assessment stopped.

Evidence and original hives are in
`artifacts/vista/winsat-stall-20260921-184000`. CHKDSK corrected the volume bitmap
(exit 1), reported zero bad sectors and left M: not dirty.

## Changes

* USB installer v7 adds an independent Vista-only `USOS/oobe.exe` entry before
  the unchanged USB bootstrap. It sets and flushes
  `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\WinSAT\MOOBE=2`, verifies
  readback, logs to `USOS/oobe-prep.log`, then runs the frozen `USOS/usb.exe`.
  All 13 hardware-success v11 payload files remain byte-identical.
* This is an intentional bypass of the automatic assessment, not a measured
  performance result. No ratings are synthesized and WinSAT.exe is unchanged.
  Static inspection of this Vista WinSAT.exe shows `moobe` reads MOOBE and exits
  before assessments for nonzero values. `formal` does not enter this guard.
  Early exit returns 1; OOBE's handling still needs physical verification.
* Existing Intel recovery changes only the existing MOOBE DWORD (1 -> 2), hive
  sequence/checksum, and its cached Panther answer file. **MOOBE=1 already takes
  the early exit**, so changing this DWORD alone is not a complete explanation
  for recovery. The additional recovery-only `oobeSystem` answer uses
  `SkipMachineOOBE` and `SkipUserOOBE` to avoid repeating completed pages and
  creating another account. This is gated by the existing `test` SAM account,
  successful mandatory-task log and current OOBE state. The Vista SP2 shell-setup
  manifest contains these boolean settings (deprecated/testing-only).
* These OOBE page-skip settings are **not shipped for fresh installations**.
  New installs still use normal account creation. SYSTEM and SAM on the Intel
  were verified byte-identical; no Setup completion flags were forced.

## Verification and deployment

Zig compiled the Vista gate and WinPE installer (exit 0). Short checks passed:
29 ESP selection cases, production servicing answer/KMDF checks, frozen payload
hashes, CPIO names/capacity and profile assets. Offline patch validation confirmed
one payload-byte change in SOFTWARE, rejected dirty input and verified MOOBE=2
with an independent registry parser. No VM or E2E tests.

Intel repair readback passed; reversible originals and hashes are under the
evidence folder's `prepared/`. Kingston update backup:
`artifacts/vista/usb-install-update-20260921-184841`.
`vista-support.cpio` SHA256:
`80281963c9dbd4b06fdbb267089817f6859047143c74e26bd48b48a05f75f6e0`.
Common support and BOOTX64.EFI stayed byte-identical; partition layout unchanged.

Next: boot the existing Intel installation with the same working firmware
settings. Do not reinstall or create another account for this check. Completion
to the existing account's desktop is not yet verified. If it still stops,
inspect the new Panther/UnattendGC and WinSAT session before another change.

## Retry: cached answer did not skip account creation

User confirmed a boot after the previous repair still displayed account creation.
Returned Intel (now disk 8, same disk/partition GUIDs) retains the `test` SAM account
and the modified Panther answer. SYSTEM/SOFTWARE changed, while Panther/WinSAT
logs remained identical to the saved session; those logs alone cannot disprove
the user's boot. `Setup/Status/ChildCompletion/setup.exe=3`, OOBEInProgress=1,
SystemSetupInProgress=0, SetupType=2, CmdLine=`oobe\windeploy.exe`.

Static inspection of the installed msoobe.exe identifies a direct RegGetValueW
read of HKLM `SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE`, DWORD
`SkipMachineOOBE`. At VA 0x10003ffaf a value of 1 takes the branch through native
finalization and WinSAT handling to the common exit, bypassing the interactive
account path. The cached answer had not resulted in this registry value.

Recovery v2 adds `C:\USOS\end.exe`, a Vista 6002-only helper. Before changing
anything it checks OOBE/setup phase, completed setup child and an enabled `test`
account through NetUserGetInfo. It sets/flushes/verifies MOOBE=2 and the native
SkipMachineOOBE=1, restores the original windeploy CmdLine, then launches and
waits for native windeploy. It does not clear Setup/OOBE flags or edit accounts.
Diagnostic log: `C:\USOS\oobe-resume.log`. This is existing-install recovery only;
it is not included in USB support for fresh installs.

Backup/build: `artifacts/vista/oobe-resume-20260921-190133`.
Zig compile and bounded hive checks passed; complete logical comparison of
SYSTEM found only Setup/CmdLine changed to `C:\USOS\end.exe`. Dirty input and
repeated patch attempts are rejected. CHKDSK corrected the volume bitmap (exit 1),
zero bad sectors, dirty flag cleared. Hardware OOBE completion remains unverified.

## Hardware confirmation and installer v8

User subsequently confirmed recovery v2 passed to the desktop. That confirms
the native SkipMachineOOBE recovery for this existing installation; it does not
validate interrupted-install recovery for a new installation.

Installer v8 expands the separate OOBE gate without changing the 13 frozen USB
payloads. A temporary child process subscribes to Setup registry notifications
before the USB bootstrap runs. Once native Windows enters OOBE with setup.exe
completed, it preserves a gate entry for the next boot, replacing only the known
native CmdLine. It never forces SetupType or completion flags. After native
Windows clears OOBE/setup progress, the watcher restores the native entry if
needed and exits. There is no timer polling, installed service or scheduled task.

On resumption, the gate requires Vista 6002, phase 4, OOBE active and completed
setup.exe. No non-builtin account means the normal first-user wizard. Exactly
one enabled/unlocked non-builtin account plus its matching creation and successful
mandatory tasks in the last Panther OOBE session permits the same native skip
used by recovery v2. Multiple accounts, disabled/locked accounts, failed account
enumeration, missing completion evidence, oversized or NUL-corrupted logs stop
with a diagnostic instead of asking for another user or declaring success.
The account name is discovered through NetUserEnum, never hardcoded to `test`.
Windows itself still finishes OOBE. No accounts are created/deleted by USOS.

Logs live beside the helper in `USOS/oobe-prep.log` and `USOS/oobe-watch.log`.
This covers an interrupted **late OOBE** whose required work was durably logged;
it is not recovery from arbitrary storage damage or failure halfway through
mandatory account/configuration work. A notification race or power loss before
the resume entry is flushed is not claimed to be covered. Do not deliberately
cut power to test it; no VM or E2E test was run.

Validation: Zig built the Vista gate and WinPE installer; short production-policy
checks cover a real successful OOBE log, different account names, a later partial
session, failed mandatory tasks, incomplete/empty/NUL logs, initial account
creation and ambiguous accounts. A saved fresh target SYSTEM passes entry-state
checks. Payload hashes, CPIO uniqueness/capacity and Intel profile verification
passed. The next physical check is a complete fresh install from the updated USB.

## Fresh installation confirmed; v8 USB published

The user confirmed a complete fresh USB installation succeeded before v8 was
published. This validates the previous v7 USB path on the physical machine,
including the automatic WinSAT bypass. It does **not** validate v8's new
interrupted-OOBE recovery, which was still local during that trial.

V8 was then deployed with successful hash readback and unchanged partition
layout. Backup: `artifacts/vista/usb-install-update-20260921-212210`.
Vista support SHA256:
`6a3aa7f12a1a2cd581e91e5e19e9092c4b58fb47131dc1493bd23abe5ea4a2fb`.
Common support and BOOTX64.EFI remain unchanged. Full clean installation and
existing-account manual recovery are hardware-confirmed; automatic interruption
recovery remains a separately unverified feature. No intentional power-cut test
is requested.
