# Isolated usosprep 1a proof of concept

This is a new, standalone Zig program. It is not wired into the USOS menu,
installer, micro-Linux or an installed operating system. It only prepares an
explicitly marked, separate QEMU target. Stage1b/WIM is not implemented here.

## Storage and memory

`src/prep/platform.zig` provides byte-offset `u64` storage callbacks, checked
bounds, flush and a tracked allocator. The core contains no UEFI or BIOS calls.
`partitions.zig` creates an aligned Basic Data GPT partition with primary and
backup CRC32 tables/headers, or an MBR07 partition. Existing GPT headers are
cleared in both modes. Disk writes never use a host physical-device interface.

The NTFS builder uses 512-byte sectors, 4096-byte clusters, 1024-byte FILE
records and 4096-byte INDX records. Metadata and ordinary data are emitted in
bounded chunks. Dynamic buffers are:

| Buffer | Bytes |
| --- | ---: |
| Copy, fill and readback scratch | 262144 |
| Generated BMP uppercase table | 131072 |
| Current-directory cache,4096 keys (UEFI ABI) | 2424832 |
| Total core allocations (UEFI ABI) | 2818048 |
| Total core allocations (BIOS i386 ABI) | 2801664 |
| Dedicated UEFI call stack, including stack-local IO/hash buffers | 1048576 |
| UEFI allocator peak, including that stack | 3866624 |

The stack's lower4096-byte canary is checked before freeing it. The counter
measures requested allocations; it does not include firmware-owned memory,
pool overhead, code/readonly sections or QEMU host memory. BIOS uses the
unchanged low-memory firmware thunk buffers and an E820-checked fixed heap;
its allocator peak excludes the low-memory stack. See the platform note.

## NTFS construction

The formatter emits NTFS3.1 volume information, BPB and backup boot sector,
MFT and first-four-record mirror, clean version1.1 restart pages in `$LogFile`,
`$AttrDef`, root `$I30`, volume/MFT bitmaps, `$BadClus`, `$Secure` indexes and
mirrored descriptor data, `$UpCase` and `$Extend` quota/object/reparse indexes.
All FILE/INDX/RSTR sector fixups are generated, checked on own reads and tested
for torn writes. There is no copied Windows boot code: the volume boot stub
halts, and booting the prepared volume is outside stage1a.

The canonical system record sequences follow the public mkntfs layout:
records1..23 use their record number, record0 and ordinary files use1. Full
64-bit parent/index references carry the matching sequence. Reserved metadata
names use combined Win32+DOS namespace; ordinary files and directory index
keys use POSIX namespace0. They do not claim to have8.3 aliases. The accepted
gate is `chkdsk X:` with no switches on a read-only VHD, plus exact file IO.

The writer accepts streamed sources and supports resident data (up to128B)
and nonresident contiguous data with signed positive mapping pairs. It grows
the MFT in powers of two within a reserved address range and updates both
bitmaps and mirror. `$UpCase:$Info` contains the32-byte information record
and CRC64 of the complete uppercase table. `$Secure:$SDH` entries contain
their canonical `0x00490049` discriminator; descriptor records in `$SDS`
are aligned to16bytes, without an extra16-byte tail at EOF or its mirror.
It accepts one timestamp for the four basic NTFS time
fields, plus a default shared descriptor or a bounded supplied self-relative
descriptor. The deterministic test timestamp is2020-12-30; this is not a claim
that ESP source timestamps have been copied.

The current directory's bounded key cache is sorted through the generated
`$UpCase`. On switching/finishing a directory it is rebuilt into a balanced,
uniform-depth allocation tree, promoting median entries rather than
duplicating separator keys. A resident root points to INDX nodes with correct
index bitmap bits. This is an offline bulk builder, not an incremental live
filesystem with journal replay. Six maximum-length keys fit each leaf; the
binary fanout deliberately favors simple bounded code over disk density.

Limits are explicit errors:4096 entries in the edited directory,8192 MFT
records,512-byte sectors, no fragmentation/append/delete/compression/reparse
creation. Sparse mapping is only used for the special `$Bad` metadata stream;
it is not general sparse-file support. The fresh volume remains dirty until
`finish()` has emitted the final indexes and flushed. Writing again after
`finish()` is refused. Power-loss recovery and concurrent mounts are not
supported or tested.

## Independent verification and earlier failures

`host_case.py` and the firmware harness produce generated fixtures:1000 small
files, nested Unicode names, a255-unit name, an empty file, a128MiB+123B file
and a supplied-security file. SHA256 readback in the builder is only the first
check. Independent host NTFS-3G and Windows read-only verification operate on
separate, explicitly hashed copies after QEMU exits. Every firmware attempt
starts from new qcow2 overlays; no active disk is copied.

The first host run exposed an inferred narrow integer during MFT growth;
explicit `u64` capacity fixed it. The independent oracle then rejected a run
of32769 clusters: its signed positive mapping length needed an extra00 byte.
The unsigned own reader had missed that defect; a regression test now covers
the sign boundary. `$Bad`'s special allocation field was also aligned with the
public formatter, but that change alone did not resolve Windows1393.

Firmware tests exposed two independent platform issues: OVMF had connected
only the boot SATA port, so recursive PCI-storage connection is now explicit;
and a reset after partitioning disappeared when the bounded private stack was
used. IA32 COFF additionally needed the MSVC u64 division ABI exports which
Zig0.16 emits for Windows but not UEFI; the own bitwise Zig implementation is
tested against native full-range u64 arithmetic. None of these observations
is a physical-machine PASS.

The correction pass exposed additional Windows compatibility defects which
the Linux read-only oracle had accepted. Matching the131072-byte uppercase
table alone was insufficient: missing `$UpCase:$Info` made chkdsk use its
default table. After adding the CRC64 information stream, chkdsk still
returned3. An empty-volume control isolated this from user files and MFT
growth. The final fix supplies the `$SDH` discriminator and corrects an
over-rounded `$SDS` length (160 instead of144bytes per test descriptor).
Trimming those16extra bytes on a separate diagnostic copy changed the
read-only check from exit3 to clean exit0. Changes to logfile filling or
per-record descriptors did not resolve the problem and were not adopted.
The full format/write/read unit test checks these metadata values as well
as ordinary file contents. The final six independent firmware cases are the
acceptance results; earlier failed attempts remain in the runtime evidence.

Final command transcripts, actual exits, firmware hashes, RAM matrix,
read-only oracle results and cleanup receipts are recorded in the separate
requested `RAPORT-MINIOS-ETAP1A.md`. A native NTFS mount and file read are not a
replacement for a clean read-only `chkdsk X:` result. `/scan` is deliberately
excluded: it requests VSS on the write-protected test disk.

The2026-10-24 correction matrix passed all six64MiB runs: UEFI x64, UEFI
IA32 and BIOS i386, each with GPT and MBR. Each independently read exactly
1005files/3directories with matching names, sizes and SHA256 in NTFS-3G and
Windows. Each Windows read-only chkdsk (no switches) returned0, with the
actual argument resolved to the exact virtual image disk immediately before
launch. A freshly generated mkntfs control also returned0. The completed
index is `docs/minios-evidence-1a.json`. This is QEMU-only acceptance, not
physical-machine testing or approval to integrate the installer.

## Sources and provenance

No local NT5/Microsoft source was opened or copied for this implementation.
Public sources actually consulted:

- [Linux-NTFS Documentation0.6](https://flatcap.github.io/linux-ntfs/ntfs/),
  for record, attribute, index, security and logfile formats.
- [ntfs-3g pinned commit7f0f841fc52cf719106c5c93bafe465004e36816](https://github.com/tuxera/ntfs-3g/tree/7f0f841fc52cf719106c5c93bafe465004e36816),
  `mkntfs.c`, `layout.h`, `logfile.h`, `sd.c`, `unistr.c` and generated
  `attrdef.c`, as GPL2-or-later format references. Metadata initialization
  choices informed by these references are credited in the Zig source;
  this project distributes its own code under GPL3-or-later. No C library is
  linked into usosprep.
- `$UpCase` now adapts the pinned ntfs-3g `ntfs_upcase_table_build` rules
  for Windows6.1, with GPL2-or-later attribution in the generated Zig source.
  It replaces the earlier generic Unicode3.2 simple-uppercase table. The
  full131072-byte LE result is checked against an independent mkntfs oracle:
  SHA256`41c26bc7a12bdaeb26025c93118697c7e3ef81ee048b00fe5cce2a472e0e0742`.
- [UEFI2.11 GPT layout](https://uefi.org/specs/UEFI/2.11/05_GUID_Partition_Table_Format.html),
  plus the Zig0.16 bundled UEFI protocols and compiler ABI definitions.
- [Microsoft's public reserved NTFS names](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-fscc/b04c3bd0-79dc-4e58-b8ed-74f19fc2ea0a),
  as a metadata coverage cross-check.

The host-only oracle uses the existing pinned Alpine package cache. Those
Linux binaries, firmware, compiler, generated filesystems and test images are
not part of the implementation and are not committed.

## Identity entropy and the next-stage boundary

GPT disk/partition GUIDs, MBR signatures and NTFS serials receive independent
bytes from a platform entropy provider, not a target marker, clock or constant.
The host backend uses system `randomSecure`. Each QEMU run gets fresh64-byte
host OS CSPRNG input through `opt/usosprep-entropy` fw_cfg. fw_cfg only transports
entropy; it does not create it. Missing entropy fails before disk writes. This
POC is not a hardware entropy solution for a physical486/UEFI machine.

Stage1b has NOT started. Before WIM decoding, its plan must rebuild NTFS
allocation/indexing to handle at least100000 files with bounded RAM, reusable
freed clusters/records, fragmented and large files, multiple runlist extents
and `$ATTRIBUTE_LIST` overflow. Directory indexes need incremental B+tree
insertion/splitting and on-disk lookup rather than the4096-key cache/rebuild
strategy. Tests must cover create/delete/reuse, fragmented runlists, >4GiB
streamed data, attribute overflow and100000-file directories, independently
checked by ntfs-3g and read-only Windows chkdsk at64MiB guest RAM. Only after
that gate may the WIM reader and decompression work begin.
