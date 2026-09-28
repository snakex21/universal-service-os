//! Linux renderers of the answer profile (docs/design/linux-iso-boot.md
//! section 7, docs/answer-profiles.md "Linux answer files"): the same
//! `usos-profile` as the Windows renderers, written as
//!
//!   autoinstall  Ubuntu subiquity `autoinstall.yaml` (top-level
//!                `autoinstall:` key, version 1)
//!   preseed      Debian d-i `preseed.cfg` (initrd preseeding)
//!   kickstart    Fedora anaconda `ks.cfg`
//!
//! Disk selection always stays in the installer: storage is an
//! interactive section, no partman*/grub-installer keys, no
//! ignoredisk/clearpart/autopart/part/zerombr/bootloader commands. The
//! password is written only as a SHA-512 crypt (`$6$`, sha512crypt.zig);
//! the salt is a parameter (random at start, fixed in the goldens).
//! Whatever the profile cannot answer is left to the installer and
//! reported in `Result.notes` for the summary.
//!
//! Fixed buffers, no allocator.
const std = @import("std");
const Profile = @import("profile.zig").Profile;
const tables = @import("tables.zig");
const sha512crypt = @import("sha512crypt.zig");

pub const max_size = 4096;

pub const Format = enum {
    autoinstall,
    preseed,
    kickstart,

    pub fn fileName(self: Format) []const u8 {
        return switch (self) {
            .autoinstall => "autoinstall.yaml",
            .preseed => "preseed.cfg",
            .kickstart => "ks.cfg",
        };
    }

    /// Path inside the per-boot cpio (docs/answer-profiles.md).
    pub fn cpioPath(self: Format) []const u8 {
        return switch (self) {
            .autoinstall => "usos/answer/autoinstall.yaml",
            .preseed => "preseed.cfg",
            .kickstart => "usos/answer/ks.cfg",
        };
    }

    /// Kernel command-line word the file needs (null: found without one).
    pub fn kernelArgument(self: Format) ?[]const u8 {
        return switch (self) {
            .kickstart => "inst.ks=file:/usos/answer/ks.cfg",
            else => null,
        };
    }
};

/// Honest limitations of one rendered file, for the start summary.
pub const Note = enum {
    /// Always: the installer asks for the disk (never answered).
    disk_interactive,
    /// Empty profile password: the installer asks for the account
    /// (Ubuntu: identity is interactive and not prefilled, since its
    /// schema requires a password; Debian: d-i asks the password;
    /// Fedora: no user line, the user spoke stays open).
    password_empty,
    /// The user name was changed to a valid Linux login (lower case,
    /// characters outside a-z 0-9 _ - replaced, reserved names suffixed).
    username_adjusted,
    /// user2 is not created (one account only).
    user2_ignored,
    /// No computer name: Ubuntu gets "ubuntu", Debian/Fedora ask or use
    /// their default.
    hostname_default,
    /// Language auto (or without a Linux locale): the installer asks.
    language_asked,
    /// Keyboard without an xkb layout: the installer asks.
    keyboard_asked,
    /// Debian: the xkb variant is not preseeded (xkb-keymap takes a layout).
    keyboard_variant_dropped,
    /// Time zone auto: not set (the installer asks or uses its default).
    timezone_not_set,
    /// Formats (locale) differ from the language: Linux gets one locale,
    /// the language's.
    formats_ignored,
};

pub const Notes = std.EnumSet(Note);

pub const Result = struct {
    bytes: []const u8,
    /// The account (name/password) is asked by the installer.
    interactive_identity: bool,
    notes: Notes,
};

// ------------------------------------------------------------ tables

pub const LocaleMap = struct { tag: []const u8, posix: []const u8 };

/// tables.languages tag -> glibc locale.
pub const locales = [_]LocaleMap{
    .{ .tag = "bg-BG", .posix = "bg_BG.UTF-8" },      .{ .tag = "cs-CZ", .posix = "cs_CZ.UTF-8" },
    .{ .tag = "da-DK", .posix = "da_DK.UTF-8" },      .{ .tag = "de-DE", .posix = "de_DE.UTF-8" },
    .{ .tag = "el-GR", .posix = "el_GR.UTF-8" },      .{ .tag = "en-GB", .posix = "en_GB.UTF-8" },
    .{ .tag = "en-US", .posix = "en_US.UTF-8" },      .{ .tag = "es-ES", .posix = "es_ES.UTF-8" },
    .{ .tag = "es-MX", .posix = "es_MX.UTF-8" },      .{ .tag = "et-EE", .posix = "et_EE.UTF-8" },
    .{ .tag = "fi-FI", .posix = "fi_FI.UTF-8" },      .{ .tag = "fr-FR", .posix = "fr_FR.UTF-8" },
    .{ .tag = "fr-CA", .posix = "fr_CA.UTF-8" },      .{ .tag = "hr-HR", .posix = "hr_HR.UTF-8" },
    .{ .tag = "hu-HU", .posix = "hu_HU.UTF-8" },      .{ .tag = "it-IT", .posix = "it_IT.UTF-8" },
    .{ .tag = "ja-JP", .posix = "ja_JP.UTF-8" },      .{ .tag = "ko-KR", .posix = "ko_KR.UTF-8" },
    .{ .tag = "lt-LT", .posix = "lt_LT.UTF-8" },      .{ .tag = "lv-LV", .posix = "lv_LV.UTF-8" },
    .{ .tag = "nb-NO", .posix = "nb_NO.UTF-8" },      .{ .tag = "nl-NL", .posix = "nl_NL.UTF-8" },
    .{ .tag = "pl-PL", .posix = "pl_PL.UTF-8" },      .{ .tag = "pt-BR", .posix = "pt_BR.UTF-8" },
    .{ .tag = "pt-PT", .posix = "pt_PT.UTF-8" },      .{ .tag = "ro-RO", .posix = "ro_RO.UTF-8" },
    .{ .tag = "ru-RU", .posix = "ru_RU.UTF-8" },      .{ .tag = "sk-SK", .posix = "sk_SK.UTF-8" },
    .{ .tag = "sl-SI", .posix = "sl_SI.UTF-8" },      .{ .tag = "sr-Latn-RS", .posix = "sr_RS.UTF-8@latin" },
    .{ .tag = "sv-SE", .posix = "sv_SE.UTF-8" },      .{ .tag = "tr-TR", .posix = "tr_TR.UTF-8" },
    .{ .tag = "uk-UA", .posix = "uk_UA.UTF-8" },      .{ .tag = "zh-CN", .posix = "zh_CN.UTF-8" },
    .{ .tag = "zh-TW", .posix = "zh_TW.UTF-8" },
};

pub const Xkb = struct { klid: u32, layout: []const u8, variant: []const u8 = "" };

/// Windows keyboard layout id -> xkb layout (and variant). Covers every
/// default keyboard of tables.languages plus common alternatives.
pub const keyboards = [_]Xkb{
    .{ .klid = 0x00000402, .layout = "bg" },
    .{ .klid = 0x00000405, .layout = "cz" },
    .{ .klid = 0x00000406, .layout = "dk" },
    .{ .klid = 0x00000407, .layout = "de" },
    .{ .klid = 0x00000807, .layout = "ch" },
    .{ .klid = 0x0000100c, .layout = "ch", .variant = "fr" },
    .{ .klid = 0x00000408, .layout = "gr" },
    .{ .klid = 0x00000809, .layout = "gb" },
    .{ .klid = 0x00000409, .layout = "us" },
    .{ .klid = 0x00020409, .layout = "us", .variant = "intl" },
    .{ .klid = 0x00010409, .layout = "us", .variant = "dvorak" },
    .{ .klid = 0x0000040a, .layout = "es" },
    .{ .klid = 0x0000080a, .layout = "latam" },
    .{ .klid = 0x00000425, .layout = "ee" },
    .{ .klid = 0x0000040b, .layout = "fi" },
    .{ .klid = 0x0000040c, .layout = "fr" },
    .{ .klid = 0x0000080c, .layout = "be" },
    .{ .klid = 0x00001009, .layout = "ca" },
    .{ .klid = 0x0000041a, .layout = "hr" },
    .{ .klid = 0x0000040e, .layout = "hu" },
    .{ .klid = 0x00000410, .layout = "it" },
    .{ .klid = 0x00000411, .layout = "jp" },
    .{ .klid = 0x00000412, .layout = "kr" },
    .{ .klid = 0x00010427, .layout = "lt" },
    .{ .klid = 0x00010426, .layout = "lv" },
    .{ .klid = 0x00000414, .layout = "no" },
    .{ .klid = 0x00000413, .layout = "nl" },
    .{ .klid = 0x00000415, .layout = "pl" },
    .{ .klid = 0x00010415, .layout = "pl", .variant = "qwertz" },
    .{ .klid = 0x00000416, .layout = "br" },
    .{ .klid = 0x00000816, .layout = "pt" },
    .{ .klid = 0x00010418, .layout = "ro", .variant = "std" },
    .{ .klid = 0x00000418, .layout = "ro" },
    .{ .klid = 0x00000419, .layout = "ru" },
    .{ .klid = 0x0000041b, .layout = "sk" },
    .{ .klid = 0x00000424, .layout = "si" },
    .{ .klid = 0x0000081a, .layout = "rs", .variant = "latin" },
    .{ .klid = 0x0000041d, .layout = "se" },
    .{ .klid = 0x0000041f, .layout = "tr" },
    .{ .klid = 0x00000422, .layout = "ua" },
    .{ .klid = 0x00000804, .layout = "cn" },
    .{ .klid = 0x00000404, .layout = "tw" },
};

pub fn posixLocale(tag: []const u8) ?[]const u8 {
    for (locales) |entry| if (std.ascii.eqlIgnoreCase(entry.tag, tag)) return entry.posix;
    return null;
}

pub fn xkbFor(klid: u32) ?*const Xkb {
    for (&keyboards) |*entry| if (entry.klid == klid) return entry;
    return null;
}

// ------------------------------------------------------------ fields

const reserved_logins = [_][]const u8{
    "root",   "daemon", "bin",  "sys",      "sync",   "games", "man",    "lp",     "mail",
    "news",   "uucp",   "proxy", "www-data", "backup", "list",  "irc",    "nobody", "adm",
    "admin",  "sudo",   "wheel", "users",   "operator", "ubuntu", "debian", "fedora", "halt",
    "shutdown", "ftp",  "systemd-network",
};

const Login = struct {
    bytes: [24]u8 = undefined,
    len: usize = 0,
    adjusted: bool = false,

    fn slice(self: *const Login) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// Profile user -> a login matching ^[a-z][a-z0-9_-]*$ (Ubuntu, Debian
/// adduser and Fedora useradd all accept it): lower case, other
/// characters -> '_', a leading digit gets 'u', reserved names get '1'.
fn login(user: []const u8) Login {
    var out = Login{};
    const n = @min(user.len, 20);
    if (n == 0) {
        @memcpy(out.bytes[0..4], "user");
        out.len = 4;
        out.adjusted = true;
        return out;
    }
    if (std.ascii.isDigit(user[0])) {
        out.bytes[0] = 'u';
        out.len = 1;
    }
    for (user[0..n]) |c| {
        const lower = std.ascii.toLower(c);
        out.bytes[out.len] = if (std.ascii.isAlphanumeric(lower) or lower == '_' or lower == '-') lower else '_';
        out.len += 1;
    }
    for (reserved_logins) |name| {
        if (std.mem.eql(u8, name, out.slice())) {
            out.bytes[out.len] = '1';
            out.len += 1;
            break;
        }
    }
    out.adjusted = !std.mem.eql(u8, out.slice(), user);
    return out;
}

const Host = struct {
    bytes: [15]u8 = undefined,
    len: usize = 0,

    fn slice(self: *const Host) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// Computer name -> hostname: lower case, no leading/trailing '-'
/// (the profile already allows only A-Z a-z 0-9 -). Empty: none.
fn hostname(computer: []const u8) Host {
    var out = Host{};
    const trimmed = std.mem.trim(u8, computer, "-");
    for (trimmed[0..@min(trimmed.len, 15)]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-')) continue;
        out.bytes[out.len] = std.ascii.toLower(c);
        out.len += 1;
    }
    return out;
}

/// What the renderers take from the profile.
const Fields = struct {
    locale: ?[]const u8 = null,
    xkb: ?*const Xkb = null,
    timezone: ?[]const u8 = null,
    login: Login,
    realname: []const u8,
    host: Host,
    crypt: ?[]const u8 = null,
    notes: Notes = .initEmpty(),
};

fn fields(p: *const Profile, salt: []const u8, crypt_buffer: *[sha512crypt.max_len]u8) !Fields {
    var f = Fields{ .login = login(p.user.slice()), .realname = p.user.slice(), .host = hostname(p.computer.slice()) };
    f.notes.insert(.disk_interactive);
    // One system locale: the language, else the formats.
    const lang = p.languageEntry() orelse p.localeEntry();
    if (lang) |entry| f.locale = posixLocale(entry.tag);
    if (f.locale == null) f.notes.insert(.language_asked);
    if (p.languageEntry() != null and p.locale != null and p.locale.? != p.language.?) f.notes.insert(.formats_ignored);
    if (p.inputProfile()) |k| f.xkb = xkbFor(k.klid);
    if (f.xkb == null) f.notes.insert(.keyboard_asked);
    if (p.timeZone()) |zone| f.timezone = zone.id else f.notes.insert(.timezone_not_set);
    if (f.login.adjusted) f.notes.insert(.username_adjusted);
    if (p.user2.len > 0) f.notes.insert(.user2_ignored);
    if (f.host.len == 0) f.notes.insert(.hostname_default);
    // The salt is checked even without a password (a bad caller is a bug).
    if (salt.len == 0 or salt.len > sha512crypt.max_salt) return error.BadSalt;
    for (salt) |c| if (!sha512crypt.isSaltChar(c)) return error.BadSalt;
    if (p.password.len > 0) {
        f.crypt = try sha512crypt.crypt(p.password.slice(), salt, null, crypt_buffer);
    } else f.notes.insert(.password_empty);
    return f;
}

// ------------------------------------------------------------ renderers

const W = std.Io.Writer;

/// YAML double-quoted scalar.
fn yamlString(w: *W, value: []const u8) !void {
    try w.writeByte('"');
    for (value) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        0...0x1f, 0x7f => try w.print("\\x{x:0>2}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn header(w: *W, p: *const Profile, what: []const u8) !void {
    try w.print("# USOS answer profile \"{s}\" (docs/answer-profiles.md).\n", .{p.name.slice()});
    try w.print("# {s}\n", .{what});
}

fn autoinstall(w: *W, p: *const Profile, f: *const Fields) !void {
    try header(w, p, "Disk selection always stays in the installer (storage is interactive).");
    try w.writeAll("autoinstall:\n  version: 1\n  interactive-sections:\n    - storage\n");
    if (f.locale == null) try w.writeAll("    - locale\n");
    if (f.xkb == null) try w.writeAll("    - keyboard\n");
    if (f.crypt == null) try w.writeAll("    - identity\n");
    if (f.locale) |locale| {
        try w.writeAll("  locale: ");
        try yamlString(w, locale);
        try w.writeByte('\n');
    }
    if (f.xkb) |x| {
        try w.writeAll("  keyboard:\n    layout: ");
        try yamlString(w, x.layout);
        try w.writeByte('\n');
        if (x.variant.len > 0) {
            try w.writeAll("    variant: ");
            try yamlString(w, x.variant);
            try w.writeByte('\n');
        }
    }
    if (f.timezone) |zone| {
        try w.writeAll("  timezone: ");
        try yamlString(w, zone);
        try w.writeByte('\n');
    }
    // Subiquity's identity schema requires a password: without one the
    // whole section is left to the installer (no prefill).
    if (f.crypt) |hash| {
        try w.writeAll("  identity:\n    hostname: ");
        try yamlString(w, if (f.host.len > 0) f.host.slice() else "ubuntu");
        try w.writeAll("\n    realname: ");
        try yamlString(w, f.realname);
        try w.writeAll("\n    username: ");
        try yamlString(w, f.login.slice());
        try w.writeAll("\n    password: ");
        try yamlString(w, hash);
        try w.writeByte('\n');
    }
    try w.writeAll("  ssh:\n    install-server: false\n");
    try w.writeAll("  refresh-installer:\n    update: false\n");
}

fn preseed(w: *W, p: *const Profile, f: *const Fields) !void {
    try header(w, p, "No disk or boot loader keys: partitioning always stays in the installer.");
    // USOS boots the installer from the stick: d-i must look at USB media.
    try w.writeAll("d-i cdrom-detect/try-usb boolean true\n");
    if (f.locale) |locale| try w.print("d-i debian-installer/locale string {s}\n", .{locale});
    if (f.xkb) |x| try w.print("d-i keyboard-configuration/xkb-keymap select {s}\n", .{x.layout});
    if (f.host.len > 0) {
        try w.print("d-i netcfg/get_hostname string {s}\n", .{f.host.slice()});
        try w.print("d-i netcfg/hostname string {s}\n", .{f.host.slice()});
    }
    try w.writeAll("d-i netcfg/get_domain string\n");
    try w.writeAll("d-i passwd/root-login boolean false\n");
    try w.print("d-i passwd/user-fullname string {s}\n", .{f.realname});
    try w.print("d-i passwd/username string {s}\n", .{f.login.slice()});
    if (f.crypt) |hash| try w.print("d-i passwd/user-password-crypted password {s}\n", .{hash});
    if (f.timezone) |zone| try w.print("d-i time/zone string {s}\n", .{zone});
    try w.writeAll("d-i clock-setup/utc boolean true\n");
}

fn kickstart(w: *W, p: *const Profile, f: *const Fields) !void {
    try header(w, p, "No storage commands: Installation Destination always stays in the installer.");
    if (f.locale) |locale| try w.print("lang {s}\n", .{locale});
    if (f.xkb) |x| {
        if (x.variant.len > 0)
            try w.print("keyboard --xlayouts='{s} ({s})'\n", .{ x.layout, x.variant })
        else
            try w.print("keyboard --xlayouts='{s}'\n", .{x.layout});
    }
    if (f.timezone) |zone| try w.print("timezone {s} --utc\n", .{zone});
    if (f.host.len > 0) try w.print("network --hostname={s}\n", .{f.host.slice()});
    try w.writeAll("rootpw --lock\n");
    if (f.crypt) |hash| try w.print("user --name={s} --gecos=\"{s}\" --groups=wheel --iscrypted --password={s}\n", .{ f.login.slice(), f.realname, hash });
}

/// Renders `p` as the Linux answer file of `format`. `salt`: 1-16
/// characters of the crypt alphabet (sha512crypt.saltFromBytes of random
/// bytes at start; fixed in the goldens), error.BadSalt otherwise.
pub fn render(p: *const Profile, format: Format, salt: []const u8, buffer: []u8) !Result {
    var crypt_buffer: [sha512crypt.max_len]u8 = undefined;
    var f = try fields(p, salt, &crypt_buffer);
    if (format == .preseed and f.xkb != null and f.xkb.?.variant.len > 0) f.notes.insert(.keyboard_variant_dropped);
    var w: W = .fixed(buffer);
    switch (format) {
        .autoinstall => try autoinstall(&w, p, &f),
        .preseed => try preseed(&w, p, &f),
        .kickstart => try kickstart(&w, p, &f),
    }
    return .{ .bytes = w.buffered(), .interactive_identity = f.crypt == null, .notes = f.notes };
}

// ------------------------------------------------------------ tests

const golden = @import("../../testing/golden.zig");
const profile = @import("profile.zig");

pub const golden_salt = "usosgoldensalt00";

fn parseVector(text: []const u8) !Profile {
    var p: Profile = undefined;
    switch (profile.parse(text, &p)) {
        .ok => {},
        .invalid => return error.InvalidProfile,
    }
    return p;
}

test "linux goldens: autoinstall, preseed, kickstart from the full and no-password profiles" {
    const vectors = [_]struct { name: []const u8, text: []const u8 }{
        .{ .name = "full", .text = @embedFile("testdata/full.profile.ini") },
        .{ .name = "nopassword", .text = @embedFile("testdata/linux-nopassword.profile.ini") },
    };
    const goldens = [_][]const u8{
        @embedFile("testdata/golden/linux/autoinstall.full.txt"),
        @embedFile("testdata/golden/linux/preseed.full.txt"),
        @embedFile("testdata/golden/linux/kickstart.full.txt"),
        @embedFile("testdata/golden/linux/autoinstall.nopassword.txt"),
        @embedFile("testdata/golden/linux/preseed.nopassword.txt"),
        @embedFile("testdata/golden/linux/kickstart.nopassword.txt"),
    };
    var buffer: [max_size]u8 = undefined;
    var i: usize = 0;
    for (vectors) |vector| {
        const p = try parseVector(vector.text);
        for ([_]Format{ .autoinstall, .preseed, .kickstart }) |format| {
            const result = try render(&p, format, golden_salt, &buffer);
            var name_buffer: [64]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buffer, "{s}.{s}.txt", .{ @tagName(format), vector.name });
            var path_buffer: [128]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buffer, "src/flow/answer/testdata/golden/linux/{s}", .{name});
            try golden.expectGolden(name, path, goldens[i], result.bytes);
            try std.testing.expect(std.mem.indexOf(u8, result.bytes, p.password.slice()) == null or p.password.len == 0);
            try std.testing.expectEqual(p.password.len == 0, result.interactive_identity);
            try std.testing.expect(result.notes.contains(.disk_interactive));
            i += 1;
        }
    }
}

test "linux: never a disk key, never the plain password" {
    var p = Profile{};
    try p.name.set("T");
    try p.user.set("Root");
    try p.password.set("S3cret!");
    var buffer: [max_size]u8 = undefined;
    const forbidden = [_][]const u8{ "partman", "grub-installer", "bootdev", "ignoredisk", "clearpart", "autopart", "zerombr", "\npart ", "bootloader", "storage:\n", "S3cret!" };
    for ([_]Format{ .autoinstall, .preseed, .kickstart }) |format| {
        const result = try render(&p, format, "abc", &buffer);
        for (forbidden) |word| {
            errdefer std.debug.print("{s}: {s}\n", .{ @tagName(format), word });
            try std.testing.expect(std.mem.indexOf(u8, result.bytes, word) == null);
        }
        try std.testing.expect(std.mem.indexOf(u8, result.bytes, "$6$abc$") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.bytes, "root1") != null);
        try std.testing.expect(result.notes.contains(.username_adjusted));
        try std.testing.expect(result.notes.contains(.language_asked) and result.notes.contains(.keyboard_asked) and result.notes.contains(.timezone_not_set));
    }
    try std.testing.expectError(error.BadSalt, render(&p, .preseed, "", &buffer));
    try std.testing.expectError(error.BadSalt, render(&p, .preseed, "bad salt", &buffer));
    try std.testing.expectError(error.BadSalt, render(&p, .preseed, "0123456789abcdefg", &buffer));
}

test "linux: logins, hostnames and tables" {
    try std.testing.expectEqualStrings("jan_kowalski", login("Jan Kowalski").slice());
    try std.testing.expectEqualStrings("u1st", login("1st").slice());
    try std.testing.expectEqualStrings("a_b", login("a.b").slice());
    try std.testing.expect(!login("tester").adjusted);
    try std.testing.expectEqualStrings("usos-pc", hostname("USOS-PC").slice());
    try std.testing.expectEqualStrings("pc", hostname("-PC-").slice());
    for (tables.languages) |entry| {
        errdefer std.debug.print("language {s}\n", .{entry.tag});
        try std.testing.expect(posixLocale(entry.tag) != null);
        try std.testing.expect(xkbFor(entry.keyboard) != null);
    }
    for (keyboards, 0..) |a, i| for (keyboards[i + 1 ..]) |b| try std.testing.expect(a.klid != b.klid);
}
