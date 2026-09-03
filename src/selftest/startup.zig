const architecture = @import("../core/architecture.zig");
const Case = @import("case.zig").Case;
const runner = @import("runner.zig");
const Report = @import("report.zig").Report;

fn architectureIsSupported() bool {
    return architecture.current() != .unsupported;
}

fn pointerWidthIsSupported() bool {
    return @sizeOf(usize) == 4 or @sizeOf(usize) == 8;
}

const checks = [_]Case{
    .{ .name = "supported architecture", .run = architectureIsSupported },
    .{ .name = "supported pointer width", .run = pointerWidthIsSupported },
};

pub fn run(observer: ?runner.Observer) Report {
    return runner.run(&checks, observer);
}

test "startup self-test passes on a supported development target" {
    const std = @import("std");
    try std.testing.expect(run(null).allPassed());
}
