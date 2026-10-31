<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# MiniOS review 3 (2026-10-28)

## Capacity

Historical host-DISM capacity/authorization code was archived outside the
repository. Production code has no exception values or MAX_CAP mutation.
Normal policy is a pool of at most 150 GiB and at least 100 GiB free, plus
the remaining declared growth. A pinned capacity plan must now contain an
explicit whole-case reservation. No reservation is injected from a receipt.
The image and auxiliary technical bounds remain separate; they are not a
capacity authorization. Host DISM mutation remains blocked.

Both diagnostic jobs must provide capacity_plan and capacity_plan_sha256.
Old jobs/plans using the spent authorization do not silently become new plans.
The capture helper and host runner also use the normal preflight without auth.

## Executable policy

The bounded host process helper admits exactly two full paths:

- dism.exe in Environment.SpecialFolder.System;
- python.exe at the explicit path whose SHA-256 is pinned by the job.

No PowerShell, command shell, PATH search, implicit extension or other
executable is permitted through this helper. The retired static Run entry
always refuses. RunAllowed uses an immutable per-instance path allowlist.
Each path is drive-absolute, has trailing dots/spaces trimmed per component,
and passes GetFullPathNameW before an ordinal case-insensitive comparison.
ADS, device/UNC paths and tilde short-name aliases are rejected. Rejecting
8.3 aliases is intentional; use the full long interpreter path.

The executable is deny-write/delete locked across process creation and the
wait. Its final handle path must match; Python bytes must match the job SHA.
The requested process is launched using that normalized full path. The
existing mutation blocker is independent and is not unlocked by this policy.
Tests do not execute DISM or bcdboot, nor read host BCD or NVRAM.

## CPU diagnostic profile

The profile is named max-no-xsave-avx-avx2-avx512f, matching the exact QEMU
CPU argument max,-xsave,-avx,-avx2,-avx512f. It remains an opt-in diagnostic.
The former shorter profile name is not an active alias. A fresh checkpoint
probe, if run, uses boot-review-20261028, never a TCG child, WHPX only,
with a whole-operation bound of 25 minutes. A screenshot must visibly show
OOBE before declaring QEMU-only Windows success.

## Integration

Master integration is by selective cherry-pick of MiniOS paths, including
1381f4fa and this review's removal of the remaining host-DISM exception.
Never merge the branch history: 89cb5d00 contains the removed capacity exception.
Do not reintroduce Microsoft SYS/CER files or acpi.sys. No merge, push or
media deployment is part of this review.

## Provenance

These are original changes to the project's own capacity checks, runner and
public Win32/.NET path/process API wrappers. No additional internal NT
mechanism was implemented and no new NT5 source extraction was necessary.
Earlier NT5 references are preserved, not copied into this implementation.
No Microsoft binaries or signing material are added to git or outputs.
