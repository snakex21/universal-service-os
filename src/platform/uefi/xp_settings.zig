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

/// DATA's usos-xp.ini mapped into an answer profile (profile.importXpIni);
/// null when missing, inactive or invalid.
pub noinline fn importProfile(directory: []const u8, name: []const u8, out: *usos.flow.answer.Profile) ?void {
    return importOrError(directory, name, out) catch null;
}

fn importOrError(directory: []const u8, name: []const u8, out: *usos.flow.answer.Profile) !?void {
    if (uefi.system_table.boot_services == null) return error.NoBootServices;
    const state = try uefi.pool_allocator.create(State);
    defer uefi.pool_allocator.destroy(state);
    state.catalog = try data_volume.openCatalog();
    var path: PathBuffer = .{};
    try ntfs.openFile(state.catalog.fs, state.catalog.reader(), try path.build(directory, name), &state.file);
    const size = state.file.size();
    if (size == 0 or size > state.bytes.len) return error.SettingsFileSize;
    const n: usize = @intCast(size);
    try state.file.readAt(state.catalog.fs, state.catalog.reader(), 0, state.bytes[0..n]);
    const result = usos.flow.answer.profile.importXpIni(state.bytes[0..n], out) orelse return null;
    return switch (result) {
        .ok => {},
        .invalid => null,
    };
}

/// An answer file in `directory` whose components are all for another
/// architecture than `media` (usos.flow.answer.xml_check.mismatch): Setup
/// ignores it without a word, so the summary warns. False when unreadable.
pub noinline fn answerArchMismatch(directory: []const u8, name: []const u8, media: usos.flow.answer.Arch) bool {
    return archMismatchOrError(directory, name, media) catch false;
}

fn archMismatchOrError(directory: []const u8, name: []const u8, media: usos.flow.answer.Arch) !bool {
    const bs = uefi.system_table.boot_services orelse return error.NoBootServices;
    const state = try uefi.pool_allocator.create(State);
    defer uefi.pool_allocator.destroy(state);
    state.catalog = try data_volume.openCatalog();
    var path: PathBuffer = .{};
    try ntfs.openFile(state.catalog.fs, state.catalog.reader(), try path.build(directory, name), &state.file);
    const size = state.file.size();
    if (size == 0 or size > 1024 * 1024) return error.AnswerFileSize;
    const bytes = try bs.allocatePool(.boot_services_data, @intCast(size));
    defer bs.freePool(bytes.ptr) catch {};
    try state.file.readAt(state.catalog.fs, state.catalog.reader(), 0, bytes);
    return usos.flow.answer.xml_check.mismatch(bytes, media);
}
