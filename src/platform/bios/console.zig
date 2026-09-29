extern fn core_poll_scancode() callconv(.c) u32;
extern fn bios_poll_key() callconv(.c) u32;
extern fn core_scancode_count() callconv(.c) u32;
extern fn core_last_scancode() callconv(.c) u32;
extern fn core_keyboard_poll_count() callconv(.c) u32;
extern fn core_last_keyboard_status() callconv(.c) u32;
extern fn core_int13_read_count() callconv(.c) u32;
extern fn core_int13_8042_before() callconv(.c) u32;
extern fn core_int13_8042_after() callconv(.c) u32;
extern fn core_a20_92_write_count() callconv(.c) u32;
extern fn core_a20_92_before() callconv(.c) u32;
extern fn core_a20_92_after() callconv(.c) u32;
extern fn core_pit_counter() callconv(.c) u32;
extern fn core_clear_screen() callconv(.c) void;
extern fn core_putc(byte: u8) callconv(.c) void;
extern fn core_serial_putc(byte: u8) callconv(.c) void;

// Keep initialized data: the Legacy Core deliberately rejects .bss.
pub var screen_output: bool = true;

pub const Key = struct {
    ascii: u8,
    scan: u8,
    selection: u8 = 255,
};

var auxiliary: struct { hook: ?*const fn (u8) ?Key = null, marker: u8 = 1 } linksection(".data") = .{};
pub fn setAuxiliaryHook(hook: ?*const fn (u8) ?Key) void {
    auxiliary.hook = hook;
}

const no_scancode: u32 = 0xFFFFFFFF;
const pit_counts_per_bios_tick: u32 = 65536;

const ScanDecoder = struct {
    extended: bool = false,
    held_scan: ?u8 = null,
    held_extended: bool = false,
    last_accepted_scan: u8 = 0,
    response_like_count: u32 = 0,
    last_response_like: u8 = 0,
    raw_tail: [8]u8 = [_]u8{0} ** 8,
    raw_tail_len: u8 = 0,
    raw_tail_next: u8 = 0,
    // Legacy Core rejects .bss. Keep the persistent decoder object in .data
    // without changing its logical initial state.
    data_marker: u8 = 0xA5,

    fn feed(self: *ScanDecoder, byte: u8) ?Key {
        self.recordRaw(byte);

        // Resolve Set 1 prefixes before classifying device/controller replies.
        // Legacy BIOS keyboard translation may wrap an extended navigation key
        // in fake Shift bytes: E0 2A ... E0 AA. Those bytes are part of the
        // translated scan stream, not BAT/Shift events, and must not touch the
        // held-key state or response telemetry.
        if (byte == 0xE0) {
            self.extended = true;
            return null;
        }
        if (byte == 0xE1) {
            self.extended = false;
            return null;
        }

        const extended = self.extended;
        self.extended = false;
        if (extended and (byte == 0x2A or byte == 0xAA)) return null;

        // Response bytes are only classified outside an E0 sequence. 0xAA is
        // ambiguous with the ordinary Set 1 Left Shift break, but Shift is not
        // a menu key, so an unprefixed 0xAA can safely be ignored here.
        if (!extended and isResponseLike(byte)) {
            self.response_like_count +|= 1;
            self.last_response_like = byte;
            return null;
        }

        const is_break = (byte & 0x80) != 0;
        const scan = byte & 0x7F;

        if (is_break) {
            if (self.held_scan != null and self.held_scan.? == scan and self.held_extended == extended) {
                self.held_scan = null;
                self.held_extended = false;
            }
            return null;
        }

        const key = decodeSet1(scan, extended) orelse return null;
        if (self.held_scan != null and self.held_scan.? == scan and self.held_extended == extended) {
            return null;
        }

        // A different valid make code proves that input progressed even if an
        // earlier matching break was swallowed by a BIOS/8042 transition.
        // Suppress only typematic repeats of the same key; never deadlock the
        // whole menu waiting forever for one lost break code.
        self.held_scan = scan;
        self.held_extended = extended;
        self.last_accepted_scan = scan;
        return key;
    }

    fn recordRaw(self: *ScanDecoder, byte: u8) void {
        const index: usize = self.raw_tail_next;
        self.raw_tail[index] = byte;
        self.raw_tail_next = if (self.raw_tail_next + 1 < self.raw_tail.len) self.raw_tail_next + 1 else 0;
        if (self.raw_tail_len < self.raw_tail.len) self.raw_tail_len += 1;
    }
};

var scan_decoder: ScanDecoder = .{};

pub fn releaseKeyAfterFirmwareIo() void {
    // BIOS disk calls may consume the previous screen's key-release byte.
    scan_decoder.held_scan = null;
    scan_decoder.held_extended = false;
}

pub fn clear() void {
    core_clear_screen();
}

/// Runs before every key wait: the graphical menu presents what it drew
/// into its back buffer (boot_ui / menu_pointer), so every screen that
/// waits for a key is on the display, whichever helper drew it.
pub var before_wait: ?*const fn () void linksection(".data") = null;

pub fn readKey() Key {
    if (before_wait) |hook| hook();
    while (true) {
        if (pollKey()) |key| return key;
    }
}

pub fn readKeyTimeoutTicks(timeout_ticks: u32) ?Key {
    if (before_wait) |hook| hook();
    if (timeout_ticks == 0) return pollKey();
    const target_counts = timeout_ticks *| pit_counts_per_bios_tick;
    var elapsed: u32 = 0;
    var previous: u16 = @truncate(core_pit_counter());
    while (elapsed < target_counts) {
        if (pollKey()) |key| return key;
        const current: u16 = @truncate(core_pit_counter());
        const delta: u16 = previous -% current;
        elapsed +|= delta;
        previous = current;
    }
    return null;
}

pub fn scancodeCount() u32 {
    return core_scancode_count();
}

pub fn lastScancode() u8 {
    return @truncate(core_last_scancode());
}

pub fn lastAcceptedScancode() u8 {
    return scan_decoder.last_accepted_scan;
}

pub fn keyboardPollCount() u32 {
    return core_keyboard_poll_count();
}

pub fn lastKeyboardStatus() u8 {
    return @truncate(core_last_keyboard_status());
}

pub fn int13ReadCount() u32 {
    return core_int13_read_count();
}

pub fn int13StatusBefore() u8 {
    return @truncate(core_int13_8042_before());
}

pub fn int13StatusAfter() u8 {
    return @truncate(core_int13_8042_after());
}

pub fn a20Port92WriteCount() u8 {
    return @truncate(core_a20_92_write_count());
}

pub fn a20Port92Before() u8 {
    return @truncate(core_a20_92_before());
}

pub fn a20Port92After() u8 {
    return @truncate(core_a20_92_after());
}

pub fn responseLikeCount() u32 {
    return scan_decoder.response_like_count;
}

pub fn lastResponseLike() u8 {
    return scan_decoder.last_response_like;
}

pub fn printRawTail() void {
    const len: usize = scan_decoder.raw_tail_len;
    if (len == 0) {
        print("[empty]");
        return;
    }
    const start: usize = if (len < scan_decoder.raw_tail.len) 0 else scan_decoder.raw_tail_next;
    var offset: usize = 0;
    while (offset < len) : (offset += 1) {
        if (offset != 0) put(' ');
        const index = (start + offset) % scan_decoder.raw_tail.len;
        printHex8(scan_decoder.raw_tail[index]);
    }
}

/// SeaBIOS (plain, or as the CSM inside CSMWrap) handles USB keyboards only
/// through INT 16h and has no 8042 emulation, so the 8042 polling below never
/// sees them. When set (core_main, SeaBIOS signature found), an empty 8042 is
/// followed by one non-blocking INT 16h poll, until the 8042 has delivered
/// its first keyboard byte: from then on a PS/2 keyboard is in use and only
/// the 8042 path reads keys, so no key arrives twice (once through the port,
/// once through SeaBIOS's IRQ1 handler during a disk thunk).
/// docs/design/bios-via-csmwrap.md.
pub var bios_keyboard_fallback: bool linksection(".data") = false;

fn pollKey() ?Key {
    const raw = core_poll_scancode();
    if (raw == no_scancode) {
        if (!bios_keyboard_fallback or core_scancode_count() != 0) return null;
        const bios_key = bios_poll_key();
        if (bios_key == no_scancode) return null;
        return biosKey(@truncate(bios_key >> 8));
    }
    if (raw & 0x100 != 0) {
        if (auxiliary.hook) |hook| return hook(@truncate(raw));
        return null;
    }
    return scan_decoder.feed(@truncate(raw));
}

/// INT 16h AH=00 returns the Set 1 make code in AH (0 or E0 in AL for the
/// grey keys), so the menu keys map through the same table.
fn biosKey(scan: u8) ?Key {
    return decodeSet1(scan, false);
}

fn isResponseLike(byte: u8) bool {
    return switch (byte) {
        0x00, 0xAA, 0xFA, 0xFC, 0xFE, 0xFF => true,
        else => false,
    };
}

fn decodeSet1(scan: u8, extended: bool) ?Key {
    return switch (scan) {
        0x01 => .{ .ascii = 27, .scan = scan },
        0x0E => .{ .ascii = 8, .scan = scan },
        0x1C => .{ .ascii = 13, .scan = scan },
        0x20 => if (!extended) .{ .ascii = 'd', .scan = scan } else null,
        0x48, 0x50, 0x4B, 0x4D => .{ .ascii = 0, .scan = scan },
        else => null,
    };
}

pub fn print(text: []const u8) void {
    for (text) |byte| put(byte);
}

pub fn put(byte: u8) void {
    if (screen_output) core_putc(byte) else core_serial_putc(byte);
}

pub fn line(text: []const u8) void {
    print(text);
    print("\r\n");
}

pub fn printU32(value: u32) void {
    var buffer: [10]u8 = undefined;
    var current = value;
    var count: usize = 0;
    if (current == 0) {
        put('0');
        return;
    }
    while (current != 0) {
        buffer[count] = '0' + @as(u8, @intCast(current % 10));
        count += 1;
        current /= 10;
    }
    while (count > 0) {
        count -= 1;
        put(buffer[count]);
    }
}

pub fn printHex8(value: u8) void {
    put(hexNibble(value >> 4));
    put(hexNibble(value & 0x0F));
}

pub fn printHex32(value: u32) void {
    var shift: u5 = 28;
    while (true) {
        put(hexNibble(@truncate((value >> shift) & 0x0F)));
        if (shift == 0) break;
        shift -= 4;
    }
}

pub fn printHex64(value: u64) void {
    printHex32(@truncate(value >> 32));
    printHex32(@truncate(value));
}

fn hexNibble(value: u8) u8 {
    return if (value < 10) '0' + value else 'A' + (value - 10);
}

test "set 1 decoder ignores break codes and typematic repeats until release" {
    const std = @import("std");
    var decoder: ScanDecoder = .{};

    const enter = decoder.feed(0x1C).?;
    try std.testing.expectEqual(@as(u8, 13), enter.ascii);
    try std.testing.expect(decoder.feed(0x1C) == null);
    try std.testing.expect(decoder.feed(0x1C) == null);
    try std.testing.expect(decoder.feed(0x9C) == null);
    try std.testing.expect(decoder.feed(0x1C) != null);
    try std.testing.expectEqual(@as(u8, 0x1C), decoder.last_accepted_scan);
}

test "set 1 decoder recovers when a prior break is lost" {
    const std = @import("std");
    var decoder: ScanDecoder = .{};

    const enter = decoder.feed(0x1C).?;
    try std.testing.expectEqual(@as(u8, 13), enter.ascii);
    try std.testing.expect(decoder.feed(0x1C) == null); // typematic repeat

    // Simulate the Enter break being swallowed during BIOS discovery. A new
    // valid make must still be accepted instead of deadlocking on held Enter.
    const down = decoder.feed(0x50).?;
    try std.testing.expectEqual(@as(u8, 0x50), down.scan);
    try std.testing.expect(decoder.feed(0x50) == null);
    try std.testing.expect(decoder.feed(0xD0) == null);

    const d = decoder.feed(0x20).?;
    try std.testing.expectEqual(@as(u8, 'd'), d.ascii);
}

test "response-like bytes never become menu events" {
    const std = @import("std");
    var decoder: ScanDecoder = .{};

    for ([_]u8{ 0x00, 0xFA, 0xFC, 0xFE, 0xFF, 0xAA }) |byte| {
        try std.testing.expect(decoder.feed(byte) == null);
    }
    try std.testing.expectEqual(@as(u32, 6), decoder.response_like_count);
    try std.testing.expectEqual(@as(u8, 0xAA), decoder.last_response_like);
    try std.testing.expectEqual(@as(u8, 6), decoder.raw_tail_len);
    try std.testing.expectEqual(@as(u8, 0x00), decoder.raw_tail[0]);
    try std.testing.expectEqual(@as(u8, 0xAA), decoder.raw_tail[5]);
}

test "E0 fake shift wrapper is ignored and repeated Down remains usable" {
    const std = @import("std");
    var decoder: ScanDecoder = .{};

    const sequence = [_]u8{ 0xE0, 0x2A, 0xE0, 0x50, 0xE0, 0xD0, 0xE0, 0xAA };
    var accepted: u8 = 0;
    for (sequence) |byte| {
        if (decoder.feed(byte)) |key| {
            try std.testing.expectEqual(@as(u8, 0x50), key.scan);
            accepted += 1;
        }
    }
    try std.testing.expectEqual(@as(u8, 1), accepted);
    try std.testing.expect(decoder.held_scan == null);
    try std.testing.expectEqual(@as(u32, 0), decoder.response_like_count);
    try std.testing.expectEqualSlices(u8, &sequence, &decoder.raw_tail);

    // A second complete translated Down sequence must generate another event;
    // E0 D0 released the key and E0 AA did not re-arm or poison held state.
    for (sequence) |byte| {
        if (decoder.feed(byte)) |key| {
            try std.testing.expectEqual(@as(u8, 0x50), key.scan);
            accepted += 1;
        }
    }
    try std.testing.expectEqual(@as(u8, 2), accepted);
    try std.testing.expect(decoder.held_scan == null);
    try std.testing.expectEqual(@as(u32, 0), decoder.response_like_count);

    // Only an unprefixed AA is eligible for response/BAT telemetry.
    try std.testing.expect(decoder.feed(0xAA) == null);
    try std.testing.expectEqual(@as(u32, 1), decoder.response_like_count);
    try std.testing.expectEqual(@as(u8, 0xAA), decoder.last_response_like);
}

test "set 1 decoder maps navigation keys to BIOS-style key fields" {
    const std = @import("std");
    var decoder: ScanDecoder = .{};

    const left = decoder.feed(0x4B).?;
    try std.testing.expectEqual(@as(u8, 0), left.ascii);
    try std.testing.expectEqual(@as(u8, 0x4B), left.scan);
    try std.testing.expect(decoder.feed(0xCB) == null);

    const escape = decoder.feed(0x01).?;
    try std.testing.expectEqual(@as(u8, 27), escape.ascii);
}
