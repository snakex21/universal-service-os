//! Reads DATA's usos-xp.ini for the XP answer-file screen and summary
//! (src/flow/xp_settings_summary.zig). Any read problem shows as "no
//! settings"; the micro-Linux staging still reads and validates the file.
const std = @import("std");
const uefi = std.os.uefi;
const usos = @import("usos");
const data_volume = @import("data_volume.zig");
const PathBuffer = @import("windows_native_iso.zig").PathBuffer;

const ntfs = usos.storage.ntfs;
const Summary = usos.flow.xp_settings_summary.Summary;

const State = struct {
    catalog: data_volume.Catalog,
    file: ntfs.File,
    bytes: [8192]u8,
};

/// Summary of `directory\name` (inactive when missing, empty or unreadable).
pub noinline fn read(directory: []const u8, name: []const u8) Summary {
    return readOrError(directory, name) catch .{};
}

fn readOrError(directory: []const u8, name: []const u8) !Summary {
    if (uefi.system_table.boot_services == null) return error.NoBootServices;
    const state = try uefi.pool_allocator.create(State);
    defer uefi.pool_allocator.destroy(state);
    // The reader points into state.catalog.block: keep state in place.
    state.catalog = try data_volume.openCatalog();
    var path: PathBuffer = .{};
    try ntfs.openFile(state.catalog.fs, state.catalog.reader(), try path.build(directory, name), &state.file);
    const size = state.file.size();
    if (size == 0 or size > state.bytes.len) return error.SettingsFileSize;
    const n: usize = @intCast(size);
    try state.file.readAt(state.catalog.fs, state.catalog.reader(), 0, state.bytes[0..n]);
    return usos.flow.xp_settings_summary.parse(state.bytes[0..n]);
}
