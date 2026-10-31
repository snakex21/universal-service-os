<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# MiniOS 1c-1: read-only optical source

`src/prep/optical.zig` exposes `Input`, `Volume.open`, `Volume.list`,
`Iterator.next`, case-insensitive `Volume.find` and `Node.read(offset, bytes)`.
It shares no firmware or host types. Input is a bounded byte source with only
a read callback. `Input.fromDisk` wraps the existing block contract; it never
calls write/flush. `optical_ntfs.zig` wraps our existing read-only NTFS reader,
retaining the resolved file runlist instead of copying the ISO.

Selection: recognized UDF first, otherwise recognized Joliet, otherwise ISO9660.
A corrupt recognized UDF is a refusal, not a silent fallback. ISO level3
multi-extent lengths are accumulated in u64. UDF versions 1.02,1.50,2.00,2.01,
2.50 and2.60 accept physical maps and (2.50+) metadata partition maps. VAT,
sparable media, indirect ICB strategies and transformed data refuse explicitly.
The optical sector and logical block size supported here is2048 bytes.

All on-media spans, endian-paired ISO fields, descriptor tags, tag location,
tag checksum and descriptor CRC are checked before interpretation. Bounds:
8maps/partitions,256 file extents,32 metadata-file extents,64 allocation-chain
links,64 directory depth,64MiB per directory and one million tree entries.
Unsupported or over-budget inputs refuse. Public specifications:
[ECMA-119](https://ecma-international.org/wp-content/uploads/ECMA-119_5th_edition_december_2024.pdf),
[ECMA-167](https://ecma-international.org/wp-content/uploads/ECMA-167_3rd_edition_june_1997.pdf),
OSTA UDF2.60 sections2.2.10 and2.2.13.

The regular-image host harness `usosprep-optical` supports streaming manifests,
block-backed manifests, NTFS-file-backed manifests and direct ISO/WIM apply.
Host sources are regular files only; writable destinations additionally need
the explicit owned workspace and `--image-only` acknowledgement. The WIM API
receives an offset-addressed stream, with no intermediate install.wim copy.
Firmware integration into the installer is a later stage.

F4: this stage injects no new USOS payload files into the applied Windows tree.
The NTFS source fixture uses the already legal8.3 name `INSTALL.ISO`. Source
WIM aliases are handled by the existing DOS-pair policy. A general8.3 generator
for future USOS-added long filenames remains an explicit later integration item;
such future names must not be claimed compatible without it.

F5: WIM tagged metadata type4 remains omitted and reported. First-boot Win11
validation belongs to1c-3. F6: integration must exclude historical acpi.sys;
this stage adds no SYS/CER files and must not restore those payloads from history.

Final evidence requires clean-tree build/test logs via `logged_run.py` (HEAD and
dirty count first), -j2, BelowNormal and two CPUs. Development logs with dirty
trees are diagnostic only. Accepted1c-0 images were removed only from its pinned
77-row inventory after separate user acceptance; all small evidence survives.

## Completed stage1c-1 host evidence

`minios-evidence-1c1.json` pins the final721 Zig/210 Python tests, three real
ISO tree/SHA comparisons,15 positive/9 refusal fixtures and3072 ReleaseSafe
mutations. One reused multi-extent ISO has a4294975489-byte file and six
offset probes.7-Zip extraction cannot decode the synthetic UDF AED-continuation
case; that one uses the known generated payload SHA and independent7-Zip
listing. All other positive fixtures and all real media have complete7-Zip
stream comparisons. Actual Windows media here use UDF1.02;2.50/2.60 are fixtures.

The final direct apply gates both passed Windows read-only `chkdsk` without
switches and exact independent content/metadata comparison:Win11x64 index2
from ISO-on-NTFS,168751 entries;Win7x86 index1 from ISO,57146 entries.
No ISO was mounted and no intermediate WIM was copied. Source write/delete
sharing is denied throughout these gates. The host CLI separately refuses
multiply linked writable targets before formatting; integrators must still
protect source stability against other processes.

Measured maximum manifest heap463696B; LZX apply heap8800392B/Win11 and
3996900B/Win7 (application times353s/96s). These are tracked heap figures,
excluding stack,code,RSS and firmware. NTFS-source limits:128 runs;refuse
ATTRIBUTE_LIST,compressed,encrypted or sparse ISO data. General firmware/menu
integration and physical-device tests are later work; these are host gates.

`minios-retained-images-1c1.json` lists126 retained images/fixtures by relative
path,size and SHA256; remove only after user acceptance. Accepted prior1c0
deletions are exactly enumerated in `minios-cleanup-accepted-1c0.json`.
