<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# MiniOS optical follow-ups for 1c-2

These changes extend the accepted 1c-1 reader. They do not install boot files
or change the Windows source tree.

| Review item | Result / interface |
|---|---|
| F-a | ICB System bit 10 is readable. Only mask `0x1800` requires an unsupported transform. |
| F-b | Invalid or unreadable primary anchor at 256 tries N-256 and N; N is the last optical block. All failed candidates retain a specific error, with no ISO downgrade after UDF recognition. |
| F-c | Directory enumeration skips and counts symbolic links, named streams, stream directories, CS0 254/255 and other unsupported optional file entries. ISO associated streams have the same policy. `find` refuses the named unsupported target. Corrupt mandatory structures still fail closed. |
| F-d | `optical.Walker` owns a global one-million physical-record budget, including skipped entries. Depth is 64, path length 4096 bytes and directory data 64 MiB. Its frame and path buffers are allocated from the supplied bounded allocator. |
| F-e | `Stream.last_error` records the original error. Native IO and bounds survive the platform mapping; `optical_wim` logs original and mapped errors. The NTFS adapter separately records `Source.last_error` for its inner NTFS failure. |
| F-f | `ntfs.LargeFile` resolves unnamed DATA via resident/nonresident ATTRIBUTE_LIST and up to 8192 physical runs. Record sequence, base reference, attribute instance, VCN continuity, disk bounds and physical overlap are checked. The legacy 128-run FileSystem/MFT representation is unchanged. |
| F-g | `findInstallWim` prefers WIM and distinguishes unsupported ESD and split install*.swm, with actionable logs before target writes. |

CS0 254/255 decode to empty, unique identifiers and do not identify a path
component. They are counted as nameless entries, including deleted FIDs.
Attached named-stream directories are not followed as normal file directories.
The source-only API never follows symbolic links.

## NTFS source bounds

The DATA run array is heap-backed and its capacity is capped at 8192 entries
(262144 bytes on the tested host). An ATTRIBUTE_LIST is bounded to 256 KiB;
its own nonresident runlist currently uses the bounded legacy 128-run reader.
The input is a read-only callback: no writer or flush callback is accepted.
The resolved stream uses binary search for offsets and does not reload the
runlist for every WIM read. Release it with `Source.deinit`.

Explicit refusal remains for compressed, sparse, encrypted or uninitialized
DATA, unsupported record geometry, over-budget runlists/attribute lists, and
an MFT which itself requires ATTRIBUTE_LIST bootstrapping. The latter returns
`UnsupportedMftAttributeList` rather than silently reading a partial MFT.
This is separate from supported ATTRIBUTE_LIST on the ISO file.

The regression fixture is a small own Joliet ISO copied by Windows CopyFileW
onto a newly Windows-formatted, exactly guarded 512 MiB VHD. Windows
FSCTL_MOVE_FILE scatters 512 clusters into 512 physical extents, forcing
ATTRIBUTE_LIST and extension records. The native verifier remounts read-only
and runs plain `chkdsk`. A separate byte parser verifies all ISO bytes and
extent/attribute-list structure; the MiniOS reader's tree and SHA-256 values
are compared with streamed 7-Zip output. All images remain retained.

## Firmware stack and sectors

`Volume.listInto` and `findInto` avoid additional by-value Node arguments;
the shared Walker uses allocator-backed frames rather than recursion.
Node still contains at most 256 optical extents. Firmware must measure its
actual stack high-water mark: struct sizes alone are not that measurement.

The common API uses byte offsets. Its 2048-byte optical blocks are independent
of 512-byte or 4096-byte backing-device sectors; both are covered by a common
read-only test. Firmware block backends must perform their own physical-sector
rounding and bounce-buffer IO. The optical layer does not assume a disk LBA is
an optical LBA.

References: ECMA-167 3rd edition, sections 4/14.6 and 4/14.17; OSTA UDF 2.60
section 2.1.1; Microsoft `FSCTL_MOVE_FILE` and `FSCTL_GET_VOLUME_BITMAP` public
API documentation. No third-party implementation code is copied here.
