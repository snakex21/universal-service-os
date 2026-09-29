const usos = @import("usos");
const std = @import("std");
const model = @import("fb_ui_state.zig");
const fb_i18n = @import("fb_i18n.zig");

pub fn fillBackground(surface: usos.gui.Surface, theme: usos.gui.Theme) void {
    surface.fill(theme.background);
}

pub fn render(surface: usos.gui.Surface, context: *const fb_i18n.Context, state: model.State) void {
    const ui = context.ui(surface);
    if (state.mode == .splash) {
        const splash = usos.gui.splash_screen;
        const layout = splash.usosLayout(&ui);
        splash.draw(&ui, layout, ui.t(.splash_starting));
        splash.spinner(&ui, layout, 0);
        return;
    }
    var clock_buffer: [48]u8 = undefined;
    const header = fb_i18n.header(&ui, &clock_buffer);
    if (state.mode == .notice or state.mode == .service) {
        var title_buffer: [192]u8 = undefined;
        var detail_buffer: [256]u8 = undefined;
        var image_buffer: [256]u8 = undefined;
        const detail = ui.tr(&detail_buffer, state.detail);
        const image = ui.tr(&image_buffer, state.image);
        const lines = [_][]const u8{ if (state.mode == .service) image else detail, if (state.mode == .service) ui.strings.lookup("Reading hardware information") else ui.strings.lookup("Choose a disk and confirm the installation before any changes.") };
        var step_buffer: [48]u8 = undefined;
        var current_text: [4]u8 = undefined;
        var total_text: [4]u8 = undefined;
        const step = if (state.mode == .service and state.total > 1)
            ui.format(&step_buffer, .prep_step, &.{ std.fmt.bufPrint(&current_text, "{d}", .{state.current}) catch "", std.fmt.bufPrint(&total_text, "{d}", .{state.total}) catch "" })
        else
            "";
        usos.gui.menu_screens.notice(&ui, header, .{
            .title = ui.tr(&title_buffer, state.title),
            .subtitle = step,
            .icon = if (state.mode == .service) .chip else .drive,
            .heading = if (state.mode == .service) detail else ui.strings.lookup("Detecting disks"),
            .lines = &lines,
        });
        return;
    }
    usos.gui.preparation_screen.render(&ui, .{
        .mode = switch (state.mode) {
            .stage => .stage,
            .progress => .progress,
            .done => .done,
            .failure => .failure,
            .diagnostic => .diagnostic,
            .notice, .service, .splash => unreachable,
        },
        .current = state.current,
        .total = state.total,
        .heading = state.heading,
        .title = state.title,
        .detail = state.detail,
        .image = state.image,
        .percent = state.percent,
        .bytes_done = state.bytes_done,
        .bytes_total = state.bytes_total,
        .speed_bps = state.speed_bps,
        .diagnostics = state.diagnostics[0..state.diagnostic_count],
        .diagnostics_truncated = state.diagnostics_truncated,
        .labels = if (state.label_count > 0) state.labels[0..state.label_count] else &usos.gui.preparation_screen.stage_labels,
        .notice = state.notice,
        .action = state.action,
    }, header);
}

test "every framebuffer UI mode renders" {
    const pixels = try std.testing.allocator.alloc(u32, 1024 * 768);
    defer std.testing.allocator.free(pixels);
    const buffer = usos.gui.ScreenBuffer.init(@intFromPtr(pixels.ptr), pixels.len * 4, 1024, 768, .bgrx8).?;
    const context = try std.testing.allocator.create(fb_i18n.Context);
    defer std.testing.allocator.destroy(context);
    context.* = .{};
    context.load();
    for ([_][]const u8{ "stage", "progress", "done", "failure", "diagnostic", "notice", "service", "splash" }) |mode| {
        var text: [96]u8 = undefined;
        const state = try model.parse(try std.fmt.bufPrint(&text, "mode={s}\ntitle=Copying files\ncurrent=2\ndiag=line", .{mode}));
        render(buffer.surface, context, state);
        try std.testing.expect(std.mem.indexOfNone(u32, pixels, pixels[0..1]) != null);
    }
}

test "framebuffer UI screens use the theme from the kernel command line" {
    const pixels = try std.testing.allocator.alloc(u32, 1024 * 768);
    defer std.testing.allocator.free(pixels);
    const buffer = usos.gui.ScreenBuffer.init(@intFromPtr(pixels.ptr), pixels.len * 4, 1024, 768, .bgrx8).?;
    const context = try std.testing.allocator.create(fb_i18n.Context);
    defer std.testing.allocator.destroy(context);
    context.* = .{};
    context.load();
    const retro = usos.gui.theme_presets.find("retro").?;
    var option: [usos.gui.theme_cmdline.option_len]u8 = undefined;
    context.theme = usos.gui.theme_cmdline.fromCmdline(usos.gui.theme_cmdline.option(&option, retro));
    for ([_][]const u8{ "progress", "notice" }) |mode| {
        var text: [64]u8 = undefined;
        render(buffer.surface, context, try model.parse(try std.fmt.bufPrint(&text, "mode={s}\ntitle=Copying files", .{mode})));
        // Most of the screen is retro background, none is the default one.
        const background = buffer.surface.packColor(retro.background);
        const default_background = buffer.surface.packColor((usos.gui.Theme{}).background);
        try std.testing.expect(std.mem.count(u32, pixels, &.{background}) > pixels.len / 4);
        try std.testing.expectEqual(@as(usize, 0), std.mem.count(u32, pixels, &.{default_background}));
    }
    fillBackground(buffer.surface, retro);
    try std.testing.expectEqual(buffer.surface.packColor(retro.background), pixels[0]);
}
