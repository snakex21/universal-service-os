# MiniOS preflight before stage 1b-2

This is an explicitly reopened preflight after the accepted 1b-1 milestone.
It contains no WIM implementation, menu integration or deployment. Earlier
milestones remain historical. The new report is `RAPORT-MINIOS-PRZED1B2.md`;
the portable evidence index records the completed tests and exact hashes.

## Entropy before any write

UEFI tries EFI_RNG_PROTOCOL, then CPUID-gated RDSEED and RDRAND. BIOS tries
CPUID-gated RDRAND. On i486, an EFLAGS.ID test precedes CPUID. The instruction
encodings are present only in guarded functions; the build baseline remains
i486, which is different from claiming that no optional newer opcode exists.
Each hardware word has at most 128 attempts and requires CF success.

The QEMU fallback is a fresh host CSPRNG 64-byte input passed by fw_cfg. Its
ports are accessed only after a positive TCG CPUID signature or a validated
SMBIOS system-manufacturer/product pair. SMBIOS entry checksums, structure
bounds and pointer arithmetic are checked. No clock, marker, weak generator
or unconditional read from ports 0x510/0x511 is used. Failure returns
EntropyUnavailable before sector writes or creation/deletion of a target log.
The host tests exercise source order, failure, unknown-platform rejection and
malformed tables. Physical boards and actual firmware RNG hardware are not
validated by the QEMU evidence.

## Fragmented NTFS metadata and failure limits

Volume, MFT and directory bitmap I/O uses multi-run streams. Attribute-list
storage also uses a stream rather than requiring one contiguous allocation.
An independent sparse-device test exercises each bitmap across separately
located physical pages. The fragmented stress test leaves only isolated free
clusters, constructs 17,000 data runs, reads the list and MFT mapping from the
disk, and checks substantial deletion and reuse with a 16 MiB core budget.

The first MFT DATA mapping remains in its base record. Continuations use only
reserved records 16 through 23 in the initially reachable MFT extent. A reader
reconstructs the mapping incrementally through already known extents; it does
not trust the writer's complete in-memory map. Existing continuation records
are reused. There are deliberately only eight continuation slots; exhaustion
returns NoSpace and retains a dirty volume rather than publishing a cyclic
or unreachable bootstrap mapping. ATTRIBUTE_LIST is bounded at 256 KiB and
its complete stream mapping must fit the base record. These are explicit
format-writer limits, not general support for every fragmented NTFS volume.

Partial allocation failure rolls back the clusters already reserved by that
attempt and the unissued file record. A fully rolled-back NoSpace does not
poison the volume. After an irreversible publication or source I/O failure,
mutating operations and finish reject PoisonedVolume and leave the dirty flag
set. This is not journaling, crash recovery or a claim of transactional
coverage of every possible hardware failure. Reuse-accounting history is
bounded at 4,096 merged ranges; dropped accounting is explicit and never
controls actual bitmap freeing or allocation.

## New acceptance gaps, without another CPU search

The new harness creates separate fresh COWs for BIOS/486 at 2 MiB and for the
150,000-file, 9,830,400,000-byte workload on BIOS and UEFI x64 at 64 MiB. It
waits for completion, exports closed images, independently enumerates and
hashes the exact tree in Windows, runs read-only chkdsk without switches, and
inspects MFT extents and mirror bytes independently. It does not repeat the
previous CPU/RAM bisection. Firmware memory is separate from the measured
program budget. A BIOS/486 no-entropy control checks the complete boot and
target image hashes before and after the expected refusal.

The original acceptance artifacts are preserved with their hashes. A final
malformed-SMBIOS-address guard was subsequently covered by a focused negative
test and compilation; it does not justify repeating hours of valid-firmware
workloads. The evidence distinguishes those build versions explicitly.

Images may be removed only after the completed final report is archived.
Deletion uses explicit owned paths, detached-VHD checks and the same exclusive
file handle for hashing and deletion. Logs, manifests and receipts remain.
After the report this task stops; WIM requires the next authorization.

The large BIOS writer completed, but its first Windows invocation refused
before mounting because two VHD copies would breach the 100 GiB free-space
reserve. Two already closed UEFI VHD files were compressed by NTFS without
deleting them; full SHA-256 checks before and after proved unchanged logical
bytes. The original refusal receipt remains. An explicit `--resume-windows`
performs only a second host-oracle attempt on the pinned, read-only BIOS raw
export, writes a new attempt receipt, and never reexecutes QEMU or replaces
a completed case. The reserve remains unchanged.

## Public references and attribution

- [UEFI EFI_RNG_PROTOCOL, section 37.5](https://uefi.org/specs/UEFI/2.11/37_Secure_Technologies.html)
- [Intel SDM, volume 1, random-number instructions](https://cdrdv2-public.intel.com/868137/325462-089-sdm-vol-1-2abcd-3abcd-4.pdf)
- [QEMU fw_cfg ports, selectors and big-endian file directory](https://www.qemu.org/docs/master/specs/fw_cfg.html)
- [Linux-NTFS MFT bootstrap and reserved extension records](https://flatcap.github.io/linux-ntfs/ntfs/files/index.html#notes)

The existing GPL ntfs-3g UpCase attribution remains in place. The unused
Unicode-LICENSE artifact was removed. No Microsoft source was consulted or
translated for this preflight.

All three new positive cases and the no-entropy refusal completed. The exact
Windows file/SHA tree, read-only chkdsk exit 0 and independent metadata checks
passed for BIOS/486 at 2 MiB and both 150k workloads. The archived final report
preceded deletion of 34 owned files (31 test images/vars and three entropy
inputs); 104 evidence files and both compiled program versions remain. The
portable receipts and cleanup-plan hashes are in
`minios-evidence-pre1b2.json`. This milestone is closed; no WIM work started.
