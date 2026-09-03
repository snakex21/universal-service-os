# Pre-merge evidence

This directory freezes the evidence that existed before the UI/backend merge.

- `full-flow-disk-selection/` contains the retained logs from the successful
  `USOS -> prepare-requested -> micro-Linux -> prepared -> Windows Setup`
  QEMU run.
- `negative-device-guard/` contains the retained logs from the deliberately
  invalid WORK PARTUUID run. The guard stopped before `mkfs.ntfs`.
- `SHA256SUMS.txt` records the size, modification time, and SHA-256 of the
  relevant qcow2 and EFI artifacts. The large images remain ignored by Git.

The logs are historical evidence. They must not be treated as proof for a
new build unless that build passes the same test matrix on a fresh qcow2
overlay.
