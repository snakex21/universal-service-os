# Media coverage helpers

Local research tools for `codex/macierz-windows`; not an installer release.
The matrix is an explicitly incomplete checkpoint until every required
installation and exact-image hardware binding has been assessed.

- `inventory.py`: SHA-256 of the Windows library and the allowed collection;
  prune scratch and macOS trees, reuse unchanged input hashes on the second pass.
- `media_probe.zig`: run production optical/identity parser APIs and export the
  real catalogue with `--catalog`. Its legacy API output is **not** evidence
  that the UEFI UI calls that parser; the UI currently chooses legacy entries
  from their catalogue folders. Actual UI results come from QEMU traces.
- `inspect_media.py`: bounded metadata and binary versions, archive member
  SHA-256; extract archives only into owned collection scratch and remove them.
- `driver_audit.py`: original NT5 prerequisite audit, reusing `pe`/`resolve`
  from `check_nt52_driver_imports.py`, including forwarder chains. It does not
  prove ABI/runtime compatibility or that source-bound XP edits can be applied
  to another SP. No Microsoft source tree is needed.
- `unpack_bytes.py`: the Windows 7-Zip build cannot seek CAB stdin; use a
  temporary owned G: input instead. Decompressed PE bytes stay in memory.
- `discover_downloads.py` / `download_media.py`: one-time Windows download plan,
  published whole-file hash validation, collection index; refuse replacement
  of existing media. The plan/report is written before transfer.
- `download_apple.py` / `apple_integrity.py`: Apple full packages. Catalogue
  `Digest` checks the compressed XAR TOC, **not** the complete PKG. Check all
  SHA-256 blocks using Apple's HTTPS `integrityDataV1` as well; method 2 is
  a self-checking manifest, not a digital signature. Record a full-file SHA-256
  locally. These downloads are not bootable ISO files.
- `download_apple_recovery.py`: invoke the pinned existing OpenCore recovery
  utility with a documented public board ID and placeholder MLB; verify the
  signed recovery chunklist. Recovery is an online-install environment.
- `prepare_stick.py` / `boot_menu.py`: disposable qcow2 fixture and OVMF menu
  adapter. The former boots Linux directly only to construct the test stick;
  the OS flow starts from OVMF, the unmodified UEFI menu and the product
  preparation scripts. Optional guest-only printf observation lines announce
  framebuffer menus/notices. They alter no selection or disk-write decision.
  Endpoints require assessment: `ASSESS_ENDPOINT` is never desktop PASS.
  Known catalogue rows without images remain selectable, so choose the actual
  system row rather than pressing Enter on the first row.
- `write_matrix.py`: render a clearly unfinished inventory checkpoint.

All new media/scratch is under `G:\USOS-Kolekcja`; other G: paths are never
traversed. No physical disk is attached to a writable VM. Keep at least 100 GiB
free and 8 GiB available host RAM, at most three VMs globally. VM disks are
thin qcow2 and are removed after saving each result; NVRAM is removed too.
Wait for serial input, QMP replies or process completion. Do not sample logs,
screenshots or process status to collect progress. A bounded endpoint image
is not evidence that Windows itself hung.

Local defaults reference the development PC's assets and collection; pass
explicit inputs. Keep product keys in the private test-key directory and do
not place them in tool arguments, Git, logs or unknown-state screenshots.

Run the integrity regressions from the worktree:

```powershell
python -I -B tools/tests/coverage/test_integrity.py -v
```

The synthetic tests distinguish a valid XAR TOC digest from a whole-file
digest, reject changed TOCs/manifests/blocks, check catalogue size and ensure
CAB temporary inputs are removed. Actual-media checks and QEMU evidence are
in the local ignored `artifacts/coverage/` directory; binaries are not committed.
