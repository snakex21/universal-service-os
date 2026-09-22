// Read-only, RAM-backed filesystem consumed by wimboot's EFI entry point.
const std = @import("std");
const efi = std.os.uefi;
const File = efi.protocol.File;
const cc = efi.cc;
const Status = efi.Status;
const limit = 64;
pub const Entry = struct { name: []const u8, bytes: []const u8 };
const Open = struct { protocol: File = vtable, entry: ?usize = null, position: usize = 0, used: bool = false };
pub const Volume = struct {
    protocol: efi.protocol.SimpleFileSystem = .{ .revision = 0x10000, ._open_volume = openVolume },
    entries: [limit]Entry = undefined,
    count: usize = 0,
    handles: [limit + 4]Open = [_]Open{.{}} ** (limit + 4),

    pub fn add(self: *Volume, name: []const u8, bytes: []const u8) !void {
        if (self.count == limit or name.len == 0 or name.len > 63) return error.InvalidWimbootFile;
        for (self.entries[0..self.count]) |entry| if (std.ascii.eqlIgnoreCase(entry.name, name)) return error.DuplicateWimbootFile;
        self.entries[self.count] = .{ .name = name, .bytes = bytes };
        self.count += 1;
    }

    pub fn addCpio(self: *Volume, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            if (bytes.len - offset < 110 or !std.mem.eql(u8, bytes[offset..][0..6], "070701")) return error.InvalidSupportArchive;
            const n = try std.fmt.parseInt(usize, bytes[offset + 94 ..][0..8], 16);
            const size = try std.fmt.parseInt(usize, bytes[offset + 54 ..][0..8], 16);
            if (n < 2 or n > 64 or n > bytes.len - offset - 110) return error.InvalidSupportArchive;
            const name = bytes[offset + 110 ..][0 .. n - 1];
            if (bytes[offset + 110 + n - 1] != 0) return error.InvalidSupportArchive;
            const start = std.mem.alignForward(usize, offset + 110 + n, 4);
            if (start > bytes.len or size > bytes.len - start) return error.InvalidSupportArchive;
            if (std.mem.eql(u8, name, "TRAILER!!!")) return error.UnexpectedSupportTrailer;
            try self.add(name, bytes[start..][0..size]);
            offset = std.mem.alignForward(usize, start + size, 4);
        }
        if (offset != bytes.len) return error.InvalidSupportArchive;
    }
};
// Installed only for the duration of the synchronous child image call.
var current: ?*Volume = null;
pub fn install(volume: *Volume) !efi.Handle {
    if (current != null) return error.WimbootAlreadyActive;
    const bs = efi.system_table.boot_services orelse return error.NoBootServices;
    // The bundled Zig headers misdeclare the Handle* argument as Handle.
    // Preserve the firmware ABI without changing the shared toolchain.
    var handle: ?efi.Handle = null;
    const status = bs._installProtocolInterface(@ptrCast(&handle), &efi.protocol.SimpleFileSystem.guid, .native, &volume.protocol);
    if (status != .success) return error.WimbootFilesystemInstallFailed;
    current = volume;
    return handle orelse return error.WimbootFilesystemInstallFailed;
}
pub fn uninstall(handle: efi.Handle, volume: *Volume) void {
    const bs = efi.system_table.boot_services orelse return;
    if (bs._uninstallProtocolInterface(handle, &efi.protocol.SimpleFileSystem.guid, &volume.protocol) != .success) return;
    current = null;
}
fn allocate(entry: ?usize, result: **File) Status {
    const volume = current orelse return .device_error;
    for (&volume.handles) |*handle| if (!handle.used) {
        handle.* = .{ .used = true, .entry = entry };
        result.* = &handle.protocol;
        return .success;
    };
    return .out_of_resources;
}
fn opened(file: *const File) *Open { return @constCast(@as(*const Open, @fieldParentPtr("protocol", file))); }
fn openVolume(_: *const efi.protocol.SimpleFileSystem, result: **File) callconv(cc) Status { return allocate(null, result); }
fn open(file: *const File, result: **File, path: [*:0]const u16, mode: File.OpenMode, _: File.Attributes) callconv(cc) Status {
    if (mode != .read) return .write_protected;
    if (opened(file).entry != null) return .not_found;
    var name = std.mem.span(path);
    while (name.len > 0 and name[0] == '\\') name = name[1..];
    if (name.len == 0) return allocate(null, result);
    const volume = current orelse return .device_error;
    for (volume.entries[0..volume.count], 0..) |entry, i| {
        if (entry.name.len != name.len) continue;
        var equal = true;
        for (entry.name, name) |a, b| if (b > 127 or std.ascii.toLower(a) != std.ascii.toLower(@as(u8, @truncate(b)))) { equal = false; break; };
        if (equal) return allocate(i, result);
    }
    return .not_found;
}
fn close(file: *File) callconv(cc) Status { opened(file).used = false; return .success; }
fn delete(_: *File) callconv(cc) Status { return .write_protected; }
fn info(entry: ?Entry, length: *usize, buffer: ?[*]u8) Status {
    const name = if (entry) |e| e.name else "";
    const need = 80 + (name.len + 1) * 2;
    if (length.* < need or buffer == null) { length.* = need; return .buffer_too_small; }
    const out = buffer.?[0..need];
    @memset(out, 0);
    std.mem.writeInt(u64, out[0..8], need, .little);
    const size = if (entry) |e| e.bytes.len else 0;
    std.mem.writeInt(u64, out[8..16], size, .little);
    std.mem.writeInt(u64, out[16..24], size, .little);
    std.mem.writeInt(u64, out[72..80], if (entry == null) 0x11 else 1, .little);
    for (name, 0..) |ch, i| out[80 + i * 2] = ch;
    length.* = need;
    return .success;
}
fn read(file: *File, length: *usize, buffer: [*]u8) callconv(cc) Status {
    const volume = current orelse return .device_error;
    const handle = opened(file);
    if (handle.entry) |index| {
        const bytes = volume.entries[index].bytes;
        const amount = @min(length.*, bytes.len - @min(handle.position, bytes.len));
        @memcpy(buffer[0..amount], bytes[@min(handle.position, bytes.len)..][0..amount]);
        handle.position += amount; length.* = amount; return .success;
    }
    if (handle.position >= volume.count) { length.* = 0; return .success; }
    const status = info(volume.entries[handle.position], length, buffer);
    if (status == .success) handle.position += 1;
    return status;
}
fn write(_: *File, _: *usize, _: [*]const u8) callconv(cc) Status { return .write_protected; }
fn getPosition(file: *const File, out: *u64) callconv(cc) Status { out.* = opened(file).position; return .success; }
fn setPosition(file: *File, position: u64) callconv(cc) Status {
    const handle = opened(file);
    if (handle.entry == null and position != 0) return .unsupported;
    handle.position = if (position == std.math.maxInt(u64)) current.?.entries[handle.entry.?].bytes.len else @intCast(position);
    return .success;
}
fn getInfo(file: *const File, guid: *align(8) const efi.Guid, length: *usize, buffer: ?[*]u8) callconv(cc) Status {
    if (!std.mem.eql(u8, std.mem.asBytes(guid), std.mem.asBytes(&File.Info.File.guid))) return .unsupported;
    const entry = if (opened(file).entry) |index| current.?.entries[index] else null;
    return info(entry, length, buffer);
}
fn setInfo(_: *File, _: *align(8) const efi.Guid, _: usize, _: [*]const u8) callconv(cc) Status { return .write_protected; }
fn flush(_: *File) callconv(cc) Status { return .success; }
const vtable: File = .{ .revision = 0x10000, ._open = open, ._close = close, ._delete = delete, ._read = read, ._write = write, ._get_position = getPosition, ._set_position = setPosition, ._get_info = getInfo, ._set_info = setInfo, ._flush = flush };

test "wimboot enumerates then seeks an independent read-only file handle" {
    var volume = Volume{};
    try volume.add("boot.wim", "0123456789");
    current = &volume;
    defer current = null;
    const root = try volume.protocol.openVolume();
    defer root.close() catch {};
    var small: [4]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, root.read(&small));
    try std.testing.expectEqual(@as(u64, 0), try root.getPosition());
    var directory: [128]u8 align(8) = undefined;
    try std.testing.expectEqual(@as(usize, 98), try root.read(&directory));
    try std.testing.expectEqual(@as(u64, 10), std.mem.readInt(u64, directory[8..16], .little));
    try std.testing.expectEqual(@as(usize, 0), try root.read(&directory));
    const file = try root.open(std.unicode.utf8ToUtf16LeStringLiteral("\\BOOT.WIM"), .read, .{});
    defer file.close() catch {};
    try file.setPosition(7);
    try std.testing.expectEqual(@as(usize, 3), try file.read(&small));
    try std.testing.expectEqualStrings("789", small[0..3]);
    try std.testing.expectEqual(@as(usize, 0), try file.read(&small));
    try std.testing.expectError(error.WriteProtected, file.write("x"));
    try std.testing.expectError(error.WriteProtected, root.open(std.unicode.utf8ToUtf16LeStringLiteral("boot.wim"), .read_write, .{}));
    try std.testing.expectError(error.DuplicateWimbootFile, volume.add("BOOT.WIM", "bad"));
    try std.testing.expectError(error.InvalidSupportArchive, volume.addCpio("070701"));
}
