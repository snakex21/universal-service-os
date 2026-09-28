//! Linux ISO boot from DATA (docs/design/linux-iso-boot.md).
pub const iso_map = @import("iso_map.zig");
pub const cpio = @import("cpio.zig");
pub const grub_cfg = @import("grub_cfg.zig");
pub const recipe = @import("recipe.zig");

test {
    _ = iso_map;
    _ = cpio;
    _ = grub_cfg;
    _ = recipe;
}
