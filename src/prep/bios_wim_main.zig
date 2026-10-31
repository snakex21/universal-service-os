//! WIM-only BIOS prep client. Keeps the existing low-memory Core ABI and slot;
//! old stage1a/scaling entry points are removed at compile time, not relocated.
pub const prep_wim_only = true;
comptime {
    _ = @import("bios_main.zig");
}
