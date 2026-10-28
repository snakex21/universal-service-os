//! `usos-fb-ui --nt3-cab-get CAB OUT` and `usos-fb-ui --nt3-cab-put CAB FILE
//! OUT` (micro-Linux, tools/nt4_csmwrap_target.sh, native NT 3.51 LAN;
//! docs/nt351-native-net-2026-10-28.md). Own implementation,
//! GPL-3.0-or-later.
//!
//! The NT 3.5x CDs ship their INF files as one-file MSZIP cabinets
//! (OEMNADLB.IN_). The install VM patched the expanded copy in system32
//! between its starts (usos_nt351_vm_patch); without the VM the local source
//! is patched before text mode copies it. `get` writes the one file of the
//! cabinet; `put` writes the cabinet again with that file's bytes replaced
//! (original header, name, date, time and attributes; cab.build: stored
//! deflate blocks in one MSZIP folder) and checks it by parsing it back.
//! The patch itself stays in the shell (usos_nt351_loop_inf with its
//! source / result hash pins). Exit: 0 done, 1 not a one-file cabinet or the
//! rebuilt cabinet does not parse back, 2 usage, 3 I/O error. One log line
//! on stderr.
const std = @import("std");
const cab = @import("cab.zig");

const max_file = 4 * 1024 * 1024;

pub const Error = error{ NotOneFileCab, Corrupt, OutOfMemory };

/// The one file's bytes (caller frees).
pub fn get(gpa: std.mem.Allocator, raw: []const u8) Error![]u8 {
    if (!cab.isCab(raw)) return error.NotOneFileCab;
    var parsed = cab.parse(gpa, raw) catch return error.Corrupt;
    defer parsed.deinit(gpa);
    if (parsed.files.len != 1) return error.NotOneFileCab;
    return try gpa.dupe(u8, parsed.files[0].data);
}

/// The cabinet `raw` with its one file's data replaced by `data`, parsed
/// back to exactly that file (caller frees).
pub fn put(gpa: std.mem.Allocator, raw: []const u8, data: []const u8) Error![]u8 {
    if (!cab.isCab(raw)) return error.NotOneFileCab;
    var parsed = cab.parse(gpa, raw) catch return error.Corrupt;
    defer parsed.deinit(gpa);
    if (parsed.files.len != 1) return error.NotOneFileCab;
    var file = parsed.files[0];
    file.data = data;
    const out = cab.build(gpa, &parsed, &.{file}) catch return error.Corrupt;
    errdefer gpa.free(out);
    var check = cab.parse(gpa, out) catch return error.Corrupt;
    defer check.deinit(gpa);
    if (check.files.len != 1 or !std.mem.eql(u8, check.files[0].data, data) or
        !std.mem.eql(u8, check.files[0].name, parsed.files[0].name) or
        check.files[0].date != parsed.files[0].date or check.files[0].time != parsed.files[0].time)
        return error.Corrupt;
    return out;
}

fn readAll(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file)) catch |err| {
        std.debug.print("[NT3_CAB] {s}: {s}\n", .{ path, @errorName(err) });
        return null;
    };
}

pub fn runGet(io: std.Io, gpa: std.mem.Allocator, cab_path: []const u8, out_path: []const u8) u8 {
    const raw = readAll(io, gpa, cab_path) orelse return 3;
    defer gpa.free(raw);
    const data = get(gpa, raw) catch |err| {
        std.debug.print("[NT3_CAB] {s}: {s}\n", .{ cab_path, @errorName(err) });
        return 1;
    };
    defer gpa.free(data);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = data }) catch return 3;
    std.debug.print("[NT3_CAB] {s}: one file, {d} bytes\n", .{ cab_path, data.len });
    return 0;
}

pub fn runPut(io: std.Io, gpa: std.mem.Allocator, cab_path: []const u8, file_path: []const u8, out_path: []const u8) u8 {
    const raw = readAll(io, gpa, cab_path) orelse return 3;
    defer gpa.free(raw);
    const data = readAll(io, gpa, file_path) orelse return 3;
    defer gpa.free(data);
    const out = put(gpa, raw, data) catch |err| {
        std.debug.print("[NT3_CAB] {s}: {s}\n", .{ cab_path, @errorName(err) });
        return 1;
    };
    defer gpa.free(out);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = out }) catch return 3;
    std.debug.print("[NT3_CAB] {s}: rebuilt with {d}-byte file ({d} bytes, parsed back)\n", .{ cab_path, data.len, out.len });
    return 0;
}

test "one-file cabinet: get, put, parse back; two files refused" {
    const gpa = std.testing.allocator;
    var header: [36]u8 = @splat(0);
    @memcpy(header[0..4], "MSCF");
    header[24] = 3;
    header[25] = 1;
    header[26] = 1;
    const like = cab.Cabinet{ .header = &header, .folder_reserve = 0, .data_reserve = 0, .folder_extra = &.{}, .compress = 1, .files = &.{}, .body = &.{} };
    const original = try cab.build(gpa, &like, &.{.{ .name = "oemnadlb.inf", .data = "adapteroptions = +\r\n", .date = 0x1eba, .time = 0x5f20, .attribs = 0x20 }});
    defer gpa.free(original);
    const text = try get(gpa, original);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("adapteroptions = +\r\n", text);
    const rebuilt = try put(gpa, original, "adapteroptions = +\r\n    ;USOS\r\n");
    defer gpa.free(rebuilt);
    var back = try cab.parse(gpa, rebuilt);
    defer back.deinit(gpa);
    try std.testing.expectEqualStrings("oemnadlb.inf", back.files[0].name);
    try std.testing.expectEqualStrings("adapteroptions = +\r\n    ;USOS\r\n", back.files[0].data);
    try std.testing.expectEqual(@as(u16, 0x1eba), back.files[0].date);
    const two = try cab.build(gpa, &like, &.{ .{ .name = "a.inf", .data = "a", .date = 0, .time = 0, .attribs = 0 }, .{ .name = "b.inf", .data = "b", .date = 0, .time = 0, .attribs = 0 } });
    defer gpa.free(two);
    try std.testing.expectError(error.NotOneFileCab, get(gpa, two));
    try std.testing.expectError(error.NotOneFileCab, put(gpa, "plain text", "x"));
}
