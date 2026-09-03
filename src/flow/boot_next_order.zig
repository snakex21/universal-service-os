const std = @import("std");

pub const State = enum {
    untouched,
    boot_order_backed_up,
    boot_next_set,
};

pub const Event = enum {
    backup_boot_order,
    set_boot_next,
};

pub const Error = error{InvalidTransition};

pub fn transition(state: State, event: Event) Error!State {
    return switch (state) {
        .untouched => if (event == .backup_boot_order) .boot_order_backed_up else error.InvalidTransition,
        .boot_order_backed_up => if (event == .set_boot_next) .boot_next_set else error.InvalidTransition,
        .boot_next_set => error.InvalidTransition,
    };
}

test "BootOrder backup is mandatory before BootNext" {
    try std.testing.expectError(error.InvalidTransition, transition(.untouched, .set_boot_next));
    var state = try transition(.untouched, .backup_boot_order);
    try std.testing.expectEqual(State.boot_order_backed_up, state);
    state = try transition(state, .set_boot_next);
    try std.testing.expectEqual(State.boot_next_set, state);
}
