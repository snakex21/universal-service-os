//! Small DOS source image. All mutations are to a caller-owned RAM buffer.
const std = @import("std");
pub const image_size = 256 * 1024 * 1024;
const fat_size = 128 * 512;
const root_start = 512 + 2 * fat_size;
const data_start = root_start + 512 * 32;
const cluster_size = 8192;
pub const Error = error{ InvalidDosFloppy, MissingDosFile, CorruptDosFile, InvalidDosName, DosImageFull };
pub const Directory = struct { offset: usize, cluster: u16, count: usize = 2 };

pub const Floppy = struct {
    bytes: []const u8,
    pub fn init(bytes: []const u8) Error!Floppy {
        if (bytes.len != 1474560 or get16(bytes, 11) != 512 or bytes[13] != 1 or get16(bytes, 14) != 1 or bytes[16] != 2 or get16(bytes, 17) != 224 or get16(bytes, 22) != 9 or get16(bytes, 510) != 0xaa55) return error.InvalidDosFloppy;
        return .{ .bytes = bytes };
    }
    pub fn lookup(self: Floppy, name: []const u8) Error![]const u8 {
        const key = try shortName(name);
        var offset: usize = 19 * 512;
        while (offset < 33 * 512) : (offset += 32) {
            const entry = self.bytes[offset..][0..32];
            if (entry[0] == 0) break;
            if (std.mem.eql(u8, entry[0..11], &key) and entry[11] & 0x18 == 0) return entry;
        }
        return error.MissingDosFile;
    }
    pub fn read(self: Floppy, entry: []const u8, output: []u8) Error!void {
        if (output.len != get32(entry, 28)) return error.CorruptDosFile;
        var cluster = get16(entry, 26);
        var position: usize = 0;
        while (position < output.len) {
            if (cluster < 2 or cluster >= 2849) return error.CorruptDosFile;
            const count = @min(512, output.len - position);
            const start = 33 * 512 + (@as(usize, cluster) - 2) * 512;
            @memcpy(output[position..][0..count], self.bytes[start..][0..count]);
            const value = get16(self.bytes, 512 + @as(usize, cluster) * 3 / 2);
            cluster = (if (cluster & 1 != 0) value >> 4 else value) & 0xfff;
            position += count;
        }
        if (cluster < 0xff8) return error.CorruptDosFile;
    }
};

pub const Builder = struct {
    bytes: []u8,
    next_cluster: usize = 2,
    root_count: usize = 0,
    setup_directory: usize = 0,
    setup_count: usize = 0,
    pub fn init(bytes: []u8, boot_sector: []const u8) Error!Builder {
        if (bytes.len != image_size) return error.InvalidDosFloppy;
        return initVolume(bytes, boot_sector);
    }
    pub fn initDisk(bytes: []u8, boot_sector: []const u8, mbr: *const [512]u8, drive: u8) Error!Builder {
        if (bytes.len < 64 * 1024 * 1024 or bytes.len > image_size or (drive != 0x80 and drive != 0x81)) return error.InvalidDosFloppy;
        const hidden = 32;
        @memset(bytes[0..hidden * 512], 0);
        @memcpy(bytes[0..512], mbr);
        @memset(bytes[440..510], 0);
        @memcpy(bytes[446..454], &[_]u8{ 0x80, 1, 1, 0, 6, 15, 0xe0, 0xff });
        put32(bytes, 454, hidden); put32(bytes, 458, @intCast(bytes.len / 512 - hidden));
        put16(bytes, 510, 0xaa55);
        var builder = try initVolume(bytes[hidden * 512..], boot_sector);
        builder.bytes[21] = 0xf8; builder.bytes[36] = drive;
        put32(builder.bytes, 28, hidden);
        @memcpy(builder.bytes[43..54], "USOSDOSRAM ");
        put16(builder.bytes, 512, 0xfff8); put16(builder.bytes, 512 + fat_size, 0xfff8);
        return builder;
    }
    fn initVolume(bytes: []u8, boot_sector: []const u8) Error!Builder {
        if (boot_sector.len < 512 or get16(boot_sector, 510) != 0xaa55) return error.InvalidDosFloppy;
        @memset(bytes, 0);
        @memcpy(bytes[0..512], boot_sector[0..512]);
        put16(bytes, 11, 512); bytes[13] = 16; put16(bytes, 14, 1); bytes[16] = 2;
        put16(bytes, 17, 512); put16(bytes, 19, 0); bytes[21] = 0xf0;
        put16(bytes, 22, 128); put16(bytes, 24, 32); put16(bytes, 26, 16);
        put32(bytes, 28, 0); put32(bytes, 32, @intCast(bytes.len / 512)); bytes[36] = 0;
        @memcpy(bytes[43..54], "USOS98RAM  "); @memcpy(bytes[54..62], "FAT16   ");
        put16(bytes, 512, 0xfff0); put16(bytes, 514, 0xffff);
        put16(bytes, 512 + fat_size, 0xfff0); put16(bytes, 514 + fat_size, 0xffff);
        return .{ .bytes = bytes };
    }
    pub fn reserve(self: *Builder, name: []const u8, size: usize, in_setup: bool) Error![]u8 {
        const entry = if (in_setup) blk: {
            if (self.setup_directory == 0 or self.setup_count >= 1024) return error.DosImageFull;
            const p = self.setup_directory + self.setup_count * 32;
            break :blk p;
        } else blk: {
            if (self.root_count >= 512) return error.DosImageFull;
            const p = root_start + self.root_count * 32;
            break :blk p;
        };
        const result = try self.reserveEntry(name, size, entry);
        if (in_setup) self.setup_count += 1 else self.root_count += 1;
        return result;
    }
    pub fn reserveIn(self: *Builder, name: []const u8, size: usize, directory: *Directory) Error![]u8 {
        if (directory.count >= 1024) return error.DosImageFull;
        const entry = directory.offset + directory.count * 32;
        const result = try self.reserveEntry(name, size, entry);
        directory.count += 1;
        return result;
    }
    fn reserveEntry(self: *Builder, name: []const u8, size: usize, entry: usize) Error![]u8 {
        const key = try shortName(name);
        const count = size / cluster_size + @intFromBool(size % cluster_size != 0);
        const cluster_limit = (self.bytes.len - data_start) / cluster_size + 2;
        if (self.next_cluster > cluster_limit or count > cluster_limit - self.next_cluster) return error.DosImageFull;
        @memcpy(self.bytes[entry..][0..11], &key);
        self.bytes[entry + 11] = 0x20;
        put16(self.bytes, entry + 26, if (count == 0) 0 else @intCast(self.next_cluster));
        put32(self.bytes, entry + 28, @intCast(size));
        const start = data_start + (self.next_cluster - 2) * cluster_size;
        for (self.next_cluster..self.next_cluster + count) |cluster| {
            const next: u16 = if (cluster + 1 < self.next_cluster + count) @intCast(cluster + 1) else 0xffff;
            put16(self.bytes, 512 + cluster * 2, next);
            put16(self.bytes, 512 + fat_size + cluster * 2, next);
        }
        self.next_cluster += count;
        return self.bytes[start..][0..size];
    }
    pub fn add(self: *Builder, name: []const u8, bytes: []const u8) Error!void {
        @memcpy(try self.reserve(name, bytes.len, false), bytes);
    }
    pub fn makeSetupDirectory(self: *Builder) Error!void {
        try self.makeNamedSetupDirectory("WIN98");
    }
    pub fn makeNamedSetupDirectory(self: *Builder, name: []const u8) Error!void {
        const directory = try self.makeDirectory(name, null);
        self.setup_directory = directory.offset;
        self.setup_count = directory.count;
    }
    pub fn makeDirectory(self: *Builder, name: []const u8, parent: ?*Directory) Error!Directory {
        const cluster = self.next_cluster;
        const entry = if (parent) |dir| dir.offset + dir.count * 32 else root_start + self.root_count * 32;
        _ = if (parent) |dir| try self.reserveIn(name, 4 * cluster_size, dir) else try self.reserve(name, 4 * cluster_size, false);
        self.bytes[entry + 11] = 0x10; put32(self.bytes, entry + 28, 0);
        const dot = data_start + (cluster - 2) * cluster_size;
        @memcpy(self.bytes[dot..][0..11], ".          "); self.bytes[dot + 11] = 0x10; put16(self.bytes, dot + 26, @intCast(cluster));
        @memcpy(self.bytes[dot + 32..][0..11], "..         "); self.bytes[dot + 43] = 0x10;
        put16(self.bytes, dot + 58, if (parent) |dir| dir.cluster else 0);
        return .{ .offset = dot, .cluster = @intCast(cluster) };
    }
};

pub fn shortName(name: []const u8) Error![11]u8 {
    var key = [_]u8{' '} ** 11;
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse name.len;
    const ext = if (dot < name.len) name[dot + 1..] else "";
    if (dot == 0 or dot > 8 or ext.len > 3 or std.mem.indexOfScalar(u8, ext, '.') != null) return error.InvalidDosName;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "._-$~!#%&'()@^`{}", c) != null)) return error.InvalidDosName;
    for (name[0..dot], 0..) |c, i| key[i] = std.ascii.toUpper(c);
    for (ext, 0..) |c, i| key[8 + i] = std.ascii.toUpper(c);
    return key;
}
pub fn get16(b: []const u8, o: usize) u16 { return std.mem.readInt(u16, b[o..][0..2], .little); }
pub fn get32(b: []const u8, o: usize) u32 { return std.mem.readInt(u32, b[o..][0..4], .little); }
fn put16(b: []u8, o: usize, v: u16) void { std.mem.writeInt(u16, b[o..][0..2], v, .little); }
fn put32(b: []u8, o: usize, v: u32) void { std.mem.writeInt(u32, b[o..][0..4], v, .little); }

test "DOS names reject traversal and truncation" {
    try std.testing.expectEqualStrings("SETUP   EXE", &(try shortName("setup.exe")));
    try std.testing.expectError(error.InvalidDosName, shortName("../setup.exe"));
    try std.testing.expectError(error.InvalidDosName, shortName("longfilename.exe"));
}
test "FAT12 rejects invalid geometry before reading directories" {
    var bytes = [_]u8{0} ** 512;
    try std.testing.expectError(error.InvalidDosFloppy, Floppy.init(&bytes));
}
test "RAM FAT16 image keeps matching FAT copies and a traversable setup directory" {
    const bytes = try std.testing.allocator.alloc(u8, image_size); defer std.testing.allocator.free(bytes);
    var boot = [_]u8{0} ** 512; put16(&boot, 510, 0xaa55);
    var builder = try Builder.init(bytes, &boot);
    try builder.add("IO.SYS", "kernel");
    try builder.makeSetupDirectory();
    @memcpy(try builder.reserve("SETUP.EXE", 4, true), "test");
    try std.testing.expectEqualSlices(u8, bytes[512..][0..fat_size], bytes[512 + fat_size..][0..fat_size]);
    try std.testing.expectEqualStrings("IO      SYS", bytes[root_start..][0..11]);
    try std.testing.expectEqual(@as(u16, 2), get16(bytes, root_start + 26));
    try std.testing.expectEqual(@as(u16, 3), get16(bytes, builder.setup_directory + 26));
    try std.testing.expectEqualStrings("SETUP   EXE", bytes[builder.setup_directory + 64..][0..11]);
    try std.testing.expectError(error.DosImageFull, builder.reserve("HUGE.BIN", image_size, true));
}

test "MS-DOS hard disk RAM source has a bounded FAT16 volume and nested directories" {
    const bytes = try std.testing.allocator.alloc(u8, image_size); defer std.testing.allocator.free(bytes);
    var boot = [_]u8{0} ** 512; put16(&boot, 510, 0xaa55);
    var builder = try Builder.initDisk(bytes, &boot, &boot, 0x81);
    try builder.add("IO.SYS", "kernel");
    var programs = try builder.makeDirectory("PROGRAMS", null);
    var child = try builder.makeDirectory("DEMO", &programs);
    @memcpy(try builder.reserveIn("HELLO.COM", 3, &child), "exe");
    try std.testing.expectEqual(@as(u32, 32), get32(bytes, 454));
    try std.testing.expectEqual(@as(u32, image_size / 512 - 32), get32(builder.bytes, 32));
    try std.testing.expectEqual(@as(u8, 0x81), builder.bytes[36]);
    try std.testing.expectEqual(@as(u8, 0xf8), builder.bytes[21]);
    try std.testing.expectEqual(programs.cluster, get16(builder.bytes, child.offset + 58));
    try std.testing.expectEqualSlices(u8, builder.bytes[512..][0..fat_size], builder.bytes[512 + fat_size..][0..fat_size]);
    try std.testing.expectError(error.DosImageFull, builder.reserve("HUGE.BIN", image_size, false));
}

test "FreeDOS 64 MiB image remains FAT16 with matching partition size" {
    const bytes = try std.testing.allocator.alloc(u8, 64 * 1024 * 1024); defer std.testing.allocator.free(bytes);
    var boot = [_]u8{0} ** 512; put16(&boot, 510, 0xaa55);
    var builder = try Builder.initDisk(bytes, &boot, &boot, 0x80);
    try builder.add("KERNEL.SYS", "kernel");
    const sectors = get32(bytes, 458);
    try std.testing.expectEqual(@as(u32, 64 * 2048 - 32), sectors);
    try std.testing.expectEqual(sectors, get32(builder.bytes, 32));
    const clusters = (builder.bytes.len - data_start) / cluster_size;
    try std.testing.expect(clusters >= 4085 and clusters < 65525);
}
