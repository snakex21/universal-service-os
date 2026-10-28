//! `usos-fb-ui --nt35-initial IN OUT` (micro-Linux, tools/nt4_csmwrap_target.sh,
//! native NT 3.5 only; docs/nt-native-plan.md) and the host tool
//! `usos-win3x-display nt35-initial IN OUT`. Own implementation,
//! GPL-3.0-or-later.
//!
//! NT 3.5 GUI-mode Setup (INITIAL.INF) asks setupdll's GetProcessor for the
//! CPU and refuses anything it does not know as I386 / I486 / I586 with a
//! fatal "processor not supported" page. The install VM worked around it
//! with -cpu pentium (QEMU 2026-10-09); on the X470 (Zen 3) GUI Setup runs on
//! the real CPU. This tool reads the CD's INITIAL.IN_ (one-file MSZIP
//! cabinet) or a plain INITIAL.INF and adds, right after the line
//! `detect ProcessorVar`, the line
//!
//!     set STF_PROCESSOR = $(ProcessorID_I586) ;USOS-NT35-CPU
//!
//! so the I586 branch runs (an x86 PC, as on the Pentium VM). Nothing else in
//! the file changes; the marker makes a second run a no-op. A cabinet is
//! written again with its original header (cab.build: stored deflate blocks
//! in one MSZIP folder) and checked by parsing it back; a plain file stays
//! plain. Exit: 0 patched or already patched, 1 the file has no
//! `detect ProcessorVar` line or is not the one-file INITIAL.INF cabinet,
//! 2 usage, 3 I/O error. One log line on stderr.
const std = @import("std");
const cab = @import("cab.zig");

pub const marker = ";USOS-NT35-CPU";
const max_file = 4 * 1024 * 1024;

pub const Error = error{ NoDetectLine, OutOfMemory };

fn isDetectLine(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t\r\n");
    if (t.len < "detect".len or !std.ascii.eqlIgnoreCase(t[0.."detect".len], "detect")) return false;
    const rest = std.mem.trim(u8, t["detect".len..], " \t");
    if (rest.len == t.len - "detect".len) return false; // "detectX": no separator
    return std.ascii.eqlIgnoreCase(rest, "ProcessorVar");
}

/// The patched text, or null when `text` already carries the marker.
pub fn patchText(gpa: std.mem.Allocator, text: []const u8) Error!?[]u8 {
    if (std.mem.indexOf(u8, text, marker) != null) return null;
    var start: usize = 0;
    while (start < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, start, '\n');
        const end = if (nl) |i| i + 1 else text.len;
        const line = text[start..end];
        if (isDetectLine(line)) {
            const indent_len = std.mem.indexOfNone(u8, line, " \t") orelse 0;
            const eol: []const u8 = if (std.mem.endsWith(u8, line, "\r\n")) "\r\n" else "\n";
            const prefix_eol: []const u8 = if (nl == null) eol else "";
            const insert = try std.fmt.allocPrint(gpa, "{s}{s}set STF_PROCESSOR = $(ProcessorID_I586) {s}{s}", .{ prefix_eol, line[0..indent_len], marker, eol });
            defer gpa.free(insert);
            return try std.mem.concat(gpa, u8, &.{ text[0..end], insert, text[end..] });
        }
        start = end;
    }
    return error.NoDetectLine;
}

pub const Outcome = enum { patched, already, no_detect_line, not_initial_cab, corrupt };

/// `raw` (INITIAL.IN_ cabinet or plain INITIAL.INF) -> new bytes in `out`.
pub fn rebuild(gpa: std.mem.Allocator, raw: []const u8, out: *?[]u8) Outcome {
    out.* = null;
    if (!cab.isCab(raw)) {
        const patched = patchText(gpa, raw) catch |err| return if (err == error.NoDetectLine) .no_detect_line else .corrupt;
        out.* = patched orelse return .already;
        return .patched;
    }
    var parsed = cab.parse(gpa, raw) catch return .corrupt;
    defer parsed.deinit(gpa);
    if (parsed.files.len != 1 or !std.ascii.eqlIgnoreCase(parsed.files[0].name, "initial.inf")) return .not_initial_cab;
    const patched = (patchText(gpa, parsed.files[0].data) catch |err| return if (err == error.NoDetectLine) .no_detect_line else .corrupt) orelse return .already;
    defer gpa.free(patched);
    var file = parsed.files[0];
    file.data = patched;
    const data = cab.build(gpa, &parsed, &.{file}) catch return .corrupt;
    // Parsed back to exactly the patched file, or nothing is written.
    var check = cab.parse(gpa, data) catch {
        gpa.free(data);
        return .corrupt;
    };
    defer check.deinit(gpa);
    if (check.files.len != 1 or !std.mem.eql(u8, check.files[0].data, patched) or !std.mem.eql(u8, check.files[0].name, parsed.files[0].name)) {
        gpa.free(data);
        return .corrupt;
    }
    out.* = data;
    return .patched;
}

pub fn run(io: std.Io, gpa: std.mem.Allocator, in_path: []const u8, out_path: []const u8) u8 {
    const cwd = std.Io.Dir.cwd();
    const raw = cwd.readFileAlloc(io, in_path, gpa, .limited(max_file)) catch |err| {
        std.debug.print("[NT35_INITIAL] {s}: {s}\n", .{ in_path, @errorName(err) });
        return 3;
    };
    defer gpa.free(raw);
    var data: ?[]u8 = null;
    const outcome = rebuild(gpa, raw, &data);
    defer if (data) |d| gpa.free(d);
    switch (outcome) {
        .patched => {
            cwd.writeFile(io, .{ .sub_path = out_path, .data = data.? }) catch |err| {
                std.debug.print("[NT35_INITIAL] {s}: {s}\n", .{ out_path, @errorName(err) });
                return 3;
            };
            std.debug.print("[NT35_INITIAL] {s}: STF_PROCESSOR = I586 after detect ProcessorVar ({s}, {d} bytes)\n", .{ in_path, if (cab.isCab(raw)) "cabinet" else "plain", data.?.len });
            return 0;
        },
        .already => {
            cwd.writeFile(io, .{ .sub_path = out_path, .data = raw }) catch return 3;
            std.debug.print("[NT35_INITIAL] {s}: already patched\n", .{in_path});
            return 0;
        },
        else => {
            std.debug.print("[NT35_INITIAL] {s}: not patched ({s})\n", .{ in_path, @tagName(outcome) });
            return 1;
        },
    }
}

const sample =
    "[ProcessorVar]\r\n    STF_PROCESSOR = \"\" ? $(!LIBHANDLE) GetProcessor\r\n" ++
    "[Shell Commands]\r\n    read-syms ProcessorVar\r\n    detect    ProcessorVar\r\n" ++
    "    ifstr(i) $(STF_PROCESSOR) == $(ProcessorID_I386)\r\n";

test "the I586 line goes right after detect ProcessorVar, once" {
    const gpa = std.testing.allocator;
    const out = (try patchText(gpa, sample)).?;
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "    detect    ProcessorVar\r\n    set STF_PROCESSOR = $(ProcessorID_I586) ;USOS-NT35-CPU\r\n    ifstr(i)") != null);
    try std.testing.expectEqual(sample.len + "    set STF_PROCESSOR = $(ProcessorID_I586) ;USOS-NT35-CPU\r\n".len, out.len);
    try std.testing.expect((try patchText(gpa, out)) == null);
    // LF files keep LF; read-syms / a [ProcessorVar] header are no detect line.
    const lf = (try patchText(gpa, "read-syms ProcessorVar\ndetect ProcessorVar\nx\n")).?;
    defer gpa.free(lf);
    try std.testing.expectEqualStrings("read-syms ProcessorVar\ndetect ProcessorVar\nset STF_PROCESSOR = $(ProcessorID_I586) ;USOS-NT35-CPU\nx\n", lf);
    try std.testing.expectError(error.NoDetectLine, patchText(gpa, "[ProcessorVar]\r\ndetectProcessorVar\r\n"));
}

test "a one-file INITIAL.INF cabinet is rebuilt with the patch" {
    const gpa = std.testing.allocator;
    // A cabinet made by cab.build from a minimal header-only "like".
    var header: [36]u8 = @splat(0);
    @memcpy(header[0..4], "MSCF");
    header[24] = 3; // version 1.3
    header[25] = 1;
    header[26] = 1; // one folder
    const like = cab.Cabinet{ .header = &header, .folder_reserve = 0, .data_reserve = 0, .folder_extra = &.{}, .compress = 1, .files = &.{}, .body = &.{} };
    const original = try cab.build(gpa, &like, &.{.{ .name = "initial.inf", .data = sample, .date = 0x1d25, .time = 0x2b1b, .attribs = 0x20 }});
    defer gpa.free(original);
    var data: ?[]u8 = null;
    try std.testing.expectEqual(Outcome.patched, rebuild(gpa, original, &data));
    defer gpa.free(data.?);
    var back = try cab.parse(gpa, data.?);
    defer back.deinit(gpa);
    try std.testing.expectEqualStrings("initial.inf", back.files[0].name);
    try std.testing.expect(std.mem.indexOf(u8, back.files[0].data, marker) != null);
    try std.testing.expectEqual(@as(u16, 0x1d25), back.files[0].date);
    var again: ?[]u8 = null;
    try std.testing.expectEqual(Outcome.already, rebuild(gpa, data.?, &again));
    // Another file in the cabinet: not ours to patch.
    const other = try cab.build(gpa, &like, &.{.{ .name = "registry.inf", .data = sample, .date = 0, .time = 0, .attribs = 0 }});
    defer gpa.free(other);
    try std.testing.expectEqual(Outcome.not_initial_cab, rebuild(gpa, other, &again));
}
