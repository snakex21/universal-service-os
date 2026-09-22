const std = @import("std");
const SystemEntry = @import("../catalog/system_entry.zig").SystemEntry;

pub fn extension(system: *const SystemEntry) []const u8 {
    if (std.mem.eql(u8, system.id, "windows-xp") or std.mem.eql(u8, system.id, "windows-2000")) return ".sif";
    return ".xml";
}

pub fn fileKindLabel(system: *const SystemEntry) []const u8 {
    if (std.mem.eql(u8, extension(system), ".sif")) return "WINNT.SIF";
    return "unattend.xml";
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
