# Isolated firmware Windows preparation

SPDX-License-Identifier: GPL-3.0-or-later

`zig build usosprep-install-app -j2` builds the UEFI x64 and IA32 clients.
IA32 explicitly targets i486; its emitted assembly is audited. These clients
are independent of the existing USOS menu and release-media steps.

The `install` profile in `USOSPREP.CFG` requires a positive `wim_index`, an
exact target sector count and a random authorization token. The read-only
source is pinned by whole-device byte count, NTFS partition start/length,
NTFS serial and ISO path. Duplicate matching sources/targets are refused.
The target excludes the firmware boot device and its parent. The common
pipeline validates explicit whole-media identities and scans every byte of
the target (apart from the exact authorization marker) before writing.
WIM metadata and all resource hashes pass before partitioning begins.

UEFI preparation creates GPT, a 300 MiB FAT32 ESP, a 16 MiB MSR and Windows
NTFS, aligned to 1 MiB. BIOS preparation uses a separate active 100 MiB NTFS
system partition and Windows NTFS. The separate system volume permits later
boot-file provisioning without reopening the existing Windows NTFS writer.
This step writes no boot files or BCD and does not imply that Windows boots.

Firmware block adapters read 512- and 4096-byte media as byte streams; the
optical reader retains 2048-byte logical blocks. The current NTFS writer
requires a 512-byte destination and refuses a 4Kn destination before writing
a partition table. This is distinct from reading an ISO stored on 4Kn NTFS.

The UEFI client uses a tracked 1 MiB stack, fills it with a sentinel before
entry and reports the actual high-water mark and bottom-guard status after
return. Its bounded source/target buffers are included in the reported
program allocation/stack budget; firmware-owned memory is excluded.
Layout identifiers use one validated 64-byte platform CSPRNG seed plus a
domain-separated SHA-256 expansion with two counters. No time-based or repeated-fw_cfg fallback
is used. Every new stage uses an immutable base and a retained overlay.

Files added by USOS on FAT32 receive deterministic collision-checked 8.3
aliases from the formatter. The control filenames themselves fit 8.3. Windows
files copied by WIM retain their recorded short names under the accepted WIM
metadata policy; future boot provisioning must preserve the same rule.

The test harness labels stdout/stderr with the clean HEAD before QEMU starts.
QEMU truncates its own serial/debug capture files, so the harness prefixes
those only after the process completion wait; every captured byte is retained
after that explicit provenance line. The receipt records this policy, and the
same clean HEAD is checked before launch and after completion. Missing guest
captures are labelled empty and cannot satisfy the acceptance markers.
