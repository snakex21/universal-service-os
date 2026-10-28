# MiniOS 1b-2: isolated WIM apply

This proof of concept has no dependency from the USOS menu, release media or
normal Windows preparation flow. `usosprep-wim-host` accepts only a regular
owned disk-image file. UEFI requires `profile=wim` and an explicit positive
`wim_index`; the input is the read-only `FIXTURES/install.wim` fixture. BIOS
uses a separate WIM-only executable and workload3 configuration. The previous
BIOS workloads remain in their original artifact; Core, bootstrap, linker,
fixed slot and low-memory stack are unchanged.

## Apply contract

The archive is read-only. The selected image's metadata SHA-1 and referenced
streams are checked before any target write. Every lookup blob, including
other images, is SHA-1 checked in bounded chunks before formatting. Optional
WIM raw-integrity blocks are also checked. Lookup and XML descriptors have no
individual resource SHA-1 in this format; this does not claim a signature or
publisher authenticity check. Each copied file/ADS is SHA-1 checked again
while streaming into NTFS. A hash or write failure cannot finish a clean
volume. The target is always partitioned and freshly formatted by usosprep;
opening an existing filesystem for WIM apply is unsupported.

Only one explicit1-based image is applied. Split SWM, solid resources/solid
ESD, EFS ciphertext, unsupported reparse types and oversized chunks are
refused. Non-solid XPRESS/LZX chunks are bounded at32KiB and LZMS at128KiB.
Archive indices are limited to131072 blob entries and64 images; metadata
walk is bounded to256 levels, one million entries and65536 security IDs.
Limits produce errors; no implicit fallback or time/date modification exists.

## NTFS representation

Hardlink identity uses WIM groupID and unnamed DATA SHA-1: Windows7 images
reuse some group IDs for different file contents. Remaining inode metadata
must agree. Directories/reparse points are not treated as file hardlinks.
Named ADS, raw self-relative security descriptors, junctions/symlinks,
sparse data, compressed attributes, empty files and timestamps are written
through the same NTFS implementation as the separate feature gate. NTFS
compressed data uses legal raw compression units, without claiming LZNT1
compression savings. WIM stores creation/write/access times; NTFS change
time is explicitly set to WIM write time.

Short8.3 names are validated but **not created**; generated filename entries
use POSIX namespace0. This is a compatibility limitation for a complete
Windows installation. Tagged extended metadata is logged as ignored; this
stage does not claim a complete Windows installer or a bootable installed OS.

## Verification and memory

Host tools reserve1MiB of stack. Firmware owns bounded tracked allocation;
UEFI includes its own1MiB stack in the tracked peak, and BIOS reports its
physical heap separately. Report memory for XPRESS, LZX and LZMS separately,
including loaded program image and reserved stacks, excluding firmware.
Compiler MaxRSS is not runtime program RAM. Solid LZMS has no accepted RAM
budget because it is refused before formatting.

Acceptance requires the independent wimlib tree/stream SHA-1 manifest,
raw `$Secure` byte equality and path-to-security references, validated
Windows API security sections, all other metadata, and native read-only
`chkdsk X:` exit0. A successful core log alone is insufficient. The verifier
checks virtual-disk identity, exact image size, read-only state, non-system
status and source hashes. Images, logs and earlier failures stay available
until the final report; any later cleanup must list every removed file.

## Source and license

The WIM layouts and hardlink compatibility rule were checked against public
wimlib v1.14.5 (`include/wimlib`, `dentry.c`, `blob_table.c`,
`metadata_resource.c`, `security.c`, `integrity.c`, `inode_fixup.c`). Codec
files identify their wimlib source commit and authors, and are LGPL-2.1-or-later;
the required license is `tools/minios/COPYING.LGPL`. The LZMS Huffman helper
also retains its MIT notice. Other MiniOS files retain their SPDX licenses.
No Microsoft implementation source or image payload is part of this work.
The pinned host wimlib DLL/CLI is an independent test oracle, never linked
into the Zig program. WIMs and generated test images remain outside Git.

## Final07 acceptance closure (2026-10-25 local)

The final application has 24 independently qualified read-only Windows gates:
two real install.wim images (Windows 10 and Windows 7), nine host feature/codec
cases, eleven firmware cases and two minimum-RAM firmware outputs. Every gate
has exact tree/stream/security comparisons and native chkdsk exit0. The final
build passed 690 Zig tests; the final helper suite passed 165 Python tests with
no skips. Source/artifact pins and individual gate receipts are in
[the portable evidence manifest](minios-evidence-1b2.json).

UEFI x64 and IA32 completed all three codecs at 64 MiB. For the large non-solid
LZMS fixture the measured boundaries are 49 MiB x64 and 48 MiB IA32; the adjacent
lower values fail the application's initial stack allocation under the pinned
EDK2/QEMU. The outputs at both minima also passed the full Windows gate. These
are workload/firmware measurements, not universal hardware requirements.
BIOS actually passed on 486 and Pentium at 32 MiB; its lower RAM boundary was not
measured in this stage. An old physical BIOS without an accepted entropy
source still refuses; the external-seed fallback remains deferred.

The proof-of-concept limits above remain explicit, including no 8.3 generation,
no solid ESD/SWM support and the reserved root-MFT5 metadata flags. The final
report is `RAPORT-MINIOS-ETAP1B2.md`. All images were retained until that
report. The authorized cleanup removed
355 image/vars files afterward, with all 1,365 retained evidence sentinels
unchanged. See [the cleanup receipt note](minios-wim-cleanup-final.md) and the
exact file list in the final report.
