const std = @import("std");
const Color = @import("color.zig").Color;
const Surface = @import("surface.zig").Surface;
const Theme = @import("theme.zig").Theme;
const text = @import("text.zig");

pub const Mode = enum {
    stage,
    progress,
    done,
    failure,
    diagnostic,
};

pub const State = struct {
    mode: Mode = .stage,
    current: u8 = 1,
    total: u8 = 5,
    title: []const u8 = "STARTING ENVIRONMENT",
    detail: []const u8 = "",
    image: []const u8 = "",
    percent: u8 = 0,
    bytes_done: u64 = 0,
    bytes_total: u64 = 0,
    speed_bps: u64 = 0,
    diagnostics: []const []const u8 = &.{},
    diagnostics_truncated: bool = false,
};

pub const stage_labels = [_][]const u8{
    "STARTING ENVIRONMENT",
    "VERIFYING TARGET DEVICE",
    "PREPARING WORKSPACE",
    "COPYING FILES",
    "VERIFICATION AND FINALIZATION",
};

const success = Color{ .r = 0x63, .g = 0xd3, .b = 0x91 };
const failure = Color{ .r = 0xff, .g = 0x70, .b = 0x70 };
const max_width: u32 = 1040;
const outer_margin: u32 = 32;
const stages_y: u32 = 150;
const stage_panel_height: u32 = 236;
const detail_y: u32 = 404;

pub fn render(surface: Surface, theme: Theme, state: State) void {
    surface.fill(theme.background);
    surface.fillRect(0, 0, surface.framebuffer.width, 5, theme.accent);

    if (state.mode == .diagnostic) {
        renderDiagnostic(surface, theme, state);
        return;
    }

    const width = @min(max_width, surface.framebuffer.width -| (outer_margin * 2));
    const x = (surface.framebuffer.width -| width) / 2;

    text.draw(surface, x, 28, "UNIVERSAL SERVICE OS", 3, theme.text);
    text.draw(surface, x, 78, "PREPARING WINDOWS INSTALLER", 1, theme.muted);
    surface.fillRect(x, 108, width, 1, theme.border);

    surface.fillRect(x, stages_y, width, stage_panel_height, theme.panel);
    surface.borderRect(x, stages_y, width, stage_panel_height, 1, theme.border);
    for (stage_labels, 0..) |_, index| {
        drawStage(surface, theme, state, x + 18, stages_y + 16 + @as(u32, @intCast(index)) * 42, width -| 36, index + 1);
    }

    const footer_y = surface.framebuffer.height -| 34;
    if (footer_y > detail_y + 54) {
        drawDetail(surface, theme, state, x, detail_y, width, footer_y -| detail_y -| 18);
    }
    drawClipped(surface, x, footer_y, width, footerText(state.mode), 1, theme.muted);
}

pub fn updateProgress(surface: Surface, theme: Theme, state: State) void {
    const width = @min(max_width, surface.framebuffer.width -| (outer_margin * 2));
    const x = (surface.framebuffer.width -| width) / 2;
    const footer_y = surface.framebuffer.height -| 34;
    if (footer_y <= detail_y + 54) return;
    drawDetail(surface, theme, state, x, detail_y, width, footer_y -| detail_y -| 18);
}

fn renderDiagnostic(surface: Surface, theme: Theme, state: State) void {
    const margin: u32 = 20;
    const width = surface.framebuffer.width -| (margin * 2);
    text.draw(surface, margin, 16, "UNIVERSAL SERVICE OS", 2, theme.text);
    const interactive = !std.mem.eql(u8, state.title, "STARTING ENVIRONMENT");
    text.draw(surface, margin, 40, if (interactive) state.title else "USB / PARTUUID DIAGNOSTICS - SCREEN IS FROZEN FOR PHOTO", 1, if (interactive) theme.accent else failure);
    surface.fillRect(margin, 56, width, 1, theme.border);

    const first_y: u32 = 66;
    const line_step: u32 = if (interactive) 14 else 7;
    const bottom_margin: u32 = 8;
    const available = surface.framebuffer.height -| first_y -| bottom_margin;
    const visible_lines: usize = @intCast(available / line_step);
    const count = @min(state.diagnostics.len, visible_lines);
    for (state.diagnostics[0..count], 0..) |line, index| {
        const y = first_y + @as(u32, @intCast(index)) * line_step;
        const color = if (std.mem.startsWith(u8, line, "==")) theme.accent else theme.text;
        drawClipped(surface, margin, y, width, line, 1, color);
    }
    if ((state.diagnostics.len > visible_lines or state.diagnostics_truncated) and visible_lines > 0) {
        const y = first_y + @as(u32, @intCast(visible_lines - 1)) * line_step;
        surface.fillRect(margin, y, width, line_step, theme.background);
        drawClipped(surface, margin, y, width, "[DIAGNOSTICS TRUNCATED - SEE SERIAL OUTPUT]", 1, failure);
    }
}

fn drawStage(surface: Surface, theme: Theme, state: State, x: u32, y: u32, width: u32, number: usize) void {
    const stage: u8 = @intCast(number);
    const done = state.mode == .done or stage < state.current;
    const current = state.mode != .done and stage == state.current;
    const failed = state.mode == .failure and current;

    surface.fillRect(x, y, width, 34, if (current) theme.selected else theme.panel_alt);
    surface.fillRect(x, y, 4, 34, if (failed) failure else if (done) success else if (current) theme.accent else theme.border);

    var number_buffer: [12]u8 = undefined;
    const number_text = std.fmt.bufPrint(&number_buffer, "[{d}/{d}]", .{ number, state.total }) catch "[?/?]";
    text.draw(surface, x + 14, y + 13, number_text, 1, theme.muted);
    drawClipped(surface, x + 62, y + 13, width -| 180, stage_labels[number - 1], 1, if (done or current) theme.text else theme.muted);

    const status = if (failed) "FAILED" else if (done) "OK" else if (current) "RUNNING" else "WAITING";
    const status_color = if (failed) failure else if (done) success else if (current) theme.accent else theme.muted;
    const status_width = text.width(status, 1);
    text.draw(surface, x +| width -| status_width -| 14, y + 13, status, 1, status_color);
}

fn drawDetail(surface: Surface, theme: Theme, state: State, x: u32, y: u32, width: u32, height: u32) void {
    surface.fillRect(x, y, width, height, theme.panel);
    surface.borderRect(x, y, width, height, 1, theme.border);

    const title_color = switch (state.mode) {
        .done => success,
        .failure => failure,
        else => theme.text,
    };
    drawClipped(surface, x + 18, y + 18, width -| 36, state.title, 1, title_color);
    if (state.detail.len > 0) drawClipped(surface, x + 18, y + 44, width -| 36, state.detail, 1, theme.muted);

    if (state.mode == .done) {
        if (height >= 154) {
            drawClipped(surface, x + 18, y + 78, width -| 36, "REMOVE THE USOS USB DRIVE BEFORE POWERING OFF.", 1, theme.text);
            const button_x = x + 18;
            const button_y = y + 106;
            const button_width: u32 = @min(340, width -| 36);
            const button_height: u32 = 42;
            surface.fillRect(button_x, button_y, button_width, button_height, theme.selected);
            surface.borderRect(button_x, button_y, button_width, button_height, 2, theme.accent);
            text.draw(surface, button_x + 18, button_y + 16, "[ ENTER ]  POWER OFF", 1, theme.text);
            if (button_y + button_height + 30 < y + height) {
                drawClipped(surface, x + 18, button_y + button_height + 18, width -| 36, "NEXT POWER-ON: BOOT THE TARGET DISK WITHOUT USOS.", 1, theme.muted);
            }
        }
        return;
    }

    if (state.mode != .progress) {
        if (state.current < 4 and height >= 104) drawClipped(surface, x + 18, y + 78, width -| 36, "MEASURED PERCENTAGE, SPEED AND ETA BEGIN DURING FILE COPY.", 1, theme.muted);
        return;
    }

    const progress_top: u32 = if (state.detail.len > 0) y + 78 else y + 52;
    if (state.image.len > 0 and progress_top + 22 < y + height) {
        drawClipped(surface, x + 18, progress_top, width -| 36, state.image, 1, theme.text);
    }
    const bar_y = if (state.image.len > 0) progress_top + 28 else progress_top;
    if (bar_y + 24 >= y + height) return;

    const bar_x = x + 18;
    const bar_width = width -| 36;
    surface.fillRect(bar_x, bar_y, bar_width, 24, theme.background);
    surface.borderRect(bar_x, bar_y, bar_width, 24, 1, theme.border);
    const filled: u32 = @intCast((@as(u64, bar_width -| 4) * state.percent) / 100);
    surface.fillRect(bar_x + 2, bar_y + 2, filled, 20, if (state.mode == .done) success else theme.accent);

    if (bar_y + 64 >= y + height) return;
    var percent_buffer: [16]u8 = undefined;
    const percent_text = std.fmt.bufPrint(&percent_buffer, "{d}%", .{state.percent}) catch "?%";
    text.draw(surface, bar_x, bar_y + 36, percent_text, 2, if (state.mode == .done) success else theme.text);

    var transfer_buffer: [64]u8 = undefined;
    if (state.bytes_total > 0) text.draw(surface, bar_x + 112, bar_y + 42, transferText(&transfer_buffer, state.bytes_done, state.bytes_total), 1, theme.text);
    if (bar_y + 98 >= y + height) return;

    var speed_buffer: [32]u8 = undefined;
    var eta_buffer: [24]u8 = undefined;
    text.draw(surface, bar_x, bar_y + 72, "SPEED", 1, theme.muted);
    text.draw(surface, bar_x + 58, bar_y + 72, speedText(&speed_buffer, state.speed_bps), 1, theme.text);
    text.draw(surface, bar_x + 260, bar_y + 72, "ETA", 1, theme.muted);
    text.draw(surface, bar_x + 300, bar_y + 72, etaText(&eta_buffer, state.bytes_done, state.bytes_total, state.speed_bps), 1, theme.text);
}

fn footerText(mode: Mode) []const u8 {
    return if (mode == .done)
        "READY - REMOVE USOS USB, THEN PRESS ENTER TO POWER OFF."
    else
        "DO NOT DISCONNECT THE DRIVE OR TURN OFF THE COMPUTER.";
}

fn drawClipped(surface: Surface, x: u32, y: u32, max_text_width: u32, value: []const u8, scale: u32, color: Color) void {
    const chars: usize = @intCast(max_text_width / (6 * scale));
    if (chars == 0) return;
    text.draw(surface, x, y, value[0..@min(value.len, chars)], scale, color);
}

fn transferText(out: []u8, done: u64, total: u64) []const u8 {
    var done_buffer: [24]u8 = undefined;
    var total_buffer: [24]u8 = undefined;
    return std.fmt.bufPrint(out, "{s} / {s}", .{ bytesText(&done_buffer, done), bytesText(&total_buffer, total) }) catch "";
}

fn bytesText(out: []u8, bytes: u64) []const u8 {
    // Match Windows' visible labels while preserving the existing binary
    // scaling. Exact byte counts remain the source of truth in logs/state.
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var unit: usize = 0;
    var divisor: u64 = 1;
    while (unit + 1 < units.len and bytes / divisor >= 1024) : (unit += 1) divisor *= 1024;
    if (unit == 0) return std.fmt.bufPrint(out, "{d} B", .{bytes}) catch "";
    return std.fmt.bufPrint(out, "{d}.{d} {s}", .{ bytes / divisor, ((bytes % divisor) * 10) / divisor, units[unit] }) catch "";
}

fn speedText(out: []u8, bps: u64) []const u8 {
    if (bps == 0) return "--";
    var value: [24]u8 = undefined;
    return std.fmt.bufPrint(out, "{s}/s", .{bytesText(&value, bps)}) catch "--";
}

fn etaText(out: []u8, done: u64, total: u64, bps: u64) []const u8 {
    if (total > 0 and done >= total) return "00:00";
    if (bps == 0 or total == 0) return "--:--";
    const seconds = (total - done + bps - 1) / bps;
    const hours = seconds / 3600;
    const minutes = (seconds % 3600) / 60;
    const secs = seconds % 60;
    if (hours > 0) return std.fmt.bufPrint(out, "{d}:{d:0>2}:{d:0>2}", .{ hours, minutes, secs }) catch "--:--";
    return std.fmt.bufPrint(out, "{d:0>2}:{d:0>2}", .{ minutes, secs }) catch "--:--";
}

test "done preparation footer exposes the physical shutdown action" {
    try std.testing.expectEqualStrings("READY - REMOVE USOS USB, THEN PRESS ENTER TO POWER OFF.", footerText(.done));
    try std.testing.expectEqualStrings("DO NOT DISCONNECT THE DRIVE OR TURN OFF THE COMPUTER.", footerText(.stage));
}

test "shared preparation screen exposes the five canonical stages" {
    try std.testing.expectEqual(@as(usize, 5), stage_labels.len);
    try std.testing.expectEqualStrings("STARTING ENVIRONMENT", stage_labels[0]);
    try std.testing.expectEqualStrings("VERIFICATION AND FINALIZATION", stage_labels[4]);
}

test "visible transfer units use Windows-style labels without changing scaling" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1.5 GB", bytesText(&buffer, 1_610_612_736));
    try std.testing.expectEqualStrings("119.2 MB/s", speedText(&buffer, 125_000_000));
}

test "ETA is based on remaining measured bytes" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("00:05", etaText(&buffer, 500, 1000, 100));
}
