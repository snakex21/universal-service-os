//! Interactive micro-Linux menus (XP disk choice, confirmations, Hardware &
//! SMART) in the shared boot UI style: page title, a card list of choices,
//! a details panel with scrollable lines or a table, and key hints.
const std = @import("std");
const usos = @import("usos");
const model = @import("fb_menu_model.zig");
const table_render = @import("fb_table_render.zig");
const fb_i18n = @import("fb_i18n.zig");
const Ui = usos.gui.ui.Ui;
const Rect = usos.gui.ui.Rect;

pub const Layout = struct {
    list: Ui.List,
    first: usize,
    info: Rect,
    info_y: u32,
    info_lines: usize,
    line_height: u32,
    table_y: u32 = 0,

    pub fn init(ui: *const Ui, state: model.State) Layout {
        const body = ui.bodyRect(state.subtitle.len > 0);
        const row_h = ui.rowHeight(true);
        const has_details = state.detailCount() > 0;
        const reserve: u32 = if (has_details) @max(body.h * 2 / 5, @min(body.h / 2, ui.px(200))) else 0;
        const list_max = body.h -| reserve -| (if (has_details) ui.px(14) else 0);
        const list_rect = Rect{ .x = body.x, .y = body.y, .w = body.w, .h = ui.listHeight(state.count, row_h, list_max) };
        const list = ui.listLayout(list_rect, row_h);
        const first = (state.selected / list.visible) * list.visible;
        const info = Rect{ .x = body.x, .y = list_rect.bottom() + ui.px(14), .w = body.w, .h = body.bottom() -| list_rect.bottom() -| ui.px(14) };
        const pad = ui.px(16);
        const line_height = ui.fonts.lineHeight(.body);
        const has_table = state.table.columns > 0;
        const info_y = info.y + pad;
        const table_y = info_y + @as(u32, @intCast(@min(state.info_count, 3))) * line_height + ui.px(6);
        const row_h_table = table_render.rowHeight(ui);
        const inner_bottom = info.bottom() -| pad;
        return .{
            .list = list,
            .first = first,
            .info = info,
            .info_y = info_y,
            .line_height = line_height,
            .info_lines = if (has_table) (inner_bottom -| table_y -| row_h_table) / row_h_table else (inner_bottom -| info_y) / line_height,
            .table_y = table_y,
        };
    }

    pub fn hit(self: Layout, x: i32, y: i32, count: usize) ?usize {
        if (x < 0 or y < 0) return null;
        const visible_count = @min(self.list.visible, count -| self.first);
        const index = self.list.hit(@intCast(x), @intCast(y), visible_count) orelse return null;
        return self.first + index;
    }
};

pub fn render(ui: *const Ui, state: model.State, mouse_x: i32, mouse_y: i32, mouse_visible: bool) void {
    const theme = ui.theme;
    const layout = Layout.init(ui, state);
    var clock_buffer: [48]u8 = undefined;
    ui.clear();
    ui.header(fb_i18n.header(ui, &clock_buffer));
    var title_buffer: [192]u8 = undefined;
    var subtitle_buffer: [256]u8 = undefined;
    ui.pageTitle(ui.tr(&title_buffer, state.title), ui.tr(&subtitle_buffer, state.subtitle));

    const hover = if (mouse_visible) layout.hit(mouse_x, mouse_y, state.count) else null;
    ui.listPanel(layout.list);
    const end = @min(state.count, layout.first + layout.list.visible);
    for (state.items[layout.first..end], layout.first..) |item, index| {
        var item_title: [192]u8 = undefined;
        var item_detail: [256]u8 = undefined;
        const row = usos.gui.ui.Row{
            .title = ui.tr(&item_title, item.title),
            .detail = ui.tr(&item_detail, item.detail),
            .icon = .{ .vector = iconFor(item.title) },
        };
        ui.row(layout.list.rowRect(index - layout.first), row, usos.gui.menu_screens.stateOf(index, state.selected, hover));
    }
    ui.scrollbar(layout.list, layout.first, state.count);

    if (state.detailCount() > 0 and layout.info.h > ui.px(40)) {
        const info = layout.info;
        usos.gui.paint.card(ui.surface, info.x, info.y, info.w, info.h, ui.px(10), ui.line(1), theme.border, theme.panel, theme.background);
        const pad = ui.px(16);
        const has_table = state.table.columns > 0;
        const info_first = if (has_table) 0 else state.scroll;
        const info_end = if (has_table) @min(state.info_count, 3) else @min(state.info_count, state.scroll + layout.info_lines);
        if (info_first < info_end) for (state.info[info_first..info_end], 0..) |line, i| {
            var line_buffer: [256]u8 = undefined;
            _ = ui.fonts.drawFit(ui.surface, info.x + pad, layout.info_y + @as(u32, @intCast(i)) * layout.line_height, info.w -| (2 * pad), .body, ui.tr(&line_buffer, line), theme.text, theme.panel);
        };
        if (has_table) table_render.render(ui, state.table, info.x + pad, layout.table_y, info.w -| (2 * pad), state.scroll, layout.info_lines);
    }

    var note_buffer: [96]u8 = undefined;
    var note: []const u8 = "";
    if (state.detailCount() > layout.info_lines) {
        var english: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&english, "Details {d}-{d} of {d}", .{ state.scroll + 1, @min(state.detailCount(), state.scroll + layout.info_lines), state.detailCount() }) catch "";
        note = ui.tr(&note_buffer, text);
    }
    const hints = [_]usos.gui.ui.Hint{
        .{ .key = "\u{2191}\u{2193}", .label = ui.t(.key_select) },
        .{ .key = "Enter", .label = ui.t(.key_open) },
        .{ .key = "Esc", .label = ui.t(.key_back) },
        .{ .key = "PgUp/PgDn", .label = ui.t(.key_scroll) },
    };
    ui.footer(if (state.detailCount() > layout.info_lines) hints[0..4] else hints[0..3], note);

    if (mouse_visible and mouse_x >= 0 and mouse_y >= 0) {
        var sprite = usos.gui.cursor.Sprite{};
        sprite.build(ui.fonts.scale.twice());
        var patch = usos.gui.cursor.Patch{};
        patch.save(ui.surface, @intCast(mouse_x), @intCast(mouse_y), sprite.width, sprite.height);
        sprite.draw(ui.surface, @intCast(mouse_x), @intCast(mouse_y), &patch.pixels);
    }
}

fn iconFor(title: []const u8) usos.gui.icons.Kind {
    const lower_contains = struct {
        fn f(haystack: []const u8, needle: []const u8) bool {
            return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
        }
    }.f;
    if (lower_contains(title, "Return to USOS") or lower_contains(title, "Back") or lower_contains(title, "Cancel")) return .chevron_left;
    if (lower_contains(title, "Confirm")) return .check;
    if (lower_contains(title, "Format") or lower_contains(title, "Erase")) return .warning;
    if (lower_contains(title, "Refresh")) return .restart;
    if (lower_contains(title, "SMART") or lower_contains(title, "report")) return .chip;
    if (lower_contains(title, "System information")) return .info;
    return .drive;
}

test "menu hit testing rejects gaps and supports paged disks" {
    const pixels = try std.testing.allocator.alloc(u32, 1024 * 768);
    defer std.testing.allocator.free(pixels);
    const buffer = usos.gui.ScreenBuffer.init(@intFromPtr(pixels.ptr), pixels.len * 4, 1024, 768, .bgrx8).?;
    const context = try std.testing.allocator.create(fb_i18n.Context);
    defer std.testing.allocator.destroy(context);
    context.* = .{};
    context.load();
    const ui = context.ui(buffer.surface);
    const state = try model.parse("title=Disks\nitem=A\nitem=B\nitem=C\nselected=1\ninfo=Disk identity");
    const layout = Layout.init(&ui, state);
    const row1 = layout.list.rowRect(1);
    try std.testing.expectEqual(@as(?usize, 1), layout.hit(@intCast(row1.x + 4), @intCast(row1.y + 4), state.count));
    try std.testing.expectEqual(@as(?usize, null), layout.hit(@intCast(row1.x + 4), @intCast(row1.bottom() + 1), state.count));
    try std.testing.expectEqual(@as(?usize, null), layout.hit(-1, 10, state.count));
}

test "confirmation choices and scrollable detail fit 640 by 480" {
    const pixels = try std.testing.allocator.alloc(u32, 640 * 480);
    defer std.testing.allocator.free(pixels);
    const buffer = usos.gui.ScreenBuffer.init(@intFromPtr(pixels.ptr), pixels.len * 4, 640, 480, .bgrx8).?;
    const context = try std.testing.allocator.create(fb_i18n.Context);
    defer std.testing.allocator.destroy(context);
    context.* = .{};
    context.load();
    const ui = context.ui(buffer.surface);
    const state = try model.parse("title=Confirm\nitem=Confirm\nitem=Cancel\nselected=1\ninfo=Disk identity");
    const layout = Layout.init(&ui, state);
    try std.testing.expect(layout.list.rowRect(1).bottom() < 480 - ui.footerHeight());
    try std.testing.expect(layout.info_lines > 0);
    render(&ui, state, 639, 479, true);
    const selected_pixel = buffer.surface.getRawPixel(layout.list.rowRect(1).x + ui.px(20), layout.list.rowRect(1).y + ui.px(6));
    const unselected_pixel = buffer.surface.getRawPixel(layout.list.rowRect(0).x + ui.px(20), layout.list.rowRect(0).y + ui.px(6));
    try std.testing.expect(selected_pixel != unselected_pixel);
}

test "SMART table remains inside a small framebuffer and scrolls rows under a fixed header" {
    const pixels = try std.testing.allocator.alloc(u32, 800 * 600);
    defer std.testing.allocator.free(pixels);
    const buffer = usos.gui.ScreenBuffer.init(@intFromPtr(pixels.ptr), pixels.len * 4, 800, 600, .bgrx8).?;
    const context = try std.testing.allocator.create(fb_i18n.Context);
    defer std.testing.allocator.destroy(context);
    context.* = .{};
    context.load();
    const ui = context.ui(buffer.surface);
    var state = try model.parse("title=SMART\nitem=Refresh\nitem=Report\nitem=Back\nselected=2\ninfo=Serial number: sample\ninfo=Manufacturer-specific values\ntable_header=ID|Attribute|Value|Worst|Limit|RAW value|State");
    for (0..40) |_| try state.table.append("normal|5|Reallocated Sector Ct|100|100|010|0|-");
    const layout = Layout.init(&ui, state);
    try std.testing.expect(layout.info_lines >= 1);
    try std.testing.expect(layout.table_y + @as(u32, @intCast(layout.info_lines + 1)) * table_render.rowHeight(&ui) <= layout.info.bottom());
    for (0..100) |_| state.scrollInfo(true, layout.info_lines);
    try std.testing.expectEqual(state.table.count - layout.info_lines, state.scroll);
    render(&ui, state, 0, 0, false);
}
