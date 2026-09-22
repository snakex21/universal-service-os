const std = @import("std");

pub const setup_staging: u32 = 0x200000;
pub const setup_runtime: u32 = 0x90000;
pub const setup_size: u32 = 2560;
pub const command_address: u32 = 0x202000;

pub fn validateMarker(marker: *const [512]u8, guid: *const [36]u8) !void {
    if (!std.mem.startsWith(u8, marker, "ready=1\nwork_partuuid=") or
        !std.mem.eql(u8, marker[22..58], guid) or marker[58] != '\n') return error.InvalidReadyIdentity;
    for (marker[59..]) |byte| if (byte != 0) return error.InvalidReadyPadding;
}

test "Windows one-shot rejects another WORK partition, consumed state and trailing data" {
    var marker = [_]u8{0} ** 512;
    const guid = "12345678-1234-1234-1234-123456789abc";
    const text = "ready=1\nwork_partuuid=" ++ guid ++ "\n";
    @memcpy(marker[0..text.len], text);
    try validateMarker(&marker, guid);
    marker[22] = '0';
    try std.testing.expectError(error.InvalidReadyIdentity, validateMarker(&marker, guid));
    marker[22] = '1'; marker[6] = '0';
    try std.testing.expectError(error.InvalidReadyIdentity, validateMarker(&marker, guid));
    marker[6] = '1'; marker[511] = 1;
    try std.testing.expectError(error.InvalidReadyPadding, validateMarker(&marker, guid));
}

test "wimboot setup stays clear of the active BIOS Core stack and payload" {
    // Regression: loading setup straight at 0x90000 corrupted active stack
    // frames, causing InvalidCluster during otherwise valid FAT32 reads.
    try std.testing.expect(setup_staging >= 0x100000 + 76064);
    try std.testing.expect(command_address >= setup_staging + setup_size);
    try std.testing.expect(setup_runtime + setup_size < 0x9e000);
}
