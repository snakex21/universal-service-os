const std = @import("std");
const uefi = std.os.uefi;
const usos = @import("usos");

const state_path = std.unicode.utf8ToUtf16LeStringLiteral("\\EFI\\USOS\\install-state.ini");
pub const max_state_bytes = 2048;

pub const Selection = struct {
    phase: usos.flow.persistent_phase.Phase,
    selected_iso: ?[]const u8 = null,
    selected_unattend: ?[]const u8 = null,
    selected_method: ?[]const u8 = null,
};

pub fn read(root: *uefi.protocol.File, storage: *[max_state_bytes]u8) !Selection {
    const file = try root.open(state_path, .read, .{});
    defer file.close() catch {};
    const used = try file.read(storage);
    const bytes = storage[0..used];
    const phase_text = value(bytes, "phase") orelse return error.PhaseMissing;
    return .{
        .phase = try usos.flow.persistent_phase.parse(phase_text),
        .selected_iso = value(bytes, "selected_iso"),
        .selected_unattend = value(bytes, "selected_unattend"),
        .selected_method = value(bytes, "selected_method"),
    };
}

pub fn write(
    root: *uefi.protocol.File,
    phase: usos.flow.persistent_phase.Phase,
    selected_iso: ?[]const u8,
    selected_unattend: ?[]const u8,
    selected_method: ?[]const u8,
    /// Catalog system id (e.g. "windows-10"); micro-Linux's extract.sh takes
    /// the DATA\Drivers folder from it (docs/drivers.md).
    selected_system: ?[]const u8,
    /// `plan_*` lines from usos.flow.plan.Plan.stateKeys (CRLF-terminated).
    plan_keys: ?[]const u8,
) !void {
    var storage: [max_state_bytes]u8 = @splat('\n');
    var used: usize = 0;
    try append(&storage, &used, "phase=");
    try append(&storage, &used, phase.value());
    try append(&storage, &used, "\r\n");
    if (selected_iso) |path| {
        try append(&storage, &used, "selected_iso=");
        try append(&storage, &used, path);
        try append(&storage, &used, "\r\n");
    }
    if (selected_unattend) |path| {
        try append(&storage, &used, "selected_unattend=");
        try append(&storage, &used, path);
        try append(&storage, &used, "\r\n");
    } else {
        try append(&storage, &used, "selected_unattend=none\r\n");
    }
    if (selected_method) |method| {
        try append(&storage, &used, "selected_method=");
        try append(&storage, &used, method);
        try append(&storage, &used, "\r\n");
    }
    if (selected_system) |id| {
        try append(&storage, &used, "selected_system=");
        try append(&storage, &used, id);
        try append(&storage, &used, "\r\n");
    }
    if (plan_keys) |keys| try append(&storage, &used, keys);

    const file = try root.open(state_path, .read_write_create, .{});
    defer file.close() catch {};
    try file.setPosition(0);
    const written = try file.write(&storage);
    if (written != storage.len) return error.ShortWrite;
    try file.flush();
}

fn value(bytes: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\x00");
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..equals], " \t"), key)) continue;
        return std.mem.trim(u8, line[equals + 1 ..], " \t\r\x00");
    }
    return null;
}

fn append(storage: *[max_state_bytes]u8, used: *usize, text: []const u8) !void {
    if (used.* + text.len > storage.len) return error.StateTooLarge;
    @memcpy(storage[used.* .. used.* + text.len], text);
    used.* += text.len;
}

