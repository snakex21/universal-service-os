//! Host tool for the WIM export+update writer (wim_update.zig): the same
//! work as `wimlib-imagex export SRC IDX DST --boot` + `wimlib-imagex update
//! DST 1 < COMMANDS`, for byte-level comparison with wimlib on Windows.
//! usage: usosprep-wim-update SRC.wim INDEX|boot OUT.wim COMMANDS.txt
//!        [--guid 32HEX] [--time FILETIME] [--security none|parent] [--attributes N]
//! COMMANDS lines: add "HOST-FILE" "/WIM/PATH" (the Alpine route's format).
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const wim = @import("wim.zig");
const update = @import("wim_update.zig");
const platform = @import("platform.zig");

const File = struct {
    io: std.Io,
    file: std.Io.File,
    size: u64 = 0,
    fn read(ctx: *anyopaque, at: u64, out: []u8) platform.Error!void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if ((self.file.readPositionalAll(self.io, out, at) catch return error.Io) != out.len) return error.Io;
    }
};
fn quoted(line: []const u8, from: *usize) ![]const u8 {
    const a = std.mem.indexOfScalarPos(u8, line, from.*, '"') orelse return error.InvalidCommand;
    const b = std.mem.indexOfScalarPos(u8, line, a + 1, '"') orelse return error.InvalidCommand;
    from.* = b + 1;
    return line[a + 1 .. b];
}
pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next();
    const src_path = args.next() orelse return error.MissingWim;
    const index_text = args.next() orelse return error.MissingIndex;
    const out_path = args.next() orelse return error.MissingOutput;
    const commands_path = args.next() orelse return error.MissingCommands;
    var options: update.Options = .{ .guid = @splat(0x55), .timestamp = 0x01dd695200000000 };
    while (args.next()) |flag| {
        const value = args.next() orelse return error.InvalidArgument;
        if (std.mem.eql(u8, flag, "--guid")) {
            if (value.len != 32) return error.InvalidArgument;
            _ = try std.fmt.hexToBytes(&options.guid, value);
        } else if (std.mem.eql(u8, flag, "--time")) {
            options.timestamp = try std.fmt.parseInt(u64, value, 0);
        } else if (std.mem.eql(u8, flag, "--security")) {
            options.security = if (std.mem.eql(u8, value, "parent")) .parent else if (std.mem.eql(u8, value, "none")) .none else return error.InvalidArgument;
        } else if (std.mem.eql(u8, flag, "--attributes")) {
            options.attributes = try std.fmt.parseInt(u32, value, 0);
        } else return error.InvalidArgument;
    }

    var src: File = .{ .io = io, .file = try std.Io.Dir.openFileAbsolute(io, src_path, .{ .mode = .read_only }) };
    defer src.file.close(io);
    src.size = (try src.file.stat(io)).size;
    var head: [208]u8 = undefined;
    try File.read(&src, 0, &head);
    const index: u32 = if (std.mem.eql(u8, index_text, "boot")) std.mem.readInt(u32, head[120..124], .little) else try std.fmt.parseInt(u32, index_text, 10);

    // Commands and their host files.
    const commands = try std.Io.Dir.cwd().readFileAlloc(io, commands_path, gpa, .limited(1 << 20));
    defer gpa.free(commands);
    var adds: std.ArrayList(update.Add) = .empty;
    defer adds.deinit(gpa);
    var files: std.ArrayList(*File) = .empty;
    defer {
        for (files.items) |f| {
            f.file.close(io);
            gpa.destroy(f);
        }
        files.deinit(gpa);
    }
    var lines = std.mem.tokenizeAny(u8, commands, "\r\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (!std.mem.startsWith(u8, trimmed, "add ")) return error.UnsupportedCommand;
        var at: usize = 4;
        const host = try quoted(trimmed, &at);
        const target = try quoted(trimmed, &at);
        const f = try gpa.create(File);
        f.* = .{ .io = io, .file = try std.Io.Dir.cwd().openFile(io, host, .{ .mode = .read_only }) };
        try files.append(gpa, f);
        f.size = (try f.file.stat(io)).size;
        try adds.append(gpa, .{ .path = target, .source = .{ .context = f, .size = f.size, .read_fn = File.read } });
    }

    var tracker: platform.TrackedAllocator = .{ .backing = gpa, .limit = 16 * 1024 * 1024 };
    const start = std.Io.Clock.awake.now(io);
    var archive = try wim.Archive.open(tracker.allocator(), .{ .context = &src, .size = src.size, .read_fn = File.read }, index);
    defer archive.deinit();
    const plan = try update.Plan.init(tracker.allocator(), &archive, adds.items, options);
    defer plan.deinit();
    const planned = std.Io.Clock.awake.now(io);
    const s = plan.stats;
    std.debug.print("PLAN index={d} size={d} dirs={d} files={d} total_bytes={d} hard_link_bytes={d} added={d} replaced={d} new_blobs={d} dedup={d} copied_blobs={d} dropped_blobs={d} copied_bytes={d} unsorted_parents={d} metadata_old={d} metadata_new={d}\n", .{ index, plan.size, s.dirs, s.files, s.total_bytes, s.hard_link_bytes, s.added, s.replaced, s.new_blobs, s.deduplicated, s.copied_blobs, s.dropped_blobs, s.copied_bytes, s.unsorted_parents, s.metadata_old, s.metadata_new });

    const out = try std.Io.Dir.createFileAbsolute(io, out_path, .{ .exclusive = true });
    defer out.close(io);
    // A fixed 64 KiB pull buffer, as an NTFS writeFile would use.
    const buffer = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(buffer);
    var at: u64 = 0;
    while (at < plan.size) {
        const n: usize = @intCast(@min(buffer.len, plan.size - at));
        plan.read(at, buffer[0..n]) catch |err| {
            std.debug.print("WRITE_FAIL at={d} error={s}\n", .{ at, @errorName(err) });
            return err;
        };
        try out.writePositionalAll(io, buffer[0..n], at);
        at += n;
    }
    const done = std.Io.Clock.awake.now(io);
    std.debug.print("WIM_UPDATE PASS bytes={d} plan_ms={d} write_ms={d} alloc_peak={d} alloc_current={d} pull_buffer={d}\n", .{ at, @divTrunc(planned.nanoseconds - start.nanoseconds, 1000000), @divTrunc(done.nanoseconds - planned.nanoseconds, 1000000), tracker.peak, tracker.current, buffer.len });
    return 0;
}
