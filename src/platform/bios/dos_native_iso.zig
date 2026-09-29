const std = @import("std");
const storage = @import("storage");
const iso9660 = @import("catalog").iso9660;
const fat = storage.fat32;
const ntfs = storage.ntfs;
const Reader = storage.random_reader.Reader;
const dos = @import("dos_fat.zig");
const config = @import("windows_iso_config.zig");
const memdisk = @import("dos_memdisk.zig");
const target_ui = @import("dos_target_ui.zig");
const wimboot = @import("windows_wimboot.zig");
const graphics_menu = @import("graphics_menu.zig");
const console = @import("console.zig");
const vbe = @import("vbe_probe.zig");
const wide = std.unicode.utf8ToUtf16LeStringLiteral;

const Iso = struct {
    fs: ntfs.FileSystem,
    disk: Reader,
    file: *const ntfs.File,
    pub fn size(self: *const Iso) u64 { return self.file.size(); }
    pub fn readAt(self: *const Iso, offset: u64, out: []u8) !usize {
        try self.file.readAt(self.fs, self.disk, offset, out); return out.len;
    }
};

/// noinline: its locals must not add to legacy_boot_actions.execute's frame (the PM32
/// stack below 0x9E000 ends at the Core .data; docs/design/bios-via-csmwrap.md).
pub noinline fn run(esp: fat.FileSystem, reader: Reader, bulk: Reader, drive: u8, graphics: ?vbe.Session, image_name: []const u8) !void {
    const session = graphics orelse return error.DosPartitionScreenNeedsGraphics;
    const action = target_ui.action(session) orelse return;
    try config.validateName(image_name);
    graphics_menu.windowsSetupStart(&session);
    const data = try storage.gpt.findUsosData(reader);
    const fs = try ntfs.mount(reader, .{ .start_bytes = data.start_lba * 512, .size_bytes = data.sectorCount() * 512 });
    var name: [255]u16 = undefined;
    for (image_name, 0..) |ch, i| name[i] = ch;
    const path = [_][]const u16{ wide("Systems"), wide("Windows"), wide("Windows 98 SE"), wide("Images"), name[0..image_name.len] };
    var file: ntfs.File = undefined;
    try ntfs.openFile(fs, reader, &path, &file);
    var iso = Iso{ .fs = fs, .disk = bulk, .file = &file };
    const setup = (try iso9660.findRecord(&iso, "win98")) orelse return error.DosSetupDirectoryMissing;
    if (!setup.is_directory or setup.size > 1024 * 1024) return error.InvalidDosSetupDirectory;
    const executable = (try iso9660.findRecord(&iso, "win98/setup.exe")) orelse return error.DosSetupMissing;
    if (executable.is_directory or executable.size == 0) return error.DosSetupMissing;
    var descriptor: [2048]u8 = undefined;
    _ = try iso.readAt(17 * 2048, &descriptor);
    if (descriptor[0] != 0 or !std.mem.eql(u8, descriptor[1..6], "CD001") or !std.mem.startsWith(u8, descriptor[7..], "EL TORITO SPECIFICATION")) return error.DosBootCatalogMissing;
    const catalog_offset = @as(u64, dos.get32(&descriptor, 71)) * 2048;
    _ = try iso.readAt(catalog_offset, &descriptor);
    if (descriptor[0] != 1 or descriptor[1] != 0 or dos.get16(&descriptor, 30) != 0xaa55 or descriptor[32] != 0x88 or descriptor[33] != 2) return error.UnsupportedDosBootImage;
    const floppy_offset = @as(u64, dos.get32(&descriptor, 40)) * 2048;
    const ram = try memdisk.allocate(esp, reader, bulk, drive);
    const scratch: [*]u8 = @ptrFromInt(0x300000);
    const floppy_bytes = scratch[0..1474560];
    _ = try iso.readAt(floppy_offset, floppy_bytes);
    const floppy = try dos.Floppy.init(floppy_bytes);
    var builder = try dos.Builder.init(ram, floppy_bytes[0..512]);
    for ([_][]const u8{ "IO.SYS", "MSDOS.SYS", "COMMAND.COM", "HIMEM.SYS", "FDISK.EXE", "EXTRACT.EXE", "EBD.CAB" }) |filename| {
        const entry = try floppy.lookup(filename);
        try floppy.read(entry, try builder.reserve(filename, dos.get32(entry, 28), false));
    }
    const helper_names = [_][]const u16{ wide("PATCH9X.EXE"), wide("CWSDPMI.EXE"), if (action == .repair) wide("REPAIR.BAT") else wide("INSTALL.BAT") };
    for ([_][]const u8{ "PATCH9X.EXE", "CWSDPMI.EXE", "AUTOEXEC.BAT" }, 0..) |filename, i| {
        const helper = [_][]const u16{ wide("EFI"), wide("USOS"), wide("dos-native"), wide("ram-patch"), helper_names[i] };
        const info = try fat.fileInfo(esp, reader, &helper);
        if (info.size == 0 or info.size > 1024 * 1024) return error.InvalidDosPatchHelper;
        const output = try builder.reserve(filename, info.size, false);
        if (try fat.readFileRange(esp, bulk, &helper, 0, output) != output.len) return error.ShortDosPatchHelper;
    }
    try builder.add("CONFIG.SYS", "DEVICE=A:\\HIMEM.SYS /TESTMEM:OFF\r\nFILES=40\r\nBUFFERS=20\r\nLASTDRIVE=Z\r\n");
    try builder.makeSetupDirectory();
    var position: u64 = 0;
    var copied: usize = 0;
    var progress = wimboot.Progress{ .session = graphics, .total = dos.image_size };
    while (action == .install and position < setup.size) {
        const block_size: usize = @intCast(@min(2048, setup.size - position));
        _ = try iso.readAt(@as(u64, setup.extent_lba) * 2048 + position, descriptor[0..block_size]);
        var p: usize = 0;
        while (p < block_size and descriptor[p] != 0) {
            const length = descriptor[p];
            if (length > block_size - p) return error.InvalidDosSetupDirectory;
            const record = iso9660.recordInfo(descriptor[p..][0..length]) orelse return error.InvalidDosSetupDirectory;
            const raw = descriptor[p + record.name_offset..][0..record.name_len];
            if (!record.is_directory) {
                if (descriptor[p + 25] & 0x80 != 0) return error.UnsupportedDosMultiExtent;
                const end = std.mem.indexOfScalar(u8, raw, ';') orelse raw.len;
                const output = try builder.reserve(raw[0..end], @intCast(record.size), true);
                var done: usize = 0;
                while (done < output.len) {
                    const count = @min(1024 * 1024, output.len - done);
                    _ = try iso.readAt(@as(u64, record.extent_lba) * 2048 + done, output[done..][0..count]);
                    done += count; copied += count;
                    wimboot.Progress.update(&progress, copied);
                }
            } else if (!(raw.len == 1 and raw[0] <= 1) and !std.ascii.eqlIgnoreCase(raw, "TOUR")) return error.UnsupportedDosSetupSubdirectory;
            p += length;
        }
        position += block_size;
    }
    wimboot.Progress.update(&progress, dos.image_size);
    console.line("[WIN98] ORIGINAL DOS AND SETUP FILES IN RAM; NO PREPARATION REBOOT");
    const selected = (try target_ui.choose(drive, session, action)) orelse return;
    if (selected.format_plan) |plan| {
        try target_ui.commit(plan);
        console.line("[WIN98] USER CONFIRMED TARGET PARTITION COMMITTED");
    } else console.line("[WIN98] USER CONFIRMED RAM REPAIR; NO PARTITION WRITES");
    memdisk.start(selected.drive);
}
