<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Isolated BIOS installation client

The experimental client is built by `tools/minios/build_bios_install.py`.
It uses private copies of the BIOS assembly thunk and bootstrap. The tracked legacy stage1,
bootstrap, core and disk-order sources remain unchanged; the build records
their SHA-256 hashes. The installation-only slot is272 KiB:16 KiB bootstrap
and at most256 KiB payload. The general legacy slot remains256 KiB with its
240 KiB payload limit. No installed disk or existing boot menu uses
this client automatically.

The private bootstrap changes only `SLOT_BYTES` and `SLOT_SECTORS` with
single-occurrence anchor checks; stage1 still loads32 bootstrap sectors.
The installation slot occupies LBA64 through607, below configuration LBA1024
and diagnostic LBA1025. A fresh packer module receives the installation slot
size locally; its file and the shared assembly stay byte-identical. Header
and content CRC-32 remain unchanged. The linked ELF must retain entry/load
address0x20000, BSS below64 KiB and its end at or below0x60000. Sector-rounded
payload loading must also end at or below0x60000, where the PM stack reserve
begins. These additional checks preserve the original linker assertions.

The CPU target is explicitly i486, without SSE or CMOV. The assembly audit is
run before linking. Hardware entropy instructions are guarded by CPUID and
feature tests; QEMU fw_cfg is accessed only after QEMU detection. Layout IDs
use the same `Ids.fromSeed64` policy as the UEFI client.

## Explicit source and target

The test boot disk is BIOS drive 0x80. Configuration occupies its LBA 1024;
bounded diagnostic logs occupy LBA 1025 through 2047. The source is drive
0x81, read-only, and the target is drive 0x82. No drive is selected by scanning
for a convenient empty disk. The source and target EDD sizes must exactly
match configuration. The source NTFS serial and partition bounds are pinned.
The target must contain the exact authorization marker; the common installer
also verifies that all other bytes are zero before partitioning.

The source file is `INSTALL.ISO` at the NTFS root. Its expected byte size is
pinned. ISO reads stream through the NTFS and optical readers directly into
WIM apply, without an intermediate copy. Source write callbacks refuse every
write, and read/write counters are logged. Both 512-byte and 4096-byte source
sectors are translated to byte offsets independently of optical 2048-byte
blocks. EDD transfers are bounded to 127 sectors and less than 64 KiB;
4096-byte sectors use at most 15 sectors per transfer. Partial-sector target
writes use read-modify-write. The current NTFS writer requires a 512-byte
target; 4Kn targets must be refused before writes by the common installer.

## Configuration layout

All integers are little-endian in the 512-byte configuration sector:

| Offset | Size | Meaning |
| --- | --- | --- |
| 0 | 16 | Magic `USOSPREP BIOS I1` |
| 16 | 4 | Mode, 1 = MBR |
| 20 | 4 | Boot sector size, 512 |
| 24 | 8 | Exact target byte size |
| 32 | 64 | ASCII hexadecimal authorization token |
| 96 | 8 | Exact source byte size |
| 104 | 8 | Source NTFS partition byte offset |
| 112 | 8 | Source NTFS partition byte size |
| 120 | 8 | Source NTFS serial |
| 128 | 4 | Drive bytes 0x80, 0x81, 0x82, 0 |
| 132 | 4 | WIM image index, nonzero |
| 136 | 4 | Source sector size, 512 or 4096 |
| 140 | 4 | Target sector size, 512 or 4096 |
| 144 | 8 | Exact ISO file size |
| 152 | 356 | Reserved, all zero |
| 508 | 4 | CRC-32 of bytes 0 through 507 |

## Resource measurements and validation status

The client reserves a 12 MiB E820 heap and logs physical and tracked peaks.
It fills the protected-mode stack reservation with a sentinel and reports
the measured high-water mark after apply; a 4 KiB guard is required. The
real-mode BIOS stack is separate. These are measurement mechanisms, not a
claim of an executed firmware gate. QEMU boot/apply results, minimum tested
RAM and final artifact hashes belong in the final validation report.

The object-section diagnostic helper records exact ELF section sizes and
hashes even when the linker refuses an oversized image. Pre-link object sizes
include compiler-runtime sections which can be discarded by the linker, so
they are not a substitute for a successful unchanged memory/packer gate.

Host regressions cover configuration CRC, reserved bytes, disk-role changes,
extent overflow, private thunk patch anchors, sector bounds, and malformed
ELF diagnostics. Constructor and WIM metadata pointer-output refactors keep
validation errors in small error unions; public value-returning wrappers
retain their existing API. Metadata indexes use constant-space heap sort;
their complete ordering is compared with the previous stable sort, while
duplicate keys remain rejected by the existing index builder.

## Actual firmware harness

`tools/minios/bios_install_case.py` prepares and runs only the MiniOS client.
It requires accepted, matching ISO/7-Zip, source-pack, WIM tree/security and
final firmware hash pins before creating any image. The owned source RAW
stays read-only and locked; its IDE frontend receives a new retained QCOW2
overlay because QEMU's IDE hard disk requires a writable backend. The guest
adapter still refuses source writes, and both a zero source-write counter
and an unchanged source RAW hash are mandatory for acceptance.

The boot, source and target drive order is explicit. Blank and prepared
target checkpoints and every overlay remain available. The guest process
is waited on through its completion handle, with a bounded timeout and no
progress polling. Success requires the BIOS layout/apply markers, stack
guard, zero live allocations, actual target writes and no failure marker.
The result uses `minios-install-firmware-v1`; independent native Windows
checks and the first Windows start remain separate gates. Defaults are a
16 GiB virtual target and i486 with 32 MiB RAM; these defaults are not a
claim of an executed full firmware test or minimum proven installation RAM.
