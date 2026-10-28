//! Explicit, checksummed configuration for the isolated BIOS installer.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
pub const magic = "USOSPREP BIOS I1";
pub const Config = struct {
    target_bytes: u64,
    token: [64]u8,
    source_bytes: u64,
    source_start: u64,
    source_partition_bytes: u64,
    source_serial: u64,
    image_index: u32,
    source_sector: u32,
    target_sector: u32,
    iso_bytes: u64,
    verify_all: bool = false,
    timing: bool = false,
};
pub fn parse(bytes: *const [512]u8) !Config {
    if (!std.mem.eql(u8,bytes[0..16],magic) or get(u32,bytes,16)!=1 or get(u32,bytes,20)!=512 or
        !std.mem.eql(u8,bytes[128..132],&.{0x80,0x81,0x82,0}) or
        get(u32,bytes,508)!=std.hash.Crc32.hash(bytes[0..508]) or bytes[152]>1 or bytes[153]>1 or !std.mem.allEqual(u8,bytes[154..508],0)) return error.InvalidInstallConfig;
    for (bytes[32..96]) |c| if (!std.ascii.isHex(c)) return error.InvalidInstallConfig;
    const result: Config=.{
        .target_bytes=get(u64,bytes,24),.token=bytes[32..96].*,
        .source_bytes=get(u64,bytes,96),.source_start=get(u64,bytes,104),
        .source_partition_bytes=get(u64,bytes,112),.source_serial=get(u64,bytes,120),
        .image_index=get(u32,bytes,132),.source_sector=get(u32,bytes,136),
        .target_sector=get(u32,bytes,140),.iso_bytes=get(u64,bytes,144),
        .verify_all=bytes[152]==1,
        .timing=bytes[153]==1,
    };
    if (result.source_sector!=512 and result.source_sector!=4096 or result.target_sector!=512 and result.target_sector!=4096 or
        result.source_bytes==0 or result.target_bytes<256*1024*1024 or result.source_serial==0 or result.image_index==0 or result.iso_bytes<17*2048 or
        result.source_start<1024*1024 or result.source_start%result.source_sector!=0 or result.source_partition_bytes%result.source_sector!=0 or
        result.source_start>result.source_bytes or result.source_partition_bytes>result.source_bytes-result.source_start or
        result.source_partition_bytes<result.iso_bytes or result.source_bytes%result.source_sector!=0 or result.target_bytes%result.target_sector!=0) return error.InvalidInstallConfig;
    return result;
}
fn get(comptime T: type,bytes: []const u8,at: usize) T { return std.mem.readInt(T,bytes[at..][0..@sizeOf(T)],.little); }

test "BIOS installer configuration pins all three drives and validates CRC bounds" {
    var bytes=[_]u8{0} ** 512;
    @memcpy(bytes[0..16],magic);
    std.mem.writeInt(u32,bytes[16..20],1,.little);std.mem.writeInt(u32,bytes[20..24],512,.little);
    std.mem.writeInt(u64,bytes[24..32],4*1024*1024*1024,.little);
    @memset(bytes[32..96],'a');
    std.mem.writeInt(u64,bytes[96..104],512*1024*1024,.little);
    std.mem.writeInt(u64,bytes[104..112],1024*1024,.little);
    std.mem.writeInt(u64,bytes[112..120],510*1024*1024,.little);
    std.mem.writeInt(u64,bytes[120..128],0x1234567890abcdef,.little);
    @memcpy(bytes[128..132],&[_]u8{0x80,0x81,0x82,0});
    std.mem.writeInt(u32,bytes[132..136],1,.little);
    std.mem.writeInt(u32,bytes[136..140],512,.little);
    std.mem.writeInt(u32,bytes[140..144],4096,.little);
    std.mem.writeInt(u64,bytes[144..152],2*1024*1024,.little);
    std.mem.writeInt(u32,bytes[508..512],std.hash.Crc32.hash(bytes[0..508]),.little);
    try std.testing.expectEqual(@as(u32,4096),(try parse(&bytes)).target_sector);
    try std.testing.expect(!(try parse(&bytes)).verify_all);
    try std.testing.expect(!(try parse(&bytes)).timing);
    bytes[153]=1;
    std.mem.writeInt(u32,bytes[508..512],std.hash.Crc32.hash(bytes[0..508]),.little);
    try std.testing.expect((try parse(&bytes)).timing);
    bytes[153]=2;
    std.mem.writeInt(u32,bytes[508..512],std.hash.Crc32.hash(bytes[0..508]),.little);
    try std.testing.expectError(error.InvalidInstallConfig,parse(&bytes));
    bytes[153]=0;
    bytes[152]=1;
    std.mem.writeInt(u32,bytes[508..512],std.hash.Crc32.hash(bytes[0..508]),.little);
    try std.testing.expect((try parse(&bytes)).verify_all);
    bytes[152]=2;
    std.mem.writeInt(u32,bytes[508..512],std.hash.Crc32.hash(bytes[0..508]),.little);
    try std.testing.expectError(error.InvalidInstallConfig,parse(&bytes));
    bytes[152]=0;
    std.mem.writeInt(u32,bytes[508..512],std.hash.Crc32.hash(bytes[0..508]),.little);
    for ([_]usize{0,32,128,129,130,151,200,509}) |at| {
        bytes[at]^=1;try std.testing.expectError(error.InvalidInstallConfig,parse(&bytes));bytes[at]^=1;
    }
    std.mem.writeInt(u64,bytes[112..120],std.math.maxInt(u64),.little);
    std.mem.writeInt(u32,bytes[508..512],std.hash.Crc32.hash(bytes[0..508]),.little);
    try std.testing.expectError(error.InvalidInstallConfig,parse(&bytes));
}
