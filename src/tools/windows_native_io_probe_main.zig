const std = @import("std");
const storage = @import("storage");
const udf = @import("catalog").udf;

const Context = struct {
    io: std.Io,
    disk: std.Io.File,
    fn read(raw: *anyopaque, offset: u64, out: []u8) storage.random_reader.Error!void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        // Physical Windows devices require sector-aligned reads; keep the
        // adapter valid for both raw fixtures and read-only USB inspection.
        var block: [64 * 1024]u8 align(4096) = undefined;
        var done: usize = 0;
        while (done < out.len) {
            const at = offset + done;
            const aligned = at & ~@as(u64, 511);
            const within: usize = @intCast(at - aligned);
            const amount = @min(out.len - done, block.len - within);
            const length = std.mem.alignForward(usize, within + amount, 512);
            const n = self.disk.readPositionalAll(self.io, block[0..length], aligned) catch return error.Io;
            if (n != length) return error.Io;
            @memcpy(out[done..][0..amount], block[within..][0..amount]);
            done += amount;
        }
    }
};
const Iso = struct {
    fs: storage.ntfs.FileSystem,
    reader: storage.random_reader.Reader,
    file: storage.ntfs.File,
    pub fn size(self: *@This()) u64 { return self.file.size(); }
    pub fn readAt(self: *@This(), offset: u64, out: []u8) !usize {
        try self.file.readAt(self.fs, self.reader, offset, out);
        return out.len;
    }
};

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const disk_path = args.next() orelse return error.MissingDisk;
    const image_name = args.next() orelse return error.MissingIsoName;
    var context = Context{ .io = init.io, .disk = try std.Io.Dir.cwd().openFile(init.io, disk_path, .{}) };
    defer context.disk.close(init.io);
    const reader = storage.random_reader.Reader{ .context = &context, .read_fn = Context.read };
    const part = try storage.gpt.findUsosData(reader);
    var iso = Iso{ .fs = try storage.ntfs.mount(reader, .{ .start_bytes = part.start_lba * 512, .size_bytes = part.sectorCount() * 512 }), .reader = reader, .file = undefined };
    const wide = std.unicode.utf8ToUtf16LeStringLiteral;
    var name: [255]u16 = undefined;
    if (image_name.len > name.len) return error.NameTooLong;
    for (image_name, 0..) |ch,i| name[i] = ch;
    const path = [_][]const u16{wide("Systems"),wide("Windows"),wide("Windows Vista"),wide("Images"),name[0..image_name.len]};
    try storage.ntfs.openFile(iso.fs, reader, &path, &iso.file);
    var block: [1024 * 1024]u8 = undefined;
    for ([_][]const u8{"bootmgr", "boot/bcd", "boot/boot.sdi", "sources/boot.wim", "sources/setup.exe", "sources/install.wim"}) |inner| {
        var node: udf.Node = undefined;
        if (!try udf.openPath(&iso, inner, &node)) return error.MissingInnerFile;
        var digest = std.crypto.hash.sha2.Sha256.init(.{});
        var at: u64 = 0;
        while (at < node.size) {
            const n: usize = @intCast(@min(block.len, node.size - at));
            try udf.readNodeAt(&iso, &node, at, block[0..n]);
            digest.update(block[0..n]);
            at += n;
        }
        var hash: [32]u8 = undefined;
        digest.final(&hash);
        std.debug.print("{s} size={d} sha256={s}\n", .{inner,node.size,std.fmt.bytesToHex(hash,.lower)});
    }
}
