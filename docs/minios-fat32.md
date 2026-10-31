<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# MiniOS FAT32 ESP writer

`src/prep/fat32.zig` is a common, platform-independent formatter and minimal
writer. Its on-disk layout follows the public Microsoft FAT specification
v1.03 (2000-12-06), especially BPB, FSInfo, directories and long filenames:
[public specification](https://download.microsoft.com/download/1/6/1/161ba512-40e2-4cc9-843a-923143f3456c/fatgen103.doc).
No Microsoft implementation code or payload is included.

The caller supplies `platform.Disk` and `partitions.Partition` after its
explicit-target, source-device and empty-disk guards. `format` does not select
or discover a disk. The volume serial must come from the platform entropy
provider. A zero or all-one serial is refused before formatting.

```zig
var esp = try fat32.format(target_disk, esp_partition, .{ .serial = serial });
_ = try esp.mkdir("EFI");
_ = try esp.mkdir("EFI/Microsoft");
_ = try esp.mkdir("EFI/Microsoft/Boot");
var output = try esp.createFile("EFI/Microsoft/Boot/bootmgfw.efi", source_size);
while (source_has_bytes) try output.write(next_source_chunk);
try output.finish();
try esp.flush();
```

The formatter writes two mirrored FATs, primary/backup BPB and FSInfo,
a volume label and a root directory. Logical sectors are512 or4096 bytes.
The300MiB ESP used by the installation layout uses one-sector clusters in
both cases. Tests also cover the mathematically valid260MiB FAT32 case.
Unaligned directory cells and stream chunks use bounded sector bounce I/O,
so firmware backends only receive complete logical-sector writes.

UTF-8 paths are validated before lookup. Every component has at most255
UTF-16 code units; long names get standard VFAT LFN cells plus unique legal
8.3 aliases. Non-ASCII alias characters become underscores. Case matching
uses the existing Windows-compatible MiniOS UpCase mapping. Both slash
styles are accepted, but empty components, traversal and invalid FAT names
are refused. At most64 parent levels and65536 directory cells are supported.

This writer is intentionally for a newly formatted ESP: allocation is
monotonic, files are created once, and files must be at most4GiB−1 bytes.
`Volume.openExisting(disk, partition)` resumes only an ESP previously formatted
by this writer. It checks the own OEM/geometry, all boot-record backups,
FSInfo and both FATs before any write. Allocation counters must match the FAT;
the allocated prefix must have no holes or backward chain links. This is not
an arbitrary FAT mount or a substitute for the prior independent whole-tree
gate. There is no deletion, replacement or free-space reuse API.
Only one file stream may be open at a time. Its directory entry is published
after the declared byte count is supplied; stale copied writer handles are
refused. Allocations and slack are initialized with zeros. On a write/flush
failure the volume is poisoned and the caller must stop the preparation
gate. This is not a crash-atomic general-purpose filesystem.

There is no heap allocation in the formatter/writer. Sector scratch is at
most4096 bytes, zeroing scratch8192 bytes, and filename scratch bounded by255
UTF-16 units. Nested call frames must be included in the firmware high-water
measurement; these sizes are not a claim about total machine RAM.

`fat32_tests.zig` checks metadata,512/4Kn bounce I/O, streaming, zero-length
files, Unicode/LFN collisions, directory growth, failure guards and an
independent existing FAT reader, and reopen/append/corrupt-metadata refusal.
`test_minios_fat32.py` is a separate Python
structural/tree/SHA-256 oracle. `test_minios_fat32_case.py` orchestrates the
small302MiB regular images and the native512-byte read-only VHD gate. QEMU's
original sparse VHD and a SHA-256-identical ordinary streamed copy are both
retained; Windows receives only the ordinary, uncompressed, unencrypted copy.
The copy regression uses a real own sparse source and checks source retention,
byte identity, ordinary destination attributes and hardlink refusal. Its
native checker accepts an existing VHD/VHDX and explicit partition geometry,
verifies the exact virtual disk behind its temporary DOS alias, invokes
`chkdsk X:` without switches, removes the alias, and detaches in `finally`.
It refuses an already attached image. No images or fixture payloads belong
in Git; all retained evidence is listed by the final stage report.
