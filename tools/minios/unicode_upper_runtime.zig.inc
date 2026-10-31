// SPDX-License-Identifier: GPL-2.0-or-later
// Representation-only compression of the already pinned mappings above.
// No new Unicode rules: the plain pairs remain the independent test oracle.
const compact_pairs = blk: {
    @setEvalBranchQuota(1000000);
    var bytes: [pairs.len * 5]u8 = undefined;
    var at: usize = 0;
    var used: usize = 0;
    while (at < pairs.len) {
        const from = pairs[at] >> 16;
        const to = pairs[at] & 65535;
        var count: usize = 1;
        var step: u32 = 1;
        for ([_]u32{ 1, 2 }) |stride| {
            var n: usize = 1;
            while (at + n < pairs.len and n < 128) : (n += 1) {
                const delta = @as(u32, @intCast(n)) * stride;
                if (pairs[at + n] >> 16 != from + delta or pairs[at + n] & 65535 != to + delta) break;
            }
            if (n > count) {
                count = n;
                step = stride;
            }
        }
        bytes[used] = @truncate(from);
        bytes[used + 1] = @truncate(from >> 8);
        bytes[used + 2] = @truncate(to);
        bytes[used + 3] = @truncate(to >> 8);
        bytes[used + 4] = @as(u8, @intCast(count - 1)) | (if (step == 2) @as(u8, 128) else 0);
        used += 5;
        at += count;
    }
    break :blk bytes[0..used].*;
};
inline fn compactWord(at: usize) u16 {
    return @as(u16, compact_pairs[at]) | @as(u16, compact_pairs[at + 1]) << 8;
}
/// Bounded lookup over losslessly packed runs; no full table allocation.
pub fn upperUnit(unit: u16) u16 {
    var low: usize = 0;
    var high: usize = compact_pairs.len / 5;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (compactWord(mid * 5) <= unit) low = mid + 1 else high = mid;
    }
    if (low == 0) return unit;
    const at = (low - 1) * 5;
    const delta = unit - compactWord(at);
    const control = compact_pairs[at + 4];
    const shift: u4 = @intCast(control >> 7);
    if (delta > @as(u16, control & 127) << shift or delta & @as(u16, control >> 7) != 0) return unit;
    return compactWord(at + 2) + delta;
}
pub fn build(table: []u16) void {
    const std = @import("std");
    std.debug.assert(table.len == 65536);
    for (table, 0..) |*value, i| value.* = @intCast(i);
    for (0..compact_pairs.len / 5) |i| {
        const at = i * 5;
        var from: u32 = compactWord(at);
        var to: u32 = compactWord(at + 2);
        const control = compact_pairs[at + 4];
        const step: u32 = 1 + @as(u32, control >> 7);
        var n: u16 = 1 + @as(u16, control & 127);
        while (n != 0) : (n -= 1) {
            table[from] = @intCast(to);
            from += step;
            to += step;
        }
    }
}
test "packed mappings preserve every UTF16 unit and use670 bytes" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 670), compact_pairs.len);
    var plain: [65536]u16 = undefined;
    for (&plain, 0..) |*v, i| v.* = @intCast(i);
    for (pairs) |pair| plain[pair >> 16] = @truncate(pair);
    for (plain, 0..) |value, i| try std.testing.expectEqual(value, upperUnit(@intCast(i)));
}
