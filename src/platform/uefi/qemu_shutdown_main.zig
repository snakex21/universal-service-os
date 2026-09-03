const std = @import("std");
const bootstrap = @import("bootstrap.zig");
const qemu_fixture = @import("qemu_fixture.zig");

pub fn main() noreturn {
    const bootstrap_status = bootstrap.run();
    const passed = bootstrap_status == .success and qemu_fixture.isDetected();
    const status: std.os.uefi.Status = if (passed) .success else .device_error;
    std.os.uefi.system_table.runtime_services.resetSystem(.shutdown, status, null);
}
