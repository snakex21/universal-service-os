//! Minimal PE32+ image loader: header layout, section copy and base
//! relocation. Used to start an already verified UEFI boot-service driver
//! when the firmware LoadImage is replaced by shim's application-only loader
//! (shim 16 frees an image as soon as its entry point returns, which would
//! unload a driver's protocol code).
const std = @import("std");

pub const Error = error{
    NotPe,
    UnsupportedFormat,
    Truncated,
    BadSection,
    BadRelocation,
    DestinationTooSmall,
};

pub const Layout = struct {
    size_of_image: u32,
    size_of_headers: u32,
    entry_rva: u32,
    preferred_base: u64,
    subsystem: u16,
    reloc_rva: u32,
    reloc_size: u32,
    section_table: usize,
    section_count: u16,
};

pub const subsystem_efi_application: u16 = 10;
pub const subsystem_efi_boot_service_driver: u16 = 11;

fn read16(bytes: []const u8, offset: usize) Error!u16 {
    if (offset + 2 > bytes.len) return error.Truncated;
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn read32(bytes: []const u8, offset: usize) Error!u32 {
    if (offset + 4 > bytes.len) return error.Truncated;
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn read64(bytes: []const u8, offset: usize) Error!u64 {
    if (offset + 8 > bytes.len) return error.Truncated;
    return std.mem.readInt(u64, bytes[offset..][0..8], .little);
}

pub fn parse(image: []const u8) Error!Layout {
    if (image.len < 0x40 or image[0] != 'M' or image[1] != 'Z') return error.NotPe;
    const pe = try read32(image, 0x3c);
    if (pe + 24 > image.len or !std.mem.eql(u8, image[pe..][0..4], "PE\x00\x00")) return error.NotPe;
    const section_count = try read16(image, pe + 6);
    const optional_size = try read16(image, pe + 20);
    const opt = pe + 24;
    if (try read16(image, opt) != 0x20b) return error.UnsupportedFormat;
    if (optional_size < 112 + 6 * 8) return error.UnsupportedFormat;
    if (try read32(image, opt + 108) < 6) return error.UnsupportedFormat;
    const layout = Layout{
        .size_of_image = try read32(image, opt + 56),
        .size_of_headers = try read32(image, opt + 60),
        .entry_rva = try read32(image, opt + 16),
        .preferred_base = try read64(image, opt + 24),
        .subsystem = try read16(image, opt + 68),
        .reloc_rva = try read32(image, opt + 112 + 5 * 8),
        .reloc_size = try read32(image, opt + 112 + 5 * 8 + 4),
        .section_table = opt + optional_size,
        .section_count = section_count,
    };
    if (layout.size_of_headers > image.len or layout.size_of_headers > layout.size_of_image) return error.Truncated;
    if (layout.section_table + @as(usize, section_count) * 40 > layout.size_of_headers) return error.BadSection;
    if (layout.entry_rva >= layout.size_of_image) return error.UnsupportedFormat;
    return layout;
}

/// Copies headers and sections of `image` into `destination` (at least
/// size_of_image bytes, zero-filled beyond raw data) and applies base
/// relocations for `load_address`.
pub fn load(image: []const u8, layout: Layout, destination: []u8, load_address: u64) Error!void {
    if (destination.len < layout.size_of_image) return error.DestinationTooSmall;
    @memset(destination[0..layout.size_of_image], 0);
    @memcpy(destination[0..layout.size_of_headers], image[0..layout.size_of_headers]);
    var index: usize = 0;
    while (index < layout.section_count) : (index += 1) {
        const header = layout.section_table + index * 40;
        const virtual_size = try read32(image, header + 8);
        const virtual_address = try read32(image, header + 12);
        const raw_size = try read32(image, header + 16);
        const raw_pointer = try read32(image, header + 20);
        const copy = @min(raw_size, if (virtual_size == 0) raw_size else virtual_size);
        if (@as(u64, virtual_address) + @max(virtual_size, copy) > layout.size_of_image) return error.BadSection;
        if (copy == 0) continue;
        if (@as(u64, raw_pointer) + copy > image.len) return error.BadSection;
        @memcpy(destination[virtual_address..][0..copy], image[raw_pointer..][0..copy]);
    }
    try relocate(destination[0..layout.size_of_image], layout, load_address -% layout.preferred_base);
}

fn relocate(memory: []u8, layout: Layout, delta: u64) Error!void {
    if (layout.reloc_size == 0) {
        if (delta != 0) return error.BadRelocation;
        return;
    }
    if (@as(u64, layout.reloc_rva) + layout.reloc_size > memory.len) return error.BadRelocation;
    var block = layout.reloc_rva;
    const end = layout.reloc_rva + layout.reloc_size;
    while (block + 8 <= end) {
        const page = try read32(memory, block);
        const block_size = try read32(memory, block + 4);
        if (block_size < 8 or block + block_size > end) return error.BadRelocation;
        var entry = block + 8;
        while (entry + 2 <= block + block_size) : (entry += 2) {
            const value = try read16(memory, entry);
            const target = @as(usize, page) + (value & 0x0fff);
            switch (value >> 12) {
                0 => {},
                3 => {
                    if (target + 4 > memory.len) return error.BadRelocation;
                    const old = std.mem.readInt(u32, memory[target..][0..4], .little);
                    std.mem.writeInt(u32, memory[target..][0..4], old +% @as(u32, @truncate(delta)), .little);
                },
                10 => {
                    if (target + 8 > memory.len) return error.BadRelocation;
                    const old = std.mem.readInt(u64, memory[target..][0..8], .little);
                    std.mem.writeInt(u64, memory[target..][0..8], old +% delta, .little);
                },
                else => return error.BadRelocation,
            }
        }
        block += block_size;
    }
}

fn testImage(buffer: []u8) void {
    @memset(buffer, 0);
    buffer[0] = 'M';
    buffer[1] = 'Z';
    std.mem.writeInt(u32, buffer[0x3c..][0..4], 0x40, .little);
    @memcpy(buffer[0x40..][0..4], "PE\x00\x00");
    std.mem.writeInt(u16, buffer[0x46..][0..2], 2, .little); // sections
    std.mem.writeInt(u16, buffer[0x54..][0..2], 240, .little); // optional header size
    const opt: usize = 0x58;
    std.mem.writeInt(u16, buffer[opt..][0..2], 0x20b, .little);
    std.mem.writeInt(u32, buffer[opt + 16 ..][0..4], 0x1000, .little); // entry
    std.mem.writeInt(u64, buffer[opt + 24 ..][0..8], 0x400000, .little); // base
    std.mem.writeInt(u32, buffer[opt + 56 ..][0..4], 0x3000, .little); // size of image
    std.mem.writeInt(u32, buffer[opt + 60 ..][0..4], 0x200, .little); // headers
    std.mem.writeInt(u16, buffer[opt + 68 ..][0..2], subsystem_efi_boot_service_driver, .little);
    std.mem.writeInt(u32, buffer[opt + 108 ..][0..4], 16, .little);
    std.mem.writeInt(u32, buffer[opt + 112 + 40 ..][0..4], 0x2000, .little); // reloc rva
    std.mem.writeInt(u32, buffer[opt + 112 + 44 ..][0..4], 12, .little); // reloc size
    const sections: usize = opt + 240;
    // .text: raw 0x200..0x400 -> rva 0x1000, holds a pointer to rva 0x1010.
    std.mem.writeInt(u32, buffer[sections + 8 ..][0..4], 0x200, .little);
    std.mem.writeInt(u32, buffer[sections + 12 ..][0..4], 0x1000, .little);
    std.mem.writeInt(u32, buffer[sections + 16 ..][0..4], 0x200, .little);
    std.mem.writeInt(u32, buffer[sections + 20 ..][0..4], 0x200, .little);
    std.mem.writeInt(u64, buffer[0x208..][0..8], 0x401010, .little);
    // .reloc: raw 0x400.. -> rva 0x2000: one DIR64 at page 0x1000 offset 8.
    std.mem.writeInt(u32, buffer[sections + 48 ..][0..4], 12, .little);
    std.mem.writeInt(u32, buffer[sections + 52 ..][0..4], 0x2000, .little);
    std.mem.writeInt(u32, buffer[sections + 56 ..][0..4], 0x200, .little);
    std.mem.writeInt(u32, buffer[sections + 60 ..][0..4], 0x400, .little);
    std.mem.writeInt(u32, buffer[0x400..][0..4], 0x1000, .little);
    std.mem.writeInt(u32, buffer[0x404..][0..4], 12, .little);
    std.mem.writeInt(u16, buffer[0x408..][0..2], (10 << 12) | 8, .little);
    std.mem.writeInt(u16, buffer[0x40a..][0..2], 0, .little);
}

test "loads sections and applies DIR64 relocations for the load address" {
    var image: [0x600]u8 = undefined;
    testImage(&image);
    const layout = try parse(&image);
    try std.testing.expectEqual(@as(u32, 0x3000), layout.size_of_image);
    try std.testing.expectEqual(subsystem_efi_boot_service_driver, layout.subsystem);
    var memory: [0x3000]u8 = undefined;
    try load(&image, layout, &memory, 0x7f00_0000);
    try std.testing.expectEqual(@as(u64, 0x7f00_1010), std.mem.readInt(u64, memory[0x1008..][0..8], .little));
    try std.testing.expectEqual(@as(u8, 'M'), memory[0]);
}

test "rejects truncated or unsupported images" {
    var image: [0x600]u8 = undefined;
    testImage(&image);
    try std.testing.expectError(error.NotPe, parse(image[0..0x20]));
    image[0x58] = 0x0b; // PE32 magic 0x10b
    image[0x59] = 0x01;
    try std.testing.expectError(error.UnsupportedFormat, parse(&image));
}

test "rejects relocation entries outside the image" {
    var image: [0x600]u8 = undefined;
    testImage(&image);
    std.mem.writeInt(u32, image[0x400..][0..4], 0x2ff8, .little);
    const layout = try parse(&image);
    var memory: [0x3000]u8 = undefined;
    try std.testing.expectError(error.BadRelocation, load(&image, layout, &memory, 0x7f00_0000));
}
