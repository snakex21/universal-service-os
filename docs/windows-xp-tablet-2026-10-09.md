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
  this media.

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
- QEMU e2e: **not run** - it needs a Tablet PC Edition product key, which
  is not in the media. Run it like the MCE e2e
  (`run_csmwrap_xp_prepared.py --profile xp-x86-sp3-uefi-csm --ahci
  --run-through`, `USOS_TEST_PROBE_EXPORTS=USOS_XP_EDITION=tablet`) with a
  `usos-xp.ini` that carries the key from a local private file; check
  `WINDOWS\system32\tabtip.exe` / `wisptis.exe` and the Tablet PC
  Start menu entries offline.
