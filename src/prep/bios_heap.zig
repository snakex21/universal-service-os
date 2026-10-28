//! Select only an actual E820-usable arena; all Legacy low-memory objects stay below1MiB.
const std = @import("std");
pub const Region = extern struct { base: u64, length: u64, kind: u32, attributes: u32 };
pub const Arena = struct { start: usize, bytes: usize };

pub fn select(regions: []const Region, scaling: bool) error{NoSpace}!Arena {
    if (!scaling) {
        for (regions) |region| {
            const end = std.math.add(u64, region.base, region.length) catch continue;
            if (region.kind == 1 and region.base <= 16 * 1024 * 1024 and end >= 24 * 1024 * 1024)
                return .{ .start = 16 * 1024 * 1024, .bytes = 8 * 1024 * 1024 };
        }
        return error.NoSpace;
    }
    return selectLimit(regions, 8 * 1024 * 1024);
}

/// Workload-specific cap without altering the legacy eight-MiB profiles.
pub fn selectLimit(regions: []const Region, limit: usize) error{NoSpace}!Arena {
    if (limit < 512 * 1024 or limit > 16 * 1024 * 1024) return error.NoSpace;
    var best: ?Arena = null;
    for (regions) |region| {
        if (region.kind != 1) continue;
        const end = @min(std.math.add(u64, region.base, region.length) catch continue, 0x1_0000_0000);
        if (end <= 1024 * 1024) continue;
        const begin = std.mem.alignForward(u64, @max(region.base, 1024 * 1024), 4096);
        if (begin >= end or begin > std.math.maxInt(usize)) continue;
        const bytes = std.mem.alignBackward(u64, @min(end - begin, limit), 4096);
        if (bytes < 512 * 1024) continue;
        const candidate: Arena = .{ .start = @intCast(begin), .bytes = @intCast(bytes) };
        if (best == null or candidate.bytes > best.?.bytes or (candidate.bytes == best.?.bytes and candidate.start < best.?.start)) best = candidate;
    }
    return best orelse error.NoSpace;
}

test "WIM arena raises only its cap and remains within E820 usable memory" {
    const regions = [_]Region{ .{ .base = 0, .length = 640 * 1024, .kind = 1, .attributes = 0 }, .{ .base = 1024 * 1024, .length = 24 * 1024 * 1024, .kind = 1, .attributes = 0 } };
    try std.testing.expectEqual(@as(usize, 12 * 1024 * 1024), (try selectLimit(&regions, 12 * 1024 * 1024)).bytes);
    try std.testing.expectEqual(@as(usize, 8 * 1024 * 1024), (try select(&regions, true)).bytes);
    const small = [_]Region{.{ .base = 1024 * 1024, .length = 768 * 1024, .kind = 1, .attributes = 0 }};
    try std.testing.expectEqual(@as(usize, 768 * 1024), (try selectLimit(&small, 12 * 1024 * 1024)).bytes);
    try std.testing.expectError(error.NoSpace, selectLimit(&regions, 0));
    try std.testing.expectError(error.NoSpace, selectLimit(&regions, 17 * 1024 * 1024));
}

test "scaling arena avoids low memory and respects the actual E820 boundary" {
    const regions = [_]Region{ .{ .base = 0, .length = 640 * 1024, .kind = 1, .attributes = 0 }, .{ .base = 1024 * 1024, .length = 30 * 1024 * 1024, .kind = 1, .attributes = 0 } };
    const arena = try select(&regions, true);
    try std.testing.expectEqual(@as(usize, 1024 * 1024), arena.start);
    try std.testing.expectEqual(@as(usize, 8 * 1024 * 1024), arena.bytes);
}

test "small scaling arena never includes reserved ACPI or firmware memory" {
    const regions = [_]Region{ .{ .base = 1024 * 1024, .length = 768 * 1024, .kind = 1, .attributes = 0 }, .{ .base = 1792 * 1024, .length = 256 * 1024, .kind = 3, .attributes = 0 } };
    try std.testing.expectEqual(@as(usize, 768 * 1024), (try select(&regions, true)).bytes);
    try std.testing.expectError(error.NoSpace, select(&regions, false));
}

test "overflow and out-of32bit E820 entries cannot become the BIOS arena" {
    const regions = [_]Region{ .{ .base = std.math.maxInt(u64) - 1, .length = 64, .kind = 1, .attributes = 0 }, .{ .base = 0x1_0000_0000, .length = 8 * 1024 * 1024, .kind = 1, .attributes = 0 } };
    try std.testing.expectError(error.NoSpace, select(&regions, true));
}
