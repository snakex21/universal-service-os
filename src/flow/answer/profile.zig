//! One settings model for every Windows answer file (refactor M5,
//! docs/answer-profiles.md): a USOS answer profile, stored as a small INI
//! file (`usos-profile`) on the ESP by the UEFI menu, and rendered per OS by
//! nt5.zig (WINNT.SIF through the XP staging merge) and autounattend.zig
//! (Vista .. 11 and Server).
//!
//! Fixed-size storage, no allocator (like the rest of src/flow). Parsing is
//! strict: an unknown key or a bad value is an error with the line number
//! and the field, never the value (keys and passwords stay out of logs).
const std = @import("std");
const tables = @import("tables.zig");

pub fn Text(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        pub const max = capacity;
        bytes: [capacity]u8 = undefined,
        len: u8 = 0,

        pub fn slice(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }

        pub fn set(self: *Self, value: []const u8) error{TooLong}!void {
            if (value.len > capacity) return error.TooLong;
            @memcpy(self.bytes[0..value.len], value);
            self.len = @intCast(value.len);
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }
    };
}

pub const Field = enum {
    name,
    user,
    user2,
    computer,
    org,
    password,
    timezone,
    language,
    locale,
    keyboard,
    key,
    remember_key,
    manual_disk,
    local_account,
    bypass_tpm,
    bypass_secure_boot,
    bypass_ram,
    no_network_oobe,
};

/// Keyboard: follow the locale (auto), or an explicit input profile
/// `LLLL:KKKKKKKK` (language id : keyboard layout id).
pub const Keyboard = struct {
    lcid: u16,
    klid: u32,
};

/// A product key for one catalog system (key.windows-xp=...).
pub const SystemKey = struct {
    system: Text(32) = .{},
    key: Text(29) = .{},
};

pub const max_system_keys = 8;
pub const max_file = 4096;

pub const Profile = struct {
    /// Name shown in the menu; also the file name stem.
    name: Text(32) = .{},
    user: Text(20) = .{},
    user2: Text(20) = .{},
    /// Empty: USOS-XP on XP (as usos-xp.ini), a Setup-chosen name on 6.x+.
    computer: Text(15) = .{},
    org: Text(64) = .{},
    password: Text(64) = .{},
    /// Index into tables.time_zones; null: auto (from the media language).
    timezone: ?u8 = null,
    /// Index into tables.languages; null: auto (Setup asks / media default).
    language: ?u8 = null,
    /// Formats (UserLocale/SystemLocale); null: the language.
    locale: ?u8 = null,
    /// null: the locale's default keyboard.
    keyboard: ?Keyboard = null,
    /// Key for every system without its own key.
    key: Text(29) = .{},
    system_keys: [max_system_keys]SystemKey = @splat(.{}),
    system_key_count: u8 = 0,
    /// Keys are written to the ESP only when this is on.
    remember_key: bool = false,
    /// Always on in this version: no DiskConfiguration, no WillWipeDisk.
    manual_disk: bool = true,
    /// Windows 8+: local account, online account screens hidden.
    local_account: bool = true,
    /// Windows 11 requirement checks (LabConfig), off by default.
    bypass_tpm: bool = false,
    bypass_secure_boot: bool = false,
    bypass_ram: bool = false,
    /// Windows 11: OOBE without network (BypassNRO), wireless page hidden.
    no_network_oobe: bool = false,

    /// Product key for a catalog system id: its own key, else the common one.
    pub fn keyFor(self: *const Profile, system_id: []const u8) []const u8 {
        for (self.system_keys[0..self.system_key_count]) |*entry| {
            if (std.ascii.eqlIgnoreCase(entry.system.slice(), system_id)) return entry.key.slice();
        }
        return self.key.slice();
    }

    pub fn hasAnyKey(self: *const Profile) bool {
        return self.key.len > 0 or self.system_key_count > 0;
    }

    pub fn setSystemKey(self: *Profile, system_id: []const u8, key: []const u8) !void {
        for (self.system_keys[0..self.system_key_count]) |*entry| {
            if (std.ascii.eqlIgnoreCase(entry.system.slice(), system_id)) {
                if (key.len == 0) return self.removeSystemKey(system_id);
                return entry.key.set(key);
            }
        }
        if (key.len == 0) return;
        if (self.system_key_count == max_system_keys) return error.TooManyKeys;
        var entry = &self.system_keys[self.system_key_count];
        entry.* = .{};
        try entry.system.set(system_id);
        try entry.key.set(key);
        self.system_key_count += 1;
    }

    fn removeSystemKey(self: *Profile, system_id: []const u8) void {
        var out: usize = 0;
        for (0..self.system_key_count) |i| {
            if (std.ascii.eqlIgnoreCase(self.system_keys[i].system.slice(), system_id)) continue;
            self.system_keys[out] = self.system_keys[i];
            out += 1;
        }
        self.system_key_count = @intCast(out);
    }

    pub fn clearKeys(self: *Profile) void {
        self.key = .{};
        self.system_key_count = 0;
    }

    pub fn timeZone(self: *const Profile) ?*const tables.TimeZone {
        return if (self.timezone) |i| &tables.time_zones[i] else null;
    }

    pub fn languageEntry(self: *const Profile) ?*const tables.Language {
        return if (self.language) |i| &tables.languages[i] else null;
    }

    /// Formats: the explicit locale, else the language.
    pub fn localeEntry(self: *const Profile) ?*const tables.Language {
        if (self.locale) |i| return &tables.languages[i];
        return self.languageEntry();
    }

    /// Input profile: explicit, else the locale's default keyboard.
    pub fn inputProfile(self: *const Profile) ?Keyboard {
        if (self.keyboard) |k| return k;
        const entry = self.localeEntry() orelse return null;
        return .{ .lcid = entry.lcid, .klid = entry.keyboard };
    }
};

// ------------------------------------------------------------ validation

pub const Problem = enum {
    too_long,
    empty,
    bad_characters,
    reserved_name,
    same_as_user,
    only_digits,
    bad_key_format,
    unknown_time_zone,
    unknown_language,
    bad_keyboard,
    bad_boolean,
    unknown_field,
    not_key_value,
    unsupported,
    too_many_keys,
    duplicate,
};

pub const Issue = struct {
    field: ?Field = null,
    problem: Problem,
    /// 1-based line of the file (0: not from a file).
    line: u32 = 0,
};

const reserved_accounts = [_][]const u8{ "administrator", "administrators", "guest", "system", "helpassistant", "support_388945a0", "defaultaccount", "wdagutilityaccount" };

/// Same rule as tools/xp_user_settings.sh: 1-20 characters A-Z a-z 0-9 . _ -
/// and space, first character alphanumeric, not ending in '.' or space, not
/// a built-in account.
pub fn checkAccount(value: []const u8) ?Problem {
    if (value.len == 0) return .empty;
    if (value.len > 20) return .too_long;
    if (!std.ascii.isAlphanumeric(value[0])) return .bad_characters;
    for (value) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-' or c == ' ')) return .bad_characters;
    }
    if (value[value.len - 1] == '.' or value[value.len - 1] == ' ') return .bad_characters;
    for (reserved_accounts) |name| {
        if (std.ascii.eqlIgnoreCase(name, value)) return .reserved_name;
    }
    return null;
}

/// NetBIOS: 1-15 characters A-Z a-z 0-9 -, not only digits. Empty = default.
pub fn checkComputer(value: []const u8) ?Problem {
    if (value.len == 0) return null;
    if (value.len > 15) return .too_long;
    var digits = true;
    for (value) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-')) return .bad_characters;
        if (!std.ascii.isDigit(c)) digits = false;
    }
    if (digits) return .only_digits;
    return null;
}

/// Printable ASCII without the characters that break WINNT.SIF quoting or cmd.
fn cleanAscii(value: []const u8, allow_space: bool) bool {
    for (value) |c| {
        if (c < 0x20 or c > 0x7e) return false;
        if (c == ' ' and !allow_space) return false;
        if (std.mem.indexOfScalar(u8, "\"%^&|<>", c) != null) return false;
    }
    return true;
}

pub fn checkOrg(value: []const u8) ?Problem {
    if (value.len > 64) return .too_long;
    if (!cleanAscii(value, true)) return .bad_characters;
    return null;
}

pub fn checkPassword(value: []const u8) ?Problem {
    if (value.len > 64) return .too_long;
    if (!cleanAscii(value, false)) return .bad_characters;
    return null;
}

/// XXXXX-XXXXX-XXXXX-XXXXX-XXXXX (letters and digits, any case). Empty = none.
pub fn checkKey(value: []const u8) ?Problem {
    if (value.len == 0) return null;
    if (value.len != 29) return .bad_key_format;
    for (value, 0..) |c, i| {
        if (i % 6 == 5) {
            if (c != '-') return .bad_key_format;
        } else if (!std.ascii.isAlphanumeric(c)) return .bad_key_format;
    }
    return null;
}

/// Profile name: 1-32 characters A-Z a-z 0-9 space . _ - (also a FAT file stem).
pub fn checkName(value: []const u8) ?Problem {
    if (value.len == 0) return .empty;
    if (value.len > 32) return .too_long;
    for (value) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == ' ' or c == '.' or c == '_' or c == '-')) return .bad_characters;
    }
    if (value[0] == ' ' or value[0] == '.' or value[value.len - 1] == ' ' or value[value.len - 1] == '.') return .bad_characters;
    return null;
}

/// The first problem of a complete profile (null: valid).
pub fn validate(p: *const Profile) ?Issue {
    if (checkName(p.name.slice())) |problem| return .{ .field = .name, .problem = problem };
    if (checkAccount(p.user.slice())) |problem| return .{ .field = .user, .problem = problem };
    if (p.user2.len > 0) {
        if (checkAccount(p.user2.slice())) |problem| return .{ .field = .user2, .problem = problem };
        if (std.ascii.eqlIgnoreCase(p.user.slice(), p.user2.slice())) return .{ .field = .user2, .problem = .same_as_user };
    }
    if (checkComputer(p.computer.slice())) |problem| return .{ .field = .computer, .problem = problem };
    if (checkOrg(p.org.slice())) |problem| return .{ .field = .org, .problem = problem };
    if (checkPassword(p.password.slice())) |problem| return .{ .field = .password, .problem = problem };
    if (checkKey(p.key.slice())) |problem| return .{ .field = .key, .problem = problem };
    for (p.system_keys[0..p.system_key_count]) |*entry| {
        if (checkKey(entry.key.slice())) |problem| return .{ .field = .key, .problem = problem };
    }
    if (!p.manual_disk) return .{ .field = .manual_disk, .problem = .unsupported };
    return null;
}

// ------------------------------------------------------------ parsing

pub const ParseResult = union(enum) {
    ok,
    invalid: Issue,
};

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') return value[1 .. value.len - 1];
    return value;
}

fn parseBool(value: []const u8) ?bool {
    const yes = [_][]const u8{ "1", "yes", "true", "on" };
    const no = [_][]const u8{ "0", "no", "false", "off" };
    for (yes) |y| if (std.ascii.eqlIgnoreCase(value, y)) return true;
    for (no) |n| if (std.ascii.eqlIgnoreCase(value, n)) return false;
    return null;
}

fn isAuto(value: []const u8) bool {
    return value.len == 0 or std.ascii.eqlIgnoreCase(value, "auto");
}

fn hexDigits(value: []const u8) ?u32 {
    if (value.len == 0 or value.len > 8) return null;
    return std.fmt.parseInt(u32, value, 16) catch null;
}

/// `LLLL:KKKKKKKK`, or a language tag (its default keyboard).
pub fn parseKeyboard(value: []const u8) ?Keyboard {
    if (std.mem.indexOfScalar(u8, value, ':')) |colon| {
        if (colon != 4 or value.len != 13) return null;
        const lcid = hexDigits(value[0..4]) orelse return null;
        const klid = hexDigits(value[5..]) orelse return null;
        return .{ .lcid = @intCast(lcid), .klid = klid };
    }
    const entry = tables.language(value) orelse return null;
    return .{ .lcid = entry.lcid, .klid = entry.keyboard };
}

fn fieldByName(name: []const u8) ?Field {
    inline for (@typeInfo(Field).@"enum".fields) |f| {
        if (std.ascii.eqlIgnoreCase(name, f.name)) return @enumFromInt(f.value);
    }
    return null;
}

/// Parses a usos-profile file into `out` (starting from defaults). UTF-8 BOM
/// and CRLF allowed, ';'/'#' comments and [sections] skipped, keys
/// case-insensitive, values trimmed and optionally quoted. Keys only in
/// the file mean remember_key was on when it was saved.
pub fn parse(text: []const u8, out: *Profile) ParseResult {
    out.* = .{};
    if (text.len > max_file) return .{ .invalid = .{ .problem = .too_long } };
    const body = if (std.mem.startsWith(u8, text, "\xef\xbb\xbf")) text[3..] else text;
    var lines = std.mem.splitScalar(u8, body, '\n');
    var number: u32 = 0;
    while (lines.next()) |raw| {
        number += 1;
        const line = trim(raw);
        if (line.len == 0 or line[0] == ';' or line[0] == '#' or line[0] == '[') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return .{ .invalid = .{ .problem = .not_key_value, .line = number } };
        const name = trim(line[0..eq]);
        const value = unquote(trim(line[eq + 1 ..]));
        if (applyField(out, name, value)) |issue| {
            var located = issue;
            located.line = number;
            return .{ .invalid = located };
        }
    }
    if (validate(out)) |issue| return .{ .invalid = issue };
    return .ok;
}

fn applyField(p: *Profile, name: []const u8, value: []const u8) ?Issue {
    if (std.ascii.startsWithIgnoreCase(name, "key.")) {
        const system = name[4..];
        if (system.len == 0 or system.len > 32) return .{ .field = .key, .problem = .unknown_field };
        for (system) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-')) return .{ .field = .key, .problem = .unknown_field };
        if (checkKey(value)) |problem| return .{ .field = .key, .problem = problem };
        const upper = upperKey(value);
        p.setSystemKey(system, upper.slice()) catch return .{ .field = .key, .problem = .too_many_keys };
        return null;
    }
    const field = fieldByName(name) orelse return .{ .problem = .unknown_field };
    switch (field) {
        .name => p.name.set(value) catch return .{ .field = field, .problem = .too_long },
        .user => p.user.set(value) catch return .{ .field = field, .problem = .too_long },
        .user2 => p.user2.set(value) catch return .{ .field = field, .problem = .too_long },
        .computer => p.computer.set(value) catch return .{ .field = field, .problem = .too_long },
        .org => p.org.set(value) catch return .{ .field = field, .problem = .too_long },
        .password => p.password.set(value) catch return .{ .field = field, .problem = .too_long },
        .key => {
            if (checkKey(value)) |problem| return .{ .field = field, .problem = problem };
            p.key = upperKey(value);
        },
        .timezone => p.timezone = if (isAuto(value)) null else if (tables.timeZoneIndex(value)) |i| @intCast(i) else return .{ .field = field, .problem = .unknown_time_zone },
        .language => p.language = if (isAuto(value)) null else if (tables.language(value)) |entry| @intCast(entry - &tables.languages[0]) else return .{ .field = field, .problem = .unknown_language },
        .locale => p.locale = if (isAuto(value)) null else if (tables.language(value)) |entry| @intCast(entry - &tables.languages[0]) else return .{ .field = field, .problem = .unknown_language },
        .keyboard => p.keyboard = if (isAuto(value)) null else parseKeyboard(value) orelse return .{ .field = field, .problem = .bad_keyboard },
        .remember_key, .manual_disk, .local_account, .bypass_tpm, .bypass_secure_boot, .bypass_ram, .no_network_oobe => {
            const flag = parseBool(value) orelse return .{ .field = field, .problem = .bad_boolean };
            switch (field) {
                .remember_key => p.remember_key = flag,
                .manual_disk => p.manual_disk = flag,
                .local_account => p.local_account = flag,
                .bypass_tpm => p.bypass_tpm = flag,
                .bypass_secure_boot => p.bypass_secure_boot = flag,
                .bypass_ram => p.bypass_ram = flag,
                .no_network_oobe => p.no_network_oobe = flag,
                else => unreachable,
            }
        },
    }
    return null;
}

fn upperKey(value: []const u8) Text(29) {
    var t: Text(29) = .{};
    const n = @min(value.len, 29);
    for (value[0..n], 0..) |c, i| t.bytes[i] = std.ascii.toUpper(c);
    t.len = @intCast(n);
    return t;
}

// ------------------------------------------------------------ writing

fn boolText(value: bool) []const u8 {
    return if (value) "yes" else "no";
}

/// The canonical file (CRLF, for Notepad). Keys are written only with
/// remember_key; the password is written (documented: plain text).
pub fn write(p: *const Profile, buffer: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buffer);
    try w.writeAll("; USOS answer profile (docs/answer-profiles.md). Plain text: the password\r\n");
    try w.writeAll("; and, with remember_key=yes, the product keys are readable by anyone with the stick.\r\n");
    try w.writeAll("[usos-profile]\r\n");
    try w.print("name={s}\r\nuser={s}\r\nuser2={s}\r\ncomputer={s}\r\norg={s}\r\npassword={s}\r\n", .{ p.name.slice(), p.user.slice(), p.user2.slice(), p.computer.slice(), p.org.slice(), p.password.slice() });
    try w.print("timezone={s}\r\n", .{if (p.timeZone()) |z| z.id else "auto"});
    try w.print("language={s}\r\n", .{if (p.languageEntry()) |l| l.tag else "auto"});
    try w.print("locale={s}\r\n", .{if (p.locale) |i| tables.languages[i].tag else "auto"});
    if (p.keyboard) |k| {
        try w.print("keyboard={X:0>4}:{X:0>8}\r\n", .{ k.lcid, k.klid });
    } else try w.writeAll("keyboard=auto\r\n");
    try w.print("remember_key={s}\r\n", .{boolText(p.remember_key)});
    if (p.remember_key) {
        try w.print("key={s}\r\n", .{p.key.slice()});
        for (p.system_keys[0..p.system_key_count]) |*entry| try w.print("key.{s}={s}\r\n", .{ entry.system.slice(), entry.key.slice() });
    }
    try w.print("manual_disk={s}\r\nlocal_account={s}\r\nbypass_tpm={s}\r\nbypass_secure_boot={s}\r\nbypass_ram={s}\r\nno_network_oobe={s}\r\n", .{
        boolText(p.manual_disk),   boolText(p.local_account), boolText(p.bypass_tpm),
        boolText(p.bypass_secure_boot), boolText(p.bypass_ram), boolText(p.no_network_oobe),
    });
    return w.buffered();
}

/// FAT file name for a profile name: lower case, space and '.' -> '-'
/// (`<stem>.ini` under \EFI\USOS\profiles).
pub fn fileStem(name: []const u8, buffer: []u8) []const u8 {
    const n = @min(name.len, buffer.len);
    for (name[0..n], 0..) |c, i| buffer[i] = if (c == ' ' or c == '.') '-' else std.ascii.toLower(c);
    return buffer[0..n];
}

// ------------------------------------------------------------ usos-xp.ini

/// Maps DATA's usos-xp.ini into the model (the first profile, "usos-xp.ini").
/// The key becomes the XP key (key.windows-xp) with remember_key on, since
/// it is already stored in a file. null: the file is inactive (no user=).
pub fn importXpIni(text: []const u8, out: *Profile) ?ParseResult {
    out.* = .{};
    out.name.set("usos-xp.ini") catch unreachable;
    const body = if (std.mem.startsWith(u8, text, "\xef\xbb\xbf")) text[3..] else text;
    var lines = std.mem.splitScalar(u8, body, '\n');
    var number: u32 = 0;
    var user_seen = false;
    while (lines.next()) |raw| {
        number += 1;
        const line = trim(raw);
        if (line.len == 0 or line[0] == ';' or line[0] == '#' or line[0] == '[') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return .{ .invalid = .{ .problem = .not_key_value, .line = number } };
        const name = trim(line[0..eq]);
        const value = unquote(trim(line[eq + 1 ..]));
        const issue: ?Issue = blk: {
            if (std.ascii.eqlIgnoreCase(name, "timezone")) {
                if (value.len == 0) break :blk null;
                const index = std.fmt.parseInt(u16, value, 10) catch break :blk Issue{ .field = .timezone, .problem = .unknown_time_zone };
                const zone = tables.timeZoneForNt5(index) orelse break :blk Issue{ .field = .timezone, .problem = .unknown_time_zone };
                out.timezone = @intCast(zone - &tables.time_zones[0]);
                break :blk null;
            }
            if (std.ascii.eqlIgnoreCase(name, "key")) {
                if (checkKey(value)) |problem| break :blk Issue{ .field = .key, .problem = problem };
                const upper = upperKey(value);
                out.setSystemKey("windows-xp", upper.slice()) catch unreachable;
                break :blk null;
            }
            const known = [_][]const u8{ "user", "user2", "computer", "org", "password" };
            for (known) |k| {
                if (std.ascii.eqlIgnoreCase(name, k)) {
                    if (std.ascii.eqlIgnoreCase(name, "user") and value.len > 0) user_seen = true;
                    break :blk applyField(out, name, value);
                }
            }
            break :blk Issue{ .problem = .unknown_field };
        };
        if (issue) |i| {
            var located = i;
            located.line = number;
            return .{ .invalid = located };
        }
    }
    if (!user_seen) return null;
    out.remember_key = out.system_key_count > 0;
    if (validate(out)) |issue| return .{ .invalid = issue };
    return .ok;
}

// ------------------------------------------------------------ tests

test "profile round trip keeps every field; keys only with remember_key" {
    var p = Profile{};
    try p.name.set("Dom");
    try p.user.set("Tester");
    try p.user2.set("Drugi");
    try p.computer.set("USOS-PC");
    try p.org.set("USOS");
    try p.password.set("Tajne1!");
    p.timezone = @intCast(tables.timeZoneIndex("Europe/Warsaw").?);
    p.language = @intCast(tables.languageIndex("pl-PL").?);
    p.keyboard = .{ .lcid = 0x0415, .klid = 0x00010415 };
    try p.key.set("AAAAA-BBBBB-CCCCC-DDDDD-EEEEE");
    try p.setSystemKey("windows-xp", "FFFFF-GGGGG-HHHHH-JJJJJ-KKKKK");
    p.bypass_tpm = true;
    p.remember_key = true;
    var buffer: [max_file]u8 = undefined;
    const text = try write(&p, &buffer);
    var q: Profile = undefined;
    try std.testing.expect(parse(text, &q) == .ok);
    try std.testing.expectEqualStrings("Tester", q.user.slice());
    try std.testing.expectEqualStrings("Drugi", q.user2.slice());
    try std.testing.expectEqualStrings("Europe/Warsaw", q.timeZone().?.id);
    try std.testing.expectEqualStrings("pl-PL", q.languageEntry().?.tag);
    try std.testing.expectEqual(@as(u32, 0x00010415), q.inputProfile().?.klid);
    try std.testing.expectEqualStrings("FFFFF-GGGGG-HHHHH-JJJJJ-KKKKK", q.keyFor("windows-xp"));
    try std.testing.expectEqualStrings("AAAAA-BBBBB-CCCCC-DDDDD-EEEEE", q.keyFor("windows-10"));
    try std.testing.expect(q.bypass_tpm and !q.bypass_ram and q.manual_disk and q.local_account);

    p.remember_key = false;
    const forgotten = try write(&p, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, forgotten, "AAAAA") == null);
    try std.testing.expect(std.mem.indexOf(u8, forgotten, "FFFFF") == null);
    try std.testing.expect(parse(forgotten, &q) == .ok);
    try std.testing.expect(!q.hasAnyKey());
}

test "profile parse errors name the field and line, never the value" {
    var p: Profile = undefined;
    const cases = [_]struct { text: []const u8, field: ?Field, problem: Problem, line: u32 }{
        .{ .text = "name=A\nuser=Bob\nfoo=1\n", .field = null, .problem = .unknown_field, .line = 3 },
        .{ .text = "name=A\nuser=Administrator\n", .field = .user, .problem = .reserved_name, .line = 0 },
        .{ .text = "name=A\nuser=Bob\nuser2=bob\n", .field = .user2, .problem = .same_as_user, .line = 0 },
        .{ .text = "name=A\nuser=Bob\ncomputer=12345\n", .field = .computer, .problem = .only_digits, .line = 0 },
        .{ .text = "name=A\nuser=Bob\nkey=ABC\n", .field = .key, .problem = .bad_key_format, .line = 3 },
        .{ .text = "name=A\nuser=Bob\ntimezone=Mars/Base\n", .field = .timezone, .problem = .unknown_time_zone, .line = 3 },
        .{ .text = "name=A\nuser=Bob\nlanguage=xx-XX\n", .field = .language, .problem = .unknown_language, .line = 3 },
        .{ .text = "name=A\nuser=Bob\nkeyboard=0415-1\n", .field = .keyboard, .problem = .bad_keyboard, .line = 3 },
        .{ .text = "name=A\nuser=Bob\nmanual_disk=no\n", .field = .manual_disk, .problem = .unsupported, .line = 0 },
        .{ .text = "name=A\nuser=Bob\nbypass_tpm=maybe\n", .field = .bypass_tpm, .problem = .bad_boolean, .line = 3 },
        .{ .text = "name=A\nuser=Bob\npassword=a b\n", .field = .password, .problem = .bad_characters, .line = 0 },
        .{ .text = "name=A\njusttext\n", .field = null, .problem = .not_key_value, .line = 2 },
        .{ .text = "user=Bob\n", .field = .name, .problem = .empty, .line = 0 },
    };
    for (cases) |case| {
        const result = parse(case.text, &p);
        errdefer std.debug.print("case: {s}\n", .{case.text});
        try std.testing.expect(result == .invalid);
        try std.testing.expectEqual(case.field, result.invalid.field);
        try std.testing.expectEqual(case.problem, result.invalid.problem);
        try std.testing.expectEqual(case.line, result.invalid.line);
    }
}

test "usos-xp.ini maps into the model" {
    var p: Profile = undefined;
    const x470 = "user=Tester\r\nuser2=Drugi\r\ncomputer=USOS-XP-TEST\r\norg=USOS\r\ntimezone=95\r\npassword=\r\nkey=aaaaa-bbbbb-ccccc-ddddd-eeeee\r\n";
    try std.testing.expect(importXpIni(x470, &p).? == .ok);
    try std.testing.expectEqualStrings("usos-xp.ini", p.name.slice());
    try std.testing.expectEqualStrings("USOS-XP-TEST", p.computer.slice());
    try std.testing.expectEqual(@as(u16, 95), p.timeZone().?.nt5);
    try std.testing.expectEqualStrings("AAAAA-BBBBB-CCCCC-DDDDD-EEEEE", p.keyFor("windows-xp"));
    try std.testing.expectEqualStrings("", p.keyFor("windows-10"));
    try std.testing.expect(p.remember_key);
    try std.testing.expect(importXpIni("; empty\r\nuser=\r\nkey=\r\n", &p) == null);
    try std.testing.expect(importXpIni("user=Bob\nfoo=1\n", &p).? == .invalid);
    try std.testing.expect(importXpIni("user=Bob\ntimezone=999\n", &p).? == .invalid);
}

test "field checks follow the XP staging rules" {
    try std.testing.expect(checkAccount("Jan Kowalski") == null);
    try std.testing.expectEqual(Problem.bad_characters, checkAccount("Jan.").?);
    try std.testing.expectEqual(Problem.bad_characters, checkAccount("Za\xc5\xbc").?);
    try std.testing.expect(checkComputer("") == null);
    try std.testing.expectEqual(Problem.bad_characters, checkComputer("a_b").?);
    try std.testing.expectEqual(Problem.bad_characters, checkOrg("A&B").?);
    try std.testing.expect(checkKey("abcde-12345-ABCDE-12345-abcde") == null);
    try std.testing.expectEqual(Problem.bad_characters, checkName("a/b").?);
    var stem: [32]u8 = undefined;
    try std.testing.expectEqualStrings("moj-profil-1", fileStem("Moj profil.1", &stem));
}
