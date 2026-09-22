// Zgodnosc implementacji Zig ze wspolna tabela regul.
//
// Zrodlo prawdy: windows7_pe_rules.tsv (obok tego pliku). Ten sam plik czyta
// installer/internal/winmedia/pe_rules_agreement_test.go, wiec obie
// implementacje - firmware (Zig) i host (Go) - rozjezdzaja sie tylko wtedy,
// gdy ktos swiadomie zmieni wiersz w tabeli.
//
// Tu sprawdzana jest wylacznie kolumna zig_mode. Testy nie montuja niczego,
// nie dotykaja dyskow i nie uruchamiaja Setupu - skladaja w pamieci sam
// zasob XML_DATA z WIM i wolaja produkcyjne funkcje z wim_setup.zig.
const std = @import("std");
const wim = @import("wim_setup.zig");

const rules = @embedFile("windows7_pe_rules.tsv");

const Version = struct {
    major: u32,
    minor: u32,
    build: u32,

    fn parse(text: []const u8) !Version {
        var parts = std.mem.splitScalar(u8, text, '.');
        return .{
            .major = try std.fmt.parseInt(u32, parts.next() orelse return error.BadRule, 10),
            .minor = try std.fmt.parseInt(u32, parts.next() orelse return error.BadRule, 10),
            .build = try std.fmt.parseInt(u32, parts.next() orelse return error.BadRule, 10),
        };
    }
};

const Expected = enum { original, hybrid, rejected };

const Rule = struct {
    install: Version,
    boot: Version,
    arch: u32,
    zig_mode: Expected,
};

fn parseArch(text: []const u8) !u32 {
    if (std.mem.eql(u8, text, "x64")) return 9;
    if (std.mem.eql(u8, text, "x86")) return 0;
    return error.BadRule;
}

fn parseRule(line: []const u8) !Rule {
    var fields = std.mem.splitScalar(u8, line, '\t');
    const install = fields.next() orelse return error.BadRule;
    const boot = fields.next() orelse return error.BadRule;
    const arch = fields.next() orelse return error.BadRule;
    // go_class nalezy do testu po stronie Go; tutaj tylko przeskakujemy.
    _ = fields.next() orelse return error.BadRule;
    const mode = fields.next() orelse return error.BadRule;
    if (fields.next() != null) return error.BadRule;
    return .{
        .install = try Version.parse(install),
        .boot = try Version.parse(boot),
        .arch = try parseArch(arch),
        .zig_mode = std.meta.stringToEnum(Expected, mode) orelse return error.BadRule,
    };
}

// Sklada zasob XML_DATA tak, jak lezy w WIM: UTF-16LE z BOM.
fn encodeXml(ascii: []const u8, out: []u8) []u8 {
    out[0] = 0xff;
    out[1] = 0xfe;
    for (ascii, 0..) |ch, i| {
        out[2 + i * 2] = ch;
        out[3 + i * 2] = 0;
    }
    return out[0 .. 2 + ascii.len * 2];
}

fn imageXml(buffer: []u8, arch: u32, version: Version) ![]u8 {
    var ascii: [512]u8 = undefined;
    const text = try std.fmt.bufPrint(
        &ascii,
        "<WIM><IMAGE INDEX=\"1\"><WINDOWS><ARCH>{d}</ARCH><VERSION><MAJOR>{d}</MAJOR><MINOR>{d}</MINOR><BUILD>{d}</BUILD></VERSION></WINDOWS></IMAGE></WIM>",
        .{ arch, version.major, version.minor, version.build },
    );
    return encodeXml(text, buffer);
}

fn classify(rule: Rule) Expected {
    var boot_storage: [1024]u8 = undefined;
    var install_storage: [1024]u8 = undefined;
    const boot_xml = imageXml(&boot_storage, rule.arch, rule.boot) catch return .rejected;
    const install_xml = imageXml(&install_storage, rule.arch, rule.install) catch return .rejected;
    // detectX64Setup jest jedyna brama architektury i wersji PE; classifyWin7
    // doklada wymagania wobec obrazu instalacyjnego.
    const setup = wim.detectX64Setup(boot_xml, 1) catch return .rejected;
    return switch (wim.classifyWin7(setup, install_xml)) {
        .original => .original,
        .hybrid => .hybrid,
        .unsupported => .rejected,
    };
}

test "wspolna tabela regul PE7/PE10 zgadza sie z implementacja w firmware" {
    var lines = std.mem.splitScalar(u8, rules, '\n');
    var checked: usize = 0;
    var seen_original = false;
    var seen_hybrid = false;
    var seen_rejected = false;
    while (lines.next()) |raw| {
        const line = if (std.mem.endsWith(u8, raw, "\r")) raw[0 .. raw.len - 1] else raw;
        if (line.len == 0 or line[0] == '#') continue;
        const rule = try parseRule(line);
        const actual = classify(rule);
        if (actual != rule.zig_mode) {
            std.debug.print("regula rozjechana: {s}\n  oczekiwano {s}, otrzymano {s}\n", .{ line, @tagName(rule.zig_mode), @tagName(actual) });
            return error.RuleMismatch;
        }
        switch (rule.zig_mode) {
            .original => seen_original = true,
            .hybrid => seen_hybrid = true,
            .rejected => seen_rejected = true,
        }
        checked += 1;
    }
    // Pusta albo obcieta tabela nie moze przejsc jako "wszystko sie zgadza".
    try std.testing.expect(checked >= 8);
    try std.testing.expect(seen_original and seen_hybrid and seen_rejected);
}

test "PE7 idzie na zewnetrzny PE10, PE10 startuje sam, a install.esd nie zmienia klasyfikacji" {
    const pe7 = wim.Setup{ .index = 1, .major = 6, .minor = 1, .build = 7601 };
    const pe10 = wim.Setup{ .index = 1, .major = 10, .minor = 0, .build = 17763 };
    // Sama brama wersji: 6.1 nigdy nie jest odrzucane jako "za stare", a 10.0
    // nigdy nie jest odrzucane jako "nie 6.1" - to byl blad sciezki WORK.
    try std.testing.expectEqual(wim.Win7Mode.original, wim.classifyWin7Boot(pe7));
    try std.testing.expectEqual(wim.Win7Mode.hybrid, wim.classifyWin7Boot(pe10));
    try std.testing.expect(!pe7.isModern());
    try std.testing.expect(pe10.isModern());
    // Klasyfikacja obrazu instalacyjnego czyta wylacznie metadane WIM, wiec
    // install.esd (PE10, 6in1) jest traktowany identycznie jak install.wim.
    var storage: [1024]u8 = undefined;
    const esd_xml = try imageXml(&storage, 9, .{ .major = 6, .minor = 1, .build = 7601 });
    const info = try wim.inspectWin7Install(esd_xml);
    try std.testing.expectEqual(@as(u32, 1), info.count);
    try std.testing.expect(info.sp1);
}

test "nosnik Windows 10 i nieznany nigdy nie wchodza na sciezke Win7" {
    var storage: [1024]u8 = undefined;
    const win10 = try imageXml(&storage, 9, .{ .major = 10, .minor = 0, .build = 19045 });
    try std.testing.expectError(error.UnsupportedWindows7InstallTarget, wim.inspectWin7Install(win10));
    const vista = try imageXml(&storage, 9, .{ .major = 6, .minor = 0, .build = 6002 });
    try std.testing.expectError(error.UnsupportedWindows7InstallTarget, wim.inspectWin7Install(vista));
}
