<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# MiniOS 1c-0 - pre-integration corrections

Complete for independent review on 2026-10-25. Same branch `codex/minios-etap1`;
no merge, push, deployment, physical disks or next stage. Final evidence:
`minios-evidence-1c0.json`; image candidates: `minios-retained-images-1c0.json`.
Final host SHA256: `98895812814b47cf0490855222bb7f2591082b8029dcf49de699e1f3a92f7891`.
699 Zig tests and 176 Python tests (zero skips, including native header ABI proof) PASS. All eight final
Windows read-only gates have exact tree/streams/metadata and plain chkdsk0.

## Behavior

- RP_FIX requires header 0x80 and a clear entry NOT_FIXED flag. Rewrite absolute
  DOS-rooted junction/symlink targets to the explicit logical destination
  (`--target-drive C`, default C), after original resource SHA1 verification.
  Relative, external and NOT_FIXED entries remain exact. Integration must
  supply the intended Windows drive; the oracle's temporary host alias is
  not that drive. Win7 and Vista each rewrite 44 entries, 43 junctions and one symbolic link.
- Preserve image DOS aliases as WIN32/DOS or combined namespace entries without
  inflating hardlink counts. Windows supports one DOS pair per inode. Vista
  exposed a real bug in multiple pairs; secondary links now stay POSIX, as in
  public wimlib win32_apply.c. Keep all source alias spellings in the oracle,
  report normalization, and check exact absence on secondary paths. Choose the
  primary from independently parsed stored-WIM DFS keys, not sorted iteration
  order or target observations. A two-hardlink fixture and opposite-iteration
  oracle test cover the bug. Offline unlink of DOS-paired files refuses;
  fresh WIM apply never unlinks. Live Windows owns subsequent file operations.
- Object IDs: 16-byte file OBJECT_ID plus all 48 extended bytes in $ObjId:$O,
  with ULONGS collation and file references. Win7 preserves 77 source entries
  across 42 inodes. Extended attributes preserve names, flags and binary values
  in EA/EA_INFORMATION, including nonresident EA. The final on-disk next offset
  is aligned/nonzero, unlike the Windows query API buffer. Win11 preserves
  25056 source EA entries across 14104 inodes.
- Count tagged metadata by type. Win11's 86217 type4 entries remain explicit
  omissions. Vista's reserved zero extension space is not a tagged-item type;
  preflight now calls that count `entries_with_tagged_space`.
- Duplicate data-resource hashes deliberately refuse, even identical copies.
  Pinned wimlib 1.14.5 verify accepts identical and conflicting duplicate fixtures.
  This stricter compatibility policy is documented; the real ten-edition
  Win11 archive has no duplicate data hashes.

## Final gates

| Source / own set | Checked entries | DOS names checked | Explicit secondary absences |
| --- | ---: | ---: | ---: |
| Win7 x86, index1/5 | 57146 | 30285 | 0 |
| Vista x86, index5/7 | 56194 | 30402 | 2264 |
| Win11 x64, index2/10 | 168751 | 82533 | 0 |
| Own NTFS feature set | 5014 | 3 | 0 |
| Own XPRESS+ADS set, each firmware case | 15 | 0 | 0 |

Eight native gates comprise those four host cases plus UEFI x64/IA32,
BIOS 486 and BIOS Pentium. All have chkdsk0, zero differences and unchanged
closed source/VHD hashes. Guards require a read-only virtual disk of the exact
image size, neither system nor boot; no repair flags or target traversal.
The same closed Vista VHD was rechecked against source-order-corrected
expectations with a pinned prior receipt; failed results remain preserved.
This does not claim booting the applied Windows or testing every edition.
All resources in each real archive are independently verified by wimlib and
by usosprep before target writes; explicit image selection handles multi-WIM.

Final LZX allocator peaks: Win7 3996200 B, Vista 2742120 B, Win11 8799608 B.
These are program heap measurements, not total host-oracle RSS. Small firmware
cases: UEFI 64 MiB, BIOS 486/Pentium 32 MiB; explicit i486 code target for 32-bit.
They are tested RAM values, not a new minimum search. Builds/tests use -j2,
BelowNormal and two logical CPUs; evidence records actual commands and times.

## Portable host tools and provenance

`USOS_MINIOS_RUNTIME` defaults to checkout `runtime/wim`.
`USOS_MINIOS_VOLUME_GUID` is required before storage queries, with no inferred
identity. `USOS_MINIOS_MEDIA_ROOTS` configures allowed source roots (host path
separator; default checkout `media`). `USOS_MINIOS_7ZIP` selects the archive
tool (otherwise PATH/local tools). `USOS_MINIOS_FINAL_REPORT` configures the
old cleanup helper's already completed report. The own native fixture requires
explicit Runtime, VolumeGuid and new Workspace arguments. Reparse, scope,
volume-identity and 100 GiB free reserve guards remain. Six private-path files
are corrected; nine WIM Python test files gained GPL3 SPDX headers.

The final SYS/CER audit targets exact master 0ba50f6e, read from the actual
integration checkout. Branch 74 versus master 34; 40 branch-only paths. Of 29
historical media payload paths, 28 have the same Git blob. Only XP x64
`media/Systems/Windows/Windows XP UEFI-CSM PAE/Drivers/x64/ACPI/acpi.sys` is
absent from that master and must not be reintroduced. See the final audit JSON;
no SYS/CER payload changed in this task. Conventional commit prefixes are used.

## Retention and remaining scope

User explicitly authorized deleting 23 closed superseded old-build images
(85365105664 B) after saving small proof, not moving anything to the backup
volume. A pre-deletion report, 100 retained evidence files, pinned plan and
receipt precede removal. Every deletion path/size/SHA is in the evidence JSON.
A negative guard test preserves a new-build sentinel. No corrected-build
image was deleted. All 77 retained image/vars/sentinel artifacts (~94.93 GiB)
remain pending separate acceptance; the charged pool is 113.54 GiB <=150 GiB and
100 GiB free reserve passed. The manifest lists each candidate and its proof.

Fresh usosprep NTFS only. Type4 is omitted, secondary Vista aliases normalize,
SWM and solid LZMS are explicitly outside the accepted path, duplicate data
hashes refuse. No broader Windows boot, hardware or integration claim is made.

Public format/behavior references:
- https://github.com/ebiggers/wimlib/blob/v1.14.5/src/win32_apply.c
- https://github.com/ebiggers/wimlib/blob/v1.14.5/include/wimlib/tagged_items.h
- https://github.com/ebiggers/wimlib/blob/v1.14.5/include/wimlib/xattr.h
- https://github.com/tuxera/ntfs-3g/blob/edge/libntfs-3g/ea.c
- https://github.com/tuxera/ntfs-3g/wiki/Using-Extended-Attributes#dos-names

STOP after RAPORT-MINIOS-1C0.md; await independent review.
