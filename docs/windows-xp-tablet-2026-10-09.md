# Windows XP Tablet PC Edition 2005 (2026-10-09)

Status: **experimental**. The entry uses the same XP x86 path from UEFI
(`xp-x86-sp3-uefi-csm`) as Windows XP and XP Media Center Edition 2005
(`windows-xp-mce-2026-10-08.md`); without CSM the installed system boots
through CSMWrap.

## 1. Menu entry

**Windows XP Tablet PC Edition 2005** (`windows-xp-tablet`) is UEFI only
(not in the BIOS Core) and sits after the Media Center entry. DATA folders:
`Systems\Windows\Windows XP Tablet PC Edition 2005\Images` and `Unattended`.

| Piece | Where |
|---|---|
| Catalog entry (gated out of the BIOS Core) | `src/catalog/windows_legacy.zig` |
| Routing as Windows XP (traits, profile, icon, `usos-xp.ini`) | `src/catalog/os_profiles.zig` |
| Answer family XP, own key field `key.windows-xp-tablet` | `src/flow/answer/target.zig` |
| Kernel argument `usos.xp_edition=tablet` | `src/platform/uefi/xp_preparation.zig` (`Nt5System.windows_xp_tablet`) |
| DATA folder / title from that argument | `tools/nt5_profile.sh` (`USOS_XP_EDITION=tablet`) |
| Heading in the micro-Linux UI | `tools/micro_linux_ui.sh` |
| The entry refuses a disc without the Tablet PC components | `tools/probe_xp_source.sh` (`tablet_pc=yes/no`) |
| CMPNENTS copied into the local source (shared with MCE) | `tools/prepare_xp_local_source.sh` |
| Driver bundle for ISOs in the Tablet PC DATA folder | `tools/build_xp_uefi_csm_trial.py` (`XP_IMAGE_FOLDERS`) |
| Summary note | `boot.summary.xp_tablet_limits` (all 27 languages) |
| Installer DATA layout row | `installer/internal/winhost/data_layout.go` |

## 2. Tablet PC specifics

- **CD2.** The retail set has two CDs; GUI Setup installs the Tablet PC
  components from CD2's `CMPNENTS\TABLETPC\I386` (`TABLETPC.CAB` and the
  compressed files next to it). `DOSNET.INF [Directories]` names it
  `d2 = \cmpnents\tabletpc\I386`, `TXTSETUP.SIF [SourceDisksNames]` the
  same. The CMPNENTS copy added for MCE (whole folder to
  `$WIN_NT$.~LS\CMPNENTS`) covers it, so no CD2 prompt is expected.
- **Two-CD media.** The `windows-xp-tablet` entry stops before any target
  write when `CMPNENTS\TABLETPC\I386\TABLETPC.CAB` is missing.
- **Product key.** The disc has no `I386\WINNT.SIF`, so the MCE disc-key
  fallback does not apply: the answer profile needs a **Tablet PC Edition key**
  (`key.windows-xp-tablet`, else `key=`), or `usos-xp.ini` / a `.sif`
  chosen in the menu. Without one, GUI Setup stops at the product key page
  (the key can be typed there). A Professional key is expected to be refused by
  this media. Although `SETUPP.INI` names the retail channel (000), the
  user's **OEM** Tablet PC key was accepted in the QEMU run (section 5).
- **Integrated SP3 media.** This disc has no `I386\SP3.CAB`: the SP3 files
  are merged into `DRIVER.CAB` and `I386` (`DriverCabName=driver.cab`), so
  the XP driver bundle build stopped at extracting SP3.CAB.
  `tools/xp_driver_overlay.py` now builds, for such media, its own SP3.CAB
  holding only the community ACPI and registers it in `TXTSETUP.SIF`
  (`DriverCabName = driver.cab,sp3.cab`, `SourceDisksFiles` directory 39,
  `FileFlags`) and `DOSNET.INF`. Microsoft-slipstreamed media are unchanged.
  Test: `tools/tests/test_xp_overlay_integrated.py`. Tablet bundle id
  `49e5ecc5...`.

## 3. The user's media

`Windows XP Tablet PC Edition 2005 SP3 EN (updated).iso` (817 512 448 bytes,
SHA-256 `169009e2...4c185ca`), library folder `OS\Windows\Windows XP Tablet PC\`:

- Volume `VX2PFPP_EN`, English, markers `WIN51`, `WIN51IP`,
  `WIN51IP.SP2`, `WIN51IP.SP3` (SP3 slipstreamed), `SETUPP.INI`
  Pid 76487 channel 000 (retail).
- One disc with `CMPNENTS\TABLETPC`, `CMPNENTS\MEDIACTR` and
  `CMPNENTS\NETFX` merged in; community-updated (files dated 2022-12).
- Host probe on the extracted media: `tablet_pc=yes`, `media_center=yes`,
  exit 0 for the Tablet, MCE and plain XP entries; no `I386\WINNT.SIF`.

## 4. Tests

- Host: `tools/tests/test_xp_tablet.py` (profile edition incl. fallback
  for unknown values, probe `tablet_pc` and refusal, UI heading order,
  builder folders, folder names in catalog / installer / profile).
  `test_xp_mce.py` unchanged and passing. Zig: traits/routing/icon, answer
  family and key field, command line (only `usos.xp_edition=tablet` differs
  from XP), routing golden (additions only). Go: DATA layout count 40.
- QEMU e2e: section 5.

## 5. QEMU e2e (2026-10-09): PASS to the desktop, Tablet PC installed

OVMF without CSM, then CSMWrap, AHCI, TCG:
`run_csmwrap_xp_prepared.py --profile xp-x86-sp3-uefi-csm --ahci --run-through`
with `USOS_TEST_PROBE_EXPORTS=USOS_XP_EDITION=tablet`, `--tree-scripts
"nt5_profile.sh probe_xp_source.sh"` (the package's micro-Linux predates the
entry) and a `usos-xp.ini` with user, computer name and the user's OEM
Tablet PC key (local private file, not logged; checked: the key string is
in no log). The package got the Tablet bundle via `--add-source`.

- Preparation: `tablet_pc=yes`, driver preflight PASS (bundle `49e5ecc5`),
  `CMPNENTS copy PASS`, `APPLIED PASS`, CSMWrap ESP created.
- Text mode, then GUI Setup ran hands-free: no key page, no CD2 prompt.
  About 30 minutes from the first CSMWrap boot to the desktop.
- Desktop with automatic logon and the "Welcome to Tablet PC" window; the
  Tablet PC Input Panel button is on the taskbar.
- Offline check: `WINDOWS\system32\wisptis.exe`, `tabcal.exe`,
  `inkball.exe`, `stikynot.exe`, `Program Files\Common Files\Microsoft
  Shared\Ink\TabTip.exe` and `PiPanel.exe`, `Program Files\Windows
  Journal\Journal.exe`, the Start menu folder `Tablet PC` (Tutorials,
  Windows Journal, Sticky Notes) and "Get Going with Tablet PC".
  `WINDOWS\Driver Cache\i386\sp3.cab` (the bundle's) next to `driver.cab`.
  `setuperr.log` is empty, `tabletoc.log` has no errors.

Not covered: the X470, pen/touch hardware, activation.
