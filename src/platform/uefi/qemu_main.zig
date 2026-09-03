const std = @import("std");
const bootstrap = @import("bootstrap.zig");
const qemu_exit = @import("qemu_exit");
const qemu_fixture = @import("qemu_fixture.zig");

pub fn main() noreturn {
    const status = bootstrap.run();
    const passed = status == .success and qemu_fixture.isDetected();
    qemu_exit.exit(if (passed) .pass else .fail);
}
