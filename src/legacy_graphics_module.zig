//! Graphics module of the Legacy BIOS Core (and a quick host test root for
//! the shared boot UI toolkit: `zig test src/legacy_graphics_module.zig`).
pub const Framebuffer = @import("gui/framebuffer.zig").Framebuffer;
pub const PixelFormat = @import("gui/framebuffer.zig").PixelFormat;
pub const Surface = @import("gui/surface.zig").Surface;
pub const Color = @import("gui/color.zig").Color;
pub const Theme = @import("gui/theme.zig").Theme;
pub const text = @import("gui/text.zig");
pub const font = @import("gui/font.zig");
pub const paint = @import("gui/paint.zig");
pub const icons = @import("gui/icons.zig");
pub const cursor = @import("gui/cursor.zig");
pub const scale = @import("gui/scale.zig");
pub const ui = @import("gui/ui.zig");
pub const ui_screens = @import("gui/menu_screens.zig");
pub const preparation_screen = @import("gui/preparation_screen.zig");
pub const rgba_rle = @import("gui/rgba_rle.zig");
pub const lang_file = @import("i18n/lang_file.zig");

test {
    _ = text;
    _ = font;
    _ = paint;
    _ = icons;
    _ = cursor;
    _ = scale;
    _ = ui;
    _ = lang_file;
    _ = @import("gui/theme.zig");
    _ = @import("gui/surface.zig");
    _ = @import("gui/preparation_screen.zig");
    _ = @import("gui/menu_screens.zig");
}
