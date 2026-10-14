//! Typed answer-profile options (stage 1 of
//! docs/research/profile-options-2026-10-12.md): one table of options with
//! their value type, editor group and, per Windows release, how each value
//! is rendered. The renderers (autounattend.zig, nt5.zig, nt4.zig,
//! msbatch.zig) turn the same rules into their own delivery channel:
//!
//!   6.x+    specialize RunSynchronous commands (reg.exe; the Default User
//!           hive loaded as HKU\USOSDefault), plus native unattend elements
//!   NT5     reg= lines in the rendered settings, applied at setup end by
//!           usos-reg.exe (tools/windows_usos_reg.c) from usos-users.cmd
//!   NT 4.0  ;USOS-REG= lines in WINNT.SIF, applied by usos-reg.exe from
//!           POST.CMD at the one automatic Administrator logon
//!   9x      an MSBATCH.INF AddReg section (HKCU at Setup time is the
//!           single default user)
//!
//! Registry roots: `hklm`; `user` = every new user (the Default User hive;
//! on 9x HKCU; usos-reg also writes HKCU when it runs as a user); `default`
//! = HKU\.DEFAULT (the logon screen). Values are facts from Microsoft's
//! documentation and policy templates (knowledge only; the option catalogue
//! follows Christoph Schneegans' unattend generator, MIT, nothing copied).
//!
//! Compatibility: a value is written to the profile file only when it is
//! not the default, so a profile without new options stays readable by
//! older builds and renders byte for byte as before (goldens).
const std = @import("std");
const target = @import("target.zig");
const Family = target.Family;

/// The Windows releases the options know (9x, NT 3.x/4.0, NT5, 6.x+).
pub const Os = enum(u4) { win95, win98, win_me, nt3, nt4, w2000, xp, w2003, vista, w7, w8, w81, w10, w11 };
pub const OsSet = std.EnumSet(Os);

pub const Target = struct {
    os: Os,
    server: bool = false,
};

fn set(comptime list: []const Os) OsSet {
    return OsSet.initMany(list);
}

const nt6 = set(&.{ .vista, .w7, .w8, .w81, .w10, .w11 });
const w8up = set(&.{ .w8, .w81, .w10, .w11 });
const w10up = set(&.{ .w10, .w11 });
const nt5 = set(&.{ .w2000, .xp, .w2003 });
const nt5up = nt5.unionWith(nt6);
const nt4up = nt5up.unionWith(set(&.{.nt4}));

/// The release of a 6.x+ / NT5 answer family.
pub fn osOfFamily(family: Family) Target {
    const os: Os = switch (family.client()) {
        .windows_2000 => .w2000,
        .windows_xp => .xp,
        .windows_2003 => .w2003,
        .vista => .vista,
        .windows_7 => .w7,
        .windows_8 => .w8,
        .windows_8_1 => .w81,
        .windows_10 => .w10,
        .windows_11 => .w11,
        else => unreachable,
    };
    return .{ .os = os, .server = family.server() };
}

/// The release of a catalog system id (null: no options, e.g. POSReady,
/// Linux).
pub fn targetFor(system_id: []const u8) ?Target {
    const msbatch = @import("msbatch.zig");
    if (msbatch.releaseFor(system_id)) |release| return .{ .os = switch (release) {
        .windows_95 => .win95,
        .windows_98 => .win98,
        .windows_me => .win_me,
    } };
    if (@import("nt4.zig").isNt4(system_id)) return .{ .os = .nt4, .server = !std.ascii.eqlIgnoreCase(system_id, "windows-nt-4") };
    if (@import("nt3.zig").isNt3(system_id)) return .{ .os = .nt3 };
    const family = target.familyFor(system_id) orelse return null;
    return osOfFamily(family);
}

pub const Group = enum { explorer, taskbar, system, updates, apps, accounts };

/// Every option of the table. Options with a `legacy` field keep their
/// value in that existing Profile field (the tweaks of 2026-09-28); the
/// others in Profile.opts. The order is the table's (editor) order.
pub const Opt = enum {
    show_extensions,
    show_hidden,
    show_protected,
    launch_to_pc,
    end_task,
    classic_context_menu,
    shortcut_suffix_off,
    desktop_icons,
    no_autorun,
    no_tips,
    taskbar_search,
    taskbar_left,
    task_view_off,
    widgets_off,
    bing_search_off,
    classic_taskbar,
    all_tray_icons,
    boot_to_desktop,
    lock_screen_off,
    uac_level,
    disable_uac,
    visual_effects,
    font_smoothing,
    mouse_accel_off,
    sticky_keys_off,
    hibernation,
    no_hibernation,
    power_profile,
    no_sleep,
    system_restore_off,
    numlock,
    last_access_off,
    long_paths,
    search_index_off,
    remote_desktop,
    firewall_off,
    server_nags_off,
    ie_esc_off,
    windows_update,
    privacy,
    disable_wer,
    security_center_off,
    defender_off,
    smartscreen_off,
    device_encryption_off,
    remove_apps,
    first_run_off,
    onedrive_off,
    user_script,
    autologon,
    password_never_expires,
};
pub const count = @typeInfo(Opt).@"enum".fields.len;

const toggle = &[_][]const u8{ "no", "yes" };

pub const Option = struct {
    opt: Opt,
    group: Group,
    /// Value names as written in the profile; [0] is the default (never
    /// written). A toggle is no/yes.
    values: []const []const u8 = toggle,
    /// Kept in this existing profile field (a bool), rendered by the
    /// family renderers as before on the releases schema.tweak_support
    /// (or disable_wer: Vista+) names; the rules below add releases.
    legacy: bool = false,

    pub fn isToggle(self: Option) bool {
        return self.values.len == 2 and std.mem.eql(u8, self.values[0], "no") and std.mem.eql(u8, self.values[1], "yes");
    }

    pub fn key(self: Option) []const u8 {
        return @tagName(self.opt);
    }
};

/// The table, in editor order (grouped).
pub const table = [_]Option{
    .{ .opt = .show_extensions, .group = .explorer, .legacy = true },
    .{ .opt = .show_hidden, .group = .explorer, .legacy = true },
    .{ .opt = .show_protected, .group = .explorer },
    .{ .opt = .launch_to_pc, .group = .explorer },
    .{ .opt = .end_task, .group = .explorer },
    .{ .opt = .classic_context_menu, .group = .explorer },
    .{ .opt = .shortcut_suffix_off, .group = .explorer },
    .{ .opt = .desktop_icons, .group = .explorer },
    .{ .opt = .no_autorun, .group = .explorer, .legacy = true },
    .{ .opt = .no_tips, .group = .explorer },
    .{ .opt = .taskbar_search, .group = .taskbar, .values = &.{ "default", "hidden", "icon", "box" } },
    .{ .opt = .taskbar_left, .group = .taskbar },
    .{ .opt = .task_view_off, .group = .taskbar },
    .{ .opt = .widgets_off, .group = .taskbar },
    .{ .opt = .bing_search_off, .group = .taskbar },
    .{ .opt = .classic_taskbar, .group = .taskbar },
    .{ .opt = .all_tray_icons, .group = .taskbar },
    .{ .opt = .boot_to_desktop, .group = .taskbar },
    .{ .opt = .lock_screen_off, .group = .taskbar },
    .{ .opt = .uac_level, .group = .system, .values = &.{ "default", "no_dim", "never" } },
    .{ .opt = .disable_uac, .group = .system, .legacy = true },
    .{ .opt = .visual_effects, .group = .system, .values = &.{ "default", "performance" } },
    .{ .opt = .font_smoothing, .group = .system },
    .{ .opt = .mouse_accel_off, .group = .system },
    .{ .opt = .sticky_keys_off, .group = .system },
    .{ .opt = .hibernation, .group = .system, .values = &.{ "default", "no_fast_startup", "off" } },
    .{ .opt = .no_hibernation, .group = .system, .legacy = true },
    .{ .opt = .power_profile, .group = .system, .values = &.{ "default", "high_performance", "balanced", "power_saver" } },
    .{ .opt = .no_sleep, .group = .system },
    .{ .opt = .system_restore_off, .group = .system },
    .{ .opt = .numlock, .group = .system, .values = &.{ "default", "on", "off" } },
    .{ .opt = .last_access_off, .group = .system },
    .{ .opt = .long_paths, .group = .system },
    .{ .opt = .search_index_off, .group = .system },
    .{ .opt = .remote_desktop, .group = .system },
    .{ .opt = .firewall_off, .group = .system },
    .{ .opt = .server_nags_off, .group = .system },
    .{ .opt = .ie_esc_off, .group = .system },
    .{ .opt = .windows_update, .group = .updates, .values = &.{ "default", "no_restart", "notify", "off" } },
    .{ .opt = .privacy, .group = .updates },
    .{ .opt = .disable_wer, .group = .updates, .legacy = true },
    .{ .opt = .security_center_off, .group = .updates },
    .{ .opt = .defender_off, .group = .updates },
    .{ .opt = .smartscreen_off, .group = .updates },
    .{ .opt = .device_encryption_off, .group = .updates },
    .{ .opt = .remove_apps, .group = .apps, .values = &.{ "default", "games", "bloat" } },
    .{ .opt = .first_run_off, .group = .apps },
    .{ .opt = .onedrive_off, .group = .apps },
    .{ .opt = .user_script, .group = .apps },
    .{ .opt = .autologon, .group = .accounts },
    .{ .opt = .password_never_expires, .group = .accounts },
};

pub fn option(opt: Opt) Option {
    return table[indexOf(opt)];
}

pub fn indexOf(opt: Opt) usize {
    inline for (table, 0..) |o, i| {
        if (o.opt == opt) return i;
    }
    unreachable;
}

pub fn byKey(name: []const u8) ?Opt {
    inline for (@typeInfo(Opt).@"enum".fields) |f| {
        if (std.ascii.eqlIgnoreCase(name, f.name)) return @enumFromInt(f.value);
    }
    return null;
}

pub fn valueByName(o: Option, name: []const u8) ?u8 {
    if (o.isToggle()) {
        const yes = [_][]const u8{ "1", "yes", "true", "on" };
        const no = [_][]const u8{ "0", "no", "false", "off" };
        for (yes) |y| if (std.ascii.eqlIgnoreCase(name, y)) return 1;
        for (no) |n| if (std.ascii.eqlIgnoreCase(name, n)) return 0;
        return null;
    }
    for (o.values, 0..) |v, i| {
        if (std.ascii.eqlIgnoreCase(name, v)) return @intCast(i);
    }
    return null;
}

// ------------------------------------------------------------ rules

pub const Root = enum {
    hklm,
    /// Every new user (Default User hive; HKCU on 9x).
    user,
    /// HKU\.DEFAULT (the logon screen and system account).
    default,

    pub fn setName(self: Root) []const u8 {
        return switch (self) {
            .hklm => "HKLM",
            .user => "USER",
            .default => "DEFAULT",
        };
    }
};

pub const Data = union(enum) {
    dword: u32,
    sz: []const u8,
    /// REG_BINARY as comma-separated hex bytes ("90,12,03,80").
    binary: []const u8,
    /// The profile's first user / password (automatic logon).
    profile_user,
    profile_password,
    /// The value is deleted.
    del,
};

pub const Reg = struct {
    root: Root,
    key: []const u8,
    name: []const u8,
    data: Data,
};

pub const Who = enum { any, client, server };

pub const Action = union(enum) {
    reg: Reg,
    /// A command line: 6.x+ specialize (as SYSTEM), NT5 the setup-end
    /// script (usos-users.cmd).
    command: []const u8,
    /// Rendered by the family renderer itself (an unattend element, a
    /// WINNT.SIF key): listed here so the editor offers the option.
    native,
};

pub const Rule = struct {
    opt: Opt,
    /// The option value this rule renders (1: a toggle's yes).
    value: u8 = 1,
    os: OsSet,
    who: Who = .any,
    /// Skipped when this option is on (it already writes the same value).
    unless: ?Opt = null,
    action: Action,
};

const advanced = "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced";
const explorer_policy = "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer";
const explorer_policy_user = "Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer";
const system_policy = "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System";
const au_policy = "SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate\\AU";
const winlogon = "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon";
const keyboard = "Control Panel\\Keyboard";
const cdm = "Software\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager";

const explorer_user = "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer";
const desktop = "Control Panel\\Desktop";
const metrics = "Control Panel\\Desktop\\WindowMetrics";
const mouse = "Control Panel\\Mouse";
const new_start_panel = explorer_user ++ "\\HideDesktopIcons\\NewStartPanel";
const classic_start_menu = explorer_user ++ "\\HideDesktopIcons\\ClassicStartMenu";
const visual_fx = explorer_user ++ "\\VisualEffects";
const edge_ui = "Software\\Microsoft\\Windows\\CurrentVersion\\ImmersiveShell\\EdgeUi";
const power_cfg = "Control Panel\\PowerCfg";
const file_system = "SYSTEM\\CurrentControlSet\\Control\\FileSystem";
const terminal_server = "SYSTEM\\CurrentControlSet\\Control\\Terminal Server";
/// The XP SP2 / 2003 SP1 Windows Firewall's own (non-policy) settings.
const firewall_xp = "SYSTEM\\CurrentControlSet\\Services\\SharedAccess\\Parameters\\FirewallPolicy";
const security_center = "SOFTWARE\\Microsoft\\Security Center";
const run_once = "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\RunOnce";
const active_setup = "SOFTWARE\\Microsoft\\Active Setup\\Installed Components";
const reliability = "SOFTWARE\\Policies\\Microsoft\\Windows NT\\Reliability";

/// Classic context menu (11): the per-user COM override that makes Explorer
/// show the full menu. It lives in the user's Classes hive (not in the
/// Default User NTUSER.DAT), so an Active Setup component writes it for
/// every user at their first sign-in, before Explorer starts.
pub const classic_menu_stub = "reg.exe add HKCU\\Software\\Classes\\CLSID\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\\InprocServer32 /ve /f";

/// User script hook: at the first sign-in, every drive with the DATA layout
/// (a Systems folder) and Scripts\first-logon.reg / .cmd: the .reg is
/// imported, then the .cmd is called. Nothing happens without the stick.
const data_letters = "C D E F G H I J K L M N O P Q R S T U V W X Y Z";
pub const user_script_reg = "cmd.exe /c for %d in (" ++ data_letters ++ ") do @if exist %d:\\Systems\\nul if exist %d:\\Scripts\\first-logon.reg regedit.exe /s %d:\\Scripts\\first-logon.reg";
pub const user_script_cmd = "cmd.exe /c for %d in (" ++ data_letters ++ ") do @if exist %d:\\Systems\\nul if exist %d:\\Scripts\\first-logon.cmd call %d:\\Scripts\\first-logon.cmd";

/// Provisioned Store apps removed in specialize (8+: the Appx cmdlets of the
/// DISM PowerShell module), matched on the package name. The vocabulary is
/// USOS's own (docs/answer-profiles.md "Options"); Store, Calculator,
/// Photos, Camera, Clock, Notepad, Paint, Snipping Tool, Terminal and the
/// frameworks stay.
fn appx(comptime pattern: []const u8) Action {
    return .{ .command = "powershell.exe -NoP -NonI -C \"Get-AppxProvisionedPackage -Online|?{$_.DisplayName -match '" ++ pattern ++ "'}|Remove-AppxProvisionedPackage -Online\"" };
}
pub const appx_games = "Xbox|GamingApp|Solitaire";
pub const appx_bloat = [_][]const u8{
    "Bing|Zune|Getstarted|OfficeHub|MixedReality|3DViewer|Print3D|MSPaint$|\\.People$|WindowsMaps|SkypeApp",
    "Messaging|Clipchamp|FeedbackHub|GetHelp|Wallet|YourPhone|PowerAutomate|Todos|Family|549981C3F5F10|Copilot",
    "communicationsapps|Teams|OneNote|StickyNotes|SoundRecorder|QuickAssist|HelpAndTips|ReadingList|DevHome",
    "OutlookForWindows",
};

fn reg(root: Root, key: []const u8, name: []const u8, data: Data) Action {
    return .{ .reg = .{ .root = root, .key = key, .name = name, .data = data } };
}

fn dw(root: Root, key: []const u8, name: []const u8, value: u32) Action {
    return reg(root, key, name, .{ .dword = value });
}

const w9x_shell = set(&.{ .win98, .win_me });
const w9x = set(&.{ .win95, .win98, .win_me });
const xp2003 = set(&.{ .xp, .w2003 });
const w9x_nt4 = w9x.unionWith(set(&.{.nt4}));
const visual_basic = w9x_nt4.unionWith(set(&.{.w2000})).unionWith(nt6);
const before_w11 = w9x_nt4.unionWith(nt5).unionWith(set(&.{ .vista, .w7, .w8, .w81, .w10 }));

/// Rendering rules. A legacy option renders through its family renderer
/// where it already did (NT5 tokens, 6.x commands); the rules here add the
/// releases that had nothing (Windows 9x, NT 4.0, 2000).
pub const rules = [_]Rule{
    // Explorer -----------------------------------------------------------
    // 98/Me shell (IE4 desktop update); 95 and NT 4.0 keep ShellState.
    .{ .opt = .show_extensions, .os = w9x_shell.unionWith(set(&.{.w2000})), .action = dw(.user, advanced, "HideFileExt", 0) },
    .{ .opt = .show_hidden, .os = w9x_shell.unionWith(set(&.{.w2000})), .action = dw(.user, advanced, "Hidden", 1) },
    // Protected operating system files (Me and 2000 introduced them).
    .{ .opt = .show_protected, .os = set(&.{ .win_me, .w2000 }).unionWith(set(&.{ .xp, .w2003 })).unionWith(nt6), .unless = .show_hidden, .action = dw(.user, advanced, "Hidden", 1) },
    .{ .opt = .show_protected, .os = set(&.{ .win_me, .w2000 }).unionWith(set(&.{ .xp, .w2003 })).unionWith(nt6), .action = dw(.user, advanced, "ShowSuperHidden", 1) },
    .{ .opt = .launch_to_pc, .os = w10up, .action = dw(.user, advanced, "LaunchTo", 1) },
    .{ .opt = .end_task, .os = set(&.{.w11}), .action = dw(.user, advanced ++ "\\TaskbarDeveloperSettings", "TaskbarEndTask", 1) },
    // AutoRun: 9x reads the per-user policy (REG_BINARY on 9x, written as
    // binary by the 9x renderer); NT 4.0 / 2000 the machine policy and the
    // CD-ROM driver's own switch.
    .{ .opt = .no_autorun, .os = w9x, .action = dw(.user, explorer_policy_user, "NoDriveTypeAutoRun", 0xff) },
    .{ .opt = .no_autorun, .os = set(&.{ .nt4, .w2000 }), .action = dw(.hklm, explorer_policy, "NoDriveTypeAutoRun", 0xff) },
    .{ .opt = .no_autorun, .os = set(&.{ .nt4, .w2000 }), .action = dw(.hklm, "SYSTEM\\CurrentControlSet\\Services\\Cdrom", "Autorun", 0) },
    // NT 4.0 "Welcome to Windows NT", 2000 "Getting Started" (welcome.exe).
    .{ .opt = .no_tips, .os = set(&.{ .nt4, .w2000 }), .action = dw(.user, "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Tips", "Show", 0) },
    // Taskbar and Start (10/11) ------------------------------------------
    .{ .opt = .taskbar_search, .value = 1, .os = w10up, .action = dw(.user, "Software\\Microsoft\\Windows\\CurrentVersion\\Search", "SearchboxTaskbarMode", 0) },
    .{ .opt = .taskbar_search, .value = 2, .os = w10up, .action = dw(.user, "Software\\Microsoft\\Windows\\CurrentVersion\\Search", "SearchboxTaskbarMode", 1) },
    .{ .opt = .taskbar_search, .value = 3, .os = w10up, .action = dw(.user, "Software\\Microsoft\\Windows\\CurrentVersion\\Search", "SearchboxTaskbarMode", 2) },
    // 11 rewrites the per-user value at the first logon (QEMU 2026-10-12:
    // icon became box); the policy (Search/ConfigureSearchOnTaskbarMode:
    // 0 hide, 1 icon, 3 box) holds it.
    .{ .opt = .taskbar_search, .value = 1, .os = set(&.{.w11}), .action = dw(.hklm, "SOFTWARE\\Policies\\Microsoft\\Windows\\Windows Search", "SearchOnTaskbarMode", 0) },
    .{ .opt = .taskbar_search, .value = 2, .os = set(&.{.w11}), .action = dw(.hklm, "SOFTWARE\\Policies\\Microsoft\\Windows\\Windows Search", "SearchOnTaskbarMode", 1) },
    .{ .opt = .taskbar_search, .value = 3, .os = set(&.{.w11}), .action = dw(.hklm, "SOFTWARE\\Policies\\Microsoft\\Windows\\Windows Search", "SearchOnTaskbarMode", 3) },
    .{ .opt = .taskbar_left, .os = set(&.{.w11}), .who = .client, .action = dw(.user, advanced, "TaskbarAl", 0) },
    .{ .opt = .task_view_off, .os = w10up, .action = dw(.user, advanced, "ShowTaskViewButton", 0) },
    // Widgets (11) / News and interests (10).
    .{ .opt = .widgets_off, .os = set(&.{.w11}), .who = .client, .action = dw(.hklm, "SOFTWARE\\Policies\\Microsoft\\Dsh", "AllowNewsAndInterests", 0) },
    .{ .opt = .widgets_off, .os = set(&.{.w10}), .who = .client, .action = dw(.hklm, "SOFTWARE\\Policies\\Microsoft\\Windows\\Windows Feeds", "EnableFeeds", 0) },
    .{ .opt = .bing_search_off, .os = w10up, .action = dw(.user, "Software\\Policies\\Microsoft\\Windows\\Explorer", "DisableSearchBoxSuggestions", 1) },
    // System -------------------------------------------------------------
    // UAC without the dimmed secure desktop / never notify (EnableLUA stays
    // on: 8+ Store apps need it).
    .{ .opt = .uac_level, .value = 1, .os = nt6, .action = dw(.hklm, system_policy, "ConsentPromptBehaviorAdmin", 5) },
    .{ .opt = .uac_level, .value = 1, .os = nt6, .action = dw(.hklm, system_policy, "PromptOnSecureDesktop", 0) },
    .{ .opt = .uac_level, .value = 2, .os = nt6, .action = dw(.hklm, system_policy, "ConsentPromptBehaviorAdmin", 0) },
    .{ .opt = .uac_level, .value = 2, .os = nt6, .action = dw(.hklm, system_policy, "PromptOnSecureDesktop", 0) },
    // 8+: Fast startup off, or hibernation off altogether (also ends Fast
    // startup). Vista/7 keep the no_hibernation toggle.
    .{ .opt = .hibernation, .value = 1, .os = w8up, .who = .client, .action = dw(.hklm, "SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Power", "HiberbootEnabled", 0) },
    .{ .opt = .hibernation, .value = 2, .os = w8up, .who = .client, .action = .{ .command = "powercfg.exe -h off" } },
    .{ .opt = .system_restore_off, .os = set(&.{.xp}), .action = dw(.hklm, "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\SystemRestore", "DisableSR", 1) },
    .{ .opt = .system_restore_off, .os = nt6, .who = .client, .action = dw(.hklm, "SOFTWARE\\Policies\\Microsoft\\Windows NT\\SystemRestore", "DisableSR", 1) },
    .{ .opt = .system_restore_off, .os = nt6, .who = .client, .action = dw(.hklm, "SOFTWARE\\Policies\\Microsoft\\Windows NT\\SystemRestore", "DisableConfig", 1) },
    // NumLock at the logon screen and for every new user. 8+ keep the
    // high bit their own setting carries.
    .{ .opt = .numlock, .value = 1, .os = nt4up.differenceWith(w8up), .action = reg(.default, keyboard, "InitialKeyboardIndicators", .{ .sz = "2" }) },
    .{ .opt = .numlock, .value = 1, .os = w8up, .action = reg(.default, keyboard, "InitialKeyboardIndicators", .{ .sz = "2147483650" }) },
    .{ .opt = .numlock, .value = 1, .os = nt4up, .action = reg(.user, keyboard, "InitialKeyboardIndicators", .{ .sz = "2" }) },
    .{ .opt = .numlock, .value = 2, .os = nt4up.differenceWith(w8up), .action = reg(.default, keyboard, "InitialKeyboardIndicators", .{ .sz = "0" }) },
    .{ .opt = .numlock, .value = 2, .os = w8up, .action = reg(.default, keyboard, "InitialKeyboardIndicators", .{ .sz = "2147483648" }) },
    .{ .opt = .numlock, .value = 2, .os = nt4up, .action = reg(.user, keyboard, "InitialKeyboardIndicators", .{ .sz = "0" }) },
    // Updates and privacy ------------------------------------------------
    // Automatic Updates policy (2000 SP3+, XP, 2003, Vista+).
    .{ .opt = .windows_update, .value = 1, .os = nt5up, .action = dw(.hklm, au_policy, "NoAutoRebootWithLoggedOnUsers", 1) },
    .{ .opt = .windows_update, .value = 2, .os = nt5up, .action = dw(.hklm, au_policy, "NoAutoUpdate", 0) },
    .{ .opt = .windows_update, .value = 2, .os = nt5up, .action = dw(.hklm, au_policy, "AUOptions", 2) },
    .{ .opt = .windows_update, .value = 2, .os = nt5up, .action = dw(.hklm, au_policy, "NoAutoRebootWithLoggedOnUsers", 1) },
    .{ .opt = .windows_update, .value = 3, .os = nt5up, .action = dw(.hklm, au_policy, "NoAutoUpdate", 1) },
    // Consumer features, suggestions, advertising ID, tailored experiences,
    // telemetry at the lowest level the edition allows, Copilot and Recall.
    .{ .opt = .privacy, .os = w10up, .action = dw(.hklm, "SOFTWARE\\Policies\\Microsoft\\Windows\\CloudContent", "DisableWindowsConsumerFeatures", 1) },
    .{ .opt = .privacy, .os = w10up, .action = dw(.hklm, "SOFTWARE\\Policies\\Microsoft\\Windows\\DataCollection", "AllowTelemetry", 0) },
    .{ .opt = .privacy, .os = w10up, .action = dw(.hklm, "SOFTWARE\\Policies\\Microsoft\\Windows\\AdvertisingInfo", "DisabledByGroupPolicy", 1) },
    .{ .opt = .privacy, .os = set(&.{.w11}), .action = dw(.hklm, "SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsCopilot", "TurnOffWindowsCopilot", 1) },
    .{ .opt = .privacy, .os = set(&.{.w11}), .action = dw(.hklm, "SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsAI", "DisableAIDataAnalysis", 1) },
    .{ .opt = .privacy, .os = w10up, .action = dw(.user, "Software\\Policies\\Microsoft\\Windows\\CloudContent", "DisableTailoredExperiencesWithDiagnosticData", 1) },
    .{ .opt = .privacy, .os = set(&.{.w11}), .action = dw(.user, "Software\\Policies\\Microsoft\\Windows\\WindowsCopilot", "TurnOffWindowsCopilot", 1) },
    .{ .opt = .privacy, .os = w10up, .action = dw(.user, "Software\\Microsoft\\Windows\\CurrentVersion\\AdvertisingInfo", "Enabled", 0) },
    .{ .opt = .privacy, .os = w10up, .action = dw(.user, cdm, "SilentInstalledAppsEnabled", 0) },
    .{ .opt = .privacy, .os = w10up, .action = dw(.user, cdm, "SystemPaneSuggestionsEnabled", 0) },
    .{ .opt = .privacy, .os = w10up, .action = dw(.user, cdm, "SoftLandingEnabled", 0) },
    .{ .opt = .privacy, .os = w10up, .action = dw(.user, cdm, "SubscribedContent-338388Enabled", 0) },
    .{ .opt = .privacy, .os = w10up, .action = dw(.user, cdm, "SubscribedContent-338389Enabled", 0) },
    .{ .opt = .privacy, .os = w10up, .action = dw(.user, cdm, "SubscribedContent-353698Enabled", 0) },
    // Stage 2 (2026-10-14): packs for every family ------------------------
    // Explorer
    .{ .opt = .classic_context_menu, .os = set(&.{.w11}), .action = reg(.hklm, active_setup ++ "\\USOS-ClassicContextMenu", "StubPath", .{ .sz = classic_menu_stub }) },
    .{ .opt = .classic_context_menu, .os = set(&.{.w11}), .action = reg(.hklm, active_setup ++ "\\USOS-ClassicContextMenu", "Version", .{ .sz = "1" }) },
    .{ .opt = .classic_context_menu, .os = set(&.{.w11}), .action = dw(.hklm, active_setup ++ "\\USOS-ClassicContextMenu", "IsInstalled", 1) },
    // "Shortcut to" (9x, NT 4.0, 2000) / "- Shortcut" (XP..10) naming.
    .{ .opt = .shortcut_suffix_off, .os = before_w11, .action = reg(.user, explorer_user, "link", .{ .binary = "00,00,00,00" }) },
    // Desktop icons: XP / 2003 My Computer, My Documents, My Network Places
    // (both Start menu styles); Vista+ Computer, the user's files, Network,
    // Control Panel.
    .{ .opt = .desktop_icons, .os = xp2003, .action = dw(.user, new_start_panel, "{20D04FE0-3AEA-1069-A2D8-08002B30309D}", 0) },
    .{ .opt = .desktop_icons, .os = xp2003, .action = dw(.user, new_start_panel, "{450D8FBA-AD25-11D0-98A8-0800361B1103}", 0) },
    .{ .opt = .desktop_icons, .os = xp2003, .action = dw(.user, new_start_panel, "{208D2C60-3AEA-1069-A2D7-08002B30309D}", 0) },
    .{ .opt = .desktop_icons, .os = xp2003, .action = dw(.user, classic_start_menu, "{20D04FE0-3AEA-1069-A2D8-08002B30309D}", 0) },
    .{ .opt = .desktop_icons, .os = xp2003, .action = dw(.user, classic_start_menu, "{450D8FBA-AD25-11D0-98A8-0800361B1103}", 0) },
    .{ .opt = .desktop_icons, .os = xp2003, .action = dw(.user, classic_start_menu, "{208D2C60-3AEA-1069-A2D7-08002B30309D}", 0) },
    .{ .opt = .desktop_icons, .os = nt6, .action = dw(.user, new_start_panel, "{20D04FE0-3AEA-1069-A2D8-08002B30309D}", 0) },
    .{ .opt = .desktop_icons, .os = nt6, .action = dw(.user, new_start_panel, "{59031a47-3f72-44a7-89c5-5595fe6b30ee}", 0) },
    .{ .opt = .desktop_icons, .os = nt6, .action = dw(.user, new_start_panel, "{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}", 0) },
    .{ .opt = .desktop_icons, .os = nt6, .action = dw(.user, new_start_panel, "{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}", 0) },
    // XP / 2003: the Tour prompt and the Desktop Cleanup Wizard.
    .{ .opt = .no_tips, .os = xp2003, .action = dw(.user, "Software\\Microsoft\\Windows\\CurrentVersion\\Applets\\Tour", "RunCount", 0) },
    .{ .opt = .no_tips, .os = xp2003, .action = dw(.user, explorer_user ++ "\\Desktop\\CleanupWiz", "NoRun", 1) },
    // Taskbar
    // XP..Vista "Group similar taskbar buttons" off; 7..10 small buttons,
    // never combined; 11 (23H2+) never combined.
    .{ .opt = .classic_taskbar, .os = set(&.{ .xp, .w2003, .vista }), .action = dw(.user, advanced, "TaskbarGlomming", 0) },
    .{ .opt = .classic_taskbar, .os = set(&.{ .w7, .w8, .w81, .w10 }), .action = dw(.user, advanced, "TaskbarSmallIcons", 1) },
    .{ .opt = .classic_taskbar, .os = set(&.{ .w7, .w8, .w81, .w10, .w11 }), .action = dw(.user, advanced, "TaskbarGlomLevel", 2) },
    // 11 ignores EnableAutoTray.
    .{ .opt = .all_tray_icons, .os = xp2003.unionWith(nt6).differenceWith(set(&.{.w11})), .action = dw(.user, explorer_user, "EnableAutoTray", 0) },
    .{ .opt = .boot_to_desktop, .os = set(&.{.w81}), .action = dw(.user, explorer_user ++ "\\StartPage", "OpenAtLogon", 0) },
    .{ .opt = .boot_to_desktop, .os = set(&.{ .w8, .w81 }), .action = dw(.user, edge_ui, "DisableTLCorner", 1) },
    .{ .opt = .boot_to_desktop, .os = set(&.{ .w8, .w81 }), .action = dw(.user, edge_ui, "DisableCharmsHint", 1) },
    .{ .opt = .lock_screen_off, .os = w8up, .action = dw(.hklm, "SOFTWARE\\Policies\\Microsoft\\Windows\\Personalization", "NoLockScreen", 1) },
    // System
    // Best performance: no minimize animation, outlines while dragging;
    // 6.x+ also the effect bits (UserPreferencesMask) and the dialog's choice.
    // Not XP / 2003: QEMU 2026-10-14 (XP MCE), the first logon's own visual
    // settings replaced MinAnimate, DragFullWindows and the mask in the
    // user's profile (the Default User hive kept them).
    .{ .opt = .visual_effects, .os = visual_basic, .action = reg(.user, metrics, "MinAnimate", .{ .sz = "0" }) },
    .{ .opt = .visual_effects, .os = visual_basic, .action = reg(.user, desktop, "DragFullWindows", .{ .sz = "0" }) },
    .{ .opt = .visual_effects, .os = nt6, .action = reg(.user, desktop, "UserPreferencesMask", .{ .binary = "90,12,03,80,10,00,00,00" }) },
    .{ .opt = .visual_effects, .os = nt6, .action = dw(.user, visual_fx, "VisualFXSetting", 2) },
    .{ .opt = .visual_effects, .os = nt6, .action = dw(.user, advanced, "TaskbarAnimations", 0) },
    .{ .opt = .visual_effects, .os = nt6, .action = dw(.user, advanced, "ListviewAlphaSelect", 0) },
    .{ .opt = .visual_effects, .os = nt6, .action = dw(.user, advanced, "ListviewShadow", 0) },
    .{ .opt = .visual_effects, .os = nt6, .action = dw(.user, "Software\\Microsoft\\Windows\\DWM", "EnableAeroPeek", 0) },
    // Font smoothing (2000: standard; XP / 2003: ClearType); Vista+ have
    // ClearType on by default.
    .{ .opt = .font_smoothing, .os = nt5, .action = reg(.default, desktop, "FontSmoothing", .{ .sz = "2" }) },
    .{ .opt = .font_smoothing, .os = nt5, .action = reg(.user, desktop, "FontSmoothing", .{ .sz = "2" }) },
    .{ .opt = .font_smoothing, .os = xp2003, .action = dw(.default, desktop, "FontSmoothingType", 2) },
    .{ .opt = .font_smoothing, .os = xp2003, .action = dw(.user, desktop, "FontSmoothingType", 2) },
    .{ .opt = .mouse_accel_off, .os = w9x_nt4.unionWith(nt5up), .action = reg(.user, mouse, "MouseSpeed", .{ .sz = "0" }) },
    .{ .opt = .mouse_accel_off, .os = w9x_nt4.unionWith(nt5up), .action = reg(.user, mouse, "MouseThreshold1", .{ .sz = "0" }) },
    .{ .opt = .mouse_accel_off, .os = w9x_nt4.unionWith(nt5up), .action = reg(.user, mouse, "MouseThreshold2", .{ .sz = "0" }) },
    // The Shift x5 shortcut off (Flags without the hot key and confirmation bits).
    .{ .opt = .sticky_keys_off, .os = nt5up, .action = reg(.user, "Control Panel\\Accessibility\\StickyKeys", "Flags", .{ .sz = "506" }) },
    .{ .opt = .hibernation, .value = 2, .os = xp2003, .action = .{ .command = "powercfg.exe /hibernate off" } },
    // Power plan: 6.x+ the built-in plans by alias (machine-wide); XP / 2003
    // the scheme of every new user and the logon screen (3 Always On,
    // 0 Home/Office Desk, 5 Max Battery).
    .{ .opt = .power_profile, .value = 1, .os = nt6, .action = .{ .command = "powercfg.exe -setactive SCHEME_MIN" } },
    .{ .opt = .power_profile, .value = 2, .os = nt6, .action = .{ .command = "powercfg.exe -setactive SCHEME_BALANCED" } },
    .{ .opt = .power_profile, .value = 3, .os = nt6, .action = .{ .command = "powercfg.exe -setactive SCHEME_MAX" } },
    .{ .opt = .power_profile, .value = 1, .os = xp2003, .action = reg(.default, power_cfg, "CurrentPowerPolicy", .{ .sz = "3" }) },
    .{ .opt = .power_profile, .value = 1, .os = xp2003, .action = reg(.user, power_cfg, "CurrentPowerPolicy", .{ .sz = "3" }) },
    .{ .opt = .power_profile, .value = 2, .os = xp2003, .action = reg(.default, power_cfg, "CurrentPowerPolicy", .{ .sz = "0" }) },
    .{ .opt = .power_profile, .value = 2, .os = xp2003, .action = reg(.user, power_cfg, "CurrentPowerPolicy", .{ .sz = "0" }) },
    .{ .opt = .power_profile, .value = 3, .os = xp2003, .action = reg(.default, power_cfg, "CurrentPowerPolicy", .{ .sz = "5" }) },
    .{ .opt = .power_profile, .value = 3, .os = xp2003, .action = reg(.user, power_cfg, "CurrentPowerPolicy", .{ .sz = "5" }) },
    // After power_profile (rule order): the active plan's AC timeouts.
    .{ .opt = .no_sleep, .os = nt6, .who = .client, .action = .{ .command = "cmd.exe /c powercfg.exe -change -standby-timeout-ac 0 & powercfg.exe -change -hibernate-timeout-ac 0" } },
    // Vista+ do not update the last-access time by default.
    .{ .opt = .last_access_off, .os = set(&.{.nt4}).unionWith(nt5), .action = dw(.hklm, file_system, "NtfsDisableLastAccessUpdate", 1) },
    .{ .opt = .long_paths, .os = w10up, .action = dw(.hklm, file_system, "LongPathsEnabled", 1) },
    .{ .opt = .search_index_off, .os = nt6, .who = .client, .action = .{ .command = "sc.exe config WSearch start= disabled" } },
    // Remote Desktop: XP / 2003 the firewall's port list (language-neutral);
    // 6.x+ a named rule through netsh (the built-in group name is localized).
    .{ .opt = .remote_desktop, .os = xp2003.unionWith(nt6), .action = dw(.hklm, terminal_server, "fDenyTSConnections", 0) },
    .{ .opt = .remote_desktop, .os = xp2003, .action = reg(.hklm, firewall_xp ++ "\\StandardProfile\\GloballyOpenPorts\\List", "3389:TCP", .{ .sz = "3389:TCP:*:Enabled:Remote Desktop" }) },
    .{ .opt = .remote_desktop, .os = xp2003, .action = reg(.hklm, firewall_xp ++ "\\DomainProfile\\GloballyOpenPorts\\List", "3389:TCP", .{ .sz = "3389:TCP:*:Enabled:Remote Desktop" }) },
    .{ .opt = .remote_desktop, .os = nt6, .action = .{ .command = "netsh.exe advfirewall firewall add rule name=USOS-RDP dir=in action=allow protocol=TCP localport=3389" } },
    .{ .opt = .firewall_off, .os = xp2003, .action = dw(.hklm, firewall_xp ++ "\\StandardProfile", "EnableFirewall", 0) },
    .{ .opt = .firewall_off, .os = xp2003, .action = dw(.hklm, firewall_xp ++ "\\DomainProfile", "EnableFirewall", 0) },
    .{ .opt = .firewall_off, .os = nt6, .action = .{ .command = "netsh.exe advfirewall set allprofiles state off" } },
    // Server: shutdown reason prompt, Ctrl+Alt+Del, Manage Your Server (2003).
    .{ .opt = .server_nags_off, .os = set(&.{.w2003}).unionWith(nt6), .who = .server, .action = dw(.hklm, reliability, "ShutdownReasonOn", 0) },
    .{ .opt = .server_nags_off, .os = set(&.{.w2003}).unionWith(nt6), .who = .server, .action = dw(.hklm, system_policy, "DisableCAD", 1) },
    .{ .opt = .server_nags_off, .os = set(&.{.w2003}), .who = .server, .action = dw(.hklm, "SOFTWARE\\Policies\\Microsoft\\Windows NT\\CurrentVersion\\MYS", "DisableShowAtLogon", 1) },
    .{ .opt = .server_nags_off, .os = set(&.{.w2003}), .who = .server, .action = dw(.user, "Software\\Policies\\Microsoft\\Windows NT\\CurrentVersion\\MYS", "DisableShowAtLogon", 1) },
    // IE Enhanced Security Configuration: its per-user Active Setup
    // components (administrators, users) stay uninstalled.
    .{ .opt = .ie_esc_off, .os = nt6, .who = .server, .action = dw(.hklm, active_setup ++ "\\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}", "IsInstalled", 0) },
    .{ .opt = .ie_esc_off, .os = nt6, .who = .server, .action = dw(.hklm, active_setup ++ "\\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}", "IsInstalled", 0) },
    // Updates, privacy and security
    // XP / 2003 error reporting (Vista+: ErrorReportingCore, legacy field).
    .{ .opt = .disable_wer, .os = xp2003, .action = dw(.hklm, "SOFTWARE\\Microsoft\\PCHealth\\ErrorReporting", "DoReport", 0) },
    .{ .opt = .disable_wer, .os = xp2003, .action = dw(.hklm, "SOFTWARE\\Microsoft\\PCHealth\\ErrorReporting", "ShowUI", 0) },
    // Customer Experience Improvement Program (Vista+), 8.1 web search.
    .{ .opt = .privacy, .os = nt6, .action = dw(.hklm, "SOFTWARE\\Policies\\Microsoft\\SQMClient\\Windows", "CEIPEnable", 0) },
    .{ .opt = .privacy, .os = set(&.{.w81}), .action = dw(.hklm, "SOFTWARE\\Policies\\Microsoft\\Windows\\AdvertisingInfo", "DisabledByGroupPolicy", 1) },
    .{ .opt = .privacy, .os = set(&.{.w81}), .action = dw(.hklm, "SOFTWARE\\Policies\\Microsoft\\Windows\\Windows Search", "ConnectedSearchUseWeb", 0) },
    .{ .opt = .security_center_off, .os = set(&.{ .xp, .vista }), .who = .client, .action = dw(.hklm, security_center, "FirewallDisableNotify", 1) },
    .{ .opt = .security_center_off, .os = set(&.{ .xp, .vista }), .who = .client, .action = dw(.hklm, security_center, "AntiVirusDisableNotify", 1) },
    .{ .opt = .security_center_off, .os = set(&.{ .xp, .vista }), .who = .client, .action = dw(.hklm, security_center, "UpdatesDisableNotify", 1) },
    .{ .opt = .security_center_off, .os = set(&.{ .w7, .w8, .w81 }), .who = .client, .action = dw(.user, explorer_policy_user, "HideSCAHealth", 1) },
    .{ .opt = .security_center_off, .os = w10up, .who = .client, .action = dw(.user, "Software\\Microsoft\\Windows\\CurrentVersion\\Notifications\\Settings\\Windows.SystemToast.SecurityAndMaintenance", "Enabled", 0) },
    // Defender as antispyware (Vista..8.1; 10+ Tamper Protection ignores it).
    .{ .opt = .defender_off, .os = set(&.{ .vista, .w7, .w8, .w81 }), .who = .client, .action = dw(.hklm, "SOFTWARE\\Policies\\Microsoft\\Windows Defender", "DisableAntiSpyware", 1) },
    .{ .opt = .smartscreen_off, .os = w8up, .action = dw(.hklm, "SOFTWARE\\Policies\\Microsoft\\Windows\\System", "EnableSmartScreen", 0) },
    .{ .opt = .smartscreen_off, .os = w8up, .action = reg(.hklm, "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer", "SmartScreenEnabled", .{ .sz = "Off" }) },
    .{ .opt = .device_encryption_off, .os = w10up, .action = dw(.hklm, "SYSTEM\\CurrentControlSet\\Control\\BitLocker", "PreventDeviceEncryption", 1) },
    // Apps and scripts
    .{ .opt = .remove_apps, .value = 1, .os = w8up, .who = .client, .action = appx(appx_games) },
    .{ .opt = .remove_apps, .value = 2, .os = w8up, .who = .client, .action = appx(appx_games) },
    .{ .opt = .remove_apps, .value = 2, .os = w8up, .who = .client, .action = appx(appx_bloat[0]) },
    .{ .opt = .remove_apps, .value = 2, .os = w8up, .who = .client, .action = appx(appx_bloat[1]) },
    .{ .opt = .remove_apps, .value = 2, .os = w8up, .who = .client, .action = appx(appx_bloat[2]) },
    .{ .opt = .remove_apps, .value = 2, .os = w8up, .who = .client, .action = appx(appx_bloat[3]) },
    // IE7+ customize wizard (policy); WMP privacy wizard; Edge first run and
    // startup boost. Not XP / 2003: IE6 has no policy, and its per-user
    // RunOnceHasShown values were reset at the first logon (QEMU 2026-10-14).
    .{ .opt = .first_run_off, .os = nt6.differenceWith(set(&.{.w11})), .action = dw(.hklm, "SOFTWARE\\Policies\\Microsoft\\Internet Explorer\\Main", "DisableFirstRunCustomize", 1) },
    .{ .opt = .first_run_off, .os = nt6, .action = dw(.hklm, "SOFTWARE\\Policies\\Microsoft\\WindowsMediaPlayer", "GroupPrivacyAcceptance", 1) },
    .{ .opt = .first_run_off, .os = w10up, .action = dw(.hklm, "SOFTWARE\\Policies\\Microsoft\\Edge", "HideFirstRunExperience", 1) },
    .{ .opt = .first_run_off, .os = w10up, .action = dw(.hklm, "SOFTWARE\\Policies\\Microsoft\\Edge", "StartupBoostEnabled", 0) },
    .{ .opt = .onedrive_off, .os = set(&.{.w81}), .who = .client, .action = dw(.hklm, "SOFTWARE\\Policies\\Microsoft\\Windows\\Skydrive", "DisableFileSync", 1) },
    .{ .opt = .onedrive_off, .os = w10up, .who = .client, .action = dw(.hklm, "SOFTWARE\\Policies\\Microsoft\\Windows\\OneDrive", "DisableFileSyncNGSC", 1) },
    .{ .opt = .onedrive_off, .os = w10up, .who = .client, .action = reg(.user, "Software\\Microsoft\\Windows\\CurrentVersion\\Run", "OneDriveSetup", .del) },
    // 6.x+: oobeSystem FirstLogonCommands (autounattend.zig); NT5: the
    // machine RunOnce (the first sign-in after Setup, any user).
    .{ .opt = .user_script, .os = nt6, .action = .native },
    .{ .opt = .user_script, .os = nt5, .action = reg(.hklm, run_once, "USOS1UserReg", .{ .sz = user_script_reg }) },
    .{ .opt = .user_script, .os = nt5, .action = reg(.hklm, run_once, "USOS2UserScript", .{ .sz = user_script_cmd }) },
    // Accounts -----------------------------------------------------------
    // 6.x+: the Shell-Setup AutoLogon element (autounattend.zig). NT5: the
    // Winlogon values, written at setup end after Setup's own.
    .{ .opt = .autologon, .os = nt6, .action = .native },
    .{ .opt = .autologon, .os = nt5, .action = reg(.hklm, winlogon, "AutoAdminLogon", .{ .sz = "1" }) },
    .{ .opt = .autologon, .os = nt5, .action = reg(.hklm, winlogon, "DefaultUserName", .profile_user) },
    .{ .opt = .autologon, .os = nt5, .action = reg(.hklm, winlogon, "DefaultPassword", .profile_password) },
    .{ .opt = .autologon, .os = nt5, .action = reg(.hklm, winlogon, "AutoLogonCount", .del) },
    .{ .opt = .password_never_expires, .os = nt5up, .action = .{ .command = "net.exe accounts /maxpwage:unlimited" } },
};

fn ruleApplies(rule: Rule, t: Target) bool {
    if (!rule.os.contains(t.os)) return false;
    return switch (rule.who) {
        .any => true,
        .client => !t.server,
        .server => t.server,
    };
}

/// The legacy renderers' own coverage (schema.tweak_support, disable_wer
/// on Vista+).
fn legacyAvailable(opt: Opt, t: Target) bool {
    const schema = @import("schema.zig");
    const family = familyOf(t) orelse return false;
    return switch (opt) {
        .disable_wer => !family.nt5(),
        inline .show_extensions, .show_hidden, .no_autorun, .disable_uac, .no_hibernation => |o| schema.tweakAvailable(@field(schema.Tweak, @tagName(o)), family),
        else => false,
    };
}

/// A family for a release (the client of the level; Server when asked).
fn familyOf(t: Target) ?Family {
    return switch (t.os) {
        .w2000 => .windows_2000,
        .xp => .windows_xp,
        .w2003 => .windows_2003,
        .vista => if (t.server) .server_2008 else .vista,
        .w7 => if (t.server) .server_2008_r2 else .windows_7,
        .w8 => if (t.server) .server_2012 else .windows_8,
        .w81 => if (t.server) .server_2012_r2 else .windows_8_1,
        .w10 => if (t.server) .server_2016 else .windows_10,
        .w11 => if (t.server) .server_2025 else .windows_11,
        else => null,
    };
}

/// The option renders something for this release (the editor offers it).
pub fn available(opt: Opt, t: Target) bool {
    if (option(opt).legacy and legacyAvailable(opt, t)) return true;
    for (rules) |rule| {
        if (rule.opt == opt and ruleApplies(rule, t)) return true;
    }
    return false;
}

/// This value of the option renders something here (default: always).
pub fn valueAvailable(opt: Opt, value: u8, t: Target) bool {
    if (value == 0) return true;
    if (option(opt).legacy) return available(opt, t);
    for (rules) |rule| {
        if (rule.opt == opt and rule.value == value and ruleApplies(rule, t)) return true;
    }
    return false;
}

/// Rules that apply to the profile `values` (one per option) on `t`, in
/// table order. A legacy option yields its rules only where its family
/// renderer has none (legacyAvailable false), so nothing is doubled.
pub const Iterator = struct {
    values: *const [count]u8,
    t: Target,
    i: usize = 0,

    pub fn next(self: *Iterator) ?Rule {
        while (self.i < rules.len) {
            const rule = rules[self.i];
            self.i += 1;
            if (!ruleApplies(rule, self.t)) continue;
            if (self.values[@intFromEnum(rule.opt)] != rule.value) continue;
            if (rule.unless) |other| if (self.values[@intFromEnum(other)] != 0) continue;
            if (option(rule.opt).legacy and legacyAvailable(rule.opt, self.t)) continue;
            return rule;
        }
        return null;
    }
};

/// The option values of a profile, legacy fields included.
pub fn values(p: *const @import("profile.zig").Profile) [count]u8 {
    var out = p.opts;
    inline for (table) |o| {
        if (o.legacy) out[@intFromEnum(o.opt)] = @intFromBool(@field(p, @tagName(o.opt)));
    }
    return out;
}

pub fn iterate(p: *const @import("profile.zig").Profile, vals: *[count]u8, t: Target) Iterator {
    vals.* = values(p);
    return .{ .values = vals, .t = t };
}

/// The data of a registry rule as text (usos-reg set and MSBATCH.INF).
pub fn dataText(data: Data, p: *const @import("profile.zig").Profile, buffer: []u8) []const u8 {
    return switch (data) {
        .dword => |v| std.fmt.bufPrint(buffer, "{d}", .{v}) catch unreachable,
        .sz, .binary => |s| s,
        .profile_user => p.user.slice(),
        .profile_password => p.password.slice(),
        .del => "",
    };
}

/// One line of the usos-reg set (tools/windows_usos_reg.c):
/// ROOT\Key|Name|type|data.
pub fn writeSetLine(w: *std.Io.Writer, r: Reg, p: *const @import("profile.zig").Profile) !void {
    var number: [16]u8 = undefined;
    const kind: []const u8 = switch (r.data) {
        .dword => "dword",
        .del => "del",
        .binary => "binary",
        else => "sz",
    };
    try w.print("{s}\\{s}|{s}|{s}|{s}", .{ r.root.setName(), r.key, r.name, kind, dataText(r.data, p, &number) });
}

// ------------------------------------------------------------ tests

test "options: every option has a profile field of the same name" {
    const Field = @import("profile.zig").Field;
    inline for (@typeInfo(Opt).@"enum".fields) |f| {
        try std.testing.expect(@hasField(Field, f.name));
    }
    try std.testing.expectEqual(@as(usize, count), table.len);
    for (table, 0..) |o, i| try std.testing.expectEqual(i, @as(usize, @intFromEnum(o.opt)));
}

test "options: every rule's value exists, every option renders somewhere" {
    for (rules) |rule| try std.testing.expect(rule.value >= 1 and rule.value < option(rule.opt).values.len);
    const all = [_]Os{ .win95, .win98, .win_me, .nt3, .nt4, .w2000, .xp, .w2003, .vista, .w7, .w8, .w81, .w10, .w11 };
    for (table) |o| {
        var anywhere = false;
        for (all) |os| anywhere = anywhere or available(o.opt, .{ .os = os }) or available(o.opt, .{ .os = os, .server = true });
        try std.testing.expect(anywhere);
        // Every non-default value of a choice renders somewhere.
        for (1..o.values.len) |v| {
            var some = false;
            for (all) |os| some = some or valueAvailable(o.opt, @intCast(v), .{ .os = os }) or valueAvailable(o.opt, @intCast(v), .{ .os = os, .server = true });
            try std.testing.expect(some);
        }
    }
}

test "options: availability per release" {
    try std.testing.expect(available(.show_extensions, .{ .os = .w2000 }));
    try std.testing.expect(available(.show_extensions, .{ .os = .win98 }));
    try std.testing.expect(!available(.show_extensions, .{ .os = .win95 }));
    try std.testing.expect(available(.show_extensions, .{ .os = .w11 }));
    try std.testing.expect(!available(.taskbar_left, .{ .os = .w10 }));
    try std.testing.expect(!available(.taskbar_left, .{ .os = .w11, .server = true }));
    try std.testing.expect(available(.numlock, .{ .os = .nt4 }));
    try std.testing.expect(!available(.numlock, .{ .os = .win98 }));
    try std.testing.expect(available(.disable_wer, .{ .os = .vista }) and available(.disable_wer, .{ .os = .xp }) and !available(.disable_wer, .{ .os = .w2000 }));
    try std.testing.expect(available(.hibernation, .{ .os = .w10 }) and !available(.hibernation, .{ .os = .w7 }));
    try std.testing.expect(available(.no_hibernation, .{ .os = .w7 }) and !available(.no_hibernation, .{ .os = .w10 }));
    try std.testing.expect(!valueAvailable(.taskbar_search, 2, .{ .os = .w81 }));
    try std.testing.expectEqual(Os.win98, targetFor("windows-98-se").?.os);
    try std.testing.expect(targetFor("windows-nt-4-server").?.server);
    try std.testing.expectEqual(Os.w7, targetFor("windows-server-2008-r2").?.os);
    try std.testing.expect(targetFor("ubuntu") == null);
}

test "options: legacy options yield rules only where their renderer has none" {
    var p = @import("profile.zig").Profile{};
    p.show_extensions = true;
    var vals: [count]u8 = undefined;
    var it = iterate(&p, &vals, .{ .os = .xp });
    try std.testing.expect(it.next() == null);
    it = iterate(&p, &vals, .{ .os = .w2000 });
    const rule = it.next().?;
    try std.testing.expectEqualStrings("HideFileExt", rule.action.reg.name);
    try std.testing.expect(it.next() == null);
}

test "options: stage 2 packs per family" {
    const T = struct {
        fn on(opt: Opt, os: Os) bool {
            return available(opt, .{ .os = os });
        }
        fn server(opt: Opt, os: Os) bool {
            return available(opt, .{ .os = os, .server = true });
        }
    };
    // 9x: Explorer and input basics only.
    for ([_]Os{ .win95, .win98, .win_me }) |os| {
        try std.testing.expect(T.on(.shortcut_suffix_off, os) and T.on(.mouse_accel_off, os) and T.on(.visual_effects, os));
        try std.testing.expect(!T.on(.user_script, os) and !T.on(.remote_desktop, os) and !T.on(.font_smoothing, os));
    }
    try std.testing.expect(T.on(.last_access_off, .nt4) and !T.on(.user_script, .nt4) and !T.on(.autologon, .nt4));
    try std.testing.expect(T.on(.font_smoothing, .w2000) and T.on(.user_script, .w2000) and !T.on(.desktop_icons, .w2000));
    try std.testing.expect(T.on(.firewall_off, .xp) and T.on(.security_center_off, .xp) and !T.server(.security_center_off, .w2003));
    try std.testing.expect(T.server(.server_nags_off, .w2003) and !T.on(.server_nags_off, .xp) and !T.server(.ie_esc_off, .w2003));
    try std.testing.expect(valueAvailable(.hibernation, 2, .{ .os = .xp }) and !valueAvailable(.hibernation, 1, .{ .os = .xp }));
    try std.testing.expect(T.on(.defender_off, .w7) and !T.on(.defender_off, .w10) and T.on(.classic_taskbar, .vista));
    try std.testing.expect(T.on(.boot_to_desktop, .w81) and !T.on(.boot_to_desktop, .w10) and T.on(.remove_apps, .w8));
    try std.testing.expect(!T.server(.remove_apps, .w10) and T.server(.ie_esc_off, .w10) and T.on(.classic_context_menu, .w11));
    try std.testing.expect(!T.on(.classic_context_menu, .w10) and !T.on(.all_tray_icons, .w11) and !T.on(.shortcut_suffix_off, .w11));
    try std.testing.expect(T.on(.user_script, .vista) and T.on(.power_profile, .w7) and T.on(.power_profile, .xp));
}

test "options: commands fit the specialize limits; set lines stay printable ASCII" {
    const autounattend = @import("autounattend.zig");
    for (rules) |rule| switch (rule.action) {
        .command => |c| {
            errdefer std.debug.print("too long ({d}): {s}\n", .{ c.len, c });
            try std.testing.expect(c.len <= autounattend.packed_limit);
        },
        .reg => |r| switch (r.data) {
            .sz, .binary => |text| for (text) |ch| try std.testing.expect(ch >= 0x20 and ch < 0x7f and ch != '|' and ch != '"'),
            else => {},
        },
        .native => {},
    };
    try std.testing.expect(user_script_reg.len <= 259 and user_script_cmd.len <= 259);
}
