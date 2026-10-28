# MiniOS: offline REGF and BCD

SPDX-License-Identifier: GPL-3.0-or-later

`src/prep/regf.zig` writes a clean REGF hive from scratch and edits an existing
clean1.3/1.5 hive in memory. The caller owns file replacement; the library does
not load a registry key or create transaction logs. Existing classes, security
descriptors, timestamps and unrelated keys/values retain their original cells.
New keys inherit the parent's security cell. Deleted replacement cells are
coalesced and reused. The base-block checksum and equal sequence numbers are
sealed only after successful modification.

The API covers all registry value type numbers as raw bytes, including default
and empty values, compressed/UTF-16 names, `lh`/`ri` directory indexes and `db`
segmented values. Every big-data segment has capacity16344bytes, including the
last partial segment; native Windows rejects a shorter last segment. Writing
big data upgrades a1.3 hive to1.5. Input allocation/cell boundaries are checked;
dirty hives and transaction-log recovery are refused. Limits are64MiB/hive,
16MiB/value,100000values/subkeys per key,512key levels and32index levels.
These are explicit bounds, not a whole-SYSTEM-hive streaming editor. BCD is small
and uses the caller's allocator; its program-memory peak belongs in the full
firmware allocation measurements.

`src/prep/bcd.zig` exposes `create(allocator, Options)` and
`fromTemplate(allocator, bytes, Options)`, returning caller-owned hive bytes.
Options contain firmware mode, separate system and Windows devices, loader GUID,
locale, description and timestamp. GPT devices encode both disk and partition
GUIDs in GPT byte order; MBR devices encode signature and byte offset.
The descriptor's88bytes match Windows BCD WMI
`SetQualifiedPartitionDeviceElement` for both styles. Production callers supply
their own loader GUID; the well-known template GUID is only a fixture default.
The installed-Windows loader always has `winpe=false`, even when editing a setup
template. This module does not disable driver-signing or integrity policies.

The manager points to `bootmgfw.efi` for UEFI and `bootmgr` for BIOS; the selected
loader points to `winload.efi` or `winload.exe`, has matching device/osdevice,
systemroot, locale, inheritance, default/display order and timeout. Resume and
memory-diagnostic entries are optional and are not synthesized in the minimal
store. Boot-file copying and MBR/PBR execution belong to the separate boot stage.

## Independent gates

`tools/minios/bcd_oracle.py` reads originals using third-party python-registry
while a Windows file handle denies writing and deletion. It compares every raw
value and key with expected fixtures, including a131129byte segmented value and
an edit of a real Windows BCD template. The parser's high-level `raw_data()` has
an inline big-endian-DWORD limitation; the adapter uses that same independent
parser's low-level VK accessor for inline bytes and checks the result with
native Windows. Neither the independent parser nor this adapter is the Zig
writer/reader.

Native `RegLoadAppKeyW(KEY_READ)` and BCDEdit are additional acceptance tests on
separate writable copies. These APIs request write access to the hive file even
when only reading registry keys, so they cannot truthfully be called physically
read-only. BCDEdit can remove `Description/TreatAsSystem` on its copy; every other
key/value must match, and the original remains protected. `RegLoadKey` and host
registry writes are never used. All native logs and copies remain evidence.

`bcd_compare.py` compares the complete default boot route against a real
`bcdboot` result from the same guarded virtual partition layout: manager and
loader classes, default/display selection, qualified devices, paths, locale,
systemroot and installed-Windows mode. Different generated loader GUIDs are
normalized by following the default; optional recovery/resume/debug objects are
recorded in full manifests. The parent virtual-disk gate supplies a completed
receipt binding the exact reference SHA-256, successful `bcdboot /s` and no
physical-disk writes. Full first boot remains a subsequent gate.

Sources: [libregf format documentation](https://github.com/libyal/libregf/blob/main/documentation/Windows%20NT%20Registry%20File%20%28REGF%29%20format.asciidoc),
[Microsoft qualified partition devices](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/bcd/bcddevicequalifiedpartitiondata),
[Microsoft BCDBoot behavior](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/bcdboot-command-line-options-techref-di),
[python-registry](https://github.com/williballenthin/python-registry).
No source or binary from Microsoft is committed by these modules.
