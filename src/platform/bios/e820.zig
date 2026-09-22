const std = @import("std");
const console = @import("console.zig");

pub const max_entries: usize = 128;
const failure: u32 = 0xFFFFFFFF;

pub const Entry = extern struct {
    base: u64,
    length: u64,
    kind: u32,
    attributes: u32,

    pub fn end(self: Entry) ?u64 {
        const result = @addWithOverflow(self.base, self.length);
        return if (result[1] == 0) result[0] else null;
    }

    pub fn isUsable(self: Entry) bool {
        return self.kind == 1 and self.length != 0 and self.end() != null;
    }
};

comptime {
    if (@sizeOf(Entry) != 24) @compileError("E820 entry ABI must be exactly 24 bytes");
}

pub const Error = error{
    BiosFailure,
    EmptyMap,
    InvalidCount,
};

extern fn bios_e820_probe(destination: [*]Entry) callconv(.c) u32;
extern fn core_e820_stage() callconv(.c) u32;
extern fn core_e820_last_eax() callconv(.c) u32;
extern fn core_e820_last_ecx() callconv(.c) u32;
extern fn core_e820_last_ebx() callconv(.c) u32;

pub fn probe(entries: *[max_entries]Entry) Error!usize {
    const count = bios_e820_probe(entries[0..].ptr);
    if (count == failure) return error.BiosFailure;
    if (count == 0) return error.EmptyMap;
    if (count > max_entries) return error.InvalidCount;
    return @intCast(count);
}

pub fn dump() void {
    var entries: [max_entries]Entry = undefined;
    const count = probe(&entries) catch |err| {
        console.print("E820 FAIL error=");
        console.print(@errorName(err));
        console.print(" stage=");
        console.printU32(core_e820_stage());
        console.print(" eax=0x");
        console.printHex32(core_e820_last_eax());
        console.print(" ecx=0x");
        console.printHex32(core_e820_last_ecx());
        console.print(" ebx=0x");
        console.printHex32(core_e820_last_ebx());
        console.line("");
        return;
    };

    dumpEntries(entries[0..count]);
}

pub fn dumpEntries(entries: []const Entry) void {
    console.print("E820 OK entries=");
    console.printU32(@intCast(entries.len));
    console.line("");
    for (entries, 0..) |entry, index| {
        console.print("E820[");
        console.printU32(@intCast(index));
        console.print("] base=0x");
        console.printHex64(entry.base);
        console.print(" length=0x");
        console.printHex64(entry.length);
        console.print(" type=");
        console.printU32(entry.kind);
        console.print(" attrs=0x");
        console.printHex32(entry.attributes);
        console.line("");
    }
}

test "E820 usable range and overflow handling" {
    const usable = Entry{ .base = 0x00100000, .length = 0x3FF00000, .kind = 1, .attributes = 1 };
    try std.testing.expect(usable.isUsable());
    try std.testing.expectEqual(@as(?u64, 0x40000000), usable.end());

    const reserved = Entry{ .base = 0x000A0000, .length = 0x00060000, .kind = 2, .attributes = 1 };
    try std.testing.expect(!reserved.isUsable());

    const overflow = Entry{ .base = std.math.maxInt(u64) - 7, .length = 16, .kind = 1, .attributes = 1 };
    try std.testing.expect(overflow.end() == null);
    try std.testing.expect(!overflow.isUsable());
}
