//! Small XML checks without a DOM (fixed memory, usable in the UEFI menu):
//!
//!   wellFormed     tags balance with one root element, attributes are
//!                  quoted, entities are the five predefined ones or
//!                  character references, comments / PIs / CDATA close
//!   architectures  the set of processorArchitecture="..." values of an
//!                  answer file (the architecture-mismatch warning: Setup
//!                  silently skips components of another architecture)
const std = @import("std");
const Arch = @import("target.zig").Arch;

pub const Error = error{ NotWellFormed, TooDeep };

const max_depth = 64;

fn nameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == ':' or c == '_' or c == '-' or c == '.' or c >= 0x80;
}

fn nameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == ':' or c == '_' or c >= 0x80;
}

fn checkEntities(s: []const u8) Error!void {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '<') return error.NotWellFormed;
        if (s[i] != '&') continue;
        const end = std.mem.indexOfScalarPos(u8, s, i, ';') orelse return error.NotWellFormed;
        const name = s[i + 1 .. end];
        const known = [_][]const u8{ "amp", "lt", "gt", "quot", "apos" };
        var ok = false;
        for (known) |k| if (std.mem.eql(u8, k, name)) {
            ok = true;
        };
        if (!ok) {
            if (name.len < 2 or name[0] != '#') return error.NotWellFormed;
            const digits = if (name[1] == 'x') name[2..] else name[1..];
            if (digits.len == 0) return error.NotWellFormed;
            _ = std.fmt.parseInt(u32, digits, if (name[1] == 'x') 16 else 10) catch return error.NotWellFormed;
        }
        i = end;
    }
}

/// Checks well-formedness (not validity against a schema).
pub fn wellFormed(xml: []const u8) Error!void {
    var stack: [max_depth][]const u8 = undefined;
    var depth: usize = 0;
    var roots: usize = 0;
    var i: usize = 0;
    if (std.mem.startsWith(u8, xml, "\xef\xbb\xbf")) i = 3;
    while (i < xml.len) {
        if (xml[i] != '<') {
            const next = std.mem.indexOfScalarPos(u8, xml, i, '<') orelse xml.len;
            const chunk = xml[i..next];
            if (depth == 0) {
                for (chunk) |c| if (!std.ascii.isWhitespace(c)) return error.NotWellFormed;
            } else try checkEntities(chunk);
            i = next;
            continue;
        }
        const rest = xml[i..];
        if (std.mem.startsWith(u8, rest, "<!--")) {
            const end = std.mem.indexOfPos(u8, xml, i + 4, "-->") orelse return error.NotWellFormed;
            if (std.mem.indexOf(u8, xml[i + 4 .. end], "--") != null) return error.NotWellFormed;
            i = end + 3;
            continue;
        }
        if (std.mem.startsWith(u8, rest, "<![CDATA[")) {
            if (depth == 0) return error.NotWellFormed;
            const end = std.mem.indexOfPos(u8, xml, i, "]]>") orelse return error.NotWellFormed;
            i = end + 3;
            continue;
        }
        if (std.mem.startsWith(u8, rest, "<?")) {
            const end = std.mem.indexOfPos(u8, xml, i, "?>") orelse return error.NotWellFormed;
            i = end + 2;
            continue;
        }
        if (std.mem.startsWith(u8, rest, "<!")) return error.NotWellFormed; // DOCTYPE: not in answer files
        const closing = rest.len > 1 and rest[1] == '/';
        var j: usize = i + (if (closing) @as(usize, 2) else 1);
        const name_start = j;
        if (j >= xml.len or !nameStart(xml[j])) return error.NotWellFormed;
        while (j < xml.len and nameChar(xml[j])) j += 1;
        const name = xml[name_start..j];
        if (closing) {
            while (j < xml.len and std.ascii.isWhitespace(xml[j])) j += 1;
            if (j >= xml.len or xml[j] != '>') return error.NotWellFormed;
            if (depth == 0 or !std.mem.eql(u8, stack[depth - 1], name)) return error.NotWellFormed;
            depth -= 1;
            i = j + 1;
            continue;
        }
        // Attributes.
        var names: [32][]const u8 = undefined;
        var count: usize = 0;
        var self_closing = false;
        while (true) {
            const before = j;
            while (j < xml.len and std.ascii.isWhitespace(xml[j])) j += 1;
            if (j >= xml.len) return error.NotWellFormed;
            if (xml[j] == '>') break;
            if (xml[j] == '/') {
                if (j + 1 >= xml.len or xml[j + 1] != '>') return error.NotWellFormed;
                self_closing = true;
                j += 1;
                break;
            }
            if (j == before) return error.NotWellFormed; // no space before the attribute
            if (!nameStart(xml[j])) return error.NotWellFormed;
            const a = j;
            while (j < xml.len and nameChar(xml[j])) j += 1;
            const attribute = xml[a..j];
            for (names[0..count]) |other| if (std.mem.eql(u8, other, attribute)) return error.NotWellFormed;
            if (count == names.len) return error.NotWellFormed;
            names[count] = attribute;
            count += 1;
            while (j < xml.len and std.ascii.isWhitespace(xml[j])) j += 1;
            if (j >= xml.len or xml[j] != '=') return error.NotWellFormed;
            j += 1;
            while (j < xml.len and std.ascii.isWhitespace(xml[j])) j += 1;
            if (j >= xml.len or (xml[j] != '"' and xml[j] != '\'')) return error.NotWellFormed;
            const quote = xml[j];
            const end = std.mem.indexOfScalarPos(u8, xml, j + 1, quote) orelse return error.NotWellFormed;
            try checkEntities(xml[j + 1 .. end]);
            j = end + 1;
        }
        if (depth == 0) {
            roots += 1;
            if (roots > 1) return error.NotWellFormed;
        }
        if (!self_closing) {
            if (depth == max_depth) return error.TooDeep;
            stack[depth] = name;
            depth += 1;
        }
        i = j + 1;
    }
    if (depth != 0 or roots != 1) return error.NotWellFormed;
}

pub const ArchSet = packed struct {
    x86: bool = false,
    amd64: bool = false,
    arm64: bool = false,
    other: bool = false,

    pub fn empty(self: ArchSet) bool {
        return !(self.x86 or self.amd64 or self.arm64 or self.other);
    }

    pub fn has(self: ArchSet, arch: Arch) bool {
        return switch (arch) {
            .x86 => self.x86,
            .amd64 => self.amd64,
            .arm64 => self.arm64,
        };
    }
};

/// processorArchitecture values used in `xml` (either quote style).
pub fn architectures(xml: []const u8) ArchSet {
    var set = ArchSet{};
    const needle = "processorArchitecture";
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, xml, i, needle)) |at| {
        var j = at + needle.len;
        i = j;
        while (j < xml.len and std.ascii.isWhitespace(xml[j])) j += 1;
        if (j >= xml.len or xml[j] != '=') continue;
        j += 1;
        while (j < xml.len and std.ascii.isWhitespace(xml[j])) j += 1;
        if (j >= xml.len or (xml[j] != '"' and xml[j] != '\'')) continue;
        const end = std.mem.indexOfScalarPos(u8, xml, j + 1, xml[j]) orelse break;
        const value = xml[j + 1 .. end];
        if (Arch.fromText(value)) |arch| switch (arch) {
            .x86 => set.x86 = true,
            .amd64 => set.amd64 = true,
            .arm64 => set.arm64 = true,
        } else set.other = true;
        i = end;
    }
    return set;
}

/// The warning case: the file has components, none for the media's
/// architecture (an amd64-only file with x86 media does nothing).
pub fn mismatch(xml: []const u8, media: Arch) bool {
    const set = architectures(xml);
    return !set.empty() and !set.has(media);
}

test "well-formed checks" {
    try wellFormed("<?xml version=\"1.0\"?>\n<!-- c --><a x='1' y=\"&amp;\"><b/><c>t &lt; &#65; &#x41;</c><![CDATA[<raw>]]></a>\n");
    const bad = [_][]const u8{
        "<a><b></a></b>", "<a>", "<a></a><b></b>", "<a x=1></a>", "<a x='1' x='2'></a>", "<a>&nbsp;</a>",
        "<a>& </a>",      "text<a></a>", "<a><!-- -- --></a>", "<!DOCTYPE a><a></a>", "<a x='1'y='2'></a>", "<a>< b</a>",
    };
    for (bad) |case| {
        wellFormed(case) catch continue;
        std.debug.print("accepted: {s}\n", .{case});
        return error.TestUnexpectedResult;
    }
}

test "architecture mismatch" {
    const amd64_only = "<unattend><settings><component name=\"a\" processorArchitecture=\"amd64\"/><component processorArchitecture = 'amd64'/></settings></unattend>";
    try std.testing.expect(mismatch(amd64_only, .x86));
    try std.testing.expect(!mismatch(amd64_only, .amd64));
    const both = "<c processorArchitecture=\"x86\"/><c processorArchitecture=\"amd64\"/>";
    try std.testing.expect(!mismatch(both, .x86));
    try std.testing.expect(!mismatch("<unattend/>", .x86));
}
