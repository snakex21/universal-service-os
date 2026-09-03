const Header = @import("mz_header.zig").Header;
const Registers = @import("registers.zig").Registers;

pub const Plan = struct {
    psp_segment: u16,
    load_segment: u16,
    file_image_offset: usize,
    image_size: usize,
    relocation_count: usize,
    min_allocation_paragraphs: usize,
    max_allocation_paragraphs: usize,
    registers: Registers,
};

pub fn plan(psp_segment: u16, header: Header) !Plan {
    const image_paragraphs = header.imageParagraphs();
    const base_paragraphs = 0x10 + image_paragraphs;
    const min_allocation = base_paragraphs + header.min_extra_paragraphs;
    const max_allocation = if (header.max_extra_paragraphs == 0xFFFF)
        @as(usize, 0xFFFF)
    else
        base_paragraphs + header.max_extra_paragraphs;

    if (min_allocation > 0xFFFF) return error.ImageTooLarge;

    const load_segment = psp_segment +% 0x10;
    return .{
        .psp_segment = psp_segment,
        .load_segment = load_segment,
        .file_image_offset = header.headerSizeBytes(),
        .image_size = header.imageSizeBytes(),
        .relocation_count = header.relocation_count,
        .min_allocation_paragraphs = min_allocation,
        .max_allocation_paragraphs = max_allocation,
        .registers = .{
            .ip = header.initial_ip,
            .sp = header.initial_sp,
            .cs = load_segment +% header.initial_cs,
            .ss = load_segment +% header.initial_ss,
            .ds = psp_segment,
            .es = psp_segment,
        },
    };
}

test "MZ entry registers are relocated from image load segment" {
    const std = @import("std");
    const header = Header{
        .signature = 0x5A4D,
        .bytes_last_page = 64,
        .pages = 1,
        .relocation_count = 2,
        .header_paragraphs = 2,
        .min_extra_paragraphs = 4,
        .max_extra_paragraphs = 8,
        .initial_ss = 3,
        .initial_sp = 0x0200,
        .checksum = 0,
        .initial_ip = 0x0010,
        .initial_cs = 1,
        .relocation_table_offset = 0x1C,
        .overlay_number = 0,
    };

    const result = try plan(0x1000, header);
    try std.testing.expectEqual(@as(u16, 0x1011), result.registers.cs);
    try std.testing.expectEqual(@as(u16, 0x1013), result.registers.ss);
    try std.testing.expectEqual(@as(u16, 0x1000), result.registers.ds);
    try std.testing.expectEqual(@as(usize, 0x10 + 2 + 4), result.min_allocation_paragraphs);
}
