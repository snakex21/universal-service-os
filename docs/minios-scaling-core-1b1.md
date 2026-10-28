# MiniOS stage1b-1: scalable NTFS core

This change extends the standalone, offline Zig formatter/writer. There is
no WIM code, no installer/menu integration, no journal replay and no live
concurrent filesystem mount. It builds on stage1a's NTFS3.1 metadata,
512-byte sectors and4096-byte clusters. Physical-device selection remains
outside the shared core; only the guarded test backends are used here.

This note describes the implementation and bounded tests. Final host/firmware
acceptance and artifact hashes belong to `RAPORT-MINIOS-ETAP1B1.md` and the
corresponding evidence index. Passing an in-process readback is not a Windows
filesystem-compatibility result.

## Public operations

The existing `mkdir`, `writeFile`, `hashFile` and `finish` contract remains.
New operations are:

- `lookup(parent, name) !?u64`: returns an MFT record number, validating the
  full sequence-bearing reference returned by the directory index.
- `removeFile(parent, name) !void`: removes an ordinary file and its extents,
  attribute-list storage and extension records. It rejects directories and
  reserved metadata records. Directory removal/rename are not implemented.
- `readFile(number, offset:u64, output) !usize`: exact bounded range read,
  with a short result at EOF, for resident and multi-run data.
- `fileStats(number) !FileStats`: size, physical run count and count of
  extension FILE records referenced by `$ATTRIBUTE_LIST`.
- `statistics() Stats`: MFT capacity/run count and allocation, freeing,
  reuse and record-reuse counters. Independent disk inspection verifies the
  physical runlists and mirror rather than trusting these counters alone.

`FileOptions.max_run_clusters` caps each allocator request. Adjacent physical
runs are coalesced, so a request cap alone does not demonstrate fragmentation.
The test workload creates live keeper files interspersed with temporary files,
deletes the temporary files, and writes into those real physical holes.

## Bitmap allocation and reuse

`bitmap.zig` maintains one4096-byte write-back page, not an in-memory copy of
the whole bitmap. A persistent allocation hint scans each bitmap region as
needed, wraps once and reports exhaustion. Freeing lowers the hint. The MFT
record allocator uses the same mechanism with a minimum user record27,
preserving the reserved16..23 range without marking it falsely in-use.

The volume `$Bitmap` determines allocation. Its pending cache is flushed
before the volume is marked clean. Both contiguous metadata allocation and
multi-run file allocation test actual bits; there is no monotonically growing
file-data-only high-water allocator. Released ordinary data and attribute-list
clusters return to the bitmap and can immediately be reused.

Reuse counters maintain a list of released intervals. This diagnostic list
depends on outstanding free intervals, not total directory entries; it is
not the allocation authority. Splitting an interval may undercount future
reuse if diagnostic bookkeeping cannot grow under OOM. It never changes the
real bitmap to fabricate reuse. Raw-image checks and known freed/reused file
locations are the correctness evidence.

## Dynamic, fragmented MFT

The first extent still starts at the BPB's MFT LCN4. Capacity starts at64
records and doubles when the record bitmap is exhausted. New space is
allocated through the ordinary volume bitmap, so the MFT can grow across
non-adjacent extents instead of reserving a fixed8192-record address range.
Every new record is initialized with a proper FILE header, number and MST
fixups in bounded batches.

All record IO maps the logical record offset through the MFT runlist; it does
not assume `LCN4 + record_number/4`. The MFT bitmap grows dynamically as well,
copying into larger metadata storage when its allocation becomes too small.
The MFT's DATA/BITMAP attributes and cached `$FILE_NAME` sizes are updated.
`finish()` replaces only the `$MFT` filename key in the root index, avoiding
the old scan/rebuild of the entire directory.

Writes to records0..3 are mirrored using the same protected bytes at the
BPB's mirror LCN2. Freeing an ordinary or extension record clears its bitmap
bit and advances its sequence, skipping zero. Reused directories/files use
that actual sequence in I30 references and child FILE_NAME parent references;
the original static stage1a sequence helper is only suitable for initial
reserved metadata, not reused ordinary records.

MFT capacity does not shrink after deletion; free record bits are reused.
The volume geometry and on-disk numeric fields still bound maximum capacity.
There is no application limit of8192 records.

## Mapping pairs and large streamed files

`runs.zig` encodes and decodes signed relative LCN differences, positive
sign-padded run lengths, sparse runs and64-bit logical positions. Backward
physical jumps are supported. Every attribute extent starts its own relative
LCN decoder at zero and carries its actual lowest/highest VCN.

Reads/writes translate byte ranges over run boundaries. File copying and SHA
use the existing256KiB scratch buffer; source size and offsets remain `u64`
on IA32/BIOS. No full5GiB file, volume or MFT is buffered. The implementation
retains run metadata for the active file and MFT; extreme fragmentation can
therefore exhaust the configured allocator even when file data is streamed.
It is not a constant-memory external runlist database.

## Attribute overflow

The record packer retains owned attribute descriptions for the one inode being
changed, sorts them by type/name/lowest VCN, and writes a single FILE record
when it fits. Mapping pairs are split into bounded segments when needed.
A nonzero lowest VCN always requires `$ATTRIBUTE_LIST`; continuation extents
are placed in separate FILE records with a full base-record reference.

On overflow the base record receives a nonresident `$ATTRIBUTE_LIST`. Entries
carry the type, name, lowest VCN, full record/sequence reference and attribute
instance. Name offset is26 even for unnamed entries; continuation entry
instances are zero, as required by the public layout. Allocated/data/initialized
sizes are meaningful in the lowest-VCN-zero extent; continuation fields are
zero. Attribute-list data excludes its own attribute.

Extension records and list data are written before publishing the new base
record. Replacing the list releases its old storage/extension records after
publication. The volume stays dirty until final flush; this ordering is not
a power-loss atomicity or recovery guarantee.

The format's256KiB attribute-list value limit is checked. Its own mapping
pairs must fit in the base record. Current replacement allocations for the
attribute-list stream and bitmap metadata require contiguous space, even
though ordinary file data, MFT DATA and directory INDEX_ALLOCATION can be
fragmented. Extreme metadata-only fragmentation is not covered by the tested
workloads and may produce `NoSpace` despite sufficient separated free clusters.

## Incremental directory integration

`index.zig` owns the4096-byte INDX B-tree algorithm. NTFS promotes complete
FILE_NAME keys to internal nodes; separator keys are not duplicated in leaves.
Lookup/insertion/deletion access the search path and siblings rather than
building a directory-wide in-memory array or scanning every MFT record.

The NTFS backend owns INDEX_ALLOCATION runlists, index bitmaps and the resident
INDEX_ROOT. Allocation grows geometrically (at least8 blocks, then doubling),
so inserting each new node does not rebuild a growing runlist. The allocation
hint persists for the active directory, and node deletion lowers it. Loading
a different directory reconstructs only its metadata/runlists, not its entries.

Nonempty trees use a fixed56-byte resident root with an END-child pointer to
the module's root node. Empty directories must instead use the canonical
48-byte resident leaf root without INDEX_ALLOCATION or index BITMAP. The first
insertion allocates a tree on demand. Removing the final key publishes that
empty root and releases the complete backing allocation and bitmap. Merely
pointing at an empty allocated INDX leaf was rejected by native Windows and
read-only chkdsk; it is deliberately not retained.

Partial deletion reuses index-node bitmap slots inside the existing allocation;
the allocation is not shrunk at every merge. Full emptying releases it. Empty
directory lookup, including after `finish()`, does not allocate or write.

## Evidence and known scope

The module tests cover signed runlists, page-boundary bitmap reuse, dynamic
MFT growth beyond8192 records, independent raw first-four-record mirror
comparison, removal of a promoted internal separator, long UTF16 names with
supplied security descriptors and ATTRIBUTE_LIST overflow, and fragmented
5GiB+37-byte range IO across2GiB/4GiB/EOF boundaries. The large unit backend
stores only nonzero pages; the production writer still submits the whole
stream through bounded writes. Native host images and their read-only Windows
hash/chkdsk gates are separate tests.

The completed large host cases passed independent, exact Windows path/size/
SHA-256 comparison and read-only `chkdsk` without switches (exit0):

| Workload | Data bytes | Writer seconds, including in-app verification | Core allocator peak | Physical MFT extents |
| --- | ---: | ---: | ---: | ---: |
|150000 files in300 subdirectories|9830400000|37.098|395328 B|13|
|50000 files in one directory,4096 B each|204800000|3.864|395576 B|11|
|1024 keeper files plus fragmented5GiB file|5435817984|18.338|456888 B|7|

The last file has1025 actual physical extents and8 attribute-list extension
records, independently decoded from the emitted image. The MFT capacities are
262144,65536 and4096 records respectively; all first-four-record mirrors match.
The large-file profile need not grow the MFT past8192, while both many-file
profiles do. The50k checkpoints finish the first25000 entries in1s and all
50000 in3s at whole-second logger resolution; this is measured workload
evidence, not a general asymptotic benchmark for every insertion order.

The host PE has1085440 loaded bytes and an explicit1048576-byte stack reserve.
Counting the whole reserve plus the loaded image and measured allocator peak
gives2529344 B for the150k case, below16MiB. This is the program's conservative
own-memory bound; Windows/host IO runtime and filesystem cache are excluded.
BIOS allocator backing consumption is accounted separately from requested
core bytes: a peak request counter alone cannot prove reclamation in a fixed
arena with arbitrary-order frees.

The empty-directory correction was first confirmed by the closed preliminary
quick-firmware02 case:10257 files/104 directories with exact native Windows
reads/SHA and read-only chkdsk exit0. It is preserved as a preliminary gate,
separate from the three completed large host cases above. The final report
and evidence index also record the independent firmware/CPU/RAM gates; no
physical motherboard is tested by these in-memory/native-file/QEMU checks.

Unimplemented operations include concurrent mounts, journal replay, crash
recovery, append/truncate, rename, directory deletion, general compression,
reparse creation and WIM extraction. A failed operation leaves a dirty build;
there is no transactional rollback promise. The ordinary-file writer is an
offline creation/deletion tool, not a production live NTFS driver.

## Provenance

The new allocation, mapping, packing and callback logic is Zig. No C library
is linked into usosprep and no local NT5/Microsoft source was opened or
translated. Existing generated UpCase/metadata provenance from stage1a remains.

Format references actually consulted:

- [Linux-NTFS Documentation0.6](https://flatcap.github.io/linux-ntfs/ntfs/).
- [Pinned ntfs-3g layout.h](https://github.com/tuxera/ntfs-3g/blob/7f0f841fc52cf719106c5c93bafe465004e36816/include/ntfs-3g/layout.h):
  mapping pairs, nonresident extents, ATTRIBUTE_LIST ordering/instances/value
  limit and FILE/INDX layout. The source is GPL-2.0-or-later and contributors
  are credited in the relevant Zig modules. No Windows binary metadata is
  embedded as an implementation table.
- Existing stage1a code and the unchanged platform storage/allocator contracts.

WIM remains outside this stage. The final report is followed by STOP.
