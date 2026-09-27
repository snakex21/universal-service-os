const std = @import("std");
const Category = @import("category.zig").Category;
const SystemEntry = @import("system_entry.zig").SystemEntry;
const windows_modern = @import("windows_modern.zig");
const windows_legacy = @import("windows_legacy.zig");
const windows_server = @import("windows_server.zig");
const linux_systems = @import("linux_systems.zig");
const windows_betas = @import("windows_betas.zig");
const dos_systems = @import("dos_systems.zig");

pub const all = windows_modern.entries ++
    windows_legacy.entries ++
    windows_server.entries ++
    linux_systems.entries ++
    windows_betas.entries ++
    dos_systems.entries;

pub fn findById(id: []const u8) ?*const SystemEntry {
    for (&all) |*entry| {
        if (std.mem.eql(u8, entry.id, id)) return entry;
    }
    return null;
}

pub fn countInCategory(category: Category) usize {
    var count: usize = 0;
    for (all) |entry| {
        if (entry.category == category) count += 1;
    }
    return count;
}

pub fn byCategoryIndex(category: Category, wanted: usize) ?*const SystemEntry {
    var found: usize = 0;
    for (&all) |*entry| {
        if (entry.category != category) continue;
        if (found == wanted) return entry;
        found += 1;
    }
    return null;
}

test {
    _ = windows_server;
}

test "Windows Server is its own section after the client versions" {
    var seen_server = false;
    var index: usize = 0;
    while (byCategoryIndex(.windows, index)) |entry| : (index += 1) {
        if (seen_server) try std.testing.expect(entry.server);
        seen_server = seen_server or entry.server;
    }
    try std.testing.expect(seen_server);
    try std.testing.expectEqualStrings("windows-server-2025", findById("windows-server-2025").?.id);
    // Server 2003 (NT5 staging) is the last Server entry.
    try std.testing.expect(findById("windows-server-2003").?.server);
}

test "built-in system catalog contains fixed operating-system profiles" {
    try std.testing.expect(findById("windows-11") != null);
    try std.testing.expect(findById("ubuntu") != null);
    try std.testing.expect(findById("windows-longhorn") != null);
    try std.testing.expect(findById("ms-dos") != null);
    try std.testing.expectEqual(@as(usize, 0), countInCategory(.utilities));
}

test "category lookup stays isolated" {
    try std.testing.expect(countInCategory(.windows) > 0);
    try std.testing.expect(countInCategory(.linux) > 0);
    try std.testing.expectEqual(Category.linux, byCategoryIndex(.linux, 0).?.category);
}

test "legacy catalog exposes firmware requirements to the view model" {
    try std.testing.expectEqual(@import("firmware_requirement.zig").FirmwareRequirement.any, findById("windows-xp").?.firmware);
    try std.testing.expectEqual(@import("firmware_requirement.zig").FirmwareRequirement.bios, findById("ms-dos").?.firmware);
    try std.testing.expectEqual(@import("firmware_requirement.zig").FirmwareRequirement.any, findById("windows-11").?.firmware);
}

test "built-in entry ids are unique" {
    for (all, 0..) |entry, index| {
        for (all[index + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, entry.id, other.id));
        }
    }
}
