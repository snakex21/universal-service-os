//! IA32 COFF compiler ABI glue. Zig 0.16 exports the MSVC division helpers
//! only for os=windows, although LLVM also requests them for os=uefi.
//! Calling convention/symbol spelling checked against the bundled Zig
//! compiler_rt/aulldiv.zig. Arithmetic below is an own bitwise implementation;
//! no division expression can recursively call the helper being provided.
const std = @import("std");
const builtin = @import("builtin");

const Result = struct { quotient: u64, remainder: u64 };
fn divide(a: u64, b: u64) Result {
    if (b == 0) @trap();
    const a_low: u32 = @truncate(a);
    const a_high: u32 = @truncate(a >> 32);
    const b_low: u32 = @truncate(b);
    const b_high: u32 = @truncate(b >> 32);
    var q_low: u32 = 0;
    var q_high: u32 = 0;
    var r_low: u32 = 0;
    var r_high: u32 = 0;
    var bit: usize = 64;
    while (bit != 0) {
        bit -= 1;
        const next = if (bit >= 32) (a_high >> @as(u5, @intCast(bit - 32))) & 1 else (a_low >> @as(u5, @intCast(bit))) & 1;
        const overflow = r_high >> 31;
        r_high = (r_high << 1) | (r_low >> 31);
        r_low = (r_low << 1) | next;
        q_high = (q_high << 1) | (q_low >> 31);
        q_low <<= 1;
        if (overflow != 0 or r_high > b_high or (r_high == b_high and r_low >= b_low)) {
            const borrow: u32 = @intFromBool(r_low < b_low);
            r_low -%= b_low;
            r_high = r_high -% b_high -% borrow;
            q_low |= 1;
        }
    }
    return .{ .quotient = (@as(u64, q_high) << 32) | q_low, .remainder = (@as(u64, r_high) << 32) | r_low };
}

fn div64(a: u64, b: u64) callconv(.{ .x86_stdcall = .{} }) u64 { return divide(a, b).quotient; }
fn rem64(a: u64, b: u64) callconv(.{ .x86_stdcall = .{} }) u64 { return divide(a, b).remainder; }
comptime {
    if (builtin.cpu.arch == .x86 and builtin.os.tag == .uefi) {
        @export(&div64, .{ .name = "\x01__aulldiv" });
        @export(&rem64, .{ .name = "\x01__aullrem" });
    }
}

test "IA32 ABI division arithmetic across full u64 range" {
    const values = [_]u64{ 0, 1, 2, 10, 0xffffffff, 0x100000000, 0x100000001, 0x7fffffffffffffff, 0x8000000000000000, 0xfffffffffffffffe, 0xffffffffffffffff };
    for (values) |a| for (values[1..]) |b| {
        const result = divide(a, b);
        try std.testing.expectEqual(a / b, result.quotient);
        try std.testing.expectEqual(a % b, result.remainder);
    };
}
