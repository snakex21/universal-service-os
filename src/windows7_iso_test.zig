// Synthetic, non-bootable UDF/WIM fixtures exercise the production reader.
// No filesystem mounts, physical disks or installer processes are involved.
const std = @import("std");
const scanner = @import("windows7_iso.zig");
const Reader = @import("image_probe/random_access.zig").SliceReader;
const config = @import("platform/bios/windows_iso_config.zig");
const block = 2048;
const allocator = std.testing.allocator;
const win7_rtm = "<IMAGE INDEX=\"1\"><ARCH>9</ARCH><MAJOR>6</MAJOR><MINOR>1</MINOR><BUILD>7600</BUILD></IMAGE>";
const win7_sp1 = "<IMAGE INDEX=\"1\"><ARCH>9</ARCH><MAJOR>6</MAJOR><MINOR>1</MINOR><BUILD>7601</BUILD></IMAGE>";
const win10 = "<IMAGE INDEX=\"2\"><ARCH>9</ARCH><MAJOR>10</MAJOR><MINOR>0</MINOR><BUILD>19045</BUILD></IMAGE>";
const win7_x86 = "<IMAGE INDEX=\"2\"><ARCH>0</ARCH><MAJOR>6</MAJOR><MINOR>1</MINOR><BUILD>7601</BUILD></IMAGE>";

fn sector(image: []u8, n: usize) []u8 {
    return image[n * block ..][0..block];
}
fn longAd(dest: []u8, logical: u32) void {
    std.mem.writeInt(u32, dest[0..4], block, .little);
    std.mem.writeInt(u32, dest[4..8], logical, .little);
}
fn fileEntry(dest: []u8, dir: bool, size: usize, data: u32) void {
    std.mem.writeInt(u16, dest[0..2], 261, .little);
    dest[27] = if (dir) 4 else 5;
    std.mem.writeInt(u64, dest[56..64], size, .little);
    std.mem.writeInt(u32, dest[172..176], 8, .little);
    std.mem.writeInt(u32, dest[176..180], @intCast(size), .little);
    std.mem.writeInt(u32, dest[180..184], data, .little);
}
fn fid(dest: []u8, name: []const u8, dir: bool, logical: u32) usize {
    const len = std.mem.alignForward(usize, 39 + name.len, 4);
    std.mem.writeInt(u16, dest[0..2], 257, .little);
    std.mem.writeInt(u16, dest[16..18], 1, .little);
    dest[18] = if (dir) 2 else 0;
    dest[19] = @intCast(name.len + 1);
    longAd(dest[20..36], logical);
    dest[38] = 8;
    @memcpy(dest[39..][0..name.len], name);
    return len;
}
fn wimFile(dest: []u8, text: []const u8, count: u32, index: u32) void {
    const size = 2 + text.len * 2;
    @memcpy(dest[0..8], "MSWIM\x00\x00\x00");
    std.mem.writeInt(u32, dest[44..48], count, .little);
    std.mem.writeInt(u64, dest[72..80], 0x0200000000000000 | size, .little);
    std.mem.writeInt(u64, dest[80..88], 124, .little);
    std.mem.writeInt(u64, dest[88..96], size, .little);
    std.mem.writeInt(u32, dest[120..124], index, .little);
    dest[124] = 0xff;
    dest[125] = 0xfe;
    for (text, 0..) |ch, i| dest[126 + i * 2] = ch;
}
const Options = struct {
    major: u32 = 6,
    minor: u32 = 1,
    build: u32 = 7601,
    arch: u32 = 9,
    index: u32 = 2,
    install: []const u8 = win7_sp1,
    install_count: u32 = 1,
    has_sdi: bool = true,
    has_setup: bool = true,
    esd: bool = false,
    boot_xml: ?[]const u8 = null,
};
fn fixture(options: Options) ![]u8 {
    const image = try allocator.alloc(u8, 320 * block);
    errdefer allocator.free(image);
    @memset(image, 0);
    @memcpy(sector(image, 16)[1..6], "NSR03");
    const anchor = sector(image, 256);
    std.mem.writeInt(u16, anchor[0..2], 2, .little);
    std.mem.writeInt(u32, anchor[16..20], 4 * block, .little);
    std.mem.writeInt(u32, anchor[20..24], 257, .little);
    const partition = sector(image, 257);
    std.mem.writeInt(u16, partition[0..2], 5, .little);
    std.mem.writeInt(u32, partition[188..192], 300, .little);
    const lvd = sector(image, 258);
    std.mem.writeInt(u16, lvd[0..2], 6, .little);
    std.mem.writeInt(u32, lvd[212..216], block, .little);
    longAd(lvd[248..264], 1);
    std.mem.writeInt(u32, lvd[264..268], 6, .little);
    std.mem.writeInt(u32, lvd[268..272], 1, .little);
    lvd[440] = 1;
    lvd[441] = 6;
    std.mem.writeInt(u16, lvd[442..444], 1, .little);
    std.mem.writeInt(u16, sector(image, 259)[0..2], 8, .little);
    const fsd = sector(image, 301);
    std.mem.writeInt(u16, fsd[0..2], 256, .little);
    longAd(fsd[400..416], 2);
    var len = fid(sector(image, 303), "sources", true, 4);
    len += fid(sector(image, 303)[len..], "boot", true, 6);
    fileEntry(sector(image, 302), true, len, 3);
    len = fid(sector(image, 305), "boot.wim", false, 8);
    if (options.has_setup) len += fid(sector(image, 305)[len..], "setup.exe", false, 10);
    len += fid(sector(image, 305)[len..], if (options.esd) "install.esd" else "install.wim", false, 12);
    fileEntry(sector(image, 304), true, len, 5);
    len = fid(sector(image, 307), "bcd", false, 14);
    if (options.has_sdi) len += fid(sector(image, 307)[len..], "boot.sdi", false, 16);
    fileEntry(sector(image, 306), true, len, 7);
    for ([_]usize{ 308, 310, 312, 314, 316 }) |n| fileEntry(sector(image, n), false, block, @intCast(n + 1 - 300));
    var ascii: [900]u8 = undefined;
    // Index 1 is deliberately x86: only the header-declared Setup index counts.
    const boot = try std.fmt.bufPrint(&ascii, "<WIM><IMAGE INDEX=\"1\"><ARCH>0</ARCH><MAJOR>6</MAJOR><MINOR>1</MINOR></IMAGE><IMAGE INDEX=\"2\"><WINDOWS><ARCH>{d}</ARCH><VERSION><MAJOR>{d}</MAJOR><MINOR>{d}</MINOR><BUILD>{d}</BUILD></VERSION></WINDOWS></IMAGE></WIM>", .{options.arch, options.major, options.minor, options.build});
    wimFile(sector(image, 309), options.boot_xml orelse boot, 2, options.index);
    const install = try std.fmt.bufPrint(&ascii, "<WIM>{s}</WIM>", .{options.install});
    wimFile(sector(image, 313), install, options.install_count, 0);
    return image;
}

test "production UDF scanner distinguishes original RTM SP1 and hybrid without filenames" {
    for ([_]Options{
        .{ .install = win7_rtm }, .{},
        .{ .major = 10, .minor = 0, .build = 19041 },
        .{ .major = 6, .minor = 3, .build = 9600, .install = win7_rtm },
    }) |options| {
        const image = try fixture(options);
        defer allocator.free(image);
        var reader = Reader{ .bytes = image };
        const before = std.hash.Wyhash.hash(0, image);
        const result = try scanner.inspectSelected(allocator, &reader);
        const expected_mode: @import("image_probe/wim_setup.zig").Win7Mode = if (options.minor == 1) .original else .hybrid;
        try std.testing.expectEqual(expected_mode, result.mode);
        try std.testing.expectEqual(std.mem.eql(u8, options.install, win7_sp1), result.nvme_packages);
        try std.testing.expectEqual(options.build, result.selected_setup.build);
        try std.testing.expectEqual(@as(u32, 2), result.boot_setup.index);
        try std.testing.expectEqual(before, std.hash.Wyhash.hash(0, image));
    }
}

test "production scanner rejects mixed editions x86 and incomplete WIM metadata" {
    for ([_]Options{
        .{ .install = win7_sp1 ++ win10, .install_count = 2 },
        .{ .install = win7_sp1 ++ win7_x86, .install_count = 2 },
        .{ .install = win7_sp1 ++ "<IMAGE INDEX=\"2\"><ARCH>9</ARCH><MAJOR>6</MAJOR><MINOR>0</MINOR><BUILD>6002</BUILD></IMAGE>", .install_count = 2 },
        .{ .install = "" },
    }) |options| {
        const image = try fixture(options);
        defer allocator.free(image);
        var reader = Reader{ .bytes = image };
        try std.testing.expectError(error.UnsupportedWindows7InstallTarget, scanner.inspectSelected(allocator, &reader));
    }
    const image = try fixture(.{ .install_count = 2 });
    defer allocator.free(image);
    var reader = Reader{ .bytes = image };
    try std.testing.expectError(error.InvalidWimXml, scanner.inspectSelected(allocator, &reader));
    // Oversized XML must fail before allocation or any out-of-resource read.
    std.mem.writeInt(u64, sector(image, 309)[88..96], 1024 * 1024 + 2, .little);
    try std.testing.expectError(error.InvalidWimXml, scanner.setupInfo(allocator, &reader));
}

test "donor optical metadata rejects PE7 PE8 Windows11 x86 missing SDI and bad index" {
    const Case = struct { options: Options, err: anyerror };
    for ([_]Case{
        .{ .options = .{}, .err = error.Windows10PeDonorWrongVersion },
        .{ .options = .{ .minor = 3, .build = 9600 }, .err = error.Windows10PeDonorWrongVersion },
        .{ .options = .{ .major = 10, .minor = 0, .build = 22000 }, .err = error.Windows10PeDonorWrongVersion },
        .{ .options = .{ .major = 10, .minor = 0, .build = 0 }, .err = error.Windows10PeDonorWrongVersion },
        .{ .options = .{ .major = 10, .minor = 0, .build = 19041, .arch = 0 }, .err = error.WindowsSetupRequiresX64 },
        .{ .options = .{ .major = 10, .minor = 0, .build = 19041, .has_sdi = false }, .err = error.InvalidWindowsBootFile },
        .{ .options = .{ .major = 10, .minor = 0, .build = 19041, .has_setup = false }, .err = error.WindowsSetupMissing },
        .{ .options = .{ .index = 0 }, .err = error.WindowsSetupIndexMissing },
        .{ .options = .{ .index = 3 }, .err = error.WindowsSetupIndexMissing },
        .{ .options = .{ .index = 1 }, .err = error.WindowsSetupRequiresX64 },
    }) |case| {
        const image = try fixture(case.options);
        defer allocator.free(image);
        var reader = Reader{ .bytes = image };
        try std.testing.expectError(case.err, scanner.inspectDonor(allocator, &reader));
    }
}

const OpticalDirectory = struct {
    reader: Reader,
    pub fn probeDonor(self: *OpticalDirectory, name: []const u8) !@import("image_probe/wim_setup.zig").Setup {
        try std.testing.expectEqualStrings("renamed-not-windows.ISO", name);
        return scanner.inspectDonor(allocator, &self.reader);
    }
    fn list(_: *anyopaque, _: []const u8, out: []@import("catalog/directory_source.zig").Entry) !usize {
        out[0] = .{};
        const name = "renamed-not-windows.ISO";
        @memcpy(out[0].name.bytes[0..name.len], name);
        out[0].name.len = name.len;
        return 1;
    }
};

test "renamed optical donor resolves separately while install config keeps selected Win7 ISO" {
    const image = try fixture(.{});
    defer allocator.free(image);
    const donor = try fixture(.{ .major = 10, .minor = 0, .build = 19041 });
    defer allocator.free(donor);
    const before = std.hash.Wyhash.hash(0, image);
    const donor_before = std.hash.Wyhash.hash(0, donor);
    var reader = Reader{ .bytes = image };
    const selected = try scanner.inspectSelected(allocator, &reader);
    var context = OpticalDirectory{ .reader = .{ .bytes = donor } };
    const resolved = try scanner.resolveDonor(selected, .{ .context = &context, .list_fn = OpticalDirectory.list }, &context);
    try std.testing.expectEqualStrings("renamed-not-windows.ISO", resolved.bootName("renamed-original.iso"));
    try std.testing.expectEqual(@as(u32, 19041), resolved.boot_setup.build);
    try std.testing.expectEqual(@as(u32, 7601), resolved.selected_setup.build);
    var bytes: [544]u8 = undefined;
    const encoded = try config.sourceConfigForFolder(&bytes, [_]u8{0x47} ** 16, image.len, "Windows 7", "renamed-original.iso");
    try std.testing.expectEqualStrings("Systems\\Windows\\Windows 7\\Images\\renamed-original.iso\x00", encoded[32..]);
    try std.testing.expectEqual(@as(u64, image.len), std.mem.readInt(u64, encoded[24..32], .little));
    // Alternating positional readers must not retarget the selected ISO or
    // return slices into the temporary XML allocation released by inspection.
    try std.testing.expectEqual(@as(u32, 7601), (try scanner.inspectSelected(allocator, &reader)).selected_setup.build);
    try std.testing.expectEqual(@as(u32, 19041), (try scanner.inspectDonor(allocator, &context.reader)).build);
    try std.testing.expectEqual(before, std.hash.Wyhash.hash(0, image));
    try std.testing.expectEqual(donor_before, std.hash.Wyhash.hash(0, donor));
}

test "all install IMAGE entries must have valid unique contiguous indices" {
    for ([_]Options{
        .{ .install = win7_sp1 ++ win7_sp1, .install_count = 2 },
        .{ .install = "<IMAGE><ARCH>9</ARCH><MAJOR>6</MAJOR><MINOR>1</MINOR></IMAGE>" ++ win7_sp1 },
        .{ .install = win7_sp1 ++ "<IMAGE INDEX=\"3\"><ARCH>9</ARCH><MAJOR>6</MAJOR><MINOR>1</MINOR></IMAGE>", .install_count = 2 },
        .{ .install = win7_sp1 ++ "<IMAGE INDEX='2'><ARCH>0</ARCH><MAJOR>6</MAJOR><MINOR>1</MINOR></IMAGE>" },
        .{ .install = "<IMAGE INDEX=\"1\"><ARCH>9</ARCH><MAJOR>6</MAJOR><MINOR>1</MINOR>" ++ win7_x86 },
    }) |options| {
        const image = try fixture(options);
        defer allocator.free(image);
        var reader = Reader{ .bytes = image };
        try std.testing.expectError(error.InvalidWimXml, scanner.inspectSelected(allocator, &reader));
    }
    const image = try fixture(.{ .install = win7_sp1 ++ "<IMAGE INDEX=\"2\"><ARCH>9</ARCH><MAJOR>6</MAJOR><MINOR>1</MINOR><BUILD>7600</BUILD></IMAGE>", .install_count = 2 });
    defer allocator.free(image);
    var reader = Reader{ .bytes = image };
    const result = try scanner.inspectSelected(allocator, &reader);
    try std.testing.expectEqual(.original, result.mode);
    try std.testing.expect(!result.nvme_packages);
}

test "declared boot IMAGE cannot be nested duplicated or absent" {
    const pe = "<IMAGE INDEX=\"2\"><ARCH>9</ARCH><MAJOR>10</MAJOR><MINOR>0</MINOR><BUILD>19041</BUILD></IMAGE>";
    const Case = struct { xml: []const u8, err: anyerror };
    for ([_]Case{
        .{ .xml = "<WIM>" ++ pe ++ pe ++ "</WIM>", .err = error.InvalidWimXml },
        .{ .xml = "<WIM><IMAGE INDEX=\"2\"><ARCH>9</ARCH><MAJOR>10</MAJOR><MINOR>0</MINOR><BUILD>19041</BUILD>" ++ win7_sp1 ++ "</WIM>", .err = error.InvalidWimXml },
        .{ .xml = "<WIM>" ++ win7_sp1 ++ "</WIM>", .err = error.WindowsSetupIndexMissing },
    }) |case| {
        const image = try fixture(.{ .boot_xml = case.xml });
        defer allocator.free(image);
        var reader = Reader{ .bytes = image };
        try std.testing.expectError(case.err, scanner.inspectDonor(allocator, &reader));
    }
}

test "hybrid requires own Setup and boot resources; ESD does not imply identity" {
    for ([_]bool{ false, true }) |modern| {
        const image = try fixture(.{ .major = if (modern) 10 else 6, .minor = if (modern) 0 else 1, .has_setup = false });
        defer allocator.free(image);
        var reader = Reader{ .bytes = image };
        try std.testing.expectError(error.WindowsSetupMissing, scanner.inspectSelected(allocator, &reader));
    }
    const original_esd = try fixture(.{ .esd = true });
    defer allocator.free(original_esd);
    var original_reader = Reader{ .bytes = original_esd };
    try std.testing.expectError(error.Windows7OriginalRequiresInstallWim, scanner.inspectSelected(allocator, &original_reader));
    const hybrid_esd = try fixture(.{ .major = 10, .minor = 0, .build = 19041, .esd = true });
    defer allocator.free(hybrid_esd);
    var hybrid_reader = Reader{ .bytes = hybrid_esd };
    try std.testing.expectEqual(.hybrid, (try scanner.inspectSelected(allocator, &hybrid_reader)).mode);
    const incomplete = try fixture(.{ .major = 10, .minor = 0, .build = 19041, .has_sdi = false });
    defer allocator.free(incomplete);
    var incomplete_reader = Reader{ .bytes = incomplete };
    try std.testing.expectError(error.InvalidWindowsBootFile, scanner.inspectSelected(allocator, &incomplete_reader));
}

test "scanner releases temporary metadata on allocation failure" {
    const image = try fixture(.{});
    defer allocator.free(image);
    var reader = Reader{ .bytes = image };
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, scanner.inspectSelected(failing.allocator(), &reader));
}
