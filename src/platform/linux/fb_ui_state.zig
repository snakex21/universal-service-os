const std = @import("std");

pub const Mode = enum {
    stage,
    progress,
    done,
    failure,
    diagnostic,
    notice,
    service,
};

pub const max_diagnostic_lines: usize = 120;
pub const max_stage_labels: usize = 5;

pub const State = struct {
    mode: Mode = .stage,
    current: u8 = 1,
    total: u8 = 5,
    title: []const u8 = "Preparing boot media",
    detail: []const u8 = "",
    image: []const u8 = "",
    percent: u8 = 0,
    bytes_done: u64 = 0,
    bytes_total: u64 = 0,
    speed_bps: u64 = 0,
    diagnostics: [max_diagnostic_lines][]const u8 = undefined,
    diagnostic_count: usize = 0,
    diagnostics_truncated: bool = false,
    /// Optional `label=` lines: the stages this path really runs.
    labels: [max_stage_labels][]const u8 = undefined,
    label_count: usize = 0,
};

pub fn parse(input: []const u8) !State {
    var state = State{};
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const separator = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..separator], " \t");
        const value = std.mem.trim(u8, line[separator + 1 ..], " \t\r");

        if (std.mem.eql(u8, key, "mode")) {
            state.mode = std.meta.stringToEnum(Mode, value) orelse return error.InvalidMode;
        } else if (std.mem.eql(u8, key, "current")) {
            state.current = try parseU8(value);
        } else if (std.mem.eql(u8, key, "total")) {
            state.total = try parseU8(value);
        } else if (std.mem.eql(u8, key, "title")) {
            state.title = value;
        } else if (std.mem.eql(u8, key, "detail")) {
            state.detail = value;
        } else if (std.mem.eql(u8, key, "image")) {
            state.image = value;
        } else if (std.mem.eql(u8, key, "percent")) {
            state.percent = @min(100, try parseU8(value));
        } else if (std.mem.eql(u8, key, "bytes_done")) {
            state.bytes_done = try parseU64(value);
        } else if (std.mem.eql(u8, key, "bytes_total")) {
            state.bytes_total = try parseU64(value);
        } else if (std.mem.eql(u8, key, "speed_bps")) {
            state.speed_bps = try parseU64(value);
        } else if (std.mem.eql(u8, key, "label")) {
            if (state.label_count >= state.labels.len) return error.TooManyStageLabels;
            if (value.len == 0) return error.InvalidStageLabel;
            state.labels[state.label_count] = value;
            state.label_count += 1;
        } else if (std.mem.eql(u8, key, "diag")) {
            if (state.diagnostic_count < state.diagnostics.len) {
                state.diagnostics[state.diagnostic_count] = value;
                state.diagnostic_count += 1;
            } else {
                state.diagnostics_truncated = true;
            }
        }
    }

    if (state.total == 0) return error.InvalidStageTotal;
    // Declared labels define the stage count; never draw unnamed stages.
    if (state.label_count > 0) state.total = @intCast(state.label_count);
    if (state.current == 0) state.current = 1;
    if (state.current > state.total) state.current = state.total;
    if (state.bytes_total > 0 and state.bytes_done > state.bytes_total) state.bytes_done = state.bytes_total;
    if (state.mode == .done) {
        state.current = state.total;
        state.percent = 100;
        if (state.bytes_total > 0) state.bytes_done = state.bytes_total;
    }
    return state;
}

fn parseU8(text: []const u8) !u8 {
    return std.fmt.parseInt(u8, text, 10) catch return error.InvalidNumber;
}

fn parseU64(text: []const u8) !u64 {
    return std.fmt.parseInt(u64, text, 10) catch return error.InvalidNumber;
}

test "state parser reads framebuffer preparation state" {
    const state = try parse(
        \\mode=progress
        \\current=4
        \\total=5
        \\title=Copying files
        \\detail=Measured byte progress
        \\image=Win11.iso
        \\percent=42
        \\bytes_done=4200000000
        \\bytes_total=10000000000
        \\speed_bps=125000000
    );
    try std.testing.expectEqual(Mode.progress, state.mode);
    try std.testing.expectEqual(@as(u8, 4), state.current);
    try std.testing.expectEqual(@as(u8, 42), state.percent);
    try std.testing.expectEqual(@as(u64, 125000000), state.speed_bps);
    try std.testing.expectEqualStrings("Win11.iso", state.image);
}

test "diagnostic state keeps repeated diagnostic lines" {
    const state = try parse(
        \\mode=diagnostic
        \\diag=one
        \\diag=two=with-equals
    );
    try std.testing.expectEqual(Mode.diagnostic, state.mode);
    try std.testing.expectEqual(@as(usize, 2), state.diagnostic_count);
    try std.testing.expectEqualStrings("one", state.diagnostics[0]);
    try std.testing.expectEqualStrings("two=with-equals", state.diagnostics[1]);
}

test "done state forces final progress" {
    const state = try parse(
        \\mode=done
        \\current=5
        \\total=5
        \\percent=77
        \\bytes_done=10
        \\bytes_total=20
    );
    try std.testing.expectEqual(@as(u8, 100), state.percent);
    try std.testing.expectEqual(@as(u64, 20), state.bytes_done);
}

test "declared stage labels define the stage count" {
    const state = try parse("mode=stage" ++ NL ++ "current=2" ++ NL ++ "total=5" ++ NL ++ "label=Starting environment" ++ NL ++ "label=Continuing installation" ++ NL ++ "title=Continuing" ++ NL);
    try std.testing.expectEqual(@as(usize, 2), state.label_count);
    try std.testing.expectEqual(@as(u8, 2), state.total);
    try std.testing.expectEqualStrings("Continuing installation", state.labels[1]);
}

test "stage labels beyond the renderer limit are rejected" {
    try std.testing.expectError(error.TooManyStageLabels, parse("label=a" ++ NL ++ "label=b" ++ NL ++ "label=c" ++ NL ++ "label=d" ++ NL ++ "label=e" ++ NL ++ "label=f" ++ NL));
}

const NL = "\n";
