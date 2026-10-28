//! Isolated i486 BIOS client: boot80, read-only NTFS source81, explicit target82.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std=@import("std");
const builtin=@import("builtin");
const p=@import("platform.zig");
const app=@import("app.zig");
const entropy=@import("entropy.zig");
const heap_mod=@import("fixed_heap.zig");
const bios_heap=@import("bios_heap.zig");
const o=@import("optical.zig");
const source_ntfs=@import("optical_ntfs.zig");
const layout=@import("windows_layout.zig");
const install=@import("install_app.zig");
const config=@import("bios_install_config.zig");
const perf_clock=@import("perf_clock.zig");
const tsc_clock=@import("tsc_clock.zig");
const rtc_clock=@import("rtc_clock.zig");
const profiling=@import("profiling.zig");
const writecombine=@import("writecombine.zig");
const Context=extern struct { magic:u32,version:u16,size:u16,drive:u8,reserved:[3]u8,sector_bytes:u32,core_lba:u64 };
const DriveInfo=extern struct { low:u32,high:u32,sector_bytes:u16,cylinders:u16,heads:u16,spt:u16 };
extern fn bios_install_read_blocks(u32,u64,u32,u32,[*]u8) callconv(.c) u32;
extern fn bios_install_write_blocks(u32,u64,u32,u32,[*]const u8) callconv(.c) u32;
extern fn bios_drive_info(u32,*DriveInfo) callconv(.c) u32;
extern fn bios_e820_probe([*]bios_heap.Region) callconv(.c) u32;
extern fn core_putc(u8) callconv(.c) void;
extern fn core_cmos_read(u32) callconv(.c) u32;
extern var __prep_bss_start:u8;
extern var __prep_bss_end:u8;
extern var bios_install_stack_top:u32;
const stack_base:usize=0x60000;
const stack_pattern:u32=0xcccccccc;
var block_io_counts:p.IoCounters=.{};
var storage_profiler:?*profiling.Profiler=null;
fn countedRead(drive:u32,lba:u64,count:u32,sector:u32,bytes:[*]u8) p.Error!void {
    const timing=p.measure(storage_profiler,if(drive==0x81) .source_io else .target_io);
    defer p.measured(storage_profiler,timing);
    block_io_counts.read(@as(u64,count)*sector);
    if (bios_install_read_blocks(drive,lba,count,sector,bytes)!=0) { block_io_counts.failed();return error.Io; }
}
fn countedWrite(drive:u32,lba:u64,count:u32,sector:u32,bytes:[*]const u8) p.Error!void {
    const timing=p.measure(storage_profiler,if(drive==0x81) .source_io else .target_io);
    defer p.measured(storage_profiler,timing);
    block_io_counts.write(@as(u64,count)*sector);
    if (bios_install_write_blocks(drive,lba,count,sector,bytes)!=0) { block_io_counts.failed();return error.Io; }
}

const Block=struct {
    drive:u32,sector:u32,sectors:u64,writable:bool=false,
    reads:u64=0,writes:u64=0,read_bytes:u64=0,written_bytes:u64=0,
    fn disk(self:*Block) p.Disk { return .{.context=self,.sector_bytes=self.sector,.sectors=self.sectors,.read_fn=read,.write_fn=write,.flush_fn=flush,.profiler=storage_profiler}; }
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
                try countedRead(self.drive,cursor/self.sector,count,self.sector,out[done..].ptr);
                const n:usize=count*self.sector;done+=n;self.reads+=1;self.read_bytes+=n;
            } else {
                try countedRead(self.drive,cursor/self.sector,1,self.sector,&one);
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
                try countedWrite(self.drive,cursor/self.sector,count,self.sector,bytes[done..].ptr);
                const n:usize=count*self.sector;done+=n;self.writes+=1;self.written_bytes+=n;
            } else {
                try countedRead(self.drive,cursor/self.sector,1,self.sector,&one);
                const n=@min(bytes.len-done,self.sector-within);
                @memcpy(one[within..][0..n],bytes[done..][0..n]);
                try countedWrite(self.drive,cursor/self.sector,1,self.sector,&one);
                done+=n;self.writes+=1;self.written_bytes+=self.sector;
            }
        }
    }
    fn flush(_: *anyopaque) p.Error!void {} // AH43 completion is synchronous.
};
const Output=struct {
    qemu:bool,persist:bool=false,cursor:usize=0,buffer:[512]u8=@splat(0),failed:bool=false,
    tracker:?*p.TrackedAllocator=null,
    profile:profiling.Profiler=profiling.Profiler.init(null),
    timer:?tsc_clock.Counter=null,
    timer_config:?perf_clock.Config=null,
    timing:bool=false,pm_reads:u64=0,
    fn timerMemory(_: *anyopaque,at:u64,len:usize) ![]const u8 {
        const ptr:[*]const u8=@ptrFromInt(@as(usize,@intCast(at)));return ptr[0..len];
    }
    fn timerRaw(ctx:*anyopaque) ?u32 {
        const self:*Output=@ptrCast(@alignCast(ctx));
        self.pm_reads +|= 1;
        return asm volatile("inl %[port], %[value]":[value]"={eax}"(->u32):[port]"{dx}"(self.timer_config.?.port));
    }
    fn timerRead(ctx:*anyopaque) ?u64 {
        const self:*Output=@ptrCast(@alignCast(ctx));return if(self.timer) |*timer| timer.read() else null;
    }
    fn initProfile(self:*Output) void {
        const caps=tsc_clock.nativeCapabilities();
        if(!caps.tsc) { self.logger().say("TIMING clock=unavailable reason=no_tsc pm_reads=0\n",.{});return; }
        const ebda_word:*const volatile u16=@ptrFromInt(0x40e);
        const ebda:u32=@as(u32,ebda_word.*)*16;
        const ranges=[_]struct{start:u32,end:u32}{
            .{.start=if(ebda>=0x80000 and ebda<=0x9fc00) ebda else 0xe0000,.end=if(ebda>=0x80000 and ebda<=0x9fc00) ebda+1024 else 0xe0000},
            .{.start=0xe0000,.end=0x100000},
        };
        for(ranges) |range| {
            var at=range.start;while(at+20<=range.end):(at+=16) {
                const bytes:[*]const u8=@ptrFromInt(at);
                if(!std.mem.eql(u8,bytes[0..8],"RSD PTR ")) continue;
                const cfg=perf_clock.discover(.{.context=self,.read_fn=timerMemory},at) catch continue;
                self.timer_config=cfg;self.timer=tsc_clock.Counter.init(caps,.{.context=self,.tsc_fn=tsc_clock.nativeRead,.pm_fn=timerRaw,.pm_width=cfg.width},self.checkedClock(),.{});
                const timer=&self.timer.?;
                if(timer.valid and self.timing) self.profile=profiling.Profiler.init(.{.context=self,.read_fn=timerRead,.frequency_hz=timer.frequency_hz,.name="tsc-calibrated-approximate"});
                self.logger().say("TIMING clock=tsc-calibrated hz={d} valid={any} failure={s} pm_reads={d} profile_enabled={any} pm_after_calibration=forbidden\n",.{timer.frequency_hz,timer.valid,@tagName(timer.failure),self.pm_reads,self.timing});
                return;
            }
        }
    }
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
    fn cmos(_: *anyopaque,index:u32) ?u32 {
        const value=core_cmos_read(index);
        return if(value<=255) value else null;
    }
    fn checkedClock(self:*Output) ?u64 {
        // Century0x32 is known for this QEMU fixture. Future hardware uses
        // FADT.CENTURY or a documented explicit100-year window.
        return rtc_clock.read(.{.context=self,.read_fn=cmos},.{.century_register=if(self.qemu) @as(?u8,0x32) else null});
    }
    fn clock(ctx:*anyopaque) u64 {
        const self:*Output=@ptrCast(@alignCast(ctx));
        return self.checkedClock() orelse 0;
    }
    fn telemetry(ctx:*anyopaque) p.Telemetry {
        const self:*Output=@ptrCast(@alignCast(ctx));
        if(self.timer) |*timer| timer.validate(self.checkedClock());
        if(self.timing) _=self.profile.now();
        var stats:p.Telemetry=.{.io=block_io_counts,.io_kind=.block_io,.alloc_peak=if(self.tracker) |t| t.peak else 0};
        if(self.timer) |*timer| { if(timer.read()) |ticks| stats.monotonic_ms=profiling.milliseconds(ticks,timer.frequency_hz); }
        if(stackUsage()) |stack| { stats.stack_available=true;stats.stack_high_water=stack.used; } else |_| {}
        return stats;
    }
    fn logger(self:*Output) app.Logger { return .{.context=self,.write_fn=write,.clock_fn=clock,.telemetry_fn=telemetry,.profiler=if(self.timing) &self.profile else null}; }
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
fn run(ctx:*const Context,out:*Output) !void {
    if (ctx.magic!=0x43425355 or ctx.version!=1 or ctx.size!=24 or ctx.drive!=0x80 or ctx.sector_bytes!=512) return error.InvalidBootContext;
    var boot_info:DriveInfo=undefined;
    if (bios_drive_info(0x80,&boot_info)!=0 or boot_info.sector_bytes!=512) return error.UnsupportedBootSector;
    var boot:Block=.{.drive=0x80,.sector=512,.sectors=(@as(u64,boot_info.high)<<32)|boot_info.low,.writable=true};
    var bytes:[512]u8=undefined;
    try boot.disk().read(1024*512,&bytes);
    const cfg=try config.parse(&bytes);
    var source=try Block.open(0x81,cfg.source_bytes,cfg.source_sector,false);
    var target=try Block.open(0x82,cfg.target_bytes,cfg.target_sector,true);
    var marker:[512]u8=@splat(0);
    const prefix="USOSPREP TARGET v1\n";
    @memcpy(marker[0..prefix.len],prefix);@memcpy(marker[prefix.len..][0..64],&cfg.token);marker[prefix.len+64]='\n';
    var observed:[512]u8=undefined;try target.disk().read(0,&observed);
    if (!std.mem.eql(u8,&observed,&marker)) return error.TargetMarkerMismatch;
    var bpb:[80]u8=undefined;try source.disk().read(cfg.source_start,&bpb);
    if (!std.mem.eql(u8,bpb[3..11],"NTFS    ") or std.mem.readInt(u64,bpb[72..80],.little)!=cfg.source_serial) return error.SourceSerialMismatch;
    var rng_ctx:u8=0;
    const random=try entropy.collect(.{.context=&rng_ctx,.rdseed=entropy.rdseed,.rdrand=entropy.rdrand,.fw_cfg=entropy.qemuEntropy,.qemu_detected=out.qemu});
    const ids=try layout.Ids.fromSeed64(random.bytes);
    var regions:[128]bios_heap.Region=undefined;
    const count=bios_e820_probe(&regions);if (count==0 or count>regions.len) return error.E820Unavailable;
    const arena=try bios_heap.selectLimit(regions[0..count],14*1024*1024);
    const memory:[*]u8=@ptrFromInt(arena.start);
    var fixed=heap_mod.init(memory[0..arena.bytes]);
    var tracker:p.TrackedAllocator=.{.backing=fixed.allocator(),.limit=arena.bytes};
    out.tracker=&tracker;
    defer out.tracker=null;
    out.timing=cfg.timing;out.initProfile();storage_profiler=if(cfg.timing) &out.profile else null;defer storage_profiler=null;
    var combined=try writecombine.Cache.init(tracker.allocator(),target.disk(),.qcow2_file);
    var combined_open=true;defer if(combined_open) combined.deinit();
    var source_disk=source.disk();
    var iso: source_ntfs.Source=undefined;
    try source_ntfs.Source.openInto(try o.Input.fromDisk(&source_disk),cfg.source_start,cfg.source_partition_bytes,&.{&.{'I','N','S','T','A','L','L','.','I','S','O'}},tracker.allocator(),&iso);
    var source_open=true;defer if (source_open) iso.deinit();
    if (iso.file.size()!=cfg.iso_bytes) return error.SourceFileSizeMismatch;
    out.persist=true;
    const log=out.logger();
    log.say("USOSPREP INSTALL BIOS cpu_baseline=i486 boot=80 source=81 target=82 sector_source={d} sector_target={d}\n",.{cfg.source_sector,cfg.target_sector});
    log.say("ENTROPY source={s} bytes=64 expansion=SHA256-domain-v2 qemu_detected={any}\n",.{@tagName(random.source),out.qemu});
    log.say("NTFS_ISO_SOURCE size={d} runs={d} attribute_extents={d} serial={x}\n",.{iso.file.size(),iso.file.runCount(),iso.file.attribute_extents,cfg.source_serial});
    const input=iso.reader();
    _=install.run(combined.disk(),.bios,ids,.{.explicit=true,.source_identity=0x81,.target_identity=0x82,.boot_identity=0x80,.marker=marker[0..prefix.len+65]},&tracker,.{.context=input.context,.size=input.size,.read_fn=input.read_fn},cfg.image_index,.{.target_drive='C',.strict_rpfix=true,.verify_scope=if(cfg.verify_all) .all else .selected},log) catch |err| {
        if (iso.last_error) |original| log.say("SOURCE_NTFS_ERROR original={s} outer={s}\n",.{@errorName(original),@errorName(err)});
        return err;
    };
    // Final flush is inside wim_app's dirty-state recovery lifetime.
    log.say("TARGET_COMBINE capacity={d} logical_writes={d} upstream_writes={d} drains={d} failures={d} edd_max_bytes=65024\n",.{writecombine.capacity,combined.stats.logical_writes,combined.stats.upstream_writes,combined.stats.drains,combined.stats.failures});
    combined.deinit();combined_open=false;
    iso.deinit();source_open=false;
    const stack=try stackUsage();
    log.say("STACK BIOS reserved={d} high_water={d} guard=4096 guard_intact=true real_mode_stack_separate=true\n",.{stack.reserved,stack.used});
    log.say("HEAP physical_current={d} physical_peak={d} extent_peak={d} reserved={d}\n",.{fixed.current_bytes,fixed.peak_bytes,fixed.extent_peak_bytes,fixed.buffer.len});
    log.say("IO source_reads={d} source_bytes={d} source_writes={d} target_reads={d} target_writes={d} target_written_bytes={d}\n",.{source.reads,source.read_bytes,source.writes,target.reads,target.writes,target.written_bytes});
    log.say("USOSPREP INSTALL FINAL current={d} peak={d}\n",.{tracker.current,tracker.peak});
    if (out.failed or tracker.current!=0 or fixed.current_bytes!=0 or source.writes!=0) return error.Io;
}
fn core_main(ctx:*const Context) callconv(.c) void {
    const bss:[*]u8=@ptrCast(&__prep_bss_start);@memset(bss[0..@intFromPtr(&__prep_bss_end)-@intFromPtr(bss)],0);
    var output:Output=.{.qemu=entropy.qemuBios()};
    const passed=if (run(ctx,&output)) |_| true else |err| result: { output.logger().say("USOSPREP INSTALL TERMINAL FAIL {s}\n",.{@errorName(err)});break :result false; };
    if (output.qemu) asm volatile ("outl %[value], %[port]"::[value]"{eax}"(@as(u32,if (passed) 0x10 else 0x11)),[port]"{dx}"(@as(u16,0xf4)));
}
comptime { if (!builtin.is_test) @export(&core_main,.{.name="core_main"}); }
