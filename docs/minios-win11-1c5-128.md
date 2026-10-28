# MiniOS 1c5: Win11 x64 / 128 MiB, closed gate

2026-10-26. QEMU only. Firmware and native oracle ran at clean HEAD `4431f6e66839d05062c74adefcdbaea210342314`; their complete receipts are pinned in `minios-win11-1c5-128.json` beside this note.

Firmware preparation passed in **559.356 s**, below the 900 s guest limit. The 629.254 s wrapper duration also includes evidence hashing after the guest completed. One WHPX CPU, `qemu64,-xsave`, 128 MiB, profiling disabled, existing 1 MiB target buffer enabled; target QCOW2. Source ISO remained on readonly NTFS, selected WIM image 2 applied directly to fresh GPT/ESP/MSR/NTFS without an intermediate WIM copy.

**Independent Windows gates passed:** readonly `chkdsk` without switches returned 0 on both the 300 MiB FAT32 ESP and Windows NTFS. The exact FileBackedVirtual/read-only/32 GiB geometry and partition identity were checked before the DOS alias was used. One final dynamic VHD export served both gates; there was no second full raw/VHD copy.

The native file-tree/SHA/ADS/metadata/security comparison checked **168751 entries**, with zero missing, extra, different or unreadable entries, and **82533 short names**. An independent on-disk NTFS/SDS proof checked **377 descriptors and 168751 references**. Source, backing files, expected manifests and readonly VHD were unchanged after verification. This follows the already documented explicit RP_FIX, root metadata and secondary hardlink alias policies; it does not conceal arbitrary metadata differences.

Program peak **12044492 B (11.49 MiB)** includes its own 1 MiB stack; stack high-water **417768 B (407.98 KiB)**, canary OK, final allocator current 0. Firmware memory is excluded. This is a measured 128 MiB guest, not evidence of a minimum machine RAM. The PM-read count stayed at the startup-calibration value 5336 throughout the apply.

Firmware reported durable selected-stream SHA-1 verification and 136696 files plus 32055 directories. All new images and small evidence are retained. This gate does **not** include the 64 MiB run, IA32/BIOS execution, BCD versus bcdboot, boot files, first Windows boot, or confirmation that omitting Win11 metadata type 4 is harmless at boot.
