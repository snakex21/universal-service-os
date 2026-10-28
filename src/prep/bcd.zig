//! Offline BCD store construction from public BCD element definitions.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const regf = @import("regf.zig");
const u = std.unicode.utf8ToUtf16LeStringLiteral;
pub const bootmgr = "{9dea862c-5cdd-4e70-acc1-f32b344d4795}";
pub const template_loader = "{cbd971bf-b7b8-4885-951a-fa03044f5d71}";
pub const globalsettings = "{7ea2e1ac-2e61-4728-aaa3-896d9d0a9f0e}";
pub const bootloadersettings = "{6efb52bf-1766-41db-a6b3-0ee5eff72bd7}";
pub const Guid = [16]u8;
pub const Device = union(enum) {
    gpt: struct { disk: Guid, partition: Guid },
    mbr: struct { signature: u32, offset: u64 },
    pub fn encode(self: Device) ![88]u8 {
        var bytes: [88]u8 = @splat(0);
        // BCD qualified partition device: 16-byte additional-options GUID,
        // type6, device descriptor length0x48, partition ID and disk ID.
        std.mem.writeInt(u32, bytes[16..20], 6, .little);
        std.mem.writeInt(u32, bytes[24..28], 72, .little);
        switch (self) {
            .gpt => |ids| {
                if (std.mem.allEqual(u8, &ids.disk, 0) or std.mem.allEqual(u8, &ids.partition, 0) or std.mem.eql(u8, &ids.disk, &ids.partition)) return error.InvalidDevice;
                @memcpy(bytes[32..48], &ids.partition); @memcpy(bytes[56..72], &ids.disk);
            },
            .mbr => |ids| {
                if (ids.signature == 0 or ids.offset == 0 or ids.offset & 511 != 0) return error.InvalidDevice;
                std.mem.writeInt(u64, bytes[32..40], ids.offset, .little);
                std.mem.writeInt(u32, bytes[52..56], 1, .little);
                std.mem.writeInt(u32, bytes[56..60], ids.signature, .little);
            },
        }
        return bytes;
    }
};
pub const Mode = enum { uefi, bios };
pub const Options = struct {
    mode: Mode,
    system: Device,
    windows: Device,
    loader_id: []const u8 = template_loader,
    locale: []const u16 = u("en-US"),
    description: []const u16 = u("Windows"),
    timestamp: u64,
    timeout: u64 = 0,
};

pub fn parseGuid(input: []const u8) !Guid {
    if (input.len != 38 or input[0] != '{' or input[37] != '}') return error.InvalidGuid;
    var canonical: [16]u8 = undefined; var at: usize = 0; var i: usize = 1;
    while (i < 37) {
        if (i == 9 or i == 14 or i == 19 or i == 24) { if (input[i] != '-') return error.InvalidGuid; i += 1; continue; }
        if (at == 16 or i + 1 >= 37) return error.InvalidGuid;
        for (input[i..][0..2]) |c| if (!std.ascii.isHex(c)) return error.InvalidGuid;
        canonical[at] = std.fmt.parseInt(u8, input[i..][0..2], 16) catch return error.InvalidGuid;
        at += 1; i += 2;
    }
    if (at != 16) return error.InvalidGuid;
    return .{ canonical[3], canonical[2], canonical[1], canonical[0], canonical[5], canonical[4], canonical[7], canonical[6], canonical[8], canonical[9], canonical[10], canonical[11], canonical[12], canonical[13], canonical[14], canonical[15] };
}
fn path(a: std.mem.Allocator, id: []const u8, suffix: []const u8) ![]u16 {
    _ = try parseGuid(id);
    const ascii = try std.fmt.allocPrint(a, "Objects\\{s}\\{s}", .{ id, suffix }); defer a.free(ascii);
    return std.unicode.utf8ToUtf16LeAlloc(a, ascii);
}
fn string(hive: *regf.Hive, key: u32, name: []const u16, value: []const u16, multi: bool) !void {
    const bytes = try hive.allocator.alloc(u8, (value.len + (if (multi) @as(usize, 2) else 1)) * 2); defer hive.allocator.free(bytes);
    @memset(bytes, 0);
    for (value, 0..) |c, i| std.mem.writeInt(u16, bytes[i * 2 ..][0..2], c, .little);
    try hive.setValue(key, name, if (multi) 7 else 1, bytes);
}
fn object(hive: *regf.Hive, id: []const u8, kind: u32) !void {
    const p = try path(hive.allocator, id, "Description"); defer hive.allocator.free(p);
    var bytes: [4]u8 = undefined; std.mem.writeInt(u32, &bytes, kind, .little);
    try hive.setValue(try hive.ensureKey(p), u("Type"), 4, &bytes);
}
fn element(hive: *regf.Hive, id: []const u8, code: u32) !u32 {
    const suffix = try std.fmt.allocPrint(hive.allocator, "Elements\\{x:0>8}", .{code}); defer hive.allocator.free(suffix);
    const p = try path(hive.allocator, id, suffix); defer hive.allocator.free(p);
    return hive.ensureKey(p);
}
fn text(hive: *regf.Hive, id: []const u8, code: u32, value: []const u16) !void { try string(hive, try element(hive, id, code), u("Element"), value, false); }
fn idElement(hive: *regf.Hive, id: []const u8, code: u32, value: []const u8, multi: bool) !void {
    _ = try parseGuid(value);
    const value16 = try std.unicode.utf8ToUtf16LeAlloc(hive.allocator, value); defer hive.allocator.free(value16);
    try string(hive, try element(hive, id, code), u("Element"), value16, multi);
}
fn number(hive: *regf.Hive, id: []const u8, code: u32, value: u64) !void {
    var bytes: [8]u8 = undefined; std.mem.writeInt(u64, &bytes, value, .little);
    try hive.setValue(try element(hive, id, code), u("Element"), 3, &bytes);
}
fn device(hive: *regf.Hive, id: []const u8, code: u32, value: Device) !void {
    const bytes = try value.encode(); try hive.setValue(try element(hive, id, code), u("Element"), 3, &bytes);
}
fn configure(hive: *regf.Hive, options: Options) !void {
    const loader_guid = try parseGuid(options.loader_id);
    if (std.mem.allEqual(u8, &loader_guid, 0)) return error.InvalidBcdOptions;
    for ([_][]const u8{bootmgr,globalsettings,bootloadersettings}) |reserved| {
        const guid = try parseGuid(reserved);
        if (std.mem.eql(u8,&loader_guid,&guid)) return error.InvalidBcdOptions;
    }
    if (options.locale.len == 0 or options.locale.len > 85 or std.mem.indexOfScalar(u16, options.locale, 0) != null) return error.InvalidBcdOptions;
    const description = try hive.ensureKey(u("Description"));
    try string(hive, description, u("KeyName"), u("BCD00000000"), false);
    try hive.setValue(description, u("System"), 4, &.{1,0,0,0});
    try hive.setValue(description, u("TreatAsSystem"), 4, &.{1,0,0,0});
    try object(hive, bootmgr, 0x10100002);
    try object(hive, options.loader_id, 0x10200003);
    try object(hive, globalsettings, 0x20100000);
    try object(hive, bootloadersettings, 0x20200003);
    try device(hive, bootmgr, 0x11000001, options.system);
    try text(hive, bootmgr, 0x12000002, if (options.mode == .uefi) u("\\EFI\\Microsoft\\Boot\\bootmgfw.efi") else u("\\bootmgr"));
    try text(hive, bootmgr, 0x12000004, u("Windows Boot Manager"));
    try text(hive, bootmgr, 0x12000005, options.locale);
    try idElement(hive, bootmgr, 0x14000006, globalsettings, true);
    try idElement(hive, bootmgr, 0x23000003, options.loader_id, false);
    try idElement(hive, bootmgr, 0x24000001, options.loader_id, true);
    try number(hive, bootmgr, 0x25000004, options.timeout);
    try text(hive, globalsettings, 0x12000005, options.locale);
    try idElement(hive, bootloadersettings, 0x14000006, globalsettings, true);
    try device(hive, options.loader_id, 0x11000001, options.windows);
    try device(hive, options.loader_id, 0x21000001, options.windows);
    try text(hive, options.loader_id, 0x12000002, if (options.mode == .uefi) u("\\Windows\\system32\\winload.efi") else u("\\Windows\\system32\\winload.exe"));
    try text(hive, options.loader_id, 0x12000004, options.description);
    try text(hive, options.loader_id, 0x12000005, options.locale);
    try idElement(hive, options.loader_id, 0x14000006, bootloadersettings, true);
    try text(hive, options.loader_id, 0x22000002, u("\\Windows"));
    // A deployment template's well-known setup loader can carry WinPE=true.
    // This store always starts the applied installed Windows, never WinPE.
    try hive.setValue(try element(hive, options.loader_id, 0x26000022), u("Element"), 3, &.{0});
    try number(hive, options.loader_id, 0x25000020, 0); // nx OptIn, no policy bypasses.
    try hive.seal();
}
/// From scratch; result is owned by the caller and may be written to FAT/NTFS.
pub fn create(a: std.mem.Allocator, options: Options) ![]u8 {
    var hive = try regf.Hive.init(a, u("BCD00000000"), options.timestamp); defer hive.deinit();
    try configure(&hive, options);
    return hive.bytes.toOwnedSlice(a);
}
/// Retain unrelated template objects/values and patch only target boot settings.
pub fn fromTemplate(a: std.mem.Allocator, source: []const u8, options: Options) ![]u8 {
    var hive = try regf.Hive.open(a, source, options.timestamp); defer hive.deinit();
    try configure(&hive, options);
    return hive.bytes.toOwnedSlice(a);
}
