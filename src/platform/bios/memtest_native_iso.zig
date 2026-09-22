//! Read-only BIOS launch of Memtest86+ from the selected Utilities ISO.
const std = @import("std");
const storage = @import("storage");
const catalog = @import("catalog");
const format = @import("memtest_image.zig");
const params = @import("linux_boot_params.zig");
const memory = @import("linux_memory.zig");
const e820 = @import("e820.zig");
const vbe = @import("vbe_probe.zig");
const console = @import("console.zig");
const Reader = storage.random_reader.Reader;
const ntfs = storage.ntfs;
const wide = std.unicode.utf8ToUtf16LeStringLiteral;
extern fn core_linux_jump(entry: u32, boot_params: u32) callconv(.c) noreturn;

const Source = struct {
    fs: ntfs.FileSystem,
    reader: Reader,
    file: ntfs.File,
    pub fn size(self: *const Source) u64 { return self.file.size(); }
    pub fn readAt(self: *const Source, offset: u64, output: []u8) !usize {
        if (offset > self.size() or output.len > self.size() - offset) return error.TruncatedUtilityIso;
        try self.file.readAt(self.fs, self.reader, offset, output);
        return output.len;
    }
};

pub fn run(reader: Reader, bulk: Reader, folder: []const u8, image: catalog.ImageItem, graphics: ?vbe.Session) !void {
    if (image.kind != .iso) return error.MemtestI586IsoRequired;
    try @import("windows_iso_config.zig").validateName(folder);
    try @import("windows_iso_config.zig").validateName(image.name.slice());
    var folder16: [255]u16 = undefined;
    var image16: [255]u16 = undefined;
    for (folder, 0..) |ch, i| folder16[i] = ch;
    for (image.name.slice(), 0..) |ch, i| image16[i] = ch;
    const path = [_][]const u16{ wide("Utilities"), folder16[0..folder.len], wide("Images"), image16[0..image.name.len] };
    const data = try storage.gpt.findUsosData(reader);
    const fs = try ntfs.mount(reader, .{ .start_bytes = data.start_lba * 512, .size_bytes = data.sectorCount() * 512 });
    var source = Source{ .fs = fs, .reader = bulk, .file = undefined };
    try ntfs.openFile(fs, reader, &path, &source.file);
    const record = (try catalog.iso9660.findRecord(&source, "BOOT/FLOPPY.IMG")) orelse return error.MemtestI586IsoRequired;
    if (record.is_directory or record.size < format.setup_bytes) return error.InvalidMemtestImageSize;
    const base = @as(u64, record.extent_lba) * 2048;
    if (base > source.size() or record.size > source.size() - base) return error.TruncatedUtilityIso;
    var setup: [format.setup_bytes]u8 = undefined;
    _ = try source.readAt(base, &setup);
    const layout = try format.parse(&setup, record.size);
    var entries: [e820.max_entries]e820.Entry = undefined;
    const map = entries[0..try e820.probe(&entries)];
    if (!memory.rangeIsUsable(map, .{ .start = format.load_address, .end = @as(u64, format.load_address) + layout.runtime_bytes }) or
        !memory.rangeIsUsable(map, .{ .start = params.boot_params_phys, .end = params.boot_params_phys + params.boot_params_bytes }))
        return error.MemtestMemoryNotUsable;
    const destination: [*]u8 = @ptrFromInt(format.load_address);
    _ = try source.readAt(base + layout.offset, destination[0..layout.load_bytes]);
    const boot_params: *[params.boot_params_bytes]u8 = @ptrFromInt(params.boot_params_phys);
    try params.buildStandalone(boot_params, &setup, map, graphics);
    console.line("[MEMTEST] Validated Memtest86+ i586; ISO read only; starting at 0x00100000");
    core_linux_jump(format.load_address, params.boot_params_phys);
}
