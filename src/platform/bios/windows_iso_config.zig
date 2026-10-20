const std = @import("std");

pub const System = enum {
    vista,
    windows10,

    pub fn folder(self: System) []const u8 {
        return switch (self) {
            .vista => "Windows Vista",
            .windows10 => "Windows 10",
        };
    }

    pub fn folderWide(self: System) []const u16 {
        const wide = std.unicode.utf8ToUtf16LeStringLiteral;
        return switch (self) {
            .vista => wide("Windows Vista"),
            .windows10 => wide("Windows 10"),
        };
    }
};

pub fn sourceConfig(buffer: []u8, partition_guid: [16]u8, iso_size: u64, system: System, image_name: []const u8) ![]const u8 {
    return encodeSourceConfig(buffer, partition_guid, iso_size, categoryForFolder(system.folder()), system.folder(), image_name);
}

pub fn sourceConfigForFolder(buffer: []u8, partition_guid: [16]u8, iso_size: u64, folder: []const u8, image_name: []const u8) ![]const u8 {
    return sourceConfigForCategory(buffer, partition_guid, iso_size, categoryForFolder(folder), folder, image_name);
}

/// The same with the DATA category given. The Legacy Core opens the image from
/// Systems\Windows\<folder> itself and binds exactly that path, without the
/// catalog table walk (the Core has no room for it).
pub fn sourceConfigForCategory(buffer: []u8, partition_guid: [16]u8, iso_size: u64, category: []const u8, folder: []const u8, image_name: []const u8) ![]const u8 {
    try validateName(folder);
    return encodeSourceConfig(buffer, partition_guid, iso_size, category, folder, image_name);
}

fn encodeSourceConfig(buffer: []u8, partition_guid: [16]u8, iso_size: u64, category: []const u8, folder: []const u8, image_name: []const u8) ![]const u8 {
    try validateName(image_name);
    const parts = [_][]const u8{ "Systems\\", category, "\\", folder, "\\Images\\", image_name, "\x00" };
    var size: usize = 32;
    for (parts) |part| size += part.len;
    if (buffer.len < size or iso_size < 32768) return error.InvalidIsoConfiguration;
    @memcpy(buffer[0..8], "USOSISO1");
    @memcpy(buffer[8..24], &partition_guid);
    std.mem.writeInt(u64, buffer[24..32], iso_size, .little);
    var position: usize = 32;
    for (parts) |part| {
        @memcpy(buffer[position..][0..part.len], part);
        position += part.len;
    }
    return buffer[0..size];
}

pub fn validateName(name: []const u8) !void {
    if (name.len == 0 or name.len > 255 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidImageName;
    for (name) |ch| if (ch < 32 or ch > 126 or std.mem.indexOfScalar(u8, "\\/:*?\"<>|", ch) != null) return error.InvalidImageName;
}

test "native ISO configuration binds DATA GUID, size and exact selected path" {
    var buffer: [544]u8 = undefined;
    const id = [_]u8{0x47} ** 16;
    const encoded = try sourceConfig(&buffer, id, 3702233088, .vista, "Vista SP2.iso");
    try std.testing.expectEqualStrings("USOSISO1", encoded[0..8]);
    try std.testing.expectEqualSlices(u8, &id, encoded[8..24]);
    try std.testing.expectEqual(@as(u64, 3702233088), std.mem.readInt(u64, encoded[24..32], .little));
    try std.testing.expectEqualStrings("Systems\\Windows\\Windows Vista\\Images\\Vista SP2.iso\x00", encoded[32..]);
    try std.testing.expectError(error.InvalidImageName, sourceConfig(&buffer, id, 3702233088, .vista, "../old.iso"));
    try std.testing.expectError(error.InvalidImageName, sourceConfig(&buffer, id, 3702233088, .windows10, "bad\".iso"));
}

test "Windows 10 source and directory lookup use the same exact system folder" {
    var buffer: [544]u8 = undefined;
    const id = [_]u8{0x47} ** 16;
    const encoded = try sourceConfig(&buffer, id, 4702233088, .windows10, "Windows 10 x86.iso");
    try std.testing.expectEqualStrings("Systems\\Windows\\Windows 10\\Images\\Windows 10 x86.iso\x00", encoded[32..]);
    try std.testing.expectEqual(@as(u64, 4702233088), std.mem.readInt(u64, encoded[24..32], .little));
    for ([_]System{ .vista, .windows10 }) |system| {
        const folder = system.folder();
        const wide = system.folderWide();
        try std.testing.expectEqual(folder.len, wide.len);
        for (folder, wide) |a, b| try std.testing.expectEqual(@as(u16, a), b);
        try std.testing.expectError(error.InvalidIsoConfiguration, sourceConfig(buffer[0..32], id, 4702233088, system, "image.iso"));
        try std.testing.expectError(error.InvalidIsoConfiguration, sourceConfig(&buffer, id, 0, system, "image.iso"));
    }
}

/// Native NT6 variants keep their own catalog DATA category.
pub fn categoryForFolder(folder: []const u8) []const u8 {
    if (folder.len == 0) return "Windows";
    for (@import("../../catalog/systems.zig").all) |entry| {
        if (std.mem.eql(u8, folder, entry.imageFolder())) return entry.dataCategory();
    }
    return "Windows";
}

test "beta source binding preserves its catalog category" {
    try std.testing.expectEqualStrings("Windows", categoryForFolder(""));
    var buffer: [544]u8 = undefined;
    const value = try sourceConfigForFolder(&buffer, [_]u8{1} ** 16, 900000, "Windows 7 Beta", "arbitrary.iso");
    try std.testing.expectEqualStrings("Systems\\Betas\\Windows 7 Beta\\Images\\arbitrary.iso\x00", value[32..]);
}

test "source categories and folders follow the catalog including all betas" {
    for (@import("../../catalog/systems.zig").all) |entry| {
        if (entry.category != .windows and entry.category != .beta) continue;
        var buffer: [544]u8 = undefined;
        var expected_buffer: [544]u8 = undefined;
        const encoded = try sourceConfigForFolder(&buffer, [_]u8{1} ** 16, 900000, entry.imageFolder(), "a.iso");
        const expected = try std.fmt.bufPrint(&expected_buffer, "{s}\\a.iso\x00", .{entry.image_directory[1..]});
        try std.testing.expectEqualStrings(expected, encoded[32..]);
    }
}
