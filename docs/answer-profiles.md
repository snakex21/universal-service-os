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
| `edition` | edition Setup installs, for every system without its own | optional, up to 64 ASCII characters; see "Edition" below |
| `edition.<system-id>` | edition for one system (`edition.windows-7=Professional`) | up to 8; wins over `edition` |
| `disable_wer` | Vista+: Windows Error Reporting off (`Microsoft-Windows-ErrorReportingCore/DisableWER=1`, specialize) | default `no` |
| `systems` | which systems offer the profile (see "Use for") | comma-separated catalog ids (`windows-vista`, `ubuntu`) and groups `windows`, `windows-nt5`, `windows-nt6`, `linux`; absent: see below |
| tweaks | `skip_games`, `skip_msn`, `hide_outlook_express`, `classic_start`, `no_balloon_tips`, `disable_uac`, `no_sidebar`, `no_welcome_center`, `no_hibernation`, `show_extensions`, `show_hidden`, `no_autorun` (yes/no); `theme` (`default`, `classic`, `basic`); `display` (`auto`, `1024x768`, `1280x1024`, `1920x1080`) | default off / `default` / `auto`; see "Tweaks" |

The password (and, with `remember_key=yes`, the keys) are plain text on
the stick. The menu never shows them in lists or logs.

`systems` and the tweaks are written only when set, so a profile without
them stays readable by the builds before 2026-09-28 (they refuse unknown
keys).

### Use for (`systems=`)

`src/flow/answer/applies.zig`. The answer screen lists only the profiles
offered for its system (`answer_profiles.filter`); every file is still
read, so a new name never overwrites another system's profile.

- `systems=` set: the listed ids and groups (`windows` = every Windows with
  a generated answer, `windows-nt5` = 2000/XP/2003/XP x64,
  `windows-nt6` = Vista and newer, `linux` = Ubuntu, Debian, Fedora).
- Absent (a profile saved before the field existed): every Windows, never
  Linux. One exception, a read-time default: when the profile's only
  per-system edition names one Windows, it was made there (the editor stores
  the edition of the system it was opened from), so it applies to that
  system only. The X470 stick's `vista-ultimate.ini` (user Retro, no key,
  `edition.windows-vista=Ultimate`) is therefore offered for Vista only.
  Saving a profile in the editor writes `systems=` explicitly.
- The editor's "Use for" row: "Only <system>" (the default for a new
  profile), "Every Windows" or "Every Linux installer", "Windows and Linux";
  a stored list that is none of these is kept and shown as it is.

### Missing answers (warnings before the start)

`applies.missing`: the profile row gets an "Incomplete" badge (warning
tone) with the reason in the help panel, and the summary shows the same
note. The start is not blocked.

- 2000 / XP / 2003: no product key for this system (`key.<id>` or `key`,
  also a key typed this boot): Setup stops on the product key page.
- Server 2008 and newer: the password does not meet the default Server
  policy (7+ characters, three of upper case, lower case, digits,
  symbols): Setup stops on the Administrator password page.

### Tweaks

Optional, off by default (nothing in the Win10 defaults suggested
otherwise). `schema.tweak_support` is the one table of where each tweak is
rendered; everywhere else the tweak writes nothing, and the editor's
"Appearance and extras" section offers only the tweaks of its system.
Windows 2000 has none (no `reg.exe` in its base system).

| tweak | XP | 2003 | Vista | 7 | 8 .. 11, Server 2012+ | how |
|---|---|---|---|---|---|---|
| `skip_games` | yes | | yes | yes | | XP `[Components]` freecell, hearts, minesweeper, pinball, solitaire, spider, zonegames `=Off`; Vista `pkgmgr /uu:InboxGames`, 7 `dism /Disable-Feature /FeatureName:InboxGames` (specialize) |
| `skip_msn` | yes | yes | | | | `[Components]` `msnexplr=Off` (XP), `msmsgs=Off` |
| `hide_outlook_express` | yes | yes | | | | `[Components]` `OEAccess=Off` (entry points; the program stays) |
| `classic_start` | yes | | | | | `[Shell] DefaultStartPanelOff=Yes` |
| `theme=classic` | yes | | | yes | | XP `[Shell] DefaultThemesOff=Yes`; 7 `HKLM\...\Themes InstallTheme` = `%WINDIR%\Resources\Ease of Access Themes\classic.theme` (specialize; read by the first-logon theme setup of every new user; `Themes/CustomDefaultThemeFile` was ignored without Aero in the VirtualBox test) |
| `theme=basic` | | | | yes | | 7 `basic.theme` (Windows 7 Basic); Vista has no reliable file for it |
| `no_balloon_tips` | yes | yes | | | | Default User `Explorer\Advanced EnableBalloonTips=0`; XP also `Applets\Tour RunCount=0` |
| `display` | yes | yes | | | | `[Display] BitsPerPel=32 Xresolution Yresolution` |
| `disable_uac` | | | yes | yes | | 7 / 2008 R2: `Microsoft-Windows-LUA-Settings/EnableLUA=false` (specialize); Vista / 2008: the same value as `reg add HKLM\...\Policies\System EnableLUA=0` (specialize command; Vista SP2 Setup refused `EnableLUA=false`: "value is in invalid format", VirtualBox test 2026-09-28) |
| `no_sidebar` | | | yes | yes | | policy `HKLM\...\Policies\Windows\Sidebar TurnOffSidebar=1` |
| `no_welcome_center` | | | yes | | | Default User `Run\WindowsWelcomeCenter` removed (7 does not open Getting Started at logon) |
| `no_hibernation` | | | yes | yes | | `powercfg.exe -h off` |
| `show_extensions` | yes | yes | yes | yes | yes | Default User `Explorer\Advanced HideFileExt=0` |
| `show_hidden` | yes | yes | yes | yes | yes | Default User `Explorer\Advanced Hidden=1` |
| `no_autorun` | yes | yes | yes | yes | yes | `HKLM\...\Policies\Explorer NoDriveTypeAutoRun=255` (every drive type, KB967715) |

Client-only tweaks (games, sidebar, welcome, hibernation, theme) are not
rendered for the Server releases of the same schema level.

- **NT5**: `nt5.zig` adds `tweaks=<tokens>` and `display=WxH` to the
  rendered settings (profile mode only; `usos-xp.ini` refuses them) only
  when set, so a default profile gives the same settings, `WINNT.SIF` and
  accounts script as before (byte identity kept by the goldens).
  `usos_xp_settings_sif` writes `[Components]`, `[Shell]`, `[Display]`;
  `usos_xp_settings_accounts` appends the registry lines to
  `usos-users.cmd` (run hidden at setup end by `pae.exe` on XP, by
  `usos-setup.cmd` on 2003/XP x64): HKLM directly, the Explorer values in
  the Default User hive (`reg load` of `<ProfilesDirectory>\<DefaultUserProfile>\NTUSER.DAT`,
  read from `ProfileList`), from which every new account's profile is made.
- **6.x+**: `Microsoft-Windows-Deployment` `RunSynchronous` in specialize
  (as SYSTEM, before OOBE creates the accounts): HKLM policies, `powercfg`,
  the Games feature, then `reg load HKU\USOSDefault
  C:\Users\Default\NTUSER.DAT`, the Explorer values, `reg unload`. Every
  command stays under the schema's 259-character `Path` limit. The DISM
  / `offlineServicing` package route is not used (the renderer has no
  servicing pass; package identities are version specific).
- **Display and VGA**: `[Display]` is applied by Setup only when the display
  driver offers that mode. Without a display driver (the VGA driver, e.g.
  XP through CSMWrap without a GOP-capable driver) Windows keeps its basic
  mode; "Automatic" writes nothing.

### Edition

`src/flow/answer/editions.zig`. The edition is matched **at start** against
the install images of the ISO being installed (`sources/install.wim`,
`.esd` or `.swm` XML metadata, read by `windows_media_probe.readEditions`).
Found: `windowsPE` / `Microsoft-Windows-Setup` gets
`ImageInstall/OSImage/InstallFrom/MetaData` with `Key=/IMAGE/INDEX` and the
image's index (the index, not `/IMAGE/NAME`: names can be non-ASCII, and
WORK copies the install image unchanged). Never `InstallTo`: the disk page
stays. Not found (or the image list unreadable): nothing is written, Setup
shows its edition list as before, and the summary shows a note ("Edition
... is not on this ISO: Setup asks for the edition"); found, the summary
shows "Edition: <name> (image <n>)".

Matching, in this order:

1. the stored id: the image's `EDITIONID`, plus `Core` for a Server Core
   image whose `EDITIONID` does not say so (2012 and later):
   `Professional`, `ServerStandard`, `ServerStandardCore`. The editor
   stores this id when the edition is picked from an ISO, so it works on
   any language of the same release and across Server releases;
2. the exact `NAME` or `DISPLAYNAME` (`Windows 7 PROFESSIONAL`,
   `Windows Server 2016 Standard` = the Core image there);
3. the edition words: product, version and packaging words dropped
   (`Windows 7 Pro` -> `pro` -> `Professional`), a few short and localized
   words (`Pro`, `Home` = `Core` on 8+, `Profesjonalny`, `Professionnel`,
   `Profissional`, ...). Server: `Core` in the text wants Server Core,
   `Desktop Experience` / `GUI` / `Full` the Desktop Experience; neither:
   the Desktop Experience when the ISO has it, else Core.

Windows 7 `Home` is ambiguous (Home Basic / Home Premium) and matches
nothing: Setup asks.

Editor: opened from an install flow with an ISO of a 6.x+ system, the
edition is a list picker filled from that ISO (DISPLAYNAME, else NAME;
"(Setup asks)" first; a stored value that is not on the ISO stays in the
list as it is). Elsewhere it is a text field. The editor edits
`edition.<system-id>` of the system it was opened from.

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

## Linux answer files

Wired into the UEFI menu since 2026-09-28: the answer screen offers the
profiles for Ubuntu, Debian and Fedora ISO starts; QEMU results in
[design/linux-iso-boot.md](design/linux-iso-boot.md) section 11 (Ubuntu
Server autoinstall to the storage screen, Debian netinst preseed to "Partition
disks", Fedora netinst kickstart to the hub with only Installation
Destination open).

`src/flow/answer/linux.zig` renders the same profile for the Linux
installers USOS boots from ISO (design: [design/linux-iso-boot.md](design/linux-iso-boot.md)
section 7): `linux.render(profile, format, salt, buffer)` with `format` =
`autoinstall` (Ubuntu subiquity, `autoinstall.yaml`, top-level
`autoinstall:`, `version: 1`), `preseed` (Debian d-i, `preseed.cfg`) or
`kickstart` (Fedora anaconda, `ks.cfg`). The result carries the bytes,
`interactive_identity` and a set of notes (limitations) for the start
summary. Host tool: `usos-answer render-linux PROFILE.ini FORMAT SALT OUT`.

The password is written only as a glibc SHA-512 crypt (`$6$<salt>$...`,
5000 rounds; `sha512crypt.zig`, checked against Drepper's reference
vectors). The salt is a parameter: at start 16 characters from
`sha512crypt.saltFromBytes` over 12 random bytes (firmware RNG, else a TSC
mix); fixed (`usosgoldensalt00`) in the goldens. The plain password never
appears in the output.

| profile | Ubuntu autoinstall | Debian preseed | Fedora kickstart |
|---|---|---|---|
| `user` | `identity.username` (login, see below), `identity.realname` (as typed) | `passwd/username`, `passwd/user-fullname` | `user --name= --gecos= --groups=wheel` |
| `password` | `identity.password` (`$6$`) | `passwd/user-password-crypted` | `user ... --iscrypted --password=`; always `rootpw --lock` |
| empty password | `identity` in `interactive-sections`, no `identity` block (subiquity's schema requires a password, so no prefill) | no password key: d-i asks | no `user` line: the user spoke stays open |
| `computer` | `identity.hostname` (lower case; empty: `ubuntu`) | `netcfg/get_hostname` + `netcfg/hostname` (empty: asked) | `network --hostname=` (empty: default) |
| `timezone` | `timezone:` (auto: not set) | `time/zone` (+ `clock-setup/utc true`) | `timezone <IANA> --utc` |
| `language` (else `locale`) | `locale: ll_CC.UTF-8` (auto: `locale` interactive) | `debian-installer/locale` | `lang` |
| `keyboard` (auto: the language's) | `keyboard.layout` / `variant` (xkb) (none: `keyboard` interactive) | `keyboard-configuration/xkb-keymap` (layout only) | `keyboard --xlayouts='layout (variant)'` |
| disk | `interactive-sections: [storage]` always, never a `storage:` block | no `partman*`, `grub-installer`, `bootdev` keys | no `ignoredisk/clearpart/autopart/part/zerombr/bootloader`, no `%packages` |
| `user2`, `org`, keys, editions, Windows options | ignored (`user2_ignored` note) | ignored | ignored |

Fixed parts: Ubuntu `ssh: {install-server: false}`,
`refresh-installer: {update: false}`; Debian always
`d-i cdrom-detect/try-usb boolean true` (the installer is on the stick) and
`passwd/root-login false` (the user gets sudo), `netcfg/get_domain` empty.

Login: the profile user in lower case, characters outside `a-z 0-9 _ -`
become `_` (`Jan Kowalski` -> `jan_kowalski`), a leading digit gets `u`,
reserved names (`root`, `admin`, `ubuntu`, ...) get `1`; any change sets
the `username_adjusted` note. Language tags map to glibc locales
(`pl-PL` -> `pl_PL.UTF-8`, `sr-Latn-RS` -> `sr_RS.UTF-8@latin`) and
Windows keyboard ids to xkb (`00000415` -> `pl`, `00020409` -> `us(intl)`);
both tables cover every entry of `tables.zig`. Formats that differ from
the language are not separate on Linux (`formats_ignored`).

Notes: `disk_interactive` (always), `password_empty`, `username_adjusted`,
`user2_ignored`, `hostname_default`, `language_asked`, `keyboard_asked`,
`keyboard_variant_dropped` (Debian), `timezone_not_set`, `formats_ignored`.

Injection (per-boot cpio, docs/design/linux-iso-boot.md; never written to
DATA): Ubuntu `/usos/answer/autoinstall.yaml`, copied to the live root
`/autoinstall.yaml` by the `/usos/hooks/init-bottom` hook; subiquity finds
it and asks for confirmation (no `autoinstall` kernel word). Debian
`/preseed.cfg` at the initrd root (initrd preseeding, read before the
language questions). Fedora `/usos/answer/ks.cfg` with
`inst.ks=file:/usos/answer/ks.cfg` (`Format.cpioPath` /
`Format.kernelArgument`).

Status: renderers and goldens only
(`src/flow/answer/testdata/golden/linux/`, Zig test plus
`tools/tests/test_answer_render.py`). Wiring into the answer screen and
`linux_iso_start` is a follow-up by the lead; no installer has consumed
these files on hardware or in QEMU yet.

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
"network location"; then "Use for" and the "Appearance and extras"
section (a form section heading row, never selected) with the tweaks of
that system. Rules are the model's, checked live (a bad
value turns the row red and the help panel says why; empty required fields
turn red on Save). A key typed with "Remember" off is kept in memory for
this boot only (`answer_profiles` session copy) and never written.

The Go installer has no profile editor: profiles are made and edited in
the UEFI menu only.

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

- tweaks (`check_tweaks`): `tweaks.matrix.txt`, one golden with the lines
  each tweak adds on each system (every tweak x every version, from
  `minimal.profile.ini` plus that one tweak; NT5: merged `WINNT.SIF` and
  `usos-users.cmd`); a system outside the tweak's row must render byte for
  byte the baseline (no leak), one where it applies must show its marker;
  `tweaks.<system>.<arch>.{xml,sif-cmd.txt}` with every tweak on
  (`testdata/tweaks.profile.ini`), each XML parsed, checked by `zig
  check-xml` and by `schema.check` inside `root.render`;
  `tweaks-basic.windows-7.x86.xml`. Zig: `schema` (one support row per
  tweak, none for 2000), `autounattend` (tweaks per version, command
  length), `nt5`, `applies` (filter, legacy default, missing answers).
- goldens `edition.windows-7.{amd64,x86}.xml` (profile
  `testdata/edition.profile.ini`, `edition.windows-7=Windows 7
  Profesjonalny` -> image 3 of `testdata/win7-sp1-x64-pl.install.xml`, the
  real metadata of `pl_windows_7_professional_with_sp1_x64_dvd_u_676944.iso`)
  and `edition.windows-vista.amd64.xml` (common `edition=Enterprise`, not
  on the media: no `ImageInstall`). `usos-answer render ... [KEY|-]
  [INSTALL-XML]` takes the install.wim XML.

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

### Installation test, edition (VirtualBox, 2026-09-27)

The same VM and ISO, profile `vbox.profile.ini` plus `edition=Professional`
(`prepare ... --edition Professional --install-xml
src/flow/answer/testdata/win7-sp1-x64-pl.install.xml`; the tool reports
"edition: image 3 (Windows 7 Professional)"). Result: from "Setup is
starting" straight to the disk page (no edition list; only the disk page
was answered, Enter on the unallocated disk), then no OOBE page up to the
desktop; `wmic os get caption` = `Microsoft Windows 7 Professional`,
`hostname` = `USOS-VBOX`, `tzutil /g` = `Central European Standard Time`.
About 17 minutes; VM deleted.

## Attribution

The set of common settings follows the catalogue of Christoph Schneegans'
unattend generator (<https://schneegans.de/windows/unattend-generator/>,
source <https://github.com/cschneegans/unattend-generator>, MIT license,
checked 2026-09-25). USOS reuses knowledge only (which settings exist and
where Microsoft's schema puts them); no code, template or data file of that
project is copied. Files made with that generator are used as they are
(answer files from `Unattended\`).
