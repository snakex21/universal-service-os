const std = @import("std");
const usos = @import("usos");
const file_read = @import("file_read.zig");

const max_icons: usize = 32;
const max_png_bytes: usize = 1024 * 1024;
const prefix = "\\UI\\Icons\\Systems\\";
const suffix = ".png";

const State = enum { empty, ready, missing };

const Entry = struct {
    state: State = .empty,
    id: ?[]const u8 = null,
    image: usos.gui.RgbaImage = .{},
};

var entries: [max_icons]Entry = [_]Entry{.{}} ** max_icons;
var png_buffer: [max_png_bytes]u8 = undefined;
var scratch: usos.gui.png_rgba.Scratch = .{};

pub fn get(root: *std.os.uefi.protocol.File, id: []const u8) ?*const usos.gui.RgbaImage {
    for (&entries) |*entry| {
        if (entry.id) |known_id| {
            if (!std.mem.eql(u8, known_id, id)) continue;
            return if (entry.state == .ready) &entry.image else null;
        }
    }

    for (&entries) |*entry| {
        if (entry.state != .empty) continue;
        entry.id = id;

        var path_buffer: [260]u8 = undefined;
        const path = buildPath(id, &path_buffer) orelse {
            entry.state = .missing;
            return null;
        };
        const png = file_read.into(root, path, &png_buffer) orelse {
            entry.state = .missing;
            return null;
        };
        if (!usos.gui.png_rgba.decodeIcon(png, &entry.image, &scratch)) {
            entry.state = .missing;
            return null;
        }

        entry.state = .ready;
        return &entry.image;
    }
    return null;
}

fn buildPath(id: []const u8, buffer: *[260]u8) ?[]const u8 {
    const needed = prefix.len + id.len + suffix.len;
    if (needed > buffer.len) return null;
    var offset: usize = 0;
    @memcpy(buffer[offset .. offset + prefix.len], prefix);
    offset += prefix.len;
    @memcpy(buffer[offset .. offset + id.len], id);
    offset += id.len;
    @memcpy(buffer[offset .. offset + suffix.len], suffix);
    offset += suffix.len;
    return buffer[0..offset];
}

test "system icon path follows system id" {
    var buffer: [260]u8 = undefined;
    const path = buildPath("windows-11", &buffer).?;
    try std.testing.expectEqualStrings("\\UI\\Icons\\Systems\\windows-11.png", path);
}
