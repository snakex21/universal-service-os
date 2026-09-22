//! Seed the confirmed FAT16 target with the user's original DOS boot files.
const std = @import("std");
const partition = @import("dos_partition.zig");
const format = @import("dos_fat16_format.zig");
const dos = @import("dos_fat.zig");
const names = [_][]const u8{ "IO.SYS", "MSDOS.SYS", "COMMAND.COM", "CONFIG.SYS", "AUTOEXEC.BAT" };
pub const Seed = struct {
    boot: [512]u8,
    files: [5][]const u8,
    pub fn validate(self: Seed) !void {
        if (dos.get16(&self.boot, 510) != 0xaa55 or !std.mem.eql(u8, self.boot[3..11], "MSDOS6.2")) return error.InvalidDosBootSeed;
        for (self.files, 0..) |bytes, i| {
            if (bytes.len == 0 or bytes.len > (if (i < 3) @as(usize, 128 * 1024) else 512)) return error.InvalidDosBootSeed;
        }
    }
};

pub fn write(writer: anytype, plan: partition.Plan, seed: Seed) !void {
    try seed.validate();
    const layout = try format.layout(plan.partition_sectors);
    const metadata = try format.header(plan);
    const root_lba = 2049 + 2 * @as(u32, layout.fat_sectors);
    const data_lba = root_lba + 32;
    const cluster_bytes = @as(usize, layout.cluster_sectors) * 512;
    var fat = [_]u8{0} ** 512;
    std.mem.writeInt(u16, fat[0..2], 0xfff8, .little);
    std.mem.writeInt(u16, fat[2..4], 0xffff, .little);
    var root = [_]u8{0} ** 512;
    var next: u16 = 2;
    for (seed.files, names, 0..) |bytes, name, index| {
        const clusters: u16 = @intCast((bytes.len + cluster_bytes - 1) / cluster_bytes);
        if (next + clusters > 256) return error.InvalidDosBootSeed;
        const entry = root[index * 32..][0..32];
        @memcpy(entry[0..11], &(try dos.shortName(name)));
        entry[11] = 0x20;
        std.mem.writeInt(u16, entry[26..28], next, .little);
        std.mem.writeInt(u32, entry[28..32], @intCast(bytes.len), .little);
        for (next..next + clusters) |cluster|
            std.mem.writeInt(u16, fat[cluster * 2..][0..2], if (cluster + 1 == next + clusters) 0xffff else @intCast(cluster + 1), .little);
        const first = data_lba + (@as(u32, next) - 2) * layout.cluster_sectors;
        for (0..@as(u32, clusters) * layout.cluster_sectors) |sector| {
            var block = [_]u8{0} ** 512;
            const offset = sector * 512;
            if (offset < bytes.len) {
                const count = @min(512, bytes.len - offset);
                @memcpy(block[0..count], bytes[offset..][0..count]);
            }
            try checkedWrite(writer, first + @as(u32, @intCast(sector)), &block);
        }
        next += clusters;
    }
    try checkedWrite(writer, 2049, &fat);
    try checkedWrite(writer, 2049 + layout.fat_sectors, &fat);
    try checkedWrite(writer, root_lba, &root);
    var boot = seed.boot;
    @memcpy(boot[11..62], metadata[11..62]);
    // Publish executable boot code after every file and FAT write is verified.
    try checkedWrite(writer, 2048, &boot);
}

fn checkedWrite(writer: anytype, lba: u32, bytes: *const [512]u8) !void {
    try writer.write(lba, bytes);
    var actual: [512]u8 = undefined;
    try writer.read(lba, &actual);
    if (!std.mem.eql(u8, bytes, &actual)) return error.DosBootSeedReadbackFailed;
}

test "boot seed rejects missing kernels and foreign boot sectors" {
    var seed = Seed{ .boot = [_]u8{0} ** 512, .files = .{ "IO", "DOS", "COMMAND", "CONFIG", "AUTOEXEC" } };
    try std.testing.expectError(error.InvalidDosBootSeed, seed.validate());
    @memcpy(seed.boot[3..11], "MSDOS6.2"); seed.boot[510] = 0x55; seed.boot[511] = 0xaa;
    try seed.validate();
    seed.files[1] = "";
    try std.testing.expectError(error.InvalidDosBootSeed, seed.validate());
}

test "boot seed verifies data and publishes the original boot code last" {
    const Fake = struct {
        sectors: [][512]u8,
        last_write: u32 = 0,
        corrupt: bool = false,
        pub fn write(self: *@This(), lba: u32, bytes: *const [512]u8) !void {
            try std.testing.expect(lba >= 2048 and lba < 3072);
            self.sectors[lba - 2048] = bytes.*;
            self.last_write = lba;
        }
        pub fn read(self: *@This(), lba: u32, out: *[512]u8) !void {
            out.* = self.sectors[lba - 2048];
            if (self.corrupt) out[0] ^= 1;
        }
    };
    const sectors = try std.testing.allocator.alloc([512]u8, 1024);
    defer std.testing.allocator.free(sectors);
    for (sectors) |*sector| @memset(sector, 0);
    var writer = Fake{ .sectors = sectors };
    const payload = [_]u8{0x42} ** 5000;
    var seed = Seed{ .boot = [_]u8{0xa5} ** 512, .files = .{ &payload, "DOS", "COMMAND", "CONFIG", "AUTOEXEC" } };
    @memcpy(seed.boot[3..11], "MSDOS6.2"); seed.boot[510] = 0x55; seed.boot[511] = 0xaa;
    const before = [_]u8{0} ** 512;
    const plan = try partition.planFat16(0x81, 0x80, 4_000_000, 128, 1024, 64, 63, before);
    try write(&writer, plan, seed);
    try std.testing.expectEqual(@as(u32, 2048), writer.last_write);
    const layout = try format.layout(plan.partition_sectors);
    const root = 1 + 2 * @as(usize, layout.fat_sectors);
    const data = root + 32;
    try std.testing.expectEqualSlices(u8, &sectors[1], &sectors[1 + layout.fat_sectors]);
    try std.testing.expectEqualStrings("IO      SYS", sectors[root][0..11]);
    try std.testing.expectEqual(@as(u16, 3), dos.get16(&sectors[1], 4));
    try std.testing.expectEqual(@as(u16, 0xffff), dos.get16(&sectors[1], 8));
    for (0..payload.len) |i| try std.testing.expectEqual(payload[i], sectors[data + i / 512][i % 512]);
    try std.testing.expectEqual(@as(u8, 0), sectors[data + payload.len / 512][payload.len % 512]);
    try std.testing.expectEqualSlices(u8, seed.boot[62..512], sectors[0][62..512]);
    try std.testing.expectEqualStrings("FAT16   ", sectors[0][54..62]);
    writer.corrupt = true; writer.last_write = 0;
    try std.testing.expectError(error.DosBootSeedReadbackFailed, write(&writer, plan, seed));
    try std.testing.expect(writer.last_write != 2048);
}
