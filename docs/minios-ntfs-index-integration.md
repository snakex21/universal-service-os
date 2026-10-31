# MiniOS 1c4: integrated current-directory cache

The real target-Disk regression now budgets all reads, writes and flushes
after format, including final MFT/bitmap/mirror durability. For3000 resident
small files it measured12560 calls (4.187/file); the enforced ceiling is
8/file plus1024 calls for growth. These are the byte-addressed test target's
backend calls, not source IO or firmware BlockIo latency.

Ntfs uses the bounded write-through cache and prepared insertion API from
`index_cache.zig`/`index.zig`. The Ntfs implementation owns one stable cache,
one prepared hint and one paged bitmap for the current directory. The raw
backend context is rebound to the current Ntfs address before exposing the
wrapped backend, avoiding a stale pointer when `Ntfs.init` returns by value.

Name validation prepares one insertion before DATA or MFT allocation. After
the complete FILE record is staged, insertion consumes the hint. The index
module checks owner, revision, root, context and exact name; an intervening
mutation safely forces a fresh search. `mkdir` keeps its parent current and
does not load its newly created empty child merely to reload the parent.

The directory bitmap retains its page and cursor between splits/frees. Its
dirty page is flushed at successful public mutation boundaries, before an
owner/runlist change or metadata publication, and at format/finish. Capacity
growth preserves old bitmap bytes before releasing old storage. Cache owner
switches, remapping, directory collapse and failures invalidate cached pages
and prepared hints. Tree and bitmap IO failures poison the builder and prevent
clearing the volume dirty flag. Neither teardown nor ordinary lookup flushes
deferred metadata.

The integration test found and corrected one MFT-cache interaction: a cold
read could previously evict a dirty record. Read-only misses now retain data
only in an invalid/clean way, or return it uncached when all ways are dirty.
Allocation explicitly uses the mutation-read path allowed to evict. Thus a
cold `lookup`/`readFile` cannot cause writeback while the one-read/one-write
new-file budget is retained.

`readRecord`, `writeRecord`, mapped bootstrap reads and explicit MFT drains
have `.mft` timing scopes. Entire prepare/lookup/insert/remove/create operations
have `.index` scopes. The shared profiler subtracts nested MFT/target IO rather
than attributing that time twice. Ntfs statistics add prepared insertion and
directory switch counts plus raw INDX and directory-bitmap callback attempts;
`indexCacheStatistics()` exposes cache statistics separately.

## Closed development gate

The isolated ReleaseSafe gate passed **71/71 tests** with two compiler jobs,
BelowNormal priority and two-CPU affinity. It includes MFT-cache, original
scaling/preflight/WIM NTFS, index-cache and four Ntfs integration tests. This
is a development gate; final firmware/Windows acceptance remains separate.

The byte-addressed backend measured these actual requests for 3000 resident
64-byte files in the root directory:

| Measurement | Result |
|---|---:|
| Prepared insertions consumed | 3000 |
| INDX reads | 8 |
| INDX writes | 3296 |
| Directory bitmap reads | 1 |
| Directory bitmap writes | 142 |
| Directory switches after format | 1 |
| Tracked allocator peak | 1,591,656 B |

The separate 2100-file MFT test still measured exactly2100 ordinary MFT reads
and2100 writes, with a1,591,400-byte tracked peak including both heap caches.
The index component's bounded payload/metadata/hint/bitmap budget is141,112 B
on the tested host, below144KiB; the MFT cache allocation is1,064,960 B. These
are allocator/component measurements, not process RSS or total firmware RAM.

Integration tests also verify duplicate rejection before reading source DATA,
no writes from repeated or owner-switching lookups, equal-VCN owner isolation,
no redundant mkdir switches, propagation of INDX/bitmap write errors, durable
dirty state, and balanced MFT/index timings with a deterministic test clock.
Final whole-application16MiB and i486 instruction gates remain the parent
pipeline's responsibility. No new VM or image was opened for this piece.
