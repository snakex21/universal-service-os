# Selected-image streaming verification

SPDX-License-Identifier: GPL-3.0-or-later

The default `verify_scope=selected` verifies the selected metadata SHA-1
before target preparation. Structural preflight resolves every referenced
stream and inventories unsupported metadata before formatting. DATA, ADS and
reparse blobs are SHA-1 checked while streamed into the fresh volume. The
final chunk is not returned to the writer until its hash matches. No existing
NTFS volume is accepted by the installer.

The NTFS dirty flag remains set until every selected stream, index and bitmap
has completed. Any apply error persists the dirty flag, refuses success and
logs `TARGET_INCOMPLETE`. This is also attempted if the final flush fails.
It is an incomplete target, not a resumable or bootable installation.

Explicit `verify_scope=all` retains the archive integrity-table check and
verification of every blob in every edition before partitioning, followed by
the same per-stream checks during apply. Unreferenced corrupt blobs therefore
fail `all` but do not prevent an otherwise valid selected image from applying.
Neither mode permits bad selected metadata or a bad selected stream.
Unnamed DATA on a directory/root is explicitly unsupported: preflight refuses
any nonzero reference before formatting. It must not skip a referenced blob
and later report selected integrity success. Directory ADS and reparse data
follow their supported stream mappings.

UEFI config accepts `verify_scope=selected|all`; duplicates and unknown values
are rejected. The BIOS checksummed config uses byte152 (0 selected,1 all);
remaining reserved bytes must be zero. The host apply client accepts the same
`verify_scope=...` option. The archive-wide raw integrity table is not scanned
in selected mode, because it also covers other editions; selected resources
retain their individual SHA-1 checks.

Guest `PROGRESS` lines cover metadata verification, structural preflight,
optional archive checks, blank-target scanning and apply. They report at
256MiB or2000resources, plus phase endpoints. Firmware counters measure actual
source/target BlockIo calls including bounce reads; diagnostic file-protocol
writes are excluded. The stack high-water mark is sampled from the painted
owned stack only at reporting boundaries. All caches use the tracked heap.

Focused regression cases include selected-vs-all corruption, metadata refusal
before target IO, streaming DATA corruption retaining NTFS dirty state,
scope parsing, progress thresholds, bounded caches and i486 code audit.
Final firmware/native/first-boot acceptance is recorded separately.
