<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Closed UEFI boot-file QEMU gate

`tools/minios/boot_provision_case.py` runs the separate UEFI boot client on
a new target overlay. It does not start Windows. There is no permissive mode
for missing prerequisites: every receipt and BCD input has an explicit SHA-256
argument. Images and even the output directory are created only after the
complete acceptance chain has passed.

Required inputs are the completed firmware preparation result and its log;
the guarded native 1c-2 result with both filesystem child results, actual
dynamic VHD and layout; the real guarded bcdboot result and job; and the
successful semantic comparison with both original BCD stores. The runner
reuses `bcdboot_reference.accepted` for native acceptance, independently reads
both BCD routes, checks their devices against the actual GPT layout, and
checks the original prepared QCOW2 and every backing-file hash. It reads
the NTFS serial from the dynamic VHD BPB. The original log's disk/partition
identities must match; its otherwise unused GPT identity `mbr_signature` is
retained for the common layout type. No drive letter, physical device, full
disk export, extra VHD or native mount is needed.

Read-only deny-write/delete handles cover accepted receipts, VHD, backing
chain, BCD files and executable until the QEMU process completes. A new
random version4 loader GUID is generated. The utility ESP receives only
8.3 control names: `USOSBOOT.CFG`, `USOSLAY.RCP`, `USOSBCD.RCP`, plus the
architecture-specific EFI fallback executable. The FAT helper is explicitly
configured for the approved runtime before opening an image. The firmware
checks the exact two receipt byte hashes and wraps target writes in an
ESP-only capability.

The output is a fresh `boot-*` folder inside the matching `1c23/qemu-x64`
or `1c23/qemu-ia32` reservation. The whole reservation still includes the
prepared QCOW2 and existing read-only VHD. The new utility image is about
65 MiB; only small QCOW2 overlays are added. The target overlay must remain
within 128 MiB and the utility overlay within 8 MiB at completion. Win11 boot
files and fonts themselves exceed 32 MB. No files are deleted, and every
base is rehashed after completion.

Only after the pinned closed prerequisites are accepted, the runner calls
`wim_pool.enforce_incremental(..., closed_scope=True)` with a 208 MiB growth
budget. That helper retains the aggregate approved 150 GiB ceiling and checks
the logical existing files plus new growth against the whole selected scope
cap. It rejects hardlinks and reparse points. Other reservations are opaque
and are never traversed. The actual free-space check reserves 100 GiB plus
the new growth, rather than charging the existing QCOW2 and VHD twice. This
closed-scope assertion requires serialization by the coordinating caller;
it must not be used while another job writes in that reservation.

QEMU runs one virtual CPU with explicit architecture, memory, pflash files,
utility and target disks, no network, debug console and debug-exit device.
It is waited on once through the process handle, without QMP or progress
polling. Success requires exit33, `BOOT_UEFI PASS`, bounded stack/allocator
measurements, no failure marker, unchanged inputs and bounded overlays. It
then creates the internal target snapshot `bootfiles`, retains source-hash
records in `boot-files.json`, and writes `result.json`. The next stage must
use another overlay for the first Windows boot and inspect its setup logs.

The CLI requires `--prep-receipt`, `--native-receipt`, `--reference-receipt`,
`--compare-receipt`, `--ours-bcd`, `--reference-bcd`, `--program`, `--qemu-dir`,
`--plan`, `--out`, and `--arch`. Each receipt uses its matching
`--prep-sha256`, `--native-sha256`, `--reference-sha256`, `--compare-sha256`;
the BCD stores and executable use `--ours-bcd-sha256`,
`--reference-bcd-sha256`, `--program-sha256`. `--memory` defaults to128 MiB;
`--timeout` defaults to300 seconds. All paths are supplied by the caller.

Unit fixtures contain only generated JSON/BPB data. They exercise missing
and forged receipt refusal before output or image creation, deleted semantic
proof, mismatched layout/BCD identity, output path boundaries, and genuine
guest-completion requirements. These tests do not claim real bcdboot, native
chkdsk, QEMU provisioning or a Windows first boot has passed.
