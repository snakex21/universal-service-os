//! Editions of an install image (install.wim/esd/swm XML metadata) and
//! the tolerant match of a profile's `edition` against them
//! (docs/answer-profiles.md "Edition").
//!
//! The profile stores a language-neutral id when the edition is picked
//! from an ISO: the image's <EDITIONID>, plus "Core" for a Server Core
//! image whose EDITIONID does not say so (2012 and later), e.g.
//! `Professional`, `ServerStandard`, `ServerStandardCore`. Typed values
//! are also accepted: the image NAME or DISPLAYNAME, or a short name
//! ("Professional", "Windows 7 Pro", "Standard (Desktop Experience)",
//! "Datacenter Core", a few localized words such as "Profesjonalny").
//! The match runs against the ISO chosen at start; the answer then names
//! the image by /IMAGE/INDEX (robust: NAME/DISPLAYNAME may be non-ASCII,
//! and WORK copies the install image unchanged). No match: no edition in
//! the answer, Setup shows its edition list as before.
const std = @import("std");

pub const max_images = 32;

pub fn Text(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        bytes: [capacity]u8 = undefined,
        len: u8 = 0,

        pub fn slice(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }

        /// Truncates to the capacity.
        pub fn set(self: *Self, value: []const u8) void {
            const n = @min(value.len, capacity);
            @memcpy(self.bytes[0..n], value[0..n]);
            self.len = @intCast(n);
        }
    };
}

pub const Image = struct {
    /// 1-based <IMAGE INDEX="n">.
    index: u16 = 0,
    name: Text(80) = .{},
    display: Text(80) = .{},
    edition_id: Text(48) = .{},
    /// Server Core (INSTALLATIONTYPE "Server Core" or a Core EDITIONID).
    core: bool = false,
    server: bool = false,

    /// The id a picked edition is stored as (see the file comment).
    pub fn id(self: *const Image, buffer: []u8) []const u8 {
        const e = self.edition_id.slice();
        if (self.server and self.core and !endsWithIgnoreCase(e, "Core") and !endsWithIgnoreCase(e, "ACor"))
            return std.fmt.bufPrint(buffer, "{s}Core", .{e}) catch e;
        return e;
    }

    /// A readable label: DISPLAYNAME, else NAME, else the id (the XML is
    /// read as ASCII; non-ASCII letters become '?').
    pub fn label(self: *const Image) []const u8 {
        if (self.display.len > 0 and std.mem.indexOfScalar(u8, self.display.slice(), '?') == null) return self.display.slice();
        if (self.name.len > 0 and std.mem.indexOfScalar(u8, self.name.slice(), '?') == null) return self.name.slice();
        return self.edition_id.slice();
    }
};

pub const List = struct {
    items: [max_images]Image = undefined,
    len: u8 = 0,

    pub fn slice(self: *const List) []const Image {
        return self.items[0..self.len];
    }

    pub fn byIndex(self: *const List, index: u16) ?*const Image {
        for (self.slice()) |*image| if (image.index == index) return image;
        return null;
    }
};

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

fn endsWithIgnoreCase(text: []const u8, suffix: []const u8) bool {
    return text.len >= suffix.len and std.ascii.eqlIgnoreCase(text[text.len - suffix.len ..], suffix);
}

fn tagText(entry: []const u8, comptime tag: []const u8) ?[]const u8 {
    const open = "<" ++ tag ++ ">";
    const start = (std.mem.indexOf(u8, entry, open) orelse return null) + open.len;
    const stop = std.mem.indexOfPos(u8, entry, start, "</" ++ tag ++ ">") orelse return null;
    return std.mem.trim(u8, entry[start..stop], " \t\r\n");
}

/// Reads the images of WIM XML metadata already converted to ASCII
/// (windows_media.installXmlAscii). Images past max_images are ignored.
pub fn parse(xml: []const u8, out: *List) void {
    out.len = 0;
    var rest = xml;
    while (std.mem.indexOf(u8, rest, "<IMAGE")) |start| {
        rest = rest[start..];
        const end = std.mem.indexOf(u8, rest, "</IMAGE>") orelse return;
        const entry = rest[0..end];
        rest = rest[end + "</IMAGE>".len ..];
        if (out.len == max_images) return;
        var image = Image{};
        if (std.mem.indexOf(u8, entry, "INDEX=\"")) |at| {
            const digits = entry[at + 7 ..];
            const stop = std.mem.indexOfScalar(u8, digits, '"') orelse 0;
            image.index = std.fmt.parseInt(u16, digits[0..stop], 10) catch 0;
        }
        if (image.index == 0) continue;
        // The image's own NAME / DISPLAYNAME follow </WINDOWS>.
        const tail = if (std.mem.indexOf(u8, entry, "</WINDOWS>")) |w| entry[w..] else entry;
        image.name.set(tagText(tail, "NAME") orelse "");
        image.display.set(tagText(tail, "DISPLAYNAME") orelse "");
        const edition_id = tagText(entry, "EDITIONID") orelse "";
        image.edition_id.set(edition_id);
        const kind = tagText(entry, "INSTALLATIONTYPE");
        const client_type = if (kind) |k| startsWithIgnoreCase(k, "Client") else false;
        image.server = !client_type and (startsWithIgnoreCase(edition_id, "Server") or (if (kind) |k| startsWithIgnoreCase(k, "Server") else false));
        image.core = image.server and blk: {
            if (kind) |k| {
                if (std.ascii.eqlIgnoreCase(k, "Server Core")) break :blk true;
                if (std.ascii.eqlIgnoreCase(k, "Server")) break :blk false;
            }
            break :blk endsWithIgnoreCase(edition_id, "Core") or endsWithIgnoreCase(edition_id, "ACor") or startsWithIgnoreCase(edition_id, "ServerHyper");
        };
        out.items[out.len] = image;
        out.len += 1;
    }
}

// ------------------------------------------------------------ matching

const Want = struct {
    /// Lower-case letters and digits of the edition words.
    key: [64]u8 = undefined,
    len: usize = 0,
    /// Server Core wanted (true), the Desktop Experience (false), either (null).
    core: ?bool = null,

    fn slice(self: *const Want) []const u8 {
        return self.key[0..self.len];
    }

    fn append(self: *Want, word: []const u8) void {
        for (word) |c| {
            if (self.len == self.key.len) return;
            self.key[self.len] = std.ascii.toLower(c);
            self.len += 1;
        }
    }
};

/// Words without meaning for the edition (product, version, packaging).
const noise = [_][]const u8{ "windows", "microsoft", "server", "edition", "vista", "sp1", "sp2", "r2", "x64", "x86", "amd64", "64", "32", "bit", "with", "the", "and", "oem", "retail", "vl", "volume" };
const core_words = [_][]const u8{ "core", "servercore" };
const desktop_words = [_][]const u8{ "desktop", "experience", "gui", "full", "installation", "shell" };

/// Short and localized edition words -> the EDITIONID (lower case).
const aliases = [_]struct { word: []const u8, id: []const u8 }{
    .{ .word = "pro", .id = "professional" },
    .{ .word = "pron", .id = "professionaln" },
    .{ .word = "profesjonalny", .id = "professional" },
    .{ .word = "professionnel", .id = "professional" },
    .{ .word = "profissional", .id = "professional" },
    .{ .word = "profesional", .id = "professional" },
    .{ .word = "professionale", .id = "professional" },
    .{ .word = "home", .id = "core" },
    .{ .word = "homen", .id = "coren" },
    .{ .word = "homesinglelanguage", .id = "coresinglelanguage" },
    .{ .word = "homecountryspecific", .id = "corecountryspecific" },
    .{ .word = "enterpriseltsc", .id = "enterprises" },
    .{ .word = "enterpriseltsb", .id = "enterprises" },
    .{ .word = "proforworkstations", .id = "professionalworkstation" },
    .{ .word = "proeducation", .id = "professionaleducation" },
};

fn isWord(word: []const u8, list: []const []const u8) bool {
    for (list) |w| if (std.ascii.eqlIgnoreCase(word, w)) return true;
    return false;
}

fn allDigits(word: []const u8) bool {
    for (word) |c| if (!std.ascii.isDigit(c)) return false;
    return word.len > 0;
}

fn wantOf(text: []const u8) Want {
    var want = Want{};
    var words = std.mem.tokenizeAny(u8, text, " \t()[]-_,.:/");
    while (words.next()) |word| {
        if (isWord(word, &core_words)) {
            want.core = true;
            continue;
        }
        if (isWord(word, &desktop_words)) {
            if (want.core == null) want.core = false;
            continue;
        }
        if (isWord(word, &noise) or allDigits(word)) continue;
        // A trailing "Core" glued to a Server edition id (ServerStandardCore).
        var w = word;
        if (startsWithIgnoreCase(w, "server") and w.len > "server".len) w = w["server".len..];
        if (w.len > 4 and (endsWithIgnoreCase(w, "core") or endsWithIgnoreCase(w, "acor")) and !std.ascii.eqlIgnoreCase(w, "core")) {
            want.core = true;
            w = w[0 .. w.len - 4];
        }
        want.append(w);
    }
    for (aliases) |alias| if (std.mem.eql(u8, want.slice(), alias.word)) {
        want.len = 0;
        want.append(alias.id);
        break;
    };
    return want;
}

/// The comparable edition key of an image: EDITIONID lower case, Server
/// without "Server", the Core/ACor suffix and "Eval".
fn imageKey(image: *const Image, buffer: []u8) []const u8 {
    var e = image.edition_id.slice();
    if (image.server) {
        if (startsWithIgnoreCase(e, "Server")) e = e["Server".len..];
        if (endsWithIgnoreCase(e, "Eval")) e = e[0 .. e.len - 4];
        if (e.len > 4 and (endsWithIgnoreCase(e, "Core") or endsWithIgnoreCase(e, "ACor"))) e = e[0 .. e.len - 4];
        if (endsWithIgnoreCase(e, "Eval")) e = e[0 .. e.len - 4];
    }
    const n = @min(e.len, buffer.len);
    for (e[0..n], 0..) |c, i| buffer[i] = std.ascii.toLower(c);
    return buffer[0..n];
}

/// The image `wanted` names in `list`, or null (empty, unknown or
/// ambiguous). Order: the stored id, the exact NAME/DISPLAYNAME, then the
/// edition words (Server: Core only when asked for, else the Desktop
/// Experience when the ISO has it).
pub fn match(wanted_raw: []const u8, list: *const List) ?*const Image {
    const wanted = std.mem.trim(u8, wanted_raw, " \t");
    if (wanted.len == 0) return null;
    var id_buffer: [64]u8 = undefined;
    for (list.slice()) |*image| if (std.ascii.eqlIgnoreCase(wanted, image.id(&id_buffer))) return image;
    for (list.slice()) |*image| {
        if (std.ascii.eqlIgnoreCase(wanted, image.name.slice()) or std.ascii.eqlIgnoreCase(wanted, image.display.slice())) return image;
    }
    const want = wantOf(wanted);
    if (want.len == 0) return null;
    var best: ?*const Image = null;
    var key_buffer: [64]u8 = undefined;
    for (list.slice()) |*image| {
        if (!std.mem.eql(u8, imageKey(image, &key_buffer), want.slice())) continue;
        if (want.core) |core| {
            if (image.core != core) continue;
            return image;
        }
        // Either: the Desktop Experience (a full Windows) before Core.
        if (best == null or (best.?.core and !image.core)) best = image;
    }
    return best;
}

// ------------------------------------------------------------ tests

fn testList(entries: []const struct { []const u8, []const u8, []const u8, ?[]const u8 }) List {
    var list = List{};
    for (entries, 0..) |e, i| {
        var image = Image{ .index = @intCast(i + 1) };
        image.name.set(e[0]);
        image.display.set(e[1]);
        image.edition_id.set(e[2]);
        const kind = e[3];
        image.server = startsWithIgnoreCase(e[2], "Server");
        image.core = image.server and (if (kind) |k| std.ascii.eqlIgnoreCase(k, "Server Core") else endsWithIgnoreCase(e[2], "Core"));
        list.items[i] = image;
        list.len += 1;
    }
    return list;
}

test "editions: the Windows 7 SP1 x64 pl metadata" {
    const utf16 = @embedFile("testdata/win7-sp1-x64-pl.install.xml");
    var ascii: [utf16.len / 2]u8 = undefined;
    for (0..ascii.len - 1) |i| ascii[i] = if (utf16[3 + 2 * i] == 0) utf16[2 + 2 * i] else '?';
    var list = List{};
    parse(ascii[0 .. ascii.len - 1], &list);
    try std.testing.expectEqual(@as(u8, 4), list.len);
    try std.testing.expectEqualStrings("Windows 7 PROFESSIONAL", list.items[2].name.slice());
    try std.testing.expectEqualStrings("Windows 7 Professional", list.items[2].label());
    try std.testing.expect(!list.items[2].server);
    const cases = [_]struct { []const u8, ?u16 }{
        .{ "Professional", 3 },       .{ "professional", 3 },          .{ "Windows 7 Professional", 3 },
        .{ "Windows 7 PROFESSIONAL", 3 }, .{ "Windows 7 Profesjonalny", 3 }, .{ "Pro", 3 },
        .{ "Home Premium", 2 },       .{ "HomeBasic", 1 },             .{ "Ultimate", 4 },
        .{ "Enterprise", null },      .{ "Home", null },               .{ "", null },
    };
    for (cases) |case| {
        const found = match(case[0], &list);
        errdefer std.debug.print("case {s}\n", .{case[0]});
        try std.testing.expectEqual(case[1], if (found) |image| image.index else null);
    }
}

test "editions: Server Core and Desktop Experience" {
    // 2016+: one EDITIONID, INSTALLATIONTYPE tells Core from Desktop.
    const modern = testList(&.{
        .{ "Windows Server 2016 SERVERSTANDARDCORE", "Windows Server 2016 Standard", "ServerStandard", "Server Core" },
        .{ "Windows Server 2016 SERVERSTANDARD", "Windows Server 2016 Standard (Desktop Experience)", "ServerStandard", "Server" },
        .{ "Windows Server 2016 SERVERDATACENTERCORE", "Windows Server 2016 Datacenter", "ServerDatacenter", "Server Core" },
    });
    var id: [64]u8 = undefined;
    try std.testing.expectEqualStrings("ServerStandardCore", modern.items[0].id(&id));
    try std.testing.expectEqualStrings("ServerStandard", modern.items[1].id(&id));
    const cases = [_]struct { []const u8, ?u16 }{
        .{ "ServerStandardCore", 1 },   .{ "ServerStandard", 2 },          .{ "Standard", 2 },
        .{ "Standard Core", 1 },        .{ "Standard (Desktop Experience)", 2 }, .{ "Windows Server 2016 Standard", 1 },
        .{ "Datacenter", 3 },           .{ "Datacenter Desktop Experience", null }, .{ "Essentials", null },
    };
    for (cases) |case| {
        errdefer std.debug.print("case {s}\n", .{case[0]});
        try std.testing.expectEqual(case[1], if (match(case[0], &modern)) |image| image.index else null);
    }
    // 2008 R2: Core is its own EDITIONID; the id matches across releases.
    const r2 = testList(&.{
        .{ "Windows Server 2008 R2 SERVERSTANDARD", "", "ServerStandard", "Server" },
        .{ "Windows Server 2008 R2 SERVERSTANDARDCORE", "", "ServerStandardCore", "Server Core" },
    });
    try std.testing.expectEqual(@as(u16, 2), match("ServerStandardCore", &r2).?.index);
    try std.testing.expectEqual(@as(u16, 2), match("Standard Core", &r2).?.index);
    try std.testing.expectEqual(@as(u16, 1), match("Standard", &r2).?.index);
    try std.testing.expectEqualStrings("Windows Server 2008 R2 SERVERSTANDARD", r2.items[0].label());
}

test "editions: Windows 10 Home is EDITIONID Core" {
    const ten = testList(&.{
        .{ "Windows 10 Home", "Windows 10 Home", "Core", null },
        .{ "Windows 10 Pro", "Windows 10 Pro", "Professional", null },
    });
    try std.testing.expectEqual(@as(u16, 1), match("Home", &ten).?.index);
    try std.testing.expectEqual(@as(u16, 1), match("Core", &ten).?.index);
    try std.testing.expectEqual(@as(u16, 2), match("Windows 10 Pro", &ten).?.index);
    try std.testing.expectEqual(@as(u16, 2), match("Pro", &ten).?.index);
}
