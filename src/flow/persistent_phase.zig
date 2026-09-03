const std = @import("std");

pub const Phase = enum {
    pending,
    prepare_requested,
    prepared,
    handoff,

    pub fn value(self: Phase) []const u8 {
        return switch (self) {
            .pending => "pending",
            .prepare_requested => "prepare-requested",
            .prepared => "prepared",
            .handoff => "handoff",
        };
    }
};

pub const Error = error{InvalidPhase};

pub fn parse(value: []const u8) Error!Phase {
    if (std.mem.eql(u8, value, "pending")) return .pending;
    if (std.mem.eql(u8, value, "prepare-requested")) return .prepare_requested;
    if (std.mem.eql(u8, value, "prepared")) return .prepared;
    if (std.mem.eql(u8, value, "handoff")) return .handoff;
    return error.InvalidPhase;
}

test "persistent phase names are stable" {
    try std.testing.expectEqual(Phase.pending, try parse("pending"));
    try std.testing.expectEqual(Phase.prepare_requested, try parse("prepare-requested"));
    try std.testing.expectEqual(Phase.prepared, try parse("prepared"));
    try std.testing.expectEqual(Phase.handoff, try parse("handoff"));
    try std.testing.expectError(error.InvalidPhase, parse("extracted"));
}
