const std = @import("std");
const storage = @import("storage");
const e820 = @import("e820.zig");
const memory = @import("linux_memory.zig");
const dos = @import("dos_fat.zig");
const console = @import("console.zig");
const fat = storage.fat32;
const Reader = storage.random_reader.Reader;
const wide = std.unicode.utf8ToUtf16LeStringLiteral;
const path = [_][]const u16{ wide("EFI"), wide("USOS"), wide("dos-native"), wide("memdisk") };
extern fn core_dos_jump(target_drive: u32) callconv(.c) noreturn;
extern const dos_filter_start: [256]u8;
extern fn bios_vbe_text_mode() callconv(.c) u32;

pub fn allocate(fs: fat.FileSystem, reader: Reader, bulk: Reader, drive: u8) ![]u8 {
    _ = drive;
    return allocateMode(fs, reader, bulk, .floppy);
}
pub const Mode = enum { floppy, first_disk, second_disk };
pub fn allocateMode(fs: fat.FileSystem, reader: Reader, bulk: Reader, mode: Mode) ![]u8 {
    return allocateAt(fs, reader, bulk, mode, 128 * 1024 * 1024, dos.image_size);
}
pub fn allocateFreeDos(fs: fat.FileSystem, reader: Reader, bulk: Reader) ![]u8 {
    return allocateAt(fs, reader, bulk, .first_disk, 16 * 1024 * 1024, 64 * 1024 * 1024);
}
fn allocateAt(fs: fat.FileSystem, reader: Reader, bulk: Reader, mode: Mode, image_start: u32, image_bytes: u32) ![]u8 {
    var map: [e820.max_entries]e820.Entry = undefined;
    const count = try e820.probe(&map);
    // Put the DOS source above 128 MiB. DOS's contiguous extended-memory
    // report stops at this reserved image, leaving ample conventional Win98 RAM.
    if (!memory.rangeIsUsable(map[0..count], .{ .start = image_start, .end = image_start + image_bytes }) or
        !memory.rangeIsUsable(map[0..count], .{ .start = 0x100000, .end = 0x500000 }) or
        !memory.rangeIsUsable(map[0..count], .{ .start = 0x90000, .end = 0x9f000 })) return error.NotEnoughDosMemory;
    const info = try fat.fileInfo(fs, reader, &path);
    if (info.size != 26140) return error.InvalidMemdisk;
    const prefix: [*]u8 = @ptrFromInt(0x200000);
    @memset(prefix[0..3072], 0);
    if (try fat.readFileRange(fs, bulk, &path, 0, prefix[0..2048]) != 2048) return error.ShortMemdisk;
    if (prefix[0x1f1] != 3 or !std.mem.eql(u8, prefix[0x202..0x206], "HdrS") or dos.get16(prefix[0..2048], 0x206) != 0x203) return error.InvalidMemdisk;
    const payload: [*]u8 = @ptrFromInt(0x100000);
    if (try fat.readFileRange(fs, bulk, &path, 2048, payload[0..info.size - 2048]) != info.size - 2048) return error.ShortMemdisk;
    prefix[0x210] = 0xff;
    std.mem.writeInt(u32, prefix[0x218..0x21c], image_start, .little);
    std.mem.writeInt(u32, prefix[0x21c..0x220], image_bytes, .little);
    // MEMDISK copies its command through a 16-bit segment register. The
    // pointer must refer to the low-memory copy made by core_dos_jump.
    std.mem.writeInt(u32, prefix[0x228..0x22c], 0x90b00, .little);
    const command = prefix + 0xb00;
    // Preserve the DOS memory manager's state when the RAM patcher uses DPMI.
    const text: []const u8 = switch (mode) {
        .floppy => "floppy safeint c=1024 h=16 s=32\x00",
        .first_disk => "harddisk=0 safeint c=1024 h=16 s=32\x00",
        .second_disk => "harddisk=1 safeint c=1024 h=16 s=32\x00",
    };
    @memcpy(command[0..text.len], text);
    const image: [*]u8 = @ptrFromInt(image_start);
    return image[0..image_bytes];
}
pub fn start(target_drive: u8) noreturn {
    const filter: [*]u8 = @ptrFromInt(0x200a00);
    @memcpy(filter[0..256], &dos_filter_start);
    _ = bios_vbe_text_mode();
    console.line("[DOS] CORE -> MEMDISK -> ORIGINAL DOS");
    core_dos_jump(target_drive);
}
