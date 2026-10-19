//! The 5048 CD's docs/unattend.xml uses lowercase sections and value
//! attributes, not Vista's settings/component schema. Only confirmed user
//! fields are generated here. Boot/WIM and automatic disk binding remain
//! gated by the existing Vista source validator (see support matrix).
const std = @import("std");
const Profile = @import("profile.zig").Profile;
const profiles = @import("profile.zig");

fn attribute(w: *std.Io.Writer, value: []const u8) !void {
    for (value) |c| try w.writeAll(switch (c) {
        '&' => "&amp;",
        '<' => "&lt;",
        '>' => "&gt;",
        '"' => "&quot;",
        '\'' => "&apos;",
        else => blk: {
            if (c < 0x20) return error.InvalidAttribute;
            try w.writeByte(c);
            break :blk "";
        },
    });
}
fn field(w: *std.Io.Writer, tag: []const u8, value: []const u8) !void {
    if (value.len == 0) return;
    try w.print("<{s} value=\"", .{tag});
    try attribute(w, value);
    try w.writeAll("\" showui=\"no\"/>\r\n");
}
pub fn render(p: *const Profile, key: []const u8, buffer: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buffer);
    try w.writeAll("<?xml version=\"1.0\" encoding=\"utf-8\"?>\r\n<unattend>\r\n<userdata>\r\n");
    try field(&w, "Fullname", p.user.slice());
    try field(&w, "Organization", p.org.slice());
    try field(&w, "ComputerName", p.computer.slice());
    if (profiles.keyShape(key) == .five_by_five) try field(&w, "ProductKey", key);
    try w.writeAll("</userdata>\r\n<setupdata><skipeula value=\"yes\"/></setupdata>\r\n</unattend>\r\n");
    return w.buffered();
}

test "5048 user settings use its documented attributes and escape values" {
    var p = Profile{};
    try p.user.set("A & B");
    try p.org.set("Lab");
    var buffer: [4096]u8 = undefined;
    const xml = try render(&p, "", &buffer);
    try @import("xml_check.zig").wellFormed(xml);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<Fullname value=\"A &amp; B\" showui=\"no\"/>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<settings") == null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "installospartition") == null);
}
