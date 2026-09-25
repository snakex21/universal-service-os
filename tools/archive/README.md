# tools/archive

One-off diagnostic, trace and repair scripts from the Windows XP
investigations (UEFI-CSM + PAE, GUI Setup loop, LSASS/crash-dump,
USB Setup, driver-package research), September 2026. They are kept for
reference and reproducibility of the evidence in `docs/`, but they are
not part of the build, the release, the installer or any test suite.

Rules for this folder:

- A script is moved here only when nothing references it: `build.bat`,
  `build.zig`, the scripts in `tools/`, the tests in `tools/tests/`,
  `src/`, `installer/` and the docs were grepped for its name before the
  move (2026-09-25). Scripts still named anywhere stay in `tools/`.
- The scripts were written to run from `tools/`. Most compute the repo
  root as `Path(__file__).parent.parent` or `$PSScriptRoot\..`, and some
  import sibling modules (`build_micro_linux`, `repair_vista_drive_mapping`).
  To run one again, `git mv` it back to `tools/` first.
- Several of them read or write a USB stick (`J:`/`L:`) or a physical
  disk. Do not run them without checking the target first.
- No script for the Windows 10/11 native UEFI fixes (2026-09-25) was
  archived: `tools/compare_esp_snapshot.ps1` and the harness in
  `tools/tests/windows_native/` are still in use.

Contents:

- `check_xp_gui_files.py`
- `check_xp_trace_evidence.py`
- `check_xp_ui_payload_delta.py`
- `check_xp_volume_readonly.ps1`
- `deploy_xp_setup_diag.ps1`
- `deploy_xp_setup_dump_workaround.ps1`
- `deploy_xp_setup_trace.ps1`
- `fetch_xp_pae_review.py`
- `find_xp_driver_downloads.py`
- `inspect_xp_after_trace.py`
- `inspect_xp_crypto_dependency.py`
- `inspect_xp_driver_packages.py`
- `inspect_xp_dump_failure.py`
- `inspect_xp_dump_state.py`
- `inspect_xp_emu_source.py`
- `inspect_xp_integration_inputs.py`
- `inspect_xp_iso_pae_files.py`
- `inspect_xp_kernel_map.py`
- `inspect_xp_kernel_versions.py`
- `inspect_xp_lsass.py`
- `inspect_xp_pae_source.py`
- `inspect_xp_pae_upstream.py`
- `inspect_xp_retry_delta.py`
- `inspect_xp_sp2_source.py`
- `inspect_xp_trial_assets.py`
- `inspect_xp_trial_base.py`
- `inspect_xp_usb_setup.py`
- `prepare_xp_setup_diag.py`
- `prepare_xp_setup_dump_workaround.py`
- `prepare_xp_setup_trace.py`
- `prepare_xp_single_cpu_trial.ps1`
- `read_xp_recipe.py`
- `repair_xp_native_usb.ps1`
- `snapshot_xp_lsass.ps1`
- `stage_xp_driver_candidates.py`
- `stop_xp_broad_search.ps1`
