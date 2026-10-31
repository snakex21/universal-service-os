# MiniOS 1c4: bounded MFT cache

The offline single writer caches 1024 logical, MST-unprotected FILE records
in 256 sets of four ways. The tracked allocation is exactly 1,064,960 bytes
on the tested x64 host; entries contain no pointers or growing containers.
Record number, rather than a physical address, is the cache key, so appended
fragmented MFT extents do not invalidate the mapping. No new CPU instruction
requirement is introduced; the firmware target remains i486 for IA32/BIOS.

New files and directories assemble their metadata and DATA/index attributes
in memory before storing the complete base record. Later metadata changes
overwrite that logical cached record. Dirty eviction and explicit drain write
only the latest record. `Ntfs.deinit` and cache deinit perform no disk IO.

## Durability and failure boundaries

- Records 0..26 bypass the cache, including `$MFT`, `$MFTMirr`, `$Volume`,
  the eight reserved MFT continuation records16..23, and metadata indexes.
- The cache is enabled only after format's initial dirty volume, metadata,
  indexes and allocation bitmaps have reached its final disk flush.
- The raw record writer protects a separate copy. A failed write cannot
  leave the caller's or cache's logical record MST-protected. Primary and
  mirror use the same protected bytes for records0..3.
- Attribute-list continuations are drained before their base is published.
  An updated base is drained before old list/extension storage is released.
  A resident-empty directory base is drained before its index storage is freed.
- MFT growth still initializes only the newly appended record range directly.
  Independent bootstrap validation reads the durable base and its previously
  reachable continuation mapping; it does not read from this cache.
- Released record slots replace the cache entry with an empty record and an
  incremented sequence before bitmap release. Only the record allocator's
  cursor moves back for cheap exact reuse; the volume cursor remains forward.
- Any failed cache read/writeback poisons the filesystem. A failed drain
  preserves its dirty entry and `finish` cannot clear the volume dirty bit.
  `markIncomplete` bypasses this cache and writes/flushes dirty `$Volume`
  directly, including after failure of the final flush following a clean write.
- `finish` drains records after its last metadata/index and bitmap updates,
  flushes the disk, then writes and flushes the clean `$Volume` marker.

This is an offline builder, not a journal or recovery protocol. Target disk
adapters must retain ordered read/write/flush semantics; downstream write
combining is a separate layer and must honor these barriers.

## API and counters

`flushMftRecords()` is an explicit record publication barrier, including for
independent raw readers during tests. `mftCacheStatistics()` returns hits,
misses, stores, writebacks and dirty evictions. The three `statistics()` fields
`mft_record_reads`, `mft_record_writes`, `mft_mirror_writes` count attempts in
the raw record helpers at the Ntfs→Disk layer. They exclude bulk initialization
and the independent bootstrap reader. They are not physical BlockIO counts
when a lower layer combines operations.

## Closed development verification

The isolated ReleaseSafe regression passed 60/60 tests, covering the new
cache tests plus existing scaling, preflight and WIM NTFS feature tests.
It ran with two compiler jobs, BelowNormal priority and a two-CPU affinity.
This is a development-source result, not the final integrated firmware gate.

The actual byte-addressed backend measured **2100 ordinary record reads and
2100 ordinary record writes for 2100 resident32-byte files**, across six MFT
growths and more than two cache capacities. It observed 4200 cache hits,
1076 dirty evictions and a 1,460,328-byte tracked allocator peak. These counters
classify real1024-byte backend requests in physical MFT runs; the assertion
does not substitute self-reported cache counters for IO. Special records,
bulk initialization, index IO and disk-backend memory are accounted separately.

Other passed cases include dirty writeback failure, a failed final disk flush
followed by durable redirty, abandonment without IO, delete/reuse sequences,
fragmented MFT bootstrap, 17,000-run attribute lists, second bitmap pages,
5GiB data boundaries, mirror equality and security/ADS/hardlink/reparse metadata.
Raw-reader fixtures now issue explicit publication barriers; fragmentation
fixtures explicitly choose freed holes without changing production allocation
policy or weakening the fragment/reuse assertions.

No VM, physical disk or retained image was opened for this code-level piece.
Whole-application16MiB budget, final firmware instructions and Windows
validation belong to the final integrated1c4 gate.
