//! Platform-CSPRNG disk identities. Never use time, disk size or target marker.
const std = @import("std");
pub const Identifiers = struct {
    disk_guid: [16]u8,
    partition_guid: [16]u8,
    mbr_signature: u32,
    ntfs_serial: u64,
    pub fn fromEntropy(entropy: [64]u8) error{EntropyUnavailable}!Identifiers {
        // Detect absent/zero-filled fw_cfg; not an entropy estimator. The
        // platform must supply all64bytes from a cryptographic OS RNG.
        if (std.mem.allEqual(u8, entropy[0..16], 0) or std.mem.allEqual(u8, entropy[16..32], 0)) return error.EntropyUnavailable;
        var ids: Identifiers = .{
            .disk_guid = entropy[0..16].*, .partition_guid = entropy[16..32].*,
            .mbr_signature = std.mem.readInt(u32, entropy[32..36], .little),
            .ntfs_serial = std.mem.readInt(u64, entropy[36..44], .little),
        };
        // GPT's first three GUID fields are little-endian; version at byte7.
        for ([_]*[16]u8{ &ids.disk_guid, &ids.partition_guid }) |guid| {
            guid[7] = (guid[7] & 0x0f) | 0x40;
            guid[8] = (guid[8] & 0x3f) | 0x80;
        }
        ids.validate() catch return error.EntropyUnavailable;
        return ids;
    }
    pub fn validate(self: Identifiers) error{InvalidArgument}!void {
        if (self.mbr_signature == 0 or self.ntfs_serial == 0 or std.mem.eql(u8, &self.disk_guid, &self.partition_guid)) return error.InvalidArgument;
        for ([_][16]u8{ self.disk_guid, self.partition_guid }) |guid| {
            if (guid[7] >> 4 != 4 or guid[8] >> 6 != 2) return error.InvalidArgument;
        }
    }
};
test "identities preserve independent random fields and reject missing entropy" {
    var entropy: [64]u8 = undefined;
    for (&entropy, 0..) |*byte, i| byte.* = @intCast(i + 1);
    const first = try Identifiers.fromEntropy(entropy);
    try first.validate();
    try std.testing.expectEqual(@as(u32, 0x24232221), first.mbr_signature);
    try std.testing.expectEqual(@as(u64, 0x2c2b2a2928272625), first.ntfs_serial);
    try std.testing.expectEqualSlices(u8, entropy[0..7], first.disk_guid[0..7]);
    try std.testing.expectError(error.EntropyUnavailable, Identifiers.fromEntropy(@splat(0)));
    entropy[0] ^= 0x80; entropy[16] ^= 0x80; entropy[32] ^= 0x80; entropy[36] ^= 0x80;
    const next = try Identifiers.fromEntropy(entropy);
    try std.testing.expect(!std.mem.eql(u8, &first.disk_guid, &next.disk_guid));
    try std.testing.expect(!std.mem.eql(u8, &first.partition_guid, &next.partition_guid));
    try std.testing.expect(first.mbr_signature != next.mbr_signature and first.ntfs_serial != next.ntfs_serial);
}
