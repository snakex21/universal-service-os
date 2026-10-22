//! Windows 6.x+ renderer (Vista, 7, 8, 8.1, 10, 11, Server 2008-2025): the
//! profile as autounattend.xml for one version and architecture.
//!
//! Disk selection always stays in Setup: no DiskConfiguration, no
//! ImageInstall/InstallTo, never WillWipeDisk (docs/design/
//! answer-file-generator.md section 5). The shape of the passes and
//! components follows Microsoft's unattend reference; the choice of the
//! common settings follows the catalogue of Christoph Schneegans'
//! unattend-generator (MIT, knowledge reuse only, no code or templates
//! copied; attribution in docs/answer-profiles.md).
const std = @import("std");
const Profile = @import("profile.zig").Profile;
const target = @import("target.zig");
const tables = @import("tables.zig");
const schema = @import("schema.zig");
const options = @import("options.zig");
const display_profile = @import("display_profile.zig");

pub const Arch = target.Arch;
pub const Family = target.Family;

pub const Input = struct {
    profile: *const Profile,
    family: Family,
    arch: Arch,
    /// Product key (the profile's for this system or one typed at start);
    /// empty: Setup asks (or selects the edition itself).
    key: []const u8 = "",
    /// The install image (1-based index) matching the profile's edition on
    /// the chosen media (editions.match); null: Setup shows its edition list.
    image_index: ?u16 = null,
};

const W = std.Io.Writer;

fn text(w: *W, value: []const u8) !void {
    for (value) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&apos;"),
        else => try w.writeByte(c),
    };
}

fn element(w: *W, depth: usize, name: []const u8, value: []const u8) !void {
    try indent(w, depth);
    try w.print("<{s}>", .{name});
    try text(w, value);
    try w.print("</{s}>\n", .{name});
}

fn indent(w: *W, depth: usize) !void {
    for (0..depth) |_| try w.writeAll("  ");
}

fn open(w: *W, depth: usize, name: []const u8) !void {
    try indent(w, depth);
    try w.print("<{s}>\n", .{name});
}

fn close(w: *W, depth: usize, name: []const u8) !void {
    try indent(w, depth);
    try w.print("</{s}>\n", .{name});
}

fn component(w: *W, name: []const u8, arch: Arch) !void {
    try w.print("    <component name=\"{s}\" processorArchitecture=\"{s}\" publicKeyToken=\"31bf3856ad364e35\" language=\"neutral\" versionScope=\"nonSxS\">\n", .{ name, @tagName(arch) });
}

fn endComponent(w: *W) !void {
    try w.writeAll("    </component>\n");
}

fn languageTag(entry: *const tables.Language, family: Family) []const u8 {
    if (family.legacyNt6()) if (entry.tag_legacy) |legacy| return legacy;
    return entry.tag;
}

fn international(w: *W, input: Input, winpe: bool) !void {
    const p = input.profile;
    const lang = p.languageEntry();
    const locale = p.localeEntry() orelse return;
    try component(w, if (winpe) "Microsoft-Windows-International-Core-WinPE" else "Microsoft-Windows-International-Core", input.arch);
    if (winpe) {
        if (lang) |l| {
            try open(w, 3, "SetupUILanguage");
            try element(w, 4, "UILanguage", languageTag(l, input.family));
            try close(w, 3, "SetupUILanguage");
        }
    }
    var buffer: [16]u8 = undefined;
    const kb = p.inputProfile().?;
    try element(w, 3, "InputLocale", try std.fmt.bufPrint(&buffer, "{x:0>4}:{x:0>8}", .{ kb.lcid, kb.klid }));
    try element(w, 3, "SystemLocale", languageTag(locale, input.family));
    if (lang) |l| try element(w, 3, "UILanguage", languageTag(l, input.family));
    try element(w, 3, "UserLocale", languageTag(locale, input.family));
    try endComponent(w);
}

fn runCommand(w: *W, depth: usize, element_name: []const u8, order: usize, path: []const u8) !void {
    try indent(w, depth);
    try w.print("<{s} wcm:action=\"add\">\n", .{element_name});
    var buffer: [8]u8 = undefined;
    try element(w, depth + 1, "Order", try std.fmt.bufPrint(&buffer, "{d}", .{order}));
    try element(w, depth + 1, "Path", path);
    try close(w, depth, element_name);
}

const lab_config = "reg.exe add \"HKLM\\SYSTEM\\Setup\\LabConfig\" /v {s} /t REG_DWORD /d 1 /f";

fn windows11(family: Family) bool {
    return family == .windows_11;
}

fn setupComponent(w: *W, input: Input) !void {
    const p = input.profile;
    try component(w, "Microsoft-Windows-Setup", input.arch);
    if (windows11(input.family) and (p.bypass_tpm or p.bypass_secure_boot or p.bypass_ram)) {
        try open(w, 3, "RunSynchronous");
        var order: usize = 1;
        var buffer: [160]u8 = undefined;
        const checks = [_]struct { on: bool, name: []const u8 }{
            .{ .on = p.bypass_tpm, .name = "BypassTPMCheck" },
            .{ .on = p.bypass_secure_boot, .name = "BypassSecureBootCheck" },
            .{ .on = p.bypass_ram, .name = "BypassRAMCheck" },
        };
        for (checks) |check| {
            if (!check.on) continue;
            try runCommand(w, 4, "RunSynchronousCommand", order, try std.fmt.bufPrint(&buffer, lab_config, .{check.name}));
            order += 1;
        }
        try close(w, 3, "RunSynchronous");
    }
    if (input.image_index) |index| {
        // Only the source image: no InstallTo, the disk page stays.
        try open(w, 3, "ImageInstall");
        try open(w, 4, "OSImage");
        try open(w, 5, "InstallFrom");
        try indent(w, 6);
        try w.writeAll("<MetaData wcm:action=\"add\">\n");
        try element(w, 7, "Key", "/IMAGE/INDEX");
        var number: [8]u8 = undefined;
        try element(w, 7, "Value", try std.fmt.bufPrint(&number, "{d}", .{index}));
        try close(w, 6, "MetaData");
        try close(w, 5, "InstallFrom");
        try close(w, 4, "OSImage");
        try close(w, 3, "ImageInstall");
    }
    try open(w, 3, "UserData");
    if (input.key.len > 0) {
        try open(w, 4, "ProductKey");
        var upper: [29]u8 = undefined;
        for (input.key[0..@min(input.key.len, 29)], 0..) |c, i| upper[i] = std.ascii.toUpper(c);
        try element(w, 5, "Key", upper[0..@min(input.key.len, 29)]);
        try element(w, 5, "WillShowUI", "OnError");
        try close(w, 4, "ProductKey");
    }
    try element(w, 4, "AcceptEula", "true");
    try element(w, 4, "FullName", p.user.slice());
    if (p.org.len > 0) try element(w, 4, "Organization", p.org.slice());
    try close(w, 3, "UserData");
    try endComponent(w);
}

/// The default user's hive while specialize runs (new accounts are
/// created from it in oobeSystem), as in Schneegans' generator.
const default_hive = "HKU\\USOSDefault";
const explorer_advanced = "reg.exe add \"" ++ default_hive ++ "\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced\" /v {s} /t REG_DWORD /d {d} /f";

/// Vista / 7 / 2008 / 2008 R2 without a firmware CSM (vista_csmwrap_target.sh)
/// install on the Standard VGA (XDDM) driver at 800x600, 32-bit Windows
/// 8 / 8.1 / 10 (win-x86-uefi-csmwrap, the same script) on Microsoft Basic
/// Display at 1024x768. The micro-Linux stages USOSRES.EXE + DISPLAY.TXT
/// into this folder of the Windows partition before Setup; these answers
/// register it for every new user (Default hive Run: it removes its own
/// value, no elevation needed) only when the file is there. The other paths
/// (UEFI with CSM, native UEFI, Win7 x64 UefiSeven without its opt-in flag)
/// never have the file, so the commands do nothing there. Server 2012 and
/// later have no 32-bit release (never on the x86 CSMWrap path).
/// docs/display-policy.md.
pub const display_helper = "%SystemDrive%\\USOS\\NT6\\USOSRES.EXE";
const display_guard = "cmd.exe /c if exist \"" ++ display_helper ++ "\" ";

fn displayHelper(family: Family, arch: Arch) bool {
    return switch (schema.Level.of(family)) {
        .vista, .windows_7 => true,
        .windows_8, .windows_8_1, .windows_10 => !family.server() and arch != .arm64,
        .windows_11 => false,
    };
}

/// The specialize commands of the profile for this version (Deployment
/// RunSynchronous, run as SYSTEM before OOBE). Each command is at most 259
/// characters (the schema's limit of Path).
pub const Commands = struct {
    items: [max_commands][]const u8 = undefined,
    storage: [max_commands][259]u8 = undefined,
    len: usize = 0,

    fn add(self: *Commands, comptime format: []const u8, args: anytype) !void {
        if (self.len == max_commands) return error.TooManyCommands;
        self.items[self.len] = try std.fmt.bufPrint(&self.storage[self.len], format, args);
        self.len += 1;
    }

    fn addText(self: *Commands, value: []const u8) !void {
        return self.add("{s}", .{value});
    }

    pub fn slice(self: *const Commands) []const []const u8 {
        return self.items[0..self.len];
    }
};

pub const max_commands = 96;

/// A packed command stays short enough for usos-run-hidden.exe's prefix
/// (tools/windows_hidden_commands.h: 20 characters within 259).
pub const packed_limit = 239;

/// Registry operations of the typed options (options.zig) as reg.exe
/// commands, several per command ("cmd.exe /c reg add ... & reg add ...")
/// while they fit: fewer RunSynchronousCommand elements keep the answer well
/// under max_size with every option on. One operation alone is a plain
/// "reg.exe ..." command.
const Packer = struct {
    out: *Commands,
    text: [packed_limit]u8 = undefined,
    len: usize = 0,
    ops: usize = 0,

    fn op(self: *Packer, comptime format: []const u8, args: anytype) !void {
        var buffer: [packed_limit]u8 = undefined;
        const one = try std.fmt.bufPrint(&buffer, format, args);
        const prefix = "cmd.exe /c ";
        if (self.ops > 0 and prefix.len + self.len + 3 + one.len > packed_limit) try self.flush();
        if (self.ops > 0) {
            @memcpy(self.text[self.len .. self.len + 3], " & ");
            self.len += 3;
        }
        @memcpy(self.text[self.len .. self.len + one.len], one);
        self.len += one.len;
        self.ops += 1;
    }

    fn flush(self: *Packer) !void {
        if (self.ops == 1) {
            // "reg add ..." -> "reg.exe add ...".
            try self.out.add("reg.exe{s}", .{self.text[3..self.len]});
        } else if (self.ops > 1) try self.out.add("cmd.exe /c {s}", .{self.text[0..self.len]});
        self.len = 0;
        self.ops = 0;
    }
};

fn regOp(packer: *Packer, r: options.Reg, p: *const Profile) !void {
    const root: []const u8 = switch (r.root) {
        .hklm => "HKLM",
        .user => default_hive,
        .default => "HKU\\.DEFAULT",
    };
    switch (r.data) {
        .del => try packer.op("reg delete \"{s}\\{s}\" /v {s} /f", .{ root, r.key, r.name }),
        .dword => |v| try packer.op("reg add \"{s}\\{s}\" /v {s} /t REG_DWORD /d {d} /f", .{ root, r.key, r.name, v }),
        .binary => |hex| {
            // "90,12,03,80" -> /d 90120380.
            var bytes: [64]u8 = undefined;
            var n: usize = 0;
            for (hex) |c| if (c != ',') {
                bytes[n] = c;
                n += 1;
            };
            try packer.op("reg add \"{s}\\{s}\" /v {s} /t REG_BINARY /d {s} /f", .{ root, r.key, r.name, bytes[0..n] });
        },
        else => {
            var number: [16]u8 = undefined;
            const data = options.dataText(r.data, p, &number);
            const quote: []const u8 = if (std.mem.indexOfScalar(u8, data, ' ') != null) "\"" else "";
            try packer.op("reg add \"{s}\\{s}\" /v {s} /t REG_SZ /d {s}{s}{s} /f", .{ root, r.key, r.name, quote, data, quote });
        },
    }
}

/// The typed options' machine-wide operations (HKLM, HKU\.DEFAULT and
/// commands) or, with `user`, the Default User hive ones.
fn optionCommands(p: *const Profile, family: Family, user: bool, out: *Commands) !void {
    var values: [options.count]u8 = undefined;
    var it = options.iterate(p, &values, options.osOfFamily(family));
    var packer: Packer = .{ .out = out };
    while (it.next()) |rule| switch (rule.action) {
        .reg => |r| if ((r.root == .user) == user) try regOp(&packer, r, p),
        .command => |c| if (!user) {
            try packer.flush();
            try out.addText(c);
        },
        .native => {},
    };
    try packer.flush();
}

fn hasUserOptions(p: *const Profile, family: Family) bool {
    var values: [options.count]u8 = undefined;
    var it = options.iterate(p, &values, options.osOfFamily(family));
    while (it.next()) |rule| switch (rule.action) {
        .reg => |r| if (r.root == .user) return true,
        else => {},
    };
    return false;
}

pub fn specializeCommands(p: *const Profile, family: Family, arch: Arch, out: *Commands) !void {
    out.len = 0;
    if (windows11(family) and p.no_network_oobe) try out.add("reg.exe add \"HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE\" /v BypassNRO /t REG_DWORD /d 1 /f", .{});
    const on = struct {
        fn f(profile: *const Profile, tweak: schema.Tweak, fam: Family) bool {
            return schema.tweakOn(profile, tweak, fam);
        }
    }.f;
    // AutoRun and AutoPlay off on every drive type (KB967715: 0xFF).
    if (on(p, .no_autorun, family)) try out.add("reg.exe add \"HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer\" /v NoDriveTypeAutoRun /t REG_DWORD /d 255 /f", .{});
    // Group Policy "Turn off Windows Sidebar" (Vista) / "Turn off desktop gadgets" (7).
    if (on(p, .no_sidebar, family)) try out.add("reg.exe add \"HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\Windows\\Sidebar\" /v TurnOffSidebar /t REG_DWORD /d 1 /f", .{});
    if (on(p, .disable_uac, family) and family.client() == .vista) try out.add("reg.exe add \"HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System\" /v EnableLUA /t REG_DWORD /d 0 /f", .{});
    if (on(p, .no_hibernation, family)) try out.add("powercfg.exe -h off", .{});
    // Windows 7: the theme every new user gets at first logon (themeui's
    // Active Setup reads InstallTheme). Themes/CustomDefaultThemeFile is
    // not used: VirtualBox test 2026-09-28, Windows 7 SP1 without Aero
    // ignored it and gave the user basic.theme; InstallTheme gave Classic.
    const theme: ?[]const u8 = if (on(p, .theme_classic, family)) "classic" else if (on(p, .theme_basic, family)) "basic" else null;
    if (theme) |name| try out.add("reg.exe add \"HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Themes\" /v InstallTheme /t REG_EXPAND_SZ /d \"%WINDIR%\\Resources\\Ease of Access Themes\\{s}.theme\" /f", .{name});
    if (on(p, .skip_games, family)) {
        // The Games feature (InboxGames): pkgmgr on Vista, DISM on 7.
        if (family.client() == .vista) {
            try out.add("cmd.exe /c start /w pkgmgr.exe /uu:InboxGames /quiet /norestart", .{});
        } else try out.add("dism.exe /Online /NoRestart /Disable-Feature /FeatureName:InboxGames", .{});
    }
    // Typed options (options.zig): HKLM, HKU\.DEFAULT, commands.
    try optionCommands(p, family, false, out);
    // The staged folder takes the system drive's permissions (the
    // micro-Linux made it before Setup).
    if (displayHelper(family, arch)) try out.add(display_guard ++ "icacls.exe \"%SystemDrive%\\USOS\" /reset /t /c /q", .{});
    const hive = displayHelper(family, arch) or on(p, .show_extensions, family) or on(p, .show_hidden, family) or on(p, .no_welcome_center, family) or hasUserOptions(p, family);
    if (hive) {
        try out.add("reg.exe load \"" ++ default_hive ++ "\" \"C:\\Users\\Default\\NTUSER.DAT\"", .{});
        if (on(p, .show_extensions, family)) try out.add(explorer_advanced, .{ "HideFileExt", 0 });
        if (on(p, .show_hidden, family)) try out.add(explorer_advanced, .{ "Hidden", 1 });
        if (on(p, .no_welcome_center, family)) try out.add("reg.exe delete \"" ++ default_hive ++ "\\Software\\Microsoft\\Windows\\CurrentVersion\\Run\" /v WindowsWelcomeCenter /f", .{});
        try optionCommands(p, family, true, out);
        if (displayHelper(family, arch)) try out.add(display_guard ++ "reg.exe add \"" ++ default_hive ++ "\\Software\\Microsoft\\Windows\\CurrentVersion\\Run\" /v USOSDisplay /t REG_SZ /d \"" ++ display_helper ++ "\" /f", .{});
        try out.add("reg.exe unload \"" ++ default_hive ++ "\"", .{});
    }
}

fn specialize(w: *W, input: Input) !void {
    const p = input.profile;
    try w.writeAll("  <settings pass=\"specialize\">\n");
    try component(w, "Microsoft-Windows-Shell-Setup", input.arch);
    try element(w, 3, "ComputerName", if (p.computer.len > 0) p.computer.slice() else "*");
    // An explicit resolution (tweak display); auto leaves the choice to
    // Windows (GOP / WDDM driver) or, Vista / 7 / 8.x / 10 on CSMWrap, to USOSRES.
    if (schema.tweakOn(p, .display, input.family)) {
        const tag = @tagName(p.display);
        const x = std.mem.indexOfScalar(u8, tag, 'x').?;
        try open(w, 3, "Display");
        try element(w, 4, "ColorDepth", if (p.display_bpp == .@"16") "16" else "32");
        try element(w, 4, "HorizontalResolution", tag[0..x]);
        try element(w, 4, "VerticalResolution", tag[x + 1 ..]);
        try close(w, 3, "Display");
    }
    try element(w, 3, "RegisteredOwner", p.user.slice());
    if (p.org.len > 0) try element(w, 3, "RegisteredOrganization", p.org.slice());
    if (p.timeZone()) |zone| {
        const name = if (input.family.legacyNt6()) zone.windows_legacy orelse zone.windows else zone.windows;
        try element(w, 3, "TimeZone", name);
    }
    // Windows 7 only (removed in 8; not in Vista's or Server's shell):
    // no "Windows Live" link in Getting Started.
    if (input.family == .windows_7) try element(w, 3, "ShowWindowsLive", "false");
    try endComponent(w);
    if (p.disable_wer) {
        try component(w, "Microsoft-Windows-ErrorReportingCore", input.arch);
        try element(w, 3, "DisableWER", "1");
        try endComponent(w);
    }
    // Windows 7 / 2008 R2: LUA-Settings. Vista / 2008 get the same registry
    // value as a command (below): Vista SP2 Setup refused EnableLUA=false in
    // specialize ("value is in invalid format", VirtualBox test 2026-09-28).
    if (schema.tweakOn(p, .disable_uac, input.family) and input.family.client() == .windows_7) {
        try component(w, "Microsoft-Windows-LUA-Settings", input.arch);
        try element(w, 3, "EnableLUA", "false");
        try endComponent(w);
    }
    // Server: no Initial Configuration Tasks (2008 / 2008 R2) and no Server
    // Manager (2008 R2 and later) at the first logon.
    if (input.family.server()) {
        const level = @intFromEnum(schema.Level.of(input.family));
        if (level <= @intFromEnum(schema.Level.windows_7)) {
            try component(w, "Microsoft-Windows-OutOfBoxExperience", input.arch);
            try element(w, 3, "DoNotOpenInitialConfigurationTasksAtLogon", "true");
            try endComponent(w);
        }
        if (level >= @intFromEnum(schema.Level.windows_7)) {
            try component(w, "Microsoft-Windows-ServerManager-SvrMgrNc", input.arch);
            try element(w, 3, "DoNotOpenServerManagerAtLogon", "true");
            try endComponent(w);
        }
    }
    // Workgroup (UnattendedJoin; without it Windows uses WORKGROUP).
    if (p.workgroup.len > 0) {
        try component(w, "Microsoft-Windows-UnattendedJoin", input.arch);
        try open(w, 3, "Identification");
        try element(w, 4, "JoinWorkgroup", p.workgroup.slice());
        try close(w, 3, "Identification");
        try endComponent(w);
    }
    var commands: Commands = .{};
    try specializeCommands(p, input.family, input.arch, &commands);
    if (commands.len > 0) {
        try component(w, "Microsoft-Windows-Deployment", input.arch);
        try open(w, 3, "RunSynchronous");
        for (commands.slice(), 1..) |command, order| try runCommand(w, 4, "RunSynchronousCommand", order, command);
        try close(w, 3, "RunSynchronous");
        try endComponent(w);
    }
    try w.writeAll("  </settings>\n");
}

fn account(w: *W, name: []const u8, password: []const u8) !void {
    try indent(w, 5);
    try w.writeAll("<LocalAccount wcm:action=\"add\">\n");
    try open(w, 6, "Password");
    try element(w, 7, "Value", password);
    try element(w, 7, "PlainText", "true");
    try close(w, 6, "Password");
    try element(w, 6, "DisplayName", name);
    try element(w, 6, "Group", "Administrators");
    try element(w, 6, "Name", name);
    try close(w, 5, "LocalAccount");
}

fn oobe(w: *W, input: Input) !void {
    const p = input.profile;
    const family = input.family;
    try w.writeAll("  <settings pass=\"oobeSystem\">\n");
    try international(w, input, false);
    try component(w, "Microsoft-Windows-Shell-Setup", input.arch);
    // Automatic logon of the first user at every start (LogonCount counts
    // down per logon: practically permanent).
    if (p.opt(.autologon) == 1) {
        try open(w, 3, "AutoLogon");
        try element(w, 4, "Enabled", "true");
        try element(w, 4, "LogonCount", "9999999");
        try element(w, 4, "Username", p.user.slice());
        try open(w, 4, "Password");
        try element(w, 5, "Value", p.password.slice());
        try element(w, 5, "PlainText", "true");
        try close(w, 4, "Password");
        try close(w, 3, "AutoLogon");
    }
    // The user script hook (options.user_script): at the first sign-in.
    if (p.opt(.user_script) == 1) {
        try open(w, 3, "FirstLogonCommands");
        const scripts = [_][]const u8{ options.user_script_reg, options.user_script_cmd };
        const descriptions = [_][]const u8{ "USOS user script (.reg)", "USOS user script (.cmd)" };
        for (scripts, descriptions, 1..) |command, description, order| {
            try indent(w, 4);
            try w.writeAll("<SynchronousCommand wcm:action=\"add\">\n");
            var number: [8]u8 = undefined;
            try element(w, 5, "Order", try std.fmt.bufPrint(&number, "{d}", .{order}));
            try element(w, 5, "CommandLine", command);
            try element(w, 5, "Description", description);
            try close(w, 4, "SynchronousCommand");
        }
        try close(w, 3, "FirstLogonCommands");
    }
    try open(w, 3, "OOBE");
    // Per version (Microsoft unattend reference, schema.zig): Vista has
    // HideEULAPage, NetworkLocation and ProtectYourPC only; 7 adds
    // HideWirelessSetupInOOBE; 8 adds the OEM registration and online
    // account pages. An element unknown to the version makes Setup stop
    // with "cannot parse or process the unattend answer file".
    try element(w, 4, "HideEULAPage", "true");
    if (family.atLeast8()) try element(w, 4, "HideOEMRegistrationScreen", "true");
    if (family.atLeast8() and p.local_account) try element(w, 4, "HideOnlineAccountScreens", "true");
    // Without it an offline Windows 10 OOBE stops on "Let's connect you to a
    // network" (VirtualBox test 2026-09-26); the page is only the Wi-Fi setup.
    if (family.client() != .vista) try element(w, 4, "HideWirelessSetupInOOBE", "true");
    if (family.legacyNt6()) try element(w, 4, "NetworkLocation", p.network_location.value());
    try element(w, 4, "ProtectYourPC", p.protect_pc.value());
    try close(w, 3, "OOBE");
    try open(w, 3, "UserAccounts");
    if (family.server() and p.password.len > 0) {
        try open(w, 4, "AdministratorPassword");
        try element(w, 5, "Value", p.password.slice());
        try element(w, 5, "PlainText", "true");
        try close(w, 4, "AdministratorPassword");
    }
    try open(w, 4, "LocalAccounts");
    try account(w, p.user.slice(), p.password.slice());
    if (p.user2.len > 0) try account(w, p.user2.slice(), p.password.slice());
    try close(w, 4, "LocalAccounts");
    try close(w, 3, "UserAccounts");
    try endComponent(w);
    try w.writeAll("  </settings>\n");
}

/// autounattend.xml for `input` (LF line ends, UTF-8, ASCII values).
pub fn render(input: Input, buffer: []u8) ![]const u8 {
    std.debug.assert(!input.family.nt5());
    var w: W = .fixed(buffer);
    try w.writeAll("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n");
    try w.print("<!-- USOS answer profile rendered for {s} ({s}); the target disk is chosen in Setup. docs/answer-profiles.md -->\n", .{ target.systemId(input.family), @tagName(input.arch) });
    // The profile's display request for the CSMWrap staging (DISPLAY.TXT,
    // tools/display_profile.sh usos_display_from_xml); none: default auto.
    if (displayHelper(input.family, input.arch) and display_profile.requested(input.profile))
        try w.print("<!-- USOS-DISPLAY={s}x{s} -->\n", .{ @tagName(input.profile.display), @tagName(input.profile.display_bpp) });
    try w.writeAll("<unattend xmlns=\"urn:schemas-microsoft-com:unattend\" xmlns:wcm=\"http://schemas.microsoft.com/WMIConfig/2002/State\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\n");
    try w.writeAll("  <settings pass=\"windowsPE\">\n");
    try international(&w, input, true);
    try setupComponent(&w, input);
    try w.writeAll("  </settings>\n");
    try specialize(&w, input);
    try oobe(&w, input);
    try w.writeAll("</unattend>\n");
    return w.buffered();
}

/// 64 KiB (16 KiB until stage 2 of the options, 2026-10-14): every option
/// on stays far below it (test below); the consumers take more (DATA answers
/// up to 1 MiB; usos-run-hidden.exe --wrap allocates the file size + 64 KiB).
pub const max_size = 64 * 1024;

test "autounattend: manual disk, escaped values, arch on every component" {
    var p = Profile{};
    try p.name.set("A");
    try p.user.set("Tester");
    try p.org.set("R'n'D Team");
    var buffer: [max_size]u8 = undefined;
    const xml = try render(.{ .profile = &p, .family = .windows_10, .arch = .x86 }, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, xml, "DiskConfiguration") == null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "WillWipeDisk") == null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "InstallTo") == null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "ImageInstall") == null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "processorArchitecture=\"amd64\"") == null);
    var second: [max_size]u8 = undefined;
    const edition = try render(.{ .profile = &p, .family = .windows_7, .arch = .x86, .image_index = 3 }, &second);
    try std.testing.expect(std.mem.indexOf(u8, edition, "<Key>/IMAGE/INDEX</Key>") != null);
    try std.testing.expect(std.mem.indexOf(u8, edition, "<Value>3</Value>") != null);
    try std.testing.expect(std.mem.indexOf(u8, edition, "InstallTo") == null);
    try @import("xml_check.zig").wellFormed(edition);
    try std.testing.expect(std.mem.indexOf(u8, xml, "R&apos;n&apos;D Team") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<ProductKey>") == null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<ComputerName>*</ComputerName>") != null);
    try @import("xml_check.zig").wellFormed(xml);
}

test "autounattend: Windows 11 bypasses only when chosen, only on 11" {
    var p = Profile{};
    try p.name.set("A");
    try p.user.set("Tester");
    p.bypass_tpm = true;
    p.bypass_ram = true;
    p.no_network_oobe = true;
    var buffer: [max_size]u8 = undefined;
    const eleven = try render(.{ .profile = &p, .family = .windows_11, .arch = .amd64 }, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, eleven, "BypassTPMCheck") != null);
    try std.testing.expect(std.mem.indexOf(u8, eleven, "BypassRAMCheck") != null);
    try std.testing.expect(std.mem.indexOf(u8, eleven, "BypassSecureBootCheck") == null);
    try std.testing.expect(std.mem.indexOf(u8, eleven, "BypassNRO") != null);
    const ten = try render(.{ .profile = &p, .family = .windows_10, .arch = .amd64 }, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, ten, "LabConfig") == null);
    try std.testing.expect(std.mem.indexOf(u8, ten, "BypassNRO") == null);
}

fn allTweaks() !Profile {
    var p = Profile{};
    try p.name.set("A");
    try p.user.set("Tester");
    for (@import("profile.zig").tweak_fields) |field| p.flag(field).?.* = true;
    p.theme = .classic;
    p.display = .@"1024x768";
    return p;
}

test "autounattend: tweaks per version, nothing for versions without them" {
    const p = try allTweaks();
    var buffer: [max_size]u8 = undefined;
    const seven = try render(.{ .profile = &p, .family = .windows_7, .arch = .amd64 }, &buffer);
    for ([_][]const u8{ "<EnableLUA>false</EnableLUA>", "NoDriveTypeAutoRun /t REG_DWORD /d 255", "TurnOffSidebar", "powercfg.exe -h off", "/FeatureName:InboxGames", "/v HideFileExt /t REG_DWORD /d 0", "/v Hidden /t REG_DWORD /d 1", "reg.exe unload", "Ease of Access Themes\\classic.theme" }) |k| {
        errdefer std.debug.print("missing on 7: {s}\n", .{k});
        try std.testing.expect(std.mem.indexOf(u8, seven, k) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, seven, "WindowsWelcomeCenter") == null);
    try @import("xml_check.zig").wellFormed(seven);
    const vista = try render(.{ .profile = &p, .family = .vista, .arch = .x86 }, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, vista, "pkgmgr.exe /uu:InboxGames") != null);
    try std.testing.expect(std.mem.indexOf(u8, vista, "<EnableLUA>") == null);
    try std.testing.expect(std.mem.indexOf(u8, vista, "/v EnableLUA /t REG_DWORD /d 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, vista, "WindowsWelcomeCenter") != null);
    try std.testing.expect(std.mem.indexOf(u8, vista, "Themes") == null);
    const ten = try render(.{ .profile = &p, .family = .windows_10, .arch = .amd64 }, &buffer);
    for ([_][]const u8{ "EnableLUA", "TurnOffSidebar", "powercfg", "InboxGames", "Themes", "WindowsWelcomeCenter" }) |k| {
        errdefer std.debug.print("leaked to 10: {s}\n", .{k});
        try std.testing.expect(std.mem.indexOf(u8, ten, k) == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, ten, "HideFileExt") != null and std.mem.indexOf(u8, ten, "NoDriveTypeAutoRun") != null);
    const r2 = try render(.{ .profile = &p, .family = .server_2008_r2, .arch = .amd64 }, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, r2, "<EnableLUA>false</EnableLUA>") != null);
    for ([_][]const u8{ "TurnOffSidebar", "powercfg", "InboxGames", "Themes" }) |k| try std.testing.expect(std.mem.indexOf(u8, r2, k) == null);
    var commands: Commands = .{};
    try specializeCommands(&p, .windows_7, .x86, &commands);
    for (commands.slice()) |command| try std.testing.expect(command.len <= 259);
}

test "autounattend: display helper on Vista / 7 / 8 / 8.1 / 10, explicit resolution on every 6.x+" {
    var p = Profile{};
    try p.name.set("A");
    try p.user.set("Tester");
    var buffer: [max_size]u8 = undefined;
    const registration = "reg.exe add &quot;HKU\\USOSDefault\\Software\\Microsoft\\Windows\\CurrentVersion\\Run&quot; /v USOSDisplay /t REG_SZ /d &quot;%SystemDrive%\\USOS\\NT6\\USOSRES.EXE&quot; /f";
    // amd64 too: an x86 CSMWrap start may get an amd64-rendered answer,
    // retargeted in the WinPE (windows_installto.h usos_it_arch).
    for ([_]Family{ .vista, .windows_7, .server_2008, .server_2008_r2, .windows_8, .windows_8_1, .windows_10 }) |family| for ([_]Arch{ .x86, .amd64 }) |arch| {
        const xml = try render(.{ .profile = &p, .family = family, .arch = arch }, &buffer);
        errdefer std.debug.print("family {s}\n", .{@tagName(family)});
        try std.testing.expect(std.mem.indexOf(u8, xml, "cmd.exe /c if exist &quot;%SystemDrive%\\USOS\\NT6\\USOSRES.EXE&quot; " ++ registration) != null);
        try std.testing.expect(std.mem.indexOf(u8, xml, "icacls.exe &quot;%SystemDrive%\\USOS&quot; /reset /t /c /q") != null);
        // Default: no request comment (the staging uses auto), no <Display>.
        try std.testing.expect(std.mem.indexOf(u8, xml, "USOS-DISPLAY=") == null);
        try std.testing.expect(std.mem.indexOf(u8, xml, "<Display>") == null);
        try schema.check(xml, family, null);
    };
    // No 32-bit release (11, Server 2012+) or never CSMWrap (arm64): nothing.
    for ([_]Family{ .windows_10, .windows_11 }) |family| {
        const xml = try render(.{ .profile = &p, .family = family, .arch = .arm64 }, &buffer);
        try std.testing.expect(std.mem.indexOf(u8, xml, "USOSRES") == null);
    }
    for ([_]Family{ .windows_11, .server_2012, .server_2012_r2, .server_2016, .server_2019, .server_2022, .server_2025 }) |family| {
        const xml = try render(.{ .profile = &p, .family = family, .arch = .amd64 }, &buffer);
        try std.testing.expect(std.mem.indexOf(u8, xml, "USOSRES") == null);
        try std.testing.expect(std.mem.indexOf(u8, xml, "<Display>") == null);
    }
    p.display = .@"1920x1080";
    for ([_]Family{ .vista, .windows_7, .windows_10, .windows_11 }) |family| {
        const xml = try render(.{ .profile = &p, .family = family, .arch = .x86 }, &buffer);
        try std.testing.expect(std.mem.indexOf(u8, xml, "<Display>\n        <ColorDepth>32</ColorDepth>\n        <HorizontalResolution>1920</HorizontalResolution>\n        <VerticalResolution>1080</VerticalResolution>\n      </Display>") != null);
        try std.testing.expectEqual(displayHelper(family, .x86), std.mem.indexOf(u8, xml, "<!-- USOS-DISPLAY=1920x1080xauto -->\n<unattend") != null);
        try @import("xml_check.zig").wellFormed(xml);
        try schema.check(xml, family, null);
    }
    // An explicit auto: the request comment only (USOSRES picks the mode).
    p.display = .auto;
    p.display_explicit = true;
    const vista = try render(.{ .profile = &p, .family = .vista, .arch = .amd64 }, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, vista, "<!-- USOS-DISPLAY=autoxauto -->") != null);
    try std.testing.expect(std.mem.indexOf(u8, vista, "<Display>") == null);
}

test "autounattend: Vista and 7 OOBE answers per version" {
    var p = Profile{};
    try p.name.set("A");
    try p.user.set("Tester");
    p.network_location = .home;
    p.protect_pc = .recommended;
    p.disable_wer = true;
    var buffer: [max_size]u8 = undefined;
    const seven = try render(.{ .profile = &p, .family = .windows_7, .arch = .amd64 }, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, seven, "<NetworkLocation>Home</NetworkLocation>") != null);
    try std.testing.expect(std.mem.indexOf(u8, seven, "<ProtectYourPC>1</ProtectYourPC>") != null);
    try std.testing.expect(std.mem.indexOf(u8, seven, "<ShowWindowsLive>false</ShowWindowsLive>") != null);
    try std.testing.expect(std.mem.indexOf(u8, seven, "<DisableWER>1</DisableWER>") != null);
    try std.testing.expect(std.mem.indexOf(u8, seven, "HideOEMRegistrationScreen") == null);
    try std.testing.expect(std.mem.indexOf(u8, seven, "<HideWirelessSetupInOOBE>") != null);
    const vista = try render(.{ .profile = &p, .family = .vista, .arch = .x86 }, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, vista, "ShowWindowsLive") == null);
    try std.testing.expect(std.mem.indexOf(u8, vista, "HideWirelessSetupInOOBE") == null);
    try std.testing.expect(std.mem.indexOf(u8, vista, "<NetworkLocation>Home</NetworkLocation>") != null);
    const r2 = try render(.{ .profile = &p, .family = .server_2008_r2, .arch = .amd64 }, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, r2, "ShowWindowsLive") == null);
    const ten = try render(.{ .profile = &p, .family = .windows_10, .arch = .amd64 }, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, ten, "NetworkLocation") == null);
    try std.testing.expect(std.mem.indexOf(u8, ten, "<HideOEMRegistrationScreen>") != null);
}

test "autounattend: Server Manager and Initial Configuration Tasks stay closed at logon" {
    var p = Profile{};
    try p.name.set("A");
    try p.user.set("Tester");
    try p.password.set("Usos-2026!");
    var buffer: [max_size]u8 = undefined;
    const r2 = try render(.{ .profile = &p, .family = .server_2008_r2, .arch = .amd64 }, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, r2, "<DoNotOpenInitialConfigurationTasksAtLogon>true</DoNotOpenInitialConfigurationTasksAtLogon>") != null);
    try std.testing.expect(std.mem.indexOf(u8, r2, "<DoNotOpenServerManagerAtLogon>true</DoNotOpenServerManagerAtLogon>") != null);
    try std.testing.expect(std.mem.indexOf(u8, r2, "<AdministratorPassword>") != null);
    try schema.check(r2, .server_2008_r2, null);
    const r12 = try render(.{ .profile = &p, .family = .server_2012_r2, .arch = .amd64 }, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, r12, "InitialConfigurationTasks") == null);
    try std.testing.expect(std.mem.indexOf(u8, r12, "<DoNotOpenServerManagerAtLogon>true</DoNotOpenServerManagerAtLogon>") != null);
    try schema.check(r12, .server_2012_r2, null);
    const s2008 = try render(.{ .profile = &p, .family = .server_2008, .arch = .amd64 }, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, s2008, "DoNotOpenServerManagerAtLogon") == null);
    try std.testing.expect(std.mem.indexOf(u8, s2008, "DoNotOpenInitialConfigurationTasksAtLogon") != null);
    const eight = try render(.{ .profile = &p, .family = .windows_8_1, .arch = .amd64 }, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, eight, "ServerManager") == null and std.mem.indexOf(u8, eight, "OutOfBoxExperience") == null);
}

/// Every typed option at its last value, every tweak, workgroup and a
/// long password: the largest answer a profile can produce.
pub fn everythingOn() !Profile {
    var p = try allTweaks();
    try p.user2.set("Drugi-Uzytkownik-20c");
    try p.org.set("USOS Laboratory Organization Name For Size Tests 0123456789ABCD");
    try p.password.set("P4ssw0rd-P4ssw0rd-P4ssw0rd-P4ssw0rd-P4ssw0rd-P4ssw0rd-P4ssw0rd!!");
    try p.workgroup.set("LABORATORY-0123");
    p.disable_wer = true;
    p.bypass_tpm = true;
    p.bypass_secure_boot = true;
    p.bypass_ram = true;
    p.no_network_oobe = true;
    p.timezone = @intCast(tables.timeZoneIndex("Europe/Warsaw").?);
    p.language = @intCast(tables.languageIndex("pl-PL").?);
    for (options.table) |o| {
        if (!o.legacy) p.opts[@intFromEnum(o.opt)] = @intCast(o.values.len - 1);
    }
    return p;
}

test "autounattend: every option on stays within the limits on every version" {
    const p = try everythingOn();
    var buffer: [max_size]u8 = undefined;
    inline for (@typeInfo(Family).@"enum".fields) |f| {
        const family: Family = @enumFromInt(f.value);
        if (comptime family.nt5()) continue;
        for ([_]Arch{ .x86, .amd64 }) |arch| {
            const xml = try render(.{ .profile = &p, .family = family, .arch = arch, .key = "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE", .image_index = 2 }, &buffer);
            // Headroom (1.5 KiB) for later options; the hidden-runner
            // prefixes go into a copy without this limit.
            errdefer std.debug.print("{s}: {d} bytes\n", .{ f.name, xml.len });
            try std.testing.expect(xml.len <= max_size - 1536);
            try @import("xml_check.zig").wellFormed(xml);
            try schema.check(xml, family, null);
        }
        var commands: Commands = .{};
        try specializeCommands(&p, family, .amd64, &commands);
        for (commands.slice()) |command| {
            try std.testing.expect(command.len <= 259);
            if (std.mem.startsWith(u8, command, "cmd.exe /c reg")) try std.testing.expect(command.len <= packed_limit);
        }
    }
}

test "autounattend: typed options render only when set (byte identity)" {
    var p = try allTweaks();
    var a: [max_size]u8 = undefined;
    var b: [max_size]u8 = undefined;
    const before = try render(.{ .profile = &p, .family = .windows_11, .arch = .amd64 }, &a);
    p.opts = @splat(0);
    const after = try render(.{ .profile = &p, .family = .windows_11, .arch = .amd64 }, &b);
    try std.testing.expectEqualStrings(before, after);
    p.opts[@intFromEnum(options.Opt.autologon)] = 1;
    p.opts[@intFromEnum(options.Opt.taskbar_left)] = 1;
    p.opts[@intFromEnum(options.Opt.widgets_off)] = 1;
    p.opts[@intFromEnum(options.Opt.uac_level)] = 1;
    const eleven = try render(.{ .profile = &p, .family = .windows_11, .arch = .amd64 }, &b);
    try std.testing.expect(std.mem.indexOf(u8, eleven, "<LogonCount>9999999</LogonCount>") != null);
    try std.testing.expect(std.mem.indexOf(u8, eleven, "/v TaskbarAl /t REG_DWORD /d 0 /f") != null);
    try std.testing.expect(std.mem.indexOf(u8, eleven, "cmd.exe /c reg add &quot;HKLM\\SOFTWARE\\Policies\\Microsoft\\Dsh&quot; /v AllowNewsAndInterests /t REG_DWORD /d 0 /f &amp; reg add &quot;HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System&quot; /v ConsentPromptBehaviorAdmin /t REG_DWORD /d 5 /f</Path>") != null);
    // 10 has no left taskbar; Server 2025 no widgets.
    const ten = try render(.{ .profile = &p, .family = .windows_10, .arch = .amd64 }, &b);
    try std.testing.expect(std.mem.indexOf(u8, ten, "TaskbarAl") == null);
    const server = try render(.{ .profile = &p, .family = .server_2025, .arch = .amd64 }, &b);
    try std.testing.expect(std.mem.indexOf(u8, server, "AllowNewsAndInterests") == null);
}
