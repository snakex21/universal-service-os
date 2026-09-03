const std = @import("std");

pub const ExecutableKind = enum {
    com,
    mz,

    pub fn detect(bytes: []const u8) ExecutableKind {
        if (bytes.len >= 2) {
            const signature = std.mem.readInt(u16, bytes[0..2], .little);
            if (signature == 0x5A4D or signature == 0x4D5A) return .mz;
        }
        return .com;
    }
};

test "MZ and old ZM signatures are treated as DOS executables" {
    try std.testing.expectEqual(ExecutableKind.mz, ExecutableKind.detect(&.{ 'M', 'Z', 0, 0 }));
    try std.testing.expectEqual(ExecutableKind.mz, ExecutableKind.detect(&.{ 'Z', 'M', 0, 0 }));
    try std.testing.expectEqual(ExecutableKind.com, ExecutableKind.detect(&.{ 0x90, 0x90 }));
}
