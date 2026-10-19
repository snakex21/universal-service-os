//! Windows Embedded POSReady 2009 answer (docs/posready-2009-2026-10-10.md).
//!
//! POSReady Setup is a .NET wizard in Windows PE that reads an XML answer
//! (\Setup\unattended.xml). The UEFI menu stages only the values here as
//! POSR.SIF (\EFI\USOS\answer, removed by micro-Linux after it copied the
//! file to RAM); tools/posready_csmwrap_target.sh fills them into
//! tools/posready_unattended.xml. The product key is required (OEM / VL /
//! Eval, 5x5): without one Setup stops with "Invalid product key".
//!
//!   [UserData]  FullName, Organization, ComputerName, AdminPassword, ProductKey
const std = @import("std");
const profile_mod = @import("profile.zig");
const Profile = profile_mod.Profile;

pub const system_id = "windows-embedded-posready-2009";

/// Rendered files the UEFI menu leaves for micro-Linux (\EFI\USOS\answer\<file>).
pub const staged = [_]struct { system_id: []const u8, file: []const u8 }{
    .{ .system_id = system_id, .file = "POSR.SIF" },
    .{ .system_id = "windows-flp", .file = "FLP.SIF" },
};

pub fn isPosReady(id: []const u8) bool {
    return std.ascii.eqlIgnoreCase(id, system_id) or std.ascii.eqlIgnoreCase(id, "windows-flp");
}

/// POSReady keys are 5x5 (OEM, VL and the evaluation SKUs).
pub fn validKey(key: []const u8) bool {
    const shape = profile_mod.keyShape(key) orelse return false;
    return shape == .five_by_five;
}

fn computerName(source: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    for (source) |c| {
        if (n == out.len) break;
        if (std.ascii.isAlphanumeric(c) or c == '-') {
            out[n] = std.ascii.toUpper(c);
            n += 1;
        }
    }
    if (n == 0) {
        const fallback = "USOS-POSREADY";
        @memcpy(out[0..fallback.len], fallback);
        return out[0..fallback.len];
    }
    return out[0..n];
}

/// XML attribute text: no quotes, angle brackets, ampersands or controls.
fn plain(w: *std.Io.Writer, value: []const u8, fallback: []const u8) !void {
    const text = if (value.len > 0) value else fallback;
    for (text) |c| try w.writeByte(switch (c) {
        '"', '<', '>', '&' => '\'',
        else => if (c < 0x20) ' ' else c,
    });
}

/// POSR.SIF (CRLF). `key` is written only with a 5x5 shape.
pub fn render(p: *const Profile, key: []const u8, buffer: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buffer);
    try w.writeAll("; POSR.SIF rendered by USOS for Windows Embedded POSReady 2009 (docs/posready-2009-2026-10-10.md)\r\n[UserData]\r\nFullName=");
    try plain(&w, p.user.slice(), "USOS");
    try w.writeAll("\r\nOrganization=");
    try plain(&w, p.org.slice(), "");
    var name: [15]u8 = undefined;
    try w.print("\r\nComputerName={s}\r\nAdminPassword=", .{computerName(p.computer.slice(), &name)});
    // SIF is a single raw value after the first '='. XML escaping happens
    // once in posready_answer_xml; replacing these characters changes the
    // password that Setup creates.
    for (p.password.slice()) |c| {
        if (c < 0x20) return error.InvalidPassword;
        try w.writeByte(c);
    }
    try w.writeAll("\r\n");
    if (validKey(key)) {
        try w.writeAll("ProductKey=");
        for (key) |c| try w.writeByte(std.ascii.toUpper(c));
        try w.writeAll("\r\n");
    }
    return w.buffered();
}

test "POSReady id and key shape" {
    try std.testing.expect(isPosReady("Windows-Embedded-POSReady-2009") and !isPosReady("windows-xp"));
    try std.testing.expect(validKey("AAAAA-BBBBB-CCCCC-DDDDD-EEEEE") and !validKey("123-4567890") and !validKey(""));
}

test "POSReady password preserves XML and registry special characters" {
    var p = Profile{};
    try p.password.set("a\\b\"&<>@FULL_NAME@");
    var buffer: [2048]u8 = undefined;
    const text = try render(&p, "", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, text, "AdminPassword=a\\b\"&<>@FULL_NAME@\r\n") != null);
}

test "POSR.SIF: names, sanitised values, key only in 5x5 shape" {
    var p = Profile{};
    try p.name.set("A");
    try p.user.set("Jan \"K\" <x>");
    try p.computer.set("kasa 1");
    var buffer: [1024]u8 = undefined;
    const text = try render(&p, "aaaaa-bbbbb-ccccc-ddddd-eeeee", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, text, "FullName=Jan 'K' 'x'\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ComputerName=KASA1\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ProductKey=AAAAA-BBBBB-CCCCC-DDDDD-EEEEE\r\n") != null);
    const no_key = try render(&p, "123-4567890", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, no_key, "ProductKey") == null);
}
