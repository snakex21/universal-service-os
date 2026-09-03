const ExecutableKind = @import("executable_kind.zig").ExecutableKind;
const com_loader = @import("com_loader.zig");
const mz_header = @import("mz_header.zig");
const mz_loader = @import("mz_loader.zig");

pub const LaunchPlan = union(enum) {
    com: com_loader.Plan,
    mz: mz_loader.Plan,
};

pub fn make(bytes: []const u8, psp_segment: u16, allocation_paragraphs: u16) !LaunchPlan {
    return switch (ExecutableKind.detect(bytes)) {
        .com => .{ .com = try com_loader.plan(psp_segment, allocation_paragraphs, bytes.len) },
        .mz => .{ .mz = try mz_loader.plan(psp_segment, try mz_header.Header.parse(bytes)) },
    };
}

test "launch plan dispatches COM and MZ independently" {
    const std = @import("std");
    const com = try make(&.{ 0x90, 0xC3 }, 0x1000, 0x1000);
    try std.testing.expect(com == .com);

    var mz = [_]u8{0} ** 32;
    mz[0] = 'M';
    mz[1] = 'Z';
    std.mem.writeInt(u16, mz[2..4], 32, .little);
    std.mem.writeInt(u16, mz[4..6], 1, .little);
    std.mem.writeInt(u16, mz[8..10], 2, .little);
    const exe = try make(&mz, 0x1000, 0x1000);
    try std.testing.expect(exe == .mz);
}
