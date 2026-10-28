<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# MiniOS review 2 (2026-10-28)

Host bcdboot execution is permanently prohibited, including a verified `/s`.
Existing BCD receipts are only read offline. The REGF writer remains the BCD
producer; no host BCD or firmware entry is an installation target.

The one-case bootfiles capacity helper was removed from the branch. A byte-identical
local archival copy has SHA-256
`3ed2baaf89bf73e362544df51b6acda1b227c62b1544e6ef3f07464bb927bf22`.
It records a spent authorization, not a release policy. Normal limits remain
150 GiB for the pool and 100 GiB free on its volume.

## Corrected Windows status

Historical Panther logs indicate completion of the OOBE deployment stage;
visible OOBE is unconfirmed. Neither IMAGE_STATE_COMPLETE nor a successful
msoobe exit establishes a visible OOBE screen or completion of account setup.
The active KOTWICA entry uses this qualified status. All VM results are
**QEMU only**. Full-install/OOBE TCG runs are prohibited in this round.

## Offline exit 183 investigation

Both preserved BFSVC logs (the 1c6 reference and the later host DISM reference)
reach creation of the system store, then fail loading its hive at
`BCD00000000`, flags `0x40`, status `c0000035`. No new execution was performed.
The XP source file `nt5src/Source/XPSP1/NT/public/sdk/inc/ntstatus.h:1946`
identifies that status as STATUS_OBJECT_NAME_COLLISION. The same tree's
`base/ntos/config/cmparse.c:1327` has one collision case when creating a registry
link over an existing key. This illustrates a possible mechanism; it does not
prove that modern BFSVC took that path. NT5's BCD/bcdboot/BFSVC implementation
was not found. A separately named LiberNT nt10 tree is not NT5 evidence and was
not used as a substitute.

The precise failed hive-load operation is established by the logs. Collision
with the already loaded host BCD hive remains a hypothesis: no recorded native
call trace, object namespace snapshot at failure, or matching modern BFSVC
source is available. The logs alone cannot distinguish the exact colliding
object or prove that /s prevented other earlier side effects.
A previously recorded trace with full native call arguments/statuses, or a
trace produced later in an isolated disposable VM, could resolve this.
Do not reproduce it on the host or unload its BCD hive. This round did not read
host BCD or NVRAM; previous before/after exports remain historical evidence,
not a new guarantee concerning the earliest host DISM execution.

This is independently written diagnostic prose; the cited local NT5 files
were used only to identify the status and qualify its interpretation. No
Microsoft implementation was copied.

## WHPX functional gate (QEMU only)

QEMU 11.1.0 e470268ff4 was the locally available version in the checked tool,
cache, Downloads, MSYS, Program Files and package locations. The separate
qemu-cos-e2e binary reports the same version. No downloads or TCG runs occurred.

| Probe | CPU | IRQ chip | Endpoint / result |
|---|---|---|---|
| irqoff | qemu64,-xsave | off | unexpected STOP, VP exit 4 |
| plaincpu | qemu64 | off | unexpected STOP, VP exit 4 |
| maxcpu | max,-xsave,-avx,-avx2 | off | 180 s completed; guest reset; no visible OOBE |
| maxresume | max,-xsave,-avx,-avx2,-avx512f | off | 600 s completed; guest reset; display uninitialized |

The first two stops occurred 6.74 s and 4.80 s after the first RTC event.
The public Windows SDK 10.0.26100.0 um/WinHvPlatformDefs.h:2812 names WHPX exit
reason 4 UnrecoverableException. That identifies the reported exit, not its
root cause. Changing to max avoids that exit; the responsible individual
CPU feature has not been isolated. This is a CPU-model result, not proof
of an NTFS defect or proof that the hypervisor alone caused all failures.

The max case contains a new svchost WinReIsWimBootEnabled entry; most Panther
content is inherited from the older TCG checkpoint. New activity and a guest
reset are not a visual OOBE PASS. Both max endpoints show Guest has not
initialized the display (yet), including after restarting QEMU from the
closed max checkpoint. There is no instruction trace/dump establishing why
Windows reset or why firmware/display failed to reinitialize afterward.

The interrupted old parent passed qemu-img check without repair while locked
read-only. Every real attempt validated its complete backing chain and retained
unchanged bases. A completed checkpoint was used for the final attempt.
Guest endpoints were 180/180/180/600 s, whole-operation bounds 900/1200 s;
all below the 45-minute ceiling. No status/progress queries were performed.
The diagnostic attempts fit within the 60-minute repair budget.

Visible Win11 OOBE remains NOT PASS: historical Panther logs OK, QEMU without
an OOBE screenshot. The WHPX VP exit was avoided but the required functional
gate was not repaired. Per the review fallback, Win10 IA32, Win7 BIOS and
64 MiB are not launched in this round and remain hardware-test items. This
handoff does not assert their hardware success, or that hardware will cure
the Win11 reset/display failure. No hardware mode or media is deployed.

## WIM type 4 follow-up


Status: unresolved, deliberately skipped and counted. The 86,217 recorded
items contain 02 00 00 00. The number 2 alone is not a semantic definition.

Checked local NT5 material: XPSP1 NT/public/sdk/inc/ntstatus.h and the registry
parse implementation for the separate BCD investigation; NT/base/fs/ntfs/
ntfsstru.h and filename inventory for WIM/tagged-item definitions. No WIM tag-4
definition was found. NTFS attribute type numbers are a different namespace.
No ntfs.sys was analyzed. No separately named nt10 source was substituted.

The already reviewed public wimlib include/wimlib/tagged_items.h and
src/tagged_items.c describe Object ID tag 1, EA tag 2 and UNIX extensions,
not tag 4. See the preserved primary-source review from the preceding round.

The real differential collector found all 86,217 selected paths, with no
missing/unknown fields. MiniOS and DISM matched on 58,820 paths; 27,397 differed:
EA 9,454, file attributes 1,227, security 16,924; reparse 0 and ADS 0.
The saved source-classification report assigns ALL differences to MiniOS
matching the raw WIM. DISM removes/changes $CI.CATALOGHINT (tag 2), changes
attributes 0x80 to 0x20, and changes only security control bits (XOR 0x810,
0x10, 0x800) in the classified descriptors. These are not proof of tag-4
semantics, nor a reason to invent new NTFS metadata.

Missing: an authoritative type-4 payload definition or a controlled WIM pair
where only this tag changes and a defined observable effect follows.
Prior Panther logs prove deployment activity, not visible OOBE or total
safety of omission. Preserve F5 as unresolved until the visual gate succeeds.

Provenance: independently written analysis of own MiniOS/DISM comparison
receipts, local NT5 status/structure references and the already reviewed
public wimlib files. No Microsoft code is reproduced here.

## Reviewer integration note (outside the previous task scope)

| Earlier commit | Change / reason | Recommendation for master |
|---|---|---|
| 89cb5d00 | Enforced fixed bootfiles image envelopes and aggregate output limits before writing; added bounds/output helpers and tests. Also added a historical capacity override. | Keep generic safety limits; exclude the capacity override. Apply review removal 1381f4fa as a prerequisite. |
| 6215189a | Connected those limits to image creation, snapshot and capture throughout boot_provision_case, avoiding checks only after writing. | Keep the generic integration with 89cb5d00 and the current normal-capacity policy. Do not restore review_capacity or approval CLI flags. |
| ad47382d | Unexpected QMP STOP immediately ends the endpoint with a screenshot and failure; avoids waiting the full deadline on a halted guest. | Keep for bounded diagnostics. It never sends CONT after a failure or promotes a transport result to Windows PASS. |
| 4c1c955e | Optional wake_display: a Shift press/release once at the final endpoint, then the bounded screenshot; default off. | Diagnostic-only convenience, not necessary for MiniOS production. Retain only if the reviewer wants that opt-in; it does not establish OOBE success. |

Integrate only reviewed MiniOS paths using selective cherry-picks. Do not merge
the branch history wholesale and do not reintroduce tracked Microsoft SYS/CER
files, especially acpi.sys. This round contains no such binary changes.
No integration, push or deployment was performed.
