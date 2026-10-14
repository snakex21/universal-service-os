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
| `systems` | which systems offer the profile (see "Use for") | comma-separated catalog ids (`windows-vista`, `ubuntu`) and groups `windows`, `windows-9x`, `windows-nt5`, `windows-nt6`, `linux`; absent: see below |
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
  a generated answer, 95/98/Me included, `windows-9x` = 95, 98, 98 SE, Me
  (MSBATCH.INF, [win9x-modern-2026-09-30.md](win9x-modern-2026-09-30.md)),
  `windows-nt5` = 2000 (Professional and Server)/XP/2003/XP x64,
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
- Windows 8 / 8.1, Server 2012 / 2012 R2 and Embedded 8.1 Industry: no
  product key (`key.<id>` or `key`): their Setup has no "I don't have a
  key" and stops on the product key page.

### Tweaks

Optional, off by default (nothing in the Win10 defaults suggested
otherwise). `schema.tweak_support` is the one table of where each tweak is
rendered; everywhere else the tweak writes nothing, and the editor's
"Appearance and extras" section offers only the tweaks of its system.
Windows 2000 gets `show_extensions`, `show_hidden` and `no_autorun` through usos-reg.exe since 2026-10-12 (no `reg.exe` in its base system; see "Options").

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
- **No console windows (6.x+, 2026-09-28)**: Windows Setup gives every
  console program of a `RunSynchronous` command (`reg.exe`, `powercfg`,
  `dism`, `cmd`) a visible console window: in specialize (Vista/7: over the
  "Setup is completing installation" screen; 8-11: over "Getting ready") and
  in windowsPE (the Windows 11 `LabConfig` checks). On the PE10/WinPE paths
  that run Setup with `/noreboot` the commands of a USOS profile answer
  therefore go through `usos-run-hidden.exe` (`tools/windows_hidden_run.c`,
  GUI subsystem, no C runtime): `usos-run-hidden.exe --wrap` prefixes each
  `RunSynchronousCommand` `Path` of an answer with the renderer's marker
  comment (`tools/windows_hidden_commands.h`; a DATA answer file keeps its
  commands; a command that would pass 259 characters stays as it is), and
  after Setup `--install` copies the runner into `System32` of the one
  Windows volume Setup wrote in this run (fatal when there is not exactly
  one: the start stops with the diagnostics instead of losing the tweaks).
  The runner starts the command with `CREATE_NO_WINDOW`, appends the
  command, its output and its exit code to
  `%WINDIR%\Panther\usos-hidden-commands.log`, returns the exit code to
  Setup, and marks itself for deletion at the next restart. Paths:
  Windows 10/11 and Server 2016+ native UEFI (`windows_modern_uefi_startup.cmd`),
  Windows 7 / 2008 R2 PE10 donor (`windows7_modern_startup.cmd`) and the
  stock Win7 PE (`windows7_native_startup.cmd`), Vista / 2008 (the installer
  wraps before its merge and copies the runner itself, next to its payload).
  Not covered (Setup reboots by itself there, no USOS step between the
  WinPE phase and specialize): the Legacy BIOS wimboot starts and the
  8/10/11 WORK preparation. XP/2000/2003 already run their commands hidden
  (`pae.exe`, `usos-setup.cmd`). The Vista first-boot USB helper's console
  ("USOS - Vista USB diagnostics", frozen v11 payload) stays visible: it is
  where a USB failure is reported.
- **Display and VGA**: `[Display]` is applied by Setup only when the display
  driver offers that mode. Without a display driver (the VGA driver, e.g.
  XP through CSMWrap without a GOP-capable driver) Windows keeps its basic
  mode; "Automatic" writes nothing.

### Options (typed, stage 1, 2026-10-12)

`src/flow/answer/options.zig` is the one option table: each option has a
value type (toggle `no`/`yes`, or a choice whose first value is the default),
an editor group, and per release the rules that render each value: a
registry value (`hklm`, `user` = every new user, `default` = `HKU\.DEFAULT`),
a command, or a native answer element. The editor shows a group and an option
only where the system renders it (`options.available`), a choice only with the
values that render there. A value is written to the profile only when it is
not the default, so older builds still read profiles that do not use them and
existing profiles render byte for byte as before (goldens). Plan and
background: [research/profile-options-2026-10-12.md](research/profile-options-2026-10-12.md).

| option | values | 95 | 98/Me | NT 4.0 | 2000 | XP/2003 | Vista/7 | 8.x | 10 | 11 |
|---|---|---|---|---|---|---|---|---|---|---|
| `show_extensions`, `show_hidden` (tweaks) | yes | | yes | | yes | yes | yes | yes | yes | yes |
| `show_protected` (`Hidden`+`ShowSuperHidden`) | yes | | Me | | yes | yes | yes | yes | yes | yes |
| `launch_to_pc` (`LaunchTo=1`) | yes | | | | | | | | yes | yes |
| `end_task` (`TaskbarEndTask`) | yes | | | | | | | | | yes |
| `no_autorun` (tweak) | yes | yes | yes | yes | yes | yes | yes | yes | yes | yes |
| `no_tips` (Welcome / Getting Started, `Tips\Show=0`) | yes | | | yes | yes | | | | | |
| `taskbar_search` (`SearchboxTaskbarMode`) | hidden, icon, box | | | | | | | | yes | yes |
| `taskbar_left` (`TaskbarAl=0`, client) | yes | | | | | | | | | yes |
| `task_view_off`, `bing_search_off` | yes | | | | | | | | yes | yes |
| `widgets_off` (Feeds / Dsh policy, client) | yes | | | | | | | | yes | yes |
| `uac_level` (EnableLUA stays on) | no_dim, never | | | | | | yes | yes | yes | yes |
| `disable_uac` (tweak) | yes | | | | | | yes | | | |
| `hibernation` (client) | no_fast_startup, off | | | | | | | yes | yes | yes |
| `no_hibernation` (tweak) | yes | | | | | | client | | | |
| `system_restore_off` | yes | | | | | XP | client | client | client | client |
| `numlock` (`InitialKeyboardIndicators`, `.DEFAULT` + new users) | on, off | | | yes | yes | yes | yes | yes | yes | yes |
| `windows_update` (AU policy) | no_restart, notify, off | | | | yes | yes | yes | yes | yes | yes |
| `privacy` (consumer features, suggestions, advertising ID, tailored experiences, telemetry minimum; 11: Copilot, Recall) | yes | | | | | | | | yes | yes |
| `disable_wer` | yes | | | | | | yes | yes | yes | yes |
| `autologon` | yes | | | | yes | yes | yes | yes | yes | yes |
| `password_never_expires` (`net accounts /maxpwage:unlimited`) | yes | | | | yes | yes | yes | yes | yes | yes |
| `workgroup` | name (computer-name rule) | yes | yes | | yes | yes | yes | yes | yes | yes |

Delivery per family:

- **6.x+**: specialize `RunSynchronous` as before. The options' registry
  values are `reg.exe` operations; several go into one
  `cmd.exe /c reg add ... & reg add ...` command while it stays within 239
  characters (room for the `usos-run-hidden.exe` prefix), so a profile with
  every option stays under 15 KiB (`max_size` 16 KiB; test
  `every option on stays within the limits`). Default-user values go between
  the existing `reg load` / `reg unload` of `HKU\USOSDefault`. `autologon`:
  `Shell-Setup/AutoLogon` (oobeSystem, `LogonCount` 9999999); `workgroup`:
  `Microsoft-Windows-UnattendedJoin/Identification/JoinWorkgroup`.
- **NT5**: `workgroup=`, `run=` (only known commands) and `reg=` lines in the
  rendered settings; the staging writes `[Identification] JoinWorkgroup`,
  appends the commands to `usos-users.cmd` and stages **usos-reg.exe** with
  `usos-reg.txt` next to it (`usos_nt5_stage_regset`); `usos-users.cmd` runs
  it at setup end (`%SystemRoot%\usos-reg.log`) and deletes the set (it can
  hold the automatic logon password). XP/2003 keep their tweak tokens;
  2000 (no `reg.exe`) gets `show_extensions`, `show_hidden` and `no_autorun`
  through usos-reg.exe since this change (golden
  `tweaks.windows-2000.x86.sif-cmd.txt` updated for that only).
- **NT 4.0**: `;USOS-REG=` comment lines at the end of `WINNT.SIF`;
  `nt4_csmwrap_target.sh` writes `C:\USOS\NT4\USOS-REG.TXT` and
  `USOS-REG.EXE`, `POST.CMD` applies them at the automatic Administrator
  logon (Default User hive + the Administrator's own HKCU).
- **95/98/Me**: `[Install] AddReg=...,USOS.Profile` and a `[USOS.Profile]`
  section (HKCU at Setup time is the single default user; DWORDs as four
  binary bytes); `workgroup` replaces `Workgroup="WORKGROUP"`.

**usos-reg.exe** (`tools/windows_usos_reg.c`, own GPL code, no C runtime,
x86, PE 4.0, NT 4.0 SP6 .. 11, `KEY_WOW64_64KEY` under WOW64): applies a set
file of lines `ROOT\Key|Name|type|data` (ROOT `HKLM`, `USER`, `DEFAULT`; type
`dword`, `sz`, `expand_sz`, `binary`, `del`). `USER` = the Default User hive
(found through `ProfileList`, loaded with `RegLoadKey`) plus HKCU when not run
as LocalSystem. `--dry-run`, `--log FILE`, `--hive FILE`; exit 0 all applied,
2 some failed, 1 bad set (nothing written). Built by
`tools/build_windows_usos_reg.py`, in the micro-Linux image as
`usr/lib/usos/usos-reg.exe`; tests `tools/tests/test_usos_reg.py`. Not used
on 6.x+: the WORK path has no channel to put a file into the target before
specialize; stage 2 raised the answer limit instead (64 KiB) and keeps the
`reg.exe` commands.

**Stage 2 (2026-10-14)**: packs for every family, new group "Apps and
scripts". Same rules as stage 1 (only where the release renders it, written
only when set, defaults unchanged).

| option | values | 95 | 98/Me | NT 4.0 | 2000 | XP/2003 | Vista/7 | 8.x | 10 | 11 |
|---|---|---|---|---|---|---|---|---|---|---|
| `classic_context_menu` (Active Setup `USOS-ClassicContextMenu`: per user at first sign-in, the `{86ca1aa0-...}\InprocServer32` override in HKCU Classes) | yes | | | | | | | | | yes |
| `shortcut_suffix_off` (`Explorer link` = 00000000) | yes | yes | yes | yes | yes | yes | yes | yes | yes | |
| `desktop_icons` (`HideDesktopIcons`: XP Computer/Documents/Network Places, Vista+ Computer/user/Network/Control Panel) | yes | | | | | yes | yes | yes | yes | yes |
| `no_tips` (XP/2003: Tour `RunCount=0`, Desktop Cleanup Wizard `NoRun`) | yes | | | yes | yes | yes | | | | |
| `classic_taskbar` (XP..Vista `TaskbarGlomming=0`; 7..10 small + `TaskbarGlomLevel=2`; 11 `TaskbarGlomLevel=2`, 23H2+) | yes | | | | | yes | yes | yes | yes | yes |
| `all_tray_icons` (`EnableAutoTray=0`) | yes | | | | | yes | yes | yes | yes | |
| `boot_to_desktop` (8.1 `StartPage OpenAtLogon=0`; 8/8.1 `EdgeUi` corner + charms hint off) | yes | | | | | | | yes | | |
| `lock_screen_off` (policy `NoLockScreen`) | yes | | | | | | | yes | yes | yes |
| `visual_effects` (`MinAnimate`, `DragFullWindows`; 6.x+ also `UserPreferencesMask`, `VisualFXSetting=2`, taskbar/list-view animations, Aero Peek; not XP/2003: their first logon replaced the values in the user's profile, QEMU 2026-10-14) | performance | yes | yes | yes | yes | | yes | yes | yes | yes |
| `font_smoothing` (`FontSmoothing=2`; XP/2003 ClearType `FontSmoothingType=2`; new users + logon screen) | yes | | | | yes | yes | | | | |
| `mouse_accel_off` (`MouseSpeed`, `MouseThreshold1/2` = 0) | yes | yes | yes | yes | yes | yes | yes | yes | yes | yes |
| `sticky_keys_off` (`StickyKeys Flags=506`) | yes | | | | yes | yes | yes | yes | yes | yes |
| `hibernation=off` on XP/2003 (`powercfg.exe /hibernate off` at setup end) | off | | | | | yes | (tweak) | yes | yes | yes |
| `power_profile` (6.x+ `powercfg -setactive SCHEME_MIN/BALANCED/MAX`; XP/2003 `PowerCfg CurrentPowerPolicy` 3 Always On / 0 Home/Office Desk / 5 Max Battery) | high_performance, balanced, power_saver | | | | | yes | yes | yes | yes | yes |
| `no_sleep` (client: AC standby/hibernate timeouts 0 of the active plan) | yes | | | | | | yes | yes | yes | yes |
| `last_access_off` (`NtfsDisableLastAccessUpdate=1`; Vista+ default) | yes | | | yes | yes | yes | | | | |
| `long_paths` (`LongPathsEnabled=1`) | yes | | | | | | | | yes | yes |
| `search_index_off` (client: `sc config WSearch start= disabled`) | yes | | | | | | yes | yes | yes | yes |
| `remote_desktop` (`fDenyTSConnections=0`; XP/2003 port 3389 in the firewall's `GloballyOpenPorts`; 6.x+ `netsh advfirewall` rule `USOS-RDP`) | yes | | | | | yes | yes | yes | yes | yes |
| `firewall_off` (XP/2003 `FirewallPolicy\*Profile EnableFirewall=0`; 6.x+ `netsh advfirewall set allprofiles state off`) | yes | | | | | yes | yes | yes | yes | yes |
| `server_nags_off` (Server: `ShutdownReasonOn=0`, `DisableCAD=1`; 2003 also Manage Your Server policy) | yes | | | | | 2003 | Server | Server | Server | Server |
| `ie_esc_off` (Server 2008+: IE ESC Active Setup components `IsInstalled=0`) | yes | | | | | | Server | Server | Server | Server |
| `disable_wer` on XP/2003 (`PCHealth\ErrorReporting DoReport=0 ShowUI=0`) | yes | | | | | yes | yes | yes | yes | yes |
| `privacy` adds CEIP off (Vista+), 8.1 advertising ID and web search off | yes | | | | | | yes | yes | yes | yes |
| `security_center_off` (client: XP/Vista Security Center `*DisableNotify`; 7/8.x `HideSCAHealth`; 10/11 Security and Maintenance toasts) | yes | | | | | XP | yes | yes | yes | yes |
| `defender_off` (client: policy `DisableAntiSpyware=1`; 10+ Tamper Protection ignores it, not offered) | yes | | | | | | yes | yes | | |
| `smartscreen_off` (policy `EnableSmartScreen=0`, Explorer `SmartScreenEnabled=Off`) | yes | | | | | | | yes | yes | yes |
| `device_encryption_off` (`BitLocker PreventDeviceEncryption=1`) | yes | | | | | | | | yes | yes |
| `remove_apps` (client: provisioned Store apps, PowerShell `Remove-AppxProvisionedPackage` in specialize) | games, bloat | | | | | | | yes | yes | yes |
| `first_run_off` (IE7+ policy `DisableFirstRunCustomize`; WMP `GroupPrivacyAcceptance`; Edge `HideFirstRunExperience`, `StartupBoostEnabled=0`; not XP/2003: IE6's per-user values were reset at the first logon) | yes | | | | | | yes | yes | yes | yes |
| `onedrive_off` (client: 8.1 SkyDrive `DisableFileSync`; 10/11 `DisableFileSyncNGSC` + Default User `Run\OneDriveSetup` removed) | yes | | | | | | | 8.1 | yes | yes |
| `user_script` (see below) | yes | | | | yes | yes | yes | yes | yes | yes |

`remove_apps` vocabulary (USOS's own list, matched with `-match` on the
package name, case-insensitive): `games` = Xbox*, GamingApp, Solitaire;
`bloat` = games + Bing* (News, Weather, Search, ...), Zune (Groove, Movies),
Getstarted (Tips), OfficeHub, MixedReality, 3D Viewer, Print 3D, MSPaint
(Paint 3D on 10), People, Maps, Skype, Messaging, Clipchamp, Feedback Hub, Get
Help, Wallet, Phone Link, Power Automate, To Do, Family, Cortana
(549981C3F5F10), Copilot, Mail/Calendar, Teams, OneNote, Sticky Notes, Voice
Recorder, Quick Assist, 8.1 Help+Tips and Reading List, Dev Home, Outlook.
Kept: Store, Store purchase, App Installer, Calculator, Camera, Clock
(Alarms), Notepad, Paint, Photos, Snipping Tool, Terminal, Security, media
extensions, frameworks, Widgets, Edge.

**User script hook** (`user_script=yes`): at the first sign-in after Setup,
`Scripts\first-logon.reg` (imported with `regedit /s`) and then
`Scripts\first-logon.cmd` (`call`) are run from every drive with the
USOS_DATA layout (a `Systems` folder), if the stick is still plugged in.
6.x+: `oobeSystem` Shell-Setup `FirstLogonCommands` (two
`SynchronousCommand`s; elevated, a console window is visible); 2000/XP/2003:
two `HKLM\...\RunOnce` values (`USOS1UserReg`, `USOS2UserScript`) written by
usos-reg.exe at setup end, run at the first sign-in of any user. Not offered
for 9x (no NTFS) and NT 4.0 (no USB storage). A drive letter without media
(card reader) may show a "No disk" prompt on XP.

Delivery changes: `autounattend.max_size` 16 -> 64 KiB (all options on: at
most ~24 KiB; DATA answers were already accepted up to 1 MiB, the hidden
runner's `--wrap` allocates file size + 64 KiB), `max_commands` 96; the
usos-reg set has the `binary` type (reg.exe `REG_BINARY`, MSBATCH flag 1);
NT5 `reg=` lines may hold `%` (the set is data), `run=` knows
`powercfg.exe /hibernate off`. 6.x+ still uses `reg.exe` in specialize (no
file channel was needed: the larger answer limit carries the commands), so
usos-reg.exe stays NT 4.0/NT5. **Fixed**: `profile.write` (the editor's save)
dropped the typed options and the workgroup before this change.

**QEMU verification (2026-10-12)**, registry read offline after the install:

- Windows 11 Pro (`tools/tests/check_profile_options_w11.py`): all HKLM,
  `.DEFAULT` and Default-hive values present, all 33 specialize commands exit
  0, auto logon, hibernation off, workgroup, This PC, End task, left taskbar,
  no Task view / widgets, hidden + protected files and extensions visible. The
  per-user `SearchboxTaskbarMode` was rewritten by 11 at the first logon (icon
  -> box): 11 now also gets the `SearchOnTaskbarMode` policy (not yet re-run).
  The VM applied the image from WinPE by hand (multi-core VMs hang on this
  host, Setup refuses one core); specialize and oobeSystem ran as in Setup.
- XP SP3 (MCE) and 2000 Pro SP4 through the real staging
  (`tools/tests/run_nt5_profile_options_qemu.py`): every value, auto logon,
  `net accounts`, `usos-reg.log` 0 failed. XP folds `ShowSuperHidden` into
  `ShellState` at the first logon (effective). **Workgroup needs a network
  adapter**: without one Setup ignores `JoinWorkgroup` (X470 I211 has no inbox
  NT5 driver).
- NT 4.0 Workstation and 98 SE (`tools/tests/run_profile_options_legacy_qemu.py`,
  `w9x_creg.py`): all values PASS after two fixes (usos-reg.exe built for i586:
  NT 4.0 faulted on an SSE `movaps`; the 9x CSMWrap staging overwrote the chosen
  MSBATCH.INF with the default). NT 4.0: the Administrator's own NumLock value
  is reset at logoff (new users and the logon screen keep it).

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

Server default (2026-10-08, `root.matchEdition`): a Windows Server
(2008 and later) with no `edition` and no key in the profile installs
`ServerStandard` (Standard with the full GUI: Full Installation on
2008 / 2008 R2, Desktop Experience on 2016+) when the ISO has it, so an
unattended Server install does not stop on the edition list. Media
without Standard (2012 R2 Foundation / Storage Server) keep Setup's choice,
which their product key decides. The editor shows the empty value as
"(Standard - default)" for Server systems.

Matching, in this order:

1. the stored id: the image's `EDITIONID` (Vista / Server 2008 media have
   none: their `FLAGS`, e.g. `ULTIMATE`, `HOMEPREMIUM`; neither: the edition
   words of the name), plus `Core` for a Server Core
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

The words are compared as a whole, never as a prefix: Windows 7 `Home` is
ambiguous (Home Basic / Home Premium) and matches nothing, `Home Premium`
never takes Home Basic, `Professional` never takes Professional N. Two images
that fit equally well (an x86 + x64 ISO with the same edition) are ambiguous
too. Ambiguous or not found: no edition is written and Setup asks.
Vista SP2 x64 pl (`pl_windows_vista_with_sp2_x64_dvd_x15-36359.iso`, no
`EDITIONID`): `Ultimate`, `ultimate`, `Windows Vista Ultimate` -> image 4
(test data `testdata/vista-sp2-x64-pl.install.xml`, golden
`edition.vista-sp2.windows-vista.amd64.xml`).

Editor (6.x+ systems; XP/2000/2003 have no edition row): the edition is a
pick list: "(Setup asks)", then the images of the chosen ISO when the editor
is opened from an install flow (DISPLAYNAME, else NAME; stored as the id
above), then the usual editions of the release (`editions.known`: Vista
Starter ... Enterprise, 7, 8/8.1, 10/11, Server 2008/R2 with Core, 2012+
Desktop Experience / Server Core; those on the ISO are left out), and last
"Type manually..." (the on-screen or physical keyboard). A stored value in
no list is shown as the typed value. Pad: A opens the list, X (F2) types
(starting from the value shown), Y (Del) goes back to "(Setup asks)", B
back; typing on the row with a physical keyboard types a new value. The
editor edits `edition.<system-id>` of the system it was opened from.

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
  ones. Windows 2000 Server (`windows-2000-server`, its own key
  `key.windows-2000-server`) renders the 2000 settings; the staging adds the
  Server pages when the CD's ProductType is 1 (`w2k_stage.sh`
  `usos_w2k_server_sif`: licensing Per Server 5, IIS off, one automatic
  logon, Configure Your Server off;
  [windows-2000-modern-2026-09-30.md](windows-2000-modern-2026-09-30.md) 9).
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
| Vista, 7 and 10/11 native wimboot | the rendered XML (amd64) goes straight into the RAM disk as `usos-unattend.xml` (the file the WinPE scripts already use), with `usos-plan.ini` next to it | WinPE, unchanged |

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

Not wired: Legacy BIOS (no profile manager in the Core); Windows 95/98/Me
take a profile through the UEFI BIOS mode page instead (rendered to
`\EFI\USOS\answer\<98SE|98|ME|95>.INF`, read by the Core, removed at the next
UEFI start). Vista / Server
2008 take a profile or a DATA answer on UEFI with CSM (wimboot,
`usos-unattend.xml` in the RAM disk, since 2026-09-28) and without CSM
(CSMWrap, `\EFI\USOS\answer`): on both the installer merges it with its KMDF
servicing answer (`merge_user_answer`) and the disk stays manual. The WinPE
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
  [INSTALL-XML]` takes the install.wim XML. Vista SP2 x64 pl
  (`testdata/edition-vista.profile.ini`,
  `testdata/vista-sp2-x64-pl.install.xml`, no EDITIONID):
  `edition.vista-sp2.windows-vista.amd64.xml` (`Ultimate` -> image 4) and
  `edition.vista-sp2.windows-server-2008.amd64.xml` (`Professional`: Setup
  asks). Zig: `editions` tests (FLAGS, names only, Home Premium / Home
  Basic, Professional / Professional N, x86 + x64 ties, known editions).
- click-through step 5a: the Windows 10 editor's edition pick list (Pro
  from the list, "Type manually", Del back to "(Setup asks)", F2 types).

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

### Installer merges (host test, 2026-09-28)

`tools/tests/test_answer_merge_paths.py` runs the real merge code on the
rendered `tweaks.profile.ini` (every tweak on): the Vista / Server 2008
CSMWrap installer's `merge_user_answer` (`tools/tests/vista_answer_merge_host.c`
includes `windows_vista_install.c`) and the Windows 7 PE10 donor chain
(`usos-win7-unattend.exe` when NVMe packages are staged, then
`usos-unattend-drivers.exe`). Goldens in `testdata/golden/merged/`. Every
settings pass of the profile answer reaches Setup unchanged, each enabled
tweak is in the merged specialize pass, and the commands keep their order;
the merges only add servicing / offlineServicing content. Vista on UEFI
with CSM runs the same installer merge since 2026-09-28 (the startup script
no longer refuses an answer; `test_vista_uefi_takes_a_user_answer`), so the
Vista goldens cover both Vista paths.

## Attribution

The set of common settings follows the catalogue of Christoph Schneegans'
unattend generator (<https://schneegans.de/windows/unattend-generator/>,
source <https://github.com/cschneegans/unattend-generator>, MIT license,
checked 2026-09-25). USOS reuses knowledge only (which settings exist and
where Microsoft's schema puts them); no code, template or data file of that
project is copied. Files made with that generator are used as they are
(answer files from `Unattended\`).
