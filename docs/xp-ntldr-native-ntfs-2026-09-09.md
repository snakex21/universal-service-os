# XP first-restart failure: physical Intel and native NTFS

The physical Intel was prepared while USB was BIOS disk 0x80; its recorded
geometry was 240 heads / 63 sectors. After XP text-mode Setup, NTLDR and a correct
partition(1) BOOT.INI were present, but XP had replaced the FAT32 loader. A sparse
read-only clone reproduced "NTLDR is missing" with VirtualBox at 255/63.
Disabling the four-byte CHS branch in that clone allowed NTLDR and the XP kernel
to load. The clone then stopped with 0x7B on the different virtual controller;
this is not evidence that the physical installation completed.

## Repair of the existing installation

`zig-out/repair-intel-ntldr-edd.ps1` verified PhysicalDrive9, its size, partition
offset/size, MBR signature 0x84a8d49f and exact previously read boot sectors.
With the volume locked and dismounted, it changed only VBR bytes 230..233 from
0F824A00 to 90909090. Readback confirmed the change and an unchanged MBR/BPB.
No format, reinstall or file changes were performed. Backups and reproduction
screenshots are under `zig-out/xp-physical-ntldr-failure`.
The user subsequently reported "działa super" after the requested physical
hardware check. This confirms the reported XP flow works on their test setup;
the message does not distinguish a resumed installation from a fresh reinstall
or provide a separate verification of every filesystem/cleanup detail.

## New installations

The automatic path creates one native NTFS volume with 4 KiB clusters and puts
both the local Setup source and Windows there. The same guarded contiguous
reservation, 128 GiB placement cap and signature/offset C: mapping remain.
`FileSystem=LeaveAlone` preserves the already prepared NTFS filesystem.

The NT52 NTFS template is extracted from bootsect.exe and its CHS branch is
disabled only after matching the exact instruction signature. The EDD capability
check and read-error handling remain intact. Merely switching to NTFS without
this patch also failed the changed-geometry test. Primary and backup boot-sector
writes are read back; mkntfs's BPB and filesystem metadata are preserved.

Source-copy and DOSNET alias validation share an I/O adapter for mounted NTFS.
The custom user-SIF/FAT32 path remains separate. Automatic installations retain
an `xp-install-record.ini` audit record instead of creating an active
`xp-resume.ini`, because the target disk continues Setup itself.

## Validation

- `USOS-XP-Native-NTFS`, NiKKA SP3, a single 120 GB virtual disk: prepared with
  BPB 240/63 and booted with BIOS 255/63. The initial diagnostic image received
  the same four-byte NTFS EDD patch before Setup. Text-mode copying and the first
  restart reached GUI Setup automatically; no post-text-mode repair was made.
- `zig-out/xp-native-preserve`: final production staging with the extracted,
  patched template preserved an existing partition and its sentinel bytes.
- Source I/O tests cover recursive copies, compressed aliases, readback and
  path traversal rejection. DOSNET, migration-map and 14 planner tests passed.
- Release build B260909-212038-61FB0A6E, Go tests, Zig tests, startup selftest and
  UEFI x86-64/ARM64 tests passed.
- `zig-out/xp-native-format`: mouse-driven selection, whole-disk format and
  staging passed with one native NTFS partition and matching backup VBR.
- The NiKKA test completed to the desktop on C:, removed its temporary Setup
  source folders, and passed a normal shutdown plus cold boot without USB/ISO.
  `verify_xp_single_vdi.py` confirmed one active NTFS partition, 4 KiB clusters,
  start LBA 2048 and 234438656 partition sectors. VBox.log confirms 255/63 BIOS
  geometry while the on-disk BPB remains 240/63.

An additional check showed that XP eventually replaces the initial patched NTFS
bootstrap; an assertion that the patch survives failed and is not a requirement
of this path. The resulting XP loader nevertheless passed the completed-system
cold boot at 255/63. Do not claim that the final Windows loader remains EDD-only,
or that this VM test proves every BIOS/controller combination.

NTFS EDD template SHA-256:
F2070782D8B42EEB87C1B5870CC5F48CD268F077B4708C10D962BAABF2E2E44F.

## Kingston deployment

The guarded physical updater completed with `RESULT=PASS` in
`zig-out/xp-native-kingston-update.log`. Disk/partition GUIDs and extents were
preserved, and payload/installer readbacks matched. Final ESP build:
B260909-212038-61FB0A6E. Initramfs SHA-256:
57E198F5993AF32730FCA407C5B2DB4CA40FB15814477E2A339864C0CFAC1A44.
The old Intel `xp-resume.ini` was checked against its saved diagnostic copy,
archived identically as `xp-install-record.ini`, and removed from the active
resume path. No fixture autoselection or obsolete handoff markers remained.
