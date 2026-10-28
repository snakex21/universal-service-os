<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Host DISM control: executor design, execution blocked

This describes a prototype executor and a synthetic identity model. The runner
was executed on a virtual image on 2026-10-27: the initial run at `76abcd78`
stopped after GPT initialization, and the resumed run at `a8ca4700` applied
the WIM successfully but bcdboot failed with exit 183. The preserved results
and logs are in `1c7/host-dism-538d709d-91fb-4e74-a43b-8a123e253760/`.
Those runs and successful synthetic tests do not
validate the Windows APIs, prove the absence of races, prove a storage limit,
or demonstrate DISM and bcdboot success. Independent review is required.

## Hard blockers

* A fixed VHDX's leave-blocks-allocated flag and its currently allocated bytes
  do not establish an enforced upper bound on future host-file growth. The
  available local SDK headers and bundled QEMU documentation do not establish
  that bound for writes performed by the Windows virtual disk driver. No
  host-side cap has been proved. The user authorized a conservative 33 GiB
  image budget and checks at phase boundaries for this specific test; these
  checks cannot prevent growth beyond the budget within one phase.
* Exclusive creation and the exact file identity must survive handoff to the
  VHDX creator. A path-based `qemu-img create` cannot by itself prove that a
  file was created with `CREATE_NEW` and remained the same file. The prototype
  uses `CreateDirectoryW` for a new case followed by native `CreateVirtualDisk`
  and pins the resulting file. This is not proof against a concurrent actor
  changing entries in that directory; inspect that remaining race in review.
* A Windows virtual disk needs write sharing, so an open handle alone is not
  proof that external actors cannot mutate it. Device-number reuse and private
  DOS alias substitution also need a reviewed race analysis. Absent a way to
  exclude these races, report a blocker instead of claiming safe mutation.
* A raw file constrained by QEMU's bounded block graph provides a potential
  hard boundary **inside QEMU**, not for host `Mount-DiskImage`. Applying
  through an isolated Windows guest may be investigated as a separate approach,
  but is not the user's host-DISM procedure and is not assumed to work.
  Volume-wide quotas or changes to host storage are not acceptable substitutes.

## Intended independent identities

The following observations must be obtained from Windows, not supplied as
trusted command-line booleans or copied from a previous step:

1. Pin the exact new ordinary `.vhdx` file using a kernel handle. Record final
   canonical path, volume serial and file ID, single link count, no reparse
   ancestors, and a no-delete/rename lock. Re-read identity from the handle
   and independently re-open the path before each operation; reject any
   mismatch. Ensure the image was not previously attached.
2. After attach, independently observe exact `Get-DiskImage -ImagePath` and
   device path; resolve `Get-Disk` from that same object, and confirm the
   device path's disk number using a device handle. Pin disk device identity,
   size, sector size and `FileBackedVirtual`. Re-read both associations before
   each mutation; reject boot/system disks, physical buses, read-only state,
   missing or ambiguous mappings, and any identity drift.
3. Verify GPT partition type, GUID, number, aligned start and length; reject
   overlaps and partitions outside the pinned disk. Use a volume handle and
   `IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS` to prove exactly one extent equals
   the target partition. Resolve and check any temporary DOS alias against that
   exact volume before every path-based tool invocation. ESP and Windows alias
   must be distinct and verified. No host directory or host partition is a
   fallback target.
4. Pin the WIM source and independently verify its receipt, size, SHA-256,
   index and deny-write identity. Fresh scratch/output locations must lie in
   the bounded workspace, with no reparse ancestors. Reserve maximum image,
   logs, scratch and overlay, independently for pool accounting and K: free
   space. The user authorized **this host-DISM reference and its firstboot only**
   to use 74 GiB minimum free and 175 GiB pool; the receipt is
   `1c7/host-dism-capacity-authorization.json`, SHA-256
   `5dbdfd344a6aecbda83dce12b85cee042ab1f56f3ba078886ca1bafb5649fd39`,
   including a 36 GiB total operation budget. All other operations retain the
   previous 100 GiB / 150 GiB limits. Recheck and lock that exact authorization,
   identity and scope before each new image; never replace a general safety
   default. At the local read-only measurement K: had 118194851840 bytes free,
   only 83251200 bytes beyond the authorized threshold plus budget; this is
   historical, not a reservation or a claim that the next preflight will pass.
   Compute pool charge from disjoint subtrees and include each existing
   reservation once, then add the 36 GiB only once for this operation. Fail
   for incomplete enumeration, unknown allocation, overlapping reservations,
   or a concurrent writer. The actual enforced maxima must be proven, not
   passed as an unchecked `true` argument.

## Operations and fresh checks

Every row is a separate mutation; repeat all applicable observations above
immediately before the row, and stop on the first failure. Validation following
one row does not authorize the next row.

| Mutation | Additional required guard |
|---|---|
| Create fresh image | Exclusive new identity and proven hard bound before any image writes. |
| Attach image | Exact pinned file and no prior attachment; record the resulting object and disk identity. |
| Initialize GPT | Newly observed exact attached disk is RAW and has no partitions. |
| Create ESP, MSR and Windows partitions | Revalidate mapping and existing GPT geometry before **each** partition creation; reject any unexpected partition. |
| Format ESP or Windows partition | Match disk, partition GUID, type, offset and length; independently validate the single volume extent for the particular target. |
| Add or remove each temporary alias | Match the exact volume device and ensure the alias does not collide with an existing host mapping. Recheck after creation. |
| Apply WIM | Pinned source/index, exact NTFS alias and extent, bounded scratch/logs, output empty; record DISM return code and logs. |
| Run bcdboot | Exact independently revalidated Windows and ESP identities, route without reparse redirection, explicit `/s` and `/f UEFI`; failure is not success. Previous host hive collision remains unresolved. |
| Dismount | Revalidate the exact image-to-disk mapping and remove only aliases proven to belong to this invocation; report cleanup failure, never guess. |

Keep the image and all receipts on failure. A process interruption must leave
an explicit recovery record, but must not auto-dismount a device that cannot be
identified conclusively. Metadata comparison occurs after dismount, on a
deny-write image; first boot uses a separate bounded overlay.

`tools/minios/host_dism_guard_model.py` models some equality/refusal rules on
caller-supplied synthetic records. It does not read operating-system identity,
enforce these rules at runtime, reserve space or dispatch commands. Its tests
are deliberately incapable of touching any disk or device. A real executor
must implement and independently review the missing OS-level mechanisms before
these model rules can become operational safeguards.

## Read-only Windows adapter and hard-blocked dispatcher

`host_dism_file_identity.cs` opens an existing ordinary VHDX read-only with a
handle denying rename/delete, checks its file ID, volume serial, one link,
final path and reparse ancestry, then compares the pinned handle with a fresh
open. Sharing writes is necessary for a future writable disk attachment, but
means this handle cannot exclude another writer. `host_dism_executor.ps1`
contains actual read-only `Get-DiskImage`/`Get-Disk` mapping and GPT partition
checks; it also calls the existing native single-volume-extent and DOS-device
helpers. Those observations are independent of the synthetic model.

The generic dispatcher always throws on mutation. The separate runner now calls
the same fail-closed assertion before its mutating workflow, regardless of
`-LibraryOnly`; phase and cleanup paths repeat the assertion. Read-only job and
resume validation remain available. The growth bound and concurrent identity
races described above remain unresolved, so this assertion must not be removed
or bypassed merely to retry the host workflow. A separate
`host_dism_run.ps1` implements the workflow behind an explicitly pinned job.
It has been run on one virtual image as described above; the unresolved bounds
and race limitations still require review before further mutations. It runs one clean-head job, uses the native
`FULL_PHYSICAL_ALLOCATION` creator, verifies initial fixed VHDX BAT and actual
physical allocation, and applies index 2 to a newly verified file-backed disk.
Every phase has a scoped capacity check and repeats image/disk/partition/alias
identity checks. It uses 1 MiB-aligned GPT: ESP 260 MiB, MSR 16 MiB and the
remaining Windows NTFS. Cleanup rechecks each exact alias and image before
removal or detach, and preserves artifacts on failure.

The job is JSON `minios-host-dism-control-v1` with `head`, `runtime`, `case`,
`plan`/`plan_sha256`, `auth`/`auth_sha256`, `wim`/`wim_sha256`,
`oracle_receipt`/`oracle_receipt_sha256`, `oracle_tree`/`oracle_tree_sha256`,
`python`/`python_sha256`, `volume_guid`, `index: 2` and `virtual_bytes`.
The caller supplies the job SHA separately. The case is a fresh
`1c7/host-dism-<hex-or-hyphen>` under the pinned runtime; the plan and inputs
are locked against write/delete for the operation. Free space is measured at
phase boundaries, not polled. `host_dism_capacity.py` charges the whole 36 GiB
reservation once in the pool and only unallocated remainder to free space.

DISM's `/ScratchDir`, `/LogPath`, `TEMP` and `TMP` point inside a uniquely named
directory on the fresh destination NTFS. A pinned independent WIM tree must
exclude that root name first. After DISM and bcdboot, the runner copies at most
64 MiB of the DISM log, verifies the exact virtual volume and removes only that
temporary tree after rejecting reparse entries. Child stdout/stderr share a
hard 64 MiB cap and timed blocking wait; the remaining 3 GiB host-side case
budget includes those logs and a later overlay.

`CreateVirtualDisk(FULL_PHYSICAL_ALLOCATION)` passed one 16 MiB synthetic
fixture on this host, unlike `qemu-img create subformat=fixed`, which produced a
sparse host file. `qemu-img map` omitted physical offsets, so the collector now
uses validated BAT offsets and cross-checks the map. A separate 16 MiB fixture
with two nonzero patterns matched QEMU's read-only `qemu-io` checks. These are
small-fixture results, **not** proof of VHDMP's future
growth behavior. Point-in-time free-space checks, sharing-write handles and
private DOS aliases do not exclude concurrent writers, alias races, or growth
between phases; the 33 GiB bound on later VHDMP activity is not enforced.
The user authorized the 74/175 GiB scoped budget, not a change to other tasks.

An observed Windows `Initialize-Disk` GPT initialization created an MSR at
LBA 34–32767. The guard now pins its exact type, geometry and GUID; the ESP
starts at 16 MiB, and Windows starts at 276 MiB. This layout differs from the
MiniOS output, so it is a control for boot behavior, not a byte-for-byte GPT
comparison. The initial run stopped before formatting or DISM and retained
the detached VHDX. Its original image hash and primary/backup GPT sector
snapshots are preserved. A narrowly pinned resume path reuses only that exact
image; its new evidence goes into a fresh subdirectory. A read-only validation
mode checks the pinned inputs and capacity before any disk operation. The
subsequent resumed run applied WIM index 2 with DISM exit 0; host bcdboot
with an explicit virtual ESP returned 183 (`0xc0000035`). The image was
detached and retained; the first-start test was later interrupted and did
not establish an OOBE result.
