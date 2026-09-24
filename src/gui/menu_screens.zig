//! The boot menu screens, drawn with the ui.zig toolkit and shared by the
//! UEFI menu and the Legacy BIOS Core so both firmware paths look the same:
//! the category home, list screens (systems, images, methods, power...),
//! the boot summary and notices. Platform code owns input and state; these
//! functions only draw and report geometry for mouse hit testing.
const std = @import("std");
const ui_mod = @import("ui.zig");
const icons = @import("icons.zig");
const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;

pub const Row = ui_mod.Row;
pub const RowState = ui_mod.RowState;
pub const Hint = ui_mod.Hint;
pub const Badge = ui_mod.Badge;
pub const HeaderInfo = ui_mod.HeaderInfo;
pub const Icon = icons.Kind;

pub const HomeItem = struct {
    icon: Icon,
    title: []const u8,
    description: []const u8,
};

pub fn home(ui: *const Ui, header: HeaderInfo, items: []const HomeItem, selected: usize, hover: ?usize, hints: []const Hint) void {
    ui.clear();
    ui.header(header);
    ui.pageTitle(ui.t(.menu_title), ui.t(.menu_subtitle));
    for (0..items.len) |index| homeItem(ui, items, index, stateOf(index, selected, hover));
    ui.footer(hints, "");
}

pub fn homeItem(ui: *const Ui, items: []const HomeItem, index: usize, state: RowState) void {
    if (index >= items.len) return;
    const item = items[index];
    ui.homeCard(ui.homeCardRect(index, items.len), item.icon, item.title, item.description, state);
}

/// The optional offer banner under the home cards (e.g. "save the Secure
/// Boot key"): as wide as the card grid, below its last row. Null when the
/// screen has no room for it.
pub fn homeBannerRect(ui: *const Ui, count: usize) ?Rect {
    if (count == 0) return null;
    const last = ui.homeCardRect(count - 1, count);
    const first = ui.homeCardRect(0, count);
    const body = ui.bodyRect(true);
    const y = last.bottom() + ui.px(16);
    const h = ui.px(56);
    if (y + h > body.bottom()) return null;
    return .{ .x = first.x, .y = y, .w = body.w, .h = h };
}

pub fn homeBanner(ui: *const Ui, count: usize, message: []const u8, action: []const u8, state: RowState) void {
    const rect = homeBannerRect(ui, count) orelse return;
    ui.offerBanner(rect, message, action, state);
}

pub fn homeHit(ui: *const Ui, count: usize, x: u32, y: u32) ?usize {
    for (0..count) |index| {
        if (ui.homeCardRect(index, count).contains(x, y)) return index;
    }
    return null;
}

pub fn stateOf(index: usize, selected: usize, hover: ?usize) RowState {
    if (index == selected) return .selected;
    if (hover) |value| {
        if (value == index) return .hover;
    }
    return .normal;
}

pub const Help = struct {
    title: []const u8,
    lines: []const []const u8,
    badge: ?Badge = null,
};

pub const ListSpec = struct {
    title: []const u8,
    subtitle: []const u8 = "",
    rows: []const Row,
    selected: usize = 0,
    hover: ?usize = null,
    two_line: bool = true,
    /// Explanation for the selected row, shown beside (wide screens) or
    /// below the list.
    help: ?Help = null,
    hints: []const Hint = &.{},
    note: []const u8 = "",
};

pub const ListGeometry = struct {
    list: Ui.List,
    first: usize,
    help: ?Rect,
};

/// Index of the first visible row that keeps `selected` in view.
pub fn firstVisible(selected: usize, count: usize, visible: usize, current_first: usize) usize {
    if (count == 0 or visible == 0 or count <= visible) return 0;
    var first = current_first;
    if (selected < first) first = selected;
    if (selected >= first + visible) first = selected + 1 - visible;
    return @min(first, count - visible);
}

pub fn listGeometry(ui: *const Ui, spec: ListSpec, current_first: usize) ListGeometry {
    const body = ui.bodyRect(spec.subtitle.len > 0);
    const row_h = ui.rowHeight(spec.two_line);
    var list_area = body;
    var help: ?Rect = null;
    if (spec.help != null) {
        if (body.w >= ui.px(860)) {
            const help_w = @min(body.w * 2 / 5, ui.px(420));
            list_area.w = body.w -| help_w -| ui.px(16);
            const content = spec.help.?;
            help = .{ .x = list_area.right() + ui.px(16), .y = body.y, .w = help_w, .h = @min(body.h, ui.infoPanelHeight(help_w, true, content.title, content.lines)) };
        } else {
            const content = spec.help.?;
            const help_h = @min(ui.infoPanelHeight(body.w, true, content.title, content.lines), body.h / 3);
            list_area.h = body.h -| help_h -| ui.px(14);
            help = .{ .x = body.x, .y = list_area.bottom() + ui.px(14), .w = body.w, .h = help_h };
        }
    }
    list_area.h = ui.listHeight(spec.rows.len, row_h, list_area.h);
    if (help) |*rect| {
        if (rect.y > list_area.bottom() + ui.px(14) and rect.x == list_area.x) rect.y = list_area.bottom() + ui.px(14);
    }
    const list = ui.listLayout(list_area, row_h);
    return .{ .list = list, .first = firstVisible(spec.selected, spec.rows.len, list.visible, current_first), .help = help };
}

/// Draws a complete list screen and returns its geometry.
pub fn listScreen(ui: *const Ui, header: HeaderInfo, spec: ListSpec, current_first: usize) ListGeometry {
    ui.clear();
    ui.header(header);
    ui.pageTitle(spec.title, spec.subtitle);
    const geometry = listGeometry(ui, spec, current_first);
    ui.listPanel(geometry.list);
    drawRows(ui, geometry, spec);
    if (geometry.help) |rect| drawHelp(ui, rect, spec.help.?);
    ui.footer(spec.hints, spec.note);
    return geometry;
}

pub fn drawRows(ui: *const Ui, geometry: ListGeometry, spec: ListSpec) void {
    const end = @min(spec.rows.len, geometry.first + geometry.list.visible);
    var visible_index: usize = 0;
    while (visible_index < geometry.list.visible) : (visible_index += 1) {
        const index = geometry.first + visible_index;
        if (index >= end) {
            ui.clearRow(geometry.list, visible_index);
            continue;
        }
        ui.row(geometry.list.rowRect(visible_index), spec.rows[index], stateOf(index, spec.selected, spec.hover));
    }
    ui.scrollbar(geometry.list, geometry.first, spec.rows.len);
}

/// Redraws one row (selection or hover changed without scrolling).
pub fn drawRow(ui: *const Ui, geometry: ListGeometry, spec: ListSpec, index: usize) void {
    if (index < geometry.first or index >= geometry.first + geometry.list.visible or index >= spec.rows.len) return;
    ui.row(geometry.list.rowRect(index - geometry.first), spec.rows[index], stateOf(index, spec.selected, spec.hover));
}

pub fn drawHelp(ui: *const Ui, rect: Rect, help: Help) void {
    ui.surface.fillRect(rect.x, rect.y, rect.w, rect.h, ui.theme.background);
    _ = ui.infoPanel(rect, .info, .neutral, help.title, help.lines, help.badge);
}

pub fn listHit(geometry: ListGeometry, count: usize, x: u32, y: u32) ?usize {
    const visible_count = @min(geometry.list.visible, count -| geometry.first);
    const visible_index = geometry.list.hit(x, y, visible_count) orelse return null;
    return geometry.first + visible_index;
}

pub const SummarySpec = struct {
    title: []const u8,
    subtitle: []const u8 = "",
    labels: []const []const u8,
    values: []const []const u8,
    /// Extra warning lines under the table (e.g. why start is blocked).
    notes: []const []const u8 = &.{},
    action: []const u8,
    action_enabled: bool = true,
    action_hover: bool = false,
    hints: []const Hint = &.{},
};

/// Draws the boot summary and returns the start button rectangle.
pub fn summary(ui: *const Ui, header: HeaderInfo, spec: SummarySpec) Rect {
    ui.clear();
    ui.header(header);
    ui.pageTitle(spec.title, spec.subtitle);
    const body = ui.bodyRect(spec.subtitle.len > 0);
    const table_h = @min(ui.keyValuesHeight(body.w, spec.labels, spec.values), body.h -| ui.px(120));
    _ = ui.keyValues(.{ .x = body.x, .y = body.y, .w = body.w, .h = table_h }, spec.labels, spec.values);
    var y = body.y + table_h + ui.px(16);
    for (spec.notes) |note| {
        if (note.len == 0) continue;
        ui.banner(.{ .x = body.x, .y = y, .w = body.w, .h = ui.px(44) }, .warning, .warning, note);
        y += ui.px(44) + ui.px(10);
    }
    const size = ui.buttonSize(if (spec.action_enabled) "Enter" else "", spec.action);
    const button = Rect{ .x = body.x, .y = y + ui.px(6), .w = @min(size.w, body.w), .h = size.h };
    summaryButton(ui, button, spec);
    if (spec.action_enabled) {
        _ = ui.fonts.drawFit(ui.surface, button.right() + ui.px(18), ui.fonts.centeredTop(.body, button.y + button.h / 2), body.right() -| button.right() -| ui.px(18), .body, ui.t(.action_hint), ui.theme.muted, ui.theme.background);
    }
    ui.footer(spec.hints, "");
    return button;
}

pub fn summaryButton(ui: *const Ui, rect: Rect, spec: SummarySpec) void {
    ui.button(rect, if (spec.action_enabled) "Enter" else "", spec.action, true, if (spec.action_hover) .hover else .normal, spec.action_enabled);
}

pub const NoticeSpec = struct {
    title: []const u8,
    subtitle: []const u8 = "",
    icon: Icon = .info,
    tone: ui_mod.Tone = .neutral,
    heading: []const u8 = "",
    lines: []const []const u8,
    hints: []const Hint = &.{},
};

pub fn notice(ui: *const Ui, header: HeaderInfo, spec: NoticeSpec) void {
    ui.clear();
    ui.header(header);
    ui.pageTitle(spec.title, spec.subtitle);
    const body = ui.bodyRect(spec.subtitle.len > 0);
    const w = @min(body.w, ui.px(900));
    const h = @min(body.h, ui.infoPanelHeight(w, true, spec.heading, spec.lines));
    _ = ui.infoPanel(.{ .x = body.x, .y = body.y, .w = w, .h = h }, spec.icon, spec.tone, spec.heading, spec.lines, null);
    ui.footer(spec.hints, "");
}

test "menu screens render in Polish at common resolutions" {
    const font = @import("font.zig");
    const lang_file = @import("../i18n/lang_file.zig");
    const ScreenBuffer = @import("screen_buffer.zig").ScreenBuffer;
    const Theme = @import("theme.zig").Theme;
    const pack = try font.Pack.parse(@embedFile("fonts/usos-font.bin"));
    const coverage = lang_file.Coverage{ .context = @ptrCast(&pack), .has = font.coverageHas };
    const table = try lang_file.Table.parse(@embedFile("../i18n/testdata/lang-pl.bin"), coverage);
    for ([_][2]u32{ .{ 800, 600 }, .{ 1280, 800 }, .{ 1920, 1080 } }) |size| {
        const pixels = try std.testing.allocator.alloc(u32, size[0] * size[1]);
        defer std.testing.allocator.free(pixels);
        const buffer = ScreenBuffer.init(@intFromPtr(pixels.ptr), pixels.len * 4, size[0], size[1], .bgrx8).?;
        const ui = Ui.init(buffer.surface, Theme{}, &pack, &table);
        const header = HeaderInfo{ .firmware = "UEFI", .language = "Polski", .build = "B260923-124620-62F8A603" };
        const items = [_]HomeItem{
            .{ .icon = .windows, .title = "Windows", .description = ui.t(.category_windows_desc) },
            .{ .icon = .terminal, .title = "Linux", .description = ui.t(.category_linux_desc) },
            .{ .icon = .power, .title = ui.t(.category_power), .description = ui.t(.category_power_desc) },
        };
        home(&ui, header, &items, 0, 2, &.{.{ .key = "Enter", .label = ui.t(.key_open) }});
        try std.testing.expectEqual(@as(?usize, 1), homeHit(&ui, items.len, ui.homeCardRect(1, items.len).x + 5, ui.homeCardRect(1, items.len).y + 5));
        var rows: [30]Row = undefined;
        for (&rows, 0..) |*row, index| row.* = .{ .title = "Windows 10", .detail = if (index % 2 == 0) "Obrazy: 2" else "", .icon = .{ .label = "ISO" } };
        const spec = ListSpec{ .title = "Windows", .rows = &rows, .selected = 20, .help = .{ .title = "Automatycznie", .lines = &.{"USOS wybiera metodę."} } };
        const geometry = listScreen(&ui, header, spec, 0);
        try std.testing.expect(geometry.first + geometry.list.visible > 20 and geometry.first <= 20);
        const hit_rect = geometry.list.rowRect(0);
        try std.testing.expectEqual(@as(?usize, geometry.first), listHit(geometry, rows.len, hit_rect.x + 2, hit_rect.y + 2));
        _ = summary(&ui, header, .{ .title = "Gotowe", .labels = &.{ "System", "Obraz" }, .values = &.{ "Windows 11", "win11.iso" }, .action = "Wczytaj ISO Windows" });
        notice(&ui, header, .{ .title = "Brak obrazów", .icon = .warning, .tone = .warning, .heading = "Nie znaleziono", .lines = &.{"Skopiuj plik do:"} });
    }
}
