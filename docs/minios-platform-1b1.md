# MiniOS1b-1: generated firmware scaling profile

The existing test executable now accepts an explicitly selected scaling
workload. No Windows setup/menu/legacy-flow code is changed and no WIM reader
is started. Firmware tests remain QEMU-only and never select the first disk.

UEFI config adds `profile=scale-firmware`; omitted profile keeps the1a fixture
workload. Duplicate/unknown profile values fail. Target selection still
requires the exact target size, unique64-hex marker token and a device path
that is not the boot device or its parent. The scaling workload does not open
large input files on the ESP: sources are generated in bounded chunks by the
shared `src/prep/scale.zig` workload.

BIOS uses the existing version1 config sector, with DWORD at offset132 set to1
for scaling (0 retains1a; other values fail). The existing explicit boot0x80 /
target0x81 and token/size checks remain. The scaling profile chooses a usable
E820 type-1 range at or above 1 MiB, capped at 8 MiB and requiring at least
512 KiB. The closed 1a profile retains its existing E820 range16..24MiB
requirement; the low-memory scaling result does not apply to that mode.
Existing stage1/bootstrap/Core thunks are reused.

UEFI tracks its own1MiB stack in the same16MiB allocator budget as the core;
firmware allocations are excluded. Published platform memory evidence adds
the PE `SizeOfImage` and a4KiB entry-stack budget to the allocator peak. BIOS
uses a bounded coalescing heap that supports arbitrary-order free; it reports
physical occupied-block peak, address-span peak and the actual E820 reserve.
Its conservative program bound counts the entire heap reserve, its actual
linked allocated-section span including BSS, the unchanged
0x60000..0x9e000 stack reserve and a conservative128KiB thunk/bootstrap budget.
The ELF allocated bytes must match the payload in the actual BIOS image.
Summary refuses a conservative program total above16MiB. These are bounded
program-memory metrics, not total VM/firmware working-set measurements.

The isolated BIOS build uses function sections and linker garbage collection
so unreferenced freestanding compiler_rt helpers do not occupy the fixed slot.
All existing slot, first64KiB-thunk, BSS and stack-overlap assertions remain.
The final CPU/heap build produced a 153228-byte payload in the unchanged
262144-byte slot; SSE/AVX and CMOV audits passed. IA32 UEFI and BIOS explicitly
target i486. The IA32 generated-assembly audit is separate from the CPU
requirements of the supplied OVMF firmware. x86_64 retains its baseline ISA,
which includes SSE2.

The BIOS source audit found no unconditional CPUID/RDTSC/RDRAND dependency in
the executed preparation path. The shared Core CPUID helper first tests the
EFLAGS.ID bit and is not called by this client. Its clock reads volatile BDA
ticks at 0x46c; entropy arrives through QEMU fw_cfg PIO from the host CSPRNG.
These source/assembly checks complement the actual CPU workload tests; they
do not establish physical-hardware compatibility by themselves.

`tools/minios/scale_firmware_case.py` runs x86_64/IA32/BIOS at64MiB using fresh
qcow2 overlays. It waits for process completion, extracts closed logs and
requires the scaling PASS marker plus debug-exit33. The exact generated
manifest is shared with `scale_case.manifest('firmware')`. After each run it
exports the closed target and invokes the independent Windows oracle: exact
case-sensitive paths, sizes and streamed SHA-256 plus read-only `chkdsk X:`
without switches. Acceptance also checks the actual aliased VHD size, no
repair flags, alias removal, VHD dismount and unchanged source/VHD hashes.
Running with `--firmware-only` is diagnostic and cannot satisfy acceptance.
No per-file TCG Linux shell loop is needed for this scaling gate.

`cpu_ram_case.py` pins the exact accepted program hashes and creates a fresh
overlay for each CPU/RAM attempt. BIOS 486 and Pentium at 32 MiB require the
full workload and independent Windows byte/CHKDSK checks. The RAM search
records completed workloads and any observed lower-memory failures;
it distinguishes the application's compiled ISA from the tested firmware
minimum. Closed receipts, including failed attempts, remain evidence. Actual
minima are published only after the controller has returned. The final run
was deliberately stopped at a completed-trial boundary by root instruction;
the original controller exit 1 and its guard exception are preserved. The
`STOP-OPTIONAL` directories are explicit operator metadata, never simulated
test receipts. No active VM was interrupted by this boundary stop.

The closed CPU/RAM results from the accepted artifacts are QEMU-only:

| Client | Lowest completed PASS | Lower completed result | CPU evidence |
| --- | --- | --- | --- |
| BIOS | 2 MiB | 1 MiB: explicit `NoSpace`, exit 35 | QEMU 486; additionally 486 and Pentium at 32 MiB each passed the independent Windows byte/CHKDSK/metadata gate |
| UEFI IA32 | 43 MiB | 42 MiB: exit 35; 32/40 MiB: timeout without extracted application log | Supplied IA32 OVMF with QEMU 486, explicit i486 application target |
| UEFI x64 | 52 MiB | 48/32 MiB: timeout without extracted application log; 50/51 MiB not run | Supplied x64 OVMF with QEMU `qemu64` |

These are minima among completed attempts for this workload and firmware.
The x64 result has no adjacent lower failure and makes no claim about 50 or
51 MiB. They are not Windows-installation or physical-hardware RAM minima.
The BIOS 2 MiB case reserves 917504 bytes of E820 heap, with physical occupied
peak 410700 bytes and address-span peak 410900 bytes; current returns to zero.
The full machine RAM and the conservative own-program bound are distinct
measurements.

`scale_evidence.py` accepts explicit `--host-case` and `--firmware-case` paths
under a separately named `minios-1b1-*` runtime. The final portable JSON
requires exactly3 host profiles and3 firmware architectures and rechecks the
recorded actual file list against the expected manifest. It contains relative
receipt paths/hashes and metrics; it contains no disk images or OS payloads.

`cleanup_scale.py` uses the same explicit case selections and acceptance
guards. Its allowlist covers only generated images in those selected cases
and their associated oracle copies. Before deleting anything it checks VHD
dismount, opens every selected file without sharing, hashes all of them and
pins the accepted target/VHD digests. Files are marked for deletion through
the same held handles, avoiding a close/reopen race. Readonly flags are changed
only on those exact held files. Logs, manifests, footprints and receipts stay.
The collector can run after cleanup. Cleanup must be invoked only after the
final accepted runs and the final report has been written; a draft report is
insufficient. It is never automatic inside a firmware test.
