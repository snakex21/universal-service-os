//! Host-only independent-codec vector runner. Reads a generated regular file;
//! no writable disk handle or firmware dependency. Fixtures stay outside repo.
const std = @import("std");
const codec = @import("wim_codec.zig");
const lzms = @import("wim_lzms.zig");
const platform = @import("platform.zig");
fn read(file: std.Io.File, io: std.Io, offset: *u64, out: []u8) !void {
    if (try file.readPositionalAll(io, out, offset.*) != out.len) return error.ShortVector;
    offset.* += out.len;
}
pub fn main(init: std.process.Init) !u8 {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const path = args.next() orelse return error.MissingVectors;
    if (args.next() != null or !std.fs.path.isAbsolute(path) or std.mem.startsWith(u8, path, "\\\\")) return error.InvalidArgument;
    const file = try std.Io.Dir.openFileAbsolute(init.io, path, .{ .mode = .read_only });
    defer file.close(init.io);
    const stat = try file.stat(init.io);
    if (stat.kind != .file) return error.InvalidArgument;
    var position: u64 = 0;
    var header: [12]u8 = undefined;
    try read(file, init.io, &position, &header);
    if (!std.mem.eql(u8, header[0..8], "USWIMC01")) return error.InvalidArgument;
    const count = std.mem.readInt(u32, header[8..12], .little);
    if (count == 0 or count > 5000) return error.InvalidArgument;
    var peak: usize = 0;
    var bytes: u64 = 0;
    var lzms_stats: lzms.Stats = .{};
    for (0..count) |i| {
        var row: [9]u8 = undefined;
        try read(file, init.io, &position, &row);
        const kind: codec.Kind = switch (row[0]) {
            1 => .xpress,
            2 => .lzx,
            3 => .lzms,
            else => return error.InvalidArgument,
        };
        const size = std.mem.readInt(u32, row[1..5], .little);
        const compressed_size = std.mem.readInt(u32, row[5..9], .little);
        const estimate = try codec.memoryEstimate(kind, size);
        if (compressed_size == 0 or compressed_size > size * 4 + 4096) return error.InvalidArgument;
        const original = try init.gpa.alloc(u8, size);
        defer init.gpa.free(original);
        const compressed = try init.gpa.alloc(u8, compressed_size);
        defer init.gpa.free(compressed);
        const output = try init.gpa.alloc(u8, size);
        defer init.gpa.free(output);
        try read(file, init.io, &position, original);
        try read(file, init.io, &position, compressed);
        var allocator: platform.TrackedAllocator = .{ .backing = init.gpa, .limit = estimate };
        const operation = if (kind == .lzms)
            lzms.decodeWithStats(compressed, output, allocator.allocator(), &lzms_stats)
        else
            codec.decode(kind, compressed, output, allocator.allocator());
        operation catch |err| {
            std.debug.print("FAIL vector={d} codec={s} out={d} in={d} error={s}\n", .{ i, @tagName(kind), size, compressed_size, @errorName(err) });
            return err;
        };
        if (!std.mem.eql(u8, original, output)) {
            std.debug.print("FAIL vector={d} codec={s} bytes_differ\n", .{ i, @tagName(kind) });
            return error.WrongBytes;
        }
        if (allocator.current != 0 or allocator.peak > estimate) return error.MemoryBudget;
        peak = @max(peak, allocator.peak);
        bytes += size;
    }
    if (position != stat.size) return error.TrailingVectors;
    std.debug.print("WIM CODEC VECTORS PASS count={d} bytes={d} workspace_peak={d} exact_bytes=true C_linked=false\n", .{ count, bytes, peak });
    std.debug.print("LZMS literal={d} lz={d} repeat={d} delta={d} delta_repeat={d} rebuilds={d} x86_translated={d}\n", .{ lzms_stats.literals, lzms_stats.lz, lzms_stats.lz_repeat, lzms_stats.delta, lzms_stats.delta_repeat, lzms_stats.rebuilds, lzms_stats.translated });
    return 0;
}
