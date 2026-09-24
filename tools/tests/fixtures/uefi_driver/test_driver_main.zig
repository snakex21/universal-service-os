//! Test EFI boot-service drivers for DATA\Drivers\UEFI (the menu's user
//! driver loader, src/platform/uefi/uefi_drivers.zig). Variants (build
//! option `variant`):
//!   ok       prints "[TEST_DRIVER] <label> entry" and stays resident;
//!   binding  also installs an EFI_DRIVER_BINDING_PROTOCOL whose Supported()
//!            refuses every controller (exercises the connect pass);
//!   hang     prints its entry line and never returns (the watchdog and the
//!            hang guard must block it on the next start).
//! Built for x64 and, as a wrong-architecture sample, for ia32.
const std = @import("std");
const uefi = std.os.uefi;
const options = @import("options");
const serial = @import("serial");

const DriverBinding = extern struct {
    supported: *const fn (*DriverBinding, uefi.Handle, ?*anyopaque) callconv(uefi.cc) uefi.Status,
    start: *const fn (*DriverBinding, uefi.Handle, ?*anyopaque) callconv(uefi.cc) uefi.Status,
    stop: *const fn (*DriverBinding, uefi.Handle, usize, ?[*]uefi.Handle) callconv(uefi.cc) uefi.Status,
    version: u32,
    image_handle: ?uefi.Handle,
    driver_binding_handle: ?uefi.Handle,

    const guid align(8) = uefi.Guid{
        .time_low = 0x18a031ab,
        .time_mid = 0xb443,
        .time_high_and_version = 0x4d1a,
        .clock_seq_high_and_reserved = 0xa5,
        .clock_seq_low = 0xc0,
        .node = .{ 0x0c, 0x09, 0x26, 0x1e, 0x9f, 0x71 },
    };
};

var supported_calls: usize = 0;

fn supported(_: *DriverBinding, _: uefi.Handle, _: ?*anyopaque) callconv(uefi.cc) uefi.Status {
    supported_calls += 1;
    return .unsupported;
}
fn startController(_: *DriverBinding, _: uefi.Handle, _: ?*anyopaque) callconv(uefi.cc) uefi.Status {
    return .unsupported;
}
fn stopController(_: *DriverBinding, _: uefi.Handle, _: usize, _: ?[*]uefi.Handle) callconv(uefi.cc) uefi.Status {
    return .success;
}

var binding = DriverBinding{
    .supported = supported,
    .start = startController,
    .stop = stopController,
    .version = 0x10,
    .image_handle = null,
    .driver_binding_handle = null,
};

pub fn main() uefi.Status {
    serial.init();
    serial.writeAscii("[TEST_DRIVER] " ++ options.label ++ " entry variant=" ++ options.variant ++ "\n");
    const bs = uefi.system_table.boot_services orelse return .load_error;
    if (comptime std.mem.eql(u8, options.variant, "hang")) {
        while (true) bs.stall(1_000_000) catch {};
    }
    if (comptime std.mem.eql(u8, options.variant, "binding")) {
        binding.image_handle = uefi.handle;
        binding.driver_binding_handle = uefi.handle;
        const Install = *const fn (*?uefi.Handle, *const uefi.Guid, uefi.tables.InterfaceType, *anyopaque) callconv(uefi.cc) uefi.Status;
        const install: Install = @ptrCast(bs._installProtocolInterface);
        var handle: ?uefi.Handle = uefi.handle;
        if (install(&handle, &DriverBinding.guid, .native, @ptrCast(&binding)) != .success) {
            serial.writeAscii("[TEST_DRIVER] " ++ options.label ++ " binding install FAILED\n");
            return .load_error;
        }
        serial.writeAscii("[TEST_DRIVER] " ++ options.label ++ " binding installed\n");
    }
    return .success;
}
