# Windows XP Media Center Edition 2005 (2026-10-08)

Status: **experimental**. The menu entry uses the XP x86 path from UEFI
(`xp-x86-sp3-uefi-csm`). With CSM the firmware boots the installed system;
without CSM, CSMWrap does (see `xp-csmwrap-status`). That path has passed on
the X470.

## 1. Menu entry

**Windows XP Media Center Edition 2005** (`windows-xp-mce`) is UEFI only.
The BIOS Core leaves it out because of its size budget. The entry sits
directly after Windows XP and uses the DATA folders
`Systems\Windows\Windows XP Media Center Edition 2005\Images` and `Unattended`.

| Piece | Where |
|---|---|
| Catalog entry (gated out of the BIOS Core) | `src/catalog/windows_legacy.zig` |
| Routing as Windows XP (traits, profile, icon, `usos-xp.ini`) | `src/catalog/os_profiles.zig` |
| Answer family XP, own key field `key.windows-xp-mce` | `src/flow/answer/target.zig` |
| Kernel argument `usos.xp_edition=mce` | `src/platform/uefi/xp_preparation.zig` (`Nt5System.windows_xp_mce`) |
| DATA folder / title from that argument | `tools/nt5_profile.sh` (`USOS_XP_EDITION=mce`) |
| Heading in the micro-Linux UI | `tools/micro_linux_ui.sh` |
| The entry refuses a disc without the Media Center components | `tools/probe_xp_source.sh` (`media_center=yes/no`) |
| CMPNENTS copied into the local source | `tools/prepare_xp_local_source.sh` |
| Disc key fallback | `tools/nt5_media_key.sh`, called by `prepare_xp_windows_partition.sh` |
| Driver bundle for ISOs in the Media Center DATA folder | `tools/build_xp_uefi_csm_trial.py` (`XP_IMAGE_FOLDERS`) |
| Summary note | `boot.summary.xp_mce_limits` (all 27 languages) |
| Installer DATA layout row | `installer/internal/winhost/data_layout.go` |

## 2. Media Center specifics

- **CD2.** The retail MCE 2005 set has two CDs. GUI Setup installs Media
  Center, Plus! and Sonic from CD2's `CMPNENTS\MEDIACTR\I386` and .NET from
  `CMPNENTS\NETFX\I386`. `DOSNET.INF [Directories]` and
  `TXTSETUP.SIF [SourceDisksNames]` name these folders relative to the
  source root (`d3 = \cmpnents\mediactr\I386`). WINNT32's local source works
  the same way, so the preparation now copies the disc's `CMPNENTS` folder
  to `$WIN_NT$.~LS\CMPNENTS` next to `I386`. GUI Setup then finds the
  cabinets without asking for CD2. The copy is generic: any XP disc with a
  `CMPNENTS` folder at its root gets it, and Microsoft's Professional and Home
  discs have none.
- **Two-CD media.** The `windows-xp-mce` entry stops with an actionable
  message before writing to the target when
  `CMPNENTS\MEDIACTR\I386\MEDIACTR.CAB` is missing. CD1 alone cannot
  install Media Center.
- **Product key.** An answered key always wins: answer profile
  (`key.windows-xp-mce`, else `key=`), `usos-xp.ini`, or a `.sif` chosen in the
  menu. When none of them sets `[UserData] ProductKey`, the preparation takes
  the key from the disc's own `I386\WINNT.SIF`, if that file has a key with
  the 5x5 shape. The value is never logged, and the log line only says
  `taken from the disc's own I386\WINNT.SIF (not logged)`. The step is
  generic for NT5, and Windows 2000 uses the `ProductID` spelling.
  Microsoft's retail and VL discs have no `I386\WINNT.SIF`, so their path is
  unchanged.
- **Driver bundle.** The XP driver bundle is bound to its source ISO
  (`source.sha256`). The stick build (`build_xp_uefi_csm_trial.py --data`) now
  also builds bundles for the SP3 ISOs in the Media Center DATA folder.
  Without a bundle, the preflight stops with "ISO differs from the prepared
  driver package". The `--release` package keeps only its PL and EN XP
  Professional allowlist.

## 3. The user's media

`Windows XP Media Center Edition 2005 SP3.iso` (726 138 880 bytes,
SHA-256 `0e8d7abd...251074e`), created 2008-08-14:

- Single disc, English (`PRODSPEC.INI` Localization=English), markers
  `WIN51`, `WIN51IP`, `WIN51IP.SP3` (SP3 slipstreamed, `I386\SP3.CAB`).
- `CMPNENTS\MEDIACTR\I386` (`MEDIACTR.CAB`, `PLUS.CAB`, `SONIC.CAB`) and
  `CMPNENTS\NETFX\I386\NETFX.CAB` are merged in, so **no second CD is
  needed**.
- `I386\SVCPACK` holds post-SP3 updates and .NET 1.0/1.1 (GUI Setup runs
  them through `SVCPACK.INF`). Text-mode storage drivers `iaStor`/`iaahci`
  come through `TXTSETUP.SIF [SCSI.Load]` (handled since 2026-09-30, see
  `windows-2000-modern-2026-09-30.md`).
- The disc's own `I386\WINNT.SIF` (an MCE answer file) carries a product
  key, so no key from the user is needed. The key was not read into any log
  or file of this repository.

## 4. Tests

- Host: `tools/tests/test_xp_mce.py` covers the profile edition, the probe
  (`media_center`, refusal of a disc without the components), the
  local-source copy, the disc-key helpers (an answered key wins, bad shapes
  are refused, `[UserData]` is created when missing, the 2000 spelling), the
  key never being logged, and the builder folders. Zig: catalog/traits,
  answer family and key field, command line (only the `usos.xp_edition=mce`
  token differs from XP), and the routing golden (additions only).
  `test_w2k_staging.py` and the pipeline tables are unchanged.
- QEMU e2e: see section 5.

## 5. QEMU e2e (2026-10-08): PASS to the desktop, Media Center installed

The run booted OVMF without CSM, then CSMWrap, on AHCI with TCG.
`run_csmwrap_xp_prepared.py --profile xp-x86-sp3-uefi-csm --ahci --run-through`
ran with `USOS_TEST_PROBE_EXPORTS=USOS_XP_EDITION=mce` and a `usos-xp.ini`
that has a user, computer name and time zone but **no key**. The package was
the current one plus the MCE bundle (`--add-source`, bundle `9319296c...`).

- Preparation: the probe reported `media_center=yes` and the driver
  preflight passed (MCE bundle). The log showed
  `CMPNENTS copy PASS`, `IASTOR.SYS` staged to `~BT`, and
  `product key: none answered, taken from the disc's own I386\WINNT.SIF
  (not logged)`. The CSMWrap ESP was created.
- Text mode copied the files through CSMWrap and restarted.
- GUI Setup ran hands-free: no product key page and no CD2 prompt.
  `setupapi.log` shows the Media Center files extracted from
  `C:\$WIN_NT$.~LS\cmpnents\mediactr\i386\mediactr.cab`.
- The second CSMWrap boot reached the XP logo, then the desktop with
  automatic logon as `Tester` and the MCE "Energy" wallpaper.
- Offline check of the target: `WINDOWS\ehome\ehshell.exe` (2006-10-09,
  Rollup 2 from `SVCPACK`), `ehrecvr.exe`, `ehtray.exe`, and the Start menu
  entries `All Users\Start Menu\Programs\Media Center.lnk` and
  `...\Accessories\Media Center\Media Center.lnk`. `setuperr.log` holds one
  entry: the unsigned `acpi.sys` of the XP driver bundle, as expected.

Not covered by QEMU: starting Media Center itself (it needs DirectX 9 video
with hardware overlay), TV tuners, and the X470 hardware.
