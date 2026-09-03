const std = @import("std");
const Category = @import("category.zig").Category;
const SystemEntry = @import("system_entry.zig").SystemEntry;
const windows_modern = @import("windows_modern.zig");
const windows_legacy = @import("windows_legacy.zig");
const linux_systems = @import("linux_systems.zig");
const windows_betas = @import("windows_betas.zig");
const dos_systems = @import("dos_systems.zig");
const utility_entries = @import("utility_entries.zig");

pub const all = windows_modern.entries ++
    windows_legacy.entries ++
    linux_systems.entries ++
    windows_betas.entries ++
    dos_systems.entries ++
    utility_entries.entries;

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

test "built-in catalog contains every top-level category" {
    try std.testing.expect(findById("windows-11") != null);
    try std.testing.expect(findById("ubuntu") != null);
    try std.testing.expect(findById("windows-longhorn") != null);
    try std.testing.expect(findById("ms-dos") != null);
    try std.testing.expect(findById("memory-tests") != null);
}

test "category lookup stays isolated" {
    try std.testing.expect(countInCategory(.windows) > 0);
    try std.testing.expect(countInCategory(.linux) > 0);
    try std.testing.expectEqual(Category.linux, byCategoryIndex(.linux, 0).?.category);
}

test "built-in entry ids are unique" {
    for (all, 0..) |entry, index| {
        for (all[index + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, entry.id, other.id));
        }
    }
}
