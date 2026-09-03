const std = @import("std");
const manual_app = @import("manual_app.zig");
const serial = @import("serial.zig");

pub fn main() noreturn {
    serial.init();
    serial.writeAscii("USOS MANUAL FLOW BOOT PASS\n");
    manual_app.run();
    std.os.uefi.system_table.runtime_services.resetSystem(.shutdown, .success, null);
}
