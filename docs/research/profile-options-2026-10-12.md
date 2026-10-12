# Answer-profile options: inventory, Schneegans comparison, per-family plan (2026-10-12)

Status: **research**, no code changed. Goal from the user: USOS answer
profiles (the UEFI answer-profile manager and editor, the `usos-profile`
INI and the `usos-answer` renderers) should offer as many options as the
unattend generator at schneegans.de, and an equally rich, native set for
**every** Windows family USOS installs, not only 10/11.

Sources: the USOS code on `test/x470-98se-qemu` (a34ce8b), the user's
generator file `win10-11 best-ustawienia.xml` (read as data; its product
key is not reproduced anywhere here), the generator web page and its
public source (section 3), Microsoft's unattend / WINNT.SIF / MSBATCH.INF
references as already used by USOS.

Effort scale used below: **S** = one profile field + renderer lines +
golden (hours); **M** = a new renderer block, a new pass or a per-family
script part, plus a VM check (a day); **L** = a new delivery channel or a
native helper (several days, hardware/VM proof).
Risk: **low** = cosmetic, reversible by the user; **med** = changes
security or servicing, reversible; **high** = can break servicing,
updates or boot, or is hard to undo.

## 1. What USOS profiles support today

Code: `src/flow/answer/profile.zig` (model, `Field` enum, parser),
`schema.zig` (setting table per version, `Tweak` + `tweak_support`),
`autounattend.zig` (6.x+), `nt5.zig` (+ `tools/xp_user_settings.sh`,
`usos-users.cmd`), `nt4.zig`, `nt3.zig`, `msbatch.zig` (95/98/Me),
`posready.zig`, `linux.zig`, `applies.zig`, `editions.zig`, `tables.zig`;
UI `src/platform/uefi/manual_unattended.zig` (answer-profile manager),
`profile_editor.zig` (the editor/wizard form), `answer_profiles.zig`
(ESP store `\EFI\USOS\profiles\<stem>.ini`). User doc:
[../answer-profiles.md](../answer-profiles.md).

### 1.1 Fields and where they render

`9x` = MSBATCH.INF (95/98/98 SE/Me), `NT3/4` = WINNT.SIF of the
local-source flow, `2000`, `XP/2003` (+ XP x64, MCE, Tablet; POSReady has
its own small `POSR.SIF`), `V/7` = Vista, 7, 2008, 2008 R2, `8.x` = 8,
8.1, 2012, 2012 R2, Embedded 8.1, `10/11` = 10, 11, Server 2016-2025.

| field | 9x | NT3/4 | 2000 | XP/2003 | V/7 | 8.x | 10/11 | how |
|---|---|---|---|---|---|---|---|---|
| `name`, `systems` | - | - | - | - | - | - | - | profile meta (menu, filter) |
| `user` | owner | owner | owner + account | owner + account | account | account | account | `[NameAndOrg]` / `[UserData]` / `usos-users.cmd` / `LocalAccounts` |
| `user2` | - | - | yes | yes | yes | yes | yes | second admin |
| `computer` | yes | yes | yes | yes | yes | yes | yes | |
| `org` | yes | yes | yes | yes | yes | yes | yes | |
| `password` | - | (blank admin) | yes | yes | yes | yes | yes | Server: also Administrator |
| `timezone` | yes (9x key) | yes (NT4 string marker) | yes | yes | yes | yes | yes | IANA -> per-OS id |
| `language`, `locale`, `keyboard` | - | - | yes | yes | yes | yes | yes | `[RegionalSettings]` / International-Core(-WinPE) |
| `key`, `key.<id>`, `remember_key` | 98/Me (95 ProductID) | yes | yes | yes | yes | yes | yes | |
| `edition`, `edition.<id>` | - | - | - | - | yes | yes | yes | `/IMAGE/INDEX` matched at start |
| `manual_disk` | - | - | - | - | yes | yes | yes | only `yes` (no DiskConfiguration) |
| `local_account` | - | - | - | - | - | yes | yes | `HideOnlineAccountScreens` |
| `bypass_tpm/secure_boot/ram` | - | - | - | - | - | - | 11 | `LabConfig` in windowsPE |
| `no_network_oobe` | - | - | - | - | - | - | 11 | `BypassNRO` |
| `protect_pc` | - | - | - | - | yes | yes | yes | `OOBE/ProtectYourPC` |
| `network_location` | - | - | - | - | yes | - | - | `OOBE/NetworkLocation` |
| `disable_wer` | - | - | - | - | yes | yes | yes | ErrorReportingCore `DisableWER` |
| `skip_games` | - | - | - | XP | V/7 client | - | - | `[Components]` / pkgmgr / DISM |
| `skip_msn`, `hide_outlook_express` | - | - | - | yes | - | - | - | `[Components]` |
| `classic_start` | - | - | - | XP | - | - | - | `[Shell]` |
| `theme` classic/basic | - | - | - | XP (classic) | 7 | - | - | `[Shell]` / Themes `InstallTheme` |
| `no_balloon_tips` | - | - | - | yes | - | - | - | Default User reg |
| `display` | - | - | - | yes | - | - | - | `[Display]` |
| `disable_uac` | - | - | - | - | yes | - | - | EnableLUA |
| `no_sidebar`, `no_hibernation` | - | - | - | - | V/7 client | - | - | policy / `powercfg -h off` |
| `no_welcome_center` | - | - | - | - | Vista | - | - | Default User Run |
| `show_extensions`, `show_hidden`, `no_autorun` | - | - | - | yes | yes | yes | yes | Default User / HKLM policy |

Observations:

- **9x, NT 3.x, NT4, POSReady take identity only** (owner, org, computer,
  time zone, key). None of the tweaks reach them; 2000 has no tweak
  either ("no reg.exe in its base system").
- **8.x and 10/11 get only three tweaks** (extensions, hidden files,
  AutoRun) plus WER. Everything the user picked in the generator beyond
  that is missing.
- Fixed mechanics on 6.x+: every tweak is a `RunSynchronous` command in
  `specialize` (SYSTEM, before OOBE), max 259 characters each, Default User
  hive via `reg load HKU\USOSDefault`; no `FirstLogonCommands`, no
  per-user-once step, no embedded files, no PowerShell. Rendered XML
  buffer 16 KiB (`autounattend.max_size`); today's all-tweaks file is
  ~4.1 KiB, so ~12 KiB headroom, not enough for a large appx list as
  individual commands.
- Console windows are hidden only on paths where `usos-run-hidden.exe` is
  installed (native UEFI 10/11, Win7 PE10/stock PE, Vista/2008); the 8/10/11
  WORK path and the Legacy BIOS wimboot starts show them.
- The editor already has the right shape for more options: one form, one
  "Appearance and extras" section filled from `schema.tweak_support`, so a
  new tweak is offered only where it renders. A choice-type row exists
  (`theme`, `display`), so multi-value options need no new widget.

### 1.2 Delivery channels per family (what a new option can use)

| family | channel today | HKLM | Default User / every new user | limits |
|---|---|---|---|---|
| 95/98/Me | MSBATCH.INF `[Setup]`, `[OptionalComponents]`, `[Install] AddReg/DelReg/UpdateInis/UpdateIniFields`, `USOS.RunOnce` INF section | INF AddReg | INF AddReg to HKCU (single-user 9x: HKCU = the default profile at Setup time) | MSDOS.SYS is not INI-editable by Setup: needs INSTALL.BAT / U9FIX; Me has no real-mode DOS |
| NT 3.1-3.51 | WINNT.SIF + own `usosnt3` tool | usosnt3 | usosnt3 | no RunOnce, no CMDLINES.TXT, no .REG import |
| NT4 | WINNT.SIF, `$OEM$\CMDLINES.TXT`, POST.CMD at one auto logon, `.REG` via `regedit /s` | yes | only the logged-on admin (no reg.exe, no Default User hive edit) | |
| 2000 | WINNT.SIF (`[Components]`, `[Display]`, `[GuiRunOnce]`, `[URL]`, `[TapiLocation]` ...), `regedit /s` in GuiRunOnce (used for `srvwiz.reg`) | yes | logged-on user only | "no tweaks" today is a tooling gap, not an OS limit |
| XP/2003 | WINNT.SIF + `usos-users.cmd` (reg.exe, Default User hive) | yes | yes | |
| Vista..11 | autounattend.xml passes; specialize RunSynchronous | yes | yes (reg load) | 259 chars/command, 16 KiB, no file payload |

**Gap in the channels** (needed for richer options):

1. A **native registry helper** (own GPL C, no CRT, like
   `usos-run-hidden.exe`): `usos-reg.exe` that imports a REGEDIT4 subset
   into HKLM, HKU\.DEFAULT and the Default User hive (`RegLoadKey`, exists
   since NT 3.1). One helper lifts the NT4/2000 Default User limitation,
   gives NT 3.x a .REG import, and on 6.x+ replaces long `reg add` chains
   with one short command. 64-bit Windows needs an x64 build (or
   `KEY_WOW64_64KEY`, XP x64+), else HKLM\Software is redirected.
2. A **file payload channel on 6.x+** for long lists (appx/capabilities)
   and user scripts. Options: (a) the files next to the answer, copied by
   the start path into `%WINDIR%\Setup\Scripts\USOS\` (the native, Win7
   and Vista paths already copy `usos-run-hidden.exe` into System32; WORK
   would use `sources\$OEM$\$$\...` - to be verified in QEMU for 10/11
   setup.exe), or (b) the contents embedded in the XML and written out by
   a specialize command. (a) is preferred: no XML size pressure, no
   PowerShell needed, reuses a proven step.
3. A **FirstLogonCommands / per-user-once** step for the few settings that
   cannot be set in the Default User hive (Windows 11 Start pins, things
   protected by the per-user-choice driver, restarting Explorer).

## 2. What the user picked in the generator

From the generator URL stored in the user's file (`OS\win10-11
best-ustawienia.xml`, also on DATA under `Systems\Windows\Windows 11\Unattended\`;
product key omitted here):

- **Region/setup**: pl-PL UI/formats, keyboard 0415, GeoLocation 191,
  generic Pro edition, amd64, bypass Windows 11 requirements, bypass
  network requirement, random computer name, time zone Central European,
  interactive local account, password expiration unlimited, lockout
  default.
- **Explorer**: show hidden + system files, show extensions, classic
  context menu, open to This PC, "End task" in the taskbar menu.
- **Taskbar/Start**: search as icon, widgets off, left-aligned taskbar,
  all tray icons shown, Bing results off, empty Start tiles (10) and
  empty pins (11), Start folders Settings/Explorer/Downloads/personal
  folder.
- **System**: UAC off, Smart App Control off, SmartScreen off, Fast
  startup off, System Restore off, long paths on, PowerShell scripts
  allowed, last-access time off, app suggestions off, device encryption
  prevented, Edge first-run hidden, Edge startup boost off, Edge made
  uninstallable, mouse acceleration off, delete Windows.old, automatic
  restart sign-on off, core isolation (HVCI) off, sticky keys off, lock
  keys untouched, express (privacy) settings all off, Wi-Fi interactive.
- **Visual effects**: custom (Aero Peek, thumbnail cache, list-view
  shadow, thumbnails, alpha select, drag full windows, font smoothing on;
  the rest off).
- **Desktop icons**: Control Panel, Downloads, Recycle Bin, This PC, user
  folder; Edge desktop icon deleted.
- **Removed**: 3D Viewer, Bing Search, Clipchamp, Copilot, Cortana, Dev
  Home, Windows Hello (face), Family, Feedback Hub, Game Assist, Get Help,
  Handwriting, Internet Explorer, Mail/Calendar, Maps, Math Input Panel,
  Mixed Reality, Movies & TV, News, Office hub, OneDrive, OneNote, OneSync,
  Outlook, Paint 3D, People, Power Automate, PowerShell 2.0, PowerShell
  ISE, Quick Assist, Recall, Skype, Solitaire, Speech, Steps Recorder,
  Sticky Notes, Teams, Tips, To Do, Voice Recorder, Wallet, Weather, Fax
  and Scan, legacy Media Player, Groove/Zune Music, WordPad, Xbox apps,
  Phone Link. Kept: Calculator, Camera, Clock, Notepad, Paint, Photos,
  Snipping Tool, Terminal, Store, Remote Desktop client.
- **Own system script** (PowerShell, Polish): power plans on every scheme
  (CPU min 5 % / max 100 %, aggressive boost, USB selective suspend off,
  display AC never / DC 10 min, sleep AC never / DC 30 min), battery
  detection -> hibernation on (laptop/Ally, critical 7 % = hibernate, low
  15 %, reserve 10 %) or off (desktop); Windows Search service manual;
  Defender tray icon policy removed; Windows Update on but no automatic
  restart with a signed-in user (`NoAutoRebootWithLoggedOnUsers`);
  uninstall Edge (system level), WebView2 kept. Logs to
  `C:\UltimateSetup\Logs`.
- AppLocker and WDAC skipped, colors/wallpaper/lock screen default.

This is the reference "enthusiast 10/11" profile: anything in the top
list below should be able to reproduce it without the user's XML.

## 3. The Schneegans generator: licence and catalogue

### 3.1 Licence

Checked 2026-10-12 on a shallow clone of
`github.com/cschneegans/unattend-generator`: `LICENSE.txt` is the **MIT
License** (SPDX `MIT`), "Copyright (c) 2024-2025 Christoph Schneegans".
The web page has no separate terms of use (footer: contact and donation
links only). This matches the 2026-09-25 note in `answer-profiles.md`
("Attribution"). Generated XML carries the generator's commit and URL in
its own `Extensions` element. MIT would allow reuse with the copyright and
permission notice kept (MIT is GPL-3.0-compatible);
USOS policy stays: **reuse knowledge only** (which settings exist, which
registry values Microsoft reads), write our own renderer code, copy no
template, script or data file. Facts such as "value X under key Y does Z"
are not copyrightable; the generator's PowerShell scripts, XML templates
and its appx name list as a file are, and stay out.

### 3.2 Catalogue (grouped) and mechanisms

See 3.3 for the per-option mechanism detail. Summary of the sections the
generator offers: region and language (UI, formats, up to several
keyboards, GeoLocation); processor architecture; Setup settings (bypass
Windows 11 checks, bypass network, configuration set, hide PowerShell
windows, keep sensitive files, narrator); computer name (random, fixed,
script); Compact OS; time zone; partitioning (interactive, automatic
GPT/MBR with recovery partition options, custom diskpart); Windows edition
/ key (generic key, interactive, firmware key, own key) and source image;
Windows PE operation (default / script / custom); user accounts
(interactive Microsoft/local, unattended local accounts with groups,
auto logon, obscured passwords, password expiration, account lockout);
File Explorer (hidden files level, extensions, classic context menu,
launch to This PC, End task); Start menu and taskbar (search box mode,
taskbar icons, widgets, left alignment, all tray icons, Bing in search,
Start tiles 10 / Start pins 11); system tweaks (UAC, Smart App Control,
SmartScreen, Defender, Fast startup, System Restore, long paths,
PowerShell execution policy, Remote Desktop, hardened ACLs, last-access,
app suggestions, device encryption, Edge first run / startup boost /
uninstallable, mouse acceleration, Windows.old, ARSO, Windows Update,
Copilot/Recall-type features, core isolation); visual effects; desktop
icons; Start menu folders; virtual machine guest tools (VirtualBox,
VMware, VirtIO/QEMU, Parallels); Wi-Fi (interactive, skip, unattended
SSID/key, profile XML); express (privacy) settings; lock keys; sticky
keys; personalization (colors, wallpaper, lock screen); bloatware removal
(appx packages, capabilities, optional features); custom scripts
(specialize / Default User / first logon / each user once); WDAC and
AppLocker.

Mechanisms, in general: OOBE/setup items are real unattend settings;
almost everything else is registry (HKLM policies in specialize, the
Default User hive loaded in specialize, a few per-user-once at first
logon); removals are `Remove-AppxProvisionedPackage`,
`Remove-WindowsCapability` and `Disable-WindowsOptionalFeature` in
PowerShell scripts that the answer file writes out of its own
`Extensions` element in specialize (`C:\Windows\Setup\Scripts\*.ps1`).

### 3.3 Repository check: how the generator works

- **Four script sequences**, written as `.ps1` files out of the XML's
  `Extensions` element by a PowerShell one-liner (specialize command #1,
  reads `C:\Windows\Panther\unattend.xml`): `Specialize.ps1` (SYSTEM,
  specialize RunSynchronous), `DefaultUser.ps1` (between
  `reg load HKU\DefaultUser C:\Users\Default\NTUSER.DAT` and
  `reg unload`), `FirstLogon.ps1` (oobeSystem `FirstLogonCommands`, once),
  `UserOnce.ps1` (Default User `RunOnce` value, once per new user, HKCU).
  Each logs to its own file.
- **Windows PE modes**: A = normal Setup (key, `LabConfig` bypasses);
  B = a generated `pe.cmd` that partitions, `dism /Apply-Image`, `bcdboot`,
  with offline extras (Defender services `Start=4`, 8.3 names off, paging
  file, WPBT off, Compact OS, `$OEM$` robocopy); C = own PE script.
  **Disabling Defender exists only in mode B** (offline, before the first
  boot), because Tamper Protection ignores later policy writes.
- **Mechanism per option** (selected; the full inventory was collected):
  hidden files / extensions / info tips / taskbar alignment / task view /
  Bing = Default User `Explorer\Advanced` and policies; classic context
  menu, Launch to This PC, search box mode, desktop icons, Start folders
  (`Start\VisiblePlaces`, binary), colors, wallpaper = UserOnce (HKCU, then
  an Explorer restart); widgets = HKLM `Dsh AllowNewsAndInterests=0`;
  Start pins 11 = HKLM `PolicyManager\current\device\Start\ConfigureStartPins`
  JSON; Start tiles 10 = Default `LayoutModification.xml`; taskbar icons =
  `StartLayoutFile` + `LockedStartLayout` with a scheduled task that
  unlocks after the first apply; all tray icons 11 = a logon scheduled
  task setting `NotifyIconSettings\*\IsPromoted=1` every minute; "disable
  Windows Update" = a scheduled task re-writing a 7-day pause
  (`WindowsUpdate\UX\Settings Pause*`) daily; "prevent WU auto-reboot" =
  AU `AUOptions=4`, `NoAutoRebootWithLoggedOnUsers=1` + a task moving the
  active hours; System Restore = FirstLogon `Disable-ComputerRestore`;
  SmartScreen = Explorer `SmartScreenEnabled=Off` + `WTDS\Components` +
  Edge/AppHost per-user values; visual effects = HKLM
  `VisualEffects\<flag>\DefaultValue` + per-user `VisualFXSetting`; lock
  keys = `InitialKeyboardIndicators` (.DEFAULT + Default User) and
  `Scancode Map` to ignore keys; sticky keys = `StickyKeys\Flags` string;
  Wi-Fi = embedded profile XML + `netsh wlan add profile` in specialize;
  system sounds off = `AppEvents` scheme blanking + `DisableStartupSound`;
  ARSO, long paths, Fast startup, device encryption, SAC, HVCI, WPBT, Edge
  policies = HKLM values in specialize; password expiry / lockout =
  `net accounts`.
- **Removals** (60 items, version-tagged 10 / 11 / 23H2 / 24H2 / 25H2):
  `Get-AppxProvisionedPackage` matched on DisplayName ->
  `Remove-AppxProvisionedPackage -AllUsers`, `Remove-WindowsCapability`
  (name before `~`), `Disable-WindowsOptionalFeature -Remove`, plus custom
  steps (OneDrive setup files + Run key, Teams `ConfigureChatAutoInstall=0`,
  Outlook / Dev Home `UScheduler_Oobe` keys, Copilot policy + per-user
  package, Notepad `ShellNew` restore). Store removal is offered too.
- Other: custom scripts in all four phases (`.cmd`, `.ps1`, `.reg`,
  `.vbs`, 15 slots each), AppLocker policy (no WDAC option), VM guest
  tools at first logon, free XML per component (84 components listed),
  narrator, interactive computer-name prompt, obscured (Base64) passwords,
  "keep sensitive files" (by default the unattend and Wi-Fi XML are
  deleted at first logon).
- **Windows 11 only**: requirement bypass, BypassNRO, classic context
  menu, left taskbar, Start pins, Start folders, SAC, widgets, End task,
  Copilot / Recall / Teams / Outlook / Dev Home handling. **10 only**:
  Start tiles XML. Different per version: all tray icons (`EnableAutoTray`
  on 10).

Lessons for USOS (own implementation): the four-phase split is the right
model (USOS has only the first two today); prefer HKLM policies and the
Default User hive over per-user-once where they work; per-user-once is
needed for the classic context menu, This PC, search mode, desktop icons
and Start folders on 11; Defender and the tray-icon / WU-pause scheduled
tasks are fragile and stay out of the first round.

## 4. Architecture proposal (one model, rendered per family)

1. **Typed options instead of only booleans.** Keep `schema.tweak_support`
   as the single table, but give each option a value type (bool, enum,
   number, short string) and a per-family *renderer kind*: WINNT.SIF key,
   MSBATCH section, unattend setting, HKLM value, Default User value,
   command, removal list. The editor already shows only supported rows.
2. **Mechanism layer per family** (section 1.2): MSBATCH AddReg for 9x;
   `usos-reg.exe` for NT3/NT4/2000 (and Default User on 6.x+); existing
   `usos-users.cmd` for XP/2003; specialize + new oobeSystem
   `FirstLogonCommands` for 6.x+; file payload channel for 8+ removals.
3. **Same id, family-specific meaning**: e.g. `visual_effects=performance`
   writes `UserPreferencesMask`/`VisualFXSetting` on XP+, `MinAnimate` +
   `DragFullWindows` on 9x/NT4; `windows_update=off` writes the AU policy
   on 2000 SP3+/XP/Vista+, the Me Automatic Updates switch on Me, nothing
   on 95/98 (no client).
4. **Backwards compatibility**: as today, a field is written to the INI
   only when set, so older builds still read default profiles; goldens
   prove "unset = byte-identical".
5. **Never**: activation or licence-check bypasses (no cracks, no
   OOBE/WPA patches, no key generation). Server/Win11 requirement
   bypasses stay limited to Microsoft-documented `LabConfig`/`BypassNRO`
   style switches already in use.

## 5. Cross-family core set (implement once, render per OS)

| option (id) | values | 9x | NT4 | 2000 | XP/2003 | V/7 | 8.x | 10/11 | effort |
|---|---|---|---|---|---|---|---|---|---|
| `show_extensions` (exists) | bool | `HideFileExt=0` AddReg (98+; 95 via ShellState, verify) | .REG | .REG | done | done | done | done | S |
| `hidden_files` (extends `show_hidden`) | default / hidden / hidden+system | `Hidden`, `ShowSuperHidden` (98+) | .REG | .REG | reg | reg | reg | reg | S |
| `no_autorun` (exists) | bool | `NoDriveTypeAutoRun` + CDROM `AutoRun=0` | .REG + Cdrom `Autorun=0` | .REG | done | done | done | done | S |
| `autologon` | off / once / always | - (9x no logon by default) | Winlogon `AutoAdminLogon` | `[GuiUnattended] AutoLogon` + Winlogon | same | Shell-Setup `AutoLogon` | same | same | S-M |
| `password_never_expires` | bool | - | `net accounts /maxpwage:unlimited` | same | same | same | same | same (generator: PasswordExpiration) | S |
| `numlock` | on / off / default | CONFIG.SYS `NUMLOCK=ON` | `InitialKeyboardIndicators=2` (.DEFAULT + user) | same | same | same | same | same (generator: lock keys) | S |
| `windows_update` | default / notify / off | - (Me: AU off) | - | AU policy (SP3+) | AU policy | AU policy / ProtectYourPC | same | policy + no auto reboot | S |
| `system_restore` | on / off | Me only (verify value) | - | - | `DisableSR=1` (XP) | policy `DisableSR` | same | same | S |
| `hibernation` (extends `no_hibernation`) | default / off | - | - | `[Unattended]` n/a, `powercfg` n/a: skip | `[Unattended] Hibernation=No` (verify XP) | done | `powercfg -h off` | same | S |
| `error_reporting` (extends `disable_wer`) | on / off | - | Dr. Watson `AeDebug Auto=0` | same | PCHealth `DoReport=0` | done | done | done | S |
| `visual_effects` | default / performance / appearance | `MinAnimate`, `DragFullWindows`, `FontSmoothing` | same | `UserPreferencesMask` | `VisualFXSetting` + mask | same | same | same + generator's custom set | M |
| `font_smoothing` | default / standard / cleartype | 98+ `FontSmoothing` | NT4: Plus!/no | standard | ClearType `FontSmoothingType=2` | default on | on | on | S |
| `desktop_icons` | set of: Computer, Documents/user, Network, Recycle Bin, Control Panel | NameSpace (verify) | n/a | `HideDesktopIcons` (2000 n/a: always shown) | `HideDesktopIcons\NewStartPanel` | same | same | same (+ Downloads, Gallery) | M |
| `home_page` / `browser_first_run` | URL / about:blank; suppress first run | IE4/5 `Start Page` | IE `Start Page` | `[URL] Home_Page` | same | IE unattend component | IE10/11 | Edge policies (first run, startup boost) | S-M |
| `remove_bundled` | list (family-specific vocabulary) | `[OptionalComponents]` | - | `[Components]` | `[Components]` | Features (DISM/pkgmgr) | appx + features | appx + capabilities + features | M-L |
| `workgroup` | name | `[Network] Workgroup` | `[Network] JoinWorkgroup` | same | same | `Identification` in specialize | same | same | S |
| `remote_desktop` | on / off | - | - | (Server TS) | `[TerminalServices] AllowConnections` (Pro) | LocalSessionManager `fDenyTSConnections` | same | same | S |
| `firewall` | default / off | - | - | - | `[WindowsFirewall]` (SP2+) | MPSSVC unattend | same | same | S |
| `startup_tips` (welcome/tour/tips/getting-started) | bool | Tips `Show=0` (+ Welcome already) | Tips | Getting Started off | Tour off (part of balloon tips) | Welcome Center (done) | - | Tips/suggestions (see 10/11) | S |
| `user_script` | file from DATA (`Scripts\<family>\`) | RunOnce `.BAT`/`.INF` | POST.CMD tail | GuiRunOnce | `usos-users.cmd` tail / GuiRunOnce | FirstLogon | same | same | M-L |
| `power_profile` | default / desktop / laptop / auto (battery) | - | - | `powercfg` n/a; registry schemes (skip) | `powercfg /change` (XP has powercfg.exe) | `powercfg -x`/GUIDs | same | same (user's script) | M |

## 6. Per-family gap tables and top lists

Columns: what it does / implementation in that family / risk / effort.
"Exists" means already in USOS. Registry values for 9x, NT4, 2000 and XP
come from the Microsoft references and common knowledge, not from a
test run here; rows marked "verify", and every value before it is
rendered, need one VM install of that family (the existing QEMU /
VirtualBox flows) with a golden.

### 6.1 Windows 10 / 11 / Server 2016+ (Schneegans parity)

| option | what | implementation | risk | effort |
|---|---|---|---|---|
| hidden files level | hidden / hidden+system | Default User `Hidden`, `ShowSuperHidden` | low | S |
| classic context menu (11) | full right-click menu | per-user Classes CLSID `{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32` empty default (per-user classes: once per user at first logon, then an Explorer restart) | low | M (per-user-once) |
| open Explorer to This PC | | Default User `Explorer\Advanced LaunchTo=1` | low | S |
| End task in taskbar menu (11) | | Default User `...\Advanced\TaskbarDeveloperSettings TaskbarEndTask=1` | low | S |
| taskbar search mode | hidden / icon / box | Default User `Search SearchboxTaskbarMode` 0/1/2 | low | S |
| widgets off | | HKLM policy `Dsh AllowNewsAndInterests=0` (11), `Feeds` policy (10) | low | S |
| taskbar left (11) | | Default User `Advanced TaskbarAl=0` | low | S |
| task view button off | | Default User `ShowTaskViewButton=0` | low | S |
| all tray icons (11) | | 11 has no `EnableAutoTray` effect since 22H2: first-logon script / scheduled task copying the `NotifyIconSettings` promotion (generator: scheduled task) | low | M |
| Bing in Start search off | | Default User `Policies\Microsoft\Windows\Explorer DisableSearchBoxSuggestions=1` | low | S |
| empty Start (10 tiles / 11 pins) | | 10: `LayoutModification.xml` in Default profile; 11: `ConfigureStartPins` policy JSON or `start2.bin` reset | low | M (file payload) |
| Start folders (11) | Settings, Explorer, Downloads... next to power | per user `Start\VisiblePlaces` (binary GUID list), once per user; HKLM `PolicyManager ... Start AllowPinnedFolder*` as an alternative (verify) | low | M (per-user-once) |
| UAC level | off / no-dim / default | `EnableLUA` (off breaks Store apps on 8+) / `ConsentPromptBehaviorAdmin=5` + `PromptOnSecureDesktop=0` | med | S |
| SmartScreen off | | HKLM `Policies\System EnableSmartScreen=0` + Explorer `SmartScreenEnabled=Off` + Edge policy | med | S |
| Smart App Control off (11) | | HKLM `CI\Policy VerifiedAndReputablePolicyState=0` in specialize | med (cannot be re-enabled without reinstall) | S |
| Defender off | | policy keys are ignored while Tamper Protection is on; the generator does it only offline from its own PE script (services `Start=4` in the offline SYSTEM hive) | high | L, not in the first round |
| Fast startup off | | HKLM `Session Manager\Power HiberbootEnabled=0` | low | S |
| System Restore off | | policy `DisableSR=1` / `Disable-ComputerRestore` | low | S |
| long paths | | HKLM `FileSystem LongPathsEnabled=1` | low | S |
| PowerShell scripts allowed | | HKLM `ExecutionPolicy RemoteSigned` | med | S |
| last-access time off | | `fsutil behavior set disablelastaccess 1` | low | S |
| app suggestions / consumer features off | | HKLM `CloudContent DisableWindowsConsumerFeatures=1` + Default User `ContentDeliveryManager` values | low | S |
| prevent device encryption | BitLocker auto-encryption off | HKLM `BitLocker PreventDeviceEncryption=1` (specialize) | low (data safety + for multi-boot) | S |
| Edge first run / startup boost | | HKLM `Policies\Microsoft\Edge HideFirstRunExperience=1`, `StartupBoostEnabled=0` | low | S |
| Edge uninstallable / remove | | EdgeUpdate `ClientState` `experiment_control_labels` / region check; uninstall via Edge `setup.exe --uninstall --system-level` (user's script) | high (Edge is a WebView2/servicing dependency; updates may restore it) | M |
| mouse acceleration off | | Default User `Control Panel\Mouse MouseSpeed=0 MouseThreshold1/2=0` | low | S |
| delete Windows.old | | first-logon `Remove-Item` / cleanmgr | low | S |
| ARSO off | | HKLM `Policies\System DisableAutomaticRestartSignOn=1` | low | S |
| core isolation (HVCI) off | | HKLM `DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity Enabled=0` | med (security) | S |
| sticky keys off | shortcut prompt off | Default User `Accessibility\StickyKeys Flags=10` (+ Toggle/Filter) | low | S |
| express/privacy settings off | | OOBE `ProtectYourPC=3` (exists) + HKLM policies: telemetry `AllowTelemetry` min, advertising ID, location, tailored experiences, inking/typing, Find my device | med | M |
| visual effects custom | 17 toggles | Default User `VisualEffects VisualFXSetting=3` + `UserPreferencesMask` bits + `DWM`/`ListviewShadow`/... | low | M |
| desktop icons | This PC, user, CP, Network, Recycle Bin, Downloads | Default User `HideDesktopIcons\NewStartPanel {CLSID}=0` | low | S |
| delete Edge desktop icon | | first logon / Default `Desktop\Microsoft Edge.lnk` removal; EdgeUpdate `CreateDesktopShortcutDefault=0` | low | S |
| bloatware removal | appx/capabilities/features list | `dism /online /Remove-ProvisionedAppxPackage` per family name prefix, `Remove-WindowsCapability`, `Disable-WindowsOptionalFeature`; OneDrive setup removal + Default User Run key; Teams/Outlook/Copilot reinstall blocks | med (wrong package list = missing Store/Calculator) | L (file payload + list vocabulary + VM check per release) |
| Wi-Fi profile | SSID + key | first logon `netsh wlan add profile` from a generated XML, or `HideWirelessSetupInOOBE` (exists) | med (secret on stick, like the password) | M |
| Copilot / Recall off | | HKLM `WindowsCopilot TurnOffWindowsCopilot=1`, `WindowsAI DisableAIDataAnalysis=1`, remove feature `Recall` | low | S |
| Windows Update: no auto restart | | AU policy `NoAutoRebootWithLoggedOnUsers=1`, optional active hours | low | S |
| power profile | the user's own script as an option | `powercfg /setacvalueindex` on all schemes, battery-aware hibernation | low | M |
| Windows Search service manual | | `sc config WSearch start= demand` | low | S |
| Compact OS | | `ImageInstall/OSImage/Compact` (windowsPE) | low | S |
| auto logon | | `AutoLogon` (Shell-Setup, oobeSystem) with LogonCount | med (password plain on stick, already true) | S |
| password never expires / lockout | | `net accounts /maxpwage:UNLIMITED`, `/lockoutthreshold:` | low | S |
| GeoLocation | home location | `International-Core` has no Geo; HKCU `Control Panel\International\Geo Nation` (Default User) | low | S |
| several keyboards | | `InputLocale` list `0415:00000415;0409:00000409` | low | S |
| VM guest tools | VirtualBox/VMware/VirtIO | first logon install from the ISO/DATA | low | M (not a USOS target; low priority) |
| colors / wallpaper / lock screen | dark mode, accent, image | Default User `Personalize AppsUseLightTheme/SystemUsesLightTheme`, `Wallpaper` + image file | low | S (mode) / M (image) |
| WDAC / AppLocker | | policy XML | high | skip |
| partitioning | automatic disk | `DiskConfiguration` | high (wipe) | out of scope: USOS rule "one disk question", manual disk stays |

**Top for 10/11** (reproduces the user's file except the custom script
parts): taskbar/Start pack (search icon, widgets off, left, task view,
Bing off, Start folders), Explorer pack (hidden level, This PC, classic
menu, End task), privacy pack (consumer features, suggestions, telemetry
min, Copilot/Recall off), Edge first-run/boost, Fast startup off, prevent
device encryption, UAC level, SmartScreen off, System Restore off, long
paths, ARSO off, mouse acceleration off, sticky keys off, desktop icons,
visual effects preset, bloatware removal (curated vocabulary), power
profile, Windows Update no-auto-restart, auto logon, password never
expires.

### 6.2 Windows 8 / 8.1 / Server 2012 / 2012 R2 / Embedded 8.1

| option | what | implementation | risk | effort |
|---|---|---|---|---|
| boot to desktop (8.1) | skip Start screen | Default User `Explorer\StartPage OpenAtLogon=0` | low | S |
| Start screen shows Apps view (8.1) | | Default User `StartPage MakeAllAppsDefault=1` | low | S |
| charms hints / hot corners off | | Default User `ImmersiveShell\EdgeUi DisableTLCorner=1 DisableCharmsHint=1` | low | S |
| lock screen off | | HKLM policy `Personalization NoLockScreen=1` | low | S |
| Fast startup off | | `HiberbootEnabled=0` (core set) | low | S |
| UAC level (not EnableLUA=0) | EnableLUA=0 stops all Modern apps | as 10/11 | med | S |
| SkyDrive/OneDrive integration off (8.1) | | policy `Skydrive DisableFileSync=1` | low | S |
| Store / Modern apps removal | | `dism /Remove-ProvisionedAppxPackage` (8.x DISM has it) | med | M |
| SmartScreen off | | as 10/11 (8 introduced Explorer SmartScreen) | med | S |
| Server: Server Manager at logon off | | `Microsoft-Windows-ServerManager-SvrMgrNc DoNotOpenServerManagerAtLogon=true` (unattend) | low | S |
| Server: IE ESC off | | `Microsoft-Windows-IE-ESC IEHardenAdmin/IEHardenUser=false` (unattend) | med | S |
| Server: shutdown event tracker off | | policy `Reliability ShutdownReasonOn=0` | low | S |
| Server: workstation mode | audio, themes, Desktop Experience | `Audiosrv` auto, features | low | M |
| Ctrl+Alt+Del off (Server) | | `DisableCAD=1` | med | S |
| core set | extensions, hidden, autorun, autologon, numlock, WU, restore, effects, icons, power | as section 5 | | |

**Top for 8.x**: boot to desktop + Apps view, hot corners/charms off,
lock screen off, Fast startup off, Server Manager/IE ESC/shutdown tracker
off for 2012, UAC level, OneDrive off, Modern app removal, core set.

### 6.3 Windows Vista / 7 / Server 2008 / 2008 R2 / Home Server 2011

| option | what | implementation | risk | effort |
|---|---|---|---|---|
| UAC level | off / no-dim / default (today only off) | `ConsentPromptBehaviorAdmin=5`, `PromptOnSecureDesktop=0` | med | S |
| Aero / theme (Vista) | Vista Basic / Classic for slow GPUs | Vista: Themes `InstallTheme` (no basic file on Vista: classic only), `Themes` service | low | S |
| Windows Search / indexing off | | `sc config WSearch start= disabled` | low | S |
| System Restore off | | policy `DisableSR=1` | low | S |
| Windows Defender (old antispyware) off | | policy `DisableAntiSpyware=1` (works on Vista/7 Defender) | low | S |
| Action Center / Security Center notifications off | | 7: `HKCU ...\Policies\Explorer HideSCAHealth=1`; Vista: Security Center `*DisableNotify=1` | low | S |
| Windows Update mode | | AU policy (`AUOptions`, `NoAutoRebootWithLoggedOnUsers`) | low | S |
| IE first run / home page | | unattend `Microsoft-Windows-IE-InternetExplorer DisableFirstRunWizard=true`, `Home_Page` | low | S |
| WMP first run | | policy `WindowsMediaPlayer GroupPrivacyAcceptance=1` | low | S |
| taskbar (7) | small icons, never combine | Default User `TaskbarSmallIcons=1`, `TaskbarGlomLevel=2` | low | S |
| Start power button = shut down (7) | | Default User `Start_PowerButtonAction=2` | low | S |
| desktop icons | Computer, user, Network, CP | `HideDesktopIcons\NewStartPanel` | low | S |
| Remote Desktop | | unattend `Microsoft-Windows-TerminalServices-LocalSessionManager fDenyTSConnections=false` + firewall group | med | S |
| firewall off | | unattend `Microsoft-Windows-Networking-MPSSVC-Svc` profiles | med | S |
| hibernation (exists), sidebar (exists), games (exists), welcome (exists), WER (exists), theme (exists) | | | | |
| Server 2008/R2: Initial Configuration Tasks off, Server Manager off, IE ESC off, shutdown tracker off, Ctrl+Alt+Del off | | unattend `Microsoft-Windows-OutOfBoxExperience DoNotOpenInitialConfigurationTasksAtLogon`, `ServerManager-SvrMgrNc`, `IE-ESC`; policies | low-med | S |
| WinSAT (Vista) | already avoided by USOS | - | | - |
| power profile | high performance / balanced presets | `powercfg -setactive` GUID | low | S |
| GeoLocation, extra keyboards | | as 10/11 | low | S |

**Top for Vista/7/2008**: UAC level, indexing off, System Restore off,
Defender off (old), Action Center nags off, WU mode, IE/WMP first run off,
taskbar small icons/never combine + power button (7), desktop icons,
Remote Desktop, Server ICT/Server Manager/IE ESC/tracker off, power
preset, plus the core set.

### 6.4 Windows XP / Server 2003 / XP x64 / MCE / Tablet / POSReady

| option | what | implementation | risk | effort |
|---|---|---|---|---|
| Windows Update / AU off or notify | | AU policy `NoAutoUpdate=1` or `AUOptions=2` (WINNT.SIF has no AU key on RTM; registry) | low | S |
| Security Center nags off (SP2) | | `Security Center FirewallDisableNotify=1`, `AntiVirusDisableNotify=1`, `UpdatesDisableNotify=1` | low | S |
| firewall off (SP2) | | `[WindowsFirewall] Profiles=WindowsFirewall.TurnOffFirewall` + `[WindowsFirewall.TurnOffFirewall] Mode=0` | med | S |
| System Restore off | | `HKLM\...\Windows NT\CurrentVersion\SystemRestore DisableSR=1` | low | S |
| hibernation off | | `[Unattended] Hibernation=No` (verify in QEMU) or `powercfg /hibernate off` | low | S |
| Tour + MSN/Messenger off | | exists (`no_balloon_tips` sets Tour `RunCount=0`; `skip_msn`) + Messenger policy `PreventRun=1` | low | S |
| Luna vs classic | | exists (`theme=classic`); add Royale/Embedded? no (not on stock media) | low | - |
| ClearType | | Default User `FontSmoothing=2`, `FontSmoothingType=2` | low | S |
| visual effects (performance) | | Default User `VisualEffects VisualFXSetting=2` + `UserPreferencesMask`, `MinAnimate=0` | low | S |
| desktop icons | My Computer, My Documents, Network Places | Default User `HideDesktopIcons\NewStartPanel` / `ClassicStartMenu` | low | S |
| desktop cleanup wizard off | | Default User `Desktop\CleanupWiz NoRun=1` | low | S |
| search companion (dog) off | | Default User `CabinetState Use Search Asst=no` | low | S |
| error reporting off | | `PCHealth\ErrorReporting DoReport=0` (`disable_wer` extended to NT5) | low | S |
| Remote Desktop on (Pro) | | `[TerminalServices] AllowConnections=1` | med | S |
| IE6: home page, first run, ESC (2003) | | `[URL] Home_Page`; `RunOnceHasShown=1`; 2003 SP1 `[Components] IEHardenAdmin=Off IEHardenUser=Off` | med (ESC) | S |
| 2003: Manage Your Server off, shutdown tracker off, Ctrl+Alt+Del off | | policy `MYS DisableShowAtLogon=1`; `Reliability ShutdownReasonOn=0`; Winlogon `DisableCAD=1` | low-med | S |
| 2003 as workstation | audio, themes, hardware acceleration | `Audiosrv`/`Themes` start=2 | low | S |
| NumLock on | | `InitialKeyboardIndicators=2` | low | S |
| permanent auto logon | | `[GuiUnattended] AutoLogon=Yes`, `AutoLogonCount` / Winlogon values | med | S |
| workgroup | | `[Identification] JoinWorkgroup` | low | S |
| TAPI location (no modem dialog) | | `[TapiLocation] CountryCode AreaCode` | low | S |
| more `[Components]` | Paint, WordPad, HyperTerminal, Chat... keep/remove | `[Components]` names | low | S |
| driver signing prompts | | `[Unattended] DriverSigningPolicy=Ignore` (already used by USOS internally) | med | - |
| thumbs.db off | | Default User `Advanced DisableThumbnailCache=1` | low | S |
| "Shortcut to" prefix off | | Default User `Explorer link=00000000` | low | S |
| activation | | **not** offered: no WPA bypass; VLK/SLP media just have no activation | - | - |

**Top for XP/2003**: AU off/notify, Security Center nags off, firewall,
System Restore off, ClearType + visual effects preset, desktop icons +
cleanup wizard off, error reporting off, IE first run / home page (+ ESC
off on 2003), 2003 server nags (MYS, tracker, CAD) and workstation mode,
NumLock, auto logon, Remote Desktop, workgroup/TAPI, more `[Components]`.

### 6.5 Windows 2000 Professional / Server

Today none. All below go through WINNT.SIF keys or a `.REG` file imported
with `regedit /s` from `[GuiRunOnce]` (the mechanism the Server path
already uses), plus `usos-reg.exe` for the Default User hive.

| option | what | implementation | risk | effort |
|---|---|---|---|---|
| show extensions / hidden / autorun | core set | .REG (HKCU of the autologon user + Default User via helper) | low | M (channel) then S |
| remove accessories/games | | `[Components]` freecell, hearts, minesweeper, pinball, solitaire, chat... | low | S |
| display mode | | `[Display] BitsPerPel Xresolution Yresolution Vrefresh` (2000 knows it) | low | S |
| Getting Started off | | Default User `Tips Show=0` / Welcome `srvwiz` (Server exists) | low | S |
| personalized menus off | | Default User `Advanced IntelliMenus=no` | low | S |
| Web view / Active Desktop off | | Default User `Policies\Explorer ClassicShell=1` or `WebView=0` | low | S |
| Windows Update / AU (SP3+) | | AU policy | low | S |
| Dr. Watson off | | `AeDebug Auto=0` | low | S |
| home page / IE5 first run | | `[URL] Home_Page` | low | S |
| auto logon / NumLock / workgroup / TAPI | | `[GuiUnattended] AutoLogon`, `[Identification]`, `[TapiLocation]` | low | S |
| driver signing | | `[Unattended] DriverSigningPolicy` | med | - |

**Top for 2000**: the `regedit /s` + helper channel, then extensions/
hidden/autorun, `[Components]` games, `[Display]`, Getting Started off,
personalized menus off, Web view off, AU policy, NumLock/auto logon/TAPI.

### 6.6 Windows NT 4.0 / NT 3.x

NT4: `.REG` files + `POST.CMD` exist (one auto logon); NT 3.x: only the
own `usosnt3` tool. Options make sense mostly for NT4.

| option | what | implementation | risk | effort |
|---|---|---|---|---|
| show extensions / hidden | | NT4 shell `Explorer\Advanced` via .REG | low | S |
| CD AutoRun off | | `Services\Cdrom Autorun=0` | low | S |
| Welcome screen off | | `Tips Show=0` | low | S |
| auto logon permanent | | Winlogon `AutoAdminLogon=1` | med | S |
| NumLock | | `InitialKeyboardIndicators=2` | low | S |
| boot menu timeout | | `boot.ini timeout` (micro-Linux writes it) | low | S |
| Dr. Watson off / crash auto reboot | | `AeDebug`, `CrashControl AutoReboot` | low | S |
| NTFS last access off | | `NtfsDisableLastAccessUpdate=1` (NT4 SP?) | low | S |
| visual effects | `MinAnimate`, `DragFullWindows` | .REG | low | S |
| IE home page / first run | IE2-6 | .REG | low | S |
| NT 3.x | Program Manager groups, Desktop wallpaper/screen saver off, boot timeout | `usosnt3` | low | M |

**Top for NT4/3.x**: Welcome off, extensions/hidden, CD AutoRun off,
NumLock, boot timeout, auto logon, Dr. Watson off; NT 3.x after the
helper exists.

### 6.7 Windows 95 / 98 / 98 SE / Me

Everything through MSBATCH.INF: `[OptionalComponents]` and `[Install]`
AddReg/UpdateInis (single user, so HKCU at Setup is the user's).

| option | what | implementation | risk | effort |
|---|---|---|---|---|
| optional components | games, MSN, Online Services, Web TV, channels, accessibility, multimedia packs | `[OptionalComponents] "Games"=0` ... (names per release) | low | S |
| Active Desktop / Channel bar off (98) | | AddReg `Policies\Explorer NoActiveDesktop=1`, IE `Show_ChannelBand=no` | low | S |
| Web view / single click off | classic folders | AddReg `ShellState` / `ClassicShell` (verify) | low | S |
| Tips at startup off | | AddReg `Explorer\Tips Show=0` | low | S |
| show extensions / hidden | | AddReg `Advanced HideFileExt=0`, `Hidden=1` (98+; 95 verify) | low | S |
| CD AutoRun off | | AddReg CDROM class `AutoRun=0` + `NoDriveTypeAutoRun` | low | S |
| boot to DOS / boot menu / no logo / BootDelay=0 | MS-DOS mode options | MSDOS.SYS `[Options] BootGUI=0 BootMenu=1 Logo=0 BootDelay=0` via INSTALL.BAT / U9FIX (not Me) | med (boot to DOS surprises users) | M |
| NumLock | | CONFIG.SYS `NUMLOCK=ON` | low | S |
| file system role / swap | "network server" cache, `ConservativeSwapfileUsage=1` (98) | AddReg FS templates, system.ini `[386Enh]` | low | S |
| visual effects | animation off, full-window drag, font smoothing (98) | AddReg `WindowMetrics MinAnimate=0`, `DragFullWindows=1`, `FontSmoothing=2` | low | S |
| "Shortcut to" prefix off | | AddReg `Explorer link=00000000` | low | S |
| Start menu delay | | AddReg `MenuShowDelay` | low | S |
| startup sound off / sound scheme none | | AddReg `AppEvents\Schemes` | low | S |
| display mode (USOS VESA driver) | 800x600 .. 1920x1080, depth | AddReg `Config\0001\Display\Settings` / USOS VESA INF default | low | S |
| Me: System Restore off, Automatic Updates off, Help "Did you know" off | | registry (verify values in Me VM) | low | S |
| workgroup | | `[Network] Workgroup` (exists fixed `WORKGROUP`) | low | S |
| TweakUI-like | "paint desktop version", tips | AddReg | low | S |

**Top for 9x**: optional components, Active Desktop/Channel bar off,
tips off, extensions/hidden, AutoRun off, MS-DOS mode options (95/98),
visual effects, display mode, NumLock, Me System Restore/AU off.

## 7. Prioritized top 15 (whole project)

Ordered by value per effort, family-wide first. All are own code;
each needs goldens per family and the VM checks USOS already runs.

1. **Typed option table + editor sections** (schema `tweak_support`
   becomes the option table with value types and per-family renderer
   kinds; editor groups: Explorer, Taskbar/Start, Privacy, System,
   Removal). Prerequisite for everything below. M.
2. **`hidden_files` level + Explorer pack** (This PC, classic context
   menu, End task, "Shortcut to" off, thumbs.db off): every family that
   has the value. S.
3. **Taskbar/Start pack for 10/11** (search mode, widgets off, left
   alignment, task view off, Bing off, Start folders) and 8.1 boot to
   desktop/Apps view/hot corners. S.
4. **Windows Update mode** (default / notify / off / no-auto-restart),
   2000 SP3 .. 11 + Me. S.
5. **System Restore off + Fast startup off + hibernation unified**
   (Me, XP, Vista..11). S.
6. **Privacy pack** (consumer features, suggestions, telemetry minimum,
   advertising ID, Copilot/Recall off; XP/7: Security/Action Center nags,
   error reporting on NT5). S-M.
7. **UAC level** instead of only off (Vista..11). S.
8. **Visual effects preset + ClearType/font smoothing** (9x..11). M.
9. **Desktop icons** (Computer, user, Network, Recycle Bin, Control
   Panel, Downloads) XP..11, plus Edge icon removal. S.
10. **Auto logon, password never expires, NumLock, workgroup** (core
    set, every NT family). S.
11. **Server pack** (Server Manager / ICT / Manage Your Server off,
    IE ESC off, shutdown tracker off, Ctrl+Alt+Del off, workstation
    mode) for 2003..2025. S.
12. **`usos-reg.exe` native helper** (REGEDIT4 subset into HKLM,
    .DEFAULT, Default User) to bring the core set to 2000, NT4 and NT 3.x
    and to shorten 6.x+ command chains. L.
13. **9x MSBATCH pack** (optional components, Active Desktop/Channel
    bar, tips, AutoRun, visual effects, display mode, MS-DOS mode options
    for 95/98). M.
14. **Bloatware removal for 8.x..11** with a USOS-maintained vocabulary
    (group names -> package family prefixes, capabilities, features),
    file payload channel, VM check per release; safe defaults keep
    Store, Calculator, Photos, Notepad, Terminal. L.
15. **Power profile + user script hook** (desktop / laptop / auto by
    battery, the user's script turned into options; plus
    `Scripts\<family>\` user script on DATA run at the family's first
    logon/RunOnce). M.

Deliberately not in the top 15: Defender off (Tamper Protection makes it
unreliable and it is a security regression; can come later as an
explicit "advanced" option), Edge removal (servicing restores it, high
risk), partitioning (conflicts with the one-disk-question rule), WDAC /
AppLocker, VM guest tools, wallpaper/lock-screen images.

## 8. Next steps

- Agree the option table shape (1) and the editor grouping with the user.
- Prove the 6.x+ file payload channel in QEMU (WORK `$OEM$` and the
  native path copy) before the removal work.
- Start with items 2-7 on 10/11 + XP (largest user value, small
  effort), goldens per family, one VirtualBox/QEMU install per family.
