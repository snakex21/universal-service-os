//! QEMU x86 fw_cfg PIO: https://www.qemu.org/docs/master/specs/fw_cfg.html
//! Host CSPRNG supplies a64-byte file. No RDRAND/time/target-marker fallback.
const std = @import("std");
pub const filename = "opt/usosprep-entropy";
pub const Reader = struct {
    context: *anyopaque,
    select_fn: *const fn (*anyopaque, u16) void,
    read_fn: *const fn (*anyopaque) u8,
    fn select(self: Reader, key: u16) void {
        self.select_fn(self.context, key);
    }
    fn read(self: Reader, out: []u8) void {
        for (out) |*byte| byte.* = self.read_fn(self.context);
    }
};
pub fn readEntropy(reader: Reader) error{EntropyUnavailable}![64]u8 {
    reader.select(0);
    var signature: [4]u8 = undefined;
    reader.read(&signature);
    if (!std.mem.eql(u8, &signature, "QEMU")) return error.EntropyUnavailable;
    reader.select(0x19);
    var count_bytes: [4]u8 = undefined;
    reader.read(&count_bytes);
    const count = std.mem.readInt(u32, &count_bytes, .big);
    if (count == 0 or count > 4096) return error.EntropyUnavailable;
    var found: ?u16 = null;
    for (0..count) |_| {
        var entry: [64]u8 = undefined;
        reader.read(&entry);
        const end = std.mem.indexOfScalar(u8, entry[8..64], 0) orelse return error.EntropyUnavailable;
        if (!std.mem.eql(u8, entry[8..][0..end], filename)) continue;
        const size = std.mem.readInt(u32, entry[0..4], .big);
        const selector = std.mem.readInt(u16, entry[4..6], .big);
        if (found != null or size != 64 or selector < 0x20 or selector >= 0x4000 or entry[6] != 0 or entry[7] != 0) return error.EntropyUnavailable;
        found = selector;
    }
    reader.select(found orelse return error.EntropyUnavailable);
    var entropy: [64]u8 = undefined;
    reader.read(&entropy);
    if (std.mem.allEqual(u8, &entropy, 0)) return error.EntropyUnavailable;
    return entropy;
}
fn portSelect(_: *anyopaque, value: u16) void {
    asm volatile ("outw %[value], %[port]"
        :
        : [value] "{ax}" (value),
          [port] "{dx}" (@as(u16, 0x510)),
    );
}
fn portRead(_: *anyopaque) u8 {
    return asm volatile ("inb %[port], %[value]"
        : [value] "={al}" (-> u8),
        : [port] "{dx}" (@as(u16, 0x511)),
    );
}
pub fn firmwareEntropy(qemu_detected: bool) error{EntropyUnavailable}![64]u8 {
    if (!qemu_detected) return error.EntropyUnavailable;
    var context: u8 = 0;
    return readEntropy(.{ .context = &context, .select_fn = portSelect, .read_fn = portRead });
}
test "fw_cfg reads BE directory/selector and rejects missing or wrong-size entropy" {
    const Fake = struct {
        directory: [68]u8 = @splat(0),
        selected: u16 = 0,
        offset: usize = 0,
        fn select(ctx: *anyopaque, key: u16) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.selected = key;
            s.offset = 0;
        }
        fn read(ctx: *anyopaque) u8 {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            defer s.offset += 1;
            return switch (s.selected) {
                0 => "QEMU"[s.offset],
                0x19 => s.directory[s.offset],
                0x27 => @intCast(s.offset + 1),
                else => 0,
            };
        }
        fn reader(s: *@This()) Reader {
            return .{ .context = s, .select_fn = select, .read_fn = read };
        }
    };
    var fake: Fake = .{};
    try std.testing.expectError(error.EntropyUnavailable, readEntropy(fake.reader()));
    std.mem.writeInt(u32, fake.directory[0..4], 1, .big);
    std.mem.writeInt(u32, fake.directory[4..8], 64, .big);
    std.mem.writeInt(u16, fake.directory[8..10], 0x27, .big);
    @memcpy(fake.directory[12..][0..filename.len], filename);
    const entropy = try readEntropy(fake.reader());
    try std.testing.expectEqual(@as(u8, 1), entropy[0]);
    try std.testing.expectEqual(@as(u8, 64), entropy[63]);
    fake.directory[7] = 63;
    try std.testing.expectError(error.EntropyUnavailable, readEntropy(fake.reader()));
}
