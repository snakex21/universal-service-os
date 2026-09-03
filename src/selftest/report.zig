pub const Report = struct {
    total: usize = 0,
    passed: usize = 0,
    failed: usize = 0,

    pub fn record(self: *Report, ok: bool) void {
        self.total += 1;
        if (ok) {
            self.passed += 1;
        } else {
            self.failed += 1;
        }
    }

    pub fn allPassed(self: Report) bool {
        return self.failed == 0 and self.passed == self.total;
    }
};

test "report counts successful and failed checks" {
    const std = @import("std");
    var report = Report{};
    report.record(true);
    report.record(false);
    report.record(true);

    try std.testing.expectEqual(@as(usize, 3), report.total);
    try std.testing.expectEqual(@as(usize, 2), report.passed);
    try std.testing.expectEqual(@as(usize, 1), report.failed);
    try std.testing.expect(!report.allPassed());
}
