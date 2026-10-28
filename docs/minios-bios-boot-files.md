<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Experimental BIOS boot-file provisioning

`boot_bios_files.provisionBios` is a platform-independent 1c-3 first-boot
experiment for the Win7 x86 MBR layout. It is unavailable until both the
complete 1c-2 apply gate and the native, real-layout bcdboot comparison pass.
It is not a production replacement for bcdboot: its own small PBR binds one
verified physical BOOTMGR run. A later Windows update relocating BOOTMGR
requires reprovisioning. Fragmented, sparse, resident or oversized BOOTMGR
is refused instead of installing unusable executable boot sectors.

The common writer validates the actual MBR signature, active 100 MiB NTFS
system partition at 1 MiB, Windows partition at 101 MiB, disk size, both NTFS
serials and both copies of their boot sectors. The system partition must
contain exactly the fresh formatter's metadata entries, including the three
known `$Extend` metadata records, with their original record numbers. It
then reformats that empty system partition, retaining its actual NTFS serial.
The Windows partition is mounted through the read-only NTFS API throughout.

The bounded `boot_source.zig` inventory is shared with UEFI, accepts no file
writer and contains no destination-write operation. It checks paths, limits
directory traversal and hashes source files before provisioning. PCAT files
are copied under `Boot`, with `Windows/Boot/PCAT/bootmgr` moved to the system
root. Fonts are required; optional resources have readable skip diagnostics.
Fresh qualified MBR BCD devices use the original disk signature and exact
system and Windows offsets. Copying is streamed and rehashes each source;
filesystem completion precedes a read-only BOOTMGR run resolution and a
read-back SHA-256 check. This final run must be non-sparse, begin at VCN 0,
and cover the exact rounded file size. The loader size is limited to 960
sectors (491520 bytes, loaded up to 0x98000); the PBR separately checks
available low memory at runtime. Win7's observed 383786-byte BOOTMGR needs
750 sectors, Windows 10 22H2 x86's 413738-byte BOOTMGR 809 (the earlier
768-sector limit refused it).

Executable MBR/PBR sectors are published only after all these steps. Their
own assembly templates are passed in `OwnBootCode`; no Microsoft boot-sector
bytes are stored in the repository. The MBR code replaces bytes 0–439 while
retaining bytes 440–511, including disk identity and partition table. The
PBR replaces bytes 84–509, retaining the NTFS BPB and signature, and is written
to both primary and backup locations. Template ABI:

| Template field | Byte offset | Contents |
| --- | ---: | --- |
| MBR identity magic | 432–439 | `USOSMB1` followed by NUL |
| PBR absolute BOOTMGR LBA | 480–487 | little-endian u64, zero in template |
| PBR BOOTMGR sector count | 488–489 | little-endian u16, zero in template |
| PBR identity magic | 492–499 | `USOSPB1` followed by NUL |

The real-mode handoff follows the public GNU GRUB `ntldr` implementation:
BOOTMGR is loaded at physical 0x20000 and entered at CS:IP 2000:0000 with
the NTFS BPB at 0x7c00, DL retained, A20 enabled and SP 0x7c00. See the
[pinned GRUB primary source](https://chromium.googlesource.com/chromiumos/third_party/grub2/+/11508780425a8cd9a8d40370e2d2d4f458917a73/grub-core/loader/i386/pc/ntldr.c),
copyright Free Software Foundation, GPL-3.0-or-later. The NTFS/FAT writer,
copying logic and the assembly templates are project code. The protocol
reference does not imply that Microsoft binaries are included in Git.

Simple boot names such as `bootmgr`, `Boot` and `BCD` receive the NTFS
writer's combined Win32/DOS namespace. Longer copied resource names use the
Win32 namespace. A general short-alias generator remains an integration
follow-up under F4; this first-boot experiment does not fabricate source
8.3 metadata. Read-only chkdsk and independent boot-file verification remain
external gates, followed by an actual Win7 BIOS first boot on an overlay.

The unit fixtures contain generated project bytes only. They verify the
default no-I/O refusal, template ABI, actual MBR/NTFS identity checks and
read-only contiguous-run SHA verification, including corrupted hash and
sparse-fragmentation refusals. They do not stand in for the Windows boot gate.
