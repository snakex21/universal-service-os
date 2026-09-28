# Hosting the USOS release files

The release folder (`zig-out\release-1.0\`, built by
`tools\release\make_release.ps1`) holds a few large binaries: the installer
(the whole stick payload is embedded), the WinPE donor zip (about 460 MB),
two XP package zips (about 100 MB each) and the sources zip. Every file is
checked to stay under 2 GiB, the per-file limit of GitHub release assets, so
nothing has to be split.

Nothing is published yet: the repository has no remote, and publishing needs
the user's explicit approval.

## Recommended: GitHub Releases

- Create a release for the tag `v1.0.0` (the tag is set only after the fresh
  install test passes, `docs/RELEASE-TEST-1.0.md`) and upload every file of
  the release folder as a release asset, `SHA256SUMS` included.
- Limits: under 2 GiB per file, no limit on the total size of a release and
  no bandwidth quota for downloads. Assets are not part of the git history,
  so clones stay small.
- Users download exactly the files they need (the installer alone, or the
  XP package in their language) and check them against `SHA256SUMS`.
- The release page is also where the WinPE donor and XP packages live: they
  are not stored in git.

## Git LFS: for the repository, not for downloads

The repository already routes `*.iso`, `payload.zip` and other large build
inputs to LFS (`.gitattributes`), so the Go installer can be built from a
clean clone. LFS is a poor channel for release downloads:

- the free GitHub plan includes only a small LFS storage and bandwidth
  quota (long 1 GiB each per month; check the current plan before relying
  on it), with more only as paid data; a few downloads of the WinPE donor
  would use it up;
- every rebuilt `payload.zip` is a new LFS object, so storage grows with each
  committed build. Commit payloads only for real releases;
- users would need `git lfs` or the web UI to fetch single files.

## Summary

| | GitHub Releases | Git LFS |
|---|---|---|
| Purpose | distribution of finished builds | large files inside the repository |
| Size limit | under 2 GiB per file | 2 GiB per file (GitHub) |
| Bandwidth | no quota | small monthly quota on the free plan |
| Versioning | one set of files per tag | every committed version is kept |
| For USOS | installer, WinPE donor, XP packages, sources, notices | `payload.zip` and build inputs only |

Upload the release assets to GitHub Releases, and keep LFS for what the
build needs. The WinPE donor and the XP packages contain Microsoft files;
the user has decided to redistribute them and takes responsibility for it
(`docs/LICENSES-AUDIT.md`).
