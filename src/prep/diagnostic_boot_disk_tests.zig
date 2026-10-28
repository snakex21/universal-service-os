//! Synthetic sectors only; no device or image access.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std=@import("std");const t=std.testing;const p=@import("platform.zig");const d=@import("diagnostic_boot_disk.zig");const target=@import("diagnostic_boot_target.zig");const bcd=@import("bcd.zig");const wl=@import("windows_layout.zig");
const S=struct{
    head:[34*512]u8=@splat(0),tail:[34*512]u8=@splat(0),boot:[512]u8=@splat(0),writes:usize=0,
    fn read(c:*anyopaque,at:u64,out:[]u8)p.Error!void{const s:*S=@ptrCast(@alignCast(c));@memset(out,0);const end:u64=67108864*512;
        if(at<s.head.len and out.len<=s.head.len-at){@memcpy(out,s.head[@intCast(at)..][0..out.len]);return;}
        if(at>=end-s.tail.len and at<=end and out.len<=end-at){@memcpy(out,s.tail[@intCast(at-(end-s.tail.len))..][0..out.len]);return;}
        if(at==d.windows.start_bytes and out.len==512){@memcpy(out,&s.boot);return;}}
    fn write(c:*anyopaque,_:u64,_:[]const u8)p.Error!void{const s:*S=@ptrCast(@alignCast(c));s.writes+=1;return error.Io;}
    fn flush(_: *anyopaque)p.Error!void{return error.Io;}
    fn disk(s:*S)p.Disk{return .{.context=s,.sectors=67108864,.read_fn=read,.write_fn=write,.flush_fn=flush};}
};
fn put(comptime T:type,b:[]u8,at:usize,v:T)void{std.mem.writeInt(T,b[at..][0..@sizeOf(T)],v,.little);}
fn entry(b:[]u8,kind:[16]u8,id:[]const u8,start:u64,end:u64,flags:u64)!void{
    @memcpy(b[0..16],&kind);const g=try bcd.parseGuid(id);@memcpy(b[16..32],&g);put(u64,b,32,start);put(u64,b,40,end);put(u64,b,48,flags);
}
fn hdr(b:[]u8,own:u64,peer:u64,table:u64,crc:u32)!void{
    @memcpy(b[0..8],"EFI PART");put(u32,b,8,0x10000);put(u32,b,12,92);put(u64,b,24,own);put(u64,b,32,peer);put(u64,b,40,34);put(u64,b,48,67108864-34);
    const g=try bcd.parseGuid("{d82f1b66-1271-4683-867c-55b5f7070868}");@memcpy(b[56..72],&g);put(u64,b,72,table);put(u32,b,80,128);put(u32,b,84,128);put(u32,b,88,crc);put(u32,b,16,std.hash.Crc32.hash(b[0..92]));
}
fn fixture(s:*S)!void{
    s.head[450]=0xee;put(u32,&s.head,454,1);put(u32,&s.head,458,0xffffffff);put(u16,&s.head,510,0xaa55);
    const table=s.head[1024..][0..16384];try entry(table[0..128],wl.msr_type,"{e5d9b44e-bcb0-48ef-a0d8-8e8d834c4e10}",34,32767,0);
    try entry(table[128..256],wl.esp_type,"{f8f81433-5702-4694-acfb-ffe9586ad29f}",32768,565247,@as(u64,1)<<63);
    try entry(table[256..384],wl.ntfs_type,"{87c4f69b-6413-4c94-9c91-ce38d027d22e}",565248,67106815,@as(u64,1)<<63);
    const crc=std.hash.Crc32.hash(table);try hdr(s.head[512..1024],1,67108863,2,crc);@memcpy(s.tail[512..16896],table);try hdr(s.tail[16896..17408],67108863,1,67108831,crc);
    @memcpy(s.boot[3..11],"NTFS    ");put(u16,&s.boot,11,512);put(u64,&s.boot,72,0xe46231e86231c05a);
}
test "diagnostic disk validates exact identity and never writes"{
    var s:S=.{};try fixture(&s);try d.validate(s.disk(),t.allocator);try t.expectEqual(@as(usize,0),s.writes);
    s.boot[72]^=1;try t.expectError(error.DiagnosticIdentityMismatch,d.validate(s.disk(),t.allocator));try t.expectEqual(@as(usize,0),s.writes);
}
test "diagnostic disk rejects modified GPT and MBR"{
    var s:S=.{};try fixture(&s);s.head[1024+16]^=1;try t.expectError(error.DiagnosticIdentityMismatch,d.validate(s.disk(),t.allocator));
    s=.{};try fixture(&s);s.head[446]=0x80;try t.expectError(error.DiagnosticIdentityMismatch,d.validate(s.disk(),t.allocator));
}
test "diagnostic capability never writes outside the pinned ESP"{
    var s:S=.{};try fixture(&s);var guard=try target.EspOnly.init(s.disk(),t.allocator);const disk=guard.disk();
    const bytes:[512]u8=@splat(0);
    try t.expectError(error.Bounds,disk.write(d.esp.start_bytes-512,&bytes));
    try t.expectError(error.Bounds,disk.write(d.esp.start_bytes+d.esp.size_bytes,&bytes));
    try t.expectError(error.Bounds,disk.write(d.windows.start_bytes,&bytes));
    try t.expectEqual(@as(usize,0),s.writes);
    try t.expectError(error.Io,disk.write(d.esp.start_bytes,&bytes));try t.expectEqual(@as(usize,1),s.writes);
}
