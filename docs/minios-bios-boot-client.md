<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Separate experimental BIOS boot provisioning client

`tools/minios/build_bios_boot.py` builds a separate i486 artifact. It uses the
private bounded BIOS thunk from the isolated install builder, without changing
the tracked legacy sources, linker memory assertions or 240 KiB payload slot.
The install client's source and artifact are not modified. Own MBR/PBR
templates come from `build_bios_bootcode.py`; Microsoft boot files are read
from the already applied Windows partition at runtime.

This client refuses execution outside detected QEMU. The utility disk is
exactly 4 MiB at BIOS drive 0x80; the prepared target is drive 0x81, with exact
byte size and 512-byte sectors. Configuration is at byte 524288. Logs occupy
bytes 524800 through 1048575. The actual accepted native-layout receipt is at
byte 1048576 and the actual accepted semantic BCD comparison receipt at byte
2097152. That comparison is pinned to the successful real-bcdboot receipt
for the exact same native disk, and both BCD stores are independently reread.
Each receipt is nonempty and at most 1 MiB. The firmware hashes every byte and
compares the result with the configuration pin. Host code must validate all
receipt semantics before constructing the utility disk, as in the UEFI client.
No synthetic success receipt is accepted as a test substitute.

Before provisioning, the target's real MBR signature, both exact partitions,
NTFS serials and primary/backup boot records must match. The existing system
volume must contain only the freshly formatted metadata. The platform write
adapter permits only a complete MBR sector at offset zero and writes wholly
inside the 100 MiB system NTFS partition. Writes into Windows, the gap, or past
the system boundary are rejected before BIOS I/O. The common provisioning
module independently validates the actual layout and inventory before writes.

The common module performs file copies, BCD creation and final own-sector
publication. A successful provisioning run is not a Windows boot result.
Actual execution is gated by accepted 1c-2 filesystems/tree/hash checks and the
real-bcdboot comparison. The first Windows start is a later, explicit QEMU
operation. All images and logs must be retained.

## Binary configuration

All integers are little-endian. Unlisted/reserved bytes must be zero.

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 16 | `USOSPREP BIOS B1` |
| 16 | 4 | Version 1 |
| 20 | 4 | Utility sector bytes, 512 |
| 24 | 8 | Exact target byte size |
| 32 | 4 | MBR disk signature |
| 36 | 4 | Target sector bytes, 512 |
| 40 | 8 | System partition byte start, 1048576 |
| 48 | 8 | System partition byte length, 104857600 |
| 56 | 8 | Windows partition byte start, 105906176 |
| 64 | 8 | Windows partition byte length |
| 72 | 8 | Windows NTFS serial |
| 80 | 8 | Distinct system NTFS serial |
| 88 | 16 | Windows loader GUID, raw Windows GUID bytes |
| 104 | 32 | Layout/native receipt SHA-256, raw bytes |
| 136 | 32 | Semantic BCD comparison receipt SHA-256, raw bytes |
| 168 | 4 | Layout/native receipt byte length |
| 172 | 4 | Semantic BCD comparison receipt byte length |
| 176 | 4 | Host layout gate, 1 |
| 180 | 4 | Host bcdboot gate, 1 |
| 184 | 4 | Drive bytes 0x80, 0x81, 0, 0 |
| 188 | 4 | Reserved |
| 192 | 8 | Nonzero FILETIME for generated boot files |
| 200 | 1 | Locale ASCII byte length, 2 through 32 |
| 201 | 32 | Locale, alphanumeric or hyphen, then zero padding |
| 233 | 7 | Reserved |
| 240 | 16 | Original layout ID: disk GUID |
| 256 | 16 | Original layout ID: Windows partition GUID |
| 272 | 16 | Original layout ID: ESP GUID, unused in BIOS |
| 288 | 16 | Original layout ID: MSR GUID, unused in BIOS |
| 304 | 204 | Reserved |
| 508 | 4 | CRC-32 of bytes 0 through 507 |

All four layout GUIDs and the separate loader GUID must retain their original
valid version/variant and be distinct. Even though MBR BCD devices use disk
signature and byte offset, the full common ID object is pinned unchanged.

The client reserves a 12 MiB E820 heap and records actual tracked/physical
peaks. Its marked protected-mode stack reports high-water usage and requires
a 4 KiB untouched guard. Real-mode BIOS stack use is separate. Unit tests
cover CRC/role/identity corruption, failed host gates, receipt length/hash/I/O
failures and writes at both system/Windows boundaries. Minimum tested machine
RAM and executed firmware results are reported only after the actual gates.

## Closed host runner

`tools/minios/bios_boot_provision_case.py` requires pinned actual preparation,
native, real-bcdboot and semantic comparison receipts before creating its
output directory. The native guard independently validates the readonly VHD,
layout and both successful chkdsk receipts. The runner rechecks the prepared
QCOW2 backing chain against the native receipt, and holds deny-write handles
across the complete guest operation. It rereads both BCD stores independently
and matches their MBR signatures, system/Windows byte offsets and winload.exe
route to the actual native disk. Neither a boolean gate nor a missing proof
can substitute for these checks.

The original BIOS identity object is reconstructed from the retained, pinned
64-byte preparation entropy and the exact common `Ids.fromSeed64` v2 policy.
It must match the actual MBR signature and both primary/backup NTFS serials,
geometry and the single completed preparation log. This reconstructs existing
IDs; it does not generate replacement layout IDs. Only the loader GUID is new.
The preparation receipt therefore must contain `entropy_sha256` and
`entropy_unchanged=true`; an older unpinned receipt is explicitly refused.

The utility is exactly 4 MiB. Configuration is encoded using the B1 table
above, with the actual native and comparison receipt bytes at their fixed
offsets. QEMU sees only utility drive 0x80 and prepared target drive 0x81,
each through its own retained QCOW2 child. Defaults are i486 and 32 MiB RAM;
there is no network or ISO attached. The successful target child gets the
`bootfiles` snapshot, independently of any subsequent Windows start.

The case uses the approved incremental pool guard before output creation,
reserving at most 208 MiB of new retained files in its closed output scope.
The target overlay is bounded to 128 MiB, the utility overlay to 8 MiB. These
bounds and all input hashes are checked after completion. Every raw capture
has an F3 HEAD/clean-tree header; QEMU-owned debug/serial captures are sealed
only after the process completes, preserving all original bytes and recording
that provenance. The process is waited on directly, without progress probes.

The result schema is `minios-bios-boot-provision-v1`, `arch=bios`, `mode=bios`.
It includes target/source pins, original gate paths, immutable input pins,
memory high-water measurements, copied-file hashes and explicit flags that
no physical disk or host firmware entry was touched and Windows was not
started. Unit tests verify rejection policy and ABI encoding using own
synthetic JSON/BPB/entropy fixtures. A host-only test result is not a passed
real Windows provisioning gate.
