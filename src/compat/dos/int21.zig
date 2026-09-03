const KernelState = @import("kernel_state.zig").KernelState;
const Registers = @import("registers.zig").Registers;

pub const Outcome = union(enum) {
    continue_execution,
    terminate: u8,
};

pub fn dispatch(state: *KernelState, registers: *Registers) Outcome {
    registers.setCarry(false);

    return switch (registers.ah()) {
        0x0E => selectDefaultDrive(state, registers),
        0x19 => getDefaultDrive(state, registers),
        0x30 => getDosVersion(state, registers),
        0x4C => .{ .terminate = registers.al() },
        0x50 => setCurrentPsp(state, registers),
        0x51, 0x62 => getCurrentPsp(state, registers),
        else => invalidFunction(registers),
    };
}

fn selectDefaultDrive(state: *KernelState, registers: *Registers) Outcome {
    const requested: u8 = @truncate(registers.dx);
    if (requested < state.logical_drive_count) state.current_drive = requested;
    registers.setAl(state.logical_drive_count);
    return .continue_execution;
}

fn getDefaultDrive(state: *const KernelState, registers: *Registers) Outcome {
    registers.setAl(state.current_drive);
    return .continue_execution;
}

fn getDosVersion(state: *const KernelState, registers: *Registers) Outcome {
    registers.setAl(state.version_major);
    registers.setAh(state.version_minor);
    registers.bx = 0;
    registers.cx = 0;
    return .continue_execution;
}

fn setCurrentPsp(state: *KernelState, registers: *const Registers) Outcome {
    state.current_psp = registers.bx;
    return .continue_execution;
}

fn getCurrentPsp(state: *const KernelState, registers: *Registers) Outcome {
    registers.bx = state.current_psp;
    return .continue_execution;
}

fn invalidFunction(registers: *Registers) Outcome {
    registers.ax = 1;
    registers.setCarry(true);
    return .continue_execution;
}

test "INT 21h reports DOS version and current PSP" {
    const std = @import("std");
    var state = KernelState{ .current_psp = 0x1234 };
    var registers = Registers{ .ax = 0x3000 };
    _ = dispatch(&state, &registers);
    try std.testing.expectEqual(@as(u8, 4), registers.al());
    try std.testing.expectEqual(@as(u8, 0), registers.ah());

    registers.ax = 0x6200;
    _ = dispatch(&state, &registers);
    try std.testing.expectEqual(@as(u16, 0x1234), registers.bx);
}

test "INT 21h drive selection and termination follow DOS conventions" {
    const std = @import("std");
    var state = KernelState{ .current_psp = 0x1000, .logical_drive_count = 4 };
    var registers = Registers{ .ax = 0x0E00, .dx = 1 };
    _ = dispatch(&state, &registers);
    try std.testing.expectEqual(@as(u8, 1), state.current_drive);
    try std.testing.expectEqual(@as(u8, 4), registers.al());

    registers.ax = 0x4C2A;
    const outcome = dispatch(&state, &registers);
    try std.testing.expect(outcome == .terminate);
    try std.testing.expectEqual(@as(u8, 0x2A), outcome.terminate);
}

test "unsupported INT 21h function returns invalid function error" {
    const std = @import("std");
    var state = KernelState{ .current_psp = 0x1000 };
    var registers = Registers{ .ax = 0xFF00 };
    _ = dispatch(&state, &registers);
    try std.testing.expectEqual(@as(u16, 1), registers.ax);
    try std.testing.expect((registers.flags & 1) != 0);
}
