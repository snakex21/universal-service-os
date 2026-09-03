const std = @import("std");
const bootstrap = @import("bootstrap.zig");

pub fn main() std.os.uefi.Status {
    return bootstrap.run();
}
