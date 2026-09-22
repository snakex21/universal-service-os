//! Validate the Memtest86+ Linux-protocol image inside the official i586 ISO.
const std = @import("std");
const linux = @import("linux_boot_header.zig");
pub const setup_bytes = 4096;
pub const load_address: u32 = 0x100000;
pub const Layout = struct { offset: u32, load_bytes: u32, runtime_bytes: u32 };

pub fn parse(setup: []const u8, file_size: u64) !Layout {
    const header = try linux.parse(setup);
    try linux.validateImageSize(header, file_size);
    const version = header.kernelVersion(setup) orelse return error.Memtest86PlusImageRequired;
    if (!std.mem.startsWith(u8, version, "Memtest86+ v")) return error.Memtest86PlusImageRequired;
    if (header.protocol < 0x020A or !header.isLoadedHigh() or header.isX86_64() or
        header.code32_start != load_address or header.protected_file_offset > setup_bytes)
        return error.MemtestI586ImageRequired;
    const size = header.protectedBytesFromSyssize();
    if (size == 0 or size > 2 * 1024 * 1024 or size > file_size - header.protected_file_offset or
        header.init_size < size or header.init_size > 16 * 1024 * 1024)
        return error.InvalidMemtestImageSize;
    return .{ .offset = header.protected_file_offset, .load_bytes = @intCast(size), .runtime_bytes = header.init_size };
}

fn fixture() [setup_bytes]u8 {
    var b = [_]u8{0} ** setup_bytes;
    b[0x1f1] = 7;
    std.mem.writeInt(u32, b[0x1f4..0x1f8], 0x2594, .little);
    std.mem.writeInt(u16, b[0x1fe..0x200], 0xaa55, .little);
    @memcpy(b[0x202..0x206], "HdrS");
    std.mem.writeInt(u16, b[0x206..0x208], 0x020c, .little);
    std.mem.writeInt(u16, b[0x20e..0x210], 0x260, .little);
    b[0x211] = 1;
    std.mem.writeInt(u32, b[0x214..0x218], load_address, .little);
    std.mem.writeInt(u32, b[0x260..0x264], 0xb2700, .little);
    const version = "Memtest86+ v8.10";
    @memcpy(b[0x460..][0..version.len], version);
    return b;
}

test "i586 Memtest image uses protected size rather than floppy padding" {
    const b = fixture();
    const layout = try parse(&b, 1474560);
    try std.testing.expectEqual(@as(u32, 4096), layout.offset);
    try std.testing.expectEqual(@as(u32, 153920), layout.load_bytes);
    try std.testing.expectEqual(@as(u32, 730880), layout.runtime_bytes);
}

test "reject unrelated Linux kernel, truncated media and unsafe runtime" {
    var b = fixture();
    b[0x460] = 'L';
    try std.testing.expectError(error.Memtest86PlusImageRequired, parse(&b, 1474560));
    b = fixture();
    try std.testing.expectError(error.InvalidMemtestImageSize, parse(&b, 8192));
    std.mem.writeInt(u32, b[0x260..0x264], 0xffffffff, .little);
    try std.testing.expectError(error.InvalidMemtestImageSize, parse(&b, 1474560));
    b = fixture(); b[0x236] = 1;
    try std.testing.expectError(error.MemtestI586ImageRequired, parse(&b, 1474560));
}
