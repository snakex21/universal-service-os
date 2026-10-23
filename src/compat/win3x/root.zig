//! Windows 3.x compatibility patches applied while USOS stages Setup files.
pub const lz = @import("lz.zig");
pub const display_patch = @import("display_patch.zig");
pub const display_table = @import("display_table.zig");
pub const display_run = @import("display_run.zig");

test {
    _ = lz;
    _ = display_patch;
    _ = display_table;
    _ = display_run;
}
