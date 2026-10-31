<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Virtual target combining and nested timing

`writecombine.Cache.init(allocator, base_disk, backend)` requires an explicit
`raw_file` or `qcow2_file` backend assertion from the pinned virtual-case
caller. Guest BlockIo geometry does not establish the host image format.
The module opens no files or physical devices, and is not an authorization
mechanism for using a physical target.

Its tracked heap buffer is exactly 1 MiB, aligned to 4096 bytes. Adjacent
writes append to one pending interval. A full interval, nonadjacent write or
overlapping update drains the earlier interval first. Reads obtain overlapping
bytes from the pending interval and uncovered prefix/suffix bytes from the
base, without unnecessarily draining. Thus read-after-write works while file
data is combined. Every explicit flush drains pending writes and then forwards
the base durability barrier. Deinitialization performs no storage I/O; a caller
must explicitly flush before accepting success.

Any backend read, write or flush error is propagated and the first error
remains sticky. Uncertain pending bytes are discarded. Subsequent writes pass
directly to the backend so NTFS can restore its dirty marker after a failed
final flush. Subsequent flushes attempt that recovery durability barrier but
always return the original error; the target cannot be accepted as complete.
Recovery writes cannot reactivate combining or replay the uncertain batch.

The unit workload combines sixteen 64 KiB writes into one 1 MiB callback.
Actual firmware requests are a different measurement: a platform adapter that
always splits into 64 KiB bounce transfers will still make those requests
until it supports a correctly aligned large direct transfer. BIOS EDD transfer
limits also remain in effect. Buffering is not reported as a reduction in
physical requests without measuring the platform backend.

`profiling.Profiler` uses an optional `Clock` with a callback returning already
extended monotonic u64 ticks, a nonzero frequency, and a source name. Platform
clock discovery, calibration and wrap resolution belong to the provider.
There is no TSC, CPUID, SSE, CMOV, ACPI access or system clock access in this
common module. Frequencies above UINT64_MAX/1000 are explicitly unsupported,
keeping conversions free of 128-bit division helpers on i486.

Categories are `decode`, `sha`, `source_io`, `target_io`, `mft` and `index`.
`begin(category)` returns a token paired with `end(token)`; nested inclusive
and exclusive tick totals are recorded separately. Child time is deducted
from its parent's exclusive time, including nested calls in the same category.
Every category exposes calls, measured intervals and invalid intervals. There
is a fixed 16-frame stack and no profiler heap allocation or global state.
`filesDone(count)` records completed logical files independently of resources.

An absent/ambiguous sample, backwards tick, unextended counter wrap, depth
overflow or mismatched token is reported as invalid; it is not presented as a
measured zero duration. A provider returning backwards ticks is disabled for
the remainder of that profiler. Unknown child duration invalidates the parent
measurement rather than inventing its exclusive time. Snapshotting performs
no timer I/O. Valid scopes require two clock samples; clock-read counts make
the measurement overhead visible. `now()` optionally samples phase boundaries.
`elapsed_ticks` is absent if the clock has ever returned an invalid sample.

Tests use self-owned byte fixtures and deterministic clocks. They cover exact
read overlays, overlap/backwards publication order, partial writes, failed
flushes followed by dirty recovery, bounds before backend I/O, teardown with
no implicit writes, recursive timing, unavailable/wrapping clocks, overflow
and invalid nesting. Actual firmware/native acceptance remains a separate
gate with preserved images and final clean-tree evidence.
