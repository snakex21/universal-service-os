//! usosprep-csmwrap-plan TOTAL SIGNATURE_HEX BUS MBR440 OUT_MBR OUT_INI
//! [BCD_IN BCD_OUT]
//! usosprep-csmwrap-plan iso ISO OUT_DIR: the ISO files the route takes
//! (MiniOS's own ISO reader), their sizes and SHA-256, the boot index.
//! Host tool for tools/tests/test_minios_csmwrap_alpine.py: the MiniOS
//! CSMWrap route's deterministic outputs (layout, final MBR with the ESP
//! slot, usos-csmwrap-target.ini; optionally the NVMe staging BCD edit) for
//! comparison with tools/vista_csmwrap_target.sh / xp_csmwrap_esp.sh /
//! usos-fb-ui run on the same inputs.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const csm = @import("csmwrap_target.zig");
const bcd_lowmem = @import("bcd_lowmem");
const optical = @import("optical.zig");
const platform = @import("platform.zig");

const HostFile = struct {
    io: std.Io,
    file: std.Io.File,
    fn read(ctx: *anyopaque, at: u64, out: []u8) platform.Error!void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if ((self.file.readPositionalAll(self.io, out, at) catch return error.Io) != out.len) return error.Io;
    }
};

fn isoMode(io: std.Io, gpa: std.mem.Allocator, iso_path: []const u8, out_dir: []const u8) !u8 {
    var host: HostFile = .{ .io = io, .file = try std.Io.Dir.cwd().openFile(io, iso_path, .{ .mode = .read_only }) };
    defer host.file.close(io);
    const size = (try host.file.stat(io)).size;
    const volume = try gpa.create(optical.Volume);
    defer gpa.destroy(volume);
    try optical.Volume.openInto(.{ .context = &host, .size = size, .read_fn = HostFile.read }, volume);
    const buffer = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(buffer);
    // The names exactly as runCsmwrapSetup asks for them.
    for ([_][]const u8{ "bootmgr", "boot\\bcd", "boot\\boot.sdi", "sources\\boot.wim" }) |name| {
        const stream = try gpa.create(optical.Stream);
        defer gpa.destroy(stream);
        stream.* = .{ .input = volume.input, .node = undefined };
        try volume.findInto(name, &stream.node);
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        var at: u64 = 0;
        var out_name: [64]u8 = undefined;
        const base = name[if (std.mem.lastIndexOfScalar(u8, name, '\\')) |i| i + 1 else 0..];
        var path_buf: [1024]u8 = undefined;
        const out_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ out_dir, try std.fmt.bufPrint(&out_name, "{s}", .{base}) });
        const out = try std.Io.Dir.cwd().createFile(io, out_path, .{});
        defer out.close(io);
        while (at < stream.node.size) {
            const n: usize = @intCast(@min(buffer.len, stream.node.size - at));
            try optical.Stream.read(stream, at, buffer[0..n]);
            hash.update(buffer[0..n]);
            try out.writePositionalAll(io, buffer[0..n], at);
            at += n;
        }
        if (std.mem.eql(u8, base, "boot.wim")) {
            var head: [208]u8 = undefined;
            try optical.Stream.read(stream, 0, &head);
            std.debug.print("boot_index={d}\n", .{std.mem.readInt(u32, head[120..124], .little)});
        }
        std.debug.print("{s} bytes={d} sha256={s}\n", .{ name, stream.node.size, std.fmt.bytesToHex(hash.finalResult(), .lower) });
    }
    return 0;
}

fn writeAll(io: std.Io, path: []const u8, data: []const u8) !void {
    const out = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer out.close(io);
    try out.writePositionalAll(io, data, 0);
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next();
    const first = args.next() orelse return 2;
    if (std.mem.eql(u8, first, "iso")) return isoMode(io, gpa, args.next() orelse return 2, args.next() orelse return 2);
    const total = try std.fmt.parseInt(u64, first, 10);
    const signature = try std.fmt.parseInt(u32, args.next() orelse return 2, 16);
    const bus = args.next() orelse return 2;
    const code_path = args.next() orelse return 2;
    const out_mbr = args.next() orelse return 2;
    const out_ini = args.next() orelse return 2;
    const cwd = std.Io.Dir.cwd();
    const code_bytes = try cwd.readFileAlloc(io, code_path, gpa, .limited(4096));
    defer gpa.free(code_bytes);
    if (code_bytes.len != 440) return 3;
    const l = try csm.Layout.compute(total);
    var mbr = csm.buildMbr(code_bytes[0..440], signature, l);
    _ = try csm.addEspEntry(&mbr, l.esp_start);
    try csm.verifyFinal(&mbr, l);
    try writeAll(io, out_mbr, &mbr);
    var ini_buf: [512]u8 = undefined;
    try writeAll(io, out_ini, try csm.targetIni(&ini_buf, signature, l, std.mem.eql(u8, bus, "nvme")));
    if (args.next()) |bcd_in| {
        const bcd_out = args.next() orelse return 2;
        const buffer = try gpa.alloc(u8, bcd_lowmem.max_hive);
        defer gpa.free(buffer);
        const bytes = try cwd.readFileAlloc(io, bcd_in, gpa, .limited(bcd_lowmem.max_hive));
        defer gpa.free(bytes);
        @memcpy(buffer[0..bytes.len], bytes);
        var len = bytes.len;
        _ = try bcd_lowmem.apply(buffer, &len, bcd_lowmem.truncatememory);
        if ((try bcd_lowmem.check(buffer[0..len], bcd_lowmem.truncatememory)) != true) return 4;
        try writeAll(io, bcd_out, buffer[0..len]);
    }
    std.debug.print("windows_start={d} windows_sectors={d} staging_start={d} staging_sectors={d} esp_start={d}\n", .{ l.windows_start, l.windows_sectors, l.staging_start, l.staging_sectors, l.esp_start });
    return 0;
}
