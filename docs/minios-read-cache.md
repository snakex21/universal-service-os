<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Bounded firmware read caches

The sequential image-source adapter in `src/prep/readahead.zig` owns at most
1 MiB on the supplied allocator. Its by-value object is below 256 bytes;
large buffers are never embedded on the firmware stack. Its `Input` contract
is a byte size, context pointer and platform-error-preserving read callback.
`Cache.init`, `read`, `reader` and `deinit` allow the common install pipeline
to wrap an immutable ISO source without changing the storage implementation.
There is no global cache, platform dependency or target write path.

On a random miss, the adapter reads only the requested bytes (using multiple
bounded reads if the request exceeds its buffer). After at least 64 KiB of
contiguous successful requests, a following contiguous miss reads ahead at
most one MiB, bounded by EOF. A noncontiguous seek resets this warmup; an
in-window read retains the already valid cache bytes. Small random metadata
lookups therefore do not cause one MiB of source I/O each. Bounds are checked before source I/O using
subtraction, so offsets above 4 GiB work on 32-bit CPUs without overflowing.
Empty reads perform no I/O. A refill invalidates the previous contents before
calling the source, and publishes its window only after success. Source errors
retain their original platform error code, including after partial writes to
the refill buffer.

WIM resources additionally keep an independent offset-table window in
`src/prep/wim.zig`: at most 64 KiB per compressed resource, and only as large
as its actual table. A raw resource or compressed single-chunk resource needs
no offset window. Both 32-bit and 64-bit table entries use the same bounded
logic. The compressed payload may seek far away without evicting the offset
window; adjacent chunk-boundary lookups therefore do not reread tiny offsets
from the source. This does not remove chunk boundary checks, resource SHA-1,
optional archive integrity checks or verification of unselected images.

Focused tests measure upstream callback calls, rather than claiming counts of
firmware or physical disk requests. A synthetic 20,000-chunk resource performs
39,998 paired offset lookups using two source calls with a 65,536-byte cache.
Sequential 1 KiB requests over 3 MiB plus 123 bytes perform 3,073 reads using
67 upstream calls (64 exact warmup reads and three windows) and a
1,048,576-byte cache. The 2,048 random 64-byte reads request and fetch exactly
131,072 source bytes, with no read amplification. A mixed workload of 64 KiB
lookup and 32 KiB payload seeks similarly fetches exactly the requested bytes.
Every output byte is checked
against the independently generated source pattern. Further tests cover
random seeks, a 64-bit table and data beyond 4 GiB, truncated final windows,
upstream errors, cache invalidation and rejected offsets before I/O.

`Resource.progress` is optional. Sequential SHA updates and full resource
verification report successful bytes; a final SHA mismatch cannot report
resource completion. `Archive.verifyAllWithProgress` forwards cumulative bytes
and completed resources, while `verifyAll` preserves the original no-progress
API. The total verification byte count is collected while parsing the lookup
table, with checked addition, without an extra source pass. The progress sink
formats nothing and owns no buffer; the caller decides when to emit logs.

A sequential burst can still prefetch data that a subsequent seek never uses:
32KiB +32KiB +1KiB may read64KiB +1MiB upstream. This is a bounded performance
tradeoff, not an integrity guarantee or a claim of zero amplification for all
access patterns. Isolated random reads remain exact; cached bytes and EOF are
validated independently. The retained real-firmware counters are the authority
for end-to-end IO cost.