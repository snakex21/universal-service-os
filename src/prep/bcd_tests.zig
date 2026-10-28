//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const bcd = @import("bcd.zig");
const regf = @import("regf.zig");
const t = std.testing;
const u = std.unicode.utf8ToUtf16LeStringLiteral;
test "BCD GPT qualified device agrees with native WMI field layout" {
    const disk = try bcd.parseGuid("{00112233-4455-4677-8899-aabbccddeeff}");
    const part = try bcd.parseGuid("{10213243-5465-4677-8899-aabbccddeeff}");
    const value = try (bcd.Device{.gpt=.{.disk=disk,.partition=part}}).encode();
    try t.expectEqual(@as(u32, 6), std.mem.readInt(u32,value[16..20],.little));
    try t.expectEqual(@as(u32, 72), std.mem.readInt(u32,value[24..28],.little));
    try t.expectEqualSlices(u8, &part, value[32..48]); try t.expectEqualSlices(u8,&disk,value[56..72]);
    try t.expectEqual(@as(u32, 0),std.mem.readInt(u32,value[52..56],.little));
}
test "BCD MBR uses byte offset and disk signature; malformed identity refused" {
    const value = try (bcd.Device{.mbr=.{.signature=0x12345678,.offset=1048576}}).encode();
    try t.expectEqual(@as(u64,1048576),std.mem.readInt(u64,value[32..40],.little));
    try t.expectEqual(@as(u32,1),std.mem.readInt(u32,value[52..56],.little));
    try t.expectEqual(@as(u32,0x12345678),std.mem.readInt(u32,value[56..60],.little));
    try t.expectError(error.InvalidDevice,(bcd.Device{.mbr=.{.signature=0,.offset=1048576}}).encode());
    try t.expectError(error.InvalidDevice,(bcd.Device{.mbr=.{.signature=1,.offset=1}}).encode());
    try t.expectError(error.InvalidGuid,bcd.parseGuid("{001122334455-4677-8899-aabbccddeeff}"));
    try t.expectError(error.InvalidGuid,bcd.parseGuid("{+a112233-4455-4677-8899-aabbccddeeff}"));
}
test "BCD fresh BIOS and UEFI hives expose loader path locale and devices" {
    for ([_]bcd.Mode{.uefi,.bios}) |mode| {
        const device: bcd.Device = .{.mbr=.{.signature=0x12345678,.offset=1048576}};
        const bytes = try bcd.create(t.allocator,.{.mode=mode,.system=device,.windows=device,.locale=u("pl-PL"),.timestamp=1}); defer t.allocator.free(bytes);
        var hive = try regf.Hive.open(t.allocator,bytes,2); defer hive.deinit();
        const key = (try hive.findKey(u("Objects\\{cbd971bf-b7b8-4885-951a-fa03044f5d71}\\Elements\\12000002"))).?;
        const value = (try hive.getValue(key,u("Element"))).?; defer t.allocator.free(value.data);
        const wanted = if (mode==.uefi) u("\\Windows\\system32\\winload.efi\x00") else u("\\Windows\\system32\\winload.exe\x00");
        try t.expectEqualSlices(u8,std.mem.sliceAsBytes(wanted),value.data);
    }
}
test { _ = @import("regf_tests.zig"); }
