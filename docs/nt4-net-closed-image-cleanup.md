# NT4 NET04–09 closed-image cleanup

The completed tuple09 qualification is pinned in `511b44a221e171f82414618b8004d0404b021b2c`; S20 is committed separately as `40e98cd1256384602311db13e07ae934d7830189` in usability-usb-net. The user and root explicitly authorized cleanup of only the owned completed NET04–09 qcow2 files and read-only08b alias. No further Windows VM is started.

Before any deletion, the immutable manifest pins 14 literal absolute file names, 13 unique Windows file IDs, their full SHA256 hashes, hardlink counts, backing chains, completed writer/reader evidence, and 194 retained C proof files plus 20 archived sanitized collector transport files. No alias09 exists. The unique qcow2 file lengths total **2,297,694,720 bytes**; this is not the virtual capacity or a measured filesystem free-space delta.

Deletion order is09 target and standalone USB media,08b alias,08 target and blank media,07 target and blank media, then06/05/04 targets and standalone blank media. The retained backing parent `G:\USOS-Kolekcja\_vm\nt4-sp6a-desktop-net-ps2-candidate03\target-retained.qcow2` is excluded and must retain SHA256 `cf04c232df2dc3bcbc2775c0d31963fd1fc4abd4daf7a2967eba9be1f8af2a21`. Other-agent USB images were separately cleaned under their own receipt; they are not included here. No NT3, macOS, directory, log, source, cache, physical device, or Microsoft export is deleted.

The actual Windows exclusive-handle test passed on two synthetic C hardlinks: existing/new READ/WRITE handles are rejected, metadata handles remain possible, file IDs and full hashes match, and unlinking alias then final representative completes after closing the lease. The real executor must acquire all unique file groups with the same READ+DELETE/share-DELETE lease and revalidate their IDs, sizes, link counts, hashes, closure proofs, C proofs, and protected parent before any unlink. Unknown dependencies, locks, changed hashes or paths cause refusal without retry or bypass. The reviewed graph is09→08→07→protected03;04/05/06→protected03. The08b name is a second hardlink of08, not another physical file.

Exact pre-delete source, manifest and host-test snapshots are in `tools/tests/coverage/nt4page_snapshot/installed03/cleanup-net09`. The actual executable remains `artifacts/nt4-success-review/cleanup_nt4_net_closed.py`, SHA256 `00d36277e3dc8c3cedc7a62a1cd542a3f7395599e8b9f96e39a40e925099633d`. A separate receipt and summary will record actual results after the single execution; this initial commit records **prepared, not deleted**.


## Actual completion

The single execution passed. Exactly **14 declared qcow2 names /13 unique file IDs** were unlinked under exclusive READ/WRITE exclusion, after all leases and pins had passed. The08b alias was removed before the08 representative and09 before its08/07 backing parents. There were **no refusals, retries or bypasses**. The total unique qcow2 file lengths deleted were **2,297,694,720 bytes (about2.140GiB)**; filesystem free space was not polled.

Protected candidate03 retained SHA256 `cf04c232df2dc3bcbc2775c0d31963fd1fc4abd4daf7a2967eba9be1f8af2a21` before and after. All declared names were absent at completion; their directories and non-qcow2 contents remain. No09/08/07 target remains available for a future cold boot. All **214 retained C proof/transport file hashes** were independently rechecked after the unlink and remained unchanged. The exact receipt and post-delete verification are adjacent to the pre-delete snapshot in `cleanup-net09`.

Pre-delete authorization/pins commit: `1746d9adb5f6514da0f58df73e2935a45120148e`. Tuple09 runtime/strict LAN/HID/MSC results and historical05/06/07/08 findings remain unchanged; cleanup does not add a fresh AUTO, physical X470 or full IRQ-route qualification. The tuple09 final disk/media hashes in its qualification report now describe completed and removed own images, with proof retained in C.
