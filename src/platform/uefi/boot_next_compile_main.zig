const std = @import("std");
const boot_next = @import("boot_next.zig");

pub fn main() std.os.uefi.Status {
    _ = boot_next.prepareReturnToCurrentBoot() catch return .load_error;
    return .success;
}
