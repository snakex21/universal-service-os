const std = @import("std");
const storage = @import("storage");
const udf = @import("catalog").udf;
const cpio = @import("windows_cpio.zig");
const iso_config = @import("windows_iso_config.zig");
const wimboot = @import("windows_wimboot.zig");
const console = @import("console.zig");
const graphics_menu = @import("graphics_menu.zig");
const vbe = @import("vbe_probe.zig");
const ntfs = storage.ntfs;
const fat = storage.fat32;
const Reader = storage.random_reader.Reader;
pub const Error = anyerror;

const wide = std.unicode.utf8ToUtf16LeStringLiteral;
const kernel_path = [_][]const u16{ wide("EFI"), wide("USOS"), wide("windows-native"), wide("wimboot") };
const support_path = [_][]const u16{ wide("EFI"), wide("USOS"), wide("windows-native"), wide("support.cpio") };
const boot_paths = [_][]const u8{ "bootmgr", "boot/bcd", "boot/boot.sdi", "sources/boot.wim" };
const boot_names = [_][]const u8{ "bootmgr", "BCD", "boot.sdi", "boot.wim" };

const IsoReader = struct {
    fs: *const ntfs.FileSystem,
    disk: Reader,
    file: *const ntfs.File,

    pub fn size(self: *const IsoReader) u64 {
        return self.file.size();
    }

    pub fn readAt(self: *const IsoReader, offset: u64, output: []u8) !usize {
        try self.file.readAt(self.fs.*, self.disk, offset, output);
        return output.len;
    }
};

pub fn run(esp: fat.FileSystem, reader: Reader, bulk: Reader, drive: u8, graphics: ?vbe.Session, system: iso_config.System, image_name: []const u8, unattended_name: ?[]const u8) !noreturn {
    try iso_config.validateName(image_name);
    if (unattended_name) |name| try iso_config.validateName(name);
    if (graphics) |session| graphics_menu.windowsSetupStart(&session);
    const data = try storage.gpt.findUsosData(reader);
    const fs = try ntfs.mount(reader, .{ .start_bytes = try multiply(data.start_lba, 512), .size_bytes = try multiply(data.sectorCount(), 512) });
    var image_wide: [255]u16 = undefined;
    const image_path = [_][]const u16{ wide("Systems"), wide("Windows"), system.folderWide(), wide("Images"), widen(image_name, &image_wide) };
    var file: ntfs.File = undefined;
    try ntfs.openFile(fs, reader, &image_path, &file);
    var iso = IsoReader{ .fs = &fs, .disk = bulk, .file = &file };
    console.line("[WINDOWS_NATIVE] SELECTED ISO OPEN; NO WORK CACHE");
    var files: [boot_paths.len]udf.Node = undefined;
    for (boot_paths, 0..) |path, i| {
        if (!try udf.openPath(&iso, path, &files[i])) return error.WindowsBootFileMissing;
        if (files[i].is_directory or files[i].size == 0 or files[i].size > 1024 * 1024 * 1024) return error.InvalidWindowsBootFile;
    }
    var setup: udf.Node = undefined;
    var install: udf.Node = undefined;
    if (!try udf.openPath(&iso, "sources/setup.exe", &setup)) return error.WindowsSetupMissing;
    if (!try udf.openPath(&iso, "sources/install.wim", &install)) return error.WindowsInstallImageMissing;
    if (setup.is_directory or setup.size == 0 or install.is_directory or install.size == 0) return error.InvalidWindowsBootFile;
    console.line("[WINDOWS_NATIVE] ORIGINAL UDF BOOT AND SETUP FILES FOUND");
    const support = try fat.fileInfo(esp, reader, &support_path);
    if (support.size < 512 or support.size > 8 * 1024 * 1024 or support.size % 4 != 0) return error.InvalidWindowsSupport;
    var config: [544]u8 = undefined;
    const config_data = try iso_config.sourceConfig(&config, data.part_guid, file.size(), system, image_name);
    var total: u64 = support.size;
    for (files, boot_names) |node, name| total += try cpio.entrySize(name, @intCast(node.size));
    total += try cpio.entrySize("usos-source.ini", @intCast(config_data.len));
    var answer: ntfs.File = undefined;
    if (unattended_name) |name| {
        var answer_wide: [255]u16 = undefined;
        const answer_path = [_][]const u16{ wide("Systems"), wide("Windows"), system.folderWide(), wide("Unattended"), widen(name, &answer_wide) };
        try ntfs.openFile(fs, reader, &answer_path, &answer);
        if (answer.size() == 0 or answer.size() > 1024 * 1024) return error.InvalidAnswerFileSize;
        total += try cpio.entrySize("usos-unattend.xml", @intCast(answer.size()));
    }
    total += try cpio.entrySize("TRAILER!!!", 0);
    if (total > 0x60000000) return error.WindowsArchiveTooLarge;
    const archive = try wimboot.allocate(esp, reader, bulk, drive, &kernel_path, @intCast(total));
    var progress = wimboot.Progress{ .session = graphics, .total = @intCast(total) };
    if (try fat.readFileSequentialProgress(esp, bulk, &support_path, archive[0..support.size], .{ .context = &progress, .update_fn = wimboot.Progress.update }) != support.size) return error.ShortWindowsSupport;
    if (!std.mem.eql(u8, archive[0..6], "070701")) return error.InvalidWindowsSupport;
    var writer = cpio.Writer{ .bytes = archive, .position = support.size, .inode = 100 };
    for (&files, boot_names) |*node, name| {
        const output = try writer.reserve(name, @intCast(node.size));
        var position: usize = 0;
        while (position < output.len) {
            const end = position + @min(@as(usize, 1024 * 1024), output.len - position);
            try udf.readNodeAt(&iso, node, position, output[position..end]);
            wimboot.Progress.update(&progress, writer.position - output.len + end);
            position = end;
        }
        console.print("[WINDOWS_NATIVE] LOADED ");
        console.line(name);
    }
    try writer.add("usos-source.ini", config_data);
    if (unattended_name != null) try answer.readAt(fs, bulk, 0, try writer.reserve("usos-unattend.xml", @intCast(answer.size())));
    try writer.finish();
    if (writer.position != archive.len) return error.InvalidWindowsArchiveSize;
    wimboot.Progress.update(&progress, archive.len);
    console.line("[WINDOWS_NATIVE] CORE -> WIMBOOT DIRECT FROM ISO; NO REBOOT");
    wimboot.start();
}

fn widen(text: []const u8, out: []u16) []const u16 {
    for (text, 0..) |ch, i| out[i] = ch;
    return out[0..text.len];
}

fn multiply(a: u64, b: u64) !u64 {
    const result = @mulWithOverflow(a, b);
    if (result[1] != 0) return error.PartitionBounds;
    return result[0];
}

