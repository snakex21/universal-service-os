//! File-only host gate for the firmware's common REGF/BCD writer.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const regf = @import("regf.zig");
const bcd = @import("bcd.zig");
const u = std.unicode.utf8ToUtf16LeStringLiteral;
fn validPath(path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path) or std.mem.startsWith(u8, path, "\\\\") or std.mem.startsWith(u8, path, "//") or std.mem.indexOfAny(u8, path, "\x00\r\n") != null) return error.RegularFileRequired;
}
fn write(io: std.Io, path: []const u8, data: []const u8) !void {
    try validPath(path);
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true }); defer file.close(io);
    try file.writePositionalAll(io, data, 0);
}
fn read(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    try validPath(path);
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only }); defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size > regf.max_hive) return error.RegularFileRequired;
    const out = try a.alloc(u8, @intCast(stat.size)); errdefer a.free(out);
    if (try file.readPositionalAll(io, out, 0) != out.len) return error.ShortRead;
    return out;
}
fn fixture(a: std.mem.Allocator, io: std.Io, out: []const u8) !void {
    try validPath(out); try std.Io.Dir.createDirAbsolute(io, out, .default_dir);
    var hive = try regf.Hive.init(a, u("ROOT"), 134053056000000000); defer hive.deinit();
    const key = try hive.ensureKey(u("AllTypes\\Zażółć"));
    for (0..12) |kind| {
        const name = [_]u16{ 'T', 'y', 'p', 'e', @intCast('A' + kind) };
        var bytes: [8]u8 = .{ @intCast(kind), 1, 2, 3, 4, 5, 6, 7 };
        try hive.setValue(key, &name, @intCast(kind), bytes[0..if (kind==4 or kind==5) 4 else 8]);
    }
    try hive.setValue(key, u(""), 0, "");
    const big = try a.alloc(u8, 131129); defer a.free(big);
    for (big, 0..) |*byte, i| byte.* = @truncate(i *% 31);
    try hive.setValue(key, u("Big"), 3, big);
    try hive.setValue(key, u("Inline"), 4, &.{0x78,0x56,0x34,0x12});
    try hive.seal();
    const original = try std.fs.path.join(a, &.{out, "fresh.hiv"}); defer a.free(original);
    try write(io, original, hive.bytes.items);
    var edited = try regf.Hive.open(a, hive.bytes.items, 134053056000000001); defer edited.deinit();
    try edited.setValue(key, u("Big"), 3, "replacement");
    const added = try edited.ensureKey(u("Added\\Child"));
    try edited.setValue(added, u("Value"), 11, "01234567"); try edited.seal();
    const result = try std.fs.path.join(a, &.{out, "edited.hiv"}); defer a.free(result);
    try write(io, result, edited.bytes.items);
    std.debug.print("REGF_FIXTURE original={d} edited={d} big_data={d}\n", .{hive.bytes.items.len, edited.bytes.items.len, big.len});
}
pub fn main(init: std.process.Init) !u8 {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa); defer args.deinit(); _ = args.next();
    const command = args.next() orelse return error.MissingCommand;
    if (std.mem.eql(u8, command, "fixture")) {
        const out = args.next() orelse return error.MissingOutput;
        if (args.next() != null) return error.InvalidArgument;
        try fixture(init.gpa, init.io, out); return 0;
    }
    if (std.mem.eql(u8, command, "edit")) {
        const source = args.next() orelse return error.MissingSource; const target = args.next() orelse return error.MissingOutput;
        if (args.next() != null or std.ascii.eqlIgnoreCase(source, target)) return error.InvalidArgument;
        const input = try read(init.gpa, init.io, source); defer init.gpa.free(input);
        var hive = try regf.Hive.open(init.gpa, input, 134053056000000001); defer hive.deinit();
        try hive.setValue(try hive.ensureKey(u("MiniOSProof\\Added")), u("Proof"), 3, "offline-editor");
        try hive.seal(); try write(init.io, target, hive.bytes.items);
        std.debug.print("REGF_EDIT input={d} output={d}\n", .{input.len,hive.bytes.items.len}); return 0;
    }
    if (!std.mem.eql(u8, command, "bcd")) return error.InvalidCommand;
    const target = args.next() orelse return error.MissingOutput;
    const mode = std.meta.stringToEnum(bcd.Mode, args.next() orelse return error.MissingMode) orelse return error.InvalidMode;
    const style = args.next() orelse return error.MissingStyle;
    const disk_id = args.next() orelse return error.MissingDisk;
    const win_id = args.next() orelse return error.MissingPartition;
    const sys_id = args.next() orelse return error.MissingPartition;
    const locale = try std.unicode.utf8ToUtf16LeAlloc(init.gpa, args.next() orelse return error.MissingLocale); defer init.gpa.free(locale);
    const description = try std.unicode.utf8ToUtf16LeAlloc(init.gpa, args.next() orelse return error.MissingDescription); defer init.gpa.free(description);
    const template = args.next(); if (args.next() != null) return error.InvalidArgument;
    var options: bcd.Options = .{.mode=mode,.system=undefined,.windows=undefined,.locale=locale,.description=description,.timestamp=134053056000000000};
    if (std.mem.eql(u8, style, "gpt")) {
        const disk = try bcd.parseGuid(disk_id);
        options.windows = .{.gpt=.{.disk=disk,.partition=try bcd.parseGuid(win_id)}};
        options.system = .{.gpt=.{.disk=disk,.partition=try bcd.parseGuid(sys_id)}};
    } else if (std.mem.eql(u8, style, "mbr")) {
        const signature = try std.fmt.parseInt(u32, disk_id, 0);
        options.windows = .{.mbr=.{.signature=signature,.offset=try std.fmt.parseInt(u64,win_id,0)}};
        options.system = .{.mbr=.{.signature=signature,.offset=try std.fmt.parseInt(u64,sys_id,0)}};
    } else return error.InvalidStyle;
    const bytes = if (template) |source| blk: {
        const input = try read(init.gpa, init.io, source); defer init.gpa.free(input);
        break :blk try bcd.fromTemplate(init.gpa, input, options);
    } else try bcd.create(init.gpa, options);
    defer init.gpa.free(bytes); try write(init.io, target, bytes);
    std.debug.print("BCD_WRITE mode={s} style={s} bytes={d} template={any}\n", .{@tagName(mode),style,bytes.len,template!=null}); return 0;
}
