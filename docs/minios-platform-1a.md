# MiniOS 1a: isolated platform clients

This is a proof of concept, not a USOS installation path. Existing UEFI menu,
Windows flows, shell scripts, and Legacy Core sources remain unchanged.
Final acceptance results belong in `RAPORT-MINIOS-ETAP1A.md`; compiling a client
or receiving its own PASS does not replace the independent filesystem checks.

## Shared contract and workload

`src/prep/platform.zig` carries byte offsets and lengths in `u64`, including on
IA32. The backend must perform exact reads/writes; `Disk` checks end-of-disk
and integer overflow first. The allocator wrapper caps requests at 8 MiB and
records current/peak requested bytes across alloc/free/resize/remap. The
dedicated UEFI stack is counted; the original firmware/BIOS stack, firmware
allocations, executable image and static buffers are outside this counter.
Requested allocations are not presented as total machine memory.

`partitions.zig` writes one Basic Data GPT partition, both 128-entry arrays,
primary/backup 92-byte CRC32 headers, protective MBR, or one MBR 0x07 partition.
The partition begins at 1 MiB. Sector size is explicitly restricted to512 B;
MBR sizes exceeding its32-bit LBA fields are rejected. Stale GPT metadata at
both ends is cleared when creating MBR. Independent entropy bytes supply
GPT disk/partition GUIDs (version4), the MBR signature (including protective
MBR) and NTFS serial. Each run receives new entropy; overlays of one base do
not intentionally repeat identities. The target-selection marker is never
used as an entropy seed. Physical-machine entropy is outside this QEMU POC.

`app.zig` reads two actual boot-medium fixtures:64 B and128 MiB+123 B. It
hashes each source with64 KiB reads before partitioning, then uses the shared
NTFS writer for1000 items in one directory, nested directories, Unicode names,
a255-UTF16-unit name, an empty file, a large streamed file, and one explicit
48-byte security descriptor. Every written file is read back and SHA-256
compared. `finish()` finalizes the volume; independent host read-only checks
are still required. No file or partition is buffered whole.

## UEFI x64 and IA32

Both artifacts use the same `uefi_main.zig` and core. The client runs while
Boot Services are available, uses BlockIo (64 KiB aligned bounce buffer,
read-modify-write for unaligned ranges), pool allocation, SimpleFileSystem
for fixture input and `\\USOSPREP.LOG`, GetTime for elapsed seconds, ConOut,
SerialIo, and a QEMU debug console. The firmware watchdog is disabled.
The prep workload switches to an owned 1 MiB stack with a 4 KiB bottom canary,
using the firmware calling convention on each architecture. This allocation
is included in the same requested-byte counter and 8 MiB cap as the core.
The original firmware stack is restored before freeing the new stack. Final
current/peak figures are logged after that free. This avoids depending on an
unspecified firmware application stack size.
The IA32 COFF runtime helper is a small own Zig implementation: the installed
compiler requests the MSVC unsigned64-bit division ABI for UEFI but its bundled
compiler_rt exports those names only for Windows. The helper uses32-bit shifts,
comparison and subtraction, with110 full-range division/remainder test pairs;
its symbol spelling/calling convention follows the installed Zig runtime ABI.

The boot ESP must contain `USOSPREP.CFG`:

```text
USOSPREP_QEMU_ONLY
mode=gpt
target_sectors=4194304
token=<64 hexadecimal characters>
```

Selection requires exactly one whole writable512-byte-sector disk matching
the exact sector count and `USOSPREP TARGET v1\n<token>\n` sector0 marker.
The loaded-image boot handle is excluded, and its whole-disk parent is excluded
by device-path prefix. Missing/malformed paths, unknown or duplicate config
keys, no match, and multiple matches fail closed. There is no first-writable
fallback and no production menu integration.

In QEMU, a completed successful run uses isa-debug-exit value0x10 (process
exit33); failure uses0x11 (exit35). Terminal failure is logged, followed by
shutdown if the debug-exit device is absent. An exit33 still requires checking
the closed log and the independent host NTFS results.

## BIOS reuse audit

The separate `usosprep-bios` build compiles the existing, unchanged files:

- `src/platform/bios/stage1.S`: INT13 extensions check and initial loader.
- `bootstrap.S`: versioned/checksummed slot, A20, protected-mode transition,
  low-memory stack, handoff at0x9100.
- `core.S`: PM32 entry, existing real-mode thunks, AH48 disk information,
  AH42 reads, AH43 writes, E820, text/serial output, memcpy/memmove/memset.
- `tools/pack_legacy_core_slot.py`: original256 KiB slot and CRC format.

New files are only the prep client, its separate linker script, and build/test
harnesses. The original slot bounds and first64 KiB thunk placement remain.
The new linker bounds BSS below64 KiB and below the low-memory stack reserve;
the new Zig entry explicitly clears this private range (needed by Zig's own
compiler_rt integer helpers). Generated assembly is checked for SSE/AVX registers
under an i386 target. No C library is linked. Existing assembly is firmware ABI
glue; the partition/NTFS workload and new platform logic are Zig.

The existing bounce buffer is0x10000..0x1ffff (below1 MiB); transfers are capped
at127 sectors. The new BIOS client requires boot drive0x80 and explicitly named
target0x81, exact AH48 size/sector geometry, and the same target token. Existing
batch reads address only the boot drive, so target reads use the existing
single-sector explicit-drive thunk. This is a known performance limit, not a
reason to change Legacy Core semantics in this proof of concept.

E820 must cover16..24 MiB as usable RAM for a fixed8 MiB allocator region. The
old graphical boot UI window32..48 MiB is not imported or used. The formatter's
tracked demand is measured separately from the reserved allocator region.

The BIOS boot image uses documented fixed sectors rather than a FAT logger:

| Area | LBAs |
|---|---:|
| Existing Core slot |64..575|
| Explicit binary fixture configuration |1024|
| UTF-8/ASCII log, zero-terminated unused tail |1025..2047|
|64-byte input |2048|
|Large streamed input |2056 onward|

The blank build artifact is1 MiB and fails closed without a staged config.
The test harness expands only its new copied boot image to256 MiB, supplies
fixtures/config, and uses overlays for every run. The target remains a separate
image. The fixed log is512 KiB minus one sector; overflow is an explicit error.

## File-only QEMU harness

`tools/minios/uefi_case.py` also supports `--arch bios`. It accepts cases only
below an explicitly supplied `--workspace` directory, rejects existing outputs/reparse
points, and enforces a100 GiB pre-creation reserve. No host disk is mounted or
formatted. It creates readonly-in-use raw bases and fresh qcow2 overlays for
both boot and target images. Completion uses one blocking subprocess wait;
there is no progress polling, QMP, or repeated log reading. After QEMU exits,
the boot overlay is converted to a closed raw copy and the log is extracted
without mounting. Firmware source SHA-256 and the actual process result are
recorded. Each RAM test uses a new overlay from the same base.
Ctrl+C or timeout kills and waits for the one owned QEMU child. Failure results
make the wrapper return nonzero; a log string alone cannot override an actual
failed process status. Paths with commas/control characters are rejected before
they can reach QEMU's `file=` option parser.

After all validation, `cleanup CASE` requires recorded guest completion for
every run and acquires no-sharing Windows handles for every allowlisted image.
It records streamed SHA-256/size in `cleanup.json` before deleting any image,
then removes only explicit raw/qcow2/vars/fixture names and writes a completion
receipt. There is no recursive cleanup or wildcard image deletion. Logs, JSON
evidence and unknown files remain. Unit tests exercise this only on newly
created synthetic files; acceptance-case cleanup is performed by the owner
after oracle/chkdsk evidence collection.

Example commands (build owner runs one build at a time):

```powershell
zig build usosprep-app -j1
# $VmRoot and $QemuDir are explicit local application directories supplied by the caller.
python -I -B tools/minios/uefi_case.py --workspace $VmRoot --qemu-dir $QemuDir prepare "$VmRoot/x64-gpt" --arch x86_64 --kind gpt --efi zig-out/test-assets/usosprep-x86_64.efi
python -I -B tools/minios/uefi_case.py --workspace $VmRoot --qemu-dir $QemuDir run "$VmRoot/x64-gpt" --memory 64
```

Repeat preparation for IA32/MBR and BIOS/GPT/MBR. After evidence collection, only owned case images
are eligible for deletion; logs, commands, and hashes remain for the report.

Every `run` generates fresh64-byte OS CSPRNG entropy and supplies it through
QEMU fw_cfg (`opt/usosprep-entropy`); the firmware refuses to format without
that source. `entropy.bin` is owned runtime data and removed during cleanup.
It is distinct from the persistent target-selection token.

`verify_case.py` takes `--workspace`, `--oracle-root`, `--qemu-dir` and
`--source-root`. Windows verification creates a separate VHD, mounts it only
read-only, and creates a temporary no-broadcast DOS alias. Immediately before
`chkdsk ALIAS:` (no switches), IOCTL_STORAGE_GET_DEVICE_NUMBER resolves the
actual alias and Storage confirms it belongs to the mounted file-backed
virtual image with exactly the expected bytes, read-only, neither boot nor
system. Any mismatch aborts before chkdsk. Exact UTF-16 path/size/SHA-256 tree
comparison is also required for the six firmware images. The independent
mkntfs control requires the same identity guard and clean chkdsk exit0; it
does not claim native file IO if Windows declines mounting a write-protected
mkntfs filesystem. Alias removal, dismount and unchanged source/VHD hashes
are acceptance conditions. All host helper logs stay below the supplied
workspace. Published JSON evidence uses symbolic relative roots only.

## Public specifications consulted for this platform work

- [UEFI2.11 chapter5: GPT disk layout](https://uefi.org/specs/UEFI/2.11/05_GUID_Partition_Table_Format.html):
  header/array CRCs, backup placement, protective MBR, GUID byte layout.
- [UEFI2.11 chapter13: media access](https://uefi.org/specs/UEFI/2.11/13_Protocols_Media_Access.html):
  BlockIo alignment, logical-partition handles, SimpleFileSystem/FAT files.
- Existing repository BIOS sources listed above and the installed Zig0.16
  UEFI/allocator declarations for ABI signatures. No Microsoft source was read
  or translated for these platform clients.
- [QEMU fw_cfg specification](https://www.qemu.org/docs/master/specs/fw_cfg.html):
  x86 selector/data PIO ports, big-endian file directory, filename selection.
