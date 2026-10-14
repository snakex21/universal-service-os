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

pub const Group = enum { explorer, taskbar, system, updates, accounts };

/// Every option of the table. Options with a `legacy` field keep their
/// value in that existing Profile field (the tweaks of 2026-09-28); the
/// others in Profile.opts.
pub const Opt = enum {
    show_extensions,
    show_hidden,
    show_protected,
    launch_to_pc,
    end_task,
    no_autorun,
    no_tips,
    taskbar_search,
    taskbar_left,
    task_view_off,
    widgets_off,
    bing_search_off,
    uac_level,
    disable_uac,
    hibernation,
    no_hibernation,
    system_restore_off,
    numlock,
    windows_update,
    privacy,
    disable_wer,
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
    .{ .opt = .no_autorun, .group = .explorer, .legacy = true },
    .{ .opt = .no_tips, .group = .explorer },
    .{ .opt = .taskbar_search, .group = .taskbar, .values = &.{ "default", "hidden", "icon", "box" } },
    .{ .opt = .taskbar_left, .group = .taskbar },
    .{ .opt = .task_view_off, .group = .taskbar },
    .{ .opt = .widgets_off, .group = .taskbar },
    .{ .opt = .bing_search_off, .group = .taskbar },
    .{ .opt = .uac_level, .group = .system, .values = &.{ "default", "no_dim", "never" } },
    .{ .opt = .disable_uac, .group = .system, .legacy = true },
    .{ .opt = .hibernation, .group = .system, .values = &.{ "default", "no_fast_startup", "off" } },
    .{ .opt = .no_hibernation, .group = .system, .legacy = true },
    .{ .opt = .system_restore_off, .group = .system },
    .{ .opt = .numlock, .group = .system, .values = &.{ "default", "on", "off" } },
    .{ .opt = .windows_update, .group = .updates, .values = &.{ "default", "no_restart", "notify", "off" } },
    .{ .opt = .privacy, .group = .updates },
    .{ .opt = .disable_wer, .group = .updates, .legacy = true },
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

fn reg(root: Root, key: []const u8, name: []const u8, data: Data) Action {
    return .{ .reg = .{ .root = root, .key = key, .name = name, .data = data } };
}

fn dw(root: Root, key: []const u8, name: []const u8, value: u32) Action {
    return reg(root, key, name, .{ .dword = value });
}

const w9x_shell = set(&.{ .win98, .win_me });
const w9x = set(&.{ .win95, .win98, .win_me });

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
    // Accounts -----------------------------------------------------------
    // 6.x+: the Shell-Setup AutoLogon element (autounattend.zig). NT5: the
    // Winlogon values, written at setup end after Setup's own.
    .{ .opt = .autologon, .os = nt6, .action = .native },
    // NT 3.x: nt3.zig ";USOS-AUTOLOGON=1", usosnt3.exe writes the Winlogon values.
    .{ .opt = .autologon, .os = set(&.{.nt3}), .action = .native },
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
        .sz => |s| s,
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
            for (all) |os| some = some or valueAvailable(o.opt, @intCast(v), .{ .os = os });
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
    try std.testing.expect(available(.disable_wer, .{ .os = .vista }) and !available(.disable_wer, .{ .os = .xp }));
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
