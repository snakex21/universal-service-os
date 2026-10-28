//! Read-only ACPI PM timer discovery and checked monotonic extension (i486).
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
pub const frequency: u64 = 3579545;
pub const Config = struct { port: u16, width: u6 };
pub const Reader = struct {
    context: *anyopaque,
    read_fn: *const fn (*anyopaque, u64, usize) anyerror![]const u8,
    fn read(self: Reader, at: u64, len: usize) ![]const u8 {
        if (at < 4096 or len == 0 or len > 65536 or at > std.math.maxInt(u32) - len) return error.Bounds;
        const b = try self.read_fn(self.context, at, len);
        if (b.len != len) return error.Bounds;
        return b;
    }
};
fn sum(bytes: []const u8) u8 { var v: u8 = 0; for (bytes) |b| v +%= b; return v; }
fn get(comptime T: type, b: []const u8, off: usize) T { return std.mem.readInt(T, b[off..][0..@sizeOf(T)], .little); }
fn table(reader: Reader, at: u64) ![]const u8 {
    const h = try reader.read(at, 36);
    const n = get(u32, h, 4);
    if (n < 36 or n > 65536) return error.Corrupt;
    const b = try reader.read(at, n);
    if (sum(b) != 0) return error.Corrupt;
    return b;
}
pub fn fromFadt(f: []const u8) !Config {
    if (f.len < 116 or !std.mem.eql(u8, f[0..4], "FACP") or get(u32, f, 4) != f.len or sum(f) != 0) return error.Corrupt;
    if (f.len >= 220 and f[208] == 1 and (f[209] == 24 or f[209] == 32) and f[210] == 0 and (f[211] == 0 or f[211] == 3)) {
        const port = get(u64, f, 212);
        if (port >= 256 and port <= 65532) return .{ .port = @intCast(port), .width = if (f[209] == 32 and get(u32, f, 112) & 0x100 != 0) 32 else 24 };
    }
    const port = get(u32, f, 76);
    if (f[91] != 4 or port < 256 or port > 65532) return error.Unsupported;
    return .{ .port = @intCast(port), .width = if (get(u32, f, 112) & 0x100 != 0) 32 else 24 };
}
pub fn discover(reader: Reader, rsdp: u64) !Config {
    const r = try reader.read(rsdp, 20);
    if (!std.mem.eql(u8, r[0..8], "RSD PTR ") or sum(r) != 0) return error.Corrupt;
    var root: u64 = get(u32, r, 16);
    var stride: usize = 4;
    if (r[15] >= 2) {
        const ext = try reader.read(rsdp, 36);
        const len = get(u32, ext, 20);
        if (len < 36 or len > 4096 or sum(try reader.read(rsdp, len)) != 0) return error.Corrupt;
        const x = get(u64, ext, 24);
        if (x != 0) { root = x; stride = 8; }
    }
    const t = try table(reader, root);
    if (!std.mem.eql(u8, t[0..4], if (stride == 8) "XSDT" else "RSDT") or (t.len - 36) % stride != 0 or (t.len - 36) / stride > 256) return error.Corrupt;
    var off: usize = 36;
    while (off < t.len) : (off += stride) {
        const at = if (stride == 8) get(u64, t, off) else get(u32, t, off);
        const h = try reader.read(at, 36);
        if (std.mem.eql(u8, h[0..4], "FACP")) return fromFadt(try table(reader, at));
    }
    return error.Unsupported;
}

/// read() extends only adjacent modular samples. The coarse clock is checked
/// at every progress snapshot: a lost complete24-bit wrap differs by4.687s,
/// exceeding the2s tolerance for two independently quantized RTC readings.
/// Ambiguous time, clock reversal or a stalled timer invalidates measurements;
/// unavailable time must never be reported as measured zero seconds.
pub const Counter = struct {
    context: *anyopaque,
    raw_fn: *const fn (*anyopaque) u32,
    width: u6,
    coarse_start: u64,
    previous: u32,
    ticks: u64 = 0,
    valid: bool = true,
    pub fn init(context: *anyopaque, raw: *const fn (*anyopaque) u32, width: u6, coarse: u64) Counter {
        return .{ .context = context, .raw_fn = raw, .width = width, .coarse_start = coarse, .previous = raw(context), .valid = width == 24 or width == 32 };
    }
    pub fn read(self: *Counter) ?u64 {
        if (!self.valid) return null;
        const mask: u32 = if (self.width == 24) 0xffffff else 0xffffffff;
        const now = self.raw_fn(self.context) & mask;
        self.ticks = std.math.add(u64, self.ticks, (now -% self.previous) & mask) catch { self.valid = false; return null; };
        self.previous = now;
        return self.ticks;
    }
    pub fn validate(self: *Counter, coarse_: ?u64) void {
        const coarse = coarse_ orelse { self.valid = false; return; };
        _ = self.read();
        if (!self.valid or coarse < self.coarse_start) { self.valid = false; return; }
        const wall = coarse - self.coarse_start;
        const measured = self.ticks / frequency;
        if (wall -| measured > 2 or measured -| wall > 2) self.valid = false;
    }
};

test "PM timer wraps, missed wraps and stalled or reversed clocks are explicit" {
    const Fake = struct { value: u32, fn read(ctx: *anyopaque) u32 { return @as(*@This(), @ptrCast(@alignCast(ctx))).value; } };
    var raw: Fake = .{ .value = 0xfffff0 };
    var c = Counter.init(&raw, Fake.read, 24, 100);
    raw.value = 0x10;
    try std.testing.expectEqual(@as(?u64, 32), c.read());
    c.validate(100);
    try std.testing.expect(c.valid);
    c.validate(105); // modulo value alone cannot prove a full lost wrap.
    try std.testing.expect(!c.valid);
    try std.testing.expectEqual(@as(?u64, null), c.read());
    c = Counter.init(&raw, Fake.read, 32, 100);
    c.validate(99);
    try std.testing.expect(!c.valid);
    c = Counter.init(&raw, Fake.read, 24, 100);
    c.validate(103);
    try std.testing.expect(!c.valid);
    c = Counter.init(&raw, Fake.read, 24, 0);
    c.validate(null);
    try std.testing.expect(!c.valid);
}
test "FADT selects read-only IO timer and rejects corrupt or invalid descriptors" {
    var f: [276]u8 = @splat(0);
    @memcpy(f[0..4], "FACP");
    std.mem.writeInt(u32, f[4..8], f.len, .little);
    std.mem.writeInt(u32, f[76..80], 0x808, .little); f[91] = 4;
    f[9] -%= sum(&f);
    try std.testing.expectEqualDeep(Config{ .port = 0x808, .width = 24 }, try fromFadt(&f));
    f[112] = 0; f[113] = 1; f[9] -%= sum(&f);
    try std.testing.expectEqual(@as(u6, 32), (try fromFadt(&f)).width);
    f[76] = 1;
    try std.testing.expectError(error.Corrupt, fromFadt(&f));
    f[76] = 0; f[91] = 0; f[9] -%= sum(&f);
    try std.testing.expectError(error.Unsupported, fromFadt(&f));
}
test "bounded root discovery checks lengths checksums and self-referencing entries" {
    const Fake = struct {
        bytes: [1024]u8 = @splat(0),
        fn read(ctx: *anyopaque, at: u64, len: usize) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (at < 4096 or at - 4096 > self.bytes.len or len > self.bytes.len - (at - 4096)) return error.Bounds;
            return self.bytes[@intCast(at - 4096)..][0..len];
        }
    };
    var memory: Fake = .{};
    const r = memory.bytes[0..20];
    @memcpy(r[0..8], "RSD PTR ");
    std.mem.writeInt(u32, r[16..20], 0x1100, .little); r[8] -%= sum(r);
    const t = memory.bytes[256..][0..40];
    @memcpy(t[0..4], "RSDT"); std.mem.writeInt(u32, t[4..8], 40, .little);
    std.mem.writeInt(u32, t[36..40], 0x1200, .little); t[9] -%= sum(t);
    const f = memory.bytes[512..][0..116];
    @memcpy(f[0..4], "FACP"); std.mem.writeInt(u32, f[4..8], 116, .little);
    std.mem.writeInt(u32, f[76..80], 0x608, .little); f[91] = 4; f[9] -%= sum(f);
    const reader: Reader = .{ .context = &memory, .read_fn = Fake.read };
    try std.testing.expectEqualDeep(Config{ .port = 0x608, .width = 24 }, try discover(reader, 0x1000));
    std.mem.writeInt(u32, t[36..40], 0x1100, .little); t[9] -%= sum(t);
    try std.testing.expectError(error.Unsupported, discover(reader, 0x1000));
    t[9] +%= 1;
    try std.testing.expectError(error.Corrupt, discover(reader, 0x1000));
    try std.testing.expectError(error.Bounds, discover(reader, 0x100000000));
}
