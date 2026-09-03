const std = @import("std");

pub const State = enum {
    prepare_requested,
    guard_passed,
    formatted,
    identity_restored,
    mounted,
    extracted,
    verified,
    synced,
    prepared,
};

pub const Event = enum {
    guard_accepted,
    format_completed,
    marker_restored,
    work_mounted,
    copy_completed,
    completeness_verified,
    storage_synced,
    prepared_published,
};

pub const Error = error{InvalidTransition};

pub fn transition(state: State, event: Event) Error!State {
    return switch (state) {
        .prepare_requested => if (event == .guard_accepted) .guard_passed else error.InvalidTransition,
        .guard_passed => if (event == .format_completed) .formatted else error.InvalidTransition,
        .formatted => if (event == .marker_restored) .identity_restored else error.InvalidTransition,
        .identity_restored => if (event == .work_mounted) .mounted else error.InvalidTransition,
        .mounted => if (event == .copy_completed) .extracted else error.InvalidTransition,
        .extracted => if (event == .completeness_verified) .verified else error.InvalidTransition,
        .verified => if (event == .storage_synced) .synced else error.InvalidTransition,
        .synced => if (event == .prepared_published) .prepared else error.InvalidTransition,
        .prepared => error.InvalidTransition,
    };
}

test "preparation cannot publish prepared before guard verify and sync" {
    var state: State = .prepare_requested;
    try std.testing.expectError(error.InvalidTransition, transition(state, .format_completed));
    state = try transition(state, .guard_accepted);
    state = try transition(state, .format_completed);
    state = try transition(state, .marker_restored);
    state = try transition(state, .work_mounted);
    state = try transition(state, .copy_completed);
    try std.testing.expectError(error.InvalidTransition, transition(state, .prepared_published));
    state = try transition(state, .completeness_verified);
    try std.testing.expectError(error.InvalidTransition, transition(state, .prepared_published));
    state = try transition(state, .storage_synced);
    state = try transition(state, .prepared_published);
    try std.testing.expectEqual(State.prepared, state);
}
