// SPDX-License-Identifier: GPL-3.0-or-later
//! Deliberately small regular-file fixture. Firmware uses fat32.zig directly.
const std = @import("std");
const host = @import("host_main.zig");
const fat = @import("fat32.zig");
const p = @import("platform.zig");

pub const image_bytes = 302 * 1024 * 1024;
pub const partition = fat.Partition{ .start_bytes = 1024 * 1024, .size_bytes = 300 * 1024 * 1024 };

fn put(comptime T: type, buffer: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, buffer[offset..][0..@sizeOf(T)], value, .little);
}
fn fixture(volume: *fat.Volume) !void {
    _ = try volume.mkdir("EFI");
    _ = try volume.mkdir("EFI/BOOT");
    _ = try volume.mkdir("EFI/Microsoft");
    _ = try volume.mkdir("EFI/Microsoft/Boot");
    _ = try volume.mkdir("EFI/Microsoft/Boot/en-US");
    _ = try volume.mkdir("EFI/Microsoft/Boot/Fonts");
    const names = [_][]const u8{
        "EFI/BOOT/BOOTX64.EFI",                      "EFI/Microsoft/Boot/bootmgfw.efi",        "EFI/Microsoft/Boot/BCD",
        "EFI/Microsoft/Boot/en-US/bootmgfw.efi.mui", "EFI/Microsoft/Boot/Fonts/wgl4_boot.ttf",
        "EFI/Microsoft/Boot/Zażółć gęślą jaźń.txt",
        "EFI/Microsoft/Boot/Empty.txt",
    };
    var buffer: [8197]u8 = undefined;
    for (names, 0..) |name, file_index| {
        const size: usize = if (file_index == names.len - 1) 0 else 8197 + file_index * 123;
        var writer = try volume.createFile(name, size);
        var offset: usize = 0;
        while (offset < size) {
            const count = @min(size - offset, buffer.len);
            for (buffer[0..count], 0..) |*byte, i| byte.* = @truncate((offset + i) * 7 + 9 + file_index);
            // Exercise unaligned stream chunks and the final partial sector.
            try writer.write(buffer[0..@min(7, count)]);
            try writer.write(buffer[@min(7, count)..count]);
            offset += count;
        }
        try writer.finish();
    }
    for (0..100) |i| {
        var path: [100]u8 = undefined;
        const name = try std.fmt.bufPrint(&path, "EFI/Microsoft/Boot/Long collision fixture {d}.txt", .{i});
        var writer = try volume.createFile(name, 4);
        try writer.write("done");
        try writer.finish();
    }
    try volume.flush();
}

pub fn main(init: std.process.Init) !u8 {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const image_path = args.next() orelse return error.MissingImage;
    const sector = try std.fmt.parseInt(u32, args.next() orelse return error.MissingSectorBytes, 10);
    const acknowledgment = args.next() orelse return error.MissingAcknowledgment;
    const workspace = args.next() orelse return error.MissingWorkspace;
    if (args.next() != null or !std.mem.eql(u8, acknowledgment, "--image-only") or (sector != 512 and sector != 4096)) return error.InvalidArgument;
    try host.validateAbsolute(workspace);
    const root = try std.Io.Dir.realPathFileAbsoluteAlloc(init.io, workspace, init.gpa);
    defer init.gpa.free(root);
    const canonical = try host.ownedPath(init.io, init.gpa, root, image_path);
    defer init.gpa.free(canonical);
    if (!std.mem.endsWith(u8, canonical, ".raw")) return error.InvalidArgument;
    var file = try host.open(init.io, canonical, true);
    defer file.file.close(init.io);
    const stat = try file.file.stat(init.io);
    if (stat.nlink != 1 or file.size != image_bytes) return error.InvalidArgument;
    var buffer: [8192]u8 = undefined;
    var offset: u64 = 0;
    while (offset < file.size) {
        const take: usize = @intCast(@min(buffer.len, file.size - offset));
        try host.File.read(&file, offset, buffer[0..take]);
        if (!std.mem.allEqual(u8, buffer[0..take], 0)) return error.TargetNotEmpty;
        offset += take;
    }
    var random: [8]u8 = undefined;
    try init.io.randomSecure(&random);
    const serial = std.mem.readInt(u32, random[0..4], .little);
    const signature = std.mem.readInt(u32, random[4..8], .little);
    if (serial == 0 or serial == 0xffffffff or signature == 0 or signature == 0xffffffff) return error.InvalidEntropy;
    const disk = p.Disk{ .context = &file, .sector_bytes = sector, .sectors = file.size / sector, .read_fn = host.File.read, .write_fn = host.File.write, .flush_fn = host.File.flush };
    var mbr: [4096]u8 = @splat(0);
    put(u32, &mbr, 440, signature);
    mbr[450] = 0x0c;
    @memcpy(mbr[447..450], "\xfe\xff\xff");
    @memcpy(mbr[451..454], "\xfe\xff\xff");
    put(u32, &mbr, 454, @intCast(partition.start_bytes / sector));
    put(u32, &mbr, 458, @intCast(partition.size_bytes / sector));
    put(u16, &mbr, 510, 0xaa55);
    try disk.write(0, mbr[0..sector]);
    var volume = try fat.format(disk, partition, .{ .serial = serial });
    // Model1c2 ->1c3b: append to the same validated ESP without reformatting.
    var marker = try volume.createFile("PHASE1.TXT", 11);
    try marker.write("first phase");
    try marker.finish();
    try volume.flush();
    volume = try fat.Volume.openExisting(disk, partition);
    try fixture(&volume);
    std.debug.print("FAT32_FIXTURE_COMPLETE sector_bytes={d} clusters={d} free={d} next={d} volume_state_bytes={d} writer_state_bytes={d} allocator_bytes=0\n", .{
        sector, volume.g.cluster_count, volume.free_clusters, volume.next_cluster, @sizeOf(fat.Volume), @sizeOf(fat.FileWriter),
    });
    return 0;
}
