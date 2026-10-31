# Read-only firmware profiling clock

The optional profiler discovers the ACPI PM timer from checksummed RSDP,
RSDT/XSDT and FADT tables. Traversal, table sizes, addresses and System IO GAS
fields are bounded. UEFI starts with its firmware configuration table; BIOS
scans EBDA and the standard RSDP range. No timer configuration is written and
no post-i486 clock instruction is needed.

The timer runs at3579545Hz. Adjacent24/32-bit samples are extended monotonically.
At each progress snapshot, an independent coarse clock checks elapsed time;
a stalled timer, backward clock or missed complete24-bit wrap invalidates
timings. The reporter emits `valid=false` and `null` durations, never measured
zero. Missing/unsupported ACPI affects profiling only, not installation.

The coarse check tolerates two seconds of quantization. This is a diagnostic
clock, not a guarantee against arbitrary simultaneous faults in both clocks.
Firmware-provided ACPI physical memory is trusted; this does not claim safe
probing of arbitrary untrusted host virtual addresses.

Focused tests cover modular extension, a lost wrap, stalled/reversed clocks,
FADT checksum and IO-field refusal, bounded root discovery and self references.

The separate bitmap change preserves the volume allocation cursor across
release. Allocation still wraps to reuse freed space; MFT record allocation
has an explicit exact-reuse preference in `releaseRecord`. Its test checks
forward allocation followed by reuse after wrapping.
