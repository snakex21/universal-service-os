//! Exact, read-only DISM reference identity for a separate diagnostic client.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const p = @import("platform.zig");
const bcd = @import("bcd.zig");
const wl = @import("windows_layout.zig");

pub const esp = .{ .start_bytes = 16777216, .size_bytes = 272629760 };
pub const windows = .{ .start_bytes = 289406976, .size_bytes = 34069282816 };
const total: u64 = 67108864;
pub fn layout() wl.Layout {
    return .{.mode=.uefi,.sector_bytes=512,.disk_bytes=total*512,
        .msr=.{.start_bytes=34*512,.size_bytes=(32768-34)*512},
        .esp=.{.start_bytes=esp.start_bytes,.size_bytes=esp.size_bytes},
        .system=.{.start_bytes=esp.start_bytes,.size_bytes=esp.size_bytes},
        .windows=.{.start_bytes=windows.start_bytes,.size_bytes=windows.size_bytes}};
}
fn get(comptime T: type, data: []const u8, at: usize) T { return std.mem.readInt(T, data[at..][0..@sizeOf(T)], .little); }
fn guid(text: []const u8) [16]u8 { return bcd.parseGuid(text) catch unreachable; }
fn header(sector: []u8, own: u64, peer: u64, array: u64) !u32 {
    if (!std.mem.eql(u8, sector[0..8], "EFI PART") or get(u32,sector,8)!=0x10000 or get(u32,sector,12)!=92 or get(u32,sector,20)!=0 or
        get(u64,sector,24)!=own or get(u64,sector,32)!=peer or get(u64,sector,40)!=34 or get(u64,sector,48)!=total-34 or
        !std.mem.eql(u8,sector[56..72],&guid("{d82f1b66-1271-4683-867c-55b5f7070868}")) or
        get(u64,sector,72)!=array or get(u32,sector,80)!=128 or get(u32,sector,84)!=128) return error.DiagnosticIdentityMismatch;
    const expected=get(u32,sector,16);std.mem.writeInt(u32,sector[16..20],0,.little);
    const actual=std.hash.Crc32.hash(sector[0..92]);std.mem.writeInt(u32,sector[16..20],expected,.little);
    if(actual!=expected)return error.DiagnosticIdentityMismatch;
    return get(u32,sector,88);
}
fn entry(data: []const u8, kind: [16]u8, id: [16]u8, start: u64, end: u64, flags: u64) !void {
    if(!std.mem.eql(u8,data[0..16],&kind) or !std.mem.eql(u8,data[16..32],&id) or get(u64,data,32)!=start or get(u64,data,40)!=end or get(u64,data,48)!=flags) return error.DiagnosticIdentityMismatch;
}
/// Caller must separately pin the exact detached VHDX SHA and create a bounded
/// overlay. This function only reads its virtual disk; it never permits writes.
pub fn validate(disk: p.Disk, a: std.mem.Allocator) !void {
    if(disk.sector_bytes!=512 or disk.sectors!=total)return error.DiagnosticIdentityMismatch;
    const sector=try a.alloc(u8,512);defer a.free(sector);
    const table=try a.alloc(u8,16384);defer a.free(table);
    try disk.read(0,sector);
    if(get(u16,sector,510)!=0xaa55 or sector[446]!=0 or sector[450]!=0xee or get(u32,sector,454)!=1 or get(u32,sector,458)!=0xffffffff or !std.mem.allEqual(u8,sector[462..510],0)) return error.DiagnosticIdentityMismatch;
    try disk.read(512,sector);const crc=try header(sector,1,total-1,2);
    try disk.read(1024,table);if(std.hash.Crc32.hash(table)!=crc)return error.DiagnosticIdentityMismatch;
    try entry(table[0..128],wl.msr_type,guid("{e5d9b44e-bcb0-48ef-a0d8-8e8d834c4e10}"),34,32767,0);
    try entry(table[128..256],wl.esp_type,guid("{f8f81433-5702-4694-acfb-ffe9586ad29f}"),32768,565247,@as(u64,1)<<63);
    try entry(table[256..384],wl.ntfs_type,guid("{87c4f69b-6413-4c94-9c91-ce38d027d22e}"),565248,67106815,@as(u64,1)<<63);
    if(!std.mem.allEqual(u8,table[384..],0))return error.DiagnosticIdentityMismatch;
    try disk.read((total-1)*512,sector);if(try header(sector,total-1,1,total-33)!=crc)return error.DiagnosticIdentityMismatch;
    for(0..32)|i|{try disk.read((total-33+i)*512,sector);if(!std.mem.eql(u8,sector,table[i*512..][0..512]))return error.DiagnosticIdentityMismatch;}
    try disk.read(windows.start_bytes,sector);
    if(!std.mem.eql(u8,sector[3..11],"NTFS    ") or get(u16,sector,11)!=512 or get(u64,sector,72)!=0xe46231e86231c05a)return error.DiagnosticIdentityMismatch;
}
