# Handoff 2026-09-28: USOS 1.0.0 release preparation

## Required build input outside git (do not delete)

`artifacts\vista\hardware-success-v11-20260920-235629\` is **git-ignored**
(`/artifacts/` in `.gitignore`), but it is a **required build input**:
`tools/build_windows_vista_support.py` builds the frozen Vista payload
(`vista-support.cpio`, first-boot helper v11, certificates, the USB driver
package) from it and checks every file against its `manifest.json`. Without
it, `build.bat` cannot build the Vista path. Any cleanup of `artifacts\`
must keep this folder. A backup copy is in
`zig-out\protected-build-inputs\artifacts\vista\` (verified identical on
2026-09-28). Other build inputs outside git: the Windows 7 MSU/CAB files and
the Alpine downloads under `tools\cache` (`docs/LICENSES-AUDIT.md`).

## Release

- Version: `VERSION` (1.0.0) → `build-info.ini` `version=`, the menu headers
  ("Universal Service OS 1.0.0"), the installer ("1.0.0 (B...)").
- One command: `powershell -ExecutionPolicy Bypass -File tools\release\make_release.ps1`
  (`-Data L:\` with the XP ISOs and the PE10 donor, `-SkipBuild` to reuse the
  last `build.bat`). Output: `zig-out\release-1.0\`.
- XP packages: `build_xp_uefi_csm_trial.py --release --release-lang pl|en`
  (allowlist only, no Server 2003 bundle). Installed with
  `tools\release\install-xp-package.ps1`.
- Forbidden-content scan: `tools\release\scan_release.py` (keys, key stores,
  product keys, foreign ISOs, filled answer files), tests in
  `tools\tests\test_release_scan.py`.
- Licences: `tools\release\third-party.json`, `tools\release\licenses\`,
  `docs\LICENSES-AUDIT.md`. Hosting: `docs\release-hosting.md`.
- Test plan for the user: `docs\RELEASE-TEST-1.0.md`. Tag `v1.0.0` only
  after it passes. Nothing was deployed to the Kingston.

## Open decisions before publishing (from the licence audit)

- USOS itself has no licence file yet.
- Microsoft files inside the installer payload (Windows 7/Vista update CABs,
  NVMe files, USB 3 drivers) and in the XP package; GenAHCI (GPL-3.0) has no
  source available locally; the Windows/MS-DOS logo icons.
- Repair does not record the PE10 donor (only Install and Update call
  `ensureWinpeDonor`), while the installer's DATA guide says to run Repair.
