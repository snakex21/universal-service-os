//! Windows 3.x compatibility patches applied while USOS stages Setup files.
pub const lz = @import("lz.zig");
pub const display_patch = @import("display_patch.zig");
pub const display_table = @import("display_table.zig");
pub const display_run = @import("display_run.zig");
pub const cab = @import("cab.zig");
pub const w9x_mini = @import("w9x_mini.zig");
pub const nt35_initial = @import("nt35_initial.zig");

test {
    _ = lz;
    _ = display_patch;
    _ = display_table;
    _ = display_run;
    _ = cab;
    _ = w9x_mini;
    _ = nt35_initial;
}
