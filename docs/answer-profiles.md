# Answer profiles (one settings model, refactor M5)

A USOS answer profile is one small settings file that USOS renders into
the answer file of whichever Windows is being installed: `WINNT.SIF` for
2000/XP/2003, `autounattend.xml` for Vista, 7, 8, 8.1, 10, 11 and Server
2008-2025. Design background: [design/answer-file-generator.md](design/answer-file-generator.md),
[design/refactor-os-pipeline.md](design/refactor-os-pipeline.md) (M5).

Code: `src/flow/answer/` (Zig, fixed buffers, no allocator), host tool
`zig build answer-tool` -> `zig-out/bin/usos-answer.exe`, micro-Linux side
`tools/xp_user_settings.sh` (NT5) and `tools/answer_plan.sh` (WORK).

## Format (`usos-profile`)

INI, UTF-8 (BOM allowed), CRLF or LF, `;`/`#` comments, `[sections]`
ignored, keys case-insensitive, values optionally quoted. Unknown keys and
bad values are refused with the field and the line, never the value.

| key | meaning | rule / default |
|---|---|---|
| `name` | name in the menu, file stem | 1-32 characters `A-Z a-z 0-9 space . _ -` |
| `user` | first local account (administrator), `FullName` / `RegisteredOwner` | required; 1-20 characters `A-Z a-z 0-9 . _ -` and space, not a built-in account |
| `user2` | optional second administrator | like `user`, different from it |
| `computer` | computer name | 1-15 characters `A-Z a-z 0-9 -`, not only digits; empty: `USOS-XP` on NT5, a Setup-chosen name (`*`) on 6.x+ |
| `org` | organization | up to 64 ASCII characters without `" % ^ & \| < >` |
| `password` | password of the accounts (Server: also Administrator) | up to 64 ASCII characters without space and `" % ^ & \| < >`; empty: no password |
| `timezone` | neutral time zone id (IANA, e.g. `Europe/Warsaw`) or `auto` | mapped per OS (below) |
| `language` | Windows language tag (`pl-PL`) or `auto` | 6.x+: Setup and system UI language; NT5: see locale |
| `locale` | formats (`UserLocale`/`SystemLocale`) or `auto` (= language) | |
| `keyboard` | `auto` (the locale's default), a tag, or `LLLL:KKKKKKKK` | |
| `key` | product key for every system | `XXXXX-XXXXX-XXXXX-XXXXX-XXXXX`, optional |
| `key.<system-id>` | key for one system (`key.windows-xp=`) | up to 8; wins over `key` |
| `remember_key` | the keys are saved in the file | default `no`: keys are typed at start and never written |
| `manual_disk` | the disk is chosen in Setup | only `yes` in this version: no `DiskConfiguration`, no `InstallTo`, never `WillWipeDisk` |
| `local_account` | 8+: local account, online-account screens hidden | default `yes` |
| `bypass_tpm`, `bypass_secure_boot`, `bypass_ram` | Windows 11 requirement checks (`LabConfig`) | default `no`, ignored on other systems |
| `no_network_oobe` | Windows 11: OOBE without network (`BypassNRO`) | default `no`; the wireless page is hidden on 7+ anyway (`HideWirelessSetupInOOBE`: an offline Windows 10 OOBE otherwise stops on it) |
| `protect_pc` | Vista+: the "Help protect Windows" page (`ProtectYourPC`) | `recommended` (1), `updates` (2, important updates only), `off` (3); default `off` |
| `network_location` | Vista/7: the network location page (`NetworkLocation`) | `work`, `home`, `public` (`Other`); default `work` (private, no HomeGroup question); not written for 8+ |
| `disable_wer` | Vista+: Windows Error Reporting off (`Microsoft-Windows-ErrorReportingCore/DisableWER=1`, specialize) | default `no` |

The password (and, with `remember_key=yes`, the keys) are plain text on
the stick. The menu never shows them in lists or logs.

### Neutral ids

`src/flow/answer/tables.zig`:

- **Time zones**: IANA id -> Windows id (Vista/7 get the older names where
  the zone was renamed, e.g. `Mexico Standard Time`) and the NT5 index.
  `Europe/Warsaw` = `Central European Standard Time` = NT5 100;
  `Europe/Budapest` = `Central Europe Standard Time` = 95 (the default of
  usos-xp.ini for Polish sources; same UTC offset and DST rules).
- **Languages**: tag -> LCID, NT5 language group, default keyboard (KLID).
  NT5 uses the locale (`SystemLocale`/`UserLocale`), the input profile and
  the language groups of both.

### usos-xp.ini

DATA's `usos-xp.ini` keeps working exactly as before
([xp-unattended.md](xp-unattended.md)). It maps into the model
(`profile.importXpIni`): name `usos-xp.ini`, the key becomes
`key.windows-xp` with `remember_key=yes`, `timezone=<index>` becomes the
first zone with that NT5 index. `tools/tests/test_answer_render.py` proves
that the file through the old path and the same file imported and rendered
give byte-identical `WINNT.SIF` and accounts script.

## Renderers

- **NT5** (`nt5.zig`): the profile as the normalized settings of
  `tools/xp_user_settings.sh` plus `family` (`xp`, `2000`, `2003`),
  `locale`, `input_locale`, `language_group`. The staging loads it in
  *profile mode* (the extra keys are refused in DATA's usos-xp.ini) and
  merges it into the automatic `WINNT.SIF` with the proven merge
  (`usos_xp_settings_sif`): 2000 gets `ProductID`, 2003
  `[LicenseFilePrintData] AutoMode=PerServer`, a chosen language
  `[RegionalSettings]`. Partition, PAE and driver keys stay the automatic
  ones.
- **6.x+** (`autounattend.zig`): one renderer, per version (Vista/7 schema:
  `NetworkLocation`, no online-account screens; 8+: `HideOnlineAccountScreens`;
  Server: `AdministratorPassword`) and per architecture
  (`processorArchitecture` = the media's `x86`/`amd64`/`arm64` on every
  component). Passes: `windowsPE` (International-Core-WinPE when a language
  is set; Setup `UserData` with `AcceptEula`, the key when there is one,
  Windows 11 `LabConfig` commands when chosen), `specialize`
  (`ComputerName`, owner, organization, `TimeZone`; Windows 11 `BypassNRO`
  when chosen), `oobeSystem` (International-Core, OOBE pages hidden,
  `LocalAccounts` in `Administrators`). Nothing selects the disk or the
  edition: Setup shows its disk list (and its edition list when there is no
  key).
- **Per version** (Microsoft unattend reference; `schema.zig` holds the
  table of every setting the renderer writes with its pass, component and
  the versions that have it, and `root.render` checks each rendered file
  against it: Setup refuses the whole file for one element its version
  does not know). OOBE: Vista `HideEULAPage`, `NetworkLocation`,
  `ProtectYourPC`; 7 / 2008 R2 add `HideWirelessSetupInOOBE`; 8+ add
  `HideOEMRegistrationScreen` and `HideOnlineAccountScreens` (before
  2026-09-27 `HideOEMRegistrationScreen` was also written for 7 and 2008
  R2, which their schema does not have). Windows 7 client also gets
  `ShowWindowsLive=false` (specialize). Not used: the deprecated
  `SkipMachineOOBE`/`SkipUserOOBE`, IE home page and search scopes. The
  OOBE pages of Vista/7 are all answered: EULA, user name and password
  (`LocalAccounts`), computer name, key (when the profile has one, else
  7 asks for it in OOBE), "Help protect Windows", time zone, network
  location.
- **Checks** (`xml_check.zig`): well-formedness without a DOM; the
  architecture set of any answer file. An answer file whose components are
  all for another architecture than the media (an amd64-only file, e.g.
  from Schneegans' generator, with 32-bit media) does nothing in Setup:
  USOS warns (not blocks) about it.

## UEFI answer-profile manager

The answer-file screen (`src/platform/uefi/manual_unattended.zig`, rows
`src/flow/answer_screen.zig`), per the agreed mockup:

| row | A (Enter) | X (F2) | Y (Delete) |
|---|---|---|---|
| No answer file (manual installation) | Setup asks everything (XP: `usos.xp_settings=off`) | | |
| XP: `usos-xp.ini: <user>, <computer>` (active DATA file) | hands-off XP as before | import into a new ESP profile (`usos-xp`) | |
| USOS profiles (`\EFI\USOS\profiles\<stem>.ini`) | use (rendered at start) | edit | delete, after a confirmation list (Keep is the default) |
| files from `Unattended\` | used as they are | | |
| + Add a new profile | editor with the menu language and its time zone | | |

B / Esc / right click go back. The footer shows X/Y only on the rows they
act on. Profiles are offered where the start can hand a rendered answer
on (`answer_screen.profileCapable`: XP UEFI-CSM, the native wimboot starts
of 7 and 10/11, WORK for 8/10/11 and WIM); Vista keeps its servicing answer
and gets the file rows only. The screen now also appears for Windows 10/11
with an empty `Unattended\` (it offers "+ Add a new profile").

The editor (`profile_editor.zig`) is a form (`src/gui/form.zig`) with the
on-screen keyboard: profile name, user, second user, computer name,
organization, password (shown as bullets), time zone, Windows language,
formats, keyboard (list pickers), the product key **of the system the
editor was opened from** (`key.<system-id>`), "Remember the key on this
stick", local account and, for Windows 11, the three requirement bypasses
and "set up without network"; for Vista and newer "Protection and
updates" and "Turn off error reporting", for Vista/7 (and 2008/2008 R2)
"network location". Rules are the model's, checked live (a bad
value turns the row red and the help panel says why; empty required fields
turn red on Save). A key typed with "Remember" off is kept in memory for
this boot only (`answer_profiles` session copy) and never written.

The summary shows "Profile <name>: <user>, <computer> (<arch>)". For an
answer file from `Unattended\` it warns when all its components are for
another architecture than the media ("The answer file has no settings for
x86 media: Setup ignores it").

## Where rendering runs (just in time)

The UEFI menu renders the chosen profile when the installation starts
(never earlier) and hands it on through `\EFI\USOS\answer\` on the ESP:

| Path | Hand-over | Consumer |
|---|---|---|
| XP UEFI-CSM (`xp-x86-sp3-uefi-csm`) | `usos-plan.ini` + `nt5-settings.ini`, kernel option `usos.xp_settings=plan` | `usos_xp_settings_plan`: checks the plan, validates the settings in profile mode, deletes the rendered file, merges into `WINNT.SIF` |
| 8/10/11 via WORK | `usos-plan.ini` + `autounattend.xml`, `install-state.ini` `answer_plan=EFI/USOS/answer/usos-plan.ini` | `micro_linux_init.sh` -> `usos_answer_plan_take`: copies to `/run`, deletes it from the ESP; `extract.sh` writes `WORK:\Autounattend.xml` and compares it (`cmp`) as for a DATA file |
| 7 and 10/11 native wimboot | the rendered XML (amd64) goes straight into the RAM disk as `usos-unattend.xml` (the file the WinPE scripts already use), with `usos-plan.ini` next to it | WinPE, unchanged |

Before every start the menu deletes rendered files an earlier start may
have left in `\EFI\USOS\answer` (`answer_profiles.clearRendered`).

`usos-plan.ini` (`plan_file.zig`) never contains a key or a password:

```ini
[plan]
version=1
profile=xp-x86-sp3-uefi-csm
system=windows-xp
[answer]
source=profile
name=Dom
format=nt5_settings
file=EFI/USOS/answer/nt5-settings.ini
arch=x86
key=yes
```

Not wired: Legacy BIOS (no profile manager in the Core), Vista (its own
servicing answer, a user answer file is refused there already). The WinPE
flag files stay (M5 in the refactor plan wants them replaced by
`usos-plan.ini`; that changes hardware-proven WinPE paths and is left for a
separate step with a Vista/7 hardware test).

## Tests

- `zig build test`: model (round trip, keys only with `remember_key`,
  errors without values, usos-xp.ini import), tables (known pairs), NT5
  and XML renderers, XML checks, plan file.
- QEMU/OVMF click-through `tools/tests/run_uefi_answer_screen.ps1`
  (golden `tools/tests/golden/uefi_answer_screen.tsv`): the XP screen rows,
  Back in every way, add a profile with the keyboard (Save with an empty
  name selects it), use it (summary, `usos.xp_settings=plan`, `[PROFILE]
  staged`), edit it with F2, Esc from the editor saves nothing, Delete asks
  (Keep keeps it, Delete removes it); Windows 10 shows the manager with the
  add row.
- `python tools/tests/test_answer_render.py`: goldens in
  `src/flow/answer/testdata/golden` (20 version/architecture XMLs, minimal
  profile, NT5 settings + `WINNT.SIF` + accounts for XP/2000/2003), XML
  parsed by Python, one architecture per file, no disk configuration, the
  usos-xp.ini byte identity, the plan hand-over (settings consumed, rendered
  file deleted, no key in the log, missing file stops), the mismatch warning
  on the user's Schneegans file when `zig-out/usb` has it.

### Hardware (X470, 2026-09-26)

Build B260926-134756-A6EF9DD9: the user created a profile in the UEFI
answer-profile manager and installed with it; confirmed working.

### Installation test (VirtualBox, 2026-09-26)

`tools/tests/run_answer_vbox.py` renders `testdata/vbox.profile.ini` for
Windows 10 x86 (the key is passed on the command line: the Microsoft generic
installation key for Pro, never stored in the repo), writes it as
`Autounattend.xml` on a FAT12 floppy and installs
`pl-pl_windows_10_22h2_19045.6396 ... x86` in the VM `usos-test-answer`
(BIOS, empty 40 GB disk, no network; deleted afterwards). Result:

- asked by Setup: only the edition list (filtered to Pro by the key; the
  profile never picks an edition) and the disk page (manual selection
  kept, Enter on the unallocated disk);
- answered: language page, key, EULA, the whole OOBE; the desktop came up
  logged on as `Tester` (empty password), `hostname` = `USOS-VBOX`,
  `tzutil /g` = `Central European Standard Time`, `Tester` in the Polish
  `Administratorzy` group (the XML says `Administrators`).
- First run found a gap: offline OOBE stopped on "Let's connect you to a
  network"; `HideWirelessSetupInOOBE` is now set on 7+ (second run clean).

### Installation test, Windows 7 SP1 x64 (VirtualBox, 2026-09-27)

Same script (`prepare --system windows-7 --arch amd64`, the Microsoft
generic volume key for 7 Professional on the command line), ISO
`pl_windows_7_professional_with_sp1_x64_dvd_u_676944.iso`, BIOS, SATA,
empty 40 GB disk, plus a NAT network card so the network location page
would appear. Result:

- asked by Setup: only the edition list (this ISO has four editions; the
  profile never picks one, Professional chosen) and the disk page (manual
  selection kept, Enter on the unallocated disk);
- answered: language page, EULA, and the whole OOBE: no user or computer
  name page, no key page, no "Help protect Windows", no time zone page, no
  network location page. From "preparing the computer for first use"
  straight to the desktop, logged on as `Tester` (empty password);
  `hostname` = `USOS-VBOX`, `tzutil /g` = `Central European Standard
  Time`, `Tester` in `Administratorzy`. About 16 minutes; VM deleted.

## Attribution

The set of common settings follows the catalogue of Christoph Schneegans'
unattend generator (<https://schneegans.de/windows/unattend-generator/>,
source <https://github.com/cschneegans/unattend-generator>, MIT license,
checked 2026-09-25). USOS reuses knowledge only (which settings exist and
where Microsoft's schema puts them); no code, template or data file of that
project is copied. Files made with that generator are used as they are
(answer files from `Unattended\`).
