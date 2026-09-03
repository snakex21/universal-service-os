const std = @import("std");

pub const State = enum {
    pending,
    verified,
    extracted,
    prepared,
    handoff,
};

pub const Event = enum {
    image_verified,
    installer_extracted,
    boot_files_prepared,
    handoff_requested,
    start_image_failed,
    start_image_succeeded,
};

pub const TransitionError = error{
    InvalidTransition,
};

pub fn transition(state: State, event: Event) TransitionError!State {
    return switch (state) {
        .pending => if (event == .image_verified) .verified else error.InvalidTransition,
        .verified => if (event == .installer_extracted) .extracted else error.InvalidTransition,
        .extracted => if (event == .boot_files_prepared) .prepared else error.InvalidTransition,
        .prepared => if (event == .handoff_requested) .handoff else error.InvalidTransition,
        .handoff => switch (event) {
            .start_image_failed => .prepared,
            .start_image_succeeded => .pending,
            else => error.InvalidTransition,
        },
    };
}

pub fn canTransition(state: State, event: Event) bool {
    _ = transition(state, event) catch return false;
    return true;
}

test "Windows preparation flow reaches handoff only in order" {
    var state: State = .pending;
    state = try transition(state, .image_verified);
    try std.testing.expectEqual(State.verified, state);
    state = try transition(state, .installer_extracted);
    try std.testing.expectEqual(State.extracted, state);
    state = try transition(state, .boot_files_prepared);
    try std.testing.expectEqual(State.prepared, state);
    state = try transition(state, .handoff_requested);
    try std.testing.expectEqual(State.handoff, state);
}

test "prepared transitions to handoff only on explicit handoff request" {
    try std.testing.expect(canTransition(.prepared, .handoff_requested));
    try std.testing.expect(!canTransition(.prepared, .image_verified));
    try std.testing.expect(!canTransition(.prepared, .installer_extracted));
    try std.testing.expect(!canTransition(.prepared, .boot_files_prepared));
}

test "flow cannot skip preparation stages" {
    try std.testing.expectError(error.InvalidTransition, transition(.pending, .handoff_requested));
    try std.testing.expectError(error.InvalidTransition, transition(.verified, .boot_files_prepared));
    try std.testing.expectError(error.InvalidTransition, transition(.extracted, .handoff_requested));
}

test "failed StartImage returns handoff to prepared for retry" {
    const state = try transition(.handoff, .start_image_failed);
    try std.testing.expectEqual(State.prepared, state);
    try std.testing.expect(canTransition(state, .handoff_requested));
}

test "successful StartImage consumes handoff and resets flow to pending" {
    const state = try transition(.handoff, .start_image_succeeded);
    try std.testing.expectEqual(State.pending, state);
    try std.testing.expect(canTransition(state, .image_verified));
}

test "handoff accepts only StartImage result events" {
    try std.testing.expectError(error.InvalidTransition, transition(.handoff, .image_verified));
    try std.testing.expectError(error.InvalidTransition, transition(.handoff, .installer_extracted));
    try std.testing.expectError(error.InvalidTransition, transition(.handoff, .boot_files_prepared));
    try std.testing.expectError(error.InvalidTransition, transition(.handoff, .handoff_requested));
}
