//! Progress screen shared by the UEFI handoff/ISO paths and the micro-Linux
//! preparation UI, styled like the installer's progress page: a warning
//! banner, a progress card with the current step and a list of the steps
//! the path really runs.
const std = @import("std");
const ui_mod = @import("ui.zig");
const icons = @import("icons.zig");
const Ui = ui_mod.Ui;
const Rect = ui_mod.Rect;

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
    /// Page heading; empty means "Preparing Windows installer".
    heading: []const u8 = "",
    /// Current activity (English from scripts is translated by Ui.tr).
    title: []const u8 = "Starting environment",
    detail: []const u8 = "",
    image: []const u8 = "",
    percent: u8 = 0,
    bytes_done: u64 = 0,
    bytes_total: u64 = 0,
    speed_bps: u64 = 0,
    diagnostics: []const []const u8 = &.{},
    diagnostics_truncated: bool = false,
    /// Labels of the stages this path really runs; `total` rows are drawn.
    /// Defaults to the five micro-Linux preparation stages.
    labels: []const []const u8 = &stage_labels,
};

pub const max_stages: usize = 5;

/// Byte, speed and ETA figures need 64-bit division, which the i386 Legacy
/// BIOS Core does not link; its progress frames never carry byte counts.
const byte_figures = !(@import("builtin").os.tag == .freestanding and @import("builtin").cpu.arch == .x86);

/// English stage labels of the five micro-Linux preparation stages; they
/// equal the boot.prep.stage.* catalog values and the script labels.
pub const stage_labels = [_][]const u8{
    "Starting environment",
    "Verifying target device",
    "Preparing workspace",
    "Copying files",
    "Verification and finalization",
};

/// Number of stage rows actually drawn for a state.
pub fn stageCount(state: State) usize {
    return @max(@as(usize, 1), @min(@min(@as(usize, state.total), state.labels.len), max_stages));
}

/// True for the five-stage micro-Linux model, whose stage 4 measures a copy.
fn usesCopyStages(state: State) bool {
    return state.labels.ptr == @as([*]const []const u8, &stage_labels) and stageCount(state) == stage_labels.len;
}

pub fn render(ui: *const Ui, state: State, header: ui_mod.HeaderInfo) void {
    ui.clear();
    ui.header(header);
    if (state.mode == .diagnostic) {
        renderDiagnostic(ui, state);
        return;
    }
    var heading_buffer: [160]u8 = undefined;
    const heading = if (state.heading.len > 0) ui.tr(&heading_buffer, state.heading) else ui.t(.prep_title);
    ui.pageTitle(heading, "");
    const body = ui.bodyRect(false);

    const banner_h = ui.px(46);
    const banner_tone: ui_mod.Tone = switch (state.mode) {
        .done => .success,
        .failure => .danger,
        else => .warning,
    };
    const banner_icon: icons.Kind = switch (state.mode) {
        .done => .check_circle,
        .failure => .error_circle,
        else => .warning,
    };
    var title_buffer: [192]u8 = undefined;
    const activity = ui.tr(&title_buffer, state.title);
    const banner_text = switch (state.mode) {
        .done => ui.t(.prep_footer_done),
        .failure => activity,
        else => ui.t(.prep_footer_running),
    };
    ui.banner(.{ .x = body.x, .y = body.y, .w = body.w, .h = banner_h }, banner_tone, banner_icon, banner_text);

    const card_y = body.y + banner_h + ui.px(16);
    const card_h = progressCardHeight(ui, state);
    drawProgressCard(ui, state, .{ .x = body.x, .y = card_y, .w = body.w, .h = card_h });

    const steps_y = card_y + card_h + ui.px(16);
    const count = stageCount(state);
    const step_h = ui.px(46);
    const steps_h = ui.px(16) + @as(u32, @intCast(count)) * step_h;
    if (steps_y + steps_h <= body.bottom()) drawSteps(ui, state, .{ .x = body.x, .y = steps_y, .w = body.w, .h = steps_h }, step_h);

    if (state.mode == .done) {
        ui.footer(&.{.{ .key = "Enter", .label = ui.t(.key_power_off) }}, ui.t(.prep_next_boot));
    } else {
        ui.footer(&.{}, ui.t(.wait));
    }
}

/// Redraws only the progress card (percent, bytes, speed) of a frame that
/// `render` drew with the same state layout.
pub fn updateProgress(ui: *const Ui, state: State) void {
    const body = ui.bodyRect(false);
    const card_y = body.y + ui.px(46) + ui.px(16);
    drawProgressCard(ui, state, .{ .x = body.x, .y = card_y, .w = body.w, .h = progressCardHeight(ui, state) });
}

fn progressCardHeight(ui: *const Ui, state: State) u32 {
    var h = ui.px(22) + ui.fonts.lineHeight(.strong) + ui.px(14) + ui.px(8) + ui.px(14) + ui.fonts.lineHeight(.body) + ui.px(20);
    if (state.mode == .progress and (state.bytes_total > 0 or state.image.len > 0)) h += ui.fonts.lineHeight(.body) + ui.px(6);
    if (state.mode == .done) h += ui.fonts.lineHeight(.body) + ui.px(6);
    return h;
}

fn drawProgressCard(ui: *const Ui, state: State, rect: Rect) void {
    const theme = ui.theme;
    const paint = @import("paint.zig");
    paint.card(ui.surface, rect.x, rect.y, rect.w, rect.h, ui.px(10), ui.line(1), theme.border, theme.panel, theme.background);
    const pad = ui.px(22);
    const inner_w = rect.w -| (2 * pad);
    var y = rect.y + pad;

    const count = stageCount(state);
    const current: usize = @min(@max(@as(usize, state.current), 1), count);
    var label_buffer: [160]u8 = undefined;
    const label = ui.tr(&label_buffer, state.labels[current - 1]);
    var step_buffer: [48]u8 = undefined;
    var current_text: [4]u8 = undefined;
    var total_text: [4]u8 = undefined;
    const step = ui.format(&step_buffer, .prep_step, &.{ decimal(&current_text, current), decimal(&total_text, count) });
    var heading_buffer: [224]u8 = undefined;
    const heading = std.fmt.bufPrint(&heading_buffer, "{s}: {s}", .{ step, label }) catch label;

    const percent: u8 = switch (state.mode) {
        .done => 100,
        .progress => state.percent,
        else => @intCast(@min(100, ((current - 1) * 100) / count)),
    };
    var percent_buffer: [8]u8 = undefined;
    const percent_text = std.fmt.bufPrint(&percent_buffer, "{d}%", .{percent}) catch "";
    const percent_w = ui.fonts.width(.heading, percent_text);
    const tone: ui_mod.Tone = switch (state.mode) {
        .done => .success,
        .failure => .danger,
        else => .accent,
    };
    const tone_color = switch (tone) {
        .success => theme.success,
        .danger => theme.danger,
        else => theme.accent,
    };
    _ = ui.fonts.drawFit(ui.surface, rect.x + pad, y + (ui.fonts.lineHeight(.heading) -| ui.fonts.lineHeight(.strong)) / 2, inner_w -| percent_w -| ui.px(20), .strong, heading, theme.text, theme.panel);
    _ = ui.fonts.drawRight(ui.surface, rect.right() -| pad, y -| ui.px(2), .heading, percent_text, tone_color, theme.panel);
    y += ui.fonts.lineHeight(.strong) + ui.px(14);
    ui.progressBar(.{ .x = rect.x + pad, .y = y, .w = inner_w, .h = ui.px(8) }, percent, tone, theme.panel);
    y += ui.px(8) + ui.px(14);

    var activity_buffer: [192]u8 = undefined;
    var detail_buffer: [256]u8 = undefined;
    const activity = ui.tr(&activity_buffer, state.title);
    const detail = ui.tr(&detail_buffer, state.detail);
    if (state.mode == .failure) {
        _ = ui.fonts.drawFit(ui.surface, rect.x + pad, y, inner_w, .body, if (detail.len > 0) detail else activity, theme.danger, theme.panel);
    } else {
        var line_buffer: [448]u8 = undefined;
        const joined = if (detail.len > 0 and !std.mem.eql(u8, activity, label))
            std.fmt.bufPrint(&line_buffer, "{s} - {s}", .{ activity, detail }) catch detail
        else if (detail.len > 0)
            detail
        else
            activity;
        _ = ui.fonts.drawFit(ui.surface, rect.x + pad, y, inner_w, .body, joined, theme.muted, theme.panel);
    }
    y += ui.fonts.lineHeight(.body) + ui.px(6);

    if (state.mode == .progress) {
        var x = rect.x + pad;
        if (state.image.len > 0) {
            const image_w = inner_w / 3;
            _ = ui.fonts.drawFit(ui.surface, x, y, image_w, .body, state.image, theme.text, theme.panel);
            x += image_w + ui.px(16);
        }
        var transfer_buffer: [64]u8 = undefined;
        if (byte_figures and state.bytes_total > 0) x += ui.fonts.draw(ui.surface, x, y, .body, transferText(&transfer_buffer, state.bytes_done, state.bytes_total), theme.text, theme.panel) + ui.px(24);
        if (byte_figures and state.bytes_total > 0) {
            var speed_buffer: [32]u8 = undefined;
            x += ui.fonts.draw(ui.surface, x, y, .body, ui.t(.prep_speed), theme.muted, theme.panel) + ui.px(8);
            x += ui.fonts.draw(ui.surface, x, y, .body, speedText(&speed_buffer, state.speed_bps), theme.text, theme.panel) + ui.px(24);
            var eta_buffer: [24]u8 = undefined;
            x += ui.fonts.draw(ui.surface, x, y, .body, ui.t(.prep_eta), theme.muted, theme.panel) + ui.px(8);
            _ = ui.fonts.draw(ui.surface, x, y, .body, etaText(&eta_buffer, state.bytes_done, state.bytes_total, state.speed_bps), theme.text, theme.panel);
        }
    } else if (state.mode == .done) {
        _ = ui.fonts.drawFit(ui.surface, rect.x + pad, y, inner_w, .body, ui.t(.prep_remove_usb), theme.text, theme.panel);
    } else if (usesCopyStages(state) and state.current < 4) {
        _ = ui.fonts.drawFit(ui.surface, rect.x + pad, y, inner_w, .small, ui.t(.prep_copy_note), theme.faint, theme.panel);
    }
}

fn drawSteps(ui: *const Ui, state: State, rect: Rect, step_h: u32) void {
    const theme = ui.theme;
    const paint = @import("paint.zig");
    paint.card(ui.surface, rect.x, rect.y, rect.w, rect.h, ui.px(10), ui.line(1), theme.border, theme.panel, theme.background);
    const count = stageCount(state);
    for (0..count) |index| {
        const number = index + 1;
        const done = state.mode == .done or number < state.current;
        const current = state.mode != .done and number == state.current;
        const failed = state.mode == .failure and current;
        const row = Rect{ .x = rect.x + ui.px(8), .y = rect.y + ui.px(8) + @as(u32, @intCast(index)) * step_h, .w = rect.w -| ui.px(16), .h = step_h };
        const fill = if (current) theme.panel_alt else theme.panel;
        if (current) paint.roundRect(ui.surface, row.x, row.y, row.w, row.h, ui.px(8), fill, theme.panel);
        const icon_size = ui.px(24);
        const icon_x = row.x + ui.px(16);
        const icon_y = row.y + (row.h -| icon_size) / 2;
        if (failed) {
            icons.draw(ui.surface, .error_circle, icon_x, icon_y, icon_size, theme.danger, null);
        } else if (done) {
            icons.draw(ui.surface, .check_circle, icon_x, icon_y, icon_size, theme.success, null);
        } else if (current) {
            icons.draw(ui.surface, .spinner, icon_x, icon_y, icon_size, theme.accent, null);
        } else {
            icons.draw(ui.surface, .pending, icon_x, icon_y, icon_size, theme.faint, null);
        }
        var number_buffer: [12]u8 = undefined;
        const number_text = std.fmt.bufPrint(&number_buffer, "{d}/{d}", .{ number, count }) catch "";
        const center = row.y + row.h / 2;
        const number_x = icon_x + icon_size + ui.px(16);
        _ = ui.fonts.draw(ui.surface, number_x, ui.fonts.centeredTop(.body, center), .body, number_text, theme.faint, fill);
        const status = if (failed) ui.t(.prep_status_failed) else if (done) ui.t(.prep_status_done) else if (current) ui.t(.prep_status_running) else ui.t(.prep_status_waiting);
        const status_color = if (failed) theme.danger else if (done) theme.success else if (current) theme.accent else theme.faint;
        const status_w = ui.fonts.drawRight(ui.surface, row.right() -| ui.px(16), ui.fonts.centeredTop(.body, center), .body, status, status_color, fill);
        var label_buffer: [160]u8 = undefined;
        const label = ui.tr(&label_buffer, state.labels[index]);
        const label_x = number_x + ui.fonts.width(.body, "00/00") + ui.px(16);
        _ = ui.fonts.drawFit(ui.surface, label_x, ui.fonts.centeredTop(.strong, center), row.right() -| ui.px(32) -| status_w -| label_x, if (current) .strong else .body, label, if (done or current) theme.text else theme.muted, fill);
    }
}

fn renderDiagnostic(ui: *const Ui, state: State) void {
    const theme = ui.theme;
    const content = ui.contentRect();
    const frozen = std.mem.eql(u8, state.title, "Starting environment") or state.title.len == 0;
    var title_buffer: [192]u8 = undefined;
    const title = if (frozen) ui.t(.prep_diag_title) else ui.tr(&title_buffer, state.title);
    _ = ui.fonts.drawFit(ui.surface, content.x, content.y, content.w, .strong, title, if (frozen) theme.danger else theme.accent, theme.background);
    const first_y = content.y + ui.fonts.lineHeight(.strong) + ui.px(8);
    const step = ui.fonts.lineHeight(.small);
    const bottom = ui.height() -| ui.px(8);
    const visible: usize = @intCast((bottom -| first_y) / @max(step, 1));
    const count = @min(state.diagnostics.len, visible);
    for (state.diagnostics[0..count], 0..) |line, index| {
        const y = first_y + @as(u32, @intCast(index)) * step;
        const color = if (std.mem.startsWith(u8, line, "==")) theme.accent else theme.text;
        _ = ui.fonts.drawFit(ui.surface, content.x, y, content.w, .small, line, color, theme.background);
    }
    if ((state.diagnostics.len > visible or state.diagnostics_truncated) and visible > 0) {
        const y = first_y + @as(u32, @intCast(visible - 1)) * step;
        ui.surface.fillRect(content.x, y, content.w, step, theme.background);
        _ = ui.fonts.drawFit(ui.surface, content.x, y, content.w, .small, ui.t(.prep_diag_truncated), theme.danger, theme.background);
    }
}

fn decimal(buffer: []u8, value: usize) []const u8 {
    return std.fmt.bufPrint(buffer, "{d}", .{value}) catch "?";
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

test "stage labels match the catalog keys" {
    const lang_file = @import("../i18n/lang_file.zig");
    const table = lang_file.Table.english_only;
    const keys = [_]lang_file.Key{ .prep_stage_1, .prep_stage_2, .prep_stage_3, .prep_stage_4, .prep_stage_5 };
    for (keys, stage_labels) |key, label| try std.testing.expectEqualStrings(label, table.get(key));
}

test "XP stage labels and details match the catalog keys" {
    const lang_file = @import("../i18n/lang_file.zig");
    const XpStage = @import("../flow/preparation_boot_progress.zig").XpStage;
    const table = lang_file.Table.english_only;
    const labels = [_]lang_file.Key{ .xp_prep_environment, .xp_prep_choose_disk, .prep_stage_3, .xp_prep_copy_verify };
    for (labels, [_][]const u8{ XpStage.labels[0], XpStage.labels[2], XpStage.labels[3], XpStage.labels[4] }) |key, label| try std.testing.expectEqualStrings(label, table.get(key));
    // Stage 2 is the micro-Linux string boot.lx.detecting_disks.
    const linux_strings = @import("../i18n/linux_strings.zig");
    var found = false;
    for (linux_strings.english) |english| found = found or std.mem.eql(u8, english, XpStage.labels[1]);
    try std.testing.expect(found);
    try std.testing.expectEqualStrings(XpStage.checking.detail(), table.get(.xp_prep_checking));
    try std.testing.expectEqualStrings(XpStage.loading.detail(), table.get(.xp_prep_loading));
    try std.testing.expectEqualStrings(XpStage.starting.detail(), table.get(.xp_prep_starting));
    try std.testing.expectEqual(@as(usize, 5), stageCount(.{ .total = 5, .labels = &XpStage.labels }));
}

test "stage rows follow the stages a path really runs" {
    const iso_labels = [_][]const u8{ "Validating installation ISO", "Loading Windows boot files", "Starting Windows Setup" };
    try std.testing.expectEqual(@as(usize, 5), stageCount(.{}));
    try std.testing.expectEqual(@as(usize, 3), stageCount(.{ .total = 3, .labels = &iso_labels }));
    try std.testing.expectEqual(@as(usize, 1), stageCount(.{ .total = 1 }));
    // A declared total larger than the declared labels never draws unnamed rows.
    try std.testing.expectEqual(@as(usize, 3), stageCount(.{ .total = 5, .labels = &iso_labels }));
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

test "progress screen renders every mode in Polish at 1920x1080" {
    const font = @import("font.zig");
    const lang_file = @import("../i18n/lang_file.zig");
    const ScreenBuffer = @import("screen_buffer.zig").ScreenBuffer;
    const Theme = @import("theme.zig").Theme;
    const pack = try font.Pack.parse(@embedFile("fonts/usos-font.bin"));
    const coverage = lang_file.Coverage{ .context = @ptrCast(&pack), .has = font.coverageHas };
    const table = try lang_file.Table.parse(@embedFile("../i18n/testdata/lang-pl.bin"), coverage);
    const pixels = try std.testing.allocator.alloc(u32, 1920 * 1080);
    defer std.testing.allocator.free(pixels);
    const buffer = ScreenBuffer.init(@intFromPtr(pixels.ptr), pixels.len * 4, 1920, 1080, .bgrx8).?;
    const ui = Ui.init(buffer.surface, Theme{}, &pack, &table);
    const lines = [_][]const u8{ "== DISKS ==", "sda 8 GiB" };
    for ([_]Mode{ .stage, .progress, .done, .failure, .diagnostic }) |mode| {
        render(&ui, .{ .mode = mode, .current = 4, .title = "Copying WIM file", .detail = "12 of 40 files", .image = "win11.iso", .percent = 44, .bytes_done = 1 << 30, .bytes_total = 3 << 30, .speed_bps = 90 << 20, .diagnostics = &lines }, .{ .firmware = "UEFI", .language = "Polski" });
        try std.testing.expect(pixels[0] != pixels[pixels.len / 2]);
    }
    updateProgress(&ui, .{ .mode = .progress, .current = 4, .percent = 50 });
}
