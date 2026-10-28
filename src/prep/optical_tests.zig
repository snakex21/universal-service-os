//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const o = @import("optical.zig");
const p = @import("platform.zig");
const udf = @import("optical_udf.zig");
const Memory = struct {
    data: []const u8,
    fn read(ctx: *anyopaque, offset: u64, out: []u8) p.Error!void {
        const self: *Memory = @ptrCast(@alignCast(ctx));
        if (offset > self.data.len or out.len > self.data.len-offset) return error.Bounds;
        @memcpy(out,self.data[@intCast(offset)..][0..out.len]);
    }
    fn input(self: *Memory) o.Input { return .{ .context = self, .size = self.data.len, .read_fn = read }; }
};
test "optical input and extent offset bounds are overflow safe" {
    var m: Memory = .{ .data = "abcdefghij" };
    var node: o.Node = .{ .size = 7 };
    try node.append(m.input(),2,3);
    try node.append(m.input(),std.math.maxInt(u64),2);
    try node.append(m.input(),0,2);
    var b: [7]u8 = undefined;
    try node.read(m.input(),0,&b);
    try std.testing.expectEqualSlices(u8,"cde\x00\x00ab",&b);
    try std.testing.expectError(error.OpticalBounds,node.read(m.input(),std.math.maxInt(u64),b[0..1]));
    try std.testing.expectError(error.OpticalBounds,node.append(m.input(),std.math.maxInt(u64)-1,3));
}
test "byte-addressed disk source separates 512 and 4096 sectors from optical 2048 blocks" {
    const data=try std.testing.allocator.alloc(u8,32*2048); defer std.testing.allocator.free(data);
    isoImage(data,32,false);
    _=isoRecord(data[24*2048..],28,4,0,"A;1");
    @memcpy(data[28*2048..][0..4],"data");
    const Device=struct {
        data: []const u8,
        writes: usize = 0,
        fn read(ctx: *anyopaque,offset: u64,out: []u8) p.Error!void {
            const self: *@This()=@ptrCast(@alignCast(ctx));
            if (offset>self.data.len or out.len>self.data.len-offset) return error.Bounds;
            @memcpy(out,self.data[@intCast(offset)..][0..out.len]);
        }
        fn write(ctx: *anyopaque,_: u64,_: []const u8) p.Error!void {
            const self: *@This()=@ptrCast(@alignCast(ctx)); self.writes+=1;
            return error.Unsupported;
        }
        fn flush(_: *anyopaque) p.Error!void { return error.Unsupported; }
    };
    for ([_]u32{512,4096}) |sector| {
        var device: Device=.{.data=data};
        var disk: p.Disk=.{.context=&device,.sector_bytes=sector,.sectors=data.len/sector,.read_fn=Device.read,.write_fn=Device.write,.flush_fn=Device.flush};
        const volume=try o.Volume.open(try o.Input.fromDisk(&disk));
        try std.testing.expectEqual(@as(u32,2048),volume.block_size);
        var node: o.Node=undefined; try volume.findInto("a",&node);
        var bytes: [4]u8=undefined; try node.read(volume.input,0,&bytes);
        try std.testing.expectEqualStrings("data",&bytes);
        try std.testing.expectEqual(@as(usize,0),device.writes);
    }
}
test "optical case fold includes Polish and rejects traversal" {
    try std.testing.expect(o.equalName(&.{0x0142,0x00f3,'a'},&.{0x0141,0x00d3,'A'}));
    try std.testing.expectError(error.InvalidOpticalName,o.validateName(&.{'.','.'}));
    try std.testing.expectError(error.InvalidOpticalName,o.validateName(&.{'a','\\','b'}));
}
test "pointer-out optical mount has the same data and failure contract as wrappers" {
    const data=try std.testing.allocator.alloc(u8,320*2048); defer std.testing.allocator.free(data);
    for ([_]bool{false,true}) |is_udf| {
        if (is_udf) udfImage(data) else {
            isoImage(data,320,false);
            _=isoRecord(data[24*block..],28,4,0,"A;1");
            @memcpy(data[28*block..][0..4],"data");
        }
        var memory: Memory=.{.data=data};
        var volume: o.Volume=undefined;try o.Volume.openInto(memory.input(),&volume);
        const wrapper=try o.Volume.open(memory.input());
        try std.testing.expectEqual(wrapper.kind,volume.kind);
        try std.testing.expectEqual(wrapper.root.identity,volume.root.identity);
        var file: o.Node=undefined;try volume.findInto("a",&file);
        var bytes: [4]u8=undefined;try file.read(volume.input,0,&bytes);
        try std.testing.expectEqualStrings("data",&bytes);
    }
    data[256*block+4]^=1;
    var memory: Memory=.{.data=data};var result:o.Volume=undefined;
    try std.testing.expectError(error.UdfTagChecksum,o.Volume.openInto(memory.input(),&result));
    try std.testing.expectError(error.UdfTagChecksum,o.Volume.open(memory.input()));
}
test "optical WIM stream retains original failures and maps native IO without loss" {
    var memory: Memory=.{.data="data"};
    var stream: o.Stream=.{.input=memory.input(),.node=.{.size=4}};
    var bytes: [4]u8=undefined;
    try std.testing.expectError(error.Corrupt,o.Stream.read(&stream,0,&bytes));
    try std.testing.expectEqual(error.TruncatedOpticalFile,stream.last_error.?);
    try std.testing.expectError(error.Bounds,o.Stream.read(&stream,4,&bytes));
    try std.testing.expectEqual(error.OpticalBounds,stream.last_error.?);
    const Failure=struct {
        fn read(_: *anyopaque, _: u64, _: []u8) p.Error!void { return error.Io; }
    };
    stream.input.read_fn=Failure.read;
    try stream.node.append(memory.input(),0,4);
    try std.testing.expectError(error.Io,o.Stream.read(&stream,0,&bytes));
    try std.testing.expectEqual(error.Io,stream.last_error.?);
}
test "UDF descriptor tag CRC checksum length and location are mandatory" {
    var b = [_]u8{0} ** 64;
    std.mem.writeInt(u16,b[0..2],261,.little);
    std.mem.writeInt(u16,b[2..4],3,.little);
    std.mem.writeInt(u16,b[10..12],48,.little);
    std.mem.writeInt(u32,b[12..16],5,.little);
    b[30] = 42;
    std.mem.writeInt(u16,b[8..10],udf.crc16(b[16..]),.little);
    for (b[0..16],0..) |c,i| if (i!=4) { b[4] +%= c; };
    try std.testing.expectEqual(@as(usize,64),try udf.tag(&b,5,261,36));
    try std.testing.expectError(error.InvalidUdfTag,udf.tag(&b,6,261,36));
    b[31] ^= 1;
    try std.testing.expectError(error.UdfDescriptorCrc,udf.tag(&b,5,261,36));
    b[4] ^= 1;
    try std.testing.expectError(error.UdfTagChecksum,udf.tag(&b,5,261,36));
}

const block = 2048;
fn put(comptime T: type, b: []u8, at: usize, value: T) void {
    std.mem.writeInt(T,b[at..][0..@sizeOf(T)],value,.little);
}
fn putBoth(comptime T: type, b: []u8, at: usize, value: T) void {
    put(T,b,at,value);
    std.mem.writeInt(T,b[at+@sizeOf(T)..][0..@sizeOf(T)],value,.big);
}
fn seal(b: []u8, id: u16, lba: u32, used: usize) void {
    put(u16,b,0,id); put(u16,b,2,3); b[4]=0; b[5]=0;
    put(u16,b,10,@intCast(used-16)); put(u32,b,12,lba);
    put(u16,b,8,udf.crc16(b[16..used]));
    for (b[0..16],0..) |c,i| if (i!=4) { b[4]+%=c; };
}
fn isoRecord(b: []u8, lba: u32, size: u32, flags: u8, name: []const u8) usize {
    const n=33+name.len+@intFromBool(name.len%2==0);
    @memset(b[0..n],0); b[0]=@intCast(n); b[25]=flags; b[32]=@intCast(name.len);
    putBoth(u32,b,2,lba); putBoth(u32,b,10,size); putBoth(u16,b,28,1);
    @memcpy(b[33..][0..name.len],name); return n;
}
fn isoImage(data: []u8, sectors: u32, wide: bool) void {
    @memset(data,0);
    const primary=data[16*block..][0..block];
    primary[0]=1; @memcpy(primary[1..7],"CD001\x01");
    putBoth(u32,primary,80,sectors); putBoth(u16,primary,120,1);
    putBoth(u16,primary,124,1); putBoth(u16,primary,128,block);
    _=isoRecord(primary[156..],24,block,2,"\x00");
    if (wide) {
        const supplementary=data[17*block..][0..block];
        @memcpy(supplementary,primary); supplementary[0]=2; @memcpy(supplementary[88..91],"%/E");
        _=isoRecord(supplementary[156..],25,block,2,"\x00");
    }
    const end=data[(if (wide) @as(usize,18) else 17)*block..];
    @memcpy(end[0..7],"\xffCD001\x01");
}
const Virtual = struct {
    prefix: []const u8,
    size: u64,
    calls: usize = 0,
    fn read(ctx: *anyopaque, offset: u64, out: []u8) p.Error!void {
        const self: *Virtual=@ptrCast(@alignCast(ctx));
        self.calls+=1;
        if (offset>self.size or out.len>self.size-offset) return error.Bounds;
        for (out,0..) |*v,i| {
            const at=offset+i;
            v.*=if (at<self.prefix.len) self.prefix[@intCast(at)] else @intCast(at%251);
        }
    }
    fn input(self: *Virtual) o.Input { return .{.context=self,.size=self.size,.read_fn=read}; }
};
test "ISO multi-extent exceeds 4 GiB with bounded streamed offset reads" {
    const data=try std.testing.allocator.alloc(u8,32*block); defer std.testing.allocator.free(data);
    const first_size=0xfffff800;
    const next_lba=64+first_size/block;
    const sectors=next_lba+2;
    isoImage(data,sectors,false);
    const directory=data[24*block..][0..block];
    const n=isoRecord(directory,64,first_size,0x80,"BIG.BIN;1");
    _=isoRecord(directory[n..],next_lba,4096,0,"BIG.BIN;1");
    var virtual: Virtual=.{.prefix=data,.size=@as(u64,sectors)*block};
    const volume=try o.Volume.open(virtual.input());
    const file=try volume.find("big.bin");
    try std.testing.expectEqual(@as(u64,0x100000800),file.size);
    try std.testing.expectEqual(@as(usize,2),file.count);
    var bytes: [32]u8=undefined;
    try file.read(volume.input,first_size-16,&bytes);
    for (bytes,0..) |v,i| try std.testing.expectEqual(@as(u8,@intCast((64*@as(u64,block)+first_size-16+i)%251)),v);
    try file.read(volume.input,0x100000000,bytes[0..1]);
    try std.testing.expect(virtual.calls<100);
    directory[n+33]='X';
    try std.testing.expectError(error.InvalidIsoMultiExtent,volume.find("big.bin"));
}
test "ISO rejects both-endian mismatch interleave and directory loops" {
    const data=try std.testing.allocator.alloc(u8,32*block); defer std.testing.allocator.free(data);
    isoImage(data,32,false);
    const directory=data[24*block..][0..block];
    _=isoRecord(directory,24,block,2,"LOOP");
    var memory: Memory=.{.data=data};
    var volume=try o.Volume.open(memory.input());
    try std.testing.expectError(error.DirectoryLoop,volume.find("loop"));
    _=isoRecord(directory,28,4,0,"A;1"); directory[26]=1;
    try std.testing.expectError(error.InvalidIsoRecord,volume.find("a"));
    directory[26]=0; directory[6]^=1;
    try std.testing.expectError(error.IsoEndianMismatch,volume.find("a"));
    directory[6]^=1; directory[25]=0x60;
    try std.testing.expectError(error.InvalidIsoRecord,volume.find("a"));
    directory[25]=0;
    data[16*block+128]^=1;
    try std.testing.expectError(error.IsoEndianMismatch,o.Volume.open(memory.input()));
}
test "Joliet wins over primary and case-insensitive Unicode path resolves" {
    const data=try std.testing.allocator.alloc(u8,32*block); defer std.testing.allocator.free(data);
    isoImage(data,32,true);
    _=isoRecord(data[24*block..],28,1,0,"PRIMARY.TXT;1");
    _=isoRecord(data[25*block..],28,1,0,"\x01\x41\x00\xf3\x00\x64\x01\x7a\x00\x2e\x00\x74\x00\x78\x00\x74\x00\x3b\x00\x31");
    var memory: Memory=.{.data=data};
    const volume=try o.Volume.open(memory.input());
    try std.testing.expectEqual(o.Kind.joliet,volume.kind);
    try std.testing.expectEqual(@as(u64,1),(try volume.find("łÓDŹ.TXT")).size);
    try std.testing.expectError(error.NotFound,volume.find("primary.txt"));
    try std.testing.expectError(error.InvalidOpticalName,volume.find("../anything"));
}
test "install WIM lookup distinguishes ESD split parts and missing source" {
    const data=try std.testing.allocator.alloc(u8,32*block); defer std.testing.allocator.free(data);
    for ([_][]const u8{"INSTALL.ESD;1","INSTALL.SWM;1","INSTALL2.SWM;1","OTHER.TXT;1"},0..) |name,i| {
        isoImage(data,32,false);
        _=isoRecord(data[24*block..],26,block,2,"SOURCES");
        _=isoRecord(data[26*block..],28,4,0,name);
        var memory: Memory=.{.data=data}; const volume=try o.Volume.open(memory.input());
        try std.testing.expectError(switch (i) {
            0 => error.InstallEsdUnsupported,
            1,2 => error.InstallSwmUnsupported,
            else => error.NotFound,
        },volume.findInstallWim());
        const at=isoRecord(data[26*block..],28,4,0,"INSTALL.WIM;1");
        _=isoRecord(data[26*block+at..],28,4,0,name);
        try std.testing.expectEqual(@as(u64,4),(try volume.findInstallWim()).size);
    }
}
fn longAd(b: []u8, length: u32, lba: u32, ref: u16) void {
    @memset(b[0..16],0); put(u32,b,0,length); put(u32,b,4,lba); put(u16,b,8,ref);
}
fn udfEntry(b: []u8, lba: u32, file_type: u8, target: u32, size: u64) void {
    @memset(b,0); put(u16,b,20,4); b[27]=file_type; put(u16,b,34,0);
    put(u64,b,56,size); put(u32,b,172,8);
    put(u32,b,176,@intCast(size)); put(u32,b,180,target); seal(b,261,lba,184);
}
fn udfImage(data: []u8) void {
    @memset(data,0);
    @memcpy(data[16*block+1..][0..5],"BEA01");
    @memcpy(data[17*block+1..][0..5],"NSR03");
    @memcpy(data[18*block+1..][0..5],"TEA01");
    const anchor=data[256*block..][0..block];
    put(u32,anchor,16,3*block); put(u32,anchor,20,257); seal(anchor,2,256,512);
    const pd=data[257*block..][0..block];
    put(u16,pd,22,0); put(u32,pd,188,32); put(u32,pd,192,192); seal(pd,5,257,512);
    const lvd=data[258*block..][0..block];
    put(u32,lvd,212,block); @memcpy(lvd[217..][0..19],"*OSTA UDF Compliant"); put(u16,lvd,240,0x201);
    longAd(lvd[248..],block,0,0); put(u32,lvd,264,6); put(u32,lvd,268,1);
    @memcpy(lvd[440..446],&[_]u8{1,6,1,0,0,0}); seal(lvd,6,258,446);
    seal(data[259*block..][0..block],8,259,512);
    const fsd=data[32*block..][0..block]; longAd(fsd[400..],block,1,0); seal(fsd,256,0,512);
    const fid=data[34*block..][0..block];
    put(u16,fid,16,1); fid[18]=0; fid[19]=2; longAd(fid[20..],block,3,0); fid[38]=8; fid[39]='A'; seal(fid,257,2,40);
    udfEntry(data[33*block..][0..block],1,4,2,40);
    udfEntry(data[35*block..][0..block],3,5,4,4);
    @memcpy(data[36*block..][0..4],"data");
}
test "UDF refuses truncated fixed descriptors and recognized UDF never downgrades" {
    const data=try std.testing.allocator.alloc(u8,320*block); defer std.testing.allocator.free(data);
    udfImage(data);
    var memory: Memory=.{.data=data};
    const volume=try o.Volume.open(memory.input());
    try std.testing.expectEqual(o.Kind.udf,volume.kind);
    var bytes: [4]u8=undefined;
    try (try volume.find("a")).read(memory.input(),0,&bytes);
    try std.testing.expectEqualSlices(u8,"data",&bytes);
    const anchor=data[256*block..][0..block];
    seal(anchor,2,256,32);
    try std.testing.expectError(error.InvalidUdfTag,o.Volume.open(memory.input()));
    seal(anchor,2,256,512);
    const pd=data[257*block..][0..block]; seal(pd,5,257,196);
    try std.testing.expectError(error.InvalidUdfPartition,o.Volume.open(memory.input()));
    seal(pd,5,257,512);
    const fsd=data[32*block..][0..block]; seal(fsd,256,0,464);
    try std.testing.expectError(error.InvalidUdfTag,o.Volume.open(memory.input()));
    // A valid ISO remains available, but a recognized broken UDF is authoritative.
    isoImage(data[0..32*block],320,false);
    @memcpy(data[18*block+1..][0..5],"NSR03");
    try std.testing.expectError(error.InvalidUdfTag,o.Volume.open(memory.input()));
}
test "UDF anchor validation falls back to N-256 then N without ISO downgrade" {
    const data=try std.testing.allocator.alloc(u8,320*block); defer std.testing.allocator.free(data);
    udfImage(data);
    const primary=data[256*block..][0..block];
    const backup=data[63*block..][0..block];
    const final=data[319*block..][0..block];
    @memcpy(backup,primary); seal(backup,2,63,512);
    @memcpy(final,primary); seal(final,2,319,512);
    primary[4]^=1;
    var memory: Memory=.{.data=data};
    try std.testing.expectEqual(o.Kind.udf,(try o.Volume.open(memory.input())).kind);
    backup[8]^=1;
    try std.testing.expectEqual(@as(u64,4),(try (try o.Volume.open(memory.input())).find("a")).size);
    final[4]^=1;
    try std.testing.expectError(error.UdfTagChecksum,o.Volume.open(memory.input()));
    // A correctly sealed anchor whose extent is outside the image also falls back.
    seal(primary,2,256,512); put(u32,primary,20,std.math.maxInt(u32)); seal(primary,2,256,512);
    seal(final,2,319,512);
    try std.testing.expectEqual(o.Kind.udf,(try o.Volume.open(memory.input())).kind);
    const UnreadablePrimary=struct {
        data: []const u8,
        fn read(ctx: *anyopaque,offset: u64,out: []u8) p.Error!void {
            const self: *@This()=@ptrCast(@alignCast(ctx));
            if (offset==256*block) return error.Io;
            if (offset>self.data.len or out.len>self.data.len-offset) return error.Bounds;
            @memcpy(out,self.data[@intCast(offset)..][0..out.len]);
        }
    };
    var unreadable: UnreadablePrimary=.{.data=data};
    try std.testing.expectEqual(o.Kind.udf,(try o.Volume.open(.{.context=&unreadable,.size=data.len,.read_fn=UnreadablePrimary.read})).kind);
}

test "UDF FID CRC span logical location padding and skipped versions are checked" {
    const data=try std.testing.allocator.alloc(u8,320*block); defer std.testing.allocator.free(data);
    udfImage(data);
    var memory: Memory=.{.data=data}; const volume=try o.Volume.open(memory.input());
    const fid=data[34*block..][0..block];
    seal(fid,257,2,38);
    try std.testing.expectError(error.InvalidUdfTag,volume.find("a"));
    seal(fid,257,3,40);
    try std.testing.expectError(error.InvalidUdfTag,volume.find("a"));
    seal(fid,257,2,40); fid[39]^=1;
    try std.testing.expectError(error.UdfDescriptorCrc,volume.find("a"));
    fid[39]^=1; fid[19]=1; fid[39]=1; seal(fid,257,2,40);
    try std.testing.expectError(error.InvalidUdfDirectory,volume.find("a"));
    fid[18]=8|2; fid[19]=0; fid[38]=0; fid[39]=0; put(u16,fid,16,2); seal(fid,257,2,40);
    try std.testing.expectError(error.InvalidUdfDirectory,volume.find("a"));
}
test "UDF System attribute remains readable while compression and encryption refuse" {
    const data=try std.testing.allocator.alloc(u8,320*block); defer std.testing.allocator.free(data);
    udfImage(data);
    var memory: Memory=.{.data=data};
    const volume=try o.Volume.open(memory.input());
    const fe=data[35*block..][0..block];
    put(u16,fe,34,0x0400); seal(fe,261,3,184);
    var bytes: [4]u8=undefined;
    try (try volume.find("a")).read(memory.input(),0,&bytes);
    try std.testing.expectEqualSlices(u8,"data",&bytes);
    for ([_]u16{0x0800,0x1000,0x1c00}) |flags| {
        put(u16,fe,34,flags); seal(fe,261,3,184);
        try std.testing.expectError(error.UnsupportedUdfTransform,volume.find("a"));
    }
}

test "UDF optional unsupported entries are skipped counted and refuse only when requested" {
    const data=try std.testing.allocator.alloc(u8,320*block); defer std.testing.allocator.free(data);
    const Fixture = struct { file_type: u8, flags: u16, reason: anyerror };
    for ([_]Fixture{
        .{.file_type=12,.flags=0,.reason=error.UnsupportedUdfSymbolicLink},
        .{.file_type=13,.flags=0,.reason=error.UnsupportedUdfStream},
        .{.file_type=5,.flags=0x2000,.reason=error.UnsupportedUdfStream},
        .{.file_type=5,.flags=0x0800,.reason=error.UnsupportedUdfTransform},
    }) |case| {
        udfImage(data);
        const fid=data[34*block..][0..block];
        @memcpy(fid[40..80],fid[0..40]); fid[79]='B'; longAd(fid[60..],block,5,0); seal(fid[40..80],257,2,40);
        udfEntry(data[33*block..][0..block],1,4,2,80);
        udfEntry(data[35*block..][0..block],3,case.file_type,4,4);
        const fe=data[35*block..][0..block]; put(u16,fe,34,case.flags); seal(fe,261,3,184);
        udfEntry(data[37*block..][0..block],5,5,4,4);
        var memory: Memory=.{.data=data}; const volume=try o.Volume.open(memory.input());
        var iterator=try volume.list(volume.root); var entry: o.Entry=undefined;
        try std.testing.expect(try iterator.next(&entry));
        try std.testing.expectEqualSlices(u16,&.{'B'},entry.nameSlice());
        try std.testing.expectEqual(@as(usize,1),iterator.skipped.total());
        try std.testing.expect(!try iterator.next(&entry));
        try std.testing.expectError(case.reason,volume.find("a"));
        var bytes: [4]u8=undefined; try (try volume.find("b")).read(memory.input(),0,&bytes);
        try std.testing.expectEqualSlices(u8,"data",&bytes);
    }
    for ([_]u8{254,255}) |compression| {
        udfImage(data);
        const fid=data[34*block..][0..block]; fid[18]=4; fid[38]=compression; seal(fid,257,2,40);
        var memory: Memory=.{.data=data}; const volume=try o.Volume.open(memory.input());
        var iterator=try volume.list(volume.root); var entry: o.Entry=undefined;
        try std.testing.expect(!try iterator.next(&entry));
        try std.testing.expectEqual(@as(usize,1),iterator.skipped.nameless);
    }
}

test "UDF allocation continuation is read and self loops are refused" {
    const data=try std.testing.allocator.alloc(u8,320*block); defer std.testing.allocator.free(data);
    udfImage(data);
    const fe=data[35*block..][0..block];
    put(u32,fe,176,0xc0000800); put(u32,fe,180,5); seal(fe,261,3,184);
    const ad=data[37*block..][0..block];
    put(u32,ad,20,8); put(u32,ad,24,4); put(u32,ad,28,4); seal(ad,258,5,32);
    var memory: Memory=.{.data=data}; const volume=try o.Volume.open(memory.input());
    var bytes: [4]u8=undefined; try (try volume.find("a")).read(memory.input(),0,&bytes);
    try std.testing.expectEqualSlices(u8,"data",&bytes);
    put(u32,ad,24,0xc0000800); put(u32,ad,28,5); seal(ad,258,5,32);
    try std.testing.expectError(error.UdfAllocationLoop,volume.find("a"));
    put(u32,ad,20,2048); seal(ad,258,5,32);
    try std.testing.expectError(error.InvalidUdfAllocation,volume.find("a"));
}
fn udfMetadata(data: []u8, revision: u16) void {
    udfImage(data);
    @memcpy(data[96*block..][0..7*block],data[32*block..][0..7*block]);
    const lvd=data[258*block..][0..block]; put(u16,lvd,240,revision);
    longAd(lvd[248..],block,0,1); put(u32,lvd,264,70); put(u32,lvd,268,2);
    const map=lvd[446..][0..64]; @memset(map,0); map[0]=2; map[1]=64;
    @memcpy(map[5..28],"*UDF Metadata Partition"); put(u16,map,28,revision);
    put(u16,map,36,1); put(u16,map,38,0); put(u32,map,40,40); seal(lvd,6,258,510);
    udfEntry(data[72*block..][0..block],40,250,64,64*block);
    const fsd=data[96*block..][0..block]; longAd(fsd[400..],block,1,1); seal(fsd,256,0,512);
    const fid=data[98*block..][0..block]; longAd(fid[20..],block,3,1); seal(fid,257,2,40);
    const fe=data[99*block..][0..block]; put(u16,fe,34,1); put(u32,fe,172,16);
    longAd(fe[176..],4,4,0); seal(fe,261,3,192);
}
test "UDF 2.50 and 2.60 map metadata logical locations to physical data" {
    const data=try std.testing.allocator.alloc(u8,320*block); defer std.testing.allocator.free(data);
    for ([_]u16{0x250,0x260}) |revision| {
        udfMetadata(data,revision);
        var memory: Memory=.{.data=data}; const volume=try o.Volume.open(memory.input());
        try std.testing.expectEqual(revision,volume.udf_state.revision);
        var bytes: [4]u8=undefined; try (try volume.find("a")).read(memory.input(),0,&bytes);
        try std.testing.expectEqualSlices(u8,"data",&bytes);
        const metadata=data[72*block..][0..block];
        metadata[27]=5; seal(metadata,261,40,184);
        try std.testing.expectError(error.UnsupportedUdfFileType,o.Volume.open(memory.input()));
        metadata[27]=250; put(u32,metadata,176,64*block-1); put(u64,metadata,56,64*block-1); seal(metadata,261,40,184);
        try std.testing.expectError(error.InvalidUdfMetadata,o.Volume.open(memory.input()));
    }
}
test "UDF fragmented metadata partitions retain logical FID locations" {
    const data=try std.testing.allocator.alloc(u8,320*block); defer std.testing.allocator.free(data);
    udfMetadata(data,0x260);
    @memcpy(data[112*block..][0..5*block],data[98*block..][0..5*block]);
    const metadata=data[72*block..][0..block];
    put(u32,metadata,172,16); put(u32,metadata,176,2*block); put(u32,metadata,180,64);
    put(u32,metadata,184,62*block); put(u32,metadata,188,80); seal(metadata,261,40,192);
    var memory: Memory=.{.data=data}; const volume=try o.Volume.open(memory.input());
    var bytes: [4]u8=undefined; try (try volume.find("a")).read(memory.input(),0,&bytes);
    try std.testing.expectEqualSlices(u8,"data",&bytes);
    const fid=data[112*block..][0..block]; seal(fid,257,80,40);
    try std.testing.expectError(error.InvalidUdfTag,volume.find("a"));
}
test "UDF sparse unallocated extents are zero and physical bounds are mandatory" {
    const data=try std.testing.allocator.alloc(u8,320*block); defer std.testing.allocator.free(data);
    udfImage(data); var memory: Memory=.{.data=data}; const volume=try o.Volume.open(memory.input());
    const fe=data[35*block..][0..block]; put(u32,fe,176,0x80000004); seal(fe,261,3,184);
    var bytes: [4]u8=undefined; try (try volume.find("a")).read(memory.input(),0,&bytes);
    try std.testing.expectEqualSlices(u8,&.{0,0,0,0},&bytes);
    put(u32,fe,176,4); put(u32,fe,180,std.math.maxInt(u32)); seal(fe,261,3,184);
    try std.testing.expectError(error.OpticalBounds,volume.find("a"));
    put(u32,fe,180,4); put(u64,fe,56,5); seal(fe,261,3,184);
    try std.testing.expectError(error.TruncatedOpticalFile,volume.find("a"));
}
test "UDF streamed short allocation extents retain 64-bit file offsets" {
    const data=try std.testing.allocator.alloc(u8,320*block); defer std.testing.allocator.free(data);
    udfImage(data);
    const extent_bytes=0x3ffff800;
    const file_size=5*@as(u64,extent_bytes);
    const sectors=32+1024+5*(extent_bytes/block);
    const pd=data[257*block..][0..block]; put(u32,pd,192,sectors-32); seal(pd,5,257,512);
    const fe=data[35*block..][0..block]; put(u64,fe,56,file_size); put(u32,fe,172,5*8);
    for (0..5) |i| { put(u32,fe,176+i*8,extent_bytes); put(u32,fe,180+i*8,@intCast(1024+i*(extent_bytes/block))); }
    seal(fe,261,3,176+5*8);
    var virtual: Virtual=.{.prefix=data,.size=@as(u64,sectors)*block};
    const volume=try o.Volume.open(virtual.input()); const file=try volume.find("a");
    try std.testing.expectEqual(file_size,file.size);
    var bytes: [32]u8=undefined; try file.read(virtual.input(),0x100000010,&bytes);
    for (bytes,0..) |v,i| try std.testing.expectEqual(@as(u8,@intCast(((32+1024)*@as(u64,block)+0x100000010+i)%251)),v);
    try std.testing.expect(virtual.calls<100);
}
test "UDF continuation and extent budgets refuse exhaustion without hanging" {
    const data=try std.testing.allocator.alloc(u8,320*block); defer std.testing.allocator.free(data);
    udfImage(data);
    const fe=data[35*block..][0..block]; put(u32,fe,176,0xc0000800); put(u32,fe,180,40); seal(fe,261,3,184);
    for (40..105) |lba| {
        const ad=data[(32+lba)*block..][0..block];
        put(u32,ad,20,8); put(u32,ad,24,0xc0000800); put(u32,ad,28,@intCast(lba+1)); seal(ad,258,@intCast(lba),32);
    }
    var memory: Memory=.{.data=data}; const volume=try o.Volume.open(memory.input());
    try std.testing.expectError(error.ExtentBudget,volume.find("a"));
    put(u32,fe,172,232*8); put(u64,fe,56,257*block);
    for (0..231) |i| { put(u32,fe,176+i*8,block); put(u32,fe,180+i*8,4); }
    put(u32,fe,176+231*8,0xc0000800); put(u32,fe,180+231*8,40); seal(fe,261,3,176+232*8);
    const ad=data[72*block..][0..block]; put(u32,ad,20,26*8);
    for (0..26) |i| { put(u32,ad,24+i*8,block); put(u32,ad,28+i*8,4); }
    seal(ad,258,40,24+26*8);
    try std.testing.expectError(error.ExtentBudget,volume.find("a"));
}
test "optical directory budgets count internal skipped records too" {
    const data=try std.testing.allocator.alloc(u8,320*block); defer std.testing.allocator.free(data);
    udfImage(data); var memory: Memory=.{.data=data}; const volume=try o.Volume.open(memory.input());
    var iterator=try volume.list(volume.root); iterator.records=1000000;
    var entry: o.Entry=undefined;
    try std.testing.expectError(error.DirectoryBudget,iterator.next(&entry));
    iterator.offset=iterator.directory.size;
    try std.testing.expect(!try iterator.next(&entry));
    isoImage(data,320,false); const iso=try o.Volume.open(memory.input());
    _=isoRecord(data[24*block..],24,block,2,"\x00");
    iterator=try iso.list(iso.root); iterator.records=1000000;
    try std.testing.expectError(error.DirectoryBudget,iterator.next(&entry));
}

test "shared optical walker enforces whole-tree budget and bounded paths" {
    const data=try std.testing.allocator.alloc(u8,32*block); defer std.testing.allocator.free(data);
    isoImage(data,32,false);
    const directory=data[24*block..][0..block];
    var at=isoRecord(directory,26,block,2,"DIR");
    _=isoRecord(directory[at..],28,1,0,"ROOT;1");
    at=isoRecord(data[26*block..],28,1,0,"ONE;1");
    _=isoRecord(data[26*block+at..],28,1,0,"TWO;1");
    var memory: Memory=.{.data=data}; const volume=try o.Volume.open(memory.input());
    var walker=try o.Walker.init(&volume,std.testing.allocator); defer walker.deinit();
    var entry: o.Entry=undefined;
    for ([_][]const u8{"DIR","DIR/ONE","DIR/TWO","ROOT"}) |expected| {
        try std.testing.expect(try walker.next(&entry));
        try std.testing.expectEqualStrings(expected,walker.path());
    }
    try std.testing.expect(!try walker.next(&entry));
    try std.testing.expectEqual(@as(usize,4),walker.entries);
    var limited=try o.Walker.init(&volume,std.testing.allocator); defer limited.deinit();
    limited.budget.limit=2;
    try std.testing.expect(try limited.next(&entry));
    try std.testing.expect(try limited.next(&entry));
    try std.testing.expectError(error.TreeBudget,limited.next(&entry));
}

test "ISO associated data stream does not hide a supported sibling" {
    const data=try std.testing.allocator.alloc(u8,32*block); defer std.testing.allocator.free(data);
    isoImage(data,32,false);
    const at=isoRecord(data[24*block..],28,4,4,"RESOURCE;1");
    _=isoRecord(data[24*block+at..],28,4,0,"NORMAL;1");
    var memory: Memory=.{.data=data}; const volume=try o.Volume.open(memory.input());
    try std.testing.expectEqual(@as(u64,4),(try volume.find("normal")).size);
    try std.testing.expectError(error.UnsupportedAssociatedFile,volume.find("resource"));
    var walker=try o.Walker.init(&volume,std.testing.allocator); defer walker.deinit();
    var entry: o.Entry=undefined;
    try std.testing.expect(try walker.next(&entry));
    try std.testing.expectEqualStrings("NORMAL",walker.path());
    try std.testing.expect(!try walker.next(&entry));
    try std.testing.expectEqual(@as(usize,1),walker.skipped.streams);
}
