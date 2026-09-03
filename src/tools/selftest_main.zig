const std = @import("std");
const usos = @import("usos");

fn printResult(name: []const u8, ok: bool) void {
    std.debug.print("[{s}] {s}\n", .{ if (ok) "PASS" else "FAIL", name });
}

pub fn main() u8 {
    const report = usos.selftest.runStartup(printResult);
    std.debug.print("Self-test: {d}/{d} passed\n", .{ report.passed, report.total });
    return if (report.allPassed()) 0 else 1;
}
