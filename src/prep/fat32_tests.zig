// SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const p = @import("platform.zig");
const fat = @import("fat32.zig");
const ro = @import("fat32_ro");

/// Sparse memory disk: only nonzero sectors consume test memory. Enforces the
/// complete-logical-sector contract of real UEFI/BIOS block backends.
const Memory = struct {
    storage: std.AutoHashMap(u64, [4096]u8),
    sector: u32,
    sectors: u64,
    writes: usize = 0,
    fail_writes: bool = false,
    fn init(sector: u32) Memory {
        return .{ .storage = std.AutoHashMap(u64, [4096]u8).init(std.testing.allocator), .sector = sector, .sectors = 264 * 1024 * 1024 / sector };
    }
    fn disk(self: *Memory) p.Disk {
        return .{ .context = self, .sector_bytes = self.sector, .sectors = self.sectors, .read_fn = read, .write_fn = write, .flush_fn = flush };
    }
    fn read(ctx: *anyopaque, offset: u64, out: []u8) p.Error!void {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        if (offset % self.sector != 0 or out.len % self.sector != 0) return error.InvalidArgument;
        var index: usize = 0;
        while (index < out.len) : (index += self.sector) {
            const value = self.storage.get((offset + index) / self.sector);
            if (value) |sector| @memcpy(out[index..][0..self.sector], sector[0..self.sector]) else @memset(out[index..][0..self.sector], 0);
        }
    }
    fn write(ctx: *anyopaque, offset: u64, input: []const u8) p.Error!void {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        if (self.fail_writes) return error.Io;
        if (offset % self.sector != 0 or input.len % self.sector != 0) return error.InvalidArgument;
        self.writes += 1;
        var index: usize = 0;
        while (index < input.len) : (index += self.sector) {
            const lba = (offset + index) / self.sector;
            if (std.mem.allEqual(u8, input[index..][0..self.sector], 0)) {
                _ = self.storage.remove(lba);
                continue;
            }
            var sector: [4096]u8 = @splat(0);
            @memcpy(sector[0..self.sector], input[index..][0..self.sector]);
            self.storage.put(lba, sector) catch return error.NoSpace;
        }
    }
    fn flush(_: *anyopaque) p.Error!void {}
    fn reader(ctx: *anyopaque, offset: u64, output: []u8) error{ Io, OutOfBounds }!void {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        if (offset > self.sectors * self.sector or output.len > self.sectors * self.sector - offset) return error.OutOfBounds;
        for (output, 0..) |*byte, index| {
            const at = offset + index;
            byte.* = if (self.storage.get(at / self.sector)) |sector| sector[@intCast(at % self.sector)] else 0;
        }
    }
};
const part: fat.Partition = .{ .start_bytes = 1024 * 1024, .size_bytes = 260 * 1024 * 1024 };
fn le(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

test "FAT32 formatter512 and4Kn BPB FSInfo backup mirror, no out-of-partition writes" {
    for ([_]u32{ 512, 4096 }) |sector| {
        var memory = Memory.init(sector);
        defer memory.storage.deinit();
        var marker: [4096]u8 = @splat(0x5a);
        try memory.disk().write(part.start_bytes - sector, marker[0..sector]);
        try memory.disk().write(part.start_bytes + part.size_bytes, marker[0..sector]);
        var volume = try fat.format(memory.disk(), part, .{ .serial = 0x19872245 });
        const boot = memory.storage.get(part.start_bytes / sector).?;
        try std.testing.expectEqual(@as(u16, @intCast(sector)), le(u16, &boot, 11));
        try std.testing.expectEqual(@as(u16, 0xaa55), le(u16, &boot, 510));
        try std.testing.expectEqual(@as(u8, 2), boot[16]);
        try std.testing.expect(volume.g.cluster_count >= 65525);
        try std.testing.expectEqual(@as(u8, 1), volume.g.sectors_per_cluster);
        try std.testing.expectEqualSlices(u8, boot[0..sector], memory.storage.get(part.start_bytes / sector + 6).?[0..sector]);
        const info = memory.storage.get(part.start_bytes / sector + 1).?;
        try std.testing.expectEqual(@as(u32, 0x41615252), le(u32, &info, 0));
        try std.testing.expectEqual(volume.g.cluster_count - 1, le(u32, &info, 488));
        try std.testing.expectEqualSlices(u8, info[0..sector], memory.storage.get(part.start_bytes / sector + 7).?[0..sector]);
        const third = memory.storage.get(part.start_bytes / sector + 2).?;
        try std.testing.expectEqual(@as(u16, 0xaa55), le(u16, &third, 510));
        try std.testing.expectEqualSlices(u8, third[0..sector], memory.storage.get(part.start_bytes / sector + 8).?[0..sector]);
        try std.testing.expectEqualSlices(u8, marker[0..sector], memory.storage.get(part.start_bytes / sector - 1).?[0..sector]);
        try std.testing.expectEqualSlices(u8, marker[0..sector], memory.storage.get((part.start_bytes + part.size_bytes) / sector).?[0..sector]);
        _ = try volume.mkdir("EFI");
        try volume.flush();
        for (0..volume.g.sectors_per_fat) |index| {
            var left: [4096]u8 = undefined;
            var right: [4096]u8 = undefined;
            try memory.disk().read(part.start_bytes + (32 + @as(u64, index)) * sector, left[0..sector]);
            try memory.disk().read(part.start_bytes + (32 + volume.g.sectors_per_fat + @as(u64, index)) * sector, right[0..sector]);
            try std.testing.expectEqualSlices(u8, left[0..sector], right[0..sector]);
        }
    }
}

test "streamed ESP tree read through independently implemented existing FAT reader" {
    var memory = Memory.init(512);
    defer memory.storage.deinit();
    var volume = try fat.format(memory.disk(), part, .{ .serial = 0x56542157 });
    _ = try volume.mkdir("EFI");
    _ = try volume.mkdir("EFI/Microsoft");
    _ = try volume.mkdir("EFI/Microsoft/Boot");
    _ = try volume.mkdir("EFI/Microsoft/Boot/en-US");
    var writer = try volume.createFile("EFI/Microsoft/Boot/bootmgfw.efi", 8197);
    var data: [8197]u8 = undefined;
    for (&data, 0..) |*byte, i| byte.* = @truncate(i * 7 + 9);
    try writer.write(data[0..7]);
    try writer.write(data[7..4097]);
    try writer.write(data[4097..]);
    try writer.finish();
    var zero = try volume.createFile("EFI/Microsoft/Boot/en-US/bootmgfw.efi.mui", 0);
    try zero.finish();
    var polish = try volume.createFile("EFI/Microsoft/Boot/Zażółć gęślą jaźń.txt", 4);
    try polish.write("test");
    try polish.finish();
    // Grow directories through multiple clusters, preserving complete LFN groups.
    for (0..50) |i| {
        var path: [96]u8 = undefined;
        const name = try std.fmt.bufPrint(&path, "EFI/Microsoft/Boot/Long collision file {d}.txt", .{i});
        var file = try volume.createFile(name, 4);
        try file.write("done");
        try file.finish();
    }
    try volume.flush();
    const Reader = @typeInfo(@TypeOf(ro.mount)).@"fn".params[0].type.?;
    const reader: Reader = .{ .context = &memory, .read_fn = Memory.reader };
    const fs = try ro.mount(reader, .{ .start_bytes = part.start_bytes, .size_bytes = part.size_bytes });
    const efi = std.unicode.utf8ToUtf16LeStringLiteral("efi");
    const microsoft = std.unicode.utf8ToUtf16LeStringLiteral("MICROSOFT");
    const boot = std.unicode.utf8ToUtf16LeStringLiteral("Boot");
    const file_name = std.unicode.utf8ToUtf16LeStringLiteral("bootmgfw.efi");
    const path = [_][]const u16{ efi, microsoft, boot, file_name };
    var output: [8197]u8 = undefined;
    try std.testing.expectEqual(@as(usize, data.len), try ro.readFile(fs, reader, &path, &output));
    try std.testing.expectEqualSlices(u8, &data, &output);
    const polish_path = [_][]const u16{ efi, microsoft, boot, std.unicode.utf8ToUtf16LeStringLiteral("zażółć gęślą jaźń.TXT") };
    var text: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try ro.readFile(fs, reader, &polish_path, &text));
    try std.testing.expectEqualSlices(u8, "test", &text);
}

test "FAT32 refuses invalid geometry serial and names before writing" {
    var memory = Memory.init(512);
    defer memory.storage.deinit();
    try std.testing.expectError(error.InvalidArgument, fat.format(memory.disk(), .{ .start_bytes = 1, .size_bytes = part.size_bytes }, .{ .serial = 1 }));
    try std.testing.expectError(error.Bounds, fat.format(memory.disk(), .{ .start_bytes = part.start_bytes, .size_bytes = 999 * 1024 * 1024 }, .{ .serial = 1 }));
    try std.testing.expectError(error.NoSpace, fat.format(memory.disk(), .{ .start_bytes = part.start_bytes, .size_bytes = 8 * 1024 * 1024 }, .{ .serial = 1 }));
    try std.testing.expectError(error.InvalidArgument, fat.format(memory.disk(), part, .{ .serial = 0 }));
    try std.testing.expectEqual(@as(usize, 0), memory.writes);
    var volume = try fat.format(memory.disk(), part, .{ .serial = 123 });
    const before = memory.writes;
    for ([_][]const u8{ "", "/EFI", "EFI/", "..", "bad?", "x.", "a//b", "bad\x00x", "bad\xff" }) |name| try std.testing.expectError(error.InvalidName, volume.createFile(name, 0));
    try std.testing.expectError(error.Unsupported, volume.createFile("large", 0x100000000));
    try std.testing.expectEqual(before, memory.writes);
}

test "FAT32 writer guards incomplete overrun duplicate busy and failed IO" {
    var memory = Memory.init(4096);
    defer memory.storage.deinit();
    var volume = try fat.format(memory.disk(), part, .{ .serial = 123 });
    var writer = try volume.createFile("bootmgfw.efi", 5);
    var stale = writer;
    try std.testing.expectError(error.Busy, volume.mkdir("EFI"));
    try std.testing.expectError(error.Busy, volume.flush());
    try std.testing.expectError(error.Incomplete, writer.finish());
    try std.testing.expectError(error.Bounds, writer.write("123456"));
    try writer.write("12345");
    try writer.finish();
    try std.testing.expectError(error.InvalidArgument, writer.write(""));
    try std.testing.expectError(error.AlreadyExists, volume.createFile("BOOTMGFW.EFI", 0));
    var next = try volume.createFile("BCD", 0);
    try std.testing.expectError(error.InvalidArgument, stale.write("12345"));
    try std.testing.expectError(error.InvalidArgument, stale.finish());
    try next.finish();
    memory.fail_writes = true;
    try std.testing.expectError(error.Io, volume.mkdir("EFI"));
    try std.testing.expectError(error.Poisoned, volume.flush());
}

test "FAT32 reopen preserves original stream and appends through validated allocation" {
    for ([_]u32{ 512, 4096 }) |sector| {
        var memory = Memory.init(sector);
        defer memory.storage.deinit();
        var first = try fat.format(memory.disk(), part, .{ .serial = 0x16917154 });
        _ = try first.mkdir("EFI");
        var original = try first.createFile("EFI/Original.dat", 777);
        var data: [777]u8 = undefined;
        for (&data, 0..) |*byte, i| byte.* = @truncate(i * 17);
        try original.write(&data);
        try original.finish();
        try first.flush();
        const writes_before = memory.writes;
        var reopened = try fat.Volume.openExisting(memory.disk(), part);
        try std.testing.expectEqual(writes_before, memory.writes);
        try std.testing.expectEqual(first.free_clusters, reopened.free_clusters);
        try std.testing.expectEqual(first.next_cluster, reopened.next_cluster);
        try std.testing.expectError(error.AlreadyExists, reopened.createFile("efi/original.DAT", 10));
        const first_free = reopened.next_cluster;
        var appended = try reopened.createFile("EFI/Second long filename.dat", 4);
        try std.testing.expectEqual(first_free, appended.first);
        try appended.write("next");
        try appended.finish();
        try reopened.flush();
        _ = try fat.Volume.openExisting(memory.disk(), part);
        if (sector == 512) {
            const Reader = @typeInfo(@TypeOf(ro.mount)).@"fn".params[0].type.?;
            const reader = Reader{ .context = &memory, .read_fn = Memory.reader };
            const fs = try ro.mount(reader, .{ .start_bytes = part.start_bytes, .size_bytes = part.size_bytes });
            const path = [_][]const u16{ std.unicode.utf8ToUtf16LeStringLiteral("EFI"), std.unicode.utf8ToUtf16LeStringLiteral("Original.dat") };
            var actual: [777]u8 = undefined;
            try std.testing.expectEqual(@as(usize, 777), try ro.readFile(fs, reader, &path, &actual));
            try std.testing.expectEqualSlices(u8, &data, &actual);
            const second = [_][]const u16{ std.unicode.utf8ToUtf16LeStringLiteral("EFI"), std.unicode.utf8ToUtf16LeStringLiteral("Second long filename.dat") };
            var text: [4]u8 = undefined;
            try std.testing.expectEqual(@as(usize, 4), try ro.readFile(fs, reader, &second, &text));
            try std.testing.expectEqualSlices(u8, "next", &text);
        }
    }
}

test "FAT32 reopen refuses BPB backups FSInfo mirror and unsafe links without writes" {
    for (0..7) |fault| {
        var memory = Memory.init(512);
        defer memory.storage.deinit();
        var volume = try fat.format(memory.disk(), part, .{ .serial = 0x16917154 });
        try volume.flush();
        const base = part.start_bytes / 512;
        switch (fault) {
            0 => memory.storage.getPtr(base).?[13] = 2,
            1 => memory.storage.getPtr(base + 6).?[67] ^= 1,
            2 => {
                memory.storage.getPtr(base + 1).?[488] ^= 1;
                memory.storage.getPtr(base + 7).?[488] ^= 1;
            },
            3 => memory.storage.getPtr(base + 32 + volume.g.sectors_per_fat).?[0] ^= 1,
            4 => {
                // Self-link in both FATs must not become a mount-time loop.
                std.mem.writeInt(u32, memory.storage.getPtr(base + 32).?[8..12], 2, .little);
                std.mem.writeInt(u32, memory.storage.getPtr(base + 32 + volume.g.sectors_per_fat).?[8..12], 2, .little);
            },
            5 => memory.storage.getPtr(base).?[3] = 'X',
            6 => memory.storage.getPtr(base + 8).?[510] = 0,
            else => unreachable,
        }
        const writes_before = memory.writes;
        try std.testing.expectError(error.Corrupt, fat.Volume.openExisting(memory.disk(), part));
        try std.testing.expectEqual(writes_before, memory.writes);
    }
}
