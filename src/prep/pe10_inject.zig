//! Step 3/4 of the Win10 x86 CSMWrap route (tools/vista_csmwrap_target.sh,
//! X86_SELF=1) for MiniOS: the donor boot.wim boot image becomes the
//! staging \sources\boot.wim with the USOS WinPE helpers in
//! \Windows\System32 and, on NVMe with USOS_PE_NVME=usosnvme, usosnvme-nt6.sys
//! as \Windows\System32\drivers\stornvme.sys; then the read-back check.
//! Not wired into the menu flow yet (see the MiniOS port plan).
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const platform = @import("platform.zig");
const wim = @import("wim.zig");
const meta = @import("wim_metadata.zig");
const update = @import("wim_update.zig");
const ntfs = @import("ntfs.zig");

/// One regular file inside a newc/crc cpio held by `archive` (no copy).
pub const CpioFile = struct { name: [64]u8, name_len: usize, offset: u64, size: u64 };
fn hex(text: []const u8) !u64 {
    return std.fmt.parseInt(u64, text, 16) catch error.CorruptCpio;
}
/// Reads the flat helper archives the Alpine route unpacks with `cpio -idm`.
/// The release archives (tools/build_windows_native_support.py NewcWriter)
/// have no TRAILER!!! entry: Core appends one when it sends them, and the
/// micro-Linux `cpio -idm` reads the files as they are. Their end is the
/// end of the last entry (optionally zero padding), as for cpio.
pub fn listCpio(archive: update.Source, out: []CpioFile) !usize {
    var at: u64 = 0;
    var count: usize = 0;
    while (at < archive.size) {
        if (archive.size - at < 110) {
            // Only zero padding may follow the last entry.
            var tail: [110]u8 = undefined;
            const rest: usize = @intCast(archive.size - at);
            try archive.read_fn(archive.context, at, tail[0..rest]);
            if (!std.mem.allEqual(u8, tail[0..rest], 0)) return error.CorruptCpio;
            return count;
        }
        var h: [110]u8 = undefined;
        try archive.read_fn(archive.context, at, &h);
        if (std.mem.allEqual(u8, &h, 0)) {
            // Zero padding after the last entry (block-padded archives).
            var rest = at + h.len;
            var chunk: [512]u8 = undefined;
            while (rest < archive.size) {
                const n: usize = @intCast(@min(chunk.len, archive.size - rest));
                try archive.read_fn(archive.context, rest, chunk[0..n]);
                if (!std.mem.allEqual(u8, chunk[0..n], 0)) return error.CorruptCpio;
                rest += n;
            }
            return count;
        }
        if (!std.mem.eql(u8, h[0..6], "070701") and !std.mem.eql(u8, h[0..6], "070702")) return error.CorruptCpio;
        const mode = try hex(h[14..22]);
        const size = try hex(h[54..62]);
        const name_size = try hex(h[94..102]);
        if (name_size == 0 or name_size > 256) return error.CorruptCpio;
        var name_buf: [256]u8 = undefined;
        try archive.read_fn(archive.context, at + 110, name_buf[0..@intCast(name_size)]);
        const name = name_buf[0..@intCast(name_size - 1)];
        const data = (at + 110 + name_size + 3) & ~@as(u64, 3);
        if (data > archive.size or size > archive.size - data) return error.CorruptCpio;
        if (std.mem.eql(u8, name, "TRAILER!!!")) return count;
        if (mode & 0o170000 == 0o100000) {
            var base = name;
            while (std.mem.startsWith(u8, base, "./")) base = base[2..];
            if (base.len == 0 or base.len > 64 or std.mem.indexOfAny(u8, base, "/\\:") != null) return error.UnsupportedCpioPath;
            // Later archives/entries replace earlier ones, as cpio -idm does.
            var slot: ?usize = null;
            for (out[0..count], 0..) |f, i| if (std.mem.eql(u8, f.name[0..f.name_len], base)) {
                slot = i;
            };
            const i = slot orelse blk: {
                if (count == out.len) return error.TooManyCpioFiles;
                count += 1;
                break :blk count - 1;
            };
            out[i] = .{ .name = undefined, .name_len = base.len, .offset = data, .size = size };
            @memcpy(out[i].name[0..base.len], base);
        }
        // The last entry's data may end the file without the 4-byte pad.
        if (data + size >= archive.size) return count;
        at = (data + size + 3) & ~@as(u64, 3);
    }
    return count;
}

pub const Request = struct {
    support: update.Source, // support.cpio
    helpers: update.Source, // modern-support.cpio (X86_SELF)
    source_ini: []const u8, // REQUEST_DIR/usos-source.ini
    target_ini: []const u8, // usos-csmwrap-target.ini text
    answer: ?[]const u8 = null, // usos-unattend.xml
    modern_nvme: bool = false, // usos-nvme-modern.flag
    pe_nvme: bool = false, // target_bus=nvme and USOS_PE_NVME=usosnvme
};
const Slice = struct {
    archive: update.Source,
    offset: u64,
    fn read(ctx: *anyopaque, at: u64, out: []u8) platform.Error!void {
        const self: *Slice = @ptrCast(@alignCast(ctx));
        return self.archive.read_fn(self.archive.context, self.offset + at, out);
    }
};
const Bytes = struct {
    bytes: []const u8,
    fn read(ctx: *anyopaque, at: u64, out: []u8) platform.Error!void {
        const self: *Bytes = @ptrCast(@alignCast(ctx));
        if (at > self.bytes.len or out.len > self.bytes.len - at) return error.Bounds;
        @memcpy(out, self.bytes[@intCast(at)..][0..out.len]);
    }
};
const flag_one = "1\r\n";
pub const max_files = 96;

/// The add list Alpine builds (inject/* -> /Windows/System32/<name>, then
/// the stornvme swap). Holds only offsets into the two cpio sources.
pub const Injection = struct {
    files: [max_files + 4]CpioFile = undefined,
    sources: [max_files + 4]?Slice = undefined,
    texts: [5]Bytes = undefined,
    paths: [max_files + 5][96]u8 = undefined,
    adds: [max_files + 5]update.Add = undefined,
    count: usize = 0,

    pub fn build(self: *Injection, req: Request) !void {
        var support: [max_files]CpioFile = undefined;
        const n1 = try listCpio(req.support, &support);
        var helpers: [max_files]CpioFile = undefined;
        const n2 = try listCpio(req.helpers, &helpers);
        var names: usize = 0;
        // inject/ = support.cpio, then modern-support.cpio over it.
        for ([_]struct { list: []CpioFile, src: update.Source }{ .{ .list = support[0..n1], .src = req.support }, .{ .list = helpers[0..n2], .src = req.helpers } }) |group| {
            for (group.list) |f| {
                const slot = self.find(names, f.name[0..f.name_len]) orelse blk: {
                    if (names == max_files) return error.TooManyHelperFiles;
                    names += 1;
                    break :blk names - 1;
                };
                self.files[slot] = f;
                self.sources[slot] = .{ .archive = group.src, .offset = f.offset };
            }
        }
        for ([_][]const u8{ "usos-x86-csmwrap.exe", "usos-x86-csmwrap.cmd", "winpeshl.ini" }) |need| {
            if (self.find(names, need) == null) return error.HelperFilesIncomplete;
        }
        var texts: usize = 0;
        const generated = [_]struct { name: []const u8, text: ?[]const u8 }{
            .{ .name = "usos-nvme-modern.flag", .text = if (req.modern_nvme) flag_one else null },
            .{ .name = "usos-x86-csmwrap.flag", .text = flag_one },
            .{ .name = "usos-source.ini", .text = req.source_ini },
            .{ .name = "usos-csmwrap-target.ini", .text = req.target_ini },
            .{ .name = "usos-unattend.xml", .text = req.answer },
        };
        for (generated) |g| {
            const text = g.text orelse continue;
            const slot = self.find(names, g.name) orelse blk: {
                if (names == max_files) return error.TooManyHelperFiles;
                names += 1;
                break :blk names - 1;
            };
            self.files[slot] = .{ .name = undefined, .name_len = g.name.len, .offset = 0, .size = text.len };
            @memcpy(self.files[slot].name[0..g.name.len], g.name);
            self.sources[slot] = null;
            self.texts[texts] = .{ .bytes = text };
            self.files[slot].offset = texts; // index into texts
            texts += 1;
        }
        self.count = 0;
        for (0..names) |i| {
            const name = self.files[i].name[0..self.files[i].name_len];
            try self.append(i, try std.fmt.bufPrint(&self.paths[self.count], "/Windows/System32/{s}", .{name}));
        }
        if (req.pe_nvme) {
            const i = self.find(names, "usosnvme-nt6.sys") orelse return error.UsosNvmeMissing;
            try self.append(i, try std.fmt.bufPrint(&self.paths[self.count], "/Windows/System32/drivers/stornvme.sys", .{}));
        }
    }
    fn find(self: *const Injection, n: usize, name: []const u8) ?usize {
        for (self.files[0..n], 0..) |f, i| if (std.ascii.eqlIgnoreCase(f.name[0..f.name_len], name)) return i;
        return null;
    }
    fn append(self: *Injection, i: usize, path: []const u8) !void {
        const source: update.Source = if (self.sources[i]) |*s|
            .{ .context = s, .size = self.files[i].size, .read_fn = Slice.read }
        else
            .{ .context = &self.texts[@intCast(self.files[i].offset)], .size = self.files[i].size, .read_fn = Bytes.read };
        self.adds[self.count] = .{ .path = path, .source = source };
        self.count += 1;
    }
    pub fn list(self: *const Injection) []const update.Add {
        return self.adds[0..self.count];
    }
};

/// Alpine's read-back: every injected path resolves in the new image to a
/// blob whose bytes (decoded and SHA-1 checked) equal the source file.
pub fn readBack(allocator: std.mem.Allocator, input: wim.Input, adds: []const update.Add) !void {
    var archive = try wim.Archive.open(allocator, input, 1);
    defer archive.deinit();
    var res = try archive.openMetadata();
    defer res.deinit();
    try res.verify();
    var tree = try meta.Metadata.open(allocator, &res);
    defer tree.deinit();
    const a = try allocator.alloc(u8, 32 * 1024);
    defer allocator.free(a);
    const b = try allocator.alloc(u8, 32 * 1024);
    defer allocator.free(b);
    for (adds) |add| {
        var parts: [8][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, add.path, "/\\");
        while (it.next()) |part| : (n += 1) {
            if (n == parts.len) return error.InvalidWimPath;
            parts[n] = part;
        }
        const entry = (try lookupPath(&tree, parts[0..n])) orelse return error.ReadBackMissing;
        if (add.source.size == 0) {
            if (!std.mem.allEqual(u8, &entry.main_hash, 0)) return error.ReadBackDiffers;
            continue;
        }
        var blob = try archive.openEntry(try archive.find(entry.main_hash));
        defer blob.deinit();
        if (blob.descriptor.size != add.source.size) return error.ReadBackDiffers;
        var at: u64 = 0;
        while (at < add.source.size) {
            const len: usize = @intCast(@min(a.len, add.source.size - at));
            try blob.readSequential(at, a[0..len]);
            try add.source.read_fn(add.source.context, at, b[0..len]);
            if (!std.mem.eql(u8, a[0..len], b[0..len])) return error.ReadBackDiffers;
            at += len;
        }
        if (!blob.verified) return error.ReadBackDiffers;
    }
}
fn lookupPath(tree: *meta.Metadata, parts: []const []const u8) !?meta.Entry {
    var dir = (try tree.readEntry(tree.root_offset, true)) orelse return error.MissingRoot;
    for (parts) |part| {
        var wide: [255]u16 = undefined;
        const len = std.unicode.utf8ToUtf16Le(&wide, part) catch return error.InvalidWimPath;
        var cursor = dir.children;
        var hit: ?meta.Entry = null;
        var e: meta.Entry = undefined;
        while (cursor != 0 and try tree.readEntryInto(cursor, false, &e)) : (cursor = e.next) {
            if (update.compareNames(e.name[0..e.name_len], wide[0..len]) == .eq) {
                hit = e;
                break;
            }
        }
        dir = hit orelse return null;
    }
    return dir;
}

const NtfsFile = struct {
    fs: *ntfs.Ntfs,
    number: u64,
    fn read(ctx: *anyopaque, at: u64, out: []u8) platform.Error!void {
        const self: *NtfsFile = @ptrCast(@alignCast(ctx));
        const n = self.fs.readFile(self.number, at, out) catch return error.Io;
        if (n != out.len) return error.Io;
    }
};
/// Steps 3/4: export the donor's boot image with the helpers injected into
/// `dir`\boot.wim on the staging NTFS, then read it back. `donor` must be
/// opened at the donor's boot index. Returns the new file's MFT number.
pub fn writeStagingBootWim(allocator: std.mem.Allocator, fs: *ntfs.Ntfs, dir: u64, donor: *wim.Archive, injection: *const Injection, options: update.Options) !u64 {
    const plan = try update.Plan.init(allocator, donor, injection.list(), options);
    defer plan.deinit();
    const src = plan.source();
    const number = try fs.writeFile(dir, std.unicode.utf8ToUtf16LeStringLiteral("boot.wim"), .{ .context = src.context, .size = src.size, .read_fn = src.read_fn }, .{ .timestamp = options.timestamp });
    var file: NtfsFile = .{ .fs = fs, .number = number };
    try readBack(allocator, .{ .context = &file, .size = plan.size, .read_fn = NtfsFile.read }, injection.list());
    return number;
}

// ---- tests ---------------------------------------------------------------
const testing = std.testing;
fn cpio(list: *std.ArrayList(u8), files: []const [2][]const u8) !void {
    const a = testing.allocator;
    _ = a;
    for (files) |f| try cpioEntry(list, f[0], f[1], 0o100644);
    try cpioEntry(list, "TRAILER!!!", "", 0);
}
fn cpioEntry(list: *std.ArrayList(u8), name: []const u8, data: []const u8, mode: u32) !void {
    const a = testing.allocator;
    var h: [110]u8 = undefined;
    _ = try std.fmt.bufPrint(&h, "070701{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}", .{ 1, mode, 0, 0, 1, 0, data.len, 0, 0, 0, 0, name.len + 1, 0 });
    try list.appendSlice(a, &h);
    try list.appendSlice(a, name);
    try list.append(a, 0);
    while (list.items.len % 4 != 0) try list.append(a, 0);
    try list.appendSlice(a, data);
    while (list.items.len % 4 != 0) try list.append(a, 0);
}
const NtfsMemory = struct {
    bytes: []u8,
    fn read(ctx: *anyopaque, offset: u64, out: []u8) platform.Error!void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        @memcpy(out, self.bytes[@intCast(offset)..][0..out.len]);
    }
    fn write(ctx: *anyopaque, offset: u64, input: []const u8) platform.Error!void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        @memcpy(self.bytes[@intCast(offset)..][0..input.len], input);
    }
    fn flush(_: *anyopaque) platform.Error!void {}
    fn disk(self: *@This()) platform.Disk {
        return .{ .context = self, .sectors = self.bytes.len / 512, .read_fn = read, .write_fn = write, .flush_fn = flush };
    }
};

test "helper archives without TRAILER (the release support.cpio / modern-support.cpio) are read" {
    // X470 2026-10-31 B261031-170724: "USOSPREP UEFI FAIL CorruptCpio" at
    // stage=target disk: the release archives end after the last file
    // (NewcWriter writes no trailer; Core appends one when it sends them).
    const a = testing.allocator;
    var bare: std.ArrayList(u8) = .empty;
    defer bare.deinit(a);
    try cpioEntry(&bare, "usos-x86-csmwrap.cmd", "@echo off", 0o100644);
    try cpioEntry(&bare, "usosnvme-nt6.sys", "NVME", 0o100644);
    var listed: [8]CpioFile = undefined;
    var m: update.Mem = .{ .bytes = bare.items };
    try testing.expectEqual(@as(usize, 2), try listCpio(m.src(), &listed));
    try testing.expectEqualStrings("usosnvme-nt6.sys", listed[1].name[0..listed[1].name_len]);
    try testing.expectEqual(@as(u64, 4), listed[1].size);
    // The last file's data unpadded at the very end ("@echo off" = 9 bytes).
    var unpadded: std.ArrayList(u8) = .empty;
    defer unpadded.deinit(a);
    try cpioEntry(&unpadded, "a.cmd", "@echo off", 0o100644);
    unpadded.shrinkRetainingCapacity(unpadded.items.len - 3);
    m = .{ .bytes = unpadded.items };
    try testing.expectEqual(@as(usize, 1), try listCpio(m.src(), &listed));
    // Zero block padding after the last entry, short or long.
    for ([_]usize{ 4, 108, 512, 1500 }) |pad| {
        var padded: std.ArrayList(u8) = .empty;
        defer padded.deinit(a);
        try cpioEntry(&padded, "a.cmd", "x", 0o100644);
        try padded.appendNTimes(a, 0, pad);
        m = .{ .bytes = padded.items };
        try testing.expectEqual(@as(usize, 1), try listCpio(m.src(), &listed));
    }
    // Anything else after the last entry is still corrupt.
    var junk: std.ArrayList(u8) = .empty;
    defer junk.deinit(a);
    try cpioEntry(&junk, "a.cmd", "x", 0o100644);
    try junk.appendSlice(a, "garbage");
    m = .{ .bytes = junk.items };
    try testing.expectError(error.CorruptCpio, listCpio(m.src(), &listed));
    try junk.appendNTimes(a, 'z', 200);
    m = .{ .bytes = junk.items };
    try testing.expectError(error.CorruptCpio, listCpio(m.src(), &listed));
    // A data size past the end is corrupt too.
    var short: std.ArrayList(u8) = .empty;
    defer short.deinit(a);
    try cpioEntry(&short, "a.cmd", "12345678", 0o100644);
    short.shrinkRetainingCapacity(short.items.len - 6);
    m = .{ .bytes = short.items };
    try testing.expectError(error.CorruptCpio, listCpio(m.src(), &listed));
    // The injection builds from trailer-less archives as well.
    var support: std.ArrayList(u8) = .empty;
    defer support.deinit(a);
    try cpioEntry(&support, "winpeshl.ini", "old", 0o100644);
    var helpers: std.ArrayList(u8) = .empty;
    defer helpers.deinit(a);
    for ([_][2][]const u8{ .{ "usos-x86-csmwrap.exe", "MZ" }, .{ "usos-x86-csmwrap.cmd", "@echo off" }, .{ "winpeshl.ini", "[LaunchApps]" } }) |f| try cpioEntry(&helpers, f[0], f[1], 0o100644);
    var s1: update.Mem = .{ .bytes = support.items };
    var s2: update.Mem = .{ .bytes = helpers.items };
    var inj: Injection = .{};
    try inj.build(.{ .support = s1.src(), .helpers = s2.src(), .source_ini = "s", .target_ini = "t" });
    try testing.expectEqual(@as(usize, 6), inj.list().len);
}

test "PE10 injection: helper archives, flags, answer and the stornvme swap land in staging boot.wim" {
    const a = testing.allocator;
    var support: std.ArrayList(u8) = .empty;
    defer support.deinit(a);
    try cpio(&support, &.{ .{ "./usos-start.cmd", "start" }, .{ "winpeshl.ini", "old" }, .{ "usosnvme-nt6.sys", "NVME DRIVER" } });
    var helpers: std.ArrayList(u8) = .empty;
    defer helpers.deinit(a);
    try cpio(&helpers, &.{ .{ "usos-x86-csmwrap.exe", "MZ helper" }, .{ "usos-x86-csmwrap.cmd", "@echo off" }, .{ "winpeshl.ini", "[LaunchApps]" } });
    var s1: update.Mem = .{ .bytes = support.items };
    var s2: update.Mem = .{ .bytes = helpers.items };
    var inj: Injection = .{};
    try inj.build(.{ .support = s1.src(), .helpers = s2.src(), .source_ini = "source=DATA\r\n", .target_ini = "target_bus=nvme\r\n", .answer = "<unattend/>", .modern_nvme = true, .pe_nvme = true });
    const adds = inj.list();
    try testing.expectEqual(@as(usize, 11), adds.len);
    try testing.expectEqualStrings("/Windows/System32/drivers/stornvme.sys", adds[adds.len - 1].path);
    // NTFS staging volume in memory.
    const disk_bytes = try a.alloc(u8, 80 * 1024 * 1024);
    defer a.free(disk_bytes);
    @memset(disk_bytes, 0);
    var memory: NtfsMemory = .{ .bytes = disk_bytes };
    var fs = try ntfs.Ntfs.init(memory.disk(), .{ .start_bytes = 1024 * 1024, .size_bytes = disk_bytes.len - 1024 * 1024 }, a, 0x1234);
    defer fs.deinit();
    try fs.format();
    const sources = try fs.mkdir(5, std.unicode.utf8ToUtf16LeStringLiteral("sources"), .{});
    const donor_bytes = try update.buildWim(update.tree_root, update.other_root, null);
    defer a.free(donor_bytes);
    var donor_mem: update.Mem = .{ .bytes = donor_bytes };
    var donor = try wim.Archive.open(a, donor_mem.input(), 2);
    defer donor.deinit();
    const number = try writeStagingBootWim(a, &fs, sources, &donor, &inj, .{ .guid = @splat(3), .timestamp = 5 });
    try fs.finish();
    // Independent read of the written file: winpeshl.ini is the helper one.
    var file: NtfsFile = .{ .fs = &fs, .number = number };
    const size = (try fs.fileStats(number)).size;
    var archive = try wim.Archive.open(a, .{ .context = &file, .size = size, .read_fn = NtfsFile.read }, 1);
    defer archive.deinit();
    try archive.verifyAll();
    try testing.expectEqual(@as(u32, 1), (try archive.find(update.sha("[LaunchApps]"))).references);
    try testing.expectEqual(@as(u32, 2), (try archive.find(update.sha("NVME DRIVER"))).references);
    try testing.expectEqual(@as(u32, 2), (try archive.find(update.sha(flag_one))).references);
    try testing.expectError(error.MissingWimResource, archive.find(update.sha("old")));
    var bad: Injection = .{};
    try testing.expectError(error.HelperFilesIncomplete, bad.build(.{ .support = s1.src(), .helpers = s1.src(), .source_ini = "", .target_ini = "" }));
}
