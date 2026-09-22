const std = @import("std");

pub const minimum_header_bytes: usize = 0x26C;
pub const boot_flag_magic: u16 = 0xAA55;
pub const header_magic: u32 = 0x53726448; // "HdrS"
pub const minimum_usos_protocol: u16 = 0x020F; // Linux boot protocol 2.15

pub const load_flag_loaded_high: u8 = 1 << 0;
pub const xload_flag_kernel_64: u16 = 1 << 0;

pub const ParseError = error{
    HeaderTooShort,
    InvalidBootFlag,
    MissingHdrS,
    UnsupportedOldProtocol,
    InvalidSetupSize,
};

pub const ImageError = error{
    ProtectedKernelMissing,
};

pub const CompatibilityError = error{
    ProtocolTooOld,
    KernelNotLoadedHigh,
    KernelNotX86_64,
    MissingCommandLineCapacity,
    MissingInitSize,
    MissingInitrdAddressLimit,
};

pub const Header = struct {
    setup_sects_raw: u8,
    setup_sects: u8,
    protected_file_offset: u32,
    syssize_paragraphs: u32,
    vid_mode: u16,
    boot_flag: u16,
    protocol: u16,
    kernel_version_offset: u16,
    type_of_loader: u8,
    loadflags: u8,
    code32_start: u32,
    ramdisk_image: u32,
    ramdisk_size: u32,
    heap_end_ptr: u16,
    cmd_line_ptr: u32,
    initrd_addr_max: u32,
    kernel_alignment: u32,
    relocatable_kernel: bool,
    min_alignment: u8,
    xloadflags: u16,
    cmdline_size: u32,
    hardware_subarch: u32,
    payload_offset: u32,
    payload_length: u32,
    setup_data: u64,
    pref_address: u64,
    init_size: u32,
    handover_offset: u32,
    kernel_info_offset: u32,

    pub fn isLoadedHigh(self: Header) bool {
        return (self.loadflags & load_flag_loaded_high) != 0;
    }

    pub fn isX86_64(self: Header) bool {
        return (self.xloadflags & xload_flag_kernel_64) != 0;
    }

    pub fn protectedBytesFromSyssize(self: Header) u64 {
        return @as(u64, self.syssize_paragraphs) * 16;
    }

    pub fn kernelVersion(self: Header, image: []const u8) ?[]const u8 {
        if (self.kernel_version_offset == 0) return null;
        const start = @as(usize, self.kernel_version_offset) + 0x200;
        if (start >= self.protected_file_offset or start >= image.len) return null;
        const setup_end = @min(@as(usize, self.protected_file_offset), image.len);
        const tail = image[start..setup_end];
        const end = std.mem.indexOfScalar(u8, tail, 0) orelse return null;
        return tail[0..end];
    }
};

pub fn parse(image: []const u8) ParseError!Header {
    if (image.len < minimum_header_bytes) return error.HeaderTooShort;
    const boot_flag = readU16(image, 0x1FE);
    if (boot_flag != boot_flag_magic) return error.InvalidBootFlag;
    if (readU32(image, 0x202) != header_magic) return error.MissingHdrS;

    const protocol = readU16(image, 0x206);
    if (protocol < 0x0200) return error.UnsupportedOldProtocol;

    const setup_raw = image[0x1F1];
    const setup_sects: u8 = if (setup_raw == 0) 4 else setup_raw;
    const protected_offset_u64 = (@as(u64, setup_sects) + 1) * 512;
    if (protected_offset_u64 > std.math.maxInt(u32)) return error.InvalidSetupSize;
    const protected_offset: u32 = @intCast(protected_offset_u64);

    return .{
        .setup_sects_raw = setup_raw,
        .setup_sects = setup_sects,
        .protected_file_offset = protected_offset,
        .syssize_paragraphs = readU32(image, 0x1F4),
        .vid_mode = readU16(image, 0x1FA),
        .boot_flag = boot_flag,
        .protocol = protocol,
        .kernel_version_offset = readU16(image, 0x20E),
        .type_of_loader = image[0x210],
        .loadflags = image[0x211],
        .code32_start = readU32(image, 0x214),
        .ramdisk_image = readU32(image, 0x218),
        .ramdisk_size = readU32(image, 0x21C),
        .heap_end_ptr = readU16(image, 0x224),
        .cmd_line_ptr = readU32(image, 0x228),
        .initrd_addr_max = if (protocol >= 0x0203) readU32(image, 0x22C) else 0x37FFFFFF,
        .kernel_alignment = if (protocol >= 0x0205) readU32(image, 0x230) else 0,
        .relocatable_kernel = protocol >= 0x0205 and image[0x234] != 0,
        .min_alignment = if (protocol >= 0x020A) image[0x235] else 0,
        .xloadflags = if (protocol >= 0x020C) readU16(image, 0x236) else 0,
        .cmdline_size = if (protocol >= 0x0206) readU32(image, 0x238) else 255,
        .hardware_subarch = if (protocol >= 0x0207) readU32(image, 0x23C) else 0,
        .payload_offset = if (protocol >= 0x0208) readU32(image, 0x248) else 0,
        .payload_length = if (protocol >= 0x0208) readU32(image, 0x24C) else 0,
        .setup_data = if (protocol >= 0x0209) readU64(image, 0x250) else 0,
        .pref_address = if (protocol >= 0x020A) readU64(image, 0x258) else 0,
        .init_size = if (protocol >= 0x020A) readU32(image, 0x260) else 0,
        .handover_offset = if (protocol >= 0x020B) readU32(image, 0x264) else 0,
        .kernel_info_offset = if (protocol >= minimum_usos_protocol) readU32(image, 0x268) else 0,
    };
}

pub fn validateImageSize(header: Header, image_size: u64) ImageError!void {
    if (image_size <= header.protected_file_offset) return error.ProtectedKernelMissing;
}

pub fn validateForUsosMicroLinux(header: Header) CompatibilityError!void {
    if (header.protocol < minimum_usos_protocol) return error.ProtocolTooOld;
    if (!header.isLoadedHigh()) return error.KernelNotLoadedHigh;
    if (!header.isX86_64()) return error.KernelNotX86_64;
    if (header.cmdline_size == 0) return error.MissingCommandLineCapacity;
    if (header.init_size == 0) return error.MissingInitSize;
    if (header.initrd_addr_max == 0) return error.MissingInitrdAddressLimit;
}

fn readU16(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) |
        (@as(u16, bytes[offset + 1]) << 8);
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, readU16(bytes, offset)) |
        (@as(u32, readU16(bytes, offset + 2)) << 16);
}

fn readU64(bytes: []const u8, offset: usize) u64 {
    return @as(u64, readU32(bytes, offset)) |
        (@as(u64, readU32(bytes, offset + 4)) << 32);
}

fn putU16(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
}

fn putU32(bytes: []u8, offset: usize, value: u32) void {
    putU16(bytes, offset, @truncate(value));
    putU16(bytes, offset + 2, @truncate(value >> 16));
}

fn putU64(bytes: []u8, offset: usize, value: u64) void {
    putU32(bytes, offset, @truncate(value));
    putU32(bytes, offset + 4, @truncate(value >> 32));
}

test "parse Linux boot protocol 2.15 setup header" {
    var image = [_]u8{0} ** 0x5000;
    image[0x1F1] = 31;
    putU32(&image, 0x1F4, 0x12345);
    putU16(&image, 0x1FA, 0xFFFF);
    putU16(&image, 0x1FE, boot_flag_magic);
    putU32(&image, 0x202, header_magic);
    putU16(&image, 0x206, 0x020F);
    putU16(&image, 0x20E, 0x0100);
    image[0x211] = load_flag_loaded_high;
    putU32(&image, 0x214, 0x00100000);
    putU32(&image, 0x22C, 0x7FFFFFFF);
    putU32(&image, 0x230, 0x01000000);
    image[0x234] = 1;
    image[0x235] = 21;
    putU16(&image, 0x236, 0x007B);
    putU32(&image, 0x238, 2047);
    putU64(&image, 0x258, 0x01000000);
    putU32(&image, 0x260, 39_862_272);
    putU32(&image, 0x268, 0x00BF81C0);
    @memcpy(image[0x300..0x30A], "6.18-test\x00");

    const header = try parse(&image);
    try validateImageSize(header, image.len);
    try validateForUsosMicroLinux(header);
    try std.testing.expectEqual(@as(u8, 31), header.setup_sects);
    try std.testing.expectEqual(@as(u32, 16_384), header.protected_file_offset);
    try std.testing.expectEqual(@as(u16, 0x020F), header.protocol);
    try std.testing.expectEqual(@as(u32, 0x00100000), header.code32_start);
    try std.testing.expectEqual(@as(u32, 0x7FFFFFFF), header.initrd_addr_max);
    try std.testing.expectEqual(@as(u32, 0x01000000), header.kernel_alignment);
    try std.testing.expect(header.relocatable_kernel);
    try std.testing.expect(header.isX86_64());
    try std.testing.expectEqual(@as(u32, 2047), header.cmdline_size);
    try std.testing.expectEqual(@as(u64, 0x01000000), header.pref_address);
    try std.testing.expectEqual(@as(u32, 39_862_272), header.init_size);
    try std.testing.expectEqualStrings("6.18-test", header.kernelVersion(&image).?);
}

test "parser needs only setup header bytes before loading protected kernel" {
    var bytes = [_]u8{0} ** minimum_header_bytes;
    bytes[0x1F1] = 31;
    putU16(&bytes, 0x1FE, boot_flag_magic);
    putU32(&bytes, 0x202, header_magic);
    putU16(&bytes, 0x206, 0x020F);

    const header = try parse(&bytes);
    try std.testing.expectEqual(@as(u32, 16_384), header.protected_file_offset);
    try std.testing.expectError(error.ProtectedKernelMissing, validateImageSize(header, bytes.len));
    try validateImageSize(header, 12_575_744);
}

test "setup_sects zero means four sectors" {
    var image = [_]u8{0} ** 4096;
    putU16(&image, 0x1FE, boot_flag_magic);
    putU32(&image, 0x202, header_magic);
    putU16(&image, 0x206, 0x020F);
    image[0x211] = load_flag_loaded_high;
    putU16(&image, 0x236, xload_flag_kernel_64);
    putU32(&image, 0x238, 2047);
    putU32(&image, 0x22C, 0x7FFFFFFF);
    putU32(&image, 0x260, 1024);

    const header = try parse(&image);
    try std.testing.expectEqual(@as(u8, 4), header.setup_sects);
    try std.testing.expectEqual(@as(u32, 2560), header.protected_file_offset);
}

test "USOS rejects 32-bit-only kernel while parser still parses it" {
    var image = [_]u8{0} ** 0x5000;
    image[0x1F1] = 31;
    putU16(&image, 0x1FE, boot_flag_magic);
    putU32(&image, 0x202, header_magic);
    putU16(&image, 0x206, 0x020F);
    image[0x211] = load_flag_loaded_high;
    putU32(&image, 0x22C, 0x7FFFFFFF);
    putU32(&image, 0x238, 2047);
    putU32(&image, 0x260, 1024);

    const header = try parse(&image);
    try std.testing.expectError(error.KernelNotX86_64, validateForUsosMicroLinux(header));
}
