const std = @import("std");

pub const Header = struct {
    signature: u16,
    bytes_last_page: u16,
    pages: u16,
    relocation_count: u16,
    header_paragraphs: u16,
    min_extra_paragraphs: u16,
    max_extra_paragraphs: u16,
    initial_ss: u16,
    initial_sp: u16,
    checksum: u16,
    initial_ip: u16,
    initial_cs: u16,
    relocation_table_offset: u16,
    overlay_number: u16,

    pub fn parse(bytes: []const u8) !Header {
        if (bytes.len < 28) return error.TruncatedHeader;
        const signature = readWord(bytes, 0);
        if (signature != 0x5A4D and signature != 0x4D5A) return error.InvalidSignature;

        const result = Header{
            .signature = signature,
            .bytes_last_page = readWord(bytes, 2),
            .pages = readWord(bytes, 4),
            .relocation_count = readWord(bytes, 6),
            .header_paragraphs = readWord(bytes, 8),
            .min_extra_paragraphs = readWord(bytes, 10),
            .max_extra_paragraphs = readWord(bytes, 12),
            .initial_ss = readWord(bytes, 14),
            .initial_sp = readWord(bytes, 16),
            .checksum = readWord(bytes, 18),
            .initial_ip = readWord(bytes, 20),
            .initial_cs = readWord(bytes, 22),
            .relocation_table_offset = readWord(bytes, 24),
            .overlay_number = readWord(bytes, 26),
        };

        if (result.headerSizeBytes() > bytes.len) return error.TruncatedHeader;
        if (result.fileSizeBytes() < result.headerSizeBytes()) return error.InvalidFileSize;
        return result;
    }

    pub fn headerSizeBytes(self: Header) usize {
        return @as(usize, self.header_paragraphs) * 16;
    }

    pub fn fileSizeBytes(self: Header) usize {
        if (self.pages == 0) return 0;
        const full_pages = @as(usize, self.pages - 1) * 512;
        const last = if (self.bytes_last_page == 0) @as(usize, 512) else @as(usize, self.bytes_last_page);
        return full_pages + last;
    }

    pub fn imageSizeBytes(self: Header) usize {
        return self.fileSizeBytes() - self.headerSizeBytes();
    }

    pub fn imageParagraphs(self: Header) usize {
        return (self.imageSizeBytes() + 15) / 16;
    }
};

fn readWord(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

test "MZ header computes header and image sizes" {
    var bytes = [_]u8{0} ** 64;
    bytes[0] = 'M';
    bytes[1] = 'Z';
    std.mem.writeInt(u16, bytes[2..4], 64, .little);
    std.mem.writeInt(u16, bytes[4..6], 1, .little);
    std.mem.writeInt(u16, bytes[8..10], 2, .little);

    const header = try Header.parse(&bytes);
    try std.testing.expectEqual(@as(usize, 32), header.headerSizeBytes());
    try std.testing.expectEqual(@as(usize, 64), header.fileSizeBytes());
    try std.testing.expectEqual(@as(usize, 32), header.imageSizeBytes());
    try std.testing.expectEqual(@as(usize, 2), header.imageParagraphs());
}

test "MZ header accepts DOS old ZM signature" {
    var bytes = [_]u8{0} ** 32;
    bytes[0] = 'Z';
    bytes[1] = 'M';
    std.mem.writeInt(u16, bytes[2..4], 32, .little);
    std.mem.writeInt(u16, bytes[4..6], 1, .little);
    std.mem.writeInt(u16, bytes[8..10], 2, .little);
    _ = try Header.parse(&bytes);
}
