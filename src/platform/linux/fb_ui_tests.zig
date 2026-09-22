const state = @import("fb_ui_state.zig");
const render = @import("fb_ui_render.zig");

test "framebuffer UI modules are reachable by host tests" {
    _ = state.State{};
    _ = render.render;
    _ = @import("fb_menu_model.zig");
    _ = @import("fb_menu_render.zig");
    _ = @import("fb_menu_input.zig");
}
