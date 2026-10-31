# NTFS metadata contract for MiniOS WIM apply

The writer accepts only a volume newly formatted by the current `Ntfs` instance. It is an offline single writer. The target remains dirty until `finish`; this is not a journal, repair tool, or writer for an existing Windows installation.

## API

- `FileTimes` contains `created`, `modified`, `changed`, and `accessed` as four independent raw64-bit NTFS FILETIME values. `FileOptions.times` overrides the legacy single `timestamp`. The caller maps WIM's three timestamps to this API; the WIM apply policy sets change time to modified time.
- `FileOptions.attributes` preserves Win32 attributes. Directory status is derived from the MFT record: bit0x10 is omitted from on-disk STANDARD_INFORMATION and represented as bit0x10000000 in FILE_NAME. Ordinary names use POSIX namespace0, without a fabricated8.3 alias.
- `registerSecurity(self_relative_sd)` validates a bounded self-relative descriptor and returns an ID>=256. Existing descriptors are deduplicated by the NTFS hash followed by exact bytes; hash equality alone is insufficient. Use `FileOptions.security_id` when creating or updating an inode. The older `security_descriptor` option remains for small legacy resident descriptors; the two options are mutually exclusive.
- `linkFile(parent,name,target_record)` creates another FILE_NAME and directory index entry for one inode, including current MFT sequence references. It does not copy data or security. Directory hardlinks are refused. `removeFile` removes one name; data/ADS/reparse are released only after the last name is gone.
- `writeStream(record,name,Source,options)` appends a uniquely named DATA stream to a file or directory. Names are UTF16 components, without a colon/path. `readStream` reads it by attribute name; the unnamed stream remains accessible through `readFile`. The current API refuses replacing an existing stream.
- `setMetadata(record,options)` updates all four times, Win32 flags and optional security ID/descriptor in STANDARD_INFORMATION and every FILE_NAME. It refreshes every corresponding parent directory index key, including hardlinks. Sparse/compressed/reparse layout flags cannot silently disappear in this later metadata pass.
- `setReparse(record,raw)` accepts the complete little-endian REPARSE_DATA_BUFFER: `u32 tag`, `u16 data_length`, `u16 reserved=0`, followed by exactly `data_length` bytes. Total length<=16384. Only mount points0xA0000003 and symlinks0xA000000C are supported. Both have substitute/print byte offsets and lengths relative to the UTF16 PathBuffer. Symlinks have a flags field0/1 before that buffer. All bounds/parity are checked. The writer emits the REPARSE_POINT attribute, FILE_NAME tag and global `$Extend/$Reparse:$R` index. Unknown tags are explicitly refused.

## Data representations

Sparse DATA is streamed a4KiB cluster at a time. Entire zero clusters become runlist holes; nonzero clusters receive physical allocation. The72-byte nonresident header has flag0x8000, compression unit4, logical allocated size and physical compressed-size field. The sparse representation is retained even when the source contains no all-zero clusters. Empty sparse streams have an empty mapping and highestVCN=-1.

Compressed DATA uses flag0x0001, unit4, and complete16-cluster physical units. Every unit is stored raw (the documented NTFS representation of an uncompressed unit), including zero-padding of the final unit. This preserves compressed-file semantics without claiming a LZNT1 encoder or smaller allocation. A compression attribute on a directory is retained as its inheritance policy. EFS ciphertext is not supported and is refused, rather than emitted as plaintext with an encrypted bit.

Named streams retain their individual mapping names through ATTRIBUTE_LIST continuations; matching kind and VCN alone is insufficient. All sources use64-bit sizes and offsets. No whole-file buffer is allocated.

## Security/index bounds

`$SDS` descriptors are appended in paired256KiB blocks. The duplicate lies at primary_offset+0x40000, both headers name the primary offset, and no entry crosses a block boundary. When the primary block is exhausted, the next primary starts at the following0x80000 pair. `$SDS` grows as a multi-run stream; descriptor payloads are not retained in RAM.

The compact in-memory security entry array is capped at65,536 IDs. An individual descriptor is at most64KiB. `$SII` and `$SDH` are generated as balanced INDX trees with each promoted key present exactly once; `$R` uses the same bounded builder and its own ULONGS collation. Each emitted node is MST-protected. Empty metadata indexes use a resident empty root, with no phantom empty allocated leaf.

Inherited core limits remain: at most8 reserved `$MFT` continuation records16..23, an explicit256KiB ATTRIBUTE_LIST limit, no journal/recovery, conservative validated filename components, and a bounded allocator supplied by the caller. Exhaustion is an error, never truncated metadata. Source integrity/I/O failure prevents a successful clean finish. The final application must abort on any apply error.

## Evidence status

Integration fixes after the initial feature implementation:

- Attribute ordering compares uppercased UTF16 names first, then raw UTF16
  as a tiebreaker, as required by NTFS collation. Windows feature01 reported
  unsorted record0x13A8 and could not open its large ADS. The corrected
  feature02 passed all5014 entries, both hardlink ADS,5001 raw SDs, and
  read-only `chkdsk` exit0. The earlier failure remains in the evidence.
- `setMetadata` accepts root record5 as the one reserved exception needed
  by WIM apply. It retains the canonical `.` namespace3 FILE_NAME and updates
  its self-index key. Other reserved records remain protected.
- The NTFS volume root is also an explicit attribute exception: record5
  retains HIDDEN|SYSTEM (`0x6`) in STANDARD_INFORMATION and FILE_NAME even
  if the WIM root has neither flag. Its Win32 directory attributes therefore
  include `0x16`, rather than the WIM's `0x10`. The original WIM manifest is
  preserved; this difference must be reported as the named volume-root rule,
  never accepted for an ordinary file or subdirectory. All four root times
  and its security descriptor are still restored from the WIM.

  Both real-image applies initially passed native file reads but failed
  read-only chkdsk in record5. Preserving only FILE_NAME flags in build06
  was insufficient. In the separately identified DIAGNOSTIC07, a freshly
  formatted 128MiB image changed only one byte of root STANDARD_INFORMATION
  (`0x00` to `0x06`), leaving the rest of the image and its MST fixups exact.
  Native Windows then reported clean chkdsk exit0; the independent manifest
  comparison found exactly the expected root-attribute difference. This
  isolates the failure without treating a patched diagnostic as a production
  apply PASS. The final source uses this rule before clean finish and needs
  its own fresh final-build acceptance gates.
- Non-NoSpace failures while constructing unpublished DATA, including disk
  I/O and allocator exhaustion, poison clean finish. Fully rolled-back
  NoSpace remains retryable. Dedicated injected-failure regressions passed.

Commit6e54614e has isolated ReleaseSafe gates:22 feature/base tests,24 preflight regressions,24 scaling regressions, with the repeated imported tests counted separately. New fixture `wim_ntfs_tests.populate` creates5,000 unique custom security descriptors, a two-name inode shared across directories, resident/nonresident ADS, sparse/dense/empty files, raw compressed units, a junction and a relative symlink. Raw checks cover security duplicates/block boundaries, link counts/FILE_NAME entries, four timestamps, sparse/compressed headers, and bounded core allocation. Independent Windows read/SHA/chkdsk is a separate acceptance gate; these native unit tests do not substitute for it.

Format references: public NTFS layouts in ntfs-3g commit7f0f841fc52cf719106c5c93bafe465004e36816 (`layout.h`, `attrib.c`, `mkntfs.c`) and Microsoft's published REPARSE_DATA_BUFFER declaration. The implementation is Zig, carries GPL attribution and links no C library. No Microsoft source implementation was copied or translated.
