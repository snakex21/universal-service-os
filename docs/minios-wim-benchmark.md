<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Firmware LZX and SHA-1 host microbenchmark

Build `src/prep/wim_bench.zig` with `-O ReleaseSmall`, separately for
`-target x86_64-windows` and `-target x86-windows -mcpu i486`. No build target
or firmware default changes. The executable opens only an explicitly supplied
regular WIM, read-only; arguments are `install.wim decoder-repeats sha-repeats`.

The code imports the actual `wim.zig` resource reader, `wim_codec.decode(.lzx)`
and `std.crypto.hash.Sha1` used in firmware. It chooses the first nonmetadata
compressed resource of 1–4 MiB, preloads its compressed bytes and validates its
full decoded SHA-1 against the WIM blob table before measurement. The timed
decoder phase calls the real decoder, including normal workspace allocation,
only for compressed chunks. Literal copies are counted and excluded. A second
phase hashes the decoded sample without decoder or file IO. Compiler barriers
prevent repeated work being eliminated. SHA-1 is checked again after timing.

`tools/minios/wim_benchmark.py` requires clean same-HEAD compiler logs, explicit
programs, retained WIMs in runtime/inputs and a fresh final-logs directory. It
holds every source/program/proof deny-write locked, runs architectures and WIMs
sequentially, and pins their SHA-256 before/after. Invoke through `logged_run.py`
for BelowNormal priority and two-CPU affinity, separately from any heavy build
or VM. The runner uses 16 decoder and 256 SHA passes and accepts only identical
resource identities across architectures. All logs and receipts are retained.

This is native-host CPU throughput for the selected real WIM resource. It is
not QEMU speed, timing of a physical i486, full WIM verification/apply speed,
storage throughput or a replacement for the real firmware Windows gate.
