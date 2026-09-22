const console = @import("console.zig");

pub const Screen = enum(u8) {
    none = 0,
    categories,
    systems,
    utilities,
    images,
    methods,
    unattended,
    power,
};

pub const Event = enum(u8) {
    none = 0,
    up,
    down,
    left,
    right,
    enter,
    escape,
    backspace,
    diagnostics,
    other,
};

// Legacy Core rejects .bss. Zig may split struct fields into separate globals,
// so every mutable storage word carries an active non-zero bias and therefore
// remains in .data even after scalar replacement.
const u32_bias: u32 = 0x80000000;
const u8_bias: u8 = 0x80;

var event_count_biased: u32 = u32_bias;
var selected_index_biased: u32 = u32_bias;
var last_event_biased: u8 = u8_bias;
var screen_biased: u8 = u8_bias;
var enter_count_biased: u32 = u32_bias;
var last_enter_index_biased: u32 = u32_bias;
var last_enter_screen_biased: u8 = u8_bias;

pub fn setSelection(screen: Screen, selected_index: usize) void {
    screen_biased = u8_bias + @intFromEnum(screen);
    selected_index_biased = u32_bias + @as(u32, @intCast(selected_index));
}

pub fn recordKey(screen: Screen, selected_index: usize, key: console.Key) void {
    setSelection(screen, selected_index);
    if (event_count_biased != 0xFFFFFFFF) event_count_biased += 1;
    const event = classify(key);
    last_event_biased = u8_bias + @intFromEnum(event);
    if (event == .enter) {
        if (enter_count_biased != 0xFFFFFFFF) enter_count_biased += 1;
        last_enter_screen_biased = u8_bias + @intFromEnum(screen);
        last_enter_index_biased = u32_bias + @as(u32, @intCast(selected_index));
    }
}

pub fn eventCount() u32 {
    return event_count_biased - u32_bias;
}

pub fn selectedIndex() u32 {
    return selected_index_biased - u32_bias;
}

pub fn lastEventName() []const u8 {
    return eventName(@enumFromInt(last_event_biased - u8_bias));
}

pub fn screenName() []const u8 {
    return screenNameFrom(@enumFromInt(screen_biased - u8_bias));
}

pub fn enterCount() u32 {
    return enter_count_biased - u32_bias;
}

pub fn lastEnterIndex() u32 {
    return last_enter_index_biased - u32_bias;
}

pub fn lastEnterScreenName() []const u8 {
    return screenNameFrom(@enumFromInt(last_enter_screen_biased - u8_bias));
}

fn screenNameFrom(screen: Screen) []const u8 {
    return switch (screen) {
        .none => "NONE",
        .categories => "CATEGORIES",
        .systems => "SYSTEMS",
        .utilities => "UTILITIES",
        .images => "IMAGES",
        .methods => "METHODS",
        .unattended => "UNATTENDED",
        .power => "POWER",
    };
}

fn classify(key: console.Key) Event {
    if (key.ascii == 27) return .escape;
    if (key.ascii == 8) return .backspace;
    if (key.ascii == 13) return .enter;
    if (key.ascii == 'd' or key.ascii == 'D') return .diagnostics;
    return switch (key.scan) {
        0x48 => .up,
        0x50 => .down,
        0x4B => .left,
        0x4D => .right,
        else => .other,
    };
}

fn eventName(event: Event) []const u8 {
    return switch (event) {
        .none => "NONE",
        .up => "UP",
        .down => "DOWN",
        .left => "LEFT",
        .right => "RIGHT",
        .enter => "ENTER",
        .escape => "ESC",
        .backspace => "BACKSPACE",
        .diagnostics => "DIAGNOSTICS",
        .other => "OTHER",
    };
}

test "Enter on IMAGES remains visible after diagnostics key" {
    const std = @import("std");
    recordKey(.images, 0, .{ .ascii = 13, .scan = 0x1c });
    recordKey(.images, 0, .{ .ascii = 'D', .scan = 0x20 });
    try std.testing.expectEqualStrings("DIAGNOSTICS", lastEventName());
    try std.testing.expectEqualStrings("IMAGES", lastEnterScreenName());
    try std.testing.expectEqual(@as(u32, 0), lastEnterIndex());
    try std.testing.expect(enterCount() >= 1);
}
