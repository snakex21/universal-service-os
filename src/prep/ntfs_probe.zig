//! Read-only host gate. The process owns no image/device file handle: a parent
//! supplies bounded requested ranges from the accepted, locked virtual image.
//! SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const nt = @import("ntfs_reader.zig");
const u = std.unicode.utf8ToUtf16LeStringLiteral;
const Input = struct {
    io: std.Io,
    fn read(ctx: *anyopaque, at: u64, out: []u8) error{Io,OutOfBounds}!void {
        const self: *Input = @ptrCast(@alignCast(ctx));
        if (out.len > 65536) return error.OutOfBounds;
        var request: [12]u8 = undefined;
        std.mem.writeInt(u64,request[0..8],at,.little);
        std.mem.writeInt(u32,request[8..12],@intCast(out.len),.little);
        std.Io.File.stdout().writeStreamingAll(self.io,&request) catch return error.Io;
        var done: usize = 0;
        while (done < out.len) {
            const n = std.Io.File.stdin().readStreaming(self.io,&.{out[done..]}) catch return error.Io;
            if (n == 0) return error.Io;
            done += n;
        }
    }
};
pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args,init.gpa);
    defer args.deinit();_ = args.next();
    const start = try std.fmt.parseInt(u64,args.next() orelse return error.MissingStart,10);
    const bytes = try std.fmt.parseInt(u64,args.next() orelse return error.MissingSize,10);
    if (args.next() != null) return error.UnexpectedArgument;
    var input: Input = .{ .io=init.io };
    const reader: nt.Reader = .{ .context=&input,.read_fn=Input.read };
    var fs = try nt.mountAllocated(reader,.{.start_bytes=start,.size_bytes=bytes},init.gpa);
    defer fs.deinit();
    std.debug.print("PROBE_MFT runs={d} heap_resolved={any}\n",.{fs.mftRunCount(),fs.mft_heap!=null});
    const paths = .{
        .{u("Windows"),u("System32"),u("winload.efi")},
        .{u("Windows"),u("Boot"),u("EFI"),u("bootmgfw.efi")},
        .{u("Windows"),u("System32"),u("config"),u("BCD-Template")},
        // The accepted Win11 fixture has exactly these two compressed files.
        // Our writer preserves the flag using full, raw compression units.
        .{u("Windows"),u("INF"),u("setupapi.offline.20240401_072600.log")},
        .{u("Windows"),u("servicing"),u("Sessions"),u("Sessions.xml")},
    };
    inline for (paths,0..) |path,index| {
        var file: nt.LargeFile = undefined;
        try nt.openLargeFile(&fs,reader,&path,init.gpa,&file);
        defer file.deinit();
        var sha = std.crypto.hash.Sha1.init(.{});
        var buffer: [65536]u8 = undefined;
        var offset: u64 = 0;
        while (offset < file.size()) {
            const n: usize = @intCast(@min(buffer.len,file.size()-offset));
            try file.readAt(&fs,reader,offset,buffer[0..n]);sha.update(buffer[0..n]);offset+=n;
        }
        const digest = sha.finalResult();
        std.debug.print("PROBE_FILE index={d} bytes={d} sha1={s}\n",.{index,file.size(),std.fmt.bytesToHex(digest,.lower)});
    }
    std.debug.print("PROBE_READONLY PASS writes=0\n",.{});
}
