# XP: one C: volume

**Historical FAT32/conversion implementation below.** The physical first-restart
failure superseded this path with native NTFS and an EDD-only NT52 bootstrap.
See [the physical failure and NTFS follow-up](xp-ntldr-native-ntfs-2026-09-09.md).

The automatic XP path now extends the guarded staging reservation into its
contiguous free extent and uses that same volume for boot files, local Setup
source and Windows. Existing partitions remain outside the reservation. The
planner retains the 128 GiB placement limit for old XP media. A whole-disk reset
therefore produces one primary partition; preserve mode keeps existing partitions.

Preparation starts with FAT32 so the existing Microsoft NT52 bootstrap works.
The default answer file requests `FileSystem=ConvertNTFS`; XP performs the
conversion during Setup. `MIGRATE.INF` assigns C: using the verified MBR signature
and the volume's byte offset. The custom user-SIF path remains separate and does
not have its answer file overridden.

## First-restart diagnosis

The initial one-volume experiment copied files successfully but its first restart
reported missing NTLDR. Read-only inspection proved NTLDR and BOOT.INI existed;
BOOT.INI correctly targeted partition(1). XP had replaced the Strategy B MBR and
the FAT32 VBR, leaving the staged 255-head BPB against VirtualBox's 240-head BIOS.
A two-byte correction of the stopped test VDI's BPB allowed the same installation
to boot, convert to NTFS and reach GUI Setup.

The production preparer now persists the selected target BIOS's AH=08 heads/SPT
in primary and backup BPBs for the single-volume path. Strategy B remains the
initial bootstrap, while XP's successor loader inherits the matching geometry.
A fresh run (`zig-out/xp-single-nikka4`, `USOS-XP-Single-Final`) then passed text
copying and entered GUI Setup automatically without any post-staging disk patch.

## Validation

- 14 partition planner tests passed, including occupied extents, overlap,
  insufficient contiguous space and the 128 GiB cap.
- Three migration-map tests passed: exact binary identities, offsets above 4 GiB,
  invalid input and completion without reading terminal input.
- `zig-out/xp-single-preserve`: existing partition entry and sentinel data survived
  actual staging; only one shared Setup/Windows partition was added.
- `zig-out/xp-single-format`: stock XP SP2 prepared through the graphical mouse
  disk-selection/whole-disk-format/confirmation flow; one partition, matching
  primary/backup VBRs, 240/63 BPB geometry and C: mapping verified.
- Unit, startup and UEFI x86-64/ARM64 tests passed.

The earlier `xp-single-nikka` and `xp-single-nikka2` preparation runs stopped on
an mcopy host-file overwrite prompt. Finalization now removes its own temporary
readback file before each mcopy. `xp-single-nikka3` is the geometry diagnosis,
not evidence of an unmodified complete installation.

The fresh NiKKA run reached the desktop with `SystemDrive=C:` and
`SystemRoot=C:\WINDOWS`. Its native Setup removed `$WIN_NT$.~BT`, `$WIN_NT$.~LS`,
`$LDR$` and root TXTSETUP.SIF. No USOS cleanup script was necessary. The customized
ISO left a small .NET decompression log; normal Windows boot/system files remain.

After a normal guest shutdown, `verify_xp_single_vdi.py` confirmed exactly one
active primary partition, type 07, NTFS with 4 KiB clusters, start LBA 2048,
234438656 partition sectors, and matching 240/63 geometry. A subsequent cold
start reached the desktop again without USB, ISO or another attached disk.
Evidence is in `zig-out/xp-single-nikka4`: `gui.png`, `late-setup.png`,
`root-inspect.png`, `volume-info.png`, `desktop.png` and `cold-boot.png`.
The provided key was entered only in the isolated guest; no activation occurred.

Final release build `B260909-202906-2B3B881B` and the full Go/Zig/startup/UEFI test
suites passed. The physical Intel disk was not written.

Kingston deployment completed with `RESULT=PASS` in
`zig-out/xp-single-kingston-update.log`. Disk and partition GUIDs/extents were
preserved; payload and embedded installer readbacks matched. The release
initramfs SHA-256 is
`08296B910D672DF422C6E94B6CDA42E8E84CDA9C0C11D5ABE267259F8435CE18`.
