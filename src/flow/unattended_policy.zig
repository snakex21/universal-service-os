const std = @import("std");
const SystemEntry = @import("../catalog/system_entry.zig").SystemEntry;

const os_profiles = @import("../catalog/os_profiles.zig");

/// Answer-file extension the selection screen lists (profile traits).
pub fn extension(system: *const SystemEntry) []const u8 {
    return os_profiles.traits(system.id).answer.extension();
}

pub fn fileKindLabel(system: *const SystemEntry) []const u8 {
    return os_profiles.traits(system.id).answer.fileKindLabel();
}

test "Windows XP uses SIF while modern Windows keeps XML" {
    const systems = @import("../catalog/systems.zig");
    const xp = systems.findById("windows-xp").?;
    const windows11 = systems.findById("windows-11").?;
    try std.testing.expectEqualStrings(".sif", extension(xp));
    try std.testing.expectEqualStrings("WINNT.SIF", fileKindLabel(xp));
    const win2k = systems.findById("windows-2000").?;
    try std.testing.expectEqualStrings(".sif", extension(win2k));
    try std.testing.expectEqualStrings("WINNT.SIF", fileKindLabel(win2k));
    try std.testing.expectEqualStrings(".xml", extension(windows11));
    try std.testing.expectEqualStrings("unattend.xml", fileKindLabel(windows11));
}
