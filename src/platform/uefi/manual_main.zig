const std = @import("std");
const manual_app = @import("manual_app.zig");
const serial = @import("serial.zig");
const boot_timing = @import("boot_timing.zig");

pub fn main() noreturn {
    boot_timing.mark("BOOTX64.EFI entry");
    serial.init();
    boot_timing.mark("serial console ready");
    // Firmware arms a five-minute watchdog before starting an EFI boot option.
    // An interactive menu and ISO reads must not retain that boot deadline.
    if (std.os.uefi.system_table.boot_services) |bs| {
        bs.setWatchdogTimer(0, 0, null) catch |err| {
            serial.writeAscii("UEFI watchdog disable failed: ");
            serial.writeAscii(@errorName(err));
            serial.writeAscii("\n");
        };
    }
    serial.writeAscii("USOS MANUAL FLOW BOOT PASS\n");
    manual_app.run();
    std.os.uefi.system_table.runtime_services.resetSystem(.shutdown, .success, null);
}
