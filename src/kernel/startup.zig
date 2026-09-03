const runner = @import("../selftest/runner.zig");
const startup_selftest = @import("../selftest/startup.zig");

pub const Decision = enum {
    continue_boot,
    halt,
};

pub fn validate(observer: ?runner.Observer) Decision {
    return if (startup_selftest.run(observer).allPassed()) .continue_boot else .halt;
}

test "kernel continues when critical startup checks pass" {
    const std = @import("std");
    try std.testing.expectEqual(Decision.continue_boot, validate(null));
}
