//! Explicit QEMU-only BIOS boot provisioning; no installer profile switch.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const wl = @import("windows_layout.zig");
const p = @import("platform.zig");
pub const magic = "USOSPREP BIOS B1";
pub const utility_bytes = 4 * wl.mib;
pub const layout_receipt_offset = wl.mib;
pub const bcd_receipt_offset = 2 * wl.mib;
pub const receipt_limit = wl.mib;
pub const Config = struct {
    target_bytes: u64,
    ids: wl.Ids,
    system_start: u64,
    system_bytes: u64,
    windows_start: u64,
    windows_bytes: u64,
    system_serial: u64,
    loader_guid: [16]u8,
    layout_sha256: [32]u8,
    bcd_sha256: [32]u8,
    layout_bytes: u32,
    bcd_bytes: u32,
    timestamp: u64,
    locale: [32]u8,
    locale_len: u8,
    pub fn writeAllowed(self: Config, offset: u64, length: usize) bool {
        if (offset == 0 and length == 512) return true;
        return offset >= self.system_start and offset - self.system_start <= self.system_bytes and
            length <= self.system_bytes - (offset - self.system_start);
    }
};
fn get(comptime T: type, bytes: []const u8, at: usize) T { return std.mem.readInt(T,bytes[at..][0..@sizeOf(T)],.little); }
fn healthy(hash: [32]u8) bool { return !std.mem.allEqual(u8,&hash,0) and !std.mem.allEqual(u8,&hash,0xff); }
pub fn verifyReceipt(disk: p.Disk, offset: u64, size: u32, expected: [32]u8, buffer: []u8) !void {
    if (size==0 or size>receipt_limit or buffer.len==0) return error.InvalidBootReceipt;
    var hash=std.crypto.hash.sha2.Sha256.init(.{});
    var cursor:u64=0;
    while (cursor<size) {
        const n:usize=@intCast(@min(buffer.len,size-cursor));
        try disk.read(std.math.add(u64,offset,cursor) catch return error.Bounds,buffer[0..n]);
        hash.update(buffer[0..n]);cursor+=n;
    }
    if (!std.mem.eql(u8,&hash.finalResult(),&expected)) return error.BootReceiptHashMismatch;
}
pub fn parse(bytes: *const [512]u8) !Config {
    if (!std.mem.eql(u8,bytes[0..16],magic) or get(u32,bytes,16)!=1 or get(u32,bytes,20)!=512 or
        get(u32,bytes,36)!=512 or get(u32,bytes,176)!=1 or get(u32,bytes,180)!=1 or
        !std.mem.eql(u8,bytes[184..188],&.{0x80,0x81,0,0}) or !std.mem.allEqual(u8,bytes[188..192],0) or
        !std.mem.allEqual(u8,bytes[233..240],0) or !std.mem.allEqual(u8,bytes[304..508],0) or
        get(u32,bytes,508)!=std.hash.Crc32.hash(bytes[0..508])) return error.InvalidBootConfig;
    const result: Config=.{
        .target_bytes=get(u64,bytes,24),
        .ids=.{ .base=.{ .mbr_signature=get(u32,bytes,32), .ntfs_serial=get(u64,bytes,72), .disk_guid=bytes[240..256].*, .partition_guid=bytes[256..272].* },
            .esp=bytes[272..288].*, .msr=bytes[288..304].* },
        .system_start=get(u64,bytes,40), .system_bytes=get(u64,bytes,48),
        .windows_start=get(u64,bytes,56), .windows_bytes=get(u64,bytes,64),
        .system_serial=get(u64,bytes,80), .loader_guid=bytes[88..104].*,
        .layout_sha256=bytes[104..136].*, .bcd_sha256=bytes[136..168].*,
        .layout_bytes=get(u32,bytes,168), .bcd_bytes=get(u32,bytes,172),
        .timestamp=get(u64,bytes,192), .locale=bytes[201..233].*, .locale_len=bytes[200],
    };
    if (result.target_bytes<256*wl.mib or result.target_bytes%wl.mib!=0 or result.target_bytes/512>std.math.maxInt(u32) or
        result.system_start!=wl.mib or result.system_bytes!=100*wl.mib or result.windows_start!=101*wl.mib or
        result.windows_bytes!=result.target_bytes-result.windows_start or result.system_serial==0 or
        result.system_serial==std.math.maxInt(u64) or result.system_serial==result.ids.base.ntfs_serial or
        result.layout_bytes==0 or result.layout_bytes>receipt_limit or result.bcd_bytes==0 or result.bcd_bytes>receipt_limit or
        result.timestamp==0 or result.locale_len<2 or result.locale_len>result.locale.len or
        !std.mem.allEqual(u8,result.locale[result.locale_len..],0)) return error.InvalidBootConfig;
    try result.ids.validate();
    if (result.loader_guid[7]>>4!=4 or result.loader_guid[8]>>6!=2 or !healthy(result.layout_sha256) or !healthy(result.bcd_sha256) or
        std.mem.eql(u8,&result.layout_sha256,&result.bcd_sha256)) return error.InvalidBootConfig;
    for ([_][16]u8{result.ids.base.disk_guid,result.ids.base.partition_guid,result.ids.esp,result.ids.msr}) |guid|
        if (std.mem.eql(u8,&guid,&result.loader_guid)) return error.InvalidBootConfig;
    for (result.locale[0..result.locale_len]) |c| if (!std.ascii.isAlphanumeric(c) and c!='-') return error.InvalidBootConfig;
    return result;
}

fn put(comptime T: type, bytes: []u8, at: usize, value: T) void { std.mem.writeInt(T,bytes[at..][0..@sizeOf(T)],value,.little); }
fn seal(bytes: *[512]u8) void { put(u32,bytes,508,std.hash.Crc32.hash(bytes[0..508])); }
fn fixture() [512]u8 {
    var bytes:[512]u8=@splat(0);
    @memcpy(bytes[0..16],magic); put(u32,&bytes,16,1);put(u32,&bytes,20,512);put(u64,&bytes,24,3*1024*wl.mib);
    put(u32,&bytes,32,0x12345678);put(u32,&bytes,36,512);
    put(u64,&bytes,40,wl.mib);put(u64,&bytes,48,100*wl.mib);put(u64,&bytes,56,101*wl.mib);put(u64,&bytes,64,(3*1024-101)*wl.mib);
    put(u64,&bytes,72,0x123456789abcdef0);put(u64,&bytes,80,0xfedcba9876543210);
    @memset(bytes[104..136],0x12);@memset(bytes[136..168],0x23);
    put(u32,&bytes,168,1234);put(u32,&bytes,172,2345);put(u32,&bytes,176,1);put(u32,&bytes,180,1);
    @memcpy(bytes[184..188],&[_]u8{0x80,0x81,0,0});put(u64,&bytes,192,133000000000000000);
    bytes[200]=5;@memcpy(bytes[201..206],"pl-PL");
    for ([_]usize{88,240,256,272,288},0..) |at,i| { @memset(bytes[at..][0..16],@intCast(i+1));bytes[at+7]=0x40;bytes[at+8]=0x80; }
    seal(&bytes);return bytes;
}
test "BIOS boot config binds receipts disk roles identities and fresh-system geometry" {
    var bytes=fixture();const c=try parse(&bytes);
    try std.testing.expectEqual(@as(u64,3*1024*wl.mib),c.target_bytes);
    try std.testing.expectEqualStrings("pl-PL",c.locale[0..c.locale_len]);
    for ([_]usize{0,32,88,104,136,168,176,180,184,185,200,241,400,509}) |at| {
        bytes[at]^=1;try std.testing.expectError(error.InvalidBootConfig,parse(&bytes));bytes[at]^=1;
    }
    for ([_]usize{176,180}) |at| { put(u32,&bytes,at,0);seal(&bytes);try std.testing.expectError(error.InvalidBootConfig,parse(&bytes));bytes=fixture(); }
    put(u64,&bytes,64,std.math.maxInt(u64));seal(&bytes);try std.testing.expectError(error.InvalidBootConfig,parse(&bytes));
    bytes=fixture();put(u32,&bytes,168,receipt_limit+1);seal(&bytes);try std.testing.expectError(error.InvalidBootConfig,parse(&bytes));
    bytes=fixture();@memcpy(bytes[136..168],bytes[104..136]);seal(&bytes);try std.testing.expectError(error.InvalidBootConfig,parse(&bytes));
}
test "BIOS boot writes are confined to MBR and system NTFS never Windows" {
    const c=try parse(&fixture());
    try std.testing.expect(c.writeAllowed(0,512));
    try std.testing.expect(!c.writeAllowed(0,513));try std.testing.expect(!c.writeAllowed(1,511));
    try std.testing.expect(c.writeAllowed(c.system_start,4096));
    try std.testing.expect(c.writeAllowed(c.windows_start-512,512));
    try std.testing.expect(!c.writeAllowed(c.windows_start-512,513));
    try std.testing.expect(!c.writeAllowed(c.windows_start,512));
    try std.testing.expect(!c.writeAllowed(std.math.maxInt(u64),512));
}
test "BIOS boot receipt hashing reads every byte and preserves IO errors" {
    const Memory=struct {
        bytes:[2048]u8, reads:usize=0, fail:bool=false,
        fn read(ctx:*anyopaque,at:u64,out:[]u8) p.Error!void {
            const self:*@This()=@ptrCast(@alignCast(ctx));self.reads+=1;
            if (self.fail) return error.Io;
            @memcpy(out,self.bytes[@intCast(at)..][0..out.len]);
        }
        fn write(_: *anyopaque, _:u64, _:[]const u8) p.Error!void { return error.Unsupported; }
        fn flush(_: *anyopaque) p.Error!void { return error.Unsupported; }
    };
    var memory:Memory=.{.bytes=undefined};
    for (&memory.bytes,0..) |*b,i| b.*=@truncate(i*%37+%11);
    const disk:p.Disk=.{.context=&memory,.sectors=4,.read_fn=Memory.read,.write_fn=Memory.write,.flush_fn=Memory.flush};
    var buffer:[64]u8=undefined;var expected:[32]u8=undefined;
    std.crypto.hash.sha2.Sha256.hash(memory.bytes[128..1153],&expected,.{});
    try verifyReceipt(disk,128,1025,expected,&buffer);
    try std.testing.expectEqual(@as(usize,17),memory.reads);
    memory.bytes[1152]^=1;
    try std.testing.expectError(error.BootReceiptHashMismatch,verifyReceipt(disk,128,1025,expected,&buffer));
    try std.testing.expectError(error.BootReceiptHashMismatch,verifyReceipt(disk,128,1024,expected,&buffer));
    try std.testing.expectError(error.Bounds,verifyReceipt(disk,2040,9,expected,&buffer));
    memory.fail=true;
    try std.testing.expectError(error.Io,verifyReceipt(disk,128,1025,expected,&buffer));
    const reads=memory.reads;
    try std.testing.expectError(error.InvalidBootReceipt,verifyReceipt(disk,128,1025,expected,&.{}));
    try std.testing.expectEqual(reads,memory.reads);
}
