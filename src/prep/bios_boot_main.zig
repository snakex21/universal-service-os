//! Separate QEMU-only i486 BIOS boot provisioning; no WIM installer code.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std=@import("std");
const builtin=@import("builtin");
const p=@import("platform.zig");
const app=@import("app.zig");
const entropy=@import("entropy.zig");
const heap_mod=@import("fixed_heap.zig");
const bios_heap=@import("bios_heap.zig");
const layout=@import("windows_layout.zig");
const provision=@import("boot_bios_files.zig");
const code=@import("bios_boot_code");
const config=@import("bios_boot_config.zig");
const Context=extern struct { magic:u32,version:u16,size:u16,drive:u8,reserved:[3]u8,sector_bytes:u32,core_lba:u64 };
const DriveInfo=extern struct { low:u32,high:u32,sector_bytes:u16,cylinders:u16,heads:u16,spt:u16 };
extern fn bios_install_read_blocks(u32,u64,u32,u32,[*]u8) callconv(.c) u32;
extern fn bios_install_write_blocks(u32,u64,u32,u32,[*]const u8) callconv(.c) u32;
extern fn bios_drive_info(u32,*DriveInfo) callconv(.c) u32;
extern fn bios_e820_probe([*]bios_heap.Region) callconv(.c) u32;
extern fn core_putc(u8) callconv(.c) void;
extern var __prep_bss_start:u8;
extern var __prep_bss_end:u8;
extern var bios_install_stack_top:u32;
const stack_base:usize=0x60000;
const stack_pattern:u32=0xcccccccc;

const Block=struct {
    drive:u32,sector:u32,sectors:u64,writable:bool=false,
    reads:u64=0,writes:u64=0,read_bytes:u64=0,written_bytes:u64=0,
    fn disk(self:*Block) p.Disk { return .{.context=self,.sector_bytes=self.sector,.sectors=self.sectors,.read_fn=read,.write_fn=write,.flush_fn=flush}; }
    fn open(drive:u32,bytes:u64,sector:u32,writable:bool) !Block {
        var info:DriveInfo=undefined;
        if (sector!=512 and sector!=4096 or bios_drive_info(drive,&info)!=0 or info.sector_bytes!=sector) return error.UnsupportedSectorSize;
        const sectors=(@as(u64,info.high)<<32)|info.low;
        if (sectors==0 or (std.math.mul(u64,sectors,sector) catch return error.Bounds)!=bytes) return error.DeviceSizeMismatch;
        return .{.drive=drive,.sector=sector,.sectors=sectors,.writable=writable};
    }
    fn maxBatch(sector:u32) u32 { return @min(127,65535/sector); }
    fn read(ctx:*anyopaque,offset:u64,out:[]u8) p.Error!void {
        const self:*Block=@ptrCast(@alignCast(ctx));
        var one:[4096]u8=undefined;
        var done:usize=0;
        while (done<out.len) {
            const cursor=offset+done;
            const within:usize=@intCast(cursor%self.sector);
            if (within==0 and out.len-done>=self.sector) {
                const count:u32=@intCast(@min(maxBatch(self.sector),(out.len-done)/self.sector));
                if (bios_install_read_blocks(self.drive,cursor/self.sector,count,self.sector,out[done..].ptr)!=0) return error.Io;
                const n:usize=count*self.sector;done+=n;self.reads+=1;self.read_bytes+=n;
            } else {
                if (bios_install_read_blocks(self.drive,cursor/self.sector,1,self.sector,&one)!=0) return error.Io;
                const n=@min(out.len-done,self.sector-within);
                @memcpy(out[done..][0..n],one[within..][0..n]);done+=n;self.reads+=1;self.read_bytes+=self.sector;
            }
        }
    }
    fn write(ctx:*anyopaque,offset:u64,bytes:[]const u8) p.Error!void {
        const self:*Block=@ptrCast(@alignCast(ctx));
        if (!self.writable) return error.Unsupported;
        var one:[4096]u8=undefined;
        var done:usize=0;
        while (done<bytes.len) {
            const cursor=offset+done;
            const within:usize=@intCast(cursor%self.sector);
            if (within==0 and bytes.len-done>=self.sector) {
                const count:u32=@intCast(@min(maxBatch(self.sector),(bytes.len-done)/self.sector));
                if (bios_install_write_blocks(self.drive,cursor/self.sector,count,self.sector,bytes[done..].ptr)!=0) return error.Io;
                const n:usize=count*self.sector;done+=n;self.writes+=1;self.written_bytes+=n;
            } else {
                if (bios_install_read_blocks(self.drive,cursor/self.sector,1,self.sector,&one)!=0) return error.Io;
                const n=@min(bytes.len-done,self.sector-within);
                @memcpy(one[within..][0..n],bytes[done..][0..n]);
                if (bios_install_write_blocks(self.drive,cursor/self.sector,1,self.sector,&one)!=0) return error.Io;
                done+=n;self.writes+=1;self.written_bytes+=self.sector;
            }
        }
    }
    fn flush(_: *anyopaque) p.Error!void {} // AH43 completion is synchronous.
};
const Output=struct {
    qemu:bool,persist:bool=false,cursor:usize=0,buffer:[512]u8=@splat(0),failed:bool=false,
    fn write(ctx:*anyopaque,text:[]const u8) void {
        const self:*Output=@ptrCast(@alignCast(ctx));
        for (text) |c| {
            core_putc(c);
            if (self.qemu) asm volatile ("outb %[value], %[port]"::[value]"{al}"(c),[port]"{dx}"(@as(u16,0xe9)));
            if (!self.persist) continue;
            if (self.cursor>=1023*512) { self.failed=true;continue; }
            self.buffer[self.cursor%512]=c;self.cursor+=1;
            if (self.cursor%512==0) {
                if (bios_install_write_blocks(0x80,1025+(self.cursor-1)/512,1,512,&self.buffer)!=0) self.failed=true;
                @memset(&self.buffer,0);
            }
        }
        if (self.persist and self.cursor%512!=0 and bios_install_write_blocks(0x80,1025+self.cursor/512,1,512,&self.buffer)!=0) self.failed=true;
    }
    fn clock(_: *anyopaque) u64 {
        const tick:*const volatile u32=@ptrFromInt(0x46c);
        return @as(u64,tick.*)*10/182;
    }
    fn logger(self:*Output) app.Logger { return .{.context=self,.write_fn=write,.clock_fn=clock}; }
};
fn stackUsage() !struct { reserved:usize,used:usize } {
    const top:usize=bios_install_stack_top;
    if (top<=stack_base or top>0x9e000 or top%4!=0) return error.StackMeasurementUnavailable;
    var cursor=stack_base;
    while (cursor<top) : (cursor+=4) {
        const word:*const volatile u32=@ptrFromInt(cursor);
        if (word.*!=stack_pattern) break;
    }
    if (cursor<stack_base+4096) return error.StackBudgetExceeded;
    return .{.reserved=top-stack_base,.used=top-cursor};
}

const GuardedTarget=struct {
    raw:p.Disk,cfg:*const config.Config,denied:usize=0,
    fn disk(self:*GuardedTarget) p.Disk { return .{.context=self,.sector_bytes=512,.sectors=self.raw.sectors,.read_fn=read,.write_fn=write,.flush_fn=flush}; }
    fn read(ctx:*anyopaque,at:u64,out:[]u8) p.Error!void { const self:*GuardedTarget=@ptrCast(@alignCast(ctx));try self.raw.read(at,out); }
    fn write(ctx:*anyopaque,at:u64,bytes:[]const u8) p.Error!void {
        const self:*GuardedTarget=@ptrCast(@alignCast(ctx));
        if (!self.cfg.writeAllowed(at,bytes.len)) { self.denied+=1;return error.Unsupported; }
        try self.raw.write(at,bytes);
    }
    fn flush(ctx:*anyopaque) p.Error!void { const self:*GuardedTarget=@ptrCast(@alignCast(ctx));try self.raw.flush(); }
};
fn receipt(boot:p.Disk,offset:u64,size:u32,expected:[32]u8,a:std.mem.Allocator,log:app.Logger) !void {
    const buffer=try a.alloc(u8,65536);defer a.free(buffer);
    try config.verifyReceipt(boot,offset,size,expected,buffer);
    log.say("BOOT RECEIPT offset={d} bytes={d} sha256={s} matched_host_pin; gate_semantics_checked_by_host\n",.{offset,size,std.fmt.bytesToHex(expected,.lower)});
}
fn run(ctx:*const Context,out:*Output) !void {
    if (!out.qemu) return error.QemuBootClientOnly;
    if (ctx.magic!=0x43425355 or ctx.version!=1 or ctx.size!=24 or ctx.drive!=0x80 or ctx.sector_bytes!=512) return error.InvalidBootContext;
    var boot=try Block.open(0x80,config.utility_bytes,512,true);
    var bytes:[512]u8=undefined;try boot.disk().read(1024*512,&bytes);
    const cfg=try config.parse(&bytes);
    var regions:[128]bios_heap.Region=undefined;
    const count=bios_e820_probe(&regions);if (count==0 or count>regions.len) return error.E820Unavailable;
    const arena=try bios_heap.selectLimit(regions[0..count],12*1024*1024);
    const memory:[*]u8=@ptrFromInt(arena.start);
    var fixed=heap_mod.init(memory[0..arena.bytes]);
    var tracker:p.TrackedAllocator=.{.backing=fixed.allocator(),.limit=arena.bytes};
    const a=tracker.allocator();
    out.persist=true;const log=out.logger();
    log.say("USOSBOOT BIOS BEGIN cpu_baseline=i486 utility=80 target=81; no WIM; no Windows NTFS writes\n",.{});
    try receipt(boot.disk(),config.layout_receipt_offset,cfg.layout_bytes,cfg.layout_sha256,a,log);
    try receipt(boot.disk(),config.bcd_receipt_offset,cfg.bcd_bytes,cfg.bcd_sha256,a,log);
    var target=try Block.open(0x81,cfg.target_bytes,512,true);
    var guard:GuardedTarget=.{.raw=target.disk(),.cfg=&cfg};
    const disk=guard.disk();const prepared=try layout.plan(disk,.bios);
    if (prepared.system.start_bytes!=cfg.system_start or prepared.system.size_bytes!=cfg.system_bytes or
        prepared.windows.start_bytes!=cfg.windows_start or prepared.windows.size_bytes!=cfg.windows_bytes) return error.BootDiskIdentityMismatch;
    if (try provision.validateDisk(disk,prepared,cfg.ids)!=cfg.system_serial) return error.BootDiskIdentityMismatch;
    try provision.requireEmptySystem(disk,prepared.system,a);
    var locale:[32]u16=undefined;
    const n=try std.unicode.utf8ToUtf16Le(&locale,cfg.locale[0..cfg.locale_len]);
    const stats=try provision.provisionBios(disk,prepared,cfg.ids,&tracker,.{.loader_guid=cfg.loader_guid,.timestamp=cfg.timestamp,.locale=locale[0..n],.gates=.{.layout_apply=true,.bcd_reference=true}},.{.mbr=&code.mbr,.pbr=&code.pbr},log);
    log.say("USOSBOOT BIOS copied files={d} bytes={d} bootmgr_sha256={s} bcd_sha256={s} bootmgr_lba={d} sectors={d}\n",.{stats.files,stats.bytes,std.fmt.bytesToHex(stats.main_sha256,.lower),std.fmt.bytesToHex(stats.bcd_sha256,.lower),stats.bootmgr_lba,stats.bootmgr_sectors});
    const stack=try stackUsage();
    log.say("STACK BIOS reserved={d} high_water={d} guard=4096 guard_intact=true real_mode_stack_separate=true\n",.{stack.reserved,stack.used});
    log.say("HEAP physical_current={d} physical_peak={d} extent_peak={d} reserved={d}\n",.{fixed.current_bytes,fixed.peak_bytes,fixed.extent_peak_bytes,fixed.buffer.len});
    log.say("USOSBOOT FINAL alloc_current={d} alloc_peak={d} target_reads={d} target_writes={d} denied_windows_writes={d}; first Windows start is a separate gate\n",.{tracker.current,tracker.peak,target.reads,target.writes,guard.denied});
    if (out.failed or tracker.current!=0 or fixed.current_bytes!=0 or guard.denied!=0) return error.Io;
}
fn core_main(ctx:*const Context) callconv(.c) void {
    const bss:[*]u8=@ptrCast(&__prep_bss_start);@memset(bss[0..@intFromPtr(&__prep_bss_end)-@intFromPtr(bss)],0);
    var output:Output=.{.qemu=entropy.qemuBios()};
    const passed=if (run(ctx,&output)) |_| true else |err| result: { output.logger().say("USOSBOOT TERMINAL FAIL {s}\n",.{@errorName(err)});break :result false; };
    if (output.qemu) asm volatile ("outl %[value], %[port]"::[value]"{eax}"(@as(u32,if (passed) 0x10 else 0x11)),[port]"{dx}"(@as(u16,0xf4)));
}
comptime { if (!builtin.is_test) @export(&core_main,.{.name="core_main"}); }
