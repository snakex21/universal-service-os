const usos = @import("usos");
const std = @import("std");
const model = @import("fb_ui_state.zig");

pub fn fillBackground(surface: usos.gui.Surface) void {
    surface.fill((usos.gui.Theme{}).background);
}

pub fn render(surface: usos.gui.Surface, state: model.State) void {
    var clock_buffer: [26]u8 = undefined;
    const clock = clockText(&clock_buffer);
    if (state.mode == .notice or state.mode == .service) {
        const canvas = usos.gui.menu_canvas.Canvas.init(surface, usos.gui.Theme{});
        var stage: [32]u8 = undefined;
        const step = if (state.total > 1) std.fmt.bufPrint(&stage, "Step {d} of {d}", .{ state.current, state.total }) catch "" else "";
        canvas.beginList(state.title, if (state.mode == .service) step else "", "USOS", clock);
        canvas.listRow(0, .{ .value = if (state.mode == .service) state.detail else "Detecting disks", .selected = true });
        canvas.listHelp(if (state.mode == .service) state.image else state.detail);
        canvas.footer(if (state.mode == .service) "Reading hardware information" else "Choose a disk and confirm the installation before any changes.");
        return;
    }
    usos.gui.preparation_screen.render(surface, usos.gui.Theme{}, .{
        .mode = switch (state.mode) {
            .stage => .stage,
            .progress => .progress,
            .done => .done,
            .failure => .failure,
            .diagnostic => .diagnostic,
            .notice, .service => unreachable,
        },
        .current = state.current,
        .total = state.total,
        .title = state.title,
        .detail = state.detail,
        .image = state.image,
        .percent = state.percent,
        .bytes_done = state.bytes_done,
        .bytes_total = state.bytes_total,
        .speed_bps = state.speed_bps,
        .diagnostics = state.diagnostics[0..state.diagnostic_count],
        .diagnostics_truncated = state.diagnostics_truncated,
    });
    if (state.mode != .diagnostic) {
        const width = @min(@as(u32, 1040), surface.framebuffer.width -| 64);
        const right = (surface.framebuffer.width -| width) / 2 + width;
        usos.gui.text.draw(surface, right -| usos.gui.text.width(clock, 1), 58, clock, 1, (usos.gui.Theme{}).muted);
    }
}

fn clockText(buffer: []u8) []const u8 {
    if (@import("builtin").os.tag != .linux) return "";
    var now: std.os.linux.timespec = undefined;
    if (std.os.linux.clock_gettime(.REALTIME, &now) != 0 or now.sec < 0) return "";
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(now.sec) };
    const year = epoch.getEpochDay().calculateYearDay();
    const date = year.calculateMonthDay();
    const time = epoch.getDaySeconds();
    return std.fmt.bufPrint(buffer, "{s} {d:0>2}.{d:0>2}.{d:0>4} {d:0>2}:{d:0>2}", .{ usos.calendar.weekdayName(year.year, @intFromEnum(date.month), date.day_index + 1), date.day_index + 1, @intFromEnum(date.month), year.year, time.getHoursIntoDay(), time.getMinutesIntoHour() }) catch "";
}
