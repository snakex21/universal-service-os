const std = @import("std");

pub const Screen = struct {
    title: []const u8,
    subtitle: []const u8,
    footer: []const u8,
};

pub fn find(html: []const u8, id: []const u8) ?Screen {
    var needle_buffer: [96]u8 = undefined;
    const prefix = "<section id=\"";
    if (prefix.len + id.len + 1 > needle_buffer.len) return null;
    @memcpy(needle_buffer[0..prefix.len], prefix);
    @memcpy(needle_buffer[prefix.len .. prefix.len + id.len], id);
    needle_buffer[prefix.len + id.len] = '"';
    const needle = needle_buffer[0 .. prefix.len + id.len + 1];

    const start = std.mem.indexOf(u8, html, needle) orelse return null;
    const tag_end_rel = std.mem.indexOfScalar(u8, html[start..], '>') orelse return null;
    const tag = html[start .. start + tag_end_rel + 1];

    return .{
        .title = attribute(tag, "data-title") orelse return null,
        .subtitle = attribute(tag, "data-subtitle") orelse "",
        .footer = attribute(tag, "data-footer") orelse "",
    };
}

fn attribute(tag: []const u8, name: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, tag, name) orelse return null;
    const rest = tag[start + name.len ..];
    const equals = std.mem.indexOfScalar(u8, rest, '=') orelse return null;
    const value = std.mem.trimStart(u8, rest[equals + 1 ..], " \t");
    if (value.len < 2 or value[0] != '"') return null;
    const end = std.mem.indexOfScalar(u8, value[1..], '"') orelse return null;
    return value[1 .. end + 1];
}

test "screen metadata comes from HTML" {
    const std_testing = std.testing;
    const html = "<section id=\"systems\" data-title=\"USOS\" data-subtitle=\"Choose\" data-footer=\"Enter\"></section>";
    const screen = find(html, "systems").?;
    try std_testing.expectEqualStrings("USOS", screen.title);
    try std_testing.expectEqualStrings("Choose", screen.subtitle);
    try std_testing.expectEqualStrings("Enter", screen.footer);
}
