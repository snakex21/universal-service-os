# MiniOS1c4: bounded directory index cache

`index_cache.Cache` retains 32 raw, MST-protected 4096-byte INDX blocks for the
current directory. Pages are allocated on the heap; writes remain write-through.
The payload is 128 KiB. Cache metadata, one `index.InsertHint` and one persistent
4096-byte directory bitmap together are checked against a 144 KiB bound. This
is an additional component budget, not a measurement of whole-program RAM.

`Tree.prepareInsert(name, &hint)` rejects an existing name before DATA/MFT
publication and records the search path and leaf. `insertPrepared(reference,
filename, &hint)` reuses that path only when backend context, directory owner,
revision, root and exact UTF16 name still match. A hint is consumed once, even
on error. A changed or non-identifying backend takes an ordinary fresh insert.
The method returns whether it reused the prepared path, for call-count evidence.

The cache advances the revision on writes, allocation, free, root replacement,
owner switch and error. A freed/reallocated VCN cannot resurrect a cached page.
Only a successful backing write updates the cached copy. Tree-level MST/format
errors also invalidate the cache. Lookup and cache eviction perform no writes.

## Ntfs integration contract

The owner of `ntfs.zig` performs these changes separately:

1. Keep one stable-address `Cache`, initialized with the existing **raw** index
   callbacks. `openTree` uses `cache.backend()`; raw callbacks must not recurse
   through the wrapper. Release its heap pages during Ntfs teardown.
2. Switch/invalidate the cache before discarding or replacing current-directory
   runlists. Invalidate explicitly when raw index bytes are changed outside the
   wrapped backend, including directory collapse and error cleanup. A same-owner
   switch is intentionally a no-op; it does not stand in for invalidation after
   an external write.
3. Prepare the current parent's insertion once before allocating the file's
   data/MFT. Retain the hint until publishing its FILE_NAME entry. Use
   `insertPrepared` when that directory already has an index tree; the initial
   resident-empty directory follows its existing create-tree path. Internal
   mutations, e.g. refreshing a long-name key before inserting a short name,
   safely cause the prepared operation to rescan.
4. Keep a persistent bitmap for the current directory, rather than creating and
   flushing a new bitmap object for every node allocation/free. Flush at the end
   of each public mutation, before switching directory/runlists and at finish.
   Lookup must not become a write or silently flush unrelated deferred changes.
5. `mkdir` already writes the new child's resident-empty root. Remove the
   redundant load of that child followed immediately by reloading its parent.
6. Import `index_cache_tests.zig` in the aggregate test root. Existing backend
   initializers remain source-compatible: new callbacks have null defaults.

## Verification scope

The focused tests compare 50000 insertions against the original lookup+insert
path byte-for-byte, including MST-protected pages and write count. A separate
150000-key permuted workload exercises variable 255-unit names, deletion and
VCN reuse. Negative cases cover duplicate/Unicode names, stale hints, changed
root/owner/backend/name, all backing I/O errors, clock eviction and corrupt MST.
Isolated `zig test src/prep/index_cache_tests.zig -O ReleaseSafe -j2` completed
with 14/14 tests passing (BelowNormal, two CPUs). For the 50000 sequential
insertions the ordinary lookup+insert made 383953 backing reads; the cached
prepared path made 0 backing reads and 193541 cache hits. Both made exactly
56265 backing writes and produced identical protected blocks. Zero backing
reads in this test follows from write-through pages covering that sequential
working set; it is not a promise for arbitrary directories or cold lookups.
The actual x64 cache+hint+bitmap size was 141112 bytes, below 144 KiB.
The 150000-key permuted workload and all negative cases passed too.

These focused results do not claim an integrated Ntfs, Windows or firmware
PASS. The isolated receipt is retained under
`runtime/index-cache-1c4/test01/{completed.json,stderr.log}`.

No changes to on-disk index format or the split/merge algorithm are required.
