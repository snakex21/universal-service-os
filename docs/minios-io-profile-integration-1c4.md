# Target combining and profiling integration

The UEFI install path wraps its explicitly selected virtual QCOW2 target in
the tracked1MiB write combiner. Sector-aligned, correctly IO-aligned writes
reach BlockIo without the old64KiB bounce split; unaligned IO preserves
read-modify-write and propagates errors. A fake BlockIo test verifies one
physical call for1MiB, unaligned fallback and a device failure. Completion
requires the final combiner flush.

Actual source and target BlockIo calls are separately timed. WIM decoding and
SHA1 work have nested profiler scopes; NTFS supplies MFT/index scopes. Progress
includes completed-file rate and cumulative **exclusive** category milliseconds.
Invalid or missing clocks produce null durations. A final durable-apply progress
line includes the finish/flush work, with rate measured from the operation start.
The PM timer is read only; coarse RTC checks occur at progress boundaries.

The UEFI installer tracked-allocation cap is14MiB, including its owned1MiB stack.
Final gate measurements, including stack high water and fixed buffers, remain
required; this cap alone is not a total-memory measurement.

Development checks before the final NTFS index integration:216 aggregate tests
passed, UEFI x64/IA32 built, i486 assembly audit passed. Final clean-tree builds
and the real Win11 gate must be repeated after all component commits.

Review corrections: no redundant target flush is issued after the protected
WIM writer returns. A composed WIM/MFT/combiner test injects failure at its last
durability barrier and requires dirty1 in both primary and mirror Volume records,
an incomplete diagnostic and no PASS. Missing UEFI RTC time is now optional,
invalidating profiling instead of passing zero as a valid coarse-clock sample.

The BIOS install client also uses the combiner and read-only PM timer, with
the BDA coarse clock. Its EDD transport retains the127-sector/65024-byte
maximum; a1MiB logical batch is therefore split by that transport. Its14MiB
heap cap excludes the separately measured low-memory stack. Static i486
compile/audit/link/pack passed with a private272KiB installer slot; this is
not a BIOS guest or Windows runtime PASS.
