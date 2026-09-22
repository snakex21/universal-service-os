const std = @import("std");
const linux_boot_header = @import("linux_boot_header");

test "pinned Alpine vmlinuz exposes the exact Legacy micro-Linux contract" {
    const allocator = std.testing.allocator;
    const image = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "zig-out/micro-linux/vmlinuz-virt", allocator, .limited(32 * 1024 * 1024));
    defer allocator.free(image);

    const header = try linux_boot_header.parse(image[0..linux_boot_header.minimum_header_bytes]);
    try linux_boot_header.validateImageSize(header, image.len);
    try linux_boot_header.validateForUsosMicroLinux(header);

    try std.testing.expectEqual(@as(u16, 0x020F), header.protocol);
    try std.testing.expectEqual(@as(u8, 39), header.setup_sects);
    try std.testing.expectEqual(@as(u32, 20_480), header.protected_file_offset);
    try std.testing.expectEqual(@as(u16, 0xFFFF), header.vid_mode);
    try std.testing.expect(header.isLoadedHigh());
    try std.testing.expect(header.isX86_64());
    try std.testing.expectEqual(@as(u32, 0x00100000), header.code32_start);
    try std.testing.expectEqual(@as(u32, 0x7FFFFFFF), header.initrd_addr_max);
    try std.testing.expectEqual(@as(u32, 0x01000000), header.kernel_alignment);
    try std.testing.expect(header.relocatable_kernel);
    try std.testing.expectEqual(@as(u8, 21), header.min_alignment);
    try std.testing.expectEqual(@as(u16, 0x007F), header.xloadflags);
    try std.testing.expectEqual(@as(u32, 2047), header.cmdline_size);
    try std.testing.expectEqual(@as(u64, 0x01000000), header.pref_address);
    try std.testing.expectEqual(@as(u32, 44_236_800), header.init_size);
    try std.testing.expectEqual(@as(u32, 0x00DC5900), header.kernel_info_offset);

    const version = header.kernelVersion(image) orelse return error.KernelVersionMissing;
    try std.testing.expect(std.mem.startsWith(u8, version, "6.18.35-0-lts"));

    std.debug.print(
        "[PASS] pinned vmlinuz protocol={x:0>4} setup={d} protected_offset=0x{x} code32=0x{x:0>8} initrd_max=0x{x:0>8} align=0x{x:0>8} init_size={d} cmdline={d} xloadflags=0x{x:0>4} version={s}\n",
        .{
            header.protocol,
            header.setup_sects,
            header.protected_file_offset,
            header.code32_start,
            header.initrd_addr_max,
            header.kernel_alignment,
            header.init_size,
            header.cmdline_size,
            header.xloadflags,
            version,
        },
    );
}
