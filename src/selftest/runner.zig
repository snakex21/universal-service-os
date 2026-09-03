const Case = @import("case.zig").Case;
const Report = @import("report.zig").Report;

pub const Observer = *const fn (name: []const u8, ok: bool) void;

pub fn run(cases: []const Case, observer: ?Observer) Report {
    var report = Report{};

    for (cases) |item| {
        const ok = item.run();
        report.record(ok);
        if (observer) |notify| notify(item.name, ok);
    }

    return report;
}

fn alwaysPass() bool {
    return true;
}

fn alwaysFail() bool {
    return false;
}

test "runner executes every registered check" {
    const std = @import("std");
    const cases = [_]Case{
        .{ .name = "pass", .run = alwaysPass },
        .{ .name = "fail", .run = alwaysFail },
    };

    const report = run(&cases, null);
    try std.testing.expectEqual(@as(usize, 2), report.total);
    try std.testing.expectEqual(@as(usize, 1), report.passed);
    try std.testing.expectEqual(@as(usize, 1), report.failed);
}
