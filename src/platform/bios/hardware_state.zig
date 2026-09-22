const std = @import("std");

extern fn core_a20_state() callconv(.c) u32;
extern fn core_pic1_mask() callconv(.c) u32;
extern fn core_pic1_irr_isr() callconv(.c) u32;
extern fn core_8042_status() callconv(.c) u32;
extern fn core_idtr_base() callconv(.c) u32;
extern fn core_idtr_limit() callconv(.c) u32;
extern fn core_bda_keyboard_offsets() callconv(.c) u32;

pub const Snapshot = struct {
    a20_enabled: bool = false,
    pic1_mask: u8 = 0,
    pic1_irr: u8 = 0,
    pic1_isr: u8 = 0,
    controller_8042_status: u8 = 0,
    idtr_base: u32 = 0,
    idtr_limit: u16 = 0,
    keyboard_head: u16 = 0,
    keyboard_tail: u16 = 0,
};

pub fn capture() Snapshot {
    return fromRaw(
        core_a20_state(),
        core_pic1_mask(),
        core_pic1_irr_isr(),
        core_8042_status(),
        core_idtr_base(),
        core_idtr_limit(),
        core_bda_keyboard_offsets(),
    );
}

fn fromRaw(a20: u32, pic1: u32, pic_requests: u32, status_8042: u32, idtr_base: u32, idtr_limit: u32, keyboard: u32) Snapshot {
    return .{
        .a20_enabled = a20 != 0,
        .pic1_mask = @truncate(pic1),
        .pic1_irr = @truncate(pic_requests),
        .pic1_isr = @truncate(pic_requests >> 8),
        .controller_8042_status = @truncate(status_8042),
        .idtr_base = idtr_base,
        .idtr_limit = @truncate(idtr_limit),
        .keyboard_head = @truncate(keyboard),
        .keyboard_tail = @truncate(keyboard >> 16),
    };
}

test "hardware snapshot decodes packed BIOS state" {
    const snapshot = fromRaw(1, 0xFD, 0x0204, 0x1D, 0x12345678, 0x03FF, 0x0030001E);
    try std.testing.expect(snapshot.a20_enabled);
    try std.testing.expectEqual(@as(u8, 0xFD), snapshot.pic1_mask);
    try std.testing.expectEqual(@as(u8, 0x04), snapshot.pic1_irr);
    try std.testing.expectEqual(@as(u8, 0x02), snapshot.pic1_isr);
    try std.testing.expectEqual(@as(u8, 0x1D), snapshot.controller_8042_status);
    try std.testing.expectEqual(@as(u32, 0x12345678), snapshot.idtr_base);
    try std.testing.expectEqual(@as(u16, 0x03FF), snapshot.idtr_limit);
    try std.testing.expectEqual(@as(u16, 0x001E), snapshot.keyboard_head);
    try std.testing.expectEqual(@as(u16, 0x0030), snapshot.keyboard_tail);
}
