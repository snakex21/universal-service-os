const std = @import("std");
const DiscoveredImage = @import("discovered_image.zig").DiscoveredImage;
const probe = @import("../image_probe/probe.zig");
const random_access = @import("../image_probe/random_access.zig");
const windows_detect = @import("../image_probe/windows_detect.zig");

pub fn inspect(io: std.Io, path: []const u8) !DiscoveredImage {
    const result = try probe.probeFile(io, path);
    var entry = fromProbe(path, result);
    if (result.kind != .iso or !result.valid) return entry;

    var reader = try random_access.FileReader.open(io, std.Io.Dir.cwd(), path);
    defer reader.close();
    const detection = windows_detect.inspect(&reader) catch return entry;
    entry.detected_system = detection.system;
    return entry;
}

pub fn fromProbe(path: []const u8, result: probe.Result) DiscoveredImage {
    return .{
        .path = path,
        .kind = result.kind,
        .verified = result.valid,
    };
}

test "catalog entry is built from image probe result" {
    const entry = fromProbe("Windows.iso", .{
        .kind = .iso,
        .valid = true,
        .iso_kind = .iso9660,
    });
    try std.testing.expectEqualStrings("Windows.iso", entry.path);
    try std.testing.expectEqual(@import("image_kind.zig").ImageKind.iso, entry.kind);
    try std.testing.expect(entry.verified);
    try std.testing.expectEqual(@import("detected_system.zig").DetectedSystem.unknown, entry.detected_system);
}

test "CD001 alone never classifies an image as Windows" {
    const entry = fromProbe("ubuntu.iso", .{
        .kind = .iso,
        .valid = true,
        .iso_kind = .iso9660,
    });
    try std.testing.expectEqual(@import("detected_system.zig").DetectedSystem.unknown, entry.detected_system);
}
