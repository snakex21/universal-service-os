//! Golden-file comparison for characterization tests (refactor M0,
//! docs/design/refactor-os-pipeline.md section 4).
//!
//! A golden file is committed next to the test that embeds it. The test
//! renders the current behaviour as text and compares it with the file.
//!
//!   mismatch            -> the actual text is written to
//!                          tools/tests/artifacts/golden/<name> (ignored by git)
//!                          and the first differing line is printed
//!   USOS_UPDATE_GOLDEN=1 -> the actual text overwrites <update_path>; review
//!                          the diff before committing it
//!
//! CR bytes are ignored on both sides: git may check the files out with CRLF.
const std = @import("std");

pub fn expectGolden(name: []const u8, update_path: []const u8, expected: []const u8, actual: []const u8) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const want = try stripCr(gpa, expected);
    defer gpa.free(want);
    const got = try stripCr(gpa, actual);
    defer gpa.free(got);
    if (std.testing.environ.containsUnempty(gpa, "USOS_UPDATE_GOLDEN") catch false) {
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = update_path, .data = got }) catch |err| {
            std.debug.print("golden {s}: cannot update {s}: {s}\n", .{ name, update_path, @errorName(err) });
            return err;
        };
        std.debug.print("golden {s}: updated {s}\n", .{ name, update_path });
        return;
    }
    if (std.mem.eql(u8, want, got)) return;

    const artifacts = "tools/tests/artifacts/golden";
    var path_buffer: [256]u8 = undefined;
    const actual_path = std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ artifacts, name }) catch artifacts;
    std.Io.Dir.cwd().createDirPath(io, artifacts) catch {};
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = actual_path, .data = got }) catch {};

    var want_lines = std.mem.splitScalar(u8, want, '\n');
    var got_lines = std.mem.splitScalar(u8, got, '\n');
    var line: usize = 1;
    while (true) : (line += 1) {
        const a = want_lines.next();
        const b = got_lines.next();
        if (a == null and b == null) break;
        if (a != null and b != null and std.mem.eql(u8, a.?, b.?)) continue;
        std.debug.print(
            "golden {s} differs at line {d}\n  expected: {s}\n  actual:   {s}\n  full actual output: {s}\n  (after review: USOS_UPDATE_GOLDEN=1 zig build test updates {s})\n",
            .{ name, line, a orelse "<end of file>", b orelse "<end of output>", actual_path, update_path },
        );
        break;
    }
    return error.GoldenMismatch;
}

fn stripCr(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, text.len);
    var len: usize = 0;
    for (text) |byte| {
        if (byte == '\r') continue;
        out[len] = byte;
        len += 1;
    }
    return gpa.realloc(out, len);
}
