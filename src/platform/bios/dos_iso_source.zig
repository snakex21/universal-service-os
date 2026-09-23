//! Read selected DOS and Windows 3.x source files from an ISO on USOS DATA.
const std = @import("std");
const storage = @import("storage");
const iso9660 = @import("catalog").iso9660;
const dos = @import("dos_fat.zig");
const ntfs = storage.ntfs;
const Reader = storage.random_reader.Reader;

pub const Source = struct {
    fs: ntfs.FileSystem,
    disk: Reader,
    file: ntfs.File,

    pub fn open(fs: ntfs.FileSystem, reader: Reader, bulk: Reader, path: []const []const u16) !Source {
        var result = Source{ .fs = fs, .disk = bulk, .file = undefined };
        // Errors come from a void helper: a comptime error returned with the
        // 11 KiB Source payload would be an 11 KiB constant in the Core.
        try result.check(reader, path);
        return result;
    }
    fn check(self: *Source, reader: Reader, path: []const []const u16) !void {
        try ntfs.openFile(self.fs, reader, path, &self.file);
        var descriptor: [2048]u8 = undefined;
        _ = try self.readAt(16 * 2048, &descriptor);
        if (descriptor[0] != 1 or !std.mem.eql(u8, descriptor[1..6], "CD001") or dos.get16(&descriptor, 128) != 2048) return error.UnsupportedDosIso;
    }
    pub fn size(self: *const Source) u64 { return self.file.size(); }
    pub fn readAt(self: *const Source, offset: u64, output: []u8) !usize {
        try self.file.readAt(self.fs, self.disk, offset, output);
        return output.len;
    }
    pub fn require(self: *Source, name: []const u8) !iso9660.Record {
        const record = (try iso9660.findRecord(self, name)) orelse return error.DosSourceFileMissing;
        if (record.is_directory or record.size == 0 or record.size > dos.image_size) return error.InvalidDosSourceFile;
        return record;
    }
    pub fn bootFloppy(self: *Source, output: []u8) !dos.Floppy {
        if (output.len != 1474560) return error.InvalidDosFloppy;
        var descriptor: [2048]u8 = undefined;
        _ = try self.readAt(17 * 2048, &descriptor);
        if (descriptor[0] != 0 or !std.mem.eql(u8, descriptor[1..6], "CD001") or !std.mem.startsWith(u8, descriptor[7..], "EL TORITO SPECIFICATION")) return error.DosBootCatalogMissing;
        _ = try self.readAt(@as(u64, dos.get32(&descriptor, 71)) * 2048, &descriptor);
        var sum: u16 = 0;
        for (0..16) |i| sum +%= dos.get16(&descriptor, i * 2);
        if (sum != 0 or descriptor[0] != 1 or descriptor[1] != 0 or dos.get16(&descriptor, 30) != 0xaa55 or descriptor[32] != 0x88 or descriptor[33] != 2) return error.UnsupportedDosBootImage;
        _ = try self.readAt(@as(u64, dos.get32(&descriptor, 40)) * 2048, output);
        if (!std.mem.eql(u8, output[3..11], "MSDOS6.2")) return error.MsDos622BootImageRequired;
        return dos.Floppy.init(output);
    }
    pub fn copyRoot(self: *Source, builder: *dos.Builder, directory: *dos.Directory, skip_owned: bool) !void {
        const root = (try iso9660.findRecord(self, "")) orelse return error.InvalidDosSetupDirectory;
        if (!root.is_directory or root.size > 1024 * 1024) return error.InvalidDosSetupDirectory;
        var block: [2048]u8 = undefined;
        var offset: u64 = 0;
        while (offset < root.size) : (offset += 2048) {
            const count: usize = @intCast(@min(2048, root.size - offset));
            _ = try self.readAt(@as(u64, root.extent_lba) * 2048 + offset, block[0..count]);
            var position: usize = 0;
            while (position < count and block[position] != 0) {
                const length = block[position];
                if (length > count - position) return error.InvalidDosSetupDirectory;
                const bytes = block[position..][0..length];
                const record = iso9660.recordInfo(bytes) orelse return error.InvalidDosSetupDirectory;
                const raw = bytes[record.name_offset..][0..record.name_len];
                position += length;
                if (raw.len == 1 and raw[0] <= 1) continue;
                if (record.is_directory or bytes[25] & 0x80 != 0) return error.UnsupportedDosSourceLayout;
                const end = std.mem.indexOfScalar(u8, raw, ';') orelse raw.len;
                const name = std.mem.trimEnd(u8, raw[0..end], ".");
                if (skip_owned and ownedName(name)) continue;
                const output = try builder.reserveIn(name, @intCast(record.size), directory);
                _ = try self.readAt(@as(u64, record.extent_lba) * 2048, output);
            }
        }
    }
};

fn ownedName(name: []const u8) bool {
    for ([_][]const u8{ "IO.SYS", "MSDOS.SYS", "COMMAND.COM", "CONFIG.SYS", "AUTOEXEC.BAT", "HIMEMX.EXE", "INSTALL.BAT", "LIVE.BAT", "PREPDOS.BAT", "HIMEMX.TXT", "HIMEMSRC.ZIP", "LICENSE.TXT" }) |owned|
        if (std.ascii.eqlIgnoreCase(name, owned)) return true;
    return false;
}
