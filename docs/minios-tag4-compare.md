<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Type 4 differential comparator prototype

This is a **host-side evidence comparator**, not a metadata collector. It does
not itself open NTFS, prove that the collector examined it, determine the
meaning of tag 4, or prove that any difference causes a boot failure. Its receipt
records this limitation. No production comparison is valid until the collector
has been implemented and independently reviewed.

The existing `1c0/oracle-win11-01/manifest.json` pins index 2 of the Win11 WIM
and the SHA-256 of `tree.jsonl`, which contains every `tagged_metadata` item,
including values and paths. Its histogram says 86217 type-4 items. Counts of
items and paths are reported separately, because more than one item may occur
on a path. Both captures must refer to this same WIM hash, index, tree hash,
and a completed DISM apply or MiniOS apply **before first boot**.

Each side needs a reviewed capture receipt (`minios-tag4-capture-v1`) with:

* `locked_readonly_during_capture: true`, `manifest_sha256`,
  `source_wim_sha256`, `wim_index`;
* exact virtual disk size, NTFS partition byte offset and length as
  `virtual_bytes`, `partition_offset`, `partition_bytes`;
* a complete ordered QCOW or raw chain as `chain` objects, each containing
  absolute `path` and `sha256`, including backing files;
* `evidence: {path, sha256}` for the JSONL observation file.

The collector must independently discover and validate GPT/MBR and chain
geometry and lock every backing file against writes/deletion while it reads
them. `inspect_ntfs.Image` has a default first-partition selection unsuitable
for GPT disks with an ESP first; pass explicitly validated NTFS partition
offset and size and the QCOW mapped reader instead. The comparator checks
arithmetic bounds but does not parse the partition table. It reopens and hashes
the full chain under deny-write locks before and after comparing. The required
runtime volume GUID and input receipt SHA-256 pins guard identities. A receipt's
claim that capture was locked requires independent verification of the actual
collector; a fabricated receipt can still lie.

Every observed JSONL row has a relative exact `path` and five fields, `attrs`,
`reparse`, `ea`, `ads`, `security`. Each is `{"known":false,"reason":"..."}`
or `{"known":true,"value":...}`. Values are:

* attrs: unsigned integer Windows/NTFS file attributes;
* reparse: null if conclusively absent, otherwise `{tag, data_hex}`;
* ea: complete array of `{name, flags, value_hex}`;
* ads: complete array of `{name, size, sha256}` (named streams only);
* security: `{revision, sbz, control, owner, group, sacl, dacl}`; the latter four are hex
  bytes or null when conclusively absent, not null when unavailable.

Empty inventories must be established, not assumed. Unsupported NTFS data,
incomplete attribute lists, inaccessible SACL, ambiguous names, or compressed
streams the collector cannot verify are UNKNOWN, never a match. Compare
security descriptor revision, SBZ, control and complete owner/group/SACL/DACL
bytes rather than offsets/IDs; ACL header flags and all ACEs remain in those
raw bytes. Missing revision/SBZ/control is UNKNOWN. Sort EA/ADS by exact
name. Case folding is not invented, all path/name bytes are compared exactly;
reparse content is exact, so different drive-letter targets require separate
documented RP_FIX classification, not silent normalization. Differences from
Windows-added setup/boot files need separate classification, not concealment.
Retain path, tag value, both observations, and per-field status in `diff.jsonl`.

`test_minios_tag4_diff.py` uses only tiny synthetic byte fixtures under the local test directory; it
tests matches, differences, unknowns, duplicates, count distinction, SHA,
volume identity, WIM index and repeated image identity. It does not validate
real collector behavior, the 86217 cases, or Windows compatibility. Tracked as experimental tooling; synthetic tests do not validate the collector on real images.

## Collector prototype

`tag4_collector.py` provides a capture plan interface; it validates selected
GUID on a 512-byte-sector GPT including both header/array CRCs, bounds and
overlaps, checks the `NTFS    ` boot signature, locks and hashes all explicitly
pinned raw/QCOW backing files, obtains a read-only `qemu-img map`, and checks
chain and hashes again. Evidence output is capped at 512 MiB; 1 GiB beyond
the required runtime-volume reserve is checked before output. No unsupported image format
or failure is accepted as an empty result.

The plan schema `minios-tag4-capture-plan-v1` contains `virtual_bytes`, `chain`
(ordered `path`/`sha256` objects), `partition_guid`, `partition_offset`,
`partition_bytes`, plus `tree` and `wim_receipt` objects with `path`/`sha256`.
Inputs must be closed owned regular files. Run only after the image-producing
VM process has exited; deny-write locks then independently prevent writers.
The exact `qemu-img.exe` has a supplied SHA-256 pin. The generated `receipt.json`
is the input receipt for the separate comparator; preserve the plan, map,
metadata, stdout log and both receipts.

Implemented raw categories: SI attributes; `0xc0` full reparse payload;
paired `0xd0`/`0xe0` EAs (EA names are emitted as hexadecimal bytes); named
`0x80` DATA streams with logical length and SHA-256; and the four SD components
plus revision, SBZ and control from `$Secure:$SDS` or inline SD. Resident and initialized
uncompressed nonresident streams are supported, including zero-filled VDL.
Unsupported compressed/sparse/encrypted named streams, incomplete lists and
inaccessible individual SDs give UNKNOWN. Whole-volume failures in the
independent path or `$SDS` scanner abort capture without a receipt: never
treat absence of a result as PASS. The existing scanner also assumes 4 KiB
clusters, 1 KiB MFT records and a valid `$ObjId` index; full NTFS generality
is not claimed. ADS values above 8 GiB are UNKNOWN. Known-value EA absence
requires both EA attributes absent after complete attribute-list validation.

`test_minios_tag4_collector.py` tests synthetic GPT, bad CRCs and wrong identity,
resident reparse, EA info/data validation, ADS hashing and refusal, security
component parsing, incomplete attribute lists, and receipt protocol. Those
fixtures do not test a real DISM-produced volume or nonresident ADS in Windows.
Both collector and comparator remain unreviewed prototypes until tested on
closed genuine images under a clean HEAD and their logs are preserved.

## Standalone VHDX prototype

The collector may accept a single pinned `.vhdx`, after independently checking
its signature, checksums and clean log in both headers, identical CRC32C-checked
region tables, bounded disjoint metadata, explicit virtual size and absence of
both the HasParent flag and parent-locator metadata **before** calling QEMU.
It rejects unknown metadata and region kinds, other backing files, malformed
or unsupported images, and all active logs. Layout definitions were checked
against the locally supplied `doors/LiberNT-main-nt10/modules/rosv/include/rosv/vhdx.h`;
this is an independent restricted parser, not a complete VHDX implementation.
After preflight, the fully present fixed-image BAT supplies bounded physical
offsets; `qemu-img map -f vhdx` independently must describe a complete,
standalone, uncompressed data image. QEMU may omit physical offsets for VHDX;
any offsets it does return must match the BAT. Unknown, compressed, sparse or
otherwise unmappable data causes refusal. The image remains deny-write
locked, gets hashed again and is revalidated after capture.

The CRC, corrupted headers, parent flag/locator, table disagreement, incorrect
geometry, and refusal before invoking QEMU have synthetic tests. No real VHDX,
Windows-produced VHDX, QEMU VHDX map, or DISM volume has been tested yet;
there is no production PASS. In particular, the VHDX fixed/leave-allocated
flag and current physical allocation do **not** establish a hard upper bound
on future file growth by Windows. No space-safety guarantee is inferred from
the flag: creation and mounting still require a separately verified enforced
bound and adequate space.
