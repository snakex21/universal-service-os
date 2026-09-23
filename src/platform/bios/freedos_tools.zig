//! Built-in DOS session. User programs are staged from NTFS into a RAM disk.
const storage = @import("storage");
const dos = @import("dos_fat.zig");
const memdisk = @import("dos_memdisk.zig");
const wide = @import("std").unicode.utf8ToUtf16LeStringLiteral;
const Reader = storage.random_reader.Reader;
extern const dos_mbr_start: [512]u8;

pub fn run(esp: storage.fat32.FileSystem, reader: Reader, bulk: Reader, graphics: ?@import("vbe_probe.zig").Session) !void {
    if (graphics) |session| @import("graphics_menu.zig").busy(&session, "FreeDOS");
    const ram = try memdisk.allocateFreeDos(esp, reader, bulk);
    var boot: [512]u8 = undefined;
    try readHelper(esp, bulk, "BOOT16.BIN", &boot);
    var builder = try dos.Builder.initDisk(ram, &boot, &dos_mbr_start, 0x80);
    for ([_][]const u8{ "KERNEL.SYS", "COMMAND.COM", "DZ.EXE", "DZ.DOS", "FDAUTO.BAT", "FDCONFIG.SYS", "TOOLS.BAT", "README.TXT", "REBOOT.COM", "DOSZIP.TXT" }) |filename| {
        const size = try helperSize(esp, reader, filename);
        try readHelper(esp, bulk, filename, try builder.reserve(filename, size, false));
    }
    const data = try storage.gpt.findUsosData(reader);
    const fs = try storage.ntfs.mount(reader, .{ .start_bytes = data.start_lba * 512, .size_bytes = data.sectorCount() * 512 });
    try @import("dos_programs.zig").copyFreeDos(fs, reader, bulk, &builder);
    @import("console.zig").line("[FREEDOS] BUILT-IN DOS AND PROGRAMS READY IN RAM; NO MEMORY MANAGERS");
    memdisk.start(0xff);
}

fn helperSize(esp: storage.fat32.FileSystem, reader: Reader, filename: []const u8) !u32 {
    var name: [12]u16 = undefined;
    for (filename, 0..) |ch, i| name[i] = ch;
    const path = [_][]const u16{ wide("EFI"), wide("USOS"), wide("dos-native"), wide("freedos"), name[0..filename.len] };
    const info = try storage.fat32.fileInfo(esp, reader, &path);
    if (info.size == 0 or info.size > 1024 * 1024) return error.InvalidFreeDosHelper;
    return info.size;
}
fn readHelper(esp: storage.fat32.FileSystem, reader: Reader, filename: []const u8, output: []u8) !void {
    var name: [12]u16 = undefined;
    for (filename, 0..) |ch, i| name[i] = ch;
    const path = [_][]const u16{ wide("EFI"), wide("USOS"), wide("dos-native"), wide("freedos"), name[0..filename.len] };
    if (try storage.fat32.readFileRange(esp, reader, &path, 0, output) != output.len) return error.ShortFreeDosHelper;
}
