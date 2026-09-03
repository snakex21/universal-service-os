const std = @import("std");
const ImageKind = @import("../catalog/image_kind.zig").ImageKind;

pub const IsoKind = enum {
    udf,
    iso9660,
    joliet,
};

pub const Result = struct {
    kind: ImageKind,
    valid: bool,
    iso_kind: ?IsoKind = null,
};

pub const ProbeError = error{
    UnsupportedExtension,
    FileTooSmall,
};

const iso_sector_size: usize = 2048;
const primary_volume_descriptor_sector: usize = 16;
const iso_identifier_offset: usize = primary_volume_descriptor_sector * iso_sector_size + 1;
const iso_identifier = "CD001";
const probe_sector_count: usize = 32;

pub fn probeBytes(filename: []const u8, bytes: []const u8) ProbeError!Result {
    const kind = ImageKind.fromFilename(filename) orelse return error.UnsupportedExtension;

    return switch (kind) {
        .iso => probeIso(bytes),
        else => .{ .kind = kind, .valid = bytes.len > 0 },
    };
}

pub fn probeFile(io: std.Io, path: []const u8) !Result {
    return probeFileInDir(io, std.Io.Dir.cwd(), path);
}

pub fn probeFileInDir(io: std.Io, dir: std.Io.Dir, path: []const u8) !Result {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);

    const kind = ImageKind.fromFilename(path) orelse return error.UnsupportedExtension;
    if (kind != .iso) {
        const stat = try file.stat(io);
        return .{ .kind = kind, .valid = stat.size > 0 };
    }

    var header: [probe_sector_count * iso_sector_size]u8 = undefined;
    const read_len = try file.readPositionalAll(io, &header, 0);
    if (read_len < iso_identifier_offset + iso_identifier.len) return error.FileTooSmall;
    return probeIso(header[0..read_len]);
}

fn probeIso(bytes: []const u8) ProbeError!Result {
    if (bytes.len < iso_identifier_offset + iso_identifier.len) return error.FileTooSmall;

    var has_udf = false;
    var sector: usize = 16;
    while (sector < probe_sector_count and (sector + 1) * iso_sector_size <= bytes.len) : (sector += 1) {
        const descriptor = bytes[sector * iso_sector_size .. (sector + 1) * iso_sector_size];
        if (std.mem.eql(u8, descriptor[1..6], "NSR02") or std.mem.eql(u8, descriptor[1..6], "NSR03")) {
            has_udf = true;
            break;
        }
    }

    const has_iso9660 = std.mem.eql(
        u8,
        bytes[iso_identifier_offset .. iso_identifier_offset + iso_identifier.len],
        iso_identifier,
    );

    return .{
        .kind = .iso,
        .valid = has_udf or has_iso9660,
        .iso_kind = if (has_udf) .udf else if (has_iso9660) .iso9660 else null,
    };
}

test "ISO probe recognizes ISO9660 primary volume descriptor" {
    var bytes = [_]u8{0} ** (iso_identifier_offset + iso_identifier.len);
    @memcpy(bytes[iso_identifier_offset .. iso_identifier_offset + iso_identifier.len], iso_identifier);

    const result = try probeBytes("windows.iso", &bytes);
    try std.testing.expectEqual(ImageKind.iso, result.kind);
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(IsoKind.iso9660, result.iso_kind.?);
}

test "ISO probe rejects a renamed non-ISO file" {
    var bytes = [_]u8{0} ** (iso_identifier_offset + iso_identifier.len);
    const result = try probeBytes("fake.iso", &bytes);
    try std.testing.expect(!result.valid);
    try std.testing.expect(result.iso_kind == null);
}

test "probe reads ISO as an ordinary host file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var bytes = [_]u8{0} ** (iso_identifier_offset + iso_identifier.len);
    @memcpy(bytes[iso_identifier_offset .. iso_identifier_offset + iso_identifier.len], iso_identifier);

    var file = try tmp.dir.createFile(std.testing.io, "fixture.iso", .{});
    try file.writePositionalAll(std.testing.io, &bytes, 0);
    file.close(std.testing.io);

    const result = try probeFileInDir(std.testing.io, tmp.dir, "fixture.iso");
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(IsoKind.iso9660, result.iso_kind.?);
}

test "probe rejects unsupported extension" {
    try std.testing.expectError(error.UnsupportedExtension, probeBytes("archive.zip", "data"));
}

test "non ISO images are at least checked for non-empty content" {
    const result = try probeBytes("boot.wim", "x");
    try std.testing.expectEqual(ImageKind.wim, result.kind);
    try std.testing.expect(result.valid);
}
